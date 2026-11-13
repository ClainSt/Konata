import 'dart:io';

import 'package:ccplayer/core/anime_mapping.dart';
import 'package:ccplayer/core/anime_mapping_store.dart';
import 'package:ccplayer/core/catalog.dart';
import 'package:ccplayer/core/library_backup_exporter.dart';
import 'package:ccplayer/core/library_backup_restorer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'refactor_baseline_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final catalog = Catalog.instance;
  late Directory root, artwork;
  late LibraryBackupRestorer restorer;
  late LibraryBackupExporter exporter;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('konata-baseline-contract-');
    await openBaselineCatalog(Directory('${root.path}/db'));
    artwork = await Directory('${root.path}/artwork').create();
    final prefs = await SharedPreferences.getInstance();
    restorer = LibraryBackupRestorer(
      database: catalog.db,
      artworkDirectory: artwork,
      preferences: prefs,
    );
    exporter = LibraryBackupExporter(
      database: catalog.db,
      artworkDirectory: artwork,
      preferences: prefs,
    );
  });
  tearDown(() async {
    await closeBaselineCatalog();
    await root.delete(recursive: true);
  });

  test(
    'mapping target boundaries reject overflow, duplicates and incomplete episodes',
    () {
      expect(AnimeMapping.targetList([]), isEmpty);
      expect(AnimeMapping.integer(2147483647), 2147483647);
      expect(() => AnimeMapping.integer(2147483648), throwsFormatException);
      expect(
        () => AnimeMapping.targetList([
          {'type': 'movie', 'id': 1},
          {'type': 'movie', 'id': 1},
        ]),
        throwsFormatException,
      );
      expect(
        () => AnimeMapping.targetList([
          {'type': 'tv', 'id': 1, 'episode': 1},
        ], episode: true),
        throwsFormatException,
      );
      expect(
        AnimeMapping.targetList([
          {'type': 'tv', 'id': 1, 'season': 0, 'episode': 1},
        ], episode: true).single['season'],
        0,
      );
    },
  );

  test(
    'backup repeated restore preserves positions and unrelated preferences',
    () async {
      await seedBaselineCatalog(2);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('baseline_unrelated', 'keep');
      final file = await exporter.export(File('${root.path}/snapshot.zip'));
      final prepared = await restorer.prepare(file);
      try {
        expect(prepared.data.manifest['format'], 'ccplayer-library');
        expect(prepared.data.manifest['format_version'], 1);
        expect(prepared.data.manifest['db_schema_version'], 27);
        for (var i = 0; i < 2; i++) {
          await catalog.db.update('progress', {'position_ms': 9000});
          await restorer.restore(prepared);
          expect(await catalog.db.query('assets'), hasLength(2));
          expect(
            (await catalog.db.query(
              'progress',
            )).every((r) => r['position_ms'] == 1000),
            isTrue,
          );
          expect(prefs.getString('baseline_unrelated'), 'keep');
        }
        expect(await restorer.recoveryBackups(), hasLength(2));
      } finally {
        await prepared.dispose();
      }
      expect(await prepared.directory.exists(), isFalse);
    },
  );

  test('merge rejects stale preview without changing local title', () async {
    await seedBaselineCatalog(1);
    final file = await exporter.export(File('${root.path}/snapshot.zip'));
    final prepared = await restorer.prepare(file);
    try {
      final preview = await restorer.previewMerge(prepared, {});
      await catalog.db.update('works', {'title': 'User edit'});
      await expectLater(
        restorer.restore(prepared, merge: preview),
        throwsStateError,
      );
      expect((await catalog.db.query('works')).single['title'], 'User edit');
      expect((await catalog.db.query('progress')).single['position_ms'], 1000);
    } finally {
      await prepared.dispose();
    }
  });

  test(
    'committed restore survives repeated filesystem cleanup failures and recovers',
    () async {
      await seedBaselineCatalog(1);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('theme_mode', 'dark');
      final file = await exporter.export(File('${root.path}/snapshot.zip'));
      final prepared = await restorer.prepare(file);
      final cache = catalog.taskStore!.cacheDirectory;
      await cache.delete(recursive: true);
      await File(cache.path).writeAsString('fault injection');
      try {
        for (var attempt = 0; attempt < 2; attempt++) {
          await catalog.db.update('works', {'title': 'Before restore'});
          await prefs.setString('theme_mode', 'light');
          final rollback = await restorer.restore(prepared);
          expect(await rollback.exists(), isTrue);
          expect(
            (await catalog.db.query('works')).single['title'],
            'Fixture 0',
          );
          expect(prefs.getString('theme_mode'), 'dark');
          expect(
            (await catalog.db.query(
              'library_restore_state',
            )).single['committed'],
            2,
          );
          expect(await File(cache.path).readAsString(), 'fault injection');
        }
        expect(await restorer.recoveryBackups(), hasLength(2));
        // Remove only this fixture's injected obstacle, then retry normally.
        await File(cache.path).delete();
        await restorer.restore(prepared);
        expect(await cache.exists(), isTrue);
        expect(await catalog.db.query('library_restore_state'), isEmpty);
        await prefs.setString('theme_mode', 'system');
        await restorer.recover();
        expect(prefs.getString('theme_mode'), 'system');
      } finally {
        await prepared.dispose();
      }
      expect(await prepared.directory.exists(), isFalse);
    },
  );

  test(
    'post-commit database reset errors are not swallowed as cache failures',
    () async {
      await seedBaselineCatalog(1);
      final file = await exporter.export(File('${root.path}/snapshot.zip'));
      final prepared = await restorer.prepare(file);
      await catalog.db.execute(
        "CREATE TRIGGER reject_runtime_reset BEFORE INSERT ON scrape_runtime BEGIN SELECT RAISE(ABORT, 'injected runtime reset failure'); END",
      );
      try {
        await expectLater(
          restorer.restore(prepared),
          throwsA(isA<DatabaseException>()),
        );
        expect((await catalog.db.query('works')).single['title'], 'Fixture 0');
        expect(
          (await catalog.db.query('library_restore_state')).single['committed'],
          2,
        );
      } finally {
        await prepared.dispose();
      }
    },
  );

  test(
    'same-version exclusion disagreement stays conflicted after cache clear',
    () async {
      final store = catalog.mappingStore!;
      final version = 'a' * 40;
      await store.registerVersion(version);
      for (var i = 0; i < 2; i++) {
        final id = 'baseline-map-$i';
        await store.tasks.enqueue(id, intent: {}, steps: ['mapping']);
        final lease = (await store.tasks.claim(id, 'mapping'))!;
        await store.importDetail(version, {
          'schemaVersion': 1,
          'bangumiId': 1,
          'targets': [],
          'episodes': [
            {'id': 101, 'type': 0, 'sort': 1},
          ],
          'rules': [],
          'overrides': [
            if (i == 1) {'bangumiEpisodeId': 101, 'targets': []},
          ],
        }, lease);
      }
      expect((await store.lookup(1, 101)).state, 'conflict');
      await store.clearCache();
      expect((await store.lookup(1, 101)).state, 'conflict');
      expect(AnimeMappingStore.commitPattern.hasMatch(version), isTrue);
    },
  );

  test(
    'merge undo retains user edits, rejects stale and repeated undo',
    () async {
      await seedBaselineCatalog(2);
      final archive = await exporter.export(File('${root.path}/merge.zip'));
      final prepared = await restorer.prepare(archive);
      try {
        await closeBaselineCatalog();
        await openBaselineCatalog(Directory('${root.path}/destination'));
        final destination = LibraryBackupRestorer(
          database: catalog.db,
          artworkDirectory: artwork,
          preferences: await SharedPreferences.getInstance(),
        );
        final review = await destination.previewMerge(prepared, {});
        await destination.restore(prepared, merge: review);
        final stale = (await destination.previewMergeUndo())!;
        await catalog.db.update(
          'progress',
          {'position_ms': 7777},
          where: 'asset_id=?',
          whereArgs: ['a0'],
        );
        await expectLater(destination.undoMerge(stale), throwsStateError);
        final current = (await destination.previewMergeUndo())!;
        expect(current.retained, greaterThan(stale.retained));
        await destination.undoMerge(current);
        expect(
          (await catalog.db.query('progress')).single['position_ms'],
          7777,
        );
        expect((await catalog.db.query('assets')).single['id'], 'a0');
        expect(await destination.previewMergeUndo(), isNull);
        await expectLater(destination.undoMerge(current), throwsStateError);
        expect((await catalog.db.query('assets')).single['id'], 'a0');
      } finally {
        await prepared.dispose();
      }
    },
  );
}
