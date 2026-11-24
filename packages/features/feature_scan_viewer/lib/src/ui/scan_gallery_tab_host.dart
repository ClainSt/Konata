import 'dart:async';

import 'package:engine_scraping/engine_scraping.dart';
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

/// 详情页「扫图」扩展标签页挂载宿主组件（供 `DetailTabContribution.viewBuilder` 直接返回）。
class ScanGalleryTabHost extends ConsumerStatefulWidget {
  /// 创建扫图画廊标签页宿主。
  const ScanGalleryTabHost({
    super.key,
    required this.workId,
    this.initialVolumeKey,
    this.scrollController,
    this.onScanTap,
  });

  /// 目标作品强类型标识。
  final WorkId workId;

  /// 可选初始分卷筛选键。
  final String? initialVolumeKey;

  /// 可选外部注入的滚动控制器。
  final ScrollController? scrollController;

  /// 可选覆写点击扫图条目的动作（缺省自动弹出内置毛玻璃原图灯箱）。
  final ScanTapCallback? onScanTap;

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
      widget.scrollController ?? (_ownedScrollController ??= ScrollController());

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
                    style: KonataTheme.bodyLabelStyle(
                      p,
                      color: p.danger,
                    ),
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

        final volumeChips = state.scanSummary.chips;
        final showVolumeBar = volumeChips.length >= 2;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (showVolumeBar) ...[
              _ScanVolumeFilterBar(
                totalCount: state.allScans.length,
                chips: volumeChips,
                selectedKey: state.selectedVolumeKey,
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
              child: ScanGalleryView(
                workId: widget.workId,
                workTitle: state.workTitle,
                items: state.visibleScans,
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

class _ScanVolumeFilterBar extends StatelessWidget {
  const _ScanVolumeFilterBar({
    required this.totalCount,
    required this.chips,
    required this.selectedKey,
    required this.onSelected,
  });

  final int totalCount;
  final List<({String key, String label, int count})> chips;
  final String? selectedKey;
  final ValueChanged<String?> onSelected;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _VolumeFilterPill(
            label: '全部 ($totalCount)',
            selected: selectedKey == null,
            onTap: () => onSelected(null),
          ),
          for (final chip in chips) ...[
            const SizedBox(width: 8),
            _VolumeFilterPill(
              label: '${chip.label} (${chip.count})',
              selected: selectedKey == chip.key,
              onTap: () => onSelected(chip.key),
            ),
          ],
        ],
      ),
    );
  }
}

class _VolumeFilterPill extends StatefulWidget {
  const _VolumeFilterPill({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_VolumeFilterPill> createState() => _VolumeFilterPillState();
}

class _VolumeFilterPillState extends State<_VolumeFilterPill> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final bg = KonataPlaybackTokens.secondaryFilterPillBg(
      p,
      selected: widget.selected,
      hovered: _hovered,
    );
    final border = KonataPlaybackTokens.secondaryFilterPillBorder(
      p,
      selected: widget.selected,
    );
    final fg = KonataPlaybackTokens.secondaryFilterPillText(
      p,
      selected: widget.selected,
      hovered: _hovered,
    );

    Widget pill = AnimatedContainer(
      duration: KonataTheme.motionFast,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: KonataTheme.borderRadiusPill,
        border: Border.all(color: border, width: 1),
      ),
      child: Text(
        widget.label,
        maxLines: 1,
        softWrap: false,
        style: TextStyle(
          color: fg,
          fontSize: KonataTheme.fontSizeCaption,
          fontWeight: widget.selected ? FontWeight.w600 : FontWeight.w500,
        ),
      ),
    );

    if (KonataAdaptiveTokens.isAndroid) {
      pill = ConstrainedBox(
        constraints: const BoxConstraints(
          minHeight: KonataAdaptiveTokens.touchTarget,
        ),
        child: Center(widthFactor: 1, heightFactor: 1, child: pill),
      );
    }

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: pill,
      ),
    );
  }
}
