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

  @override
  Future<void> close() async {}

  @override
  Future<List<RemoteEntry>> listDirectory(String relativePath) async {
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
