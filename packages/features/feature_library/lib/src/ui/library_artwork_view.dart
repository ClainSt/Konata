import 'package:engine_scraping/engine_scraping.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:konata_design_system/konata_design_system.dart';

import '../providers.dart';

/// 面向海报墙高帧率滚动的受控位图内存缩放分档宽度量化函数。
///
/// 将任意逻辑宽度与 DPR 的乘积向上吸附到有限的几个标准档位（`256/384/512/768/1024/1440`），
/// 既保证视网膜屏幕清晰度，又防止不同尺寸卡片产生海量重复解码纹理缓存。
int quantizeManagedImageWidth(double logicalWidth, double devicePixelRatio) {
  if (!logicalWidth.isFinite || logicalWidth <= 0) return 384;
  final raw = (logicalWidth * devicePixelRatio.clamp(1.0, 3.0)).ceil();
  const buckets = <int>[256, 384, 512, 768, 1024, 1440];
  for (final bucket in buckets) {
    if (raw <= bucket) return bucket;
  }
  return 1440;
}

/// 统一承载磁盘 `photos/` 缓存直读、受控解码缩放与占位过渡的托管图片组件。
class ManagedImage extends ConsumerWidget {
  /// 构造托管艺术图组件。
  const ManagedImage({
    super.key,
    required this.path,
    this.imageSize = TmdbImageSize.w500,
    this.targetWidth = 384,
    this.ownerWorkId,
    this.subfolder,
    this.fit = BoxFit.cover,
    this.alignment = Alignment.center,
    this.filterQuality = FilterQuality.low,
    this.placeholder,
    this.errorWidget,
    this.imageLoaderOverride,
  });

  /// 图片相对路径或完整 URL。
  final String? path;

  /// 首选图片清晰度档位。
  final TmdbImageSize imageSize;

  /// 受控解码目标像素宽度（默认 `384`，有效限制海报墙内存峰值）。
  final int targetWidth;

  /// 所属作品 ID（供按作品维度命中本机 `photos/` 艺术图缓存）。
  final String? ownerWorkId;

  /// 本机图片子目录分类（封面 / 横图 / 剧照等）。
  final PhotoSubfolder? subfolder;

  /// 图像适配填充方式。
  final BoxFit fit;

  /// 对齐锚点。
  final Alignment alignment;

  /// GPU 采样滤镜精度（高速海报墙默认 `FilterQuality.low` 以降低采样开销）。
  final FilterQuality filterQuality;

  /// 加载期间占位组件。
  final Widget? placeholder;

  /// 空路径或加载失败时的降级兜底组件。
  final Widget? errorWidget;

  /// 可选图片字节加载覆盖回调（常用于纯 Widget 测试注入样例图）。
  final LibraryArtworkLoader? imageLoaderOverride;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = context.palette;
    final LibraryArtworkLoader source =
        imageLoaderOverride ?? ref.watch(libraryArtworkLoaderProvider);
    return KonataManagedImage(
      url: path,
      loader: (url, {required targetWidth, variantKey}) => source(
        url,
        targetWidth: targetWidth,
        imageSize: imageSize,
        ownerWorkId: ownerWorkId,
        subfolder: subfolder,
      ),
      loaderToken: source,
      variantKey: (imageSize, ownerWorkId, subfolder),
      explicitTargetWidth: targetWidth,
      fit: fit,
      alignment: alignment,
      filterQuality: filterQuality,
      useThumbnailByteLru: imageLoaderOverride == null,
      placeholder:
          placeholder ??
          ColoredBox(color: palette.elevatedSurface.withValues(alpha: 0.6)),
      errorBuilder: (_, _, _) =>
          errorWidget ??
          ColoredBox(
            color: palette.elevatedSurface.withValues(alpha: 0.65),
            child: Center(
              child: Icon(
                Icons.movie_outlined,
                size: 28,
                color: palette.textMuted,
              ),
            ),
          ),
    );
  }
}
