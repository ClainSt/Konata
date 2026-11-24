/// Konata v3 番剧海报墙、本地搜索与作品管理业务包唯一公开出口。
///
/// 严禁跨包导入本包内部路径；所有调用方统一导入本文件。
library;

export 'src/data/chinese_pinyin_collator.dart' show ChinesePinyinCollator;
export 'src/data/library_filter_prefs.dart'
    show LibraryFilterPrefs, LibraryPrefsState;
export 'src/data/library_models.dart'
    show
        HybridMatchRequest,
        LibrarySortMode,
        LibrarySortOrder,
        MediaDisplayFormatter,
        MergeVideoCategoryMode,
        ReviewReasonLabels,
        WorkLibraryItem,
        WorkMergeOutcome,
        annotateCrossSourceBadges;
export 'src/data/library_search_matcher.dart' show LibrarySearchMatcher;
export 'src/manifest.dart' show featureLibraryManifest;
export 'src/providers.dart'
    show
        FeatureLibraryDependencies,
        LibraryArtworkLoader,
        featureLibraryDependenciesProvider,
        libraryArtworkLoaderProvider,
        libraryControllerProvider,
        workManagementControllerProvider;
export 'src/state/library_controller.dart'
    show LibraryController, desktopKeepAliveWorkLimit;
export 'src/state/work_management_controller.dart'
    show WorkManagementController;
export 'src/ui/delete_work_dialog.dart'
    show DeleteWorkConfirmResult, showDeleteWorkDialog, showHideWorkDialog;
export 'src/ui/hidden_works_dialog.dart' show showHiddenWorksDialog;
export 'src/ui/library_page.dart' show LibraryPage;
export 'src/ui/managed_image.dart' show ManagedImage, quantizeManagedImageWidth;
export 'src/ui/manual_match_dialog.dart' show showManualMatchDialog;
export 'src/ui/poster_card.dart' show PosterCard;
export 'src/ui/review_dialog.dart' show showReviewDialog;
export 'src/ui/source_files_review_dialog.dart' show showSourceFilesReviewDialog;
export 'src/ui/work_merge_target_dialog.dart'
    show
        WorkMergeSelection,
        showWorkMergeSelectionDialog,
        showWorkMergeTargetDialog;
