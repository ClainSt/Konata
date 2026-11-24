import 'package:engine_scraping/engine_scraping.dart';

/// 单文件手动剧集/特典重映射提交项。
class EpisodeFileMappingEdit {
  /// 创建文件映射编辑请求。
  const EpisodeFileMappingEdit({
    required this.variantId,
    required this.category,
    required this.seasonNumber,
    required this.episodeNumber,
    this.extraType,
    this.lockMapping = true,
  });

  /// 物理视频变体唯一主键。
  final String variantId;

  /// 目标分类（正片或特典）。
  final EpisodeCategory category;

  /// 目标季号（特典自动归为 `0` 季）。
  final int seasonNumber;

  /// 目标集号或特典序号。
  final int episodeNumber;

  /// 特典细分类型。
  final ExtraKind? extraType;

  /// 是否持久化锁定此映射防止重扫覆盖。
  final bool lockMapping;
}

/// 附属资源（特典 / CD / Scan）作用域可编辑条目上下文。
class SupplementaryEditableItem {
  /// 创建附属资源编辑上下文。
  const SupplementaryEditableItem({
    required this.variant,
    required this.ownerWorkId,
    required this.ownerWorkTitle,
    this.episode,
  });

  /// 物理文件版本记录。
  final MediaVariant variant;

  /// 当前所属作品主键。
  final String ownerWorkId;

  /// 当前所属作品标题。
  final String ownerWorkTitle;

  /// 关联逻辑特典条目（仅视频特典非空）。
  final Episode? episode;
}

/// 系列内成员排序与展示标签编辑请求。
class SeriesMemberEdit {
  /// 创建系列成员编辑项。
  const SeriesMemberEdit({
    required this.workId,
    required this.order,
    required this.label,
  });

  /// 作品唯一主键。
  final String workId;

  /// 排序序号（从 `1` 起）。
  final int order;

  /// 展示标签（如 `第 1 季`、`剧场版`）。
  final String label;
}

/// 附属资源共享范围编辑请求。
class SupplementaryScopeEdit {
  /// 创建附属资源范围编辑项。
  const SupplementaryScopeEdit({
    required this.variantId,
    required this.scope,
    required this.targetWorkId,
  });

  /// 物理文件版本主键。
  final String variantId;

  /// 目标可见范围（独享或全系列共享）。
  final SupplementaryAssetScope scope;

  /// 独享模式下的归属目标作品主键。
  final String targetWorkId;
}

/// `Bangumi` 独立条目与 `TMDB` 指定季/集的双源混合绑定请求。
class HybridMatchRequest {
  /// 创建双源混合绑定请求。
  const HybridMatchRequest({
    required this.bangumiSubject,
    required this.tmdbDetail,
    required this.tmdbSeasonNumber,
    required this.startEpisodeNumber,
    this.customSlotsByVariantId,
  });

  /// 选定的 `Bangumi` 独立条目。
  final BangumiSubjectCandidate bangumiSubject;

  /// 选定的 `TMDB` 母系列作品详情。
  final TmdbWorkDetail tmdbDetail;

  /// 目标 `TMDB` 季号（例如特别篇为 `0`）。
  final int tmdbSeasonNumber;

  /// 起始映射 `TMDB` 集号。
  final int startEpisodeNumber;

  /// 可选按物理版本主键显式覆盖的目标季号与集号。
  final Map<String, ({int season, int episode})>? customSlotsByVariantId;
}

/// 合并或迁移操作的可观测执行结果。
class WorkMergeOutcome {
  /// 创建合并结果实体。
  const WorkMergeOutcome({
    required this.targetWork,
    required this.movedVariantCount,
    required this.sourceWorkDeleted,
    this.sourceWorkId,
  });

  /// 合并后的目标作品实体。
  final Work targetWork;

  /// 成功迁移的物理媒体文件数量。
  final int movedVariantCount;

  /// 原作品是否因空壳已被自动清理移除。
  final bool sourceWorkDeleted;

  /// 原作品主键。
  final String? sourceWorkId;
}

/// 并入已有作品时的视频分类归属模式。
enum MergeVideoCategoryMode {
  /// 保持原文件所属分类。
  preserve,

  /// 全部作为「特典 / 附加映像」归入目标作品。
  asExtra,

  /// 全部作为「正片剧集」顺延或对应集号并入目标作品。
  asMain,
}

/// 手动编辑「文件映射修正」单行可变状态模型。
class EditableFileMappingRow {
  /// 创建单行文件映射编辑状态。
  EditableFileMappingRow({
    required this.variant,
    required this.category,
    required this.seasonNumber,
    required this.episodeNumber,
    required this.extraType,
    this.recognizedExtraLabel = '',
    this.isTmdbSpecial = false,
  }) : initialCategory = category,
       initialSeasonNumber = seasonNumber,
       initialEpisodeNumber = episodeNumber,
       initialExtraType = extraType,
       initialIsTmdbSpecial = isTmdbSpecial;

  /// 物理视频变体。
  final MediaVariant variant;

  /// 初始剧集分类。
  final EpisodeCategory initialCategory;

  /// 初始季号。
  final int initialSeasonNumber;

  /// 初始集号（未编号普通特典可为 `0`）。
  final int initialEpisodeNumber;

  /// 初始特典子类。
  final ExtraKind initialExtraType;

  /// 初始是否已对齐至 `TMDB Season 0` 特别篇。
  final bool initialIsTmdbSpecial;

  /// 自动识别出的特典可读标签。
  final String recognizedExtraLabel;

  /// 当前分类。
  EpisodeCategory category;

  /// 当前季号。
  int seasonNumber;

  /// 当前集号。
  int episodeNumber;

  /// 当前特典子类。
  ExtraKind extraType;

  /// 当前是否显式对齐为 `TMDB` 特别篇。
  bool isTmdbSpecial;

  /// 面向非特别篇特典的简洁识别展示文案。
  String get displayRecognizedExtra {
    final trimmed = recognizedExtraLabel.trim();
    if (trimmed.isNotEmpty) return trimmed;
    final kindUpper = extraType.name.toUpperCase();
    if (episodeNumber > 0) {
      return '$kindUpper${episodeNumber.toString().padLeft(2, '0')}';
    }
    return kindUpper;
  }

  /// 相对于初始状态是否发生变更。
  bool get isModified =>
      category != initialCategory ||
      seasonNumber != initialSeasonNumber ||
      episodeNumber != initialEpisodeNumber ||
      extraType != initialExtraType ||
      isTmdbSpecial != initialIsTmdbSpecial;
}
