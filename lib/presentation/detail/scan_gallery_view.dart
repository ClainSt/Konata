import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/providers/artwork_provider.dart';
import '../../application/providers/library_providers.dart';
import '../../domain/formatting/media_display_formatter.dart';
import '../../domain/matching/supplementary_subclassifier.dart';
import '../../domain/models/media_variant.dart';
import '../../infrastructure/cache/scan_thumbnail_scheduler.dart';
import '../theme/konata_adaptive_tokens.dart';
import '../theme/konata_palette.dart';
import '../theme/konata_theme.dart';
import '../widgets/design_system/konata_draggable_scrollbar.dart';
import '../widgets/design_system/konata_segmented_capsule.dart';
import '../widgets/design_system/konata_toast.dart';
import 'detail_bottom_drawer.dart';
import 'supplementary_asset_cards.dart';

/// 完整列表 Scan 画廊展示模式。
enum ScanGalleryMode {
  /// 默认：保序无裁切画框（统一 `3:4` 光学画框 + `BoxFit.contain`，WebDAV 冷态 0 布局抖动）。
  uniformFrame('保序画框'),

  /// 可选：保比例等高木桶流（利用已持久化自然宽高比满屏无留白浏览，锁定视口上方已滚过行防跳动）。
  justified('等高流');

  const ScanGalleryMode(this.label);

  /// 简体中文按钮标签。
  final String label;
}

/// 完整列表 Scan 画廊 3 档视图密度。
enum ScanGalleryDensity {
  /// 紧凑高密度预览。
  compact('紧凑', 144.0, 174.0),

  /// 标准均衡预览。
  standard('标准', 198.0, 232.0),

  /// 大图细节预览。
  large('大图', 274.0, 312.0);

  const ScanGalleryDensity(
    this.label,
    this.uniformMaxExtent,
    this.justifiedTargetHeight,
  );

  /// 简体中文密度标签。
  final String label;

  /// 保序画框模式下的单列最大宽度。
  final double uniformMaxExtent;

  /// 等高木桶流模式下的目标行高。
  final double justifiedTargetHeight;
}

class _JustifiedRowSpec {
  const _JustifiedRowSpec({
    required this.indices,
    required this.ratios,
    required this.height,
    required this.isLastIncompleteRow,
  });

  final List<int> indices;
  final List<double> ratios;
  final double height;
  final bool isLastIncompleteRow;
}

/// 完整列表弹窗专属双模式虚拟化 Scan 画廊（零重型第三方插件依赖）：
/// - 默认「保序无裁切画框」：统一 `3:4` 光学画框 + `BoxFit.contain`，零布局抖动且 100% 保持 Booklet 页码顺序；
/// - 可选「等高木桶流（Justified）」：利用 `.webp` 帧头与本地文件头预热宽高比，对已滚过行锁定比例防止滚动条顶飞；
/// - 支持 3 档密度切换（桌面支持 `Ctrl + 滚轮` 快捷调密度）与画面主角化极简呈现。
class ScanGalleryView extends ConsumerStatefulWidget {
  /// 创建双模式 Scan 画廊视图。
  const ScanGalleryView({
    super.key,
    required this.bundle,
    required this.items,
    required this.scanSummary,
    required this.selectedVolumeKey,
    required this.showSeriesSharedBadge,
    required this.scrollController,
    required this.onScanTap,
  });

  final WorkDetailBundle bundle;
  final List<MediaVariant> items;
  final ScanVolumeGroupSummary scanSummary;
  final String? selectedVolumeKey;
  final bool showSeriesSharedBadge;
  final ScrollController scrollController;
  final DetailScanTapCallback? onScanTap;

  @override
  ConsumerState<ScanGalleryView> createState() => _ScanGalleryViewState();
}

class _ScanGalleryViewState extends ConsumerState<ScanGalleryView> {
  static const double _defaultFrameRatio = 3 / 4;
  static const double _spacing = 10.0;
  static const double _rightPad = 16.0;

  ScanGalleryMode _mode = ScanGalleryMode.uniformFrame;
  ScanGalleryDensity _density = ScanGalleryDensity.standard;

  late final ScanThumbnailScheduler _scheduler;
  // 为已排入视口及上方已滚过区域的条目锁定宽高比，杜绝异步获知新比例导致滚动条跳动。
  final Map<String, double> _lockedJustifiedRatios = <String, double>{};

  @override
  void initState() {
    super.initState();
    _scheduler = ref.read(scanThumbnailSchedulerProvider);
    _scheduler.aspectRatioRevision.addListener(_onAspectRatioUpdated);
    unawaited(_prewarmAspectRatios());
  }

  @override
  void didUpdateWidget(covariant ScanGalleryView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.bundle.work.id != widget.bundle.work.id ||
        oldWidget.selectedVolumeKey != widget.selectedVolumeKey ||
        oldWidget.items.length != widget.items.length) {
      _lockedJustifiedRatios.clear();
      unawaited(_prewarmAspectRatios());
    }
  }

  @override
  void dispose() {
    _scheduler.aspectRatioRevision.removeListener(_onAspectRatioUpdated);
    super.dispose();
  }

  Future<void> _prewarmAspectRatios() {
    return _scheduler.prewarmCachedAndLocalAspectRatios(
      workId: widget.bundle.work.id,
      workTitle: widget.bundle.work.title,
      variants: widget.items,
      sourcesById: widget.bundle.sourcesById,
    );
  }

  void _onAspectRatioUpdated() {
    if (!mounted || _mode != ScanGalleryMode.justified) return;
    setState(() {});
  }

  void _handleCtrlWheelDensity(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    if (!HardwareKeyboard.instance.isControlPressed) return;
    if (event.scrollDelta.dy == 0) return;

    const order = ScanGalleryDensity.values;
    final idx = order.indexOf(_density);
    final nextIdx = event.scrollDelta.dy < 0
        ? math.min(order.length - 1, idx + 1)
        : math.max(0, idx - 1);
    if (nextIdx != idx) {
      setState(() {
        _density = order[nextIdx];
        _lockedJustifiedRatios.clear();
      });
    }
  }

  double _resolveJustifiedRatio(MediaVariant variant, {required bool freeze}) {
    final locked = _lockedJustifiedRatios[variant.id];
    if (locked != null) return locked;
    final known = _scheduler.cachedAspectRatio(variant.id);
    if (known != null) {
      _lockedJustifiedRatios[variant.id] = known;
      return known;
    }
    if (freeze) {
      _lockedJustifiedRatios[variant.id] = _defaultFrameRatio;
    }
    return _defaultFrameRatio;
  }

  List<_JustifiedRowSpec> _buildJustifiedRows({
    required double usableWidth,
    required double targetRowHeight,
  }) {
    final rows = <_JustifiedRowSpec>[];
    final scrollOffset = widget.scrollController.hasClients
        ? widget.scrollController.offset
        : 0.0;
    var cursorY = 0.0;
    var i = 0;
    final total = widget.items.length;

    while (i < total) {
      final rowIndices = <int>[];
      final rowRatios = <double>[];
      var ratioSum = 0.0;
      final shouldFreeze = cursorY < scrollOffset + targetRowHeight * 0.5;

      while (i < total) {
        final v = widget.items[i];
        final r = _resolveJustifiedRatio(v, freeze: shouldFreeze);
        final nextCount = rowIndices.length + 1;
        final gaps = (nextCount - 1) * _spacing;
        final nextRatioSum = ratioSum + r;
        final projectedWidth = nextRatioSum * targetRowHeight + gaps;

        rowIndices.add(i);
        rowRatios.add(r);
        ratioSum = nextRatioSum;
        i++;

        if (projectedWidth >= usableWidth) {
          break;
        }
      }

      final gaps = (rowIndices.length - 1) * _spacing;
      final isLast = i >= total;
      final naturalFullWidth = ratioSum * targetRowHeight + gaps;
      final isIncompleteLast = isLast && naturalFullWidth < usableWidth * 0.78;
      final rowHeight = isIncompleteLast
          ? targetRowHeight
          : ((usableWidth - gaps) / math.max(0.25, ratioSum)).clamp(
              targetRowHeight * 0.62,
              targetRowHeight * 1.48,
            );

      rows.add(
        _JustifiedRowSpec(
          indices: rowIndices,
          ratios: rowRatios,
          height: rowHeight,
          isLastIncompleteRow: isIncompleteLast,
        ),
      );
      cursorY += rowHeight + _spacing;
    }

    return rows;
  }

  void _showItemInfo(MediaVariant v) {
    final sizeText = MediaDisplayFormatter.formatBytes(v.fileSize);
    showKonataToast(
      context,
      '${v.fileName}${sizeText.isNotEmpty ? ' · $sizeText' : ''}',
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final compact =
        MediaQuery.sizeOf(context).width <
        KonataAdaptiveTokens.tabletBreakpoint;
    final showDirectSubdir =
        widget.selectedVolumeKey == null &&
        widget.scanSummary.hasMultipleSubdirs;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Wrap(
            spacing: 10,
            runSpacing: 8,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              KonataSegmentedCapsule<ScanGalleryMode>(
                options: [
                  for (final m in ScanGalleryMode.values)
                    KonataSegmentOption<ScanGalleryMode>(
                      value: m,
                      label: m.label,
                    ),
                ],
                selected: _mode,
                onChanged: (next) {
                  setState(() {
                    _mode = next;
                    _lockedJustifiedRatios.clear();
                  });
                },
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (!compact) ...[
                    Text(
                      '密度',
                      style: TextStyle(
                        color: p.textMuted,
                        fontSize: KonataTheme.fontSizeCaption,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                  KonataSegmentedCapsule<ScanGalleryDensity>(
                    options: [
                      for (final d in ScanGalleryDensity.values)
                        KonataSegmentOption<ScanGalleryDensity>(
                          value: d,
                          label: d.label,
                        ),
                    ],
                    selected: _density,
                    onChanged: (next) {
                      setState(() {
                        _density = next;
                        _lockedJustifiedRatios.clear();
                      });
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: Listener(
            onPointerSignal: _handleCtrlWheelDensity,
            child: LayoutBuilder(
              builder: (_, constraints) {
                final usableWidth = math.max(
                  140.0,
                  constraints.maxWidth - _rightPad,
                );
                if (_mode == ScanGalleryMode.uniformFrame) {
                  return _buildUniformFrameGrid(
                    usableWidth: usableWidth,
                    showDirectSubdir: showDirectSubdir,
                  );
                }
                return _buildJustifiedStream(
                  usableWidth: usableWidth,
                  showDirectSubdir: showDirectSubdir,
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildUniformFrameGrid({
    required double usableWidth,
    required bool showDirectSubdir,
  }) {
    final maxExtent = _density.uniformMaxExtent;
    final columns = math.max(
      2,
      ((usableWidth + _spacing) / (maxExtent + _spacing)).ceil(),
    );
    final rowCount = (widget.items.length + columns - 1) ~/ columns;

    return KonataDraggableScrollbar(
      controller: widget.scrollController,
      builder: (_, ctrl) => ListView.separated(
        key: const ValueKey('scan_gallery_uniform_list'),
        controller: ctrl,
        padding: const EdgeInsets.only(right: _rightPad, bottom: 8),
        itemCount: rowCount,
        separatorBuilder: (_, _) => const SizedBox(height: _spacing),
        itemBuilder: (_, rowIdx) {
          final start = rowIdx * columns;
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var col = 0; col < columns; col++) ...[
                if (col > 0) const SizedBox(width: _spacing),
                Expanded(
                  child: start + col < widget.items.length
                      ? _buildScanTile(
                          index: start + col,
                          frameAspectRatio: _defaultFrameRatio,
                          showDirectSubdir: showDirectSubdir,
                        )
                      : const SizedBox.shrink(),
                ),
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _buildJustifiedStream({
    required double usableWidth,
    required bool showDirectSubdir,
  }) {
    final rows = _buildJustifiedRows(
      usableWidth: usableWidth,
      targetRowHeight: _density.justifiedTargetHeight,
    );

    return KonataDraggableScrollbar(
      controller: widget.scrollController,
      builder: (_, ctrl) => ListView.separated(
        key: const ValueKey('scan_gallery_justified_list'),
        controller: ctrl,
        padding: const EdgeInsets.only(right: _rightPad, bottom: 8),
        itemCount: rows.length,
        separatorBuilder: (_, _) => const SizedBox(height: _spacing),
        itemBuilder: (_, rowIdx) {
          final row = rows[rowIdx];
          return SizedBox(
            height: row.height,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var k = 0; k < row.indices.length; k++) ...[
                  if (k > 0) const SizedBox(width: _spacing),
                  if (row.isLastIncompleteRow)
                    SizedBox(
                      width: row.ratios[k] * row.height,
                      child: _buildScanTile(
                        index: row.indices[k],
                        frameAspectRatio: row.ratios[k],
                        showDirectSubdir: showDirectSubdir,
                      ),
                    )
                  else
                    Expanded(
                      flex: math.max(10, (row.ratios[k] * 1000).round()),
                      child: _buildScanTile(
                        index: row.indices[k],
                        frameAspectRatio: row.ratios[k],
                        showDirectSubdir: showDirectSubdir,
                      ),
                    ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildScanTile({
    required int index,
    required double frameAspectRatio,
    required bool showDirectSubdir,
  }) {
    final v = widget.items[index];
    final group = widget.scanSummary.byVariantId[v.id];
    return ScanDrawerCard(
      key: ValueKey('full_list_scan_${v.id}'),
      variant: v,
      source: widget.bundle.sourcesById[v.sourceId],
      workId: widget.bundle.work.id,
      workTitle: widget.bundle.work.title,
      showSeriesSharedBadge: widget.showSeriesSharedBadge,
      directSubdirLabel: showDirectSubdir ? group?.directSubdirShort : null,
      onDarkBackdrop: false,
      fillAvailableWidth: true,
      frameAspectRatio: frameAspectRatio,
      galleryOverlayCaption: true,
      pageIndex: index + 1,
      onLongPressInfo: () => _showItemInfo(v),
      onTap: () => widget.onScanTap?.call(
        v,
        volumeKey: widget.selectedVolumeKey,
      ),
    );
  }
}
