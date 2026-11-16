import 'dart:ui';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/playback/playback_preferences_provider.dart';
import '../../application/providers/artwork_provider.dart';
import '../../application/providers/detail_display_preferences_provider.dart';
import '../../application/providers/library_providers.dart';
import '../../application/providers/scraping_providers.dart';
import '../../application/providers/work_management_provider.dart';
import '../../domain/models/tmdb_models.dart';
import '../../infrastructure/cache/scan_thumbnail_scheduler.dart';
import '../dialogs/work_artwork_picker_dialog.dart';
import '../shell/window_controls.dart';
import '../theme/konata_palette.dart';
import '../theme/konata_theme.dart';
import '../widgets/design_system/konata_toast.dart';
import '../widgets/managed_image.dart';
import 'detail_action_handlers.dart';
import 'detail_bottom_drawer.dart';
import 'detail_hero_info.dart';

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
    if (ref.read(detailDrawerExpandedProvider)) {
      _scanScheduler.cancelAll();
      ref.read(detailDrawerExpandedProvider.notifier).state = false;
      return;
    }
    Navigator.of(context).maybePop();
  }

  void _showToast(String message) {
    if (!mounted) return;
    showKonataToast(context, message);
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
    final players =
        ref.watch(externalPlayersProvider).valueOrNull ?? const [];
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

    return Listener(
      onPointerDown: (event) {
        if ((event.buttons & kBackMouseButton) != 0) {
          _handleEscapeOrBack();
        }
      },
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape):
              _handleEscapeOrBack,
        },
        child: Scaffold(
          backgroundColor: KonataTheme.cinemaObsidian,
          body: bundleAsync.when(
            data: (bundle) {
              if (bundle == null) {
                return const Center(
                  child: Text(
                    '未找到该作品记录',
                    style: TextStyle(color: Colors.white70),
                  ),
                );
              }
              final work = bundle.work;
              _maybeBackfillBangumiScore(work.id, work.bangumiScore);
              final bgPath =
                  (work.backdropPath != null && work.backdropPath!.isNotEmpty)
                  ? work.backdropPath!
                  : (work.posterPath ?? '');
              final hasBackdrop =
                  work.backdropPath != null && work.backdropPath!.isNotEmpty;

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
                        color: KonataTheme.cinemaObsidian.withValues(
                          alpha: 0.34,
                        ),
                      ),
                    ),

                  // 左侧极轻柔羽化保护层（48% 处彻底归零，保留原画右侧与人物通透色彩）
                  IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.centerLeft,
                          end: Alignment.centerRight,
                          stops: const [0.0, 0.24, 0.48],
                          colors: [
                            Colors.black.withValues(alpha: 0.28),
                            Colors.black.withValues(alpha: 0.12),
                            Colors.transparent,
                          ],
                        ),
                      ),
                    ),
                  ),
                  // 底部 28% 边缘柔和渐暗层，专门承托底部无框悬浮剧集卡片文字
                  IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.bottomCenter,
                          end: Alignment.topCenter,
                          stops: const [0.0, 0.28],
                          colors: [
                            Colors.black.withValues(alpha: 0.52),
                            Colors.transparent,
                          ],
                        ),
                      ),
                    ),
                  ),

                  // 顶部 56px 极淡保护带，轻柔承托左上返回键与右上窗口控制键
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    height: 56,
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.black.withValues(alpha: 0.22),
                              Colors.transparent,
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),

                  // 弹性垂直分栏：确保展开正片/特典抽屉时，主交互按钮与剧情简介完整向上顶起且永不遮挡
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
                                36,
                                8,
                                36,
                                effectiveActiveTab == null ? 24 : 18,
                              ),
                              child: DetailHeroInfo(
                                bundle: bundle,
                                imageLoader: imageLoader,
                                onPrimaryPlay: () =>
                                    DetailActionHandlers.handlePrimaryPlay(
                                      context: context,
                                      ref: ref,
                                      bundle: bundle,
                                      players: players,
                                    ),
                                onManualMatch: () =>
                                    DetailActionHandlers.openManualMatch(
                                      context,
                                      bundle,
                                    ),
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
                        DetailBottomDrawer(
                          bundle: bundle,
                          activeTab: effectiveActiveTab,
                          preferredTab: preferredTab,
                          showRawVideoFilename:
                              displayPrefs.showRawVideoFilename,
                          showCdTab: displayPrefs.showCdTab,
                          showScanTab: displayPrefs.showScanTab,
                          imageLoader: imageLoader,
                          onToggleTab: (tab) {
                            final currentExpanded = ref.read(
                              detailDrawerExpandedProvider,
                            );
                            final currentTab = ref.read(detailDrawerTabProvider);
                            if (!currentExpanded) {
                              ref.read(detailDrawerTabProvider.notifier).state =
                                  tab;
                              ref
                                      .read(
                                        detailDrawerExpandedProvider.notifier,
                                      )
                                      .state =
                                  true;
                            } else if (currentTab == tab) {
                              if (currentTab == DetailDrawerTab.scan) {
                                _scanScheduler.cancelAll();
                              }
                              ref
                                      .read(
                                        detailDrawerExpandedProvider.notifier,
                                      )
                                      .state =
                                  false;
                            } else {
                              if (currentTab == DetailDrawerTab.scan &&
                                  tab != DetailDrawerTab.scan) {
                                _scanScheduler.cancelAll();
                              }
                              ref.read(detailDrawerTabProvider.notifier).state =
                                  tab;
                            }
                          },
                          onCollapse: () {
                            _scanScheduler.cancelAll();
                            ref
                                    .read(detailDrawerExpandedProvider.notifier)
                                    .state =
                                false;
                          },
                          onSecondaryFilterChanged: _scanScheduler.cancelAll,
                          onEpisodeTap: (ep) =>
                              DetailActionHandlers.playEpisode(
                                context: context,
                                ref: ref,
                                bundle: bundle,
                                episode: ep,
                                players: players,
                              ),
                          onEpisodePlayBuiltin: (ep) =>
                              DetailActionHandlers.playEpisode(
                                context: context,
                                ref: ref,
                                bundle: bundle,
                                episode: ep,
                                players: players,
                                overrideEngine:
                                    PreferredPlaybackEngine.builtinLibmpv,
                              ),
                          onEpisodePlayExternal: (ep) =>
                              DetailActionHandlers.playEpisode(
                                context: context,
                                ref: ref,
                                bundle: bundle,
                                episode: ep,
                                players: players,
                                overrideEngine:
                                    PreferredPlaybackEngine.externalPlayer,
                              ),
                          onEpisodeMarkCompleted: (ep) =>
                              DetailActionHandlers.markEpisodeCompleted(
                                context: context,
                                ref: ref,
                                bundle: bundle,
                                episode: ep,
                              ),
                          onEpisodeAdjustSlot: (ep) =>
                              DetailActionHandlers.showAdjustEpisodeDialog(
                                context: context,
                                ref: ref,
                                episode: ep,
                              ),
                          onOpenManualMatch: () async {
                            final matched = await DetailActionHandlers.openManualMatch(
                              context,
                              bundle,
                            );
                            if (matched != null &&
                                matched.id != bundle.work.id &&
                                mounted) {
                              setState(() => _activeWorkId = matched.id);
                              _showToast('已自动并入已有作品「${matched.title}」');
                            }
                          },
                          onOpenManualEdit: () =>
                              DetailActionHandlers.openManualEdit(
                                context,
                                bundle,
                              ),
                          onOpenPosterPicker: () =>
                              DetailActionHandlers.openArtworkPicker(
                                context,
                                bundle,
                                WorkArtworkKind.poster,
                              ),
                          onOpenBackdropPicker: () =>
                              DetailActionHandlers.openArtworkPicker(
                                context,
                                bundle,
                                WorkArtworkKind.backdrop,
                              ),
                          onHideWork: () => DetailActionHandlers.hideWorkAndPop(
                            context,
                            ref,
                            bundle,
                          ),
                          onDeleteWork: () =>
                              DetailActionHandlers.confirmDeleteAndPop(
                                context,
                                ref,
                                bundle,
                              ),
                          onRescrape: () async {
                            if (work.tmdbId != null &&
                                work.tmdbMediaType != null) {
                              final updated = await ref
                                  .read(scrapeControllerProvider.notifier)
                                  .rebindWork(
                                    workId: work.id,
                                    tmdbId: work.tmdbId!,
                                    mediaType: work.tmdbMediaType!,
                                  );
                              if (mounted && updated.id != work.id) {
                                setState(() => _activeWorkId = updated.id);
                                _showToast('已自动并入已有作品「${updated.title}」');
                              } else {
                                _showToast('已完成元数据刷新');
                              }
                            } else {
                              _showToast('当前作品尚未绑定 TMDB ID，请先使用绑定元数据匹配');
                            }
                          },
                          onOpenLocalDir: () =>
                              DetailActionHandlers.openLocalDirectory(
                                context,
                                ref,
                                bundle,
                              ),
                          onOpenSeriesManage: () =>
                              DetailActionHandlers.openSeriesManage(
                                context,
                                bundle,
                              ),
                          onOpenMergeWork: () async {
                            final outcome = await DetailActionHandlers.openMergeWork(
                              context,
                              bundle,
                            );
                            if (outcome != null && mounted) {
                              _showToast(
                                '已将「${bundle.work.title}」合并入「${outcome.targetWork.title}」',
                              );
                              setState(
                                () => _activeWorkId = outcome.targetWork.id,
                              );
                            }
                          },
                          onSelectSeriesWork: (nextWorkId) {
                            if (nextWorkId == _activeWorkId) return;
                            _scanScheduler.cancelAll();
                            setState(() => _activeWorkId = nextWorkId);
                          },
                          onCdTap: (variant) =>
                              DetailActionHandlers.playCdAsset(
                                context: context,
                                ref: ref,
                                bundle: bundle,
                                variant: variant,
                              ),
                          onCdPlayImmersive: (variant) =>
                              DetailActionHandlers.playCdAsset(
                                context: context,
                                ref: ref,
                                bundle: bundle,
                                variant: variant,
                                overrideEngine:
                                    PreferredPlaybackEngine.builtinLibmpv,
                                expandImmersive: true,
                              ),
                          onCdPlayExternal: (variant) =>
                              DetailActionHandlers.playCdAsset(
                                context: context,
                                ref: ref,
                                bundle: bundle,
                                variant: variant,
                                overrideEngine:
                                    PreferredPlaybackEngine.externalPlayer,
                              ),
                          onScanTap: (variant) =>
                              DetailActionHandlers.openScanViewer(
                                context,
                                bundle,
                                variant,
                              ),
                        ),
                      ],
                    ),
                  ),

                  // 顶部：左上角 38x38 高透磨砂玻璃返回钮（无生硬 Tooltip 黑块），右上角同款通透磨砂窗口控制胶囊
                  Positioned(
                    top: 12,
                    left: 16,
                    right: 14,
                    child: Row(
                      children: [
                        SizedBox(
                          width: 38,
                          height: 38,
                          child: ClipOval(
                            child: BackdropFilter(
                              filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                              child: Material(
                                color: Colors.black.withValues(alpha: 0.28),
                                shape: CircleBorder(
                                  side: BorderSide(
                                    color: Colors.white.withValues(alpha: 0.22),
                                  ),
                                ),
                                child: InkWell(
                                  customBorder: const CircleBorder(),
                                  hoverColor:
                                      Colors.white.withValues(alpha: 0.14),
                                  onTap: () => Navigator.of(context).maybePop(),
                                  child: const Center(
                                    child: Icon(
                                      Icons.arrow_back_ios_new_rounded,
                                      size: 16,
                                      color: Colors.white,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        const Spacer(),
                        const WindowControls(forceLightIcons: true),
                      ],
                    ),
                  ),
                ],
              );
            },
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (err, _) => Center(
              child: Text(
                '加载作品详情失败: $err',
                style: TextStyle(color: p.danger),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
