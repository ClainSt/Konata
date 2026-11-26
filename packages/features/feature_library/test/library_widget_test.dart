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
    int? initialCueTrackIndex,
    int? initialPositionSeconds,
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

class _CountingArtworkCache implements ArtworkCacheStore {
  _CountingArtworkCache(this.inner);
  final ArtworkDiskCache inner;
  int reads = 0;
  int localReads = 0;
  int writes = 0;

  @override
  Future<Uint8List?> read(
    String key, {
    int minimumQuality = 0,
    String? owner,
    PhotoSubfolder? subfolder,
  }) {
    reads++;
    return inner.read(
      key,
      minimumQuality: minimumQuality,
      owner: owner,
      subfolder: subfolder,
    );
  }

  @override
  Future<void> write(
    String key,
    Uint8List bytes, {
    String? owner,
    int quality = 0,
    PhotoSubfolder? subfolder,
  }) {
    writes++;
    return inner.write(
      key,
      bytes,
      owner: owner,
      quality: quality,
      subfolder: subfolder,
    );
  }

  @override
  Future<Uint8List?> readLocalWorkFile({
    required String owner,
    required PhotoSubfolder subfolder,
    required String fileName,
  }) {
    localReads++;
    return inner.readLocalWorkFile(
      owner: owner,
      subfolder: subfolder,
      fileName: fileName,
    );
  }
}

class _ArtworkAuditHttp extends _FakeHttpClient {
  final requests = <Uri>[];

  @override
  Future<KonataHttpResponse> get(
    Uri uri, {
    Map<String, String> headers = const <String, String>{},
    RequestPriority priority = RequestPriority.background,
    String? dedupeKey,
    String? bucketKey,
  }) async {
    requests.add(uri);
    return KonataHttpResponse(
      statusCode: uri.path.endsWith('failure.png') ? 503 : 200,
      headers: const {'content-type': 'image/png'},
      bodyBytes: _samplePng,
    );
  }
}

void main() {
  testWidgets('海报长标题仅在静止悬停时显示全文，短标题及滚动期不挂载提示', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final scrolling = ValueNotifier(false);
    addTearDown(scrolling.dispose);
    var blocked = false;
    var taps = 0;
    const longTitle = '轻音少女 K-ON!! 第二季 全24话 + 番外篇 特别收纳合集纪念版';
    const shortTitle = '轻音少女';
    Widget app(String title) => MaterialApp(
      theme: KonataTheme.darkTheme(),
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 140,
            height: 280,
            child: PosterCard(
              key: ValueKey(title),
              item: WorkLibraryItem(
                work: Work(id: 'tooltip-audit', title: title),
                variants: const [],
                episodeCount: 1,
                releaseGroups: const [],
              ),
              cardWidth: 140,
              scrollingListenable: scrolling,
              suppressHoverCheck: () => blocked,
              onTap: () => taps++,
            ),
          ),
        ),
      ),
    );
    await tester.pumpWidget(app(longTitle));
    await tester.pumpAndSettle();
    expect(find.byTooltip(longTitle), findsNothing);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    final fullTitleCount = find
        .text(longTitle, findRichText: true)
        .evaluate()
        .length;
    final titleFinder = find.text(longTitle).last;
    final point = tester.getCenter(titleFinder);

    scrolling.value = true;
    await mouse.moveTo(point);
    await tester.pumpAndSettle();
    expect(find.byTooltip(longTitle), findsNothing);
    scrolling.value = false;
    await tester.pumpAndSettle();
    await mouse.moveTo(point + const Offset(2, 0));
    await tester.pumpAndSettle();
    expect(find.byTooltip(longTitle), findsOneWidget, reason: '黄金源长标题全文提示必须恢复');
    await tester.pump(
      KonataTheme.tooltipWaitDuration + const Duration(milliseconds: 200),
    );
    await tester.pumpAndSettle();
    expect(
      find.text(longTitle, findRichText: true).evaluate().length,
      greaterThan(fullTitleCount),
      reason: '实际浮层必须显示全文',
    );

    scrolling.value = true;
    await tester.pumpAndSettle();
    expect(find.byTooltip(longTitle), findsNothing);
    scrolling.value = false;
    blocked = true;
    await mouse.moveTo(point + const Offset(4, 0));
    await tester.pumpAndSettle();
    expect(find.byTooltip(longTitle), findsNothing);
    blocked = false;
    await mouse.moveTo(Offset.zero);
    await tester.pumpAndSettle();
    await tester.pumpWidget(app(shortTitle));
    await tester.pumpAndSettle();
    await mouse.moveTo(tester.getCenter(find.text(shortTitle).last));
    await tester.pumpAndSettle();
    expect(find.byTooltip(shortTitle), findsNothing);
    await tester.tap(find.text(shortTitle).last);
    expect(taps, 1);
    expect(tester.takeException(), isNull);
  });

  test('生产海报加载单次缓存探测并保留命中、回写和本地迁移语义', () async {
    final temp = await Directory.systemTemp.createTemp('konata_artwork_probe_');
    addTearDown(() => temp.delete(recursive: true));
    final db = KonataDatabaseBundle.openInMemory();
    addTearDown(db.close);
    final bus = InMemoryDomainEventBus();
    addTearDown(bus.dispose);
    final root = _TestStorageRoot(temp.path);
    final photos = PhotosStorage(storageRoot: root);
    final disk = ArtworkDiskCache(photosStorage: photos);
    final cache = _CountingArtworkCache(disk);
    final http = _ArtworkAuditHttp();
    final container = ProviderContainer(
      overrides: [
        featureLibraryDependenciesProvider.overrideWithValue(
          FeatureLibraryDependencies(
            databases: db,
            storageRoot: root,
            diagnosticLog: _FakeDiagnosticLog(),
            scopedPrefs: ScopedPrefsStore(db.userState),
            domainEventBus: bus,
            navigator: _FakeNavigator(),
            httpClient: http,
            photosStorage: photos,
            artworkCache: cache,
            platform: KonataPlatform.windows,
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    final loader = container.read(libraryArtworkLoaderProvider);
    const slot = PhotoSubfolder.posters;
    const owner = 'audit-owner';
    const remote = 'https://isolated.invalid/cover.png';
    const tmdb = '/audit-poster.png';
    final counts = <String, int>{};

    Future<Uint8List?> load(String path) =>
        loader(path, ownerWorkId: owner, subfolder: slot);

    // 首次未命中后请求一次，并持久化；后续加载直接复用同一字节对象。
    final first = await load(remote);
    expect(first, _samplePng);
    counts['remoteMiss'] = cache.reads;
    expect(http.requests, hasLength(1));
    expect(cache.writes, 1);
    expect(await load(remote), same(first));
    counts['remoteHit'] = cache.reads - counts['remoteMiss']!;
    expect(http.requests, hasLength(1));

    // 两层缓存保存的是同一个 Uint8List，而不是另外复制一份编码图。
    final thumbnail = KonataThumbnailByteLru();
    thumbnail.put(remote, first!);
    expect(
      thumbnail.get(remote),
      same(await disk.read('url:$remote', owner: owner, subfolder: slot)),
    );

    disk.clearMemoryCache();
    final cold = await load(remote);
    expect(cold, _samplePng);
    expect(identical(cold, first), isFalse);
    expect(
      await disk.read('url:$remote', owner: owner, subfolder: slot),
      same(cold),
    );
    expect(http.requests, hasLength(1));

    final tmdbStart = cache.reads;
    final tmdbBytes = await load(tmdb);
    expect(tmdbBytes, _samplePng);
    counts['tmdbMiss'] = cache.reads - tmdbStart;
    expect(http.requests, hasLength(2));
    expect(http.requests.last.path, endsWith('/w500/audit-poster.png'));
    final tmdbHitStart = cache.reads;
    expect(await load(tmdb), same(tmdbBytes));
    counts['tmdbHit'] = cache.reads - tmdbHitStart;
    expect(http.requests, hasLength(2));

    const corruptUrl = 'https://isolated.invalid/corrupt.png';
    await disk.write(
      'url:$corruptUrl',
      Uint8List.fromList('<html>not an image</html>'.codeUnits),
      owner: owner,
      subfolder: slot,
    );
    final corruptStart = cache.reads;
    expect(await load(corruptUrl), _samplePng);
    counts['corruptMiss'] = cache.reads - corruptStart;
    expect(http.requests, hasLength(3));

    final failureStart = cache.reads;
    expect(await load('https://isolated.invalid/failure.png'), isNull);
    counts['failedRemote'] = cache.reads - failureStart;
    expect(http.requests, hasLength(4));

    final file = File('${temp.path}/local.png')..writeAsBytesSync(_samplePng);
    final localStart = cache.localReads;
    expect(await load(file.path), _samplePng);
    expect(cache.localReads, localStart);
    final moved = await photos.writeArtwork(
      workId: owner,
      subfolder: slot,
      cacheKey: 'relocated',
      bytes: _samplePng,
      extension: '.png',
    );
    final name = moved.uri.pathSegments.last;
    expect(await load('${temp.path}/old/posters/$name'), _samplePng);
    counts['relocatedHit'] = cache.localReads - localStart;
    final missingStart = cache.localReads;
    expect(await load('${temp.path}/old/posters/missing.png'), isNull);
    counts['relocatedMiss'] = cache.localReads - missingStart;
    final emptyStart = cache.reads;
    expect(await load('  '), isNull);
    expect(cache.reads, emptyStart);
    expect(http.requests, hasLength(4));
    // 计数结果同时作为未命中冗余探测的可核查基线。
    expect(counts, {
      'remoteMiss': 1,
      'remoteHit': 1,
      'tmdbMiss': 1,
      'tmdbHit': 1,
      'corruptMiss': 1,
      'failedRemote': 1,
      'relocatedHit': 1,
      'relocatedMiss': 1,
    });
  });

  testWidgets('媒体库海报墙在四视口矩阵下零溢出且点击海报卡准确触发 openWorkDetail', (tester) async {
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

    const clearances = <double>[96, 0, 120, 0];
    for (final (index, viewport) in viewports.indexed) {
      final clearance = clearances[index];
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
                    KonataBottomClearanceScope(
                      bottomClearance: clearance,
                      child: LibraryPage(
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
      final grid = tester.widget<GridView>(find.byType(GridView));
      expect(
        grid.padding!.resolve(TextDirection.ltr).bottom,
        28 + clearance,
        reason: '黄金源底部留白应独立叠加胶囊避让',
      );
      final poster = tester.widget<ManagedImage>(find.byType(ManagedImage));
      expect(poster.ownerWorkId, 'w_wall_1');
      expect(poster.subfolder, PhotoSubfolder.posters);
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

  testWidgets('PosterCard 保持高速滚动惰性降载并在桌面顶栏搜索词注入时实时过滤', (tester) async {
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
    final scrolling = ValueNotifier(false);
    addTearDown(scrolling.dispose);
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
                scrollingListenable: scrolling,
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
    // 鼠标静止时滚动开始/结束必须直接驱动当前叶子，不能依赖整页刷新。
    scrolling.value = true;
    await tester.pumpAndSettle();
    expect(find.byType(BackdropFilter), findsNothing);
    scrolling.value = false;
    await tester.pumpAndSettle();
    expect(find.byType(BackdropFilter), findsOneWidget);
    await gesture.moveTo(Offset.zero);
    await tester.pumpAndSettle();
    scrolling.value = true;
    scrolling.value = false;
    await tester.pumpAndSettle();
    expect(find.byType(BackdropFilter), findsNothing);

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
    // 窄屏内联搜索恢复输入法组合保护与防抖契约。
    tester.view.physicalSize = const Size(390, 780);
    await tester.pumpAndSettle();
    final searchController = ProviderScope.containerOf(
      tester.element(find.byType(LibraryPage)),
    ).read(libraryControllerProvider);
    await tester.tap(find.byTooltip('搜索作品'));
    await tester.pumpAndSettle();
    final editable = find.byType(EditableText);
    expect(editable, findsOneWidget);
    await tester.showKeyboard(editable);
    await tester.enterText(editable, '轻');
    await tester.pump(const Duration(milliseconds: 50));
    expect(searchController.searchQuery, 'CLANNAD', reason: '内联搜索必须等待防抖');
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '轻音',
        selection: TextSelection.collapsed(offset: 2),
        composing: TextRange(start: 0, end: 2),
      ),
    );
    await tester.pump(const Duration(milliseconds: 250));
    expect(searchController.searchQuery, 'CLANNAD', reason: '输入法组合期间取消旧定时器');
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '轻音',
        selection: TextSelection.collapsed(offset: 2),
      ),
    );
    await tester.pump(const Duration(milliseconds: 149));
    expect(searchController.searchQuery, 'CLANNAD');
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pumpAndSettle();
    expect(searchController.searchQuery, '轻音');
    expect(find.byKey(const ValueKey<String>('w_k1')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('w_k2')), findsNothing);
    await tester.enterText(editable, '');
    await tester.pump();
    expect(searchController.searchQuery, '');
    await tester.enterText(editable, 'CLANNAD');
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.byTooltip('收起搜索'));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpAndSettle();
    expect(searchController.searchQuery, '');
    expect(find.byKey(const ValueKey<String>('w_k1')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('w_k2')), findsOneWidget);
  });

  testWidgets('媒体库顶栏与待复核中心经宿主分派作品管理动作', (tester) async {
    final tempRoot = Directory.systemTemp.createTempSync('konata_lib_modals_');
    addTearDown(() => tempRoot.deleteSync(recursive: true));
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
        id: 'src_modal',
        kind: MediaSourceKind.local,
        label: '本地源',
        location: 'D:/Anime',
      ),
    );
    await repo.upsertWork(
      const Work(
        id: 'w_m1',
        title: '轻音少女',
        year: 2009,
        bangumiScore: 8.6,
        scrapeStatus: ScrapeStatus.matched,
      ),
    );
    await repo.upsertWork(
      const Work(
        id: 'w_m2',
        title: 'CLANNAD',
        year: 2007,
        bangumiScore: 9.0,
        scrapeStatus: ScrapeStatus.matched,
      ),
    );
    await repo.upsertWork(
      const Work(
        id: 'w_hidden',
        title: '隐藏测试动画',
        year: 2020,
        scrapeStatus: ScrapeStatus.matched,
      ),
    );
    await repo.upsertWork(
      const Work(
        id: 'w_review',
        title: '未知新番文件夹',
        year: 2024,
        scrapeStatus: ScrapeStatus.needsReview,
        reviewReason: 'network_error:api_timeout',
      ),
    );
    await repo.upsertMediaVariant(
      const MediaVariant(
        id: 'var_hidden',
        workId: 'w_hidden',
        sourceId: 'src_modal',
        relativePath: 'HiddenDir/01.mkv',
        fileName: '01.mkv',
        fileSize: 2048,
      ),
    );
    await repo.upsertMediaVariant(
      const MediaVariant(
        id: 'var_rev',
        workId: 'w_review',
        sourceId: 'src_modal',
        relativePath: 'ReviewDir/01.mkv',
        fileName: '01.mkv',
        fileSize: 4096,
      ),
    );
    await repo.upsertMediaVariant(
      const MediaVariant(
        id: 'var_rev_cd',
        workId: 'w_review',
        sourceId: 'src_modal',
        relativePath: 'ReviewDir/CD/01.flac',
        fileName: '01.flac',
        fileSize: 1024,
        assetKind: AssetKind.cdAlbum,
      ),
    );
    await repo.saveScrapeCandidates('w_review', const <ScrapeCandidateSummary>[
      ScrapeCandidateSummary(
        workId: 'w_review',
        tmdbId: 101,
        mediaType: TmdbMediaType.tv,
        title: '待复核候选番剧',
        year: 2024,
        episodeCount: 12,
        score: 0.92,
        rank: 1,
        reasons: <String>['title_exact', 'year_match'],
      ),
    ]);

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
    final management = _FailOnceReviewManagement(
      databases: db,
      storageRoot: storageRoot,
      scopedPrefs: prefs,
      eventBus: eventBus,
      httpClient: deps.httpClient,
      photosStorage: photos,
    );
    final dialogs = _RecordingWorkDialogs();
    final toastController = KonataToastController();
    addTearDown(toastController.dispose);

    // 验证桌面 1440x900 顶栏待复核入口与统计胶囊。
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          featureLibraryDependenciesProvider.overrideWithValue(deps),
          workManagementControllerProvider.overrideWithValue(management),
          workManageDialogPortProvider.overrideWithValue(dialogs),
        ],
        child: MaterialApp(
          theme: KonataTheme.darkTheme(),
          home: KonataToastScope(
            controller: toastController,
            child: Scaffold(
              body: LibraryPage(
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
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('全部作品'), findsOneWidget);
    expect(find.byKey(const Key('library_works_count_pill')), findsOneWidget);
    expect(find.text('3 部'), findsOneWidget);
    expect(find.text('待复核 · 1'), findsOneWidget);
    expect(find.byIcon(Icons.visibility_off_outlined), findsNothing);
    expect(find.byKey(const ValueKey<String>('w_hidden')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('w_hidden')),
        matching: find.text('隐藏测试动画'),
      ),
      findsWidgets,
    );
    expect(tester.takeException(), isNull, reason: 'desktop wall');
    // 打开待复核队列，校验网络重试条、候选展开、源文件展示与多选限制及合并横屏适配。
    await tester.tap(find.text('待复核 · 1'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: 'review dialog');
    expect(find.text('待复核队列'), findsOneWidget);
    expect(management.summaryAttempts, 1);
    expect(find.text('复核信息读取失败'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    expect(management.summaryAttempts, 1);
    await tester.tap(find.text('重新读取'));
    await tester.pumpAndSettle();
    expect(management.summaryAttempts, 2);
    expect(find.text('复核信息读取失败'), findsNothing);
    expect(find.byType(KonataDraggableScrollbar), findsAtLeastNWidgets(2));
    expect(find.text('1 项'), findsOneWidget);
    expect(find.text('重试网络项 (1)'), findsOneWidget);

    await tester.tap(find.text('展开候选 (1)'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: 'review candidates');
    expect(find.text('TMDB #101'), findsOneWidget);
    expect(find.text('匹配度 92%'), findsOneWidget);

    await tester.tap(find.text('源文件'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('手动搜索'));
    await tester.pumpAndSettle();
    expect(dialogs.calls, [
      ('源文件', const WorkId.trusted('w_review')),
      ('手动搜索', const WorkId.trusted('w_review')),
    ]);
    await tester.tap(find.text('关闭').last);
    await tester.pumpAndSettle();

    // 验证手机端 390x780 内联展开搜索与紧凑复核胶囊。
    tester.view.physicalSize = const Size(390, 780);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: 'phone wall');
    expect(find.text('复核 1'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.search_rounded));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'CLANNAD');
    await tester.pump(KonataTheme.searchInputDebounce);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('w_m2')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('w_m1')), findsNothing);
    await tester.tap(find.byIcon(Icons.arrow_back_rounded));
    await tester.pumpAndSettle();
    expect(find.text('3 部'), findsOneWidget);
  });
}

final class _RecordingWorkDialogs implements WorkManageDialogPort {
  final calls = <(String, WorkId)>[];

  @override
  Future<bool> showManualMatchDialog(
    Object platformContext, {
    required WorkId workId,
    List<VariantId>? splitVariantIds,
  }) async {
    calls.add(('手动搜索', workId));
    return false;
  }

  @override
  Future<bool> showSourceFilesReviewDialog(
    Object platformContext, {
    required WorkId workId,
  }) async {
    calls.add(('源文件', workId));
    return false;
  }

  @override
  Future<bool> showWorkMergeDialog(
    Object platformContext, {
    required WorkId sourceWorkId,
    List<VariantId> variantIds = const [],
    String? dialogTitle,
  }) async {
    calls.add(('并入', sourceWorkId));
    return false;
  }
}

class _FailOnceReviewManagement extends WorkManagementController {
  _FailOnceReviewManagement({
    required super.databases,
    required super.storageRoot,
    required super.scopedPrefs,
    required super.eventBus,
    required super.httpClient,
    required super.photosStorage,
  });

  int summaryAttempts = 0;

  @override
  Future<Map<String, MediaSource>> loadSourcesById() async {
    summaryAttempts++;
    if (summaryAttempts == 1) throw StateError('注入一次读取失败');
    return super.loadSourcesById();
  }
}
