import 'package:engine_scraping/engine_scraping.dart' hide WorkMatcher;
import 'package:engine_scraping/src/matching/work_matcher.dart' as v2;
import 'package:engine_scraping/src/scraping/work_matcher.dart';
import 'package:test/test.dart';

void main() {
  group('问题二：Kuroko no Basket OAD 防单个前缀词误匹配', () {
    test('多词纯拉丁标题 Kuroko no Basket OAD 不拆出孤立单词 Kuroko 搜寻也不绑定无关短片', () {
      const folder = GroupedWorkFolder(
        folderRelativePath: 'Kuroko no Basket OAD',
        folderName: 'Kuroko no Basket OAD',
        cleanTitle: 'Kuroko no Basket OAD',
        mainEpisodeNumbers: [1],
        variants: [
          MediaVariant(
            id: 'v1',
            workId: 'w1',
            sourceId: 's1',
            relativePath:
                'Kuroko no Basket OAD/[Group] Kuroko no Basket OAD [01][1080p].mkv',
            fileName: '[Group] Kuroko no Basket OAD [01][1080p].mkv',
            fileSize: 100,
            assetKind: AssetKind.video,
          ),
        ],
      );
      final queries = ScrapeDomainAdapter.buildSearchQueries(folder);
      expect(
        queries.any((k) => k.trim().toLowerCase() == 'kuroko'),
        isFalse,
        reason: '禁止把多词纯拉丁标题 Kuroko no Basket 拆成孤立单词 Kuroko 搜索',
      );

      final inv = DirectoryAnalyzer.analyze('Kuroko no Basket OAD', const [
        (path: '[Group] Kuroko no Basket OAD [01][1080p].mkv', size: 100),
      ]);
      const unrelated = MatchCandidate(
        provider: 'bangumi',
        id: 112589,
        type: 'anime',
        title: 'ひとりじゃない',
        aliases: ['你不是一个人', 'Kuroko'],
        year: 2014,
        seasons: [SeasonInfo(1, 1, 2014)],
      );
      final res = WorkMatcher.bangumi(inv, const [unrelated]);
      expect(res.tier, MatchTier.none);
      expect(res.candidate, isNull);
    });
  });

  group('问题七：加速世界 TV+Movie 拆分与 EX OVA 不误绑 8 话无关《加素世界》', () {
    test('加速世界 TV+Movie 自动拆分并独立评估 TV 24集与剧场版', () {
      const folder = '加速世界 TV+Movie';
      final files = <ScannedFileInput>[
        for (var i = 1; i <= 24; i++)
          ScannedFileInput(
            relativePath:
                '$folder/[ANK-Raws] Accel World - ${i.toString().padLeft(2, '0')} [BDRip].mkv',
            fileName:
                '[ANK-Raws] Accel World - ${i.toString().padLeft(2, '0')} [BDRip].mkv',
            fileSize: 100,
            assetKind: AssetKind.video,
          ),
        const ScannedFileInput(
          relativePath:
              '$folder/[VCB-Studio] Accel World [EX01][Ma10p_1080p].mkv',
          fileName: '[VCB-Studio] Accel World [EX01][Ma10p_1080p].mkv',
          fileSize: 100,
          assetKind: AssetKind.video,
        ),
        const ScannedFileInput(
          relativePath:
              '$folder/[VCB-Studio] Accel World [EX02][Ma10p_1080p].mkv',
          fileName: '[VCB-Studio] Accel World [EX02][Ma10p_1080p].mkv',
          fileSize: 100,
          assetKind: AssetKind.video,
        ),
        const ScannedFileInput(
          relativePath:
              '$folder/[VCB-Studio] Accel World - Infinite Burst [Ma10p_1080p].mkv',
          fileName:
              '[VCB-Studio] Accel World - Infinite Burst [Ma10p_1080p].mkv',
          fileSize: 100,
          assetKind: AssetKind.video,
        ),
      ];

      final groups = ScrapeDomainAdapter.groupAndSplitFiles(
        sourceId: 's1',
        files: files,
      );
      expect(groups.length, greaterThanOrEqualTo(2));
      final tvGroup = groups.firstWhere(
        (g) => g.mainEpisodeNumbers.length == 24,
      );
      final movieGroup = groups.firstWhere(
        (g) => g.cleanTitle.toLowerCase().contains('infinite burst'),
      );
      expect(tvGroup.isSplitCluster, isTrue);
      expect(movieGroup.isMovieHint, isTrue);

      // 验证 EX1/EX2 2 话单独目录绝不会误绑 8 话《加素世界》
      final exInv = DirectoryAnalyzer.analyze('Accel World EX', const [
        (path: '[VCB-Studio] Accel World [EX1].mkv', size: 100),
        (path: '[VCB-Studio] Accel World [EX2].mkv', size: 100),
      ]);
      const fake8Ep = MatchCandidate(
        provider: 'bangumi',
        id: 67229,
        type: 'anime',
        title: '加素世界',
        aliases: ['あくちぇる・わーるど。', 'Accel World'],
        year: 2012,
        seasons: [SeasonInfo(1, 8, 2012)],
      );
      final exRes = WorkMatcher.bangumi(exInv, const [fake8Ep]);
      expect(exRes.tier, isNot(MatchTier.high));
      expect(exRes.candidate, isNull);
    });
  });

  group('问题十：弹丸论破3 续作数字硬约束与罗马音篇章词双向桥接', () {
    test('WorkMatcher 硬性阻止《弹丸论破3》匹配无 3 的 2013 第 1 部', () {
      final inv = DirectoryAnalyzer.analyze('弹丸论破3', [
        for (var i = 1; i <= 12; i++)
          (
            path:
                '[Group] Danganronpa 3 - Mirai Hen [${i.toString().padLeft(2, '0')}].mkv',
            size: 100,
          ),
      ]);
      const wrongBangumi = MatchCandidate(
        provider: 'bangumi',
        id: 56093,
        type: 'anime',
        title: '弹丸论破 希望的学园和绝望的高中生',
        aliases: ['ダンガンロンパ 希望の学園と絶望の高校生', 'Danganronpa: The Animation'],
        year: 2013,
        seasons: [SeasonInfo(1, 13, 2013)],
      );
      final bgmMatch = WorkMatcher.bangumi(inv, const [wrongBangumi]);
      expect(bgmMatch.tier, MatchTier.none);
      expect(bgmMatch.candidate, isNull);

      const wrongTmdb = MatchCandidate(
        provider: 'tmdb',
        id: 49207,
        type: 'tv',
        title: '弹丸论破 希望的学园和绝望的高中生',
        aliases: ['ダンガンロンパ', 'Danganronpa: The Animation'],
        year: 2013,
        seasons: [SeasonInfo(1, 13, 2013, name: '第 1 季')],
      );
      final tmdbMatch = WorkMatcher.tmdb(inv, const [wrongTmdb]);
      expect(tmdbMatch.tier, MatchTier.none);
      expect(tmdbMatch.candidate, isNull);
    });

    test('罗马音 Mirai Hen / Zetsubou Hen / Kibou Hen 分别自动桥接并命中未来篇/绝望篇/希望篇', () {
      final splitter = MultiWorkSplitter.split('弹丸论破3', [
        for (var i = 1; i <= 12; i++) ...[
          {
            'id': 'm$i',
            'relative_path':
                '弹丸论破3/[Group] Danganronpa 3 - The End of Kibougamine Gakuen - Mirai Hen [${i.toString().padLeft(2, '0')}].mkv',
            'name':
                '[Group] Danganronpa 3 - The End of Kibougamine Gakuen - Mirai Hen [${i.toString().padLeft(2, '0')}].mkv',
            'size': 100,
          },
          {
            'id': 'z$i',
            'relative_path':
                '弹丸论破3/[Group] Danganronpa 3 - The End of Kibougamine Gakuen - Zetsubou Hen [${i.toString().padLeft(2, '0')}].mkv',
            'name':
                '[Group] Danganronpa 3 - The End of Kibougamine Gakuen - Zetsubou Hen [${i.toString().padLeft(2, '0')}].mkv',
            'size': 100,
          },
        ],
        {
          'id': 'k1',
          'relative_path':
              '弹丸论破3/[Group] Danganronpa 3 - The End of Kibougamine Gakuen - Kibou Hen [1080p].mkv',
          'name':
              '[Group] Danganronpa 3 - The End of Kibougamine Gakuen - Kibou Hen [1080p].mkv',
          'size': 100,
        },
      ]);
      expect(splitter.length, 3);

      final queries = WorkMatcher.expandRomajiArcQueries(
        'Danganronpa 3 Mirai Hen',
      );
      expect(queries.any((String q) => q.contains('未来篇') || q.contains('未来編')), isTrue);
    });

    test('ScrapeDomainAdapter.groupAndSplitFiles 自动拆分无合集词的《弹丸论破3》并分别精确绑定未来篇(S2)与绝望篇(独立条目)', () {
      const root = '未添加TMDB ID/弹丸论破系列/弹丸论破3';
      final files = <ScannedFileInput>[
        for (var i = 1; i <= 12; i++)
          ScannedFileInput(
            relativePath:
                '$root/[LoliHouse] Danganronpa 3 - Mirai Hen - ${i.toString().padLeft(2, '0')} [BDRip 1080p HEVC-10bit FLAC].mkv',
            fileName:
                '[LoliHouse] Danganronpa 3 - Mirai Hen - ${i.toString().padLeft(2, '0')} [BDRip 1080p HEVC-10bit FLAC].mkv',
            fileSize: 1500 * 1024 * 1024,
            assetKind: AssetKind.video,
          ),
        for (var i = 1; i <= 11; i++)
          ScannedFileInput(
            relativePath:
                '$root/[LoliHouse] Danganronpa 3 - Zetsubou Hen - ${i.toString().padLeft(2, '0')} [BDRip 1080p HEVC-10bit FLAC].mkv',
            fileName:
                '[LoliHouse] Danganronpa 3 - Zetsubou Hen - ${i.toString().padLeft(2, '0')} [BDRip 1080p HEVC-10bit FLAC].mkv',
            fileSize: 1250 * 1024 * 1024,
            assetKind: AssetKind.video,
          ),
        const ScannedFileInput(
          relativePath:
              '$root/[LoliHouse] Danganronpa 3 - Kibou Hen [BDRip 1080p HEVC-10bit FLAC].mkv',
          fileName:
              '[LoliHouse] Danganronpa 3 - Kibou Hen [BDRip 1080p HEVC-10bit FLAC].mkv',
          fileSize: 1127 * 1024 * 1024,
          assetKind: AssetKind.video,
        ),
        const ScannedFileInput(
          relativePath:
              '$root/SPs/[LoliHouse] Danganronpa 3 - NCOP01 [BDRip 1080p HEVC-10bit FLAC].mkv',
          fileName:
              '[LoliHouse] Danganronpa 3 - NCOP01 [BDRip 1080p HEVC-10bit FLAC].mkv',
          fileSize: 120 * 1024 * 1024,
          assetKind: AssetKind.video,
        ),
      ];

      final grouped = ScrapeDomainAdapter.groupAndSplitFiles(
        sourceId: 'src_test',
        files: files,
      );
      expect(grouped, hasLength(3));

      final mirai = grouped.singleWhere(
        (g) => g.cleanTitle.toLowerCase().contains('mirai'),
      );
      final zetsubou = grouped.singleWhere(
        (g) => g.cleanTitle.toLowerCase().contains('zetsubou'),
      );
      final kibou = grouped.singleWhere(
        (g) => g.cleanTitle.toLowerCase().contains('kibou'),
      );
      expect(mirai.mainEpisodeNumbers, [for (var i = 1; i <= 12; i++) i]);
      expect(zetsubou.mainEpisodeNumbers, [for (var i = 1; i <= 11; i++) i]);
      expect(kibou.variants.where((v) => v.fileName.contains('Kibou Hen')), hasLength(1));

      // 验证离线映射与 TMDB 季级消歧：未来篇 -> 弹丸论破(49471) 第 2 季；绝望篇 -> 独立条目(65951) 第 1 季
      final mappingBytes = BangumiTmdbIndex.encode(
        const [
          BangumiTmdbRecord(
            bangumiId: 158415,
            type: TmdbMediaType.tv,
            tmdbId: 49471,
            season: 2,
          ),
          BangumiTmdbRecord(
            bangumiId: 163046,
            type: TmdbMediaType.tv,
            tmdbId: 65951,
            season: 1,
          ),
        ],
        snapshotDateYyyymmdd: 20261123,
      );
      final mappingIndex = BangumiTmdbIndex.fromBytes(mappingBytes);
      const tmdbMain = TmdbWorkDetail(
        tmdbId: 49471,
        mediaType: TmdbMediaType.tv,
        title: '弹丸论破',
        originalTitle: 'ダンガンロンパ 希望の学園と絶望の高校生 The Animation',
        year: 2013,
        voteCount: 500,
        aliases: ['弹丸论破', 'Danganronpa'],
        seasons: [
          TmdbSeasonSummary(
            seasonNumber: 0,
            name: '特别篇',
            episodeCount: 3,
            airDate: '2016-07-07',
          ),
          TmdbSeasonSummary(
            seasonNumber: 1,
            name: '希望的学园与绝望的高中生',
            episodeCount: 13,
            airDate: '2013-07-05',
          ),
          TmdbSeasonSummary(
            seasonNumber: 2,
            name: '-The End of 希望之峰学园-未来篇',
            episodeCount: 12,
            airDate: '2016-07-11',
          ),
        ],
      );
      const tmdbZetsubou = TmdbWorkDetail(
        tmdbId: 65951,
        mediaType: TmdbMediaType.tv,
        title: '弹丸论破3 -The End of 希望之峰学园- 绝望篇',
        originalTitle: 'ダンガンロンパ3 -The End of 希望ヶ峰学園- 絶望編',
        year: 2016,
        voteCount: 300,
        aliases: ['Danganronpa 3: The End of Hope\'s Peak High School - Despair Arc'],
        seasons: [
          TmdbSeasonSummary(
            seasonNumber: 1,
            name: '第 1 季',
            episodeCount: 11,
            airDate: '2016-07-14',
          ),
        ],
      );
      const bgmMirai = BangumiSubjectCandidate(
        id: 158415,
        name: 'ダンガンロンパ3 -The End of 希望ヶ峰学園- 未来編',
        nameCn: '弹丸论破3 -The End of 希望之峰学园- 未来篇',
        year: 2016,
        totalEpisodes: 12,
        aliases: ['弹丸论破3 未来篇', 'Danganronpa 3 Mirai Hen'],
      );
      const bgmZetsubou = BangumiSubjectCandidate(
        id: 163046,
        name: 'ダンガンロンパ3 -The End of 希望ヶ峰学園- 絶望編',
        nameCn: '弹丸论破3 -The End of 希望之峰学园- 绝望篇',
        year: 2016,
        totalEpisodes: 11,
        aliases: ['弹丸论破3 绝望篇', 'Danganronpa 3 Zetsubou Hen'],
      );

      final miraiDecision = ScrapeDomainAdapter.evaluateMatch(
        mirai,
        const [tmdbMain, tmdbZetsubou],
        bangumiCandidates: const [bgmMirai, bgmZetsubou],
        mappingIndex: mappingIndex,
      );
      expect(miraiDecision.level, v2.MatchLevel.autoBind);
      expect(miraiDecision.best?.detail.tmdbId, 49471);
      expect(miraiDecision.matchedSeason, 2);

      final zetsubouDecision = ScrapeDomainAdapter.evaluateMatch(
        zetsubou,
        const [tmdbMain, tmdbZetsubou],
        bangumiCandidates: const [bgmMirai, bgmZetsubou],
        mappingIndex: mappingIndex,
      );
      expect(zetsubouDecision.level, v2.MatchLevel.autoBind);
      expect(zetsubouDecision.best?.detail.tmdbId, 65951);
      expect(zetsubouDecision.matchedSeason, 1);

      // 反向守卫：同作双语多压制组洗版目录绝不被误拆为多部作品
      final dualGroupGrouped = ScrapeDomainAdapter.groupAndSplitFiles(
        sourceId: 'src_test',
        files: [
          for (var i = 1; i <= 6; i++) ...[
            ScannedFileInput(
              relativePath:
                  '葬送的芙莉莲/[VCB-Studio] Sousou no Frieren - ${i.toString().padLeft(2, '0')} [1080p].mkv',
              fileName:
                  '[VCB-Studio] Sousou no Frieren - ${i.toString().padLeft(2, '0')} [1080p].mkv',
              fileSize: 900 * 1024 * 1024,
              assetKind: AssetKind.video,
            ),
            ScannedFileInput(
              relativePath:
                  '葬送的芙莉莲/[LoliHouse] Frieren Beyond Journeys End - ${i.toString().padLeft(2, '0')} [1080p].mkv',
              fileName:
                  '[LoliHouse] Frieren Beyond Journeys End - ${i.toString().padLeft(2, '0')} [1080p].mkv',
              fileSize: 850 * 1024 * 1024,
              assetKind: AssetKind.video,
            ),
          ],
        ],
      );
      expect(dualGroupGrouped, hasLength(1));
    });
  });

  group('问题三与问题六：Alternative ONE/TWO 与罗马数字 Ⅴ 搜索变体展开', () {
    test('Alternative 双集目录自动生成 ONE/TWO 检索词', () {
      const folder = GroupedWorkFolder(
        folderRelativePath: '侦探歌剧 少女福尔摩斯 Alternative',
        folderName: '侦探歌剧 少女福尔摩斯 Alternative',
        cleanTitle: '侦探歌剧 少女福尔摩斯 Alternative',
        mainEpisodeNumbers: [1, 2],
        variants: [
          MediaVariant(
            id: 'v1',
            workId: 'w1',
            sourceId: 's1',
            relativePath:
                '侦探歌剧 少女福尔摩斯 Alternative/[Group] Tantei Opera Milky Holmes Alternative [01].mkv',
            fileName: '[Group] Tantei Opera Milky Holmes Alternative [01].mkv',
            fileSize: 100,
            assetKind: AssetKind.video,
          ),
          MediaVariant(
            id: 'v2',
            workId: 'w1',
            sourceId: 's1',
            relativePath:
                '侦探歌剧 少女福尔摩斯 Alternative/[Group] Tantei Opera Milky Holmes Alternative [02].mkv',
            fileName: '[Group] Tantei Opera Milky Holmes Alternative [02].mkv',
            fileSize: 100,
            assetKind: AssetKind.video,
          ),
        ],
      );
      final queries = ScrapeDomainAdapter.buildSearchQueries(folder);
      expect(
        queries.any((q) => q.contains('ONE')) &&
            queries.any((q) => q.contains('TWO')),
        isTrue,
      );
    });

    test('Unicode 罗马数字 Ⅴ 自动展开 ASCII V 与阿拉伯 5 变体', () {
      const folder = GroupedWorkFolder(
        folderRelativePath: '剧场版 高达Reconguista in G Ⅴ 越过死线 (2022)',
        folderName: '剧场版 高达Reconguista in G Ⅴ 越过死线 (2022)',
        cleanTitle: '剧场版 高达Reconguista in G Ⅴ 越过死线',
        year: 2022,
        isMovieHint: true,
        variants: [
          MediaVariant(
            id: 'v1',
            workId: 'w1',
            sourceId: 's1',
            relativePath:
                '剧场版 高达Reconguista in G Ⅴ 越过死线 (2022)/[Group] Gundam Reconguista in G V - Shisen wo Koete [1080p].mkv',
            fileName:
                '[Group] Gundam Reconguista in G V - Shisen wo Koete [1080p].mkv',
            fileSize: 100,
            assetKind: AssetKind.video,
          ),
        ],
      );
      final queries = ScrapeDomainAdapter.buildSearchQueries(folder);
      expect(queries.any((q) => q.contains('V') && !q.contains('Ⅴ')), isTrue);
      expect(queries.any((q) => q.contains('5')), isTrue);
    });
  });
}
