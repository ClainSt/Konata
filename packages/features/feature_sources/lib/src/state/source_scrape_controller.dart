import 'dart:async';

import 'package:engine_scraping/engine_scraping.dart';
import 'package:flutter/foundation.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';

import 'scrape_task_phase.dart';
import 'source_scope_prefs.dart';

/// 扫库弹窗「本源待复核」标签页展示用的轻量条目前端投影。
@immutable
class SourcePendingReviewWork {
  /// 构造单条属于当前媒体源的待复核作品摘要。
  const SourcePendingReviewWork({
    required this.work,
    required this.variantCount,
    this.sampleRelativePath,
  });

  /// 待复核作品领域模型。
  final Work work;

  /// 该作品在本媒体源下关联的物理文件数量。
  final int variantCount;

  /// 代表性物理文件的相对路径提示。
  final String? sampleRelativePath;
}

/// 媒体源扫库与刮削编排控制器（零 `Riverpod` 纯构造注入状态机）。
///
/// 职责边界：
/// - 在扫库前加载（并在冷却外尝试刷新）Bangumi-TMDB 离线二进制映射表；
/// - 驱动 `ScrapePipeline` 执行只读扫描、难度分层、多源匹配与剧照入库；
/// - 实时维护 `ScrapeTaskPhase` 密闭阶段状态机，支持安全取消并节流发布 `LibraryWorkChangedEvent`；
/// - 完全隔离于 `feature_library`，不直接导入任何海报墙 UI 或状态。
class SourceScrapeController extends ChangeNotifier {
  /// 构造扫库与刮削编排控制器。
  SourceScrapeController({
    required this.databases,
    required this.storageRoot,
    required this.scopedPrefs,
    required this.eventBus,
    required this.httpClient,
    required this.gatewayFactory,
    this.photosStorage,
    this.diagnosticLog,
    this.sourceDeviceId = '',
    this.pipelineBuilder,
    this.mappingLoaderOverride,
    int Function()? nowMs,
  }) : _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch),
       _repository = StorageScrapeRepository(
         databases,
         sourceDeviceId: sourceDeviceId,
         nowMs: nowMs,
       );

  /// 三库合一存储句柄。
  final KonataDatabaseBundle databases;

  /// 应用便携存储根目录端口。
  final StorageRootPort storageRoot;

  /// 分作用域配置存储。
  final ScopedPrefsStore scopedPrefs;

  /// 跨模块领域事件总线。
  final DomainEventBus eventBus;

  /// 受控 HTTP 客户端端口（含网络代理与凭据配置）。
  final KonataHttpClientPort httpClient;

  /// 媒体源只读网关工厂。
  final MediaSourceGatewayFactoryPort gatewayFactory;

  /// 可选本机艺术图存储端口。
  final PhotosStorage? photosStorage;

  /// 可选诊断日志端口。
  final DiagnosticLogPort? diagnosticLog;

  /// 当前设备标识。
  final String sourceDeviceId;

  /// 测试覆盖用的流水线构建工厂（为空时走默认真实元数据与网关装配）。
  final ScrapePipeline Function({
    required LibraryRepository repository,
    required BangumiTmdbIndex? mappingIndex,
  })?
  pipelineBuilder;

  /// 测试覆盖用的离线映射索引加载器。
  final Future<BangumiTmdbIndex?> Function()? mappingLoaderOverride;
  final int Function() _nowMs;
  final StorageScrapeRepository _repository;

  ScrapeTaskPhase _phase = const ScrapeIdlePhase();
  bool _isRunning = false;
  bool _cancelRequested = false;
  int _lastWorkEventMs = 0;

  /// 当前不可变刮削任务阶段快照。
  ScrapeTaskPhase get phase => _phase;

  /// 是否正在执行单源或全源扫描。
  bool get isBusy => _isRunning;

  /// 对指定媒体源发起一次完整或选定子目录的扫库刮削。
  Future<ScrapeTaskPhase> scanSource(
    MediaSource source, {
    List<String>? scanRootsOverride,
    bool forceFullRescan = false,
  }) async {
    if (_isRunning) {
      return _phase;
    }
    _isRunning = true;
    _cancelRequested = false;
    try {
      return await _runSingleSource(
        source,
        scanRootsOverride: scanRootsOverride,
        forceFullRescan: forceFullRescan,
      );
    } finally {
      _isRunning = false;
    }
  }

  /// 顺序扫描当前全部已配置媒体源；遇到主动取消时提前结束后续源队列。
  Future<List<ScrapeTaskPhase>> scanAllSources({
    bool forceFullRescan = false,
  }) async {
    if (_isRunning) {
      return <ScrapeTaskPhase>[_phase];
    }
    final sources = await _repository.getMediaSources();
    if (sources.isEmpty) {
      return const <ScrapeTaskPhase>[];
    }

    _isRunning = true;
    _cancelRequested = false;
    final results = <ScrapeTaskPhase>[];
    try {
      for (final source in sources) {
        if (_cancelRequested) break;
        final terminal = await _runSingleSource(
          source,
          forceFullRescan: forceFullRescan,
        );
        results.add(terminal);
        if (terminal is ScrapeCancelledPhase || _cancelRequested) {
          break;
        }
      }
      return List<ScrapeTaskPhase>.unmodifiable(results);
    } finally {
      _isRunning = false;
    }
  }

  /// 请求安全中止当前正在执行的扫描任务。
  void cancelActiveScan() {
    if (!_isRunning || _cancelRequested) return;
    _cancelRequested = true;
    final current = _phase;
    if (current is ScrapeRunningPhase) {
      _setPhase(current.withCancelRequested());
    } else if (current is ScrapeScanningPhase) {
      _setPhase(
        ScrapeScanningPhase(
          sourceId: current.sourceId,
          sourceLabel: current.sourceLabel,
          currentItemName: current.currentItemName,
          scannedDirectories: current.scannedDirectories,
          foundFiles: current.foundFiles,
          totalWorks: current.totalWorks,
          selectedRoots: current.selectedRoots,
          folderVideoCounts: current.folderVideoCounts,
          completedFolders: current.completedFolders,
          cancelRequested: true,
        ),
      );
    } else {
      notifyListeners();
    }
  }

  /// 在终态下重置进度条与状态机为空闲态。
  void dismissTerminalBanner() {
    if (_isRunning) return;
    _setPhase(const ScrapeIdlePhase());
  }

  /// 持续监听归属于指定媒体源的待复核作品摘要，供本包进度弹窗独立展示。
  Stream<List<SourcePendingReviewWork>> watchNeedsReviewForSource(
    String sourceId,
  ) {
    return databases.library.works.watchNeedsReview().asyncMap(
      (_) => listNeedsReviewForSource(sourceId),
    );
  }

  /// 查询归属于指定媒体源的待复核作品摘要（按最新或标题稳定排序）。
  Future<List<SourcePendingReviewWork>> listNeedsReviewForSource(
    String sourceId,
  ) async {
    final variants = await _repository.getVariantsBySource(sourceId);
    if (variants.isEmpty) return const <SourcePendingReviewWork>[];

    final variantsByWork = <String, List<MediaVariant>>{};
    for (final v in variants) {
      variantsByWork.putIfAbsent(v.workId, () => <MediaVariant>[]).add(v);
    }

    final works = await _repository.getAllWorks();
    final items = <SourcePendingReviewWork>[];
    for (final w in works) {
      if (w.isHidden || w.scrapeStatus != ScrapeStatus.needsReview) {
        continue;
      }
      final workVariants = variantsByWork[w.id];
      if (workVariants == null || workVariants.isEmpty) {
        continue;
      }
      items.add(
        SourcePendingReviewWork(
          work: w,
          variantCount: workVariants.length,
          sampleRelativePath: workVariants.first.relativePath,
        ),
      );
    }
    return List<SourcePendingReviewWork>.unmodifiable(items);
  }

  Future<ScrapeTaskPhase> _runSingleSource(
    MediaSource source, {
    List<String>? scanRootsOverride,
    bool forceFullRescan = false,
  }) async {
    _setPhase(
      ScrapeCheckingIndexPhase(
        sourceId: source.id,
        sourceLabel: source.label,
        statusMessage: '正在载入离线映射索引…',
      ),
    );

    final index = await _resolveMappingIndexSafely();
    if (_cancelRequested) {
      final cancelled = ScrapeCancelledPhase(
        sourceId: source.id,
        sourceLabel: source.label,
      );
      _setPhase(cancelled);
      return cancelled;
    }

    final roots =
        scanRootsOverride ??
        SourceScopePrefs.readIncludedFolders(scopedPrefs, source.id);
    _setPhase(
      ScrapeScanningPhase(
        sourceId: source.id,
        sourceLabel: source.label,
        currentItemName: source.label,
        selectedRoots: roots,
      ),
    );

    try {
      final pipeline =
          pipelineBuilder?.call(
            repository: _repository,
            mappingIndex: index,
          ) ??
          _buildDefaultPipeline(mappingIndex: index);

      final result = await pipeline.scanAndScrapeSource(
        source,
        scanRootsOverride: roots.isEmpty ? null : roots,
        forceFullRescan: forceFullRescan,
        isCancelled: () => _cancelRequested,
        onProgress: (progress) {
          final next = ScrapeTaskPhase.fromProgress(progress);
          if (_cancelRequested && next is ScrapeRunningPhase) {
            _setPhase(next.withCancelRequested());
          } else {
            _setPhase(next);
          }
        },
        onWorkPersisted: (workId, status, displayTitle) {
          final now = _nowMs();
          if (now - _lastWorkEventMs >= 400) {
            _lastWorkEventMs = now;
            eventBus.publish(
              LibraryWorkChangedEvent(
                workId: WorkId.trusted(workId),
                reason: 'scraped',
                occurredAtMs: now,
              ),
            );
          }
        },
      );

      var terminal = ScrapeTaskPhase.fromProgress(result);
      if (_cancelRequested &&
          terminal is! ScrapeCancelledPhase &&
          terminal is! ScrapeCompletedPhase) {
        terminal = ScrapeCancelledPhase(
          sourceId: source.id,
          sourceLabel: source.label,
          currentItemName: terminal.currentItemName,
          scannedDirectories: terminal.scannedDirectories,
          foundFiles: terminal.foundFiles,
          totalWorks: terminal.totalWorks,
          processedWorks: terminal.processedWorks,
          matchedWorks: terminal.matchedWorks,
          reviewWorks: terminal.reviewWorks,
          unmatchedWorks: terminal.unmatchedWorks,
          easyWorks: terminal.easyWorks,
          mediumWorks: terminal.mediumWorks,
          hardWorks: terminal.hardWorks,
          hardRescuedWorks: terminal.hardRescuedWorks,
          lastMatchedTitle: terminal.lastMatchedTitle,
          selectedRoots: terminal.selectedRoots,
          folderVideoCounts: terminal.folderVideoCounts,
          completedFolders: terminal.completedFolders,
        );
      }

      _setPhase(terminal);
      final now = _nowMs();
      if (terminal is ScrapeCompletedPhase) {
        SourceScopePrefs.writeLastScannedAtMs(scopedPrefs, source.id, now);
      }
      eventBus.publish(
        MediaSourceChangedEvent(
          sourceId: SourceId.trusted(source.id),
          reason: terminal is ScrapeCancelledPhase
              ? 'scan_cancelled'
              : 'scan_completed',
          occurredAtMs: now,
        ),
      );
      eventBus.publish(
        LibraryWorkChangedEvent(
          workId: const WorkId.trusted('*'),
          reason: 'scrape_batch_finished',
          occurredAtMs: now,
        ),
      );
      return terminal;
    } catch (error) {
      final safeError = DiagnosticTextSanitizer.redactSecrets('$error');
      diagnosticLog?.logError(
        subsystem: DiagnosticSubsystem.scraper,
        code: 'source_scrape_failed',
        message: '扫描媒体源 ${source.label} 失败: $safeError',
        error: error,
        source: 'SourceScrapeController._runSingleSource',
      );
      final failed = ScrapeFailedPhase(
        sourceId: source.id,
        sourceLabel: source.label,
        errorMessage: '扫库失败：$safeError',
      );
      _setPhase(failed);
      return failed;
    }
  }

  Future<BangumiTmdbIndex?> _resolveMappingIndexSafely() async {
    final override = mappingLoaderOverride;
    if (override != null) {
      try {
        return await override();
      } catch (_) {
        return null;
      }
    }
    try {
      final updater = BangumiTmdbMapUpdater(
        storageRoot: storageRoot,
        prefsStore: scopedPrefs,
      );
      final snapshot = await updater.loadActiveSnapshot();
      return snapshot.index;
    } catch (_) {
      return null;
    }
  }

  ScrapePipeline _buildDefaultPipeline({
    required BangumiTmdbIndex? mappingIndex,
  }) {
    final tmdbService = TmdbService(httpClient: httpClient);
    final bangumiService = BangumiService(httpClient: httpClient);
    final fanartService = FanartService(httpClient: httpClient);
    final clearLogoResolver = ClearLogoResolver(
      tmdbService: tmdbService,
      fanartService: fanartService,
      networkConfig: httpClient.config,
      mappingIndex: mappingIndex,
    );
    final artworkStorage = photosStorage != null
        ? StorageRootWorkArtworkStorage(storageRoot: storageRoot)
        : null;
    final snapshotStore = ScrapeDirectoryScanSnapshotStore(
      storageRoot: storageRoot,
    );

    return ScrapePipeline(
      repository: _repository,
      tmdbService: tmdbService,
      bangumiService: bangumiService,
      fanartService: fanartService,
      clearLogoResolver: clearLogoResolver,
      gatewayBuilder: (source) => gatewayFactory.create(
        MediaSourceView(
          id: SourceId.trusted(source.id),
          kind: source.kind,
          label: source.label,
          location: source.location,
          username: source.username,
        ),
      ),
      photosStorage: artworkStorage,
      mappingIndex: mappingIndex,
      snapshotStore: snapshotStore,
      diagnosticLog: diagnosticLog,
      eventBus: eventBus,
    );
  }

  void _setPhase(ScrapeTaskPhase next) {
    _phase = next;
    notifyListeners();
  }
}
