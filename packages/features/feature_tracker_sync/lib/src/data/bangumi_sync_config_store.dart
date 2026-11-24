import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';

import 'bangumi_sync_models.dart';

/// Bangumi 同步偏好与安全凭据仓库（状态与数据层保持零 Riverpod）。
///
/// 非敏感开关与账号展示信息保存在 `ScopedPrefsStore`，PAT 密钥严格只存于 `SecureStoragePort`。
final class BangumiSyncConfigStore {
  /// 创建 Bangumi 同步配置仓库。
  BangumiSyncConfigStore({
    required this._scopedPrefs,
    required this._secureStorage,
    required this._syncMetaDao,
  });

  /// `SecureStoragePort` 中保存 Bangumi PAT 的唯一键名。
  static const String patStorageKey = 'feature_tracker_sync.bangumi.pat';

  /// `SyncMetaDao` 中保存鉴权失效标记的键名（绝不写入凭据明文）。
  static const String authInvalidMetaKey =
      'feature_tracker_sync.bangumi.auth_invalid';

  /// `SyncMetaDao` 中保存已脱敏鉴权提示文案的键名。
  static const String authErrorMetaKey =
      'feature_tracker_sync.bangumi.auth_error';

  /// `ScopedPrefsStore` 中的类型安全配置分片。
  static final TypedPrefsSlice<BangumiSyncConfig> configSlice =
      TypedPrefsSlice<BangumiSyncConfig>(
        namespace: 'feature_tracker_sync.bangumi',
        schemaVersion: 1,
        syncPolicy: SyncPolicy.portable,
        defaultValue: const BangumiSyncConfig(),
        decode: (json, _) => BangumiSyncConfig.fromJson(json),
        encode: (config) => config.toJson(),
      );

  final ScopedPrefsStore _scopedPrefs;
  final SecureStoragePort _secureStorage;
  final SyncMetaDao _syncMetaDao;

  /// 读取当前非敏感同步配置。
  BangumiSyncConfig readConfig() => _scopedPrefs.read(configSlice);

  /// 持久化非敏感同步配置。
  Future<void> saveConfig(BangumiSyncConfig config) async {
    _scopedPrefs.write(configSlice, config);
  }

  /// 响应式监听非敏感同步配置变化。
  Stream<BangumiSyncConfig> watchConfig() => _scopedPrefs.watch(configSlice);

  /// 从安全凭据存储读取 PAT（去除首尾空白）。
  Future<String?> readToken() async {
    final raw = await _secureStorage.read(patStorageKey);
    final trimmed = raw?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      return null;
    }
    return trimmed;
  }

  /// 判断当前是否已配置非空 PAT。
  Future<bool> hasToken() async {
    final token = await readToken();
    return token != null && token.isNotEmpty;
  }

  /// 保存或清空 PAT 凭据（只写入 `SecureStoragePort`）。
  Future<void> saveToken(String token) async {
    final trimmed = token.trim();
    if (trimmed.isEmpty) {
      await deleteToken();
      return;
    }
    await _secureStorage.write(patStorageKey, trimmed);
  }

  /// 删除安全凭据存储中的 PAT，并清理验证资料。
  Future<void> deleteToken() async {
    await _secureStorage.delete(patStorageKey);
  }

  /// 读取持久化鉴权失效状态及脱敏提示文案。
  ({bool authInvalid, String? authError}) readAuthState() {
    final rawFlag = _syncMetaDao.get(authInvalidMetaKey)?.value;
    final authInvalid = rawFlag == '1' || rawFlag == 'true';
    final rawErr = _syncMetaDao.get(authErrorMetaKey)?.value;
    final authError = rawErr != null && rawErr.trim().isNotEmpty
        ? rawErr.trim()
        : null;
    return (authInvalid: authInvalid, authError: authError);
  }

  /// 写入鉴权失效标记与脱敏提示，绝不写入任何 PAT 内容。
  void writeAuthState({
    required bool authInvalid,
    String? authError,
    required int updatedAtMs,
  }) {
    _syncMetaDao.put(
      authInvalidMetaKey,
      authInvalid ? '1' : '0',
      updatedAtMs: updatedAtMs,
    );
    if (!authInvalid || authError == null || authError.trim().isEmpty) {
      _syncMetaDao.delete(authErrorMetaKey);
      return;
    }
    final sanitized = DiagnosticTextSanitizer.redactSecrets(authError.trim());
    _syncMetaDao.put(
      authErrorMetaKey,
      sanitized,
      updatedAtMs: updatedAtMs,
    );
  }
}
