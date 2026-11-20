import 'tmdb_models.dart';

/// 轻量代理接入模式（官方优先 + 备用自动回退架构下的外层通道选择）。
enum ProxyMode {
  /// 跟随操作系统代理设置（默认）。
  system,

  /// 使用用户指定的本地 HTTP/SOCKS 代理地址（如 `http://127.0.0.1:7890`）。
  custom,

  /// 不使用任何代理，强制直连。
  none,
}

/// 刮削与图床网络配置实体（官方地址优先 + 备用镜像自动容灾回退）。
class TmdbNetworkConfig {
  /// 创建网络配置实例。
  const TmdbNetworkConfig({
    this.credential = '',
    this.tmdbBackupApiBase = defaultTmdbBackupApiBase,
    this.tmdbBackupImageBase = defaultTmdbBackupImageBase,
    this.bangumiBackupApiBase = defaultBangumiBackupApiBase,
    this.bangumiBackupImageBase = defaultBangumiBackupImageBase,
    this.proxyMode = ProxyMode.system,
    this.proxyUrl = '',
  });

  /// 官方标准 TMDB API 根地址。
  static const String defaultApiBase = 'https://api.themoviedb.org/3';

  /// 官方标准 TMDB 图片根地址（UI 展示末尾带斜杠）。
  static const String defaultImageBaseDisplay = 'https://image.tmdb.org/t/p/';

  /// 官方标准 TMDB 图片根地址（无尾斜杠，便于路径拼接）。
  static const String defaultImageBase = 'https://image.tmdb.org/t/p';

  /// 默认 TMDB 备用 API 地址。
  static const String defaultTmdbBackupApiBase = 'https://api.tmdb.org/3';

  /// 默认 TMDB 备用图片服务器地址。
  static const String defaultTmdbBackupImageBase = 'https://images.tmdb.org/t/p/';

  /// 官方标准 Bangumi API 根地址。
  static const String defaultBangumiApiBase = 'https://api.bgm.tv/v0';

  /// 官方标准 Bangumi 图片根地址。
  static const String defaultBangumiImageBase = 'https://lain.bgm.tv';

  /// 默认 Bangumi 备用 API 地址。
  static const String defaultBangumiBackupApiBase = 'https://api.bgm.lat/v0';

  /// 默认 Bangumi 备用图片服务器地址。
  static const String defaultBangumiBackupImageBase = 'https://lain.bgm.lat';

  /// 已迁址的旧版默认 Bangumi 备用 API 地址（现对全部请求返回 301，POST 检索会被静默当作无结果），
  /// 加载持久化配置时自动替换为 [defaultBangumiBackupApiBase]。
  static const Set<String> retiredBangumiBackupApiBases = {
    'https://api.bangumi.lat/v0',
  };

  /// 已迁址的旧版默认 Bangumi 备用图片地址，加载时自动替换为 [defaultBangumiBackupImageBase]。
  static const Set<String> retiredBangumiBackupImageBases = {
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

  /// Scan 原图单帧解码内存上限（64 MiB）。
  static const int maxScanFullImageBytes = 64 * 1024 * 1024;

  /// Bangumi ↔ TMDB 离线映射表热更新镜像根地址（jsDelivr 双节点优先 + GitHub Raw 兜底）。
  static const List<String> mappingMirrorBases = <String>[
    'https://fastly.jsdelivr.net/gh/ClainSt/Konata@data/mapping',
    'https://gcore.jsdelivr.net/gh/ClainSt/Konata@data/mapping',
    'https://raw.githubusercontent.com/ClainSt/Konata/data/mapping',
  ];

  /// 远程映射表清单文件名。
  static const String mappingManifestFileName = 'manifest.json';

  /// 远程与本地映射表二进制索引文件名。
  static const String mappingBinaryFileName = 'bangumi_tmdb_map.bin';

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

  /// 映射表二进制文件大小安全上限（4 MiB，防止损坏或异常响应耗尽内存）。
  static const int maxMappingBinaryBytes = 4 * 1024 * 1024;

  /// 用户配置的 TMDB 凭证（v3 API Key 或 v4 Bearer Token）。
  final String credential;

  /// TMDB 备用 API 地址（官方不可达或超时自动回退）。
  final String tmdbBackupApiBase;

  /// TMDB 备用图片服务器地址（官方不可达或超时自动回退）。
  final String tmdbBackupImageBase;

  /// Bangumi 备用 API 地址（官方不可达或超时自动回退）。
  final String bangumiBackupApiBase;

  /// Bangumi 备用图片服务器地址（官方不可达或超时自动回退）。
  final String bangumiBackupImageBase;

  /// 代理模式（默认跟随系统代理）。
  final ProxyMode proxyMode;

  /// 自定义本地代理地址（如 `http://127.0.0.1:7890`）。
  final String proxyUrl;

  /// 自动识别当前凭证属于 v3 API Key 还是 v4 Read Access Token。
  TmdbCredentialKind get credentialKind {
    final trimmed = credential.trim();
    if (trimmed.isEmpty) return TmdbCredentialKind.none;
    if (trimmed.startsWith('eyJ')) return TmdbCredentialKind.v4BearerToken;
    return TmdbCredentialKind.v3ApiKey;
  }

  /// 主请求优先使用的官方 TMDB API Base URL。
  String get effectiveApiBase => defaultApiBase;

  /// 主请求优先使用的官方 TMDB 图片 Base URL。
  String get effectiveImageBase => defaultImageBase;

  /// 规范化后的 TMDB 备用 API Base URL（去尾斜杠；为空时返回空字符串）。
  String get normalizedTmdbBackupApiBase => _trimTrailingSlashes(tmdbBackupApiBase);

  /// 规范化后的 TMDB 备用图片 Base URL（去尾斜杠；为空时返回空字符串）。
  String get normalizedTmdbBackupImageBase =>
      _trimTrailingSlashes(tmdbBackupImageBase);

  /// 规范化后的 Bangumi 备用 API Base URL（去尾斜杠；为空时返回空字符串）。
  String get normalizedBangumiBackupApiBase =>
      _trimTrailingSlashes(bangumiBackupApiBase);

  /// 规范化后的 Bangumi 备用图片 Base URL（去尾斜杠；为空时返回空字符串）。
  String get normalizedBangumiBackupImageBase =>
      _trimTrailingSlashes(bangumiBackupImageBase);

  /// 复制并修改部分字段。
  TmdbNetworkConfig copyWith({
    String? credential,
    String? tmdbBackupApiBase,
    String? tmdbBackupImageBase,
    String? bangumiBackupApiBase,
    String? bangumiBackupImageBase,
    ProxyMode? proxyMode,
    String? proxyUrl,
  }) {
    return TmdbNetworkConfig(
      credential: credential ?? this.credential,
      tmdbBackupApiBase: tmdbBackupApiBase ?? this.tmdbBackupApiBase,
      tmdbBackupImageBase: tmdbBackupImageBase ?? this.tmdbBackupImageBase,
      bangumiBackupApiBase: bangumiBackupApiBase ?? this.bangumiBackupApiBase,
      bangumiBackupImageBase:
          bangumiBackupImageBase ?? this.bangumiBackupImageBase,
      proxyMode: proxyMode ?? this.proxyMode,
      proxyUrl: proxyUrl ?? this.proxyUrl,
    );
  }

  static String _trimTrailingSlashes(String raw) =>
      raw.trim().replaceAll(RegExp(r'/+$'), '');
}
