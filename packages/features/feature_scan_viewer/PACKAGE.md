# feature_scan_viewer

Konata v3 独立扫图画廊、按源并发微缩图调度与有界 96 MiB 内存滑窗灯箱纵向业务包。

## 职责边界

- **独立可插拔切片**：严禁导入 `feature_detail`、`feature_library`、`feature_sources` 等任意横向 Feature；仅通过 `DetailTabContribution(id: 'scan_viewer', label: 'Scan', iconKey: 'scan_viewer', order: 40, ...)` 向详情页声明挂载能力（删除本包与壳层 1 行清单注册即可零报错编译）。
- **UI 框架与状态严格隔离**：
  - 全包仅导入 `package:flutter/widgets.dart`、`dart:ui` 与 `package:konata_design_system/konata_design_system.dart`，严禁直接导入 `material.dart`、`cupertino.dart`、`material_ui` 或 `cupertino_ui`；
  - `lib/src/data/` 与 `lib/src/state/` 保持零 Riverpod 纯构造函数注入，Riverpod 仅留在 `lib/src/providers.dart`、`lib/src/manifest.dart` 与 `lib/src/ui/`。
- **按源分级并发与原图零落盘红线**：
  - 微缩图生成并发上限严格锁定：`Local 4 / SMB 2 / WebDAV 严格串行 1 + LIFO 抢占取消`（卡片划走立即 `subscription.cancel()` + `close()`）；
  - 宽高比帧头预热仅读取已缓存 `.webp` 前 32 字节或本地磁盘文件前 64 KB（`ImageHeaderParser`），对未缓存远程源零探测请求；
  - 微缩图经 `CompactWebpEncoder` 压缩后由 `PhotosStorage` 落盘 `photos/<作品>/scans/<hash>.webp`；
  - 灯箱高清原图严格零落盘，受单帧 64 MiB 安全护栏与有界 96 MiB 内存滑窗（`ScanLightboxMemoryWindow`，按最远距离淘汰）约束，关闭灯箱即同步全量驱逐释放内存。

- 二级分卷筛选仅在存在多个有效 Scan 分组时展示；画廊与灯箱共用分组判定，单一分组直接展示全部图片。

## 公开出口符号

- **清单与可用性**：`featureScanViewerManifest`、`createFeatureScanViewerManifest`、`ScanViewerAvailability`
- **依赖注入**：`FeatureScanViewerDependencies`、`ScanWindowFullscreenPort`、`featureScanViewerDependenciesProvider`、`scanThumbnailSchedulerProvider`、`scanLightboxLoaderProvider`
- **数据与调度**：`ScanThumbnailScheduler`、`ScanThumbnailTicket`、`ScanSourceStreamOpener`、`ScanLightboxLoader`、`ScanImageLoadHandle`、`ScanLightboxMemoryWindow`、`ScanMemoryWindowEntry`、`ScanGalleryRepository`、`ScanWorkDataset`、`ScanGalleryMode`、`ScanGalleryDensity`、`ScanGalleryPrefs`、`scanGalleryPrefsSlice`
- **状态控制**：`ScanGalleryController`、`ScanGalleryState`
- **界面组件**：`ScanGalleryTabHost`、`ScanGalleryView`、`ScanThumbnailCard`、`ScanLightboxDialog`、`showScanLightboxDialog`、`ScanTapCallback`

## 依赖关系

- 底座：`konata_contracts`、`konata_storage`、`konata_design_system`
- 引擎：`engine_sources`、`engine_scraping`
- 工具：`flutter`、`flutter_riverpod`、`path`
- 扫图画廊直接监听媒体版本、作品、系列及媒体源表提交；系列成员变更后自动重算共享范围，失效分卷回退全部，切换作品复用订阅且保留手动刷新模式。
