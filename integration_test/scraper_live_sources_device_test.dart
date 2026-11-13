import 'dart:convert';
import 'dart:io';

import 'package:ccplayer/core/catalog.dart';
import 'package:ccplayer/core/image_store.dart';
import 'package:ccplayer/core/metadata.dart';
import 'package:ccplayer/core/metadata_http.dart';
import 'package:ccplayer/core/metadata_servers.dart';
import 'package:ccplayer/core/mpv_config_store.dart';
import 'package:ccplayer/core/scrape_task_runner.dart';
import 'package:ccplayer/core/selected_scanner.dart';
import 'package:ccplayer/core/sources.dart';
import 'package:ccplayer/core/tmdb_auth.dart';
import 'package:ccplayer/l10n/app_localizations.dart';
import 'package:ccplayer/ui/watch_page.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void _mark(Map<String, Object?> event) =>
    debugPrint('KONATA_LIVE_SOURCE ${jsonEncode(event)}');

Future<Map<String, Object?>> _handoff(Directory root) async {
  final config = File('${root.path}/scrape-live-qa.json');
  debugPrint('KONATA_LIVE_CONFIG_READY ${config.path}');
  final elapsed = Stopwatch()..start();
  while (!await config.exists()) {
    if (elapsed.elapsed > const Duration(seconds: 45)) {
      throw StateError('Private runtime test configuration not received');
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  try {
    return Map<String, Object?>.from(
      jsonDecode(await config.readAsString()) as Map,
    );
  } finally {
    await config.delete();
  }
}

Future<void> _source(
  WidgetTester tester,
  Catalog catalog,
  ScrapeTaskRunner runner,
  MpvConfigStore mpv,
  Map row,
) async {
  final kind = row['kind'] as String;
  var phase = 'preflight';
  final clock = Stopwatch()..start();
  try {
    final source = await catalog.addSource(
      kind,
      'Isolated read-only test',
      row['location'] as String,
      username: row['username'] as String? ?? '',
      password: row['password'] as String? ?? '',
    );
    final sourceRow = catalog.sourceOf(source);
    final adapter = WebDav(await catalog.withCredentials(sourceRow));
    final listing = await adapter.list(
      adapter.directoryUri(''),
      requireComplete: true,
    );
    _mark({
      'kind': kind,
      'phase': phase,
      'entries': listing.length,
      'subfolders': listing.where((entry) => entry.isDirectory).length,
    });
    final relative = row['relative'] as String;
    expect(listing.any((e) => e.name == relative), isTrue);
    final pending = [(path: '', depth: 0, entries: listing)];
    var entries = 0, videos = 0;
    for (var i = 0; i < pending.length; i++) {
      final current = pending[i];
      entries += current.entries.length;
      if (entries > 600) {
        throw StateError('Directory sample exceeds entry limit');
      }
      for (final entry in current.entries) {
        final path = current.path.isEmpty
            ? entry.name
            : '${current.path}/${entry.name}';
        if (SelectedScanner.excluded(path, '')) continue;
        if (!entry.isDirectory) {
          if (Catalog.isVideo(entry.name) && ++videos > 128) {
            throw StateError('Directory sample exceeds video limit');
          }
          continue;
        }
        if (pending.length >= 16 || current.depth >= 3) {
          throw StateError('Directory sample exceeds traversal limit');
        }
        pending.add((
          path: path,
          depth: current.depth + 1,
          entries: await adapter.list(
            adapter.directoryUri(path),
            requireComplete: true,
          ),
        ));
      }
    }
    _mark({
      'kind': kind,
      'phase': 'scope',
      'entries': entries,
      'videos': videos,
      'directories': pending.length,
    });
    phase = 'scan';
    await catalog.addScanRoot(source, '');
    final scan = await runner.enqueueScan(source);
    await runner.run(scan);
    Future<bool> completed() async =>
        (await catalog.db.query(
          'scrape_tasks',
          where: 'id=?',
          whereArgs: [scan],
        )).single['state'] ==
        'complete';
    expect(await completed(), isTrue);
    final assets = catalog.assets.where(
      (asset) => asset['source_id'] == source,
    );
    final asset = assets.singleWhere(
      (asset) => asset['relative_path'] == relative,
    );
    expect(asset['size'], row['bytes']);

    phase = 'range';
    final ticket = await StreamBroker.instance.issue(sourceRow, relative);
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 12);
    try {
      final start = row['offset'] as int;
      final request = await client.getUrl(ticket);
      request.headers.set(
        HttpHeaders.rangeHeader,
        'bytes=$start-${start + 255}',
      );
      final response = await request.close().timeout(
        const Duration(seconds: 15),
      );
      expect(response.statusCode, 206);
      final payload = await response
          .timeout(const Duration(seconds: 12))
          .expand((data) => data)
          .take(257)
          .toList();
      expect(payload.length, 256);
      expect(sha256.convert(payload).toString() == row['range_sha256'], isTrue);
    } finally {
      client.close(force: true);
      StreamBroker.instance.revoke(ticket);
    }

    phase = 'playback';
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: WatchPage(asset: asset, configurationStore: mpv),
      ),
    );
    final dynamic page = tester.state(find.byType(WatchPage));
    final player = page.player as Player;
    await player.setVolume(0);
    Future<int> wait(Duration position) async {
      final elapsed = Stopwatch()..start();
      while (player.state.position < position || player.state.buffering) {
        expect(elapsed.elapsed, lessThan(const Duration(seconds: 30)));
        await tester.pump(const Duration(milliseconds: 100));
        await Future<void>.delayed(const Duration(milliseconds: 80));
      }
      return elapsed.elapsedMilliseconds;
    }

    int started, seek;
    try {
      started = await wait(const Duration(milliseconds: 500));
      final target = Duration(
        seconds: player.state.duration.inSeconds >= 40 ? 20 : 5,
      );
      await player.seek(target).timeout(const Duration(seconds: 15));
      seek = await wait(target + const Duration(milliseconds: 500));
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await player.stream.position.drain<void>().timeout(
        const Duration(seconds: 15),
      );
    }
    phase = 'rescan';
    await runner.run(await runner.enqueueScan(source));
    expect(await completed(), isTrue);
    expect(
      catalog.assets.singleWhere(
        (candidate) =>
            candidate['source_id'] == source &&
            candidate['relative_path'] == relative,
      )['id'],
      asset['id'],
    );
    _mark({
      'kind': kind,
      'ok': true,
      'indexed': assets.length,
      'range_bytes': 256,
      'start_ms': started,
      'seek_ms': seek,
      'elapsed_ms': clock.elapsedMilliseconds,
      'same_file_id': true,
    });
  } catch (error) {
    _mark({
      'kind': kind,
      'phase': phase,
      'ok': false,
      'error': error.runtimeType.toString(),
    });
    throw StateError('Isolated $kind validation failed at $phase');
  }
}

Future<void> _tmdb(Map config, bool useAlternate) async {
  final auth = TmdbCredentials(
    mode: config['mode'] as String,
    value: config['value'] as String,
  );
  final endpoints = useAlternate
      ? MetadataServers.defaults
      : MetadataServers.official;
  MetadataServers.values = List.of(endpoints);
  MetadataServers.fallback = useAlternate;
  Metadata.authMode = auth.mode;
  if (auth.mode == 'token') {
    Metadata.token = auth.value;
  } else {
    Metadata.apiKey = auth.value;
  }
  var phase = 'authentication';
  final client = MetadataHttp(fresh: true);
  try {
    await Metadata.testTmdbCredentials(
      auth,
    ).timeout(const Duration(seconds: 30));
    phase = 'episode';
    final season = await Metadata.tvDetails(
      100565,
      season: 1,
    ).timeout(const Duration(seconds: 30));
    final episode = (season['episodes'] as List).cast<Map>().singleWhere(
      (entry) => entry['episode_number'] == 1,
    );
    phase = 'episode_images';
    final response = await client
        .get(
          auth.uri('/tv/100565/season/1/episode/1/images', {
            'include_image_language': 'zh,ja,en,null',
          }),
          headers: auth.headers,
        )
        .timeout(const Duration(seconds: 30));
    _mark({'kind': 'tmdb', 'phase': phase, 'http': response.statusCode});
    expect(response.statusCode, 200);
    final images = jsonDecode(response.body) as Map;
    expect(images['id'], episode['id']);
    final stills = (images['stills'] as List).cast<Map>();
    expect(stills, isNotEmpty);
    phase = 'image_bytes';
    final path = stills.first['file_path'] as String;
    final bytes = await ImageStore.load(
      MetadataServers.tmdbImage(path),
    ).timeout(const Duration(seconds: 30));
    final dimensions = await ImageStore.dimensions(bytes);
    expect(dimensions.width, greaterThan(0));
    _mark({
      'kind': 'tmdb',
      'ok': true,
      'api_host': Uri.parse(endpoints[0]).host,
      'image_host': Uri.parse(endpoints[1]).host,
      'episode_images': stills.length,
      'image_width': dimensions.width,
      'image_height': dimensions.height,
    });
  } catch (error) {
    final code = RegExp(r'TMDB HTTP (\d+)').firstMatch(error.toString())?[1];
    _mark({
      'kind': 'tmdb',
      'phase': phase,
      'ok': false,
      'error': error.runtimeType.toString(),
      if (code != null) 'http': int.parse(code),
    });
    throw StateError('Isolated TMDB validation failed at $phase');
  } finally {
    client.close();
    Metadata.token = '';
    Metadata.apiKey = '';
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('isolated live scraper sources', (tester) async {
    final temp = await getTemporaryDirectory();
    if (Platform.isAndroid &&
        !temp.path.contains('com.anime.konata.validation')) {
      throw StateError('Use the isolated .validation application');
    }
    final root = await Directory.systemTemp.createTemp('konata-scrape-live-');
    final catalog = Catalog.instance;
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    var opened = false;
    final failures = <String>[];
    try {
      final config = await _handoff(
        Platform.isAndroid ? await getApplicationSupportDirectory() : root,
      );
      await catalog.initialize(
        dataDirectory: root,
        enableFoundation: true,
        enableTasks: true,
        enableMappings: true,
        enableRecognition: true,
        enableScopedArtwork: true,
        enableChapterRelations: true,
        enableLibraryMerge: true,
      );
      opened = true;
      final runner = ScrapeTaskRunner.forCatalog(catalog);
      final mpv = MpvConfigStore(rootOverride: Directory('${root.path}/mpv'));
      await mpv.initialize();
      MediaKit.ensureInitialized();
      final sources = (config['sources'] as List).cast<Map>();
      expect(sources.isNotEmpty || config['tmdb'] != null, isTrue);
      for (final source in sources) {
        try {
          await _source(tester, catalog, runner, mpv, source);
        } on StateError {
          failures.add(source['kind'] as String);
        }
      }
      if (config['tmdb'] case final Map tmdb) {
        try {
          await _tmdb(tmdb, config['prefer_alternate'] == true);
        } on StateError {
          failures.add('tmdb');
        }
      }
      expect(failures, isEmpty);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      if (opened) {
        catalog.taskStore?.dispose();
        catalog.taskStore = null;
        await catalog.db.close();
        await ImageStore.close();
        ImageStore.root = null;
      }
      await root.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 6)));
}
