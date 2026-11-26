import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:feature_sync/feature_sync.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';

Map<String, Object?> _encode(Map<String, Object?> value) => value;
Map<String, Object?> _decode(Map<String, Object?> value, int version) => value;
const _appearance = TypedPrefsSlice<Map<String, Object?>>(
  namespace: 'feature_settings.appearance',
  schemaVersion: 1,
  syncPolicy: SyncPolicy.portable,
  defaultValue: {},
  encode: _encode,
  decode: _decode,
);
const _local = TypedPrefsSlice<Map<String, Object?>>(
  namespace: 'sync_webdav',
  schemaVersion: 1,
  syncPolicy: SyncPolicy.deviceLocal,
  defaultValue: {},
  encode: _encode,
  decode: _decode,
);
KonataBackupService _service(KonataDatabaseBundle db) => KonataBackupService(
  databases: db,
  scopedPrefs: ScopedPrefsStore(db.userState),
  deviceStore: SyncDeviceStore(db.userState.syncMeta),
  nowMs: () => 1800000000000,
);
Future<Uint8List> _fixture(int version, [String extension = 'konata']) => File(
  'test/fixtures/legacy_backup/legacy-complete-v$version.$extension',
).readAsBytes();
Future<Uint8List> _mutate(
  int version,
  void Function(Map<String, Object?>) change, {
  bool rehash = true,
}) async {
  final root =
      jsonDecode(utf8.decode(await _fixture(version, 'json')))
          as Map<String, Object?>;
  final payload = root['payload']! as Map<String, Object?>;
  change(payload);
  if (rehash) {
    root['payloadSha256'] = sha256
        .convert(utf8.encode(jsonEncode(payload)))
        .toString();
  }
  return Uint8List.fromList(utf8.encode(jsonEncode(root)));
}

void _seedV1(KonataDatabaseBundle db) {
  db.library.mediaSources.upsert(
    const MediaSourceRecord(
      id: SourceId.trusted('local-source'),
      kind: MediaSourceKind.local,
      label: '隔离源',
      location: 'D:/isolated',
    ),
  );
  db.library.works.upsert(
    const WorkRecord(
      id: WorkId.trusted('local-work'),
      title: '合成作品',
      tmdbId: 100565,
      tmdbMediaType: TmdbMediaType.tv,
      matchedSeason: 1,
      bangumiId: 293049,
    ),
  );
  db.library.episodes.upsert(
    const EpisodeRecord(
      id: EpisodeId.trusted('local-ep'),
      workId: WorkId.trusted('local-work'),
      seasonNumber: 1,
      episodeNumber: 1,
    ),
  );
  db.library.mediaVariants.upsert(
    const MediaVariantRecord(
      id: VariantId.trusted('local-video'),
      workId: WorkId.trusted('local-work'),
      episodeId: EpisodeId.trusted('local-ep'),
      sourceId: SourceId.trusted('local-source'),
      relativePath: '01.mkv',
      fileName: '01.mkv',
      fileSize: 1024,
    ),
  );
}

void main() {
  test('真实黄金源 v2 压缩备份迁移空磁盘库，重开保留六类目录、锁及进度', () async {
    final root = await Directory.systemTemp.createTemp(
      'konata-legacy-complete-',
    );
    addTearDown(() => root.delete(recursive: true));
    final storage = PortableStorageRootService(overrideRootPath: root.path);
    final db = await KonataDatabaseBundle.openFromStorageRoot(storage);
    try {
      final prefs = ScopedPrefsStore(db.userState);
      prefs.write(_local, {
        'baseUrl': 'https://device-only.invalid',
        'password': 'fixture-secret',
      });
      final service = _service(db);
      final bytes = await _fixture(2);
      for (final ext in ['json', 'konata']) {
        final preview = await service.previewRestore(await _fixture(2, ext));
        expect(preview.legacyFormatVersion, 2);
        expect(preview.archiveSliceIds.toSet(), {
          PrefsSyncSlice.id,
          LibraryCatalogSyncSlice.id,
          PlaybackHistorySyncSlice.id,
        });
        expect(preview.totalInserts, 12);
      }
      expect(db.library.works.listVisible(), isEmpty);
      expect(db.userState.playbackRecords.listAllWithTombstones(), isEmpty);
      await expectLater(
        service.restoreFromArchiveBytes(
          bytes,
          mode: KonataRestoreMode.overwrite,
        ),
        throwsFormatException,
      );
      await expectLater(
        service.restoreFromArchiveBytes(
          bytes,
          selectedSliceIds: {PlaybackHistorySyncSlice.id},
        ),
        throwsFormatException,
      );
      for (final ids in [
        {LibraryCatalogSyncSlice.id},
        {LibraryCatalogSyncSlice.id, PlaybackHistorySyncSlice.id},
        {PrefsSyncSlice.id},
      ]) {
        await expectLater(
          service.restoreFromArchiveBytes(bytes, selectedSliceIds: ids),
          throwsFormatException,
        );
      }
      expect(db.library.works.listVisible(), isEmpty);
      await service.restoreFromArchiveBytes(bytes);
    } finally {
      await db.close();
    }
    final reopened = await KonataDatabaseBundle.openFromStorageRoot(storage);
    try {
      final work = reopened.library.works.listVisible().single;
      expect(work.id.value, 'old-work');
      expect(work.seriesId?.value, 'old-series');
      expect(work.metadataLocked, isTrue);
      expect(work.seriesLocked, isTrue);
      expect(
        work.posterRef,
        const RemoteArtworkRef(
          source: ArtworkSource.tmdb,
          uri: '/synthetic.jpg',
          locked: true,
        ),
      );
      expect(
        work.logoRef,
        const RemoteArtworkRef(
          source: ArtworkSource.fanart,
          uri: 'https://assets.fanart.tv/synthetic.png',
          locked: true,
        ),
      );
      expect(reopened.library.episodes.listByWork(work.id), hasLength(2));
      final variants = reopened.library.mediaVariants.listByWork(work.id);
      expect(variants, hasLength(4));
      expect(
        variants.singleWhere((v) => v.id.value == 'old-extra').assetScope,
        SupplementaryAssetScope.seriesShared,
      );
      expect(
        variants.singleWhere((v) => v.id.value == 'old-extra').scopeLocked,
        isTrue,
      );
      expect(
        variants
            .singleWhere((v) => v.id.value == 'old-video')
            .externalSubtitles,
        ['Series/01.sc.ass'],
      );
      expect(
        variants.singleWhere((v) => v.id.value == 'old-video').mappingLocked,
        isTrue,
      );
      expect(
        reopened.library.ignoredFolders
            .listBySource(const SourceId.trusted('old-src'))
            .single
            .relativePath,
        'Ignore',
      );
      final history = reopened.userState.playbackRecords
          .listAllWithTombstones()
          .single;
      expect(history.workId, work.id);
      expect(history.variantId.value, 'old-video');
      expect(history.episodeId.value, 'old-ep');
      expect(history.positionSeconds, 42);
      final prefs = ScopedPrefsStore(reopened.userState);
      expect(prefs.read(_appearance), {
        'themeMode': 'light',
        'windowMaterial': 'mica',
        'ambientBackdropEnabled': true,
      });
      expect(prefs.read(_local)['baseUrl'], 'https://device-only.invalid');
      await expectLater(
        _service(reopened).restoreFromArchiveBytes(await _fixture(2)),
        throwsFormatException,
      );
      expect(reopened.library.works.listVisible(), hasLength(1));
      expect(
        reopened.userState.playbackRecords.listAllWithTombstones(),
        hasLength(1),
      );
    } finally {
      await reopened.close();
    }
  });

  test('v1 通过唯一逻辑身份恢复至不同物理ID，重复合并不增加记录', () async {
    final db = KonataDatabaseBundle.openInMemory();
    addTearDown(db.close);
    _seedV1(db);
    final service = _service(db);
    for (final ext in ['json', 'konata']) {
      final bytes = await _fixture(1, ext);
      expect((await service.previewRestore(bytes)).legacyFormatVersion, 1);
      await service.restoreFromArchiveBytes(bytes);
    }
    final history = db.userState.playbackRecords.listAllWithTombstones().single;
    expect(history.positionSeconds, 42);
    expect(history.workId.value, 'local-work');
    expect(history.episodeId.value, 'local-ep');
    expect(history.variantId.value, 'local-video');
  });

  test('篡改、未知偏好、墓碑、旧音频、路径穿越、未知目录字段与隐藏语义拒绝', () async {
    final db = KonataDatabaseBundle.openInMemory();
    addTearDown(db.close);
    final service = _service(db);
    final cases = <Uint8List>[
      await _mutate(
        2,
        (p) => (p['playbackEntries']! as List).clear(),
        rehash: false,
      ),
      await _mutate(
        2,
        (p) =>
            ((p['preferences']! as Map<String, Object?>)['values']!
                    as Map<String, Object?>)['unknown_pref'] =
                true,
      ),
      await _mutate(
        2,
        (p) => (p['tombstones']! as List).add({
          'entityKey': 'test',
          'entityType': 'playback',
          'deletedAtMs': 1700000000000,
          'deviceId': 'old',
        }),
      ),
      await _mutate(
        2,
        (p) =>
            ((p['playbackEntries']! as List).first
                    as Map<String, Object?>)['isAudio'] =
                true,
      ),
      await _mutate(
        2,
        (p) =>
            (((p['libraryCatalog']! as Map<String, Object?>)['variants']!
                            as List)
                        .first
                    as Map<String, Object?>)['relativePath'] =
                '../outside.mkv',
      ),
      await _mutate(
        2,
        (p) =>
            (((p['libraryCatalog']! as Map<String, Object?>)['works']! as List)
                        .first
                    as Map<String, Object?>)['futureField'] =
                'unsupported',
      ),
      await _mutate(
        2,
        (p) =>
            (((p['libraryCatalog']! as Map<String, Object?>)['works']! as List)
                        .first
                    as Map<String, Object?>)['isHidden'] =
                true,
      ),
      await _mutate(
        2,
        (p) =>
            (((p['libraryCatalog']! as Map<String, Object?>)['works']! as List)
                        .first
                    as Map<String, Object?>)['posterPath'] =
                'D:/private/custom.jpg',
      ),
    ];
    for (final bytes in cases) {
      await expectLater(service.previewRestore(bytes), throwsFormatException);
      await expectLater(
        service.restoreFromArchiveBytes(bytes),
        throwsFormatException,
      );
      expect(db.library.works.listVisible(), isEmpty);
      expect(db.userState.playbackRecords.listAllWithTombstones(), isEmpty);
      expect(ScopedPrefsStore(db.userState).read(_appearance), isEmpty);
    }
  });

  test('旧视频墓碑在无历史与有历史目标均正确落盘，旧进度不复活，新进度可恢复', () async {
    for (final seedHistory in [false, true]) {
      final db = KonataDatabaseBundle.openInMemory();
      try {
        _seedV1(db);
        final service = _service(db);
        final active = await _fixture(1);
        if (seedHistory) await service.restoreFromArchiveBytes(active);
        const deletedAt = 1700000000001;
        final tombstone = await _mutate(1, (p) {
          (p['playbackEntries']! as List).clear();
          (p['tombstones']! as List).add({
            'entityKey': 'playback::tmdb:tv:100565:s1::s1::e1',
            'entityType': 'playback',
            'deletedAtMs': deletedAt,
            'deviceId': 'legacy-delete',
          });
        });
        final preview = await service.previewRestore(tombstone);
        expect(preview.totalDeletes, seedHistory ? 1 : 0);
        await service.restoreFromArchiveBytes(tombstone);
        await service.restoreFromArchiveBytes(tombstone);
        var record = db.userState.playbackRecords
            .listAllWithTombstones()
            .single;
        expect(record.deletedAtMs, deletedAt);
        expect(record.variantId.value, 'local-video');
        await service.restoreFromArchiveBytes(active);
        expect(
          db.userState.playbackRecords
              .listAllWithTombstones()
              .single
              .deletedAtMs,
          deletedAt,
        );
        final newer = await _mutate(1, (p) {
          final row =
              (p['playbackEntries']! as List).first as Map<String, Object?>;
          row['updatedAtMs'] = deletedAt + 1;
          row['playedAtMs'] = deletedAt + 1;
          row['positionSeconds'] = 55;
        });
        await service.restoreFromArchiveBytes(newer);
        record = db.userState.playbackRecords.listAllWithTombstones().single;
        expect(record.deletedAtMs, isNull);
        expect(record.positionSeconds, 55);
        await service.restoreFromArchiveBytes(tombstone);
        expect(
          db.userState.playbackRecords
              .listAllWithTombstones()
              .single
              .deletedAtMs,
          isNull,
        );
      } finally {
        await db.close();
      }
    }
  });

  test('v2 同一备份内活跃记录与墓碑按时间裁决，作品墓碑仍拒绝', () async {
    final db = KonataDatabaseBundle.openInMemory();
    addTearDown(db.close);
    final service = _service(db);
    final unsupported = await _mutate(2, (p) {
      (p['tombstones']! as List).add({
        'entityKey': 'work_id::old-work',
        'entityType': 'work_catalog',
        'deletedAtMs': 1700000000001,
        'deviceId': 'legacy-delete',
      });
    });
    await expectLater(
      service.restoreFromArchiveBytes(unsupported),
      throwsFormatException,
    );
    final bytes = await _mutate(2, (p) {
      (p['tombstones']! as List).add({
        'entityKey': 'playback::tmdb:tv:100565:s1::s1::e1',
        'entityType': 'playback',
        'deletedAtMs': 1700000000001,
        'deviceId': 'legacy-delete',
      });
    });
    await service.restoreFromArchiveBytes(bytes);
    expect(db.library.works.listVisible(), hasLength(1));
    final record = db.userState.playbackRecords.listAllWithTombstones().single;
    expect(record.deletedAtMs, 1700000000001);
    expect(record.variantId.value, 'old-video');
  });

  test('v1 未匹配与歧义物理版本拒绝，现有库保持不变', () async {
    final db = KonataDatabaseBundle.openInMemory();
    addTearDown(db.close);
    final bytes = await _fixture(1);
    final service = _service(db);
    await expectLater(
      service.restoreFromArchiveBytes(bytes),
      throwsFormatException,
    );
    _seedV1(db);
    db.library.mediaVariants.upsert(
      const MediaVariantRecord(
        id: VariantId.trusted('second-video'),
        workId: WorkId.trusted('local-work'),
        episodeId: EpisodeId.trusted('local-ep'),
        sourceId: SourceId.trusted('local-source'),
        relativePath: '01-alt.mkv',
        fileName: '01-alt.mkv',
        fileSize: 1024,
      ),
    );
    await expectLater(service.previewRestore(bytes), throwsFormatException);
    await expectLater(
      service.restoreFromArchiveBytes(bytes),
      throwsFormatException,
    );
    expect(db.library.works.listVisible(), hasLength(1));
    expect(db.userState.playbackRecords.listAllWithTombstones(), isEmpty);
  });
}
