import 'dart:async';

import 'package:engine_scraping/engine_scraping.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_design_system/konata_design_system.dart';

import '../data/scan_lightbox_loader.dart';
import '../data/scan_thumbnail_scheduler.dart';
import '../providers.dart';
import '../state/scan_gallery_controller.dart';
import 'scan_gallery_view.dart';
import 'scan_lightbox_dialog.dart';
import 'scan_thumbnail_card.dart';

/// 详情页「扫图」扩展标签页挂载宿主组件（供 `DetailTabContribution.viewBuilder` 直接返回）。
class ScanGalleryTabHost extends ConsumerStatefulWidget {
  /// 创建扫图画廊标签页宿主。
  const ScanGalleryTabHost({
    super.key,
    required this.workId,
    this.initialVolumeKey,
    this.scrollController,
    this.onScanTap,
    this.inlineRail = false,
    this.searchQuery = '',
  });

  /// 目标作品强类型标识。
  final WorkId workId;

  /// 可选初始分卷筛选键。
  final String? initialVolumeKey;

  /// 可选外部注入的滚动控制器。
  final ScrollController? scrollController;

  /// 可选覆写点击扫图条目的动作（缺省自动弹出内置毛玻璃原图灯箱）。
  final ScanTapCallback? onScanTap;

  /// 详情页内嵌横向轨道，而非完整画廊。
  final bool inlineRail;

  /// 完整列表搜索词。
  final String searchQuery;

  @override
  ConsumerState<ScanGalleryTabHost> createState() => _ScanGalleryTabHostState();
}

class _ScanGalleryTabHostState extends ConsumerState<ScanGalleryTabHost> {
  ScrollController? _ownedScrollController;
  ScanGalleryController? _controller;
  late ScanThumbnailScheduler _scheduler;
  late ScanLightboxLoader _lightboxLoader;
  late FeatureScanViewerDependencies _deps;
  bool _initialized = false;

  ScrollController get _effectiveScrollController =>
      widget.scrollController ??
      (_ownedScrollController ??= ScrollController());

  @override
  void initState() {
    super.initState();
    if (widget.scrollController == null) {
      _ownedScrollController = ScrollController();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_initialized) {
      _initialized = true;
      _deps = ref.read(featureScanViewerDependenciesProvider);
      _scheduler = ref.read(scanThumbnailSchedulerProvider);
      _lightboxLoader = ref.read(scanLightboxLoaderProvider);
      _controller = ScanGalleryController(
        databases: _deps.databases,
        scopedPrefs: _deps.scopedPrefs,
        scheduler: _scheduler,
        photosStorage: _deps.photosStorage,
        diagnosticLog: _deps.diagnosticLog,
      );
      unawaited(
        _controller!.loadWork(
          widget.workId,
          initialVolumeKey: widget.initialVolumeKey,
        ),
      );
    }
  }

  @override
  void didUpdateWidget(covariant ScanGalleryTabHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scrollController == null && widget.scrollController != null) {
      _ownedScrollController?.dispose();
      _ownedScrollController = null;
    } else if (oldWidget.scrollController != null &&
        widget.scrollController == null) {
      _ownedScrollController ??= ScrollController();
    }
    if (_controller != null && oldWidget.workId != widget.workId) {
      if (_effectiveScrollController.hasClients) {
        _effectiveScrollController.jumpTo(0);
      }
      unawaited(
        _controller!.loadWork(
          widget.workId,
          initialVolumeKey: widget.initialVolumeKey,
        ),
      );
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    _ownedScrollController?.dispose();
    _ownedScrollController = null;
    super.dispose();
  }

  Future<void> _openLightbox(
    ScanGalleryState state,
    MediaVariant variant, {
    String? volumeKey,
  }) {
    if (widget.onScanTap != null) {
      widget.onScanTap!(variant, volumeKey: volumeKey);
      return Future<void>.value();
    }
    return showScanLightboxDialog(
      context,
      workId: widget.workId,
      workTitle: state.workTitle,
      scans: state.allScans,
      sourcesById: state.sourceViewsById,
      initialVariant: variant,
      initialVolumeKey: volumeKey ?? state.selectedVolumeKey,
      scanSummary: state.scanSummary,
      scheduler: _scheduler,
      loader: _lightboxLoader,
      platform: _deps.platform,
      urlOpener: _deps.urlOpener,
      windowFullscreen: _deps.windowFullscreen,
      diagnosticLog: _deps.diagnosticLog,
    );
  }

  Widget _buildInlineRail(ScanGalleryState state, List<MediaVariant> items) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = (constraints.maxHeight - 48).clamp(60.0, 186.0);
        return Listener(
          onPointerSignal: (event) {
            final ctrl = _effectiveScrollController;
            if (event is! PointerScrollEvent ||
                !ctrl.hasClients ||
                event.scrollDelta.dy.abs() < event.scrollDelta.dx.abs()) {
              return;
            }
            final pos = ctrl.position;
            GestureBinding.instance.pointerSignalResolver.register(event, (_) {
              pos.jumpTo(
                (pos.pixels + event.scrollDelta.dy).clamp(
                  pos.minScrollExtent,
                  pos.maxScrollExtent,
                ),
              );
            });
          },
          child: ListView.separated(
            key: const ValueKey('scan_gallery_inline_rail'),
            controller: _effectiveScrollController,
            scrollDirection: Axis.horizontal,
            addAutomaticKeepAlives: false,
            itemCount: items.length,
            separatorBuilder: (_, _) => const SizedBox(width: 12),
            itemBuilder: (_, index) {
              final v = items[index];
              return ScanThumbnailCard(
                key: ValueKey('scan_inline_tile_${v.id}'),
                variant: v,
                source: state.sourceViewsById[v.sourceId],
                scheduler: _scheduler,
                workId: widget.workId.value,
                workTitle: state.workTitle,
                showSeriesSharedBadge: state.showSeriesSharedBadge,
                onDarkBackdrop: true,
                cardWidth: width,
                fillAvailableWidth: false,
                frameAspectRatio: 4 / 3,
                galleryOverlayCaption: false,
                onTap: () => unawaited(_openLightbox(state, v)),
              );
            },
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null) {
      return const SizedBox.shrink();
    }
    final p = context.palette;
    final bottomClearance = KonataBottomClearanceScope.of(context);

    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final state = controller.state;
        if (state.isLoading && state.allScans.isEmpty) {
          return const Center(child: CircularProgressIndicator());
        }

        if (state.errorMessage != null && state.allScans.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    state.errorMessage!,
                    textAlign: TextAlign.center,
                    style: KonataTheme.bodyLabelStyle(p, color: p.danger),
                  ),
                  const SizedBox(height: 14),
                  KonataPillButton.primary(
                    label: '重新加载',
                    icon: Icons.refresh_rounded,
                    onPressed: () => unawaited(controller.reload()),
                  ),
                ],
              ),
            ),
          );
        }

        if (state.allScans.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.photo_library_outlined,
                    size: 36,
                    color: p.textMuted,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    '暂无扫图画册资产',
                    style: KonataTheme.bodyLabelStyle(
                      p,
                      color: p.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          );
        }

        final query = widget.searchQuery.trim().toLowerCase();
        final visibleScans = query.isEmpty
            ? state.visibleScans
            : state.visibleScans
                  .where(
                    (v) =>
                        v.fileName.toLowerCase().contains(query) ||
                        v.relativePath.toLowerCase().contains(query),
                  )
                  .toList();
        final volumeChips = state.scanSummary.chips;
        final showVolumeBar = state.scanSummary.hasMultipleSubdirs;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (showVolumeBar) ...[
              KonataSecondaryFilterBar<String?>(
                items: [
                  (value: null, label: '全部 (${state.allScans.length})'),
                  for (final chip in volumeChips)
                    (value: chip.key, label: '${chip.label} (${chip.count})'),
                ],
                selected: state.selectedVolumeKey,
                onSelected: (key) {
                  if (_effectiveScrollController.hasClients) {
                    _effectiveScrollController.jumpTo(0);
                  }
                  controller.selectVolume(key);
                },
              ),
              const SizedBox(height: 10),
            ],
            Expanded(
              child: widget.inlineRail
                  ? _buildInlineRail(state, visibleScans)
                  : ScanGalleryView(
                      workId: widget.workId,
                      workTitle: state.workTitle,
                      items: visibleScans,
                      sourcesById: state.sourceViewsById,
                      scanSummary: state.scanSummary,
                      scheduler: _scheduler,
                      scrollController: _effectiveScrollController,
                      selectedVolumeKey: state.selectedVolumeKey,
                      showSeriesSharedBadge: state.showSeriesSharedBadge,
                      mode: state.mode,
                      density: state.density,
                      onModeChanged: controller.setMode,
                      onDensityChanged: controller.setDensity,
                      onScanTap: (variant, {volumeKey}) {
                        unawaited(
                          _openLightbox(state, variant, volumeKey: volumeKey),
                        );
                      },
                      bottomPadding: bottomClearance + 12.0,
                      prewarmOnMount: false,
                    ),
            ),
          ],
        );
      },
    );
  }
}
