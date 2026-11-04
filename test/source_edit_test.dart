import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:ccplayer/core/catalog.dart';

void main() {
  test(
    'editing connection preserves source ID, works, assets, progress and scopes',
    () async {
      sqfliteFfiInit();
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      final catalog = Catalog.instance;
      catalog.db = db;
      try {
        await db.execute(
          'CREATE TABLE sources (id TEXT PRIMARY KEY, kind TEXT, label TEXT, location TEXT, username TEXT, password TEXT)',
        );
        await db.execute(
          'CREATE TABLE works (id TEXT PRIMARY KEY, title TEXT)',
        );
        await db.execute(
          'CREATE TABLE assets (id TEXT PRIMARY KEY,source_id TEXT,work_id TEXT,relative_path TEXT,episode INTEGER,name TEXT)',
        );
        await db.execute(
          'CREATE TABLE progress (asset_id TEXT PRIMARY KEY,position_ms INTEGER)',
        );
        await db.execute(
          'CREATE TABLE scan_roots (source_id TEXT,relative_path TEXT,mode TEXT,PRIMARY KEY(source_id,relative_path))',
        );
        await db.insert('sources', {
          'id': 'same-id',
          'kind': 'webdav',
          'label': 'old',
          'location': 'https://example.com/dav/',
          'username': 'old',
          'password': null,
        });
        await db.insert('works', {'id': 'work-1', 'title': '86'});
        await db.insert('assets', {
          'id': 'video-1',
          'source_id': 'same-id',
          'work_id': 'work-1',
          'relative_path': '动画-单作品/86/[01].mkv',
        });
        await db.insert('progress', {
          'asset_id': 'video-1',
          'position_ms': 12000,
        });
        await catalog.reload();
        await catalog.addScanRoot('same-id', '动画-单作品/86');
        await catalog.updateSource(
          'same-id',
          label: 'new',
          location: 'https://example.com/new/',
          username: 'new',
          password: null,
        );
        expect(catalog.sources.single['id'], 'same-id');
        expect(catalog.sources.single['location'], 'https://example.com/new/');
        expect(catalog.works.single['title'], '86');
        expect(catalog.assets.single['id'], 'video-1');
        expect(
          catalog.rootsFor('same-id').single['relative_path'],
          '动画-单作品/86',
        );
        expect((await db.query('progress')).single['position_ms'], 12000);
      } finally {
        await db.close();
      }
    },
  );

  test('selecting parent replaces covered child without duplication', () async {
    sqfliteFfiInit();
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    final cat = Catalog.instance;
    cat.db = db;
    try {
      await db.execute(
        'CREATE TABLE sources (id TEXT PRIMARY KEY, kind TEXT, label TEXT, location TEXT, username TEXT, password TEXT)',
      );
      await db.execute('CREATE TABLE works (id TEXT PRIMARY KEY,title TEXT)');
      await db.execute(
        'CREATE TABLE assets (id TEXT PRIMARY KEY,episode INTEGER,name TEXT)',
      );
      await db.execute(
        'CREATE TABLE scan_roots (source_id TEXT,relative_path TEXT,mode TEXT,PRIMARY KEY(source_id,relative_path))',
      );
      await db.insert('sources', {
        'id': 'x',
        'kind': 'webdav',
        'label': 'x',
        'location': 'http://example.com/dav',
        'username': '',
        'password': null,
      });
      await cat.reload();
      await cat.addScanRoot('x', '动画-单作品/86');
      await cat.addScanRoot('x', '动画-单作品/葬送的芙莉莲');
      expect(cat.rootsFor('x').length, 2);
      await cat.addScanRoot('x', '动画-单作品');
      expect(cat.rootsFor('x').length, 1);
      expect(cat.rootsFor('x').single['mode'], 'auto');
      await cat.toggleScanRoot('x', '动画-单作品');
      expect(cat.rootsFor('x'), isEmpty);
    } finally {
      await db.close();
    }
  });
}
