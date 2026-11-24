# feature_sync

Konata v3 同软件跨设备分片同步与本地 `.konata` 选择性备份恢复业务包。

## 职责边界

- 以统一 `SyncSliceContributor` 协议聚合内置切片（`prefs_slice`、`playback_history_slice`、`library_catalog_slice`）与外部业务包注册切片（如 `lyric_overrides_slice`）。
- 完整保留 `ArtworkRef` 同步隔离规则（绝不泄漏本机路径）、敏感凭据零出库与 `303e408` 完整媒体库直通同步能力。
- 仅依赖 `flutter/widgets.dart`、`konata_design_system`、`konata_contracts`、`konata_storage`、`engine_*`，注册 `SettingsSectionContribution` 与 `SyncSliceContributor`。
