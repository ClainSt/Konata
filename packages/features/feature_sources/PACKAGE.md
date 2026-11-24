# feature_sources

Konata v3 媒体源管理与扫库触发纵向全栈自治业务包。

## 职责边界

- 仅依赖 `flutter/widgets.dart`、`konata_design_system`、`konata_contracts`、`konata_storage`、`engine_sources`、`engine_scraping`，严禁直接导入 `material.dart`/`material_ui` 或横向依赖其他 Feature。
- `lib/src/state/` 保持 0 Riverpod 纯 Dart 构造函数注入，Riverpod 仅留在 `providers.dart`、`manifest.dart` 与 `ui/`。
- 核心能力：Local / WebDAV / SMB 媒体源增删改与测试连通（密码仅入 `SecureStoragePort`）、目录范围选择器、忽略目录管理、扫库与元数据刮削实时进度状态机；移除媒体源仅写入本地数据库软删除墓碑并清理安全凭据，绝不触碰或删除物理媒体文件。

## 公开契约

- 统一出口：`package:feature_sources/feature_sources.dart`
- 扩展清单：`featureSourcesManifest`（注册 `id: 'sources'` 顶层导航分区，`order: 20`）
- 注入容器：`FeatureSourcesDependencies` 与 `featureSourcesDependenciesProvider`
- 零 Riverpod 状态控制器：`SourcesController`、`SourceScrapeController` 与密封阶段状态机 `ScrapeTaskPhase`
- 视图与毛玻璃弹窗：`SourcesPage`、`ScrapeProgressBanner`、`TmdbScrapeGuardBanner`、`showSourceEditorDialog`、`showSourceFolderPickerDialog`、`showScanProgressDialog`、`showDeleteSourceDialog`
