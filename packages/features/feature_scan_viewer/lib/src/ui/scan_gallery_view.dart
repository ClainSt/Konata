import 'dart:async';
import 'dart:math' as math;

import 'package:engine_scraping/engine_scraping.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_design_system/konata_design_system.dart';

import '../data/scan_display_formatter.dart';
import '../data/scan_gallery_prefs.dart';
import '../data/scan_thumbnail_scheduler.dart';
import 'scan_thumbnail_card.dart';

/// 点击扫图条目打开灯箱时的回调签名（可选透传当前激活的二级分卷键）。
typedef ScanTapCallback =
    void Function(MediaVariant variant, {String? volumeKey});

final class _JustifiedRowSpec {
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

/// 双模式虚拟化扫图画廊视图：
/// - 整齐网格（保序画框）：统一 `3:4` 光学画框 + `BoxFit.contain`，远程冷态零布局抖动；
/// - 自适应等高瀑布流：利用 `.webp` 帧头与本地文件头预热宽高比，对已滚过行锁定比例防跳动；
/// - 支持 3 档视图密度切换与桌面端 `Ctrl + 滚轮` 快捷调密度，卡片划出视口自动取消微缩图任务。
class ScanGalleryView extends StatefulWidget {
  /// 创建双模式扫图画廊视图。
  const ScanGalleryView({
    super.key,
    required this.workId,
    required this.workTitle,
    required this.items,
    required this.sourcesById,
    required this.scanSummary,
    required this.scheduler,
    required this.scrollController,
    this.selectedVolumeKey,
    this.showSeriesSharedBadge = false,
    this.mode,
    this.density,
    this.onModeChanged,
    this.onDensityChanged,
    this.onScanTap,
    this.bottomPadding = 8.0,
    this.prewarmOnMount = true,
  });

  /// 所属作品标识。
  final WorkId workId;

  /// 所属作品标题。
  final String workTitle;

  /// 当前筛选作用域下需要展示的扫图变体列表。
  final List<MediaVariant> items;

  /// 媒体源只读视图字典（按 `sourceId` 索引）。
  final Map<String, MediaSourceView> sourcesById;

  /// 分卷与子目录分组汇总。
  final ScanVolumeGroupSummary scanSummary;

  /// 三级并发微缩图调度器。
  final ScanThumbnailScheduler scheduler;

  /// 外层或内置可拖拽滚动条绑定的滚动控制器。
  final ScrollController scrollController;

  /// 当前激活的二级分卷筛选键。
  final String? selectedVolumeKey;

  /// 是否显示「系列共用」角标。
  final bool showSeriesSharedBadge;

  /// 受控展示模式（传入时由外部状态管理，否则由组件内部状态托管）。
  final ScanGalleryMode? mode;

  /// 受控密度档位（传入时由外部状态管理，否则由组件内部状态托管）。
  final ScanGalleryDensity? density;

  /// 切换展示模式回调。
  final ValueChanged<ScanGalleryMode>? onModeChanged;

  /// 切换密度档位回调。
  final ValueChanged<ScanGalleryDensity>? onDensityChanged;

  /// 点击具体扫图条目回调。
  final ScanTapCallback? onScanTap;

  /// 底部安全避让内边距。
  final double bottomPadding;

  /// 挂载或切换数据时是否自动触发帧头宽高比预热。
  final bool prewarmOnMount;

  @override
  State<ScanGalleryView> createState() => _ScanGalleryViewState();
}

class _ScanGalleryViewState extends State<ScanGalleryView> {
  static const double _defaultFrameRatio = 3 / 4;
  static const double _spacing = 10.0;
  static const double _rightPad = 16.0;

  ScanGalleryMode _localMode = ScanGalleryMode.uniformFrame;
  ScanGalleryDensity _localDensity = ScanGalleryDensity.standard;

  // 为已排入视口及上方已滚过区域的条目锁定宽高比，防止异步获知新比例导致滚动条跳动。
  final Map<String, double> _lockedJustifiedRatios = <String, double>{};

  ScanGalleryMode get _effectiveMode => widget.mode ?? _localMode;
  ScanGalleryDensity get _effectiveDensity => widget.density ?? _localDensity;

  @override
  void initState() {
    super.initState();
    widget.scheduler.aspectRatioRevision.addListener(_onAspectRatioUpdated);
    if (widget.prewarmOnMount) {
      unawaited(_prewarmAspectRatios());
    }
  }

  @override
  void didUpdateWidget(covariant ScanGalleryView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.scheduler, widget.scheduler)) {
      oldWidget.scheduler.aspectRatioRevision.removeListener(
        _onAspectRatioUpdated,
      );
      widget.scheduler.aspectRatioRevision.addListener(_onAspectRatioUpdated);
    }
    if (oldWidget.workId != widget.workId ||
        oldWidget.selectedVolumeKey != widget.selectedVolumeKey ||
        oldWidget.items.length != widget.items.length ||
        oldWidget.mode != widget.mode ||
        oldWidget.density != widget.density) {
      _lockedJustifiedRatios.clear();
      if (widget.prewarmOnMount &&
          (oldWidget.workId != widget.workId ||
              oldWidget.selectedVolumeKey != widget.selectedVolumeKey ||
              oldWidget.items.length != widget.items.length)) {
        unawaited(_prewarmAspectRatios());
      }
    }
  }

  @override
  void dispose() {
    widget.scheduler.aspectRatioRevision.removeListener(_onAspectRatioUpdated);
    super.dispose();
  }

  Future<void> _prewarmAspectRatios() {
    return widget.scheduler.prewarmCachedAndLocalAspectRatios(
      workId: widget.workId.value,
      workTitle: widget.workTitle,
      variants: widget.items,
      sourcesById: widget.sourcesById,
    );
  }

  void _onAspectRatioUpdated() {
    if (!mounted || _effectiveMode != ScanGalleryMode.justified) return;
    setState(() {});
  }

  void _setMode(ScanGalleryMode next) {
    if (_effectiveMode == next) return;
    _lockedJustifiedRatios.clear();
    if (widget.onModeChanged != null) {
      widget.onModeChanged!(next);
    } else {
      setState(() => _localMode = next);
    }
  }

  void _setDensity(ScanGalleryDensity next) {
    if (_effectiveDensity == next) return;
    _lockedJustifiedRatios.clear();
    if (widget.onDensityChanged != null) {
      widget.onDensityChanged!(next);
    } else {
      setState(() => _localDensity = next);
    }
  }

  void _handleCtrlWheelDensity(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    if (!HardwareKeyboard.instance.isControlPressed) return;
    if (event.scrollDelta.dy == 0) return;

    const order = ScanGalleryDensity.values;
    final idx = order.indexOf(_effectiveDensity);
    final nextIdx = event.scrollDelta.dy < 0
        ? math.min(order.length - 1, idx + 1)
        : math.max(0, idx - 1);
    if (nextIdx != idx) {
      _setDensity(order[nextIdx]);
    }
  }

  double _resolveJustifiedRatio(MediaVariant variant, {required bool freeze}) {
    final locked = _lockedJustifiedRatios[variant.id];
    if (locked != null) return locked;
    final known = widget.scheduler.cachedAspectRatio(variant.id);
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
    final sizeText = ScanDisplayFormatter.formatBytes(v.fileSize);
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
                compact: compact,
                options: [
                  for (final m in ScanGalleryMode.values)
                    KonataSegmentOption<ScanGalleryMode>(
                      value: m,
                      label: m.label,
                    ),
                ],
                selected: _effectiveMode,
                onChanged: _setMode,
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
                    compact: compact,
                    options: [
                      for (final d in ScanGalleryDensity.values)
                        KonataSegmentOption<ScanGalleryDensity>(
                          value: d,
                          label: d.label,
                        ),
                    ],
                    selected: _effectiveDensity,
                    onChanged: _setDensity,
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
                if (_effectiveMode == ScanGalleryMode.uniformFrame) {
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
    final maxExtent = _effectiveDensity.uniformMaxExtent;
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
        addAutomaticKeepAlives: false,
        padding: EdgeInsets.only(
          right: _rightPad,
          bottom: math.max(8.0, widget.bottomPadding),
        ),
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
      targetRowHeight: _effectiveDensity.justifiedTargetHeight,
    );

    return KonataDraggableScrollbar(
      controller: widget.scrollController,
      builder: (_, ctrl) => ListView.separated(
        key: const ValueKey('scan_gallery_justified_list'),
        controller: ctrl,
        addAutomaticKeepAlives: false,
        padding: EdgeInsets.only(
          right: _rightPad,
          bottom: math.max(8.0, widget.bottomPadding),
        ),
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
    return ScanThumbnailCard(
      key: ValueKey('scan_gallery_tile_${v.id}'),
      variant: v,
      source: widget.sourcesById[v.sourceId],
      scheduler: widget.scheduler,
      workId: widget.workId.value,
      workTitle: widget.workTitle,
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
