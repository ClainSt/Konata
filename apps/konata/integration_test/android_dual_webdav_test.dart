import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:konata/bootstrap/host_storage_adapters.dart';

import 'support/dual_webdav_scenario.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Android 真机与 Windows 双向 WebDAV 磁盘同步', (tester) async {
    expect(Platform.isAndroid, isTrue);
    final parent = Directory(
      await (await createAndroidStorageRoot()).resolveAppRootPath(),
    );
    await parent.create(recursive: true);
    final dir = await parent.createTemp('konata-dual-webdav-');
    try {
      await runDualWebDavScenario('android', dir.path);
    } finally {
      await dir.delete(recursive: true);
    }
  });
}
