import 'package:engine_playback/engine_playback.dart';
import 'package:engine_scraping/engine_scraping.dart';
import 'package:konata_contracts/konata_contracts.dart';

import '../data/detail_edit_models.dart';

/// 作品详情页聚合数据包（零 Riverpod，供详情控制器与 UI 组件消费）。
class WorkDetailBundle {
  /// 创建作品详情聚合包。
  const WorkDetailBundle({
    required this.work,
    required this.episodes,
    required this.variants,
    required this.sourcesById,
    required this.latestPlayback,
    this.playbackByEpisodeId = const <String, PlaybackRecord>{},
    this.seriesGroup,
    this.seriesMembers = const <Work>[],
    this.cdVariants = const <MediaVariant>[],
    this.editableSupplementaryItems = const <SupplementaryEditableItem>[],
    this.variantsByEpisodeId = const <String, List<MediaVariant>>{},
    this.scrapeCandidates = const <ScrapeCandidateSummary>[],
    this.folderPath,
    this.visibleTabs = const <DetailTabContribution>[],
    this.primaryBarActions = const <DetailActionContribution>[],
    this.gearMenuActions = const <DetailActionContribution>[],
    this.resumePlan,
  });

  /// 当前作品领域实体。
  final Work work;

  /// 作品全部逻辑剧集（正片 + 特典 + 同系列共享特典）。
  final List<Episode> episodes;

  /// 作品关联全部物理文件变体。
  final List<MediaVariant> variants;

  /// 媒体源字典（按 `sourceId` 索引）。
  final Map<String, MediaSource> sourcesById;

  /// 最近一次播放记录。
  final PlaybackRecord? latestPlayback;

  /// 按 `episodeId` 索引的播放记录表。
  final Map<String, PlaybackRecord> playbackByEpisodeId;

  /// 所属系列编组。
  final SeriesGroup? seriesGroup;

  /// 同系列成员列表（按时间线与季号排序）。
  final List<Work> seriesMembers;

  /// 可见音乐 CD 音轨物理变体（自身 + 系列共用）。
  final List<MediaVariant> cdVariants;

  /// 可在手动编辑面板调整作用域的附属条目清单。
  final List<SupplementaryEditableItem> editableSupplementaryItems;

  /// 按 `episodeId` 预聚合的物理变体查找表。
  final Map<String, List<MediaVariant>> variantsByEpisodeId;

  /// 待人工复核候选摘要列表。
  final List<ScrapeCandidateSummary> scrapeCandidates;

  /// 首个文件所在相对目录路径。
  final String? folderPath;

  /// 经平台与 `isVisibleForWork` 动态过滤后的外部扩展标签页列表（如扫图画廊）。
  final List<DetailTabContribution> visibleTabs;

  /// 经平台与 `isEnabledForWork` 动态过滤后的主操作区动作列表。
  final List<DetailActionContribution> primaryBarActions;

  /// 经平台与 `isEnabledForWork` 动态过滤后的齿轮菜单扩展动作列表。
  final List<DetailActionContribution> gearMenuActions;

  /// 主播放按钮续播推演结果。
  final PlaybackResumePlan? resumePlan;

  /// 正片逻辑剧集（已排序）。
  List<Episode> get mainEpisodes => [
    for (final ep in episodes)
      if (ep.category == EpisodeCategory.main) ep,
  ];

  /// 特典/附加映像逻辑条目（已排序）。
  List<Episode> get extraEpisodes => [
    for (final ep in episodes)
      if (ep.category == EpisodeCategory.extra) ep,
  ];

  /// 可见扫图数量，按与画廊一致的路径与共享范围去重。
  int get visibleScanCount => {
    for (final item in editableSupplementaryItems)
      if (item.variant.assetKind == AssetKind.scanGallery &&
          (item.variant.workId == work.id ||
              item.variant.assetScope == SupplementaryAssetScope.seriesShared))
        '${item.variant.sourceId}::${item.variant.relativePath.toLowerCase()}',
  }.length;

  /// 取得指定逻辑分集的物理文件变体列表。
  List<MediaVariant> variantsForEpisode(String episodeId) =>
      variantsByEpisodeId[episodeId] ?? const <MediaVariant>[];

  /// 详情页实际展示的 `16:9` 横版背景来源（自身优先，缺失时借用同系列母剧横图）。
  ({String path, String ownerWorkId, bool isShared})?
  get effectiveHeroBackdrop =>
      SeriesSeasonFormatter.resolveEffectiveHeroBackdrop(
        work: work,
        seriesMembers: seriesMembers,
      );

  /// 详情页实际展示的 `16:9` 横版背景路径。
  String? get effectiveHeroBackdropPath => effectiveHeroBackdrop?.path;

  /// 详情页实际横版背景的缓存归属作品主键。
  String get effectiveHeroBackdropOwnerId =>
      effectiveHeroBackdrop?.ownerWorkId ?? work.id;
}

/// 正片多季筛选分组描述。
class DetailMainSeasonGroup {
  /// 创建正片季号分组。
  const DetailMainSeasonGroup({
    required this.seasonNumber,
    required this.label,
    required this.episodes,
  });

  /// 季号。
  final int seasonNumber;

  /// 中文展示标签（如 `第 1 季`、`正片`）。
  final String label;

  /// 该季包含的正片剧集列表。
  final List<Episode> episodes;
}

/// 详情页抽屉筛选标签与目录聚合 helper。
abstract final class DetailSupplementaryHelper {
  /// 将正片剧集按季号聚合为有序分季列表。
  static List<DetailMainSeasonGroup> groupMainBySeason(List<Episode> mains) {
    final bySeason = <int, List<Episode>>{};
    for (final ep in mains) {
      bySeason.putIfAbsent(ep.seasonNumber, () => <Episode>[]).add(ep);
    }
    final keys = bySeason.keys.toList()..sort();
    return [
      for (final season in keys)
        DetailMainSeasonGroup(
          seasonNumber: season,
          label: season <= 0 ? '正片' : '第 $season 季',
          episodes: bySeason[season]!,
        ),
    ];
  }

  /// 将特典细分类型映射为简洁中文标签。
  static String extraKindLabel(ExtraKind kind) =>
      SupplementarySubclassifier.extraKindLabel(kind);

  /// 按黄金源文件名、目录语义和原始类型分类特典。
  static ExtraKind resolvedExtraKind(WorkDetailBundle bundle, Episode episode) {
    final v = bundle.variantsForEpisode(episode.id).firstOrNull;
    return v == null
        ? episode.extraType ?? ExtraKind.sp
        : SupplementarySubclassifier.classifyExtraVideo(
            fileName: v.fileName,
            relativePath: v.relativePath,
            fallbackExtraType: episode.extraType,
          );
  }

  /// 将 `engine_scraping` 领域 `Episode` 投影为跨包只读 `EpisodeSummaryView`。
  static EpisodeSummaryView toEpisodeSummaryView(Episode ep) {
    return EpisodeSummaryView(
      id: EpisodeId.trusted(ep.id),
      workId: WorkId.trusted(ep.workId),
      seasonNumber: ep.seasonNumber,
      category: ep.category,
      episodeNumber: ep.episodeNumber,
      episodeNumberEnd: ep.episodeNumberEnd,
      extraType: ep.extraType,
      title: ep.title,
    );
  }

  /// 将 `PlaybackRecord` 投影为 `PlaybackResumeView`。
  static PlaybackResumeView toPlaybackResumeView(PlaybackRecord r) {
    return PlaybackResumeView(
      workId: WorkId.trusted(r.workId),
      episodeId: EpisodeId.trusted(r.episodeId),
      variantId: VariantId.trusted(r.variantId),
      positionSeconds: r.positionSeconds,
      durationSeconds: r.durationSeconds,
      completed: r.isCompleted,
      playedAtMs: r.playedAt.millisecondsSinceEpoch,
    );
  }
}
