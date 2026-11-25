# feature_sources

Konata v3 媒体源管理与扫库触发纵向全栈自治业务包。

## 职责边界

- 仅依赖 `flutter/widgets.dart`、`konata_design_system`、`konata_contracts`、`konata_storage`、`engine_sources`、`engine_scraping`，严禁直接导入 `material.dart`/`material_ui` 或横向依赖其他 Feature。
- `lib/src/state/` 保持 0 Riverpod 纯 Dart 构造函数注入，Riverpod 仅留在 `providers.dart`、`manifest.dart` 与 `ui/`。
- 核心能力：Local / WebDAV / SMB 媒体源差异化卡片与状态指示、增删改与测试连通（密码仅入 `SecureStoragePort`）、目录与文件浏览器及多选作用域管理、忽略目录管理、扫库与元数据刮削实时进度状态机与分标签详情监控；移除媒体源仅写入本地数据库软删除墓碑并清理安全凭据，绝不触碰或删除物理媒体文件。

## 公开契约

- 统一出口：`package:feature_sources/feature_sources.dart`
- 扩展清单：`featureSourcesManifest`（注册 `id: 'sources'` 顶层导航分区，`order: 20`）
- 注入容器：`FeatureSourcesDependencies` 与 `featureSourcesDependenciesProvider`
- 响应式数据流：`mediaSourcesStreamProvider`、`sourceStatsStreamProvider`、`ignoredFoldersStreamProvider`
- 零 Riverpod 状态控制器：`SourcesController`、`SourceScrapeController`、统计摘要 `SourceLibraryStats` 与密封阶段状态机 `ScrapeTaskPhase`
- 视图与毛玻璃弹窗：`SourcesPage`、`ScrapeProgressBanner`、`TmdbScrapeGuardBanner`、`ScanProgressStatChip`、`ScanVisitedFoldersPane`、`ScanPendingReviewTab`、`SourceBrowserEntryRow`、`SourceBrowserFormatters`、`SourceSelectedScopePanel`、`showSourceBrowserHelpDialog`、`showSourceEditorDialog`、`showSourceFolderPickerDialog`、`showScanProgressDialog`、`showDeleteSourceDialog`

- 云盘媒体源由宿主注入无凭据账号地址及 CloudAccountSignInPort；新增源须连通，既有绑定不可改写。授权与连通性检测状态分离，未配置客户端时不开放短信入口。
