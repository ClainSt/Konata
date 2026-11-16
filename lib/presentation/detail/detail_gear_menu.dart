import 'dart:ui';

import 'package:flutter/material.dart';

import '../theme/konata_palette.dart';
import '../theme/konata_playback_tokens.dart';

/// 详情页底部齿轮向上弹出的高透毛玻璃作品管理菜单。
class DetailGearMenuOverlay extends StatelessWidget {
  /// 创建向上悬浮作品管理菜单。
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

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
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
          targetAnchor: Alignment.topRight,
          followerAnchor: Alignment.bottomRight,
          offset: const Offset(0, -12),
          child: Material(
            color: Colors.transparent,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 28, sigmaY: 28),
                child: Container(
                  width: 218,
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
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: enabled ? onPressed : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          width: 30,
          height: 30,
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

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOutCubic,
          padding: EdgeInsets.symmetric(
            horizontal: widget.compact ? 12 : 14,
            vertical: widget.compact ? 6 : 7,
          ),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: borderColor, width: 1),
          ),
          child: Text(
            widget.label,
            style: TextStyle(
              color: textColor,
              fontSize: 12.5,
              fontWeight: widget.active ? FontWeight.w600 : FontWeight.w500,
              fontFeatures: KonataPlaybackTokens.tabularNumbers,
              height: 1.15,
            ),
          ),
        ),
      ),
    );
  }
}
