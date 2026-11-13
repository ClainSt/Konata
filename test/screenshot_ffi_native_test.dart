import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final library = Platform.environment['CCPLAYER_TEST_MPV'];
  test(
    'native screenshot keeps formats and both argv modes across repeated players',
    () async {
      MediaKit.ensureInitialized(libmpv: library);
      final root = await Directory.systemTemp.createTemp(
        'konata-screenshot-ffi-',
      );
      try {
        // Self-contained PPM; no user media, downloads, encoders or new packages.
        final input = await File('${root.path}/frame.ppm').writeAsBytes([
          ...'P6\n32 16\n255\n'.codeUnits,
          for (var i = 0; i < 32 * 16; i++) ...[10, 20, 30],
        ]);
        for (var cycle = 0; cycle < 2; cycle++) {
          final player = Player(
            configuration: const PlayerConfiguration(vo: 'null'),
          );
          try {
            final native = player.platform as NativePlayer;
            await native.setProperty('vid', 'auto');
            await native.setProperty('aid', 'no');
            await player.open(Media(input.path), play: false);
            var ready = false;
            for (var attempt = 0; attempt < 100; attempt++) {
              if (await native.getProperty('video-params/w') == '32') {
                ready = true;
                break;
              }
              await Future<void>.delayed(const Duration(milliseconds: 50));
            }
            expect(
              ready,
              isTrue,
              reason: 'Synthetic frame must actually decode',
            );
            for (final subtitles in [false, true]) {
              final png = (await player.screenshot(
                format: 'image/png',
                includeLibassSubtitles: subtitles,
              ))!;
              expect(png.take(8), [137, 80, 78, 71, 13, 10, 26, 10]);
              final header = ByteData.sublistView(png);
              expect(header.getUint32(16), 32);
              expect(header.getUint32(20), 16);
              final jpeg = (await player.screenshot(
                includeLibassSubtitles: subtitles,
              ))!;
              expect(jpeg.take(2), [255, 216]);
              expect(jpeg.sublist(jpeg.length - 2), [255, 217]);
              final raw = (await player.screenshot(
                format: null,
                includeLibassSubtitles: subtitles,
              ))!;
              expect(raw.length, greaterThanOrEqualTo(32 * 16 * 4));
              expect(raw.take(3), [30, 20, 10]);
            }
            await expectLater(
              player.screenshot(format: 'unsupported'),
              throwsArgumentError,
            );
          } finally {
            await player.dispose();
          }
          await expectLater(
            player.screenshot(),
            throwsA(isA<AssertionError>()),
          );
        }
        // The existing NativePlayer destructor is scheduled five seconds later.
        await Future<void>.delayed(const Duration(seconds: 6));
      } finally {
        await root.delete(recursive: true);
      }
    },
    skip: library == null
        ? 'Set CCPLAYER_TEST_MPV to an existing native library'
        : false,
    timeout: const Timeout(Duration(seconds: 45)),
  );
}
