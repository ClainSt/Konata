# `feature_tracker_sync`

Konata 第三方追番平台进度同步业务包，提供可热插拔的多平台追番同步框架与官方直连版 Bangumi 番组计划适配器。

## 公开出口

统一从 `package:feature_tracker_sync/feature_tracker_sync.dart` 导入，禁止跨包引用 `src/` 内部路径：

- 依赖与清单：`FeatureTrackerSyncDependencies`、`featureTrackerSyncDependenciesProvider`、`featureTrackerSyncManifest`
- 数据与客户端：`BangumiSyncClient`、`BangumiSyncConfigStore`、`BangumiTrackerProvider`、`BangumiEpisodeAligner` 与相关强类型模型
- 状态协调：`TrackerSyncCoordinator`、`trackerSyncCoordinatorProvider`
- 界面组件：`SettingsBangumiSyncCard`

## 架构与安全约束

- **状态与数据零 Riverpod**：`lib/src/data/` 与 `lib/src/state/` 不引入 `flutter_riverpod`，仅通过 `lib/src/providers.dart` 完成薄依赖注入。
- **Bangumi 官方直连**：`BangumiSyncClient` 固定请求 `https://api.bgm.tv`，绝不将鉴权凭据发送至任何第三方中转或镜像节点。
- **凭据安全隔离**：PAT 仅保存于 `SecureStoragePort`，日志、SQLite 队列错误信息与异常输出前均强制脱敏。
- **离线排队与鉴权熔断**：监听 `DomainEventBus` 的 `EpisodeCompletionChangedEvent` 自动入队，网络异常按指数退避重试，遇到 401/403 立即标记不可重试并提示重新绑定 PAT。
