import 'dart:io';

import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage_windows/flutter_secure_storage_windows.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('stores and removes an isolated generic credential', () async {
    if (!Platform.isWindows) return;
    final storage = FlutterSecureStorageWindows();
    const key = 'credential_manager_storage_test_${0x4e50}';
    const value = 'test-token-秘密';
    addTearDown(() => storage.delete(key: key, options: const {}));

    await storage.write(key: key, value: value, options: const {});
    expect(await storage.containsKey(key: key, options: const {}), isTrue);
    expect(await storage.read(key: key, options: const {}), value);
    await storage.delete(key: key, options: const {});
    expect(await storage.read(key: key, options: const {}), isNull);
    expect(FlutterSecureStoragePlatform.instance, isNotNull);
  });
}
