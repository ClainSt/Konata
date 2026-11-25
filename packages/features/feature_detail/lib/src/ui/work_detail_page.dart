import 'dart:async';

import 'package:engine_scraping/engine_scraping.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_design_system/konata_design_system.dart';

import '../data/artwork_dominant_color.dart';
import '../data/detail_display_preferences.dart';
import '../data/detail_edit_models.dart';
import '../providers.dart';
import '../state/detail_supplementary_view_data.dart';
import '../state/work_detail_controller.dart';
import 'detail_full_list_dialog.dart';
import 'detail_gear_menu.dart';
import 'episode_media_info_dialog.dart';
import 'manual_match_dialog.dart';
import 'series_manage_dialog.dart';
import 'source_files_review_dialog.dart';
import 'variant_picker_dialog.dart';
import 'work_artwork_picker_dialog.dart';
import 'work_detail_stage_layouts.dart';
import 'work_detail_sub_views.dart';
import 'work_manual_edit_dialog.dart';
import 'work_merge_target_dialog.dart';
import 'work_review_banner.dart';

/// 作品详情页主舞台（三端自适应全屏沉浸详情页、选集与附属资源抽屉、动态扩展点宿主）。
class WorkDetailPage extends ConsumerStatefulWidget {
  /// 创建番剧详情页组件。
  const WorkDetailPage({
    super.key,
    required this.workId,
    this.initialTabId,
    this.controllerOverride,
    this.imageLoaderOverride,
  });

  /// 目标作品唯一标识。
  final WorkId workId;

  /// 可选初始高亮分页（如深链直达 `cd` 或外部扩展标签 ID）。
  final String? initialTabId;

  /// 可选外部注入的详情状态控制器（主要用于无全量组装根下的组件测试）。
  final WorkDetailController? controllerOverride;

  /// 可选外部注入的受管图片加载器（主要用于组件测试离线桩图）。
  final ManagedImageLoader? imageLoaderOverride;

  @override
  ConsumerState<WorkDetailPage> createState() => _WorkDetailPageState();
}

class _WorkDetailPageState extends ConsumerState<WorkDetailPage> {
  final ScrollController _portraitScrollCtrl = ScrollController();
  final ScrollController _wideHeroScrollCtrl = ScrollController();
  bool _rematching = false;
  late bool _drawerExpanded;
  bool _lockedPortraitOrientation = false;
  String? _sampledDissolveKey;
  Color? _sampledDissolveColor;

  @override
  void initState() {
    super.initState();
    _drawerExpanded = widget.initialTabId?.trim().isNotEmpty ?? false;
    final platform =
        widget.controllerOverride?.platform ??
        ref.read(workDetailControllerProvider(widget.workId)).platform;
    if (platform == KonataPlatform.androidPhone) {
      _lockedPortraitOrientation = true;
      unawaited(
        SystemChrome.setPreferredOrientations(const <DeviceOrientation>[
          DeviceOrientation.portraitUp,
        ]),
      );
    }
  }

  @override
  void didUpdateWidget(covariant WorkDetailPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.workId != widget.workId ||
        oldWidget.initialTabId != widget.initialTabId) {
      _drawerExpanded = widget.initialTabId?.trim().isNotEmpty ?? false;
      _sampledDissolveKey = null;
      _sampledDissolveColor = null;
    }
  }

  @override
  void dispose() {
    if (_lockedPortraitOrientation) {
      unawaited(
        SystemChrome.setPreferredOrientations(DeviceOrientation.values),
      );
    }
    _portraitScrollCtrl.dispose();
    _wideHeroScrollCtrl.dispose();
    super.dispose();
  }

  WorkDetailController _resolveController() {
    return widget.controllerOverride ??
        ref.watch(workDetailControllerProvider(widget.workId));
  }

  ManagedImageLoader _resolveImageLoader() {
    return widget.imageLoaderOverride ??
        ref.watch(detailManagedImageLoaderProvider);
  }

  Future<void> _handleBack(WorkDetailController controller) async {
    final popped = await controller.navigateBack();
    if (!popped && mounted) {
      Navigator.of(context).maybePop();
    }
  }

  Future<void> _handlePlayPrimary(
    WorkDetailController controller,
    WorkDetailBundle bundle,
  ) async {
    final plan = bundle.resumePlan;
    if (plan != null) {
      final epId = plan.targetEpisode.id;
      final epVariants = bundle.variantsForEpisode(epId.value);
      if (epVariants.length > 1) {
        final targetEp = bundle.episodes
            .where((e) => e.id == epId.value)
            .firstOrNull;
        if (targetEp != null) {
          await _handleTapEpisode(controller, bundle, targetEp);
          return;
        }
      }
      await controller.playEpisode(
        episodeId: epId,
        variantId: epVariants.isNotEmpty
            ? VariantId.trusted(epVariants.first.id)
            : null,
      );
      return;
    }
    if (bundle.mainEpisodes.isNotEmpty) {
      await _handleTapEpisode(controller, bundle, bundle.mainEpisodes.first);
      return;
    }
    if (bundle.episodes.isNotEmpty) {
      await _handleTapEpisode(controller, bundle, bundle.episodes.first);
      return;
    }
    if (bundle.cdVariants.isNotEmpty) {
      await controller.playCdAlbum(
        variantId: VariantId.trusted(bundle.cdVariants.first.id),
      );
    }
  }

  Future<void> _handleTapEpisode(
    WorkDetailController controller,
    WorkDetailBundle bundle,
    Episode ep,
  ) async {
    final variants = bundle.variantsForEpisode(ep.id);
    if (variants.length > 1) {
      final episodeTitle = EpisodeTitleFormatter.formatCardTitle(
        episode: DetailSupplementaryHelper.toEpisodeSummaryView(ep),
        workTitle: bundle.work.title,
        workMediaType: bundle.work.tmdbMediaType,
        mainEpisodeCount: bundle.mainEpisodes.length,
      );
      await showKonataGlassDialog<void>(
        context: context,
        builder: (_) => VariantPickerDialog(
          episodeTitle: episodeTitle,
          variants: variants,
          sourcesById: bundle.sourcesById,
          onSelectVariant: (variant) {
            unawaited(
              controller.playEpisode(
                episodeId: EpisodeId.trusted(ep.id),
                variantId: VariantId.trusted(variant.id),
              ),
            );
          },
        ),
      );
      return;
    }
    await controller.playEpisode(
      episodeId: EpisodeId.trusted(ep.id),
      variantId: variants.isNotEmpty
          ? VariantId.trusted(variants.first.id)
          : null,
    );
  }

  Future<void> _handleTapCdVariant(
    WorkDetailController controller,
    MediaVariant variant,
  ) async {
    await controller.playCdAlbum(variantId: VariantId.trusted(variant.id));
  }

  Future<void> _handleInspectEpisodeInfo(
    WorkDetailBundle bundle,
    Episode ep,
  ) async {
    final heading = EpisodeTitleFormatter.formatCardTitle(
      episode: DetailSupplementaryHelper.toEpisodeSummaryView(ep),
      workTitle: bundle.work.title,
      workMediaType: bundle.work.tmdbMediaType,
      mainEpisodeCount: bundle.mainEpisodes.length,
    );
    await showKonataGlassDialog<void>(
      context: context,
      builder: (_) => EpisodeMediaInfoDialog(
        episodeTitle: heading,
        variants: bundle.variantsForEpisode(ep.id),
        sourcesById: bundle.sourcesById,
      ),
    );
  }

  Future<void> _handleOpenFullList(
    WorkDetailController controller,
    WorkDetailBundle bundle,
    ManagedImageLoader imageLoader,
    DetailDisplayPreferences prefs,
    String tabId,
  ) async {
    await showKonataGlassDialog<void>(
      context: context,
      builder: (dialogCtx) => DetailFullListDialog(
        bundle: bundle,
        initialTabId: tabId,
        cdCoverLoader: widget.controllerOverride == null
            ? ref.read(detailCdCoverLoaderProvider)
            : null,
        imageLoader: imageLoader,
        displayPreferences: prefs,
        onTapEpisode: (ep) {
          Navigator.of(dialogCtx).pop();
          unawaited(_handleTapEpisode(controller, bundle, ep));
        },
        onTapCdVariant: (variant) {
          Navigator.of(dialogCtx).pop();
          unawaited(_handleTapCdVariant(controller, variant));
        },
        onInspectEpisodeInfo: (ep) => _handleInspectEpisodeInfo(bundle, ep),
      ),
    );
  }

  Future<void> _handleBuiltInAction(
    WorkDetailController controller,
    WorkDetailBundle bundle,
    ManagedImageLoader imageLoader,
    DetailBuiltInGearAction action,
  ) async {
    switch (action) {
      case DetailBuiltInGearAction.rescrape:
        await controller.rescrapeMetadata();
      case DetailBuiltInGearAction.syncDirectory:
        final res = await controller.syncWorkDirectory();
        if (!mounted) return;
        showKonataToast(
          context,
          res.workRemoved
              ? '所在目录源文件已移除，已清理记录'
              : (res.changed ? '源目录变更已同步更新' : '目录文件已是最新状态'),
        );
      case DetailBuiltInGearAction.editPoster:
        await showKonataGlassDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (_) => WorkArtworkPickerDialog(
            controller: controller,
            work: bundle.work,
            imageLoader: imageLoader,
            kind: WorkArtworkKind.poster,
          ),
        );
      case DetailBuiltInGearAction.editBackdrop:
        await showKonataGlassDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (_) => WorkArtworkPickerDialog(
            controller: controller,
            work: bundle.work,
            imageLoader: imageLoader,
            kind: WorkArtworkKind.backdrop,
          ),
        );
      case DetailBuiltInGearAction.editPortraitBackdrop:
        await showKonataGlassDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (_) => WorkArtworkPickerDialog(
            controller: controller,
            work: bundle.work,
            imageLoader: imageLoader,
            kind: WorkArtworkKind.portraitBackdrop,
          ),
        );
      case DetailBuiltInGearAction.editLogo:
        await showKonataGlassDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (_) => WorkArtworkPickerDialog(
            controller: controller,
            work: bundle.work,
            imageLoader: imageLoader,
            kind: WorkArtworkKind.logo,
          ),
        );
      case DetailBuiltInGearAction.manualEdit:
        await showKonataGlassDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (_) => WorkManualEditDialog(
            controller: controller,
            bundle: bundle,
            imageLoader: imageLoader,
          ),
        );
      case DetailBuiltInGearAction.manualMatch:
        await showKonataGlassDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (_) => ManualMatchDialog(
            controller: controller,
            bundle: bundle,
            imageLoader: imageLoader,
          ),
        );
      case DetailBuiltInGearAction.manageSeries:
        await showKonataGlassDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (_) => SeriesManageDialog(
            controller: controller,
            anchorWork: bundle.work,
            initialSeries: bundle.seriesGroup,
            initialMembers: bundle.seriesMembers,
            imageLoader: imageLoader,
          ),
        );
      case DetailBuiltInGearAction.mergeIntoWork:
        final outcome = await showKonataGlassDialog<WorkMergeOutcome>(
          context: context,
          barrierDismissible: false,
          builder: (_) => WorkMergeTargetDialog(
            controller: controller,
            sourceWorkId: bundle.work.id,
            sourceWorkTitle: bundle.work.title,
            imageLoader: imageLoader,
          ),
        );
        if (outcome != null && outcome.sourceWorkDeleted && mounted) {
          await controller.switchSeriesMember(
            WorkId.trusted(outcome.targetWork.id),
          );
        }
      case DetailBuiltInGearAction.markAllWatched:
        await controller.markAllMainEpisodesWatched();
        if (mounted) {
          showKonataToast(context, '已将全部正片标为已看完');
        }
      case DetailBuiltInGearAction.clearHistory:
        await controller.clearWorkPlaybackHistory();
        if (mounted) {
          showKonataToast(context, '已清空作品播放记录');
        }
      case DetailBuiltInGearAction.toggleHidden:
        final nextHidden = !bundle.work.isHidden;
        await controller.setWorkHidden(hidden: nextHidden);
        if (mounted) {
          showKonataToast(context, nextHidden ? '已从媒体库隐藏该作品' : '已恢复显示该作品');
        }
      case DetailBuiltInGearAction.deleteFromLibrary:
        await _confirmAndDeleteWork(controller, bundle.work);
    }
  }

  Future<void> _confirmAndDeleteWork(
    WorkDetailController controller,
    Work work,
  ) async {
    final result = await showConfirmDeleteWorkDialog(
      context,
      workTitle: work.title,
    );
    if (result != null && result.confirmed && mounted) {
      await controller.deleteWorkFromLibrary(
        addToIgnoreList: result.addToIgnore,
      );
      if (mounted) {
        await _handleBack(controller);
      }
    }
  }

  Future<void> _handleInvokeExternalAction(
    WorkDetailBundle bundle,
    DetailActionContribution action,
  ) async {
    await action.onInvoke(
      ViewSlotContext(
        platformContext: context,
        workId: WorkId.trusted(bundle.work.id),
        arguments: <String, Object?>{
          'workTitle': bundle.work.title,
          'seriesId': bundle.work.seriesId,
        },
      ),
    );
  }

  Future<void> _handleRematch(WorkDetailController controller) async {
    if (_rematching) return;
    setState(() => _rematching = true);
    try {
      await controller.rematchReviewWork();
    } catch (error) {
      if (mounted) {
        showKonataToast(context, '重新匹配失败：$error', isError: true);
      }
    } finally {
      if (mounted) {
        setState(() => _rematching = false);
      }
    }
  }

  List<DetailActionContribution> _mergedExternalActions(
    WorkDetailBundle bundle,
  ) {
    final merged = <DetailActionContribution>[];
    final seenIds = <String>{};
    for (final action in bundle.primaryBarActions) {
      if (seenIds.add(action.id)) {
        merged.add(action);
      }
    }
    for (final action in bundle.gearMenuActions) {
      if (seenIds.add(action.id)) {
        merged.add(action);
      }
    }
    return merged;
  }

  Color? _resolvePortraitDissolveColor({
    required Work work,
    required ManagedImageLoader imageLoader,
    required bool isDark,
    required Color themeBg,
  }) {
    final portraitPath = (work.portraitBackdropPath ?? '').trim();
    final posterPath = (work.posterPath?.trim().isNotEmpty ?? false)
        ? work.posterPath!.trim()
        : (work.bangumiPosterPath?.trim() ?? '');
    final sourcePath = portraitPath.isNotEmpty ? portraitPath : posterPath;
    if (sourcePath.isEmpty) {
      return null;
    }

    final cacheKey = '${work.id}|$sourcePath';
    final cached = ArtworkDominantColor.getCached(
      cacheKey: cacheKey,
      isDark: isDark,
    );
    if (cached != null) {
      return cached;
    }

    final requestKey = '$cacheKey|${isDark ? 'd' : 'l'}';
    if (_sampledDissolveKey != requestKey) {
      _sampledDissolveKey = requestKey;
      final Future<Uint8List> fetchFuture = imageLoader is ManagedArtworkLoader
          ? imageLoader(
              sourcePath,
              targetWidth: 300,
              ownerWorkId: work.id,
              artwork: ManagedArtwork.poster,
            )
          : imageLoader(sourcePath, targetWidth: 300);
      unawaited(
        fetchFuture
            .then(
              (bytes) => ArtworkDominantColor.sampleBottomDissolveColor(
                bytes: bytes,
                cacheKey: cacheKey,
                isDark: isDark,
                themeBackground: themeBg,
              ),
            )
            .then((color) {
              if (!mounted ||
                  _sampledDissolveKey != requestKey ||
                  color == null) {
                return;
              }
              setState(() => _sampledDissolveColor = color);
            })
            .catchError((Object _) {}),
      );
    }
    return _sampledDissolveColor;
  }

  Widget? _maybeBuildReviewBanner(
    WorkDetailController controller,
    WorkDetailBundle bundle,
    ManagedImageLoader imageLoader,
  ) {
    if (bundle.work.scrapeStatus == ScrapeStatus.matched) return null;
    return WorkReviewBanner(
      work: bundle.work,
      candidates: bundle.scrapeCandidates,
      folderPath: bundle.folderPath,
      rematching: _rematching,
      onRematch: () => unawaited(_handleRematch(controller)),
      onOpenManualMatch: () => unawaited(
        _handleBuiltInAction(
          controller,
          bundle,
          imageLoader,
          DetailBuiltInGearAction.manualMatch,
        ),
      ),
      onOpenSourceFiles: () => unawaited(
        showSourceFilesReviewDialog(
          context: context,
          controller: controller,
          bundle: bundle,
          imageLoader: imageLoader,
        ),
      ),
      onDismissReview: () => unawaited(controller.dismissWorkReview()),
      onSelectCandidate: (cand) => unawaited(
        controller.rebindWorkToTmdb(
          tmdbId: cand.tmdbId,
          mediaType: cand.mediaType,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = _resolveController();
    final imageLoader = _resolveImageLoader();
    final p = context.palette;
    final bottomClearance = KonataBottomClearanceScope.of(context);
    final safePad = MediaQuery.paddingOf(context);
    final platform = controller.platform;

    return Listener(
      onPointerDown: (event) {
        if ((event.buttons & kBackMouseButton) != 0) {
          unawaited(_handleBack(controller));
        }
      },
      child: CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.escape): () {
            if (platform != KonataPlatform.androidPhone && _drawerExpanded) {
              setState(() => _drawerExpanded = false);
              return;
            }
            unawaited(_handleBack(controller));
          },
        },
        child: Focus(
          autofocus: true,
          child: ListenableBuilder(
            listenable: controller,
            builder: (ctx, _) {
              final bundle = controller.bundle;
              if (controller.isLoading && bundle == null) {
                return ColoredBox(
                  color: platform == KonataPlatform.androidPhone
                      ? p.canvas
                      : KonataTheme.cinemaObsidian,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      const Center(child: CircularProgressIndicator()),
                      Positioned(
                        top: safePad.top + 12,
                        left: 16,
                        right: 16,
                        child: WorkDetailTopBar(
                          showDesktopChrome:
                              platform != KonataPlatform.androidPhone,
                          onBack: () => unawaited(_handleBack(controller)),
                        ),
                      ),
                    ],
                  ),
                );
              }
              if (controller.loadError != null && bundle == null) {
                return ColoredBox(
                  color: p.canvas,
                  child: MissingWorkFallbackView(
                    title: '加载作品详情失败',
                    subtitle: '${controller.loadError}',
                    isError: true,
                    onReturnToLibrary: () => unawaited(_handleBack(controller)),
                  ),
                );
              }
              if (bundle == null) {
                return ColoredBox(
                  color: p.canvas,
                  child: MissingWorkFallbackView(
                    onReturnToLibrary: () => unawaited(_handleBack(controller)),
                  ),
                );
              }

              final mergedExternal = _mergedExternalActions(bundle);
              final reviewBanner = _maybeBuildReviewBanner(
                controller,
                bundle,
                imageLoader,
              );
              final prefs = controller.displayPreferences;

              return LayoutBuilder(
                builder: (_, constraints) {
                  final size = Size(
                    constraints.maxWidth.isFinite
                        ? constraints.maxWidth
                        : MediaQuery.sizeOf(ctx).width,
                    constraints.maxHeight.isFinite
                        ? constraints.maxHeight
                        : MediaQuery.sizeOf(ctx).height,
                  );
                  final isPhone = platform == KonataPlatform.androidPhone;
                  final isTabletPortrait =
                      platform == KonataPlatform.androidTablet &&
                      size.height > size.width;
                  final isNarrowWindowFallback = !isPhone && size.width < 760;
                  final isShortLandscapeFallback =
                      !isPhone && size.height < 540 && size.width >= 480;

                  if (isPhone ||
                      isTabletPortrait ||
                      isNarrowWindowFallback ||
                      isShortLandscapeFallback) {
                    final dissolveColor =
                        _resolvePortraitDissolveColor(
                          work: bundle.work,
                          imageLoader: imageLoader,
                          isDark: p.isDark,
                          themeBg: p.canvas,
                        ) ??
                        p.canvas;
                    return ColoredBox(
                      color: dissolveColor,
                      child: DetailPortraitStageLayout(
                        cdCoverLoader: widget.controllerOverride == null
                            ? ref.watch(detailCdCoverLoaderProvider)
                            : null,
                        bundle: bundle,
                        displayPreferences: prefs,
                        rescrapeState: controller.rescrapeState,
                        imageLoader: imageLoader,
                        scrollController: _portraitScrollCtrl,
                        viewport: size,
                        safePad: safePad,
                        bottomClearance: bottomClearance,
                        dissolveColor: dissolveColor,
                        isPhone: isPhone,
                        showDesktopChrome: platform == KonataPlatform.windows,
                        drawerExpanded: _drawerExpanded,
                        mergedExternalActions: mergedExternal,
                        initialTabId: widget.initialTabId,
                        reviewBanner: reviewBanner,
                        onBack: () => unawaited(_handleBack(controller)),
                        onDrawerExpandedChanged: (next) =>
                            setState(() => _drawerExpanded = next),
                        onPlayPrimary: () =>
                            unawaited(_handlePlayPrimary(controller, bundle)),
                        onSelectSeriesWork: (targetId) => unawaited(
                          controller.switchSeriesMember(
                            WorkId.trusted(targetId),
                          ),
                        ),
                        onDismissRescrape: controller.dismissRescrapeStatus,
                        onBuiltInAction: (action) => unawaited(
                          _handleBuiltInAction(
                            controller,
                            bundle,
                            imageLoader,
                            action,
                          ),
                        ),
                        onInvokeExternalAction: (action) => unawaited(
                          _handleInvokeExternalAction(bundle, action),
                        ),
                        onTapEpisode: (ep) => unawaited(
                          _handleTapEpisode(controller, bundle, ep),
                        ),
                        onTapCdVariant: (variant) =>
                            unawaited(_handleTapCdVariant(controller, variant)),
                        onInspectEpisodeInfo: (ep) =>
                            unawaited(_handleInspectEpisodeInfo(bundle, ep)),
                        onOpenFullList: (tabId) => unawaited(
                          _handleOpenFullList(
                            controller,
                            bundle,
                            imageLoader,
                            prefs,
                            tabId,
                          ),
                        ),
                      ),
                    );
                  }

                  return ColoredBox(
                    color: KonataTheme.cinemaObsidian,
                    child: DetailWideOverlayStageLayout(
                      cdCoverLoader: widget.controllerOverride == null
                          ? ref.watch(detailCdCoverLoaderProvider)
                          : null,
                      bundle: bundle,
                      displayPreferences: prefs,
                      rescrapeState: controller.rescrapeState,
                      imageLoader: imageLoader,
                      heroScrollController: _wideHeroScrollCtrl,
                      safePad: safePad,
                      bottomClearance: bottomClearance,
                      drawerExpanded: _drawerExpanded,
                      mergedExternalActions: mergedExternal,
                      initialTabId: widget.initialTabId,
                      reviewBanner: reviewBanner,
                      onBack: () => unawaited(_handleBack(controller)),
                      onCollapseDrawer: () =>
                          setState(() => _drawerExpanded = false),
                      onDrawerExpandedChanged: (next) =>
                          setState(() => _drawerExpanded = next),
                      onPlayPrimary: () =>
                          unawaited(_handlePlayPrimary(controller, bundle)),
                      onSelectSeriesWork: (targetId) => unawaited(
                        controller.switchSeriesMember(WorkId.trusted(targetId)),
                      ),
                      onDismissRescrape: controller.dismissRescrapeStatus,
                      onBuiltInAction: (action) => unawaited(
                        _handleBuiltInAction(
                          controller,
                          bundle,
                          imageLoader,
                          action,
                        ),
                      ),
                      onInvokeExternalAction: (action) => unawaited(
                        _handleInvokeExternalAction(bundle, action),
                      ),
                      onTapEpisode: (ep) =>
                          unawaited(_handleTapEpisode(controller, bundle, ep)),
                      onTapCdVariant: (variant) =>
                          unawaited(_handleTapCdVariant(controller, variant)),
                      onInspectEpisodeInfo: (ep) =>
                          unawaited(_handleInspectEpisodeInfo(bundle, ep)),
                      onOpenFullList: (tabId) => unawaited(
                        _handleOpenFullList(
                          controller,
                          bundle,
                          imageLoader,
                          prefs,
                          tabId,
                        ),
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ),
      ),
    );
  }
}
