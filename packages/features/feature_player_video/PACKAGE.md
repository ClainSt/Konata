# feature_player_video

Konata v3 视频播放舞台、触控手势、侧栏控制与悬浮小窗纵向自治业务包。

## 职责边界

- 仅依赖 `flutter/widgets.dart`、`konata_design_system`、`konata_contracts`、`konata_storage`、`engine_sources`、`engine_playback`，严禁直引 `material.dart`/`material_ui`、桌面原生插件或其他 Feature。
- `lib/src/state/` 与 `lib/src/data/` 严格 0 Riverpod，高频进度与拖拽坐标直连叶子 `ValueNotifier`。
- 动态消费 `PlayerSidePanelContribution(mode: video)`，并通过 `SettingsSectionContribution` 注册播放画质与桌面外置播放器设置。
