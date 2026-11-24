# feature_player_video

全屏纯横屏视频播放舞台、单层通透毛玻璃播控胶囊、16:9 可拖拽悬浮小窗与音画设置业务包。

## 职责边界

- **依赖范围**：仅依赖 `konata_contracts`、`konata_storage`、`konata_design_system`、`engine_sources`、`engine_playback`、`flutter`、`flutter_riverpod` 与 `path`；严格隔离兄弟业务包与平台原生插件。
- **界面约束**：界面层仅使用 `package:flutter/widgets.dart`、`services.dart`、`foundation.dart` 与 `package:konata_design_system/konata_design_system.dart` 导出原语。
- **三端横屏与交互规范**：
  - Windows / Android 平板 / Android 手机统一锁定纯横屏全屏视频舞台（Android 进入自动锁定 `landscapeLeft` / `landscapeRight`，退出或销毁自动恢复原方向）；
  - 顶部单层高通透毛玻璃长胶囊（挂载 `KonataDesktopWindowChromeScope` 无框窗口三键与拖拽区、规格标签、小窗/PiP、纯音频、探针、桌面外部接力与画面设置）；
  - 底部居中 `52px` 单层毛玻璃胶囊：顶边紧贴 `26px` 圆角切点连贯进度条（常态 `3.0px` / 悬停 `4.5px`）、圆心严格居中对齐轨道中心线的播放头圆点、顶边平齐（`y = 0`）内指圆角倒三角（`10×7.5px`）章节点与磁吸缩略图预览浮泡；
  - 底栏呼出自动按真实占高与约 `16dp` 呼吸空隙经 `VideoPlaybackController.updateHudSubtitleLift` 同步抬升 `libmpv` `sub-pos` / `secondary-sub-pos`，OSD 隐藏瞬间立即复原 `0.0` 且不干扰 ASS `\pos()`；
  - 触屏左侧防误触锁钮与右侧 5-Tab 侧滑面板（底部自动避让播控胶囊上方呼吸间距）。
- **状态分层**：`lib/src/data/` 与 `lib/src/state/` 保持零状态管理框架耦合，仅通过 `lib/src/providers.dart` 提供依赖装配与控制器生命周期管理；高频播放进度与悬浮小窗拖拽偏移直连叶子 `ValueNotifier`。

## 公开出口

- 清单与依赖：`featurePlayerVideoManifest`（`id: 'feature_player_video'`）、`FeaturePlayerVideoDependencies`、`featurePlayerVideoDependenciesProvider`、`videoPlaybackControllerProvider`、`activeVideoSessionManagerProvider`、`ActiveVideoSessionManager`。
- 自治配置与服务：`VideoPlaybackPreferences`（`playback_video` 命名空间切片）、`VideoPlaybackPreferencesStore`、`PipRecoveryStore`、`ShaderDiscoveryService`、`MpvThumbnailService`、`VideoBundleLoader`、`VideoWorkBundle`、`VideoLaunchRequest`。
- 控制器与页面组件：`VideoPlaybackController`、`EmbeddedVideoPage`、`EmbeddedVideoOverlays`、`VideoPlaybackCapsule`、`VideoTouchGestureLayer`、`VideoSideSheet`、`VideoProbeOverlay`、`VideoFloatingMiniPlayer`、`SettingsPlayersPanel`、`SettingsExternalToolsPanel`。

## 验证门禁

```powershell
dart run tool/verify.dart guard
dart run tool/verify.dart analyze packages/features/feature_player_video
dart run tool/verify.dart test packages/features/feature_player_video
pwsh -NoProfile -File scripts/check_comments.ps1
```
