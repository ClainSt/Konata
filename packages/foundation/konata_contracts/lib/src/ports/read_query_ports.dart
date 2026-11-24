import '../value_objects/artwork_ref.dart';
import '../value_objects/domain_enums.dart';
import '../value_objects/ids.dart';

/// 作品只读摘要视图（供跨 Feature 只读查询，严禁暴露可变持久化行对象）。
final class WorkSummaryView {
  /// 创建作品只读摘要。
  const WorkSummaryView({
    required this.id,
    required this.title,
    required this.scrapeStatus,
    this.canonicalKey,
    this.originalTitle,
    this.year,
    this.tmdbId,
    this.bangumiId,
    this.posterRef,
    this.backdropRef,
    this.logoRef,
    this.seriesGroupId,
    this.isHidden = false,
  });

  /// 作品唯一主键。
  final WorkId id;

  /// 展示标题。
  final String title;

  /// 当前刮削匹配状态。
  final ScrapeStatus scrapeStatus;

  /// 跨设备稳定规范键。
  final String? canonicalKey;

  /// 原始语言标题。
  final String? originalTitle;

  /// 发行或首播年份。
  final int? year;

  /// 绑定的 TMDB 条目编号。
  final int? tmdbId;

  /// 绑定的 Bangumi 条目编号。
  final int? bangumiId;

  /// 封面海报引用。
  final ArtworkRef? posterRef;

  /// 无字横版背景引用。
  final ArtworkRef? backdropRef;

  /// 透明标题徽标引用。
  final ArtworkRef? logoRef;

  /// 所属系列编组标识。
  final SeriesGroupId? seriesGroupId;

  /// 是否在主媒体库中隐藏。
  final bool isHidden;
}

/// 逻辑剧集只读摘要视图。
final class EpisodeSummaryView {
  /// 创建逻辑剧集只读摘要。
  const EpisodeSummaryView({
    required this.id,
    required this.workId,
    required this.seasonNumber,
    required this.category,
    this.episodeNumber,
    this.episodeNumberEnd,
    this.extraType,
    this.title,
  });

  /// 逻辑剧集主键。
  final EpisodeId id;

  /// 所属作品主键。
  final WorkId workId;

  /// 所属季号。
  final int seasonNumber;

  /// 正片或特典分类。
  final EpisodeCategory category;

  /// 单集集号或区间起始集号。
  final int? episodeNumber;

  /// 多集合并区间结束集号。
  final int? episodeNumberEnd;

  /// 特典细分类型。
  final ExtraKind? extraType;

  /// 单集展示标题。
  final String? title;
}

/// 媒体源只读摘要视图（严禁携带密码等敏感凭据）。
final class MediaSourceView {
  /// 创建媒体源只读摘要。
  const MediaSourceView({
    required this.id,
    required this.kind,
    required this.label,
    required this.location,
    this.username,
  });

  /// 媒体源主键。
  final SourceId id;

  /// 协议类型。
  final MediaSourceKind kind;

  /// 显示名称。
  final String label;

  /// 根目录路径或远程服务地址。
  final String location;

  /// 可选用户名（不含密码）。
  final String? username;
}

/// 续播进度只读摘要视图。
final class PlaybackResumeView {
  /// 创建续播进度只读摘要。
  const PlaybackResumeView({
    required this.workId,
    required this.episodeId,
    required this.variantId,
    required this.positionSeconds,
    required this.durationSeconds,
    required this.completed,
    required this.playedAtMs,
  });

  /// 所属作品主键。
  final WorkId workId;

  /// 逻辑剧集主键。
  final EpisodeId episodeId;

  /// 物理版本主键。
  final VariantId variantId;

  /// 上次观看位置（秒）。
  final int positionSeconds;

  /// 媒体总时长（秒）。
  final int durationSeconds;

  /// 是否已达完播状态。
  final bool completed;

  /// 最近播放的 UTC 毫秒时间戳。
  final int playedAtMs;
}

/// 媒体库跨包极薄只读查询端口。
abstract interface class LibraryReadPort {
  /// 按作品主键查询只读摘要，不存在或已软删除时返回 `null`。
  Future<WorkSummaryView?> findWorkSummary(WorkId workId);

  /// 列出未隐藏且未删除的全部作品只读摘要。
  Future<List<WorkSummaryView>> listVisibleWorks();

  /// 查询指定作品下的全部有效逻辑剧集摘要。
  Future<List<EpisodeSummaryView>> listEpisodesForWork(WorkId workId);

  /// 按主键查询媒体源只读摘要。
  Future<MediaSourceView?> findMediaSource(SourceId sourceId);

  /// 列出全部有效媒体源只读摘要。
  Future<List<MediaSourceView>> listMediaSources();
}

/// 播放记录跨包极薄只读查询端口。
abstract interface class PlaybackReadPort {
  /// 查询指定作品最近一次有效播放进度。
  Future<PlaybackResumeView?> findLatestForWork(WorkId workId);

  /// 查询指定逻辑剧集最近一次有效播放进度。
  Future<PlaybackResumeView?> findLatestForEpisode(EpisodeId episodeId);
}

/// 配置切片跨包极薄只读查询端口。
abstract interface class PrefsReadPort {
  /// 读取指定命名空间的原始配置 JSON 载荷；未写入时返回 `null`。
  Future<Map<String, Object?>?> readRawSlice(String namespace);
}
