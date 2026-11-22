import 'dart:async';
import 'dart:developer' as developer;

import 'package:path/path.dart' as p;

import '../../domain/formatting/network_error_sanitizer.dart';
import '../../domain/matching/directory_grouper.dart';
import '../../domain/matching/episode_remapper.dart';
import '../../domain/matching/work_matcher.dart';
import '../../domain/models/episode.dart';
import '../../domain/models/fanart_models.dart';
import '../../domain/models/media_source.dart';
import '../../domain/models/media_variant.dart';
import '../../domain/models/tmdb_models.dart';
import '../../domain/models/work.dart';
import '../../domain/repositories/file_system_gateway.dart';
import '../../domain/repositories/library_repository.dart';
import '../../domain/scraping/bangumi_models.dart';
import '../../domain/scraping/bangumi_tmdb_index.dart';
import '../../domain/scraping/match_difficulty_classifier.dart';
import '../../domain/scraping/scrape_domain_adapter.dart';
import '../../domain/scraping/work_wall_eligibility.dart';
import '../../infrastructure/cache/photos_storage.dart';
import '../../infrastructure/network/bangumi_service.dart';
import '../../infrastructure/network/fanart_service.dart';
import '../../infrastructure/network/priority_http_scheduler.dart';
import '../../infrastructure/network/tmdb_service.dart';
import '../../infrastructure/sources/directory_scan_snapshot.dart';
import '../../infrastructure/sources/directory_scan_snapshot_store.dart';
import '../../infrastructure/sources/directory_scanner.dart';
import '../../infrastructure/sources/source_access_error.dart';
import 'clear_logo_resolver.dart';
import 'release_group_work_merger.dart';
import 'scrape_artwork_enricher.dart';
import 'scrape_candidate_fetcher.dart';
import 'scrape_compute_worker.dart';
import 'scrape_match_resolver.dart';
import 'scrape_progress.dart';
import 'scrape_progress_tracker.dart';
import 'scrape_work_persister.dart';
import 'series_auto_linker.dart';
import 'work_directory_sync_service.dart';

/// 进度状态回调。
typedef ScrapeProgressListener = void Function(ScrapeProgress progress);

/// 单部作品完成落库后的实时通知回调（供媒体库即刻展示已匹配成果）。
typedef ScrapeWorkPersistedListener =
    void Function(String workId, ScrapeStatus status, String displayTitle);

/// 媒体源网关构建函数。
typedef GatewayBuilder =
    Future<MediaSourceGateway> Function(MediaSource source);

/// Konata 2.0 四段漏斗后台刮削调度器。
class ScrapeOrchestrator {
  /// 创建刮削调度器。
  ScrapeOrchestrator({
    required LibraryRepository repository,
    required TmdbService tmdbService,
    BangumiService? bangumiService,
    this._fanartService,
    this._clearLogoResolver,
    required this._gatewayBuilder,
    this._scanner = const DirectoryScanner(),
    this._computeWorker = const ScrapeComputeWorker(),
    this._photosStorage,
    this._mappingIndex,
    this._snapshotStore,
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
       ) {
    _matchResolver = ScrapeMatchResolver(
      fetcher: _candidateFetcher,
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
  final PhotosStorage? _photosStorage;
  final BangumiTmdbIndex? _mappingIndex;
  final DirectoryScanSnapshotStore? _snapshotStore;
  final int _maxWorkConcurrency;
  final GatewayBuilder _gatewayBuilder;
  final DirectoryScanner _scanner;
  final ScrapeWorkPersister _persister;
  final ScrapeCandidateFetcher _candidateFetcher;
  final ScrapeComputeWorker _computeWorker;
  late final ScrapeMatchResolver _matchResolver;
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
          : DirectoryScanSnapshotStore.keyFor(
              source,
              DirectoryScanner.normalizeScanRoots(effectiveRoots),
            );
      final previousSnapshot = store != null && !forceFullRescan
          ? await store.load(snapshotKey)
          : null;

      Future<DirectoryScanResult> scan(DirectoryScanSnapshot? previous) =>
          _scanner.scan(
            gateway,
            scanRoots: effectiveRoots,
            detectLocalCovers: source.kind == MediaSourceKind.local,
            sourceId: snapshotKey,
            previousSnapshot: previous,
            onCheckpoint: store?.save,
            isCancelled: isCancelled,
            onFolderVisited: tracker.recordFolderVisited,
            onProgress: (dir, dirCount, fileCount) {
              emit(
                tracker.updateScanProgress(
                  currentDir: dir,
                  scannedDirectories: dirCount,
                  foundFiles: fileCount,
                  cancelRequested: isCancelled?.call() ?? false,
                ),
              );
            },
          );

      DirectoryScanResult scanResult;
      try {
        scanResult = await scan(previousSnapshot);
      } catch (error) {
        // 断点记录的待扫目录可能已被移除，重新列举父目录以确认当前拓扑。
        if (previousSnapshot == null ||
            previousSnapshot.isComplete ||
            SourceAccessErrorClassifier.classify(error, source.kind).kind !=
                SourceAccessProblemKind.path) {
          rethrow;
        }
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

      final scanContext = _ScanBatchContext(
        computeWorker: computeSession,
        worksById: worksById,
        workIdByRelPath: workIdByRelPath,
        sourceVariantById: sourceVariantById,
        unlockedVariantsByWorkId: unlockedVariantsByWorkId,
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

      emit(
        tracker.advance(
          currentItemName: '正在整理系列归组与收尾...',
        ),
      );

      // 支持全量与局部 scanRoots 范围修剪：非空 scopedRoots 仅清理对应目录前缀下的失联条目，绝不误删未选目录作品。
      // 断点续扫期间已完成目录可能被单作品自动同步更新，留待后续校验确认缺失项。
      final canPruneStale = !scanResult.resumedFromCheckpoint;
      final hadStaleSourceVariant =
          canPruneStale &&
          existingSourceVariants.any((v) => !activeVariantIds.contains(v.id));
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
      emit(completed);
      return completed;
    } catch (error) {
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
        final existing = await _persister.findExistingWorkForFolder(
          sourceId,
          folder,
          workIdByRelPath: scanContext.workIdByRelPath,
          worksById: scanContext.worksById,
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
    final existing = await _persister.findExistingWorkForFolder(
      sourceId,
      folder,
      workIdByRelPath: scanContext.workIdByRelPath,
      worksById: scanContext.worksById,
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
    if (existing != null &&
        existing.scrapeStatus == ScrapeStatus.matched &&
        hasMatchedIdentityOrCover &&
        _canFastSkipUnchangedMatchedWork(
          existing: existing,
          folder: folder,
          existingUnlockedVariants:
              scanContext.unlockedVariantsByWorkId[existing.id] ?? const [],
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
    if (existing != null &&
        !existing.isManualLocked &&
        existing.scrapeStatus == ScrapeStatus.matched &&
        _canUseIncrementalEpisodeFastPath(existing: existing, folder: folder)) {
      await _workDirectorySync.syncMatchedWorkEpisodesOnly(
        work: existing,
        folder: folder,
        preloadedSourceVariantsById: scanContext.sourceVariantById,
        runPersist: scanContext.persistMutex.synchronized,
        isCancelled: isCancelled,
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
      final status = await _bindAndPersistDetail(
        workId: workId,
        existing: existing,
        folder: effectiveFolder,
        detail: decision.best!.detail,
        matchedSeason: decision.matchedSeason ?? decision.best!.matchedSeason,
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
      final bgmReviewReason = bgmStatus == ScrapeStatus.matched
          ? null
          : (tmdbNetworkError != null
                ? NetworkErrorSanitizer.toUserMessage(
                    tmdbNetworkError!,
                    prefix: 'TMDB 网络异常，已降级使用 Bangumi 元数据入库',
                  )
                : decision.reviewReason);
      final builtBgmWork = ScrapeWorkPersister.buildBangumiOnlyWork(
        id: workId,
        folder: effectiveFolder,
        bangumiCandidate: fallbackBgmCandidate,
        status: bgmStatus,
        reviewReason: bgmReviewReason,
        tvdbId: bgmWall.tvdbId,
        posterPathOverride: bgmWall.fanartPoster,
        backdropPath: bgmWall.fanartBackdrop,
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
      fanartPosterFallback: fanartEnrich.posterFallback,
      fanartBackdropOverride: fanartEnrich.backdropOverride,
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
        ((preRemap?.hasInterspersedSpecialCandidate ?? false) ||
            bundle.episodes.isEmpty ||
            bundle.episodes.any((e) => e.title.trim().isEmpty));
    final bangumiEpisodes = needBgmEpisodes
        ? await _candidateFetcher.fetchBangumiEpisodes(
            effectiveBgmId,
            type: null,
          )
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

  /// 判断已自动匹配的作品发生文件增删时是否可走零搜索增量剧集同步快通道。
  static bool _canUseIncrementalEpisodeFastPath({
    required Work existing,
    required GroupedWorkFolder folder,
  }) {
    final hasIdentity =
        (existing.tmdbId != null && existing.tmdbMediaType != null) ||
        existing.bangumiId != null;
    if (!hasIdentity) return false;
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

  /// 判断已成功匹配的作品在增量重扫时其未锁定文件集是否完全未变化，允许零网络请求直接快跳。
  ///
  /// 当同一作品已由同父目录多个压制组子目录归并时，按当前文件夹物理目录前缀隔离比对，
  /// 确保单目录新增追番集数/分卷必被精准感知，同时已归并的无变更子目录亦能零请求快跳。
  static bool _canFastSkipUnchangedMatchedWork({
    required Work existing,
    required GroupedWorkFolder folder,
    required List<MediaVariant> existingUnlockedVariants,
  }) {
    if (existingUnlockedVariants.isEmpty) {
      return false;
    }
    var scopedExisting = existingUnlockedVariants;
    if (existingUnlockedVariants.length > folder.variants.length &&
        !folder.isSplitCluster) {
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

  /// 人工纠错或元数据刷新：重绑定或刷新指定 TMDB 条目（未显式重置时严格保护已锁定字段与文件映射）。
  Future<Work> rebindWorkToTmdb(
    String workId,
    int tmdbId,
    TmdbMediaType mediaType, {
    bool writeIdToFolderName = false,
    bool resetManualLocks = false,
    bool markManualLocked = true,
  }) async {
    final existing = await _repository.findWorkById(workId);
    if (existing == null) {
      throw StateError('作品不存在: $workId');
    }

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

    GroupedWorkFolder? targetFolder;
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
          .toList();
      final grouped = await _computeWorker.groupFiles(
        sourceId: variants.first.sourceId,
        files: files,
      );
      if (grouped.isNotEmpty) {
        targetFolder = grouped.first;
      }
    }

    if (targetFolder != null) {
      final bgmRescue = _bangumiService == null
          ? const <BangumiSubjectCandidate>[]
          : await _candidateFetcher.fetchBangumiCandidates(
              targetFolder,
              extraQueries: [detail.title, ...detail.aliases.take(2)],
            );
      final matchDecision = await _computeWorker.evaluateMatch(
        targetFolder,
        [detail],
        bangumiCandidates: bgmRescue,
        mappingIndex: _mappingIndex,
      );
      final matchedSeason =
          matchDecision.matchedSeason ??
          targetFolder.seasonHint ??
          ScrapeDomainAdapter.fallbackResolveSeason(
            folder: targetFolder,
            detail: detail,
          ) ??
          existing.matchedSeason;
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
      final bundle = await _candidateFetcher.fetchSeasonBundle(
        detail.tmdbId,
        detail.mediaType,
        seasonsToFetch,
      );
      final seasonDetail = matchedSeason != null
          ? bundle.seasonDetails[matchedSeason]
          : null;

      final fanartEnrich = await _artworkEnricher.enrichTmdbDetail(
        detail: detail,
        seasonDetail: seasonDetail,
        matchedSeason: matchedSeason,
        bangumiCandidate: matchDecision.bestBangumi,
        priority: RequestPriority.interactive,
      );

      final built = ScrapeWorkPersister.buildMatchedWork(
        id: existing.id,
        detail: detail,
        folder: targetFolder,
        matchedSeason: matchedSeason,
        seasonDetail: seasonDetail,
        bangumiCandidate: matchDecision.bestBangumi,
        tvdbIdOverride: fanartEnrich.tvdbId,
        fanartPosterFallback: fanartEnrich.posterFallback,
        fanartBackdropOverride: fanartEnrich.backdropOverride,
        fanartLogoOverride: fanartEnrich.logoOverride,
        fallbackYear: existing.year,
        folderTmdbHint: tmdbId,
        isManualLocked: markManualLocked || existing.isManualLocked,
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
          ((preRemap?.hasInterspersedSpecialCandidate ?? false) ||
              bundle.episodes.isEmpty ||
              bundle.episodes.any((e) => e.title.trim().isEmpty));
      final bgmEpisodes = needBgmEpisodes
          ? await _candidateFetcher.fetchBangumiEpisodes(
              effectiveBgmId,
              type: null,
            )
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
      return updated;
    }

    final fanartFallback = await _artworkEnricher.enrichTmdbDetail(
      detail: detail,
      seasonDetail: null,
      matchedSeason: existing.matchedSeason,
      bangumiCandidate: null,
      priority: RequestPriority.interactive,
    );
    final builtFallback = ScrapeWorkPersister.buildMatchedWork(
      id: existing.id,
      detail: detail,
      tvdbIdOverride: fanartFallback.tvdbId,
      fanartPosterFallback: fanartFallback.posterFallback,
      fanartBackdropOverride: fanartFallback.backdropOverride,
      fanartLogoOverride: fanartFallback.logoOverride,
      fallbackYear: existing.year,
      folderTmdbHint: tmdbId,
      isManualLocked: markManualLocked || existing.isManualLocked,
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
      focusBangumiIds: {
        if ((updated.bangumiId ?? 0) > 0) updated.bangumiId!,
      },
      focusWorkIds: {updated.id},
      relationCache: _bangumiRelationCache,
    );
    return updated;
  }

  /// 详情页进入自动补全或点击重新抓取：为缺 `tmdbId`、`logoPath` 或无字横版背景的条目自动补绑并回填。
  Future<Work?> autoBindOrBackfillWorkTmdb(
    String workId, {
    bool interactive = false,
  }) async {
    final existing = await _repository.findWorkById(workId);
    if (existing == null) return null;

    if (existing.tmdbId != null && existing.tmdbMediaType != null) {
      if (interactive) {
        var rebound = await rebindWorkToTmdb(
          workId,
          existing.tmdbId!,
          existing.tmdbMediaType!,
        );
        final needsInteractiveLogoOrArt =
            _clearLogoResolver != null &&
            ((!rebound.logoLocked &&
                    (rebound.logoPath == null ||
                        rebound.logoPath!.trim().isEmpty ||
                        rebound.logoPath!.trim().startsWith('/'))) ||
                (!rebound.backdropLocked &&
                    (rebound.backdropPath == null ||
                        rebound.backdropPath!.trim().isEmpty)) ||
                (!rebound.posterLocked &&
                    (rebound.posterPath == null ||
                        rebound.posterPath!.trim().isEmpty)));
        if (needsInteractiveLogoOrArt) {
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
      final canUpgradeLogo =
          !existing.logoLocked &&
          existing.logoPath != null &&
          existing.logoPath!.trim().startsWith('/') &&
          (existing.logoNegativeMask &
                  ClearLogoNegativeMask.multiSourceUpgraded) ==
              0 &&
          _clearLogoResolver != null;
      final missingBackdrop =
          !existing.backdropLocked &&
          (existing.backdropPath == null ||
              existing.backdropPath!.trim().isEmpty);
      final missingPoster =
          !existing.posterLocked &&
          (existing.posterPath == null || existing.posterPath!.trim().isEmpty);
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
        final nextPoster = existing.posterLocked
            ? existing.posterPath
            : (missingPoster
                  ? (detail?.posterPath ??
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
        focusBangumiIds: {
          if ((updated.bangumiId ?? 0) > 0) updated.bangumiId!,
        },
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
      );
    }

    // 无 TMDB 匹配时仍支持刷新 Bangumi 元数据/分集及 Fanart.tv 封面/背景/透明徽标。
    return _refreshNonTmdbWork(
      existing,
      bgmSubject: rescueTarget,
      folder: folder,
      interactive: interactive,
    );
  }

  Future<Work?> _refreshNonTmdbWork(
    Work existing, {
    BangumiSubjectCandidate? bgmSubject,
    GroupedWorkFolder? folder,
    required bool interactive,
  }) async {
    final resolvedTvdbId =
        existing.tvdbId ??
        ScrapeArtworkEnricher.lookupOfflineTvdbId(
          mappingIndex: _mappingIndex,
          bangumiId: bgmSubject?.id ?? existing.bangumiId,
        );
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
    if (resolvedTvdbId != null &&
        _fanartService != null &&
        _fanartService.isConfigured &&
        (interactive || missingLogo || missingBackdrop || missingPoster)) {
      fanartBundle = await _artworkEnricher.fetchFanartBundleIfAvailable(
        mediaType: TmdbMediaType.tv,
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
    final fanartLogo = fanartBundle?.bestLogoUrl;

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
        : (missingPoster
              ? (nextBgmPoster ?? fanartPoster ?? existing.posterPath)
              : existing.posterPath);
    final nextBackdrop = existing.backdropLocked
        ? existing.backdropPath
        : (missingBackdrop
              ? (fanartBackdrop ?? existing.backdropPath)
              : existing.backdropPath);
    final nextLogo = existing.logoLocked
        ? existing.logoPath
        : (missingLogo ? (fanartLogo ?? existing.logoPath) : existing.logoPath);
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
          final classified = SourceAccessErrorClassifier.classify(
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
}

/// 单部作品目录刮削处理的内部返回值。
class _FolderProcessResult {
  const _FolderProcessResult({
    required this.status,
    required this.workId,
    required this.displayTitle,
    required this.didPersist,
    this.rescuedByHardRules = false,
    this.episodeSyncOnly = false,
  });

  final ScrapeStatus status;
  final String workId;
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
    required this.persistMutex,
  });

  final ScrapeComputeWorker computeWorker;
  final Map<String, Work> worksById;
  final Map<String, String> workIdByRelPath;
  final Map<String, MediaVariant> sourceVariantById;
  final Map<String, List<MediaVariant>> unlockedVariantsByWorkId;
  final _AsyncMutex persistMutex;
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
