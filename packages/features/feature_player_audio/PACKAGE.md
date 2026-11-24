# feature_player_audio

Konata v3 全屏流光音乐舞台、专辑队列、发烧音频安全链与悬浮小窗纵向自治业务包。

## 职责边界

- **严格零横向导入**：仅依赖 `flutter/widgets.dart`、`konata_design_system`、`konata_contracts`、`konata_storage`、`engine_sources`、`engine_playback`，绝不导入 `feature_lyrics` 或直引 `material.dart`/`cupertino.dart`/`material_ui`/`cupertino_ui`。
- **Salt 级恒定深邃流光舞台与三端定版布局**：
  - 四象限高饱和丝绒流光取色（`ArtworkPaletteCache` / `clusterAuroraPaletteArgb`）与恒定深邃 `#0E0B12` 暗光域（`AudioAuroraBackdrop`，严禁随浅色系统主题漂白，全舞台统一纯白发光排版）；
  - 桌面与平板宽屏双栏（`DesktopAudioDualStage`）：左侧大占比无硬白边封面配模糊渐变水面倒影，右侧大空气感歌词与一键队列切换，顶栏静默隐形悬停亮显并保留宿主窗口控制，底部超轻烟熏玻璃顶边发光胶囊（`AudioPlaybackCapsule`）；
  - Android 手机锁纯竖屏（`PortraitPhoneAudioStage` + `DeviceOrientation.portraitUp`）：极简留白顶栏与歌词态中央淡入迷你封面返回胶囊、曲名右侧直显格式徽标、移除作品详情入口、无损输出链路与动态 `extraSidePanels` 收口于右上角统一暗色玻璃菜单。
- **可插拔歌词协同**：所有歌词交互通过 `konata_contracts` 中的可选 `LyricDisplayPort`（仅在切歌、列表更新或停播时低频触发）、`AudioLyricsViewportBuilder` 与 `PlayerSidePanelContribution(supportedModes: {PlayerMediaMode.audio})` 装配；当歌词端口与视口均未注入时自动退化为独立纯音频舞台且零报错运行。
- **零框架污染状态内核**：`lib/src/data/` 与 `lib/src/state/` 严格 0 Riverpod；播放位置/总时长/播放态直连叶子 `ValueNotifier<Duration>` / `ValueNotifier<bool>`，迷你唱片拖拽坐标直连 `ValueNotifier<Offset>` 并被 `RepaintBoundary` 隔离，暂停或隐藏时立刻注销属性监听与动画计时器。
- **发烧安全输出链路**：全量托管 `UnifiedPlaybackEngine` 四维代数隔离与 `AudiophileSafetyCoordinator`，默认开启 `-12 dBFS` 防爆耳安全上限，支持 150ms S 型微淡入、`.cue` 分轨动态展开/无感切换、`ScopedPrefsStore(playback_audio)` 偏好持久化和桌面端 `PlaybackHostWindowPort` 置顶便携小窗切换。

## 公开出口

- 数据模型与队列：`AudioPlaybackPreferences`、`AudioPlaybackPrefsData`、`AudioReplayGainMode`、`AudioPlaybackQueueBuilder`、`AudioQueueItem`、`AudioPlaybackAssets`、`ArtworkPaletteCache`、`SmartCoverAlignmentCache`
- 控制器：`AudioPlaybackController`（含 `positionListenable`、`durationListenable`、`playingListenable`、`activeListenable`、`snapshotListenable`）
- 界面组件：`ImmersiveAudioPage`、`MiniAudioBar`、`SettingsAudioPanel`、`AudioLyricsViewportContext`、`AudioLyricsViewportBuilder`、`showAudiophileSafetyDialog`
- 装配契约与清单：`FeaturePlayerAudioDependencies`、`featurePlayerAudioDependenciesProvider`、`audioPlaybackControllerProvider`、`audioPlaybackPrefsRepoProvider`、`featurePlayerAudioManifest`
