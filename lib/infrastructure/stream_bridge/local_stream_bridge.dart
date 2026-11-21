import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../domain/models/media_extensions.dart';
import '../../domain/models/media_source.dart';
import '../../domain/playback/cue_and_lrc_parser.dart';
import '../sources/byte_stream_source_gateway.dart';
import '../sources/source_access_error.dart';
import '../sources/subtitle_matcher.dart';
import '../storage/atomic_file_writer.dart';
import '../storage/storage_root_provider.dart';
import 'http_byte_range.dart';
import 'remote_window_reader.dart';

part 'local_stream_bridge_album.dart';

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

/// 经同卷 `.part` 校验并原子落盘的原始外挂字幕缓存记录。
class MaterializedSubtitleRecord {
  /// 创建原始字幕缓存记录。
  const MaterializedSubtitleRecord({
    required this.relativePath,
    required this.localFilePath,
    required this.sourceSha1,
    required this.byteLength,
    required this.cacheKey,
    this.validator = '',
  });

  /// 媒体源中的原始相对路径。
  final String relativePath;

  /// 本地应用便携缓存目录中的原子落盘绝对路径。
  final String localFilePath;

  /// 原始字幕字节流的 SHA-1 十六进制摘要（供后续处理与云端子集去重）。
  final String sourceSha1;

  /// 校验后的实际字节长度。
  final int byteLength;

  /// 绑定 `(sourceId, canonicalRelativePath, validator)` 的缓存键。
  final String cacheKey;

  /// 源版本验证器（如强 ETag、修改时间或探测字节长度）。
  final String validator;
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
  String? lastDiagnosticError;
  SourceAccessProblemKind? lastDiagnosticKind;
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
  final Map<String, _VirtualAlbumDirectorySession> _albumSessions = {};
  final Map<String, String> _recentErrorsByPath = {};
  final Map<String, String> _recentErrorsByToken = {};
  final Map<String, SourceAccessProblemKind> _recentKindsByPath = {};
  final Map<String, SourceAccessProblemKind> _recentKindsByToken = {};
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

  /// 查询指定流令牌或相对路径最近一次捕获的上游访问故障中文说明。
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

  /// 查询指定流令牌或相对路径最近一次捕获的上游故障分类（用于区分源离线/鉴权/404 与解码故障）。
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

  /// 当前监听端口号（未启动时返回 `null`）。
  int? get port => _server?.port;

  /// 当前仍处于注册状态的流会话令牌数量（用于测试与诊断）。
  int get activeSessionCount => _sessions.length + _albumSessions.length;

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
    // 会话级强 ETag：禁止将弱 ETag 用于 If-Range 的强校验。
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
    session?.windowReader?.clear();
    if (session != null && session.ownsGateway) {
      try {
        await session.gateway.close();
      } catch (error) {
      developer.log('可恢复异常已记录', name: 'konata.local_stream_bridge', error: error);
    }
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

  /// 构造绑定 `(sourceId, canonicalRelativePath, sourceValidator)` 的原始字幕缓存定位键。
  static String buildSubtitleCacheKey({
    required String sourceId,
    required String relativePath,
    String validator = '',
  }) {
    final canonical = canonicalizeSubtitleRelativePath(relativePath);
    return '$sourceId\x00$canonical\x00$validator';
  }

  static String _subtitlePathBucket(String sourceId, String canonicalRelPath) {
    return sha1
        .convert(utf8.encode('$sourceId\x00$canonicalRelPath'))
        .toString()
        .substring(0, 16);
  }

  static String _subtitleVersionBucket(String validator) {
    if (validator.isEmpty) return 'v_default';
    final digest = sha1.convert(utf8.encode(validator)).toString();
    return 'v_${digest.substring(0, 12)}';
  }

  /// 纯本地零网络检查已缓存落盘的外挂字幕路径（供远程视频首帧零网络秒挂已有字幕）。
  ///
  /// 缓存定位键严格绑定 `(sourceId, canonicalRelativePath, validator)`，消除跨季/跨集同名串用。
  Future<List<String>> resolveExistingCachedSubtitles({
    required String workId,
    required List<String> subtitleRelativePaths,
    String? sourceId,
    Map<String, String>? validatorsByPath,
  }) async {
    if (subtitleRelativePaths.isEmpty) return const [];
    final dirHash = sha1
        .convert(utf8.encode(workId))
        .toString()
        .substring(0, 12);
    final targetDir = await _storageRoot.ensureSubtitleStageDir(dirHash);
    final resolvedSourceId = (sourceId == null || sourceId.isEmpty)
        ? workId
        : sourceId;
    final hits = <String>[];
    for (final relPath in subtitleRelativePaths) {
      final canonical = canonicalizeSubtitleRelativePath(relPath);
      final baseName = p.posix.basename(canonical);
      if (!SubtitleMatcher.isSubtitleFile(baseName)) continue;

      final pathBucketDir = Directory(
        p.join(targetDir.path, _subtitlePathBucket(resolvedSourceId, canonical)),
      );
      if (!await pathBucketDir.exists()) continue;

      final explicitValidator = validatorsByPath?[relPath]?.trim();
      if (explicitValidator != null && explicitValidator.isNotEmpty) {
        final destFile = File(
          p.join(
            pathBucketDir.path,
            _subtitleVersionBucket(explicitValidator),
            baseName,
          ),
        );
        if (await _isValidCachedSubtitleFile(destFile)) {
          hits.add(destFile.path);
        }
        continue;
      }

      // 未显式提供源版本验证器时，仅在当前 (sourceId, canonicalRelativePath) 隔离桶内检索最新有效文件。
      final defaultFile = File(
        p.join(pathBucketDir.path, 'v_default', baseName),
      );
      if (await _isValidCachedSubtitleFile(defaultFile)) {
        hits.add(defaultFile.path);
        continue;
      }

      File? newestCandidate;
      DateTime? newestMtime;
      await for (final entity in pathBucketDir.list(followLinks: false)) {
        if (entity is! Directory) continue;
        final candidate = File(p.join(entity.path, baseName));
        if (!await _isValidCachedSubtitleFile(candidate)) continue;
        final stat = await candidate.stat();
        if (newestMtime == null || stat.modified.isAfter(newestMtime)) {
          newestMtime = stat.modified;
          newestCandidate = candidate;
        }
      }
      if (newestCandidate != null) {
        hits.add(newestCandidate.path);
      }
    }
    return hits;
  }

  Future<bool> _isValidCachedSubtitleFile(File file) async {
    if (!await file.exists()) return false;
    final len = await file.length();
    return len > 0 && len <= StreamBridgeConfig.maxSubtitleMaterializeBytes;
  }

  /// 将远程源中的外挂字幕文件并发拉取并经同卷 `.part` 校验后原子落盘，返回本地路径列表。
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

  /// 将远程源中的外挂字幕文件经同卷 `.part` 完整性校验后原子 `rename` 落盘，并计算 `<srcSha1>`。
  ///
  /// 缓存路径严格绑定 `(sourceId, canonicalRelativePath, validator)`，保证同作品跨季同名零串用、
  /// 网络中断半包零污染。
  Future<List<MaterializedSubtitleRecord>> materializeRemoteSubtitleRecords({
    required ByteRangeReadableGateway gateway,
    required String workId,
    required List<String> subtitleRelativePaths,
    String? sourceId,
    Map<String, String>? validatorsByPath,
  }) async {
    if (subtitleRelativePaths.isEmpty) return const [];
    final dirHash = sha1
        .convert(utf8.encode(workId))
        .toString()
        .substring(0, 12);
    final targetDir = await _storageRoot.ensureSubtitleStageDir(dirHash);
    final resolvedSourceId = (sourceId == null || sourceId.isEmpty)
        ? workId
        : sourceId;

    final results = await Future.wait(
      subtitleRelativePaths.asMap().entries.map((entry) async {
        final relPath = entry.value;
        final canonical = canonicalizeSubtitleRelativePath(relPath);
        final baseName = p.posix.basename(canonical);
        if (!SubtitleMatcher.isSubtitleFile(baseName)) {
          return null;
        }

        int? probedLen;
        String? probedValidator;
        final explicitValidator = validatorsByPath?[relPath]?.trim() ?? '';
        try {
          if (gateway is FileValidatorProbeGateway) {
            final meta = await gateway.probeFileMetadata(relPath);
            probedLen = meta.length;
            probedValidator = meta.validator?.trim();
          } else {
            probedLen = await gateway.probeFileLength(relPath);
          }
          if (probedLen != null &&
              probedLen > StreamBridgeConfig.maxSubtitleMaterializeBytes) {
            return null;
          }
        } on Object catch (error) {
  // 探测失败时继续尝试直接拉取校验，避免禁用 HEAD 的远端源阻断字幕下载。
  developer.log('可恢复异常已记录', name: 'konata.local_stream_bridge', error: error);
}

        final effectiveValidator = explicitValidator.isNotEmpty
            ? explicitValidator
            : ((probedValidator != null && probedValidator.isNotEmpty)
                  ? probedValidator
                  : (probedLen != null && probedLen > 0
                        ? 'len:$probedLen'
                        : ''));
        final cacheKey = buildSubtitleCacheKey(
          sourceId: resolvedSourceId,
          relativePath: canonical,
          validator: effectiveValidator,
        );
        final pathBucket = _subtitlePathBucket(resolvedSourceId, canonical);
        final versionBucket = _subtitleVersionBucket(effectiveValidator);
        final versionDir = Directory(
          p.join(targetDir.path, pathBucket, versionBucket),
        );
        final destFile = File(p.join(versionDir.path, baseName));

        // 命中同键且字节完整的已落盘缓存直接计算 SHA-1 返回，零重复下载。
        if (await destFile.exists()) {
          final existingLen = await destFile.length();
          final lenMatches =
              probedLen == null || probedLen <= 0 || existingLen == probedLen;
          if (existingLen > 0 &&
              existingLen <= StreamBridgeConfig.maxSubtitleMaterializeBytes &&
              lenMatches) {
            final digest = await _computeFileSha1(destFile);
            return MaterializedSubtitleRecord(
              relativePath: relPath,
              localFilePath: destFile.path,
              sourceSha1: digest,
              byteLength: existingLen,
              cacheKey: cacheKey,
              validator: effectiveValidator,
            );
          }
        }

        await versionDir.create(recursive: true);
        final uniqueSuffix =
            '${DateTime.now().microsecondsSinceEpoch}_${entry.key}';
        final partFile = File('${destFile.path}.part.$uniqueSuffix');
        final digestSink = _SingleDigestSink();
        final sha1Input = sha1.startChunkedConversion(digestSink);
        final sink = partFile.openWrite();
        var writtenBytes = 0;
        var failed = false;
        String? streamValidator;
        try {
          Stream<List<int>> stream;
          if (gateway is ValidatedByteRangeGateway &&
              explicitValidator.isEmpty &&
              (probedValidator == null || probedValidator.isEmpty)) {
            final validated = await gateway.openValidatedByteRange(
              relPath,
              start: 0,
            );
            streamValidator = validated.strongValidator?.trim();
            stream = validated.stream;
          } else {
            stream = await gateway.openByteRange(relPath, start: 0);
          }
          await for (final chunk in stream) {
            if (chunk.isEmpty) continue;
            writtenBytes += chunk.length;
            if (writtenBytes > StreamBridgeConfig.maxSubtitleMaterializeBytes) {
              failed = true;
              break;
            }
            sink.add(chunk);
            sha1Input.add(chunk);
          }
          if (!failed) {
            await sink.flush();
          }
        } on Object {
          failed = true;
        } finally {
          await sink.close();
          sha1Input.close();
        }

        final lengthValid =
            writtenBytes > 0 &&
            writtenBytes <= StreamBridgeConfig.maxSubtitleMaterializeBytes &&
            (probedLen == null || probedLen <= 0 || writtenBytes == probedLen);
        final srcDigest = digestSink.digest;
        if (failed || !lengthValid || srcDigest == null) {
          if (await partFile.exists()) {
            await partFile.delete().catchError((_) => partFile);
          }
          return null;
        }

        var finalValidator = effectiveValidator;
        var finalCacheKey = cacheKey;
        var finalDestFile = destFile;
        if (explicitValidator.isEmpty &&
            (probedValidator == null || probedValidator.isEmpty) &&
            streamValidator != null &&
            streamValidator.isNotEmpty &&
            streamValidator != effectiveValidator) {
          finalValidator = streamValidator;
          finalCacheKey = buildSubtitleCacheKey(
            sourceId: resolvedSourceId,
            relativePath: canonical,
            validator: finalValidator,
          );
          final upgradedDir = Directory(
            p.join(
              targetDir.path,
              pathBucket,
              _subtitleVersionBucket(finalValidator),
            ),
          );
          await upgradedDir.create(recursive: true);
          finalDestFile = File(p.join(upgradedDir.path, baseName));
        }

        try {
          // 同卷安全原子替换发布（兼容 Windows 目标文件已存在与并发覆盖场景）。
          await AtomicFileWriter.replaceFile(
            partFile,
            finalDestFile,
            expectedLength: writtenBytes,
          );
        } on Object {
          if (await partFile.exists()) {
            await partFile.delete().catchError((_) => partFile);
          }
          return null;
        }

        return MaterializedSubtitleRecord(
          relativePath: relPath,
          localFilePath: finalDestFile.path,
          sourceSha1: srcDigest.toString(),
          byteLength: writtenBytes,
          cacheKey: finalCacheKey,
          validator: finalValidator,
        );
      }),
    );

    return results
        .whereType<MaterializedSubtitleRecord>()
        .toList(growable: false);
  }

  Future<String> _computeFileSha1(File file) async {
    final digestSink = _SingleDigestSink();
    final input = sha1.startChunkedConversion(digestSink);
    await for (final chunk in file.openRead()) {
      input.add(chunk);
    }
    input.close();
    return digestSink.digest?.toString() ?? '';
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
      } catch (error) {
      developer.log('可恢复异常已记录', name: 'konata.local_stream_bridge', error: error);
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

  /// 校验 HTTP `If-Range` 请求头是否命中当前会话 ETag（不匹配时应回退 200 全量流）。
  static bool _matchesIfRange(String? ifRangeHeader, String sessionEtag) {
    if (ifRangeHeader == null || ifRangeHeader.trim().isEmpty) {
      return true;
    }
    // RFC 9110: If-Range 必须使用强验证器；不接受弱标签或日期。
    final tag = ifRangeHeader.trim();
    return !tag.startsWith('W/') && tag == sessionEtag;
  }

  /// 拆离底层回环套接字以实时监听对端 `FIN/RST` 断连信号，在下游主动取消或 Seek 中断时即时取消上游流。
  ///
  /// 关键语义：先等待上游首个数据块就绪再发送 `200/206` 响应头，避免 WebDAV/SMB 离线或 401/404 时
  /// 提前向 `libmpv` 回传 200 并静默吞掉上游 `SocketException` 导致只剩裸错码 `-17`。
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
      developer.log('可恢复异常已记录', name: 'konata.local_stream_bridge', error: error);
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
        final hasNext = await Future.any<bool>([nextMove, disconnected.future]);
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
      developer.log('流传输连接异常已记录', name: 'konata.local_stream_bridge', error: error);
    } on HttpException catch (error) {
      if (!disconnected.isCompleted) {
        _recordDiagnostic(session, error);
      }
      developer.log('流传输 HTTP 异常已记录', name: 'konata.local_stream_bridge', error: error);
    } catch (error) {
      if (!disconnected.isCompleted) {
        _recordDiagnostic(session, error);
      }
      developer.log('流传输上游异常已记录', name: 'konata.local_stream_bridge', error: error);
    } finally {
      try {
        await iterator.cancel();
      } catch (error) {
      developer.log('可恢复异常已记录', name: 'konata.local_stream_bridge', error: error);
    }
      try {
        await peerSub?.cancel();
      } catch (error) {
      developer.log('可恢复异常已记录', name: 'konata.local_stream_bridge', error: error);
    }
      if (completedNormally) {
        try {
          await socket.flush();
          await socket.close();
        } catch (error) {
      developer.log('可恢复异常已记录', name: 'konata.local_stream_bridge', error: error);
    }
      } else {
        try {
          socket.destroy();
        } catch (error) {
      developer.log('可恢复异常已记录', name: 'konata.local_stream_bridge', error: error);
    }
      }
    }
  }

  String _guessMimeType(String fileName) =>
      KonataMediaExtensions.mimeTypeFor(fileName);

  /// 关闭回环流服务并清理所有会话与定时器。
  Future<void> dispose() async {
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
}
