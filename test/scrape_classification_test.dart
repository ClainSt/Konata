import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ccplayer/core/catalog.dart';
import 'package:ccplayer/core/metadata.dart';
import 'package:ccplayer/core/personal_scraper.dart';
import 'package:ccplayer/core/personal_scrape_coordinator.dart';
import 'package:ccplayer/core/scan_activity.dart';

http.Response json(Object data) => http.Response(
  jsonEncode(data),
  200,
  headers: {'content-type': 'application/json'},
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late String oldToken, oldKey;
  setUp(() {
    oldToken = Metadata.token;
    oldKey = Metadata.apiKey;
    Metadata.token = '';
    Metadata.apiKey = '';
  });
  tearDown(() {
    Metadata.token = oldToken;
    Metadata.apiKey = oldKey;
  });

  final subjects = <int, Map<String, Object?>>{
    1: {
      'id': 1,
      'name': '進撃の巨人',
      'name_cn': '进击的巨人',
      'date': '2013-04-07',
      'infobox': [
        {
          'key': '别名',
          'value': [
            {'v': 'Shingeki no Kyojin'},
            {'v': 'Attack on Titan'},
          ],
        },
      ],
    },
    2: {
      'id': 2,
      'name': '氷菓',
      'name_cn': '冰菓',
      'date': '2012-04-22',
      'infobox': [
        {
          'key': '别名',
          'value': [
            {'v': 'Hyouka'},
          ],
        },
      ],
    },
  };
  test(
    'TMDB ID in folder or filename plus year selects unique season and rejects conflicting years',
    () async {
      Metadata.token = 'synthetic';
      final mode = Metadata.authMode;
      Metadata.authMode = 'token';
      addTearDown(() => Metadata.authMode = mode);
      final client = MockClient((request) async {
        final path = request.url.path;
        if (request.method == 'POST') return json({'data': []});
        if (path == '/3/tv/42') {
          return json({
            'id': 42,
            'name': 'Series',
            'first_air_date': '2018-01-01',
            'seasons': [
              {'season_number': 1, 'air_date': '2018-01-01'},
              {'season_number': 2, 'air_date': '2020-01-01'},
              {'season_number': 3, 'air_date': '2022-01-01'},
              {'season_number': 4, 'air_date': '2022-10-01'},
            ],
          });
        }
        if (path == '/3/tv/42/season/2') {
          return json({
            'season_number': 2,
            'air_date': '2020-01-01',
            'poster_path': '/s2.jpg',
          });
        }
        return http.Response('{}', 404);
      });
      final scraper = PersonalMetadataScraper(client: client);
      final folder = await scraper.scrape({
        'title': 'Any name (2020) [tmdbid=42]',
      });
      expect(folder?.title, 'Series 第2季');
      expect(folder?.poster, endsWith('/s2.jpg'));
      expect(
        (await scraper.scrape({'title': 'Any name S2 {tmdb-42}'}))?.year,
        2020,
      );
      final filename = PersonalMetadataScraper.filenameWork(
        'Any name (2020) {tmdb-42} - 01.mkv',
      )!;
      expect((await scraper.scrape(filename))?.title, 'Series 第2季');
      expect(
        await scraper.scrape({'title': 'Any name (2022) {tmdb-42}'}),
        isNull,
      );
      expect(
        await scraper.scrape({'title': 'Any name S2 (2018) {tmdb-42}'}),
        isNull,
      );
      expect(
        await scraper.scrape({'title': 'Any name {tmdb-42} [tmdb=43]'}),
        isNull,
      );
      expect(
        (await scraper.scrape({'title': 'Any name (2018) {tmdb-42}'}))?.tmdbId,
        42,
      );
    },
  );
  PersonalMetadataScraper fake({
    List<String>? queries,
  }) => PersonalMetadataScraper(
    client: MockClient((request) async {
      if (request.method == 'GET') {
        return json(subjects[int.parse(request.url.path.split('/').last)]!);
      }
      final query = (jsonDecode(request.body) as Map)['keyword'].toString();
      queries?.add(query);
      return json({
        'data': subjects.values
            .where(
              (row) =>
                  PersonalMetadataScraper.officialTitles(row).contains(query),
            )
            .map(
              (row) => {
                for (final key in ['id', 'name', 'name_cn', 'date'])
                  key: row[key],
              },
            )
            .toList(),
      });
    }),
  );

  test(
    'official Chinese/Japanese/English/romaji aliases resolve, fuzzy does not',
    () async {
      final scraper = fake();
      for (final title in [
        '进击的巨人',
        '進撃の巨人',
        'Attack on Titan',
        'Shingeki no Kyojin',
      ]) {
        expect(
          (await scraper.scrape({'title': title, 'year': 2013}))?.bangumiId,
          1,
        );
      }
      expect((await scraper.scrape({'title': '冰菓'}))?.bangumiId, 2);
      expect(await scraper.scrape({'title': 'Shingeki no Kyoji'}), isNull);
      expect(
        await scraper.scrape({'title': 'Attack on Titan', 'year': 2020}),
        isNull,
      );
      expect(
        await scraper.scrape({'title': 'Attack on Titan S2', 'year': 2013}),
        isNull,
      );
    },
  );

  test(
    'folder conflict and seventh file are checked, episodes deduplicate',
    () async {
      final queries = <String>[];
      final scraper = fake(queries: queries);
      final files = [
        for (var i = 1; i <= 12; i++)
          '[Group] Shingeki no Kyojin [$i][1080p].mkv',
        'Hyouka - 01.mkv',
        'unknown.mkv',
      ];
      final result = await scraper.classify(
        {'title': 'Mixed'},
        [
          for (var i = 0; i < files.length; i++) {'id': '$i', 'name': files[i]},
        ],
      );
      expect(result.values.take(12).every((v) => v?.bangumiId == 1), isTrue);
      expect(result['12']?.bangumiId, 2);
      expect(result['13'], isNull);
      expect(queries.where((q) => q == 'Shingeki no Kyojin').length, 1);
      expect(
        await scraper.scrape(
          {'title': '进击的巨人'},
          filenames: ['Hyouka - 01.mkv'],
        ),
        isNull,
      );
    },
  );

  test(
    'rescraping replaces stale automatic identity without stale artwork',
    () async {
      final dir = await Directory.systemTemp.createTemp('konata-rematch-');
      final cat = Catalog.instance;
      await cat.initialize(dataDirectory: dir);
      addTearDown(() async {
        await cat.db.close();
        await dir.delete(recursive: true);
      });
      await cat.indexVideo('s', 'Hyouka/Hyouka - 01.wmv', 100);
      await cat.db.update('works', {
        'title': 'Wrong 第3季',
        'tmdb_id': 999,
        'tmdb_type': 'tv',
        'year': 2025,
        'poster': 'https://example.org/wrong.jpg',
      });
      await cat.reload();
      final work = cat.works.single;
      final match = await fake().scrape(work);
      expect(match?.bangumiId, 2);
      expect(match?.tmdbId, isNull);
      await cat.applyScrapedWork(work['id'].toString(), match!);
      expect(cat.works.single['tmdb_id'], isNull);
      expect(cat.works.single['poster'], isNull);
      expect(cat.works.single['year'], 2012);
      expect(cat.assets.single['name'], endsWith('.wmv'));
    },
  );

  test(
    'rescraping virtual groups isolates pending files and protects locked targets',
    () async {
      final dir = await Directory.systemTemp.createTemp('konata-regroup-');
      final cat = Catalog.instance;
      await cat.initialize(dataDirectory: dir);
      addTearDown(() async {
        await cat.db.close();
        await dir.delete(recursive: true);
      });
      for (final name in ['a.mkv', 'b.mkv', 'c.mkv']) {
        await cat.indexVideo('s', 'Mixed/$name', 100);
      }
      await cat.reload();
      final origin = cat.works.single['id'].toString();
      final ids = {for (final a in cat.assets) a['name']: a['id'].toString()};
      const match = ScrapedWork(title: '冰菓', provider: 'Bangumi', bangumiId: 2);
      await cat.applyClassification(origin, {
        ids['a.mkv']!: match,
        ids['b.mkv']!: match,
      });
      await cat.reload();
      final target = cat.works
          .singleWhere((w) => w['bangumi_id'] == 2)['id']
          .toString();
      expect(
        await cat.applyClassification(target, {ids['a.mkv']!: match}),
        false,
      );
      await cat.reload();
      expect(cat.unclassifiedAssets.map((a) => a['name']).toSet(), {
        'b.mkv',
        'c.mkv',
      });
      await cat.db.update(
        'works',
        {'manual_lock': 1, 'bangumi_id': 99},
        where: 'id=?',
        whereArgs: [target],
      );
      expect(
        await cat.applyClassification(origin, {ids['b.mkv']!: match}),
        false,
      );
      await cat.reload();
      expect(cat.unclassifiedAssets.map((a) => a['name']).toSet(), {
        'b.mkv',
        'c.mkv',
      });
      expect(cat.works.singleWhere((w) => w['id'] == target)['bangumi_id'], 99);
    },
  );

  test(
    'virtual grouping survives rescan, manual batch is atomic and preserves progress',
    () async {
      final dir = await Directory.systemTemp.createTemp('konata-classify-');
      final cat = Catalog.instance;
      await cat.initialize(dataDirectory: dir);
      addTearDown(() async {
        await cat.db.close();
        await dir.delete(recursive: true);
      });
      for (final file in [
        'Shingeki no Kyojin - 01.mkv',
        'Hyouka - 01.mkv',
        'unknown.mkv',
      ]) {
        await cat.indexVideo('s', 'Mixed/$file', 100);
      }
      await cat.reload();
      final original = cat.assets
          .map((r) => Map<String, Object?>.from(r))
          .toList();
      for (final asset in original) {
        await cat.progress(asset['id'].toString(), 1234, 5000);
      }
      final work = cat.works.single;
      await cat.applyClassification(
        work['id'].toString(),
        await fake().classify(work, cat.assets),
      );
      for (final asset in original) {
        await cat.indexVideo('s', asset['relative_path'].toString(), 100);
      }
      await cat.reload();
      expect(cat.works.length, 3);
      expect(cat.unclassifiedAssets.single['name'], 'unknown.mkv');
      expect(
        cat.assets.map((r) => r['id']).toSet(),
        original.map((r) => r['id']).toSet(),
      );
      final unknown = cat.unclassifiedAssets.single['id'].toString();
      final target = cat.works
          .firstWhere((w) => w['bangumi_id'] == 2)['id']
          .toString();
      await expectLater(
        cat.classifyManually({unknown, 'missing'}, targetWorkId: target),
        throwsStateError,
      );
      expect((await cat.db.query('asset_overrides')), isEmpty);
      await cat.classifyManually({unknown}, targetWorkId: target);
      await cat.indexVideo('s', 'Mixed/unknown.mkv', 100);
      await cat.pruneOrphanedWorks();
      await cat.reload();
      expect(cat.unclassifiedAssets, isEmpty);
      expect(
        cat.assets.firstWhere((a) => a['id'] == unknown)['work_id'],
        target,
      );
      expect(
        (await cat.db.query('progress')).every((r) => r['position_ms'] == 1234),
        isTrue,
      );
      expect(await cat.undoAssetRelation(unknown), isTrue);
      expect(cat.unclassifiedAssets.single['id'], unknown);
    },
  );

  test(
    '1001 TV works / 12012 files use two metadata requests per title and skip completed on resume',
    () async {
      final dir = await Directory.systemTemp.createTemp('konata-scale-');
      final cat = Catalog.instance;
      await cat.initialize(dataDirectory: dir);
      addTearDown(() async {
        await cat.db.close();
        await dir.delete(recursive: true);
      });
      final batch = cat.db.batch();
      for (var i = 0; i < 1001; i++) {
        final title = 'Animation $i';
        final work = 'work:s:${Uri.encodeComponent(title)}';
        batch.insert('works', {'id': work, 'title': title});
        for (var e = 1; e <= 12; e++) {
          batch.insert('assets', {
            'id': 'asset:$i:$e',
            'source_id': 's',
            'work_id': work,
            'relative_path': '$title/$title - $e.mkv',
            'name': '$title - $e.mkv',
            'episode': e,
            'category': 'main',
          });
        }
      }
      await batch.commit(noResult: true);
      await cat.reload();
      var calls = 0;
      final client = MockClient((request) async {
        calls++;
        final id = request.method == 'POST'
            ? int.parse(
                (jsonDecode(request.body) as Map)['keyword']
                    .toString()
                    .split(' ')
                    .last,
              )
            : int.parse(request.url.path.split('/').last);
        final row = {
          'id': id,
          'name': 'Animation $id',
          'images': {'large': 'https://example.org/$id.jpg'},
        };
        return json(
          request.method == 'POST'
              ? {
                  'data': [row],
                }
              : row,
        );
      });
      final scraper = PersonalMetadataScraper(client: client);
      final watch = Stopwatch()..start();
      final report = await PersonalScrapeCoordinator(
        scraper: scraper,
      ).scrapeSource('s');
      expect(report.matched, 1001);
      expect(report.errors, 0);
      expect(report.review, 0);
      expect(calls, 2002);
      final resumed = await PersonalScrapeCoordinator(
        scraper: scraper,
      ).scrapeSource('s');
      expect(resumed.skipped, 1001);
      expect(calls, 2002);
      // This measures local parsing, matching and SQLite work, not internet speed.
      // ignore: avoid_print
      print(
        'SCRAPE_SCALE titles=1001 assets=12012 requests=$calls elapsedMs=${watch.elapsedMilliseconds}',
      );
      final run = ScanActivity('s', []);
      run.cancel();
      await expectLater(
        PersonalScrapeCoordinator(
          scraper: scraper,
        ).scrapeSource('s', onlyPending: false, run: run),
        throwsA(isA<ScanCancelled>()),
      );
      expect(cat.scanning, isFalse);
      scraper.close();
      client.close();
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
  test('real release markers do not erase numeric title words', () {
    for (final entry in {
      '86 - 01.mkv': '86',
      '[Group] Animation 12 - 01.mkv': 'Animation 12',
      '[Group] mono #01.mkv': 'mono',
      'The Gene of AI - 02v2.mkv': 'The Gene of AI',
      'Lets.Play.S01E01.Episode.Title.1080p.mkv': 'Lets Play S1',
      '91 Days 01.mkv': '91 Days',
    }.entries) {
      expect(
        PersonalMetadataScraper.filenameWork(entry.key)?['title'],
        entry.value,
      );
    }
  });
  test(
    'named extras are checked while unnamed extras can follow a proven title',
    () async {
      final scraper = fake();
      final proven = await scraper.scrape({'title': '进击的巨人'});
      final result = await scraper.classify(
        {'title': '@unclassified'},
        [
          {'id': 'opening', 'name': 'NCOP01.mkv', 'category': 'extra'},
          {'id': 'other', 'name': 'Hyouka NCOP01.mkv', 'category': 'extra'},
        ],
        unnamedFallback: proven,
      );
      expect(result['opening']?.bangumiId, 1);
      expect(result['other']?.bangumiId, 2);
    },
  );
}
