import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../domain/models/tmdb_models.dart';

/// 图片艺术类型。
enum ManagedArtwork {
  /// 作品竖版海报。
  poster,

  /// 单集横版剧照。
  still,

  /// 详情页背景图。
  backdrop,

  /// 作品官方透明标题 Logo。
  logo,
}

/// 异步图片字节加载器签名（保持兼容既有调用方；扩展所有者与图片类型请用 [bindManagedArtworkLoader]）。
typedef ManagedImageLoader =
    Future<Uint8List> Function(
      String url, {
      int? targetWidth,
      TmdbImageSize? imageSize,
    });

/// 携带所属作品 ID 与图片分类语义的扩展图片字节加载器签名。
typedef ManagedArtworkLoader =
    Future<Uint8List> Function(
      String url, {
      int? targetWidth,
      TmdbImageSize? imageSize,
      String? ownerWorkId,
      ManagedArtwork? artwork,
    });

final Expando<ManagedArtworkLoader> _managedArtworkLoaderExpando =
    Expando<ManagedArtworkLoader>('konataManagedArtworkLoader');

/// 将支持 `ownerWorkId` 与 `artwork` 分区缓存的扩展加载器包装为标准 [ManagedImageLoader]。
ManagedImageLoader bindManagedArtworkLoader(ManagedArtworkLoader extended) {
  Future<Uint8List> wrapper(
    String url, {
    int? targetWidth,
    TmdbImageSize? imageSize,
  }) {
    return extended(url, targetWidth: targetWidth, imageSize: imageSize);
  }

  _managedArtworkLoaderExpando[wrapper] = extended;
  return wrapper;
}

/// 图片缓存唯一键。
typedef ManagedImageKey = ({
  String url,
  String? owner,
  ManagedArtwork artwork,
  int targetWidth,
  TmdbImageSize? imageSize,
  bool isHeroBackdrop,
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
      final extended = _managedArtworkLoaderExpando[key.loader];
      final bytes = extended != null
          ? await extended(
              key.url,
              targetWidth: key.targetWidth,
              imageSize: key.imageSize,
              ownerWorkId: key.owner,
              artwork: key.artwork,
            )
          : await key.loader(
              key.url,
              targetWidth: key.targetWidth,
              imageSize: key.imageSize,
            );
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      return await decode(buffer);
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

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final logicalWidth =
            width ??
            (constraints.hasBoundedWidth ? constraints.maxWidth : 1280.0);
        final physicalWidth =
            (logicalWidth * MediaQuery.devicePixelRatioOf(context))
                .ceil()
                .clamp(1, 8192);

        final keepFullResolution =
            isHeroBackdrop ||
            imageSize == TmdbImageSize.original ||
            artwork == ManagedArtwork.backdrop ||
            artwork == ManagedArtwork.logo;
        final effectiveSize =
            imageSize ??
            (keepFullResolution ? TmdbImageSize.original : null);
        final target = artwork == ManagedArtwork.poster && !keepFullResolution
            ? physicalWidth.clamp(1, decodeWidth)
            : physicalWidth;

        final ImageProvider baseProvider = ManagedImageProvider(
          url,
          loader: loader,
          targetWidth: target,
          artwork: artwork,
          imageSize: effectiveSize,
          isHeroBackdrop: isHeroBackdrop,
          owner: owner,
        );

        final effectiveProvider = keepFullResolution
            ? baseProvider
            : ResizeImage.resizeIfNeeded(target, null, baseProvider);

        return Image(
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
      },
    );
  }
}
