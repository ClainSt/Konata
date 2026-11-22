import 'dart:convert';
import 'dart:io';

import 'package:konata/application/providers/library_providers.dart';
import 'package:konata/application/providers/work_merge_actions.dart';
import 'package:konata/application/scraping/clear_logo_resolver.dart';
import 'package:konata/application/scraping/scrape_compute_worker.dart';
import 'package:konata/application/scraping/scrape_orchestrator.dart';
import 'package:konata/domain/formatting/network_error_sanitizer.dart';
import 'package:konata/domain/matching/directory_grouper.dart';
import 'package:konata/domain/models/episode.dart';
import 'package:konata/domain/models/fanart_models.dart';
import 'package:konata/domain/models/media_source.dart';
import 'package:konata/domain/models/media_variant.dart';
import 'package:konata/domain/models/network_config.dart';
import 'package:konata/domain/models/work.dart';
import 'package:konata/domain/scraping/bangumi_tmdb_index.dart';
import 'package:konata/domain/scraping/scrape_domain_adapter.dart';
import 'package:konata/infrastructure/database/drift_library_repository.dart';
import 'package:konata/infrastructure/database/konata_database.dart';
import 'package:konata/infrastructure/network/bangumi_service.dart';
import 'package:konata/infrastructure/network/fanart_service.dart';
import 'package:konata/infrastructure/network/priority_http_scheduler.dart';
import 'package:konata/infrastructure/network/tmdb_http_client.dart';
import 'package:konata/infrastructure/network/tmdb_service.dart';
import 'package:konata/infrastructure/sources/directory_scanner.dart';
import 'package:konata/infrastructure/sources/local_source_gateway.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

void main() {
  group('FanartService 无状态中继、自定义覆盖与 429/1027 熔断闭环', () {
    test('默认中继模式零 api-key 暴露，仅透传合法 client-key 并按中文>日文>英文与高清优先排序', () async {
      final capturedRequests = <http.Request>[];
      final mockClient = MockClient((request) async {
        capturedRequests.add(request);
        return http.Response(
          jsonEncode({
            'name': 'Frieren',
            'clearlogo': [
              {
                'id': '1',
                'url': 'http://assets.fanart.tv/fanart/tv/424536/clearlogo/en.png',
                'lang': 'en',
                'likes': '12',
              },
            ],
            'hdtvlogo': [
              {
                'id': '2',
                'url': 'https://assets.fanart.tv/fanart/tv/424536/hdtvlogo/ja.png',
                'lang': 'ja',
                'likes': '5',
              },
              {
                'id': '3',
                'url': 'https://assets.fanart.tv/fanart/tv/424536/hdtvlogo/zh.png',
                'lang': 'zh',
                'likes': '2',
              },
            ],
          }),
          200,
          headers: const {'content-type': 'application/json'},
        );
      });

      const cfg = TmdbNetworkConfig(
        fanartBackupApiBase: 'https://relay.konata.example',
        fanartClientKey: 'abcdef1234567890abcdef1234567890',
      );
      final client = TmdbHttpClient(
        config: cfg,
        scheduler: PriorityHttpScheduler(maxRetries: 0),
        httpClient: mockClient,
      );
      final fanart = FanartService(httpClient: client);

      final result = await fanart.fetchLogos(
        mediaType: TmdbMediaType.tv,
        tvdbId: 424536,
      );

      expect(capturedRequests, hasLength(1));
      final req = capturedRequests.first;
      expect(req.url.toString(), 'https://relay.konata.example/fanart/v3/tv/424536');
      expect(req.headers.containsKey('api-key'), isFalse);
      expect(req.headers.containsKey('x-konata-app-token'), isFalse);
      expect(req.headers['client-key'], 'abcdef1234567890abcdef1234567890');
      expect(result.logos.length, 3);
      expect(result.logos.first.url, contains('/zh.png'));
      expect(result.logos[1].url, contains('/ja.png'));
      expect(result.logos[2].url, startsWith('https://assets.fanart.tv/'));
    });

    test('自定义 api-key 覆盖模式直连官方 Fanart.tv v3', () async {
      final captured = <http.Request>[];
      final mockClient = MockClient((request) async {
        captured.add(request);
        return http.Response(
          jsonEncode({
            'hdmovielogo': [
              {
                'id': '9',
                'url': 'https://assets.fanart.tv/fanart/movies/129/hdmovielogo/zh.png',
                'lang': 'zh',
                'likes': '8',
              },
            ],
          }),
          200,
        );
      });

      const cfg = TmdbNetworkConfig(
        fanartApiKeyOverride: 'my_custom_project_key_123456',
      );
      final client = TmdbHttpClient(
        config: cfg,
        scheduler: PriorityHttpScheduler(maxRetries: 0),
        httpClient: mockClient,
      );
      final fanart = FanartService(httpClient: client);
      final res = await fanart.fetchLogos(
        mediaType: TmdbMediaType.movie,
        tmdbId: 129,
      );

      expect(captured.first.url.toString(), 'https://webservice.fanart.tv/v3/movies/129');
      expect(captured.first.headers['api-key'], 'my_custom_project_key_123456');
      expect(res.bestLogoUrl, contains('hdmovielogo/zh.png'));
    });

    test('精准区分 429 频率限流与 Cloudflare 1027 日额度耗尽熔断', () async {
      var now = DateTime.utc(2026, 11, 21, 10, 0, 0);
      final breaker = FanartCircuitBreaker();

      // 1. 频率限流：即便调度器 maxRetries=3，无状态中继仍必须首次 429 即刻熔断（0 退避阻塞）
      var rateLimitCalls = 0;
      final rateLimitClient = TmdbHttpClient(
        config: const TmdbNetworkConfig(
          fanartBackupApiBase: 'https://relay.konata.example',
        ),
        scheduler: PriorityHttpScheduler(maxRetries: 3),
        httpClient: MockClient((_) async {
          rateLimitCalls++;
          return http.Response(
            '{"error":"rate_limited","retryAfter":60}',
            429,
            headers: const {
              'content-type': 'application/json',
              'x-konata-relay-error': 'rate_limited',
              'retry-after': '60',
            },
          );
        }),
      );
      final svc1 = FanartService(
        httpClient: rateLimitClient,
        circuitBreaker: breaker,
        nowProvider: () => now,
      );
      final sw = Stopwatch()..start();
      final res1 = await svc1.fetchLogos(
        mediaType: TmdbMediaType.movie,
        tmdbId: 129,
      );
      sw.stop();
      expect(rateLimitCalls, 1);
      expect(sw.elapsedMilliseconds, lessThan(300));
      expect(res1.authRejected, isTrue);
      expect(breaker.snapshot(now).status, FanartRelayStatus.rateLimited);

      // 1b. 中继连续瞬态握手异常达到阈值后同样自动熔断，避免阻塞批量刮削
      breaker.reset();
      var transportErrCalls = 0;
      final flakyRelayClient = TmdbHttpClient(
        config: const TmdbNetworkConfig(
          fanartBackupApiBase: 'https://relay.konata.example',
        ),
        scheduler: PriorityHttpScheduler(maxRetries: 2),
        httpClient: MockClient((_) async {
          transportErrCalls++;
          throw const HandshakeException('relay tls reset');
        }),
      );
      final svcFlaky = FanartService(
        httpClient: flakyRelayClient,
        circuitBreaker: breaker,
        nowProvider: () => now,
      );
      await svcFlaky.fetchLogos(mediaType: TmdbMediaType.movie, tmdbId: 201);
      await svcFlaky.fetchLogos(mediaType: TmdbMediaType.movie, tmdbId: 202);
      expect(breaker.isOpen(now), isTrue);
      await svcFlaky.fetchLogos(mediaType: TmdbMediaType.movie, tmdbId: 203);
      expect(transportErrCalls, 2);

      // 2. 重置后模拟 Cloudflare 免费日额度耗尽（1027 非 JSON 429）
      breaker.reset();
      var callCount = 0;
      final quotaClient = TmdbHttpClient(
        config: const TmdbNetworkConfig(
          fanartBackupApiBase: 'https://relay.konata.example',
        ),
        scheduler: PriorityHttpScheduler(maxRetries: 2),
        httpClient: MockClient((_) async {
          callCount++;
          return http.Response(
            '<html>Error code: 1027 You have exceeded your daily request limit</html>',
            429,
            headers: const {'content-type': 'text/html'},
          );
        }),
      );
      final svc2 = FanartService(
        httpClient: quotaClient,
        circuitBreaker: breaker,
        nowProvider: () => now,
      );
      await svc2.fetchLogos(mediaType: TmdbMediaType.movie, tmdbId: 129);
      // 额度耗尽不进行无意义退避重试，且立即触发熔断拦截后续请求
      expect(callCount, 1);
      expect(breaker.snapshot(now).status, FanartRelayStatus.quotaExhausted);
      await svc2.fetchLogos(mediaType: TmdbMediaType.movie, tmdbId: 130);
      expect(callCount, 1);
    });
  });

  group('ClearLogoResolver 漏斗、分层负缓存与离线 KTBM v2 tvdbId 反查', () {
    test('TMDB 无图但附带 external_ids.tvdb_id 时自动回落 Fanart.tv，全部无图按年份写 3 天/30 天负缓存', () async {
      final now = DateTime.utc(2026, 11, 21, 12, 0, 0);
      final mockClient = MockClient((request) async {
        if (request.url.host == 'api.themoviedb.org') {
          expect(request.url.queryParameters['append_to_response'], contains('external_ids'));
          if (request.url.path.endsWith('/tv/9001')) {
            return http.Response.bytes(
              utf8.encode(
                jsonEncode({
                  'id': 9001,
                  'name': '经典番剧',
                  'images': {'logos': []},
                  'external_ids': {'tvdb_id': 778899},
                }),
              ),
              200,
              headers: const {'content-type': 'application/json; charset=utf-8'},
            );
          }
          return http.Response.bytes(
            utf8.encode(
              jsonEncode({
                'id': 9002,
                'name': '无图新番',
                'images': {'logos': []},
                'external_ids': {'tvdb_id': 112233},
              }),
            ),
            200,
            headers: const {'content-type': 'application/json; charset=utf-8'},
          );
        }
        if (request.url.host == 'relay.konata.example') {
          if (request.url.path == '/fanart/v3/tv/778899') {
            return http.Response(
              jsonEncode({
                'hdtvlogo': [
                  {
                    'id': 'f1',
                    'url': 'https://assets.fanart.tv/fanart/tv/778899/hdtvlogo/zh.png',
                    'lang': 'zh',
                    'likes': '10',
                  },
                ],
              }),
              200,
              headers: const {'content-type': 'application/json'},
            );
          }
          return http.Response('{"error":"not_found"}', 404);
        }
        return http.Response('not found', 404);
      });

      const cfg = TmdbNetworkConfig(
        credential: 'test_tmdb_key',
        fanartBackupApiBase: 'https://relay.konata.example',
      );
      final httpClient = TmdbHttpClient(
        config: cfg,
        scheduler: PriorityHttpScheduler(maxRetries: 0),
        httpClient: mockClient,
      );
      final resolver = ClearLogoResolver(
        tmdbService: TmdbService(httpClient: httpClient),
        fanartService: FanartService(httpClient: httpClient),
        networkConfig: cfg,
        nowProvider: () => now,
      );

      // 1. TMDB 无图 -> 借助同次 external_ids.tvdb_id 命中 Fanart.tv
      const workHit = Work(
        id: 'w_hit',
        title: '经典番剧',
        tmdbId: 9001,
        tmdbMediaType: TmdbMediaType.tv,
        year: 2015,
      );
      final outHit = await resolver.resolveForWork(workHit);
      expect(outHit.resolvedTvdbId, 778899);
      expect(outHit.logoPath, contains('778899/hdtvlogo/zh.png'));
      expect(outHit.negativeUntil, isNull);

      // 2. 当年新番双源无图 -> 3 天负缓存；老番 -> 30 天；新增 clientKey 立即破冰
      const recentMiss = Work(
        id: 'w_miss',
        title: '无图新番',
        tmdbId: 9002,
        tmdbMediaType: TmdbMediaType.tv,
        year: 2026,
      );
      final outMiss = await resolver.resolveForWork(recentMiss);
      expect(outMiss.logoPath, isNull);
      expect(outMiss.negativeUntil, now.add(const Duration(days: 3)));
      expect(
        outMiss.negativeMask & ClearLogoNegativeMask.tmdb,
        isNonZero,
      );
      expect(
        outMiss.negativeMask & ClearLogoNegativeMask.fanart,
        isNonZero,
      );

      final cooledWork = recentMiss.copyWith(
        tvdbId: outMiss.resolvedTvdbId,
        logoNegativeUntil: outMiss.negativeUntil,
        logoNegativeMask: outMiss.negativeMask,
      );
      expect(
        ClearLogoResolver.shouldAttemptDetailLogoBackfill(
          work: cooledWork,
          config: cfg,
          now: now.add(const Duration(hours: 6)),
        ),
        isFalse,
      );
      // 用户新填入 Personal Key 后，能力掩码新增 fanartWithClientKey -> 立刻破冰允许补查
      expect(
        ClearLogoResolver.shouldAttemptDetailLogoBackfill(
          work: cooledWork,
          config: cfg.copyWith(
            fanartClientKey: 'abcdef1234567890abcdef1234567890',
          ),
          now: now.add(const Duration(hours: 6)),
        ),
        isTrue,
      );
    });

    test('离线 KTBM v2 映射表在无 TMDB 密钥时直接反查 tvdbId 驱动 Fanart 补全', () async {
      final v2Bytes = BangumiTmdbIndex.encode(
        const [
          BangumiTmdbRecord(
            bangumiId: 400602,
            type: TmdbMediaType.tv,
            tmdbId: 209867,
            season: 1,
            tvdbId: 424536,
          ),
        ],
        snapshotDateYyyymmdd: 20261121,
      );
      final index = BangumiTmdbIndex.fromBytes(v2Bytes);
      expect(index.supportsTvdbId, isTrue);

      final mockClient = MockClient((request) async {
        if (request.url.path == '/fanart/v3/tv/424536') {
          return http.Response(
            jsonEncode({
              'hdtvlogo': [
                {
                  'id': 'v2_1',
                  'url': 'https://assets.fanart.tv/fanart/tv/424536/hdtvlogo/zh.png',
                  'lang': 'zh',
                  'likes': '9',
                },
              ],
            }),
            200,
          );
        }
        return http.Response('not found', 404);
      });
      const cfg = TmdbNetworkConfig(
        fanartBackupApiBase: 'https://relay.konata.example',
      );
      final httpClient = TmdbHttpClient(
        config: cfg,
        scheduler: PriorityHttpScheduler(maxRetries: 0),
        httpClient: mockClient,
      );
      final resolver = ClearLogoResolver(
        tmdbService: TmdbService(httpClient: httpClient),
        fanartService: FanartService(httpClient: httpClient),
        networkConfig: cfg,
        mappingIndex: index,
      );

      final out = await resolver.resolveForWork(
        const Work(
          id: 'w_v2',
          title: '葬送的芙莉莲',
          tmdbId: 209867,
          tmdbMediaType: TmdbMediaType.tv,
        ),
      );
      expect(out.resolvedTvdbId, 424536);
      expect(out.logoPath, contains('424536/hdtvlogo/zh.png'));
    });

    test('密钥脱敏与 Drift v13 新增列持久化读写完整无损', () async {
      expect(
        NetworkErrorSanitizer.redactSecrets(
          'GET https://x/?client_key=secret123&api-key:abc456',
        ),
        'GET https://x/?client_key=***&api-key:***',
      );

      final db = KonataDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final repo = DriftLibraryRepository(db);
      final until = DateTime.utc(2026, 12, 1, 0, 0, 0);
      await repo.upsertWork(
        Work(
          id: 'w_v13',
          title: '测试作品',
          tvdbId: 424536,
          logoLocked: true,
          logoNegativeUntil: until,
          logoNegativeMask:
              ClearLogoNegativeMask.tmdb | ClearLogoNegativeMask.fanart,
        ),
      );
      final loaded = await repo.findWorkById('w_v13');
      expect(loaded, isNotNull);
      expect(loaded!.tvdbId, 424536);
      expect(loaded.logoLocked, isTrue);
      expect(loaded.logoNegativeUntil?.toUtc(), until);
      expect(
        loaded.logoNegativeMask,
        ClearLogoNegativeMask.tmdb | ClearLogoNegativeMask.fanart,
      );
    });

    test('Fanart 连通性测试准确返回 429 频率限流与 1027 日额度耗尽中文引导', () async {
      // 模拟中继接口正常连通
      final okClient = TmdbHttpClient(
        config: const TmdbNetworkConfig(
          fanartBackupApiBase: 'https://relay.konata.example',
        ),
        scheduler: PriorityHttpScheduler(maxRetries: 0),
        httpClient: MockClient(
          (_) async => http.Response('{"hdmovielogo":[]}', 200),
        ),
      );
      final okRes = await okClient.testFanartApiConnectivity();
      expect(okRes.reachable, isTrue);
      expect(okRes.statusSummary, contains('连通成功'));

      // 模拟中继日额度耗尽（1027）
      final exhaustedClient = TmdbHttpClient(
        config: const TmdbNetworkConfig(
          fanartBackupApiBase: 'https://relay.konata.example',
        ),
        scheduler: PriorityHttpScheduler(maxRetries: 0),
        httpClient: MockClient(
          (_) async => http.Response(
            'Error code: 1027 exceeded daily limit',
            429,
            headers: const {'content-type': 'text/html'},
          ),
        ),
      );
      final exhaustedRes = await exhaustedClient.testFanartApiConnectivity();
      expect(exhaustedRes.reachable, isFalse);
      expect(exhaustedRes.statusSummary, contains('免费额度'));

      // 模拟单用户频率限流（429 + X-Konata-Relay-Error）
      final limitedClient = TmdbHttpClient(
        config: const TmdbNetworkConfig(
          fanartBackupApiBase: 'https://relay.konata.example',
        ),
        scheduler: PriorityHttpScheduler(maxRetries: 0),
        httpClient: MockClient(
          (_) async => http.Response(
            '{"error":"rate_limited"}',
            429,
            headers: const {
              'content-type': 'application/json',
              'x-konata-relay-error': 'rate_limited',
            },
          ),
        ),
      );
      final limitedRes = await limitedClient.testFanartApiConnectivity();
      expect(limitedRes.reachable, isFalse);
      expect(limitedRes.statusSummary, contains('请求频繁'));
    });

    test('Fanart 项目 API Key 生效优先级严格遵循「设置页手填 > 编译期注入 > 空」', () {
      expect(
        TmdbNetworkConfig.resolveEffectiveFanartApiKey(
          manualOverride: 'manual_override_key',
          compileTimeKey: 'compile_time_key',
        ),
        'manual_override_key',
      );
      expect(
        TmdbNetworkConfig.resolveEffectiveFanartApiKey(
          manualOverride: '   ',
          compileTimeKey: 'compile_time_key',
        ),
        'compile_time_key',
      );
      expect(
        TmdbNetworkConfig.resolveEffectiveFanartApiKey(
          manualOverride: '',
          compileTimeKey: '',
        ),
        isEmpty,
      );
      expect(
        TmdbNetworkConfig.builtInFanartRelayBase,
        'https://api.konata.acgcc.cn',
      );
      // 自定义直连模式下不将内置中继误作直连反代，防止向公开中继透传用户私有 api-key
      const directDefault = TmdbNetworkConfig(
        fanartApiKeyOverride: 'my_custom_key_123456',
      );
      expect(directDefault.normalizedFanartDirectBackupApiBase, isEmpty);
      const directCustomProxy = TmdbNetworkConfig(
        fanartApiKeyOverride: 'my_custom_key_123456',
        fanartBackupApiBase: 'https://my-fanart-proxy.example',
      );
      expect(
        directCustomProxy.normalizedFanartDirectBackupApiBase,
        'https://my-fanart-proxy.example',
      );
    });
  });

  group('Fanart 整包缓存、多源徽标/背景联合升级、跨源防合并与独立上墙全链路回归', () {
    test('单次 Fanart 整包缓存复用三次读取仅发 1 次请求，解析分季海报与 1080p 无字背景并严格剔除 tvthumb/moviethumb', () async {
      var httpCalls = 0;
      final mockClient = MockClient((request) async {
        httpCalls++;
        return http.Response(
          jsonEncode({
            'hdtvlogo': [
              {
                'id': 'l1',
                'url': 'https://assets.fanart.tv/fanart/tv/424536/hdtvlogo/ja.png',
                'lang': 'ja',
                'likes': '14',
              },
            ],
            'tvposter': [
              {
                'id': 'p1',
                'url': 'https://assets.fanart.tv/fanart/tv/424536/tvposter/main.jpg',
                'lang': 'ja',
                'likes': '9',
              },
            ],
            'seasonposter': [
              {
                'id': 'sp1',
                'url': 'https://assets.fanart.tv/fanart/tv/424536/seasonposter/s1.jpg',
                'lang': 'zh',
                'likes': '12',
                'season': '1',
              },
              {
                'id': 'sp0',
                'url': 'https://assets.fanart.tv/fanart/tv/424536/seasonposter/s0.jpg',
                'lang': 'ja',
                'likes': '4',
                'season': '0',
              },
            ],
            'showbackground': [
              {
                'id': 'bg1',
                'url': 'https://assets.fanart.tv/fanart/tv/424536/showbackground/low.jpg',
                'likes': '3',
              },
              {
                'id': 'bg2',
                'url': 'https://assets.fanart.tv/fanart/tv/424536/showbackground/top.jpg',
                'likes': '25',
              },
            ],
            'tvthumb': [
              {
                'id': 'bad1',
                'url': 'https://assets.fanart.tv/fanart/tv/424536/tvthumb/texted.jpg',
                'likes': '99',
              },
            ],
          }),
          200,
          headers: const {'content-type': 'application/json'},
        );
      });

      final cache = FanartArtworkCache();
      final httpClient = TmdbHttpClient(
        config: const TmdbNetworkConfig(
          fanartBackupApiBase: 'https://relay.konata.example',
        ),
        scheduler: PriorityHttpScheduler(maxRetries: 0),
        httpClient: mockClient,
      );
      final fanart = FanartService(
        httpClient: httpClient,
        artworkCache: cache,
      );

      final first = await fanart.fetchArtworkBundle(
        mediaType: TmdbMediaType.tv,
        tvdbId: 424536,
      );
      final second = await fanart.fetchArtworkBundle(
        mediaType: TmdbMediaType.tv,
        tvdbId: 424536,
      );
      final third = await fanart.fetchLogos(
        mediaType: TmdbMediaType.tv,
        tvdbId: 424536,
      );
      expect(httpCalls, 1);
      expect(identical(first, second), isTrue);
      expect(identical(first, third), isTrue);

      expect(first.posters, hasLength(3));
      final s1 = first.posters.firstWhere((e) => e.season == 1);
      final sp = first.posters.firstWhere((e) => e.season == 0);
      expect(s1.sourceLabel, 'Fanart.tv·S1');
      expect(sp.sourceLabel, 'Fanart.tv·SP');
      expect(s1.width, 1000);
      expect(s1.height, 1426);
      expect(s1.previewUrl, contains('/preview/'));
      expect(first.bestPosterUrlForSeason(1), s1.url);

      expect(first.backgrounds, hasLength(2));
      expect(first.bestBackgroundUrl, contains('/top.jpg'));
      expect(
        first.backgrounds.any((b) => b.url.contains('tvthumb')),
        isFalse,
      );
    });

    test('ClearLogoResolver 联合排序将已有 TMDB 英文徽标升级为 Fanart 高清日文，并同步升级 720p 背景且写入防重复掩码', () async {
      final now = DateTime.utc(2026, 11, 21, 15, 0, 0);
      final mockClient = MockClient((request) async {
        if (request.url.host == 'api.themoviedb.org') {
          if (request.url.path.endsWith('/tv/209867')) {
            return http.Response.bytes(
              utf8.encode(
                jsonEncode({
                  'id': 209867,
                  'name': '葬送的芙莉莲',
                  'backdrop_path': '/tmdb_720.jpg',
                  'external_ids': {'tvdb_id': 424536},
                  'images': {
                    'logos': [
                      {
                        'iso_639_1': 'en',
                        'iso_3166_1': 'US',
                        'file_path': '/tmdb_en.png',
                        'width': 1200,
                        'height': 300,
                        'vote_average': 8.5,
                      },
                    ],
                    'backdrops': [
                      {
                        'iso_639_1': null,
                        'file_path': '/tmdb_720.jpg',
                        'width': 1280,
                        'height': 720,
                        'vote_average': 8.0,
                      },
                    ],
                  },
                }),
              ),
              200,
              headers: const {'content-type': 'application/json; charset=utf-8'},
            );
          }
          return http.Response.bytes(
            utf8.encode(
              jsonEncode({
                'id': 209868,
                'name': '仅英文老番',
                'external_ids': {'tvdb_id': 999001},
                'images': {
                  'logos': [
                    {
                      'iso_639_1': 'en',
                      'file_path': '/only_en.png',
                      'width': 1000,
                      'height': 250,
                    },
                  ],
                },
              }),
            ),
            200,
            headers: const {'content-type': 'application/json; charset=utf-8'},
          );
        }
        if (request.url.host == 'relay.konata.example') {
          if (request.url.path == '/fanart/v3/tv/424536') {
            return http.Response(
              jsonEncode({
                'hdtvlogo': [
                  {
                    'id': 'ja1',
                    'url': 'https://assets.fanart.tv/fanart/tv/424536/hdtvlogo/ja.png',
                    'lang': 'ja',
                    'likes': '11',
                  },
                ],
                'showbackground': [
                  {
                    'id': 'bg1080',
                    'url': 'https://assets.fanart.tv/fanart/tv/424536/showbackground/clean_1080.jpg',
                    'likes': '18',
                  },
                ],
              }),
              200,
            );
          }
          return http.Response('{"error":"not_found"}', 404);
        }
        return http.Response('not found', 404);
      });

      const cfg = TmdbNetworkConfig(
        credential: 'tmdb_key',
        fanartBackupApiBase: 'https://relay.konata.example',
      );
      final httpClient = TmdbHttpClient(
        config: cfg,
        scheduler: PriorityHttpScheduler(maxRetries: 0),
        httpClient: mockClient,
      );
      final resolver = ClearLogoResolver(
        tmdbService: TmdbService(httpClient: httpClient),
        fanartService: FanartService(
          httpClient: httpClient,
          artworkCache: FanartArtworkCache(),
        ),
        networkConfig: cfg,
        nowProvider: () => now,
      );

      // 1. 已有非锁定 TMDB 英文徽标的作品允许触发一次性多源联合升级，Fanart 高清日文胜出并同步升级 1080p 背景
      const workWithTmdbEn = Work(
        id: 'w_upgrade',
        title: '葬送的芙莉莲',
        tmdbId: 209867,
        tmdbMediaType: TmdbMediaType.tv,
        logoPath: '/tmdb_en.png',
        backdropPath: '/tmdb_720.jpg',
      );
      expect(
        ClearLogoResolver.shouldAttemptDetailLogoBackfill(
          work: workWithTmdbEn,
          config: cfg,
          now: now,
        ),
        isTrue,
      );
      final upgraded = await resolver.resolveForWork(
        workWithTmdbEn,
        allowUpgradeExisting: true,
        upgradeBackdropIfSuboptimal: true,
      );
      expect(upgraded.logoPath, contains('/hdtvlogo/ja.png'));
      expect(upgraded.upgradedBackdropPath, contains('/clean_1080.jpg'));

      // 2. 若 Fanart 404 未提供更优徽标，则保留原 TMDB 英文徽标并盖章 multiSourceUpgraded 防止反复探测
      const workOnlyEn = Work(
        id: 'w_only_en',
        title: '仅英文老番',
        tmdbId: 209868,
        tmdbMediaType: TmdbMediaType.tv,
        logoPath: '/only_en.png',
      );
      final kept = await resolver.resolveForWork(
        workOnlyEn,
        allowUpgradeExisting: true,
      );
      expect(kept.logoPath, '/only_en.png');
      expect(
        kept.negativeMask & ClearLogoNegativeMask.multiSourceUpgraded,
        isNonZero,
      );
      expect(
        ClearLogoResolver.shouldAttemptDetailLogoBackfill(
          work: workOnlyEn.copyWith(logoNegativeMask: kept.negativeMask),
          config: cfg,
          now: now.add(const Duration(minutes: 10)),
        ),
        isFalse,
      );
    });

    test('findAutoMergeTargetInRepo 仅允许同媒体源自动合并，严格禁止跨源自动合并', () async {
      final db = KonataDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final repo = DriftLibraryRepository(db);
      await repo.upsertMediaSource(
        const MediaSource(
          id: 'src_local',
          kind: MediaSourceKind.local,
          label: '本地磁盘',
          location: r'D:\Anime',
        ),
      );
      await repo.upsertMediaSource(
        const MediaSource(
          id: 'src_webdav',
          kind: MediaSourceKind.webdav,
          label: 'NAS WebDAV',
          location: 'https://nas.example/dav',
        ),
      );

      await repo.upsertWork(
        const Work(
          id: 'w_main_local',
          title: '葬送的芙莉莲',
          tmdbId: 209867,
          tmdbMediaType: TmdbMediaType.tv,
          matchedSeason: 1,
          scrapeStatus: ScrapeStatus.matched,
        ),
      );
      await repo.upsertEpisode(
        const Episode(
          id: 'ep_main_1',
          workId: 'w_main_local',
          seasonNumber: 1,
          episodeNumber: 1,
          category: EpisodeCategory.main,
          title: '第 1 话',
        ),
      );
      await repo.upsertMediaVariant(
        const MediaVariant(
          id: 'v_main_local',
          workId: 'w_main_local',
          episodeId: 'ep_main_1',
          sourceId: 'src_local',
          relativePath: 'Frieren/01.mkv',
          fileName: '01.mkv',
          fileSize: 1000,
        ),
      );

      // 同源 0 正片特典壳 -> 允许合并
      await repo.upsertWork(
        const Work(
          id: 'w_sp_same_src',
          title: '芙莉莲 特典',
          scrapeStatus: ScrapeStatus.needsReview,
        ),
      );
      await repo.upsertMediaVariant(
        const MediaVariant(
          id: 'v_sp_same',
          workId: 'w_sp_same_src',
          sourceId: 'src_local',
          relativePath: 'Frieren/SP/NCOP.mkv',
          fileName: 'NCOP.mkv',
          fileSize: 500,
        ),
      );

      // 跨源（WebDAV）0 正片目录 -> 禁止跨源自动合并
      await repo.upsertWork(
        const Work(
          id: 'w_sp_other_src',
          title: '芙莉莲 特典 WebDAV',
          scrapeStatus: ScrapeStatus.needsReview,
        ),
      );
      await repo.upsertMediaVariant(
        const MediaVariant(
          id: 'v_sp_other',
          workId: 'w_sp_other_src',
          sourceId: 'src_webdav',
          relativePath: 'Frieren/SP/NCOP.mkv',
          fileName: 'NCOP.mkv',
          fileSize: 500,
        ),
      );

      final sameSourceTarget = await findAutoMergeTargetInRepo(
        repo,
        sourceWorkId: 'w_sp_same_src',
        tmdbId: 209867,
        tmdbMediaType: TmdbMediaType.tv,
        matchedSeason: 1,
      );
      expect(sameSourceTarget?.id, 'w_main_local');

      final crossSourceTarget = await findAutoMergeTargetInRepo(
        repo,
        sourceWorkId: 'w_sp_other_src',
        tmdbId: 209867,
        tmdbMediaType: TmdbMediaType.tv,
        matchedSeason: 1,
      );
      expect(crossSourceTarget, isNull);
    });

    test('本地磁盘封面仅本地源扫描生效（不扫 clearlogo），且 Bangumi 独立 OVA 与本地封面独立上墙、纯特典不误拆', () async {
      final tempRoot = await Directory.systemTemp.createTemp(
        'konata_wall_decouple_',
      );
      addTearDown(() async {
        if (await tempRoot.exists()) {
          await tempRoot.delete(recursive: true);
        }
      });

      // 1. 仅本地封面独立作品（含正片 + poster.jpg + clearlogo.png）
      final localOnlyDir = Directory(p.join(tempRoot.path, 'Indie Short (2024)'));
      await localOnlyDir.create(recursive: true);
      await File(
        p.join(localOnlyDir.path, '[Sub] Indie Short [01][1080p].mkv'),
      ).writeAsBytes(List<int>.filled(64, 1));
      await File(p.join(localOnlyDir.path, 'poster.jpg')).writeAsBytes([1, 2, 3]);
      await File(p.join(localOnlyDir.path, 'clearlogo.png')).writeAsBytes([4, 5, 6]);

      // 2. 纯特典目录（0 正片，仅有 NCOP + poster.jpg），绝不可独立建卡
      final extraDir = Directory(p.join(tempRoot.path, 'Only Extras (2024)'));
      await extraDir.create(recursive: true);
      await File(
        p.join(extraDir.path, '[VCB-Studio] Only Extras [NCOP01][1080p].mkv'),
      ).writeAsBytes(List<int>.filled(64, 2));
      await File(p.join(extraDir.path, 'poster.jpg')).writeAsBytes([1, 2, 3]);

      // 3. 仅 Bangumi 独立 OVA（TMDB 无条目，Bangumi 有封面与简介）
      final bgmOvaDir = Directory(p.join(tempRoot.path, 'Mystic OVA (2025)'));
      await bgmOvaDir.create(recursive: true);
      await File(
        p.join(bgmOvaDir.path, '[VCB-Studio] Mystic OVA [01][1080p].mkv'),
      ).writeAsBytes(List<int>.filled(64, 3));

      // 核验 DirectoryScanner：本地源开启 detectLocalCovers 能识别 poster.jpg，远程源关闭时不扫描任何封面
      final gateway = LocalSourceGateway(rootPath: tempRoot.path);
      const scanner = DirectoryScanner();
      final localScan = await scanner.scan(gateway, detectLocalCovers: true);
      expect(
        localScan.localCoverByFolder['Indie Short (2024)'],
        'Indie Short (2024)/poster.jpg',
      );
      final remoteScan = await scanner.scan(gateway, detectLocalCovers: false);
      expect(remoteScan.localCoverByFolder, isEmpty);

      // 核验拆簇不继承父合集根目录 folder.jpg
      final splitCheck = ScrapeDomainAdapter.groupAndSplitFiles(
        sourceId: 'src_local',
        files: const [
          ScannedFileInput(
            relativePath: 'Collection/Season 1/[Sub] Show A [01].mkv',
            fileName: '[Sub] Show A [01].mkv',
            fileSize: 100,
            assetKind: AssetKind.video,
          ),
          ScannedFileInput(
            relativePath: 'Collection/Movie/[Sub] Show Movie.mkv',
            fileName: '[Sub] Show Movie.mkv',
            fileSize: 200,
            assetKind: AssetKind.video,
          ),
        ],
        localCoverByFolder: const {
          'Collection': r'D:\Anime\Collection\folder.jpg',
        },
      );
      for (final g in splitCheck) {
        if (g.isSplitCluster) {
          expect(g.localPosterPath, isNull);
        }
      }

      // 端到端 ScrapeOrchestrator 扫库验证：无 TMDB 匹配下 Bangumi OVA 与本地封面作品独立上墙，纯特典保持非 matched
      final db = KonataDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final repo = DriftLibraryRepository(db);
      final localSource = MediaSource(
        id: 'src_local_test',
        kind: MediaSourceKind.local,
        label: '本地番剧库',
        location: tempRoot.path,
      );
      await repo.upsertMediaSource(localSource);

      final mockHttp = MockClient((request) async {
        final uriStr = request.url.toString();
        if (uriStr.contains('api.bgm.tv') && uriStr.contains('/search/subjects')) {
          final body = request.body;
          if (body.contains('Mystic OVA')) {
            return http.Response.bytes(
              utf8.encode(
                jsonEncode({
                  'data': [
                    {
                      'id': 88001,
                      'type': 2,
                      'name': 'Mystic OVA',
                      'name_cn': '神秘 OVA',
                      'date': '2025-05-01',
                      'eps': 1,
                      'rating': {'score': 8.1},
                      'summary': '独立 OVA 简介',
                      'images': {
                        'large': 'https://lain.bgm.tv/pic/cover/l/mystic_ova.jpg',
                      },
                    },
                  ],
                }),
              ),
              200,
              headers: const {'content-type': 'application/json; charset=utf-8'},
            );
          }
          return http.Response('{"data":[]}', 200);
        }
        if (uriStr.contains('api.bgm.tv') && uriStr.contains('/episodes')) {
          return http.Response(
            jsonEncode({
              'data': [
                {'id': 1, 'type': 0, 'sort': 1, 'ep': 1, 'name_cn': '序章 OVA'},
              ],
            }),
            200,
          );
        }
        return http.Response('{"results":[]}', 200);
      });

      final client = TmdbHttpClient(
        config: const TmdbNetworkConfig(credential: ''),
        scheduler: PriorityHttpScheduler(maxRetries: 0),
        httpClient: mockHttp,
      );
      final orchestrator = ScrapeOrchestrator(
        repository: repo,
        tmdbService: TmdbService(httpClient: client),
        bangumiService: BangumiService(httpClient: client),
        gatewayBuilder: (s) async => LocalSourceGateway(rootPath: s.location),
        computeWorker: const ScrapeComputeWorker(useIsolate: false),
      );

      await orchestrator.scanAndScrapeSource(localSource);
      final works = await repo.getAllWorks();
      final indie = works.firstWhere((w) => w.title.contains('Indie Short'));
      final bgmOva = works.firstWhere((w) => w.bangumiId == 88001);
      final extraOnly = works.firstWhere((w) => w.title.contains('Only Extras'));

      expect(indie.scrapeStatus, ScrapeStatus.matched);
      expect(indie.posterPath, endsWith('poster.jpg'));
      expect(bgmOva.scrapeStatus, ScrapeStatus.matched);
      expect(bgmOva.tmdbId, isNull);
      expect(bgmOva.posterPath, contains('mystic_ova.jpg'));
      expect(extraOnly.scrapeStatus, isNot(ScrapeStatus.matched));

      // 模拟跨源同作品角标：若同一 Bangumi OVA 在 WebDAV 源再入库一张卡，两者均显示对应来源角标
      const webdavItem = WorkLibraryItem(
        work: Work(
          id: 'w_dav_ova',
          title: '神秘 OVA',
          bangumiId: 88001,
          scrapeStatus: ScrapeStatus.matched,
        ),
        variants: [],
        episodeCount: 1,
        releaseGroups: [],
        sourceIds: ['src_webdav'],
        primarySourceKind: MediaSourceKind.webdav,
        primarySourceLabel: 'NAS',
      );
      final localItem = WorkLibraryItem(
        work: bgmOva,
        variants: const [],
        episodeCount: 1,
        releaseGroups: const [],
        sourceIds: const ['src_local_test'],
        primarySourceKind: MediaSourceKind.local,
        primarySourceLabel: '本地番剧库',
      );
      final indieItem = WorkLibraryItem(
        work: indie,
        variants: const [],
        episodeCount: 1,
        releaseGroups: const [],
        sourceIds: const ['src_local_test'],
        primarySourceKind: MediaSourceKind.local,
        primarySourceLabel: '本地番剧库',
      );
      final annotated = annotateCrossSourceBadges([
        localItem,
        webdavItem,
        indieItem,
      ]);
      expect(annotated[0].crossSourceBadgeLabel, '本地');
      expect(annotated[1].crossSourceBadgeLabel, 'WebDAV');
      expect(annotated[2].crossSourceBadgeLabel, isNull);
    });
  });
}
