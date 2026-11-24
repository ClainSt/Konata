# feature_library

Konata v3 媒体库海报墙、本地检索筛选、作品管理与待复核纠错纵向自治业务包。

## 职责边界

- 仅依赖 `flutter/widgets.dart`、`konata_design_system`、`konata_contracts`、`konata_storage`、`engine_sources`、`engine_scraping`，严禁直接导入 `material.dart`/`material_ui` 或横向依赖其他 Feature。
- `lib/src/state/` 与 `lib/src/data/` 保持 0 Riverpod 纯 Dart 构造函数注入。
- 核心能力：三端自适应海报墙（保留高速滚动优化与有界图像缓存）、拼音与多维搜索筛选、隐藏/恢复/合并/删除作品管理（仅软删除墓碑，绝不删用户物理文件）、待复核入口与手动匹配纠错；通过 `FeatureManifest` 注册顶层 `library` 导航分区。
