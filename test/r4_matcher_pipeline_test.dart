import 'dart:convert';
import 'dart:io';

import 'package:ccplayer/core/catalog.dart';
import 'package:ccplayer/core/directory_analyzer.dart';
import 'package:ccplayer/core/metadata.dart';
import 'package:ccplayer/core/scrape_pipeline.dart';
import 'package:ccplayer/core/selected_scan_workflow.dart';
import 'package:ccplayer/core/work_matcher.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

Future<(Directory root, Directory dataDir, Catalog catalog)>
_openTestCatalog(String prefix) async {
  final root = await Directory.systemTemp.createTemp('konata-r4-$prefix-');
  final dataDir = await Directory.systemTemp.createTemp('konata-r4-db-');
  final catalog = Catalog.instance;
  await catalog.initialize(dataDirectory: dataDir);
  addTearDown(() async {
    await catalog.db.close();
    if (await root.exists()) await root.delete(recursive: true);
    if (await dataDir.exists()) await dataDir.delete(recursive: true);
  });
  return (root, dataDir, catalog);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late String savedToken, savedKey, savedMode;
  setUp(() {
    savedToken = Metadata.token;
    savedKey = Metadata.apiKey;
    savedMode = Metadata.authMode;
    Metadata.token = 'test-token';
    Metadata.apiKey = '';
    Metadata.authMode = 'token';
  });
  tearDown(() {
    Metadata.token = savedToken;
    Metadata.apiKey = savedKey;
    Metadata.authMode = savedMode;
  });

  group('作品标题纯净原则', () {
    test(
      '单季/普通S2不自动追加第x季，专名季优先采用且统一写 assets.season',
      () async {
        final (root, _, catalog) = await _openTestCatalog('pure-titles');

        final s1Dir = await Directory('${root.path}/星穹物语').create();
        final s2GenericDir =
            await Directory('${root.path}/星穹物语 Season 2').create();
        final s3NamedDir =
            await Directory('${root.path}/苍穹编年史 第2季').create();
        for (var i = 1; i <= 4; i++) {
          final ep = i.toString().padLeft(2, '0');
          await File('${s1Dir.path}/[$ep].mkv').writeAsBytes([i]);
          await File('${s2GenericDir.path}/[$ep].mkv').writeAsBytes([i]);
          await File('${s3NamedDir.path}/[$ep].mkv').writeAsBytes([i]);
        }

        final client = MockClient((req) async {
          final path = req.url.path;
          if (path == '/v0/search/subjects') {
            final kw = (jsonDecode(req.body) as Map)['keyword'].toString();
            if (kw.contains('苍穹编年史')) {
              return _json({
                'data': [
                  {
                    'id': 88002,
                    'name': '蒼穹クロニクル 黎明編',
                    'name_cn': '苍穹编年史 黎明篇',
                    'date': '2022-04-01',
                    'total_episodes': 4,
                  },
                ],
              });
            }
            return _json({
              'data': [
                {
                  'id': 88001,
                  'name': '星穹物语',
                  'name_cn': '星穹物语',
                  'date': '2020-01-10',
                  'total_episodes': 4,
                },
              ],
            });
          }
          if (path == '/v0/subjects/88001') {
            return _json({
              'id': 88001,
              'name': '星穹物语',
              'name_cn': '星穹物语',
              'date': '2020-01-10',
              'total_episodes': 4,
              'images': {'large': 'https://lain.bgm.tv/star-s1.jpg'},
            });
          }
          if (path == '/v0/subjects/88002') {
            return _json({
              'id': 88002,
              'name': '蒼穹クロニクル 黎明編',
              'name_cn': '苍穹编年史 黎明篇',
              'date': '2022-04-01',
              'total_episodes': 4,
              'images': {'large': 'https://lain.bgm.tv/sky-s2.jpg'},
            });
          }
          if (path == '/3/search/tv') {
            final q = req.url.queryParameters['query'] ?? '';
            if (q.contains('苍穹') || q.contains('蒼穹')) {
              return _json({
                'results': [
                  {
                    'id': 77002,
                    'name': '苍穹编年史',
                    'first_air_date': '2020-04-01',
                  },
                ],
              });
            }
            return _json({
              'results': [
                {
                  'id': 77001,
                  'name': '星穹物语',
                  'first_air_date': '2020-01-10',
                },
              ],
            });
          }
          if (path == '/3/tv/77001') {
            return _json({
              'id': 77001,
              'name': '星穹物语',
              'first_air_date': '2020-01-10',
              'poster_path': '/star-series.jpg',
              'seasons': [
                {
                  'season_number': 1,
                  'name': 'Season 1',
                  'episode_count': 4,
                  'air_date': '2020-01-10',
                },
                {
                  'season_number': 2,
                  'name': 'Season 2',
                  'episode_count': 4,
                  'air_date': '2021-07-05',
                },
              ],
            });
          }
          if (path == '/3/tv/77001/season/1') {
            return _json({'season_number': 1, 'poster_path': '/star-s1.jpg'});
          }
          if (path == '/3/tv/77001/season/2') {
            return _json({
              'season_number': 2,
              'name': 'Season 2',
              'poster_path': '/star-s2.jpg',
            });
          }
          if (path == '/3/tv/77002') {
            return _json({
              'id': 77002,
              'name': '苍穹编年史',
              'first_air_date': '2020-04-01',
              'poster_path': '/sky-series.jpg',
              'seasons': [
                {
                  'season_number': 1,
                  'name': 'Season 1',
                  'episode_count': 12,
                  'air_date': '2020-04-01',
                },
                {
                  'season_number': 2,
                  'name': '黎明篇',
                  'episode_count': 4,
                  'air_date': '2022-04-01',
                },
              ],
            });
          }
          if (path == '/3/tv/77002/season/2') {
            return _json({
              'season_number': 2,
              'name': '黎明篇',
              'poster_path': '/sky-s2.jpg',
            });
          }
          return _json({}, 404);
        });

        final sourceId = await catalog.addSource('local', '纯净标题库', root.path);
        await catalog.addScanRoot(sourceId, '');
        await SelectedScanWorkflow.run(
          catalog.sourceOf(sourceId),
          pipeline: ScrapePipeline(catalog: catalog, client: client),
        );

        final starWorks = catalog.works
            .where((w) => w['tmdb_id'] == 77001)
            .toList();
        expect(starWorks, hasLength(2));
        for (final w in starWorks) {
          expect(w['title'], '星穹物语');
          expect(w['title'].toString(), isNot(contains('第1季')));
          expect(w['title'].toString(), isNot(contains('第2季')));
        }
        final starSeasons = {
          for (final w in starWorks)
            catalog.forWork(w['id'].toString()).first['season'] as int,
        };
        expect(starSeasons, {1, 2});

        final skyWork = catalog.works.singleWhere(
          (w) => w['tmdb_id'] == 77002,
        );
        expect(skyWork['title'], '苍穹编年史 黎明篇');
        expect(skyWork['title'].toString(), isNot(contains('第2季')));
        expect(
          catalog.forWork(skyWork['id'].toString()).every((a) => a['season'] == 2),
          isTrue,
        );
      },
    );
  });

  group('分层词干召回、404 安全降级、混装拆分与 HD 重制版', () {
    test(
      'Wave 2 衍生词干（fileHints / 父目录去系列 / 前导修饰词与副标题剥离）召回父 TV',
      () async {
        final (root, _, catalog) = await _openTestCatalog('stem-recall');
        final seriesParent =
            await Directory('${root.path}/星海战记 作品集').create();
        final arcDir = await Directory(
          '${seriesParent.path}/续 星海战记·终焉回响 (2018)',
        ).create();
        for (var i = 1; i <= 6; i++) {
          final ep = i.toString().padLeft(2, '0');
          await File(
            '${arcDir.path}/[Sub] Hoshi no Umi Senki - $ep [1080p].mkv',
          ).writeAsBytes([i]);
        }

        final seenTmdbQueries = <String>[];
        final client = MockClient((req) async {
          final path = req.url.path;
          if (path == '/v0/search/subjects') {
            return _json({'data': []});
          }
          if (path == '/3/search/tv') {
            final q = req.url.queryParameters['query'] ?? '';
            seenTmdbQueries.add(q);
            // Wave 1 full modified title returns empty; Wave 2 stems rescue it.
            if (q == '星海战记' || q == 'Hoshi no Umi Senki') {
              return _json({
                'results': [
                  {
                    'id': 66001,
                    'name': '星海战记',
                    'original_name': 'Hoshi no Umi Senki',
                    'first_air_date': '2018-04-01',
                  },
                ],
              });
            }
            return _json({'results': []});
          }
          if (path == '/3/tv/66001') {
            return _json({
              'id': 66001,
              'name': '星海战记',
              'original_name': 'Hoshi no Umi Senki',
              'first_air_date': '2018-04-01',
              'poster_path': '/hoshi.jpg',
              'seasons': [
                {
                  'season_number': 1,
                  'episode_count': 6,
                  'air_date': '2018-04-01',
                },
              ],
            });
          }
          if (path == '/3/tv/66001/season/1') {
            return _json({'season_number': 1, 'poster_path': '/hoshi-s1.jpg'});
          }
          return _json({}, 404);
        });

        final sourceId = await catalog.addSource('local', '词干召回库', root.path);
        await catalog.addScanRoot(sourceId, '');
        await SelectedScanWorkflow.run(
          catalog.sourceOf(sourceId),
          pipeline: ScrapePipeline(catalog: catalog, client: client),
        );

        expect(seenTmdbQueries, contains('星海战记'));
        final work = catalog.works.singleWhere(
          (w) => w['tmdb_id'] == 66001,
        );
        expect(work['title'], '星海战记');
        expect(work['needs_review'], 0);
      },
    );

    test('{tmdb-N} 404 安全降级走常规搜索绑定正确作品，不报错留空', () async {
      final (root, _, catalog) = await _openTestCatalog('tmdb-404-fallback');
      final dir = await Directory(
        '${root.path}/幻想旅途 (2021) {tmdb-999999}',
      ).create();
      for (var i = 1; i <= 4; i++) {
        await File('${dir.path}/0$i.mkv').writeAsBytes([i]);
      }

      final client = MockClient((req) async {
        final path = req.url.path;
        if (path == '/3/tv/999999' || path == '/3/movie/999999') {
          return _json({'status_code': 34}, 404);
        }
        if (path == '/v0/search/subjects') {
          return _json({
            'data': [
              {
                'id': 33001,
                'name': '幻想旅途',
                'name_cn': '幻想旅途',
                'date': '2021-01-05',
                'total_episodes': 4,
              },
            ],
          });
        }
        if (path == '/v0/subjects/33001') {
          return _json({
            'id': 33001,
            'name': '幻想旅途',
            'name_cn': '幻想旅途',
            'date': '2021-01-05',
            'total_episodes': 4,
            'images': {'large': 'https://lain.bgm.tv/fantasy.jpg'},
          });
        }
        if (path == '/3/search/tv') {
          return _json({
            'results': [
              {
                'id': 55001,
                'name': '幻想旅途',
                'first_air_date': '2021-01-05',
              },
            ],
          });
        }
        if (path == '/3/tv/55001') {
          return _json({
            'id': 55001,
            'name': '幻想旅途',
            'first_air_date': '2021-01-05',
            'poster_path': '/fantasy.jpg',
            'seasons': [
              {
                'season_number': 1,
                'episode_count': 4,
                'air_date': '2021-01-05',
              },
            ],
          });
        }
        if (path == '/3/tv/55001/season/1') {
          return _json({'season_number': 1, 'poster_path': '/fantasy-s1.jpg'});
        }
        return _json({}, 404);
      });

      final sourceId = await catalog.addSource('local', '404降级库', root.path);
      await catalog.addScanRoot(sourceId, '');
      await SelectedScanWorkflow.run(
        catalog.sourceOf(sourceId),
        pipeline: ScrapePipeline(catalog: catalog, client: client),
      );

      final work = catalog.works.single;
      expect(work['tmdb_id'], 55001);
      expect(work['bangumi_id'], 33001);
      expect(work['needs_review'], 0);
      expect(work['poster'], 'https://image.tmdb.org/t/p/w500/fantasy-s1.jpg');
    });

    test(
      '携带 {tmdb-N} 的 TV 目录混装独立剧场版时允许进入多作品拆分流程',
      () async {
        final (root, _, catalog) = await _openTestCatalog('tmdb-mixed-split');
        final mixed = await Directory('${root.path}/星辉战记 {tmdb-500}').create();
        final s1 = await Directory('${mixed.path}/Season 1').create();
        for (var i = 1; i <= 4; i++) {
          await File('${s1.path}/[Group] 星辉战记 - 0$i.mkv').writeAsBytes([i]);
        }
        await File('${mixed.path}/剧场版 星辉战记 终章 [BDRip].mkv').writeAsBytes([
          99,
        ]);

        final client = MockClient((req) async {
          final path = req.url.path;
          if (path == '/v0/search/subjects') {
            final kw = (jsonDecode(req.body) as Map)['keyword'].toString();
            if (kw.contains('终章') || kw.contains('剧场版')) {
              return _json({
                'data': [
                  {
                    'id': 5010,
                    'name': '星辉战记 终章',
                    'name_cn': '剧场版 星辉战记 终章',
                    'date': '2022-08-12',
                    'total_episodes': 1,
                  },
                ],
              });
            }
            return _json({
              'data': [
                {
                  'id': 5000,
                  'name': '星辉战记',
                  'name_cn': '星辉战记',
                  'date': '2020-04-01',
                  'total_episodes': 4,
                },
              ],
            });
          }
          if (path == '/v0/subjects/5000') {
            return _json({
              'id': 5000,
              'name': '星辉战记',
              'name_cn': '星辉战记',
              'date': '2020-04-01',
              'total_episodes': 4,
              'images': {'large': 'https://lain.bgm.tv/star-tv.jpg'},
            });
          }
          if (path == '/v0/subjects/5010') {
            return _json({
              'id': 5010,
              'name': '剧场版 星辉战记 终章',
              'name_cn': '剧场版 星辉战记 终章',
              'date': '2022-08-12',
              'total_episodes': 1,
              'images': {'large': 'https://lain.bgm.tv/star-movie.jpg'},
            });
          }
          if (path == '/3/search/tv') {
            return _json({
              'results': [
                {'id': 500, 'name': '星辉战记', 'first_air_date': '2020-04-01'},
              ],
            });
          }
          if (path == '/3/search/movie') {
            return _json({
              'results': [
                {
                  'id': 501,
                  'title': '剧场版 星辉战记 终章',
                  'release_date': '2022-08-12',
                },
              ],
            });
          }
          if (path == '/3/tv/500') {
            return _json({
              'id': 500,
              'name': '星辉战记',
              'first_air_date': '2020-04-01',
              'poster_path': '/tv500.jpg',
              'seasons': [
                {
                  'season_number': 1,
                  'episode_count': 4,
                  'air_date': '2020-04-01',
                },
              ],
            });
          }
          if (path == '/3/tv/500/season/1') {
            return _json({'season_number': 1, 'poster_path': '/tv500-s1.jpg'});
          }
          if (path == '/3/movie/501') {
            return _json({
              'id': 501,
              'title': '剧场版 星辉战记 终章',
              'release_date': '2022-08-12',
              'poster_path': '/movie501.jpg',
            });
          }
          return _json({}, 404);
        });

        final sourceId = await catalog.addSource('local', '混装拆分库', root.path);
        await catalog.addScanRoot(sourceId, '');
        await SelectedScanWorkflow.run(
          catalog.sourceOf(sourceId),
          pipeline: ScrapePipeline(catalog: catalog, client: client),
        );

        expect(catalog.works, hasLength(2));
        final tvWork = catalog.works.singleWhere(
          (w) => w['tmdb_type'] == 'tv' && w['tmdb_id'] == 500,
        );
        final movieWork = catalog.works.singleWhere(
          (w) => w['tmdb_type'] == 'movie' && w['tmdb_id'] == 501,
        );
        expect(tvWork['title'], '星辉战记');
        expect(movieWork['title'], '剧场版 星辉战记 终章');
      },
    );

    test(
      'HD 重制版优先绑定 Bangumi 重制版条目并关联 TMDB 原版 TV（豁免年代差惩罚）',
      () async {
        final (root, _, catalog) = await _openTestCatalog('hd-remaster');
        final dir =
            await Directory('${root.path}/苍蓝传说 HD重制版 (2011)').create();
        for (var i = 1; i <= 48; i++) {
          final ep = i.toString().padLeft(2, '0');
          await File('${dir.path}/$ep.mkv').writeAsBytes([i]);
        }

        final client = MockClient((req) async {
          final path = req.url.path;
          if (path == '/v0/search/subjects') {
            return _json({
              'data': [
                {
                  'id': 19950,
                  'name': '苍蓝传说',
                  'name_cn': '苍蓝传说',
                  'date': '1995-04-07',
                  'total_episodes': 50,
                },
                {
                  'id': 20110,
                  'name': '苍蓝传说 HDリマスター',
                  'name_cn': '苍蓝传说 HD重制版',
                  'date': '2011-10-01',
                  'total_episodes': 48,
                },
              ],
            });
          }
          if (path == '/v0/subjects/20110') {
            return _json({
              'id': 20110,
              'name': '苍蓝传说 HDリマスター',
              'name_cn': '苍蓝传说 HD重制版',
              'date': '2011-10-01',
              'total_episodes': 48,
              'images': {'large': 'https://lain.bgm.tv/remaster-2011.jpg'},
            });
          }
          if (path == '/v0/subjects/19950') {
            return _json({
              'id': 19950,
              'name': '苍蓝传说',
              'name_cn': '苍蓝传说',
              'date': '1995-04-07',
              'total_episodes': 50,
              'images': {'large': 'https://lain.bgm.tv/orig-1995.jpg'},
            });
          }
          if (path == '/3/search/tv') {
            final q = req.url.queryParameters['query'] ?? '';
            if (q == '苍蓝传说') {
              return _json({
                'results': [
                  {
                    'id': 1995,
                    'name': '苍蓝传说',
                    'first_air_date': '1995-04-07',
                  },
                ],
              });
            }
            return _json({'results': []});
          }
          if (path == '/3/tv/1995') {
            return _json({
              'id': 1995,
              'name': '苍蓝传说',
              'first_air_date': '1995-04-07',
              'poster_path': '/orig-1995.jpg',
              'seasons': [
                {
                  'season_number': 1,
                  'name': 'Season 1',
                  'episode_count': 50,
                  'air_date': '1995-04-07',
                },
              ],
            });
          }
          return _json({}, 404);
        });

        final sourceId = await catalog.addSource('local', '重制版库', root.path);
        await catalog.addScanRoot(sourceId, '');
        await SelectedScanWorkflow.run(
          catalog.sourceOf(sourceId),
          pipeline: ScrapePipeline(catalog: catalog, client: client),
        );

        final work = catalog.works.single;
        expect(work['bangumi_id'], 20110);
        expect(work['tmdb_id'], 1995);
        expect(work['title'], '苍蓝传说 HD重制版');
        expect(work['year'], 2011);
        expect(work['needs_review'], 0);
        expect(
          Catalog.preferredPoster(work),
          'https://lain.bgm.tv/remaster-2011.jpg',
        );
      },
    );
  });

  group('四维季级精准消歧与 SeasonInfo 兼容', () {
    test('SeasonInfo 构造与 MatchCandidate.fromJson 兼容新旧格式', () {
      const legacy = SeasonInfo(1, 12, 2020);
      expect(legacy.name, isNull);
      expect(legacy.airDate, isNull);

      const extended = SeasonInfo(
        2,
        12,
        2021,
        name: '暗影篇',
        airDate: '2021-04-01',
      );
      expect(extended.name, '暗影篇');
      expect(extended.airDate, '2021-04-01');

      final candidate = MatchCandidate.fromJson('tmdb', {
        'id': 42,
        'type': 'tv',
        'title': '星影物语',
        'year': 2020,
        'airDate': '2020-01-10',
        'isSpecialFormat': true,
        'seasons': [
          [1, 12, 2020],
          [2, 12, 2021, '暗影篇', '2021-04-01'],
          {
            'season': 3,
            'count': 6,
            'year': 2022,
            'name': '终篇',
            'airDate': '2022-10-01',
          },
        ],
      });
      expect(candidate.airDate, '2020-01-10');
      expect(candidate.isSpecialFormat, isTrue);
      expect(candidate.seasons, hasLength(3));
      expect(candidate.seasons[0].name, isNull);
      expect(candidate.seasons[1].name, '暗影篇');
      expect(candidate.seasons[1].airDate, '2021-04-01');
      expect(candidate.seasons[2].number, 3);
      expect(candidate.seasons[2].name, '终篇');
    });

    test('SeasonInfo.name 匹配锁定季并豁免副标题冲突惩罚，显式 {tmdb-N} 年份+集数吻合亦豁免', () {
      final invByName = DirectoryInventory.synthetic(
        folder: '星影物语 暗影篇',
        shape: WorkShape.series,
        title: '星影物语 暗影篇',
        titleHints: const ['星影物语 暗影篇'],
        main: [
          for (var i = 1; i <= 12; i++) LogicalItem('ep', '星影物语', i, null),
        ],
      );
      const tmdbParent = MatchCandidate(
        provider: 'tmdb',
        id: 1001,
        type: 'tv',
        title: '星影物语',
        year: 2020,
        seasons: [
          SeasonInfo(1, 12, 2020, name: '序章', airDate: '2020-01-10'),
          SeasonInfo(2, 12, 2021, name: '暗影篇', airDate: '2021-04-01'),
        ],
      );
      final nameRes = WorkMatcher.tmdb(invByName, [tmdbParent]);
      expect(nameRes.season, 2);
      expect(nameRes.tier, MatchTier.high);
      expect(
        nameRes.ranking.first.reasons.where(
          (r) => r.contains('conflicting subtitle'),
        ),
        isEmpty,
      );

      // 显式 {tmdb-N} 目录下，虽有本地修饰副标题但某季年份+集数完全吻合时豁免副标题冲突惩罚
      final invExplicit = DirectoryInventory.synthetic(
        folder: '星影物语 特别编年 {tmdb-1001} (2021)',
        shape: WorkShape.series,
        title: '星影物语 特别编年',
        titleHints: const ['星影物语 特别编年'],
        year: 2021,
        tmdbId: 1001,
        tmdbType: 'tv',
        main: [
          for (var i = 1; i <= 12; i++) LogicalItem('ep', '星影物语', i, null),
        ],
      );
      final expRes = WorkMatcher.tmdb(invExplicit, [tmdbParent]);
      expect(expRes.season, 2);
      expect(expRes.tier, MatchTier.high);
      expect(
        expRes.ranking.first.reasons.where(
          (r) => r.contains('conflicting subtitle'),
        ),
        isEmpty,
      );
    });

    test(
      '同年多季经 Bangumi airDate (<=35天) 与 SeasonInfo.name 消歧落库 assets.season 1/2',
      () async {
        final (root, _, catalog) = await _openTestCatalog('same-year-seasons');
        final s1Dir = await Directory('${root.path}/幻境双姝 春之章').create();
        final s2Dir = await Directory('${root.path}/幻境双姝 秋之章').create();
        for (var i = 1; i <= 12; i++) {
          final ep = i.toString().padLeft(2, '0');
          await File('${s1Dir.path}/$ep.mkv').writeAsBytes([i]);
          await File('${s2Dir.path}/$ep.mkv').writeAsBytes([i]);
        }

        final client = MockClient((req) async {
          final path = req.url.path;
          if (path == '/v0/search/subjects') {
            final kw = (jsonDecode(req.body) as Map)['keyword'].toString();
            if (kw.contains('秋之章')) {
              return _json({
                'data': [
                  {
                    'id': 20902,
                    'name': '幻境双姝 秋之章',
                    'name_cn': '幻境双姝 秋之章',
                    'date': '2009-09-25',
                    'total_episodes': 12,
                  },
                ],
              });
            }
            return _json({
              'data': [
                {
                  'id': 20901,
                  'name': '幻境双姝 春之章',
                  'name_cn': '幻境双姝 春之章',
                  'date': '2009-04-03',
                  'total_episodes': 12,
                },
              ],
            });
          }
          if (path == '/v0/subjects/20901') {
            return _json({
              'id': 20901,
              'name': '幻境双姝 春之章',
              'name_cn': '幻境双姝 春之章',
              'date': '2009-04-03',
              'total_episodes': 12,
              'images': {'large': 'https://lain.bgm.tv/spring.jpg'},
            });
          }
          if (path == '/v0/subjects/20902') {
            return _json({
              'id': 20902,
              'name': '幻境双姝 秋之章',
              'name_cn': '幻境双姝 秋之章',
              'date': '2009-09-25',
              'total_episodes': 12,
              'images': {'large': 'https://lain.bgm.tv/autumn.jpg'},
            });
          }
          if (path == '/3/search/tv') {
            return _json({
              'results': [
                {
                  'id': 20090,
                  'name': '幻境双姝',
                  'first_air_date': '2009-04-02',
                },
              ],
            });
          }
          if (path == '/3/tv/20090') {
            return _json({
              'id': 20090,
              'name': '幻境双姝',
              'first_air_date': '2009-04-02',
              'poster_path': '/dual-series.jpg',
              'seasons': [
                {
                  'season_number': 1,
                  'name': '春之章',
                  'episode_count': 12,
                  'air_date': '2009-04-02',
                },
                {
                  'season_number': 2,
                  'name': '秋之章',
                  'episode_count': 12,
                  'air_date': '2009-09-24',
                },
              ],
            });
          }
          if (path == '/3/tv/20090/season/1') {
            return _json({
              'season_number': 1,
              'name': '春之章',
              'poster_path': '/spring-s1.jpg',
            });
          }
          if (path == '/3/tv/20090/season/2') {
            return _json({
              'season_number': 2,
              'name': '秋之章',
              'poster_path': '/autumn-s2.jpg',
            });
          }
          return _json({}, 404);
        });

        final sourceId = await catalog.addSource('local', '同年双季库', root.path);
        await catalog.addScanRoot(sourceId, '');
        await SelectedScanWorkflow.run(
          catalog.sourceOf(sourceId),
          pipeline: ScrapePipeline(catalog: catalog, client: client),
        );

        final s1 = catalog.works.singleWhere((w) => w['bangumi_id'] == 20901);
        final s2 = catalog.works.singleWhere((w) => w['bangumi_id'] == 20902);
        expect(s1['tmdb_id'], 20090);
        expect(s2['tmdb_id'], 20090);
        expect(
          catalog.forWork(s1['id'].toString()).every((a) => a['season'] == 1),
          isTrue,
        );
        expect(
          catalog.forWork(s2['id'].toString()).every((a) => a['season'] == 2),
          isTrue,
        );
      },
    );

    test('累计集数偏移区间 26..31 锁定第 4 季且惩罚单季残缺条目，连续多季 1..50 展开加分', () async {
      // 1. 偏移区间 26..31（前3季 13+6+6=25，第4季 6 集）vs 单季6集残缺条目
      final invOffset = DirectoryInventory.synthetic(
        folder: '暮夜战记 (2022)',
        shape: WorkShape.series,
        title: '暮夜战记',
        titleHints: const ['暮夜战记'],
        year: 2022,
        main: [
          for (var ep = 26; ep <= 31; ep++)
            LogicalItem('ep', '暮夜战记', ep, null),
        ],
      );
      const multiSeasonParent = MatchCandidate(
        provider: 'tmdb',
        id: 3001,
        type: 'tv',
        title: '暮夜战记',
        year: 2019,
        seasons: [
          SeasonInfo(1, 13, 2019),
          SeasonInfo(2, 6, 2020),
          SeasonInfo(3, 6, 2021),
          SeasonInfo(4, 6, 2022),
        ],
      );
      const truncatedSingle = MatchCandidate(
        provider: 'tmdb',
        id: 3002,
        type: 'tv',
        title: '暮夜战记',
        year: 2022,
        seasons: [SeasonInfo(1, 6, 2022)],
      );

      final offsetMatch = WorkMatcher.tmdb(invOffset, [
        truncatedSingle,
        multiSeasonParent,
      ]);
      expect(offsetMatch.tier, MatchTier.high);
      expect(offsetMatch.candidate?.id, 3001);
      expect(offsetMatch.season, 4);
      expect(
        offsetMatch.ranking.last.reasons.any(
          (r) => r.contains('incomplete season vs offset'),
        ),
        isTrue,
      );

      // 2. 连续多季展开：1..50 == S1(25) + S2(25)
      final invMultiCour = DirectoryInventory.synthetic(
        folder: '星轨长篇 (2018)',
        shape: WorkShape.series,
        title: '星轨长篇',
        titleHints: const ['星轨长篇'],
        year: 2018,
        main: [
          for (var ep = 1; ep <= 50; ep++) LogicalItem('ep', '星轨长篇', ep, null),
        ],
      );
      const tmdbThreeSeasons = MatchCandidate(
        provider: 'tmdb',
        id: 4001,
        type: 'tv',
        title: '星轨长篇',
        year: 2018,
        seasons: [
          SeasonInfo(1, 25, 2018),
          SeasonInfo(2, 25, 2019),
          SeasonInfo(3, 12, 2021),
        ],
      );
      final multiCourMatch = WorkMatcher.tmdb(invMultiCour, [tmdbThreeSeasons]);
      expect(multiCourMatch.tier, MatchTier.high);
      expect(multiCourMatch.season, isNull);
      expect(
        multiCourMatch.ranking.first.reasons.any(
          (r) => r.contains('all seasons count'),
        ),
        isTrue,
      );
    });

    test('独立 6 集 OVA（放宽 <=12 集）与 Extras 特别篇目录匹配父 TV 落库 season=0', () async {
      // 1. 单元级校验：纯 Extras 特别篇目录 (inventory.season == 0) 精确匹配父 TV Season 0
      final invExtras = DirectoryInventory.synthetic(
        folder: '星海恋歌物语 Extras',
        shape: WorkShape.series,
        title: '星海恋歌物语',
        titleHints: const ['星海恋歌物语'],
        year: 2019,
        season: 0,
        main: [
          for (var ep = 1; ep <= 4; ep++) LogicalItem('ep', '星海恋歌物语', ep, 0),
        ],
      );
      const tmdbLove = MatchCandidate(
        provider: 'tmdb',
        id: 61000,
        type: 'tv',
        title: '星海恋歌物语',
        year: 2019,
        seasons: [
          SeasonInfo(0, 10, 2019, name: '特别篇', airDate: '2019-05-01'),
          SeasonInfo(1, 24, 2019, name: 'Season 1', airDate: '2019-04-05'),
        ],
      );
      final extrasUnit = WorkMatcher.tmdb(invExtras, [tmdbLove]);
      expect(extrasUnit.tier, MatchTier.high);
      expect(extrasUnit.season, 0);

      // 2. 端到端校验：独立 6 集 OVA (放宽 <=12 集) + Season 0 特别篇目录落库 assets.season == 0
      final (root, _, catalog) = await _openTestCatalog('ova-season0');
      final ovaDir =
          await Directory('${root.path}/星海恋歌物语 OVA 特别篇').create();
      final extrasDir =
          await Directory('${root.path}/星海恋歌物语 Season 0').create();
      for (var i = 1; i <= 6; i++) {
        await File('${ovaDir.path}/0$i.mkv').writeAsBytes([i]);
      }
      for (var i = 1; i <= 2; i++) {
        await File('${extrasDir.path}/星海恋歌物语 - S00E0$i.mkv').writeAsBytes([i]);
      }

      final client = MockClient((req) async {
        final path = req.url.path;
        if (path == '/v0/search/subjects') {
          final kw = (jsonDecode(req.body) as Map)['keyword'].toString();
          if (kw.contains('OVA')) {
            return _json({
              'data': [
                {
                  'id': 61002,
                  'name': '星海恋歌物语 OVA 特别篇',
                  'name_cn': '星海恋歌物语 OVA 特别篇',
                  'date': '2021-06-15',
                  'total_episodes': 6,
                  'platform': 'OVA',
                },
              ],
            });
          }
          return _json({
            'data': [
              {
                'id': 61001,
                'name': '星海恋歌物语',
                'name_cn': '星海恋歌物语',
                'date': '2019-04-05',
                'total_episodes': 24,
              },
            ],
          });
        }
        if (path == '/v0/subjects/61002') {
          return _json({
            'id': 61002,
            'name': '星海恋歌物语 OVA 特别篇',
            'name_cn': '星海恋歌物语 OVA 特别篇',
            'date': '2021-06-15',
            'total_episodes': 6,
            'platform': 'OVA',
            'images': {'large': 'https://lain.bgm.tv/love-ova.jpg'},
          });
        }
        if (path == '/v0/subjects/61001') {
          return _json({
            'id': 61001,
            'name': '星海恋歌物语',
            'name_cn': '星海恋歌物语',
            'date': '2019-04-05',
            'total_episodes': 24,
            'images': {'large': 'https://lain.bgm.tv/love-tv.jpg'},
          });
        }
        if (path == '/3/search/tv') {
          return _json({
            'results': [
              {
                'id': 61000,
                'name': '星海恋歌物语',
                'first_air_date': '2019-04-05',
              },
            ],
          });
        }
        if (path == '/3/tv/61000') {
          return _json({
            'id': 61000,
            'name': '星海恋歌物语',
            'first_air_date': '2019-04-05',
            'poster_path': '/love-tv.jpg',
            'seasons': [
              {
                'season_number': 0,
                'name': '特别篇',
                'episode_count': 10,
                'air_date': '2019-05-01',
              },
              {
                'season_number': 1,
                'name': 'Season 1',
                'episode_count': 24,
                'air_date': '2019-04-05',
              },
            ],
          });
        }
        if (path == '/3/tv/61000/season/0') {
          return _json({
            'season_number': 0,
            'poster_path': '/love-specials.jpg',
          });
        }
        return _json({}, 404);
      });

      final sourceId = await catalog.addSource('local', 'OVA与特典库', root.path);
      await catalog.addScanRoot(sourceId, '');
      await SelectedScanWorkflow.run(
        catalog.sourceOf(sourceId),
        pipeline: ScrapePipeline(catalog: catalog, client: client),
      );

      final ovaWork = catalog.works.singleWhere(
        (w) => w['bangumi_id'] == 61002,
      );
      expect(ovaWork['tmdb_id'], 61000);
      expect(ovaWork['needs_review'], 0);
      expect(
        catalog.forWork(ovaWork['id'].toString()).every((a) => a['season'] == 0),
        isTrue,
      );

      final extrasWork = catalog.works.singleWhere(
        (w) => w['id'].toString() != ovaWork['id'].toString(),
      );
      expect(extrasWork['tmdb_id'], 61000);
      expect(extrasWork['needs_review'], 0);
      expect(
        catalog
            .forWork(extrasWork['id'].toString())
            .every((a) => a['season'] == 0),
        isTrue,
      );
    });
  });

  group('已确认作品增量免重刮与 CRC32 误分类资产自愈', () {
    test(
      '已确认作品增量扫描发 0 次网络请求并自愈 CRC32 误判特典，同时保留 manual_lock==0 与手动覆盖',
      () async {
        final (root, _, catalog) = await _openTestCatalog('incremental-crc32');
        final folderName = '星之音 Season 2';
        final workDir = await Directory('${root.path}/$folderName').create();

        // 预先将文件索引入库并模拟历史状态：
        // - 03 正常识别为 main (season=2)
        // - 01 [89D91AED] & 02 [ed07016e] 历史上被误判成 category='extra', episode=null
        // - 04 [DEAD1234] 被用户手动 override 为 category='extra'（严禁被自愈篡改）
        final sourceId = await catalog.addSource('local', '增量自愈库', root.path);
        await catalog.addScanRoot(sourceId, '');
        final p1 = '${workDir.path}/[Group] 星之音 - 01 [89D91AED].mkv';
        final p2 = '${workDir.path}/[Group] 星之音 - 02 [ed07016e].mkv';
        final p3 = '${workDir.path}/[Group] 星之音 - 03.mkv';
        final p4 = '${workDir.path}/[Group] 星之音 - 04 [DEAD1234].mkv';
        for (final p in [p1, p2, p3, p4]) {
          await File(p).writeAsBytes([1]);
        }

        final rel1 = '$folderName/[Group] 星之音 - 01 [89D91AED].mkv';
        final rel2 = '$folderName/[Group] 星之音 - 02 [ed07016e].mkv';
        final rel3 = '$folderName/[Group] 星之音 - 03.mkv';
        final rel4 = '$folderName/[Group] 星之音 - 04 [DEAD1234].mkv';

        await catalog.indexVideo(sourceId, rel1, 100, workFolder: folderName);
        await catalog.indexVideo(sourceId, rel2, 100, workFolder: folderName);
        await catalog.indexVideo(sourceId, rel3, 100, workFolder: folderName);
        await catalog.indexVideo(sourceId, rel4, 100, workFolder: folderName);

        Future<String> assetIdFor(String rel) async {
          final rows = await catalog.db.query(
            'assets',
            columns: ['id'],
            where: 'relative_path=?',
            whereArgs: [rel],
            limit: 1,
          );
          return rows.single['id'].toString();
        }

        final a1 = await assetIdFor(rel1);
        final a2 = await assetIdFor(rel2);
        final a3 = await assetIdFor(rel3);
        final a4 = await assetIdFor(rel4);

        await catalog.db.update(
          'assets',
          {'category': 'extra', 'extra_type': 'ed', 'season': 1, 'episode': null},
          where: 'id IN (?,?)',
          whereArgs: [a1, a2],
        );
        await catalog.db.update(
          'assets',
          {'category': 'main', 'extra_type': null, 'season': 2, 'episode': 3},
          where: 'id=?',
          whereArgs: [a3],
        );
        await catalog.db.update(
          'assets',
          {'category': 'extra', 'extra_type': 'other', 'season': 1, 'episode': null},
          where: 'id=?',
          whereArgs: [a4],
        );

        await catalog.reload();
        final workId = catalog.works.single['id'].toString();
        await catalog.db.update(
          'works',
          {
            'title': '星之音',
            'tmdb_id': 91001,
            'tmdb_type': 'tv',
            'bangumi_id': 41001,
            'poster': 'https://image.tmdb.org/t/p/w500/star-s2.jpg',
            'needs_review': 0,
            'manual_lock': 0,
          },
          where: 'id=?',
          whereArgs: [workId],
        );
        await catalog.db.insert('asset_overrides', {
          'asset_id': a4,
          'work_id': workId,
          'category': 'extra',
          'episode': null,
          'season': 1,
          'extra_type': 'other',
        });
        await catalog.db.insert('work_details', {
          'work_id': workId,
          'identity': 'tmdb-tv-91001',
          'payload': '{}',
          'fetched_at': DateTime.now().toIso8601String(),
        });
        await catalog.reload();

        var httpCalls = 0;
        final client = MockClient((req) async {
          httpCalls++;
          return _json({}, 404);
        });

        final report = await ScrapePipeline(
          catalog: catalog,
          client: client,
        ).scrapeSource(sourceId, onlyPending: true);

        // 1. 已确认作品跳过网络请求，零 HTTP 调用
        expect(httpCalls, 0);
        expect(report.matched, 0);
        expect(report.skipped, 1);

        final work = catalog.works.single;
        expect(work['manual_lock'], 0);
        expect(work['title'], '星之音');

        // 2. CRC32 误判特典自动恢复为 main 并补齐 episode 与同季 season=2
        final assetsById = {
          for (final a in catalog.forWork(workId)) a['id'].toString(): a,
        };
        expect(assetsById[a1]!['category'], 'main');
        expect(assetsById[a1]!['episode'], 1);
        expect(assetsById[a1]!['season'], 2);
        expect(assetsById[a1]!['extra_type'], isNull);

        expect(assetsById[a2]!['category'], 'main');
        expect(assetsById[a2]!['episode'], 2);
        expect(assetsById[a2]!['season'], 2);
        expect(assetsById[a2]!['extra_type'], isNull);

        // 3. 手动 override 资产保持不被自愈覆盖
        expect(assetsById[a4]!['category'], 'extra');
        expect(assetsById[a4]!['episode'], isNull);

        // 4. 自愈后已清理 work_details 缓存触发详情页刷新
        final cached = await catalog.db.query(
          'work_details',
          where: 'work_id=?',
          whereArgs: [workId],
        );
        expect(cached, isEmpty);

        // 5. manual_lock==0 兼容 pruneOrphanedWorks（清空无保护资产后可清理孤儿作品）
        await catalog.db.delete('asset_overrides', where: 'work_id=?', whereArgs: [workId]);
        await catalog.db.delete('assets', where: 'work_id=?', whereArgs: [workId]);
        await catalog.pruneOrphanedWorks();
        expect(catalog.works, isEmpty);
      },
    );
  });
}
