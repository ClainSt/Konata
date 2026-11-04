import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:ccplayer/core/catalog.dart';

void main() {
  setUpAll(() => sqfliteFfiInit());
  test(
    'clearing temporary scan checkboxes never deletes indexed works or progress',
    () async {
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      final cat = Catalog.instance;
      cat.db = db;
      try {
        await db.execute(
          'CREATE TABLE scan_roots (source_id TEXT, relative_path TEXT, mode TEXT, PRIMARY KEY(source_id,relative_path))',
        );
        await db.execute(
          'CREATE TABLE sources (id TEXT PRIMARY KEY,kind TEXT,label TEXT,location TEXT,username TEXT,password TEXT)',
        );
        await db.execute(
          'CREATE TABLE works (id TEXT PRIMARY KEY,title TEXT,hidden INTEGER NOT NULL DEFAULT 0,keep_hidden INTEGER NOT NULL DEFAULT 0)',
        );
        await db.execute(
          'CREATE TABLE assets (id TEXT PRIMARY KEY,episode INTEGER,name TEXT,work_id TEXT)',
        );
        await db.execute(
          'CREATE TABLE progress (asset_id TEXT PRIMARY KEY,position_ms INTEGER)',
        );
        await db.insert('sources', {
          'id': 'src1',
          'kind': 'webdav',
          'label': 'Cloud',
          'location': 'https://example.org/dav',
          'username': '',
          'password': null,
        });
        await db.insert('works', {'id': 'work1', 'title': '86'});
        await db.insert('assets', {
          'id': 'asset1',
          'work_id': 'work1',
          'episode': 1,
          'name': '01.mkv',
        });
        await db.insert('progress', {
          'asset_id': 'asset1',
          'position_ms': 45000,
        });
        await cat.reload();
        await cat.addScanRoot('src1', '动画-单作品/86');
        expect(cat.rootsFor('src1'), hasLength(1));
        await cat.clearScanRoots('src1');
        expect(cat.rootsFor('src1'), isEmpty);
        expect(cat.works.single['title'], '86');
        expect((await db.query('progress')).single['position_ms'], 45000);
      } finally {
        await db.close();
      }
    },
  );
}
