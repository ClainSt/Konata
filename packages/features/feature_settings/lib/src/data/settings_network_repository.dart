import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';

/// 非敏感网络镜像与代理配置分片模型。
final class _NonSecretNetworkPrefs {
  const _NonSecretNetworkPrefs({
    this.tmdbBackupApiBase = '',
    this.tmdbBackupImageBase = '',
    this.bangumiBackupApiBase = '',
    this.bangumiBackupImageBase = '',
    this.fanartBackupApiBase = '',
    this.fanartBackupImageBase = '',
    this.proxyMode = ProxyMode.system,
    this.proxyUrl = '',
  });

  final String tmdbBackupApiBase;
  final String tmdbBackupImageBase;
  final String bangumiBackupApiBase;
  final String bangumiBackupImageBase;
  final String fanartBackupApiBase;
  final String fanartBackupImageBase;
  final ProxyMode proxyMode;
  final String proxyUrl;

  Map<String, Object?> toJson() => <String, Object?>{
    'tmdbBackupApiBase': tmdbBackupApiBase,
    'tmdbBackupImageBase': tmdbBackupImageBase,
    'bangumiBackupApiBase': bangumiBackupApiBase,
    'bangumiBackupImageBase': bangumiBackupImageBase,
    'fanartBackupApiBase': fanartBackupApiBase,
    'fanartBackupImageBase': fanartBackupImageBase,
    'proxyMode': proxyMode.name,
    'proxyUrl': proxyUrl,
  };

  static _NonSecretNetworkPrefs fromJson(Map<String, Object?> json) {
    final modeName = (json['proxyMode'] ?? '').toString().trim();
    final mode = ProxyMode.values.firstWhere(
      (candidate) => candidate.name == modeName,
      orElse: () => ProxyMode.system,
    );
    return _NonSecretNetworkPrefs(
      tmdbBackupApiBase: (json['tmdbBackupApiBase'] ?? '').toString(),
      tmdbBackupImageBase: (json['tmdbBackupImageBase'] ?? '').toString(),
      bangumiBackupApiBase: (json['bangumiBackupApiBase'] ?? '').toString(),
      bangumiBackupImageBase:
          (json['bangumiBackupImageBase'] ?? '').toString(),
      fanartBackupApiBase: (json['fanartBackupApiBase'] ?? '').toString(),
      fanartBackupImageBase: (json['fanartBackupImageBase'] ?? '').toString(),
      proxyMode: mode,
      proxyUrl: (json['proxyUrl'] ?? '').toString(),
    );
  }
}

/// 网络与元数据凭据配置仓库（数据层保持零 Riverpod）。
///
/// TMDB 与 Fanart 密钥严格保存在 [SecureStoragePort]；非敏感代理与镜像地址保存在 [ScopedPrefsStore]。
final class SettingsNetworkRepository {
  /// 创建网络配置仓库。
  const SettingsNetworkRepository({
    required this._scopedPrefs,
    required this._secureStorage,
  });

  /// `SecureStoragePort` 中保存 TMDB v3/v4 凭据的键名。
  static const String tmdbCredentialKey =
      'feature_settings.network.tmdb_credential';

  /// `SecureStoragePort` 中保存 Fanart 个人客户端密钥的键名。
  static const String fanartClientKeyStorageKey =
      'feature_settings.network.fanart_client_key';

  /// `SecureStoragePort` 中保存 Fanart 自定义项目密钥的键名。
  static const String fanartApiKeyOverrideStorageKey =
      'feature_settings.network.fanart_api_key_override';

  /// `ScopedPrefsStore` 中的非敏感网络与镜像配置切片。
  static final TypedPrefsSlice<_NonSecretNetworkPrefs> _slice =
      TypedPrefsSlice<_NonSecretNetworkPrefs>(
        namespace: 'feature_settings.network',
        schemaVersion: 1,
        syncPolicy: SyncPolicy.portable,
        defaultValue: const _NonSecretNetworkPrefs(),
        decode: (json, _) => _NonSecretNetworkPrefs.fromJson(json),
        encode: (value) => value.toJson(),
      );

  final ScopedPrefsStore _scopedPrefs;
  final SecureStoragePort _secureStorage;

  /// 读取组合后的完整 [KonataNetworkConfig]。
  Future<KonataNetworkConfig> load() async {
    final prefs = _scopedPrefs.read(_slice);
    final tmdbCred = (await _secureStorage.read(tmdbCredentialKey)) ?? '';
    final fanartClient =
        (await _secureStorage.read(fanartClientKeyStorageKey)) ?? '';
    final fanartOverride =
        (await _secureStorage.read(fanartApiKeyOverrideStorageKey)) ?? '';

    const defaults = KonataNetworkConfig();
    return KonataNetworkConfig(
      credential: tmdbCred.trim(),
      tmdbBackupApiBase: prefs.tmdbBackupApiBase.isEmpty
          ? defaults.tmdbBackupApiBase
          : prefs.tmdbBackupApiBase,
      tmdbBackupImageBase: prefs.tmdbBackupImageBase.isEmpty
          ? defaults.tmdbBackupImageBase
          : prefs.tmdbBackupImageBase,
      bangumiBackupApiBase: prefs.bangumiBackupApiBase.isEmpty
          ? defaults.bangumiBackupApiBase
          : prefs.bangumiBackupApiBase,
      bangumiBackupImageBase: prefs.bangumiBackupImageBase.isEmpty
          ? defaults.bangumiBackupImageBase
          : prefs.bangumiBackupImageBase,
      fanartClientKey: fanartClient.trim(),
      fanartApiKeyOverride: fanartOverride.trim(),
      fanartBackupApiBase: prefs.fanartBackupApiBase.isEmpty
          ? defaults.fanartBackupApiBase
          : prefs.fanartBackupApiBase,
      fanartBackupImageBase: prefs.fanartBackupImageBase.isEmpty
          ? defaults.fanartBackupImageBase
          : prefs.fanartBackupImageBase,
      proxyMode: prefs.proxyMode,
      proxyUrl: prefs.proxyUrl.trim(),
    );
  }

  /// 持久化网络配置：敏感凭据写 [SecureStoragePort]，非敏感镜像写 [ScopedPrefsStore]。
  Future<void> save(KonataNetworkConfig config) async {
    await _writeOrDeleteSecret(tmdbCredentialKey, config.credential);
    await _writeOrDeleteSecret(
      fanartClientKeyStorageKey,
      config.fanartClientKey,
    );
    await _writeOrDeleteSecret(
      fanartApiKeyOverrideStorageKey,
      config.fanartApiKeyOverride,
    );

    _scopedPrefs.write(
      _slice,
      _NonSecretNetworkPrefs(
        tmdbBackupApiBase: config.tmdbBackupApiBase.trim(),
        tmdbBackupImageBase: config.tmdbBackupImageBase.trim(),
        bangumiBackupApiBase: config.bangumiBackupApiBase.trim(),
        bangumiBackupImageBase: config.bangumiBackupImageBase.trim(),
        fanartBackupApiBase: config.fanartBackupApiBase.trim(),
        fanartBackupImageBase: config.fanartBackupImageBase.trim(),
        proxyMode: config.proxyMode,
        proxyUrl: config.proxyUrl.trim(),
      ),
    );
  }

  /// 读取当前保存的全部非空凭据明文集合，供诊断导出二次脱敏使用。
  Future<List<String>> readCurrentSecretsForRedaction() async {
    final values = <String>[
      (await _secureStorage.read(tmdbCredentialKey))?.trim() ?? '',
      (await _secureStorage.read(fanartClientKeyStorageKey))?.trim() ?? '',
      (await _secureStorage.read(fanartApiKeyOverrideStorageKey))?.trim() ?? '',
    ];
    return values.where((v) => v.isNotEmpty).toList(growable: false);
  }

  Future<void> _writeOrDeleteSecret(String key, String raw) async {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      await _secureStorage.delete(key);
    } else {
      await _secureStorage.write(key, trimmed);
    }
  }
}
