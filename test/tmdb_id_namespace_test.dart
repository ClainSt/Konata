import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ccplayer/core/metadata.dart';
import 'package:ccplayer/core/personal_scraper.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'untyped IDs require a unique name/year/season identity across namespaces',
    () async {
      final oldToken = Metadata.token, oldMode = Metadata.authMode;
      Metadata.token = 'synthetic';
      Metadata.authMode = 'token';
      addTearDown(() {
        Metadata.token = oldToken;
        Metadata.authMode = oldMode;
      });
      final paths = <String>[];
      var movieFails = false;
      var sameTitle = false;
      PersonalMetadataScraper make() => PersonalMetadataScraper(
        client: MockClient((request) async {
          final path = request.url.path;
          paths.add(path);
          Object? body;
          if (path == '/3/tv/36865') {
            body = {
              'id': 36865,
              'name': sameTitle ? '凉宫春日的消失' : 'Strictly Ice Dancing',
              'first_air_date': '2010-01-01',
            };
          } else if (path == '/3/movie/36865') {
            if (movieFails) return http.Response('{}', 503);
            body = {
              'id': 36865,
              'title': '凉宫春日的消失',
              'release_date': '2010-02-06',
              'alternative_titles': {
                'titles': [
                  {'title': 'The Disappearance of Haruhi Suzumiya'},
                ],
              },
            };
          } else if (path == '/3/tv/42') {
            body = {
              'id': 42,
              'name': 'Series',
              'first_air_date': '2018-01-01',
              'seasons': [
                {'season_number': 1, 'air_date': '2018-01-01'},
                {'season_number': 2, 'air_date': '2020-01-01'},
              ],
            };
          } else if (path == '/3/movie/42') {
            body = {'id': 42, 'title': 'Series', 'release_date': '2018-01-01'};
          } else if (path == '/3/tv/42/season/2') {
            body = {'season_number': 2, 'air_date': '2020-01-01'};
          } else if (request.method == 'POST') {
            body = {'data': []};
          }
          return body == null
              ? http.Response('{}', 404)
              : http.Response(
                  jsonEncode(body),
                  200,
                  headers: {'content-type': 'application/json'},
                );
        }),
      );
      final scraper = make();
      addTearDown(scraper.close);
      final movie = await scraper.scrape({
        'title': '凉宫春日的消失 (2010) {tmdb-36865}',
      });
      expect(movie?.tmdbType, 'movie');
      expect(paths, containsAll(['/3/tv/36865', '/3/movie/36865']));
    expect((await scraper.classify(
      {'title': 'Conflicting folder (2010) {tmdb-42}'},
      [{'id': 'conflict', 'name': '凉宫春日的消失 (2010) {tmdbmovie-36865} - 01.mkv'}],
    ))['conflict'], isNull);
      expect(
        (await scraper.scrape({
          'title': 'The Disappearance of Haruhi Suzumiya (2010) {tmdb-36865}',
        }))?.tmdbType,
        'movie',
      );
      expect(
        await scraper.scrape({'title': '凉宫春日的消失 (2011) {tmdb-36865}'}),
        isNull,
      );
      expect(
        (await scraper.scrape({'title': 'Series (2020) {tmdb-42}'}))?.tmdbType,
        'tv',
      );
      expect(
        await scraper.scrape({'title': 'Series S2 (2018) {tmdb-42}'}),
        isNull,
      );
      sameTitle = true;
      final ambiguous = make();
      addTearDown(ambiguous.close);
      expect(
        await ambiguous.scrape({'title': '凉宫春日的消失 (2010) {tmdb-36865}'}),
        isNull,
      );
      paths.clear();
      expect(
        (await ambiguous.scrape({
          'title': '凉宫春日的消失 (2010) {tmdbmovie-36865}',
        }))?.tmdbType,
        'movie',
      );
      expect(paths.where((p) => p == '/3/tv/36865'), isEmpty);
      movieFails = true;
      final unavailable = make();
      addTearDown(unavailable.close);
      expect(
        await unavailable.scrape({'title': '凉宫春日的消失 (2010) {tmdb-36865}'}),
        isNull,
      );
    },
  );
}
