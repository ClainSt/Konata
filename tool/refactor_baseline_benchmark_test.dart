import 'dart:convert';
import 'dart:io';

import 'package:ccplayer/core/catalog.dart';
import 'package:ccplayer/core/library_backup_exporter.dart';
import 'package:ccplayer/core/library_backup_restorer.dart';
import 'package:ccplayer/core/playback_history.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test/refactor_baseline_support.dart';

/// Run separately, concurrency=1. Timings are observations, never CI thresholds.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final count in [100, 1000]) {
    test(
      'synthetic library benchmark $count',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'konata-baseline-bench-',
        );
        await openBaselineCatalog(Directory('${root.path}/db'));
        try {
          await seedBaselineCatalog(count);
          final catalog = Catalog.instance;
          final artwork = await Directory('${root.path}/artwork').create();
          final exporter = LibraryBackupExporter(
            database: catalog.db,
            artworkDirectory: artwork,
            preferences: await SharedPreferences.getInstance(),
          );
          final restorer = LibraryBackupRestorer(
            database: catalog.db,
            artworkDirectory: artwork,
          );
          var sequence = 0;
          Future<void> measure(String name, Future<void> Function() run) async {
            await run(); // One unmeasured warm-up.
            final samples = <int>[];
            final rssBefore = ProcessInfo.currentRss;
            for (var i = 0; i < 3; i++) {
              final clock = Stopwatch()..start();
              await run();
              samples.add(clock.elapsedMicroseconds);
            }
            // RSS is process-wide before/after, NOT a per-operation peak.
            // Machine-readable benchmark output, deliberately not app logging.
            // ignore: avoid_print
            print(
              'BASELINE_BENCHMARK ${jsonEncode({'operation': name, 'works': count, 'assets': count, 'progress': count, 'schema': 27, 'warmups': 1, 'samples_us': samples, 'rss_before_bytes': rssBefore, 'rss_after_bytes': ProcessInfo.currentRss})}',
            );
          }

          await measure('catalog.reload', () async {
            await catalog.reload();
            expect(catalog.assets, hasLength(count));
          });
          await measure('playback_history.entries', () async {
            expect(
              await PlaybackHistory(catalog.db).entries(),
              hasLength(count),
            );
          });
          await measure('backup.export', () async {
            final file = await exporter.export(
              File('${root.path}/export-${sequence++}.zip'),
            );
            expect(await file.length(), greaterThan(0));
            await file.delete();
          });
          final archive = await exporter.export(
            File('${root.path}/preview.zip'),
          );
          final prepared = await restorer.prepare(archive);
          try {
            await measure('merge.preview_identical_library', () async {
              final review = await restorer.previewMerge(prepared, {});
              expect(review.fingerprint, hasLength(64));
            });
          } finally {
            await prepared.dispose();
          }
        } finally {
          await closeBaselineCatalog();
          await root.delete(recursive: true);
        }
      },
      timeout: const Timeout(Duration(minutes: 10)),
    );
  }
}
