import 'dart:convert';
import 'dart:io';

import 'package:konata/application/providers/artwork_provider.dart';
import 'package:konata/application/providers/library_providers.dart';
import 'package:konata/application/providers/work_management_provider.dart';
import 'package:konata/application/scraping/scrape_compute_worker.dart';
import 'package:konata/application/scraping/scrape_orchestrator.dart';
import 'package:konata/application/scraping/scrape_work_persister.dart';
import 'package:konata/domain/matching/directory_grouper.dart';
import 'package:konata/domain/models/episode.dart';
import 'package:konata/domain/models/media_source.dart';
import 'package:konata/domain/models/media_variant.dart';
import 'package:konata/domain/models/network_config.dart';
import 'package:konata/domain/models/tmdb_models.dart';
import 'package:konata/domain/models/work.dart';
import 'package:konata/infrastructure/database/drift_library_repository.dart';
import 'package:konata/infrastructure/database/konata_database.dart';
import 'package:konata/infrastructure/network/bangumi_service.dart';
import 'package:konata/infrastructure/network/priority_http_scheduler.dart';
import 'package:konata/infrastructure/network/tmdb_http_client.dart';
import 'package:konata/infrastructure/network/tmdb_service.dart';
import 'package:konata/infrastructure/sources/local_source_gateway.dart';
import 'package:konata/presentation/dialogs/work_artwork_picker_dialog.dart';
import 'package:konata/presentation/theme/konata_theme.dart';
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

// 1x1 透明 PNG，用于 ManagedImage 离线加载测试。
const List<int> _kTinyPngBytes = <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
];



void main() {
  group('Bangumi 在线 API 双引擎与实机回归测试', () {
    late Directory tempRoot;
    late KonataDatabase db;
    late DriftLibraryRepository repo;

    setUp(() async {
      tempRoot = await Directory.systemTemp.createTemp('konata_bgm_reg_');
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
      '1. Wake Up, Girls! 第一季 vs 新章独立季身份 + Bangumi 封面与剧场版交叉救援 + 零角色接口调用',
      () async {
        // S1: 12 集；新章: 13 集；剧场版: 七人的偶像
        for (var i = 1; i <= 12; i++) {
          final ep = i.toString().padLeft(2, '0');
          await touchFile(
            'Wake Up, Girls!/[VCB-Studio] Wake Up, Girls! [$ep][Ma10p_1080p].mkv',
          );
        }
        for (var i = 1; i <= 13; i++) {
          final ep = i.toString().padLeft(2, '0');
          await touchFile(
            'Wake Up, Girls! 新章/[VCB-Studio] Wake Up, Girls! Shin Shou [$ep][Ma10p_1080p].mkv',
          );
        }
        await touchFile(
          'Wake Up, Girls! 七人的偶像/[VCB-Studio] Wake Up, Girls! Shichinin no Idol [Ma10p_1080p].mkv',
        );

        final source = MediaSource(
          id: 'src-wug',
          kind: MediaSourceKind.local,
          label: 'WUG测试盘',
          location: tempRoot.path,
        );
        await repo.upsertMediaSource(source);

        final requestedPaths = <String>[];
        final mockClient = MockClient((request) async {
          requestedPaths.add('${request.url.host}${request.url.path}');

          // Bangumi API（严格禁止调用 /characters 或 /persons）
          if (request.url.host == 'api.bgm.tv') {
            if (request.url.path == '/v0/search/subjects') {
              final body = jsonDecode(request.body) as Map<String, dynamic>;
              final kw = (body['keyword'] ?? '').toString().toLowerCase();
              if (kw.contains('新章') || kw.contains('shin')) {
                return _jsonResp({
                  'data': [
                    {
                      'id': 199392,
                      'name': 'Wake Up, Girls! 新章',
                      'name_cn': 'Wake Up, Girls! 新章',
                      'date': '2017-10-09',
                      'eps': 13,
                      'summary': '新章讲述七名少女迎来新挑战的故事。',
                      'images': {
                        'large': 'https://lain.bgm.tv/pic/cover/l/wug_s2.jpg',
                      },
                    },
                  ],
                });
              }
              if (kw.contains('七人') || kw.contains('idol')) {
                return _jsonResp({
                  'data': [
                    {
                      'id': 88424,
                      'name': 'Wake Up, Girls! 七人のアイドル',
                      'name_cn': 'Wake Up, Girls! 七人的偶像',
                      'date': '2014-01-10',
                      'eps': 1,
                      'platform': '剧场版',
                      'summary': '仙台地方偶像团体集结成军的剧场版起点。',
                      'images': {
                        'large': 'https://lain.bgm.tv/pic/cover/l/wug_m1.jpg',
                      },
                    },
                  ],
                });
              }
              return _jsonResp({
                'data': [
                  {
                    'id': 81446,
                    'name': 'Wake Up, Girls!',
                    'name_cn': 'Wake Up, Girls!',
                    'date': '2014-01-10',
                    'eps': 12,
                    'summary': '第一季正篇简介。',
                    'images': {
                      'large': 'https://lain.bgm.tv/pic/cover/l/wug_s1.jpg',
                    },
                  },
                ],
              });
            }
            if (request.url.path == '/v0/subjects/81446') {
              return _jsonResp({
                'id': 81446,
                'name': 'Wake Up, Girls!',
                'name_cn': 'Wake Up, Girls!',
                'date': '2014-01-10',
                'total_episodes': 12,
                'summary': '第一季完整简介。',
                'images': {
                  'large': 'https://lain.bgm.tv/pic/cover/l/wug_s1.jpg',
                },
                'infobox': [],
              });
            }
            if (request.url.path == '/v0/subjects/199392') {
              return _jsonResp({
                'id': 199392,
                'name': 'Wake Up, Girls! 新章',
                'name_cn': 'Wake Up, Girls! 新章',
                'date': '2017-10-09',
                'total_episodes': 13,
                'summary': '新章完整简介。',
                'images': {
                  'large': 'https://lain.bgm.tv/pic/cover/l/wug_s2.jpg',
                },
                'infobox': [
                  {'key': '别名', 'value': 'Wake Up, Girls! Shin Shou'},
                ],
              });
            }
            if (request.url.path == '/v0/subjects/88424') {
              return _jsonResp({
                'id': 88424,
                'name': 'Wake Up, Girls! 七人のアイドル',
                'name_cn': 'Wake Up, Girls! 七人的偶像',
                'date': '2014-01-10',
                'total_episodes': 1,
                'platform': '剧场版',
                'summary': '剧场版完整简介。',
                'images': {
                  'large': 'https://lain.bgm.tv/pic/cover/l/wug_m1.jpg',
                },
                'infobox': [
                  {'key': '别名', 'value': 'Wake Up, Girls! Seven Idols'},
                ],
              });
            }
            if (request.url.path == '/v0/episodes') {
              return _jsonResp({'data': []});
            }
            return http.Response('not found', 404);
          }

          // 模拟 TMDB 接口返回分支
          final path = request.url.path;
          final query = (request.url.queryParameters['query'] ?? '')
              .toLowerCase();
          if (path.endsWith('/search/tv')) {
            if (query.contains('wake up')) {
              return _jsonResp({
                'results': [
                  {
                    'id': 56055,
                    'name': 'Wake Up, Girls!',
                    'original_name': 'Wake Up, Girls!',
                    'first_air_date': '2014-01-10',
                  },
                ],
              });
            }
            return _jsonResp({'results': []});
          }
          if (path.endsWith('/search/movie')) {
            // 仅当使用 Bangumi 交叉词 `七人のアイドル` 或 `七人的偶像` / `seven idols` 才命中 TMDB 电影
            if (query.contains('七人のアイドル') ||
                query.contains('七人的偶像') ||
                query.contains('seven idols')) {
              return _jsonResp({
                'results': [
                  {
                    'id': 250101,
                    'title': 'Wake Up, Girls! 七位偶像',
                    'original_title': 'Wake Up, Girls! 七人のアイドル',
                    'release_date': '2014-01-10',
                  },
                ],
              });
            }
            return _jsonResp({'results': []});
          }
          if (path.endsWith('/tv/56055')) {
            return _jsonResp({
              'id': 56055,
              'name': 'Wake Up, Girls!',
              'original_name': 'Wake Up, Girls!',
              'first_air_date': '2014-01-10',
              'overview': '第1季简介',
              'poster_path': '/wug_series.jpg',
              'backdrop_path': '/wug_bg.jpg',
              'seasons': [
                {
                  'season_number': 1,
                  'name': '第 1 季',
                  'episode_count': 12,
                  'air_date': '2014-01-10',
                  'poster_path': '/wug_s1_tmdb.jpg',
                },
                {
                  'season_number': 2,
                  'name': 'Wake Up, Girls! 新章',
                  'episode_count': 13,
                  'air_date': '2017-10-09',
                  'poster_path': '/wug_s2_tmdb.jpg',
                },
              ],
            });
          }
          if (path.endsWith('/tv/56055/season/1')) {
            return _jsonResp({
              'season_number': 1,
              'name': '第 1 季',
              'air_date': '2014-01-10',
              'poster_path': '/wug_s1_tmdb.jpg',
              'episodes': [
                for (var i = 1; i <= 12; i++)
                  {'episode_number': i, 'name': 'S1 第$i话'},
              ],
            });
          }
          if (path.endsWith('/tv/56055/season/2')) {
            return _jsonResp({
              'season_number': 2,
              'name': 'Wake Up, Girls! 新章',
              'air_date': '2017-10-09',
              'poster_path': '/wug_s2_tmdb.jpg',
              'episodes': [
                for (var i = 1; i <= 13; i++)
                  {'episode_number': i, 'name': '新章 第$i话'},
              ],
            });
          }
          if (path.endsWith('/movie/250101')) {
            return _jsonResp({
              'id': 250101,
              'title': 'Wake Up, Girls! 七位偶像',
              'original_title': 'Wake Up, Girls! 七人のアイドル',
              'release_date': '2014-01-10',
              'overview': '剧场版 TMDB 简介',
              'poster_path': '/wug_m1_tmdb.jpg',
              'backdrop_path': '/wug_m1_bg.jpg',
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

        // 绝不请求 Bangumi 角色/声优接口
        expect(
          requestedPaths.any(
            (p) => p.contains('/characters') || p.contains('/persons'),
          ),
          isFalse,
        );

        final works = await repo.getAllWorks();
        expect(works, hasLength(3));

        final s1 = works.firstWhere((w) => w.matchedSeason == 1);
        final s2 = works.firstWhere((w) => w.matchedSeason == 2);
        final movie = works.firstWhere(
          (w) => w.tmdbMediaType == TmdbMediaType.movie,
        );

        // S1 与 新章 必须严格区分为 2014 vs 2017、不同标题、不同季海报，且均保留 bangumiPosterPath
        expect(s1.title, 'Wake Up, Girls!');
        expect(s1.year, 2014);
        expect(s1.posterPath, '/wug_s1_tmdb.jpg');
        expect(s1.bangumiPosterPath, 'https://lain.bgm.tv/pic/cover/l/wug_s1.jpg');
        expect(s1.bangumiId, 81446);

        expect(s2.title, 'Wake Up, Girls! 新章');
        expect(s2.year, 2017);
        expect(s2.posterPath, '/wug_s2_tmdb.jpg');
        expect(s2.bangumiPosterPath, 'https://lain.bgm.tv/pic/cover/l/wug_s2.jpg');
        expect(s2.bangumiId, 199392);

        final s2Episodes = await repo.getEpisodesByWork(s2.id);
        expect(s2Episodes, hasLength(13));
        expect(s2Episodes.first.seasonNumber, 2);
        expect(s2Episodes.first.title, '新章 第1话');

        // 剧场版由 Bangumi 交叉救援成功自动绑定
        expect(movie.scrapeStatus, ScrapeStatus.matched);
        expect(movie.tmdbId, 250101);
        expect(movie.bangumiId, 88424);
        expect(
          movie.bangumiPosterPath,
          'https://lain.bgm.tv/pic/cover/l/wug_m1.jpg',
        );
      },
    );

    test(
      '2. 加速世界 TV+Movie 合集拆分 + Accel World EX 识别 + 特典短标题与零误并多版本',
      () async {
        // 混合目录：TV 01..03 + EX 01 + 剧场版 + 多个无集号特典 CM1/Menu/Preview/PV1
        await touchFile(
          '加速世界 TV+Movie/[VCB-Studio] Accel World [01][Ma10p_1080p].mkv',
        );
        await touchFile(
          '加速世界 TV+Movie/[VCB-Studio] Accel World [02][Ma10p_1080p].mkv',
        );
        await touchFile(
          '加速世界 TV+Movie/[VCB-Studio] Accel World [03][Ma10p_1080p].mkv',
        );
        await touchFile(
          '加速世界 TV+Movie/[VCB-Studio] Accel World [EX1][Ma10p_1080p].mkv',
        );
        await touchFile(
          '加速世界 TV+Movie/[VCB-Studio] Accel World Infinite Burst [Ma10p_1080p].mkv',
        );
        await touchFile(
          '加速世界 TV+Movie/SPs/[VCB-Studio] Accel World Infinite Burst [CM1].mkv',
        );
        await touchFile(
          '加速世界 TV+Movie/SPs/[VCB-Studio] Accel World Infinite Burst [Menu].mkv',
        );
        await touchFile(
          '加速世界 TV+Movie/SPs/[VCB-Studio] Accel World Infinite Burst [Preview].mkv',
        );
        await touchFile(
          '加速世界 TV+Movie/SPs/[VCB-Studio] Accel World Infinite Burst [PV1].mkv',
        );

        final source = MediaSource(
          id: 'src-aw',
          kind: MediaSourceKind.local,
          label: 'AW测试盘',
          location: tempRoot.path,
        );
        await repo.upsertMediaSource(source);

        final mockClient = MockClient((request) async {
          if (request.url.host == 'api.bgm.tv') {
            if (request.url.path == '/v0/search/subjects') {
              final body = jsonDecode(request.body) as Map<String, dynamic>;
              final kw = (body['keyword'] ?? '').toString().toLowerCase();
              if (kw.contains('infinite') || kw.contains('burst')) {
                return _jsonResp({
                  'data': [
                    {
                      'id': 148097,
                      'name': 'アクセル・ワールド INFINITE∞BURST',
                      'name_cn': '加速世界 INFINITE BURST',
                      'date': '2016-07-23',
                      'eps': 1,
                      'platform': '剧场版',
                      'images': {
                        'large': 'https://lain.bgm.tv/pic/cover/l/aw_m.jpg',
                      },
                    },
                  ],
                });
              }
              if (kw.contains('ex')) {
                return _jsonResp({
                  'data': [
                    {
                      'id': 39604,
                      'name': 'アクセル・ワールド OVA',
                      'name_cn': '加速世界 OVA',
                      'date': '2012-09-13',
                      'eps': 2,
                      'platform': 'OVA',
                      'images': {
                        'large': 'https://lain.bgm.tv/pic/cover/l/aw_ex.jpg',
                      },
                    },
                  ],
                });
              }
              return _jsonResp({
                'data': [
                  {
                    'id': 23119,
                    'name': 'アクセル・ワールド',
                    'name_cn': '加速世界',
                    'date': '2012-04-06',
                    'eps': 24,
                    'images': {
                      'large': 'https://lain.bgm.tv/pic/cover/l/aw_tv.jpg',
                    },
                  },
                ],
              });
            }
            if (request.url.path == '/v0/subjects/23119') {
              return _jsonResp({
                'id': 23119,
                'name': 'アクセル・ワールド',
                'name_cn': '加速世界',
                'date': '2012-04-06',
                'total_episodes': 24,
                'images': {
                  'large': 'https://lain.bgm.tv/pic/cover/l/aw_tv.jpg',
                },
                'infobox': [
                  {'key': '别名', 'value': 'Accel World'},
                ],
              });
            }
            if (request.url.path == '/v0/subjects/39604') {
              return _jsonResp({
                'id': 39604,
                'name': 'アクセル・ワールド OVA',
                'name_cn': '加速世界 OVA',
                'date': '2012-09-13',
                'total_episodes': 2,
                'platform': 'OVA',
                'images': {
                  'large': 'https://lain.bgm.tv/pic/cover/l/aw_ex.jpg',
                },
                'infobox': [
                  {'key': '别名', 'value': 'Accel World EX'},
                ],
              });
            }
            if (request.url.path == '/v0/subjects/148097') {
              return _jsonResp({
                'id': 148097,
                'name': 'アクセル・ワールド INFINITE∞BURST',
                'name_cn': '加速世界 INFINITE BURST',
                'date': '2016-07-23',
                'total_episodes': 1,
                'platform': '剧场版',
                'images': {
                  'large': 'https://lain.bgm.tv/pic/cover/l/aw_m.jpg',
                },
                'infobox': [
                  {'key': '别名', 'value': 'Accel World Infinite Burst'},
                ],
              });
            }
            if (request.url.path == '/v0/episodes') {
              return _jsonResp({'data': []});
            }
            return http.Response('not found', 404);
          }

          final path = request.url.path;
          final query = (request.url.queryParameters['query'] ?? '')
              .toLowerCase();
          if (path.endsWith('/search/tv')) {
            if (query.contains('accel world') || query.contains('加速世界')) {
              return _jsonResp({
                'results': [
                  {
                    'id': 42731,
                    'name': '加速世界',
                    'original_name': 'アクセル・ワールド',
                    'first_air_date': '2012-04-06',
                  },
                ],
              });
            }
            return _jsonResp({'results': []});
          }
          if (path.endsWith('/search/movie')) {
            if (query.contains('infinite') || query.contains('burst')) {
              return _jsonResp({
                'results': [
                  {
                    'id': 378102,
                    'title': '加速世界 INFINITE∞BURST',
                    'original_title': 'アクセル・ワールド INFINITE∞BURST',
                    'release_date': '2016-07-23',
                  },
                ],
              });
            }
            return _jsonResp({'results': []});
          }
          if (path.endsWith('/tv/42731')) {
            return _jsonResp({
              'id': 42731,
              'name': '加速世界',
              'original_name': 'アクセル・ワールド',
              'first_air_date': '2012-04-06',
              'poster_path': '/aw_tv_tmdb.jpg',
              'alternative_titles': {
                'results': [
                  {'title': 'Accel World'},
                ],
              },
              'seasons': [
                {
                  'season_number': 0,
                  'name': '特别篇',
                  'episode_count': 2,
                  'air_date': '2012-09-13',
                },
                {
                  'season_number': 1,
                  'name': '第 1 季',
                  'episode_count': 24,
                  'air_date': '2012-04-06',
                },
              ],
            });
          }
          if (path.endsWith('/movie/378102')) {
            return _jsonResp({
              'id': 378102,
              'title': '加速世界 INFINITE∞BURST',
              'original_title': 'アクセル・ワールド INFINITE∞BURST',
              'release_date': '2016-07-23',
              'poster_path': '/aw_m_tmdb.jpg',
              'alternative_titles': {
                'results': [
                  {'title': 'Accel World Infinite Burst'},
                ],
              },
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

        final works = await repo.getAllWorks();
        // TV、EX、Infinite Burst 应当拆成 3 部作品
        expect(works.length, 3);
        expect(
          works.every((w) => w.scrapeStatus == ScrapeStatus.matched),
          isTrue,
          reason: works
              .map(
                (w) =>
                    '${w.title}(status=${w.scrapeStatus.name},tmdb=${w.tmdbId},bgm=${w.bangumiId},reason=${w.reviewReason})',
              )
              .join(' | '),
        );

        // 验证特典未误合并为 3 版本，且分别提取短标题
        final allEpisodes = <Episode>[];
        for (final w in works) {
          allEpisodes.addAll(await repo.getEpisodesByWork(w.id));
        }
        final extraEps = allEpisodes
            .where((e) => e.category == EpisodeCategory.extra)
            .toList();
        expect(extraEps, hasLength(4));

        final titles = extraEps.map((e) => e.title).toSet();
        expect(titles, containsAll(['CM1', 'MENU', 'Preview']));

        // 每个特典只有 1 个物理文件，绝不报假 2版本 / 3版本
        for (final ep in extraEps) {
          final variants = await repo.getVariantsByWork(ep.workId);
          final countForEp = variants.where((v) => v.episodeId == ep.id).length;
          expect(countForEp, 1);
        }
      },
    );

    testWidgets(
      '3. 详情页编辑封面弹窗同时呈现 Bangumi 与 TMDB 封面并支持一键切换持久化',
      (tester) async {
        const work = Work(
          id: 'w-cover-switch',
          tmdbId: 56055,
          tmdbMediaType: TmdbMediaType.tv,
          bangumiId: 199392,
          matchedSeason: 2,
          title: 'Wake Up, Girls! 新章',
          posterPath: '/wug_s2_tmdb.jpg',
          bangumiPosterPath: 'https://lain.bgm.tv/pic/cover/l/wug_s2.jpg',
          scrapeStatus: ScrapeStatus.matched,
        );
        await repo.upsertWork(work);

        final mockClient = MockClient((request) async {
          final path = request.url.path;
          if (path.endsWith('/tv/56055')) {
            return _jsonResp({
              'id': 56055,
              'name': 'Wake Up, Girls!',
              'poster_path': '/wug_series.jpg',
              'seasons': [
                {
                  'season_number': 2,
                  'name': 'Wake Up, Girls! 新章',
                  'episode_count': 13,
                  'poster_path': '/wug_s2_tmdb.jpg',
                },
              ],
              'images': {
                'posters': [
                  {'file_path': '/wug_alt_tmdb.jpg', 'iso_639_1': 'ja'},
                ],
                'backdrops': [],
              },
            });
          }
          // 所有图片请求返回 1x1 PNG
          return http.Response.bytes(_kTinyPngBytes, 200);
        });

        final httpClient = TmdbHttpClient(
          config: const TmdbNetworkConfig(credential: 'dummy_v3_key'),
          scheduler: PriorityHttpScheduler(),
          httpClient: mockClient,
        );
        final tmdbService = TmdbService(httpClient: httpClient);

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              libraryRepositoryProvider.overrideWithValue(repo),
              tmdbImageLoaderProvider.overrideWithValue((
                String pathOrUrl, {
                int? targetWidth,
                TmdbImageSize? imageSize,
              }) {
                return tmdbService.fetchImageBytes(
                  pathOrUrl,
                  size: imageSize,
                  targetWidth: targetWidth,
                );
              }),
              workManagementProvider.overrideWith((ref) {
                return _TestableWorkManagementActions(
                  ref,
                  repo: repo,
                  tmdbService: tmdbService,
                );
              }),
            ],
            child: MaterialApp(
              theme: KonataTheme.darkTheme(),
              home: const Scaffold(
                body: WorkArtworkPickerDialog(
                  work: work,
                  kind: WorkArtworkKind.poster,
                ),
              ),
            ),
          ),
        );

        await tester.pumpAndSettle();

        expect(find.textContaining('Bangumi / TMDB 官方候选封面'), findsOneWidget);
        expect(find.text('Bangumi'), findsOneWidget);
        expect(find.text('TMDB·S2'), findsOneWidget);

        // 点击 Bangumi 封面卡片并点击「应用选中图片」
        await tester.tap(find.text('Bangumi'));
        await tester.pump();
        await tester.tap(find.text('应用选中图片'));
        await tester.pumpAndSettle();

        final updated = await repo.findWorkById(work.id);
        expect(updated, isNotNull);
        expect(
          updated!.posterPath,
          'https://lain.bgm.tv/pic/cover/l/wug_s2.jpg',
        );
        expect(updated.isManualLocked, isTrue);
      },
    );

    test(
      '4. Menu (Vol.1)/Menu (Vol.2)/Web Preview/Commentary 与同特典多压制真版本精确分集不误合并',
      () async {
        await repo.upsertMediaSource(
          const MediaSource(
            id: 'src-local',
            kind: MediaSourceKind.local,
            label: '本地测试盘',
            location: 'D:/Anime',
          ),
        );
        const work = Work(
          id: 'w-extra-dedupe',
          tmdbId: 88801,
          tmdbMediaType: TmdbMediaType.movie,
          title: 'Accel World: Infinite Burst',
          scrapeStatus: ScrapeStatus.matched,
        );
        await repo.upsertWork(work);

        const folder = GroupedWorkFolder(
          folderRelativePath: 'Accel World Infinite Burst',
          folderName: 'Accel World Infinite Burst',
          cleanTitle: 'Accel World Infinite Burst',
          isMovieHint: true,
          variants: [
            MediaVariant(
              id: 'v-main',
              workId: 'w-extra-dedupe',
              sourceId: 'src-local',
              relativePath:
                  'Accel World Infinite Burst/[VCB-Studio] Accel World Infinite Burst [Ma10p_1080p].mkv',
              fileName: '[VCB-Studio] Accel World Infinite Burst [Ma10p_1080p].mkv',
              fileSize: 1024 * 1024,
              assetKind: AssetKind.video,
            ),
            MediaVariant(
              id: 'v-menu-v1',
              workId: 'w-extra-dedupe',
              sourceId: 'src-local',
              relativePath:
                  'Accel World Infinite Burst/SPs/[VCB-Studio] Accel World Infinite Burst Menu (Vol.1) [Ma10p_1080p].mkv',
              fileName:
                  '[VCB-Studio] Accel World Infinite Burst Menu (Vol.1) [Ma10p_1080p].mkv',
              fileSize: 1024 * 1024,
              assetKind: AssetKind.video,
            ),
            MediaVariant(
              id: 'v-menu-v2',
              workId: 'w-extra-dedupe',
              sourceId: 'src-local',
              relativePath:
                  'Accel World Infinite Burst/SPs/[VCB-Studio] Accel World Infinite Burst Menu (Vol.2) [Ma10p_1080p].mkv',
              fileName:
                  '[VCB-Studio] Accel World Infinite Burst Menu (Vol.2) [Ma10p_1080p].mkv',
              fileSize: 1024 * 1024,
              assetKind: AssetKind.video,
            ),
            MediaVariant(
              id: 'v-web-prev',
              workId: 'w-extra-dedupe',
              sourceId: 'src-local',
              relativePath:
                  'Accel World Infinite Burst/SPs/[VCB-Studio] Accel World Infinite Burst [Web Preview][Ma10p_1080p].mkv',
              fileName:
                  '[VCB-Studio] Accel World Infinite Burst [Web Preview][Ma10p_1080p].mkv',
              fileSize: 1024 * 1024,
              assetKind: AssetKind.video,
            ),
            MediaVariant(
              id: 'v-prev-1080',
              workId: 'w-extra-dedupe',
              sourceId: 'src-local',
              relativePath:
                  'Accel World Infinite Burst/SPs/[VCB-Studio] Accel World Infinite Burst [Preview][Ma10p_1080p].mkv',
              fileName:
                  '[VCB-Studio] Accel World Infinite Burst [Preview][Ma10p_1080p].mkv',
              fileSize: 1024 * 1024,
              assetKind: AssetKind.video,
            ),
            MediaVariant(
              id: 'v-prev-720',
              workId: 'w-extra-dedupe',
              sourceId: 'src-local',
              relativePath:
                  'Accel World Infinite Burst/SPs/[Snow-Raws] Accel World Infinite Burst [Preview][720p].mkv',
              fileName:
                  '[Snow-Raws] Accel World Infinite Burst [Preview][720p].mkv',
              fileSize: 1024 * 1024,
              assetKind: AssetKind.video,
            ),
            MediaVariant(
              id: 'v-cm1',
              workId: 'w-extra-dedupe',
              sourceId: 'src-local',
              relativePath:
                  'Accel World Infinite Burst/SPs/[VCB-Studio] Accel World Infinite Burst [CM1][Ma10p_1080p].mkv',
              fileName:
                  '[VCB-Studio] Accel World Infinite Burst [CM1][Ma10p_1080p].mkv',
              fileSize: 1024 * 1024,
              assetKind: AssetKind.video,
            ),
          ],
        );

        final persister = ScrapeWorkPersister(repo);
        await persister.syncEpisodesAndVariants(
          work: work,
          folder: folder,
          tmdbEpisodes: const [],
        );

        final episodes = await repo.getEpisodesByWork(work.id);
        final extras = episodes
            .where((e) => e.category == EpisodeCategory.extra)
            .toList();
        final variants = await repo.getVariantsByWork(work.id);

        expect(extras, hasLength(5));
        expect(
          extras.map((e) => e.title).toSet(),
          containsAll(['MENU Vol.1', 'MENU Vol.2', 'Web Preview', 'Preview', 'CM1']),
        );
        for (final ep in extras) {
          final epVariants = variants.where((v) => v.episodeId == ep.id).length;
          if (ep.title == 'Preview') {
            expect(epVariants, 2, reason: '同一 Preview 的双压制真版本应合并为 2 版本');
          } else {
            expect(epVariants, 1, reason: '${ep.title} 为独立特典，不得误并版本数');
          }
        }
      },
    );
  });
}



class _TestableWorkManagementActions extends WorkManagementActions {
  _TestableWorkManagementActions(
    super.ref, {
    required this.repo,
    required this.tmdbService,
  });

  final DriftLibraryRepository repo;
  final TmdbService tmdbService;

  @override
  Future<WorkArtworkOptions> fetchWorkArtworkOptions(
    Work work, {
    bool includeLogos = false,
  }) async {
    final posters = <WorkArtworkOption>[
      if (work.bangumiPosterPath != null && work.bangumiPosterPath!.isNotEmpty)
        WorkArtworkOption(
          filePath: work.bangumiPosterPath!,
          sourceLabel: 'Bangumi',
          isBangumi: true,
        ),
    ];
    final detail = await tmdbService.getWorkDetail(
      work.tmdbId!,
      work.tmdbMediaType!,
      includeEnglishImages: true,
    );
    if (detail != null) {
      final s2 = detail.seasons
          .where((s) => s.seasonNumber == work.matchedSeason)
          .firstOrNull;
      if (s2?.posterPath != null) {
        posters.add(
          WorkArtworkOption(
            filePath: s2!.posterPath!,
            sourceLabel: 'TMDB 第${work.matchedSeason}季',
            isSeasonPoster: true,
          ),
        );
      }
      if (detail.posterPath != null) {
        posters.add(WorkArtworkOption(filePath: detail.posterPath!, sourceLabel: 'TMDB'));
      }
      for (final item in detail.candidatePosters) {
        if (!posters.any((p) => p.filePath == item.filePath)) {
          posters.add(WorkArtworkOption(filePath: item.filePath, sourceLabel: 'TMDB'));
        }
      }
    }
    return WorkArtworkOptions(posters: posters);
  }
}
