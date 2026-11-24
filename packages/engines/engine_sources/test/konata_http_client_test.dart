import 'dart:async';
import 'dart:io';

import 'package:engine_sources/engine_sources.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:test/test.dart';

void main() {
  group('PriorityHttpScheduler 优先级隔离、分域分桶与限流退避', () {
    test('前台请求不等待后台分桶并发上限', () async {
      final scheduler = PriorityHttpScheduler(
        interactiveConcurrency: 4,
        backgroundConcurrency: 2,
        backgroundBucketConcurrency: const <String, int>{'tmdb': 1},
      );
      expect(scheduler.concurrencyLimitForBucket('tmdb'), 1);
      expect(scheduler.concurrencyLimitForBucket('unknown'), 2);

      final gate = Completer<void>();
      final bgStarted = Completer<void>();
      final bgFuture = scheduler.schedule<String>(
        RequestPriority.background,
        () async {
          bgStarted.complete();
          await gate.future;
          return 'bg';
        },
        bucketKey: 'tmdb',
      );
      await bgStarted.future;
      expect(scheduler.backgroundActiveCount, 1);

      final fgResult = await scheduler.schedule<String>(
        RequestPriority.interactive,
        () async {
          expect(scheduler.interactiveActiveCount, 1);
          return 'fg';
        },
      );
      expect(fgResult, 'fg');

      gate.complete();
      expect(await bgFuture, 'bg');
      expect(scheduler.backgroundActiveCount, 0);
    });

    test('后台同 dedupeKey 在途去重合并，429 按 Retry-After 退避重试，日额度耗尽立即上抛', () async {
      final scheduler = PriorityHttpScheduler(maxRetries: 2);
      var sharedCount = 0;
      final gate = Completer<void>();

      final f1 = scheduler.schedule<int>(
        RequestPriority.background,
        () async {
          sharedCount += 1;
          await gate.future;
          return sharedCount;
        },
        dedupeKey: 'k1',
      );
      final f2 = scheduler.schedule<int>(
        RequestPriority.background,
        () async {
          sharedCount += 1;
          return sharedCount;
        },
        dedupeKey: 'k1',
      );
      gate.complete();
      expect(await Future.wait(<Future<int>>[f1, f2]), <int>[1, 1]);
      expect(sharedCount, 1);

      var attempts = 0;
      final retried = await scheduler.schedule<String>(
        RequestPriority.background,
        () async {
          attempts += 1;
          if (attempts == 1) {
            throw const RateLimitedHttpException(
              Duration(milliseconds: 20),
              'HTTP 429',
            );
          }
          return 'ok';
        },
        bucketKey: 'bangumi',
      );
      expect(retried, 'ok');
      expect(attempts, 2);

      var quotaAttempts = 0;
      await expectLater(
        scheduler.schedule<String>(
          RequestPriority.background,
          () async {
            quotaAttempts += 1;
            throw const RateLimitedHttpException(
              Duration(seconds: 1),
              'HTTP 429',
              <String, String>{},
              '1027',
              true,
            );
          },
          bucketKey: 'fanart',
        ),
        throwsA(
          isA<RateLimitedHttpException>().having(
            (e) => e.isQuotaExhausted,
            'isQuotaExhausted',
            isTrue,
          ),
        ),
      );
      expect(quotaAttempts, 1);
    });
  });

  group('KonataHttpClient 主备回退、域名冷却与统一响应', () {
    test('主链路网络异常自动切换备用并进入冷却，备用连续 5xx 解除冷却，配置变更清空冷却', () async {
      var now = DateTime.utc(2026, 11, 24, 12, 0, 0);
      final requestedHosts = <String>[];
      var failPrimary = true;
      var backupStatus = 200;

      final mockClient = MockClient((request) async {
        requestedHosts.add(request.url.host);
        if (request.url.host == 'api.themoviedb.org') {
          if (failPrimary) {
            throw const SocketException('主站超时不可达');
          }
          return http.Response('{"ok":true,"from":"primary"}', 200);
        }
        return http.Response('{"ok":true,"from":"backup"}', backupStatus);
      });

      final TmdbHttpClient client = KonataHttpClient(
        config: const KonataNetworkConfig(credential: 'v3_secret_key'),
        httpClient: mockClient,
        nowProvider: () => now,
      );

      final primaryUri = Uri.parse('https://api.themoviedb.org/3/tv/1');
      final backupUri = Uri.parse('https://api.tmdb.org/3/tv/1');

      // 1. 首次请求主站抛错 -> 回退备用成功，并标记主域名冷却。
      final r1 = await client.getWithFallback(primaryUri, backupUri: backupUri);
      expect(r1, isA<KonataHttpResponse>());
      expect(r1.statusCode, 200);
      expect(r1.body, contains('backup'));
      expect(requestedHosts, <String>['api.themoviedb.org', 'api.tmdb.org']);
      expect(client.cooldownRegistry.isCoolingDown('api.themoviedb.org', now), isTrue);

      // 2. 冷却窗口内直接走备用，不浪费时间探测主站。
      requestedHosts.clear();
      final r2 = await client.getWithFallback(primaryUri, backupUri: backupUri);
      expect(r2.body, contains('backup'));
      expect(requestedHosts, <String>['api.tmdb.org']);

      // 3. 备用连续返回 3 次 502 后自动解除主站冷却，第四次重新探活主站。
      backupStatus = 502;
      failPrimary = false;
      for (var i = 0; i < DomainCooldownRegistry.backupErrorStreakToUnblock; i++) {
        await client.getWithFallback(
          primaryUri,
          backupUri: backupUri,
          dedupeKey: 'streak_$i',
        );
      }
      expect(
        client.cooldownRegistry.isCoolingDown('api.themoviedb.org', now),
        isFalse,
      );

      requestedHosts.clear();
      final rRecovered = await client.getWithFallback(
        primaryUri,
        backupUri: backupUri,
        dedupeKey: 'recovered',
      );
      expect(rRecovered.body, contains('primary'));
      expect(requestedHosts, <String>['api.themoviedb.org']);

      // 4. 冷却过期或 updateConfig 会重置冷却表。
      client.cooldownRegistry.markBlocked('api.themoviedb.org', now);
      now = now.add(const Duration(minutes: 11));
      expect(
        client.cooldownRegistry.isCoolingDown('api.themoviedb.org', now),
        isFalse,
      );
      client.cooldownRegistry.markBlocked('api.themoviedb.org', now);
      client.updateConfig(const KonataNetworkConfig(proxyMode: ProxyMode.none));
      expect(
        client.cooldownRegistry.isCoolingDown('api.themoviedb.org', now),
        isFalse,
      );
      client.close();
    });

    test('支持 POST 主备回退、429 额度识别与连通性测试报告', () async {
      final mockClient = MockClient((request) async {
        if (request.method == 'POST' && request.url.host == 'primary.invalid') {
          return http.Response('err', 503);
        }
        if (request.method == 'POST' && request.url.host == 'backup.valid') {
          return http.Response('{"created":true}', 201);
        }
        if (request.url.path.endsWith('/configuration')) {
          return http.Response('{"images":{}}', 200);
        }
        if (request.url.path.contains('/fanart/')) {
          return http.Response(
            '<html>cf 1027</html>',
            429,
            headers: const <String, String>{
              'content-type': 'text/html',
              'retry-after': '5',
            },
          );
        }
        return http.Response('{}', 404);
      });

      final client = KonataHttpClient(
        config: const KonataNetworkConfig(credential: 'test_key'),
        httpClient: mockClient,
      );

      final postRes = await client.postWithFallback(
        Uri.parse('https://primary.invalid/search'),
        backupUri: Uri.parse('https://backup.valid/search'),
        body: '{"q":"konata"}',
      );
      expect(postRes.statusCode, 201);
      expect(postRes.body, contains('created'));

      final report = await client.testTmdbApiConnectivity();
      expect(report.reachable, isTrue);
      expect(report.usedBackup, isFalse);
      expect(report.displayText, contains('官方直连成功'));

      final fanartReport = await client.testFanartApiConnectivity();
      expect(fanartReport.reachable, isFalse);
      expect(fanartReport.displayText, contains('额度'));
      client.close();
    });
  });
}
