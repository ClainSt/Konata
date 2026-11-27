import 'dart:async';
import 'dart:math' as math;

import 'package:engine_scraping/engine_scraping.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_design_system/konata_design_system.dart';

import '../data/scan_display_formatter.dart';
import '../data/scan_lightbox_loader.dart';
import '../data/scan_thumbnail_scheduler.dart';
import '../providers.dart';

part 'scan_lightbox_widgets.dart';

/// 灯箱画册阅读缩放预设模式。
enum _ScanFitMode {
  /// 完整适应可视窗口（`1.0x`，无裁切）。
  fitWindow('适应窗口'),

  /// 撑满视口宽度（适合竖版长页纵向阅读）。
  fitWidth('适应宽度'),

  /// 撑满视口高度（适合宽幅跨页横向浏览）。
  fitHeight('适应高度'),

  /// 按图像真实像素比例 `1:1` 原寸查看。
  original100('100% 原寸');

  const _ScanFitMode(this.label);

  /// 简体中文菜单展示文案。
  final String label;
}

/// 弹出内置毛玻璃高清扫图灯箱弹窗。
Future<void> showScanLightboxDialog(
  BuildContext context, {
  required WorkId workId,
  required String workTitle,
  required List<MediaVariant> scans,
  required Map<String, MediaSourceView> sourcesById,
  required MediaVariant initialVariant,
  String? initialVolumeKey,
  ScanVolumeGroupSummary? scanSummary,
  ScanThumbnailScheduler? scheduler,
  ScanLightboxLoader? loader,
  ScanLightboxMemoryWindow? memoryWindow,
  KonataPlatform? platform,
  UrlOpenerPort? urlOpener,
  ScanWindowFullscreenPort? windowFullscreen,
  DiagnosticLogPort? diagnosticLog,
}) {
  final isAndroid = platform != null
      ? platform != KonataPlatform.windows
      : KonataAdaptiveTokens.isAndroid;
  Widget buildViewer(BuildContext _) => ScanLightboxDialog(
    workId: workId,
    workTitle: workTitle,
    scans: scans,
    sourcesById: sourcesById,
    initialVariant: initialVariant,
    initialVolumeKey: initialVolumeKey,
    scanSummary: scanSummary,
    scheduler: scheduler,
    loader: loader,
    memoryWindow: memoryWindow,
    platform: platform,
    urlOpener: urlOpener,
    windowFullscreen: windowFullscreen,
    diagnosticLog: diagnosticLog,
  );
  if (isAndroid) {
    return Navigator.of(context, rootNavigator: true).push<void>(
      PageRouteBuilder<void>(
        pageBuilder: (context, _, _) => buildViewer(context),
        opaque: true,
      ),
    );
  }
  return showKonataGlassDialog<void>(context: context, builder: buildViewer);
}

/// Scan 画集毛玻璃全屏高清内置灯箱：
/// - 打开期间暂停后台远程微缩图调度，独占远端带宽防云盘限流；
/// - 两阶段渐进替换：若本地已有 `.webp` 微缩图则 0ms 瞬时铺满，原图就绪后保留平移/缩放锚点无缝锐化；
/// - 基于 [ScanLightboxMemoryWindow] 严格维持有界 `96 MiB` 内存滑窗（按最远距离淘汰，关闭弹窗即全量驱逐，原图零落盘）；
/// - 承接当前二级分卷筛选并支持顶栏切换分卷、底部只读缓存胶片条、全屏沉浸切换、四档缩放预设与键盘/触控翻页。
class ScanLightboxDialog extends StatefulWidget {
  /// 创建 Scan 画集高清大图浏览弹窗。
  const ScanLightboxDialog({
    super.key,
    required this.workId,
    required this.workTitle,
    required this.scans,
    required this.sourcesById,
    required this.initialVariant,
    this.initialVolumeKey,
    this.scanSummary,
    this.scheduler,
    this.loader,
    this.memoryWindow,
    this.platform,
    this.urlOpener,
    this.windowFullscreen,
    this.diagnosticLog,
  });

  /// 当前作品强类型标识。
  final WorkId workId;

  /// 当前作品展示标题。
  final String workTitle;

  /// 当前作品及同系列可见的全部扫图变体列表。
  final List<MediaVariant> scans;

  /// 媒体源只读视图字典（按 `sourceId` 索引）。
  final Map<String, MediaSourceView> sourcesById;

  /// 初始定位的扫图条目。
  final MediaVariant initialVariant;

  /// 可选承接画廊当前激活的二级分卷筛选键。
  final String? initialVolumeKey;

  /// 可选复用的分卷分组摘要（缺省时自动计算）。
  final ScanVolumeGroupSummary? scanSummary;

  /// 可选注入微缩图调度器（缺省从容器读取）。
  final ScanThumbnailScheduler? scheduler;

  /// 可选注入原图流式加载器（缺省从容器读取）。
  final ScanLightboxLoader? loader;

  /// 可选注入有界内存滑窗（便于单测观测淘汰与释放行为）。
  final ScanLightboxMemoryWindow? memoryWindow;

  /// 可选显式宿主平台形态。
  final KonataPlatform? platform;

  /// 可选外部图片打开端口。
  final UrlOpenerPort? urlOpener;

  /// 可选桌面窗口全屏控制端口。
  final ScanWindowFullscreenPort? windowFullscreen;

  /// 可选结构化诊断日志端口。
  final DiagnosticLogPort? diagnosticLog;

  @override
  State<ScanLightboxDialog> createState() => _ScanLightboxDialogState();
}

class _ScanLightboxDialogState extends State<ScanLightboxDialog> {
  static const double _minScale = 1.0;
  static const double _maxScale = 5.0;

  final TransformationController _transformController =
      TransformationController();
  final ScrollController _filmstripController = ScrollController();

  late final ScanThumbnailScheduler _scanScheduler;
  late final ScanLightboxLoader _loader;
  late final ScanLightboxMemoryWindow _memoryWindow;
  late final bool _ownsMemoryWindow;
  late final ScanVolumeGroupSummary _scanSummary;
  late final UrlOpenerPort _urlOpener;
  ScanWindowFullscreenPort? _windowFullscreen;
  DiagnosticLogPort? _diagnosticLog;
  bool _dependenciesInitialized = false;

  // 维护内存滑窗中已构造的绘制图像提供者，淘汰时同步驱逐解码帧缓存。
  final Map<String, MemoryImage> _providersByVariantId =
      <String, MemoryImage>{};

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
  int? _activeByteLength;
  double _currentScale = 1.0;
  _ScanFitMode _fitMode = _ScanFitMode.fitWindow;

  bool _fullscreen = false;

  bool get _isAndroid => widget.platform != null
      ? widget.platform != KonataPlatform.windows
      : KonataAdaptiveTokens.isAndroid;
  bool _enteredSystemFullscreen = false;
  bool _chromeVisible = true;
  bool _showFilmstrip = true;

  ScanImageLoadHandle? _activeLoadHandle;
  ScanImageLoadHandle? _prefetchHandle;
  String? _prefetchVariantId;

  // 胶片条只读本地缓存微缩图映射（绝不发送网络请求）。
  final Map<String, Uint8List?> _filmstripCache = <String, Uint8List?>{};
  final Set<String> _filmstripRequested = <String>{};

  Offset? _lastDoubleTapLocalPos;
  Size _lastViewportSize = Size.zero;
  double _touchSwipeDeltaX = 0.0;

  @override
  void initState() {
    super.initState();
    _fullscreen = _isAndroid;
    if (_fullscreen && KonataAdaptiveTokens.isAndroid) {
      unawaited(
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky),
      );
    }
    _ownsMemoryWindow = widget.memoryWindow == null;
    _memoryWindow = widget.memoryWindow ?? ScanLightboxMemoryWindow();
    _transformController.addListener(_handleTransformChanged);
    _scanSummary =
        widget.scanSummary ??
        SupplementarySubclassifier.groupScanVariants(widget.scans);

    final initKey = widget.initialVolumeKey;
    if (initKey != null &&
        _scanSummary.hasMultipleSubdirs &&
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
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_dependenciesInitialized) return;
    _dependenciesInitialized = true;

    final container = _tryContainerOf(context);
    final deps = _tryReadDependencies(container);
    _scanScheduler =
        widget.scheduler ?? container!.read(scanThumbnailSchedulerProvider);
    _loader = widget.loader ?? container!.read(scanLightboxLoaderProvider);
    _urlOpener =
        widget.urlOpener ?? deps?.urlOpener ?? const NoopUrlOpenerPort();
    _windowFullscreen = widget.windowFullscreen ?? deps?.windowFullscreen;
    _diagnosticLog = widget.diagnosticLog ?? deps?.diagnosticLog;

    _scanScheduler.pauseRemote(abortActive: true);
    if (_scopedScans.isNotEmpty) {
      unawaited(_loadCurrentScan());
    }
  }

  ProviderContainer? _tryContainerOf(BuildContext context) {
    try {
      return ProviderScope.containerOf(context, listen: false);
    } catch (_) {
      return null;
    }
  }

  FeatureScanViewerDependencies? _tryReadDependencies(
    ProviderContainer? container,
  ) {
    if (container == null) return null;
    try {
      return container.read(featureScanViewerDependenciesProvider);
    } catch (_) {
      return null;
    }
  }

  @override
  void dispose() {
    _transformController.removeListener(_handleTransformChanged);
    _transformController.dispose();
    _filmstripController.dispose();
    if (_enteredSystemFullscreen) {
      _enteredSystemFullscreen = false;
      final host = _windowFullscreen;
      if (host != null) {
        unawaited(host.setFullScreen(false));
      }
    }
    if (_fullscreen && KonataAdaptiveTokens.isAndroid) {
      unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    }
    _abortAllAndEvictAllSync();
    _scanScheduler.resumeRemote();
    super.dispose();
  }

  List<MediaVariant> _computeScopedScans(String? volumeKey) {
    final all = widget.scans;
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
      } catch (error, stackTrace) {
        _logError('取消扫图加载任务失败', error: error, stackTrace: stackTrace);
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
      } catch (error, stackTrace) {
        _logError('取消扫图预读任务失败', error: error, stackTrace: stackTrace);
      }
    }
  }

  void _evictPlaceholderSync() {
    final prev = _placeholderProvider;
    _placeholderProvider = null;
    if (prev != null) {
      unawaited(prev.evict().catchError((_) => false));
    }
  }

  void _abortAllAndEvictAllSync() {
    final active = _activeLoadHandle;
    _activeLoadHandle = null;
    if (active != null) {
      unawaited(active.cancel().catchError((_) {}));
    }
    final prefetch = _prefetchHandle;
    _prefetchHandle = null;
    _prefetchVariantId = null;
    if (prefetch != null) {
      unawaited(prefetch.cancel().catchError((_) {}));
    }
    _evictPlaceholderSync();
    _activeImageProvider = null;
    _activeByteLength = null;

    if (_ownsMemoryWindow) {
      _memoryWindow.clear();
    } else {
      for (final key in _providersByVariantId.keys.toList(growable: false)) {
        _memoryWindow.remove(key);
      }
    }
    for (final provider in _providersByVariantId.values) {
      unawaited(provider.evict().catchError((_) => false));
    }
    _providersByVariantId.clear();
    _filmstripCache.clear();
    _filmstripRequested.clear();
  }

  MemoryImage _resolveOrCreateProvider(ScanMemoryWindowEntry entry) {
    final existing = _providersByVariantId[entry.variantId];
    if (existing != null) return existing;
    final created = MemoryImage(entry.bytes);
    _providersByVariantId[entry.variantId] = created;
    return created;
  }

  void _putIntoMemoryWindow({
    required MediaVariant variant,
    required int pageIndex,
    required Uint8List bytes,
    required ({int width, int height})? dims,
    required String pinnedVariantId,
  }) {
    final provider = MemoryImage(bytes);
    _providersByVariantId[variant.id] = provider;
    final stored = _memoryWindow.put(
      ScanMemoryWindowEntry(
        variantId: variant.id,
        pageIndex: pageIndex,
        bytes: bytes,
        pixelWidth: dims?.width,
        pixelHeight: dims?.height,
        onEvict: () {
          final removed = _providersByVariantId.remove(variant.id);
          if (removed != null) {
            unawaited(removed.evict().catchError((_) => false));
          }
        },
      ),
      currentIndex: _index,
      pinnedVariantId: pinnedVariantId,
    );
    if (!stored) {
      _providersByVariantId.remove(variant.id);
      unawaited(provider.evict().catchError((_) => false));
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
    if (nextIndex < 0 ||
        nextIndex >= _scopedScans.length ||
        nextIndex == _index) {
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
    final targetOffset =
        (targetIndex * itemExtent - viewportW / 2 + itemExtent / 2).clamp(
          0.0,
          _filmstripController.position.maxScrollExtent,
        );
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

    final epoch = ++_loadEpoch;
    await _cancelActiveLoad();
    await _cancelPrefetch();
    if (!mounted || epoch != _loadEpoch) return;

    final safeIdx = _index.clamp(0, _scopedScans.length - 1);
    final current = _scopedScans[safeIdx];
    final source = widget.sourcesById[current.sourceId];

    // 1. 优先 0ms 命中内存滑窗缓存。
    final windowHit = _memoryWindow.get(current.id);
    if (windowHit != null) {
      _evictPlaceholderSync();
      if (!mounted || epoch != _loadEpoch) return;
      final provider = _resolveOrCreateProvider(windowHit);
      setState(() {
        _activeImageProvider = provider;
        _activePixelWidth = windowHit.pixelWidth;
        _activePixelHeight = windowHit.pixelHeight;
        _activeByteLength = windowHit.byteLength;
        _loadingFull = false;
        _errorText = null;
      });
      _scheduleIdlePrefetchAdjacent(safeIdx, epoch);
      return;
    }

    if (source == null) {
      _evictPlaceholderSync();
      if (!mounted || epoch != _loadEpoch) return;
      setState(() {
        _activeImageProvider = null;
        _activeByteLength = null;
        _loadingFull = false;
        _errorText = '找不到当前画集所属媒体源配置';
      });
      return;
    }

    // 2. 两阶段渐进占位：先 0ms 读取本地 `.webp` 微缩图铺满画布（绝不发网络请求）。
    Uint8List? thumbPlaceholder;
    try {
      thumbPlaceholder = await _scanScheduler.readCachedThumbnailOnly(
        workId: widget.workId.value,
        workTitle: widget.workTitle,
        variant: current,
      );
    } catch (error, stackTrace) {
      _logError('读取灯箱本地微缩图占位失败', error: error, stackTrace: stackTrace);
    }
    if (!mounted || epoch != _loadEpoch) return;

    _evictPlaceholderSync();

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
      _activeByteLength = null;
      _loadingFull = true;
      _errorText = null;
    });

    // 3. 单次流式拉取完整原图并无缝锐化替换（严格保留当前缩放与平移变换矩阵，零落盘）。
    try {
      final handle = _loader.startLoad(variant: current, source: source);
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
        _scanScheduler.recordAspectRatio(current.id, dims.width / dims.height);
      }

      _putIntoMemoryWindow(
        variant: current,
        pageIndex: safeIdx,
        bytes: bytes,
        dims: dims,
        pinnedVariantId: current.id,
      );
      final provider = _providersByVariantId[current.id] ?? MemoryImage(bytes);

      if (!mounted || epoch != _loadEpoch) return;
      setState(() {
        _activeImageProvider = provider;
        _activePixelWidth = dims?.width;
        _activePixelHeight = dims?.height;
        _activeByteLength = bytes.length;
        _loadingFull = false;
        _errorText = null;
      });
      _evictPlaceholderSync();

      // 4. 当前张原图就绪且远端通道空闲后，顺序静默预读邻近页。
      _scheduleIdlePrefetchAdjacent(safeIdx, epoch);
    } catch (err, stackTrace) {
      _logError('加载高清画集失败', error: err, stackTrace: stackTrace);
      if (!mounted || epoch != _loadEpoch) return;
      final cleanMsg = err is StateError ? err.message : '加载高清画集失败: $err';
      setState(() {
        _loadingFull = false;
        _errorText = cleanMsg;
      });
    }
  }

  void _scheduleIdlePrefetchAdjacent(int currentIndex, int epoch) {
    final candidateIndices = <int>[
      if (currentIndex + 1 < _scopedScans.length) currentIndex + 1,
      if (currentIndex - 1 >= 0) currentIndex - 1,
    ];
    if (candidateIndices.isEmpty) return;

    unawaited(() async {
      for (final targetIdx in candidateIndices) {
        if (!mounted || epoch != _loadEpoch) return;
        final targetVariant = _scopedScans[targetIdx];
        if (_memoryWindow.contains(targetVariant.id) ||
            _prefetchVariantId == targetVariant.id) {
          continue;
        }
        final source = widget.sourcesById[targetVariant.sourceId];
        if (source == null) continue;

        final handle = _loader.startLoad(
          variant: targetVariant,
          source: source,
        );
        _prefetchHandle = handle;
        _prefetchVariantId = targetVariant.id;

        try {
          final bytes = await handle.future;
          if (identical(_prefetchHandle, handle)) {
            _prefetchHandle = null;
            _prefetchVariantId = null;
          }
          if (!mounted ||
              epoch != _loadEpoch ||
              bytes == null ||
              bytes.isEmpty) {
            return;
          }
          final dims = ImageHeaderParser.parseDimensions(bytes);
          if (dims != null) {
            _scanScheduler.recordAspectRatio(
              targetVariant.id,
              dims.width / dims.height,
            );
          }
          final currentId =
              _scopedScans[_index.clamp(0, _scopedScans.length - 1)].id;
          _putIntoMemoryWindow(
            variant: targetVariant,
            pageIndex: targetIdx,
            bytes: bytes,
            dims: dims,
            pinnedVariantId: currentId,
          );
        } catch (_) {
          if (identical(_prefetchHandle, handle)) {
            _prefetchHandle = null;
            _prefetchVariantId = null;
          }
        }
      }
    }());
  }

  void _ensureFilmstripThumbnail(MediaVariant variant) {
    if (_filmstripRequested.contains(variant.id)) return;
    _filmstripRequested.add(variant.id);
    unawaited(() async {
      final cached = await _scanScheduler.readCachedThumbnailOnly(
        workId: widget.workId.value,
        workTitle: widget.workTitle,
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
        // 适应宽度时横向居中并锚定顶部，方便竖页画册从上往下阅读。
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
    MediaSourceView? source,
  ) async {
    if (source == null || source.kind != MediaSourceKind.local) {
      if (!mounted) return;
      showKonataToast(context, '远程媒体源不在本地写临时文件，请直接在当前浮层滚轮缩放查看原图');
      return;
    }

    final existingPath = await _loader.resolveExistingLocalPath(
      variant: current,
      source: source,
    );
    if (existingPath == null) {
      if (!mounted) return;
      showKonataToast(context, '本地原图文件不存在或不可访问', isError: true);
      return;
    }

    final ok = await _urlOpener.openExternalUrl(Uri.file(existingPath));
    if (!ok && mounted) {
      showKonataToast(context, '无法拉起系统图片查看器', isError: true);
    }
  }

  void _logError(
    String message, {
    required Object error,
    StackTrace? stackTrace,
  }) {
    _diagnosticLog?.logError(
      subsystem: DiagnosticSubsystem.ui,
      code: 'SCAN_LIGHTBOX_ERROR',
      message: message,
      error: error,
      stackTrace: stackTrace,
      severity: DiagnosticSeverity.warn,
      source: 'feature_scan_viewer:scan_lightbox_dialog.dart',
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    if (_scopedScans.isEmpty) {
      return const SizedBox.shrink();
    }
    final safeIdx = _index.clamp(0, _scopedScans.length - 1);
    final current = _scopedScans[safeIdx];
    final source = widget.sourcesById[current.sourceId];
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

    final cornerRadius = _fullscreen
        ? BorderRadius.zero
        : KonataTheme.borderRadiusCapsule;

    final shortcuts = <ShortcutActivator, VoidCallback>{
      const SingleActivator(LogicalKeyboardKey.escape): () {
        if (_fullscreen && !_isAndroid) {
          unawaited(_setFullscreen(false));
        } else {
          Navigator.of(context).pop();
        }
      },
      if (!_isAndroid)
        const SingleActivator(LogicalKeyboardKey.keyF): () =>
            unawaited(_setFullscreen(!_fullscreen)),
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
    };
    final surface = ClipRRect(
      borderRadius: cornerRadius,
      child: KonataAdaptiveBackdropBlur(
        filter: KonataTheme.blurFilterLightbox,
        child: Container(
          width: dialogWidth,
          height: dialogHeight,
          decoration: BoxDecoration(
            color: _isAndroid
                ? KonataTheme.cinemaObsidian
                : _fullscreen
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
                    dialogWidth: dialogWidth,
                    compact: compact,
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
                                borderRadius: KonataTheme.borderRadiusPill,
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
                                      fontSize: KonataTheme.fontSizeCaptionSm,
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
    );
    final dialogSurface = CallbackShortcuts(
      bindings: shortcuts,
      child: Focus(
        autofocus: true,
        child: _isAndroid
            ? Material(
                color: KonataTheme.cinemaObsidian,
                child: SizedBox.expand(child: surface),
              )
            : Dialog(
                backgroundColor: Colors.transparent,
                elevation: 0,
                insetPadding: EdgeInsets.all(inset),
                child: surface,
              ),
      ),
    );

    if (ModalRoute.of(context) != null) {
      return KonataModalRouteScope(child: dialogSurface);
    }
    return dialogSurface;
  }

  void _toggleFullscreen() => unawaited(_setFullscreen(!_fullscreen));

  /// 同步切换灯箱无边框沉浸态与操作系统级窗口全屏。
  Future<void> _setFullscreen(bool enable) async {
    if (_isAndroid || _fullscreen == enable) return;
    if (mounted) {
      setState(() => _fullscreen = enable);
    } else {
      _fullscreen = enable;
    }

    final host = _windowFullscreen;
    final isWindowsPlatform = widget.platform != null
        ? widget.platform == KonataPlatform.windows
        : KonataAdaptiveTokens.isWindows;
    final isAndroidPlatform = widget.platform != null
        ? widget.platform != KonataPlatform.windows
        : KonataAdaptiveTokens.isAndroid;

    if (isWindowsPlatform && host != null) {
      if (enable) {
        final alreadyWindowFull = await host.isFullScreen();
        if (!alreadyWindowFull && _fullscreen && mounted) {
          _enteredSystemFullscreen = true;
          await host.setFullScreen(true);
        }
      } else if (_enteredSystemFullscreen) {
        _enteredSystemFullscreen = false;
        await host.setFullScreen(false);
      }
    } else if (isAndroidPlatform) {
      await SystemChrome.setEnabledSystemUIMode(
        enable ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
      );
    }
  }

  void _toggleFilmstrip() => setState(() => _showFilmstrip = !_showFilmstrip);

  void _toggleChromeVisible() =>
      setState(() => _chromeVisible = !_chromeVisible);
}
