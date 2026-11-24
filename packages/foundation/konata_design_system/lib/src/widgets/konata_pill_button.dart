import 'package:material_ui/material_ui.dart';
import '../tokens/konata_adaptive_tokens.dart';

import '../tokens/konata_palette.dart';
import '../tokens/konata_theme.dart';

/// 胶囊按钮视觉变体。
enum KonataPillVariant {
  /// 高对比度主操作按钮（暗色纯白底黑字 / 亮色深墨黑底白字）。
  primary,

  /// 无边框半透明柔和融合次级按钮。
  secondary,

  /// 无底色纯文字轻量按钮。
  ghost,

  /// 告警/危险操作语义胶囊按钮（二次确认清理/删除）。
  danger,
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
    this.height,
    this.borderColor,
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
    this.height,
    this.borderColor,
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
    this.height,
    this.borderColor,
  }) : variant = KonataPillVariant.ghost;

  /// 创建告警危险语义胶囊按钮。
  const KonataPillButton.danger({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.trailing,
    this.compact = false,
    this.padding,
    this.height,
    this.borderColor,
  }) : variant = KonataPillVariant.danger;

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

  /// 可选固定高度（用于与同排输入框严格等高居中对齐）。
  final double? height;

  /// 可选显式描边色。
  final Color? borderColor;

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
    Color? borderColor;
    switch (widget.variant) {
      case KonataPillVariant.primary:
        bgColor = _hovered && enabled
            ? p.primaryButtonHoverBg
            : p.primaryButtonBg;
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
      case KonataPillVariant.danger:
        bgColor = _hovered && enabled
            ? Color.lerp(p.dangerBadge.bg, p.danger, 0.16)!
            : p.dangerBadge.bg;
        fgColor = p.dangerBadge.fg;
        borderColor = widget.borderColor ?? p.dangerBadge.border;
    }
    if (widget.variant != KonataPillVariant.danger &&
        widget.borderColor != null) {
      borderColor = widget.borderColor;
    }

    final padding =
        widget.padding ??
        (widget.height != null
            ? EdgeInsets.symmetric(horizontal: widget.compact ? 14 : 18)
            : (widget.compact
                  ? const EdgeInsets.symmetric(horizontal: 13, vertical: 7)
                  : const EdgeInsets.symmetric(horizontal: 18, vertical: 10)));

    Widget visualPill = AnimatedOpacity(
      duration: KonataTheme.motionFast,
      opacity: enabled ? 1.0 : 0.45,
      child: AnimatedContainer(
        duration: KonataTheme.motionFast,
        curve: Curves.easeOutCubic,
        height: widget.height,
        padding: padding,
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: KonataTheme.borderRadiusPill,
          border: borderColor == null
              ? null
              : Border.all(color: borderColor, width: 1),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
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
              maxLines: 1,
              softWrap: false,
              style: TextStyle(
                color: fgColor,
                fontSize: widget.compact ? 12.5 : 13.5,
                fontWeight:
                    (widget.variant == KonataPillVariant.primary ||
                        widget.variant == KonataPillVariant.danger)
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
    );

    if (KonataAdaptiveTokens.isAndroid) {
      // Android 仅在最外层扩展 48dp 透明触控热区，内层染色胶囊严格保留 Windows 同源修长比例。
      visualPill = ConstrainedBox(
        constraints: const BoxConstraints(
          minHeight: KonataAdaptiveTokens.touchTarget,
          minWidth: KonataAdaptiveTokens.touchTarget,
        ),
        child: Center(widthFactor: 1, heightFactor: 1, child: visualPill),
      );
    }

    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.15,
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onPressed,
          child: visualPill,
        ),
      ),
    );
  }
}

/// 源文件名 / 目录提取词的一键快捷填入胶囊栏（供手动匹配与混合匹配工作台共用）。
class KonataQuickFillRow extends StatelessWidget {
  /// 创建一键快捷填入胶囊栏。
  const KonataQuickFillRow({
    super.key,
    required this.terms,
    required this.onPick,
    this.disabled = false,
  });

  /// 提取出的清洗关键词列表；为空时不渲染任何内容。
  final List<String> terms;

  /// 点击任意胶囊时的回调（传入对应关键词）。
  final ValueChanged<String> onPick;

  /// 是否禁用交互。
  final bool disabled;

  @override
  Widget build(BuildContext context) {
    if (terms.isEmpty) return const SizedBox.shrink();
    final p = context.palette;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text('快捷填入：', style: TextStyle(color: p.textMuted, fontSize: KonataTheme.fontSizeCaptionSm)),
          for (final term in terms)
            KonataPillButton.secondary(
              label: term,
              compact: true,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              onPressed: disabled ? null : () => onPick(term),
            ),
        ],
      ),
    );
  }
}
