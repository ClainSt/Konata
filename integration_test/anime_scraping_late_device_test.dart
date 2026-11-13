import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ccplayer/core/catalog.dart';
import 'package:ccplayer/core/image_store.dart';
import 'package:ccplayer/core/library_backup_restorer.dart';
import 'package:ccplayer/core/metadata.dart';
import 'package:ccplayer/core/mpv_config_store.dart';
import 'package:ccplayer/core/player_fullscreen.dart';
import 'package:ccplayer/core/scrape_task_runner.dart';
import 'package:ccplayer/core/watched_timeline.dart';
import 'package:ccplayer/l10n/app_localizations.dart';
import 'package:ccplayer/ui/watch_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';
import 'package:window_manager/window_manager.dart';

import '../test/anime_scraping_late_flow.dart';

const _fullEpisode = bool.fromEnvironment('KONATA_FULL_EPISODE');

Uint8List _video() {
  const width = 64, height = 48;
  final data = BytesBuilder(copy: false)
    ..add(ascii.encode('YUV4MPEG2 W64 H48 F12:1 Ip A1:1 C420jpeg\n'));
  for (var i = 0; i < 48; i++) {
    data.add(ascii.encode('FRAME\n'));
    data.add(
      Uint8List(width * height)..fillRange(0, width * height, 25 + i * 3),
    );
    data.add(
      Uint8List(width * height ~/ 2)..fillRange(0, width * height ~/ 2, 128),
    );
  }
  return data.takeBytes();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'isolated artwork, chapter spans, backup merge and native playback',
    (tester) async {
      final temp = await getTemporaryDirectory();
      if (Platform.isAndroid &&
          !temp.path.contains('com.anime.konata.validation')) {
        throw StateError('Use the isolated .validation application');
      }
      final root = await temp.createTemp('konata-scrape-device-');
      final catalog = Catalog.instance;
      var opened = false;
      try {
        await exerciseScrapeLibrary(root, videoBytes: _video());
        const foreign = String.fromEnvironment('KONATA_FOREIGN_BACKUP');
        if (foreign.isNotEmpty) await _verifyForeign(root, foreign);
        if (const bool.fromEnvironment('KONATA_LIVE_BANGUMI')) {
          await _probeBangumi();
        }
        await catalog.initialize(
          dataDirectory: Directory('${root.path}/library-b'),
          enableFoundation: true,
          enableTasks: true,
          enableMappings: true,
          enableRecognition: true,
          enableScopedArtwork: true,
          enableChapterRelations: true,
          enableLibraryMerge: true,
        );
        opened = true;
        final asset = catalog.assets.singleWhere(
          (row) => row['name'] == 'E01.mkv',
        );
        final source = asset['source_id'] as String;
        await catalog.addScanRoot(source, '');
        final runner = ScrapeTaskRunner.forCatalog(catalog);
        final scan = await runner.enqueueScan(source);
        final config = MpvConfigStore(
          rootOverride: Directory('${root.path}/mpv'),
        );
        await config.initialize();
        MediaKit.ensureInitialized();
        bool? finished;
        await tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () async {
                    finished = await Navigator.of(context).push<bool>(
                      MaterialPageRoute(
                        builder: (_) => WatchPage(
                          asset: asset,
                          configurationStore: config,
                          chapterStartMs: 0,
                          chapterEndMs: 2100,
                        ),
                      ),
                    );
                  },
                  child: const Text('Open confirmed interval'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open confirmed interval'));
        final clock = Stopwatch()..start();
        while (playingHeader.value == null &&
            clock.elapsed < const Duration(seconds: 20)) {
          await tester.pump(const Duration(milliseconds: 30));
          await Future<void>.delayed(const Duration(milliseconds: 25));
        }
        expect(playingHeader.value, isNotNull);
        await runner.run(scan);
        final parked = (await catalog.db.query(
          'scrape_tasks',
          where: 'id=?',
          whereArgs: [scan],
        )).single;
        expect(parked['state'], 'queued');
        final scanStep = (await catalog.db.query(
          'scrape_steps',
          where: "task_id=? AND step='enumerate'",
          whereArgs: [scan],
        )).single;
        expect(scanStep['state'], 'queued');
        expect(
          (await catalog.db.query(
            'scan_directory_checkpoints',
            where: 'complete=1',
          )),
          isEmpty,
        );
        while (finished == null &&
            clock.elapsed < const Duration(seconds: 30)) {
          await tester.pump(const Duration(milliseconds: 30));
          await Future<void>.delayed(const Duration(milliseconds: 25));
        }
        expect(finished, isTrue);
        await tester.pumpAndSettle();
        await runner.run(scan);
        expect(
          (await catalog.db.query(
            'scrape_tasks',
            where: 'id=?',
            whereArgs: [scan],
          )).single['state'],
          'complete',
        );
        final row = (await catalog.db.query(
          'progress',
          where: 'asset_id=?',
          whereArgs: [asset['id']],
        )).single;
        expect(row['position_ms'], inInclusiveRange(2000, 3000));
        expect(row['duration_ms'], 4000);
        debugPrint(
          'KONATA_SCRAPE_DEVICE ${jsonEncode({
            'platform': Platform.operatingSystem,
            'schema': (await catalog.db.rawQuery('PRAGMA user_version')).single['user_version'],
            'checks': ['scoped_artwork_degraded_then_stable', 'manual_episode_still', 'chapter_coverage', 'associated_merge', 'explicit_resume_choice', 'selective_merge_undo', 'native_interval_stop', 'scan_parks_during_playback'],
            'position_ms': row['position_ms'],
            'duration_ms': row['duration_ms'],
          })}',
        );
        if (_fullEpisode) {
          await _verifyFullEpisode(tester, catalog, runner, config);
        } else if (const bool.fromEnvironment('KONATA_LONG_DAV')) {
          await _verifyLongDav(tester, catalog, runner, config);
        }
        if (const bool.fromEnvironment('KONATA_EXPORT_FIXTURE')) {
          final archive = base64Encode(
            await File('${root.path}/library.zip').readAsBytes(),
          );
          const width = 1400;
          for (var offset = 0; offset < archive.length; offset += width) {
            debugPrint(
              'KONATA_FIXTURE_EXPORT ${offset ~/ width} ${archive.substring(offset, (offset + width).clamp(0, archive.length))}',
            );
          }
        }
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        if (opened) {
          catalog.taskStore?.dispose();
          catalog.taskStore = null;
          await catalog.db.close();
          await ImageStore.close();
        }
        ImageStore.root = null;
        await root.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: _fullEpisode ? 35 : 5)),
  );
}

Future<void> _verifyFullEpisode(
  WidgetTester tester,
  Catalog catalog,
  ScrapeTaskRunner runner,
  MpvConfigStore config,
) async {
  Metadata.token = '';
  Metadata.apiKey = '';
  final source = await catalog.addSource(
    'webdav',
    'Read-only validation WebDAV',
    'http://127.0.0.1:18781/fixture/',
  );
  await catalog.addScanRoot(source, '');
  final scan = await runner.enqueueScan(source);
  await runner.run(scan);
  final asset = catalog.assets.singleWhere((row) => row['source_id'] == source);
  expect(asset['size'], 1284006743);
  final id = asset['id'];
  final rescan = await runner.enqueueScan(source);
  Future<String?> scanState() async =>
      (await catalog.db.query(
            'scrape_tasks',
            where: 'id=?',
            whereArgs: [rescan],
          )).single['state']
          as String?;

  final clock = Stopwatch()..start();
  bool? returned;
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async {
              returned = await Navigator.of(context).push<bool>(
                MaterialPageRoute(
                  builder: (_) => WatchPage(
                    asset: asset,
                    configurationStore: config,
                    returnOnCompletion: true,
                  ),
                ),
              );
            },
            child: const Text('Play full episode'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Play full episode'));
  await tester.pump(const Duration(milliseconds: 300));
  final dynamic page = tester.state(find.byType(WatchPage));
  final player = page.player as Player;
  await player.setVolume(0);
  final native = player.platform as NativePlayer;
  var maxPosition = 0, duration = 0, stalls = 0, stallMs = 0;
  var naturalEnd = false, checkedStart = false, checkedMiddle = false;
  int? stalledAt, startupMs;
  final subscriptions = [
    player.stream.completed.listen((completed) {
      if (completed) naturalEnd = true;
    }),
    player.stream.position.listen((position) {
      if (position.inMilliseconds > maxPosition) {
        maxPosition = position.inMilliseconds;
      }
    }),
    player.stream.buffering.distinct().listen((buffering) {
      if (buffering) {
        stalls++;
        stalledAt = clock.elapsedMilliseconds;
      } else if (stalledAt case final started?) {
        stallMs += clock.elapsedMilliseconds - started;
        stalledAt = null;
      }
    }),
  ];
  void mark(Map<String, Object?> fields) => debugPrint(
    'KONATA_FULL_EPISODE ${jsonEncode({'platform': Platform.operatingSystem, 'elapsed_ms': clock.elapsedMilliseconds, 'position_ms': maxPosition, ...fields})}',
  );

  var sampleAt = 0;
  final renderer = <Map<String, Object?>>[];
  try {
    while (returned == null) {
      if (clock.elapsed > const Duration(minutes: 31)) {
        fail('Full playback timeout at $maxPosition ms');
      }
      await tester.pump(const Duration(milliseconds: 100));
      if (returned != null) break;
      final length = player.state.duration.inMilliseconds;
      if (length > 0) duration = length;
      if (!checkedStart && playingHeader.value != null) {
        await runner.run(rescan);
        expect(await scanState(), 'queued');
        checkedStart = true;
      }
      if (maxPosition > 350 && startupMs == null) {
        startupMs = clock.elapsedMilliseconds;
        expect(player.state.rate, 1.0);
        expect(duration, greaterThan(20 * 60 * 1000));
        expect(maxPosition, lessThan(3000));
      }
      if (startupMs == null && clock.elapsed > const Duration(seconds: 60)) {
        fail('Full episode did not start');
      }
      if (!checkedMiddle && duration > 0 && maxPosition > duration ~/ 2) {
        await runner.run(rescan);
        expect(await scanState(), 'queued');
        checkedMiddle = true;
      }
      if (startupMs != null &&
          maxPosition >= sampleAt &&
          duration - maxPosition > 2000) {
        final surface = Map<String, Object?>.from(
          await (page.capturePresentedBuffer() as Future).timeout(
                const Duration(seconds: 12),
              )
              as Map,
        );
        final sample = {
          'phase': 'sample',
          'buffer_count': stalls,
          'buffer_ms': stallMs,
          'duration_ms': duration,
          'decoder_drops': await native.getProperty('decoder-frame-drop-count'),
          'output_drops': await native.getProperty('frame-drop-count'),
          'rss_bytes': ProcessInfo.currentRss,
          'surface': surface,
        };
        renderer.add(sample);
        mark(sample);
        sampleAt = maxPosition >= duration - 15000
            ? duration
            : (maxPosition + 180000).clamp(0, duration - 15000);
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(returned, isTrue);
    expect(naturalEnd, isTrue);
    expect(duration - maxPosition, inInclusiveRange(0, 1500));
    expect(checkedStart && checkedMiddle, isTrue);
    expect(
      renderer.where((sample) => (sample['surface'] as Map).isNotEmpty).length,
      greaterThanOrEqualTo(2),
    );
    await tester.pumpAndSettle();
    final progress = (await catalog.db.query(
      'progress',
      where: 'asset_id=?',
      whereArgs: [id],
    )).single;
    final coverage = WatchedTimeline.decode(
      progress['watched_ranges'],
    ).coveredMilliseconds(duration);
    expect(progress['completed'], 1);
    expect(coverage / duration, greaterThanOrEqualTo(.90));
    expect(progress['position_ms'], greaterThanOrEqualTo(duration - 1500));
    final playback = {
      'natural_eof': naturalEnd,
      'duration_ms': duration,
      'startup_ms': startupMs,
      'buffer_count': stalls,
      'buffer_ms': stallMs,
      'saved_position_ms': progress['position_ms'],
      'coverage_ms': coverage,
      'completed': progress['completed'],
    };
    mark({'phase': 'playback_complete', ...playback});
    final recovery = Stopwatch()..start();
    var state = await scanState();
    if (Platform.isWindows &&
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      await windowManager.ensureInitialized();
      await windowManager.focus();
    }
    while (state == 'queued' &&
        recovery.elapsed < const Duration(seconds: 20)) {
      await tester.pump(const Duration(milliseconds: 100));
      await runner.run(rescan);
      state = await scanState();
      if (state == 'queued') {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }
    expect(
      state,
      'complete',
      reason: 'Window lifecycle ${WidgetsBinding.instance.lifecycleState}',
    );
    expect(
      catalog.assets.singleWhere((row) => row['source_id'] == source)['id'],
      id,
    );
    mark({
      'phase': 'complete',
      ...playback,
      'scan_recovery_ms': recovery.elapsedMilliseconds,
      'scan_recovered': true,
    });
  } finally {
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
  }
}

Future<void> _verifyLongDav(
  WidgetTester tester,
  Catalog catalog,
  ScrapeTaskRunner runner,
  MpvConfigStore config,
) async {
  Metadata.token = '';
  Metadata.apiKey = '';
  final source = await catalog.addSource(
    'webdav',
    'Read-only validation WebDAV',
    'http://127.0.0.1:18781/fixture/',
  );
  await catalog.addScanRoot(source, '');
  await runner.run(await runner.enqueueScan(source));
  final asset = catalog.assets.singleWhere((row) => row['source_id'] == source);
  expect(asset['size'], greaterThan(1024 * 1024 * 1024));
  final assetId = asset['id'] as String;
  final counters = <Map<String, Object?>>[];
  Future<void> until(Stopwatch clock, bool Function() ready) async {
    while (!ready()) {
      expect(clock.elapsed, lessThan(const Duration(seconds: 25)));
      await tester.pump(const Duration(milliseconds: 30));
      await Future<void>.delayed(const Duration(milliseconds: 35));
    }
  }

  for (final withScan in [false, true, true, false]) {
    await catalog.db.delete(
      'progress',
      where: 'asset_id=?',
      whereArgs: [assetId],
    );
    final scan = withScan ? await runner.enqueueScan(source) : null;
    final clock = Stopwatch()..start();
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: WatchPage(asset: asset, configurationStore: config),
      ),
    );
    final dynamic page = tester.state(find.byType(WatchPage));
    final player = page.player as Player;
    await player.setVolume(0);
    var bufferCount = 0;
    var bufferMs = 0;
    int? bufferStart;
    final subscription = player.stream.buffering.distinct().listen((value) {
      if (value) {
        bufferCount++;
        bufferStart = clock.elapsedMilliseconds;
      } else if (bufferStart case final started?) {
        bufferMs += clock.elapsedMilliseconds - started;
        bufferStart = null;
      }
    });
    try {
      await until(clock, () => playingHeader.value != null);
      if (scan != null) {
        await runner.run(scan);
        expect(
          (await catalog.db.query(
            'scrape_tasks',
            where: 'id=?',
            whereArgs: [scan],
          )).single['state'],
          'queued',
        );
      }
      await until(
        clock,
        () =>
            player.state.position.inMilliseconds >= 350 &&
            !player.state.buffering,
      );
      final started = clock.elapsedMilliseconds;
      final duration = player.state.duration.inMilliseconds;
      expect(duration, greaterThan(20 * 60 * 1000));
      final midpoint = Duration(milliseconds: duration ~/ 2);
      final seekStart = clock.elapsedMilliseconds;
      await player.seek(midpoint);
      final seekClock = Stopwatch()..start();
      await until(
        seekClock,
        () =>
            player.state.position >
                midpoint + const Duration(milliseconds: 350) &&
            !player.state.buffering,
      );
      final seekMs = clock.elapsedMilliseconds - seekStart;
      final presented = Map<String, Object?>.from(
        await page.capturePresentedBuffer() as Map,
      );
      expect(presented, isNotEmpty);
      final observe = Stopwatch()..start();
      await until(
        observe,
        () =>
            player.state.position > midpoint + const Duration(seconds: 8) &&
            !player.state.buffering,
      );
      final native = player.platform as NativePlayer;
      Future<String?> read(String key) async {
        try {
          return await native.getProperty(key);
        } catch (_) {
          return null;
        }
      }

      counters.add({
        'scan_queued': withScan,
        'duration_ms': duration,
        'startup_to_progress_ms': started,
        'midpoint_seek_to_progress_ms': seekMs,
        'buffer_events': bufferCount,
        'buffer_ms': bufferMs,
        'decoder_drops': await read('decoder-frame-drop-count'),
        'output_drops': await read('frame-drop-count'),
        'rss_sample_bytes': ProcessInfo.currentRss,
        'surface': presented,
      });
    } finally {
      await subscription.cancel();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await player.stream.position.drain<void>().timeout(
        const Duration(seconds: 15),
      );
    }
    if (scan != null) {
      await runner.run(scan);
      expect(
        (await catalog.db.query(
          'scrape_tasks',
          where: 'id=?',
          whereArgs: [scan],
        )).single['state'],
        'complete',
      );
    }
    expect(
      catalog.assets.singleWhere((a) => a['source_id'] == source)['id'],
      assetId,
    );
  }
  debugPrint(
    'KONATA_LONG_DAV ${jsonEncode({'platform': Platform.operatingSystem, 'runs': counters})}',
  );
}

Future<void> _probeBangumi() async {
  const limit = Duration(seconds: 8);
  for (var attempt = 1; attempt <= 3; attempt++) {
    final client = HttpClient()..connectionTimeout = limit;
    try {
      final request = await client
          .getUrl(Uri.https('api.bgm.tv', '/v0/subjects/302189'))
          .timeout(limit);
      request.headers.set(
        HttpHeaders.userAgentHeader,
        'Konata/1.0 isolated-acceptance',
      );
      final response = await request.close().timeout(limit);
      final buffer = BytesBuilder();
      await for (final chunk in response.timeout(limit)) {
        buffer.add(chunk);
        if (buffer.length > 128 * 1024) {
          throw const FormatException('Unexpected provider response');
        }
      }
      final data = jsonDecode(utf8.decode(buffer.takeBytes()));
      final valid = data is Map && data['id'] == 302189 && data['type'] == 2;
      debugPrint(
        'KONATA_PROVIDER_REACHABILITY ${Platform.operatingSystem} '
        'attempt=$attempt status=${response.statusCode} subject_valid=$valid',
      );
      if (response.statusCode == 200 && valid) return;
      if (response.statusCode == 429) return;
    } catch (error) {
      final code = error is SocketException ? error.osError?.errorCode : null;
      debugPrint(
        'KONATA_PROVIDER_REACHABILITY ${Platform.operatingSystem} '
        'attempt=$attempt failure=${error.runtimeType} os_code=$code',
      );
    } finally {
      client.close(force: true);
    }
    if (attempt < 3) await Future<void>.delayed(const Duration(seconds: 2));
  }
}

Future<void> _verifyForeign(Directory root, String encoded) async {
  final catalog = Catalog.instance;
  final directory = Directory('${root.path}/foreign-library');
  await catalog.initialize(
    dataDirectory: directory,
    enableFoundation: true,
    enableTasks: true,
    enableMappings: true,
    enableRecognition: true,
    enableScopedArtwork: true,
    enableChapterRelations: true,
    enableLibraryMerge: true,
  );
  try {
    final zip = await File(
      '${root.path}/foreign.zip',
    ).writeAsBytes(base64Decode(encoded));
    final restorer = LibraryBackupRestorer(
      database: catalog.db,
      artworkDirectory: await ImageStore.directory(),
    );
    final prepared = await restorer.prepare(zip);
    try {
      await restorer.restore(prepared);
    } finally {
      await prepared.dispose();
    }
    await catalog.reload();
    final source = catalog.sources.single['id'] as String;
    final ids = catalog.assets.map((a) => a['id']).toSet();
    final asset =
        catalog.assets.singleWhere((a) => a['name'] == 'E01.mkv')['id']
            as String;
    expect(await catalog.sourceNeedsAssociation(source), isTrue);
    await catalog.updateSource(
      source,
      label: 'Reassociated fixture',
      location: '${root.path}/media-b',
      username: '',
    );
    expect(await catalog.sourceNeedsAssociation(source), isFalse);
    await catalog.addScanRoot(source, '');
    final runner = ScrapeTaskRunner.forCatalog(catalog);
    await runner.run(await runner.enqueueScan(source));
    expect(catalog.assets.map((a) => a['id']).toSet(), ids);
    expect(await catalog.resumePosition(asset), 1900);
    expect(await File('${root.path}/media-b/Series/E01.mkv').exists(), isTrue);
    debugPrint(
      'KONATA_FOREIGN_RESTORE ${Platform.operatingSystem} ${ids.length} files, 1900ms',
    );
  } finally {
    catalog.taskStore?.dispose();
    catalog.taskStore = null;
    await catalog.db.close();
    await ImageStore.close();
  }
}
