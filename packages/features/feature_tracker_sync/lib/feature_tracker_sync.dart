/// Konata v3 第三方追番平台进度同步框架唯一公开出口。
///
/// 严禁跨包导入本包内部路径；所有调用方统一导入本文件。
library;

export 'src/data/bangumi_sync_client.dart' show BangumiSyncClient;
export 'src/data/bangumi_sync_config_store.dart' show BangumiSyncConfigStore;
export 'src/data/bangumi_sync_models.dart'
    show
        BangumiAlignedEpisodePlan,
        BangumiApiException,
        BangumiAuthException,
        BangumiCollectionType,
        BangumiEpisodeAligner,
        BangumiEpisodeWatchStatus,
        BangumiLibrarySyncReport,
        BangumiRemoteEpisodeProgress,
        BangumiSyncConfig,
        BangumiSyncMode,
        BangumiSyncModeX,
        BangumiUserProfile,
        BangumiWorkSyncResult;
export 'src/data/bangumi_tracker_provider.dart'
    show BangumiTrackerProvider, DelegatingBangumiTrackerProvider;
export 'src/manifest.dart' show featureTrackerSyncManifest;
export 'src/providers.dart'
    show
        FeatureTrackerSyncDependencies,
        bangumiSyncClientProvider,
        bangumiSyncConfigStoreProvider,
        bangumiTrackerProvider,
        featureTrackerSyncDependenciesProvider,
        trackerSyncCoordinatorProvider;
export 'src/state/tracker_sync_coordinator.dart'
    show TrackerSubjectResolver, TrackerSyncCoordinator;
export 'src/ui/settings_bangumi_sync_card.dart' show SettingsBangumiSyncCard;
