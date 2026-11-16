import 'package:flutter/material.dart';

import '../../theme/konata_palette.dart';

/// 仅在单/多行文本真实发生省略截断时挂载全名悬停 Tooltip 的通用文本组件。
class EllipsisTextWithTooltip extends StatelessWidget {
  /// 创建自动检测截断的悬停提示文本组件。
  const EllipsisTextWithTooltip({
    super.key,
    required this.text,
    required this.style,
    this.maxLines = 1,
    this.textAlign = TextAlign.start,
    this.tooltipMessage,
    this.strutStyle,
    this.waitDuration = const Duration(milliseconds: 350),
  });

  /// 要展示的文本内容。
  final String text;

  /// 文本样式。
  final TextStyle style;

  /// 最大行数，超过后截断并触发 Tooltip。
  final int maxLines;

  /// 文本对齐方式。
  final TextAlign textAlign;

  /// 自定义 Tooltip 提示全文（默认与 [text] 一致）。
  final String? tooltipMessage;

  /// 可选行距基准样式。
  final StrutStyle? strutStyle;

  /// 悬停等待触发时长（默认 350ms）。
  final Duration waitDuration;

  @override
  Widget build(BuildContext context) {
    final effectiveStyle = DefaultTextStyle.of(context).style.merge(style);
    final textWidget = Text(
      text,
      maxLines: maxLines,
      overflow: TextOverflow.ellipsis,
      textAlign: textAlign,
      style: effectiveStyle,
      strutStyle: strutStyle,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        if (!constraints.hasBoundedWidth || text.isEmpty) {
          return textWidget;
        }
        final painter = TextPainter(
          text: TextSpan(text: text, style: effectiveStyle),
          maxLines: maxLines,
          textAlign: textAlign,
          textDirection: Directionality.maybeOf(context) ?? TextDirection.ltr,
          textScaler: MediaQuery.textScalerOf(context),
          locale: Localizations.maybeLocaleOf(context),
          strutStyle: strutStyle,
        )..layout(maxWidth: constraints.maxWidth);

        if (!painter.didExceedMaxLines) {
          return textWidget;
        }

        final p = context.palette;
        return Tooltip(
          message: tooltipMessage ?? text,
          waitDuration: waitDuration,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          constraints: const BoxConstraints(maxWidth: 420),
          textStyle: TextStyle(
            color: p.isDark
                ? Colors.white.withValues(alpha: 0.94)
                : p.textPrimary,
            fontSize: 12.2,
            fontWeight: FontWeight.w500,
            height: 1.35,
          ),
          decoration: BoxDecoration(
            color: p.isDark
                ? const Color(0xEC1B2029)
                : const Color(0xF6FFFFFF),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: p.isDark
                  ? Colors.white.withValues(alpha: 0.16)
                  : Colors.black.withValues(alpha: 0.10),
              width: 1,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: p.isDark ? 0.36 : 0.12),
                blurRadius: 16,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: textWidget,
        );
      },
    );
  }
}
