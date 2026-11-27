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
   - 通过 `BackupFilePort` 完成跨平台存取，恢复前通过 `planMerge` 预览新增、更新和删除计数，确认后通过媒体库和用户状态库各自的事务写入所选切片。
   - 文件读取上限 32 MiB，gzip 解压累计上限 128 MiB；导出也遵守同一上限。切片标识与版本不兼容时拒绝恢复。旧版 v1/v2 快照经专用迁移后仅支持智能合并，v2 完整目录限空目标库并一次性恢复全部归档切片。可唯一解析的视频进度与墓碑按物理身份关联。
   - 旧普通音频按同作品的唯一曲名与可播放文件关联，音频墓碑通过同归档已解析的播放记录关联。旧 v2 作品墓碑须能关联归档内完整作品实体，较新墓碑保留作品、分集及媒体版本的软删除标记；较新整理状态墓碑抑制过期整理状态，完整目录内资料锁保持原值。缺少实体的作品墓碑、v1 作品或整理状态墓碑、含 CUE 的旧音频、独立音频墓碑、歧义关系和未映射偏好拒绝转换。艺术图仅迁移明确远程来源，外观偏好仅支持完整已知字段。
3. **WebDAV 多设备分片同步（`WebDavSyncTransport` + `WebDavSyncCoordinator`）**
   - 远端固定采用 `manifest.json` + `slices/<sliceId>_<deviceId>_<sha256>.json.gz` 隔离布局；
   - 通过切片主体确定性 `SHA-256` 比对实现未变分片零下载与零上传；
   - 新分片按内容版本命名并条件创建，读取时仍支持旧版 v2 清单引用的固定路径；清单使用强 ETag / If-Match 与首次创建 If-None-Match，412 冲突最多重试三次，仅合并本轮新增水位；
   - 所有参与设备须升级至支持条件写入的版本，服务器须正确执行 HTTP 前置条件；缺少强 ETag 时拒绝更新已有清单。暂不自动清理历史分片，避免误删正在被读取或尚未发布的分片；
   - WebDAV 服务器配置存入 `ScopedPrefsStore`（命名空间 `sync_webdav`），密码严格加密存储于 `SecureStoragePort`。
4. **状态控制、事件联动与设置面板**
   - `SyncBackupController` 管理导出勾选、导入干跑预览、WebDAV 连通性测试与一键/自动同步调度，并在落盘后通过 `DomainEventBus` 发布 `SyncCompletedEvent`；
   - `SettingsBackupSyncPanel` 与 `featureSyncManifest` 向设置页注册同步面板。

- 云盘媒体源仅同步合法无凭据虚拟地址与远端文件标识；未知来源、普通合并的标识冲突拒绝处理，授权由各设备单独完成。
- 音频历史匹配到本地媒体后沿用播放器的播放记录身份。CUE 分轨保留轨号，每轨的断点与删除墓碑独立应用。

WebDAV 同步边界：已启用切片在清单读取及冲突重读时校验贡献器版本（包括本机旧身份水位）；清单与非分片响应上限 4 MiB、压缩分片 32 MiB、解压正文 128 MiB，正文累计接收限时沿用请求超时（默认 15 秒）。超限或不兼容时停止同步，不降级为无条件写入。

恢复与 WebDAV 合并通过媒体库和用户状态库各自的事务应用所选切片。应用切片时发生 SQL 错误会回滚本轮两库，两库均成功提交后记录水位。两个 WAL 文件依次提交，提交期间进程中断或断电可能导致部分写入。
