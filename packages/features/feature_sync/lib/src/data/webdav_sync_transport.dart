import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:engine_sources/engine_sources.dart';
import 'package:http/http.dart' as http;
import 'package:konata_contracts/konata_contracts.dart';

import 'sync_models.dart';

/// WebDAV 同步传输异常（错误文本已自动经过凭据脱敏清洗）。
final class WebDavSyncException implements Exception {
  /// 创建 WebDAV 同步异常。
  const WebDavSyncException(this.message, {this.statusCode});

  /// 脱敏后的中文错误说明。
  final String message;

  /// 关联 HTTP 状态码（网络层失败时为空）。
  final int? statusCode;

  @override
  String toString() => statusCode == null
      ? 'WebDavSyncException: $message'
      : 'WebDavSyncException($statusCode): $message';
}

/// 清单及其 HTTP 写入前置条件；不存在时只能使用 If-None-Match 创建。
final class WebDavManifestSnapshot {
  /// 保留读取时的强 ETag，避免覆盖其他设备随后发布的清单。
  const WebDavManifestSnapshot(
    this.manifest, {
    required this.exists,
    this.etag,
  });

  /// 当前清单内容。
  final WebDavSyncManifest manifest;

  /// 远端是否已有清单。
  final bool exists;

  /// 读取时的强实体标记（服务器可能不提供）。
  final String? etag;

  /// 不允许降级为无条件写入。
  void requireWritable() {
    final tag = etag;
    if (exists && (tag == null || !RegExp(r'^"[^"]*"$').hasMatch(tag))) {
      throw const WebDavSyncException('服务器未提供强 ETag，无法安全更新同步清单');
    }
  }
}

/// 远端分片下载与校验返回包。
final class DownloadedSliceShard {
  /// 创建远端分片下载结果。
  const DownloadedSliceShard({required this.watermark, required this.payload});

  /// 远端清单水位条目标记。
  final WebDavSliceWatermark watermark;

  /// 解析并通过 `SHA-256` 校验的切片载荷。
  final SyncSlicePayload payload;
}

/// WebDAV 多设备分片同步底层 HTTP 传输层（基于 `engine_sources` 复用连接池与认证逻辑，同时支持注入 `http.Client` 便于离线单测）。
///
/// 远端目录结构严格固定为：
/// - `<remoteDir>/manifest.json`
/// - `<remoteDir>/slices/<sliceId>_<deviceId>_<sha256>.json.gz`
final class WebDavSyncTransport {
  /// 创建 WebDAV 同步传输器。
  WebDavSyncTransport({
    WebDavConnectionPool? connectionPool,
    this._clientFactory,
    this._requestTimeout = WebDavGatewayConfig.defaultRequestTimeout,
  }) : _effectivePool = connectionPool ?? WebDavConnectionPool();

  /// 远端总清单固定文件名。
  static const String manifestFileName = 'manifest.json';

  /// 远端切片压缩分片固定子目录名。
  static const String slicesDirectoryName = 'slices';

  /// 清单只记录设备与切片水位，不含目录正文。
  static const int maxManifestBytes = 4 * 1024 * 1024;

  /// 压缩分片安全上限。
  static const int maxShardBytes = 32 * 1024 * 1024;

  /// 解压正文安全上限，防止异常远端内容耗尽设备内存。
  static const int maxDecodedShardBytes = 128 * 1024 * 1024;

  final WebDavConnectionPool _effectivePool;
  final http.Client Function(WebDavSyncConfig config)? _clientFactory;
  final Duration _requestTimeout;

  /// 新分片采用内容版本路径；已发布的旧分片不能被新数据覆盖。
  static String buildShardRelativePath({
    required String sliceId,
    required String deviceId,
    required String sha256,
  }) {
    final safeSlice = _sanitizePathSegment(sliceId);
    final safeDevice = _sanitizePathSegment(deviceId);
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(sha256)) {
      throw ArgumentError('无效的分片 SHA-256');
    }
    return '$slicesDirectoryName/${safeSlice}_${safeDevice}_$sha256.json.gz';
  }

  /// 解析远程基准 URI 与归一化同步根目录，构造目标接口完整地址。
  static Uri resolveRelativeUri(WebDavSyncConfig config, String relativePath) {
    final baseUri = _parseValidatedBaseUri(config.baseUrl);
    final remoteSegments = config.normalizedRemoteDir
        .split('/')
        .where((s) => s.isNotEmpty);
    final relSegments = SyncSanitizer.normalizeRelativePath(
      relativePath,
    ).split('/').where((s) => s.isNotEmpty);

    final segments = <String>[
      ...baseUri.pathSegments.where((s) => s.isNotEmpty),
      ...remoteSegments,
      ...relSegments,
    ];
    return baseUri.replace(pathSegments: segments, queryParameters: null);
  }

  /// 校验服务器配置并确保同步目录结构（`<remoteDir>` 与 `<remoteDir>/slices`）存在。
  Future<void> testConnection(WebDavSyncConfig config) async {
    _parseValidatedBaseUri(config.baseUrl);
    await ensureSyncDirectories(config);
    final manifest = await fetchManifest(config);
    manifest.requireWritable();
    await _verifyWriteAccess(config);
  }

  /// 使用同步分片目录中的独立随机测试文件验证读写权限，绝不修改清单或已发布分片。
  Future<void> _verifyWriteAccess(WebDavSyncConfig config) async {
    final random = Random.secure();
    final token = List.generate(
      16,
      (_) => random.nextInt(256),
    ).map((value) => value.toRadixString(16).padLeft(2, '0')).join();
    final uri = resolveRelativeUri(
      config,
      '$slicesDirectoryName/konata-probe-$token.json.gz',
    );
    final bytes = gzip.encode(utf8.encode(jsonEncode({'probe': token})));
    final uploaded = await _sendWithAuth(
      config: config,
      method: 'PUT',
      uri: uri,
      headers: const {
        HttpHeaders.contentTypeHeader: 'application/gzip',
        'If-None-Match': '*',
      },
      body: bytes,
    );
    if (uploaded.statusCode < 200 || uploaded.statusCode >= 300) {
      throw _buildHttpException('服务器不允许写入同步目录', uploaded.statusCode);
    }
    try {
      final downloaded = await _sendWithAuth(
        config: config,
        method: 'GET',
        uri: uri,
      );
      if (downloaded.statusCode != 200) {
        throw _buildHttpException('无法读取同步测试文件', downloaded.statusCode);
      }
      if (downloaded.bodyBytes.length != bytes.length ||
          !List.generate(
            bytes.length,
            (i) => i,
          ).every((i) => bytes[i] == downloaded.bodyBytes[i])) {
        throw const WebDavSyncException('同步测试文件内容与上传内容不一致');
      }
    } finally {
      final deleted = await _sendWithAuth(
        config: config,
        method: 'DELETE',
        uri: uri,
      );
      if ((deleted.statusCode < 200 || deleted.statusCode >= 300) &&
          deleted.statusCode != 404) {
        throw _buildHttpException('无法清理独立的同步测试文件', deleted.statusCode);
      }
    }
  }

  /// 逐级 `MKCOL` 创建同步根目录及 `slices/` 子目录（幂等容忍已存在）。
  Future<void> ensureSyncDirectories(WebDavSyncConfig config) async {
    final baseUri = _parseValidatedBaseUri(config.baseUrl);
    final baseSegments = baseUri.pathSegments
        .where((s) => s.isNotEmpty)
        .toList();
    final syncSegments = <String>[
      ...config.normalizedRemoteDir.split('/').where((s) => s.isNotEmpty),
      slicesDirectoryName,
    ];

    final current = List<String>.of(baseSegments);
    for (final segment in syncSegments) {
      current.add(segment);
      final dirUri = baseUri.replace(
        pathSegments: <String>[...current, ''],
        queryParameters: null,
      );
      final res = await _sendWithAuth(
        config: config,
        method: 'MKCOL',
        uri: dirUri,
      );
      if (res.statusCode == 200 ||
          res.statusCode == 201 ||
          res.statusCode == 204) {
        continue;
      }
      // 405 可表示目录已存在，也可能是服务端禁止写入；必须确认目标确实可访问。
      if (res.statusCode == 405 || res.statusCode == 409) {
        final probe = await _sendWithAuth(
          config: config,
          method: 'PROPFIND',
          uri: dirUri,
          headers: const {'Depth': '0'},
        );
        if (probe.statusCode == 207) continue;
      }
      if (res.statusCode == 401 || res.statusCode == 403) {
        throw WebDavSyncException(
          'WebDAV 鉴权失败（HTTP ${res.statusCode}），请检查账号或应用密码',
          statusCode: res.statusCode,
        );
      }
      throw WebDavSyncException(
        '无法在 WebDAV 上准备同步目录（HTTP ${res.statusCode}）',
        statusCode: res.statusCode,
      );
    }
  }

  /// 读取远端 `manifest.json`；若首次同步尚不存在则返回空清单。
  Future<WebDavManifestSnapshot> fetchManifest(WebDavSyncConfig config) async {
    final uri = resolveRelativeUri(config, manifestFileName);
    final res = await _sendWithAuth(config: config, method: 'GET', uri: uri);
    if (res.statusCode == 404) {
      return const WebDavManifestSnapshot(WebDavSyncManifest(), exists: false);
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw _buildHttpException('读取同步清单失败', res.statusCode);
    }

    final String bodyText;
    try {
      bodyText = utf8.decode(res.bodyBytes);
    } catch (_) {
      throw const WebDavSyncException('远端 manifest.json 编码无效');
    }
    if (bodyText.trim().isEmpty) {
      throw const WebDavSyncException('远端 manifest.json 内容为空，已终止同步');
    }

    final dynamic decoded;
    try {
      decoded = jsonDecode(bodyText);
    } catch (_) {
      throw const WebDavSyncException('远端 manifest.json 格式损坏');
    }
    if (decoded is! Map) {
      throw const WebDavSyncException('远端 manifest.json 结构无效');
    }
    return WebDavManifestSnapshot(
      WebDavSyncManifest.fromJson(SyncSanitizer.coerceStringKeyMap(decoded)),
      exists: true,
      etag: _readCaseInsensitiveHeader(res.headers, 'etag'),
    );
  }

  /// 条件发布远端清单；HTTP 412 表示快照失效，调用方必须重读合并。
  Future<void> uploadManifest(
    WebDavSyncConfig config,
    WebDavSyncManifest manifest, {
    required WebDavManifestSnapshot expected,
  }) async {
    expected.requireWritable();
    final uri = resolveRelativeUri(config, manifestFileName);
    final body = utf8.encode(jsonEncode(manifest.toJson()));
    if (body.length > maxManifestBytes) {
      throw const WebDavSyncException('同步清单超过 4 MiB 安全上限');
    }
    final res = await _sendWithAuth(
      config: config,
      method: 'PUT',
      uri: uri,
      headers: <String, String>{
        HttpHeaders.contentTypeHeader: 'application/json; charset=utf-8',
        if (expected.exists)
          'If-Match': expected.etag!
        else
          'If-None-Match': '*',
      },
      body: body,
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw _buildHttpException('更新远端 manifest.json 失败', res.statusCode);
    }
  }

  /// 下载并解压校验单个远端切片分片（`.json.gz`）。
  Future<DownloadedSliceShard> downloadSliceShard(
    WebDavSyncConfig config,
    WebDavSliceWatermark watermark,
  ) async {
    _validateShardPath(watermark);
    final uri = resolveRelativeUri(config, watermark.shardPath);
    final res = await _sendWithAuth(config: config, method: 'GET', uri: uri);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw _buildHttpException(
        '下载同步切片 `${watermark.sliceId}` 失败',
        res.statusCode,
      );
    }
    if (res.bodyBytes.isEmpty) {
      throw WebDavSyncException('远端切片 `${watermark.sliceId}` 内容为空');
    }

    final List<int> jsonBytes;
    if (res.bodyBytes.length >= 2 &&
        res.bodyBytes[0] == 0x1f &&
        res.bodyBytes[1] == 0x8b) {
      try {
        final output = _BoundedShardSink();
        final decoder = gzip.decoder.startChunkedConversion(output);
        const chunkSize = 16 * 1024;
        for (var start = 0; start < res.bodyBytes.length; start += chunkSize) {
          final end = (start + chunkSize).clamp(0, res.bodyBytes.length);
          decoder.add(Uint8List.sublistView(res.bodyBytes, start, end));
        }
        decoder.close();
        jsonBytes = output.takeBytes();
      } on WebDavSyncException {
        rethrow;
      } catch (_) {
        throw WebDavSyncException('远端切片 ${watermark.sliceId} 解压失败');
      }
    } else {
      jsonBytes = res.bodyBytes;
    }

    final dynamic decoded;
    try {
      decoded = jsonDecode(utf8.decode(jsonBytes));
    } catch (_) {
      throw WebDavSyncException('远端切片 `${watermark.sliceId}` JSON 解析失败');
    }
    if (decoded is! Map) {
      throw WebDavSyncException('远端切片 `${watermark.sliceId}` 结构无效');
    }

    final root = SyncSanitizer.coerceStringKeyMap(decoded);
    final rawData = root['data'];
    if (rawData is! Map) {
      throw WebDavSyncException('远端切片 `${watermark.sliceId}` 缺少 data 载荷');
    }

    if (root['sliceId'] != watermark.sliceId ||
        root['schemaVersion'] != watermark.schemaVersion ||
        root['sourceDeviceId'] != watermark.deviceId) {
      throw const WebDavSyncException('远端切片身份与清单不一致，已终止合并');
    }
    final sliceId = watermark.sliceId;
    final schemaVersion = watermark.schemaVersion;
    final data = Map<String, Object?>.unmodifiable(
      SyncSanitizer.coerceStringKeyMap(rawData),
    );
    final actualSha = SyncSanitizer.computeSliceDataSha256(
      sliceId: sliceId,
      schemaVersion: schemaVersion,
      data: data,
    );
    if (watermark.sha256.isNotEmpty && actualSha != watermark.sha256) {
      throw WebDavSyncException('远端切片 `$sliceId` SHA-256 校验失败，已终止合并');
    }

    final payload = SyncSlicePayload(
      sliceId: sliceId,
      schemaVersion: schemaVersion,
      exportedAtMs:
          (root['exportedAtMs'] as num?)?.toInt() ?? watermark.updatedAtMs,
      sourceDeviceId: (root['sourceDeviceId'] ?? watermark.deviceId).toString(),
      data: data,
    );
    return DownloadedSliceShard(watermark: watermark, payload: payload);
  }

  /// 压缩并上传本机单个切片分片（`slices/<sliceId>_<deviceId>_<sha256>.json.gz`）。
  Future<void> uploadSliceShard({
    required WebDavSyncConfig config,
    required WebDavSliceWatermark watermark,
    required SyncSlicePayload payload,
  }) async {
    _validateShardPath(watermark);
    final uri = resolveRelativeUri(config, watermark.shardPath);
    final envelope = <String, Object?>{
      ...payload.toJson(),
      'sha256': watermark.sha256,
    };
    final rawBytes = utf8.encode(jsonEncode(envelope));
    if (rawBytes.length > maxDecodedShardBytes) {
      throw const WebDavSyncException('同步分片解压后超过 128 MiB 安全上限');
    }
    final gzBytes = gzip.encode(rawBytes);
    if (gzBytes.length > maxShardBytes) {
      throw const WebDavSyncException('同步分片超过 32 MiB 安全上限');
    }
    final res = await _sendWithAuth(
      config: config,
      method: 'PUT',
      uri: uri,
      headers: const <String, String>{
        HttpHeaders.contentTypeHeader: 'application/gzip',
        'If-None-Match': '*',
      },
      body: gzBytes,
    );
    if (res.statusCode == 412 || res.statusCode == 405) {
      // 内容寻址分片不可覆盖；拒绝重复创建时，仅允许复用身份和哈希均一致的远端内容。
      try {
        await downloadSliceShard(config, watermark);
        return;
      } on WebDavSyncException catch (error) {
        if (res.statusCode == 412) rethrow;
        throw WebDavSyncException(
          '服务器拒绝上传同步数据，且无法确认已有数据完整。请检查同步目录写入权限（HTTP 405）。${error.statusCode == null ? ' 已有数据校验失败。' : ''}',
          statusCode: 405,
        );
      }
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw _buildHttpException('上传同步数据失败', res.statusCode);
    }
  }

  Future<http.Response> _sendWithAuth({
    required WebDavSyncConfig config,
    required String method,
    required Uri uri,
    Map<String, String> headers = const <String, String>{},
    List<int>? body,
  }) async {
    final pool = _effectivePool;
    final rootUri = _parseValidatedBaseUri(config.baseUrl);
    final username = config.username.trim();
    final password = config.password;
    final ownsClient = _clientFactory != null;
    final client = ownsClient
        ? _clientFactory(config)
        : pool.acquireClient(
            rootUri: rootUri,
            username: username,
            password: password,
          );

    try {
      String? authHeader;
      if (username.isNotEmpty || password.isNotEmpty) {
        final cachedDigest = pool.readDigestChallenge(
          rootUri: rootUri,
          username: username,
          password: password,
        );
        if (cachedDigest != null) {
          authHeader = WebDavDigestAuth.buildAuthorizationHeader(
            wwwAuthenticateHeader: cachedDigest,
            method: method,
            uri: uri,
            username: username,
            password: password,
          );
        }
        authHeader ??= _buildBasicAuthHeader(username, password);
      }

      var response = await _executeSingleRequest(
        client: client,
        method: method,
        uri: uri,
        headers: headers,
        authHeader: authHeader,
        body: body,
      );

      if (response.statusCode == 401 &&
          (username.isNotEmpty || password.isNotEmpty)) {
        final challenge = _readCaseInsensitiveHeader(
          response.headers,
          'www-authenticate',
        );
        if (challenge != null && challenge.toLowerCase().contains('digest')) {
          pool.rememberDigestChallenge(
            rootUri: rootUri,
            username: username,
            password: password,
            challenge: challenge,
          );
          final digestHeader = WebDavDigestAuth.buildAuthorizationHeader(
            wwwAuthenticateHeader: challenge,
            method: method,
            uri: uri,
            username: username,
            password: password,
          );
          if (digestHeader != null) {
            response = await _executeSingleRequest(
              client: client,
              method: method,
              uri: uri,
              headers: headers,
              authHeader: digestHeader,
              body: body,
            );
          }
        }
      }

      return response;
    } on WebDavSyncException {
      rethrow;
    } catch (error) {
      throw WebDavSyncException(
        NetworkErrorSanitizer.toUserMessage(error, prefix: 'WebDAV 请求失败'),
      );
    } finally {
      if (ownsClient) {
        client.close();
      }
    }
  }

  Future<http.Response> _executeSingleRequest({
    required http.Client client,
    required String method,
    required Uri uri,
    required Map<String, String> headers,
    required String? authHeader,
    required List<int>? body,
  }) async {
    var currentUri = uri;
    for (var hop = 0; hop <= WebDavGatewayConfig.maxRedirects; hop++) {
      final req = http.Request(method, currentUri)
        ..followRedirects = false
        ..headers[HttpHeaders.userAgentHeader] =
            WebDavGatewayConfig.defaultUserAgent;
      req.headers.addAll(headers);
      if (authHeader != null && authHeader.isNotEmpty) {
        req.headers[HttpHeaders.authorizationHeader] = authHeader;
      }
      if (body != null) {
        req.bodyBytes = body;
      }

      final streamed = await client.send(req).timeout(_requestTimeout);
      final isShard = method == 'GET' && uri.path.endsWith('.json.gz');
      final response = await _readBoundedResponse(
        streamed,
        isShard ? maxShardBytes : maxManifestBytes,
        isShard ? '同步分片超过 32 MiB 安全上限' : '同步响应超过 4 MiB 安全上限',
      );
      if (_isRedirect(response.statusCode)) {
        final location = _readCaseInsensitiveHeader(
          response.headers,
          'location',
        );
        if (location != null &&
            location.trim().isNotEmpty &&
            hop < WebDavGatewayConfig.maxRedirects) {
          final nextUri = currentUri.resolve(location.trim());
          if (nextUri.scheme != uri.scheme ||
              nextUri.host != uri.host ||
              nextUri.port != uri.port ||
              nextUri.userInfo.isNotEmpty) {
            throw const WebDavSyncException('拒绝跨站或协议变更的 WebDAV 重定向');
          }
          currentUri = nextUri;
          continue;
        }
      }
      return response;
    }
    throw const WebDavSyncException('WebDAV 重定向次数过多');
  }

  /// 限制声明长度、实际累计长度和整个正文接收时间。
  Future<http.Response> _readBoundedResponse(
    http.StreamedResponse streamed,
    int limit,
    String message,
  ) async {
    if ((streamed.contentLength ?? 0) > limit) {
      await streamed.stream.listen((_) {}).cancel();
      throw WebDavSyncException(message);
    }
    final bytes = BytesBuilder(copy: false);
    final result = Completer<Uint8List>();
    late final StreamSubscription<List<int>> subscription;
    void reject(Object error, [StackTrace? stack]) {
      if (result.isCompleted) {
        return;
      }
      result.completeError(error, stack);
      // 已确定失败，不让连接取消过程阻塞错误返回。
      unawaited(subscription.cancel().catchError((Object _) {}));
    }

    final timer = Timer(
      _requestTimeout,
      () => reject(const WebDavSyncException('WebDAV 响应读取超时')),
    );
    try {
      subscription = streamed.stream.listen(
        (chunk) {
          if (result.isCompleted) {
            return;
          }
          if (chunk.length > limit - bytes.length) {
            reject(WebDavSyncException(message));
            return;
          }
          bytes.add(chunk);
        },
        onError: (Object error, StackTrace stack) => reject(error, stack),
        onDone: () {
          if (!result.isCompleted) {
            result.complete(bytes.takeBytes());
          }
        },
        cancelOnError: true,
      );
      return http.Response.bytes(
        await result.future,
        streamed.statusCode,
        headers: streamed.headers,
        request: streamed.request,
        isRedirect: streamed.isRedirect,
        persistentConnection: streamed.persistentConnection,
        reasonPhrase: streamed.reasonPhrase,
      );
    } finally {
      timer.cancel();
    }
  }

  static Uri _parseValidatedBaseUri(String rawUrl) {
    final uri = Uri.tryParse(rawUrl.trim());
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.trim().isEmpty) {
      throw const WebDavSyncException('请输入有效的 WebDAV 服务器地址（http 或 https）');
    }
    return uri;
  }

  static String _buildBasicAuthHeader(String username, String password) {
    final token = base64Encode(utf8.encode('$username:$password'));
    return 'Basic $token';
  }

  static bool _isRedirect(int statusCode) =>
      statusCode == 301 ||
      statusCode == 302 ||
      statusCode == 303 ||
      statusCode == 307 ||
      statusCode == 308;

  static String? _readCaseInsensitiveHeader(
    Map<String, String> headers,
    String targetName,
  ) {
    final lower = targetName.toLowerCase();
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == lower) {
        return entry.value;
      }
    }
    return null;
  }

  static WebDavSyncException _buildHttpException(String prefix, int status) {
    if (status == 401 || status == 403) {
      return WebDavSyncException(
        '$prefix（HTTP $status：账号或应用密码认证失败）',
        statusCode: status,
      );
    }
    if (status == 405) {
      return WebDavSyncException(
        '$prefix：服务器不允许此操作，请检查 WebDAV 地址及同步目录写入权限（HTTP 405）',
        statusCode: status,
      );
    }
    return WebDavSyncException('$prefix（HTTP $status）', statusCode: status);
  }

  // 仅接受当前分片版本路径或既有 v2 固定路径，不访问同步目录之外的资源。
  static void _validateShardPath(WebDavSliceWatermark watermark) {
    final legacy =
        '$slicesDirectoryName/${_sanitizePathSegment(watermark.sliceId)}_${_sanitizePathSegment(watermark.deviceId)}.json.gz';
    final versioned = buildShardRelativePath(
      sliceId: watermark.sliceId,
      deviceId: watermark.deviceId,
      sha256: watermark.sha256,
    );
    if (watermark.shardPath != legacy && watermark.shardPath != versioned) {
      throw const WebDavSyncException('远端切片路径与清单身份不一致');
    }
  }

  static String _sanitizePathSegment(String raw) {
    final cleaned = raw.trim().replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    return cleaned.isEmpty ? 'unknown' : cleaned;
  }
}

/// 限制解压器累计输出，不分配超过上限的正文缓冲区。
final class _BoundedShardSink implements Sink<List<int>> {
  final BytesBuilder _bytes = BytesBuilder(copy: false);

  @override
  void add(List<int> chunk) {
    if (chunk.length >
        WebDavSyncTransport.maxDecodedShardBytes - _bytes.length) {
      throw const WebDavSyncException('同步分片解压后超过 128 MiB 安全上限');
    }
    _bytes.add(chunk);
  }

  @override
  void close() {}

  Uint8List takeBytes() => _bytes.takeBytes();
}
