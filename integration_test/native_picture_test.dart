import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ccplayer/core/catalog.dart';
import 'support/diagnostic_mpv_config.dart';
import 'package:ccplayer/l10n/app_localizations.dart';
import 'package:ccplayer/ui/watch_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

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
        for (final name in ['real-0', 'real-1', 'real-2']) {
          final response = await (await client.getUrl(
            Uri.parse('$endpoint/$name.mkv'),
          )).close();
          expect(response.statusCode, 200);
          final file = File('${root.path}/$name.mkv');
          await response.pipe(file.openWrite());
          final source = await catalog.addSource('local', name, root.path);
          final asset = <String, Object?>{
            'id': name,
            'work_id': name,
            'name': name,
            'relative_path': '$name.mkv',
            'source_id': source,
            'category': 'main',
          };
          await catalog.db.insert('works', {'id': name, 'title': name});
          await catalog.db.insert('assets', asset);
          final store = DiagnosticMpvConfigStore(
            rootOverride: Directory('${root.path}/mpv-$name'),
          );
          await store.initialize();
          await store.setDecodeMode(VideoDecodeMode.software);
          await tester.pumpWidget(
            MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: WatchPage(asset: asset, configurationStore: store),
            ),
          );
          final dynamic page = tester.state(find.byType(WatchPage));
          final player = page.player as Player;
          final native = player.platform as NativePlayer;
          await player.setVolume(0);
          for (
            var i = 0;
            i < 200 && player.state.position.inMilliseconds < 500;
            i++
          ) {
            await wait(100);
          }
          expect(
            player.state.position.inMilliseconds,
            greaterThanOrEqualTo(500),
          );
          await player.pause();
          // Explicit deterministic capture; daily playback is not reconfigured.
          await native.setProperty('dither', 'no');
          await native.setProperty('screenshot-high-bit-depth', 'yes');
          await native.setProperty('screenshot-format', 'png');
          await native.setProperty('osd-level', '0');
          await native.setProperty('sub-visibility', 'no');
          for (final timestamp in ['5.005', '12.012']) {
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
                in 'mpv-version ffmpeg-version time-pos video-pts hwdec-current video-params/pixelformat video-params/primaries video-params/gamma video-params/colorlevels video-params/colormatrix osd-width osd-height scale cscale dscale dither dither-depth correct-downscaling linear-downscaling sigmoid-upscaling hdr-compute-peak deband interpolation tone-mapping target-prim target-trc target-peak sub-ass-override sid'
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
              await page.capturePresentedBuffer(pixels: true) as Map,
            );
            final pixels = capture.remove('pixels') as Uint8List;
            final stem = '$name-$timestamp';
            await save('$stem.raw', pixels);
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
          await player.stream.position.drain<void>().timeout(
            const Duration(seconds: 20),
          );
          await wait(1000);
        }
      } finally {
        client.close(force: true);
        await catalog.db.close();
        await root.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
