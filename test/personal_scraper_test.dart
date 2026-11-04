import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:ccplayer/core/catalog.dart';
import 'package:ccplayer/core/metadata.dart';
import 'package:ccplayer/core/personal_scraper.dart';

http.Response jsonResponse(Object body, {int status = 200}) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

void main() {
  test(
    'NipaPlay Personal TMDB ID first, official Bangumi exact-match fallback',
    () async {
      final old = Metadata.token, mode = Metadata.authMode;
      Metadata.token = 'dummy-token';
      Metadata.authMode = 'token';
      final paths = <String>[];
      final client = MockClient((req) async {
        paths.add('${req.method} ${req.url.path}');
        if (req.url.path.endsWith('/tv/217512')) {
          expect(req.headers['Authorization'], 'Bearer dummy-token');
          return jsonResponse({
            'id': 217512,
            'name': '16bit的感动 ANOTHER LAYER',
            'poster_path': '/16bit.jpg',
            'overview': 'TMDB overview',
            'first_air_date': '2023-10-04',
          });
        }
        if (req.url.path.endsWith('/v0/search/subjects')) {
          return jsonResponse({
            'data': [
              {
                'id': 413741,
                'name_cn': '16bit的感动 ANOTHER LAYER',
                'date': '2023-10-04',
              },
            ],
          });
        }
        if (req.url.path.endsWith('/v0/subjects/413741')) {
          return jsonResponse({
            'id': 413741,
            'name_cn': '16bit的感动 ANOTHER LAYER',
            'summary': 'Bangumi description',
            'date': '2023-10-04',
            'images': {'large': 'https://example.org/bgm.jpg'},
          });
        }
        return jsonResponse({}, status: 404);
      });
      final scraper = PersonalMetadataScraper(client: client);
      try {
        final result = await scraper.scrape(<String, Object?>{
          'title': '16bit的感动 ANOTHER LAYER',
          'tmdb_id': 217512,
          'tmdb_type': 'tv',
          'year': 2023,
        });
        expect(result, isNotNull);
        expect(result!.provider, 'TMDB + Bangumi');
        expect(result.tmdbId, 217512);
        expect(result.bangumiId, 413741);
        expect(result.poster, 'https://image.tmdb.org/t/p/w500/16bit.jpg');
        expect(result.bangumiPoster, 'https://example.org/bgm.jpg');
        expect(paths, contains('GET /3/tv/217512'));
        expect(paths.any((path) => path.contains('dandan')), isFalse);
      } finally {
        scraper.close();
        client.close();
        Metadata.token = old;
        Metadata.authMode = mode;
      }
    },
  );

  test(
    'No TMDB credential still permits exact Bangumi-only metadata',
    () async {
      final token = Metadata.token, mode = Metadata.authMode;
      Metadata.token = '';
      Metadata.authMode = 'token';
      final client = MockClient((req) async {
        expect(req.url.host, 'api.bgm.tv');
        if (req.method == 'POST') {
          return jsonResponse({
            'data': [
              {
                'id': 99,
                'name_cn': '测试动画',
                'name': 'Test Anime',
                'date': '2022-04-01',
              },
            ],
          });
        }
        return jsonResponse({
          'id': 99,
          'name_cn': '测试动画',
          'date': '2022-04-01',
          'images': {'large': 'https://bgm.tv/cover.jpg'},
        });
      });
      final scraper = PersonalMetadataScraper(client: client);
      try {
        final result = await scraper.scrape({'title': '测试动画', 'year': 2022});
        expect(result?.provider, 'Bangumi');
        expect(result?.tmdbId, isNull);
        expect(result?.bangumiId, 99);
        expect(result?.poster, 'https://bgm.tv/cover.jpg');
      } finally {
        client.close();
        scraper.close();
        Metadata.token = token;
        Metadata.authMode = mode;
      }
    },
  );

  test(
    'NipaPlay filename keyword fallback finds the correct Bangumi subject',
    () async {
      final original = Metadata.token, mode = Metadata.authMode;
      Metadata.token = '';
      Metadata.authMode = 'token';
      final client = MockClient((req) async {
        if (req.method == 'POST') {
          final data = jsonDecode(req.body) as Map;
          if ((data['keyword']?.toString() ?? '').contains('Shomin Sample')) {
            return jsonResponse({
              'data': [
                {
                  'id': 321,
                  'name': 'Shomin Sample',
                  'name_cn': '庶民样本',
                  'date': '2015-10-07',
                },
              ],
            });
          }
          return jsonResponse({'data': []});
        }
        return jsonResponse({
          'id': 321,
          'name': 'Shomin Sample',
          'name_cn': '庶民样本',
          'date': '2015-10-07',
          'images': {'large': 'https://bgm.tv/321.jpg'},
        });
      });
      final scraper = PersonalMetadataScraper(client: client);
      try {
        final result = await scraper.scrape(
          {'title': '庶民样本', 'year': 2015},
          filenames: ['[VCB-Studio] Shomin Sample [01][Ma10p_1080p][x265].mkv'],
        );
        expect(result?.bangumiId, 321);
        expect(result?.poster, 'https://bgm.tv/321.jpg');
      } finally {
        client.close();
        scraper.close();
        Metadata.token = original;
        Metadata.authMode = mode;
      }
    },
  );

  test('Ambiguous anime subjects stay unbound instead of guessing', () async {
    final token = Metadata.token, mode = Metadata.authMode;
    Metadata.token = '';
    Metadata.authMode = 'token';
    final client = MockClient(
      (req) async => jsonResponse({
        'data': [
          {'id': 21, 'name_cn': '相同名称', 'date': '2023-02-10'},
          {'id': 22, 'name_cn': '相同名称', 'date': '2023-03-10'},
        ],
      }),
    );
    final scraper = PersonalMetadataScraper(client: client);
    try {
      expect(await scraper.scrape({'title': '相同名称', 'year': 2023}), isNull);
    } finally {
      client.close();
      scraper.close();
      Metadata.token = token;
      Metadata.authMode = mode;
    }
  });

  test(
    'Metadata upsert never overwrites manual title/poster or progress',
    () async {
      sqfliteFfiInit();
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      Catalog.instance.db = db;
      try {
        await db.execute(
          'CREATE TABLE works (id TEXT PRIMARY KEY,title TEXT,year INTEGER,poster TEXT,overview TEXT,tmdb_id INTEGER,tmdb_type TEXT,bangumi_id INTEGER,manual_lock INTEGER,needs_review INTEGER)',
        );
        await db.execute(
          'CREATE TABLE progress (asset_id TEXT PRIMARY KEY,position_ms INTEGER)',
        );
        await db.insert('works', {
          'id': 'manual',
          'title': '我的标题',
          'year': 2022,
          'poster': 'local.jpg',
          'overview': 'mine',
          'manual_lock': 1,
          'needs_review': 0,
        });
        await db.insert('progress', {'asset_id': 'ep1', 'position_ms': 7654});
        final done = await Catalog.instance.applyScrapedWork(
          'manual',
          const ScrapedWork(
            title: 'Other',
            provider: 'TMDB',
            poster: 'remote.jpg',
          ),
          reloadAfter: false,
        );
        expect(done, isFalse);
        final work = (await db.query('works')).single;
        expect(work['title'], '我的标题');
        expect(work['poster'], 'local.jpg');
        expect((await db.query('progress')).single['position_ms'], 7654);
      } finally {
        await db.close();
      }
    },
  );

  test('BDRip with release-group prefix has a stable episode number', () {
    expect(
      Catalog.episode(
        '[SweetSub&VCB-Studio] 16bit Sensation [01][Ma10p_1080p][x265].mkv',
      ),
      1,
    );
    expect(Catalog.episode('[VCB-Studio] Anime [12][Ma10p_1080p].mkv'), 12);
    expect(Catalog.episode('[VCB-Studio] Anime [S02E03][Ma10p].mkv'), 3);
  });
}
