import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ccplayer/application/providers/artwork_provider.dart';
import 'package:ccplayer/application/providers/library_providers.dart';
import 'package:ccplayer/application/providers/work_split_and_series_actions.dart';
import 'package:ccplayer/application/scraping/scrape_compute_worker.dart';
import 'package:ccplayer/application/scraping/scrape_orchestrator.dart';
import 'package:ccplayer/domain/matching/directory_grouper.dart';
import 'package:ccplayer/domain/matching/episode_title_formatter.dart';
import 'package:ccplayer/domain/models/media_source.dart';
import 'package:ccplayer/domain/models/media_variant.dart';
import 'package:ccplayer/domain/models/network_config.dart';
import 'package:ccplayer/domain/models/tmdb_models.dart';
import 'package:ccplayer/domain/models/work.dart';
import 'package:ccplayer/domain/scraping/bangumi_models.dart';
import 'package:ccplayer/domain/scraping/scrape_domain_adapter.dart';
import 'package:ccplayer/domain/scraping/search_query_sanitizer.dart';
import 'package:ccplayer/infrastructure/database/drift_library_repository.dart';
import 'package:ccplayer/infrastructure/database/konata_database.dart';
import 'package:ccplayer/infrastructure/network/bangumi_service.dart';
import 'package:ccplayer/infrastructure/network/priority_http_scheduler.dart';
import 'package:ccplayer/infrastructure/network/tmdb_http_client.dart';
import 'package:ccplayer/infrastructure/network/tmdb_service.dart';
import 'package:ccplayer/infrastructure/sources/local_source_gateway.dart';
import 'package:ccplayer/presentation/dialogs/manual_match_dialog.dart';
import 'package:ccplayer/presentation/theme/konata_theme.dart';
import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
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

void main() {
  group('86 单集识别、Bangumi 分级净化与 TMDB 跨源校验回归', () {
    late Directory tempRoot;
    late KonataDatabase db;
    late DriftLibraryRepository repo;

    setUp(() async {
      tempRoot = await Directory.systemTemp.createTemp('konata_86_reg_');
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

    test('SearchQuerySanitizer 净化负号陷阱并提取分级查询与快捷填入词', () {
      expect(
        SearchQuerySanitizer.sanitize('86 -不存在的战区- 第2部分'),
        '86 不存在的战区 第2部分',
      );
      final fallbacks = SearchQuerySanitizer.buildBangumiFallbackQueries(
        '86 -不存在的战区- 第2部分',
      );
      expect(fallbacks.first, '86 不存在的战区 第2部分');
      expect(fallbacks, containsAll(['86 不存在的战区', '86', '不存在的战区']));

      final quick = SearchQuerySanitizer.buildQuickSourceTerms(
        const [
          (
            fileName:
                '[UHA-WINGS&VCB-Studio] EIGHTY SIX [01][Ma10p_1080p][x265_flac_aac].mkv',
            relativePath:
                'EIGHTY SIX/[UHA-WINGS&VCB-Studio] EIGHTY SIX [01][Ma10p_1080p][x265_flac_aac].mkv',
          ),
        ],
        excludeQuery: '86 -不存在的战区- 第2部分',
      );
      expect(quick, contains('EIGHTY SIX'));
    });

    test('BangumiService.searchSubjectsProgressive 净化连字符并分层补全初代与第2部分', () async {
      final queriesSent = <String>[];
      final mockClient = MockClient((request) async {
        if (request.url.path == '/v0/search/subjects' &&
            request.method == 'POST') {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          final kw = (body['keyword'] ?? '').toString();
          queriesSent.add(kw);
          // 模拟带“第2部分”精准长词条时只返回第 2 部分或无母系列
          if (kw == '86 不存在的战区 第2部分') {
            return _jsonResp({
              'data': [
                {
                  'id': 341163,
                  'name': '86―エイティシックス― 第2クール',
                  'name_cn': '86 -不存在的战区- 第2部分',
                  'date': '2021-10-02',
                  'total_episodes': 12,
                  'rating': {'score': 8.0},
                  'images': {'large': 'https://lain.bgm.tv/86_p2.jpg'},
                },
              ],
            });
          }
          if (kw == '86 不存在的战区' || kw == '86') {
            return _jsonResp({
              'data': [
                {
                  'id': 302189,
                  'name': '86―エイティシックス―',
                  'name_cn': '86 -不存在的战区-',
                  'date': '2021-04-10',
                  'total_episodes': 11,
                  'rating': {'score': 7.6},
                  'images': {'large': 'https://lain.bgm.tv/86_p1.jpg'},
                },
                {
                  'id': 341163,
                  'name': '86―エイティシックス― 第2クール',
                  'name_cn': '86 -不存在的战区- 第2部分',
                  'date': '2021-10-02',
                  'total_episodes': 12,
                  'rating': {'score': 8.0},
                  'images': {'large': 'https://lain.bgm.tv/86_p2.jpg'},
                },
              ],
            });
          }
          return _jsonResp({'data': []});
        }
        return _jsonResp({});
      });

      final httpClient = TmdbHttpClient(
        config: const TmdbNetworkConfig(credential: 'dummy'),
        scheduler: PriorityHttpScheduler(),
        httpClient: mockClient,
      );
      final bgm = BangumiService(httpClient: httpClient);
      final results = await bgm.searchSubjectsProgressive(
        '86 -不存在的战区- 第2部分',
        priority: RequestPriority.interactive,
      );

      expect(queriesSent.every((q) => !q.contains('-不存在的战区-')), isTrue);
      expect(queriesSent.first, '86 不存在的战区 第2部分');
      expect(results.map((e) => e.id).toSet(), {341163, 302189});
    });

    test(
      '单集 [01] 全自动刮削命中初代《86》、绝不被第2部分/Auftrag Schutzengel污染、且成功救回 TMDB 100565 横版背景图与单集名',
      () async {
        const fileName =
            '[UHA-WINGS&VCB-Studio] EIGHTY SIX [01][Ma10p_1080p][x265_flac_aac].mkv';
        await touchFile('EIGHTY SIX/$fileName');

        final source = MediaSource(
          id: 'src_86',
          kind: MediaSourceKind.local,
          label: 'Local 86',
          location: tempRoot.path,
        );
        await repo.upsertMediaSource(source);

        final requestedPaths = <String>[];
        final mockClient = MockClient((request) async {
          requestedPaths.add(request.url.path);
          if (request.url.host.contains('bgm.tv')) {
            if (request.url.path == '/v0/search/subjects' &&
                request.method == 'POST') {
              return _jsonResp({
                'data': [
                  {
                    'id': 341163,
                    'name': '86―エイティシックス― 第2クール',
                    'name_cn': '86 -不存在的战区- 第2部分',
                    'date': '2021-10-02',
                    'total_episodes': 12,
                    'rating': {'score': 8.0},
                    'images': {'large': 'https://lain.bgm.tv/86_p2.jpg'},
                    'infobox': [
                      {'key': '别名', 'value': 'EIGHTY SIX Part 2'},
                    ],
                  },
                  {
                    'id': 302189,
                    'name': '86―エイティシックス―',
                    'name_cn': '86 -不存在的战区-',
                    'date': '2021-04-10',
                    'total_episodes': 11,
                    'rating': {'score': 7.6},
                    'images': {'large': 'https://lain.bgm.tv/86_p1.jpg'},
                    'infobox': [
                      {'key': '别名', 'value': 'EIGHTY SIX'},
                    ],
                  },
                ],
              });
            }
            if (request.url.path == '/v0/subjects/302189') {
              return _jsonResp({
                'id': 302189,
                'name': '86―エイティシックス―',
                'name_cn': '86 -不存在的战区-',
                'date': '2021-04-10',
                'total_episodes': 11,
                'rating': {'score': 7.6},
                'summary': '初代 86 简介。',
                'images': {'large': 'https://lain.bgm.tv/86_p1.jpg'},
                'infobox': [
                  {'key': '别名', 'value': 'EIGHTY SIX'},
                ],
              });
            }
            if (request.url.path == '/v0/subjects/341163') {
              return _jsonResp({
                'id': 341163,
                'name': '86―エイティシックス― 第2クール',
                'name_cn': '86 -不存在的战区- 第2部分',
                'date': '2021-10-02',
                'total_episodes': 12,
                'rating': {'score': 8.0},
                'summary': '第 2 部分简介。',
                'images': {'large': 'https://lain.bgm.tv/86_p2.jpg'},
                'infobox': [
                  {'key': '别名', 'value': 'EIGHTY SIX Part 2'},
                ],
              });
            }
            if (request.url.path == '/v0/episodes') {
              final sid = request.url.queryParameters['subject_id'];
              if (sid == '341163') {
                return _jsonResp({
                  'data': [
                    {
                      'id': 90012,
                      'ep': 1,
                      'sort': 12,
                      'type': 0,
                      'name': 'せめて、人間らしく',
                      'name_cn': '至少要像个人类',
                    },
                  ],
                });
              }
              if (sid == '302189') {
                return _jsonResp({
                  'data': [
                    {
                      'id': 90001,
                      'ep': 1,
                      'sort': 1,
                      'type': 0,
                      'name': 'アンダーテイカー',
                      'name_cn': 'Undertaker',
                    },
                  ],
                });
              }
            }
            return _jsonResp({}, 404);
          }

          // 模拟 TMDB 接口返回分支
          final path = request.url.path;
          final query =
              (request.url.queryParameters['query'] ?? '').toLowerCase();
          if (path.endsWith('/search/movie')) {
            return _jsonResp({
              'results': [
                {
                  'id': 999001,
                  'title': 'Auftrag Schutzengel',
                  'original_title': 'Auftrag Schutzengel',
                  'release_date': '2001-01-01',
                  'genre_ids': [18],
                  'backdrop_path': null,
                },
              ],
            });
          }
          if (path.endsWith('/search/tv')) {
            // 仅当包含净化后中文/86主词时才命中 TMDB 100565（验证二次救回 & TV 过滤）。
            if (query.contains('不存在的战区') || query == '86') {
              return _jsonResp({
                'results': [
                  {
                    'id': 100565,
                    'name': '86 -不存在的战区-',
                    'original_name': '86―エイティシックス―',
                    'first_air_date': '2021-04-11',
                    'genre_ids': [16, 18, 10759],
                    'poster_path': '/86_tmdb_poster.jpg',
                    'backdrop_path': '/86_backdrop_16x9.jpg',
                  },
                ],
              });
            }
            return _jsonResp({'results': []});
          }
          if (path.endsWith('/tv/100565')) {
            return _jsonResp({
              'id': 100565,
              'name': '86 -不存在的战区-',
              'original_name': '86―エイティシックス―',
              'first_air_date': '2021-04-11',
              'overview': '为了应对邻国无人战斗机的进攻……',
              'genre_ids': [16, 18, 10759],
              'genres': [
                {'id': 16, 'name': '动画'},
                {'id': 18, 'name': '剧情'},
              ],
              'poster_path': '/86_tmdb_poster.jpg',
              'backdrop_path': '/86_backdrop_16x9.jpg',
              'seasons': [
                {
                  'season_number': 1,
                  'name': '第 1 季',
                  'episode_count': 23,
                  'air_date': '2021-04-11',
                },
              ],
              'images': {
                'backdrops': [
                  {
                    'file_path': '/86_backdrop_16x9.jpg',
                    'aspect_ratio': 1.778,
                    'width': 1920,
                    'height': 1080,
                    'vote_average': 5.6,
                  },
                ],
                'logos': [
                  {'file_path': '/86_logo.png', 'iso_639_1': 'zh'},
                ],
              },
            });
          }
          if (path.endsWith('/tv/100565/season/1')) {
            return _jsonResp({
              'season_number': 1,
              'name': '第 1 季',
              'air_date': '2021-04-11',
              'episodes': [
                {
                  'episode_number': 1,
                  'name': 'Undertaker',
                  'overview': '第1话剧情简介',
                  'still_path': '/ep1_still.jpg',
                },
              ],
            });
          }
          return _jsonResp({});
        });

        final httpClient = TmdbHttpClient(
          config: const TmdbNetworkConfig(credential: 'dummy_v3_key'),
          scheduler: PriorityHttpScheduler(),
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

        // 带 [01] 的单文件电视动画绝不应去查 /search/movie
        expect(requestedPaths.any((e) => e.endsWith('/search/movie')), isFalse);

        final works = await repo.getAllWorks();
        expect(works, hasLength(1));
        final w = works.single;
        expect(w.scrapeStatus, ScrapeStatus.matched);
        expect(w.bangumiId, 302189);
        expect(w.tmdbId, 100565);
        expect(w.tmdbMediaType, TmdbMediaType.tv);
        expect(w.title, '86 -不存在的战区-');
        expect(w.title.toLowerCase(), isNot(contains('auftrag')));
        expect(w.backdropPath, '/86_backdrop_16x9.jpg');
        expect(w.logoPath, '/86_logo.png');

        final episodes = await repo.getEpisodesByWork(w.id);
        expect(episodes, hasLength(1));
        final ep = episodes.single;
        expect(ep.episodeNumber, 1);
        expect(ep.stillPath, '/ep1_still.jpg');
        expect(
          EpisodeTitleFormatter.formatCardTitle(
            episode: ep,
            workTitle: w.title,
            workMediaType: w.tmdbMediaType,
            mainEpisodeCount: episodes.length,
          ),
          '01 · Undertaker',
        );
      },
    );

    test('跨源不一致熔断：TMDB 为无关非动画条目时绝不将 top5.first 污染写入作品', () {
      const folder = GroupedWorkFolder(
        folderRelativePath: 'EIGHTY SIX',
        folderName: 'EIGHTY SIX',
        cleanTitle: 'EIGHTY SIX',
        mainEpisodeNumbers: [1],
        variants: [
          MediaVariant(
            id: 'v_86_mock',
            workId: 'w_86_mock',
            sourceId: 'src_local',
            relativePath:
                'EIGHTY SIX/[UHA-WINGS&VCB-Studio] EIGHTY SIX [01][Ma10p_1080p][x265_flac_aac].mkv',
            fileName:
                '[UHA-WINGS&VCB-Studio] EIGHTY SIX [01][Ma10p_1080p][x265_flac_aac].mkv',
            fileSize: 1024,
          ),
        ],
      );
      const tmdbGarbage = TmdbWorkDetail(
        tmdbId: 999001,
        mediaType: TmdbMediaType.movie,
        title: 'Auftrag Schutzengel',
        originalTitle: 'Auftrag Schutzengel',
        year: 2001,
        genreIds: [18],
      );
      const bgm86 = BangumiSubjectCandidate(
        id: 302189,
        name: '86―エイティシックス―',
        nameCn: '86 -不存在的战区-',
        year: 2021,
        totalEpisodes: 11,
        aliases: ['EIGHTY SIX'],
      );

      final decision = ScrapeDomainAdapter.evaluateMatch(
        folder,
        const [tmdbGarbage],
        bangumiCandidates: const [bgm86],
      );
      expect(decision.best, isNull);
      expect(decision.bestBangumi?.subject.id, 302189);
    });

    test('手动「仅 Bangumi」绑定保留 Bangumi 全字段并在缺图时静默回填高置信度动画 TMDB 背景图', () async {
      await repo.upsertMediaSource(
        MediaSource(
          id: 'src_local',
          kind: MediaSourceKind.local,
          label: 'Local Test',
          location: tempRoot.path,
        ),
      );
      const work = Work(
        id: 'w_86_manual',
        title: 'EIGHTY SIX',
        scrapeStatus: ScrapeStatus.unmatched,
      );
      await repo.upsertWork(work);
      await repo.upsertMediaVariant(
        const MediaVariant(
          id: 'v_86_01',
          workId: 'w_86_manual',
          sourceId: 'src_local',
          relativePath:
              'EIGHTY SIX/[UHA-WINGS&VCB-Studio] EIGHTY SIX [01][Ma10p_1080p][x265_flac_aac].mkv',
          fileName:
              '[UHA-WINGS&VCB-Studio] EIGHTY SIX [01][Ma10p_1080p][x265_flac_aac].mkv',
          fileSize: 1024,
        ),
      );

      final mockClient = MockClient((request) async {
        if (request.url.host.contains('bgm.tv')) {
          if (request.url.path == '/v0/episodes') {
            return _jsonResp({'data': []});
          }
          return _jsonResp({});
        }
        if (request.url.path.endsWith('/search/tv')) {
          return _jsonResp({
            'results': [
              {
                'id': 999001,
                'name': '86 Live Action Fake',
                'original_name': '86 Live Action Fake',
                'first_air_date': '2021-04-01',
                'genre_ids': [18],
                'backdrop_path': '/wrong_non_anime.jpg',
              },
              {
                'id': 100565,
                'name': '86 -不存在的战区-',
                'original_name': '86―エイティシックス―',
                'first_air_date': '2021-04-11',
                'genre_ids': [16, 18],
                'backdrop_path': '/86_silent_bd.jpg',
              },
            ],
          });
        }
        return _jsonResp({});
      });

      final httpClient = TmdbHttpClient(
        config: const TmdbNetworkConfig(credential: 'dummy'),
        scheduler: PriorityHttpScheduler(),
        httpClient: mockClient,
      );
      final container = ProviderContainer(
        overrides: [libraryRepositoryProvider.overrideWithValue(repo)],
      );
      addTearDown(container.dispose);

      // 读取一条轻量 FutureProvider 来拿到 Ref 执行 executeBangumiOnlyBind。
      final testProvider = FutureProvider<Work>((ref) {
        return executeBangumiOnlyBind(
          ref,
          workId: work.id,
          bangumiSubject: const BangumiSubjectCandidate(
            id: 302189,
            name: '86―エイティシックス―',
            nameCn: '86 -不存在的战区-',
            year: 2021,
            summary: '纯正 Bangumi 简介',
            posterUrl: 'https://lain.bgm.tv/86_bgm_cover.jpg',
            score: 7.6,
          ),
          bangumiServiceOverride: BangumiService(httpClient: httpClient),
          tmdbServiceOverride: TmdbService(httpClient: httpClient),
        );
      });

      final bound = await container.read(testProvider.future);
      expect(bound.title, '86 -不存在的战区-');
      expect(bound.overview, '纯正 Bangumi 简介');
      expect(bound.bangumiScore, 7.6);
      expect(bound.posterPath, 'https://lain.bgm.tv/86_bgm_cover.jpg');
      expect(bound.backdropPath, '/86_silent_bd.jpg');
      expect(bound.tmdbId, isNull);

      final eps = await repo.getEpisodesByWork(work.id);
      expect(eps, hasLength(1));
      expect(eps.single.episodeNumber, 1);
      expect(eps.single.title, '第 01 话');
    });

    testWidgets('ManualMatchDialog 展示源文件名清洗快捷填入胶囊并支持一键填入搜索框', (
      tester,
    ) async {
      await repo.upsertMediaSource(
        MediaSource(
          id: 'src_local',
          kind: MediaSourceKind.local,
          label: 'Local Test',
          location: tempRoot.path,
        ),
      );
      const work = Work(
        id: 'w_dialog_86',
        title: '86 -不存在的战区- 第2部分',
      );
      await repo.upsertWork(work);
      await repo.upsertMediaVariant(
        const MediaVariant(
          id: 'v_d_1',
          workId: 'w_dialog_86',
          sourceId: 'src_local',
          relativePath:
              'EIGHTY SIX/[UHA-WINGS&VCB-Studio] EIGHTY SIX [01][Ma10p_1080p][x265_flac_aac].mkv',
          fileName:
              '[UHA-WINGS&VCB-Studio] EIGHTY SIX [01][Ma10p_1080p][x265_flac_aac].mkv',
          fileSize: 1024,
        ),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            libraryRepositoryProvider.overrideWithValue(repo),
            tmdbImageLoaderProvider.overrideWithValue(
              (String url, {int? targetWidth, TmdbImageSize? imageSize}) async =>
                  Uint8List(0),
            ),
          ],
          child: MaterialApp(
            theme: KonataTheme.darkTheme(),
            home: const Scaffold(
              body: ManualMatchDialog(
                workId: 'w_dialog_86',
                initialQuery: '86 -不存在的战区- 第2部分',
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 快捷填入胶囊应提取出 EIGHTY SIX 且点击后直接填入输入框
      expect(find.text('EIGHTY SIX'), findsOneWidget);
      await tester.tap(find.text('EIGHTY SIX'));
      await tester.pump();

      final textFields = tester.widgetList<TextField>(find.byType(TextField));
      expect(
        textFields.any((tf) => tf.controller?.text == 'EIGHTY SIX'),
        isTrue,
      );
    });
  });
}
