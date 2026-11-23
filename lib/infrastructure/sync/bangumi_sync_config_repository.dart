import 'dart:developer' as developer;

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/sync/bangumi_sync_models.dart';

/// Bangumi PAT 同步配置仓储（开关保存在 `SharedPreferences`，个人访问令牌仅存于 `FlutterSecureStorage`）。
class BangumiSyncConfigRepository {
  /// 创建 Bangumi 同步配置仓储。
  const BangumiSyncConfigRepository({
    FlutterSecureStorage? secureStorage,
    Future<SharedPreferences> Function()? prefsLoader,
  }) : _secureStorage = secureStorage ?? const FlutterSecureStorage(),
       _prefsLoader = prefsLoader ?? SharedPreferences.getInstance;

  final FlutterSecureStorage _secureStorage;
  final Future<SharedPreferences> Function() _prefsLoader;

  static const String _keyEnabled = 'konata_v2_bangumi_sync_enabled';
  static const String _keyPat = 'konata_v2_bangumi_pat_secret';
  static const String _keySyncMode = 'konata_v2_bangumi_sync_mode';
  static const String _keyAutoPush = 'konata_v2_bangumi_auto_push';
  static const String _keyAutoCompleteSubject =
      'konata_v2_bangumi_auto_complete_subject';

  /// 读取持久化 Bangumi 同步配置（无安全存储插件时安全回落为空令牌）。
  Future<BangumiSyncConfig> load() async {
    final prefs = await _prefsLoader();
    var token = '';
    try {
      token = (await _secureStorage.read(key: _keyPat)) ?? '';
    } on MissingPluginException {
      token = '';
    } on PlatformException catch (error) {
      developer.log(
        '读取 Bangumi PAT 安全凭据失败，回落为空',
        name: 'konata.bangumi_sync_config_repository',
        error: error,
      );
    }

    final modeRaw = prefs.getString(_keySyncMode);
    final mode = BangumiSyncMode.values.firstWhere(
      (m) => m.name == modeRaw,
      orElse: () => BangumiSyncMode.bidirectional,
    );

    return BangumiSyncConfig(
      enabled: prefs.getBool(_keyEnabled) ?? false,
      personalAccessToken: token,
      syncMode: mode,
      autoPushOnComplete: prefs.getBool(_keyAutoPush) ?? true,
      autoMarkSubjectCompleted: prefs.getBool(_keyAutoCompleteSubject) ?? true,
    );
  }

  /// 持久化 Bangumi 同步配置。
  Future<void> save(BangumiSyncConfig config) async {
    final prefs = await _prefsLoader();
    await prefs.setBool(_keyEnabled, config.enabled);
    await prefs.setString(_keySyncMode, config.syncMode.name);
    await prefs.setBool(_keyAutoPush, config.autoPushOnComplete);
    await prefs.setBool(
      _keyAutoCompleteSubject,
      config.autoMarkSubjectCompleted,
    );

    final trimmed = config.personalAccessToken.trim();
    try {
      if (trimmed.isEmpty) {
        await _secureStorage.delete(key: _keyPat);
      } else {
        await _secureStorage.write(key: _keyPat, value: trimmed);
      }
    } on MissingPluginException {
      developer.log(
        '当前运行环境无安全存储插件，跳过写入 Bangumi PAT',
        name: 'konata.bangumi_sync_config_repository',
      );
    } on PlatformException catch (error) {
      developer.log(
        '写入 Bangumi PAT 安全凭据失败',
        name: 'konata.bangumi_sync_config_repository',
        error: error,
      );
    }
  }
}
