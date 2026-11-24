# feature_scan_viewer

Konata v3 独立扫图画廊与有界内存滑窗灯箱业务包。

## 职责边界

- 独立拆包并通过 `DetailTabContribution` 动态挂载至作品详情页（删除本包目录与壳层 1 行清单注册即可零报错编译）。
- 仅依赖 `flutter/widgets.dart`、`konata_design_system`、`konata_contracts`、`konata_storage`、`engine_sources`、`engine_scraping`，严禁直接导入 `material.dart`/`material_ui` 或横向依赖其他 Feature。
- `lib/src/state/` 与 `lib/src/data/` 保持 0 Riverpod 纯 Dart 构造函数注入。
- 核心能力：64KB 帧头宽高比探测、按源严格并发限流微缩图调度（Local 4 / SMB 2 / WebDAV 严格 1 + LIFO 抢占）、双模式画廊（自适应瀑布流 / 整齐网格）、有界 96MB 内存滑窗原图灯箱（原图零落盘）。
