// Opt-in real-device resource/lifecycle experiment; never uses the user catalog.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show FramePhase, FrameTiming;

import 'package:ccplayer/core/catalog.dart';
import 'package:ccplayer/core/debug_log.dart';
import 'package:ccplayer/core/mpv_config_store.dart';
import 'package:ccplayer/l10n/app_localizations.dart';
import 'package:ccplayer/ui/watch_page.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'webdav_trial_support.dart';

class _BackgroundRound extends WidgetsBindingObserver {
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
  const sourceUrl = String.fromEnvironment('DAV_COLD_ROOT');
  const relative = String.fromEnvironment('DAV_COLD_FILE');
  const compareFramePolicy = bool.fromEnvironment('DAV_COMPARE_FRAME_POLICY');
  testWidgets(
    'three real WebDAV playback resource cycles and background return',
    (tester) async {
      MediaKit.ensureInitialized();
      SharedPreferences.setMockInitialValues({});
      final root = await Directory.systemTemp.createTemp(
        'konata-dav-resources-',
      );
      final catalog = Catalog.instance;
      await catalog.initialize(dataDirectory: root);
      DebugLog.directory = Directory('${root.path}/logs');
      await DebugLog.directory!.create();
      DebugLog.enabled = true;
      final clock = Stopwatch()..start();
      final samples = <Map<String, Object?>>[];
      final cycles = <Map<String, Object?>>[];
      final frameTimings = <Map<String, Object?>>[];
      var phase = 'setup';
      void onFrames(List<FrameTiming> values) {
        if (!phase.startsWith('pacing_')) {
          return;
        }
        for (final value in values) {
          frameTimings.add({
            'phase': phase,
            'vsync_us': value.timestampInMicroseconds(FramePhase.vsyncStart),
            'build_us': value.buildDuration.inMicroseconds,
            'raster_us': value.rasterDuration.inMicroseconds,
            'total_us': value.totalSpan.inMicroseconds,
          });
        }
      }

      binding.addTimingsCallback(onFrames);
      void mark(String value, int round) {
        phase = value;
        debugPrint(
          'SOAK_MARK ${jsonEncode({'phase': value, 'round': round, 'ms': clock.elapsedMilliseconds})}',
        );
      }

      Future<void> sample(int round, [NativePlayer? native]) async {
        int? fdCount;
        try {
          fdCount = await Directory(
            '/proc/self/fd',
          ).list(followLinks: false).length;
        } on FileSystemException {
          // Descriptors can close during enumeration; an unavailable metric must
          // not abort playback or hide its independently collected results.
        }
        final properties = <String, String>{};
        if (native != null) {
          for (final key in [
            'time-pos',
            'pause',
            'paused-for-cache',
            'demuxer-cache-duration',
            'demuxer-cache-state/fw-bytes',
            'frame-drop-count',
            'decoder-frame-drop-count',
            'avsync',
            'hwdec-current',
            'current-vo',
            'network-timeout',
            'demuxer-max-bytes',
          ]) {
            try {
              properties[key] = await native
                  .getProperty(key)
                  .timeout(const Duration(seconds: 2));
            } catch (_) {
              properties[key] = 'unavailable';
            }
          }
        }
        samples.add({
          'round': round,
          'phase': phase,
          'ms': clock.elapsedMilliseconds,
          'rss_bytes': ProcessInfo.currentRss,
          'open_fd_count': fdCount,
          'flutter_image_cache_bytes':
              PaintingBinding.instance.imageCache.currentSizeBytes,
          'properties': properties,
        });
      }

      Future<void> observe(
        int seconds,
        int round, [
        NativePlayer? native,
      ]) async {
        final end = clock.elapsed + Duration(seconds: seconds);
        var nextSample = clock.elapsed;
        while (clock.elapsed < end) {
          await tester.pump();
          if (clock.elapsed >= nextSample) {
            await sample(round, native);
            nextSample = clock.elapsed + const Duration(seconds: 15);
          }
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
        await sample(round, native);
      }

      try {
        final source = await catalog.addSource(
          'webdav',
          'resource experiment',
          sourceUrl,
          username: 'anonymous',
        );
        final asset = <String, Object?>{
          'id': 'clip',
          'source_id': source,
          'relative_path': relative,
          'name': 'Resource experiment',
          'work_id': 'work',
          'category': 'main',
        };
        await catalog.db.insert('works', {'id': 'work', 'title': 'experiment'});
        await catalog.db.insert('assets', asset);
        final config = MpvConfigStore(
          rootOverride: Directory('${root.path}/mpv'),
        );
        await config.initialize();
        await tester.pumpWidget(const SizedBox());
        mark('idle_before', 0);
        await observe(30, 0);
        for (var round = 1; round <= 3; round++) {
          await catalog.db.delete('progress');
          final row = <String, Object?>{'round': round};
          cycles.add(row);
          final key = GlobalKey();
          mark('opening', round);
          final opened = clock.elapsedMilliseconds;
          await tester.pumpWidget(
            MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: WatchPage(
                key: key,
                asset: asset,
                configurationStore: config,
              ),
            ),
          );
          final dynamic page = key.currentState;
          final player = page.player as Player;
          final native = player.platform as NativePlayer;
          final errors = <Map<String, Object?>>[];
          row['errors'] = errors;
          final buffering = <Map<String, Object?>>[];
          row['buffering_events'] = buffering;
          final errorSub = player.stream.error.listen((error) {
            errors.add({
              'ms': clock.elapsedMilliseconds,
              'phase': phase,
              'kinds': RegExp(
                r'HTTP (?:error )?\d{3}|timed out|connection refused|failed to open',
                caseSensitive: false,
              ).allMatches(error).map((m) => m.group(0)).toList(),
            });
          });
          final bufferSub = player.stream.buffering.listen((value) {
            buffering.add({
              'ms': clock.elapsedMilliseconds,
              'phase': phase,
              'value': value,
            });
          });
          try {
            await player.setVolume(0);
            var framed = false;
            unawaited(
              (page.controller as VideoController).waitUntilFirstFrameRendered
                  .then((_) {
                    framed = true;
                    row['first_frame_ms'] = clock.elapsedMilliseconds - opened;
                  }),
            );
            await poll(
              tester,
              () async =>
                  framed &&
                  player.state.position.inMilliseconds >= 1000 &&
                  !player.state.buffering,
              seconds: 30,
            );
            if (round == 1 && compareFramePolicy) {
              // Same clip and settings, alternate only test frame scheduling.
              // Flutter timing counts do not by themselves count unique video frames.
              for (var trial = 0; trial < 4; trial++) {
                binding.framePolicy =
                    LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
                await player.seek(const Duration(milliseconds: 1144750));
                await poll(
                  tester,
                  () async =>
                      player.state.position.inMilliseconds >= 1145000 &&
                      !player.state.buffering,
                  seconds: 30,
                );
                await observe(2, round, native);
                final live = trial.isOdd;
                binding.framePolicy = live
                    ? LiveTestWidgetsFlutterBindingFramePolicy.fullyLive
                    : LiveTestWidgetsFlutterBindingFramePolicy.fadePointers;
                mark('pacing_${live ? "live" : "pumped"}_${trial + 1}', round);
                await observe(15, round, native);
              }
              binding.framePolicy =
                  LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
              await player.seek(Duration.zero);
              await poll(
                tester,
                () async =>
                    player.state.position.inMilliseconds >= 1000 &&
                    player.state.position.inMilliseconds < 15000 &&
                    !player.state.buffering,
                seconds: 30,
              );
            }
            mark('playing', round);
            await observe(120, round, native);
            if (round == 1) {
              await player.pause();
              final observer = _BackgroundRound();
              binding.addObserver(observer);
              try {
                mark('background_ready', round);
                await observer.entered.future.timeout(
                  const Duration(minutes: 1),
                );
                final backgroundStart = DateTime.now();
                await observer.returned.future.timeout(
                  const Duration(minutes: 13),
                );
                row['background_ms'] = DateTime.now()
                    .difference(backgroundStart)
                    .inMilliseconds;
              } finally {
                binding.framePolicy =
                    LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
                binding.removeTimingsCallback(onFrames);
                binding.removeObserver(observer);
              }
              mark('resuming', round);
              final start = clock.elapsedMilliseconds;
              final position = player.state.position;
              await player.play();
              await poll(
                tester,
                () async =>
                    player.state.position >
                        position + const Duration(seconds: 1) &&
                    !player.state.buffering,
                seconds: 30,
              );
              row['resume_progress_ms'] = clock.elapsedMilliseconds - start;
              mark('after_resume', round);
              await observe(30, round, native);
            }
            final seeks = <Map<String, Object?>>[];
            row['seeks'] = seeks;
            for (final target in [60, 1300, 20]) {
              mark('seeking', round);
              final start = clock.elapsedMilliseconds;
              await player.seek(Duration(seconds: target));
              await player.play();
              await poll(
                tester,
                () async =>
                    player.state.position.inMilliseconds >=
                        target * 1000 + 300 &&
                    player.state.position.inMilliseconds <
                        target * 1000 + 15000 &&
                    !player.state.buffering,
                seconds: 30,
              );
              seeks.add({
                'target_s': target,
                'progress_ms': clock.elapsedMilliseconds - start,
              });
              mark('after_seek', round);
              await observe(10, round, native);
            }
            await sample(round, native);
            expect(errors, isEmpty);
          } finally {
            await errorSub.cancel();
            await bufferSub.cancel();
            mark('closing', round);
            await tester.pumpWidget(const SizedBox());
            await poll(tester, () async => native.disposed, seconds: 15);
            row['native_disposed'] = native.disposed;
            mark('idle_after', round);
            await observe(45, round);
          }
        }
        mark('complete', 3);
      } finally {
        await DebugLog.flush();
        final log = File('${root.path}/logs/current.log');
        binding.reportData = {
          'mode': kProfileMode ? 'profile' : (kDebugMode ? 'debug' : 'release'),
          'scope': 'three same-process cycles; upstream cache unknown',
          'cycles': cycles,
          'samples': samples,
          'frame_timings': frameTimings,
          'relay_log': await log.exists()
              ? (await log.readAsLines()).map(DebugLog.redact).toList()
              : <String>[],
        };
        DebugLog.enabled = false;
        DebugLog.directory = null;
        await catalog.db.close();
        await root.delete(recursive: true);
      }
    },
    skip: sourceUrl.isEmpty || relative.isEmpty || !Platform.isAndroid,
    timeout: const Timeout(Duration(minutes: 27)),
  );
}
