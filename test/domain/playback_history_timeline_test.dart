import 'package:flutter_test/flutter_test.dart';
import 'package:konata/domain/models/media_source.dart';
import 'package:konata/domain/models/playback_record.dart';
import 'package:konata/domain/models/work.dart';
import 'package:konata/domain/playback/playback_history_timeline.dart';

void main() {
  group('PlaybackHistoryTimelineBuilder 日记时间轴聚合', () {
    PlaybackRecord makeRecord({
      required String id,
      required String workId,
      required DateTime playedAt,
      int seasonNumber = 1,
      int? episodeNumber = 1,
      String episodeTitle = '第 1 话',
      String episodeId = 'ep_1',
    }) {
      return PlaybackRecord(
        id: id,
        workId: workId,
        episodeId: episodeId,
        variantId: 'var_$id',
        seasonNumber: seasonNumber,
        episodeNumber: episodeNumber,
        episodeTitle: episodeTitle,
        sourceType: MediaSourceKind.local,
        playedAt: playedAt,
        positionSeconds: 300,
        durationSeconds: 1440,
      );
    }

    test('按系统本地自然日 YYYY.MM.DD 分组，并在当天内按作品聚合（日记风格）', () {
      final records = <PlaybackRecord>[
        makeRecord(
          id: 'r1',
          workId: 'w1',
          episodeNumber: 1,
          playedAt: DateTime(2026, 7, 8, 21, 10),
        ),
        makeRecord(
          id: 'r2',
          workId: 'w1',
          episodeNumber: 2,
          playedAt: DateTime(2026, 7, 8, 21, 45),
        ),
        makeRecord(
          id: 'r3',
          workId: 'w1',
          episodeNumber: 3,
          playedAt: DateTime(2026, 7, 10, 2, 37),
        ),
        makeRecord(
          id: 'r4',
          workId: 'w2',
          episodeNumber: 12,
          playedAt: DateTime(2026, 7, 10, 17, 52),
        ),
      ];

      final sections = PlaybackHistoryTimelineBuilder.build(records);
      expect(sections, hasLength(2));

      // 最近一天在前，且日期固定为 YYYY.MM.DD
      expect(sections[0].dateLabel, equals('2026.07.10'));
      expect(sections[0].works.map((w) => w.workId), equals(['w2', 'w1']));
      expect(sections[0].works[0].entryCount, equals(1));
      expect(sections[0].works[1].entryCount, equals(1));
      expect(sections[0].works[1].latestRecord.id, equals('r3'));

      // 另一天同作品独立聚合，包含当天看过的 2 集且按时间倒序
      expect(sections[1].dateLabel, equals('2026.07.08'));
      expect(sections[1].works, hasLength(1));
      expect(sections[1].works[0].workId, equals('w1'));
      expect(
        sections[1].works[0].records.map((r) => r.id),
        equals(['r2', 'r1']),
      );
    });

    test('UTC 时间戳自动转换为系统本地时区与 24 小时制 HH:mm', () {
      final utcTime = DateTime.utc(2026, 10, 23, 9, 5);
      final expectedLocal = utcTime.toLocal();
      final rec = makeRecord(id: 'r_utc', workId: 'w1', playedAt: utcTime);

      final sections = PlaybackHistoryTimelineBuilder.build([rec]);
      expect(sections, hasLength(1));
      expect(
        sections.first.dateLabel,
        equals(PlaybackHistoryTimelineBuilder.formatDayHeaderLabel(expectedLocal)),
      );
      expect(
        PlaybackHistoryTimelineBuilder.formatClockHm(utcTime),
        equals(
          '${expectedLocal.hour.toString().padLeft(2, '0')}:'
          '${expectedLocal.minute.toString().padLeft(2, '0')}',
        ),
      );
    });

    test('收起态副标题准确呈现集号/曲名、24 小时制时间与多集计数', () {
      const tvWork = Work(
        id: 'w_tv',
        title: '吹响吧！上低音号',
        tmdbMediaType: TmdbMediaType.tv,
        scrapeStatus: ScrapeStatus.matched,
      );
      const movieWork = Work(
        id: 'w_mv',
        title: '利兹与青鸟',
        tmdbMediaType: TmdbMediaType.movie,
        scrapeStatus: ScrapeStatus.matched,
      );

      final tvRec = makeRecord(
        id: 'r_tv',
        workId: 'w_tv',
        episodeNumber: 12,
        episodeTitle: '最后的独奏',
        playedAt: DateTime(2026, 10, 23, 17, 52),
      );
      expect(
        PlaybackHistoryTimelineBuilder.formatCollapsedSummary(
          latestRecord: tvRec,
          entryCount: 1,
          isAudio: false,
          work: tvWork,
        ),
        equals('第 12 集 - 17:52'),
      );
      expect(
        PlaybackHistoryTimelineBuilder.formatCollapsedSummary(
          latestRecord: tvRec,
          entryCount: 3,
          isAudio: false,
          work: tvWork,
        ),
        equals('第 12 集 - 17:52 · 共 3 集'),
      );

      final movieRec = makeRecord(
        id: 'r_mv',
        workId: 'w_mv',
        episodeNumber: 1,
        episodeTitle: '利兹与青鸟',
        playedAt: DateTime(2026, 10, 23, 8, 5),
      );
      expect(
        PlaybackHistoryTimelineBuilder.formatCollapsedSummary(
          latestRecord: movieRec,
          entryCount: 1,
          isAudio: false,
          work: movieWork,
        ),
        equals('正片 - 08:05'),
      );

      final audioRec = makeRecord(
        id: 'r_cd',
        workId: 'w_tv',
        episodeId: 'cd::var_1::track_02',
        episodeNumber: 2,
        episodeTitle: '02. 響け！ユーフォニアム.flac',
        playedAt: DateTime(2026, 10, 23, 23, 9),
      );
      expect(
        PlaybackHistoryTimelineBuilder.formatCollapsedSummary(
          latestRecord: audioRec,
          entryCount: 4,
          isAudio: true,
          work: tvWork,
        ),
        equals('響け！ユーフォニアム - 23:09 · 共 4 首'),
      );
    });
  });
}
