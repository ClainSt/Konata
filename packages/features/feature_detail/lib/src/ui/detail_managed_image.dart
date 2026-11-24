import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:engine_scraping/engine_scraping.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:konata_design_system/konata_design_system.dart';

/// 将物理目标像素宽度向上规整至离散档位，避免窗口拖拽微调宽度导致 `ImageCache` 反复重复解码。
int quantizeManagedImageWidth(int rawPhysicalWidth, {int maxWidth = 3840}) {
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

/// 图片缓存唯一标识键。
typedef DetailManagedImageKey = ({
  String url,
  String? owner,
  ManagedArtwork artwork,
  int targetWidth,
  TmdbImageSize? imageSize,
  bool isHeroBackdrop,
  bool applyDecodeWidthCap,
  ManagedImageLoader loader,
});

/// 支持按显示物理像素或原画档位按需解码的图片提供器。
class DetailManagedImageProvider
    extends ImageProvider<DetailManagedImageKey> {
  /// 创建可控解码尺寸的图片提供器。
  const DetailManagedImageProvider(
    this.url, {
    required this.loader,
    required this.targetWidth,
    this.artwork = ManagedArtwork.poster,
    this.imageSize,
    this.isHeroBackdrop = false,
    this.applyDecodeWidthCap = false,
    this.owner,
  });

  /// 图片地址或缓存路径。
  final String url;

  /// 所属作品主键。
  final String? owner;

  /// 艺术图分类（海报 / 剧照 / 背景 / 透明徽标）。
  final ManagedArtwork artwork;

  /// 目标物理解码宽度。
  final int targetWidth;

  /// 显式请求的 `TMDB` 分辨率档位。
  final TmdbImageSize? imageSize;

  /// 是否作为全屏背景大画布渲染。
  final bool isHeroBackdrop;

  /// 是否在自身解码阶段施加宽度上限。
  final bool applyDecodeWidthCap;

  /// 字节加载回调。
  final ManagedImageLoader loader;

  @override
  Future<DetailManagedImageKey> obtainKey(ImageConfiguration configuration) {
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
    DetailManagedImageKey key,
    ImageDecoderCallback decode,
  ) {
    return MultiFrameImageStreamCompleter(
      codec: _decode(key, decode),
      scale: 1,
      debugLabel: key.url,
    );
  }

  Future<ui.Codec> _decode(
    DetailManagedImageKey key,
    ImageDecoderCallback decode,
  ) async {
    try {
      final bytes = key.loader is ManagedArtworkLoader
          ? await (key.loader as ManagedArtworkLoader)(
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
      if (!key.applyDecodeWidthCap || key.targetWidth <= 0) {
        final codec = await decode(buffer);
        return codec;
      }
      final codec = await decode(
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
      return codec;
    } catch (_) {
      PaintingBinding.instance.imageCache.evict(key);
      rethrow;
    }
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is DetailManagedImageProvider &&
        other.url == url &&
        other.owner == owner &&
        other.artwork == artwork &&
        other.targetWidth == targetWidth &&
        other.imageSize == imageSize &&
        other.isHeroBackdrop == isHeroBackdrop &&
        other.applyDecodeWidthCap == applyDecodeWidthCap &&
        other.loader == loader;
  }

  @override
  int get hashCode => Object.hash(
    url,
    owner,
    artwork,
    targetWidth,
    imageSize,
    isHeroBackdrop,
    applyDecodeWidthCap,
    loader,
  );
}

/// 详情页自适应物理分辨率受管图片组件（严格隔离至设计系统，绝不引入 `material_ui`）。
class DetailManagedImage extends StatefulWidget {
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

  /// 首帧解码就绪通知回调。
  final void Function(ui.Image image, ImageProvider provider)? onImageResolved;

  @override
  State<DetailManagedImage> createState() => _DetailManagedImageState();
}

class _DetailManagedImageState extends State<DetailManagedImage> {
  Widget _buildForLogicalWidth(BuildContext context, double logicalWidth) {
    final dpr =
        widget.devicePixelRatio ?? MediaQuery.devicePixelRatioOf(context);
    final rawPhysicalWidth = (logicalWidth * dpr).ceil().clamp(1, 3840);

    final keepFullResolution =
        widget.isHeroBackdrop ||
        widget.imageSize == TmdbImageSize.original ||
        widget.artwork == ManagedArtwork.backdrop ||
        widget.artwork == ManagedArtwork.logo;
    final effectiveSize =
        widget.imageSize ??
        (keepFullResolution ? TmdbImageSize.original : null);
    final int target;
    if (widget.artwork == ManagedArtwork.logo) {
      target = quantizeManagedImageWidth(
        math.min(rawPhysicalWidth, 1280),
        maxWidth: 1280,
      );
    } else if (keepFullResolution) {
      final displayMax = math.max(rawPhysicalWidth, 1920).clamp(1, 2560);
      target = quantizeManagedImageWidth(
        math.min(rawPhysicalWidth, displayMax),
        maxWidth: displayMax,
      );
    } else {
      target = quantizeManagedImageWidth(
        rawPhysicalWidth.clamp(1, widget.decodeWidth),
        maxWidth: widget.decodeWidth,
      );
    }

    final ImageProvider baseProvider = DetailManagedImageProvider(
      widget.url,
      loader: widget.loader,
      targetWidth: target,
      artwork: widget.artwork,
      imageSize: effectiveSize,
      isHeroBackdrop: widget.isHeroBackdrop,
      applyDecodeWidthCap: keepFullResolution,
      owner: widget.owner,
    );
    final effectiveProvider = keepFullResolution
        ? baseProvider
        : ResizeImage.resizeIfNeeded(target, null, baseProvider);
    final filterQuality =
        widget.filterQuality ??
        (keepFullResolution ? FilterQuality.high : FilterQuality.medium);

    final imageWidget = Image(
      image: effectiveProvider,
      width: widget.width,
      height: widget.height,
      fit: widget.fit,
      alignment: widget.alignment,
      filterQuality: filterQuality,
      gaplessPlayback: true,
      errorBuilder: widget.errorBuilder ?? _defaultErrorBuilder,
    );

    final observer = widget.onImageResolved;
    if (observer == null) return imageWidget;
    return _ManagedImageDecodeObserver(
      provider: effectiveProvider,
      onImageResolved: observer,
      child: imageWidget,
    );
  }

  Widget _defaultErrorBuilder(
    BuildContext context,
    Object error,
    StackTrace? stackTrace,
  ) {
    if (widget.artwork == ManagedArtwork.logo) {
      return const SizedBox.shrink();
    }
    if (widget.isHeroBackdrop || widget.artwork == ManagedArtwork.backdrop) {
      return const ColoredBox(color: KonataTheme.cinemaObsidian);
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
final class DetailSmartCoverAlignmentCache {
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
abstract final class DetailSmartCoverFraming {
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
    DetailSmartCoverAlignmentCache? cache,
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

/// 受管图片智能框选对齐构建器（根据目标画幅异步计算最优裁剪对齐锚点）。
class ManagedCoverAlignmentBuilder extends StatefulWidget {
  /// 创建智能框选对齐构建器。
  const ManagedCoverAlignmentBuilder({
    super.key,
    required this.url,
    required this.loader,
    required this.builder,
    this.owner,
    this.artwork = ManagedArtwork.poster,
    this.isPosterFallback = false,
    this.targetAspectRatio = 1.0,
    this.cache,
  });

  /// 图片地址。
  final String url;

  /// 受管字节加载器。
  final ManagedImageLoader loader;

  /// 所属作品主键。
  final String? owner;

  /// 图片类别。
  final ManagedArtwork artwork;

  /// 是否来自竖版作品海报回落。
  final bool isPosterFallback;

  /// 目标容器宽高比。
  final double targetAspectRatio;

  /// 可选外部共享对齐缓存。
  final DetailSmartCoverAlignmentCache? cache;

  /// 携带解析出的最佳对齐锚点构建内容。
  final Widget Function(BuildContext context, Alignment alignment) builder;

  @override
  State<ManagedCoverAlignmentBuilder> createState() =>
      _ManagedCoverAlignmentBuilderState();
}

class _ManagedCoverAlignmentBuilderState
    extends State<ManagedCoverAlignmentBuilder> {
  static final DetailSmartCoverAlignmentCache _fallbackCache =
      DetailSmartCoverAlignmentCache();

  late String _activeKey;
  late Alignment _alignment;
  int _epoch = 0;

  DetailSmartCoverAlignmentCache get _effectiveCache =>
      widget.cache ?? _fallbackCache;

  @override
  void initState() {
    super.initState();
    _syncTarget(initial: true);
  }

  @override
  void didUpdateWidget(covariant ManagedCoverAlignmentBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url ||
        oldWidget.owner != widget.owner ||
        oldWidget.isPosterFallback != widget.isPosterFallback ||
        (oldWidget.targetAspectRatio - widget.targetAspectRatio).abs() > 0.05) {
      _syncTarget(initial: false);
    }
  }

  void _syncTarget({required bool initial}) {
    final key = DetailSmartCoverFraming.managedCacheKey(
      url: widget.url.trim(),
      owner: widget.owner,
      targetAspectRatio: widget.targetAspectRatio,
    );
    _activeKey = key;
    final cached = _effectiveCache.peek(key);
    final nextInitial =
        cached ??
        (widget.isPosterFallback
            ? DetailSmartCoverFraming.defaultPosterAlignment
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
      final Uint8List bytes;
      try {
        final l = widget.loader;
        bytes = l is ManagedArtworkLoader
            ? await l(
                widget.url.trim(),
                targetWidth: 320,
                imageSize: TmdbImageSize.w342,
                ownerWorkId: widget.owner,
                artwork: widget.artwork,
              )
            : await l(
                widget.url.trim(),
                targetWidth: 320,
                imageSize: TmdbImageSize.w342,
              );
      } catch (_) {
        return widget.isPosterFallback
            ? DetailSmartCoverFraming.defaultPosterAlignment
            : Alignment.center;
      }
      if (bytes.isEmpty) {
        return widget.isPosterFallback
            ? DetailSmartCoverFraming.defaultPosterAlignment
            : Alignment.center;
      }
      return DetailSmartCoverFraming.computeAndCache(
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
