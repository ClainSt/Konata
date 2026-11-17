import 'dart:convert';
import 'dart:io';

import 'package:ccplayer/application/scraping/scrape_compute_worker.dart';
import 'package:ccplayer/application/scraping/scrape_orchestrator.dart';
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
  group('Phase 4 刮削管线回退、Season 0 特典与局部 scanRoots 安全防误删测试', () {
    late Directory tempRoot;
    late KonataDatabase db;
    late DriftLibraryRepository repo;

    setUp(() async {
      tempRoot = await Directory.systemTemp.createTemp('konata_p4_e2e_');
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

    Future<void> removeFile(String relPath) async {
      final file = File(p.joinAll([tempRoot.path, ...relPath.split('/')]));
      if (await file.exists()) {
        await file.delete();
      }
    }

    test(
      '失效 {tmdb-999999} 404 回退清零且无 -60 惩罚 + 首选 tv 404 自动切换 movie + Season 0 拉取',
      () async {
        // 1. 失效显式 TMDB ID 目录 + Season 0 特典文件
        await touchFile('Ghost Show {tmdb-999999}/Ghost Show S01E01.mkv');
        await touchFile(
          'Ghost Show {tmdb-999999}/Specials/Ghost Show [OVA01].mkv',
        );
        // 2. 无后缀显式 ID 但实际是 Movie（验证 tv 404 后自动尝试 movie）
        await touchFile('Movie Hint {tmdb-888111}/Movie Hint (2024).mkv');

        final source = MediaSource(
          id: 'src_fallback',
          kind: MediaSourceKind.local,
          label: '测试回退盘',
          location: tempRoot.path,
        );
        await repo.upsertMediaSource(source);

        var seasonZeroRequested = false;
        var creditsRequested = false;

        final mockClient = MockClient((req) async {
          final path = req.url.path;
          final query = (req.url.queryParameters['query'] ?? '').toLowerCase();
          if ((req.url.queryParameters['append_to_response'] ?? '').contains(
            'credits',
          )) {
            creditsRequested = true;
          }

          // 失效 ID 999999：TV 与 Movie 均 404
          if (path.endsWith('/tv/999999') || path.endsWith('/movie/999999')) {
            return http.Response('{}', 404);
          }
          // 888111：TV 404，Movie 200 命中
          if (path.endsWith('/tv/888111')) {
            return http.Response('{}', 404);
          }
          if (path.endsWith('/movie/888111')) {
            return _jsonRes({
              'id': 888111,
              'title': '剧场版 Movie Hint',
              'original_title': 'Movie Hint',
              'release_date': '2024-06-15',
            });
          }

          // 回落阶段 3 搜索 Ghost Show
          if (path.endsWith('/search/tv') && query.contains('ghost')) {
            return _jsonRes({
              'results': [
                {
                  'id': 555123,
                  'name': 'Ghost Show',
                  'original_name': 'Ghost Show',
                  'first_air_date': '2024-01-10',
                },
              ],
            });
          }
          if (path.endsWith('/search/movie')) {
            return _jsonRes({'results': []});
          }
          if (path.endsWith('/tv/555123')) {
            return _jsonRes({
              'id': 555123,
              'name': 'Ghost Show',
              'original_name': 'Ghost Show',
              'first_air_date': '2024-01-10',
              'seasons': [
                {'season_number': 0, 'name': '特别篇', 'episode_count': 1},
                {
                  'season_number': 1,
                  'name': '第 1 季',
                  'episode_count': 1,
                  'air_date': '2024-01-10',
                },
              ],
            });
          }
          if (path.endsWith('/tv/555123/season/1')) {
            return _jsonRes({
              'episodes': [
                {'episode_number': 1, 'name': '幽灵序章'},
              ],
            });
          }
          if (path.endsWith('/tv/555123/season/0')) {
            seasonZeroRequested = true;
            return _jsonRes({
              'episodes': [
                {'episode_number': 1, 'name': '前传特别篇 OVA'},
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

        final summary = await orchestrator.scanAndScrapeSource(source);
        expect(summary.totalWorks, 2);
        expect(summary.matchedWorks, 2);
        expect(creditsRequested, isFalse, reason: '已优化移除未使用的 credits 请求');
        expect(seasonZeroRequested, isTrue, reason: '存在 Season 0 时应拉取特典元数据');

        final works = await repo.getAllWorks();
        final ghost = works.firstWhere((w) => w.tmdbId == 555123);
        expect(ghost.scrapeStatus, ScrapeStatus.matched);
        expect(ghost.reviewReason, isNull);

        final ghostEps = await repo.getEpisodesByWork(ghost.id);
        final ova = ghostEps.firstWhere(
          (e) => e.category == EpisodeCategory.extra,
        );
        expect(ova.extraType, ExtraKind.ova);
        expect(ova.title, '前传特别篇 OVA');

        final movie = works.firstWhere((w) => w.tmdbId == 888111);
        expect(movie.tmdbMediaType, TmdbMediaType.movie);
        expect(movie.scrapeStatus, ScrapeStatus.matched);
      },
    );

    test('局部 scanRoots 仅扫描选中子树：严禁误删未勾选目录下的既有已入库作品', () async {
      await touchFile('2024-Autumn/Frieren/Frieren S01E01.mkv');
      await touchFile('2025-Winter/Ave Mujica/Ave Mujica S01E01.mkv');

      final fullSource = MediaSource(
        id: 'src_scoped',
        kind: MediaSourceKind.local,
        label: '局部作用域盘',
        location: tempRoot.path,
      );
      await repo.upsertMediaSource(fullSource);

      final mockClient = MockClient((req) async {
        final path = req.url.path;
        final query = (req.url.queryParameters['query'] ?? '').toLowerCase();
        if (path.endsWith('/search/tv')) {
          if (query.contains('frieren')) {
            return _jsonRes({
              'results': [
                {
                  'id': 209867,
                  'name': '葬送的芙莉莲',
                  'first_air_date': '2023-09-29',
                },
              ],
            });
          }
          if (query.contains('ave mujica')) {
            return _jsonRes({
              'results': [
                {
                  'id': 260001,
                  'name': 'Ave Mujica',
                  'first_air_date': '2025-01-02',
                },
              ],
            });
          }
        }
        if (path.endsWith('/tv/209867')) {
          return _jsonRes({
            'id': 209867,
            'name': '葬送的芙莉莲',
            'original_name': '葬送のフリーレン',
            'first_air_date': '2023-09-29',
            'alternative_titles': {
              'results': [
                {'title': 'Frieren'},
              ],
            },
            'seasons': [
              {
                'season_number': 1,
                'name': 'S1',
                'episode_count': 1,
                'air_date': '2023-09-29',
              },
            ],
          });
        }
        if (path.endsWith('/tv/260001')) {
          return _jsonRes({
            'id': 260001,
            'name': 'Ave Mujica',
            'first_air_date': '2025-01-02',
            'seasons': [
              {
                'season_number': 1,
                'name': 'S1',
                'episode_count': 1,
                'air_date': '2025-01-02',
              },
            ],
          });
        }
        if (path.endsWith('/season/1')) {
          return _jsonRes({
            'episodes': [
              {'episode_number': 1, 'name': '第 1 话'},
              {'episode_number': 2, 'name': '第 2 话'},
            ],
          });
        }
        return _jsonRes({'results': []});
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

      // 首次全库扫描，两部作品均入库
      await orchestrator.scanAndScrapeSource(fullSource);
      var works = await repo.getAllWorks();
      expect(works.length, 2);

      // 删除 2025-Winter 下旧第 1 集，新增洗版新文件；仅勾选 ['2025-Winter'] 重扫
      await removeFile('2025-Winter/Ave Mujica/Ave Mujica S01E01.mkv');
      await touchFile(
        '2025-Winter/Ave Mujica/[VCB-Studio] Ave Mujica S01E01 [1080p].mkv',
      );

      await orchestrator.scanAndScrapeSource(
        fullSource,
        scanRootsOverride: const ['2025-Winter'],
      );

      works = await repo.getAllWorks();
      expect(
        works.any((w) => w.tmdbId == 209867),
        isTrue,
        reason: '未勾选目录 2024-Autumn/Frieren 严禁被局部扫描误删',
      );
      final frieren = works.firstWhere((w) => w.tmdbId == 209867);
      final frierenVariants = await repo.getVariantsByWork(frieren.id);
      expect(frierenVariants.length, 1);

      final ave = works.firstWhere((w) => w.tmdbId == 260001);
      final aveVariants = await repo.getVariantsByWork(ave.id);
      expect(aveVariants.length, 1);
      expect(
        aveVariants.first.fileName,
        '[VCB-Studio] Ave Mujica S01E01 [1080p].mkv',
      );
    });

    test('跨季绝对集号自动对齐 TMDB 季内集数 + 中文无结果回退英文检索', () async {
      await touchFile(
        'Re：从零开始的异世界生活 第三季 (2024) {tmdb-65942}/[VCB-Studio] Re Zero 3rd Season [51][1080p].mkv',
      );
      await touchFile(
        'Re：从零开始的异世界生活 第三季 (2024) {tmdb-65942}/[VCB-Studio] Re Zero 3rd Season [52][1080p].mkv',
      );
      await touchFile(
        'Unknown Nichijou Work (2024)/Unknown Nichijou Work S01E01.mkv',
      );

      final source = MediaSource(
        id: 'src_remap_lang',
        kind: MediaSourceKind.local,
        label: '测试重映射与多语言盘',
        location: tempRoot.path,
      );
      await repo.upsertMediaSource(source);

      var enSearchRequested = false;

      final mockClient = MockClient((req) async {
        final path = req.url.path;
        final lang = req.url.queryParameters['language'] ?? '';
        final query = (req.url.queryParameters['query'] ?? '').toLowerCase();

        if (path.endsWith('/tv/65942')) {
          return _jsonRes({
            'id': 65942,
            'name': 'Re:从零开始的异世界生活',
            'first_air_date': '2016-04-04',
            'seasons': [
              {'season_number': 1, 'name': 'S1', 'episode_count': 25},
              {'season_number': 2, 'name': 'S2', 'episode_count': 25},
              {
                'season_number': 3,
                'name': 'S3',
                'episode_count': 16,
                'air_date': '2024-10-02',
              },
            ],
          });
        }
        if (path.endsWith('/tv/65942/season/3')) {
          return _jsonRes({
            'episodes': [
              {'episode_number': 1, 'name': '剧场型恶意', 'still_path': '/s3e1.jpg'},
              {
                'episode_number': 2,
                'name': '冰与炎的结局',
                'still_path': '/s3e2.jpg',
              },
            ],
          });
        }

        if (path.endsWith('/search/tv') && query.contains('unknown nichijou')) {
          if (lang == 'zh-CN') return _jsonRes({'results': []});
          if (lang == 'en-US') {
            enSearchRequested = true;
            return _jsonRes({
              'results': [
                {
                  'id': 770011,
                  'name': 'Unknown Nichijou Work',
                  'first_air_date': '2024-04-01',
                },
              ],
            });
          }
        }
        if (path.endsWith('/tv/770011')) {
          return _jsonRes({
            'id': 770011,
            'name': 'Unknown Nichijou Work',
            'original_name': 'Unknown Nichijou Work',
            'first_air_date': '2024-04-01',
            'seasons': [
              {'season_number': 1, 'name': 'S1', 'episode_count': 1},
            ],
          });
        }
        if (path.endsWith('/tv/770011/season/1')) {
          return _jsonRes({
            'episodes': [
              {'episode_number': 1, 'name': '第 1 话'},
            ],
          });
        }
        return _jsonRes({'results': []});
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

      await orchestrator.scanAndScrapeSource(source);

      expect(enSearchRequested, isTrue);

      final works = await repo.getAllWorks();
      final reZero = works.firstWhere((w) => w.tmdbId == 65942);
      final reZeroEps = await repo.getEpisodesByWork(reZero.id);
      expect(reZeroEps.length, 2);
      expect(reZeroEps.map((e) => e.episodeNumber), containsAll([1, 2]));
      expect(reZeroEps.firstWhere((e) => e.episodeNumber == 1).title, '剧场型恶意');
      expect(
        reZeroEps.firstWhere((e) => e.episodeNumber == 2).stillPath,
        '/s3e2.jpg',
      );

      final fallbackWork = works.firstWhere((w) => w.tmdbId == 770011);
      expect(fallbackWork.scrapeStatus, ScrapeStatus.matched);
    });

    test('源目录改名移走后仅局部扫描新目录时，自动清理已失联的旧幽灵作品且保留其他有效未选目录', () async {
      await touchFile('KeepDir/Frieren {tmdb-209867}/Frieren S01E01.mkv');
      await touchFile('OldDir/Ave Mujica {tmdb-260001}/Ave Mujica S01E01.mkv');

      final src = MediaSource(
        id: 'src_rename_cleanup',
        kind: MediaSourceKind.local,
        label: '测试改名清理盘',
        location: tempRoot.path,
      );
      await repo.upsertMediaSource(src);

      final mockClient = MockClient((req) async {
        final path = req.url.path;
        final query = (req.url.queryParameters['query'] ?? '').toLowerCase();
        if (path.endsWith('/search/tv')) {
          if (query.contains('frieren')) {
            return _jsonRes({
              'results': [
                {
                  'id': 209867,
                  'name': '葬送的芙莉莲',
                  'first_air_date': '2023-09-29',
                },
              ],
            });
          }
          if (query.contains('ave mujica')) {
            return _jsonRes({
              'results': [
                {
                  'id': 260001,
                  'name': 'Ave Mujica',
                  'first_air_date': '2025-01-02',
                },
              ],
            });
          }
        }
        if (path.endsWith('/tv/209867')) {
          return _jsonRes({
            'id': 209867,
            'name': '葬送的芙莉莲',
            'first_air_date': '2023-09-29',
            'seasons': [
              {'season_number': 1, 'name': 'S1', 'episode_count': 1},
            ],
          });
        }
        if (path.endsWith('/tv/260001')) {
          return _jsonRes({
            'id': 260001,
            'name': 'Ave Mujica',
            'first_air_date': '2025-01-02',
            'seasons': [
              {'season_number': 1, 'name': 'S1', 'episode_count': 1},
            ],
          });
        }
        if (path.endsWith('/season/1')) {
          return _jsonRes({
            'episodes': [
              {'episode_number': 1, 'name': '第 1 话'},
            ],
          });
        }
        return _jsonRes({'results': []});
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

      await orchestrator.scanAndScrapeSource(src);
      expect((await repo.getAllWorks()).length, 2);

      // 模拟用户将 OldDir 重命名为 NewDir，并仅勾选 ['NewDir'] 触发局部扫描
      await Directory(
        '${tempRoot.path}${Platform.pathSeparator}OldDir',
      ).delete(recursive: true);
      await touchFile('NewDir/Ave Mujica {tmdb-260001}/Ave Mujica S01E01.mkv');

      await orchestrator.scanAndScrapeSource(
        src,
        scanRootsOverride: const ['NewDir'],
      );

      final worksAfter = await repo.getAllWorks();
      expect(
        worksAfter.where((w) => w.tmdbId == 260001).length,
        1,
        reason: '已改名消失的 OldDir 幽灵作品必须被自动清理，不产生双份重复海报',
      );
      expect(
        worksAfter.any((w) => w.tmdbId == 209867),
        isTrue,
        reason: '仍然真实存在的未勾选目录 KeepDir/Frieren 必须安全保留',
      );
    });
  });
}
