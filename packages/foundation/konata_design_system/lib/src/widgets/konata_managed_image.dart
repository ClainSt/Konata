import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import '../tokens/konata_palette.dart';
import '../tokens/konata_theme.dart';

/// 通用受管图片字节加载回调（仅透传地址、物理目标宽度与可选分桶键，严守 0 业务依赖）。
typedef KonataManagedImageLoader =
    Future<Uint8List?> Function(
      String url, {
      required int targetWidth,
      Object? variantKey,
    });

/// 将物理目标像素宽度向上规整至离散档位，避免窗口拖拽微调或不同尺寸卡片导致重复解码纹理。
int quantizeKonataImageWidth(int rawPhysicalWidth, {int maxWidth = 3840}) {
  const buckets = <int>[
    192,
    256,
    320,
    384,
    480,
    640,
    960,
    1280,
    1920,
    2560,
    3840,
  ];
  final clampedMax = maxWidth.clamp(1, 3840);
  final desired = rawPhysicalWidth.clamp(1, clampedMax);
  for (final bucket in buckets) {
    if (bucket >= desired) {
      return math.min(bucket, clampedMax);
    }
  }
  return clampedMax;
}

/// 进程内热点缩略图内存字节 LRU（避免海报墙快速复用网格项时异步磁盘读取造成首帧闪烁）。
final class KonataThumbnailByteLru {
  /// 创建有界内存字节缓存。
  KonataThumbnailByteLru({
    this.maxEntries = 180,
    this.maxBytesPerEntry = 2 * 1024 * 1024,
  });

  /// 最大缓存条目数。
  final int maxEntries;

  /// 单张缓存字节大小上限（避免原画大背景挤占热点缩略图配额）。
  final int maxBytesPerEntry;

  final LinkedHashMap<Object, Uint8List> _entries =
      LinkedHashMap<Object, Uint8List>();

  /// 命中时刷新 LRU 顺序并返回只读字节。
  Uint8List? get(Object key) {
    final hit = _entries.remove(key);
    if (hit == null) return null;
    _entries[key] = hit;
    return hit;
  }

  /// 写入受控大小的图片字节并在超限时淘汰最旧条目。
  void put(Object key, Uint8List bytes) {
    if (bytes.isEmpty || bytes.lengthInBytes > maxBytesPerEntry) return;
    _entries.remove(key);
    _entries[key] = bytes;
    while (_entries.length > maxEntries) {
      _entries.remove(_entries.keys.first);
    }
  }

  /// 清空全部内存字节缓存（供后台收缩或测试复位调用）。
  void clear() => _entries.clear();
}

/// 供海报墙等高速列表共享的默认热点缩略图字节缓存。
final KonataThumbnailByteLru konataSharedThumbnailByteLru =
    KonataThumbnailByteLru();

/// 通用受管图片缓存键（以值语义判等，避免外层重建轻量闭包导致 `ImageCache` 失效）。
final class KonataManagedImageKey {
  /// 创建图片缓存键。
  const KonataManagedImageKey({
    required this.url,
    required this.targetWidth,
    required this.applyDecodeWidthCap,
    this.variantKey,
    this.loaderToken,
  });

  /// 图片地址或缓存路径。
  final String url;

  /// 目标物理解码宽度。
  final int targetWidth;

  /// 是否在解码器内部施加宽度上限。
  final bool applyDecodeWidthCap;

  /// 业务侧透传的分桶标识（如作品主键、艺术图槽位与分辨率档位组合）。
  final Object? variantKey;

  /// 可选加载器实例令牌（仅在单测覆盖加载器或需显式隔离缓存时传入）。
  final Object? loaderToken;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is KonataManagedImageKey &&
        other.url == url &&
        other.targetWidth == targetWidth &&
        other.applyDecodeWidthCap == applyDecodeWidthCap &&
        other.variantKey == variantKey &&
        other.loaderToken == loaderToken;
  }

  @override
  int get hashCode => Object.hash(
    url,
    targetWidth,
    applyDecodeWidthCap,
    variantKey,
    loaderToken,
  );
}

/// 支持离散物理解码宽度与可选字节 LRU 的通用受管图片提供器。
class KonataManagedImageProvider extends ImageProvider<KonataManagedImageKey> {
  /// 创建受管图片提供器。
  const KonataManagedImageProvider(
    this.url, {
    required this.loader,
    required this.targetWidth,
    this.variantKey,
    this.loaderToken,
    this.applyDecodeWidthCap = false,
    this.byteLru,
  });

  /// 图片地址或相对路径。
  final String url;

  /// 异步字节加载回调。
  final KonataManagedImageLoader loader;

  /// 目标物理解码宽度。
  final int targetWidth;

  /// 业务侧分桶标识。
  final Object? variantKey;

  /// 可选加载器隔离令牌。
  final Object? loaderToken;

  /// 是否在原生解码阶段限制目标宽度。
  final bool applyDecodeWidthCap;

  /// 可选热点字节 LRU（用于高速滚动列表免闪烁复用）。
  final KonataThumbnailByteLru? byteLru;

  @override
  Future<KonataManagedImageKey> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture<KonataManagedImageKey>(
      KonataManagedImageKey(
        url: url,
        targetWidth: targetWidth,
        applyDecodeWidthCap: applyDecodeWidthCap,
        variantKey: variantKey,
        loaderToken: loaderToken,
      ),
    );
  }

  @override
  ImageStreamCompleter loadImage(
    KonataManagedImageKey key,
    ImageDecoderCallback decode,
  ) {
    return MultiFrameImageStreamCompleter(
      codec: _decode(key, decode),
      scale: 1,
      debugLabel: key.url,
    );
  }

  Future<ui.Codec> _decode(
    KonataManagedImageKey key,
    ImageDecoderCallback decode,
  ) async {
    try {
      Uint8List? bytes = byteLru?.get(key);
      if (bytes == null || bytes.isEmpty) {
        bytes = await loader(
          key.url,
          targetWidth: key.targetWidth,
          variantKey: key.variantKey,
        );
        if (bytes != null && bytes.isNotEmpty) {
          byteLru?.put(key, bytes);
        }
      }
      if (bytes == null || bytes.isEmpty) {
        throw StateError('受管图片字节为空：${key.url}');
      }
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

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is KonataManagedImageProvider &&
        other.url == url &&
        other.targetWidth == targetWidth &&
        other.variantKey == variantKey &&
        other.loaderToken == loaderToken &&
        other.applyDecodeWidthCap == applyDecodeWidthCap &&
        other.byteLru == byteLru;
  }

  @override
  int get hashCode => Object.hash(
    url,
    targetWidth,
    variantKey,
    loaderToken,
    applyDecodeWidthCap,
    byteLru,
  );
}

/// Konata 三端统一通用受管图片组件（严格 0 Riverpod、0 业务依赖）。
///
/// 统一替代海报墙与详情页重复图片加载器，支持：
/// - 物理分辨率离散分档与 `ResizeImage` 显存上限保护；
/// - 可选原画高精模式（背景原画 / 透明徽标）；
/// - 可选热点字节 LRU 与首帧解码完成回调。
class KonataManagedImage extends StatefulWidget {
  /// 创建通用受管图片组件。
  const KonataManagedImage({
    super.key,
    required this.url,
    required this.loader,
    this.variantKey,
    this.loaderToken,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.alignment = Alignment.center,
    this.decodeWidth = 1024,
    this.explicitTargetWidth,
    this.keepFullResolution = false,
    this.fullResolutionMaxWidth = 2560,
    this.devicePixelRatio,
    this.filterQuality,
    this.placeholder,
    this.errorBuilder,
    this.onImageResolved,
    this.useThumbnailByteLru = false,
    this.byteLru,
  });

  /// 图片地址或缓存路径（为空时直接展示兜底视图）。
  final String? url;

  /// 异步字节加载回调。
  final KonataManagedImageLoader loader;

  /// 业务侧分桶标识（透传给加载器并参与缓存判等）。
  final Object? variantKey;

  /// 可选加载器隔离令牌。
  final Object? loaderToken;

  /// 可选逻辑宽度。
  final double? width;

  /// 可选逻辑高度。
  final double? height;

  /// 图像适配填充模式。
  final BoxFit fit;

  /// 图像对齐锚点。
  final AlignmentGeometry alignment;

  /// 常规缩略图最大物理解码宽度上限。
  final int decodeWidth;

  /// 显式锁定目标解码宽度（传入且 `> 0` 时跳过自适应布局测算）。
  final int? explicitTargetWidth;

  /// 是否开启高精原画解码通道（适用于全屏背景或透明徽标）。
  final bool keepFullResolution;

  /// 高精原画模式下的最大物理解码宽度上限。
  final int fullResolutionMaxWidth;

  /// 可选设备像素比覆写。
  final double? devicePixelRatio;

  /// 可选 GPU 采样滤镜质量覆写。
  final FilterQuality? filterQuality;

  /// 首帧加载期间占位组件。
  final Widget? placeholder;

  /// 空地址或加载失败兜底构建器。
  final ImageErrorWidgetBuilder? errorBuilder;

  /// 首帧位图解码就绪通知回调。
  final void Function(ui.Image image, ImageProvider provider)? onImageResolved;

  /// 是否启用默认热点缩略图内存字节 LRU。
  final bool useThumbnailByteLru;

  /// 自定义热点缩略图内存字节 LRU 实例。
  final KonataThumbnailByteLru? byteLru;

  @override
  State<KonataManagedImage> createState() => _KonataManagedImageState();
}

class _KonataManagedImageState extends State<KonataManagedImage> {
  Widget _buildForLogicalWidth(BuildContext context, double logicalWidth) {
    final cleanUrl = widget.url?.trim() ?? '';
    if (cleanUrl.isEmpty) {
      return _buildError(context, StateError('图片地址为空'), null);
    }

    final int target;
    final explicit = widget.explicitTargetWidth;
    if (explicit != null && explicit > 0) {
      target = explicit;
    } else {
      final dpr =
          widget.devicePixelRatio ?? MediaQuery.devicePixelRatioOf(context);
      final rawPhysicalWidth = (logicalWidth * dpr).ceil().clamp(1, 3840);
      if (widget.keepFullResolution) {
        final displayMax = math
            .max(
              rawPhysicalWidth,
              math.min(1920, widget.fullResolutionMaxWidth),
            )
            .clamp(1, widget.fullResolutionMaxWidth);
        target = quantizeKonataImageWidth(
          math.min(rawPhysicalWidth, displayMax),
          maxWidth: displayMax,
        );
      } else {
        target = quantizeKonataImageWidth(
          rawPhysicalWidth.clamp(1, widget.decodeWidth),
          maxWidth: widget.decodeWidth,
        );
      }
    }

    final effectiveLru =
        widget.byteLru ??
        (widget.useThumbnailByteLru ? konataSharedThumbnailByteLru : null);

    final ImageProvider baseProvider = KonataManagedImageProvider(
      cleanUrl,
      loader: widget.loader,
      targetWidth: target,
      variantKey: widget.variantKey,
      loaderToken: widget.loaderToken,
      applyDecodeWidthCap: widget.keepFullResolution,
      byteLru: effectiveLru,
    );
    final effectiveProvider = widget.keepFullResolution
        ? baseProvider
        : ResizeImage.resizeIfNeeded(target, null, baseProvider);
    final filterQuality =
        widget.filterQuality ??
        (widget.keepFullResolution ? FilterQuality.high : FilterQuality.medium);

    final imageWidget = Image(
      image: effectiveProvider,
      width: widget.width,
      height: widget.height,
      fit: widget.fit,
      alignment: widget.alignment,
      filterQuality: filterQuality,
      gaplessPlayback: true,
      frameBuilder: widget.placeholder == null
          ? null
          : (context, child, frame, wasSynchronouslyLoaded) {
              if (wasSynchronouslyLoaded || frame != null) {
                return child;
              }
              return widget.placeholder!;
            },
      errorBuilder: _buildError,
    );

    final observer = widget.onImageResolved;
    if (observer == null) return imageWidget;
    return _KonataImageDecodeObserver(
      provider: effectiveProvider,
      onImageResolved: observer,
      child: imageWidget,
    );
  }

  Widget _buildError(
    BuildContext context,
    Object error,
    StackTrace? stackTrace,
  ) {
    final custom = widget.errorBuilder;
    if (custom != null) {
      return custom(context, error, stackTrace);
    }
    final p = context.palette;
    return Container(
      width: widget.width,
      height: widget.height,
      color: p.softFill,
      alignment: Alignment.center,
      child: Icon(
        Icons.broken_image_outlined,
        size: 18,
        color: p.textMuted.withValues(alpha: 0.45),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final explicitTarget = widget.explicitTargetWidth;
    if (explicitTarget != null && explicitTarget > 0) {
      return _buildForLogicalWidth(context, explicitTarget.toDouble());
    }
    final explicitWidth = widget.width;
    if (explicitWidth != null && explicitWidth.isFinite && explicitWidth > 0) {
      return _buildForLogicalWidth(context, explicitWidth);
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final logicalWidth = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : 1280.0;
        return _buildForLogicalWidth(context, logicalWidth);
      },
    );
  }
}

class _KonataImageDecodeObserver extends StatefulWidget {
  const _KonataImageDecodeObserver({
    required this.provider,
    required this.onImageResolved,
    required this.child,
  });

  final ImageProvider provider;
  final void Function(ui.Image image, ImageProvider provider) onImageResolved;
  final Widget child;

  @override
  State<_KonataImageDecodeObserver> createState() =>
      _KonataImageDecodeObserverState();
}

class _KonataImageDecodeObserverState
    extends State<_KonataImageDecodeObserver> {
  ImageStream? _stream;
  ImageStreamListener? _listener;
  ImageProvider? _listeningProvider;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncStream();
  }

  @override
  void didUpdateWidget(covariant _KonataImageDecodeObserver oldWidget) {
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
      onError: (_, _) => _detachStream(),
    );
    _stream = stream;
    _listener = listener;
    stream.addListener(listener);
  }

  void _handleFrame(ImageInfo info, bool synchronousCall) {
    if (!mounted) return;
    widget.onImageResolved(info.image, widget.provider);
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

/// 封面智能框选对齐锚点有界内存缓存与单飞去重协调器。
final class KonataSmartCoverAlignmentCache {
  static const int _maxCacheEntries = 96;
  final Map<String, Alignment> _entries = <String, Alignment>{};
  final Map<String, Future<Alignment>> _inFlight =
      <String, Future<Alignment>>{};

  /// 同步读取缓存中的取景对齐锚点。
  Alignment? peek(String key) => _entries[key];

  /// 写入对齐锚点并在超限时淘汰最早条目。
  void put(String key, Alignment alignment) {
    _entries.remove(key);
    _entries[key] = alignment;
    while (_entries.length > _maxCacheEntries) {
      _entries.remove(_entries.keys.first);
    }
  }

  /// 对同键并发计算执行单飞去重。
  Future<Alignment> deduplicate(
    String key,
    Future<Alignment> Function() compute,
  ) {
    final cached = _entries[key];
    if (cached != null) return Future<Alignment>.value(cached);
    final running = _inFlight[key];
    if (running != null) return running;
    final future = compute().whenComplete(() {
      _inFlight.remove(key);
    });
    _inFlight[key] = future;
    return future;
  }

  /// 清空缓存。
  void clear() => _entries.clear();
}

/// 竖版海报裁入 `1:1` 或 `16:9` 容器时的智能防切头对齐计算器。
abstract final class KonataSmartCoverFraming {
  /// 竖版海报默认上偏黄金保护锚点（防止居中裁剪切掉角色头部）。
  static const Alignment defaultPosterAlignment = Alignment(0.0, -0.72);

  /// 生成按目标画幅分桶的唯一缓存键。
  static String managedCacheKey({
    required String url,
    String? owner,
    double targetAspectRatio = 1.0,
  }) {
    final arBucket = (targetAspectRatio.clamp(0.25, 4.0) * 100).round();
    return 'managed:${owner ?? ''}:$url@ar$arBucket';
  }

  /// 对低分辨率图像字节执行边缘梯度与暖肤色显著度滑窗寻优。
  static Future<Alignment> computeAndCache(
    String key,
    Uint8List bytes, {
    required bool isPosterFallback,
    double targetAspectRatio = 1.0,
    KonataSmartCoverAlignmentCache? cache,
  }) async {
    final existing = cache?.peek(key);
    if (existing != null) return existing;
    final fallback = isPosterFallback
        ? defaultPosterAlignment
        : Alignment.center;
    if (bytes.length < 32) return fallback;

    ui.Codec? codec;
    ui.FrameInfo? frame;
    try {
      codec = await ui.instantiateImageCodec(bytes, targetWidth: 96);
      frame = await codec.getNextFrame();
      final img = frame.image;
      final byteData = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (byteData == null) return fallback;
      final rgba = Uint8List.view(
        byteData.buffer,
        byteData.offsetInBytes,
        byteData.lengthInBytes,
      );
      final solved = solveRgbaAlignment(
        rgba,
        img.width,
        img.height,
        targetAspectRatio: targetAspectRatio,
      );
      cache?.put(key, solved);
      return solved;
    } catch (_) {
      return fallback;
    } finally {
      frame?.image.dispose();
      codec?.dispose();
    }
  }

  /// 纯内存计算对应目标宽高比的最佳取景对齐锚点。
  static Alignment solveRgbaAlignment(
    Uint8List rgba,
    int w,
    int h, {
    double targetAspectRatio = 1.0,
  }) {
    if (w <= 4 || h <= 4 || rgba.length < w * h * 4) {
      return Alignment.center;
    }
    final safeTarget = targetAspectRatio.clamp(0.25, 4.0);
    final aspect = w / h;
    if ((aspect - safeTarget).abs() / safeTarget <= 0.09) {
      return Alignment.center;
    }
    if (aspect < safeTarget) {
      final winH = (w / safeTarget).round().clamp(1, h);
      return _solveVerticalWindow(rgba, w, h, winH: winH);
    }
    final winW = (h * safeTarget).round().clamp(1, w);
    return _solveHorizontalWindow(rgba, w, h, winW: winW);
  }

  static Alignment _solveVerticalWindow(
    Uint8List rgba,
    int w,
    int h, {
    required int winH,
  }) {
    final maxStart = h - winH;
    if (maxStart <= 0) return Alignment.center;

    final rowScores = Float64List(h);
    for (var y = 0; y < h; y++) {
      var grad = 0.0;
      var skin = 0.0;
      final rowOff = y * w * 4;
      for (var x = 1; x < w - 1; x++) {
        final idx = rowOff + x * 4;
        final prev = idx - 4;
        final r = rgba[idx].toDouble();
        final g = rgba[idx + 1].toDouble();
        final b = rgba[idx + 2].toDouble();
        final lum = 0.2126 * r + 0.7152 * g + 0.0722 * b;
        final pLum =
            0.2126 * rgba[prev] +
            0.7152 * rgba[prev + 1] +
            0.0722 * rgba[prev + 2];
        grad += (lum - pLum).abs() / 255.0;
        if (r > g && g > b && (r - b) > 18 && r > 90) {
          skin += 0.35;
        }
      }
      final yNorm = y / math.max(1, h - 1);
      final upperBias = 1.0 + math.max(0.0, 0.42 - yNorm) * 0.9;
      rowScores[y] = (grad + skin) * upperBias;
    }

    var bestStart = 0;
    var bestScore = -1.0;
    for (var start = 0; start <= maxStart; start++) {
      var sum = 0.0;
      for (var dy = 0; dy < winH; dy++) {
        sum += rowScores[start + dy];
      }
      if (sum > bestScore) {
        bestScore = sum;
        bestStart = start;
      }
    }
    final yAlign = -1.0 + 2.0 * (bestStart / maxStart);
    return Alignment(0.0, yAlign.clamp(-1.0, 1.0));
  }

  static Alignment _solveHorizontalWindow(
    Uint8List rgba,
    int w,
    int h, {
    required int winW,
  }) {
    final maxStart = w - winW;
    if (maxStart <= 0) return Alignment.center;

    final colScores = Float64List(w);
    for (var x = 0; x < w; x++) {
      var score = 0.0;
      for (var y = 1; y < h - 1; y++) {
        final idx = (y * w + x) * 4;
        final up = ((y - 1) * w + x) * 4;
        final lum =
            0.2126 * rgba[idx] +
            0.7152 * rgba[idx + 1] +
            0.0722 * rgba[idx + 2];
        final uLum =
            0.2126 * rgba[up] + 0.7152 * rgba[up + 1] + 0.0722 * rgba[up + 2];
        score += (lum - uLum).abs() / 255.0;
      }
      colScores[x] = score;
    }

    var bestStart = 0;
    var bestScore = -1.0;
    for (var start = 0; start <= maxStart; start++) {
      var sum = 0.0;
      for (var dx = 0; dx < winW; dx++) {
        sum += colScores[start + dx];
      }
      if (sum > bestScore) {
        bestScore = sum;
        bestStart = start;
      }
    }
    final xAlign = -1.0 + 2.0 * (bestStart / maxStart);
    return Alignment(xAlign.clamp(-1.0, 1.0), 0.0);
  }
}

/// 通用智能框选对齐构建器（根据目标画幅异步计算最优裁剪对齐锚点）。
class KonataCoverAlignmentBuilder extends StatefulWidget {
  /// 创建智能框选对齐构建器。
  const KonataCoverAlignmentBuilder({
    super.key,
    required this.url,
    required this.loader,
    required this.builder,
    this.owner,
    this.variantKey,
    this.isPosterFallback = false,
    this.targetAspectRatio = 1.0,
    this.cache,
  });

  /// 图片地址。
  final String url;

  /// 受管字节加载器。
  final KonataManagedImageLoader loader;

  /// 所属作品主键（用于缓存分桶）。
  final String? owner;

  /// 透传给加载器的分桶标识。
  final Object? variantKey;

  /// 是否来自竖版作品海报回落。
  final bool isPosterFallback;

  /// 目标容器宽高比。
  final double targetAspectRatio;

  /// 可选外部共享对齐缓存。
  final KonataSmartCoverAlignmentCache? cache;

  /// 携带解析出的最佳对齐锚点构建内容。
  final Widget Function(BuildContext context, Alignment alignment) builder;

  @override
  State<KonataCoverAlignmentBuilder> createState() =>
      _KonataCoverAlignmentBuilderState();
}

class _KonataCoverAlignmentBuilderState
    extends State<KonataCoverAlignmentBuilder> {
  static final KonataSmartCoverAlignmentCache _fallbackCache =
      KonataSmartCoverAlignmentCache();

  late String _activeKey;
  late Alignment _alignment;
  int _epoch = 0;

  KonataSmartCoverAlignmentCache get _effectiveCache =>
      widget.cache ?? _fallbackCache;

  @override
  void initState() {
    super.initState();
    _syncTarget(initial: true);
  }

  @override
  void didUpdateWidget(covariant KonataCoverAlignmentBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url ||
        oldWidget.owner != widget.owner ||
        oldWidget.isPosterFallback != widget.isPosterFallback ||
        (oldWidget.targetAspectRatio - widget.targetAspectRatio).abs() > 0.05) {
      _syncTarget(initial: false);
    }
  }

  void _syncTarget({required bool initial}) {
    final key = KonataSmartCoverFraming.managedCacheKey(
      url: widget.url.trim(),
      owner: widget.owner,
      targetAspectRatio: widget.targetAspectRatio,
    );
    _activeKey = key;
    final cached = _effectiveCache.peek(key);
    final nextInitial =
        cached ??
        (widget.isPosterFallback
            ? KonataSmartCoverFraming.defaultPosterAlignment
            : Alignment.center);
    if (initial) {
      _alignment = nextInitial;
    } else if (_alignment != nextInitial) {
      setState(() => _alignment = nextInitial);
    }
    if (cached == null && widget.url.trim().isNotEmpty) {
      unawaited(_resolveAsync(key, ++_epoch));
    }
  }

  Future<void> _resolveAsync(String key, int epoch) async {
    Future<Alignment> compute() async {
      final Uint8List? bytes;
      try {
        bytes = await widget.loader(
          widget.url.trim(),
          targetWidth: 320,
          variantKey: widget.variantKey,
        );
      } catch (_) {
        return widget.isPosterFallback
            ? KonataSmartCoverFraming.defaultPosterAlignment
            : Alignment.center;
      }
      if (bytes == null || bytes.isEmpty) {
        return widget.isPosterFallback
            ? KonataSmartCoverFraming.defaultPosterAlignment
            : Alignment.center;
      }
      return KonataSmartCoverFraming.computeAndCache(
        key,
        bytes,
        isPosterFallback: widget.isPosterFallback,
        targetAspectRatio: widget.targetAspectRatio,
        cache: _effectiveCache,
      );
    }

    final computed = await _effectiveCache.deduplicate(key, compute);
    if (!mounted || epoch != _epoch || key != _activeKey) return;
    if ((computed.x - _alignment.x).abs() > 0.01 ||
        (computed.y - _alignment.y).abs() > 0.01) {
      setState(() => _alignment = computed);
    }
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _alignment);
}

/// 默认暗色画布背景兜底构建器（供全屏背景原画失败回退使用）。
Widget konataBackdropErrorPlaceholder(
  BuildContext context,
  Object error,
  StackTrace? stackTrace,
) => const ColoredBox(color: KonataTheme.cinemaObsidian);
