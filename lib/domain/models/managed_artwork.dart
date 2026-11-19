import 'dart:typed_data';

import 'tmdb_models.dart';

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

/// 异步图片字节加载器签名（兼容既有三参调用方，且可直接承载扩展签名 [ManagedArtworkLoader]）。
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

/// 将支持 `ownerWorkId` 与 `artwork` 分区缓存的扩展加载器按子类型契约暴露为 [ManagedImageLoader]。
///
/// 零全局可变表，解码端通过 `loader is ManagedArtworkLoader` 直接分派扩展参数。
ManagedImageLoader bindManagedArtworkLoader(ManagedArtworkLoader extended) {
  return extended;
}
