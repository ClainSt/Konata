import 'dart:convert';
import 'dart:io';

import 'package:ccplayer/application/providers/library_providers.dart';
import 'package:ccplayer/application/providers/scraping_providers.dart';
import 'package:ccplayer/application/providers/work_split_and_series_actions.dart';
import 'package:ccplayer/application/scraping/scrape_compute_worker.dart';
import 'package:ccplayer/application/scraping/scrape_orchestrator.dart';
import 'package:ccplayer/domain/models/media_source.dart';
import 'package:ccplayer/domain/models/network_config.dart';
import 'package:ccplayer/domain/models/work.dart';
import 'package:ccplayer/domain/scraping/bangumi_models.dart';
import 'package:ccplayer/infrastructure/database/drift_library_repository.dart';
import 'package:ccplayer/infrastructure/database/konata_database.dart';
import 'package:ccplayer/infrastructure/network/bangumi_service.dart';
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

http.Response _jsonResp(Object data, [int statusCode = 200]) {
  return http.Response.bytes(
    utf8.encode(jsonEncode(data)),
    statusCode,
    headers: const {'content-type': 'application/json; charset=utf-8'},
  );
}

final _testRefProvider = Provider<Ref>((ref) => ref);

void main() {
  group('阶段 3 文件级拆分 + Bangumi×TMDB 双源混合绑定与永久锁回归测试', () {
    late Directory tempRoot;
    late KonataDatabase db;
    late DriftLibraryRepository repo;

    setUp(() async {
      tempRoot = await Directory.systemTemp.createTemp('konata_stage3_');
      db = KonataDatabase(NativeDatabase.memory());
      repo = DriftLibraryRepository(db);
    });

    tearDown(() async {
      await db.close();
      if (await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
    });

    Future<void> touchFile(String relPath, [String content = '']) async {
      final file = File(p.joinAll([tempRoot.path, ...relPath.split('/')]));
      await file.parent.create(recursive: true);
      await file.writeAsString(content);
    }

    test(
      '待复核 OVA 逐个拆分生成独立作品卡片 + 清空残余待复核 + 全库重扫严格保持 file/work 锁定不回并',
      () async {
        await touchFile(
          'Milky Holmes Alternative/Milky Holmes Alternative ONE.mkv',
        );
        await touchFile(
          'Milky Holmes Alternative/Milky Holmes Alternative TWO.mkv',
        );

        final source = MediaSource(
          id: 'src-stage3',
          kind: MediaSourceKind.local,
          label: 'OVA 测试源',
          location: tempRoot.path,
        );
        await repo.upsertMediaSource(source);

        final mockClient = MockClient((request) async {
          final path = request.url.path;
          final query = (request.url.queryParameters['query'] ?? '')
              .toLowerCase();

          // TMDB 搜索：初次扫描针对目录名返回空白以落入待复核池，便于手工分拆绑定
          if (path.endsWith('/search/tv')) {
            if (query.contains('milky holmes')) {
              return _jsonResp({'results': []});
            }
            return _jsonResp({'results': []});
          }
          if (path.endsWith('/search/movie')) {
            return _jsonResp({'results': []});
          }

          // TMDB 母系列详请：70010（侦探歌剧 少女福尔摩斯）
          if (path.endsWith('/tv/70010')) {
            return _jsonResp({
              'id': 70010,
              'name': '侦探歌剧 少女福尔摩斯',
              'original_name': '探偵オペラ ミルキィホームズ',
              'first_air_date': '2010-10-07',
              'overview': '拥有侦探能力的少女们解决神秘案件的故事。',
              'poster_path': '/mh_series_poster.jpg',
              'backdrop_path': '/mh_backdrop_main.jpg',
              'vote_average': 7.5,
              'seasons': [
                {
                  'season_number': 0,
                  'name': '特别篇',
                  'poster_path': '/mh_season0_poster.jpg',
                },
                {
                  'season_number': 1,
                  'name': '第 1 季',
                  'poster_path': '/mh_season1_poster.jpg',
                },
              ],
              'images': {
                'posters': [
                  {
                    'file_path': '/mh_series_poster.jpg',
                    'width': 1000,
                    'height': 1500,
                    'iso_639_1': 'zh',
                  },
                ],
                'backdrops': [
                  {
                    'file_path': '/mh_backdrop_main.jpg',
                    'width': 3840,
                    'height': 2160,
                    'iso_639_1': 'zh',
                  },
                  {
                    'file_path': '/mh_backdrop_alt.jpg',
                    'width': 1920,
                    'height': 1080,
                    'iso_639_1': 'ja',
                  },
                ],
              },
            });
          }

          // TMDB 母系列 Season 0 特别篇（第 2、3 集分别对应 Alternative ONE / TWO）
          if (path.endsWith('/tv/70010/season/0')) {
            return _jsonResp({
              'id': 700100,
              'season_number': 0,
              'name': '特别篇',
              'overview': '系列 OVA 与特别篇收录。',
              'poster_path': '/mh_season0_poster.jpg',
              'air_date': '2012-08-25',
              'episodes': [
                {
                  'episode_number': 2,
                  'name': 'Alternative ONE ~小林歌剧与五幅画作~',
                  'overview': '在英国伦敦爆发的名画失窃案。',
                  'still_path': '/still_ova1.jpg',
                  'air_date': '2012-08-25',
                },
                {
                  'episode_number': 3,
                  'name': 'Alternative TWO ~小林歌剧与虚空の大鴉~',
                  'overview': '围绕神秘组织展开的后续推理。',
                  'still_path': '/still_ova2.jpg',
                  'air_date': '2012-12-31',
                },
              ],
            });
          }

          // Bangumi 搜索与条目详情
          if (path.endsWith('/search/subjects')) {
            return _jsonResp({'data': []});
          }
          if (path.endsWith('/subjects/41101')) {
            return _jsonResp({
              'id': 41101,
              'name': '探偵オペラ ミルキィホームズ Alternative ONE',
              'name_cn': '侦探歌剧 少女福尔摩斯 Alternative ONE',
              'date': '2012-08-25',
              'platform': 'OVA',
              'summary': 'OVA 第一弹独立简介。',
              'rating': {'score': 7.6},
              'images': {'large': 'https://bgm.example/ova1.jpg'},
            });
          }
          if (path.endsWith('/subjects/41102')) {
            return _jsonResp({
              'id': 41102,
              'name': '探偵オペラ ミルキィホームズ Alternative TWO',
              'name_cn': '侦探歌剧 少女福尔摩斯 Alternative TWO',
              'date': '2012-12-31',
              'platform': 'OVA',
              'summary': 'OVA 第二弹独立简介。',
              'rating': {'score': 7.4},
              'images': {'large': 'https://bgm.example/ova2.jpg'},
            });
          }
          if (path.endsWith('/subjects/41101/subjects')) {
            return _jsonResp([
              {
                'id': 41102,
                'relation': '续集',
                'name': 'Alternative TWO',
                'name_cn': '侦探歌剧 少女福尔摩斯 Alternative TWO',
              },
            ]);
          }
          if (path.endsWith('/subjects/41102/subjects')) {
            return _jsonResp([
              {
                'id': 41101,
                'relation': '前传',
                'name': 'Alternative ONE',
                'name_cn': '侦探歌剧 少女福尔摩斯 Alternative ONE',
              },
            ]);
          }
          if (path.endsWith('/episodes')) {
            return _jsonResp({'data': []});
          }

          return _jsonResp({}, 404);
        });

        final scheduler = PriorityHttpScheduler();
        final httpClient = TmdbHttpClient(
          config: const TmdbNetworkConfig(credential: 'test-tmdb-key'),
          scheduler: scheduler,
          httpClient: mockClient,
        );
        final tmdbService = TmdbService(httpClient: httpClient);
        final bgmService = BangumiService(httpClient: httpClient);

        final orchestrator = ScrapeOrchestrator(
          repository: repo,
          tmdbService: tmdbService,
          bangumiService: bgmService,
          gatewayBuilder: (s) async => LocalSourceGateway(rootPath: s.location),
          computeWorker: const ScrapeComputeWorker(useIsolate: false),
        );

        // 1. 初次扫描入库 -> 生成 1 条待复核组，含 2 个 OVA 文件
        await orchestrator.scanAndScrapeSource(source);
        final initialWorks = await repo.getAllWorks();
        expect(initialWorks, hasLength(1));
        final reviewWork = initialWorks.single;
        expect(reviewWork.scrapeStatus, ScrapeStatus.unmatched);
        final initialVariants = await repo.getVariantsByWork(reviewWork.id);
        expect(initialVariants, hasLength(2));

        final variantOne = initialVariants.firstWhere(
          (v) => v.fileName.contains('ONE'),
        );
        final variantTwo = initialVariants.firstWhere(
          (v) => v.fileName.contains('TWO'),
        );

        final container = ProviderContainer(
          overrides: [
            libraryRepositoryProvider.overrideWithValue(repo),
            tmdbNetworkConfigProvider.overrideWith(
              (_) async => const TmdbNetworkConfig(credential: 'test-tmdb-key'),
            ),
            priorityHttpSchedulerProvider.overrideWithValue(scheduler),
          ],
        );
        addTearDown(container.dispose);
        final ref = container.read(_testRefProvider);

        final tmdbParent = await tmdbService.getWorkDetail(
          70010,
          TmdbMediaType.tv,
          includeEnglishImages: true,
        );
        expect(tmdbParent, isNotNull);
        expect(tmdbParent!.candidateBackdrops, hasLength(2));

        // 2. 拆出第一个文件并绑定 Bangumi 41101 × TMDB 70010 Season 0 Episode 2
        const bgmOne = BangumiSubjectCandidate(
          id: 41101,
          name: '探偵オペラ ミルキィホームズ Alternative ONE',
          nameCn: '侦探歌剧 少女福尔摩斯 Alternative ONE',
          year: 2012,
          score: 7.6,
          posterUrl: 'https://bgm.example/ova1.jpg',
          summary: 'OVA 第一弹独立简介。',
          isSpecialFormat: true,
        );
        final createdOne = await executeSplitVariantsToIndependentWork(
          ref,
          sourceWorkId: reviewWork.id,
          variantIds: [variantOne.id],
          hybridRequest: HybridMatchRequest(
            bangumiSubject: bgmOne,
            tmdbDetail: tmdbParent,
            tmdbSeasonNumber: 0,
            startEpisodeNumber: 2,
          ),
          bangumiServiceOverride: bgmService,
          tmdbServiceOverride: tmdbService,
        );

        expect(createdOne.title, '侦探歌剧 少女福尔摩斯 Alternative ONE');
        expect(createdOne.bangumiId, 41101);
        expect(createdOne.bangumiScore, closeTo(7.6, 0.001));
        expect(createdOne.posterPath, 'https://bgm.example/ova1.jpg');
        expect(createdOne.tmdbId, 70010);
        expect(createdOne.matchedSeason, 0);
        expect(createdOne.backdropPath, '/mh_backdrop_main.jpg');
        expect(createdOne.scrapeStatus, ScrapeStatus.matched);

        final oneEpisodes = await repo.getEpisodesByWork(createdOne.id);
        expect(oneEpisodes, hasLength(1));
        expect(oneEpisodes.single.seasonNumber, 0);
        expect(oneEpisodes.single.episodeNumber, 2);
        expect(oneEpisodes.single.stillPath, '/still_ova1.jpg');
        expect(
          oneEpisodes.single.title,
          'Alternative ONE ~小林歌剧与五幅画作~',
        );

        final oneVariants = await repo.getVariantsByWork(createdOne.id);
        expect(oneVariants.single.workLocked, isTrue);
        expect(oneVariants.single.mappingLocked, isTrue);

        // 原待复核条目仍存在且仅剩余 1 个文件
        final remainingInReview = await repo.getVariantsByWork(reviewWork.id);
        expect(remainingInReview.map((v) => v.id).toList(), [variantTwo.id]);

        // 3. 拆出第二个文件并绑定 Bangumi 41102 × TMDB 70010 Season 0 Episode 3
        const bgmTwo = BangumiSubjectCandidate(
          id: 41102,
          name: '探偵オペラ ミルキィホームズ Alternative TWO',
          nameCn: '侦探歌剧 少女福尔摩斯 Alternative TWO',
          year: 2012,
          score: 7.4,
          posterUrl: 'https://bgm.example/ova2.jpg',
          summary: 'OVA 第二弹独立简介。',
          isSpecialFormat: true,
        );
        final createdTwo = await executeSplitVariantsToIndependentWork(
          ref,
          sourceWorkId: reviewWork.id,
          variantIds: [variantTwo.id],
          hybridRequest: HybridMatchRequest(
            bangumiSubject: bgmTwo,
            tmdbDetail: tmdbParent,
            tmdbSeasonNumber: 0,
            startEpisodeNumber: 3,
          ),
          bangumiServiceOverride: bgmService,
          tmdbServiceOverride: tmdbService,
        );

        // 原待复核残余文件分配完毕后自动删除
        expect(await repo.findWorkById(reviewWork.id), isNull);

        // 两部独立 OVA 根据 Bangumi 前传/续集关联自动编入同一系列
        final refreshedOne = await repo.findWorkById(createdOne.id);
        final refreshedTwo = await repo.findWorkById(createdTwo.id);
        expect(refreshedOne!.seriesId, isNotNull);
        expect(refreshedOne.seriesId, refreshedTwo!.seriesId);

        // 4. 再次全库重扫：workLocked 与 mappingLocked 严格阻止合并回原目录，保留双源混合结果
        await orchestrator.scanAndScrapeSource(source);

        final worksAfterRescan = await repo.getAllWorks();
        expect(worksAfterRescan, hasLength(2));
        expect(
          worksAfterRescan.map((w) => w.id).toSet(),
          {createdOne.id, createdTwo.id},
        );

        final postOne = await repo.findWorkById(createdOne.id);
        final postTwo = await repo.findWorkById(createdTwo.id);
        expect(postOne!.posterPath, 'https://bgm.example/ova1.jpg');
        expect(postOne.backdropPath, '/mh_backdrop_main.jpg');
        expect(postOne.bangumiScore, closeTo(7.6, 0.001));
        expect(postTwo!.posterPath, 'https://bgm.example/ova2.jpg');

        final postOneEps = await repo.getEpisodesByWork(createdOne.id);
        final postTwoEps = await repo.getEpisodesByWork(createdTwo.id);
        expect(postOneEps.single.seasonNumber, 0);
        expect(postOneEps.single.episodeNumber, 2);
        expect(postTwoEps.single.seasonNumber, 0);
        expect(postTwoEps.single.episodeNumber, 3);
      },
    );
  });
}
