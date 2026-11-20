import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/playback/playback_preferences_provider.dart';
import '../../application/providers/artwork_provider.dart';
import '../../application/providers/detail_display_preferences_provider.dart';
import '../../application/providers/library_providers.dart';
import '../../application/providers/playback_providers.dart';
import '../../application/providers/scraping_providers.dart';
import '../../application/providers/work_management_provider.dart';
import '../../composition/platform_composition.dart';
import '../../domain/models/episode.dart';
import '../../domain/models/tmdb_models.dart';
import '../../domain/models/work.dart';
import '../../domain/playback/cue_variant_resolver.dart';
import '../../infrastructure/cache/scan_thumbnail_scheduler.dart';
import '../../infrastructure/sources/work_detail_warmup_service.dart';
import '../audio/mini_audio_bar.dart';
import '../dialogs/work_artwork_picker_dialog.dart';
import '../sources/tmdb_scrape_guard.dart';
import '../theme/konata_adaptive_tokens.dart';
import '../theme/konata_palette.dart';
import '../theme/konata_theme.dart';
import '../widgets/design_system/konata_draggable_scrollbar.dart';
import '../widgets/design_system/konata_toast.dart';
import '../widgets/managed_image.dart';
import 'detail_action_handlers.dart';
import 'detail_bottom_drawer.dart';
import 'detail_gear_menu.dart';
import 'detail_hero_info.dart';
import 'inline_expandable_synopsis.dart';
import 'series_switcher_dropdown.dart';
import 'work_detail_sub_views.dart';

/// 详情页底部选集区记忆收展状态与选中分页（默认收起剧集缩略图，仅展示紧凑胶囊）。
final detailDrawerExpandedProvider = StateProvider<bool>((ref) => false);
final detailDrawerTabProvider = StateProvider<DetailDrawerTab>(
  (ref) => DetailDrawerTab.main,
);

/// 全屏沉浸式「高通透原画 + 无框悬浮选集」番剧详情页。
class WorkDetailPage extends ConsumerStatefulWidget {
  /// 创建番剧详情页。
  const WorkDetailPage({super.key, required this.workId});

  /// 作品唯一 ID。
  final String workId;

  @override
  ConsumerState<WorkDetailPage> createState() => _WorkDetailPageState();
}

class _WorkDetailPageState extends ConsumerState<WorkDetailPage> {
  late String _activeWorkId = widget.workId;
  final Set<String> _scoreBackfillRequested = <String>{};
  final Set<String> _tmdbBackfillRequested = <String>{};
  final Set<String> _remoteWarmupRequested = <String>{};
  late final ScanThumbnailScheduler _scanScheduler;
  late final WorkDetailWarmupService _warmupService;
  final ScrollController _portraitScrollCtrl = ScrollController();
  final ScrollController _tabletLandscapeScrollCtrl = ScrollController();
  final GlobalKey<DetailBottomDrawerState> _drawerKey =
      GlobalKey<DetailBottomDrawerState>();
  bool _phonePortraitExpanded = true;

  @override
  void initState() {
    super.initState();
    _scanScheduler = ref.read(scanThumbnailSchedulerProvider);
    _warmupService = ref.read(workDetailWarmupServiceProvider);
  }

  @override
  void didUpdateWidget(covariant WorkDetailPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.workId != widget.workId) {
      _scanScheduler.cancelAll();
      _warmupService.cancelPending();
      _activeWorkId = widget.workId;
    }
  }

  @override
  void dispose() {
    _scanScheduler.cancelAll();
    _warmupService.cancelPending();
    _portraitScrollCtrl.dispose();
    _tabletLandscapeScrollCtrl.dispose();
    super.dispose();
  }

  void _maybeWarmupRemoteSources(WorkDetailBundle bundle) {
    if (!_remoteWarmupRequested.add(bundle.work.id)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _warmupService.warmupForVariants(
        variants: bundle.variants,
        sourcesById: bundle.sourcesById,
      );
    });
  }

  void _maybeBackfillBangumiScore(String workId, double? bangumiScore) {
    if (bangumiScore != null && bangumiScore > 0) return;
    if (!_scoreBackfillRequested.add(workId)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(workManagementProvider).ensureWorkBangumiScore(workId);
    });
  }

  void _maybeBackfillTmdbArtwork(Work work) {
    final missingTmdbAfterBangumiFallback =
        !work.metadataLocked &&
        work.tmdbId == null &&
        (work.bangumiId != null || work.folderTmdbHint != null);
    final missingTvArtwork =
        work.tmdbId != null &&
        work.tmdbMediaType == TmdbMediaType.tv &&
        ((work.logoPath == null || work.logoPath!.trim().isEmpty) ||
            (!work.backdropLocked &&
                (work.backdropPath == null ||
                    work.backdropPath!.trim().isEmpty)));
    if (!missingTmdbAfterBangumiFallback && !missingTvArtwork) return;
    if (!_tmdbBackfillRequested.add(work.id)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final updated = await ref
          .read(scrapeControllerProvider.notifier)
          .ensureOrRescrapeWork(workId: work.id, interactive: false);
      if (!mounted || updated == null) return;
      if (updated.id != _activeWorkId) {
        _switchActiveWork(updated.id);
      }
    });
  }

  void _handleEscapeOrBack() {
    final screenSize = MediaQuery.sizeOf(context);
    final isAndroidPhone =
        KonataAdaptiveTokens.isAndroid &&
        screenSize.shortestSide < KonataAdaptiveTokens.tabletBreakpoint;
    final isTabletPortrait =
        KonataAdaptiveTokens.isAndroid &&
        screenSize.shortestSide >= KonataAdaptiveTokens.tabletBreakpoint &&
        screenSize.height >= screenSize.width;
    final hasLoadedBundle =
        ref.read(workDetailBundleProvider(_activeWorkId)).valueOrNull != null;
    if (!isAndroidPhone &&
        !isTabletPortrait &&
        hasLoadedBundle &&
        ref.read(detailDrawerExpandedProvider)) {
      _scanScheduler.cancelAll();
      ref.read(detailDrawerExpandedProvider.notifier).state = false;
      return;
    }
    _returnToLibrary();
  }

  void _returnToLibrary() {
    if (!mounted) return;
    _scanScheduler.cancelAll();
    Navigator.of(context).maybePop();
  }

  void _switchActiveWork(String nextWorkId, {String? toastMessage}) {
    if (!mounted || nextWorkId.isEmpty || nextWorkId == _activeWorkId) return;
    _scanScheduler.cancelAll();
    setState(() => _activeWorkId = nextWorkId);
    if (toastMessage != null && toastMessage.isNotEmpty) {
      _showToast(toastMessage);
    }
  }

  Future<void> _handleOpenManualMatch(WorkDetailBundle bundle) async {
    if (!await ensureTmdbConfiguredForScrape(context, ref) || !mounted) {
      return;
    }
    final matched = await DetailActionHandlers.openManualMatch(context, bundle);
    if (!mounted || matched == null) return;
    if (matched.id != _activeWorkId) {
      _switchActiveWork(
        matched.id,
        toastMessage: '已自动并入已有作品「${matched.title}」',
      );
    }
  }

  Future<void> _handleRescrape(WorkDetailBundle bundle) async {
    if (!await ensureTmdbConfiguredForScrape(context, ref) || !mounted) {
      return;
    }
    final work = bundle.work;
    if (work.tmdbId != null && work.tmdbMediaType != null) {
      final updated = await ref
          .read(scrapeControllerProvider.notifier)
          .rebindWork(
            workId: work.id,
            tmdbId: work.tmdbId!,
            mediaType: work.tmdbMediaType!,
          );
      if (mounted && updated.id != work.id) {
        _switchActiveWork(
          updated.id,
          toastMessage: '已自动并入已有作品「${updated.title}」',
        );
      } else {
        _showToast('已完成元数据刷新');
      }
      return;
    }
    final bound = await ref
        .read(scrapeControllerProvider.notifier)
        .ensureOrRescrapeWork(workId: work.id, interactive: true);
    if (!mounted) return;
    if (bound == null || bound.tmdbId == null) {
      _showToast('未能自动定位唯一 TMDB 条目，请使用绑定元数据匹配');
      return;
    }
    if (bound.id != work.id) {
      _switchActiveWork(
        bound.id,
        toastMessage: '已自动并入已有作品「${bound.title}」',
      );
    } else {
      _showToast('已自动补绑 TMDB 数据并更新图片');
    }
  }

  Future<void> _handleOpenManualEdit(WorkDetailBundle bundle) async {
    final nextWorkId = await DetailActionHandlers.openManualEdit(
      context,
      bundle,
    );
    if (nextWorkId != null) {
      _switchActiveWork(nextWorkId);
    }
  }

  Future<void> _handleOpenMergeWork(WorkDetailBundle bundle) async {
    final outcome = await DetailActionHandlers.openMergeWork(context, bundle);
    if (outcome != null && mounted) {
      _switchActiveWork(
        outcome.targetWork.id,
        toastMessage:
            '已将「${bundle.work.title}」合并入「${outcome.targetWork.title}」',
      );
    }
  }

  void _showToast(String message) {
    if (!mounted) return;
    showKonataToast(context, message);
  }

  bool _hasContentForTab(
    WorkDetailBundle bundle,
    DetailDrawerTab tab,
    DetailDisplayPreferences prefs,
  ) {
    final mainCount = bundle.episodes
        .where((e) => e.category == EpisodeCategory.main)
        .length;
    final extraCount = bundle.episodes
        .where((e) => e.category == EpisodeCategory.extra)
        .length;
    final cdCount = prefs.showCdTab
        ? bundle.cdVariants
              .where((v) => !CueVariantResolver.isCueSheetFile(v.fileName))
              .length
        : 0;
    final scanCount = prefs.showScanTab ? bundle.scanVariants.length : 0;
    return switch (tab) {
      DetailDrawerTab.main => mainCount > 0,
      DetailDrawerTab.extra => extraCount > 0,
      DetailDrawerTab.cd => cdCount > 0 || mainCount > 0,
      DetailDrawerTab.scan => scanCount > 0 || mainCount > 0,
    };
  }

  Widget? _buildInlineSeriesSwitcher(
    WorkDetailBundle bundle, {
    required bool compact,
    required bool openDownward,
  }) {
    if (bundle.seriesMembers.length < 2) return null;
    return SeriesSwitcherDropdown(
      activeWork: bundle.work,
      seriesMembers: bundle.seriesMembers,
      seriesGroup: bundle.seriesGroup,
      onSelectWork: _switchActiveWork,
      compact: compact,
      openDownward: openDownward,
    );
  }

  DetailBottomDrawer _buildBottomDrawer({
    required WorkDetailBundle bundle,
    required DetailDrawerLayoutMode layoutMode,
    required DetailDrawerTab? activeTab,
    required DetailDrawerTab preferredTab,
    required DetailDisplayPreferences displayPrefs,
    required ManagedImageLoader imageLoader,
    required List players,
    required ValueChanged<DetailDrawerTab> onToggleTab,
    required VoidCallback onCollapse,
    Widget? leadingBarWidget,
    bool hideOpsCapsuleInBar = false,
    bool hideSeriesSwitcherInBar = false,
    bool showOpsInPortraitBar = false,
  }) {
    final typedPlayers = players.cast<dynamic>();
    return DetailBottomDrawer(
      key: _drawerKey,
      layoutMode: layoutMode,
      leadingBarWidget: leadingBarWidget,
      hideOpsCapsuleInBar: hideOpsCapsuleInBar,
      hideSeriesSwitcherInBar: hideSeriesSwitcherInBar,
      showOpsInPortraitBar: showOpsInPortraitBar,
      bundle: bundle,
      activeTab: activeTab,
      preferredTab: preferredTab,
      showRawVideoFilename: displayPrefs.showRawVideoFilename,
      showCdTab: displayPrefs.showCdTab,
      showScanTab: displayPrefs.showScanTab,
      imageLoader: imageLoader,
      onToggleTab: onToggleTab,
      onCollapse: onCollapse,
      onSecondaryFilterChanged: _scanScheduler.cancelAll,
      onEpisodeTap: (ep) => DetailActionHandlers.playEpisode(
        context: context,
        ref: ref,
        bundle: bundle,
        episode: ep,
        players: typedPlayers.cast(),
      ),
      onEpisodePlayBuiltin: (ep) => DetailActionHandlers.playEpisode(
        context: context,
        ref: ref,
        bundle: bundle,
        episode: ep,
        players: typedPlayers.cast(),
        overrideEngine: PreferredPlaybackEngine.builtinLibmpv,
      ),
      onEpisodePlayExternal: KonataAdaptiveTokens.isWindows
          ? (ep) => DetailActionHandlers.playEpisode(
              context: context,
              ref: ref,
              bundle: bundle,
              episode: ep,
              players: typedPlayers.cast(),
              overrideEngine: PreferredPlaybackEngine.desktopRelay,
            )
          : null,
      onEpisodeMarkCompleted: (ep) => DetailActionHandlers.markEpisodeCompleted(
        context: context,
        ref: ref,
        bundle: bundle,
        episode: ep,
      ),
      onEpisodeAdjustSlot: (ep) => DetailActionHandlers.showAdjustEpisodeDialog(
        context: context,
        ref: ref,
        episode: ep,
      ),
      onEpisodeMediaInfo: (ep) => DetailActionHandlers.showEpisodeMediaInfo(
        context: context,
        bundle: bundle,
        episode: ep,
      ),
      onOpenManualMatch: () => _handleOpenManualMatch(bundle),
      onOpenManualEdit: () => _handleOpenManualEdit(bundle),
      onOpenPosterPicker: () => DetailActionHandlers.openArtworkPicker(
        context,
        bundle,
        WorkArtworkKind.poster,
      ),
      onOpenBackdropPicker: () => DetailActionHandlers.openArtworkPicker(
        context,
        bundle,
        WorkArtworkKind.backdrop,
      ),
      onHideWork: () => DetailActionHandlers.hideWorkAndPop(
        context,
        ref,
        bundle,
      ),
      onDeleteWork: () => DetailActionHandlers.confirmDeleteAndPop(
        context,
        ref,
        bundle,
      ),
      onRescrape: () => _handleRescrape(bundle),
      onOpenLocalDir: () => DetailActionHandlers.openLocalDirectory(
        context,
        ref,
        bundle,
      ),
      onOpenSeriesManage: () => DetailActionHandlers.openSeriesManage(
        context,
        bundle,
      ),
      onOpenMergeWork: () => _handleOpenMergeWork(bundle),
      onSelectSeriesWork: _switchActiveWork,
      onCdTap: (variant) => DetailActionHandlers.playCdAsset(
        context: context,
        ref: ref,
        bundle: bundle,
        variant: variant,
      ),
      onCdPlayImmersive: (variant) => DetailActionHandlers.playCdAsset(
        context: context,
        ref: ref,
        bundle: bundle,
        variant: variant,
        overrideEngine: PreferredPlaybackEngine.builtinLibmpv,
        expandImmersive: true,
      ),
      onCdPlayExternal: KonataAdaptiveTokens.isWindows
          ? (variant) => DetailActionHandlers.playCdAsset(
              context: context,
              ref: ref,
              bundle: bundle,
              variant: variant,
              overrideEngine: PreferredPlaybackEngine.desktopRelay,
            )
          : null,
      onScanTap: (variant, {String? volumeKey}) =>
          DetailActionHandlers.openScanViewer(
            context,
            bundle,
            variant,
            initialVolumeKey: volumeKey,
          ),
    );
  }

  Widget _buildTopOpsCapsule(
    WorkDetailBundle loaded,
    DetailDrawerTab preferredTab,
    DetailDisplayPreferences displayPrefs, {
    required bool isExpanded,
  }) {
    return DetailOpsCapsule(
      isExpanded: isExpanded,
      hasContent: _hasContentForTab(loaded, preferredTab, displayPrefs),
      showCollapseButton: false,
      openDownward: true,
      onOpenFullList: () => _drawerKey.currentState?.openCurrentFullList(),
      onManualMatch: () => _handleOpenManualMatch(loaded),
      onManualEdit: () => _handleOpenManualEdit(loaded),
      onEditPoster: () => DetailActionHandlers.openArtworkPicker(
        context,
        loaded,
        WorkArtworkKind.poster,
      ),
      onEditBackdrop: () => DetailActionHandlers.openArtworkPicker(
        context,
        loaded,
        WorkArtworkKind.backdrop,
      ),
      onHideWork: () => DetailActionHandlers.hideWorkAndPop(
        context,
        ref,
        loaded,
      ),
      onDeleteWork: () => DetailActionHandlers.confirmDeleteAndPop(
        context,
        ref,
        loaded,
      ),
      onRescrape: () => _handleRescrape(loaded),
      onOpenLocalDir: () => DetailActionHandlers.openLocalDirectory(
        context,
        ref,
        loaded,
      ),
      onManageSeries: () => DetailActionHandlers.openSeriesManage(
        context,
        loaded,
      ),
      onMergeWork: () => _handleOpenMergeWork(loaded),
    );
  }

  void _handlePortraitDrawerTabToggle(
    DetailDrawerTab tab,
    DetailDrawerTab preferredTab,
  ) {
    if (!_phonePortraitExpanded) {
      ref.read(detailDrawerTabProvider.notifier).state = tab;
      setState(() => _phonePortraitExpanded = true);
    } else if (preferredTab == tab) {
      if (preferredTab == DetailDrawerTab.scan) {
        _scanScheduler.cancelAll();
      }
      setState(() => _phonePortraitExpanded = false);
    } else {
      if (preferredTab == DetailDrawerTab.scan && tab != DetailDrawerTab.scan) {
        _scanScheduler.cancelAll();
      }
      ref.read(detailDrawerTabProvider.notifier).state = tab;
    }
  }

  void _handleOverlayDrawerTabToggle(DetailDrawerTab tab) {
    final currentExpanded = ref.read(detailDrawerExpandedProvider);
    final currentTab = ref.read(detailDrawerTabProvider);
    if (!currentExpanded) {
      ref.read(detailDrawerTabProvider.notifier).state = tab;
      ref.read(detailDrawerExpandedProvider.notifier).state = true;
    } else if (currentTab == tab) {
      if (currentTab == DetailDrawerTab.scan) {
        _scanScheduler.cancelAll();
      }
      ref.read(detailDrawerExpandedProvider.notifier).state = false;
    } else {
      if (currentTab == DetailDrawerTab.scan && tab != DetailDrawerTab.scan) {
        _scanScheduler.cancelAll();
      }
      ref.read(detailDrawerTabProvider.notifier).state = tab;
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<DetailDisplayPreferences>(detailDisplayPreferencesProvider, (
      prev,
      next,
    ) {
      if ((prev?.showScanTab ?? true) && !next.showScanTab) {
        _scanScheduler.cancelAll();
      }
    });
    final p = context.palette;
    final bundleAsync = ref.watch(workDetailBundleProvider(_activeWorkId));
    final redirectMap = ref.watch(workRedirectMapProvider);
    final isMissing = bundleAsync.hasValue && bundleAsync.value == null;
    final hasActiveBundle = bundleAsync.valueOrNull != null;
    final redirectTarget = isMissing
        ? resolveWorkRedirectChain(redirectMap, _activeWorkId)
        : _activeWorkId;
    if (isMissing && redirectTarget != _activeWorkId) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _switchActiveWork(redirectTarget);
      });
    }

    final players =
        ref.watch(desktopVideoRelayTargetsProvider).valueOrNull ?? const [];
    final imageLoader = ref.watch(tmdbImageLoaderProvider);
    final isDrawerExpanded = ref.watch(detailDrawerExpandedProvider);
    final displayPrefs = ref.watch(detailDisplayPreferencesProvider);
    final rawPreferredTab = ref.watch(detailDrawerTabProvider);
    final preferredTab =
        (!displayPrefs.showCdTab && rawPreferredTab == DetailDrawerTab.cd) ||
            (!displayPrefs.showScanTab &&
                rawPreferredTab == DetailDrawerTab.scan)
        ? DetailDrawerTab.main
        : rawPreferredTab;
    final effectiveActiveTab = isDrawerExpanded ? preferredTab : null;
    final bottomClearance = KonataBottomClearanceScope.resolve(context, ref);
    final forceLightChrome = p.isDark;
    final outerSize = MediaQuery.sizeOf(context);
    final outerPad = MediaQuery.paddingOf(context);
    final isOuterPhone =
        KonataAdaptiveTokens.isAndroid &&
        outerSize.shortestSide < KonataAdaptiveTokens.tabletBreakpoint;
    final isOuterPhoneLandscape =
        isOuterPhone && outerSize.width > outerSize.height;
    final isOuterPhonePortrait =
        isOuterPhone && outerSize.height >= outerSize.width;
    // 仅手机竖屏在右上角顶栏保留操作胶囊；平板竖屏与手机横屏均将其下移至「正片」分类胶囊同一行最右侧。
    final showPortraitOpsInTopBar =
        isOuterPhonePortrait && bundleAsync.valueOrNull != null;
    final useLightTopBarIcons =
        forceLightChrome ||
        (KonataAdaptiveTokens.isAndroid && hasActiveBundle);

    return Listener(
      onPointerDown: (event) {
        if ((event.buttons & kBackMouseButton) != 0) {
          _handleEscapeOrBack();
        }
      },
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): _handleEscapeOrBack,
        },
        child: Focus(
          autofocus: true,
          child: Scaffold(
            backgroundColor: hasActiveBundle || p.isDark
                ? KonataTheme.cinemaObsidian
                : KonataTheme.themePreviewLightCanvas,
            body: Stack(
              fit: StackFit.expand,
              children: [
                bundleAsync.when(
                  data: (bundle) {
                    if (bundle == null) {
                      if (redirectTarget != _activeWorkId) {
                        return const Center(child: CircularProgressIndicator());
                      }
                      return MissingWorkFallbackView(
                        onReturnToLibrary: _returnToLibrary,
                      );
                    }
                    final work = bundle.work;
                    _maybeBackfillBangumiScore(work.id, work.bangumiScore);
                    _maybeBackfillTmdbArtwork(work);
                    _maybeWarmupRemoteSources(bundle);
                    final screenSize = MediaQuery.sizeOf(context);
                    final safePad = MediaQuery.paddingOf(context);
                    final isAndroidPhone =
                        KonataAdaptiveTokens.isAndroid &&
                        screenSize.shortestSide <
                            KonataAdaptiveTokens.tabletBreakpoint;
                    final isPhonePortrait =
                        isAndroidPhone && screenSize.height >= screenSize.width;
                    final isPhoneLandscape =
                        isAndroidPhone && screenSize.width > screenSize.height;
                    final isAndroidTablet =
                        KonataAdaptiveTokens.isAndroid &&
                        screenSize.shortestSide >=
                            KonataAdaptiveTokens.tabletBreakpoint;
                    final isTabletPortrait =
                        isAndroidTablet &&
                        screenSize.height >= screenSize.width;
                    final hasLogo =
                        work.logoPath != null &&
                        work.logoPath!.trim().isNotEmpty;
                    final hasOverview =
                        displayPrefs.showOverview &&
                        work.overview != null &&
                        work.overview!.trim().isNotEmpty;

                    // 手机横屏：沉浸式放大横版头图（双向及底部平滑渐隐） + 下方选集滑轨 + 作品简介整体纵向滚动
                    if (isPhoneLandscape) {
                      final landscapeHero = DetailLandscapeHeroBanner(
                        bundle: bundle,
                        imageLoader: imageLoader,
                        displayPrefs: displayPrefs,
                        screenSize: screenSize,
                        leadingBackButton: WorkDetailBackCircle(
                          forceLightIcons: true,
                          onBack: _returnToLibrary,
                        ),
                        seriesSwitcher: _buildInlineSeriesSwitcher(
                          bundle,
                          compact: true,
                          openDownward: true,
                        ),
                        onPrimaryPlay: () =>
                            DetailActionHandlers.handlePrimaryPlay(
                              context: context,
                              ref: ref,
                              bundle: bundle,
                              players: players,
                            ),
                      );
                      final landscapeDrawer = _buildBottomDrawer(
                        bundle: bundle,
                        layoutMode: DetailDrawerLayoutMode.phoneLandscapeRail,
                        hideOpsCapsuleInBar: false,
                        hideSeriesSwitcherInBar: true,
                        activeTab: preferredTab,
                        preferredTab: preferredTab,
                        displayPrefs: displayPrefs,
                        imageLoader: imageLoader,
                        players: players,
                        onToggleTab: (tab) {
                          if (preferredTab == DetailDrawerTab.scan &&
                              tab != DetailDrawerTab.scan) {
                            _scanScheduler.cancelAll();
                          }
                          ref.read(detailDrawerTabProvider.notifier).state =
                              tab;
                        },
                        onCollapse: () {},
                      );
                      final safeHPad = math.max(
                        16.0,
                        math.max(safePad.left, safePad.right) + 12.0,
                      );

                      return KonataDraggableScrollbar(
                        controller: _portraitScrollCtrl,
                        builder: (_, ctrl) => SingleChildScrollView(
                          key: const ValueKey(
                            'detail_phone_landscape_scroll_view',
                          ),
                          controller: ctrl,
                          padding: EdgeInsets.only(
                            bottom: 24 + bottomClearance,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              if (safePad.top > 0)
                                SizedBox(height: safePad.top),
                              landscapeHero,
                              Padding(
                                padding: EdgeInsets.symmetric(
                                  horizontal: math.max(0.0, safeHPad - 16.0),
                                ),
                                child: landscapeDrawer,
                              ),
                              if (hasOverview) ...[
                                const SizedBox(height: 16),
                                Padding(
                                  padding: EdgeInsets.symmetric(
                                    horizontal: safeHPad,
                                  ),
                                  child: Theme(
                                    data: KonataTheme.darkTheme(),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          '作品简介',
                                          style: KonataTheme.detailTextStyle(
                                            palette: p,
                                            color: KonataTheme.pureWhite.withValues(
                                              alpha: 0.92,
                                            ),
                                            fontSize: KonataTheme.fontSizeTitleSm,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                        const SizedBox(height: 8),
                                        InlineExpandableSynopsis(
                                          text: work.overview!.trim(),
                                          collapsedMaxLines: 4,
                                          maxExpandedHeight: 260,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      );
                    }

                    // 手机竖屏采用方案 P1 全幅竖版封面沉浸头图；平板竖屏保持 16:9 横版背景头图 + 通栏简介
                    if (isPhonePortrait || isTabletPortrait) {
                      final portraitTab = _phonePortraitExpanded
                          ? preferredTab
                          : null;
                      final contentPadH = isTabletPortrait ? 28.0 : 16.0;
                      final overlayLogoMaxH = isTabletPortrait ? 68.0 : 56.0;
                      final overlayLogoMaxW = math.min(
                        screenSize.width * (isTabletPortrait ? 0.56 : 0.68),
                        isTabletPortrait ? 300.0 : 240.0,
                      );

                      return KonataDraggableScrollbar(
                        controller: _portraitScrollCtrl,
                        builder: (_, ctrl) => SingleChildScrollView(
                          key: const ValueKey('detail_portrait_scroll_view'),
                          controller: ctrl,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              if (safePad.top > 0)
                                SizedBox(height: safePad.top),
                              DetailPortraitHeroHeader(
                                work: work,
                                imageLoader: imageLoader,
                                screenSize: screenSize,
                                isTablet: isTabletPortrait,
                                showTitleLogo: displayPrefs.showTitleLogo,
                                logoMaxHeight: overlayLogoMaxH,
                                logoMaxWidth: overlayLogoMaxW,
                              ),
                              Padding(
                                padding: EdgeInsets.fromLTRB(
                                  contentPadH,
                                  6,
                                  contentPadH,
                                  16,
                                ),
                                child: Theme(
                                  data: KonataTheme.darkTheme(),
                                  child: DetailHeroInfo(
                                    bundle: bundle,
                                    imageLoader: imageLoader,
                                    showTitleText: displayPrefs.showTitleText,
                                    showTitleLogo: displayPrefs.showTitleLogo,
                                    showOverview: isTabletPortrait
                                        ? displayPrefs.showOverview
                                        : false,
                                    expandOverviewFullWidth: isTabletPortrait,
                                    trailingPlayAccessory:
                                        _buildInlineSeriesSwitcher(
                                          bundle,
                                          compact: isPhonePortrait,
                                          openDownward: true,
                                        ),
                                    overlayLogoHandledSeparately:
                                        isTabletPortrait &&
                                        displayPrefs.showTitleLogo &&
                                        hasLogo,
                                    lockInFlowLogoHeight: isPhonePortrait,
                                    logoMaxHeight: overlayLogoMaxH,
                                    logoMaxWidth: overlayLogoMaxW,
                                    titleFontSize: isTabletPortrait ? 28 : 23,
                                    fullWidthPlayButton: false,
                                    onPrimaryPlay: () =>
                                        DetailActionHandlers.handlePrimaryPlay(
                                          context: context,
                                          ref: ref,
                                          bundle: bundle,
                                          players: players,
                                        ),
                                    onManualMatch: () =>
                                        _handleOpenManualMatch(bundle),
                                    onDismissReview: () =>
                                        DetailActionHandlers.dismissReviewPrompt(
                                          context: context,
                                          ref: ref,
                                          workId: work.id,
                                        ),
                                  ),
                                ),
                              ),
                              _buildBottomDrawer(
                                bundle: bundle,
                                layoutMode:
                                    DetailDrawerLayoutMode.phonePortraitSection,
                                hideSeriesSwitcherInBar: true,
                                showOpsInPortraitBar: isTabletPortrait,
                                activeTab: portraitTab,
                                preferredTab: preferredTab,
                                displayPrefs: displayPrefs,
                                imageLoader: imageLoader,
                                players: players,
                                onToggleTab: (tab) =>
                                    _handlePortraitDrawerTabToggle(
                                      tab,
                                      preferredTab,
                                    ),
                                onCollapse: () {
                                  _scanScheduler.cancelAll();
                                  setState(
                                    () => _phonePortraitExpanded = false,
                                  );
                                },
                              ),
                              if (!isTabletPortrait && hasOverview) ...[
                                const SizedBox(height: 18),
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                  ),
                                  child: Theme(
                                    data: KonataTheme.darkTheme(),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          '作品简介',
                                          style: KonataTheme.detailTextStyle(
                                            palette: p,
                                            color: KonataTheme.pureWhite.withValues(
                                              alpha: 0.92,
                                            ),
                                            fontSize: KonataTheme.fontSizeTitleSm,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                        const SizedBox(height: 8),
                                        InlineExpandableSynopsis(
                                          text: work.overview!.trim(),
                                          collapsedMaxLines: 4,
                                          maxExpandedHeight: 280,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                              SizedBox(height: 28 + bottomClearance),
                            ],
                          ),
                        ),
                      );
                    }

                    // 桌面端与 Android 平板横屏：全屏原画与底部悬浮选集抽屉
                    final safeTop = safePad.top;
                    const heroPadH = 36.0;
                    final bgPath =
                        (work.backdropPath != null &&
                            work.backdropPath!.isNotEmpty)
                        ? work.backdropPath!
                        : (work.posterPath ?? '');
                    final hasBackdrop =
                        work.backdropPath != null &&
                        work.backdropPath!.isNotEmpty;

                    final overlayDrawerWidget = _buildBottomDrawer(
                      bundle: bundle,
                      layoutMode: DetailDrawerLayoutMode.bottomOverlay,
                      activeTab: effectiveActiveTab,
                      preferredTab: preferredTab,
                      displayPrefs: displayPrefs,
                      imageLoader: imageLoader,
                      players: players,
                      onToggleTab: _handleOverlayDrawerTabToggle,
                      onCollapse: () {
                        _scanScheduler.cancelAll();
                        ref.read(detailDrawerExpandedProvider.notifier).state =
                            false;
                      },
                    );

                    final heroInfoWidget = DetailHeroInfo(
                      bundle: bundle,
                      imageLoader: imageLoader,
                      showTitleText: displayPrefs.showTitleText,
                      showTitleLogo: displayPrefs.showTitleLogo,
                      showOverview: displayPrefs.showOverview,
                      logoMaxHeight: 80.0,
                      logoMaxWidth: 340.0,
                      onPrimaryPlay: () =>
                          DetailActionHandlers.handlePrimaryPlay(
                            context: context,
                            ref: ref,
                            bundle: bundle,
                            players: players,
                          ),
                      onManualMatch: () => _handleOpenManualMatch(bundle),
                      onDismissReview: () =>
                          DetailActionHandlers.dismissReviewPrompt(
                            context: context,
                            ref: ref,
                            workId: work.id,
                          ),
                    );

                    return Stack(
                      fit: StackFit.expand,
                      children: [
                        Positioned(
                          key: const ValueKey(
                            'detail_wide_backdrop_stage',
                          ),
                          top: KonataAdaptiveTokens.isAndroid ? safeTop : 0.0,
                          left: 0,
                          right: 0,
                          bottom: 0,
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              if (bgPath.isNotEmpty)
                                ManagedImage(
                                  bgPath,
                                  loader: imageLoader,
                                  owner: work.id,
                                  artwork: ManagedArtwork.backdrop,
                                  isHeroBackdrop: true,
                                  imageSize: TmdbImageSize.original,
                                  fit: BoxFit.cover,
                                ),
                              if (!hasBackdrop && bgPath.isNotEmpty)
                                BackdropFilter(
                                  filter: KonataTheme.blurFilterCapsule,
                                  child: Container(
                                    color: KonataTheme.scrimBlackMedium,
                                  ),
                                ),
                              // L 型双轴光学暗幕：左→右柔光承托文字与 ClearLogo，右半屏原画保持饱满通透
                              IgnorePointer(
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    gradient: LinearGradient(
                                      begin: Alignment.centerLeft,
                                      end: Alignment.centerRight,
                                      stops: const [0.0, 0.34, 0.66],
                                      colors: [
                                        KonataTheme.cinemaObsidian.withValues(
                                          alpha: 0.84,
                                        ),
                                        KonataTheme.cinemaObsidian.withValues(
                                          alpha: 0.40,
                                        ),
                                        Colors.transparent,
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                              // 下→上光学渐隐暗幕：展开选集抽屉时加深托底以衬托无框卡片
                              IgnorePointer(
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    gradient: LinearGradient(
                                      begin: Alignment.bottomCenter,
                                      end: Alignment.topCenter,
                                      stops: isDrawerExpanded
                                          ? const [0.0, 0.24, 0.48]
                                          : const [0.0, 0.14, 0.30],
                                      colors: isDrawerExpanded
                                          ? [
                                              KonataTheme.cinemaObsidian
                                                  .withValues(alpha: 0.86),
                                              KonataTheme.cinemaObsidian
                                                  .withValues(alpha: 0.46),
                                              Colors.transparent,
                                            ]
                                          : [
                                              KonataTheme.cinemaObsidian
                                                  .withValues(alpha: 0.54),
                                              KonataTheme.cinemaObsidian
                                                  .withValues(alpha: 0.18),
                                              Colors.transparent,
                                            ],
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        // Android 平板横屏使用底部 padding 避让迷你播放胶囊的纵向滚动流，防止分类栏向上硬推遮挡播放按钮。
                        if (isAndroidTablet)
                          Positioned.fill(
                            child: KonataDraggableScrollbar(
                              controller: _tabletLandscapeScrollCtrl,
                              builder: (_, ctrl) {
                                final drawerReserve =
                                    effectiveActiveTab != null ? 316.0 : 72.0;
                                final minHeroStageH = math.max(
                                  240.0,
                                  screenSize.height -
                                      safeTop -
                                      60.0 -
                                      drawerReserve -
                                      safePad.bottom,
                                );
                                return SingleChildScrollView(
                                  key: const ValueKey(
                                    'detail_tablet_landscape_scroll_view',
                                  ),
                                  controller: ctrl,
                                  padding: EdgeInsets.only(
                                    bottom: bottomClearance,
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      SizedBox(height: safeTop + 60),
                                      ConstrainedBox(
                                        constraints: BoxConstraints(
                                          minHeight: minHeroStageH,
                                        ),
                                        child: Align(
                                          alignment: Alignment.bottomLeft,
                                          child: Padding(
                                            padding: EdgeInsets.fromLTRB(
                                              heroPadH,
                                              8,
                                              heroPadH,
                                              effectiveActiveTab == null
                                                  ? 24
                                                  : 18,
                                            ),
                                            child: heroInfoWidget,
                                          ),
                                        ),
                                      ),
                                      overlayDrawerWidget,
                                    ],
                                  ),
                                );
                              },
                            ),
                          )
                        else
                          Positioned.fill(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                const SizedBox(height: 62),
                                Expanded(
                                  child: Align(
                                    alignment: Alignment.bottomLeft,
                                    child: SingleChildScrollView(
                                      padding: EdgeInsets.fromLTRB(
                                        heroPadH,
                                        8,
                                        heroPadH,
                                        effectiveActiveTab == null ? 24 : 18,
                                      ),
                                      child: heroInfoWidget,
                                    ),
                                  ),
                                ),
                                AnimatedPadding(
                                  duration: KonataTheme.capsuleSlideDuration,
                                  curve: Curves.easeOutCubic,
                                  padding: EdgeInsets.only(
                                    bottom: bottomClearance,
                                  ),
                                  child: overlayDrawerWidget,
                                ),
                              ],
                            ),
                          ),
                      ],
                    );
                  },
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (err, _) => MissingWorkFallbackView(
                    title: '加载作品详情失败',
                    subtitle: '$err',
                    isError: true,
                    onReturnToLibrary: _returnToLibrary,
                  ),
                ),
                if (!(isOuterPhoneLandscape && hasActiveBundle))
                  Positioned(
                    top: KonataAdaptiveTokens.isAndroid ? outerPad.top + 7 : 12,
                    left: KonataAdaptiveTokens.isAndroid ? 12 : 16,
                    right: 14,
                    child: WorkDetailTopBar(
                      forceLightIcons: useLightTopBarIcons,
                      showGlassChrome: hasActiveBundle,
                      onBack: _returnToLibrary,
                      trailingOps: showPortraitOpsInTopBar
                          ? _buildTopOpsCapsule(
                              bundleAsync.valueOrNull!,
                              preferredTab,
                              displayPrefs,
                              isExpanded: _phonePortraitExpanded,
                            )
                          : null,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
