import 'package:engine_playback/engine_playback.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';

/// 播放记录媒体类型筛选标签。
enum HistoryMediaFilter {
  /// 展示全部媒体类型的观看与收听记录。
  all('全部'),

  /// 仅展示视频正片与特典播放记录。
  video('视频'),

  /// 仅展示 CD 与音频播放记录。
  audio('音频');

  const HistoryMediaFilter(this.label);

  /// 中文筛选胶囊标签文案。
  final String label;
}

/// 单条已关联作品/剧集元数据的播放记录视图。
final class HistoryEntryView {
  /// 创建单条播放记录展示视图。
  const HistoryEntryView({
    required this.record,
    required this.work,
    required this.episode,
    required this.variant,
    required this.isAudio,
    required this.workTitle,
    required this.workOriginalTitle,
    required this.episodeSubtitle,
    required this.playedTimeLabel,
    required this.progressLabel,
    required this.progressRatio,
  });

  /// 底层持久化播放记录实体。
  final PlaybackRecordEntity record;

  /// 关联作品记录（作品已删除时可能为空）。
  final WorkRecord? work;

  /// 关联逻辑剧集记录（可能为空）。
  final EpisodeRecord? episode;

  /// 关联物理媒体版本（可能为空）。
  final MediaVariantRecord? variant;

  /// 是否属于音频/CD 记录。
  final bool isAudio;

  /// 作品展示主标题。
  final String workTitle;

  /// 作品原始标题（用于补充搜索匹配与副标题提示）。
  final String? workOriginalTitle;

  /// 单集或音轨副标题（由 [EpisodeTitleFormatter] 统一生成）。
  final String episodeSubtitle;

  /// 24 小时制播放时间文案（`HH:mm`）。
  final String playedTimeLabel;

  /// 进度文字摘要（如 `已看完`、`看到 12:34 / 24:00`）。
  final String progressLabel;

  /// 进度比例（0.0 ~ 1.0）。
  final double progressRatio;

  /// 关联剧集的横版剧照相对路径或地址（视频分组展开卡使用）。
  String? get stillPath => episode?.stillPath;

  /// 音频或光盘记录所属的专辑子目录标签（用于展开抽屉副标题区分光盘）。
  String? get audioSubdirLabel {
    if (!isAudio) return null;
    final raw = variant?.relativePath.replaceAll('\\', '/').trim() ?? '';
    if (raw.isEmpty) return null;
    final lastSlash = raw.lastIndexOf('/');
    if (lastSlash <= 0) return null;
    final dirPath = raw.substring(0, lastSlash).trim();
    final parts = dirPath
        .split('/')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList(growable: false);
    if (parts.length <= 1) return null;
    return parts.last;
  }

  /// 是否已完成当前集或音轨播放。
  bool get isCompleted => record.isCompleted;
}

/// 同一自然日内按作品聚合展示的时间轴卡片组。
final class HistoryWorkGroupEntry {
  /// 创建单日作品聚合展示组。
  const HistoryWorkGroupEntry({
    required this.groupKey,
    required this.dateKey,
    required this.workId,
    required this.work,
    required this.workTitle,
    required this.workOriginalTitle,
    required this.posterRef,
    required this.mainEpisodeCount,
    required this.items,
  });

  /// 唯一分组键（`${dateKey}::${workId.value}`）。
  final String groupKey;

  /// 所属自然日键（`YYYY-MM-DD`）。
  final String dateKey;

  /// 作品唯一主键。
  final WorkId workId;

  /// 作品元数据记录。
  final WorkRecord? work;

  /// 作品主标题。
  final String workTitle;

  /// 作品原名。
  final String? workOriginalTitle;

  /// 作品海报引用。
  final ArtworkRef? posterRef;

  /// 作品正片总集数。
  final int mainEpisodeCount;

  /// 当天该作品下按时间倒序排列的全部播放记录。
  final List<HistoryEntryView> items;

  /// 最近一次播放记录。
  HistoryEntryView get latestItem => items.first;

  /// 分组内总记录条数。
  int get entryCount => items.length;

  /// 该组主展示记录是否为音频记录。
  bool get isAudioGroup => latestItem.isAudio;

  /// 收起态顶部次行摘要（如 `第 12 集 - 17:52 · 共 3 集`）。
  String get collapsedSummary => PlaybackHistoryTimelineBuilder.formatCollapsedSummary(
    latestRecord: latestItem.record,
    entryCount: entryCount,
    isAudio: isAudioGroup,
    work: work,
    workTitle: workTitle,
    mainEpisodeCount: mainEpisodeCount > 0 ? mainEpisodeCount : null,
  );
}

/// 播放记录时间轴的单日分区模型（支持今天 / 昨天 / 具体日期标题）。
final class HistoryDayGroup {
  /// 创建自然日分组。
  const HistoryDayGroup({
    required this.dateKey,
    required this.dayDate,
    required this.dayTitle,
    required this.dateSubLabel,
    required this.works,
  });

  /// 自然日键（`YYYY-MM-DD`）。
  final String dateKey;

  /// 本地自然日零点日期。
  final DateTime dayDate;

  /// 自然日主标题（`今天`、`昨天` 或 `YYYY.MM.DD`）。
  final String dayTitle;

  /// 当 [dayTitle] 为相对日期时附加的具体日期（`YYYY.MM.DD`），否则为空。
  final String? dateSubLabel;

  /// 当天聚合后的作品分组列表。
  final List<HistoryWorkGroupEntry> works;
}

/// 日记式播放记录分组、过滤与文案装配纯领域辅助器。
abstract final class HistoryTimelineGrouper {
  /// 判断某条记录是否属于音频/CD 记录。
  static bool resolveIsAudio(
    PlaybackRecordEntity record,
    MediaVariantRecord? variant,
  ) {
    if (record.isAudioRecord) {
      return true;
    }
    return variant?.assetKind == AssetKind.cdAlbum;
  }

  /// 将记录按媒体筛选与关键字过滤，并聚合为「今天 / 昨天 / 具体日期 -> 作品」结构。
  static List<HistoryDayGroup> buildGroups({
    required List<PlaybackRecordEntity> records,
    required Map<WorkId, WorkRecord> worksById,
    required Map<EpisodeId, EpisodeRecord> episodesById,
    required Map<VariantId, MediaVariantRecord> variantsById,
    required Map<WorkId, int> mainEpisodeCounts,
    HistoryMediaFilter filter = HistoryMediaFilter.all,
    String query = '',
    DateTime? now,
  }) {
    final normalizedQuery = query.trim().toLowerCase();
    final filtered = <PlaybackRecordEntity>[];

    for (final rec in records) {
      if (rec.isDeleted) {
        continue;
      }
      final work = worksById[rec.workId];
      final episode = episodesById[rec.episodeId];
      final variant = variantsById[rec.variantId];
      final isAudio = resolveIsAudio(rec, variant);

      if (filter == HistoryMediaFilter.video && isAudio) {
        continue;
      }
      if (filter == HistoryMediaFilter.audio && !isAudio) {
        continue;
      }

      if (normalizedQuery.isNotEmpty) {
        final searchable = <String>[
          work?.title ?? '',
          work?.originalTitle ?? '',
          rec.episodeTitle,
          episode?.title ?? '',
          variant?.fileName ?? '',
          if (rec.episodeNumber != null) '第${rec.episodeNumber}集',
          if (rec.episodeNumber != null) '${rec.episodeNumber}',
        ].join(' ').toLowerCase();
        if (!searchable.contains(normalizedQuery)) {
          continue;
        }
      }

      filtered.add(rec);
    }

    final timelineSections = PlaybackHistoryTimelineBuilder.build(filtered);
    final localNow = (now ?? DateTime.now()).toLocal();
    final todayDay = DateTime(localNow.year, localNow.month, localNow.day);
    final yesterdayDay = todayDay.subtract(const Duration(days: 1));

    return timelineSections
        .map((section) {
          final isToday = _sameDay(section.dayDate, todayDay);
          final isYesterday = _sameDay(section.dayDate, yesterdayDay);
          final dayTitle = isToday
              ? '今天'
              : (isYesterday ? '昨天' : section.dateLabel);
          final dateSubLabel = (isToday || isYesterday)
              ? section.dateLabel
              : null;

          final workGroups = section.works
              .map((group) {
                final work = worksById[group.workId];
                final mainEpCount = mainEpisodeCounts[group.workId] ?? 0;
                final fallbackTitle = _fallbackTitle(
                  work: work,
                  records: group.records,
                  variantsById: variantsById,
                );

                final itemViews = group.records
                    .map((rec) {
                      final ep = episodesById[rec.episodeId];
                      final variant = variantsById[rec.variantId];
                      final isAudio = resolveIsAudio(rec, variant);
                      final subtitle = EpisodeTitleFormatter.formatHistorySubtitle(
                        record: rec,
                        work: work,
                        workTitle: fallbackTitle,
                        mainEpisodeCount: mainEpCount > 0 ? mainEpCount : null,
                      );
                      return HistoryEntryView(
                        record: rec,
                        work: work,
                        episode: ep,
                        variant: variant,
                        isAudio: isAudio,
                        workTitle: fallbackTitle,
                        workOriginalTitle: work?.originalTitle,
                        episodeSubtitle: subtitle,
                        playedTimeLabel:
                            PlaybackHistoryTimelineBuilder.formatClockHm(
                              rec.playedAt,
                            ),
                        progressLabel: formatProgressLabel(
                          rec,
                          isAudio: isAudio,
                        ),
                        progressRatio: rec.progressRatio,
                      );
                    })
                    .toList(growable: false);

                return HistoryWorkGroupEntry(
                  groupKey: group.groupKey,
                  dateKey: group.dateKey,
                  workId: group.workId,
                  work: work,
                  workTitle: fallbackTitle,
                  workOriginalTitle: work?.originalTitle,
                  posterRef: work?.posterRef,
                  mainEpisodeCount: mainEpCount,
                  items: itemViews,
                );
              })
              .toList(growable: false);

          return HistoryDayGroup(
            dateKey: section.dateKey,
            dayDate: section.dayDate,
            dayTitle: dayTitle,
            dateSubLabel: dateSubLabel,
            works: workGroups,
          );
        })
        .toList(growable: false);
  }

  /// 格式化单条记录的观看/收听进度文本。
  static String formatProgressLabel(
    PlaybackRecordEntity record, {
    required bool isAudio,
  }) {
    if (record.isCompleted) {
      return isAudio ? '已听完' : '已看完';
    }
    if (record.positionSeconds <= 0 && record.durationSeconds <= 0) {
      return isAudio ? '开始收听' : '已起播';
    }
    final posStr = PlaybackRecordHelper.formatClock(record.positionSeconds);
    if (record.durationSeconds > 0) {
      final durStr = PlaybackRecordHelper.formatClock(record.durationSeconds);
      return '${isAudio ? '听到' : '看到'} $posStr / $durStr';
    }
    return '${isAudio ? '听到' : '看到'} $posStr';
  }

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  static String _fallbackTitle({
    required WorkRecord? work,
    required List<PlaybackRecordEntity> records,
    required Map<VariantId, MediaVariantRecord> variantsById,
  }) {
    final workTitle = work?.title.trim();
    if (workTitle != null && workTitle.isNotEmpty) {
      return workTitle;
    }
    final firstVariant = variantsById[records.first.variantId];
    final fileName = firstVariant?.fileName.trim();
    if (fileName != null && fileName.isNotEmpty) {
      return fileName;
    }
    final epTitle = records.first.episodeTitle.trim();
    if (epTitle.isNotEmpty) {
      return epTitle;
    }
    return '未知作品';
  }
}
