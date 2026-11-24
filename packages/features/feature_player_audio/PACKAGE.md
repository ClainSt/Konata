# feature_player_audio

Konata v3 全屏流光音乐舞台、专辑队列、发烧音频安全链与悬浮小窗纵向自治业务包。

## 职责边界

- 仅依赖 `flutter/widgets.dart`、`konata_design_system`、`konata_contracts`、`konata_storage`、`engine_sources`、`engine_playback`，严禁横向导入 `feature_lyrics` 或直引 `material.dart`/`material_ui`。
- 歌词能力仅通过 `LyricDisplayPort` 与 `PlayerSidePanelContribution(mode: audio)` 动态注入，确保歌词模块独立可插拔。
- `lib/src/state/` 与 `lib/src/data/` 严格 0 Riverpod，高频进度时钟直连叶子 `ValueNotifier`。
