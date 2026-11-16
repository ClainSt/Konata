import 'dart:convert';
import 'dart:io';

import 'package:ccplayer/application/providers/library_providers.dart';
import 'package:ccplayer/application/scraping/scrape_compute_worker.dart';
import 'package:ccplayer/application/scraping/scrape_orchestrator.dart';
import 'package:ccplayer/domain/matching/episode_title_formatter.dart';
import 'package:ccplayer/domain/models/episode.dart';
import 'package:ccplayer/domain/models/media_source.dart';
import 'package:ccplayer/domain/models/network_config.dart';
import 'package:ccplayer/domain/models/work.dart';
import 'package:ccplayer/infrastructure/database/drift_library_repository.dart';
import 'package:ccplayer/infrastructure/database/konata_database.dart';
import 'package:ccplayer/infrastructure/network/priority_http_scheduler.dart';
import 'package:ccplayer/infrastructure/network/tmdb_http_client.dart';
import 'package:ccplayer/infrastructure/network/tmdb_service.dart';
import 'package:ccplayer/infrastructure/sources/local_source_gateway.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

http.Response _jsonRes(Object data, [int statusCode = 200]) => http.Response.bytes(
  utf8.encode(jsonEncode(data)),
  statusCode,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);

void main() {
  group('Phase 5 全链路 1:1 无损刮削回归验收', () {
    late Directory tempRoot;
    late KonataDatabase db;
    late DriftLibraryRepository repo;

    setUp(() async {
      tempRoot = await Directory.systemTemp.createTemp('konata_p5_parity_');
      db = KonataDatabase(NativeDatabase.memory());
      repo = DriftLibraryRepository(db);
    });

    tearDown(() async {
      await db.close();
      if (await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
    });

    Future<void> touchFile(String relPath) async {
      final f = File(p.joinAll([tempRoot.path, ...relPath.split('/')]));
      await f.parent.create(recursive: true);
      await f.writeAsBytes(const [0]);
    }

    test('加速世界 TV+Movie 自动拆分 + EX OVA Season 0 映射 + 单集剧场版 episodeNumber=null + 旧卡清理', () async {
      const rootFolder = '加速世界 TV+Movie';
      for (var i = 1; i <= 24; i++) {
        final ep = i.toString().padLeft(2, '0');
        await touchFile('$rootFolder/[VCB-Studio] Accel World [$ep][1080p].mkv');
      }
      await touchFile('$rootFolder/[VCB-Studio] Accel World [EX01][1080p].mkv');
      await touchFile('$rootFolder/[VCB-Studio] Accel World [EX02][1080p].mkv');
      await touchFile('$rootFolder/SPs/[VCB-Studio] Accel World [NCOP01].mkv');
      await touchFile(
        '$rootFolder/[VCB-Studio] Accel World - Infinite Burst [1080p].mkv',
      );

      final source = MediaSource(
        id: 'src_aw',
        kind: MediaSourceKind.local,
        label: '合集盘',
        location: tempRoot.path,
      );
      await repo.upsertMediaSource(source);

      // 预置历史遗留未拆分白板旧卡片，验证重扫拆簇后自动清理 0 遗留
      await repo.upsertWork(
        const Work(
          id: 'stale-unsplit-aw',
          title: '加速世界 TV+Movie',
          scrapeStatus: ScrapeStatus.unmatched,
        ),
      );

      final mockClient = MockClient((req) async {
        final path = req.url.path;
        final query = (req.url.queryParameters['query'] ?? '').toLowerCase();

        if (path.endsWith('/search/tv') &&
            !query.contains('infinite burst') &&
            (query.contains('accel world') || query.contains('加速世界'))) {
          return _jsonRes({
            'results': [
              {
                'id': 43167,
                'name': '加速世界',
                'original_name': 'アクセル・ワールド',
                'first_air_date': '2012-04-07',
              },
            ],
          });
        }
        if (path.endsWith('/search/movie') && query.contains('infinite burst')) {
          return _jsonRes({
            'results': [
              {
                'id': 391751,
                'title': '加速世界 Infinite Burst',
                'original_title': 'アクセル・ワールド INFINITE∞BURST',
                'release_date': '2016-07-23',
              },
            ],
          });
        }
        if (path.endsWith('/search/tv') || path.endsWith('/search/movie')) {
          return _jsonRes({'results': []});
        }
        if (path.endsWith('/tv/43167')) {
          return _jsonRes({
            'id': 43167,
            'name': '加速世界',
            'original_name': 'アクセル・ワールド',
            'first_air_date': '2012-04-07',
            'poster_path': '/aw-tv.jpg',
            'alternative_titles': {
              'results': [
                {'title': 'Accel World'},
              ],
            },
            'seasons': [
              {'season_number': 0, 'name': '特别篇', 'episode_count': 2},
              {
                'season_number': 1,
                'name': '第 1 季',
                'episode_count': 24,
                'air_date': '2012-04-07',
                'poster_path': '/aw-s1.jpg',
              },
            ],
          });
        }
        if (path.endsWith('/tv/43167/season/1')) {
          return _jsonRes({
            'season_number': 1,
            'name': '第 1 季',
            'air_date': '2012-04-07',
            'poster_path': '/aw-s1.jpg',
            'episodes': [
              for (var i = 1; i <= 24; i++)
                {'episode_number': i, 'name': '第 $i 话'},
            ],
          });
        }
        if (path.endsWith('/tv/43167/season/0')) {
          return _jsonRes({
            'season_number': 0,
            'name': '特别篇',
            'episodes': [
              {'episode_number': 1, 'name': 'EX01 银翼觉醒'},
              {'episode_number': 2, 'name': 'EX02 温泉回'},
            ],
          });
        }
        if (path.endsWith('/movie/391751')) {
          return _jsonRes({
            'id': 391751,
            'title': '加速世界 Infinite Burst',
            'original_title': 'アクセル・ワールド INFINITE∞BURST',
            'release_date': '2016-07-23',
            'poster_path': '/aw-movie.jpg',
            'alternative_titles': {
              'titles': [
                {'title': 'Accel World: Infinite Burst'},
              ],
            },
          });
        }
        return http.Response('{}', 404);
      });

      final orchestrator = ScrapeOrchestrator(
        repository: repo,
        tmdbService: TmdbService(
          httpClient: TmdbHttpClient(
            config: const TmdbNetworkConfig(credential: 'v3_test'),
            scheduler: PriorityHttpScheduler(),
            httpClient: mockClient,
          ),
        ),
        gatewayBuilder: (s) async => LocalSourceGateway(rootPath: s.location),
        computeWorker: const ScrapeComputeWorker(useIsolate: false),
      );

      final summary = await orchestrator.scanAndScrapeSource(source);
      final works = await repo.getAllWorks();
      // `加速世界 TV+Movie` 严格按照 MultiWorkSplitter 拆分为 3 个独立子簇：
      // 1. 加速世界 TV (24集 + NCOP), 2. Accel World EX (EX01/02), 3. 加速世界 Infinite Burst (剧场版)
      expect(summary.totalWorks, 3);
      expect(
        summary.matchedWorks,
        greaterThanOrEqualTo(2),
        reason:
            'works=${works.map((w) => '${w.title}(${w.tmdbId}/${w.scrapeStatus.name}:${w.reviewReason})').toList()}',
      );
      expect(works, hasLength(3));
      expect(works.any((w) => w.id == 'stale-unsplit-aw'), isFalse);

      final tvWork = works.firstWhere((w) => w.tmdbId == 43167);
      expect(tvWork.tmdbMediaType, TmdbMediaType.tv);
      expect(tvWork.matchedSeason, 1);
      expect(tvWork.title, '加速世界');

      final tvEps = await repo.getEpisodesByWork(tvWork.id);
      final tvMain = tvEps
          .where((e) => e.category == EpisodeCategory.main)
          .toList();
      final tvExtras = tvEps
          .where((e) => e.category == EpisodeCategory.extra)
          .toList();
      expect(tvMain, hasLength(24));
      expect(tvExtras, hasLength(1));

      final exWork = works.firstWhere(
        (w) => w.id != tvWork.id && w.tmdbId != 391751,
      );
      final exVariants = await repo.getVariantsByWork(exWork.id);
      expect(exVariants, hasLength(2));
      expect(exWork.tmdbId, isNot(43167));

      final movieWork = works.firstWhere((w) => w.tmdbId == 391751);
      expect(movieWork.tmdbMediaType, TmdbMediaType.movie);
      final movieEps = await repo.getEpisodesByWork(movieWork.id);
      expect(movieEps, hasLength(1));
      expect(movieEps.single.episodeNumber, isNull);
      expect(
        EpisodeTitleFormatter.formatCardTitle(
          episode: movieEps.single,
          workTitle: movieWork.title,
          workMediaType: movieWork.tmdbMediaType,
          mainEpisodeCount: 1,
        ),
        isNot(contains('01 ·')),
      );
    });

    test('Wake Up, Girls! 全系列 5 个独立目录完整保留 S1/S2 季身份与 Wug Ban Special 第 7 集', () async {
      const series = 'Wake Up, Girls!';
      await touchFile('$series/Wake Up, Girls！七位偶像 (2014)/WUG Movie (2014).mkv');
      for (var i = 1; i <= 12; i++) {
        final ep = i.toString().padLeft(2, '0');
        final fileName = i == 7
            ? 'Wake Up, Girls! - $ep [ Wug Ban Special ].mkv'
            : 'Wake Up, Girls! - $ep.mkv';
        await touchFile('$series/Wake Up, Girls! (2014)/$fileName');
      }
      await touchFile('$series/Wake Up, Girls！青春之影 (2015)/Seishun no Kage (2015).mkv');
      await touchFile('$series/Wake Up, Girls！Beyond the Bottom (2015)/Beyond the Bottom (2015).mkv');
      for (var i = 1; i <= 12; i++) {
        final ep = i.toString().padLeft(2, '0');
        await touchFile('$series/Wake Up, Girls! 新章 (2017)/WUG Shinshou - $ep.mkv');
      }

      final source = MediaSource(
        id: 'src_wug',
        kind: MediaSourceKind.local,
        label: 'WUG 盘',
        location: tempRoot.path,
      );
      await repo.upsertMediaSource(source);

      final mockClient = MockClient((req) async {
        final path = req.url.path;
        final query = (req.url.queryParameters['query'] ?? '').toLowerCase();

        if (path.endsWith('/search/tv') && query.contains('wake up, girls')) {
          return _jsonRes({
            'results': [
              {
                'id': 60571,
                'name': 'Wake Up, Girls!',
                'original_name': 'Wake Up, Girls!',
                'first_air_date': '2014-01-11',
              },
            ],
          });
        }
        if (path.endsWith('/search/movie')) {
          if (query.contains('七位偶像') || query.contains('wug movie')) {
            return _jsonRes({
              'results': [
                {
                  'id': 280001,
                  'title': 'Wake Up, Girls! 七位偶像',
                  'release_date': '2014-01-10',
                },
              ],
            });
          }
          if (query.contains('青春之影') || query.contains('seishun no kage')) {
            return _jsonRes({
              'results': [
                {
                  'id': 355001,
                  'title': 'Wake Up, Girls! 青春之影',
                  'release_date': '2015-09-25',
                },
              ],
            });
          }
          if (query.contains('beyond the bottom')) {
            return _jsonRes({
              'results': [
                {
                  'id': 365001,
                  'title': 'Wake Up, Girls! Beyond the Bottom',
                  'release_date': '2015-12-11',
                },
              ],
            });
          }
        }
        if (path.endsWith('/search/tv') || path.endsWith('/search/movie')) {
          return _jsonRes({'results': []});
        }
        if (path.endsWith('/tv/60571')) {
          return _jsonRes({
            'id': 60571,
            'name': 'Wake Up, Girls!',
            'original_name': 'Wake Up, Girls!',
            'first_air_date': '2014-01-11',
            'poster_path': '/wug-series.jpg',
            'seasons': [
              {
                'season_number': 1,
                'name': '第 1 季',
                'episode_count': 12,
                'air_date': '2014-01-11',
                'poster_path': '/wug-s1.jpg',
              },
              {
                'season_number': 2,
                'name': 'Wake Up, Girls! 新章',
                'episode_count': 12,
                'air_date': '2017-10-10',
                'poster_path': '/wug-s2.jpg',
              },
            ],
          });
        }
        if (path.endsWith('/tv/60571/season/1')) {
          return _jsonRes({
            'season_number': 1,
            'name': '第 1 季',
            'air_date': '2014-01-11',
            'poster_path': '/wug-s1.jpg',
            'episodes': [
              for (var i = 1; i <= 12; i++)
                {'episode_number': i, 'name': 'S1 第 $i 话'},
            ],
          });
        }
        if (path.endsWith('/tv/60571/season/2')) {
          return _jsonRes({
            'season_number': 2,
            'name': 'Wake Up, Girls! 新章',
            'air_date': '2017-10-10',
            'poster_path': '/wug-s2.jpg',
            'episodes': [
              for (var i = 1; i <= 12; i++)
                {'episode_number': i, 'name': '新章第 $i 话'},
            ],
          });
        }
        if (path.endsWith('/movie/280001')) {
          return _jsonRes({
            'id': 280001,
            'title': 'Wake Up, Girls! 七位偶像',
            'release_date': '2014-01-10',
            'poster_path': '/wug-m1.jpg',
          });
        }
        if (path.endsWith('/movie/355001')) {
          return _jsonRes({
            'id': 355001,
            'title': 'Wake Up, Girls! 青春之影',
            'release_date': '2015-09-25',
            'poster_path': '/wug-m2.jpg',
          });
        }
        if (path.endsWith('/movie/365001')) {
          return _jsonRes({
            'id': 365001,
            'title': 'Wake Up, Girls! Beyond the Bottom',
            'release_date': '2015-12-11',
            'poster_path': '/wug-m3.jpg',
          });
        }
        return http.Response('{}', 404);
      });

      final orchestrator = ScrapeOrchestrator(
        repository: repo,
        tmdbService: TmdbService(
          httpClient: TmdbHttpClient(
            config: const TmdbNetworkConfig(credential: 'v3_test'),
            scheduler: PriorityHttpScheduler(),
            httpClient: mockClient,
          ),
        ),
        gatewayBuilder: (s) async => LocalSourceGateway(rootPath: s.location),
        computeWorker: const ScrapeComputeWorker(useIsolate: false),
      );

      final summary = await orchestrator.scanAndScrapeSource(source);
      final works = await repo.getAllWorks();
      final diag = <String>[];
      for (final w in works) {
        final cands = await repo.getScrapeCandidates(w.id);
        final eps = await repo.getEpisodesByWork(w.id);
        diag.add(
          '${w.title}(id=${w.tmdbId},st=${w.scrapeStatus.name},eps=${eps.length},cands=${cands.map((c) => '${c.tmdbId}:${c.score}:${c.reasons}').toList()})',
        );
      }
      expect(summary.totalWorks, 5);
      expect(summary.matchedWorks, 5, reason: diag.join(' | '));
      expect(works, hasLength(5));

      final tvWorks = works.where((w) => w.tmdbId == 60571).toList();
      expect(tvWorks, hasLength(2));

      final s1 = tvWorks.firstWhere((w) => w.matchedSeason == 1);
      expect(s1.year, 2014);
      expect(s1.posterPath, '/wug-s1.jpg');
      final s1Eps = await repo.getEpisodesByWork(s1.id);
      expect(s1Eps.where((e) => e.category == EpisodeCategory.main), hasLength(12));
      final ep7 = s1Eps.firstWhere((e) => e.episodeNumber == 7);
      expect(ep7.category, EpisodeCategory.main);
      expect(ep7.title, 'S1 第 7 话');

      final s2 = tvWorks.firstWhere((w) => w.matchedSeason == 2);
      expect(s2.title, 'Wake Up, Girls! 新章');
      expect(s2.year, 2017);
      expect(s2.posterPath, '/wug-s2.jpg');
      expect(s2.posterFallback, '/wug-series.jpg');
      final s2Eps = await repo.getEpisodesByWork(s2.id);
      expect(s2Eps.where((e) => e.category == EpisodeCategory.main), hasLength(12));
      expect(s2Eps.first.seasonNumber, 2);

      expect(works.any((w) => w.tmdbId == 280001), isTrue);
      expect(works.any((w) => w.tmdbId == 355001), isTrue);
      expect(works.any((w) => w.tmdbId == 365001), isTrue);
    });

    test('未匹配 (unmatched) 作品进入 needsReviewItemsProvider 且手动绑定后自动移出', () async {
      await touchFile('神秘实验动画 (2019)/神秘实验动画 S01E01.mkv');

      final source = MediaSource(
        id: 'src_unmatched',
        kind: MediaSourceKind.local,
        label: '无结果测试盘',
        location: tempRoot.path,
      );
      await repo.upsertMediaSource(source);

      final mockClient = MockClient((req) async {
        final path = req.url.path;
        if (path.endsWith('/search/tv') || path.endsWith('/search/movie')) {
          return _jsonRes({'results': []});
        }
        if (path.endsWith('/tv/919191')) {
          return _jsonRes({
            'id': 919191,
            'name': '神秘实验动画',
            'first_air_date': '2019-07-01',
            'seasons': [
              {'season_number': 1, 'name': '第 1 季', 'episode_count': 1},
            ],
          });
        }
        if (path.endsWith('/tv/919191/season/1')) {
          return _jsonRes({
            'season_number': 1,
            'episodes': [
              {'episode_number': 1, 'name': '第 1 话'},
            ],
          });
        }
        return http.Response('{}', 404);
      });

      final orchestrator = ScrapeOrchestrator(
        repository: repo,
        tmdbService: TmdbService(
          httpClient: TmdbHttpClient(
            config: const TmdbNetworkConfig(credential: 'v3_test'),
            scheduler: PriorityHttpScheduler(),
            httpClient: mockClient,
          ),
        ),
        gatewayBuilder: (s) async => LocalSourceGateway(rootPath: s.location),
        computeWorker: const ScrapeComputeWorker(useIsolate: false),
      );

      final container = ProviderContainer(
        overrides: [libraryRepositoryProvider.overrideWithValue(repo)],
      );
      addTearDown(container.dispose);
      final reviewSub = container.listen(needsReviewItemsProvider, (_, _) {});
      addTearDown(reviewSub.close);

      await orchestrator.scanAndScrapeSource(source);

      container.invalidate(libraryItemsProvider);
      final allItems = await container.read(libraryItemsProvider.future);
      expect(allItems, hasLength(1));
      expect(allItems.single.work.scrapeStatus, ScrapeStatus.unmatched);
      expect(allItems.single.work.reviewReason, isNotNull);

      final reviewAsync = container.read(needsReviewItemsProvider);
      expect(reviewAsync.requireValue, hasLength(1));
      expect(reviewAsync.requireValue.single.work.id, allItems.single.work.id);

      await orchestrator.rebindWorkToTmdb(
        allItems.single.work.id,
        919191,
        TmdbMediaType.tv,
      );
      container.invalidate(libraryItemsProvider);
      await container.read(libraryItemsProvider.future);
      final afterReview = container.read(needsReviewItemsProvider);
      expect(afterReview.requireValue, isEmpty);
    });
  });
}
