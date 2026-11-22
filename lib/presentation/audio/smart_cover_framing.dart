import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/playback/audio_playback_notifier.dart';
import '../widgets/managed_image.dart';

/// 封面智能框选对齐锚点 LRU 缓存（由 Riverpod 托管，消除静态全局状态）。
class SmartCoverAlignmentCache {
  static const int _maxCacheEntries = 64;
  final Map<String, Alignment> _entries = <String, Alignment>{};

  /// 同步读取已缓存的对齐锚点。
  Alignment? peek(String key) => _entries[key];

  /// 写入对齐锚点并在超出容量时按 FIFO 淘汰最早条目。
  void put(String key, Alignment alignment) {
    _entries.remove(key);
    _entries[key] = alignment;
    while (_entries.length > _maxCacheEntries) {
      _entries.remove(_entries.keys.first);
    }
  }
}

/// 音频封面智能框选缓存 Provider。
final smartCoverAlignmentCacheProvider = Provider<SmartCoverAlignmentCache>(
  (ref) => SmartCoverAlignmentCache(),
);

/// 音频封面智能主体框选算法（离线毫秒级边缘梯度 + 面部暖肤色显著度 + 防切头惩罚）。
///
/// 解决将 `2:3` 竖版动漫海报或宽幅扫图裁入 `1:1` 正方形 CD 封面框时，默认居中裁剪截断角色头部的问题。
abstract final class SmartCoverFraming {
  /// 竖版作品海报在采样完成前的黄金上偏保护锚点（优先完整保留上方角色头部与面部）。
  static const Alignment defaultPosterAlignment = Alignment(0.0, -0.72);

  /// 生成封面唯一缓存键。
  static String cacheKeyFor(AudioCoverSource cover) {
    return switch (cover) {
      MemoryAudioCover(:final bytes, :final contentHash) =>
        'mem:${bytes.length}:$contentHash',
      ManagedPosterAudioCover(:final url, :final workId, :final revision) =>
        'poster:$workId:$url#$revision',
      EmptyAudioCover() => 'empty',
    };
  }

  /// 对封面字节进行快速低分辨率显著度分析，计算最佳 `1:1` 正方形取景对齐锚点。
  static Future<Alignment> computeAndCache(
    String key,
    Uint8List bytes, {
    required bool isPosterFallback,
    SmartCoverAlignmentCache? cache,
  }) async {
    final existing = cache?.peek(key);
    if (existing != null) return existing;

    final fallback = isPosterFallback
        ? defaultPosterAlignment
        : Alignment.center;
    if (bytes.length < 32) {
      return fallback;
    }

    ui.Codec? codec;
    ui.FrameInfo? frame;
    try {
      codec = await ui.instantiateImageCodec(bytes, targetWidth: 72);
      frame = await codec.getNextFrame();
      final img = frame.image;
      final w = img.width;
      final h = img.height;
      if (w <= 4 || h <= 4) {
        return fallback;
      }

      final aspect = w / h;
      // 本身接近 1:1 的标准专辑封面无需偏移，直接正中对齐
      if (aspect >= 0.91 && aspect <= 1.10) {
        cache?.put(key, Alignment.center);
        return Alignment.center;
      }

      final bd = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (bd == null) {
        return fallback;
      }
      final rgba = bd.buffer.asUint8List();

      final Alignment resolved = aspect < 0.91
          ? _solveVerticalWindow(rgba, w, h)
          : _solveHorizontalWindow(rgba, w, h);
      cache?.put(key, resolved);
      return resolved;
    } catch (_) {
      return fallback;
    } finally {
      frame?.image.dispose();
      codec?.dispose();
    }
  }

  /// 竖图（如 2:3 海报）垂直滑窗寻优：最大化框内主体细节与面部权重，严厉惩罚切断上方角色头部。
  static Alignment _solveVerticalWindow(Uint8List rgba, int w, int h) {
    final winH = w;
    final maxTop = h - winH;
    if (maxTop <= 0) return Alignment.center;

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
    return Alignment(0.0, rawAlignY.clamp(-1.0, 0.65));
  }

  /// 横图（如双页展开 Booklet 扫图）水平滑窗寻优：锁定人物主封皮所在侧。
  static Alignment _solveHorizontalWindow(Uint8List rgba, int w, int h) {
    final winW = h;
    final maxLeft = w - winW;
    if (maxLeft <= 0) return Alignment.center;

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
    return Alignment(rawAlignX.clamp(-1.0, 1.0), 0.0);
  }
}

/// 响应式封面智能框选对齐构建器（供全屏流光大封面、镜像倒影与迷你栏缩略图统一复用）。
class SmartCoverAlignmentBuilder extends ConsumerStatefulWidget {
  /// 创建智能框选对齐构建器。
  const SmartCoverAlignmentBuilder({
    super.key,
    required this.cover,
    required this.loader,
    required this.builder,
  });

  /// 当前音频封面源。
  final AudioCoverSource cover;

  /// 受管海报字节加载器。
  final ManagedImageLoader loader;

  /// 携带解析出的最佳 [Alignment] 构建封面组件。
  final Widget Function(BuildContext context, Alignment alignment) builder;

  @override
  ConsumerState<SmartCoverAlignmentBuilder> createState() =>
      _SmartCoverAlignmentBuilderState();
}

class _SmartCoverAlignmentBuilderState
    extends ConsumerState<SmartCoverAlignmentBuilder> {
  late String _activeKey;
  late Alignment _alignment;
  int _epoch = 0;

  @override
  void initState() {
    super.initState();
    _syncCover(initial: true);
  }

  @override
  void didUpdateWidget(covariant SmartCoverAlignmentBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (SmartCoverFraming.cacheKeyFor(oldWidget.cover) !=
        SmartCoverFraming.cacheKeyFor(widget.cover)) {
      _syncCover(initial: false);
    }
  }

  void _syncCover({required bool initial}) {
    final cache = ref.read(smartCoverAlignmentCacheProvider);
    final key = SmartCoverFraming.cacheKeyFor(widget.cover);
    _activeKey = key;
    final cached = cache.peek(key);
    final nextInitial =
        cached ??
        (widget.cover is ManagedPosterAudioCover
            ? SmartCoverFraming.defaultPosterAlignment
            : Alignment.center);
    if (initial) {
      _alignment = nextInitial;
    } else if (_alignment != nextInitial) {
      setState(() => _alignment = nextInitial);
    }
    if (cached == null && widget.cover is! EmptyAudioCover) {
      unawaited(_resolveAsync(key, ++_epoch, cache));
    }
  }

  Future<void> _resolveAsync(
    String key,
    int epoch,
    SmartCoverAlignmentCache cache,
  ) async {
    Uint8List? bytes;
    var isPoster = false;
    switch (widget.cover) {
      case MemoryAudioCover(bytes: final mem):
        bytes = mem;
      case ManagedPosterAudioCover(:final url):
        isPoster = true;
        try {
          bytes = await widget.loader(url, targetWidth: 160);
        } catch (_) {
          return;
        }
      case EmptyAudioCover():
        return;
    }
    if (!mounted || epoch != _epoch || key != _activeKey || bytes.isEmpty) {
      return;
    }
    final computed = await SmartCoverFraming.computeAndCache(
      key,
      bytes,
      isPosterFallback: isPoster,
      cache: cache,
    );
    if (!mounted || epoch != _epoch || key != _activeKey) return;
    if ((computed.x - _alignment.x).abs() > 0.01 ||
        (computed.y - _alignment.y).abs() > 0.01) {
      setState(() => _alignment = computed);
    }
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _alignment);
}
