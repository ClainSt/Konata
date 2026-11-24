import 'dart:convert';
import 'dart:io';

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

/// 远端分片（`slices/<sliceId>_<deviceId>.json.gz`）下载与校验返回包。
final class DownloadedSliceShard {
  /// 创建远端分片下载结果。
  const DownloadedSliceShard({
    required this.watermark,
    required this.payload,
  });

  /// 远端清单水位条目标记。
  final WebDavSliceWatermark watermark;

  /// 解析并通过 `SHA-256` 校验的切片载荷。
  final SyncSlicePayload payload;
}

/// WebDAV 多设备分片同步底层 HTTP 传输层（基于 `engine_sources` 复用连接池与认证逻辑，同时支持注入 `http.Client` 便于离线单测）。
///
/// 远端目录结构严格固定为：
/// - `<remoteDir>/manifest.json`
/// - `<remoteDir>/slices/<sliceId>_<deviceId>.json.gz`
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

  final WebDavConnectionPool _effectivePool;
  final http.Client Function(WebDavSyncConfig config)? _clientFactory;
  final Duration _requestTimeout;

  /// 构造规范分片相对路径：`slices/<sliceId>_<deviceId>.json.gz`。
  static String buildShardRelativePath({
    required String sliceId,
    required String deviceId,
  }) {
    final safeSlice = _sanitizePathSegment(sliceId);
    final safeDevice = _sanitizePathSegment(deviceId);
    return '$slicesDirectoryName/${safeSlice}_$safeDevice.json.gz';
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
    await fetchManifest(config);
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
          res.statusCode == 204 ||
          res.statusCode == 301 ||
          res.statusCode == 302 ||
          res.statusCode == 405 ||
          res.statusCode == 409) {
        continue;
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
  Future<WebDavSyncManifest> fetchManifest(WebDavSyncConfig config) async {
    final uri = resolveRelativeUri(config, manifestFileName);
    final res = await _sendWithAuth(config: config, method: 'GET', uri: uri);
    if (res.statusCode == 404) {
      return const WebDavSyncManifest();
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
      return const WebDavSyncManifest();
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
    return WebDavSyncManifest.fromJson(
      SyncSanitizer.coerceStringKeyMap(decoded),
    );
  }

  /// 上传更新后的远端 `manifest.json`。
  Future<void> uploadManifest(
    WebDavSyncConfig config,
    WebDavSyncManifest manifest,
  ) async {
    final uri = resolveRelativeUri(config, manifestFileName);
    final body = utf8.encode(jsonEncode(manifest.toJson()));
    final res = await _sendWithAuth(
      config: config,
      method: 'PUT',
      uri: uri,
      headers: const <String, String>{
        HttpHeaders.contentTypeHeader: 'application/json; charset=utf-8',
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
        jsonBytes = gzip.decode(res.bodyBytes);
      } catch (_) {
        throw WebDavSyncException('远端切片 `${watermark.sliceId}` 解压失败');
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

    final sliceId = (root['sliceId'] ?? watermark.sliceId).toString().trim();
    final schemaVersion =
        (root['schemaVersion'] as num?)?.toInt() ?? watermark.schemaVersion;
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

  /// 压缩并上传本机单个切片分片（`slices/<sliceId>_<deviceId>.json.gz`）。
  Future<void> uploadSliceShard({
    required WebDavSyncConfig config,
    required WebDavSliceWatermark watermark,
    required SyncSlicePayload payload,
  }) async {
    final uri = resolveRelativeUri(config, watermark.shardPath);
    final envelope = <String, Object?>{
      ...payload.toJson(),
      'sha256': watermark.sha256,
    };
    final gzBytes = gzip.encode(utf8.encode(jsonEncode(envelope)));
    final res = await _sendWithAuth(
      config: config,
      method: 'PUT',
      uri: uri,
      headers: const <String, String>{
        HttpHeaders.contentTypeHeader: 'application/gzip',
      },
      body: gzBytes,
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw _buildHttpException(
        '上传同步切片 `${watermark.sliceId}` 失败',
        res.statusCode,
      );
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
      final response = await http.Response.fromStream(streamed);
      if (_isRedirect(response.statusCode)) {
        final location = _readCaseInsensitiveHeader(
          response.headers,
          'location',
        );
        if (location != null &&
            location.trim().isNotEmpty &&
            hop < WebDavGatewayConfig.maxRedirects) {
          currentUri = currentUri.resolve(location.trim());
          continue;
        }
      }
      return response;
    }
    throw const WebDavSyncException('WebDAV 重定向次数过多');
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
    return WebDavSyncException('$prefix（HTTP $status）', statusCode: status);
  }

  static String _sanitizePathSegment(String raw) {
    final cleaned = raw.trim().replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    return cleaned.isEmpty ? 'unknown' : cleaned;
  }
}
