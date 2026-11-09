import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ccplayer/core/catalog.dart';
import 'package:ccplayer/core/mpv_config_store.dart';
import 'package:ccplayer/l10n/app_localizations.dart';
import 'package:ccplayer/ui/watch_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

class _ReturnObserver extends WidgetsBindingObserver {
  final entered = Completer<void>();
  final returned = Completer<void>();
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused && !entered.isCompleted) {
      entered.complete();
    }
    if (state == AppLifecycleState.resumed &&
        entered.isCompleted &&
        !returned.isCompleted) {
      returned.complete();
    }
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets(
    'three bounded local playback and resource cycles',
    (tester) async {
      const tag = String.fromEnvironment('RESOURCE_TAG');
      const lifecycle = bool.fromEnvironment('RESOURCE_LIFECYCLE');
      const audioRoute = bool.fromEnvironment('RESOURCE_AUDIO_ROUTE');
      const audioVolume = int.fromEnvironment(
        'RESOURCE_AUDIO_VOLUME',
        defaultValue: 20,
      );
      expect(tag, isNotEmpty);
      MediaKit.ensureInitialized();
      SharedPreferences.setMockInitialValues({});
      final root = await Directory.systemTemp.createTemp('konata-resources-');
      final catalog = Catalog.instance;
      await catalog.initialize(dataDirectory: root);
      final client = HttpClient();
      const endpoint = 'http://127.0.0.1:18769';
      final clock = Stopwatch()..start();
      final rows = <Map<String, Object?>>[];
      final cycles = <Map<String, Object?>>[];
      Player? activePlayer;
      String phase = 'setup';
      int round = 0;
      void mark(String next) {
        phase = next;
        debugPrint(
          'RESOURCE_MARK ${jsonEncode({'tag': tag, 'phase': phase, 'round': round, 'ms': clock.elapsedMilliseconds})}',
        );
      }

      Future<void> save(String name, List<int> data) async {
        final request = await client.postUrl(Uri.parse('$endpoint/$tag-$name'));
        request.contentLength = data.length;
        request.add(data);
        final response = await request.close();
        expect(response.statusCode, 201);
        await response.drain<void>();
      }

      Future<void> sample([NativePlayer? native]) async {
        final row = <String, Object?>{
          'round': round,
          'phase': phase,
          'ms': clock.elapsedMilliseconds,
          'rssBytes': ProcessInfo.currentRss,
          'imageCacheBytes':
              PaintingBinding.instance.imageCache.currentSizeBytes,
        };
        if (Platform.isAndroid) {
          try {
            row['fdCount'] = await Directory('/proc/self/fd').list().length;
          } catch (_) {
            row['fdCount'] = null;
          }
        }
        if (native != null) {
          final values = <String, String>{};
          for (final key
              in 'time-pos pause paused-for-cache frame-drop-count decoder-frame-drop-count avsync hwdec-current video-dec-params current-vo demuxer-cache-state/fw-bytes demuxer-max-bytes current-ao audio-device audio-params audio-out-params audio-device-list volume mute'
                  .split(' ')) {
            values[key] = await native.getProperty(key);
          }
          row['mpv'] = values;
        }
        rows.add(row);
      }

      Future<void> observe(int seconds, [NativePlayer? native]) async {
        final end = clock.elapsed + Duration(seconds: seconds);
        var nextSample = clock.elapsed;
        while (clock.elapsed < end) {
          await tester.pump();
          if (clock.elapsed >= nextSample) {
            await sample(native);
            nextSample = clock.elapsed + const Duration(seconds: 15);
          }
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        await sample(native);
      }

      Future<void> progressing(Player player, Duration after) async {
        final end = clock.elapsed + const Duration(seconds: 20);
        while (player.state.position <= after || player.state.buffering) {
          expect(clock.elapsed, lessThan(end));
          await tester.pump();
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }

      try {
        final response = await (await client.getUrl(
          Uri.parse('$endpoint/real-0.mkv'),
        )).close();
        expect(response.statusCode, 200);
        final clip = File('${root.path}/clip.mkv');
        await response.pipe(clip.openWrite());
        final source = await catalog.addSource(
          'local',
          'resource clip',
          root.path,
        );
        final asset = <String, Object?>{
          'id': 'clip',
          'work_id': 'clip',
          'source_id': source,
          'name': 'resource clip',
          'relative_path': 'clip.mkv',
          'category': 'main',
        };
        await catalog.db.insert('works', {
          'id': 'clip',
          'title': 'resource clip',
        });
        await catalog.db.insert('assets', asset);
        final config = MpvConfigStore(
          rootOverride: Directory('${root.path}/mpv'),
        );
        await config.initialize();
        if (Platform.isWindows) {
          await windowManager.ensureInitialized();
          await windowManager.show();
        }
        await tester.pumpWidget(const SizedBox());
        mark('idle_before');
        await observe(lifecycle ? 3 : 30);
        for (round = 1; round <= (lifecycle ? 1 : 3); round++) {
          await catalog.db.delete('progress');
          mark('opening');
          final opened = clock.elapsedMilliseconds;
          await tester.pumpWidget(
            MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: WatchPage(asset: asset, configurationStore: config),
            ),
          );
          final dynamic page = tester.state(find.byType(WatchPage));
          final player = page.player as Player;
          activePlayer = player;
          final native = player.platform as NativePlayer;
          await player.setVolume(audioRoute ? audioVolume.toDouble() : 0);
          await progressing(player, const Duration(milliseconds: 500));
          if (audioRoute) {
            expect(
              double.parse(await native.getProperty('volume')),
              audioVolume.toDouble(),
            );
            expect(await native.getProperty('mute'), 'no');
          }
          final cycle = <String, Object?>{
            'round': round,
            'progressStartMs': clock.elapsedMilliseconds - opened,
          };
          cycles.add(cycle);
          mark(audioRoute ? 'audio_route_ready' : 'playing');
          await observe(audioRoute ? 45 : (lifecycle ? 5 : 30), native);
          if (lifecycle && !audioRoute) {
            for (final landscape in [false, true, false]) {
              mark(landscape ? 'landscape' : 'portrait');
              if (Platform.isAndroid) {
                await SystemChrome.setPreferredOrientations([
                  landscape
                      ? DeviceOrientation.landscapeLeft
                      : DeviceOrientation.portraitUp,
                ]);
              } else if (Platform.isWindows) {
                await windowManager.setSize(
                  landscape ? const Size(1100, 650) : const Size(650, 900),
                );
              }
              final before = player.state.position;
              await observe(5, native);
              expect(
                player.state.position - before,
                greaterThan(const Duration(seconds: 3)),
              );
              final size = tester.view.physicalSize;
              expect(size.width > size.height, landscape);
              final capture = Map<Object?, Object?>.from(
                await page.capturePresentedBuffer() as Map,
              );
              cycle[phase + rows.length.toString()] = {
                'width': size.width,
                'height': size.height,
                'surface': capture,
              };
              expect(tester.takeException(), isNull);
            }
          }
          mark('seeking');
          await player.seek(const Duration(seconds: 10));
          await progressing(player, const Duration(milliseconds: 10500));
          await observe(10, native);
          await player.pause();
          final pausedAt = player.state.position;
          if (Platform.isAndroid) {
            final observer = _ReturnObserver();
            binding.addObserver(observer);
            try {
              mark(lifecycle ? 'lock_ready' : 'background_ready');
              // Host sends Home then returns to this isolated app. Do not pump
              // Flutter frames while the real app is suspended.
              await observer.entered.future.timeout(
                const Duration(seconds: 40),
              );
              await observer.returned.future.timeout(
                Duration(seconds: lifecycle ? 180 : 40),
              );
            } finally {
              binding.removeObserver(observer);
            }
          } else if (Platform.isWindows) {
            mark('background_ready');
            await windowManager.minimize();
            await Future<void>.delayed(const Duration(seconds: 3));
            await windowManager.restore();
          }
          mark('resuming');
          expect(
            (player.state.position - pausedAt).inMilliseconds.abs(),
            lessThan(300),
          );
          await player.play();
          await progressing(
            player,
            pausedAt + const Duration(milliseconds: 500),
          );
          await observe(10, native);
          if (lifecycle) {
            cycle['restoredSurface'] = Map<Object?, Object?>.from(
              await page.capturePresentedBuffer() as Map,
            );
            expect(tester.takeException(), isNull);
          }
          mark('seeking');
          await player.seek(const Duration(seconds: 40));
          await progressing(player, const Duration(milliseconds: 40500));
          await observe(10, native);
          cycle['finalPositionMs'] = player.state.position.inMilliseconds;
          mark('closing');
          await tester.pumpWidget(const SizedBox());
          await player.stream.position.drain<void>().timeout(
            const Duration(seconds: 20),
          );
          activePlayer = null;
          mark('idle_after');
          await observe(30);
        }
        mark('complete');
      } finally {
        try {
          if (activePlayer != null) {
            await tester.pumpWidget(const SizedBox());
            await activePlayer.stream.position.drain<void>().timeout(
              const Duration(seconds: 20),
            );
          }
          await save(
            'cycles.json',
            utf8.encode(jsonEncode({'cycles': cycles, 'samples': rows})),
          );
        } finally {
          client.close(force: true);
          await catalog.db.close();
          await root.delete(recursive: true);
        }
      }
    },
    timeout: const Timeout(Duration(minutes: 9)),
  );
}
