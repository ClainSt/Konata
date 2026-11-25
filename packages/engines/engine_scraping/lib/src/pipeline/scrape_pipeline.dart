import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:konata_contracts/konata_contracts.dart';
import 'package:path/path.dart' as p;

import '../matching/directory_grouper.dart';
import '../matching/episode_remapper.dart';
import '../matching/work_matcher.dart';
import '../models/episode.dart';
import '../models/fanart_models.dart';
import '../models/media_source.dart';
import '../models/media_variant.dart';
import '../models/tmdb_models.dart';
import '../models/work.dart';
import '../network/bangumi_service.dart';
import '../network/fanart_service.dart';
import '../network/tmdb_service.dart';
import '../scraping/bangumi_models.dart';
import '../scraping/bangumi_tmdb_index.dart';
import '../scraping/match_difficulty_classifier.dart';
import '../scraping/scrape_domain_adapter.dart';
import '../scraping/work_wall_eligibility.dart';
import 'clear_logo_resolver.dart';
import 'library_repository.dart';
import 'release_group_work_merger.dart';
import 'scrape_artwork_enricher.dart';
import 'scrape_candidate_fetcher.dart';
import 'scrape_compute_worker.dart';
import 'scrape_match_resolver.dart';
import 'scrape_progress.dart';
import 'scrape_progress_tracker.dart';
import 'scrape_work_persister.dart';
import 'season_zero_work_splitter.dart';
import 'series_auto_linker.dart';
import 'source_scan/directory_scan_snapshot.dart';
import 'source_scan/directory_scan_snapshot_store.dart';
import 'source_scan/directory_scanner.dart';
import 'source_scan/scan_throttle_policy.dart';
import 'source_scan/source_access_error.dart';
import 'work_artwork_storage.dart';
import 'work_directory_sync_service.dart';

/// 进度状态回调。
typedef ScrapeProgressListener = void Function(ScrapeProgress progress);

/// 单部作品完成落库后的实时通知回调（供媒体库即刻展示已匹配成果）。
typedef ScrapeWorkPersistedListener =
    void Function(String workId, ScrapeStatus status, String displayTitle);

/// 媒体源网关构建函数。
typedef GatewayBuilder =
    Future<MediaSourceGateway> Function(MediaSource source);

/// 单条待复核作品手动触发「重新匹配」的结果状态。
enum RematchWorkOutcome {
  /// 已自动匹配并升级为已匹配状态。
  matched,

  /// 匹配成功后检测到同源同身份作品并自动归并。
  autoMerged,

  /// 网络正常但置信度或候选仍需人工核对（已更新候选列表与复核原因）。
  needsReview,

  /// 网络正常但未检索到匹配词条。
  unmatched,

  /// 仍受网络、证书或接口异常影响导致匹配失败。
  networkError,
}

/// 单条待复核作品手动「重新匹配」的强类型执行结果。
class RematchWorkResult {
  /// 创建重新匹配结果。
  const RematchWorkResult({
    required this.outcome,
    this.work,
    this.candidateCount = 0,
    this.errorMessage,
  });

  /// 执行结果分类。
  final RematchWorkOutcome outcome;

  /// 更新或归并后的作品快照。
  final Work? work;

  /// 本次写回的可展开候选数量。
  final int candidateCount;

  /// 失败或异常时的面向用户中文说明。
  final String? errorMessage;
}

/// 自定义只读目录扫描执行回调（用于集成外部协议扫描器）。
typedef ScrapeSourceScanRunner =
    Future<ScrapeDirectoryScanResult> Function(
      MediaSource source,
      MediaSourceGateway gateway, {
      required List<String> scanRoots,
      required bool detectLocalCovers,
      required String snapshotKey,
      ScrapeDirectoryScanSnapshot? previousSnapshot,
      ScrapeDirectoryScanCheckpointCallback? onCheckpoint,
      bool Function()? isCancelled,
      ScrapeDirectoryFolderVisitedCallback? onFolderVisited,
      ScrapeDirectoryScanProgressCallback? onProgress,
    });

/// 向后兼容别名（等价于 [ScrapePipeline]）。
typedef ScrapeOrchestrator = ScrapePipeline;

/// Konata 有序四段漏斗后台刮削流水线（纯 Dart 核心编排引擎）。
class ScrapePipeline {
  /// 创建有序刮削流水线实例。
  ScrapePipeline({
    required LibraryRepository repository,
    required TmdbService tmdbService,
    BangumiService? bangumiService,
    this._fanartService,
    this._clearLogoResolver,
    required this._gatewayBuilder,
    this._scanner = const ScrapeDirectoryScanner(),
    this._scanRunner,
    this._computeWorker = const ScrapeComputeWorker(),
    this._photosStorage,
    this._mappingIndex,
    this._snapshotStore,
    this._diagnosticLog,
    this._eventBus,
    this._maxWorkConcurrency = defaultWorkConcurrency,
    Map<int, List<BangumiRelatedSubject>>? bangumiRelationCache,
  }) : _repository = repository,
       _tmdbService = tmdbService,
       _bangumiService = bangumiService,
       _bangumiRelationCache =
           bangumiRelationCache ?? <int, List<BangumiRelatedSubject>>{},
       _persister = ScrapeWorkPersister(repository),
       _candidateFetcher = ScrapeCandidateFetcher(
         tmdbService,
         bangumiService: bangumiService,
       ),
       _interactiveCandidateFetcher = ScrapeCandidateFetcher(
         tmdbService,
         bangumiService: bangumiService,
         requestPriority: RequestPriority.interactive,
       ) {
    _matchResolver = ScrapeMatchResolver(
      fetcher: _candidateFetcher,
      computeWorker: _computeWorker,
      mappingIndex: _mappingIndex,
    );
    _interactiveMatchResolver = ScrapeMatchResolver(
      fetcher: _interactiveCandidateFetcher,
      computeWorker: _computeWorker,
      mappingIndex: _mappingIndex,
    );
    _artworkEnricher = ScrapeArtworkEnricher(
      fanartService: _fanartService,
      mappingIndex: _mappingIndex,
    );
    _workDirectorySync = WorkDirectorySyncService(
      repository: _repository,
      tmdbService: _tmdbService,
      candidateFetcher: _candidateFetcher,
      persister: _persister,
      gatewayBuilder: _gatewayBuilder,
      scanner: _scanner,
      computeWorker: _computeWorker,
      photosStorage: _photosStorage,
    );
  }

  /// 阶段 3 跨作品并发刮削默认并发度（仅并发在线元数据请求，写库与进度串行保护）。
  static const int defaultWorkConcurrency = 5;

  final LibraryRepository _repository;
  final TmdbService _tmdbService;
  final BangumiService? _bangumiService;
  final FanartService? _fanartService;
  final ClearLogoResolver? _clearLogoResolver;
  final WorkArtworkStoragePort? _photosStorage;
  final BangumiTmdbIndex? _mappingIndex;
  final ScrapeDirectoryScanSnapshotStore? _snapshotStore;
  final int _maxWorkConcurrency;
  final GatewayBuilder _gatewayBuilder;
  final ScrapeDirectoryScanner _scanner;
  final ScrapeSourceScanRunner? _scanRunner;
  final DiagnosticLogPort? _diagnosticLog;
  final DomainEventBus? _eventBus;
  final ScrapeWorkPersister _persister;
  final ScrapeCandidateFetcher _candidateFetcher;
  final ScrapeCandidateFetcher _interactiveCandidateFetcher;
  final ScrapeComputeWorker _computeWorker;
  late final ScrapeMatchResolver _matchResolver;
  late final ScrapeMatchResolver _interactiveMatchResolver;
  late final ScrapeArtworkEnricher _artworkEnricher;
  late final WorkDirectorySyncService _workDirectorySync;
  final Map<int, int> _tmdbCollectionIdByTmdbId = <int, int>{};
  final Map<int, List<BangumiRelatedSubject>> _bangumiRelationCache;

  /// 对单个作品所在目录执行轻量自动同步（自动追加追番新集、清理已删失效集与孤儿剧集）。
  Future<SingleWorkSyncResult> syncSingleWorkDirectory(
    String workId, {
    bool Function()? isCancelled,
  }) => _workDirectorySync.syncSingleWork(workId, isCancelled: isCancelled);

  /// 对指定媒体源执行完整的扫描 + 四段漏斗刮削流水线。
  ///
  /// 默认启用目录树快照增量复用与中断断点续扫；若需忽略历史快照执行全盘校准，可传 [forceFullRescan] 为真。
  Future<ScrapeProgress> scanAndScrapeSource(
    MediaSource source, {
    List<String>? scanRootsOverride,
    bool forceFullRescan = false,
    bool Function()? isCancelled,
    ScrapeProgressListener? onProgress,
    ScrapeWorkPersistedListener? onWorkPersisted,
  }) async {
    // 独立包装回调，避免 Dart `?.call(tracker.advance(...))` 在监听器为空时短路跳过状态推进。
    void emit(ScrapeProgress s) => onProgress?.call(s);

    final effectiveRoots = scanRootsOverride ?? const <String>[];
    final tracker = ScrapeProgressTracker(
      sourceId: source.id,
      sourceLabel: source.label,
      selectedRoots: effectiveRoots,
    );
    emit(tracker.snapshot);

    final gateway = await _gatewayBuilder(source);
    final computeSession = _computeWorker.openSession();
    _tmdbService.beginSessionCache();
    try {
      final store = source.kind == MediaSourceKind.webdav
          ? _snapshotStore
          : null;
      final snapshotKey = store == null
          ? ''
          : ScrapeDirectoryScanSnapshotStore.keyFor(
              source,
              ScrapeDirectoryScanner.normalizeScanRoots(effectiveRoots),
            );
      final previousSnapshot = store != null && !forceFullRescan
          ? await store.load(snapshotKey)
          : null;

      _logDecision(
        code: 'scraper.scan.start',
        message: '开始扫描媒体源：${source.label}',
        source: 'ScrapePipeline.scanAndScrapeSource',
        context: <String, Object?>{
          'sourceId': source.id,
          'sourceKind': source.kind.name,
          'forceFullRescan': forceFullRescan,
          'rootCount': effectiveRoots.length,
        },
      );

      Future<ScrapeDirectoryScanResult> scan(
        ScrapeDirectoryScanSnapshot? previous,
      ) {
        void handleProgress(String dir, int dirCount, int fileCount) {
          emit(
            tracker.updateScanProgress(
              currentDir: dir,
              scannedDirectories: dirCount,
              foundFiles: fileCount,
              cancelRequested: isCancelled?.call() ?? false,
            ),
          );
        }

        final runner = _scanRunner;
        if (runner != null) {
          return runner(
            source,
            gateway,
            scanRoots: effectiveRoots,
            detectLocalCovers: source.kind == MediaSourceKind.local,
            snapshotKey: snapshotKey,
            previousSnapshot: previous,
            onCheckpoint: store?.save,
            isCancelled: isCancelled,
            onFolderVisited: tracker.recordFolderVisited,
            onProgress: handleProgress,
          );
        }
        return _scanner.scan(
          gateway,
          scanRoots: effectiveRoots,
          detectLocalCovers: source.kind == MediaSourceKind.local,
          profileOverride: ScrapeDirectoryScanProfile.forSourceKind(
            source.kind,
          ),
          sourceId: snapshotKey,
          previousSnapshot: previous,
          onCheckpoint: store?.save,
          isCancelled: isCancelled,
          onFolderVisited: tracker.recordFolderVisited,
          onProgress: handleProgress,
        );
      }

      ScrapeDirectoryScanResult scanResult;
      try {
        scanResult = await scan(previousSnapshot);
      } catch (error) {
        // 断点记录的待扫目录可能已被移除，重新列举父目录以确认当前拓扑。
        if (previousSnapshot == null ||
            previousSnapshot.isComplete ||
            ScrapeSourceAccessErrorClassifier.classify(
                  error,
                  source.kind,
                ).kind !=
                SourceAccessProblemKind.path) {
          rethrow;
        }
        _logDecision(
          code: 'scraper.scan.snapshot_fallback',
          message: '断点路径不存在，回退至全量目录树复查',
          severity: DiagnosticSeverity.warn,
          source: 'ScrapePipeline.scanAndScrapeSource',
          context: <String, Object?>{'sourceId': source.id},
        );
        scanResult = await scan(null);
      }

      if (scanResult.cancelled || (isCancelled?.call() ?? false)) {
        final cancelled = tracker.advance(
          phase: ScrapePhase.cancelled,
          currentItemName: '已取消扫描',
          scannedDirectories: scanResult.scannedDirectories,
          folderVideoCounts: scanResult.folderVideoCounts,
          cancelRequested: true,
        );
        emit(cancelled);
        return cancelled;
      }

      emit(
        tracker.advance(
          phase: ScrapePhase.grouping,
          currentItemName: '正在聚合作品目录...',
          scannedDirectories: scanResult.scannedDirectories,
          foundFiles: scanResult.files.length,
          folderVideoCounts: scanResult.folderVideoCounts,
        ),
      );

      final existingSourceVariants = await _repository.getVariantsBySource(
        source.id,
      );
      final allExistingWorks = await _repository.getAllWorks();
      final worksById = <String, Work>{
        for (final w in allExistingWorks) w.id: w,
      };
      final sourceVariantById = <String, MediaVariant>{
        for (final v in existingSourceVariants) v.id: v,
      };
      final workIdByRelPath = <String, String>{};
      final unlockedVariantsByWorkId = <String, List<MediaVariant>>{};
      final lockedByNormalizedPath = <String, MediaVariant>{};
      for (final variant in existingSourceVariants) {
        workIdByRelPath[variant.relativePath] = variant.workId;
        if (variant.workLocked || variant.scopeLocked) {
          final norm = _normalizeSourceRelPath(variant.relativePath);
          if (norm.isNotEmpty) {
            lockedByNormalizedPath[norm] = variant;
          }
        } else {
          unlockedVariantsByWorkId
              .putIfAbsent(variant.workId, () => <MediaVariant>[])
              .add(variant);
        }
      }

      final lockedActiveWorkIds = <String>{};
      final lockedActiveVariantIds = <String>{};
      final unlockedScanFiles = <ScannedFileInput>[];
      for (final file in scanResult.files) {
        final norm = _normalizeSourceRelPath(file.relativePath);
        final lockedVariant = lockedByNormalizedPath[norm];
        if (lockedVariant != null) {
          lockedActiveWorkIds.add(lockedVariant.workId);
          lockedActiveVariantIds.add(lockedVariant.id);
        } else {
          unlockedScanFiles.add(file);
        }
      }

      final localCoverAbsByFolder = <String, String>{};
      if (source.kind == MediaSourceKind.local &&
          scanResult.localCoverByFolder.isNotEmpty) {
        for (final entry in scanResult.localCoverByFolder.entries) {
          final segments = entry.value
              .split('/')
              .where((seg) => seg.isNotEmpty)
              .toList(growable: false);
          if (segments.isEmpty) continue;
          localCoverAbsByFolder[entry.key] = p.joinAll([
            source.location,
            ...segments,
          ]);
        }
      }

      final groupedWorksAll = await computeSession.groupFiles(
        sourceId: source.id,
        files: unlockedScanFiles,
        nfoByFolder: scanResult.nfoByFolder,
        localCoverByFolder: localCoverAbsByFolder,
      );
      final ignoredFolders = (await _repository.getIgnoredFolders(source.id))
          .map((e) => e.trim().replaceAll('\\', '/'))
          .where((e) => e.isNotEmpty)
          .toSet();
      final filteredWorks = groupedWorksAll
          .where((folder) {
            final norm = folder.folderRelativePath.trim().replaceAll('\\', '/');
            return !ignoredFolders.any(
              (ig) => norm == ig || norm.startsWith('$ig/'),
            );
          })
          .toList(growable: false);
      // 零开销三级难度排程：按「简单（显式 ID）→ 中等（常规无 ID）→ 困难（乱目录/高歧义）」稳定排序，
      // 让简单目录最先瞬间匹配并实时上墙展示，困难目录排在末尾并按需启动第二套专属救援规则。
      final groupedWorks = MatchDifficultyClassifier.sortByDifficulty(
        filteredWorks,
      );
      final tierCounts = MatchDifficultyClassifier.countByDifficulty(
        groupedWorks,
      );

      emit(
        tracker.advance(
          phase: ScrapePhase.scraping,
          totalWorks: groupedWorks.length,
          processedWorks: 0,
          easyWorks: tierCounts.easy,
          mediumWorks: tierCounts.medium,
          hardWorks: tierCounts.hard,
          currentDifficulty: groupedWorks.isEmpty
              ? null
              : groupedWorks.first.matchDifficulty,
        ),
      );

      // 预计算同物理父目录下被多个兄弟拆簇共同指向的冲突 workId（如升级前未拆分旧主卡），
      // 仅排除真正存在兄弟争抢的旧卡，允许已独立归并至异目录存活主卡的拆簇稳定复用并快跳。
      final conflictingSplitWorkIdsByRoot = <String, Set<String>>{};
      final splitClustersByRoot = <String, List<GroupedWorkFolder>>{};
      for (final folder in groupedWorks) {
        if (!folder.isSplitCluster) continue;
        final normRoot = _normalizeSourceRelPath(
          folder.physicalRootFolder ?? '',
        );
        if (normRoot.isEmpty) continue;
        splitClustersByRoot
            .putIfAbsent(normRoot, () => <GroupedWorkFolder>[])
            .add(folder);
      }
      for (final entry in splitClustersByRoot.entries) {
        final root = entry.key;
        final clusters = entry.value;
        final ownerClusterCount = <String, int>{};
        for (final cluster in clusters) {
          final seenInCluster = <String>{};
          for (final v in cluster.variants) {
            final ownerId = workIdByRelPath[v.relativePath];
            if (ownerId != null) {
              seenInCluster.add(ownerId);
            }
          }
          for (final id in seenInCluster) {
            ownerClusterCount[id] = (ownerClusterCount[id] ?? 0) + 1;
          }
        }
        final conflicts = <String>{
          ScrapeWorkPersister.deterministicId('${source.id}::$root'),
          for (final c in ownerClusterCount.entries)
            if (c.value >= 2) c.key,
        };
        conflictingSplitWorkIdsByRoot[root] = conflicts;
      }

      final scanContext = _ScanBatchContext(
        computeWorker: computeSession,
        worksById: worksById,
        workIdByRelPath: workIdByRelPath,
        sourceVariantById: sourceVariantById,
        unlockedVariantsByWorkId: unlockedVariantsByWorkId,
        conflictingSplitWorkIdsByRoot: conflictingSplitWorkIdsByRoot,
        persistMutex: _AsyncMutex(),
      );

      final activeWorkIds = <String>{...lockedActiveWorkIds};
      final activeVariantIds = <String>{...lockedActiveVariantIds};
      final workIdByFolderPath = <String, String>{};
      final identityMutatedWorkIds = <String>{};

      // 阶段 3 受控跨作品并发池：重叠多部作品的在线元数据往返，同时对写库与进度上报串行加锁防竞态。
      final effectiveConcurrency = _maxWorkConcurrency < 1
          ? 1
          : (_maxWorkConcurrency > groupedWorks.length
                ? groupedWorks.length
                : _maxWorkConcurrency);
      var nextIndex = 0;
      var cancelledDuringScrape = false;
      Object? fatalError;
      StackTrace? fatalStackTrace;

      Future<void> runWorker() async {
        while (true) {
          if (fatalError != null) return;
          if (isCancelled?.call() ?? false) {
            cancelledDuringScrape = true;
            return;
          }
          if (nextIndex >= groupedWorks.length) return;
          final folder = groupedWorks[nextIndex++];
          emit(
            tracker.advance(
              currentItemName: folder.cleanTitle,
              currentDifficulty: folder.matchDifficulty,
            ),
          );

          final _FolderProcessResult result;
          try {
            result = await _processSingleFolderSafe(
              source.id,
              folder,
              scanContext: scanContext,
              isCancelled: isCancelled,
            );
          } catch (error, stackTrace) {
            fatalError ??= error;
            fatalStackTrace ??= stackTrace;
            return;
          }

          if (isCancelled?.call() ?? false) {
            cancelledDuringScrape = true;
            return;
          }

          activeWorkIds.add(result.workId);
          activeWorkIds.addAll(result.extraWorkIds);
          workIdByFolderPath[folder.folderRelativePath] = result.workId;
          for (final v in folder.variants) {
            activeVariantIds.add(
              ScrapeWorkPersister.deterministicId(
                '${v.sourceId}::${v.relativePath}',
              ),
            );
          }
          if (result.didPersist) {
            if (!result.episodeSyncOnly) {
              identityMutatedWorkIds.add(result.workId);
              identityMutatedWorkIds.addAll(result.extraWorkIds);
            }
            onWorkPersisted?.call(
              result.workId,
              result.status,
              result.displayTitle,
            );
          }
          final snap = tracker.snapshot;
          emit(
            tracker.advance(
              processedWorks: snap.processedWorks + 1,
              matchedWorks:
                  snap.matchedWorks +
                  (result.status == ScrapeStatus.matched ? 1 : 0),
              reviewWorks:
                  snap.reviewWorks +
                  (result.status == ScrapeStatus.needsReview ? 1 : 0),
              unmatchedWorks:
                  snap.unmatchedWorks +
                  (result.status == ScrapeStatus.unmatched ? 1 : 0),
              hardRescuedWorks:
                  snap.hardRescuedWorks + (result.rescuedByHardRules ? 1 : 0),
              lastMatchedTitle: result.status == ScrapeStatus.matched
                  ? result.displayTitle
                  : null,
            ),
          );
        }
      }

      if (effectiveConcurrency > 0) {
        await Future.wait([
          for (var i = 0; i < effectiveConcurrency; i++) runWorker(),
        ]);
      }

      if (fatalError != null) {
        Error.throwWithStackTrace(fatalError!, fatalStackTrace!);
      }
      if (cancelledDuringScrape || (isCancelled?.call() ?? false)) {
        final cancelled = tracker.advance(
          phase: ScrapePhase.cancelled,
          currentItemName: '已取消刮削',
          cancelRequested: true,
        );
        emit(cancelled);
        return cancelled;
      }

      emit(tracker.advance(currentItemName: '正在整理系列归组与收尾...'));

      // 支持全量与局部 scanRoots 范围修剪：非空 scopedRoots 仅清理对应目录前缀下的失联条目，绝不误删未选目录作品。
      // 断点续扫期间已完成目录可能被单作品自动同步更新，留待后续校验确认缺失项。
      final canPruneStale = !scanResult.resumedFromCheckpoint;
      final normalizedScopedRoots = effectiveRoots
          .map(_normalizeSourceRelPath)
          .where((r) => r.isNotEmpty)
          .toList(growable: false);
      bool withinScopedRoots(String rawRelPath) {
        if (normalizedScopedRoots.isEmpty) return true;
        final norm = _normalizeSourceRelPath(rawRelPath);
        return normalizedScopedRoots.any(
          (root) => norm == root || norm.startsWith('$root/'),
        );
      }

      final hadStaleSourceVariant =
          canPruneStale &&
          existingSourceVariants.any(
            (v) =>
                withinScopedRoots(v.relativePath) &&
                !activeVariantIds.contains(v.id),
          );
      if (canPruneStale) {
        await _repository.pruneStaleSourceEntries(
          sourceId: source.id,
          activeWorkIds: activeWorkIds,
          activeVariantIds: activeVariantIds,
          scopedRoots: effectiveRoots,
        );
      }

      // 方案 A：自动归并同一媒体源下匹配至完全相同强身份（TMDB 或 Bangumi）的多版本作品卡片
      // （涵盖多压制组洗版目录、不同兄弟目录及合集拆簇，完整保留多版本正片、特典、CD、Scan 与播放进度）。
      var mergedAnyWork = false;
      if (activeWorkIds.isNotEmpty) {
        final mergeRes =
            await ReleaseGroupWorkMerger.mergeSameSourceIdentityWorks(
              repository: _repository,
              sourceId: source.id,
              focusWorkIds: activeWorkIds,
              photosStorage: _photosStorage,
            );
        if (mergeRes.absorbedIds.isNotEmpty) {
          mergedAnyWork = true;
          activeWorkIds.removeAll(mergeRes.absorbedIds);
          identityMutatedWorkIds.removeAll(mergeRes.absorbedIds);
          for (final id in mergeRes.absorbedIds) {
            scanContext.worksById.remove(id);
          }
          for (final targetId in mergeRes.survivingTargetIds) {
            identityMutatedWorkIds.add(targetId);
            final refreshed = await _repository.findWorkById(targetId);
            if (refreshed != null) {
              scanContext.worksById[targetId] = refreshed;
            }
          }
        }
      }

      // 当局部扫描新入库的作品在同源范围外存在同身份/同名旧副本，且旧目录已在源端消失时，自动清除该幽灵重复作品。
      if (effectiveRoots.isNotEmpty &&
          activeWorkIds.isNotEmpty &&
          !(isCancelled?.call() ?? false)) {
        await _pruneMovedOutOfScopeGhostWorks(
          gateway: gateway,
          sourceId: source.id,
          sourceKind: source.kind,
          newlyActiveWorkIds: activeWorkIds,
          scopedRoots: effectiveRoots,
          isCancelled: isCancelled,
        );
      }

      if (isCancelled?.call() ?? false) {
        final cancelled = tracker.advance(
          phase: ScrapePhase.cancelled,
          currentItemName: '已取消刮削',
          cancelRequested: true,
        );
        emit(cancelled);
        return cancelled;
      }

      // 变更门控：仅当本次存在新增/身份变更/归并/修剪作品时才运行系列自动编组，
      // 且仅对本次发生身份变动的作品发起 Bangumi 关联与 ClearLogo 交叉校验，消除大库收尾冗余网络风暴。
      if (identityMutatedWorkIds.isNotEmpty ||
          mergedAnyWork ||
          hadStaleSourceVariant) {
        final focusBangumiIds = <int>{
          for (final id in identityMutatedWorkIds)
            if ((scanContext.worksById[id]?.bangumiId ?? 0) > 0)
              scanContext.worksById[id]!.bangumiId!,
        };
        try {
          await SeriesAutoLinker.reconcileAll(
            repository: _repository,
            bangumiService: _bangumiService,
            tmdbService: _tmdbService,
            tmdbCollectionIdByTmdbId: _tmdbCollectionIdByTmdbId,
            focusBangumiIds: focusBangumiIds,
            focusWorkIds: identityMutatedWorkIds,
            relationCache: _bangumiRelationCache,
            isCancelled: isCancelled,
            onRelationProgress: (done, total) {
              if (total > 0 && !(isCancelled?.call() ?? false)) {
                emit(
                  tracker.advance(
                    currentItemName: '正在整理系列归组 ($done/$total)...',
                  ),
                );
              }
            },
          );
        } catch (linkError) {
          if (!NetworkErrorSanitizer.isTransientNetworkError(linkError)) {
            rethrow;
          }
        }
      }

      if (isCancelled?.call() ?? false) {
        final cancelled = tracker.advance(
          phase: ScrapePhase.cancelled,
          currentItemName: '已取消刮削',
          cancelRequested: true,
        );
        emit(cancelled);
        return cancelled;
      }

      final completed = tracker.advance(
        phase: ScrapePhase.completed,
        currentItemName: '刮削完成',
      );
      _logDecision(
        code: 'scraper.scan.completed',
        message: '媒体源刮削完成：${source.label}',
        source: 'ScrapePipeline.scanAndScrapeSource',
        context: <String, Object?>{
          'sourceId': source.id,
          'matchedWorks': completed.matchedWorks,
          'reviewWorks': completed.reviewWorks,
          'unmatchedWorks': completed.unmatchedWorks,
          'totalWorks': completed.totalWorks,
        },
      );
      emit(completed);
      return completed;
    } catch (error, stackTrace) {
      _logDecision(
        code: 'scraper.scan.failed',
        message: '媒体源刮削异常终止：${source.label}',
        severity: DiagnosticSeverity.error,
        source: 'ScrapePipeline.scanAndScrapeSource',
        error: error,
        stackTrace: stackTrace,
        context: <String, Object?>{'sourceId': source.id},
      );
      final failed = tracker.advance(
        phase: ScrapePhase.failed,
        errorMessage: NetworkErrorSanitizer.toUserMessage(error),
      );
      emit(failed);
      rethrow;
    } finally {
      _tmdbService.endSessionCache();
      await computeSession.dispose();
      await gateway.close();
    }
  }

  Future<_FolderProcessResult> _processSingleFolderSafe(
    String sourceId,
    GroupedWorkFolder folder, {
    required _ScanBatchContext scanContext,
    bool Function()? isCancelled,
  }) async {
    try {
      return await _processSingleFolder(
        sourceId,
        folder,
        scanContext: scanContext,
        isCancelled: isCancelled,
      );
    } catch (error) {
      if (!NetworkErrorSanitizer.isTransientNetworkError(error)) {
        rethrow;
      }
      if (isCancelled?.call() ?? false) {
        return _FolderProcessResult(
          status: ScrapeStatus.needsReview,
          workId: ScrapeWorkPersister.deterministicId(
            '$sourceId::${folder.folderRelativePath}',
          ),
          displayTitle: folder.cleanTitle,
          didPersist: false,
        );
      }
      return scanContext.persistMutex.synchronized(() async {
        _logDecision(
          code: 'scraper.folder.transient_error',
          message: '远端刮削遭遇瞬态网络故障，保留既有状态并隔离异常',
          severity: DiagnosticSeverity.warn,
          source: 'ScrapePipeline._processSingleFolderSafe',
          error: error,
          context: <String, Object?>{
            'sourceId': sourceId,
            'folder': folder.folderRelativePath,
          },
        );
        final existing = await _persister.findExistingWorkForFolder(
          sourceId,
          folder,
          workIdByRelPath: scanContext.workIdByRelPath,
          worksById: scanContext.worksById,
          excludedSplitWorkIds: scanContext.conflictingSplitWorkIdsFor(folder),
        );
        final workId =
            existing?.id ??
            ScrapeWorkPersister.deterministicId(
              '$sourceId::${folder.folderRelativePath}',
            );
        if (existing != null && existing.scrapeStatus == ScrapeStatus.matched) {
          await _persister.syncEpisodesAndVariants(
            work: existing,
            folder: folder,
            tmdbEpisodes: const [],
            preloadedSourceVariantsById: scanContext.sourceVariantById,
          );
          return _FolderProcessResult(
            status: existing.scrapeStatus,
            workId: workId,
            displayTitle: existing.title,
            didPersist: true,
          );
        }
        final canPromoteLocalCover =
            WorkWallEligibility.shouldPromoteCoverFallback(
              folder: folder,
              coverPath: folder.localPosterPath,
            );
        final fallbackWork = canPromoteLocalCover
            ? ScrapeWorkPersister.buildCoverFallbackWork(
                id: workId,
                folder: folder,
                posterPath: folder.localPosterPath!,
                isHidden: existing?.keepHidden == true
                    ? true
                    : (existing?.isHidden ?? false),
                keepHidden: existing?.keepHidden ?? false,
              )
            : Work(
                id: workId,
                title: folder.cleanTitle,
                year: folder.year,
                folderTmdbHint: folder.explicitTmdbId,
                isManualLocked: false,
                isHidden: existing?.keepHidden == true
                    ? true
                    : (existing?.isHidden ?? false),
                keepHidden: existing?.keepHidden ?? false,
                scrapeStatus: ScrapeStatus.needsReview,
                reviewReason: NetworkErrorSanitizer.toUserMessage(
                  error,
                  prefix: 'TMDB 网络异常，已使用本地目录降级入库',
                ),
              );
        await _repository.upsertWork(fallbackWork);
        scanContext.worksById[fallbackWork.id] = fallbackWork;
        await _photosStorage?.renameWorkFolderIfNeeded(
          fallbackWork.id,
          fallbackWork.title,
        );
        await _persister.syncEpisodesAndVariants(
          work: fallbackWork,
          folder: folder,
          tmdbEpisodes: const [],
          preloadedSourceVariantsById: scanContext.sourceVariantById,
        );
        return _FolderProcessResult(
          status: fallbackWork.scrapeStatus,
          workId: workId,
          displayTitle: fallbackWork.title,
          didPersist: true,
        );
      });
    }
  }

  Future<_FolderProcessResult> _processSingleFolder(
    String sourceId,
    GroupedWorkFolder folder, {
    required _ScanBatchContext scanContext,
    bool Function()? isCancelled,
  }) async {
    // 既有 Season 0 拆作防回并护栏：若当前物理目录已由 SeasonZeroWorkSplitter 拆分为多部独立
    // Bangumi 特别篇（如加速世界 Stage:01 + Stage:02），重扫文件未变时直接零请求快跳并登记全部 workId，
    // 文件变化时禁止进入单作增量同步快通道，交由阶段 3 重新拆作更新，严防后续重扫把多作重新吸回单作。
    final splitSeasonZeroOwners = _inspectAlreadySplitSeasonZeroOwners(
      folder: folder,
      scanContext: scanContext,
    );
    if (splitSeasonZeroOwners.canFastSkip) {
      final ids = splitSeasonZeroOwners.orderedWorkIds;
      return _FolderProcessResult(
        status: ScrapeStatus.matched,
        workId: ids.first,
        extraWorkIds: ids.skip(1).toList(growable: false),
        displayTitle: splitSeasonZeroOwners.ownersById[ids.first]!.title,
        didPersist: false,
      );
    }

    final existing = await _persister.findExistingWorkForFolder(
      sourceId,
      folder,
      workIdByRelPath: scanContext.workIdByRelPath,
      worksById: scanContext.worksById,
      excludedSplitWorkIds: scanContext.conflictingSplitWorkIdsFor(folder),
    );
    final workId =
        existing?.id ??
        ScrapeWorkPersister.deterministicId(
          '$sourceId::${folder.folderRelativePath}',
        );

    // 增量重扫零请求快跳：已成功入库（TMDB / Bangumi 独立条目 / Fanart / 本地封面 / 人工锁定）且物理文件集与字幕未变化、
    // 且未出现新的显式 ID/季提示时，直接沿用既有入库结果并跳过全部在线 API 与重复写库；详情页始终保留手动重抓与补绑入口。
    final hasMatchedIdentityOrCover =
        existing != null &&
        (existing.tmdbId != null ||
            existing.bangumiId != null ||
            existing.tvdbId != null ||
            existing.isManualLocked ||
            (existing.posterPath != null &&
                existing.posterPath!.trim().isNotEmpty));
    if (!splitSeasonZeroOwners.isSplit &&
        existing != null &&
        existing.scrapeStatus == ScrapeStatus.matched &&
        hasMatchedIdentityOrCover &&
        _canFastSkipUnchangedMatchedWork(
          existing: existing,
          folder: folder,
          existingUnlockedVariants:
              scanContext.unlockedVariantsByWorkId[existing.id] ?? const [],
          mappingIndex: _mappingIndex,
        )) {
      return _FolderProcessResult(
        status: existing.scrapeStatus,
        workId: workId,
        displayTitle: existing.title,
        didPersist: false,
      );
    }

    // 阶段 1A：已自动匹配作品的增量加集 / 删集快通道：
    // 追番目录新增一集、删集或换字幕时跳过全部 TMDB/Bangumi 搜索与艺术图重抓，仅按需同步目标季剧集与文件。
    if (!splitSeasonZeroOwners.isSplit &&
        existing != null &&
        !existing.isManualLocked &&
        existing.scrapeStatus == ScrapeStatus.matched &&
        _canUseIncrementalEpisodeFastPath(
          existing: existing,
          folder: folder,
          mappingIndex: _mappingIndex,
        )) {
      await _workDirectorySync.syncMatchedWorkEpisodesOnly(
        work: existing,
        folder: folder,
        preloadedSourceVariantsById: scanContext.sourceVariantById,
        runPersist: scanContext.persistMutex.synchronized,
        isCancelled: isCancelled,
      );
      _logDecision(
        code: 'scraper.work.incremental_episode_sync',
        message: '已匹配作品增量分集同步完成：${existing.title}',
        source: 'ScrapePipeline._processSingleFolder',
        context: <String, Object?>{'workId': existing.id},
      );
      return _FolderProcessResult(
        status: existing.scrapeStatus,
        workId: workId,
        displayTitle: existing.title,
        didPersist: true,
        episodeSyncOnly: true,
      );
    }

    final seasons = _extractReferencedSeasons(folder);

    // 阶段 1：人工锁定保护，跳过自动重刮削，仅同步新增文件与剧集关联（保留手动文件映射与 Bangumi 穿插校准）。
    if (existing != null && existing.isManualLocked) {
      _logDecision(
        code: 'scraper.work.manual_lock_preserved',
        message: '保留人工锁定作品元数据并仅同步分集文件：${existing.title}',
        source: 'ScrapePipeline._processSingleFolder',
        context: <String, Object?>{
          'workId': existing.id,
          'title': existing.title,
        },
      );
      final lockedSeasons = <int>{
        ...seasons,
        if (existing.matchedSeason != null && existing.matchedSeason! > 0)
          existing.matchedSeason!,
      };
      TmdbWorkDetail? lockedDetail;
      if (existing.tmdbId != null && existing.tmdbMediaType != null) {
        try {
          lockedDetail = await _tmdbService.getWorkDetail(
            existing.tmdbId!,
            existing.tmdbMediaType!,
            priority: RequestPriority.background,
            includeImages: false,
          );
        } catch (error) {
          developer.log(
            '锁定作品详情预拉失败，继续本地分集同步',
            name: 'konata.scrape_orchestrator',
            error: error,
          );
          lockedDetail = null;
        }
      }
      final preRemap =
          (lockedDetail != null &&
              lockedDetail.mediaType == TmdbMediaType.tv &&
              lockedDetail.seasons.isNotEmpty)
          ? EpisodeRemapper.buildPlan(
              folder: folder,
              tmdbSeasons: lockedDetail.seasons,
              matchedSeason: existing.matchedSeason,
            )
          : null;
      if (preRemap != null) {
        lockedSeasons.addAll(preRemap.referencedSeasons);
      }
      if (lockedDetail?.collectionId != null &&
          lockedDetail!.collectionId! > 0) {
        _tmdbCollectionIdByTmdbId[lockedDetail.tmdbId] =
            lockedDetail.collectionId!;
      }
      final episodes =
          (existing.tmdbId != null && existing.tmdbMediaType != null)
          ? await _candidateFetcher.fetchEpisodesForDetail(
              existing.tmdbId!,
              existing.tmdbMediaType!,
              lockedSeasons,
            )
          : const <TmdbEpisodeDetail>[];
      final bgmEps =
          (existing.bangumiId != null &&
              ((preRemap?.hasInterspersedSpecialCandidate ?? false) ||
                  episodes.isEmpty ||
                  episodes.any((e) => e.title.trim().isEmpty)))
          ? await _candidateFetcher.fetchBangumiEpisodes(
              existing.bangumiId!,
              type: null,
            )
          : const <BangumiEpisodeEntry>[];
      final finalRemap =
          (lockedDetail != null &&
              lockedDetail.mediaType == TmdbMediaType.tv &&
              lockedDetail.seasons.isNotEmpty)
          ? EpisodeRemapper.buildPlan(
              folder: folder,
              tmdbSeasons: lockedDetail.seasons,
              matchedSeason: existing.matchedSeason,
              tmdbEpisodes: episodes,
              bangumiEpisodes: bgmEps,
            )
          : preRemap;
      if (isCancelled?.call() ?? false) {
        return _FolderProcessResult(
          status: existing.scrapeStatus,
          workId: workId,
          displayTitle: existing.title,
          didPersist: false,
        );
      }
      await scanContext.persistMutex.synchronized(() async {
        await _persister.syncEpisodesAndVariants(
          work: existing,
          folder: folder,
          tmdbEpisodes: episodes,
          bangumiEpisodes: bgmEps,
          remapPlan: finalRemap,
          preloadedSourceVariantsById: scanContext.sourceVariantById,
        );
      });
      return _FolderProcessResult(
        status: existing.scrapeStatus,
        workId: workId,
        displayTitle: existing.title,
        didPersist: true,
      );
    }

    Object? tmdbNetworkError;
    void recordTmdbError(Object err) {
      tmdbNetworkError ??= err;
    }

    // 阶段 2：显式文件夹 `[tmdbid=xxx]` / `.nfo` 精确直连通道（含首选 404 跨类型重试与 Bangumi 补充封面）。
    var effectiveFolder = folder;
    if (folder.explicitTmdbId != null) {
      final detail = await _candidateFetcher.fetchExplicitDetail(
        folder,
        onNetworkError: recordTmdbError,
      );
      if (detail != null) {
        final preSeason =
            folder.seasonHint ??
            ScrapeDomainAdapter.fallbackResolveSeason(
              folder: folder,
              detail: detail,
            );
        // 显式 TMDB 目录优先通过离线双向索引 O(log N) 反查精准 Bangumi ID 直拉详情，
        // 避免对海量显式 ID 目录逐部发起模糊关键词 POST 搜索；未命中时平滑回退常规搜索。
        final reverseMatches =
            _mappingIndex?.lookupBangumiIdsByTmdb(
              mediaType: detail.mediaType,
              tmdbId: detail.tmdbId,
              season: preSeason,
              strictSeason: true,
            ) ??
            const <BangumiReverseMatch>[];
        // 电影或已锁定季号时直接取前 3 条（覆盖分割放送上下季）；多季剧集未定季时仅在候选数 <= 3 才直拉，
        // 避免长篇多季番（如 5+ 季）只取前两季遗漏真实季条目。
        final allowReverseDirect =
            preSeason != null ||
            detail.mediaType == TmdbMediaType.movie ||
            reverseMatches.length <= 3;
        final directBgmIds = <int>[
          if (folder.explicitBangumiId != null) folder.explicitBangumiId!,
          if (allowReverseDirect)
            for (final match in reverseMatches.take(3))
              if (match.bangumiId != folder.explicitBangumiId) match.bangumiId,
        ];
        final usedDirectBgm = directBgmIds.isNotEmpty;
        var bgmCandidates = usedDirectBgm
            ? await _candidateFetcher.fetchBangumiSubjectsByIds(directBgmIds)
            : const <BangumiSubjectCandidate>[];
        if (bgmCandidates.isEmpty) {
          bgmCandidates = await _candidateFetcher.fetchBangumiCandidates(
            folder,
            extraQueries: [detail.title, ...detail.aliases.take(2)],
          );
        }
        var explicitDecision = await scanContext.computeWorker.evaluateMatch(
          folder,
          [detail],
          bangumiCandidates: bgmCandidates,
          mappingIndex: _mappingIndex,
        );
        if (usedDirectBgm && explicitDecision.bestBangumi == null) {
          final fallbackBgm = await _candidateFetcher.fetchBangumiCandidates(
            folder,
            extraQueries: [detail.title, ...detail.aliases.take(2)],
          );
          if (fallbackBgm.isNotEmpty) {
            explicitDecision = await scanContext.computeWorker.evaluateMatch(
              folder,
              [detail],
              bangumiCandidates: fallbackBgm,
              mappingIndex: _mappingIndex,
            );
          }
        }
        if (isCancelled?.call() ?? false) {
          return _FolderProcessResult(
            status: ScrapeStatus.unmatched,
            workId: workId,
            displayTitle: folder.cleanTitle,
            didPersist: false,
          );
        }
        final status = await _bindAndPersistDetail(
          workId: workId,
          existing: existing,
          folder: folder,
          detail: detail,
          matchedSeason:
              explicitDecision.matchedSeason ??
              folder.seasonHint ??
              ScrapeDomainAdapter.fallbackResolveSeason(
                folder: folder,
                detail: detail,
              ),
          bangumiCandidate: explicitDecision.bestBangumi,
          seasons: seasons,
          isManualLocked: existing?.isManualLocked ?? false,
          isHidden: existing?.keepHidden == true
              ? true
              : (existing?.isHidden ?? false),
          keepHidden: existing?.keepHidden ?? false,
          scanContext: scanContext,
          isCancelled: isCancelled,
        );
        return _FolderProcessResult(
          status: status,
          workId: workId,
          displayTitle: scanContext.worksById[workId]?.title ?? detail.title,
          didPersist: status == ScrapeStatus.matched,
        );
      }
      // 仅在无网络异常（即双侧真实 404）时清除失效的 explicitTmdbId，防止网络故障误抹除目录显式提示。
      if (tmdbNetworkError == null) {
        effectiveFolder = folder.withoutExplicitTmdb();
      }
    }

    // 阶段 3：Bangumi 在线优先匹配 -> 离线映射直连快通道 -> 交叉关键词救回 TMDB 搜索 -> 合集父系列兜底 -> 双向互保重评（未命中时自动触发困难目录第二套规则）。
    final resolution = await _matchResolver.resolve(
      effectiveFolder,
      tmdbUnavailable: tmdbNetworkError != null,
      computeWorker: scanContext.computeWorker,
    );
    if (isCancelled?.call() ?? false) {
      return _FolderProcessResult(
        status: ScrapeStatus.unmatched,
        workId: workId,
        displayTitle: effectiveFolder.cleanTitle,
        didPersist: false,
      );
    }
    if (resolution.networkError != null) {
      recordTmdbError(resolution.networkError!);
    }
    final decision = resolution.decision;

    if (decision.level == MatchLevel.autoBind && decision.best != null) {
      final resolvedSeason =
          decision.matchedSeason ?? decision.best!.matchedSeason;
      if (resolvedSeason == 0 &&
          decision.best!.detail.mediaType == TmdbMediaType.tv &&
          decision.bestBangumi != null &&
          _bangumiService != null) {
        final existingByBgm = <int, String>{
          ...splitSeasonZeroOwners.workIdByBangumiId,
          if (existing != null && (existing.bangumiId ?? 0) > 0)
            existing.bangumiId!: existing.id,
        };
        final slices = await SeasonZeroWorkSplitter.tryPlanSplit(
          sourceId: sourceId,
          primaryWorkId: workId,
          folder: effectiveFolder,
          detail: decision.best!.detail,
          matchedSeason: resolvedSeason,
          bangumiCandidate: decision.bestBangumi,
          bangumiService: _bangumiService,
          knownBangumiCandidates: resolution.bangumiCandidates,
          mappingIndex: _mappingIndex,
          relationCache: _bangumiRelationCache,
          existingWorkIdByBangumiId: existingByBgm.isEmpty
              ? null
              : existingByBgm,
          priority: RequestPriority.background,
        );
        if (slices != null && slices.length >= 2) {
          var firstStatus = ScrapeStatus.matched;
          final cleanupOrphanIds = <String>{
            workId,
            ...splitSeasonZeroOwners.orderedWorkIds,
          };
          for (var i = 0; i < slices.length; i++) {
            final slice = slices[i];
            final sliceExisting =
                scanContext.worksById[slice.workId] ??
                await _repository.findWorkById(slice.workId);
            final sliceStatus = await _bindAndPersistDetail(
              workId: slice.workId,
              existing: sliceExisting,
              folder: slice.folder,
              detail: decision.best!.detail,
              matchedSeason: 0,
              bangumiCandidate: slice.bangumiCandidate,
              seasons: seasons,
              isManualLocked: false,
              isHidden: sliceExisting?.keepHidden == true
                  ? true
                  : (sliceExisting?.isHidden ?? false),
              keepHidden: sliceExisting?.keepHidden ?? false,
              scanContext: scanContext,
              isCancelled: isCancelled,
            );
            if (i == 0) {
              firstStatus = sliceStatus;
            }
            for (final v in slice.folder.variants) {
              scanContext.workIdByRelPath[v.relativePath] = slice.workId;
            }
            cleanupOrphanIds.add(slice.workId);
          }
          await scanContext.persistMutex.synchronized(() async {
            for (final id in cleanupOrphanIds) {
              await _repository.deleteOrphanEpisodes(id);
            }
          });
          return _FolderProcessResult(
            status: firstStatus,
            workId: slices.first.workId,
            extraWorkIds: slices
                .skip(1)
                .map((s) => s.workId)
                .toList(growable: false),
            displayTitle:
                scanContext.worksById[slices.first.workId]?.title ??
                slices.first.bangumiCandidate.subject.displayTitle,
            didPersist: firstStatus == ScrapeStatus.matched,
            rescuedByHardRules: resolution.rescuedByHardRules,
          );
        }
      }
      final status = await _bindAndPersistDetail(
        workId: workId,
        existing: existing,
        folder: effectiveFolder,
        detail: decision.best!.detail,
        matchedSeason: resolvedSeason,
        bangumiCandidate: decision.bestBangumi,
        seasons: seasons,
        isManualLocked: false,
        isHidden: existing?.keepHidden == true
            ? true
            : (existing?.isHidden ?? false),
        keepHidden: existing?.keepHidden ?? false,
        scanContext: scanContext,
        isCancelled: isCancelled,
      );
      return _FolderProcessResult(
        status: status,
        workId: workId,
        displayTitle:
            scanContext.worksById[workId]?.title ?? decision.best!.detail.title,
        didPersist: status == ScrapeStatus.matched,
        rescuedByHardRules: resolution.rescuedByHardRules,
      );
    }

    // 既有 Bangumi 单源作品在次轮扫描尝试升级补齐 TMDB 时：
    // 若常规关键词重评因目录名宽泛未能 autoBind，优先按已确认的 Bangumi ID 唯一离线映射直连升级 TMDB；
    // 若仍无法升级，则绝不将已匹配的 Bangumi 作品降级抹空为 needsReview。
    if (tmdbNetworkError == null &&
        existing != null &&
        !existing.metadataLocked &&
        existing.tmdbId == null &&
        existing.bangumiId != null &&
        existing.scrapeStatus == ScrapeStatus.matched) {
      final mappedTargets = BangumiTmdbIndex.resolveTargets(
        existing.bangumiId!,
        index: _mappingIndex,
      );
      if (mappedTargets.length == 1) {
        final target = mappedTargets.single;
        TmdbWorkDetail? mappedDetail;
        for (final cand in resolution.candidates) {
          if (cand.mediaType == target.type && cand.tmdbId == target.id) {
            mappedDetail = cand;
            break;
          }
        }
        if (mappedDetail == null) {
          try {
            mappedDetail = await _tmdbService.getWorkDetail(
              target.id,
              target.type,
              priority: RequestPriority.background,
              includeImages: false,
            );
          } catch (error) {
            if (NetworkErrorSanitizer.isTransientNetworkError(error)) {
              recordTmdbError(error);
            }
          }
        }
        if (mappedDetail != null && !(isCancelled?.call() ?? false)) {
          final attachedBgm =
              resolution.bestBangumi?.subject.id == existing.bangumiId
              ? resolution.bestBangumi
              : null;
          final status = await _bindAndPersistDetail(
            workId: workId,
            existing: existing,
            folder: effectiveFolder,
            detail: mappedDetail,
            matchedSeason:
                target.season ??
                effectiveFolder.seasonHint ??
                ScrapeDomainAdapter.fallbackResolveSeason(
                  folder: effectiveFolder,
                  detail: mappedDetail,
                ),
            bangumiCandidate: attachedBgm,
            seasons: seasons,
            isManualLocked: false,
            isHidden: existing.keepHidden ? true : existing.isHidden,
            keepHidden: existing.keepHidden,
            scanContext: scanContext,
            isCancelled: isCancelled,
          );
          return _FolderProcessResult(
            status: status,
            workId: workId,
            displayTitle:
                scanContext.worksById[workId]?.title ?? mappedDetail.title,
            didPersist: status == ScrapeStatus.matched,
          );
        }
      }
      if (tmdbNetworkError == null) {
        final kept = existing.reviewReason != null
            ? existing.copyWith(clearReviewReason: true)
            : existing;
        await scanContext.persistMutex.synchronized(() async {
          if (kept.reviewReason != existing.reviewReason) {
            await _repository.upsertWork(kept);
            scanContext.worksById[kept.id] = kept;
          }
          await _persister.syncEpisodesAndVariants(
            work: kept,
            folder: effectiveFolder,
            tmdbEpisodes: const [],
            preloadedSourceVariantsById: scanContext.sourceVariantById,
          );
        });
        return _FolderProcessResult(
          status: kept.scrapeStatus,
          workId: workId,
          displayTitle: kept.title,
          didPersist: true,
        );
      }
    }

    // 若本次因 TMDB 网络异常未能获取候选，但本地已存在成功匹配的旧记录，保留既有元数据并同步分集文件。
    if (tmdbNetworkError != null &&
        existing != null &&
        existing.scrapeStatus == ScrapeStatus.matched) {
      await scanContext.persistMutex.synchronized(() async {
        await _persister.syncEpisodesAndVariants(
          work: existing,
          folder: effectiveFolder,
          tmdbEpisodes: const [],
          preloadedSourceVariantsById: scanContext.sourceVariantById,
        );
      });
      return _FolderProcessResult(
        status: existing.scrapeStatus,
        workId: workId,
        displayTitle: existing.title,
        didPersist: true,
      );
    }

    final fallbackBgmCandidate =
        decision.bestBangumi ??
        (tmdbNetworkError != null ? resolution.bestBangumi : null);
    if (decision.best == null && fallbackBgmCandidate != null) {
      final bgmWall = await _artworkEnricher.evaluateBangumiOnly(
        folder: effectiveFolder,
        bangumiCandidate: fallbackBgmCandidate,
        bangumiTier: resolution.bangumiTier,
        priority: RequestPriority.background,
      );
      final bgmStatus =
          (bgmWall.canPromote ||
              (tmdbNetworkError == null &&
                  decision.level == MatchLevel.autoBind))
          ? ScrapeStatus.matched
          : ScrapeStatus.needsReview;
      // 即便仅凭 Bangumi 封面先上墙展示，当本次降级源于瞬时 TMDB 网络超时/中断时仍记录 reviewReason，
      // 确保下一次扫描自动自愈补齐 TMDB 元数据、16:9 背景图与跨目录多版本归并，而非永久快跳锁死。
      final bgmReviewReason = tmdbNetworkError != null
          ? NetworkErrorSanitizer.toUserMessage(
              tmdbNetworkError!,
              prefix: 'TMDB 网络异常，已降级使用 Bangumi 元数据入库',
            )
          : (bgmStatus == ScrapeStatus.matched ? null : decision.reviewReason);
      final builtBgmWork = ScrapeWorkPersister.buildBangumiOnlyWork(
        id: workId,
        folder: effectiveFolder,
        bangumiCandidate: fallbackBgmCandidate,
        status: bgmStatus,
        reviewReason: bgmReviewReason,
        tvdbId: bgmWall.tvdbId,
        posterPathOverride: bgmWall.fanartPoster,
        backdropPath: bgmWall.fanartBackdrop,
        portraitBackdropPath: bgmWall.fanartPortraitBackdrop,
        logoPath: bgmWall.fanartLogo,
        isManualLocked: false,
        isHidden: existing?.keepHidden == true
            ? true
            : (existing?.isHidden ?? false),
        keepHidden: existing?.keepHidden ?? false,
      );
      final work = ScrapeWorkPersister.mergeWorkWithLocks(
        existing: existing,
        candidate: builtBgmWork,
      );
      final bgmEpisodes =
          (bgmStatus == ScrapeStatus.matched || tmdbNetworkError != null)
          ? await _candidateFetcher.fetchBangumiEpisodes(
              fallbackBgmCandidate.subject.id,
              type: null,
            )
          : const <BangumiEpisodeEntry>[];
      if (isCancelled?.call() ?? false) {
        return _FolderProcessResult(
          status: bgmStatus,
          workId: workId,
          displayTitle: work.title,
          didPersist: false,
        );
      }
      await scanContext.persistMutex.synchronized(() async {
        await _repository.upsertWork(work);
        scanContext.worksById[work.id] = work;
        await _photosStorage?.renameWorkFolderIfNeeded(work.id, work.title);
        await _persister.saveTopCandidates(workId, decision.topCandidates);
        await _persister.syncEpisodesAndVariants(
          work: work,
          folder: effectiveFolder,
          tmdbEpisodes: const [],
          bangumiEpisodes: bgmEpisodes,
          preloadedSourceVariantsById: scanContext.sourceVariantById,
        );
      });
      return _FolderProcessResult(
        status: bgmStatus,
        workId: workId,
        displayTitle: work.title,
        didPersist: true,
        rescuedByHardRules: resolution.rescuedByHardRules,
      );
    }

    // 条件 C / D：无 TMDB 与 Bangumi 主匹配，但具备 Fanart.tv 有效封面或本地目录封面且含有效正片时独立上墙。
    final coverFallback = await _artworkEnricher.evaluateCoverFallback(
      folder: effectiveFolder,
      existingTvdbId: existing?.tvdbId,
      priority: RequestPriority.background,
    );
    if (coverFallback.canPromote && coverFallback.posterPath != null) {
      final builtFallback = ScrapeWorkPersister.buildCoverFallbackWork(
        id: workId,
        folder: effectiveFolder,
        posterPath: coverFallback.posterPath!,
        tvdbId: coverFallback.tvdbId,
        backdropPath: coverFallback.backdropPath,
        portraitBackdropPath: coverFallback.portraitBackdropPath,
        logoPath: coverFallback.logoPath,
        isHidden: existing?.keepHidden == true
            ? true
            : (existing?.isHidden ?? false),
        keepHidden: existing?.keepHidden ?? false,
      );
      final work = ScrapeWorkPersister.mergeWorkWithLocks(
        existing: existing,
        candidate: builtFallback,
      );
      await scanContext.persistMutex.synchronized(() async {
        await _repository.upsertWork(work);
        scanContext.worksById[work.id] = work;
        await _photosStorage?.renameWorkFolderIfNeeded(work.id, work.title);
        await _persister.saveTopCandidates(workId, decision.topCandidates);
        await _persister.syncEpisodesAndVariants(
          work: work,
          folder: effectiveFolder,
          tmdbEpisodes: const [],
          preloadedSourceVariantsById: scanContext.sourceVariantById,
        );
      });
      return _FolderProcessResult(
        status: ScrapeStatus.matched,
        workId: workId,
        displayTitle: work.title,
        didPersist: true,
      );
    }

    final status =
        (tmdbNetworkError != null ||
            decision.level == MatchLevel.reviewRequired)
        ? ScrapeStatus.needsReview
        : ScrapeStatus.unmatched;
    final reviewReason = tmdbNetworkError != null
        ? NetworkErrorSanitizer.toUserMessage(
            tmdbNetworkError!,
            prefix: 'TMDB 网络异常，已使用本地目录降级入库',
          )
        : decision.reviewReason;
    final work = Work(
      id: workId,
      title: effectiveFolder.cleanTitle,
      year: effectiveFolder.year,
      folderTmdbHint: effectiveFolder.explicitTmdbId,
      isManualLocked: false,
      isHidden: existing?.keepHidden == true
          ? true
          : (existing?.isHidden ?? false),
      keepHidden: existing?.keepHidden ?? false,
      scrapeStatus: status,
      reviewReason: reviewReason,
    );
    await scanContext.persistMutex.synchronized(() async {
      await _repository.upsertWork(work);
      scanContext.worksById[work.id] = work;
      await _photosStorage?.renameWorkFolderIfNeeded(work.id, work.title);
      await _persister.saveTopCandidates(workId, decision.topCandidates);
      await _persister.syncEpisodesAndVariants(
        work: work,
        folder: effectiveFolder,
        tmdbEpisodes: const [],
        preloadedSourceVariantsById: scanContext.sourceVariantById,
      );
    });
    return _FolderProcessResult(
      status: status,
      workId: workId,
      displayTitle: work.title,
      didPersist: true,
    );
  }

  Future<ScrapeStatus> _bindAndPersistDetail({
    required String workId,
    Work? existing,
    required GroupedWorkFolder folder,
    required TmdbWorkDetail detail,
    int? matchedSeason,
    ScoredBangumiCandidate? bangumiCandidate,
    required Set<int> seasons,
    required bool isManualLocked,
    bool isHidden = false,
    bool keepHidden = false,
    _ScanBatchContext? scanContext,
    bool Function()? isCancelled,
  }) async {
    // 候选初筛阶段省略了沉重的 images 集合；仅对最终确认绑定的唯一优胜条目按需补全 ClearLogo 与高清背景图集。
    var effectiveDetail = detail;
    if (!detail.imagesLoaded) {
      try {
        final hydrated = await _tmdbService.getWorkDetail(
          detail.tmdbId,
          detail.mediaType,
          priority: RequestPriority.background,
          includeImages: true,
        );
        if (hydrated != null) {
          effectiveDetail = hydrated;
        }
      } catch (error) {
        developer.log(
          '补全优胜条目高清图集失败，沿用基础详情继续入库',
          name: 'konata.scrape_orchestrator',
          error: error,
        );
      }
    }

    if (effectiveDetail.collectionId != null &&
        effectiveDetail.collectionId! > 0) {
      _tmdbCollectionIdByTmdbId[effectiveDetail.tmdbId] =
          effectiveDetail.collectionId!;
    }
    final preRemap =
        (effectiveDetail.mediaType == TmdbMediaType.tv &&
            effectiveDetail.seasons.isNotEmpty)
        ? EpisodeRemapper.buildPlan(
            folder: folder,
            tmdbSeasons: effectiveDetail.seasons,
            matchedSeason: matchedSeason,
          )
        : null;
    final seasonsToFetch = <int>{
      ...ScrapeDomainAdapter.referencedSeasonsToFetch(
        folder,
        matchedSeason: matchedSeason,
        detail: effectiveDetail,
      ),
      if (preRemap != null) ...preRemap.referencedSeasons,
      ...seasons,
    };
    final bundle = await _candidateFetcher.fetchSeasonBundle(
      effectiveDetail.tmdbId,
      effectiveDetail.mediaType,
      seasonsToFetch,
    );
    final seasonDetail = matchedSeason != null
        ? bundle.seasonDetails[matchedSeason]
        : null;

    final fanartEnrich = await _artworkEnricher.enrichTmdbDetail(
      detail: effectiveDetail,
      seasonDetail: seasonDetail,
      matchedSeason: matchedSeason,
      bangumiCandidate: bangumiCandidate,
      priority: RequestPriority.background,
    );

    final candidateWork = ScrapeWorkPersister.buildMatchedWork(
      id: workId,
      detail: effectiveDetail,
      folder: folder,
      matchedSeason: matchedSeason,
      seasonDetail: seasonDetail,
      bangumiCandidate: bangumiCandidate,
      tvdbIdOverride: fanartEnrich.tvdbId,
      fanartPosterOverride: fanartEnrich.posterOverride,
      fanartPosterFallback: fanartEnrich.posterFallback,
      fanartBackdropOverride: fanartEnrich.backdropOverride,
      fanartPortraitBackdropOverride: fanartEnrich.portraitBackdropOverride,
      fanartLogoOverride: fanartEnrich.logoOverride,
      localPosterFallback: folder.localPosterPath,
      fallbackYear: folder.year,
      folderTmdbHint: folder.explicitTmdbId,
      isManualLocked: isManualLocked,
      logoNegativeMask: fanartEnrich.logoNegativeMask,
      isHidden: isHidden,
      keepHidden: keepHidden,
    );
    final work = ScrapeWorkPersister.mergeWorkWithLocks(
      existing: existing,
      candidate: candidateWork,
    );

    final effectiveBgmId = bangumiCandidate?.subject.id ?? existing?.bangumiId;
    final needBgmEpisodes =
        effectiveBgmId != null &&
        EpisodeRemapper.shouldFetchBangumiEpisodes(
          matchedSeason: matchedSeason,
          tmdbEpisodes: bundle.episodes,
          preRemap: preRemap,
        );
    final expectedMainCount = folder.mainEpisodeNumbers.toSet().length;
    final bangumiEpisodes = needBgmEpisodes
        ? (matchedSeason == 0
              ? await _candidateFetcher.fetchBangumiEpisodesForSeasonZero(
                  effectiveBgmId,
                  expectedMainCount: expectedMainCount > 0
                      ? expectedMainCount
                      : 1,
                  subjectHint: bangumiCandidate?.subject,
                  relationCache: _bangumiRelationCache,
                )
              : await _candidateFetcher.fetchBangumiEpisodes(
                  effectiveBgmId,
                  type: null,
                ))
        : const <BangumiEpisodeEntry>[];

    final remapPlan =
        (effectiveDetail.mediaType == TmdbMediaType.tv &&
            effectiveDetail.seasons.isNotEmpty)
        ? EpisodeRemapper.buildPlan(
            folder: folder,
            tmdbSeasons: effectiveDetail.seasons,
            matchedSeason: matchedSeason,
            tmdbEpisodes: bundle.episodes,
            bangumiEpisodes: bangumiEpisodes,
          )
        : preRemap;

    if (isCancelled?.call() ?? false) {
      return ScrapeStatus.unmatched;
    }

    Future<void> persist() async {
      await _repository.upsertWork(work);
      _logDecision(
        code: 'scraper.work.persisted',
        message: '作品落库完成：${work.title}',
        source: 'ScrapePipeline._bindAndPersistDetail',
        context: <String, Object?>{
          'workId': work.id,
          'tmdbId': work.tmdbId,
          'matchedSeason': work.matchedSeason,
          'status': work.scrapeStatus.name,
        },
      );
      _eventBus?.publish(
        LibraryWorkChangedEvent(
          workId: WorkId.trusted(work.id),
          reason: 'scraped',
          occurredAtMs: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      scanContext?.worksById[work.id] = work;
      await _photosStorage?.renameWorkFolderIfNeeded(work.id, work.title);
      await _repository.clearScrapeCandidates(workId);
      await _persister.syncEpisodesAndVariants(
        work: work,
        folder: folder,
        tmdbEpisodes: bundle.episodes,
        bangumiEpisodes: bangumiEpisodes,
        remapPlan: remapPlan,
        seasonName: seasonDetail?.name,
        preloadedSourceVariantsById: scanContext?.sourceVariantById,
      );
    }

    if (scanContext != null) {
      await scanContext.persistMutex.synchronized(persist);
    } else {
      await persist();
    }
    return ScrapeStatus.matched;
  }

  /// 判断仅命中 Bangumi 的未锁定作品是否属于可自愈的 TMDB 缺失降级态（此前因 TMDB 网络异常降级，或离线映射表明确存在对应 TMDB 条目）。
  static bool _needsTmdbUpgradeFromBangumiOnly(
    Work existing,
    BangumiTmdbIndex? mappingIndex,
  ) {
    if (existing.isManualLocked || existing.metadataLocked) return false;
    if (existing.tmdbId != null && existing.tmdbId! > 0) return false;
    final bgmId = existing.bangumiId;
    if (bgmId == null || bgmId <= 0) return false;
    if (existing.reviewReason != null &&
        existing.reviewReason!.trim().isNotEmpty) {
      return true;
    }
    return BangumiTmdbIndex.resolveTargets(
      bgmId,
      index: mappingIndex,
    ).isNotEmpty;
  }

  /// 判断已自动匹配的作品发生文件增删时是否可走零搜索增量剧集同步快通道。
  static bool _canUseIncrementalEpisodeFastPath({
    required Work existing,
    required GroupedWorkFolder folder,
    BangumiTmdbIndex? mappingIndex,
  }) {
    final hasIdentity =
        (existing.tmdbId != null && existing.tmdbMediaType != null) ||
        existing.bangumiId != null;
    if (!hasIdentity) return false;
    if (_needsTmdbUpgradeFromBangumiOnly(existing, mappingIndex)) {
      return false;
    }
    if (folder.explicitTmdbId != null &&
        folder.explicitTmdbId != existing.tmdbId) {
      return false;
    }
    if (folder.explicitBangumiId != null &&
        folder.explicitBangumiId != existing.bangumiId) {
      return false;
    }
    if (existing.tmdbId != null &&
        existing.tmdbMediaType == TmdbMediaType.tv &&
        existing.matchedSeason == null &&
        folder.seasonHint != null) {
      return false;
    }
    if ((existing.posterPath == null || existing.posterPath!.trim().isEmpty) &&
        folder.localPosterPath != null &&
        folder.localPosterPath!.trim().isNotEmpty) {
      return false;
    }
    return true;
  }

  static ({
    bool isSplit,
    bool canFastSkip,
    List<String> orderedWorkIds,
    Map<String, Work> ownersById,
    Map<int, String> workIdByBangumiId,
  })
  _inspectAlreadySplitSeasonZeroOwners({
    required GroupedWorkFolder folder,
    required _ScanBatchContext scanContext,
  }) {
    final ownersById = <String, Work>{};
    final orderedIds = <String>[];
    final workIdByBangumiId = <int, String>{};
    var allAssignedToSplitOwners = folder.variants.isNotEmpty;

    String signatureOf(MediaVariant v) {
      final subs = List<String>.of(v.externalSubtitles)..sort();
      return '${v.sourceId}\u0000${v.relativePath}\u0000${v.fileSize}\u0000'
          '${v.assetKind.index}\u0000${subs.join('\u0001')}';
    }

    var allSignaturesUnchanged = true;
    for (final v in folder.variants) {
      final ownerId = scanContext.workIdByRelPath[v.relativePath];
      final owner = ownerId != null ? scanContext.worksById[ownerId] : null;
      final isSeasonZeroMatched =
          owner != null &&
          owner.scrapeStatus == ScrapeStatus.matched &&
          owner.tmdbMediaType == TmdbMediaType.tv &&
          owner.matchedSeason == 0 &&
          (owner.bangumiId ?? 0) > 0;
      if (!isSeasonZeroMatched) {
        allAssignedToSplitOwners = false;
        allSignaturesUnchanged = false;
        continue;
      }
      if (!ownersById.containsKey(owner.id)) {
        ownersById[owner.id] = owner;
        orderedIds.add(owner.id);
      }
      workIdByBangumiId.putIfAbsent(owner.bangumiId!, () => owner.id);
      final vId = ScrapeWorkPersister.deterministicId(
        '${v.sourceId}::${v.relativePath}',
      );
      final existingVariant = scanContext.sourceVariantById[vId];
      if (existingVariant == null ||
          existingVariant.workId != owner.id ||
          signatureOf(existingVariant) != signatureOf(v)) {
        allSignaturesUnchanged = false;
      }
    }

    final isSplit = ownersById.length >= 2 && workIdByBangumiId.length >= 2;
    return (
      isSplit: isSplit,
      canFastSkip:
          isSplit && allAssignedToSplitOwners && allSignaturesUnchanged,
      orderedWorkIds: orderedIds,
      ownersById: ownersById,
      workIdByBangumiId: workIdByBangumiId,
    );
  }

  /// 判断已成功匹配的作品在增量重扫时其未锁定文件集是否完全未变化，允许零网络请求直接快跳。
  ///
  /// 当同一作品已由同父目录多个压制组子目录归并时，按当前文件夹物理目录前缀隔离比对，
  /// 确保单目录新增追番集数/分卷必被精准感知，同时已归并的无变更子目录亦能零请求快跳。
  static bool _canFastSkipUnchangedMatchedWork({
    required Work existing,
    required GroupedWorkFolder folder,
    required List<MediaVariant> existingUnlockedVariants,
    BangumiTmdbIndex? mappingIndex,
  }) {
    if (existingUnlockedVariants.isEmpty) {
      return false;
    }
    if (_needsTmdbUpgradeFromBangumiOnly(existing, mappingIndex)) {
      return false;
    }
    var scopedExisting = existingUnlockedVariants;
    if (existingUnlockedVariants.length > folder.variants.length) {
      // 归并后的多目录/多拆簇作品按当前物理根目录前缀切片比对：
      // 同一物理根目录下若存在其他兄弟拆簇，其变体已隶属各自独立 workId，不会混入当前 existing 的变体集。
      final rawRoot = (folder.physicalRootFolder ?? folder.folderRelativePath)
          .trim()
          .replaceAll('\\', '/');
      if (rawRoot.isNotEmpty) {
        final prefix = '$rawRoot/';
        final inFolder = existingUnlockedVariants
            .where(
              (v) => v.relativePath.replaceAll('\\', '/').startsWith(prefix),
            )
            .toList(growable: false);
        if (inFolder.length == folder.variants.length) {
          scopedExisting = inFolder;
        }
      }
    }
    if (scopedExisting.length != folder.variants.length) {
      return false;
    }
    if (folder.explicitTmdbId != null &&
        folder.explicitTmdbId != existing.tmdbId) {
      return false;
    }
    if (existing.tmdbId != null &&
        existing.tmdbMediaType == TmdbMediaType.tv &&
        existing.matchedSeason == null &&
        folder.seasonHint != null) {
      return false;
    }
    if ((existing.posterPath == null || existing.posterPath!.trim().isEmpty) &&
        folder.localPosterPath != null &&
        folder.localPosterPath!.trim().isNotEmpty) {
      return false;
    }

    String signatureOf(MediaVariant v) {
      final subs = List<String>.of(v.externalSubtitles)..sort();
      return '${v.sourceId}\u0000${v.relativePath}\u0000${v.fileSize}\u0000'
          '${v.assetKind.index}\u0000${subs.join('\u0001')}';
    }

    final existingSigs = {for (final v in scopedExisting) signatureOf(v)};
    if (existingSigs.length != scopedExisting.length) {
      return false;
    }
    for (final v in folder.variants) {
      if (!existingSigs.contains(signatureOf(v))) {
        return false;
      }
    }
    return true;
  }

  Set<int> _extractReferencedSeasons(GroupedWorkFolder folder) =>
      ScrapeDomainAdapter.referencedSeasonsToFetch(folder);

  /// 人工纠错或元数据刷新：重绑定或刷新指定 TMDB 条目（同步刷新已绑定的 Bangumi 与 Fanart.tv 等已用源，未显式重置时严格保护已锁定字段与文件映射）。
  Future<Work> rebindWorkToTmdb(
    String workId,
    int tmdbId,
    TmdbMediaType mediaType, {
    bool writeIdToFolderName = false,
    bool resetManualLocks = false,
    bool markManualLocked = true,
    bool clearManualLockIfNoFieldLock = false,
    int? matchedSeasonOverride,
    bool forceRefreshArtwork = false,
    WorkRescrapeProgressListener? onProgress,
  }) async {
    void reportStep(int step, String label, {String? detail}) {
      onProgress?.call(
        WorkRescrapeProgress(
          workId: workId,
          stageLabel: label,
          stepIndex: step,
          totalSteps: 6,
          detailText: detail,
        ),
      );
    }

    final existing = await _repository.findWorkById(workId);
    if (existing == null) {
      throw StateError('作品不存在: $workId');
    }

    reportStep(2, '正在拉取 TMDB 与 Bangumi 详情...');
    final detail = await _tmdbService.getWorkDetail(
      tmdbId,
      mediaType,
      priority: RequestPriority.interactive,
    );
    if (detail == null) {
      throw StateError('无法获取 TMDB 条目详情: $tmdbId');
    }

    var variants = await _repository.getVariantsByWork(workId);
    if (writeIdToFolderName && variants.isNotEmpty) {
      variants = await _persister.tryAppendTmdbIdToLocalFolder(
        variants,
        tmdbId,
      );
    }

    final targetFolder = await _rebuildFolderFromVariants(
      variants,
      existing: existing,
    );

    // 同一 TMDB 条目交互刷新或由无背景孤岛电影升级母剧特别篇时，直接拉取已绑定 Bangumi 最新详情以同步最新评分、简介、封面与标题。
    final sameTmdbRefresh =
        existing.tmdbId == tmdbId &&
        existing.tmdbMediaType == mediaType &&
        !resetManualLocks;
    final preserveExistingBangumi =
        sameTmdbRefresh || (matchedSeasonOverride != null && !resetManualLocks);
    BangumiSubjectCandidate? existingBgmDetail;
    if (_bangumiService != null &&
        existing.bangumiId != null &&
        preserveExistingBangumi) {
      try {
        existingBgmDetail = await _bangumiService.getSubjectDetail(
          existing.bangumiId!,
          priority: RequestPriority.interactive,
        );
      } catch (error) {
        developer.log(
          '刷新既有 Bangumi 详情失败，回退常规候选匹配',
          name: 'konata.scrape_orchestrator',
          error: error,
        );
      }
    }

    if (targetFolder != null) {
      final searchedBgm = _bangumiService == null
          ? const <BangumiSubjectCandidate>[]
          : await _interactiveCandidateFetcher.fetchBangumiCandidates(
              targetFolder,
              extraQueries: [detail.title, ...detail.aliases.take(2)],
            );
      final bgmById = <int, BangumiSubjectCandidate>{
        for (final c in searchedBgm) c.id: c,
      };
      if (existingBgmDetail != null) {
        bgmById[existingBgmDetail.id] = existingBgmDetail;
      }
      final bgmRescue = bgmById.values.toList(growable: false);
      final matchDecision = await _computeWorker.evaluateMatch(
        targetFolder,
        [detail],
        bangumiCandidates: bgmRescue,
        mappingIndex: _mappingIndex,
      );
      final effectiveBangumi =
          (preserveExistingBangumi && existingBgmDetail != null)
          ? (matchDecision.bestBangumi?.subject.id == existingBgmDetail.id
                ? ScoredBangumiCandidate(
                    subject: existingBgmDetail,
                    score: matchDecision.bestBangumi!.score,
                    reasons: matchDecision.bestBangumi!.reasons,
                  )
                : ScoredBangumiCandidate(
                    subject: existingBgmDetail,
                    score: 100.0,
                    reasons: const ['existing_bangumi_refresh'],
                  ))
          : matchDecision.bestBangumi;
      final matchedSeason =
          matchedSeasonOverride ??
          matchDecision.matchedSeason ??
          targetFolder.seasonHint ??
          ScrapeDomainAdapter.fallbackResolveSeason(
            folder: targetFolder,
            detail: detail,
          ) ??
          existing.matchedSeason;

      // 交互重抓/刷新 Season 0 多部独立 1 话特别篇合集（如加速世界 EX1+EX2）时，原地拆分为独立作品。
      if (matchedSeason == 0 &&
          detail.mediaType == TmdbMediaType.tv &&
          effectiveBangumi != null &&
          _bangumiService != null &&
          variants.isNotEmpty) {
        final splitSlices = await SeasonZeroWorkSplitter.tryPlanSplit(
          sourceId: variants.first.sourceId,
          primaryWorkId: existing.id,
          folder: targetFolder,
          detail: detail,
          matchedSeason: 0,
          bangumiCandidate: effectiveBangumi,
          bangumiService: _bangumiService,
          knownBangumiCandidates: bgmRescue,
          mappingIndex: _mappingIndex,
          relationCache: _bangumiRelationCache,
          existingWorkIdByBangumiId: {
            if ((existing.bangumiId ?? 0) > 0) existing.bangumiId!: existing.id,
          },
          priority: RequestPriority.interactive,
        );
        if (splitSlices != null && splitSlices.length >= 2) {
          reportStep(
            3,
            '正在拉取特别篇分集清单与剧照...',
            detail: '识别到 ${splitSlices.length} 部独立特别篇',
          );
          final bundle = await _interactiveCandidateFetcher.fetchSeasonBundle(
            detail.tmdbId,
            detail.mediaType,
            const {0},
          );
          final seasonDetail = bundle.seasonDetails[0];
          final hasFieldLock =
              existing.metadataLocked ||
              existing.posterLocked ||
              existing.backdropLocked ||
              existing.logoLocked;
          final nextManualLocked = markManualLocked
              ? true
              : (clearManualLockIfNoFieldLock && !hasFieldLock
                    ? false
                    : existing.isManualLocked);
          Work? primaryUpdated;
          final focusWorkIds = <String>{existing.id};
          final focusBangumiIds = <int>{};
          for (var sliceIdx = 0; sliceIdx < splitSlices.length; sliceIdx++) {
            final slice = splitSlices[sliceIdx];
            reportStep(
              4,
              '正在拆分并同步独立特别篇...',
              detail:
                  '第 ${sliceIdx + 1}/${splitSlices.length} 部 · ${slice.bangumiCandidate.subject.displayTitle}',
            );
            final sliceExisting = slice.workId == existing.id
                ? existing
                : await _repository.findWorkById(slice.workId);
            final sliceEnrich = await _artworkEnricher.enrichTmdbDetail(
              detail: detail,
              seasonDetail: seasonDetail,
              matchedSeason: 0,
              bangumiCandidate: slice.bangumiCandidate,
              priority: RequestPriority.interactive,
              forceRefresh: forceRefreshArtwork,
            );
            final sliceBuilt = ScrapeWorkPersister.buildMatchedWork(
              id: slice.workId,
              detail: detail,
              folder: slice.folder,
              matchedSeason: 0,
              seasonDetail: seasonDetail,
              bangumiCandidate: slice.bangumiCandidate,
              tvdbIdOverride: sliceEnrich.tvdbId,
              fanartPosterOverride: sliceEnrich.posterOverride,
              fanartPosterFallback: sliceEnrich.posterFallback,
              fanartBackdropOverride: sliceEnrich.backdropOverride,
              fanartPortraitBackdropOverride:
                  sliceEnrich.portraitBackdropOverride,
              fanartLogoOverride: sliceEnrich.logoOverride,
              fallbackYear:
                  slice.bangumiCandidate.subject.year ?? existing.year,
              folderTmdbHint: tmdbId,
              isManualLocked: slice.workId == existing.id
                  ? nextManualLocked
                  : false,
              logoNegativeMask: sliceEnrich.logoNegativeMask,
              isHidden: sliceExisting?.isHidden ?? existing.isHidden,
              keepHidden: sliceExisting?.keepHidden ?? existing.keepHidden,
            );
            final sliceUpdated = ScrapeWorkPersister.mergeWorkWithLocks(
              existing: sliceExisting,
              candidate: sliceBuilt,
              resetManualLocks: resetManualLocks,
            );
            await _repository.upsertWork(sliceUpdated);
            await _photosStorage?.renameWorkFolderIfNeeded(
              sliceUpdated.id,
              sliceUpdated.title,
            );
            await _repository.clearScrapeCandidates(sliceUpdated.id);
            final sliceBgmId = sliceUpdated.bangumiId;
            final sliceBgmEpisodes = sliceBgmId == null
                ? const <BangumiEpisodeEntry>[]
                : await _interactiveCandidateFetcher
                      .fetchBangumiEpisodesForSeasonZero(
                        sliceBgmId,
                        expectedMainCount: 1,
                        subjectHint: slice.bangumiCandidate.subject,
                        relationCache: _bangumiRelationCache,
                      );
            await _persister.syncEpisodesAndVariants(
              work: sliceUpdated,
              folder: slice.folder,
              tmdbEpisodes: bundle.episodes,
              bangumiEpisodes: sliceBgmEpisodes,
              seasonName: seasonDetail?.name,
              resetManualLocks: resetManualLocks,
            );
            focusWorkIds.add(sliceUpdated.id);
            if (sliceBgmId != null && sliceBgmId > 0) {
              focusBangumiIds.add(sliceBgmId);
            }
            if (sliceUpdated.id == existing.id) {
              primaryUpdated = sliceUpdated;
            }
          }
          await _repository.deleteOrphanEpisodes(existing.id);
          if (detail.collectionId != null && detail.collectionId! > 0) {
            _tmdbCollectionIdByTmdbId[detail.tmdbId] = detail.collectionId!;
          }
          reportStep(6, '正在整理系列归组与刷新缓存...');
          await SeriesAutoLinker.reconcileAll(
            repository: _repository,
            bangumiService: _bangumiService,
            tmdbService: _tmdbService,
            tmdbCollectionIdByTmdbId: _tmdbCollectionIdByTmdbId,
            focusBangumiIds: focusBangumiIds,
            focusWorkIds: focusWorkIds,
            relationCache: _bangumiRelationCache,
          );
          return (await _repository.findWorkById(workId)) ??
              primaryUpdated ??
              existing;
        }
      }
      final preRemap =
          (detail.mediaType == TmdbMediaType.tv && detail.seasons.isNotEmpty)
          ? EpisodeRemapper.buildPlan(
              folder: targetFolder,
              tmdbSeasons: detail.seasons,
              matchedSeason: matchedSeason,
            )
          : null;
      final existingEpisodes = await _repository.getEpisodesByWork(workId);
      final seasonsToFetch = <int>{
        ...ScrapeDomainAdapter.referencedSeasonsToFetch(
          targetFolder,
          matchedSeason: matchedSeason,
          detail: detail,
        ),
        if (preRemap != null) ...preRemap.referencedSeasons,
        for (final ep in existingEpisodes) ep.seasonNumber,
      };
      reportStep(3, '正在拉取分集清单与官方剧照...');
      final bundle = await _interactiveCandidateFetcher.fetchSeasonBundle(
        detail.tmdbId,
        detail.mediaType,
        seasonsToFetch,
      );
      final seasonDetail = matchedSeason != null
          ? bundle.seasonDetails[matchedSeason]
          : null;

      reportStep(4, '正在获取高清封面与透明标题...');
      final fanartEnrich = await _artworkEnricher.enrichTmdbDetail(
        detail: detail,
        seasonDetail: seasonDetail,
        matchedSeason: matchedSeason,
        bangumiCandidate: effectiveBangumi,
        priority: RequestPriority.interactive,
        forceRefresh: forceRefreshArtwork,
      );

      final hasFieldLock =
          existing.metadataLocked ||
          existing.posterLocked ||
          existing.backdropLocked ||
          existing.logoLocked;
      final nextManualLocked = markManualLocked
          ? true
          : (clearManualLockIfNoFieldLock && !hasFieldLock
                ? false
                : existing.isManualLocked);
      final built = ScrapeWorkPersister.buildMatchedWork(
        id: existing.id,
        detail: detail,
        folder: targetFolder,
        matchedSeason: matchedSeason,
        seasonDetail: seasonDetail,
        bangumiCandidate: effectiveBangumi,
        tvdbIdOverride: fanartEnrich.tvdbId,
        fanartPosterOverride: fanartEnrich.posterOverride,
        fanartPosterFallback: fanartEnrich.posterFallback,
        fanartBackdropOverride: fanartEnrich.backdropOverride,
        fanartPortraitBackdropOverride: fanartEnrich.portraitBackdropOverride,
        fanartLogoOverride: fanartEnrich.logoOverride,
        fallbackYear: existing.year,
        folderTmdbHint: tmdbId,
        isManualLocked: nextManualLocked,
        logoNegativeMask: fanartEnrich.logoNegativeMask,
        isHidden: existing.isHidden,
        keepHidden: existing.keepHidden,
      );
      var updated = ScrapeWorkPersister.mergeWorkWithLocks(
        existing: existing,
        candidate: built,
        resetManualLocks: resetManualLocks,
      );
      if (_bangumiService != null &&
          updated.bangumiId != null &&
          (updated.bangumiScore == null || updated.bangumiScore! <= 0)) {
        try {
          final bgmDetail = await _bangumiService.getSubjectDetail(
            updated.bangumiId!,
            priority: RequestPriority.interactive,
          );
          if (bgmDetail != null &&
              bgmDetail.score != null &&
              bgmDetail.score! > 0) {
            updated = updated.copyWith(
              bangumiScore: bgmDetail.score,
              bangumiPosterPath:
                  updated.bangumiPosterPath ?? bgmDetail.posterUrl,
            );
          }
        } catch (error) {
          // Bangumi 评分补全失败不阻断 TMDB 重绑定流程。
          developer.log(
            '可恢复异常已记录',
            name: 'konata.scrape_orchestrator',
            error: error,
          );
        }
      }
      await _repository.upsertWork(updated);
      await _photosStorage?.renameWorkFolderIfNeeded(updated.id, updated.title);
      await _repository.clearScrapeCandidates(workId);

      final effectiveBgmId = updated.bangumiId;
      final needBgmEpisodes =
          effectiveBgmId != null &&
          EpisodeRemapper.shouldFetchBangumiEpisodes(
            matchedSeason: matchedSeason,
            tmdbEpisodes: bundle.episodes,
            preRemap: preRemap,
          );
      final expectedMainCount = targetFolder.mainEpisodeNumbers.toSet().length;
      final bgmEpisodes = needBgmEpisodes
          ? (matchedSeason == 0
                ? await _interactiveCandidateFetcher
                      .fetchBangumiEpisodesForSeasonZero(
                        effectiveBgmId,
                        expectedMainCount: expectedMainCount > 0
                            ? expectedMainCount
                            : 1,
                        subjectHint: effectiveBangumi?.subject,
                        relationCache: _bangumiRelationCache,
                      )
                : await _interactiveCandidateFetcher.fetchBangumiEpisodes(
                    effectiveBgmId,
                    type: null,
                  ))
          : const <BangumiEpisodeEntry>[];
      final remapPlan =
          (detail.mediaType == TmdbMediaType.tv && detail.seasons.isNotEmpty)
          ? EpisodeRemapper.buildPlan(
              folder: targetFolder,
              tmdbSeasons: detail.seasons,
              matchedSeason: matchedSeason,
              tmdbEpisodes: bundle.episodes,
              bangumiEpisodes: bgmEpisodes,
            )
          : preRemap;

      reportStep(5, '正在同步剧集与多版本映射...');
      await _persister.syncEpisodesAndVariants(
        work: updated,
        folder: targetFolder,
        tmdbEpisodes: bundle.episodes,
        bangumiEpisodes: bgmEpisodes,
        remapPlan: remapPlan,
        seasonName: seasonDetail?.name,
        resetManualLocks: resetManualLocks,
      );
      if (detail.collectionId != null && detail.collectionId! > 0) {
        _tmdbCollectionIdByTmdbId[detail.tmdbId] = detail.collectionId!;
      }
      reportStep(6, '正在整理系列归组与刷新缓存...');
      await SeriesAutoLinker.reconcileAll(
        repository: _repository,
        bangumiService: _bangumiService,
        tmdbService: _tmdbService,
        tmdbCollectionIdByTmdbId: _tmdbCollectionIdByTmdbId,
        focusBangumiIds: {if ((updated.bangumiId ?? 0) > 0) updated.bangumiId!},
        focusWorkIds: {updated.id},
        relationCache: _bangumiRelationCache,
      );
      return updated;
    }

    final fallbackBgmCandidate = existingBgmDetail == null
        ? null
        : ScoredBangumiCandidate(
            subject: existingBgmDetail,
            score: 100.0,
            reasons: const ['existing_bangumi_refresh'],
          );
    final fanartFallback = await _artworkEnricher.enrichTmdbDetail(
      detail: detail,
      seasonDetail: null,
      matchedSeason: existing.matchedSeason,
      bangumiCandidate: fallbackBgmCandidate,
      priority: RequestPriority.interactive,
      forceRefresh: forceRefreshArtwork,
    );
    final fallbackHasFieldLock =
        existing.metadataLocked ||
        existing.posterLocked ||
        existing.backdropLocked ||
        existing.logoLocked;
    final fallbackManualLocked = markManualLocked
        ? true
        : (clearManualLockIfNoFieldLock && !fallbackHasFieldLock
              ? false
              : existing.isManualLocked);
    final builtFallback = ScrapeWorkPersister.buildMatchedWork(
      id: existing.id,
      detail: detail,
      matchedSeason: matchedSeasonOverride ?? existing.matchedSeason,
      bangumiCandidate: fallbackBgmCandidate,
      tvdbIdOverride: fanartFallback.tvdbId,
      fanartPosterOverride: fanartFallback.posterOverride,
      fanartPosterFallback: fanartFallback.posterFallback,
      fanartBackdropOverride: fanartFallback.backdropOverride,
      fanartPortraitBackdropOverride: fanartFallback.portraitBackdropOverride,
      fanartLogoOverride: fanartFallback.logoOverride,
      fallbackYear: existing.year,
      folderTmdbHint: tmdbId,
      isManualLocked: fallbackManualLocked,
      logoNegativeMask: fanartFallback.logoNegativeMask,
      isHidden: existing.isHidden,
      keepHidden: existing.keepHidden,
    );
    final updated = ScrapeWorkPersister.mergeWorkWithLocks(
      existing: existing,
      candidate: builtFallback,
      resetManualLocks: resetManualLocks,
    );
    await _repository.upsertWork(updated);
    await _photosStorage?.renameWorkFolderIfNeeded(updated.id, updated.title);
    await _repository.clearScrapeCandidates(workId);
    if (detail.collectionId != null && detail.collectionId! > 0) {
      _tmdbCollectionIdByTmdbId[detail.tmdbId] = detail.collectionId!;
    }
    await SeriesAutoLinker.reconcileAll(
      repository: _repository,
      bangumiService: _bangumiService,
      tmdbService: _tmdbService,
      tmdbCollectionIdByTmdbId: _tmdbCollectionIdByTmdbId,
      focusBangumiIds: {if ((updated.bangumiId ?? 0) > 0) updated.bangumiId!},
      focusWorkIds: {updated.id},
      relationCache: _bangumiRelationCache,
    );
    return updated;
  }

  /// 为已绑定 TMDB 的 TV 剧集静默补拉缺失的官方单集剧照与单集标题（严防扫描期单季超时后永久误落入本地抽帧）。
  Future<bool> _backfillMissingTmdbEpisodeStills(Work work) async {
    final tmdbId = work.tmdbId;
    if (tmdbId == null ||
        tmdbId <= 0 ||
        work.tmdbMediaType != TmdbMediaType.tv ||
        work.matchedSeason == 0) {
      return false;
    }
    final episodes = await _repository.getEpisodesByWork(work.id);
    if (episodes.isEmpty) return false;

    final missingSeasons = <int>{};
    for (final ep in episodes) {
      if (ep.category != EpisodeCategory.main) continue;
      if (ep.episodeNumber == null || ep.episodeNumber! <= 0) continue;
      final targetSeason = ep.seasonNumber > 0
          ? ep.seasonNumber
          : (work.matchedSeason != null && work.matchedSeason! > 0
                ? work.matchedSeason!
                : 0);
      if (targetSeason <= 0) continue;
      final still = ep.stillPath?.trim() ?? '';
      final needsStill =
          still.isEmpty ||
          ScrapeWorkPersister.isAutoExtractedLocalStillPath(still);
      final needsTitle = EpisodeTitleFormatter.isGenericEpisodePlaceholder(
        ep.title ?? '',
      );
      if (needsStill || needsTitle) {
        missingSeasons.add(targetSeason);
      }
    }
    if (missingSeasons.isEmpty) return false;

    final bundle = await _candidateFetcher.fetchSeasonBundle(
      tmdbId,
      TmdbMediaType.tv,
      missingSeasons,
    );
    if (bundle.episodes.isEmpty) return false;

    final tmdbByKey = <String, TmdbEpisodeDetail>{
      for (final e in bundle.episodes)
        '${e.seasonNumber}:${e.episodeNumber}': e,
    };
    final toUpsert = <Episode>[];
    final staleAutoStills = <String>[];
    for (final ep in episodes) {
      if (ep.category != EpisodeCategory.main) continue;
      if (ep.episodeNumber == null || ep.episodeNumber! <= 0) continue;
      final lookupSeason = ep.seasonNumber > 0
          ? ep.seasonNumber
          : (work.matchedSeason != null && work.matchedSeason! > 0
                ? work.matchedSeason!
                : 0);
      if (lookupSeason <= 0) continue;
      final tmdbEp = tmdbByKey['$lookupSeason:${ep.episodeNumber}'];
      if (tmdbEp == null) continue;

      final currentStill = ep.stillPath?.trim() ?? '';
      final tmdbStill = tmdbEp.stillPath?.trim() ?? '';
      final upgradeStill =
          tmdbStill.isNotEmpty &&
          (currentStill.isEmpty ||
              ScrapeWorkPersister.isAutoExtractedLocalStillPath(currentStill));
      final tmdbTitle = tmdbEp.title.trim();
      final upgradeTitle =
          tmdbTitle.isNotEmpty &&
          EpisodeTitleFormatter.isGenericEpisodePlaceholder(ep.title ?? '');
      final tmdbOverview = tmdbEp.overview?.trim() ?? '';
      final upgradeOverview =
          tmdbOverview.isNotEmpty && (ep.overview?.trim().isEmpty ?? true);
      if (!upgradeStill && !upgradeTitle && !upgradeOverview) continue;

      if (upgradeStill &&
          currentStill.isNotEmpty &&
          ScrapeWorkPersister.isAutoExtractedLocalStillPath(currentStill)) {
        staleAutoStills.add(currentStill);
      }
      toUpsert.add(
        ep.copyWith(
          stillPath: upgradeStill ? tmdbStill : ep.stillPath,
          title: upgradeTitle ? tmdbTitle : ep.title,
          overview: upgradeOverview ? tmdbOverview : ep.overview,
        ),
      );
    }
    if (toUpsert.isEmpty) return false;

    await _repository.upsertEpisodesBatch(toUpsert);
    for (final stale in staleAutoStills) {
      try {
        final f = File(stale);
        if (f.existsSync()) {
          f.deleteSync();
        }
      } catch (error) {
        developer.log(
          '清理已被官方剧照替代的抽帧缓存失败已忽略',
          name: 'konata.scrape_orchestrator',
          error: error,
        );
      }
    }
    return true;
  }

  /// 详情页进入自动补全或点击重新抓取：为缺 `tmdbId`、`logoPath` 或无字横版背景的条目自动补绑并回填。
  Future<Work?> autoBindOrBackfillWorkTmdb(
    String workId, {
    bool interactive = false,
    WorkRescrapeProgressListener? onProgress,
  }) async {
    void reportStep(int step, String label, {String? detail}) {
      onProgress?.call(
        WorkRescrapeProgress(
          workId: workId,
          stageLabel: label,
          stepIndex: step,
          totalSteps: 6,
          detailText: detail,
        ),
      );
    }

    final existing = await _repository.findWorkById(workId);
    if (existing == null) return null;

    if (existing.tmdbId != null && existing.tmdbMediaType != null) {
      if (interactive) {
        // 已绑定到缺横版背景图的电影条目且存在 Bangumi ID 时，交互重新抓取先尝试重评：
        // 若可升级回带横版背景的母剧 TV 特别篇（Season 0，如《少女福尔摩斯 派对之夜》），自动原位纠偏并清除历史误加锁。
        var targetTmdbId = existing.tmdbId!;
        var targetMediaType = existing.tmdbMediaType!;
        var upgradedFromOrphanMovie = false;
        if (!existing.metadataLocked &&
            existing.tmdbMediaType == TmdbMediaType.movie &&
            (existing.backdropPath?.trim().isEmpty ?? true) &&
            existing.bangumiId != null) {
          reportStep(1, '正在复核作品匹配关系...');
          try {
            final variants = await _repository.getVariantsByWork(workId);
            final folder = await _rebuildFolderFromVariants(
              variants,
              existing: existing,
            );
            if (folder != null && folder.explicitTmdbId == null) {
              final resolved = await _interactiveMatchResolver.resolve(folder);
              final best = resolved.decision.best;
              if (resolved.decision.level == MatchLevel.autoBind &&
                  best != null &&
                  best.detail.mediaType == TmdbMediaType.tv &&
                  resolved.decision.matchedSeason == 0 &&
                  (best.detail.backdropPath?.trim().isNotEmpty ?? false)) {
                targetTmdbId = best.detail.tmdbId;
                targetMediaType = TmdbMediaType.tv;
                upgradedFromOrphanMovie = true;
              }
            }
          } catch (error) {
            developer.log(
              '交互重抓检查孤岛电影升级母剧特别篇失败，回退常规刷新',
              name: 'konata.scrape_orchestrator',
              error: error,
            );
          }
        }

        Work? rebound;
        Object? tmdbError;
        try {
          rebound = await rebindWorkToTmdb(
            workId,
            targetTmdbId,
            targetMediaType,
            markManualLocked: false,
            clearManualLockIfNoFieldLock: upgradedFromOrphanMovie,
            matchedSeasonOverride: upgradedFromOrphanMovie ? 0 : null,
            forceRefreshArtwork: true,
            onProgress: onProgress,
          );
        } catch (error) {
          tmdbError = error;
          developer.log(
            '交互刷新 TMDB 失败，尝试继续刷新 Bangumi 与 Fanart.tv 等已用源',
            name: 'konata.scrape_orchestrator',
            error: error,
          );
        }
        if (rebound == null) {
          BangumiSubjectCandidate? refreshedBgm;
          if (_bangumiService != null && existing.bangumiId != null) {
            try {
              refreshedBgm = await _bangumiService.getSubjectDetail(
                existing.bangumiId!,
                priority: RequestPriority.interactive,
              );
            } catch (error) {
              developer.log(
                '回退刷新 Bangumi 详情失败',
                name: 'konata.scrape_orchestrator',
                error: error,
              );
            }
          }
          final hasFallbackSource =
              refreshedBgm != null ||
              existing.tvdbId != null ||
              ScrapeArtworkEnricher.lookupOfflineTvdbId(
                    mappingIndex: _mappingIndex,
                    bangumiId: existing.bangumiId,
                    tmdbId: existing.tmdbId,
                    mediaType: existing.tmdbMediaType,
                  ) !=
                  null ||
              (_fanartService?.isConfigured ?? false);
          if (!hasFallbackSource && tmdbError != null) {
            Error.throwWithStackTrace(tmdbError, StackTrace.current);
          }
          final fallbackVariants = await _repository.getVariantsByWork(workId);
          final fallbackFolder = await _rebuildFolderFromVariants(
            fallbackVariants,
          );
          return _refreshNonTmdbWork(
            existing,
            bgmSubject: refreshedBgm,
            folder: fallbackFolder,
            interactive: true,
            onProgress: onProgress,
          );
        }
        final hasSeasonMismatchLogo = ClearLogoRanker.isKnownSeasonMismatchLogo(
          filePath: rebound.logoPath,
          matchedSeason: rebound.matchedSeason,
          tmdbId: rebound.tmdbId,
          tvdbId: rebound.tvdbId,
          mediaType: rebound.tmdbMediaType,
        );
        final needsInteractiveLogoOrArt =
            _clearLogoResolver != null &&
            ((!rebound.logoLocked &&
                    (rebound.logoPath == null ||
                        rebound.logoPath!.trim().isEmpty ||
                        rebound.logoPath!.trim().startsWith('/') ||
                        hasSeasonMismatchLogo)) ||
                (!rebound.backdropLocked &&
                    (rebound.backdropPath == null ||
                        rebound.backdropPath!.trim().isEmpty)) ||
                (!rebound.posterLocked &&
                    (rebound.posterPath == null ||
                        rebound.posterPath!.trim().isEmpty)));
        if (needsInteractiveLogoOrArt) {
          reportStep(6, '正在核验透明标题与高清背景...');
          final outcome = await _clearLogoResolver.resolveForWork(
            rebound,
            forceRefresh: true,
            allowUpgradeExisting: true,
            upgradeBackdropIfSuboptimal: true,
            fillPosterIfMissing: true,
            priority: RequestPriority.interactive,
          );
          final nextLogo = rebound.logoLocked
              ? rebound.logoPath
              : (outcome.logoPath ?? rebound.logoPath);
          final nextBackdrop = rebound.backdropLocked
              ? rebound.backdropPath
              : (outcome.upgradedBackdropPath ?? rebound.backdropPath);
          final nextPoster = rebound.posterLocked
              ? rebound.posterPath
              : ((rebound.posterPath == null ||
                        rebound.posterPath!.trim().isEmpty)
                    ? (outcome.fallbackPosterPath ?? rebound.posterPath)
                    : rebound.posterPath);
          final clearNeg =
              nextLogo != null &&
              nextLogo.trim().isNotEmpty &&
              outcome.negativeMask == 0;
          rebound = rebound.copyWith(
            logoPath: nextLogo,
            backdropPath: nextBackdrop,
            posterPath: nextPoster,
            tvdbId: outcome.resolvedTvdbId ?? rebound.tvdbId,
            clearLogoNegative: clearNeg,
            logoNegativeUntil: outcome.negativeUntil,
            logoNegativeMask: outcome.negativeMask,
          );
          await _repository.upsertWork(rebound);
        }
        return rebound;
      }

      final missingLogo =
          !existing.logoLocked &&
          (existing.logoPath == null || existing.logoPath!.trim().isEmpty);
      final hasSeasonMismatchLogo =
          !existing.logoLocked &&
          ClearLogoRanker.isKnownSeasonMismatchLogo(
            filePath: existing.logoPath,
            matchedSeason: existing.matchedSeason,
            tmdbId: existing.tmdbId,
            tvdbId: existing.tvdbId,
            mediaType: existing.tmdbMediaType,
          );
      final canUpgradeLogo =
          !existing.logoLocked &&
          _clearLogoResolver != null &&
          (hasSeasonMismatchLogo ||
              (existing.logoPath != null &&
                  existing.logoPath!.trim().startsWith('/') &&
                  (existing.logoNegativeMask &
                          ClearLogoNegativeMask.multiSourceUpgraded) ==
                      0));
      final missingBackdrop =
          !existing.backdropLocked &&
          (existing.backdropPath == null ||
              existing.backdropPath!.trim().isEmpty);
      final missingPoster =
          !existing.posterLocked &&
          (existing.posterPath == null || existing.posterPath!.trim().isEmpty);

      // 严守「TMDB 官方分集剧照优先于本地抽帧」：
      // 已绑定 TMDB 的剧集若存在缺失官方剧照或占位集名的正片集（如扫描期季详情瞬时超时所致），
      // 进入详情页时先静默按季补拉 TMDB 官方分集元数据，并自动清理被官方剧照替换的本地抽帧文件。
      if (existing.tmdbMediaType == TmdbMediaType.tv) {
        await _backfillMissingTmdbEpisodeStills(existing);
      }

      if (!missingLogo &&
          !canUpgradeLogo &&
          !missingBackdrop &&
          !missingPoster) {
        return existing;
      }

      TmdbWorkDetail? detail;
      try {
        detail = await _tmdbService.getWorkDetail(
          existing.tmdbId!,
          existing.tmdbMediaType!,
          priority: RequestPriority.background,
          includeImages: true,
        );
      } catch (error) {
        developer.log(
          '后台拉取 TMDB 详情失败，继续尝试 Fanart 艺术图补全',
          name: 'konata.scrape_orchestrator',
          error: error,
        );
      }

      if (_clearLogoResolver != null) {
        final outcome = await _clearLogoResolver.resolveForWork(
          existing,
          preloadedTmdbDetail: detail,
          skipTmdb: detail == null,
          allowUpgradeExisting: canUpgradeLogo,
          upgradeBackdropIfSuboptimal: !existing.backdropLocked,
          fillPosterIfMissing: missingPoster,
          priority: RequestPriority.background,
        );
        final nextLogo = existing.logoLocked
            ? existing.logoPath
            : (outcome.logoPath ?? existing.logoPath);
        final nextTvdb =
            outcome.resolvedTvdbId ?? detail?.tvdbId ?? existing.tvdbId;
        final canUpgradeRemoteBackdrop =
            !existing.backdropLocked &&
            (missingBackdrop ||
                (missingLogo &&
                    (existing.backdropPath?.startsWith('/') ?? false) &&
                    (detail?.backdropPath?.trim().isNotEmpty ?? false)));
        final nextBackdrop = existing.backdropLocked
            ? existing.backdropPath
            : (outcome.upgradedBackdropPath ??
                  (canUpgradeRemoteBackdrop
                      ? (detail?.backdropPath ?? existing.backdropPath)
                      : existing.backdropPath));
        final detailPosterSuboptimal =
            detail != null &&
            WorkWallEligibility.isTmdbPosterSuboptimal(
              selectedPosterPath: detail.posterPath,
              candidatePosters: detail.candidatePosters,
            );
        final nextPoster = existing.posterLocked
            ? existing.posterPath
            : (missingPoster
                  ? ((detailPosterSuboptimal
                            ? outcome.fallbackPosterPath
                            : null) ??
                        detail?.posterPath ??
                        outcome.fallbackPosterPath ??
                        existing.posterPath)
                  : existing.posterPath);
        final nextNegUntil = outcome.negativeUntil;
        final nextNegMask = outcome.negativeMask;
        final changed =
            nextLogo != existing.logoPath ||
            nextBackdrop != existing.backdropPath ||
            nextPoster != existing.posterPath ||
            nextTvdb != existing.tvdbId ||
            nextNegUntil != existing.logoNegativeUntil ||
            nextNegMask != existing.logoNegativeMask;
        if (!changed) return existing;
        final updated = existing.copyWith(
          logoPath: nextLogo,
          backdropPath: nextBackdrop,
          posterPath: nextPoster,
          tvdbId: nextTvdb,
          clearLogoNegative:
              nextLogo != null &&
              nextLogo.trim().isNotEmpty &&
              nextNegMask == 0 &&
              nextNegUntil == null,
          logoNegativeUntil: nextNegUntil,
          logoNegativeMask: nextNegMask,
        );
        await _repository.upsertWork(updated);
        if (detail != null) {
          await SeriesAutoLinker.reconcileAll(
            repository: _repository,
            bangumiService: _bangumiService,
            tmdbService: _tmdbService,
            tmdbCollectionIdByTmdbId: _tmdbCollectionIdByTmdbId,
            focusBangumiIds: {
              if ((updated.bangumiId ?? 0) > 0) updated.bangumiId!,
            },
            focusWorkIds: {updated.id},
            relationCache: _bangumiRelationCache,
          );
        }
        return await _repository.findWorkById(workId) ?? updated;
      }

      if (detail == null) return existing;
      final nextLogo = missingLogo
          ? (detail.logoPath ?? existing.logoPath)
          : existing.logoPath;
      final nextTvdb = detail.tvdbId ?? existing.tvdbId;
      final canUpgradeRemoteBackdrop =
          !existing.backdropLocked &&
          (missingBackdrop ||
              (missingLogo &&
                  (existing.backdropPath?.startsWith('/') ?? false) &&
                  (detail.backdropPath?.trim().isNotEmpty ?? false)));
      final nextBackdrop = canUpgradeRemoteBackdrop
          ? (detail.backdropPath ?? existing.backdropPath)
          : existing.backdropPath;
      final nextPoster = (!existing.posterLocked && missingPoster)
          ? (detail.posterPath ?? existing.posterPath)
          : existing.posterPath;

      if (nextLogo == existing.logoPath &&
          nextBackdrop == existing.backdropPath &&
          nextPoster == existing.posterPath &&
          nextTvdb == existing.tvdbId) {
        return existing;
      }
      final updated = existing.copyWith(
        logoPath: nextLogo,
        backdropPath: nextBackdrop,
        posterPath: nextPoster,
        tvdbId: nextTvdb,
        clearLogoNegative: nextLogo != null && nextLogo.trim().isNotEmpty,
      );
      await _repository.upsertWork(updated);
      await SeriesAutoLinker.reconcileAll(
        repository: _repository,
        bangumiService: _bangumiService,
        tmdbService: _tmdbService,
        tmdbCollectionIdByTmdbId: _tmdbCollectionIdByTmdbId,
        focusBangumiIds: {if ((updated.bangumiId ?? 0) > 0) updated.bangumiId!},
        focusWorkIds: {updated.id},
        relationCache: _bangumiRelationCache,
      );
      return await _repository.findWorkById(workId) ?? updated;
    }

    if (!interactive && existing.metadataLocked) {
      return _refreshNonTmdbWork(existing, interactive: false);
    }

    final variants = await _repository.getVariantsByWork(workId);
    final episodes = await _repository.getEpisodesByWork(workId);
    final mainEpNums =
        episodes
            .where(
              (e) =>
                  e.category == EpisodeCategory.main &&
                  e.episodeNumber != null &&
                  e.episodeNumber! > 0,
            )
            .map((e) => e.episodeNumber!)
            .toSet()
            .toList()
          ..sort();
    final extraQueries = <String>[
      existing.title.trim(),
      if (existing.originalTitle != null) existing.originalTitle!.trim(),
    ].where((s) => s.isNotEmpty).toSet().toList(growable: false);

    GroupedWorkFolder? folder;
    if (variants.isNotEmpty) {
      final files = variants
          .map(
            (v) => ScannedFileInput(
              relativePath: v.relativePath,
              fileName: v.fileName,
              fileSize: v.fileSize,
              assetKind: v.assetKind,
              externalSubtitles: v.externalSubtitles,
              subtitleGroupHint: v.subtitleGroup,
            ),
          )
          .toList(growable: false);
      final grouped = await _computeWorker.groupFiles(
        sourceId: variants.first.sourceId,
        files: files,
      );
      if (grouped.isNotEmpty) {
        folder = grouped.first;
      }
    }
    folder ??= GroupedWorkFolder(
      folderRelativePath: existing.title,
      folderName: existing.title,
      cleanTitle: existing.title,
      explicitTmdbId: existing.folderTmdbHint,
      year: existing.year,
      seasonHint: existing.matchedSeason,
      mainEpisodeNumbers: mainEpNums,
      variants: const [],
      titleHints: extraQueries,
      extraSearchQueries: extraQueries,
    );

    final explicitId = existing.folderTmdbHint ?? folder.explicitTmdbId;
    if (explicitId != null) {
      final explicitFolder = folder.explicitTmdbId != null
          ? folder
          : GroupedWorkFolder(
              folderRelativePath: folder.folderRelativePath,
              folderName: folder.folderName,
              cleanTitle: folder.cleanTitle,
              explicitTmdbId: explicitId,
              explicitMediaType: folder.explicitMediaType,
              year: folder.year ?? existing.year,
              seasonHint: folder.seasonHint ?? existing.matchedSeason,
              mainEpisodeNumbers: folder.mainEpisodeNumbers.isNotEmpty
                  ? folder.mainEpisodeNumbers
                  : mainEpNums,
              isMovieHint: folder.isMovieHint,
              variants: folder.variants,
              titleHints: folder.titleHints,
              extraSearchQueries: extraQueries,
            );
      TmdbWorkDetail? explicitDetail;
      try {
        explicitDetail = await _candidateFetcher.fetchExplicitDetail(
          explicitFolder,
        );
      } catch (error) {
        developer.log(
          '显式 TMDB 补绑查询失败，回退 Bangumi/Fanart 刷新',
          name: 'konata.scrape_orchestrator',
          error: error,
        );
      }
      if (explicitDetail != null) {
        return rebindWorkToTmdb(
          workId,
          explicitDetail.tmdbId,
          explicitDetail.mediaType,
          markManualLocked: interactive || existing.isManualLocked,
        );
      }
    }

    final bgmById = <int, BangumiSubjectCandidate>{};
    reportStep(2, '正在检索 Bangumi 与 TMDB 候选...');
    if (_bangumiService != null && existing.bangumiId != null) {
      try {
        final bgmDetail = await _bangumiService.getSubjectDetail(
          existing.bangumiId!,
          priority: interactive
              ? RequestPriority.interactive
              : RequestPriority.background,
        );
        if (bgmDetail != null) {
          bgmById[bgmDetail.id] = bgmDetail;
        }
      } catch (error) {
        developer.log(
          '可恢复异常已记录',
          name: 'konata.scrape_orchestrator',
          error: error,
        );
      }
    }
    final searchedBgm = await _candidateFetcher.fetchBangumiCandidates(
      folder,
      extraQueries: extraQueries,
    );
    for (final c in searchedBgm) {
      bgmById.putIfAbsent(c.id, () => c);
    }
    final bgmCandidates = bgmById.values.toList(growable: false);
    final bgmEval = await _computeWorker.evaluateBangumiMatch(
      folder,
      bgmCandidates,
    );

    var candidates = const <TmdbWorkDetail>[];
    // 已有可信 Bangumi ID（如降级入库的条目）时，先查离线映射直连拉取对应 TMDB 详情入池，避免长副标题关键词搜索漏召回。
    final mappedBgmId = existing.bangumiId ?? bgmEval.best?.subject.id;
    final mappedDetails = <TmdbWorkDetail>[];
    if (mappedBgmId != null && mappedBgmId > 0) {
      final mappedTargets = BangumiTmdbIndex.resolveTargets(
        mappedBgmId,
        index: _mappingIndex,
      );
      if (mappedTargets.isNotEmpty) {
        final seenTargetKeys = <String>{};
        final directTargets = <({TmdbMediaType type, int id})>[
          for (final t in mappedTargets)
            if (seenTargetKeys.add(t.key)) (type: t.type, id: t.id),
        ].take(3).toList(growable: false);
        try {
          mappedDetails.addAll(
            await _candidateFetcher.fetchDetailsByIds(
              directTargets,
              includeImages: false,
            ),
          );
        } catch (error) {
          developer.log(
            '离线映射直连 TMDB 补绑查询失败，继续关键词检索',
            name: 'konata.scrape_orchestrator',
            error: error,
          );
        }
      }
    }
    try {
      candidates = await _candidateFetcher.fetchCandidateDetails(
        folder,
        bangumiCandidate: bgmEval.best,
        extraQueries: extraQueries,
      );
    } catch (error) {
      developer.log(
        'TMDB 候选拉取不可用，继续执行 Bangumi 与 Fanart 补全',
        name: 'konata.scrape_orchestrator',
        error: error,
      );
    }
    if (mappedDetails.isNotEmpty) {
      final mergedByKey = <String, TmdbWorkDetail>{
        for (final c in candidates) '${c.mediaType.name}:${c.tmdbId}': c,
        for (final m in mappedDetails) '${m.mediaType.name}:${m.tmdbId}': m,
      };
      candidates = mergedByKey.values.toList(growable: false);
    }
    var decision = await _computeWorker.evaluateMatch(
      folder,
      candidates,
      bangumiCandidates: bgmCandidates,
      mappingIndex: _mappingIndex,
    );

    final rescueTarget =
        decision.bestBangumi?.subject ??
        bgmEval.best?.subject ??
        (existing.bangumiId != null ? bgmById[existing.bangumiId!] : null);
    if (rescueTarget != null &&
        (decision.best == null ||
            (decision.best!.detail.backdropPath?.trim().isEmpty ?? true))) {
      try {
        final rescued = await _candidateFetcher.rescueTmdbByBangumi(
          folder,
          rescueTarget,
          existingDetails: candidates,
        );
        if (rescued.length > candidates.length) {
          candidates = rescued;
          decision = await _computeWorker.evaluateMatch(
            folder,
            candidates,
            bangumiCandidates: bgmCandidates,
            mappingIndex: _mappingIndex,
          );
        }
      } catch (error) {
        developer.log(
          'TMDB 交叉救回不可用，保留 Bangumi/Fanart 刷新',
          name: 'konata.scrape_orchestrator',
          error: error,
        );
      }
    }

    final best = decision.best;
    final allowBind =
        best != null &&
        (decision.level == MatchLevel.autoBind ||
            (existing.bangumiId != null &&
                decision.level != MatchLevel.unmatched) ||
            (interactive && decision.level != MatchLevel.unmatched));
    if (allowBind) {
      return rebindWorkToTmdb(
        workId,
        best.detail.tmdbId,
        best.detail.mediaType,
        markManualLocked: interactive || existing.isManualLocked,
        onProgress: onProgress,
      );
    }
    if (existing.bangumiId != null && mappedDetails.length == 1) {
      final mapped = mappedDetails.single;
      return rebindWorkToTmdb(
        workId,
        mapped.tmdbId,
        mapped.mediaType,
        markManualLocked: interactive || existing.isManualLocked,
        onProgress: onProgress,
      );
    }

    // 无 TMDB 匹配时仍支持刷新 Bangumi 元数据/分集及 Fanart.tv 封面/背景/透明徽标。
    return _refreshNonTmdbWork(
      existing,
      bgmSubject: rescueTarget,
      folder: folder,
      interactive: interactive,
      onProgress: onProgress,
    );
  }

  /// 对单条待复核或因网络异常降级的作品执行高优先交互式重新匹配。
  ///
  /// 复用完整在线匹配流水线（显式 TMDB 编号直连 + Bangumi/TMDB 联合打分），
  /// 命中高置信度时自动升级为已匹配并清理复核原因；存在候选或仍遇网络异常时如实写回最新状态与原因。
  Future<RematchWorkResult> rematchReviewWork(String workId) async {
    final existing = await _repository.findWorkById(workId);
    if (existing == null) {
      return const RematchWorkResult(
        outcome: RematchWorkOutcome.unmatched,
        errorMessage: '作品不存在或已被移除',
      );
    }

    final variants = await _repository.getVariantsByWork(workId);
    final episodes = await _repository.getEpisodesByWork(workId);
    final mainEpNums =
        episodes
            .where(
              (e) =>
                  e.category == EpisodeCategory.main &&
                  e.episodeNumber != null &&
                  e.episodeNumber! > 0,
            )
            .map((e) => e.episodeNumber!)
            .toSet()
            .toList()
          ..sort();
    final extraQueries = <String>[
      existing.title.trim(),
      if (existing.originalTitle != null) existing.originalTitle!.trim(),
    ].where((s) => s.isNotEmpty).toSet().toList(growable: false);

    var folder =
        await _rebuildFolderFromVariants(variants, existing: existing) ??
        GroupedWorkFolder(
          folderRelativePath: existing.title,
          folderName: existing.title,
          cleanTitle: existing.title,
          explicitTmdbId: existing.folderTmdbHint,
          year: existing.year,
          seasonHint: existing.matchedSeason,
          mainEpisodeNumbers: mainEpNums,
          variants: const [],
          titleHints: extraQueries,
          extraSearchQueries: extraQueries,
        );
    final explicitId = existing.folderTmdbHint ?? folder.explicitTmdbId;
    if (explicitId != null && folder.explicitTmdbId == null) {
      folder = GroupedWorkFolder(
        folderRelativePath: folder.folderRelativePath,
        folderName: folder.folderName,
        cleanTitle: folder.cleanTitle,
        explicitTmdbId: explicitId,
        explicitMediaType: folder.explicitMediaType,
        year: folder.year ?? existing.year,
        seasonHint: folder.seasonHint ?? existing.matchedSeason,
        mainEpisodeNumbers: folder.mainEpisodeNumbers.isNotEmpty
            ? folder.mainEpisodeNumbers
            : mainEpNums,
        isMovieHint: folder.isMovieHint,
        variants: folder.variants,
        inventory: folder.inventory,
        slotAssignmentsByPath: folder.slotAssignmentsByPath,
        physicalRootFolder: folder.physicalRootFolder,
        isSplitCluster: folder.isSplitCluster,
        titleHints: folder.titleHints,
        fileHints: folder.fileHints,
        extraSearchQueries: folder.extraSearchQueries.isNotEmpty
            ? folder.extraSearchQueries
            : extraQueries,
        parentTmdbId: folder.parentTmdbId,
        parentTmdbType: folder.parentTmdbType,
        allowParentTmdbCandidate: folder.allowParentTmdbCandidate,
        assetScopesByPath: folder.assetScopesByPath,
        localPosterPath: folder.localPosterPath,
        matchDifficulty: folder.matchDifficulty,
      );
    }

    Future<RematchWorkResult> persistNetworkFailure(Object error) async {
      final userMessage = NetworkErrorSanitizer.toUserMessage(error);
      final reason = NetworkErrorSanitizer.isTransientNetworkError(error)
          ? NetworkErrorSanitizer.toUserMessage(
              error,
              prefix: existing.bangumiId != null
                  ? 'TMDB 网络异常，已降级使用 Bangumi 元数据入库'
                  : 'TMDB 网络异常，已使用本地目录降级入库',
            )
          : userMessage;
      final refreshed = existing.copyWith(
        scrapeStatus: ScrapeStatus.needsReview,
        reviewReason: reason,
      );
      await _repository.upsertWork(refreshed);
      return RematchWorkResult(
        outcome: RematchWorkOutcome.networkError,
        work: refreshed,
        errorMessage: userMessage,
      );
    }

    Object? tmdbNetworkError;
    void recordTmdbError(Object err) {
      tmdbNetworkError ??= err;
    }

    // 阶段 1：显式目录 `{tmdb-N}` / `[tmdbid=N]` 优先高优直连。
    var effectiveFolder = folder;
    if (folder.explicitTmdbId != null) {
      TmdbWorkDetail? explicitDetail;
      try {
        explicitDetail = await _interactiveCandidateFetcher.fetchExplicitDetail(
          folder,
          onNetworkError: recordTmdbError,
        );
      } catch (error) {
        return persistNetworkFailure(error);
      }
      if (explicitDetail != null) {
        try {
          final bound = await rebindWorkToTmdb(
            workId,
            explicitDetail.tmdbId,
            explicitDetail.mediaType,
            markManualLocked: existing.isManualLocked,
          );
          return RematchWorkResult(
            outcome: RematchWorkOutcome.matched,
            work: bound,
          );
        } catch (error) {
          return persistNetworkFailure(error);
        }
      }
      if (tmdbNetworkError == null) {
        effectiveFolder = folder.withoutExplicitTmdb();
      }
    }

    // 显式直连已遇瞬时网络异常时直接报错返回，避免重复阻塞在已知故障链路。
    if (tmdbNetworkError != null) {
      return persistNetworkFailure(tmdbNetworkError!);
    }

    // 阶段 2：复用统一在线匹配决策器（高优交互通道）执行全量 TMDB + Bangumi 匹配。
    ScrapeMatchResolution resolution;
    try {
      resolution = await _interactiveMatchResolver.resolve(
        effectiveFolder,
        computeWorker: _computeWorker,
      );
    } catch (error) {
      return persistNetworkFailure(error);
    }
    tmdbNetworkError ??= resolution.networkError;
    final decision = resolution.decision;

    if (decision.level == MatchLevel.autoBind && decision.best != null) {
      try {
        final bound = await rebindWorkToTmdb(
          workId,
          decision.best!.detail.tmdbId,
          decision.best!.detail.mediaType,
          markManualLocked: existing.isManualLocked,
        );
        return RematchWorkResult(
          outcome: RematchWorkOutcome.matched,
          work: bound,
        );
      } catch (error) {
        return persistNetworkFailure(error);
      }
    }

    if (tmdbNetworkError != null) {
      return persistNetworkFailure(tmdbNetworkError!);
    }

    // TMDB 网络正常但无 TMDB 命中时，允许按 Bangumi 独立上墙策略升级或更新复核状态。
    final fallbackBgmCandidate = decision.bestBangumi;
    if (decision.best == null && fallbackBgmCandidate != null) {
      final bgmWall = await _artworkEnricher.evaluateBangumiOnly(
        folder: effectiveFolder,
        bangumiCandidate: fallbackBgmCandidate,
        bangumiTier: resolution.bangumiTier,
        priority: RequestPriority.interactive,
      );
      final promoted =
          bgmWall.canPromote || decision.level == MatchLevel.autoBind;
      final bgmStatus = promoted
          ? ScrapeStatus.matched
          : ScrapeStatus.needsReview;
      final bgmReason = promoted
          ? null
          : (decision.reviewReason ?? '未能匹配到对应 TMDB 条目，请手动核实');
      final builtBgm = ScrapeWorkPersister.buildBangumiOnlyWork(
        id: existing.id,
        folder: effectiveFolder,
        bangumiCandidate: fallbackBgmCandidate,
        status: bgmStatus,
        reviewReason: bgmReason,
        tvdbId: bgmWall.tvdbId,
        posterPathOverride: bgmWall.fanartPoster,
        backdropPath: bgmWall.fanartBackdrop,
        portraitBackdropPath: bgmWall.fanartPortraitBackdrop,
        logoPath: bgmWall.fanartLogo,
        isManualLocked: existing.isManualLocked,
        isHidden: existing.isHidden,
        keepHidden: existing.keepHidden,
      );
      final updated = ScrapeWorkPersister.mergeWorkWithLocks(
        existing: existing,
        candidate: builtBgm,
      );
      await _repository.upsertWork(updated);
      await _photosStorage?.renameWorkFolderIfNeeded(updated.id, updated.title);
      if (promoted) {
        await _repository.clearScrapeCandidates(workId);
        final bgmEpisodes = await _interactiveCandidateFetcher
            .fetchBangumiEpisodes(fallbackBgmCandidate.subject.id, type: null);
        await _persister.syncEpisodesAndVariants(
          work: updated,
          folder: effectiveFolder,
          tmdbEpisodes: const [],
          bangumiEpisodes: bgmEpisodes,
        );
        await SeriesAutoLinker.reconcileAll(
          repository: _repository,
          bangumiService: _bangumiService,
          tmdbService: _tmdbService,
          tmdbCollectionIdByTmdbId: _tmdbCollectionIdByTmdbId,
          focusBangumiIds: {
            if ((updated.bangumiId ?? 0) > 0) updated.bangumiId!,
          },
          focusWorkIds: {updated.id},
          relationCache: _bangumiRelationCache,
        );
        return RematchWorkResult(
          outcome: RematchWorkOutcome.matched,
          work: await _repository.findWorkById(workId) ?? updated,
        );
      }
      await _persister.saveTopCandidates(workId, decision.topCandidates);
      return RematchWorkResult(
        outcome: RematchWorkOutcome.needsReview,
        work: updated,
        candidateCount: decision.topCandidates.take(5).length,
      );
    }

    if (decision.level == MatchLevel.reviewRequired ||
        decision.topCandidates.isNotEmpty) {
      await _persister.saveTopCandidates(workId, decision.topCandidates);
      final updated = existing.copyWith(
        scrapeStatus: ScrapeStatus.needsReview,
        reviewReason: decision.reviewReason ?? '多个候选分数接近，需人工核实',
      );
      await _repository.upsertWork(updated);
      return RematchWorkResult(
        outcome: RematchWorkOutcome.needsReview,
        work: updated,
        candidateCount: decision.topCandidates.take(5).length,
      );
    }

    await _repository.clearScrapeCandidates(workId);
    final updated = existing.copyWith(
      scrapeStatus: ScrapeStatus.unmatched,
      reviewReason: decision.reviewReason ?? '未搜索到匹配词条，请手动检索或指定 TMDB ID',
    );
    await _repository.upsertWork(updated);
    return RematchWorkResult(
      outcome: RematchWorkOutcome.unmatched,
      work: updated,
    );
  }

  Future<GroupedWorkFolder?> _rebuildFolderFromVariants(
    List<MediaVariant> variants, {
    Work? existing,
  }) async {
    if (variants.isEmpty) return null;
    final files = variants
        .map(
          (v) => ScannedFileInput(
            relativePath: v.relativePath,
            fileName: v.fileName,
            fileSize: v.fileSize,
            assetKind: v.assetKind,
            externalSubtitles: v.externalSubtitles,
            subtitleGroupHint: v.subtitleGroup,
          ),
        )
        .toList(growable: false);
    final grouped = await _computeWorker.groupFiles(
      sourceId: variants.first.sourceId,
      files: files,
    );
    if (grouped.isEmpty) return null;
    if (grouped.length == 1 || existing == null) return grouped.first;

    // 多分组场景优先匹配既有显式 TMDB 提示、作品标题或视频数量最多的主分组。
    if (existing.folderTmdbHint != null) {
      for (final g in grouped) {
        if (g.explicitTmdbId == existing.folderTmdbHint) return g;
      }
    }
    final normTitle = existing.title.trim().toLowerCase();
    for (final g in grouped) {
      if (g.cleanTitle.trim().toLowerCase() == normTitle) return g;
    }
    var best = grouped.first;
    var bestVideos = best.variants
        .where((v) => v.assetKind == AssetKind.video)
        .length;
    for (final g in grouped.skip(1)) {
      final count = g.variants
          .where((v) => v.assetKind == AssetKind.video)
          .length;
      if (count > bestVideos) {
        best = g;
        bestVideos = count;
      }
    }
    return best;
  }

  Future<Work?> _refreshNonTmdbWork(
    Work existing, {
    BangumiSubjectCandidate? bgmSubject,
    GroupedWorkFolder? folder,
    required bool interactive,
    WorkRescrapeProgressListener? onProgress,
  }) async {
    onProgress?.call(
      WorkRescrapeProgress(
        workId: existing.id,
        stageLabel: '正在获取 Bangumi 与艺术图元数据...',
        stepIndex: 4,
        totalSteps: 6,
      ),
    );
    final resolvedTvdbId =
        existing.tvdbId ??
        ScrapeArtworkEnricher.lookupOfflineTvdbId(
          mappingIndex: _mappingIndex,
          bangumiId: bgmSubject?.id ?? existing.bangumiId,
          tmdbId: existing.tmdbId,
          mediaType: existing.tmdbMediaType,
        );
    final effectiveFanartType = existing.tmdbMediaType == TmdbMediaType.movie
        ? TmdbMediaType.movie
        : TmdbMediaType.tv;
    final hasFanartId = effectiveFanartType == TmdbMediaType.movie
        ? (existing.tmdbId != null && existing.tmdbId! > 0)
        : (resolvedTvdbId != null && resolvedTvdbId > 0);
    final missingLogo =
        !existing.logoLocked &&
        (existing.logoPath == null || existing.logoPath!.trim().isEmpty);
    final missingBackdrop =
        !existing.backdropLocked &&
        (existing.backdropPath == null ||
            existing.backdropPath!.trim().isEmpty);
    final missingPoster =
        !existing.posterLocked &&
        (existing.posterPath == null || existing.posterPath!.trim().isEmpty);

    FanartArtworkResult? fanartBundle;
    if (hasFanartId &&
        _fanartService != null &&
        _fanartService.isConfigured &&
        (interactive || missingLogo || missingBackdrop || missingPoster)) {
      fanartBundle = await _artworkEnricher.fetchFanartBundleIfAvailable(
        mediaType: effectiveFanartType,
        tmdbId: existing.tmdbId,
        tvdbId: resolvedTvdbId,
        priority: interactive
            ? RequestPriority.interactive
            : RequestPriority.background,
        forceRefresh: interactive,
      );
    }

    final fanartPoster = fanartBundle?.bestPosterUrlForSeason(
      existing.matchedSeason,
    );
    final fanartBackdrop = fanartBundle?.bestBackgroundUrl;
    final rankedFanartLogos = ClearLogoResolver.toRankedFanartLogos(
      fanartBundle?.logos ?? const [],
      tmdbId: existing.tmdbId,
      tvdbId: resolvedTvdbId,
      mediaType: effectiveFanartType,
      matchedSeason: existing.matchedSeason,
    );
    final fanartLogo = rankedFanartLogos.isEmpty
        ? fanartBundle?.bestLogoUrl
        : rankedFanartLogos.first.filePath;

    final nextTitle = (!existing.metadataLocked && bgmSubject != null)
        ? (bgmSubject.displayTitle.trim().isNotEmpty
              ? bgmSubject.displayTitle.trim()
              : existing.title)
        : existing.title;
    final nextOverview = (!existing.metadataLocked && bgmSubject != null)
        ? (_nonEmpty(bgmSubject.summary) ?? existing.overview)
        : existing.overview;
    final nextYear = (!existing.metadataLocked && bgmSubject != null)
        ? (bgmSubject.year ?? existing.year)
        : existing.year;
    final nextBgmPoster =
        _nonEmpty(bgmSubject?.posterUrl) ?? existing.bangumiPosterPath;
    final nextPoster = existing.posterLocked
        ? existing.posterPath
        : ((interactive || missingPoster)
              ? (nextBgmPoster ?? fanartPoster ?? existing.posterPath)
              : existing.posterPath);
    final nextBackdrop = existing.backdropLocked
        ? existing.backdropPath
        : ((interactive || missingBackdrop)
              ? (fanartBackdrop ?? existing.backdropPath)
              : existing.backdropPath);
    final nextLogo = existing.logoLocked
        ? existing.logoPath
        : ((interactive || missingLogo)
              ? (fanartLogo ?? existing.logoPath)
              : existing.logoPath);
    final nextScore = bgmSubject?.score ?? existing.bangumiScore;
    final nextStatus =
        (existing.scrapeStatus != ScrapeStatus.matched &&
            nextPoster != null &&
            nextPoster.trim().isNotEmpty &&
            (bgmSubject != null || resolvedTvdbId != null))
        ? ScrapeStatus.matched
        : existing.scrapeStatus;

    final changed =
        resolvedTvdbId != existing.tvdbId ||
        nextTitle != existing.title ||
        nextOverview != existing.overview ||
        nextYear != existing.year ||
        nextBgmPoster != existing.bangumiPosterPath ||
        nextPoster != existing.posterPath ||
        nextBackdrop != existing.backdropPath ||
        nextLogo != existing.logoPath ||
        nextScore != existing.bangumiScore ||
        nextStatus != existing.scrapeStatus;

    if (!changed && !interactive) {
      return null;
    }

    final updated = existing.copyWith(
      tvdbId: resolvedTvdbId,
      title: nextTitle,
      overview: nextOverview,
      year: nextYear,
      posterPath: nextPoster,
      bangumiPosterPath: nextBgmPoster,
      backdropPath: nextBackdrop,
      logoPath: nextLogo,
      bangumiScore: nextScore,
      scrapeStatus: nextStatus,
      clearLogoNegative: nextLogo != null && nextLogo.trim().isNotEmpty,
    );
    await _repository.upsertWork(updated);
    await _photosStorage?.renameWorkFolderIfNeeded(updated.id, updated.title);

    if (interactive &&
        updated.bangumiId != null &&
        folder != null &&
        folder.variants.isNotEmpty) {
      final bgmEpisodes = await _candidateFetcher.fetchBangumiEpisodes(
        updated.bangumiId!,
        type: null,
      );
      if (bgmEpisodes.isNotEmpty) {
        await _persister.syncEpisodesAndVariants(
          work: updated,
          folder: folder,
          tmdbEpisodes: const [],
          bangumiEpisodes: bgmEpisodes,
        );
      }
    }
    return await _repository.findWorkById(existing.id) ?? updated;
  }

  static String? _nonEmpty(String? raw) {
    final trimmed = raw?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    return trimmed;
  }

  /// 仅针对与本次新扫入作品同身份（相同 TMDB/Bangumi 或同名同文件）的同源旧作品核实源目录存活性，自动清理因目录改名产生的幽灵重复卡片。
  Future<void> _pruneMovedOutOfScopeGhostWorks({
    required MediaSourceGateway gateway,
    required String sourceId,
    required MediaSourceKind sourceKind,
    required Set<String> newlyActiveWorkIds,
    required List<String> scopedRoots,
    bool Function()? isCancelled,
  }) async {
    final normScoped = scopedRoots
        .map(
          (r) =>
              r.trim().replaceAll('\\', '/').replaceAll(RegExp(r'^/+|/+$'), ''),
        )
        .where((r) => r.isNotEmpty)
        .toList(growable: false);
    if (normScoped.isEmpty) return;

    bool inScoped(String path) {
      return normScoped.any(
        (root) => path == root || path.startsWith('$root/'),
      );
    }

    final allWorks = await _repository.getAllWorks();
    final newWorks = allWorks
        .where((w) => newlyActiveWorkIds.contains(w.id))
        .toList(growable: false);
    if (newWorks.isEmpty) return;

    final allSourceVariants = await _repository.getVariantsBySource(sourceId);
    final variantsByWork = <String, List<MediaVariant>>{};
    for (final v in allSourceVariants) {
      variantsByWork.putIfAbsent(v.workId, () => <MediaVariant>[]).add(v);
    }

    final newFileSetsByWork = <String, Set<String>>{
      for (final nw in newWorks)
        nw.id: {
          for (final v in (variantsByWork[nw.id] ?? const <MediaVariant>[]))
            if (v.assetKind == AssetKind.video) v.fileName.toLowerCase(),
        },
    };

    bool matchesAnyNewWork(Work oldWork, List<MediaVariant> oldVars) {
      final oldVideoNames = {
        for (final v in oldVars)
          if (v.assetKind == AssetKind.video) v.fileName.toLowerCase(),
      };
      for (final nw in newWorks) {
        if (nw.id == oldWork.id) continue;
        if (oldWork.tmdbId != null &&
            nw.tmdbId == oldWork.tmdbId &&
            nw.tmdbMediaType == oldWork.tmdbMediaType &&
            nw.matchedSeason == oldWork.matchedSeason) {
          return true;
        }
        if (oldWork.bangumiId != null && nw.bangumiId == oldWork.bangumiId) {
          return true;
        }
        if (nw.title.trim().toLowerCase() ==
            oldWork.title.trim().toLowerCase()) {
          return true;
        }
        final nwFiles = newFileSetsByWork[nw.id] ?? const <String>{};
        final hasDistinctiveNames = oldVideoNames.every((n) => n.length >= 16);
        if (hasDistinctiveNames &&
            oldVideoNames.isNotEmpty &&
            oldVideoNames.length == nwFiles.length &&
            oldVideoNames.containsAll(nwFiles)) {
          return true;
        }
      }
      return false;
    }

    final listedChildrenByParent = <String, Set<String>?>{};
    Future<bool> isDirDefinitelyMissing(String relDir) async {
      final slash = relDir.lastIndexOf('/');
      final parent = slash > 0 ? relDir.substring(0, slash) : '';
      final leaf = (slash > 0 ? relDir.substring(slash + 1) : relDir)
          .trim()
          .toLowerCase();
      Set<String>? siblings;
      if (listedChildrenByParent.containsKey(parent)) {
        siblings = listedChildrenByParent[parent];
      } else {
        try {
          final entries = await gateway.listDirectory(parent);
          siblings = {for (final e in entries) e.name.trim().toLowerCase()};
        } catch (err) {
          final classified = ScrapeSourceAccessErrorClassifier.classify(
            err,
            sourceKind,
          );
          siblings = classified.kind == SourceAccessProblemKind.path
              ? const <String>{}
              : null;
        }
        listedChildrenByParent[parent] = siblings;
      }
      return siblings != null && !siblings.contains(leaf);
    }

    for (final w in allWorks) {
      if (isCancelled?.call() ?? false) return;
      if (newlyActiveWorkIds.contains(w.id)) continue;
      final oldVars = variantsByWork[w.id];
      if (oldVars == null || oldVars.isEmpty) continue;
      if (oldVars.any((v) => v.workLocked || v.scopeLocked)) continue;

      // 先在内存中过滤同身份与扫描范围外目录，仅对真正疑似幽灵重复项查全库变体与源端目录存活性。
      if (!matchesAnyNewWork(w, oldVars)) continue;
      final outOfScopeDirs = <String>{};
      var anyInScope = false;
      for (final v in oldVars) {
        final norm = v.relativePath
            .trim()
            .replaceAll('\\', '/')
            .replaceAll(RegExp(r'^/+|/+$'), '');
        if (inScoped(norm)) {
          anyInScope = true;
          break;
        }
        final segs = norm.split('/').where((s) => s.isNotEmpty).toList();
        if (segs.length > 1) {
          final depth = segs.length >= 3 ? 2 : 1;
          outOfScopeDirs.add(segs.sublist(0, depth).join('/'));
        }
      }
      if (anyInScope || outOfScopeDirs.isEmpty) continue;

      final fullWorkVars = await _repository.getVariantsByWork(w.id);
      if (fullWorkVars.any((v) => v.sourceId != sourceId)) continue;

      var allMissing = true;
      for (final d in outOfScopeDirs) {
        if (isCancelled?.call() ?? false) return;
        if (!await isDirDefinitelyMissing(d)) {
          allMissing = false;
          break;
        }
      }
      if (allMissing) {
        await _repository.deleteWork(w.id);
      }
    }
  }

  static String _normalizeSourceRelPath(String raw) {
    return raw
        .trim()
        .replaceAll('\\', '/')
        .replaceAll(RegExp(r'/+'), '/')
        .replaceAll(RegExp(r'^/+|/+$'), '')
        .toLowerCase();
  }

  void _logDecision({
    required String code,
    required String message,
    DiagnosticSeverity severity = DiagnosticSeverity.info,
    String? source,
    Map<String, Object?> context = const <String, Object?>{},
    Object? error,
    StackTrace? stackTrace,
  }) {
    _diagnosticLog?.logEvent(
      subsystem: DiagnosticSubsystem.scraper,
      code: code,
      message: message,
      severity: severity,
      source: source,
      context: context,
      error: error,
      stackTrace: stackTrace,
    );
  }
}

/// 单部作品目录刮削处理的内部返回值。
class _FolderProcessResult {
  const _FolderProcessResult({
    required this.status,
    required this.workId,
    required this.displayTitle,
    required this.didPersist,
    this.extraWorkIds = const [],
    this.rescuedByHardRules = false,
    this.episodeSyncOnly = false,
  });

  final ScrapeStatus status;
  final String workId;
  final List<String> extraWorkIds;
  final String displayTitle;
  final bool didPersist;
  final bool rescuedByHardRules;
  final bool episodeSyncOnly;
}

/// 单次扫描会话内共享的预载索引与串行写库互斥锁（避免跨作品并发时的 SQLite 写锁竞争与重复查表）。
class _ScanBatchContext {
  const _ScanBatchContext({
    required this.computeWorker,
    required this.worksById,
    required this.workIdByRelPath,
    required this.sourceVariantById,
    required this.unlockedVariantsByWorkId,
    required this.conflictingSplitWorkIdsByRoot,
    required this.persistMutex,
  });

  final ScrapeComputeWorker computeWorker;
  final Map<String, Work> worksById;
  final Map<String, String> workIdByRelPath;
  final Map<String, MediaVariant> sourceVariantById;
  final Map<String, List<MediaVariant>> unlockedVariantsByWorkId;
  final Map<String, Set<String>> conflictingSplitWorkIdsByRoot;
  final _AsyncMutex persistMutex;

  Set<String>? conflictingSplitWorkIdsFor(GroupedWorkFolder folder) {
    if (!folder.isSplitCluster) return null;
    final normRoot = (folder.physicalRootFolder ?? '')
        .trim()
        .replaceAll('\\', '/')
        .replaceAll(RegExp(r'^/+|/+$'), '');
    if (normRoot.isEmpty) return null;
    return conflictingSplitWorkIdsByRoot[normRoot];
  }
}

/// 轻量级异步串行互斥锁（保护数据库事务写入顺序与内存索引一致性）。
class _AsyncMutex {
  Future<void> _tail = Future<void>.value();

  Future<T> synchronized<T>(Future<T> Function() action) {
    final prev = _tail;
    final done = Completer<void>();
    _tail = done.future;
    return prev.then((_) async {
      try {
        return await action();
      } finally {
        done.complete();
      }
    });
  }
}
