import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_design_system/konata_design_system.dart';

import '../data/data.dart';

/// 基于封面聚类色板的三点式低功耗径向流光舞台背景（无高开销逐帧全屏着色器）。
class AudioAuroraBackdrop extends StatefulWidget {
  /// 创建流光背景视图。
  const AudioAuroraBackdrop({
    super.key,
    required this.cover,
    required this.coverVariantTag,
    required this.paletteCache,
    required this.child,
  });

  /// 当前生效封面来源。
  final AudioCoverSource cover;

  /// 用于缓存命中与动画去重的封面版本标记。
  final String? coverVariantTag;

  /// 封面聚类色板缓存。
  final ArtworkPaletteCache paletteCache;

  /// 前景舞台内容。
  final Widget child;

  @override
  State<AudioAuroraBackdrop> createState() => _AudioAuroraBackdropState();
}

class _AudioAuroraBackdropState extends State<AudioAuroraBackdrop> {
  ArtworkAuroraPalette _palette = ArtworkAuroraPalette.fallback;
  String? _activeKey;

  @override
  void initState() {
    super.initState();
    _resolvePaletteIfNeeded();
  }

  @override
  void didUpdateWidget(covariant AudioAuroraBackdrop oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.coverVariantTag != widget.coverVariantTag ||
        !identical(oldWidget.cover, widget.cover)) {
      _resolvePaletteIfNeeded();
    }
  }

  void _resolvePaletteIfNeeded() {
    final cover = widget.cover;
    final key = widget.coverVariantTag ?? '';
    if (cover is! MemoryAudioCover || cover.bytes.isEmpty || key.isEmpty) {
      _activeKey = null;
      if (_palette != ArtworkAuroraPalette.fallback) {
        setState(() {
          _activeKey = null;
          _palette = ArtworkAuroraPalette.fallback;
        });
      }
      return;
    }
    if (_activeKey == key) return;
    _activeKey = key;

    final syncHit = widget.paletteCache.peek(key);
    if (syncHit != null) {
      if (_palette != syncHit) {
        setState(() {
          _palette = syncHit;
        });
      }
      return;
    }

    unawaited(
      widget.paletteCache.getOrExtract(key, cover.bytes).then((palette) {
        if (!mounted || _activeKey != key) return;
        if (_palette != palette) {
          setState(() {
            _palette = palette;
          });
        }
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final q1 = Color(_palette.quadrantTopLeftArgb);
    final q2 = Color(_palette.quadrantTopRightArgb);
    final q3 = Color(_palette.quadrantBottomLeftArgb);
    final q4 = Color(_palette.quadrantBottomRightArgb);
    final accent = Color(_palette.accentArgb);
    final tint = Color(_palette.surfaceTintArgb);
    // 恒定电影感深邃暗基底（#0E0B12），严禁随外部浅色主题漂白。
    final baseBg = Color.lerp(const Color(0xFF0E0B12), tint, 0.18)!;

    return RepaintBoundary(
      child: AnimatedContainer(
        key: const ValueKey('salt_audio_aurora_backdrop'),
        duration: const Duration(milliseconds: 520),
        curve: Curves.easeOutCubic,
        color: baseBg,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // 象限 1：左上高饱和丝绒色点。
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(-0.78, -0.72),
                  radius: 1.05,
                  colors: [
                    q1.withValues(alpha: 0.56),
                    q1.withValues(alpha: 0.16),
                    Colors.transparent,
                  ],
                  stops: const [0.0, 0.46, 1.0],
                ),
              ),
            ),
            // 象限 2：右上高饱和丝绒色点。
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(0.76, -0.68),
                  radius: 1.02,
                  colors: [
                    q2.withValues(alpha: 0.48),
                    q2.withValues(alpha: 0.12),
                    Colors.transparent,
                  ],
                  stops: const [0.0, 0.48, 1.0],
                ),
              ),
            ),
            // 象限 3：左下高饱和丝绒色点。
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(-0.72, 0.74),
                  radius: 1.05,
                  colors: [
                    q3.withValues(alpha: 0.44),
                    q3.withValues(alpha: 0.10),
                    Colors.transparent,
                  ],
                  stops: const [0.0, 0.50, 1.0],
                ),
              ),
            ),
            // 象限 4：右下高饱和丝绒色点。
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(0.76, 0.72),
                  radius: 1.10,
                  colors: [
                    q4.withValues(alpha: 0.52),
                    q4.withValues(alpha: 0.14),
                    Colors.transparent,
                  ],
                  stops: const [0.0, 0.50, 1.0],
                ),
              ),
            ),
            // 中景温和呼吸点亮晕，承托透明玻璃胶囊与纯白歌词发光层。
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(0.0, -0.08),
                  radius: 0.88,
                  colors: [accent.withValues(alpha: 0.14), Colors.transparent],
                  stops: const [0.0, 1.0],
                ),
              ),
            ),
            // 四角柔和收边暗晕，塑造电影感暗房景深与边界收敛。
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: Alignment.center,
                  radius: 1.15,
                  colors: [
                    Colors.transparent,
                    Colors.black.withValues(alpha: 0.22),
                    Colors.black.withValues(alpha: 0.52),
                  ],
                  stops: const [0.35, 0.78, 1.0],
                ),
              ),
            ),
            // 上下暗幕保护层，确保纯白顶栏与底部烟熏玻璃播控胶囊高对比度可读。
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.18),
                    Colors.black.withValues(alpha: 0.14),
                    Colors.black.withValues(alpha: 0.42),
                  ],
                ),
              ),
            ),
            widget.child,
          ],
        ),
      ),
    );
  }
}

/// 根据图像显著性重心异步对齐封面的裁切辅助包装组件。
class SmartCoverAlignmentBuilder extends StatefulWidget {
  /// 构造智能裁切构建器。
  const SmartCoverAlignmentBuilder({
    super.key,
    required this.coverKey,
    required this.bytes,
    required this.cache,
    required this.builder,
  });

  /// 缓存定位键。
  final String? coverKey;

  /// 图片原始字节。
  final Uint8List? bytes;

  /// 智能裁切结果缓存。
  final SmartCoverAlignmentCache cache;

  /// 子节点构建器，接收已插值的 [AlignmentGeometry]。
  final Widget Function(BuildContext context, Alignment alignment) builder;

  @override
  State<SmartCoverAlignmentBuilder> createState() =>
      _SmartCoverAlignmentBuilderState();
}

class _SmartCoverAlignmentBuilderState
    extends State<SmartCoverAlignmentBuilder> {
  Alignment _alignment = Alignment.center;
  String? _lastKey;

  @override
  void initState() {
    super.initState();
    _syncAlignment();
  }

  @override
  void didUpdateWidget(covariant SmartCoverAlignmentBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.coverKey != widget.coverKey ||
        !identical(oldWidget.bytes, widget.bytes)) {
      _syncAlignment();
    }
  }

  void _syncAlignment() {
    final key = widget.coverKey ?? '';
    final bytes = widget.bytes;
    if (key.isEmpty || bytes == null || bytes.isEmpty) {
      if (_alignment != Alignment.center) {
        setState(() {
          _lastKey = null;
          _alignment = Alignment.center;
        });
      }
      return;
    }
    if (_lastKey == key) return;
    _lastKey = key;

    final hit = widget.cache.peek(key);
    if (hit != null) {
      final next = Alignment(hit.x, hit.y);
      if (_alignment != next) {
        setState(() => _alignment = next);
      }
      return;
    }

    unawaited(
      widget.cache.getOrCompute(key, bytes).then((resolved) {
        if (!mounted || _lastKey != key) return;
        final next = Alignment(resolved.x, resolved.y);
        if (_alignment != next) {
          setState(() => _alignment = next);
        }
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    return widget.builder(context, _alignment);
  }
}

/// 统一渲染内存字节封面、作品托管海报或极简唱片占位的音频专辑图组件。
class AudioCoverArtworkView extends StatelessWidget {
  /// 构造统一音频封面图视图。
  const AudioCoverArtworkView({
    super.key,
    required this.cover,
    this.coverKey,
    this.alignmentCache,
    this.borderRadius = 18.0,
    this.fit = BoxFit.cover,
    this.discLabel = 'CD',
    this.showBorder = false,
  });

  /// 封面数据来源。
  final AudioCoverSource cover;

  /// 用于缓存命中与对齐的唯一键。
  final String? coverKey;

  /// 可选智能构图对齐缓存。
  final SmartCoverAlignmentCache? alignmentCache;

  /// 圆角半径。
  final double borderRadius;

  /// 图片填充模式。
  final BoxFit fit;

  /// 回退占位唱片上的短标牌文案。
  final String discLabel;

  /// 是否叠加柔和外描边（大舞台沉浸封面默认关闭硬白边）。
  final bool showBorder;

  @override
  Widget build(BuildContext context) {
    const fallbackPlaceholder = KonataCdDiscPlaceholder(
      transparentBackdrop: true,
    );

    Widget buildWithAlignment(Alignment alignment) {
      final source = cover;
      if (source is MemoryAudioCover && source.bytes.isNotEmpty) {
        return Image.memory(
          source.bytes,
          fit: fit,
          alignment: alignment,
          gaplessPlayback: true,
          filterQuality: FilterQuality.medium,
          errorBuilder: (_, _, _) => fallbackPlaceholder,
        );
      }
      if (source is ManagedPosterAudioCover) {
        final ref = source.artworkRef;
        if (ref is LocalCustomArtworkRef && ref.localPath.trim().isNotEmpty) {
          return Image.file(
            File(ref.localPath),
            fit: fit,
            alignment: alignment,
            errorBuilder: (_, _, _) => fallbackPlaceholder,
          );
        }
        if (ref is RemoteArtworkRef && ref.uri.trim().isNotEmpty) {
          return Image.network(
            ref.uri,
            fit: fit,
            alignment: alignment,
            errorBuilder: (_, _, _) => fallbackPlaceholder,
          );
        }
        final fallbackUrl = source.fallbackUrl?.trim() ?? '';
        if (fallbackUrl.startsWith('http://') ||
            fallbackUrl.startsWith('https://')) {
          return Image.network(
            fallbackUrl,
            fit: fit,
            alignment: alignment,
            errorBuilder: (_, _, _) => fallbackPlaceholder,
          );
        }
        if (fallbackUrl.isNotEmpty) {
          return Image.file(
            File(fallbackUrl),
            fit: fit,
            alignment: alignment,
            errorBuilder: (_, _, _) => fallbackPlaceholder,
          );
        }
      }
      return fallbackPlaceholder;
    }

    final memBytes = cover is MemoryAudioCover
        ? (cover as MemoryAudioCover).bytes
        : null;
    final Widget inner = (alignmentCache != null && memBytes != null)
        ? SmartCoverAlignmentBuilder(
            coverKey: coverKey,
            bytes: memBytes,
            cache: alignmentCache!,
            builder: (_, alignment) => buildWithAlignment(alignment),
          )
        : buildWithAlignment(
            cover is ManagedPosterAudioCover
                ? KonataSmartCoverFraming.defaultPosterAlignment
                : Alignment.center,
          );

    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xFF16131D),
          borderRadius: BorderRadius.circular(borderRadius),
          border: showBorder
              ? Border.all(
                  color: Colors.white.withValues(alpha: 0.14),
                  width: 0.8,
                )
              : null,
        ),
        child: inner,
      ),
    );
  }
}

/// 带底部模糊渐变水面倒影的桌面与移动端主封面舞台图。
class ImmersiveCoverWithReflection extends StatelessWidget {
  /// 创建带镜面倒影的沉浸封面组件。
  const ImmersiveCoverWithReflection({
    super.key,
    required this.cover,
    required this.size,
    this.coverKey,
    this.alignmentCache,
    this.borderRadius = 20.0,
    this.reflectionHeight = 52.0,
    this.showBorder = false,
  });

  /// 封面数据源。
  final AudioCoverSource cover;

  /// 封面方形边长。
  final double size;

  /// 封面唯一缓存键。
  final String? coverKey;

  /// 智能构图缓存。
  final SmartCoverAlignmentCache? alignmentCache;

  /// 圆角半径。
  final double borderRadius;

  /// 底部水面倒影高度（为 0 时隐藏倒影）。
  final double reflectionHeight;

  /// 是否显示边缘描边。
  final bool showBorder;

  @override
  Widget build(BuildContext context) {
    final coverArt = SizedBox.square(
      dimension: size,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(borderRadius),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.56),
              blurRadius: 48,
              spreadRadius: -6,
              offset: const Offset(0, 24),
            ),
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.28),
              blurRadius: 18,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: AudioCoverArtworkView(
          cover: cover,
          coverKey: coverKey,
          alignmentCache: alignmentCache,
          borderRadius: borderRadius,
          showBorder: showBorder,
        ),
      ),
    );

    if (reflectionHeight <= 0) return coverArt;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        coverArt,
        const SizedBox(height: 4),
        SizedBox(
          width: size,
          height: reflectionHeight,
          child: ClipRRect(
            borderRadius: BorderRadius.vertical(
              top: Radius.circular(borderRadius * 0.5),
            ),
            child: Opacity(
              opacity: 0.62,
              child: ImageFiltered(
                imageFilter: KonataTheme.blurFilterDecalOf(
                  KonataPlaybackTokens.albumReflectionBlurSigma,
                ),
                child: ShaderMask(
                  shaderCallback: (bounds) => const LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Color(0x78FFFFFF),
                      Color(0x28FFFFFF),
                      Colors.transparent,
                    ],
                    stops: [0.0, 0.45, 0.90],
                  ).createShader(bounds),
                  blendMode: BlendMode.dstIn,
                  child: Transform(
                    alignment: Alignment.center,
                    transform: Matrix4.diagonal3Values(1.0, -1.0, 1.0),
                    child: OverflowBox(
                      alignment: Alignment.topCenter,
                      minHeight: size,
                      maxHeight: size,
                      child: SizedBox.square(
                        dimension: size,
                        child: AudioCoverArtworkView(
                          cover: cover,
                          coverKey: coverKey,
                          borderRadius: borderRadius,
                          showBorder: false,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 歌词态顶部与紧凑视图专用迷你方形封面图。
class ImmersiveMicroCover extends StatelessWidget {
  /// 创建紧凑方形封面缩略图。
  const ImmersiveMicroCover({
    super.key,
    required this.cover,
    this.size = 72.0,
    this.coverKey,
  });

  final AudioCoverSource cover;
  final double size;
  final String? coverKey;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: size,
      child: AudioCoverArtworkView(
        cover: cover,
        coverKey: coverKey,
        borderRadius: 12.0,
      ),
    );
  }
}
