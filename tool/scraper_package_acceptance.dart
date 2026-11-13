// AOT entry point for the portable scraper test packages only.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:ccplayer/core/catalog.dart';
import 'package:ccplayer/core/app_language.dart';
import 'package:ccplayer/core/artwork_settings.dart';
import 'package:ccplayer/core/detail_metadata.dart';
import 'package:ccplayer/core/optional_features.dart';
import 'package:ccplayer/core/optional_people.dart';
import 'package:ccplayer/core/scoped_artwork.dart';
import 'package:ccplayer/core/selected_scan_workflow.dart';
import 'package:ccplayer/core/metadata.dart';
import 'package:ccplayer/core/metadata_http.dart';
import 'package:ccplayer/core/metadata_servers.dart';
import 'package:ccplayer/core/scan_recognition.dart';
import 'package:ccplayer/core/scrape_task_runner.dart';
import 'package:ccplayer/core/shared_metadata_requests.dart';
import 'package:ccplayer/main.dart' as app;
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

const _androidPackage = 'com.anime.konata.scrapervalidation';
const _marker = '.konata-scraper-validation';
const _report = 'scraper-acceptance.json';

void _event(String name, Object data) {
  final payload = jsonEncode(data);
  if (name == 'KONATA_PACKAGE_RESULT' && payload.length > 650) {
    final encoded = base64Encode(utf8.encode(payload));
    const size = 600;
    final count = (encoded.length + size - 1) ~/ size;
    for (var i = 0; i < count; i++) {
      // ignore: avoid_print
      print(
        'KONATA_PACKAGE_PART $i/$count ${encoded.substring(i * size, min((i + 1) * size, encoded.length))}',
      );
    }
    return;
  }
  // ignore: avoid_print
  print('$name $payload');
}

Future<Directory> _safeRoot() async {
  if (!const bool.fromEnvironment('KONATA_SCRAPER_PACKAGE')) {
    throw StateError('Validation build flag required');
  }
  if (Platform.isWindows) {
    final executable = File(Platform.resolvedExecutable);
    final base = p.dirname(await executable.resolveSymbolicLinks());
    final root = Directory(p.join(base, 'userdata'));
    if (!await root.exists() ||
        !p.equals(await root.resolveSymbolicLinks(), root.path) ||
        await File(p.join(root.path, _marker)).readAsString() !=
            'konata-scraper-validation-v1') {
      throw StateError('Portable isolation marker required');
    }
    return root;
  }
  if (Platform.isAndroid) {
    final root = await getApplicationSupportDirectory();
    if (p.split(root.path).contains(_androidPackage)) return root;
  }
  throw StateError('Isolated application package required');
}

Future<Map<String, dynamic>?> _configuration(
  Directory root,
  List<String> args,
) async {
  if (Platform.isWindows) {
    final file = File(p.join(root.path, 'scraper-probe.json'));
    if (!await file.exists()) return null;
    try {
      return jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    } finally {
      await file.delete();
    }
  }
  if (!args.contains('scraper-probe')) return null;
  final random = Random.secure();
  final nonce = base64UrlEncode(List.generate(24, (_) => random.nextInt(256)));
  _event('KONATA_PACKAGE_CHALLENGE', nonce);
  final http = HttpClient()
    ..findProxy = ((_) => 'DIRECT')
    ..connectionTimeout = const Duration(seconds: 2);
  final clock = Stopwatch()..start();
  try {
    while (clock.elapsed < const Duration(seconds: 35)) {
      try {
        final request = await http.getUrl(
          Uri.http('127.0.0.1:29813', '/probe'),
        );
        request.followRedirects = false;
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $nonce');
        final response = await request.close().timeout(
          const Duration(seconds: 2),
        );
        final body = await utf8.decodeStream(
          response.timeout(const Duration(seconds: 2)),
        );
        if (response.statusCode == 200) {
          return jsonDecode(body) as Map<String, dynamic>;
        }
      } on IOException {
        // The host starts the private handoff after reading our challenge.
      } on TimeoutException {
        // Retry within the short handoff deadline.
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    throw StateError('Private configuration handoff expired');
  } finally {
    http.close(force: true);
  }
}

class _ObservedClient extends IOClient {
  _ObservedClient(this.injectTimeout, this.attempts)
    : super(HttpClient()..findProxy = ((_) => 'DIRECT'));

  final bool injectTimeout;
  final List<Map<String, Object?>> attempts;

  @override
  Future<IOStreamedResponse> send(http.BaseRequest request) async {
    final host = request.url.host;
    final record = <String, Object?>{'host': host, 'path': request.url.path};
    attempts.add(record);
    if (injectTimeout && ['api.themoviedb.org', 'api.bgm.tv'].contains(host)) {
      record['injected_timeout'] = true;
      throw TimeoutException('Controlled official endpoint timeout');
    }
    try {
      final response = await super.send(request);
      record['http'] = response.statusCode;
      return response;
    } catch (error) {
      record['error'] = error.runtimeType.toString();
      rethrow;
    }
  }
}

Future<Map<String, Object?>> _scrape(
  Directory root, {
  required bool force,
}) async {
  final catalog = Catalog.instance;
  final tasks = catalog.taskStore!;
  await MetadataServers.load();
  MetadataServers.values = List.of(MetadataServers.defaults);
  MetadataServers.fallback = true;
  MetadataServers.trustCustomTmdb = false;
  final attempts = <Map<String, Object?>>[];
  final requests = SharedMetadataRequests(
    tasks,
    clientFactory: () => MetadataHttp(
      raw: true,
      fresh: true,
      inner: _ObservedClient(force, attempts),
    ),
  );
  final runner = ScrapeTaskRunner(catalog, requests: requests);
  final mode = force ? 'injected_timeout' : 'live_network';
  final adopted = <String, Object?>{};
  final elapsed = Stopwatch()..start();
  String? phase = 'scan';
  try {
    final path = await root.createTemp('$mode-');
    final folder = await Directory(
      p.join(path.path, '86 (2021) {tmdbtv-100565} {bangumi-302189}'),
    ).create();
    await File(p.join(folder.path, 'E01.mkv')).writeAsBytes([0]);
    final source = await catalog.addSource('local', mode, path.path);
    await catalog.addScanRoot(source, '');
    await runner.run(await runner.enqueueScan(source));
    phase = 'recognition';
    final asset = catalog.assets.singleWhere(
      (row) => row['source_id'] == source,
    );
    final work = asset['work_id'] as String;
    for (final (provider, id, path, official, backup) in [
      ('tmdb', 100565, '/3/tv/100565', 'api.themoviedb.org', 'api.tmdb.org'),
      (
        'bangumi',
        302189,
        '/v0/subjects/302189',
        'api.bgm.tv',
        'api.bangumi.lat',
      ),
    ]) {
      phase = provider;
      final binding = (await catalog.db.query(
        'scan_bindings',
        where: "work_id=? AND provider=? AND layer='work'",
        whereArgs: [work, provider],
      )).single;
      final candidate = ScanRecognition.candidates(
        binding,
      ).singleWhere((row) => row['id'] == id);
      final matches = attempts.where((row) => row['path'] == path).toList();
      if (matches.isEmpty ||
          matches.first['host'] != official ||
          !matches.any(
            (row) => row['http'] == 200 && (!force || row['host'] == backup),
          )) {
        throw StateError(
          'Provider request order or response was not confirmed',
        );
      }
      await runner.recognition.decide({
        ...binding,
        'session': (await catalog.db.query('scrape_runtime')).single['session'],
        'identity_revision': (await catalog.db.query(
          'library_work_protection',
          where: 'work_id=?',
          whereArgs: [work],
        )).single['revision'],
      }, candidate);
      final saved = (await catalog.db.query(
        'scan_bindings',
        where: 'id=?',
        whereArgs: [binding['id']],
      )).single;
      if (saved['state'] != 'confirmed' ||
          ScanRecognition.adopted(saved)?['id'] != id) {
        throw StateError('Confirmed identity was not persisted');
      }
      adopted[provider] = id;
    }
    phase = null;
  } catch (_) {
    // No response bodies, credential headers or exception messages in evidence.
  } finally {
    requests.close();
  }
  return {
    'mode': mode,
    'ok': phase == null,
    if (phase != null) 'failed_at': phase,
    'adopted': adopted,
    'attempts': attempts,
    'ms': elapsed.elapsedMilliseconds,
  };
}

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  Directory? root;
  try {
    root = await _safeRoot();
    final config = await _configuration(root, args);
    if (config?['scenario'] == 'cd2_comparison') {
      final result = await _compareCd2(root, config!);
      await File(
        p.join(root.path, _report),
      ).writeAsString(jsonEncode(result), flush: true);
      _event('KONATA_PACKAGE_RESULT', result);
      return;
    }
    final database = Directory(
      p.join(
        root.path,
        const bool.fromEnvironment('KONATA_AUTO_SCRAPER_VALIDATION')
            ? 'scraper-library-auto'
            : 'scraper-library',
      ),
    );
    // The test package keeps credentials out of the platform's real vault.
    // ignore: invalid_use_of_visible_for_testing_member
    FlutterSecureStorage.setMockInitialValues({});
    await app.launchKonata(
      scraperValidationDirectory: database,
      experimentalScraping: config != null,
    );
    if (config == null) return;
    await WidgetsBinding.instance.endOfFrame;
    final mode = config['mode'];
    final value = config['value'];
    if (!['apiKey', 'token'].contains(mode) ||
        value is! String ||
        value.trim().isEmpty) {
      throw StateError('TMDB test credential required');
    }
    Metadata.authMode = mode as String;
    if (mode == 'token') {
      Metadata.token = value;
    } else {
      Metadata.apiKey = value;
    }
    try {
      final run = await root.createTemp('probe-');
      final cases = [
        await _scrape(run, force: false),
        if (config['force_fallback'] == true) await _scrape(run, force: true),
      ];
      final result = {
        'ok': cases.every((row) => row['ok'] == true),
        'platform': Platform.operatingSystem,
        'schema': (await Catalog.instance.db.rawQuery(
          'PRAGMA user_version',
        )).single['user_version'],
        'cases': cases,
      };
      await File(
        p.join(root.path, _report),
      ).writeAsString(jsonEncode(result), flush: true);
      _event('KONATA_PACKAGE_RESULT', result);
    } finally {
      Metadata.token = '';
      Metadata.apiKey = '';
    }
  } catch (error) {
    final result = {
      'ok': false,
      'phase': 'isolated_startup',
      'error': error.runtimeType.toString(),
    };
    if (root != null) {
      await File(
        p.join(root.path, _report),
      ).writeAsString(jsonEncode(result), flush: true);
    }
    _event('KONATA_PACKAGE_RESULT', result);
    runApp(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: Text('Konata Scraper Test isolation check failed.'),
          ),
        ),
      ),
    );
  }
}

void _loadProbeCredentials(Map<String, dynamic> config) {
  final mode = config['mode'];
  final value = config['value'];
  if (!['apiKey', 'token'].contains(mode) ||
      value is! String ||
      value.trim().isEmpty) {
    throw StateError('TMDB test credential required');
  }
  Metadata.authMode = mode as String;
  Metadata.token = mode == 'token' ? value : '';
  Metadata.apiKey = mode == 'apiKey' ? value : '';
}

Future<Map<String, Object?>> _compareCd2(
  Directory root,
  Map<String, dynamic> config,
) async {
  final catalog = Catalog.instance;
  final run = await root.createTemp('cd2-comparison-');
  final url = Platform.isWindows
      ? 'http://127.0.0.1:29798/dav'
      : 'http://127.0.0.1:29801/dav';
  const folder86 = '动画-单作品/86 -不存在的战区- (2021) {tmdb-100565}';
  const folderSeries = '动画-多作品/为美好的世界献上祝福！系列';
  const expectedSpecials = {2, 3, 4, 5};

  Future<String> selectSamples() async {
    final source = await catalog.addSource(
      'webdav',
      'CD2 comparison',
      url,
      username: 'anonymous',
    );
    await catalog.addScanRoot(source, folder86);
    await catalog.addScanRoot(source, folderSeries);
    return source;
  }

  await MetadataServers.load();
  await MetadataHttp.initialize();
  await AppLanguage.instance.load();
  _loadProbeCredentials(config);
  await catalog.initialize(
    dataDirectory: Directory(p.join(run.path, 'legacy')),
  );
  final oldSource = await selectSamples();
  final oldClock = Stopwatch()..start();
  await SelectedScanWorkflow.run(catalog.sources.single);
  oldClock.stop();
  final oldWorks = catalog.works
      .map(
        (work) => {
          'title': work['title'],
          'tmdb': work['tmdb_id'],
          'bangumi': work['bangumi_id'],
          'season': catalog
              .forWork(work['id'] as String)
              .where((file) => file['category'] == 'main')
              .map((file) => file['season'])
              .toSet()
              .toList(),
          'poster': Catalog.preferredPoster(work) != null,
        },
      )
      .toList();
  final oldAssets = catalog.assets
      .where((file) => file['source_id'] == oldSource)
      .length;
  final old86 = catalog.works
      .where(
        (work) =>
            work['tmdb_id'] == 100565 || '${work['title']}'.startsWith('86'),
      )
      .firstOrNull;
  var oldSpecials = 0;
  if (old86 != null) {
    final service = DetailMetadataService();
    try {
      final details = await service.fetch(
        old86,
        assets: catalog.forWork(old86['id'] as String),
      );
      oldSpecials = (details['specialAssets'] as Map? ?? {}).length;
    } finally {
      service.close();
    }
  }
  await catalog.db.close();

  // Keep the test account's credential in this process, outside the real vault.
  // ignore: invalid_use_of_visible_for_testing_member
  FlutterSecureStorage.setMockInitialValues({
    'tmdb_auth_mode': config['mode'] as String,
    if (config['mode'] == 'token')
      'tmdb_token': config['value'] as String
    else
      'tmdb_api_key': config['value'] as String,
  });
  await app.launchKonata(
    scraperValidationDirectory: Directory(p.join(run.path, 'revised')),
    experimentalScraping: true,
  );
  await WidgetsBinding.instance.endOfFrame;
  final source = await selectSamples();
  final runner = ScrapeTaskRunner.forCatalog(catalog);
  final clock = Stopwatch()..start();
  await SelectedScanWorkflow.run(catalog.sources.single);
  while (clock.elapsed < const Duration(seconds: 160)) {
    final active = (await catalog.db.rawQuery(
      "SELECT COUNT(*) AS n FROM scrape_tasks WHERE source_id=? AND state IN ('queued','running')",
      [source],
    )).single['n'];
    if (active == 0) break;
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
  clock.stop();
  final report = <Map<String, Object?>>[];
  final counts = <String, int>{};
  var specialOk = false;
  var verified86 = false;
  final identities = <Object?>[];
  final seasons = <int>{};
  final verifiedSeriesArtwork = <int>{};
  const expectedOvas = {
    1: {1},
    2: {2},
    3: {3, 4},
  };
  for (final task in await catalog.db.query(
    'scrape_tasks',
    columns: ['state'],
  )) {
    counts.update(task['state'] as String, (n) => n + 1, ifAbsent: () => 1);
  }
  for (final work in catalog.works) {
    final id = work['id'] as String;
    final rows = await catalog.db.query(
      'scan_bindings',
      where: "work_id=? AND state='confirmed'",
      whereArgs: [id],
    );
    final tmdb = rows.where((row) => row['provider'] == 'tmdb').toList();
    final series = tmdb
        .where((row) => row['layer'] == 'work')
        .map(ScanRecognition.adopted)
        .firstOrNull?['id'];
    identities.add(series);
    final range = tmdb
        .where((row) => row['layer'] == 'range')
        .map(ScanRecognition.adopted)
        .map((row) => row?['season'])
        .toSet();
    final episodes = tmdb
        .where((row) => row['layer'] == 'episode')
        .map(ScanRecognition.adopted)
        .whereType<Map>()
        .toList();
    final specials = episodes
        .where((row) => row['season'] == 0)
        .map((row) => row['episode'])
        .whereType<int>()
        .toSet();
    if (series == 65844)
      seasons.addAll(range.whereType<int>().where((n) => n > 0));
    if (series == 100565) specialOk = specials.containsAll(expectedSpecials);
    final details = await ScanRecognition.details(catalog, work);
    String? backdrop;
    var peopleCount = 0;
    if ((series == 100565 || series == 65844) &&
        ArtworkSettings.instance.backdrop) {
      final job = await runner.artwork.enqueue(id, ScopedImage.backdrop);
      if (job != null) await runner.run(job);
      backdrop = await runner.artwork.displayed(id, ScopedImage.backdrop);
    }
    if (series == 65844) {
      final season = range.whereType<int>().where((n) => n > 0).singleOrNull;
      final expected = expectedOvas[season];
      final withStills = episodes
          .where((row) => row['season'] == 0 && row['still'] != null)
          .map((row) => row['episode'])
          .toSet();
      if (season != null &&
          expected != null &&
          backdrop != null &&
          specials.length == expected.length &&
          specials.containsAll(expected) &&
          withStills.containsAll(expected)) {
        verifiedSeriesArtwork.add(season);
      }
    }
    if (series == 100565) {
      final people = details?['recognized_people'] as Map?;
      final settings = OptionalFeatures.instance;
      if (people?['bangumi_ids'] != null &&
          settings.peopleSource(animation: true) ==
              OptionalFeature.characters) {
        final session = OptionalPeopleSession(
          settings,
          OptionalFeature.characters,
        );
        try {
          peopleCount =
              (await session
                      .load({
                        ...work,
                        ...people!,
                      }, AppLanguage.instance.metadataLanguage)
                      .timeout(const Duration(seconds: 35)))
                  .length;
        } catch (_) {
          // Acceptance records the missing result without private network data.
        } finally {
          session.dispose();
        }
      }
      verified86 =
          episodes.where((row) => row['season'] == 1).length == 23 &&
          peopleCount > 0 &&
          backdrop != null &&
          Catalog.preferredPoster(work) != null &&
          details?['overview']?.toString().isNotEmpty == true;
    }
    report.add({
      'title': work['title'],
      'tmdb': series,
      'seasons': range.toList(),
      'main_matches': episodes.where((row) => row['season'] != 0).length,
      'special_matches': specials.toList(),
      'default_stills': episodes.where((row) => row['still'] != null).length,
      'bangumi_roles': (details?['recognized_people'] as Map?)?['bangumi_ids'],
      'overview': details?['overview']?.toString().isNotEmpty == true,
      'poster': Catalog.preferredPoster(work) != null,
      if (series == 100565 || series == 65844) 'backdrop': backdrop != null,
      if (series == 100565) 'people_count': peopleCount,
    });
  }
  final newAssets = catalog.assets
      .where((file) => file['source_id'] == source)
      .length;
  return {
    'ok':
        oldAssets == 233 &&
        newAssets == oldAssets &&
        report.length == 6 &&
        identities.toSet().containsAll({100565, 65844, 532067, 203040}) &&
        identities.where((id) => id == 65844).length == 3 &&
        verified86 &&
        seasons.containsAll({1, 2, 3}) &&
        verifiedSeriesArtwork.containsAll({1, 2, 3}) &&
        specialOk &&
        (counts['queued'] ?? 0) == 0 &&
        (counts['running'] ?? 0) == 0,
    'platform': Platform.operatingSystem,
    'legacy': {
      'assets': oldAssets,
      'scan_ms': oldClock.elapsedMilliseconds,
      'special_matches_86': oldSpecials,
      'works': oldWorks,
    },
    'revised': {
      'assets': newAssets,
      'scan_and_queue_ms': clock.elapsedMilliseconds,
      'lifecycle': WidgetsBinding.instance.lifecycleState?.name,
      'tasks': counts,
      'works': report,
    },
  };
}
