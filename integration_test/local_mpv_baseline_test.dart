import 'dart:convert';
import 'dart:io';
import 'dart:ffi';
// Test-only access to the same FFI allocator used by media_kit's mpv bindings.
// ignore: depend_on_referenced_packages
import 'package:ffi/ffi.dart';
import 'package:media_kit/generated/libmpv/bindings.dart' as api;

import 'package:ccplayer/core/catalog.dart';
import 'package:ccplayer/core/mpv_config_store.dart';
import 'package:ccplayer/core/playback_probe.dart';
import 'package:ccplayer/l10n/app_localizations.dart';
import 'package:ccplayer/ui/watch_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path/path.dart' as p;
import 'package:window_manager/window_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'local_decoder_trials.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const video = String.fromEnvironment('BASELINE_VIDEO');
  testWidgets('sample effective local WatchPage playback configuration', (
    tester,
  ) async {
    if (const bool.fromEnvironment('BASELINE_HOST_INPUTS')) {
      final previous = binding.shouldPropagateDevicePointerEvents;
      binding.shouldPropagateDevicePointerEvents = true;
      addTearDown(() => binding.shouldPropagateDevicePointerEvents = previous);
    }
    MediaKit.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    final root = await Directory.systemTemp.createTemp('ccplayer-baseline-');
    final catalog = Catalog.instance;
    await catalog.initialize(dataDirectory: root);
    try {
      const transfer = String.fromEnvironment('BASELINE_STAGE_URL');
      final staged = transfer.isEmpty
          ? File(video)
          : File(p.join(root.path, p.basename(video)));
      if (transfer.isNotEmpty) {
        final client = HttpClient();
        try {
          final response = await (await client.getUrl(
            Uri.parse(transfer),
          )).close();
          expect(response.statusCode, 200);
          await response.pipe(staged.openWrite());
        } finally {
          client.close(force: true);
        }
      }
      if (!await staged.exists()) {
        throw StateError('Missing local baseline fixture: ${staged.path}');
      }
      final source = await catalog.addSource(
        'local',
        'baseline',
        staged.parent.path,
      );
      final asset = {
        'id': 'baseline',
        'work_id': 'baseline',
        'name': p.basename(video),
        'relative_path': p.basename(video),
        'source_id': source,
        'category': 'main',
      };
      await catalog.db.insert('works', {'id': 'baseline', 'title': 'baseline'});
      await catalog.db.insert('assets', asset);
      final store = MpvConfigStore(
        rootOverride: Directory(p.join(root.path, 'mpv')),
      );
      await store.initialize();
      const decodeMode = String.fromEnvironment('BASELINE_DECODE_MODE');
      if (decodeMode.isNotEmpty) {
        await store.setDecodeMode(VideoDecodeMode.values.byName(decodeMode));
      }
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: WatchPage(asset: asset, configurationStore: store),
        ),
      );
      final dynamic page = tester.state(find.byType(WatchPage));
      final player = page.player as Player;
      final nativeWarnings = <String>[];
      final warningSubscription = player.stream.log.listen((entry) {
        if (nativeWarnings.length < 20 &&
            ['warn', 'error', 'fatal'].contains(entry.level)) {
          nativeWarnings.add('${entry.prefix}: ${entry.text}');
        }
      });
      addTearDown(warningSubscription.cancel);
      await player.setVolume(
        const int.fromEnvironment(
          'BASELINE_VOLUME',
          defaultValue: 0,
        ).toDouble(),
      );
      if (Platform.isWindows) {
        await windowManager.ensureInitialized();
        await windowManager.show();
      }
      await player.setPlaylistMode(PlaylistMode.single);
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (player.state.position.inSeconds < 1 &&
          DateTime.now().isBefore(deadline)) {
        await tester.pump(const Duration(milliseconds: 50));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      if (player.state.position.inSeconds < 1) {
        final native = player.platform as NativePlayer;
        final status = await PlaybackProbe(native.getProperty).statistics();
        for (final key in [
          'pause',
          'core-idle',
          'eof-reached',
          'seeking',
          'aid',
          'vid',
        ]) {
          status[key] = await native.getProperty(key);
        }
        debugPrint('MPV_STARTUP_FAILURE ${jsonEncode(status)}');
        debugPrint('MPV_STARTUP_WARNINGS ${jsonEncode(nativeWarnings)}');
      }
      expect(player.state.position.inSeconds, greaterThanOrEqualTo(1));
      const sampleSeconds = int.fromEnvironment('BASELINE_SAMPLE_SECONDS');
      if (sampleSeconds > 0) {
        final startPosition = player.state.position;
        final watch = Stopwatch()..start();
        while (watch.elapsed.inSeconds < sampleSeconds) {
          await tester.pump(const Duration(milliseconds: 100));
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(
          (player.state.position - startPosition).inMilliseconds,
          greaterThan(sampleSeconds * 900),
          reason: 'Playback must sustain near-real-time progress.',
        );
      }
      await player.pause();
      final native = player.platform as NativePlayer;
      if (const bool.fromEnvironment('BASELINE_ALL_AUDIO')) {
        final audioResults = <Map<String, String>>[];
        for (final track in player.state.tracks.audio.where(
          (track) => track.id != 'auto' && track.id != 'no',
        )) {
          await player.setAudioTrack(track);
          await player.seek(const Duration(seconds: 10));
          await player.play();
          for (var i = 0; i < 50; i++) {
            await tester.pump(const Duration(milliseconds: 100));
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
          final audio = <String, String>{'track': track.id};
          for (final key in [
            'aid',
            'audio-codec-name',
            'audio-params/format',
            'audio-params/samplerate',
            'audio-params/channels',
            'audio-out-params/format',
            'audio-out-params/samplerate',
            'audio-out-params/channels',
            'current-ao',
            'mute',
            'volume',
          ]) {
            audio[key] = await native.getProperty(key);
          }
          expect(audio['aid'], track.id);
          expect(audio['audio-codec-name'], isNotEmpty);
          expect(audio['current-ao'], isNotEmpty);
          expect(audio['current-ao'], isNot('null'));
          expect(
            int.tryParse(audio['audio-out-params/samplerate']!),
            greaterThan(0),
          );
          expect(audio['mute'], 'no');
          expect(player.state.position.inSeconds, greaterThan(12));
          audioResults.add(audio);
        }
        expect(audioResults, isNotEmpty);
        debugPrint('MPV_AUDIO_BASELINE ${jsonEncode(audioResults)}');
        await player.pause();
      }
      if (decodeMode == 'software') {
        expect(await native.getProperty('hwdec'), 'no');
        expect(await native.getProperty('hwdec-current'), 'no');
      }
      if (Platform.isWindows &&
          const bool.fromEnvironment('BASELINE_PAUSED_FULLSCREEN')) {
        // Simulate an input.conf pause without calling Player.pause().
        await player.play();
        await native.command(['set', 'pause', 'yes']);
        await native.command(['seek', '1', 'absolute+exact']);
        final view = tester.state<VideoState>(find.byType(Video));
        await view.enterFullscreen();
        try {
          final size = tester.view.physicalSize;
          final params = player.state.videoParams;
          final width = params.dw!;
          final height = params.dh!;
          // This fixture needs a letterboxed screen to exercise the resize.
          expect(size.height / size.width, greaterThan(height / width));
          final expected = (size.height * (width / size.width).clamp(0, 1))
              .round();
          for (var i = 0; i < 100; i++) {
            await tester.pump(const Duration(milliseconds: 50));
            await Future<void>.delayed(const Duration(milliseconds: 50));
            if (await native.getProperty('osd-height') == '$expected') break;
          }
          expect(await native.getProperty('osd-height'), '$expected');
          expect(await native.getProperty('pause'), 'yes');
          expect(player.state.buffering, isFalse);
        } finally {
          await view.exitFullscreen();
          await tester.pump();
        }
      }
      for (var i = 0; i < 100; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        final width = int.tryParse(await native.getProperty('osd-width')) ?? 0;
        if (width > 100) break;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      const capture = String.fromEnvironment('BASELINE_WINDOW_BGR0');
      if (capture.isNotEmpty) {
        await native.setProperty('osd-level', '0');
        await native.setProperty('sub-visibility', 'no');
        await native.setProperty('screenshot-high-bit-depth', 'no');
        const timestamp = String.fromEnvironment(
          'BASELINE_FRAME_SECONDS',
          defaultValue: '123.957',
        );
        final target = double.parse(timestamp);
        final image = File(capture);
        expect(
          await image.exists(),
          isFalse,
          reason: 'Choose a fresh capture path',
        );
        await native.command(['seek', timestamp, 'absolute+exact']);
        for (var i = 0; i < 100; i++) {
          await tester.pump(const Duration(milliseconds: 50));
          await Future<void>.delayed(const Duration(milliseconds: 50));
          final t = double.tryParse(await native.getProperty('time-pos'));
          if (t != null &&
              (t - target).abs() < 0.05 &&
              await native.getProperty('seeking') == 'no') {
            break;
          }
        }
        final position = double.parse(await native.getProperty('time-pos'));
        expect((position - target).abs(), lessThan(0.05));
        using((arena) {
          final args = arena<Pointer<Int8>>(3);
          args[0] = 'screenshot-raw'.toNativeUtf8(allocator: arena).cast();
          args[1] = 'window'.toNativeUtf8(allocator: arena).cast();
          final result = arena<api.mpv_node>();
          final status = native.mpv.mpv_command_ret(native.ctx, args, result);
          expect(status, 0);
          try {
            expect(result.ref.format, api.mpv_format.MPV_FORMAT_NODE_MAP);
            final map = result.ref.u.list.ref;
            final values = {
              for (int i = 0; i < map.num; i++)
                map.keys[i].cast<Utf8>().toDartString(): map.values[i],
            };
            final width = values['w']!.u.int64;
            final height = values['h']!.u.int64;
            final stride = values['stride']!.u.int64;
            expect(
              values['format']!.u.string.cast<Utf8>().toDartString(),
              'bgr0',
            );
            final data = values['data']!.u.ba.ref;
            expect(stride, greaterThanOrEqualTo(width * 4));
            expect(data.size, stride * height);
            image.writeAsBytesSync(
              data.data.cast<Uint8>().asTypedList(data.size),
            );
            debugPrint(
              'WINDOW_BGR0 width=$width height=$height stride=$stride',
            );
          } finally {
            native.mpv.mpv_free_node_contents(result);
          }
        });
      }
      if (const bool.fromEnvironment('BASELINE_ANDROID_TRIALS')) {
        await androidDecoderTrials(tester, player);
      }
      if (const bool.fromEnvironment('BASELINE_WINDOWS_SCREEN')) {
        await windowsScreenTrial(tester, player);
      }
      final fields = <String, String>{};
      fields.addAll(await PlaybackProbe(native.getProperty).statistics());
      for (final key in [
        'track-list/count',
        'track-list/0/type',
        'track-list/0/selected',
        'track-list/0/format-name',
        'track-list/0/codec-profile',
        'track-list/0/codec',
      ]) {
        fields[key] = await native.getProperty(key);
      }
      for (final key
          in 'mpv-version ffmpeg-version time-pos current-vo hwdec-current video-params/pixelformat video-params/hw-pixelformat video-params/primaries video-params/gamma video-params/colorlevels video-params/w video-params/h osd-width osd-height scale cscale dscale dither dither-depth correct-downscaling linear-downscaling sigmoid-upscaling hdr-compute-peak deband interpolation tone-mapping d3d11-output-format aid sid sub-ass-override embeddedfonts frame-drop-count decoder-frame-drop-count'
              .split(' ')) {
        try {
          fields[key] = await native.getProperty(key);
        } catch (_) {
          fields[key] = 'unavailable';
        }
      }
      expect(int.tryParse(fields['osd-width'] ?? ''), greaterThan(100));
      debugPrint('MPV_LOCAL_BASELINE ${jsonEncode(fields)}');
      if (const bool.fromEnvironment('BASELINE_PRESENTED_GRADIENT')) {
        final presented =
            await page.capturePresentedBuffer() as Map<Object?, Object?>;
        debugPrint('MPV_PRESENTED_BUFFER ${jsonEncode(presented)}');
        expect(presented['format'], 'R10G10B10A2_UNORM');
        for (final key in ['redLevels', 'greenLevels', 'blueLevels']) {
          expect(presented[key], greaterThan(256));
        }
      }
      if (const bool.fromEnvironment('BASELINE_REQUIRE_PRECISION')) {
        // Established by the external ffprobe fixture report, not profile name.
        const sourceDepth = int.fromEnvironment(
          'BASELINE_EXPECT_DECODED_DEPTH',
        );
        final decodedDepth = int.tryParse(
          fields['decoded-component-depth'] ?? '',
        );
        expect(sourceDepth, greaterThan(0));
        expect(decodedDepth, isNotNull);
        expect(decodedDepth, greaterThanOrEqualTo(sourceDepth));
      }
      await tester.pumpWidget(const SizedBox());
      await player.stream.position.drain<void>().timeout(
        const Duration(seconds: 20),
      );
    } finally {
      await catalog.db.close();
      await root.delete(recursive: true);
    }
  }, skip: video.isEmpty);
}
