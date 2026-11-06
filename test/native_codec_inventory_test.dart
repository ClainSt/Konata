// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

String cString(Pointer<Uint8> pointer) {
  final bytes = <int>[];
  for (var i = 0; i < 131072; i++) {
    final b = pointer[i];
    if (b == 0) return utf8.decode(bytes, allowMalformed: true);
    bytes.add(b);
  }
  throw const FormatException('Native string exceeds bound');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final dll = Platform.environment['CCPLAYER_TEST_MPV'];
  final output =
      Platform.environment['CCPLAYER_CODEC_REPORT'] ??
      const String.fromEnvironment('BDRIP_CODEC_REPORT');
  const deviceRun = bool.fromEnvironment('BDRIP_NATIVE_INVENTORY');
  test(
    'query actual libmpv decoder inventory and linked build metadata',
    () async {
      MediaKit.ensureInitialized(libmpv: dll);
      final player = Player();
      try {
        final native = player.platform as NativePlayer;
        final properties = <String, String>{};
        for (final key in [
          'mpv-version',
          'mpv-configuration',
          'ffmpeg-version',
          'libass-version',
          'libplacebo-version',
          'platform',
          'protocol-list',
          'hwdec',
          'vo',
        ]) {
          properties[key] = await native.getProperty(key);
        }
        final count = int.parse(await native.getProperty('decoder-list/count'));
        final decoders = <Map<String, String>>[];
        for (var i = 0; i < count; i++) {
          decoders.add({
            for (final key in ['codec', 'driver', 'description'])
              key: await native.getProperty('decoder-list/$i/$key'),
          });
        }
        final exports = <String, String>{};
        final library = DynamicLibrary.open(dll ?? 'libmpv.so');
        for (final name in [
          'avcodec_configuration',
          'avformat_configuration',
          'avutil_configuration',
          'swscale_configuration',
        ]) {
          try {
            final get = library
                .lookupFunction<
                  Pointer<Uint8> Function(),
                  Pointer<Uint8> Function()
                >(name);
            exports[name] = cString(get());
          } catch (_) {
            exports[name] = 'not exported by this DLL';
          }
        }
        final result = {
          'platform': Platform.operatingSystem,
          'engine_sha256_note': 'See paired external hash report',
          'properties': properties,
          'decoder_count': count,
          'decoders': decoders,
          'ffmpeg_exports': exports,
          'limitations':
              'decoder-list is vd/ad capability, not proof of usable hardware or complete subtitle support. libass rendering tested separately.',
        };
        for (final line in const JsonEncoder.withIndent(
          '  ',
        ).convert(result).split('\n')) {
          print('INV_JSON $line');
        }
        if (output.isNotEmpty) {
          await File(
            output,
          ).writeAsString(const JsonEncoder.withIndent('  ').convert(result));
        }
        expect(decoders.any((d) => d['codec'] == 'h264'), isTrue);
        expect(decoders.any((d) => d['codec'] == 'hevc'), isTrue);
        expect(decoders.any((d) => d['codec'] == 'flac'), isTrue);
        expect(decoders.any((d) => d['codec'] == 'aac'), isTrue);
        // Only runtime observations are printed, not a host ffmpeg's feature list.
        print(
          'NATIVE_INVENTORY ${jsonEncode({'count': count, 'properties': properties, 'exports': exports})}',
        );
      } finally {
        await player.dispose();
      }
    },
    skip: dll == null && !deviceRun,
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
