import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 封面主色色板 LRU 内存缓存（由 Riverpod Provider 托管生命周期，禁止全局静态可变字段）。
class ArtworkPaletteCache {
  /// 创建容量受限的色板 LRU 缓存。
  ArtworkPaletteCache({this.maxEntries = 32});

  /// 最大缓存条目数。
  final int maxEntries;

  final Map<String, List<Color>> _entries = <String, List<Color>>{};

  /// 查询并刷新命中键的最近访问次序。
  List<Color>? get(String key) {
    final hit = _entries.remove(key);
    if (hit == null) return null;
    _entries[key] = hit;
    return hit;
  }

  /// 写入色板并在超出容量上限时淘汰最久未使用的条目。
  void put(String key, List<Color> palette) {
    final frozen = List<Color>.unmodifiable(palette);
    _entries.remove(key);
    _entries[key] = frozen;
    while (_entries.length > maxEntries) {
      _entries.remove(_entries.keys.first);
    }
  }

  /// 清空全部缓存条目。
  void clear() {
    _entries.clear();
  }

  /// 当前缓存条目数量。
  int get length => _entries.length;
}

/// 全局封面流光主色板缓存 Provider（无静态可变状态，随容器释放自动回收）。
final artworkPaletteCacheProvider = Provider<ArtworkPaletteCache>((ref) {
  final cache = ArtworkPaletteCache();
  ref.onDispose(cache.clear);
  return cache;
});

/// 在后台 `Isolate` 中执行 RGBA 像素色相分桶主色聚类，返回三色流光色板（主 UI 线程零聚类计算）。
Future<List<Color>?> extractAuroraPaletteInIsolate(Uint8List rgbaBytes) async {
  if (rgbaBytes.length < 4) return null;
  final argbList = await Isolate.run(
    () => clusterAuroraPaletteArgb(rgbaBytes),
  );
  if (argbList == null || argbList.length < 3) return null;
  return List<Color>.unmodifiable([
    Color(argbList[0]),
    Color(argbList[1]),
    Color(argbList[2]),
  ]);
}

/// 纯 Dart 12 色相分桶主色聚类算法（不依赖 `dart:ui`，可在后台 `Isolate` 直接执行）。
///
/// 输入为 `rawRgba` 像素字节流，返回 3 个经饱和度/明度提纯后的 32 位 ARGB 色值。
List<int>? clusterAuroraPaletteArgb(Uint8List rgbaBytes) {
  if (rgbaBytes.length < 4) return null;
  final counts = List<int>.filled(12, 0);
  final sumR = List<double>.filled(12, 0);
  final sumG = List<double>.filled(12, 0);
  final sumB = List<double>.filled(12, 0);

  for (var i = 0; i + 3 < rgbaBytes.length; i += 4) {
    final a = rgbaBytes[i + 3];
    if (a < 140) continue;
    final r = rgbaBytes[i];
    final g = rgbaBytes[i + 1];
    final b = rgbaBytes[i + 2];
    final hsv = _rgbToHsv(r, g, b);
    if (hsv.s < 0.14 || hsv.v < 0.12) continue;
    final bin = (hsv.h ~/ 30).clamp(0, 11);
    counts[bin] += 1;
    sumR[bin] += r;
    sumG[bin] += g;
    sumB[bin] += b;
  }

  final ranked = <({int count, double h, double s, double v})>[];
  for (var bin = 0; bin < 12; bin++) {
    final c = counts[bin];
    if (c == 0) continue;
    final avgR = (sumR[bin] / c).round().clamp(0, 255);
    final avgG = (sumG[bin] / c).round().clamp(0, 255);
    final avgB = (sumB[bin] / c).round().clamp(0, 255);
    final hsv = _rgbToHsv(avgR, avgG, avgB);
    ranked.add((
      count: c,
      h: hsv.h,
      s: hsv.s.clamp(0.68, 0.88),
      v: hsv.v.clamp(0.45, 0.65),
    ));
  }

  if (ranked.isEmpty) return null;
  ranked.sort((a, b) => b.count.compareTo(a.count));

  final primary = ranked[0];
  final c1 = _hsvToArgb(primary.h, primary.s, primary.v);
  final c2 = ranked.length > 1
      ? _hsvToArgb(ranked[1].h, ranked[1].s, ranked[1].v)
      : _hsvToArgb((primary.h + 36.0) % 360.0, primary.s, primary.v);
  final c3 = ranked.length > 2
      ? _hsvToArgb(ranked[2].h, ranked[2].s, ranked[2].v)
      : _hsvToArgb((primary.h + 318.0) % 360.0, primary.s, primary.v);
  return <int>[c1, c2, c3];
}

({double h, double s, double v}) _rgbToHsv(int r, int g, int b) {
  final rf = r / 255.0;
  final gf = g / 255.0;
  final bf = b / 255.0;
  final maxC = math.max(rf, math.max(gf, bf));
  final minC = math.min(rf, math.min(gf, bf));
  final delta = maxC - minC;

  double h = 0.0;
  if (delta > 0.0) {
    if (maxC == rf) {
      h = 60.0 * (((gf - bf) / delta) % 6.0);
    } else if (maxC == gf) {
      h = 60.0 * (((bf - rf) / delta) + 2.0);
    } else {
      h = 60.0 * (((rf - gf) / delta) + 4.0);
    }
    if (h < 0.0) h += 360.0;
  }
  final s = maxC <= 0.0 ? 0.0 : delta / maxC;
  return (h: h, s: s, v: maxC);
}

int _hsvToArgb(double h, double s, double v) {
  final normalizedH = ((h % 360.0) + 360.0) % 360.0;
  final c = v * s;
  final x = c * (1.0 - (((normalizedH / 60.0) % 2.0) - 1.0).abs());
  final m = v - c;

  double rf;
  double gf;
  double bf;
  if (normalizedH < 60.0) {
    rf = c;
    gf = x;
    bf = 0.0;
  } else if (normalizedH < 120.0) {
    rf = x;
    gf = c;
    bf = 0.0;
  } else if (normalizedH < 180.0) {
    rf = 0.0;
    gf = c;
    bf = x;
  } else if (normalizedH < 240.0) {
    rf = 0.0;
    gf = x;
    bf = c;
  } else if (normalizedH < 300.0) {
    rf = x;
    gf = 0.0;
    bf = c;
  } else {
    rf = c;
    gf = 0.0;
    bf = x;
  }

  final r = ((rf + m) * 255.0).round().clamp(0, 255);
  final g = ((gf + m) * 255.0).round().clamp(0, 255);
  final b = ((bf + m) * 255.0).round().clamp(0, 255);
  return 0xFF000000 | (r << 16) | (g << 8) | b;
}
