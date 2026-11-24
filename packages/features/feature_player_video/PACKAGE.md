# feature_player_video

全屏视频播放舞台、16:9 可拖拽悬浮小窗与音画设置业务包。

## 职责边界

- **依赖范围**：仅依赖 `konata_contracts`、`konata_storage`、`konata_design_system`、`engine_sources`、`engine_playback`、`flutter`、`flutter_riverpod` 与 `path`；严格隔离兄弟业务包与平台原生插件。
- **界面约束**：界面层仅使用 `package:flutter/widgets.dart`、`services.dart`、`foundation.dart` 与 `package:konata_design_system/konata_design_system.dart` 导出原语。
- **状态分层**：`lib/src/data/` 与 `lib/src/state/` 保持零状态管理框架耦合，仅通过 `lib/src/providers.dart` 提供依赖装配与控制器生命周期管理；高频播放进度与悬浮小窗拖拽偏移直连叶子 `ValueNotifier`。

## 公开出口

- 清单与依赖：`featurePlayerVideoManifest`（`id: 'feature_player_video'`）、`FeaturePlayerVideoDependencies`、`featurePlayerVideoDependenciesProvider`、`videoPlaybackControllerProvider`。
- 自治配置与服务：`VideoPlaybackPreferences`（`playback_video` 命名空间切片）、`VideoPlaybackPreferencesStore`、`PipRecoveryStore`、`ShaderDiscoveryService`、`MpvThumbnailService`、`VideoBundleLoader`、`VideoWorkBundle`、`VideoLaunchRequest`。
- 控制器与页面组件：`VideoPlaybackController`、`EmbeddedVideoPage`、`EmbeddedVideoOverlays`、`VideoTouchGestureLayer`、`VideoSideSheet`、`VideoProbeOverlay`、`VideoFloatingMiniPlayer`、`SettingsPlayersPanel`、`SettingsExternalToolsPanel`。

## 验证门禁

```powershell
dart run tool/verify.dart guard
dart run tool/verify.dart analyze
dart run tool/verify.dart test packages/features/feature_player_video
pwsh -NoProfile -File scripts/check_comments.ps1
```
