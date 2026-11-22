import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../theme/konata_palette.dart';
import '../../theme/konata_playback_tokens.dart';
import '../../theme/konata_theme.dart';

/// 全站唯一无封面 CD 专辑光学实体光盘占位组件（零额外贴图、纯矢量抗锯齿、深浅双主题自适应）。
///
/// 统一服务于详情页 CD 卡片、播放记录音频缩略图、悬浮音频小窗与全屏流光音频页大封面兜底：
/// - 盘面采用金属微珠光径向基色 + 对角双对称光学干涉虹彩高光（低饱和通透感，契合流光毛玻璃语言）；
/// - 完整刻画实体光盘外沿倒角高光、微细数据轨、聚碳酸酯透明压环与中心镂空孔；
/// - 尺寸 `< 64px` 时自动精简细纹确保小尺寸锐利不糊，零常驻动画 Ticker。
class KonataCdDiscPlaceholder extends StatelessWidget {
  /// 创建实体光学 CD 光盘占位图。
  const KonataCdDiscPlaceholder({
    super.key,
    this.hovered = false,
    this.transparentBackdrop = false,
    this.discScale = 0.78,
  });

  /// 是否处于悬停激活态（悬停时适度提升盘面光泽与高光通透度）。
  final bool hovered;

  /// 是否透明底（当外层已叠加虚化作品海报或毛玻璃衬底时开启，仅绘制悬浮光盘主体）。
  final bool transparentBackdrop;

  /// 光盘直径占容器最短边的比例（默认 `0.78`，在圆形封面容器内可设为 `0.92`）。
  final double discScale;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return RepaintBoundary(
      child: CustomPaint(
        painter: _KonataOpticalCdDiscPainter(
          isDark: p.isDark,
          hovered: hovered,
          transparentBackdrop: transparentBackdrop,
          discScale: discScale,
        ),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _KonataOpticalCdDiscPainter extends CustomPainter {
  const _KonataOpticalCdDiscPainter({
    required this.isDark,
    required this.hovered,
    required this.transparentBackdrop,
    required this.discScale,
  });

  final bool isDark;
  final bool hovered;
  final bool transparentBackdrop;
  final double discScale;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final rect = Offset.zero & size;
    final center = rect.center;
    final minSide = math.min(size.width, size.height);
    final isMicro = minSide < 64.0;

    // 1. 柔和 CD 盒内衬背景（当无外层虚化海报底图时绘制）。
    if (!transparentBackdrop) {
      final bgPaint = Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: isDark
              ? const [
                  KonataPlaybackTokens.cdCaseBgDarkTop,
                  KonataPlaybackTokens.cdCaseBgDarkBottom,
                ]
              : const [
                  KonataPlaybackTokens.cdCaseBgLightTop,
                  KonataPlaybackTokens.cdCaseBgLightBottom,
                ],
        ).createShader(rect);
      canvas.drawRect(rect, bgPaint);

      // 左上角微妙光学环境辉光，呼应全局流光毛玻璃光源方向。
      final ambientPaint = Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.75, -0.75),
          radius: 1.35,
          colors: [
            (isDark
                    ? KonataPlaybackTokens.auroraDefaultGlowA
                    : KonataTheme.pureWhite)
                .withValues(alpha: isDark ? 0.22 : 0.45),
            Colors.transparent,
          ],
        ).createShader(rect);
      canvas.drawRect(rect, ambientPaint);
    }

    final radius = (minSide * discScale * 0.5).clamp(8.0, minSide * 0.49);
    final discRect = Rect.fromCircle(center: center, radius: radius);

    // 2. 光盘底部柔和悬浮接触阴影。
    if (!isMicro) {
      final shadowPaint = Paint()
        ..color = KonataPlaybackTokens.cinemaPureBlack.withValues(
          alpha: isDark ? 0.46 : 0.16,
        )
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, radius * 0.14);
      canvas.drawCircle(
        center.translate(0, radius * 0.08),
        radius * 0.98,
        shadowPaint,
      );
    }

    // 3. 实体光盘环形主体（采用 evenOdd 路径精确挖空中心轴孔）。
    final holeRadius = radius * 0.165;
    final discRingPath = Path()
      ..fillType = PathFillType.evenOdd
      ..addOval(discRect)
      ..addOval(Rect.fromCircle(center: center, radius: holeRadius));

    canvas.save();
    canvas.clipPath(discRingPath);

    // 3a. 金属拉丝径向基底色。
    final basePaint = Paint()
      ..shader = RadialGradient(
        center: const Alignment(-0.22, -0.24),
        radius: 1.05,
        stops: const [0.0, 0.46, 0.82, 1.0],
        colors: isDark
            ? const [
                KonataPlaybackTokens.cdDiscBodyDarkInner,
                KonataPlaybackTokens.cdDiscBodyDarkMid,
                KonataPlaybackTokens.cdDiscBodyDarkOuter,
                KonataPlaybackTokens.cdCaseBgDarkBottom,
              ]
            : const [
                KonataPlaybackTokens.cdDiscBodyLightInner,
                KonataPlaybackTokens.cdDiscBodyLightMid,
                KonataPlaybackTokens.cdDiscBodyLightOuter,
                KonataPlaybackTokens.cdCaseBgLightBottom,
              ],
      ).createShader(discRect);
    canvas.drawRect(discRect, basePaint);

    // 3b. 对角双对称光学扫射光泽（真实 CD 蝴蝶结状各向异性高光 + 克制干涉虹彩）。
    final sheenBoost = hovered ? 1.25 : 1.0;
    Color scaled(Color c, double factor) =>
        c.withValues(alpha: (c.a * factor * sheenBoost).clamp(0.0, 0.92));
    final sheenFactor = isDark ? 0.85 : 0.72;
    final sweepPaint = Paint()
      ..shader = SweepGradient(
        center: Alignment.center,
        transform: const GradientRotation(-math.pi / 4.0),
        stops: const [
          0.0,
          0.08,
          0.16,
          0.26,
          0.38,
          0.50,
          0.58,
          0.66,
          0.76,
          0.88,
          1.0,
        ],
        colors: [
          scaled(KonataPlaybackTokens.cdIridescenceWhite, sheenFactor),
          scaled(KonataPlaybackTokens.cdIridescenceCyan, sheenFactor),
          scaled(KonataPlaybackTokens.cdIridescenceViolet, sheenFactor * 0.8),
          Colors.transparent,
          Colors.transparent,
          scaled(KonataPlaybackTokens.cdIridescenceWhite, sheenFactor * 0.92),
          scaled(KonataPlaybackTokens.cdIridescenceRose, sheenFactor * 0.85),
          scaled(KonataPlaybackTokens.cdIridescenceCyan, sheenFactor * 0.75),
          Colors.transparent,
          Colors.transparent,
          scaled(KonataPlaybackTokens.cdIridescenceWhite, sheenFactor),
        ],
      ).createShader(discRect);
    canvas.drawRect(discRect, sweepPaint);

    // 3c. 微米级数据读取区同心细纹（仅常规尺寸绘制，保持精致质感）。
    if (!isMicro) {
      final groovePaint = Paint()
        ..color = KonataTheme.pureWhite.withValues(
          alpha: isDark ? 0.08 : 0.24,
        )
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.65;
      for (final factor in const [0.88, 0.74, 0.60, 0.46]) {
        canvas.drawCircle(center, radius * factor, groovePaint);
      }
    }

    // 3d. 中心聚碳酸酯透明压环（Clamping Ring）。
    final clampRingOuter = radius * 0.34;
    final clampRingInner = radius * 0.245;
    final clampFill = Paint()
      ..color = (isDark ? KonataPlaybackTokens.cinemaPureBlack : KonataTheme.pureWhite)
          .withValues(alpha: isDark ? 0.30 : 0.48)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, clampRingOuter, clampFill);

    final clampRim = Paint()
      ..color = (isDark ? KonataTheme.pureWhite : KonataPlaybackTokens.cinemaPureBlack)
          .withValues(alpha: isDark ? 0.22 : 0.14)
      ..style = PaintingStyle.stroke
      ..strokeWidth = isMicro ? 0.8 : 1.0;
    canvas.drawCircle(center, clampRingOuter, clampRim);
    canvas.drawCircle(center, clampRingInner, clampRim);

    // 外沿斜切镜面高光环。
    final rimHighlight = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          KonataTheme.pureWhite.withValues(alpha: isDark ? 0.48 : 0.88),
          KonataTheme.pureWhite.withValues(alpha: isDark ? 0.12 : 0.25),
          KonataPlaybackTokens.cinemaPureBlack.withValues(alpha: isDark ? 0.35 : 0.16),
        ],
      ).createShader(discRect)
      ..style = PaintingStyle.stroke
      ..strokeWidth = isMicro ? 1.0 : 1.3;
    canvas.drawCircle(center, radius - 0.6, rimHighlight);

    canvas.restore();

    // 4. 中心镂空轴孔内壁微妙凹陷环与底部高光。
    if (!transparentBackdrop) {
      final holeBg = Paint()
        ..color = isDark
            ? KonataPlaybackTokens.cdSpindleHoleDark
            : KonataPlaybackTokens.cdSpindleHoleLight;
      canvas.drawCircle(center, holeRadius, holeBg);
    }
    final holeBorder = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          KonataPlaybackTokens.cinemaPureBlack.withValues(alpha: isDark ? 0.60 : 0.26),
          KonataTheme.pureWhite.withValues(alpha: isDark ? 0.32 : 0.72),
        ],
      ).createShader(Rect.fromCircle(center: center, radius: holeRadius))
      ..style = PaintingStyle.stroke
      ..strokeWidth = isMicro ? 0.9 : 1.2;
    canvas.drawCircle(center, holeRadius, holeBorder);
  }

  @override
  bool shouldRepaint(covariant _KonataOpticalCdDiscPainter oldDelegate) {
    return oldDelegate.isDark != isDark ||
        oldDelegate.hovered != hovered ||
        oldDelegate.transparentBackdrop != transparentBackdrop ||
        oldDelegate.discScale != discScale;
  }
}
