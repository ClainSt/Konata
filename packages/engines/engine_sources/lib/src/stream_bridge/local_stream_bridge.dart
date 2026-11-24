import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';
import 'package:path/path.dart' as p;

import '../scanning/subtitle_matcher.dart';
import '../sources/source_access_error.dart';
import 'http_byte_range.dart';
import 'remote_window_reader.dart';

part 'local_stream_bridge_album.dart';
part 'local_stream_bridge_subtitle.dart';

/// 本地回环流网桥集中配置常量。
abstract final class StreamBridgeConfig {
  /// 单路回环会话无活跃连接后的默认空闲回收时长。
  static const Duration sessionIdleTimeout = Duration(minutes: 20);

  /// 后台巡检空闲会话的周期。
  static const Duration reaperInterval = Duration(minutes: 2);

  /// 本地套接字写入心跳与空转判定超时。
  static const Duration socketIdleTimeout = Duration(seconds: 45);

  /// 外挂字幕最大允许拉取体积上限（32 MiB，防止误将视频流当作字幕）。
  static const int maxSubtitleMaterializeBytes = 32 * 1024 * 1024;
}

class _SingleDigestSink implements Sink<Digest> {
  Digest? digest;

  @override
  void add(Digest data) {
    digest = data;
  }

  @override
  void close() {}
}

class _RegisteredStreamSession {
  _RegisteredStreamSession({
    required this.token,
    required this.gateway,
    required this.relativePath,
    required this.fileName,
    required this.ownsGateway,
    required this.etag,
    this.sourceKind = MediaSourceKind.webdav,
    DateTime? createdAt,
    this.cachedLength,
  }) : lastAccessedAt = createdAt ?? DateTime.now();

  final String token;
  final ByteRangeReadableGateway gateway;
  final String relativePath;
  final String fileName;
  final bool ownsGateway;
  final String etag;
  final MediaSourceKind sourceKind;
  DateTime lastAccessedAt;
  int activeStreams = 0;
  int? cachedLength;
  Future<int?>? inflightLengthProbe;
  RemoteWindowReader? windowReader;
  Future<void> Function()? prewarmCancel;
  String? lastDiagnosticError;
  SourceAccessProblemKind? lastDiagnosticKind;
}

/// 本地安全回环按需 HTTP Range 流媒体网桥（绑定 `127.0.0.1` 动态空闲端口）。
///
/// 负责将远程音视频流按 `206 Partial Content`（含 `ETag` 与 `If-Range`）并发无阻塞透传给播放器，
/// 并在下游中断请求时即时取消上游流；同时将远程外挂字幕原子落盘至便携临时缓存目录。
class LocalStreamBridge implements LocalStreamBridgePort {
  /// 创建流网桥实例。
  LocalStreamBridge({
    StorageRootPort? storageRoot,
    Duration? idleTimeout,
    Duration? reaperInterval,
  }) : _storageRoot = storageRoot ?? const PortableStorageRootService(),
       _idleTimeout = idleTimeout ?? StreamBridgeConfig.sessionIdleTimeout,
       _reaperInterval = reaperInterval ?? StreamBridgeConfig.reaperInterval;

  final StorageRootPort _storageRoot;
  final Duration _idleTimeout;
  final Duration _reaperInterval;

  HttpServer? _server;
  Future<HttpServer>? _starting;
  Timer? _reaperTimer;
  final Map<String, _RegisteredStreamSession> _sessions =
      <String, _RegisteredStreamSession>{};
  final Map<String, _VirtualAlbumDirectorySession> _albumSessions =
      <String, _VirtualAlbumDirectorySession>{};
  final Map<String, String> _recentErrorsByPath = <String, String>{};
  final Map<String, String> _recentErrorsByToken = <String, String>{};
  final Map<String, SourceAccessProblemKind> _recentKindsByPath =
      <String, SourceAccessProblemKind>{};
  final Map<String, SourceAccessProblemKind> _recentKindsByToken =
      <String, SourceAccessProblemKind>{};
  int _tokenCounter = 0;

  void _recordDiagnostic(_RegisteredStreamSession session, Object error) {
    final classified = SourceAccessErrorClassifier.classify(
      error,
      session.sourceKind,
    );
    final message = classified.kind == SourceAccessProblemKind.path
        ? '媒体文件不存在或源路径已变更（${session.relativePath}），请前往「媒体源」重新扫描同步'
        : classified.message;
    session.lastDiagnosticError = message;
    session.lastDiagnosticKind = classified.kind;
    final normPath = session.relativePath.replaceAll('\\', '/');
    _recentErrorsByPath.remove(normPath);
    _recentErrorsByPath[normPath] = message;
    _recentKindsByPath.remove(normPath);
    _recentKindsByPath[normPath] = classified.kind;
    while (_recentErrorsByPath.length > 24) {
      final oldest = _recentErrorsByPath.keys.first;
      _recentErrorsByPath.remove(oldest);
      _recentKindsByPath.remove(oldest);
    }
    _recentErrorsByToken.remove(session.token);
    _recentErrorsByToken[session.token] = message;
    _recentKindsByToken.remove(session.token);
    _recentKindsByToken[session.token] = classified.kind;
    while (_recentErrorsByToken.length > 24) {
      final oldest = _recentErrorsByToken.keys.first;
      _recentErrorsByToken.remove(oldest);
      _recentKindsByToken.remove(oldest);
    }
  }

  @override
  String? describeLastError({String? token, String? relativePath}) {
    if (token != null && token.isNotEmpty) {
      final live = _sessions[token]?.lastDiagnosticError;
      if (live != null && live.isNotEmpty) return live;
      final recentByTok = _recentErrorsByToken[token];
      if (recentByTok != null && recentByTok.isNotEmpty) return recentByTok;
    }
    if (relativePath != null && relativePath.isNotEmpty) {
      final norm = relativePath.replaceAll('\\', '/');
      return _recentErrorsByPath[norm];
    }
    return null;
  }

  @override
  SourceAccessProblemKind? lastErrorKind({
    String? token,
    String? relativePath,
  }) {
    if (token != null && token.isNotEmpty) {
      final live = _sessions[token]?.lastDiagnosticKind;
      if (live != null) return live;
      final recentByTok = _recentKindsByToken[token];
      if (recentByTok != null) return recentByTok;
    }
    if (relativePath != null && relativePath.isNotEmpty) {
      final norm = relativePath.replaceAll('\\', '/');
      return _recentKindsByPath[norm];
    }
    return null;
  }

  @override
  int? get port => _server?.port;

  @override
  int get activeSessionCount => _sessions.length + _albumSessions.length;

  /// 确保底层回环服务器已启动，并返回监听的服务器实例。
  Future<HttpServer> ensureStarted() {
    final existing = _server;
    if (existing != null) return Future<HttpServer>.value(existing);
    final inflight = _starting;
    if (inflight != null) return inflight;

    final startFuture = HttpServer.bind(InternetAddress.loopbackIPv4, 0)
        .then((server) {
          server.idleTimeout = StreamBridgeConfig.socketIdleTimeout;
          _server = server;
          _starting = null;
          _reaperTimer ??= Timer.periodic(
            _reaperInterval,
            (_) => unawaited(pruneIdleSessions()),
          );
          server.listen(_handleRequest);
          return server;
        })
        .catchError((Object error, StackTrace stack) {
          _starting = null;
          throw error;
        });
    _starting = startFuture;
    return startFuture;
  }

  @override
  Future<({String token, Uri url})> registerSession({
    required ByteRangeReadableGateway gateway,
    required String relativePath,
    required String fileName,
    int? knownLength,
    bool ownsGateway = false,
    MediaSourceKind sourceKind = MediaSourceKind.webdav,
  }) async {
    final server = await ensureStarted();
    _tokenCounter += 1;
    final rawSeed =
        '${DateTime.now().microsecondsSinceEpoch}_${_tokenCounter}_$relativePath';
    final token = sha1
        .convert(utf8.encode(rawSeed))
        .toString()
        .substring(0, 16);

    final sanitizedLength = (knownLength != null && knownLength > 0)
        ? knownLength
        : null;
    final etagDigest = sha1
        .convert(utf8.encode('$relativePath#${sanitizedLength ?? 0}#$token'))
        .toString()
        .substring(0, 12);
    final etag = '"$etagDigest"';

    final normRel = relativePath.replaceAll('\\', '/');
    _recentErrorsByPath.remove(normRel);
    _recentKindsByPath.remove(normRel);
    _sessions[token] = _RegisteredStreamSession(
      token: token,
      gateway: gateway,
      relativePath: relativePath,
      fileName: fileName,
      ownsGateway: ownsGateway,
      etag: etag,
      sourceKind: sourceKind,
      cachedLength: sanitizedLength,
    );

    final url = Uri(
      scheme: 'http',
      host: '127.0.0.1',
      port: server.port,
      pathSegments: <String>['stream', token, fileName],
    );
    return (token: token, url: url);
  }

  @override
  Future<bool> prewarmSessionMetadata(
    String token, {
    int headBytes = 1024 * 1024,
    int tailBytes = 512 * 1024,
  }) async {
    final session = _sessions[token];
    if (session == null) return false;
    var canceled = false;
    StreamSubscription<List<int>>? activeSub;
    Completer<void>? activeDone;
    session.prewarmCancel = () async {
      canceled = true;
      await activeSub?.cancel();
      if (activeDone != null && !activeDone!.isCompleted) {
        activeDone!.complete();
      }
    };

    Future<bool> drainRange(
      RemoteWindowReader reader,
      int start,
      int endInclusive,
    ) async {
      if (canceled || _sessions[token] != session || endInclusive < start) {
        return false;
      }
      final done = Completer<void>();
      activeDone = done;
      activeSub = reader
          .read(start: start, endInclusive: endInclusive)
          .listen(
            (_) {},
            onError: (_) {
              if (!done.isCompleted) done.complete();
            },
            onDone: () {
              if (!done.isCompleted) done.complete();
            },
            cancelOnError: true,
          );
      await done.future;
      await activeSub?.cancel();
      activeSub = null;
      activeDone = null;
      return !canceled && _sessions[token] == session;
    }

    try {
      session.activeStreams += 1;
      session.lastAccessedAt = DateTime.now();
      final totalLength = await _resolveTotalLength(session);
      if (canceled ||
          _sessions[token] != session ||
          totalLength == null ||
          totalLength <= 0) {
        return false;
      }
      final reader = session.windowReader ??= RemoteWindowReader(
        gateway: session.gateway,
        relativePath: session.relativePath,
        totalLength: totalLength,
      );
      final headEnd = (headBytes - 1).clamp(0, totalLength - 1);
      final headOk = await drainRange(reader, 0, headEnd);
      if (!headOk) return false;
      if (tailBytes > 0 && totalLength > headEnd + 1) {
        final tailStart = (totalLength - tailBytes).clamp(
          headEnd + 1,
          totalLength - 1,
        );
        await drainRange(reader, tailStart, totalLength - 1);
      }
      return !canceled && _sessions[token] == session;
    } catch (error) {
      developer.log(
        '静默预热流会话元数据忽略',
        name: 'konata.local_stream_bridge',
        error: error,
      );
      return false;
    } finally {
      session.prewarmCancel = null;
      session.activeStreams = (session.activeStreams - 1).clamp(0, 100000);
      session.lastAccessedAt = DateTime.now();
    }
  }

  @override
  Future<void> unregisterSession(String token) async {
    final session = _sessions.remove(token);
    if (session?.prewarmCancel != null) {
      try {
        await session!.prewarmCancel!();
      } catch (error) {
        developer.log(
          '取消会话预热任务忽略',
          name: 'konata.local_stream_bridge',
          error: error,
        );
      }
    }
    session?.windowReader?.clear();
    if (session != null && session.ownsGateway) {
      try {
        await session.gateway.close();
      } catch (error) {
        developer.log(
          '释放网关异常已忽略',
          name: 'konata.local_stream_bridge',
          error: error,
        );
      }
    }
  }

  @override
  Future<int> pruneIdleSessions({Duration? maxIdle, DateTime? now}) async {
    final threshold = maxIdle ?? _idleTimeout;
    final current = now ?? DateTime.now();
    final expiredTokens = <String>[];
    for (final entry in _sessions.entries) {
      final s = entry.value;
      if (s.activeStreams > 0) continue;
      if (current.difference(s.lastAccessedAt) >= threshold) {
        expiredTokens.add(entry.key);
      }
    }
    for (final token in expiredTokens) {
      await unregisterSession(token);
    }
    final expiredAlbums = _collectExpiredAlbumTokens(
      threshold: threshold,
      current: current,
    );
    for (final albumToken in expiredAlbums) {
      await unregisterAlbumSession(albumToken);
    }
    return expiredTokens.length + expiredAlbums.length;
  }

  /// 规范化字幕相对路径（统一斜杠与首尾分隔符，作为缓存定位键组成部分）。
  static String canonicalizeSubtitleRelativePath(String rawPath) {
    return rawPath
        .replaceAll('\\', '/')
        .replaceAll(RegExp(r'/+'), '/')
        .replaceAll(RegExp(r'^/|/$'), '');
  }

  /// 构造绑定媒体源、规范路径与源版本验证器的原始字幕缓存定位键。
  static String buildSubtitleCacheKey({
    required String sourceId,
    required String relativePath,
    String validator = '',
  }) {
    final canonical = canonicalizeSubtitleRelativePath(relativePath);
    return '$sourceId\x00$canonical\x00$validator';
  }

  @override
  Future<List<String>> resolveExistingCachedSubtitles({
    required String workId,
    required List<String> subtitleRelativePaths,
    String? sourceId,
    Map<String, String>? validatorsByPath,
  }) => _resolveExistingCachedSubtitlesImpl(
    workId: workId,
    subtitleRelativePaths: subtitleRelativePaths,
    sourceId: sourceId,
    validatorsByPath: validatorsByPath,
  );

  @override
  Future<List<String>> materializeRemoteSubtitles({
    required ByteRangeReadableGateway gateway,
    required String workId,
    required List<String> subtitleRelativePaths,
    String? sourceId,
    Map<String, String>? validatorsByPath,
  }) async {
    final records = await materializeRemoteSubtitleRecords(
      gateway: gateway,
      workId: workId,
      subtitleRelativePaths: subtitleRelativePaths,
      sourceId: sourceId,
      validatorsByPath: validatorsByPath,
    );
    return records.map((r) => r.localFilePath).toList(growable: false);
  }

  @override
  Future<List<MaterializedSubtitleRecord>> materializeRemoteSubtitleRecords({
    required ByteRangeReadableGateway gateway,
    required String workId,
    required List<String> subtitleRelativePaths,
    String? sourceId,
    Map<String, String>? validatorsByPath,
  }) => _materializeRemoteSubtitleRecordsImpl(
    gateway: gateway,
    workId: workId,
    subtitleRelativePaths: subtitleRelativePaths,
    sourceId: sourceId,
    validatorsByPath: validatorsByPath,
  );

  @override
  Future<VirtualAlbumRegistration> registerCueAlbumSession({
    required ByteRangeReadableGateway gateway,
    required String normalizedCueText,
    required List<VirtualAlbumAudioEntry> audioEntries,
    bool ownsGateway = true,
    MediaSourceKind sourceKind = MediaSourceKind.webdav,
  }) => _registerCueAlbumSessionImpl(
    gateway: gateway,
    normalizedCueText: normalizedCueText,
    audioEntries: audioEntries,
    ownsGateway: ownsGateway,
    sourceKind: sourceKind,
  );

  @override
  Future<VirtualAlbumRegistration> registerPlaylistM3u8Session({
    required ByteRangeReadableGateway gateway,
    required List<VirtualAlbumAudioEntry> audioEntries,
    bool ownsGateway = true,
    MediaSourceKind sourceKind = MediaSourceKind.webdav,
  }) => _registerPlaylistM3u8SessionImpl(
    gateway: gateway,
    audioEntries: audioEntries,
    ownsGateway: ownsGateway,
    sourceKind: sourceKind,
  );

  /// 在应用便携缓存目录原子写入带字符编码前缀的本地影子分轨清单文件。
  Future<String> writeLocalShadowCue({
    required String seedKey,
    required String normalizedCueText,
  }) => _writeLocalShadowCueImpl(
    seedKey: seedKey,
    normalizedCueText: normalizedCueText,
  );

  /// 刷新指定虚拟专辑会话及子流心跳时间，避免空闲回收断流。
  void touchAlbumSession(String albumToken) =>
      _touchAlbumSessionImpl(albumToken);

  @override
  Future<void> unregisterAlbumSession(String albumToken) =>
      _unregisterAlbumSessionImpl(albumToken);

  Future<int?> _resolveTotalLength(_RegisteredStreamSession session) {
    final cached = session.cachedLength;
    if (cached != null && cached > 0) {
      return Future<int?>.value(cached);
    }
    final existingProbe = session.inflightLengthProbe;
    if (existingProbe != null) {
      return existingProbe;
    }
    final probe = session.gateway
        .probeFileLength(session.relativePath)
        .then((len) {
          if (len != null && len > 0) {
            session.cachedLength = len;
          }
          return len;
        })
        .whenComplete(() {
          session.inflightLengthProbe = null;
        });
    session.inflightLengthProbe = probe;
    return probe;
  }

  Future<void> _handleRequest(HttpRequest request) async {
    final response = request.response;
    final segments = request.uri.pathSegments;
    if (segments.length >= 3 && segments[0] == 'album') {
      await _handleVirtualAlbumRequest(request, segments);
      return;
    }
    if (segments.length < 2 || segments[0] != 'stream') {
      response.statusCode = HttpStatus.notFound;
      await response.close();
      return;
    }

    final token = segments[1];
    final session = _sessions[token];
    if (session == null) {
      response.statusCode = HttpStatus.notFound;
      await response.close();
      return;
    }
    await _serveStreamSession(request, response, session);
  }

  Future<void> _serveStreamSession(
    HttpRequest request,
    HttpResponse response,
    _RegisteredStreamSession session,
  ) async {
    _RegisteredStreamSession? trackedSession;
    try {
      trackedSession = session;
      session.lastAccessedAt = DateTime.now();
      session.activeStreams += 1;

      if (request.method != 'GET' && request.method != 'HEAD') {
        response.statusCode = HttpStatus.methodNotAllowed;
        await response.close();
        return;
      }

      final totalLength = await _resolveTotalLength(session);

      response.bufferOutput = false;
      response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      response.headers.set(HttpHeaders.etagHeader, session.etag);
      response.headers.set(
        HttpHeaders.contentTypeHeader,
        _guessMimeType(session.fileName),
      );
      response.headers.set(
        'Content-Disposition',
        "inline; filename*=UTF-8''${Uri.encodeComponent(session.fileName)}",
      );
      response.headers.set('Cache-Control', 'no-store');

      final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
      final ifRangeHeader = request.headers.value(HttpHeaders.ifRangeHeader);
      final allowPartial = _matchesIfRange(ifRangeHeader, session.etag);

      if (allowPartial &&
          rangeHeader != null &&
          rangeHeader.trim().isNotEmpty) {
        if (totalLength == null || totalLength <= 0) {
          response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
          await response.close();
          return;
        }

        final parsed = HttpByteRange.parse(rangeHeader, totalLength);
        final parsedRange = parsed.range;
        if (!parsed.valid || parsedRange == null) {
          response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
          response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes */$totalLength',
          );
          await response.close();
          return;
        }

        response.statusCode = HttpStatus.partialContent;
        response.headers.set(
          HttpHeaders.contentRangeHeader,
          parsedRange.toContentRangeHeader(),
        );
        response.headers.contentLength = parsedRange.length;

        if (request.method == 'HEAD') {
          await response.close();
          return;
        }

        final stream =
            (session.windowReader ??= RemoteWindowReader(
              gateway: session.gateway,
              relativePath: session.relativePath,
              totalLength: totalLength,
            )).read(
              start: parsedRange.start,
              endInclusive: parsedRange.endInclusive,
            );
        await _streamChunksWithAbort(stream, response, session: session);
        return;
      }

      response.statusCode = HttpStatus.ok;
      if (totalLength != null && totalLength > 0) {
        response.headers.contentLength = totalLength;
      }
      if (request.method == 'HEAD') {
        await response.close();
        return;
      }

      final fullStream = totalLength != null && totalLength > 0
          ? (session.windowReader ??= RemoteWindowReader(
              gateway: session.gateway,
              relativePath: session.relativePath,
              totalLength: totalLength,
            )).read(start: 0, endInclusive: totalLength - 1)
          : await session.gateway.openByteRange(session.relativePath, start: 0);
      await _streamChunksWithAbort(fullStream, response, session: session);
    } catch (error) {
      if (trackedSession != null) {
        _recordDiagnostic(trackedSession, error);
      }
      try {
        final msg = error.toString();
        response.contentLength = 0;
        response.headers.removeAll(HttpHeaders.contentRangeHeader);
        response.headers.removeAll(HttpHeaders.etagHeader);
        if (error is PathNotFoundException || msg.contains('HTTP 404')) {
          response.statusCode = HttpStatus.notFound;
        } else {
          response.statusCode = HttpStatus.badGateway;
        }
        await response.close();
      } catch (closeErr) {
        developer.log(
          '回写网桥错误响应忽略',
          name: 'konata.local_stream_bridge',
          error: closeErr,
        );
      }
    } finally {
      if (trackedSession != null) {
        trackedSession.activeStreams = (trackedSession.activeStreams - 1).clamp(
          0,
          100000,
        );
        trackedSession.lastAccessedAt = DateTime.now();
      }
    }
  }

  /// 校验 HTTP `If-Range` 请求头是否命中当前会话强标签。
  static bool _matchesIfRange(String? ifRangeHeader, String sessionEtag) {
    if (ifRangeHeader == null || ifRangeHeader.trim().isEmpty) {
      return true;
    }
    final tag = ifRangeHeader.trim();
    return !tag.startsWith('W/') && tag == sessionEtag;
  }

  /// 拆离底层回环套接字以监听对端断连信号，在下游取消或跳转时即时中断上游流。
  Future<void> _streamChunksWithAbort(
    Stream<List<int>> source,
    HttpResponse response, {
    required _RegisteredStreamSession session,
  }) async {
    response.persistentConnection = false;
    response.headers.chunkedTransferEncoding = false;
    response.headers.set(HttpHeaders.connectionHeader, 'close');
    final iterator = StreamIterator<List<int>>(source);
    bool hasFirstChunk;
    try {
      hasFirstChunk = await iterator.moveNext();
    } catch (_) {
      try {
        await iterator.cancel();
      } catch (cancelErr) {
        developer.log(
          '上游首包取消异常已忽略',
          name: 'konata.local_stream_bridge',
          error: cancelErr,
        );
      }
      rethrow;
    }

    final socket = await response.detachSocket(writeHeaders: true);
    try {
      socket.setOption(SocketOption.tcpNoDelay, true);
    } catch (error) {
      developer.log(
        '设置套接字低延迟选项忽略',
        name: 'konata.local_stream_bridge',
        error: error,
      );
    }

    final disconnected = Completer<bool>();
    void markDisconnected() {
      if (!disconnected.isCompleted) {
        disconnected.complete(false);
      }
    }

    StreamSubscription<void>? peerSub;
    var completedNormally = false;
    try {
      peerSub = socket.listen(
        (_) {},
        onDone: markDisconnected,
        onError: (_) => markDisconnected(),
        cancelOnError: false,
      );
      unawaited(
        socket.done.then(
          (_) => markDisconnected(),
          onError: (_) => markDisconnected(),
        ),
      );

      if (!hasFirstChunk) {
        completedNormally = !disconnected.isCompleted;
        return;
      }

      const flushThresholdBytes = 256 * 1024;
      var unflushedBytes = 0;
      var firstChunkFlushed = false;

      final firstChunk = iterator.current;
      if (firstChunk.isNotEmpty) {
        socket.add(firstChunk);
        firstChunkFlushed = true;
        await socket.flush();
      }

      var nextMove = iterator.moveNext();
      while (true) {
        final hasNext = await Future.any<bool>(<Future<bool>>[
          nextMove,
          disconnected.future,
        ]);
        if (!hasNext) {
          completedNormally = !disconnected.isCompleted;
          break;
        }
        if (disconnected.isCompleted) {
          break;
        }
        final chunk = iterator.current;
        if (chunk.isEmpty) {
          nextMove = iterator.moveNext();
          continue;
        }
        socket.add(chunk);
        unflushedBytes += chunk.length;
        if (!firstChunkFlushed || unflushedBytes >= flushThresholdBytes) {
          firstChunkFlushed = true;
          unflushedBytes = 0;
          await socket.flush();
        }
        nextMove = iterator.moveNext();
      }
    } on SocketException catch (error) {
      if (!disconnected.isCompleted) {
        _recordDiagnostic(session, error);
      }
      developer.log(
        '流传输连接异常已记录',
        name: 'konata.local_stream_bridge',
        error: error,
      );
    } on HttpException catch (error) {
      if (!disconnected.isCompleted) {
        _recordDiagnostic(session, error);
      }
      developer.log(
        '流传输协议异常已记录',
        name: 'konata.local_stream_bridge',
        error: error,
      );
    } catch (error) {
      if (!disconnected.isCompleted) {
        _recordDiagnostic(session, error);
      }
      developer.log(
        '流传输上游异常已记录',
        name: 'konata.local_stream_bridge',
        error: error,
      );
    } finally {
      try {
        await iterator.cancel();
      } catch (error) {
        developer.log(
          '取消上游流迭代器忽略',
          name: 'konata.local_stream_bridge',
          error: error,
        );
      }
      try {
        await peerSub?.cancel();
      } catch (error) {
        developer.log(
          '取消对端监听忽略',
          name: 'konata.local_stream_bridge',
          error: error,
        );
      }
      if (completedNormally) {
        try {
          await socket.flush();
          await socket.close();
        } catch (error) {
          developer.log(
            '正常关闭传输套接字忽略',
            name: 'konata.local_stream_bridge',
            error: error,
          );
        }
      } else {
        try {
          socket.destroy();
        } catch (error) {
          developer.log(
            '强制销毁传输套接字忽略',
            name: 'konata.local_stream_bridge',
            error: error,
          );
        }
      }
    }
  }

  String _guessMimeType(String fileName) =>
      KonataMediaExtensions.mimeTypeFor(fileName);

  @override
  Future<void> close() async {
    _reaperTimer?.cancel();
    _reaperTimer = null;
    final tokens = _sessions.keys.toList(growable: false);
    for (final token in tokens) {
      await unregisterSession(token);
    }
    final albumTokens = _albumSessions.keys.toList(growable: false);
    for (final albumToken in albumTokens) {
      await unregisterAlbumSession(albumToken);
    }
    final server = _server;
    _server = null;
    if (server != null) {
      await server.close(force: true);
    }
  }

  /// 兼容旧调用的释放入口（等同于 [close]）。
  Future<void> dispose() => close();
}
