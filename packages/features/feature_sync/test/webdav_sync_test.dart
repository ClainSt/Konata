import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:feature_sync/feature_sync.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';

/// 内存态伪 WebDAV 服务器（支持 MKCOL、GET、PUT、Digest 质询重放与按文件路径精确统计流量）。
final class _InMemoryWebDavServer {
  _InMemoryWebDavServer({this.requireDigestAuth = false});

  final bool requireDigestAuth;
  final String expectedUsername = 'konata';

  final Set<String> createdDirs = <String>{};
  final Map<String, Uint8List> files = <String, Uint8List>{};
  final List<String> requestLog = <String>[];
  bool includeEtags = true;
  Completer<void>? manifestBarrier;
  int waitingManifestPuts = 0;
  int conflicts = 0;
  int forcedManifestConflicts = 0;
  String? redirectManifestTo;
  final List<Uri> requestUris = [];

  String etag(Uint8List bytes) => '"${base64Encode(bytes)}"';

  http.Client createClient() => _FakeWebDavClient(this);

  Future<http.StreamedResponse> handle(http.BaseRequest request) async {
    final path = request.url.path;
    final method = request.method.toUpperCase();
    requestLog.add('$method $path');
    requestUris.add(request.url);
    final redirect = redirectManifestTo;
    if (method == 'GET' &&
        path.endsWith('/manifest.json') &&
        redirect != null) {
      return http.StreamedResponse(
        Stream<List<int>>.value(const <int>[]),
        307,
        headers: {'location': redirect},
      );
    }

    if (requireDigestAuth && !_isAuthorized(request)) {
      const challenge =
          'Digest realm="konata-sync", qop="auth", nonce="konata-nonce-01", opaque="konata-opaque"';
      return http.StreamedResponse(
        Stream<List<int>>.value(const <int>[]),
        401,
        headers: const <String, String>{'www-authenticate': challenge},
      );
    }

    if (method == 'MKCOL') {
      createdDirs.add(path);
      return http.StreamedResponse(Stream<List<int>>.value(const <int>[]), 201);
    }

    if (method == 'GET') {
      final data = files[path];
      if (data == null) {
        return http.StreamedResponse(
          Stream<List<int>>.value(const <int>[]),
          404,
        );
      }
      return http.StreamedResponse(
        Stream<List<int>>.value(data),
        200,
        contentLength: data.length,
        headers: {if (includeEtags) 'etag': etag(data)},
      );
    }

    if (method == 'PUT') {
      final bytes = await request.finalize().toBytes();
      if (path.endsWith('/manifest.json') && forcedManifestConflicts > 0) {
        forcedManifestConflicts--;
        conflicts++;
        return http.StreamedResponse(
          Stream<List<int>>.value(const <int>[]),
          412,
        );
      }
      final barrier = manifestBarrier;
      if (path.endsWith('/manifest.json') &&
          barrier != null &&
          waitingManifestPuts < 2) {
        waitingManifestPuts++;
        if (waitingManifestPuts == 2) barrier.complete();
        await barrier.future.timeout(const Duration(seconds: 5));
      }
      final old = files[path];
      final ifMatch = request.headers['if-match'];
      final ifNoneMatch = request.headers['if-none-match'];
      if ((ifMatch != null && (old == null || etag(old) != ifMatch)) ||
          (ifNoneMatch == '*' && old != null)) {
        conflicts++;
        return http.StreamedResponse(
          Stream<List<int>>.value(const <int>[]),
          412,
        );
      }
      files[path] = Uint8List.fromList(bytes);
      return http.StreamedResponse(Stream<List<int>>.value(const <int>[]), 201);
    }

    return http.StreamedResponse(Stream<List<int>>.value(const <int>[]), 405);
  }

  bool _isAuthorized(http.BaseRequest request) {
    final auth = request.headers[HttpHeaders.authorizationHeader] ?? '';
    if (auth.startsWith('Digest ') &&
        auth.contains('username="$expectedUsername"') &&
        auth.contains('response=')) {
      return true;
    }
    return false;
  }

  int countRequests(String methodPrefix, {String? pathContains}) {
    return requestLog.where((entry) {
      if (!entry.startsWith('$methodPrefix ')) return false;
      if (pathContains != null && !entry.contains(pathContains)) return false;
      return true;
    }).length;
  }
}

final class _FakeWebDavClient extends http.BaseClient {
  _FakeWebDavClient(this._server);
  final _InMemoryWebDavServer _server;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      _server.handle(request);
}

void main() {
  group('WebDavSyncConfigRepository 凭据隔离仓储', () {
    late KonataDatabaseBundle db;
    late ScopedPrefsStore prefs;
    late InMemorySecureStorage secureStorage;
    late WebDavSyncConfigRepository repo;

    setUp(() {
      db = KonataDatabaseBundle.openInMemory();
      prefs = ScopedPrefsStore(db.userState);
      secureStorage = InMemorySecureStorage();
      repo = WebDavSyncConfigRepository(
        scopedPrefs: prefs,
        secureStorage: secureStorage,
      );
    });

    tearDown(() async {
      await db.close();
    });

    test(
      '将非敏感配置存 ScopedPrefsStore(sync_webdav)，密码严格隔离存 SecureStoragePort',
      () async {
        const input = WebDavSyncConfig(
          enabled: true,
          baseUrl: 'https://dav.example.com/root',
          remoteDir: '/konata-cloud/',
          username: 'alice',
          password: 'super-secret-webdav-password',
          autoSyncOnStartup: true,
          autoSyncOnPlaybackStop: true,
          autoSyncIntervalMinutes: 15,
          selectedSliceIds: <String>{'prefs_slice', 'playback_history_slice'},
        );

        await repo.save(input, sourceDeviceId: 'dev-win');

        final rawRow = db.userState.scopedPrefs.findByNamespace('sync_webdav');
        expect(rawRow, isNotNull);
        expect(rawRow!.syncPolicy, SyncPolicy.deviceLocal);
        expect(rawRow.payloadJson, contains('https://dav.example.com/root'));
        expect(rawRow.payloadJson, contains('konata-cloud'));
        expect(
          rawRow.payloadJson,
          isNot(contains('super-secret-webdav-password')),
        );

        final secretInVault = await secureStorage.read(
          WebDavSyncConfigRepository.passwordSecretKey,
        );
        expect(secretInVault, 'super-secret-webdav-password');

        final loaded = await repo.load();
        expect(loaded.enabled, isTrue);
        expect(loaded.baseUrl, 'https://dav.example.com/root');
        expect(loaded.remoteDir, 'konata-cloud');
        expect(loaded.username, 'alice');
        expect(loaded.password, 'super-secret-webdav-password');
        expect(loaded.autoSyncOnStartup, isTrue);
        expect(loaded.autoSyncOnPlaybackStop, isTrue);
        expect(loaded.autoSyncIntervalMinutes, 15);
        expect(
          loaded.selectedSliceIds,
          equals(<String>{'prefs_slice', 'playback_history_slice'}),
        );

        // 确保 PrefsSyncSlice 绝不会将 sync_webdav 暴露至同步导出数据中。
        final prefsSlice = PrefsSyncSlice(
          userStateDb: db.userState,
          scopedPrefs: prefs,
        );
        final exported = await prefsSlice.exportSlice(localDeviceId: 'dev-win');
        expect(jsonEncode(exported.toJson()), isNot(contains('sync_webdav')));
        expect(
          jsonEncode(exported.toJson()),
          isNot(contains('super-secret-webdav-password')),
        );
      },
    );
  });

  group('WebDavSyncTransport & WebDavSyncCoordinator 多设备分片同步与 SHA-256 跳过', () {
    late _InMemoryWebDavServer server;
    late KonataDatabaseBundle dbA;
    late KonataDatabaseBundle dbB;
    late ScopedPrefsStore prefsA;
    late ScopedPrefsStore prefsB;
    late SyncDeviceStore storeA;
    late SyncDeviceStore storeB;
    late InMemoryDomainEventBus eventBusA;
    late InMemoryDomainEventBus eventBusB;
    late WebDavSyncCoordinator coordinatorA;
    late WebDavSyncCoordinator coordinatorB;

    const appearanceSlice = TypedPrefsSlice<Map<String, Object?>>(
      namespace: 'appearance',
      schemaVersion: 1,
      syncPolicy: SyncPolicy.portable,
      defaultValue: <String, Object?>{},
      encode: _identityEncode,
      decode: _identityDecode,
    );

    const webDavConfig = WebDavSyncConfig(
      enabled: true,
      baseUrl: 'https://dav.example.com/dav',
      remoteDir: 'konata-sync',
      username: 'konata',
      password: 'app-secret-password',
    );

    setUp(() {
      server = _InMemoryWebDavServer(requireDigestAuth: true);
      dbA = KonataDatabaseBundle.openInMemory();
      dbB = KonataDatabaseBundle.openInMemory();
      prefsA = ScopedPrefsStore(dbA.userState);
      prefsB = ScopedPrefsStore(dbB.userState);
      dbA.userState.syncMeta.put(
        SyncDeviceStore.metaKeyDeviceId,
        'device_a',
        updatedAtMs: 1,
      );
      dbB.userState.syncMeta.put(
        SyncDeviceStore.metaKeyDeviceId,
        'device_b',
        updatedAtMs: 1,
      );
      storeA = SyncDeviceStore(dbA.userState.syncMeta, nowMs: () => 5000);
      storeB = SyncDeviceStore(dbB.userState.syncMeta, nowMs: () => 6000);
      eventBusA = InMemoryDomainEventBus();
      eventBusB = InMemoryDomainEventBus();

      final transport = WebDavSyncTransport(
        clientFactory: (_) => server.createClient(),
      );
      coordinatorA = WebDavSyncCoordinator(
        databases: dbA,
        scopedPrefs: prefsA,
        deviceStore: storeA,
        transport: transport,
        nowMs: () => 5000,
        eventBus: eventBusA,
      );
      coordinatorB = WebDavSyncCoordinator(
        databases: dbB,
        scopedPrefs: prefsB,
        deviceStore: storeB,
        transport: transport,
        nowMs: () => 6000,
        eventBus: eventBusB,
      );
    });

    tearDown(() async {
      await eventBusA.dispose();
      await eventBusB.dispose();
      await dbA.close();
      await dbB.close();
    });

    test('扩展切片第二条SQL失败时双库回滚，不发布水位或完成事件，重试成功', () async {
      final extensionA = _TransactionFaultSlice(dbA);
      final extensionB = _TransactionFaultSlice(dbB);
      final transport = WebDavSyncTransport(
        clientFactory: (_) => server.createClient(),
      );
      final a = WebDavSyncCoordinator(
        databases: dbA,
        scopedPrefs: prefsA,
        deviceStore: storeA,
        transport: transport,
        extraSlices: [extensionA],
      );
      final b = WebDavSyncCoordinator(
        databases: dbB,
        scopedPrefs: prefsB,
        deviceStore: storeB,
        transport: transport,
        extraSlices: [extensionB],
        eventBus: eventBusB,
      );
      prefsA.write(appearanceSlice, {
        'themeMode': 'dark',
      }, sourceDeviceId: 'device_a');
      dbA.library.works.upsert(
        const WorkRecord(id: WorkId.trusted('rollback-work'), title: '远端作品'),
      );
      extensionA.seed();
      await a.syncNow(webDavConfig);
      final events = <DomainEvent>[];
      final sub = eventBusB.stream.listen(events.add);
      addTearDown(sub.cancel);
      dbB.userState.engine.runTransaction((tx) {
        tx.execute(
          "CREATE TRIGGER audit_fail_second BEFORE INSERT ON lyric_user_overrides WHEN NEW.override_key = 'track::second' BEGIN SELECT RAISE(ABORT, 'audit second write'); END;",
        );
      });
      server.requestLog.clear();
      await expectLater(
        b.syncNow(webDavConfig),
        throwsA(
          predicate<Object>((e) => e.toString().contains('audit second write')),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(dbB.library.works.listVisible(), isEmpty);
      expect(prefsB.read(appearanceSlice), isEmpty);
      expect(
        dbB.userState.lyricUserOverrides.listAll(includeDeleted: true),
        isEmpty,
      );
      for (final slice in a.registeredSlices) {
        expect(storeB.readRemoteSliceSha256(slice.sliceId, 'device_a'), isNull);
        expect(storeB.readLocalSliceSha256(slice.sliceId), isNull);
      }
      expect(storeB.readMeta(SyncDeviceStore.metaKeyWebDavLastSyncMs), isNull);
      expect(events.whereType<SyncCompletedEvent>(), isEmpty);
      expect(server.countRequests('PUT'), 0);
      dbB.userState.engine.runTransaction(
        (tx) => tx.execute('DROP TRIGGER audit_fail_second;'),
      );
      final outcome = await b.syncNow(webDavConfig);
      await Future<void>.delayed(Duration.zero);
      expect(outcome.downloadedShards, 4);
      expect(dbB.library.works.listVisible().single.title, '远端作品');
      expect(prefsB.read(appearanceSlice)['themeMode'], 'dark');
      expect(dbB.userState.lyricUserOverrides.listAll(), hasLength(2));
      expect(events.whereType<SyncCompletedEvent>(), hasLength(1));
    });
    test('旧版或损坏远端清单拒绝同步且绝不上传覆盖', () async {
      const manifestPath = '/dav/konata-sync/manifest.json';
      for (final content in [
        '',
        '{}',
        '{"schemaVersion":1,"devices":{"old":{"deviceId":"old"}}}',
        '{"schemaVersion":3,"slices":{}}',
        '{"schemaVersion":2,"slices":{"bad":null}}',
        '{"schemaVersion":2,"slices":{"bad":{"sliceId":"prefs_slice","deviceId":"old","schemaVersion":1,"updatedAtMs":1,"shardPath":"slices/old.json.gz","sha256":""}}}',
      ]) {
        final bytes = Uint8List.fromList(utf8.encode(content));
        server.files[manifestPath] = bytes;
        server.requestLog.clear();
        await expectLater(
          coordinatorA.syncNow(webDavConfig),
          throwsA(anyOf(isA<FormatException>(), isA<WebDavSyncException>())),
        );
        expect(server.countRequests('PUT'), 0);
        expect(server.files[manifestPath], orderedEquals(bytes));
      }
    });

    test(
      '支持 Digest 质询重放、规范目录 manifest.json + slices/*.json.gz 写入与双向合流',
      () async {
        // 设备 A 写入作品、本地自定义封面（应归零为 null）与观看历史，并配置 WebDAV。
        prefsA.write(appearanceSlice, <String, Object?>{'themeMode': 'dark'});
        final workId = WorkId('w-a');
        final epId = EpisodeId('ep-a-1');
        dbA.library.works.upsert(
          WorkRecord(
            id: workId,
            tmdbId: 31910,
            tmdbMediaType: TmdbMediaType.tv,
            matchedSeason: 1,
            title: '轻音少女',
            posterRef: const ArtworkRef.localCustom(
              localPath: 'photos/device_a_secret_cover.png',
              locked: true,
            ),
            logoRef: const ArtworkRef.remote(
              source: ArtworkSource.fanart,
              uri: 'https://assets.fanart.tv/k_on_logo.png',
            ),
            isManualLocked: true,
            updatedAtMs: 4000,
            sourceDeviceId: 'device_a',
          ),
        );
        dbA.library.episodes.upsert(
          EpisodeRecord(
            id: epId,
            workId: workId,
            seasonNumber: 1,
            episodeNumber: 1,
            title: '废部！',
            updatedAtMs: 4000,
          ),
        );
        dbA.userState.playbackRecords.upsert(
          PlaybackRecordEntity(
            id: '${workId.value}::${epId.value}',
            canonicalKey: 'tmdb:tv:31910:s1::s1::e1',
            workId: workId,
            episodeId: epId,
            variantId: VariantId('var-a-1'),
            seasonNumber: 1,
            episodeNumber: 1,
            episodeTitle: '废部！',
            sourceKind: MediaSourceKind.local,
            playedAtMs: 4500,
            positionSeconds: 820,
            durationSeconds: 1440,
            isCompleted: false,
            updatedAtMs: 4500,
            sourceDeviceId: 'device_a',
          ),
        );

        final outcomeA = await coordinatorA.syncNow(webDavConfig);
        expect(outcomeA.uploadedShards, 3);
        expect(outcomeA.downloadedShards, 0);

        // 检验远端目录路径、文件清单及严格零凭据/零本地自定义路径泄露。
        expect(
          server.files.containsKey('/dav/konata-sync/manifest.json'),
          isTrue,
        );
        expect(
          server.files.keys.any(
            (path) =>
                path.startsWith(
                  '/dav/konata-sync/slices/prefs_slice_device_a_',
                ) &&
                path.endsWith('.json.gz'),
          ),
          isTrue,
        );
        expect(
          server.files.keys.any(
            (path) =>
                path.startsWith(
                  '/dav/konata-sync/slices/playback_history_slice_device_a_',
                ) &&
                path.endsWith('.json.gz'),
          ),
          isTrue,
        );
        expect(
          server.files.keys.any(
            (path) =>
                path.startsWith(
                  '/dav/konata-sync/slices/library_catalog_slice_device_a_',
                ) &&
                path.endsWith('.json.gz'),
          ),
          isTrue,
        );

        for (final entry in server.files.entries) {
          final content = entry.key.endsWith('.gz')
              ? utf8.decode(gzip.decode(entry.value))
              : utf8.decode(entry.value);
          expect(content, isNot(contains('app-secret-password')));
          expect(content, isNot(contains('device_a_secret_cover.png')));
        }

        // 设备 B 执行同步，监听 SyncCompletedEvent 并验证三切片均正确合流落盘。
        final eventsB = <DomainEvent>[];
        final subB = eventBusB.stream.listen(eventsB.add);
        addTearDown(subB.cancel);

        final outcomeB = await coordinatorB.syncNow(webDavConfig);
        await Future<void>.delayed(Duration.zero);

        expect(outcomeB.downloadedShards, 3);
        expect(outcomeB.uploadedShards, 3);
        expect(
          outcomeB.updatedSliceIds,
          equals(<String>{
            'prefs_slice',
            'playback_history_slice',
            'library_catalog_slice',
          }),
        );
        expect(prefsB.read(appearanceSlice)['themeMode'], 'dark');
        final syncedWorkB = dbB.library.works.listVisible().single;
        expect(syncedWorkB.title, '轻音少女');
        expect(syncedWorkB.posterRef, isNull);
        expect(
          (syncedWorkB.logoRef! as RemoteArtworkRef).uri,
          'https://assets.fanart.tv/k_on_logo.png',
        );
        expect(syncedWorkB.isManualLocked, isTrue);
        expect(
          dbB.userState.playbackRecords
              .listAllWithTombstones()
              .where((r) => !r.isDeleted)
              .single
              .positionSeconds,
          820,
        );

        final syncCompletedB = eventsB.whereType<SyncCompletedEvent>().single;
        expect(syncCompletedB.channel, SyncChannelIds.webDav);
      },
    );

    test('首次同步同时发布，412 重读后保留两个设备全部水位', () async {
      server.manifestBarrier = Completer<void>();
      await Future.wait([
        coordinatorA.syncNow(webDavConfig),
        coordinatorB.syncNow(webDavConfig),
      ]);
      final manifest = WebDavSyncManifest.fromJson(
        jsonDecode(utf8.decode(server.files['/dav/konata-sync/manifest.json']!))
            as Map<String, Object?>,
      );
      expect(manifest.slices.length, 6);
      expect(manifest.slices.values.map((wm) => wm.deviceId).toSet(), {
        'device_a',
        'device_b',
      });
      expect(server.conflicts, 1);
      for (final wm in manifest.slices.values) {
        expect(
          server.files.containsKey('/dav/konata-sync/${wm.shardPath}'),
          isTrue,
        );
      }
      await coordinatorA.syncNow(webDavConfig);
      await coordinatorB.syncNow(webDavConfig);
    });

    test('已有清单同时更新，保留旧分片字节与双方新水位', () async {
      await coordinatorA.syncNow(webDavConfig);
      await coordinatorB.syncNow(webDavConfig);
      await coordinatorA.syncNow(webDavConfig);
      final previous = Map<String, Uint8List>.of(server.files);
      prefsA.write(appearanceSlice, {
        'themeMode': 'dark',
      }, sourceDeviceId: 'device_a');
      prefsB.write(appearanceSlice, {
        'themeMode': 'light',
      }, sourceDeviceId: 'device_b');
      server.manifestBarrier = Completer<void>();
      await Future.wait([
        coordinatorA.syncNow(webDavConfig),
        coordinatorB.syncNow(webDavConfig),
      ]);
      expect(server.conflicts, 1);
      final manifest = WebDavSyncManifest.fromJson(
        jsonDecode(utf8.decode(server.files['/dav/konata-sync/manifest.json']!))
            as Map<String, Object?>,
      );
      expect(manifest.slices.length, 6);
      for (final entry in previous.entries.where(
        (e) => e.key.endsWith('.gz'),
      )) {
        expect(server.files[entry.key], orderedEquals(entry.value));
      }
      expect(
        manifest.findEntry('prefs_slice', 'device_a')!.shardPath,
        isNot(manifest.findEntry('prefs_slice', 'device_b')!.shardPath),
      );
      await coordinatorA.syncNow(webDavConfig);
      await coordinatorB.syncNow(webDavConfig);
    });

    test('无强 ETag 的现有清单拒绝发布且不上传分片', () async {
      await coordinatorA.syncNow(webDavConfig);
      server.includeEtags = false;
      server.requestLog.clear();
      final previous = Map<String, Uint8List>.of(server.files);
      prefsA.write(appearanceSlice, {
        'themeMode': 'light',
      }, sourceDeviceId: 'device_a');
      await expectLater(
        coordinatorA.syncNow(webDavConfig),
        throwsA(isA<WebDavSyncException>()),
      );
      expect(server.countRequests('PUT'), 0);
      expect(server.files, previous);
    });

    test('清单重试耗尽不记录成功，随后复用已存在的完整分片', () async {
      server.forcedManifestConflicts = 4;
      await expectLater(
        coordinatorA.syncNow(webDavConfig),
        throwsA(
          isA<WebDavSyncException>().having(
            (e) => e.statusCode,
            'statusCode',
            412,
          ),
        ),
      );
      expect(server.conflicts, 4);
      expect(
        server.files.containsKey('/dav/konata-sync/manifest.json'),
        isFalse,
      );
      expect(storeA.readMeta(SyncDeviceStore.metaKeyWebDavLastSyncMs), isNull);
      expect(storeA.readLocalSliceSha256('prefs_slice'), isNull);
      final shards = Map<String, Uint8List>.of(server.files);
      expect(shards.length, 3);
      await coordinatorA.syncNow(webDavConfig);
      expect(storeA.readLocalSliceSha256('prefs_slice'), isNotNull);
      for (final entry in shards.entries) {
        expect(server.files[entry.key], orderedEquals(entry.value));
      }
      expect(server.files.length, 4);
    });

    test('同设备标识的不同会话冲突时仅一个清单发布成功', () async {
      storeB.writeMeta(SyncDeviceStore.metaKeyDeviceId, 'device_a');
      prefsA.write(appearanceSlice, {
        'themeMode': 'dark',
      }, sourceDeviceId: 'device_a');
      prefsB.write(appearanceSlice, {
        'themeMode': 'light',
      }, sourceDeviceId: 'device_a');
      server.manifestBarrier = Completer<void>();
      final results = await Future.wait([
        coordinatorA
            .syncNow(webDavConfig)
            .then<Object>((v) => v, onError: (Object e) => e),
        coordinatorB
            .syncNow(webDavConfig)
            .then<Object>((v) => v, onError: (Object e) => e),
      ]);
      expect(results.whereType<KonataSyncOutcome>(), hasLength(1));
      expect(
        results.whereType<WebDavSyncException>().single.message,
        contains('同一设备'),
      );
      final manifest = WebDavSyncManifest.fromJson(
        jsonDecode(utf8.decode(server.files['/dav/konata-sync/manifest.json']!))
            as Map<String, Object?>,
      );
      expect(manifest.slices.length, 3);
      expect(
        manifest.slices.values.every((wm) => wm.deviceId == 'device_a'),
        isTrue,
      );
    });

    test('跨站重定向不会发送第二个请求或泄漏凭据', () async {
      for (final target in [
        'https://other.example.com/manifest.json',
        'http://dav.example.com/manifest.json',
        'https://dav.example.com:444/manifest.json',
        'https://user@dav.example.com/manifest.json',
      ]) {
        server.redirectManifestTo = target;
        server.requestUris.clear();
        await expectLater(
          coordinatorA.syncNow(webDavConfig),
          throwsA(
            isA<WebDavSyncException>().having(
              (e) => e.message,
              'message',
              contains('重定向'),
            ),
          ),
        );
        expect(
          server.requestUris.every(
            (u) =>
                u.scheme == 'https' &&
                u.host == 'dav.example.com' &&
                u.port == 443 &&
                u.userInfo.isEmpty,
          ),
          isTrue,
        );
        expect(server.countRequests('PUT'), 0);
      }
    });

    test('声明长度及无长度流式响应超过清单上限时拒绝', () async {
      final chunk = Uint8List(1024 * 1024);
      for (final lengthKnown in [true, false]) {
        var canceled = false;
        final stream = StreamController<List<int>>(
          onCancel: () {
            canceled = true;
          },
        );
        stream.add(chunk);
        if (!lengthKnown) {
          for (var i = 0; i < 4; i++) {
            stream.add(chunk);
          }
        }
        unawaited(stream.close());
        final transport = WebDavSyncTransport(
          clientFactory: (_) => _AuditStreamClient(
            () => http.StreamedResponse(
              stream.stream,
              200,
              contentLength: lengthKnown
                  ? WebDavSyncTransport.maxManifestBytes + 1
                  : null,
            ),
          ),
        );
        await expectLater(
          transport.fetchManifest(webDavConfig),
          throwsA(
            isA<WebDavSyncException>().having(
              (e) => e.message,
              'message',
              contains('4 MiB'),
            ),
          ),
        );
        expect(canceled, isTrue);
      }
    });

    test('正文停滞时限时退出并取消网络流', () async {
      var canceled = false;
      final stream = StreamController<List<int>>(
        onCancel: () {
          canceled = true;
        },
      );
      stream.add([123]);
      final transport = WebDavSyncTransport(
        clientFactory: (_) =>
            _AuditStreamClient(() => http.StreamedResponse(stream.stream, 200)),
        requestTimeout: const Duration(milliseconds: 100),
      );
      try {
        await expectLater(
          transport.fetchManifest(webDavConfig),
          throwsA(
            isA<WebDavSyncException>().having(
              (e) => e.message,
              'message',
              contains('超时'),
            ),
          ),
        );
        expect(canceled, isTrue);
      } finally {
        await stream.close();
      }
    });

    test('分片压缩大小与流式解压上限拒绝，目标库和远端水位不变', () async {
      await coordinatorA.syncNow(webDavConfig);
      final manifest = WebDavSyncManifest.fromJson(
        jsonDecode(utf8.decode(server.files['/dav/konata-sync/manifest.json']!))
            as Map<String, Object?>,
      );
      final entry = manifest.findEntry(PrefsSyncSlice.id, 'device_a')!;
      final path = '/dav/konata-sync/${entry.shardPath}';
      final encoded = _AuditByteSink();
      final compressor = gzip.encoder.startChunkedConversion(encoded);
      final block = Uint8List(1024 * 1024);
      for (
        var i = 0;
        i <= WebDavSyncTransport.maxDecodedShardBytes ~/ block.length;
        i++
      ) {
        compressor.add(block);
      }
      compressor.close();
      final bomb = encoded.bytes.takeBytes();
      expect(bomb.length, lessThan(WebDavSyncTransport.maxShardBytes));
      for (final payload in [
        (Uint8List(WebDavSyncTransport.maxShardBytes + 1), '32 MiB'),
        (bomb, '128 MiB'),
      ]) {
        server.files[path] = payload.$1;
        server.requestLog.clear();
        await expectLater(
          coordinatorB.syncNow(webDavConfig),
          throwsA(
            isA<WebDavSyncException>().having(
              (e) => e.message,
              'message',
              contains(payload.$2),
            ),
          ),
        );
        expect(server.countRequests('PUT'), 0);
        expect(
          storeB.readRemoteSliceSha256(PrefsSyncSlice.id, 'device_a'),
          isNull,
        );
        expect(
          storeB.readMeta(SyncDeviceStore.metaKeyWebDavLastSyncMs),
          isNull,
        );
        expect(dbB.library.works.listVisible(), isEmpty);
        expect(prefsB.read(appearanceSlice), isEmpty);
      }
    });
    test('当前清单含未来切片版本时在下载及合并前拒绝，水位和两库保持不变', () async {
      prefsA.write(appearanceSlice, {
        'themeMode': 'dark',
      }, sourceDeviceId: 'device_a');
      dbA.library.works.upsert(
        const WorkRecord(id: WorkId.trusted('remote-work'), title: '远端作品'),
      );
      await coordinatorA.syncNow(webDavConfig);
      const manifestPath = '/dav/konata-sync/manifest.json';
      final original = WebDavSyncManifest.fromJson(
        jsonDecode(utf8.decode(server.files[manifestPath]!))
            as Map<String, Object?>,
      );
      final originalEntry = original.findEntry(PrefsSyncSlice.id, 'device_a')!;
      final envelope =
          jsonDecode(
                utf8.decode(
                  gzip.decode(
                    server
                        .files['/dav/konata-sync/${originalEntry.shardPath}']!,
                  ),
                ),
              )
              as Map<String, Object?>;
      envelope['schemaVersion'] = 99;
      final hash = SyncSanitizer.computeSliceDataSha256(
        sliceId: PrefsSyncSlice.id,
        schemaVersion: 99,
        data: envelope['data']! as Map<String, Object?>,
      );
      envelope['sha256'] = hash;
      final path = WebDavSyncTransport.buildShardRelativePath(
        sliceId: PrefsSyncSlice.id,
        deviceId: 'device_a',
        sha256: hash,
      );
      server.files['/dav/konata-sync/$path'] = Uint8List.fromList(
        gzip.encode(utf8.encode(jsonEncode(envelope))),
      );
      final future = original.withEntry(
        WebDavSliceWatermark(
          sliceId: PrefsSyncSlice.id,
          deviceId: 'device_a',
          deviceName: '未来设备',
          platform: 'windows',
          schemaVersion: 99,
          updatedAtMs: 5001,
          shardPath: path,
          sha256: hash,
        ),
      );
      final bytes = Uint8List.fromList(
        utf8.encode(jsonEncode(future.toJson())),
      );
      server.files[manifestPath] = bytes;
      dbB.library.works.upsert(
        const WorkRecord(id: WorkId.trusted('keep-work'), title: '本机作品'),
      );
      prefsB.write(appearanceSlice, {
        'themeMode': 'light',
      }, sourceDeviceId: 'device_b');
      for (final config in [
        webDavConfig,
        webDavConfig.copyWith(selectedSliceIds: {PrefsSyncSlice.id}),
      ]) {
        server.requestLog.clear();
        await expectLater(
          coordinatorB.syncNow(config),
          throwsA(
            isA<WebDavSyncException>().having(
              (e) => e.message,
              'message',
              contains('版本不兼容'),
            ),
          ),
        );
        expect(server.countRequests('GET', pathContains: '/slices/'), 0);
        expect(server.countRequests('PUT'), 0);
        expect(server.files[manifestPath], orderedEquals(bytes));
        expect(
          storeB.readRemoteSliceSha256(PrefsSyncSlice.id, 'device_a'),
          isNull,
        );
        expect(
          storeB.readMeta(SyncDeviceStore.metaKeyWebDavLastSyncMs),
          isNull,
        );
        expect(dbB.library.works.listVisible().single.title, '本机作品');
        expect(prefsB.read(appearanceSlice)['themeMode'], 'light');
      }
      // 降级回同一设备身份也不能用旧结构覆盖自己的未来分片。
      server.requestLog.clear();
      await expectLater(
        coordinatorA.syncNow(webDavConfig),
        throwsA(isA<WebDavSyncException>()),
      );
      expect(server.countRequests('PUT'), 0);
      expect(server.files[manifestPath], orderedEquals(bytes));
    });

    test('分片身份不一致即使主体哈希有效也拒绝合并', () async {
      prefsA.write(appearanceSlice, {
        'themeMode': 'dark',
      }, sourceDeviceId: 'device_a');
      await coordinatorA.syncNow(webDavConfig);
      final manifest = WebDavSyncManifest.fromJson(
        jsonDecode(utf8.decode(server.files['/dav/konata-sync/manifest.json']!))
            as Map<String, Object?>,
      );
      final path =
          '/dav/konata-sync/${manifest.findEntry('prefs_slice', 'device_a')!.shardPath}';
      final envelope =
          jsonDecode(utf8.decode(gzip.decode(server.files[path]!)))
              as Map<String, Object?>;
      envelope['sourceDeviceId'] = 'different_device';
      server.files[path] = Uint8List.fromList(
        gzip.encode(utf8.encode(jsonEncode(envelope))),
      );
      server.requestLog.clear();
      await expectLater(
        coordinatorB.syncNow(webDavConfig),
        throwsA(
          isA<WebDavSyncException>().having(
            (e) => e.message,
            'message',
            contains('身份'),
          ),
        ),
      );
      expect(server.countRequests('PUT'), 0);
      expect(storeB.readRemoteSliceSha256('prefs_slice', 'device_a'), isNull);
      expect(prefsB.read(appearanceSlice)['themeMode'], isNull);
    });

    test('清单路径越界时拒绝读取非分片资源', () async {
      await coordinatorA.syncNow(webDavConfig);
      const manifestPath = '/dav/konata-sync/manifest.json';
      final manifest =
          jsonDecode(utf8.decode(server.files[manifestPath]!))
              as Map<String, Object?>;
      final slices = manifest['slices']! as Map<String, Object?>;
      final entry = slices['prefs_slice::device_a']! as Map<String, Object?>;
      entry['shardPath'] = '../private.json';
      server.files[manifestPath] = Uint8List.fromList(
        utf8.encode(jsonEncode(manifest)),
      );
      server.requestLog.clear();
      await expectLater(
        coordinatorB.syncNow(webDavConfig),
        throwsA(
          isA<WebDavSyncException>().having(
            (e) => e.message,
            'message',
            contains('路径'),
          ),
        ),
      );
      expect(
        server.requestLog.where((e) => e.contains('private.json')),
        isEmpty,
      );
      expect(server.countRequests('PUT'), 0);
    });

    test('SHA-256 校验跳过未变分片，完全未改动时实现零切片下载、零切片上传与零清单覆写', () async {
      prefsA.write(appearanceSlice, <String, Object?>{'themeMode': 'dark'});
      await coordinatorA.syncNow(webDavConfig);
      await coordinatorB.syncNow(webDavConfig);

      // 清空请求日志后，设备 B 再次立即同步：必须零 GET slices/*、零 PUT slices/*、零 PUT manifest.json。
      server.requestLog.clear();
      final noopOutcome = await coordinatorB.syncNow(webDavConfig);
      expect(noopOutcome.downloadedShards, 0);
      expect(noopOutcome.uploadedShards, 0);
      expect(noopOutcome.skippedUnchangedDownloads, 3);
      expect(noopOutcome.skippedUnchangedUploads, 3);
      expect(server.countRequests('GET', pathContains: '/slices/'), 0);
      expect(server.countRequests('PUT', pathContains: '/slices/'), 0);
      expect(server.countRequests('PUT', pathContains: 'manifest.json'), 0);

      // 仅设备 A 修改偏好切片：设备 A 应只上传 prefs_slice（1 个 PUT），设备 B 只下载 prefs_slice（1 个 GET）。
      prefsA.write(appearanceSlice, <String, Object?>{
        'themeMode': 'light',
      }, sourceDeviceId: 'device_a');
      server.requestLog.clear();
      final pushA = await coordinatorA.syncNow(webDavConfig);
      expect(pushA.uploadedShards, 1);
      expect(pushA.skippedUnchangedUploads, 2);
      expect(
        server.countRequests('PUT', pathContains: 'prefs_slice_device_a'),
        1,
      );
      expect(
        server.countRequests('PUT', pathContains: 'playback_history_slice'),
        0,
      );

      server.requestLog.clear();
      final pullB = await coordinatorB.syncNow(webDavConfig);
      expect(pullB.downloadedShards, 1);
      expect(pullB.skippedUnchangedDownloads, 2);
      expect(
        server.countRequests('GET', pathContains: 'prefs_slice_device_a'),
        1,
      );
      expect(
        server.countRequests('GET', pathContains: 'library_catalog_slice'),
        0,
      );
      expect(prefsB.read(appearanceSlice)['themeMode'], 'light');
    });
  });
}

Map<String, Object?> _identityEncode(Map<String, Object?> value) => value;
Map<String, Object?> _identityDecode(
  Map<String, Object?> json,
  int schemaVersion,
) => json;

final class _AuditStreamClient extends http.BaseClient {
  _AuditStreamClient(this.response);
  final http.StreamedResponse Function() response;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      response();
}

final class _AuditByteSink implements Sink<List<int>> {
  final bytes = BytesBuilder(copy: false);

  @override
  void add(List<int> data) => bytes.add(data);

  @override
  void close() {}
}

/// 使用真实事务句柄的扩展切片，测试宿主回滚及失败重试。
final class _TransactionFaultSlice
    implements SyncSliceContributor<List<String>> {
  _TransactionFaultSlice(this.db);
  final KonataDatabaseBundle db;
  @override
  String get sliceId => 'audit_transaction_slice';
  @override
  String get displayName => '事务故障夹具';
  @override
  int get schemaVersion => 1;
  LyricUserOverrideRecord record(String key) => LyricUserOverrideRecord(
    overrideKey: key,
    scope: LyricOverrideScope.track,
    trackKey: key,
    updatedAtMs: 1000,
  );
  void seed() {
    for (final key in ['track::first', 'track::second']) {
      db.userState.lyricUserOverrides.upsert(record(key));
    }
  }

  @override
  Future<SyncSlicePayload> exportSlice({required String localDeviceId}) async =>
      SyncSlicePayload(
        sliceId: sliceId,
        schemaVersion: 1,
        exportedAtMs: 1000,
        sourceDeviceId: localDeviceId,
        data: {
          'keys':
              db.userState.lyricUserOverrides
                  .listAll()
                  .map((r) => r.overrideKey)
                  .toList()
                ..sort(),
        },
      );
  @override
  SyncMergePlan<List<String>> planMerge({
    required SyncSlicePayload local,
    required SyncSlicePayload remote,
  }) {
    final old = (local.data['keys']! as List).cast<String>().toSet();
    final next = (remote.data['keys']! as List)
        .cast<String>()
        .where((k) => !old.contains(k))
        .toList();
    return SyncMergePlan(
      sliceId: sliceId,
      insertCount: next.length,
      updateCount: 0,
      deleteCount: 0,
      skippedCount: 0,
      planData: next,
    );
  }

  @override
  SyncApplyCompletion applyMergePlan(
    SyncTransactionContext tx,
    SyncMergePlan<List<String>> plan,
  ) {
    final handle = tx.rawHandleFor('user_state')! as SqliteTransaction;
    for (final key in plan.planData) {
      db.userState.lyricUserOverrides.upsertInTx(handle, record(key));
    }
    return SyncApplyCompletion.completed;
  }
}
