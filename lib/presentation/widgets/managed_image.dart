import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import '../../domain/models/managed_artwork.dart';
import '../../domain/models/tmdb_models.dart';

export '../../domain/models/managed_artwork.dart';

/// 将物理目标像素宽度向上规整至离散档位，避免窗口拖拽微调宽度导致 `ImageCache` 反复重复解码。
int quantizeManagedImageWidth(int rawPhysicalWidth, {int maxWidth = 3840}) {
  const buckets = <int>[192, 320, 480, 640, 960, 1280, 1920, 2560, 3840];
  final clampedMax = maxWidth.clamp(1, 3840);
  final desired = rawPhysicalWidth.clamp(1, clampedMax);
  for (final bucket in buckets) {
    if (bucket >= desired) {
      return math.min(bucket, clampedMax);
    }
  }
  return clampedMax;
}

/// 图片缓存唯一键。
typedef ManagedImageKey = ({
  String url,
  String? owner,
  ManagedArtwork artwork,
  int targetWidth,
  TmdbImageSize? imageSize,
  bool isHeroBackdrop,
  bool applyDecodeWidthCap,
  ManagedImageLoader loader,
});

/// 支持按显示物理像素或原画档位解码的图片 Provider。
class ManagedImageProvider extends ImageProvider<ManagedImageKey> {
  /// 创建可控解码尺寸的 [ImageProvider]。
  const ManagedImageProvider(
    this.url, {
    required this.loader,
    required this.targetWidth,
    this.artwork = ManagedArtwork.poster,
    this.imageSize,
    this.isHeroBackdrop = false,
    this.applyDecodeWidthCap = false,
    this.owner,
  });

  /// 图片地址或缓存标识。
  final String url;

  /// 所属作品 ID（可选）。
  final String? owner;

  /// 图片分类（用于归档到 `posters / backdrops / logos / thumbnails`）。
  final ManagedArtwork artwork;

  /// 目标物理解码宽度。
  final int targetWidth;

  /// 显式请求的 TMDB 分辨率档位。
  final TmdbImageSize? imageSize;

  /// 是否作为全屏背景大画布渲染。
  final bool isHeroBackdrop;

  /// 未外包 `ResizeImage` 时是否在自身解码阶段直接施加物理宽度封顶，避免与 `ResizeImage` 重复传 `getTargetSize`。
  final bool applyDecodeWidthCap;

  /// 字节加载回调。
  final ManagedImageLoader loader;

  @override
  Future<ManagedImageKey> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture((
      url: url,
      owner: owner,
      artwork: artwork,
      targetWidth: targetWidth,
      imageSize: imageSize,
      isHeroBackdrop: isHeroBackdrop,
      applyDecodeWidthCap: applyDecodeWidthCap,
      loader: loader,
    ));
  }

  @override
  ImageStreamCompleter loadImage(
    ManagedImageKey key,
    ImageDecoderCallback decode,
  ) {
    return MultiFrameImageStreamCompleter(
      codec: _decode(key, decode),
      scale: 1,
      debugLabel: key.url,
    );
  }

  Future<ui.Codec> _decode(
    ManagedImageKey key,
    ImageDecoderCallback decode,
  ) async {
    try {
      final loader = key.loader;
      final bytes = loader is ManagedArtworkLoader
          ? await loader(
              key.url,
              targetWidth: key.targetWidth,
              imageSize: key.imageSize,
              ownerWorkId: key.owner,
              artwork: key.artwork,
            )
          : await loader(
              key.url,
              targetWidth: key.targetWidth,
              imageSize: key.imageSize,
            );
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      if (!key.applyDecodeWidthCap || key.targetWidth <= 0) {
        return await decode(buffer);
      }
      return await decode(
        buffer,
        getTargetSize: (int intrinsicWidth, int intrinsicHeight) {
          if (intrinsicWidth > key.targetWidth) {
            return ui.TargetImageSize(width: key.targetWidth);
          }
          return ui.TargetImageSize(
            width: intrinsicWidth,
            height: intrinsicHeight,
          );
        },
      );
    } catch (_) {
      PaintingBinding.instance.imageCache.evict(key);
      rethrow;
    }
  }
}

/// 自适应物理分辨率的受管图片展示组件。
///
/// 对列表海报按需降维解码以防内存膨胀；对详情页背景、ClearLogo 与显式 `original` 档位
/// 绕过小尺寸缩放重采样限制，配合高画质滤波渲染无损锐利原画。
class ManagedImage extends StatelessWidget {
  /// 创建受管图片组件。
  const ManagedImage(
    this.url, {
    super.key,
    required this.loader,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.alignment = Alignment.center,
    this.owner,
    this.decodeWidth = 1024,
    this.artwork = ManagedArtwork.poster,
    this.imageSize,
    this.isHeroBackdrop = false,
    this.errorBuilder,
    this.onImageResolved,
  });

  /// 图片地址。
  final String url;

  /// 字节加载回调。
  final ManagedImageLoader loader;

  /// 可选逻辑宽度。
  final double? width;

  /// 可选逻辑高度。
  final double? height;

  /// 缩放填充模式。
  final BoxFit fit;

  /// 对齐方式。
  final AlignmentGeometry alignment;

  /// 所属作品 ID。
  final String? owner;

  /// 常规缩略图最大解码宽度上限。
  final int decodeWidth;

  /// 图片类型。
  final ManagedArtwork artwork;

  /// 强制指定 TMDB 物理尺寸档位（详情页背景/Logo 推荐传 [TmdbImageSize.original]）。
  final TmdbImageSize? imageSize;

  /// 是否作为全屏/顶部大尺寸 Hero 背景渲染（关闭缩放裁剪，直出原画）。
  final bool isHeroBackdrop;

  /// 加载失败兜底构建器。
  final ImageErrorWidgetBuilder? errorBuilder;

  /// 首帧图像解码就绪时的可选只读回调（复用同一缓存图像流，零重复下载与解码）。
  final void Function(ui.Image image, ImageProvider provider)? onImageResolved;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final dpr = MediaQuery.devicePixelRatioOf(context);
        final logicalWidth =
            width ??
            (constraints.hasBoundedWidth ? constraints.maxWidth : 1280.0);
        final rawPhysicalWidth = (logicalWidth * dpr).ceil().clamp(1, 3840);
        final viewportPhysicalWidth =
            (MediaQuery.sizeOf(context).width * dpr).ceil().clamp(1, 3840);

        final keepFullResolution =
            isHeroBackdrop ||
            imageSize == TmdbImageSize.original ||
            artwork == ManagedArtwork.backdrop ||
            artwork == ManagedArtwork.logo;
        final effectiveSize =
            imageSize ??
            (keepFullResolution ? TmdbImageSize.original : null);
        final int target;
        if (artwork == ManagedArtwork.logo) {
          target = quantizeManagedImageWidth(
            math.min(rawPhysicalWidth, 1280),
            maxWidth: 1280,
          );
        } else if (keepFullResolution) {
          // 保持下载 original 高清原图落盘，但解码位图按显示物理像素封顶以防 4K 背景图浪费 33MB+ 内存。
          final displayMax = math.max(viewportPhysicalWidth, 1920).clamp(
            1,
            3840,
          );
          target = quantizeManagedImageWidth(
            math.min(rawPhysicalWidth, displayMax),
            maxWidth: displayMax,
          );
        } else {
          target = quantizeManagedImageWidth(
            rawPhysicalWidth.clamp(1, decodeWidth),
            maxWidth: decodeWidth,
          );
        }

        final ImageProvider baseProvider = ManagedImageProvider(
          url,
          loader: loader,
          targetWidth: target,
          artwork: artwork,
          imageSize: effectiveSize,
          isHeroBackdrop: isHeroBackdrop,
          applyDecodeWidthCap: keepFullResolution,
          owner: owner,
        );

        final effectiveProvider = keepFullResolution
            ? baseProvider
            : ResizeImage.resizeIfNeeded(target, null, baseProvider);

        final imageWidget = Image(
          image: effectiveProvider,
          width: width,
          height: height,
          fit: fit,
          alignment: alignment,
          filterQuality: keepFullResolution
              ? FilterQuality.high
              : FilterQuality.medium,
          gaplessPlayback: true,
          errorBuilder: errorBuilder,
        );

        final observer = onImageResolved;
        if (observer == null) {
          return imageWidget;
        }
        return _ManagedImageDecodeObserver(
          provider: effectiveProvider,
          onImageResolved: observer,
          child: imageWidget,
        );
      },
    );
  }
}

/// 复用同一 [ImageProvider] 缓存流监听解码就绪事件，严禁触发二次下载或二次解码。
class _ManagedImageDecodeObserver extends StatefulWidget {
  const _ManagedImageDecodeObserver({
    required this.provider,
    required this.onImageResolved,
    required this.child,
  });

  final ImageProvider provider;
  final void Function(ui.Image image, ImageProvider provider) onImageResolved;
  final Widget child;

  @override
  State<_ManagedImageDecodeObserver> createState() =>
      _ManagedImageDecodeObserverState();
}

class _ManagedImageDecodeObserverState
    extends State<_ManagedImageDecodeObserver> {
  ImageStream? _stream;
  ImageStreamListener? _listener;
  ImageProvider? _listeningProvider;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncStream();
  }

  @override
  void didUpdateWidget(covariant _ManagedImageDecodeObserver oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.provider != widget.provider) {
      _syncStream();
    }
  }

  void _syncStream() {
    if (_listeningProvider == widget.provider && _stream != null) return;
    _detachStream();
    _listeningProvider = widget.provider;
    final stream = widget.provider.resolve(
      createLocalImageConfiguration(context),
    );
    final listener = ImageStreamListener(
      _handleFrame,
      onError: _handleStreamError,
    );
    _stream = stream;
    _listener = listener;
    stream.addListener(listener);
  }

  void _handleFrame(ImageInfo info, bool synchronousCall) {
    if (!mounted) return;
    widget.onImageResolved(info.image, widget.provider);
  }

  void _handleStreamError(Object error, StackTrace? stackTrace) {
    // 加载异常统一由子级 Image.errorBuilder 承接展示，此处仅静默解绑。
    _detachStream();
  }

  void _detachStream() {
    if (_stream != null && _listener != null) {
      _stream!.removeListener(_listener!);
    }
    _stream = null;
    _listener = null;
    _listeningProvider = null;
  }

  @override
  void dispose() {
    _detachStream();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
