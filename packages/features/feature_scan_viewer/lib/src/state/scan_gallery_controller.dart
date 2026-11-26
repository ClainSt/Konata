import 'dart:async';

import 'package:engine_scraping/engine_scraping.dart';
import 'package:flutter/foundation.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';

import '../data/scan_gallery_prefs.dart';
import '../data/scan_gallery_repository.dart';
import '../data/scan_thumbnail_scheduler.dart';

/// 扫图画廊状态快照（零 Riverpod 不可变视图模型）。
final class ScanGalleryState {
  /// 创建扫图画廊状态快照。
  const ScanGalleryState({
    this.workId,
    this.workTitle = '',
    this.allScans = const <MediaVariant>[],
    this.visibleScans = const <MediaVariant>[],
    this.sourcesById = const <String, MediaSourceRecord>{},
    this.sourceViewsById = const <String, MediaSourceView>{},
    this.scanSummary = const ScanVolumeGroupSummary(
      chips: <({String key, String label, int count})>[],
      byVariantId: <String, ScanVolumeGroupingResult>{},
      hasMultipleSubdirs: false,
    ),
    this.selectedVolumeKey,
    this.showSeriesSharedBadge = false,
    this.prefs = ScanGalleryPrefs.defaults,
    this.isLoading = false,
    this.errorMessage,
  });

  /// 当前已加载的作品主键。
  final WorkId? workId;

  /// 当前作品展示标题。
  final String workTitle;

  /// 当前作品及同系列可见的全部扫图变体。
  final List<MediaVariant> allScans;

  /// 应用二级分卷筛选后的可见扫图变体。
  final List<MediaVariant> visibleScans;

  /// 媒体源持久化记录映射（按 `sourceId` 索引）。
  final Map<String, MediaSourceRecord> sourcesById;

  /// 媒体源只读视图映射（按 `sourceId` 索引）。
  final Map<String, MediaSourceView> sourceViewsById;

  /// 当前扫图资产分卷与子目录分组摘要。
  final ScanVolumeGroupSummary scanSummary;

  /// 当前激活的二级分卷筛选键（`null` 表示显示全部）。
  final String? selectedVolumeKey;

  /// 是否展示「系列共用」角标。
  final bool showSeriesSharedBadge;

  /// 画廊展示模式与密度偏好。
  final ScanGalleryPrefs prefs;

  /// 是否处于数据加载态。
  final bool isLoading;

  /// 加载异常说明（无错误时为 `null`）。
  final String? errorMessage;

  /// 当前画廊展示模式（整齐网格 / 自适应等高瀑布流）。
  ScanGalleryMode get mode => prefs.mode;

  /// 当前画廊密度档位。
  ScanGalleryDensity get density => prefs.density;

  /// 复制并局部更新画廊状态。
  ScanGalleryState copyWith({
    WorkId? workId,
    String? workTitle,
    List<MediaVariant>? allScans,
    List<MediaVariant>? visibleScans,
    Map<String, MediaSourceRecord>? sourcesById,
    Map<String, MediaSourceView>? sourceViewsById,
    ScanVolumeGroupSummary? scanSummary,
    String? selectedVolumeKey,
    bool clearSelectedVolumeKey = false,
    bool? showSeriesSharedBadge,
    ScanGalleryPrefs? prefs,
    bool? isLoading,
    String? errorMessage,
    bool clearErrorMessage = false,
  }) {
    return ScanGalleryState(
      workId: workId ?? this.workId,
      workTitle: workTitle ?? this.workTitle,
      allScans: allScans ?? this.allScans,
      visibleScans: visibleScans ?? this.visibleScans,
      sourcesById: sourcesById ?? this.sourcesById,
      sourceViewsById: sourceViewsById ?? this.sourceViewsById,
      scanSummary: scanSummary ?? this.scanSummary,
      selectedVolumeKey: clearSelectedVolumeKey
          ? null
          : (selectedVolumeKey ?? this.selectedVolumeKey),
      showSeriesSharedBadge:
          showSeriesSharedBadge ?? this.showSeriesSharedBadge,
      prefs: prefs ?? this.prefs,
      isLoading: isLoading ?? this.isLoading,
      errorMessage: clearErrorMessage
          ? null
          : (errorMessage ?? this.errorMessage),
    );
  }
}

/// 扫图画廊业务状态控制器（严格零 Riverpod 纯构造函数注入，基于 [ChangeNotifier] 驱动 UI）。
///
/// 职责：
/// 1. 基于 [KonataDatabaseBundle] 查询作品自身及同系列 `seriesShared` 扫图变体与 [MediaSourceRecord]；
/// 2. 管理分卷筛选、画廊双模式切换（整齐网格 / 自适应瀑布流）与 3 档视图密度，并同步持久化至 [ScopedPrefsStore]；
/// 3. 协调 [ScanThumbnailScheduler] 预热帧头宽高比并在切分卷或切作品时取消过期队列。
final class ScanGalleryController extends ChangeNotifier {
  /// 创建扫图画廊控制器。
  ScanGalleryController({
    required this._databases,
    required this._scopedPrefs,
    required this._scheduler,
    this._photosStorage,
    this._diagnosticLog,
    this.autoWatchDatabase = true,
  }) {
    final initialPrefs = _scopedPrefs.read(scanGalleryPrefsSlice);
    _state = ScanGalleryState(prefs: initialPrefs);
    _prefsSub = _scopedPrefs.watch(scanGalleryPrefsSlice).listen((next) {
      if (_disposed || next == _state.prefs) return;
      _state = _state.copyWith(prefs: next);
      notifyListeners();
    });
  }

  final KonataDatabaseBundle _databases;
  final ScopedPrefsStore _scopedPrefs;
  final ScanThumbnailScheduler _scheduler;
  final PhotosStorage? _photosStorage;
  final DiagnosticLogPort? _diagnosticLog;

  /// 是否在加载作品后自动订阅 `media_variants` 表变更刷新。
  final bool autoWatchDatabase;

  late ScanGalleryState _state;
  StreamSubscription<List<MediaVariantRecord>>? _variantWatchSub;
  StreamSubscription<ScanGalleryPrefs>? _prefsSub;
  bool _disposed = false;

  /// 当前扫图画廊状态快照。
  ScanGalleryState get state => _state;

  /// 加载指定作品的扫图画廊数据与媒体源配置。
  Future<void> loadWork(
    WorkId workId, {
    String? initialVolumeKey,
    bool prewarmAspectRatios = true,
  }) async {
    if (_disposed) return;

    final isWorkSwitch = _state.workId != workId;
    if (isWorkSwitch) {
      await _variantWatchSub?.cancel();
      _variantWatchSub = null;
    }
    if (_disposed) return;

    _state = _state.copyWith(
      workId: workId,
      isLoading: true,
      clearErrorMessage: true,
      clearSelectedVolumeKey: isWorkSwitch && initialVolumeKey == null,
    );
    notifyListeners();

    await _refreshFromDatabase(
      workId,
      preferredVolumeKey: initialVolumeKey ?? _state.selectedVolumeKey,
      prewarmAspectRatios: prewarmAspectRatios,
    );

    if (_disposed || !autoWatchDatabase || _state.workId != workId) return;
    if (_variantWatchSub == null) {
      var skipInitial = true;
      _variantWatchSub = _databases.library.mediaVariants
          .watchByWork(workId)
          .listen((_) {
            if (skipInitial) {
              skipInitial = false;
              return;
            }
            if (_disposed || _state.workId != workId) return;
            unawaited(
              _refreshFromDatabase(
                workId,
                preferredVolumeKey: _state.selectedVolumeKey,
                prewarmAspectRatios: prewarmAspectRatios,
              ),
            );
          });
    }
  }

  /// 强制从数据库刷新当前作品的扫图列表。
  Future<void> reload({bool prewarmAspectRatios = true}) async {
    final workId = _state.workId;
    if (workId == null || _disposed) return;
    await _refreshFromDatabase(
      workId,
      preferredVolumeKey: _state.selectedVolumeKey,
      prewarmAspectRatios: prewarmAspectRatios,
    );
  }

  Future<void> _refreshFromDatabase(
    WorkId workId, {
    String? preferredVolumeKey,
    required bool prewarmAspectRatios,
  }) async {
    try {
      final dataset = ScanGalleryRepository.loadWorkDataset(
        _databases,
        workId,
        photosStorage: _photosStorage,
      );
      if (_disposed || _state.workId != workId) return;

      final validVolumeKey =
          preferredVolumeKey != null &&
              dataset.scanSummary.hasMultipleSubdirs &&
              dataset.scanSummary.chips.any((c) => c.key == preferredVolumeKey)
          ? preferredVolumeKey
          : null;

      final filtered = _filterByVolume(
        dataset.scanVariants,
        dataset.scanSummary,
        validVolumeKey,
      );

      _state = _state.copyWith(
        workId: workId,
        workTitle: dataset.work?.title ?? '',
        allScans: dataset.scanVariants,
        visibleScans: filtered,
        sourcesById: dataset.sourcesById,
        sourceViewsById: dataset.sourceViewsById,
        scanSummary: dataset.scanSummary,
        selectedVolumeKey: validVolumeKey,
        clearSelectedVolumeKey: validVolumeKey == null,
        showSeriesSharedBadge: dataset.showSeriesSharedBadge,
        isLoading: false,
        clearErrorMessage: true,
      );
      notifyListeners();

      if (prewarmAspectRatios && dataset.scanVariants.isNotEmpty) {
        unawaited(
          _scheduler.prewarmCachedAndLocalAspectRatios(
            workId: workId.value,
            workTitle: dataset.work?.title,
            variants: dataset.scanVariants,
            sourcesById: dataset.sourceViewsById,
          ),
        );
      }
    } catch (error, stackTrace) {
      _diagnosticLog?.logError(
        subsystem: DiagnosticSubsystem.storage,
        code: 'SCAN_GALLERY_LOAD_FAIL',
        message: '加载作品扫图画廊数据失败',
        error: error,
        stackTrace: stackTrace,
        source: 'feature_scan_viewer:scan_gallery_controller.dart',
      );
      if (_disposed || _state.workId != workId) return;
      _state = _state.copyWith(
        isLoading: false,
        errorMessage: '加载扫图资产失败：$error',
      );
      notifyListeners();
    }
  }

  /// 切换画廊展示模式并持久化至 `ScopedPrefsStore`。
  void setMode(ScanGalleryMode nextMode) {
    if (_disposed || _state.prefs.mode == nextMode) return;
    final nextPrefs = _state.prefs.copyWith(mode: nextMode);
    _updatePrefs(nextPrefs);
  }

  /// 切换画廊视图密度档位并持久化至 `ScopedPrefsStore`。
  void setDensity(ScanGalleryDensity nextDensity) {
    if (_disposed || _state.prefs.density == nextDensity) return;
    final nextPrefs = _state.prefs.copyWith(density: nextDensity);
    _updatePrefs(nextPrefs);
  }

  /// 按步进方向调整视图密度（供桌面端 `Ctrl + 滚轮` 快捷调密度）。
  void stepDensity(int delta) {
    if (_disposed || delta == 0) return;
    const order = ScanGalleryDensity.values;
    final currentIdx = order.indexOf(_state.prefs.density);
    final nextIdx = (currentIdx + delta).clamp(0, order.length - 1);
    if (nextIdx != currentIdx) {
      setDensity(order[nextIdx]);
    }
  }

  /// 切换二级分卷筛选；移出视口的卡片自行取消，保留卡片继续加载。
  void selectVolume(String? volumeKey) {
    if (_disposed || _state.selectedVolumeKey == volumeKey) return;
    final nextKey =
        volumeKey != null &&
            _state.scanSummary.hasMultipleSubdirs &&
            _state.scanSummary.chips.any((c) => c.key == volumeKey)
        ? volumeKey
        : null;
    final filtered = _filterByVolume(
      _state.allScans,
      _state.scanSummary,
      nextKey,
    );
    _state = _state.copyWith(
      selectedVolumeKey: nextKey,
      clearSelectedVolumeKey: nextKey == null,
      visibleScans: filtered,
    );
    notifyListeners();
  }

  void _updatePrefs(ScanGalleryPrefs nextPrefs) {
    _state = _state.copyWith(prefs: nextPrefs);
    notifyListeners();
    try {
      _scopedPrefs.write(scanGalleryPrefsSlice, nextPrefs);
    } catch (error, stackTrace) {
      _diagnosticLog?.logError(
        subsystem: DiagnosticSubsystem.storage,
        code: 'SCAN_PREFS_SAVE_FAIL',
        message: '持久化扫图画廊偏好设置失败',
        error: error,
        stackTrace: stackTrace,
        severity: DiagnosticSeverity.warn,
        source: 'feature_scan_viewer:scan_gallery_controller.dart',
      );
    }
  }

  static List<MediaVariant> _filterByVolume(
    List<MediaVariant> all,
    ScanVolumeGroupSummary summary,
    String? volumeKey,
  ) {
    if (volumeKey == null) return all;
    return List<MediaVariant>.unmodifiable(
      all.where((v) => summary.byVariantId[v.id]?.volumeKey == volumeKey),
    );
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(_variantWatchSub?.cancel());
    _variantWatchSub = null;
    unawaited(_prefsSub?.cancel());
    _prefsSub = null;
    super.dispose();
  }
}
