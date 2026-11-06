import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ccplayer/core/detail_metadata.dart';

void main() {
  test(
    'repairs an unlocked single-season title and prefers exact cast subject over a second part',
    () async {
      const title = '86-不存在的战区-';
      final work = {
        'id':
            'work:tablet:${Uri.encodeComponent('$title (2021) {tmdb-100565}')}',
        'title': '$title 第1季',
        'year': 2021,
        'tmdb_id': 100565,
        'tmdb_type': 'tv',
      };
      final client = MockClient((req) async {
        final Object body = switch (req.url.path) {
          '/v0/search/subjects' => {
            'data': [
              {'id': 331887, 'name_cn': '$title 第2部分', 'date': '2021-10-02'},
              {'id': 302189, 'name_cn': '86 -不存在的战区-', 'date': '2021-04-10'},
            ],
          },
          '/v0/subjects/302189' => {'id': 302189, 'date': '2021-04-10'},
          '/v0/subjects/302189/characters' => [
            {'id': 1, 'name': '蕾娜', 'relation': '主角', 'actors': []},
          ],
          _ => <String, dynamic>{},
        };
        return http.Response(
          jsonEncode(body),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });
      final service = DetailMetadataService(
        client: client,
        tmdbRequest: (path, _) async => path == '/tv/100565'
            ? {
                'name': title,
                'genres': [
                  {'id': 16},
                ],
                'seasons': [
                  {'season_number': 0},
                  {'season_number': 1, 'episode_count': 23},
                ],
              }
            : {},
      );
      final repaired = await service.fetch(work);
      expect(repaired['automaticSeriesTitle'], title);
      expect(repaired['automaticBangumiId'], 302189);
      expect((repaired['characters'] as List).single['id'], 1);
      final locked = await service.fetch({...work, 'manual_lock': 1});
      expect(locked.containsKey('automaticSeriesTitle'), isFalse);
      expect(locked.containsKey('automaticBangumiId'), isFalse);
      client.close();
    },
  );
  test(
    'character roster is visible before season and translation requests finish',
    () async {
      final overview = Completer<Map<String, dynamic>?>();
      final translation = Completer<http.Response>();
      final preview = Completer<List<Map<String, dynamic>>>();
      final client = MockClient((request) async {
        if (request.url.path == '/v0/subjects/302189/characters') {
          return http.Response(
            jsonEncode([
              {'id': 1, 'name': 'Lena', 'actors': [], 'relation': '主角'},
            ]),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
        if (request.url.path == '/v0/characters/1') return translation.future;
        return http.Response('{}', 200);
      });
      addTearDown(client.close);
      final service = DetailMetadataService(
        client: client,
        tmdbRequest: (_, _) => overview.future,
      );
      final pending = service.fetch({
        'tmdb_id': 100565,
        'bangumi_id': 302189,
      }, onCharacters: preview.complete);
      expect(
        (await preview.future.timeout(
          const Duration(seconds: 2),
        )).single['name'],
        'Lena',
      );
      translation.complete(
        http.Response.bytes(utf8.encode(jsonEncode({'name_cn': '蕾娜'})), 200),
      );
      overview.complete(null);
      expect(((await pending)['characters'] as List).single['name_cn'], '蕾娜');
    },
  );
  test(
    'Bangumi fallback episode names belong to the directory season',
    () async {
      final client = MockClient((request) async {
        Object data = {};
        if (request.url.path.endsWith('/episodes')) {
          data = {
            'data': [
              {'sort': 1, 'name_cn': '第二季第一话'},
            ],
          };
        } else if (request.url.path.endsWith('/characters')) {
          data = [];
        } else if (request.url.path.endsWith('/subjects/42')) {
          data = {'id': 42, 'name_cn': '动画 第二季', 'tags': []};
        }
        return http.Response(
          jsonEncode(data),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final service = DetailMetadataService(
        client: client,
        tmdbRequest: (_, _) async => null,
      );
      final data = await service.fetch({'title': '动画 第二季', 'bangumi_id': 42});
      expect(
        ((data['seasonEpisodes'] as Map)['2'] as Map)['1']['name'],
        '第二季第一话',
      );
      expect(data['episodes'], isEmpty);
      client.close();
      service.close();
    },
  );
  test('Movie main artwork uses the Personal landscape image pipeline', () async {
    for (final hasBackdrop in [true, false]) {
      final calls = <String>[];
      final service = DetailMetadataService(
        tmdbRequest: (path, params) async {
          calls.add(path);
          if (path == '/movie/123') {
            return {'backdrop_path': hasBackdrop ? '/movie.jpg' : null};
          }
          if (path == '/movie/123/images') {
            expect(params['include_image_language'], 'zh,ja,en,null');
            return {
              'backdrops': [
                {'file_path': '/low.jpg', 'vote_average': 5, 'width': 1920},
                {'file_path': '/small.jpg', 'vote_average': 8, 'width': 1280},
                {'file_path': '/best.jpg', 'vote_average': 8, 'width': 1920},
              ],
            };
          }
          fail('Unexpected request: $path');
        },
      );
      final data = await service.fetch({'tmdb_id': 123, 'tmdb_type': 'movie'});
      expect(data['tags'], isNot(contains('剧场版')));
      expect(
        data['movieStill'],
        'https://images.tmdb.org/t/p/w780/${hasBackdrop ? 'movie' : 'best'}.jpg',
      );
      expect(calls.any((path) => path.contains('/season/')), isFalse);
      expect(calls.contains('/movie/123/images'), !hasBackdrop);
      service.close();
    }
  });

  test('Movie without landscape artwork keeps a neutral placeholder', () async {
    final service = DetailMetadataService(
      tmdbRequest: (path, _) async => path.endsWith('/images')
          ? {'backdrops': []}
          : {'poster_path': '/poster.jpg'},
    );
    final data = await service.fetch({'tmdb_id': 123, 'tmdb_type': 'movie'});
    expect(data['movieStill'], isNull);
    service.close();
  });
  test('principal Bangumi characters precede cameo crossovers', () {
    final entries = <Map<String, dynamic>>[
      {'name': '客串角色A', 'relation': '客串', 'order': 1},
      {'name': '配角', 'relation': '配角', 'order': 1},
      {'name': '主角B', 'relation': '主角', 'order': 2},
      {'name': '其他', 'relation': '其他', 'order': 1},
      {'name': '主角A', 'relation': '主角', 'order': 1},
      {'name': '客串角色B', 'relation': '客串', 'order': 2},
    ];
    final sorted = DetailMetadataService.sortSubjectCharacters(entries);
    expect(sorted.map((e) => e['name']).toList(), [
      '主角A',
      '主角B',
      '配角',
      '客串角色A',
      '客串角色B',
      '其他',
    ]);
  });

  test(
    'Personal-style TMDB episode stills + Bangumi cast and rating merge',
    () async {
      final client = MockClient((request) async {
        final path = request.url.path;
        Object response = <String, dynamic>{};
        if (path.endsWith('/v0/subjects/413741')) {
          response = {
            'rating': {'score': 8.4},
            'tags': [
              {'name': '科幻'},
              {'name': '游戏'},
            ],
            'total_episodes': 13,
            'summary': 'Bangumi summary',
          };
        } else if (path.endsWith('/characters')) {
          response = [
            {
              'id': 10001,
              'name': '秋里乐叶',
              'name_cn': '秋里乐叶',
              'images': {'medium': 'https://example.org/char.jpg'},
              'actors': [
                {'name': '古贺葵'},
              ],
              'type': 1,
            },
          ];
        } else if (path.endsWith('/episodes')) {
          response = {
            'data': [
              {'sort': 1, 'name_cn': 'Bangumi 第1集'},
            ],
          };
        }
        return http.Response(
          jsonEncode(response),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final calls = <String>[];
      final service = DetailMetadataService(
        client: client,
        tmdbRequest: (resource, params) async {
          calls.add(resource);
          if (resource == '/tv/217512') {
            return {
              'vote_average': 6.1,
              'backdrop_path': '/backdrop.jpg',
              'poster_path': '/poster.jpg',
              'number_of_episodes': 13,
              'genres': [
                {'name': '动画'},
              ],
              'overview': 'TMDB 剧情简介',
            };
          }
          if (resource.endsWith('/season/1')) {
            return {
              'episodes': [
                {
                  'episode_number': 1,
                  'name': '第一集',
                  'still_path': '/ep01.jpg',
                  'overview': 'Episode summary',
                },
              ],
            };
          }
          return {'episodes': []};
        },
      );
      try {
        final detail = await service.fetch({
          'tmdb_id': 217512,
          'tmdb_type': 'tv',
          'bangumi_id': 413741,
        });
        expect(detail['score'], 8.4);
        expect(detail['episodeCount'], 13);
        expect(detail['source'], 'TMDB + Bangumi');
        expect(
          detail['backdrop'],
          'https://images.tmdb.org/t/p/original/backdrop.jpg',
        );
        final episodes = detail['episodes'] as Map;
        expect((episodes['1'] as Map)['name'], '第一集');
        expect(
          (episodes['1'] as Map)['still'],
          'https://images.tmdb.org/t/p/w500/ep01.jpg',
        );
        final characters = detail['characters'] as List;
        expect((characters.first as Map)['name'], '秋里乐叶');
        expect(((characters.first as Map)['actors'] as List).single, '古贺葵');
        expect(calls, contains('/tv/217512/season/0'));
      } finally {
        service.close();
      }
    },
  );

  test('Optional TMDB failure does not prevent Bangumi details', () async {
    final client = MockClient((req) async {
      if (req.url.path.endsWith('/characters')) return http.Response('[]', 200);
      if (req.url.path.endsWith('/episodes')) {
        return http.Response('{"data":[]}', 200);
      }
      return http.Response(
        '{"summary":"Only Bangumi","rating":{"score":7.8}}',
        200,
      );
    });
    final service = DetailMetadataService(
      client: client,
      tmdbRequest: (_, _) async => throw StateError('TMDB unavailable'),
    );
    final data = await service.fetch({
      'tmdb_id': 111,
      'tmdb_type': 'tv',
      'bangumi_id': 222,
    });
    expect(data['score'], 7.8);
    expect(data['overview'], 'Only Bangumi');
    expect((data['errors'] as List), contains('TMDB 暂时不可用'));
    service.close();
  });
}
