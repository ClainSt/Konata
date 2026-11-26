import 'package:flutter/foundation.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';

/// 触发进入全屏视频播放舞台的强类型导航与首播上下文请求。
@immutable
class VideoLaunchRequest {
  /// 创建视频起播请求描述符。
  const VideoLaunchRequest({
    required this.workId,
    this.episodeId,
    this.variantId,
    this.initialPositionSeconds,
    this.initialPlaying = true,
    this.initialBundle,
  });

  /// 目标作品唯一标识。
  final WorkId workId;

  /// 指定起播逻辑剧集标识；为空时自动匹配最近续播集或第一集正片。
  final EpisodeId? episodeId;

  /// 指定起播物理版本标识；为空时自动匹配关联版本。
  final VariantId? variantId;

  /// 可选外部指定跳转起点（整秒）。
  final int? initialPositionSeconds;

  /// 冷恢复时保存的播放或暂停态，常规起播默认播放。
  final bool initialPlaying;

  /// 可选调用方已缓存的作品视频聚合数据包（加速首帧拉起，省去重复查库）。
  final VideoWorkBundle? initialBundle;

  /// 从剧集列表或外部程序拉起的快速构造工厂。
  factory VideoLaunchRequest.fromPlayback({
    required WorkId workId,
    EpisodeId? episodeId,
    VariantId? variantId,
    int? initialPositionSeconds,
  }) {
    return VideoLaunchRequest(
      workId: workId,
      episodeId: episodeId,
      variantId: variantId,
      initialPositionSeconds: initialPositionSeconds,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is VideoLaunchRequest &&
      other.workId == workId &&
      other.episodeId == episodeId &&
      other.variantId == variantId &&
      other.initialPositionSeconds == initialPositionSeconds &&
      other.initialPlaying == initialPlaying;

  @override
  int get hashCode => Object.hash(
    workId,
    episodeId,
    variantId,
    initialPositionSeconds,
    initialPlaying,
  );
}

/// 视频播放所需的作品、剧集、物理版本、媒体源与续播记录只读聚合包。
@immutable
class VideoWorkBundle {
  /// 创建视频作品聚合包。
  const VideoWorkBundle({
    required this.work,
    required this.episodes,
    required this.variants,
    required this.sourcesById,
    required this.playbackByEpisodeId,
    this.seriesGroup,
    this.seriesMembers = const <WorkRecord>[],
    this.latestPlayback,
  });

  /// 当前作品持久化记录。
  final WorkRecord work;

  /// 已按正片优先与季集序排好序的剧集记录列表。
  final List<EpisodeRecord> episodes;

  /// 当前作品及关联系列下挂载的视频物理版本记录列表。
  final List<MediaVariantRecord> variants;

  /// 全部有效媒体源字典（按媒体源主键索引）。
  final Map<SourceId, MediaSourceRecord> sourcesById;

  /// 当前作品及各关联剧集最近的播放历史映射表（以剧集主键文本值为键）。
  final Map<String, PlaybackRecordEntity> playbackByEpisodeId;

  /// 可选所属系列编组记录。
  final SeriesGroupRecord? seriesGroup;

  /// 同系列按顺序排好序的成员作品清单。
  final List<WorkRecord> seriesMembers;

  /// 当前作品最近一次视频播放记录。
  final PlaybackRecordEntity? latestPlayback;

  /// 全部主线正片剧集（过滤特典）。
  List<EpisodeRecord> get mainEpisodes =>
      List<EpisodeRecord>.unmodifiable(<EpisodeRecord>[
        for (final ep in episodes)
          if (ep.category == EpisodeCategory.main) ep,
      ]);

  /// 全部特典剧集列表。
  List<EpisodeRecord> get extraEpisodes =>
      List<EpisodeRecord>.unmodifiable(<EpisodeRecord>[
        for (final ep in episodes)
          if (ep.category == EpisodeCategory.extra) ep,
      ]);

  /// 查询指定剧集关联的全部可用视频物理版本。
  List<MediaVariantRecord> variantsForEpisode(EpisodeId episodeId) {
    return List<MediaVariantRecord>.unmodifiable(<MediaVariantRecord>[
      for (final variant in variants)
        if (variant.assetKind == AssetKind.video &&
            variant.episodeId == episodeId)
          variant,
    ]);
  }
}

/// 视频分集排序、版本技术摘要与系列成员格式化工具（零跨包耦合）。
abstract final class VideoSeriesHelper {
  /// 按正片优先、季号升序、集号升序整理逻辑剧集列表。
  static List<EpisodeRecord> sortEpisodesMainFirst(
    Iterable<EpisodeRecord> raw,
  ) {
    final sorted = List<EpisodeRecord>.of(raw);
    sorted.sort((a, b) {
      final catCmp = _categoryRank(
        a.category,
      ).compareTo(_categoryRank(b.category));
      if (catCmp != 0) return catCmp;
      final seasonCmp = a.seasonNumber.compareTo(b.seasonNumber);
      if (seasonCmp != 0) return seasonCmp;
      final epA = a.episodeNumber ?? 1 << 20;
      final epB = b.episodeNumber ?? 1 << 20;
      final epCmp = epA.compareTo(epB);
      if (epCmp != 0) return epCmp;
      return a.id.value.compareTo(b.id.value);
    });
    return List<EpisodeRecord>.unmodifiable(sorted);
  }

  static int _categoryRank(EpisodeCategory category) => switch (category) {
    EpisodeCategory.main => 0,
    EpisodeCategory.extra => 1,
  };

  /// 按系列编组顺序、发行年份与标题整理同系列作品成员。
  static List<WorkRecord> sortSeriesMembers(Iterable<WorkRecord> raw) {
    final sorted = List<WorkRecord>.of(raw);
    sorted.sort((a, b) {
      final orderA = a.seriesOrder ?? 1 << 20;
      final orderB = b.seriesOrder ?? 1 << 20;
      final orderCmp = orderA.compareTo(orderB);
      if (orderCmp != 0) return orderCmp;
      final yearA = a.year ?? 1 << 20;
      final yearB = b.year ?? 1 << 20;
      final yearCmp = yearA.compareTo(yearB);
      if (yearCmp != 0) return yearCmp;
      final titleCmp = a.title.compareTo(b.title);
      if (titleCmp != 0) return titleCmp;
      return a.id.value.compareTo(b.id.value);
    });
    return List<WorkRecord>.unmodifiable(sorted);
  }

  /// 生成分季或系列成员在列表中的简明区分标签。
  static String formatMemberLabel(
    WorkRecord work,
    List<WorkRecord> members, {
    SeriesGroupRecord? seriesGroup,
    int fallbackOrder = 1,
  }) {
    final customLabel = work.seriesLabel?.trim() ?? '';
    if (customLabel.isNotEmpty) {
      return customLabel;
    }
    if (work.matchedSeason != null && work.matchedSeason! > 0) {
      return '第 ${work.matchedSeason} 季';
    }
    if (work.title.trim().isNotEmpty && members.length > 1) {
      return work.title.trim();
    }
    if (seriesGroup != null && seriesGroup.title.trim().isNotEmpty) {
      return seriesGroup.title.trim();
    }
    return '第 $fallbackOrder 部';
  }

  /// 生成视频物理版本的简短组名与规格徽标文案。
  static String formatVariantSummary(MediaVariantRecord variant) {
    final parts = <String>[
      if ((variant.releaseGroup ?? '').trim().isNotEmpty)
        variant.releaseGroup!.trim(),
      if ((variant.subtitleGroup ?? '').trim().isNotEmpty &&
          variant.subtitleGroup!.trim() != variant.releaseGroup?.trim())
        variant.subtitleGroup!.trim(),
      if ((variant.resolution ?? '').trim().isNotEmpty)
        variant.resolution!.trim(),
      if ((variant.videoCodec ?? '').trim().isNotEmpty)
        variant.videoCodec!.trim().toUpperCase(),
      if ((variant.bitDepth ?? '').trim().isNotEmpty) variant.bitDepth!.trim(),
    ];
    if (parts.isEmpty) {
      return variant.fileName;
    }
    return parts.join(' · ');
  }
}

/// 基于底层三库门面的视频作品数据聚合加载器（零状态管理依赖）。
abstract final class VideoBundleLoader {
  /// 查询并组装指定作品的完整视频播控数据包。
  static Future<VideoWorkBundle?> load({
    required KonataDatabaseBundle databases,
    required WorkId workId,
  }) async {
    final lib = databases.library;
    final user = databases.userState;

    final work = lib.works.findById(workId);
    if (work == null) return null;

    final episodes = VideoSeriesHelper.sortEpisodesMainFirst(
      lib.episodes.listByWork(workId),
    );
    final variants = lib.mediaVariants.listByWork(workId);
    final sources = lib.mediaSources.listAll();
    final sourcesById = <SourceId, MediaSourceRecord>{
      for (final source in sources) source.id: source,
    };

    final seriesId = work.seriesId;
    final seriesGroup = seriesId == null
        ? null
        : lib.seriesGroups.findById(seriesId);
    final seriesMembers = seriesId == null
        ? const <WorkRecord>[]
        : VideoSeriesHelper.sortSeriesMembers(lib.works.listBySeries(seriesId));

    final playbackByEpisodeId = <String, PlaybackRecordEntity>{};
    for (final ep in episodes) {
      final rec = user.playbackRecords.findLatestByEpisode(ep.id);
      if (rec != null) {
        playbackByEpisodeId[ep.id.value] = rec;
      }
    }
    final latestPlayback = user.playbackRecords.findLatestByWork(workId);

    return VideoWorkBundle(
      work: work,
      episodes: episodes,
      variants: List<MediaVariantRecord>.unmodifiable(<MediaVariantRecord>[
        for (final v in variants)
          if (v.assetKind == AssetKind.video) v,
      ]),
      sourcesById: Map<SourceId, MediaSourceRecord>.unmodifiable(sourcesById),
      playbackByEpisodeId: Map<String, PlaybackRecordEntity>.unmodifiable(
        playbackByEpisodeId,
      ),
      seriesGroup: seriesGroup,
      seriesMembers: seriesMembers,
      latestPlayback: latestPlayback,
    );
  }
}
