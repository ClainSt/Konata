import 'package:flutter/material.dart';

import '../../theme/konata_playback_tokens.dart';

/// 原生 `mpv` 风格纯文字外描边 OSD 组件（外包 [RepaintBoundary] 隔离重绘）。
///
/// 底层使用 `PaintingStyle.stroke` + 圆角连接实心黑边，顶层叠加纯白/浅亮灰填充字形，
/// 彻底摆脱卡片背景框与模糊遮罩，在亮/暗任意动画帧之上均可锐利辨识。
class KonataOsdStrokedText extends StatelessWidget {
  /// 创建纯文字描边 OSD 文本。
  const KonataOsdStrokedText(
    this.text, {
    super.key,
    this.fontSize = 12.0,
    this.fontWeight = FontWeight.w500,
    this.color = KonataPlaybackTokens.osdProbeValueColor,
    this.strokeColor = KonataPlaybackTokens.osdStrokeColor,
    this.strokeWidth = KonataPlaybackTokens.osdStrokeWidth,
    this.height = 1.32,
    this.maxLines,
    this.overflow = TextOverflow.clip,
    this.softWrap = true,
    this.textAlign = TextAlign.start,
    this.useTabularNumbers = true,
  });

  /// 显示文本内容。
  final String text;

  /// 字号（默认 `12.0`）。
  final double fontSize;

  /// 字重。
  final FontWeight fontWeight;

  /// 顶层实心填充字色。
  final Color color;

  /// 底层实心描边颜色。
  final Color strokeColor;

  /// 描边线宽（默认 `2.4`）。
  final double strokeWidth;

  /// 行高。
  final double height;

  /// 最大行数。
  final int? maxLines;

  /// 溢出裁剪策略。
  final TextOverflow overflow;

  /// 是否允许自动换行。
  final bool softWrap;

  /// 对齐方式。
  final TextAlign textAlign;

  /// 是否启用等宽数字（`FontFeature.tabularFigures`）。
  final bool useTabularNumbers;

  @override
  Widget build(BuildContext context) {
    final features = useTabularNumbers
        ? KonataPlaybackTokens.tabularNumbers
        : null;
    final strokeStyle = TextStyle(
      fontSize: fontSize,
      fontWeight: fontWeight,
      height: height,
      fontFeatures: features,
      foreground: Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round
        ..color = strokeColor,
    );
    final fillStyle = TextStyle(
      fontSize: fontSize,
      fontWeight: fontWeight,
      height: height,
      fontFeatures: features,
      color: color,
    );

    return RepaintBoundary(
      child: Stack(
        alignment: Alignment.centerLeft,
        children: [
          Text(
            text,
            maxLines: maxLines,
            overflow: overflow,
            softWrap: softWrap,
            textAlign: textAlign,
            style: strokeStyle,
          ),
          Text(
            text,
            maxLines: maxLines,
            overflow: overflow,
            softWrap: softWrap,
            textAlign: textAlign,
            style: fillStyle,
          ),
        ],
      ),
    );
  }
}
