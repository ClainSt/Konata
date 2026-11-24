import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:feature_tracker_sync/feature_tracker_sync.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';

final class _RecordedLog implements DiagnosticLogPort {
  final List<String> capturedMessages = <String>[];

  @override
  void clear() => capturedMessages.clear();

  @override
  Future<String> buildJsonBundle() async => '{}';

  @override
  Future<String> buildTextReport() async => capturedMessages.join('\n');

  @override
  void logError({
    required DiagnosticSubsystem subsystem,
    required String code,
    required String message,
    required Object error,
    StackTrace? stackTrace,
    DiagnosticSeverity severity = DiagnosticSeverity.error,
    String? source,
    Map<String, Object?> context = const <String, Object?>{},
  }) {
    capturedMessages.add('$code|$message|${error.toString()}|$context');
  }

  @override
  void logEvent({
    required DiagnosticSubsystem subsystem,
    required String code,
    required String message,
    DiagnosticSeverity severity = DiagnosticSeverity.info,
    String? source,
    Map<String, Object?> context = const <String, Object?>{},
    Object? error,
    StackTrace? stackTrace,
  }) {
    capturedMessages.add('$code|$message|${error ?? ''}|$context');
  }

  @override
  void recordBreadcrumb({
    required String category,
    required String label,
    String? source,
    String? detail,
  }) {}

  @override
  void Function() registerSnapshotContributor(
    String sectionId,
    DiagnosticSnapshotContributor contributor,
  ) => () {};

  @override
  void setVerbose(bool enabled) {}

  @override
  List<DiagnosticEvent> snapshotEvents() => const <DiagnosticEvent>[];

  @override
  List<DiagnosticFaultSummary> summarizeFaults() =>
      const <DiagnosticFaultSummary>[];

  @override
  DiagnosticSummaryCounts get summaryCounts => const DiagnosticSummaryCounts(
    totalEvents: 0,
    warningCount: 0,
    errorCount: 0,
    breadcrumbCount: 0,
  );

  @override
  bool get verboseEnabled => false;
}

final class _StubHttpClientPort implements KonataHttpClientPort {
  KonataNetworkConfig _config = const KonataNetworkConfig();

  @override
  KonataNetworkConfig get config => _config;

  @override
  void updateConfig(KonataNetworkConfig next) {
    _config = next;
  }

  @override
  void close() {}

  @override
  Future<KonataHttpResponse> get(
    Uri uri, {
    Map<String, String> headers = const <String, String>{},
    RequestPriority priority = RequestPriority.background,
    String? dedupeKey,
    String? bucketKey,
  }) async => KonataHttpResponse(
    statusCode: 200,
    headers: const <String, String>{},
    bodyBytes: Uint8List(0),
  );

  @override
  Future<KonataHttpResponse> getWithFallback(
    Uri primaryUri, {
    Uri? backupUri,
    Map<String, String> headers = const <String, String>{},
    RequestPriority priority = RequestPriority.background,
    String? dedupeKey,
    String? bucketKey,
    bool retryOnRateLimit = true,
    Duration? timeoutOverride,
  }) async => KonataHttpResponse(
    statusCode: 200,
    headers: const <String, String>{},
    bodyBytes: Uint8List(0),
  );

  @override
  Future<KonataHttpResponse> post(
    Uri uri, {
    Map<String, String> headers = const <String, String>{},
    Object? body,
    RequestPriority priority = RequestPriority.background,
    String? dedupeKey,
    String? bucketKey,
  }) async => KonataHttpResponse(
    statusCode: 200,
    headers: const <String, String>{},
    bodyBytes: Uint8List(0),
  );

  @override
  Future<KonataHttpResponse> postWithFallback(
    Uri primaryUri, {
    Uri? backupUri,
    Map<String, String> headers = const <String, String>{},
    Object? body,
    RequestPriority priority = RequestPriority.background,
    String? dedupeKey,
    String? bucketKey,
    bool retryOnRateLimit = true,
    Duration? timeoutOverride,
  }) async => KonataHttpResponse(
    statusCode: 200,
    headers: const <String, String>{},
    bodyBytes: Uint8List(0),
  );

  @override
  Future<KonataHttpResponse> sendWithFallback({
    required String method,
    required Uri primaryUri,
    Uri? backupUri,
    Map<String, String> headers = const <String, String>{},
    Object? body,
    RequestPriority priority = RequestPriority.background,
    String? dedupeKey,
    String? bucketKey,
    bool retryOnRateLimit = true,
    Duration? timeoutOverride,
  }) async => KonataHttpResponse(
    statusCode: 200,
    headers: const <String, String>{},
    bodyBytes: Uint8List(0),
  );
}

final class _StubUrlOpener implements UrlOpenerPort {
  final List<Uri> opened = <Uri>[];

  @override
  Future<bool> openExternalUrl(Uri uri) async {
    opened.add(uri);
    return true;
  }
}

final class _CustomTrackerProvider implements ProgressTrackerProvider {
  _CustomTrackerProvider({required this.id, required this.name});

  final String id;
  final String name;
  final List<TrackerProgressPayload> pushed = <TrackerProgressPayload>[];

  @override
  String get trackerId => id;

  @override
  String get displayName => name;

  @override
  Future<bool> isConfigured() async => true;

  @override
  Future<TrackerSyncResult> pushProgress(TrackerProgressPayload payload) async {
    pushed.add(payload);
    return const TrackerSyncResult.succeeded(remoteSummary: 'ok');
  }
}

http.Response _jsonResponse(Object payload, {int statusCode = 200}) {
  return http.Response.bytes(
    utf8.encode(jsonEncode(payload)),
    statusCode,
    headers: const <String, String>{'content-type': 'application/json'},
  );
}

void main() {
  late KonataDatabaseBundle db;
  late InMemorySecureStorage secureStorage;
  late ScopedPrefsStore scopedPrefs;
  late InMemoryDomainEventBus eventBus;
  late _RecordedLog log;

  setUp(() {
    db = KonataDatabaseBundle.openInMemory();
    secureStorage = InMemorySecureStorage();
    scopedPrefs = ScopedPrefsStore(db.userState);
    eventBus = InMemoryDomainEventBus();
    log = _RecordedLog();

    db.library.works.upsert(
      const WorkRecord(
        id: WorkId.trusted('work_1'),
        title: '葬送的芙莉莲',
        bangumiId: 400602,
        tmdbMediaType: TmdbMediaType.tv,
      ),
    );
    db.library.episodes.upsert(
      const EpisodeRecord(
        id: EpisodeId.trusted('ep_1'),
        workId: WorkId.trusted('work_1'),
        seasonNumber: 1,
        episodeNumber: 1,
        category: EpisodeCategory.main,
        title: '冒险的终点',
      ),
    );
    db.library.episodes.upsert(
      const EpisodeRecord(
        id: EpisodeId.trusted('ep_2'),
        workId: WorkId.trusted('work_1'),
        seasonNumber: 1,
        episodeNumber: 2,
        category: EpisodeCategory.main,
        title: '就算不是魔法也没关系',
      ),
    );
    db.library.episodes.upsert(
      const EpisodeRecord(
        id: EpisodeId.trusted('ep_sp'),
        workId: WorkId.trusted('work_1'),
        seasonNumber: 0,
        episodeNumber: 1,
        category: EpisodeCategory.extra,
        extraType: ExtraKind.sp,
        title: '特典',
      ),
    );
  });

  tearDown(() async {
    await eventBus.dispose();
    await db.close();
  });

  test('客户端仅直连官方域名且异常和日志绝不泄漏 PAT 明文', () async {
    const secretPat = 'bgm_pat_super_secret_token_987654';
    final requests = <Uri>[];
    final mockHttp = MockClient((request) async {
      requests.add(request.url);
      if (request.url.path == '/v0/me') {
        return _jsonResponse(
          <String, Object?>{
            'description': 'gateway error with Bearer $secretPat echoed back',
          },
          statusCode: 502,
        );
      }
      return _jsonResponse(<String, Object?>{}, statusCode: 404);
    });

    final client = BangumiSyncClient(httpClient: mockHttp, diagnosticLog: log);
    addTearDown(client.close);

    String? caughtError;
    try {
      await client.verifyToken(secretPat);
    } on BangumiApiException catch (error) {
      caughtError = error.message;
    }

    expect(requests, isNotEmpty);
    expect(requests.every((uri) => uri.host == 'api.bgm.tv'), isTrue);
    expect(requests.every((uri) => uri.scheme == 'https'), isTrue);
    expect(caughtError, isNotNull);
    expect(caughtError, isNot(contains(secretPat)));
    expect(log.capturedMessages.join('\n'), isNot(contains(secretPat)));
  });

  test('监听完播事件自动入队并在离线后按指数退避恢复补推', () async {
    const secretPat = 'bgm_pat_offline_test_123456';
    await secureStorage.write(BangumiSyncConfigStore.patStorageKey, secretPat);

    var networkAvailable = false;
    final remoteEpisodeStatuses = <int, int>{1001: 0, 1002: 0};
    final recordedRequests = <String>[];

    final mockHttp = MockClient((request) async {
      recordedRequests.add('${request.method} ${request.url.path}');
      expect(request.url.host, equals('api.bgm.tv'));
      expect(request.headers['Authorization'], equals('Bearer $secretPat'));

      if (!networkAvailable) {
        throw const SocketException('Network unreachable $secretPat');
      }
      if (request.method == 'GET' &&
          request.url.path == '/v0/users/-/collections/400602') {
        return _jsonResponse(<String, Object?>{'type': 3});
      }
      if (request.method == 'GET' &&
          request.url.path == '/v0/users/-/collections/400602/episodes') {
        return _jsonResponse(<String, Object?>{
          'total': 2,
          'data': <Map<String, Object?>>[
            <String, Object?>{
              'type': remoteEpisodeStatuses[1001],
              'episode': <String, Object?>{'id': 1001, 'type': 0, 'sort': 1, 'ep': 1},
            },
            <String, Object?>{
              'type': remoteEpisodeStatuses[1002],
              'episode': <String, Object?>{'id': 1002, 'type': 0, 'sort': 2, 'ep': 2},
            },
          ],
        });
      }
      if (request.method == 'PUT' &&
          request.url.path == '/v0/users/-/collections/-/episodes/1001') {
        remoteEpisodeStatuses[1001] = 2;
        return http.Response('', 204);
      }
      return _jsonResponse(<String, Object?>{}, statusCode: 404);
    });

    var currentClock = DateTime.utc(2026, 7, 1, 12, 0, 0);
    final configStore = BangumiSyncConfigStore(
      scopedPrefs: scopedPrefs,
      secureStorage: secureStorage,
      syncMetaDao: db.userState.syncMeta,
    );
    final client = BangumiSyncClient(httpClient: mockHttp, diagnosticLog: log);
    addTearDown(client.close);

    final coordinator = TrackerSyncCoordinator(
      databases: db,
      domainEventBus: eventBus,
      diagnosticLog: log,
      configStore: configStore,
      client: client,
      clock: () => currentClock,
    );
    addTearDown(coordinator.dispose);

    // 触发第 1 集完播和特典完播（特典应被忽略，仅第 1 集入队）。
    eventBus.publish(
      EpisodeCompletionChangedEvent(
        workId: const WorkId.trusted('work_1'),
        episodeId: const EpisodeId.trusted('ep_sp'),
        completed: true,
        occurredAtMs: currentClock.millisecondsSinceEpoch,
      ),
    );
    eventBus.publish(
      EpisodeCompletionChangedEvent(
        workId: const WorkId.trusted('work_1'),
        episodeId: const EpisodeId.trusted('ep_1'),
        completed: true,
        occurredAtMs: currentClock.millisecondsSinceEpoch,
      ),
    );
    await coordinator.waitForIdle();

    expect(coordinator.pendingCount, equals(1));
    final queuedItem = coordinator.pendingBangumiItems.single;
    expect(queuedItem.episodeNumber, equals(1));
    expect(queuedItem.retryCount, equals(1));
    expect(
      queuedItem.nextRetryAtMs,
      equals(currentClock.millisecondsSinceEpoch + 30 * 1000),
    );
    expect(queuedItem.lastError, isNot(contains(secretPat)));

    // 验证偏好库与日志内绝不包含 PAT 明文。
    await coordinator.updateConfig(
      coordinator.config.copyWith(autoMarkCollectionCompleted: true),
    );
    final prefsDump = db.userState.scopedPrefs
        .findByNamespace('feature_tracker_sync.bangumi')
        ?.payloadJson;
    expect(prefsDump, isNotNull);
    expect(prefsDump, isNot(contains(secretPat)));
    expect(log.capturedMessages.join('\n'), isNot(contains(secretPat)));

    // 退避窗口未到时不发起网络重试。
    recordedRequests.clear();
    currentClock = currentClock.add(const Duration(seconds: 15));
    await coordinator.flushDueQueue();
    expect(recordedRequests, isEmpty);

    // 网络恢复且到达退避窗口后成功冲刷并移除队列项。
    networkAvailable = true;
    currentClock = currentClock.add(const Duration(seconds: 20));
    final flushed = await coordinator.flushDueQueue();
    expect(flushed, equals(1));
    expect(coordinator.pendingCount, equals(0));
    expect(remoteEpisodeStatuses[1001], equals(2));
  });

  test('遇到 401 鉴权失效立即标记不可重试并停止后续队列消耗，重绑后恢复推送', () async {
    const expiredPat = 'bgm_expired_token_111';
    const freshPat = 'bgm_fresh_token_222';
    await secureStorage.write(BangumiSyncConfigStore.patStorageKey, expiredPat);

    final pushCallsWithExpired = <String>[];
    final pushCallsWithFresh = <String>[];

    final mockHttp = MockClient((request) async {
      final auth = request.headers['Authorization'];
      if (request.url.path == '/v0/me') {
        if (auth == 'Bearer $freshPat') {
          return _jsonResponse(<String, Object?>{
            'id': 42,
            'username': 'konata',
            'nickname': '泉此方',
          });
        }
        return _jsonResponse(<String, Object?>{'title': 'Unauthorized'}, statusCode: 401);
      }

      if (auth == 'Bearer $expiredPat') {
        pushCallsWithExpired.add('${request.method} ${request.url.path}');
        return _jsonResponse(<String, Object?>{'title': 'Unauthorized'}, statusCode: 401);
      }

      if (auth == 'Bearer $freshPat') {
        pushCallsWithFresh.add('${request.method} ${request.url.path}');
        if (request.method == 'GET' &&
            request.url.path == '/v0/users/-/collections/400602') {
          return _jsonResponse(<String, Object?>{'type': 3});
        }
        if (request.method == 'GET' &&
            request.url.path == '/v0/users/-/collections/400602/episodes') {
          return _jsonResponse(<String, Object?>{
            'total': 2,
            'data': <Map<String, Object?>>[
              <String, Object?>{
                'type': 0,
                'episode': <String, Object?>{'id': 2001, 'type': 0, 'sort': 1, 'ep': 1},
              },
              <String, Object?>{
                'type': 0,
                'episode': <String, Object?>{'id': 2002, 'type': 0, 'sort': 2, 'ep': 2},
              },
            ],
          });
        }
        if (request.method == 'PUT') {
          return http.Response('', 204);
        }
      }
      return _jsonResponse(<String, Object?>{}, statusCode: 404);
    });

    final now = DateTime.utc(2026, 7, 1, 14, 0, 0);
    final configStore = BangumiSyncConfigStore(
      scopedPrefs: scopedPrefs,
      secureStorage: secureStorage,
      syncMetaDao: db.userState.syncMeta,
    );
    final client = BangumiSyncClient(httpClient: mockHttp, diagnosticLog: log);
    addTearDown(client.close);

    final coordinator = TrackerSyncCoordinator(
      databases: db,
      domainEventBus: eventBus,
      diagnosticLog: log,
      configStore: configStore,
      client: client,
      autoFlushOnEvent: false,
      clock: () => now,
    );
    addTearDown(coordinator.dispose);

    eventBus.publish(
      EpisodeCompletionChangedEvent(
        workId: const WorkId.trusted('work_1'),
        episodeId: const EpisodeId.trusted('ep_1'),
        completed: true,
        occurredAtMs: now.millisecondsSinceEpoch,
      ),
    );
    eventBus.publish(
      EpisodeCompletionChangedEvent(
        workId: const WorkId.trusted('work_1'),
        episodeId: const EpisodeId.trusted('ep_2'),
        completed: true,
        occurredAtMs: now.millisecondsSinceEpoch + 1000,
      ),
    );
    await coordinator.waitForIdle();
    expect(coordinator.pendingCount, equals(2));

    // 首条遇 401 即刻中止冲刷，第二条不会浪费调用接口，且暂停全部自动重试。
    final firstFlush = await coordinator.flushDueQueue();
    expect(firstFlush, equals(0));
    expect(pushCallsWithExpired.length, equals(1));
    expect(coordinator.authInvalid, isTrue);
    expect(coordinator.pausedPendingCount, equals(1));

    // 即使传入未来时间再次冲刷也不再请求网络。
    final secondFlush = await coordinator.flushDueQueue(
      includeBackoffScheduled: true,
      nowOverride: now.add(const Duration(days: 7)),
    );
    expect(secondFlush, equals(0));
    expect(pushCallsWithExpired.length, equals(1));

    // 绑定有效新 PAT 后自动解除暂停并成功补推两条记录。
    final profile = await coordinator.bindAndVerifyToken(freshPat);
    expect(profile.nickname, equals('泉此方'));
    expect(coordinator.authInvalid, isFalse);

    final recovered = await coordinator.flushDueQueue();
    expect(recovered, equals(2));
    expect(coordinator.pendingCount, equals(0));
    expect(pushCallsWithFresh.where((call) => call.startsWith('PUT')).length, equals(2));
  });

  test('支持多追番提供者扩展挂载与清单绑定', () async {
    const pat = 'bgm_multi_provider_pat';
    await secureStorage.write(BangumiSyncConfigStore.patStorageKey, pat);
    final customProvider = _CustomTrackerProvider(
      id: 'anilist',
      name: 'AniList 测试适配器',
    );

    final mockHttp = MockClient((request) async {
      if (request.method == 'GET' &&
          request.url.path == '/v0/users/-/collections/400602') {
        return _jsonResponse(<String, Object?>{'type': 3});
      }
      if (request.method == 'GET' &&
          request.url.path == '/v0/users/-/collections/400602/episodes') {
        return _jsonResponse(<String, Object?>{
          'total': 1,
          'data': <Map<String, Object?>>[
            <String, Object?>{
              'type': 0,
              'episode': <String, Object?>{'id': 3001, 'type': 0, 'sort': 1, 'ep': 1},
            },
          ],
        });
      }
      if (request.method == 'PUT') {
        return http.Response('', 204);
      }
      return _jsonResponse(<String, Object?>{}, statusCode: 404);
    });

    final container = ProviderContainer(
      overrides: [
        featureTrackerSyncDependenciesProvider.overrideWithValue(
          FeatureTrackerSyncDependencies(
            databases: db,
            secureStorage: secureStorage,
            scopedPrefs: scopedPrefs,
            domainEventBus: eventBus,
            diagnosticLog: log,
            httpClient: _StubHttpClientPort(),
            urlOpener: _StubUrlOpener(),
            platform: KonataPlatform.windows,
            rawHttpClientOverride: mockHttp,
            additionalProviders: <ProgressTrackerProvider>[customProvider],
            subjectResolver: (trackerId, work) =>
                trackerId == 'anilist' ? 'al_999' : work.bangumiId?.toString(),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    final coordinator = container.read(trackerSyncCoordinatorProvider);
    expect(featureTrackerSyncManifest.id, equals('feature_tracker_sync'));
    expect(featureTrackerSyncManifest.dataProviders.single.id, equals('bangumi'));
    expect(
      await featureTrackerSyncManifest.dataProviders.single
          .let((d) => (d as ProgressTrackerProviderContribution).provider.isConfigured()),
      isTrue,
    );

    eventBus.publish(
      EpisodeCompletionChangedEvent(
        workId: const WorkId.trusted('work_1'),
        episodeId: const EpisodeId.trusted('ep_1'),
        completed: true,
        occurredAtMs: DateTime.utc(2026, 7, 1).millisecondsSinceEpoch,
      ),
    );
    await coordinator.waitForIdle();

    expect(customProvider.pushed.length, equals(1));
    expect(customProvider.pushed.single.externalSubjectId, equals('al_999'));
    expect(customProvider.pushed.single.episodeNumber, equals(1));
    expect(coordinator.pendingCount, equals(0));
  });
}

extension<T> on T {
  R let<R>(R Function(T value) block) => block(this);
}
