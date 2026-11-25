import 'package:engine_scraping/engine_scraping.dart';
import 'package:konata_contracts/konata_contracts.dart'
    show
        EpisodeCategory,
        EpisodeId,
        EpisodeSummaryView,
        EpisodeTitleFormatter,
        WorkId;
import 'package:test/test.dart';

const _mb = 1024 * 1024;

ScannedFileInput _video(String path, {int size = 900 * _mb}) =>
    ScannedFileInput(
      relativePath: path,
      fileName: path.split('/').last,
      fileSize: size,
      assetKind: AssetKind.video,
    );

({int? start, int? end}) _parse(String name, [String dir = '']) {
  final span = CloudMediaFileClassifier.episodeSpanFromNameInDirectory(
    dir,
    name,
  );
  // 单次解析入口的起始集必须与独立集号入口完全一致。
  expect(
    span.start,
    CloudMediaFileClassifier.episodeNumberFromNameInDirectory(dir, name),
  );
  return span;
}

void main() {
  group('多集合并文件：区间结束集解析', () {
    const positives = <String, (int, int)>{
      '[VCB-Studio] Tamayura [01-02][Ma10p_1080p][x265_flac_aac].mkv': (1, 2),
      '[VCB-Studio] Nyanko Days [01-12][Ma10p_1080p][x265_flac_aac].mkv': (
        1,
        12,
      ),
      '[ReinForce] Gensou Mangekyou ~The Memories of Phantasm~ 05-06 (BDRip 1920x1080 x264 FLAC).mkv':
          (5, 6),
      "[IrizaRaws] Chou Kadou Girl Nona's Diary Video - 01-13 (BDRip 1920x1080 x264 FLAC).mkv":
          (1, 13),
      "Chi's Sweet Home - 93-104 [DVDRip 960x720 x264 AC3].mkv": (93, 104),
      'Di.Gi.Charat.NYO.2003.S03E093-E094.720p.DVDRip.x265.AAC-CoolFansSub.mkv':
          (93, 94),
      '[Kagura] Urusei Yatsura - 045&046 [BDRip 1280x960 x264 Hi10P FLAC].mkv':
          (45, 46),
      '[Kagura] Urusei Yatsura - 003&004 [BDRip 1280x960 x264 Hi10P FLAC].mkv':
          (3, 4),
      '[FLsnow_feat.AO][Aikatsu_Planet!-Bloomy_Cafe][13-19][WEBDL].mkv': (
        13,
        19,
      ),
      '[Group] Title 第01-02话 [1080p].mkv': (1, 2),
      '[Group] Title S01E01E02.mkv': (1, 2),
      '[Group] Title S01E05~E06 [1080p].mkv': (5, 6),
      '[Group] Title 07～08 [1080p].mkv': (7, 8),
      '[ANK-Raws] ももくり 01+02 (BDrip 1920x1080 HEVC-YUV420P10 FLAC).mkv': (1, 2),
      '[Group] Title [03+04][1080p].mkv': (3, 4),
    };
    positives.forEach((name, range) {
      test('识别区间：$name', () {
        final r = _parse(name);
        expect(r.start, range.$1);
        expect(r.end, range.$2);
      });
    });

    const negatives = <String, int>{
      '[G] Title 2 - 12 [1080p].mkv': 12,
      '[G] 22／7 - 03 [1080p].mkv': 3,
      '[G] Lupin the Third Part 1 - 13 [1080p].mkv': 13,
      '[G] R-15 - 04 [1080p].mkv': 4,
      '[Moozzi2] Youjo Shachou - 12-A (BD 1920x1080 x264 FLAC).mkv': 12,
      '[Moozzi2] Youjo Shachou - 12-B (BD 1920x1080 x264 FLAC).mkv': 12,
      '2024-12-21 Special Conference - 02.mkv': 2,
      '羅小黒戦記 #08(Web 23-25).mkv': 8,
      '[G] Title - 05 [BDRip 1920x1080 x264 FLAC].mkv': 5,
      '[G] Title [12][1080p][a1b2c3d4].mkv': 12,
    };
    negatives.forEach((name, start) {
      test('不是区间：$name', () {
        final r = _parse(name);
        expect(r.start, start);
        expect(r.end, isNull);
      });
    });

    test('结束集不大于起始集或跨度超过 30 时不成区间', () {
      expect(_parse('[G] Title [05-03][1080p].mkv').end, isNull);
      expect(_parse('[G] Title [05-05][1080p].mkv').end, isNull);
      expect(_parse('[G] Title [01-40][1080p].mkv').end, isNull);
      expect(_parse('[G] Title [01-30][1080p].mkv').end, 30);
    });

    test('特典类文件名即使带区间也不会被分析器当作正片区间', () {
      for (final name in const [
        '[G] Title NCOP EP01-08 [1080p].mkv',
        '[G] Title NCED_EP03-04 [1080p].mkv',
        '[G] Title Web Preview 06-08 [1080p].mkv',
        '[G] Title [Picture_Drama][10-13][1080p].mkv',
        '[G] Title [S2 EP01-12 Digest][1080p].mkv',
      ]) {
        final groups = groupAndSplitFiles(
          sourceId: 's',
          files: [
            for (var i = 1; i <= 3; i++)
              _video('Title/[G] Title - 0$i [1080p].mkv'),
            _video('Title/$name', size: 80 * _mb),
          ],
        );
        final g = groups.single;
        final slot = g.slotAssignmentsByPath['Title/$name']!;
        expect(slot.episodeEnd, isNull, reason: name);
        // Picture_Drama 在现有分类器中仍按带编号正片处理，这里只约束其不得成为区间。
        if (!name.contains('Picture_Drama')) {
          expect(slot.category, EpisodeCategory.extra, reason: name);
          expect(g.mainEpisodeNumbers, [1, 2, 3], reason: name);
        }
      }
    });
  });

  group('多集合并文件：目录分析与槽位', () {
    test('[01-02]、S03E093-E094、045&046 目录槽位带区间且 mainEpisodeNumbers 覆盖整个区间', () {
      final cases = <String, (List<String>, int, int)>{
        'Tamayura': (
          [
            '[VCB-Studio] Tamayura [01-02][Ma10p_1080p][x265_flac_aac].mkv',
            '[VCB-Studio] Tamayura [03][Ma10p_1080p][x265_flac_aac].mkv',
          ],
          1,
          2,
        ),
        'Urusei Yatsura': (
          [
            '[Kagura] Urusei Yatsura - 045&046 [BDRip 1280x960 x264 Hi10P FLAC].mkv',
            '[Kagura] Urusei Yatsura - 047 [BDRip 1280x960 x264 Hi10P FLAC].mkv',
          ],
          45,
          46,
        ),
        'Di Gi Charat Nyo': (
          [
            'Di.Gi.Charat.NYO.2003.S03E093-E094.720p.DVDRip.x265.AAC-CoolFansSub.mkv',
            'Di.Gi.Charat.NYO.2003.S03E095.720p.DVDRip.x265.AAC-CoolFansSub.mkv',
          ],
          93,
          94,
        ),
      };
      cases.forEach((dir, spec) {
        final files = spec.$1;
        final groups = groupAndSplitFiles(
          sourceId: 's',
          files: [for (final f in files) _video('$dir/$f')],
        );
        expect(groups, hasLength(1), reason: dir);
        final g = groups.single;
        final slot = g.slotAssignmentsByPath['$dir/${files.first}']!;
        expect(slot.category, EpisodeCategory.main, reason: dir);
        expect(slot.episodeNumber, spec.$2, reason: dir);
        expect(slot.episodeEnd, spec.$3, reason: dir);
        expect(g.mainEpisodeNumbers, containsAll([spec.$2, spec.$3]));
        final single = g.slotAssignmentsByPath['$dir/${files.last}']!;
        expect(single.episodeEnd, isNull, reason: dir);
      });
    });

    test('同目录另有单独 [01] 文件时区间文件不会被并成同集多版本', () {
      const dir = 'Tamayura';
      const range =
          '$dir/[VCB-Studio] Tamayura [01-02][Ma10p_1080p][x265_flac_aac].mkv';
      const single = '$dir/[Other] Tamayura [01][1080p][x264].mkv';
      const third =
          '$dir/[VCB-Studio] Tamayura [03][Ma10p_1080p][x265_flac_aac].mkv';
      final groups = groupAndSplitFiles(
        sourceId: 's',
        files: [_video(range), _video(single), _video(third)],
      );
      final g = groups.single;
      final inventory = g.inventory!;
      final rangeItems = inventory.main.where((i) => i.episodeEnd != null);
      expect(rangeItems, hasLength(1));
      expect(rangeItems.single.files, [range.substring(dir.length + 1)]);
      expect(rangeItems.single.episode, 1);
      expect(rangeItems.single.episodeEnd, 2);
      final singleItem = inventory.main.singleWhere(
        (i) => i.episode == 1 && i.episodeEnd == null,
      );
      expect(singleItem.files, [single.substring(dir.length + 1)]);
      expect(g.slotAssignmentsByPath[range]!.episodeEnd, 2);
      expect(g.slotAssignmentsByPath[single]!.episodeEnd, isNull);
      expect(g.mainEpisodeNumbers, [1, 2, 3]);
    });
  });

  group('多集合并文件：重映射区间', () {
    EpisodeRemapPlan plan(
      Map<String, ({int seasonNumber, int episodeNumber})> m,
    ) => EpisodeRemapPlan(remappedSlots: m, referencedSeasons: const {1, 2});

    test('无任何映射时原样保留区间', () {
      expect(plan(const {}).resolveEpisodeEnd(1, 3, 4), 4);
    });

    test('两端映射到同一季时保留映射后的区间', () {
      final p = plan({
        '1:27': (seasonNumber: 2, episodeNumber: 1),
        '1:28': (seasonNumber: 2, episodeNumber: 2),
      });
      expect(p.resolveEpisodeEnd(1, 27, 28), 2);
    });

    test('任一端映射失败、跨季或命中特别篇时退化为单集', () {
      expect(
        plan({
          '1:27': (seasonNumber: 2, episodeNumber: 1),
        }).resolveEpisodeEnd(1, 27, 28),
        isNull,
      );
      expect(
        plan({
          '1:25': (seasonNumber: 1, episodeNumber: 25),
          '1:26': (seasonNumber: 2, episodeNumber: 1),
        }).resolveEpisodeEnd(1, 25, 26),
        isNull,
      );
      expect(
        const EpisodeRemapPlan(
          remappedSlots: {},
          referencedSeasons: {1},
          specialSlots: {
            '1:4': InterspersedSpecialMapping(tmdbSpecialEpisodeNumber: 1),
          },
        ).resolveEpisodeEnd(1, 3, 4),
        isNull,
      );
    });
  });

  group('多集合并文件：标题格式化', () {
    const range = EpisodeSummaryView(
      id: EpisodeId.trusted('e'),
      workId: WorkId.trusted('w'),
      seasonNumber: 1,
      category: EpisodeCategory.main,
      episodeNumber: 1,
      episodeNumberEnd: 2,
      title: 'A / B',
    );

    test('区间显示 01-02 · 标题', () {
      expect(
        EpisodeTitleFormatter.formatCardTitle(
          episode: range,
          mainEpisodeCount: 12,
        ),
        '01-02 · A / B',
      );
    });

    test('占位标题显示 第 01-02 话', () {
      for (final placeholder in ['第 1-2 话', '第 01-02 话', null]) {
        final ep = EpisodeSummaryView(
          id: const EpisodeId.trusted('e'),
          workId: const WorkId.trusted('w'),
          seasonNumber: 1,
          category: EpisodeCategory.main,
          episodeNumber: 1,
          episodeNumberEnd: 2,
          title: placeholder,
        );
        expect(
          EpisodeTitleFormatter.formatCardTitle(
            episode: ep,
            mainEpisodeCount: 12,
          ),
          '第 01-02 话',
          reason: '$placeholder',
        );
      }
    });

    test('单集保持原样，集号标签补零', () {
      const single = EpisodeSummaryView(
        id: EpisodeId.trusted('e'),
        workId: WorkId.trusted('w'),
        seasonNumber: 1,
        category: EpisodeCategory.main,
        episodeNumber: 3,
        title: 'C',
      );
      expect(
        EpisodeTitleFormatter.formatCardTitle(
          episode: single,
          mainEpisodeCount: 12,
        ),
        '03 · C',
      );
      expect(EpisodeTitleFormatter.formatEpisodeNumberLabel(93, 104), '93-104');
    });

    test('外部播放器标题同样带区间', () {
      expect(
        EpisodeTitleFormatter.formatPlayerMediaTitle(
          workTitle: '作品',
          workMediaType: TmdbMediaType.tv,
          episode: range,
          mainEpisodeCount: 12,
        ),
        '作品 - 01-02 · A / B',
      );
    });
  });
}
