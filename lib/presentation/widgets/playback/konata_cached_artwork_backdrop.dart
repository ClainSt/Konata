import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../application/playback/audio_playback_notifier.dart';
import '../../../application/providers/artwork_provider.dart';
import '../../theme/konata_palette.dart';
import '../../theme/konata_playback_tokens.dart';

/// 全端同源的 0 MB 模糊位图显存 GPU 径向流光舞台背景（供全屏音乐页与视频后台纯音频模式复用）。
///
/// 架构特性：
/// 1. 仅从极小 `24×24` 封面采样提取三色高饱和色板后立即释放图像，全程 **0 MB 离屏模糊位图显存占用**；
/// 2. 通过 `CustomPainter` + 多源 `ui.Gradient.radial` GPU 径向着色场直接渲染柔和层次光晕；
/// 3. 切歌时仅执行一次 `800 ms` 有界色板过渡，到位立即停钟（`No Idle Tickers`），播放进度跳动 0 重绘；
/// 4. 最上层铺满透明度 `0.48 ~ 0.56` 的主题表面遮罩，覆盖系统状态栏与底部安全区。
class KonataCachedArtworkBackdrop extends ConsumerStatefulWidget {
  /// 创建 0 MB 显存 GPU 径向流光舞台背景。
  const KonataCachedArtworkBackdrop({
    super.key,
    required this.cover,
  });

  /// 当前曲目或作品封面源。
  final AudioCoverSource cover;

  @override
  ConsumerState<KonataCachedArtworkBackdrop> createState() =>
      _KonataCachedArtworkBackdropState();
}

class _KonataCachedArtworkBackdropState
    extends ConsumerState<KonataCachedArtworkBackdrop>
    with SingleTickerProviderStateMixin {
  static final Map<String, List<Color>> _paletteCache = {};
  static const int _maxPaletteCacheEntries = 32;
  static const List<Color> _defaultPalette = [
    KonataPlaybackTokens.auroraDefaultGlowA,
    KonataPlaybackTokens.auroraDefaultGlowB,
    KonataPlaybackTokens.auroraDefaultGlowC,
  ];

  late final AnimationController _colorTransitionCtrl;
  List<Color> _fromColors = _defaultPalette;
  List<Color> _toColors = _defaultPalette;
  String _sampledKey = '';
  int _sampleEpoch = 0;

  @override
  void initState() {
    super.initState();
    _colorTransitionCtrl = AnimationController(
      vsync: this,
      duration: KonataPlaybackTokens.auroraColorTransitionDuration,
      value: 1.0,
    );
    _scheduleSamplePalette();
  }

  @override
  void didUpdateWidget(covariant KonataCachedArtworkBackdrop oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_coverKey(oldWidget.cover) != _coverKey(widget.cover)) {
      _scheduleSamplePalette();
    }
  }

  @override
  void dispose() {
    _colorTransitionCtrl.dispose();
    super.dispose();
  }

  String _coverKey(AudioCoverSource cover) {
    return switch (cover) {
      MemoryAudioCover() => 'mem:${cover.bytes.length}:${cover.contentHash}',
      ManagedPosterAudioCover(:final url, :final workId, :final revision) =>
        'url:$workId:$url#$revision',
      EmptyAudioCover() => 'empty',
    };
  }

  List<Color> _currentInterpolatedColors() {
    final t = Curves.easeOutCubic.transform(_colorTransitionCtrl.value);
    return List<Color>.generate(3, (i) {
      return Color.lerp(_fromColors[i], _toColors[i], t) ?? _toColors[i];
    }, growable: false);
  }

  void _transitionToPalette(List<Color> nextColors) {
    if (!mounted) return;
    if (listEquals(_toColors, nextColors)) return;
    _fromColors = _currentInterpolatedColors();
    _toColors = List<Color>.unmodifiable(nextColors);
    // 有限 800ms 有界过渡，到达 1.0 后 AnimationController 自动停止 Ticker。
    _colorTransitionCtrl.forward(from: 0.0);
  }

  Future<void> _scheduleSamplePalette() async {
    final key = _coverKey(widget.cover);
    if (key == _sampledKey) return;
    _sampledKey = key;
    final epoch = ++_sampleEpoch;

    if (widget.cover is EmptyAudioCover) {
      _transitionToPalette(_defaultPalette);
      return;
    }

    final cachedPalette = _paletteCache[key];
    if (cachedPalette != null) {
      _transitionToPalette(cachedPalette);
      return;
    }

    Uint8List? bytes;
    switch (widget.cover) {
      case MemoryAudioCover(bytes: final mem):
        bytes = mem;
      case ManagedPosterAudioCover(:final url):
        try {
          final loader = ref.read(tmdbImageLoaderProvider);
          bytes = await loader(url, targetWidth: 64);
        } catch (_) {}
      case EmptyAudioCover():
        return;
    }
    if (bytes == null || bytes.isEmpty || !mounted || epoch != _sampleEpoch) {
      return;
    }

    final palette = await _extractAuroraPalette(bytes);
    if (!mounted || epoch != _sampleEpoch || palette == null) return;

    _paletteCache.remove(key);
    _paletteCache[key] = palette;
    while (_paletteCache.length > _maxPaletteCacheEntries) {
      _paletteCache.remove(_paletteCache.keys.first);
    }
    _transitionToPalette(palette);
  }

  static Future<List<Color>?> _extractAuroraPalette(Uint8List bytes) async {
    try {
      final codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: 24,
        targetHeight: 24,
      );
      final frame = await codec.getNextFrame();
      final bd = await frame.image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      frame.image.dispose();
      codec.dispose();
      if (bd == null) return null;

      final data = bd.buffer.asUint8List();
      final buckets = List<({int count, double r, double g, double b})>.filled(
        12,
        (count: 0, r: 0, g: 0, b: 0),
      );
      for (var i = 0; i + 3 < data.length; i += 4) {
        final a = data[i + 3];
        if (a < 140) continue;
        final r = data[i];
        final g = data[i + 1];
        final b = data[i + 2];
        final hsv = HSVColor.fromColor(Color.fromARGB(255, r, g, b));
        if (hsv.saturation < 0.14 || hsv.value < 0.12) continue;
        final bin = (hsv.hue ~/ 30).clamp(0, 11);
        final prev = buckets[bin];
        buckets[bin] = (
          count: prev.count + 1,
          r: prev.r + r,
          g: prev.g + g,
          b: prev.b + b,
        );
      }

      final ranked = <({int count, Color color})>[];
      for (final b in buckets) {
        if (b.count == 0) continue;
        final raw = Color.fromARGB(
          255,
          (b.r / b.count).round().clamp(0, 255),
          (b.g / b.count).round().clamp(0, 255),
          (b.b / b.count).round().clamp(0, 255),
        );
        final hsv = HSVColor.fromColor(raw);
        final boosted = HSVColor.fromAHSV(
          1.0,
          hsv.hue,
          hsv.saturation.clamp(0.68, 0.88),
          hsv.value.clamp(0.45, 0.65),
        ).toColor();
        ranked.add((count: b.count, color: boosted));
      }
      ranked.sort((a, b) => b.count.compareTo(a.count));
      if (ranked.isEmpty) return null;
      final c1 = ranked[0].color;
      final c2 = ranked.length > 1 ? ranked[1].color : _shiftHue(c1, 36);
      final c3 = ranked.length > 2 ? ranked[2].color : _shiftHue(c1, -42);
      return [c1, c2, c3];
    } catch (_) {
      return null;
    }
  }

  static Color _shiftHue(Color base, double delta) {
    final hsv = HSVColor.fromColor(base);
    return hsv.withHue((hsv.hue + delta) % 360.0).toColor();
  }

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
      child: AnimatedBuilder(
        animation: _colorTransitionCtrl,
        builder: (context, _) {
          final colors = _currentInterpolatedColors();
          return CustomPaint(
            painter: _AuroraRadialFieldPainter(
              baseColor: canvasBase,
              glowA: colors[0],
              glowB: colors[1],
              glowC: colors[2],
              scrimColor: scrimColor,
            ),
            child: const SizedBox.expand(),
          );
        },
      ),
    );
  }
}

/// 纯 GPU 多源 `ui.Gradient.radial` 径向流光着色场画师（零位图分配、零显存滞留）。
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

    // 1. 主题底布
    canvas.drawRect(rect, Paint()..color = baseColor);

    // 2. 四源 GPU 径向着色场（左上主色、右中次色、左下辅色与中心柔光弥散）
    final blendMid = Color.lerp(glowA, glowB, 0.5) ?? glowA;
    final sources = <({Offset center, double radius, Color color, double alpha})>[
      (
        center: Offset(size.width * 0.22, size.height * 0.28),
        radius: maxDim * 0.78,
        color: glowA,
        alpha: 0.82,
      ),
      (
        center: Offset(size.width * 0.80, size.height * 0.56),
        radius: maxDim * 0.74,
        color: glowB,
        alpha: 0.70,
      ),
      (
        center: Offset(size.width * 0.36, size.height * 0.86),
        radius: maxDim * 0.70,
        color: glowC,
        alpha: 0.62,
      ),
      (
        center: Offset(size.width * 0.58, size.height * 0.22),
        radius: maxDim * 0.60,
        color: blendMid,
        alpha: 0.42,
      ),
    ];

    for (final src in sources) {
      final paint = Paint()
        ..shader = ui.Gradient.radial(
          src.center,
          src.radius,
          [
            src.color.withValues(alpha: src.alpha),
            src.color.withValues(alpha: src.alpha * 0.36),
            Colors.transparent,
          ],
          const [0.0, 0.48, 1.0],
        );
      canvas.drawRect(rect, paint);
    }

    // 3. 主题表面遮罩（0.48 / 0.56 保障前景文字与封面高对比度）
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
