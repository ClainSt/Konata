import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:engine_scraping/engine_scraping.dart';
import 'package:feature_sources/feature_sources.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:konata_contracts/konata_contracts.dart';
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

class _FakeHttpClient implements KonataHttpClientPort {
  KonataNetworkConfig _config = const KonataNetworkConfig(
    credential: 'fake-tmdb-key',
  );

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
  }) async {
    return KonataHttpResponse(
      statusCode: 200,
      headers: const <String, String>{},
      bodyBytes: Uint8List(0),
    );
  }

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

class _FakeGatewayFactory implements MediaSourceGatewayFactoryPort {
  @override
  Future<MediaSourceGateway> create(
    MediaSourceView source, {
    String? passwordOverride,
    bool clearPassword = false,
  }) async {
    throw UnimplementedError();
  }
}

class _StubScrapePipeline extends ScrapePipeline {
  _StubScrapePipeline({
    required super.repository,
    required KonataHttpClientPort httpClient,
    required this.behavior,
  }) : _repo = repository,
       super(
         tmdbService: TmdbService(httpClient: httpClient),
         gatewayBuilder: (_) => throw UnimplementedError(),
       );

  final LibraryRepository _repo;
  final Future<ScrapeProgress> Function(
    LibraryRepository repo,
    MediaSource source,
    bool Function()? isCancelled,
    ScrapeProgressListener? onProgress,
    ScrapeWorkPersistedListener? onWorkPersisted,
  )
  behavior;

  @override
  Future<ScrapeProgress> scanAndScrapeSource(
    MediaSource source, {
    List<String>? scanRootsOverride,
    bool Function()? isCancelled,
    ScrapeProgressListener? onProgress,
    ScrapeWorkPersistedListener? onWorkPersisted,
  }) {
    return behavior(_repo, source, isCancelled, onProgress, onWorkPersisted);
  }
}

void main() {
  late Directory tempRoot;
  late KonataDatabaseBundle db;
  late ScopedPrefsStore prefs;
  late InMemoryDomainEventBus eventBus;
  late _FakeHttpClient httpClient;

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('konata_scrape_ctrl_');
    db = KonataDatabaseBundle.openInMemory();
    prefs = ScopedPrefsStore(db.userState);
    eventBus = InMemoryDomainEventBus();
    httpClient = _FakeHttpClient();
  });

  tearDown(() async {
    await eventBus.dispose();
    await db.close();
    if (tempRoot.existsSync()) {
      tempRoot.deleteSync(recursive: true);
    }
  });

  test('扫库状态机完整流转、记录上次扫描时间并广播领域事件', () async {
    const source = MediaSource(
      id: 'src_1',
      kind: MediaSourceKind.local,
      label: '本地动画库',
      location: 'D:/Anime',
    );
    await StorageScrapeRepository(db).upsertMediaSource(source);

    final phases = <ScrapeTaskStage>[];
    final controller = SourceScrapeController(
      databases: db,
      storageRoot: _TestStorageRoot(tempRoot.path),
      scopedPrefs: prefs,
      eventBus: eventBus,
      httpClient: httpClient,
      gatewayFactory: _FakeGatewayFactory(),
      nowMs: () => 88000,
      mappingLoaderOverride: () async => null,
      pipelineBuilder: ({required repository, required mappingIndex}) =>
          _StubScrapePipeline(
            repository: repository,
            httpClient: httpClient,
            behavior:
                (repo, src, isCancelled, onProgress, onWorkPersisted) async {
                  onProgress?.call(
                    ScrapeProgress(
                      phase: ScrapePhase.scanning,
                      sourceId: src.id,
                      sourceLabel: src.label,
                      currentItemName: '孤独摇滚',
                      scannedDirectories: 2,
                      foundFiles: 12,
                    ),
                  );
                  await repo.upsertWork(
                    const Work(
                      id: 'w_bocchi',
                      title: '孤独摇滚！',
                      scrapeStatus: ScrapeStatus.matched,
                    ),
                  );
                  onProgress?.call(
                    ScrapeProgress(
                      phase: ScrapePhase.scraping,
                      sourceId: src.id,
                      sourceLabel: src.label,
                      currentItemName: '孤独摇滚！',
                      scannedDirectories: 2,
                      foundFiles: 12,
                      totalWorks: 1,
                      processedWorks: 1,
                      matchedWorks: 1,
                    ),
                  );
                  onWorkPersisted?.call(
                    'w_bocchi',
                    ScrapeStatus.matched,
                    '孤独摇滚！',
                  );
                  return ScrapeProgress(
                    phase: ScrapePhase.completed,
                    sourceId: src.id,
                    sourceLabel: src.label,
                    scannedDirectories: 2,
                    foundFiles: 12,
                    totalWorks: 1,
                    processedWorks: 1,
                    matchedWorks: 1,
                  );
                },
          ),
    );
    controller.addListener(() => phases.add(controller.phase.stage));
    addTearDown(controller.dispose);

    final workEvents = <LibraryWorkChangedEvent>[];
    final sub = eventBus.on<LibraryWorkChangedEvent>().listen(workEvents.add);
    addTearDown(() => unawaited(sub.cancel()));

    await expectLater(
      controller.scanSource(source, scanRootsOverride: const []),
      throwsArgumentError,
    );
    await expectLater(
      controller.scanSource(source, scanRootsOverride: const ['/']),
      throwsArgumentError,
    );
    await expectLater(
      controller.scanSource(source, scanRootsOverride: const ['../outside']),
      throwsArgumentError,
    );
    final terminal = await controller.scanSource(
      source,
      scanRootsOverride: const ['2024'],
    );
    await Future<void>.delayed(Duration.zero);

    expect(terminal, isA<ScrapeCompletedPhase>());
    expect(terminal.matchedWorks, 1);
    expect(
      phases,
      containsAllInOrder([
        ScrapeTaskStage.checkingIndex,
        ScrapeTaskStage.scanning,
        ScrapeTaskStage.running,
        ScrapeTaskStage.completed,
      ]),
    );
    expect(
      SourceScopePrefs.readLastScannedAt(
        prefs,
        source.id,
      )?.millisecondsSinceEpoch,
      88000,
    );
    expect(workEvents.any((e) => e.workId.value == 'w_bocchi'), isTrue);
  });

  test('主动取消扫描会标记 cancelRequested 并落入 ScrapeCancelledPhase', () async {
    const source = MediaSource(
      id: 'src_cancel',
      kind: MediaSourceKind.local,
      label: '取消验证源',
      location: 'D:/Anime2',
    );
    final enteredScrape = Completer<void>();
    final allowFinish = Completer<void>();

    final controller = SourceScrapeController(
      databases: db,
      storageRoot: _TestStorageRoot(tempRoot.path),
      scopedPrefs: prefs,
      eventBus: eventBus,
      httpClient: httpClient,
      gatewayFactory: _FakeGatewayFactory(),
      mappingLoaderOverride: () async => null,
      pipelineBuilder: ({required repository, required mappingIndex}) =>
          _StubScrapePipeline(
            repository: repository,
            httpClient: httpClient,
            behavior:
                (repo, src, isCancelled, onProgress, onWorkPersisted) async {
                  onProgress?.call(
                    ScrapeProgress(
                      phase: ScrapePhase.scraping,
                      sourceId: src.id,
                      sourceLabel: src.label,
                      totalWorks: 5,
                      processedWorks: 1,
                    ),
                  );
                  enteredScrape.complete();
                  await allowFinish.future;
                  return ScrapeProgress(
                    phase: (isCancelled?.call() ?? false)
                        ? ScrapePhase.cancelled
                        : ScrapePhase.completed,
                    sourceId: src.id,
                    sourceLabel: src.label,
                    totalWorks: 5,
                    processedWorks: 1,
                  );
                },
          ),
    );
    addTearDown(controller.dispose);

    final scanFuture = controller.scanSource(
      source,
      scanRootsOverride: const ['2024'],
    );
    await enteredScrape.future;

    controller.cancelActiveScan();
    expect(controller.phase.cancelRequested, isTrue);

    allowFinish.complete();
    final terminal = await scanFuture;
    expect(terminal, isA<ScrapeCancelledPhase>());
  });

  test('本源待复核隔离查询仅返回属于指定媒体源的 needsReview 作品', () async {
    final repo = StorageScrapeRepository(db);
    await repo.upsertMediaSource(
      const MediaSource(
        id: 'src_alpha',
        kind: MediaSourceKind.local,
        label: '源 A',
        location: 'D:/Alpha',
      ),
    );
    await repo.upsertMediaSource(
      const MediaSource(
        id: 'src_beta',
        kind: MediaSourceKind.local,
        label: '源 B',
        location: 'D:/Beta',
      ),
    );
    await repo.upsertWork(
      const Work(
        id: 'w_rev_1',
        title: '待复核作品 A',
        scrapeStatus: ScrapeStatus.needsReview,
        reviewReason: 'ambiguous_candidates',
      ),
    );
    await repo.upsertMediaVariant(
      const MediaVariant(
        id: 'v_rev_1',
        workId: 'w_rev_1',
        sourceId: 'src_alpha',
        relativePath: 'AnimeA/01.mkv',
        fileName: '01.mkv',
        fileSize: 100,
      ),
    );
    await repo.upsertWork(
      const Work(
        id: 'w_rev_2',
        title: '待复核作品 B',
        scrapeStatus: ScrapeStatus.needsReview,
      ),
    );
    await repo.upsertMediaVariant(
      const MediaVariant(
        id: 'v_rev_2',
        workId: 'w_rev_2',
        sourceId: 'src_beta',
        relativePath: 'AnimeB/01.mkv',
        fileName: '01.mkv',
        fileSize: 100,
      ),
    );

    final controller = SourceScrapeController(
      databases: db,
      storageRoot: _TestStorageRoot(tempRoot.path),
      scopedPrefs: prefs,
      eventBus: eventBus,
      httpClient: httpClient,
      gatewayFactory: _FakeGatewayFactory(),
    );
    addTearDown(controller.dispose);

    final alphaItems = await controller.listNeedsReviewForSource('src_alpha');
    expect(alphaItems.length, 1);
    expect(alphaItems.first.work.id, 'w_rev_1');
    expect(alphaItems.first.sampleRelativePath, 'AnimeA/01.mkv');
  });

  test('ScrapeTaskPhase 准确投影归组状态、已扫目录视频统计及根作用域计数', () async {
    final phase = ScrapeTaskPhase.fromProgress(
      const ScrapeProgress(
        phase: ScrapePhase.grouping,
        sourceId: 'src_group',
        sourceLabel: '归组测试源',
        currentItemName: 'BDRip 解析',
        scannedDirectories: 3,
        foundFiles: 15,
        selectedRoots: <String>['2024', 'OVA'],
        folderVideoCounts: <String, int>{
          '2024/Frieren': 12,
          '2024/Bocchi': 6,
          'OVA/Special': 2,
        },
        completedFolders: <String>{'2024/Frieren'},
      ),
    );

    expect(phase, isA<ScrapeScanningPhase>());
    expect((phase as ScrapeScanningPhase).isGrouping, isTrue);
    expect(phase.totalVideos, 20);
    expect(phase.videosUnderRoot('2024'), 18);
    expect(phase.videosUnderRoot('OVA'), 2);
    expect(phase.visitedFolders, [
      '2024/Bocchi',
      '2024/Frieren',
      'OVA/Special',
    ]);
    expect(phase.statusLabel, contains('归组'));

    final controller = SourceScrapeController(
      databases: db,
      storageRoot: _TestStorageRoot(tempRoot.path),
      scopedPrefs: prefs,
      eventBus: eventBus,
      httpClient: httpClient,
      gatewayFactory: _FakeGatewayFactory(),
    );
    addTearDown(controller.dispose);
    expect(await controller.runOngoingWorksAutoSyncIfDue(), 0);
  });
}
