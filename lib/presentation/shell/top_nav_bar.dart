import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
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

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.searchQuery);
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
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: KonataTheme.topNavOuterHorizontalPadding,
          ),
          child: Row(
            children: [
              _TextNavTab(
                label: '媒体库',
                selected: widget.activeSection == KonataNavSection.library,
                onTap: () => widget.onSectionChanged(KonataNavSection.library),
              ),
              const SizedBox(width: 28),
              _TextNavTab(
                label: '媒体源',
                selected: widget.activeSection == KonataNavSection.sources,
                onTap: () => widget.onSectionChanged(KonataNavSection.sources),
              ),
              const SizedBox(width: 28),
              _TextNavTab(
                label: '播放记录',
                selected: widget.activeSection == KonataNavSection.history,
                onTap: () => widget.onSectionChanged(KonataNavSection.history),
              ),
              const SizedBox(width: 28),
              _TextNavTab(
                label: '设置',
                selected: widget.activeSection == KonataNavSection.settings,
                onTap: () => widget.onSectionChanged(KonataNavSection.settings),
              ),
              const Spacer(),
              if (isLibrary) ...[
                _ExpandableSearchBox(
                  expanded: widget.searchExpanded,
                  controller: _controller,
                  focusNode: widget.searchFocusNode,
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
        ),
      ),
    );

    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
      return DragToMoveArea(child: barContent);
    }
    return barContent;
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
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: KonataTheme.topNavTabHorizontalPadding,
            vertical: 6,
          ),
          child: TweenAnimationBuilder<double>(
            duration: KonataTheme.standardTransition,
            curve: Curves.easeOutCubic,
            tween: Tween<double>(end: widget.selected ? 1.0 : 0.0),
            builder: (context, t, _) {
              final inactiveColor = _hovered
                  ? p.textPrimary.withValues(alpha: 0.85)
                  : p.textSecondary;
              final textColor =
                  Color.lerp(inactiveColor, p.textPrimary, t) ?? p.textPrimary;
              final weight = lerpDouble(
                KonataTheme.weightRegularLabel,
                KonataTheme.weightActive,
                t,
              )!;
              final boldReserveStyle = KonataTheme.textStyle(
                fontSize: 14,
                weight: KonataTheme.weightActive,
              );
              final activeStyle = KonataTheme.textStyle(
                color: textColor,
                fontSize: 14,
                weight: weight,
                shadows: t > 0.02
                    ? [
                        Shadow(
                          color: (p.isDark ? p.accent : p.textPrimary)
                              .withValues(alpha: (p.isDark ? 0.35 : 0.14) * t),
                          blurRadius: 12 * t,
                        ),
                      ]
                    : null,
              );

              return Stack(
                alignment: Alignment.center,
                clipBehavior: Clip.none,
                children: [
                  // 隐形粗体 RichText 由字体引擎自动撑出等宽占位，杜绝多字裁切、切页抖动及 find.text 双匹配冲突
                  Padding(
                    padding: const EdgeInsets.only(bottom: 5),
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
                              ).style.merge(boldReserveStyle),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 5),
                    child: Text(
                      widget.label,
                      style: activeStyle,
                      softWrap: false,
                      maxLines: 1,
                      overflow: TextOverflow.visible,
                    ),
                  ),
                  if (t > 0.005)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: Center(
                        child: Opacity(
                          opacity: t,
                          child: Container(
                            width: 6 + 12 * t,
                            height: 2,
                            decoration: BoxDecoration(
                              color: p.isDark ? p.accent : p.textPrimary,
                              borderRadius: BorderRadius.circular(999),
                              boxShadow: [
                                BoxShadow(
                                  color: (p.isDark ? p.accent : p.textPrimary)
                                      .withValues(alpha: 0.45 * t),
                                  blurRadius: 8,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
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

class _ExpandableSearchBox extends StatelessWidget {
  const _ExpandableSearchBox({
    required this.expanded,
    required this.controller,
    required this.focusNode,
    required this.onExpand,
    required this.onChanged,
    required this.onCollapse,
  });

  final bool expanded;
  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onExpand;
  final ValueChanged<String> onChanged;
  final VoidCallback onCollapse;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      width: expanded ? 236 : 32,
      height: 32,
      decoration: BoxDecoration(
        color: expanded ? p.softFill : Colors.transparent,
        borderRadius: BorderRadius.circular(16),
      ),
      child: expanded
          ? ClipRect(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                physics: const NeverScrollableScrollPhysics(),
                child: SizedBox(
                  width: 236,
                  height: 32,
                  child: KeyboardListener(
                    focusNode: FocusNode(skipTraversal: true),
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
                              fontSize: 12.5,
                            ),
                            decoration: InputDecoration(
                              hintText: '搜索作品 / 原名 / 压制组 / ID',
                              hintStyle: TextStyle(
                                color: p.textMuted,
                                fontSize: 12,
                              ),
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
                borderRadius: BorderRadius.circular(8),
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
