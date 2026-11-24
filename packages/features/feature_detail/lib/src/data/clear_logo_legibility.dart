import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'dart:ui' show Color;

import 'package:konata_design_system/konata_design_system.dart';

/// 透明标题徽标（ClearLogo）像素亮度采样摘要。
class ClearLogoLumaStats {
  /// 创建亮度采样摘要。
  const ClearLogoLumaStats({
    required this.opaquePixelCount,
    required this.averageLuma,
    required this.darkPixelRatio,
    required this.brightPixelRatio,
  });

  /// 参与统计的有效不透明像素数量。
  final int opaquePixelCount;

  /// 加权平均相对亮度（`0.0` 纯黑 ~ `1.0` 纯白）。
  final double averageLuma;

  /// 深色像素占比（线性近似亮度 `< 0.34`）。
  final double darkPixelRatio;

  /// 浅色像素占比（线性近似亮度 `> 0.66`）。
  final double brightPixelRatio;
}

/// 徽标可视性与暗角托底自适应策略决策结果。
class ClearLogoLegibilityResult {
  /// 创建可读性自适应决策结果。
  const ClearLogoLegibilityResult({
    required this.needsDarkScrim,
    required this.needsLightScrim,
    required this.recommendedScrimStrength,
    required this.contrastToBackground,
  });

  /// 默认均衡参数（在尚未完成采样时温和保底）。
  static const ClearLogoLegibilityResult neutral = ClearLogoLegibilityResult(
    needsDarkScrim: true,
    needsLightScrim: false,
    recommendedScrimStrength: 0.36,
    contrastToBackground: 4.5,
  );

  /// 是否需要在徽标背后强化暗色渐变衬底（适合白字/亮色徽标）。
  final bool needsDarkScrim;

  /// 是否需要在深色背景上施加柔光托底（适合纯黑/极深墨色徽标）。
  final bool needsLightScrim;

  /// 推荐衬底不透明度增强系数（`0.0 ~ 1.0`）。
  final double recommendedScrimStrength;

  /// 徽标主色与估算局部背景的相对对比度比值（`1.0 ~ 21.0`）。
  final double contrastToBackground;
}

/// 透明标题徽标像素亮度分析与双背景可读性自适应计算工具。
abstract final class ClearLogoLegibility {
  static const double _alphaThreshold = 32.0;

  /// 从解码后的徽标像素采样统计其有效前景亮度分布（自动降采样至最多 64×64）。
  static ClearLogoLumaStats analyzeRgbaBytes(
    Uint8List rgba,
    int width,
    int height,
  ) {
    if (width <= 0 || height <= 0 || rgba.length < width * height * 4) {
      return const ClearLogoLumaStats(
        opaquePixelCount: 0,
        averageLuma: 0.5,
        darkPixelRatio: 0,
        brightPixelRatio: 0,
      );
    }

    final stepX = width > 64 ? (width / 64).ceil() : 1;
    final stepY = height > 64 ? (height / 64).ceil() : 1;

    var opaqueCount = 0;
    var darkCount = 0;
    var brightCount = 0;
    var weightedLumaSum = 0.0;
    var weightSum = 0.0;

    for (var y = 0; y < height; y += stepY) {
      for (var x = 0; x < width; x += stepX) {
        final offset = (y * width + x) * 4;
        final r = rgba[offset];
        final g = rgba[offset + 1];
        final b = rgba[offset + 2];
        final a = rgba[offset + 3];
        if (a < _alphaThreshold) continue;

        final alphaWeight = a / 255.0;
        final luma = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255.0;
        opaqueCount++;
        weightedLumaSum += luma * alphaWeight;
        weightSum += alphaWeight;
        if (luma < 0.34) {
          darkCount++;
        } else if (luma > 0.66) {
          brightCount++;
        }
      }
    }

    if (opaqueCount == 0 || weightSum <= 0) {
      return const ClearLogoLumaStats(
        opaquePixelCount: 0,
        averageLuma: 0.5,
        darkPixelRatio: 0,
        brightPixelRatio: 0,
      );
    }

    return ClearLogoLumaStats(
      opaquePixelCount: opaqueCount,
      averageLuma: (weightedLumaSum / weightSum).clamp(0.0, 1.0),
      darkPixelRatio: darkCount / opaqueCount,
      brightPixelRatio: brightCount / opaqueCount,
    );
  }

  /// 异步从 GPU 图像提取字节并分析徽标亮度分布。
  static Future<ClearLogoLumaStats> analyzeImage(ui.Image image) async {
    final byteData = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (byteData == null) {
      return const ClearLogoLumaStats(
        opaquePixelCount: 0,
        averageLuma: 0.5,
        darkPixelRatio: 0,
        brightPixelRatio: 0,
      );
    }
    final bytes = Uint8List.view(
      byteData.buffer,
      byteData.offsetInBytes,
      byteData.lengthInBytes,
    );
    return analyzeRgbaBytes(bytes, image.width, image.height);
  }

  /// 计算指定徽标统计量在目标局部背景色下所需的衬底增强策略。
  static ClearLogoLegibilityResult evaluateForSurface({
    required ClearLogoLumaStats stats,
    required Color estimatedBackground,
  }) {
    if (stats.opaquePixelCount == 0) {
      return ClearLogoLegibilityResult.neutral;
    }

    final bgLuma = estimatedBackground.computeLuminance();
    final logoLuma = stats.averageLuma;
    final hi = logoLuma > bgLuma ? logoLuma : bgLuma;
    final lo = logoLuma > bgLuma ? bgLuma : logoLuma;
    final contrast = (hi + 0.05) / (lo + 0.05);

    if (stats.darkPixelRatio >= 0.60 && stats.brightPixelRatio < 0.20) {
      final lowContrastOnDark = bgLuma < 0.35 || contrast < 3.0;
      return ClearLogoLegibilityResult(
        needsDarkScrim: false,
        needsLightScrim: lowContrastOnDark,
        recommendedScrimStrength: lowContrastOnDark ? 0.56 : 0.14,
        contrastToBackground: contrast,
      );
    }

    final needsMoreDark = bgLuma > 0.38 || contrast < 3.2;
    return ClearLogoLegibilityResult(
      needsDarkScrim: true,
      needsLightScrim: false,
      recommendedScrimStrength: needsMoreDark ? 0.62 : 0.28,
      contrastToBackground: contrast,
    );
  }

  /// 针对预览网格暗底或亮底返回徽标边缘柔光提亮参数。
  static Color? resolvePreviewGlowTint({
    required ClearLogoLumaStats stats,
    required bool isDarkSurface,
  }) {
    if (stats.opaquePixelCount == 0) return null;
    if (isDarkSurface && stats.darkPixelRatio >= 0.58) {
      return KonataTheme.pureWhite.withValues(alpha: 0.32);
    }
    if (!isDarkSurface && stats.brightPixelRatio >= 0.58) {
      return KonataTheme.cinemaObsidian.withValues(alpha: 0.36);
    }
    return null;
  }
}
