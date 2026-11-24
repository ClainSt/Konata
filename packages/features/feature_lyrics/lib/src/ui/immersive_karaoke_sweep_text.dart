import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:engine_playback/engine_playback.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:konata_design_system/konata_design_system.dart';

/// 支持自然换行、逐字精确停顿与音拍加权推进的卡拉 OK 歌词文本渲染器。
///
/// 底层渲染真实 `Text` 保证多行自动换行、可访问性与文本查找完全一致；
/// 布局阶段一次性缓存每段逐字或音拍分片矩形边界与前缀已亮宽度，
/// 渲染每帧零临时列表分配，仅通过二分查找与算术插值驱动羽化扫白。
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
    this.romajiText = '',
    this.isJapaneseSong,
    this.textAlign = TextAlign.start,
  });

  /// 完整显示文本（自动换行，永不截断）。
  final String text;

  /// 未唱部分的底色文字样式。
  final TextStyle baseStyle;

  /// 已唱部分的亮白/高对比度高亮文字样式（字号、字重、行高与 [baseStyle] 完全一致）。
  final TextStyle litStyle;

  /// `[0.0, 1.0]` 范围内的实时扫光进度监听句柄。
  final ValueListenable<double> progress;

  /// 当前歌词行扫光时间窗起点（秒）。
  final double windowStartSeconds;

  /// 当前歌词行扫光时间窗终点（秒）。
  final double windowEndSeconds;

  /// 可选逐字时间片段列表；非空时按逐字起止时间精确扫白，空时按音拍权重分布连续推进。
  final List<TimedLyricSpan> spans;

  /// 可选独立罗马音文本（行级音拍加权模式下用于精确校准音拍总数）。
  final String romajiText;

  /// 所属歌词文档是否为日文语境（确保全汉字行仍按日文音拍比例估算）。
  final bool? isJapaneseSong;

  /// 歌词文本水平对齐方式（与底层 `Text` 保持严格像素一致）。
  final TextAlign textAlign;

  @override
  State<ImmersiveKaraokeSweepText> createState() =>
      _ImmersiveKaraokeSweepTextState();
}

/// 单个字符或逐字片段落在某一视觉行上的预缓存水平矩形切片。
class _CachedBoxSlice {
  const _CachedBoxSlice({
    required this.lineIndex,
    required this.localLeft,
    required this.width,
    required this.localRight,
    required this.cumStartPx,
  });

  final int lineIndex;
  final double localLeft;
  final double width;
  final double localRight;
  final double cumStartPx;
}

/// 布局期预缓存的单个扫白时间分段（统一承载逐字时间片段与行级音拍分段）。
class _CachedSweepSegment {
  const _CachedSweepSegment({
    required this.startTime,
    required this.endTime,
    required this.invDuration,
    required this.totalBoxWidth,
    required this.slices,
  });

  final double startTime;
  final double endTime;
  final double invDuration;
  final double totalBoxWidth;
  final List<_CachedBoxSlice> slices;
}

/// 布局期一次性构建的不可变扫白几何缓存（每帧只读，零排版查询）。
class _KaraokeSweepGeometryCache {
  _KaraokeSweepGeometryCache({
    required this.metrics,
    required this.lineFullWidths,
    required this.lineLefts,
    required this.lineFeathers,
    required this.bandTops,
    required this.bandBottoms,
    required this.segments,
    required this.usesRealSeconds,
    required this.isStrictlyMonotonic,
    required this.prefixLitWidths,
    required this.totalLineWidth,
  });

  final List<ui.LineMetrics> metrics;
  final Float64List lineFullWidths;
  final Float64List lineLefts;
  final Float64List lineFeathers;
  final Float64List bandTops;
  final Float64List bandBottoms;
  final List<_CachedSweepSegment> segments;

  /// 为真表示起止值为真实播放秒数（逐字模式）；为假表示归一化进度（行级模式）。
  final bool usesRealSeconds;

  /// 所有分段是否按起始时间单调且彼此无重叠（支持二分与前缀宽度直取）。
  final bool isStrictlyMonotonic;

  /// 各分段之前全部唱完后各视觉行的累计点亮宽度。
  final List<Float64List> prefixLitWidths;

  /// 全部视觉行宽度之和（用于无分段兜底）。
  final double totalLineWidth;

  static _KaraokeSweepGeometryCache build({
    required TextPainter painter,
    required String text,
    required List<TimedLyricSpan> spans,
    required String romajiText,
    required bool? isJapaneseSong,
  }) {
    final metrics = painter.computeLineMetrics();
    final lineCount = metrics.length;
    final lineFullWidths = Float64List(lineCount);
    final lineLefts = Float64List(lineCount);
    final lineFeathers = Float64List(lineCount);
    final bandTops = Float64List(lineCount);
    final bandBottoms = Float64List(lineCount);
    final lineCenterYs = Float64List(lineCount);
    var totalLineWidth = 0.0;

    for (var i = 0; i < lineCount; i++) {
      final m = metrics[i];
      lineFullWidths[i] = m.width;
      lineLefts[i] = m.left;
      lineFeathers[i] = math.min(
        KonataPlaybackTokens.lyricKaraokeFeatherMaxPx,
        math.max(6.0, m.width * 0.12),
      );
      totalLineWidth += m.width;
      final lineTop = m.baseline - m.ascent;
      lineCenterYs[i] = lineTop + m.height * 0.5;
      final prev = i > 0 ? metrics[i - 1] : null;
      final next = i + 1 < lineCount ? metrics[i + 1] : null;
      bandTops[i] = prev == null
          ? -8.0
          : ((prev.baseline + prev.descent) + lineTop) * 0.5;
      bandBottoms[i] = next == null
          ? painter.height + 8.0
          : ((m.baseline + m.descent) + (next.baseline - next.ascent)) * 0.5;
    }

    int resolveLineIndex(ui.TextBox box) {
      if (lineCount <= 1) return 0;
      final boxCenterY = (box.top + box.bottom) * 0.5;
      var bestIdx = 0;
      var bestDist = (boxCenterY - lineCenterYs[0]).abs();
      for (var i = 1; i < lineCount; i++) {
        final dist = (boxCenterY - lineCenterYs[i]).abs();
        if (dist < bestDist) {
          bestDist = dist;
          bestIdx = i;
        }
      }
      return bestIdx;
    }

    List<_CachedBoxSlice> extractSlices(int startOffset, int endOffset) {
      final clampedStart = startOffset.clamp(0, text.length);
      final clampedEnd = endOffset.clamp(clampedStart, text.length);
      if (clampedEnd <= clampedStart || lineCount == 0) {
        return const <_CachedBoxSlice>[];
      }
      final boxes = painter.getBoxesForSelection(
        TextSelection(baseOffset: clampedStart, extentOffset: clampedEnd),
      );
      if (boxes.isEmpty) return const <_CachedBoxSlice>[];

      final slices = <_CachedBoxSlice>[];
      var cumPx = 0.0;
      for (final b in boxes) {
        final bw = math.max(0.0, b.right - b.left);
        if (bw <= 0.0) continue;
        final lineIdx = resolveLineIndex(b);
        final lineLeft = lineLefts[lineIdx];
        final lineW = lineFullWidths[lineIdx];
        final localLeft = (b.left - lineLeft).clamp(0.0, lineW);
        final localRight = (b.right - lineLeft).clamp(0.0, lineW);
        slices.add(
          _CachedBoxSlice(
            lineIndex: lineIdx,
            localLeft: localLeft,
            width: bw,
            localRight: localRight,
            cumStartPx: cumPx,
          ),
        );
        cumPx += bw;
      }
      return slices;
    }

    final segments = <_CachedSweepSegment>[];
    final usesRealSeconds = spans.isNotEmpty;

    if (usesRealSeconds) {
      var charCursor = 0;
      for (final span in spans) {
        final len = span.text.length;
        if (len == 0) continue;
        final startOffset = charCursor;
        final endOffset = charCursor + len;
        charCursor = endOffset;
        final slices = extractSlices(startOffset, endOffset);
        var totalBoxW = 0.0;
        for (final s in slices) {
          totalBoxW += s.width;
        }
        final dur = span.endSeconds - span.startSeconds;
        segments.add(
          _CachedSweepSegment(
            startTime: span.startSeconds,
            endTime: span.endSeconds,
            invDuration: dur > 1e-6 ? 1.0 / dur : 0.0,
            totalBoxWidth: totalBoxW,
            slices: slices,
          ),
        );
      }
    } else if (lineCount > 0 && text.isNotEmpty) {
      final profile = MoraPaceEstimator.buildLineProfile(
        text,
        romajiText: romajiText,
        isJapaneseSong: isJapaneseSong,
      );
      for (final seg in profile.segments) {
        final slices = extractSlices(seg.startOffset, seg.endOffset);
        var totalBoxW = 0.0;
        for (final s in slices) {
          totalBoxW += s.width;
        }
        final dur = seg.endFraction - seg.startFraction;
        segments.add(
          _CachedSweepSegment(
            startTime: seg.startFraction,
            endTime: seg.endFraction,
            invDuration: dur > 1e-6 ? 1.0 / dur : 0.0,
            totalBoxWidth: totalBoxW,
            slices: slices,
          ),
        );
      }
    }

    var monotonic = segments.isNotEmpty && lineCount > 0;
    for (var i = 1; i < segments.length && monotonic; i++) {
      final prev = segments[i - 1];
      final cur = segments[i];
      if (cur.startTime + 1e-5 < prev.startTime ||
          prev.endTime > cur.startTime + 1e-3) {
        monotonic = false;
      }
    }

    final prefixLitWidths = <Float64List>[];
    if (monotonic) {
      final running = Float64List(lineCount);
      for (final seg in segments) {
        prefixLitWidths.add(Float64List.fromList(running));
        for (final slice in seg.slices) {
          if (slice.localRight > running[slice.lineIndex]) {
            running[slice.lineIndex] = slice.localRight;
          }
        }
      }
    }

    return _KaraokeSweepGeometryCache(
      metrics: metrics,
      lineFullWidths: lineFullWidths,
      lineLefts: lineLefts,
      lineFeathers: lineFeathers,
      bandTops: bandTops,
      bandBottoms: bandBottoms,
      segments: List<_CachedSweepSegment>.unmodifiable(segments),
      usesRealSeconds: usesRealSeconds,
      isStrictlyMonotonic: monotonic,
      prefixLitWidths: prefixLitWidths,
      totalLineWidth: totalLineWidth,
    );
  }
}

class _ImmersiveKaraokeSweepTextState extends State<ImmersiveKaraokeSweepText> {
  TextPainter? _cachedPainter;
  _KaraokeSweepGeometryCache? _cachedGeometry;
  Float64List _scratchWidths = Float64List(0);

  String? _laidOutText;
  TextStyle? _laidOutStyle;
  double _laidOutMaxWidth = -1;
  TextScaler? _laidOutScaler;
  TextDirection? _laidOutDirection;
  TextAlign? _laidOutAlign;
  List<TimedLyricSpan>? _laidOutSpans;
  String? _laidOutRomaji;
  bool? _laidOutIsJapanese;

  @override
  void dispose() {
    _cachedPainter?.dispose();
    _cachedPainter = null;
    _cachedGeometry = null;
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
        _cachedGeometry != null &&
        _laidOutText == widget.text &&
        _laidOutStyle == resolvedLitStyle &&
        (_laidOutMaxWidth - safeWidth).abs() < 0.25 &&
        _laidOutScaler == textScaler &&
        _laidOutDirection == textDirection &&
        _laidOutAlign == widget.textAlign &&
        identical(_laidOutSpans, widget.spans) &&
        _laidOutRomaji == widget.romajiText &&
        _laidOutIsJapanese == widget.isJapaneseSong) {
      return;
    }
    _cachedPainter?.dispose();
    final painter = TextPainter(
      text: TextSpan(text: widget.text, style: resolvedLitStyle),
      textAlign: widget.textAlign,
      textDirection: textDirection,
      textScaler: textScaler,
    )..layout(maxWidth: safeWidth);

    final geometry = _KaraokeSweepGeometryCache.build(
      painter: painter,
      text: widget.text,
      spans: widget.spans,
      romajiText: widget.romajiText,
      isJapaneseSong: widget.isJapaneseSong,
    );
    _cachedPainter = painter;
    _cachedGeometry = geometry;
    if (_scratchWidths.length != geometry.metrics.length) {
      _scratchWidths = Float64List(geometry.metrics.length);
    }
    _laidOutText = widget.text;
    _laidOutStyle = resolvedLitStyle;
    _laidOutMaxWidth = safeWidth;
    _laidOutScaler = textScaler;
    _laidOutDirection = textDirection;
    _laidOutAlign = widget.textAlign;
    _laidOutSpans = widget.spans;
    _laidOutRomaji = widget.romajiText;
    _laidOutIsJapanese = widget.isJapaneseSong;
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
            geometry: _cachedGeometry!,
            scratchWidths: _scratchWidths,
            progress: widget.progress,
            windowStartSeconds: widget.windowStartSeconds,
            windowEndSeconds: widget.windowEndSeconds,
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
    required this.geometry,
    required this.scratchWidths,
    required this.progress,
    required this.windowStartSeconds,
    required this.windowEndSeconds,
  }) : super(repaint: progress);

  final TextPainter litPainter;
  final _KaraokeSweepGeometryCache geometry;
  final Float64List scratchWidths;
  final ValueListenable<double> progress;
  final double windowStartSeconds;
  final double windowEndSeconds;

  static const LinearGradient _featherGradient = LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    colors: <Color>[KonataTheme.pureWhite, Colors.transparent],
  );

  void _fillLineLitWidths() {
    final count = geometry.metrics.length;
    if (count == 0) return;

    final clamped = progress.value.clamp(0.0, 1.0);
    if (clamped <= 0.0) {
      for (var i = 0; i < count; i++) {
        scratchWidths[i] = 0.0;
      }
      return;
    }
    if (clamped >= 1.0) {
      for (var i = 0; i < count; i++) {
        scratchWidths[i] = geometry.lineFullWidths[i];
      }
      return;
    }

    final segments = geometry.segments;
    if (segments.isEmpty) {
      _fillUniformPixelFallback(clamped);
      return;
    }

    final targetTime = geometry.usesRealSeconds
        ? windowStartSeconds +
              clamped * math.max(0.01, windowEndSeconds - windowStartSeconds)
        : clamped;

    if (geometry.isStrictlyMonotonic) {
      _fillWithBinarySearchPrefix(targetTime);
    } else {
      _fillWithLinearCachedScan(targetTime);
    }
  }

  /// 二分查找加前缀已亮宽度直取：每帧对数复杂度定位当前活跃分段并做算术插值。
  void _fillWithBinarySearchPrefix(double targetTime) {
    final segments = geometry.segments;
    final count = geometry.metrics.length;
    if (targetTime < segments.first.startTime) {
      for (var i = 0; i < count; i++) {
        scratchWidths[i] = 0.0;
      }
      return;
    }

    var low = 0;
    var high = segments.length - 1;
    var activeIdx = 0;
    while (low <= high) {
      final mid = (low + high) >> 1;
      if (segments[mid].startTime <= targetTime) {
        activeIdx = mid;
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }

    final prefix = geometry.prefixLitWidths[activeIdx];
    for (var i = 0; i < count; i++) {
      scratchWidths[i] = prefix[i];
    }
    _applySegmentPartialLit(segments[activeIdx], targetTime);
  }

  /// 缓存几何线性扫描（兼容重叠时间戳片段）。
  void _fillWithLinearCachedScan(double targetTime) {
    final count = geometry.metrics.length;
    for (var i = 0; i < count; i++) {
      scratchWidths[i] = 0.0;
    }
    for (final seg in geometry.segments) {
      if (targetTime <= seg.startTime) continue;
      _applySegmentPartialLit(seg, targetTime);
    }
  }

  void _applySegmentPartialLit(_CachedSweepSegment seg, double targetTime) {
    if (seg.slices.isEmpty) return;
    final double segProg;
    if (targetTime <= seg.startTime) {
      return;
    } else if (targetTime >= seg.endTime || seg.invDuration <= 0.0) {
      segProg = 1.0;
    } else {
      segProg = ((targetTime - seg.startTime) * seg.invDuration).clamp(0.0, 1.0);
    }

    if (segProg >= 1.0) {
      for (final slice in seg.slices) {
        if (slice.localRight > scratchWidths[slice.lineIndex]) {
          scratchWidths[slice.lineIndex] = slice.localRight;
        }
      }
      return;
    }

    final targetPx = seg.totalBoxWidth * segProg;
    for (final slice in seg.slices) {
      final within = targetPx - slice.cumStartPx;
      if (within <= 0.0) break;
      final take = math.min(slice.width, within);
      final rightEdge = math.min(
        geometry.lineFullWidths[slice.lineIndex],
        slice.localLeft + take,
      );
      if (rightEdge > scratchWidths[slice.lineIndex]) {
        scratchWidths[slice.lineIndex] = rightEdge;
      }
      if (within <= slice.width + 0.001) break;
    }
  }

  void _fillUniformPixelFallback(double clamped) {
    final count = geometry.metrics.length;
    final totalWidth = geometry.totalLineWidth;
    if (totalWidth <= 0.0) {
      for (var i = 0; i < count; i++) {
        scratchWidths[i] = 0.0;
      }
      return;
    }
    var remaining = clamped * totalWidth;
    for (var i = 0; i < count; i++) {
      final lineW = geometry.lineFullWidths[i];
      if (remaining >= lineW) {
        scratchWidths[i] = lineW;
        remaining -= lineW;
      } else if (remaining > 0.0) {
        scratchWidths[i] = remaining;
        remaining = 0.0;
      } else {
        scratchWidths[i] = 0.0;
      }
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    final count = geometry.metrics.length;
    if (count == 0) return;
    _fillLineLitWidths();

    final clipRight = size.width + 12.0;
    for (var i = 0; i < count; i++) {
      final litW = scratchWidths[i];
      if (litW <= 0.05) continue;

      final lineW = geometry.lineFullWidths[i];
      final yTop = geometry.bandTops[i];
      final yBottom = geometry.bandBottoms[i];
      final bandRect = Rect.fromLTRB(-12.0, yTop, clipRight, yBottom);

      if (litW >= lineW - 0.5) {
        canvas.save();
        canvas.clipRect(bandRect);
        litPainter.paint(canvas, Offset.zero);
        canvas.restore();
      } else {
        final sweepX = geometry.lineLefts[i] + litW;
        final feather = geometry.lineFeathers[i];
        final gradStart = sweepX - feather * 0.35;
        final gradEnd = sweepX + feather * 0.55;

        canvas.saveLayer(bandRect, Paint());
        canvas.clipRect(bandRect);
        litPainter.paint(canvas, Offset.zero);
        final maskPaint = Paint()
          ..blendMode = BlendMode.dstIn
          ..shader = _featherGradient.createShader(
            Rect.fromLTRB(gradStart, yTop, gradEnd, yBottom),
          );
        canvas.drawRect(bandRect, maskPaint);
        canvas.restore();
      }
    }
  }

  @override
  bool shouldRepaint(covariant _KaraokeSweepForegroundPainter oldDelegate) {
    return !identical(oldDelegate.litPainter, litPainter) ||
        !identical(oldDelegate.geometry, geometry) ||
        oldDelegate.progress != progress ||
        oldDelegate.windowStartSeconds != windowStartSeconds ||
        oldDelegate.windowEndSeconds != windowEndSeconds;
  }
}
