/// Konata v3 独立扫图画廊与滑窗灯箱业务包唯一公开出口。
///
/// 严禁跨包导入本包内部路径；所有调用方统一导入本文件。
library;

export 'src/data/scan_gallery_prefs.dart'
    show
        ScanGalleryDensity,
        ScanGalleryMode,
        ScanGalleryPrefs,
        scanGalleryPrefsSlice;
export 'src/data/scan_gallery_repository.dart'
    show ScanGalleryRepository, ScanWorkDataset;
export 'src/data/scan_lightbox_loader.dart'
    show
        ScanImageLoadHandle,
        ScanLightboxLoader,
        ScanLightboxMemoryWindow,
        ScanMemoryWindowEntry;
export 'src/data/scan_thumbnail_scheduler.dart'
    show ScanSourceStreamOpener, ScanThumbnailScheduler, ScanThumbnailTicket;
export 'src/manifest.dart'
    show
        ScanViewerAvailability,
        createFeatureScanViewerManifest,
        featureScanViewerManifest;
export 'src/providers.dart'
    show
        FeatureScanViewerDependencies,
        ScanWindowFullscreenPort,
        featureScanViewerDependenciesProvider,
        scanLightboxLoaderProvider,
        scanThumbnailSchedulerProvider;
export 'src/state/scan_gallery_controller.dart'
    show ScanGalleryController, ScanGalleryState;
export 'src/ui/scan_gallery_tab_host.dart' show ScanGalleryTabHost;
export 'src/ui/scan_gallery_view.dart' show ScanGalleryView, ScanTapCallback;
export 'src/ui/scan_lightbox_dialog.dart'
    show ScanLightboxDialog, showScanLightboxDialog;
export 'src/ui/scan_thumbnail_card.dart' show ScanThumbnailCard;
