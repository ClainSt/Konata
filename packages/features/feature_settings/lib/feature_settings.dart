/// Konata v3 三端自适应纯设置容器业务包唯一公开出口。
///
/// 严禁跨包导入本包内部路径；所有调用方统一导入本文件。
library;

export 'src/data/photos_cleanup_scanner.dart'
    show PhotosCleanupScanner, PhotosCleanupSnapshot, WorkPhotoStorageEntry;
export 'src/data/settings_network_repository.dart'
    show SettingsNetworkRepository;
export 'src/data/settings_prefs.dart'
    show SettingsAppearancePrefs, SettingsAppearanceRepository;
export 'src/manifest.dart' show featureSettingsManifest;
export 'src/providers.dart'
    show
        FeatureSettingsDependencies,
        featureSettingsDependenciesProvider,
        settingsControllerProvider;
export 'src/state/settings_controller.dart'
    show NetworkConnectivityProbe, NetworkProbeTargets, SettingsController;
export 'src/ui/fanart_api_help_dialog.dart' show showFanartApiHelpDialog;
export 'src/ui/photo_custom_cleanup_dialog.dart'
    show PhotoCustomCleanupSelection, showPhotoCustomCleanupDialog;
export 'src/ui/settings_about_panel.dart' show SettingsAboutPanel;
export 'src/ui/settings_appearance_panel.dart' show SettingsAppearancePanel;
export 'src/ui/settings_network_panel.dart' show SettingsNetworkPanel;
export 'src/ui/settings_page.dart' show SettingsPage;
export 'src/ui/settings_photos_storage_card.dart'
    show SettingsPhotosStorageCard;
export 'src/ui/tmdb_api_help_dialog.dart' show showTmdbApiHelpDialog;
