# feature_sources

Konata v3 媒体源管理与扫库触发纵向全栈自治业务包。

## 职责边界

- 仅依赖 `flutter/widgets.dart`、`konata_design_system`、`konata_contracts`、`konata_storage`、`engine_sources`、`engine_scraping`，严禁直接导入 `material.dart`/`material_ui` 或横向依赖其他 Feature。
- `lib/src/state/` 与 `lib/src/data/` 保持 0 Riverpod 纯 Dart 构造函数注入，Riverpod 仅留在 `providers.dart`、`manifest.dart` 与 `ui/`。
- 核心能力：Local / WebDAV / SMB 媒体源增删改与测试连通（密码仅入 `SecureStoragePort`）、目录选择器、忽略目录管理、扫库与元数据刮削进度展示；通过 `FeatureManifest` 注册顶层 `sources` 导航分区。
