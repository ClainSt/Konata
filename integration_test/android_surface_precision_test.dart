import 'dart:convert';
import 'dart:io';
import 'package:ccplayer/core/playback_probe.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native Android surface preserves gradient precision',
    (tester) async {
      MediaKit.ensureInitialized();
      final root = await Directory.systemTemp.createTemp(
        'konata-surface-trial-',
      );
      final file = File('${root.path}/gradient.mkv');
      final client = HttpClient();
      try {
        final response = await (await client.getUrl(
          Uri.parse(
            const String.fromEnvironment(
              'SURFACE_STAGE_URL',
              defaultValue: 'http://127.0.0.1:18768/gradient10-long.mkv',
            ),
          ),
        )).close();
        expect(response.statusCode, 200);
        await response.pipe(file.openWrite());
      } finally {
        client.close(force: true);
      }
      final player = Player(
        configuration: const PlayerConfiguration(
          libass: true,
          logLevel: MPVLogLevel.warn,
        ),
      );
      final native = player.platform as NativePlayer;
      MethodChannel? surface;
      addTearDown(() async {
        await player.dispose();
        await tester.pumpWidget(const SizedBox());
        await root.delete(recursive: true);
        await const MethodChannel(
          'ccplayer/playback_window',
        ).invokeMethod<void>('fullscreen', false);
      });
      await const MethodChannel(
        'ccplayer/playback_window',
      ).invokeMethod<void>('fullscreen', true);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlatformViewLink(
              viewType: 'ccplayer/android_surface',
              surfaceFactory: (_, controller) => AndroidViewSurface(
                controller: controller as AndroidViewController,
                gestureRecognizers:
                    const <Factory<OneSequenceGestureRecognizer>>{},
                hitTestBehavior: PlatformViewHitTestBehavior.opaque,
              ),
              onCreatePlatformView: (params) {
                surface = MethodChannel(
                  'ccplayer/android_surface/${params.id}',
                );
                return PlatformViewsService.initExpensiveAndroidView(
                    id: params.id,
                    viewType: 'ccplayer/android_surface',
                    layoutDirection: TextDirection.ltr,
                    creationParams: const <String, Object>{},
                    creationParamsCodec: const StandardMessageCodec(),
                  )
                  ..addOnPlatformViewCreatedListener(
                    params.onPlatformViewCreated,
                  )
                  ..create();
              },
            ),
          ),
        ),
      );
      Map<Object?, Object?>? attached;
      for (var i = 0; i < 100; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        await Future<void>.delayed(const Duration(milliseconds: 50));
        attached = await surface?.invokeMapMethod<Object?, Object?>('current');
        if (attached != null && (attached['width'] as int) > 0) break;
      }
      expect(attached, isNotNull);
      const outputFormat = String.fromEnvironment(
        'SURFACE_OUTPUT_FORMAT',
        defaultValue: 'rgb10_a2',
      );
      const decoder = String.fromEnvironment(
        'SURFACE_HWDEC',
        defaultValue: 'no',
      );
      for (final entry in {
        'wid': '${attached!['wid']}',
        'vid': 'auto',
        'vo': 'gpu',
        'gpu-api': 'opengl',
        'gpu-context': 'android',
        'egl-output-format': outputFormat,
        'hwdec': decoder,
        'dither': 'no',
        // Nearest sampling prevents interpolation from inventing intermediate
        // levels and making an already truncated gradient look high precision.
        'scale': 'nearest',
        'dscale': 'nearest',
        'cscale': 'nearest',
        'volume': '0',
      }.entries) {
        await native.setProperty(entry.key, entry.value);
      }
      await player.open(Media(file.path));
      for (var i = 0; i < 200 && player.state.position.inSeconds < 2; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(player.state.position.inSeconds, greaterThanOrEqualTo(2));
      await player.pause();
      final captured = await surface!.invokeMapMethod<String, Object?>(
        'capturePrecision',
      );
      final stats = await PlaybackProbe(native.getProperty).statistics();
      debugPrint(
        'ANDROID_SURFACE_PRECISION ${jsonEncode({'outputFormat': outputFormat, 'requestedHwdec': decoder, 'fixtureSha256': sha256.convert(await file.readAsBytes()).toString(), 'surface': captured, 'stats': stats})}',
      );
      expect(stats['hwdec-current'], decoder);
      for (final component in ['redLevels', 'greenLevels', 'blueLevels']) {
        expect(
          captured![component] as int,
          outputFormat == 'rgba8' ? lessThanOrEqualTo(256) : greaterThan(256),
        );
      }
      // Keep the paused surface alive for the runner's independent compositor read.
      await Future<void>.delayed(const Duration(seconds: 5));
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
