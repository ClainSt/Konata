import 'package:konata_contracts/konata_contracts.dart';

import 'artwork_ref_codec.dart';

export 'package:konata_contracts/konata_contracts.dart'
    show ScrapeStatus, TmdbMediaType;

/// 作品强类型领域实体（与物理文件夹路径彻底解耦）。
class Work {
  /// 创建作品实例。
  const Work({
    required this.id,
    required this.title,
    this.tmdbId,
    this.tmdbMediaType,
    this.bangumiId,
    this.tvdbId,
    this.matchedSeason,
    this.originalTitle,
    this.year,
    this.overview,
    this.posterPath,
    this.posterFallback,
    this.bangumiPosterPath,
    this.backdropPath,
    this.portraitBackdropPath,
    this.logoPath,
    this.voteAverage,
    this.bangumiScore,
    this.folderTmdbHint,
    this.isManualLocked = false,
    this.metadataLocked = false,
    this.posterLocked = false,
    this.backdropLocked = false,
    this.portraitBackdropLocked = false,
    this.logoLocked = false,
    this.logoNegativeUntil,
    this.logoNegativeMask = 0,
    this.isHidden = false,
    this.keepHidden = false,
    this.scrapeStatus = ScrapeStatus.unmatched,
    this.reviewReason,
    this.seriesId,
    this.seriesOrder,
    this.seriesLabel,
    this.seriesLocked = false,
  });

  /// 作品唯一主键（UUID，与磁盘路径解耦）。
  final String id;

  /// 绑定的 TMDB 条目 ID。
  final int? tmdbId;

  /// 绑定的 TMDB 媒体类型（`tv` 或 `movie`）。
  final TmdbMediaType? tmdbMediaType;

  /// 绑定的 Bangumi 条目 ID（用于混合匹配或离线交叉验证）。
  final int? bangumiId;

  /// 关联的 TheTVDB 剧集 ID（来自 TMDB `external_ids` 或离线映射表，用于对接 Fanart.tv 剧集接口）。
  final int? tvdbId;

  /// 匹配的 TMDB 目标季号（用于多季拆卡与季级海报/年份/标题展示）。
  final int? matchedSeason;

  /// 展示标题。
  final String title;

  /// 原始标题（通常为日文或英文原名）。
  final String? originalTitle;

  /// 首播或上映年份。
  final int? year;

  /// 作品简介。
  final String? overview;

  /// 海报路径或远程路径标识。
  final String? posterPath;

  /// 备用海报路径（例如当选季海报缺失或剧集总海报回落）。
  final String? posterFallback;

  /// 关联的 Bangumi 官方封面 URL（用于详情页封面切换与回落展示）。
  final String? bangumiPosterPath;

  /// 背景图路径或远程路径标识。
  final String? backdropPath;

  /// 竖版无字原画路径或远程路径标识（供手机与平板竖屏详情页全宽展示）。
  final String? portraitBackdropPath;

  /// 官方透明 PNG 标题 Logo 路径。
  final String? logoPath;

  /// TMDB 评分（0.0 ~ 10.0）。
  final double? voteAverage;

  /// 关联 Bangumi 条目评分（0.0 ~ 10.0，详情页主评分显示源）。
  final double? bangumiScore;

  /// 从文件夹命名中显式提取到的 TMDB ID 提示。
  final int? folderTmdbHint;

  /// 是否已被人工纠错锁定（锁定后自动刮削不得更换绑定条目）。
  final bool isManualLocked;

  /// 基础元数据（标题/原名/年份/简介/匹配季）是否已人工锁定。
  final bool metadataLocked;

  /// 封面海报是否已人工锁定。
  final bool posterLocked;

  /// 横版背景原画是否已人工锁定。
  final bool backdropLocked;

  /// 竖版无字原画是否已人工锁定。
  final bool portraitBackdropLocked;

  /// 透明标题徽标是否已人工锁定（锁定后自动刮削与补全不得覆盖）。
  final bool logoLocked;

  /// 透明标题徽标负缓存冷却截止时间（未到期前不重复发起在线补查）。
  final DateTime? logoNegativeUntil;

  /// 上次透明标题徽标无图探测覆盖的数据源位掩码（详见 `ClearLogoNegativeMask`）。
  final int logoNegativeMask;

  /// 是否从主媒体库视图隐藏。
  final bool isHidden;

  /// 重扫后是否继续保持隐藏状态。
  final bool keepHidden;

  /// 当前刮削状态。
  final ScrapeStatus scrapeStatus;

  /// 作品级待复核/未匹配主要原因码。
  final String? reviewReason;

  /// 所属系列（Series）ID。
  final String? seriesId;

  /// 在所属系列中的排序序号（升序排列）。
  final int? seriesOrder;

  /// 在所属系列下拉切换器中的展示标签（如 `第 1 季`、`剧场版 Code: White`）。
  final String? seriesLabel;

  /// 系列编组归属与标签是否已被人工锁定（自动系列关联不得覆盖）。
  final bool seriesLocked;

  /// 复制并按需替换作品字段。
  Work copyWith({
    int? tmdbId,
    TmdbMediaType? tmdbMediaType,
    int? bangumiId,
    int? tvdbId,
    bool clearTvdbId = false,
    int? matchedSeason,
    String? title,
    String? originalTitle,
    int? year,
    String? overview,
    String? posterPath,
    String? posterFallback,
    String? bangumiPosterPath,
    String? backdropPath,
    String? portraitBackdropPath,
    String? logoPath,
    bool clearLogoPath = false,
    double? voteAverage,
    double? bangumiScore,
    int? folderTmdbHint,
    bool? isManualLocked,
    bool? metadataLocked,
    bool? posterLocked,
    bool? backdropLocked,
    bool? portraitBackdropLocked,
    bool? logoLocked,
    DateTime? logoNegativeUntil,
    bool clearLogoNegative = false,
    int? logoNegativeMask,
    bool? isHidden,
    bool? keepHidden,
    ScrapeStatus? scrapeStatus,
    String? reviewReason,
    String? seriesId,
    int? seriesOrder,
    String? seriesLabel,
    bool? seriesLocked,
    bool clearReviewReason = false,
    bool clearBangumiPosterPath = false,
    bool clearBackdropPath = false,
    bool clearPortraitBackdropPath = false,
    bool clearSeries = false,
  }) {
    return Work(
      id: id,
      tmdbId: tmdbId ?? this.tmdbId,
      tmdbMediaType: tmdbMediaType ?? this.tmdbMediaType,
      bangumiId: bangumiId ?? this.bangumiId,
      tvdbId: clearTvdbId ? null : (tvdbId ?? this.tvdbId),
      matchedSeason: matchedSeason ?? this.matchedSeason,
      title: title ?? this.title,
      originalTitle: originalTitle ?? this.originalTitle,
      year: year ?? this.year,
      overview: overview ?? this.overview,
      posterPath: posterPath ?? this.posterPath,
      posterFallback: posterFallback ?? this.posterFallback,
      bangumiPosterPath: clearBangumiPosterPath
          ? null
          : (bangumiPosterPath ?? this.bangumiPosterPath),
      backdropPath: clearBackdropPath
          ? null
          : (backdropPath ?? this.backdropPath),
      portraitBackdropPath: clearPortraitBackdropPath
          ? null
          : (portraitBackdropPath ?? this.portraitBackdropPath),
      logoPath: clearLogoPath ? null : (logoPath ?? this.logoPath),
      voteAverage: voteAverage ?? this.voteAverage,
      bangumiScore: bangumiScore ?? this.bangumiScore,
      folderTmdbHint: folderTmdbHint ?? this.folderTmdbHint,
      isManualLocked: isManualLocked ?? this.isManualLocked,
      metadataLocked: metadataLocked ?? this.metadataLocked,
      posterLocked: posterLocked ?? this.posterLocked,
      backdropLocked: backdropLocked ?? this.backdropLocked,
      portraitBackdropLocked:
          portraitBackdropLocked ?? this.portraitBackdropLocked,
      logoLocked: logoLocked ?? this.logoLocked,
      logoNegativeUntil: clearLogoNegative
          ? null
          : (logoNegativeUntil ?? this.logoNegativeUntil),
      logoNegativeMask: clearLogoNegative
          ? 0
          : (logoNegativeMask ?? this.logoNegativeMask),
      isHidden: isHidden ?? this.isHidden,
      keepHidden: keepHidden ?? this.keepHidden,
      scrapeStatus: scrapeStatus ?? this.scrapeStatus,
      reviewReason: clearReviewReason
          ? null
          : (reviewReason ?? this.reviewReason),
      seriesId: clearSeries ? null : (seriesId ?? this.seriesId),
      seriesOrder: clearSeries ? null : (seriesOrder ?? this.seriesOrder),
      seriesLabel: clearSeries ? null : (seriesLabel ?? this.seriesLabel),
      seriesLocked: seriesLocked ?? this.seriesLocked,
    );
  }

  /// 当前封面对应的强类型 [ArtworkRef]（自动识别 TMDB / Bangumi / Fanart / 本机自定义）。
  ArtworkRef? get posterRef =>
      ArtworkRefCodec.fromPath(posterPath, locked: posterLocked);

  /// 当前背景图对应的强类型 [ArtworkRef]。
  ArtworkRef? get backdropRef =>
      ArtworkRefCodec.fromPath(backdropPath, locked: backdropLocked);

  /// 当前竖版无字原画对应的强类型 [ArtworkRef]。
  ArtworkRef? get portraitBackdropRef => ArtworkRefCodec.fromPath(
    portraitBackdropPath,
    locked: portraitBackdropLocked,
  );

  /// 当前标题徽标对应的强类型 [ArtworkRef]。
  ArtworkRef? get logoRef =>
      ArtworkRefCodec.fromPath(logoPath, locked: logoLocked);
}
