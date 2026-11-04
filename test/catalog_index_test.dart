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
        'CREATE TABLE works (id TEXT PRIMARY KEY, title TEXT, year INTEGER, tmdb_id INTEGER, tmdb_type TEXT)',
      );
      await db.execute(
        'CREATE TABLE assets (id TEXT PRIMARY KEY, source_id TEXT, work_id TEXT, relative_path TEXT, name TEXT, episode INTEGER, category TEXT, size INTEGER)',
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
    } finally {
      await db.close();
    }
  });
}
