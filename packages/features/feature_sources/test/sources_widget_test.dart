import 'dart:io';
import 'dart:typed_data';

import 'package:engine_scraping/engine_scraping.dart';
import 'package:feature_sources/feature_sources.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_design_system/konata_design_system.dart';
import 'package:konata_storage/konata_storage.dart';

class _TestStorageRoot implements StorageRootPort {
  _TestStorageRoot(this.rootPath);

  final String rootPath;

  @override
  Future<String> ensureDatabaseDirPath() async => '$rootPath/userdata/db';

  @override
  Future<String> ensureLogsDirPath() async => '$rootPath/userdata/logs';

  @override
  Future<String> ensureTempDirPath() async => '$rootPath/cache/tmp';

  @override
  Future<String> ensureUserdataDirPath() async => '$rootPath/userdata';

  @override
  Future<String> resolveAppRootPath() async => rootPath;

  @override
  Future<String> resolveCacheRootPath() async => '$rootPath/cache';

  @override
  Future<String> resolveDatabaseFilePath(String dbFileName) async =>
      '$rootPath/userdata/db/$dbFileName';

  @override
  Future<String> resolvePhotosDirPath() async => '$rootPath/photos';
}

class _FakeNavigator implements AppNavigator {
  final List<String> openedSettingsSections = <String>[];
  final List<String> switchedSections = <String>[];
  final List<WorkId> openedWorkDetails = <WorkId>[];

  @override
  Future<void> openAudioPlayer({
    required WorkId workId,
    VariantId? variantId,
  }) async {}

  @override
  Future<void> openSettings({String? sectionId}) async {
    openedSettingsSections.add(sectionId ?? '');
  }

  @override
  Future<void> openVideoPlayer({
    required WorkId workId,
    EpisodeId? episodeId,
    VariantId? variantId,
  }) async {}

  @override
  Future<void> openWorkDetail(WorkId workId, {String? initialTabId}) async {
    openedWorkDetails.add(workId);
  }

  @override
  Future<bool> pop() async => true;

  @override
  Future<void> switchNavSection(String sectionId) async {
    switchedSections.add(sectionId);
  }
}

class _FakeFilePicker implements FilePickerPort {
  _FakeFilePicker(this.directoryToReturn);

  final String? directoryToReturn;
  int pickCalls = 0;

  @override
  Future<String?> pickDirectory({String? dialogTitle}) async {
    pickCalls++;
    return directoryToReturn;
  }

  @override
  Future<String?> pickImageFile({String? dialogTitle}) async => null;

  @override
  Future<String?> pickSubtitleFile({String? dialogTitle}) async => null;
}

class _FakeDiagnosticLog implements DiagnosticLogPort {
  @override
  Future<String> buildJsonBundle() async => '{}';

  @override
  Future<String> buildTextReport() async => '';

  @override
  void clear() {}

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

class _FakeHttpClient implements KonataHttpClientPort {
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
  }) => get(primaryUri);

  @override
  Future<KonataHttpResponse> post(
    Uri uri, {
    Map<String, String> headers = const <String, String>{},
    Object? body,
    RequestPriority priority = RequestPriority.background,
    String? dedupeKey,
    String? bucketKey,
  }) => get(uri);

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
  }) => get(primaryUri);

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
  }) => get(primaryUri);
}

class _FakeGateway implements MediaSourceGateway {
  @override
  Future<void> close() async {}

  @override
  Future<List<RemoteEntry>> listDirectory(String relativePath) async => const [
    RemoteEntry(name: '2024', relativePath: '2024', isDirectory: true),
    RemoteEntry(name: '剧场版', relativePath: '剧场版', isDirectory: true),
  ];

  @override
  Future<String?> readTextFile(
    String relativePath, {
    int maxBytes = 256 * 1024,
  }) async => null;

  @override
  Future<String?> testConnection() async => null;
}

class _FakeGatewayFactory implements MediaSourceGatewayFactoryPort {
  @override
  Future<MediaSourceGateway> create(
    MediaSourceView source, {
    String? passwordOverride,
    bool clearPassword = false,
  }) async => _FakeGateway();
}

void main() {
  testWidgets('媒体源主页面与编辑/删除弹窗在四组标准视口尺寸下零溢出且交互闭环', (tester) async {
    final tempRoot = Directory.systemTemp.createTempSync('konata_src_ui_');
    addTearDown(() {
      if (tempRoot.existsSync()) {
        tempRoot.deleteSync(recursive: true);
      }
    });

    final db = KonataDatabaseBundle.openInMemory();
    addTearDown(db.close);
    final eventBus = InMemoryDomainEventBus();
    addTearDown(eventBus.dispose);
    final navigator = _FakeNavigator();
    final picker = _FakeFilePicker('D:/NewAnime');
    final storageRoot = _TestStorageRoot(tempRoot.path);
    final prefs = ScopedPrefsStore(db.userState);
    final photos = PhotosStorage(storageRoot: storageRoot);

    final repo = StorageScrapeRepository(db);
    await repo.upsertMediaSource(
      const MediaSource(
        id: 'src_ui_1',
        kind: MediaSourceKind.webdav,
        label: '家庭主力 WebDAV 动画库超长名称测试字段',
        location: 'https://nas.example.com:5006/bangumi/collection',
        username: 'admin',
      ),
    );
    await repo.addIgnoredFolder('src_ui_1', 'NCOP/2024');

    final deps = FeatureSourcesDependencies(
      databases: db,
      storageRoot: storageRoot,
      secureStorage: InMemorySecureStorage(),
      diagnosticLog: _FakeDiagnosticLog(),
      scopedPrefs: prefs,
      domainEventBus: eventBus,
      navigator: navigator,
      filePicker: picker,
      httpClient: _FakeHttpClient(),
      gatewayFactory: _FakeGatewayFactory(),
      photosStorage: photos,
      platform: KonataPlatform.windows,
    );

    const viewports = <Size>[
      Size(390, 780),
      Size(780, 390),
      Size(1024, 700),
      Size(1440, 900),
    ];

    for (final viewport in viewports) {
      tester.view.physicalSize = viewport;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final toastCtrl = KonataToastController();
      addTearDown(toastCtrl.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            featureSourcesDependenciesProvider.overrideWithValue(deps),
          ],
          child: MaterialApp(
            theme: KonataTheme.darkTheme(),
            home: KonataToastScope(
              controller: toastCtrl,
              child: Scaffold(
                body: Stack(
                  children: [
                    featureSourcesManifest.navSections.first.viewBuilder(
                          const ViewSlotContext(),
                        )
                        as Widget,
                    KonataToastViewport(controller: toastCtrl),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('尚未配置 TMDB API 凭证'), findsOneWidget);
      expect(find.textContaining('家庭主力 WebDAV'), findsOneWidget);
    }

    await tester.tap(find.text('去配置'));
    await tester.pumpAndSettle();
    expect(navigator.openedSettingsSections, contains('network'));

    await tester.tap(find.byKey(const Key('sources_add_button')));
    await tester.pumpAndSettle();
    expect(find.text('添加媒体源'), findsOneWidget);

    await tester.tap(find.text('浏览'));
    await tester.pumpAndSettle();
    expect(picker.pickCalls, 1);

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    final sourcesAfterAdd = await repo.getMediaSources();
    expect(sourcesAfterAdd.any((s) => s.location == 'D:/NewAnime'), isTrue);
  });
}
