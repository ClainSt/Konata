import 'dart:async';
import 'dart:math' as math;

import 'package:engine_scraping/engine_scraping.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_design_system/konata_design_system.dart';

import '../data/detail_display_preferences.dart';
import '../data/detail_edit_models.dart';
import '../providers.dart';
import '../state/detail_supplementary_view_data.dart';
import '../state/work_detail_controller.dart';
import 'detail_bottom_drawer.dart';
import 'detail_full_list_dialog.dart';
import 'detail_gear_menu.dart';
import 'detail_hero_info.dart';
import 'episode_media_info_dialog.dart';
import 'manual_match_dialog.dart';
import 'series_manage_dialog.dart';
import 'source_files_review_dialog.dart';
import 'variant_picker_dialog.dart';
import 'work_artwork_picker_dialog.dart';
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

  @override
  void dispose() {
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
        final targetEp = bundle.episodes.where((e) => e.id == epId.value).firstOrNull;
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
        episode: ep,
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
      episode: ep,
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
    var addToIgnore = false;
    final confirmed = await showKonataGlassDialog<bool>(
      context: context,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final p = ctx.palette;
          return KonataGlassDialog(
            width: 440,
            title: '移出媒体库 · ${work.title}',
            onClose: () => Navigator.of(ctx).pop(false),
            actions: [
              KonataPillButton.ghost(
                label: '取消',
                compact: true,
                onPressed: () => Navigator.of(ctx).pop(false),
              ),
              KonataPillButton.danger(
                label: '确认移出',
                compact: true,
                onPressed: () => Navigator.of(ctx).pop(true),
              ),
            ],
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '此操作仅移除媒体库索引记录与本地海报缓存，绝不会删除网盘或磁盘上的任何原始视频文件。',
                  style: KonataTheme.bodyLabelStyle(
                    p,
                    color: p.textSecondary,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    KonataSwitch(
                      value: addToIgnore,
                      onChanged: (v) => setDialogState(() => addToIgnore = v),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '同时将该目录加入忽略扫描名单',
                        style: KonataTheme.captionStyle(
                          p,
                        ).copyWith(color: p.textPrimary),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
    if (confirmed == true && mounted) {
      await controller.deleteWorkFromLibrary(addToIgnoreList: addToIgnore);
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

  @override
  Widget build(BuildContext context) {
    final controller = _resolveController();
    final imageLoader = _resolveImageLoader();
    final bottomClearance = KonataBottomClearanceScope.of(context);
    final safePad = MediaQuery.paddingOf(context);

    return Listener(
      onPointerDown: (event) {
        if ((event.buttons & kBackMouseButton) != 0) {
          unawaited(_handleBack(controller));
        }
      },
      child: CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.escape): () =>
              unawaited(_handleBack(controller)),
        },
        child: Focus(
          autofocus: true,
          child: ColoredBox(
            color: KonataTheme.cinemaObsidian,
            child: ListenableBuilder(
              listenable: controller,
              builder: (ctx, _) {
                final bundle = controller.bundle;
                if (controller.isLoading && bundle == null) {
                  return Stack(
                    fit: StackFit.expand,
                    children: [
                      const Center(child: CircularProgressIndicator()),
                      Positioned(
                        top: safePad.top + 12,
                        left: 16,
                        right: 16,
                        child: WorkDetailTopBar(
                          onBack: () => unawaited(_handleBack(controller)),
                        ),
                      ),
                    ],
                  );
                }
                if (controller.loadError != null && bundle == null) {
                  return MissingWorkFallbackView(
                    title: '加载作品详情失败',
                    subtitle: '${controller.loadError}',
                    isError: true,
                    onReturnToLibrary: () => unawaited(_handleBack(controller)),
                  );
                }
                if (bundle == null) {
                  return MissingWorkFallbackView(
                    onReturnToLibrary: () => unawaited(_handleBack(controller)),
                  );
                }

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
                    final isNarrowPortrait = size.width < 760;
                    final isShortLandscape =
                        size.height < 540 && size.width >= 480;

                    if (isNarrowPortrait || isShortLandscape) {
                      return _buildScrollableStage(
                        controller: controller,
                        bundle: bundle,
                        imageLoader: imageLoader,
                        viewport: size,
                        safePad: safePad,
                        bottomClearance: bottomClearance,
                      );
                    }
                    return _buildWideOverlayStage(
                      controller: controller,
                      bundle: bundle,
                      imageLoader: imageLoader,
                      safePad: safePad,
                      bottomClearance: bottomClearance,
                    );
                  },
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildWideOverlayStage({
    required WorkDetailController controller,
    required WorkDetailBundle bundle,
    required ManagedImageLoader imageLoader,
    required EdgeInsets safePad,
    required double bottomClearance,
  }) {
    final work = bundle.work;
    final prefs = controller.displayPreferences;
    final effectiveBackdrop = bundle.effectiveHeroBackdrop;
    final hasBackdrop = effectiveBackdrop != null;
    final fallbackPoster = (work.posterPath?.trim().isNotEmpty ?? false)
        ? work.posterPath!.trim()
        : (work.bangumiPosterPath?.trim() ?? '');
    final bgPath = hasBackdrop ? effectiveBackdrop.path : fallbackPoster;

    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned.fill(
          key: const ValueKey<String>('detail_wide_backdrop_stage'),
          child: DetailWideBackdropStage(
            workId: work.id,
            backdropOwnerWorkId: hasBackdrop
                ? effectiveBackdrop.ownerWorkId
                : work.id,
            bgPath: bgPath,
            hasBackdrop: hasBackdrop,
            fallbackPosterPath: fallbackPoster,
            showHeroBackdrop: prefs.showMainHeroBackdrop,
            imageLoader: imageLoader,
          ),
        ),
        Positioned.fill(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(height: safePad.top + 58),
              Expanded(
                child: Align(
                  alignment: Alignment.bottomLeft,
                  child: SingleChildScrollView(
                    controller: _wideHeroScrollCtrl,
                    padding: const EdgeInsets.fromLTRB(36, 8, 36, 14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _buildHeroInfo(controller, bundle, imageLoader, compact: false),
                        if (work.scrapeStatus != ScrapeStatus.matched) ...[
                          const SizedBox(height: 12),
                          _buildReviewBanner(controller, bundle, imageLoader),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
              Padding(
                padding: EdgeInsets.only(bottom: math.max(12.0, bottomClearance)),
                child: _buildBottomDrawer(
                  controller,
                  bundle,
                  imageLoader,
                  compact: false,
                  inlineMode: false,
                ),
              ),
            ],
          ),
        ),
        Positioned(
          top: safePad.top + 12,
          left: math.max(16.0, safePad.left + 12),
          right: math.max(16.0, safePad.right + 12),
          child: WorkDetailTopBar(
            onBack: () => unawaited(_handleBack(controller)),
          ),
        ),
      ],
    );
  }

  Widget _buildScrollableStage({
    required WorkDetailController controller,
    required WorkDetailBundle bundle,
    required ManagedImageLoader imageLoader,
    required Size viewport,
    required EdgeInsets safePad,
    required double bottomClearance,
  }) {
    final work = bundle.work;
    final prefs = controller.displayPreferences;
    final effectiveBackdrop = bundle.effectiveHeroBackdrop;
    final padH = math.max(16.0, safePad.left + 12);

    return Stack(
      fit: StackFit.expand,
      children: [
        SingleChildScrollView(
          key: const ValueKey<String>('detail_scrollable_stage'),
          controller: _portraitScrollCtrl,
          padding: EdgeInsets.only(bottom: 24 + bottomClearance),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DetailPortraitHeroHeader(
                work: work,
                imageLoader: imageLoader,
                viewportWidth: viewport.width,
                viewportHeight: viewport.height,
                backdropPathOverride: effectiveBackdrop?.path,
                backdropOwnerWorkId: effectiveBackdrop?.ownerWorkId,
                showHeroBackdrop: prefs.showMainHeroBackdrop,
              ),
              Padding(
                padding: EdgeInsets.fromLTRB(padH, 4, padH, 0),
                child: _buildHeroInfo(
                  controller,
                  bundle,
                  imageLoader,
                  compact: true,
                ),
              ),
              if (work.scrapeStatus != ScrapeStatus.matched) ...[
                const SizedBox(height: 12),
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: padH),
                  child: _buildReviewBanner(controller, bundle, imageLoader),
                ),
              ],
              const SizedBox(height: 16),
              _buildBottomDrawer(
                controller,
                bundle,
                imageLoader,
                compact: true,
                inlineMode: true,
              ),
            ],
          ),
        ),
        Positioned(
          top: safePad.top + 10,
          left: padH,
          right: padH,
          child: WorkDetailTopBar(
            onBack: () => unawaited(_handleBack(controller)),
          ),
        ),
      ],
    );
  }

  Widget _buildHeroInfo(
    WorkDetailController controller,
    WorkDetailBundle bundle,
    ManagedImageLoader imageLoader, {
    required bool compact,
  }) {
    return DetailHeroInfo(
      bundle: bundle,
      imageLoader: imageLoader,
      rescrapeState: controller.rescrapeState,
      displayPreferences: controller.displayPreferences,
      compact: compact,
      onPlayPrimary: () => unawaited(_handlePlayPrimary(controller, bundle)),
      onSelectSeriesWork: (targetId) =>
          unawaited(controller.switchSeriesMember(WorkId.trusted(targetId))),
      onDismissRescrape: controller.dismissRescrapeStatus,
      onBuiltInAction: (action) => unawaited(
        _handleBuiltInAction(controller, bundle, imageLoader, action),
      ),
      onInvokeExternalAction: (action) =>
          unawaited(_handleInvokeExternalAction(bundle, action)),
    );
  }

  Widget _buildReviewBanner(
    WorkDetailController controller,
    WorkDetailBundle bundle,
    ManagedImageLoader imageLoader,
  ) {
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

  Widget _buildBottomDrawer(
    WorkDetailController controller,
    WorkDetailBundle bundle,
    ManagedImageLoader imageLoader, {
    required bool compact,
    required bool inlineMode,
  }) {
    final prefs = controller.displayPreferences;
    return DetailBottomDrawer(
      bundle: bundle,
      imageLoader: imageLoader,
      displayPreferences: prefs,
      initialTabId: widget.initialTabId,
      compact: compact,
      inlineMode: inlineMode,
      onTapEpisode: (ep) => unawaited(_handleTapEpisode(controller, bundle, ep)),
      onTapCdVariant: (variant) =>
          unawaited(_handleTapCdVariant(controller, variant)),
      onInspectEpisodeInfo: (ep) => unawaited(_handleInspectEpisodeInfo(bundle, ep)),
      onOpenFullList: (tabId) => unawaited(
        _handleOpenFullList(controller, bundle, imageLoader, prefs, tabId),
      ),
    );
  }
}
