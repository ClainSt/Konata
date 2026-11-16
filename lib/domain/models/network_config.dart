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
  static const String defaultBangumiBackupApiBase = 'https://api.bangumi.lat/v0';

  /// 默认 Bangumi 备用图片服务器地址。
  static const String defaultBangumiBackupImageBase = 'https://lain.bangumi.lat';

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
