import 'dart:convert';
import 'dart:io';
import 'package:ccplayer/core/mpv_config_store.dart';
import 'package:ccplayer/core/subtitle_system_fonts.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Android external ASS selects installed CJK font and renders styles',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      MediaKit.ensureInitialized();
      final root = await Directory.systemTemp.createTemp('ccplayer-ass-');
      final store = MpvConfigStore(rootOverride: root);
      await store.initialize();
      expect(store.playerConfiguration.libass, isTrue);
      final player = Player(
        configuration: PlayerConfiguration(
          libass: store.playerConfiguration.libass,
          logLevel: MPVLogLevel.v,
        ),
      );
      final controller = VideoController(
        player,
        configuration: const VideoControllerConfiguration(hwdec: 'no'),
      );
      final logs = <String>[];
      final subscription = player.stream.log.listen((log) {
        logs.add(log.text);
      });
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: Video(controller: controller, controls: NoVideoControls),
          ),
        );
        await tester.pump();
        await controller.platform.future.timeout(const Duration(seconds: 25));
        final native = player.platform as NativePlayer;
        expect(await native.getProperty('sub-fonts-dir'), isEmpty);
        await configureAndroidSubtitleFonts(native.setProperty, cache: root);
        final client = HttpClient();
        final subtitle = File('${root.path}/external.ass');
        try {
          final response = await (await client.getUrl(
            Uri.parse('http://127.0.0.1:18765/probe.ass'),
          )).close();
          await subtitle.writeAsString(
            await response.transform(utf8.decoder).join(),
          );
        } finally {
          client.close(force: true);
        }
        await player.open(Media('http://127.0.0.1:18765/h264-8-1080.mkv'));
        await player.setSubtitleTrack(SubtitleTrack.uri(subtitle.path));
        for (
          var i = 0;
          i < 100 && player.state.position.inMilliseconds < 1000;
          i++
        ) {
          await tester.pump(const Duration(milliseconds: 50));
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        expect(player.state.position.inMilliseconds, greaterThan(500));
        await player.pause();
        expect(await native.getProperty('sub-ass'), 'yes');
        expect(await native.getProperty('sub-text'), contains('ASS Test'));
        final clean = await player.screenshot(format: 'image/png');
        final styled = await player.screenshot(
          format: 'image/png',
          includeLibassSubtitles: true,
        );
        expect(styled, isNotNull);
        expect(styled, isNot(orderedEquals(clean!)));
        final expectedFamily = await File('/system/fonts/MiSansVF.ttf').exists()
            ? 'MiSansVF'
            : 'NotoSansCJK';
        expect(
          logs.any(
            (line) =>
                line.contains('fontselect:') && line.contains(expectedFamily),
          ),
          isTrue,
          reason: logs.where((line) => line.contains('font')).join('\n'),
        );
        debugPrint(
          'ANDROID_SYSTEM_ASS ${logs.where((line) => line.contains('fontselect:')).join('\n')}',
        );
        final output = await getExternalStorageDirectory();
        final screenshot = File('${output!.path}/system-ass.png');
        await screenshot.parent.create(recursive: true);
        await screenshot.writeAsBytes(styled!);
        debugPrint('ANDROID_SYSTEM_ASS_SCREENSHOT ${screenshot.path}');
      } finally {
        await subscription.cancel();
        await player.dispose();
        await tester.pumpWidget(const SizedBox());
        await root.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );
}
