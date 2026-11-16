import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 媒体源敏感凭据安全存储。
///
/// 通过 `FlutterSecureStorage` 按媒体源 `sourceId` 读写登录密码，避免明文落入 SQLite。
class SourceCredentialStore {
  /// 创建凭据存储实例。
  const SourceCredentialStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  String _key(String sourceId) => 'konata_v2_source_secret_$sourceId';

  /// 保存媒体源密码；若密码为空则清除已有记录。
  Future<void> savePassword(String sourceId, String? password) async {
    if (password == null || password.isEmpty) {
      await _storage.delete(key: _key(sourceId));
      return;
    }
    await _storage.write(key: _key(sourceId), value: password);
  }

  /// 读取媒体源密码。
  Future<String?> readPassword(String sourceId) async {
    return _storage.read(key: _key(sourceId));
  }

  /// 删除媒体源密码。
  Future<void> deletePassword(String sourceId) async {
    await _storage.delete(key: _key(sourceId));
  }
}
