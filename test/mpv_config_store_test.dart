import 'dart:io';

import 'package:ccplayer/core/mpv_config_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late MpvConfigStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('ccplayer-mpv-test-');
    store = MpvConfigStore(rootOverride: directory);
  });
  tearDown(() async => directory.delete(recursive: true));

  test(
    'legacy subtitle preferences still use native ASS on supported platforms',
    () async {
      SharedPreferences.setMockInitialValues({
        'mpv_native_ass_android': false,
        'mpv_native_ass_windows': false,
        'android_webdav_long_recovery': true,
      });
      await store.initialize();
      expect(
        store.playerConfiguration.libass,
        Platform.isWindows || Platform.isAndroid,
      );
      expect(store.enabled, isFalse);
    },
  );

  test('custom config opts in without altering the default profile', () async {
    await store.initialize();
    expect(store.enabled, isFalse);
    expect(store.playerConfiguration.mpvConfigurationDirectory, isNull);
    expect(await store.readConfig('mpv.conf'), contains('Empty by default'));
    await store.setConfigEnabled(true);
    expect(store.playerConfiguration.mpvConfigurationDirectory, directory.path);
    await store.setConfigEnabled(false);
    expect(store.playerConfiguration.mpvConfigurationDirectory, isNull);
  });

  test('editor saves LF text and keeps backup for rollback', () async {
    await store.initialize();
    final before = await store.readConfig('mpv.conf');
    await store.saveConfig('mpv.conf', 'hwdec=auto\r\nscale=spline36');
    expect(await store.readConfig('mpv.conf'), 'hwdec=auto\nscale=spline36');
    expect(
      await File(p.join(directory.path, 'mpv.conf.bak')).readAsString(),
      before,
    );
    await store.restoreConfig('mpv.conf');
    expect(await store.readConfig('mpv.conf'), contains('reset configuration'));
    expect(
      await File(p.join(directory.path, 'mpv.conf.bak')).readAsString(),
      'hwdec=auto\nscale=spline36',
    );
    await expectLater(
      store.saveConfig('../evil.conf', 'bad'),
      throwsA(isA<FormatException>()),
    );
    await expectLater(
      store.saveConfig('input.conf', 'X' * (MpvConfigStore.maxConfigBytes + 1)),
      throwsA(isA<FormatException>()),
    );
  });

  test(
    'selected folder is read again for every player and original files survive',
    () async {
      final source = await Directory(
        p.join(directory.path, 'external'),
      ).create();
      final conf = File(p.join(source.path, 'mpv.conf'));
      final input = File(p.join(source.path, 'input.conf'));
      await conf.writeAsString('volume=50');
      await File(p.join(source.path, 'keep.lua')).writeAsString('user file');
      await store.selectFolder(source.path);
      await store.setConfigEnabled(true);
      final reopened = MpvConfigStore(rootOverride: directory);
      await reopened.initialize();
      expect(reopened.externalFolder, source.path);
      final first = await reopened.snapshot(source.path);
      expect(await File(p.join(first.path, 'input.conf')).length(), 0);
      await conf.writeAsString('volume=75');
      await input.writeAsString('F1 cycle mute');
      final second = await reopened.snapshot(source.path);
      expect(
        await File(p.join(first.path, 'mpv.conf')).readAsString(),
        'volume=50',
      );
      expect(
        await File(p.join(second.path, 'mpv.conf')).readAsString(),
        'volume=75',
      );
      expect(
        await File(p.join(second.path, 'input.conf')).readAsString(),
        'F1 cycle mute',
      );
      expect(await second.list().length, 2);
      await conf.writeAsBytes([255]);
      await expectLater(reopened.snapshot(source.path), throwsFormatException);
      await conf.writeAsString('x' * (MpvConfigStore.maxConfigBytes + 1));
      await expectLater(reopened.snapshot(source.path), throwsFormatException);
      await expectLater(
        reopened.selectFolder(p.join(source.path, 'missing')),
        throwsA(isA<FileSystemException>()),
      );
      expect(reopened.externalFolder, source.path);
      await reopened.selectFolder(null);
      expect(
        reopened.playerConfiguration.mpvConfigurationDirectory,
        directory.path,
      );
      expect(
        await File(p.join(source.path, 'keep.lua')).readAsString(),
        'user file',
      );
    },
  );
}
