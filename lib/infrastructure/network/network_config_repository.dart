import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/models/network_config.dart';

/// 刮削与图床网络配置持久化仓储。
///
/// 备用地址与代理模式保存在 `SharedPreferences`，TMDB 凭证通过 `FlutterSecureStorage` 存储。
class NetworkConfigRepository {
  /// 创建网络配置仓储。
  const NetworkConfigRepository({
    FlutterSecureStorage? secureStorage,
    Future<SharedPreferences> Function()? prefsLoader,
  }) : _secureStorage = secureStorage ?? const FlutterSecureStorage(),
       _prefsLoader = prefsLoader ?? SharedPreferences.getInstance;

  final FlutterSecureStorage _secureStorage;
  final Future<SharedPreferences> Function() _prefsLoader;

  static const String _keyCredential = 'konata_v2_tmdb_credential';
  static const String _keyFanartClientKey = 'konata_v2_fanart_client_key';
  static const String _keyFanartApiKeyOverride =
      'konata_v2_fanart_api_key_override';
  static const String _keyTmdbBackupApi = 'konata_v2_tmdb_backup_api';
  static const String _keyTmdbBackupImage = 'konata_v2_tmdb_backup_image';
  static const String _keyBangumiBackupApi = 'konata_v2_bangumi_backup_api';
  static const String _keyBangumiBackupImage = 'konata_v2_bangumi_backup_image';
  static const String _keyFanartBackupApi = 'konata_v2_fanart_backup_api';
  static const String _keyFanartBackupImage = 'konata_v2_fanart_backup_image';
  static const String _keyProxyMode = 'konata_v2_proxy_mode';
  static const String _keyProxyUrl = 'konata_v2_proxy_url';

  // 旧版键（仅做平滑迁移兜底）
  static const String _legacyKeyMode = 'konata_v2_network_mode';
  static const String _legacyKeyProxyHost = 'konata_v2_proxy_host';
  static const String _legacyKeyProxyPort = 'konata_v2_proxy_port';
  static const String _legacyKeyUseSocks5 = 'konata_v2_proxy_socks5';

  /// 加载当前持久化的网络配置。
  Future<TmdbNetworkConfig> load() async {
    final prefs = await _prefsLoader();
    final credential = (await _secureStorage.read(key: _keyCredential)) ?? '';
    final fanartClientKey =
        (await _secureStorage.read(key: _keyFanartClientKey)) ?? '';
    final fanartApiKeyOverride =
        (await _secureStorage.read(key: _keyFanartApiKeyOverride)) ?? '';

    var proxyMode = ProxyMode.system;
    var proxyUrl = prefs.getString(_keyProxyUrl) ?? '';

    final modeName = prefs.getString(_keyProxyMode);
    if (modeName != null) {
      proxyMode = ProxyMode.values.firstWhere(
        (m) => m.name == modeName,
        orElse: () => ProxyMode.system,
      );
    } else if (prefs.getString(_legacyKeyMode) == 'customProxy') {
      final host = prefs.getString(_legacyKeyProxyHost) ?? '127.0.0.1';
      final port = prefs.getInt(_legacyKeyProxyPort) ?? 7890;
      final isSocks5 = prefs.getBool(_legacyKeyUseSocks5) ?? false;
      proxyMode = ProxyMode.custom;
      if (proxyUrl.isEmpty) {
        proxyUrl = '${isSocks5 ? 'socks5' : 'http'}://$host:$port';
      }
    }

    return TmdbNetworkConfig(
      credential: credential,
      tmdbBackupApiBase:
          prefs.getString(_keyTmdbBackupApi) ??
          TmdbNetworkConfig.defaultTmdbBackupApiBase,
      tmdbBackupImageBase:
          prefs.getString(_keyTmdbBackupImage) ??
          TmdbNetworkConfig.defaultTmdbBackupImageBase,
      bangumiBackupApiBase: _withoutRetiredDefault(
        prefs.getString(_keyBangumiBackupApi),
        retired: TmdbNetworkConfig.retiredBangumiBackupApiBases,
        current: TmdbNetworkConfig.defaultBangumiBackupApiBase,
      ),
      bangumiBackupImageBase: _withoutRetiredDefault(
        prefs.getString(_keyBangumiBackupImage),
        retired: TmdbNetworkConfig.retiredBangumiBackupImageBases,
        current: TmdbNetworkConfig.defaultBangumiBackupImageBase,
      ),
      fanartClientKey: fanartClientKey,
      fanartApiKeyOverride: fanartApiKeyOverride,
      fanartBackupApiBase:
          prefs.getString(_keyFanartBackupApi) ??
          TmdbNetworkConfig.builtInFanartRelayBase,
      fanartBackupImageBase: prefs.getString(_keyFanartBackupImage) ?? '',
      proxyMode: proxyMode,
      proxyUrl: proxyUrl,
    );
  }

  /// 未保存过或仍是已迁址的旧版默认地址时返回当前默认地址；用户自定义的地址原样保留。
  static String _withoutRetiredDefault(
    String? stored, {
    required Set<String> retired,
    required String current,
  }) {
    if (stored == null) return current;
    final normalized = stored.trim().replaceAll(RegExp(r'/+$'), '');
    return retired.contains(normalized) ? current : stored;
  }

  /// 保存网络配置。
  Future<void> save(TmdbNetworkConfig config) async {
    final prefs = await _prefsLoader();
    await prefs.setString(_keyTmdbBackupApi, config.tmdbBackupApiBase.trim());
    await prefs.setString(
      _keyTmdbBackupImage,
      config.tmdbBackupImageBase.trim(),
    );
    await prefs.setString(
      _keyBangumiBackupApi,
      config.bangumiBackupApiBase.trim(),
    );
    await prefs.setString(
      _keyBangumiBackupImage,
      config.bangumiBackupImageBase.trim(),
    );
    await prefs.setString(
      _keyFanartBackupApi,
      config.fanartBackupApiBase.trim(),
    );
    await prefs.setString(
      _keyFanartBackupImage,
      config.fanartBackupImageBase.trim(),
    );
    await prefs.setString(_keyProxyMode, config.proxyMode.name);
    await prefs.setString(_keyProxyUrl, config.proxyUrl.trim());

    await _writeOrDeleteSecret(_keyCredential, config.credential);
    await _writeOrDeleteSecret(_keyFanartClientKey, config.fanartClientKey);
    await _writeOrDeleteSecret(
      _keyFanartApiKeyOverride,
      config.fanartApiKeyOverride,
    );
  }

  Future<void> _writeOrDeleteSecret(String key, String raw) async {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      await _secureStorage.delete(key: key);
    } else {
      await _secureStorage.write(key: key, value: trimmed);
    }
  }
}
