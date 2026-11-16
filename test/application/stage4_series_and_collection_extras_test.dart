import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ccplayer/application/providers/artwork_provider.dart';
import 'package:ccplayer/application/providers/library_providers.dart';
import 'package:ccplayer/application/providers/scraping_providers.dart';
import 'package:ccplayer/application/providers/theme_providers.dart';
import 'package:ccplayer/application/providers/work_management_provider.dart';
import 'package:ccplayer/application/providers/work_split_and_series_actions.dart';
import 'package:ccplayer/application/scraping/scrape_compute_worker.dart';
import 'package:ccplayer/application/scraping/scrape_orchestrator.dart';
import 'package:ccplayer/domain/models/episode.dart';
import 'package:ccplayer/domain/models/media_source.dart';
import 'package:ccplayer/domain/models/media_variant.dart';
import 'package:ccplayer/domain/models/network_config.dart';
import 'package:ccplayer/domain/models/series_group.dart';
import 'package:ccplayer/domain/models/work.dart';
import 'package:ccplayer/infrastructure/database/drift_library_repository.dart';
import 'package:ccplayer/infrastructure/database/konata_database.dart';
import 'package:ccplayer/infrastructure/network/bangumi_service.dart';
import 'package:ccplayer/infrastructure/network/priority_http_scheduler.dart';
import 'package:ccplayer/infrastructure/network/tmdb_http_client.dart';
import 'package:ccplayer/infrastructure/network/tmdb_service.dart';
import 'package:ccplayer/infrastructure/sources/local_source_gateway.dart';
import 'package:ccplayer/presentation/detail/series_switcher_dropdown.dart';
import 'package:ccplayer/presentation/detail/work_detail_page.dart';
import 'package:ccplayer/presentation/theme/konata_theme.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

http.Response _jsonResp(Object data, [int statusCode = 200]) {
  return http.Response.bytes(
    utf8.encode(jsonEncode(data)),
    statusCode,
    headers: const {'content-type': 'application/json; charset=utf-8'},
  );
}

final Uint8List _transparentPng = Uint8List.fromList([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
]);

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  group('阶段 4 系列编组、下拉原地切换与合集公共/季独占附属资源测试', () {
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
      '合集多季+剧场版自动拆卡成系列、CD/Creditless/Menu/PV 全系列共享、Scan S3 季独占及人工范围锁定',
      () async {
        // 1. 构造典型 BDRip 合集树：[ReinForce] Spy x Family
        for (var s = 1; s <= 3; s++) {
          for (var ep = 1; ep <= 12; ep++) {
            final epStr = ep.toString().padLeft(2, '0');
            await touchFile(
              '[ReinForce] Spy x Family/Season $s/[ReinForce] Spy x Family - S0${s}E$epStr.mkv',
            );
          }
        }
        await touchFile(
          '[ReinForce] Spy x Family/Code White/[ReinForce] Spy x Family Code White.mkv',
        );
        await touchFile(
          '[ReinForce] Spy x Family/Extra/CD/Original Soundtrack.flac',
          'flac-bytes',
        );
        await touchFile(
          '[ReinForce] Spy x Family/Extra/Creditless/NCOP1.mkv',
        );
        await touchFile(
          '[ReinForce] Spy x Family/Extra/Menu/Menu01.mkv',
        );
        await touchFile(
          '[ReinForce] Spy x Family/Extra/PV/PV01.mkv',
        );
        await touchFile(
          '[ReinForce] Spy x Family/Extra/Scan S3/Booklet_01.jpg',
          'jpeg-bytes',
        );

        final source = MediaSource(
          id: 'src-stage4',
          kind: MediaSourceKind.local,
          label: '合集测试库',
          location: tempRoot.path,
        );
        await repo.upsertMediaSource(source);

        final mockClient = MockClient((request) async {
          final path = request.url.path;
          final query = (request.url.queryParameters['query'] ?? '')
              .toLowerCase();

          if (path.endsWith('/search/tv')) {
            if (query.contains('code') || query.contains('white')) {
              return _jsonResp({'results': []});
            }
            if (query.contains('spy')) {
              return _jsonResp({
                'results': [
                  {
                    'id': 120089,
                    'name': '间谍过家家',
                    'original_name': 'SPY×FAMILY',
                    'first_air_date': '2022-04-09',
                    'poster_path': '/spy_tv_poster.jpg',
                    'vote_average': 8.6,
                  },
                ],
              });
            }
            return _jsonResp({'results': []});
          }

          if (path.endsWith('/search/movie')) {
            if (query.contains('code') || query.contains('white')) {
              return _jsonResp({
                'results': [
                  {
                    'id': 968051,
                    'title': '剧场版 间谍过家家 代号：白',
                    'original_title': 'SPY x FAMILY Code White',
                    'release_date': '2023-12-22',
                    'poster_path': '/spy_movie_poster.jpg',
                    'vote_average': 8.1,
                  },
                ],
              });
            }
            return _jsonResp({'results': []});
          }

          if (path.endsWith('/tv/120089')) {
            return _jsonResp({
              'id': 120089,
              'name': '间谍过家家',
              'original_name': 'SPY×FAMILY',
              'first_air_date': '2022-04-09',
              'overview': '名门校潜入任务与家庭喜剧。',
              'poster_path': '/spy_tv_poster.jpg',
              'backdrop_path': '/spy_tv_backdrop.jpg',
              'vote_average': 8.6,
              'alternative_titles': {
                'results': [
                  {'iso_3166_1': 'US', 'title': 'Spy x Family'},
                ],
              },
              'seasons': [
                {
                  'season_number': 1,
                  'name': '第 1 季',
                  'episode_count': 12,
                  'air_date': '2022-04-09',
                  'poster_path': '/spy_s1.jpg',
                },
                {
                  'season_number': 2,
                  'name': '第 2 季',
                  'episode_count': 12,
                  'air_date': '2023-10-07',
                  'poster_path': '/spy_s2.jpg',
                },
                {
                  'season_number': 3,
                  'name': '第 3 季',
                  'episode_count': 12,
                  'air_date': '2025-10-04',
                  'poster_path': '/spy_s3.jpg',
                },
              ],
            });
          }

          for (final s in [1, 2, 3]) {
            if (path.endsWith('/tv/120089/season/$s')) {
              return _jsonResp({
                'id': 1200890 + s,
                'season_number': s,
                'name': '第 $s 季',
                'air_date': s == 1
                    ? '2022-04-09'
                    : (s == 2 ? '2023-10-07' : '2025-10-04'),
                'poster_path': '/spy_s$s.jpg',
                'episodes': [
                  for (var ep = 1; ep <= 12; ep++)
                    {
                      'episode_number': ep,
                      'name': '第 $s 季 第 $ep 话',
                      'overview': '正片第 $ep 集剧情。',
                      'still_path': '/spy_s${s}_ep$ep.jpg',
                    },
                ],
              });
            }
          }

          if (path.endsWith('/movie/968051')) {
            return _jsonResp({
              'id': 968051,
              'title': '剧场版 间谍过家家 代号：白',
              'original_title': 'SPY x FAMILY Code White',
              'release_date': '2023-12-22',
              'overview': '弗里吉斯家族旅行大冒险。',
              'poster_path': '/spy_movie_poster.jpg',
              'backdrop_path': '/spy_movie_backdrop.jpg',
              'vote_average': 8.1,
              'belongs_to_collection': {
                'id': 110055,
                'name': '间谍过家家系列',
              },
            });
          }

          if (path.endsWith('/search/subjects')) {
            var kw = '';
            try {
              final decoded = jsonDecode(utf8.decode(request.bodyBytes));
              if (decoded is Map) {
                kw = (decoded['keyword'] ?? '').toString().toLowerCase();
              }
            } catch (_) {}
            if (kw.contains('code') || kw.contains('white')) {
              return _jsonResp({
                'data': [
                  {
                    'id': 411428,
                    'name': '劇場版 SPY×FAMILY CODE: White',
                    'name_cn': '剧场版 间谍过家家 代号：白',
                    'date': '2023-12-22',
                    'rating': {'score': 7.7},
                    'images': {'large': 'https://bgm.example/spy_movie.jpg'},
                  },
                ],
              });
            }
            return _jsonResp({
              'data': [
                {
                  'id': 329906,
                  'name': 'SPY×FAMILY',
                  'name_cn': '间谍过家家',
                  'date': '2022-04-09',
                  'rating': {'score': 8.1},
                  'images': {'large': 'https://bgm.example/spy_s1.jpg'},
                },
                {
                  'id': 404804,
                  'name': 'SPY×FAMILY Season 2',
                  'name_cn': '间谍过家家 第二季',
                  'date': '2023-10-07',
                  'rating': {'score': 7.9},
                  'images': {'large': 'https://bgm.example/spy_s2.jpg'},
                },
                {
                  'id': 486001,
                  'name': 'SPY×FAMILY Season 3',
                  'name_cn': '间谍过家家 第三季',
                  'date': '2025-10-04',
                  'rating': {'score': 8.0},
                  'images': {'large': 'https://bgm.example/spy_s3.jpg'},
                },
              ],
            });
          }
          if (path.endsWith('/subjects/329906')) {
            return _jsonResp({
              'id': 329906,
              'name': 'SPY×FAMILY',
              'name_cn': '间谍过家家',
              'date': '2022-04-09',
              'total_episodes': 12,
              'rating': {'score': 8.1},
              'images': {'large': 'https://bgm.example/spy_s1.jpg'},
              'infobox': [
                {
                  'key': '别名',
                  'value': [
                    {'v': 'Spy x Family'},
                  ],
                },
              ],
            });
          }
          if (path.endsWith('/subjects/404804')) {
            return _jsonResp({
              'id': 404804,
              'name': 'SPY×FAMILY Season 2',
              'name_cn': '间谍过家家 第二季',
              'date': '2023-10-07',
              'rating': {'score': 7.9},
              'images': {'large': 'https://bgm.example/spy_s2.jpg'},
            });
          }
          if (path.endsWith('/subjects/486001')) {
            return _jsonResp({
              'id': 486001,
              'name': 'SPY×FAMILY Season 3',
              'name_cn': '间谍过家家 第三季',
              'date': '2025-10-04',
              'rating': {'score': 8.0},
              'images': {'large': 'https://bgm.example/spy_s3.jpg'},
            });
          }
          if (path.endsWith('/subjects/411428')) {
            return _jsonResp({
              'id': 411428,
              'name': '劇場版 SPY×FAMILY CODE: White',
              'name_cn': '剧场版 间谍过家家 代号：白',
              'date': '2023-12-22',
              'rating': {'score': 7.7},
              'images': {'large': 'https://bgm.example/spy_movie.jpg'},
            });
          }
          if (path.endsWith('/subjects/329906/subjects') ||
              path.endsWith('/subjects/404804/subjects') ||
              path.endsWith('/subjects/486001/subjects') ||
              path.endsWith('/subjects/411428/subjects')) {
            return _jsonResp([]);
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
        final orchestrator = ScrapeOrchestrator(
          repository: repo,
          tmdbService: TmdbService(httpClient: httpClient),
          bangumiService: BangumiService(httpClient: httpClient),
          gatewayBuilder: (s) async => LocalSourceGateway(rootPath: s.location),
          computeWorker: const ScrapeComputeWorker(useIsolate: false),
        );

        await orchestrator.scanAndScrapeSource(source);

        // 2. 验证拆分为 4 部独立作品且自动编入同一个 SeriesGroup
        final works = await repo.getAllWorks();
        expect(
          works,
          hasLength(4),
          reason:
              '实际入库作品: ${works.map((w) => '${w.title}(tmdb=${w.tmdbId},season=${w.matchedSeason},status=${w.scrapeStatus},reason=${w.reviewReason})').join('; ')}',
        );

        final movieCandidates = works
            .where(
              (w) =>
                  w.tmdbId == 968051 && w.tmdbMediaType == TmdbMediaType.movie,
            )
            .toList();
        expect(
          movieCandidates,
          hasLength(1),
          reason:
              '未匹配到电影 968051，当前作品列表: ${works.map((w) => '${w.title}(tmdb=${w.tmdbId},type=${w.tmdbMediaType},season=${w.matchedSeason},status=${w.scrapeStatus},reason=${w.reviewReason})').join(' | ')}',
        );
        final worksSummary = works
            .map(
              (w) =>
                  '${w.title}(tmdb=${w.tmdbId},type=${w.tmdbMediaType},season=${w.matchedSeason},status=${w.scrapeStatus},reason=${w.reviewReason})',
            )
            .join(' | ');
        final s1Candidates = works
            .where((w) => w.tmdbId == 120089 && w.matchedSeason == 1)
            .toList();
        expect(s1Candidates, hasLength(1), reason: '作品总览: $worksSummary');
        final s2Candidates = works
            .where((w) => w.tmdbId == 120089 && w.matchedSeason == 2)
            .toList();
        expect(s2Candidates, hasLength(1), reason: '作品总览: $worksSummary');
        final s3Candidates = works
            .where((w) => w.tmdbId == 120089 && w.matchedSeason == 3)
            .toList();
        expect(s3Candidates, hasLength(1), reason: '作品总览: $worksSummary');
        final s1Work = s1Candidates.single;
        final s2Work = s2Candidates.single;
        final s3Work = s3Candidates.single;
        final movieWork = movieCandidates.single;

        final seriesId = s1Work.seriesId;
        expect(seriesId, isNotNull);
        expect(s2Work.seriesId, seriesId);
        expect(s3Work.seriesId, seriesId);
        expect(movieWork.seriesId, seriesId);

        final group = await repo.findSeriesGroupById(seriesId!);
        expect(group, isNotNull);

        // 3. 验证 WorkDetailBundle 中的公共共享 vs Scan S3 季独占语义
        final container = ProviderContainer(
          overrides: [
            libraryRepositoryProvider.overrideWithValue(repo),
            tmdbNetworkConfigProvider.overrideWith(
              (_) async => const TmdbNetworkConfig(credential: 'test-tmdb-key'),
            ),
          ],
        );
        addTearDown(container.dispose);

        Future<WorkDetailBundle> bundleOf(String workId) async {
          final b = await container.read(workDetailBundleProvider(workId).future);
          expect(b, isNotNull);
          return b!;
        }

        final s1Bundle = await bundleOf(s1Work.id);
        final s2Bundle = await bundleOf(s2Work.id);
        final s3Bundle = await bundleOf(s3Work.id);
        final movieBundle = await bundleOf(movieWork.id);

        // CD 与 Creditless/Menu/PV 特典全部标记为 seriesShared 并向全部 4 部作品曝光
        for (final b in [s1Bundle, s2Bundle, s3Bundle, movieBundle]) {
          expect(
            b.cdVariants.map((v) => v.fileName).toList(),
            contains('Original Soundtrack.flac'),
          );
          expect(b.cdVariants.single.assetScope, SupplementaryAssetScope.seriesShared);

          final extraNames = b.variants
              .where((v) => v.assetKind == AssetKind.video)
              .map((v) => v.fileName)
              .toSet();
          expect(
            extraNames,
            containsAll(['NCOP1.mkv', 'Menu01.mkv', 'PV01.mkv']),
          );
        }

        // Scan S3 仅在第 3 季独占可见，其余第 1/2 季与剧场版均为空
        expect(
          s3Bundle.scanVariants.map((v) => v.fileName).toList(),
          ['Booklet_01.jpg'],
        );
        expect(
          s3Bundle.scanVariants.single.assetScope,
          SupplementaryAssetScope.workExclusive,
        );
        expect(s1Bundle.scanVariants, isEmpty);
        expect(s2Bundle.scanVariants, isEmpty);
        expect(movieBundle.scanVariants, isEmpty);

        // 4. 人工编辑系列标签顺序与附属共享范围，验证重扫保持 seriesLocked 与 scopeLocked
        await container.read(workManagementProvider).saveSeriesGroupConfig(
          seriesId: seriesId,
          title: 'SPY×FAMILY 家族系列合集',
          members: [
            SeriesMemberEdit(workId: movieWork.id, order: 1, label: '剧场版 Code: White'),
            SeriesMemberEdit(workId: s1Work.id, order: 2, label: '第 1 季'),
            SeriesMemberEdit(workId: s2Work.id, order: 3, label: '第 2 季'),
            SeriesMemberEdit(workId: s3Work.id, order: 4, label: '第 3 季'),
          ],
        );

        final pvItem = s1Bundle.editableSupplementaryItems.firstWhere(
          (e) => e.variant.fileName == 'PV01.mkv',
        );
        await container.read(workManagementProvider).updateSupplementaryScopes([
          SupplementaryScopeEdit(
            variantId: pvItem.variant.id,
            scope: SupplementaryAssetScope.workExclusive,
            targetWorkId: s2Work.id,
          ),
        ]);

        // 再次全库重扫验证人工修改彻底锁定
        await orchestrator.scanAndScrapeSource(source);

        final lockedMovie = await repo.findWorkById(movieWork.id);
        expect(lockedMovie!.seriesLocked, isTrue);
        expect(lockedMovie.seriesLabel, '剧场版 Code: White');
        expect(lockedMovie.seriesOrder, 1);

        final postS1 = await container.refresh(workDetailBundleProvider(s1Work.id).future);
        final postS2 = await container.refresh(workDetailBundleProvider(s2Work.id).future);
        final postS3 = await container.refresh(workDetailBundleProvider(s3Work.id).future);
        final postMovie = await container.refresh(workDetailBundleProvider(movieWork.id).future);

        expect(
          postS2!.variants.any((v) => v.fileName == 'PV01.mkv'),
          isTrue,
        );
        expect(
          postS1!.variants.any((v) => v.fileName == 'PV01.mkv'),
          isFalse,
        );
        expect(
          postS3!.variants.any((v) => v.fileName == 'PV01.mkv'),
          isFalse,
        );
        expect(
          postMovie!.variants.any((v) => v.fileName == 'PV01.mkv'),
          isFalse,
        );
      },
    );

    testWidgets('WorkDetailPage 底部紧凑下拉切换同系列成员实现平滑原地切换', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      final dbLocal = KonataDatabase(NativeDatabase.memory());
      addTearDown(dbLocal.close);
      final repoLocal = DriftLibraryRepository(dbLocal);

      final now = DateTime.now();
      await repoLocal.upsertSeriesGroup(
        SeriesGroup(
          id: 'series-widget-1',
          title: '间谍过家家系列',
          createdAt: now,
          updatedAt: now,
        ),
      );
      await repoLocal.upsertWork(
        const Work(
          id: 'w-s1',
          title: '间谍过家家 第一季',
          year: 2022,
          bangumiScore: 8.1,
          tmdbId: 120089,
          tmdbMediaType: TmdbMediaType.tv,
          matchedSeason: 1,
          scrapeStatus: ScrapeStatus.matched,
          seriesId: 'series-widget-1',
          seriesOrder: 1,
          seriesLabel: '第 1 季',
        ),
      );
      await repoLocal.upsertWork(
        const Work(
          id: 'w-movie',
          title: '剧场版 间谍过家家 代号：白',
          year: 2023,
          bangumiScore: 7.7,
          tmdbId: 968051,
          tmdbMediaType: TmdbMediaType.movie,
          scrapeStatus: ScrapeStatus.matched,
          seriesId: 'series-widget-1',
          seriesOrder: 2,
          seriesLabel: '剧场版 Code: White',
        ),
      );
      await repoLocal.upsertEpisode(
        const Episode(
          id: 'ep-s1-1',
          workId: 'w-s1',
          seasonNumber: 1,
          episodeNumber: 1,
          category: EpisodeCategory.main,
          title: '行动〈枭〉第一话',
        ),
      );
      await repoLocal.upsertEpisode(
        const Episode(
          id: 'ep-mov-1',
          workId: 'w-movie',
          seasonNumber: 1,
          episodeNumber: 1,
          category: EpisodeCategory.main,
          title: '剧场版 正片',
        ),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            libraryRepositoryProvider.overrideWithValue(repoLocal),
            tmdbImageLoaderProvider.overrideWithValue(
              (_, {targetWidth, imageSize}) async => _transparentPng,
            ),
            tmdbNetworkConfigProvider.overrideWith(
              (_) async => const TmdbNetworkConfig(),
            ),
          ],
          child: Consumer(
            builder: (context, ref, _) => MaterialApp(
              locale: const Locale('zh', 'CN'),
              supportedLocales: const [Locale('zh', 'CN')],
              localizationsDelegates: GlobalMaterialLocalizations.delegates,
              theme: KonataTheme.darkTheme(),
              darkTheme: KonataTheme.darkTheme(),
              themeMode: ref.watch(themeModeProvider),
              home: const WorkDetailPage(workId: 'w-s1'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 验证第 1 季界面及 SeriesSwitcherDropdown 存在
      expect(find.text('间谍过家家 第一季'), findsOneWidget);
      expect(find.byType(SeriesSwitcherDropdown), findsOneWidget);
      expect(find.text('第 1 季'), findsOneWidget);

      // 展开系列下拉浮层，切换至剧场版
      await tester.tap(find.byType(SeriesSwitcherDropdown));
      await tester.pumpAndSettle();

      expect(find.text('剧场版 Code: White'), findsOneWidget);
      await tester.tap(find.text('剧场版 Code: White'));
      await tester.pumpAndSettle();

      // 同页原地切换，展示剧场版标题与标签，未退回上一页
      expect(find.byType(WorkDetailPage), findsOneWidget);
      expect(find.text('剧场版 间谍过家家 代号：白'), findsOneWidget);
      expect(find.textContaining('2023'), findsOneWidget);
    });
  });
}
