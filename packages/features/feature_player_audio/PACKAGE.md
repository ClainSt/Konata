# feature_player_audio

Konata v3 全屏流光音乐舞台、专辑队列、发烧音频安全链与悬浮小窗纵向自治业务包。

## 职责边界

- **严格零横向导入**：仅依赖 `flutter/widgets.dart`、`konata_design_system`、`konata_contracts`、`konata_storage`、`engine_sources`、`engine_playback`，绝不导入 `feature_lyrics` 或直引 `material.dart`/`cupertino.dart`/`material_ui`/`cupertino_ui`。
- **可插拔歌词协同**：所有歌词交互通过 `konata_contracts` 中的可选 `LyricDisplayPort`（仅在切歌、列表更新或停播时低频触发）、`AudioLyricsViewportBuilder` 与 `PlayerSidePanelContribution(supportedModes: {PlayerMediaMode.audio})` 装配；当歌词端口与视口均未注入时自动退化为独立纯音频舞台且零报错运行。
- **零框架污染状态内核**：`lib/src/data/` 与 `lib/src/state/` 严格 0 Riverpod；播放位置/总时长/播放态直连叶子 `ValueNotifier<Duration>` / `ValueNotifier<bool>`，迷你唱片拖拽坐标直连 `ValueNotifier<Offset>` 并被 `RepaintBoundary` 隔离，暂停或隐藏时立刻注销属性监听与动画计时器。
- **发烧安全输出链路**：全量托管 `UnifiedPlaybackEngine` 四维代数隔离与 `AudiophileSafetyCoordinator`，默认开启 `-12 dBFS` 防爆耳安全上限，支持 150ms S 型微淡入、`.cue` 分轨动态展开/无感切换、`ScopedPrefsStore(playback_audio)` 偏好持久化和桌面端 `PlaybackHostWindowPort` 置顶便携小窗切换。

## 公开出口

- 数据模型与队列：`AudioPlaybackPreferences`、`AudioPlaybackPrefsData`、`AudioReplayGainMode`、`AudioPlaybackQueueBuilder`、`AudioQueueItem`、`AudioPlaybackAssets`、`ArtworkPaletteCache`、`SmartCoverAlignmentCache`
- 控制器：`AudioPlaybackController`（含 `positionListenable`、`durationListenable`、`playingListenable`、`activeListenable`、`snapshotListenable`）
- 界面组件：`ImmersiveAudioPage`、`MiniAudioBar`、`SettingsAudioPanel`、`AudioLyricsViewportContext`、`AudioLyricsViewportBuilder`、`showAudiophileSafetyDialog`
- 装配契约与清单：`FeaturePlayerAudioDependencies`、`featurePlayerAudioDependenciesProvider`、`audioPlaybackControllerProvider`、`audioPlaybackPrefsRepoProvider`、`featurePlayerAudioManifest`
