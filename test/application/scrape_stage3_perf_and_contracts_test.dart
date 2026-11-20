import 'dart:convert';
import 'dart:io';

import 'package:ccplayer/application/scraping/scrape_compute_worker.dart';
import 'package:ccplayer/application/scraping/scrape_orchestrator.dart';
import 'package:ccplayer/application/scraping/series_auto_linker.dart';
import 'package:ccplayer/domain/matching/directory_grouper.dart';
import 'package:ccplayer/domain/models/media_source.dart';
import 'package:ccplayer/domain/models/media_variant.dart';
import 'package:ccplayer/domain/models/network_config.dart';
import 'package:ccplayer/domain/models/work.dart';
import 'package:ccplayer/domain/scraping/bangumi_tmdb_index.dart';
import 'package:ccplayer/infrastructure/database/drift_library_repository.dart';
import 'package:ccplayer/infrastructure/database/konata_database.dart';
import 'package:ccplayer/infrastructure/network/bangumi_service.dart';
import 'package:ccplayer/infrastructure/network/priority_http_scheduler.dart';
import 'package:ccplayer/infrastructure/network/tmdb_http_client.dart';
import 'package:ccplayer/infrastructure/network/tmdb_service.dart';
import 'package:ccplayer/infrastructure/sources/local_source_gateway.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

http.Response _json(Object body, [int status = 200]) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  status,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);

void main() {
  group('阶段三刮削提速、安全回退与契约回归测试', () {
    late Directory tempRoot;
    late KonataDatabase db;
    late DriftLibraryRepository repo;

    setUp(() async {
      tempRoot = await Directory.systemTemp.createTemp('konata_s3_perf_');
      db = KonataDatabase(NativeDatabase.memory());
      repo = DriftLibraryRepository(db);
    });

    tearDown(() async {
      await db.close();
      if (await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
    });

    Future<File> touchFile(String relPath, {int bytes = 1024}) async {
      final f = File(p.join(tempRoot.path, relPath));
      await f.parent.create(recursive: true);
      await f.writeAsBytes(List<int>.filled(bytes, 1), flush: true);
      return f;
    }

    test('1. 离线映射直连快通道：命中映射时零 TMDB 搜索，且错链自动安全回退全量搜索', () async {
      await touchFile('Frieren (2023)/[VCB-Studio] Frieren [01][1080p].mkv');
      await touchFile('Frieren (2023)/[VCB-Studio] Frieren [02][1080p].mkv');
      await touchFile('Bocchi (2022)/[VCB-Studio] Bocchi [01][1080p].mkv');
      await touchFile('Bocchi (2022)/[VCB-Studio] Bocchi [02][1080p].mkv');

      final source = MediaSource(
        id: 'src_fastpath',
        kind: MediaSourceKind.local,
        label: '快通道测试盘',
        location: tempRoot.path,
      );
      await repo.upsertMediaSource(source);

      // 构造二进制索引：bgm 400602 -> 正确 tv:209867(S1)；bgm 328609 -> 故意写错到无关作品 tv:999999
      final binBytes = BangumiTmdbIndex.encode(
        const [
          BangumiTmdbRecord(
            bangumiId: 400602,
            type: TmdbMediaType.tv,
            tmdbId: 209867,
            season: 1,
            flags: BangumiTmdbTarget.flagOpenAni,
          ),
          BangumiTmdbRecord(
            bangumiId: 328609,
            type: TmdbMediaType.tv,
            tmdbId: 999999,
            season: 1,
            flags: BangumiTmdbTarget.flagOpenAni,
          ),
        ],
        snapshotDateYyyymmdd: 20261121,
      );
      final mappingIndex = BangumiTmdbIndex.fromBytes(binBytes);

      final tmdbSearchQueries = <String>[];
      final detailImageFlags = <String, List<bool>>{};
      final mockClient = MockClient((req) async {
        final path = req.url.path;
        if (path.endsWith('/search/subjects')) {
          final body = jsonDecode(req.body) as Map<String, dynamic>;
          final kw = (body['keyword'] ?? '').toString().toLowerCase();
          if (kw.contains('frieren')) {
            return _json({
              'data': [
                {
                  'id': 400602,
                  'name': '葬送のフリーレン',
                  'name_cn': '葬送的芙莉莲',
                  'date': '2023-09-29',
                  'platform': 'TV',
                  'total_episodes': 2,
                  'infobox': [
                    {
                      'key': '别名',
                      'value': [
                        {'v': 'Frieren'},
                      ],
                    },
                  ],
                },
              ],
            });
          }
          if (kw.contains('bocchi')) {
            return _json({
              'data': [
                {
                  'id': 328609,
                  'name': 'ぼっち・ざ・ろっく！',
                  'name_cn': '孤独摇滚！',
                  'date': '2022-10-09',
                  'platform': 'TV',
                  'total_episodes': 2,
                  'infobox': [
                    {
                      'key': '别名',
                      'value': [
                        {'v': 'Bocchi'},
                      ],
                    },
                  ],
                },
              ],
            });
          }
          return _json({'data': []});
        }
        if (path.endsWith('/subjects/400602')) {
          return _json({
            'id': 400602,
            'name': '葬送のフリーレン',
            'name_cn': '葬送的芙莉莲',
            'date': '2023-09-29',
            'platform': 'TV',
            'total_episodes': 2,
            'infobox': [
              {
                'key': '别名',
                'value': [
                  {'v': 'Frieren'},
                ],
              },
            ],
          });
        }
        if (path.endsWith('/subjects/328609')) {
          return _json({
            'id': 328609,
            'name': 'ぼっち・ざ・ろっく！',
            'name_cn': '孤独摇滚！',
            'date': '2022-10-09',
            'platform': 'TV',
            'total_episodes': 2,
            'infobox': [
              {
                'key': '别名',
                'value': [
                  {'v': 'Bocchi'},
                ],
              },
            ],
          });
        }
        if (path.endsWith('/subjects/400602/subjects') ||
            path.endsWith('/subjects/328609/subjects')) {
          return _json([]);
        }
        if (path.endsWith('/search/tv') || path.endsWith('/search/movie')) {
          final q = (req.url.queryParameters['query'] ?? '').toLowerCase();
          tmdbSearchQueries.add(q);
          if (q.contains('bocchi') || q.contains('孤独摇滚') || q.contains('ぼっち')) {
            return _json({
              'results': [
                {
                  'id': 134148,
                  'name': '孤独摇滚！',
                  'original_name': 'ぼっち・ざ・ろっく！',
                  'first_air_date': '2022-10-09',
                  'genre_ids': [16],
                },
              ],
            });
          }
          return _json({'results': []});
        }
        if (path.endsWith('/tv/209867')) {
          final append = req.url.queryParameters['append_to_response'] ?? '';
          final hasImages = append.contains('images');
          detailImageFlags.putIfAbsent('209867', () => []).add(hasImages);
          return _json({
            'id': 209867,
            'name': '葬送的芙莉莲',
            'original_name': '葬送のフリーレン',
            'first_air_date': '2023-09-29',
            'poster_path': '/frieren_p.jpg',
            'backdrop_path': '/frieren_b.jpg',
            'vote_count': 1200,
            'genres': [
              {'id': 16},
            ],
            'alternative_titles': {
              'results': [
                {'title': 'Frieren'},
              ],
            },
            'seasons': [
              {
                'season_number': 1,
                'name': '第 1 季',
                'episode_count': 2,
                'air_date': '2023-09-29',
              },
            ],
            if (hasImages)
              'images': {
                'logos': [
                  {
                    'iso_639_1': 'zh',
                    'iso_3166_1': 'CN',
                    'file_path': '/frieren_logo.png',
                    'vote_average': 9.0,
                    'vote_count': 10,
                  },
                ],
                'backdrops': [],
                'posters': [],
              },
          });
        }
        if (path.endsWith('/tv/999999')) {
          // 故意返回毫不相干的错误条目，验证防误绑防线自动放弃快通道并回退全量搜索
          return _json({
            'id': 999999,
            'name': '完全无关的纪录片',
            'original_name': 'Unrelated Documentary',
            'first_air_date': '1995-01-01',
            'vote_count': 50,
            'genres': [
              {'id': 99},
            ],
            'seasons': [
              {'season_number': 1, 'name': 'S1', 'episode_count': 20},
            ],
          });
        }
        if (path.endsWith('/tv/134148')) {
          return _json({
            'id': 134148,
            'name': '孤独摇滚！',
            'original_name': 'ぼっち・ざ・ろっく！',
            'first_air_date': '2022-10-09',
            'poster_path': '/bocchi_p.jpg',
            'backdrop_path': '/bocchi_b.jpg',
            'vote_count': 900,
            'genres': [
              {'id': 16},
            ],
            'alternative_titles': {
              'results': [
                {'title': 'Bocchi'},
              ],
            },
            'seasons': [
              {
                'season_number': 1,
                'name': '第 1 季',
                'episode_count': 2,
                'air_date': '2022-10-09',
              },
            ],
          });
        }
        if (path.endsWith('/season/1')) {
          return _json({
            'name': '第 1 季',
            'episodes': [
              {'episode_number': 1, 'name': '第 1 话'},
              {'episode_number': 2, 'name': '第 2 话'},
            ],
          });
        }
        return _json({}, 404);
      });

      final httpClient = TmdbHttpClient(
        config: const TmdbNetworkConfig(credential: 'v3_test'),
        scheduler: PriorityHttpScheduler(maxRetries: 0),
        httpClient: mockClient,
      );
      final orchestrator = ScrapeOrchestrator(
        repository: repo,
        tmdbService: TmdbService(httpClient: httpClient),
        bangumiService: BangumiService(httpClient: httpClient),
        gatewayBuilder: (s) async => LocalSourceGateway(rootPath: s.location),
        computeWorker: const ScrapeComputeWorker(useIsolate: false),
        mappingIndex: mappingIndex,
      );

      final summary = await orchestrator.scanAndScrapeSource(source);
      expect(summary.matchedWorks, 2);

      final works = await repo.getAllWorks();
      final frieren = works.firstWhere((w) => w.bangumiId == 400602);
      expect(frieren.tmdbId, 209867);
      expect(frieren.logoPath, '/frieren_logo.png', reason: '优胜条目必须按需补全高清图集与 Logo');
      // 芙莉莲直接走映射快通道，从未发起任何针对 frieren 的 TMDB 关键词检索
      expect(
        tmdbSearchQueries.any((q) => q.contains('frieren') || q.contains('芙莉莲')),
        isFalse,
      );
      // 轻量初筛 (false) -> 确认绑定后补全图集 (true)
      expect(detailImageFlags['209867'], [false, true]);

      // 孤独摇滚映射故意错链到 999999，必须被拦截并回退全量搜索绑定正确条目 134148
      final bocchi = works.firstWhere((w) => w.bangumiId == 328609);
      expect(bocchi.tmdbId, 134148);
    });

    test('2. 跨作品并发提速实测对比、增量重扫零请求快跳与文件变动失效', () async {
      for (var i = 1; i <= 6; i++) {
        await touchFile('Anime$i (2024) {tmdb-${1000 + i}}/Anime$i [01].mkv');
      }
      final source = MediaSource(
        id: 'src_concurrent',
        kind: MediaSourceKind.local,
        label: '并发提速对比盘',
        location: tempRoot.path,
      );
      await repo.upsertMediaSource(source);

      var totalHttpCalls = 0;
      var inFlight = 0;
      var peakInFlight = 0;

      MockClient buildSlowClient() => MockClient((req) async {
        totalHttpCalls++;
        inFlight++;
        if (inFlight > peakInFlight) peakInFlight = inFlight;
        await Future<void>.delayed(const Duration(milliseconds: 35));
        try {
          final path = req.url.path;
          final tvMatch = RegExp(r'/tv/(\d+)$').firstMatch(path);
          if (tvMatch != null) {
            final id = int.parse(tvMatch.group(1)!);
            final idx = id - 1000;
            return _json({
              'id': id,
              'name': 'Anime$idx',
              'first_air_date': '2024-01-01',
              'vote_count': 100,
              'genres': [
                {'id': 16},
              ],
              'seasons': [
                {'season_number': 1, 'name': 'S1', 'episode_count': 1},
              ],
            });
          }
          if (path.endsWith('/season/1')) {
            return _json({
              'name': 'S1',
              'episodes': [
                {'episode_number': 1, 'name': '第 1 话'},
              ],
            });
          }
          return _json({'results': []});
        } finally {
          inFlight--;
        }
      });

      // 对比 A：并发度 = 1（串行基线）
      final serialHttp = TmdbHttpClient(
        config: const TmdbNetworkConfig(credential: 'v3_test'),
        scheduler: PriorityHttpScheduler(maxRetries: 0),
        httpClient: buildSlowClient(),
      );
      final serialOrch = ScrapeOrchestrator(
        repository: repo,
        tmdbService: TmdbService(httpClient: serialHttp),
        gatewayBuilder: (s) async => LocalSourceGateway(rootPath: s.location),
        computeWorker: const ScrapeComputeWorker(useIsolate: false),
        maxWorkConcurrency: 1,
      );
      final serialSw = Stopwatch()..start();
      await serialOrch.scanAndScrapeSource(source);
      serialSw.stop();

      // 清空既有作品后执行并发度 = 5（阶段三默认并发池）同负载实测对比
      for (final w in await repo.getAllWorks()) {
        await repo.deleteWork(w.id);
      }
      totalHttpCalls = 0;
      peakInFlight = 0;
      final parallelHttp = TmdbHttpClient(
        config: const TmdbNetworkConfig(credential: 'v3_test'),
        scheduler: PriorityHttpScheduler(maxRetries: 0),
        httpClient: buildSlowClient(),
      );
      final parallelOrch = ScrapeOrchestrator(
        repository: repo,
        tmdbService: TmdbService(httpClient: parallelHttp),
        gatewayBuilder: (s) async => LocalSourceGateway(rootPath: s.location),
        computeWorker: const ScrapeComputeWorker(useIsolate: false),
        maxWorkConcurrency: 5,
      );
      final parallelSw = Stopwatch()..start();
      final res = await parallelOrch.scanAndScrapeSource(source);
      parallelSw.stop();

      stdout.writeln(
        'stage3 concurrency benchmark (6 works): '
        'serial=${serialSw.elapsedMilliseconds}ms vs '
        'parallel(5)=${parallelSw.elapsedMilliseconds}ms, '
        'peakInFlight=$peakInFlight',
      );
      expect(res.matchedWorks, 6);
      expect(peakInFlight, greaterThanOrEqualTo(3));
      expect(
        parallelSw.elapsedMilliseconds,
        lessThan(serialSw.elapsedMilliseconds),
      );

      // 增量重扫：物理文件未变，二次扫描网络请求必须为 0
      totalHttpCalls = 0;
      final rescanUnchanged = await parallelOrch.scanAndScrapeSource(source);
      expect(rescanUnchanged.matchedWorks, 6);
      expect(totalHttpCalls, 0, reason: '未变动已匹配作品二次重扫必须零在线请求快跳');

      // 为 Anime1 新增一集后重扫：仅触发 Anime1 增量同步，其余 5 部继续零请求快跳
      await touchFile('Anime1 (2024) {tmdb-1001}/Anime1 [02].mkv');
      totalHttpCalls = 0;
      await parallelOrch.scanAndScrapeSource(source);
      expect(totalHttpCalls, greaterThan(0));
      expect(totalHttpCalls, lessThanOrEqualTo(3));
      final anime1 = (await repo.getAllWorks()).firstWhere(
        (w) => w.tmdbId == 1001,
      );
      expect(await repo.getVariantsByWork(anime1.id), hasLength(2));

      // 新增外挂字幕时必须打破快跳并将新字幕入库
      await touchFile('Anime2 (2024) {tmdb-1002}/Anime2 [01].sc.ass', bytes: 64);
      totalHttpCalls = 0;
      await parallelOrch.scanAndScrapeSource(source);
      expect(totalHttpCalls, greaterThan(0));
      final anime2 = (await repo.getAllWorks()).firstWhere(
        (w) => w.tmdbId == 1002,
      );
      final anime2Variants = await repo.getVariantsByWork(anime2.id);
      expect(
        anime2Variants.single.externalSubtitles,
        contains('Anime2 (2024) {tmdb-1002}/Anime2 [01].sc.ass'),
      );

      // 仅命中 Bangumi（缺少 tmdbId）的非锁定作品不得被增量快跳，重扫须补绑 TMDB
      final anime3 = (await repo.getAllWorks()).firstWhere(
        (w) => w.tmdbId == 1003,
      );
      await repo.upsertWork(
        Work(
          id: anime3.id,
          bangumiId: 33333,
          title: anime3.title,
          year: anime3.year,
          scrapeStatus: ScrapeStatus.matched,
        ),
      );
      totalHttpCalls = 0;
      await parallelOrch.scanAndScrapeSource(source);
      expect(totalHttpCalls, greaterThan(0));
      final anime3After = await repo.findWorkById(anime3.id);
      expect(anime3After?.tmdbId, 1003);
    });

    test('3. 分域 HTTP 并发桶隔离 429 冷却，且单次备用 5xx 不破坏主域名冷却窗口', () async {
      final scheduler = PriorityHttpScheduler(maxRetries: 1);
      expect(scheduler.concurrencyLimitForBucket('tmdb'), 6);
      expect(scheduler.concurrencyLimitForBucket('bangumi'), 4);

      // Bangumi 桶触发 429 后仅退避 bangumi 桶，tmdb 桶保持立即调度不被拖累
      var bgmAttempts = 0;
      final bgmFuture = scheduler.schedule<String>(
        RequestPriority.background,
        () async {
          bgmAttempts++;
          if (bgmAttempts == 1) {
            throw const RateLimitedHttpException(Duration(milliseconds: 250));
          }
          return 'bgm_ok';
        },
        bucketKey: 'bangumi',
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final tmdbSw = Stopwatch()..start();
      final tmdbRes = await scheduler.schedule<String>(
        RequestPriority.background,
        () async => 'tmdb_fast',
        bucketKey: 'tmdb',
      );
      tmdbSw.stop();
      expect(tmdbRes, 'tmdb_fast');
      expect(tmdbSw.elapsedMilliseconds, lessThan(150));
      expect(await bgmFuture, 'bgm_ok');

      // 验证冷却期内备用偶发单次 502 不立刻打穿主域名冷却，连续 3 次 502 才解除冷却重新探活
      final now = DateTime(2026, 11, 21, 10, 0);
      final cooldown = DomainCooldownRegistry()..markBlocked('api.bgm.tv', now);
      final hosts = <String>[];
      final client = MockClient((req) async {
        hosts.add(req.url.host);
        if (req.url.host == 'api.bgm.lat') {
          return http.Response('bad gateway', 502);
        }
        return _json({'ok': true});
      });
      final httpClient = TmdbHttpClient(
        config: const TmdbNetworkConfig(credential: 'v3_test'),
        scheduler: PriorityHttpScheduler(maxRetries: 0),
        httpClient: client,
        cooldownRegistry: cooldown,
        nowProvider: () => now,
      );

      final r1 = await httpClient.getWithFallback(
        Uri.parse('https://api.bgm.tv/v0/subjects/1'),
        backupUri: Uri.parse('https://api.bgm.lat/v0/subjects/1'),
      );
      expect(r1.statusCode, 502);
      expect(cooldown.isCoolingDown('api.bgm.tv', now), isTrue);
      expect(hosts, ['api.bgm.lat']);

      final r2 = await httpClient.getWithFallback(
        Uri.parse('https://api.bgm.tv/v0/subjects/2'),
        backupUri: Uri.parse('https://api.bgm.lat/v0/subjects/2'),
      );
      expect(r2.statusCode, 502);
      expect(cooldown.isCoolingDown('api.bgm.tv', now), isTrue);

      // 第 3 次连续 502 触发探活回切官方域名
      final r3 = await httpClient.getWithFallback(
        Uri.parse('https://api.bgm.tv/v0/subjects/3'),
        backupUri: Uri.parse('https://api.bgm.lat/v0/subjects/3'),
      );
      expect(r3.statusCode, 200);
      expect(hosts.last, 'api.bgm.tv');
      expect(cooldown.isCoolingDown('api.bgm.tv', now), isFalse);
    });

    test('4. 常驻 Isolate 会话跨多次计算复用与干净释放 + SeriesAutoLinker 并发关联', () async {
      final session = const ScrapeComputeWorker(useIsolate: true).openSession();
      try {
        final grouped = await session.groupFiles(
          sourceId: 'src_iso',
          files: const [
            ScannedFileInput(
              relativePath: 'Frieren (2023)/[VCB-Studio] Frieren [01].mkv',
              fileName: '[VCB-Studio] Frieren [01].mkv',
              fileSize: 500000000,
              assetKind: AssetKind.video,
            ),
          ],
        );
        expect(grouped, hasLength(1));
        final bgmRes = await session.evaluateBangumiMatch(grouped.single, const []);
        expect(bgmRes.best, isNull);
        final tmdbRes = await session.evaluateMatch(
          grouped.single,
          const [],
          mappingIndex: BangumiTmdbIndex.empty(),
        );
        expect(tmdbRes.best, isNull);
      } finally {
        await session.dispose();
      }

      // 验证 SeriesAutoLinker 批量加载变体并并发查询 Bangumi 关联条目
      for (var i = 1; i <= 4; i++) {
        await repo.upsertWork(
          Work(
            id: 'w_rel_$i',
            bangumiId: 500 + i,
            title: '系列作 $i',
            year: 2020 + i,
            scrapeStatus: ScrapeStatus.matched,
          ),
        );
      }
      var relInFlight = 0;
      var relPeak = 0;
      final relClient = MockClient((req) async {
        relInFlight++;
        if (relInFlight > relPeak) relPeak = relInFlight;
        await Future<void>.delayed(const Duration(milliseconds: 30));
        try {
          if (req.url.path.endsWith('/subjects/501/subjects')) {
            return _json([
              {'id': 502, 'relation': '续集', 'name': 'S2', 'name_cn': '系列作 2'},
            ]);
          }
          return _json([]);
        } finally {
          relInFlight--;
        }
      });
      final bgmService = BangumiService(
        httpClient: TmdbHttpClient(
          config: const TmdbNetworkConfig(credential: 'v3_test'),
          scheduler: PriorityHttpScheduler(maxRetries: 0),
          httpClient: relClient,
        ),
      );
      final mutated = await SeriesAutoLinker.reconcileAll(
        repository: repo,
        bangumiService: bgmService,
      );
      expect(mutated, isTrue);
      expect(relPeak, greaterThan(1));
      final w1 = await repo.findWorkById('w_rel_1');
      final w2 = await repo.findWorkById('w_rel_2');
      expect(w1?.seriesId, isNotNull);
      expect(w1?.seriesId, w2?.seriesId);
    });
  });
}
