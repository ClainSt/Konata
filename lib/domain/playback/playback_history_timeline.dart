import '../matching/episode_title_formatter.dart';
import '../models/playback_record.dart';
import '../models/work.dart';

/// 播放记录时间轴的单日分组（日记模式）。
class PlaybackHistoryDaySection {
  /// 创建单日分组。
  const PlaybackHistoryDaySection({
    required this.dateKey,
    required this.dayDate,
    required this.dateLabel,
    required this.works,
  });

  /// 本地自然日键值（格式 `YYYY-MM-DD`）。
  final String dateKey;

  /// 本地自然日零点时间戳。
  final DateTime dayDate;

  /// 展示日期文案（固定 `YYYY.MM.DD` 格式，例如 `2026.10.23`）。
  final String dateLabel;

  /// 当天按最近观看时间倒序排列的作品聚合列表。
  final List<PlaybackHistoryWorkGroup> works;
}

/// 同一自然日内按作品聚合的一组播放记录。
class PlaybackHistoryWorkGroup {
  /// 创建单日作品聚合分组。
  const PlaybackHistoryWorkGroup({
    required this.groupKey,
    required this.dateKey,
    required this.workId,
    required this.records,
  });

  /// 唯一分组键（`${dateKey}::${workId}`），用于展开状态与组件标识。
  final String groupKey;

  /// 所属自然日键值（`YYYY-MM-DD`）。
  final String dateKey;

  /// 作品唯一主键。
  final String workId;

  /// 当天该作品全部播放记录（按播放时间降序排列，非空）。
  final List<PlaybackRecord> records;

  /// 当天该作品最近一次播放的记录。
  PlaybackRecord get latestRecord => records.first;

  /// 当天该作品记录总条数。
  int get entryCount => records.length;
}

/// 播放记录时间轴分组与摘要纯领域构造器。
abstract final class PlaybackHistoryTimelineBuilder {
  /// 将平铺播放记录按「本地自然日 → 作品」二级结构聚合成日记式时间轴。
  static List<PlaybackHistoryDaySection> build(List<PlaybackRecord> records) {
    if (records.isEmpty) {
      return const <PlaybackHistoryDaySection>[];
    }

    final sorted = List<PlaybackRecord>.of(records)
      ..sort((a, b) {
        final byTime = b.playedAt.compareTo(a.playedAt);
        if (byTime != 0) return byTime;
        final epA = a.episodeNumber ?? -1;
        final epB = b.episodeNumber ?? -1;
        if (epA != epB) return epB.compareTo(epA);
        return b.id.compareTo(a.id);
      });

    final dayOrder = <String>[];
    final dayDateByKey = <String, DateTime>{};
    final dayWorkOrder = <String, List<String>>{};
    final dayWorkRecords = <String, Map<String, List<PlaybackRecord>>>{};

    for (final rec in sorted) {
      final localTime = rec.playedAt.toLocal();
      final dayDate = DateTime(localTime.year, localTime.month, localTime.day);
      final dateKey = formatDateKey(dayDate);

      if (!dayDateByKey.containsKey(dateKey)) {
        dayOrder.add(dateKey);
        dayDateByKey[dateKey] = dayDate;
        dayWorkOrder[dateKey] = <String>[];
        dayWorkRecords[dateKey] = <String, List<PlaybackRecord>>{};
      }

      final worksMap = dayWorkRecords[dateKey]!;
      final workBucket = worksMap.putIfAbsent(rec.workId, () {
        dayWorkOrder[dateKey]!.add(rec.workId);
        return <PlaybackRecord>[];
      });
      workBucket.add(rec);
    }

    return dayOrder
        .map((dateKey) {
          final dayDate = dayDateByKey[dateKey]!;
          final worksMap = dayWorkRecords[dateKey]!;
          final works = dayWorkOrder[dateKey]!
              .map(
                (workId) => PlaybackHistoryWorkGroup(
                  groupKey: '$dateKey::$workId',
                  dateKey: dateKey,
                  workId: workId,
                  records: List<PlaybackRecord>.unmodifiable(worksMap[workId]!),
                ),
              )
              .toList(growable: false);

          return PlaybackHistoryDaySection(
            dateKey: dateKey,
            dayDate: dayDate,
            dateLabel: formatDayHeaderLabel(dayDate),
            works: List<PlaybackHistoryWorkGroup>.unmodifiable(works),
          );
        })
        .toList(growable: false);
  }

  /// 生成规范自然日键（`YYYY-MM-DD`）。
  static String formatDateKey(DateTime localDay) {
    final y = localDay.year.toString().padLeft(4, '0');
    final m = localDay.month.toString().padLeft(2, '0');
    final d = localDay.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  /// 格式化时间轴日期分组头（统一为 `YYYY.MM.DD`，例如 `2026.07.08`）。
  static String formatDayHeaderLabel(DateTime localDay) {
    final y = localDay.year.toString().padLeft(4, '0');
    final m = localDay.month.toString().padLeft(2, '0');
    final d = localDay.day.toString().padLeft(2, '0');
    return '$y.$m.$d';
  }

  /// 格式化播放时间点（24 小时制 `HH:mm`）。
  static String formatClockHm(DateTime playedAt) {
    final local = playedAt.toLocal();
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }

  /// 格式化收起态作品卡片的第二行摘要（如 `第 12 集 - 17:52`、`第 12 集 - 17:52 · 共 3 集`）。
  static String formatCollapsedSummary({
    required PlaybackRecord latestRecord,
    required int entryCount,
    required bool isAudio,
    Work? work,
    int? mainEpisodeCount,
  }) {
    final timeStr = formatClockHm(latestRecord.playedAt);
    final leadLabel = _formatLatestLeadLabel(
      record: latestRecord,
      isAudio: isAudio,
      work: work,
      mainEpisodeCount: mainEpisodeCount,
    );
    final unit = isAudio ? '首' : '集';
    if (entryCount > 1) {
      return '$leadLabel - $timeStr · 共 $entryCount $unit';
    }
    return '$leadLabel - $timeStr';
  }

  static String _formatLatestLeadLabel({
    required PlaybackRecord record,
    required bool isAudio,
    Work? work,
    int? mainEpisodeCount,
  }) {
    if (isAudio || record.isAudioRecord) {
      return EpisodeTitleFormatter.formatHistorySubtitle(
        record: record,
        work: work,
        mainEpisodeCount: mainEpisodeCount,
      );
    }

    // 特典或 SP 直接展示精简特典名。
    if (record.seasonNumber == 0) {
      return EpisodeTitleFormatter.formatHistorySubtitle(
        record: record,
        work: work,
        mainEpisodeCount: mainEpisodeCount,
      );
    }

    // 单一剧场版/单集作品不强加「第 1 集」。
    final isSingleMain =
        work?.tmdbMediaType == TmdbMediaType.movie ||
        (mainEpisodeCount == 1 && record.episodeNumber == null);
    if (isSingleMain) {
      return '正片';
    }

    final epNum = record.episodeNumber;
    if (epNum != null) {
      return '第 $epNum 集';
    }
    return EpisodeTitleFormatter.formatHistorySubtitle(
      record: record,
      work: work,
      mainEpisodeCount: mainEpisodeCount,
    );
  }
}
