import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

/// 从竖版原画或海报底部区域提取主色，并合成为适应深/浅主题的背景溶底颜色（零 Riverpod）。
abstract final class ArtworkDominantColor {
  static const int _maxCacheEntries = 64;
  static final Map<String, Color> _cache = <String, Color>{};

  /// 从缓存读取已计算的主题适配背景溶底色。
  static Color? getCached({required String cacheKey, required bool isDark}) {
    return _cache[_buildKey(cacheKey, isDark)];
  }

  /// 对原画字节流下缘区域进行 48x48 降采样吸色，并按当前深/浅主题合成为自然溶底色。
  static Future<Color?> sampleBottomDissolveColor({
    required Uint8List bytes,
    required String cacheKey,
    required bool isDark,
    required Color themeBackground,
  }) async {
    final fullKey = _buildKey(cacheKey, isDark);
    final hit = _cache[fullKey];
    if (hit != null) return hit;
    if (bytes.isEmpty) return null;

    ui.Codec? codec;
    ui.FrameInfo? frame;
    try {
      codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: 48,
        targetHeight: 48,
      );
      frame = await codec.getNextFrame();
      final byteData = await frame.image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      if (byteData == null) return null;

      final extracted = _extractBottomEdgeDominantRgb(
        rgba: byteData.buffer.asUint8List(),
        width: frame.image.width,
        height: frame.image.height,
      );
      if (extracted == null) return null;

      final adapted = harmonizeWithTheme(
        extracted,
        isDark: isDark,
        themeBackground: themeBackground,
      );
      _putCache(fullKey, adapted);
      return adapted;
    } catch (_) {
      return null;
    } finally {
      frame?.image.dispose();
      codec?.dispose();
    }
  }

  /// 将原始封面主色柔和映射为适应深色/浅色模式的高对比溶底色，避免刺眼纯色或泥泞灰底。
  static Color harmonizeWithTheme(
    Color rawColor, {
    required bool isDark,
    required Color themeBackground,
  }) {
    final hsl = HSLColor.fromColor(rawColor);
    if (isDark) {
      final tinted = hsl
          .withSaturation(hsl.saturation.clamp(0.08, 0.36))
          .withLightness(0.10)
          .toColor();
      return Color.lerp(themeBackground, tinted, 0.56) ?? themeBackground;
    }
    final tinted = hsl
        .withSaturation(hsl.saturation.clamp(0.06, 0.24))
        .withLightness(0.93)
        .toColor();
    return Color.lerp(themeBackground, tinted, 0.52) ?? themeBackground;
  }

  static Color? _extractBottomEdgeDominantRgb({
    required Uint8List rgba,
    required int width,
    required int height,
  }) {
    if (width <= 0 || height <= 0 || rgba.length < width * height * 4) {
      return null;
    }
    final startY = (height * 0.58).floor().clamp(0, height - 1);
    final deepStartY = (height * 0.78).floor().clamp(startY, height - 1);

    var weightedR = 0.0;
    var weightedG = 0.0;
    var weightedB = 0.0;
    var totalWeight = 0.0;

    for (var y = startY; y < height; y++) {
      final rowWeight = y >= deepStartY ? 2.2 : 1.0;
      for (var x = 0; x < width; x++) {
        final offset = (y * width + x) * 4;
        final r = rgba[offset];
        final g = rgba[offset + 1];
        final b = rgba[offset + 2];
        final a = rgba[offset + 3];
        if (a < 24) continue;

        final maxC = r > g ? (r > b ? r : b) : (g > b ? g : b);
        final minC = r < g ? (r < b ? r : b) : (g < b ? g : b);
        final chroma = (maxC - minC) / 255.0;
        final pixelWeight = rowWeight * (0.65 + chroma * 1.15);

        weightedR += r * pixelWeight;
        weightedG += g * pixelWeight;
        weightedB += b * pixelWeight;
        totalWeight += pixelWeight;
      }
    }

    if (totalWeight <= 0) return null;
    return Color.fromARGB(
      255,
      (weightedR / totalWeight).round().clamp(0, 255),
      (weightedG / totalWeight).round().clamp(0, 255),
      (weightedB / totalWeight).round().clamp(0, 255),
    );
  }

  static String _buildKey(String cacheKey, bool isDark) =>
      '$cacheKey|${isDark ? 'd' : 'l'}';

  static void _putCache(String key, Color color) {
    if (_cache.length >= _maxCacheEntries && !_cache.containsKey(key)) {
      _cache.remove(_cache.keys.first);
    }
    _cache[key] = color;
  }
}
