import 'dart:convert';
import 'dart:typed_data';

import 'package:feature_tracker_sync/feature_tracker_sync.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_design_system/konata_design_system.dart';
import 'package:konata_storage/konata_storage.dart';

final class _FakeLog implements DiagnosticLogPort {
  @override
  void clear() {}

  @override
  Future<String> buildJsonBundle() async => '{}';

  @override
  Future<String> buildTextReport() async => '';

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
  }) {}

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
  }) {}

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

final class _FakeHttpClientPort implements KonataHttpClientPort {
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

final class _FakeUrlOpener implements UrlOpenerPort {
  final List<Uri> opened = <Uri>[];

  @override
  Future<bool> openExternalUrl(Uri uri) async {
    opened.add(uri);
    return true;
  }
}

void main() {
  testWidgets('Bangumi 同步卡片支持 PAT 绑定、队列计数显示与一键补推', (tester) async {
    final db = KonataDatabaseBundle.openInMemory();
    addTearDown(db.close);
    final secureStorage = InMemorySecureStorage();
    final scopedPrefs = ScopedPrefsStore(db.userState);
    final eventBus = InMemoryDomainEventBus();
    addTearDown(eventBus.dispose);
    final urlOpener = _FakeUrlOpener();

    db.library.works.upsert(
      const WorkRecord(
        id: WorkId.trusted('work_ui'),
        title: '迷宫饭',
        bangumiId: 404804,
      ),
    );
    db.library.episodes.upsert(
      const EpisodeRecord(
        id: EpisodeId.trusted('ep_ui_1'),
        workId: WorkId.trusted('work_ui'),
        seasonNumber: 1,
        episodeNumber: 1,
        category: EpisodeCategory.main,
      ),
    );

    final mockHttp = MockClient((request) async {
      if (request.url.path == '/v0/me') {
        return http.Response.bytes(
          utf8.encode(
            jsonEncode(<String, Object?>{
              'id': 77,
              'username': 'laios',
              'nickname': '莱欧斯',
            }),
          ),
          200,
        );
      }
      if (request.url.path == '/v0/users/-/collections/404804') {
        return http.Response.bytes(
          utf8.encode(jsonEncode(<String, Object?>{'type': 3})),
          200,
        );
      }
      if (request.url.path == '/v0/users/-/collections/404804/episodes') {
        return http.Response.bytes(
          utf8.encode(
            jsonEncode(<String, Object?>{
              'total': 1,
              'data': <Map<String, Object?>>[
                <String, Object?>{
                  'type': 0,
                  'episode': <String, Object?>{
                    'id': 9001,
                    'type': 0,
                    'sort': 1,
                    'ep': 1,
                  },
                },
              ],
            }),
          ),
          200,
        );
      }
      if (request.method == 'PUT' &&
          request.url.path == '/v0/users/-/collections/-/episodes/9001') {
        return http.Response('', 204);
      }
      return http.Response('{}', 404);
    });

    // 预先放入一条待重试队列项，验证界面显示数量与一键补推。
    db.userState.trackerSyncQueue.enqueue(
      const TrackerSyncQueueItem(
        queueKey: 'bangumi:404804:s1:e1',
        trackerId: 'bangumi',
        externalSubjectId: '404804',
        seasonNumber: 1,
        episodeNumber: 1,
        targetStatus: 2,
        payloadJson: '{"completed":true}',
        enqueuedAtMs: 1000,
        retryCount: 1,
        nextRetryAtMs: 999999999999,
      ),
    );

    final deps = FeatureTrackerSyncDependencies(
      databases: db,
      secureStorage: secureStorage,
      scopedPrefs: scopedPrefs,
      domainEventBus: eventBus,
      diagnosticLog: _FakeLog(),
      httpClient: _FakeHttpClientPort(),
      urlOpener: urlOpener,
      platform: KonataPlatform.windows,
      rawHttpClientOverride: mockHttp,
    );

    tester.view.physicalSize = const Size(1024, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final toastController = KonataToastController();
    addTearDown(toastController.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          featureTrackerSyncDependenciesProvider.overrideWithValue(deps),
        ],
        child: MaterialApp(
          theme: KonataTheme.darkTheme(),
          home: KonataToastScope(
            controller: toastController,
            child: Scaffold(
              body: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child:
                    featureTrackerSyncManifest.settingsSections.single
                            .viewBuilder(const ViewSlotContext())
                        as Widget,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Bangumi 番组计划同步'), findsOneWidget);
    expect(featureTrackerSyncManifest.settingsSections.single.title, '追踪记录');
    final wordmark = find.byKey(const ValueKey('bangumi_sync_wordmark'));
    expect(tester.getSize(wordmark), const Size(38, 38));
    final logo = find.descendant(of: wordmark, matching: find.text('bgm'));
    expect(logo, findsOneWidget);
    expect(tester.widget<Text>(logo).style?.color, KonataTheme.bangumiPink);
    expect(tester.getCenter(logo), tester.getCenter(wordmark));
    expect(find.text('待重试推送队列：1 条'), findsOneWidget);

    await tester.tap(find.text('获取 PAT'));
    await tester.pump();
    expect(urlOpener.opened.length, equals(1));

    await tester.enterText(find.byType(TextField), 'bgm_widget_pat_test');
    await tester.tap(find.text('验证并绑定 PAT'));
    await tester.pumpAndSettle();

    expect(find.text('莱欧斯 (@laios)'), findsOneWidget);
    expect(find.text('已验证并绑定：莱欧斯 (@laios)'), findsOneWidget);
    expect(
      await secureStorage.read(BangumiSyncConfigStore.patStorageKey),
      equals('bgm_widget_pat_test'),
    );

    await tester.tap(find.text('一键补推'));
    await tester.pumpAndSettle();
    expect(find.text('待重试推送队列：0 条'), findsOneWidget);
  });

  testWidgets('手机与窄视口下正常展示鉴权失效重绑提示且零溢出', (tester) async {
    final db = KonataDatabaseBundle.openInMemory();
    addTearDown(db.close);
    final secureStorage = InMemorySecureStorage();
    await secureStorage.write(
      BangumiSyncConfigStore.patStorageKey,
      'bgm_expired_ui_pat',
    );
    final scopedPrefs = ScopedPrefsStore(db.userState);
    final eventBus = InMemoryDomainEventBus();
    addTearDown(eventBus.dispose);

    db.userState.syncMeta.put(
      BangumiSyncConfigStore.authInvalidMetaKey,
      '1',
      updatedAtMs: 1000,
    );
    db.userState.syncMeta.put(
      BangumiSyncConfigStore.authErrorMetaKey,
      'Bangumi PAT 无效或已过期（401），请重新绑定',
      updatedAtMs: 1000,
    );

    final deps = FeatureTrackerSyncDependencies(
      databases: db,
      secureStorage: secureStorage,
      scopedPrefs: scopedPrefs,
      domainEventBus: eventBus,
      diagnosticLog: _FakeLog(),
      httpClient: _FakeHttpClientPort(),
      urlOpener: _FakeUrlOpener(),
      platform: KonataPlatform.androidPhone,
      rawHttpClientOverride: MockClient((_) async => http.Response('{}', 401)),
    );

    tester.view.physicalSize = const Size(390, 780);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final toastController = KonataToastController();
    addTearDown(toastController.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          featureTrackerSyncDependenciesProvider.overrideWithValue(deps),
        ],
        child: MaterialApp(
          theme: KonataTheme.darkTheme(),
          home: KonataToastScope(
            controller: toastController,
            child: const Scaffold(
              body: SingleChildScrollView(
                padding: EdgeInsets.all(12),
                child: SettingsBangumiSyncCard(),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('鉴权失效需重绑'), findsOneWidget);
    expect(find.textContaining('401'), findsOneWidget);
  });
}
