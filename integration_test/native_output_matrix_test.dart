import 'dart:convert';
import 'dart:io';

import 'package:ccplayer/core/catalog.dart';
import 'package:ccplayer/core/mpv_config_store.dart';
import 'package:ccplayer/core/playback_probe.dart';
import 'package:ccplayer/l10n/app_localizations.dart';
import 'package:ccplayer/ui/watch_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';
import 'support/diagnostic_mpv_config.dart';

class _MatrixConfigStore extends DiagnosticMpvConfigStore {
  _MatrixConfigStore({required super.rootOverride});

  @override
  PlayerConfiguration configurationFor(Directory? profile) {
    final config = super.configurationFor(profile);
    if (!const bool.fromEnvironment('MATRIX_TRACE')) return config;
    return PlayerConfiguration(
      logLevel: MPVLogLevel.debug,
      libass: config.libass,
      mpvConfigurationDirectory: config.mpvConfigurationDirectory,
      mpvRespectRenderingConfiguration: config.mpvRespectRenderingConfiguration,
    );
  }
}

// Diagnostic only: actual presented high-precision pixels plus mpv's own
// window readback. The host compares them with standalone mpv at the same PTS.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets(
    'normal WatchPage native output picture and lifecycle',
    (tester) async {
      const tag = String.fromEnvironment('PICTURE_TAG');
      expect(tag, isNotEmpty);
      MediaKit.ensureInitialized();
      SharedPreferences.setMockInitialValues({});
      final root = await Directory.systemTemp.createTemp('konata-picture-');
      final catalog = Catalog.instance;
      await catalog.initialize(dataDirectory: root);
      final client = HttpClient();
      const endpoint = 'http://127.0.0.1:18769';
      Future<void> save(String name, List<int> bytes) async {
        final request = await client.postUrl(Uri.parse('$endpoint/$tag-$name'));
        request.contentLength = bytes.length;
        request.add(bytes);
        final response = await request.close();
        expect(response.statusCode, 201);
        await response.drain<void>();
      }

      Future<void> wait(int milliseconds) async {
        final clock = Stopwatch()..start();
        while (clock.elapsedMilliseconds < milliseconds) {
          await tester.pump();
          await Future<void>.delayed(const Duration(milliseconds: 16));
        }
      }

      if (Platform.isWindows) {
        await windowManager.ensureInitialized();
        await windowManager.show();
      }
      try {
        final cases = <(String, VideoDecodeMode, bool)>[
          for (final name in [
            'real-0',
            'real-1',
            'real-2',
            'real-3',
            'real-4',
            'real-5',
            'real-6',
          ])
            (name, VideoDecodeMode.automatic, false),
          ('real-6', VideoDecodeMode.software, false),
          if (const String.fromEnvironment('MATRIX_CASE') ==
              'real-3-software-off')
            ('real-3', VideoDecodeMode.software, false),
          ('real-0', VideoDecodeMode.custom, false),
          ('real-0', VideoDecodeMode.custom, true),
          if (const bool.fromEnvironment('MATRIX_SUBTITLES'))
            ('real-7', VideoDecodeMode.automatic, false),
          if (const bool.fromEnvironment('MATRIX_NORMAL_STORE')) ...[
            ('real-1', VideoDecodeMode.automatic, true),
            ('real-0', VideoDecodeMode.automatic, true),
          ],
        ];
        for (var caseIndex = 0; caseIndex < cases.length; caseIndex++) {
          final (name, mode, configEnabled) = cases[caseIndex];
          final caseTag = '$name-${mode.name}-${configEnabled ? "on" : "off"}';
          const selectedCase = String.fromEnvironment('MATRIX_CASE');
          if (selectedCase.isNotEmpty &&
              !selectedCase.split(',').contains(caseTag)) {
            continue;
          }
          final response = await (await client.getUrl(
            Uri.parse('$endpoint/$name.mkv'),
          )).close();
          expect(response.statusCode, 200);
          final file = File('${root.path}/$name.mkv');
          await response.pipe(file.openWrite());
          final source = await catalog.addSource('local', name, root.path);
          final asset = <String, Object?>{
            'id': caseTag,
            'work_id': caseTag,
            'name': name,
            'relative_path': '$name.mkv',
            'source_id': source,
            'category': 'main',
          };
          await catalog.db.insert('works', {'id': caseTag, 'title': name});
          await catalog.db.insert('assets', asset);
          final profileRoot = Directory('${root.path}/mpv-$caseTag');
          final store = const bool.fromEnvironment('MATRIX_NORMAL_STORE')
              ? MpvConfigStore(rootOverride: profileRoot)
              : _MatrixConfigStore(rootOverride: profileRoot);
          await store.initialize();
          if (store is DiagnosticMpvConfigStore) {
            await store.setDecodeMode(mode);
          }
          await store.saveConfig(
            'mpv.conf',
            '${mode == VideoDecodeMode.automatic && configEnabled ? '' : 'hwdec=no\n'}scale=lanczos\ndscale=mitchell\ndither=no\n',
          );
          await store.setConfigEnabled(configEnabled);
          await tester.pumpWidget(
            MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: WatchPage(asset: asset, configurationStore: store),
            ),
          );
          final dynamic page = tester.state(find.byType(WatchPage));
          Player? createdPlayer;
          for (var i = 0; i < 200 && createdPlayer == null; i++) {
            await wait(20);
            try {
              createdPlayer = page.player as Player;
            } on Error {
              /* Enabled configuration is snapshotted asynchronously. */
            }
          }
          expect(createdPlayer, isNotNull);
          final player = createdPlayer!;
          final native = player.platform as NativePlayer;
          final playbackLogs = <String>[];
          final logSubscription = player.stream.log.listen((event) {
            if (playbackLogs.length == 500) playbackLogs.removeAt(0);
            playbackLogs.add(event.toString());
          });
          await player.setVolume(0);
          for (
            var i = 0;
            i < 200 && player.state.position.inMilliseconds < 500;
            i++
          ) {
            await wait(100);
          }
          if (player.state.position.inMilliseconds < 500) {
            final startup = <String, Object?>{'logs': playbackLogs};
            for (final key
                in 'hwdec hwdec-current current-vo time-pos pause core-idle video-params video-dec-params track-list'
                    .split(' ')) {
              try {
                startup[key] = await native.getProperty(key);
              } catch (_) {
                startup[key] = 'unavailable';
              }
            }
            await save(
              '$caseTag-startup-failure.json',
              utf8.encode(jsonEncode(startup)),
            );
            debugPrint('STARTUP_FAILURE ${jsonEncode(startup)}');
          }
          expect(
            player.state.position.inMilliseconds,
            greaterThanOrEqualTo(500),
          );
          await wait(2500);
          if (const bool.fromEnvironment('MATRIX_SUBTITLES')) await wait(4000);
          expect(
            find.byType(SnackBar),
            findsNothing,
            reason: 'Automatic decoder fallback is silent',
          );
          await player.pause();
          final daily = <String, String>{};
          for (final key
              in 'mpv-version ffmpeg-version hwdec hwdec-current current-vo video-codec video-params video-dec-params video-out-params scale cscale dscale dither dither-depth target-prim target-trc target-peak tone-mapping frame-drop-count decoder-frame-drop-count paused-for-cache'
                  .split(' ')) {
            try {
              daily[key] = await native.getProperty(key);
            } catch (_) {
              daily[key] = 'unavailable';
            }
          }
          await save('$caseTag-daily.json', utf8.encode(jsonEncode(daily)));
          debugPrint(
            'DAILY_OPTIONS ${jsonEncode({'case': caseTag, 'values': daily})}',
          );
          if ((name == 'real-0' &&
                  mode == VideoDecodeMode.custom &&
                  !configEnabled) ||
              name == 'real-5') {
            final decoded = jsonDecode(daily['video-dec-params']!) as Map;
            expect(
              PlaybackProbe.componentDepth(decoded['pixelformat'] as String?) ??
                  PlaybackProbe.componentDepth(
                    decoded['hw-pixelformat'] as String?,
                  ),
              greaterThanOrEqualTo(10),
              reason: 'Known 10-bit fixture must retain decoded precision',
            );
          }
          if (configEnabled) {
            expect(daily['scale'], 'lanczos');
            expect(daily['dscale'], 'mitchell');
            if (mode == VideoDecodeMode.custom) {
              expect(daily['hwdec-current'], 'no');
            } else if (name == 'real-1') {
              expect(daily['hwdec'], startsWith('auto'));
              expect(daily['hwdec-current'], isNot('no'));
            }
          } else {
            expect(daily['scale'], isNot('lanczos'));
          }
          // Explicit deterministic capture; daily playback is not reconfigured.
          await native.setProperty('dither', 'no');
          await native.setProperty('screenshot-high-bit-depth', 'yes');
          await native.setProperty('screenshot-format', 'png');
          await native.setProperty('osd-level', '0');
          await native.setProperty(
            'sub-visibility',
            const bool.fromEnvironment('MATRIX_SUBTITLES') ? 'yes' : 'no',
          );
          for (final timestamp
              in const bool.fromEnvironment('MATRIX_SUBTITLES')
                  ? ['1.001', '3.003', '7.007']
                  : ['5.005']) {
            await native.command(['seek', timestamp, 'absolute+exact']);
            for (var i = 0; i < 100; i++) {
              await wait(50);
              final pos = double.tryParse(await native.getProperty('time-pos'));
              if (pos != null &&
                  (pos - double.parse(timestamp)).abs() < 0.05 &&
                  await native.getProperty('seeking') == 'no') {
                break;
              }
            }
            await wait(400);
            final fields = <String, String>{};
            for (final key
                in 'mpv-version ffmpeg-version time-pos video-pts hwdec-current video-params/pixelformat video-params/primaries video-params/gamma video-params/colorlevels video-params/colormatrix osd-width osd-height scale cscale dscale dither dither-depth correct-downscaling linear-downscaling sigmoid-upscaling hdr-compute-peak deband interpolation tone-mapping target-prim target-trc target-peak sub-ass-override sub-visibility sub-scale sub-use-margins sub-ass-force-margins sub-scale-with-window sid'
                    .split(' ')) {
              try {
                fields[key] = await native.getProperty(key);
              } catch (_) {
                fields[key] = 'unavailable';
              }
            }
            expect(
              (double.parse(fields['time-pos']!) - double.parse(timestamp))
                  .abs(),
              lessThan(0.05),
            );
            final capture = Map<Object?, Object?>.from(
              await page.capturePresentedBuffer(pixels: false) as Map,
            );
            capture.remove('pixels');
            final stem = '$caseTag-$timestamp';
            final png = File('${root.path}/$stem.png');
            await native.command(['screenshot-to-file', png.path, 'window']);
            expect(await png.exists(), isTrue);
            await save('$stem.png', await png.readAsBytes());
            await save(
              '$stem.json',
              utf8.encode(jsonEncode({'surface': capture, 'mpv': fields})),
            );
            debugPrint(
              'PICTURE_FRAME ${jsonEncode({'tag': tag, 'sample': stem, 'surface': capture, 'mpv': fields})}',
            );
          }
          // Pause/seek/resume smoke; real Home/rotation is a separate host-driven
          // Release check. Pumping an artificially paused engine can deadlock.
          await player.play();
          await wait(1000);
          await player.pause();
          final before = player.state.position;
          await wait(500);
          expect(player.state.playing, isFalse);
          expect(
            (player.state.position - before).inMilliseconds.abs(),
            lessThan(100),
          );
          await player.play();
          await wait(1500);
          expect(player.state.position, greaterThan(before));
          await tester.pumpWidget(const SizedBox());
          await logSubscription.cancel();
          await player.stream.position.drain<void>().timeout(
            const Duration(seconds: 20),
          );
          await wait(
            const int.fromEnvironment(
              'MATRIX_EXIT_DELAY_MS',
              defaultValue: 1000,
            ),
          );
        }
      } finally {
        client.close(force: true);
        await catalog.db.close();
        await root.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
