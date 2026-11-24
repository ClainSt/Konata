import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:engine_scraping/engine_scraping.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

import '../support/test_helpers.dart';

http.Response _jsonResponse(Object data, [int statusCode = 200]) {
  return http.Response.bytes(
    utf8.encode(jsonEncode(data)),
    statusCode,
    headers: const {'content-type': 'application/json; charset=utf-8'},
  );
}

void main() {
  group('TmdbService & PriorityHttpScheduler', () {
    test('自动识别 v3 API Key 并附加 api_key 查询参数', () async {
      Uri? capturedUri;
      String? capturedAuth;

      final mockClient = MockClient((request) async {
        capturedUri = request.url;
        capturedAuth = request.headers[HttpHeaders.authorizationHeader];
        return _jsonResponse({
          'results': [
            {
              'id': 209867,
              'name': '葬送的芙莉莲',
              'original_name': '葬送のフリーレン',
              'first_air_date': '2023-09-29',
              'poster_path': '/frieren.jpg',
            },
          ],
        });
      });

      final service = TmdbService(
        httpClient: TmdbHttpClient(
          config: const TmdbNetworkConfig(credential: 'v3_test_key_12345'),
          scheduler: PriorityHttpScheduler(),
          httpClient: mockClient,
        ),
      );

      final results = await service.searchAnime('葬送的芙莉莲');
      expect(results, hasLength(2)); // tv + movie 两条并发结果合并
      expect(capturedUri?.queryParameters['api_key'], 'v3_test_key_12345');
      expect(capturedAuth, isNull);
    });

    test('自动识别 eyJ 开头 v4 Bearer Token 并解析详情与别名', () async {
      String? capturedAuth;

      final mockClient = MockClient((request) async {
        capturedAuth = request.headers[HttpHeaders.authorizationHeader];
        if (request.url.path.endsWith('/tv/209867')) {
          return _jsonResponse({
            'id': 209867,
            'name': '葬送的芙莉莲',
            'original_name': '葬送のフリーレン',
            'first_air_date': '2023-09-29',
            'overview': '勇者一行打倒魔王之后的故事。',
            'poster_path': '/poster.jpg',
            'backdrop_path': '/backdrop.jpg',
            'seasons': [
              {'season_number': 1, 'name': '第 1 季', 'episode_count': 28},
            ],
            'alternative_titles': {
              'results': [
                {'title': "Frieren: Beyond Journey's End"},
              ],
            },
            'translations': {
              'translations': [
                {
                  'iso_639_1': 'zh',
                  'data': {'name': '葬送的芙莉蓮'},
                },
              ],
            },
          });
        }
        return http.Response('{}', 404);
      });

      final service = TmdbService(
        httpClient: TmdbHttpClient(
          config: const TmdbNetworkConfig(
            credential: 'eyJhbGciOiJIUzI1NiJ9.payload.sig',
          ),
          scheduler: PriorityHttpScheduler(),
          httpClient: mockClient,
        ),
      );

      final detail = await service.getWorkDetail(209867, TmdbMediaType.tv);
      expect(capturedAuth, 'Bearer eyJhbGciOiJIUzI1NiJ9.payload.sig');
      expect(detail, isNotNull);
      expect(detail!.title, '葬送的芙莉莲');
      expect(detail.originalTitle, '葬送のフリーレン');
      expect(detail.year, 2023);
      expect(detail.aliases, contains("Frieren: Beyond Journey's End"));
      expect(detail.aliases, contains('葬送的芙莉蓮'));
      expect(detail.seasons.single.episodeCount, 28);
    });

    test('双通道并发隔离：Background 队列受限流且同 URL 去重，Interactive 立即调度', () async {
      final scheduler = PriorityHttpScheduler(
        interactiveConcurrency: 4,
        backgroundConcurrency: 1,
      );

      final gate = Completer<void>();
      var bgCalls = 0;

      // 占满唯一的 Background 槽位，同时测试相同 dedupeKey 合并去重
      final f1 = scheduler.schedule<int>(
        RequestPriority.background,
        () async {
          bgCalls++;
          await gate.future;
          return 1;
        },
        dedupeKey: 'same_url',
      );
      final f2 = scheduler.schedule<int>(
        RequestPriority.background,
        () async {
          bgCalls++;
          return 2;
        },
        dedupeKey: 'same_url',
      );

      // 此时 Background 队列已满，但 Interactive 通道必须能立即完成
      final interactiveResult = await scheduler.schedule<String>(
        RequestPriority.interactive,
        () async => 'fast_ui',
      );
      expect(interactiveResult, 'fast_ui');

      gate.complete();
      expect(await f1, 1);
      expect(await f2, 1);
      expect(bgCalls, 1);
    });

    test('支持 HTTP 429 Retry-After 指数退避重试与图片缓存写入', () async {
      var attempts = 0;
      final tempDir = await Directory.systemTemp.createTemp('konata_img_test_');
      final cache = TestArtworkCacheStore(tempDir);
      addTearDown(() async {
        cache.close();
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      });

      final mockClient = MockClient((request) async {
        if (request.url.path.contains('/tv/100/season/1')) {
          attempts++;
          if (attempts == 1) {
            return http.Response(
              'rate limited',
              429,
              headers: {'retry-after': '0'},
            );
          }
          return _jsonResponse({
            'episodes': [
              {'episode_number': 1, 'name': '冒险的终点', 'overview': '简介'},
            ],
          });
        }
        return http.Response.bytes([1, 2, 3, 4], 200);
      });

      final service = TmdbService(
        httpClient: TmdbHttpClient(
          config: const TmdbNetworkConfig(credential: 'v3_test'),
          scheduler: PriorityHttpScheduler(),
          httpClient: mockClient,
        ),
        artworkCache: cache,
      );

      final episodes = await service.getSeasonEpisodes(100, 1);
      expect(attempts, 2);
      expect(episodes.single.title, '冒险的终点');

      final bytes = await service.fetchImageBytes(
        '/demo.jpg',
        ownerWorkId: 'w1',
      );
      expect(bytes, [1, 2, 3, 4]);
    });

    test('官方接口超时/阻断时自动回退备用地址并进入10分钟冷却期', () async {
      final requestedHosts = <String>[];
      var fakeNow = DateTime(2026, 11, 15, 18, 0);
      final cooldown = DomainCooldownRegistry(
        cooldownDuration: const Duration(minutes: 10),
      );

      final mockClient = MockClient((request) async {
        requestedHosts.add('${request.url.host}${request.url.path}');
        if (request.url.host == 'api.themoviedb.org') {
          throw const SocketException('TLS handshake blocked');
        }
        if (request.url.host == 'api.tmdb.org') {
          return _jsonResponse({'results': <Map<String, Object?>>[]});
        }
        if (request.url.host == 'image.tmdb.org') {
          throw TimeoutException('official image timeout');
        }
        if (request.url.host == 'images.tmdb.org') {
          return http.Response.bytes([9, 8, 7], 200);
        }
        return http.Response('not found', 404);
      });

      final client = TmdbHttpClient(
        config: const TmdbNetworkConfig(credential: 'v3_test'),
        scheduler: PriorityHttpScheduler(),
        httpClient: mockClient,
        cooldownRegistry: cooldown,
        nowProvider: () => fakeNow,
      );
      final service = TmdbService(httpClient: client);

      // 首次检索：先尝官方，失败后回退 api.tmdb.org，同时写入冷却表
      await service.searchAnime('Frieren');
      expect(
        requestedHosts.where((h) => h.startsWith('api.tmdb.org/')),
        isNotEmpty,
      );
      expect(cooldown.isCoolingDown('api.themoviedb.org', fakeNow), isTrue);

      requestedHosts.clear();
      // 冷却窗口内（5分钟后）发起图片请求：首次先失败回退 images.tmdb.org，随后 6 分钟内第二张图直接走备用域名不再等官方超时
      fakeNow = fakeNow.add(const Duration(minutes: 5));
      expect(await service.fetchImageBytes('/p1.jpg'), [9, 8, 7]);
      expect(await service.fetchImageBytes('/p2.jpg'), [9, 8, 7]);
      final imagePrimaryHits = requestedHosts
          .where((h) => h.startsWith('image.tmdb.org'))
          .length;
      final imageBackupHits = requestedHosts
          .where((h) => h.startsWith('images.tmdb.org'))
          .length;
      expect(imagePrimaryHits, 1, reason: '冷却期内第二张图片应直接命中备用域名');
      expect(imageBackupHits, 2);

      // 连通性测试：官方受阻时自动回退备用地址并返回明确提示
      final apiProbe = await client.testTmdbApiConnectivity();
      expect(apiProbe.reachable, isTrue);
      expect(apiProbe.usedBackup, isTrue);
      expect(apiProbe.displayText, contains('已自动回退备用地址连通'));
    });

    test('备用链路瞬态握手异常自动重试一次且不因单次异常过早清除主域名冷却', () async {
      final requestedHosts = <String>[];
      final fakeNow = DateTime(2026, 11, 23, 5, 45);
      final cooldown = DomainCooldownRegistry(
        cooldownDuration: const Duration(minutes: 10),
      )..markBlocked('api.themoviedb.org', fakeNow);

      var backupCalls = 0;
      final mockClient = MockClient((request) async {
        requestedHosts.add(request.url.host);
        if (request.url.host == 'api.tmdb.org') {
          backupCalls++;
          if (backupCalls == 1) {
            throw const HandshakeException('Connection terminated during handshake');
          }
          if (backupCalls == 2) {
            return _jsonResponse({'results': <Map<String, Object?>>[]});
          }
          throw const HandshakeException('still flaky');
        }
        return _jsonResponse({'results': <Map<String, Object?>>[]});
      });

      final client = TmdbHttpClient(
        config: const TmdbNetworkConfig(credential: 'v3_test'),
        scheduler: PriorityHttpScheduler(),
        httpClient: mockClient,
        cooldownRegistry: cooldown,
        maxTransientTransportRetries: 1,
        transientRetryDelay: Duration.zero,
        nowProvider: () => fakeNow,
      );

      // 第 1 次请求：备用首次握手异常自动重试一次即成功，全程零打扰主域名
      final okResp = await client.getWithFallback(
        Uri.parse('https://api.themoviedb.org/3/search/tv?query=test'),
        backupUri: Uri.parse('https://api.tmdb.org/3/search/tv?query=test'),
      );
      expect(okResp.statusCode, 200);
      expect(backupCalls, 2);
      expect(requestedHosts, everyElement('api.tmdb.org'));
      expect(cooldown.isCoolingDown('api.themoviedb.org', fakeNow), isTrue);

      // 第 2 次请求：备用两次握手失败后抛出，但主域名冷却需连续 3 次失败才解除，单次失败不立刻解除
      await expectLater(
        client.getWithFallback(
          Uri.parse('https://api.themoviedb.org/3/search/tv?query=fail1'),
          backupUri: Uri.parse('https://api.tmdb.org/3/search/tv?query=fail1'),
        ),
        throwsA(isA<HandshakeException>()),
      );
      expect(cooldown.isCoolingDown('api.themoviedb.org', fakeNow), isTrue);
    });

    test('PriorityHttpScheduler 排队等待槽位的请求在 429 冷却后才发包，且支持 retryOnRateLimit=false 立即熔断', () async {
      final scheduler = PriorityHttpScheduler(
        backgroundConcurrency: 1,
        maxRetries: 2,
      );
      final events = <String>[];
      DateTime? secondStartedAt;
      DateTime? rateLimitedAt;

      final first = scheduler.schedule<String>(
        RequestPriority.background,
        () async {
          if (rateLimitedAt == null) {
            rateLimitedAt = DateTime.now();
            events.add('first_429');
            throw const RateLimitedHttpException(Duration(milliseconds: 220));
          }
          events.add('first_ok');
          return 'ok1';
        },
        bucketKey: 'test_bucket',
      );
      // 第二个请求在首个请求触发 429 前已进入等待队列，放行时必须遵守新写入的冷却窗口
      final second = scheduler.schedule<String>(
        RequestPriority.background,
        () async {
          secondStartedAt = DateTime.now();
          events.add('second_ok');
          return 'ok2';
        },
        bucketKey: 'test_bucket',
      );

      expect(await first, 'ok1');
      expect(await second, 'ok2');
      expect(rateLimitedAt, isNotNull);
      expect(secondStartedAt, isNotNull);
      expect(
        secondStartedAt!.difference(rateLimitedAt!).inMilliseconds,
        greaterThanOrEqualTo(180),
        reason: '队列中已有待发请求也必须等待 429 冷却结束再发包',
      );

      // retryOnRateLimit=false 应首次 429 即直接上抛，不触发退避休眠
      var fastFailCalls = 0;
      final sw = Stopwatch()..start();
      await expectLater(
        scheduler.schedule<void>(
          RequestPriority.background,
          () async {
            fastFailCalls++;
            throw const RateLimitedHttpException(Duration(seconds: 30));
          },
          bucketKey: 'fast_fail_bucket',
          retryOnRateLimit: false,
        ),
        throwsA(isA<RateLimitedHttpException>()),
      );
      sw.stop();
      expect(fastFailCalls, 1);
      expect(sw.elapsedMilliseconds, lessThan(200));
    });
  });
}
