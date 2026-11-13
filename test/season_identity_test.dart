import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:ccplayer/core/catalog.dart';
import 'package:ccplayer/core/metadata.dart';
import 'package:ccplayer/core/personal_scraper.dart';
import 'package:ccplayer/core/work_season.dart';

void main() {
  test('Personal ID syntax and strict year checks are retained', () {
    for (final marker in [
      '{tmdb-65844}',
      '{tmdbtv=65844}',
      '{tmdbid:65844}',
      '[tmdb=65844]',
      '{[tmdbid=65844;type=tv]}',
    ]) {
      expect(Catalog.tmdbId('Show (2017) $marker'), 65844);
    }
    expect(Catalog.tmdbType('{tmdbmovie-123}'), 'movie');
    expect(Catalog.year('Show 2017 {tmdb-65844}'), 2017);
    expect(Catalog.year('Show (1920x1080)'), isNull);
    expect(PersonalMetadataScraper.yearCompatible(2017, '2016-12-31'), isFalse);
    expect(
      PersonalMetadataScraper.queries('Show 2nd Season (2017)'),
      contains('Show'),
    );
    expect(
      WorkSeason.resolve(
        {'title': 'Show S1+S2 (2018)'},
        [
          {'season_number': 1, 'air_date': '2018-01-01'},
          {'season_number': 2, 'air_date': '2019-01-01'},
        ],
      ),
      isNull,
    );
  });
  test(
    'same TMDB ID retains three directory seasons and their artwork after prior scrape',
    () async {
      final token = Metadata.token, mode = Metadata.authMode;
      Metadata.token = 'test-token';
      Metadata.authMode = 'token';
      const base = '为美好的世界献上祝福！';
      final years = [2016, 2017, 2024];
      final calls = <String>[];
      final client = MockClient((request) async {
        final path = request.url.path;
        calls.add(path);
        Map<String, Object?> data = {};
        if (path == '/3/tv/65844') {
          data = {
            'id': 65844,
            'name': base,
            'poster_path': '/latest-s3.jpg',
            'first_air_date': '2016-01-01',
            'seasons': [
              for (var i = 0; i < 3; i++)
                {
                  'season_number': i + 1,
                  'air_date': '${years[i]}-01-01',
                  'poster_path': '/s${i + 1}.jpg',
                },
            ],
          };
        } else if (path.contains('/season/')) {
          final number = int.parse(path.split('/').last);
          data = {
            'season_number': number,
            'air_date': '${years[number - 1]}-01-01',
            'poster_path': '/s$number.jpg',
          };
        } else if (path.endsWith('/v0/search/subjects')) {
          data = {'data': []};
        }
        return http.Response(
          jsonEncode(data),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final scraper = PersonalMetadataScraper(client: client);
      sqfliteFfiInit();
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      final catalog = Catalog.instance;
      catalog.db = db;
      await db.execute(
        'CREATE TABLE works (id TEXT PRIMARY KEY, title TEXT, year INTEGER, tmdb_id INTEGER, tmdb_type TEXT, bangumi_id INTEGER, poster TEXT, poster_fallback TEXT, overview TEXT, manual_lock INTEGER DEFAULT 0, needs_review INTEGER DEFAULT 1, hidden INTEGER DEFAULT 0, keep_hidden INTEGER DEFAULT 0)',
      );
      await db.execute(
        'CREATE TABLE assets (id TEXT PRIMARY KEY, source_id TEXT, work_id TEXT, relative_path TEXT, name TEXT, episode INTEGER, season INTEGER, category TEXT, extra_type TEXT, size INTEGER)',
      );
      await db.execute(
        'CREATE TABLE asset_overrides (asset_id TEXT, work_id TEXT, episode INTEGER, season INTEGER, category TEXT, extra_type TEXT)',
      );
      await db.execute(
        'CREATE TABLE progress (asset_id TEXT PRIMARY KEY, position_ms INTEGER)',
      );
      try {
        for (var i = 0; i < 3; i++) {
          final suffix = ['', ' 第二季', ' 第三季'][i];
          final folder = '$base$suffix (${years[i]}) {tmdb-65844}';
          final work = <String, Object?>{
            'id': 'work:source:${Uri.encodeComponent(folder)}',
            'title': base,
            'tmdb_id': 65844,
            'tmdb_type': 'tv',
            'year': years[i],
          };
          expect(WorkSeason.needsRefresh(work), isTrue);
          await catalog.indexVideo(
            'source',
            '$folder/[Group] Show [01].mkv',
            100,
            workFolder: folder,
            needsReview: false,
          );
          await db.update(
            'works',
            {'title': base, 'poster': '/latest-s3.jpg'},
            where: 'id=?',
            whereArgs: [work['id']],
          );
          final result = await scraper.scrape(work);
          expect(result, isNotNull);
          expect(result!.title, '$base 第${i + 1}季');
          expect(
            result.poster,
            'https://image.tmdb.org/t/p/w500/s${i + 1}.jpg',
          );
          expect(result.year, years[i]);
          await catalog.applyScrapedWork(
            work['id'].toString(),
            result,
            reloadAfter: false,
          );
          final saved = (await db.query(
            'works',
            where: 'id=?',
            whereArgs: [work['id']],
          )).single;
          expect(saved['title'], '$base 第${i + 1}季');
          expect(saved['poster'], result.poster);
          final asset = (await db.query(
            'assets',
            where: 'work_id=?',
            whereArgs: [work['id']],
          )).single;
          expect(asset['season'], i + 1);
          expect(asset['episode'], 1);
          await db.insert('progress', {
            'asset_id': asset['id'],
            'position_ms': 42000,
          });
          expect(
            WorkSeason.needsRefresh({...work, 'title': result.title}),
            isFalse,
          );
        }
        expect((await db.query('works')).length, 3);
        expect(
          (await db.query('progress')).every((p) => p['position_ms'] == 42000),
          isTrue,
        );
        expect(
          calls,
          containsAll([
            '/3/tv/65844/season/1',
            '/3/tv/65844/season/2',
            '/3/tv/65844/season/3',
          ]),
        );
        expect(
          await scraper.scrape({
            'title': '$base 第二季',
            'tmdb_id': 65844,
            'tmdb_type': 'tv',
            'year': 2024,
          }),
          isNull,
        );
      } finally {
        await db.close();
        scraper.close();
        client.close();
        Metadata.token = token;
        Metadata.authMode = mode;
      }
    },
  );
  test('Chinese season directories survive indexing', () {
    expect(Catalog.detectedSeason('为美好的世界献上祝福！ 第二季 (2017)/01.mkv'), 2);
    expect(Catalog.detectedSeason('为美好的世界献上祝福！ 第三季 (2024)/01.mkv'), 3);
  });
}
