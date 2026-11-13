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
import 'package:ccplayer/core/personal_filename_parser.dart';
import 'package:ccplayer/core/release_groups.dart';

http.Response json(Object data) => http.Response(
  jsonEncode(data),
  200,
  headers: {'content-type': 'application/json'},
);

Iterable<Map<String, Object?>> pendingFiles(Catalog catalog) {
  final pending = catalog.works
      .where((work) => work['needs_review'] == 1 && work['manual_lock'] != 1)
      .map((work) => work['id'])
      .toSet();
  return catalog.assets.where(
    (asset) =>
        pending.contains(asset['work_id']) && asset['manual_mapping'] != true,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('same confirmed Bangumi identity survives a missing TMDB type', () {
    const fallback = ScrapedWork(
      title: '书虫公主',
      provider: 'Bangumi',
      tmdbId: 156510,
      bangumiId: 366695,
    );
    const complete = ScrapedWork(
      title: '书虫公主',
      provider: 'TMDB + Bangumi',
      tmdbId: 156510,
      tmdbType: 'tv',
      bangumiId: 366695,
    );
    expect(fallback.sameWork(complete), true);
    expect(complete.sameWork(fallback), true);
    expect(
      complete.sameWork(
        const ScrapedWork(
          title: 'Other',
          provider: 'TMDB',
          tmdbId: 99,
          tmdbType: 'tv',
          bangumiId: 366695,
        ),
      ),
      false,
    );
  });
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
    'Bangumi linking retains the original official title before translated TMDB title',
    () async {
      Metadata.token = 'synthetic';
      final mode = Metadata.authMode;
      Metadata.authMode = 'token';
      addTearDown(() => Metadata.authMode = mode);
      final scraper = PersonalMetadataScraper(
        client: MockClient((request) async {
          if (request.url.path == '/3/tv/76063') {
            return json({
              'id': 76063,
              'name': '柑橘味香气',
              'original_name': 'citrus',
              'first_air_date': '2018-01-06',
            });
          }
          const subject = {
            'id': 198098,
            'name': 'citrus',
            'name_cn': 'citrus～柑橘味香气～',
            'date': '2018-01-06',
          };
          if (request.method == 'POST') {
            return json({
              'data': [subject],
            });
          }
          if (request.url.path == '/v0/subjects/198098') return json(subject);
          return http.Response('{}', 404);
        }),
      );
      final result = await scraper.scrape({
        'title': 'citrus～柑橘味香气～ (2018) {tmdb-76063}',
      });
      expect(result?.tmdbId, 76063);
      expect(result?.bangumiId, 198098);
    },
  );
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
        'title': 'Series (2020) [tmdbid=42]',
      });
      expect(folder?.title, 'Series 第2季');
      expect(folder?.poster, endsWith('/s2.jpg'));
      expect(
        (await scraper.scrape({'title': 'Series S2 {tmdb-42}'}))?.year,
        2020,
      );
      final filename = PersonalMetadataScraper.filenameWork(
        'Series (2020) {tmdb-42} - 01.mkv',
      )!;
      expect((await scraper.scrape(filename))?.title, 'Series 第2季');
      // An explicit series ID survives same-year season ambiguity; no season
      // may be selected from the year alone (covered by remaining rules tests).
      final ambiguous = await scraper.scrape({'title': 'Series (2022) {tmdb-42}'});
      expect(ambiguous?.tmdbId, 42);
      expect(ambiguous?.title, 'Series');
      expect(await scraper.scrape({'title': 'Series (2024) {tmdb-42}'}), isNull);
      expect(
        await scraper.scrape({'title': 'Series S2 (2018) {tmdb-42}'}),
        isNull,
      );
      expect(
        await scraper.scrape({'title': 'Series {tmdb-42} [tmdb=43]'}),
        isNull,
      );
      expect(
        (await scraper.scrape({'title': 'Series (2018) {tmdb-42}'}))?.tmdbId,
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
    'bracket candidates require one official identity, never a guessed group position',
    () async {
      final scraper = fake();
      final matches = await scraper.classify(
        {'title': 'Mixed'},
        [
          {'id': 'one', 'name': '[Some Group][Hyouka][01][1080p][JPSC].mkv'},
          {'id': 'two', 'name': '[Hyouka][Shingeki no Kyojin][01][1080p].mkv'},
        ],
      );
      expect(matches['one']?.bangumiId, 2);
      expect(matches['two'], isNull);
    },
  );

  test(
    'bare episode suffix needs sibling sequence and cannot override a full title',
    () async {
      final scraper = fake();
      final files = [
        for (final n in ['01', '02', '03', '10', '11', '12'])
          {'id': n, 'name': '[Group] Hyouka $n [1080p].mkv'},
      ];
      final matches = await scraper.classify({'title': 'Mixed'}, files);
      expect(matches.values.every((m) => m?.bangumiId == 2), true);
      expect(
        (await scraper.classify(
          {'title': 'Mixed'},
          [
            {'id': 'alone', 'name': 'Hyouka 10.mkv'},
          ],
        ))['alone'],
        isNull,
      );
      expect(
        PersonalMetadataScraper.filenameWork('Animation 12 - 01.mkv')?['title'],
        'Animation 12',
      );
      subjects[3] = {'id': 3, 'name': 'Hyouka 10'};
      addTearDown(() => subjects.remove(3));
      final collision = await fake().classify({'title': 'Mixed'}, files);
      expect(collision['10'], isNull);
      expect(collision['11']?.bangumiId, 2);
    },
  );

  test('bare episode evidence cannot cross physical directories', () async {
    final matches = await fake().classify(
      {'title': 'Mixed'},
      [
        for (final n in [10, 11, 12])
          {
            'id': '$n',
            'name': 'Hyouka $n.mkv',
            'relative_path': 'Folder$n/Hyouka $n.mkv',
          },
      ],
    );
    expect(matches.values.every((m) => m == null), true);
  });

  test('bracket candidates preserve numeric titles and explicit seasons', () {
    final numeric = PersonalMetadataScraper.filenameCandidates(
      '[Group][86][01][1080p].mkv',
    );
    expect(numeric.any((c) => c['title'] == '86'), true);
    final seasonal = PersonalMetadataScraper.filenameCandidates(
      '[Group][Hyouka][S02E01][1080p].mkv',
    );
    expect(seasonal.any((c) => c['title'] == 'Hyouka S2'), true);
    expect(seasonal.any((c) => c['title'] == 'S02E01 S2'), false);
  });

  test(
    'known publisher suffix adds a candidate without erasing a full title',
    () async {
      final original = 'Hyouka - VCB-Studio';
      final candidates = PersonalMetadataScraper.filenameCandidates(
        '$original.mkv',
      );
      expect(candidates.any((c) => c['title'] == original), true);
      expect(candidates.any((c) => c['title'] == 'Hyouka'), true);
      final files = [
        {'id': 'one', 'name': '$original.mkv'},
      ];
      expect(
        (await fake().classify({'title': 'Mixed'}, files))['one']?.bangumiId,
        2,
      );
      subjects[4] = {'id': 4, 'name': original};
      addTearDown(() => subjects.remove(4));
      expect((await fake().classify({'title': 'Mixed'}, files))['one'], isNull);
    },
  );

  test(
    'publisher dictionary only removes entire bounded tags, not title words',
    () {
      expect(ReleaseGroups.contains('VCB-Studio'), true);
      expect(ReleaseGroups.contains('iNTERNAL'), true);
      expect(ReleaseGroups.contains('INTERNAL'), false);
      expect(
        PersonalFilenameParser.withoutKnownReleaseGroups(
          'VCB-Studio Story.mkv',
        ),
        isNull,
      );
      expect(
        PersonalFilenameParser.withoutKnownReleaseGroups(
          'Title-UnknownGroup.mkv',
        ),
        isNull,
      );
      expect(
        PersonalFilenameParser.withoutKnownReleaseGroups(
          '[VCB-Studio] Hyouka.mkv',
        ),
        'Hyouka.mkv',
      );
      expect(
        PersonalFilenameParser.withoutKnownReleaseGroups(
          'Hyouka-VCB-Studio.mkv',
        ),
        'Hyouka.mkv',
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
      expect(pendingFiles(cat).map((a) => a['name']).toSet(), {
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
      expect(pendingFiles(cat).map((a) => a['name']).toSet(), {
        'b.mkv',
        'c.mkv',
      });
      expect(cat.works.singleWhere((w) => w['id'] == target)['bangumi_id'], 99);
    },
  );

  test(
    'automatic virtual grouping and viewing progress survive rescan',
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
      expect(pendingFiles(cat).single['name'], 'unknown.mkv');
      expect(
        cat.assets.map((r) => r['id']).toSet(),
        original.map((r) => r['id']).toSet(),
      );
      expect((await cat.db.query('asset_overrides')), isEmpty);
      expect(
        (await cat.db.query('progress')).every((r) => r['position_ms'] == 1234),
        isTrue,
      );
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
