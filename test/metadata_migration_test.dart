import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:ccplayer/core/catalog.dart';
import 'package:ccplayer/core/personal_scraper.dart';
import 'package:ccplayer/core/image_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final existingColumns in [1, 4]) {
    test(
      'v12 containing $existingColumns metadata columns upgrades without overwriting user data',
      () async {
        sqfliteFfiInit();
        final directory = await Directory.systemTemp.createTemp(
          'ccplayer-existing-columns-',
        );
        var db = await databaseFactoryFfi.openDatabase(
          '${directory.path}/ccplayer.db',
          options: OpenDatabaseOptions(
            version: 12,
            onCreate: (db, _) async {
              await db.execute(
                'CREATE TABLE sources (id TEXT PRIMARY KEY,label TEXT,password TEXT)',
              );
              await db.execute(
                'CREATE TABLE works (id TEXT PRIMARY KEY,title TEXT,hidden INTEGER DEFAULT 0)',
              );
              await db.execute(
                'CREATE TABLE assets (id TEXT PRIMARY KEY,name TEXT,episode INTEGER)',
              );
              await db.execute(
                'CREATE TABLE scan_roots (source_id TEXT,relative_path TEXT)',
              );
              await db.execute(
                'CREATE TABLE progress (asset_id TEXT PRIMARY KEY,position_ms INTEGER)',
              );
              for (final column in [
                'bangumi_ids',
                'bangumi_link_info',
                'cover_edit_json',
                'character_order',
              ].take(existingColumns)) {
                await db.execute('ALTER TABLE works ADD COLUMN $column TEXT');
              }
              await db.insert('works', {
                'id': 'locked-work',
                'title': '保留作品',
                'bangumi_ids': '[302189,331887]',
              });
              await db.insert('progress', {
                'asset_id': 'watched-video',
                'position_ms': 12345,
              });
            },
          ),
        );
        await db.close();
        try {
          await Catalog.instance.initialize(dataDirectory: directory);
          db = Catalog.instance.db;
          expect(await db.getVersion(), 18);
          expect(
            (await db.rawQuery(
              'PRAGMA table_info(works)',
            )).where((r) => r['name'] == 'bangumi_ids'),
            hasLength(1),
          );
          expect(
            Catalog.instance.works.single['bangumi_ids'],
            '[302189,331887]',
          );
          expect((await db.query('progress')).single['position_ms'], 12345);
          await db.close();
          await Catalog.instance.initialize(dataDirectory: directory);
          db = Catalog.instance.db;
          expect(Catalog.instance.works.single['title'], '保留作品');
        } finally {
          try {
            await db.close();
          } catch (_) {}
          await directory.delete(recursive: true);
        }
      },
    );
  }
  test(
    'v12 upgrade preserves progress and bindings; cropped artwork survives scrape and restart',
    () async {
      sqfliteFfiInit();
      final dir = await Directory.systemTemp.createTemp('ccplayer-migration-');
      final path = '${dir.path}/ccplayer.db';
      final catalog = Catalog.instance;
      var db = await databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 12,
          onCreate: (db, _) async {
            await db.execute(
              'CREATE TABLE sources (id TEXT PRIMARY KEY,label TEXT,password TEXT)',
            );
            await db.execute(
              'CREATE TABLE works (id TEXT PRIMARY KEY,title TEXT,year INTEGER,tmdb_id INTEGER,tmdb_type TEXT,bangumi_id INTEGER,poster TEXT,poster_fallback TEXT,manual_cover_url TEXT,manual_cover_source TEXT,overview TEXT,manual_lock INTEGER DEFAULT 0,needs_review INTEGER DEFAULT 0,hidden INTEGER DEFAULT 0,keep_hidden INTEGER DEFAULT 0)',
            );
            await db.execute(
              'CREATE TABLE assets (id TEXT PRIMARY KEY,source_id TEXT,work_id TEXT,relative_path TEXT,name TEXT,episode INTEGER,season INTEGER,category TEXT,extra_type TEXT,size INTEGER)',
            );
            await db.execute(
              'CREATE TABLE scan_roots (source_id TEXT,relative_path TEXT)',
            );
            await db.execute(
              'CREATE TABLE work_details (work_id TEXT PRIMARY KEY,identity TEXT,payload TEXT,fetched_at TEXT)',
            );
            await db.execute(
              'CREATE TABLE progress (asset_id TEXT PRIMARY KEY,position_ms INTEGER)',
            );
            await db.insert('works', {
              'id': '86',
              'title': '86',
              'tmdb_id': 100565,
              'bangumi_id': 302189,
              'manual_lock': 1,
            });
            await db.insert('progress', {
              'asset_id': 'video1',
              'position_ms': 9999,
            });
          },
        ),
      );
      await db.close();
      try {
        await catalog.initialize(dataDirectory: dir);
        db = catalog.db;
        expect(await db.getVersion(), 18);
        expect((await db.query('progress')).single['position_ms'], 9999);
        expect(catalog.works.single['manual_lock'], 1);
        await catalog.setBangumiLinks('86', [302189, 331887, 302189]);
        expect(jsonDecode(catalog.works.single['bangumi_ids'].toString()), [
          302189,
          331887,
        ]);
        final original = File('${dir.path}/source.png')
          ..writeAsStringSync('source remains untouched');
        ImageStore.root = Directory('${dir.path}/artwork');
        final originalId = await ImageStore.save(
          await original.readAsBytes(),
          'original',
        );
        final cropId = await ImageStore.save(
          utf8.encode('cropped bytes'),
          'crop',
        );
        await catalog.saveCroppedCover('86', 'bangumi', originalId, cropId, [
          0,
          0,
          400,
          600,
        ], subjectId: 331887);
        await db.update('works', {'manual_lock': 0});
        await catalog.applyScrapedWork(
          '86',
          const ScrapedWork(
            title: '86',
            provider: 'TMDB',
            bangumiId: 999,
            poster: 'https://images.tmdb.org/t/p/w500/x.jpg',
          ),
        );
        expect(Catalog.preferredPoster(catalog.works.single), cropId);
        expect(catalog.works.single['bangumi_id'], 302189);
        expect(await original.readAsString(), 'source remains untouched');
        await db.close();
        await catalog.initialize(dataDirectory: dir);
        db = catalog.db;
        expect(Catalog.preferredPoster(catalog.works.single), cropId);
        expect((await db.query('progress')).single['position_ms'], 9999);
        final work = catalog.works.single;
        await catalog.saveWorkDetails(work, {
          'characters': [
            {
              'id': 1,
              'name': 'one',
              'actors': [],
              'sources': [302189],
            },
            {
              'id': 2,
              'name': 'two',
              'actors': [],
              'sources': [331887],
            },
          ],
        });
        await catalog.setCharacterOrder('86', [2, 1]);
        await catalog.saveWorkDetails(catalog.works.single, {
          'characters': [
            {
              'id': 1,
              'name': 'one',
              'actors': [],
              'sources': [302189],
            },
          ],
          'errors': ['角色资料暂时不可用'],
        });
        final details = await catalog.readWorkDetails(catalog.works.single);
        expect((details!['characters'] as List).map((c) => c['id']), [2, 1]);
        ImageStore.root = Directory('${dir.path}/other-device');
        expect(
          Catalog.preferredPoster(catalog.works.single),
          'https://images.tmdb.org/t/p/w500/x.jpg',
        );
      } finally {
        await db.close();
        ImageStore.root = null;
        await dir.delete(recursive: true);
      }
    },
  );
}
