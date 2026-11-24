import 'package:konata_contracts/konata_contracts.dart';

/// 媒体源敏感凭据安全存储。
///
/// 通过 [SecureStoragePort] 按媒体源标识读写登录密码，避免明文落入本地数据库或同步载荷。
class SourceCredentialStore {
  /// 创建凭据存储实例。
  const SourceCredentialStore({required this._storage});

  final SecureStoragePort _storage;

  String _key(String sourceId) => 'konata_v2_source_secret_$sourceId';

  /// 保存媒体源密码；若密码为空则清除已有记录。
  Future<void> savePassword(String sourceId, String? password) async {
    if (password == null || password.isEmpty) {
      await _storage.delete(_key(sourceId));
      return;
    }
    await _storage.write(_key(sourceId), password);
  }

  /// 读取媒体源密码。
  Future<String?> readPassword(String sourceId) async {
    return _storage.read(_key(sourceId));
  }

  /// 删除媒体源密码。
  Future<void> deletePassword(String sourceId) async {
    await _storage.delete(_key(sourceId));
  }
}
