/// Konata v3 媒体源配置与扫库触发业务包唯一公开出口。
///
/// 严禁跨包导入本包内部路径；所有调用方统一导入本文件。
library;

export 'src/manifest.dart' show featureSourcesManifest;
export 'src/providers.dart'
    show
        FeatureSourcesDependencies,
        featureSourcesDependenciesProvider,
        ignoredFoldersStreamProvider,
        mediaSourcesStreamProvider,
        sourceCredentialStoreProvider,
        sourceScrapeControllerProvider,
        sourceStatsStreamProvider,
        sourcesControllerProvider;
export 'src/state/scrape_task_phase.dart'
    show
        ScrapeCancelledPhase,
        ScrapeCheckingIndexPhase,
        ScrapeCompletedPhase,
        ScrapeFailedPhase,
        ScrapeIdlePhase,
        ScrapeRunningPhase,
        ScrapeScanningPhase,
        ScrapeTaskPhase,
        ScrapeTaskStage;
export 'src/state/source_scope_prefs.dart'
    show SourceScopeMetadata, SourceScopePrefs;
export 'src/state/source_scrape_controller.dart'
    show SourcePendingReviewWork, SourceScrapeController;
export 'src/state/sources_controller.dart'
    show SourceActionResult, SourceLibraryStats, SourceTestResult, SourcesController;
export 'src/ui/delete_source_dialog.dart' show showDeleteSourceDialog;
export 'src/ui/scan_progress_dialog.dart' show showScanProgressDialog;
export 'src/ui/scan_progress_tabs.dart'
    show ScanPendingReviewTab, ScanProgressStatChip, ScanVisitedFoldersPane;
export 'src/ui/scrape_progress_banner.dart' show ScrapeProgressBanner;
export 'src/ui/source_editor_dialog.dart' show showSourceEditorDialog;
export 'src/ui/source_folder_picker_dialog.dart'
    show showSourceFolderPickerDialog;
export 'src/ui/source_selected_scope_panel.dart'
    show
        SourceBrowserEntryRow,
        SourceBrowserFormatters,
        SourceSelectedScopePanel,
        showSourceBrowserHelpDialog;
export 'src/ui/sources_page.dart' show SourcesPage;
export 'src/ui/tmdb_scrape_guard.dart'
    show TmdbScrapeGuardBanner, confirmScrapeWithoutTmdbIfNeeded;
