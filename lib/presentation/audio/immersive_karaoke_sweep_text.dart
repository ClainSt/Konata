import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../domain/playback/lyric_version_matcher.dart';
import '../theme/konata_playback_tokens.dart';
import '../theme/konata_theme.dart';

/// 支持自然换行与平滑进度扫光的卡拉 OK 歌词文本渲染器。
///
/// 底层渲染真实 `Text` 保证多行自动换行、可访问性与 `find.text` 精确一致；
/// 前景使用缓存 `TextPainter` + 逐行 `dstIn` 羽化渐变遮罩，在 60/120Hz 驱动下
/// 零 Widget 重建地将高亮纯白随歌声如进度条般连续铺满每一行（含换行续行）。
class ImmersiveKaraokeSweepText extends StatefulWidget {
  /// 创建卡拉 OK 进度扫光歌词文本。
  const ImmersiveKaraokeSweepText({
    super.key,
    required this.text,
    required this.baseStyle,
    required this.litStyle,
    required this.progress,
    required this.windowStartSeconds,
    required this.windowEndSeconds,
    this.spans = const <TimedLyricSpan>[],
    this.textAlign = TextAlign.start,
  });

  /// 完整显示文本（自动换行，永不截断）。
  final String text;

  /// 未唱部分的底色文字样式。
  final TextStyle baseStyle;

  /// 已唱部分的亮白/高对比度高亮文字样式（字号、字重、行高与 [baseStyle] 完全一致）。
  final TextStyle litStyle;

  /// `[0.0, 1.0]` 范围内的实时扫光动画监听句柄。
  final Animation<double> progress;

  /// 当前歌词行扫光时间窗起点（秒）。
  final double windowStartSeconds;

  /// 当前歌词行扫光时间窗终点（秒）。
  final double windowEndSeconds;

  /// 可选逐字时间片段列表；非空时按逐字片段精确映射像素进度，空时按视觉总行宽均匀连续铺满。
  final List<TimedLyricSpan> spans;

  /// 歌词文本水平对齐方式（与底层 `Text` 保持严格像素一致）。
  final TextAlign textAlign;

  @override
  State<ImmersiveKaraokeSweepText> createState() =>
      _ImmersiveKaraokeSweepTextState();
}

class _ImmersiveKaraokeSweepTextState extends State<ImmersiveKaraokeSweepText> {
  TextPainter? _cachedPainter;
  List<ui.LineMetrics> _cachedMetrics = const <ui.LineMetrics>[];
  String? _laidOutText;
  TextStyle? _laidOutStyle;
  double _laidOutMaxWidth = -1;
  TextScaler? _laidOutScaler;
  TextDirection? _laidOutDirection;
  TextAlign? _laidOutAlign;

  @override
  void dispose() {
    _cachedPainter?.dispose();
    _cachedPainter = null;
    super.dispose();
  }

  void _ensureLayout({
    required TextStyle resolvedLitStyle,
    required double maxWidth,
    required TextScaler textScaler,
    required TextDirection textDirection,
  }) {
    final safeWidth = maxWidth.isFinite && maxWidth > 0 ? maxWidth : 10000.0;
    if (_cachedPainter != null &&
        _laidOutText == widget.text &&
        _laidOutStyle == resolvedLitStyle &&
        (_laidOutMaxWidth - safeWidth).abs() < 0.25 &&
        _laidOutScaler == textScaler &&
        _laidOutDirection == textDirection &&
        _laidOutAlign == widget.textAlign) {
      return;
    }
    _cachedPainter?.dispose();
    final painter = TextPainter(
      text: TextSpan(text: widget.text, style: resolvedLitStyle),
      textAlign: widget.textAlign,
      textDirection: textDirection,
      textScaler: textScaler,
    )..layout(maxWidth: safeWidth);
    _cachedPainter = painter;
    _cachedMetrics = painter.computeLineMetrics();
    _laidOutText = widget.text;
    _laidOutStyle = resolvedLitStyle;
    _laidOutMaxWidth = safeWidth;
    _laidOutScaler = textScaler;
    _laidOutDirection = textDirection;
    _laidOutAlign = widget.textAlign;
  }

  @override
  Widget build(BuildContext context) {
    final defaultStyle = DefaultTextStyle.of(context).style;
    final resolvedBase = defaultStyle.merge(widget.baseStyle);
    final resolvedLit = defaultStyle.merge(widget.litStyle);
    final textScaler = MediaQuery.textScalerOf(context);
    final textDirection = Directionality.of(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        _ensureLayout(
          resolvedLitStyle: resolvedLit,
          maxWidth: constraints.maxWidth,
          textScaler: textScaler,
          textDirection: textDirection,
        );
        return CustomPaint(
          foregroundPainter: _KaraokeSweepForegroundPainter(
            litPainter: _cachedPainter!,
            metrics: _cachedMetrics,
            progress: widget.progress,
            windowStartSeconds: widget.windowStartSeconds,
            windowEndSeconds: widget.windowEndSeconds,
            spans: widget.spans,
          ),
          child: Text(
            widget.text,
            textAlign: widget.textAlign,
            softWrap: true,
            style: resolvedBase,
          ),
        );
      },
    );
  }
}

class _KaraokeSweepForegroundPainter extends CustomPainter {
  _KaraokeSweepForegroundPainter({
    required this.litPainter,
    required this.metrics,
    required this.progress,
    required this.windowStartSeconds,
    required this.windowEndSeconds,
    required this.spans,
  }) : super(repaint: progress);

  final TextPainter litPainter;
  final List<ui.LineMetrics> metrics;
  final Animation<double> progress;
  final double windowStartSeconds;
  final double windowEndSeconds;
  final List<TimedLyricSpan> spans;

  List<double> _computeLineLitWidths() {
    final count = metrics.length;
    if (count == 0) return const <double>[];
    final clamped = progress.value.clamp(0.0, 1.0);
    if (clamped <= 0.0) {
      return List<double>.filled(count, 0.0);
    }
    if (clamped >= 1.0) {
      return List<double>.generate(count, (i) => metrics[i].width);
    }

    if (spans.isNotEmpty) {
      return _computeSpanLineLitWidths(clamped);
    }

    var totalWidth = 0.0;
    for (final m in metrics) {
      totalWidth += m.width;
    }
    if (totalWidth <= 0.0) {
      return List<double>.filled(count, 0.0);
    }

    var remaining = clamped * totalWidth;
    final widths = List<double>.filled(count, 0.0);
    for (var i = 0; i < count; i++) {
      final lineW = metrics[i].width;
      if (remaining >= lineW) {
        widths[i] = lineW;
        remaining -= lineW;
      } else if (remaining > 0.0) {
        widths[i] = remaining;
        break;
      }
    }
    return widths;
  }

  List<double> _computeSpanLineLitWidths(double normalizedProgress) {
    final count = metrics.length;
    final widths = List<double>.filled(count, 0.0);
    final windowDur = math.max(0.01, windowEndSeconds - windowStartSeconds);
    final currentSec = windowStartSeconds + normalizedProgress * windowDur;

    var charCursor = 0;
    for (final span in spans) {
      final len = span.text.length;
      if (len == 0) continue;
      final startOffset = charCursor;
      final endOffset = charCursor + len;
      charCursor = endOffset;

      final spanProg = span.sweepProgressAt(currentSec);
      if (spanProg <= 0.0) continue;

      final boxes = litPainter.getBoxesForSelection(
        TextSelection(baseOffset: startOffset, extentOffset: endOffset),
      );
      if (boxes.isEmpty) continue;

      var totalBoxWidth = 0.0;
      for (final b in boxes) {
        totalBoxWidth += math.max(0.0, b.right - b.left);
      }
      var remainingBoxPx = totalBoxWidth * spanProg;
      for (final b in boxes) {
        final bw = math.max(0.0, b.right - b.left);
        if (bw <= 0.0) continue;
        final take = math.min(bw, remainingBoxPx);
        remainingBoxPx -= take;

        final lineIdx = _resolveLineIndexForBox(b);
        final rightEdge = (b.left + take) - metrics[lineIdx].left;
        if (rightEdge > widths[lineIdx]) {
          widths[lineIdx] = rightEdge.clamp(0.0, metrics[lineIdx].width);
        }
        if (remainingBoxPx <= 0.001) {
          break;
        }
      }
    }
    return widths;
  }

  int _resolveLineIndexForBox(TextBox box) {
    final boxCenterY = (box.top + box.bottom) * 0.5;
    var bestIdx = 0;
    var bestDist = double.infinity;
    for (var i = 0; i < metrics.length; i++) {
      final m = metrics[i];
      final lineTop = m.baseline - m.ascent;
      final lineCenterY = lineTop + m.height * 0.5;
      final dist = (boxCenterY - lineCenterY).abs();
      if (dist < bestDist) {
        bestDist = dist;
        bestIdx = i;
      }
    }
    return bestIdx;
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (metrics.isEmpty) return;
    final lineLitWidths = _computeLineLitWidths();
    final count = metrics.length;

    for (var i = 0; i < count; i++) {
      final m = metrics[i];
      final litW = lineLitWidths[i];
      if (litW <= 0.05) continue;

      final prev = i > 0 ? metrics[i - 1] : null;
      final next = i + 1 < count ? metrics[i + 1] : null;
      final yTop = prev == null
          ? -8.0
          : ((prev.baseline + prev.descent) + (m.baseline - m.ascent)) * 0.5;
      final yBottom = next == null
          ? size.height + 8.0
          : ((m.baseline + m.descent) + (next.baseline - next.ascent)) * 0.5;
      final bandRect = Rect.fromLTRB(-12.0, yTop, size.width + 12.0, yBottom);

      if (litW >= m.width - 0.5) {
        canvas.save();
        canvas.clipRect(bandRect);
        litPainter.paint(canvas, Offset.zero);
        canvas.restore();
      } else {
        final sweepX = m.left + litW;
        final feather = math.min(
          KonataPlaybackTokens.lyricKaraokeFeatherMaxPx,
          math.max(6.0, m.width * 0.12),
        );
        final gradStart = sweepX - feather * 0.35;
        final gradEnd = sweepX + feather * 0.55;

        canvas.saveLayer(bandRect, Paint());
        canvas.clipRect(bandRect);
        litPainter.paint(canvas, Offset.zero);
        final maskPaint = Paint()
          ..blendMode = BlendMode.dstIn
          ..shader = const LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: <Color>[KonataTheme.pureWhite, Colors.transparent],
          ).createShader(Rect.fromLTRB(gradStart, yTop, gradEnd, yBottom));
        canvas.drawRect(bandRect, maskPaint);
        canvas.restore();
      }
    }
  }

  @override
  bool shouldRepaint(covariant _KaraokeSweepForegroundPainter oldDelegate) {
    return oldDelegate.litPainter != litPainter ||
        oldDelegate.metrics != metrics ||
        oldDelegate.progress != progress ||
        oldDelegate.windowStartSeconds != windowStartSeconds ||
        oldDelegate.windowEndSeconds != windowEndSeconds ||
        oldDelegate.spans != spans;
  }
}
