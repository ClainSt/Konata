import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:ccplayer/core/catalog.dart';
import 'package:ccplayer/core/library_backup_exporter.dart';
import 'package:ccplayer/core/library_backup_inspector.dart';
import 'package:ccplayer/core/logical_episode_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'confirmed identity persists across paths, respects corrections and revokes',
    () async {
      final dir = await Directory.systemTemp.createTemp('ccplayer-identity-');
      final cat = Catalog.instance;
      await cat.initialize(dataDirectory: dir);
      try {
        final db = cat.db;
        await db.insert('works', {
          'id': 'w',
          'title': 'Anime',
          'tmdb_type': 'tv',
          'tmdb_id': 42,
        });
        for (final id in ['local', 'dav']) {
          await db.insert('sources', {
            'id': id,
            'kind': id == 'local' ? 'local' : 'webdav',
            'label': id,
            'location': id == 'local'
                ? r'D:\Anime'
                : 'https://example.invalid/anime',
          });
          await db.insert('assets', {
            'id': id,
            'source_id': id,
            'work_id': 'w',
            'relative_path': '$id/01.mkv',
            'name': '$id.mkv',
            'category': 'main',
            'season': 1,
            'episode': 1,
          });
        }
        final store = LogicalEpisodeStore(db);
        const key = 'tmdb:tv:42:s1:e1';
        expect(await store.resolve('local'), isNull);
        await expectLater(
          store.confirm('local', 'tmdb:tv:42:s1:e2'),
          throwsStateError,
        );
        await store.confirm('local', key);
        await store.confirm('dav', key);
        await db.update(
          'assets',
          {'relative_path': 'BD/new-name.x265.mkv'},
          where: 'id=?',
          whereArgs: ['dav'],
        );
        expect(await store.resolve('local'), key);
        expect(await store.resolve('dav'), key);
        // Progress remains separate: duration and positions are never rescaled.
        await cat.progress('local', 90000, 100000);
        await cat.progress('dav', 5000, 110000);
        expect((await db.query('progress')).length, 2);
        expect(
          (await db.query('progress')).every((r) => r['completed'] == 0),
          isTrue,
        );
        await db.insert('asset_overrides', {
          'asset_id': 'dav',
          'work_id': 'w',
          'category': 'extra',
          'season': 0,
          'episode': 3,
          'extra_type': 'SP',
        });
        expect(await store.resolve('dav'), 'tmdb:tv:42:s0:e3');
        await db.update(
          'asset_overrides',
          {'category': 'other', 'episode': null},
          where: 'asset_id=?',
          whereArgs: ['dav'],
        );
        expect(await store.resolve('dav'), isNull);
        await store.revoke('local');
        expect(await store.resolve('local'), isNull);
        await store.revoke('local'); // Repeated revocation is a no-op.
        expect((await db.query('logical_episode_confirmations')).length, 3);
        await db.close();
        await cat.initialize(dataDirectory: dir);
        expect(await LogicalEpisodeStore(cat.db).resolve('local'), isNull);
        expect((await cat.db.query('progress')).length, 2);
      } finally {
        await cat.db.close();
        await dir.delete(recursive: true);
      }
    },
  );

  test(
    'v15 upgrade preserves history and both backup schemas remain readable',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'ccplayer-identity-upgrade-',
      );
      final cat = Catalog.instance;
      await cat.initialize(dataDirectory: dir);
      try {
        await cat.db.execute('DROP TABLE logical_episode_confirmations');
        await cat.db.setVersion(15);
        await cat.progress('legacy', 987, 1234);
        final before = await cat.db.query('progress');
        await cat.db.close();
        await cat.initialize(dataDirectory: dir);
        expect(await cat.db.getVersion(), 18);
        expect(await cat.db.query('progress'), before);
        // Orphaned legacy progress is allowed by SQLite, but not by backup
        // inspection: remove only this synthetic fixture before exporting.
        await cat.db.delete('progress');
        SharedPreferences.setMockInitialValues({});
        final backup = await LibraryBackupExporter(
          database: cat.db,
          artworkDirectory: Directory('${dir.path}/artwork'),
          preferences: await SharedPreferences.getInstance(),
        ).export(File('${dir.path}/v16.zip'));
        await LibraryBackupInspector.inspect(backup);
        final archive = ZipDecoder().decodeBytes(await backup.readAsBytes());
        final manifest =
            jsonDecode(
                  utf8.decode(archive.findFile('manifest.json')!.readBytes()!),
                )
                as Map<String, dynamic>;
        manifest['db_schema_version'] = 16;
        (manifest['tables'] as Map).remove('bangumi_episode_mappings');
        (manifest['tables'] as Map).remove('watch_event_origins');
        (manifest['tables'] as Map).remove('watch_identity_epochs');
        (manifest['tables'] as Map).remove('watch_events');
        final previous = ZipFileEncoder()..create('${dir.path}/v16-legacy.zip');
        previous.addArchiveFile(
          ArchiveFile.string('manifest.json', jsonEncode(manifest)),
        );
        await previous.close();
        await LibraryBackupInspector.inspect(
          File('${dir.path}/v16-legacy.zip'),
        );
        manifest['db_schema_version'] = 15;
        (manifest['tables'] as Map).remove('logical_episode_confirmations');
        final zip = ZipFileEncoder()..create('${dir.path}/v15.zip');
        zip.addArchiveFile(
          ArchiveFile.string('manifest.json', jsonEncode(manifest)),
        );
        await zip.close();
        await LibraryBackupInspector.inspect(File('${dir.path}/v15.zip'));
      } finally {
        await cat.db.close();
        await dir.delete(recursive: true);
      }
    },
  );
}
