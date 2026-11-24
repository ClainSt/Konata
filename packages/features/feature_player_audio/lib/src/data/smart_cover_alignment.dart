import 'dart:async';
import 'dart:collection';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

/// 不依赖界面库的归一化裁切对齐坐标（范围 `-1.0 ~ 1.0`）。
class CoverCropAlignment {
  /// 构造归一化对齐坐标。
  const CoverCropAlignment(this.x, this.y);

  /// 默认视觉中心点。
  static const CoverCropAlignment center = CoverCropAlignment(0.0, 0.0);

  /// 水平重心（`-1.0` 靠左，`1.0` 靠右）。
  final double x;

  /// 垂直重心（`-1.0` 靠上，`1.0` 靠下）。
  final double y;

  @override
  bool operator ==(Object other) =>
      other is CoverCropAlignment && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(x, y);
}

/// 基于显著性梯度与二次元肤色重心的封面智能构图核心计算（零外部视觉推理依赖）。
abstract final class SmartCoverFraming {
  /// 若图像横竖比例差在安全阈值内（小于 `1.22`），返回中心对齐避免过度偏移。
  static const double minCropRatioThreshold = 1.22;

  /// 根据编码图像字节在后台提取归一化对齐重心。
  static Future<CoverCropAlignment> computeAlignmentFromBytes(
    Uint8List encodedBytes,
  ) async {
    if (encodedBytes.isEmpty) return CoverCropAlignment.center;
    ui.Codec? codec;
    ui.Image? image;
    try {
      codec = await ui.instantiateImageCodec(
        encodedBytes,
        targetWidth: 64,
        targetHeight: 64,
      );
      final frame = await codec.getNextFrame();
      image = frame.image;
      final byteData = await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      if (byteData == null) return CoverCropAlignment.center;
      final rgba = byteData.buffer.asUint8List(
        byteData.offsetInBytes,
        byteData.lengthInBytes,
      );
      final w = image.width;
      final h = image.height;
      return await Isolate.run(() => computeAlignmentFromRgba(rgba, w, h));
    } catch (_) {
      return CoverCropAlignment.center;
    } finally {
      image?.dispose();
      codec?.dispose();
    }
  }

  /// 纯 `Isolate` 执行 64×64 低分辨率像素边缘梯度 + 肤色高光检测 + 切头惩罚，返回安全归一化焦点。
  static CoverCropAlignment computeAlignmentFromRgba(
    Uint8List rgba,
    int width,
    int height,
  ) {
    if (width < 4 || height < 4 || rgba.lengthInBytes < width * height * 4) {
      return CoverCropAlignment.center;
    }

    final luma = Float64List(width * height);
    final skinMask = Uint8List(width * height);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final idx = y * width + x;
        final off = idx * 4;
        final r = rgba[off];
        final g = rgba[off + 1];
        final b = rgba[off + 2];
        final a = rgba[off + 3];
        if (a < 100) {
          luma[idx] = 0.0;
          continue;
        }
        luma[idx] = 0.299 * r + 0.587 * g + 0.114 * b;
        if (_isLikelyAnimeSkinOrHairHighlight(r, g, b)) {
          skinMask[idx] = 1;
        }
      }
    }

    var weightedX = 0.0;
    var weightedY = 0.0;
    var totalWeight = 0.0;
    var skinCount = 0;

    for (var y = 1; y < height - 1; y++) {
      for (var x = 1; x < width - 1; x++) {
        final idx = y * width + x;
        final gx = (luma[idx + 1] - luma[idx - 1]).abs();
        final gy = (luma[idx + width] - luma[idx - width]).abs();
        var weight = math.sqrt(gx * gx + gy * gy) * 0.5;

        if (skinMask[idx] == 1) {
          weight += 42.0;
          skinCount++;
        }

        // 上半区权重微升，规避封面角色头顶在宽屏裁切时被截断。
        final normY = y / (height - 1);
        if (normY < 0.45) {
          weight *= 1.18;
        } else if (normY > 0.78) {
          weight *= 0.65;
        }

        if (weight > 8.0) {
          weightedX += (x / (width - 1)) * weight;
          weightedY += normY * weight;
          totalWeight += weight;
        }
      }
    }

    if (totalWeight <= 1e-3) {
      return CoverCropAlignment.center;
    }

    final cx = (weightedX / totalWeight) * 2.0 - 1.0;
    var cy = (weightedY / totalWeight) * 2.0 - 1.0;

    // 检测到明显人像区域时将焦点适度上拉保护头肩区域。
    if (skinCount >= 10) {
      cy = math.min(cy, -0.18);
    }

    return CoverCropAlignment(
      cx.clamp(-0.65, 0.65),
      cy.clamp(-0.72, 0.45),
    );
  }

  static bool _isLikelyAnimeSkinOrHairHighlight(int r, int g, int b) {
    if (r < 145 || g < 105 || b < 85) return false;
    final rg = r - g;
    final gb = g - b;
    return rg >= 8 && rg <= 90 && gb >= -12 && gb <= 75;
  }
}

/// 封面智能构图对齐结果内存缓存（淘汰上限与并发去重，零状态框架依赖）。
class SmartCoverAlignmentCache {
  /// 最大条目上限。
  static const int maxEntries = 192;

  final LinkedHashMap<String, CoverCropAlignment> _cache = LinkedHashMap();
  final Map<String, Future<CoverCropAlignment>> _inFlight = {};

  /// 同步命中已计算的重心偏移。
  CoverCropAlignment? peek(String key) {
    final hit = _cache.remove(key);
    if (hit != null) {
      _cache[key] = hit;
    }
    return hit;
  }

  /// 获取或异步提炼封面裁切安全焦点。
  Future<CoverCropAlignment> getOrCompute(String key, Uint8List encodedBytes) {
    final cached = peek(key);
    if (cached != null) return Future.value(cached);

    final pending = _inFlight[key];
    if (pending != null) return pending;

    final future = SmartCoverFraming.computeAlignmentFromBytes(encodedBytes)
        .then((alignment) {
          if (_cache.length >= maxEntries) {
            _cache.remove(_cache.keys.first);
          }
          _cache[key] = alignment;
          return alignment;
        })
        .whenComplete(() {
          _inFlight.remove(key);
        });
    _inFlight[key] = future;
    return future;
  }

  /// 清空构图对齐缓存。
  void clear() {
    _cache.clear();
  }
}
