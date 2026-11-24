import 'dart:collection';
import 'dart:typed_data';

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

/// 进程内热点小图内存字节 LRU 缓存（避免反复异步磁盘读取引起的滚动闪烁）。
final class _InMemoryThumbnailByteLru {
  _InMemoryThumbnailByteLru();

  static const int _maxEntries = 180;
  final LinkedHashMap<String, Uint8List> _entries =
      LinkedHashMap<String, Uint8List>();

  Uint8List? get(String key) {
    final hit = _entries.remove(key);
    if (hit == null) return null;
    _entries[key] = hit;
    return hit;
  }

  void put(String key, Uint8List bytes) {
    if (bytes.isEmpty || bytes.lengthInBytes > 2 * 1024 * 1024) return;
    _entries.remove(key);
    _entries[key] = bytes;
    while (_entries.length > _maxEntries) {
      _entries.remove(_entries.keys.first);
    }
  }
}

final _thumbnailByteLru = _InMemoryThumbnailByteLru();

/// 统一承载磁盘 `photos/` 缓存直读、受控解码缩放与占位过渡的托管图片组件。
class ManagedImage extends ConsumerStatefulWidget {
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
  ConsumerState<ManagedImage> createState() => _ManagedImageState();
}

class _ManagedImageState extends ConsumerState<ManagedImage> {
  Uint8List? _bytes;
  bool _loading = false;
  bool _failed = false;
  int _requestGeneration = 0;

  String get _cacheKey =>
      '${widget.path?.trim() ?? ''}|${widget.imageSize.name}|${widget.targetWidth}|${widget.ownerWorkId ?? ''}';

  @override
  void initState() {
    super.initState();
    _loadImage();
  }

  @override
  void didUpdateWidget(covariant ManagedImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path ||
        oldWidget.imageSize != widget.imageSize ||
        oldWidget.targetWidth != widget.targetWidth ||
        oldWidget.ownerWorkId != widget.ownerWorkId ||
        oldWidget.imageLoaderOverride != widget.imageLoaderOverride) {
      _loadImage();
    }
  }

  Future<void> _loadImage() async {
    final cleanPath = widget.path?.trim() ?? '';
    final gen = ++_requestGeneration;
    if (cleanPath.isEmpty) {
      if (mounted) {
        setState(() {
          _bytes = null;
          _loading = false;
          _failed = true;
        });
      }
      return;
    }

    if (widget.imageLoaderOverride == null) {
      final memoryHit = _thumbnailByteLru.get(_cacheKey);
      if (memoryHit != null) {
        if (mounted) {
          setState(() {
            _bytes = memoryHit;
            _loading = false;
            _failed = false;
          });
        }
        return;
      }
    }

    setState(() {
      _loading = true;
      _failed = false;
    });

    final LibraryArtworkLoader loader =
        widget.imageLoaderOverride ?? ref.read(libraryArtworkLoaderProvider);
    try {
      final loaded = await loader(
        cleanPath,
        targetWidth: widget.targetWidth,
        imageSize: widget.imageSize,
        ownerWorkId: widget.ownerWorkId,
        subfolder: widget.subfolder,
      );
      if (!mounted || gen != _requestGeneration) return;
      if (loaded == null || loaded.isEmpty) {
        setState(() {
          _bytes = null;
          _loading = false;
          _failed = true;
        });
        return;
      }
      if (widget.imageLoaderOverride == null) {
        _thumbnailByteLru.put(_cacheKey, loaded);
      }
      setState(() {
        _bytes = loaded;
        _loading = false;
        _failed = false;
      });
    } catch (_) {
      if (!mounted || gen != _requestGeneration) return;
      setState(() {
        _bytes = null;
        _loading = false;
        _failed = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    if (bytes != null && bytes.isNotEmpty) {
      final provider = ResizeImage.resizeIfNeeded(
        widget.targetWidth > 0 ? widget.targetWidth : null,
        null,
        MemoryImage(bytes),
      );
      return Image(
        image: provider,
        fit: widget.fit,
        alignment: widget.alignment,
        filterQuality: widget.filterQuality,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => _buildFallback(context),
      );
    }
    if (_loading) {
      return widget.placeholder ?? _buildPlaceholder(context);
    }
    if (_failed) {
      return _buildFallback(context);
    }
    return widget.placeholder ?? _buildPlaceholder(context);
  }

  Widget _buildPlaceholder(BuildContext context) {
    final p = context.palette;
    return ColoredBox(color: p.elevatedSurface.withValues(alpha: 0.6));
  }

  Widget _buildFallback(BuildContext context) {
    if (widget.errorWidget != null) return widget.errorWidget!;
    final p = context.palette;
    return ColoredBox(
      color: p.elevatedSurface.withValues(alpha: 0.65),
      child: Center(
        child: Icon(
          Icons.movie_outlined,
          size: 28,
          color: p.textMuted,
        ),
      ),
    );
  }
}
