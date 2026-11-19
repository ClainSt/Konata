import 'package:flutter/material.dart';

import '../theme/konata_palette.dart';
import '../theme/konata_theme.dart';

/// 详情页简介无感内联展开/收起组件（无独立边框、胶囊或高亮底色）。
class InlineExpandableSynopsis extends StatefulWidget {
  /// 创建无感内联展开/收起简介文本组件。
  const InlineExpandableSynopsis({
    super.key,
    required this.text,
    this.collapsedMaxLines = 3,
    this.maxExpandedHeight = 200,
    this.style,
  });

  /// 简介全文。
  final String text;

  /// 默认折叠行数。
  final int collapsedMaxLines;

  /// 展开后的最大可视高度，防止极长简介挤压下方播放按钮。
  final double maxExpandedHeight;

  /// 可选正文基础样式。
  final TextStyle? style;

  @override
  State<InlineExpandableSynopsis> createState() =>
      _InlineExpandableSynopsisState();
}

class _InlineExpandableSynopsisState extends State<InlineExpandableSynopsis> {
  static const String _expandSuffix = '… 展开';
  static const String _collapseSuffix = ' 收起';

  bool _expanded = false;
  bool _hovered = false;

  @override
  void didUpdateWidget(covariant InlineExpandableSynopsis oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) {
      _expanded = false;
    }
  }

  void _toggle() {
    setState(() => _expanded = !_expanded);
  }

  @override
  Widget build(BuildContext context) {
    final trimmed = widget.text.trim();
    if (trimmed.isEmpty) {
      return const SizedBox.shrink();
    }

    final p = context.palette;
    final bodyStyle = widget.style ??
        KonataTheme.detailTextStyle(
          fontSize: KonataTheme.fontSizeSubtitle,
          fontWeight: FontWeight.w500,
          height: 1.65,
          letterSpacing: 0.35,
          palette: p,
          color: p.isDark
              ? p.textPrimary.withValues(alpha: 0.92)
              : KonataTheme.detailPrimaryTextColor(p),
        );
    final toggleStyle = bodyStyle.copyWith(
      color: _hovered
          ? KonataTheme.detailPrimaryTextColor(p)
          : KonataTheme.detailSecondaryTextColor(p),
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        if (!constraints.hasBoundedWidth) {
          return Text(
            trimmed,
            maxLines: _expanded ? null : widget.collapsedMaxLines,
            overflow:
                _expanded ? TextOverflow.visible : TextOverflow.ellipsis,
            style: bodyStyle,
          );
        }

        final textDirection =
            Directionality.maybeOf(context) ?? TextDirection.ltr;
        final textScaler = MediaQuery.textScalerOf(context);
        final locale = Localizations.maybeLocaleOf(context);

        final fullPainter = TextPainter(
          text: TextSpan(text: trimmed, style: bodyStyle),
          maxLines: widget.collapsedMaxLines,
          textDirection: textDirection,
          textScaler: textScaler,
          locale: locale,
        )..layout(maxWidth: constraints.maxWidth);

        if (!fullPainter.didExceedMaxLines) {
          return Text(trimmed, style: bodyStyle);
        }

        final Widget content;
        if (_expanded) {
          content = ConstrainedBox(
            constraints: BoxConstraints(maxHeight: widget.maxExpandedHeight),
            child: ScrollConfiguration(
              behavior: ScrollConfiguration.of(context).copyWith(
                scrollbars: false,
              ),
              child: SingleChildScrollView(
                physics: const ClampingScrollPhysics(),
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(text: trimmed, style: bodyStyle),
                      TextSpan(text: _collapseSuffix, style: toggleStyle),
                    ],
                  ),
                ),
              ),
            ),
          );
        } else {
          final visiblePrefix = _computeTruncatedPrefix(
            text: trimmed,
            suffix: _expandSuffix,
            maxLines: widget.collapsedMaxLines,
            maxWidth: constraints.maxWidth,
            bodyStyle: bodyStyle,
            toggleStyle: toggleStyle,
            textDirection: textDirection,
            textScaler: textScaler,
            locale: locale,
          );
          content = Text.rich(
            TextSpan(
              children: [
                TextSpan(text: visiblePrefix, style: bodyStyle),
                TextSpan(text: _expandSuffix, style: toggleStyle),
              ],
            ),
            maxLines: widget.collapsedMaxLines,
          );
        }

        return MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _toggle,
            child: AnimatedSize(
              duration: KonataTheme.motionNormal,
              curve: Curves.easeOutCubic,
              alignment: Alignment.topLeft,
              child: content,
            ),
          ),
        );
      },
    );
  }

  static String _computeTruncatedPrefix({
    required String text,
    required String suffix,
    required int maxLines,
    required double maxWidth,
    required TextStyle bodyStyle,
    required TextStyle toggleStyle,
    required TextDirection textDirection,
    required TextScaler textScaler,
    required Locale? locale,
  }) {
    final runes = text.runes.toList(growable: false);
    if (runes.isEmpty) return '';

    final probe = TextPainter(
      maxLines: maxLines,
      textDirection: textDirection,
      textScaler: textScaler,
      locale: locale,
    );

    var lo = 0;
    var hi = runes.length;
    var best = 0;

    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      final candidate = String.fromCharCodes(runes.take(mid)).trimRight();
      probe.text = TextSpan(
        children: [
          TextSpan(text: candidate, style: bodyStyle),
          TextSpan(text: suffix, style: toggleStyle),
        ],
      );
      probe.layout(maxWidth: maxWidth);
      if (!probe.didExceedMaxLines) {
        best = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }

    return String.fromCharCodes(runes.take(best)).trimRight();
  }
}
