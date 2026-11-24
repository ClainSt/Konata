part of 'webdav_source_gateway.dart';

/// WebDAV 网关集中配置常量。
abstract final class WebDavGatewayConfig {
  /// 默认单次 HTTP 请求超时。
  static const Duration defaultRequestTimeout = Duration(seconds: 15);

  /// TCP 建连超时上限（快速失败防死连接挂起）。
  static const Duration defaultConnectTimeout = Duration(seconds: 6);

  /// `HEAD` 探测文件长度超时上限（超时立即降级 `Range: bytes=0-0`）。
  static const Duration defaultHeadProbeTimeout = Duration(seconds: 5);

  /// 远程流式读取首包响应头超时上限（兼容网盘冷直链唤醒）。
  static const Duration defaultStreamOpenTimeout = Duration(seconds: 25);

  /// 持久连接空闲保活时长。
  static const Duration idleKeepAliveTimeout = Duration(seconds: 60);

  /// 单主机最大并发保活连接数（为视频/音频流、封面探测与画册灯箱预留并发槽位）。
  static const int maxConnectionsPerHost = 16;

  /// 允许跟踪的最大 30x 重定向跳数（防重定向循环）。
  static const int maxRedirects = 5;

  /// 302 直链 CDN 地址短周期缓存上限时长（避免每 4~16 MiB 分块都往返源站重复签发 302）。
  static const Duration redirectCacheTtl = Duration(seconds: 180);

  /// 解析直链查询参数中签名过期时间时预留的安全提前失效余量。
  static const Duration redirectExpirySafetyMargin = Duration(seconds: 15);

  /// 单个 WebDAV 槽位最多缓存的 302 重定向条目数（有界防内存增长）。
  static const int maxCachedRedirects = 64;

  /// 通用流媒体客户端标识（兼容网盘 302 CDN 与防火墙放行策略）。
  static const String defaultUserAgent = 'VLC/3.0.20 LibVLC/3.0.20';

  /// 判断目标主机是否属于回环、内网或虚拟网段（强制直连绕过代理）。
  static bool isDirectBypassHost(String rawHost) {
    var host = rawHost.trim().toLowerCase();
    if (host.startsWith('[') && host.endsWith(']') && host.length > 2) {
      host = host.substring(1, host.length - 1);
    }
    if (host.isEmpty ||
        host == 'localhost' ||
        host == '::1' ||
        host == '0:0:0:0:0:0:0:1' ||
        host.endsWith('.local') ||
        host.endsWith('.lan') ||
        host.endsWith('.internal')) {
      return true;
    }
    if (host.startsWith('fe80:') ||
        host.startsWith('fc') ||
        host.startsWith('fd')) {
      return true;
    }
    final parts = host.split('.');
    if (parts.length == 4) {
      final o0 = int.tryParse(parts[0]);
      final o1 = int.tryParse(parts[1]);
      final o2 = int.tryParse(parts[2]);
      final o3 = int.tryParse(parts[3]);
      if (o0 != null && o1 != null && o2 != null && o3 != null) {
        if (o0 == 127 || o0 == 10) return true;
        if (o0 == 192 && o1 == 168) return true;
        if (o0 == 169 && o1 == 254) return true;
        if (o0 == 172 && o1 >= 16 && o1 <= 31) return true;
        if (o0 == 100 && o1 >= 64 && o1 <= 127) return true;
      }
    }
    return false;
  }

  /// 智能代理路由：内网与回环强制直连，公网地址尊重系统环境代理配置。
  static String resolveSmartProxy(Uri uri) {
    if (isDirectBypassHost(uri.host)) {
      return 'DIRECT';
    }
    try {
      return HttpClient.findProxyFromEnvironment(uri);
    } catch (_) {
      return 'DIRECT';
    }
  }

  /// 创建统一调优的底层 [HttpClient]。
  static HttpClient createConfiguredIoClient() {
    return HttpClient()
      ..connectionTimeout = defaultConnectTimeout
      ..maxConnectionsPerHost = maxConnectionsPerHost
      ..idleTimeout = idleKeepAliveTimeout
      ..userAgent = defaultUserAgent
      ..findProxy = resolveSmartProxy;
  }
}

class _CachedRedirectEntry {
  const _CachedRedirectEntry({
    required this.targetUri,
    required this.expiresAt,
  });

  final Uri targetUri;
  final DateTime expiresAt;
}

class _WebDavPoolSlot {
  _WebDavPoolSlot({required this.client, this.ioClient});

  final HttpClient? ioClient;
  final http.Client client;
  String? digestChallenge;
  int nonceCount = 0;
  final Map<String, _CachedRedirectEntry> redirectCache =
      <String, _CachedRedirectEntry>{};

  void close() {
    redirectCache.clear();
    client.close();
    ioClient?.close(force: true);
  }
}

/// 跨网关实例共享的 WebDAV HTTP 保活连接池与 Digest 质询缓存。
class WebDavConnectionPool {
  /// 创建连接池实例（测试可注入自定义 [clientBuilder]）。
  WebDavConnectionPool({this.clientBuilder});

  /// 可选自定义 HTTP 客户端构建器。
  final http.Client Function()? clientBuilder;
  final Map<String, _WebDavPoolSlot> _slots = <String, _WebDavPoolSlot>{};
  bool _disposed = false;

  /// 根据协议、主机、端口、用户名及密码摘要构建隔离池键（绝不以明文缓存密码）。
  static String buildOriginKey({
    required Uri rootUri,
    String? username,
    String? password,
  }) {
    final scheme = rootUri.scheme.toLowerCase();
    final host = rootUri.host.toLowerCase();
    final port = rootUri.port;
    final user = username ?? '';
    final pwdHash = sha256.convert(utf8.encode(password ?? '')).toString();
    return '$scheme://$host:$port|$user|$pwdHash';
  }

  /// 当前连接池中已缓存的主机凭据槽位数量。
  int get activeHostCount => _slots.length;

  /// 获取或创建对应主机与凭据组合的持久 [http.Client]。
  http.Client acquireClient({
    required Uri rootUri,
    String? username,
    String? password,
  }) {
    if (_disposed) {
      throw StateError('WebDAV 连接池已释放');
    }
    final key = buildOriginKey(
      rootUri: rootUri,
      username: username,
      password: password,
    );
    return _ensureSlot(key).client;
  }

  _WebDavPoolSlot _ensureSlot(String key) {
    return _slots.putIfAbsent(key, () {
      if (clientBuilder != null) {
        return _WebDavPoolSlot(client: clientBuilder!());
      }
      final io = WebDavGatewayConfig.createConfiguredIoClient();
      return _WebDavPoolSlot(ioClient: io, client: IOClient(io));
    });
  }

  /// 读取对应源站最近缓存的 Digest `WWW-Authenticate` 质询头。
  String? readDigestChallenge({
    required Uri rootUri,
    String? username,
    String? password,
  }) {
    final key = buildOriginKey(
      rootUri: rootUri,
      username: username,
      password: password,
    );
    return _slots[key]?.digestChallenge;
  }

  /// 记录对应源站返回的最新 Digest `WWW-Authenticate` 质询并复位计数器。
  void rememberDigestChallenge({
    required Uri rootUri,
    String? username,
    String? password,
    required String challenge,
  }) {
    if (_disposed) return;
    final key = buildOriginKey(
      rootUri: rootUri,
      username: username,
      password: password,
    );
    final slot = _ensureSlot(key);
    slot.digestChallenge = challenge;
    slot.nonceCount = 0;
  }

  int _nextNonceCount({
    required Uri rootUri,
    String? username,
    String? password,
  }) {
    if (_disposed) return 1;
    final key = buildOriginKey(
      rootUri: rootUri,
      username: username,
      password: password,
    );
    final slot = _slots[key];
    if (slot == null) return 1;
    slot.nonceCount += 1;
    return slot.nonceCount;
  }

  Map<String, _CachedRedirectEntry>? _redirectCacheFor({
    required Uri rootUri,
    String? username,
    String? password,
  }) {
    if (_disposed) return null;
    final key = buildOriginKey(
      rootUri: rootUri,
      username: username,
      password: password,
    );
    return _ensureSlot(key).redirectCache;
  }

  /// 释放所有池化 HTTP 连接句柄与缓存质询（随全局容器销毁调用）。
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final slot in _slots.values) {
      slot.close();
    }
    _slots.clear();
  }
}
