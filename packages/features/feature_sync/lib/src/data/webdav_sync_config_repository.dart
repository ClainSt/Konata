import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';

import 'sync_models.dart';

/// WebDAV 多设备同步配置持久化仓储。
///
/// 严格执行凭据隔离铁律：
/// - 服务器地址、远端目录、用户名、自动同步开关与勾选切片存入 `ScopedPrefsStore`
///   （命名空间 `sync_webdav`，同步策略 `SyncPolicy.deviceLocal`）；
/// - WebDAV 登录密码仅读写自 `SecureStoragePort`，绝不落入数据库与导出归档。
final class WebDavSyncConfigRepository {
  /// 创建 WebDAV 同步配置仓储。
  const WebDavSyncConfigRepository({
    required this._scopedPrefs,
    required this._secureStorage,
  });

  /// 非敏感同步配置在 `ScopedPrefsStore` 中的固定命名空间。
  static const String prefsNamespace = 'sync_webdav';

  /// WebDAV 密码在 `SecureStoragePort` 中的唯一存储键。
  static const String passwordSecretKey = 'konata_sync_webdav_password_secret';

  final ScopedPrefsStore _scopedPrefs;
  final SecureStoragePort _secureStorage;

  /// `sync_webdav` 强类型配置切片定义（始终标记为 `deviceLocal` 隔离跨端覆写）。
  static const TypedPrefsSlice<WebDavSyncConfig> prefsSlice =
      TypedPrefsSlice<WebDavSyncConfig>(
        namespace: prefsNamespace,
        schemaVersion: 1,
        syncPolicy: SyncPolicy.deviceLocal,
        defaultValue: WebDavSyncConfig(),
        encode: _encodeNonSecretPrefs,
        decode: _decodeNonSecretPrefs,
      );

  /// 读取当前设备的完整 WebDAV 配置（含自安全存储读取的密码）。
  Future<WebDavSyncConfig> load() async {
    final prefsConfig = _scopedPrefs.read(prefsSlice);
    final password = await _readPasswordSafely();
    return prefsConfig.copyWith(password: password);
  }

  /// 保存 WebDAV 配置（非敏感项写 `ScopedPrefsStore`，密码仅写 `SecureStoragePort`）。
  Future<void> save(
    WebDavSyncConfig config, {
    String sourceDeviceId = '',
  }) async {
    final normalized = config.copyWith(
      baseUrl: config.baseUrl.trim(),
      remoteDir: config.normalizedRemoteDir,
      username: config.username.trim(),
      autoSyncIntervalMinutes: WebDavSyncConfig.normalizeIntervalMinutes(
        config.autoSyncIntervalMinutes,
      ),
    );
    _scopedPrefs.write(
      prefsSlice,
      normalized.copyWith(password: ''),
      sourceDeviceId: sourceDeviceId,
    );

    final pwd = normalized.password;
    if (pwd.isEmpty) {
      await _secureStorage.delete(passwordSecretKey);
    } else {
      await _secureStorage.write(passwordSecretKey, pwd);
    }
  }

  Future<String> _readPasswordSafely() async {
    try {
      return (await _secureStorage.read(passwordSecretKey)) ?? '';
    } catch (_) {
      return '';
    }
  }

  static Map<String, Object?> _encodeNonSecretPrefs(WebDavSyncConfig value) {
    return <String, Object?>{
      'enabled': value.enabled,
      'baseUrl': value.baseUrl.trim(),
      'remoteDir': value.normalizedRemoteDir,
      'username': value.username.trim(),
      'autoSyncOnStartup': value.autoSyncOnStartup,
      'autoSyncOnPlaybackStop': value.autoSyncOnPlaybackStop,
      'autoSyncIntervalMinutes': WebDavSyncConfig.normalizeIntervalMinutes(
        value.autoSyncIntervalMinutes,
      ),
      if (value.selectedSliceIds != null)
        'selectedSliceIds': (value.selectedSliceIds!.toList()..sort()),
    };
  }

  static WebDavSyncConfig _decodeNonSecretPrefs(
    Map<String, Object?> json,
    int storedSchemaVersion,
  ) {
    final rawSelected = json['selectedSliceIds'];
    Set<String>? selectedIds;
    if (rawSelected is List) {
      selectedIds = <String>{
        for (final item in rawSelected)
          if (item.toString().trim().isNotEmpty) item.toString().trim(),
      };
    }
    return WebDavSyncConfig(
      enabled: json['enabled'] == true,
      baseUrl: (json['baseUrl'] as String? ?? '').trim(),
      remoteDir: (json['remoteDir'] as String? ?? WebDavSyncConfig.defaultRemoteDir)
          .trim(),
      username: (json['username'] as String? ?? '').trim(),
      password: '',
      autoSyncOnStartup: json['autoSyncOnStartup'] == true,
      autoSyncOnPlaybackStop: json['autoSyncOnPlaybackStop'] == true,
      autoSyncIntervalMinutes: WebDavSyncConfig.normalizeIntervalMinutes(
        (json['autoSyncIntervalMinutes'] as num?)?.toInt() ?? 0,
      ),
      selectedSliceIds: selectedIds,
    );
  }
}
