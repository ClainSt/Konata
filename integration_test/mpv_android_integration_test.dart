import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;

/// Run on Android API 35 emulator with:
/// flutter test integration_test/mpv_android_integration_test.dart -d emulator-5554
///
/// Validates the installed Android libmpv.so and local native configuration.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Android libmpv reads mpv.conf and handles input.conf bindings',
    (tester) async {
      MediaKit.ensureInitialized();
      final dir = await Directory.systemTemp.createTemp(
        'ccplayer-mpv-android-',
      );
      await File(
        p.join(dir.path, 'mpv.conf'),
      ).writeAsString('sub-font-size=49\n');
      await File(
        p.join(dir.path, 'input.conf'),
      ).writeAsString('z set sub-font-size 57\n');

      final player = Player(
        configuration: PlayerConfiguration(mpvConfigurationDirectory: dir.path),
      );
      try {
        final native = player.platform as NativePlayer;
        expect(num.parse(await native.getProperty('sub-font-size')), 49);
        await native.command(['keypress', 'z']);
        expect(num.parse(await native.getProperty('sub-font-size')), 57);
      } finally {
        await player.dispose();
        await dir.delete(recursive: true);
      }
    },
    skip: !Platform.isAndroid,
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
