# feature_library

Konata v3 媒体库海报墙、本地检索筛选、作品管理与待复核纠错纵向自治业务包。

## 职责边界

- 仅依赖 `flutter/widgets.dart`、`konata_design_system`、`konata_contracts`、`konata_storage`、`engine_scraping`，严禁直接导入 `material.dart`/`material_ui` 或横向依赖其他 Feature。
- `lib/src/data/` 与 `lib/src/state/` 保持 0 Riverpod 纯 Dart 构造函数注入，Riverpod 仅留在 `providers.dart`、`manifest.dart` 与 `ui/`。
- 核心能力：三端自适应海报墙（保留高速滚动优化与受控图像分档解码）、完整 `20902` 汉字拼音自然排序与前缀搜索筛选、合并/删除作品管理（仅软删除墓碑与清理本机 `photos/` 艺术图缓存，绝不删除物理媒体文件）、待复核与手动匹配纠偏。

## 公开契约

- 统一出口：`package:feature_library/feature_library.dart`
- 扩展清单：`featureLibraryManifest`（注册 `id: 'library'` 顶层导航分区，`order: 10`）
- 注入容器：`FeatureLibraryDependencies`、`featureLibraryDependenciesProvider` 与宿主注入的 `workManageDialogPortProvider`
- 零 Riverpod 数据与状态控制：`ChinesePinyinCollator`、`LibrarySearchMatcher`、`LibraryController`、`WorkManagementController`、`LibraryFilterPrefs`
- 视图与毛玻璃弹窗使用 `LibraryPage`、`PosterCard`、`showReviewDialog`、`showDeleteWorkDialog`。艺术图经薄适配接入 `KonataManagedImage`，匹配、源文件复核与合并经 `WorkManageDialogPort` 复用详情模块。
- 拼音排序表在已有媒体数据需要汉字排序时由宿主资产端口装载。
- 媒体库全量刷新同轮请求合并，读取期间的新请求串行补跑，调用方等待本轮全部刷新完成。
- 海报墙仅提取压制组，复用解析器按需开关；完整季集和特典识别继续由入库流程负责。
- 搜索输入复用当前筛选及排序快照；数据、筛选或排序变化时同步重建，结果保持不可修改。
- 海报卡传递作品 ID 与 posters 槽位，启用生产分作品磁盘缓存；候选预览图仍无归属槽位。
- 海报加载直接复用 TmdbService 的缓存优先入口；未命中不重复探测，保留本地迁移、脏数据回源、清晰度与错误兜底语义。
- 海报长标题恢复按需全文提示，仅允许悬停的当前卡片检测省略；滚动冷却和后台视频播放抑制时回落普通文本。
