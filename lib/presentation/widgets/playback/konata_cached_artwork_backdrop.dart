import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../application/playback/audio_playback_notifier.dart';
import '../../../application/providers/artwork_provider.dart';
import '../../theme/konata_palette.dart';
import '../../theme/konata_playback_tokens.dart';
import '../managed_image.dart';

/// 全端同源的静态缓存三层封面背景（供全屏音乐页与视频后台纯音频模式复用）。
///
/// 三层合成结构：
/// 1. 封面高饱和采样主色底布；
/// 2. 切歌时离屏烘焙并按曲目缓存的静态高模糊封面纹理（避免逐帧实时模糊开销）；
/// 3. 透明度 `0.48 ~ 0.56`（严格处于 `0.4 ~ 0.6` 区间）的主题表面遮罩，铺满系统安全区。
class KonataCachedArtworkBackdrop extends ConsumerStatefulWidget {
  /// 创建静态缓存三层封面背景。
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
    extends ConsumerState<KonataCachedArtworkBackdrop> {
  static final Map<String, List<Color>> _paletteCache = {};
  static final Map<String, ui.Image> _blurredImageCache = {};
  static const int _maxPaletteCacheEntries = 32;
  static const int _maxBlurredImageCacheEntries = 12;

  List<Color> _glowColors = const [
    KonataPlaybackTokens.auroraDefaultGlowA,
    KonataPlaybackTokens.auroraDefaultGlowB,
    KonataPlaybackTokens.auroraDefaultGlowC,
  ];
  ui.Image? _bakedBlurredImage;
  String _sampledKey = '';
  int _sampleEpoch = 0;

  @override
  void initState() {
    super.initState();
    _scheduleSampleAndBake();
  }

  @override
  void didUpdateWidget(covariant KonataCachedArtworkBackdrop oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_coverKey(oldWidget.cover) != _coverKey(widget.cover)) {
      _scheduleSampleAndBake();
    }
  }

  String _coverKey(AudioCoverSource cover) {
    return switch (cover) {
      MemoryAudioCover() => 'mem:${cover.bytes.length}:${cover.contentHash}',
      ManagedPosterAudioCover(:final url, :final workId, :final revision) =>
        'url:$workId:$url#$revision',
      EmptyAudioCover() => 'empty',
    };
  }

  Future<void> _scheduleSampleAndBake() async {
    final key = _coverKey(widget.cover);
    if (key == _sampledKey) return;
    _sampledKey = key;
    final epoch = ++_sampleEpoch;

    if (widget.cover is EmptyAudioCover) {
      if (mounted) {
        setState(() {
          _bakedBlurredImage = null;
          _glowColors = const [
            KonataPlaybackTokens.auroraDefaultGlowA,
            KonataPlaybackTokens.auroraDefaultGlowB,
            KonataPlaybackTokens.auroraDefaultGlowC,
          ];
        });
      }
      return;
    }

    final cachedPalette = _paletteCache[key];
    final cachedBlurred = _blurredImageCache[key];
    if (cachedPalette != null && cachedBlurred != null) {
      if (mounted) {
        setState(() {
          _glowColors = cachedPalette;
          _bakedBlurredImage = cachedBlurred;
        });
      }
      return;
    }
    if (cachedPalette != null && mounted) {
      setState(() => _glowColors = cachedPalette);
    }

    Uint8List? bytes;
    switch (widget.cover) {
      case MemoryAudioCover(bytes: final mem):
        bytes = mem;
      case ManagedPosterAudioCover(:final url):
        try {
          final loader = ref.read(tmdbImageLoaderProvider);
          bytes = await loader(url, targetWidth: 160);
        } catch (_) {}
      case EmptyAudioCover():
        return;
    }
    if (bytes == null || bytes.isEmpty || !mounted || epoch != _sampleEpoch) {
      return;
    }

    final palette = cachedPalette ?? await _extractAuroraPalette(bytes);
    if (!mounted || epoch != _sampleEpoch) return;
    if (palette != null && cachedPalette == null) {
      _paletteCache.remove(key);
      _paletteCache[key] = palette;
      while (_paletteCache.length > _maxPaletteCacheEntries) {
        _paletteCache.remove(_paletteCache.keys.first);
      }
    }

    final baked = cachedBlurred ?? await _bakeStaticBlurredCover(bytes);
    if (!mounted || epoch != _sampleEpoch) {
      baked?.dispose();
      return;
    }
    if (baked != null && cachedBlurred == null) {
      _blurredImageCache.remove(key)?.dispose();
      _blurredImageCache[key] = baked;
      while (_blurredImageCache.length > _maxBlurredImageCacheEntries) {
        final oldestKey = _blurredImageCache.keys.first;
        final evicted = _blurredImageCache.remove(oldestKey);
        evicted?.dispose();
      }
    }

    setState(() {
      if (palette != null) _glowColors = palette;
      _bakedBlurredImage = baked;
    });
  }

  static Future<ui.Image?> _bakeStaticBlurredCover(Uint8List bytes) async {
    try {
      const targetDim = 160;
      final codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: targetDim,
        targetHeight: targetDim,
      );
      final frame = await codec.getNextFrame();
      final srcImage = frame.image;

      const outDim = 192;
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(
        recorder,
        Rect.fromLTWH(0, 0, outDim.toDouble(), outDim.toDouble()),
      );
      final paint = Paint()
        ..filterQuality = FilterQuality.low
        ..colorFilter = ColorFilter.matrix(_saturationBoostMatrix(1.36))
        ..imageFilter = ui.ImageFilter.blur(
          sigmaX: 22.0,
          sigmaY: 22.0,
          tileMode: TileMode.clamp,
        );
      // 适度外扩绘制消除高斯模糊边缘采样衰减
      final srcRect = Rect.fromLTWH(
        0,
        0,
        srcImage.width.toDouble(),
        srcImage.height.toDouble(),
      );
      const dstRect = Rect.fromLTWH(-24, -24, outDim + 48.0, outDim + 48.0);
      canvas.drawImageRect(srcImage, srcRect, dstRect, paint);

      final picture = recorder.endRecording();
      final baked = await picture.toImage(outDim, outDim);
      picture.dispose();
      srcImage.dispose();
      codec.dispose();
      return baked;
    } catch (_) {
      return null;
    }
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

  static List<double> _saturationBoostMatrix(double saturation) {
    const lumR = 0.2126;
    const lumG = 0.7152;
    const lumB = 0.0722;
    final inv = 1.0 - saturation;
    final r = lumR * inv;
    final g = lumG * inv;
    final b = lumB * inv;
    return [
      r + saturation,
      g,
      b,
      0,
      0,
      r,
      g + saturation,
      b,
      0,
      0,
      r,
      g,
      b + saturation,
      0,
      0,
      0,
      0,
      0,
      1,
      0,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final c1 = _glowColors[0];
    final c2 = _glowColors[1];
    final c3 = _glowColors[2];
    final scrimBase = KonataPlaybackTokens.detailScrimBase(p);
    final scrimAlpha = p.isDark
        ? KonataPlaybackTokens.auroraScrimDarkAlpha
        : KonataPlaybackTokens.auroraScrimLightAlpha;

    Widget? blurredCoverLayer;
    if (_bakedBlurredImage != null) {
      blurredCoverLayer = Opacity(
        opacity: 0.76,
        child: RawImage(
          image: _bakedBlurredImage,
          fit: BoxFit.cover,
          width: double.infinity,
          height: double.infinity,
          filterQuality: FilterQuality.medium,
        ),
      );
    } else {
      final loader = ref.watch(tmdbImageLoaderProvider);
      Widget? fallbackArt;
      switch (widget.cover) {
        case MemoryAudioCover(:final bytes):
          fallbackArt = Image.memory(
            bytes,
            fit: BoxFit.cover,
            width: double.infinity,
            height: double.infinity,
            gaplessPlayback: true,
          );
        case ManagedPosterAudioCover(:final url, :final workId, :final revision):
          fallbackArt = ManagedImage(
            url,
            key: ValueKey('imm_bg_${workId}_${url}_$revision'),
            loader: loader,
            owner: workId,
            fit: BoxFit.cover,
            decodeWidth: 256,
            width: double.infinity,
            height: double.infinity,
            errorBuilder: (_, _, _) => const SizedBox.shrink(),
          );
        case EmptyAudioCover():
          fallbackArt = null;
      }
      if (fallbackArt != null) {
        blurredCoverLayer = Transform.scale(
          scale: 1.24,
          child: Opacity(
            opacity: 0.72,
            child: ImageFiltered(
              imageFilter: ui.ImageFilter.blur(
                sigmaX: KonataPlaybackTokens.auroraBlurSigma,
                sigmaY: KonataPlaybackTokens.auroraBlurSigma,
              ),
              child: fallbackArt,
            ),
          ),
        );
      }
    }

    return RepaintBoundary(
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 第一层：封面主色采样底布
          ColoredBox(color: KonataPlaybackTokens.auroraCanvas(p)),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: const Alignment(-0.55, -0.35),
                radius: 1.05,
                colors: [c1.withValues(alpha: 0.80), Colors.transparent],
              ),
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: const Alignment(0.60, 0.20),
                radius: 1.0,
                colors: [c2.withValues(alpha: 0.66), Colors.transparent],
              ),
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: const Alignment(-0.20, 0.75),
                radius: 0.95,
                colors: [c3.withValues(alpha: 0.58), Colors.transparent],
              ),
            ),
          ),
          // 第二层：切歌静态缓存的高模糊封面
          ?blurredCoverLayer,
          // 第三层：0.4 ~ 0.6 区间透明度表面遮罩（全幅覆盖含系统状态栏与手势安全区）
          ColoredBox(color: scrimBase.withValues(alpha: scrimAlpha)),
        ],
      ),
    );
  }
}
