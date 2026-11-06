import 'dart:io';

import 'package:ccplayer/core/mpv_engine_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// Set CCPLAYER_TEST_MPV_ARCHIVE to the official pinned 20261105 .7z file.
/// This test extracts into a temporary directory and never touches the app.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final archive = Platform.environment['CCPLAYER_TEST_MPV_ARCHIVE'];

  test('verified upstream release extracts the exact pinned enhanced engine', () async {
    final root = await Directory.systemTemp.createTemp('ccplayer-mpv-install-');
    try {
      final engine = MpvEngineStore(rootOverride: root);
      await engine.installFromArchive(File(archive!));
      expect(await engine.isInstalledAndValid(), isTrue);
      final dll = await engine.libraryFile;
      expect(await dll.length(), 121911296);
      expect(engine.enabled, isFalse);
    } finally {
      await root.delete(recursive: true);
    }
  }, skip: archive == null || !Platform.isWindows,
      timeout: const Timeout(Duration(minutes: 2)));
}
