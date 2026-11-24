import 'dart:convert';

import 'package:engine_scraping/engine_scraping.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  group('ArtworkRanker 背景图六档排序与方案 A 质量判定', () {
    test('魔具少女场景：4K 无字官方原画严格胜过 1080p 低票高均分动画截图', () {
      const screenshot1080p = TmdbArtworkImage(
        filePath: '/7dE2I1Z22kndVgUliYQL7AhaLHs.jpg',
        isoLanguage: null,
        width: 1920,
        height: 1080,
        voteAverage: 5.312,
        voteCount: 1,
      );
      const visual4kA = TmdbArtworkImage(
        filePath: '/maken_4k_key_visual_a.jpg',
        isoLanguage: null,
        width: 3840,
        height: 2160,
        voteAverage: 5.25,
        voteCount: 2,
      );
      const visual4kB = TmdbArtworkImage(
        filePath: '/maken_4k_key_visual_b.jpg',
        isoLanguage: null,
        width: 3840,
        height: 2160,
        voteAverage: 5.20,
        voteCount: 6,
      );
      const oddNonStandard = TmdbArtworkImage(
        filePath: '/maken_2024x1138.jpg',
        isoLanguage: null,
        width: 2024,
        height: 1138,
        voteAverage: 8.0,
        voteCount: 5,
      );

      final ranked = ArtworkRanker.rankTmdbBackdrops(
        const [screenshot1080p, oddNonStandard, visual4kA, visual4kB],
        primaryDefaultPath: screenshot1080p.filePath,
      );

      expect(
        ranked.map((e) => e.filePath).toList(),
        const [
          '/maken_4k_key_visual_b.jpg',
          '/maken_4k_key_visual_a.jpg',
          '/7dE2I1Z22kndVgUliYQL7AhaLHs.jpg',
          '/maken_2024x1138.jpg',
        ],
      );
      expect(
        ArtworkRanker.selectBestTmdbBackdrop(
          ranked,
          primaryDefaultPath: screenshot1080p.filePath,
        ),
        '/maken_4k_key_visual_b.jpg',
      );
    });

    test('贝叶斯平滑评分：多人投票原画压过 1 票虚高裸均分截图，非标准比例沉底', () {
      const oneVoteFluke = TmdbArtworkImage(
        filePath: '/one_vote.jpg',
        isoLanguage: null,
        width: 1920,
        height: 1080,
        voteAverage: 5.5,
        voteCount: 1,
      );
      const multiVoteVisual = TmdbArtworkImage(
        filePath: '/multi_vote.jpg',
        isoLanguage: null,
        width: 1920,
        height: 1080,
        voteAverage: 5.35,
        voteCount: 10,
      );
      const texted1080p = TmdbArtworkImage(
        filePath: '/texted_zh.jpg',
        isoLanguage: 'zh',
        width: 1920,
        height: 1080,
        voteAverage: 9.0,
        voteCount: 20,
      );
      const malformedAspect = TmdbArtworkImage(
        filePath: '/square_4k.jpg',
        isoLanguage: null,
        width: 3000,
        height: 3000,
        voteAverage: 9.5,
        voteCount: 30,
      );

      final ranked = ArtworkRanker.rankTmdbBackdrops(const [
        malformedAspect,
        texted1080p,
        oneVoteFluke,
        multiVoteVisual,
      ]);
      expect(
        ranked.map((e) => e.filePath).toList(),
        const [
          '/multi_vote.jpg',
          '/one_vote.jpg',
          '/texted_zh.jpg',
          '/square_4k.jpg',
        ],
      );
    });

    test('方案 A 背景欠佳判定：识别 2008×1129 非标拉大糊图与低票 1080p 截帧，放行 4K 与高共识 1080p', () {
      // 快盗天使真实案例：2008×1129 非标拉大糊图
      expect(
        WorkWallEligibility.isTmdbBackdropSuboptimal(
          selectedBackdropPath: '/zuMRUdvISkEMY4NsFIImHrKNSjs.jpg',
          candidateBackdrops: const [
            TmdbArtworkImage(
              filePath: '/zuMRUdvISkEMY4NsFIImHrKNSjs.jpg',
              isoLanguage: null,
              width: 2008,
              height: 1129,
              voteAverage: 5.3,
              voteCount: 2,
            ),
          ],
        ),
        isTrue,
      );

      // 低票标准 1080p（voteCount < 3）触发 Fanart 升级
      expect(
        WorkWallEligibility.isTmdbBackdropSuboptimal(
          selectedBackdropPath: '/low_vote_1080p.jpg',
          candidateBackdrops: const [
            TmdbArtworkImage(
              filePath: '/low_vote_1080p.jpg',
              isoLanguage: null,
              width: 1920,
              height: 1080,
              voteAverage: 5.3,
              voteCount: 2,
            ),
          ],
        ),
        isTrue,
      );

      // 高共识标准 1080p（voteCount >= 3）不触发多余 Fanart 请求
      expect(
        WorkWallEligibility.isTmdbBackdropSuboptimal(
          selectedBackdropPath: '/trusted_1080p.jpg',
          candidateBackdrops: const [
            TmdbArtworkImage(
              filePath: '/trusted_1080p.jpg',
              isoLanguage: null,
              width: 1920,
              height: 1080,
              voteAverage: 5.4,
              voteCount: 3,
            ),
          ],
        ),
        isFalse,
      );

      // 4K 无字官方原画即便 0~1 票也无需 Fanart 降级替代
      expect(
        WorkWallEligibility.isTmdbBackdropSuboptimal(
          selectedBackdropPath: '/official_4k.jpg',
          candidateBackdrops: const [
            TmdbArtworkImage(
              filePath: '/official_4k.jpg',
              isoLanguage: null,
              width: 3840,
              height: 2160,
              voteAverage: 0.0,
              voteCount: 0,
            ),
          ],
        ),
        isFalse,
      );
    });
  });

  group('ArtworkRanker 封面图排序与欠佳判定', () {
    test('清晰度门槛优先于语言：清晰日文全高清海报胜过模糊中文小图与方图', () {
      const blurryZh = TmdbArtworkImage(
        filePath: '/blurry_zh.jpg',
        isoLanguage: 'zh',
        isoCountry: 'CN',
        width: 450,
        height: 675,
        voteAverage: 8.0,
        voteCount: 10,
      );
      const squareZh = TmdbArtworkImage(
        filePath: '/square_zh.jpg',
        isoLanguage: 'zh',
        isoCountry: 'CN',
        width: 1000,
        height: 1000,
        voteAverage: 9.0,
        voteCount: 10,
      );
      const crispJaFullHd = TmdbArtworkImage(
        filePath: '/crisp_ja_2k.jpg',
        isoLanguage: 'ja',
        width: 2000,
        height: 3000,
        voteAverage: 5.5,
        voteCount: 4,
      );
      const crispZhTw = TmdbArtworkImage(
        filePath: '/crisp_zh_tw.jpg',
        isoLanguage: 'zh',
        isoCountry: 'TW',
        width: 1000,
        height: 1500,
        voteAverage: 5.2,
        voteCount: 2,
      );
      const crispEn = TmdbArtworkImage(
        filePath: '/crisp_en.jpg',
        isoLanguage: 'en',
        width: 2000,
        height: 3000,
        voteAverage: 8.8,
        voteCount: 25,
      );

      final ranked = ArtworkRanker.rankTmdbPosters(const [
        blurryZh,
        squareZh,
        crispEn,
        crispJaFullHd,
        crispZhTw,
      ]);

      expect(
        ranked.map((e) => e.filePath).toList(),
        const [
          '/crisp_zh_tw.jpg',
          '/crisp_ja_2k.jpg',
          '/crisp_en.jpg',
          '/blurry_zh.jpg',
          '/square_zh.jpg',
        ],
      );
      expect(
        ArtworkRanker.isTmdbPosterSuboptimal(
          selectedPosterPath: '/crisp_zh_tw.jpg',
          candidatePosters: ranked,
        ),
        isFalse,
      );
      expect(
        ArtworkRanker.isTmdbPosterSuboptimal(
          selectedPosterPath: '/crisp_en.jpg',
          candidatePosters: ranked,
        ),
        isTrue,
      );
      expect(
        ArtworkRanker.isTmdbPosterSuboptimal(
          selectedPosterPath: '/blurry_zh.jpg',
          candidatePosters: ranked,
        ),
        isTrue,
      );
    });

    test('第 1 季分季海报欠佳时自动回退至清晰的系列主海报，第 2 季保留欠佳标记等待跨源补位', () {
      const detail = TmdbWorkDetail(
        tmdbId: 9001,
        mediaType: TmdbMediaType.tv,
        title: '示例动画',
        posterPath: '/series_zh_2k.jpg',
        candidatePosters: [
          TmdbArtworkImage(
            filePath: '/series_zh_2k.jpg',
            isoLanguage: 'zh',
            isoCountry: 'CN',
            width: 2000,
            height: 3000,
          ),
        ],
      );
      const badSeason = TmdbSeasonDetail(
        seasonNumber: 1,
        name: '第 1 季',
        posterPath: '/season_en_blur.jpg',
        candidatePosters: [
          TmdbArtworkImage(
            filePath: '/season_en_blur.jpg',
            isoLanguage: 'en',
            width: 500,
            height: 750,
          ),
        ],
      );

      final s1 = ArtworkRanker.resolveEffectiveTmdbPoster(
        detail: detail,
        seasonDetail: badSeason,
        matchedSeason: 1,
      );
      expect(s1.posterPath, '/series_zh_2k.jpg');
      expect(s1.fallbackPosterPath, '/season_en_blur.jpg');
      expect(s1.isSuboptimal, isFalse);

      final s2 = ArtworkRanker.resolveEffectiveTmdbPoster(
        detail: detail,
        seasonDetail: const TmdbSeasonDetail(
          seasonNumber: 2,
          name: '第 2 季',
          posterPath: '/s2_en.jpg',
          candidatePosters: [
            TmdbArtworkImage(
              filePath: '/s2_en.jpg',
              isoLanguage: 'en',
              width: 1000,
              height: 1500,
            ),
          ],
        ),
        matchedSeason: 2,
      );
      expect(s2.posterPath, '/s2_en.jpg');
      expect(s2.isSuboptimal, isTrue);
    });

    test('selectFanartPosterForUpgrade：英文 TMDB 仅采纳 Fanart 中日/无字海报，糊图允许任意语言升级', () {
      const fanartOnlyEn = FanartArtworkResult(
        posters: [
          FanartPosterCandidate(
            id: 'p_en',
            url: 'https://assets.fanart.tv/fanart/tv/1/tvposter/en.jpg',
            lang: 'en',
            likes: 10,
          ),
        ],
      );
      const fanartWithJa = FanartArtworkResult(
        posters: [
          FanartPosterCandidate(
            id: 'p_en',
            url: 'https://assets.fanart.tv/fanart/tv/1/tvposter/en.jpg',
            lang: 'en',
            likes: 10,
          ),
          FanartPosterCandidate(
            id: 'p_ja',
            url: 'https://assets.fanart.tv/fanart/tv/1/tvposter/ja.jpg',
            lang: 'ja',
            likes: 5,
          ),
        ],
      );

      // 清晰英文 TMDB + Fanart 仅英文 -> 不做无意义替换
      expect(
        ArtworkRanker.selectFanartPosterForUpgrade(
          fanartOnlyEn,
          allowAnyLanguage: false,
        ),
        isNull,
      );
      // 模糊 TMDB + Fanart 仅英文 1000×1426 -> 允许清晰度升级
      expect(
        ArtworkRanker.selectFanartPosterForUpgrade(
          fanartOnlyEn,
          allowAnyLanguage: true,
        ),
        'https://assets.fanart.tv/fanart/tv/1/tvposter/en.jpg',
      );
      // 清晰英文 TMDB + Fanart 有日文原版 -> 升级为日文
      expect(
        ArtworkRanker.selectFanartPosterForUpgrade(
          fanartWithJa,
          allowAnyLanguage: false,
        ),
        'https://assets.fanart.tv/fanart/tv/1/tvposter/ja.jpg',
      );
    });
  });

  group('TmdbService、ScrapeArtworkEnricher 与 ClearLogoResolver 端到端协同', () {
    test('TmdbService.getWorkDetail 与 getSeasonDetail 解析并按新引擎优选 4K 背景与高清分季封面', () async {
      final mockClient = MockClient((request) async {
        if (request.url.path.endsWith('/tv/4242')) {
          return http.Response.bytes(
            utf8.encode(
              jsonEncode({
                'id': 4242,
                'name': '魔具少女！',
                'poster_path': '/raw_en_poster.jpg',
                'backdrop_path': '/7dE2I1Z22kndVgUliYQL7AhaLHs.jpg',
                'images': {
                  'posters': [
                    {
                      'iso_639_1': 'en',
                      'file_path': '/raw_en_poster.jpg',
                      'width': 1000,
                      'height': 1500,
                      'vote_average': 7.5,
                      'vote_count': 10,
                    },
                    {
                      'iso_639_1': 'zh',
                      'iso_3166_1': 'CN',
                      'file_path': '/zh_cn_2k.jpg',
                      'width': 2000,
                      'height': 3000,
                      'vote_average': 5.3,
                      'vote_count': 2,
                    },
                  ],
                  'backdrops': [
                    {
                      'iso_639_1': null,
                      'file_path': '/7dE2I1Z22kndVgUliYQL7AhaLHs.jpg',
                      'width': 1920,
                      'height': 1080,
                      'vote_average': 5.312,
                      'vote_count': 1,
                    },
                    {
                      'iso_639_1': null,
                      'file_path': '/official_4k_kv.jpg',
                      'width': 3840,
                      'height': 2160,
                      'vote_average': 5.25,
                      'vote_count': 2,
                    },
                  ],
                },
              }),
            ),
            200,
            headers: const {'content-type': 'application/json; charset=utf-8'},
          );
        }
        if (request.url.path.endsWith('/tv/4242/season/2')) {
          expect(request.url.queryParameters['append_to_response'], 'images');
          return http.Response.bytes(
            utf8.encode(
              jsonEncode({
                'season_number': 2,
                'name': '魔具少女！通',
                'poster_path': '/s2_blurry.jpg',
                'episodes': <Map<String, Object?>>[],
                'images': {
                  'posters': [
                    {
                      'iso_639_1': 'zh',
                      'file_path': '/s2_blurry.jpg',
                      'width': 400,
                      'height': 600,
                      'vote_average': 6.0,
                      'vote_count': 1,
                    },
                    {
                      'iso_639_1': 'ja',
                      'file_path': '/s2_crisp_ja.jpg',
                      'width': 1400,
                      'height': 2100,
                      'vote_average': 5.4,
                      'vote_count': 3,
                    },
                  ],
                },
              }),
            ),
            200,
            headers: const {'content-type': 'application/json; charset=utf-8'},
          );
        }
        return http.Response('{}', 404);
      });

      final client = TmdbHttpClient(
        config: const TmdbNetworkConfig(credential: 'test_key'),
        scheduler: PriorityHttpScheduler(maxRetries: 0),
        httpClient: mockClient,
      );
      addTearDown(client.close);
      final tmdb = TmdbService(httpClient: client);

      final detail = await tmdb.getWorkDetail(4242, TmdbMediaType.tv);
      expect(detail, isNotNull);
      expect(detail!.backdropPath, '/official_4k_kv.jpg');
      expect(detail.posterPath, '/zh_cn_2k.jpg');

      final season = await tmdb.getSeasonDetail(4242, 2);
      expect(season, isNotNull);
      expect(season!.posterPath, '/s2_crisp_ja.jpg');
      expect(season.candidatePosters.length, 2);
      expect(season.candidatePosters.first.filePath, '/s2_crisp_ja.jpg');
    });

    test('快盗天使场景：2008×1129 非标 TMDB 背景自动触发 Fanart 升级为清晰 1920×1080', () async {
      var fanartHitCount = 0;
      final mockClient = MockClient((request) async {
        if (request.url.host == 'relay.konata.example' &&
            request.url.path == '/fanart/v3/tv/250001') {
          fanartHitCount++;
          return http.Response(
            jsonEncode({
              'showbackground': [
                {
                  'id': 'bg1',
                  'url':
                      'https://assets.fanart.tv/fanart/tv/250001/showbackground/twin_clean.jpg',
                  'lang': '',
                  'likes': '6',
                },
              ],
            }),
            200,
          );
        }
        return http.Response('{}', 404);
      });

      const config = TmdbNetworkConfig(
        credential: 'test_key',
        fanartBackupApiBase: 'https://relay.konata.example',
      );
      final httpClient = TmdbHttpClient(
        config: config,
        scheduler: PriorityHttpScheduler(maxRetries: 0),
        httpClient: mockClient,
      );
      addTearDown(httpClient.close);

      final enricher = ScrapeArtworkEnricher(
        fanartService: FanartService(httpClient: httpClient),
      );
      final outcome = await enricher.enrichTmdbDetail(
        detail: const TmdbWorkDetail(
          tmdbId: 65432,
          mediaType: TmdbMediaType.tv,
          tvdbId: 250001,
          title: '快盗天使双胞胎',
          posterPath: '/twin_ja.jpg',
          backdropPath: '/zuMRUdvISkEMY4NsFIImHrKNSjs.jpg',
          candidatePosters: [
            TmdbArtworkImage(
              filePath: '/twin_ja.jpg',
              isoLanguage: 'ja',
              width: 1000,
              height: 1500,
            ),
          ],
          candidateBackdrops: [
            TmdbArtworkImage(
              filePath: '/zuMRUdvISkEMY4NsFIImHrKNSjs.jpg',
              isoLanguage: null,
              width: 2008,
              height: 1129,
              voteAverage: 5.3,
              voteCount: 2,
            ),
          ],
        ),
        seasonDetail: null,
        matchedSeason: 0,
        bangumiCandidate: null,
        priority: RequestPriority.background,
      );

      expect(fanartHitCount, 1);
      expect(outcome.backdropSuboptimal, isTrue);
      expect(outcome.backdropUpgradedByFanart, isTrue);
      expect(
        outcome.backdropOverride,
        'https://assets.fanart.tv/fanart/tv/250001/showbackground/twin_clean.jpg',
      );
    });

    test('无 Bangumi 封面且 TMDB 仅有英文封面时，Fanart 日文高清海报自动接管并保留原 TMDB 兜底', () async {
      final mockClient = MockClient((request) async {
        if (request.url.host == 'relay.konata.example' &&
            request.url.path == '/fanart/v3/tv/350001') {
          return http.Response(
            jsonEncode({
              'tvposter': [
                {
                  'id': 'p1',
                  'url':
                      'https://assets.fanart.tv/fanart/tv/350001/tvposter/ja_hd.jpg',
                  'lang': 'ja',
                  'likes': '8',
                },
              ],
            }),
            200,
          );
        }
        return http.Response('{}', 404);
      });

      const config = TmdbNetworkConfig(
        credential: 'test_key',
        fanartBackupApiBase: 'https://relay.konata.example',
      );
      final httpClient = TmdbHttpClient(
        config: config,
        scheduler: PriorityHttpScheduler(maxRetries: 0),
        httpClient: mockClient,
      );
      addTearDown(httpClient.close);

      const detail = TmdbWorkDetail(
        tmdbId: 77701,
        mediaType: TmdbMediaType.tv,
        tvdbId: 350001,
        title: '测试动画',
        posterPath: '/en_only.jpg',
        backdropPath: '/good_4k.jpg',
        candidatePosters: [
          TmdbArtworkImage(
            filePath: '/en_only.jpg',
            isoLanguage: 'en',
            width: 1000,
            height: 1500,
          ),
        ],
        candidateBackdrops: [
          TmdbArtworkImage(
            filePath: '/good_4k.jpg',
            isoLanguage: null,
            width: 3840,
            height: 2160,
          ),
        ],
      );

      final enricher = ScrapeArtworkEnricher(
        fanartService: FanartService(httpClient: httpClient),
      );
      final enrich = await enricher.enrichTmdbDetail(
        detail: detail,
        seasonDetail: null,
        matchedSeason: 1,
        bangumiCandidate: null,
        priority: RequestPriority.background,
      );

      expect(enrich.posterSuboptimal, isTrue);
      expect(enrich.fanartQueried, isTrue);
      expect(
        enrich.posterOverride,
        'https://assets.fanart.tv/fanart/tv/350001/tvposter/ja_hd.jpg',
      );

      final work = ScrapeWorkPersister.buildMatchedWork(
        id: 'w_fanart_poster',
        detail: detail,
        matchedSeason: 1,
        fanartPosterOverride: enrich.posterOverride,
        fanartPosterFallback: enrich.posterFallback,
        isManualLocked: false,
      );
      expect(
        work.posterPath,
        'https://assets.fanart.tv/fanart/tv/350001/tvposter/ja_hd.jpg',
      );
      expect(work.posterFallback, '/en_only.jpg');
    });

    test('已有 Bangumi 官方封面且 TMDB 仅有英文封面时，零 Fanart 消耗直接优选 Bangumi 官方封面', () async {
      var fanartCalls = 0;
      final mockClient = MockClient((request) async {
        fanartCalls++;
        return http.Response('{}', 404);
      });
      const config = TmdbNetworkConfig(
        credential: 'test_key',
        fanartBackupApiBase: 'https://relay.konata.example',
      );
      final httpClient = TmdbHttpClient(
        config: config,
        scheduler: PriorityHttpScheduler(maxRetries: 0),
        httpClient: mockClient,
      );
      addTearDown(httpClient.close);

      const detail = TmdbWorkDetail(
        tmdbId: 77702,
        mediaType: TmdbMediaType.tv,
        tvdbId: 350002,
        title: '测试动画',
        posterPath: '/en_only.jpg',
        backdropPath: '/good_4k.jpg',
        candidatePosters: [
          TmdbArtworkImage(
            filePath: '/en_only.jpg',
            isoLanguage: 'en',
            width: 1000,
            height: 1500,
          ),
        ],
        candidateBackdrops: [
          TmdbArtworkImage(
            filePath: '/good_4k.jpg',
            isoLanguage: null,
            width: 3840,
            height: 2160,
          ),
        ],
      );
      const bgmCand = ScoredBangumiCandidate(
        subject: BangumiSubjectCandidate(
          id: 12345,
          name: 'テストアニメ',
          nameCn: '测试动画',
          posterUrl: 'https://lain.bgm.tv/pic/cover/l/test.jpg',
        ),
        score: 0.96,
        reasons: ['测试夹具'],
      );
      const folder = GroupedWorkFolder(
        folderName: '测试动画',
        folderRelativePath: '测试动画',
        cleanTitle: '测试动画',
        variants: [],
      );

      final enricher = ScrapeArtworkEnricher(
        fanartService: FanartService(httpClient: httpClient),
      );
      final enrich = await enricher.enrichTmdbDetail(
        detail: detail,
        seasonDetail: null,
        matchedSeason: 1,
        bangumiCandidate: bgmCand,
        priority: RequestPriority.background,
      );

      expect(fanartCalls, 0);
      expect(enrich.fanartQueried, isFalse);
      expect(enrich.posterOverride, isNull);

      final work = ScrapeWorkPersister.buildMatchedWork(
        id: 'w_bgm_rescue',
        detail: detail,
        folder: folder,
        matchedSeason: 1,
        bangumiCandidate: bgmCand,
        isManualLocked: false,
      );
      expect(work.posterPath, 'https://lain.bgm.tv/pic/cover/l/test.jpg');
      expect(work.posterFallback, '/en_only.jpg');
    });

    test('ClearLogoResolver 后台补全可将旧库 1080p 截图直接升级为 TMDB 4K 原画且零 Fanart 消耗', () async {
      var fanartCalls = 0;
      final mockClient = MockClient((request) async {
        if (request.url.host == 'relay.konata.example') {
          fanartCalls++;
        }
        return http.Response('{}', 404);
      });
      const config = TmdbNetworkConfig(
        credential: 'test_key',
        fanartBackupApiBase: 'https://relay.konata.example',
      );
      final httpClient = TmdbHttpClient(
        config: config,
        scheduler: PriorityHttpScheduler(maxRetries: 0),
        httpClient: mockClient,
      );
      addTearDown(httpClient.close);

      final resolver = ClearLogoResolver(
        tmdbService: TmdbService(httpClient: httpClient),
        fanartService: FanartService(httpClient: httpClient),
        networkConfig: config,
      );

      const oldWork = Work(
        id: 'w_maken_old',
        title: '魔具少女！通',
        tmdbId: 4242,
        tmdbMediaType: TmdbMediaType.tv,
        tvdbId: 251001,
        backdropPath: '/old_1080p_screenshot.jpg',
        logoPath: '/zh_cn_logo.png',
        logoLocked: true,
      );
      const freshDetail = TmdbWorkDetail(
        tmdbId: 4242,
        mediaType: TmdbMediaType.tv,
        tvdbId: 251001,
        title: '魔具少女！',
        backdropPath: '/official_4k_kv.jpg',
        candidateBackdrops: [
          TmdbArtworkImage(
            filePath: '/official_4k_kv.jpg',
            isoLanguage: null,
            width: 3840,
            height: 2160,
            voteAverage: 5.25,
            voteCount: 2,
          ),
          TmdbArtworkImage(
            filePath: '/old_1080p_screenshot.jpg',
            isoLanguage: null,
            width: 1920,
            height: 1080,
            voteAverage: 5.312,
            voteCount: 1,
          ),
        ],
      );

      final outcome = await resolver.resolveForWork(
        oldWork,
        preloadedTmdbDetail: freshDetail,
        upgradeBackdropIfSuboptimal: true,
      );

      expect(fanartCalls, 0);
      expect(outcome.upgradedBackdropPath, '/official_4k_kv.jpg');
    });
  });

  group('竖版无字原画 portraitBackdropRef 零额外请求优选与锁定保护', () {
    test('仅采纳 TMDB iso_639_1 == null 的无字竖版海报，严禁误选带字海报', () {
      const textedZh = TmdbArtworkImage(
        filePath: '/texted_zh_2k.jpg',
        isoLanguage: 'zh',
        isoCountry: 'CN',
        width: 2000,
        height: 3000,
        voteAverage: 9.0,
        voteCount: 30,
      );
      const textlessLowRes = TmdbArtworkImage(
        filePath: '/textless_low.jpg',
        isoLanguage: null,
        width: 500,
        height: 750,
        voteAverage: 8.5,
        voteCount: 20,
      );
      const textless2k = TmdbArtworkImage(
        filePath: '/textless_2k.jpg',
        isoLanguage: null,
        width: 2000,
        height: 3000,
        voteAverage: 5.8,
        voteCount: 6,
      );

      expect(
        ArtworkRanker.selectBestTextlessPortraitBackdrop(const [textedZh]),
        isNull,
      );
      expect(
        ArtworkRanker.selectBestTextlessPortraitBackdrop(const [
          textedZh,
          textlessLowRes,
          textless2k,
        ]),
        '/textless_2k.jpg',
      );
    });

    test('Fanart 整包优先挑选当前季 00 无字竖图，次选系列主无字竖图', () {
      const bundle = FanartArtworkResult(
        posters: [
          FanartPosterCandidate(
            id: 'p_ja',
            url: 'https://assets.fanart.tv/ja.jpg',
            lang: 'ja',
            likes: 20,
          ),
          FanartPosterCandidate(
            id: 'p_series_00',
            url: 'https://assets.fanart.tv/series_00.jpg',
            lang: '00',
            likes: 10,
          ),
          FanartPosterCandidate(
            id: 'p_s2_00',
            url: 'https://assets.fanart.tv/s2_00.jpg',
            lang: '00',
            season: 2,
            likes: 3,
          ),
        ],
      );

      expect(
        ArtworkRanker.selectFanartTextlessPortraitBackdrop(
          bundle,
          matchedSeason: 2,
        ),
        'https://assets.fanart.tv/s2_00.jpg',
      );
      expect(
        ArtworkRanker.selectFanartTextlessPortraitBackdrop(
          bundle,
          matchedSeason: 1,
        ),
        'https://assets.fanart.tv/series_00.jpg',
      );
    });

    test('mergeWorkWithLocks 严格保护 portraitBackdropLocked 人工锁定原画不被重扫覆盖', () {
      const existing = Work(
        id: 'w_lock_portrait',
        title: '测试作品',
        portraitBackdropPath: 'photos/custom_portrait.jpg',
        portraitBackdropLocked: true,
        scrapeStatus: ScrapeStatus.matched,
      );
      const candidate = Work(
        id: 'w_lock_portrait',
        title: '测试作品',
        portraitBackdropPath: '/new_remote_textless.jpg',
        portraitBackdropLocked: false,
        scrapeStatus: ScrapeStatus.matched,
      );

      final merged = ScrapeWorkPersister.mergeWorkWithLocks(
        existing: existing,
        candidate: candidate,
      );
      expect(merged.portraitBackdropPath, 'photos/custom_portrait.jpg');
      expect(merged.portraitBackdropLocked, isTrue);

      final resetMerged = ScrapeWorkPersister.mergeWorkWithLocks(
        existing: existing,
        candidate: candidate,
        resetManualLocks: true,
      );
      expect(resetMerged.portraitBackdropPath, '/new_remote_textless.jpg');
    });
  });
}
