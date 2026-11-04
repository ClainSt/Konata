import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:ccplayer/core/catalog.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  test('checkbox OFF removes from library but next real scan restores it', () async {
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    final catalog = Catalog.instance;
    catalog.db = db;
    try {
      await db.execute('CREATE TABLE sources (id TEXT PRIMARY KEY,label TEXT)');
      await db.execute(
        'CREATE TABLE works (id TEXT PRIMARY KEY,title TEXT,year INTEGER,'
        'tmdb_id INTEGER,tmdb_type TEXT,manual_lock INTEGER NOT NULL DEFAULT 0,'
        'needs_review INTEGER NOT NULL DEFAULT 1,'
        'hidden INTEGER NOT NULL DEFAULT 0,'
        'keep_hidden INTEGER NOT NULL DEFAULT 0)',
      );
      await db.execute(
        'CREATE TABLE assets (id TEXT PRIMARY KEY,source_id TEXT,work_id TEXT,'
        'relative_path TEXT,name TEXT,episode INTEGER,'
        'season INTEGER NOT NULL DEFAULT 1,category TEXT,extra_type TEXT,size INTEGER)',
      );
      await db.execute(
        'CREATE TABLE scan_roots (source_id TEXT,relative_path TEXT)',
      );
      await db.execute(
        'CREATE TABLE asset_overrides (asset_id TEXT PRIMARY KEY,'
        'work_id TEXT,category TEXT,episode INTEGER,season INTEGER,extra_type TEXT)',
      );
      await db.execute(
        'CREATE TABLE progress (asset_id TEXT PRIMARY KEY,position_ms INTEGER)',
      );
      Future<void> reindex() => catalog.indexVideo(
        'src',
        'Anime/[01].mkv',
        1024,
        workFolder: 'Anime',
      );

      await reindex();
      await catalog.reload();
      final workId = catalog.works.single['id'].toString();
      final assetId = catalog.assets.single['id'].toString();
      await db.insert('progress', {'asset_id': assetId, 'position_ms': 54321});

      await catalog.hideWork(workId, keepHidden: false);
      expect(catalog.works, isEmpty);
      expect(catalog.hiddenWorkEntries.single['id'], workId);
      final hidden = (await db.query('works')).single;
      expect(hidden['hidden'], 1);
      expect(hidden['keep_hidden'], 0);
      expect((await db.query('assets')).single['id'], assetId);
      expect((await db.query('progress')).single['position_ms'], 54321);

      // An actual reindex automatically restores a nonpersistent removal.
      await reindex();
      await catalog.reload();
      expect(catalog.works.single['id'], workId);

      await catalog.hideWork(workId, keepHidden: true);
      expect(catalog.works, isEmpty);
      await reindex();
      await catalog.reload();
      expect(
        catalog.works,
        isEmpty,
        reason: 'Checked permanent hiding must survive the next scan',
      );
      expect((await db.query('works')).single['keep_hidden'], 1);

      // Restore is reversible even for a persistently hidden work.
      await catalog.restoreWork(workId);
      expect(catalog.hiddenWorkEntries, isEmpty);
      expect(catalog.works.single['id'], workId);
      expect((await db.query('progress')).single['position_ms'], 54321);
    } finally {
      await db.close();
    }
  });
}
