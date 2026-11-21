import 'dart:convert';

import 'package:ccplayer/application/scraping/clear_logo_resolver.dart';
import 'package:ccplayer/domain/formatting/network_error_sanitizer.dart';
import 'package:ccplayer/domain/models/fanart_models.dart';
import 'package:ccplayer/domain/models/network_config.dart';
import 'package:ccplayer/domain/models/work.dart';
import 'package:ccplayer/domain/scraping/bangumi_tmdb_index.dart';
import 'package:ccplayer/infrastructure/database/drift_library_repository.dart';
import 'package:ccplayer/infrastructure/database/konata_database.dart';
import 'package:ccplayer/infrastructure/network/fanart_service.dart';
import 'package:ccplayer/infrastructure/network/priority_http_scheduler.dart';
import 'package:ccplayer/infrastructure/network/tmdb_http_client.dart';
import 'package:ccplayer/infrastructure/network/tmdb_service.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

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

      // 1. 频率限流
      final rateLimitClient = TmdbHttpClient(
        config: const TmdbNetworkConfig(
          fanartBackupApiBase: 'https://relay.konata.example',
        ),
        scheduler: PriorityHttpScheduler(maxRetries: 0),
        httpClient: MockClient(
          (_) async => http.Response(
            '{"error":"rate_limited","retryAfter":60}',
            429,
            headers: const {
              'content-type': 'application/json',
              'x-konata-relay-error': 'rate_limited',
              'retry-after': '60',
            },
          ),
        ),
      );
      final svc1 = FanartService(
        httpClient: rateLimitClient,
        circuitBreaker: breaker,
        nowProvider: () => now,
      );
      final res1 = await svc1.fetchLogos(
        mediaType: TmdbMediaType.movie,
        tmdbId: 129,
      );
      expect(res1.authRejected, isTrue);
      expect(breaker.snapshot(now).status, FanartRelayStatus.rateLimited);

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
    });
  });
}
