import 'dart:convert';
import 'dart:io';

import 'package:feature_sync/feature_sync.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';

void main() {
  test('大型目录导出及合并规划五轮基准，完整保留墓碑和规范哈希', () async {
    final db = KonataDatabaseBundle.openInMemory();
    addTearDown(db.close);
    final lib = db.library;
    const works = 1000;
    const perWork = 12;
    const sources = 20;
    lib.engine.runTransaction((tx) {
      for (var i = 0; i < sources; i++) {
        final source = SourceId.trusted('bench-source-$i');
        lib.mediaSources.upsertInTx(
          tx,
          MediaSourceRecord(
            id: source,
            kind: MediaSourceKind.webdav,
            label: 'Source $i',
            location: 'https://fixture.invalid/dav/$i',
            updatedAtMs: 1000,
          ),
        );
        lib.ignoredFolders.upsertInTx(
          tx,
          IgnoredFolderRecord(
            id: '${source.value}::ignore',
            sourceId: source,
            relativePath: 'ignore',
            updatedAtMs: 1000,
            deletedAtMs: i.isEven ? 1000 : null,
          ),
        );
      }
      for (var i = 0; i < works; i++) {
        final work = WorkId.trusted('bench-work-$i');
        lib.works.upsertInTx(
          tx,
          WorkRecord(
            id: work,
            title: 'Fixture $i',
            tmdbId: 100000 + i,
            tmdbMediaType: TmdbMediaType.tv,
            matchedSeason: 1,
            updatedAtMs: 1000,
          ),
        );
        for (var n = 1; n <= perWork; n++) {
          final episode = EpisodeId.trusted('bench-ep-$i-$n');
          final deleted = n == perWork ? 1000 : null;
          lib.episodes.upsertInTx(
            tx,
            EpisodeRecord(
              id: episode,
              workId: work,
              seasonNumber: 1,
              episodeNumber: n,
              updatedAtMs: 1000,
              deletedAtMs: deleted,
            ),
          );
          lib.mediaVariants.upsertInTx(
            tx,
            MediaVariantRecord(
              id: VariantId.trusted('bench-var-$i-$n'),
              workId: work,
              episodeId: episode,
              sourceId: SourceId.trusted('bench-source-${i % sources}'),
              relativePath: 'work-$i/$n.mkv',
              fileName: '$n.mkv',
              fileSize: 100,
              updatedAtMs: 1000,
              deletedAtMs: deleted,
            ),
          );
        }
      }
    });
    final slice = LibraryCatalogSyncSlice(libraryDb: lib, nowMs: () => 1000);
    final warm = await slice.exportSlice(localDeviceId: 'benchmark');
    expect(warm.data['works'], hasLength(works));
    expect(warm.data['episodes'], hasLength(works * perWork));
    expect(warm.data['variants'], hasLength(works * perWork));
    expect(warm.data['ignoredFolders'], hasLength(sources));
    final hash = SyncSanitizer.computeSliceDataSha256(
      sliceId: slice.sliceId,
      schemaVersion: slice.schemaVersion,
      data: warm.data,
    );
    // 固定优化前规范哈希，保护排序、墓碑和导出协议不发生隐式变化。
    expect(
      hash,
      '32b3fbdba04f1bfcc9ffec5179e1b140766992d150d35e007e84f5d898880fd8',
    );
    final exports = <int>[];
    final plans = <int>[];
    for (var i = 0; i < 5; i++) {
      final timer = Stopwatch()..start();
      final next = await slice.exportSlice(localDeviceId: 'benchmark');
      timer.stop();
      exports.add(timer.elapsedMicroseconds);
      expect(
        SyncSanitizer.computeSliceDataSha256(
          sliceId: slice.sliceId,
          schemaVersion: slice.schemaVersion,
          data: next.data,
        ),
        hash,
      );
      timer.reset();
      timer.start();
      final plan = slice.planMerge(local: warm, remote: next);
      timer.stop();
      plans.add(timer.elapsedMicroseconds);
      expect(plan.hasChanges, isFalse);
    }
    stdout.writeln(
      'CATALOG_BENCHMARK ${jsonEncode({'works': works, 'episodes': works * perWork, 'variants': works * perWork, 'sources': sources, 'sha256': hash, 'export_us': exports, 'plan_us': plans})}',
    );
  });
}
