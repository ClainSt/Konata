import 'dart:convert';
import 'dart:io';

import 'package:ccplayer/core/catalog.dart';
import 'package:ccplayer/core/library_backup_exporter.dart';
import 'package:ccplayer/core/library_backup_restorer.dart';
import 'package:ccplayer/core/watch_event_store.dart';
import 'package:ccplayer/core/watched_timeline.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// Phase 0's real Catalog reproducer is now the phase 1 preservation regression.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final catalog = Catalog.instance;
  for (final foundation in [false, true]) {
    final schema = foundation ? 19 : 18;
    for (final count in [12, 3000]) {
      test(
        'isolated round trip and unchanged indexing: $count works schema $schema',
        () async {
          SharedPreferences.setMockInitialValues({'theme_mode': 'dark'});
          final prefs = await SharedPreferences.getInstance();
          final root = await Directory.systemTemp.createTemp('konata-phase0-');
          final source = await Directory('${root.path}/source').create();
          final target = await Directory('${root.path}/target').create();
          final artwork = await Directory('${source.path}/artwork').create();
          await catalog.initialize(
            dataDirectory: source,
            enableFoundation: foundation,
          );
          try {
            expect(await catalog.db.getVersion(), schema);
            await catalog.db.insert('sources', {
              'id': 'fixture',
              'kind': 'local',
              'label': 'Synthetic',
              'location': 'fixture-only',
            });
            final videos = [
              for (var i = 1; i <= count; i++)
                (
                  relative: 'Series $i/01.mkv',
                  size: 1000,
                  folder: 'Series $i',
                  review: true,
                ),
            ];
            final timer = Stopwatch()..start();
            await catalog.indexVideos('fixture', videos);
            final indexMs = timer.elapsedMilliseconds;
            final asset = (await catalog.db.query(
              'assets',
              orderBy: 'id',
            )).first;
            final assetId = asset['id'] as String;
            final workId = asset['work_id'] as String;
            const key = 'tmdb:tv:42:s1:e1';
            final png = base64Decode(
              'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aN1sAAAAASUVORK5CYII=',
            );
            final imageName = 'original_${sha256.convert(png)}.png';
            await File('${artwork.path}/$imageName').writeAsBytes(png);
            await catalog.db.update(
              'works',
              {
                'tmdb_id': 42,
                'tmdb_type': 'tv',
                'bangumi_id': 123,
                'manual_lock': 1,
                'manual_cover_url': 'artwork:$imageName',
                'overview': 'Synthetic manual metadata',
              },
              where: 'id=?',
              whereArgs: [workId],
            );
            await catalog.db.insert('asset_overrides', {
              'asset_id': assetId,
              'work_id': workId,
              'category': asset['category'],
              'season': asset['season'],
              'episode': asset['episode'],
              'extra_type': asset['extra_type'],
            });
            await catalog.logicalEpisodes.confirm(assetId, key);
            await catalog.progress(
              assetId,
              90000,
              100000,
              watchedRanges: [const WatchedRange(0, 90000)],
            );
            expect(
              (await WatchEventStore(catalog.db).uploadCandidate(key)).ready,
              isTrue,
            );

            Future<Map<String, List<Map<String, Object?>>>> snapshot() async =>
                {
                  for (final table in LibraryBackupExporter.tablesForSchema(
                    schema,
                  ))
                    table: await catalog.db.query(table),
                };
            String digest(List<Map<String, Object?>> rows) {
              final normalized = rows.map((row) {
                final keys = row.keys.toList()..sort();
                return jsonEncode({for (final key in keys) key: row[key]});
              }).toList()..sort();
              return sha256
                  .convert(utf8.encode(jsonEncode(normalized)))
                  .toString();
            }

            final before = await snapshot();
            final backup = File('${root.path}/baseline.zip');
            timer.reset();
            await LibraryBackupExporter(
              database: catalog.db,
              artworkDirectory: artwork,
              preferences: prefs,
            ).export(backup);
            final exportMs = timer.elapsedMilliseconds;
            final databaseBytes = await File(catalog.db.path).length();
            await catalog.db.close();
            await catalog.initialize(
              dataDirectory: target,
              enableFoundation: foundation,
            );
            final targetArtwork = await Directory(
              '${target.path}/artwork',
            ).create();
            final restorer = LibraryBackupRestorer(
              database: catalog.db,
              artworkDirectory: targetArtwork,
              preferences: prefs,
            );
            timer.reset();
            final prepared = await restorer.prepare(backup);
            late File rollback;
            try {
              rollback = await restorer.restore(prepared);
            } finally {
              await prepared.dispose();
            }
            final restoreMs = timer.elapsedMilliseconds;
            await catalog.db.close();
            await catalog.initialize(
              dataDirectory: target,
              enableFoundation: foundation,
            );
            final restored = await snapshot();
            for (final table in before.keys) {
              expect(
                digest(restored[table]!),
                digest(before[table]!),
                reason: table,
              );
            }
            expect(
              await File('${targetArtwork.path}/$imageName').readAsBytes(),
              png,
            );
            expect(await catalog.db.rawQuery('PRAGMA integrity_check'), [
              {'integrity_check': 'ok'},
            ]);

            // Create local provenance after restore: portable restore intentionally
            // does not transfer watch_event_local (device identity).
            await catalog.progress(
              assetId,
              90000,
              100000,
              watchedRanges: [const WatchedRange(0, 90000)],
            );
            final store = WatchEventStore(catalog.db);
            expect((await store.uploadCandidate(key)).ready, isTrue);
            final preScan = await snapshot();
            timer.reset();
            await catalog.indexVideos('fixture', videos);
            final repeatMs = timer.elapsedMilliseconds;
            final postScan = await snapshot();
            expect(postScan['assets'], preScan['assets']);
            expect(postScan['works'], preScan['works']);
            expect(postScan['progress'], preScan['progress']);
            expect(postScan['asset_overrides'], preScan['asset_overrides']);
            expect(
              postScan['watch_event_origins']!.every(
                (r) => r['invalidated'] == 0,
              ),
              isTrue,
            );
            expect((await store.uploadCandidate(key)).ready, isTrue);
            final report = {
              'works': count,
              'assets': restored['assets']!.length,
              'schema': schema,
              'initial_index_ms': indexMs,
              'repeat_index_ms': repeatMs,
              'export_ms': exportMs,
              'restore_ms': restoreMs,
              'database_bytes': databaseBytes,
              'zip_bytes': await backup.length(),
              'tables': {
                for (final table in before.keys)
                  table: {
                    'count': before[table]!.length,
                    'sha256': digest(before[table]!),
                  },
              },
              'unchanged_index_invalidates_evidence': false,
            };
            // Machine-readable, synthetic-only evidence; no user paths or secrets.
            // ignore: avoid_print
            print('PHASE0 ${jsonEncode(report)}');
            final undoRestorer = LibraryBackupRestorer(
              database: catalog.db,
              artworkDirectory: targetArtwork,
              preferences: prefs,
            );
            final undo = await undoRestorer.prepare(rollback);
            try {
              await undoRestorer.restore(undo);
            } finally {
              await undo.dispose();
            }
            expect(await catalog.db.query('works'), isEmpty);
            expect(await catalog.db.query('assets'), isEmpty);
          } finally {
            if (catalog.db.isOpen) await catalog.db.close();
            await root.delete(recursive: true);
          }
        },
        timeout: const Timeout(Duration(minutes: 5)),
      );
    }
  }
}
