# feature_detail

Konata v3 番剧详情页、正片 / 特典 / CD 编排、正片单并发流式抽帧补图、实时元数据重刮与裁切精修纵向自治特性包。

## 职责边界

- **依赖隔离**：仅导入 `package:flutter/widgets.dart`、`konata_design_system`、`konata_contracts`、`konata_storage`、`engine_sources`、`engine_scraping`、`engine_playback`（UI 层额外允许 `flutter_riverpod`）。严禁直接导入 `material.dart`、`cupertino.dart`、`material_ui/*`、`cupertino_ui/*` 或横向互引 `feature_scan_viewer`、`feature_library`、`feature_sources`。
- **0 Riverpod 状态与数据层**：`lib/src/data/` 与 `lib/src/state/` 严格保持纯 Dart 构造函数注入，仅 `lib/src/providers.dart`、`lib/src/manifest.dart` 与 `lib/src/ui/` 使用 Riverpod。
- **跨包扩展挂载**：外部详情标签页（例如扫图画廊）通过注入的 `List<DetailTabContribution> detailTabs`（调用 `isVisibleForWork` 与 `viewBuilder(ViewSlotContext)`）动态挂载；外部动作按钮与菜单项通过 `List<DetailActionContribution> detailActions` 动态聚合；跨页播放与系列切换通过 `AppNavigator` 执行。
- **艺术图与只读媒体源边界**：严格遵循远程艺术图保存 `RemoteArtworkRef`、本机自定义/裁切保存 `LocalCustomArtworkRef`（写入 `PhotosStorage` 分目录），绝不向媒体源写回任何文件。
- 海报、背景、徽标与缩略图经薄适配统一使用 `KonataManagedImage`。媒体库经宿主复用本包的手动匹配、源文件复核与合并弹窗。

## 核心模块与公开出口

- **清单与依赖注入（`lib/src/manifest.dart`、`lib/src/providers.dart`）**：
  - `featureDetailManifest`（`FeatureManifest(id: 'feature_detail', displayName: '作品详情')`）；
  - `FeatureDetailDependencies`（完整承接 `databases`、`storageRoot`、`diagnosticLog`、`scopedPrefs`、`domainEventBus`、`navigator`、`filePicker`、`urlOpener`、`httpClient`、`gatewayFactory`、`streamBridge`、`warmupService`、`photosStorage`、`artworkCache`、`platform`、`detailTabs`、`detailActions`）与 `featureDetailDependenciesProvider`。
- **领域辅助与抽帧服务（`lib/src/data/`）**：
  - `DetailTitleTypographyResolver`、`ClearLogoLegibility`、`MediaDisplayFormatter`、`ArtworkCropMath`、`LocalArtworkCropper`；
  - `SeriesMemberLabelResolver` / `SeriesWorkMediaFilter`（同系列形态识别、简洁胶囊摘要、20+ 长系列多形态筛选与搜索）与 `ArtworkDominantColor`（竖版原画底部吸色适配深/浅主题溶底）；
  - `DetailDisplayPreferences` / `DetailDisplayPreferencesStore`（与设置中心共享 `feature_detail.display` 全部 10 个便携键与未知扩展字段透传）；
  - `MainEpisodeFrameExtractor`（全局单并发串行、`LibMpvClient` + `LocalStreamBridgePort` + `VideoFrameSelector`）与 `MainEpisodeFrameBackfillService`（严格仅对 `EpisodeCategory.main` 正片抽帧，绝不碰特典）；
  - `WorkArtworkOptionsService`、`DetailWorkActionsService`（支持封面/横版背景/`portraitBackdrop` 竖版原画锁定与重置，并同步发布 `LibraryWorkChangedEvent`）。
- **状态管理（`lib/src/state/`）**：
  - `WorkDetailController`（监听三库变更总线、`DomainEventBus` 与偏好切片；驱动静默预热、正片补图、人工锁定、系列编组与拆合操作）；
  - `WorkRescrapeState` 密封状态机（`WorkRescrapeIdle` / `WorkRescrapeRunning` / `WorkRescrapeSucceeded` / `WorkRescrapeFailed`）。
- **三端同源 UI 与弹窗（`lib/src/ui/`）**：
  - `WorkDetailPage`、`DetailWideOverlayStageLayout`、`DetailPortraitStageLayout`（Android 手机纯竖屏锁定与 `portraitBackdropRef` 吸色溶底；Windows/平板横屏清澈 16:9 原画舞台并完整保留桌面窗口控制栏；统一所有外部扩展动作进入唯一 `⚙`）；
  - `DetailHeroInfo`（统一保留 `[开始/继续播放]` + `[系列胶囊]` 双胶囊主操作行）、`DetailStylizedTitleBlock`、`SeriesSwitcherDropdown` + `showSeriesSelectorModal`（手机底部全宽抽屉 / 桌面平板居中宽弹窗，支持 `全部 / TV / 剧场版 / OVA` 筛选与实时搜索）；
  - `DetailSecondaryFilterBar`、`DetailBottomDrawer`（三端统一单条毛玻璃分类胶囊、展开态右端弹性伸出 `⊞`、彻底移除 `⌄`、三端保留横向大剧照选集卡轨道）、`EpisodeDrawerCard`、`CdDrawerCard`、`DetailGearMenu`、`DetailFullListDialog`；
  - `WorkArtworkPickerDialog`（含 `WorkArtworkKind.portraitBackdrop` 竖版无字原画挑选、本地裁切与重置）、`ArtworkCropDialog`、`VideoFrameCandidateTile`、`WorkManualEditDialog`、`ManualMatchDialog`、`SeriesManageDialog`、`VariantPickerDialog`、`EpisodeMediaInfoDialog`、`FileMappingPanel`、`EpisodeSlotPickerButton`、`SupplementaryScopePanel`、`SourceFilesReviewDialog`、`WorkMergeTargetDialog`。

## 验证说明

- 通过 `dart run tool/verify.dart guard` 边界检查、`dart run tool/verify.dart analyze packages/features/feature_detail` 零告警静态分析、`dart run tool/verify.dart test packages/features/feature_detail` 单元测试与多视口 Widget 测试，以及 `pwsh -NoProfile -File scripts/check_comments.ps1` 纯简体中文注释校验。
