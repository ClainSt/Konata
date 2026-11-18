import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';

import '../theme/konata_adaptive_tokens.dart';
import '../theme/konata_palette.dart';
import '../theme/konata_playback_tokens.dart';

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
    required this.onHideWork,
    required this.onDeleteWork,
    required this.onRescrape,
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
  final VoidCallback onHideWork;
  final VoidCallback onDeleteWork;
  final VoidCallback onRescrape;
  final VoidCallback onOpenLocalDir;
  final VoidCallback? onManageSeries;
  final VoidCallback? onMergeWork;

  @override
  State<DetailOpsCapsule> createState() => _DetailOpsCapsuleState();
}

class _DetailOpsCapsuleState extends State<DetailOpsCapsule> {
  final LayerLink _gearLink = LayerLink();
  OverlayEntry? _gearMenuEntry;

  @override
  void dispose() {
    _closeMenu();
    super.dispose();
  }

  void _closeMenu() {
    _gearMenuEntry?.remove();
    _gearMenuEntry = null;
  }

  void _toggleMenu() {
    if (_gearMenuEntry != null) {
      _closeMenu();
      setState(() {});
      return;
    }
    final overlay = Overlay.of(context, rootOverlay: true);
    _gearMenuEntry = OverlayEntry(
      builder: (_) => DetailGearMenuOverlay(
        link: _gearLink,
        openDownward: widget.openDownward,
        onDismiss: () {
          _closeMenu();
          if (mounted) setState(() {});
        },
        onSelect: (action) {
          _closeMenu();
          if (mounted) setState(() {});
          action();
        },
        onManualMatch: widget.onManualMatch,
        onManualEdit: widget.onManualEdit,
        onEditPoster: widget.onEditPoster,
        onEditBackdrop: widget.onEditBackdrop,
        onHideWork: widget.onHideWork,
        onDeleteWork: widget.onDeleteWork,
        onRescrape: widget.onRescrape,
        onOpenLocalDir: widget.onOpenLocalDir,
        onManageSeries: widget.onManageSeries,
        onMergeWork: widget.onMergeWork,
      ),
    );
    overlay.insert(_gearMenuEntry!);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final compactPad = KonataAdaptiveTokens.isAndroid;
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
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
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: KonataPlaybackTokens.glassBorder(p),
              width: 1,
            ),
          ),
          child: AnimatedSize(
            duration: const Duration(milliseconds: 200),
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
                  link: _gearLink,
                  child: DetailDrawerHeaderButton(
                    icon: Icons.settings_rounded,
                    tooltip: '作品管理选项',
                    active: _gearMenuEntry != null,
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

/// 详情页底部齿轮向上或右上角齿轮向下弹出的高透毛玻璃作品管理菜单。
class DetailGearMenuOverlay extends StatelessWidget {
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
    required this.onHideWork,
    required this.onDeleteWork,
    required this.onRescrape,
    required this.onOpenLocalDir,
    this.onManageSeries,
    this.onMergeWork,
    this.openDownward = false,
  });

  /// 锚定在齿轮图标上的坐标连接器。
  final LayerLink link;

  /// 点击空白处关闭回调。
  final VoidCallback onDismiss;

  /// 执行某项并关闭菜单的包裹器。
  final ValueChanged<VoidCallback> onSelect;

  /// 6 个管理动作 + 管理系列 + 刷新元数据 + 打开本地目录回调。
  final VoidCallback onManualMatch;
  final VoidCallback onManualEdit;
  final VoidCallback onEditPoster;
  final VoidCallback onEditBackdrop;
  final VoidCallback onHideWork;
  final VoidCallback onDeleteWork;
  final VoidCallback onRescrape;
  final VoidCallback onOpenLocalDir;
  final VoidCallback? onManageSeries;
  final VoidCallback? onMergeWork;

  /// 是否向下展开（Android 手机右上角齿轮置顶时需向下弹出避免裁切）。
  final bool openDownward;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final maxMenuH = math.max(
      180.0,
      MediaQuery.sizeOf(context).height - MediaQuery.paddingOf(context).vertical - 88.0,
    );
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: onDismiss,
          ),
        ),
        CompositedTransformFollower(
          link: link,
          targetAnchor: openDownward
              ? Alignment.bottomRight
              : Alignment.topRight,
          followerAnchor: openDownward
              ? Alignment.topRight
              : Alignment.bottomRight,
          offset: Offset(0, openDownward ? 8 : -12),
          child: Material(
            color: Colors.transparent,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 28, sigmaY: 28),
                child: Container(
                  width: 218,
                  constraints: BoxConstraints(maxHeight: maxMenuH),
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  decoration: BoxDecoration(
                    color: KonataPlaybackTokens.popoverSurface(p),
                    borderRadius: BorderRadius.circular(16),
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
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _MenuRow(
                          icon: Icons.manage_search_rounded,
                          label: '绑定元数据',
                          onTap: () => onSelect(onManualMatch),
                        ),
                        _MenuRow(
                          icon: Icons.edit_note_rounded,
                          label: '手动编辑',
                          onTap: () => onSelect(onManualEdit),
                        ),
                        _MenuRow(
                          icon: Icons.image_outlined,
                          label: '编辑封面',
                          onTap: () => onSelect(onEditPoster),
                        ),
                        _MenuRow(
                          icon: Icons.wallpaper_rounded,
                          label: '编辑背景图',
                          onTap: () => onSelect(onEditBackdrop),
                        ),
                        _MenuRow(
                          icon: Icons.layers_rounded,
                          label: '管理系列编组',
                          onTap: () {
                            final fn = onManageSeries;
                            if (fn != null) {
                              onSelect(fn);
                            } else {
                              onDismiss();
                            }
                          },
                        ),
                        if (onMergeWork != null)
                          _MenuRow(
                            icon: Icons.merge_type_rounded,
                            label: '合并整部作品至其他条目...',
                            onTap: () => onSelect(onMergeWork!),
                          ),
                        _MenuRow(
                          icon: Icons.visibility_off_outlined,
                          label: '隐藏作品',
                          onTap: () => onSelect(onHideWork),
                        ),
                        _MenuRow(
                          icon: Icons.delete_outline_rounded,
                          label: '删除作品',
                          isDanger: true,
                          onTap: () => onSelect(onDeleteWork),
                        ),
                        Divider(height: 10, color: p.hairline),
                        _MenuRow(
                          icon: Icons.refresh_rounded,
                          label: '重新抓取 TMDB 数据',
                          onTap: () => onSelect(onRescrape),
                        ),
                        if (KonataAdaptiveTokens.isWindows)
                          _MenuRow(
                            icon: Icons.folder_open_rounded,
                            label: '打开本地所在文件夹',
                            onTap: () => onSelect(onOpenLocalDir),
                          ),
                      ],
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
    required this.onTap,
    this.isDanger = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool isDanger;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final fg = isDanger ? p.danger : p.textPrimary;
    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: KonataAdaptiveTokens.isAndroid
            ? const BoxConstraints(minHeight: KonataAdaptiveTokens.touchTarget)
            : const BoxConstraints(),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          child: Row(
            children: [
              Icon(icon, size: 17, color: fg),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    color: fg,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        ),
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
        borderRadius: BorderRadius.circular(999),
        onTap: enabled ? onPressed : null,
        child: SizedBox(
          width: hitSize,
          height: hitSize,
          child: Center(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 140),
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
      borderColor = p.isDark ? const Color(0x42FFFFFF) : p.primaryButtonBg;
      textColor = p.isDark ? Colors.white : p.primaryButtonFg;
    } else if (_hovered) {
      bgColor = p.isDark ? const Color(0x1FFFFFFF) : const Color(0x140F172A);
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
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeOutCubic,
      padding: EdgeInsets.symmetric(
        horizontal: effectiveCompact ? 10 : 14,
        vertical: effectiveCompact ? 5.5 : 7,
      ),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(999),
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
