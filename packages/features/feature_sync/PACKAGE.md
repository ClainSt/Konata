# `feature_sync`

Konata 跨设备协同同步与本地 `.konata` 备份还原独立特性包。

## 核心职责

1. **统一同步切片引擎（`SyncSliceContributor`）**
   - `PrefsSyncSlice`（`prefs_slice`）：基于 `ScopedPrefsStore` 执行白名单/黑名单过滤敏感凭据与本机绝对路径，按时间戳执行确定性合并并保护 `SyncPolicy.deviceLocal` 配置。
   - `PlaybackHistorySyncSlice`（`playback_history_slice`）：基于 `PlaybackRecordDao.listAllWithTombstones()` 执行跨数据源聚类、完播态单调合并、最大观看进度保留及软删除墓碑裁决。
   - `LibraryCatalogSyncSlice`（`library_catalog_slice`）：基于 `WorkDao` 与媒体库完整表集同步作品、合集编组、标签、人工锁定态与忽略目录，严格遵守 `ArtworkRef.localCustom -> null` 序列化铁律。
   - 外部切片热插拔：通过 `FeatureSyncDependencies.extraSlices` 动态接入其他业务模块切片，零跨包导入。
2. **本地 `.konata` 备份与干跑预览恢复（`KonataBackupService`）**
   - 按勾选切片打包为带 `schemaVersion`、`deviceId`、`SHA-256` 校验和与切片清单的自描述压缩归档；
   - 通过 `BackupFilePort` 完成跨平台存取，恢复前执行干跑 `planMerge` 预览新增/更新/删除计数并在统一跨库写事务中原子落盘。
3. **WebDAV 多设备分片同步（`WebDavSyncTransport` + `WebDavSyncCoordinator`）**
   - 远端固定采用 `manifest.json` + `slices/<sliceId>_<deviceId>.json.gz` 隔离布局；
   - 通过切片主体确定性 `SHA-256` 比对实现未变分片零下载与零上传；
   - WebDAV 服务器配置存入 `ScopedPrefsStore`（命名空间 `sync_webdav`），密码严格加密存储于 `SecureStoragePort`。
4. **状态控制、事件联动与设置面板**
   - `SyncBackupController` 管理导出勾选、导入干跑预览、WebDAV 连通性测试与一键/自动同步调度，并在落盘后通过 `DomainEventBus` 发布 `SyncCompletedEvent`；
   - `SettingsBackupSyncPanel` 与 `featureSyncManifest` 向设置页注册同步面板。
