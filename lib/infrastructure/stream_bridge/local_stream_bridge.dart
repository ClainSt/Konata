import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../sources/byte_stream_source_gateway.dart';
import '../sources/subtitle_matcher.dart';
import '../storage/storage_root_provider.dart';
import 'http_byte_range.dart';

/// 本地回环流网桥集中配置常量（避免超时阈值与路径硬编码）。
abstract final class StreamBridgeConfig {
  /// 单路回环会话无活跃连接后的默认空闲回收时长。
  static const Duration sessionIdleTimeout = Duration(minutes: 20);

  /// 后台巡检空闲会话的周期。
  static const Duration reaperInterval = Duration(minutes: 2);

  /// 本地套接字写入心跳与空转判定超时。
  static const Duration socketIdleTimeout = Duration(seconds: 45);

  /// 外挂字幕最大允许拉取体积上限（32 MiB，严防误将视频流当作字幕拖垮首帧）。
  static const int maxSubtitleMaterializeBytes = 32 * 1024 * 1024;
}

class _RegisteredStreamSession {
  _RegisteredStreamSession({
    required this.token,
    required this.gateway,
    required this.relativePath,
    required this.fileName,
    required this.ownsGateway,
    required this.etag,
    DateTime? createdAt,
    this.cachedLength,
  }) : lastAccessedAt = createdAt ?? DateTime.now();

  final String token;
  final ByteRangeReadableGateway gateway;
  final String relativePath;
  final String fileName;
  final bool ownsGateway;
  final String etag;
  DateTime lastAccessedAt;
  int activeStreams = 0;
  int? cachedLength;
  Future<int?>? inflightLengthProbe;
}

/// 本地安全回环按需 HTTP Range 流媒体网桥（绑定 `127.0.0.1` 动态空闲端口）。
///
/// 负责将 WebDAV / SMB 远程音视频流按 `206 Partial Content`（含 `ETag` 与 `If-Range`）
/// 并发无阻塞地透传给内置 `libmpv` 或外部播放器，在下游中断请求时即时取消上游流并支持空闲回收，
/// 同时将远程外挂字幕落地至应用便携 `cache/tmp/konata_subs/`，原媒体文件全程零落盘。
class LocalStreamBridge {
  /// 创建流网桥实例。
  LocalStreamBridge({
    StorageRootService? storageRoot,
    Duration? idleTimeout,
    Duration? reaperInterval,
  }) : _storageRoot = storageRoot ?? const StorageRootService(),
       _idleTimeout = idleTimeout ?? StreamBridgeConfig.sessionIdleTimeout,
       _reaperInterval = reaperInterval ?? StreamBridgeConfig.reaperInterval;

  final StorageRootService _storageRoot;
  final Duration _idleTimeout;
  final Duration _reaperInterval;

  HttpServer? _server;
  Future<HttpServer>? _starting;
  Timer? _reaperTimer;
  final Map<String, _RegisteredStreamSession> _sessions = {};
  int _tokenCounter = 0;

  /// 当前监听端口号（未启动时返回 `null`）。
  int? get port => _server?.port;

  /// 当前仍处于注册状态的流会话令牌数量（用于测试与诊断）。
  int get activeSessionCount => _sessions.length;

  /// 确保底层回环 HTTP 服务器已启动，并返回监听的服务器实例。
  Future<HttpServer> ensureStarted() {
    final existing = _server;
    if (existing != null) return Future.value(existing);
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

  /// 注册一个远程媒体的本地流会话，返回 `http://127.0.0.1:<port>/stream/<token>/<name>` 与对应 `ETag`。
  Future<({String token, Uri url})> registerSession({
    required ByteRangeReadableGateway gateway,
    required String relativePath,
    required String fileName,
    int? knownLength,
    bool ownsGateway = false,
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
    final etag = 'W/"$etagDigest"';

    _sessions[token] = _RegisteredStreamSession(
      token: token,
      gateway: gateway,
      relativePath: relativePath,
      fileName: fileName,
      ownsGateway: ownsGateway,
      etag: etag,
      cachedLength: sanitizedLength,
    );

    // Uri(pathSegments: ...) 自身会对分段执行标准单次 UTF-8 百分号编码，
    // 严禁再手动调用 Uri.encodeComponent，以免产生 %255B... 双重编码乱码。
    final url = Uri(
      scheme: 'http',
      host: '127.0.0.1',
      port: server.port,
      pathSegments: ['stream', token, fileName],
    );
    return (token: token, url: url);
  }

  /// 注销单个流会话并按需释放关联网关。
  Future<void> unregisterSession(String token) async {
    final session = _sessions.remove(token);
    if (session != null && session.ownsGateway) {
      try {
        await session.gateway.close();
      } catch (_) {}
    }
  }

  /// 回收超过空闲阈值且无活跃传输流的历史会话，防止远程连接泄漏。
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
    return expiredTokens.length;
  }

  /// 将远程源中的外挂字幕文件并发拉取并写入应用便携 `cache/tmp/konata_subs/` 目录。
  ///
  /// 严格校验扩展名与文件体积上限（<= 32 MiB），并将文件存入索引隔离目录保持原始文件名完整无前缀篡改。
  Future<List<String>> materializeRemoteSubtitles({
    required ByteRangeReadableGateway gateway,
    required String workId,
    required List<String> subtitleRelativePaths,
  }) async {
    if (subtitleRelativePaths.isEmpty) return const [];
    final dirHash = sha1
        .convert(utf8.encode(workId))
        .toString()
        .substring(0, 12);
    final targetDir = await _storageRoot.ensureSubtitleStageDir(dirHash);

    final results = await Future.wait(
      subtitleRelativePaths.asMap().entries.map((entry) async {
        final relPath = entry.value;
        final baseName = p.posix.basename(relPath.replaceAll('\\', '/'));
        if (!SubtitleMatcher.isSubtitleFile(baseName)) {
          return null;
        }
        final subDir = Directory(p.join(targetDir.path, '${entry.key}'));
        final destFile = File(p.join(subDir.path, baseName));
        int? probedLen;
        try {
          if (await destFile.exists()) {
            final existingLen = await destFile.length();
            if (existingLen > 0 &&
                existingLen <= StreamBridgeConfig.maxSubtitleMaterializeBytes) {
              return destFile.path;
            }
          }
          probedLen = await gateway.probeFileLength(relPath);
          if (probedLen != null &&
              probedLen > StreamBridgeConfig.maxSubtitleMaterializeBytes) {
            return null;
          }
        } catch (_) {}

        await subDir.create(recursive: true);
        final sink = destFile.openWrite();
        var writtenBytes = 0;
        var failedOrOversized = false;
        try {
          final stream = await gateway.openByteRange(relPath, start: 0);
          await for (final chunk in stream) {
            writtenBytes += chunk.length;
            if (writtenBytes > StreamBridgeConfig.maxSubtitleMaterializeBytes) {
              failedOrOversized = true;
              break;
            }
            sink.add(chunk);
          }
          if (!failedOrOversized) {
            await sink.flush();
          }
        } catch (_) {
          failedOrOversized = true;
        } finally {
          await sink.close();
        }
        if (failedOrOversized) {
          if (await destFile.exists()) {
            await destFile.delete().catchError((_) => destFile);
          }
          return null;
        }
        return destFile.path;
      }),
    );

    return results.whereType<String>().toList(growable: false);
  }

  Future<int?> _resolveTotalLength(_RegisteredStreamSession session) {
    final cached = session.cachedLength;
    if (cached != null && cached > 0) {
      return Future.value(cached);
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
    _RegisteredStreamSession? trackedSession;
    try {
      final segments = request.uri.pathSegments;
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

        final stream = await session.gateway.openByteRange(
          session.relativePath,
          start: parsedRange.start,
          endInclusive: parsedRange.endInclusive,
        );
        await _streamChunksWithAbort(stream, response);
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

      final fullStream = await session.gateway.openByteRange(
        session.relativePath,
        start: 0,
        endInclusive: totalLength != null && totalLength > 0
            ? totalLength - 1
            : null,
      );
      await _streamChunksWithAbort(fullStream, response);
    } catch (_) {
      try {
        response.statusCode = HttpStatus.internalServerError;
        await response.close();
      } catch (_) {}
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

  /// 校验 HTTP `If-Range` 请求头是否命中当前会话 ETag（不匹配时应回退 200 全量流）。
  static bool _matchesIfRange(String? ifRangeHeader, String sessionEtag) {
    if (ifRangeHeader == null || ifRangeHeader.trim().isEmpty) {
      return true;
    }
    String normalizeTag(String raw) {
      var trimmed = raw.trim();
      if (trimmed.startsWith('W/') || trimmed.startsWith('w/')) {
        trimmed = trimmed.substring(2).trim();
      }
      if (trimmed.length >= 2 &&
          trimmed.startsWith('"') &&
          trimmed.endsWith('"')) {
        trimmed = trimmed.substring(1, trimmed.length - 1);
      }
      return trimmed;
    }

    return normalizeTag(ifRangeHeader) == normalizeTag(sessionEtag);
  }

  /// 拆离底层回环套接字以实时监听对端 `FIN/RST` 断连信号，在下游主动取消或 Seek 中断时即时取消上游流。
  Future<void> _streamChunksWithAbort(
    Stream<List<int>> source,
    HttpResponse response,
  ) async {
    response.persistentConnection = false;
    response.headers.chunkedTransferEncoding = false;
    final socket = await response.detachSocket(writeHeaders: true);
    try {
      socket.setOption(SocketOption.tcpNoDelay, true);
    } catch (_) {}

    final iterator = StreamIterator<List<int>>(source);
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

      const flushThresholdBytes = 256 * 1024;
      var unflushedBytes = 0;
      while (true) {
        final hasNext = await Future.any<bool>([
          iterator.moveNext(),
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
          continue;
        }
        socket.add(chunk);
        unflushedBytes += chunk.length;
        if (unflushedBytes >= flushThresholdBytes) {
          unflushedBytes = 0;
          await socket.flush();
        }
      }
    } on SocketException {
      // 播放器触发 Seek 或关闭时主动断开连接，属正常现象。
    } on HttpException {
      // 客户端连接中断。
    } finally {
      try {
        await iterator.cancel();
      } catch (_) {}
      try {
        await peerSub?.cancel();
      } catch (_) {}
      if (completedNormally) {
        try {
          await socket.flush();
          await socket.close();
        } catch (_) {}
      } else {
        try {
          socket.destroy();
        } catch (_) {}
      }
    }
  }

  String _guessMimeType(String fileName) {
    switch (p.posix.extension(fileName).toLowerCase()) {
      case '.mkv':
        return 'video/x-matroska';
      case '.mp4':
      case '.m4v':
        return 'video/mp4';
      case '.webm':
        return 'video/webm';
      case '.avi':
        return 'video/x-msvideo';
      case '.ts':
      case '.m2ts':
        return 'video/mp2t';
      case '.flac':
        return 'audio/flac';
      case '.wav':
        return 'audio/wav';
      case '.mp3':
        return 'audio/mpeg';
      case '.m4a':
      case '.aac':
      case '.alac':
        return 'audio/mp4';
      case '.ogg':
      case '.opus':
        return 'audio/ogg';
      case '.mka':
        return 'audio/x-matroska';
      case '.tak':
      case '.tta':
        return 'application/octet-stream';
      default:
        return 'application/octet-stream';
    }
  }

  /// 关闭回环流服务并清理所有会话与定时器。
  Future<void> dispose() async {
    _reaperTimer?.cancel();
    _reaperTimer = null;
    final tokens = _sessions.keys.toList(growable: false);
    for (final token in tokens) {
      await unregisterSession(token);
    }
    final server = _server;
    _server = null;
    if (server != null) {
      await server.close(force: true);
    }
  }
}
