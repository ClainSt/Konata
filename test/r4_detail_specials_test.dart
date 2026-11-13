import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ccplayer/core/cloud_media_asset_presentation.dart';
import 'package:ccplayer/core/detail_metadata.dart';
import 'package:ccplayer/core/episode_metadata.dart';

http.Response _jsonResponse(Object body, {int status = 200}) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Goal 1: Consecutive multi-season expansion & locked cumulative offset', () {
    test(
      '4A: same-year unseasoned 1..50 matching 25+25 clears ambiguity and merges two Bangumi subjects',
      () async {
        final work = <String, Object?>{
          'id': 'work:tablet:multi50',
          'title': 'Dual Cour Show',
          'directory_path': '/Dual Cour Show (2016)',
          'year': 2016,
          'tmdb_id': 1001,
          'tmdb_type': 'tv',
          'bangumi_ids': jsonEncode([2001, 2002]),
        };
        final assets = <Map<String, Object?>>[
          for (var ep = 1; ep <= 50; ep++)
            {
              'category': 'main',
              'season': 1,
              'episode': ep,
              'name': 'Dual Cour Show - ${ep.toString().padLeft(2, '0')}.mkv',
              'relative_path':
                  'Dual Cour Show/${ep.toString().padLeft(2, '0')}.mkv',
            },
        ];

        final client = MockClient((req) async {
          return switch (req.url.path) {
            '/v0/subjects/2001' => _jsonResponse({
              'id': 2001,
              'name_cn': '双季作品 第1期',
              'date': '2016-04-01',
              'eps': 25,
            }),
            '/v0/subjects/2002' => _jsonResponse({
              'id': 2002,
              'name_cn': '双季作品 第2期',
              'date': '2016-10-01',
              'eps': 25,
            }),
            '/v0/episodes' => _jsonResponse({
              'data': [
                for (var ep = 1; ep <= 25; ep++)
                  {
                    'ep': ep,
                    'sort': ep,
                    'name_cn': req.url.queryParameters['subject_id'] == '2001'
                        ? '一期第$ep话'
                        : '二期第$ep话',
                  },
              ],
            }),
            _ => _jsonResponse({}),
          };
        });

        final service = DetailMetadataService(
          client: client,
          tmdbRequest: (path, _) async {
            if (path == '/tv/1001') {
              return {
                'name': 'Dual Cour Show',
                'genres': [
                  {'id': 16},
                ],
                'seasons': [
                  {
                    'season_number': 1,
                    'episode_count': 25,
                    'air_date': '2016-04-01',
                  },
                  {
                    'season_number': 2,
                    'episode_count': 25,
                    'air_date': '2016-10-01',
                  },
                ],
              };
            }
            if (path == '/tv/1001/season/1' || path == '/tv/1001/season/2') {
              final s = path.endsWith('1') ? 1 : 2;
              return {
                'episodes': [
                  for (var ep = 1; ep <= 25; ep++)
                    {
                      'episode_number': ep,
                      'name': '',
                      'overview': 'TMDB S${s}E$ep',
                      'still_path': '/s${s}_e$ep.jpg',
                    },
                ],
              };
            }
            return {};
          },
        );

        final details = await service.fetch(work, assets: assets);
        expect(details['seasonMappingAmbiguous'], isFalse);

        final ep26 = EpisodeMetadata.lookup(work, details, assets[25]);
        expect(ep26['name'], '二期第1话');
        expect(ep26['overview'], 'TMDB S2E1');
        expect(ep26['still'], contains('/s2_e1.jpg'));

        final ep50 = EpisodeMetadata.lookup(work, details, assets[49]);
        expect(ep50['name'], '二期第25话');
        expect(ep50['still'], contains('/s2_e25.jpg'));

        final coords = CloudMediaAssetPresentation.episodeCoordinates(
          {'episode_number': 26, 'name': '26.mkv'},
          details,
        );
        expect(coords, (season: 2, number: 1));
        client.close();
      },
    );

    test(
      '4A: single Bangumi subject follows sequel link automatically for 1..50 span',
      () async {
        final work = <String, Object?>{
          'id': 'work:tablet:split50',
          'title': 'Cross Year Show',
          'tmdb_id': 1002,
          'tmdb_type': 'tv',
          'bangumi_id': 2010,
        };
        final assets = <Map<String, Object?>>[
          for (var ep = 1; ep <= 50; ep++)
            {
              'category': 'main',
              'season': 1,
              'episode': ep,
              'name': '$ep.mkv',
              'relative_path': '$ep.mkv',
            },
        ];

        final client = MockClient((req) async {
          if (req.url.path == '/v0/subjects/2010') {
            return _jsonResponse({'id': 2010, 'date': '2011-04-01', 'eps': 25});
          }
          if (req.url.path == '/v0/subjects/2010/subjects') {
            return _jsonResponse([
              {'id': 2011, 'type': 2, 'relation': '续集'},
            ]);
          }
          if (req.url.path == '/v0/episodes') {
            final sid = req.url.queryParameters['subject_id'];
            return _jsonResponse({
              'data': [
                for (var ep = 1; ep <= 25; ep++)
                  {
                    'ep': ep,
                    'sort': ep,
                    'name_cn': sid == '2010' ? '上篇第$ep话' : '下篇第$ep话',
                  },
              ],
            });
          }
          return _jsonResponse({});
        });

        final service = DetailMetadataService(
          client: client,
          tmdbRequest: (path, _) async {
            if (path == '/tv/1002') {
              return {
                'name': 'Cross Year Show',
                'genres': [
                  {'id': 16},
                ],
                'seasons': [
                  {'season_number': 1, 'episode_count': 25, 'air_date': '2011-04-01'},
                  {'season_number': 2, 'episode_count': 25, 'air_date': '2012-10-01'},
                ],
              };
            }
            if (path == '/tv/1002/season/1' || path == '/tv/1002/season/2') {
              final s = path.endsWith('1') ? 1 : 2;
              return {
                'episodes': [
                  for (var ep = 1; ep <= 25; ep++)
                    {
                      'episode_number': ep,
                      'name': '',
                      'still_path': '/cross_s${s}_e$ep.jpg',
                    },
                ],
              };
            }
            return {};
          },
        );

        final details = await service.fetch(work, assets: assets);
        expect(details['seasonMappingAmbiguous'], isFalse);
        expect(
          ((details['seasonEpisodes'] as Map)['2'] as Map)['1']['name'],
          '下篇第1话',
        );
        expect(
          EpisodeMetadata.lookup(work, details, assets[25])['still'],
          contains('/cross_s2_e1.jpg'),
        );
        client.close();
      },
    );

    test(
      '10: locked Season 4 with cumulative episodes 26..31 maps to Season 4 episodes 1..6',
      () async {
        final work = <String, Object?>{
          'id': 'work:tablet:s4cum',
          'title': 'Long Saga Season 4',
          'directory_path': '/Long Saga Season 4',
          'tmdb_id': 1004,
          'tmdb_type': 'tv',
          'bangumi_id': 2004,
        };
        final assets = <Map<String, Object?>>[
          for (var ep = 26; ep <= 31; ep++)
            {
              'category': 'main',
              'season': 4,
              'episode': ep,
              'name': 'Long Saga - $ep.mkv',
              'relative_path': 'Season 4/Long Saga - $ep.mkv',
            },
        ];

        final client = MockClient((req) async {
          if (req.url.path == '/v0/subjects/2004') {
            return _jsonResponse({'id': 2004, 'date': '2019-10-01', 'eps': 6});
          }
          if (req.url.path == '/v0/episodes') {
            return _jsonResponse({
              'data': [
                for (var ep = 1; ep <= 6; ep++)
                  {'ep': ep, 'sort': 25 + ep, 'name_cn': '第四季第$ep话'},
              ],
            });
          }
          return _jsonResponse({});
        });

        final service = DetailMetadataService(
          client: client,
          tmdbRequest: (path, _) async {
            if (path == '/tv/1004') {
              return {
                'name': 'Long Saga',
                'genres': [
                  {'id': 16},
                ],
                'seasons': [
                  {'season_number': 1, 'episode_count': 13},
                  {'season_number': 2, 'episode_count': 6},
                  {'season_number': 3, 'episode_count': 6},
                  {'season_number': 4, 'episode_count': 6},
                ],
              };
            }
            if (path == '/tv/1004/season/4') {
              return {
                'episodes': [
                  for (var ep = 1; ep <= 6; ep++)
                    {
                      'episode_number': ep,
                      'name': '',
                      'overview': 'S4E$ep overview',
                      'still_path': '/s4_e$ep.jpg',
                    },
                ],
              };
            }
            return {};
          },
        );

        final details = await service.fetch(work, assets: assets);
        expect(details['seasonMappingAmbiguous'], isFalse);

        for (var i = 0; i < 6; i++) {
          final info = EpisodeMetadata.lookup(work, details, assets[i]);
          expect(info['name'], '第四季第${i + 1}话');
          expect(info['still'], contains('/s4_e${i + 1}.jpg'));

          final coords = CloudMediaAssetPresentation.episodeCoordinates(
            assets[i],
            details,
          );
          expect(coords, (season: 4, number: i + 1));
        }
        client.close();
      },
    );
  });

  group('Goal 2: Bangumi recap cross-season date alignment & #00 resolution', () {
    test(
      '2B: aligns Bangumi recap episode 7 (2017-11-20) to Season 0 (2017-11-21) and shifts 8..13 to TMDB 7..12',
      () async {
        final work = <String, Object?>{
          'id': 'work:tablet:recap13',
          'title': 'Broadcast Recap Show',
          'year': 2017,
          'tmdb_id': 3001,
          'tmdb_type': 'tv',
          'bangumi_id': 4001,
        };
        final assets = <Map<String, Object?>>[
          for (var ep = 1; ep <= 13; ep++)
            {
              'category': 'main',
              'season': 1,
              'episode': ep,
              'name': 'Broadcast Recap Show - ${ep.toString().padLeft(2, '0')}.mkv',
              'relative_path':
                  'Show/${ep.toString().padLeft(2, '0')}.mkv',
            },
        ];

        final bgmDates = <String>[
          '2017-10-09', '2017-10-16', '2017-10-23', '2017-10-30',
          '2017-11-06', '2017-11-13',
          '2017-11-20', // Ep 7 recap!
          '2017-11-27', '2017-12-04', '2017-12-11', '2017-12-18',
          '2017-12-25', '2018-01-01',
        ];
        final tmdbRegDates = <String>[
          '2017-10-09', '2017-10-16', '2017-10-23', '2017-10-30',
          '2017-11-06', '2017-11-13',
          '2017-11-27', '2017-12-04', '2017-12-11', '2017-12-18',
          '2017-12-25', '2018-01-01',
        ];

        final client = MockClient((req) async {
          if (req.url.path == '/v0/subjects/4001') {
            return _jsonResponse({'id': 4001, 'date': '2017-10-09', 'eps': 13});
          }
          if (req.url.path == '/v0/episodes') {
            return _jsonResponse({
              'data': [
                for (var i = 0; i < 13; i++)
                  {
                    'ep': i + 1,
                    'sort': i + 1,
                    'name_cn': i == 6 ? '总集篇 特番' : '正片第${i + 1}话',
                    'airdate': bgmDates[i],
                  },
              ],
            });
          }
          return _jsonResponse({});
        });

        final service = DetailMetadataService(
          client: client,
          tmdbRequest: (path, _) async {
            if (path == '/tv/3001') {
              return {
                'name': 'Broadcast Recap Show',
                'genres': [
                  {'id': 16},
                ],
                'seasons': [
                  {'season_number': 0, 'episode_count': 2},
                  {
                    'season_number': 1,
                    'episode_count': 12,
                    'air_date': '2017-10-09',
                  },
                ],
              };
            }
            if (path == '/tv/3001/season/1') {
              return {
                'episodes': [
                  for (var i = 0; i < 12; i++)
                    {
                      'episode_number': i + 1,
                      'name': '',
                      'still_path': '/reg_e${i + 1}.jpg',
                      'air_date': tmdbRegDates[i],
                    },
                ],
              };
            }
            if (path == '/tv/3001/season/0') {
              return {
                'episodes': [
                  {
                    'episode_number': 1,
                    'name': 'Earlier PV',
                    'air_date': '2017-09-15',
                    'still_path': '/s0_1.jpg',
                  },
                  {
                    'episode_number': 2,
                    'name': 'Recap Special',
                    'overview': 'Mid-season recap episode',
                    'air_date': '2017-11-21',
                    'still_path': '/s0_recap_2.jpg',
                  },
                ],
              };
            }
            return {};
          },
        );

        final details = await service.fetch(work, assets: assets);
        final ep6 = EpisodeMetadata.lookup(work, details, assets[5]);
        expect(ep6['name'], '正片第6话');
        expect(ep6['still'], contains('/reg_e6.jpg'));

        final ep7 = EpisodeMetadata.lookup(work, details, assets[6]);
        expect(ep7['name'], '总集篇 特番');
        expect(ep7['special_number'], 2);
        expect(ep7['still'], contains('/s0_recap_2.jpg'));

        final ep8 = EpisodeMetadata.lookup(work, details, assets[7]);
        expect(ep8['name'], '正片第8话');
        expect(ep8['still'], contains('/reg_e7.jpg'));

        final ep13 = EpisodeMetadata.lookup(work, details, assets[12]);
        expect(ep13['name'], '正片第13话');
        expect(ep13['still'], contains('/reg_e12.jpg'));
        client.close();
      },
    );

    test(
      '13A: resolves episode == 0 main assets via Bangumi ep 0 and TMDB Season 0',
      () async {
        final work = <String, Object?>{
          'id': 'work:tablet:epzero',
          'title': 'Prologue Series',
          'year': 2022,
          'tmdb_id': 3002,
          'tmdb_type': 'tv',
          'bangumi_id': 4002,
        };
        final ep0Asset = <String, Object?>{
          'category': 'main',
          'season': 1,
          'episode': 0,
          'name': '[Group] Prologue Series #00 - Before Dawn [1080p].mkv',
          'relative_path': 'Show/#00 - Before Dawn.mkv',
        };
        final ep1Asset = <String, Object?>{
          'category': 'main',
          'season': 1,
          'episode': 1,
          'name': '[Group] Prologue Series #01 [1080p].mkv',
          'relative_path': 'Show/#01.mkv',
        };

        final client = MockClient((req) async {
          if (req.url.path == '/v0/subjects/4002') {
            return _jsonResponse({'id': 4002, 'date': '2022-07-02', 'eps': 12});
          }
          if (req.url.path == '/v0/episodes') {
            if (req.url.queryParameters['type'] == '1') {
              return _jsonResponse({
                'data': [
                  {
                    'ep': 0,
                    'sort': 0,
                    'name': 'Before Dawn',
                    'name_cn': '破晓之前',
                    'airdate': '2022-06-25',
                  },
                ],
              });
            }
            return _jsonResponse({
              'data': [
                {'ep': 1, 'sort': 1, 'name_cn': '第1话 正篇', 'airdate': '2022-07-02'},
              ],
            });
          }
          return _jsonResponse({});
        });

        final service = DetailMetadataService(
          client: client,
          tmdbRequest: (path, _) async {
            if (path == '/tv/3002') {
              return {
                'name': 'Prologue Series',
                'genres': [
                  {'id': 16},
                ],
                'seasons': [
                  {'season_number': 0, 'episode_count': 2},
                  {'season_number': 1, 'episode_count': 12, 'air_date': '2022-07-02'},
                ],
              };
            }
            if (path == '/tv/3002/season/1') {
              return {
                'episodes': [
                  {'episode_number': 1, 'name': '', 'still_path': '/ep1.jpg'},
                ],
              };
            }
            if (path == '/tv/3002/season/0') {
              return {
                'episodes': [
                  {
                    'episode_number': 1,
                    'name': 'PROLOGUE: Before Dawn',
                    'air_date': '2022-06-25',
                    'still_path': '/s0_before_dawn.jpg',
                    'overview': 'Episode 0 special prologue.',
                  },
                  {
                    'episode_number': 2,
                    'name': 'Post-series OVA',
                    'air_date': '2023-03-01',
                    'still_path': '/s0_later.jpg',
                  },
                ],
              };
            }
            return {};
          },
        );

        final details = await service.fetch(work, assets: [ep0Asset, ep1Asset]);
        final zeroInfo = EpisodeMetadata.lookup(work, details, ep0Asset);
        expect(zeroInfo['name'], '破晓之前');
        expect(zeroInfo['name'], isNot('第0集'));
        expect(zeroInfo['still'], contains('/s0_before_dawn.jpg'));
        client.close();
      },
    );
  });

  group('Goal 3: Animation movie still backfill from parent TV Season 0', () {
    test(
      '13B: backfills missing movieStill & backdrop via Bangumi main story relation and air date (±14 days)',
      () async {
        final work = <String, Object?>{
          'id': 'work:tablet:ova_movie',
          'title': 'Parent Series Side OVA',
          'tmdb_id': 5001,
          'tmdb_type': 'movie',
          'bangumi_id': 6001,
        };

        final client = MockClient((req) async {
          if (req.url.path == '/v0/subjects/6001') {
            return _jsonResponse({
              'id': 6001,
              'name_cn': '某系列 番外OVA',
              'date': '2020-05-20',
            });
          }
          if (req.url.path == '/v0/subjects/6001/subjects') {
            return _jsonResponse([
              {'id': 6000, 'type': 2, 'relation': '主线故事', 'name_cn': '某系列TV'},
            ]);
          }
          return _jsonResponse({});
        });

        final service = DetailMetadataService(
          client: client,
          tmdbRequest: (path, params) async {
            if (path == '/movie/5001') {
              return {
                'id': 5001,
                'title': 'Side OVA Feature',
                'genres': [
                  {'id': 16},
                ],
                'release_date': '2020-05-20',
                'backdrop_path': null,
              };
            }
            if (path == '/movie/5001/images') {
              return {'backdrops': []};
            }
            if (path == '/search/tv' && params['query'] == '某系列TV') {
              return {
                'results': [
                  {
                    'id': 5500,
                    'name': '某系列',
                    'genre_ids': [16],
                  },
                ],
              };
            }
            if (path == '/tv/5500/season/0') {
              return {
                'episodes': [
                  {
                    'episode_number': 1,
                    'name': 'Unrelated early special',
                    'air_date': '2018-01-01',
                    'still_path': '/wrong_s0.jpg',
                  },
                  {
                    'episode_number': 2,
                    'name': 'Bonus Special',
                    'air_date': '2020-05-25',
                    'still_path': '/parent_s0_matched.jpg',
                  },
                ],
              };
            }
            return {};
          },
        );

        final details = await service.fetch(work);
        expect(details['movieStill'], contains('/parent_s0_matched.jpg'));
        expect(details['backdrop'], contains('/parent_s0_matched.jpg'));
        client.close();
      },
    );

    test(
      '13B: falls back to title stem search & subtitle similarity when no Bangumi links exist',
      () async {
        final work = <String, Object?>{
          'id': 'work:tablet:ova_movie_stem',
          'title': 'Chronicle: Lost Chapter',
          'tmdb_id': 5002,
          'tmdb_type': 'movie',
        };

        final service = DetailMetadataService(
          client: MockClient((_) async => _jsonResponse({})),
          tmdbRequest: (path, params) async {
            if (path == '/movie/5002') {
              return {
                'id': 5002,
                'title': 'Chronicle: Lost Chapter',
                'genres': [
                  {'id': 16},
                ],
                'backdrop_path': null,
              };
            }
            if (path == '/movie/5002/images') {
              return {'backdrops': []};
            }
            if (path == '/search/tv' &&
                params['query']?.contains('Chronicle') == true) {
              return {
                'results': [
                  {
                    'id': 5502,
                    'name': 'Chronicle',
                    'genre_ids': [16],
                  },
                ],
              };
            }
            if (path == '/tv/5502/season/0') {
              return {
                'episodes': [
                  {
                    'episode_number': 4,
                    'name': 'Lost Chapter',
                    'still_path': '/chronicle_lost_still.jpg',
                  },
                ],
              };
            }
            return {};
          },
        );

        final details = await service.fetch(work);
        expect(details['movieStill'], contains('/chronicle_lost_still.jpg'));
        expect(details['backdrop'], contains('/chronicle_lost_still.jpg'));
      },
    );
  });

  group('Goal 4: Standalone Season 0 per-episode resolution (_resolveMainSpecialAssets)', () {
    test(
      '6B/8A: Extra Stage I/II, Battle Stage I/II, The Way to Project D align via numeral equivalence while Digest avoids wrong still',
      () async {
        final work = <String, Object?>{
          'id': 'work:tablet:extras_stages',
          'title': 'Arcade Drift Stages',
          'year': 2001,
          'tmdb_id': 7001,
          'tmdb_type': 'tv',
        };
        final assets = <Map<String, Object?>>[
          {
            'category': 'main',
            'season': 0,
            'episode': 1,
            'name': 'Extra Stage I.mkv',
            'relative_path': 'Extras/Extra Stage I.mkv',
          },
          {
            'category': 'main',
            'season': 0,
            'episode': 2,
            'name': 'Extra Stage II.mkv',
            'relative_path': 'Extras/Extra Stage II.mkv',
          },
          {
            'category': 'main',
            'season': 0,
            'episode': 3,
            'name': 'Battle Stage I.mkv',
            'relative_path': 'Extras/Battle Stage I.mkv',
          },
          {
            'category': 'main',
            'season': 0,
            'episode': 4,
            'name': 'Battle Stage II.mkv',
            'relative_path': 'Extras/Battle Stage II.mkv',
          },
          {
            'category': 'main',
            'season': 0,
            'episode': 5,
            'name': 'The Way to Project D.mkv',
            'relative_path': 'Extras/The Way to Project D.mkv',
          },
          {
            'category': 'main',
            'season': 0,
            'episode': 6,
            'name': 'Digest.mkv',
            'relative_path': 'Extras/Digest.mkv',
          },
        ];

        final service = DetailMetadataService(
          client: MockClient((_) async => _jsonResponse({})),
          tmdbRequest: (path, _) async {
            if (path == '/tv/7001') {
              return {
                'name': 'Arcade Drift',
                'genres': [
                  {'id': 16},
                ],
                'seasons': [
                  {'season_number': 0, 'episode_count': 7},
                ],
              };
            }
            if (path == '/tv/7001/season/0') {
              return {
                'episodes': [
                  {
                    'episode_number': 1,
                    'name': 'Extra Stage',
                    'air_date': '2001-03-22',
                    'still_path': '/extra1.jpg',
                  },
                  {
                    'episode_number': 2,
                    'name': 'Battle Stage',
                    'air_date': '2002-05-15',
                    'still_path': '/battle1.jpg',
                  },
                  {
                    'episode_number': 3,
                    'name': 'Project D',
                    'air_date': '2004-01-17',
                    'still_path': '/project_d.jpg',
                  },
                  {
                    'episode_number': 4,
                    'name': 'Battle Stage 2',
                    'air_date': '2007-05-30',
                    'still_path': '/battle2.jpg',
                  },
                  {
                    'episode_number': 5,
                    'name': 'Extra Stage 2',
                    'air_date': '2008-12-05',
                    'still_path': '/extra2.jpg',
                  },
                  {
                    'episode_number': 6,
                    'name': 'Unrelated New Stage 3',
                    'air_date': '2001-05-01',
                    'still_path': '/unrelated.jpg',
                  },
                ],
              };
            }
            return {};
          },
        );

        final details = await service.fetch(work, assets: assets);
        expect(
          EpisodeMetadata.lookup(work, details, assets[0])['still'],
          contains('/extra1.jpg'),
        );
        expect(
          EpisodeMetadata.lookup(work, details, assets[1])['still'],
          contains('/extra2.jpg'),
        );
        expect(
          EpisodeMetadata.lookup(work, details, assets[2])['still'],
          contains('/battle1.jpg'),
        );
        expect(
          EpisodeMetadata.lookup(work, details, assets[3])['still'],
          contains('/battle2.jpg'),
        );
        expect(
          EpisodeMetadata.lookup(work, details, assets[4])['still'],
          contains('/project_d.jpg'),
        );
        final digest = EpisodeMetadata.lookup(work, details, assets[5]);
        expect(digest['name'], 'Digest');
        expect(digest['still'], isNull);
      },
    );

    test(
      '12B/17B: aligns 6-episode standalone OVA onto Season 0 range 13..18 and tolerates cross-New-Year release dates',
      () async {
        final work = <String, Object?>{
          'id': 'work:tablet:ova6',
          'title': 'Standalone Six OVA',
          'year': 2013,
          'tmdb_id': 7002,
          'tmdb_type': 'tv',
          'bangumi_id': 8002,
        };
        final assets = <Map<String, Object?>>[
          for (var ep = 1; ep <= 6; ep++)
            {
              'category': 'main',
              'season': 0,
              'episode': ep,
              'name': 'Standalone Six OVA - 0$ep.mkv',
              'relative_path': 'OVA/0$ep.mkv',
            },
        ];

        final client = MockClient((req) async {
          if (req.url.path == '/v0/subjects/8002') {
            return _jsonResponse({'id': 8002, 'date': '2013-08-16', 'eps': 6});
          }
          if (req.url.path == '/v0/episodes') {
            return _jsonResponse({
              'data': [
                {'ep': 1, 'sort': 1, 'name_cn': '新章一', 'airdate': '2013-08-16'},
                {'ep': 2, 'sort': 2, 'name_cn': '新章二', 'airdate': '2013-09-20'},
                {'ep': 3, 'sort': 3, 'name_cn': '新章三', 'airdate': '2013-10-18'},
                {'ep': 4, 'sort': 4, 'name_cn': '新章四', 'airdate': '2013-11-15'},
                {'ep': 5, 'sort': 5, 'name_cn': '新章五', 'airdate': '2013-12-20'},
                // Cross-New-Year: 2013-12-31 vs TMDB 2014-01-25 (diff = 25 <= 45)
                {'ep': 6, 'sort': 6, 'name_cn': '新章六', 'airdate': '2013-12-31'},
              ],
            });
          }
          return _jsonResponse({});
        });

        final service = DetailMetadataService(
          client: client,
          tmdbRequest: (path, _) async {
            if (path == '/tv/7002') {
              return {
                'name': 'Parent Franchise',
                'genres': [
                  {'id': 16},
                ],
                'seasons': [
                  {'season_number': 0, 'episode_count': 18},
                ],
              };
            }
            if (path == '/tv/7002/season/0') {
              return {
                'episodes': [
                  for (var ep = 1; ep <= 12; ep++)
                    {
                      'episode_number': ep,
                      'name': 'Old S0 #$ep',
                      'air_date': '2011-01-01',
                      'still_path': '/old_$ep.jpg',
                    },
                  {
                    'episode_number': 13,
                    'name': 'OVA Ep 1',
                    'air_date': '2013-08-16',
                    'still_path': '/ova_13.jpg',
                  },
                  {
                    'episode_number': 14,
                    'name': 'OVA Ep 2',
                    'air_date': '2013-09-20',
                    'still_path': '/ova_14.jpg',
                  },
                  {
                    'episode_number': 15,
                    'name': 'OVA Ep 3',
                    'air_date': '2013-10-18',
                    'still_path': '/ova_15.jpg',
                  },
                  {
                    'episode_number': 16,
                    'name': 'OVA Ep 4',
                    'air_date': '2013-11-15',
                    'still_path': '/ova_16.jpg',
                  },
                  {
                    'episode_number': 17,
                    'name': 'OVA Ep 5',
                    'air_date': '2013-12-20',
                    'still_path': '/ova_17.jpg',
                  },
                  {
                    'episode_number': 18,
                    'name': 'OVA Ep 6',
                    'air_date': '2014-01-25',
                    'still_path': '/ova_18.jpg',
                  },
                ],
              };
            }
            return {};
          },
        );

        final details = await service.fetch(work, assets: assets);
        for (var i = 0; i < 6; i++) {
          final info = EpisodeMetadata.lookup(work, details, assets[i]);
          expect(info['special_number'], 13 + i);
          expect(info['still'], contains('/ova_${13 + i}.jpg'));
        }
        client.close();
      },
    );
  });

  group('Goal 5: Extras mapSpecialEpisodes multi-signal engine', () {
    test(
      '8B/8C: technical-only trailing brackets after [SP01] preserve SP type and mapping while [Menu] stays MENU',
      () {
        final sp1 = {
          'name': '[VCB-Studio] Show [SP01][Ma10p_1080p][x265_flac].mkv',
          'relative_path':
              'SPs/[VCB-Studio] Show [SP01][Ma10p_1080p][x265_flac].mkv',
          'category': 'extra',
        };
        final sp2 = {
          'name': '[VCB-Studio] Show [SP02][1080p][HEVC_2FLAC][ABCD1234].mkv',
          'relative_path':
              'SPs/[VCB-Studio] Show [SP02][1080p][HEVC_2FLAC][ABCD1234].mkv',
          'category': 'extra',
        };
        final menu = {
          'name': '[Moozzi2] Show [SP03][Menu].mkv',
          'relative_path': 'SPs/[Moozzi2] Show [SP03][Menu].mkv',
          'category': 'extra',
        };

        expect(CloudMediaAssetPresentation.extraType(sp1), 'SP');
        expect(CloudMediaAssetPresentation.explicitSpecialNumber(sp1), 1);
        expect(CloudMediaAssetPresentation.extraType(sp2), 'SP');
        expect(CloudMediaAssetPresentation.explicitSpecialNumber(sp2), 2);
        expect(CloudMediaAssetPresentation.extraType(menu), 'MENU');

        final specials = [
          {'episode_number': 1, 'name': 'SP 1', 'still_path': '/sp1.jpg'},
          {'episode_number': 2, 'name': 'SP 2', 'still_path': '/sp2.jpg'},
        ];
        final mapping = CloudMediaAssetPresentation.mapSpecialEpisodes(
          assets: [sp1, sp2, menu],
          specials: specials,
        );
        expect(mapping[sp1['relative_path']]?['episode_number'], 1);
        expect(mapping[sp2['relative_path']]?['episode_number'], 2);
        expect(mapping.containsKey(menu['relative_path']), isFalse);
      },
    );

    test(
      '14B: separates OVA, OVA SP, and SP subfamilies without pool collision',
      () {
        final assets = <Map<String, Object?>>[
          for (var i = 1; i <= 2; i++)
            {
              'name': 'Show OVA 0$i.mkv',
              'relative_path': 'Bonus/Show OVA 0$i.mkv',
              'category': 'extra',
            },
          for (var i = 1; i <= 2; i++)
            {
              'name': 'Show OVA SP0$i.mkv',
              'relative_path': 'Bonus/Show OVA SP0$i.mkv',
              'category': 'extra',
            },
          for (var i = 1; i <= 6; i++)
            {
              'name': 'Show SP0$i.mkv',
              'relative_path': 'Bonus/Show SP0$i.mkv',
              'category': 'extra',
            },
        ];
        final specials = <Map<String, dynamic>>[
          for (var i = 1; i <= 6; i++)
            {'episode_number': i, 'name': 'SP $i', 'air_date': '2018-06-0$i'},
          {'episode_number': 7, 'name': 'OVA 1', 'air_date': '2018-10-01'},
          {'episode_number': 8, 'name': 'OVA 2', 'air_date': '2018-11-01'},
          {'episode_number': 9, 'name': 'OVA SP 1', 'air_date': '2018-10-01'},
          {'episode_number': 10, 'name': 'OVA SP 2', 'air_date': '2018-11-01'},
        ];

        final mapping = CloudMediaAssetPresentation.mapSpecialEpisodes(
          assets: assets,
          specials: specials,
          yearHint: '2018',
        );
        expect(mapping['Bonus/Show OVA 01.mkv']?['episode_number'], 7);
        expect(mapping['Bonus/Show OVA 02.mkv']?['episode_number'], 8);
        expect(mapping['Bonus/Show OVA SP01.mkv']?['episode_number'], 9);
        expect(mapping['Bonus/Show OVA SP02.mkv']?['episode_number'], 10);
        for (var i = 1; i <= 6; i++) {
          expect(mapping['Bonus/Show SP0$i.mkv']?['episode_number'], i);
        }
      },
    );

    test(
      '15: explicit SP1..2 lock first slots and 03/04 alter-end & Specials shorts map semantically without OP/PV intrusion',
      () {
        final assets = <Map<String, Object?>>[
          {
            'name': '[Group] Show [SP01][1080p].mkv',
            'relative_path': 'SPs/[Group] Show [SP01][1080p].mkv',
            'category': 'extra',
          },
          {
            'name': '[Group] Show [SP02][1080p].mkv',
            'relative_path': 'SPs/[Group] Show [SP02][1080p].mkv',
            'category': 'extra',
          },
          {
            'name': '[Group] Show [03 alter-end][1080p].mkv',
            'relative_path': 'SPs/[Group] Show [03 alter-end][1080p].mkv',
            'category': 'extra',
          },
          {
            'name': '[Group] Show [04 alter-end][1080p].mkv',
            'relative_path': 'SPs/[Group] Show [04 alter-end][1080p].mkv',
            'category': 'extra',
          },
          {
            'name': 'After Story Short.mkv',
            'relative_path': 'Specials/After Story Short.mkv',
            'category': 'extra',
          },
          {
            'name': 'PV01.mkv',
            'relative_path': 'Specials/PV01.mkv',
            'category': 'extra',
          },
          {
            'name': 'NCED1.mkv',
            'relative_path': 'Specials/NCED1.mkv',
            'category': 'extra',
          },
        ];

        expect(
          CloudMediaAssetPresentation.extraType(assets[2]),
          'SP',
        );
        expect(
          CloudMediaAssetPresentation.isSpecialMappingCandidate(assets[2]),
          isTrue,
        );
        expect(
          CloudMediaAssetPresentation.extraType(assets[4]),
          'SP',
        );
        expect(
          CloudMediaAssetPresentation.isSpecialMappingCandidate(assets[5]),
          isFalse,
        );
        expect(
          CloudMediaAssetPresentation.isSpecialMappingCandidate(assets[6]),
          isFalse,
        );

        final specials = <Map<String, dynamic>>[
          {'episode_number': 1, 'name': 'SP 1', 'air_date': '2018-04-01'},
          {'episode_number': 2, 'name': 'SP 2', 'air_date': '2018-05-01'},
          // Deliberately swap ep 4 before ep 3 so clue-based matching is proven.
          {
            'episode_number': 3,
            'name': 'Special 04',
            'overview': 'Episode 04 alternative ending',
            'air_date': '2018-07-01',
          },
          {
            'episode_number': 4,
            'name': 'Special 03',
            'overview': 'Episode 03 alternative ending',
            'air_date': '2018-06-01',
          },
          {
            'episode_number': 5,
            'name': 'After Story Short',
            'air_date': '2018-08-01',
          },
        ];

        final mapping = CloudMediaAssetPresentation.mapSpecialEpisodes(
          assets: assets,
          specials: specials,
          yearHint: 'Show (2018)',
          workTitle: 'Show',
        );
        expect(
          mapping['SPs/[Group] Show [SP01][1080p].mkv']?['episode_number'],
          1,
        );
        expect(
          mapping['SPs/[Group] Show [SP02][1080p].mkv']?['episode_number'],
          2,
        );
        expect(
          mapping['SPs/[Group] Show [03 alter-end][1080p].mkv']?['name'],
          'Special 03',
        );
        expect(
          mapping['SPs/[Group] Show [04 alter-end][1080p].mkv']?['name'],
          'Special 04',
        );
        expect(
          mapping['Specials/After Story Short.mkv']?['episode_number'],
          5,
        );
        expect(mapping.containsKey('Specials/PV01.mkv'), isFalse);
        expect(mapping.containsKey('Specials/NCED1.mkv'), isFalse);

        // Preserve existing Maken-ki OAD preemption when OVA bundle includes explicit OAD + OVA 1..2.
        final oadBundle = [
          {
            'name': 'Hero! [OAD].mkv',
            'relative_path': 'SPs/Hero! [OAD].mkv',
            'category': 'extra',
          },
          {
            'name': 'Hero! [OVA 01].mkv',
            'relative_path': 'SPs/Hero! [OVA 01].mkv',
            'category': 'extra',
          },
          {
            'name': 'Hero! [OVA 02].mkv',
            'relative_path': 'SPs/Hero! [OVA 02].mkv',
            'category': 'extra',
          },
        ];
        final oadSpecials = [
          {'episode_number': 1, 'name': 'OAD Standalone', 'air_date': '2012-03-01'},
          {'episode_number': 2, 'name': 'OVA Ep 1', 'air_date': '2012-06-01'},
          {'episode_number': 3, 'name': 'OVA Ep 2', 'air_date': '2012-07-01'},
        ];
        final oadMap = CloudMediaAssetPresentation.mapSpecialEpisodes(
          assets: oadBundle,
          specials: oadSpecials,
          yearHint: 'Hero! (2012)',
        );
        expect(oadMap['SPs/Hero! [OAD].mkv']?['episode_number'], 1);
        expect(oadMap['SPs/Hero! [OVA 01].mkv']?['episode_number'], 2);
        expect(oadMap['SPs/Hero! [OVA 02].mkv']?['episode_number'], 3);
      },
    );

    test(
      '7: exclusive subtitle tokens allow cross-year OVA match while generic Show [OVA].mkv remains guarded',
      () {
        final spinOff = {
          'name':
              '[Group] Sousei no Aquarion [SP07][Sousei no Aquarion Evol OVA][Ma10p_1080p].mkv',
          'relative_path':
              'SPs/[Group] Sousei no Aquarion [SP07][Sousei no Aquarion Evol OVA][Ma10p_1080p].mkv',
          'category': 'extra',
        };
        final specials = [
          {
            'episode_number': 1,
            'name': 'OVA 1',
            'air_date': '2005-05-01',
          },
          {
            'episode_number': 4,
            'name': 'Sousei no Aquarion Evol OVA',
            'air_date': '2015-06-26',
          },
        ];
        final matched = CloudMediaAssetPresentation.mapSpecialEpisodes(
          assets: [spinOff],
          specials: specials,
          yearHint: 'Sousei no Aquarion (2005) {tmdb-1}',
          workTitle: 'Sousei no Aquarion',
        );
        expect(matched[spinOff['relative_path']]?['episode_number'], 4);

        final genericAsset = {
          'name': 'Show [OVA].mkv',
          'relative_path': 'Show/[OVA].mkv',
          'category': 'extra',
        };
        final blocked = CloudMediaAssetPresentation.mapSpecialEpisodes(
          assets: [genericAsset],
          specials: [
            {'episode_number': 3, 'name': 'Later OVA', 'air_date': '2025-01-01'},
          ],
          yearHint: 'Show (2016) {tmdb-1}',
        );
        expect(blocked, isEmpty);
      },
    );

    test(
      '14B/16/17: shared Season 0 disambiguates season via seasonNumber, seasonName, and overview without cross-season leakage',
      () {
        final assets = [
          {
            'name': 'Show [SP01].mkv',
            'relative_path': 'Season 2/SPs/Show [SP01].mkv',
            'category': 'extra',
          },
          {
            'name': 'Show [SP03].mkv',
            'relative_path': 'Season 2/SPs/Show [SP03].mkv',
            'category': 'extra',
          },
        ];
        final specials = [
          {
            'episode_number': 1,
            'name': 'SP 1',
            'overview': '第1期特典映像 1',
            'air_date': '2016-06-01',
          },
          {
            'episode_number': 2,
            'name': 'SP 2',
            'overview': '第1期特典映像 2',
            'air_date': '2016-07-01',
          },
          {
            'episode_number': 3,
            'name': 'SP 3',
            'overview': '第1期特典映像 3',
            'air_date': '2016-08-01',
          },
          {
            'episode_number': 4,
            'name': 'SP 1',
            'overview': '第2期 Radiant Arc 特典映像 1',
            'air_date': '2018-06-01',
          },
          {
            'episode_number': 5,
            'name': 'SP 2',
            'overview': '第2期 Radiant Arc 特典映像 2',
            'air_date': '2018-07-01',
          },
          {
            'episode_number': 6,
            'name': 'SP 3',
            'overview': '第2期 Radiant Arc 特典映像 3',
            'air_date': '2018-08-01',
          },
        ];

        final mapping = CloudMediaAssetPresentation.mapSpecialEpisodes(
          assets: assets,
          specials: specials,
          workTitle: 'Show Season 2',
          seasonNumber: 2,
          seasonName: 'Radiant Arc',
        );
        expect(
          mapping['Season 2/SPs/Show [SP01].mkv']?['episode_number'],
          4,
        );
        expect(
          mapping['Season 2/SPs/Show [SP03].mkv']?['episode_number'],
          6,
        );
      },
    );
  });
}
