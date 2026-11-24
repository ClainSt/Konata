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
    final primary = Color(_palette.primaryArgb);
    final secondary = Color(_palette.secondaryArgb);
    final accent = Color(_palette.accentArgb);
    final tint = Color(_palette.surfaceTintArgb);
    final baseBg = Color.lerp(const Color(0xFF0C0F14), tint, 0.35)!;

    return RepaintBoundary(
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 520),
        curve: Curves.easeOutCubic,
        color: baseBg,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // 左上主色流光斑。
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(-0.72, -0.68),
                  radius: 1.05,
                  colors: [
                    primary.withValues(alpha: 0.44),
                    primary.withValues(alpha: 0.14),
                    Colors.transparent,
                  ],
                  stops: const [0.0, 0.48, 1.0],
                ),
              ),
            ),
            // 右下辅色均衡流光斑。
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(0.75, 0.65),
                  radius: 1.15,
                  colors: [
                    secondary.withValues(alpha: 0.38),
                    secondary.withValues(alpha: 0.10),
                    Colors.transparent,
                  ],
                  stops: const [0.0, 0.52, 1.0],
                ),
              ),
            ),
            // 中心高光提亮光晕，增强玻璃胶囊景深。
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(0.0, -0.10),
                  radius: 0.90,
                  colors: [
                    accent.withValues(alpha: 0.18),
                    Colors.transparent,
                  ],
                  stops: const [0.0, 1.0],
                ),
              ),
            ),
            // 深色安全暗角遮罩，保证高可读对比度。
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.24),
                    Colors.black.withValues(alpha: 0.32),
                    Colors.black.withValues(alpha: 0.48),
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
        : buildWithAlignment(Alignment.center);

    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xFF1A1E26),
          borderRadius: BorderRadius.circular(borderRadius),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.14),
            width: 0.8,
          ),
        ),
        child: inner,
      ),
    );
  }
}

/// 带底部镜面柔化倒影的桌面与移动端主封面舞台图。
class ImmersiveCoverWithReflection extends StatelessWidget {
  /// 创建带镜面倒影的沉浸封面组件。
  const ImmersiveCoverWithReflection({
    super.key,
    required this.cover,
    required this.size,
    this.coverKey,
    this.alignmentCache,
    this.borderRadius = 20.0,
    this.reflectionHeight = 36.0,
  });

  final AudioCoverSource cover;
  final double size;
  final String? coverKey;
  final SmartCoverAlignmentCache? alignmentCache;
  final double borderRadius;
  final double reflectionHeight;

  @override
  Widget build(BuildContext context) {
    final coverArt = SizedBox.square(
      dimension: size,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(borderRadius),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.45),
              blurRadius: 36,
              offset: const Offset(0, 18),
            ),
          ],
        ),
        child: AudioCoverArtworkView(
          cover: cover,
          coverKey: coverKey,
          alignmentCache: alignmentCache,
          borderRadius: borderRadius,
        ),
      ),
    );

    if (reflectionHeight <= 0) return coverArt;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        coverArt,
        const SizedBox(height: 6),
        SizedBox(
          width: size,
          height: reflectionHeight,
          child: ClipRRect(
            borderRadius: BorderRadius.vertical(
              top: Radius.circular(borderRadius * 0.5),
            ),
            child: ShaderMask(
              shaderCallback: (bounds) => const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0x38FFFFFF), Colors.transparent],
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

/// 手机横屏矮视口专用迷你方形封面图。
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
