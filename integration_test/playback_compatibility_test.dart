import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:ccplayer/core/playback_probe.dart';
import 'package:ccplayer/core/webdav_stream.dart';

/// Standalone test app: does NOT initialize Catalog, user prefs or library.
/// `--dart-define=PLAYBACK_FIXTURE_DIR=synthetic_fixture_folder`
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const folder = String.fromEnvironment('PLAYBACK_FIXTURE_DIR');
  const dll = String.fromEnvironment('PLAYBACK_MPV_DLL');
  const extended = bool.fromEnvironment('PLAYBACK_EXTENDED');
  const extraFiles = ['h264-pcm51.mkv', 'av1-aac.mkv'];
  final reports = <Map<String, Object?>>[];
  setUpAll(() async {
    if (Platform.isAndroid && folder.isNotEmpty) {
      await Directory(folder).create(recursive: true);
      const base = String.fromEnvironment('PLAYBACK_FIXTURE_URL');
      if (base.isEmpty) {
        throw StateError('Android requires explicit local fixture URL');
      }
      final client = HttpClient();
      try {
        for (final file in [
          'h264-8-1080.mkv',
          'h264-hi10-1080.mkv',
          'hevc-main10-1080.mkv',
          'hevc-main10-4k.mkv',
          'hevc-main10-4k-hdr.mkv',
          'h264-aac.mkv',
          'hevc-multi-font.mkv',
          'probe.ass',
          if (extended) ...extraFiles,
        ]) {
          final response = await (await client.getUrl(
            Uri.parse('$base/$file'),
          )).close();
          if (response.statusCode != 200) {
            throw StateError('Fixture download failed: $file');
          }
          await response.pipe(File('$folder/$file').openWrite());
        }
      } finally {
        client.close(force: true);
      }
    }
  });
  Future<void> until(Future<bool> Function() check) async {
    final end = DateTime.now().add(const Duration(seconds: 25));
    while (DateTime.now().isBefore(end)) {
      if (await check()) return;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    throw StateError('Playback condition timed out');
  }

  for (final file in [
    'h264-8-1080.mkv',
    'h264-aac.mkv',
    'hevc-multi-font.mkv',
    'h264-hi10-1080.mkv',
    'hevc-main10-1080.mkv',
    'hevc-main10-4k.mkv',
    'hevc-main10-4k-hdr.mkv',
    if (extended) ...extraFiles,
  ]) {
    for (final mode in ['no', 'auto']) {
      testWidgets(
        '$file decode=$mode with actual Flutter video texture',
        (tester) async {
          MediaKit.ensureInitialized(libmpv: dll.isEmpty ? null : dll);
          final player = Player();
          final controller = VideoController(
            player,
            configuration: VideoControllerConfiguration(hwdec: mode),
          );
          final errors = <String>[];
          final sub = player.stream.error.listen(errors.add);
          try {
            await tester.pumpWidget(
              MaterialApp(
                home: Scaffold(
                  body: Video(
                    controller: controller,
                    controls: NoVideoControls,
                  ),
                ),
              ),
            );
            await tester.pump();
            await controller.platform.future.timeout(
              const Duration(seconds: 25),
            );
            await player.open(Media('$folder/$file'));
            await until(() async {
              await tester.pump(const Duration(milliseconds: 50));
              return player.state.position.inMilliseconds >= 500 &&
                  controller.rect.value != null &&
                  (await (player.platform as NativePlayer).getProperty(
                    'video-params/w',
                  )).isNotEmpty;
            });
            if (extended && Platform.isAndroid) {
              // /proc/self/stat fields 14/15 give user/system CPU ticks.
              Future<int> cpuTicks() async {
                final stat = await File('/proc/self/stat').readAsString();
                final fields = stat
                    .substring(stat.lastIndexOf(')') + 2)
                    .split(' ');
                return int.parse(fields[11]) + int.parse(fields[12]);
              }

              final start = await cpuTicks();
              final elapsed = Stopwatch()..start();
              await Future<void>.delayed(const Duration(milliseconds: 1200));
              final ticks = await cpuTicks() - start;
              debugPrint(
                'PLAYBACK_CPU $file $mode ticks=$ticks ms=${elapsed.elapsedMilliseconds}',
              );
            }
            await player.pause();
            await controller.waitUntilFirstFrameRendered.timeout(
              const Duration(seconds: 10),
            );
            final native = player.platform as NativePlayer;
            final stats = await PlaybackProbe(
              native.getProperty,
              textureResolution: () {
                final r = controller.rect.value;
                return r == null ? null : '${r.width}x${r.height}';
              },
            ).statistics();
            expect(
              stats['audio-codec-name'],
              file.endsWith('-aac.mkv')
                  ? 'aac'
                  : file == 'h264-pcm51.mkv'
                  ? 'pcm_s16le'
                  : 'flac',
            );
            debugPrint('PROBE_STATS ${jsonEncode(stats)}');
            expect(
              int.tryParse(stats['video-params/w'] ?? ''),
              file.contains('4k') ? 3840 : 1920,
            );
            if (mode == 'no') {
              expect(
                stats['decoded-component-depth'],
                file.startsWith('h264-8') ||
                        file == 'h264-aac.mkv' ||
                        extraFiles.contains(file)
                    ? '8'
                    : '10',
              );
            }
            expect(stats['current-vo'], Platform.isAndroid ? 'gpu' : 'libmpv');
            if (mode == 'no') {
              expect(stats['hwdec'], 'no');
            } else {
              expect(
                stats['hwdec'],
                isIn(
                  Platform.isAndroid ? ['auto', 'auto-safe', 'no'] : ['auto'],
                ),
              );
            }
            final image = await player.screenshot(format: 'image/png');
            expect(image, isNotNull);
            expect(image!.length, greaterThan(1000));
            await player.seek(const Duration(seconds: 2));
            await until(() async {
              final p = double.tryParse(await native.getProperty('time-pos'));
              return p != null && (p - 2).abs() < .3;
            });
            final seekFrame = await player.screenshot(format: 'image/png');
            expect(seekFrame, isNotNull);
            await player.play();
            await until(
              () async => player.state.position.inMilliseconds > 2300,
            );
            await player.pause();
            final result = <String, Object?>{
              'file': file,
              'requested': mode,
              'stats': stats,
              'rss_with_player_bytes': ProcessInfo.currentRss,
              'screenshot_bytes': image.length,
              'errors': errors,
            };
            reports.add(result);
            debugPrint('PLAYBACK_RESULT ${jsonEncode(result)}');
            if (file == 'h264-8-1080.mkv' && mode == 'no') {
              await File(
                '$folder/${Platform.operatingSystem}-software-reference.png',
              ).writeAsBytes(image);
            }
          } finally {
            await sub.cancel();
            await player.dispose();
            await tester.pumpWidget(const SizedBox());
            debugPrint(
              'PLAYBACK_DISPOSED $file $mode rss_bytes=${ProcessInfo.currentRss}',
            );
          }
        },
        skip: folder.isEmpty,
        timeout: const Timeout(Duration(seconds: 90)),
      );
    }
  }
  for (final requested in ['no', 'ccplayer-nonexistent-decoder']) {
    testWidgets(
      'custom configuration reads hwdec=$requested without initialization deadlock',
      (tester) async {
        MediaKit.ensureInitialized(libmpv: dll.isEmpty ? null : dll);
        final dir = await Directory.systemTemp.createTemp(
          'ccplayer-custom-playback-',
        );
        await File(
          '${dir.path}/mpv.conf',
        ).writeAsString('hwdec=$requested\ncorrect-downscaling=yes\n');
        await File('${dir.path}/input.conf').writeAsString('');
        final player = Player(
          configuration: PlayerConfiguration(
            mpvConfigurationDirectory: dir.path,
            mpvRespectRenderingConfiguration: true,
          ),
        );
        final controller = VideoController(player);
        try {
          await tester.pumpWidget(
            MaterialApp(
              home: Video(controller: controller, controls: NoVideoControls),
            ),
          );
          await tester.pump();
          await controller.platform.future.timeout(const Duration(seconds: 25));
          await player.open(Media('$folder/h264-8-1080.mkv'));
          await until(() async {
            await tester.pump(const Duration(milliseconds: 50));
            return player.state.position.inMilliseconds > 500 &&
                (await (player.platform as NativePlayer).getProperty(
                  'video-params/w',
                )).isNotEmpty;
          });
          await controller.waitUntilFirstFrameRendered.timeout(
            const Duration(seconds: 10),
          );
          final native = player.platform as NativePlayer;
          expect(await native.getProperty('correct-downscaling'), 'yes');
          expect(await native.getProperty('hwdec-current'), 'no');
          expect(await player.screenshot(format: 'image/png'), isNotNull);
          debugPrint(
            'CUSTOM_PLAYBACK requested=$requested configured=${await native.getProperty('hwdec')} actual=${await native.getProperty('hwdec-current')}',
          );
        } finally {
          await player.dispose();
          await tester.pumpWidget(const SizedBox());
          await dir.delete(recursive: true);
        }
      },
      skip: folder.isEmpty,
      timeout: const Timeout(Duration(seconds: 60)),
    );
  }
  testWidgets(
    'native libass capability renders Chinese ASS into captured frame (opt-in harness)',
    (tester) async {
      MediaKit.ensureInitialized(libmpv: dll.isEmpty ? null : dll);
      final player = Player(
        configuration: const PlayerConfiguration(libass: true),
      );
      final controller = VideoController(
        player,
        configuration: const VideoControllerConfiguration(hwdec: 'no'),
      );
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: Video(controller: controller, controls: NoVideoControls),
          ),
        );
        await tester.pump();
        await controller.platform.future.timeout(const Duration(seconds: 25));
        await player.open(
          Media(
            '$folder/${Platform.isAndroid ? 'hevc-multi-font.mkv' : 'h264-8-1080.mkv'}',
          ),
        );
        await until(() async {
          await tester.pump(const Duration(milliseconds: 50));
          return player.state.position.inMilliseconds > 500 &&
              (await (player.platform as NativePlayer).getProperty(
                'video-params/w',
              )).isNotEmpty;
        });
        await player.pause();
        await player.setSubtitleTrack(
          Platform.isAndroid
              ? const SubtitleTrack('1', null, null)
              : SubtitleTrack.uri('$folder/probe.ass'),
        );
        final native = player.platform as NativePlayer;
        await until(
          () async =>
              (await native.getProperty('sub-text')).contains('ASS Test'),
        );
        final clean = await player.screenshot(format: 'image/png');
        final subtitled = await player.screenshot(
          format: 'image/png',
          includeLibassSubtitles: true,
        );
        expect(clean, isNotNull);
        expect(subtitled, isNotNull);
        expect(subtitled, isNot(orderedEquals(clean!)));
        await File(
          '$folder/${Platform.operatingSystem}-native-ass.png',
        ).writeAsBytes(subtitled!);
        debugPrint(
          'ASS_CAPABILITY sub-text=${await native.getProperty('sub-text')}',
        );
      } finally {
        await player.dispose();
        await tester.pumpWidget(const SizedBox());
      }
    },
    skip: folder.isEmpty,
    timeout: const Timeout(Duration(seconds: 60)),
  );
  testWidgets(
    'HTTP Range playback through the production relay seeks and releases connections',
    (tester) async {
      MediaKit.ensureInitialized(libmpv: dll.isEmpty ? null : dll);
      final bytes = await File('$folder/h264-8-1080.mkv').readAsBytes();
      var requests = 0;
      final ranges = <String>[];
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      origin.listen((r) async {
        try {
          requests++;
          var first = 0, last = bytes.length - 1;
          final range = r.headers.value('range');
          if (range != null) ranges.add(range);
          if (range != null) {
            final m = RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(range)!;
            first = int.parse(m[1]!);
            if (m[2]!.isNotEmpty) last = int.parse(m[2]!);
            r.response.statusCode = 206;
            r.response.headers.set(
              'content-range',
              'bytes $first-$last/${bytes.length}',
            );
          }
          r.response.contentLength = last - first + 1;
          r.response.add(bytes.sublist(first, last + 1));
          await r.response.close();
        } catch (_) {
          try {
            await r.response.close();
          } catch (_) {}
        }
      });
      final relay = WebDavStream(
        target: Uri.parse('http://127.0.0.1:${origin.port}/video'),
      );
      final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      proxy.listen(relay.serve);
      final player = Player(
        configuration: const PlayerConfiguration(bufferSize: 64 * 1024),
      );
      final controller = VideoController(
        player,
        configuration: const VideoControllerConfiguration(hwdec: 'no'),
      );
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: Video(controller: controller, controls: NoVideoControls),
          ),
        );
        await tester.pump();
        await controller.platform.future.timeout(const Duration(seconds: 25));
        await player.open(Media('http://127.0.0.1:${proxy.port}/video'));
        await until(() async {
          await tester.pump(const Duration(milliseconds: 50));
          return player.state.position.inMilliseconds > 500 &&
              (await (player.platform as NativePlayer).getProperty(
                'video-params/w',
              )).isNotEmpty;
        });
        await player.pause();
        await player.seek(const Duration(seconds: 2));
        final native = player.platform as NativePlayer;
        await until(
          () async =>
              (double.tryParse(await native.getProperty('time-pos')) ?? 0) >
              1.7,
        );
        expect(await player.screenshot(format: 'image/png'), isNotNull);
        expect(requests, greaterThan(0));
        debugPrint('NETWORK_PLAYBACK requests=$requests');
        debugPrint('NETWORK_RANGES ${jsonEncode(ranges)}');
      } finally {
        relay.close();
        await player.dispose();
        await proxy.close(force: true);
        await origin.close(force: true);
        await tester.pumpWidget(const SizedBox());
      }
    },
    skip: folder.isEmpty,
    timeout: const Timeout(Duration(seconds: 90)),
  );
  tearDownAll(() async {
    if (folder.isNotEmpty) {
      await File(
        '$folder/playback-results.json',
      ).writeAsString(const JsonEncoder.withIndent('  ').convert(reports));
    }
  });
}
