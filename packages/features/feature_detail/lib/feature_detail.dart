/// Konata v3 番剧作品详情、剧集与特典编排及元数据精修特性包唯一公开出口。
///
/// 严禁跨包导入本包 `src/` 目录及以下任何文件；所有外部调用方与组装根统一导入本出口。
library;

export 'src/data/artwork_crop_math.dart'
    show
        ArtworkCropCorner,
        ArtworkCropMath,
        ArtworkDisplayRect,
        ArtworkNormalizedCropRect,
        ArtworkSourcePixelRect;
export 'src/data/artwork_dominant_color.dart' show ArtworkDominantColor;
export 'src/data/clear_logo_legibility.dart'
    show ClearLogoLegibility, ClearLogoLegibilityResult, ClearLogoLumaStats;
export 'src/data/detail_display_preferences.dart'
    show DetailDisplayPreferences, DetailDisplayPreferencesStore;
export 'src/data/detail_edit_models.dart'
    show
        EditableFileMappingRow,
        EpisodeFileMappingEdit,
        HybridMatchRequest,
        MergeVideoCategoryMode,
        SeriesMemberEdit,
        SupplementaryEditableItem,
        SupplementaryScopeEdit,
        WorkMergeOutcome;
export 'src/data/detail_title_typography.dart'
    show DetailStylizedTitlePlan, DetailTitleTypographyResolver;
export 'src/data/detail_work_actions.dart'
    show DetailWorkActionsService, PhotosStorageArtworkPortAdapter;
export 'src/data/local_artwork_cropper.dart'
    show LoadedLocalArtwork, LocalArtworkCropper;
export 'src/data/main_episode_frame_backfill_service.dart'
    show MainEpisodeFrameBackfillService;
export 'src/data/main_episode_frame_extractor.dart'
    show MainEpisodeFrameExtractor, MainEpisodeFrameTask;
export 'src/data/media_display_formatter.dart' show MediaDisplayFormatter;
export 'src/data/series_member_label_resolver.dart'
    show SeriesMemberLabelResolver, SeriesWorkMediaFilter;
export 'src/data/work_artwork_options.dart'
    show WorkArtworkOption, WorkArtworkOptions, WorkArtworkOptionsService;
export 'src/manifest.dart' show featureDetailManifest;
export 'src/providers.dart'
    show
        FeatureDetailDependencies,
        detailBangumiServiceProvider,
        detailClearLogoResolverProvider,
        detailDisplayPreferencesProvider,
        detailDisplayPreferencesStoreProvider,
        detailFanartCacheProvider,
        detailFanartCircuitBreakerProvider,
        detailFanartServiceProvider,
        detailLibraryRepositoryProvider,
        detailManagedImageLoaderProvider,
        detailScrapePipelineProvider,
        detailTmdbServiceProvider,
        detailWorkActionsServiceProvider,
        featureDetailDependenciesProvider,
        mainEpisodeFrameExtractorProvider,
        workArtworkOptionsServiceProvider,
        workDetailControllerProvider;
export 'src/state/detail_supplementary_view_data.dart'
    show DetailMainSeasonGroup, DetailSupplementaryHelper, WorkDetailBundle;
export 'src/state/work_detail_controller.dart' show WorkDetailController;
export 'src/state/work_rescrape_state.dart'
    show
        WorkRescrapeFailed,
        WorkRescrapeIdle,
        WorkRescrapeRunning,
        WorkRescrapeState,
        WorkRescrapeSucceeded;
export 'src/ui/artwork_crop_dialog.dart' show ArtworkCropDialog;
export 'src/ui/detail_bottom_drawer.dart' show DetailBottomDrawer;
export 'src/ui/detail_full_list_dialog.dart' show DetailFullListDialog;
export 'src/ui/detail_gear_menu.dart'
    show DetailBuiltInGearAction, DetailGearMenu;
export 'src/ui/detail_hero_info.dart' show DetailHeroInfo;
export 'src/ui/detail_managed_image.dart'
    show DetailManagedImage, DetailManagedImageProvider, DetailSmartCoverFraming;
export 'src/ui/detail_rescrape_progress_pill.dart'
    show DetailRescrapeProgressPill;
export 'src/ui/detail_secondary_filter_bar.dart'
    show DetailDrawerTabIds, DetailSecondaryFilterBar;
export 'src/ui/detail_stylized_title_block.dart' show DetailStylizedTitleBlock;
export 'src/ui/episode_drawer_card.dart' show EpisodeDrawerCard;
export 'src/ui/episode_media_info_dialog.dart' show EpisodeMediaInfoDialog;
export 'src/ui/episode_slot_picker_popover.dart' show EpisodeSlotPickerButton;
export 'src/ui/file_mapping_panel.dart' show FileMappingPanel;
export 'src/ui/inline_expandable_synopsis.dart' show InlineExpandableSynopsis;
export 'src/ui/manual_match_dialog.dart' show ManualMatchDialog;
export 'src/ui/series_manage_dialog.dart' show SeriesManageDialog;
export 'src/ui/series_switcher_dropdown.dart' show SeriesSwitcherDropdown;
export 'src/ui/source_files_review_dialog.dart'
    show SourceFilesReviewDialog, showSourceFilesReviewDialog;
export 'src/ui/supplementary_asset_cards.dart' show CdDrawerCard;
export 'src/ui/supplementary_scope_panel.dart'
    show SupplementaryScopeDraft, SupplementaryScopePanel;
export 'src/ui/variant_picker_dialog.dart' show VariantPickerDialog;
export 'src/ui/video_frame_candidates_grid.dart' show VideoFrameCandidateTile;
export 'src/ui/work_artwork_picker_dialog.dart'
    show WorkArtworkKind, WorkArtworkPickerDialog;
export 'src/ui/work_detail_page.dart' show WorkDetailPage;
export 'src/ui/work_detail_sub_views.dart'
    show
        DetailPortraitHeroHeader,
        DetailWideBackdropStage,
        MissingWorkFallbackView,
        WorkDetailTopBar;
export 'src/ui/work_manual_edit_dialog.dart'
    show WorkManualEditDialog, WorkManualEditSection;
export 'src/ui/work_merge_target_dialog.dart' show WorkMergeTargetDialog;
export 'src/ui/work_review_banner.dart' show WorkReviewBanner;
