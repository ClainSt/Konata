import 'package:material_ui/material_ui.dart';

import '../tokens/konata_palette.dart';
import '../tokens/konata_theme.dart';
import 'konata_tooltip.dart';

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
    this.waitDuration = KonataTheme.tooltipWaitDuration,
    this.maxWidth,
    this.textScaler,
    this.deferTooltipToHover = false,
    this.suppressHoverCheck,
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

  /// 可选已知可用宽度（网格等外层已算定列宽的场景传入后直接跳过 `LayoutBuilder`）。
  final double? maxWidth;

  /// 可选预读取的文本缩放器（网格列表透传后避免每张卡片重复订阅 `MediaQuery`）。
  final TextScaler? textScaler;

  /// 是否将 `Tooltip` 节点延迟到指针实际悬停时再挂载（高速滚动大列表可省去数百个 Overlay/Ticker 分配）。
  final bool deferTooltipToHover;

  /// 可选滚动期悬停抑制回调，仅在 [deferTooltipToHover] 开启时生效。
  final bool Function()? suppressHoverCheck;

  /// 保守快判是否必定不截断或必定截断，仅在边界区间才回退 `TextPainter.layout()`，
  /// 避免高速滚动海量卡片时对每条标题重复执行双次 HarfBuzz 排版。
  bool _detectOverflow({
    required BuildContext context,
    required TextStyle effectiveStyle,
    required double boundedWidth,
  }) {
    if (text.isEmpty || !boundedWidth.isFinite || boundedWidth <= 0) {
      return false;
    }
    final scaler = textScaler ?? MediaQuery.textScalerOf(context);
    final baseFontSize = effectiveStyle.fontSize ?? 14.0;
    final scaledFontSize = scaler.scale(baseFontSize);
    final letterSpacing = effectiveStyle.letterSpacing ?? 0.0;
    final lineBudget = boundedWidth * maxLines;

    if (maxLines == 1 && !text.contains('\n')) {
      var upperBound = 0.0;
      var lowerBound = 0.0;
      for (var i = 0; i < text.length; i++) {
        final unit = text.codeUnitAt(i);
        final isWide = unit >= 0x2E80;
        upperBound += (isWide ? 1.08 : 0.78) * scaledFontSize + letterSpacing;
        lowerBound += (isWide ? 0.88 : 0.36) * scaledFontSize + letterSpacing;
      }
      if (upperBound < boundedWidth * 0.90) {
        return false;
      }
      if (lowerBound > boundedWidth * 1.12) {
        return true;
      }
    } else if (text.length * scaledFontSize * 1.08 < lineBudget * 0.72 &&
        !text.contains('\n')) {
      return false;
    }

    final painter = TextPainter(
      text: TextSpan(text: text, style: effectiveStyle),
      maxLines: maxLines,
      textAlign: textAlign,
      textDirection: Directionality.maybeOf(context) ?? TextDirection.ltr,
      textScaler: scaler,
      locale: Localizations.maybeLocaleOf(context),
      strutStyle: strutStyle,
    )..layout(maxWidth: boundedWidth);
    final exceeded = painter.didExceedMaxLines;
    painter.dispose();
    return exceeded;
  }

  Widget _buildStyledTooltip(BuildContext context, Widget child) {
    final p = context.palette;
    return KonataTooltip(
      message: tooltipMessage ?? text,
      waitDuration: waitDuration,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      constraints: const BoxConstraints(maxWidth: 420),
      textStyle: TextStyle(
        color: KonataTheme.tooltipTextColor(p),
        fontSize: KonataTheme.fontSizeCaption,
        fontWeight: FontWeight.w500,
        height: 1.35,
      ),
      decoration: BoxDecoration(
        color: KonataTheme.tooltipSurface(p),
        borderRadius: KonataTheme.borderRadiusSm,
        border: Border.all(color: KonataTheme.tooltipBorder(p), width: 1),
        boxShadow: [
          BoxShadow(
            color: KonataTheme.tooltipShadow(p),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: child,
    );
  }

  Widget _wrapWithTooltipIfNeeded(
    BuildContext context,
    TextStyle effectiveStyle,
    Widget textWidget,
    double boundedWidth,
  ) {
    if (!_detectOverflow(
      context: context,
      effectiveStyle: effectiveStyle,
      boundedWidth: boundedWidth,
    )) {
      return textWidget;
    }
    if (deferTooltipToHover) {
      return _DeferredHoverTooltip(
        tooltipBuilder: (ctx, child) => _buildStyledTooltip(ctx, child),
        suppressHoverCheck: suppressHoverCheck,
        child: textWidget,
      );
    }
    return _buildStyledTooltip(context, textWidget);
  }

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

    if (text.isEmpty) {
      return textWidget;
    }
    final knownWidth = maxWidth;
    if (knownWidth != null && knownWidth.isFinite && knownWidth > 0) {
      return _wrapWithTooltipIfNeeded(
        context,
        effectiveStyle,
        textWidget,
        knownWidth,
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        if (!constraints.hasBoundedWidth) {
          return textWidget;
        }
        return _wrapWithTooltipIfNeeded(
          context,
          effectiveStyle,
          textWidget,
          constraints.maxWidth,
        );
      },
    );
  }
}

/// 仅在桌面鼠标静止悬停到截断标题上时再惰性挂载 `Tooltip`，避免列表高速滚动期批量创建浮层控制器。
class _DeferredHoverTooltip extends StatefulWidget {
  const _DeferredHoverTooltip({
    required this.tooltipBuilder,
    required this.child,
    this.suppressHoverCheck,
  });

  final Widget Function(BuildContext context, Widget child) tooltipBuilder;
  final Widget child;
  final bool Function()? suppressHoverCheck;

  @override
  State<_DeferredHoverTooltip> createState() => _DeferredHoverTooltipState();
}

class _DeferredHoverTooltipState extends State<_DeferredHoverTooltip> {
  bool _armed = false;

  void _armTooltip() {
    if (_armed || (widget.suppressHoverCheck?.call() ?? false)) return;
    setState(() => _armed = true);
  }

  @override
  Widget build(BuildContext context) {
    if (_armed) {
      return widget.tooltipBuilder(context, widget.child);
    }
    return MouseRegion(
      opaque: false,
      onEnter: (_) => _armTooltip(),
      onHover: (_) => _armTooltip(),
      child: widget.child,
    );
  }
}
