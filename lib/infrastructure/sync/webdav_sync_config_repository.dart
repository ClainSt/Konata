import 'dart:developer' as developer;

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/sync/konata_sync_models.dart';

/// WebDAV 多设备同步配置仓储（基础参数存 `SharedPreferences`，密码仅存 `FlutterSecureStorage`）。
class WebDavSyncConfigRepository {
  /// 创建 WebDAV 同步配置仓储。
  const WebDavSyncConfigRepository({
    FlutterSecureStorage? secureStorage,
    Future<SharedPreferences> Function()? prefsLoader,
  }) : _secureStorage = secureStorage ?? const FlutterSecureStorage(),
       _prefsLoader = prefsLoader ?? SharedPreferences.getInstance;

  final FlutterSecureStorage _secureStorage;
  final Future<SharedPreferences> Function() _prefsLoader;

  static const String _keyEnabled = 'konata_v2_sync_webdav_enabled';
  static const String _keyBaseUrl = 'konata_v2_sync_webdav_url';
  static const String _keyRemoteDir = 'konata_v2_sync_webdav_dir';
  static const String _keyUsername = 'konata_v2_sync_webdav_username';
  static const String _keyPassword = 'konata_v2_sync_webdav_password_secret';
  static const String _keyAutoStartup = 'konata_v2_sync_webdav_auto_startup';
  static const String _keyAutoStop = 'konata_v2_sync_webdav_auto_stop';
  static const String _keyAutoIntervalMinutes =
      'konata_v2_sync_webdav_interval_minutes';
  static const String _keyScopePlaybacks =
      'konata_v2_sync_webdav_scope_playbacks';
  static const String _keyScopeWorkOverrides =
      'konata_v2_sync_webdav_scope_work_overrides';
  static const String _keyScopePreferences =
      'konata_v2_sync_webdav_scope_preferences';

  /// 加载当前持久化的 WebDAV 同步配置（无平台插件环境下安全回落空密码）。
  Future<WebDavSyncConfig> load() async {
    final prefs = await _prefsLoader();
    var password = '';
    try {
      password = (await _secureStorage.read(key: _keyPassword)) ?? '';
    } on MissingPluginException {
      password = '';
    } on PlatformException catch (error) {
      developer.log(
        '读取 WebDAV 同步密码凭据失败，回落为空',
        name: 'konata.webdav_sync_config_repository',
        error: error,
      );
    }
    return WebDavSyncConfig(
      enabled: prefs.getBool(_keyEnabled) ?? false,
      baseUrl: prefs.getString(_keyBaseUrl) ?? '',
      remoteDir:
          prefs.getString(_keyRemoteDir) ?? WebDavSyncConfig.defaultRemoteDir,
      username: prefs.getString(_keyUsername) ?? '',
      password: password,
      autoSyncOnStartup: prefs.getBool(_keyAutoStartup) ?? false,
      autoSyncOnPlaybackStop: prefs.getBool(_keyAutoStop) ?? false,
      autoSyncIntervalMinutes: WebDavSyncConfig.normalizeIntervalMinutes(
        prefs.getInt(_keyAutoIntervalMinutes) ?? 0,
      ),
      syncScope: KonataSyncDataScope(
        includePlaybacks: prefs.getBool(_keyScopePlaybacks) ?? true,
        includeWorkOverrides: prefs.getBool(_keyScopeWorkOverrides) ?? true,
        includePreferences: prefs.getBool(_keyScopePreferences) ?? true,
      ),
    );
  }

  /// 持久化 WebDAV 同步配置。
  Future<void> save(WebDavSyncConfig config) async {
    final prefs = await _prefsLoader();
    await prefs.setBool(_keyEnabled, config.enabled);
    await prefs.setString(_keyBaseUrl, config.baseUrl.trim());
    await prefs.setString(_keyRemoteDir, config.normalizedRemoteDir);
    await prefs.setString(_keyUsername, config.username.trim());
    await prefs.setBool(_keyAutoStartup, config.autoSyncOnStartup);
    await prefs.setBool(_keyAutoStop, config.autoSyncOnPlaybackStop);
    await prefs.setInt(
      _keyAutoIntervalMinutes,
      WebDavSyncConfig.normalizeIntervalMinutes(config.autoSyncIntervalMinutes),
    );
    await prefs.setBool(_keyScopePlaybacks, config.syncScope.includePlaybacks);
    await prefs.setBool(
      _keyScopeWorkOverrides,
      config.syncScope.includeWorkOverrides,
    );
    await prefs.setBool(
      _keyScopePreferences,
      config.syncScope.includePreferences,
    );

    final pwd = config.password;
    try {
      if (pwd.isEmpty) {
        await _secureStorage.delete(key: _keyPassword);
      } else {
        await _secureStorage.write(key: _keyPassword, value: pwd);
      }
    } on MissingPluginException {
      developer.log(
        '当前运行环境无安全存储插件，跳过持久化 WebDAV 同步密码',
        name: 'konata.webdav_sync_config_repository',
      );
    } on PlatformException catch (error) {
      developer.log(
        '写入 WebDAV 同步密码凭据失败',
        name: 'konata.webdav_sync_config_repository',
        error: error,
      );
    }
  }
}
