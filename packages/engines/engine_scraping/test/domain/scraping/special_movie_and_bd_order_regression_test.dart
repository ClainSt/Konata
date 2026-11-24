import 'package:engine_scraping/engine_scraping.dart';
import 'package:test/test.dart';

import '../../support/test_helpers.dart';

void main() {
  group('特别篇正片映射、孤岛电影防误杀、罗马分部电影拆分与 BD 集序对齐回归', () {
    late StorageScrapeRepository repo;
    late ScrapeWorkPersister persister;

    setUp(() async {
      repo = openTestScrapeDatabase().repository;
      persister = ScrapeWorkPersister(repo);
      await repo.upsertMediaSource(
        const MediaSource(
          id: 'src_1',
          kind: MediaSourceKind.local,
          label: '测试源',
          location: '/anime',
        ),
      );
    });

    tearDown(() async {
    });

    ScannedFileInput videoFile(
      String folderPath,
      String fileName, {
      int fileSize = 1500 * 1024 * 1024,
    }) => ScannedFileInput(
      relativePath: '$folderPath/$fileName',
      fileName: fileName,
      fileSize: fileSize,
      assetKind: AssetKind.video,
    );

    test('1. 少女福尔摩斯 Alternative 01/02 精准落位至 Season 0 第 2/3 集且绝不串入第 1 季', () async {
      const folderPath = '未添加TMDB ID/少女福尔摩斯系列/侦探歌剧 少女福尔摩斯 Alternative';
      final files = [
        videoFile(
          folderPath,
          '[ReinForce] Tantei Opera Milky Holmes Alternative - 01 (BDRip 1920x1080 x264 FLAC).mkv',
        ),
        videoFile(
          folderPath,
          '[ReinForce] Tantei Opera Milky Holmes Alternative - 02 (BDRip 1920x1080 x264 FLAC).mkv',
          fileSize: 1600 * 1024 * 1024,
        ),
      ];

      final grouped = ScrapeDomainAdapter.groupAndSplitFiles(
        sourceId: 'src_1',
        files: files,
      );
      expect(grouped, hasLength(2));

      const tmdbEpisodes = <TmdbEpisodeDetail>[
        TmdbEpisodeDetail(
          seasonNumber: 1,
          episodeNumber: 1,
          title: '屋顶的潜入者',
          stillPath: '/s1e1_wrong.jpg',
          airDate: '2010-10-07',
        ),
        TmdbEpisodeDetail(
          seasonNumber: 0,
          episodeNumber: 1,
          title: '夏天到了！神秘事件！',
          stillPath: '/s0e1.jpg',
          airDate: '2011-08-26',
        ),
        TmdbEpisodeDetail(
          seasonNumber: 0,
          episodeNumber: 2,
          title: 'Alternative ONE 小林奥帕拉与五幅绘画',
          overview: '小林奥帕拉与五幅绘画简介',
          stillPath: '/s0e2_alt1.jpg',
          airDate: '2012-08-25',
        ),
        TmdbEpisodeDetail(
          seasonNumber: 0,
          episodeNumber: 3,
          title: 'Alternative TWO 小林奥帕拉与虚空的大鸦',
          overview: '小林奥帕拉与虚空的大鸦简介',
          stillPath: '/s0e3_alt2.jpg',
          airDate: '2013-01-03',
        ),
      ];

      final alt1Folder = grouped.firstWhere(
        (g) => g.variants.any((v) => v.fileName.contains('- 01')),
      );
      final alt2Folder = grouped.firstWhere(
        (g) => g.variants.any((v) => v.fileName.contains('- 02')),
      );

      // 确认拉取季集合在 matchedSeason == 0 时不会附带拉取第 1 季。
      const parentDetail = TmdbWorkDetail(
        tmdbId: 51492,
        mediaType: TmdbMediaType.tv,
        title: '侦探歌剧 少女福尔摩斯',
        originalTitle: '探偵オペラ ミルキィホームズ',
        year: 2010,
        seasons: [
          TmdbSeasonSummary(seasonNumber: 0, name: '特别篇', episodeCount: 6),
          TmdbSeasonSummary(seasonNumber: 1, name: '第 1 季', episodeCount: 12),
        ],
      );
      expect(
        ScrapeDomainAdapter.referencedSeasonsToFetch(
          alt1Folder,
          matchedSeason: 0,
          detail: parentDetail,
        ),
        equals({0}),
      );

      // 验证即便同时传入 Season 1 剧集（例如旧记录重绑定场景），Alternative 01 也绝不串入 S01E01。
      const workAlt1 = Work(
        id: 'work_alt1',
        tmdbId: 51492,
        tmdbMediaType: TmdbMediaType.tv,
        bangumiId: 47464,
        matchedSeason: 0,
        title: '侦探歌剧 少女福尔摩斯 Alternative ONE',
        year: 2012,
        scrapeStatus: ScrapeStatus.matched,
      );
      await repo.upsertWork(workAlt1);
      await persister.syncEpisodesAndVariants(
        work: workAlt1,
        folder: alt1Folder,
        tmdbEpisodes: tmdbEpisodes,
        bangumiEpisodes: const [
          BangumiEpisodeEntry(
            id: 1,
            type: 0,
            ep: 1,
            sort: 1,
            name: 'Alternative ONE',
            nameCn: 'Alternative ONE 小林歌剧与五幅画作',
            airDate: '2012-08-25',
          ),
        ],
      );

      final ep1List = await repo.getEpisodesByWork(workAlt1.id);
      expect(ep1List, hasLength(1));
      expect(ep1List.single.category, EpisodeCategory.main);
      expect(ep1List.single.seasonNumber, 0);
      expect(ep1List.single.episodeNumber, 2);
      expect(ep1List.single.title, 'Alternative ONE 小林奥帕拉与五幅绘画');
      expect(ep1List.single.stillPath, '/s0e2_alt1.jpg');

      // 验证 Alternative 02 精确落位至 S00E03 且获得完整标题与剧照。
      const workAlt2 = Work(
        id: 'work_alt2',
        tmdbId: 51492,
        tmdbMediaType: TmdbMediaType.tv,
        bangumiId: 54728,
        matchedSeason: 0,
        title: '侦探歌剧 少女福尔摩斯 Alternative TWO',
        year: 2012,
        scrapeStatus: ScrapeStatus.matched,
      );
      await repo.upsertWork(workAlt2);
      await persister.syncEpisodesAndVariants(
        work: workAlt2,
        folder: alt2Folder,
        tmdbEpisodes: tmdbEpisodes,
        bangumiEpisodes: const [
          BangumiEpisodeEntry(
            id: 2,
            type: 0,
            ep: 1,
            sort: 1,
            name: 'Alternative TWO',
            nameCn: 'Alternative TWO 小林歌剧与虚空的大鸦',
            airDate: '2013-01-03',
          ),
        ],
      );

      final ep2List = await repo.getEpisodesByWork(workAlt2.id);
      expect(ep2List, hasLength(1));
      expect(ep2List.single.category, EpisodeCategory.main);
      expect(ep2List.single.seasonNumber, 0);
      expect(ep2List.single.episodeNumber, 3);
      expect(ep2List.single.title, 'Alternative TWO 小林奥帕拉与虚空的大鸦');
      expect(ep2List.single.stillPath, '/s0e3_alt2.jpg');

      // 验证多版本（双压制组）同一特别篇共享同一 S00E03 槽位而不被拆分或丢失第二版。
      final multiVerAlt2Folder = GroupedWorkFolder(
        folderRelativePath: alt2Folder.folderRelativePath,
        folderName: alt2Folder.folderName,
        cleanTitle: alt2Folder.cleanTitle,
        year: 2012,
        seasonHint: 0,
        variants: [
          ...alt2Folder.variants,
          const MediaVariant(
            id: 'alt2_v2',
            workId: 'work_alt2_mv',
            sourceId: 'src_1',
            relativePath:
                '$folderPath/[VCB-Studio] Tantei Opera Milky Holmes Alternative - 02 [Ma10p_1080p].mkv',
            fileName:
                '[VCB-Studio] Tantei Opera Milky Holmes Alternative - 02 [Ma10p_1080p].mkv',
            fileSize: 1200 * 1024 * 1024,
          ),
        ],
      );
      const workAlt2Mv = Work(
        id: 'work_alt2_mv',
        tmdbId: 51492,
        tmdbMediaType: TmdbMediaType.tv,
        matchedSeason: 0,
        title: '侦探歌剧 少女福尔摩斯 Alternative TWO',
        year: 2012,
        scrapeStatus: ScrapeStatus.matched,
      );
      await repo.upsertWork(workAlt2Mv);
      await persister.syncEpisodesAndVariants(
        work: workAlt2Mv,
        folder: multiVerAlt2Folder,
        tmdbEpisodes: tmdbEpisodes,
      );
      final mvEps = await repo.getEpisodesByWork(workAlt2Mv.id);
      final mvVars = await repo.getVariantsByWork(workAlt2Mv.id);
      expect(mvEps, hasLength(1));
      expect(mvEps.single.episodeNumber, 3);
      expect(mvVars, hasLength(2));
      expect(mvVars.every((v) => v.episodeId == mvEps.single.id), isTrue);

      // 验证无法辨识身份的特别篇绝不盲目回落错贴 S00E01。
      const mysteryWork = Work(
        id: 'work_mystery_s0',
        tmdbId: 51492,
        tmdbMediaType: TmdbMediaType.tv,
        matchedSeason: 0,
        title: '侦探歌剧 少女福尔摩斯 未知特别篇',
        year: 2020,
        scrapeStatus: ScrapeStatus.matched,
      );
      const mysteryFolder = GroupedWorkFolder(
        folderRelativePath: '未添加TMDB ID/少女福尔摩斯系列/未知特别篇',
        folderName: '未知特别篇',
        cleanTitle: '未知特别篇',
        year: 2020,
        seasonHint: 0,
        mainEpisodeNumbers: [1],
        variants: [
          MediaVariant(
            id: 'mys_1',
            workId: 'work_mystery_s0',
            sourceId: 'src_1',
            relativePath: '未添加TMDB ID/少女福尔摩斯系列/未知特别篇/Unknown Special - 01.mkv',
            fileName: 'Unknown Special - 01.mkv',
            fileSize: 800 * 1024 * 1024,
          ),
        ],
      );
      await repo.upsertWork(mysteryWork);
      await persister.syncEpisodesAndVariants(
        work: mysteryWork,
        folder: mysteryFolder,
        tmdbEpisodes: tmdbEpisodes,
      );
      final mysEps = await repo.getEpisodesByWork(mysteryWork.id);
      expect(mysEps, hasLength(1));
      expect(mysEps.single.seasonNumber, 0);
      expect(mysEps.single.stillPath, isNull);
      expect(mysEps.single.title, isNot('夏天到了！神秘事件！'));
      expect(mysEps.single.title, isNot('屋顶的潜入者'));
    });

    test('2. 派对之夜电视特别篇不被无背景孤岛电影劫持，归入母剧 Season 0 并继承横版背景与 S00E04', () async {
      const folderPath =
          '未添加TMDB ID/少女福尔摩斯系列/侦探歌剧 少女福尔摩斯 派对之夜 & 侦探歌剧 少女福尔摩斯 亚森 华丽的欲望';
      final files = [
        videoFile(
          folderPath,
          '[ReinForce] Tantei Opera Milky Holmes Fun Fun Pearly Night - Ken to Janet no Okurimono (BDRip 1920x1080 x264 FLAC).mkv',
          fileSize: 1800 * 1024 * 1024,
        ),
        videoFile(
          folderPath,
          '[ReinForce] Tantei Opera Milky Holmes - Arsene Karei Naru Yokubou (BDRip 1920x1080 x264 FLAC).mkv',
          fileSize: 1700 * 1024 * 1024,
        ),
      ];

      final grouped = ScrapeDomainAdapter.groupAndSplitFiles(
        sourceId: 'src_1',
        files: files,
      );
      expect(grouped, hasLength(2));
      final pearlyFolder = grouped.firstWhere(
        (g) => g.variants.any((v) => v.fileName.contains('Fun Fun Pearly Night')),
      );

      const bgmPearly = BangumiSubjectCandidate(
        id: 193031,
        name: '探偵オペラ ミルキィホームズ ファンファンパーリーナイト♪ ～ケンとジャネットの贈り物～',
        nameCn: '侦探歌剧 少女福尔摩斯 派对之夜♪ ～肯和珍妮特的礼物～',
        year: 2016,
        totalEpisodes: 1,
        score: 6.8,
        platform: 'TV',
        posterUrl: 'https://bgm.example/pearly.jpg',
      );
      // 仅凭单文件形态推演的弱 isMovieHint 不应覆盖 Bangumi 的 TV 平台标记。
      expect(
        ScrapeDomainAdapter.expectsStandaloneMovie(pearlyFolder, bgmPearly),
        isFalse,
      );
      expect(
        ScrapeDomainAdapter.expectsStandaloneMovie(
          pearlyFolder,
          const BangumiSubjectCandidate(
            id: 999999,
            name: '劇場版 テスト',
            nameCn: '剧场版 测试',
            year: 2021,
            platform: '剧场版',
          ),
        ),
        isTrue,
      );

      const orphanMovieStub = TmdbWorkDetail(
        tmdbId: 901234,
        mediaType: TmdbMediaType.movie,
        title: '探偵オペラ ミルキィホームズ ファンファンパーリーナイト♪ ～ケンとジャネットの贈り物～',
        originalTitle: '探偵オペラ ミルキィホームズ ファンファンパーリーナイト♪ ～ケンとジャネットの贈り物～',
        year: 2016,
        genreIds: [16, 35],
        voteCount: 1,
        backdropPath: null,
        posterPath: '/orphan_poster.jpg',
      );
      const parentTv = TmdbWorkDetail(
        tmdbId: 51492,
        mediaType: TmdbMediaType.tv,
        title: '侦探歌剧 少女福尔摩斯',
        originalTitle: '探偵オペラ ミルキィホームズ',
        year: 2010,
        genreIds: [16, 35],
        voteCount: 42,
        backdropPath: '/mh_horizontal_backdrop.jpg',
        logoPath: '/mh_clearlogo.png',
        seasons: [
          TmdbSeasonSummary(
            seasonNumber: 0,
            name: '特别篇',
            episodeCount: 6,
            airDate: '2011-08-26',
          ),
          TmdbSeasonSummary(
            seasonNumber: 1,
            name: '第 1 季',
            episodeCount: 12,
            airDate: '2010-10-07',
          ),
        ],
      );

      final decision = ScrapeDomainAdapter.evaluateMatch(
        pearlyFolder,
        const [orphanMovieStub, parentTv],
        bangumiCandidates: const [bgmPearly],
      );
      expect(decision.level, MatchLevel.autoBind);
      expect(decision.best?.detail.tmdbId, 51492);
      expect(decision.best?.detail.mediaType, TmdbMediaType.tv);
      expect(decision.matchedSeason, 0);
      expect(decision.best?.detail.backdropPath, '/mh_horizontal_backdrop.jpg');

      // 进一步验证持久化后单集精准命中 S00E04 有趣的珍珠之夜。
      final workPearly = ScrapeWorkPersister.buildMatchedWork(
        id: 'work_pearly',
        detail: decision.best!.detail,
        folder: pearlyFolder,
        matchedSeason: decision.matchedSeason,
        bangumiCandidate: decision.bestBangumi,
        isManualLocked: false,
      );
      expect(workPearly.backdropPath, '/mh_horizontal_backdrop.jpg');
      expect(workPearly.matchedSeason, 0);
      await repo.upsertWork(workPearly);
      await persister.syncEpisodesAndVariants(
        work: workPearly,
        folder: pearlyFolder,
        tmdbEpisodes: const [
          TmdbEpisodeDetail(
            seasonNumber: 0,
            episodeNumber: 2,
            title: 'Alternative ONE 小林奥帕拉与五幅绘画',
            airDate: '2012-08-25',
          ),
          TmdbEpisodeDetail(
            seasonNumber: 0,
            episodeNumber: 4,
            title: '有趣的珍珠之夜 ~ 肯和珍妮特的礼物 ~',
            overview: '一个甜蜜的圣诞特辑，模仿欧亨利的麦琪的礼物。',
            airDate: '2016-12-30',
          ),
          TmdbEpisodeDetail(
            seasonNumber: 0,
            episodeNumber: 5,
            title: 'アルセーヌ 華麗なる欲望',
            airDate: '2017-12-31',
          ),
        ],
        bangumiEpisodes: const [
          BangumiEpisodeEntry(
            id: 4001,
            type: 0,
            ep: 1,
            sort: 1,
            name: 'ファンファンパーリーナイト♪ ～ケンとジャネットの贈り物～',
            nameCn: '派对之夜♪ ～肯和珍妮特的礼物～',
            airDate: '2016-12-31',
          ),
        ],
      );
      final pearlyEps = await repo.getEpisodesByWork(workPearly.id);
      expect(pearlyEps, hasLength(1));
      expect(pearlyEps.single.seasonNumber, 0);
      expect(pearlyEps.single.episodeNumber, 4);
      expect(pearlyEps.single.title, '有趣的珍珠之夜 ~ 肯和珍妮特的礼物 ~');
    });

    test('3. BanG Dream! Episode of Roselia I & II 锚定目录下拆分为两部独立电影且不误传 TMDB ID', () {
      const folderPath =
          '动画-多作品/BanG Dream! 作品集/剧场版 BanG Dream! Episode of Roselia (2021) {tmdb-852743}';
      final files = [
        videoFile(
          folderPath,
          '[VCB-Studio] BanG Dream! Episode of Roselia I: Promise [Ma10p_1080p][x265_flac].mkv',
          fileSize: 3285649981,
        ),
        videoFile(
          folderPath,
          '[VCB-Studio] BanG Dream! Episode of Roselia II: Song I am. [Ma10p_1080p][x265_flac].mkv',
          fileSize: 3639984455,
        ),
      ];

      final grouped = ScrapeDomainAdapter.groupAndSplitFiles(
        sourceId: 'src_1',
        files: files,
      );
      expect(grouped, hasLength(2));
      expect(grouped.every((g) => g.isMovieHint), isTrue);
      // 两部独立剧场版均不得把目录级 {tmdb-852743} 强制锁死到第二部电影上。
      expect(grouped.every((g) => g.explicitTmdbId == null), isTrue);
      expect(
        grouped.any(
          (g) =>
              g.variants.length == 1 &&
              g.variants.single.fileName.contains('I: Promise'),
        ),
        isTrue,
      );
      expect(
        grouped.any(
          (g) =>
              g.variants.length == 1 &&
              g.variants.single.fileName.contains('II: Song I am.'),
        ),
        isTrue,
      );

      // 同一部电影的双压制版保留在同一部电影下作为 2 版本，与第二部电影互不混淆。
      final groupedWithMultiVer = ScrapeDomainAdapter.groupAndSplitFiles(
        sourceId: 'src_1',
        files: [
          ...files,
          videoFile(
            folderPath,
            '[ReinForce] BanG Dream! Episode of Roselia I: Promise (BDRip 1920x1080 x264 FLAC).mkv',
            fileSize: 2800000000,
          ),
        ],
      );
      expect(groupedWithMultiVer, hasLength(2));
      final part1 = groupedWithMultiVer.firstWhere(
        (g) => g.variants.any((v) => v.fileName.contains('I: Promise')),
      );
      final part2 = groupedWithMultiVer.firstWhere(
        (g) => g.variants.any((v) => v.fileName.contains('II: Song I am.')),
      );
      expect(part1.variants, hasLength(2));
      expect(part2.variants, hasLength(1));

      // 同样覆盖罗马数字加点号的三部曲电影目录（如 Fate/stay night Heaven's Feel I./II./III.）。
      const hfFolder = '剧场版/Fate stay night Heavens Feel (2017) {tmdb-283984}';
      final hfGrouped = ScrapeDomainAdapter.groupAndSplitFiles(
        sourceId: 'src_1',
        files: [
          videoFile(
            hfFolder,
            '[VCB-Studio] Fate stay night Heavens Feel I. presage flower [Ma10p_1080p].mkv',
            fileSize: 4000000000,
          ),
          videoFile(
            hfFolder,
            '[VCB-Studio] Fate stay night Heavens Feel II. lost butterfly [Ma10p_1080p].mkv',
            fileSize: 4100000000,
          ),
          videoFile(
            hfFolder,
            '[VCB-Studio] Fate stay night Heavens Feel III. spring song [Ma10p_1080p].mkv',
            fileSize: 4200000000,
          ),
        ],
      );
      expect(hfGrouped, hasLength(3));
      expect(hfGrouped.every((g) => g.isMovieHint), isTrue);
    });

    test('4. 全金属狂潮？校园篇 BD 12 集按 Bangumi 语义对齐 TMDB 11 集 + Season 0，零错位零重名', () async {
      const folderPath = '全金属狂潮/全金属狂潮？校园篇 (2003)';
      final fumoffuFolder = GroupedWorkFolder(
        folderRelativePath: folderPath,
        folderName: '全金属狂潮？校园篇 (2003)',
        cleanTitle: '全金属狂潮？校园篇',
        year: 2003,
        seasonHint: 2,
        mainEpisodeNumbers: [for (var i = 1; i <= 12; i++) i],
        variants: [
          for (var i = 1; i <= 12; i++)
            MediaVariant(
              id: 'fmp_$i',
              workId: 'work_fumoffu',
              sourceId: 'src_1',
              relativePath:
                  '$folderPath/[VCB-Studio] Full Metal Panic Fumoffu [${'$i'.padLeft(2, '0')}][Ma10p_1080p].mkv',
              fileName:
                  '[VCB-Studio] Full Metal Panic Fumoffu [${'$i'.padLeft(2, '0')}][Ma10p_1080p].mkv',
              fileSize: 900 * 1024 * 1024,
            ),
        ],
      );

      const tmdbSeasons = <TmdbSeasonSummary>[
        TmdbSeasonSummary(seasonNumber: 0, name: '特别篇', episodeCount: 3),
        TmdbSeasonSummary(seasonNumber: 1, name: '第 1 季', episodeCount: 24),
        TmdbSeasonSummary(seasonNumber: 2, name: '校园篇', episodeCount: 11),
      ];

      // 预热阶段即可识别 12 > 11 的集数分歧并自动请求 Season 0 与 Bangumi 分集。
      final preRemap = EpisodeRemapper.buildPlan(
        folder: fumoffuFolder,
        tmdbSeasons: tmdbSeasons,
        matchedSeason: 2,
      );
      expect(preRemap.hasInterspersedSpecialCandidate, isTrue);
      expect(preRemap.referencedSeasons, containsAll([0, 2]));
      expect(
        EpisodeRemapper.shouldFetchBangumiEpisodes(
          matchedSeason: 2,
          tmdbEpisodes: const [
            TmdbEpisodeDetail(seasonNumber: 2, episodeNumber: 1, title: '占位'),
          ],
          preRemap: preRemap,
        ),
        isTrue,
      );

      const tmdbEpisodes = <TmdbEpisodeDetail>[
        TmdbEpisodeDetail(
          seasonNumber: 0,
          episodeNumber: 1,
          title: '无须妥协的人质危机',
          stillPath: '/s0e1_hostage.jpg',
        ),
        TmdbEpisodeDetail(
          seasonNumber: 0,
          episodeNumber: 2,
          title: '擦身而过的敌意',
          stillPath: '/s0e2_hostility.jpg',
        ),
        TmdbEpisodeDetail(
          seasonNumber: 2,
          episodeNumber: 1,
          title: '从南方来的男人/白忙一场的午餐时间',
          stillPath: '/s2e1_south.jpg',
          airDate: '2003-08-26',
        ),
        TmdbEpisodeDetail(
          seasonNumber: 2,
          episodeNumber: 2,
          title: '钢铁的夏日幻影',
          stillPath: '/s2e2_summer.jpg',
          airDate: '2003-09-02',
        ),
        TmdbEpisodeDetail(
          seasonNumber: 2,
          episodeNumber: 3,
          title: '艺术的汉堡山/执着的监视',
          stillPath: '/s2e3_burger.jpg',
        ),
        TmdbEpisodeDetail(
          seasonNumber: 2,
          episodeNumber: 4,
          title: '纯洁而不纯洁的格斗家/善意的入侵',
          stillPath: '/s2e4_grappler.jpg',
        ),
        TmdbEpisodeDetail(
          seasonNumber: 2,
          episodeNumber: 5,
          title: '强买强卖的恋物癖/黑暗中的病人',
          stillPath: '/s2e5_fetish.jpg',
        ),
        TmdbEpisodeDetail(
          seasonNumber: 2,
          episodeNumber: 6,
          title: '过火的战吼',
          stillPath: '/s2e6_warcry.jpg',
        ),
        TmdbEpisodeDetail(
          seasonNumber: 2,
          episodeNumber: 7,
          title: '女神的来日（受难篇）',
          stillPath: '/s2e7_goddess1.jpg',
        ),
        TmdbEpisodeDetail(
          seasonNumber: 2,
          episodeNumber: 8,
          title: '女神的来日（温泉篇）',
          stillPath: '/s2e8_goddess2.jpg',
        ),
        TmdbEpisodeDetail(
          seasonNumber: 2,
          episodeNumber: 9,
          title: '无仁义的幻想',
          stillPath: '/s2e9_fancy.jpg',
        ),
        TmdbEpisodeDetail(
          seasonNumber: 2,
          episodeNumber: 10,
          title: '不如意的青鸟',
          stillPath: '/s2e10_bluebird.jpg',
        ),
        TmdbEpisodeDetail(
          seasonNumber: 2,
          episodeNumber: 11,
          title: '第五堂课的危险区域',
          stillPath: '/s2e11_hotspot.jpg',
        ),
      ];

      const bgmEpisodes = <BangumiEpisodeEntry>[
        BangumiEpisodeEntry(
          id: 1,
          type: 0,
          ep: 1,
          sort: 1,
          name: '南から来た男 / 妥協無用のホステージ',
          nameCn: '南方来的男人 / 无须妥协的人质危机',
          airDate: '2003-08-25',
        ),
        BangumiEpisodeEntry(
          id: 2,
          type: 0,
          ep: 2,
          sort: 2,
          name: 'すれ違いのホスティリティ / から回りのランチタイム',
          nameCn: '擦身而过的敌意 / 白忙一场的午餐时间',
        ),
        BangumiEpisodeEntry(
          id: 3,
          type: 0,
          ep: 3,
          sort: 3,
          name: '鋼鉄のサマー・イリュージョン',
          nameCn: '钢铁的夏日幻影',
          airDate: '2003-09-02',
        ),
        BangumiEpisodeEntry(
          id: 4,
          type: 0,
          ep: 4,
          sort: 4,
          name: '芸術のハンバーガー・ヒル / 一途なステイク・アウト',
          nameCn: '艺术的汉堡山 / 执着的监视',
        ),
        BangumiEpisodeEntry(
          id: 5,
          type: 0,
          ep: 5,
          sort: 5,
          name: '純で不純なグラップラー / 善意のトレスパス',
          nameCn: '纯洁而不纯洁的格斗家 / 善意的入侵',
        ),
        BangumiEpisodeEntry(
          id: 6,
          type: 0,
          ep: 6,
          sort: 6,
          name: '押し売りのフェティッシュ / 暗闇のペイシェント',
          nameCn: '强买强卖的恋物癖 / 黑暗中的病人',
        ),
        BangumiEpisodeEntry(
          id: 7,
          type: 0,
          ep: 7,
          sort: 7,
          name: 'やりすぎのウォークライ',
          nameCn: '过火的战吼',
        ),
        BangumiEpisodeEntry(
          id: 8,
          type: 0,
          ep: 8,
          sort: 8,
          name: '女神の来日(受難編)',
          nameCn: '女神的来日（受难篇）',
        ),
        BangumiEpisodeEntry(
          id: 9,
          type: 0,
          ep: 9,
          sort: 9,
          name: '女神の来日(温泉編)',
          nameCn: '女神的来日（温泉篇）',
        ),
        BangumiEpisodeEntry(
          id: 10,
          type: 0,
          ep: 10,
          sort: 10,
          name: '仁義なきファンシー',
          nameCn: '无仁义的幻想',
        ),
        BangumiEpisodeEntry(
          id: 11,
          type: 0,
          ep: 11,
          sort: 11,
          name: 'ままならないブルーバード',
          nameCn: '不如意的青鸟',
        ),
        BangumiEpisodeEntry(
          id: 12,
          type: 0,
          ep: 12,
          sort: 12,
          name: '五時間目のホット・スポット',
          nameCn: '第五堂课的危险区域',
        ),
      ];

      final fullPlan = EpisodeRemapper.buildPlan(
        folder: fumoffuFolder,
        tmdbSeasons: tmdbSeasons,
        matchedSeason: 2,
        tmdbEpisodes: tmdbEpisodes,
        bangumiEpisodes: bgmEpisodes,
      );
      expect(fullPlan.metadataOverrides, hasLength(12));
      expect(fullPlan.resolveMetadataTarget(2, 1)?.tmdbSeasonNumber, 2);
      expect(fullPlan.resolveMetadataTarget(2, 1)?.tmdbEpisodeNumber, 1);
      expect(fullPlan.resolveMetadataTarget(2, 1)?.preferBangumiTitle, isTrue);
      expect(fullPlan.resolveMetadataTarget(2, 2)?.tmdbSeasonNumber, 0);
      expect(fullPlan.resolveMetadataTarget(2, 2)?.tmdbEpisodeNumber, 2);
      expect(fullPlan.resolveMetadataTarget(2, 2)?.preferBangumiTitle, isTrue);
      expect(fullPlan.resolveMetadataTarget(2, 3)?.tmdbEpisodeNumber, 2);
      expect(fullPlan.resolveMetadataTarget(2, 11)?.tmdbEpisodeNumber, 10);
      expect(fullPlan.resolveMetadataTarget(2, 12)?.tmdbEpisodeNumber, 11);

      const workFumoffu = Work(
        id: 'work_fumoffu',
        tmdbId: 39379,
        tmdbMediaType: TmdbMediaType.tv,
        bangumiId: 337,
        matchedSeason: 2,
        title: '全金属狂潮？校园篇',
        year: 2003,
        scrapeStatus: ScrapeStatus.matched,
      );
      await repo.upsertWork(workFumoffu);
      await persister.syncEpisodesAndVariants(
        work: workFumoffu,
        folder: fumoffuFolder,
        tmdbEpisodes: tmdbEpisodes,
        bangumiEpisodes: bgmEpisodes,
        remapPlan: fullPlan,
      );

      final persisted = (await repo.getEpisodesByWork(workFumoffu.id))
        ..sort((a, b) => (a.episodeNumber ?? 0).compareTo(b.episodeNumber ?? 0));
      expect(persisted, hasLength(12));
      expect(
        persisted.every((e) => e.category == EpisodeCategory.main && e.seasonNumber == 2),
        isTrue,
      );
      expect(persisted.map((e) => e.episodeNumber).toList(), [
        for (var i = 1; i <= 12; i++) i,
      ]);
      // 每集均有唯一标题与剧照，彻底消除第 11/12 话重名与第 12 话缺图。
      expect(persisted.map((e) => e.title).toSet(), hasLength(12));
      expect(persisted.every((e) => e.stillPath != null), isTrue);

      expect(persisted[0].title, '南方来的男人 / 无须妥协的人质危机');
      expect(persisted[0].stillPath, '/s2e1_south.jpg');
      expect(persisted[1].title, '擦身而过的敌意 / 白忙一场的午餐时间');
      expect(persisted[1].stillPath, '/s0e2_hostility.jpg');
      expect(persisted[2].title, '钢铁的夏日幻影');
      expect(persisted[2].stillPath, '/s2e2_summer.jpg');
      expect(persisted[10].title, '不如意的青鸟');
      expect(persisted[10].stillPath, '/s2e10_bluebird.jpg');
      expect(persisted[11].title, '第五堂课的危险区域');
      expect(persisted[11].stillPath, '/s2e11_hotspot.jpg');

      // 模拟旧数据错位重刷且 TMDB Season 0 缺失第 2 集：Ep 02 的旧错位剧照必须清空，不得残留 S02E02 剧照。
      final tmdbWithoutS0 = tmdbEpisodes
          .where((e) => e.seasonNumber != 0)
          .toList(growable: false);
      final planWithoutS0 = EpisodeRemapper.buildPlan(
        folder: fumoffuFolder,
        tmdbSeasons: tmdbSeasons,
        matchedSeason: 2,
        tmdbEpisodes: tmdbWithoutS0,
        bangumiEpisodes: bgmEpisodes,
      );
      await persister.syncEpisodesAndVariants(
        work: workFumoffu,
        folder: fumoffuFolder,
        tmdbEpisodes: tmdbWithoutS0,
        bangumiEpisodes: bgmEpisodes,
        remapPlan: planWithoutS0,
      );
      final rePersisted = (await repo.getEpisodesByWork(workFumoffu.id))
        ..sort((a, b) => (a.episodeNumber ?? 0).compareTo(b.episodeNumber ?? 0));
      expect(rePersisted[1].title, '擦身而过的敌意 / 白忙一场的午餐时间');
      expect(rePersisted[1].stillPath, isNull);
      expect(rePersisted[2].title, '钢铁的夏日幻影');
      expect(rePersisted[2].stillPath, '/s2e2_summer.jpg');

      // 防误触发护栏：TMDB 全英文标题对照 Bangumi 全中文标题时，相似度不足必须返回空覆写表。
      final englishOnlyTmdb = [
        for (var i = 1; i <= 11; i++)
          TmdbEpisodeDetail(
            seasonNumber: 2,
            episodeNumber: i,
            title: 'English Episode Title Number $i',
          ),
      ];
      final guardPlan = EpisodeRemapper.buildPlan(
        folder: fumoffuFolder,
        tmdbSeasons: tmdbSeasons,
        matchedSeason: 2,
        tmdbEpisodes: englishOnlyTmdb,
        bangumiEpisodes: bgmEpisodes,
      );
      expect(guardPlan.metadataOverrides, isEmpty);
    });
  });
}
