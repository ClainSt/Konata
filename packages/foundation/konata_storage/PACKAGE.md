# konata_storage

## 职责边界
- Konata v3 受保护存储底座，**严格 0 Flutter、0 Riverpod、0 `build_runner` 依赖**，仅依赖 `konata_contracts`、`sqlite3` 与 `path`。
- 提供自研极薄纯 `sqlite3` 响应式引擎（`KonataSqliteEngine`）、三库物理分治（`library.db` / `user_state.db` / 惰性 `cache.db`）、强类型配置切片（`ScopedPrefsStore`）、结构化脱敏诊断日志存储（`DiagnosticLogStore`）及跨端便携路径服务（`PortableStorageRootService`）。

## 唯一公开出口
- `package:konata_storage/konata_storage.dart`

## 核心导出符号
- **响应式 SQLite 引擎**：`KonataSqliteEngine`、`SqliteTransaction`、`SqliteMigration`、`TableChangeBus`、`KonataDatabaseBundle`。
- **媒体资产库（`library.db`）**：`LibraryDatabase`、`MediaSourceDao`、`SeriesGroupDao`、`WorkDao`、`EpisodeDao`、`MediaVariantDao`、`IgnoredFolderDao`、`StorageLibraryReadAdapter` 及全部独立 `*_schema.dart` 列常量与记录模型。
- **用户态库（`user_state.db`）**：`UserStateDatabase`、`PlaybackRecordDao`、`ScopedPrefsDao`、`LyricUserOverrideDao`、`SyncMetaDao`、`TrackerSyncQueueDao`、`StoragePlaybackReadAdapter`。
- **惰性缓存库（`cache.db`）**：`CacheDatabase`（支持冷启动惰性打开与一键删库重建）、`ScrapeCandidateDao`、`LyricCacheDao`、`ArtworkNegativeCacheDao`、`CloudDriveEntryDao`（仅非敏感云盘目录快照，按媒体源隔离）。
- **配置、日志与路径服务**：`ScopedPrefsStore`、`TypedPrefsSlice`、`DiagnosticLogStore`、`PortableStorageRootService`、`InMemorySecureStorage`。

- **作品可见性契约**：library.db v4 原位移除废弃隐藏字段；未删除作品按匹配状态进入媒体库或复核队列，保留原 ID、系列和媒体关联。作品软删除在同一事务内收敛仍归属该作品的有效剧集和文件索引墓碑；同步可在关系写入后复用收敛方法。

- **受管图片精准清理**：PhotosStorage.deleteManagedArtworkFile 校验作品、槽位和真实路径；禁止以数据库任意路径直接删除外部文件。
