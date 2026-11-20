import 'package:ccplayer/domain/matching/directory_grouper.dart';
import 'package:ccplayer/domain/matching/work_matcher.dart';
import 'package:ccplayer/domain/models/media_variant.dart';
import 'package:ccplayer/domain/models/tmdb_models.dart';
import 'package:ccplayer/domain/models/work.dart';
import 'package:ccplayer/domain/scraping/bangumi_models.dart';
import 'package:ccplayer/domain/scraping/bangumi_tmdb_map.dart';
import 'package:ccplayer/domain/scraping/scrape_domain_adapter.dart';
import 'package:flutter_test/flutter_test.dart';

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

  test('Wikidata 映射表可查询并按 Bangumi 放送平台排序可用候选键', () {
    // 《攻壳机动队》(1995) 剧场版：Bangumi 237 ↔ TMDB 电影 9323。
    expect(
      BangumiTmdbMap.lookup(237),
      contains((type: TmdbMediaType.movie, id: 9323)),
    );
    expect(BangumiTmdbMap.lookup(-1), isEmpty);
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
}
