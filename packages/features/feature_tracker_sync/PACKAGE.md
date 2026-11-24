# feature_tracker_sync

Konata v3 第三方追番平台进度同步框架与首批内置 Bangumi 提供者业务包。

## 职责边界

- 面向 `ProgressTrackerProvider` 契约与 `user_state.db` 的通用 `tracker_sync_queue`（含 `tracker_id`），首批内置 `BangumiTrackerProvider`（PAT 鉴权仅走 `SecureStoragePort` 且只直连官方 `api.bgm.tv`）。
- 订阅 `DomainEventBus.on<EpisodeCompletionChangedEvent>()` 自动入队并支持离线退避重试。
- 删除本包与壳层 1 行清单注册即可零报错编译。
