import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';

import '../tokens/konata_palette.dart';
import '../tokens/konata_theme.dart';

/// Bangumi 粉色斜体几何微标 + 评分数字组件（零外部字体/图片体积膨胀）。
///
/// 使用纯矢量 [CustomPainter] 绘制经典 `bangumi` 粉色几何斜体标识（含 `m` 顶部的标志性
/// 小电视天线 `v`，无底行副标文字），右侧紧凑衔接同色斜体等宽评分数字；
/// 外壳对齐「N 部」计数胶囊的双主题半透明毛玻璃与细亮描边质感。
class BangumiScoreWordmarkBadge extends StatelessWidget {
  /// 创建 Bangumi 评分微标。
  const BangumiScoreWordmarkBadge({
    super.key,
    required this.score,
    this.wordmarkHeight = 12.5,
    this.enableBackdropBlur = true,
  });

  /// Bangumi 评分（如 `8.6` / `6.7`）。
  final double score;

  /// `bangumi` 矢量字标高度（宽度按矢量实际绘制边界 `3.88:1` 紧凑计算）。
  final double wordmarkHeight;

  /// 是否启用实时 `BackdropFilter` 毛玻璃与阴影层（未悬停隐藏态可关闭以消除滚动期合成层开销）。
  final bool enableBackdropBlur;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final formattedScore = score.toStringAsFixed(1);
    final fgColor = KonataTheme.bangumiBadgeForeground(p);
    final fillColor = KonataTheme.bangumiBadgeFill(p);
    final borderColor = KonataTheme.bangumiBadgeBorderFor(p);

    final badgeSurface = Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        gradient: KonataTheme.opticalSheenGradient(p, baseColor: fillColor),
        borderRadius: KonataTheme.borderRadiusPill,
        border: Border.all(color: borderColor, width: 1.0),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: wordmarkHeight * 3.88,
            height: wordmarkHeight,
            child: CustomPaint(
              painter: _BangumiWordmarkPainter(color: fgColor),
            ),
          ),
          const SizedBox(width: 4.5),
          Transform(
            transform: Matrix4.skewX(-0.22),
            alignment: Alignment.center,
            child: Text(
              formattedScore,
              style: KonataTheme.textStyle(
                color: fgColor,
                fontSize: wordmarkHeight * 0.96,
                weight: 760,
                height: 1.0,
                tabularFigures: true,
              ),
            ),
          ),
        ],
      ),
    );

    if (!enableBackdropBlur) {
      return badgeSurface;
    }

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: KonataTheme.borderRadiusPill,
        boxShadow: [
          BoxShadow(
            color: KonataTheme.pureBlack.withValues(
              alpha: p.isDark ? 0.30 : 0.14,
            ),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: KonataTheme.borderRadiusPill,
        child: BackdropFilter(
          filter: KonataTheme.blurFilterSubtle,
          child: badgeSurface,
        ),
      ),
    );
  }
}

/// 纯矢量绘制 Bangumi 官方几何斜体字标（`b a n g u m i` + `m` 顶电视天线 `v`）。
class _BangumiWordmarkPainter extends CustomPainter {
  const _BangumiWordmarkPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    // 逻辑坐标系：宽 240，高 62；x-height 区间 y=[18..48]，ascender y=4，descender y=58
    final scale = size.height / 62.0;
    canvas.save();
    canvas.scale(scale, scale);

    // 施加与参考图一致的几何右倾斜体矩阵，并补偿左侧水平偏移防裁切
    canvas.translate(15.0, 0.0);
    canvas.transform(
      Float64List.fromList(<double>[
        1.0, 0.0, 0.0, 0.0, //
        -0.31, 1.0, 0.0, 0.0, //
        0.0, 0.0, 1.0, 0.0, //
        0.0, 0.0, 0.0, 1.0, //
      ]),
    );

    const strokeW = 7.4;
    const r = 6.2;
    const xTop = 18.0;
    const xBot = 48.0;

    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeW
      ..strokeCap = StrokeCap.butt
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;

    final roundStroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;

    // 1. 字母 b（左竖干起自 y=4 + 右侧圆角矩形腹腔）
    final bPath = Path()
      ..moveTo(6, 5)
      ..lineTo(6, xBot)
      ..lineTo(24, xBot)
      ..quadraticBezierTo(30, xBot, 30, xBot - r)
      ..lineTo(30, xTop + r)
      ..quadraticBezierTo(30, xTop, 24, xTop)
      ..lineTo(6, xTop);
    canvas.drawPath(bPath, stroke);

    // 2. 字母 a（上方屋檐横杠转右竖干 + 下方闭合圆角矩形腹腔）
    const ax = 41.0;
    final aPath = Path()
      ..moveTo(ax + 2, xTop)
      ..lineTo(ax + 18, xTop)
      ..quadraticBezierTo(ax + 24, xTop, ax + 24, xTop + r)
      ..lineTo(ax + 24, xBot)
      ..lineTo(ax + 6, xBot)
      ..quadraticBezierTo(ax, xBot, ax, xBot - r)
      ..lineTo(ax, 34)
      ..quadraticBezierTo(ax, 30, ax + 6, 30)
      ..lineTo(ax + 24, 30);
    canvas.drawPath(aPath, stroke);

    // 3. 字母 n（左竖干 + 圆角顶拱 + 右竖干）
    const nx = 76.0;
    final nPath = Path()
      ..moveTo(nx, xBot + 2)
      ..lineTo(nx, xTop)
      ..lineTo(nx + 18, xTop)
      ..quadraticBezierTo(nx + 24, xTop, nx + 24, xTop + r)
      ..lineTo(nx + 24, xBot + 2);
    canvas.drawPath(nPath, stroke);

    // 4. 字母 g（圆角腹腔 + 右干向下延伸至基线下水平勾脚）
    const gx = 111.0;
    final gPath = Path()
      ..moveTo(gx + 24, xTop)
      ..lineTo(gx + 6, xTop)
      ..quadraticBezierTo(gx, xTop, gx, xTop + r)
      ..lineTo(gx, xBot - r)
      ..quadraticBezierTo(gx, xBot, gx + 6, xBot)
      ..lineTo(gx + 24, xBot)
      ..moveTo(gx + 24, xTop - 2)
      ..lineTo(gx + 24, 53)
      ..quadraticBezierTo(gx + 24, 58, gx + 18, 58)
      ..lineTo(gx + 2, 58);
    canvas.drawPath(gPath, stroke);

    // 5. 字母 u（左干下落圆角底拱接右干）
    const ux = 146.0;
    final uPath = Path()
      ..moveTo(ux, xTop - 2)
      ..lineTo(ux, xBot - r)
      ..quadraticBezierTo(ux, xBot, ux + 6, xBot)
      ..lineTo(ux + 24, xBot)
      ..lineTo(ux + 24, xTop - 2);
    canvas.drawPath(uPath, stroke);

    // 6. 字母 m（三竖腿圆角双拱）
    const mx = 181.0;
    final mPath = Path()
      ..moveTo(mx, xBot + 2)
      ..lineTo(mx, xTop)
      ..lineTo(mx + 26, xTop)
      ..quadraticBezierTo(mx + 32, xTop, mx + 32, xTop + r)
      ..lineTo(mx + 32, xBot + 2)
      ..moveTo(mx + 16, xTop)
      ..lineTo(mx + 16, xBot + 2);
    canvas.drawPath(mPath, stroke);

    // 标志性小电视天线 v（从 m 顶部中右处向左上/右上张开）
    const antennaBaseX = mx + 17.5;
    const antennaBaseY = xTop - 3.0;
    canvas.drawLine(
      const Offset(antennaBaseX, antennaBaseY),
      const Offset(antennaBaseX - 9.0, 4.5),
      roundStroke,
    );
    canvas.drawLine(
      const Offset(antennaBaseX, antennaBaseY),
      const Offset(antennaBaseX + 9.5, 4.5),
      roundStroke,
    );

    // 7. 无点几何斜体 i
    const ix = 224.0;
    canvas.drawLine(
      const Offset(ix, xTop - 2),
      const Offset(ix, xBot + 2),
      stroke,
    );

    canvas.restore();
  }

  @override
  bool shouldRepaint(_BangumiWordmarkPainter oldDelegate) =>
      oldDelegate.color != color;
}
