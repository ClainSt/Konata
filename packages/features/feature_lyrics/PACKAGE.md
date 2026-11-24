# feature_lyrics

Konata v3 多源竞速歌词引擎、逐字扫白渲染、双语对齐、三级偏移校准与离线评测业务包。

## 职责边界

- 完整承接 `4ee643f` 含双语修复 `93b7ac6` 的歌词清洗、合并、QRC/YRC/TTML 解析与多源竞速，持久化切换至 `konata_storage`（`lyric_cache_entries` + `lyric_user_overrides`）。
- 仅依赖 `flutter/widgets.dart`、`konata_design_system`、`konata_contracts`、`konata_storage`、`engine_*`，严禁横向导入 `feature_player_audio` 或直引 `material.dart`/`material_ui`。
- 注册 `PlayerSidePanelContribution(mode: audio)`、`LyricSourceProviderContribution`、`SyncSliceContributor(lyric_overrides_slice)` 与 `SettingsSectionContribution`，含离线评测 `tool/lyric_bench.dart`。
