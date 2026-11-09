import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:ccplayer/core/catalog.dart';
import 'package:ccplayer/core/artwork_cache.dart';
import 'package:ccplayer/core/library_backup_exporter.dart';
import 'package:ccplayer/core/library_backup_restorer.dart';
import 'package:ccplayer/core/watch_event_store.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
// Test the storage failure boundary of the existing preferences dependency.
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

class _FailOncePreferences extends InMemorySharedPreferencesStore {
  _FailOncePreferences(super.data) : super.withData();
  bool failed = false;
  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (!failed && key == 'flutter.theme_accent') {
      failed = true;
      return false;
    }
    return super.setValue(valueType, key, value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final catalog = Catalog.instance;
  late Directory temp, artwork;
  late SharedPreferences prefs;
  late LibraryBackupRestorer restorer;
  late File archive;
  late String imageName;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'theme_mode': 'dark',
      'theme_accent': 'red',
      'ui_language': 'zhHans',
      'watched_completion_percent': 85,
      'unrelated': 'keep',
    });
    prefs = await SharedPreferences.getInstance();
    temp = await Directory.systemTemp.createTemp('konata-restore-test-');
    artwork = await Directory('${temp.path}/artwork').create();
    await catalog.initialize(dataDirectory: temp);
    final db = catalog.db;
    await db.insert('sources', {
      'id': 's',
      'kind': 'local',
      'label': 'Local',
      'location': 'D:/Anime',
    });
    const bytes = [1, 2, 3, 4];
    imageName = 'crop_${sha256.convert(bytes)}.png';
    await File('${artwork.path}/$imageName').writeAsBytes(bytes);
    await db.insert('works', {
      'id': 'w',
      'title': 'Restored anime',
      'tmdb_id': 42,
      'tmdb_type': 'tv',
      'manual_lock': 1,
      'manual_cover_url': 'artwork:$imageName',
      'cover_edit_json': jsonEncode({'resource': 'artwork:$imageName'}),
      'character_order': '[2,1]',
      'hidden': 1,
    });
    await db.insert('assets', {
      'id': 'a',
      'source_id': 's',
      'work_id': 'w',
      'relative_path': '01.mkv',
      'name': '01.mkv',
      'category': 'main',
      'episode': 1,
    });
    await db.insert('asset_overrides', {
      'asset_id': 'a',
      'work_id': 'w',
      'category': 'main',
      'episode': 1,
    });
    await db.insert('asset_override_history', {
      'asset_id': 'a',
      'work_id': 'w',
      'category': 'main',
      'episode': 2,
      'was_locked': 1,
    });
    await db.insert('work_details', {
      'work_id': 'w',
      'identity': 'tmdb:42',
      'payload': '{"characters":[{"id":1}]}',
      'fetched_at': '2026-11-08T00:00:00Z',
    });
    await db.insert('progress', {
      'asset_id': 'a',
      'position_ms': 12345,
      'duration_ms': 24000,
      'completed': 0,
      'manual_completed': 1,
      'watched_ranges': '[[0,12345]]',
      'updated_at': '2026-11-08T00:00:00Z',
    });
    await db.transaction(
      (tx) => WatchEventStore.recordManual(
        tx,
        'tmdb:tv:42:s1:e1',
        true,
        assetId: 'a',
      ),
    );
    await db.insert('logical_episode_confirmations', {
      'id': 1,
      'asset_id': 'a',
      'logical_key': 'tmdb:tv:42:s1:e1',
      'revoked': 0,
      'created_at': '2026-11-08T00:00:00Z',
    });
    final revision = (await db.query(
      'watch_identity_epochs',
    )).single['revision'];
    await db.insert('bangumi_episode_mappings', {
      'id': 1,
      'episode_key': 'tmdb:tv:42:s1:e1',
      'asset_id': 'a',
      'revision': revision,
      'subject_id': 123,
      'episode_id': 456,
      'episode_type': 0,
      'episode_sort': 1.0,
      'episode_name': 'Episode 1',
      'verified_at': '2026-11-08T00:00:00Z',
      'revoked': 0,
    });
    await db.insert('phantom_asset_archive', {
      'obsolete_asset_id': 'obsolete',
      'canonical_asset_id': 'a',
      'asset_json': '{"id":"obsolete"}',
      'progress_json': null,
      'override_json': null,
      'history_json': null,
      'archived_at': '2026-11-08T00:00:00Z',
    });
    archive = File('${temp.path}/export.zip');
    await LibraryBackupExporter(
      database: db,
      artworkDirectory: artwork,
      preferences: prefs,
    ).export(archive);
    restorer = LibraryBackupRestorer(
      database: db,
      artworkDirectory: artwork,
      preferences: prefs,
    );
  });

  tearDown(() async {
    await catalog.db.close();
    await temp.delete(recursive: true);
  });

  Future<PreparedLibraryBackup> prepare() async {
    final prepared = await restorer.prepare(archive);
    addTearDown(prepared.dispose);
    return prepared;
  }

  Future<void> mutateArchive(void Function(Map<String, dynamic>) edit) async {
    final decoded = ZipDecoder().decodeBytes(await archive.readAsBytes());
    final manifest =
        jsonDecode(utf8.decode(decoded.findFile('manifest.json')!.content))
            as Map<String, dynamic>;
    edit(manifest);
    final out = ZipFileEncoder();
    out.create(archive.path);
    out.addArchiveFile(
      ArchiveFile.string('manifest.json', jsonEncode(manifest)),
    );
    for (final file in decoded.files.where((f) => f.name != 'manifest.json')) {
      out.addArchiveFile(file);
    }
    await out.close();
  }

  test(
    'restore drops obsolete cache owners but preserves hidden works and originals',
    () async {
      await catalog.db.insert('works', {'id': 'extra', 'title': 'Old library'});
      final cache = ArtworkCache(artwork);
      try {
        await cache.retain('extra', ['obsolete', 'shared']);
        await cache.retain('w', ['shared']);
        await cache.write('obsolete', Uint8List.fromList([7]));
        await cache.write('shared', Uint8List.fromList([8]));
        await cache.writeData('extra', 'cards', ['old'], checkActive: () {});
        await cache.writeData('metadata-only', 'cards', [
          'old',
        ], checkActive: () {});
        await cache.writeData('w', 'cards', ['keep'], checkActive: () {});
        await restorer.restore(await prepare());
        expect(await cache.read('obsolete'), isNull);
        expect(await cache.read('shared'), [8]);
        expect(await cache.readData('extra', 'cards'), isNull);
        expect(await cache.readData('metadata-only', 'cards'), isNull);
        expect(await cache.readData('w', 'cards'), ['keep']);
        expect(await File('${artwork.path}/$imageName').exists(), isTrue);
      } finally {
        await cache.close();
      }
    },
  );

  test(
    'cache cleanup failure allows another restore and later retries safely',
    () async {
      await catalog.db.insert('works', {'id': 'extra', 'title': 'Old library'});
      await prefs.setString('theme_mode', 'light');
      final cache = ArtworkCache(artwork);
      try {
        await cache.retain('extra', ['obsolete']);
        await cache.write('obsolete', Uint8List.fromList([7]));
        final cacheDb = await cache.database;
        await cacheDb.execute(
          '''CREATE TRIGGER refuse_cleanup BEFORE DELETE ON owners
        BEGIN SELECT RAISE(ABORT, 'injected cache cleanup failure'); END''',
        );
        await restorer.restore(await prepare());
        expect((await catalog.db.query('works')).single['id'], 'w');
        expect(prefs.getString('theme_mode'), 'dark');
        expect(
          (await catalog.db.query('library_restore_state')).single['committed'],
          2,
        );
        expect(await cache.read('obsolete'), [7]);
        await mutateArchive((manifest) {
          manifest['tables']['works'][0]['title'] = 'Second restored library';
          manifest['preferences']['theme_mode'] = 'light';
        });
        await restorer.restore(await prepare());
        expect(
          (await catalog.db.query('works')).single['title'],
          'Second restored library',
        );
        expect(prefs.getString('theme_mode'), 'light');
        expect(
          (await catalog.db.query('library_restore_state')).single['committed'],
          2,
        );
        expect(await cache.read('obsolete'), [7]);
        await catalog.db.execute(
          '''CREATE TRIGGER reject_restore BEFORE INSERT ON progress
          BEGIN SELECT RAISE(ABORT, 'injected restore failure'); END''',
        );
        await mutateArchive((manifest) {
          manifest['tables']['works'][0]['title'] = 'Rejected third library';
        });
        await expectLater(restorer.restore(await prepare()), throwsA(anything));
        expect(
          (await catalog.db.query('works')).single['title'],
          'Second restored library',
        );
        expect(
          (await catalog.db.query('library_restore_state')).single['committed'],
          2,
        );
        await prefs.setString('theme_mode', 'system');
        await cacheDb.execute('DROP TRIGGER refuse_cleanup');
        await restorer.recover();
        expect(await catalog.db.query('library_restore_state'), isEmpty);
        expect(await cache.read('obsolete'), isNull);
        expect((await catalog.db.query('works')).single['id'], 'w');
        expect(
          (await catalog.db.query('works')).single['title'],
          'Second restored library',
        );
        expect(prefs.getString('theme_mode'), 'system');
      } finally {
        await cache.close();
      }
    },
  );

  test('failed replacement keeps the current library cache owners', () async {
    await catalog.db.insert('works', {'id': 'extra', 'title': 'Old library'});
    final cache = ArtworkCache(artwork);
    try {
      await cache.retain('extra', ['keep']);
      await cache.write('keep', Uint8List.fromList([7]));
      await catalog.db.execute(
        '''CREATE TRIGGER reject_restore BEFORE INSERT ON progress
        BEGIN SELECT RAISE(ABORT, 'injected restore failure'); END''',
      );
      await expectLater(restorer.restore(await prepare()), throwsA(anything));
      expect(await cache.read('keep'), [7]);
      expect(await (await cache.database).query('owners'), hasLength(1));
    } finally {
      await cache.close();
    }
  });

  test(
    'full replacement preserves all portable tables and supports undo backup',
    () async {
      final before = {
        for (final table in LibraryBackupExporter.tables)
          table: await catalog.db.query(table),
      };
      final deviceBefore = await catalog.db.query('watch_event_local');
      await catalog.db.insert('works', {
        'id': 'extra',
        'title': 'Before restore',
      });
      await prefs.setString('theme_mode', 'light');
      final prepared = await prepare();
      // Selection is immutable even if the external file changes after preview.
      await archive.writeAsString('replaced after preview');
      final rollback = await restorer.restore(prepared);
      for (final table in LibraryBackupExporter.tables) {
        expect(await catalog.db.query(table), before[table], reason: table);
      }
      expect(prefs.getString('theme_mode'), 'dark');
      expect(prefs.getString('unrelated'), 'keep');
      expect((await catalog.withCredentials({'id': 's'}))['password'], '');
      expect(await catalog.db.query('watch_event_local'), isEmpty);
      await catalog.db.transaction(
        (tx) => WatchEventStore.recordManual(
          tx,
          'tmdb:tv:42:s1:e1',
          false,
          assetId: 'a',
        ),
      );
      expect(await catalog.db.query('watch_event_local'), isNot(deviceBefore));
      final undo = await restorer.prepare(rollback);
      try {
        await restorer.restore(undo);
      } finally {
        await undo.dispose();
      }
      expect(
        await catalog.db.query('works', where: 'id=?', whereArgs: ['extra']),
        hasLength(1),
      );
      expect(prefs.getString('theme_mode'), 'light');
      expect(await restorer.recoveryBackups(), hasLength(2));
    },
  );

  test(
    'SQL failure rolls back records and removes only newly imported artwork',
    () async {
      final prepared = await prepare();
      await File('${artwork.path}/$imageName').delete();
      await File('${artwork.path}/user-resource.txt').writeAsString('keep');
      await catalog.db.update('works', {'title': 'Current title'});
      await prefs.setString('theme_mode', 'light');
      await catalog.db.execute(
        '''CREATE TRIGGER reject_restore BEFORE INSERT ON progress
      BEGIN SELECT RAISE(ABORT, 'injected write failure'); END''',
      );
      await expectLater(restorer.restore(prepared), throwsA(anything));
      expect(
        (await catalog.db.query('works')).single['title'],
        'Current title',
      );
      expect((await catalog.db.query('progress')).single['position_ms'], 12345);
      expect(prefs.getString('theme_mode'), 'light');
      expect(await File('${artwork.path}/$imageName').exists(), isFalse);
      expect(
        await File('${artwork.path}/user-resource.txt').readAsString(),
        'keep',
      );
      expect(await catalog.db.query('library_restore_state'), isEmpty);
    },
  );

  for (final committed in [0, 1]) {
    test(
      'startup recovers interrupted preference writes (committed=$committed)',
      () async {
        await catalog.db.insert('library_restore_state', {
          'id': 1,
          'committed': committed,
          'old_preferences':
              '{"theme_mode":"light","watched_completion_percent":80}',
          'new_preferences':
              '{"theme_mode":"dark","watched_completion_percent":95}',
          'added_artwork': jsonEncode([imageName]),
        });
        await prefs.setString('theme_mode', 'system');
        await catalog.db.close();
        await catalog.initialize(dataDirectory: temp);
        expect(
          prefs.getString('theme_mode'),
          committed == 1 ? 'dark' : 'light',
        );
        expect(
          prefs.getInt('watched_completion_percent'),
          committed == 1 ? 95 : 80,
        );
        expect(prefs.containsKey('theme_accent'), isFalse);
        expect(
          await File('${artwork.path}/$imageName').exists(),
          committed == 1,
        );
        expect(await catalog.db.query('library_restore_state'), isEmpty);
      },
    );
  }

  for (final version in [15, 16, 17]) {
    test('restores schema $version without inventing missing events', () async {
      await mutateArchive((manifest) {
        manifest['db_schema_version'] = version;
        final tables = manifest['tables'] as Map;
        for (final key in [
          'watch_identity_epochs',
          'watch_event_origins',
          'bangumi_episode_mappings',
        ]) {
          tables.remove(key);
        }
        if (version < 17) tables.remove('watch_events');
        if (version < 16) tables.remove('logical_episode_confirmations');
      });
      await restorer.restore(await prepare());
      expect((await catalog.db.query('progress')).single['position_ms'], 12345);
      expect(await catalog.db.query('watch_event_origins'), isEmpty);
      expect(
        await catalog.db.query('watch_events'),
        hasLength(version < 17 ? 0 : 1),
      );
    });
  }

  test('invalid preference types rejected before writes', () async {
    await mutateArchive((m) => m['preferences']['theme_mode'] = 123);
    await expectLater(restorer.prepare(archive), throwsFormatException);
    expect((await catalog.db.query('works')).single['title'], 'Restored anime');
    expect(await restorer.recoveryBackups(), isEmpty);
  });

  test(
    'preference write failure also rolls back committed-looking settings and DB',
    () async {
      final prepared = await prepare();
      await catalog.db.update('works', {'title': 'Keep before failure'});
      await prefs.setString('theme_mode', 'light');
      final old = {
        for (final key in prefs.getKeys()) 'flutter.$key': prefs.get(key)!,
      };
      final store = _FailOncePreferences(old);
      SharedPreferencesStorePlatform.instance = store;
      await expectLater(restorer.restore(prepared), throwsStateError);
      expect(store.failed, isTrue);
      expect(
        (await catalog.db.query('works')).single['title'],
        'Keep before failure',
      );
      await prefs.reload();
      expect(prefs.getString('theme_mode'), 'light');
      expect(prefs.getString('theme_accent'), 'red');
      expect(await catalog.db.query('library_restore_state'), isEmpty);
    },
  );

  test('unknown columns rejected before writes', () async {
    await mutateArchive((m) => m['tables']['works'][0]['unexpected'] = 'bad');
    await expectLater(restorer.restore(await prepare()), throwsFormatException);
    expect(await restorer.recoveryBackups(), isEmpty);
  });

  test('duplicate primary keys abort whole replacement', () async {
    await mutateArchive(
      (m) => (m['tables']['works'] as List).add(m['tables']['works'][0]),
    );
    await catalog.db.update('works', {'title': 'Keep current'});
    await expectLater(restorer.restore(await prepare()), throwsA(anything));
    expect((await catalog.db.query('works')).single['title'], 'Keep current');
  });
}
