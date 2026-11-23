import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../../domain/formatting/network_error_sanitizer.dart';
import '../../domain/logging/diagnostic_event.dart';
import '../../domain/sync/konata_sync_models.dart';
import '../logging/diagnostics_log_store.dart';
import '../sources/webdav_digest_auth.dart';
import '../sources/webdav_source_gateway.dart';

/// WebDAV 多设备分片同步远端传输客户端（复用 Digest/Basic 认证与全局连接池）。
///
/// 远端目录结构严格分片隔离，避免多设备并发覆盖冲突：
/// - `<baseUrl>/<remoteDir>/manifest.json`
/// - `<baseUrl>/<remoteDir>/devices/<deviceId>/snapshot.json.gz`
class WebDavSyncTransport {
  /// 创建 WebDAV 同步传输客户端（支持测试注入 [httpClient]）。
  WebDavSyncTransport({
    required this._config,
    WebDavConnectionPool? connectionPool,
    http.Client? httpClient,
    this._logStore,
    this.requestTimeout = WebDavGatewayConfig.defaultRequestTimeout,
  }) : _pool = connectionPool,
       _injectedClient = httpClient;

  final WebDavSyncConfig _config;
  final WebDavConnectionPool? _pool;
  final http.Client? _injectedClient;
  final DiagnosticsLogStore? _logStore;

  /// 单次 WebDAV HTTP 请求超时时间。
  final Duration requestTimeout;

  String? _localDigestChallenge;
  int _localNonceCount = 0;

  Uri _resolveUri(String relativePath, {bool isDirectory = false}) {
    final base = Uri.parse(_config.baseUrl.trim());
    final baseSegments = <String>[
      for (final seg in base.pathSegments)
        if (seg.isNotEmpty) seg,
    ];
    final relSegments = <String>[
      for (final seg in relativePath.replaceAll('\\', '/').split('/'))
        if (seg.isNotEmpty) seg,
    ];
    final combined = <String>[...baseSegments, ...relSegments];
    final encodedPath = '/${combined.map(Uri.encodeComponent).join('/')}';
    final finalPath = isDirectory && !encodedPath.endsWith('/')
        ? '$encodedPath/'
        : encodedPath;
    return base.replace(path: finalPath, query: null, fragment: null);
  }

  /// 确保同步根目录及本机独立分片目录存在（逐级幂等执行 `MKCOL`）。
  Future<void> ensureDeviceDirectories(String deviceId) async {
    final rootDir = _config.normalizedRemoteDir;
    final parts = <String>[
      for (final seg in rootDir.split('/'))
        if (seg.isNotEmpty) seg,
      'devices',
      deviceId,
    ];
    var acc = '';
    for (final seg in parts) {
      acc = acc.isEmpty ? seg : '$acc/$seg';
      final uri = _resolveUri(acc, isDirectory: true);
      final resp = await _send(method: 'MKCOL', uri: uri);
      // 201 创建成功，405/301/302/409 通常代表目录已存在，直接放行。
      if (resp.statusCode == 201 ||
          resp.statusCode == 200 ||
          resp.statusCode == 204 ||
          resp.statusCode == 405 ||
          resp.statusCode == 301 ||
          resp.statusCode == 302) {
        continue;
      }
      if (resp.statusCode == 401 || resp.statusCode == 403) {
        throw StateError('WebDAV 鉴权失败（HTTP ${resp.statusCode}），请检查账号密码或写入权限');
      }
      if (resp.statusCode >= 400 && resp.statusCode != 409) {
        throw StateError(
          '创建 WebDAV 同步目录失败（/$acc，HTTP ${resp.statusCode}）',
        );
      }
    }
  }

  /// 测试目标 WebDAV 同步服务连通性与写权限（成功返回 `null`，失败返回中文原因）。
  Future<String?> testConnection() async {
    if (!_config.hasValidServerUrl) {
      return '请填写以 http:// 或 https:// 开头的有效 WebDAV 服务器地址';
    }
    try {
      final probeUri = _resolveUri(
        _config.normalizedRemoteDir,
        isDirectory: true,
      );
      final mkRes = await _send(method: 'MKCOL', uri: probeUri);
      if (mkRes.statusCode == 401 || mkRes.statusCode == 403) {
        return 'WebDAV 认证失败（HTTP ${mkRes.statusCode}），请检查用户名、密码与目录写权限';
      }
      if (mkRes.statusCode >= 500) {
        return 'WebDAV 服务器异常（HTTP ${mkRes.statusCode}）';
      }
      final manifestUri = _resolveUri(
        '${_config.normalizedRemoteDir}/manifest.json',
      );
      final getRes = await _send(method: 'GET', uri: manifestUri);
      if (getRes.statusCode == 401 || getRes.statusCode == 403) {
        return 'WebDAV 读取认证失败（HTTP ${getRes.statusCode}）';
      }
      if (getRes.statusCode == 200 || getRes.statusCode == 404) {
        return null;
      }
      return 'WebDAV 响应异常（HTTP ${getRes.statusCode}）';
    } catch (error, stackTrace) {
      _logStore?.logError(
        subsystem: DiagnosticSubsystem.sync,
        code: 'SYNC_WEBDAV_TEST_FAILED',
        message: 'WebDAV 同步连通性测试失败',
        error: error,
        stackTrace: stackTrace,
        source:
            'lib/infrastructure/sync/webdav_sync_transport.dart:testConnection',
      );
      return NetworkErrorSanitizer.toUserMessage(error, prefix: 'WebDAV 连接失败');
    }
  }

  /// 读取远端 `manifest.json`（若远端尚未初始化返回 `null`）。
  Future<WebDavSyncManifest?> fetchManifest() async {
    final uri = _resolveUri('${_config.normalizedRemoteDir}/manifest.json');
    final resp = await _send(method: 'GET', uri: uri);
    if (resp.statusCode == 404) return null;
    if (resp.statusCode == 401 || resp.statusCode == 403) {
      throw StateError('WebDAV 读取清单认证失败（HTTP ${resp.statusCode}）');
    }
    if (resp.statusCode != 200) {
      throw StateError('读取远端同步清单失败（HTTP ${resp.statusCode}）');
    }
    final dynamic decoded;
    try {
      decoded = jsonDecode(utf8.decode(resp.bodyBytes));
    } catch (_) {
      throw const FormatException('远端 manifest.json 不是有效的 JSON 文本');
    }
    if (decoded is! Map) {
      throw const FormatException('远端 manifest.json 格式无效');
    }
    return WebDavSyncManifest.fromJson(
      decoded.map((k, v) => MapEntry(k.toString(), v)),
    );
  }

  /// 上传更新后的 `manifest.json`。
  Future<void> uploadManifest(WebDavSyncManifest manifest) async {
    final uri = _resolveUri('${_config.normalizedRemoteDir}/manifest.json');
    final body = utf8.encode(jsonEncode(manifest.toJson()));
    final resp = await _send(
      method: 'PUT',
      uri: uri,
      body: body,
      contentType: 'application/json; charset=utf-8',
    );
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw StateError('写入远端同步清单失败（HTTP ${resp.statusCode}）');
    }
  }

  /// 下载指定设备的 gzip 压缩分片并校验其 SHA-256 完整性（不存在返回 `null`）。
  Future<KonataSyncSnapshotEnvelope?> downloadDeviceShard(
    String shardPath,
  ) async {
    final normalized = shardPath.replaceAll('\\', '/').replaceFirst(
      RegExp(r'^/+'),
      '',
    );
    final rel = normalized.startsWith('${_config.normalizedRemoteDir}/')
        ? normalized
        : '${_config.normalizedRemoteDir}/$normalized';
    final uri = _resolveUri(rel);
    final resp = await _send(method: 'GET', uri: uri);
    if (resp.statusCode == 404) return null;
    if (resp.statusCode == 401 || resp.statusCode == 403) {
      throw StateError('WebDAV 下载设备分片认证失败（HTTP ${resp.statusCode}）');
    }
    if (resp.statusCode != 200) {
      throw StateError('下载设备同步分片失败（HTTP ${resp.statusCode}）');
    }
    final rawBytes = resp.bodyBytes;
    final jsonBytes = _isGzipBytes(rawBytes) ? gzip.decode(rawBytes) : rawBytes;
    return KonataSyncSnapshotEnvelope.parseAndVerify(utf8.decode(jsonBytes));
  }

  /// 将本机快照压缩为 `.json.gz` 上传至专属分片路径 `devices/<deviceId>/snapshot.json.gz`。
  Future<String> uploadDeviceShard({
    required String deviceId,
    required KonataSyncSnapshotEnvelope envelope,
  }) async {
    final shardRel = 'devices/$deviceId/snapshot.json.gz';
    final uri = _resolveUri('${_config.normalizedRemoteDir}/$shardRel');
    final gzBytes = gzip.encode(utf8.encode(jsonEncode(envelope.toJson())));
    final resp = await _send(
      method: 'PUT',
      uri: uri,
      body: gzBytes,
      contentType: 'application/gzip',
    );
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw StateError('上传本机同步分片失败（HTTP ${resp.statusCode}）');
    }
    return shardRel;
  }

  bool _isGzipBytes(List<int> bytes) =>
      bytes.length >= 2 && bytes[0] == 0x1f && bytes[1] == 0x8b;

  http.Client _acquireClient() {
    if (_injectedClient != null) return _injectedClient;
    final baseUri = Uri.parse(_config.baseUrl.trim());
    if (_pool != null) {
      return _pool.acquireClient(
        rootUri: baseUri,
        username: _config.username,
        password: _config.password,
      );
    }
    return http.Client();
  }

  String? _buildInitialAuthHeader(String method, Uri uri) {
    final user = _config.username.trim();
    final pass = _config.password;
    if (user.isEmpty && pass.isEmpty) return null;
    final challenge = _readCachedChallenge();
    if (challenge != null) {
      final nc = _nextNonceCount();
      final digest = WebDavDigestAuth.buildAuthorizationHeader(
        wwwAuthenticateHeader: challenge,
        method: method,
        uri: uri,
        username: user,
        password: pass,
        nonceCount: nc,
      );
      if (digest != null) return digest;
    }
    final encoded = base64Encode(utf8.encode('$user:$pass'));
    return 'Basic $encoded';
  }

  String? _readCachedChallenge() {
    if (_pool != null) {
      return _pool.readDigestChallenge(
        rootUri: Uri.parse(_config.baseUrl.trim()),
        username: _config.username,
        password: _config.password,
      );
    }
    return _localDigestChallenge;
  }

  void _saveCachedChallenge(String challenge) {
    if (_pool != null) {
      _pool.rememberDigestChallenge(
        rootUri: Uri.parse(_config.baseUrl.trim()),
        username: _config.username,
        password: _config.password,
        challenge: challenge,
      );
    }
    _localDigestChallenge = challenge;
    _localNonceCount = 0;
  }

  int _nextNonceCount() {
    _localNonceCount++;
    return _localNonceCount;
  }

  Future<http.Response> _send({
    required String method,
    required Uri uri,
    List<int>? body,
    String? contentType,
  }) async {
    final ownsClient = _injectedClient == null && _pool == null;
    final client = _acquireClient();
    try {
      Future<http.Response> fire(String? authHeader) async {
        final req = http.Request(method, uri);
        req.followRedirects = true;
        req.maxRedirects = WebDavGatewayConfig.maxRedirects;
        req.headers['User-Agent'] = WebDavGatewayConfig.defaultUserAgent;
        if (contentType != null) {
          req.headers['Content-Type'] = contentType;
        }
        if (authHeader != null) {
          req.headers['Authorization'] = authHeader;
        }
        if (body != null) {
          req.bodyBytes = body;
        }
        final streamed = await client.send(req).timeout(requestTimeout);
        return http.Response.fromStream(streamed).timeout(requestTimeout);
      }

      var response = await fire(_buildInitialAuthHeader(method, uri));
      if (response.statusCode == 401) {
        final wwwAuth = response.headers['www-authenticate'];
        final user = _config.username.trim();
        if (wwwAuth != null &&
            wwwAuth.toLowerCase().startsWith('digest ') &&
            (user.isNotEmpty || _config.password.isNotEmpty)) {
          _saveCachedChallenge(wwwAuth);
          final digestHeader = WebDavDigestAuth.buildAuthorizationHeader(
            wwwAuthenticateHeader: wwwAuth,
            method: method,
            uri: uri,
            username: user,
            password: _config.password,
            nonceCount: _nextNonceCount(),
          );
          if (digestHeader != null) {
            response = await fire(digestHeader);
          }
        }
      }
      return response;
    } finally {
      if (ownsClient) {
        client.close();
      }
    }
  }
}
