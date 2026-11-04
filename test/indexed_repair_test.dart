import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:ccplayer/core/catalog.dart';

void main() {
  setUpAll(() => sqfliteFfiInit());
  test(
    'Offline upgrade repairs grouped BDRip episodes but not manual relations',
    () async {
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      try {
        await db.execute(
          'CREATE TABLE assets (id TEXT PRIMARY KEY,name TEXT,relative_path TEXT,episode INTEGER,season INTEGER,category TEXT,extra_type TEXT)',
        );
        await db.execute(
          'CREATE TABLE asset_overrides (asset_id TEXT PRIMARY KEY)',
        );
        for (final id in ['a', 'b']) {
          await db.insert('assets', {
            'id': id,
            'name': '[SweetSub&VCB-Studio] 16bit Sensation [01][Ma10p].mkv',
            'relative_path':
                'Anime/$id/[SweetSub&VCB-Studio] 16bit Sensation [01][Ma10p].mkv',
            'episode': null,
            'season': 1,
            'category': 'main',
          });
        }
        await db.insert('asset_overrides', {'asset_id': 'b'});
        await db.insert('assets', {
          'id': 'cm',
          'name': 'CM01.mkv',
          'relative_path': 'Anime/SPs/CM01.mkv',
          'episode': null,
          'season': 0,
          'category': 'extra',
        });
        expect(await Catalog.repairIndexedAssets(db), 2);
        final a = (await db.query(
          'assets',
          where: 'id=?',
          whereArgs: ['a'],
        )).single;
        expect(a['episode'], 1);
        final b = (await db.query(
          'assets',
          where: 'id=?',
          whereArgs: ['b'],
        )).single;
        expect(b['episode'], isNull);
        final cm = (await db.query(
          'assets',
          where: 'id=?',
          whereArgs: ['cm'],
        )).single;
        expect(cm['extra_type'], 'CM');
        expect(await Catalog.repairIndexedAssets(db), 0);
      } finally {
        await db.close();
      }
    },
  );
}
