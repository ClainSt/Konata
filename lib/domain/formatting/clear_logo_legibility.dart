import 'dart:math' as math;
import 'dart:typed_data';

/// 透明标题徽标（ClearLogo）在暗色电影底图上的自适应可读性增强策略。
enum ClearLogoLegibilityMode {
  /// 原图在暗底上已具备足够对比度（浅色字、亮彩色或自带浅色描边），原样渲染。
  original,

  /// 单色或近似单色的纯黑/深灰暗字（无白边），采用保色相亮度反相为光学象牙白。
  smartInvert,

  /// 深彩色无白边标题（如深酒红、深海蓝、深墨绿），保留原色相并沿真实字形轮廓绘制柔和霜白背晕。
  softHalo,
}

/// 基于 RGBA 采样像素评估透明标题徽标在暗底上的可读性增强模式。
///
/// 采用 BT.709 感知相对亮度与色度差 `(max - min) / 255` 联合判定，
/// 避免纯黑/炭黑字因极低通道值触发 HSV 饱和度噪声而被误判为彩色徽标。
ClearLogoLegibilityMode analyzeClearLogoRgba(Uint8List rgbaBytes) {
  if (rgbaBytes.length < 4) {
    return ClearLogoLegibilityMode.original;
  }

  var totalWeight = 0.0;
  var weightedLumSum = 0.0;
  var brightWeight = 0.0;
  var neutralWeight = 0.0;

  for (var i = 0; i + 3 < rgbaBytes.length; i += 4) {
    final alpha = rgbaBytes[i + 3];
    if (alpha < 64) continue;

    final r = rgbaBytes[i];
    final g = rgbaBytes[i + 1];
    final b = rgbaBytes[i + 2];
    final weight = alpha / 255.0;
    final lum = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255.0;
    final maxC = math.max(r, math.max(g, b));
    final minC = math.min(r, math.min(g, b));
    final chroma = (maxC - minC) / 255.0;

    totalWeight += weight;
    weightedLumSum += lum * weight;
    if (lum >= 0.42) {
      brightWeight += weight;
    }
    if (chroma < 0.14) {
      neutralWeight += weight;
    }
  }

  if (totalWeight <= 0.0) {
    return ClearLogoLegibilityMode.original;
  }

  final avgLum = weightedLumSum / totalWeight;
  final brightRatio = brightWeight / totalWeight;
  final neutralRatio = neutralWeight / totalWeight;

  // 原图整体较亮或已有足够比例浅色描边/亮部元素时，忠实保留官方原画。
  if (avgLum >= 0.30 || brightRatio >= 0.20) {
    return ClearLogoLegibilityMode.original;
  }

  // 主体为纯黑/炭灰等低色度暗字（即使带少量彩色点缀），采用保色相亮度反相为清晰白字。
  if (avgLum < 0.28 && brightRatio < 0.14 && neutralRatio >= 0.65) {
    return ClearLogoLegibilityMode.smartInvert;
  }

  // 深色高饱和彩色字保留原色相，叠加贴合字形轮廓的柔和霜白背晕。
  return ClearLogoLegibilityMode.softHalo;
}
