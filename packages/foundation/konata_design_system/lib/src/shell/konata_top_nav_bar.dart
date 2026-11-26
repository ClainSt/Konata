import 'dart:async';
import 'dart:ui';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../tokens/konata_palette.dart';
import '../tokens/konata_theme.dart';
import '../widgets/konata_tooltip.dart';
import 'capsule_navigation.dart';

/// 100% 透明去框化桌面顶部导航栏（高 52px，零桌面原生插件依赖）。
///
/// 左侧纯文字横向排布并带流畅滑动微光底条；右侧保留展开式搜索框、亮/暗主题切换与可选窗口控制槽位；
/// 窗口拖拽区与原生三键由桌面宿主壳通过 [windowDragBackground] 与 [trailingWindowControls] 注入，
/// 彻底避免向 Android 产物引入桌面插件。
class KonataTopNavBar extends StatefulWidget {
  /// 创建极简无框桌面顶栏。
  const KonataTopNavBar({
    super.key,
    required this.selectedIndex,
    required this.onSelectedIndexChanged,
    required this.searchQuery,
    required this.onSearchChanged,
    required this.searchFocusNode,
    required this.searchExpanded,
    required this.onSearchExpandedChanged,
    required this.onToggleTheme,
    this.items = KonataNavItem.defaults,
    this.showSearch = true,
    this.windowDragBackground,
    this.trailingWindowControls,
  });

  /// 顶栏导航条目集合（默认四主页）。
  final List<KonataNavItem> items;

  /// 当前激活页签下标。
  final int selectedIndex;

  /// 切换页签回调。
  final ValueChanged<int> onSelectedIndexChanged;

  /// 是否在当前页显示展开式搜索框（通常仅在媒体库页开启）。
  final bool showSearch;

  /// 当前搜索关键词。
  final String searchQuery;

  /// 搜索词变更回调（带防抖与输入法组合态保护）。
  final ValueChanged<String> onSearchChanged;

  /// 外部可触发聚焦的搜索焦点节点（供 `Ctrl + K` 快捷键使用）。
  final FocusNode searchFocusNode;

  /// 搜索框是否处于展开态。
  final bool searchExpanded;

  /// 搜索框展开态切换回调。
  final ValueChanged<bool> onSearchExpandedChanged;

  /// 一键切换亮/暗主题回调。
  final VoidCallback onToggleTheme;

  /// 可选底层空白区拖拽宿主（Windows 桌面宿主传入 `DragToMoveArea`）。
  final Widget? windowDragBackground;

  /// 可选最右侧窗口控制三键（Windows 桌面宿主传入 `WindowControls`）。
  final Widget? trailingWindowControls;

  @override
  State<KonataTopNavBar> createState() => _KonataTopNavBarState();
}

class _KonataTopNavBarState extends State<KonataTopNavBar> {
  late final TextEditingController _controller;
  late final FocusNode _searchEscapeFocusNode;
  Timer? _searchDebounce;
  late String _lastDispatchedQuery;

  @override
  void initState() {
    super.initState();
    _lastDispatchedQuery = widget.searchQuery;
    _controller = TextEditingController(text: widget.searchQuery);
    _controller.addListener(_handleControllerValueChanged);
    _searchEscapeFocusNode = FocusNode(skipTraversal: true);
    widget.searchFocusNode.addListener(_handleFocusChange);
  }

  @override
  void didUpdateWidget(covariant KonataTopNavBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.searchQuery != widget.searchQuery &&
        widget.searchQuery != _lastDispatchedQuery) {
      _searchDebounce?.cancel();
      _searchDebounce = null;
      _lastDispatchedQuery = widget.searchQuery;
      if (_controller.text != widget.searchQuery) {
        _controller.value = TextEditingValue(
          text: widget.searchQuery,
          selection: TextSelection.collapsed(offset: widget.searchQuery.length),
        );
      }
    }
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchDebounce = null;
    _controller.removeListener(_handleControllerValueChanged);
    widget.searchFocusNode.removeListener(_handleFocusChange);
    _searchEscapeFocusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _handleControllerValueChanged() {
    final value = _controller.value;
    if (value.text == _lastDispatchedQuery) return;
    // 输入法拼音组合尚未上屏前跳过过滤，避免未定稿字符频繁重绘海报墙。
    if (value.composing.isValid &&
        !value.composing.isCollapsed &&
        value.text.isNotEmpty) {
      return;
    }
    _searchDebounce?.cancel();
    if (value.text.isEmpty) {
      _searchDebounce = null;
      _dispatchSearchQuery('');
      return;
    }
    _searchDebounce = Timer(KonataTheme.searchInputDebounce, () {
      _searchDebounce = null;
      if (!mounted) return;
      _dispatchSearchQuery(_controller.text);
    });
  }

  void _dispatchSearchQuery(String query) {
    if (_lastDispatchedQuery == query) return;
    _lastDispatchedQuery = query;
    widget.onSearchChanged(query);
  }

  void _flushSearchImmediately() {
    _searchDebounce?.cancel();
    _searchDebounce = null;
    _dispatchSearchQuery(_controller.text);
  }

  void _handleFocusChange() {
    if (!widget.searchFocusNode.hasFocus &&
        _controller.text.trim().isEmpty &&
        widget.searchExpanded) {
      widget.onSearchExpandedChanged(false);
    }
  }

  void _collapseSearch() {
    _searchDebounce?.cancel();
    _searchDebounce = null;
    _controller.clear();
    _dispatchSearchQuery('');
    widget.searchFocusNode.unfocus();
    widget.onSearchExpandedChanged(false);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;

    return ClipRect(
      child: SizedBox(
        height: KonataTheme.topNavHeight,
        child: Stack(
          children: <Widget>[
            if (widget.windowDragBackground != null)
              Positioned.fill(child: widget.windowDragBackground!),
            LayoutBuilder(
              builder: (context, constraints) {
                final compactOuter = constraints.maxWidth < 360;
                final outerPad = compactOuter
                    ? 8.0
                    : KonataTheme.topNavOuterHorizontalPadding;
                final innerWidth = (constraints.maxWidth - outerPad * 2).clamp(
                  0.0,
                  double.infinity,
                );
                final controlsReserve = widget.trailingWindowControls != null
                    ? 116.0
                    : 0.0;
                final rightFixedWidth =
                    36.0 + controlsReserve + (innerWidth >= 240 ? 8.0 : 0.0);
                final searchExpandedWidth = (innerWidth - rightFixedWidth)
                    .clamp(32.0, 236.0);
                return Padding(
                  padding: EdgeInsets.symmetric(horizontal: outerPad),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            physics: const ClampingScrollPhysics(),
                            child: _TopNavTabStrip(
                              items: widget.items,
                              selectedIndex: widget.selectedIndex,
                              onSelectedIndexChanged:
                                  widget.onSelectedIndexChanged,
                            ),
                          ),
                        ),
                      ),
                      if (innerWidth >= 240) const SizedBox(width: 8),
                      if (widget.showSearch) ...[
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
                          onSubmitted: _flushSearchImmediately,
                          onCollapse: _collapseSearch,
                        ),
                        const SizedBox(width: 4),
                      ],
                      _TopNavIconButton(
                        tooltip: p.isDark ? '浅色模式' : '深色模式',
                        icon: p.isDark
                            ? Icons.light_mode_outlined
                            : Icons.dark_mode_outlined,
                        color: p.textSecondary,
                        hoverBg: p.secondaryButtonBg,
                        hoverColor: p.textPrimary,
                        onPressed: widget.onToggleTheme,
                      ),
                      if (widget.trailingWindowControls != null) ...[
                        const SizedBox(width: 8),
                        widget.trailingWindowControls!,
                      ],
                    ],
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _TopNavTabStrip extends StatefulWidget {
  const _TopNavTabStrip({
    required this.items,
    required this.selectedIndex,
    required this.onSelectedIndexChanged,
  });

  final List<KonataNavItem> items;
  final int selectedIndex;
  final ValueChanged<int> onSelectedIndexChanged;

  @override
  State<_TopNavTabStrip> createState() => _TopNavTabStripState();
}

class _TopNavTabStripState extends State<_TopNavTabStrip>
    with SingleTickerProviderStateMixin {
  static const double _indicatorRestWidth = 20.0;
  static const double _indicatorHeight = 2.5;

  final GlobalKey _tabsStackKey = GlobalKey();
  late List<GlobalKey> _tabKeys;
  late final AnimationController _sliderCtrl;
  late List<double?> _tabCenters;

  double? _fromLeft;
  double? _fromRight;
  double? _toLeft;
  double? _toRight;
  bool _movingForward = true;

  @override
  void initState() {
    super.initState();
    _tabKeys = List<GlobalKey>.generate(
      widget.items.length,
      (_) => GlobalKey(),
    );
    _tabCenters = List<double?>.filled(widget.items.length, null);
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
    if (oldWidget.items.length != widget.items.length) {
      _tabKeys = List<GlobalKey>.generate(
        widget.items.length,
        (_) => GlobalKey(),
      );
      _tabCenters = List<double?>.filled(widget.items.length, null);
      _fromLeft = null;
      _fromRight = null;
      _toLeft = null;
      _toRight = null;
      _scheduleMeasure();
      return;
    }
    if (oldWidget.selectedIndex != widget.selectedIndex) {
      _transitionTo(widget.selectedIndex);
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
    if (stackBox == null || !stackBox.hasSize || widget.items.isEmpty) return;
    final next = <double?>[];
    for (var i = 0; i < _tabKeys.length; i++) {
      final tabBox =
          _tabKeys[i].currentContext?.findRenderObject() as RenderBox?;
      if (tabBox == null || !tabBox.hasSize) {
        next.add(null);
      } else {
        final center = tabBox
            .localToGlobal(Offset(tabBox.size.width / 2, 0), ancestor: stackBox)
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

    final safeIdx = widget.selectedIndex.clamp(0, next.length - 1);
    final activeCenter = next[safeIdx];
    if (activeCenter == null) return;
    const half = _indicatorRestWidth / 2;

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
    if (_tabCenters.isEmpty) return;
    final safeIdx = targetIndex.clamp(0, _tabCenters.length - 1);
    final targetCenter = _tabCenters[safeIdx];
    if (targetCenter == null) {
      _scheduleMeasure();
      return;
    }
    const half = _indicatorRestWidth / 2;
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
    unawaited(_sliderCtrl.forward(from: 0.0));
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
          children: <Widget>[
            Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                for (var i = 0; i < widget.items.length; i++) ...[
                  if (i > 0) const SizedBox(width: 28),
                  KeyedSubtree(
                    key: _tabKeys[i],
                    child: _TextNavTab(
                      label: widget.items[i].label,
                      selected: widget.selectedIndex == i,
                      onTap: () => widget.onSelectedIndexChanged(i),
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
                      boxShadow: <BoxShadow>[
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
                        ? <Shadow>[
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
                    children: <Widget>[
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
                // 隐形粗字重占位锁定固有宽度，消除可变字重插值时相邻标签微抖。
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
    required this.onSubmitted,
    required this.onCollapse,
  });

  final bool expanded;
  final double expandedWidth;
  final TextEditingController controller;
  final FocusNode focusNode;
  final FocusNode escapeFocusNode;
  final VoidCallback onExpand;
  final VoidCallback onSubmitted;
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
          color: showExpanded ? p.softFill : p.softFill.withValues(alpha: 0),
          borderRadius: KonataTheme.borderRadiusSheet,
        ),
        child: showExpanded
            ? Listener(
                behavior: HitTestBehavior.opaque,
                child: ClipRect(
                  child: OverflowBox(
                    minWidth: expandedWidth,
                    maxWidth: expandedWidth,
                    minHeight: 32,
                    maxHeight: 32,
                    alignment: Alignment.centerLeft,
                    child: KeyboardListener(
                      focusNode: escapeFocusNode,
                      onKeyEvent: (event) {
                        if (event is KeyDownEvent &&
                            event.logicalKey == LogicalKeyboardKey.escape) {
                          onCollapse();
                        }
                      },
                      child: Row(
                        children: <Widget>[
                          GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: focusNode.requestFocus,
                            child: Padding(
                              padding: const EdgeInsets.only(
                                left: 10,
                                right: 6,
                              ),
                              child: Icon(
                                Icons.search_rounded,
                                size: 15,
                                color: p.textSecondary,
                              ),
                            ),
                          ),
                          Expanded(
                            child: TextField(
                              key: const ValueKey('top_nav_search_text_field'),
                              controller: controller,
                              focusNode: focusNode,
                              onSubmitted: (_) => onSubmitted(),
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
                tooltip: '搜索媒体库',
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
    return KonataTooltip(
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
                borderRadius: KonataTheme.borderRadiusControl,
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
