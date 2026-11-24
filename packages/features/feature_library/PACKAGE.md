# feature_library

Konata v3 媒体库海报墙、本地检索筛选、作品管理与待复核纠错纵向自治业务包。

## 职责边界

- 仅依赖 `flutter/widgets.dart`、`konata_design_system`、`konata_contracts`、`konata_storage`、`engine_scraping`，严禁直接导入 `material.dart`/`material_ui` 或横向依赖其他 Feature。
- `lib/src/data/` 与 `lib/src/state/` 保持 0 Riverpod 纯 Dart 构造函数注入，Riverpod 仅留在 `providers.dart`、`manifest.dart` 与 `ui/`。
- 核心能力：三端自适应海报墙（保留高速滚动优化与受控图像分档解码）、完整 `20902` 汉字拼音自然排序与前缀搜索筛选、隐藏/恢复/合并/删除作品管理（仅软删除墓碑与清理本机 `photos/` 艺术图缓存，绝不删除物理媒体文件）、待复核与手动匹配纠偏。

## 公开契约

- 统一出口：`package:feature_library/feature_library.dart`
- 扩展清单：`featureLibraryManifest`（注册 `id: 'library'` 顶层导航分区，`order: 10`）
- 注入容器：`FeatureLibraryDependencies` 与 `featureLibraryDependenciesProvider`
- 零 Riverpod 数据与状态控制：`ChinesePinyinCollator`、`LibrarySearchMatcher`、`LibraryController`、`WorkManagementController`、`LibraryFilterPrefs`
- 视图与毛玻璃弹窗：`LibraryPage`、`PosterCard`、`ManagedImage`、`showReviewDialog`、`showHiddenWorksDialog`、`showManualMatchDialog`、`showWorkMergeTargetDialog`、`showWorkMergeSelectionDialog`、`WorkMergeSelection`、`MergeVideoCategoryMode`、`showDeleteWorkDialog`、`showHideWorkDialog`、`showSourceFilesReviewDialog`
