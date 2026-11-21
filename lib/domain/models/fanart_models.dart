/// 透明徽标负缓存探测位掩码（标记上次无图结论已覆盖哪些能力源）。
abstract final class ClearLogoNegativeMask {
  /// 未记录任何负缓存。
  static const int none = 0;

  /// 已探测 TMDB `/images` 透明徽标。
  static const int tmdb = 1 << 0;

  /// 已探测 Fanart.tv 透明徽标（内置中继或自定义项目 Key）。
  static const int fanart = 1 << 1;

  /// 已携带用户 Personal Key（`client-key`）探测 Fanart.tv。
  static const int fanartWithClientKey = 1 << 2;
}

/// Fanart.tv 透明标题徽标分类档位。
enum FanartLogoKind {
  /// 高清剧集透明徽标（`hdtvlogo`，通常为 `800×310`）。
  hdTvLogo('hdtvlogo', 2),

  /// 标清剧集透明徽标（`clearlogo`，通常为 `400×155`）。
  clearLogo('clearlogo', 1),

  /// 高清电影透明徽标（`hdmovielogo`，通常为 `800×310`）。
  hdMovieLogo('hdmovielogo', 2),

  /// 标清电影透明徽标（`movielogo`，通常为 `400×155`）。
  movieLogo('movielogo', 1);

  const FanartLogoKind(this.jsonKey, this.qualityRank);

  /// Fanart.tv v3 响应体中的数组字段键名。
  final String jsonKey;

  /// 画质排序权重（高清优先于标清）。
  final int qualityRank;

  /// 是否为高清透明徽标。
  bool get isHd => qualityRank >= 2;
}

/// Fanart.tv 单张透明标题徽标候选条目。
class FanartLogoCandidate {
  /// 创建 Fanart.tv 透明徽标候选。
  const FanartLogoCandidate({
    required this.id,
    required this.url,
    required this.kind,
    this.lang,
    this.likes = 0,
  });

  /// Fanart.tv 资产唯一标识。
  final String id;

  /// 原始 HTTPS 透明 PNG 地址（通常位于 `assets.fanart.tv`）。
  final String url;

  /// 资产清晰度与媒体分类档位。
  final FanartLogoKind kind;

  /// 语言代码（如 `zh`、`ja`、`en`、`00` 或空）。
  final String? lang;

  /// 社区点赞数（用于同语言同画质内择优）。
  final int likes;
}

/// 单次 Fanart.tv 透明徽标拉取结果。
class FanartArtworkResult {
  /// 创建拉取结果。
  const FanartArtworkResult({
    this.logos = const [],
    this.notFound = false,
    this.authRejected = false,
  });

  /// 已按语言、高清档位与点赞数排序的透明徽标候选集。
  final List<FanartLogoCandidate> logos;

  /// 上游明确返回 404（条目在 Fanart.tv 尚无建档）。
  final bool notFound;

  /// 上游返回 401/403（用于触发内置通道短时熔断，避免死循环重试）。
  final bool authRejected;

  /// 排序第一的最优透明徽标地址。
  String? get bestLogoUrl => logos.isEmpty ? null : logos.first.url;
}
