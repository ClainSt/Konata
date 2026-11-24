import 'dart:async';
import 'dart:collection';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

/// 从专辑封面提炼的四象限丝绒沉浸流光颜色（ARGB 32位无符号整数）。
class ArtworkAuroraPalette {
  /// 构造包含主色调、次色调、高光、底色微染与四象限丝绒色点的流光色板。
  const ArtworkAuroraPalette({
    required this.primaryArgb,
    required this.secondaryArgb,
    required this.accentArgb,
    required this.surfaceTintArgb,
    this.quadrantTopLeftArgb = fallbackTopLeftArgb,
    this.quadrantTopRightArgb = fallbackTopRightArgb,
    this.quadrantBottomLeftArgb = fallbackBottomLeftArgb,
    this.quadrantBottomRightArgb = fallbackBottomRightArgb,
  });

  /// 默认左上丝绒深蓝紫退化色点。
  static const int fallbackTopLeftArgb = 0xFF4B4270;

  /// 默认右上丝绒靛青退化色点。
  static const int fallbackTopRightArgb = 0xFF3D5073;

  /// 默认左下丝绒夜幕紫退化色点。
  static const int fallbackBottomLeftArgb = 0xFF2E2A48;

  /// 默认右下丝绒莓紫退化色点。
  static const int fallbackBottomRightArgb = 0xFF5C3E62;

  /// 默认冷雾曜石静态流光底色（无封面图或色彩提取未完成时的优雅退化色板）。
  static const ArtworkAuroraPalette fallback = ArtworkAuroraPalette(
    primaryArgb: 0xFF564B70,
    secondaryArgb: 0xFF3E6178,
    accentArgb: 0xFFD9885B,
    surfaceTintArgb: 0xFF0E0B12,
    quadrantTopLeftArgb: fallbackTopLeftArgb,
    quadrantTopRightArgb: fallbackTopRightArgb,
    quadrantBottomLeftArgb: fallbackBottomLeftArgb,
    quadrantBottomRightArgb: fallbackBottomRightArgb,
  );

  /// 主色调高饱和代表色。
  final int primaryArgb;

  /// 辅色调均衡代表色。
  final int secondaryArgb;

  /// 中心呼吸高光点亮色。
  final int accentArgb;

  /// 深色玻璃基底微染基准色。
  final int surfaceTintArgb;

  /// 左上象限高饱和丝绒色点。
  final int quadrantTopLeftArgb;

  /// 右上象限高饱和丝绒色点。
  final int quadrantTopRightArgb;

  /// 左下象限高饱和丝绒色点。
  final int quadrantBottomLeftArgb;

  /// 右下象限高饱和丝绒色点。
  final int quadrantBottomRightArgb;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ArtworkAuroraPalette &&
          other.primaryArgb == primaryArgb &&
          other.secondaryArgb == secondaryArgb &&
          other.accentArgb == accentArgb &&
          other.surfaceTintArgb == surfaceTintArgb &&
          other.quadrantTopLeftArgb == quadrantTopLeftArgb &&
          other.quadrantTopRightArgb == quadrantTopRightArgb &&
          other.quadrantBottomLeftArgb == quadrantBottomLeftArgb &&
          other.quadrantBottomRightArgb == quadrantBottomRightArgb;

  @override
  int get hashCode => Object.hash(
    primaryArgb,
    secondaryArgb,
    accentArgb,
    surfaceTintArgb,
    quadrantTopLeftArgb,
    quadrantTopRightArgb,
    quadrantBottomLeftArgb,
    quadrantBottomRightArgb,
  );
}

/// 纯 `Isolate` 像素聚类算法：将缩放后的 `RGBA8888` 缓冲区按 12 色相桶统计并生成平衡流光色板。
ArtworkAuroraPalette clusterAuroraPaletteArgb(
  Uint8List rgbaBytes,
  int width,
  int height,
) {
  if (rgbaBytes.lengthInBytes < 4 || width <= 0 || height <= 0) {
    return ArtworkAuroraPalette.fallback;
  }

  const binCount = 12;
  final binWeight = Float64List(binCount);
  final binR = Float64List(binCount);
  final binG = Float64List(binCount);
  final binB = Float64List(binCount);

  double totalR = 0;
  double totalG = 0;
  double totalB = 0;
  double totalWeight = 0;
  final quadR = Float64List(4);
  final quadG = Float64List(4);
  final quadB = Float64List(4);
  final quadW = Float64List(4);
  final halfW = width * 0.5;
  final halfH = height * 0.5;
  double peakSatR = 0;
  double peakSatG = 0;
  double peakSatB = 0;
  double peakSatScore = -1;

  final totalPixels = math.min(width * height, rgbaBytes.lengthInBytes ~/ 4);
  for (var i = 0; i < totalPixels; i++) {
    final offset = i * 4;
    final r = rgbaBytes[offset];
    final g = rgbaBytes[offset + 1];
    final b = rgbaBytes[offset + 2];
    final a = rgbaBytes[offset + 3];
    if (a < 180) continue;

    final maxC = math.max(r, math.max(g, b));
    final minC = math.min(r, math.min(g, b));
    final chroma = maxC - minC;
    final luma = (0.299 * r + 0.587 * g + 0.114 * b) / 255.0;

    if (luma < 0.05 || luma > 0.94) continue;

    final sat = maxC == 0 ? 0.0 : chroma / maxC;
    final w = 0.25 + sat * sat * 2.2 + (chroma / 255.0) * 1.4;

    totalR += r * w;
    totalG += g * w;
    totalB += b * w;
    totalWeight += w;

    final x = i % width;
    final y = i ~/ width;
    final qIdx = (y < halfH ? 0 : 2) + (x < halfW ? 0 : 1);
    quadR[qIdx] += r * w;
    quadG[qIdx] += g * w;
    quadB[qIdx] += b * w;
    quadW[qIdx] += w;

    if (sat > 0.14 && chroma > 22) {
      final score = sat * (0.65 + (1.0 - (luma - 0.52).abs()));
      if (score > peakSatScore) {
        peakSatScore = score;
        peakSatR = r.toDouble();
        peakSatG = g.toDouble();
        peakSatB = b.toDouble();
      }
    }

    if (chroma < 16) continue;
    final hueDeg = _rgbToHueDegrees(r, g, b, maxC, chroma);
    final bin = (hueDeg / 30.0).floor().clamp(0, binCount - 1);
    binWeight[bin] += w;
    binR[bin] += r * w;
    binG[bin] += g * w;
    binB[bin] += b * w;
  }

  if (totalWeight <= 0.001) {
    return ArtworkAuroraPalette.fallback;
  }

  var primaryBin = -1;
  var bestBinW = 0.0;
  for (var b = 0; b < binCount; b++) {
    if (binWeight[b] > bestBinW) {
      bestBinW = binWeight[b];
      primaryBin = b;
    }
  }

  final avgR = totalR / totalWeight;
  final avgG = totalG / totalWeight;
  final avgB = totalB / totalWeight;

  final int primaryArgb;
  if (primaryBin >= 0) {
    final w = binWeight[primaryBin];
    primaryArgb = _tuneAuroraRgb(
      binR[primaryBin] / w,
      binG[primaryBin] / w,
      binB[primaryBin] / w,
      targetMinSat: 0.36,
      targetMinLuma: 0.34,
      targetMaxLuma: 0.62,
    );
  } else {
    primaryArgb = _tuneAuroraRgb(
      avgR,
      avgG,
      avgB,
      targetMinSat: 0.26,
      targetMinLuma: 0.32,
      targetMaxLuma: 0.56,
    );
  }

  var secondaryBin = -1;
  var bestSecScore = 0.0;
  if (primaryBin >= 0) {
    for (var b = 0; b < binCount; b++) {
      if (binWeight[b] <= 0) continue;
      final dist = math.min(
        (b - primaryBin).abs(),
        binCount - (b - primaryBin).abs(),
      );
      if (dist < 2) continue;
      final score = binWeight[b] * (0.7 + dist * 0.22);
      if (score > bestSecScore) {
        bestSecScore = score;
        secondaryBin = b;
      }
    }
  }

  final int secondaryArgb;
  if (secondaryBin >= 0) {
    final w = binWeight[secondaryBin];
    secondaryArgb = _tuneAuroraRgb(
      binR[secondaryBin] / w,
      binG[secondaryBin] / w,
      binB[secondaryBin] / w,
      targetMinSat: 0.32,
      targetMinLuma: 0.28,
      targetMaxLuma: 0.56,
    );
  } else {
    secondaryArgb = _rotateHueAndDarken(primaryArgb, 42.0, 0.85);
  }

  final int accentArgb;
  if (peakSatScore > 0) {
    accentArgb = _tuneAuroraRgb(
      peakSatR,
      peakSatG,
      peakSatB,
      targetMinSat: 0.44,
      targetMinLuma: 0.44,
      targetMaxLuma: 0.72,
    );
  } else {
    accentArgb = _rotateHueAndDarken(primaryArgb, -35.0, 1.08);
  }

  final surfaceTintArgb = _tuneAuroraRgb(
    avgR,
    avgG,
    avgB,
    targetMinSat: 0.14,
    targetMinLuma: 0.05,
    targetMaxLuma: 0.11,
  );

  int tuneQuadrant(int qIdx, int fallbackArgb) {
    final w = quadW[qIdx];
    if (w <= 0.001) return fallbackArgb;
    return _tuneAuroraRgb(
      quadR[qIdx] / w,
      quadG[qIdx] / w,
      quadB[qIdx] / w,
      targetMinSat: 0.44,
      targetMinLuma: 0.22,
      targetMaxLuma: 0.42,
    );
  }

  final qTopLeft = tuneQuadrant(
    0,
    _rotateHueAndDarken(primaryArgb, -12.0, 0.72),
  );
  final qTopRight = tuneQuadrant(
    1,
    _rotateHueAndDarken(secondaryArgb, 18.0, 0.74),
  );
  final qBottomLeft = tuneQuadrant(
    2,
    _rotateHueAndDarken(primaryArgb, 28.0, 0.62),
  );
  final qBottomRight = tuneQuadrant(
    3,
    _rotateHueAndDarken(secondaryArgb, -24.0, 0.68),
  );

  return ArtworkAuroraPalette(
    primaryArgb: primaryArgb,
    secondaryArgb: secondaryArgb,
    accentArgb: accentArgb,
    surfaceTintArgb: surfaceTintArgb,
    quadrantTopLeftArgb: qTopLeft,
    quadrantTopRightArgb: qTopRight,
    quadrantBottomLeftArgb: qBottomLeft,
    quadrantBottomRightArgb: qBottomRight,
  );
}

double _rgbToHueDegrees(int r, int g, int b, int maxC, int chroma) {
  if (chroma == 0) return 0;
  double hue;
  if (maxC == r) {
    hue = ((g - b) / chroma) % 6.0;
  } else if (maxC == g) {
    hue = ((b - r) / chroma) + 2.0;
  } else {
    hue = ((r - g) / chroma) + 4.0;
  }
  final deg = hue * 60.0;
  return deg < 0 ? deg + 360.0 : deg;
}

int _tuneAuroraRgb(
  double r,
  double g,
  double b, {
  required double targetMinSat,
  required double targetMinLuma,
  required double targetMaxLuma,
}) {
  final nr = (r / 255.0).clamp(0.0, 1.0);
  final ng = (g / 255.0).clamp(0.0, 1.0);
  final nb = (b / 255.0).clamp(0.0, 1.0);
  final maxC = math.max(nr, math.max(ng, nb));
  final minC = math.min(nr, math.min(ng, nb));
  final delta = maxC - minC;

  var l = (maxC + minC) * 0.5;
  var s = 0.0;
  if (delta > 0.0001) {
    s = delta / (1.0 - (2.0 * l - 1.0).abs());
  }
  var h = 248.0;
  if (delta > 0.0001) {
    if (maxC == nr) {
      h = ((ng - nb) / delta) % 6.0;
    } else if (maxC == ng) {
      h = ((nb - nr) / delta) + 2.0;
    } else {
      h = ((nr - ng) / delta) + 4.0;
    }
    h *= 60.0;
    if (h < 0) h += 360.0;
  }

  s = delta <= 0.015 ? 0.16 : s.clamp(targetMinSat, 0.84);
  l = l.clamp(targetMinLuma, targetMaxLuma);
  return _hslToArgb(h, s, l);
}

int _rotateHueAndDarken(int argb, double deltaHueDeg, double lumaFactor) {
  final r = ((argb >> 16) & 0xFF) / 255.0;
  final g = ((argb >> 8) & 0xFF) / 255.0;
  final b = (argb & 0xFF) / 255.0;
  final maxC = math.max(r, math.max(g, b));
  final minC = math.min(r, math.min(g, b));
  final delta = maxC - minC;
  final l = ((maxC + minC) * 0.5 * lumaFactor).clamp(0.22, 0.72);
  var s = delta <= 0.0001 ? 0.35 : delta / (1.0 - (2.0 * l - 1.0).abs());
  s = s.clamp(0.28, 0.72);
  var h = 210.0;
  if (delta > 0.0001) {
    if (maxC == r) {
      h = ((g - b) / delta) % 6.0;
    } else if (maxC == g) {
      h = ((b - r) / delta) + 2.0;
    } else {
      h = ((r - g) / delta) + 4.0;
    }
    h = (h * 60.0 + deltaHueDeg) % 360.0;
    if (h < 0) h += 360.0;
  }
  return _hslToArgb(h, s, l);
}

int _hslToArgb(double h, double s, double l) {
  final c = (1.0 - (2.0 * l - 1.0).abs()) * s;
  final x = c * (1.0 - (((h / 60.0) % 2.0) - 1.0).abs());
  final m = l - c * 0.5;
  double rp = 0, gp = 0, bp = 0;
  if (h < 60) {
    rp = c;
    gp = x;
  } else if (h < 120) {
    rp = x;
    gp = c;
  } else if (h < 180) {
    gp = c;
    bp = x;
  } else if (h < 240) {
    gp = x;
    bp = c;
  } else if (h < 300) {
    rp = x;
    bp = c;
  } else {
    rp = c;
    bp = x;
  }
  final ri = ((rp + m) * 255.0).round().clamp(0, 255);
  final gi = ((gp + m) * 255.0).round().clamp(0, 255);
  final bi = ((bp + m) * 255.0).round().clamp(0, 255);
  return 0xFF000000 | (ri << 16) | (gi << 8) | bi;
}

/// 从编码图片字节高效解码缩略帧并在后台线程完成聚类的工具函数。
Future<ArtworkAuroraPalette> extractAuroraPaletteInIsolate(
  Uint8List encodedImageBytes,
) async {
  if (encodedImageBytes.isEmpty) return ArtworkAuroraPalette.fallback;
  ui.Codec? codec;
  ui.Image? image;
  try {
    codec = await ui.instantiateImageCodec(
      encodedImageBytes,
      targetWidth: 48,
      targetHeight: 48,
    );
    final frame = await codec.getNextFrame();
    image = frame.image;
    final byteData = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (byteData == null) return ArtworkAuroraPalette.fallback;
    final rgba = byteData.buffer.asUint8List(
      byteData.offsetInBytes,
      byteData.lengthInBytes,
    );
    final w = image.width;
    final h = image.height;
    return await Isolate.run(() => clusterAuroraPaletteArgb(rgba, w, h));
  } catch (_) {
    return ArtworkAuroraPalette.fallback;
  } finally {
    image?.dispose();
    codec?.dispose();
  }
}

/// 专辑封面流光色板内存缓存（内置并发请求合并与淘汰上限，零状态框架依赖）。
class ArtworkPaletteCache {
  /// 最大内存色板条目上限。
  static const int maxEntries = 128;

  final LinkedHashMap<String, ArtworkAuroraPalette> _cache = LinkedHashMap();
  final Map<String, Future<ArtworkAuroraPalette>> _inFlight = {};

  /// 同步命中已缓存色板，未命中返回空。
  ArtworkAuroraPalette? peek(String cacheKey) {
    final hit = _cache.remove(cacheKey);
    if (hit != null) {
      _cache[cacheKey] = hit;
    }
    return hit;
  }

  /// 获取或后台提炼封面流光色板，相同键的并发提取仅执行一次。
  Future<ArtworkAuroraPalette> getOrExtract(
    String cacheKey,
    Uint8List encodedBytes,
  ) {
    final cached = peek(cacheKey);
    if (cached != null) return Future.value(cached);

    final pending = _inFlight[cacheKey];
    if (pending != null) return pending;

    final future = extractAuroraPaletteInIsolate(encodedBytes).then((palette) {
      if (_cache.length >= maxEntries) {
        _cache.remove(_cache.keys.first);
      }
      _cache[cacheKey] = palette;
      return palette;
    }).whenComplete(() {
      _inFlight.remove(cacheKey);
    });
    _inFlight[cacheKey] = future;
    return future;
  }

  /// 清空内存色板缓存。
  void clear() {
    _cache.clear();
  }
}
