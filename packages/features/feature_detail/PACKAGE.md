# feature_detail

Konata v3 番剧详情页、正片/特典/CD 编排、正片抽帧补图与元数据编辑重刮纵向自治业务包。

## 职责边界

- 仅依赖 `flutter/widgets.dart`、`konata_design_system`、`konata_contracts`、`konata_storage`、`engine_sources`、`engine_scraping`、`engine_playback`，严禁直接导入 `material.dart`/`material_ui` 或横向依赖其他 Feature（例如扫图画廊仅经 `DetailTabContribution` 动态挂载）。
- `lib/src/state/` 与 `lib/src/data/` 保持 0 Riverpod 纯 Dart 构造函数注入。
- 核心能力：三端同源详情舞台（背景原画、透明标题徽标与自适应可读性、风格化无徽标标题、系列切换下拉）、正片/特典/CD 分组与版本切换、正片单并发流式抽帧补图、实时重刮进度胶囊、封面/背景/徽标编辑与裁切、人工锁与系列编组管理。
