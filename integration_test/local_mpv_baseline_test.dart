import 'dart:convert';
import 'dart:io';
import 'dart:ffi';
// Test-only access to the same FFI allocator used by media_kit's mpv bindings.
// ignore: depend_on_referenced_packages
import 'package:ffi/ffi.dart';
import 'package:media_kit/generated/libmpv/bindings.dart' as api;

import 'package:ccplayer/core/catalog.dart';
import 'package:ccplayer/core/mpv_config_store.dart';
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
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const video = String.fromEnvironment('BASELINE_VIDEO');
  testWidgets('sample effective local WatchPage playback configuration', (
    tester,
  ) async {
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
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: WatchPage(asset: asset, configurationStore: store),
        ),
      );
      final dynamic page = tester.state(find.byType(WatchPage));
      final player = page.player as Player;
      await player.setVolume(0);
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
      expect(player.state.position.inSeconds, greaterThanOrEqualTo(1));
      await player.pause();
      final native = player.platform as NativePlayer;
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
