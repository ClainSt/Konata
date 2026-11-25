import 'dart:async';
import 'dart:io';

import 'package:engine_scraping/engine_scraping.dart';
import 'package:engine_sources/engine_sources.dart';
import 'package:feature_sources/feature_sources.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';

class _FakeGateway implements MediaSourceGateway {
  _FakeGateway({
    this.testConnectionError,
    this.entries = const <RemoteEntry>[],
  });

  final String? testConnectionError;
  final List<RemoteEntry> entries;
  int listCalls = 0;
  int closeCalls = 0;

  @override
  Future<void> close() async {
    closeCalls++;
  }

  @override
  Future<List<RemoteEntry>> listDirectory(String relativePath) async {
    listCalls++;
    return entries;
  }

  @override
  Future<String?> readTextFile(
    String relativePath, {
    int maxBytes = 256 * 1024,
  }) async => null;

  @override
  Future<String?> testConnection() async => testConnectionError;
}

class _FakeGatewayFactory implements MediaSourceGatewayFactoryPort {
  _FakeGatewayFactory(this._builder);

  final MediaSourceGateway Function(
    MediaSourceView source,
    String? passwordOverride,
    bool clearPassword,
  )
  _builder;

  String? lastPasswordOverride;

  @override
  Future<MediaSourceGateway> create(
    MediaSourceView source, {
    String? passwordOverride,
    bool clearPassword = false,
  }) async {
    lastPasswordOverride = passwordOverride;
    return _builder(source, passwordOverride, clearPassword);
  }
}

void main() {
  late KonataDatabaseBundle db;
  late InMemorySecureStorage secureStorage;
  late SourceCredentialStore credentialStore;
  late ScopedPrefsStore prefs;
  late InMemoryDomainEventBus eventBus;

  setUp(() {
    db = KonataDatabaseBundle.openInMemory();
    secureStorage = InMemorySecureStorage();
    credentialStore = SourceCredentialStore(storage: secureStorage);
    prefs = ScopedPrefsStore(db.userState);
    eventBus = InMemoryDomainEventBus();
  });

  tearDown(() async {
    await eventBus.dispose();
    await db.close();
  });

  test('1246 项大目录往返复用同一浏览网关，关闭后重新读取', () async {
    final gateways = <_FakeGateway>[];
    final entries = List.generate(
      1246,
      (i) => RemoteEntry(
        name: 'Anime $i',
        relativePath: 'Anime $i',
        isDirectory: true,
        size: 0,
      ),
    );
    final controller = SourcesController(
      databases: db,
      credentialStore: credentialStore,
      eventBus: eventBus,
      scopedPrefs: prefs,
      gatewayFactory: _FakeGatewayFactory((source, pwd, clear) {
        final gateway = _FakeGateway(entries: entries);
        gateways.add(gateway);
        return gateway;
      }),
    );
    addTearDown(controller.dispose);
    Future<SourceDirectoryBrowseSession> open() =>
        controller.openDirectoryBrowseSession(
          kind: MediaSourceKind.cloudDrive,
          location: 'guangyapan://account_fixture',
        );
    final session = await open();
    addTearDown(session.close);
    final first = await session.listDirectory('Anime', includeFiles: true);
    await session.listDirectory('', includeFiles: true);
    final cached = await session.listDirectory('Anime', includeFiles: true);
    expect(first.length, 1246);
    expect(identical(first, cached), isTrue);
    expect(gateways.length, 1);
    expect(gateways.single.listCalls, 2);
    await session.close();
    expect(gateways.single.closeCalls, 1);
    await expectLater(session.listDirectory('Anime'), throwsStateError);
    final refreshed = await open();
    addTearDown(refreshed.close);
    expect(
      (await refreshed.listDirectory('Anime', includeFiles: true)).length,
      1246,
    );
    expect(gateways.length, 2);
    expect(gateways.last.listCalls, 1);
  });

  test('目录浏览缓存受条目和目录数量限制', () async {
    final gateway = _FakeGateway(
      entries: List.generate(
        1246,
        (i) => RemoteEntry(
          name: 'Anime $i',
          relativePath: 'Anime $i',
          isDirectory: true,
          size: 0,
        ),
      ),
    );
    final session = SourceDirectoryBrowseSession(gateway);
    addTearDown(session.close);
    for (var i = 0; i < 10; i++) {
      await session.listDirectory('folder$i', includeFiles: true);
    }
    expect(gateway.listCalls, 10);
    await session.listDirectory('folder9', includeFiles: true);
    expect(gateway.listCalls, 10);
    await session.listDirectory('folder0', includeFiles: true);
    expect(gateway.listCalls, 11);
  });

  test('媒体源校验拒绝无效地址并隔离凭据（密码绝不写入 SQLite）', () async {
    final gatewayFactory = _FakeGatewayFactory(
      (source, pwd, clear) => _FakeGateway(),
    );
    final controller = SourcesController(
      databases: db,
      credentialStore: credentialStore,
      gatewayFactory: gatewayFactory,
      eventBus: eventBus,
      scopedPrefs: prefs,
      nowMs: () => 1000,
    );
    addTearDown(controller.dispose);

    final badLabel = await controller.saveSource(
      kind: MediaSourceKind.local,
      label: '   ',
      location: 'D:/Anime',
    );
    expect(badLabel.success, isFalse);

    final badWebDav = await controller.saveSource(
      kind: MediaSourceKind.webdav,
      label: '网盘',
      location: 'ftp://example.com/dav',
    );
    expect(badWebDav.success, isFalse);

    final badSmb = await controller.saveSource(
      kind: MediaSourceKind.smb,
      label: '局域网',
      location: 'smb://192.168.1.2/../secret',
    );
    expect(badSmb.success, isFalse);

    final events = <MediaSourceChangedEvent>[];
    final sub = eventBus.on<MediaSourceChangedEvent>().listen(events.add);
    addTearDown(() => unawaited(sub.cancel()));

    final created = await controller.saveSource(
      kind: MediaSourceKind.webdav,
      label: '极空间 WebDAV',
      location: 'https://nas.local:5006/anime/',
      username: 'otaku',
      password: 'top-secret-password',
      includedFolders: const ['2024', '/2025/'],
    );
    expect(created.success, isTrue);
    final src = created.source!;

    expect(await controller.readSavedPassword(src.id), 'top-secret-password');
    final sqliteRows = db.library.engine.select(
      'SELECT * FROM media_sources WHERE id = ?;',
      <Object?>[src.id],
    );
    expect(sqliteRows.length, 1);
    expect(sqliteRows.first.values.join('|'), isNot(contains('top-secret')));

    expect(controller.readIncludedFolders(src.id), ['2024', '2025']);

    final dup = await controller.saveSource(
      kind: MediaSourceKind.webdav,
      label: '重复网盘',
      location: 'https://nas.local:5006/anime',
    );
    expect(dup.success, isFalse);

    await controller.saveSource(
      existingId: src.id,
      kind: MediaSourceKind.webdav,
      label: '极空间新版',
      location: src.location,
      username: 'otaku2',
      password: '',
    );
    expect(await controller.readSavedPassword(src.id), 'top-secret-password');

    await controller.saveSource(
      existingId: src.id,
      kind: MediaSourceKind.webdav,
      label: '极空间匿名版',
      location: src.location,
      clearPassword: true,
    );
    expect(await controller.readSavedPassword(src.id), isNull);

    await Future<void>.delayed(Duration.zero);
    expect(events.map((e) => e.reason), ['created', 'updated', 'updated']);
  });

  test('光鸭新源需授权且不保存普通密码，编辑禁止替换绑定', () async {
    var authorized = false;
    final gatewayFactory = _FakeGatewayFactory((source, pwd, clear) {
      expect(source.username, isNull);
      expect(pwd, isNull);
      return _FakeGateway(testConnectionError: authorized ? null : '本机未授权');
    });
    final controller = SourcesController(
      databases: db,
      credentialStore: credentialStore,
      gatewayFactory: gatewayFactory,
      eventBus: eventBus,
      scopedPrefs: prefs,
    );
    addTearDown(controller.dispose);
    final denied = await controller.saveSource(
      kind: MediaSourceKind.cloudDrive,
      label: '光鸭',
      location: 'guangyapan://account_a',
    );
    expect(denied.success, isFalse);
    expect(await StorageScrapeRepository(db).getMediaSources(), isEmpty);
    authorized = true;
    final added = await controller.saveSource(
      kind: MediaSourceKind.cloudDrive,
      label: '光鸭',
      location: 'guangyapan://account_a',
      username: 'should-not-save',
      password: 'should-not-save',
      includedFolders: const ['Anime'],
    );
    expect(added.success, isTrue);
    final id = added.source!.id;
    expect(added.source!.username, isNull);
    expect(await controller.readSavedPassword(id), isNull);
    expect(controller.readIncludedFolders(id), ['Anime']);
    final rebound = await controller.saveSource(
      existingId: id,
      kind: MediaSourceKind.cloudDrive,
      label: '替换绑定',
      location: 'guangyapan://account_b',
    );
    expect(rebound.success, isFalse);
    final converted = await controller.saveSource(
      existingId: id,
      kind: MediaSourceKind.local,
      label: '替换类型',
      location: 'D:/Anime',
    );
    expect(converted.success, isFalse);
    final edited = await controller.saveSource(
      existingId: id,
      kind: MediaSourceKind.cloudDrive,
      label: '新名称',
      location: 'guangyapan://account_a',
    );
    expect(edited.success, isTrue);
    expect(edited.source!.label, '新名称');
  });

  test('云盘留空自动编号，保留已有名称与账号地址', () async {
    final repo = StorageScrapeRepository(db);
    final legacyId = 'gya_' + List.filled(64, 'a').join();
    await repo.upsertMediaSource(
      MediaSource(
        id: 'legacy_cloud',
        kind: MediaSourceKind.cloudDrive,
        label: legacyId,
        location: 'guangyapan://$legacyId',
      ),
    );
    final controller = SourcesController(
      databases: db,
      credentialStore: credentialStore,
      gatewayFactory: _FakeGatewayFactory(
        (source, pwd, clear) => _FakeGateway(),
      ),
      eventBus: eventBus,
      scopedPrefs: prefs,
    );
    addTearDown(controller.dispose);
    for (var i = 2; i <= 3; i++) {
      final result = await controller.saveSource(
        kind: MediaSourceKind.cloudDrive,
        label: ' ',
        location: 'guangyapan://account_$i',
      );
      expect(result.success, isTrue);
      expect(result.source!.label, '云盘$i');
    }
    final custom = await controller.saveSource(
      kind: MediaSourceKind.cloudDrive,
      label: '收藏归档',
      location: 'guangyapan://account_custom',
    );
    expect(custom.source!.label, '收藏归档');
    final sources = await repo.getMediaSources();
    expect(sources.firstWhere((s) => s.id == 'legacy_cloud').label, legacyId);
    expect(
      sources.firstWhere((s) => s.id == 'legacy_cloud').location,
      'guangyapan://$legacyId',
    );
    final next = await controller.saveSource(
      kind: MediaSourceKind.cloudDrive,
      label: '',
      location: 'guangyapan://account_next',
    );
    expect(next.source!.label, '云盘4');
  });

  test('目录列举使用本地自然排序且忽略隐藏目录，连通测试自动脱敏密码', () async {
    final gatewayFactory = _FakeGatewayFactory(
      (source, pwd, clear) => _FakeGateway(
        testConnectionError: '连接超时 password=mySecret123',
        entries: const [
          RemoteEntry(
            name: '.Trash',
            relativePath: '.Trash',
            isDirectory: true,
          ),
          RemoteEntry(
            name: 'Season 10',
            relativePath: 'Season 10',
            isDirectory: true,
          ),
          RemoteEntry(
            name: 'Season 2',
            relativePath: 'Season 2',
            isDirectory: true,
          ),
          RemoteEntry(
            name: 'readme.txt',
            relativePath: 'readme.txt',
            isDirectory: false,
          ),
        ],
      ),
    );
    final controller = SourcesController(
      databases: db,
      credentialStore: credentialStore,
      gatewayFactory: gatewayFactory,
      eventBus: eventBus,
    );
    addTearDown(controller.dispose);

    final testRes = await controller.testConnection(
      kind: MediaSourceKind.webdav,
      location: 'https://dav.example.com/anime',
      password: 'mySecret123',
    );
    expect(testRes.success, isFalse);
    expect(testRes.message, isNot(contains('mySecret123')));
    expect(gatewayFactory.lastPasswordOverride, 'mySecret123');

    final dirs = await controller.listDirectory(
      kind: MediaSourceKind.webdav,
      location: 'https://dav.example.com/anime',
    );
    expect(dirs.map((d) => d.name), ['Season 2', 'Season 10']);

    final allEntries = await controller.listDirectory(
      kind: MediaSourceKind.webdav,
      location: 'https://dav.example.com/anime',
      includeFiles: true,
    );
    expect(allEntries.map((e) => e.name), [
      'Season 2',
      'Season 10',
      'readme.txt',
    ]);
  });

  test('媒体源统计流准确聚合关联作品数、视频数与待复核条目数', () async {
    final gatewayFactory = _FakeGatewayFactory((_, _, _) => _FakeGateway());
    final controller = SourcesController(
      databases: db,
      credentialStore: credentialStore,
      gatewayFactory: gatewayFactory,
      eventBus: eventBus,
      scopedPrefs: prefs,
      nowMs: () => 2000,
    );
    addTearDown(controller.dispose);

    final created = await controller.saveSource(
      kind: MediaSourceKind.local,
      label: '统计验证盘',
      location: 'D:/StatsAnime',
    );
    final source = created.source!;

    final repo = StorageScrapeRepository(db);
    await repo.upsertWork(
      const Work(
        id: 'w_stats_1',
        title: '已匹配作品',
        scrapeStatus: ScrapeStatus.matched,
      ),
    );
    await repo.upsertWork(
      const Work(
        id: 'w_stats_2',
        title: '待复核作品',
        scrapeStatus: ScrapeStatus.needsReview,
      ),
    );
    await repo.upsertMediaVariant(
      MediaVariant(
        id: 'v_stats_1',
        workId: 'w_stats_1',
        sourceId: source.id,
        relativePath: '01.mkv',
        fileName: '01.mkv',
        fileSize: 100,
      ),
    );
    await repo.upsertMediaVariant(
      MediaVariant(
        id: 'v_stats_2',
        workId: 'w_stats_2',
        sourceId: source.id,
        relativePath: '02.mkv',
        fileName: '02.mkv',
        fileSize: 200,
      ),
    );
    await repo.upsertMediaVariant(
      MediaVariant(
        id: 'v_stats_3',
        workId: 'w_stats_1',
        sourceId: source.id,
        relativePath: 'Scans/01.jpg',
        fileName: '01.jpg',
        fileSize: 50,
        assetKind: AssetKind.scanGallery,
      ),
    );

    final statsMap = await controller.watchSourceStats().first;
    final stats = statsMap[source.id];
    expect(stats, isNotNull);
    expect(stats!.workCount, 2);
    expect(stats.videoCount, 2);
    expect(stats.totalFileCount, 3);
    expect(stats.reviewCount, 1);
  });

  test('移除媒体源写入软删除墓碑与清凭据，严禁删除物理媒体文件', () async {
    final tempDir = Directory.systemTemp.createTempSync('konata_src_ro_');
    addTearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });
    final physicalFile = File('${tempDir.path}/episode01.mkv');
    physicalFile.writeAsStringSync('keep-user-media-safe');

    final gatewayFactory = _FakeGatewayFactory((_, _, _) => _FakeGateway());
    final controller = SourcesController(
      databases: db,
      credentialStore: credentialStore,
      gatewayFactory: gatewayFactory,
      eventBus: eventBus,
      scopedPrefs: prefs,
      nowMs: () => 5000,
    );
    addTearDown(controller.dispose);

    final saved = await controller.saveSource(
      kind: MediaSourceKind.local,
      label: '只读盘',
      location: tempDir.path,
    );
    final source = saved.source!;
    await controller.addIgnoredFolder(source.id, 'SP');

    final repo = StorageScrapeRepository(db);
    await repo.upsertWork(
      const Work(
        id: 'w_ro_1',
        title: '轻音少女',
        scrapeStatus: ScrapeStatus.matched,
      ),
    );
    await repo.upsertEpisode(
      const Episode(
        id: 'ep_ro_1',
        workId: 'w_ro_1',
        seasonNumber: 1,
        episodeNumber: 1,
      ),
    );
    await repo.upsertMediaVariant(
      MediaVariant(
        id: 'var_ro_1',
        workId: 'w_ro_1',
        episodeId: 'ep_ro_1',
        sourceId: source.id,
        relativePath: 'episode01.mkv',
        fileName: 'episode01.mkv',
        fileSize: physicalFile.lengthSync(),
      ),
    );

    final workEvents = <LibraryWorkChangedEvent>[];
    final workSub = eventBus.on<LibraryWorkChangedEvent>().listen(
      workEvents.add,
    );
    addTearDown(() => unawaited(workSub.cancel()));

    await controller.deleteSource(source.id);
    await Future<void>.delayed(Duration.zero);

    expect(await controller.listSources(), isEmpty);
    expect(await controller.listIgnoredFolders(source.id), isEmpty);
    expect(await repo.getAllWorks(), isEmpty);
    expect(await repo.getAllVariants(), isEmpty);
    expect(workEvents.any((e) => e.workId.value == 'w_ro_1'), isTrue);

    final tombstoned = db.library.mediaSources.listAll(includeDeleted: true);
    expect(tombstoned.length, 1);
    expect(tombstoned.first.deletedAtMs, 5000);
    expect(physicalFile.existsSync(), isTrue);
    expect(physicalFile.readAsStringSync(), 'keep-user-media-safe');
  });
}
