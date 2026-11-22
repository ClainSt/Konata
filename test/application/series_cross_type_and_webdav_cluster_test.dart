import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:konata/application/scraping/release_group_work_merger.dart';
import 'package:konata/application/scraping/series_auto_linker.dart';
import 'package:konata/domain/models/episode.dart';
import 'package:konata/domain/models/media_source.dart';
import 'package:konata/domain/models/media_variant.dart';
import 'package:konata/domain/models/network_config.dart';
import 'package:konata/domain/models/work.dart';
import 'package:konata/domain/scraping/multi_work_splitter.dart';
import 'package:konata/domain/scraping/search_query_sanitizer.dart';
import 'package:konata/infrastructure/database/drift_library_repository.dart';
import 'package:konata/infrastructure/database/konata_database.dart';
import 'package:konata/infrastructure/network/bangumi_service.dart';
import 'package:konata/infrastructure/network/priority_http_scheduler.dart';
import 'package:konata/infrastructure/network/tmdb_http_client.dart';
import 'package:konata/infrastructure/network/tmdb_service.dart';

void main() {
  group('WebDAV 同系列 TV+Movie 自动归组与 ClearLogo 交叉纠偏测试', () {
    late KonataDatabase db;
    late DriftLibraryRepository repo;

    setUp(() async {
      db = KonataDatabase(NativeDatabase.memory());
      repo = DriftLibraryRepository(db);
      await repo.upsertMediaSource(
        const MediaSource(
          id: 'src_webdav',
          kind: MediaSourceKind.webdav,
          label: '云盘番剧',
          location: 'http://192.168.1.2:29798/dav',
        ),
      );
    });

    tearDown(() async {
      await db.close();
    });

    test('同源同 workDir（加速世界系列）TV 正片与剧场版自动归入同一系列，并清洗误挂剧场版 ClearLogo', () async {
      const accelLogo = '/wsQCRIHeVQJlO0MgU2oA3z6hgQd.png';
      await repo.upsertWork(
        const Work(
          id: 'w_aw_tv',
          title: '加速世界',
          originalTitle: 'アクセル・ワールド',
          tmdbId: 43167,
          tmdbMediaType: TmdbMediaType.tv,
          bangumiId: 23685,
          matchedSeason: 1,
          year: 2012,
          logoPath: accelLogo,
          scrapeStatus: ScrapeStatus.matched,
        ),
      );
      await repo.upsertMediaVariant(
        const MediaVariant(
          id: 'v_aw_tv_1',
          workId: 'w_aw_tv',
          sourceId: 'src_webdav',
          relativePath: '未添加TMDB ID/加速世界系列/[VCB-S] Accel World 01.mkv',
          fileName: '[VCB-S] Accel World 01.mkv',
          fileSize: 1024 * 1024,
        ),
      );

      await repo.upsertWork(
        const Work(
          id: 'w_aw_movie',
          title: '加速世界：无限超频',
          originalTitle: 'アクセル・ワールド INFINITE∞BURST',
          tmdbId: 381873,
          tmdbMediaType: TmdbMediaType.movie,
          bangumiId: 148095,
          year: 2016,
          logoPath: null,
          scrapeStatus: ScrapeStatus.matched,
        ),
      );
      await repo.upsertMediaVariant(
        const MediaVariant(
          id: 'v_aw_movie_1',
          workId: 'w_aw_movie',
          sourceId: 'src_webdav',
          relativePath:
              '未添加TMDB ID/加速世界系列/[VCB-S] Accel World Infinite Burst.mkv',
          fileName: '[VCB-S] Accel World Infinite Burst.mkv',
          fileSize: 2048 * 1024,
        ),
      );

      final changed = await SeriesAutoLinker.reconcileAll(repository: repo);
      expect(changed, isTrue);

      final tvUpdated = await repo.findWorkById('w_aw_tv');
      final movieUpdated = await repo.findWorkById('w_aw_movie');
      expect(tvUpdated, isNotNull);
      expect(movieUpdated, isNotNull);

      expect(tvUpdated!.seriesId, isNotNull);
      expect(movieUpdated!.seriesId, equals(tvUpdated.seriesId));
      expect(tvUpdated.seriesOrder, equals(1));
      expect(movieUpdated.seriesOrder, equals(2));
      expect(movieUpdated.seriesLabel, equals('剧场版'));

      // 误上传在 TV 43167 下的剧场版 ClearLogo 应被清除，并归还给剧场版 381873
      expect(tvUpdated.logoPath, isNull);
      expect(movieUpdated.logoPath, equals(accelLogo));
    });

    test('分处不同目录时可通过跨类型主标题归一化前缀将 TV 与剧场版自动归组，且不误伤日常/日常生活', () async {
      await repo.upsertWork(
        const Work(
          id: 'w_tv_cross',
          title: '加速世界',
          originalTitle: 'アクセル・ワールド',
          tmdbId: 43167,
          tmdbMediaType: TmdbMediaType.tv,
          matchedSeason: 1,
          year: 2012,
          scrapeStatus: ScrapeStatus.matched,
        ),
      );
      await repo.upsertMediaVariant(
        const MediaVariant(
          id: 'v_cross_1',
          workId: 'w_tv_cross',
          sourceId: 'src_webdav',
          relativePath: 'Anime/Accel World/01.mkv',
          fileName: '01.mkv',
          fileSize: 1000,
        ),
      );

      await repo.upsertWork(
        const Work(
          id: 'w_mv_cross',
          title: '加速世界：无限超频',
          originalTitle: 'アクセル・ワールド INFINITE∞BURST',
          tmdbId: 381873,
          tmdbMediaType: TmdbMediaType.movie,
          year: 2016,
          scrapeStatus: ScrapeStatus.matched,
        ),
      );
      await repo.upsertMediaVariant(
        const MediaVariant(
          id: 'v_cross_2',
          workId: 'w_mv_cross',
          sourceId: 'src_webdav',
          relativePath: 'Movies/Accel World Infinite Burst/Movie.mkv',
          fileName: 'Movie.mkv',
          fileSize: 2000,
        ),
      );

      // 负向边界对照：《日常》与《日常生活》（无副标题边界符，严禁误归并）
      await repo.upsertWork(
        const Work(
          id: 'w_nichijou',
          title: '日常',
          originalTitle: '日常',
          tmdbId: 39127,
          tmdbMediaType: TmdbMediaType.tv,
          matchedSeason: 1,
          year: 2011,
          scrapeStatus: ScrapeStatus.matched,
        ),
      );
      await repo.upsertMediaVariant(
        const MediaVariant(
          id: 'v_n1',
          workId: 'w_nichijou',
          sourceId: 'src_webdav',
          relativePath: 'Anime/Nichijou/01.mkv',
          fileName: '01.mkv',
          fileSize: 500,
        ),
      );

      await repo.upsertWork(
        const Work(
          id: 'w_daily',
          title: '日常生活',
          originalTitle: '日常生活',
          tmdbId: 999999,
          tmdbMediaType: TmdbMediaType.movie,
          year: 2020,
          scrapeStatus: ScrapeStatus.matched,
        ),
      );
      await repo.upsertMediaVariant(
        const MediaVariant(
          id: 'v_n2',
          workId: 'w_daily',
          sourceId: 'src_webdav',
          relativePath: 'Movies/DailyLife/movie.mkv',
          fileName: 'movie.mkv',
          fileSize: 600,
        ),
      );

      await SeriesAutoLinker.reconcileAll(repository: repo);

      final tvCross = await repo.findWorkById('w_tv_cross');
      final mvCross = await repo.findWorkById('w_mv_cross');
      final nichijou = await repo.findWorkById('w_nichijou');
      final daily = await repo.findWorkById('w_daily');

      expect(tvCross?.seriesId, isNotNull);
      expect(mvCross?.seriesId, equals(tvCross!.seriesId));
      expect(nichijou?.seriesId, isNull);
      expect(daily?.seriesId, isNull);
    });

    test('TmdbService.getWorkDetail 获取 tv/43167 时主动过滤已知误传剧场版 Logo', () async {
      final client = MockClient((request) async {
        expect(
          request.url.queryParameters['include_image_language'],
          'zh,ja,en,null',
        );
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'id': 43167,
              'name': '加速世界',
              'original_name': 'アクセル・ワールド',
              'images': {
                'logos': [
                  {
                    'iso_639_1': 'ja',
                    'file_path': '/wsQCRIHeVQJlO0MgU2oA3z6hgQd.png',
                    'vote_average': 0.0,
                    'vote_count': 0,
                  },
                ],
              },
            }),
          ),
          200,
        );
      });
      final service = TmdbService(
        httpClient: TmdbHttpClient(
          config: const TmdbNetworkConfig(),
          scheduler: PriorityHttpScheduler(),
          httpClient: client,
        ),
      );

      final detail = await service.getWorkDetail(43167, TmdbMediaType.tv);
      expect(detail, isNotNull);
      expect(detail!.logoPath, isNull);
      expect(detail.candidateLogos, hasLength(1));
    });

    test('局部扫描收尾跳过独立电影与未变更系列，零冗余 TMDB 请求且仍对本次变更 TV+电影系列纠偏', () async {
      // 1. 预置 8 部独立电影（无 TV 成员）与 1 组早已编组完成的无关 TV+电影系列。
      for (var i = 1; i <= 8; i++) {
        await repo.upsertWork(
          Work(
            id: 'w_solo_mv_$i',
            title: '独立剧场版 $i',
            tmdbId: 50000 + i,
            tmdbMediaType: TmdbMediaType.movie,
            year: 2015 + i,
            scrapeStatus: ScrapeStatus.matched,
          ),
        );
      }
      await repo.upsertWork(
        const Work(
          id: 'w_old_tv',
          title: '老系列主番',
          tmdbId: 60001,
          tmdbMediaType: TmdbMediaType.tv,
          matchedSeason: 1,
          logoPath: '/old_tv_logo.png',
          seriesId: 'series_existing_old',
          seriesOrder: 1,
          seriesLabel: '第 1 季',
          scrapeStatus: ScrapeStatus.matched,
        ),
      );
      await repo.upsertWork(
        const Work(
          id: 'w_old_mv',
          title: '老系列剧场版',
          tmdbId: 60002,
          tmdbMediaType: TmdbMediaType.movie,
          logoPath: '/old_mv_logo.png',
          seriesId: 'series_existing_old',
          seriesOrder: 2,
          seriesLabel: '剧场版',
          scrapeStatus: ScrapeStatus.matched,
        ),
      );

      // 2. 本次仅局部扫描新增一部纯 TV 作品（focusWorkIds 仅含该作品）。
      await repo.upsertWork(
        const Work(
          id: 'w_focus_tv_only',
          title: '弹丸论破3 绝望篇',
          tmdbId: 65951,
          tmdbMediaType: TmdbMediaType.tv,
          matchedSeason: 1,
          logoPath: '/dr3_logo.png',
          scrapeStatus: ScrapeStatus.matched,
        ),
      );

      final requestedPaths = <String>[];
      final tmdbClient = MockClient((request) async {
        requestedPaths.add(request.url.path);
        if (request.url.path.endsWith('/movie/88801')) {
          return http.Response.bytes(
            utf8.encode(
              jsonEncode({
                'id': 88801,
                'title': '新系列剧场版',
                'images': {
                  'logos': [
                    {
                      'iso_639_1': 'ja',
                      'file_path': '/dup_movie_logo.png',
                      'vote_average': 5.0,
                      'vote_count': 10,
                    },
                  ],
                },
              }),
            ),
            200,
          );
        }
        if (request.url.path.endsWith('/tv/77701')) {
          return http.Response.bytes(
            utf8.encode(
              jsonEncode({
                'id': 77701,
                'name': '新系列主番',
                'images': {
                  'logos': [
                    {
                      'iso_639_1': 'ja',
                      'file_path': '/dup_movie_logo.png',
                      'vote_average': 5.0,
                      'vote_count': 10,
                    },
                    {
                      'iso_639_1': 'ja',
                      'file_path': '/real_tv_logo.png',
                      'vote_average': 4.0,
                      'vote_count': 6,
                    },
                  ],
                },
              }),
            ),
            200,
          );
        }
        return http.Response('{}', 404);
      });
      final tmdbService = TmdbService(
        httpClient: TmdbHttpClient(
          config: const TmdbNetworkConfig(credential: 'v3_test'),
          scheduler: PriorityHttpScheduler(maxRetries: 0),
          httpClient: tmdbClient,
        ),
      );

      await SeriesAutoLinker.reconcileAll(
        repository: repo,
        tmdbService: tmdbService,
        focusWorkIds: const {'w_focus_tv_only'},
      );
      // 独立电影与未变更系列不得触发任何 TMDB 详情请求。
      expect(requestedPaths, isEmpty);

      // 3. 当本次变更的 TV 与剧场版归入同系列且 TV 误挂了剧场版 Logo 时，仅探测该系列成员并完成纠偏。
      await repo.upsertWork(
        const Work(
          id: 'w_hit_tv',
          title: '新系列主番',
          tmdbId: 77701,
          tmdbMediaType: TmdbMediaType.tv,
          matchedSeason: 1,
          logoPath: '/dup_movie_logo.png',
          scrapeStatus: ScrapeStatus.matched,
        ),
      );
      await repo.upsertMediaVariant(
        const MediaVariant(
          id: 'v_hit_tv_1',
          workId: 'w_hit_tv',
          sourceId: 'src_webdav',
          relativePath: '新系列合集/01.mkv',
          fileName: '01.mkv',
          fileSize: 1000,
        ),
      );
      await repo.upsertWork(
        const Work(
          id: 'w_hit_mv',
          title: '新系列剧场版',
          tmdbId: 88801,
          tmdbMediaType: TmdbMediaType.movie,
          logoPath: null,
          scrapeStatus: ScrapeStatus.matched,
        ),
      );
      await repo.upsertMediaVariant(
        const MediaVariant(
          id: 'v_hit_mv_1',
          workId: 'w_hit_mv',
          sourceId: 'src_webdav',
          relativePath: '新系列合集/Movie.mkv',
          fileName: 'Movie.mkv',
          fileSize: 2000,
        ),
      );

      await SeriesAutoLinker.reconcileAll(
        repository: repo,
        tmdbService: tmdbService,
        focusWorkIds: const {'w_hit_tv', 'w_hit_mv'},
      );

      expect(
        requestedPaths,
        containsAll(<String>['/3/movie/88801', '/3/tv/77701']),
      );
      expect(
        requestedPaths.where((p) => p.contains('5000') || p.contains('6000')),
        isEmpty,
      );
      final healedTv = await repo.findWorkById('w_hit_tv');
      final healedMv = await repo.findWorkById('w_hit_mv');
      expect(healedTv?.logoPath, equals('/real_tv_logo.png'));
      expect(healedMv?.logoPath, equals('/dup_movie_logo.png'));
    });

    test('收尾阶段触发取消后立即跳过剩余 Bangumi 与 TMDB 在线请求', () async {
      await repo.upsertWork(
        const Work(
          id: 'w_cancel_1',
          title: '取消测试番 1',
          bangumiId: 901,
          tmdbId: 90101,
          tmdbMediaType: TmdbMediaType.tv,
          logoPath: '/x.png',
          scrapeStatus: ScrapeStatus.matched,
        ),
      );
      await repo.upsertWork(
        const Work(
          id: 'w_cancel_2',
          title: '取消测试番 1 剧场版',
          bangumiId: 902,
          tmdbId: 90102,
          tmdbMediaType: TmdbMediaType.movie,
          scrapeStatus: ScrapeStatus.matched,
        ),
      );
      var networkCalls = 0;
      final client = MockClient((_) async {
        networkCalls++;
        return http.Response('[]', 200);
      });
      final httpClient = TmdbHttpClient(
        config: const TmdbNetworkConfig(credential: 'v3_test'),
        scheduler: PriorityHttpScheduler(maxRetries: 0),
        httpClient: client,
      );
      await SeriesAutoLinker.reconcileAll(
        repository: repo,
        bangumiService: BangumiService(httpClient: httpClient),
        tmdbService: TmdbService(httpClient: httpClient),
        isCancelled: () => true,
      );
      expect(networkCalls, equals(0));
    });

    test('窈窕淑女刮削修复：Bangumi 剧场版回退搜索剥离前缀不搜空泛词、双部 Movie.1/2 识别前后篇且 Bangumi 单源剧场版标签不回退为第N季', () async {
      // 1. SearchQuerySanitizer：剥离「剧场版 / 劇場版」前缀并输出核心作品词，绝不生成裸「剧场版」查询词。
      final zhQueries = SearchQuerySanitizer.buildBangumiFallbackQueries(
        '剧场版 窈窕淑女 后篇 ~花之东京大浪漫~',
      );
      expect(zhQueries, contains('窈窕淑女 后篇 花之东京大浪漫'));
      expect(zhQueries, contains('窈窕淑女'));
      expect(zhQueries.contains('剧场版'), isFalse);
      final jpQueries = SearchQuerySanitizer.buildBangumiFallbackQueries(
        '劇場版 はいからさんが通る 前編 ～紅緒、花の17歳～',
      );
      expect(jpQueries, contains('はいからさんが通る 前編 紅緒、花の17歳'));
      expect(jpQueries.contains('劇場版'), isFalse);

      // 2. MultiWorkSplitter：TV + Movie.1.2017 + Movie.2.2018 混放目录中，Movie.1/2 识别为前后篇且不向 1978 TV 泄词。
      final clusters = MultiWorkSplitter.splitEntries(
        '未添加TMDB ID/窈窕淑女系列/窈窕淑女 (1978) {tmdb-45229}',
        [
          for (var ep = 1; ep <= 12; ep++)
            (
              relativePath:
                  '未添加TMDB ID/窈窕淑女系列/窈窕淑女 (1978) {tmdb-45229}/Haikara-san.ga.Tooru.1978.S01E${ep.toString().padLeft(2, '0')}.1080p.BDRip.x265.FLAC-CoolFansSub.mkv',
              name:
                  'Haikara-san.ga.Tooru.1978.S01E${ep.toString().padLeft(2, '0')}.1080p.BDRip.x265.FLAC-CoolFansSub.mkv',
              size: 2000 * 1024 * 1024,
              assetId: 'tv_$ep',
            ),
          (
            relativePath:
                '未添加TMDB ID/窈窕淑女系列/窈窕淑女 (1978) {tmdb-45229}/Haikara-San.Here.Comes.Miss.Modern.Movie.1.2017.1080p.BDRip.x265.FLAC-CoolFansSub.mkv',
            name:
                'Haikara-San.Here.Comes.Miss.Modern.Movie.1.2017.1080p.BDRip.x265.FLAC-CoolFansSub.mkv',
            size: 5000 * 1024 * 1024,
            assetId: 'mv1',
          ),
          (
            relativePath:
                '未添加TMDB ID/窈窕淑女系列/窈窕淑女 (1978) {tmdb-45229}/Haikara-San.Here.Comes.Miss.Modern.Movie.2.2018.1080p.BDRip.x265.FLAC-CoolFansSub.mkv',
            name:
                'Haikara-San.Here.Comes.Miss.Modern.Movie.2.2018.1080p.BDRip.x265.FLAC-CoolFansSub.mkv',
            size: 5500 * 1024 * 1024,
            assetId: 'mv2',
          ),
        ],
      );
      expect(clusters, hasLength(3));
      final mv1Cluster = clusters.firstWhere((c) => c.inventory.year == 2017);
      final mv2Cluster = clusters.firstWhere((c) => c.inventory.year == 2018);
      expect(mv1Cluster.inventory.tmdbId, isNull);
      expect(mv2Cluster.inventory.tmdbId, isNull);
      expect(mv1Cluster.inventory.titleHints, contains('窈窕淑女 前篇'));
      expect(
        mv1Cluster.inventory.titleHints,
        contains('Haikara-San Here Comes Miss Modern Part 1'),
      );
      expect(
        mv1Cluster.inventory.titleHints.contains(
          'Haikara-San Here Comes Miss Modern',
        ),
        isFalse,
      );
      expect(mv2Cluster.inventory.titleHints, contains('窈窕淑女 后篇'));
      expect(
        mv2Cluster.inventory.titleHints,
        contains('Haikara-San Here Comes Miss Modern Part 2'),
      );

      // 3. SeriesAutoLinker：仅命中 Bangumi 的剧场版自动归组后标注为「剧场版」，不落入「第 3 季」。
      await repo.upsertWork(
        const Work(
          id: 'w_haikara_tv',
          title: '窈窕淑女',
          tmdbId: 45229,
          tmdbMediaType: TmdbMediaType.tv,
          bangumiId: 72359,
          matchedSeason: 1,
          year: 1978,
          scrapeStatus: ScrapeStatus.matched,
        ),
      );
      await repo.upsertWork(
        const Work(
          id: 'w_haikara_bgm_mv1',
          title: '剧场版 窈窕淑女 前篇 ~红绪，花样的17岁~',
          bangumiId: 184021,
          year: 2017,
          scrapeStatus: ScrapeStatus.matched,
        ),
      );
      await repo.upsertMediaVariant(
        const MediaVariant(
          id: 'v_htv',
          workId: 'w_haikara_tv',
          sourceId: 'src_webdav',
          relativePath: '窈窕淑女系列/窈窕淑女 (1978)/ep01.mkv',
          fileName: 'ep01.mkv',
          fileSize: 1000,
        ),
      );
      await repo.upsertMediaVariant(
        const MediaVariant(
          id: 'v_hmv1',
          workId: 'w_haikara_bgm_mv1',
          sourceId: 'src_webdav',
          relativePath: '窈窕淑女系列/剧场版 窈窕淑女/zenpen.mkv',
          fileName: 'zenpen.mkv',
          fileSize: 5000,
        ),
      );
      await SeriesAutoLinker.reconcileAll(repository: repo);
      final bgmMv1 = await repo.findWorkById('w_haikara_bgm_mv1');
      expect(bgmMv1?.seriesLabel, equals('剧场版'));
    });

    test('方案 A 同源强身份自动归并：跨目录/拆簇双版本剧场版自动合并为多版本正片并互补双源元数据，严格保持跨源与锁定隔离', () async {
      await repo.upsertMediaSource(
        const MediaSource(
          id: 'src_local_other',
          kind: MediaSourceKind.local,
          label: '本地硬盘',
          location: 'D:/Anime',
        ),
      );

      // 同源目录 A（CoolFansSub 拆簇）：仅有 TMDB 剧场版元数据 + 背景图 + 1 个视频 + 1 个特典
      await repo.upsertWork(
        const Work(
          id: 'w_coolfans_mv2',
          title: '窈窕淑女 后篇：花之东京大浪漫',
          tmdbId: 539441,
          tmdbMediaType: TmdbMediaType.movie,
          bangumiId: 197654,
          year: 2018,
          overview: 'TMDB 中文简介',
          backdropPath: '/haikara_mv2_bg.jpg',
          posterPath: '/haikara_mv2_poster.jpg',
          scrapeStatus: ScrapeStatus.matched,
        ),
      );
      await repo.upsertEpisode(
        const Episode(
          id: 'ep_cool_main',
          workId: 'w_coolfans_mv2',
          seasonNumber: 1,
          episodeNumber: null,
          category: EpisodeCategory.main,
          title: '窈窕淑女 后篇',
        ),
      );
      await repo.upsertEpisode(
        const Episode(
          id: 'ep_cool_sp',
          workId: 'w_coolfans_mv2',
          seasonNumber: 0,
          episodeNumber: 1,
          category: EpisodeCategory.extra,
          extraType: ExtraKind.sp,
          title: 'SP01',
        ),
      );
      await repo.upsertMediaVariant(
        const MediaVariant(
          id: 'var_cool_main',
          workId: 'w_coolfans_mv2',
          episodeId: 'ep_cool_main',
          sourceId: 'src_webdav',
          relativePath: '窈窕淑女系列/窈窕淑女 (1978)/Movie.2.2018-CoolFansSub.mkv',
          fileName: 'Movie.2.2018-CoolFansSub.mkv',
          fileSize: 4000,
          assetKind: AssetKind.video,
        ),
      );
      await repo.upsertMediaVariant(
        const MediaVariant(
          id: 'var_cool_sp',
          workId: 'w_coolfans_mv2',
          episodeId: 'ep_cool_sp',
          sourceId: 'src_webdav',
          relativePath: '窈窕淑女系列/窈窕淑女 (1978)/Extras/Movie.2.2018.SP01.mkv',
          fileName: 'Movie.2.2018.SP01.mkv',
          fileSize: 200,
          assetKind: AssetKind.video,
        ),
      );

      // 同源目录 B（Nekomoe 拆簇）：同 Bangumi ID + Bangumi 评分 + 猫萌正片 + 特典 + CD + Scan
      await repo.upsertWork(
        const Work(
          id: 'w_nekomoe_mv2',
          title: '剧场版 窈窕淑女 后篇 ~花之东京大浪漫~',
          bangumiId: 197654,
          bangumiScore: 5.3,
          year: 2018,
          scrapeStatus: ScrapeStatus.matched,
        ),
      );
      await repo.upsertEpisode(
        const Episode(
          id: 'ep_neko_main',
          workId: 'w_nekomoe_mv2',
          seasonNumber: 1,
          episodeNumber: null,
          category: EpisodeCategory.main,
          title: '剧场版 窈窕淑女 后篇',
        ),
      );
      await repo.upsertEpisode(
        const Episode(
          id: 'ep_neko_sp',
          workId: 'w_nekomoe_mv2',
          seasonNumber: 0,
          episodeNumber: 1,
          category: EpisodeCategory.extra,
          extraType: ExtraKind.pv,
          title: 'CM01',
        ),
      );
      await repo.upsertMediaVariant(
        const MediaVariant(
          id: 'var_neko_main',
          workId: 'w_nekomoe_mv2',
          episodeId: 'ep_neko_main',
          sourceId: 'src_webdav',
          relativePath: '窈窕淑女系列/剧场版 窈窕淑女/[Nekomoe] kouhen.mkv',
          fileName: '[Nekomoe] kouhen.mkv',
          fileSize: 6000,
          assetKind: AssetKind.video,
        ),
      );
      await repo.upsertMediaVariant(
        const MediaVariant(
          id: 'var_neko_sp',
          workId: 'w_nekomoe_mv2',
          episodeId: 'ep_neko_sp',
          sourceId: 'src_webdav',
          relativePath: '窈窕淑女系列/剧场版 窈窕淑女/SPs/[Nekomoe] kouhen CM01.mkv',
          fileName: '[Nekomoe] kouhen CM01.mkv',
          fileSize: 100,
          assetKind: AssetKind.video,
        ),
      );
      await repo.upsertMediaVariant(
        const MediaVariant(
          id: 'var_neko_cd',
          workId: 'w_nekomoe_mv2',
          sourceId: 'src_webdav',
          relativePath: '窈窕淑女系列/剧场版 窈窕淑女/CDs/OST.flac',
          fileName: 'OST.flac',
          fileSize: 50,
          assetKind: AssetKind.cdAlbum,
        ),
      );
      await repo.upsertMediaVariant(
        const MediaVariant(
          id: 'var_neko_scan',
          workId: 'w_nekomoe_mv2',
          sourceId: 'src_webdav',
          relativePath: '窈窕淑女系列/剧场版 窈窕淑女/Scans/01.png',
          fileName: '01.png',
          fileSize: 30,
          assetKind: AssetKind.scanGallery,
        ),
      );

      // 异源同身份作品：必须保持独立，严禁跨源合并
      await repo.upsertWork(
        const Work(
          id: 'w_other_source_mv2',
          title: '窈窕淑女 后篇：花之东京大浪漫',
          tmdbId: 539441,
          tmdbMediaType: TmdbMediaType.movie,
          bangumiId: 197654,
          year: 2018,
          scrapeStatus: ScrapeStatus.matched,
        ),
      );
      await repo.upsertMediaVariant(
        const MediaVariant(
          id: 'var_other_main',
          workId: 'w_other_source_mv2',
          sourceId: 'src_local_other',
          relativePath: '窈窕淑女 后篇/local.mkv',
          fileName: 'local.mkv',
          fileSize: 4000,
          assetKind: AssetKind.video,
        ),
      );

      final mergeRes = await ReleaseGroupWorkMerger.mergeSameSourceIdentityWorks(
        repository: repo,
        sourceId: 'src_webdav',
      );
      expect(mergeRes.absorbedIds, equals({'w_nekomoe_mv2'}));
      expect(mergeRes.survivingTargetIds, equals({'w_coolfans_mv2'}));

      // 原猫萌卡已被吸收清理，异源卡保持独立
      expect(await repo.findWorkById('w_nekomoe_mv2'), isNull);
      expect(await repo.findWorkById('w_other_source_mv2'), isNotNull);

      // 目标主卡自动补齐 Bangumi 评分并保留 TMDB 简介与背景图
      final merged = (await repo.findWorkById('w_coolfans_mv2'))!;
      expect(merged.tmdbId, equals(539441));
      expect(merged.bangumiId, equals(197654));
      expect(merged.bangumiScore, equals(5.3));
      expect(merged.backdropPath, equals('/haikara_mv2_bg.jpg'));

      // 两版剧场版正片汇聚于唯一 EpisodeCategory.main 正片下作为双版本，绝不误归入特典
      final episodes = await repo.getEpisodesByWork(merged.id);
      final mainEps = episodes
          .where((e) => e.category == EpisodeCategory.main)
          .toList();
      final extraEps = episodes
          .where((e) => e.category == EpisodeCategory.extra)
          .toList();
      expect(mainEps, hasLength(1));
      expect(extraEps, hasLength(2));

      final variants = await repo.getVariantsByWork(merged.id);
      final mainVariants = variants
          .where((v) => v.episodeId == mainEps.single.id)
          .toList();
      expect(mainVariants, hasLength(2));
      expect(
        mainVariants.map((v) => v.fileName).toSet(),
        equals({'Movie.2.2018-CoolFansSub.mkv', '[Nekomoe] kouhen.mkv'}),
      );
      expect(
        variants.where((v) => v.assetKind == AssetKind.cdAlbum),
        hasLength(1),
      );
      expect(
        variants.where((v) => v.assetKind == AssetKind.scanGallery),
        hasLength(1),
      );
    });
  });
}
