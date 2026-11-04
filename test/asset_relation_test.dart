import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:ccplayer/core/catalog.dart';

void main() {
  test('manual file association survives reindex and can be undone', () async {
    sqfliteFfiInit();
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    final catalog = Catalog.instance;
    catalog.db = db;
    try {
      await db.execute(
        'CREATE TABLE sources (id TEXT PRIMARY KEY,kind TEXT,label TEXT,location TEXT,username TEXT,password TEXT)',
      );
      await db.execute(
        'CREATE TABLE scan_roots (source_id TEXT,relative_path TEXT,mode TEXT)',
      );
      await db.execute(
        'CREATE TABLE works (id TEXT PRIMARY KEY,title TEXT,year INTEGER,tmdb_id INTEGER,tmdb_type TEXT,manual_lock INTEGER NOT NULL DEFAULT 0,needs_review INTEGER NOT NULL DEFAULT 1)',
      );
      await db.execute(
        'CREATE TABLE assets (id TEXT PRIMARY KEY,source_id TEXT,work_id TEXT,relative_path TEXT,name TEXT,episode INTEGER,category TEXT,size INTEGER)',
      );
      await db.execute(
        'CREATE TABLE asset_overrides (asset_id TEXT PRIMARY KEY,work_id TEXT,category TEXT,episode INTEGER)',
      );
      await db.execute(
        'CREATE TABLE asset_override_history (asset_id TEXT PRIMARY KEY,work_id TEXT,category TEXT,episode INTEGER,was_locked INTEGER)',
      );
      await db.execute(
        'CREATE TABLE progress (asset_id TEXT PRIMARY KEY,position_ms INTEGER,duration_ms INTEGER,completed INTEGER,updated_at TEXT)',
      );
      await catalog.indexVideo(
        'source-1',
        'AnimeA/[01].mkv',
        null,
        workFolder: 'AnimeA',
      );
      await catalog.indexVideo(
        'source-1',
        'AnimeB/[02].mkv',
        null,
        workFolder: 'AnimeB',
      );
      final first = (await db.query(
        'assets',
        where: 'name=?',
        whereArgs: ['[01].mkv'],
      )).single;
      final assetId = first['id'].toString();
      final originalWork = first['work_id'].toString();
      final destination = (await db.query(
        'works',
        where: 'title=?',
        whereArgs: ['AnimeB'],
      )).single['id'].toString();
      await catalog.progress(assetId, 12000, 120000);
      await catalog.lockAssetRelation(
        assetId,
        workId: destination,
        category: 'extra',
        episode: 99,
      );
      await catalog.indexVideo(
        'source-1',
        'AnimeA/[01].mkv',
        null,
        workFolder: 'AnimeA',
      );
      final overridden = (await db.query(
        'assets',
        where: 'id=?',
        whereArgs: [assetId],
      )).single;
      expect(overridden['work_id'], destination);
      expect(overridden['category'], 'extra');
      expect(overridden['episode'], 99);
      expect(
        (await db.query(
          'progress',
          where: 'asset_id=?',
          whereArgs: [assetId],
        )).single['position_ms'],
        12000,
      );
      expect(await catalog.undoAssetRelation(assetId), true);
      final restored = (await db.query(
        'assets',
        where: 'id=?',
        whereArgs: [assetId],
      )).single;
      expect(restored['work_id'], originalWork);
      expect(restored['category'], 'main');
      expect(restored['episode'], 1);
      expect((await db.query('asset_overrides')), isEmpty);
      expect(await catalog.undoAssetRelation(assetId), false);
    } finally {
      await db.close();
    }
  });
}
