import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;

/// Optional Windows-native integration tests; these do not open any media.
/// CCPLAYER_TEST_MPV must point to a local libmpv-2.dll.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final dll = Platform.environment['CCPLAYER_TEST_MPV'];

  test(
    'native mpv loads mpv.conf and executes input.conf key binding',
    () async {
      MediaKit.ensureInitialized(libmpv: dll);
      final dir = await Directory.systemTemp.createTemp('ccplayer-mpv-native-');
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
    skip: dll == null,
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
