import 'dart:convert';
import 'dart:io';

import 'package:feature_sync/feature_sync.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';

void main() {
  test('大型播放历史导出五轮基准及音频墓碑身份保护', () async {
    final db = KonataDatabaseBundle.openInMemory();
    addTearDown(db.close);
    final lib = db.library;
    const works = 1000;
    const perWork = 12;
    const source = SourceId.trusted('bench-source');
    lib.engine.runTransaction((tx) {
      lib.mediaSources.upsertInTx(
        tx,
        const MediaSourceRecord(
          id: source,
          kind: MediaSourceKind.webdav,
          label: 'Fixture',
          location: 'https://fixture.invalid/dav',
        ),
      );
      for (var i = 0; i < works; i++) {
        final work = WorkId.trusted('bench-work-$i');
        lib.works.upsertInTx(
          tx,
          WorkRecord(
            id: work,
            title: 'Fixture $i',
            tmdbId: 100000 + i,
            bangumiId: 200000 + i,
            tmdbMediaType: TmdbMediaType.tv,
            matchedSeason: 1,
            updatedAtMs: 1000,
          ),
        );
        for (var n = 1; n <= perWork; n++) {
          final audio = n >= 11;
          lib.mediaVariants.upsertInTx(
            tx,
            MediaVariantRecord(
              id: VariantId.trusted('bench-var-$i-$n'),
              workId: work,
              sourceId: source,
              relativePath: 'work-$i/$n.${audio ? 'flac' : 'mkv'}',
              fileName: '$n.${audio ? 'flac' : 'mkv'}',
              fileSize: 100,
              assetKind: audio ? AssetKind.cdAlbum : AssetKind.video,
              externalSubtitles: audio ? const [] : ['work-$i/$n.ass'],
              deletedAtMs: n == 12 ? 2000 : null,
            ),
          );
        }
      }
    });
    final slice = PlaybackHistorySyncSlice(databases: db, nowMs: () => 3000);
    expect(
      (await slice.exportSlice(localDeviceId: 'benchmark')).data['records'],
      isEmpty,
    );
    db.userState.engine.runTransaction((tx) {
      for (var i = 0; i < works; i++) {
        for (final n in [1, 2, 11, 12]) {
          final audio = n >= 11;
          final variant = VariantId.trusted('bench-var-$i-$n');
          db.userState.playbackRecords.upsertInTx(
            tx,
            PlaybackRecordEntity(
              id: audio
                  ? 'cd::bench-work-$i::${variant.value}#cue:2'
                  : 'bench-work-$i::ep-$n',
              workId: WorkId.trusted('bench-work-$i'),
              episodeId: EpisodeId.trusted(
                audio ? 'cd::${variant.value}#cue:2' : 'ep-$n',
              ),
              variantId: variant,
              seasonNumber: audio ? 0 : 1,
              episodeNumber: audio ? 2 : n,
              episodeTitle: 'Track $n',
              positionSeconds: 20,
              durationSeconds: 100,
              playedAtMs: 1000,
              updatedAtMs: n == 12 ? 2000 : 1000,
              deletedAtMs: n == 12 ? 2000 : null,
            ),
          );
        }
      }
    });
    final warm = await slice.exportSlice(localDeviceId: 'benchmark');
    final rows = (warm.data['records']! as List).cast<Map<String, Object?>>();
    expect(rows, hasLength(4000));
    expect(rows.where((r) => r['isAudio'] == true), hasLength(2000));
    expect(
      rows.where((r) => r['deletedAtMs'] != null && r['isAudio'] == true),
      hasLength(1000),
    );
    String hash(SyncSlicePayload payload) =>
        SyncSanitizer.computeSliceDataSha256(
          sliceId: slice.sliceId,
          schemaVersion: slice.schemaVersion,
          data: payload.data,
        );
    final digest = hash(warm);
    expect(
      digest,
      '4c3a3c62142d13fb7e3d014f85751de612a269fc52364dad348a0dd53a16b7e8',
    );
    final times = <int>[];
    for (var i = 0; i < 5; i++) {
      final timer = Stopwatch()..start();
      final next = await slice.exportSlice(localDeviceId: 'benchmark');
      timer.stop();
      times.add(timer.elapsedMicroseconds);
      expect(hash(next), digest);
    }
    stdout.writeln(
      'HISTORY_BENCHMARK ${jsonEncode({'works': works, 'variants': works * perWork, 'records': rows.length, 'sha256': digest, 'export_us': times})}',
    );
  });
}
