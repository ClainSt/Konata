import 'dart:ui';

import 'package:material_ui/material_ui.dart';
import '../../theme/konata_adaptive_tokens.dart';

import '../../theme/konata_palette.dart';
import '../../theme/konata_playback_tokens.dart';
import '../../theme/konata_theme.dart';

/// 滑动分段胶囊选项描述。
class KonataSegmentOption<T> {
  /// 创建分段胶囊条目。
  const KonataSegmentOption({
    required this.value,
    required this.label,
    this.icon,
  });

  /// 选项关联的业务枚举或标识值。
  final T value;

  /// 展示文本。
  final String label;

  /// 可选前置小图标。
  final IconData? icon;
}

/// 全站唯一丝滑物理滑动分段胶囊控制器。
///
/// 采用三层合成架构：
/// 1. 底层圆角凹槽轨道；
/// 2. 中层精确测量的单一微阴影圆角滑块（`220ms easeOutCubic` 平滑滑动伸缩）；
/// 3. 顶层 `MouseRegion` + `GestureDetector`（零 `InkWell` 灰底/水波纹残留）与平滑插值可变字重。
class KonataSegmentedCapsule<T> extends StatefulWidget {
  /// 创建滑动分段胶囊。
  const KonataSegmentedCapsule({
    super.key,
    required this.options,
    required this.selected,
    required this.onChanged,
    this.expand = false,
    this.compact = false,
  });

  /// 可选项列表。
  final List<KonataSegmentOption<T>> options;

  /// 当前激活值。
  final T selected;

  /// 切换选项回调。
  final ValueChanged<T> onChanged;

  /// 是否横向撑满父容器并等分每一项。
  final bool expand;

  /// 是否使用紧凑尺寸（用于表格/密集行内筛选）。
  final bool compact;

  @override
  State<KonataSegmentedCapsule<T>> createState() =>
      _KonataSegmentedCapsuleState<T>();
}

class _KonataSegmentedCapsuleState<T> extends State<KonataSegmentedCapsule<T>> {
  final GlobalKey _trackKey = GlobalKey();
  final List<GlobalKey> _itemKeys = <GlobalKey>[];

  Rect? _thumbRect;
  Size? _lastTrackSize;
  bool _hasAnimatedOnce = false;
  int? _hoveredIndex;

  @override
  void initState() {
    super.initState();
    _syncItemKeys();
    _scheduleMeasure();
  }

  @override
  void didUpdateWidget(covariant KonataSegmentedCapsule<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncItemKeys();
    if (!widget.expand) {
      _scheduleMeasure();
    }
  }

  void _syncItemKeys() {
    while (_itemKeys.length < widget.options.length) {
      _itemKeys.add(GlobalKey());
    }
    if (_itemKeys.length > widget.options.length) {
      _itemKeys.removeRange(widget.options.length, _itemKeys.length);
    }
  }

  void _scheduleMeasure() {
    if (widget.expand) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final selectedIndex = widget.options.indexWhere(
        (o) => o.value == widget.selected,
      );
      if (selectedIndex < 0 || selectedIndex >= _itemKeys.length) {
        if (_thumbRect != null) setState(() => _thumbRect = null);
        return;
      }
      final trackCtx = _trackKey.currentContext;
      final itemCtx = _itemKeys[selectedIndex].currentContext;
      final trackBox = trackCtx?.findRenderObject() as RenderBox?;
      final itemBox = itemCtx?.findRenderObject() as RenderBox?;
      if (trackBox == null ||
          itemBox == null ||
          !trackBox.attached ||
          !itemBox.attached ||
          !trackBox.hasSize ||
          !itemBox.hasSize) {
        return;
      }
      final trackSize = trackBox.size;
      final topLeft = itemBox.localToGlobal(Offset.zero, ancestor: trackBox);
      final nextRect = Rect.fromLTWH(
        topLeft.dx,
        topLeft.dy,
        itemBox.size.width,
        itemBox.size.height,
      );
      _lastTrackSize = trackSize;
      if (_thumbRect == null) {
        setState(() {
          _thumbRect = nextRect;
        });
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _hasAnimatedOnce = true;
        });
      } else if (_thumbRect != nextRect) {
        setState(() {
          _hasAnimatedOnce = true;
          _thumbRect = nextRect;
        });
      }
    });
  }

  void _handleOuterTapPosition(Offset globalPosition) {
    for (var i = 0; i < widget.options.length && i < _itemKeys.length; i++) {
      final box = _itemKeys[i].currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.attached || !box.hasSize) continue;
      final local = box.globalToLocal(globalPosition);
      if (local.dx >= 0 && local.dx <= box.size.width) {
        final target = widget.options[i].value;
        if (target != widget.selected) {
          widget.onChanged(target);
        }
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;

    final trackBg = KonataPlaybackTokens.softFill(p);
    final trackBorder = KonataPlaybackTokens.segmentedTrackBorder(p);
    final thumbBg = KonataTheme.segmentedThumbSurface(p);
    final thumbBorder = KonataTheme.segmentedThumbBorder(p);

    final selectedIndex = widget.options.indexWhere(
      (o) => o.value == widget.selected,
    );
    final trackPadding = widget.compact ? 3.0 : 3.5;

    final items = <Widget>[
      for (var i = 0; i < widget.options.length; i++)
        _buildItemWrapper(
          index: i,
          option: widget.options[i],
          selected: i == selectedIndex,
          hovered: _hoveredIndex == i,
          palette: p,
          showFallbackPill:
              !widget.expand && _thumbRect == null && i == selectedIndex,
          thumbBg: thumbBg,
          thumbBorder: thumbBorder,
        ),
    ];
    final itemsRow = widget.expand
        ? Row(children: items)
        : Row(mainAxisSize: MainAxisSize.min, children: items);

    final innerTrack = Container(
      padding: EdgeInsets.all(trackPadding),
      decoration: BoxDecoration(
        color: trackBg,
        borderRadius: KonataTheme.borderRadiusPill,
        border: Border.all(color: trackBorder, width: 1),
      ),
      child: widget.expand
          ? LayoutBuilder(
              builder: (context, constraints) {
                final count = widget.options.isEmpty
                    ? 1
                    : widget.options.length;
                final slotWidth = constraints.maxWidth / count;
                final thumbLeft = selectedIndex >= 0
                    ? selectedIndex * slotWidth
                    : 0.0;
                return Stack(
                  children: [
                    if (selectedIndex >= 0)
                      AnimatedPositioned(
                        duration: KonataTheme.capsuleSlideDuration,
                        curve: Curves.easeOutCubic,
                        left: thumbLeft,
                        top: 0,
                        bottom: 0,
                        width: slotWidth,
                        child: _SlidingThumbBox(
                          bgColor: thumbBg,
                          borderColor: thumbBorder,
                          isDark: p.isDark,
                        ),
                      ),
                    itemsRow,
                  ],
                );
              },
            )
          : Stack(
              key: _trackKey,
              children: [
                if (_thumbRect != null && selectedIndex >= 0)
                  AnimatedPositioned(
                    duration: _hasAnimatedOnce
                        ? KonataTheme.capsuleSlideDuration
                        : Duration.zero,
                    curve: Curves.easeOutCubic,
                    left: _thumbRect!.left,
                    top: _thumbRect!.top,
                    width: _thumbRect!.width,
                    height: _thumbRect!.height,
                    child: _SlidingThumbBox(
                      bgColor: thumbBg,
                      borderColor: thumbBorder,
                      isDark: p.isDark,
                    ),
                  ),
                itemsRow,
              ],
            ),
    );

    Widget result = widget.expand
        ? innerTrack
        : LayoutBuilder(
            builder: (context, constraints) {
              if (_lastTrackSize != null) {
                final maxW = constraints.maxWidth;
                if (maxW.isFinite && _lastTrackSize!.width > maxW) {
                  _scheduleMeasure();
                }
              }
              if (!constraints.hasBoundedWidth) {
                return innerTrack;
              }
              return Align(
                alignment: Alignment.centerLeft,
                widthFactor: 1,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: innerTrack,
                ),
              );
            },
          );

    if (KonataAdaptiveTokens.isAndroid) {
      // Android 透明外扩至 48dp 触控高度并保持水平按段坐标映射，视觉轨道尺寸严格对齐 Windows。
      result = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: (details) => _handleOuterTapPosition(details.globalPosition),
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minHeight: KonataAdaptiveTokens.touchTarget,
          ),
          child: Center(
            widthFactor: widget.expand ? null : 1,
            heightFactor: 1,
            child: result,
          ),
        ),
      );
    }

    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.15,
      child: result,
    );
  }

  Widget _buildItemWrapper({
    required int index,
    required KonataSegmentOption<T> option,
    required bool selected,
    required bool hovered,
    required KonataPalette palette,
    required bool showFallbackPill,
    required Color thumbBg,
    required Color thumbBorder,
  }) {
    final child = _SegmentChip(
      key: _itemKeys[index],
      option: option,
      selected: selected,
      hovered: hovered,
      compact: widget.compact,
      palette: palette,
      fallbackBoxColor: showFallbackPill ? thumbBg : null,
      fallbackBorderColor: showFallbackPill ? thumbBorder : null,
      onHoverChanged: (v) => setState(() {
        _hoveredIndex = v
            ? index
            : (_hoveredIndex == index ? null : _hoveredIndex);
      }),
      onTap: () {
        if (!selected) {
          widget.onChanged(option.value);
        }
      },
    );

    if (widget.expand) {
      return Expanded(child: child);
    }
    return child;
  }
}

class _SlidingThumbBox extends StatelessWidget {
  const _SlidingThumbBox({
    required this.bgColor,
    required this.borderColor,
    required this.isDark,
  });

  final Color bgColor;
  final Color borderColor;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: KonataTheme.borderRadiusPill,
          border: Border.all(color: borderColor, width: 1),
          boxShadow: [
            BoxShadow(
              color: KonataTheme.segmentedThumbShadow(isDark),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
      ),
    );
  }
}

class _SegmentChip<T> extends StatelessWidget {
  const _SegmentChip({
    super.key,
    required this.option,
    required this.selected,
    required this.hovered,
    required this.compact,
    required this.palette,
    required this.fallbackBoxColor,
    required this.fallbackBorderColor,
    required this.onHoverChanged,
    required this.onTap,
  });

  final KonataSegmentOption<T> option;
  final bool selected;
  final bool hovered;
  final bool compact;
  final KonataPalette palette;
  final Color? fallbackBoxColor;
  final Color? fallbackBorderColor;
  final ValueChanged<bool> onHoverChanged;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = palette;
    final activeTextColor = p.textPrimary;
    final restTextColor = hovered
        ? p.textPrimary.withValues(alpha: 0.85)
        : p.textSecondary;
    final fontSize = compact ? 12.0 : 12.5;
    final padH = compact ? 11.0 : 14.0;
    final padV = compact ? 5.0 : 6.5;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => onHoverChanged(true),
      onExit: (_) => onHoverChanged(false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          decoration: fallbackBoxColor != null
              ? BoxDecoration(
                  color: fallbackBoxColor,
                  borderRadius: KonataTheme.borderRadiusPill,
                  border: Border.all(
                    color: fallbackBorderColor ?? Colors.transparent,
                    width: 1,
                  ),
                )
              : null,
          padding: EdgeInsets.symmetric(horizontal: padH, vertical: padV),
          child: TweenAnimationBuilder<double>(
            duration: KonataTheme.standardTransition,
            curve: Curves.easeOutCubic,
            tween: Tween<double>(end: selected ? 1.0 : 0.0),
            builder: (context, t, _) {
              final textColor =
                  Color.lerp(restTextColor, activeTextColor, t) ??
                  activeTextColor;
              final weight = lerpDouble(
                KonataTheme.weightRegularLabel,
                KonataTheme.weightActive,
                t,
              )!;

              return Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (option.icon != null) ...[
                    Icon(
                      option.icon,
                      size: compact ? 13 : 14,
                      color: textColor,
                    ),
                    const SizedBox(width: 5),
                  ],
                  Stack(
                    alignment: Alignment.center,
                    children: [
                      // 隐形粗体 RichText 占位锁死宽度，字重连续插值零抖动且不产生 find.text 双匹配冲突
                      IgnorePointer(
                        child: ExcludeSemantics(
                          child: Opacity(
                            opacity: 0,
                            child: RichText(
                              maxLines: 1,
                              softWrap: false,
                              overflow: TextOverflow.visible,
                              textScaler: MediaQuery.textScalerOf(context),
                              locale: Localizations.maybeLocaleOf(context),
                              text: TextSpan(
                                text: option.label,
                                style: KonataTheme.textStyle(
                                  fontSize: fontSize,
                                  weight: KonataTheme.weightActive,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      Text(
                        option.label,
                        maxLines: 1,
                        softWrap: false,
                        style: KonataTheme.textStyle(
                          color: textColor,
                          fontSize: fontSize,
                          weight: weight,
                        ),
                      ),
                    ],
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// 与 [KonataSegmentedCapsule] 联动的通用平滑面板过渡包装器（`AnimatedSize` + 单实例淡入轻滑）。
///
/// 始终只挂载当前唯一激活子面板，彻底杜绝高频往返切换时因新旧子面板短暂重叠导致的
/// `Duplicate GlobalKey` 与共享 `ScrollController` 双挂载崩溃，同时消除高度瞬跳与硬切闪烁。
class KonataSmoothSectionSwitcher extends StatefulWidget {
  /// 创建平滑面板过渡器。
  const KonataSmoothSectionSwitcher({
    super.key,
    required this.switchKey,
    required this.child,
    this.alignment = Alignment.topCenter,
  });

  /// 用于标识当前子面板的键值（变化时触发平滑渐隐位移切换）。
  final Object switchKey;

  /// 当前激活的子面板内容。
  final Widget child;

  /// 尺寸缩放对齐点（默认顶部居中对齐，避免弹窗上下跳动）。
  final Alignment alignment;

  @override
  State<KonataSmoothSectionSwitcher> createState() =>
      _KonataSmoothSectionSwitcherState();
}

class _KonataSmoothSectionSwitcherState
    extends State<KonataSmoothSectionSwitcher>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _opacity;
  late final Animation<Offset> _offset;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: KonataTheme.panelSwitchDuration,
      value: 1.0,
    );
    final curved = CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic);
    _opacity = curved;
    _offset = Tween<Offset>(
      begin: const Offset(0, 0.018),
      end: Offset.zero,
    ).animate(curved);
  }

  @override
  void didUpdateWidget(covariant KonataSmoothSectionSwitcher oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.switchKey != oldWidget.switchKey) {
      _ctrl.forward(from: 0.0);
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedSize(
      duration: KonataTheme.capsuleSlideDuration,
      curve: Curves.easeOutCubic,
      alignment: widget.alignment,
      clipBehavior: Clip.hardEdge,
      child: FadeTransition(
        opacity: _opacity,
        child: SlideTransition(
          position: _offset,
          child: KeyedSubtree(
            key: ValueKey<Object>(widget.switchKey),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}
