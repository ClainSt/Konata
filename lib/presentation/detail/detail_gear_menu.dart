import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../shell/adaptive_capsule_layout.dart';
import '../theme/konata_adaptive_tokens.dart';
import '../theme/konata_palette.dart';
import '../theme/konata_playback_tokens.dart';
import '../widgets/design_system/konata_draggable_scrollbar.dart';
import '../widgets/design_system/konata_popover_option_tile.dart';
import '../theme/konata_theme.dart';

/// 详情页公共高透运维胶囊（展开态在齿轮左侧展示「完整列表」与可选「收起」图标，齿轮固定最右侧并弹出管理菜单）。
class DetailOpsCapsule extends StatefulWidget {
  /// 创建详情页运维控制胶囊。
  const DetailOpsCapsule({
    super.key,
    required this.isExpanded,
    required this.hasContent,
    required this.onOpenFullList,
    required this.onManualMatch,
    required this.onManualEdit,
    required this.onEditPoster,
    required this.onEditBackdrop,
    this.onEditLogo,
    required this.onHideWork,
    required this.onDeleteWork,
    required this.onRescrape,
    this.onSyncBangumi,
    required this.onOpenLocalDir,
    this.onManageSeries,
    this.onMergeWork,
    this.onCollapse,
    this.showCollapseButton = true,
    this.openDownward = false,
  });

  /// 当前选集分类是否处于展开状态（决定是否展示齿轮左侧的完整列表图标）。
  final bool isExpanded;

  /// 当前激活分类下是否有条目（决定完整列表图标是否可点击）。
  final bool hasContent;

  /// 点击「完整列表」图标回调。
  final VoidCallback onOpenFullList;

  /// 点击「收起剧集」图标回调。
  final VoidCallback? onCollapse;

  /// 是否在展开态展示「收起」向下箭头（桌面与平板使用，手机右上角隐藏）。
  final bool showCollapseButton;

  /// 管理菜单是否向下弹出（手机右上角置顶时为 `true`，桌面与平板底部悬停时为 `false`）。
  final bool openDownward;

  /// 各项管理菜单回调。
  final VoidCallback onManualMatch;
  final VoidCallback onManualEdit;
  final VoidCallback onEditPoster;
  final VoidCallback onEditBackdrop;
  final VoidCallback? onEditLogo;
  final VoidCallback onHideWork;
  final VoidCallback onDeleteWork;
  final VoidCallback onRescrape;
  final VoidCallback? onSyncBangumi;
  final VoidCallback onOpenLocalDir;
  final VoidCallback? onManageSeries;
  final VoidCallback? onMergeWork;

  @override
  State<DetailOpsCapsule> createState() => _DetailOpsCapsuleState();
}

class _DetailOpsCapsuleState extends State<DetailOpsCapsule> {
  final LayerLink _gearLink = LayerLink();
  final GlobalKey _gearButtonKey = GlobalKey();
  ModalRoute<VoidCallback>? _gearMenuRoute;

  @override
  void dispose() {
    _gearMenuRoute = null;
    super.dispose();
  }

  Rect? _resolveGearButtonRect() {
    final box = _gearButtonKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return null;
    final topLeft = box.localToGlobal(Offset.zero);
    return topLeft & box.size;
  }

  void _toggleMenu() {
    final activeRoute = _gearMenuRoute;
    if (activeRoute != null && activeRoute.isActive) {
      Navigator.of(context, rootNavigator: true).removeRoute(activeRoute);
      _gearMenuRoute = null;
      setState(() {});
      return;
    }
    final anchorRect = _resolveGearButtonRect();
    final route = RawDialogRoute<VoidCallback>(
      barrierDismissible: true,
      barrierColor: Colors.transparent,
      transitionDuration: Duration.zero,
      pageBuilder: (routeCtx, _, _) => KonataModalRouteScope(
        child: DetailGearMenuOverlay(
          link: _gearLink,
          anchorRect: anchorRect,
          openDownward: widget.openDownward,
          onDismiss: () {
            if (Navigator.of(routeCtx).canPop()) {
              Navigator.of(routeCtx).pop();
            }
          },
          onSelect: (action) {
            Navigator.of(routeCtx).pop(action);
          },
          onManualMatch: widget.onManualMatch,
          onManualEdit: widget.onManualEdit,
          onEditPoster: widget.onEditPoster,
          onEditBackdrop: widget.onEditBackdrop,
          onEditLogo: widget.onEditLogo,
          onHideWork: widget.onHideWork,
          onDeleteWork: widget.onDeleteWork,
          onRescrape: widget.onRescrape,
          onSyncBangumi: widget.onSyncBangumi,
          onOpenLocalDir: widget.onOpenLocalDir,
          onManageSeries: widget.onManageSeries,
          onMergeWork: widget.onMergeWork,
        ),
      ),
    );
    _gearMenuRoute = route;
    setState(() {});
    Navigator.of(context, rootNavigator: true).push<VoidCallback>(route).then((
      selectedAction,
    ) {
      if (identical(_gearMenuRoute, route)) {
        _gearMenuRoute = null;
        if (mounted) setState(() {});
      }
      selectedAction?.call();
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final compactPad = KonataAdaptiveTokens.isAndroid;
    return ClipRRect(
      borderRadius: KonataTheme.borderRadiusPill,
      child: BackdropFilter(
        filter: KonataTheme.blurFilterMedium,
        child: Container(
          padding: compactPad
              ? EdgeInsets.symmetric(
                  horizontal: widget.isExpanded ? 4 : 0,
                  vertical: 0,
                )
              : (widget.isExpanded
                    ? const EdgeInsets.symmetric(horizontal: 6, vertical: 4)
                    : const EdgeInsets.all(4)),
          decoration: BoxDecoration(
            color: KonataPlaybackTokens.glassSurface(p),
            borderRadius: KonataTheme.borderRadiusPill,
            border: Border.all(
              color: KonataPlaybackTokens.glassBorder(p),
              width: 1,
            ),
          ),
          child: AnimatedSize(
            duration: KonataTheme.motionNormal,
            curve: Curves.easeOutCubic,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.isExpanded) ...[
                  DetailDrawerHeaderButton(
                    icon: Icons.grid_view_rounded,
                    tooltip: '完整列表',
                    enabled: widget.hasContent,
                    onPressed: widget.onOpenFullList,
                  ),
                  if (widget.showCollapseButton &&
                      widget.onCollapse != null) ...[
                    const SizedBox(width: 2),
                    DetailDrawerHeaderButton(
                      icon: Icons.keyboard_arrow_down_rounded,
                      tooltip: '收起剧集 (Esc)',
                      onPressed: widget.onCollapse!,
                    ),
                  ],
                  const SizedBox(width: 2),
                ],
                CompositedTransformTarget(
                  key: _gearButtonKey,
                  link: _gearLink,
                  child: DetailDrawerHeaderButton(
                    icon: Icons.settings_rounded,
                    tooltip: '作品管理选项',
                    active: _gearMenuRoute?.isActive == true,
                    onPressed: _toggleMenu,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 详情页齿轮弹出的高透毛玻璃作品管理菜单（自适应展开方向并严格钳制安全区高度，支持纵向滚动）。
class DetailGearMenuOverlay extends StatefulWidget {
  /// 创建悬浮作品管理菜单。
  const DetailGearMenuOverlay({
    super.key,
    required this.link,
    required this.onDismiss,
    required this.onSelect,
    required this.onManualMatch,
    required this.onManualEdit,
    required this.onEditPoster,
    required this.onEditBackdrop,
    this.onEditLogo,
    required this.onHideWork,
    required this.onDeleteWork,
    required this.onRescrape,
    this.onSyncBangumi,
    required this.onOpenLocalDir,
    this.anchorRect,
    this.onManageSeries,
    this.onMergeWork,
    this.openDownward = false,
  });

  /// 锚定在齿轮图标上的坐标连接器。
  final LayerLink link;

  /// 齿轮按钮在屏幕坐标系中的全局包围盒（用于精确计算上下可用安全区高度）。
  final Rect? anchorRect;

  /// 点击空白处关闭回调。
  final VoidCallback onDismiss;

  /// 执行某项并关闭菜单的包裹器。
  final ValueChanged<VoidCallback> onSelect;

  /// 各项作品管理操作回调。
  final VoidCallback onManualMatch;
  final VoidCallback onManualEdit;
  final VoidCallback onEditPoster;
  final VoidCallback onEditBackdrop;
  final VoidCallback? onEditLogo;
  final VoidCallback onHideWork;
  final VoidCallback onDeleteWork;
  final VoidCallback onRescrape;
  final VoidCallback? onSyncBangumi;
  final VoidCallback onOpenLocalDir;
  final VoidCallback? onManageSeries;
  final VoidCallback? onMergeWork;

  /// 首选是否向下展开（当首选方向剩余高度不足时会自动翻转至空间更大的一侧）。
  final bool openDownward;

  @override
  State<DetailGearMenuOverlay> createState() => _DetailGearMenuOverlayState();
}

class _DetailGearMenuOverlayState extends State<DetailGearMenuOverlay> {
  final ScrollController _scrollCtrl = ScrollController();
  String? _hoveredLabel;

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  Widget _buildRow({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool isDanger = false,
  }) => _MenuRow(
    icon: icon,
    label: label,
    isDanger: isDanger,
    hovered: _hoveredLabel == label,
    onHoverEnter: () {
      if (_hoveredLabel != label) {
        setState(() => _hoveredLabel = label);
      }
    },
    onHoverExit: () {
      if (_hoveredLabel == label) {
        setState(() => _hoveredLabel = null);
      }
    },
    onTap: onTap,
  );

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final screen = MediaQuery.sizeOf(context);
    final safe = MediaQuery.viewPaddingOf(context);
    final totalSafeHeight = math.max(
      140.0,
      screen.height - safe.vertical - 24.0,
    );

    var effectiveDownward = widget.openDownward;
    var maxMenuH = totalSafeHeight;
    final rect = widget.anchorRect;
    if (rect != null) {
      final spaceAbove = rect.top - safe.top - 16.0;
      final spaceBelow = screen.height - safe.bottom - rect.bottom - 16.0;
      final preferredSpace = effectiveDownward ? spaceBelow : spaceAbove;
      final oppositeSpace = effectiveDownward ? spaceAbove : spaceBelow;
      if (preferredSpace < 240.0 && oppositeSpace > preferredSpace + 24.0) {
        effectiveDownward = !effectiveDownward;
      }
      final chosenSpace = effectiveDownward ? spaceBelow : spaceAbove;
      maxMenuH = math.min(totalSafeHeight, math.max(120.0, chosenSpace));
    }

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: widget.onDismiss,
          ),
        ),
        CompositedTransformFollower(
          link: widget.link,
          targetAnchor: effectiveDownward
              ? Alignment.bottomRight
              : Alignment.topRight,
          followerAnchor: effectiveDownward
              ? Alignment.topRight
              : Alignment.bottomRight,
          offset: Offset(0, effectiveDownward ? 8 : -8),
          child: Material(
            color: Colors.transparent,
            child: ClipRRect(
              borderRadius: KonataTheme.borderRadiusSheet,
              child: BackdropFilter(
                filter: KonataTheme.blurFilterCapsule,
                child: Container(
                  key: const ValueKey('detail_gear_menu_container'),
                  width: 218,
                  constraints: BoxConstraints(maxHeight: maxMenuH),
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  decoration: BoxDecoration(
                    color: KonataPlaybackTokens.popoverSurface(p),
                    borderRadius: KonataTheme.borderRadiusSheet,
                    border: Border.all(
                      color: KonataPlaybackTokens.glassBorder(p),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: KonataPlaybackTokens.shadowColor(p),
                        blurRadius: 24,
                        offset: const Offset(0, 10),
                      ),
                    ],
                  ),
                  child: MouseRegion(
                    onExit: (_) {
                      if (_hoveredLabel != null) {
                        setState(() => _hoveredLabel = null);
                      }
                    },
                    child: KonataDraggableScrollbar(
                      controller: _scrollCtrl,
                      builder: (_, ctrl) => SingleChildScrollView(
                        controller: ctrl,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _buildRow(
                              icon: Icons.manage_search_rounded,
                              label: '绑定元数据',
                              onTap: () => widget.onSelect(widget.onManualMatch),
                            ),
                            _buildRow(
                              icon: Icons.edit_note_rounded,
                              label: '手动编辑',
                              onTap: () => widget.onSelect(widget.onManualEdit),
                            ),
                            _buildRow(
                              icon: Icons.image_outlined,
                              label: '编辑封面',
                              onTap: () => widget.onSelect(widget.onEditPoster),
                            ),
                            _buildRow(
                              icon: Icons.wallpaper_rounded,
                              label: '编辑背景图',
                              onTap: () => widget.onSelect(widget.onEditBackdrop),
                            ),
                            if (widget.onEditLogo != null)
                              _buildRow(
                                icon: Icons.title_rounded,
                                label: '编辑标题徽标',
                                onTap: () => widget.onSelect(widget.onEditLogo!),
                              ),
                            _buildRow(
                              icon: Icons.layers_rounded,
                              label: '管理系列编组',
                              onTap: () {
                                final fn = widget.onManageSeries;
                                if (fn != null) {
                                  widget.onSelect(fn);
                                } else {
                                  widget.onDismiss();
                                }
                              },
                            ),
                            if (widget.onMergeWork != null)
                              _buildRow(
                                icon: Icons.merge_type_rounded,
                                label: '合并整部作品至其他条目...',
                                onTap: () =>
                                    widget.onSelect(widget.onMergeWork!),
                              ),
                            _buildRow(
                              icon: Icons.visibility_off_outlined,
                              label: '隐藏作品',
                              onTap: () => widget.onSelect(widget.onHideWork),
                            ),
                            _buildRow(
                              icon: Icons.delete_outline_rounded,
                              label: '删除作品',
                              isDanger: true,
                              onTap: () => widget.onSelect(widget.onDeleteWork),
                            ),
                            Divider(height: 10, color: p.hairline),
                            _buildRow(
                              icon: Icons.refresh_rounded,
                              label: '重新抓取 TMDB 数据',
                              onTap: () => widget.onSelect(widget.onRescrape),
                            ),
                            if (widget.onSyncBangumi != null)
                              _buildRow(
                                icon: Icons.sync_rounded,
                                label: '同步 Bangumi 观看进度',
                                onTap: () =>
                                    widget.onSelect(widget.onSyncBangumi!),
                              ),
                            if (KonataAdaptiveTokens.isWindows)
                              _buildRow(
                                icon: Icons.folder_open_rounded,
                                label: '打开本地所在文件夹',
                                onTap: () =>
                                    widget.onSelect(widget.onOpenLocalDir),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _MenuRow extends StatelessWidget {
  const _MenuRow({
    required this.icon,
    required this.label,
    required this.hovered,
    required this.onHoverEnter,
    required this.onHoverExit,
    required this.onTap,
    this.isDanger = false,
  });

  final IconData icon;
  final String label;
  final bool hovered;
  final VoidCallback onHoverEnter;
  final VoidCallback onHoverExit;
  final VoidCallback onTap;
  final bool isDanger;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final fg = isDanger ? p.danger : p.textPrimary;
    return KonataPopoverOptionTile(
      hovered: hovered,
      onHoverEnter: onHoverEnter,
      onHoverExit: onHoverExit,
      onTap: onTap,
      margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      child: Row(
        children: [
          Icon(icon, size: 17, color: fg),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: fg,
                fontSize: KonataTheme.fontSizeBodySm,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 底部右侧磨砂胶囊中的紧凑圆形操作按钮（`<`/`>`、展开收起与齿轮）。
class DetailDrawerHeaderButton extends StatelessWidget {
  /// 创建控制胶囊操作按钮。
  const DetailDrawerHeaderButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.enabled = true,
    this.active = false,
  });

  /// 图标。
  final IconData icon;

  /// 悬停提示文案。
  final String tooltip;

  /// 点击回调。
  final VoidCallback onPressed;

  /// 是否允许交互。
  final bool enabled;

  /// 是否处于激活高亮态。
  final bool active;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final hitSize = KonataAdaptiveTokens.isAndroid
        ? KonataAdaptiveTokens.touchTarget
        : 30.0;
    final circleSize = KonataAdaptiveTokens.isAndroid ? 34.0 : 30.0;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: KonataTheme.borderRadiusPill,
        onTap: enabled ? onPressed : null,
        child: SizedBox(
          width: hitSize,
          height: hitSize,
          child: Center(
            child: AnimatedContainer(
              duration: KonataTheme.motionFast,
              width: circleSize,
              height: circleSize,
              decoration: BoxDecoration(
                color: active
                    ? KonataPlaybackTokens.activePillBg(p)
                    : Colors.transparent,
                shape: BoxShape.circle,
              ),
              child: Icon(
                icon,
                size: 18,
                color: !enabled
                    ? p.textMuted
                    : active
                    ? p.textPrimary
                    : p.textSecondary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 底部毛玻璃胶囊栏中的正片 / 特典切换标签芯片（极简纯文字样式）。
class DetailDrawerTabChip extends StatefulWidget {
  /// 创建选集分类切换胶囊芯片。
  const DetailDrawerTabChip({
    super.key,
    required this.label,
    required this.active,
    required this.onTap,
    this.compact = false,
  });

  /// 标签文本（如 `正片 (24)`）。
  final String label;

  /// 当前是否处于激活选中态。
  final bool active;

  /// 点击切换回调。
  final VoidCallback onTap;

  /// 是否使用紧凑内边距。
  final bool compact;

  @override
  State<DetailDrawerTabChip> createState() => _DetailDrawerTabChipState();
}

class _DetailDrawerTabChipState extends State<DetailDrawerTabChip> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final Color bgColor;
    final Color borderColor;
    final Color textColor;

    if (widget.active) {
      bgColor = p.isDark
          ? KonataPlaybackTokens.activePillBg(p)
          : p.primaryButtonBg;
      borderColor = KonataTheme.activeControlBorder(p);
      textColor = p.isDark ? KonataTheme.pureWhite : p.primaryButtonFg;
    } else if (_hovered) {
      bgColor = KonataTheme.subtleControlFill(p);
      borderColor = Colors.transparent;
      textColor = p.textPrimary;
    } else {
      bgColor = Colors.transparent;
      borderColor = Colors.transparent;
      textColor = p.isDark ? p.textSecondary : p.textPrimary;
    }

    final effectiveCompact =
        widget.compact ||
        (KonataAdaptiveTokens.isAndroid &&
            MediaQuery.sizeOf(context).shortestSide <
                KonataAdaptiveTokens.tabletBreakpoint);
    final visualPill = AnimatedContainer(
      duration: KonataTheme.motionFast,
      curve: Curves.easeOutCubic,
      padding: EdgeInsets.symmetric(
        horizontal: effectiveCompact ? 10 : 14,
        vertical: effectiveCompact ? 5.5 : 7,
      ),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: KonataTheme.borderRadiusPill,
        border: Border.all(color: borderColor, width: 1),
      ),
      child: Text(
        widget.label,
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: textColor,
          fontSize: effectiveCompact ? 11.5 : 12.5,
          fontWeight: widget.active ? FontWeight.w600 : FontWeight.w500,
          fontFeatures: KonataPlaybackTokens.tabularNumbers,
          height: 1.15,
        ),
      ),
    );

    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.15,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: KonataAdaptiveTokens.isAndroid
              ? ConstrainedBox(
                  constraints: const BoxConstraints(
                    minWidth: KonataAdaptiveTokens.touchTarget,
                    minHeight: 36,
                  ),
                  child: Center(
                    widthFactor: 1.0,
                    heightFactor: 1.0,
                    child: visualPill,
                  ),
                )
              : visualPill,
        ),
      ),
    );
  }
}
