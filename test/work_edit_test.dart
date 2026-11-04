import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:ccplayer/core/catalog.dart';
import 'package:ccplayer/core/personal_scraper.dart';

void main() {
  setUpAll(() => sqfliteFfiInit());
  test(
    'TMDB/Bangumi cover selection remains locked across automated scrape',
    () async {
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      final catalog = Catalog.instance;
      catalog.db = db;
      try {
        await db.execute(
          'CREATE TABLE sources (id TEXT PRIMARY KEY,label TEXT)',
        );
        await db.execute(
          'CREATE TABLE assets (id TEXT PRIMARY KEY,episode INTEGER,name TEXT)',
        );
        await db.execute(
          'CREATE TABLE scan_roots (source_id TEXT,relative_path TEXT)',
        );
        await db.execute(
          'CREATE TABLE works (id TEXT PRIMARY KEY,title TEXT,year INTEGER,poster TEXT,poster_fallback TEXT,manual_cover_url TEXT,manual_cover_source TEXT,overview TEXT,tmdb_id INTEGER,tmdb_type TEXT,bangumi_id INTEGER,manual_lock INTEGER NOT NULL DEFAULT 0,needs_review INTEGER NOT NULL DEFAULT 1,hidden INTEGER NOT NULL DEFAULT 0,keep_hidden INTEGER NOT NULL DEFAULT 0)',
        );
        await db.insert('works', {
          'id': 'id1',
          'title': 'Anime',
          'manual_lock': 0,
          'poster': 'https://image.tmdb.org/t/p/w500/old.jpg',
        });
        await catalog.setManualCover(
          'id1',
          source: 'bangumi',
          url: 'https://lain.bgm.tv/cover.jpg',
        );
        final scraped = const ScrapedWork(
          title: 'Anime Updated',
          provider: 'TMDB + Bangumi',
          poster: 'https://image.tmdb.org/t/p/w500/new.jpg',
          bangumiPoster: 'https://lain.bgm.tv/new-cover.jpg',
        );
        expect(
          await catalog.applyScrapedWork('id1', scraped, reloadAfter: false),
          isTrue,
        );
        final updated = (await db.query(
          'works',
          where: 'id=?',
          whereArgs: ['id1'],
        )).single;
        expect(
          Catalog.preferredPoster(updated),
          'https://lain.bgm.tv/cover.jpg',
        );
        expect(updated['poster'], 'https://image.tmdb.org/t/p/w500/new.jpg');
        expect(updated['manual_cover_source'], 'bangumi');
        await catalog.setManualCover('id1');
        final reset = (await db.query(
          'works',
          where: 'id=?',
          whereArgs: ['id1'],
        )).single;
        expect(reset['manual_cover_url'], isNull);
        expect(reset['manual_cover_source'], isNull);
        expect(
          Catalog.preferredPoster(reset),
          'https://image.tmdb.org/t/p/w500/new.jpg',
        );
      } finally {
        await db.close();
      }
    },
  );
  test(
    'manual metadata editing sets manual lock and does not alter progress',
    () async {
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      final catalog = Catalog.instance;
      catalog.db = db;
      try {
        await db.execute(
          'CREATE TABLE sources (id TEXT PRIMARY KEY,label TEXT)',
        );
        await db.execute(
          'CREATE TABLE works (id TEXT PRIMARY KEY,title TEXT,year INTEGER,poster TEXT,poster_fallback TEXT,manual_cover_url TEXT,manual_cover_source TEXT,overview TEXT,tmdb_id INTEGER,tmdb_type TEXT,bangumi_id INTEGER,manual_lock INTEGER NOT NULL DEFAULT 0,needs_review INTEGER NOT NULL DEFAULT 1,hidden INTEGER NOT NULL DEFAULT 0,keep_hidden INTEGER NOT NULL DEFAULT 0)',
        );
        await db.execute(
          'CREATE TABLE assets (id TEXT PRIMARY KEY,episode INTEGER,name TEXT)',
        );
        await db.execute(
          'CREATE TABLE scan_roots (source_id TEXT,relative_path TEXT)',
        );
        await db.execute(
          'CREATE TABLE progress (asset_id TEXT PRIMARY KEY,position_ms INTEGER)',
        );
        await db.insert('works', {'id': 'w1', 'title': 'Old', 'year': 2022});
        await db.insert('progress', {'asset_id': 'a1', 'position_ms': 10001});
        await catalog.updateWorkMetadata(
          'w1',
          title: '  新标题  ',
          year: 2024,
          overview: '作品简介',
        );
        final updated = (await db.query('works')).single;
        expect(updated['title'], '新标题');
        expect(updated['year'], 2024);
        expect(updated['overview'], '作品简介');
        expect(updated['manual_lock'], 1);
        expect((await db.query('progress')).single['position_ms'], 10001);
        final scrap = const ScrapedWork(
          title: 'Ignored',
          provider: 'TMDB',
          poster: 'https://example.org/ignored.jpg',
        );
        expect(
          await catalog.applyScrapedWork('w1', scrap, reloadAfter: false),
          isFalse,
        );
        expect((await db.query('works')).single['title'], '新标题');
      } finally {
        await db.close();
      }
    },
  );
}
