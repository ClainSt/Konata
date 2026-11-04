import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:ccplayer/core/catalog.dart';

void main() {
  test('indexed work title and TMDB ID use chosen child directory', () async {
    sqfliteFfiInit();
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    final catalog = Catalog.instance;
    catalog.db = db;
    try {
      await db.execute(
        'CREATE TABLE works (id TEXT PRIMARY KEY, title TEXT, year INTEGER, tmdb_id INTEGER, tmdb_type TEXT, needs_review INTEGER NOT NULL DEFAULT 1, manual_lock INTEGER NOT NULL DEFAULT 0)',
      );
      await db.execute(
        'CREATE TABLE assets (id TEXT PRIMARY KEY, source_id TEXT, work_id TEXT, relative_path TEXT, name TEXT, episode INTEGER, season INTEGER NOT NULL DEFAULT 1, category TEXT, extra_type TEXT, size INTEGER)',
      );
      await db.execute(
        'CREATE TABLE asset_overrides (asset_id TEXT PRIMARY KEY, work_id TEXT, category TEXT, episode INTEGER, season INTEGER NOT NULL DEFAULT 1, extra_type TEXT)',
      );
      await catalog.indexVideo(
        'source-1',
        '动画-单作品/86 (2021) {tmdb-100565}/[01].mkv',
        null,
        workFolder: '动画-单作品/86 (2021) {tmdb-100565}',
      );
      final works = await db.query('works');
      expect(works.length, 1);
      expect(works.single['title'], '86');
      expect(works.single['tmdb_id'], 100565);
      final files = await db.query('assets');
      expect(files.single['episode'], 1);
      await db.insert('works', {
        'id': 'manual-work',
        'title': 'Corrected',
        'manual_lock': 1,
      });
      await db.update(
        'assets',
        {'work_id': 'manual-work'},
        where: 'id=?',
        whereArgs: [files.single['id']],
      );
      await catalog.indexVideo(
        'source-1',
        '动画-单作品/86 (2021) {tmdb-100565}/[01].mkv',
        null,
        workFolder: '动画-单作品/Other (2021) {tmdb-123456}',
      );
      expect((await db.query('assets')).single['work_id'], 'manual-work');
    } finally {
      await db.close();
    }
  });
}
