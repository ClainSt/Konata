# feature_history

Konata v3 日记式播放记录时间轴与断点续播入口业务包。

## 职责边界

- 仅依赖 `flutter/widgets.dart`、`konata_design_system`、`konata_contracts`、`konata_storage`、`engine_playback`，严禁横向依赖其他 Feature 或直引 `material.dart`/`material_ui`。
- 通过 `FeatureManifest` 注册顶层 `history` 导航分区（权重 `30`），通过 `AppNavigator` 跳转详情或续播，删除记录仅写软删除墓碑不碰物理媒体文件。
