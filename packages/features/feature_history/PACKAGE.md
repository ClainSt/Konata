# `feature_history`

Konata 日记式播放记录时间轴业务包，向宿主贡献主导航「播放记录」入口并支持三端自适应展示。

## 公开出口

统一从 `package:feature_history/feature_history.dart` 导入，禁止跨包引用 `src/` 内部路径：

- 依赖与清单：`FeatureHistoryDependencies`、`featureHistoryDependenciesProvider`、`featureHistoryManifest`
- 状态与分组：`HistoryController`、`HistorySelectionAction`、`historyControllerProvider`、`HistoryTimelineGrouper` 与时间轴视图模型
- 界面组件：`PlaybackHistoryPage`、`HistoryDaySectionView`、`HistoryWorkTimelineCard`、`HistoryExpandedEpisodeRow`、`HistoryProgressMetaRow`、`HistoryThumbnail`、`HistoryArtworkLoader`、`HistoryPathArtworkLoader`

## 核心职责与边界

- **自然日分组与折叠聚合**：按本地自然日（`今天` / `昨天` / `YYYY.MM.DD`）与作品二级聚合，支持视频与音频筛选及关键字搜索。
- **跨包路由导航**：点击续播或查看详情全部经 `AppNavigator` 路由分发，不直接依赖播放器包或详情包。
- **同步墓碑删除**：单条删除、整组删除与清空全部仅调用 `PlaybackRecordDao.softDelete` / `clearAll` 写入软删除墓碑，绝不触碰任何物理媒体文件。
- **状态零 Riverpod**：`lib/src/data/` 与 `lib/src/state/` 不引入 `flutter_riverpod`，UI 仅使用 `konata_design_system` 与 Flutter 基础库。

- 音频历史续播按记录归属和物理版本导航，兼容 #cue: 与 ::track_ 轨号标识；已听完以零秒起播。
