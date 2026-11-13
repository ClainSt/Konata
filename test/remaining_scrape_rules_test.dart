import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:ccplayer/core/bangumi_offline_index.dart';
import 'package:ccplayer/core/metadata.dart';
import 'package:ccplayer/core/episode_metadata.dart';
import 'package:ccplayer/core/detail_metadata.dart';
import 'package:ccplayer/core/work_season.dart';
import 'package:ccplayer/core/personal_scraper.dart';
import 'package:ccplayer/core/personal_filename_parser.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('bracket release year wins over numeric title and conflicts remain visible', () {
    expect(WorkSeason.year({'title': '暗夜第六感 2041 (2021) {tmdb-112616}'}), 2021);
    expect(WorkSeason.year({'title': 'Series（2020）'}), 2020);
    expect(WorkSeason.conflictingYears({'title': 'Series (2020) (2021)'}), true);
    expect(WorkSeason.year({'title': 'Series (2020) (2021)'}), isNull);
    expect(WorkSeason.year({'title': 'Series (1920x1080)'}), isNull);
  });
  test('unique series survives same-year season ambiguity end to end', () async {
    final token = Metadata.token;
    Metadata.token = 'test';
    addTearDown(() => Metadata.token = token);
    final overview = <String, dynamic>{
      'id': 10, 'name': 'Series', 'first_air_date': '2020-01-01',
      'seasons': [
        {'season_number': 1, 'air_date': '2020-01-01', 'episode_count': 12},
        {'season_number': 2, 'air_date': '2020-10-01', 'episode_count': 12},
      ],
    };
    final client = MockClient((request) async => http.Response(
      jsonEncode(request.url.path == '/3/tv/10' ? overview : {'data': [], 'results': []}),
      request.url.path == '/3/movie/10' ? 404 : 200,
      headers: {'content-type': 'application/json'},
    ));
    addTearDown(client.close);
    final scraper = PersonalMetadataScraper(client: client);
    addTearDown(scraper.close);
    final work = <String, Object?>{'title': 'Series (2020) {tmdb-10}'};
    final matched = await scraper.scrape(work);
    expect(matched?.tmdbId, 10);
    expect(matched?.title, 'Series');
    expect(await scraper.scrape({'title': 'Series (2022) {tmdb-10}'}), isNull);
    expect(await scraper.scrape({'title': 'Series (2020) (2021) {tmdb-10}'}), isNull);
    final service = DetailMetadataService(client: client, tmdbRequest: (path, _) async => path == '/tv/10' ? overview : {'episodes': []});
    final details = await service.fetch({...work, 'tmdb_id': 10, 'tmdb_type': 'tv'});
    expect(details['seasonMappingAmbiguous'], true);
  });
  test('ambiguous same-year seasons do not invent episode mapping', () {
    final work = <String, Object?>{'title': 'Series (2020)'};
    expect(
      WorkSeason.ambiguousYear(work, [
        {'season_number': 1, 'air_date': '2020-01-01'},
        {'season_number': 2, 'air_date': '2020-10-01'},
      ]),
      true,
    );
    final details = <String, dynamic>{
      'seasonMappingAmbiguous': true,
      'seasonEpisodes': {
        '1': {
          '1': {'name': 'Wrong default'},
        },
        '2': {
          '1': {'name': 'Explicit'},
        },
      },
    };
    expect(
      EpisodeMetadata.lookup(work, details, {
        'episode': 1,
        'category': 'main',
        'name': 'Series - 01.mkv',
      }),
      isEmpty,
    );
    expect(
      EpisodeMetadata.lookup(work, details, {
        'episode': 1,
        'category': 'main',
        'name': 'Series S02E01.mkv',
      })['name'],
      'Explicit',
    );
  });
  test('release metadata is cleaned before title matching', () {
    expect(
      PersonalFilenameParser.bracketTitleCandidates(
        '[Series][01][1920x1080][TrueHD][FLACx2][ASSx2][YUV420P10][5.1].mkv',
      ),
      ['Series'],
    );
    expect(
      PersonalFilenameParser.extractAnimeTitleKeyword(
        '[Nekomoe kissaten][180-kimimimi][01][1080p][JPSC].mp4',
      ),
      '180-kimimimi',
    );
    expect(
      PersonalFilenameParser.extractAnimeTitleKeyword(
        '[VCB-Studio] Citrus [01][Ma10p_1080p][x265_flac_aac].mkv',
      ),
      'Citrus',
    );
    expect(
      PersonalFilenameParser.extractAnimeTitleKeyword('[WAR][01].mkv'),
      'WAR',
    );
  });
  for (final scenario in [
    'single',
    'standard_episode',
    'mixed',
    'network',
    'conflict',
  ]) {
    test('verified directory inheritance $scenario', () async {
      final token = Metadata.token;
      Metadata.token = 'test';
      addTearDown(() => Metadata.token = token);
      final queries = <String>[];
      final client = MockClient((request) async {
        final path = request.url.path;
        Object data = {'results': [], 'data': []};
        if (path == '/3/tv/10') {
          data = {
            'id': 10,
            'name': '180秒能让你的耳朵幸福吗？',
            'first_air_date': '2021-01-01',
            'seasons': [],
          };
        } else if (path.contains('/search')) {
          queries.add(
            request.method == 'POST'
                ? '${(jsonDecode(request.body) as Map)['keyword']}'
                : request.url.queryParameters['query'] ?? '',
          );
          if (scenario == 'network') throw const SocketException('offline');
          if (scenario == 'conflict' && path.contains('/search/movie')) {
            data = {
              'results': [
                {
                  'id': 99,
                  'title': '180-kimimimi',
                  'release_date': '2021-01-01',
                },
              ],
            };
          }
        } else if (path == '/3/movie/99') {
          data = {
            'id': 99,
            'title': '180-kimimimi',
            'release_date': '2021-01-01',
          };
        }
        return http.Response(
          jsonEncode(data),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final scraper = PersonalMetadataScraper(client: client);
      addTearDown(() {
        scraper.close();
        client.close();
      });
      Map<String, ScrapedWork?> results;
      try {
        results = await scraper.classify(
          {'title': '180秒能让你的耳朵幸福吗？ (2021) {tmdbtv-10}'},
          [
            for (var i = 1; i <= 3; i++)
              {
                'id': '$i',
                'name': scenario == 'standard_episode'
                    ? '180-kimimimi.S01E0$i.Episode.Title.mkv'
                    : '[Nekomoe kissaten][${scenario == 'mixed' && i == 3 ? 'Other' : '180-kimimimi'}][0$i][1080p][JPSC].mp4',
                'category': 'main',
              },
          ],
        );
      } catch (_) {
        if (scenario != 'network') rethrow;
        return;
      }
      expect(
        results.values.whereType<ScrapedWork>().length,
        ['single', 'standard_episode'].contains(scenario) ? 3 : 0,
      );
      expect(
        queries.where((q) => q.toLowerCase() == 'nekomoe kissaten'),
        isEmpty,
      );
    });
  }
  test('punctuation keeps legacy offline collisions visible', () async {
    expect(PersonalMetadataScraper.exactTitle('Lets Play', 'Let’s Play'), true);
    expect(PersonalMetadataScraper.exactTitle('A-B', 'A‐B'), true);
    expect(PersonalMetadataScraper.exactTitle('A B 2', 'A B'), false);
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final dir = await Directory.systemTemp.createTemp('legacy-punctuation-');
    addTearDown(() => dir.delete(recursive: true));
    final db = await databaseFactory.openDatabase(
      '${dir.path}/animation.sqlite',
    );
    await db.execute('CREATE TABLE names(name TEXT, subject_id INTEGER)');
    await db.execute(
      'CREATE TABLE subjects(id INTEGER PRIMARY KEY, payload TEXT)',
    );
    for (var i = 1; i <= 2; i++) {
      await db.insert('subjects', {
        'id': i,
        'payload': jsonEncode({'id': i}),
      });
      await db.insert('names', {
        'name': i == 1 ? "let'splay" : 'letsplay',
        'subject_id': i,
      });
    }
    await db.close();
    expect(
      (await BangumiOfflineIndex(
        dir,
      ).lookup('Lets Play')).map((r) => r['id']).toSet(),
      {1, 2},
    );
  });
  for (final scenario in [
    'correct',
    'wrong_number',
    'wrong_title',
    'wrong_season',
    'network',
    'conflict',
  ]) {
    test('official episode title: $scenario', () async {
      final token = Metadata.token;
      final key = Metadata.apiKey;
      Metadata.token = 'test';
      Metadata.apiKey = '';
      addTearDown(() {
        Metadata.token = token;
        Metadata.apiKey = key;
      });
      final client = MockClient((request) async {
        Object body = {'results': [], 'data': []};
        final path = request.url.path;
        if (path == '/3/tv/10') {
          body = {
            'id': 10,
            'name': 'Series',
            'first_air_date': '2023-01-01',
            'seasons': [
              {'season_number': 1, 'air_date': '2023-01-01'},
            ],
          };
        } else if (path == '/3/tv/10/season/1') {
          if (scenario == 'network') throw const SocketException('offline');
          body = {
            'season_number': 1,
            'air_date': '2023-01-01',
            'episodes': [
              {
                'episode_number': scenario == 'wrong_number' ? 12 : 11,
                'season_number': scenario == 'wrong_season' ? 2 : 1,
                'show_id': 10,
                'name': scenario == 'wrong_title'
                    ? 'Another title'
                    : 'The Die Is Cast',
              },
            ],
          };
        } else if (scenario == 'conflict' && path.contains('/search/movie')) {
          body = {
            'results': [
              {
                'id': 20,
                'title': 'The Die Is Cast',
                'release_date': '2023-01-01',
              },
            ],
          };
        } else if (path == '/3/movie/20') {
          body = {
            'id': 20,
            'title': 'The Die Is Cast',
            'release_date': '2023-01-01',
          };
        }
        return http.Response(
          jsonEncode(body),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final scraper = PersonalMetadataScraper(client: client);
      addTearDown(() {
        scraper.close();
        client.close();
      });
      final results = await scraper.classify(
        {'title': 'Series (2023) {tmdbtv-10}'},
        [
          {
            'id': 'episode',
            'name': '[WBDP] 11 - The Die Is Cast [BD][1080p-FLAC][HEVC].mkv',
            'category': 'main',
          },
        ],
      );
      expect(results['episode']?.tmdbId, scenario == 'correct' ? 10 : null);
    });
  }
}
