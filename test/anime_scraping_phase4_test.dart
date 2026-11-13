import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ccplayer/core/catalog.dart';
import 'package:ccplayer/core/debug_log.dart';
import 'package:ccplayer/core/detail_metadata.dart';
import 'package:ccplayer/core/playback_history.dart';
import 'package:ccplayer/core/anime_mapping_acquisition.dart';
import 'package:ccplayer/core/incremental_scan.dart';
import 'package:ccplayer/core/image_store.dart';
import 'package:ccplayer/core/library_backup_exporter.dart';
import 'package:ccplayer/core/library_backup_restorer.dart';
import 'package:ccplayer/core/local_media.dart';
import 'package:ccplayer/core/metadata.dart';
import 'package:ccplayer/core/metadata_servers.dart';
import 'package:ccplayer/core/scan_recognition.dart';
import 'package:ccplayer/core/scoped_artwork.dart';
import 'package:ccplayer/core/scan_activity.dart';
import 'package:ccplayer/core/scrape_task_runner.dart';
import 'package:ccplayer/core/shared_metadata_requests.dart';
import 'package:ccplayer/ui/scan_reviews_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

class QueueProbeRunner extends ScrapeTaskRunner {
  QueueProbeRunner(super.catalog, this.execute);
  final Future<void> Function(String) execute;
  @override
  Future<void> run(String id, {bool manualRetry = false}) => execute(id);
}

class _ArtworkFixtureRunner extends ScrapeTaskRunner {
  _ArtworkFixtureRunner(Catalog catalog, SharedMetadataRequests requests)
    : super(catalog, requests: requests);

  @override
  ScopedArtwork get artwork => ScopedArtwork(catalog, requests,
      fetchImage: (_, checkActive) async => checkActive());
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final catalog = Catalog.instance;
  late Directory scratch, library, media;
  late String source;
  late ScrapeTaskRunner runner;
  late String oldToken, oldMode;
  late bool oldFallback;

  Future<void> open({bool automatic = false, bool artwork = false}) =>
      catalog.initialize(
        dataDirectory: library,
        enableFoundation: true,
        enableTasks: true,
        enableMappings: true,
        enableRecognition: true,
        enableAutomaticRecognition: automatic,
        enableScopedArtwork: artwork,
      );

  http.Response reply(Object body, [int status = 200]) => http.Response(
    jsonEncode(body),
    status,
    headers: {'content-type': 'application/json'},
  );

  void useTransport(Future<http.Response> Function(http.Request) handler, {bool artwork = false}) {
    final requests = SharedMetadataRequests(
        catalog.taskStore!,
        clientFactory: () => MockClient(handler),
        deadline: const Duration(seconds: 2),
        retryDelays: const [],
    );
    runner = artwork ? _ArtworkFixtureRunner(catalog, requests)
        : ScrapeTaskRunner(catalog, requests: requests);
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    scratch = await Directory.systemTemp.createTemp('konata-phase4-');
    library = await Directory('${scratch.path}/library').create();
    media = await Directory('${scratch.path}/media').create();
    oldToken = Metadata.token;
    oldMode = Metadata.authMode;
    oldFallback = MetadataServers.fallback;
    Metadata.token = 'test-fixture-token';
    Metadata.authMode = 'token';
    MetadataServers.fallback = false;
    await open();
    source = await catalog.addSource('local', 'Fixture', media.path);
    await catalog.addScanRoot(source, '');
    useTransport(
      (request) async => reply(
        request.url.path.contains('/3/') ? {'results': []} : {'data': []},
      ),
    );
  });

  tearDown(() async {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      LocalMedia.channel,
      null,
    );
    catalog.taskStore?.dispose();
    catalog.taskStore = null;
    await ImageStore.close();
    await catalog.db.close();
    Metadata.token = oldToken;
    Metadata.authMode = oldMode;
    MetadataServers.fallback = oldFallback;
    await scratch.delete(recursive: true);
  });

  test('automatic queue refills a free slot while another work is slow', () async {
    final slow = Completer<void>(), second = Completer<void>();
    final secondStarted = Completer<void>(), thirdStarted = Completer<void>();
    var concurrent = 0, peak = 0;
    const slots = ScrapeTaskRunner.maxConcurrentWorks;
    for (final id in ['recognize:slow', for (var i = 1; i < slots; i++) 'recognize:waiting:$i', 'recognize:next']) {
      await catalog.taskStore!.enqueue(id, intent: {}, steps: ['recognize']);
    }
    final queue = QueueProbeRunner(catalog, (id) async {
      concurrent++;
      if (concurrent > peak) peak = concurrent;
      try {
        if (id == 'recognize:slow') await slow.future;
        if (id.startsWith('recognize:waiting:')) {
          if (concurrent == slots) secondStarted.complete();
          await second.future;
        }
        if (id == 'recognize:next') thirdStarted.complete();
        await catalog.db.update('scrape_tasks', {'state': 'complete'}, where: 'id=?', whereArgs: [id]);
      } finally { concurrent--; }
    });
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    try {
      queue.startAutomaticQueue();
      await secondStarted.future.timeout(const Duration(seconds: 2));
      second.complete();
      await thirdStarted.future.timeout(const Duration(seconds: 2));
      expect(slow.isCompleted, isFalse);
      expect(peak, slots);
    } finally {
      if (!second.isCompleted) second.complete();
      if (!slow.isCompleted) slow.complete();
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      while (concurrent > 0) { await Future<void>.delayed(const Duration(milliseconds: 10)); }
      await Future<void>.delayed(const Duration(milliseconds: 20));
      catalog.taskStore!.dispose();
      catalog.taskStore = null;
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    }
  });

  Future<void> video(String path, [int size = 10]) async {
    final file = File('${media.path}/$path');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(List.filled(size, 0));
  }

  Future<void> scan() async => runner.run(await runner.enqueueScan(source));

  Future<Map<String, Object?>> withToken(Map<String, Object?> row) async => {
    ...row,
    'session': (await catalog.db.query('scrape_runtime')).single['session'],
    'identity_revision': (await catalog.db.query(
      'library_work_protection',
      where: 'work_id=?',
      whereArgs: [row['work_id']],
    )).single['revision'],
  };
  Future<Map<String, Object?>> record(
    String provider,
    String layer, {
    String scope = '',
  }) async => withToken(
    (await catalog.db.query(
      'scan_bindings',
      where: 'provider=? AND layer=? AND scope=?',
      whereArgs: [provider, layer, scope],
    )).single,
  );

  for (final scenario in ['recover', 'recover-second', 'series-title', 'saved-conflict',
      'dual-season', 'dual-season-wrong-offset', 'chapter-conflict', 'locked']) {
    test('Maken-Ki real season evidence: $scenario', () async {
      await catalog.db.close();
      await open(automatic: true, artwork: true);
      final fixtures = jsonDecode(await File('test/fixtures/maken_ki_identity.json').readAsString()) as List;
      final fixture = fixtures[scenario == 'recover' || scenario == 'locked' ? 0 : 1] as Map;
      final folder = fixture['folder'] as String;
      final tv = fixture['tmdb'] as Map;
      final bg = fixture['subject'] as Map;
      final recovering = scenario.startsWith('recover') || scenario == 'locked';
      final dual = scenario.startsWith('dual-season');
      final savedConflict = scenario == 'saved-conflict' || dual;
      for (final (index, file) in (fixture['files'] as List).cast<String>().indexed) {
        final number = (index + 1).toString().padLeft(2, '0');
        final absolute = index + (scenario == 'dual-season-wrong-offset' ? 14 : 13);
        final end = index == 9 ? ' END' : '';
        await video(dual
            ? '$folder/[Moozzi2] Maken-Ki! Two S2 - $number [ $absolute ]$end (BD 1920x1080 x.264 Flac).mkv'
            : '$folder/$file');
      }
      if (recovering || savedConflict) {
        useTransport((request) async => reply({'results': [], 'data': [], 'total': 0}));
        await scan();
        await catalog.db.update('scan_bindings', {
          'state': recovering ? 'confirmed' : 'pending',
          'reason': recovering ? 'verified_tmdb' : 'conflicting_title',
          if (recovering) 'adopted': jsonEncode(tv),
          'candidates': jsonEncode([{...tv, if (savedConflict) 'directory_title_matches': false}]),
        }, where: "layer='work' AND provider='tmdb'");
        await catalog.db.update('scan_bindings', {
          'reason': recovering ? 'query_incomplete' : 'conflicting_title',
          'candidates': jsonEncode([fixture['bangumi']]),
        }, where: "layer='work' AND provider='bangumi'");
        if (scenario == 'locked') {
          await catalog.db.update('library_work_protection', {'identity_locked': 1});
        }
      }
      var searches = 0, narrowSearches = 0;
      useTransport((request) async {
        final path = request.url.path;
        if (path.endsWith('/search/subjects')) {
          final body = jsonDecode(request.body) as Map;
          if ((body['filter'] as Map?)?['air_date'] != null) narrowSearches++;
          final related = fixture['bangumi_related'];
          return reply({'data': [bg, if (related != null) related], 'total': related == null ? 1 : 2});
        }
        if (path.endsWith('/search/multi') || path.contains('/search/tv')) {
          searches++;
          return reply({'results': [{
            'id': tv['id'], 'media_type': 'tv', 'name': '魔剑姬',
            'original_name': 'Maken-Ki! Two', 'first_air_date': '2011-10-05',
          }], 'total_pages': 1});
        }
        if (path.endsWith('/tv/${tv['id']}')) {
          return reply({
            'id': tv['id'], 'name': '魔剑姬', 'original_name': 'Maken-Ki! Two',
            'first_air_date': '2011-10-05',
            'seasons': [
              {'season_number': 1, 'episode_count': 12, 'air_date': '2011-10-05'},
              {'season_number': 2, 'episode_count': 10, 'air_date': '2014-01-16'},
            ],
          });
        }
        if (path.endsWith('/subjects/${bg['id']}')) return reply(bg);
        if (path.endsWith('/episodes')) {
          final body = jsonDecode(jsonEncode(fixture['episodes'])) as Map;
          if (scenario == 'chapter-conflict') body['data'][0]['name'] = '別の番組';
          return reply(body);
        }
        if (path.endsWith('/season/${fixture['season']}')) {
          return reply(fixture[request.url.queryParameters['language'] == 'ja-JP' ? 'ja' : 'zh']);
        }
        if (path.endsWith('/images')) return reply({'posters': [], 'backdrops': []});
        return reply({}, 404);
      }, artwork: true);
      await scan();
      if (scenario == 'locked' || scenario == 'chapter-conflict' || scenario == 'dual-season-wrong-offset') {
        expect(ScanRecognition.adopted(await record('bangumi', 'work')), isNull);
        expect((await record('tmdb', 'work'))['reason'], isNot('verified_tv_chapters'));
        if (scenario == 'locked') expect(searches + narrowSearches, 0);
        if (scenario == 'dual-season-wrong-offset') {
          final steps = await catalog.db.query('scrape_steps',
              where: "step='recognize' AND state='running'");
          expect(steps, isEmpty);
        }
        return;
      }
      if (recovering) {
        expect(searches, 0);
        expect(narrowSearches, 1);
      }
      if (savedConflict) expect(searches + narrowSearches, 0);
      expect((await record('tmdb', 'work'))['reason'], 'verified_tv_chapters');
      expect(ScanRecognition.adopted(await record('bangumi', 'work'))?['id'], bg['id']);
      final range = ScanRecognition.adopted(await record('tmdb', 'range'));
      expect(range?['season'], fixture['season']);
      if (dual) expect(range?['offset'], -12);
      expect((range?['chapters'] as List).map((r) => r['id']),
          (fixture['zh']['episodes'] as List).map((r) => r['id']));
      final work = catalog.works.single;
      expect(work['title'], bg['name_cn']);
      expect(Catalog.preferredPoster(work),
          endsWith(Uri.parse(bg['images']['large'] as String).path));
    });
  }

  for (final mode in ['automatic', 'manual', 'locked', 'legacy_locked']) {
    test('promotion rescan retracts only automatic episode: $mode', () async {
      await catalog.db.close();
      await open(automatic: true);
      useTransport((request) async => reply({'results': [], 'data': []}));
      await video('Sasaki to Miyano/Bonus/Sasaki to Miyano - OVA CM.mkv');
      await scan();
      final file = (await catalog.db.query('assets')).single;
      final wrong = jsonEncode({'id': 127549, 'season': 0, 'episode': 1,
        'by': mode == 'manual' ? 'manual_confirmed' : 'verified_specials'});
      await catalog.db.insert('scan_bindings', {
        'id': 'promotion-fixture', 'work_id': file['work_id'],
        'asset_id': file['id'], 'provider': 'tmdb', 'layer': 'episode',
        'scope': file['id'], 'state': 'confirmed',
        'reason': mode == 'manual' ? 'manual_confirmed' : 'verified_specials',
        'adopted': wrong,
      });
      if (mode.endsWith('locked')) {
        await catalog.db.update('library_work_protection',
          {mode == 'locked' ? 'identity_locked' : 'legacy_lock': 1});
      }
      Future<Map<String, Object?>> row() async => (await catalog.db.query(
        'scan_bindings', where: 'id=?', whereArgs: ['promotion-fixture'])).single;
      final before = await row();
      await scan();
      final after = await row();
      if (mode == 'automatic') {
        expect(after['adopted'], isNull);
        expect(after['previous'], wrong);
        expect(after['state'], 'pending');
        expect(after['reason'], 'special_no_longer_eligible');
      } else {
        expect(after, before);
      }
      await scan();
      expect(await row(), after);
    });
  }

  for (final mode in ['first', 'burst', 'short-first', 'mixed-release', 'wrong-chapter', 'wrong-date', 'partial-response', 'locked']) {
    test('same-year seasons recover from r7 series binding: $mode', () async {
      await catalog.db.close();
      await open(automatic: true, artwork: true);
      final first = mode == 'first' || mode == 'short-first';
      const base = '新妹魔王的契约者', japanese = '新妹魔王の契約者';
      const release = 'Shinmai Maou no Testament';
      final suffix = first ? '' : ' BURST';
      final folder = '$base$suffix';
      final season = first ? 1 : 2, subjectId = first ? 100205 : 128885;
      final names = first ? [
        '妹ができた日', '初めての主従契約', '再会と信頼の狭間', '悲しみがゼロになるまで',
        '朝の妹の魔王無双', '募る思いを抱えて', '恩讐の果てに', '暴走のエロサキュバス',
        '主從の功罪', '哀切なる背信', '諜報者…その先にあるもの', 'この夜、このときのために',
      ] : [
        'あなたの為にできる事を', '深まる疑惑と謎の中で', '譲れない想いを君と', '絡み合う思惑の中で',
        '吹き抜ける戦場の風の中を', '己の真実と現実の狭間で', '絡み合う思惑と欲望の狭間で',
        '未来へと挑む者たち', '見果てぬ夢のその先に', '果たすべき意思の後先',
      ];
      String date(int index, bool seasonOne) => DateTime.utc(2015, seasonOne ? 1 : 10, seasonOne ? 7 : 9)
          .add(Duration(days: index * 7)).toIso8601String().split('T').first;
      final count = mode == 'short-first' ? 10 : names.length;
      for (var n = 1; n <= count; n++) {
        final fileSuffix = mode == 'mixed-release' && n == 1 ? '' : suffix;
        await video('$folder/[VCB-Studio] $release$fileSuffix [${n.toString().padLeft(2, '0')}][Ma10p_1080p][x265_flac].mkv');
      }
      useTransport((request) async => reply({'results': [], 'data': [], 'total': 0}));
      await scan();
      final work = catalog.works.single['id'] as String;
      final series = {'id': 64163, 'type': 'tv', 'title': base, 'year': 2015,
        'by': 'verified_tmdb', 'exact': true, 'title_matches': true,
        'directory_title_matches': first,
        'aliases': [base, japanese, if (!first) '$release$suffix'],
        if (!first) 'directory_subject': subjectId,
        'seasons': [
          {'season': 0, 'count': 13, 'year': 2015},
          {'season': 1, 'count': 12, 'year': 2015},
          {'season': 2, 'count': 10, 'year': 2015},
        ]};
      final poster = 'https://lain.bgm.tv/pic/cover/l/01/02/${subjectId}_fixture.jpg';
      final subject = {'id': subjectId, 'type': 2, 'name': '$japanese$suffix',
        'name_cn': folder, 'date': date(0, first), 'images': {'large': poster}};
      await catalog.db.update('scan_bindings', {
        'state': 'confirmed', 'reason': 'verified_tmdb',
        'adopted': jsonEncode(series), 'candidates': jsonEncode([series]),
      }, where: "provider='tmdb' AND layer='work'");
      await catalog.db.update('scan_bindings', {
        'reason': 'query_incomplete',
        'candidates': jsonEncode([{'id': subjectId, 'type': 'anime', 'title': folder,
          'year': 2015, 'exact': true, 'directory_title_matches': true}]),
      }, where: "provider='bangumi' AND layer='work'");
      await catalog.db.update('works', {'title': base}, where: 'id=?', whereArgs: [work]);
      if (mode == 'locked') {
        await catalog.db.update('library_work_protection', {'identity_locked': 1});
      }
      final queriedSeasons = <int>{};
      var refreshedAliases = false;
      useTransport((request) async {
        final path = request.url.path;
        if (path.endsWith('/subjects/$subjectId')) return reply(subject);
        if (path.endsWith('/search/subjects')) return reply({'data': [subject], 'total': 1});
        if (path.endsWith('/tv/64163')) {
          refreshedAliases = true;
          return reply({'id': 64163, 'name': base, 'original_name': japanese,
            'alternative_titles': {'results': [{'title': release}, {'title': '$release BURST'}]}});
        }
        if (path.endsWith('/episodes')) {
          return reply({
            'total': names.length,
            'data': [for (final (i, name) in names.indexed)
              {'id': subjectId + i, 'type': 0, 'sort': i + 1, 'name': name, 'airdate': date(i, first)}],
          });
        }
        final match = RegExp(r'/season/(\d+)$').firstMatch(path);
        if (match != null) {
          final number = int.parse(match[1]!);
          if (number == 0) return reply({'season_number': 0, 'episodes': []});
          queriedSeasons.add(number);
          final original = request.url.queryParameters['language'] == 'ja-JP';
          final total = number == 1 ? 12 : 10;
          return reply({'season_number': number, 'episodes': [
            for (var i = 0; i < (mode == 'partial-response' ? total - 1 : total); i++)
              {'id': number * 100 + i + 1, 'season_number': number, 'episode_number': i + 1,
                'air_date': mode == 'wrong-date' && i == 0 ? '2015-10-12' : date(i, number == 1),
                'name': !original ? 'Translated chapter ${i + 1}'
                    : mode == 'wrong-chapter' && i == 0 ? '別の番組'
                    : number != season ? '別の番組 ${i + 1}'
                    : first && i == 8 ? '主従の功罪'
                    : first && i == 10 ? '諜報者(エスピオナージ)……その先にあるもの'
                    : names[i]},
          ]});
        }
        if (path.endsWith('/images')) return reply({'posters': [], 'backdrops': []});
        return reply({}, 404);
      }, artwork: true);
      await runner.run(await runner.recognition.enqueue(source, work, retry: true));
      final tv = await record('tmdb', 'work');
      expect(ScanRecognition.adopted(tv)?['id'], 64163);
      final ranges = await catalog.db.query('scan_bindings',
          where: "provider='tmdb' AND layer='range' AND state='confirmed'");
      if (mode != 'first' && mode != 'burst') {
        expect(ranges, isEmpty);
        expect(ScanRecognition.adopted(await record('bangumi', 'work')), isNull);
        if (mode == 'locked') {
          expect(queriedSeasons, isEmpty);
        } else {
          expect(queriedSeasons, mode == 'mixed-release' ? isEmpty : {2});
          expect(catalog.works.single['title'], folder);
        }
        return;
      }
      expect(refreshedAliases, first);
      expect(queriedSeasons, {season});
      expect(tv['reason'], 'verified_tv_chapters');
      expect(ScanRecognition.adopted(await record('bangumi', 'work'))?['id'], subjectId);
      expect(ScanRecognition.adopted(ranges.single)?['season'], season);
      final episodes = await catalog.db.query('scan_bindings',
          where: "provider='tmdb' AND layer='episode' AND state='confirmed'");
      expect(episodes.map((row) => ScanRecognition.adopted(row)?['episode']).toSet(),
          {for (var n = 1; n <= count; n++) n});
      expect(catalog.works.single['title'], folder);
      expect(Catalog.preferredPoster(catalog.works.single), endsWith(Uri.parse(poster).path));
    });
  }

  test('numbered TV inventory excludes homonymous movie search candidates', () async {
    await catalog.db.close();
    await open(automatic: true);
    for (var n = 1; n <= 23; n++) {
      await video('86 -不存在的战区-/[UHA-WINGS&VCB-Studio] EIGHTY SIX [${n.toString().padLeft(2, '0')}].mkv');
    }
    useTransport((request) async {
      final path = request.url.path;
      if (path.endsWith('/search/multi')) {
        return reply({'total_pages': 1, 'results': [
          {'id': 100565, 'media_type': 'tv', 'name': '86-不存在的战区-', 'first_air_date': '2021-04-11'},
          {'id': 1077468, 'media_type': 'movie', 'title': 'Eighty-Six', 'release_date': '2012-01-01'},
          {'id': 1367516, 'media_type': 'movie', 'title': 'Eighty-Six', 'release_date': '2024-01-01'},
        ]});
      }
      if (path.endsWith('/tv/100565')) return reply({
        'id': 100565, 'first_air_date': '2021-04-11',
        'seasons': [{'season_number': 1, 'episode_count': 23, 'air_date': '2021-04-11'}],
      });
      if (path.endsWith('/season/1')) return reply({'season_number': 1, 'episodes': [
        for (var n = 1; n <= 23; n++) {'id': n, 'episode_number': n, 'season_number': 1, 'name': 'Episode $n'},
      ]});
      if (path.contains('/movie/')) return reply({
        'id': int.parse(path.split('/').last), 'title': 'Eighty-Six',
        'release_date': path.endsWith('1077468') ? '2012-01-01' : '2024-01-01',
      });
      if (path.startsWith('/3/')) return reply({});
      return reply({}, 503);
    });
    await scan();
    final reviewed = await record('tmdb', 'work');
    expect(ScanRecognition.adopted(reviewed)?['id'], 100565, reason: '${reviewed['reason']} ${reviewed['candidates']}');
    expect(ScanRecognition.adopted(await record('tmdb', 'range'))?['season'], 1);
  });

  for (final mode in ['fresh', 'existing', 'unverified', 'manual', 'locked']) {
    test('marked Aquarion film keeps its own identity: $mode', () async {
      await catalog.db.close();
      await open(automatic: true, artwork: true);
      const film = '剧场版 创圣的大天使';
      const tv = '创圣的大天使';
      const release = '[QTS] Gekijouban AQUARION -Sosei Shinwa Hen & Ippatsu '
          'Gyakuten Hen- (BD Hi10P 1920x1080 Dolby TrueHD 5.1ch + WV 2ch).mkv';
      await video('$film/$release');
      await video('$tv (2005) {tmdbtv-8872}/$tv S01E05.mkv');
      final show = {'id': 8872, 'media_type': 'tv', 'name': tv,
        'first_air_date': '2005-04-05', 'seasons': [
          {'season_number': 1, 'episode_count': 26, 'air_date': '2005-04-05'},
        ]};
      final tvSubject = {'id': 1763, 'type': 2, 'name': tv, 'date': '2005-04-05'};
      final subject = {'id': 30488, 'type': 2, 'name': '劇場版アクエリオン',
        'name_cn': film, 'platform': '剧场版', 'date': '2007-09-22',
        'images': {'large': 'https://lain.bgm.tv/pic/cover/l/film.jpg'}};
      final movie = {'id': 187334, 'media_type': 'movie',
        'original_title': '劇場版アクエリオン -壱発逆転篇-', 'title': 'Genesis of Aquarion: Wings of Genesis',
        'release_date': '2007-09-21', 'poster_path': '/film.jpg',
        'alternative_titles': {'titles': [
          {'title': 'Gekijouban Aquarion Ippatsu Gyakuten Hen'},
        ]}};
      var includeFilm = mode == 'fresh', movieQueries = 0;
      var narrowSearches = 0;
      useTransport((request) async {
        final path = request.url.path;
        if (path.endsWith('/search/subjects')) {
          final query = jsonDecode(request.body) as Map;
          final filmQuery = query['keyword'] == film;
          if (filmQuery && includeFilm) {
            final dates = (query['filter'] as Map)['air_date'];
            if (dates != null) narrowSearches++;
            return reply({'data': [subject], 'total': dates == null ? 798 : 1});
          }
          return reply({'data': [tvSubject], 'total': 1});
        }
        if (path.endsWith('/subjects/30488')) return reply(subject);
        if (path.endsWith('/tv/8872')) return reply(show);
        if (path.endsWith('/movie/187334')) return reply(movie);
        if (path.endsWith('/search/multi')) {
          movieQueries++;
          return reply({'results': [show, if (includeFilm) movie], 'total_pages': 1});
        }
        if (path.endsWith('/season/1')) {
          return reply({'season_number': 1, 'episodes': [
            for (var n = 1; n <= 26; n++)
              {'id': n, 'episode_number': n, 'season_number': 1, 'name': 'Episode $n'},
          ]});
        }
        if (path.endsWith('/images')) return reply({'posters': [], 'backdrops': []});
        return reply({}, 404);
      }, artwork: true);
      await scan();
      final location = (await catalog.db.query('library_locations',
          where: "kind='work' AND relative_path=?", whereArgs: [film])).single;
      final work = location['entity_id'] as String;
      Future<List<Map<String, Object?>>> bindings() => catalog.db.query('scan_bindings',
          where: 'work_id=?', whereArgs: [work], orderBy: 'id');
      expect((await catalog.db.query('assets', where: 'work_id=?',
          whereArgs: [work])).single['episode'], isNull);
      if (mode != 'fresh') {
        expect((await bindings()).every((row) => ScanRecognition.adopted(row) == null), isTrue);
        if (mode == 'unverified') return;
        for (final provider in ['tmdb', 'bangumi']) {
          final tmdb = provider == 'tmdb';
          final reason = tmdb ? 'verified_tmdb' : 'verified_bangumi';
          await catalog.db.update('scan_bindings', {
            'state': 'confirmed',
            'reason': mode == 'manual' && tmdb ? 'manual_confirmed' : reason,
            'adopted': jsonEncode({'id': tmdb ? 8872 : 1763,
              'type': tmdb ? 'tv' : 'anime', 'title': tv,
              'by': mode == 'manual' && tmdb ? 'user' : reason}),
          }, where: "work_id=? AND provider=? AND layer='work'", whereArgs: [work, provider]);
          final identity = (await bindings()).singleWhere((row) => row['provider'] == provider);
          await catalog.db.insert('scan_bindings', {
            'id': jsonEncode([work, provider, 'range', '']),
            'work_id': work, 'provider': provider, 'layer': 'range', 'scope': '',
            'state': 'pending', 'reason': 'range_unconfirmed',
            'parent': jsonEncode([identity['id'], identity['revision']]),
          });
        }
        await catalog.db.update('assets', {'episode': 5}, where: 'work_id=?', whereArgs: [work]);
        if (mode == 'locked') {
          await catalog.db.update('library_work_protection', {'identity_locked': 1},
              where: 'work_id=?', whereArgs: [work]);
        }
        final before = await bindings(), beforeQueries = movieQueries;
        includeFilm = true;
        await runner.run(await runner.recognition.enqueue(source, work, retry: true));
        if (mode == 'manual' || mode == 'locked') {
          expect(await bindings(), before);
          expect(movieQueries, beforeQueries);
          return;
        }
      }
      final rows = await bindings();
      final tmdb = rows.singleWhere((row) => row['provider'] == 'tmdb' && row['layer'] == 'work');
      final bangumi = rows.singleWhere((row) => row['provider'] == 'bangumi' && row['layer'] == 'work');
      expect(ScanRecognition.adopted(tmdb)?['id'], 187334, reason: '$rows');
      expect(ScanRecognition.adopted(bangumi)?['id'], 30488);
      expect(narrowSearches, 1);
      expect(rows.where((row) => row['layer'] != 'work'), isEmpty);
      if (mode == 'existing') expect(jsonDecode(tmdb['previous'] as String)['id'], 8872);
      expect((await catalog.db.query('assets', where: 'work_id=?',
          whereArgs: [work])).single['episode'], isNull);
      final scope = await ScopedArtwork.scopeIn(catalog.db, work);
      expect(scope?.movie, isTrue);
      expect(scope?.tmdb, 187334);
      expect(Catalog.preferredPoster(catalog.works.singleWhere((row) => row['id'] == work)),
          endsWith('/film.jpg'));
      final other = catalog.works.singleWhere((row) => row['id'] != work);
      final tvRange = (await catalog.db.query('scan_bindings',
          where: "work_id=? AND provider='tmdb' AND layer='range'",
          whereArgs: [other['id']])).single;
      expect(ScanRecognition.adopted(tvRange)?['season'], 1);
    });
  }

  for (final mode in ['matched', 'lower_date_conflict', 'independent', 'locked']) {
    test('two-part OVA confirms only the matching special range: $mode', () async {
      await catalog.db.close();
      await open(automatic: true);
      const title = '夜空故事', original = '夜空の物語';
      for (final number in ['01', 'Vol.1', 'Vol.2', 'NCOP']) {
        await video('$title/[Group][Night_Tales][$number][OVA][DVDRIP].mkv');
      }
      const subject = {'id': 75201, 'type': 2, 'name': original, 'name_cn': title,
        'date': '2008-09-18', 'platform': 'OVA', 'eps': 2,
        'infobox': [{'key': '别名', 'value': '夜空 Night Tales OVA'}],
      };
      const series = {'id': 75202, 'media_type': 'tv', 'name': title,
        'original_name': '$original ～続き～', 'first_air_date': '2011-07-05',
        'seasons': [{'season_number': 0, 'episode_count': 3}]};
      var ready = false;
      useTransport((request) async {
        final path = request.url.path;
        if (path.endsWith('/search/subjects')) return reply({'total': 1, 'data': [subject]});
        if (path.endsWith('/subjects/75201')) return reply(subject);
        if (path.endsWith('/search/multi')) {
          return reply({'total_pages': 1, 'results': [if (ready) series]});
        }
        if (path.endsWith('/search/movie') || path.endsWith('/search/tv')) {
          return reply({'total_pages': 1, 'results': [
            if (mode == 'independent' && path.endsWith('/search/tv'))
              {'id': 75203, 'name': title, 'original_name': original, 'first_air_date': '2008-08-08'},
          ]});
        }
        if (path.endsWith('/tv/75202')) return reply(series);
        if (path.endsWith('/episodes')) {
          return reply({'total': 2, 'data': [
            {'id': 75301, 'sort': 1, 'type': 0, 'name': '上巻', 'airdate': '2008-09-18'},
            {'id': 75302, 'sort': 2, 'type': 0, 'name': '下巻', 'airdate': '2008-10-02'},
          ]});
        }
        if (path.endsWith('/season/0')) {
          return reply({'season_number': 0, 'episodes': [
            {'id': 75401, 'season_number': 0, 'episode_number': 1, 'name': 'OVA 上', 'air_date': '2008-08-08'},
            {'id': 75402, 'season_number': 0, 'episode_number': 2, 'name': 'OVA 下',
              'air_date': mode == 'lower_date_conflict' ? '2008-10-03' : '2008-10-02'},
            {'id': 75403, 'season_number': 0, 'episode_number': 3, 'name': '別の話', 'air_date': '2015-10-02'},
          ]});
        }
        return reply({}, 404);
      });
      await scan();
      final work = catalog.works.single['id'] as String;
      final saved = await record('bangumi', 'work');
      expect(ScanRecognition.adopted(saved)?['id'], 75201);
      if (mode == 'locked') {
        await catalog.db.update('library_work_protection', {'identity_locked': 1},
            where: 'work_id=?', whereArgs: [work]);
      }
      ready = true;
      await runner.run(await runner.recognition.enqueue(source, work, retry: true), manualRetry: true);
      expect(await record('bangumi', 'work'), saved);
      if (mode == 'matched') {
        expect(ScanRecognition.adopted(await record('tmdb', 'work'))?['year'], 2008);
        final range = ScanRecognition.adopted(await record('tmdb', 'range'))!;
        expect([range['season'], range['first'], range['last']], [0, 1, 2]);
        final episodes = await catalog.db.query('scan_bindings', where: "provider='tmdb' AND layer='episode'");
        final adopted = episodes.map(ScanRecognition.adopted).nonNulls.single;
        expect(adopted['chapter_id'], 75402);
        expect(episodes.where((row) => row['state'] == 'pending'), hasLength(2));
      } else {
        expect(ScanRecognition.adopted(await record('tmdb', 'work')), isNull);
      }
    });
  }

  for (final mode in ['fresh', 'saved', 'duration_conflict', 'no_compilation_tag',
      'short_clip', 'season_zero_only', 'trailer', 'locked',
      'ova', 'ova_short_clip', 'ova_trailer', 'ova_ambiguous', 'ova_tv_subject', 'ova_season_zero_only']) {
    test('standalone video requires evidence of an independent release: $mode', () async {
      await catalog.db.close();
      await open(automatic: true);
      const title = '夜空 四季回顾';
      final ova = mode.startsWith('ova');
      final original = ova ? '夜空の物語 番外編 四季の記憶' : '夜空の物語 四季の記憶';
      final suffix = mode.endsWith('trailer') ? ' 予告編' : '';
      final filename = ova ? original : '夜空の物語 総集編 四季の記憶';
      await video('$title/[Group] $filename$suffix (BD HEVC 1080p).mkv');
      final minutes = mode.endsWith('short_clip') ? 8 : ova ? 25 : 90;
      final subject = {
        'id': 75101, 'type': 2, 'name': original, 'name_cn': title, 'date': '1988-12-21',
        'platform': mode == 'ova_tv_subject' ? 'TV' : 'OVA', 'eps': 1,
        'infobox': [if (!ova) {'key': '片长', 'value': '$minutes分'}],
      };
      final movie = {
        'id': 75102, 'original_title': original, 'title': title, 'release_date': '1988-09-25',
      };
      var ready = !const {'saved', 'locked'}.contains(mode);
      var movieQueries = 0, seriesQueries = 0;
      useTransport((request) async {
        final path = request.url.path;
        if (path.endsWith('/search/subjects')) return reply({'data': [subject], 'total': 1});
        if (path.endsWith('/subjects/75101')) return reply(subject);
        if (path.endsWith('/search/movie')) {
          movieQueries++;
          expect(request.url.queryParameters['query'], original);
          expect(request.url.queryParameters['primary_release_year'], '1988');
          return reply({'total_pages': 1, 'results': [
            if (ready && !mode.endsWith('season_zero_only')) movie,
            if (mode == 'ova_ambiguous') {...movie, 'id': 75104},
          ]});
        }
        if (path.endsWith('/movie/75102')) {
          return reply({...movie, 'runtime': mode == 'duration_conflict' ? minutes + 1 : minutes,
            'genres': [{'id': 16}], if (!ova) 'keywords': {'keywords': [
              {'name': mode == 'no_compilation_tag' ? 'animation' : 'compilation'},
            ]}});
        }
        if (path.endsWith('/episodes')) {
          return reply({'total': 1, 'data': [{'id': 75103, 'type': 0, 'sort': 1, 'name': ''}]});
        }
        if (path.contains('/season/')) seriesQueries++;
        return reply({'results': [], 'total_pages': 1});
      });
      await scan();
      final work = catalog.works.single['id'] as String;
      if (mode == 'saved' || mode == 'locked') {
        expect(ScanRecognition.adopted(await record('bangumi', 'work'))?['id'], 75101);
        if (mode == 'locked') {
          await catalog.db.update('library_work_protection', {'identity_locked': 1},
              where: 'work_id=?', whereArgs: [work]);
        }
        ready = true;
        await runner.run(await runner.recognition.enqueue(source, work, retry: true), manualRetry: true);
      }
      final adopted = ScanRecognition.adopted(await record('tmdb', 'work'));
      final asset = (await catalog.db.query('assets')).single;
      if (const {'fresh', 'saved', 'ova'}.contains(mode)) {
        expect(adopted?['id'], 75102);
        expect(adopted?['type'], 'movie');
        expect((await record('tmdb', 'work'))['reason'],
            ova ? 'verified_standalone_ova' : 'verified_standalone_compilation');
        expect(ScanRecognition.adopted(await record('bangumi', 'work'))?['movie'], isTrue);
        expect(asset['category'], 'main');
        expect(asset['episode'], isNull);
        expect(asset['extra_type'], isNull);
        expect(await catalog.db.query('scan_bindings', where: "layer!='work'"), isEmpty);
        final binding = await record('tmdb', 'work');
        await scan();
        expect((await catalog.db.query('assets')).single['category'], 'main');
        expect(await record('tmdb', 'work'), binding);
      } else {
        expect(adopted, isNull);
        expect(asset['category'], 'extra');
      }
      if (const {'trailer', 'short_clip', 'ova_trailer', 'ova_tv_subject'}.contains(mode)) {
        expect(movieQueries, 0);
      }
      expect(seriesQueries, 0);
    });
  }

  for (final mode in ['verified', 'same_year_collision', 'live_action', 'wrong_file',
      'file_year_conflict', 'incomplete_bangumi', 'locked']) {
    test('ambiguous movie requires matching animated release evidence: $mode', () async {
      await catalog.db.close();
      await open(automatic: true);
      const title = '夜空 最终篇', original = '夜空の物語 完結篇';
      final name = mode == 'wrong_file' ? '別の物語 完結篇' : original;
      final year = mode == 'file_year_conflict' ? ' (2008)' : '';
      await video('$title/[Group] 劇場版 $name$year (BD HEVC 1920x1040 FLAC).mkv');
      if (mode == 'verified' || mode == 'locked') {
        for (final extra in [
          '劇場版 $original 予告編',
          '劇場版 $original 特報',
          '劇場版 別の物語 完結篇 予告編',
          '劇場版 $original (2008) 予告編',
        ]) {
          await video('$title/[Group] $extra (BD HEVC 1920x1040 FLAC).mkv');
        }
      }
      const subject = {
        'id': 74101, 'type': 2, 'name': original, 'name_cn': title, 'date': '1988-02-06',
        'platform': '剧场版',
      };
      const anime = {
        'id': 74102, 'media_type': 'movie', 'original_title': original,
        'title': title, 'release_date': '1988-11-06',
      };
      final remake = {
        ...anime, 'id': 74103, 'original_title': 'スペシャルドラマ 夜空の物語 完結編',
        'release_date': '2008-07-25',
      };
      var ready = false, scopedMovies = 0;
      useTransport((request) async {
        final path = request.url.path;
        if (path.endsWith('/search/subjects')) {
          final query = jsonDecode(request.body) as Map;
          final filter = query['filter'] as Map;
          final narrowed = (filter['air_date'] as List?)?.contains('>=1988-02-03') == true;
          if (narrowed) {
            if (mode == 'incomplete_bangumi') {
              return reply({'total': 2, 'data': [if (request.url.queryParameters['offset'] == null) subject]});
            }
            return reply({'total': 1, 'data': [subject]});
          }
          return reply({'total': ready ? 2 : 0,
            'data': [if (ready && request.url.queryParameters['offset'] == null) subject]});
        }
        if (path.endsWith('/subjects/74101')) return reply(subject);
        if (path.endsWith('/search/multi')) {
          return reply({'total_pages': 1, 'results': [if (ready) ...[anime, remake]]});
        }
        if (path.endsWith('/search/movie')) {
          scopedMovies++;
          expect(request.url.queryParameters['primary_release_year'], '1988');
          expect(request.url.queryParameters['query'], original);
          return reply({'total_pages': 1, 'results': [
            anime, remake, if (mode == 'same_year_collision') {...anime, 'id': 74104},
          ]});
        }
        if (path.endsWith('/movie/74102')) {
          return reply({...anime, 'genres': [{'id': mode == 'live_action' ? 18 : 16}]});
        }
        return reply({}, 404);
      });
      await scan();
      final work = catalog.works.single['id'] as String;
      if (mode == 'locked') {
        await catalog.db.update('library_work_protection', {'identity_locked': 1},
            where: 'work_id=?', whereArgs: [work]);
      }
      ready = true;
      await runner.run(await runner.recognition.enqueue(source, work, retry: true), manualRetry: true);
      final tmdb = ScanRecognition.adopted(await record('tmdb', 'work'));
      final bangumi = ScanRecognition.adopted(await record('bangumi', 'work'));
      Future<List<Map<String, Object?>>> attachments() => catalog.db.rawQuery("""
        SELECT b.*,a.name FROM scan_bindings b JOIN assets a ON a.id=b.asset_id
        WHERE b.reason='verified_movie_attachment' AND b.state='confirmed' ORDER BY b.id
      """);
      if (mode == 'verified') {
        expect(scopedMovies, 1);
        expect(tmdb?['id'], 74102);
        expect(bangumi?['id'], 74101);
        expect(bangumi?['movie'], isTrue);
        expect((await record('tmdb', 'work'))['reason'], 'verified_movie');
        final first = await attachments();
        expect(first, hasLength(4));
        for (final row in first) {
          final value = ScanRecognition.adopted(row)!;
          expect(value['movie_id'], row['provider'] == 'tmdb' ? 74102 : 74101);
          expect(value['attachment'], (row['name'] as String).contains('特報') ? 'teaser' : 'trailer');
          expect(value.containsKey('episode'), isFalse);
          expect(value.containsKey('chapter_id'), isFalse);
        }
        await runner.run(await runner.recognition.enqueue(source, work, retry: true), manualRetry: true);
        expect(await attachments(), first);
        final trailer = first.firstWhere((row) => row['provider'] == 'tmdb' &&
            (row['name'] as String).contains('予告編'));
        await runner.recognition.decide(await withToken(trailer), null, undo: true);
        await runner.run(await runner.recognition.enqueue(source, work, retry: true), manualRetry: true);
        expect(await attachments(), hasLength(3));
        final teaser = first.firstWhere((row) => (row['name'] as String).contains('特報'));
        await catalog.db.update('assets', {'name': 'Other Film 特報.mkv'},
            where: 'id=?', whereArgs: [teaser['asset_id']]);
        await runner.run(await runner.recognition.enqueue(source, work, retry: true), manualRetry: true);
        expect(await attachments(), hasLength(1));
        await runner.recognition.decide(await withToken(await record('tmdb', 'work')),
            {'type': 'tv', 'id': 74104});
        expect(await attachments(), isEmpty);
      } else {
        expect(tmdb, isNull);
        expect(bangumi, isNull);
        expect(await attachments(), isEmpty);
      }
    });
  }

  for (final mode in ['real', 'other', 'year_conflict', 'wrong_file', 'two_main']) {
    test('movie official filename alias enables landscape still $mode', () async {
      await catalog.db.close();
      await open(automatic: true);
      final id = mode == 'other' ? 77 : 593240;
      final title = mode == 'other' ? '另一部电影' : 'HUMAN LOST 人间失格';
      final original = mode == 'other' ? 'Another Movie Original' : 'HUMAN LOST 人間失格';
      final folder = '$title (${mode == 'year_conflict' ? 2018 : 2019}) {tmdb-$id}';
      await video('$folder/[Snow-Raws] ${mode == 'wrong_file' ? 'Unrelated Movie' : original} (BD 1920x804 HEVC-YUV420P10 DTS).mkv');
      if (mode == 'two_main') await video('$folder/Unrelated Movie.mkv');
      useTransport((request) async {
        if (request.url.path.endsWith('/movie/$id')) {
          return reply({
            'id': id, 'title': title, 'original_title': original,
            'release_date': '2019-11-29', 'backdrop_path': '/movie-landscape.jpg',
          });
        }
        if (request.url.path.contains('/search/subjects')) return reply({'data': [], 'total': 0});
        return reply({}, 404);
      });
      await scan();
      final row = await record('tmdb', 'work');
      if (mode == 'real' || mode == 'other') {
        expect(ScanRecognition.adopted(row)?['id'], id);
        final work = (await catalog.db.query('works')).single;
        final details = await ScanRecognition.details(catalog, work);
        expect(details?['recognized_movie_tmdb'], id);
        expect(details?['movieStill'], endsWith('/movie-landscape.jpg'));
        final before = await catalog.db.query('scan_bindings', orderBy: 'id');
        await scan();
        expect(await catalog.db.query('scan_bindings', orderBy: 'id'), before);
      } else {
        expect(ScanRecognition.adopted(row), isNull);
      }
    });
  }

  for (final mode in ['versions', 'mixed', 'legend', 'same-year-tv', 'locked']) {
    test('r7 movie identity follows all main files on targeted retry: $mode', () async {
      await catalog.db.close();
      await open(automatic: true);
      final legend = mode == 'legend' || mode == 'same-year-tv';
      final id = legend ? 271709 : 16157;
      final year = legend ? 2014 : 1988;
      final title = legend ? '头文字D Legend1 -觉醒-' : '机动战士高达 逆袭的夏亚';
      final folder = '$title ($year) {tmdb-$id}';
      final original = legend
          ? '新劇場版「頭文字D」Legend1 -覚醒-'
          : '機動戦士ガンダム 逆襲のシャア';
      if (legend) {
        await video('$folder/[AI-Raws&ANK-Raws] New Initial D the Movie Legend 01 - Awakening - (BDRip 1920x1080 x264 DTS).mkv');
      } else {
        await video('$folder/[AI-Raws] $original (UHD HEVC 1920x1040 yuv444p10le SDR FLAC).mkv');
        final other = mode == 'mixed' ? 'Unrelated film' : original;
        await video('$folder/[AI-Raws] $other (UHD HEVC 3840x2160 HDR FLAC).mkv', 11);
      }
      var ready = false;
      useTransport((request) async {
        final path = request.url.path;
        if (path.endsWith('/tv/$id')) return reply({
          'id': id,
          'name': mode == 'same-year-tv' ? title : 'Unrelated television series',
          'first_air_date': '${mode == 'same-year-tv' ? year : 2021}-01-01',
          'seasons': [{'season_number': 1, 'episode_count': 12}],
        });
        if (path.endsWith('/movie/$id') && ready) return reply({
          'id': id,
          'title': legend ? '头文字D新剧场版：觉醒' : title,
          'original_title': original,
          'release_date': '$year-03-12',
          'alternative_titles': {'titles': [
            if (legend) {'title': 'New Initial D the Movie: Legend 1 - Awakening'},
          ]},
        });
        if (path.endsWith('/search/subjects')) return reply({
          'data': legend ? [] : [
            {'id': 4583, 'type': 2, 'name': original, 'name_cn': title, 'date': '$year-03-12'},
          ],
          'total': legend ? 0 : 1,
        });
        return reply({}, 404);
      });
      await scan();
      final work = catalog.works.single['id'] as String;
      if (mode == 'locked') {
        await catalog.db.update('library_work_protection', {'identity_locked': 1});
      }
      ready = true;
      await runner.run(await runner.recognition.enqueue(source, work, retry: true), manualRetry: true);
      final adopted = ScanRecognition.adopted(await record('tmdb', 'work'));
      if (mode == 'versions' || mode == 'legend') {
        expect(adopted?['id'], id);
        expect(adopted?['type'], 'movie');
        final assets = await catalog.db.query('assets', where: 'work_id=?', whereArgs: [work]);
        expect(assets, hasLength(legend ? 1 : 2));
        expect(await catalog.db.query('scan_bindings',
            where: "provider='tmdb' AND layer!='work' AND state='confirmed'"), isEmpty);
      } else {
        expect(adopted?['type'], isNot('movie'));
      }
    });
  }

  for (final mode in ['bracketed-crc', 'bilingual', 'mixed-title', 'wrong-detail-year']) {
    test('movie release formatting keeps exact identity evidence: $mode', () async {
      await catalog.db.close();
      await open(automatic: true);
      const folder = '电影作品 赤色黎明';
      const original = '赤い夜明け';
      const english = 'The Crimson Dawn';
      final bracketed = mode == 'bracketed-crc' || mode == 'wrong-detail-year';
      final raw = bracketed ? '赤色黎明' : '赤色黎明 (2021) {tmdb-902501}';
      await video('$raw/${bracketed
          ? '[Group][The_Crimson_Dawn][hevc_10bit_aac][1080P][BDrip](167095E5).mkv'
          : '赤色黎明.${mode == 'mixed-title' ? 'Unrelated.Film' : 'The.Crimson.Dawn'}.2021.1080p.BluRay.x265.FLAC-Group.mkv'}');
      final movie = {
        'id': 902501, 'media_type': 'movie', 'title': '赤色黎明',
        'original_title': original, 'release_date': '2021-03-12',
      };
      var detailQueries = 0;
      useTransport((request) async {
        final path = request.url.path;
        if (path.endsWith('/search/subjects')) return reply({'data': [{
          'id': 441002, 'type': 2, 'name': original, 'name_cn': '赤色黎明', 'date': '2021-03-12',
        }], 'total': 1});
        if (path.endsWith('/search/multi')) {
          return reply({'results': [movie], 'total_pages': 1});
        }
        if (path.endsWith('/movie/902501')) {
          detailQueries++;
          return reply({...movie, 'release_date': mode == 'wrong-detail-year' ? '2020-03-12' : '2021-03-12',
            'alternative_titles': {'titles': [{'title': english}]}});
        }
        return reply({}, 404);
      });
      await scan();
      expect(detailQueries, 1, reason: folder);
      final selected = ScanRecognition.adopted(await record('tmdb', 'work'));
      if (mode == 'bilingual' || mode == 'bracketed-crc') {
        expect(selected?['id'], 902501);
      } else {
        expect(selected, isNull);
      }
    });
  }

  for (final mode in ['bangumi', 'incomplete-bangumi', 'tmdb-budget', 'ambiguous-tmdb',
      'missing-movie', 'missing-on-both-queries', 'missing-narrow-failure']) {
    test('r7 precise movie search completes bounded evidence: $mode', () async {
      await catalog.db.close();
      await open(automatic: true);
      final budget = mode.endsWith('tmdb') || mode == 'tmdb-budget';
      final missing = mode.startsWith('missing');
      final folder = missing ? '圣斗士星矢 天界篇 序奏～overture～' :
          budget ? '和谐' : 'Wake Up, Girls! 七人的偶像';
      final original = missing ? '聖闘士星矢 天界編 序奏 ~Overture~' :
          budget ? 'ハーモニー' : 'Wake Up, Girls! 七人のアイドル';
      final id = missing ? 601205 : budget ? 357411 : 249766;
      final subject = missing ? 20235 : budget ? 100448 : 87700;
      final year = missing ? 2004 : budget ? 2015 : 2014;
      const alias = 'Saint Seiya the Movie 5 - Tenkai-hen Josou';
      final release = missing ? '$alias (2004)' : budget ? 'Harmony' : '劇場版 $original';
      await video('$folder/[VCB-Studio] $release (BDRip 1080p FLAC).mkv');
      final movie = {'id': id, 'media_type': 'movie', 'title': folder,
        'original_title': original, 'release_date': '$year-01-10',
        if (missing) 'alternative_titles': {'titles': [{'title': alias}]}};
      var narrowed = 0;
      useTransport((request) async {
        final path = request.url.path;
        final bangumi = {'id': subject, 'type': 2, 'name': original,
          'name_cn': folder, 'date': '$year-01-10',
          'infobox': [if (budget) {'key': '别名', 'value': 'Harmony'}]};
        if (path.endsWith('/search/subjects')) {
          final query = jsonDecode(request.body) as Map;
          final dates = (query['filter'] as Map)['air_date'];
          if (dates != null) narrowed++;
          return reply({'data': [bangumi],
            'total': budget || missing || dates != null && mode != 'incomplete-bangumi' ? 1 : 70});
        }
        if (path.endsWith('/subjects/$subject')) return reply(bangumi);
        if (path.endsWith('/search/multi')) return reply({
          'total_pages': 1,
          'results': [if (!missing) movie, if (budget)
            for (var i = 0; i < 13; i++)
              {'id': 500000 + i, 'media_type': 'movie', 'title': 'Harmony',
                'original_title': 'Unrelated title $i', 'release_date': '$year-01-10'}],
        });
        if (path.endsWith('/search/movie')) {
          narrowed++;
          expect(request.url.queryParameters['primary_release_year'], '$year');
          expect(request.url.queryParameters['query'], original);
          if (mode == 'missing-narrow-failure') return reply({}, 503);
          return reply({'total_pages': 1, 'results': [
            if (mode != 'missing-on-both-queries') movie,
            if (mode == 'ambiguous-tmdb') {...movie, 'id': 123456},
          ]});
        }
        if (path.contains('/movie/')) {
          final id = int.parse(path.split('/').last);
          return reply({'id': id, 'title': 'Harmony',
            'original_title': 'Unrelated title ${id - 500000}', 'release_date': '$year-01-10'});
        }
        return reply({}, 404);
      });
      await scan();
      expect(narrowed, mode == 'missing-narrow-failure' ? inInclusiveRange(1, 3) : 1);
      final tmdb = await record('tmdb', 'work');
      final match = ScanRecognition.adopted(tmdb);
      if (mode == 'bangumi' || mode == 'tmdb-budget' || mode == 'missing-movie') {
        expect(match?['id'], id);
        expect(ScanRecognition.adopted(await record('bangumi', 'work'))?['id'], subject);
      } else {
        expect(match, isNull);
        if (mode == 'missing-narrow-failure') expect(tmdb['reason'], 'request_failed');
      }
    });
  }

  for (final mode in ['complete', 'different-title', 'different-chapter', 'same-year-collision',
      'broadcast-dates', 'two-date-outliers', 'duplicate-chapter-title',
      'continuous-seasons', 'continuous-seasons-wrong-title', 'continuous-seasons-missing', 'continuous-seasons-locked']) {
    test('same-title television candidates require complete chapter evidence: $mode', () async {
      await catalog.db.close();
      await open(automatic: true);
      const title = '雨夜故事', original = '雨夜の物語', alias = 'Stories on Rainy Nights';
      final differingDates = const {'broadcast-dates', 'two-date-outliers', 'duplicate-chapter-title'}.contains(mode);
      final continuous = mode.startsWith('continuous-seasons');
      final count = continuous ? 12 : differingDates ? 13 : 4;
      for (var n = 1; n <= count; n++) {
        if (mode == 'continuous-seasons-missing' && n == 6) continue;
        await video('$title/[Group] $alias - ${n.toString().padLeft(2, '0')} (BDRip 1080p).mkv');
      }
      String episodeTitle(int n) => '雨夜の章 ${mode == 'duplicate-chapter-title' && n == 3 ? 2 : n}';
      String episodeDate(int n, {bool bangumi = false}) {
        final gap = !bangumi || !differingDates ? 0 :
            n == 5 || (n == 6 && mode == 'two-date-outliers') ? 30 : 4;
        return DateTime.utc(2005, 10, 1)
            .add(Duration(days: (n - 1) * 7 + gap)).toIso8601String().split('T').first;
      }
      final tv = {
        'id': 701501, 'media_type': 'tv', 'name': title, 'original_name': original,
        'first_air_date': '2005-10-01',
        'seasons': [
          {'season_number': 1, 'episode_count': continuous ? 6 : count, 'air_date': '2005-10-01'},
          if (continuous) {'season_number': 2, 'episode_count': 6, 'air_date': '2005-11-12'},
        ],
      };
      final remake = {...tv, 'id': 701502, 'first_air_date': '2015-10-01'};
      var ready = false, narrow = 0, chapterQueries = 0;
      useTransport((request) async {
        final path = request.url.path;
        if (path.endsWith('/search/subjects')) {
          return reply({'total': 1, 'data': [{
            'id': 702501, 'type': 2, 'name': original, 'name_cn': title, 'date': '2005-10-01',
            'infobox': [{'key': '别名', 'value': alias}],
          }]});
        }
        if (path.endsWith('/search/multi')) {
          return reply({'results': [if (ready) ...[tv, remake]], 'total_pages': 1});
        }
        if (path.endsWith('/search/tv')) {
          narrow++;
          expect(request.url.queryParameters['query'], original);
          expect(request.url.queryParameters['first_air_date_year'], '2005');
          return reply({'total_pages': 1, 'results': [
            if (mode == 'different-title') {...tv, 'id': 701503} else tv,
            if (mode == 'same-year-collision') {...tv, 'id': 701504},
          ]});
        }
        if (path.endsWith('/tv/701501')) return reply(tv);
        if (path.endsWith('/season/1') || path.endsWith('/season/2')) {
          chapterQueries++;
          final season = path.endsWith('/season/2') ? 2 : 1;
          final offset = season == 2 ? 6 : 0;
          return reply({'season_number': season, 'episodes': [
            for (var n = 1; n <= (continuous ? 6 : count); n++)
              {'id': 100 + offset + n, 'season_number': season, 'episode_number': n,
                'name': continuous && offset + n == 7 ? '雨夜の大章 7' :
                    mode == 'different-chapter' && n == 2 ? '別の物語' : episodeTitle(offset + n),
                'air_date': episodeDate(offset + n)},
          ]});
        }
        if (path.endsWith('/episodes')) {
          return reply({'total': count, 'data': [
            for (var n = 1; n <= count; n++)
              {'id': 200 + n, 'type': 0, 'sort': n,
                'name': mode == 'continuous-seasons-wrong-title' && n == 7 ? '別の物語' : episodeTitle(n),
                'airdate': continuous ? '${episodeDate(n).replaceFirst('-', '年').replaceFirst('-', '月')}日' :
                    episodeDate(n, bangumi: true)},
          ]});
        }
        return reply({}, 404);
      });
      await scan();
      final work = catalog.works.single['id'] as String;
      expect(ScanRecognition.adopted(await record('bangumi', 'work'))?['id'], 702501);
      if (mode == 'continuous-seasons-locked') {
        await catalog.db.update('library_work_protection', {'identity_locked': 1},
            where: 'work_id=?', whereArgs: [work]);
      }
      ready = true;
      await runner.run(await runner.recognition.enqueue(source, work, retry: true), manualRetry: true);
      if (!continuous) expect(narrow, 1);
      final adopted = ScanRecognition.adopted(await record('tmdb', 'work'));
      if (mode == 'continuous-seasons') {
        expect(adopted?['id'], 701501);
        expect(await catalog.db.query('scan_file_groups'), hasLength(2));
        final episodes = await catalog.db.rawQuery("""
          SELECT b.adopted, a.episode AS local_episode FROM scan_bindings b
          JOIN assets a ON b.asset_id=a.id
          WHERE b.provider='tmdb' AND b.layer='episode' AND b.state='confirmed'
          ORDER BY a.episode
        """);
        expect(episodes, hasLength(count));
        for (final (index, row) in episodes.indexed) {
          final chapter = ScanRecognition.adopted(row)!;
          expect(chapter['season'], index ~/ 6 + 1);
          expect(chapter['episode'], index % 6 + 1);
          expect(chapter['chapter_id'], 101 + index);
        }
      } else if (mode == 'complete' || mode == 'broadcast-dates') {
        expect(adopted?['id'], 701501);
        expect(ScanRecognition.adopted(await record('tmdb', 'range'))?['season'], 1);
        expect(await catalog.db.query('scan_bindings',
            where: "provider='tmdb' AND layer='episode' AND state='confirmed'"), hasLength(count));
        if (mode == 'broadcast-dates') {
          final scope = ScanRecognition.adopted(await record('tmdb', 'range'));
          expect(scope?['chapter_verification']?['method'], 'complete_titles_broadcast_dates');
        }
      } else {
        expect(adopted, isNull);
        if (continuous) expect(await catalog.db.query('scan_file_groups'), isEmpty);
        if (mode == 'different-title' || mode == 'same-year-collision') expect(chapterQueries, 0);
      }
    });
  }

  for (final mode in ['complete', 'wrong-release', 'short-season', 'locked',
      'absolute-numbering', 'wrong-absolute-title']) {
    test('r7 verified Bangumi sequel supplies missing season evidence: $mode', () async {
      await catalog.db.close();
      await open(automatic: true);
      const folder = '全金属狂潮 Invisible Victory';
      const release = 'Full Metal Panic! Invisible Victory';
      final absolute = mode == 'absolute-numbering' || mode == 'wrong-absolute-title';
      for (var n = 1; n <= 12; n++) {
        final name = mode == 'wrong-release' ? 'Full Metal Panic!' : release;
        final number = n + (absolute ? 50 : 0);
        final label = absolute
            ? '[連続する原題 ${mode == 'wrong-absolute-title' && n == 5 ? 6 : n}]' : '';
        await video('$folder/[VCB-Studio] $name [${number.toString().padLeft(2, '0')}]$label[Ma10p_1080p][x265_flac].mkv');
      }
      var ready = false, chapters = 0;
      final series = {'id': 39379, 'media_type': 'tv', 'name': '全金属狂潮！',
        'original_name': 'フルメタル・パニック！', 'first_air_date': '2002-01-08',
        'alternative_titles': {'results': [
          {'title': 'Full Metal Panic!'},
          {'title': release},
        ]},
        'seasons': [
          {'season_number': 1, 'episode_count': 24, 'air_date': '2002-01-08'},
          {'season_number': 4, 'episode_count': 12, 'air_date': '2018-04-13'},
        ]};
      useTransport((request) async {
        final path = request.url.path;
        if (path.endsWith('/search/subjects')) return reply({'data': [{
          'id': 150246, 'type': 2, 'name': 'フルメタル・パニック! Invisible Victory',
          'name_cn': folder, 'date': '2018-04-13',
          'infobox': [{'key': '别名', 'value': release}],
        }], 'total': 1});
        if (path.endsWith('/search/multi')) return reply({
          'results': [if (ready) series], 'total_pages': 1,
        });
        if (path.endsWith('/tv/39379')) return reply(series);
        if (path.endsWith('/season/4')) {
          chapters++;
          return reply({'season_number': 4, 'episodes': [
            for (var i = 1; i <= (mode == 'short-season' ? 11 : 12); i++)
              {'id': i, 'season_number': 4, 'episode_number': i,
                'name': '連続する原題 $i', 'air_date': '2018-04-13'},
          ]});
        }
        if (path.endsWith('/episodes')) return reply({'total': 12, 'data': [
          for (var i = 1; i <= 12; i++)
            {'id': 200 + i, 'type': 0, 'sort': i,
              'name': '連続する原題 $i', 'airdate': '2018-04-13'},
        ]});
        return reply({}, 404);
      });
      await scan();
      final work = catalog.works.single['id'] as String;
      final bg = await record('bangumi', 'work');
      expect(ScanRecognition.adopted(bg)?['id'], 150246);
      if (mode == 'locked') {
        await catalog.db.update('library_work_protection', {'identity_locked': 1});
      }
      ready = true;
      await runner.run(await runner.recognition.enqueue(source, work, retry: true), manualRetry: true);
      final tv = await record('tmdb', 'work');
      expect(ScanRecognition.adopted(await record('bangumi', 'work'))?['id'], 150246);
      if (mode == 'complete' || mode == 'absolute-numbering') {
        expect(tv['reason'], 'verified_tv_chapters');
        final range = ScanRecognition.adopted(await record('tmdb', 'range'));
        expect(range?['season'], 4);
        expect(range?['offset'], absolute ? -50 : 0);
        expect(await catalog.db.query('scan_bindings',
            where: "provider='tmdb' AND layer='episode' AND state='confirmed'"), hasLength(12));
      } else if (mode == 'wrong-absolute-title') {
        expect(ScanRecognition.adopted(tv)?['id'], 39379);
        expect(await catalog.db.query('scan_bindings',
            where: "provider='tmdb' AND layer='episode' AND state='confirmed'"), isEmpty);
      } else {
        expect(ScanRecognition.adopted(tv), isNull);
        if (mode == 'locked' || mode == 'wrong-release') expect(chapters, 0);
      }
    });
  }

  for (final mode in ['marked', 'without_id', 'wrong_original', 'wrong_file', 'no_movie_label', 'year_conflict']) {
    test('movie subtitle corroboration uses both providers $mode', () async {
      await catalog.db.close();
      await open(automatic: true);
      final fixture = jsonDecode(await File('test/fixtures/milky_movie_identity.json').readAsString()) as Map;
      final movie = fixture['tmdb'] as Map, subject = fixture['bangumi'] as Map;
      if (mode == 'wrong_original') subject['name'] = '別の劇場作品';
      final folder = '${subject['name_cn']} (${mode == 'year_conflict' ? 2015 : 2016})${mode == 'without_id' ? '' : ' {tmdb-372762}'}';
      final name = mode == 'wrong_file' ? 'Gekijouban Unrelated Film' :
          '${mode == 'no_movie_label' ? '' : 'Gekijouban '}Tantei Opera Milky Holmes';
      await video('$folder/[ReinForce] $name (BDRip 1920x1080 x264 FLAC).mkv');
      useTransport((request) async {
        final path = request.url.path;
        if (path.endsWith('/movie/372762')) return reply(movie);
        if (path.endsWith('/search/multi')) return reply({'total_pages': 1, 'results': [{...movie, 'media_type': 'movie'}]});
        if (path.endsWith('/search/subjects')) return reply({'total': 1, 'data': [subject]});
        if (path.endsWith('/subjects/144465')) return reply(subject);
        if (path.endsWith('/episodes')) return reply(fixture['episodes']);
        return reply({}, 404);
      });
      await scan();
      final row = await record('tmdb', 'work');
      if (mode == 'marked' || mode == 'without_id') {
        expect(ScanRecognition.adopted(row)?['id'], 372762);
        final details = await ScanRecognition.details(catalog, (await catalog.db.query('works')).single);
        expect(details?['movieStill'], isNotNull);
      } else {
        expect(ScanRecognition.adopted(row), isNull);
      }
    });
  }

  for (final subjectId in [22756, 259070]) {
    for (final mode in ['complete', 'existing', 'rename_restore', 'mix_restore', 'delete_restore', 'wrong_file', 'date_conflict', 'ambiguous', 'failure', 'manual', 'locked']) {
      test('standalone special follows official parent $subjectId $mode', () async {
        await catalog.db.close();
        await open(automatic: true);
        final all = jsonDecode(await File('test/fixtures/milky_single_specials.json').readAsString()) as List;
        final fixture = all.singleWhere((r) => r['subject']['id'] == subjectId) as Map;
        final subject = fixture['subject'] as Map, file = fixture['file'] as Map;
        final path = file['relative_path'] as String;
        await video(mode == 'wrong_file' ? '${path.substring(0, path.lastIndexOf('/'))}/Unrelated Special.mkv' : path);
        var seed = ['existing', 'manual', 'locked'].contains(mode);
        Map<String, Object?>? protected;
        final requested = <String>[];
        useTransport((request) async {
          requested.add(request.url.toString());
          final p = request.url.path;
          if (p.endsWith('/search/subjects')) return reply({'total': 1, 'data': [subject]});
          if (p.endsWith('/subjects/$subjectId')) return reply(fixture['subject']);
          if (p.endsWith('/subjects/$subjectId/subjects')) return seed || mode == 'failure'
              ? reply({}, 503) : reply(fixture['relations']);
          if (p.endsWith('/search/multi')) {
            final q = request.url.queryParameters['query'];
            return reply({'total_pages': 1, 'results': [
              if (q == '探偵オペラ ミルキィホームズ' || q == '侦探歌剧 少女福尔摩斯')
                {...fixture['series'] as Map, 'media_type': 'tv'},
            ]});
          }
          if (p.endsWith('/tv/51492')) return reply(fixture['series']);
          if (p.endsWith('/episodes')) {
            final data = jsonDecode(jsonEncode(fixture['episodes'])) as Map;
            if (mode == 'date_conflict') data['data'][0]['airdate'] = '2000-01-01';
            return reply(data);
          }
          if (p.endsWith('/season/0')) {
            final data = jsonDecode(jsonEncode(fixture[request.url.queryParameters['language'] == 'ja-JP' ? 'ja' : 'en'])) as Map;
            if (mode == 'ambiguous') {
              final index = subjectId == 22756 ? 0 : 5;
              data['episodes'].add({...data['episodes'][index] as Map, 'id': 999999, 'episode_number': 7});
            }
            return reply(data);
          }
          return reply({}, 404);
        });
        await scan();
        if (seed) {
          final row = await record('bangumi', 'work');
          expect(row['state'], 'confirmed');
          if (mode == 'manual') {
            await runner.recognition.decide(await withToken(row), ScanRecognition.adopted(row)!);
            protected = await record('bangumi', 'work');
          } else if (mode == 'locked') {
            await catalog.db.update('library_work_protection', {'identity_locked': 1});
            protected = await record('bangumi', 'work');
          }
          seed = false;
          // Simulate retry after the recorded service cooldown, without
          // weakening production backoff or waiting on wall-clock time.
          await catalog.db.update('scrape_network', {'not_before': catalog.taskStore!.now - 1});
          await scan();
        }
        final episodes = await catalog.db.query('scan_bindings', where: "layer='episode' AND state='confirmed'");
        if (mode == 'complete' || mode == 'existing' || mode.endsWith('_restore')) {
          expect(episodes.length, 2, reason: '${await catalog.db.query('scan_bindings')}\n$requested');
          final tv = ScanRecognition.adopted(episodes.singleWhere((r) => r['provider'] == 'tmdb'))!;
          expect(tv['season'], 0);
          expect(tv['episode'], subjectId == 22756 ? 1 : 6);
          if (subjectId == 259070 && mode == 'complete') {
            final work = catalog.works.single;
            final details = (await ScanRecognition.details(catalog, work))!;
            final files = details['recognized_file_details'] as Map;
            final target = files.values.single as Map;
            expect(target['special_number'], 6);
            expect(target['localized_special_chapter'], 4644570);
            expect(catalog.standaloneParts[work['id']], isNull);
            final service = DetailMetadataService(tmdbRequest: (path, params) async {
              expect(path, '/tv/51492/season/0');
              expect(params['language'], 'zh-CN');
              return {'episodes': [
                {'id': 123, 'season_number': 0, 'episode_number': 6, 'name': '其他条目'},
                {'id': 4644570, 'season_number': 0, 'episode_number': 6, 'name': '心灵的问候'},
              ]};
            });
            try {
              expect(await service.localizedSpecialTitle(
                details['recognized_tmdb_id'] as int,
                target['special_number'] as int,
                target['localized_special_chapter'] as int,
                'zh-CN',
              ), '心灵的问候');
            } finally {
              service.close();
            }
          }
          expect(ScanRecognition.adopted(episodes.singleWhere((r) => r['provider'] == 'bangumi'))?['id'], fixture['episodes']['data'][0]['id']);
          final before = await catalog.db.query('scan_bindings', orderBy: 'id');
          await scan();
          expect(await catalog.db.query('scan_bindings', orderBy: 'id'), before);
          if (mode.endsWith('_restore')) {
            final original = File('${media.path}/$path');
            final otherPath = '${path.substring(0, path.lastIndexOf('/'))}/[Group] Different Anime - 01.mkv';
            if (mode == 'delete_restore') {
              await original.delete();
            } else if (mode == 'rename_restore') {
              await original.rename('${media.path}/$otherPath');
            } else {
              await video(otherPath);
            }
            await scan();
            expect(await catalog.db.query('scan_bindings',
                where: "layer='episode' AND state='confirmed'"), isEmpty);
            if (mode == 'delete_restore') {
              await video(path);
            } else if (mode == 'rename_restore') {
              await File('${media.path}/$otherPath').rename(original.path);
            } else {
              await File('${media.path}/$otherPath').delete();
            }
            await scan();
            final restored = await catalog.db.query('scan_bindings',
                where: "layer='episode' AND state='confirmed'");
            expect(restored.length, 2);
            expect(ScanRecognition.adopted(restored.singleWhere((r) => r['provider'] == 'tmdb'))?['episode'],
                subjectId == 22756 ? 1 : 6);
          }
        } else {
          expect(episodes, isEmpty);
          if (mode == 'failure') expect((await record('tmdb', 'work'))['reason'], 'request_failed');
          if (protected != null) expect(await record('bangumi', 'work'), protected);
        }
      });
    }
  }

  for (final fixtureName in ['milky_alternative_specials', 'milky_mixed_specials', 'synthetic_numbered_specials']) {
  for (final mode in ['complete', 'request_failure', 'rename_restore', 'mix_restore', 'manual_change', 'locked_change', 'date_conflict', if (fixtureName == 'milky_alternative_specials') 'wrong_subtitle', 'multiple_chapters']) {
  test('numbered standalone specials keep distinct provider chapter numbers $fixtureName $mode', () async {
    await catalog.db.close();
    await open(automatic: true);
    final sourceFixture = fixtureName == 'synthetic_numbered_specials' ? 'milky_alternative_specials' : fixtureName;
    var fixtureText = await File('test/fixtures/$sourceFixture.json').readAsString();
    if (fixtureName == 'synthetic_numbered_specials') {
      fixtureText = fixtureText.replaceAll('Milky Holmes', 'Amber Detectives')
          .replaceAll('ミルキィホームズ', '琥珀探偵').replaceAll('少女福尔摩斯', '琥珀侦探')
          .replaceAll('51492', '951492').replaceAll('8560', '908560')
          .replaceAll('47464', '947464').replaceAll('54728', '954728');
    }
    final fixtures = (jsonDecode(fixtureText) as List).cast<Map>();
    if (mode == 'date_conflict') {
      fixtures.last['subject']['date'] = '2001-01-01';
      fixtures.last['episodes']['data'][0]['airdate'] = '2001-01-01';
    }
    if (mode == 'wrong_subtitle') fixtures.last['subject']['name'] += ' 別の物語';
    if (mode == 'multiple_chapters') {
      final data = fixtures.last['episodes']['data'] as List;
      data.add({...data.first as Map, 'id': 999999, 'sort': 3});
      fixtures.last['episodes']['total'] = 2;
    }
    for (final fixture in fixtures) {
      await video(fixture['file']['relative_path'] as String);
    }
    useTransport((request) async {
      final path = request.url.path;
      if (path.endsWith('/search/subjects')) {
        final body = jsonDecode(request.body) as Map;
        final query = body['keyword'] as String;
        final matches = fixtures.where((f) => query == f['subject']['name_cn']).map((f) => f['subject']).toList();
        if (fixtureName == 'milky_mixed_specials' && mode == 'complete' && matches.isNotEmpty) {
          expect(request.url.queryParameters['offset'], isNull);
          if ((body['filter'] as Map)['air_date'] == null) {
            return reply({'total': 174, 'data': matches});
          }
        }
        return reply({'total': matches.length, 'data': matches});
      }
      for (final fixture in fixtures) {
        final id = fixture['subject']['id'];
        if (path.endsWith('/subjects/$id')) return reply(fixture['subject']);
        if (path.endsWith('/subjects/$id/subjects')) return mode == 'request_failure' ? reply({}, 503) : reply(fixture['relations']);
        if (path.endsWith('/episodes') && request.url.queryParameters['subject_id'] == '$id') return reply(fixture['episodes']);
      }
      if (path.endsWith('/search/multi')) {
        final q = request.url.queryParameters['query'];
        return reply({'total_pages': 1, 'results': [
          if (q == fixtures.first['series']['name'] ||
              q == fixtures.first['relations'][0]['name_cn'])
            {...fixtures.first['series'] as Map, 'media_type': 'tv'},
        ]});
      }
      if (path.endsWith('/tv/${fixtures.first['series']['id']}')) return reply(fixtures.first['series']);
      if (path.endsWith('/season/0')) return reply(fixtures.first[request.url.queryParameters['language'] == 'ja-JP' ? 'ja' : 'en']);
      return reply({}, 404);
    });
    await scan();
    final episodes = await catalog.db.query('scan_bindings', where: "layer='episode' AND state='confirmed'");
    if (['request_failure', 'date_conflict', 'wrong_subtitle', 'multiple_chapters'].contains(mode)) {
      expect(episodes, isEmpty);
      expect(await catalog.db.query('scan_file_groups'), isEmpty);
      if (mode == 'request_failure') {
        for (final provider in ['tmdb', 'bangumi']) {
          expect((await record(provider, 'work'))['reason'], 'request_failed');
        }
      }
      return;
    }
    expect(episodes, hasLength(4));
    expect(catalog.standaloneParts.values.single.map((part) => part['bangumi_subject']),
        unorderedEquals(fixtures.map((f) => f['subject']['id'])));
    final assets = await catalog.db.query('assets');
    for (final fixture in fixtures) {
      final asset = assets.singleWhere((a) => a['relative_path'] == fixture['file']['relative_path']);
      final selections = {for (final row in episodes.where((r) => r['asset_id'] == asset['id']))
        row['provider']: ScanRecognition.adopted(row)!};
      expect(selections['tmdb']?['season'], 0);
      expect(selections['tmdb']?['episode'], fixture['expected_tmdb_episode']);
      expect(selections['bangumi']?['subject'], fixture['subject']['id']);
      expect(selections['bangumi']?['id'], fixture['episodes']['data'][0]['id']);
      expect(selections['bangumi']?['sort'], fixture['expected_bangumi_sort']);
    }
    final before = await catalog.db.query('scan_bindings', orderBy: 'id');
    await scan();
    expect(await catalog.db.query('scan_bindings', orderBy: 'id'), before);
    if (mode.endsWith('_restore') || mode.endsWith('_change')) {
      final path = fixtures.first['file']['relative_path'] as String;
      final otherPath = '${path.substring(0, path.lastIndexOf('/'))}/[Group] Unrelated Anime - 03.mkv';
      Map<String, Object?>? protected;
      if (mode == 'manual_change') {
        final episode = episodes.first;
        await runner.recognition.decide(await withToken(episode), ScanRecognition.adopted(episode)!);
        protected = (await catalog.db.query('scan_bindings', where: 'id=?', whereArgs: [episode['id']])).single;
      } else if (mode == 'locked_change') {
        await catalog.db.update('library_work_protection', {'identity_locked': 1});
        protected = episodes.first;
      }
      if (mode == 'mix_restore') {
        await video(otherPath);
      } else {
        await File('${media.path}/$path').rename('${media.path}/$otherPath');
      }
      await scan();
      if (protected != null) {
        expect((await catalog.db.query('scan_bindings', where: 'id=?', whereArgs: [protected['id']])).single, protected);
        return;
      }
      expect(await catalog.db.query('scan_bindings', where: "layer='episode' AND state='confirmed'"), isEmpty);
      expect(await catalog.db.query('scan_file_groups'), isEmpty);
      if (mode == 'mix_restore') {
        await File('${media.path}/$otherPath').delete();
      } else {
        await File('${media.path}/$otherPath').rename('${media.path}/$path');
      }
      await scan();
      expect(await catalog.db.query('scan_bindings', where: "layer='episode' AND state='confirmed'"), hasLength(4));
    }
  });
  }
  }

  test('no-ID filenames supply candidates without overriding conflicting folder', () async {
    await catalog.db.close();
    await open(automatic: true);
    await video('人生 (2014)/[G] Break Blade - 01.mkv');
    final queries = <String>[];
    final bangumiQueries = <String>[];
    useTransport((request) async {
      if (request.url.path.endsWith('/search/subjects')) {
        final query = (jsonDecode(request.body) as Map)['keyword'] as String;
        bangumiQueries.add(query);
        return reply({'data': query == 'Break Blade' ? [
          {'id': 20, 'type': 2, 'name': 'Break Blade', 'date': '2014-01-01'}
        ] : [], 'total': query == 'Break Blade' ? 1 : 0});
      }
      if (request.url.path.endsWith('/search/multi')) {
        final query = request.url.queryParameters['query']!;
        queries.add(query);
        return reply({'results': query == 'Break Blade' ? [
          {'id': 10, 'media_type': 'tv', 'name': 'Break Blade', 'first_air_date': '2014-01-01'}
        ] : [], 'total_pages': 1});
      }
      return reply({'data': [], 'total': 0});
    });
    await scan();
    expect(queries, contains('Break Blade'));
    expect(bangumiQueries, contains('Break Blade'));
    final row = await record('tmdb', 'work');
    expect(ScanRecognition.candidates(row).map((c) => c['id']), contains(10));
    expect(row['state'], 'pending');
    expect(ScanRecognition.adopted(row), isNull);
    final bangumi = await record('bangumi', 'work');
    expect(ScanRecognition.candidates(bangumi).map((c) => c['id']), contains(20));
    expect(bangumi['state'], 'pending');
    expect(ScanRecognition.adopted(bangumi), isNull);
  });

  test('wrong directory cannot confirm Bangumi when only TMDB finds filename work', () async {
    await catalog.db.close();
    await open(automatic: true);
    for (final number in ['01', '02']) {
      await video('人生 (2014)/[ReinForce] Break Blade - $number.mkv');
    }
    useTransport((request) async {
      if (request.url.path.endsWith('/search/subjects')) {
        final query = (jsonDecode(request.body) as Map)['keyword'];
        return reply({'data': query == '人生' ? [
          {'id': 92430, 'type': 2, 'name': '人生', 'date': '2014-07-06'}
        ] : [], 'total': query == '人生' ? 1 : 0});
      }
      if (request.url.path.endsWith('/search/multi')) {
        final filename = request.url.queryParameters['query'] == 'Break Blade';
        return reply({'results': [{'id': filename ? 44163 : 60993,
          'media_type': 'tv', 'name': filename ? 'Break Blade' : '人生',
          'first_air_date': '2014-04-06'}], 'total_pages': 1});
      }
      if (request.url.path.endsWith('/tv/44163')) {
        return reply({'id': 44163, 'name': 'Break Blade', 'first_air_date': '2014-04-06',
          'seasons': [{'season_number': 1, 'episode_count': 12, 'air_date': '2014-04-06'}]});
      }
      return reply({}, 404);
    });
    await scan();
    final bg = await record('bangumi', 'work');
    expect(bg['state'], 'pending');
    expect(bg['reason'], 'conflicting_title');
    expect(ScanRecognition.adopted(bg), isNull);
    expect(ScanRecognition.candidates(await record('tmdb', 'work')).map((r) => r['id']), contains(44163));
    await runner.recognition.decide(await withToken(bg), {
      'id': 95618, 'type': 'anime', 'title': '破刃之剑', 'year': 2014,
    });
    final manual = (await catalog.db.query('scan_bindings', where: 'id=?', whereArgs: [bg['id']])).single;
    await video('人生 (2014)/[ReinForce] Break Blade - 03.mkv');
    await scan();
    expect(await catalog.db.query('scan_bindings', where: 'id=?', whereArgs: [bg['id']]), [manual]);
  });

  for (final sample in ['review-011', 'review-013', 'review-015', 'milky-01', 'milky-02', 'milky-03', 'milky-04']) {
    for (final scenario in ['complete', 'network_recovery', if (sample == 'milky-04') ...[
      'network_locked', 'network_manual', 'network_tmdb_recovery', 'network_bg_recovery',
      'network_incomplete_recovery', 'network_invalid_recovery', 'network_manual_retry_recovery', 'without_id_no_year',
      'without_id', 'date_conflict', 'changed_id', 'wrong_title', 'unknown_alias', 'wrong_sequel',
      'disc_delete', 'disc_rename', 'disc_mix', 'disc_manual', 'disc_locked'],
      if (sample.startsWith('milky-') && sample != 'milky-04') ...[
      'existing', 'manual_bg', 'manual_episode', 'locked', 'date_conflict', 'changed_id',
      'wrong_title', 'reordered', 'multiple_errors', 'unknown_alias', 'wrong_sequel', 'without_id',
      if (sample != 'milky-01') 'without_id_alias_conflict',
      if (sample == 'milky-02') 'without_id_stem'], if (sample == 'review-011') ...[
      'marked', 'existing_marked', 'existing', 'manual_bg', 'manual_tmdb', 'manual_episode', 'locked', 'late_manual', 'late_lock',
      'unknown_alias', 'date_conflict', 'changed_id', 'incomplete', 'failure']]) {
      test('ordinary TV aliases and original chapters $sample $scenario', () async {
        await catalog.db.close();
        await open(automatic: true);
        final fixtures = jsonDecode(await File('test/fixtures/ordinary_tv_identity.json').readAsString()) as List;
        fixtures.addAll(jsonDecode(await File('test/fixtures/milky_regular_identity.json').readAsString()) as List);
        final fixture = fixtures.singleWhere((r) => r['key'] == sample) as Map;
        final tmdb = fixture['tmdb'] as Map, bg = fixture['bangumi'] as Map;
        if (scenario == 'without_id_alias_conflict') bg['name'] = 'Unrelated original title';
        for (final input in fixture['files'] as List) {
          var path = '${input['path']}/${input['name']}'.replaceFirst('/${input['root']}/', '');
          if (scenario.startsWith('without_id')) path = path.replaceAll(RegExp(r'\s*\{tmdb-\d+\}'), '');
          if (scenario == 'without_id_no_year') path = path.replaceAll(RegExp(r'\s*\(2015\)'), '');
          await video(scenario.contains('marked') ? path.replaceFirst('/', ' {tmdb-${tmdb['id']}}/') : path);
        }
        if (scenario == 'unknown_alias' || scenario == 'wrong_sequel') {
          final input = fixture['files'][0] as Map;
          final path = '${input['path']}/${input['name']}'.replaceFirst('/${input['root']}/', '');
          final file = File('${media.path}/$path');
          await file.rename('${file.parent.path}/${scenario == 'wrong_sequel' ? 'Tantei Opera Milky Holmes III' : 'Unverified Work'} - 01.mkv');
        }
        var seed = ['existing_marked', 'existing', 'manual_bg', 'manual_tmdb', 'manual_episode', 'locked'].contains(scenario);
        Map<String, Object?>? manualRow;
        var originalQueries = 0;
        var offline = scenario.startsWith('network_');
        useTransport((request) async {
          if (offline && (scenario == 'network_tmdb_recovery' ? request.url.host.contains('themoviedb') :
              scenario == 'network_bg_recovery' ? request.url.host == 'api.bgm.tv' : true)) return reply({}, 503);
          final path = request.url.path;
          if (path.endsWith('/search/multi')) {
            return reply({'results': [
              if (scenario != 'without_id_stem' || request.url.queryParameters['query'] == '探偵オペラ ミルキィホームズ')
                {...tmdb, 'media_type': 'tv'}], 'total_pages': 1});
          }
          if (path.endsWith('/search/subjects')) return reply({'data': [bg], 'total': 1});
          if (path.endsWith('/tv/${tmdb['id']}')) return reply(tmdb);
          if (path.endsWith('/subjects/${bg['id']}')) return reply(bg);
          if (path.endsWith('/season/${fixture['season']['season_number']}')) {
            final original = request.url.queryParameters['language'] == 'ja-JP';
            if (original) originalQueries++;
            if (original && scenario == 'failure') return reply({}, 503);
            final body = jsonDecode(jsonEncode(fixture['season'])) as Map;
            if (!original) {
              for (final e in body['episodes']) { e['name'] = 'Localized episode ${e['episode_number']}'; }
            } else if (scenario == 'changed_id') {
              body['episodes'][0]['id'] = 999999;
            }
            return reply(body);
          }
          if (path.endsWith('/episodes')) {
            if (scenario == 'late_lock') await catalog.db.update('library_work_protection', {'identity_locked': 1});
            if (scenario == 'late_manual' && manualRow == null) {
              final row = await record('bangumi', 'work');
              await runner.recognition.decide(await withToken(row),
                  {'id': bg['id'], 'type': 'anime', 'title': bg['name_cn']});
              manualRow = await record('bangumi', 'work');
            }
            final body = jsonDecode(jsonEncode(fixture['episodes'])) as Map;
            if (seed) for (final e in body['data']) { e['name'] = 'Unverified ${e['sort']}'; }
            if (scenario == 'date_conflict') body['data'][0]['airdate'] = '2000-01-01';
            if (scenario == 'wrong_title') body['data'][0]['name'] = '別の作品のエピソード';
            if (scenario == 'multiple_errors') {
              for (var i = 0; i < 3; i++) { body['data'][i]['airdate'] = '2000-01-01'; }
            }
            if (scenario == 'reordered') {
              final first = body['data'][0]['name'];
              body['data'][0]['name'] = body['data'][1]['name'];
              body['data'][1]['name'] = first;
            }
            if (scenario == 'incomplete') body['total'] = (body['total'] as int) + 1;
            return reply(body);
          }
          return reply({}, 404);
        });
        await scan();
        if (offline) {
          for (final provider in ['tmdb', 'bangumi']) {
            if (scenario == 'network_tmdb_recovery' && provider == 'bangumi' ||
                scenario == 'network_bg_recovery' && provider == 'tmdb') continue;
            expect((await record(provider, 'work'))['reason'], 'request_failed');
          }
          if (scenario == 'network_locked') {
            await catalog.db.update('library_work_protection', {'identity_locked': 1});
          } else if (scenario == 'network_manual') {
            final row = await record('bangumi', 'work');
            await runner.recognition.decide(await withToken(row),
                {'id': bg['id'], 'type': 'anime', 'title': bg['name_cn']});
            manualRow = await record('bangumi', 'work');
          }
          if (scenario == 'network_incomplete_recovery' || scenario == 'network_invalid_recovery') {
            // Persisted partial-query states must be eligible for a fresh explicit scan.
            await catalog.db.update('scan_bindings',
                {'reason': scenario == 'network_incomplete_recovery' ? 'query_incomplete' : 'invalid_response'},
                where: "layer='work' AND state='pending'");
          }
          offline = false;
          if (scenario == 'network_manual_retry_recovery') {
            // Exercise the UI's retry chain without expiring or deleting cooldowns.
            expect(await catalog.db.query('scrape_network'), isNotEmpty);
            final currentWork = (await catalog.db.query('works')).single;
            final id = await runner.recognition.enqueue(source, currentWork['id'] as String, retry: true);
            await runner.run(id, manualRetry: true);
          } else {
            await catalog.db.update('scrape_network', {'not_before': catalog.taskStore!.now - 1});
            await scan();
          }
        }
        if (seed) {
          expect(ScanRecognition.adopted(await record('tmdb', 'work'))?['id'], tmdb['id']);
          expect(ScanRecognition.adopted(await record('bangumi', 'work'))?['id'], bg['id']);
          expect((await catalog.db.query('scan_bindings', where: "provider='bangumi' AND layer='episode' AND state='confirmed'")), isEmpty);
          if (scenario.startsWith('manual_')) {
            final provider = scenario == 'manual_bg' ? 'bangumi' : 'tmdb';
            final row = scenario == 'manual_episode' ? await withToken((await catalog.db.query('scan_bindings',
                where: "provider='tmdb' AND layer='episode' AND state='confirmed'", limit: 1)).single) : await record(provider, 'work');
            await runner.recognition.decide(await withToken(row), ScanRecognition.adopted(row)!);
            manualRow = await record(provider, row['layer'] as String, scope: row['scope'] as String);
          } else if (scenario == 'locked') {
            await catalog.db.update('library_work_protection', {'identity_locked': 1});
          }
          seed = false;
          await scan();
        }
        final episodes = await catalog.db.query('scan_bindings', where: "provider='bangumi' AND layer='episode' AND state='confirmed'");
        if (sample == 'milky-03' && scenario == 'complete') {
          final details = await ScanRecognition.details(catalog, (await catalog.db.query('works')).single);
          final displayed = (details!['recognized_file_details'] as Map).values.cast<Map>();
          expect(displayed.every((row) => '${row['name']}'.startsWith('Localized episode ')), isTrue);
          final fileDetails = details['recognized_file_details'] as Map;
          final withStill = fileDetails.entries.firstWhere((entry) => entry.value['still'] is String);
          await catalog.progress(withStill.key as String, 8000, 1200000);
          final history = (await PlaybackHistory(catalog.db).entries()).single;
          expect(history['_recognized_still'], withStill.value['still']);
        }
        if (scenario == 'complete' || scenario.endsWith('_recovery') || scenario == 'existing' || scenario == 'without_id' || scenario == 'without_id_no_year' || scenario == 'without_id_stem' || scenario.contains('marked') || scenario.startsWith('disc_')) {
          expect(originalQueries, greaterThan(0));
          expect(episodes.length, (fixture['episodes']['data'] as List).length);
          final assets = await catalog.db.query('assets');
          for (final row in episodes) {
            final chosen = ScanRecognition.adopted(row)!;
            expect(chosen['sort'], assets.singleWhere((a) => a['id'] == row['asset_id'])['episode']);
            final expected = (fixture['episodes']['data'] as List).singleWhere((e) => e['sort'] == chosen['sort']);
            expect(chosen['id'], expected['id']);
            expect(chosen['subject'], bg['id']);
          }
          final tvEpisodes = await catalog.db.query('scan_bindings', where: "provider='tmdb' AND layer='episode' AND state='confirmed'");
          expect(ScanRecognition.adopted(tvEpisodes.first)!['title'], startsWith('Localized episode '));
          for (final row in tvEpisodes) {
            final localNumber = assets.singleWhere((a) => a['id'] == row['asset_id'])['episode'];
            expect(ScanRecognition.adopted(row)!['episode'],
                (fixture['tmdb_episode_by_sort'] as Map?)?['$localNumber'] ?? localNumber);
          }
          for (final zero in assets.where((a) => a['episode'] == 0)) {
            expect(episodes.where((e) => e['asset_id'] == zero['id']), isEmpty);
          }
          final before = await catalog.db.query('scan_bindings', orderBy: 'id');
          await scan();
          expect(await catalog.db.query('scan_bindings', orderBy: 'id'), before);
          if (scenario.startsWith('disc_')) {
            if (scenario == 'disc_manual') {
              final row = await withToken(tvEpisodes.first);
              await runner.recognition.decide(row, ScanRecognition.adopted(row)!);
            } else if (scenario == 'disc_locked') {
              await catalog.db.update('library_work_protection', {'identity_locked': 1});
            }
            final protected = await catalog.db.query('scan_bindings', orderBy: 'id');
            final input = fixture['files'][4] as Map;
            final path = '${input['path']}/${input['name']}'.replaceFirst('/${input['root']}/', '');
            final file = File('${media.path}/$path');
            final originalBytes = await file.readAsBytes();
            final changed = File('${file.parent.path}/Other Work - 05.mkv');
            if (scenario == 'disc_rename') {
              await file.rename(changed.path);
            } else if (scenario == 'disc_mix') {
              await changed.writeAsBytes([0]);
            } else {
              await file.delete();
            }
            await scan();
            if (scenario == 'disc_manual' || scenario == 'disc_locked') {
              expect(await catalog.db.query('scan_bindings', orderBy: 'id'), protected);
            } else {
              expect(await catalog.db.query('scan_bindings', where: "layer='episode' AND state='confirmed'"), isEmpty);
            }
            if (scenario == 'disc_rename') {
              await changed.rename(file.path);
            } else if (scenario == 'disc_mix') {
              await changed.delete();
            } else {
              await file.writeAsBytes(originalBytes);
            }
            await scan();
            if (scenario == 'disc_manual' || scenario == 'disc_locked') {
              expect(await catalog.db.query('scan_bindings', orderBy: 'id'), protected);
            } else {
              final restored = await catalog.db.query('scan_bindings', where: "layer='episode' AND state='confirmed'");
              expect(restored.length, 24);
              for (final row in restored.where((r) => r['provider'] == 'tmdb')) {
                final localNumber = assets.singleWhere((a) => a['id'] == row['asset_id'])['episode'];
                expect(ScanRecognition.adopted(row)!['episode'],
                    (fixture['tmdb_episode_by_sort'] as Map)['$localNumber'] ?? localNumber);
              }
            }
          }
        } else {
          expect(episodes, isEmpty);
          if (manualRow != null) {
            expect(await record(manualRow!['provider'] as String,
                manualRow!['layer'] as String, scope: manualRow!['scope'] as String), manualRow);
          }
        }
      });
    }
  }

  for (final mode in ['complete', 'missing', 'mixed', 'chapter_conflict', 'year_conflict', 'failure', 'manual', 'manual_tmdb', 'late_manual', 'locked', 'manual_range',
    'bound', 'bound_both', 'bound_manual', 'bound_locked', 'bound_legacy_lock', 'bound_unknown',
    'bound_failure', 'bound_missing', 'bound_late_manual', 'bound_late_lock', 'bound_children', 'bound_child_manual', 'bound_rollback',
    for (final change in ['delete', 'rename', 'renumber', 'mixed', 'cosmetic'])
      for (final protection in ['auto', 'manual', 'locked',
        if (change == 'delete') ...['afterManual', 'afterLocked', 'failure', 'lateLocked', 'lateManual', 'chapterConflict']])
        'bound_rescan_${change}_$protection']) {
    test('wrong directory corrected only with complete Break Blade evidence: $mode', () async {
      await catalog.db.close();
      await open(automatic: true);
      final fixture = jsonDecode(await File('test/fixtures/breakblade_identity.json').readAsString()) as Map;
      for (var n = 1; n <= (mode.endsWith('missing') ? 11 : 12); n++) {
        await video('人生 (2014)/[ReinForce] ${mode == 'mixed' && n == 12 ? 'Jinsei' : 'Break Blade'} - ${n.toString().padLeft(2, '0')} (BDRip 1920x1080 x264 FLAC).mkv');
      }
      await video('人生 (2014)/Extras/[ReinForce] Break Blade - NCOP.mkv');
      Map<String, Object?>? manual;
      List<Map<String, Object?>>? originalBindings;
      final manualProvider = mode == 'manual_tmdb' ? 'tmdb' : 'bangumi';
      if (mode == 'manual' || mode == 'manual_tmdb' || mode.startsWith('bound')) {
        useTransport((request) async => reply(request.url.path.contains('/3/')
            ? {'results': [], 'total_pages': 1} : {'data': [], 'total': 0}));
        await scan();
        final row = await record(manualProvider, 'work');
        await runner.recognition.decide(await withToken(row), {'id': manualProvider == 'tmdb' ? 60993 : 92430, 'type': manualProvider == 'tmdb' ? 'tv' : 'anime', 'title': '人生', 'year': 2014});
        manual = await record(manualProvider, 'work');
        if (mode.startsWith('bound')) {
          final choice = ScanRecognition.adopted(manual)!;
          if (mode != 'bound_manual') {
            await catalog.db.update('scan_bindings', {
              'reason': 'verified_bangumi',
              'adopted': jsonEncode({...choice, 'by': mode == 'bound_unknown' ? 'unknown' : 'verified_bangumi'}),
            }, where: 'id=?', whereArgs: [manual['id']]);
          }
          if (mode == 'bound_locked' || mode == 'bound_legacy_lock') {
            await catalog.db.update('library_work_protection', {mode == 'bound_locked' ? 'identity_locked' : 'legacy_lock': 1});
          }
          if (mode == 'bound_children' || mode == 'bound_child_manual') {
            final range = await record('bangumi', 'range');
            await catalog.db.update('scan_bindings', {
              'state': 'confirmed', 'reason': mode == 'bound_child_manual' ? 'manual_confirmed' : 'verified_tv_chapters',
              'adopted': jsonEncode({'id': 92430, 'offset': 0,
                'by': mode == 'bound_child_manual' ? 'user' : 'verified_tv_chapters'}),
            }, where: 'id=?', whereArgs: [range['id']]);
          }
          originalBindings = await catalog.db.query('scan_bindings', orderBy: 'id');
          if (mode == 'bound_both') {
            final row = await record('tmdb', 'work');
            await runner.recognition.decide(await withToken(row),
                {'id': 60993, 'type': 'tv', 'title': '人生', 'year': 2014});
            final chosen = await record('tmdb', 'work');
            await catalog.db.update('scan_bindings', {'reason': 'verified_tmdb',
              'adopted': jsonEncode({...ScanRecognition.adopted(chosen)!, 'by': 'verified_tmdb'})},
              where: 'id=?', whereArgs: [chosen['id']]);
            originalBindings = await catalog.db.query('scan_bindings', orderBy: 'id');
          }
          manual = null;
        }
      }
      if (mode == 'year_conflict') fixture['bangumi']['date'] = '2015-04-06';
      if (mode == 'bound_rollback') {
        // Fetches are complete and pairwise equal, but the final independent
        // title-diversity guard must reject this and restore every old row.
        for (final row in fixture['season']['episodes'] as List) {
          row['name'] = '同じ題名';
        }
        for (final row in fixture['episodes']['data'] as List) {
          row['name'] = '同じ題名';
        }
      }
      Map<String, Object?>? protectedRange;
      var restoringFiles = false;
      var restoreFailure = false;
      var restoreRequests = 0;
      useTransport((request) async {
        if (restoringFiles) restoreRequests++;
        final path = request.url.path;
        if (path.endsWith('/search/subjects')) {
          final q = (jsonDecode(request.body) as Map)['keyword'] as String;
          final rows = q == '人生' ? [{'id': 92430, 'type': 2, 'name': '人生', 'date': '2014-07-06'}]
              : q.contains('ブレイク') || q == '破刃之剑' ? [fixture['bangumi']] : [];
          return reply({'data': rows, 'total': rows.length});
        }
        if (path.endsWith('/search/multi')) {
          final filename = request.url.queryParameters['query'] == 'Break Blade';
          return reply({'results': [filename ? {...fixture['tmdb'] as Map, 'media_type': 'tv'}
              : {'id': 60993, 'media_type': 'tv', 'name': '人生', 'first_air_date': '2014-07-06'}], 'total_pages': 1});
        }
        if (path.endsWith('/tv/44163')) return reply(fixture['tmdb']);
        if (path.endsWith('/tv/60993')) return reply({'id': 60993, 'name': '人生', 'first_air_date': '2014-07-06', 'seasons': []});
        if (path.endsWith('/subjects/95618')) return reply(fixture['bangumi']);
        if (path.endsWith('/season/1')) {
          if (mode == 'failure' || mode == 'bound_failure' || restoreFailure) return reply({}, 503);
          return reply(fixture['season']);
        }
        if (path.endsWith('/episodes')) {
          if (restoringFiles && mode.endsWith('_lateLocked')) {
            await catalog.db.update('library_work_protection', {'identity_locked': 1});
          }
          if (restoringFiles && mode.endsWith('_lateManual') && manual == null) {
            final row = await record('bangumi', 'work');
            await runner.recognition.decide(await withToken(row),
                {'id': 95618, 'type': 'anime', 'title': '破刃之剑', 'year': 2014});
            manual = await record('bangumi', 'work');
          }
          if (mode == 'locked' || mode == 'bound_late_lock') {
            await catalog.db.update('library_work_protection', {'identity_locked': 1});
          }
          if (mode == 'manual_range') {
            final row = await record('bangumi', 'work');
            protectedRange = {...row, 'id': 'manual-range-fixture', 'layer': 'range', 'scope': '',
              'parent': 'previous-identity', 'state': 'confirmed', 'reason': 'manual_confirmed',
              'adopted': jsonEncode({'id': 92430, 'by': 'manual_confirmed'})}
              ..remove('session')
              ..remove('identity_revision');
            await catalog.db.insert('scan_bindings', protectedRange!);
          }
          if ((mode == 'late_manual' || mode == 'bound_late_manual') && manual == null) {
            final row = await record('bangumi', 'work');
            await runner.recognition.decide(await withToken(row), {'id': 92430, 'type': 'anime', 'title': '人生', 'year': 2014});
            manual = await record('bangumi', 'work');
          }
          if (mode == 'chapter_conflict' || restoringFiles && mode.endsWith('_chapterConflict')) {
            fixture['episodes']['data'][0]['name'] = '別の話';
          }
          return reply(fixture['episodes']);
        }
        return reply({}, 404);
      });
      await scan();
      if (manual != null) {
        expect(await record(manualProvider, 'work'), manual);
        expect(ScanRecognition.adopted(await record(manualProvider == 'tmdb' ? 'bangumi' : 'tmdb', 'work')), isNull);
      } else if (mode == 'complete' || mode == 'bound' || mode == 'bound_both' || mode == 'bound_children' || mode.startsWith('bound_rescan_')) {
        expect(ScanRecognition.adopted(await record('tmdb', 'work'))?['id'], 44163);
        expect(ScanRecognition.adopted(await record('bangumi', 'work'))?['id'], 95618);
        final episodes = await catalog.db.query('scan_bindings', where: "layer='episode' AND state='confirmed'");
        expect(episodes.length, 24);
        expect(episodes.where((e) => e['provider'] == 'tmdb').map((e) => ScanRecognition.adopted(e)!['episode']).toSet(), {for (var n = 1; n <= 12; n++) n});
        if (originalBindings != null) {
          final identity = await record('bangumi', 'work');
          expect((jsonDecode(identity['previous'] as String) as Map)['id'], 92430);
          final stale = originalBindings.singleWhere((r) => r['layer'] == 'work' && r['provider'] == 'bangumi');
          await expectLater(runner.recognition.decide(await withToken(stale),
              {'id': 92430, 'type': 'anime', 'title': '人生', 'year': 2014}), throwsStateError);
          final all = await catalog.db.query('scan_bindings');
          for (final row in all.where((r) => r['parent'] != null)) {
            final token = jsonDecode(row['parent'] as String) as List;
            final parent = all.singleWhere((r) => r['id'] == token[0]);
            expect(parent['revision'], token[1]);
          }
        }
        final confirmed = await catalog.db.query('scan_bindings', orderBy: 'id');
        await scan();
        expect(ScanRecognition.adopted(await record('bangumi', 'work'))?['id'], 95618);
        expect(await catalog.db.query('scan_bindings', orderBy: 'id'), confirmed);
        if (mode.startsWith('bound_rescan_')) {
          final change = mode.split('_')[2], protection = mode.split('_')[3];
          final protectedInitially = ['manual', 'locked'].contains(protection);
          if (protection == 'manual') {
            final identity = await record('bangumi', 'work');
            await runner.recognition.decide(await withToken(identity), ScanRecognition.adopted(identity)!);
          } else if (protection == 'locked') {
            await catalog.db.update('library_work_protection', {'identity_locked': 1});
          }
          final before = await catalog.db.query('scan_bindings', orderBy: 'id');
          final target = File('${media.path}/人生 (2014)/[ReinForce] Break Blade - 12 (BDRip 1920x1080 x264 FLAC).mkv');
          if (change == 'delete') {
            await target.delete();
          } else if (change == 'rename') {
            await target.rename('${media.path}/人生 (2014)/[ReinForce] Jinsei - 12.mkv');
          } else if (change == 'renumber') {
            await target.rename('${media.path}/人生 (2014)/[ReinForce] Break Blade - 13.mkv');
          } else if (change == 'mixed') {
            await video('人生 (2014)/[Other] Jinsei - 13.mkv');
          } else {
            await target.rename('${media.path}/人生 (2014)/[Other] Break Blade - 12.mkv');
          }
          await scan();
          final after = await catalog.db.query('scan_bindings', orderBy: 'id');
          if (protectedInitially) {
            expect(after.where((r) => r['state'] == 'confirmed').length,
                before.where((r) => r['state'] == 'confirmed').length);
            for (final old in before.where((r) => r['state'] == 'confirmed')) {
              expect(after.singleWhere((r) => r['id'] == old['id']), old);
            }
          } else if (change != 'cosmetic') {
            expect(after.where((r) => r['state'] == 'confirmed'), isEmpty);
            expect(after.where((r) => r['layer'] == 'work').every((r) =>
                r['reason'] == 'corrected_inventory_changed' && r['previous'] != null), isTrue);
          } else {
            expect(ScanRecognition.adopted(await record('bangumi', 'work'))?['id'], 95618);
          }
          await scan();
          expect(await catalog.db.query('scan_bindings', orderBy: 'id'), after);
          if (protection == 'afterManual') {
            final row = await record('bangumi', 'work');
            await runner.recognition.decide(await withToken(row),
                {'id': 95618, 'type': 'anime', 'title': '破刃之剑', 'year': 2014});
          } else if (protection == 'afterLocked') {
            await catalog.db.update('library_work_protection', {'identity_locked': 1});
          }
          final protectedSnapshot = await catalog.db.query('scan_bindings', orderBy: 'id');
          if (change == 'delete') {
            await video('人生 (2014)/[ReinForce] Break Blade - 12 (BDRip 1920x1080 x264 FLAC).mkv');
          } else if (change == 'rename') {
            await File('${media.path}/人生 (2014)/[ReinForce] Jinsei - 12.mkv').rename(target.path);
          } else if (change == 'renumber') {
            await File('${media.path}/人生 (2014)/[ReinForce] Break Blade - 13.mkv').rename(target.path);
          } else if (change == 'mixed') {
            await File('${media.path}/人生 (2014)/[Other] Jinsei - 13.mkv').delete();
          } else {
            await File('${media.path}/人生 (2014)/[Other] Break Blade - 12.mkv').rename(target.path);
          }
          restoringFiles = true;
          restoreFailure = protection == 'failure';
          await scan();
          if (protection == 'failure') {
            expect(restoreRequests, greaterThan(0));
            expect(await catalog.db.query('scan_bindings', orderBy: 'id'), after);
            restoreFailure = false;
            // An explicit rescan must still respect the provider cooldown.
            await scan();
            expect(await catalog.db.query('scan_bindings', orderBy: 'id'), after);
            // Simulate cooldown expiry in this isolated fixture, not product code.
            await catalog.db.update('scrape_network', {'not_before': catalog.taskStore!.now - 1});
            await scan();
          }
          final restored = await catalog.db.query('scan_bindings', orderBy: 'id');
          if (['afterManual', 'afterLocked'].contains(protection)) {
            expect(restored, protectedSnapshot);
            expect(restoreRequests, 0);
          } else if (protection == 'lateLocked' || protection == 'chapterConflict') {
            expect(restored, after);
            expect(restoreRequests, greaterThan(0));
          } else if (protection == 'lateManual') {
            expect(await record('bangumi', 'work'), manual);
            expect(ScanRecognition.adopted(await record('tmdb', 'work')), isNull);
          } else if (protectedInitially) {
            for (final old in before.where((r) => r['state'] == 'confirmed')) {
              expect(restored.singleWhere((r) => r['id'] == old['id']), old);
            }
          } else {
            if (change != 'cosmetic') expect(restoreRequests, greaterThan(0));
            expect(ScanRecognition.adopted(await record('tmdb', 'work'))?['id'], 44163);
            expect(ScanRecognition.adopted(await record('bangumi', 'work'))?['id'], 95618);
            final mapped = restored.where((r) => r['layer'] == 'episode' && r['state'] == 'confirmed');
            expect(mapped.length, 24);
            for (final provider in ['tmdb', 'bangumi']) {
              expect(mapped.where((r) => r['provider'] == provider).map((r) =>
                  ScanRecognition.adopted(r)![provider == 'tmdb' ? 'episode' : 'sort']).toSet(),
                  {for (var n = 1; n <= 12; n++) n});
            }
          }
          await scan();
          expect(await catalog.db.query('scan_bindings', orderBy: 'id'), restored);
        }
      } else if (originalBindings != null) {
        expect(await catalog.db.query('scan_bindings', orderBy: 'id'), originalBindings);
      } else {
        expect(ScanRecognition.adopted(await record('tmdb', 'work')), isNull);
        expect(ScanRecognition.adopted(await record('bangumi', 'work')), isNull);
        if (protectedRange != null) {
          expect(await catalog.db.query('scan_bindings', where: 'id=?', whereArgs: ['manual-range-fixture']), [protectedRange]);
        }
      }
    });
  }

  for (final mode in ['conflict', 'same_identity', 'truncated', 'failure']) {
    test('no-ID later hint cannot hide conflicting or incomplete evidence: $mode', () async {
      await catalog.db.close();
      await open(automatic: true);
      await video('Series (2020)/[G] Other - 01.mkv');
      final queried = <String>[];
      final bangumiQueried = <String>[];
      useTransport((request) async {
        if (request.url.path.endsWith('/search/subjects')) {
          final query = (jsonDecode(request.body) as Map)['keyword'] as String;
          bangumiQueried.add(query);
          if (query == 'Other' && mode == 'failure') return reply({}, 503);
          final id = query == 'Other' && mode == 'conflict' ? 21 : 20;
          return reply({'data': [
            {'id': id, 'type': 2, 'name': id == 21 ? 'Other' : 'Series', 'date': '2020-01-01'}
          ], 'total': mode == 'truncated' ? 2 : 1});
        }
        if (request.url.path.endsWith('/search/multi')) {
          final query = request.url.queryParameters['query']!;
          queried.add(query);
          if (query == 'Other' && mode == 'failure') return reply({}, 503);
          final id = query == 'Other' && mode == 'conflict' ? 11 : 10;
          return reply({'results': [
            {'id': id, 'media_type': 'tv', 'name': id == 11 ? 'Other' : 'Series', 'first_air_date': '2020-01-01'}
          ], 'total_pages': mode == 'truncated' && query == 'Series' ? 2 : 1});
        }
        if (request.url.path.endsWith('/tv/10')) {
          return reply({'id': 10, 'name': 'Series', 'first_air_date': '2020-01-01', 'seasons': []});
        }
        return reply({'data': [], 'total': 0});
      });
      await scan();
      expect(queried, contains('Other'));
      if (mode != 'truncated') expect(bangumiQueried, contains('Other'));
      final row = await record('tmdb', 'work');
      expect(row['state'], mode == 'same_identity' ? 'confirmed' : 'pending');
      if (mode != 'same_identity') expect(ScanRecognition.adopted(row), isNull);
      if (mode == 'conflict') {
        expect(ScanRecognition.candidates(row).map((c) => c['id']).toSet(), {10, 11});
      }
      if (mode != 'same_identity') {
        final bg = await record('bangumi', 'work');
        expect(bg['state'], 'pending');
        expect(ScanRecognition.adopted(bg), isNull);
        if (mode == 'conflict') {
          expect(ScanRecognition.candidates(bg).map((c) => c['id']).toSet(), {20, 21});
        }
      }
    });
  }

  for (final mode in ['translated', 'year_conflict']) {
    test('same ID retains earlier name evidence without hiding conflicts: $mode', () async {
      await catalog.db.close();
      await open(automatic: true);
      await video('Series (2020)/[G] Other - 01.mkv');
      useTransport((request) async {
        if (request.url.path.endsWith('/search/multi')) {
          final later = request.url.queryParameters['query'] == 'Other';
          return reply({'results': [
            {'id': 10, 'media_type': 'tv', 'name': later ? 'Other' : 'Series',
              'first_air_date': later && mode == 'year_conflict' ? '2021-01-01' : '2020-01-01'}
          ], 'total_pages': 1});
        }
        if (request.url.path.endsWith('/tv/10')) {
          return reply({'id': 10, 'name': 'Series', 'first_air_date': '2020-01-01', 'seasons': []});
        }
        return reply({'data': [], 'total': 0});
      });
      await scan();
      final row = await record('tmdb', 'work');
      expect(row['state'], mode == 'translated' ? 'confirmed' : 'pending');
      if (mode == 'translated') {
        expect(ScanRecognition.candidates(row).single['aliases'], containsAll(['Series', 'Other']));
      } else {
        expect(ScanRecognition.adopted(row), isNull);
      }
    });
  }

  for (final mode in ['linked', 'unrelated', 'failure']) {
    test('English filename needs official Chinese directory alias: $mode', () async {
      await catalog.db.close();
      await open(automatic: true);
      await video('暗夜第六感 2041 (2021)/NIGHT HEAD 2041 - 01.mkv');
      var detailCalls = 0;
      useTransport((request) async {
        if (request.url.path.endsWith('/search/multi')) {
          return reply({'results': [{'id': 112616, 'media_type': 'tv',
            'name': 'Night Head 2041', 'original_name': 'NIGHT HEAD 2041',
            'first_air_date': '2021-07-15'}], 'total_pages': 1});
        }
        if (request.url.path.endsWith('/tv/112616')) {
          detailCalls++;
          if (mode == 'failure') return reply({}, 503);
          return reply({'id': 112616, 'name': 'Night Head 2041',
            'first_air_date': '2021-07-15', 'seasons': [],
            'translations': {'translations': [{'data': {'name': mode == 'linked' ? '暗夜第六感 2041' : '另一个作品'}}]}});
        }
        return reply({'data': [], 'total': 0});
      });
      await scan();
      expect(detailCalls, mode == 'failure' ? greaterThan(0) : equals(1));
      final row = await record('tmdb', 'work');
      expect(row['state'], mode == 'linked' ? 'confirmed' : 'pending');
      if (mode != 'linked') expect(ScanRecognition.adopted(row), isNull);
    });
  }

  for (final lateConflict in [false, true]) {
    test('TMDB year prefilter preserves older TV and later-page conflicts: $lateConflict', () async {
      await catalog.db.close();
      await open(automatic: true);
      await video('Series (1981)/Series - 01.mkv');
      final detailIds = <int>[];
      var secondPage = false;
      useTransport((request) async {
        if (request.url.path.endsWith('/search/multi')) {
          final page = request.url.queryParameters['page'] ?? '1';
          if (page == '2') secondPage = true;
          return reply({'total_pages': 2, 'results': page == '1' ? [
            {'id': 1, 'media_type': 'tv', 'name': 'Other', 'first_air_date': '1981-01-01'},
            {'id': 2, 'media_type': 'tv', 'name': 'Other', 'first_air_date': '2022-01-01'},
            for (var id = 10; id < 24; id++)
              {'id': id, 'media_type': 'movie', 'name': 'Other', 'release_date': '1985-01-01'},
          ] : [
            {'id': 3, 'media_type': 'tv', 'name': 'Other', 'first_air_date': '1979-01-01'},
            {'id': 4, 'media_type': 'movie', 'name': 'Other'},
          ]});
        }
        if (RegExp(r'/(tv|movie)/\d+$').hasMatch(request.url.path)) {
          final id = int.parse(request.url.path.split('/').last);
          detailIds.add(id);
          return reply({'id': id, 'name': id == 1 || lateConflict ? 'Series' : 'Unrelated',
            'first_air_date': id == 3 ? '1979-01-01' : '1981-01-01',
            'seasons': [{'season_number': 1, 'episode_count': 12, 'air_date': '1981-01-01'}]});
        }
        return reply({'data': [], 'total': 0});
      });
      await scan();
      expect(secondPage, isTrue);
      expect(detailIds.toSet(), {1, 3, 4});
      final row = await record('tmdb', 'work');
      expect(row['state'], lateConflict ? 'pending' : 'confirmed');
      if (lateConflict) expect(ScanRecognition.adopted(row), isNull);
    });
  }

  test('TMDB alias detail budget spans all no-ID hints', () async {
    await catalog.db.close();
    await open(automatic: true);
    await video('Series (2020)/Other - 01.mkv');
    var details = 0;
    useTransport((request) async {
      if (request.url.path.endsWith('/search/multi')) {
        final offset = request.url.queryParameters['query'] == 'Other' ? 7 : 0;
        return reply({'results': [for (var i = 1; i <= 7; i++)
          {'id': offset + i, 'media_type': 'tv', 'name': 'Unrelated ${offset + i}', 'first_air_date': '2020-01-01'}
        ], 'total_pages': 1});
      }
      if (RegExp(r'/tv/\d+$').hasMatch(request.url.path)) {
        details++;
        final id = int.parse(request.url.path.split('/').last);
        return reply({'id': id, 'name': 'Unrelated $id', 'first_air_date': '2020-01-01',
          if (id == 1) 'alternative_titles': {'results': [{'title': 'Series'}]}});
      }
      return reply({'data': [], 'total': 0});
    });
    await scan();
    expect(details, 12);
    final row = await record('tmdb', 'work');
    expect(row['state'], 'pending');
    expect(row['reason'], 'detail_budget_exhausted');
    expect(ScanRecognition.canRetryWorkQuery(row), isFalse);
    expect(ScanRecognition.adopted(row), isNull);
  });

  for (final mode in ['alias', 'ambiguous', 'failure', 'wrong_id', 'truncated']) {
    test('TMDB detail aliases require complete consistent candidates: $mode', () async {
      await catalog.db.close();
      await open(automatic: true);
      await video('Urusei Yatsura (1981)/Urusei Yatsura - 01.mkv');
      var details = 0;
      useTransport((request) async {
        if (request.url.path.endsWith('/search/multi')) {
          return reply({'results': [
            for (final id in mode == 'ambiguous' ? [34163, 999] : [34163])
              {'id': id, 'media_type': 'tv', 'name': '福星小子', 'original_name': 'うる星やつら', 'first_air_date': '1981-10-14'}
          ], 'total_pages': mode == 'truncated' ? 2 : 1});
        }
        if (RegExp(r'/tv/\d+$').hasMatch(request.url.path)) {
          details++;
          if (mode == 'failure') return reply({}, 503);
          final id = int.parse(request.url.path.split('/').last);
          return reply({'id': mode == 'wrong_id' ? 123 : id,
            'name': '福星小子', 'first_air_date': '1981-10-14', 'seasons': [],
            'alternative_titles': {'results': [{'title': 'Urusei Yatsura'}]}});
        }
        return reply({'data': [], 'total': 0});
      });
      await scan();
      expect(details, greaterThan(0));
      final row = await record('tmdb', 'work');
      expect(row['state'], mode == 'alias' ? 'confirmed' : 'pending');
      if (mode == 'failure') expect(row['reason'], 'request_failed');
      if (mode == 'wrong_id') {
        expect(row['reason'], 'invalid_response');
        expect(ScanRecognition.canRetryWorkQuery(row), isTrue);
      }
      if (mode != 'alias') expect(ScanRecognition.adopted(row), isNull);
    });
  }

  for (final scenario in ['unique', 'mismatch', 'two_seasons', 'shifted', 'incomplete', 'failure', 'unknown_season', 'duplicate', 'out_of_range', 'last_episode', 'complete_rescan', 'combined', 'absolute', 'absolute_incomplete', 'missing_first', 'missing_middle', 'missing_last', 'mixed', 'mixed_duplicate', 'missing_manual_range', 'missing_manual_episode', 'after_delete', 'after_rename', 'after_mix', 'after_manual_episode', 'after_manual_range', 'after_rename_label']) {
    final mode = scenario.startsWith('after_') ? 'absolute' : scenario;
    test('broadcast part selects a season only by complete original chapters: $scenario', () async {
      await catalog.db.close();
      await open(automatic: true);
      final gapCases = <String, List<int>>{
        'missing_manual_range': [for (var n = 14; n <= 26; n++) if (n != 20) n],
        'missing_manual_episode': [for (var n = 14; n <= 26; n++) if (n != 20) n],
        'missing_first': [for (var n = 15; n <= 26; n++) n],
        'missing_middle': [for (var n = 14; n <= 26; n++) if (n != 20) n],
        'missing_last': [for (var n = 14; n <= 25; n++) n],
        'mixed': [1, for (var n = 15; n <= 26; n++) n],
        'mixed_duplicate': [1, for (var n = 14; n <= 26; n++) n],
      };
      final gap = gapCases[mode];
      final count = gap == null ? 3 : 13;
      if (gap != null) {
        for (final n in gap) {
          await video('苍穹之法芙娜 EXODUS 第2部分 (2015)/[G] Soukyuu_no_Fafner_Exodus [${n.toString().padLeft(2, '0')}].mkv');
        }
      }
      if (gap == null) {
        await video('苍穹之法芙娜 EXODUS 第2部分 (2015)/[G] Soukyuu_no_Fafner_Exodus [${['out_of_range', 'absolute', 'absolute_incomplete'].contains(mode) ? '14' : mode == 'last_episode' ? '03' : '01'}].mkv');
      }
      if (mode == 'duplicate') {
        await video('苍穹之法芙娜 EXODUS 第2部分 (2015)/[H] Soukyuu_no_Fafner_Exodus [01].mkv');
      }
      if (mode == 'complete_rescan') {
        for (final number in ['02', '03']) {
          await video('苍穹之法芙娜 EXODUS 第2部分 (2015)/[G] Soukyuu_no_Fafner_Exodus [$number].mkv');
        }
      }
      if (mode == 'combined') {
        await video('苍穹之法芙娜 EXODUS 第2部分 (2015)/[G] Soukyuu_no_Fafner_Exodus [02+03].mkv');
      }
      if (mode == 'absolute') {
        for (final number in ['15', '16']) {
          await video('苍穹之法芙娜 EXODUS 第2部分 (2015)/[G] Soukyuu_no_Fafner_Exodus [$number].mkv');
        }
      }
      useTransport((request) async {
        if (request.url.path.endsWith('/search/multi')) {
          return reply({'results': [{'id': 25891, 'media_type': 'tv', 'name': '苍穹之法芙娜 EXODUS', 'first_air_date': '2015-01-09'}], 'total_pages': 1});
        }
        if (request.url.path.endsWith('/search/subjects')) {
          return reply({'data': [{'id': 130230, 'type': 2, 'name_cn': '苍穹之法芙娜 EXODUS 第2部分', 'date': '2015-10-02'}], 'total': 1});
        }
        if (request.url.path.endsWith('/tv/25891')) {
          return reply({'id': 25891, 'name': '苍穹之法芙娜 EXODUS', 'first_air_date': '2015-01-09',
            'seasons': [for (final s in [1, mode == 'shifted' ? 3 : 2]) {'season_number': s, 'episode_count': count, 'air_date': mode == 'unknown_season' && s == 1 ? null : s == 1 ? '2015-01-09' : '2015-10-03'}]});
        }
        if (request.url.path.endsWith('/episodes')) {
          return reply({'total': mode == 'incomplete' ? 4 : count, 'data': [for (var i = 1; i <= count; i++)
            {'id': 100 + i, 'subject_id': 130230, 'sort': 13 + i, 'type': 0, 'name': '原題$i', 'name_cn': '不同译名$i', 'airdate': DateTime(2015, 10, i + 1).toIso8601String().substring(0, 10)}]});
        }
        if (RegExp(r'/season/[123]$').hasMatch(request.url.path)) {
          final s = int.parse(request.url.path.split('/').last);
          if (mode == 'failure' && s == 2) return reply({}, 503);
          final matches = s == (mode == 'shifted' ? 3 : 2) || mode == 'two_seasons';
          return reply({'season_number': s, 'episodes': [for (var i = 1; i <= count; i++)
            {'id': s * 1000 + i, 'season_number': s, 'episode_number': i,
              'name': mode == 'mismatch' && i == 3 ? '其他标题' : '原題$i',
              'air_date': matches ? DateTime(2015, 10, i + 2).toIso8601String().substring(0, 10) : DateTime(2015, 1, i + 2).toIso8601String().substring(0, 10)}]});
        }
        return reply({}, 404);
      });
      await scan();
      final work = await record('tmdb', 'work');
      expect(ScanRecognition.adopted(work)?['id'], 25891);
      final ranges = await catalog.db.query('scan_bindings', where: "provider='tmdb' AND layer='range' AND state='confirmed'");
      if ((gap != null && !mode.startsWith('mixed')) || ['unique', 'shifted', 'duplicate', 'out_of_range', 'last_episode', 'complete_rescan', 'combined', 'absolute', 'absolute_incomplete'].contains(mode)) {
        expect(ranges, hasLength(1));
        expect(ScanRecognition.adopted(ranges.single)?['season'], mode == 'shifted' ? 3 : 2);
        expect(ScanRecognition.adopted(ranges.single)?['offset'], mode == 'absolute' ? -13 : 0);
        if (mode == 'absolute') {
          final files = await catalog.db.query('scan_bindings', where: "provider='tmdb' AND layer='episode' AND state='confirmed'");
          expect(files.map((row) => ScanRecognition.adopted(row)?['episode']), unorderedEquals([1, 2, 3]));
        }
      } else {
        expect(ranges, isEmpty);
      }
      if (gap != null) {
        final bound = await catalog.db.query('scan_bindings', where: "layer='episode' AND state='confirmed'");
        expect(bound, isEmpty, reason: 'Incomplete or mixed absolute numbering must not bind files');
        final before = await catalog.db.query('scan_bindings', orderBy: 'id');
        await scan();
        expect(await catalog.db.query('scan_bindings', orderBy: 'id'), before);
      }
      final bgRanges = await catalog.db.query('scan_bindings', where: "provider='bangumi' AND layer='range' AND state='confirmed'");
      if (['unique', 'shifted', 'last_episode', 'complete_rescan', 'absolute'].contains(mode)) {
        expect(bgRanges, hasLength(1));
        expect(ScanRecognition.adopted(bgRanges.single)?['offset'], mode == 'absolute' ? 0 : 13);
        final episodes = await catalog.db.query('scan_bindings', where: "provider='bangumi' AND layer='episode' AND state='confirmed'");
        expect(episodes, hasLength(['complete_rescan', 'absolute'].contains(mode) ? 3 : 1));
        if (['complete_rescan', 'absolute'].contains(mode)) {
          expect(episodes.map((row) => ScanRecognition.adopted(row)?['sort']), unorderedEquals([14, 15, 16]));
          expect(episodes.map((row) => ScanRecognition.adopted(row)?['id']), unorderedEquals([101, 102, 103]));
          final before = await catalog.db.query('scan_bindings', orderBy: 'id');
          await scan();
          expect(await catalog.db.query('scan_bindings', orderBy: 'id'), before);
        } else {
          expect(ScanRecognition.adopted(episodes.single)?['sort'], mode == 'last_episode' ? 16 : 14);
          expect(ScanRecognition.adopted(episodes.single)?['id'], mode == 'last_episode' ? 103 : 101);
        }
        final chapters = ScanRecognition.adopted(bgRanges.single)!['chapters'] as List;
        expect(chapters.first['title'], '不同译名1');
      } else {
        expect(bgRanges, isEmpty);
      }
      if (scenario.startsWith('after_')) {
        Map<String, Object?>? manual;
        if (scenario.startsWith('after_manual')) {
          final layer = scenario == 'after_manual_range' ? 'range' : 'episode';
          final row = (await catalog.db.query('scan_bindings', where: 'provider=? AND layer=?', whereArgs: ['tmdb', layer])).first;
          await runner.recognition.decide(await withToken(row), ScanRecognition.adopted(row)!);
          manual = (await catalog.db.query('scan_bindings', where: 'id=?', whereArgs: [row['id']])).single;
        }
        final folder = '${media.path}/苍穹之法芙娜 EXODUS 第2部分 (2015)';
        final original = File('$folder/[G] Soukyuu_no_Fafner_Exodus [15].mkv');
        if (scenario == 'after_rename_label') {
          await original.rename('$folder/[H] Soukyuu_no_Fafner_Exodus [15].mkv');
        } else if (scenario == 'after_delete') {
          await original.delete();
        } else if (scenario == 'after_rename') {
          await original.rename('$folder/[G] Soukyuu_no_Fafner_Exodus [02].mkv');
        } else {
          await video('苍穹之法芙娜 EXODUS 第2部分 (2015)/[G] Soukyuu_no_Fafner_Exodus [01].mkv');
        }
        await scan();
        if (manual != null) {
          expect(await catalog.db.query('scan_bindings', where: 'id=?', whereArgs: [manual['id']]), [manual]);
        }
        if (scenario == 'after_rename_label') {
          final confirmed = await catalog.db.query('scan_bindings', where: "layer='episode' AND state='confirmed'");
          expect(confirmed, hasLength(6));
          expect(confirmed.where((r) => r['provider'] == 'tmdb').map((r) => ScanRecognition.adopted(r)?['episode']), unorderedEquals([1, 2, 3]));
          expect(confirmed.where((r) => r['provider'] == 'bangumi').map((r) => ScanRecognition.adopted(r)?['sort']), unorderedEquals([14, 15, 16]));
        } else if (scenario != 'after_manual_range') {
          final confirmed = await catalog.db.query('scan_bindings', where: "layer='episode' AND state='confirmed'");
          expect(confirmed, manual == null ? isEmpty : equals([manual]));
        }
        final stable = await catalog.db.query('scan_bindings', orderBy: 'id');
        await scan();
        expect(await catalog.db.query('scan_bindings', orderBy: 'id'), stable);
      }
      if (mode.startsWith('missing_')) {
        Map<String, Object?>? manual;
        if (mode.startsWith('missing_manual')) {
          final layer = mode == 'missing_manual_range' ? 'range' : 'episode';
          final row = (await catalog.db.query('scan_bindings', where: 'provider=? AND layer=?', whereArgs: ['tmdb', layer])).first;
          await runner.recognition.decide(await withToken(row), layer == 'range'
              ? ScanRecognition.adopted(row)!
              : {'season': 2, 'episode': 8});
          manual = (await catalog.db.query('scan_bindings', where: 'id=?', whereArgs: [row['id']])).single;
        }
        for (var n = 14; n <= 26; n++) {
          if (!gap!.contains(n)) {
            await video('苍穹之法芙娜 EXODUS 第2部分 (2015)/[G] Soukyuu_no_Fafner_Exodus [$n].mkv');
          }
        }
        await scan();
        final bound = await catalog.db.query('scan_bindings', where: "layer='episode' AND state='confirmed'");
        if (manual != null) {
          expect(await catalog.db.query('scan_bindings', where: 'id=?', whereArgs: [manual['id']]), [manual]);
          expect(bound.length, lessThan(26));
          return;
        }
        expect(bound, hasLength(26));
        expect(bound.where((r) => r['provider'] == 'tmdb').map((r) => ScanRecognition.adopted(r)?['episode']), unorderedEquals([for (var i = 1; i <= 13; i++) i]));
        expect(bound.where((r) => r['provider'] == 'bangumi').map((r) => ScanRecognition.adopted(r)?['sort']), unorderedEquals([for (var i = 14; i <= 26; i++) i]));
        final stable = await catalog.db.query('scan_bindings', orderBy: 'id');
        await scan();
        expect(await catalog.db.query('scan_bindings', orderBy: 'id'), stable);
      }
    });
  }

  for (final mode in ['conflict', 'matching_season', 'detail_failure']) {
    test('no-ID year is rechecked after TV details: $mode', () async {
      await catalog.db.close();
      await open(automatic: true);
      await video('Series (2020)/Series - 01.mkv');
      useTransport((request) async {
        if (request.url.path.endsWith('/search/multi')) {
          return reply({'results': [
            {'id': 10, 'media_type': 'tv', 'name': 'Series', 'first_air_date': '2010-01-01'}
          ], 'total_pages': 1});
        }
        if (request.url.path.endsWith('/tv/10')) {
          if (mode == 'detail_failure') return reply({}, 503);
          return reply({'id': 10, 'name': 'Series', 'first_air_date': '2010-01-01',
            'seasons': [{'season_number': 1, 'episode_count': 12,
              'air_date': mode == 'matching_season' ? '2020-01-01' : '2010-01-01'}]});
        }
        return reply({'data': [], 'total': 0});
      });
      await scan();
      final row = await record('tmdb', 'work');
      expect(row['state'], mode == 'matching_season' ? 'confirmed' : 'pending');
      if (mode != 'matching_season') expect(ScanRecognition.adopted(row), isNull);
    });
  }

  for (final (scenario, state, reason, ids) in [
    ('nine page unique', 'confirmed', 'verified_bangumi', [376565]),
    ('nine page late conflict', 'pending', 'ambiguous', [376565, 500001]),
    ('one exact candidate', 'confirmed', 'verified_bangumi', [376565]),
    ('two exact candidates', 'pending', 'ambiguous', [376565, 500001]),
    ('next page fails', 'pending', 'query_incomplete', [376565]),
  ]) {
    test('Bangumi pagination: $scenario', () async {
      await catalog.db.close();
      await open(automatic: true);
      Metadata.token = '';
      const title = '4个人各自有着自己的秘密';
      await video('$title (2022)/$title [01].mkv');
      final offsets = <int>[];
      var activePages = 0, peakPages = 0;
      Map<String, Object?> subject(int id, String name) => {
        'id': id,
        'name': name,
        'type': 2,
        'date': '2022-10-15',
      };
      useTransport((request) async {
        expect(request.url.path, '/v0/search/subjects');
        final body = jsonDecode(request.body) as Map;
        expect(body['keyword'], title);
        final offset = int.parse(request.url.queryParameters['offset'] ?? '0');
        offsets.add(offset);
        if (scenario.startsWith('nine page')) {
          activePages++;
          if (activePages > peakPages) peakPages = activePages;
          await Future<void>.delayed(const Duration(milliseconds: 40));
          activePages--;
          return reply({'total': 174, 'data': [
            for (var i = offset; i < offset + 20 && i < 174; i++)
              subject(i == 0 ? 376565 : i == 173 && scenario.endsWith('conflict') ? 500001 : i,
                i == 0 || i == 173 && scenario.endsWith('conflict') ? title : 'Unrelated $i'),
          ]});
        }
        if (offset == 0) {
          return reply({
            'total': 25,
            'data': [
              subject(376565, title),
              for (var i = 1; i <= 19; i++) subject(i, 'Unrelated $i'),
            ],
          });
        }
        expect(offset, 20);
        if (scenario == 'next page fails') return reply({}, 503);
        return reply({
          'total': 25,
          'data': [
            subject(
              scenario == 'two exact candidates' ? 500001 : 376565,
              title,
            ),
            for (var i = 20; i <= 23; i++) subject(i, 'Unrelated $i'),
          ],
        });
      });
      await scan();
      if (scenario == 'next page fails') {
        expect(offsets.first, 0);
        expect(offsets.skip(1), isNotEmpty);
        expect(offsets.skip(1), everyElement(20));
      } else if (scenario.startsWith('nine page')) {
        expect(offsets, unorderedEquals([for (var n = 0; n < 174; n += 20) n]));
        expect(peakPages, 3);
      } else {
        expect(offsets, [0, 20]);
      }
      final binding = await record('bangumi', 'work');
      expect(binding['state'], state);
      expect(binding['reason'], reason);
      expect(
        ScanRecognition.candidates(binding).map((row) => row['id']),
        unorderedEquals(ids),
      );
      expect(
        ScanRecognition.adopted(binding)?['id'],
        state == 'confirmed' ? 376565 : null,
      );
    });
  }

  test('prioritized inventory sends a scrape request before remaining publication', () async {
    await catalog.db.close();
    await open(automatic: true);
    await video('Priority (2021) {tmdbtv-42}/E01.mkv');
    for (var number = 1; number <= 49; number++) {
      await video('Large inventory/E${number.toString().padLeft(2, '0')}.mkv');
    }
    Future<List<Map<String, Object?>>>? firstInventory;
    useTransport((request) async {
      firstInventory ??= catalog.db.query('works', columns: ['title']);
      return reply(request.url.path.contains('/3/') ? {'results': []} : {'data': []});
    });
    final id = await runner.enqueueScan(source);
    final previousLogs = DebugLog.directory;
    final previousLogging = DebugLog.enabled;
    await DebugLog.initialize(root: scratch);
    addTearDown(() async {
      await DebugLog.flush();
      DebugLog.directory = previousLogs;
      DebugLog.enabled = previousLogging;
    });
    await runner.run(id);
    final first = await firstInventory!;
    expect(first, hasLength(1));
    expect(first.single['title'], contains('Priority'));
    expect(catalog.assets, hasLength(50));
    final step = (await catalog.db.query('scrape_steps',
      where: "task_id=? AND step='enumerate'", whereArgs: [id])).single;
    final result = jsonDecode(step['result_json'] as String) as Map;
    expect(result['added'], 50);
    expect(result['priority_added'], 1);
    expect(result['enumeration_ms'], isNonNegative);
    expect(result['publication_ms'], isNonNegative);
    await DebugLog.flush();
    final events = <String, Map<String, dynamic>>{};
    for (final line in await File('${scratch.path}/logs/current.log').readAsLines()) {
      final event = jsonDecode(line.substring(line.indexOf('{'))) as Map<String, dynamic>;
      if (event['event'] is String) events[event['event'] as String] = event;
    }
    final phases = events['scan_phases']!;
    final firstRequest = events['first_scrape_request']!;
    expect(firstRequest['scan'], phases['scan']);
    expect(firstRequest['elapsedMs'], greaterThanOrEqualTo(phases['enumerationMs'] as int));
    // ignore: avoid_print
    print('KONATA_SCAN_PHASES ${jsonEncode({
      'enumeration_ms': phases['enumerationMs'],
      'publication_ms': phases['publicationMs'],
      'priority_publication_ms': phases['priorityPublicationMs'],
      'first_scrape_request_ms': firstRequest['elapsedMs'],
      'works_at_first_request': first.length,
    })}');
  });

  test('explicit dotted TV episodes keep stills alongside unnumbered films', () async {
    await catalog.db.close();
    await open(automatic: true);
    const folder = 'Example Series (1978) {tmdbtv-42}';
    for (var number = 1; number <= 3; number++) {
      await video('$folder/Example.Series.1978.S01E0$number.1080p.BDRip.x265.mkv');
    }
    await video('$folder/Example.Series.Movie.1.2017.1080p.mkv');
    await video('$folder/Example.Series.Movie.2.2018.1080p.mkv');
    useTransport((request) async => switch (request.url.path) {
      '/3/tv/42' => reply({'id': 42, 'name': 'Example Series',
        'first_air_date': '1978-06-03',
        'seasons': [{'season_number': 1, 'episode_count': 3, 'air_date': '1978-06-03'}]}),
      '/3/tv/42/season/1' => reply({'season_number': 1, 'episodes': [
        for (var i = 1; i <= 3; i++)
          {'id': 420 + i, 'season_number': 1, 'episode_number': i,
            'name': 'Episode $i', 'still_path': '/example-$i.jpg'},
      ]}),
      _ => reply(request.url.path.contains('/3/') ? {'results': []} : {'data': []}),
    });
    Future<void> checkStills() async {
      final details = (await ScanRecognition.details(catalog, catalog.works.single))!;
      final files = details['recognized_file_details'] as Map;
      final ranges = await catalog.db.query('scan_bindings', columns: ['provider','layer','state','reason'],
        where: "layer IN ('work','range')");
      expect(files.values.where((value) => (value as Map)['still'] != null), hasLength(3),
        reason: '$ranges; ${catalog.assets.map((file) => [file['name'],file['episode'],file['category']]).toList()}');
      expect(catalog.assets, hasLength(5));
    }
    await scan();
    await checkStills();
    await catalog.db.delete('scan_bindings', where: "provider='tmdb' AND layer IN ('range','episode')");
    await scan();
    await checkStills();
  });

  test('a verified single-season identity recovers a missing Bangumi alias', () async {
    await catalog.db.close();
    await open(automatic: true);
    const local = 'Release Series';
    const official = 'Original Series';
    await video('$local/$local - 01.mkv');
    useTransport((_) async => reply({'results': [], 'data': []}));
    await scan();
    final work = catalog.works.single['id'];
    await catalog.db.update('scan_bindings', {
      'state': 'confirmed', 'reason': 'verified_tmdb',
      'adopted': jsonEncode({
        'id': 42, 'type': 'tv', 'year': 2020, 'exact': true,
        'by': 'verified_tmdb', 'aliases': [local, official],
        'seasons': [{'season': 1, 'count': 1, 'year': 2020}],
      }),
    }, where: "work_id=? AND provider='tmdb' AND layer='work'", whereArgs: [work]);
    final keywords = <String>[];
    useTransport((request) async {
      if (request.url.path != '/v0/search/subjects') return reply({}, 503);
      final query = jsonDecode(request.body) as Map;
      final keyword = query['keyword'] as String;
      keywords.add(keyword);
      if (keyword != official) return reply({'data': [], 'total': 0});
      expect((query['filter'] as Map)['air_date'], ['>=2020-01-01', '<2021-01-01']);
      return reply({'data': [
        {'id': 41, 'name': official, 'date': '2020-01-01', 'type': 2},
      ], 'total': 1});
    });
    await scan();
    expect(keywords, contains(official));
    expect(ScanRecognition.adopted(await record('bangumi', 'work'))?['id'], 41);
    expect(ScanRecognition.adopted(await record('tmdb', 'work'))?['id'], 42);
  });

  test('a complete OVA retires an old partial binding to the later TV cut', () async {
    await catalog.db.close();
    await open(automatic: true);
    const title = 'Example Recut Story';
    for (var episode = 1; episode <= 3; episode++) {
      await video('$title/[Release] $title [0$episode].mkv');
    }
    useTransport((_) async => reply({'results': [], 'data': []}));
    await scan();
    final work = catalog.works.single['id'] as String;
    final ova = {
      'id': 31, 'type': 'anime', 'year': 2015, 'title': title,
      'exact': true, 'directory_title_matches': true, 'by': 'verified_bangumi',
    };
    final recut = {
      'id': 32, 'type': 'tv', 'year': 2019, 'title': '$title: The TV Cut',
      'aliases': [title], 'directory_subject': 31, 'directory_title_matches': false,
      'seasons': [{'season': 1, 'count': 6, 'year': 2019}], 'by': 'verified_tmdb',
    };
    for (final (provider, identity) in [('bangumi', ova), ('tmdb', recut)]) {
      await catalog.db.update('scan_bindings', {
        'state': 'confirmed', 'reason': 'verified_$provider',
        'adopted': jsonEncode(identity),
      }, where: "work_id=? AND provider=? AND layer='work'", whereArgs: [work, provider]);
    }
    await catalog.db.insert('scan_bindings', {
      'id': jsonEncode([work, 'bangumi', 'range', '']),
      'work_id': work, 'provider': 'bangumi', 'layer': 'range', 'scope': '',
      'reason': 'range_unconfirmed',
    });
    useTransport((request) async => request.url.path == '/v0/subjects/31'
        ? reply({'id': 31, 'type': 2, 'name': title, 'platform': 'OVA',
            'eps': 3, 'date': '2015-01-01'})
        : reply({'results': [], 'data': []}));
    await scan();
    final tmdb = await record('tmdb', 'work');
    expect(tmdb['state'], 'pending');
    expect(tmdb['reason'], 'conflicting_title');
    expect(jsonDecode(tmdb['previous'] as String)['id'], 32);
    expect(ScanRecognition.adopted(await record('bangumi', 'work'))?['id'], 31);
  });

  test('a numbered after phase with a full sibling remains a separate extra', () async {
    await catalog.db.close();
    await open(automatic: true);
    const main = 'Example Show EP48 [23.976fps x265-10Bit].mkv';
    const bonus = 'Example Show EP48 After Phase [23.976fps x265-10Bit].mkv';
    const orphan = 'Example Show EP47 After Phase [23.976fps x265-10Bit].mkv';
    for (final name in [main, bonus, orphan]) {
      await video('Example Show/$name');
    }
    useTransport((_) async => reply({'results': [], 'data': []}));
    await scan();
    final original = await catalog.db.query('assets');
    expect(original, hasLength(3));
    for (final name in [main, bonus, orphan]) {
      await catalog.db.update('assets', {'size':name == main ? 1000 : 100},
          where:'name=?', whereArgs:[name]);
    }
    final id = await runner.recognition.enqueue(source, catalog.works.single['id'] as String, retry:true);
    await runner.run(id, manualRetry:true);
    final after = await catalog.db.query('assets');
    expect(after.map((row)=>row['id']), unorderedEquals(original.map((row)=>row['id'])));
    expect(after.singleWhere((row)=>row['name']==bonus)['category'], 'extra');
    expect(after.singleWhere((row)=>row['name']==main)['category'], 'main');
    expect(after.singleWhere((row)=>row['name']==orphan)['category'], 'main');
  });

  for (final scenario in ['split', 'split-conflict', 'combined', 'combined-conflict']) {
    test('provider chapters verify mixed numbering: $scenario', () async {
      await catalog.db.close();
      await open(automatic: true);
      final all = jsonDecode(
        await File('test/fixtures/split_combined_broadcast.json').readAsString(),
      ) as Map;
      final split = scenario.startsWith('split');
      final conflict = scenario.endsWith('conflict');
      final fixture = all[split ? 'split' : 'combined'] as Map;
      final folder = fixture['folder'];
      for (var i = 1; i <= (split ? 26 : 12); i++) {
        final n = '$i'.padLeft(2, '0');
        await video(split
            ? '$folder/[Moozzi2] Gundam Build Divers Re Rise - $n (BD 1920x1080 x265-10Bit FLACx2).mkv'
            : '$folder/[VCB-Studio] Full Metal Panic？Fumoffu [$n][Hi10p_720p][x264_flac].mkv');
      }
      useTransport((_) async => reply({'results': [], 'data': []}));
      await scan();
      for (final p in ['tmdb', 'bangumi']) {
        final source = fixture['providers'][p] as Map;
        final adopted = source['adopted'];
        await catalog.db.update('scan_bindings', {
          'state': adopted == null ? 'pending' : 'confirmed',
          'reason': adopted != null ? 'verified_bangumi' : split
              ? (p == 'tmdb' ? 'ambiguous' : 'query_incomplete') : 'conflicting_title',
          'candidates': jsonEncode(source['candidates']),
          'adopted': adopted == null ? null : jsonEncode(adopted),
        }, where:"provider=? AND layer='work'", whereArgs:[p]);
      }
      if (conflict) {
        for (final body in (fixture['chapters'] as Map).values) {
          body['episodes'][0]['name'] = '無関係のエピソード';
        }
      }
      useTransport((request) async {
        final path = request.url.path;
        if (path == '/v0/episodes') {
          final subject = request.url.queryParameters['subject_id'];
          return reply(fixture['episodes'][subject]);
        }
        if (path == '/v0/subjects/286123/subjects') return reply([fixture['relation']]);
        if (path.startsWith('/v0/subjects/')) {
          final subject = fixture['subjects'][request.url.pathSegments.last];
          if (subject != null) return reply(subject);
        }
        if (path == "/3/tv/${fixture['series']}/season/2") {
          return reply(fixture['chapters'][request.url.queryParameters['language']] ??
              fixture['chapters']['zh-CN']);
        }
        return reply({'results': [], 'data': []});
      });
      final id = await runner.recognition.enqueue(source, catalog.works.single['id'] as String, retry:true);
      await runner.run(id, manualRetry:true);
      expect(ScanRecognition.adopted(await record('tmdb','work'))?['id'],
          conflict ? null : fixture['series']);
      final confirmed = await catalog.db.query('scan_bindings',
          where:"layer='episode' AND provider='tmdb' AND state='confirmed'");
      expect(confirmed, hasLength(conflict ? 0 : split ? 26 : 10));
      if (conflict) return;
      if (split) {
        final parts = await catalog.db.query('scan_bindings',
            where:"layer='range' AND provider='bangumi' AND state='confirmed'");
        expect(parts.map((row) => ScanRecognition.adopted(row)?['id']), unorderedEquals([286123,297261]));
      } else {
        final chapters = confirmed.map(ScanRecognition.adopted);
        expect(chapters.where((c) => c?['episode'] == 1).map((c) => c?['broadcast_part']),
            unorderedEquals([1,2]));
        final range = ScanRecognition.adopted(await record('tmdb','range'));
        expect(range?['chapter_verification']['deferred_local_numbers'], [5,6]);
      }
    });
  }

  for (final conflictingTranslation in [false, true]) {
    test('complete dual numbering verifies a single disputed chapter: conflict=$conflictingTranslation', () async {
      await catalog.db.close();
      await open(automatic: true);
      final fixture = jsonDecode(
        await File('test/fixtures/nobunaga_season_numbering.json').readAsString(),
      ) as Map;
      for (var i = 1; i <= 26; i++) {
        final local = '$i'.padLeft(2, '0');
        final end = i == 26 ? ' END' : '';
        await video("${fixture['folder']}/[Moozzi2] Nobunaga no Shinobi S3 - $local [ ${i + 52} ]$end (BDRip).mkv");
      }
      useTransport((_) async => reply({'results': [], 'data': []}));
      await scan();
      for (final provider in ['tmdb', 'bangumi']) {
        await catalog.db.update('scan_bindings', {
          'state': 'pending',
          'reason': 'conflicting_title',
          'candidates': jsonEncode([fixture['candidates'][provider]]),
        }, where: "provider=? AND layer='work'", whereArgs: [provider]);
      }
      if (conflictingTranslation) {
        fixture['zh-CN']['episodes'][16]['name'] = '完全不同的集名';
      }
      useTransport((request) async {
        if (request.url.path == '/v0/episodes') return reply(fixture['bangumi']);
        if (request.url.path == '/3/tv/68146/season/3') {
          return reply(fixture[request.url.queryParameters['language'] == 'zh-CN' ? 'zh-CN' : 'ja-JP']);
        }
        return reply({}, 404);
      });
      await scan();
      final adopted = ScanRecognition.adopted(await record('tmdb', 'work'));
      expect(adopted?['id'], conflictingTranslation ? null : 68146);
      if (!conflictingTranslation) {
        final range = ScanRecognition.adopted(await record('tmdb', 'range'));
        expect(range?['season'], 3);
        expect(range?['offset'], -52);
        expect(range?['chapters'], hasLength(26));
      }
    });
  }

  for (final (differentDate, noLocalYear) in [(false, false), (true, false), (false, true), (true, true)]) {
    test('a marked movie uses matching official premiere evidence: conflict=$differentDate, no year=$noLocalYear', () async {
      await catalog.db.close();
      await open(automatic: true);
      const title = 'Example Adventure';
      const original = '冒険ものがたり';
      final directory = noLocalYear ? '$title {tmdb-59}' : '$title (2022) {tmdb-59}';
      final file = noLocalYear ? 'A Long The Movie Local Romanization' : 'A Long Local Romanization';
      await video('$directory/[Release] $file [BDRip].mkv');
      useTransport((_) async => reply({'results': [], 'data': []}));
      await scan();
      final work = catalog.works.single['id'];
      final candidate = {'id': 59, 'type': 'movie', 'marker': true, 'year': 2022,
        if (noLocalYear) 'aliases': ['A Long Local Romanization']};
      await catalog.db.update('scan_bindings', {
        'reason': 'untyped_id', 'candidates': jsonEncode([candidate]),
      }, where: "work_id=? AND provider='tmdb' AND layer='work'", whereArgs: [work]);
      await catalog.db.update('scan_bindings', {
        'state': 'confirmed', 'reason': 'verified_bangumi',
        'adopted': jsonEncode({'id': 61, 'type': 'anime', 'exact': true,
          'directory_title_matches': true, 'year': 2022, 'by': 'verified_bangumi'}),
      }, where: "work_id=? AND provider='bangumi' AND layer='work'", whereArgs: [work]);
      useTransport((request) async => switch (request.url.path) {
        '/3/tv/59' => reply({'id': 59, 'name': 'Different program', 'first_air_date': '2022-03-10'}),
        '/3/movie/59' => reply({'id': 59, 'title': title,
          'original_title': original, 'release_date': '2022-06-03',
          'alternative_titles': {'titles': [{'title': noLocalYear
            ? 'A Long Local Romanization' : 'The Complete A Long Local Romanization'}]}}),
        '/v0/subjects/61' => reply({'id': 61, 'type': 2, 'platform': '剧场版',
          'name': original, 'date': differentDate ? '2022-06-04' : '2022-06-03'}),
        _ => reply({'results': [], 'data': []}),
      });
      await scan();
      final tmdb = await record('tmdb', 'work');
      expect(ScanRecognition.adopted(tmdb)?['id'], differentDate ? null : 59);
      if (!differentDate) {
        expect(ScanRecognition.adopted(tmdb)?['type'], 'movie');
        expect(ScanRecognition.adopted(tmdb)?['verified_premiere'], isTrue);
      }
      expect(ScanRecognition.adopted(await record('bangumi', 'work'))?['id'], 61);
    });
  }

  test('rescan skips hidden work with a retryable provider binding', () async {
    await catalog.db.close();
    await open(automatic: true);
    await video('Hidden Title/Hidden Title - 01.mkv');
    await video('Visible Title/Visible Title - 01.mkv');
    useTransport((_) async => reply({'results': [], 'data': []}));
    await scan();
    final work = catalog.works.singleWhere((row) => row['title'] == 'Hidden Title')['id'];
    await catalog.db.update('works', {'hidden': 1, 'keep_hidden': 1},
        where: 'id=?', whereArgs: [work]);
    await catalog.db.update('scan_bindings', {'reason': 'query_incomplete'},
        where: "work_id=? AND layer='work'", whereArgs: [work]);
    final scanId = await runner.enqueueScan(source);
    await runner.run(scanId);
    final scanTask = (await catalog.db.query('scrape_tasks',
        where: 'id=?', whereArgs: [scanId])).single;
    expect(scanTask['state'], 'complete');
  });

  test('two verified films leave a mixed TV work without changing asset ids', () async {
    await catalog.db.close();
    await open(automatic: true);
    const folder = 'Example Series';
    const episodeCount = 42;
    for (var episode = 1; episode <= episodeCount; episode++) {
      final number = episode.toString().padLeft(2, '0');
      await video('$folder/Example.Series.S01E$number.mkv');
    }
    await video('$folder/Example.Series.Movie.1.2017.mkv');
    await video('$folder/Example.Series.Movie.2.2018.mkv');
    useTransport((request) async =>
        reply(request.url.path.contains('/3/') ? {'results': []} : {'data': []}));
    await scan();
    final work = catalog.works.single['id'];
    final ids = catalog.assets.map((asset) => asset['id']).toSet();
    for (final provider in ['tmdb', 'bangumi']) {
      await catalog.db.update('scan_bindings', {
        'state': 'confirmed', 'reason': 'verified_$provider',
        'adopted': jsonEncode({
          'id': provider == 'tmdb' ? 42 : 43,
          'type': provider == 'tmdb' ? 'tv' : 'anime',
          'by': 'verified_$provider',
          if (provider == 'tmdb')
            'seasons': [{'season': 1, 'count': episodeCount, 'year': 1978}],
        }),
      }, where: "work_id=? AND provider=? AND layer='work'", whereArgs: [work, provider]);
    }
    Map<String, Object> movie(int part) => {
      'id': 90 + part, 'title': part == 1 ? 'Example Series Part One' : 'Example Series Part Two',
      'original_title': '劇場版 作品 第$part部', 'release_date': '${2016 + part}-01-01',
    };
    useTransport((request) async => switch (request.url.path) {
      '/v0/subjects/43/subjects' => reply([{'id': 81, 'type': 2, 'relation': '不同演绎'}]),
      '/v0/subjects/81/subjects' => reply([{'id': 82, 'type': 2, 'relation': '续集'}]),
      '/v0/subjects/81' || '/v0/subjects/82' => reply({
        'id': int.parse(request.url.pathSegments.last), 'type': 2, 'platform': '剧场版',
        'name': '劇場版 作品 第${request.url.pathSegments.last == '81' ? 1 : 2}部',
        'date': request.url.pathSegments.last == '81' ? '2017-01-01' : '2018-01-01',
      }),
      '/3/search/movie' => reply({'results': [
        movie(request.url.queryParameters['primary_release_year'] == '2017' ? 1 : 2),
      ]}),
      '/3/movie/91' => reply(movie(1)),
      '/3/movie/92' => reply(movie(2)),
      '/3/tv/42/season/1' => reply({
        'season_number': 1,
        'episodes': [
          for (var episode = 1; episode <= episodeCount; episode++)
            {
              'id': 100 + episode,
              'episode_number': episode,
              'season_number': 1,
              'name': 'Episode $episode',
              'still_path': '/still-$episode.jpg',
            },
        ],
      }),
      _ => reply({'data': []}),
    });
    await scan();
    expect(catalog.works, hasLength(3));
    expect(catalog.assets.map((asset) => asset['id']).toSet(), ids);
    expect(catalog.forWork(work as String), hasLength(episodeCount));
    final tv = catalog.works.singleWhere((entry) => entry['id'] == work);
    final details = await ScanRecognition.details(catalog, tv);
    final files = details!['recognized_file_details'] as Map;
    for (final file in catalog.forWork(work)) {
      expect((files[file['id']] as Map)['still'], endsWith('/still-${file['episode']}.jpg'));
    }
    final rows = await catalog.db.query('scan_bindings', where: "reason='verified_movie'");
    expect(rows.map(ScanRecognition.adopted).map((identity) => identity?['id']),
        unorderedEquals([81, 82, 91, 92]));
    for (var part = 1; part <= 2; part++) {
      final file = catalog.assets.singleWhere((a) =>
          (a['name'] as String).contains('Movie.$part.'));
      final identity = rows.where((row) => row['work_id'] == file['work_id']);
      expect(identity.map(ScanRecognition.adopted).map((value) => value?['id']),
          unorderedEquals([80 + part, 90 + part]));
    }
    await scan();
    expect(catalog.works, hasLength(3));
  });

  for (final conflict in [false, true]) {
    test('a complete season verifies both local and absolute numbers: conflict=$conflict', () async {
      await catalog.db.close();
      await open(automatic: true);
      for (var episode = 1; episode <= 3; episode++) {
        final absolute = episode + (conflict ? 13 : 12);
        final end = episode == 3 ? ' END' : '';
        await video('Example Story 第二季/[Group] Example Story S2 - 0$episode$end [ $absolute ] (BDRip).mkv');
      }
      useTransport((_) async => reply({'results': [], 'data': []}));
      await scan();
      final work = catalog.works.single['id'];
      for (final (provider, value) in [
        ('tmdb', {'id': 42, 'type': 'tv', 'by': 'verified_tmdb', 'seasons': [
          {'season': 1, 'count': 12, 'year': 2012},
          {'season': 2, 'count': 3, 'year': 2013},
        ]}),
        ('bangumi', {'id': 43, 'type': 'anime', 'by': 'verified_bangumi',
          'year': 2013, 'exact': true, 'directory_title_matches': true}),
      ]) {
        await catalog.db.update('scan_bindings', {
          'state': 'confirmed', 'reason': 'verified_$provider', 'adopted': jsonEncode(value),
        }, where: "work_id=? AND provider=? AND layer='work'", whereArgs: [work, provider]);
      }
      useTransport((request) async {
        if (request.url.path != '/3/tv/42/season/2') return reply({'results': [], 'data': []});
        return reply({'season_number': 2, 'episodes': [
          for (var episode = 1; episode <= 3; episode++)
            {'id': 100 + episode, 'episode_number': episode, 'season_number': 2,
              'name': 'Episode $episode', 'still_path': '/still-$episode.jpg'},
        ]});
      });
      await scan();
      final rows = await catalog.db.query('scan_bindings',
          where: "work_id=? AND provider='tmdb' AND layer='episode' AND state='confirmed'",
          whereArgs: [work]);
      expect(rows.map(ScanRecognition.adopted).map((a) => a?['episode']),
          unorderedEquals(conflict ? <int>[] : [1, 2, 3]));
    });
  }

  test('an existing series uses independently verified season year and complete numbering', () async {
    await catalog.db.close();
    await open(automatic: true);
    for (var i = 1; i <= 3; i++) {
      await video('Example Story Second Arc/Example Story Second Arc - 0$i.mkv');
    }
    useTransport((request) async =>
        reply(request.url.path.contains('/3/') ? {'results': []} : {'data': []}));
    await scan();
    final work = catalog.works.single['id'];
    await catalog.db.update('scan_bindings', {
      'state': 'confirmed', 'reason': 'verified_tmdb',
      'adopted': jsonEncode({'id': 42, 'type': 'tv', 'by': 'verified_tmdb',
        'seasons': [
          {'season': 1, 'year': 2010, 'count': 3},
          {'season': 2, 'year': 2012, 'count': 3},
        ]}),
    }, where: "work_id=? AND provider='tmdb' AND layer='work'", whereArgs: [work]);
    await catalog.db.update('scan_bindings', {
      'state': 'confirmed', 'reason': 'verified_bangumi',
      'adopted': jsonEncode({'id': 43, 'type': 'anime', 'by': 'verified_bangumi',
        'year': 2012, 'exact': true, 'directory_title_matches': true}),
    }, where: "work_id=? AND provider='bangumi' AND layer='work'", whereArgs: [work]);
    final paths = <String>[];
    useTransport((request) async {
      paths.add(request.url.path);
      return reply({'season_number': 2, 'episodes': [
        for (var i = 1; i <= 3; i++)
          {'id': 420 + i, 'season_number': 2, 'episode_number': i,
            'name': 'Episode $i', 'still_path': '/second-$i.jpg'},
      ]});
    });
    await scan();
    expect(paths, ['/3/tv/42/season/2']);
    expect(ScanRecognition.adopted(await record('tmdb', 'range'))?['season'], 2);
  });

  for (final verifiedSeason in [true, false]) {
    test('86 movie alias conflict with verified season=$verifiedSeason', () async {
    await catalog.db.close();
    await open(automatic: true);
    const name = '86 -不存在的战区-';
    const series = {
      'id': 100565, 'media_type': 'tv', 'name': name,
      'first_air_date': '2021-04-11',
      'seasons': [{'season_number': 1, 'episode_count': 23}],
    };
    const movie = {
      'id': 1367516, 'media_type': 'movie', 'title': 'Eighty-Six',
      'release_date': '2024-05-01',
    };
    const subject = {
      'id': 302189, 'type': 2, 'name': '86―エイティシックス―', 'name_cn': name,
      'date': '2021-04-11',
    };
    for (var number = 1; number <= 23; number++) {
      final index = number.toString().padLeft(2, '0');
      await video('$name/[UHA-WINGS&VCB-Studio] EIGHTY SIX [$index].mkv');
    }
    useTransport((request) async {
      return switch (request.url.path) {
        '/3/search/multi' => reply({'results': [series, movie], 'total_pages': 1}),
        '/3/tv/100565' => reply(series),
        '/3/movie/1367516' => reply(movie),
        '/3/tv/100565/season/1' => !verifiedSeason ? reply({}, 503) : reply({
          'season_number': 1,
          'episodes': [
            for (var i = 1; i <= 23; i++)
              {'id': 1000 + i, 'season_number': 1, 'episode_number': i, 'name': 'Episode $i'},
          ],
        }),
        '/v0/search/subjects' => reply({'data': [subject], 'total': 1}),
        '/v0/subjects/302189' => reply(subject),
        _ => reply(request.url.path.contains('/3/') ? {'results': []} : {'data': []}),
      };
    });
    await scan();
    final tmdb = await record('tmdb', 'work');
    expect(ScanRecognition.candidates(tmdb).map((row) => row['id']), contains(1367516));
    final bangumi = await record('bangumi', 'work');
    if (!verifiedSeason) {
      expect(bangumi['reason'], 'conflicting_title');
      expect(ScanRecognition.adopted(bangumi), isNull);
      return;
    }
    expect(ScanRecognition.adopted(await record('tmdb', 'range'))?['season'], 1);
    expect(bangumi['reason'], 'verified_bangumi');
    expect(ScanRecognition.adopted(bangumi)?['id'], 302189);

    // Replay a pending identity saved by the previous acceptance package.
    await catalog.db.update('scan_bindings', {
      'state': 'pending', 'reason': 'conflicting_title', 'adopted': null,
    }, where: 'id=?', whereArgs: [bangumi['id']]);
    await scan();
    final recovered = await record('bangumi', 'work');
    expect(recovered['reason'], 'verified_bangumi');
    expect(ScanRecognition.adopted(recovered)?['id'], 302189);
    });
  }

  test(
    'untyped 86 matches S1 and leaves the special and failed source separate',
    () async {
      await catalog.db.close();
      await open(automatic: true);
      const folder = '86 -不存在的战区- (2021) {tmdb-100565}';
      for (var number = 1; number <= 23; number++) {
        final index = number.toString().padLeft(2, '0');
        await video('$folder/[UHA-WINGS&VCB-Studio] EIGHTY SIX [$index].mkv');
      }
      const decimals = ['11.5', '17.5', '18.5', '21.5'];
      for (final number in decimals) {
        await video('$folder/SPs/EIGHTY SIX [$number].mkv');
      }
      await video('$folder/SPs/EIGHTY SIX [99.5].mkv');
      await video('$folder/SPs/NCOP 1.mkv');
      final requested = <String>[];
      useTransport((request) async {
        final path = request.url.path;
        requested.add(path);
        return switch (path) {
          '/3/tv/100565' => reply({
            'id': 100565,
            'name': '86-不存在的战区-',
            'first_air_date': '2021-04-11',
            'seasons': [
              {'season_number': 0, 'episode_count': 5},
              {'season_number': 1, 'episode_count': 23},
            ],
          }),
          '/3/movie/100565' => reply({
            'id': 100565,
            'title': 'Auftrag Schutzengel',
            'release_date': '2009-01-01',
          }),
          '/3/tv/100565/season/1' => reply({
            'season_number': 1,
            'episodes': [
              for (var i = 1; i <= 23; i++)
                {
                  'id': 100 + i,
                  'season_number': 1,
                  'episode_number': i,
                  'name': 'Episode $i',
                  'still_path': '/episode-$i.jpg',
                },
            ],
          }),
          '/3/tv/100565/season/0' => reply({
            'season_number': 0,
            'episodes': [
              for (var i = 0; i < decimals.length; i++)
                {
                  'id': 200 + i,
                  'season_number': 0,
                  'episode_number': i + 2,
                  'name': 'Special ${i + 2}',
                  'overview': 'SP${decimals[i]}',
                  'still_path': '/special-$i.jpg',
                },
            ],
          }),
          _ => reply({}, 503),
        };
      });
      await scan();
      expect(
        ScanRecognition.adopted(await record('tmdb', 'work'))?['type'],
        'tv',
      );
      expect(
        ScanRecognition.adopted(await record('tmdb', 'range'))?['season'],
        1,
      );
      expect((await record('bangumi', 'work'))['reason'], 'request_failed');
      expect(
        ScanRecognition.adopted(
          await record('tmdb', 'range', scope: 'SPs'),
        )?['season'],
        0,
      );
      expect(
        requested.where((path) => path == '/3/tv/100565/season/0'),
        hasLength(1),
      );
      final specials = await catalog.db.rawQuery(
        """SELECT a.name, b.state, b.adopted FROM assets a
        JOIN scan_bindings b ON b.asset_id=a.id WHERE a.category='extra'""",
      );
      expect(
        specials
            .where((row) => row['state'] == 'confirmed')
            .map((row) => ScanRecognition.adopted(row)?['episode']),
        unorderedEquals([2, 3, 4, 5]),
      );
      expect(
        specials.singleWhere(
          (row) => '${row['name']}'.contains('99.5'),
        )['state'],
        'pending',
      );
      expect(specials.any((row) => '${row['name']}'.contains('NCOP')), isFalse);
      final details = await ScanRecognition.details(
        catalog,
        catalog.works.single,
      );
      expect(details?['recognized_episodes'], 27);
      final episodes = (details!['recognized_file_details'] as Map).values;
      expect(
        episodes
            .map((episode) => episode['still'])
            .where((value) => '$value'.contains('/episode-')),
        hasLength(23),
      );
      expect(
        episodes
            .map((episode) => episode['still'])
            .where((value) => '$value'.contains('/special-')),
        hasLength(4),
      );
      final before = requested.length;
      await scan();
      expect(requested, hasLength(before));
    },
  );

  test(
    'series resumes automatically and checks directory year against the season',
    () async {
      await catalog.db.close();
      await open(automatic: true, artwork: true);
      const name = '为美好的世界献上祝福！';
      for (final (year, suffix) in [
        (2016, ''),
        (2017, ' 第二季'),
        (2024, ' 第三季'),
      ]) {
        await video('$name$suffix ($year) {tmdb-65844}/[Group] $name [01].mkv');
        await video('$name$suffix ($year) {tmdb-65844}/[Group] $name [02].mkv');
        if (year == 2024) {
          await video(
            '$name$suffix ($year) {tmdb-65844}/[Group] $name [12(OVA01)].mkv',
          );
          await video(
            '$name$suffix ($year) {tmdb-65844}/[Group] $name [13(OVA02)].mkv',
          );
        } else {
          await video(
            '$name$suffix ($year) {tmdb-65844}/[Group] $name [11(OVA)].mkv',
          );
        }
      }
      useTransport((request) async {
        final path = request.url.path;
        if (path == '/3/tv/65844') {
          return reply({
            'id': 65844,
            'name': name,
            'first_air_date': '2016-01-01',
            'backdrop_path': '/series-default.jpg',
            'seasons': [
              {'season_number': 0, 'episode_count': 4},
              for (final (season, year) in [(1, 2016), (2, 2017), (3, 2024)])
                {
                  'season_number': season,
                  'episode_count': 2,
                  'air_date': '$year-01-01',
                },
            ],
          });
        }
        if (path == '/3/tv/65844/season/0') {
          return reply({
            'season_number': 0,
            'episodes': [
              for (final (i, date, title) in [
                (1, '2016-06-24', 'OAD A'),
                (2, '2017-07-24', 'OAD B'),
                (3, '2025-04-25', 'OVA1 C'),
                (4, '2025-04-25', 'OVA2 D'),
              ])
                {
                  'id': 100 + i,
                  'season_number': 0,
                  'episode_number': i,
                  'name': title,
                  'air_date': date,
                  'still_path': '/ova-$i.jpg',
                },
            ],
          });
        }
        if (path.startsWith('/3/tv/65844/season/')) {
          final season = int.parse(path.split('/').last);
          return reply({
            'season_number': season,
            'episodes': [
              for (var i = 1; i <= 2; i++)
                {
                  'id': season * 10 + i,
                  'season_number': season,
                  'episode_number': i,
                  'name': 'Episode $i',
                },
            ],
          });
        }
        if (path == '/3/movie/65844') return reply({}, 404);
        return reply({'data': []});
      });
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      final scanId = await runner.enqueueScan(source);
      try {
        runner.startAutomaticQueue();
        expect(
          (await catalog.db.query(
            'scrape_tasks',
            where: 'id=?',
            whereArgs: [scanId],
          )).single['state'],
          'queued',
        );
      } finally {
        binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
        binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      }
      final clock = Stopwatch()..start();
      while (!runner.isIdle && clock.elapsed < const Duration(seconds: 10)) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
      expect(runner.isIdle, isTrue);
      final ranges = await catalog.db.query(
        'scan_bindings',
        where: "provider='tmdb' AND layer='range' AND state='confirmed'",
      );
      expect(
        ranges.map((row) => ScanRecognition.adopted(row)?['season']),
        unorderedEquals([0, 0, 0, 1, 2, 3]),
      );
      expect(catalog.works, hasLength(3));
      final specials = await catalog.db.rawQuery(
        """SELECT b.adopted FROM scan_bindings b JOIN assets a ON a.id=b.asset_id
        WHERE b.state='confirmed' AND b.provider='tmdb' AND a.extra_type='OVA'""",
      );
      expect(
        specials.map((row) => ScanRecognition.adopted(row)?['episode']),
        unorderedEquals([1, 2, 3, 4]),
      );
      expect(
        specials.map((row) => ScanRecognition.adopted(row)?['still']),
        everyElement(contains('/w300/ova-')),
      );
      Metadata.token = '';
      for (final work in catalog.works) {
        expect(
          await runner.artwork.displayed(
            work['id'] as String,
            ScopedImage.backdrop,
          ),
          endsWith('/series-default.jpg'),
        );
      }
    },
  );

  test(
    'typed lookup and failed source are independent; 86 ranges and SP stay separate',
    () async {
      const folder = '86 (2021) {tmdbtv-86}';
      await video('$folder/Part 1/S01E01.mkv');
      await video('$folder/Part 2/S01E01.mkv');
      await video('$folder/Part 2/SP 11.5.mkv');
      var tmdbRequests = 0, bangumiRequests = 0;
      useTransport((request) async {
        if (request.url.path == '/3/tv/86') {
          tmdbRequests++;
          return reply({
            'id': 86,
            'name': '86',
            'first_air_date': '2021-04-11',
            'seasons': [
              {'season_number': 1, 'episode_count': 23},
            ],
          });
        }
        bangumiRequests++;
        return reply({}, 503);
      });
      await scan();
      expect(catalog.assets, hasLength(3));
      expect(catalog.works, hasLength(1));
      expect(catalog.works.single['tmdb_id'], isNull);
      expect(tmdbRequests, 1);
      expect(bangumiRequests, greaterThan(0));
      final tmdb = await record('tmdb', 'work');
      expect(tmdb['reason'], 'verify_candidate');
      expect((await record('bangumi', 'work'))['reason'], 'request_failed');
      expect(
        await catalog.db.query('scan_bindings', where: "layer='range'"),
        isEmpty,
      );

      await runner.recognition.decide(
        tmdb,
        ScanRecognition.candidates(tmdb).single,
      );
      final titleOnly = await ScanRecognition.details(
        catalog,
        catalog.works.single,
      );
      expect(titleOnly!['recognized_title'], '86');
      expect(titleOnly['recognized_ranges'], 0);
      final lower = await record('tmdb', 'range', scope: 'Part 2');
      await runner.recognition.decide(lower, {
        'season': 1,
        'first': 12,
        'last': 23,
        'offset': 11,
      });
      final files = await catalog.db.rawQuery(
        '''SELECT b.*,a.name FROM scan_bindings b
      JOIN assets a ON a.id=b.asset_id WHERE b.provider='tmdb' ORDER BY a.name''',
      );
      expect(files, hasLength(2));
      final episode = files.singleWhere((r) => r['name'] == 'S01E01.mkv');
      final special = files.singleWhere((r) => r['name'] == 'SP 11.5.mkv');
      expect(ScanRecognition.candidates(episode).single['episode'], 12);
      expect(ScanRecognition.candidates(special), isEmpty);
      expect(special['state'], 'pending');
      final episodePreview = await withToken(episode);
      await runner.recognition.decide(
        episodePreview,
        ScanRecognition.candidates(episode).single,
      );
      expect(
        (await record('tmdb', 'range', scope: 'Part 1'))['state'],
        'pending',
      );

      final before = (tmdbRequests, bangumiRequests);
      await video('$folder/Part 2/S01E02.mkv', 17);
      await scan();
      expect((tmdbRequests, bangumiRequests), before);
      expect(catalog.assets, hasLength(4));
      final newFile = catalog.assets.singleWhere(
        (a) => a['name'] == 'S01E02.mkv',
      );
      final newEpisode = await record(
        'tmdb',
        'episode',
        scope: newFile['id'] as String,
      );
      expect(ScanRecognition.candidates(newEpisode).single['episode'], 13);
      expect(
        (await record(
          'tmdb',
          'episode',
          scope: episode['asset_id'] as String,
        ))['state'],
        'confirmed',
      );
      await expectLater(
        runner.recognition.decide(episodePreview, {'season': 1, 'episode': 99}),
        throwsStateError,
      );
    },
  );

  test(
    'untyped ID probes both types; same-name remakes stay in review',
    () async {
      await video('Series {tmdb-42}/S01E01.mkv');
      await video('Remake/S01E01.mkv');
      final paths = <String>[];
      useTransport((request) async {
        paths.add(request.url.path);
        return switch (request.url.path) {
          '/3/tv/42' => reply({'id': 42, 'name': 'Series'}),
          '/3/movie/42' => reply({'id': 42, 'title': 'Series'}),
          '/3/search/multi' => reply({
            'results': [
              {
                'id': 1,
                'media_type': 'tv',
                'name': 'Remake',
                'first_air_date': '1995-01-01',
              },
              {
                'id': 2,
                'media_type': 'tv',
                'name': 'Remake',
                'first_air_date': '2025-01-01',
              },
            ],
          }),
          _ => reply({'data': []}),
        };
      });
      await scan();
      final tmdb = await catalog.db.query(
        'scan_bindings',
        where: "provider='tmdb' AND layer='work'",
      );
      expect(
        tmdb.map((r) => r['reason']),
        unorderedEquals(['untyped_id', 'ambiguous']),
      );
      expect(
        tmdb.every(
          (r) =>
              ScanRecognition.candidates(r).length == 2 && r['adopted'] == null,
        ),
        isTrue,
      );
      expect(
        paths,
        containsAll([
          '/3/tv/42',
          '/3/movie/42',
          '/3/search/multi',
          '/v0/search/subjects',
        ]),
      );
      expect(catalog.works.every((w) => w['tmdb_id'] == null), isTrue);
    },
  );

  test(
    'same TMDB ID stays separate across three works; OVA folders get distinct ranges',
    () async {
      for (final season in [1, 2, 3]) {
        await video('Genesis Season $season {tmdbtv-75}/E01.mkv', season);
      }
      await video('OVA Collection/Disc 1/E01.mkv', 21);
      await video('OVA Collection/Disc 2/E01.mkv', 22);
      useTransport(
        (request) async => switch (request.url.path) {
          '/3/tv/75' => reply({
            'id': 75,
            'name': 'Genesis',
            'seasons': [
              for (final season in [1, 2, 3])
                {'season_number': season, 'episode_count': 12},
            ],
          }),
          '/3/search/multi' => reply({'results': []}),
          _ => reply({'data': []}),
        },
      );
      await scan();
      expect(catalog.works, hasLength(4));
      final typed = (await catalog.db.query(
        'scan_bindings',
        where: "provider='tmdb' AND layer='work'",
      )).where((r) => ScanRecognition.candidates(r).isNotEmpty).toList();
      expect(typed, hasLength(3));
      for (final row in typed) {
        await runner.recognition.decide(
          await withToken(row),
          ScanRecognition.candidates(row).single,
        );
      }
      final ova = (await catalog.db.rawQuery(
        '''SELECT b.* FROM scan_bindings b JOIN works w
      ON w.id=b.work_id WHERE b.layer='work' AND b.provider='bangumi' AND w.title='OVA Collection' ''',
      )).single;
      await runner.recognition.decide(await withToken(ova), {
        'type': 'anime',
        'id': 150,
      });
      final ovaRanges = await catalog.db.query(
        'scan_bindings',
        where: "work_id=? AND provider='bangumi' AND layer='range'",
        whereArgs: [ova['work_id']],
      );
      expect(
        ovaRanges.map((r) => r['scope']),
        unorderedEquals(['Disc 1', 'Disc 2']),
      );
    },
  );

  test(
    'directory checkpoints survive a reopened DB and incomplete scans do not mark missing',
    () async {
      await catalog.db.update(
        'sources',
        {'location': 'content://example/tree/test'},
        where: 'id=?',
        whereArgs: [source],
      );
      await catalog.reload();
      await catalog.indexVideo(source, 'Old/01.mkv', 5, workFolder: 'Old');
      final calls = <String>[];
      var unavailable = true;
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        LocalMedia.channel,
        (call) async {
          final path = call.arguments['relative'] as String;
          calls.add(path);
          if (path.isEmpty) {
            return [
              {'name': 'New', 'directory': true},
            ];
          }
          if (unavailable) return null;
          return [
            {'name': '02.mkv', 'directory': false, 'size': 12},
          ];
        },
      );
      final id = await runner.enqueueScan(source);
      await runner.run(id);
      expect(await catalog.db.query('scan_missing_assets'), isEmpty);
      expect(calls, ['', 'New']);
      final checkpoint = await catalog.db.query(
        'scan_directory_checkpoints',
        where: 'complete=1',
      );
      expect(checkpoint.single['path'], '');
      await catalog.db.close();
      await open();
      useTransport(
        (request) async => reply(
          request.url.path.contains('/3/') ? {'results': []} : {'data': []},
        ),
      );
      unavailable = false;
      await runner.tasks.control(id, 'retry');
      await runner.run(id, manualRetry: true);
      expect(calls, ['', 'New', 'New']);
      final progress = ScanActivityStore.instance.forSource(source)!;
      expect(progress.completedFolders, {'', 'New'});
      expect(progress.videoCount, 1);
      expect(await catalog.db.query('scan_directory_checkpoints'), isEmpty);
      expect(await catalog.db.query('scan_missing_assets'), hasLength(1));
      expect(catalog.assets, hasLength(2));
    },
  );

  test(
    'rename review preserves stable asset and work IDs across repeated scans',
    () async {
      await video('Original/E01.mkv');
      await video('Original/E02.mkv', 11);
      await scan();
      final assets = catalog.assets.map((a) => a['id']).toSet();
      final work = catalog.works.single['id'] as String;
      await Directory('${media.path}/Original').rename('${media.path}/Renamed');
      await scan();
      expect(catalog.works, hasLength(1));
      Future<Map<String, Object?>> move() async => (await catalog.db.rawQuery(
        'SELECT m.*,s.session FROM scan_move_reviews m CROSS JOIN scrape_runtime s',
      )).single;
      final row = await move();
      await IncrementalScan(catalog).resolveMove(row, null, skip: true);
      await scan();
      final saved = await move();
      expect(saved['skipped'], 1);
      await IncrementalScan(catalog).resolveMove(saved, work);
      await scan();
      expect(catalog.assets.map((a) => a['id']).toSet(), assets);
      expect(
        catalog.assets.every(
          (a) => (a['relative_path'] as String).startsWith('Renamed/'),
        ),
        isTrue,
      );
      expect(await catalog.db.query('scan_missing_assets'), isEmpty);
      expect(await catalog.db.query('scan_move_reviews'), isEmpty);
      expect(catalog.works.single['id'], work);
    },
  );

  test(
    'old response cannot replace a manual decision or publish after restore',
    () async {
      await video('Series/01.mkv');
      final entered = Completer<void>();
      final response = Completer<http.Response>();
      useTransport((request) async {
        if (request.url.path == '/3/search/multi') {
          entered.complete();
          return response.future;
        }
        return reply({'data': []});
      });
      final scanning = scan();
      await entered.future;
      final before = await record('tmdb', 'work');
      await runner.recognition.decide(before, {'type': 'tv', 'id': 99});
      response.complete(
        reply({
          'results': [
            {'id': 42, 'media_type': 'tv', 'name': 'Series'},
          ],
        }),
      );
      await scanning;
      expect(ScanRecognition.adopted(await record('tmdb', 'work'))!['id'], 99);
      final prefs = await SharedPreferences.getInstance();
      final artwork = Directory('${library.path}/artwork');
      final backup = await LibraryBackupExporter(
        database: catalog.db,
        artworkDirectory: artwork,
        preferences: prefs,
      ).export(File('${scratch.path}/snapshot.zip'));
      final changed = await record('tmdb', 'work');
      await runner.recognition.decide(changed, {'type': 'tv', 'id': 81});
      final restorer = LibraryBackupRestorer(
        database: catalog.db,
        artworkDirectory: artwork,
      );
      final prepared = await restorer.prepare(backup);
      await restorer.restore(prepared);
      await prepared.dispose();
      expect(ScanRecognition.adopted(await record('tmdb', 'work'))!['id'], 99);
      await expectLater(
        runner.recognition.decide(changed, {'type': 'tv', 'id': 72}),
        throwsStateError,
      );
    },
  );

  test(
    'confirmed scope fetches chapters and mapping changes preserve adopted targets',
    () async {
      await video('Series/E01.mkv');
      useTransport(
        (request) async => switch (request.url.path) {
          '/v0/episodes' => reply({
            'data': [
              {
                'id': 101,
                'subject_id': 1,
                'sort': 1,
                'type': 0,
                'name_cn': '第一集',
              },
              {
                'id': 999,
                'subject_id': 2,
                'sort': 1,
                'type': 0,
                'name_cn': '其他作品',
              },
            ],
          }),
          '/3/search/multi' => reply({'results': []}),
          _ => reply({'data': []}),
        },
      );
      await scan();
      await runner.recognition.decide(await record('tmdb', 'work'), {
        'type': 'tv',
        'id': 42,
      });
      await runner.recognition.decide(await record('tmdb', 'range'), {
        'season': 1,
        'first': 1,
        'last': 12,
        'offset': 0,
      });
      await runner.recognition.decide(await record('bangumi', 'work'), {
        'type': 'anime',
        'id': 1,
      });
      final bangumiRange = await record('bangumi', 'range');
      await runner.recognition.decide(bangumiRange, {'id': 1});
      await runner.run(
        await runner.recognition.enqueueRange(
          source,
          bangumiRange['id'] as String,
        ),
      );
      final asset = catalog.assets.single['id'] as String;
      final chapter = await record('bangumi', 'episode', scope: asset);
      expect(ScanRecognition.candidates(chapter).single['title'], '第一集');
      final store = catalog.mappingStore!;
      final v1 = '1' * 40, v2 = '2' * 40;
      await store.registerVersion(v1);
      await store.registerVersion(v2);
      await store.proveDescendant(v1, v2, {
        'status': 'ahead',
        'base_commit': {'sha': v1},
        'merge_base_commit': {'sha': v1},
        'commits': [
          {'sha': v2},
        ],
      });
      Future<void> import(String version, int episode) async {
        final id = 'fixture:$episode';
        await runner.tasks.enqueue(id, intent: {}, steps: ['mapping']);
        final lease = (await runner.tasks.claim(id, 'mapping'))!;
        await store.importDetail(version, {
          'schemaVersion': 1,
          'bangumiId': 1,
          'targets': [
            {'type': 'tv', 'id': 42, 'season': 1},
          ],
          'episodes': [
            {'id': 101, 'type': 0, 'sort': 1},
          ],
          'rules': [
            {
              'bangumiType': 0,
              'start': 1,
              'end': 1,
              'tmdbId': 42,
              'season': 1,
              'episodeStart': episode,
            },
          ],
          'overrides': [],
        }, lease);
      }

      await import(v1, 1);
      await runner.recognition.decide(
        chapter,
        ScanRecognition.candidates(chapter).single,
      );
      final target = await record('tmdb', 'episode', scope: asset);
      final option = ScanRecognition.candidates(target).single;
      expect(option['mapping_version'], v1);
      await runner.recognition.decide(target, option);
      await import(v2, 2);
      await runner.recognition.auditMappings();
      final review = await record('tmdb', 'episode', scope: asset);
      expect(review['reason'], 'mapping_changed');
      expect(ScanRecognition.adopted(review)!['episode'], 1);
      expect(ScanRecognition.candidates(review).single['episode'], 2);
    },
  );

  test('version discovery pins the release tag before any downloads', () async {
    final version = 'a' * 40;
    final paths = <String>[];
    useTransport((request) async {
      paths.add(request.url.path);
      return reply({
        'tag_name': 'data-$version',
        'draft': false,
        'prerelease': false,
      });
    });
    final acquisition = AnimeMappingAcquisition(
      catalog.mappingStore!,
      runner.requests,
    );
    final id = await acquisition.enqueueDiscovery();
    await runner.run(id);
    final result = (await catalog.db.query(
      'scrape_steps',
      where: 'task_id=?',
      whereArgs: [id],
    )).single;
    expect(jsonDecode(result['result_json'] as String), {'version': version});
    expect(paths.single, endsWith('/releases/latest'));
  });

  test(
    'only corroborated typed movies auto-confirm when explicitly enabled',
    () async {
      await catalog.db.close();
      await open(automatic: true);
      await video('Film (2025) {tmdbmovie-42}/Film.mkv');
      await video('Different (2025) {tmdbmovie-43}/Unrelated.mkv');
      useTransport((request) async {
        final path = request.url.path;
        if (path == '/3/movie/42') {
          return reply({
            'id': 42,
            'title': 'Film',
            'release_date': '2025-01-01',
            'backdrop_path': '/film-still.jpg',
          });
        }
        if (path == '/3/movie/43') {
          return reply({
            'id': 43,
            'title': 'Different',
            'release_date': '2025-01-01',
          });
        }
        final keyword = (jsonDecode(request.body) as Map)['keyword'];
        return reply({
          'data': [
            {
              'id': keyword == 'Film' ? 1 : 2,
              'type': 2,
              'name': keyword,
              'date': '2025-01-01',
            },
          ],
        });
      });
      final version = 'f' * 40;
      final store = catalog.mappingStore!;
      await store.registerVersion(version);
      for (final subject in [1, 2]) {
        final id = 'film:$subject';
        await runner.tasks.enqueue(id, intent: {}, steps: ['mapping']);
        final lease = (await runner.tasks.claim(id, 'mapping'))!;
        await store.importDetail(version, {
          'schemaVersion': 1,
          'bangumiId': subject,
          'targets': [
            {'type': 'movie', 'id': 41 + subject},
          ],
          'episodes': [],
          'rules': [],
          'overrides': [],
        }, lease);
      }
      await scan();
      final adopted = await catalog.db.query(
        'scan_bindings',
        where: "state='confirmed'",
      );
      expect(adopted, hasLength(2));
      expect(
        adopted.every(
          (row) => row['layer'] == 'work' && row['reason'] == 'verified_movie',
        ),
        isTrue,
      );
      final matched = catalog.works.singleWhere(
        (row) => row['title'] == 'Film',
      );
      expect(adopted.every((row) => row['work_id'] == matched['id']), isTrue);
      final details = await ScanRecognition.details(catalog, matched);
      expect(details?['recognized_movie'], true);
      expect(details?['movieStill'], endsWith('/w780/film-still.jpg'));
      await catalog.db.close();
      await open();
      expect(catalog.automaticRecognition, isFalse);
      expect(
        await catalog.db.query('scan_bindings', where: "state='confirmed'"),
        adopted,
      );
    },
  );

  test(
    'same-folder group, numbering preview, stale commit and portable restore',
    () async {
      const folder = 'Grouped';
      for (final name in [
        'Upper S01E01',
        'Lower S01E01',
        'Lower S01E03',
        'Lower A S01E04',
        'Lower B S01E04',
        'Lower SP 2.5',
      ]) {
        await video('$folder/$name.mkv');
      }
      useTransport((request) async {
        if (request.url.path == '/3/tv/42/season/1') {
          return reply({
            'season_number': 1,
            'episodes': [
              for (var n = 1; n <= 13; n++)
                {
                  'id': 200 + n,
                  'season_number': 1,
                  'episode_number': n,
                  'name': 'Chapter $n',
                },
            ],
          });
        }
        return reply(
          request.url.path.contains('/3/') ? {'results': []} : {'data': []},
        );
      });
      await scan();
      await runner.recognition.decide(await record('tmdb', 'work'), {
        'id': 42,
        'type': 'tv',
      });
      await runner.recognition.decide(await record('tmdb', 'range'), {
        'season': 1,
        'first': 1,
        'last': 4,
        'offset': 0,
      });
      final upper =
          catalog.assets.singleWhere(
                (row) => row['name'] == 'Upper S01E01.mkv',
              )['id']
              as String;
      await runner.recognition.decide(
        await record('tmdb', 'episode', scope: upper),
        {'season': 1, 'episode': 1},
      );
      final base = await record('tmdb', 'range');
      final selected = (await runner.recognition.groupFiles(base))
          .where((file) => (file['name'] as String).startsWith('Lower'))
          .map((file) => file['id'] as String)
          .toSet();
      await runner.recognition.saveFileGroup(base, 'Lower half', selected);
      final group = (await catalog.db.query('scan_file_groups')).single;
      final scope = group['scope'] as String;
      await runner.recognition.decide(
        await record('tmdb', 'range', scope: scope),
        {'season': 1, 'first': 10, 'last': 13, 'offset': 9},
      );
      final range = await record('tmdb', 'range', scope: scope);
      await runner.run(
        await runner.recognition.enqueueRange(source, range['id'] as String),
      );
      final preview = await runner.recognition.previewNumbering(range);
      expect(preview.matches.map((item) => item.choice['episode']), [10, 12]);
      expect(preview.deferred, hasLength(3));
      final first = preview.matches.first;
      await runner.recognition.decide(
        await withToken(first.binding),
        first.choice,
      );
      await expectLater(
        runner.recognition.applyNumbering(range, preview),
        throwsStateError,
      );
      final fresh = await runner.recognition.previewNumbering(range);
      expect(fresh.matches.single.choice['episode'], 12);
      await runner.recognition.applyNumbering(range, fresh);
      expect(
        ScanRecognition.adopted(
          await record('tmdb', 'episode', scope: upper),
        )!['episode'],
        1,
      );

      final prefs = await SharedPreferences.getInstance();
      final artwork = Directory('${library.path}/artwork');
      final backup = await LibraryBackupExporter(
        database: catalog.db,
        artworkDirectory: artwork,
        preferences: prefs,
      ).export(File('${scratch.path}/group.zip'));
      final restorer = LibraryBackupRestorer(
        database: catalog.db,
        artworkDirectory: artwork,
      );
      final prepared = await restorer.prepare(backup);
      await runner.recognition.saveFileGroup(
        range,
        'Lower half',
        {},
        groupRevision: group['revision'] as int,
      );
      expect(await catalog.db.query('scan_file_groups'), isEmpty);
      await restorer.restore(prepared);
      await prepared.dispose();
      expect(
        (await catalog.db.query('scan_file_groups')).single['scope'],
        scope,
      );
      expect(
        (await catalog.db.query(
          'scan_file_group_members',
        )).map((row) => row['asset_id']).toSet(),
        selected,
      );
      expect(
        (await catalog.db.query(
          'scan_bindings',
          where: "reason='confirmed_numbering'",
        )).length,
        1,
      );
    },
  );

  test(
    'TV auto uses complete versioned mapping and respects chapter exclusions',
    () async {
      await catalog.db.close();
      await open(automatic: true);
      for (final name in ['Mapped', 'Excluded']) {
        final series = name == 'Mapped' ? 44 : 45;
        for (final n in [1, 3]) {
          await video('$name (2024) {tmdbtv-$series}/$name S01E0$n.mkv');
        }
      }
      final version = 'c' * 40;
      final store = catalog.mappingStore!;
      await store.registerVersion(version);
      for (final id in [31, 32]) {
        final job = 'tv-fixture:$id';
        await catalog.taskStore!.enqueue(job, intent: {}, steps: ['mapping']);
        final lease = (await catalog.taskStore!.claim(job, 'mapping'))!;
        final series = id + 13;
        await store.importDetail(version, {
          'schemaVersion': 1,
          'bangumiId': id,
          'targets': [
            {'type': 'tv', 'id': series, 'season': 1},
          ],
          'episodes': [
            for (var n = 1; n <= 3; n++)
              {'id': id * 100 + n, 'type': 0, 'sort': n},
          ],
          'rules': [
            {
              'bangumiType': 0,
              'start': 1,
              'end': 3,
              'tmdbId': series,
              'season': 1,
              'episodeStart': 1,
            },
          ],
          'overrides': [
            if (id == 32) {'bangumiEpisodeId': 3202, 'targets': []},
          ],
        }, lease);
      }
      useTransport((request) async {
        final path = request.url.path;
        if (path == '/v0/search/subjects') {
          final keyword = (jsonDecode(request.body) as Map)['keyword'];
          return reply({
            'data': [
              {
                'id': keyword == 'Mapped' ? 31 : 32,
                'type': 2,
                'name': keyword,
                'date': '2024-01-01',
              },
            ],
          });
        }
        if (path == '/v0/episodes') {
          final subject = int.parse(request.url.queryParameters['subject_id']!);
          return reply({
            'total': 3,
            'data': [
              for (var n = 1; n <= 3; n++)
                {
                  'id': subject * 100 + n,
                  'subject_id': subject,
                  'type': 0,
                  'sort': n,
                  'name': 'Other language $n',
                },
            ],
          });
        }
        final series = int.parse(request.url.pathSegments[2]);
        if (path.endsWith('/season/1')) {
          return reply({
            'season_number': 1,
            'episodes': [
              for (var n = 1; n <= 3; n++)
                {
                  'id': 500 + n,
                  'season_number': 1,
                  'episode_number': n,
                  'name': 'TMDB $n',
                },
            ],
          });
        }
        return reply({
          'id': series,
          'name': series == 44 ? 'Mapped' : 'Excluded',
          'first_air_date': '2024-01-01',
          'seasons': [
            {'season_number': 1, 'episode_count': 3, 'air_date': '2024-01-01'},
          ],
        });
      });
      await scan();
      final verified = await catalog.db.query(
        'scan_bindings',
        where: "layer='episode' AND reason='verified_tv_mapping'",
      );
      expect(verified, hasLength(4));
      expect(
        verified
            .where((row) => row['provider'] == 'tmdb')
            .map((row) => ScanRecognition.adopted(row)!['episode']),
        unorderedEquals([1, 3]),
      );
      final excluded = catalog.works.singleWhere(
        (row) => row['title'] == 'Excluded',
      )['id'];
      final independent = await catalog.db.query(
        'scan_bindings',
        where: "work_id=? AND layer='episode' AND state='confirmed'",
        whereArgs: [excluded],
      );
      expect(independent.map((row) => row['provider']), ['tmdb', 'tmdb']);
      expect(
        independent.map((row) => ScanRecognition.adopted(row)!['episode']),
        unorderedEquals([1, 3]),
      );
    },
  );

  test(
    'opening a schema 22 fixture preserves prior confirmations and IDs',
    () async {
      await video('Legacy Series/S01E01.mkv');
      await scan();
      await runner.recognition.decide(await record('tmdb', 'work'), {
        'id': 55,
        'type': 'tv',
      });
      await runner.recognition.decide(await record('tmdb', 'range'), {
        'season': 1,
        'first': 1,
        'last': 8,
        'offset': 0,
      });
      final asset = catalog.assets.single['id'] as String;
      await runner.recognition.decide(
        await record('tmdb', 'episode', scope: asset),
        {'season': 1, 'episode': 1},
      );
      final bindings = await catalog.db.query('scan_bindings', orderBy: 'id');
      // Remove the two new tables and their triggers to recreate the stage 4
      // schema 22 fixture, then exercise Catalog's real upgrade callback.
      await catalog.db.transaction((tx) async {
        final triggers = await tx.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='trigger' AND name LIKE 'scan_file_group_%'",
        );
        for (final row in triggers) {
          await tx.execute('DROP TRIGGER ${row['name']}');
        }
        await tx.execute('DROP TABLE scan_file_group_members');
        await tx.execute('DROP TABLE scan_file_groups');
        await tx.execute('PRAGMA user_version=22');
      });
      await catalog.db.close();
      await open();
      expect(
        (await catalog.db.rawQuery('PRAGMA user_version')).single.values.single,
        23,
      );
      expect(catalog.assets.single['id'], asset);
      expect(await catalog.db.query('scan_bindings', orderBy: 'id'), bindings);
      expect(await catalog.db.query('scan_file_groups'), isEmpty);
    },
  );

  testWidgets(
    'review queue fits narrow portrait, wide and short landscape at large text',
    (tester) async {
      await tester.runAsync(() async {
        await video('A long test work name with a long path/01.mkv');
        await scan();
      });
      for (final size in [
        const Size(320, 640),
        const Size(1050, 700),
        const Size(600, 320),
      ]) {
        await tester.binding.setSurfaceSize(size);
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(1.7)),
              child: child!,
            ),
            home: ScanReviewsPage(runner: runner, source: source),
          ),
        );
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
      expect(find.text('A long test work name with a long path'), findsWidgets);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.binding.setSurfaceSize(null);
    },
  );
}
