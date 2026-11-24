import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';
import 'package:path_provider/path_provider.dart';

/// 基于 `flutter_secure_storage` 的跨端敏感凭据安全存储实现（实现 [SecureStoragePort]）。
///
/// Windows 端经由本地绿色便携 DPAPI 插件落盘，Android 端走系统 KeyStore 加密存储，
/// 敏感密码与令牌绝不进入 SQLite 或跨设备同步切片。
final class FlutterSecureStorageAdapter implements SecureStoragePort {
  /// 创建跨端安全存储适配器。
  const FlutterSecureStorageAdapter({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String? value) {
    if (value == null || value.isEmpty) {
      return _storage.delete(key: key);
    }
    return _storage.write(key: key, value: value);
  }

  @override
  Future<void> delete(String key) => _storage.delete(key: key);

  @override
  Future<Map<String, String>> readAllWithPrefix(String prefix) async {
    final all = await _storage.readAll();
    return <String, String>{
      for (final entry in all.entries)
        if (entry.key.startsWith(prefix)) entry.key: entry.value,
    };
  }
}

/// 构造 Windows 桌面端绿色便携存储根目录端口（严禁写入 C 盘系统用户目录）。
StorageRootPort createWindowsStorageRoot({String? laneOverride}) {
  return PortableStorageRootService(laneOverride: laneOverride);
}

/// 构造 Android 端应用沙箱存储根目录端口（委托 `ApplicationSupportDirectory`）。
Future<StorageRootPort> createAndroidStorageRoot() async {
  final supportDir = await getApplicationSupportDirectory();
  return PortableStorageRootService(overrideRootPath: supportDir.path);
}
