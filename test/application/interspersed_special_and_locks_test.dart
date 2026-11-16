import 'dart:convert';
import 'dart:io';

import 'package:ccplayer/application/providers/library_providers.dart';
import 'package:ccplayer/application/providers/work_management_provider.dart';
import 'package:ccplayer/application/scraping/scrape_compute_worker.dart';
import 'package:ccplayer/application/scraping/scrape_orchestrator.dart';
import 'package:ccplayer/domain/matching/directory_grouper.dart';
import 'package:ccplayer/domain/matching/episode_remapper.dart';
import 'package:ccplayer/domain/models/episode.dart';
import 'package:ccplayer/domain/models/media_source.dart';
import 'package:ccplayer/domain/models/media_variant.dart';
import 'package:ccplayer/domain/models/network_config.dart';
import 'package:ccplayer/domain/models/tmdb_models.dart';
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

http.Response _jsonRes(Object data, [int statusCode = 200]) {
  return http.Response.bytes(
    utf8.encode(jsonEncode(data)),
    statusCode,
    headers: const {'content-type': 'application/json; charset=utf-8'},
  );
}

void main() {
  group('Stage 4: Bangumi 穿插特别篇 -1 偏移校准与人工锁持久化', () {
    late Directory tempRoot;
    late KonataDatabase db;
    late DriftLibraryRepository repo;

    setUp(() async {
      tempRoot = await Directory.systemTemp.createTemp('konata_stage4_');
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
      '[Moozzi2] Wake Up, Girls! Shin Shou 13 话含穿插特别篇 07 [ Wug Ban Special ]：07 映射 Season 0/Bangumi SP，08..13 精确 -1 偏移对齐 S02E07..E12',
      () async {
        const folderName = '[Moozzi2] Wake Up, Girls! Shin Shou (2017)';
        for (var i = 1; i <= 13; i++) {
          final ep = i.toString().padLeft(2, '0');
          final fileName = i == 7
              ? '[Moozzi2] Wake Up, Girls! Shin Shou - 07 [ Wug Ban Special ] (BD 1920x1080 x264 FLAC).mkv'
              : '[Moozzi2] Wake Up, Girls! Shin Shou - $ep (BD 1920x1080 x264 FLAC).mkv';
          await touchFile('$folderName/$fileName');
        }

        final source = MediaSource(
          id: 'src_wug2',
          kind: MediaSourceKind.local,
          label: 'ShinShou',
          location: tempRoot.path,
        );
        await repo.upsertMediaSource(source);

        final mockClient = MockClient((req) async {
          final host = req.url.host;
          final path = req.url.path;

          if (host == 'api.bgm.tv') {
            if (path.endsWith('/v0/search/subjects')) {
              return _jsonRes({
                'data': [
                  {
                    'id': 202270,
                    'name': 'Wake Up, Girls! 新章',
                    'name_cn': 'Wake Up, Girls! 新章',
                    'date': '2017-10-10',
                    'total_episodes': 12,
                    'platform': 'TV',
                    'images': {'large': 'https://lain.bgm.tv/pic/cover/l/wug2.jpg'},
                  },
                ],
              });
            }
            if (path.endsWith('/v0/subjects/202270')) {
              return _jsonRes({
                'id': 202270,
                'name': 'Wake Up, Girls! 新章',
                'name_cn': 'Wake Up, Girls! 新章',
                'date': '2017-10-10',
                'total_episodes': 12,
                'platform': 'TV',
                'images': {'large': 'https://lain.bgm.tv/pic/cover/l/wug2.jpg'},
                'infobox': [
                  {'key': '别名', 'value': 'Wake Up, Girls! Shin Shou'},
                ],
              });
            }
            if (path.endsWith('/v0/episodes')) {
              // 同时返回 type=0 正片 (12 话) 与穿插其中的 type=1 特别篇 (2017-11-21)
              final eps = <Map<String, Object?>>[];
              final baseDates = <String>[
                '2017-10-10',
                '2017-10-17',
                '2017-10-24',
                '2017-10-31',
                '2017-11-07',
                '2017-11-14',
                '2017-11-28',
                '2017-12-05',
                '2017-12-12',
                '2017-12-19',
                '2017-12-26',
                '2018-01-08',
              ];
              for (var i = 0; i < 12; i++) {
                eps.add({
                  'id': 7000 + i + 1,
                  'ep': i + 1,
                  'sort': i + 1,
                  'type': 0,
                  'name': 'Main ${i + 1}',
                  'name_cn': i == 6 ? '越苦越要笑' : '第${i + 1}话',
                  'airdate': baseDates[i],
                });
              }
              eps.add({
                'id': 7999,
                'ep': 1,
                'sort': 1,
                'type': 1,
                'name': '特別編 WUGBAN！新章',
                'name_cn': '特别篇 WUGBAN！新章',
                'airdate': '2017-11-21',
              });
              return _jsonRes({'data': eps});
            }
            return _jsonRes({});
          }

          if (path.endsWith('/search/tv')) {
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
            return _jsonRes({'results': []});
          }
          if (path.endsWith('/tv/60571')) {
            return _jsonRes({
              'id': 60571,
              'name': 'Wake Up, Girls!',
              'original_name': 'Wake Up, Girls!',
              'first_air_date': '2014-01-11',
              'seasons': [
                {'season_number': 0, 'name': '特别篇', 'episode_count': 2},
                {
                  'season_number': 1,
                  'name': '第 1 季',
                  'episode_count': 12,
                  'air_date': '2014-01-11',
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
          if (path.endsWith('/tv/60571/season/2')) {
            return _jsonRes({
              'id': 9002,
              'season_number': 2,
              'name': 'Wake Up, Girls! 新章',
              'air_date': '2017-10-10',
              'poster_path': '/wug-s2.jpg',
              'episodes': [
                {'episode_number': 1, 'name': '只要努力就会是阳光灿烂', 'air_date': '2017-10-10', 'still_path': '/s2e1.jpg'},
                {'episode_number': 2, 'name': '这里就是我们的地点', 'air_date': '2017-10-17', 'still_path': '/s2e2.jpg'},
                {'episode_number': 3, 'name': '为了某个人的一小步', 'air_date': '2017-10-24', 'still_path': '/s2e3.jpg'},
                {'episode_number': 4, 'name': '我们的故事', 'air_date': '2017-10-31', 'still_path': '/s2e4.jpg'},
                {'episode_number': 5, 'name': '一样的梦想、不一样的梦想', 'air_date': '2017-11-07', 'still_path': '/s2e5.jpg'},
                {'episode_number': 6, 'name': '只有现在', 'air_date': '2017-11-14', 'still_path': '/s2e6.jpg'},
                {'episode_number': 7, 'name': '越苦越要笑', 'air_date': '2017-11-28', 'still_path': '/s2e7.jpg'},
                {'episode_number': 8, 'name': '大家一起创造未来', 'air_date': '2017-12-05', 'still_path': '/s2e8.jpg'},
                {'episode_number': 9, 'name': '向阳的天空下', 'air_date': '2017-12-12', 'still_path': '/s2e9.jpg'},
                {'episode_number': 10, 'name': '在自己的时间里', 'air_date': '2017-12-19', 'still_path': '/s2e10.jpg'},
                {'episode_number': 11, 'name': '永远的闪耀', 'air_date': '2017-12-26', 'still_path': '/s2e11.jpg'},
                {'episode_number': 12, 'name': 'Brightest', 'air_date': '2018-01-08', 'still_path': '/s2e12.jpg'},
              ],
            });
          }
          if (path.endsWith('/tv/60571/season/0')) {
            return _jsonRes({
              'season_number': 0,
              'name': '特别篇',
              'episodes': [
                {'episode_number': 1, 'name': '剧场版相关特别篇', 'air_date': '2014-03-01', 'still_path': '/s0e1.jpg'},
                {'episode_number': 2, 'name': 'WUG BAN! New Chapter', 'air_date': '2017-11-21', 'still_path': '/s0e2.jpg'},
              ],
            });
          }
          return http.Response('{}', 404);
        });

        final httpClient = TmdbHttpClient(
          config: const TmdbNetworkConfig(credential: 'demo_key'),
          scheduler: PriorityHttpScheduler(),
          httpClient: mockClient,
          cooldownRegistry: DomainCooldownRegistry(),
        );
        final orchestrator = ScrapeOrchestrator(
          repository: repo,
          tmdbService: TmdbService(httpClient: httpClient),
          bangumiService: BangumiService(httpClient: httpClient),
          gatewayBuilder: (s) async => LocalSourceGateway(rootPath: s.location),
          computeWorker: const ScrapeComputeWorker(useIsolate: false),
        );

        final progress = await orchestrator.scanAndScrapeSource(source);
        expect(progress.matchedWorks, 1);

        final works = await repo.getAllWorks();
        expect(works, hasLength(1));
        final work = works.single;
        expect(work.tmdbId, 60571);
        expect(work.matchedSeason, 2);
        expect(work.bangumiId, 202270);

        final episodes = await repo.getEpisodesByWork(work.id);
        final variants = await repo.getVariantsByWork(work.id);

        final mainEps = episodes
            .where((e) => e.category == EpisodeCategory.main)
            .toList();
        final extraEps = episodes
            .where((e) => e.category == EpisodeCategory.extra)
            .toList();

        // 正片严格收敛为 12 集，第 07 个穿插特别篇分离进特典 Season 0
        expect(mainEps, hasLength(12));
        expect(extraEps, hasLength(1));

        final spEp = extraEps.single;
        expect(spEp.seasonNumber, 0);
        expect(spEp.episodeNumber, 2);
        expect(spEp.title, '特别篇 WUGBAN！新章');
        expect(spEp.stillPath, '/s0e2.jpg');

        final v07 = variants.firstWhere((v) => v.fileName.contains('- 07 '));
        expect(v07.episodeId, spEp.id);

        // 第 08 个文件严格顺延 -1，精准对齐 S02E07「越苦越要笑」
        final v08 = variants.firstWhere((v) => v.fileName.contains('- 08 '));
        final ep07 = mainEps.firstWhere((e) => e.episodeNumber == 7);
        expect(v08.episodeId, ep07.id);
        expect(ep07.title, '越苦越要笑');
        expect(ep07.stillPath, '/s2e7.jpg');

        // 第 13 个文件对齐 S02E12「Brightest」
        final v13 = variants.firstWhere((v) => v.fileName.contains('- 13 '));
        final ep12 = mainEps.firstWhere((e) => e.episodeNumber == 12);
        expect(v13.episodeId, ep12.id);
        expect(ep12.title, 'Brightest');
        expect(ep12.stillPath, '/s2e12.jpg');
      },
    );

    test('EpisodeRemapper 纯领域单元测试：无文件名特征词时仍凭 Bangumi 播出顺序 + 日期缺口对齐穿插总集篇', () {
      final variants = [
        for (var i = 1; i <= 5; i++)
          MediaVariant(
            id: 'v$i',
            workId: 'w1',
            sourceId: 'src1',
            relativePath: 'Demo/Demo - 0$i.mkv',
            fileName: 'Demo - 0$i.mkv',
            fileSize: 1000,
          ),
      ];
      final folder = GroupedWorkFolder(
        folderRelativePath: 'Demo',
        folderName: 'Demo',
        cleanTitle: 'Demo',
        seasonHint: 1,
        mainEpisodeNumbers: const [1, 2, 3, 4, 5],
        variants: variants,
      );
      final plan = EpisodeRemapper.buildPlan(
        folder: folder,
        tmdbSeasons: const [
          TmdbSeasonSummary(seasonNumber: 0, name: '特别篇', episodeCount: 1),
          TmdbSeasonSummary(seasonNumber: 1, name: '第 1 季', episodeCount: 4),
        ],
        matchedSeason: 1,
        tmdbEpisodes: const [
          TmdbEpisodeDetail(seasonNumber: 0, episodeNumber: 1, title: '总集篇 SP', airDate: '2024-04-15'),
          TmdbEpisodeDetail(seasonNumber: 1, episodeNumber: 1, title: 'E1', airDate: '2024-04-01'),
          TmdbEpisodeDetail(seasonNumber: 1, episodeNumber: 2, title: 'E2', airDate: '2024-04-08'),
          TmdbEpisodeDetail(seasonNumber: 1, episodeNumber: 3, title: 'E3', airDate: '2024-04-22'),
          TmdbEpisodeDetail(seasonNumber: 1, episodeNumber: 4, title: 'E4', airDate: '2024-04-29'),
        ],
        bangumiEpisodes: const [
          BangumiEpisodeEntry(id: 1, ep: 1, sort: 1, type: 0, name: 'E1', airDate: '2024-04-01'),
          BangumiEpisodeEntry(id: 2, ep: 2, sort: 2, type: 0, name: 'E2', airDate: '2024-04-08'),
          BangumiEpisodeEntry(id: 99, ep: 1, sort: 1, type: 1, name: '特别总集篇', nameCn: '特别总集篇', airDate: '2024-04-15'),
          BangumiEpisodeEntry(id: 3, ep: 3, sort: 3, type: 0, name: 'E3', airDate: '2024-04-22'),
          BangumiEpisodeEntry(id: 4, ep: 4, sort: 4, type: 0, name: 'E4', airDate: '2024-04-29'),
        ],
      );

      expect(plan.resolveSpecial(1, 3)?.tmdbSpecialEpisodeNumber, 1);
      expect(plan.resolveSpecial(1, 3)?.bangumiEpisode?.nameCn, '特别总集篇');
      expect(plan.resolve(1, 4)?.episodeNumber, 3);
      expect(plan.resolve(1, 5)?.episodeNumber, 4);
    });

    test(
      '细粒度人工锁定保护：重抓 TMDB 与增量重扫绝不覆盖已锁定的海报/背景图/文件映射，且仅更新未锁定字段 + 支持恢复自动默认',
      () async {
        await touchFile('LockDemo (2024)/LockDemo - 01.mkv');
        await touchFile('LockDemo (2024)/LockDemo - 02.mkv');

        final source = MediaSource(
          id: 'src_lock',
          kind: MediaSourceKind.local,
          label: '锁定验证盘',
          location: tempRoot.path,
        );
        await repo.upsertMediaSource(source);

        var tmdbTitleVersion = '初版标题';
        var tmdbOverviewVersion = '初版简介';
        var tmdbPosterVersion = '/tmdb-poster-v1.jpg';
        var tmdbBackdropVersion = '/tmdb-backdrop-v1.jpg';
        var ep1TitleVersion = '第1集初版';

        final mockClient = MockClient((req) async {
          final path = req.url.path;
          if (path.endsWith('/search/tv')) {
            return _jsonRes({
              'results': [
                {'id': 777, 'name': tmdbTitleVersion, 'first_air_date': '2024-01-05'},
              ],
            });
          }
          if (path.endsWith('/search/movie')) {
            return _jsonRes({'results': []});
          }
          if (path.endsWith('/tv/777')) {
            return _jsonRes({
              'id': 777,
              'name': tmdbTitleVersion,
              'overview': tmdbOverviewVersion,
              'first_air_date': '2024-01-05',
              'poster_path': tmdbPosterVersion,
              'backdrop_path': tmdbBackdropVersion,
              'seasons': [
                {'season_number': 1, 'name': '第 1 季', 'episode_count': 2, 'air_date': '2024-01-05'},
              ],
            });
          }
          if (path.endsWith('/tv/777/season/1')) {
            return _jsonRes({
              'season_number': 1,
              'episodes': [
                {'episode_number': 1, 'name': ep1TitleVersion, 'still_path': '/ep1.jpg'},
                {'episode_number': 2, 'name': '第2集正片', 'still_path': '/ep2.jpg'},
              ],
            });
          }
          if (path.endsWith('/tv/888')) {
            return _jsonRes({
              'id': 888,
              'name': '全新绑定条目',
              'overview': '全新绑定简介',
              'first_air_date': '2025-01-01',
              'poster_path': '/new-888-poster.jpg',
              'backdrop_path': '/new-888-backdrop.jpg',
              'seasons': [
                {'season_number': 1, 'name': '第 1 季', 'episode_count': 2, 'air_date': '2025-01-01'},
              ],
            });
          }
          if (path.endsWith('/tv/888/season/1')) {
            return _jsonRes({
              'season_number': 1,
              'episodes': [
                {'episode_number': 1, 'name': '新作品第1集'},
                {'episode_number': 2, 'name': '新作品第2集'},
              ],
            });
          }
          return http.Response('{}', 404);
        });

        final httpClient = TmdbHttpClient(
          config: const TmdbNetworkConfig(credential: 'demo_key'),
          scheduler: PriorityHttpScheduler(),
          httpClient: mockClient,
          cooldownRegistry: DomainCooldownRegistry(),
        );
        final tmdbService = TmdbService(httpClient: httpClient);
        final orchestrator = ScrapeOrchestrator(
          repository: repo,
          tmdbService: tmdbService,
          gatewayBuilder: (s) async => LocalSourceGateway(rootPath: s.location),
          computeWorker: const ScrapeComputeWorker(useIsolate: false),
        );

        await orchestrator.scanAndScrapeSource(source);
        final work0 = (await repo.getAllWorks()).single;
        final variants0 = await repo.getVariantsByWork(work0.id);
        final v2 = variants0.firstWhere((v) => v.fileName.contains('02'));

        // 通过 Riverpod WorkManagementActions 仅锁定自定义封面、背景图与文件 02 映射（故意不锁定 metadata！）
        final container = ProviderContainer(
          overrides: [
            libraryRepositoryProvider.overrideWithValue(repo),
          ],
        );
        addTearDown(container.dispose);

        final mgmt = container.read(workManagementProvider);
        await mgmt.updateWorkArtwork(
          workId: work0.id,
          posterPath: 'C:/custom/my_poster.png',
          backdropPath: 'C:/custom/my_backdrop.jpg',
        );
        await mgmt.saveEpisodeMappings(
          workId: work0.id,
          mappings: [
            EpisodeFileMappingEdit(
              variantId: v2.id,
              category: EpisodeCategory.extra,
              seasonNumber: 0,
              episodeNumber: 9,
              extraType: ExtraKind.sp,
            ),
          ],
        );

        // 模拟远端 TMDB 元数据/图像已更新
        tmdbTitleVersion = '更新后新标题';
        tmdbOverviewVersion = '更新后新简介';
        tmdbPosterVersion = '/tmdb-poster-v2.jpg';
        tmdbBackdropVersion = '/tmdb-backdrop-v2.jpg';
        ep1TitleVersion = '第1集更新标题';

        // 1. 触发「重新抓取 TMDB 数据」（同 tmdbId 刷新，resetManualLocks=false）
        final refreshed = await orchestrator.rebindWorkToTmdb(
          work0.id,
          777,
          TmdbMediaType.tv,
        );
        expect(refreshed.title, '更新后新标题', reason: '未锁定的元数据应随刷新更新');
        expect(refreshed.overview, '更新后新简介');
        expect(refreshed.posterPath, 'C:/custom/my_poster.png', reason: '已锁定自定义封面绝不重置');
        expect(refreshed.backdropPath, 'C:/custom/my_backdrop.jpg', reason: '已锁定自定义背景绝不重置');
        expect(refreshed.posterLocked, isTrue);
        expect(refreshed.backdropLocked, isTrue);

        // 检查文件 01 更新为新剧集标题，文件 02 保持手动修正为 Extra SP #09
        final epsAfterRefresh = await repo.getEpisodesByWork(work0.id);
        final variantsAfterRefresh = await repo.getVariantsByWork(work0.id);
        final v1After = variantsAfterRefresh.firstWhere((v) => v.fileName.contains('01'));
        final v2After = variantsAfterRefresh.firstWhere((v) => v.fileName.contains('02'));
        final ep1After = epsAfterRefresh.firstWhere((e) => e.id == v1After.episodeId);
        final ep2After = epsAfterRefresh.firstWhere((e) => e.id == v2After.episodeId);
        expect(ep1After.title, '第1集更新标题');
        expect(ep2After.category, EpisodeCategory.extra);
        expect(ep2After.seasonNumber, 0);
        expect(ep2After.episodeNumber, 9);
        expect(v2After.mappingLocked, isTrue);

        // 2. 再次全量增量扫描源：仍然严格保护海报、背景图与文件 02 的锁定映射
        await orchestrator.scanAndScrapeSource(source);
        final afterRescanWork = await repo.findWorkById(work0.id);
        final afterRescanV2 = (await repo.getVariantsByWork(work0.id))
            .firstWhere((v) => v.id == v2.id);
        final afterRescanEp2 = (await repo.getEpisodesByWork(work0.id))
            .firstWhere((e) => e.id == afterRescanV2.episodeId);
        expect(afterRescanWork?.posterPath, 'C:/custom/my_poster.png');
        expect(afterRescanWork?.backdropPath, 'C:/custom/my_backdrop.jpg');
        expect(afterRescanEp2.category, EpisodeCategory.extra);
        expect(afterRescanEp2.episodeNumber, 9);

        // 3. 主动解锁封面并调用重绑到同一 ID（通过 repository/actions 验证解锁）
        await repo.upsertWork(afterRescanWork!.copyWith(posterLocked: false));
        final afterPosterUnlock = await orchestrator.rebindWorkToTmdb(
          work0.id,
          777,
          TmdbMediaType.tv,
        );
        expect(afterPosterUnlock.posterPath, '/tmdb-poster-v2.jpg');
        expect(afterPosterUnlock.backdropPath, 'C:/custom/my_backdrop.jpg');

        // 4. 在「绑定元数据」中更换绑定到全新作品 tmdbId=888 并重置旧锁定
        final switched = await orchestrator.rebindWorkToTmdb(
          work0.id,
          888,
          TmdbMediaType.tv,
          resetManualLocks: true,
        );
        expect(switched.tmdbId, 888);
        expect(switched.title, '全新绑定条目');
        expect(switched.posterPath, '/new-888-poster.jpg');
        expect(switched.backdropPath, '/new-888-backdrop.jpg');
        expect(switched.backdropLocked, isFalse);
        final switchedV2 = (await repo.getVariantsByWork(work0.id))
            .firstWhere((v) => v.id == v2.id);
        final switchedEp2 = (await repo.getEpisodesByWork(work0.id))
            .firstWhere((e) => e.id == switchedV2.episodeId);
        expect(switchedV2.mappingLocked, isFalse);
        expect(switchedEp2.category, EpisodeCategory.main);
        expect(switchedEp2.episodeNumber, 2);
        expect(switchedEp2.title, '新作品第2集');
      },
    );
  });
}
