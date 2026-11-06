import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/src/utils/decode_policy.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final dll = Platform.environment['CCPLAYER_TEST_MPV'];
  test(
    'explicit custom mode preserves rendering options while legacy defaults stay unchanged',
    () async {
      MediaKit.ensureInitialized(libmpv: dll);
      final dir = await Directory.systemTemp.createTemp(
        'ccplayer-native-render-',
      );
      try {
        await File('${dir.path}/mpv.conf').writeAsString(
          'correct-downscaling=yes\nlinear-downscaling=yes\nsigmoid-upscaling=yes\nhdr-compute-peak=yes\nhwdec=no\nscale=spline36\ndither=fruit\ncache-on-disk=yes\n',
        );
        await File('${dir.path}/input.conf').writeAsString('');
        for (final custom in [false, true]) {
          final player = Player(
            configuration: PlayerConfiguration(
              mpvConfigurationDirectory: dir.path,
              mpvRespectRenderingConfiguration: custom,
            ),
          );
          try {
            final native = player.platform as NativePlayer;
            for (final property in [
              'correct-downscaling',
              'linear-downscaling',
              'sigmoid-upscaling',
              'hdr-compute-peak',
            ]) {
              expect(
                await native.getProperty(property),
                custom ? 'yes' : 'no',
                reason: property,
              );
            }
            expect(await native.getProperty('scale'), 'spline36');
            expect(await native.getProperty('dither'), 'fruit');
            expect(await native.getProperty('hwdec'), 'no');
            expect(await native.getProperty('cache-on-disk'), 'yes');
          } finally {
            await player.dispose();
          }
        }
      } finally {
        await dir.delete(recursive: true);
      }
    },
    skip: dll == null,
    timeout: const Timeout(Duration(seconds: 40)),
  );
  test(
    'actual libmpv accepts unknown API names; runtime fallback needs playback validation',
    () async {
      MediaKit.ensureInitialized(libmpv: dll);
      final player = Player();
      try {
        final native = player.platform as NativePlayer;
        expect(await native.getProperty('cache-on-disk'), 'no');
        expect(await native.getProperty('ccplayer-absent-property'), isEmpty);
        expect(
          await applyHwdec(
            'ccplayer-nonexistent-decoder',
            (v) => native.setProperty('hwdec', v),
            read: () => native.getProperty('hwdec'),
          ),
          isFalse,
        );
        expect(
          await native.getProperty('hwdec'),
          'ccplayer-nonexistent-decoder',
        );
      } finally {
        await player.dispose();
      }
    },
    skip: dll == null,
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
