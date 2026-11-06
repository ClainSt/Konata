// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final dll = Platform.environment['CCPLAYER_TEST_MPV'];
  final folder = Platform.environment['CCPLAYER_AUDIO_FIXTURES'];
  test(
    'actual native TrueHD capability and explicit AAC fallback',
    () async {
      MediaKit.ensureInitialized(libmpv: dll);
      final dir = await Directory.systemTemp.createTemp('bdrip-audio-');
      await File('${dir.path}/mpv.conf').writeAsString('ao=null\nvid=no\n');
      await File('${dir.path}/input.conf').writeAsString('');
      final p = Player(
        configuration: PlayerConfiguration(mpvConfigurationDirectory: dir.path),
      );
      final errors = <String>[];
      final subscription = p.stream.error.listen(errors.add);
      try {
        final n = p.platform as NativePlayer;
        final count = int.parse(await n.getProperty('decoder-list/count'));
        var hasTrueHd = false;
        for (var i = 0; i < count; i++) {
          if (await n.getProperty('decoder-list/$i/codec') == 'truehd') {
            hasTrueHd = true;
          }
        }
        await p.open(Media('$folder/hevc-truehd-aac.mkv'));
        await Future<void>.delayed(const Duration(milliseconds: 900));
        final first = await n.getProperty('audio-codec-name');
        final initialChannels = await n.getProperty(
          'audio-params/channel-count',
        );
        if (hasTrueHd) {
          expect(first, 'truehd');
          expect(initialChannels, '6');
        } else {
          expect(first, isNot('truehd'));
        }
        await n.setProperty('aid', '2');
        await p.open(Media('$folder/hevc-truehd-aac.mkv'));
        await p.play();
        final deadline = DateTime.now().add(const Duration(seconds: 8));
        while (await n.getProperty('audio-codec-name') != 'aac' &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        expect(await n.getProperty('audio-codec-name'), 'aac');
        print(
          'AUDIO_NATIVE ${jsonEncode({'mpv': await n.getProperty('mpv-version'), 'truehd_decoder': hasTrueHd, 'initial_codec': first, 'initial_channels': initialChannels, 'fallback_codec': await n.getProperty('audio-codec-name'), 'fallback_channels': await n.getProperty('audio-params/channel-count'), 'errors': errors, 'ao': 'null; decoder validation only, no audible channel validation'})}',
        );
      } finally {
        await subscription.cancel();
        await p.dispose();
        await dir.delete(recursive: true);
      }
    },
    skip: dll == null || folder == null,
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
