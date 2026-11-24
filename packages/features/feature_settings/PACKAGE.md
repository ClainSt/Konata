# `feature_settings`

Konata 三端自适应纯声明式设置容器业务包，向上层提供聚合设置框架及外观、网络凭据、存储清理诊断、关于 Konata 四项通用设置分区。

## 公开出口

统一从 `package:feature_settings/feature_settings.dart` 导入，禁止跨包引用 `src/` 内部路径：

- 依赖与清单：`FeatureSettingsDependencies`、`featureSettingsDependenciesProvider`、`featureSettingsManifest`
- 数据与状态：`SettingsController`、`settingsControllerProvider`、`SettingsAppearanceRepository`、`SettingsNetworkRepository`、`PhotosCleanupScanner`
- 容器与面板：`SettingsPage`、`SettingsAppearancePanel`、`SettingsNetworkPanel`、`SettingsPhotosStorageCard`、`SettingsAboutPanel`

## 架构与解耦约束

- **纯粹声明式容器**：`SettingsPage` 仅消费经 `FeatureSettingsDependencies.sections` 传入的 `SettingsSectionContribution`，按 `currentPlatform` 过滤并按 `order` 升序排列；绝不硬编码播放器、离线备份、歌词或追番同步等其他业务包的面板。
- **凭据与偏好严格隔离**：TMDB / Fanart API 密钥严格存入 `SecureStoragePort`，镜像与代理参数存入 `ScopedPrefsStore`。
- **零原生桌面插件依赖**：外链通过 `UrlOpenerPort`，脱敏诊断日志通过 `DiagnosticLogPort` 与 `BackupFilePort.saveFile` 导出落盘。
- **状态零 Riverpod**：`lib/src/data/` 与 `lib/src/state/` 不引入 `flutter_riverpod`，界面层严禁直接导入 `material.dart` 或 `cupertino.dart`。
