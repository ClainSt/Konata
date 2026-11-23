import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../../application/providers/library_providers.dart';
import '../theme/konata_palette.dart';
import '../theme/konata_theme.dart';
import 'window_controls.dart';

/// 100% 透明去框化顶部导航栏（高 52px，全宽可拖拽窗口）。
///
/// 左侧纯文字横向排布：`媒体库`、`媒体源`、`播放记录`、`设置`（间距 28px）；
/// 右侧仅保留：展开式放大镜 `🔍`（仅媒体库）、亮/暗主题切换图标、窗口控制键。
class TopNavBar extends StatefulWidget {
  /// 创建极简无框顶栏。
  const TopNavBar({
    super.key,
    required this.activeSection,
    required this.onSectionChanged,
    required this.searchQuery,
    required this.onSearchChanged,
    required this.searchFocusNode,
    required this.searchExpanded,
    required this.onSearchExpandedChanged,
    required this.onToggleTheme,
  });

  /// 当前激活的一级导航标签。
  final KonataNavSection activeSection;

  /// 切换页签回调。
  final ValueChanged<KonataNavSection> onSectionChanged;

  /// 当前搜索关键词。
  final String searchQuery;

  /// 搜索词变更回调。
  final ValueChanged<String> onSearchChanged;

  /// 外部可触发聚焦的搜索焦点节点（供 `Ctrl + K` 使用）。
  final FocusNode searchFocusNode;

  /// 搜索框是否处于展开态。
  final bool searchExpanded;

  /// 搜索框展开态切换回调。
  final ValueChanged<bool> onSearchExpandedChanged;

  /// 一键切换亮/暗主题回调。
  final VoidCallback onToggleTheme;

  @override
  State<TopNavBar> createState() => _TopNavBarState();
}

class _TopNavBarState extends State<TopNavBar> {
  late final TextEditingController _controller;
  late final FocusNode _searchEscapeFocusNode;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.searchQuery);
    _searchEscapeFocusNode = FocusNode(skipTraversal: true);
    widget.searchFocusNode.addListener(_handleFocusChange);
  }

  @override
  void didUpdateWidget(covariant TopNavBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.searchQuery != _controller.text) {
      _controller.text = widget.searchQuery;
    }
  }

  @override
  void dispose() {
    widget.searchFocusNode.removeListener(_handleFocusChange);
    _searchEscapeFocusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _handleFocusChange() {
    if (!widget.searchFocusNode.hasFocus &&
        _controller.text.trim().isEmpty &&
        widget.searchExpanded) {
      widget.onSearchExpandedChanged(false);
    }
  }

  void _collapseSearch() {
    _controller.clear();
    widget.onSearchChanged('');
    widget.searchFocusNode.unfocus();
    widget.onSearchExpandedChanged(false);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final isLibrary = widget.activeSection == KonataNavSection.library;

    final barContent = ClipRect(
      child: SizedBox(
        height: KonataTheme.topNavHeight,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compactOuter = constraints.maxWidth < 360;
            final outerPad = compactOuter
                ? 8.0
                : KonataTheme.topNavOuterHorizontalPadding;
            final innerWidth = (constraints.maxWidth - outerPad * 2).clamp(
              0.0,
              double.infinity,
            );
            // 右侧固定控件（搜索间隙 4 + 主题键 32 + 间隙 8 + 窗口三键 108 = 152）与最小安全余量。
            final rightFixedWidth = 152.0 + (innerWidth >= 240 ? 8.0 : 0.0);
            final searchExpandedWidth = (innerWidth - rightFixedWidth).clamp(
              32.0,
              236.0,
            );
            return Padding(
              padding: EdgeInsets.symmetric(horizontal: outerPad),
              child: Row(
                children: [
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        physics: const ClampingScrollPhysics(),
                        child: _TopNavTabStrip(
                          activeSection: widget.activeSection,
                          onSectionChanged: widget.onSectionChanged,
                        ),
                      ),
                    ),
                  ),
                  if (innerWidth >= 240) const SizedBox(width: 8),
                  if (isLibrary) ...[
                    _ExpandableSearchBox(
                      expanded: widget.searchExpanded,
                      expandedWidth: searchExpandedWidth,
                      controller: _controller,
                      focusNode: widget.searchFocusNode,
                      escapeFocusNode: _searchEscapeFocusNode,
                      onExpand: () {
                        widget.onSearchExpandedChanged(true);
                        widget.searchFocusNode.requestFocus();
                      },
                      onChanged: widget.onSearchChanged,
                      onCollapse: _collapseSearch,
                    ),
                    const SizedBox(width: 4),
                  ],
                  _TopNavIconButton(
                    tooltip: p.isDark ? '切换亮色模式' : '切换暗色模式',
                    icon: p.isDark
                        ? Icons.light_mode_outlined
                        : Icons.dark_mode_outlined,
                    color: p.textSecondary,
                    hoverBg: p.secondaryButtonBg,
                    hoverColor: p.textPrimary,
                    onPressed: widget.onToggleTheme,
                  ),
                  const SizedBox(width: 8),
                  const WindowControls(),
                ],
              ),
            );
          },
        ),
      ),
    );

    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
      return DragToMoveArea(child: barContent);
    }
    return barContent;
  }
}

class _TopNavTabStrip extends StatefulWidget {
  const _TopNavTabStrip({
    required this.activeSection,
    required this.onSectionChanged,
  });

  final KonataNavSection activeSection;
  final ValueChanged<KonataNavSection> onSectionChanged;

  @override
  State<_TopNavTabStrip> createState() => _TopNavTabStripState();
}

class _TopNavTabStripState extends State<_TopNavTabStrip>
    with SingleTickerProviderStateMixin {
  static const List<(KonataNavSection section, String label)> _entries = [
    (KonataNavSection.library, '媒体库'),
    (KonataNavSection.sources, '媒体源'),
    (KonataNavSection.history, '播放记录'),
    (KonataNavSection.settings, '设置'),
  ];
  static const double _indicatorRestWidth = 20.0;
  static const double _indicatorHeight = 2.5;

  final GlobalKey _tabsStackKey = GlobalKey();
  late final List<GlobalKey> _tabKeys = List<GlobalKey>.generate(
    _entries.length,
    (_) => GlobalKey(),
  );
  late final AnimationController _sliderCtrl;

  List<double?> _tabCenters = List<double?>.filled(_entries.length, null);
  double? _fromLeft;
  double? _fromRight;
  double? _toLeft;
  double? _toRight;
  bool _movingForward = true;

  @override
  void initState() {
    super.initState();
    _sliderCtrl = AnimationController(
      vsync: this,
      duration: KonataTheme.navSliderDuration,
      value: 1.0,
    );
    _scheduleMeasure();
  }

  @override
  void didUpdateWidget(covariant _TopNavTabStrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.activeSection != widget.activeSection) {
      _transitionTo(widget.activeSection.index);
    }
    if (_tabCenters.any((c) => c == null)) {
      _scheduleMeasure();
    }
  }

  @override
  void dispose() {
    _sliderCtrl.dispose();
    super.dispose();
  }

  void _scheduleMeasure() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _measureTabs();
    });
  }

  void _measureTabs() {
    final stackBox =
        _tabsStackKey.currentContext?.findRenderObject() as RenderBox?;
    if (stackBox == null || !stackBox.hasSize) return;
    final next = <double?>[];
    for (var i = 0; i < _tabKeys.length; i++) {
      final tabBox =
          _tabKeys[i].currentContext?.findRenderObject() as RenderBox?;
      if (tabBox == null || !tabBox.hasSize) {
        next.add(null);
      } else {
        final center = tabBox
            .localToGlobal(
              Offset(tabBox.size.width / 2, 0),
              ancestor: stackBox,
            )
            .dx;
        next.add(center);
      }
    }
    var changed = false;
    for (var i = 0; i < next.length; i++) {
      if (_tabCenters[i] != next[i]) {
        changed = true;
        break;
      }
    }
    _tabCenters = next;

    final activeCenter = next[widget.activeSection.index];
    if (activeCenter == null) return;
    final half = _indicatorRestWidth / 2;

    if (_fromLeft == null || _toLeft == null) {
      setState(() {
        _fromLeft = activeCenter - half;
        _fromRight = activeCenter + half;
        _toLeft = activeCenter - half;
        _toRight = activeCenter + half;
        _sliderCtrl.value = 1.0;
      });
      return;
    }

    if (changed) {
      setState(() {
        _toLeft = activeCenter - half;
        _toRight = activeCenter + half;
      });
    }
  }

  ({double left, double right}) _currentEdges() {
    final fl = _fromLeft!;
    final fr = _fromRight!;
    final tl = _toLeft!;
    final tr = _toRight!;
    final t = _sliderCtrl.value;
    // 克制的前后沿时间差配合 easeOutQuart，使指示条轻柔舒展滑行而非夸张甩尾。
    final leadingT = const Interval(
      0.0,
      0.82,
      curve: Curves.easeOutQuart,
    ).transform(t);
    final trailingT = const Interval(
      0.12,
      1.0,
      curve: Curves.easeOutQuart,
    ).transform(t);
    if (_movingForward) {
      return (
        left: lerpDouble(fl, tl, trailingT)!,
        right: lerpDouble(fr, tr, leadingT)!,
      );
    }
    return (
      left: lerpDouble(fl, tl, leadingT)!,
      right: lerpDouble(fr, tr, trailingT)!,
    );
  }

  void _transitionTo(int targetIndex) {
    final targetCenter = _tabCenters[targetIndex];
    if (targetCenter == null) {
      _scheduleMeasure();
      return;
    }
    final half = _indicatorRestWidth / 2;
    if (_fromLeft == null || _toLeft == null) {
      _fromLeft = targetCenter - half;
      _fromRight = targetCenter + half;
      _toLeft = targetCenter - half;
      _toRight = targetCenter + half;
      _sliderCtrl.value = 1.0;
      return;
    }

    final current = _currentEdges();
    final curCenter = (current.left + current.right) / 2;
    _fromLeft = current.left;
    _fromRight = current.right;
    _toLeft = targetCenter - half;
    _toRight = targetCenter + half;
    _movingForward = targetCenter >= curCenter;
    _sliderCtrl.forward(from: 0.0);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;

    return NotificationListener<SizeChangedLayoutNotification>(
      onNotification: (_) {
        _scheduleMeasure();
        return false;
      },
      child: SizeChangedLayoutNotifier(
        child: Stack(
          key: _tabsStackKey,
          clipBehavior: Clip.none,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < _entries.length; i++) ...[
                  if (i > 0) const SizedBox(width: 28),
                  KeyedSubtree(
                    key: _tabKeys[i],
                    child: _TextNavTab(
                      label: _entries[i].$2,
                      selected: widget.activeSection == _entries[i].$1,
                      onTap: () => widget.onSectionChanged(_entries[i].$1),
                    ),
                  ),
                ],
              ],
            ),
            if (_fromLeft != null && _toLeft != null)
              AnimatedBuilder(
                animation: _sliderCtrl,
                child: IgnorePointer(
                  child: DecoratedBox(
                    key: const ValueKey('top_nav_fluid_indicator'),
                    decoration: BoxDecoration(
                      color: p.progressFill,
                      borderRadius: KonataTheme.borderRadiusPill,
                      boxShadow: [
                        BoxShadow(
                          color: p.progressFill.withValues(alpha: 0.22),
                          blurRadius: 4,
                        ),
                      ],
                    ),
                  ),
                ),
                builder: (context, indicator) {
                  final edges = _currentEdges();
                  final width = (edges.right - edges.left).clamp(
                    _indicatorRestWidth * 0.5,
                    600.0,
                  );
                  return Positioned(
                    left: edges.left,
                    bottom: 0,
                    width: width,
                    height: _indicatorHeight,
                    child: indicator!,
                  );
                },
              ),
          ],
        ),
      ),
    );
  }
}

class _TextNavTab extends StatefulWidget {
  const _TextNavTab({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_TextNavTab> createState() => _TextNavTabState();
}

class _TextNavTabState extends State<_TextNavTab> {
  static const double _weightReserve = 700.0;
  static final TextStyle _boldReserveStyle = KonataTheme.textStyle(
    fontSize: KonataTheme.fontSizeBodyMd,
    weight: _weightReserve,
  );

  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() {
        _hovered = false;
        _pressed = false;
      }),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _pressed ? 0.97 : 1.0,
          duration: KonataTheme.motionFast,
          curve: Curves.easeOutQuart,
          child: AnimatedContainer(
            duration: KonataTheme.motionFast,
            curve: Curves.easeOutCubic,
            decoration: BoxDecoration(
              color: (!widget.selected && _hovered)
                  ? p.secondaryButtonBg
                  : Colors.transparent,
              borderRadius: KonataTheme.borderRadiusControl,
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                KonataTheme.topNavTabHorizontalPadding,
                6,
                KonataTheme.topNavTabHorizontalPadding,
                10,
              ),
              child: TweenAnimationBuilder<double>(
                duration: KonataTheme.navSliderDuration,
                curve: Curves.easeOutQuart,
                tween: Tween<double>(end: widget.selected ? 1.0 : 0.0),
                builder: (context, t, reserveChild) {
                  final inactiveColor = _hovered
                      ? p.textPrimary.withValues(alpha: 0.86)
                      : p.textSecondary;
                  final textColor =
                      Color.lerp(inactiveColor, p.textPrimary, t) ??
                      p.textPrimary;
                  final weight = lerpDouble(
                    KonataTheme.weightRegularLabel,
                    KonataTheme.weightActive,
                    t,
                  )!;
                  final activeStyle = KonataTheme.textStyle(
                    color: textColor,
                    fontSize: KonataTheme.fontSizeBodyMd,
                    weight: weight,
                    shadows: t > 0.02
                        ? [
                            Shadow(
                              color: p.progressFill.withValues(
                                alpha: (p.isDark ? 0.10 : 0.04) * t,
                              ),
                              blurRadius: 6.0 * t,
                            ),
                          ]
                        : null,
                  );

                  return Stack(
                    alignment: Alignment.center,
                    clipBehavior: Clip.none,
                    children: [
                      reserveChild!,
                      Text(
                        widget.label,
                        style: activeStyle,
                        softWrap: false,
                        maxLines: 1,
                        overflow: TextOverflow.visible,
                      ),
                    ],
                  );
                },
                // 隐形 w700 RichText 锁死固有宽度，杜绝可变字重插值引起相邻标签微抖，通过 child 复用避免逐帧重建
                child: IgnorePointer(
                  child: ExcludeSemantics(
                    child: Opacity(
                      opacity: 0,
                      child: RichText(
                        softWrap: false,
                        maxLines: 1,
                        overflow: TextOverflow.visible,
                        textScaler: MediaQuery.textScalerOf(context),
                        locale: Localizations.maybeLocaleOf(context),
                        text: TextSpan(
                          text: widget.label,
                          style: DefaultTextStyle.of(
                            context,
                          ).style.merge(_boldReserveStyle),
                        ),
                      ),
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

class _ExpandableSearchBox extends StatelessWidget {
  const _ExpandableSearchBox({
    required this.expanded,
    required this.expandedWidth,
    required this.controller,
    required this.focusNode,
    required this.escapeFocusNode,
    required this.onExpand,
    required this.onChanged,
    required this.onCollapse,
  });

  final bool expanded;
  final double expandedWidth;
  final TextEditingController controller;
  final FocusNode focusNode;
  final FocusNode escapeFocusNode;
  final VoidCallback onExpand;
  final ValueChanged<String> onChanged;
  final VoidCallback onCollapse;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final showExpanded = expanded && expandedWidth >= 96.0;
    final targetWidth = showExpanded ? expandedWidth : 32.0;

    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: expandedWidth),
      child: AnimatedContainer(
        duration: KonataTheme.navSliderDuration,
        curve: Curves.easeOutCubic,
        width: targetWidth,
        height: 32,
        decoration: BoxDecoration(
          color: showExpanded ? p.softFill : Colors.transparent,
          borderRadius: KonataTheme.borderRadiusSheet,
        ),
        child: showExpanded
            ? ClipRect(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  physics: const NeverScrollableScrollPhysics(),
                  child: SizedBox(
                    width: expandedWidth,
                    height: 32,
                    child: KeyboardListener(
                      focusNode: escapeFocusNode,
                      onKeyEvent: (event) {
                        if (event is KeyDownEvent &&
                            event.logicalKey == LogicalKeyboardKey.escape) {
                          onCollapse();
                        }
                      },
                      child: Row(
                        children: [
                          const SizedBox(width: 10),
                          Icon(
                            Icons.search_rounded,
                            size: 15,
                            color: p.textSecondary,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: TextField(
                              controller: controller,
                              focusNode: focusNode,
                              onChanged: onChanged,
                              style: TextStyle(
                                color: p.textPrimary,
                                fontSize: KonataTheme.fontSizeBodyXs,
                              ),
                              decoration: const InputDecoration(
                                border: InputBorder.none,
                                enabledBorder: InputBorder.none,
                                focusedBorder: InputBorder.none,
                                isDense: true,
                                contentPadding: EdgeInsets.zero,
                              ),
                            ),
                          ),
                          _TopNavIconButton(
                            tooltip: '清空并收起',
                            icon: Icons.close_rounded,
                            iconSize: 14,
                            size: 28,
                            color: p.textSecondary,
                            hoverBg: Colors.transparent,
                            hoverColor: p.textPrimary,
                            onPressed: onCollapse,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              )
            : _TopNavIconButton(
                tooltip: '搜索媒体库 (Ctrl + K)',
                icon: Icons.search_rounded,
                color: p.textSecondary,
                hoverBg: p.secondaryButtonBg,
                hoverColor: p.textPrimary,
                onPressed: onExpand,
              ),
      ),
    );
  }
}

class _TopNavIconButton extends StatefulWidget {
  const _TopNavIconButton({
    required this.tooltip,
    required this.icon,
    required this.color,
    required this.hoverBg,
    required this.hoverColor,
    required this.onPressed,
    this.iconSize = 17,
    this.size = 32,
  });

  final String tooltip;
  final IconData icon;
  final Color color;
  final Color hoverBg;
  final Color hoverColor;
  final VoidCallback onPressed;
  final double iconSize;
  final double size;

  @override
  State<_TopNavIconButton> createState() => _TopNavIconButtonState();
}

class _TopNavIconButtonState extends State<_TopNavIconButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onPressed,
          child: SizedBox(
            width: widget.size,
            height: widget.size,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: _hovered ? widget.hoverBg : Colors.transparent,
                borderRadius: KonataTheme.borderRadiusSm,
              ),
              child: Center(
                child: Icon(
                  widget.icon,
                  size: widget.iconSize,
                  color: _hovered ? widget.hoverColor : widget.color,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
