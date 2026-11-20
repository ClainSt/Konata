import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../application/providers/artwork_provider.dart';
import '../../application/providers/diagnostics_providers.dart';
import '../../application/providers/library_providers.dart';
import '../../application/providers/scan_lightbox_loader.dart';
import '../../domain/formatting/image_header_parser.dart';
import '../../domain/matching/supplementary_subclassifier.dart';
import '../../domain/models/media_source.dart';
import '../../domain/models/media_variant.dart';
import '../../infrastructure/cache/scan_thumbnail_scheduler.dart';
import '../theme/konata_adaptive_tokens.dart';
import '../theme/konata_palette.dart';
import '../theme/konata_theme.dart';
import '../widgets/design_system/konata_toast.dart';

part 'scan_lightbox_widgets.dart';

/// 灯箱画册阅读缩放预设模式。
enum _ScanFitMode {
  /// 完整适应可视窗口（`1.0x`，无裁切）。
  fitWindow('适应窗口'),

  /// 撑满视口宽度（适合竖版长页 Booklet 纵向阅读）。
  fitWidth('适应宽度'),

  /// 撑满视口高度（适合宽幅双页跨页横向浏览）。
  fitHeight('适应高度'),

  /// 按图像真实像素比例 `1:1` 原寸查看。
  original100('100% 原寸');

  const _ScanFitMode(this.label);

  /// 简体中文按钮提示与菜单文案。
  final String label;
}

class _CachedFullScan {
  const _CachedFullScan({
    required this.provider,
    required this.byteLength,
    this.pixelWidth,
    this.pixelHeight,
  });

  final MemoryImage provider;
  final int byteLength;
  final int? pixelWidth;
  final int? pixelHeight;
}

/// Scan 画集毛玻璃全屏高清内置灯箱：
/// - 打开期间暂停后台远程缩略图队列，独占远端带宽防 WebDAV 风控限流；
/// - 两阶段渐进替换：若本地 `scans/` 已有 `.webp` 微缩图则 0ms 瞬时铺满，原图就绪后保留平移/缩放锚点无缝锐化；
/// - 有界内存滑窗 LRU（最多保留 4 张且总字节 `<= 96 MB`，关闭即全量 `evict()`，原图严格零落盘）+ 单通道空闲静默预读下一张；
/// - 承接当前二级分卷筛选并支持顶栏切换分卷、底部只读缓存胶片条、全屏沉浸切换、四档缩放预设与触控滑动翻页。
class ScanLightboxDialog extends ConsumerStatefulWidget {
  /// 创建 Scan 画集高清大图浏览弹窗。
  const ScanLightboxDialog({
    super.key,
    required this.bundle,
    required this.initialVariant,
    this.initialVolumeKey,
  });

  /// 当前作品详情数据包。
  final WorkDetailBundle bundle;

  /// 初始定位的扫图条目。
  final MediaVariant initialVariant;

  /// 可选承接详情页或完整列表当前激活的二级分卷筛选键。
  final String? initialVolumeKey;

  @override
  ConsumerState<ScanLightboxDialog> createState() => _ScanLightboxDialogState();
}

class _ScanLightboxDialogState extends ConsumerState<ScanLightboxDialog> {
  static const double _minScale = 1.0;
  static const double _maxScale = 5.0;
  static const int _maxLruEntries = 4;
  static const int _maxLruTotalBytes = 96 * 1024 * 1024;

  final TransformationController _transformController =
      TransformationController();
  final ScrollController _filmstripController = ScrollController();

  late final ScanThumbnailScheduler _scanScheduler;
  late final ScanVolumeGroupSummary _scanSummary;

  String? _selectedVolumeKey;
  late List<MediaVariant> _scopedScans;
  late int _index;

  int _loadEpoch = 0;
  bool _loadingFull = false;
  String? _errorText;
  MemoryImage? _placeholderProvider;
  MemoryImage? _activeImageProvider;
  int? _activePixelWidth;
  int? _activePixelHeight;
  double _currentScale = 1.0;
  _ScanFitMode _fitMode = _ScanFitMode.fitWindow;

  bool _fullscreen = false;
  bool _chromeVisible = true;
  bool _showFilmstrip = true;

  // 有界内存滑窗 LRU（最近访问在队尾，关闭弹窗即全量 evict，严格零原图落盘）
  final LinkedHashMap<String, _CachedFullScan> _memoryLru =
      LinkedHashMap<String, _CachedFullScan>();
  int _memoryLruBytes = 0;

  ScanImageLoadHandle? _activeLoadHandle;
  ScanImageLoadHandle? _prefetchHandle;
  String? _prefetchVariantId;

  // 胶片条只读本地缓存微缩图映射（绝不发网络请求）
  final Map<String, Uint8List?> _filmstripCache = <String, Uint8List?>{};
  final Set<String> _filmstripRequested = <String>{};

  Offset? _lastDoubleTapLocalPos;
  Size _lastViewportSize = Size.zero;
  double _touchSwipeDeltaX = 0.0;
  void Function(String message)? _logError;

  @override
  void initState() {
    super.initState();
    _scanScheduler = ref.read(scanThumbnailSchedulerProvider);
    _scanScheduler.pauseRemote();

    _transformController.addListener(_handleTransformChanged);
    _scanSummary = SupplementarySubclassifier.groupScanVariants(
      widget.bundle.scanVariants,
    );

    final initKey = widget.initialVolumeKey;
    if (initKey != null &&
        _scanSummary.chips.length >= 2 &&
        _scanSummary.chips.any((c) => c.key == initKey)) {
      _selectedVolumeKey = initKey;
    } else {
      _selectedVolumeKey = null;
    }
    _scopedScans = _computeScopedScans(_selectedVolumeKey);
    final found = _scopedScans.indexWhere(
      (s) => s.id == widget.initialVariant.id,
    );
    _index = found >= 0 ? found : 0;
    _showFilmstrip = _scopedScans.length > 1;

    if (_scopedScans.isNotEmpty) {
      unawaited(_loadCurrentScan());
    }
  }

  @override
  void dispose() {
    _transformController.removeListener(_handleTransformChanged);
    _transformController.dispose();
    _filmstripController.dispose();
    unawaited(_abortAllAndEvictAll());
    _scanScheduler.resumeRemote();
    super.dispose();
  }

  List<MediaVariant> _computeScopedScans(String? volumeKey) {
    final all = widget.bundle.scanVariants;
    if (volumeKey == null) return all;
    final filtered = all
        .where((v) => _scanSummary.byVariantId[v.id]?.volumeKey == volumeKey)
        .toList(growable: false);
    return filtered.isEmpty ? all : filtered;
  }

  void _handleTransformChanged() {
    final scale = _transformController.value.storage[0].clamp(
      _minScale,
      _maxScale,
    );
    if ((scale - _currentScale).abs() > 0.005 && mounted) {
      setState(() => _currentScale = scale);
    }
  }

  Future<void> _cancelActiveLoad() async {
    final handle = _activeLoadHandle;
    _activeLoadHandle = null;
    if (handle != null) {
      try {
        await handle.cancel();
      } catch (e) {
        _logError?.call('取消扫图加载任务失败：$e');
      }
    }
  }

  Future<void> _cancelPrefetch() async {
    final handle = _prefetchHandle;
    _prefetchHandle = null;
    _prefetchVariantId = null;
    if (handle != null) {
      try {
        await handle.cancel();
      } catch (e) {
        _logError?.call('取消扫图预读任务失败：$e');
      }
    }
  }

  Future<void> _evictPlaceholder() async {
    final prev = _placeholderProvider;
    _placeholderProvider = null;
    if (prev != null) {
      try {
        await prev.evict();
      } catch (error) {
        _logError?.call('回收占位微缩图缓存失败：$error');
      }
    }
  }

  Future<void> _abortAllAndEvictAll() async {
    await _cancelActiveLoad();
    await _cancelPrefetch();
    await _evictPlaceholder();
    _activeImageProvider = null;

    final entries = _memoryLru.values.toList(growable: false);
    _memoryLru.clear();
    _memoryLruBytes = 0;
    for (final entry in entries) {
      try {
        await entry.provider.evict();
      } catch (e) {
        _logError?.call('回收扫图位图缓存失败：$e');
      }
    }
    _filmstripCache.clear();
    _filmstripRequested.clear();
  }

  _CachedFullScan? _getFromLru(String variantId) {
    final existing = _memoryLru.remove(variantId);
    if (existing != null) {
      _memoryLru[variantId] = existing;
    }
    return existing;
  }

  void _putToLru(
    String variantId,
    _CachedFullScan entry, {
    String? pinnedVariantId,
  }) {
    final replaced = _memoryLru.remove(variantId);
    if (replaced != null) {
      _memoryLruBytes -= replaced.byteLength;
      unawaited(replaced.provider.evict().catchError((_) => false));
    }
    _memoryLru[variantId] = entry;
    _memoryLruBytes += entry.byteLength;

    while (_memoryLru.length > _maxLruEntries ||
        (_memoryLruBytes > _maxLruTotalBytes && _memoryLru.length > 1)) {
      String? victimKey;
      for (final key in _memoryLru.keys) {
        if (key != pinnedVariantId && key != variantId) {
          victimKey = key;
          break;
        }
      }
      if (victimKey == null) break;
      final victim = _memoryLru.remove(victimKey);
      if (victim != null) {
        _memoryLruBytes -= victim.byteLength;
        unawaited(victim.provider.evict().catchError((_) => false));
      }
    }
  }

  Future<void> _selectVolume(String? nextVolumeKey) async {
    if (_selectedVolumeKey == nextVolumeKey) return;
    final nextList = _computeScopedScans(nextVolumeKey);
    if (nextList.isEmpty) return;
    setState(() {
      _selectedVolumeKey = nextVolumeKey;
      _scopedScans = nextList;
      _index = 0;
      _errorText = null;
      _fitMode = _ScanFitMode.fitWindow;
    });
    _resetZoom();
    _scrollFilmstripToIndex(0);
    await _loadCurrentScan();
  }

  Future<void> _selectIndex(int nextIndex) async {
    if (nextIndex < 0 || nextIndex >= _scopedScans.length || nextIndex == _index) {
      return;
    }
    setState(() {
      _index = nextIndex;
      _errorText = null;
      _fitMode = _ScanFitMode.fitWindow;
    });
    _resetZoom();
    _scrollFilmstripToIndex(nextIndex);
    await _loadCurrentScan();
  }

  void _scrollFilmstripToIndex(int targetIndex) {
    if (!_filmstripController.hasClients) return;
    const itemExtent = 66.0;
    final viewportW = _filmstripController.position.viewportDimension;
    final targetOffset = (targetIndex * itemExtent - viewportW / 2 + itemExtent / 2)
        .clamp(0.0, _filmstripController.position.maxScrollExtent);
    unawaited(
      _filmstripController.animateTo(
        targetOffset,
        duration: KonataTheme.motionFast,
        curve: Curves.easeOutCubic,
      ),
    );
  }

  Future<void> _loadCurrentScan() async {
    if (_scopedScans.isEmpty) return;

    final loader = ref.read(scanLightboxLoaderProvider);
    final logStore = ref.read(diagnosticsLogStoreProvider);
    _logError = (msg) => logStore.record('SCAN', msg, isError: true);

    final epoch = ++_loadEpoch;
    await _cancelActiveLoad();
    await _cancelPrefetch();
    if (!mounted || epoch != _loadEpoch) return;

    final safeIdx = _index.clamp(0, _scopedScans.length - 1);
    final current = _scopedScans[safeIdx];
    final source = widget.bundle.sourcesById[current.sourceId];

    // 1. 优先 0ms 命中会话内存滑窗 LRU
    final lruHit = _getFromLru(current.id);
    if (lruHit != null) {
      await _evictPlaceholder();
      if (!mounted || epoch != _loadEpoch) return;
      setState(() {
        _activeImageProvider = lruHit.provider;
        _activePixelWidth = lruHit.pixelWidth;
        _activePixelHeight = lruHit.pixelHeight;
        _loadingFull = false;
        _errorText = null;
      });
      _scheduleIdlePrefetchNext(safeIdx, epoch);
      return;
    }

    if (source == null) {
      await _evictPlaceholder();
      if (!mounted || epoch != _loadEpoch) return;
      setState(() {
        _activeImageProvider = null;
        _loadingFull = false;
        _errorText = '找不到当前画集所属媒体源配置';
      });
      return;
    }

    // 2. 两阶段渐进占位：先 0ms 读取本地 scans/*.webp 缓存铺满画布（绝不发网络请求）
    Uint8List? thumbPlaceholder;
    try {
      thumbPlaceholder = await _scanScheduler.readCachedThumbnailOnly(
        workId: widget.bundle.work.id,
        workTitle: widget.bundle.work.title,
        variant: current,
      );
    } catch (error) {
      _logError?.call('读取灯箱本地微缩图占位失败：$error');
    }
    if (!mounted || epoch != _loadEpoch) return;

    await _evictPlaceholder();
    if (!mounted || epoch != _loadEpoch) return;

    MemoryImage? nextPlaceholder;
    if (thumbPlaceholder != null && thumbPlaceholder.isNotEmpty) {
      nextPlaceholder = MemoryImage(thumbPlaceholder);
      _filmstripCache[current.id] = thumbPlaceholder;
    }

    setState(() {
      _placeholderProvider = nextPlaceholder;
      _activeImageProvider = null;
      _activePixelWidth = null;
      _activePixelHeight = null;
      _loadingFull = true;
      _errorText = null;
    });

    // 3. 单次流式拉取完整原图并无缝锐化替换（严格保留当前缩放与平移变换矩阵）
    try {
      final handle = loader.startLoad(variant: current, source: source);
      _activeLoadHandle = handle;
      final bytes = await handle.future;
      if (identical(_activeLoadHandle, handle)) {
        _activeLoadHandle = null;
      }

      if (!mounted || epoch != _loadEpoch) return;

      if (bytes == null || bytes.isEmpty) {
        setState(() {
          _loadingFull = false;
          _errorText = _placeholderProvider == null ? '无法读取当前画集图像内容' : null;
        });
        return;
      }

      final dims = ImageHeaderParser.parseDimensions(bytes);
      if (dims != null) {
        _scanScheduler.recordAspectRatio(
          current.id,
          dims.width / dims.height,
        );
      }
      final provider = MemoryImage(bytes);
      _putToLru(
        current.id,
        _CachedFullScan(
          provider: provider,
          byteLength: bytes.length,
          pixelWidth: dims?.width,
          pixelHeight: dims?.height,
        ),
        pinnedVariantId: current.id,
      );

      if (!mounted || epoch != _loadEpoch) return;
      setState(() {
        _activeImageProvider = provider;
        _activePixelWidth = dims?.width;
        _activePixelHeight = dims?.height;
        _loadingFull = false;
        _errorText = null;
      });
      await _evictPlaceholder();

      // 4. 当前张原图就绪且远端通道空闲后，单通道静默预读下一张
      _scheduleIdlePrefetchNext(safeIdx, epoch);
    } catch (err) {
      logStore.record('SCAN', '加载高清画集失败：$err', isError: true);
      if (!mounted || epoch != _loadEpoch) return;
      final cleanMsg = err is StateError ? err.message : '加载高清画集失败: $err';
      setState(() {
        _loadingFull = false;
        _errorText = cleanMsg;
      });
    }
  }

  void _scheduleIdlePrefetchNext(int currentIndex, int epoch) {
    final nextIdx = currentIndex + 1;
    if (nextIdx >= _scopedScans.length) return;
    final nextVariant = _scopedScans[nextIdx];
    if (_memoryLru.containsKey(nextVariant.id) ||
        _prefetchVariantId == nextVariant.id) {
      return;
    }
    final source = widget.bundle.sourcesById[nextVariant.sourceId];
    if (source == null) return;

    final loader = ref.read(scanLightboxLoaderProvider);
    final handle = loader.startLoad(variant: nextVariant, source: source);
    _prefetchHandle = handle;
    _prefetchVariantId = nextVariant.id;

    unawaited(() async {
      try {
        final bytes = await handle.future;
        if (identical(_prefetchHandle, handle)) {
          _prefetchHandle = null;
          _prefetchVariantId = null;
        }
        if (!mounted || epoch != _loadEpoch || bytes == null || bytes.isEmpty) {
          return;
        }
        final dims = ImageHeaderParser.parseDimensions(bytes);
        if (dims != null) {
          _scanScheduler.recordAspectRatio(
            nextVariant.id,
            dims.width / dims.height,
          );
        }
        final currentId =
            _scopedScans[_index.clamp(0, _scopedScans.length - 1)].id;
        _putToLru(
          nextVariant.id,
          _CachedFullScan(
            provider: MemoryImage(bytes),
            byteLength: bytes.length,
            pixelWidth: dims?.width,
            pixelHeight: dims?.height,
          ),
          pinnedVariantId: currentId,
        );
      } catch (_) {
        if (identical(_prefetchHandle, handle)) {
          _prefetchHandle = null;
          _prefetchVariantId = null;
        }
      }
    }());
  }

  void _ensureFilmstripThumbnail(MediaVariant variant) {
    if (_filmstripRequested.contains(variant.id)) return;
    _filmstripRequested.add(variant.id);
    unawaited(() async {
      final cached = await _scanScheduler.readCachedThumbnailOnly(
        workId: widget.bundle.work.id,
        workTitle: widget.bundle.work.title,
        variant: variant,
      );
      if (!mounted) return;
      if (cached != null && cached.isNotEmpty) {
        setState(() {
          _filmstripCache[variant.id] = cached;
        });
      }
    }());
  }

  void _resetZoom() {
    _transformController.value = Matrix4.identity();
    if (mounted) {
      setState(() {
        _currentScale = 1.0;
        _fitMode = _ScanFitMode.fitWindow;
      });
    }
  }

  void _applyFitMode(_ScanFitMode mode) {
    if (mode == _ScanFitMode.fitWindow || _lastViewportSize.isEmpty) {
      _resetZoom();
      return;
    }

    final vw = _lastViewportSize.width;
    final vh = _lastViewportSize.height;
    final current = _scopedScans[_index.clamp(0, _scopedScans.length - 1)];
    final imgW = _activePixelWidth?.toDouble();
    final imgH = _activePixelHeight?.toDouble();
    final ratio = (imgW != null && imgH != null && imgH > 0)
        ? imgW / imgH
        : (_scanScheduler.cachedAspectRatio(current.id) ?? (vw / vh));

    // 计算当前 BoxFit.contain 下图像在视口中的初始渲染矩形
    final viewportRatio = vw / vh;
    final double fittedW;
    final double fittedH;
    if (ratio >= viewportRatio) {
      fittedW = vw;
      fittedH = vw / ratio;
    } else {
      fittedH = vh;
      fittedW = vh * ratio;
    }

    double targetScale = 1.0;
    double tx = 0.0;
    double ty = 0.0;

    switch (mode) {
      case _ScanFitMode.fitWindow:
        targetScale = 1.0;
      case _ScanFitMode.fitWidth:
        targetScale = (vw / math.max(1.0, fittedW)).clamp(_minScale, _maxScale);
        // 适应宽度时居中横向并锚定顶部，方便竖页画册从上往下阅读
        tx = vw * (1.0 - targetScale) / 2.0;
        ty = 0.0;
      case _ScanFitMode.fitHeight:
        targetScale = (vh / math.max(1.0, fittedH)).clamp(_minScale, _maxScale);
        tx = vw * (1.0 - targetScale) / 2.0;
        ty = vh * (1.0 - targetScale) / 2.0;
      case _ScanFitMode.original100:
        final dpr = MediaQuery.devicePixelRatioOf(context);
        if (imgW != null && imgW > 0) {
          final logicalNativeW = imgW / math.max(1.0, dpr);
          targetScale = (logicalNativeW / math.max(1.0, fittedW)).clamp(
            _minScale,
            _maxScale,
          );
        } else {
          targetScale = 2.0;
        }
        tx = vw * (1.0 - targetScale) / 2.0;
        ty = vh * (1.0 - targetScale) / 2.0;
    }

    if (targetScale <= 1.005) {
      _resetZoom();
      return;
    }

    final minTx = vw * (1.0 - targetScale);
    final minTy = vh * (1.0 - targetScale);
    final clampedTx = tx.clamp(minTx <= 0 ? minTx : 0.0, 0.0);
    final clampedTy = ty.clamp(minTy <= 0 ? minTy : 0.0, 0.0);

    _transformController.value = Matrix4(
      targetScale,
      0,
      0,
      0,
      0,
      targetScale,
      0,
      0,
      0,
      0,
      1,
      0,
      clampedTx,
      clampedTy,
      0,
      1,
    );
    setState(() {
      _fitMode = mode;
      _currentScale = targetScale;
    });
  }

  void _toggleDoubleTapZoom(double viewportWidth, double viewportHeight) {
    if (_currentScale > 1.02) {
      _resetZoom();
      return;
    }
    const targetScale = 2.5;
    final focal =
        _lastDoubleTapLocalPos ?? Offset(viewportWidth / 2, viewportHeight / 2);
    final minTx = viewportWidth * (1.0 - targetScale);
    final minTy = viewportHeight * (1.0 - targetScale);
    final tx = (focal.dx * (1.0 - targetScale)).clamp(
      minTx <= 0 ? minTx : 0.0,
      0.0,
    );
    final ty = (focal.dy * (1.0 - targetScale)).clamp(
      minTy <= 0 ? minTy : 0.0,
      0.0,
    );
    _transformController.value = Matrix4(
      targetScale,
      0,
      0,
      0,
      0,
      targetScale,
      0,
      0,
      0,
      0,
      1,
      0,
      tx,
      ty,
      0,
      1,
    );
  }

  void _handleWheelZoom(
    PointerSignalEvent event,
    double viewportWidth,
    double viewportHeight,
  ) {
    if (event is! PointerScrollEvent ||
        (_activeImageProvider == null && _placeholderProvider == null)) {
      return;
    }
    if (event.scrollDelta.dy == 0) return;

    final matrix = _transformController.value;
    final currentScale = matrix.storage[0] <= 0 ? 1.0 : matrix.storage[0];
    final currentTx = matrix.storage[12];
    final currentTy = matrix.storage[13];

    final factor = event.scrollDelta.dy < 0 ? 1.18 : 1 / 1.18;
    final nextScale = (currentScale * factor).clamp(_minScale, _maxScale);
    if ((nextScale - currentScale).abs() < 0.001) return;

    if (nextScale <= 1.002) {
      _resetZoom();
      return;
    }

    final ratio = nextScale / currentScale;
    final focal = event.localPosition;
    final rawTx = focal.dx - ratio * (focal.dx - currentTx);
    final rawTy = focal.dy - ratio * (focal.dy - currentTy);

    final minTx = viewportWidth * (1.0 - nextScale);
    final minTy = viewportHeight * (1.0 - nextScale);
    final clampedTx = rawTx.clamp(minTx <= 0 ? minTx : 0.0, 0.0);
    final clampedTy = rawTy.clamp(minTy <= 0 ? minTy : 0.0, 0.0);

    _transformController.value = Matrix4(
      nextScale,
      0,
      0,
      0,
      0,
      nextScale,
      0,
      0,
      0,
      0,
      1,
      0,
      clampedTx,
      clampedTy,
      0,
      1,
    );
  }

  Future<void> _openInSystemViewer(
    MediaVariant current,
    MediaSource? source,
  ) async {
    if (source == null || source.kind != MediaSourceKind.local) {
      if (!mounted) return;
      showKonataToast(
        context,
        '远程媒体源不在本地写临时文件，请直接在当前浮层滚轮缩放查看原图',
      );
      return;
    }

    final existingPath = await ref
        .read(scanLightboxLoaderProvider)
        .resolveExistingLocalPath(variant: current, source: source);
    if (existingPath == null) {
      if (!mounted) return;
      showKonataToast(context, '本地原图文件不存在或不可访问');
      return;
    }

    final ok = await launchUrl(
      Uri.file(existingPath),
      mode: LaunchMode.externalApplication,
    );
    if (!ok && mounted) {
      showKonataToast(context, '无法拉起系统图片查看器');
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    if (_scopedScans.isEmpty) {
      return const SizedBox.shrink();
    }
    final safeIdx = _index.clamp(0, _scopedScans.length - 1);
    final current = _scopedScans[safeIdx];
    final source = widget.bundle.sourcesById[current.sourceId];
    final size = MediaQuery.sizeOf(context);
    final safe = MediaQuery.paddingOf(context);
    final compact =
        size.width < KonataAdaptiveTokens.tabletBreakpoint ||
        size.height < KonataAdaptiveTokens.shortViewportHeight;

    final inset = _fullscreen ? 0.0 : (compact ? 10.0 : 24.0);
    final dialogWidth = _fullscreen
        ? size.width
        : (compact
                  ? math.max(240.0, size.width - safe.horizontal - inset * 2)
                  : (size.width * 0.90).clamp(
                      math.min(640.0, size.width - 48.0),
                      1380.0,
                    ))
              .toDouble();
    final dialogHeight = _fullscreen
        ? size.height
        : (compact
                  ? math.max(200.0, size.height - safe.vertical - inset * 2)
                  : (size.height * 0.88).clamp(
                      math.min(480.0, size.height - 48.0),
                      920.0,
                    ))
              .toDouble();

    final iconConstraints = KonataAdaptiveTokens.isAndroid
        ? const BoxConstraints(
            minWidth: KonataAdaptiveTokens.touchTarget,
            minHeight: KonataAdaptiveTokens.touchTarget,
          )
        : null;
    final cornerRadius = _fullscreen
        ? BorderRadius.zero
        : KonataTheme.borderRadiusCapsule;

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (_fullscreen) {
            setState(() => _fullscreen = false);
          } else {
            Navigator.of(context).pop();
          }
        },
        const SingleActivator(LogicalKeyboardKey.keyF): () =>
            setState(() => _fullscreen = !_fullscreen),
        const SingleActivator(LogicalKeyboardKey.digit0): _resetZoom,
        if (_scopedScans.length > 1)
          const SingleActivator(LogicalKeyboardKey.arrowLeft): () {
            if (safeIdx > 0) unawaited(_selectIndex(safeIdx - 1));
          },
        if (_scopedScans.length > 1)
          const SingleActivator(LogicalKeyboardKey.arrowRight): () {
            if (safeIdx < _scopedScans.length - 1) {
              unawaited(_selectIndex(safeIdx + 1));
            }
          },
      },
      child: Focus(
        autofocus: true,
        child: Dialog(
          backgroundColor: Colors.transparent,
          elevation: 0,
          insetPadding: EdgeInsets.all(inset),
          child: ClipRRect(
            borderRadius: cornerRadius,
            child: BackdropFilter(
              filter: KonataTheme.blurFilterLightbox,
              child: Container(
                width: dialogWidth,
                height: dialogHeight,
                decoration: BoxDecoration(
                  color: _fullscreen
                      ? KonataTheme.cinemaObsidian.withValues(alpha: 0.96)
                      : KonataTheme.lightboxDarkSurface.withValues(alpha: 0.86),
                  borderRadius: cornerRadius,
                  border: _fullscreen
                      ? null
                      : Border.all(color: KonataTheme.overlayWhiteBorder),
                ),
                child: SafeArea(
                  top: _fullscreen,
                  bottom: _fullscreen,
                  left: _fullscreen,
                  right: _fullscreen,
                  child: Column(
                    children: [
                      if (_chromeVisible) ...[
                        _buildTopBar(
                          p: p,
                          current: current,
                          source: source,
                          safeIdx: safeIdx,
                          compact: compact,
                          iconConstraints: iconConstraints,
                        ),
                        Divider(height: 1, color: p.hairline),
                      ],
                      Expanded(
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            _buildViewportBody(p, safeIdx),
                            if (_loadingFull && _placeholderProvider != null)
                              Positioned(
                                right: 14,
                                bottom: 14,
                                child: IgnorePointer(
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 6,
                                    ),
                                    decoration: BoxDecoration(
                                      color: KonataTheme.scrimBlackDense,
                                      borderRadius:
                                          KonataTheme.borderRadiusPill,
                                      border: Border.all(
                                        color: KonataTheme.overlayWhiteBorder,
                                        width: 0.8,
                                      ),
                                    ),
                                    child: const Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        SizedBox(
                                          width: 12,
                                          height: 12,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 1.8,
                                            color: KonataTheme.pureWhite,
                                          ),
                                        ),
                                        SizedBox(width: 7),
                                        Text(
                                          '加载原图…',
                                          style: TextStyle(
                                            color: KonataTheme.pureWhite,
                                            fontSize:
                                                KonataTheme.fontSizeCaptionSm,
                                            fontWeight: FontWeight.w500,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                      if (_chromeVisible &&
                          _showFilmstrip &&
                          _scopedScans.length > 1) ...[
                        Divider(height: 1, color: p.hairline),
                        _buildFilmstrip(p, safeIdx),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _toggleFullscreen() => setState(() => _fullscreen = !_fullscreen);

  void _toggleFilmstrip() => setState(() => _showFilmstrip = !_showFilmstrip);

  void _toggleChromeVisible() =>
      setState(() => _chromeVisible = !_chromeVisible);
}
