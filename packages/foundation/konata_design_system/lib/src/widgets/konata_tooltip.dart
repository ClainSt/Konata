import 'package:material_ui/material_ui.dart';

/// 统一悬停提示，兼容 Navigator 外部的小窗、通知和窗口浮层。
class KonataTooltip extends StatelessWidget {
  const KonataTooltip({
    super.key,
    required this.message,
    required this.child,
    this.waitDuration,
    this.triggerMode,
    this.padding,
    this.constraints,
    this.textStyle,
    this.decoration,
    this.excludeFromSemantics = false,
  });

  final String message;
  final Widget child;
  final Duration? waitDuration;
  final TooltipTriggerMode? triggerMode;
  final EdgeInsetsGeometry? padding;
  final BoxConstraints? constraints;
  final TextStyle? textStyle;
  final Decoration? decoration;
  final bool excludeFromSemantics;

  @override
  Widget build(BuildContext context) {
    if (Overlay.maybeOf(context) == null) {
      return excludeFromSemantics
          ? child
          : Semantics(label: message, child: child);
    }
    return Tooltip(
      message: message,
      waitDuration: waitDuration,
      triggerMode: triggerMode,
      padding: padding,
      constraints: constraints,
      textStyle: textStyle,
      decoration: decoration,
      excludeFromSemantics: excludeFromSemantics,
      child: child,
    );
  }
}
