import 'dart:io';
import 'package:ccplayer/core/mpv_config_store.dart';
import 'package:media_kit_video/src/utils/decode_policy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'legacy decoder choices migrate to automatic without altering MPV files',
    () async {
      for (final legacy in [
        'automatic',
        'hardwarePreferred',
        'software',
        'custom',
      ]) {
        SharedPreferences.setMockInitialValues({'video_decode_mode': legacy});
        final dir = await Directory.systemTemp.createTemp(
          'ccplayer-auto-decode-',
        );
        try {
          final store = MpvConfigStore(rootOverride: dir);
          await store.initialize();
          expect(store.videoConfiguration.hwdec, isNull);
          expect(store.videoConfiguration.enableHardwareAcceleration, isTrue);
          expect(
            (await SharedPreferences.getInstance()).containsKey(
              'video_decode_mode',
            ),
            isFalse,
          );
          expect(
            store.playerConfiguration.mpvRespectRenderingConfiguration,
            isFalse,
          );
          await store.saveConfig('mpv.conf', 'hwdec=no\nscale=lanczos\n');
          await store.setConfigEnabled(true);
          final snapshot = await store.snapshot(dir.path);
          final text = await File('${snapshot.path}/mpv.conf').readAsString();
          expect(
            text,
            contains('hwdec=${Platform.isAndroid ? 'auto-safe' : 'auto'}\n'),
          );
          expect(text, endsWith('hwdec=no\nscale=lanczos\n'));
          expect(
            await store.readConfig('mpv.conf'),
            'hwdec=no\nscale=lanczos\n',
          );
          expect(
            store.configurationFor(snapshot).mpvRespectRenderingConfiguration,
            isTrue,
          );
        } finally {
          await dir.delete(recursive: true);
        }
      }
    },
  );
  test(
    'emulator is software; explicit mode overrides config and custom reads it',
    () async {
      Future<String> choose({
        String? requested,
        bool emulator = false,
        bool custom = false,
      }) => resolveHwdec(
        fallback: 'auto-safe',
        emulator: emulator,
        requested: requested,
        respectConfig: custom,
        readConfig: () async => 'no',
      );
      expect(await choose(), 'auto-safe');
      expect(await choose(custom: true), 'no');
      expect(await choose(requested: 'auto', custom: true), 'auto');
      expect(await choose(requested: 'auto', emulator: true), 'no');
    },
  );
  test(
    'silent setter rejection and thrown errors recover with verified software',
    () async {
      var actual = 'auto';
      final writes = <String>[];
      final fallback = await applyHwdec('bad', (v) async {
        writes.add(v);
        if (v != 'bad') actual = v;
      }, read: () async => actual);
      expect(fallback, isTrue);
      expect(actual, 'no');
      expect(writes, ['bad', 'no']);
      expect(
        await applyHwdec('auto-safe', (v) async {
          actual = 'auto';
        }, read: () async => actual),
        isFalse,
      );
      expect(
        await applyHwdec('bad', (v) async {
          if (v == 'bad') throw StateError('bad');
          actual = v;
        }, read: () async => actual),
        isTrue,
      );
      await expectLater(
        applyHwdec('bad', (_) async {}, read: () async => 'invalid'),
        throwsStateError,
      );
    },
  );
}
