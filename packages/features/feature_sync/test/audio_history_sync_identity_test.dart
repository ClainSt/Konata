import 'package:feature_sync/feature_sync.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';

void main() {
  test('跨库备份恢复整轨 FLAC 的两条 CUE 断点时保留各自分轨身份', () async {
    final origin = KonataDatabaseBundle.openInMemory();
    final target = KonataDatabaseBundle.openInMemory();
    addTearDown(origin.close);
    addTearDown(target.close);
    for (final (db, host) in [(origin, 'origin'), (target, 'target')]) {
      final sourceId = SourceId.trusted('$host-source');
      final workId = WorkId.trusted('$host-work');
      db.library.mediaSources.upsert(
        MediaSourceRecord(
          id: sourceId,
          kind: MediaSourceKind.local,
          label: host,
          location: 'D:/isolated/$host',
        ),
      );
      db.library.works.upsert(
        WorkRecord(
          id: workId,
          title: '隔离作品',
          tmdbId: 90001,
          tmdbMediaType: TmdbMediaType.tv,
          matchedSeason: 1,
        ),
      );
      db.library.mediaVariants.upsert(
        MediaVariantRecord(
          id: VariantId.trusted('$host-flac'),
          workId: workId,
          sourceId: sourceId,
          relativePath: 'CD/Album.flac',
          fileName: 'Album.flac',
          fileSize: 1024,
          assetKind: AssetKind.cdAlbum,
        ),
      );
    }
    for (final track in [2, 3]) {
      origin.userState.playbackRecords.upsert(
        PlaybackRecordEntity(
          id: 'cd::origin-work::origin-flac#cue:$track',
          workId: const WorkId.trusted('origin-work'),
          episodeId: EpisodeId.trusted('cd::origin-flac#cue:$track'),
          variantId: const VariantId.trusted('origin-flac'),
          seasonNumber: 0,
          episodeNumber: track,
          episodeTitle: '曲目 $track',
          sourceKind: MediaSourceKind.local,
          playedAtMs: 1000 + track,
          updatedAtMs: 1000 + track,
          positionSeconds: track * 10,
          durationSeconds: 100,
        ),
      );
    }
    KonataBackupService service(KonataDatabaseBundle db) => KonataBackupService(
      databases: db,
      scopedPrefs: ScopedPrefsStore(db.userState),
      deviceStore: SyncDeviceStore(db.userState.syncMeta),
      nowMs: () => 3000,
    );

    final from = service(origin);
    final to = service(target);
    const slices = {PlaybackHistorySyncSlice.id};
    final archive = await from.exportArchiveBytes(sliceIds: slices);
    expect((await to.previewRestore(archive)).totalInserts, 2);
    await to.restoreFromArchiveBytes(archive);
    await to.restoreFromArchiveBytes(archive);
    final dao = target.userState.playbackRecords;
    final saved = dao.listAllWithTombstones();
    expect(saved, hasLength(2));
    expect(
      {
        for (final record in saved)
          record.episodeId.value: record.positionSeconds,
      },
      {'cd::target-flac#cue:2': 20, 'cd::target-flac#cue:3': 30},
    );
    expect(
      saved.map((record) => record.variantId.value),
      everyElement('target-flac'),
    );
    expect(
      saved.map((record) => record.id),
      unorderedEquals([
        'cd::target-work::target-flac#cue:2',
        'cd::target-work::target-flac#cue:3',
      ]),
    );

    origin.userState.playbackRecords.softDelete(
      'cd::origin-work::origin-flac#cue:2',
      deletedAtMs: 2500,
    );
    final deleted = await from.exportArchiveBytes(sliceIds: slices);
    await to.restoreFromArchiveBytes(deleted);
    await to.restoreFromArchiveBytes(archive);
    final after = dao.listAllWithTombstones();
    expect(after, hasLength(2));
    final byTrack = {for (final record in after) record.episodeNumber: record};
    expect(byTrack[2]!.deletedAtMs, 2500);
    expect(byTrack[3]!.deletedAtMs, isNull);
    expect(byTrack[3]!.positionSeconds, 30);
  });
}
