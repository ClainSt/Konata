# `feature_settings`

Konata 三端自适应纯声明式设置容器业务包，向上层提供聚合设置框架及外观、显示与存储、刮削与网络、关于四项通用设置分区。

## 公开出口

统一从 `package:feature_settings/feature_settings.dart` 导入，禁止跨包引用 `src/` 内部路径：

- 依赖与清单：`FeatureSettingsDependencies`、`featureSettingsDependenciesProvider`、`featureSettingsManifest`
- 数据与状态：`SettingsController`、`settingsControllerProvider`、`SettingsAppearancePrefs`、`SettingsAppearanceRepository`、`SettingsDisplayPrefs`、`SettingsDisplayRepository`、`SettingsNetworkRepository`、`PhotosCleanupScanner`、`PhotosCleanupSnapshot`、`WorkPhotoStorageEntry`
- 容器与面板：`SettingsPage`、`SettingsAppearancePanel`、`SettingsDisplayPanel`、`SettingsNetworkPanel`、`SettingsPhotosStorageCard`、`SettingsAboutPanel`
- 弹窗辅助：`showTmdbApiHelpDialog`、`showFanartApiHelpDialog`、`showPhotoCustomCleanupDialog`

## 架构与解耦约束

- **纯粹声明式容器**：`SettingsPage` 仅消费经 `FeatureSettingsDependencies.sections` 传入的 `SettingsSectionContribution`，按 `currentPlatform` 过滤并按 `order` 升序排列，并将旧深链 `'storage'` 兼容映射至 `'display'`；绝不硬编码播放器、离线备份、歌词或追番同步等其他业务包的面板。
- **共享分片零覆盖契约**：`SettingsDisplayRepository` 直接读写 `'feature_detail.display'` 便携命名空间（`schemaVersion: 1`），在变更显示面板 6 项字段（`showTitleText`、`showTitleLogo`、`showOverview`、`showRawVideoFilename`、`showCdTab`、`showScanTab`）时完整保留 `feature_detail` 共存字段（`showMainHeroBackdrop`、`showEpisodeStillThumbnails`、`showOriginalSubtitlesOnCards`、`autoSilentWarmup`）与未知字段，严禁跨包导入 `feature_detail`。
- **凭据与偏好严格隔离**：TMDB / Fanart API 密钥严格存入 `SecureStoragePort`，镜像与代理参数存入 `ScopedPrefsStore`。
- **零原生桌面插件依赖**：外链与本地目录通过 `UrlOpenerPort`，脱敏诊断日志通过 `DiagnosticLogPort` 与 `BackupFilePort.saveFile` 导出落盘。
- **状态零 Riverpod**：`lib/src/data/` 与 `lib/src/state/` 不引入 `flutter_riverpod`，界面层严禁直接导入 `material.dart` / `cupertino.dart` / `material_ui` / `cupertino_ui`。
