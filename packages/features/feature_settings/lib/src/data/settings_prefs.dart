import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_design_system/konata_design_system.dart';
import 'package:konata_storage/konata_storage.dart';

/// 外观与界面显示持久化偏好模型（状态与数据层保持零 Riverpod）。
final class SettingsAppearancePrefs {
  /// 创建外观与显示偏好配置。
  const SettingsAppearancePrefs({
    this.themeMode = ThemeMode.dark,
    this.ambientBackdropEnabled = true,
  });

  /// 当前主题外观模式。
  final ThemeMode themeMode;

  /// 是否启用全局柔和流光氛围背景。
  final bool ambientBackdropEnabled;

  /// 复制并修改部分外观配置。
  SettingsAppearancePrefs copyWith({
    ThemeMode? themeMode,
    bool? ambientBackdropEnabled,
  }) {
    return SettingsAppearancePrefs(
      themeMode: themeMode ?? this.themeMode,
      ambientBackdropEnabled:
          ambientBackdropEnabled ?? this.ambientBackdropEnabled,
    );
  }

  /// 序列化为 JSON 字典。
  Map<String, Object?> toJson() => <String, Object?>{
    'themeMode': themeMode.name,
    'ambientBackdropEnabled': ambientBackdropEnabled,
  };

  /// 从持久化 JSON 反序列化。
  static SettingsAppearancePrefs fromJson(Map<String, Object?> json) {
    final modeRaw = (json['themeMode'] ?? '').toString().trim();
    final mode = ThemeMode.values.firstWhere(
      (candidate) => candidate.name == modeRaw,
      orElse: () => ThemeMode.dark,
    );
    final ambient = json['ambientBackdropEnabled'] is bool
        ? json['ambientBackdropEnabled']! as bool
        : true;
    return SettingsAppearancePrefs(
      themeMode: mode,
      ambientBackdropEnabled: ambient,
    );
  }
}

/// 通用外观设置持久化读写仓库（存入 `ScopedPrefsStore`）。
final class SettingsAppearanceRepository {
  /// 创建外观设置仓库。
  const SettingsAppearanceRepository(this._scopedPrefs);

  /// 外观设置类型安全分片定义。
  static final TypedPrefsSlice<SettingsAppearancePrefs> slice =
      TypedPrefsSlice<SettingsAppearancePrefs>(
        namespace: 'feature_settings.appearance',
        schemaVersion: 1,
        syncPolicy: SyncPolicy.portable,
        defaultValue: const SettingsAppearancePrefs(),
        decode: (json, _) => SettingsAppearancePrefs.fromJson(json),
        encode: (value) => value.toJson(),
      );

  final ScopedPrefsStore _scopedPrefs;

  /// 读取当前外观与显示设置。
  SettingsAppearancePrefs read() => _scopedPrefs.read(slice);

  /// 写入并持久化外观与显示设置。
  void save(SettingsAppearancePrefs value) {
    _scopedPrefs.write(slice, value);
  }

  /// 响应式监听外观设置变化。
  Stream<SettingsAppearancePrefs> watch() => _scopedPrefs.watch(slice);
}
