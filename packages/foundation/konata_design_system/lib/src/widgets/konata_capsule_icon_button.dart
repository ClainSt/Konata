import 'package:material_ui/material_ui.dart';

import '../tokens/konata_adaptive_tokens.dart';
import '../tokens/konata_palette.dart';
import '../tokens/konata_theme.dart';
import 'konata_tooltip.dart';

/// 播控胶囊、导航胶囊与流光浮层共用的无边框纯图标按钮（零水波纹残留）。
class KonataCapsuleIconButton extends StatefulWidget {
  /// 创建无边框 OSD / 胶囊图标按钮。
  const KonataCapsuleIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.color,
    required this.onTap,
    this.onLongPress,
    this.size = 20,
    this.padding = const EdgeInsets.all(6),
    this.highlighted = false,
    this.highlightColor,
    this.highlightBgColor,
    this.showHighlightBorder = true,
    this.showHoverBackground = true,
    this.borderRadius = 999,
    this.fixedSize,
  });

  /// 图标字形。
  final IconData icon;

  /// 悬停与无障碍提示文案。
  final String tooltip;

  /// 常态图标颜色。
  final Color color;

  /// 点击回调（为空表示禁用态）。
  final VoidCallback? onTap;

  /// 可选长按回调。
  final VoidCallback? onLongPress;

  /// 图标绘制尺寸。
  final double size;

  /// 内边距。
  final EdgeInsetsGeometry padding;

  /// 是否处于激活高亮态。
  final bool highlighted;

  /// 可选高亮前景色。
  final Color? highlightColor;

  /// 可选高亮背景色。
  final Color? highlightBgColor;

  /// 高亮态是否显示 1px 微光边框。
  final bool showHighlightBorder;

  /// 悬停态是否显示柔光底衬。
  final bool showHoverBackground;

  /// 按钮圆角半径。
  final double borderRadius;

  /// 可选固定正方形热区尺寸（移动端通常为 `48.0` 或 `56.0`）。
  final double? fixedSize;

  @override
  State<KonataCapsuleIconButton> createState() =>
      _KonataCapsuleIconButtonState();
}

class _KonataCapsuleIconButtonState extends State<KonataCapsuleIconButton> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    final baseColor = widget.highlighted
        ? (widget.highlightColor ?? widget.color)
        : widget.color;
    final effectiveColor = !enabled
        ? baseColor.withValues(alpha: 0.34)
        : (_hovered || widget.highlighted
              ? baseColor
              : baseColor.withValues(alpha: 0.88));

    return KonataTooltip(
      message: widget.tooltip,
      waitDuration: KonataTheme.tooltipSlowWaitDuration,
      triggerMode: widget.onLongPress != null
          ? TooltipTriggerMode.manual
          : null,
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() {
          _hovered = false;
          _pressed = false;
        }),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
          onTapUp: enabled ? (_) => setState(() => _pressed = false) : null,
          onTapCancel: () => setState(() => _pressed = false),
          onTap: widget.onTap,
          onLongPress: widget.onLongPress,
          child: AnimatedScale(
            scale: _pressed ? 0.90 : 1.0,
            duration: KonataTheme.capsuleSlideDuration,
            child: AnimatedContainer(
              duration: KonataTheme.motionFast,
              width: widget.fixedSize,
              height: widget.fixedSize,
              padding: widget.padding,
              alignment: widget.fixedSize != null ? Alignment.center : null,
              decoration: BoxDecoration(
                color: widget.highlighted
                    ? (widget.highlightBgColor ??
                          baseColor.withValues(
                            alpha: _hovered && enabled ? 0.28 : 0.22,
                          ))
                    : ((_hovered && enabled && widget.showHoverBackground)
                          ? baseColor.withValues(alpha: 0.12)
                          : Colors.transparent),
                border: (widget.highlighted && widget.showHighlightBorder)
                    ? Border.all(
                        color: baseColor.withValues(alpha: 0.42),
                        width: 1,
                      )
                    : null,
                borderRadius: BorderRadius.circular(widget.borderRadius),
              ),
              child: Icon(
                widget.icon,
                size: widget.size,
                color: effectiveColor,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 音视频播控胶囊左翼共用的 `32×32`（触屏 `48×48`）纯图标循环模式切换按钮。
class KonataAudioLoopButton extends StatelessWidget {
  /// 创建纯图标循环模式切换按钮。
  const KonataAudioLoopButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.highlighted,
    required this.onTap,
  });

  /// 当前循环模式对应的纯图标。
  final IconData icon;

  /// 悬停提示文案。
  final String tooltip;

  /// 保留字段以兼容调用侧签名。
  final bool highlighted;

  /// 点击切换循环模式回调。
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final btnSize = KonataAdaptiveTokens.isAndroid
        ? KonataAdaptiveTokens.touchTarget
        : 32.0;
    return KonataCapsuleIconButton(
      icon: icon,
      tooltip: tooltip,
      color: p.textPrimary,
      size: 18,
      fixedSize: btnSize,
      padding: EdgeInsets.zero,
      highlighted: false,
      showHighlightBorder: false,
      onTap: onTap,
    );
  }
}
