import 'dart:io';
import 'dart:typed_data';

import 'package:engine_scraping/engine_scraping.dart' hide TitleNormalizer;
import 'package:engine_scraping/src/scraping/title_normalizer.dart';
import 'package:konata_contracts/konata_contracts.dart' show AssetDataLoaderPort, TmdbNetworkConfig;
import 'package:test/test.dart';

final class _BundledMappingAsset implements AssetDataLoaderPort {
  @override
  Future<Uint8List> loadBytes(String assetPath) {
    expect(assetPath, TmdbNetworkConfig.bundledMappingAssetPath);
    return File('../../../apps/konata/$assetPath').readAsBytes();
  }
}

/// 在线准确率评测（真实媒体库 + TMDB/Bangumi 实时数据）暴露的联合决策缺陷回归。
void main() {
  GroupedWorkFolder folder(
    String title, {
    int? year,
    List<int> eps = const [],
  }) {
    final name = '$title${year == null ? '' : ' ($year)'}';
    final files = eps.isEmpty
        ? ['$title.mkv']
        : [for (final e in eps) '$title - ${'$e'.padLeft(2, '0')}.mkv'];
    return GroupedWorkFolder(
      folderRelativePath: '动画/$name',
      folderName: name,
      cleanTitle: title,
      year: year,
      mainEpisodeNumbers: eps,
      variants: [
        for (final f in files)
          MediaVariant(
            id: f,
            workId: 'w',
            sourceId: 's',
            relativePath: '动画/$name/$f',
            fileName: f,
            fileSize: 1,
          ),
      ],
    );
  }

  test('同名空壳条目（无首播日期、无类型）不得与正主打平而丢弃 TMDB 绑定', () {
    const stub = TmdbWorkDetail(
      tmdbId: 312757,
      mediaType: TmdbMediaType.tv,
      title: '美妙天堂',
      originalTitle: '美妙天堂',
      seasons: [
        TmdbSeasonSummary(seasonNumber: 1, name: '第 1 季', episodeCount: 1),
      ],
    );
    const real = TmdbWorkDetail(
      tmdbId: 67627,
      mediaType: TmdbMediaType.tv,
      title: '美妙天堂',
      originalTitle: 'プリパラ',
      year: 2014,
      genreIds: [16, 35],
      seasons: [
        TmdbSeasonSummary(
          seasonNumber: 1,
          name: '第 1 季',
          episodeCount: 140,
          airDate: '2014-07-05',
        ),
      ],
    );
    const bgm = BangumiSubjectCandidate(
      id: 100449,
      name: 'プリパラ',
      nameCn: '美妙天堂',
      year: 2014,
      totalEpisodes: 38,
      platform: 'TV',
    );
    final decision = ScrapeDomainAdapter.evaluateMatch(
      folder('美妙天堂', year: 2014, eps: [for (var i = 1; i <= 38; i++) i]),
      const [stub, real],
      bangumiCandidates: const [bgm],
    );
    expect(decision.level, MatchLevel.autoBind);
    expect(decision.best?.detail.tmdbId, 67627);
    final stubScore = decision.topCandidates
        .firstWhere((c) => c.detail.tmdbId == 312757)
        .reasons;
    expect(stubScore, contains('stub_entry'));
  });

  test('Bangumi 高置信且名称完全一致时，分差过小的 TMDB 候选仍按 Bangumi 锚定绑定', () {
    const special = TmdbWorkDetail(
      tmdbId: 972231,
      mediaType: TmdbMediaType.movie,
      title: 'D4DJ: Double Mix',
      originalTitle: 'D4DJ: Double Mix',
      year: 2022,
      genreIds: [16, 10402],
    );
    const series = TmdbWorkDetail(
      tmdbId: 102655,
      mediaType: TmdbMediaType.tv,
      title: 'D4DJ',
      originalTitle: 'D4DJ',
      year: 2020,
      genreIds: [35, 16],
      seasons: [
        TmdbSeasonSummary(
          seasonNumber: 0,
          name: '特别篇',
          episodeCount: 1,
          airDate: '2022-08-19',
        ),
        TmdbSeasonSummary(
          seasonNumber: 1,
          name: '第 1 季',
          episodeCount: 13,
          airDate: '2020-10-30',
        ),
      ],
    );
    const bgm = BangumiSubjectCandidate(
      id: 374228,
      name: 'D4DJ Double Mix',
      nameCn: 'D4DJ Double Mix',
      year: 2022,
      totalEpisodes: 1,
      platform: 'TV',
    );
    final decision = ScrapeDomainAdapter.evaluateMatch(
      folder('D4DJ Double Mix', year: 2022),
      const [special, series],
      bangumiCandidates: const [bgm],
    );
    expect(decision.level, MatchLevel.autoBind);
    expect(decision.best?.detail.tmdbId, 972231);
  });

  test('TMDB 漏标动画类型的小型条目在名称与年份均与 Bangumi 一致时不被跨源校验丢弃', () {
    const shorts = TmdbWorkDetail(
      tmdbId: 1052374,
      mediaType: TmdbMediaType.movie,
      title: '从漫画了解！Fate Grand Order',
      originalTitle: 'マンガで分かる！Fate/Grand Order',
      year: 2018,
      genreIds: [12, 35],
    );
    const bgm = BangumiSubjectCandidate(
      id: 254880,
      name: 'マンガで分かる！Fate/Grand Order',
      nameCn: '从漫画了解！Fate/Grand Order',
      year: 2018,
      totalEpisodes: 12,
      platform: 'WEB',
    );
    final decision = ScrapeDomainAdapter.evaluateMatch(
      folder('从漫画了解！Fate Grand Order', year: 2018),
      const [shorts],
      bangumiCandidates: const [bgm],
    );
    expect(decision.level, MatchLevel.autoBind);
    expect(decision.best?.detail.tmdbId, 1052374);
  });

  test('内置映射表可查询并按 Bangumi 放送平台排序可用候选键', () async {
    await BangumiTmdbIndex.loadBundled(_BundledMappingAsset());
    // 《攻壳机动队》(1995) 剧场版：Bangumi 237 ↔ TMDB 电影 9323。
    expect(
      BangumiTmdbIndex.resolveTargets(237).map((target) => (type: target.type, id: target.id)),
      contains((type: TmdbMediaType.movie, id: 9323)),
    );
    expect(BangumiTmdbIndex.resolveTargets(-1), isEmpty);
    const movieSubject = BangumiSubjectCandidate(
      id: 237,
      name: 'GHOST IN THE SHELL / 攻殻機動隊',
      platform: '剧场版',
    );
    expect(
      ScrapeDomainAdapter.bangumiMappedTmdbKeys(movieSubject, {
        'movie:9323',
        'tv:1095',
      }),
      ['movie:9323'],
    );
    expect(
      ScrapeDomainAdapter.bangumiMappedTmdbKeys(movieSubject, {'tv:1095'}),
      isEmpty,
    );
  });

  test('Bangumi 命中续季条目而 TMDB 仅有合并多季的母剧时，绑定母剧而非只留 Bangumi', () {
    const parent = TmdbWorkDetail(
      tmdbId: 93653,
      mediaType: TmdbMediaType.tv,
      title: '虚构推理',
      originalTitle: '虚構推理',
      year: 2020,
      genreIds: [16, 9648],
      voteCount: 120,
      seasons: [
        TmdbSeasonSummary(
          seasonNumber: 1,
          name: '第 1 季',
          episodeCount: 12,
          airDate: '2020-01-12',
        ),
        TmdbSeasonSummary(
          seasonNumber: 2,
          name: '第 2 季',
          episodeCount: 12,
          airDate: '2023-01-08',
        ),
      ],
    );
    const unrelated = TmdbWorkDetail(
      tmdbId: 271594,
      mediaType: TmdbMediaType.tv,
      title: '土豆逗严肃科普 第二季',
      year: 2023,
      genreIds: [16],
      voteCount: 3,
    );
    const bgm = BangumiSubjectCandidate(
      id: 359223,
      name: '虚構推理 Season2',
      nameCn: '虚构推理 第二季',
      year: 2023,
      totalEpisodes: 12,
      platform: 'TV',
    );
    final decision = ScrapeDomainAdapter.evaluateMatch(
      folder('虚构推理 第二季', year: 2023, eps: [for (var i = 1; i <= 12; i++) i]),
      const [parent, unrelated],
      bangumiCandidates: const [bgm],
    );
    expect(decision.level, MatchLevel.autoBind);
    expect(decision.best?.detail.tmdbId, 93653);
  });

  test('同名锚定候选分差过小时，取唯一有评分人数的正主而非零评分重复条目', () {
    const real = TmdbWorkDetail(
      tmdbId: 42836,
      mediaType: TmdbMediaType.tv,
      title: '苍穹之法芙娜',
      originalTitle: '蒼穹のファフナー Dead Aggressor',
      year: 2004,
      genreIds: [16, 18],
      voteCount: 16,
      seasons: [
        TmdbSeasonSummary(
          seasonNumber: 1,
          name: '第 1 季',
          episodeCount: 25,
          airDate: '2004-07-05',
        ),
      ],
    );
    const duplicate = TmdbWorkDetail(
      tmdbId: 325361,
      mediaType: TmdbMediaType.tv,
      title: '蒼穹のファフナー',
      originalTitle: '蒼穹のファフナー',
      year: 2004,
      genreIds: [16],
      voteCount: 0,
      seasons: [
        TmdbSeasonSummary(
          seasonNumber: 1,
          name: '第 1 季',
          episodeCount: 25,
          airDate: '2004-07-04',
        ),
      ],
    );
    const bgm = BangumiSubjectCandidate(
      id: 2936,
      name: '蒼穹のファフナー',
      nameCn: '苍穹之法芙娜',
      year: 2004,
      totalEpisodes: 26,
      platform: 'TV',
    );
    final decision = ScrapeDomainAdapter.evaluateMatch(
      folder('苍穹之法芙娜', year: 2004, eps: [for (var i = 1; i <= 25; i++) i]),
      const [real, duplicate],
      bangumiCandidates: const [bgm],
    );
    expect(decision.level, MatchLevel.autoBind);
    expect(decision.best?.detail.tmdbId, 42836);
  });

  group('冷门重复条目识别', () {
    TmdbWorkDetail tv(
      int id,
      String title,
      String original,
      int votes, {
      List<String> aliases = const [],
    }) => TmdbWorkDetail(
      tmdbId: id,
      mediaType: TmdbMediaType.tv,
      title: title,
      originalTitle: original,
      year: 2023,
      genreIds: const [16],
      voteCount: votes,
      aliases: aliases,
      seasons: const [
        TmdbSeasonSummary(
          seasonNumber: 1,
          name: '第 1 季',
          episodeCount: 20,
          airDate: '2023-01-14',
        ),
      ],
    );

    List<String> reasonsOf(MatchDecision d, int id) =>
        d.topCandidates.firstWhere((c) => c.detail.tmdbId == id).reasons;

    test('正式标题与原名相同、几乎无人评分的新建条目降权，让位给正主', () {
      final decision = ScrapeDomainAdapter.evaluateMatch(
        folder('狩火之王', year: 2023, eps: [for (var i = 1; i <= 20; i++) i]),
        [tv(312644, '狩火之王', '火狩りの王', 0), tv(156688, '狩火之王', '火狩りの王', 20)],
      );
      expect(reasonsOf(decision, 312644), contains('unpopular_duplicate'));
      expect(
        reasonsOf(decision, 156688),
        isNot(contains('unpopular_duplicate')),
      );
      expect(decision.topCandidates.first.detail.tmdbId, 156688);
    });

    test('仅别名含系列总称的同系列续作不视为重复条目', () {
      final decision = ScrapeDomainAdapter.evaluateMatch(
        folder('宇宙战舰大和号2202 爱的战士们', year: 2023),
        [
          tv(
            304669,
            '宇宙战舰大和号2202 爱的战士们',
            '宇宙戦艦ヤマト2202 愛の戦士たち',
            1,
            aliases: const ['宇宙戦艦ヤマト'],
          ),
          tv(
            45844,
            '宇宙战舰大和号2199',
            '宇宙戦艦ヤマト2199',
            200,
            aliases: const ['宇宙戦艦ヤマト'],
          ),
        ],
      );
      expect(
        reasonsOf(decision, 304669),
        isNot(contains('unpopular_duplicate')),
      );
    });
  });

  group('第二轮刮削决策与排序回归', () {
    test('季度名前后附带「第 N 季」装饰词时仍精确命中目标续季', () {
      const gundamSeed = TmdbWorkDetail(
        tmdbId: 20111,
        mediaType: TmdbMediaType.tv,
        title: '机动战士高达SEED',
        originalTitle: '機動戦士ガンダムSEED',
        year: 2002,
        voteCount: 65,
        genreIds: [16, 10759],
        seasons: [
          TmdbSeasonSummary(
            seasonNumber: 1,
            name: '机动战士高达SEED 第 1 季',
            episodeCount: 50,
            airDate: '2002-10-05',
          ),
          TmdbSeasonSummary(
            seasonNumber: 2,
            name: '机动战士高达SEED DESTINY 第 2 季',
            episodeCount: 50,
            airDate: '2004-10-09',
          ),
        ],
      );
      const bgmDestiny = BangumiSubjectCandidate(
        id: 54277,
        name: '機動戦士ガンダムSEED DESTINY HDリマスター',
        nameCn: '机动战士高达SEED DESTINY HD重制版',
        year: 2013,
        totalEpisodes: 50,
        platform: 'TV',
      );
      final seedDecision = ScrapeDomainAdapter.evaluateMatch(
        folder(
          '机动战士高达SEED DESTINY HD重制版',
          eps: [for (var i = 1; i <= 50; i++) i],
        ),
        const [gundamSeed],
        bangumiCandidates: const [bgmDestiny],
      );
      expect(seedDecision.level, MatchLevel.autoBind);
      expect(seedDecision.best?.detail.tmdbId, 20111);
      expect(seedDecision.matchedSeason, 2);

      const shugogetten = TmdbWorkDetail(
        tmdbId: 24019,
        mediaType: TmdbMediaType.tv,
        title: '守护月天',
        originalTitle: 'まもって守護月天!',
        year: 1998,
        voteCount: 5,
        genreIds: [16],
        seasons: [
          TmdbSeasonSummary(
            seasonNumber: 1,
            name: '第 1 季  守护月天！',
            episodeCount: 22,
            airDate: '1998-10-17',
          ),
          TmdbSeasonSummary(
            seasonNumber: 2,
            name: '第 2 季  传心 守护月天！',
            episodeCount: 8,
            airDate: '2000-06-23',
          ),
        ],
      );
      final shugoDecision = ScrapeDomainAdapter.evaluateMatch(
        folder('传心 守护月天！', eps: [for (var i = 1; i <= 8; i++) i]),
        const [shugogetten],
      );
      expect(shugoDecision.level, MatchLevel.autoBind);
      expect(shugoDecision.best?.detail.tmdbId, 24019);
      expect(shugoDecision.matchedSeason, 2);
    });

    test('无高置信 Bangumi 时显式 OVA/OAD 目录自动路由母剧第 0 季并容忍跨年发售', () {
      const hakuouki = TmdbWorkDetail(
        tmdbId: 44318,
        mediaType: TmdbMediaType.tv,
        title: '薄樱鬼',
        originalTitle: '薄桜鬼',
        year: 2010,
        voteCount: 34,
        genreIds: [16, 18],
        seasons: [
          TmdbSeasonSummary(
            seasonNumber: 0,
            name: '特别篇',
            episodeCount: 12,
            airDate: '2010-10-03',
          ),
          TmdbSeasonSummary(
            seasonNumber: 1,
            name: '薄樱鬼',
            episodeCount: 12,
            airDate: '2010-04-03',
          ),
        ],
      );
      const hakuoukiSpin = TmdbWorkDetail(
        tmdbId: 77158,
        mediaType: TmdbMediaType.tv,
        title: '薄樱鬼：御伽草子',
        originalTitle: '薄桜鬼～御伽草子～',
        year: 2016,
        voteCount: 6,
        genreIds: [16, 35],
        seasons: [
          TmdbSeasonSummary(
            seasonNumber: 1,
            name: '第 1 季',
            episodeCount: 12,
            airDate: '2016-04-05',
          ),
        ],
      );
      final ovaFolder = ScrapeDomainAdapter.groupAndSplitFiles(
        sourceId: 's',
        files: [
          for (var i = 1; i <= 3; i++)
            ScannedFileInput(
              relativePath:
                  '动画/薄樱鬼 OVA (2021)/[AI-Raws] 薄桜鬼 OVA #0$i (BD HEVC).mkv',
              fileName: '[AI-Raws] 薄桜鬼 OVA #0$i (BD HEVC).mkv',
              fileSize: 900 * 1024 * 1024,
              assetKind: AssetKind.video,
            ),
        ],
      ).single;
      final ovaDecision = ScrapeDomainAdapter.evaluateMatch(ovaFolder, const [
        hakuouki,
        hakuoukiSpin,
      ]);
      expect(ovaDecision.level, MatchLevel.autoBind);
      expect(ovaDecision.best?.detail.tmdbId, 44318);
      expect(ovaDecision.matchedSeason, 0);

      const yowamushiTv = TmdbWorkDetail(
        tmdbId: 61441,
        mediaType: TmdbMediaType.tv,
        title: '飙速宅男',
        originalTitle: '弱虫ペダル',
        year: 2013,
        voteCount: 57,
        genreIds: [16, 35],
        seasons: [
          TmdbSeasonSummary(
            seasonNumber: 0,
            name: '特别篇',
            episodeCount: 8,
            airDate: '2013-08-08',
          ),
          TmdbSeasonSummary(
            seasonNumber: 1,
            name: '飙速宅男',
            episodeCount: 38,
            airDate: '2013-10-07',
          ),
        ],
      );
      const yowamushiMovie = TmdbWorkDetail(
        tmdbId: 292740,
        mediaType: TmdbMediaType.movie,
        title: '飙速宅男 Re:RIDE',
        originalTitle: '弱虫ペダル Re:RIDE',
        year: 2014,
        voteCount: 12,
        genreIds: [16],
      );
      final oadFolder = ScrapeDomainAdapter.groupAndSplitFiles(
        sourceId: 's',
        files: const [
          ScannedFileInput(
            relativePath: '动画/飙速宅男 OAD (2013)/[Group] Yowamushi Pedal SPECIAL RIDE OAD.mkv',
            fileName: '[Group] Yowamushi Pedal SPECIAL RIDE OAD.mkv',
            fileSize: 900 * 1024 * 1024,
            assetKind: AssetKind.video,
          ),
        ],
      ).single;
      final oadDecision = ScrapeDomainAdapter.evaluateMatch(oadFolder, const [
        yowamushiTv,
        yowamushiMovie,
      ]);
      expect(oadDecision.level, MatchLevel.autoBind);
      expect(oadDecision.best?.detail.tmdbId, 61441);
      expect(oadDecision.matchedSeason, 0);
    });

    test('中置信错误 Bangumi 不得借用错误年份误杀精确标题匹配的 TMDB 剧集', () {
      const highCollar = TmdbWorkDetail(
        tmdbId: 289562,
        mediaType: TmdbMediaType.tv,
        title: '美男高校地球防卫部High collar！',
        originalTitle: '美男高校地球防衛部ハイカラ！',
        year: 2025,
        voteCount: 3,
        genreIds: [16, 35],
        seasons: [
          TmdbSeasonSummary(
            seasonNumber: 1,
            name: '第 1 季',
            episodeCount: 12,
            airDate: '2025-07-07',
          ),
        ],
      );
      const oldLove = TmdbWorkDetail(
        tmdbId: 61930,
        mediaType: TmdbMediaType.tv,
        title: '美男高校地球防卫部 LOVE！',
        originalTitle: '美男高校地球防衛部',
        year: 2015,
        voteCount: 9,
        genreIds: [16, 35],
        seasons: [
          TmdbSeasonSummary(
            seasonNumber: 1,
            name: '第 1 季',
            episodeCount: 12,
            airDate: '2015-01-07',
          ),
          TmdbSeasonSummary(
            seasonNumber: 3,
            name: '第 3 季',
            episodeCount: 12,
            airDate: '2018-04-09',
          ),
        ],
      );
      const wrongMediumBgm = BangumiSubjectCandidate(
        id: 234378,
        name: '美男高校地球防衛部HAPPY KISS！',
        nameCn: '美男高校地球防卫部 HAPPY KISS！',
        year: 2018,
        totalEpisodes: 12,
        platform: 'TV',
      );
      final decision = ScrapeDomainAdapter.evaluateMatch(
        folder('美男高校地球防卫部High collar！', eps: [for (var i = 1; i <= 12; i++) i]),
        const [oldLove, highCollar],
        bangumiCandidates: const [wrongMediumBgm],
      );
      expect(decision.level, MatchLevel.autoBind);
      expect(decision.best?.detail.tmdbId, 289562);
      expect(decision.matchedSeason, 1);
    });

    test('空分类零评分冷门电影不得误绑高置信 Bangumi 动画短片', () {
      const unrelatedZeroVote = TmdbWorkDetail(
        tmdbId: 776246,
        mediaType: TmdbMediaType.movie,
        title: 'Shelter for the Bloodstained Soul',
        originalTitle: 'Shelter for the Bloodstained Soul',
        year: 2016,
        voteCount: 0,
        genreIds: [],
      );
      const bgmShelter = BangumiSubjectCandidate(
        id: 195249,
        name: 'SHELTER',
        nameCn: '避难所',
        year: 2016,
        totalEpisodes: 1,
        platform: '其他',
      );
      final decision = ScrapeDomainAdapter.evaluateMatch(
        folder('避难所'),
        const [unrelatedZeroVote],
        bangumiCandidates: const [bgmShelter],
      );
      expect(decision.best, isNull);
      expect(decision.bestBangumi?.subject.id, 195249);
    });

    test('声优演唱会 Live 豁免音乐分类非动画扣分并自动绑定', () {
      const liveMovie = TmdbWorkDetail(
        tmdbId: 992325,
        mediaType: TmdbMediaType.movie,
        title: 'Rhodanthe* Special Live 2014 ハロー * コンニチハ !!',
        originalTitle: 'Rhodanthe* Special Live 2014 ハロー * コンニチハ !!',
        aliases: ['Rhodanthe* Special Live 2014 HELLO*KONNICHIWA!!'],
        year: 2014,
        voteCount: 0,
        genreIds: [10402],
      );
      final liveFolder = ScrapeDomainAdapter.groupAndSplitFiles(
        sourceId: 's',
        files: const [
          ScannedFileInput(
            relativePath: '动画/Rhodanthe Special Live 2014 HELLO KONNICHIWA (2014)/[VCB-Studio] Rhodanthe Special Live 2014 HELLO KONNICHIWA.mkv',
            fileName:
                '[VCB-Studio] Rhodanthe Special Live 2014 HELLO KONNICHIWA.mkv',
            fileSize: 12000 * 1024 * 1024,
            assetKind: AssetKind.video,
          ),
        ],
      ).single;
      final decision = ScrapeDomainAdapter.evaluateMatch(liveFolder, const [
        liveMovie,
      ]);
      expect(decision.level, MatchLevel.autoBind);
      expect(decision.best?.detail.tmdbId, 992325);
    });

    test('显式剧场版目录不再给 TV 特别篇加分，电影篇章插词与精确英文文件名自动定型', () {
      const planetMovie = TmdbWorkDetail(
        tmdbId: 969044,
        mediaType: TmdbMediaType.movie,
        title: '偶像活动Planet 剧场版',
        originalTitle: '劇場版アイカツプラネット！',
        year: 2022,
        voteCount: 2,
        genreIds: [16, 10402],
      );
      const planetTv = TmdbWorkDetail(
        tmdbId: 107315,
        mediaType: TmdbMediaType.tv,
        title: '偶像活动Planet！',
        originalTitle: 'アイカツプラネット！',
        year: 2021,
        voteCount: 6,
        genreIds: [16, 35],
        seasons: [
          TmdbSeasonSummary(seasonNumber: 0, name: '特别篇', episodeCount: 1),
          TmdbSeasonSummary(seasonNumber: 1, name: '第 1 季', episodeCount: 25),
        ],
      );
      final planetFolder = ScrapeDomainAdapter.groupAndSplitFiles(
        sourceId: 's',
        files: const [
          ScannedFileInput(
            relativePath:
                '动画/偶像活动Planet！剧场版/[Group][Aikatsu_Planet!][BD_Movie].mkv',
            fileName: '[Group][Aikatsu_Planet!][BD_Movie].mkv',
            fileSize: 4000 * 1024 * 1024,
            assetKind: AssetKind.video,
          ),
        ],
      ).single;
      final planetDecision = ScrapeDomainAdapter.evaluateMatch(
        planetFolder,
        const [planetMovie, planetTv],
      );
      expect(planetDecision.level, MatchLevel.autoBind);
      expect(planetDecision.best?.detail.tmdbId, 969044);

      const peacemakerMovie = TmdbWorkDetail(
        tmdbId: 483456,
        mediaType: TmdbMediaType.movie,
        title: '新撰组异闻录 铁 前篇 想道',
        originalTitle: 'PEACE MAKER 鐵 前篇 想道~オモウミチ~',
        year: 2018,
        voteCount: 5,
        genreIds: [16, 28],
      );
      final peaceDecision = ScrapeDomainAdapter.evaluateMatch(
        folder('新撰组异闻录 铁 ～想道～'),
        const [peacemakerMovie],
      );
      expect(peaceDecision.level, MatchLevel.autoBind);
      expect(peaceDecision.best?.detail.tmdbId, 483456);

      const akitoTv = TmdbWorkDetail(
        tmdbId: 313304,
        mediaType: TmdbMediaType.tv,
        title: 'Code Geass: Akito the Exiled',
        originalTitle: 'Code Geass: Akito the Exiled',
        year: 2012,
        voteCount: 3,
        genreIds: [16, 10765],
        seasons: [
          TmdbSeasonSummary(seasonNumber: 1, name: '第 1 季', episodeCount: 5),
        ],
      );
      const lelouchTv = TmdbWorkDetail(
        tmdbId: 31724,
        mediaType: TmdbMediaType.tv,
        title: '反叛的鲁路修',
        originalTitle: 'コードギアス 反逆のルルーシュ',
        aliases: ['Code Geass: Lelouch of the Rebellion'],
        year: 2006,
        voteCount: 900,
        genreIds: [16, 10765],
        seasons: [
          TmdbSeasonSummary(seasonNumber: 1, name: '第 1 季', episodeCount: 25),
        ],
      );
      final akitoFolder = ScrapeDomainAdapter.groupAndSplitFiles(
        sourceId: 's',
        files: [
          for (var i = 1; i <= 5; i++)
            ScannedFileInput(
              relativePath:
                  '动画/Code Geass 亡国的阿基德/[VCB-S][Code Geass Akito The Exiled][0$i][1080p].mkv',
              fileName: '[VCB-S][Code Geass Akito The Exiled][0$i][1080p].mkv',
              fileSize: 1000 * 1024 * 1024,
              assetKind: AssetKind.video,
            ),
        ],
      ).single;
      final akitoDecision = ScrapeDomainAdapter.evaluateMatch(
        akitoFolder,
        const [akitoTv, lelouchTv],
      );
      expect(akitoDecision.level, MatchLevel.autoBind);
      expect(akitoDecision.best?.detail.tmdbId, 313304);
      expect(akitoDecision.matchedSeason, 1);
    });

    test('ScrapeMatchResolver：剧场版映射指向 TV 时不短路快通道，继续召回独立 Movie', () async {
      const bgmMovie = BangumiSubjectCandidate(
        id: 11044,
        name: '劇場版 ブレイクブレイド 第五章「死線ノ涯」',
        nameCn: '破刃之剑 第五章 死线之涯',
        year: 2010,
        totalEpisodes: 1,
        platform: '剧场版',
      );
      const tvRemake = TmdbWorkDetail(
        tmdbId: 44163,
        mediaType: TmdbMediaType.tv,
        title: '破刃之剑',
        originalTitle: 'ブレイクブレイド',
        year: 2014,
        voteCount: 40,
        genreIds: [16, 10765],
        seasons: [
          TmdbSeasonSummary(seasonNumber: 0, name: '特别篇', episodeCount: 6),
          TmdbSeasonSummary(seasonNumber: 1, name: '第 1 季', episodeCount: 12),
        ],
      );
      const movieCh5 = TmdbWorkDetail(
        tmdbId: 55437,
        mediaType: TmdbMediaType.movie,
        title: '破刃之剑 第五章 死线之涯',
        originalTitle: '劇場版 ブレイクブレイド 第五章「死線ノ涯」',
        year: 2010,
        voteCount: 25,
        genreIds: [16, 28],
      );
      final fakeFetcher = _FakeMatchFetcher(
        bgmResults: const [bgmMovie],
        byIdResults: const [tvRemake],
        searchResults: const [movieCh5, tvRemake],
      );
      final resolver = ScrapeMatchResolver(
        fetcher: fakeFetcher,
        mappingIndex: BangumiTmdbIndex.fromBytes(
          BangumiTmdbIndex.encode(const [
            BangumiTmdbRecord(
              bangumiId: 11044,
              type: TmdbMediaType.tv,
              tmdbId: 44163,
              season: 0,
              flags: BangumiTmdbTarget.flagOpenAni,
            ),
          ], snapshotDateYyyymmdd: 20261121),
        ),
      );
      const movieFolder = GroupedWorkFolder(
        folderRelativePath: '动画/破刃之剑 第五章 死线之涯 (2010)',
        folderName: '破刃之剑 第五章 死线之涯 (2010)',
        cleanTitle: '破刃之剑 第五章 死线之涯',
        year: 2010,
        isMovieHint: true,
        variants: [
          MediaVariant(
            id: 'm1',
            workId: 'w',
            sourceId: 's',
            relativePath: '动画/破刃之剑 第五章 死线之涯 (2010)/劇場版 ブレイクブレイド 第五章.mkv',
            fileName: '劇場版 ブレイクブレイド 第五章.mkv',
            fileSize: 4000,
          ),
        ],
      );
      final res = await resolver.resolve(movieFolder);
      expect(fakeFetcher.fullSearchCalled, isTrue);
      expect(res.decision.level, MatchLevel.autoBind);
      expect(res.decision.best?.detail.mediaType, TmdbMediaType.movie);
      expect(res.decision.best?.detail.tmdbId, 55437);
    });

    test('ScrapeMatchResolver：父目录上下文瞬时网络异常不毒化主作品 TMDB 检索', () async {
      const bgm = BangumiSubjectCandidate(
        id: 56093,
        name: 'ダンガンロンパ 希望の学園と絶望の高校生 The Animation',
        nameCn: '弹丸论破 希望学园与绝望高中生',
        year: 2013,
        totalEpisodes: 13,
        platform: 'TV',
      );
      const tmdbTv = TmdbWorkDetail(
        tmdbId: 49471,
        mediaType: TmdbMediaType.tv,
        title: '弹丸论破 希望学园与绝望高中生',
        originalTitle: 'ダンガンロンパ 希望の学園と絶望の高校生 The Animation',
        year: 2013,
        voteCount: 500,
        genreIds: [16, 9648],
        seasons: [
          TmdbSeasonSummary(seasonNumber: 1, name: '第 1 季', episodeCount: 13),
        ],
      );
      final fakeFetcher = _FakeMatchFetcher(
        bgmResults: const [bgm],
        byIdResults: const [],
        searchResults: const [tmdbTv],
        parentContextFailsTransient: true,
      );
      final resolver = ScrapeMatchResolver(fetcher: fakeFetcher);
      final res = await resolver.resolve(
        folder('弹丸论破 希望学园与绝望高中生', eps: [for (var i = 1; i <= 13; i++) i]),
      );
      expect(fakeFetcher.fullSearchCalled, isTrue);
      expect(res.networkError, isNull);
      expect(res.decision.level, MatchLevel.autoBind);
      expect(res.decision.best?.detail.tmdbId, 49471);
    });

    test('雪月花三部曲拆簇保留干净卷名，单字卷名互斥使三卷分别直绑对应 Movie', () {
      const folderPath = '动画/刀剑乱舞-花丸-合集/特『刀剑乱舞-花丸-』～雪月花～ (2022)';
      final clusters = MultiWorkSplitter.split(folderPath, const [
        {
          'id': '1',
          'relative_path': '$folderPath/[AI-Raws] 特・刀剣乱舞-花丸- #1～雪の巻～.mkv',
          'name': '[AI-Raws] 特・刀剣乱舞-花丸- #1～雪の巻～.mkv',
          'size': 3500 * 1024 * 1024,
        },
        {
          'id': '2',
          'relative_path': '$folderPath/[AI-Raws] 特・刀剣乱舞-花丸- #2～月の巻～.mkv',
          'name': '[AI-Raws] 特・刀剣乱舞-花丸- #2～月の巻～.mkv',
          'size': 3500 * 1024 * 1024,
        },
        {
          'id': '3',
          'relative_path': '$folderPath/[AI-Raws] 特・刀剣乱舞-花丸- #3～華の巻～.mkv',
          'name': '[AI-Raws] 特・刀剣乱舞-花丸- #3～華の巻～.mkv',
          'size': 3500 * 1024 * 1024,
        },
      ]);
      expect(clusters, hasLength(3));
      expect(clusters[0].inventory.title, '特・刀剣乱舞-花丸- 雪の巻');
      expect(clusters[1].inventory.title, '特・刀剣乱舞-花丸- 月の巻');
      expect(clusters[2].inventory.title, '特・刀剣乱舞-花丸- 華の巻');

      const candidates = [
        TmdbWorkDetail(
          tmdbId: 978039,
          mediaType: TmdbMediaType.movie,
          title: '特『刀剑乱舞-花丸-』～雪月花～雪之卷',
          originalTitle: '特『刀剣乱舞-花丸-』～雪ノ巻～',
          year: 2022,
          voteCount: 3,
          genreIds: [16],
        ),
        TmdbWorkDetail(
          tmdbId: 1081640,
          mediaType: TmdbMediaType.movie,
          title: '特『刀剑乱舞-花丸-』～雪月花～月之卷',
          originalTitle: '特『刀剣乱舞-花丸-』～月ノ巻～',
          year: 2022,
          voteCount: 5,
          genreIds: [16],
        ),
        TmdbWorkDetail(
          tmdbId: 1081641,
          mediaType: TmdbMediaType.movie,
          title: '特『刀剑乱舞-花丸-』～雪月花～花之卷',
          originalTitle: '特『刀剣乱舞-花丸-』～華ノ巻～',
          year: 2022,
          voteCount: 3,
          genreIds: [16],
        ),
      ];
      final expectedIds = [978039, 1081640, 1081641];
      for (var i = 0; i < 3; i++) {
        final c = clusters[i];
        final decision = ScrapeDomainAdapter.evaluateMatch(
          GroupedWorkFolder(
            folderRelativePath: '$folderPath::${c.slug}',
            folderName: c.inventory.title,
            cleanTitle: c.inventory.title,
            isMovieHint: true,
            isSplitCluster: true,
            inventory: c.inventory,
            titleHints: c.inventory.titleHints,
            fileHints: c.inventory.fileHints,
            variants: const [],
          ),
          candidates,
        );
        expect(decision.level, MatchLevel.autoBind);
        expect(decision.best?.detail.tmdbId, expectedIds[i]);
      }
    });

    test('高达 SEED 合集拆簇不伪造 season=1、准确命中 S2 且 C.E. 73 Stargazer 不截断', () {
      const root = '动画/机动战士高达SEED HD重制版 & 机动战士高达SEED DESTINY HD重制版';
      final clusters = MultiWorkSplitter.split(root, [
        for (var i = 1; i <= 50; i++)
          {
            'id': 's$i',
            'relative_path':
                '$root/Mobile Suit Gundam SEED - HD Remaster 2011 EP${'$i'.padLeft(2, '0')} [BD 1920x1080].mkv',
            'name':
                'Mobile Suit Gundam SEED - HD Remaster 2011 EP${'$i'.padLeft(2, '0')} [BD 1920x1080].mkv',
            'size': 800 * 1024 * 1024,
          },
        for (var i = 1; i <= 50; i++)
          {
            'id': 'd$i',
            'relative_path':
                '$root/Mobile Suit Gundam SEED Destiny - HD Remaster 2013 EP${'$i'.padLeft(2, '0')} [BD 1920x1080].mkv',
            'name':
                'Mobile Suit Gundam SEED Destiny - HD Remaster 2013 EP${'$i'.padLeft(2, '0')} [BD 1920x1080].mkv',
            'size': 800 * 1024 * 1024,
          },
        {
          'id': 'astray',
          'relative_path':
              '$root/Mobile Suit Gundam SEED OVA ASTRAY BLUE FRAME 2006 [BD 1920x1080 23.976fps AVC-yuv420p10 FLAC] - yan04000985.mkv',
          'name': 'Mobile Suit Gundam SEED OVA ASTRAY BLUE FRAME 2006 [BD 1920x1080 23.976fps AVC-yuv420p10 FLAC] - yan04000985.mkv',
          'size': 400 * 1024 * 1024,
        },
        {
          'id': 'sg',
          'relative_path':
              '$root/Mobile Suit Gundam SEED OVA C.E. 73 Stargazer 2006 EP01-03 [BD 1920x1080 23.976fps AVC-yuv420p10 FLAC] - yan04000985.mkv',
          'name': 'Mobile Suit Gundam SEED OVA C.E. 73 Stargazer 2006 EP01-03 [BD 1920x1080 23.976fps AVC-yuv420p10 FLAC] - yan04000985.mkv',
          'size': 1200 * 1024 * 1024,
        },
      ]);
      final destiny = clusters.firstWhere(
        (c) => c.inventory.title.contains('DESTINY'),
      );
      expect(destiny.inventory.main.every((m) => m.season == null), isTrue);

      final astray = clusters.firstWhere(
        (c) => c.inventory.title.contains('ASTRAY BLUE FRAME'),
      );
      expect(
        astray.inventory.title,
        'Mobile Suit Gundam SEED OVA ASTRAY BLUE FRAME',
      );
      expect(astray.inventory.year, 2006);

      final stargazer = clusters.firstWhere(
        (c) => c.inventory.title.contains('Stargazer'),
      );
      expect(
        stargazer.inventory.title,
        'Mobile Suit Gundam SEED OVA C E 73 Stargazer',
      );
      expect(stargazer.inventory.year, 2006);

      final destinyDecision = ScrapeDomainAdapter.evaluateMatch(
        GroupedWorkFolder(
          folderRelativePath: '$root::${destiny.slug}',
          folderName: destiny.inventory.title,
          cleanTitle: destiny.inventory.title,
          isSplitCluster: true,
          inventory: destiny.inventory,
          mainEpisodeNumbers: [for (var i = 1; i <= 50; i++) i],
          titleHints: destiny.inventory.titleHints,
          fileHints: destiny.inventory.fileHints,
          variants: const [],
        ),
        const [
          TmdbWorkDetail(
            tmdbId: 20111,
            mediaType: TmdbMediaType.tv,
            title: '机动战士高达SEED',
            originalTitle: '機動戦士ガンダムSEED',
            year: 2002,
            voteCount: 300,
            genreIds: [16, 10765],
            seasons: [
              TmdbSeasonSummary(
                seasonNumber: 1,
                name: '机动战士高达SEED 第 1 季',
                episodeCount: 50,
                airDate: '2002-10-05',
              ),
              TmdbSeasonSummary(
                seasonNumber: 2,
                name: '机动战士高达SEED DESTINY 第 2 季',
                episodeCount: 50,
                airDate: '2004-10-09',
              ),
            ],
          ),
        ],
        bangumiCandidates: const [
          BangumiSubjectCandidate(
            id: 54277,
            name: '機動戦士ガンダムSEED DESTINY HDリマスター',
            nameCn: '机动战士高达SEED DESTINY HD重制版',
            year: 2013,
            airDate: '2013-04-07',
            totalEpisodes: 50,
            platform: 'TV',
          ),
        ],
      );
      expect(destinyDecision.level, MatchLevel.autoBind);
      expect(destinyDecision.best?.detail.tmdbId, 20111);
      expect(destinyDecision.matchedSeason, 2);
    });

    test('长罗马音共享前缀尾段副标题冲突拦截错绑前作（美男高校 High collar vs LOVE/HAPPY KISS）', () {
      final workFolder = GroupedWorkFolder(
        folderRelativePath: '动画/美男高校地球防卫部High collar！',
        folderName: '美男高校地球防卫部High collar！',
        cleanTitle: '美男高校地球防卫部High collar！',
        mainEpisodeNumbers: [for (var i = 1; i <= 12; i++) i],
        variants: [
          for (var i = 1; i <= 12; i++)
            MediaVariant(
              id: 'hc$i',
              workId: 'w',
              sourceId: 's',
              relativePath:
                  '动画/美男高校地球防卫部High collar！/[LoliHouse] Binan Koukou Chikyuu Bouei-bu Haikara！ - ${'$i'.padLeft(2, '0')}.mkv',
              fileName:
                  '[LoliHouse] Binan Koukou Chikyuu Bouei-bu Haikara！ - ${'$i'.padLeft(2, '0')}.mkv',
              fileSize: 500,
            ),
        ],
      );
      final decision = ScrapeDomainAdapter.evaluateMatch(
        workFolder,
        const [
          TmdbWorkDetail(
            tmdbId: 61930,
            mediaType: TmdbMediaType.tv,
            title: '美男高校地球防卫部 LOVE！',
            originalTitle: '美男高校地球防衛部LOVE！',
            aliases: ['Binan Koukou Chikyuu Bouei-bu LOVE!'],
            year: 2015,
            voteCount: 50,
            genreIds: [16, 35],
            seasons: [
              TmdbSeasonSummary(
                seasonNumber: 1,
                name: '第 1 季',
                episodeCount: 12,
                airDate: '2015-01-07',
              ),
            ],
          ),
          TmdbWorkDetail(
            tmdbId: 289562,
            mediaType: TmdbMediaType.tv,
            title: '美男高校地球防卫部High collar！',
            originalTitle: '美男高校地球防衛部ハイカラ！',
            year: 2025,
            voteCount: 4,
            genreIds: [16, 35],
            seasons: [
              TmdbSeasonSummary(
                seasonNumber: 1,
                name: '第 1 季',
                episodeCount: 12,
                airDate: '2025-07-07',
              ),
            ],
          ),
        ],
        bangumiCandidates: const [
          BangumiSubjectCandidate(
            id: 234378,
            name: '美男高校地球防衛部HAPPY KISS！',
            nameCn: '美男高校地球防卫部 HAPPY KISS！',
            aliases: ['Binan Koukou Chikyuu Bouei-bu Happy Kiss!'],
            year: 2018,
            totalEpisodes: 12,
            platform: 'TV',
          ),
        ],
      );
      expect(decision.level, MatchLevel.autoBind);
      expect(decision.best?.detail.tmdbId, 289562);
      expect(decision.bestBangumi, isNull);
    });

    test('零评分但具动画分类与封面的冷门独立 OAD 经离线映射正常锚定（刃牙道 OAD）', () {
      final index = BangumiTmdbIndex.fromBytes(
        BangumiTmdbIndex.encode(const [
          BangumiTmdbRecord(
            bangumiId: 186404,
            type: TmdbMediaType.movie,
            tmdbId: 1698625,
            season: null,
          ),
        ], snapshotDateYyyymmdd: 20261121),
      );
      final decision = ScrapeDomainAdapter.evaluateMatch(
        folder('刃牙道 OAD', year: 2016),
        const [
          TmdbWorkDetail(
            tmdbId: 1698625,
            mediaType: TmdbMediaType.movie,
            title: 'バキ 最凶死刑囚編SP(スペシャル)アニメ',
            originalTitle: 'バキ 最凶死刑囚編SP(スペシャル)アニメ',
            year: 2016,
            voteCount: 0,
            genreIds: [28, 16],
            posterPath: '/baki-oad.jpg',
          ),
        ],
        bangumiCandidates: const [
          BangumiSubjectCandidate(
            id: 186404,
            name: '刃牙道 OAD',
            nameCn: '刃牙道 OAD',
            year: 2016,
            airDate: '2016-12-06',
            totalEpisodes: 1,
            platform: 'OVA',
          ),
        ],
        mappingIndex: index,
      );
      expect(decision.level, MatchLevel.autoBind);
      expect(decision.best?.detail.mediaType, TmdbMediaType.movie);
      expect(decision.best?.detail.tmdbId, 1698625);
    });

    test('无年份 Bangumi 同名多版本按精确集数升格高置信 + 短篇 OVA 与长篇 TV 分离', () {
      final aikatsu = ScrapeDomainAdapter.evaluateBangumiMatch(
        folder('偶像活动 10th STORY ～通往未来的STARWAY～', eps: const [1, 2, 3]),
        const [
          BangumiSubjectCandidate(
            id: 377962,
            name: 'アイカツ! 10th STORY ～未来へのSTARWAY～',
            nameCn: '偶像活动! 10th STORY ～通往未来的STARWAY～',
            year: 2022,
            totalEpisodes: 1,
            platform: '剧场版',
          ),
          BangumiSubjectCandidate(
            id: 404427,
            name: 'アイカツ! 10th STORY ～未来へのSTARWAY～',
            nameCn: '偶像活动! 10th STORY ～通往未来的STARWAY～',
            year: 2023,
            totalEpisodes: 3,
            platform: '剧场版',
          ),
        ],
      );
      expect(aikatsu.best?.subject.id, 404427);
      expect(aikatsu.rawResult.tier.name, 'high');

      final aquarion = ScrapeDomainAdapter.evaluateBangumiMatch(
        folder('创星的大天使', eps: const [1, 2]),
        const [
          BangumiSubjectCandidate(
            id: 22601,
            name: '創星のアクエリオン',
            nameCn: '创星的大天使',
            year: 2007,
            totalEpisodes: 2,
            platform: 'OVA',
          ),
          BangumiSubjectCandidate(
            id: 1763,
            name: '創聖のアクエリオン',
            nameCn: '创圣的大天使',
            aliases: ['Aquarion'],
            year: 2005,
            totalEpisodes: 26,
            platform: 'TV',
          ),
        ],
      );
      expect(aquarion.best?.subject.id, 22601);
      expect(aquarion.rawResult.tier.name, 'high');
    });

    test('假名罗马音语音匹配显著拉开同系列兄弟特别篇分差（少女福尔摩斯 亚森 vs 派对之夜）', () {
      const arseneLocal =
          'Tantei Opera Milky Holmes - Arsene Karei Naru Yokubou';
      const pearlyLocal =
          'Tantei Opera Milky Holmes Fun Fun Pearly Night - Ken to Janet no Okurimono';
      const arseneJp = '探偵オペラ ミルキィホームズ アルセーヌ 華麗なる欲望';
      const pearlyJp = '探偵オペラ ミルキィホームズ ファンファンパーリーナイト♪ ～ケンとジャネットの贈り物～';

      final arseneRight = TitleNormalizer.romajiKanaSimilarity(
        arseneLocal,
        arseneJp,
      );
      final arseneWrong = TitleNormalizer.romajiKanaSimilarity(
        arseneLocal,
        pearlyJp,
      );
      expect(arseneRight, greaterThanOrEqualTo(0.84));
      expect(arseneRight - arseneWrong, greaterThanOrEqualTo(0.30));

      final pearlyRight = TitleNormalizer.romajiKanaSimilarity(
        pearlyLocal,
        pearlyJp,
      );
      final pearlyWrong = TitleNormalizer.romajiKanaSimilarity(
        pearlyLocal,
        arseneJp,
      );
      expect(pearlyRight, greaterThanOrEqualTo(0.84));
      expect(pearlyRight - pearlyWrong, greaterThanOrEqualTo(0.30));
    });

    test('中置信特别篇/OVA 借离线 S0 映射直绑母剧第 0 季（Accel World EX 与 海王星 OVA1/2）', () {
      final index = BangumiTmdbIndex.fromBytes(
        BangumiTmdbIndex.encode(const [
          BangumiTmdbRecord(
            bangumiId: 48997,
            type: TmdbMediaType.tv,
            tmdbId: 43167,
            season: 0,
            tvdbId: 257516,
          ),
          BangumiTmdbRecord(
            bangumiId: 351253,
            type: TmdbMediaType.tv,
            tmdbId: 63525,
            season: 0,
            tvdbId: 267705,
          ),
        ], snapshotDateYyyymmdd: 20261121),
      );
      final awExDecision = ScrapeDomainAdapter.evaluateMatch(
        const GroupedWorkFolder(
          folderRelativePath: '动画/加速世界 TV+Movie::ex',
          folderName: 'Accel World EX',
          cleanTitle: 'Accel World EX',
          seasonHint: 0,
          isSplitCluster: true,
          mainEpisodeNumbers: [1, 2],
          titleHints: ['Accel World EX', '加速世界 EX'],
          fileHints: ['Accel World'],
          variants: [
            MediaVariant(
              id: 'ex1',
              workId: 'w',
              sourceId: 's',
              relativePath: '动画/加速世界 TV+Movie/Accel World [EX01].mkv',
              fileName: 'Accel World [EX01].mkv',
              fileSize: 500,
            ),
            MediaVariant(
              id: 'ex2',
              workId: 'w',
              sourceId: 's',
              relativePath: '动画/加速世界 TV+Movie/Accel World [EX02].mkv',
              fileName: 'Accel World [EX02].mkv',
              fileSize: 500,
            ),
          ],
        ),
        const [
          TmdbWorkDetail(
            tmdbId: 43167,
            mediaType: TmdbMediaType.tv,
            title: '加速世界',
            originalTitle: 'アクセル・ワールド',
            aliases: ['Accel World'],
            year: 2012,
            voteCount: 164,
            genreIds: [16, 10759],
            seasons: [
              TmdbSeasonSummary(seasonNumber: 0, name: '特别篇', episodeCount: 10),
              TmdbSeasonSummary(
                seasonNumber: 1,
                name: '加速世界',
                episodeCount: 24,
              ),
            ],
          ),
        ],
        bangumiCandidates: const [
          BangumiSubjectCandidate(
            id: 48997,
            name: 'アクセル・ワールド -銀翼の覚醒-',
            nameCn: '加速世界 Stage:01 -银翼的觉醒-',
            aliases: ['Accel World EX', '加速世界 OVA'],
            year: 2012,
            totalEpisodes: 1,
            platform: 'OVA',
          ),
        ],
        mappingIndex: index,
      );
      expect(awExDecision.level, MatchLevel.autoBind);
      expect(awExDecision.best?.detail.tmdbId, 43167);
      expect(awExDecision.matchedSeason, 0);
    });
  });
}

class _FakeMatchFetcher implements ScrapeCandidateFetcher {
  _FakeMatchFetcher({
    required this.bgmResults,
    required this.byIdResults,
    required this.searchResults,
    this.parentContextFailsTransient = false,
  });

  final List<BangumiSubjectCandidate> bgmResults;
  final List<TmdbWorkDetail> byIdResults;
  final List<TmdbWorkDetail> searchResults;
  final bool parentContextFailsTransient;
  bool fullSearchCalled = false;

  @override
  BangumiService? get bangumiService => null;

  @override
  Future<({List<String> extraQueries, TmdbWorkDetail? parentDetail})>
  fetchParentCollectionContext(
    GroupedWorkFolder folder, {
    void Function(Object error)? onNetworkError,
  }) async {
    if (parentContextFailsTransient) {
      onNetworkError?.call(Exception('simulated transient timeout'));
    }
    return (extraQueries: const <String>[], parentDetail: null);
  }

  @override
  Future<List<BangumiSubjectCandidate>> fetchBangumiCandidates(
    GroupedWorkFolder folder, {
    List<String> extraQueries = const [],
  }) async => bgmResults;

  @override
  Future<List<TmdbWorkDetail>> fetchDetailsByIds(
    List<({TmdbMediaType type, int id})> targets, {
    bool includeImages = true,
    void Function(Object error)? onNetworkError,
  }) async => byIdResults;

  @override
  Future<List<TmdbWorkDetail>> fetchCandidateDetails(
    GroupedWorkFolder folder, {
    ScoredBangumiCandidate? bangumiCandidate,
    List<String> extraQueries = const [],
    void Function(Object error)? onNetworkError,
  }) async {
    fullSearchCalled = true;
    return searchResults;
  }

  @override
  Future<List<TmdbWorkDetail>> rescueTmdbByBangumi(
    GroupedWorkFolder folder,
    BangumiSubjectCandidate subject, {
    List<TmdbWorkDetail> existingDetails = const [],
    void Function(Object error)? onNetworkError,
  }) async => existingDetails;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
