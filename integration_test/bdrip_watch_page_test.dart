import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ccplayer/core/catalog.dart';
import 'package:ccplayer/core/mpv_config_store.dart';
import 'package:ccplayer/core/playback_probe.dart';
import 'package:ccplayer/ui/watch_page.dart';

/// Production WatchPage with an isolated temporary catalog and in-memory prefs.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const folder = String.fromEnvironment('PLAYBACK_FIXTURE_DIR');
  const dll = String.fromEnvironment('PLAYBACK_MPV_DLL');
  const seconds = int.fromEnvironment(
    'PLAYBACK_SOAK_SECONDS',
    defaultValue: 600,
  );
  testWidgets(
    'production WatchPage isolated HEVC Main10 ten-minute stability',
    (tester) async {
      MediaKit.ensureInitialized(libmpv: dll.isEmpty ? null : dll);
      SharedPreferences.setMockInitialValues({});
      final temp = await Directory.systemTemp.createTemp(
        'ccplayer-bdrip-isolated-',
      );
      final cat = Catalog.instance;
      final samples = <Map<String, Object?>>[];
      final errors = <String>[];
      Player? player;
      StreamSubscription<String>? subscription;
      try {
        await cat.initialize(dataDirectory: temp);
        await cat.db.insert('sources', {
          'id': 'test-source',
          'kind': 'local',
          'label': 'Synthetic test',
          'location': folder,
        });
        await cat.db.insert('works', {
          'id': 'test-work',
          'title': 'Synthetic HEVC test',
        });
        final asset = <String, Object?>{
          'id': 'test-asset',
          'source_id': 'test-source',
          'work_id': 'test-work',
          'relative_path': 'hevc-main10-4k.mkv',
          'name': 'hevc-main10-4k.mkv',
          'category': 'main',
          'season': 1,
          'episode': 1,
        };
        await cat.db.insert('assets', asset);
        await cat.reload();
        final config = MpvConfigStore(
          rootOverride: Directory('${temp.path}/mpv'),
        );
        await config.initialize();
        final key = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            home: WatchPage(key: key, asset: asset, configurationStore: config),
          ),
        );
        await tester.pump();
        player = (key.currentState as dynamic).player as Player;
        final controller =
            (key.currentState as dynamic).controller as VideoController;
        subscription = player.stream.error.listen(errors.add);
        final frameDeadline = DateTime.now().add(const Duration(seconds: 30));
        while ((await (player.platform as NativePlayer).getProperty(
              'video-params/w',
            )).isEmpty &&
            DateTime.now().isBefore(frameDeadline)) {
          await tester.pump(const Duration(milliseconds: 50));
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        await controller.waitUntilFirstFrameRendered.timeout(
          const Duration(seconds: 30),
        );
        await player.setPlaylistMode(PlaylistMode.single);
        final native = player.platform as NativePlayer;
        final clock = Stopwatch()..start();
        while (clock.elapsed.inSeconds < seconds) {
          await Future<void>.delayed(const Duration(seconds: 5));
          await tester.pump();
          final elapsed = clock.elapsed.inSeconds;
          final stats = await PlaybackProbe(native.getProperty).statistics();
          samples.add({
            'elapsed_seconds': elapsed,
            'rss_bytes': ProcessInfo.currentRss,
            'max_rss_bytes': ProcessInfo.maxRss,
            'stats': stats,
          });
          expect(stats['video-params/w'], '3840');
          expect(errors, isEmpty);
          if (elapsed % 60 < 5) {
            debugPrint('WATCHPAGE_SOAK ${jsonEncode(samples.last)}');
          }
          if (elapsed % 30 < 5) {
            await player.pause();
            await player.seek(
              Duration(milliseconds: 500 + (elapsed * 37) % 2400),
            );
            await player.play();
          }
        }
        expect(clock.elapsed.inSeconds, greaterThanOrEqualTo(seconds));
        expect(controller.rect.value?.width, 3840);
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
        final deadline = DateTime.now().add(const Duration(seconds: 15));
        while (!(player.platform as NativePlayer).disposed &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect((player.platform as NativePlayer).disposed, isTrue);
        final progress = await cat.db.query('progress');
        expect(progress, isNotEmpty);
        debugPrint(
          'WATCHPAGE_SOAK_PASS seconds=${clock.elapsed.inSeconds} samples=${samples.length} progress_rows=${progress.length}',
        );
      } finally {
        await subscription?.cancel();
        await tester.pumpWidget(const SizedBox());
        if (player != null && !(player.platform as NativePlayer).disposed) {
          await player.dispose();
        }
        await File('$folder/watchpage-soak-results.json').writeAsString(
          const JsonEncoder.withIndent('  ').convert({
            'seconds_requested': seconds,
            'samples': samples,
            'errors': errors,
          }),
        );
        await cat.db.close();
        await temp.delete(recursive: true);
      }
    },
    skip: folder.isEmpty,
    timeout: const Timeout(Duration(minutes: 13)),
  );
}
