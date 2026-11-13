import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart' as archive;
import 'package:ccplayer/core/bangumi_offline_index.dart';
import 'package:ccplayer/core/catalog.dart';
import 'package:ccplayer/core/detail_metadata.dart';
import 'package:ccplayer/core/metadata.dart';
import 'package:ccplayer/core/scrape_pipeline.dart';
import 'package:ccplayer/core/selected_scan_workflow.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

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
    Metadata.token = 'test-bearer-token';
    Metadata.apiKey = '';
    Metadata.authMode = 'token';
  });
  tearDown(() {
    Metadata.token = savedToken;
    Metadata.apiKey = savedKey;
    Metadata.authMode = savedMode;
  });

  test(
    'SelectedScanWorkflow defaults to ScrapePipeline: untyped {tmdb-N} movie vs TV, dual-encode collapse, and manual data preservation',
    () async {
      final root = await Directory.systemTemp.createTemp('konata-pipe-scan-');
      final dataDir = await Directory.systemTemp.createTemp('konata-pipe-db-');
      final catalog = Catalog.instance;
      await catalog.initialize(dataDirectory: dataDir);
      addTearDown(() async {
        await catalog.db.close();
        await root.delete(recursive: true);
        await dataDir.delete(recursive: true);
      });

      // 1. Dual-encode movie with untyped {tmdb-532067} where TV 532067 also exists!
      final movieDir = await Directory(
        '${root.path}/为美好的世界献上祝福！红传说 (2019) {tmdb-532067}',
      ).create();
      await File(
        '${movieDir.path}/[VCB-Studio] KonoSuba Legend 01 [Ma10p_1080p][x265_flac].mkv',
      ).writeAsBytes([1, 2]);
      await File(
        '${movieDir.path}/[VCB-Studio] KonoSuba Legend 01 [Ma10p_2160p_HDR][x265_flac].mkv',
      ).writeAsBytes([3, 4]);

      // 2. Anthology folder with {tmdb-508108} that must NOT bind to single movie.
      final anthologyDir = await Directory(
        '${root.path}/机动战士SD高达 (1988) {tmdb-508108}',
      ).create();
      for (final series in [
        'SD Gundam Mk-I',
        'SD Gundam Mk-II',
        'SD Gundam Mk-III',
        'SD Gundam Mk-IV',
        'SD Gundam Mk-V',
      ]) {
        for (var ep = 1; ep <= 3; ep++) {
          await File(
            '${anthologyDir.path}/[Group] $series [0$ep][1080p].mkv',
          ).writeAsBytes([ep]);
        }
      }

      var anthologyHttpCalls = 0;
      final client = MockClient((req) async {
        final path = req.url.path;
        if (path.contains('508108')) anthologyHttpCalls++;
        if (path == '/3/tv/532067') {
          return _json({
            'id': 532067,
            'name': 'Unrelated Talk Show',
            'first_air_date': '2021-05-01',
            'seasons': [
              {
                'season_number': 1,
                'episode_count': 24,
                'air_date': '2021-05-01',
              },
            ],
          });
        }
        if (path == '/3/movie/532067') {
          return _json({
            'id': 532067,
            'title': '为美好的世界献上祝福！红传说',
            'original_title': '映画 この素晴らしい世界に祝福を！紅伝説',
            'release_date': '2019-08-30',
            'poster_path': '/crimson.jpg',
            'overview': '红魔族剧场版简介',
          });
        }
        if (path == '/v0/search/subjects') {
          return _json({
            'data': [
              {
                'id': 253046,
                'name': '映画 この素晴らしい世界に祝福を！紅伝説',
                'name_cn': '为美好的世界献上祝福！红传说',
                'date': '2019-08-30',
              },
            ],
          });
        }
        if (path == '/v0/subjects/253046') {
          return _json({
            'id': 253046,
            'name': '映画 この素晴らしい世界に祝福を！紅伝説',
            'name_cn': '为美好的世界献上祝福！红传说',
            'date': '2019-08-30',
            'summary': 'Bangumi 剧场版简介',
            'images': {'large': 'https://lain.bgm.tv/pic/cover/l/crimson.jpg'},
          });
        }
        return _json({}, 404);
      });

      final pipeline = ScrapePipeline(catalog: catalog, client: client);
      addTearDown(() {
        pipeline.close();
        client.close();
      });

      final sourceId = await catalog.addSource('local', '本地动画', root.path);
      await catalog.addScanRoot(sourceId, '');
      await SelectedScanWorkflow.run(
        catalog.sourceOf(sourceId),
        pipeline: pipeline,
      );

      expect(
        anthologyHttpCalls,
        0,
        reason: 'Anthologies short-circuit locally',
      );
      final movieWork = catalog.works.singleWhere(
        (w) => w['tmdb_id'] == 532067,
      );
      expect(movieWork['tmdb_type'], 'movie');
      expect(movieWork['bangumi_id'], 253046);
      expect(movieWork['needs_review'], 0);
      expect(
        movieWork['poster'],
        'https://image.tmdb.org/t/p/w500/crimson.jpg',
      );
      final movieAssets = catalog.forWork(movieWork['id'].toString());
      expect(movieAssets, hasLength(2));
      expect(movieAssets.every((a) => a['episode'] == null), isTrue);

      final anthologyWork = catalog.works.singleWhere(
        (w) => w['id'] != movieWork['id'],
      );
      expect(anthologyWork['tmdb_id'], isNull);
      expect(anthologyWork['poster'], isNull);
      expect(anthologyWork['title'], '机动战士SD高达');
      expect(anthologyWork['needs_review'], 1);

      // Verify manual cover, manual lock, asset_overrides and watch progress survive rescan!
      final firstAssetId = movieAssets.first['id'].toString();
      await catalog.progress(firstAssetId, 54321, 120000);
      await catalog.setManualCover(
        movieWork['id'].toString(),
        source: 'tmdb',
        url: 'https://image.tmdb.org/t/p/w500/custom-picked.jpg',
      );
      await catalog.updateWorkMetadata(
        anthologyWork['id'].toString(),
        title: '我的SD高达合集',
        year: 1988,
        overview: '自定义简介',
      );

      await catalog.addScanRoot(sourceId, '');
      await SelectedScanWorkflow.run(
        catalog.sourceOf(sourceId),
        pipeline: ScrapePipeline(catalog: catalog, client: client),
      );

      final movieAfter = catalog.works.singleWhere(
        (w) => w['id'] == movieWork['id'],
      );
      expect(
        Catalog.preferredPoster(movieAfter),
        'https://image.tmdb.org/t/p/w500/custom-picked.jpg',
      );
      final progressRows = await catalog.progressForWork(
        movieWork['id'].toString(),
      );
      expect(progressRows[firstAssetId]?['position_ms'], 54321);

      final anthologyAfter = catalog.works.singleWhere(
        (w) => w['id'] == anthologyWork['id'],
      );
      expect(anthologyAfter['title'], '我的SD高达合集');
      expect(anthologyAfter['manual_lock'], 1);
    },
  );

  test(
    'Same-year multi-season separation (12 eps S1 vs 10 eps BURST S2) + standalone OVA promotion',
    () async {
      final root = await Directory.systemTemp.createTemp('konata-seasons-');
      final dataDir = await Directory.systemTemp.createTemp(
        'konata-seasons-db-',
      );
      final catalog = Catalog.instance;
      await catalog.initialize(dataDirectory: dataDir);
      addTearDown(() async {
        await catalog.db.close();
        await root.delete(recursive: true);
        await dataDir.delete(recursive: true);
      });

      final s1Dir = await Directory('${root.path}/新妹魔王的契约者 (2015)').create();
      for (var i = 1; i <= 12; i++) {
        await File(
          '${s1Dir.path}/[VCB-Studio] Shinmai Maou no Testament [${i.toString().padLeft(2, '0')}][1080p].mkv',
        ).writeAsBytes([i]);
      }

      final s2Dir = await Directory(
        '${root.path}/新妹魔王的契约者 BURST (2015)',
      ).create();
      for (var i = 1; i <= 10; i++) {
        await File(
          '${s2Dir.path}/[VCB-Studio] Shinmai Maou no Testament BURST [${i.toString().padLeft(2, '0')}][1080p].mkv',
        ).writeAsBytes([i]);
      }

      final ovaDir = await Directory(
        '${root.path}/头文字D Extra Stage (2001) {tmdb-13525}',
      ).create();
      await File(
        '${ovaDir.path}/[Group] Initial D Extra Stage [OVA][1080p].mkv',
      ).writeAsBytes([1]);
      await File('${ovaDir.path}/Sample.mkv').writeAsBytes([0]);

      final client = MockClient((req) async {
        final path = req.url.path;
        if (path == '/v0/search/subjects') {
          final kw = (jsonDecode(req.body) as Map)['keyword'].toString();
          if (kw.contains('BURST')) {
            return _json({
              'data': [
                {
                  'id': 129820,
                  'name': '新妹魔王の契約者 BURST',
                  'name_cn': '新妹魔王的契约者 BURST',
                  'date': '2015-10-09',
                  'total_episodes': 10,
                },
              ],
            });
          }
          if (kw.contains('新妹魔王') || kw.contains('Shinmai')) {
            return _json({
              'data': [
                {
                  'id': 100444,
                  'name': '新妹魔王の契約者',
                  'name_cn': '新妹魔王的契约者',
                  'date': '2015-01-07',
                  'total_episodes': 12,
                },
                {
                  'id': 129820,
                  'name': '新妹魔王の契約者 BURST',
                  'name_cn': '新妹魔王的契约者 BURST',
                  'date': '2015-10-09',
                  'total_episodes': 10,
                },
              ],
            });
          }
          if (kw.contains('Extra Stage') || kw.contains('头文字D')) {
            return _json({
              'data': [
                {
                  'id': 9569,
                  'name': '頭文字D Extra Stage',
                  'name_cn': '头文字D Extra Stage',
                  'date': '2001-03-22',
                  'total_episodes': 2,
                },
              ],
            });
          }
          return _json({'data': []});
        }
        if (path == '/v0/subjects/100444') {
          return _json({
            'id': 100444,
            'name': '新妹魔王の契約者',
            'name_cn': '新妹魔王的契约者',
            'date': '2015-01-07',
            'total_episodes': 12,
            'images': {'large': 'https://lain.bgm.tv/s1.jpg'},
          });
        }
        if (path == '/v0/subjects/129820') {
          return _json({
            'id': 129820,
            'name': '新妹魔王の契約者 BURST',
            'name_cn': '新妹魔王的契约者 BURST',
            'date': '2015-10-09',
            'total_episodes': 10,
            'images': {'large': 'https://lain.bgm.tv/s2.jpg'},
          });
        }
        if (path == '/v0/subjects/9569') {
          return _json({
            'id': 9569,
            'name': '頭文字D Extra Stage',
            'name_cn': '头文字D Extra Stage',
            'date': '2001-03-22',
            'images': {'large': 'https://lain.bgm.tv/ova.jpg'},
          });
        }
        if (path == '/3/search/tv') {
          return _json({
            'results': [
              {
                'id': 61923,
                'name': '新妹魔王的契约者',
                'original_name': '新妹魔王の契約者',
                'first_air_date': '2015-01-07',
              },
            ],
          });
        }
        if (path == '/3/tv/61923') {
          return _json({
            'id': 61923,
            'name': '新妹魔王的契约者',
            'original_name': '新妹魔王の契約者',
            'first_air_date': '2015-01-07',
            'poster_path': '/series.jpg',
            'seasons': [
              {
                'season_number': 1,
                'episode_count': 12,
                'air_date': '2015-01-07',
              },
              {
                'season_number': 2,
                'episode_count': 10,
                'air_date': '2015-10-10',
              },
            ],
          });
        }
        if (path == '/3/tv/61923/season/1') {
          return _json({
            'season_number': 1,
            'air_date': '2015-01-07',
            'poster_path': '/shinmai-s1.jpg',
            'overview': '第一季简介',
          });
        }
        if (path == '/3/tv/61923/season/2') {
          return _json({
            'season_number': 2,
            'air_date': '2015-10-10',
            'poster_path': '/shinmai-s2.jpg',
            'overview': '第二季 BURST 简介',
            'episodes': [
              {
                'episode_number': 1,
                'name': 'BURST 第1话',
                'still_path': '/burst-ep1.jpg',
              },
            ],
          });
        }
        if (path == '/3/tv/13525') {
          return _json({
            'id': 13525,
            'name': '头文字D',
            'original_name': '頭文字D',
            'first_air_date': '1998-04-18',
            'seasons': [
              {
                'season_number': 0,
                'episode_count': 6,
                'air_date': '2001-03-22',
              },
              {
                'season_number': 1,
                'episode_count': 26,
                'air_date': '1998-04-18',
              },
            ],
          });
        }
        if (path == '/3/tv/13525/season/0') {
          return _json({
            'season_number': 0,
            'name': 'Specials',
            'poster_path': '/initiald-s0.jpg',
          });
        }
        return _json({}, 404);
      });

      final sourceId = await catalog.addSource('local', '多季样本', root.path);
      await catalog.addScanRoot(sourceId, '');
      await SelectedScanWorkflow.run(
        catalog.sourceOf(sourceId),
        pipeline: ScrapePipeline(catalog: catalog, client: client),
      );

      final s1 = catalog.works.singleWhere((w) => w['bangumi_id'] == 100444);
      final s2 = catalog.works.singleWhere((w) => w['bangumi_id'] == 129820);
      expect(s1['tmdb_id'], 61923);
      expect(s2['tmdb_id'], 61923);
      expect(s1['title'], '新妹魔王的契约者');
      expect(s2['title'], '新妹魔王的契约者 BURST');
      expect(s1['poster'], 'https://image.tmdb.org/t/p/w500/shinmai-s1.jpg');
      expect(s2['poster'], 'https://image.tmdb.org/t/p/w500/shinmai-s2.jpg');
      expect(
        catalog.forWork(s1['id'].toString()).every((a) => a['season'] == 1),
        isTrue,
      );
      expect(
        catalog.forWork(s2['id'].toString()).every((a) => a['season'] == 2),
        isTrue,
      );

      // DetailMetadataService resolves S2 episodes cleanly without year ambiguity!
      final detailSvc = DetailMetadataService(
        client: client,
        tmdbRequest: (res, _) async {
          final resp = await client.get(
            Uri.parse('https://api.themoviedb.org/3$res'),
          );
          return resp.statusCode == 200
              ? jsonDecode(resp.body) as Map<String, dynamic>
              : null;
        },
      );
      final s2Detail = await detailSvc.fetch(
        s2,
        assets: catalog.forWork(s2['id'].toString()),
      );
      expect(s2Detail['seasonMappingAmbiguous'], isFalse);
      expect(
        ((s2Detail['seasonEpisodes'] as Map)['2'] as Map)['1']['name'],
        'BURST 第1话',
      );
      detailSvc.close();

      // Standalone OVA promoted to main while Sample stays extra.
      final ova = catalog.works.singleWhere((w) => w['bangumi_id'] == 9569);
      expect(ova['title'], '头文字D Extra Stage');
      final ovaAssets = catalog.forWork(ova['id'].toString());
      final mainOva = ovaAssets.singleWhere((a) => a['category'] == 'main');
      final sampleExtra = ovaAssets.singleWhere(
        (a) => a['category'] == 'extra',
      );
      expect(mainOva['name'].toString(), contains('Extra Stage'));
      expect(mainOva['season'], 0);
      expect(sampleExtra['name'], 'Sample.mkv');

      client.close();
    },
  );

  test(
    'Offline Bangumi lookupMany + cross-provider Japanese title rescue hits TMDB with 0 Bangumi search calls',
    () async {
      final temp = await Directory.systemTemp.createTemp('konata-xrescue-');
      final dataDir = await Directory.systemTemp.createTemp('konata-xdb-');
      final catalog = Catalog.instance;
      await catalog.initialize(dataDirectory: dataDir);
      addTearDown(() async {
        await catalog.db.close();
        await temp.delete(recursive: true);
        await dataDir.delete(recursive: true);
      });

      final index = BangumiOfflineIndex(Directory('${temp.path}/bgm_index'));
      final zip = File('${temp.path}/archive.zip');
      final lines = [
        {
          'id': 136213,
          'type': 2,
          'name': 'ネトゲの嫁は女の子じゃないと思った？',
          'name_cn': '线上游戏的老婆不可能是女生？',
          'date': '2016-04-07',
          'infobox': '{{Infobox\n|别名={\n[亚子与卢西安的日常]\n}\n}}',
        },
        {
          'id': 50190,
          'type': 2,
          'name': '機動戦士ΖガンダムIII 星の鼓動は愛',
          'name_cn': '机动战士Z高达III 星之鼓动是爱',
          'date': '2006-03-04',
        },
      ];
      final rawBytes = utf8.encode('${lines.map(jsonEncode).join('\n')}\n');
      final archiveData = archive.Archive()
        ..addFile(
          archive.ArchiveFile('subject.jsonlines', rawBytes.length, rawBytes),
        );
      await zip.writeAsBytes(archive.ZipEncoder().encode(archiveData));
      await index.install(zip: zip);

      // Roman numeral Ⅲ (U+2162) matches ASCII III in lookupMany!
      final romanHits = await index.lookupMany(['机动战士Z高达Ⅲ 星之鼓动是爱']);
      expect(romanHits.map((e) => e['id']), contains(50190));

      // Folder uses fan alias "亚子与卢西安的日常" unknown to TMDB; offline Bangumi
      // finds official JP name "ネトゲの嫁は女の子じゃないと思った？", rescuing TMDB!
      final mediaRoot = await Directory('${temp.path}/media').create();
      final showDir = await Directory(
        '${mediaRoot.path}/亚子与卢西安的日常 (2016)',
      ).create();
      for (var i = 1; i <= 12; i++) {
        await File(
          '${showDir.path}/[${i.toString().padLeft(2, '0')}].mkv',
        ).writeAsBytes([i]);
      }

      var bgmSearchCalls = 0;
      final client = MockClient((req) async {
        final path = req.url.path;
        if (path == '/v0/search/subjects') {
          bgmSearchCalls++;
          return _json({'data': []});
        }
        if (path == '/v0/subjects/136213') {
          return _json({
            'id': 136213,
            'name': 'ネトゲの嫁は女の子じゃないと思った？',
            'name_cn': '线上游戏的老婆不可能是女生？',
            'date': '2016-04-07',
            'total_episodes': 12,
            'images': {'large': 'https://lain.bgm.tv/netoge.jpg'},
          });
        }
        if (path == '/3/search/tv') {
          final q = req.url.queryParameters['query'] ?? '';
          if (q.contains('ネトゲの嫁') || q.contains('线上游戏的老婆')) {
            return _json({
              'results': [
                {
                  'id': 65946,
                  'name': '线上游戏的老婆不可能是女生？',
                  'original_name': 'ネトゲの嫁は女の子じゃないと思った？',
                  'first_air_date': '2016-04-07',
                },
              ],
            });
          }
          return _json({'results': []});
        }
        if (path == '/3/tv/65946') {
          return _json({
            'id': 65946,
            'name': '线上游戏的老婆不可能是女生？',
            'original_name': 'ネトゲの嫁は女の子じゃないと思った？',
            'first_air_date': '2016-04-07',
            'poster_path': '/netoge-tmdb.jpg',
            'seasons': [
              {
                'season_number': 1,
                'episode_count': 12,
                'air_date': '2016-04-07',
              },
            ],
          });
        }
        if (path == '/3/tv/65946/season/1') {
          return _json({'season_number': 1, 'poster_path': '/netoge-tmdb.jpg'});
        }
        return _json({}, 404);
      });

      final sourceId = await catalog.addSource('local', '离线测试', mediaRoot.path);
      await catalog.addScanRoot(sourceId, '');
      await SelectedScanWorkflow.run(
        catalog.sourceOf(sourceId),
        pipeline: ScrapePipeline(
          catalog: catalog,
          client: client,
          offlineIndex: index,
        ),
      );

      expect(bgmSearchCalls, 0, reason: 'Offline index hit avoids POST search');
      final work = catalog.works.single;
      expect(work['bangumi_id'], 136213);
      expect(work['tmdb_id'], 65946);
      expect(work['title'], '线上游戏的老婆不可能是女生？');
      expect(work['needs_review'], 0);
      expect(work['poster'], 'https://image.tmdb.org/t/p/w500/netoge-tmdb.jpg');

      client.close();
    },
  );

  test(
    'Default parameterless SelectedScanWorkflow.run uses ScrapePipeline, adopts medium-tier poster, and regroups @unclassified files',
    () async {
      final temp = await Directory.systemTemp.createTemp('konata-default-wf-');
      final dataDir = await Directory.systemTemp.createTemp('konata-def-db-');
      final catalog = Catalog.instance;
      await catalog.initialize(dataDirectory: dataDir);
      final oldIndexDir = BangumiOfflineIndex.directory;
      addTearDown(() async {
        BangumiOfflineIndex.directory = oldIndexDir;
        await catalog.db.close();
        await temp.delete(recursive: true);
        await dataDir.delete(recursive: true);
      });

      // 1. Parameterless SelectedScanWorkflow.run promotes standalone OVA folder
      //    using ScrapePipeline (with offline Bangumi index & no TMDB token).
      Metadata.token = '';
      final indexDir = Directory('${temp.path}/offline_bgm');
      BangumiOfflineIndex.directory = indexDir;
      final index = BangumiOfflineIndex(indexDir);
      final zip = File('${temp.path}/bgm.zip');
      final dump = utf8.encode(
        '${jsonEncode({'id': 9569, 'type': 2, 'name': '頭文字D Extra Stage', 'name_cn': '头文字D Extra Stage', 'date': '2001-03-22'})}\n',
      );
      final arch = archive.Archive()
        ..addFile(archive.ArchiveFile('subject.jsonlines', dump.length, dump));
      await zip.writeAsBytes(archive.ZipEncoder().encode(arch));
      await index.install(zip: zip);

      final mediaRoot = await Directory('${temp.path}/library').create();
      final ovaFolder = await Directory(
        '${mediaRoot.path}/头文字D Extra Stage (2001)',
      ).create();
      await File(
        '${ovaFolder.path}/[Group] Initial D Extra Stage [OVA][1080p].mkv',
      ).writeAsBytes([1]);

      // TestWidgetsFlutterBinding blocks real internet by returning HTTP 400,
      // proving offline index + local DirectoryAnalyzer run by default!
      final src = await catalog.addSource('local', '默认管线验证', mediaRoot.path);
      await catalog.addScanRoot(src, '');
      await SelectedScanWorkflow.run(catalog.sourceOf(src));

      final promotedWork = catalog.works.single;
      expect(promotedWork['bangumi_id'], 9569);
      expect(promotedWork['needs_review'], 0);
      expect(
        catalog.forWork(promotedWork['id'].toString()).single['category'],
        'main',
        reason:
            'Default SelectedScanWorkflow.run executed ScrapePipeline OVA promotion',
      );

      // 2. Medium-tier match adopts Top-1 cover onto poster wall immediately
      //    while keeping needs_review = 1; @unclassified splits distinct shows.
      Metadata.token = 'test-bearer-token';
      final mediumDir = await Directory(
        '${mediaRoot.path}/机动战士高达 THE ORIGIN',
      ).create();
      for (var i = 1; i <= 6; i++) {
        await File(
          '${mediumDir.path}/[Group] Mobile Suit Gundam The Origin [0$i][1080p].mkv',
        ).writeAsBytes([i]);
      }

      final looseRoot = await Directory('${temp.path}/Anime').create();
      await File(
        '${looseRoot.path}/[Group] Hyouka - 01 [1080p].mkv',
      ).writeAsBytes([1]);
      await File(
        '${looseRoot.path}/[Group] Hyouka - 02 [1080p].mkv',
      ).writeAsBytes([2]);
      await File(
        '${looseRoot.path}/[Group] Bakemonogatari - 01 [1080p].mkv',
      ).writeAsBytes([3]);

      final mockClient = MockClient((req) async {
        final path = req.url.path;
        if (path == '/v0/search/subjects') {
          final kw = (jsonDecode(req.body) as Map)['keyword'].toString();
          if (kw.contains('Hyouka')) {
            return _json({
              'data': [
                {'id': 2, 'name': '氷菓', 'name_cn': '冰菓', 'date': '2012-04-22'},
              ],
            });
          }
          if (kw.contains('Bakemonogatari')) {
            return _json({
              'data': [
                {
                  'id': 3,
                  'name': '化物語',
                  'name_cn': '化物语',
                  'date': '2009-07-03',
                },
              ],
            });
          }
          return _json({'data': []});
        }
        if (path == '/v0/subjects/2') {
          return _json({
            'id': 2,
            'type': 2,
            'platform': 'TV',
            'name': '氷菓',
            'name_cn': '冰菓',
            'date': '2012-04-22',
            'eps': 22,
            'images': {'large': 'https://lain.bgm.tv/hyouka.jpg'},
            'infobox': [
              {
                'key': '别名',
                'value': [
                  {'v': 'Hyouka'},
                ],
              },
            ],
          });
        }
        if (path == '/v0/subjects/3') {
          return _json({
            'id': 3,
            'type': 2,
            'platform': 'TV',
            'name': '化物語',
            'name_cn': '化物语',
            'date': '2009-07-03',
            'eps': 15,
            'images': {'large': 'https://lain.bgm.tv/bake.jpg'},
            'infobox': [
              {
                'key': '别名',
                'value': [
                  {'v': 'Bakemonogatari'},
                ],
              },
            ],
          });
        }
        if (path == '/3/search/tv') {
          final q = req.url.queryParameters['query'] ?? '';
          if (q.contains('ORIGIN') || q.contains('Origin')) {
            return _json({
              'results': [
                {
                  'id': 62605,
                  'name': '机动战士高达 THE ORIGIN 前夜 红色彗星',
                  'original_name': '機動戦士ガンダム THE ORIGIN 前夜 赤い彗星',
                  'first_air_date': '2019-04-29',
                },
              ],
            });
          }
          return _json({'results': []});
        }
        if (path == '/3/tv/62605') {
          return _json({
            'id': 62605,
            'name': '机动战士高达 THE ORIGIN 前夜 红色彗星',
            'original_name': '機動戦士ガンダム THE ORIGIN 前夜 赤い彗星',
            'first_air_date': '2019-04-29',
            'poster_path': '/origin.jpg',
            'overview': '夏亚前传简介',
            'seasons': [
              {
                'season_number': 1,
                'episode_count': 6,
                'air_date': '2019-04-29',
              },
            ],
          });
        }
        return _json({}, 404);
      });

      final src1 = catalog.sources.first['id'].toString();
      await catalog.addScanRoot(src1, '机动战士高达 THE ORIGIN');
      await SelectedScanWorkflow.run(
        catalog.sourceOf(src1),
        pipeline: ScrapePipeline(
          catalog: catalog,
          client: mockClient,
          offlineIndex: BangumiOfflineIndex(
            Directory('${temp.path}/empty_idx'),
          ),
        ),
      );

      final originWork = catalog.works.singleWhere(
        (w) => w['tmdb_id'] == 62605,
      );
      // Medium tier: cover and overview adopted immediately, needs_review = 1!
      expect(
        originWork['poster'],
        'https://image.tmdb.org/t/p/w500/origin.jpg',
      );
      expect(originWork['overview'], '夏亚前传简介');
      expect(originWork['needs_review'], 1);

      final looseSrc = await catalog.addSource('local', '散装目录', looseRoot.path);
      await catalog.addScanRoot(looseSrc, '');
      await SelectedScanWorkflow.run(
        catalog.sourceOf(looseSrc),
        pipeline: ScrapePipeline(
          catalog: catalog,
          client: mockClient,
          offlineIndex: BangumiOfflineIndex(
            Directory('${temp.path}/empty_idx'),
          ),
        ),
      );
      final hyoukaWork = catalog.works.singleWhere((w) => w['bangumi_id'] == 2);
      expect(hyoukaWork['title'], '冰菓');
      expect(hyoukaWork['poster_fallback'], 'https://lain.bgm.tv/hyouka.jpg');
      expect(catalog.forWork(hyoukaWork['id'].toString()).length, 2);

      final bakeWork = catalog.works.singleWhere((w) => w['bangumi_id'] == 3);
      expect(bakeWork['title'], '化物语');
      expect(bakeWork['poster_fallback'], 'https://lain.bgm.tv/bake.jpg');
      expect(catalog.forWork(bakeWork['id'].toString()).length, 1);

      mockClient.close();
    },
  );
}
