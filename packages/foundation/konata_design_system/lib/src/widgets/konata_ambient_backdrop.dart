import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import '../tokens/konata_palette.dart';
import '../tokens/konata_playback_tokens.dart';
import '../tokens/konata_theme.dart';

/// 纯 GPU 五源径向流光着色场画布（0 MB 模糊位图显存、零常驻动画时钟）。
///
/// 由上层音频/舞台模块传入采样后的三主色（或默认流光三色），本组件专注纯视觉渲染。
class KonataAuroraFieldCanvas extends StatelessWidget {
  /// 创建纯 GPU 五源径向流光着色场画布。
  const KonataAuroraFieldCanvas({
    super.key,
    this.glowA = KonataPlaybackTokens.auroraDefaultGlowA,
    this.glowB = KonataPlaybackTokens.auroraDefaultGlowB,
    this.glowC = KonataPlaybackTokens.auroraDefaultGlowC,
  });

  /// 左肩主光色。
  final Color glowA;

  /// 右上暖霞光色。
  final Color glowB;

  /// 右下深韵光色。
  final Color glowC;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final canvasBase = KonataPlaybackTokens.auroraCanvas(p);
    final scrimColor = KonataPlaybackTokens.detailScrimBase(p).withValues(
      alpha: p.isDark
          ? KonataPlaybackTokens.auroraScrimDarkAlpha
          : KonataPlaybackTokens.auroraScrimLightAlpha,
    );
    return RepaintBoundary(
      child: CustomPaint(
        painter: _AuroraRadialFieldPainter(
          baseColor: canvasBase,
          glowA: glowA,
          glowB: glowB,
          glowC: glowC,
          scrimColor: scrimColor,
        ),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _AuroraRadialFieldPainter extends CustomPainter {
  const _AuroraRadialFieldPainter({
    required this.baseColor,
    required this.glowA,
    required this.glowB,
    required this.glowC,
    required this.scrimColor,
  });

  final Color baseColor;
  final Color glowA;
  final Color glowB;
  final Color glowC;
  final Color scrimColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final rect = Offset.zero & size;
    final maxDim = size.longestSide;

    canvas.drawRect(rect, Paint()..color = baseColor);

    final blendWarm = Color.lerp(glowA, glowB, 0.45) ?? glowA;
    final blendCool = Color.lerp(glowB, glowC, 0.55) ?? glowC;
    final sources = <({Offset center, double radius, Color color, double alpha})>[
      (
        center: Offset(size.width * 0.16, size.height * 0.24),
        radius: maxDim * 0.84,
        color: glowA,
        alpha: 0.86,
      ),
      (
        center: Offset(size.width * 0.84, size.height * 0.28),
        radius: maxDim * 0.78,
        color: glowB,
        alpha: 0.78,
      ),
      (
        center: Offset(size.width * 0.78, size.height * 0.82),
        radius: maxDim * 0.76,
        color: glowC,
        alpha: 0.70,
      ),
      (
        center: Offset(size.width * 0.24, size.height * 0.84),
        radius: maxDim * 0.72,
        color: blendCool,
        alpha: 0.64,
      ),
      (
        center: Offset(size.width * 0.50, size.height * 0.46),
        radius: maxDim * 0.64,
        color: blendWarm,
        alpha: 0.44,
      ),
    ];

    for (final src in sources) {
      final paint = Paint()
        ..shader = ui.Gradient.radial(
          src.center,
          src.radius,
          <Color>[
            src.color.withValues(alpha: src.alpha),
            src.color.withValues(alpha: src.alpha * 0.42),
            Colors.transparent,
          ],
          const <double>[0.0, 0.46, 1.0],
        );
      canvas.drawRect(rect, paint);
    }

    canvas.drawRect(rect, Paint()..color = scrimColor);
  }

  @override
  bool shouldRepaint(covariant _AuroraRadialFieldPainter oldDelegate) {
    return oldDelegate.baseColor != baseColor ||
        oldDelegate.glowA != glowA ||
        oldDelegate.glowB != glowB ||
        oldDelegate.glowC != glowC ||
        oldDelegate.scrimColor != scrimColor;
  }
}

/// 跨端壳层静态流光氛围画布（零动画时钟、0 MB 位图显存、纯 GPU 轻柔三源径向弥散）。
///
/// 供 Android 主壳层常驻铺底，以及 Windows 端用户开启「流光氛围画布」时柔和叠色使用。
class KonataAmbientShellBackdrop extends StatelessWidget {
  /// 创建壳层静态流光氛围画布。
  const KonataAmbientShellBackdrop({
    super.key,
    this.opaqueBase = true,
    this.intensity = 1.0,
  });

  /// 是否绘制不透明主题底色（Android 实底壳层为 `true`；Windows 透明窗叠加模式为 `false`）。
  final bool opaqueBase;

  /// 光晕叠加强度系数（默认 `1.0`；Windows 透光叠色建议 `0.62`）。
  final double intensity;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return RepaintBoundary(
      child: IgnorePointer(
        child: CustomPaint(
          painter: _AmbientShellPainter(
            isDark: p.isDark,
            opaqueBase: opaqueBase,
            intensity: intensity,
          ),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}

class _AmbientShellPainter extends CustomPainter {
  const _AmbientShellPainter({
    required this.isDark,
    required this.opaqueBase,
    required this.intensity,
  });

  final bool isDark;
  final bool opaqueBase;
  final double intensity;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final rect = Offset.zero & size;
    final maxDim = size.longestSide;

    if (opaqueBase) {
      canvas.drawRect(
        rect,
        Paint()
          ..color = isDark
              ? KonataTheme.cinemaObsidian
              : KonataTheme.themePreviewLightCanvas,
      );
    }

    final glowA = isDark
        ? KonataTheme.ambientShellDarkGlowA
        : KonataTheme.ambientShellLightGlowA;
    final glowB = isDark
        ? KonataTheme.ambientShellDarkGlowB
        : KonataTheme.ambientShellLightGlowB;
    final glowC = isDark
        ? KonataTheme.ambientShellDarkGlowC
        : KonataTheme.ambientShellLightGlowC;
    final baseAlpha = (isDark ? 0.24 : 0.42) * intensity.clamp(0.0, 1.0);

    final blobs = <({Offset center, double radius, Color color, double weight})>[
      (
        center: Offset(size.width * 0.14, size.height * 0.12),
        radius: maxDim * 0.72,
        color: glowA,
        weight: 1.0,
      ),
      (
        center: Offset(size.width * 0.88, size.height * 0.24),
        radius: maxDim * 0.68,
        color: glowB,
        weight: 0.92,
      ),
      (
        center: Offset(size.width * 0.56, size.height * 0.94),
        radius: maxDim * 0.66,
        color: glowC,
        weight: 0.80,
      ),
    ];

    for (final blob in blobs) {
      final a = (baseAlpha * blob.weight).clamp(0.0, 1.0);
      final paint = Paint()
        ..shader = ui.Gradient.radial(
          blob.center,
          blob.radius,
          <Color>[
            blob.color.withValues(alpha: a),
            blob.color.withValues(alpha: a * 0.34),
            Colors.transparent,
          ],
          const <double>[0.0, 0.48, 1.0],
        );
      canvas.drawRect(rect, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _AmbientShellPainter oldDelegate) {
    return oldDelegate.isDark != isDark ||
        oldDelegate.opaqueBase != opaqueBase ||
        oldDelegate.intensity != intensity;
  }
}
