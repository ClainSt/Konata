import 'dart:convert';
import 'dart:typed_data';

/// 轻量代理接入模式（官方优先与备用自动回退架构下的外层通道选择）。
enum ProxyMode {
  /// 跟随操作系统代理设置（默认）。
  system,

  /// 使用用户指定的本地代理地址。
  custom,

  /// 不使用任何代理，强制直连。
  none,
}

/// TMDB 凭证自动识别类型。
enum TmdbCredentialKind {
  /// TMDB v3 接口密钥（通过查询参数传递）。
  v3ApiKey,

  /// TMDB v4 读取令牌（通过授权请求头传递）。
  v4BearerToken,

  /// 未配置或空凭证。
  none,
}

/// 网络请求优先级通道类型。
enum RequestPriority {
  /// 前台交互通道（海报墙封面、详情页、手动纠错搜索）。
  interactive,

  /// 后台批量刮削通道（受按域限流、退避与在途去重约束）。
  background,
}

/// 系统代理查询回调签名（供宿主组装根与离线测试按需注入）。
typedef SystemProxyResolver = Future<String?> Function(Uri uri);

/// HTTP 429 限流异常（携带服务端建议等待时长与响应摘要，区分频率限流与日额度耗尽）。
class RateLimitedHttpException implements Exception {
  /// 创建限流异常。
  const RateLimitedHttpException(
    this.retryAfter, [
    this.message = 'HTTP 429',
    this.headers = const <String, String>{},
    this.bodySnippet,
    this.isQuotaExhausted = false,
  ]);

  /// 建议退避等待时长。
  final Duration retryAfter;

  /// 描述信息。
  final String message;

  /// 原始响应头（用于区分频率限流与平台日额度耗尽）。
  final Map<String, String> headers;

  /// 截断后的响应正文片段。
  final String? bodySnippet;

  /// 是否已判定为日额度耗尽（为真时调度器不再退避重试）。
  final bool isQuotaExhausted;

  @override
  String toString() => 'RateLimitedHttpException($message, $retryAfter)';
}

/// 跨引擎无外部依赖的统一 HTTP 响应快照。
final class KonataHttpResponse {
  /// 创建 HTTP 响应快照。
  KonataHttpResponse({
    required this.statusCode,
    required Uint8List bodyBytes,
    Map<String, String> headers = const <String, String>{},
    this.reasonPhrase,
  }) : bodyBytes = Uint8List.fromList(bodyBytes),
       headers = Map<String, String>.unmodifiable(headers);

  /// 由 UTF-8 文本构建响应快照（便于单测与本地模拟）。
  factory KonataHttpResponse.text(
    String body, {
    int statusCode = 200,
    Map<String, String> headers = const <String, String>{},
    String? reasonPhrase,
  }) {
    return KonataHttpResponse(
      statusCode: statusCode,
      bodyBytes: Uint8List.fromList(utf8.encode(body)),
      headers: headers,
      reasonPhrase: reasonPhrase,
    );
  }

  /// HTTP 状态码。
  final int statusCode;

  /// 原始响应字节载荷。
  final Uint8List bodyBytes;

  /// 只读响应头映射。
  final Map<String, String> headers;

  /// 可选状态原因短语。
  final String? reasonPhrase;

  /// 按 UTF-8 容错解码后的文本正文。
  String get body => utf8.decode(bodyBytes, allowMalformed: true);
}

/// 刮削与图床统一网络配置实体（官方地址优先 + 备用镜像自动容灾回退）。
class KonataNetworkConfig {
  /// 创建网络配置实例。
  const KonataNetworkConfig({
    this.credential = '',
    this.tmdbBackupApiBase = defaultTmdbBackupApiBase,
    this.tmdbBackupImageBase = defaultTmdbBackupImageBase,
    this.bangumiBackupApiBase = defaultBangumiBackupApiBase,
    this.bangumiBackupImageBase = defaultBangumiBackupImageBase,
    this.fanartClientKey = '',
    this.fanartApiKeyOverride = '',
    this.fanartBackupApiBase = builtInFanartRelayBase,
    this.fanartBackupImageBase = '',
    this.proxyMode = ProxyMode.system,
    this.proxyUrl = '',
  });

  /// 官方标准 TMDB 接口根地址。
  static const String defaultApiBase = 'https://api.themoviedb.org/3';

  /// 官方标准 TMDB 图片根地址（界面展示末尾带斜杠）。
  static const String defaultImageBaseDisplay = 'https://image.tmdb.org/t/p/';

  /// 官方标准 TMDB 图片根地址（无尾斜杠，便于路径拼接）。
  static const String defaultImageBase = 'https://image.tmdb.org/t/p';

  /// 默认 TMDB 备用接口地址。
  static const String defaultTmdbBackupApiBase = 'https://api.tmdb.org/3';

  /// 默认 TMDB 备用图片服务器地址。
  static const String defaultTmdbBackupImageBase =
      'https://images.tmdb.org/t/p/';

  /// 官方标准 Bangumi 接口根地址。
  static const String defaultBangumiApiBase = 'https://api.bgm.tv/v0';

  /// 官方标准 Bangumi 图片根地址。
  static const String defaultBangumiImageBase = 'https://lain.bgm.tv';

  /// 默认 Bangumi 备用接口地址。
  static const String defaultBangumiBackupApiBase = 'https://api.bgm.lat/v0';

  /// 默认 Bangumi 备用图片服务器地址。
  static const String defaultBangumiBackupImageBase = 'https://lain.bgm.lat';

  /// 官方标准 Fanart.tv 接口根地址。
  static const String defaultFanartApiBase = 'https://webservice.fanart.tv/v3';

  /// 官方标准 Fanart.tv 图片分发根地址。
  static const String defaultFanartImageBase = 'https://assets.fanart.tv';

  /// 默认公开的无状态中继根地址（不含任何私钥）。
  static const String defaultFanartRelayBase = 'https://api.konata.acgcc.cn';

  static const String _envFanartRelayBase = String.fromEnvironment(
    'KONATA_FANART_RELAY_BASE',
  );

  /// 内置无状态中继根地址（支持通过编译期常量覆盖，空串自动回退默认中继）。
  static const String builtInFanartRelayBase = _envFanartRelayBase != ''
      ? _envFanartRelayBase
      : defaultFanartRelayBase;

  /// 编译期注入的 Fanart 项目密钥（源码默认为空）。
  static const String compileTimeFanartApiKey = String.fromEnvironment(
    'FANART_API_KEY',
    defaultValue: '',
  );

  /// Fanart 个人密钥免费申请页地址。
  static const String fanartGetApiKeyUrl = 'https://fanart.tv/get-an-api-key/';

  /// 已迁址的旧版默认 Bangumi 备用接口地址，加载持久化配置时自动替换。
  static const Set<String> retiredBangumiBackupApiBases = <String>{
    'https://api.bangumi.lat/v0',
  };

  /// 已迁址的旧版默认 Bangumi 备用图片地址，加载时自动替换。
  static const Set<String> retiredBangumiBackupImageBases = <String>{
    'https://lain.bangumi.lat',
  };

  /// 官方外部站点与设置输入提示常量。
  static const String tmdbHomeUrl = 'https://www.themoviedb.org/';
  static const String tmdbSignupUrl = 'https://www.themoviedb.org/signup';
  static const String tmdbApiSettingsUrl =
      'https://www.themoviedb.org/settings/api';
  static const String githubRepoUrl = 'https://github.com/ClainSt/Konata';
  static const String defaultLocalProxyHint = 'http://127.0.0.1:7890';
  static const String defaultWebDavHint = 'https://nas.local:5006/Anime';

  /// 扫图原图单帧解码内存上限（64 MiB）。
  static const int maxScanFullImageBytes = 64 * 1024 * 1024;

  /// Bangumi 与 TMDB 离线映射表热更新镜像根地址。
  static const List<String> mappingMirrorBases = <String>[
    'https://fastly.jsdelivr.net/gh/ClainSt/Konata@data/mapping',
    'https://gcore.jsdelivr.net/gh/ClainSt/Konata@data/mapping',
    'https://raw.githubusercontent.com/ClainSt/Konata/data/mapping',
  ];

  /// 远程映射表清单文件名（兼容 v1 与含电视库编号的 v2）。
  static const String mappingManifestFileName = 'manifest.json';
  static const String mappingV2ManifestFileName = 'manifest_v2.json';

  /// 远程与本地映射表二进制索引文件名。
  static const String mappingBinaryFileName = 'bangumi_tmdb_map.bin';
  static const String mappingV2BinaryFileName = 'bangumi_tmdb_map_v2.bin';

  /// 本地持久化清单缓存文件名。
  static const String localMappingManifestFileName =
      'bangumi_tmdb_manifest.json';

  /// 随安装包内置的映射表二进制资源路径。
  static const String bundledMappingAssetPath =
      'assets/data/bangumi_tmdb_map.bin';

  /// 扫描前自动检查映射表更新的冷却周期（24 小时）。
  static const Duration mappingAutoCheckInterval = Duration(hours: 24);

  /// 单次清单探测超时时间。
  static const Duration mappingCheckTimeout = Duration(seconds: 4);

  /// 单次映射表二进制下载超时时间。
  static const Duration mappingDownloadTimeout = Duration(seconds: 12);

  /// 扫描前静默检查的总耗时上限（避免断网时阻塞扫描启动）。
  static const Duration mappingSilentCheckBudget = Duration(seconds: 5);

  /// 手动点击检查更新的总耗时上限。
  static const Duration mappingManualCheckBudget = Duration(seconds: 20);

  /// 映射表二进制文件大小安全上限（4 MiB）。
  static const int maxMappingBinaryBytes = 4 * 1024 * 1024;

  /// 用户配置的 TMDB 凭证（v3 密钥或 v4 读取令牌）。
  final String credential;

  /// TMDB 备用接口地址。
  final String tmdbBackupApiBase;

  /// TMDB 备用图片服务器地址。
  final String tmdbBackupImageBase;

  /// Bangumi 备用接口地址。
  final String bangumiBackupApiBase;

  /// Bangumi 备用图片服务器地址。
  final String bangumiBackupImageBase;

  /// 用户选填的 Fanart 个人客户端密钥。
  final String fanartClientKey;

  /// 高级设置选填的自定义 Fanart 项目密钥（填写后覆盖内置中继）。
  final String fanartApiKeyOverride;

  /// Fanart 无状态中继或备用接口根地址。
  final String fanartBackupApiBase;

  /// Fanart 备用图片反代服务器地址。
  final String fanartBackupImageBase;

  /// 代理模式（默认跟随系统代理）。
  final ProxyMode proxyMode;

  /// 自定义本地代理地址。
  final String proxyUrl;

  /// 自动识别当前凭证属于 v3 密钥还是 v4 令牌。
  TmdbCredentialKind get credentialKind {
    final trimmed = credential.trim();
    if (trimmed.isEmpty) return TmdbCredentialKind.none;
    if (trimmed.startsWith('eyJ')) return TmdbCredentialKind.v4BearerToken;
    return TmdbCredentialKind.v3ApiKey;
  }

  /// 主请求优先使用的官方 TMDB 接口根地址。
  String get effectiveApiBase => defaultApiBase;

  /// 主请求优先使用的官方 TMDB 图片根地址。
  String get effectiveImageBase => defaultImageBase;

  /// 规范化后的 TMDB 备用接口地址（去尾斜杠）。
  String get normalizedTmdbBackupApiBase =>
      _trimTrailingSlashes(tmdbBackupApiBase);

  /// 规范化后的 TMDB 备用图片地址（去尾斜杠）。
  String get normalizedTmdbBackupImageBase =>
      _trimTrailingSlashes(tmdbBackupImageBase);

  /// 规范化后的 Bangumi 备用接口地址（去尾斜杠）。
  String get normalizedBangumiBackupApiBase =>
      _trimTrailingSlashes(bangumiBackupApiBase);

  /// 规范化后的 Bangumi 备用图片地址（去尾斜杠）。
  String get normalizedBangumiBackupImageBase =>
      _trimTrailingSlashes(bangumiBackupImageBase);

  /// 规范化后的 Fanart 中继或备用接口地址（为空时回退内置中继）。
  String get normalizedFanartBackupApiBase {
    final trimmed = _trimTrailingSlashes(fanartBackupApiBase);
    if (trimmed.isNotEmpty) return trimmed;
    return _trimTrailingSlashes(builtInFanartRelayBase);
  }

  /// 直连自定义密钥模式下可用的备用反代地址（排除内置公开中继，防止发送私有密钥）。
  String get normalizedFanartDirectBackupApiBase {
    final trimmed = _trimTrailingSlashes(fanartBackupApiBase);
    if (trimmed.isEmpty) return '';
    final builtIn = _trimTrailingSlashes(builtInFanartRelayBase);
    if (trimmed.toLowerCase() == builtIn.toLowerCase()) return '';
    return trimmed;
  }

  /// 规范化后的 Fanart 备用图片地址（去尾斜杠）。
  String get normalizedFanartBackupImageBase =>
      _trimTrailingSlashes(fanartBackupImageBase);

  /// 解析最终生效的 Fanart 项目密钥（设置手填优先，其次编译期注入）。
  static String resolveEffectiveFanartApiKey({
    required String manualOverride,
    String compileTimeKey = compileTimeFanartApiKey,
  }) {
    final manual = manualOverride.trim();
    if (manual.isNotEmpty) return manual;
    return compileTimeKey.trim();
  }

  /// 当前实际生效的 Fanart 项目密钥。
  String get effectiveFanartApiKey =>
      resolveEffectiveFanartApiKey(manualOverride: fanartApiKeyOverride);

  /// 当前是否具备直连官方 Fanart 的项目密钥。
  bool get hasCustomFanartApiKey => effectiveFanartApiKey.isNotEmpty;

  /// 当前是否填写了用户选填的 Fanart 个人客户端密钥。
  bool get hasFanartClientKey => fanartClientKey.trim().isNotEmpty;

  /// 当前是否具备可用的 Fanart 查询通道。
  bool get isFanartAvailable =>
      hasCustomFanartApiKey || normalizedFanartBackupApiBase.isNotEmpty;

  /// 复制并修改部分字段。
  KonataNetworkConfig copyWith({
    String? credential,
    String? tmdbBackupApiBase,
    String? tmdbBackupImageBase,
    String? bangumiBackupApiBase,
    String? bangumiBackupImageBase,
    String? fanartClientKey,
    String? fanartApiKeyOverride,
    String? fanartBackupApiBase,
    String? fanartBackupImageBase,
    ProxyMode? proxyMode,
    String? proxyUrl,
  }) {
    return KonataNetworkConfig(
      credential: credential ?? this.credential,
      tmdbBackupApiBase: tmdbBackupApiBase ?? this.tmdbBackupApiBase,
      tmdbBackupImageBase: tmdbBackupImageBase ?? this.tmdbBackupImageBase,
      bangumiBackupApiBase: bangumiBackupApiBase ?? this.bangumiBackupApiBase,
      bangumiBackupImageBase:
          bangumiBackupImageBase ?? this.bangumiBackupImageBase,
      fanartClientKey: fanartClientKey ?? this.fanartClientKey,
      fanartApiKeyOverride: fanartApiKeyOverride ?? this.fanartApiKeyOverride,
      fanartBackupApiBase: fanartBackupApiBase ?? this.fanartBackupApiBase,
      fanartBackupImageBase:
          fanartBackupImageBase ?? this.fanartBackupImageBase,
      proxyMode: proxyMode ?? this.proxyMode,
      proxyUrl: proxyUrl ?? this.proxyUrl,
    );
  }

  static String _trimTrailingSlashes(String raw) =>
      raw.trim().replaceAll(RegExp(r'/+$'), '');
}

/// 兼容旧称呼的类型别名，统一指向 [KonataNetworkConfig]。
typedef TmdbNetworkConfig = KonataNetworkConfig;

/// 网络异常密钥脱敏与简体中文错误文案转译工具。
///
/// 统一清洗日志、异常堆栈及界面报错中的敏感凭据，
/// 并将底层套接字、域名解析、握手与超时异常转换为面向用户的中文提示。
abstract final class NetworkErrorSanitizer {
  static final RegExp _apiKeyQueryPattern = RegExp(
    r'((?:api_key|client_key|api-key|client-key|access_token|token|pat|password|passwd|secret)\s*[=:]\s*)([^&\s)\x27",;}\]]+)',
    caseSensitive: false,
  );
  static final RegExp _encodedApiKeyPattern = RegExp(
    r'((?:api_key|client_key|access_token|token|password)%3d)([^&\s)\x27",;%]+)',
    caseSensitive: false,
  );
  static final RegExp _jsonSecretPattern = RegExp(
    r'("(?:api_key|client_key|access_token|token|pat|password|passwd|secret|credential|authorization)"\s*:\s*")([^"]*)(")',
    caseSensitive: false,
  );
  static final RegExp _bearerTokenPattern = RegExp(
    r'(Bearer\s+)([A-Za-z0-9\-._~+/]+=*)',
    caseSensitive: false,
  );
  static final RegExp _basicAuthPattern = RegExp(
    r'(Basic\s+)([A-Za-z0-9+/]+=*)',
    caseSensitive: false,
  );
  static final RegExp _digestResponsePattern = RegExp(
    r'(response\s*=\s*")([^"]+)(")',
    caseSensitive: false,
  );
  static final RegExp _urlUserInfoPattern = RegExp(
    r'(https?://[^/\s:@]+:)([^/\s@]+)(@)',
    caseSensitive: false,
  );
  static final RegExp _windowsUserHomePattern = RegExp(
    r'[A-Za-z]:\\Users\\[^\\/\s"\x27]+',
  );
  static final RegExp _unixUserHomePattern = RegExp(
    r'/(?:Users|home)/[^/\s"\x27]+',
  );
  static final RegExp _hostLookupPattern = RegExp(
    r"Failed host lookup:\s*'([^']+)'",
    caseSensitive: false,
  );

  /// 将文本中所有明文或编码态凭据、授权请求头与地址内嵌密码替换为脱敏占位符。
  static String redactSecrets(String input) {
    if (input.isEmpty) return input;
    return input
        .replaceAllMapped(_urlUserInfoPattern, (m) => '${m[1]}***${m[3]}')
        .replaceAllMapped(_jsonSecretPattern, (m) => '${m[1]}***${m[3]}')
        .replaceAllMapped(_apiKeyQueryPattern, (m) => '${m[1]}***')
        .replaceAllMapped(_encodedApiKeyPattern, (m) => '${m[1]}***')
        .replaceAllMapped(_bearerTokenPattern, (m) => '${m[1]}***')
        .replaceAllMapped(_basicAuthPattern, (m) => '${m[1]}***')
        .replaceAllMapped(_digestResponsePattern, (m) => '${m[1]}***${m[3]}');
  }

  /// 对导出的诊断文本进一步隐藏本机操作系统用户名目录前缀。
  static String redactForDiagnosticsExport(String input) {
    final secretSafe = redactSecrets(input);
    if (secretSafe.isEmpty) return secretSafe;
    return secretSafe
        .replaceAll(_windowsUserHomePattern, r'<USER_HOME>')
        .replaceAll(_unixUserHomePattern, '<USER_HOME>');
  }

  /// 判断异常是否属于可降级容错的外部网络瞬态异常。
  static bool isTransientNetworkError(Object error) {
    final text = error.toString().toLowerCase();
    if (text.contains('http 401') ||
        text.contains('http 403') ||
        text.contains('密钥无效')) {
      return false;
    }
    return text.contains('failed host lookup') ||
        text.contains('no address associated with hostname') ||
        text.contains('socketexception') ||
        text.contains('timeoutexception') ||
        text.contains('timed out') ||
        text.contains('handshakeexception') ||
        text.contains('tlsexception') ||
        text.contains('certificate_verify_failed') ||
        text.contains('connection closed') ||
        text.contains('connection refused') ||
        text.contains('connection reset') ||
        text.contains('network is unreachable') ||
        text.contains('software caused connection abort') ||
        text.contains('clientexception');
  }

  /// 将底层网络或业务异常脱敏并转译为清晰的简体中文提示。
  static String toUserMessage(Object error, {String? prefix}) {
    final raw = redactSecrets(error.toString()).trim();
    final lower = raw.toLowerCase();
    final head = (prefix != null && prefix.trim().isNotEmpty)
        ? '${prefix.trim()}：'
        : '';

    if (lower.contains('failed host lookup') ||
        lower.contains('no address associated with hostname')) {
      final hostMatch = _hostLookupPattern.firstMatch(raw);
      final host = hostMatch?.group(1)?.trim() ?? '';
      final hostLabel = host.isNotEmpty ? '（$host）' : '';
      return '$head域名解析失败$hostLabel，请检查网络连接、系统代理或备用镜像配置';
    }
    if (lower.contains('timeoutexception') || lower.contains('timed out')) {
      return '$head服务器连接超时，请检查网络环境或代理设置后重试';
    }
    if (lower.contains('handshakeexception') ||
        lower.contains('tlsexception') ||
        lower.contains('certificate_verify_failed')) {
      return '$head安全连接握手异常，请检查网络代理或证书环境';
    }
    if (lower.contains('connection refused')) {
      return '$head目标服务器拒绝连接，请检查服务地址或代理端口';
    }
    if (lower.contains('connection reset') ||
        lower.contains('connection closed') ||
        lower.contains('software caused connection abort')) {
      return '$head网络连接意外中断，请稍后重试';
    }
    if (lower.contains('network is unreachable') ||
        lower.contains('socketexception')) {
      return '$head网络不可达，请检查当前设备网络或代理连接';
    }

    final cleaned = raw
        .replaceFirst(RegExp(r'^(StateError|Exception|FormatException):\s*'), '')
        .replaceFirst(RegExp(r'^Bad state:\s*'), '')
        .trim();
    if (cleaned.isEmpty) {
      return '$head请求发生未知异常';
    }
    if (head.isNotEmpty && !cleaned.startsWith(prefix!.trim())) {
      return '$head$cleaned';
    }
    return cleaned;
  }
}

/// 跨引擎统一 HTTP 传输客户端抽象端口（由 `engine_sources` 的 `KonataHttpClient` 实现）。
abstract interface class KonataHttpClientPort {
  /// 当前生效的网络配置。
  KonataNetworkConfig get config;

  /// 更新网络配置并重置底层连接与冷却状态。
  void updateConfig(KonataNetworkConfig next);

  /// 发起单链路 GET 请求。
  Future<KonataHttpResponse> get(
    Uri uri, {
    Map<String, String> headers = const <String, String>{},
    RequestPriority priority = RequestPriority.background,
    String? dedupeKey,
    String? bucketKey,
  });

  /// 发起支持官方主备自动回退的 GET 请求。
  Future<KonataHttpResponse> getWithFallback(
    Uri primaryUri, {
    Uri? backupUri,
    Map<String, String> headers = const <String, String>{},
    RequestPriority priority = RequestPriority.background,
    String? dedupeKey,
    String? bucketKey,
    bool retryOnRateLimit = true,
    Duration? timeoutOverride,
  });

  /// 发起单链路 POST 请求。
  Future<KonataHttpResponse> post(
    Uri uri, {
    Map<String, String> headers = const <String, String>{},
    Object? body,
    RequestPriority priority = RequestPriority.background,
    String? dedupeKey,
    String? bucketKey,
  });

  /// 发起支持官方主备自动回退的 POST 请求。
  Future<KonataHttpResponse> postWithFallback(
    Uri primaryUri, {
    Uri? backupUri,
    Map<String, String> headers = const <String, String>{},
    Object? body,
    RequestPriority priority = RequestPriority.background,
    String? dedupeKey,
    String? bucketKey,
    bool retryOnRateLimit = true,
    Duration? timeoutOverride,
  });

  /// 发起支持官方主备自动回退与自定义动词的通用请求。
  Future<KonataHttpResponse> sendWithFallback({
    required String method,
    required Uri primaryUri,
    Uri? backupUri,
    Map<String, String> headers = const <String, String>{},
    Object? body,
    RequestPriority priority = RequestPriority.background,
    String? dedupeKey,
    String? bucketKey,
    bool retryOnRateLimit = true,
    Duration? timeoutOverride,
  });

  /// 释放底层连接池资源。
  void close();
}
