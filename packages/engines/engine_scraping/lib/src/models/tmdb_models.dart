import 'package:konata_contracts/konata_contracts.dart';

import 'work.dart';

export 'package:konata_contracts/konata_contracts.dart'
    show TmdbCredentialKind;

/// TMDB 搜索候选条目。
class TmdbSearchResult {
  /// 创建 TMDB 搜索结果。
  const TmdbSearchResult({
    required this.tmdbId,
    required this.mediaType,
    required this.title,
    this.originalTitle,
    this.year,
    this.overview,
    this.posterPath,
    this.backdropPath,
    this.genreIds = const [],
  });

  /// TMDB 条目 ID。
  final int tmdbId;

  /// 媒体类型（`tv` 或 `movie`）。
  final TmdbMediaType mediaType;

  /// 本地化标题（优先简体中文）。
  final String title;

  /// 原始语言标题（通常为日文或英文）。
  final String? originalTitle;

  /// 首播或上映年份。
  final int? year;

  /// 作品简介。
  final String? overview;

  /// 海报相对路径。
  final String? posterPath;

  /// 背景图相对路径。
  final String? backdropPath;

  /// TMDB 类型标签 ID 列表（`16` 为动画）。
  final List<int> genreIds;
}

/// TMDB 单季摘要信息。
class TmdbSeasonSummary {
  /// 创建季摘要实例。
  const TmdbSeasonSummary({
    required this.seasonNumber,
    required this.name,
    required this.episodeCount,
    this.airDate,
    this.posterPath,
  });

  /// 季号（`0` 为特典/Specials，正片从 `1` 起）。
  final int seasonNumber;

  /// 季名称。
  final String name;

  /// 该季总集数。
  final int episodeCount;

  /// 首播日期字符串。
  final String? airDate;

  /// 季海报路径。
  final String? posterPath;
}

/// TMDB 单集详细信息。
class TmdbEpisodeDetail {
  /// 创建单集详情实例。
  const TmdbEpisodeDetail({
    required this.seasonNumber,
    required this.episodeNumber,
    required this.title,
    this.overview,
    this.stillPath,
    this.airDate,
  });

  /// 所属季号。
  final int seasonNumber;

  /// 集号。
  final int episodeNumber;

  /// 单集标题。
  final String title;

  /// 单集简介。
  final String? overview;

  /// 剧照相对路径。
  final String? stillPath;

  /// 播出日期。
  final String? airDate;
}

/// TMDB 单季完整详情（包含单季封面、季名、简介与全部分集）。
class TmdbSeasonDetail {
  /// 创建单季详情实例。
  const TmdbSeasonDetail({
    required this.seasonNumber,
    required this.name,
    this.overview,
    this.airDate,
    this.posterPath,
    this.portraitBackdropPath,
    this.candidatePosters = const [],
    this.episodes = const [],
  });

  /// 季号（0 为特典/Specials，正片从 1 起）。
  final int seasonNumber;

  /// 季标题（如 `Wake Up, Girls! 新章` 或 `第 2 季`）。
  final String name;

  /// 季简介。
  final String? overview;

  /// 首播日期字符串。
  final String? airDate;

  /// 单季专属海报相对路径。
  final String? posterPath;

  /// 单季专属无字竖版原画路径（直接筛选自 `posters` 数组中 `iso_639_1 == null` 条目）。
  final String? portraitBackdropPath;

  /// 单季专属候选海报列表（按清晰度、中日无字优先级与贝叶斯热度排序）。
  final List<TmdbArtworkImage> candidatePosters;

  /// 该季分集列表。
  final List<TmdbEpisodeDetail> episodes;
}

/// TMDB 候选海报 / 背景图条目。
class TmdbArtworkImage {
  /// 创建候选图条目。
  const TmdbArtworkImage({
    required this.filePath,
    this.isoLanguage,
    this.isoCountry,
    this.width,
    this.height,
    this.voteAverage,
    this.voteCount,
  });

  /// TMDB 相对图片路径。
  final String filePath;

  /// 语言代码（如 `zh`、`ja`、`en`）。
  final String? isoLanguage;

  /// 国家或地区细分代码（如 `CN`、`TW`、`HK`，用于区分简繁体中文徽标）。
  final String? isoCountry;

  /// 宽度像素。
  final int? width;

  /// 高度像素。
  final int? height;

  /// 用户评分。
  final double? voteAverage;

  /// 社区投票人数（用于区分官方高投票与零票误传条目）。
  final int? voteCount;
}

/// TMDB 作品完整详情（融合 `alternative_titles`、`translations` 与 `credits`）。
class TmdbWorkDetail {
  /// 创建 TMDB 作品详情实例。
  const TmdbWorkDetail({
    required this.tmdbId,
    required this.mediaType,
    required this.title,
    this.originalTitle,
    this.year,
    this.overview,
    this.posterPath,
    this.backdropPath,
    this.portraitBackdropPath,
    this.logoPath,
    this.voteAverage,
    this.voteCount,
    this.aliases = const [],
    this.seasons = const [],
    this.candidatePosters = const [],
    this.candidateBackdrops = const [],
    this.candidateLogos = const [],
    this.collectionId,
    this.collectionName,
    this.tvdbId,
    this.genreIds = const [],
    this.imagesLoaded = true,
  });

  /// TMDB 条目 ID。
  final int tmdbId;

  /// 媒体类型。
  final TmdbMediaType mediaType;

  /// 首选展示标题（优先简体中文）。
  final String title;

  /// 原始语言标题（通常为日文或英文）。
  final String? originalTitle;

  /// 首播或上映年份。
  final int? year;

  /// 作品简介。
  final String? overview;

  /// 海报路径。
  final String? posterPath;

  /// 背景图路径。
  final String? backdropPath;

  /// 竖版无字原画路径（复用 `posters` 数组中 `iso_639_1 == null` 候选，零新增请求）。
  final String? portraitBackdropPath;

  /// 官方透明 PNG 标题 Logo 路径。
  final String? logoPath;

  /// TMDB 评分（0.0 ~ 10.0）。
  final double? voteAverage;

  /// TMDB 评分人数（`0` 多为新建的低质量重复条目；未知时为空）。
  final int? voteCount;

  /// 合并主副标题、多语言翻译与别名后的全部名称列表。
  final List<String> aliases;

  /// 剧集季列表（电影为空）。
  final List<TmdbSeasonSummary> seasons;

  /// 候选封面海报列表。
  final List<TmdbArtworkImage> candidatePosters;

  /// 候选背景图列表。
  final List<TmdbArtworkImage> candidateBackdrops;

  /// 候选透明标题徽标列表。
  final List<TmdbArtworkImage> candidateLogos;

  /// 所属 TMDB 合集 ID（如多部剧场版同属一条 `belongs_to_collection`）。
  final int? collectionId;

  /// 所属 TMDB 合集名称。
  final String? collectionName;

  /// 关联的 TheTVDB 剧集 ID（通过 `append_to_response=external_ids` 随详情一并拉取）。
  final int? tvdbId;

  /// TMDB 类型标签 ID 列表（`16` 为动画）。
  final List<int> genreIds;

  /// 是否已一并拉取完整图像候选集（轻量候选初筛模式为 `false`，确认绑定后按需补全高清图集）。
  final bool imagesLoaded;
}

/// 待复核候选持久化摘要实体。
class ScrapeCandidateSummary {
  /// 创建候选摘要实例。
  const ScrapeCandidateSummary({
    required this.workId,
    required this.tmdbId,
    required this.mediaType,
    required this.title,
    this.originalTitle,
    this.year,
    this.episodeCount,
    this.posterPath,
    required this.score,
    required this.rank,
    this.reasons = const [],
  });

  /// 所属作品主键 ID。
  final String workId;

  /// 候选 TMDB ID。
  final int tmdbId;

  /// 候选媒体类型。
  final TmdbMediaType mediaType;

  /// 候选标题。
  final String title;

  /// 候选原名。
  final String? originalTitle;

  /// 候选年份。
  final int? year;

  /// 候选总集数（TV 汇总各正片季集数，电影为 1）。
  final int? episodeCount;

  /// 海报路径。
  final String? posterPath;

  /// 匹配得分（0~100+）。
  final double score;

  /// 排序名次（从 1 开始）。
  final int rank;

  /// 命中或扣分原因列表。
  final List<String> reasons;
}

/// TMDB 图片物理分辨率档位。
enum TmdbImageSize {
  /// 列表与海报缩略图（w342）。
  w342('w342', 1),

  /// 标准海报/剧照（w500）。
  w500('w500', 2),

  /// 高清海报/预览背景（w780）。
  w780('w780', 3),

  /// 全高清背景图（w1280）。
  w1280('w1280', 4),

  /// 无压缩官方原画（original）。
  original('original', 5);

  const TmdbImageSize(this.apiSegment, this.qualityRank);

  /// TMDB CDN URL 分段标识。
  final String apiSegment;

  /// 档位质量排序等级（数值越大画质越高）。
  final int qualityRank;
}
