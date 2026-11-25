import 'dart:convert';

import 'package:engine_scraping/engine_scraping.dart';
import 'package:engine_scraping/src/matching/work_matcher.dart' as legacy;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

GroupedWorkFolder _makeFolder({
  String path = 'Anime/OVA Show',
  List<int> mainEpisodes = const [1],
  Map<String, EpisodeSlotAssignment> slots = const {},
  DirectoryInventory? inventory,
  String? localPosterPath,
}) {
  return GroupedWorkFolder(
    folderRelativePath: path,
    folderName: path.split('/').last,
    cleanTitle: 'OVA Show',
    mainEpisodeNumbers: mainEpisodes,
    slotAssignmentsByPath: slots,
    inventory: inventory,
    localPosterPath: localPosterPath,
    variants: const [
      MediaVariant(
        id: 'v1',
        workId: 'w1',
        sourceId: 'src_local',
        relativePath: 'Anime/OVA Show/[Sub] OVA Show [01].mkv',
        fileName: '[Sub] OVA Show [01].mkv',
        fileSize: 1024,
      ),
    ],
  );
}

void main() {
  group('WorkWallEligibility 独立上墙资格、背景图质量与跨源身份规则', () {
    test('含正片的 Bangumi 独立条目（高置信与无硬冲突中置信）具备独立上墙资格', () {
      final folder = _makeFolder(mainEpisodes: const [1, 2]);
      const subject = BangumiSubjectCandidate(
        id: 50001,
        name: 'OVA Show',
        nameCn: '测试 OVA',
        posterUrl: 'https://lain.bgm.tv/pic/cover/l/ova.jpg',
      );
      const highBgm = ScoredBangumiCandidate(
        subject: subject,
        score: 72.0,
        reasons: ['exact title'],
      );
      expect(
        WorkWallEligibility.shouldPromoteBangumiOnly(
          folder: folder,
          bestBangumi: highBgm,
          bangumiTier: legacy.MatchTier.high,
          hasValidCover: true,
        ),
        isTrue,
      );
      expect(
        WorkWallEligibility.shouldPromoteBangumiOnly(
          folder: folder,
          bestBangumi: highBgm,
          bangumiTier: legacy.MatchTier.high,
          hasValidCover: false,
        ),
        isFalse,
      );

      const medOk = ScoredBangumiCandidate(
        subject: subject,
        score: 42.0,
        reasons: ['title match'],
      );
      expect(
        WorkWallEligibility.shouldPromoteBangumiOnly(
          folder: folder,
          bestBangumi: medOk,
          bangumiTier: legacy.MatchTier.medium,
          hasValidCover: true,
        ),
        isTrue,
      );

      const medConflict = ScoredBangumiCandidate(
        subject: subject,
        score: 45.0,
        reasons: ['year conflict'],
      );
      expect(
        WorkWallEligibility.shouldPromoteBangumiOnly(
          folder: folder,
          bestBangumi: medConflict,
          bangumiTier: legacy.MatchTier.medium,
          hasValidCover: true,
        ),
        isFalse,
      );
    });

    test('防误拆红线：0 正片纯特典/NCOP/PV/CM 目录及未拆合集绝不晋升独立海报卡片', () {
      final extraOnlyFolder = _makeFolder(
        path: 'Anime/Show/SPs',
        mainEpisodes: const [],
        localPosterPath: r'D:\Anime\Show\SPs\poster.jpg',
        slots: const {
          'Anime/Show/SPs/NCOP01.mkv': EpisodeSlotAssignment(
            category: EpisodeCategory.extra,
            seasonNumber: 0,
            extraType: ExtraKind.ncop,
          ),
        },
      );
      expect(WorkWallEligibility.hasMainPlayableContent(extraOnlyFolder), isFalse);
      expect(
        WorkWallEligibility.shouldPromoteCoverFallback(
          folder: extraOnlyFolder,
          coverPath: extraOnlyFolder.localPosterPath,
        ),
        isFalse,
      );

      final anthologyInv = DirectoryInventory.synthetic(
        folder: 'Anime/Collection',
        title: 'Collection',
        main: [LogicalItem('1', 'Show A', 1, 1)],
        shape: WorkShape.anthology,
        titleHints: const ['Show A', 'Show B'],
      );
      final anthologyFolder = _makeFolder(
        mainEpisodes: const [1, 2],
        inventory: anthologyInv,
        localPosterPath: r'D:\Anime\Collection\folder.jpg',
      );
      expect(WorkWallEligibility.hasMainPlayableContent(anthologyFolder), isFalse);
      expect(
        WorkWallEligibility.shouldPromoteCoverFallback(
          folder: anthologyFolder,
          coverPath: anthologyFolder.localPosterPath,
        ),
        isFalse,
      );
    });

    test('TMDB 背景图低清（720p）或带文字时触发 Fanart 1080p 升级，1080p 无字则保持 TMDB', () {
      expect(
        WorkWallEligibility.isTmdbBackdropSuboptimal(
          selectedBackdropPath: null,
          candidateBackdrops: const [],
        ),
        isTrue,
      );
      expect(
        WorkWallEligibility.isTmdbBackdropSuboptimal(
          selectedBackdropPath: '/bg_720p.jpg',
          candidateBackdrops: const [
            TmdbArtworkImage(
              filePath: '/bg_720p.jpg',
              isoLanguage: null,
              width: 1280,
              height: 720,
            ),
          ],
        ),
        isTrue,
      );
      expect(
        WorkWallEligibility.isTmdbBackdropSuboptimal(
          selectedBackdropPath: '/bg_texted.jpg',
          candidateBackdrops: const [
            TmdbArtworkImage(
              filePath: '/bg_texted.jpg',
              isoLanguage: 'en',
              width: 1920,
              height: 1080,
            ),
          ],
        ),
        isTrue,
      );
      expect(
        WorkWallEligibility.isTmdbBackdropSuboptimal(
          selectedBackdropPath: '/bg_clean_1080p.jpg',
          candidateBackdrops: const [
            TmdbArtworkImage(
              filePath: '/bg_clean_1080p.jpg',
              isoLanguage: null,
              width: 1920,
              height: 1080,
            ),
          ],
        ),
        isFalse,
      );
    });

    test('跨来源身份键严格区分同系列不同季，并稳定聚合同作品不同来源卡片', () {
      const s1Local = Work(
        id: 'w_local_s1',
        title: '葬送的芙莉莲',
        tmdbId: 209867,
        tmdbMediaType: TmdbMediaType.tv,
        matchedSeason: 1,
      );
      const s1Webdav = Work(
        id: 'w_dav_s1',
        title: '葬送的芙莉莲',
        tmdbId: 209867,
        tmdbMediaType: TmdbMediaType.tv,
        matchedSeason: 1,
      );
      const s2Local = Work(
        id: 'w_local_s2',
        title: '葬送的芙莉莲 第2季',
        tmdbId: 209867,
        tmdbMediaType: TmdbMediaType.tv,
        matchedSeason: 2,
      );
      expect(
        WorkWallEligibility.buildCrossSourceIdentityKey(s1Local),
        WorkWallEligibility.buildCrossSourceIdentityKey(s1Webdav),
      );
      expect(
        WorkWallEligibility.buildCrossSourceIdentityKey(s1Local),
        isNot(WorkWallEligibility.buildCrossSourceIdentityKey(s2Local)),
      );
    });
  });

  group('ClearLogoRanker 跨源排序与 FanartUrlHelper 预览地址转换', () {
    test('Fanart 高清日文徽标严格胜过 TMDB 英文徽标；简中高清最高优先', () {
      final ranked = ClearLogoRanker.sortMerged(const [
        RankedLogoCandidate(
          filePath: '/tmdb_en_hd.png',
          source: LogoSourceKind.tmdb,
          isoLanguage: 'en',
          isoCountry: 'US',
          isHd: true,
          width: 1500,
          voteAverage: 9.2,
          voteCount: 40,
        ),
        RankedLogoCandidate(
          filePath: 'https://assets.fanart.tv/fanart/tv/424536/hdtvlogo/ja.png',
          source: LogoSourceKind.fanart,
          isoLanguage: 'ja',
          isHd: true,
          likes: 6,
        ),
        RankedLogoCandidate(
          filePath: 'https://assets.fanart.tv/fanart/tv/424536/clearlogo/ja_sd.png',
          source: LogoSourceKind.fanart,
          isoLanguage: 'ja',
          isHd: false,
          likes: 20,
        ),
      ]);
      expect(ranked.first.filePath, contains('/hdtvlogo/ja.png'));
      expect(ranked[1].filePath, contains('/clearlogo/ja_sd.png'));
      expect(ranked[2].filePath, '/tmdb_en_hd.png');

      final withZh = ClearLogoRanker.sortMerged([
        ...ranked,
        const RankedLogoCandidate(
          filePath: '/tmdb_zh_cn.png',
          source: LogoSourceKind.tmdb,
          isoLanguage: 'zh',
          isoCountry: 'CN',
          isHd: true,
          width: 900,
          voteAverage: 7.0,
        ),
      ]);
      expect(withZh.first.filePath, '/tmdb_zh_cn.png');
    });

    test('FanartUrlHelper 精确完成 /fanart/ 与 /preview/ 双向转换并升级 HTTPS', () {
      const rawHttp = 'http://assets.fanart.tv/fanart/tv/424536/tvposter/p1.jpg';
      final preview = FanartUrlHelper.toPreviewUrl(rawHttp);
      expect(
        preview,
        'https://assets.fanart.tv/preview/tv/424536/tvposter/p1.jpg',
      );
      expect(
        FanartUrlHelper.toOriginalUrl(preview),
        'https://assets.fanart.tv/fanart/tv/424536/tvposter/p1.jpg',
      );
    });

    test('魔具少女分季徽标纠偏：第 1 季跳过第 2 季《通》自动选第 1 季高清，第 2 季优先选《通》', () {
      const fanartLogos = <FanartLogoCandidate>[
        FanartLogoCandidate(
          id: '145609',
          url:
              'https://assets.fanart.tv/fanart/maken-ki-battling-venus-621c4c6a4c46c.png',
          kind: FanartLogoKind.hdTvLogo,
          lang: 'ja',
          likes: 1,
        ),
        FanartLogoCandidate(
          id: '59138',
          url: 'https://assets.fanart.tv/fanart/maken-ki-5678d8daa917e.png',
          kind: FanartLogoKind.hdTvLogo,
          lang: 'ja',
          likes: 0,
        ),
        FanartLogoCandidate(
          id: '14777',
          url: 'https://assets.fanart.tv/fanart/maken-ki-4ee2c66ca3f34.png',
          kind: FanartLogoKind.clearLogo,
          lang: 'ja',
          likes: 0,
        ),
        FanartLogoCandidate(
          id: '95533',
          url: 'https://assets.fanart.tv/fanart/maken-ki-5c8d3de33a32d.png',
          kind: FanartLogoKind.hdTvLogo,
          lang: 'en',
          likes: 0,
        ),
      ];

      final s1Ranked = ClearLogoResolver.mergeAndRankLogos(
        tmdbLogos: const [],
        fanartLogos: fanartLogos,
        tmdbId: 60732,
        tvdbId: 252474,
        mediaType: TmdbMediaType.tv,
        matchedSeason: 1,
      );
      expect(s1Ranked, hasLength(4));
      expect(s1Ranked.first.filePath, contains('maken-ki-5678d8daa917e.png'));
      expect(s1Ranked[1].filePath, contains('maken-ki-4ee2c66ca3f34.png'));
      // 第 2 季《通》仍保留在手动选图列表末尾，但不参与第 1 季默认首推。
      expect(
        s1Ranked.last.filePath,
        contains('maken-ki-battling-venus-621c4c6a4c46c.png'),
      );

      final s2Ranked = ClearLogoResolver.mergeAndRankLogos(
        tmdbLogos: const [],
        fanartLogos: fanartLogos,
        tmdbId: 60732,
        tvdbId: 252474,
        mediaType: TmdbMediaType.tv,
        matchedSeason: 2,
      );
      expect(
        s2Ranked.first.filePath,
        contains('maken-ki-battling-venus-621c4c6a4c46c.png'),
      );
    });

    test('已落盘错季徽标的非锁定作品自动触发详情页自愈纠偏，人工锁定后严格尊重用户选择', () async {
      const s2WrongLogo =
          'https://assets.fanart.tv/fanart/maken-ki-battling-venus-621c4c6a4c46c.png';
      const s1CorrectLogo =
          'https://assets.fanart.tv/fanart/maken-ki-5678d8daa917e.png';

      const unlockedS1 = Work(
        id: 'w_makenki_s1',
        title: '魔具少女！',
        tmdbId: 60732,
        tvdbId: 252474,
        tmdbMediaType: TmdbMediaType.tv,
        matchedSeason: 1,
        logoPath: s2WrongLogo,
        logoLocked: false,
      );
      const lockedS1 = Work(
        id: 'w_makenki_s1_locked',
        title: '魔具少女！',
        tmdbId: 60732,
        tvdbId: 252474,
        tmdbMediaType: TmdbMediaType.tv,
        matchedSeason: 1,
        logoPath: s2WrongLogo,
        logoLocked: true,
      );
      const cfg = TmdbNetworkConfig(credential: 'test_tmdb_key');

      expect(
        ClearLogoResolver.shouldAttemptDetailLogoBackfill(
          work: unlockedS1,
          config: cfg,
        ),
        isTrue,
      );
      expect(
        ClearLogoResolver.shouldAttemptDetailLogoBackfill(
          work: lockedS1,
          config: cfg,
        ),
        isFalse,
      );

      final mockClient = MockClient((request) async {
        final path = request.url.path;
        if (path.endsWith('/tv/60732')) {
          return http.Response.bytes(
            utf8.encode(
              jsonEncode({
                'id': 60732,
                'name': '魔具少女！',
                'external_ids': {'tvdb_id': 252474},
                'images': {'logos': <Object>[]},
              }),
            ),
            200,
            headers: const {'content-type': 'application/json; charset=utf-8'},
          );
        }
        if (path.contains('/v3/tv/252474')) {
          return http.Response.bytes(
            utf8.encode(
              jsonEncode({
                'name': 'Maken-Ki!',
                'thetvdb_id': '252474',
                'hdtvlogo': [
                  {
                    'id': '145609',
                    'url': s2WrongLogo,
                    'lang': 'ja',
                    'likes': '1',
                  },
                  {
                    'id': '59138',
                    'url': s1CorrectLogo,
                    'lang': 'ja',
                    'likes': '0',
                  },
                ],
              }),
            ),
            200,
            headers: const {'content-type': 'application/json; charset=utf-8'},
          );
        }
        return http.Response('{}', 404);
      });
      final httpClient = TmdbHttpClient(
        config: cfg,
        scheduler: PriorityHttpScheduler(maxRetries: 0),
        httpClient: mockClient,
      );
      addTearDown(httpClient.close);
      final resolver = ClearLogoResolver(
        tmdbService: TmdbService(httpClient: httpClient),
        fanartService: FanartService(httpClient: httpClient),
        networkConfig: cfg,
      );

      final outcome = await resolver.resolveForWork(unlockedS1);
      expect(outcome.logoPath, s1CorrectLogo);

      // 自愈后再次检查不再重复发起网络探测。
      final healed = unlockedS1.copyWith(logoPath: outcome.logoPath);
      expect(
        ClearLogoResolver.shouldAttemptDetailLogoBackfill(
          work: healed,
          config: cfg,
        ),
        isFalse,
      );
    });

    test('TMDB 透明徽标贝叶斯平滑评分防止 1 票虚高条目反超多人投票共识图', () {
      final ranked = ClearLogoRanker.sortMerged(const [
        RankedLogoCandidate(
          filePath: '/one_vote_sequel.png',
          source: LogoSourceKind.tmdb,
          isoLanguage: 'ja',
          isHd: true,
          width: 1000,
          voteAverage: 5.312,
          voteCount: 1,
        ),
        RankedLogoCandidate(
          filePath: '/consensus_s1.png',
          source: LogoSourceKind.tmdb,
          isoLanguage: 'ja',
          isHd: true,
          width: 1000,
          voteAverage: 5.25,
          voteCount: 4,
        ),
      ]);
      expect(ranked.first.filePath, '/consensus_s1.png');
    });
  });
}
