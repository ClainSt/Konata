import 'package:flutter/material.dart';

import '../../theme/konata_palette.dart';

final ValueNotifier<Object?> _activeHoveredTileToken = ValueNotifier<Object?>(
  null,
);

/// 全站统一圆角 `12px` 半透明微光卡片容器，直接透出底层系统 DWM 光影。
class KonataSurfaceCard extends StatefulWidget {
  /// 创建微光描边卡片容器。
  const KonataSurfaceCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(18),
    this.radius = 12,
    this.enableHover = false,
    this.backgroundColor,
    this.borderColor,
  });

  /// 子组件。
  final Widget child;

  /// 内边距。
  final EdgeInsetsGeometry padding;

  /// 圆角半径（默认 12px）。
  final double radius;

  /// 是否在鼠标悬停时平滑提亮半透明表面。
  final bool enableHover;

  /// 可选自定义表面背景色（用于选中高亮态等覆盖）。
  final Color? backgroundColor;

  /// 可选自定义 1px 边框色（用于选中高亮态等覆盖）。
  final Color? borderColor;

  @override
  State<KonataSurfaceCard> createState() => _KonataSurfaceCardState();
}

class _KonataSurfaceCardState extends State<KonataSurfaceCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final box = AnimatedContainer(
      duration: const Duration(milliseconds: 110),
      padding: widget.padding,
      decoration: BoxDecoration(
        color:
            widget.backgroundColor ??
            (widget.enableHover && _hovered ? p.surfaceHover : p.surface),
        borderRadius: BorderRadius.circular(widget.radius),
        border: Border.all(
          color:
              widget.borderColor ??
              (widget.enableHover && _hovered ? p.hoverBorder : p.hairline),
          width: 1,
        ),
      ),
      child: widget.child,
    );

    if (!widget.enableHover) {
      return box;
    }
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: box,
    );
  }
}

/// 统一列表行组件，用于设置项卡片行、外部链接卡片与日志导出行。
class KonataListTile extends StatefulWidget {
  /// 创建列表行组件。
  const KonataListTile({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.onTap,
  });

  /// 主标题。
  final String title;

  /// 可选副标题。
  final String? subtitle;

  /// 可选左侧图标或徽标。
  final Widget? leading;

  /// 可选右侧控件（如 Switch 或箭头图标）。
  final Widget? trailing;

  /// 点击整行回调。
  final VoidCallback? onTap;

  @override
  State<KonataListTile> createState() => _KonataListTileState();
}

class _KonataListTileState extends State<KonataListTile> {
  final Object _token = Object();

  @override
  void dispose() {
    if (identical(_activeHoveredTileToken.value, _token)) {
      _activeHoveredTileToken.value = null;
    }
    super.dispose();
  }

  void _setHovered(bool hovered) {
    if (widget.onTap == null) {
      if (identical(_activeHoveredTileToken.value, _token)) {
        _activeHoveredTileToken.value = null;
      }
      return;
    }
    if (hovered) {
      if (!identical(_activeHoveredTileToken.value, _token)) {
        _activeHoveredTileToken.value = _token;
      }
    } else if (identical(_activeHoveredTileToken.value, _token)) {
      _activeHoveredTileToken.value = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final clickable = widget.onTap != null;
    final hoverFill = p.isDark
        ? Colors.white.withValues(alpha: 0.07)
        : Colors.black.withValues(alpha: 0.045);
    final idleFill = hoverFill.withValues(alpha: 0.0);

    return MouseRegion(
      cursor: clickable ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => _setHovered(true),
      onHover: (_) => _setHovered(true),
      onExit: (_) => _setHovered(false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: ValueListenableBuilder<Object?>(
          valueListenable: _activeHoveredTileToken,
          builder: (context, activeToken, child) {
            final isHovered = clickable && identical(activeToken, _token);
            return AnimatedContainer(
              duration: const Duration(milliseconds: 70),
              curve: Curves.easeOut,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                color: isHovered ? hoverFill : idleFill,
                borderRadius: BorderRadius.circular(12),
              ),
              child: child,
            );
          },
          child: Row(
            children: [
              if (widget.leading != null) ...[
                widget.leading!,
                const SizedBox(width: 14),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      widget.title,
                      style: TextStyle(
                        color: p.textPrimary,
                        fontSize: 14.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (widget.subtitle != null &&
                        widget.subtitle!.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        widget.subtitle!,
                        style: TextStyle(
                          color: p.textSecondary,
                          fontSize: 12.5,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (widget.trailing != null) ...[
                const SizedBox(width: 12),
                widget.trailing!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}
