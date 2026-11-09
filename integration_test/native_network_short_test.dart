import 'dart:convert';
import 'dart:io';
import 'package:ccplayer/core/catalog.dart';
import 'package:ccplayer/core/debug_log.dart';
import 'package:ccplayer/core/mpv_config_store.dart';
import 'package:ccplayer/core/sources.dart';
import 'package:ccplayer/l10n/app_localizations.dart';
import 'package:ccplayer/ui/watch_page.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets(
    'bounded real network ranges playback seek and resume',
    (tester) async {
      const tag = String.fromEnvironment('NETWORK_TAG');
      expect(tag, isNotEmpty);
      MediaKit.ensureInitialized();
      SharedPreferences.setMockInitialValues({'debug_logs': true});
      final root = await Directory.systemTemp.createTemp('konata-network-');
      await DebugLog.initialize(root: root);
      final privateRoot = Platform.isAndroid
          ? await getApplicationSupportDirectory()
          : root;
      final configFile = File('${privateRoot.path}/network-qa.json');
      debugPrint('NETWORK_CONFIG_READY ${configFile.path}');
      final waitConfig = Stopwatch()..start();
      while (!await configFile.exists()) {
        expect(waitConfig.elapsed.inSeconds, lessThan(40));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      final cases = jsonDecode(await configFile.readAsString()) as List;
      await configFile.delete();
      final catalog = Catalog.instance;
      await catalog.initialize(dataDirectory: root);
      final store = MpvConfigStore(rootOverride: Directory('${root.path}/mpv'));
      await store.initialize();
      final http = HttpClient()
        ..connectionTimeout = const Duration(seconds: 15);
      final report = <Map<String, Object?>>[];
      final sources = <String>[];
      Player? active;
      Future<void> wait(int seconds) async {
        final watch = Stopwatch()..start();
        while (watch.elapsed.inSeconds < seconds) {
          await tester.pump();
          await Future<void>.delayed(const Duration(milliseconds: 30));
        }
      }

      Future<void> progress(
        Player player,
        Duration after, {
        List<Map<String, Object?>>? samples,
      }) async {
        final watch = Stopwatch()..start();
        var nextSample = 0;
        while (player.state.position <= after || player.state.buffering) {
          if (samples != null && watch.elapsed.inSeconds >= nextSample) {
            final native = player.platform as NativePlayer;
            final sample = <String, Object?>{
              'elapsedMs': watch.elapsedMilliseconds,
            };
            for (final key
                in 'hwdec hwdec-current core-idle pause paused-for-cache seeking time-pos video-params video-dec-params demuxer-cache-state eof-reached'
                    .split(' ')) {
              sample[key] = await native.getProperty(key);
            }
            samples.add(sample);
            nextSample += 5;
          }
          expect(watch.elapsed.inSeconds, lessThan(35));
          await tester.pump();
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }

      Future<Map<String, String>> stats(NativePlayer player) async => {
        for (final key
            in 'time-pos hwdec-current video-params/pixelformat frame-drop-count decoder-frame-drop-count paused-for-cache avsync demuxer-cache-state/fw-bytes demuxer-max-bytes'
                .split(' '))
          key: await player.getProperty(key),
        'demuxer-cache-state': await player.getProperty('demuxer-cache-state'),
      };
      if (Platform.isWindows) {
        await windowManager.ensureInitialized();
        await windowManager.show();
      }
      try {
        for (final raw in cases) {
          final config = Map<String, Object?>.from(raw as Map);
          final kind = config['kind'] as String;
          final clock = Stopwatch()..start();
          final id = await catalog.addSource(
            kind,
            'isolated $kind QA',
            config['location'] as String,
            username: config['username'] as String,
            password: config['password'] as String,
          );
          sources.add(id);
          final source = (await catalog.db.query(
            'sources',
            where: 'id=?',
            whereArgs: [id],
          )).single;
          final row = <String, Object?>{'kind': kind};
          report.add(row);
          final entries = await WebDav(
            await catalog.withCredentials(source),
          ).list(WebDav(source).root);
          expect(entries.any((e) => e.name == config['relative']), isTrue);
          row['listed'] = true;
          row['listMs'] = clock.elapsedMilliseconds;
          final ticket = await StreamBroker.instance.issue(
            source,
            config['relative'] as String,
          );
          final ranges = <Map<String, Object?>>[];
          try {
            for (final rawRange in config['ranges'] as List) {
              final range = rawRange as Map;
              final offset = range['offset'] as int;
              final length = range['length'] as int;
              clock.reset();
              final request = await http.getUrl(ticket);
              request.headers.set(
                'Range',
                'bytes=$offset-${offset + length - 1}',
              );
              final response = await request.close().timeout(
                const Duration(seconds: 25),
              );
              expect(response.statusCode, 206);
              final bytes = await response.fold<List<int>>(
                [],
                (a, b) => a..addAll(b),
              );
              expect(sha256.convert(bytes).toString(), range['sha256']);
              ranges.add({
                'offset': offset,
                'bytes': bytes.length,
                'ms': clock.elapsedMilliseconds,
              });
            }
          } finally {
            StreamBroker.instance.revoke(ticket);
          }
          row['ranges'] = ranges;
          final gone = await (await http.getUrl(ticket)).close();
          expect(gone.statusCode, 404);
          await gone.drain<void>();
          row['revoked'] = true;
          final asset = <String, Object?>{
            'id': kind,
            'work_id': kind,
            'source_id': id,
            'name': 'isolated network clip',
            'relative_path': config['relative'],
            'category': 'main',
          };
          await catalog.db.insert('works', {'id': kind, 'title': kind});
          await catalog.db.insert('assets', asset);
          clock.reset();
          await tester.pumpWidget(
            MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: WatchPage(asset: asset, configurationStore: store),
            ),
          );
          final dynamic page = tester.state(find.byType(WatchPage));
          final player = active = page.player as Player;
          final native = player.platform as NativePlayer;
          final errors = <String>[];
          final logs = <String>[];
          final errorsSubscription = player.stream.error.listen((error) {
            if (errors.length < 30) errors.add(DebugLog.redact(error));
          });
          final logsSubscription = player.stream.log.listen((event) {
            if (logs.length == 100) logs.removeAt(0);
            logs.add(DebugLog.redact(event.toString()));
          });
          await player.setVolume(0);
          final startupSamples = <Map<String, Object?>>[];
          row['startupSamples'] = startupSamples;
          try {
            await progress(
              player,
              const Duration(milliseconds: 500),
              samples: startupSamples,
            );
          } catch (_) {
            row['errors'] = errors;
            row['logs'] = logs;
            row['failureState'] = {
              'positionMs': player.state.position.inMilliseconds,
              'buffering': player.state.buffering,
              'playing': player.state.playing,
            };
            rethrow;
          } finally {
            await errorsSubscription.cancel();
            await logsSubscription.cancel();
          }
          row['startMs'] = clock.elapsedMilliseconds;
          final firstPosition = player.state.position;
          await wait(15);
          row['initial'] = await stats(native);
          row['initialProgressMs'] =
              (player.state.position - firstPosition).inMilliseconds;
          expect(
            row['initialProgressMs'],
            greaterThanOrEqualTo(12000),
            reason:
                '15 seconds of steady playback must advance at least 12 seconds',
          );
          clock.reset();
          await player.seek(const Duration(seconds: 40));
          await progress(player, const Duration(milliseconds: 40500));
          row['seekMs'] = clock.elapsedMilliseconds;
          final seekPosition = player.state.position;
          await wait(8);
          row['afterSeek'] = await stats(native);
          row['seekProgressMs'] =
              (player.state.position - seekPosition).inMilliseconds;
          expect(row['seekProgressMs'], greaterThanOrEqualTo(6000));
          await player.pause();
          final paused = player.state.position;
          await wait(2);
          expect(
            (player.state.position - paused).inMilliseconds.abs(),
            lessThan(250),
          );
          await player.play();
          await progress(player, paused + const Duration(milliseconds: 500));
          row['resume'] = true;
          await tester.pumpWidget(const SizedBox());
          await player.stream.position.drain<void>().timeout(
            const Duration(seconds: 20),
          );
          active = null;
          row['disposed'] = native.disposed;
          await wait(7);
          debugPrint('NETWORK_CASE_DONE $kind');
        }
      } finally {
        if (active != null) {
          await tester.pumpWidget(const SizedBox());
          await active.stream.position.drain<void>().timeout(
            const Duration(seconds: 20),
          );
        }
        for (final id in sources) {
          await catalog.removeSource(id);
        }
        await DebugLog.flush();
        final diagnostic = <String>[];
        if (await DebugLog.directory!.exists()) {
          await for (final file in DebugLog.directory!.list()) {
            if (file is File) {
              diagnostic.addAll(
                (await file.readAsLines()).where(
                  (line) =>
                      line.contains('[SMB]') ||
                      line.contains('decode_software_fallback'),
                ),
              );
            }
          }
        }
        report.add({'smbDiagnostics': diagnostic.take(100).toList()});
        final request = await http.postUrl(
          Uri.parse('http://127.0.0.1:18769/$tag.json'),
        );
        final bytes = utf8.encode(jsonEncode(report));
        request.contentLength = bytes.length;
        request.add(bytes);
        final response = await request.close();
        expect(response.statusCode, 201);
        await response.drain<void>();
        http.close(force: true);
        await catalog.db.close();
        await root.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
