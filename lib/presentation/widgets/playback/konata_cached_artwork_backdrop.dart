import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../application/playback/artwork_palette_service.dart';
import '../../../application/playback/audio_playback_notifier.dart';
import '../../../application/playback/unified_playback_engine.dart';
import '../../../application/providers/artwork_provider.dart';
import '../../../application/providers/diagnostics_providers.dart';
import '../../theme/konata_palette.dart';
import '../../theme/konata_playback_tokens.dart';

/// 全端同源的 0 MB 模糊位图显存 GPU 径向流光舞台背景（供全屏音乐页与视频后台纯音频模式复用）。
///
/// 架构特性：
/// 1. 仅采样极小 `24×24` 封面 RGBA 像素后立即释放图像，并在后台 `Isolate` 完成三色聚类，全程 **0 MB 离屏模糊位图显存占用**；
/// 2. 通过 `UnifiedPlaybackEngine` 的 `PlaybackTaskDomain.artworkColor` 分域令牌取消陈旧色板任务，色板 LRU 缓存由 Riverpod 托管；
/// 3. 通过 `CustomPainter` + 多源 `ui.Gradient.radial` GPU 径向着色场直接渲染柔和层次光晕；
/// 4. 切歌时仅执行一次 `800 ms` 有界色板过渡，到位立即停钟（`No Idle Tickers`），播放进度跳动 0 重绘。
class KonataCachedArtworkBackdrop extends ConsumerStatefulWidget {
  /// 创建 0 MB 显存 GPU 径向流光舞台背景。
  const KonataCachedArtworkBackdrop({super.key, required this.cover});

  /// 当前曲目或作品封面源。
  final AudioCoverSource cover;

  @override
  ConsumerState<KonataCachedArtworkBackdrop> createState() =>
      _KonataCachedArtworkBackdropState();
}

class _KonataCachedArtworkBackdropState
    extends ConsumerState<KonataCachedArtworkBackdrop>
    with SingleTickerProviderStateMixin {
  static const List<Color> _defaultPalette = [
    KonataPlaybackTokens.auroraDefaultGlowA,
    KonataPlaybackTokens.auroraDefaultGlowB,
    KonataPlaybackTokens.auroraDefaultGlowC,
  ];

  late final AnimationController _colorTransitionCtrl;
  List<Color> _fromColors = _defaultPalette;
  List<Color> _toColors = _defaultPalette;
  String _sampledKey = '';
  UnifiedPlaybackEngine? _boundEngine;
  ScopedTaskToken? _activeColorToken;

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
    final token = _activeColorToken;
    final engine = _boundEngine;
    _activeColorToken = null;
    _boundEngine = null;
    if (token != null && engine != null && engine.isTaskAlive(token)) {
      engine.cancelTaskDomain(PlaybackTaskDomain.artworkColor);
    }
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

    final engine = ref.read(unifiedPlaybackEngineProvider);
    final logStore = ref.read(diagnosticsLogStoreProvider);
    _boundEngine = engine;
    final token = engine.acquireTaskToken(PlaybackTaskDomain.artworkColor);
    _activeColorToken = token;

    if (widget.cover is EmptyAudioCover) {
      _transitionToPalette(_defaultPalette);
      return;
    }

    final paletteCache = ref.read(artworkPaletteCacheProvider);
    final cachedPalette = paletteCache.get(key);
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
        } catch (e) {
          logStore.record('ARTWORK', '拉取流光背景封面缩略图失败：$e', isError: true);
        }
      case EmptyAudioCover():
        return;
    }
    if (bytes == null || bytes.isEmpty || !mounted || !engine.isTaskAlive(token)) {
      return;
    }

    final rgbaBytes = await _decodeTinyRgba(
      bytes,
      (message) => logStore.record('ARTWORK', message, isError: true),
    );
    if (rgbaBytes == null || !mounted || !engine.isTaskAlive(token)) {
      return;
    }

    final palette = await extractAuroraPaletteInIsolate(rgbaBytes);
    if (!mounted || !engine.isTaskAlive(token) || palette == null) return;

    paletteCache.put(key, palette);
    _transitionToPalette(palette);
  }

  Future<Uint8List?> _decodeTinyRgba(
    Uint8List bytes,
    void Function(String message) onError,
  ) async {
    ui.Codec? codec;
    ui.FrameInfo? frame;
    try {
      codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: 24,
        targetHeight: 24,
      );
      frame = await codec.getNextFrame();
      final bd = await frame.image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      if (bd == null) return null;
      return Uint8List.fromList(
        bd.buffer.asUint8List(bd.offsetInBytes, bd.lengthInBytes),
      );
    } catch (e) {
      onError('解码流光背景采样帧失败：$e');
      return null;
    } finally {
      frame?.image.dispose();
      codec?.dispose();
    }
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
