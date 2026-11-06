// ignore_for_file: avoid_print
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ccplayer/core/mpv_engine_store.dart';

class _RealHttp extends HttpOverrides {}

/// Explicit test-fixture preparation only; never run by normal flutter test.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'prepare pinned enhanced DLL in isolated test directory without activation',
    () async {
      final store = MpvEngineStore(
        rootOverride: Directory('.dart_tool/bdrip-enhanced-engine'),
      );
      if (!await store.isInstalledAndValid()) {
        final archive = File('.dart_tool/bdrip-downloads/mpv-20261105.7z');
        if (await archive.exists()) {
          await store.installFromArchive(archive);
        } else {
          await HttpOverrides.runWithHttpOverrides(
            () => store.downloadAndInstall(),
            _RealHttp(),
          );
        }
      }
      expect(await store.isInstalledAndValid(), isTrue);
      print('TEST_ENGINE ${(await store.libraryFile).absolute.path}');
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
