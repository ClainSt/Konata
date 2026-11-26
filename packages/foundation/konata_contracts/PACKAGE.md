# konata_contracts

## 职责边界
- Konata v3 最底层受保护契约包，**严格 0 Flutter、0 Riverpod、0 持久化实现依赖**。
- 定义全仓共享的强类型值对象、3 条合法跨包通信端口、7 大声明式扩展点契约，以及诊断日志/安全存储/存储根目录端口。
- 业务车道默认只读；确需修改契约须先在短分支合入 `main`。

## 唯一公开出口
- `package:konata_contracts/konata_contracts.dart`

## 核心导出符号
- **值对象与配置**：`WorkId`、`EpisodeId`、`SourceId`、`SeriesGroupId`、`VariantId`、`ArtworkRef`（`RemoteArtworkRef` / `LocalCustomArtworkRef`）、`ArtworkSource`、`ArtworkSlot`、`SyncPolicy`、`KonataPlatform`、`KonataLaneConfig`、领域共享枚举（`MediaSourceKind`、`TmdbMediaType`、`ScrapeStatus`、`EpisodeCategory`、`ExtraKind`、`AssetKind`、`SupplementaryAssetScope`）。
- **3 条跨包通信端口**：`AppNavigator`、`DomainEventBus`（`InMemoryDomainEventBus` + `sealed class DomainEvent`，严禁 `> 5Hz` 高频事件）、只读查询端口（`LibraryReadPort`、`PlaybackReadPort`、`PrefsReadPort`）。
- **基础设施端口**：`AssetDataLoaderPort`、`WorkManageDialogPort`、`EpisodeTitleFormatter`、`DiagnosticLogPort`（含 `DiagnosticSeverity`、`DiagnosticSubsystem`、`DiagnosticEvent`、`DiagnosticBreadcrumb`、`DiagnosticFaultSummary`、`DiagnosticSnapshotSection`、`DiagnosticTextSanitizer`）、`SecureStoragePort`、`StorageRootPort`。
- **7 大声明式扩展点**：`FeatureManifest`、`NavSectionContribution`、`SettingsSectionContribution`、`DetailTabContribution`、`DetailActionContribution`、`PlayerSidePanelContribution`、`DataProviderContribution`（含 `ProgressTrackerProvider`）、`SyncSliceContributor`（含 `SyncSlicePayload` / `SyncMergePlan` / `SyncTransactionContext`）。

同步切片事务应用采用非 Future 的 SyncApplyCompletion 完成标记；应用计划须在当前调用栈内完成并同步抛出失败，不能自行打开写事务、异步写入或绕过宿主事务句柄。

- 音频导航端口可选传递 CUE 轨号和轨内续播秒数；普通选曲及悬浮窗恢复不传历史参数。
