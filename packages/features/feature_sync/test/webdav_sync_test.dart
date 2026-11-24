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

  http.Client createClient() => _FakeWebDavClient(this);

  Future<http.StreamedResponse> handle(http.BaseRequest request) async {
    final path = request.url.path;
    final method = request.method.toUpperCase();
    requestLog.add('$method $path');

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
      return http.StreamedResponse(
        Stream<List<int>>.value(const <int>[]),
        201,
      );
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
      );
    }

    if (method == 'PUT') {
      final bytes = await request.finalize().toBytes();
      files[path] = Uint8List.fromList(bytes);
      return http.StreamedResponse(
        Stream<List<int>>.value(const <int>[]),
        201,
      );
    }

    return http.StreamedResponse(
      Stream<List<int>>.value(const <int>[]),
      405,
    );
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

    test('将非敏感配置存 ScopedPrefsStore(sync_webdav)，密码严格隔离存 SecureStoragePort', () async {
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
    });
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

    test('支持 Digest 质询重放、规范目录 manifest.json + slices/*.json.gz 写入与双向合流', () async {
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
        server.files.containsKey(
          '/dav/konata-sync/slices/prefs_slice_device_a.json.gz',
        ),
        isTrue,
      );
      expect(
        server.files.containsKey(
          '/dav/konata-sync/slices/playback_history_slice_device_a.json.gz',
        ),
        isTrue,
      );
      expect(
        server.files.containsKey(
          '/dav/konata-sync/slices/library_catalog_slice_device_a.json.gz',
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
      prefsA.write(
        appearanceSlice,
        <String, Object?>{'themeMode': 'light'},
        sourceDeviceId: 'device_a',
      );
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
