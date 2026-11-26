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
  /// 海报尚未完成采样时使用上偏保护锚点。
  static const CoverCropAlignment defaultPosterAlignment = CoverCropAlignment(
    0,
    -0.72,
  );

  /// 保留图像比例，以低分辨率像素滑窗计算方形取景位置。
  static Future<CoverCropAlignment> computeAlignmentFromBytes(
    Uint8List encodedBytes, {
    bool isPosterFallback = false,
  }) async {
    final fallback = isPosterFallback
        ? defaultPosterAlignment
        : CoverCropAlignment.center;
    if (encodedBytes.isEmpty) return fallback;
    ui.Codec? codec;
    ui.Image? image;
    try {
      codec = await ui.instantiateImageCodec(
        encodedBytes,
        targetWidth: 72,
        allowUpscaling: false,
      );
      image = (await codec.getNextFrame()).image;
      final bd = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (bd == null) return fallback;
      final rgba = bd.buffer.asUint8List(bd.offsetInBytes, bd.lengthInBytes);
      final w = image.width;
      final h = image.height;
      return await Isolate.run(() => computeAlignmentFromRgba(rgba, w, h));
    } catch (_) {
      return fallback;
    } finally {
      image?.dispose();
      codec?.dispose();
    }
  }

  /// 只生成内存中的方形海报副本，所有播放器形态与原生媒体通知共用，不改写源图。
  static Future<Uint8List?> cropPosterToSquare(Uint8List bytes) async {
    if (bytes.isEmpty) return null;
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    ui.Image? source;
    ui.Picture? picture;
    ui.Image? square;
    try {
      final alignment = await computeAlignmentFromBytes(
        bytes,
        isPosterFallback: true,
      );
      buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      final scale = math.min(
        1.0,
        1024 / math.max(descriptor.width, descriptor.height),
      );
      codec = await descriptor.instantiateCodec(
        targetWidth: math.max(1, (descriptor.width * scale).round()),
        targetHeight: math.max(1, (descriptor.height * scale).round()),
      );
      source = (await codec.getNextFrame()).image;
      final side = math.min(source.width, source.height).toDouble();
      final left = (source.width - side) * (alignment.x + 1) / 2;
      final top = (source.height - side) * (alignment.y + 1) / 2;
      final size = math.min(512, side.toInt());
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      canvas.drawImageRect(
        source,
        ui.Rect.fromLTWH(left, top, side, side),
        ui.Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble()),
        ui.Paint()..filterQuality = ui.FilterQuality.medium,
      );
      picture = recorder.endRecording();
      square = await picture.toImage(size, size);
      final data = await square.toByteData(format: ui.ImageByteFormat.png);
      return data?.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } catch (_) {
      return null;
    } finally {
      square?.dispose();
      picture?.dispose();
      source?.dispose();
      codec?.dispose();
      descriptor?.dispose();
      buffer?.dispose();
    }
  }

  /// 依据原始比例和上方主体切断惩罚计算取景锚点。
  static CoverCropAlignment computeAlignmentFromRgba(
    Uint8List rgba,
    int w,
    int h, {
    double targetAspectRatio = 1.0,
  }) {
    if (w <= 4 || h <= 4 || rgba.length < w * h * 4) {
      return CoverCropAlignment.center;
    }
    final safeTarget = targetAspectRatio.clamp(0.25, 4.0);
    final aspect = w / h;
    // 原图比例已接近目标画幅时直接正中对齐，避免不必要的轻微偏移。
    if ((aspect - safeTarget).abs() / safeTarget <= 0.09) {
      return CoverCropAlignment.center;
    }
    if (aspect < safeTarget) {
      final winH = (w / safeTarget).round().clamp(1, h);
      return _solveVerticalWindow(rgba, w, h, winH: winH);
    }
    final winW = (h * safeTarget).round().clamp(1, w);
    return _solveHorizontalWindow(rgba, w, h, winW: winW);
  }

  /// 竖图（如 2:3 海报）垂直滑窗寻优：最大化框内主体细节与面部权重，严厉惩罚切断上方角色头部。
  static CoverCropAlignment _solveVerticalWindow(
    Uint8List rgba,
    int w,
    int h, {
    required int winH,
  }) {
    final maxTop = h - winH;
    if (maxTop <= 0) return CoverCropAlignment.center;

    final rowEnergy = List<double>.filled(h, 0.0);
    for (var y = 0; y < h; y++) {
      final yNext = math.min(y + 1, h - 1);
      var sum = 0.0;
      for (var x = 0; x < w - 1; x++) {
        final idx = (y * w + x) * 4;
        final a = rgba[idx + 3];
        if (a < 64) continue;
        final r = rgba[idx];
        final g = rgba[idx + 1];
        final b = rgba[idx + 2];

        final idxR = idx + 4;
        final idxD = (yNext * w + x) * 4;
        final edge =
            ((r - rgba[idxR]).abs() +
                (g - rgba[idxR + 1]).abs() +
                (b - rgba[idxR + 2]).abs() +
                (r - rgba[idxD]).abs() +
                (g - rgba[idxD + 1]).abs() +
                (b - rgba[idxD + 2]).abs()) /
            (255.0 * 6.0);

        // 二次元角色面部暖肤色高明度特征加权（排除纯白背景与高饱和背景光）
        final spread = r - b;
        final isAnimeSkinTone =
            r > 155 && r >= g && g >= b && spread >= 16 && spread <= 110;
        final skinBonus = isAnimeSkinTone ? 0.16 : 0.0;

        // 水平中心区域权重略高于两侧边缘
        final xNorm = (x / w - 0.5).abs();
        final xWeight = xNorm < 0.36 ? 1.0 : 0.68;
        sum += (edge + skinBonus) * xWeight;
      }
      var normalized = sum / math.max(1, w - 1);
      // 弱化海报最底部 20% 常见版权文字/机械底座对取景框的下拽拉力
      if (y > h * 0.80) {
        normalized *= 0.42;
      }
      rowEnergy[y] = normalized;
    }

    final prefix = List<double>.filled(h + 1, 0.0);
    for (var i = 0; i < h; i++) {
      prefix[i + 1] = prefix[i] + rowEnergy[i];
    }

    // 估计顶部环境背景底噪，仅对超出背景底噪的上方主体（如头发/头顶）施加高额切头惩罚
    final topBgFloor =
        math.min(rowEnergy[0], rowEnergy[math.min(1, h - 1)]) * 0.85;

    var bestTop = 0;
    var bestScore = double.negativeInfinity;
    for (var top = 0; top <= maxTop; top++) {
      final inside = prefix[top + winH] - prefix[top];
      final rawAbove = prefix[top];
      final excessAbove = math.max(0.0, rawAbove - topBgFloor * top);
      final seamEnergy = rowEnergy[top];

      final score = inside - excessAbove * 2.45 - seamEnergy * 1.6;
      if (score > bestScore) {
        bestScore = score;
        bestTop = top;
      }
    }

    final rawAlignY = -1.0 + 2.0 * (bestTop / maxTop);
    return CoverCropAlignment(0.0, rawAlignY.clamp(-1.0, 0.65));
  }

  /// 横图（如双页展开 Booklet 扫图）水平滑窗寻优：锁定人物主封皮所在侧。
  static CoverCropAlignment _solveHorizontalWindow(
    Uint8List rgba,
    int w,
    int h, {
    required int winW,
  }) {
    final maxLeft = w - winW;
    if (maxLeft <= 0) return CoverCropAlignment.center;

    final colEnergy = List<double>.filled(w, 0.0);
    for (var x = 0; x < w; x++) {
      final xNext = math.min(x + 1, w - 1);
      var sum = 0.0;
      for (var y = 0; y < h - 1; y++) {
        final idx = (y * w + x) * 4;
        if (rgba[idx + 3] < 64) continue;
        final r = rgba[idx];
        final g = rgba[idx + 1];
        final b = rgba[idx + 2];

        final idxR = (y * w + xNext) * 4;
        final idxD = ((y + 1) * w + x) * 4;
        final edge =
            ((r - rgba[idxR]).abs() +
                (g - rgba[idxR + 1]).abs() +
                (b - rgba[idxR + 2]).abs() +
                (r - rgba[idxD]).abs() +
                (g - rgba[idxD + 1]).abs() +
                (b - rgba[idxD + 2]).abs()) /
            (255.0 * 6.0);
        final spread = r - b;
        final skinBonus =
            (r > 155 && r >= g && g >= b && spread >= 16 && spread <= 110)
            ? 0.16
            : 0.0;
        sum += edge + skinBonus;
      }
      colEnergy[x] = sum / math.max(1, h - 1);
    }

    final prefix = List<double>.filled(w + 1, 0.0);
    for (var i = 0; i < w; i++) {
      prefix[i + 1] = prefix[i] + colEnergy[i];
    }

    var bestLeft = maxLeft ~/ 2;
    var bestScore = double.negativeInfinity;
    for (var left = 0; left <= maxLeft; left++) {
      final inside = prefix[left + winW] - prefix[left];
      final seam =
          colEnergy[left] + colEnergy[math.min(w - 1, left + winW - 1)];
      final score = inside - seam * 1.2;
      if (score > bestScore) {
        bestScore = score;
        bestLeft = left;
      }
    }

    final rawAlignX = -1.0 + 2.0 * (bestLeft / maxLeft);
    return CoverCropAlignment(rawAlignX.clamp(-1.0, 1.0), 0.0);
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
