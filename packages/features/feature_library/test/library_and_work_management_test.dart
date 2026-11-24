import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:engine_scraping/engine_scraping.dart';
import 'package:feature_library/feature_library.dart';
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
    statusCode: 404,
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
  late Directory tempRoot;
  late KonataDatabaseBundle db;
  late ScopedPrefsStore prefs;
  late InMemoryDomainEventBus eventBus;
  late PhotosStorage photos;
  late StorageRootPort storageRoot;

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('konata_lib_mgmt_');
    db = KonataDatabaseBundle.openInMemory();
    prefs = ScopedPrefsStore(db.userState);
    eventBus = InMemoryDomainEventBus();
    storageRoot = _TestStorageRoot(tempRoot.path);
    photos = PhotosStorage(storageRoot: storageRoot);
  });

  tearDown(() async {
    await eventBus.dispose();
    await db.close();
    if (tempRoot.existsSync()) {
      tempRoot.deleteSync(recursive: true);
    }
  });

  test('LibraryController 多维筛选、排序持久化与跨源角标识别', () async {
    final repo = StorageScrapeRepository(db);
    await repo.upsertMediaSource(
      const MediaSource(
        id: 'src_local',
        kind: MediaSourceKind.local,
        label: '本地盘',
        location: 'D:/Anime',
      ),
    );
    await repo.upsertMediaSource(
      const MediaSource(
        id: 'src_dav',
        kind: MediaSourceKind.webdav,
        label: '云盘',
        location: 'https://dav.local/anime',
      ),
    );

    await repo.upsertWork(
      const Work(
        id: 'w_frieren_local',
        title: '葬送的芙莉莲',
        year: 2023,
        tmdbId: 209867,
        tmdbMediaType: TmdbMediaType.tv,
        matchedSeason: 1,
        bangumiScore: 8.6,
        scrapeStatus: ScrapeStatus.matched,
      ),
    );
    await repo.upsertMediaVariant(
      const MediaVariant(
        id: 'v_f1',
        workId: 'w_frieren_local',
        sourceId: 'src_local',
        relativePath: 'Frieren/[VCB-Studio] Frieren - 01.mkv',
        fileName: '[VCB-Studio] Frieren - 01.mkv',
        fileSize: 1000,
      ),
    );

    await repo.upsertWork(
      const Work(
        id: 'w_frieren_dav',
        title: '葬送的芙莉莲',
        year: 2023,
        tmdbId: 209867,
        tmdbMediaType: TmdbMediaType.tv,
        matchedSeason: 1,
        bangumiScore: 8.6,
        scrapeStatus: ScrapeStatus.matched,
      ),
    );
    await repo.upsertMediaVariant(
      const MediaVariant(
        id: 'v_f2',
        workId: 'w_frieren_dav',
        sourceId: 'src_dav',
        relativePath: 'Frieren/[SweetSub] Frieren - 01.mkv',
        fileName: '[SweetSub] Frieren - 01.mkv',
        fileSize: 1200,
      ),
    );

    await repo.upsertWork(
      const Work(
        id: 'w_hidden',
        title: '隐藏番剧',
        year: 2020,
        isHidden: true,
        scrapeStatus: ScrapeStatus.matched,
      ),
    );
    await repo.upsertWork(
      const Work(
        id: 'w_review',
        title: '待复核番剧',
        scrapeStatus: ScrapeStatus.needsReview,
      ),
    );

    final controller = LibraryController(
      databases: db,
      scopedPrefs: prefs,
      eventBus: eventBus,
    );
    await controller.reload();

    expect(controller.allVisibleItems.length, 2);
    expect(
      controller.allVisibleItems.every((e) => e.crossSourceBadgeLabel != null),
      isTrue,
    );
    expect(controller.hiddenWorks.map((w) => w.id), ['w_hidden']);
    expect(controller.reviewWorks.map((w) => w.id), ['w_review']);

    controller.setReleaseGroupFilter('VCB-Studio');
    expect(controller.displayedItems.map((e) => e.work.id), [
      'w_frieren_local',
    ]);

    controller.setSortMode(LibrarySortMode.score);
    controller.setSortOrder(LibrarySortOrder.descending);
    controller.dispose();

    final restored = LibraryController(
      databases: db,
      scopedPrefs: prefs,
      eventBus: eventBus,
      autoStart: false,
    );
    addTearDown(restored.dispose);
    expect(restored.prefs.sortMode, LibrarySortMode.score);
    expect(restored.prefs.sortOrder, LibrarySortOrder.descending);
    expect(restored.prefs.releaseGroupFilter, 'VCB-Studio');

    expect(restored.shouldEnableDesktopKeepAlive, isTrue);
    restored.setVideoPlaybackActive(true);
    expect(restored.shouldEnableDesktopKeepAlive, isFalse);
  });

  test('WorkManagementController 软删除仅清本地缓存与数据库墓碑，绝不触碰源文件', () async {
    final mediaDir = Directory('${tempRoot.path}/source_media/MyAnime');
    mediaDir.createSync(recursive: true);
    final videoFile = File('${mediaDir.path}/01.mkv');
    videoFile.writeAsStringSync('do-not-delete-user-media');

    await photos.writeArtwork(
      workId: 'w_del_1',
      subfolder: PhotoSubfolder.posters,
      cacheKey: 'poster.jpg',
      bytes: Uint8List.fromList([1, 2, 3]),
      title: '测试删除',
    );
    expect(
      await photos.readArtwork(
        workId: 'w_del_1',
        subfolder: PhotoSubfolder.posters,
        cacheKey: 'poster.jpg',
        title: '测试删除',
      ),
      isNotNull,
    );

    final repo = StorageScrapeRepository(db);
    await repo.upsertMediaSource(
      MediaSource(
        id: 'src_del',
        kind: MediaSourceKind.local,
        label: '本地源',
        location: '${tempRoot.path}/source_media',
      ),
    );
    await repo.upsertWork(
      const Work(
        id: 'w_del_1',
        title: '测试删除',
        scrapeStatus: ScrapeStatus.matched,
      ),
    );
    await repo.upsertEpisode(
      const Episode(
        id: 'ep_del_1',
        workId: 'w_del_1',
        seasonNumber: 1,
        episodeNumber: 1,
      ),
    );
    await repo.upsertMediaVariant(
      const MediaVariant(
        id: 'var_del_1',
        workId: 'w_del_1',
        episodeId: 'ep_del_1',
        sourceId: 'src_del',
        relativePath: 'MyAnime/01.mkv',
        fileName: '01.mkv',
        fileSize: 24,
      ),
    );

    final mgmt = WorkManagementController(
      databases: db,
      storageRoot: storageRoot,
      scopedPrefs: prefs,
      eventBus: eventBus,
      httpClient: _FakeHttpClient(),
      photosStorage: photos,
      nowMs: () => 99999,
    );

    final workEvents = <LibraryWorkChangedEvent>[];
    final sub = eventBus.on<LibraryWorkChangedEvent>().listen(workEvents.add);
    addTearDown(() => unawaited(sub.cancel()));

    await mgmt.deleteWork('w_del_1', ignoreFolderOnRescan: true);
    await Future<void>.delayed(Duration.zero);

    expect(await repo.findWorkById('w_del_1'), isNull);
    expect(await repo.getIgnoredFolders('src_del'), ['MyAnime']);
    expect(workEvents.any((e) => e.reason == 'deleted'), isTrue);

    expect(
      await photos.readArtwork(
        workId: 'w_del_1',
        subfolder: PhotoSubfolder.posters,
        cacheKey: 'poster.jpg',
        title: '测试删除',
      ),
      isNull,
    );
    expect(
      db.library.works.listAll(includeDeleted: true).first.deletedAtMs,
      99999,
    );
    expect(videoFile.existsSync(), isTrue);
    expect(videoFile.readAsStringSync(), 'do-not-delete-user-media');
  });

  test('作品合并与手动 Bangumi 绑定写入锁定标记并清空复核状态', () async {
    final repo = StorageScrapeRepository(db);
    await repo.upsertMediaSource(
      const MediaSource(
        id: 'src_m',
        kind: MediaSourceKind.local,
        label: '本地',
        location: 'D:/Anime',
      ),
    );
    await repo.upsertWork(
      const Work(
        id: 'w_target',
        title: '目标作品',
        scrapeStatus: ScrapeStatus.matched,
      ),
    );
    await repo.upsertWork(
      const Work(
        id: 'w_source',
        title: '待并入分集',
        year: 2024,
        bangumiScore: 8.1,
        scrapeStatus: ScrapeStatus.needsReview,
        reviewReason: 'ambiguous_candidates',
      ),
    );
    await repo.upsertEpisode(
      const Episode(
        id: 'ep_s2',
        workId: 'w_source',
        seasonNumber: 1,
        episodeNumber: 2,
        title: '第 02 话',
      ),
    );
    await repo.upsertMediaVariant(
      const MediaVariant(
        id: 'var_s2',
        workId: 'w_source',
        episodeId: 'ep_s2',
        sourceId: 'src_m',
        relativePath: 'Target/02.mkv',
        fileName: '02.mkv',
        fileSize: 500,
      ),
    );

    final mgmt = WorkManagementController(
      databases: db,
      storageRoot: storageRoot,
      scopedPrefs: prefs,
      eventBus: eventBus,
      httpClient: _FakeHttpClient(),
      photosStorage: photos,
      nowMs: () => 77777,
    );

    final outcome = await mgmt.mergeWorkIntoTarget(
      sourceWorkId: 'w_source',
      targetWorkId: 'w_target',
    );
    expect(outcome.movedVariantCount, 1);
    expect(outcome.sourceDeleted, isTrue);
    expect(outcome.targetWork.isManualLocked, isTrue);
    expect(outcome.targetWork.bangumiScore, 8.1);
    expect(await repo.findWorkById('w_source'), isNull);

    final targetVariants = await repo.getVariantsByWork('w_target');
    expect(targetVariants.length, 1);
    expect(targetVariants.first.workLocked, isTrue);

    await mgmt.bindWorkBangumiOnly(
      workId: 'w_target',
      bangumiSubject: const BangumiSubjectCandidate(
        id: 400123,
        name: 'Original Title',
        nameCn: '手工锁定新标题',
        year: 2024,
        score: 8.5,
      ),
    );
    final rebound = await repo.findWorkById('w_target');
    expect(rebound!.isManualLocked, isTrue);
    expect(rebound.bangumiId, 400123);
    expect(rebound.title, '手工锁定新标题');
    expect(rebound.scrapeStatus, ScrapeStatus.matched);
  });
}
