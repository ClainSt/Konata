import 'dart:ui';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../../application/playback/playback_preferences_provider.dart';
import '../../application/providers/artwork_provider.dart';
import '../../application/providers/detail_display_preferences_provider.dart';
import '../../application/providers/library_providers.dart';
import '../../application/providers/scraping_providers.dart';
import '../../application/providers/work_management_provider.dart';
import '../../domain/models/episode.dart';
import '../../domain/models/tmdb_models.dart';
import '../../domain/playback/cue_variant_resolver.dart';
import '../../infrastructure/cache/scan_thumbnail_scheduler.dart';
import '../audio/mini_audio_bar.dart';
import '../audio/smart_cover_framing.dart';
import '../dialogs/work_artwork_picker_dialog.dart';
import '../shell/window_controls.dart';
import '../sources/tmdb_scrape_guard.dart';
import '../theme/konata_adaptive_tokens.dart';
import '../theme/konata_palette.dart';
import '../theme/konata_playback_tokens.dart';
import '../theme/konata_theme.dart';
import '../widgets/design_system/konata_draggable_scrollbar.dart';
import '../widgets/design_system/konata_pill_button.dart';
import '../widgets/design_system/konata_toast.dart';
import '../widgets/managed_image.dart';
import 'detail_action_handlers.dart';
import 'detail_bottom_drawer.dart';
import 'detail_gear_menu.dart';
import 'detail_hero_info.dart';
import 'inline_expandable_synopsis.dart';

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
  late final ScanThumbnailScheduler _scanScheduler;
  final ScrollController _portraitScrollCtrl = ScrollController();
  final GlobalKey<DetailBottomDrawerState> _drawerKey =
      GlobalKey<DetailBottomDrawerState>();
  bool _phonePortraitExpanded = true;

  @override
  void initState() {
    super.initState();
    _scanScheduler = ref.read(scanThumbnailSchedulerProvider);
  }

  @override
  void didUpdateWidget(covariant WorkDetailPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.workId != widget.workId) {
      _scanScheduler.cancelAll();
      _activeWorkId = widget.workId;
    }
  }

  @override
  void dispose() {
    _scanScheduler.cancelAll();
    _portraitScrollCtrl.dispose();
    super.dispose();
  }

  void _maybeBackfillBangumiScore(String workId, double? bangumiScore) {
    if (bangumiScore != null && bangumiScore > 0) return;
    if (!_scoreBackfillRequested.add(workId)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(workManagementProvider).ensureWorkBangumiScore(workId);
    });
  }

  void _handleEscapeOrBack() {
    final screenSize = MediaQuery.sizeOf(context);
    final isAndroidPhone =
        KonataAdaptiveTokens.isAndroid &&
        screenSize.shortestSide < KonataAdaptiveTokens.tabletBreakpoint;
    final hasLoadedBundle =
        ref.read(workDetailBundleProvider(_activeWorkId)).valueOrNull != null;
    if (!isAndroidPhone &&
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
    } else {
      _showToast('当前作品尚未绑定 TMDB ID，请先使用绑定元数据匹配');
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
  }) {
    final typedPlayers = players.cast<dynamic>();
    return DetailBottomDrawer(
      key: _drawerKey,
      layoutMode: layoutMode,
      leadingBarWidget: leadingBarWidget,
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
              overrideEngine: PreferredPlaybackEngine.externalPlayer,
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
              overrideEngine: PreferredPlaybackEngine.externalPlayer,
            )
          : null,
      onScanTap: (variant) => DetailActionHandlers.openScanViewer(
        context,
        bundle,
        variant,
      ),
    );
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

    final players = ref.watch(externalPlayersProvider).valueOrNull ?? const [];
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
    final playerBarActive = ref.watch(miniAudioBottomClearanceProvider) > 0;
    final bottomClearance = playerBarActive
        ? KonataBottomClearanceScope.resolve(context, ref)
        : MediaQuery.paddingOf(context).bottom;
    final forceLightChrome = p.isDark;

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
                      return _MissingWorkFallbackView(
                        onReturnToLibrary: _returnToLibrary,
                      );
                    }
                    final work = bundle.work;
                    _maybeBackfillBangumiScore(work.id, work.bangumiScore);
                    final screenSize = MediaQuery.sizeOf(context);
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

                    // 手机横屏：仅保留顶部平齐导航与选集胶囊，不展示作品标题、封面与简介
                    if (isPhoneLandscape) {
                      return SafeArea(
                        bottom: false,
                        child: Padding(
                          padding: EdgeInsets.only(bottom: bottomClearance),
                          child: _buildBottomDrawer(
                            bundle: bundle,
                            layoutMode: DetailDrawerLayoutMode.phoneLandscapeRail,
                            activeTab: preferredTab,
                            preferredTab: preferredTab,
                            displayPrefs: displayPrefs,
                            imageLoader: imageLoader,
                            players: players,
                            leadingBarWidget: _WorkDetailBackCircle(
                              forceLightIcons: forceLightChrome,
                              onBack: _returnToLibrary,
                            ),
                            onToggleTab: (tab) {
                              if (preferredTab == DetailDrawerTab.scan &&
                                  tab != DetailDrawerTab.scan) {
                                _scanScheduler.cancelAll();
                              }
                              ref.read(detailDrawerTabProvider.notifier).state =
                                  tab;
                            },
                            onCollapse: () {},
                          ),
                        ),
                      );
                    }

                    // 手机竖屏：仿网易爆米花竖版海报封面流 + 剧集置于简介上方
                    if (isPhonePortrait) {
                      final posterPath =
                          (work.posterPath != null &&
                              work.posterPath!.isNotEmpty)
                          ? work.posterPath!
                          : (work.bangumiPosterPath != null &&
                                    work.bangumiPosterPath!.isNotEmpty
                                ? work.bangumiPosterPath!
                                : (work.backdropPath ?? ''));
                      final heroPosterH = (screenSize.height * 0.44).clamp(
                        240.0,
                        380.0,
                      );
                      final phoneTab = _phonePortraitExpanded
                          ? preferredTab
                          : null;
                      final hasOverview =
                          displayPrefs.showOverview &&
                          work.overview != null &&
                          work.overview!.trim().isNotEmpty;

                      return KonataDraggableScrollbar(
                        controller: _portraitScrollCtrl,
                        builder: (_, ctrl) => SingleChildScrollView(
                          controller: ctrl,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              SizedBox(
                                height: heroPosterH,
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    if (posterPath.isNotEmpty) ...[
                                      ManagedImage(
                                        posterPath,
                                        loader: imageLoader,
                                        owner: work.id,
                                        artwork: ManagedArtwork.poster,
                                        fit: BoxFit.cover,
                                        alignment: SmartCoverFraming
                                            .defaultPosterAlignment,
                                      ),
                                    ] else
                                      const ColoredBox(
                                        color: KonataTheme.cinemaObsidian,
                                      ),
                                    IgnorePointer(
                                      child: DecoratedBox(
                                        decoration: BoxDecoration(
                                          gradient: LinearGradient(
                                            begin: Alignment.topCenter,
                                            end: Alignment.bottomCenter,
                                            stops: const [0.0, 0.48, 0.84, 1.0],
                                            colors: [
                                              Colors.black.withValues(
                                                alpha: 0.28,
                                              ),
                                              Colors.transparent,
                                              KonataTheme.cinemaObsidian
                                                  .withValues(alpha: 0.76),
                                              KonataTheme.cinemaObsidian,
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  16,
                                  4,
                                  16,
                                  18,
                                ),
                                child: Theme(
                                  data: KonataTheme.darkTheme(),
                                  child: DetailHeroInfo(
                                    bundle: bundle,
                                    imageLoader: imageLoader,
                                    showTitleText: displayPrefs.showTitleText,
                                    showTitleLogo: displayPrefs.showTitleLogo,
                                    showOverview: false,
                                    titleFontSize: 23,
                                    fullWidthPlayButton: true,
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
                                activeTab: phoneTab,
                                preferredTab: preferredTab,
                                displayPrefs: displayPrefs,
                                imageLoader: imageLoader,
                                players: players,
                                onToggleTab: (tab) {
                                  if (!_phonePortraitExpanded) {
                                    ref
                                            .read(
                                              detailDrawerTabProvider.notifier,
                                            )
                                            .state =
                                        tab;
                                    setState(
                                      () => _phonePortraitExpanded = true,
                                    );
                                  } else if (preferredTab == tab) {
                                    if (preferredTab == DetailDrawerTab.scan) {
                                      _scanScheduler.cancelAll();
                                    }
                                    setState(
                                      () => _phonePortraitExpanded = false,
                                    );
                                  } else {
                                    if (preferredTab == DetailDrawerTab.scan &&
                                        tab != DetailDrawerTab.scan) {
                                      _scanScheduler.cancelAll();
                                    }
                                    ref
                                            .read(
                                              detailDrawerTabProvider.notifier,
                                            )
                                            .state =
                                        tab;
                                  }
                                },
                                onCollapse: () {
                                  _scanScheduler.cancelAll();
                                  setState(
                                    () => _phonePortraitExpanded = false,
                                  );
                                },
                              ),
                              if (hasOverview) ...[
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
                                            color: Colors.white.withValues(
                                              alpha: 0.92,
                                            ),
                                            fontSize: 15,
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

                    // 桌面端与 Android 平板（含平板横屏）：完整展示背景大图与悬浮选集抽屉
                    final safeTop = MediaQuery.paddingOf(context).top;
                    final allowBackdropDecode =
                        !KonataAdaptiveTokens.isAndroid || isAndroidTablet;
                    final heroPadH = 36.0;
                    final bgPath = allowBackdropDecode
                        ? ((work.backdropPath != null &&
                                  work.backdropPath!.isNotEmpty)
                              ? work.backdropPath!
                              : (work.posterPath ?? ''))
                        : '';
                    final hasBackdrop =
                        work.backdropPath != null &&
                        work.backdropPath!.isNotEmpty;

                    return Stack(
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
                            filter: ImageFilter.blur(sigmaX: 28, sigmaY: 28),
                            child: Container(
                              color: Colors.black.withValues(alpha: 0.36),
                            ),
                          ),

                        // 零白边电影感自然暗影：深浅模式原画四周均保持 100% 纯净通透，仅在左下文字与底栏后保留柔和局部暗晕
                        IgnorePointer(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: RadialGradient(
                                center: const Alignment(-0.78, 0.58),
                                radius: 0.82,
                                stops: const [0.0, 0.52, 1.0],
                                colors: [
                                  Colors.black.withValues(alpha: 0.44),
                                  Colors.black.withValues(alpha: 0.16),
                                  Colors.transparent,
                                ],
                              ),
                            ),
                          ),
                        ),
                        IgnorePointer(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.bottomCenter,
                                end: Alignment.topCenter,
                                stops: isDrawerExpanded
                                    ? const [0.0, 0.22, 0.44]
                                    : const [0.0, 0.18],
                                colors: isDrawerExpanded
                                    ? [
                                        Colors.black.withValues(alpha: 0.78),
                                        Colors.black.withValues(alpha: 0.42),
                                        Colors.transparent,
                                      ]
                                    : [
                                        Colors.black.withValues(alpha: 0.30),
                                        Colors.transparent,
                                      ],
                              ),
                            ),
                          ),
                        ),

                        // 弹性垂直分栏：确保展开正片/特典抽屉时，主交互按钮与剧情简介完整向上顶起且永不遮挡
                        Positioned.fill(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              SizedBox(
                                height: KonataAdaptiveTokens.isAndroid
                                    ? safeTop + 60
                                    : 62,
                              ),
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
                                    child: DetailHeroInfo(
                                      bundle: bundle,
                                      imageLoader: imageLoader,
                                      showTitleText: displayPrefs.showTitleText,
                                      showTitleLogo: displayPrefs.showTitleLogo,
                                      showOverview: displayPrefs.showOverview,
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
                              ),
                              AnimatedPadding(
                                duration: KonataTheme.capsuleSlideDuration,
                                curve: Curves.easeOutCubic,
                                padding: EdgeInsets.only(
                                  bottom: bottomClearance,
                                ),
                                child: _buildBottomDrawer(
                                  bundle: bundle,
                                  layoutMode:
                                      DetailDrawerLayoutMode.bottomOverlay,
                                  activeTab: effectiveActiveTab,
                                  preferredTab: preferredTab,
                                  displayPrefs: displayPrefs,
                                  imageLoader: imageLoader,
                                  players: players,
                                  onToggleTab: (tab) {
                                    final currentExpanded = ref.read(
                                      detailDrawerExpandedProvider,
                                    );
                                    final currentTab = ref.read(
                                      detailDrawerTabProvider,
                                    );
                                    if (!currentExpanded) {
                                      ref
                                              .read(
                                                detailDrawerTabProvider
                                                    .notifier,
                                              )
                                              .state =
                                          tab;
                                      ref
                                              .read(
                                                detailDrawerExpandedProvider
                                                    .notifier,
                                              )
                                              .state =
                                          true;
                                    } else if (currentTab == tab) {
                                      if (currentTab == DetailDrawerTab.scan) {
                                        _scanScheduler.cancelAll();
                                      }
                                      ref
                                              .read(
                                                detailDrawerExpandedProvider
                                                    .notifier,
                                              )
                                              .state =
                                          false;
                                    } else {
                                      if (currentTab == DetailDrawerTab.scan &&
                                          tab != DetailDrawerTab.scan) {
                                        _scanScheduler.cancelAll();
                                      }
                                      ref
                                              .read(
                                                detailDrawerTabProvider
                                                    .notifier,
                                              )
                                              .state =
                                          tab;
                                    }
                                  },
                                  onCollapse: () {
                                    _scanScheduler.cancelAll();
                                    ref
                                            .read(
                                              detailDrawerExpandedProvider
                                                  .notifier,
                                            )
                                            .state =
                                        false;
                                  },
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    );
                  },
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (err, _) => _MissingWorkFallbackView(
                    title: '加载作品详情失败',
                    subtitle: '$err',
                    isError: true,
                    onReturnToLibrary: _returnToLibrary,
                  ),
                ),
                if (!(KonataAdaptiveTokens.isAndroid &&
                    MediaQuery.sizeOf(context).shortestSide <
                        KonataAdaptiveTokens.tabletBreakpoint &&
                    MediaQuery.sizeOf(context).width >
                        MediaQuery.sizeOf(context).height &&
                    hasActiveBundle))
                  Positioned(
                    top: KonataAdaptiveTokens.isAndroid
                        ? MediaQuery.paddingOf(context).top + 8
                        : 12,
                    left: KonataAdaptiveTokens.isAndroid ? 12 : 16,
                    right: 14,
                    child: _WorkDetailTopBar(
                      forceLightIcons: forceLightChrome,
                      showGlassChrome: hasActiveBundle,
                      onBack: _returnToLibrary,
                      trailingOps: (KonataAdaptiveTokens.isAndroid &&
                              MediaQuery.sizeOf(context).shortestSide <
                                  KonataAdaptiveTokens.tabletBreakpoint &&
                              bundleAsync.valueOrNull != null)
                          ? Builder(
                              builder: (_) {
                                final loaded = bundleAsync.valueOrNull!;
                                return DetailOpsCapsule(
                                  isExpanded: _phonePortraitExpanded,
                                  hasContent: _hasContentForTab(
                                    loaded,
                                    preferredTab,
                                    displayPrefs,
                                  ),
                                  showCollapseButton: false,
                                  openDownward: true,
                                  onOpenFullList: () => _drawerKey.currentState
                                      ?.openCurrentFullList(),
                                  onManualMatch: () =>
                                      _handleOpenManualMatch(loaded),
                                  onManualEdit: () =>
                                      _handleOpenManualEdit(loaded),
                                  onEditPoster: () =>
                                      DetailActionHandlers.openArtworkPicker(
                                        context,
                                        loaded,
                                        WorkArtworkKind.poster,
                                      ),
                                  onEditBackdrop: () =>
                                      DetailActionHandlers.openArtworkPicker(
                                        context,
                                        loaded,
                                        WorkArtworkKind.backdrop,
                                      ),
                                  onHideWork: () =>
                                      DetailActionHandlers.hideWorkAndPop(
                                        context,
                                        ref,
                                        loaded,
                                      ),
                                  onDeleteWork: () =>
                                      DetailActionHandlers.confirmDeleteAndPop(
                                        context,
                                        ref,
                                        loaded,
                                      ),
                                  onRescrape: () => _handleRescrape(loaded),
                                  onOpenLocalDir: () =>
                                      DetailActionHandlers.openLocalDirectory(
                                        context,
                                        ref,
                                        loaded,
                                      ),
                                  onManageSeries: () =>
                                      DetailActionHandlers.openSeriesManage(
                                        context,
                                        loaded,
                                      ),
                                  onMergeWork: () =>
                                      _handleOpenMergeWork(loaded),
                                );
                              },
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

/// 详情页顶部返回圆钮（供竖屏顶栏与横屏首行共用）。
class _WorkDetailBackCircle extends StatelessWidget {
  const _WorkDetailBackCircle({
    required this.forceLightIcons,
    required this.onBack,
  });

  final bool forceLightIcons;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final iconColor = forceLightIcons ? Colors.white : p.textPrimary;
    final bgColor = forceLightIcons
        ? Colors.black.withValues(alpha: 0.30)
        : p.surface;
    final borderColor = forceLightIcons
        ? Colors.white.withValues(alpha: 0.22)
        : p.hairline;
    final btnSize = KonataAdaptiveTokens.isAndroid
        ? KonataAdaptiveTokens.touchTarget
        : 38.0;

    return Semantics(
      button: true,
      label: '返回',
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: KonataPlaybackTokens.shadowColor(p),
              blurRadius: 12,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: SizedBox(
          key: const ValueKey('work_detail_back_button'),
          width: btnSize,
          height: btnSize,
          child: ClipOval(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
              child: Material(
                color: bgColor,
                shape: CircleBorder(side: BorderSide(color: borderColor)),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  hoverColor: forceLightIcons
                      ? Colors.white.withValues(alpha: 0.14)
                      : p.surfaceHover,
                  onTap: onBack,
                  child: Center(
                    child: Icon(
                      Icons.arrow_back_ios_new_rounded,
                      size: 16,
                      color: iconColor,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 详情页顶部常驻防死锁导航栏（左上返回按钮 + Windows 可拖拽标题区 + 右上控制胶囊）。
class _WorkDetailTopBar extends StatelessWidget {
  const _WorkDetailTopBar({
    required this.forceLightIcons,
    required this.showGlassChrome,
    required this.onBack,
    this.trailingOps,
  });

  final bool forceLightIcons;
  final bool showGlassChrome;
  final VoidCallback onBack;
  final Widget? trailingOps;

  @override
  Widget build(BuildContext context) {
    const dragZone = SizedBox(height: 38);

    return Row(
      children: [
        _WorkDetailBackCircle(
          forceLightIcons: forceLightIcons,
          onBack: onBack,
        ),
        Expanded(
          child: KonataAdaptiveTokens.isWindows
              ? DragToMoveArea(child: dragZone)
              : dragZone,
        ),
        if (trailingOps != null)
          trailingOps!
        else
          WindowControls(
            forceLightIcons: forceLightIcons,
            showGlassPill: showGlassChrome,
          ),
      ],
    );
  }
}

/// 当作品记录被合并、删除或失效时的安全空状态兜底视图（保持柔和克制，提供显式主操作返回按钮）。
class _MissingWorkFallbackView extends StatelessWidget {
  const _MissingWorkFallbackView({
    required this.onReturnToLibrary,
    this.title = '该作品记录已变更或移除',
    this.subtitle = '该条目的元数据可能已合并至其他作品或被移出媒体库。',
    this.isError = false,
  });

  final VoidCallback onReturnToLibrary;
  final String title;
  final String subtitle;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                isError
                    ? Icons.error_outline_rounded
                    : Icons.auto_stories_outlined,
                size: 48,
                color: isError ? p.danger : p.textMuted,
              ),
              const SizedBox(height: 14),
              Text(
                title,
                textAlign: TextAlign.center,
                style: KonataTheme.h2Style(p),
              ),
              const SizedBox(height: 8),
              Text(
                subtitle,
                textAlign: TextAlign.center,
                style: KonataTheme.captionStyle(
                  p,
                  fontSize: 13,
                  color: p.textSecondary,
                ),
              ),
              const SizedBox(height: 22),
              KonataPillButton.primary(
                label: '返回媒体库',
                icon: Icons.arrow_back_rounded,
                onPressed: onReturnToLibrary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
