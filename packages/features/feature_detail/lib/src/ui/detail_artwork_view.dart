import 'dart:async';
import 'dart:ui' as ui;

import 'package:engine_scraping/engine_scraping.dart';
import 'package:flutter/widgets.dart';
import 'package:konata_design_system/konata_design_system.dart';

/// 向共享图片组件传入详情页的艺术图分类与远端分辨率档位。
KonataManagedImageLoader detailArtworkLoader(
  ManagedImageLoader loader, {
  String? owner,
  ManagedArtwork artwork = ManagedArtwork.poster,
  TmdbImageSize? imageSize,
}) {
  return (url, {required targetWidth, variantKey}) {
    if (loader is ManagedArtworkLoader) {
      return loader(
        url,
        targetWidth: targetWidth,
        imageSize: imageSize,
        ownerWorkId: owner,
        artwork: artwork,
      );
    }
    return loader(url, targetWidth: targetWidth, imageSize: imageSize);
  };
}

/// 详情页自适应物理分辨率受管图片组件（严格隔离至设计系统，绝不引入 `material_ui`）。
class DetailManagedImage extends StatelessWidget {
  /// 创建受管图片组件。
  const DetailManagedImage(
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
    this.devicePixelRatio,
    this.filterQuality,
    this.errorBuilder,
    this.onImageResolved,
  });

  /// 图片地址或相对路径。
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

  /// 所属作品主键。
  final String? owner;

  /// 常规缩略图最大解码宽度上限。
  final int decodeWidth;

  /// 图片分类。
  final ManagedArtwork artwork;

  /// 强制指定 `TMDB` 分辨率档位。
  final TmdbImageSize? imageSize;

  /// 是否作为全屏背景画布渲染。
  final bool isHeroBackdrop;

  /// 可选设备像素比覆写。
  final double? devicePixelRatio;

  /// 可选滤波质量覆写。
  final FilterQuality? filterQuality;

  /// 加载失败兜底构建器。
  final ImageErrorWidgetBuilder? errorBuilder;

  /// 首帧解码通知，异步读取须返回 Future，观察器在回调完成后释放图像。
  final FutureOr<void> Function(ui.Image image, ImageProvider provider)?
  onImageResolved;

  @override
  Widget build(BuildContext context) {
    final original =
        isHeroBackdrop ||
        imageSize == TmdbImageSize.original ||
        artwork == ManagedArtwork.backdrop ||
        artwork == ManagedArtwork.logo;
    final size = imageSize ?? (original ? TmdbImageSize.original : null);
    final ImageErrorWidgetBuilder? artworkFallback = switch (artwork) {
      ManagedArtwork.logo => (_, _, _) => const SizedBox.shrink(),
      ManagedArtwork.backdrop => (_, _, _) => const ColoredBox(
        color: KonataTheme.cinemaObsidian,
      ),
      _ when isHeroBackdrop => (_, _, _) => const ColoredBox(
        color: KonataTheme.cinemaObsidian,
      ),
      _ => null,
    };
    return KonataManagedImage(
      url: url,
      loader: detailArtworkLoader(
        loader,
        owner: owner,
        artwork: artwork,
        imageSize: size,
      ),
      loaderToken: loader,
      variantKey: (owner, artwork, size, isHeroBackdrop),
      width: width,
      height: height,
      fit: fit,
      alignment: alignment,
      decodeWidth: decodeWidth,
      keepFullResolution: original,
      fullResolutionMaxWidth: artwork == ManagedArtwork.logo ? 1280 : 2560,
      devicePixelRatio: devicePixelRatio,
      filterQuality: filterQuality,
      onImageResolved: onImageResolved,
      errorBuilder: errorBuilder ?? artworkFallback,
    );
  }
}
