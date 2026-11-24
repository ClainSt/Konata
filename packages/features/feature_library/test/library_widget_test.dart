import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:engine_scraping/engine_scraping.dart';
import 'package:feature_library/feature_library.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_design_system/konata_design_system.dart';
import 'package:konata_storage/konata_storage.dart';

final Uint8List _samplePng = Uint8List.fromList(<int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, //
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, //
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, //
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41, //
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00, //
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, //
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, //
  0x42, 0x60, 0x82,
]);

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
  final List<WorkId> openedWorkDetails = <WorkId>[];
  final List<String> switchedSections = <String>[];

  @override
  Future<void> openAudioPlayer({
    required WorkId workId,
    VariantId? variantId,
  }) async {}

  @override
  Future<void> openSettings({String? sectionId}) async {}

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

void main() {
  testWidgets('媒体库海报墙在四视口矩阵下零溢出且点击海报卡准确触发 openWorkDetail', (
    tester,
  ) async {
    final tempRoot = Directory.systemTemp.createTempSync('konata_lib_ui_');
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
    final storageRoot = _TestStorageRoot(tempRoot.path);
    final prefs = ScopedPrefsStore(db.userState);
    final photos = PhotosStorage(storageRoot: storageRoot);
    final artworkCache = ArtworkDiskCache(photosStorage: photos);

    final repo = StorageScrapeRepository(db);
    await repo.upsertMediaSource(
      const MediaSource(
        id: 'src_wall',
        kind: MediaSourceKind.local,
        label: '本地源',
        location: 'D:/Anime',
      ),
    );
    await repo.upsertWork(
      const Work(
        id: 'w_wall_1',
        title: '吹响！上低音号 第三季',
        year: 2024,
        bangumiScore: 8.7,
        posterPath: '/hibike3.jpg',
        scrapeStatus: ScrapeStatus.matched,
      ),
    );
    await repo.upsertEpisode(
      const Episode(
        id: 'ep_w1',
        workId: 'w_wall_1',
        seasonNumber: 3,
        episodeNumber: 1,
      ),
    );
    await repo.upsertMediaVariant(
      const MediaVariant(
        id: 'var_w1',
        workId: 'w_wall_1',
        episodeId: 'ep_w1',
        sourceId: 'src_wall',
        relativePath: 'Hibike3/[VCB-Studio] 01.mkv',
        fileName: '[VCB-Studio] 01.mkv',
        fileSize: 1024,
      ),
    );

    final deps = FeatureLibraryDependencies(
      databases: db,
      storageRoot: storageRoot,
      diagnosticLog: _FakeDiagnosticLog(),
      scopedPrefs: prefs,
      domainEventBus: eventBus,
      navigator: navigator,
      httpClient: _FakeHttpClient(),
      photosStorage: photos,
      artworkCache: artworkCache,
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
            featureLibraryDependenciesProvider.overrideWithValue(deps),
          ],
          child: MaterialApp(
            theme: KonataTheme.darkTheme(),
            home: KonataToastScope(
              controller: toastCtrl,
              child: Scaffold(
                body: Stack(
                  children: [
                    LibraryPage(
                      slotContext: const ViewSlotContext(
                        arguments: <String, Object?>{'searchQuery': ''},
                      ),
                      imageLoaderOverride:
                          (
                            _, {
                            int targetWidth = 384,
                            TmdbImageSize imageSize = TmdbImageSize.w500,
                            String? ownerWorkId,
                            PhotoSubfolder? subfolder,
                          }) async => _samplePng,
                    ),
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
      expect(find.text('吹响！上低音号 第三季'), findsOneWidget);
    }

    await repo.upsertWork(
      const Work(
        id: 'w_wall_2',
        title: '少女乐队的呐喊',
        year: 2024,
        bangumiScore: 8.5,
        posterPath: '/gbc.jpg',
        scrapeStatus: ScrapeStatus.matched,
      ),
    );
    eventBus.publish(
      const LibraryWorkChangedEvent(
        workId: WorkId.trusted('w_wall_2'),
        reason: 'scraped',
        occurredAtMs: 123456,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('少女乐队的呐喊'), findsOneWidget);

    await tester.tap(find.text('少女乐队的呐喊'));
    await tester.pumpAndSettle();
    expect(navigator.openedWorkDetails.last.value, 'w_wall_2');
  });

  testWidgets('PosterCard 保持高速滚动惰性降载并在桌面顶栏搜索词注入时实时过滤', (
    tester,
  ) async {
    final tempRoot = Directory.systemTemp.createTempSync('konata_lib_opt_');
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
    final storageRoot = _TestStorageRoot(tempRoot.path);
    final prefs = ScopedPrefsStore(db.userState);
    final photos = PhotosStorage(storageRoot: storageRoot);

    final repo = StorageScrapeRepository(db);
    await repo.upsertWork(
      const Work(
        id: 'w_k1',
        title: '轻音少女',
        year: 2009,
        bangumiScore: 9.1,
        posterPath: '/kon.jpg',
        scrapeStatus: ScrapeStatus.matched,
      ),
    );
    await repo.upsertWork(
      const Work(
        id: 'w_k2',
        title: 'CLANNAD',
        year: 2007,
        bangumiScore: 9.2,
        posterPath: '/clannad.jpg',
        scrapeStatus: ScrapeStatus.matched,
      ),
    );

    final deps = FeatureLibraryDependencies(
      databases: db,
      storageRoot: storageRoot,
      diagnosticLog: _FakeDiagnosticLog(),
      scopedPrefs: prefs,
      domainEventBus: eventBus,
      navigator: navigator,
      httpClient: _FakeHttpClient(),
      photosStorage: photos,
      artworkCache: ArtworkDiskCache(photosStorage: photos),
      platform: KonataPlatform.windows,
    );

    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    var suppressHover = true;
    const item = WorkLibraryItem(
      work: Work(
        id: 'w_hover_1',
        title: '加速世界：无限的爆发',
        year: 2016,
        bangumiScore: 7.4,
        posterPath: '/aw.jpg',
        scrapeStatus: ScrapeStatus.matched,
      ),
      variants: <MediaVariant>[],
      episodeCount: 1,
      releaseGroups: <String>['VCB-Studio'],
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: KonataTheme.darkTheme(),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 180,
              height: 336,
              child: PosterCard(
                item: item,
                cardWidth: 180,
                suppressHoverCheck: () => suppressHover,
                imageLoaderOverride:
                    (
                      _, {
                      int targetWidth = 384,
                      TmdbImageSize imageSize = TmdbImageSize.w500,
                      String? ownerWorkId,
                      PhotoSubfolder? subfolder,
                    }) async => _samplePng,
                onTap: () {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(BangumiScoreWordmarkBadge), findsOneWidget);
    expect(find.byType(BackdropFilter), findsNothing);

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(tester.getCenter(find.byType(PosterCard)));
    await tester.pump(const Duration(milliseconds: 40));
    expect(find.byType(BackdropFilter), findsNothing);

    suppressHover = false;
    await gesture.moveTo(
      tester.getCenter(find.byType(PosterCard)) + const Offset(3, 0),
    );
    await tester.pumpAndSettle();
    expect(find.byType(BackdropFilter), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [featureLibraryDependenciesProvider.overrideWithValue(deps)],
        child: MaterialApp(
          theme: KonataTheme.darkTheme(),
          home: Scaffold(
            body: LibraryPage(
              slotContext: const ViewSlotContext(
                arguments: <String, Object?>{'searchQuery': 'CLANNAD'},
              ),
              imageLoaderOverride:
                  (
                    _, {
                    int targetWidth = 384,
                    TmdbImageSize imageSize = TmdbImageSize.w500,
                    String? ownerWorkId,
                    PhotoSubfolder? subfolder,
                  }) async => _samplePng,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey<String>('w_k2')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('w_k1')), findsNothing);
    expect(find.text('CLANNAD'), findsOneWidget);
    expect(find.text('轻音少女'), findsNothing);
  });
}
