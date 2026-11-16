import 'package:flutter/material.dart';

import '../../theme/konata_palette.dart';

/// 胶囊按钮视觉变体。
enum KonataPillVariant {
  /// 高对比度主操作按钮（暗色纯白底黑字 / 亮色深墨黑底白字）。
  primary,

  /// 无边框半透明柔和融合次级按钮。
  secondary,

  /// 无底色纯文字轻量按钮。
  ghost,
}

/// 全站统一全圆角胶囊按钮。
class KonataPillButton extends StatefulWidget {
  /// 创建主操作高对比胶囊按钮。
  const KonataPillButton.primary({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.trailing,
    this.compact = false,
    this.padding,
  }) : variant = KonataPillVariant.primary;

  /// 创建次级无边框柔和融合胶囊按钮。
  const KonataPillButton.secondary({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.trailing,
    this.compact = false,
    this.padding,
  }) : variant = KonataPillVariant.secondary;

  /// 创建无底色文字胶囊按钮。
  const KonataPillButton.ghost({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.trailing,
    this.compact = false,
    this.padding,
  }) : variant = KonataPillVariant.ghost;

  /// 按钮文案。
  final String label;

  /// 可选前置图标。
  final IconData? icon;

  /// 可选尾部自定义控件（如动态旋转箭头）。
  final Widget? trailing;

  /// 点击回调（为 `null` 时进入禁用态）。
  final VoidCallback? onPressed;

  /// 按钮样式变体。
  final KonataPillVariant variant;

  /// 是否使用紧凑内边距。
  final bool compact;

  /// 可选自定义内边距（覆盖默认宽松/紧凑内边距）。
  final EdgeInsetsGeometry? padding;

  @override
  State<KonataPillButton> createState() => _KonataPillButtonState();
}

class _KonataPillButtonState extends State<KonataPillButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final enabled = widget.onPressed != null;

    final Color bgColor;
    final Color fgColor;
    switch (widget.variant) {
      case KonataPillVariant.primary:
        bgColor = _hovered && enabled ? p.primaryButtonHoverBg : p.primaryButtonBg;
        fgColor = p.primaryButtonFg;
      case KonataPillVariant.secondary:
        bgColor = _hovered && enabled
            ? p.secondaryButtonHoverBg
            : p.secondaryButtonBg;
        fgColor = p.textPrimary;
      case KonataPillVariant.ghost:
        bgColor = _hovered && enabled
            ? p.secondaryButtonBg
            : Colors.transparent;
        fgColor = _hovered && enabled ? p.textPrimary : p.textSecondary;
    }

    final padding = widget.padding ??
        (widget.compact
            ? const EdgeInsets.symmetric(horizontal: 13, vertical: 7)
            : const EdgeInsets.symmetric(horizontal: 18, vertical: 10));

    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onPressed,
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 140),
          opacity: enabled ? 1.0 : 0.45,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            curve: Curves.easeOutCubic,
            padding: padding,
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                if (widget.icon != null) ...[
                  Icon(
                    widget.icon,
                    size: widget.compact ? 15 : 17,
                    color: fgColor,
                  ),
                  const SizedBox(width: 6),
                ],
                Text(
                  widget.label,
                  style: TextStyle(
                    color: fgColor,
                    fontSize: widget.compact ? 12.5 : 13.5,
                    fontWeight: widget.variant == KonataPillVariant.primary
                        ? FontWeight.w600
                        : FontWeight.w500,
                  ),
                ),
                if (widget.trailing != null) ...[
                  const SizedBox(width: 2),
                  widget.trailing!,
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
