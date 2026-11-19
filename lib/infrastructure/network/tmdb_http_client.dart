import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:developer' as developer;

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../../domain/formatting/network_error_sanitizer.dart';
import '../../domain/models/network_config.dart';
import '../../domain/models/tmdb_models.dart';
import 'priority_http_scheduler.dart';

/// 不可达官方域名冷却注册表（防止主线受阻时每张图片或每条请求重复等待超时）。
class DomainCooldownRegistry {
  /// 创建独立域名冷却注册表。
  DomainCooldownRegistry({this.cooldownDuration = const Duration(minutes: 10)});

  /// 全应用共享默认冷却注册表（10 分钟冷却窗口）。
  static final DomainCooldownRegistry shared = DomainCooldownRegistry();

  /// 官方域名不可达后的跳过冷却时长。
  final Duration cooldownDuration;

  final Map<String, DateTime> _blockedUntil = {};

  /// 判断指定域名当前是否处于冷却窗口内。
  bool isCoolingDown(String host, [DateTime? now]) {
    final key = host.trim().toLowerCase();
    if (key.isEmpty) return false;
    final until = _blockedUntil[key];
    if (until == null) return false;
    final current = now ?? DateTime.now();
    if (!current.isBefore(until)) {
      _blockedUntil.remove(key);
      return false;
    }
    return true;
  }

  /// 将指定域名标记为临时不可达并进入冷却窗口。
  void markBlocked(String host, [DateTime? now]) {
    final key = host.trim().toLowerCase();
    if (key.isEmpty) return;
    final current = now ?? DateTime.now();
    _blockedUntil[key] = current.add(cooldownDuration);
  }

  /// 解除指定域名的冷却状态（例如手工测试连通恢复时）。
  void clearHost(String host) {
    final key = host.trim().toLowerCase();
    if (key.isNotEmpty) {
      _blockedUntil.remove(key);
    }
  }

  /// 清空全部冷却记录。
  void clearAll() => _blockedUntil.clear();
}

/// 支持「官方优先 + 备用地址自动容灾回退 + 冷却窗口」的统一 HTTP 客户端。
class TmdbHttpClient {
  /// 创建客户端实例（支持注入 [httpClient] 与独立 [cooldownRegistry] 便于离线单测）。
  TmdbHttpClient({
    required this._config,
    PriorityHttpScheduler? scheduler,
    http.Client? httpClient,
    DomainCooldownRegistry? cooldownRegistry,
    this.primaryTimeout = const Duration(seconds: 3, milliseconds: 500),
    this.backupTimeout = const Duration(seconds: 12),
    DateTime Function()? nowProvider,
  }) : _scheduler = scheduler ?? PriorityHttpScheduler(),
       _injectedClient = httpClient,
       _cooldown = cooldownRegistry ?? DomainCooldownRegistry.shared,
       _now = nowProvider ?? DateTime.now;

  TmdbNetworkConfig _config;
  final PriorityHttpScheduler _scheduler;
  final http.Client? _injectedClient;
  final DomainCooldownRegistry _cooldown;
  final DateTime Function() _now;

  /// 官方主链路单次请求超时阈值（默认 3.5 秒以快速感知受阻并切向备用地址）。
  final Duration primaryTimeout;

  /// 备用链路及无备选单链路超时阈值。
  final Duration backupTimeout;

  http.Client? _cachedIoClient;

  static const MethodChannel _androidNetworkChannel = MethodChannel(
    'ccplayer/network',
  );
  static const List<String> _dohJsonEndpoints = <String>[
    'https://223.5.5.5/resolve',
    'https://1.1.1.1/dns-query',
  ];
  final Map<String, ({String directive, DateTime expiresAt})>
  _androidProxyCache = {};
  final Map<String, ({InternetAddress address, DateTime expiresAt})>
  _dohResolvedCache = {};

  /// 当前生效的网络配置。
  TmdbNetworkConfig get config => _config;

  /// 当前关联的域名冷却表（供测试校验冷却状态）。
  DomainCooldownRegistry get cooldownRegistry => _cooldown;

  /// 更新网络配置（立即重建底层传输客户端并重置域名冷却窗口）。
  void updateConfig(TmdbNetworkConfig next) {
    _config = next;
    _cooldown.clearAll();
    _androidProxyCache.clear();
    _dohResolvedCache.clear();
    _cachedIoClient?.close();
    _cachedIoClient = null;
  }

  /// 发起 GET 请求（单链路版本）。
  Future<http.Response> get(
    Uri uri, {
    Map<String, String> headers = const {},
    RequestPriority priority = RequestPriority.background,
    String? dedupeKey,
  }) {
    return getWithFallback(
      uri,
      headers: headers,
      priority: priority,
      dedupeKey: dedupeKey,
    );
  }

  /// 发起支持官方主备自动回退的 GET 请求。
  Future<http.Response> getWithFallback(
    Uri primaryUri, {
    Uri? backupUri,
    Map<String, String> headers = const {},
    RequestPriority priority = RequestPriority.background,
    String? dedupeKey,
  }) {
    return _scheduler.schedule<http.Response>(
      priority,
      () => _executeWithFallback(
        method: 'GET',
        primaryUri: primaryUri,
        backupUri: backupUri,
        headers: headers,
      ),
      dedupeKey: dedupeKey ?? primaryUri.toString(),
    );
  }

  /// 发起 POST 请求（单链路版本）。
  Future<http.Response> post(
    Uri uri, {
    Map<String, String> headers = const {},
    Object? body,
    RequestPriority priority = RequestPriority.background,
    String? dedupeKey,
  }) {
    return postWithFallback(
      uri,
      headers: headers,
      body: body,
      priority: priority,
      dedupeKey: dedupeKey,
    );
  }

  /// 发起支持官方主备自动回退的 POST 请求。
  Future<http.Response> postWithFallback(
    Uri primaryUri, {
    Uri? backupUri,
    Map<String, String> headers = const {},
    Object? body,
    RequestPriority priority = RequestPriority.background,
    String? dedupeKey,
  }) {
    return _scheduler.schedule<http.Response>(
      priority,
      () => _executeWithFallback(
        method: 'POST',
        primaryUri: primaryUri,
        backupUri: backupUri,
        headers: headers,
        body: body,
      ),
      dedupeKey: dedupeKey,
    );
  }

  Future<http.Response> _executeWithFallback({
    required String method,
    required Uri primaryUri,
    required Uri? backupUri,
    required Map<String, String> headers,
    Object? body,
  }) async {
    final effectiveBackup = _usableBackup(primaryUri, backupUri);
    if (effectiveBackup == null) {
      return _sendSingle(
        method: method,
        uri: primaryUri,
        headers: headers,
        body: body,
        timeout: backupTimeout,
      );
    }

    if (_cooldown.isCoolingDown(primaryUri.host, _now())) {
      try {
        return await _sendSingle(
          method: method,
          uri: effectiveBackup,
          headers: headers,
          body: body,
          timeout: backupTimeout,
        );
      } catch (e) {
        if (_isFallbackTriggerError(e)) {
          _cooldown.clearHost(primaryUri.host);
        }
        rethrow;
      }
    }

    try {
      final response = await _sendSingle(
        method: method,
        uri: primaryUri,
        headers: headers,
        body: body,
        timeout: primaryTimeout,
      );
      if (response.statusCode >= 500) {
        _cooldown.markBlocked(primaryUri.host, _now());
        return _sendSingle(
          method: method,
          uri: effectiveBackup,
          headers: headers,
          body: body,
          timeout: backupTimeout,
        );
      }
      return response;
    } catch (e) {
      if (_isFallbackTriggerError(e)) {
        _cooldown.markBlocked(primaryUri.host, _now());
        return _sendSingle(
          method: method,
          uri: effectiveBackup,
          headers: headers,
          body: body,
          timeout: backupTimeout,
        );
      }
      rethrow;
    }
  }

  Future<http.Response> _sendSingle({
    required String method,
    required Uri uri,
    required Map<String, String> headers,
    required Duration timeout,
    Object? body,
  }) async {
    if (_injectedClient == null &&
        Platform.isAndroid &&
        _config.proxyMode == ProxyMode.system) {
      await _warmAndroidSystemProxy(uri);
    }

    final finalHeaders = <String, String>{
      'Accept': 'application/json',
      if (method == 'POST') 'Content-Type': 'application/json',
      'User-Agent': Platform.isAndroid
          ? 'Konata/2.0 (Android)'
          : 'Konata/2.0 (Windows)',
      ...headers,
    };

    Future<http.Response> dispatch() {
      final client = _getClient();
      final future = method == 'POST'
          ? client.post(uri, headers: finalHeaders, body: body)
          : client.get(uri, headers: finalHeaders);
      return future.timeout(timeout);
    }

    http.Response response;
    try {
      response = await dispatch();
    } catch (error) {
      if (_injectedClient == null &&
          _isDnsLookupError(error) &&
          _effectiveProxyDirectiveForUri(uri) == 'DIRECT') {
        final resolved = await _resolveHostViaDoh(uri.host);
        if (resolved != null) {
          try {
            response = await dispatch();
          } catch (retryError) {
            throw _sanitizeThrownError(retryError);
          }
        } else {
          throw _sanitizeThrownError(error);
        }
      } else {
        throw _sanitizeThrownError(error);
      }
    }

    if (response.statusCode == 429) {
      final retrySec =
          int.tryParse(response.headers['retry-after'] ?? '') ?? 1;
      throw RateLimitedHttpException(
        Duration(seconds: retrySec.clamp(1, 30)),
        'HTTP 429',
      );
    }
    return response;
  }

  Object _sanitizeThrownError(Object error) {
    if (error is http.ClientException) {
      final safeMsg = NetworkErrorSanitizer.redactSecrets(error.message);
      final rawUri = error.uri?.toString();
      final safeUri = rawUri == null
          ? null
          : Uri.tryParse(NetworkErrorSanitizer.redactSecrets(rawUri));
      return http.ClientException(safeMsg, safeUri);
    }
    return error;
  }

  bool _isDnsLookupError(Object error) {
    final text = error.toString().toLowerCase();
    return text.contains('failed host lookup') ||
        text.contains('no address associated with hostname');
  }

  Uri? _usableBackup(Uri primary, Uri? backup) {
    if (backup == null) return null;
    if (backup.scheme.isEmpty || backup.host.isEmpty) return null;
    if (backup.toString() == primary.toString()) return null;
    return backup;
  }

  bool _isFallbackTriggerError(Object error) {
    if (error is RateLimitedHttpException) return false;
    return error is TimeoutException ||
        error is SocketException ||
        error is HandshakeException ||
        error is TlsException ||
        error is HttpException ||
        error is http.ClientException;
  }

  /// 探测 TMDB API（官方优先，受阻自动回退备用地址）。
  Future<ConnectivityReport> testTmdbApiConnectivity() {
    final primaryBase = Uri.parse('${TmdbNetworkConfig.defaultApiBase}/configuration');
    final backupRaw = _config.normalizedTmdbBackupApiBase;
    final backupBase = backupRaw.isNotEmpty
        ? Uri.tryParse('$backupRaw/configuration')
        : null;

    final queryParams = <String, String>{};
    final headers = <String, String>{};
    switch (_config.credentialKind) {
      case TmdbCredentialKind.v3ApiKey:
        queryParams['api_key'] = _config.credential.trim();
      case TmdbCredentialKind.v4BearerToken:
        headers['Authorization'] = 'Bearer ${_config.credential.trim()}';
      case TmdbCredentialKind.none:
        break;
    }

    Uri decorate(Uri uri) => queryParams.isEmpty
        ? uri
        : uri.replace(
            queryParameters: <String, String>{
              ...uri.queryParameters,
              ...queryParams,
            },
          );

    return _probeEndpointPair(
      primaryUri: decorate(primaryBase),
      backupUri: backupBase == null ? null : decorate(backupBase),
      headers: headers,
      checkAuthErrors: true,
    );
  }

  /// 探测 TMDB 图片服务器（官方优先，受阻自动回退备用图片地址）。
  Future<ConnectivityReport> testTmdbImageConnectivity() {
    const probePath = '/w92/wwemzKWzjKYJFfCeiB57q3r4Bcm.png';
    final primary = Uri.parse('${TmdbNetworkConfig.defaultImageBase}$probePath');
    final backupRaw = _config.normalizedTmdbBackupImageBase;
    final backup = backupRaw.isNotEmpty
        ? Uri.tryParse('$backupRaw$probePath')
        : null;
    return _probeEndpointPair(
      primaryUri: primary,
      backupUri: backup,
      headers: const {'Accept': 'image/*,*/*'},
    );
  }

  /// 探测 Bangumi API（官方优先，受阻自动回退社区镜像）。
  Future<ConnectivityReport> testBangumiApiConnectivity() {
    final primary = Uri.parse('${TmdbNetworkConfig.defaultBangumiApiBase}/subjects/1');
    final backupRaw = _config.normalizedBangumiBackupApiBase;
    final backup = backupRaw.isNotEmpty
        ? Uri.tryParse('$backupRaw/subjects/1')
        : null;
    return _probeEndpointPair(
      primaryUri: primary,
      backupUri: backup,
      headers: const {
        'User-Agent': 'ClainSt/Konata (+https://github.com/ClainSt/Konata)',
        'Accept': 'application/json',
      },
    );
  }

  /// 探测 Bangumi 图片服务器（官方优先，受阻自动回退备用图片镜像）。
  Future<ConnectivityReport> testBangumiImageConnectivity() {
    const probePath = '/pic/cover/c/7f/ce/1_3581p.jpg';
    final primary = Uri.parse(
      '${TmdbNetworkConfig.defaultBangumiImageBase}$probePath',
    );
    final backupRaw = _config.normalizedBangumiBackupImageBase;
    final backup = backupRaw.isNotEmpty
        ? Uri.tryParse('$backupRaw$probePath')
        : null;
    return _probeEndpointPair(
      primaryUri: primary,
      backupUri: backup,
      headers: const {'Accept': 'image/*,*/*'},
    );
  }

  /// 兼容旧调用的连通测试入口（等同 `testTmdbApiConnectivity`）。
  Future<ConnectivityReport> testConnectivity() => testTmdbApiConnectivity();

  Future<ConnectivityReport> _probeEndpointPair({
    required Uri primaryUri,
    required Uri? backupUri,
    Map<String, String> headers = const {},
    bool checkAuthErrors = false,
  }) async {
    final safePrimaryAddr = NetworkErrorSanitizer.redactSecrets(
      primaryUri.toString(),
    );
    final sw = Stopwatch()..start();
    try {
      final resp = await _sendSingle(
        method: 'GET',
        uri: primaryUri,
        headers: headers,
        timeout: primaryTimeout,
      );
      sw.stop();
      if (resp.statusCode == 200) {
        _cooldown.clearHost(primaryUri.host);
        return ConnectivityReport(
          reachable: true,
          latencyMs: sw.elapsedMilliseconds,
          usedBackup: false,
          resolvedAddress: safePrimaryAddr,
          statusSummary: '官方直连成功 (${sw.elapsedMilliseconds}ms)',
        );
      }
      if (checkAuthErrors &&
          (resp.statusCode == 401 || resp.statusCode == 403)) {
        _cooldown.clearHost(primaryUri.host);
        return ConnectivityReport(
          reachable: false,
          latencyMs: sw.elapsedMilliseconds,
          resolvedAddress: safePrimaryAddr,
          errorMessage: 'API 密钥无效 (HTTP ${resp.statusCode})',
          statusSummary: '官方地址连通，但 API 密钥无效 (HTTP ${resp.statusCode})',
        );
      }
      if (resp.statusCode < 500) {
        return ConnectivityReport(
          reachable: false,
          latencyMs: sw.elapsedMilliseconds,
          resolvedAddress: safePrimaryAddr,
          errorMessage: 'HTTP ${resp.statusCode}',
          statusSummary: '官方返回 HTTP ${resp.statusCode}',
        );
      }
    } catch (error) {
      // 官方网络错误或超时，继续探测备用地址
      developer.log('可恢复异常已记录', name: 'konata.tmdb_http_client', error: error);
    } finally {
      sw.stop();
    }

    final usableBackup = _usableBackup(primaryUri, backupUri);
    if (usableBackup == null) {
      return ConnectivityReport(
        reachable: false,
        latencyMs: sw.elapsedMilliseconds,
        errorMessage: '官方地址无法连接且未配置有效备用地址',
        statusSummary: '官方地址无法连接，且未配置有效备用地址',
      );
    }

    final safeBackupAddr = NetworkErrorSanitizer.redactSecrets(
      usableBackup.toString(),
    );
    final backupSw = Stopwatch()..start();
    try {
      final bResp = await _sendSingle(
        method: 'GET',
        uri: usableBackup,
        headers: headers,
        timeout: backupTimeout,
      );
      backupSw.stop();
      if (bResp.statusCode == 200) {
        return ConnectivityReport(
          reachable: true,
          latencyMs: backupSw.elapsedMilliseconds,
          usedBackup: true,
          resolvedAddress: safeBackupAddr,
          statusSummary:
              '官方不可达，已自动回退备用地址连通 (${backupSw.elapsedMilliseconds}ms)',
        );
      }
      if (checkAuthErrors &&
          (bResp.statusCode == 401 || bResp.statusCode == 403)) {
        return ConnectivityReport(
          reachable: false,
          latencyMs: backupSw.elapsedMilliseconds,
          usedBackup: true,
          resolvedAddress: safeBackupAddr,
          errorMessage: '备用地址返回密钥无效 (HTTP ${bResp.statusCode})',
          statusSummary:
              '官方不可达，备用地址返回密钥无效 (HTTP ${bResp.statusCode})',
        );
      }
      return ConnectivityReport(
        reachable: false,
        latencyMs: backupSw.elapsedMilliseconds,
        usedBackup: true,
        resolvedAddress: safeBackupAddr,
        errorMessage: 'HTTP ${bResp.statusCode}',
        statusSummary: '官方不可达，备用地址返回 HTTP ${bResp.statusCode}',
      );
    } catch (_) {
      backupSw.stop();
      return ConnectivityReport(
        reachable: false,
        latencyMs: backupSw.elapsedMilliseconds,
        errorMessage: '官方与备用地址均无法连接',
        statusSummary: '官方与备用地址均无法连接（请检查密钥/备用地址或代理）',
      );
    }
  }

  /// 查询并短期缓存 Android 系统 Wi-Fi HTTP 代理配置（兼容未开启 TUN 模式的系统代理）。
  Future<void> _warmAndroidSystemProxy(Uri uri) async {
    if (uri.scheme != 'http' && uri.scheme != 'https') return;
    final key = '${uri.scheme}://${uri.host}'.toLowerCase();
    final now = _now();
    final cached = _androidProxyCache[key];
    if (cached != null && now.isBefore(cached.expiresAt)) {
      return;
    }
    try {
      final probeUrl = '${uri.scheme}://${uri.host}/';
      final directive = await _androidNetworkChannel
          .invokeMethod<String>('proxy', probeUrl)
          .timeout(const Duration(milliseconds: 600));
      if (directive != null && directive.trim().isNotEmpty) {
        _androidProxyCache[key] = (
          directive: directive.trim(),
          expiresAt: now.add(const Duration(seconds: 30)),
        );
      }
    } catch (error) {
      // 单元测试或后台无引擎绑定环境回退至环境变量探测。
      developer.log('可恢复异常已记录', name: 'konata.tmdb_http_client', error: error);
    }
  }

  String _effectiveProxyDirectiveForUri(Uri uri) {
    switch (_config.proxyMode) {
      case ProxyMode.none:
        return 'DIRECT';
      case ProxyMode.custom:
        return _parseProxyDirective(_config.proxyUrl) ?? 'DIRECT';
      case ProxyMode.system:
        if (Platform.isAndroid) {
          final key = '${uri.scheme}://${uri.host}'.toLowerCase();
          final cached = _androidProxyCache[key];
          if (cached != null && _now().isBefore(cached.expiresAt)) {
            return cached.directive;
          }
        }
        return HttpClient.findProxyFromEnvironment(uri);
    }
  }

  InternetAddress? _lookupCachedDohAddress(String host) {
    final key = host.trim().toLowerCase();
    if (key.isEmpty) return null;
    final entry = _dohResolvedCache[key];
    if (entry == null) return null;
    if (!_now().isBefore(entry.expiresAt)) {
      _dohResolvedCache.remove(key);
      return null;
    }
    return entry.address;
  }

  /// 当本地 DNS 发生域名解析失败时，通过加密 DoH 接口解析目标域名 IPv4 地址并缓存。
  Future<InternetAddress?> _resolveHostViaDoh(String host) async {
    final normalized = host.trim().toLowerCase();
    if (normalized.isEmpty || InternetAddress.tryParse(normalized) != null) {
      return null;
    }
    final existing = _lookupCachedDohAddress(normalized);
    if (existing != null) return existing;

    final dohClient = HttpClient()
      ..connectionTimeout = const Duration(milliseconds: 2200)
      ..findProxy = (_) => 'DIRECT';
    try {
      for (final endpoint in _dohJsonEndpoints) {
        try {
          final queryUri = Uri.parse(endpoint).replace(
            queryParameters: <String, String>{'name': normalized, 'type': 'A'},
          );
          final req = await dohClient
              .getUrl(queryUri)
              .timeout(const Duration(milliseconds: 2200));
          req.headers.set('Accept', 'application/dns-json');
          final resp = await req.close().timeout(
            const Duration(milliseconds: 2200),
          );
          if (resp.statusCode != 200) continue;
          final payload = await utf8.decoder
              .bind(resp)
              .join()
              .timeout(const Duration(milliseconds: 2000));
          final decoded = jsonDecode(payload);
          if (decoded is! Map) continue;
          final answers = decoded['Answer'];
          if (answers is! List) continue;
          for (final item in answers) {
            if (item is! Map) continue;
            final data = item['data']?.toString().trim() ?? '';
            final addr = InternetAddress.tryParse(data);
            if (addr != null) {
              _dohResolvedCache[normalized] = (
                address: addr,
                expiresAt: _now().add(const Duration(minutes: 10)),
              );
              return addr;
            }
          }
        } catch (error) {
      // 单个公共 DoH 节点不可达时继续尝试备选节点。
      developer.log('可恢复异常已记录', name: 'konata.tmdb_http_client', error: error);
    }
      }
    } finally {
      dohClient.close(force: true);
    }
    return null;
  }

  http.Client _getClient() {
    if (_injectedClient != null) return _injectedClient;
    if (_cachedIoClient != null) return _cachedIoClient!;

    final ioClient = HttpClient()..connectionTimeout = primaryTimeout;
    ioClient.findProxy = _effectiveProxyDirectiveForUri;
    ioClient.connectionFactory = (Uri url, String? proxyHost, int? proxyPort) {
      if (proxyHost != null && proxyPort != null) {
        return Socket.startConnect(proxyHost, proxyPort);
      }
      final isHttps = url.scheme.toLowerCase() == 'https';
      final defaultPort = isHttps ? 443 : 80;
      final port = url.hasPort ? url.port : defaultPort;
      final dohAddress = _lookupCachedDohAddress(url.host);
      if (dohAddress != null) {
        final socketFuture = Socket.connect(
          dohAddress,
          port,
          timeout: primaryTimeout,
        ).then<Socket>((rawSocket) async {
          if (!isHttps) return rawSocket;
          try {
            return await SecureSocket.secure(rawSocket, host: url.host);
          } catch (_) {
            rawSocket.destroy();
            rethrow;
          }
        });
        return Future.value(ConnectionTask.fromSocket(socketFuture, () {}));
      }
      if (isHttps) {
        return SecureSocket.startConnect(url.host, port);
      }
      return Socket.startConnect(url.host, port);
    };
    _cachedIoClient = IOClient(ioClient);
    return _cachedIoClient!;
  }

  static String? _parseProxyDirective(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    final normalized = trimmed.contains('://') ? trimmed : 'http://$trimmed';
    final uri = Uri.tryParse(normalized);
    if (uri == null || uri.host.isEmpty || !uri.hasPort || uri.port <= 0) {
      return null;
    }
    final scheme = uri.scheme.toLowerCase();
    if (scheme == 'socks' || scheme == 'socks5') {
      return 'SOCKS5 ${uri.host}:${uri.port}; DIRECT';
    }
    return 'PROXY ${uri.host}:${uri.port}';
  }

  /// 释放底层连接资源。
  void close() {
    _cachedIoClient?.close();
    _cachedIoClient = null;
  }
}
