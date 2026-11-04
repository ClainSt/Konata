import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:ccplayer/core/phantom_directory_repair.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  Future<Database> database() async {
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await db.execute(
      'CREATE TABLE assets (id TEXT PRIMARY KEY,source_id TEXT,work_id TEXT,'
      'relative_path TEXT,name TEXT,episode INTEGER,season INTEGER,'
      'category TEXT,extra_type TEXT,size INTEGER)',
    );
    await db.execute(
      'CREATE TABLE progress (asset_id TEXT PRIMARY KEY,position_ms INTEGER,'
      'duration_ms INTEGER,completed INTEGER,updated_at TEXT)',
    );
    await db.execute(
      'CREATE TABLE asset_overrides (asset_id TEXT PRIMARY KEY,work_id TEXT,'
      'episode INTEGER,season INTEGER,category TEXT,extra_type TEXT)',
    );
    await db.execute(
      'CREATE TABLE asset_override_history (asset_id TEXT PRIMARY KEY,work_id TEXT,'
      'episode INTEGER,season INTEGER,category TEXT,extra_type TEXT,was_locked INTEGER)',
    );
    return db;
  }

  test(
    'phantom repeated parent removed, original and all corrections preserved',
    () async {
      final db = await database();
      const root = '动画-单作品/16bit的感动 (2023) {tmdb-217512}';
      const filename = '[SweetSub] 16bit [01].mkv';
      try {
        Map<String, Object?> asset(String id, String path, String filename) => {
          'id': id,
          'source_id': 'src',
          'work_id': 'work',
          'relative_path': path,
          'name': filename,
          'episode': 1,
          'season': 1,
          'category': 'main',
          'extra_type': null,
          'size': 123456,
        };
        await db.insert('assets', asset('good', '$root/$filename', filename));
        await db.insert(
          'assets',
          asset('phantom', '$root/${root.split('/').last}/$filename', filename),
        );
        await db.insert(
          'assets',
          asset(
            'real-other-version',
            '$root/[Another] 16bit [01].mkv',
            '[Another] 16bit [01].mkv',
          ),
        );
        await db.insert('progress', {
          'asset_id': 'phantom',
          'position_ms': 112233,
          'duration_ms': 999999,
          'completed': 0,
          'updated_at': '2026-11-04T10:00:00Z',
        });
        await db.insert('asset_overrides', {
          'asset_id': 'phantom',
          'work_id': 'work',
          'episode': 1,
          'season': 1,
          'category': 'main',
        });
        await db.insert('asset_override_history', {
          'asset_id': 'phantom',
          'work_id': 'work',
          'episode': 1,
          'season': 1,
          'category': 'main',
          'was_locked': 1,
        });

        expect(await PhantomDirectoryRepair.repair(db), 1);
        final assets = await db.query('assets');
        expect(assets.map((r) => r['id']).toSet(), {
          'good',
          'real-other-version',
        });
        expect((await db.query('progress')).single['asset_id'], 'good');
        expect((await db.query('progress')).single['position_ms'], 112233);
        expect((await db.query('asset_overrides')).single['asset_id'], 'good');
        expect(
          (await db.query('asset_override_history')).single['asset_id'],
          'good',
        );
        final archive = (await db.query('phantom_asset_archive')).single;
        expect(archive['obsolete_asset_id'], 'phantom');
        expect(archive['canonical_asset_id'], 'good');
        expect(archive['progress_json'], contains('112233'));
        expect(
          await PhantomDirectoryRepair.repair(db),
          0,
          reason: 'Upgrade must be idempotent',
        );
      } finally {
        await db.close();
      }
    },
  );

  test(
    'manual association conflicts block automatic phantom removal',
    () async {
      final db = await database();
      try {
        for (final path in ['Anime/86/[01].mkv', 'Anime/86/86/[01].mkv']) {
          final ghost = path.contains('86/86/');
          final id = ghost ? 'ghost' : 'real';
          await db.insert('assets', {
            'id': id,
            'source_id': 'src',
            'work_id': 'work',
            'relative_path': path,
            'name': '[01].mkv',
            'episode': 1,
            'season': 1,
            'category': 'main',
            'size': 100,
          });
          await db.insert('asset_overrides', {
            'asset_id': id,
            'work_id': ghost ? 'manual-work' : 'work',
            'episode': 1,
            'season': 1,
            'category': 'main',
          });
        }
        expect(await PhantomDirectoryRepair.repair(db), 0);
        expect((await db.query('assets')).length, 2);
        expect((await db.query('phantom_asset_archive')).length, 0);
      } finally {
        await db.close();
      }
    },
  );
}
