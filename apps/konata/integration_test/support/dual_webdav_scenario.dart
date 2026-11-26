import 'dart:convert';
import 'dart:io';

import 'package:feature_lyrics/feature_lyrics.dart';
import 'package:feature_sync/feature_sync.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';

Map<String, Object?> _encode(Map<String, Object?> value) => value;
Map<String, Object?> _decode(Map<String, Object?> value, int version) => value;
const _appearance = TypedPrefsSlice<Map<String, Object?>>(
  namespace: 'appearance',
  schemaVersion: 1,
  syncPolicy: SyncPolicy.portable,
  defaultValue: {},
  encode: _encode,
  decode: _decode,
);
const _local = TypedPrefsSlice<Map<String, Object?>>(
  namespace: 'audit_local',
  schemaVersion: 1,
  syncPolicy: SyncPolicy.deviceLocal,
  defaultValue: {},
  encode: _encode,
  decode: _decode,
);
const _source = SourceId.trusted('dual-source');
const _work = WorkId.trusted('dual-work');
const _series = SeriesGroupId.trusted('dual-series');
const _second = WorkId.trusted('dual-android-work');
const _t = 1700000000000;
EpisodeId _episode(int n) => EpisodeId.trusted('dual-ep-$n');
VariantId _variant(int n) => VariantId.trusted('dual-variant-$n');
String _historyId(int n) => '${_work.value}::${_episode(n).value}';
void _history(
  KonataDatabaseBundle db,
  int n,
  int position,
  int ts,
  String device,
) {
  db.userState.playbackRecords.upsert(
    PlaybackRecordEntity(
      id: _historyId(n),
      workId: _work,
      episodeId: _episode(n),
      variantId: _variant(n),
      canonicalKey: 'tmdb:tv:100565:s1::s1::e$n',
      seasonNumber: 1,
      episodeNumber: n,
      sourceKind: MediaSourceKind.webdav,
      playedAtMs: ts,
      updatedAtMs: ts,
      sourceDeviceId: device,
      positionSeconds: position,
      durationSeconds: 120,
    ),
  );
}

void _lyric(
  KonataDatabaseBundle db,
  String key,
  int offset,
  int ts,
  String device,
  String text,
) {
  db.userState.lyricUserOverrides.upsert(
    LyricUserOverrideRecord(
      overrideKey: key,
      scope: LyricOverrideScope.track,
      trackKey: key,
      lrcContent: text,
      offsetMillis: offset,
      userOffsetLocked: true,
      userEdited: true,
      updatedAtMs: ts,
      sourceDeviceId: device,
    ),
  );
}

void _check(KonataDatabaseBundle db, {required bool changed}) {
  final lyrics = db.userState.lyricUserOverrides.listAll(includeDeleted: true);
  expect(lyrics, hasLength(2));
  final first = lyrics.singleWhere((r) => r.overrideKey == 'track::first');
  final second = lyrics.singleWhere((r) => r.overrideKey == 'track::second');
  expect(first.offsetMillis, changed ? -240 : 120);
  expect(first.lrcContent, changed ? '[00:01.00]手机校准' : '[00:01.00]电脑校准');
  expect(first.userOffsetLocked, isTrue);
  expect(first.userEdited, isTrue);
  expect(second.deletedAtMs, changed ? _t + 200 : null);
  final w = db.library.works.findById(_work)!;
  expect(w.seriesId, _series);
  expect(w.metadataLocked, isTrue);
  expect(db.library.episodes.listByWork(_work), hasLength(2));
  expect(db.library.mediaVariants.listByWork(_work), hasLength(2));
  expect(
    db.library.mediaVariants.findById(_variant(1))!.episodeId,
    _episode(1),
  );
  final history = db.userState.playbackRecords.listAllWithTombstones();
  expect(history, hasLength(2));
  expect(
    history.singleWhere((r) => r.episodeId == _episode(1)).positionSeconds,
    changed ? 76 : 42,
  );
  expect(
    history.singleWhere((r) => r.episodeId == _episode(2)).deletedAtMs,
    changed ? _t + 200 : null,
  );
  expect(db.library.works.listVisible(), hasLength(changed ? 2 : 1));
  expect(
    ScopedPrefsStore(db.userState).read(_appearance)['themeMode'],
    changed ? 'light' : 'dark',
  );
}

/// 实际网络、真实磁盘数据库；仅允许独立回环夹具。
Future<void> runDualWebDavScenario(String phase, String root) async {
  expect(['seed', 'android', 'verify'], contains(phase));
  expect(phase == 'android' ? Platform.isAndroid : Platform.isWindows, isTrue);
  final storage = PortableStorageRootService(overrideRootPath: root);
  final db = await KonataDatabaseBundle.openFromStorageRoot(storage);
  final device = phase == 'android' ? 'audit-android' : 'audit-windows';
  final prefs = ScopedPrefsStore(db.userState);
  final store = SyncDeviceStore(db.userState.syncMeta);
  final repo = WebDavSyncConfigRepository(
    scopedPrefs: prefs,
    secureStorage: InMemorySecureStorage(),
  );
  const config = WebDavSyncConfig(
    enabled: true,
    baseUrl: 'http://127.0.0.1:48764/dav',
    remoteDir: 'dual-audit',
    username: 'fixture',
    password: 'fixture-sync-only',
    selectedSliceIds: {
      LibraryCatalogSyncSlice.id,
      PlaybackHistorySyncSlice.id,
      PrefsSyncSlice.id,
      LyricOverridesSyncSlice.stableSliceId,
    },
  );
  final coordinator = WebDavSyncCoordinator(
    databases: db,
    scopedPrefs: prefs,
    deviceStore: store,
    transport: WebDavSyncTransport(),
    extraSlices: [LyricOverridesSyncSlice(userStateDb: db.userState)],
  );
  final rounds = <Map<String, Object?>>[];
  var rollbackVerified = false;
  Future<void> sync(String label) async {
    final outcome = await coordinator.syncNow(await repo.load());
    rounds.add({
      'label': label,
      'downloaded': outcome.downloadedShards,
      'uploaded': outcome.uploadedShards,
      'skippedDownloads': outcome.skippedUnchangedDownloads,
      'skippedUploads': outcome.skippedUnchangedUploads,
    });
  }

  try {
    if (phase != 'verify') {
      expect(db.library.works.listVisible(), isEmpty);
      store.writeMeta(SyncDeviceStore.metaKeyDeviceId, device);
      prefs.write(_local, {'marker': device});
    }
    expect(store.getOrCreateDeviceId(), device);
    await repo.save(config);
    await coordinator.testConnection(await repo.load());
    if (phase == 'seed') {
      db.library.mediaSources.upsert(
        const MediaSourceRecord(
          id: _source,
          kind: MediaSourceKind.webdav,
          label: '隔离媒体源',
          location: 'https://fixture.example.invalid/media',
        ),
      );
      db.library.seriesGroups.upsert(
        const SeriesGroupRecord(id: _series, title: '隔离系列', updatedAtMs: _t),
      );
      db.library.works.upsert(
        const WorkRecord(
          id: _work,
          title: '隔离作品',
          tmdbId: 100565,
          tmdbMediaType: TmdbMediaType.tv,
          matchedSeason: 1,
          seriesId: _series,
          metadataLocked: true,
          updatedAtMs: _t,
          sourceDeviceId: 'audit-windows',
        ),
      );
      for (final n in [1, 2]) {
        db.library.episodes.upsert(
          EpisodeRecord(
            id: _episode(n),
            workId: _work,
            seasonNumber: 1,
            episodeNumber: n,
          ),
        );
        db.library.mediaVariants.upsert(
          MediaVariantRecord(
            id: _variant(n),
            workId: _work,
            episodeId: _episode(n),
            sourceId: _source,
            relativePath: 'Series/$n.mkv',
            fileName: '$n.mkv',
            fileSize: 1000,
          ),
        );
        _history(db, n, n == 1 ? 42 : 18, _t, device);
      }
      prefs.write(_appearance, {'themeMode': 'dark'}, sourceDeviceId: device);
      _lyric(db, 'track::first', 120, _t, device, '[00:01.00]电脑校准');
      _lyric(db, 'track::second', 250, _t, device, '[00:02.00]删除测试');
      _check(db, changed: false);
      await sync('Windows发布');
      expect(rounds.last['uploaded'], 4);
    } else if (phase == 'android') {
      db.userState.engine.runTransaction((tx) {
        tx.execute(
          "CREATE TRIGGER audit_fail_second BEFORE INSERT ON lyric_user_overrides WHEN NEW.override_key = 'track::second' BEGIN SELECT RAISE(ABORT, 'audit second write'); END;",
        );
      });
      final activeConfig = await repo.load();
      await expectLater(
        coordinator.syncNow(activeConfig),
        throwsA(
          predicate<Object>((e) => e.toString().contains('audit second write')),
        ),
      );
      expect(db.library.works.listVisible(), isEmpty);
      expect(db.userState.playbackRecords.listAllWithTombstones(), isEmpty);
      expect(
        db.userState.lyricUserOverrides.listAll(includeDeleted: true),
        isEmpty,
      );
      expect(prefs.read(_appearance), isEmpty);
      for (final slice in coordinator.registeredSlices) {
        expect(
          store.readRemoteSliceSha256(slice.sliceId, 'audit-windows'),
          isNull,
        );
        expect(store.readLocalSliceSha256(slice.sliceId), isNull);
      }
      expect(store.readMeta(SyncDeviceStore.metaKeyWebDavLastSyncMs), isNull);
      db.userState.engine.runTransaction(
        (tx) => tx.execute('DROP TRIGGER audit_fail_second;'),
      );
      rollbackVerified = true;
      await sync('Android接收');
      expect(rounds.last['downloaded'], 4);
      _check(db, changed: false);
      _history(db, 1, 76, _t + 200, device);
      db.userState.playbackRecords.softDelete(
        _historyId(2),
        deletedAtMs: _t + 200,
        sourceDeviceId: device,
      );
      db.library.works.upsert(
        const WorkRecord(
          id: _second,
          title: 'Android新作品',
          tmdbId: 999001,
          tmdbMediaType: TmdbMediaType.tv,
          matchedSeason: 1,
          updatedAtMs: _t + 200,
          sourceDeviceId: 'audit-android',
        ),
      );
      prefs.write(_appearance, {'themeMode': 'light'}, sourceDeviceId: device);
      _lyric(db, 'track::first', -240, _t + 200, device, '[00:01.00]手机校准');
      db.userState.lyricUserOverrides.softDelete(
        'track::second',
        deletedAtMs: _t + 200,
        sourceDeviceId: device,
      );
      await sync('Android反向发布');
      expect(rounds.last['uploaded'], 4);
      _check(db, changed: true);
      await sync('Android无变化复验');
      expect(rounds.last['uploaded'], 0);
      expect(rounds.last['downloaded'], 0);
    } else {
      _check(db, changed: false);
      await sync('Windows接收');
      expect(rounds.last['downloaded'], 4);
      _check(db, changed: true);
      await sync('Windows无变化复验');
      expect(rounds.last['uploaded'], 0);
      expect(rounds.last['downloaded'], 0);
    }
    expect(prefs.read(_local)['marker'], device);
    expect((await repo.load()).password, 'fixture-sync-only');
    expect(
      db.userState.scopedPrefs.findByNamespace('sync_webdav')!.payloadJson,
      isNot(contains('fixture-sync-only')),
    );
  } finally {
    await db.close();
  }
  final reopened = await KonataDatabaseBundle.openFromStorageRoot(storage);
  try {
    _check(reopened, changed: phase != 'seed');
    expect(
      SyncDeviceStore(reopened.userState.syncMeta).getOrCreateDeviceId(),
      device,
    );
    expect(ScopedPrefsStore(reopened.userState).read(_local)['marker'], device);
  } finally {
    await reopened.close();
  }
  debugPrint(
    'DUAL_WEBDAV_EVIDENCE=${jsonEncode({'phase': phase, 'platform': Platform.operatingSystem, 'rounds': rounds, 'diskReopen': true, 'deviceLocalPreserved': true, 'lyricSlice': true, 'rollbackVerified': rollbackVerified})}',
  );
}
