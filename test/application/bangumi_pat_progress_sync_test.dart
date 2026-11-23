import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:konata/application/providers/bangumi_sync_providers.dart';
import 'package:konata/application/providers/diagnostics_providers.dart';
import 'package:konata/application/providers/library_providers.dart';
import 'package:konata/application/sync/bangumi_progress_sync_service.dart';
import 'package:konata/domain/models/episode.dart';
import 'package:konata/domain/models/media_source.dart';
import 'package:konata/domain/models/media_variant.dart';
import 'package:konata/domain/models/network_config.dart';
import 'package:konata/domain/models/playback_record.dart';
import 'package:konata/domain/models/work.dart';
import 'package:konata/domain/sync/bangumi_sync_models.dart';
import 'package:konata/infrastructure/database/drift_library_repository.dart';
import 'package:konata/infrastructure/database/konata_database.dart';
import 'package:konata/infrastructure/logging/diagnostics_log_store.dart';
import 'package:konata/infrastructure/network/bangumi_sync_client.dart';
import 'package:konata/infrastructure/network/tmdb_http_client.dart';
import 'package:konata/infrastructure/sync/konata_sync_store.dart';
import 'package:konata/presentation/settings/settings_bangumi_sync_card.dart';
import 'package:konata/presentation/theme/konata_theme.dart';

Future<void> _seedBangumiWork({
  required DriftLibraryRepository repo,
  required String workId,
  required int bangumiId,
  required String title,
  int epCount = 3,
}) async {
  await repo.upsertMediaSource(
    MediaSource(
      id: 'src_local',
      kind: MediaSourceKind.local,
      label: '本地',
      location: r'D:\Anime',
      createdAt: DateTime(2026, 1, 1),
    ),
  );
  await repo.upsertWork(
    Work(
      id: workId,
      bangumiId: bangumiId,
      title: title,
      scrapeStatus: ScrapeStatus.matched,
    ),
  );
  for (var i = 1; i <= epCount; i++) {
    final epId = '${workId}_e$i';
    await repo.upsertEpisode(
      Episode(
        id: epId,
        workId: workId,
        seasonNumber: 1,
        episodeNumber: i,
        category: EpisodeCategory.main,
        title: '第 $i 话',
      ),
    );
    await repo.upsertMediaVariant(
      MediaVariant(
        id: '${workId}_v$i',
        workId: workId,
        episodeId: epId,
        sourceId: 'src_local',
        relativePath: '$title/0$i.mkv',
        fileName: '0$i.mkv',
        fileSize: 1024,
        assetKind: AssetKind.video,
      ),
    );
  }
}

void main() {
  group('Bangumi PAT 观看进度双向同步与离线队列回归', () {
    test('PAT 校验仅直连官方 api.bgm.tv，401 返回中文提示且日志绝不泄露明文令牌', () async {
      final db = KonataDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final repo = DriftLibraryRepository(db);
      final syncStore = KonataSyncStore(db);
      final logStore = DiagnosticsLogStore();

      final requestedHosts = <String>[];
      final mockHttp = MockClient((http.Request req) async {
        requestedHosts.add(req.url.host);
        final auth = req.headers['authorization'] ?? '';
        if (req.url.path.endsWith('/v0/me')) {
          if (auth == 'Bearer valid_pat_secret_123') {
            return http.Response.bytes(
              utf8.encode(
                jsonEncode(<String, Object?>{
                  'id': 88001,
                  'username': 'konata_user',
                  'nickname': '泉此方',
                  'avatar': <String, String>{
                    'medium': 'https://lain.bgm.tv/a.jpg',
                  },
                }),
              ),
              200,
              headers: const <String, String>{
                'content-type': 'application/json; charset=utf-8',
              },
            );
          }
          return http.Response('{"title":"Unauthorized"}', 401);
        }
        return http.Response('Not Found', 404);
      });

      final tmdbHttp = TmdbHttpClient(
        config: const TmdbNetworkConfig(
          bangumiBackupApiBase: 'https://mirror.untrusted.example/v0',
        ),
        httpClient: mockHttp,
      );
      addTearDown(tmdbHttp.close);

      final client = BangumiSyncClient(
        httpClient: tmdbHttp,
        logStore: logStore,
      );
      final service = BangumiProgressSyncService(
        repository: repo,
        syncStore: syncStore,
        client: client,
        logStore: logStore,
      );

      // 1. 错误令牌抛出 BangumiAuthException
      await expectLater(
        () => service.verifyAndCacheProfile('invalid_pat_secret_999'),
        throwsA(isA<BangumiAuthException>()),
      );

      // 2. 合法令牌成功并缓存公开资料
      final profile = await service.verifyAndCacheProfile(
        'valid_pat_secret_123',
      );
      expect(profile.username, 'konata_user');
      expect(profile.displayLabel, '泉此方 (@konata_user)');
      expect((await service.readCachedProfile())?.id, 88001);

      // 3. 绝不向第三方社区镜像转发 PAT
      expect(requestedHosts, everyElement('api.bgm.tv'));

      // 4. 诊断日志绝不泄露任何 PAT
      final diag = logStore.buildRecentIncidentReport();
      expect(diag, isNot(contains('valid_pat_secret_123')));
      expect(diag, isNot(contains('invalid_pat_secret_999')));
      expect(diag, contains('BGM_AUTH_401'));
    });

    test('双向同步：拉取远端已看、单次批量 PATCH 上报本地已看、全集看完自动升档为「看过」', () async {
      final db = KonataDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final repo = DriftLibraryRepository(db);
      final syncStore = KonataSyncStore(db);
      final logStore = DiagnosticsLogStore();

      await _seedBangumiWork(
        repo: repo,
        workId: 'w_86',
        bangumiId: 302189,
        title: '86 -不存在的战区-',
        epCount: 3,
      );

      // 本地已看第 2、3 话；远端已看第 1 话
      for (final epNum in <int>[2, 3]) {
        await repo.recordPlayback(
          PlaybackRecord(
            id: 'w_86::w_86_e$epNum',
            workId: 'w_86',
            episodeId: 'w_86_e$epNum',
            variantId: 'w_86_v$epNum',
            seasonNumber: 1,
            episodeNumber: epNum,
            episodeTitle: '第 $epNum 话',
            sourceType: MediaSourceKind.local,
            playedAt: DateTime(2026, 11, 22, 20, epNum),
            positionSeconds: 1400,
            durationSeconds: 1420,
            isCompleted: true,
          ),
        );
      }

      final patchedBatches = <List<int>>[];
      final collectionPostTypes = <int>[];
      final epStatus = <int, int>{1001: 2, 1002: 0, 1003: 0};

      final mockHttp = MockClient((http.Request req) async {
        expect(req.headers['authorization'], 'Bearer pat_sync_test');
        if (req.method == 'GET' &&
            req.url.path == '/v0/users/-/collections/302189/episodes') {
          return http.Response.bytes(
            utf8.encode(
              jsonEncode(<String, Object?>{
                'total': 3,
                'data': <Map<String, Object?>>[
                  for (var i = 1; i <= 3; i++)
                    <String, Object?>{
                      'type': epStatus[1000 + i],
                      'episode': <String, Object?>{
                        'id': 1000 + i,
                        'type': 0,
                        'sort': i,
                        'ep': i,
                        'name': 'Ep $i',
                        'name_cn': '第 $i 话',
                      },
                    },
                ],
              }),
            ),
            200,
            headers: const <String, String>{
              'content-type': 'application/json; charset=utf-8',
            },
          );
        }
        if (req.method == 'PATCH' &&
            req.url.path == '/v0/users/-/collections/302189/episodes') {
          final body = jsonDecode(req.body) as Map<String, Object?>;
          final ids = [
            for (final id in (body['episode_id'] as List)) (id as num).toInt(),
          ];
          patchedBatches.add(ids);
          for (final id in ids) {
            epStatus[id] = (body['type'] as num).toInt();
          }
          return http.Response('', 204);
        }
        if (req.method == 'POST' &&
            req.url.path == '/v0/users/-/collections/302189') {
          final body = jsonDecode(req.body) as Map<String, Object?>;
          collectionPostTypes.add((body['type'] as num).toInt());
          return http.Response('', 202);
        }
        return http.Response('Not Found', 404);
      });

      final tmdbHttp = TmdbHttpClient(
        config: const TmdbNetworkConfig(),
        httpClient: mockHttp,
      );
      addTearDown(tmdbHttp.close);
      final service = BangumiProgressSyncService(
        repository: repo,
        syncStore: syncStore,
        client: BangumiSyncClient(httpClient: tmdbHttp, logStore: logStore),
        logStore: logStore,
      );

      const cfg = BangumiSyncConfig(
        enabled: true,
        personalAccessToken: 'pat_sync_test',
        syncMode: BangumiSyncMode.bidirectional,
        autoMarkSubjectCompleted: true,
      );

      final result = await service.syncWork(config: cfg, workId: 'w_86');
      expect(result.isSuccess, isTrue);
      expect(result.pulledWatchedCount, 1);
      expect(result.pushedWatchedCount, 2);
      expect(result.promotedCollectionTo, BangumiCollectionType.collect);

      // 确认只发了 1 次批量 PATCH 合并第 2、3 话，且自动将条目标记为「看过(2)」
      expect(patchedBatches.length, 1);
      expect(patchedBatches.single, <int>[1002, 1003]);
      expect(collectionPostTypes, <int>[BangumiCollectionType.collect]);

      // 确认本地第 1 话已补齐为 isCompleted = true
      final localAfter = await repo.getPlaybacksByWork('w_86');
      final ep1Rec = localAfter.firstWhere((r) => r.episodeNumber == 1);
      expect(ep1Rec.isCompleted, isTrue);
    });

    test('离线完播自动入队重试：断网保留队列并退避，网络恢复后自动补发并清空队列', () async {
      final db = KonataDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final repo = DriftLibraryRepository(db);
      final syncStore = KonataSyncStore(db);
      final logStore = DiagnosticsLogStore();

      await _seedBangumiWork(
        repo: repo,
        workId: 'w_k_on',
        bangumiId: 1424,
        title: '轻音少女',
        epCount: 2,
      );

      var offline = true;
      var collected = false;
      final patchedIds = <int>[];

      final mockHttp = MockClient((http.Request req) async {
        if (offline) {
          throw const SocketException('Network unreachable');
        }
        if (req.method == 'GET' &&
            req.url.path == '/v0/users/-/collections/1424/episodes') {
          if (!collected) return http.Response('Not Found', 404);
          return http.Response(
            jsonEncode(<String, Object?>{
              'total': 2,
              'data': <Map<String, Object?>>[
                <String, Object?>{
                  'type': 0,
                  'episode': <String, Object?>{
                    'id': 5001,
                    'type': 0,
                    'sort': 1,
                    'ep': 1,
                  },
                },
                <String, Object?>{
                  'type': 0,
                  'episode': <String, Object?>{
                    'id': 5002,
                    'type': 0,
                    'sort': 2,
                    'ep': 2,
                  },
                },
              ],
            }),
            200,
          );
        }
        if (req.method == 'POST' &&
            req.url.path == '/v0/users/-/collections/1424') {
          collected = true;
          return http.Response('', 202);
        }
        if (req.method == 'PATCH' &&
            req.url.path == '/v0/users/-/collections/1424/episodes') {
          final body = jsonDecode(req.body) as Map<String, Object?>;
          patchedIds.addAll(
            (body['episode_id'] as List).map((e) => (e as num).toInt()),
          );
          return http.Response('', 204);
        }
        return http.Response('Not Found', 404);
      });

      final tmdbHttp = TmdbHttpClient(
        config: const TmdbNetworkConfig(),
        httpClient: mockHttp,
      );
      addTearDown(tmdbHttp.close);
      final service = BangumiProgressSyncService(
        repository: repo,
        syncStore: syncStore,
        client: BangumiSyncClient(httpClient: tmdbHttp, logStore: logStore),
        logStore: logStore,
      );

      const cfg = BangumiSyncConfig(
        enabled: true,
        personalAccessToken: 'pat_offline_test',
        autoPushOnComplete: true,
      );

      final work = (await repo.findWorkById('w_k_on'))!;
      final ep1 = (await repo.getEpisodesByWork('w_k_on')).first;

      // 断网时完播上报：不抛错，留存在 SQLite 离线重试队列中且 retryCount=1
      await service.enqueueEpisodeWatched(config: cfg, work: work, episode: ep1);
      final pending = await syncStore.readBangumiSyncQueue();
      expect(pending.length, 1);
      expect(pending.single.retryCount, 1);
      expect(pending.single.subjectId, 1424);

      // 网络恢复：自动建收藏(在看) + 补发第 1 话 + 清空队列
      offline = false;
      final flushed = await service.flushPendingQueue(cfg, ignoreBackoff: true);
      expect(flushed, 1);
      expect(collected, isTrue);
      expect(patchedIds, <int>[5001]);
      expect(await syncStore.readBangumiSyncQueue(), isEmpty);
    });

    testWidgets('SettingsBangumiSyncCard 渲染与交互正常且无溢出', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final db = KonataDatabase(NativeDatabase.memory());
      addTearDown(db.close);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            libraryRepositoryProvider.overrideWithValue(
              DriftLibraryRepository(db),
            ),
            diagnosticsLogStoreProvider.overrideWithValue(
              DiagnosticsLogStore(),
            ),
            bangumiSyncClientProvider.overrideWithValue(
              BangumiSyncClient(
                httpClient: TmdbHttpClient(
                  config: const TmdbNetworkConfig(),
                  httpClient: MockClient(
                    (_) async => http.Response.bytes(
                      utf8.encode(
                        jsonEncode(<String, Object?>{
                          'id': 1,
                          'username': 'demo',
                          'nickname': '演示账号',
                        }),
                      ),
                      200,
                      headers: const <String, String>{
                        'content-type': 'application/json; charset=utf-8',
                      },
                    ),
                  ),
                ),
              ),
            ),
          ],
          child: MaterialApp(
            theme: KonataTheme.darkTheme(),
            home: const Scaffold(
              body: SingleChildScrollView(child: SettingsBangumiSyncCard()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Bangumi 观看进度同步'), findsOneWidget);
      expect(find.byKey(const ValueKey('settings_bangumi_verify_token')), findsOneWidget);
      expect(find.byKey(const ValueKey('settings_bangumi_sync_all')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
