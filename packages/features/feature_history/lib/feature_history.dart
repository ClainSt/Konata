/// Konata v3 日记式播放记录时间轴业务包唯一公开出口。
///
/// 严禁跨包导入本包内部路径；所有调用方统一导入本文件。
library;

export 'src/data/history_timeline_models.dart'
    show
        HistoryDayGroup,
        HistoryEntryView,
        HistoryMediaFilter,
        HistoryTimelineGrouper,
        HistoryWorkGroupEntry;
export 'src/manifest.dart' show featureHistoryManifest;
export 'src/providers.dart'
    show
        FeatureHistoryDependencies,
        featureHistoryDependenciesProvider,
        historyControllerProvider;
export 'src/state/history_controller.dart'
    show HistoryController, HistorySelectionAction;
export 'src/ui/playback_history_cards.dart'
    show HistoryDaySectionView, HistoryWorkTimelineCard;
export 'src/ui/playback_history_page.dart' show PlaybackHistoryPage;
export 'src/ui/playback_history_sub_cards.dart'
    show
        HistoryArtworkLoader,
        HistoryExpandedEpisodeRow,
        HistoryPathArtworkLoader,
        HistoryProgressMetaRow,
        HistoryThumbnail;
