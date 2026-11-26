import 'dart:io';

import 'package:feature_sync/feature_sync.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';

Map<String, Object?> _identityEncode(Map<String, Object?> value) => value;
Map<String, Object?> _identityDecode(Map<String, Object?> value, int version) =>
    value;

const _appearance = TypedPrefsSlice<Map<String, Object?>>(
  namespace: 'appearance',
  schemaVersion: 1,
  syncPolicy: SyncPolicy.portable,
  defaultValue: {},
  encode: _identityEncode,
  decode: _identityDecode,
);
const _local = TypedPrefsSlice<Map<String, Object?>>(
  namespace: 'sync_webdav',
  schemaVersion: 1,
  syncPolicy: SyncPolicy.deviceLocal,
  defaultValue: {},
  encode: _identityEncode,
  decode: _identityDecode,
);

KonataBackupService _backup(KonataDatabaseBundle db, {required int now}) =>
    KonataBackupService(
      databases: db,
      scopedPrefs: ScopedPrefsStore(db.userState),
      deviceStore: SyncDeviceStore(db.userState.syncMeta, nowMs: () => now),
      nowMs: () => now,
    );

void main() {
  test('黄金源实生成 v1/v2 JSON/gzip 归档明确拒绝，双模式均不修改目标磁盘库', () async {
    final root = await Directory.systemTemp.createTemp(
      'konata-legacy-rejection-',
    );
    addTearDown(() => root.delete(recursive: true));
    final db = await KonataDatabaseBundle.openFromStorageRoot(
      PortableStorageRootService(overrideRootPath: root.path),
    );
    try {
      final prefs = ScopedPrefsStore(db.userState);
      prefs.write(_local, {'baseUrl': 'https://local.example.invalid'});
      const id = WorkId.trusted('keep-existing');
      db.library.works.upsert(const WorkRecord(id: id, title: '本机已整理收藏'));
      final service = _backup(db, now: 1700000001000);
      for (final version in [1, 2]) {
        for (final ext in ['json', 'konata']) {
          final file = File(
            'test/fixtures/legacy_backup/legacy-golden-v$version.$ext',
          );
          final bytes = await KonataBackupService.readArchiveFile(file.path);
          for (final mode in KonataRestoreMode.values) {
            final rejected = throwsA(
              isA<FormatException>().having(
                (e) => e.message,
                'message',
                contains('旧版 Konata v1/v2 备份'),
              ),
            );
            await expectLater(
              service.previewRestore(bytes, mode: mode),
              rejected,
            );
            await expectLater(
              service.restoreFromArchiveBytes(bytes, mode: mode),
              rejected,
            );
          }
        }
      }
      expect(db.library.works.listVisible().single.id, id);
      expect(prefs.read(_local)['baseUrl'], 'https://local.example.invalid');
      expect(db.userState.playbackRecords.listAllWithTombstones(), isEmpty);
    } finally {
      await db.close();
    }
  });

  test('实际磁盘备份恢复到独立新库、关闭重开保留作品关系及观看进度', () async {
    final root = await Directory.systemTemp.createTemp(
      'konata-backup-roundtrip-',
    );
    addTearDown(() => root.delete(recursive: true));
    final sourceRoot = PortableStorageRootService(
      overrideRootPath: '${root.path}/source',
    );
    final targetRoot = PortableStorageRootService(
      overrideRootPath: '${root.path}/target',
    );
    const source = SourceId.trusted('disk-src');
    const work = WorkId.trusted('disk-work');
    const ep = EpisodeId.trusted('disk-episode');
    const variant = VariantId.trusted('disk-variant');
    const series = SeriesGroupId.trusted('disk-series');
    final a = await KonataDatabaseBundle.openFromStorageRoot(sourceRoot);
    final archiveFile = File('${root.path}/actual-backup.konata');
    try {
      a.library.mediaSources.upsert(
        const MediaSourceRecord(
          id: source,
          kind: MediaSourceKind.webdav,
          label: '隔离云盘',
          location: 'https://fixture.example.invalid/dav',
        ),
      );
      a.library.seriesGroups.upsert(
        const SeriesGroupRecord(id: series, title: '隔离系列'),
      );
      a.library.works.upsert(
        const WorkRecord(
          id: work,
          title: '隔离作品',
          tmdbId: 100565,
          tmdbMediaType: TmdbMediaType.tv,
          matchedSeason: 1,
          seriesId: series,
          metadataLocked: true,
          updatedAtMs: 1000,
        ),
      );
      a.library.episodes.upsert(
        const EpisodeRecord(
          id: ep,
          workId: work,
          seasonNumber: 1,
          episodeNumber: 1,
        ),
      );
      a.library.mediaVariants.upsert(
        const MediaVariantRecord(
          id: variant,
          workId: work,
          episodeId: ep,
          sourceId: source,
          relativePath: 'Series/01.mkv',
          fileName: '01.mkv',
          fileSize: 1024,
        ),
      );
      a.userState.playbackRecords.upsert(
        PlaybackRecordEntity(
          id: '${work.value}::${ep.value}',
          canonicalKey: 'tmdb:tv:100565:s1::s1::e1',
          workId: work,
          episodeId: ep,
          variantId: variant,
          seasonNumber: 1,
          episodeNumber: 1,
          episodeTitle: '第一集',
          sourceKind: MediaSourceKind.webdav,
          playedAtMs: 2000,
          positionSeconds: 42,
          durationSeconds: 120,
          isCompleted: false,
          updatedAtMs: 2000,
          sourceDeviceId: 'device-a',
        ),
      );
      final prefs = ScopedPrefsStore(a.userState);
      prefs.write(_appearance, {'themeMode': 'dark'});
      prefs.write(_local, {
        'baseUrl': 'https://source-only.example.invalid',
        'password': 'fixture-secret',
      });
      await archiveFile.writeAsBytes(
        await _backup(a, now: 3000).exportArchiveBytes(),
        flush: true,
      );
    } finally {
      await a.close();
    }
    final b = await KonataDatabaseBundle.openFromStorageRoot(targetRoot);
    try {
      final prefs = ScopedPrefsStore(b.userState);
      prefs.write(_local, {'baseUrl': 'https://target-only.example.invalid'});
      final service = _backup(b, now: 4000);
      final bytes = await KonataBackupService.readArchiveFile(archiveFile.path);
      final archive = await service.decodeAndVerifyArchiveBytes(bytes);
      expect(archive.schemaVersion, 3);
      expect(
        archive.slices['prefs_slice']!.data.toString(),
        isNot(contains('fixture-secret')),
      );
      final preview = await service.previewRestore(bytes);
      expect(preview.totalInserts, greaterThan(0));
      expect(b.library.works.listVisible(), isEmpty);
      expect(b.userState.playbackRecords.listAllWithTombstones(), isEmpty);
      await service.restoreFromArchiveBytes(bytes);
      await service.restoreFromArchiveBytes(bytes);
    } finally {
      await b.close();
    }
    final reopened = await KonataDatabaseBundle.openFromStorageRoot(targetRoot);
    try {
      final restored = reopened.library.works.listVisible().single;
      expect(restored.id, work);
      expect(restored.seriesId, series);
      expect(restored.metadataLocked, isTrue);
      expect(reopened.library.seriesGroups.listAll().single.title, '隔离系列');
      expect(reopened.library.episodes.findById(ep)?.workId, work);
      final restoredVariant = reopened.library.mediaVariants.findById(variant);
      expect(restoredVariant?.episodeId, ep);
      expect(restoredVariant?.sourceId, source);
      final history = reopened.userState.playbackRecords
          .listAllWithTombstones()
          .single;
      expect(history.workId, work);
      expect(history.episodeId, ep);
      expect(history.variantId, variant);
      expect(history.positionSeconds, 42);
      final prefs = ScopedPrefsStore(reopened.userState);
      expect(prefs.read(_appearance)['themeMode'], 'dark');
      expect(
        prefs.read(_local)['baseUrl'],
        'https://target-only.example.invalid',
      );
    } finally {
      await reopened.close();
    }
  });
}
