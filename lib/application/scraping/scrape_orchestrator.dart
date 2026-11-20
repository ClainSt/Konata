import 'dart:async';
import 'dart:developer' as developer;
import '../../domain/formatting/network_error_sanitizer.dart';
import '../../domain/matching/directory_grouper.dart';
import '../../domain/matching/episode_remapper.dart';
import '../../domain/matching/work_matcher.dart';
import '../../domain/models/episode.dart';
import '../../domain/models/media_source.dart';
import '../../domain/models/media_variant.dart';
import '../../domain/models/tmdb_models.dart';
import '../../domain/models/work.dart';
import '../../domain/repositories/file_system_gateway.dart';
import '../../domain/repositories/library_repository.dart';
import '../../domain/scraping/bangumi_models.dart';
import '../../domain/scraping/bangumi_tmdb_index.dart';
import '../../domain/scraping/scrape_domain_adapter.dart';
import '../../infrastructure/cache/photos_storage.dart';
import '../../infrastructure/network/bangumi_service.dart';
import '../../infrastructure/network/priority_http_scheduler.dart';
import '../../infrastructure/network/tmdb_service.dart';
import '../../infrastructure/sources/directory_scanner.dart';
import '../../infrastructure/sources/source_access_error.dart';
import 'scrape_candidate_fetcher.dart';
import 'scrape_compute_worker.dart';
import 'scrape_match_resolver.dart';
import 'scrape_progress.dart';
import 'scrape_progress_tracker.dart';
import 'scrape_work_persister.dart';
import 'series_auto_linker.dart';

/// 进度状态回调。
typedef ScrapeProgressListener = void Function(ScrapeProgress progress);

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
    required this._gatewayBuilder,
    this._scanner = const DirectoryScanner(),
    this._computeWorker = const ScrapeComputeWorker(),
    this._photosStorage,
    this._mappingIndex,
    this._maxWorkConcurrency = defaultWorkConcurrency,
  }) : _repository = repository,
       _tmdbService = tmdbService,
       _bangumiService = bangumiService,
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
  }

  /// 阶段 3 跨作品并发刮削默认并发度（仅并发在线元数据请求，写库与进度串行保护）。
  static const int defaultWorkConcurrency = 5;

  final LibraryRepository _repository;
  final TmdbService _tmdbService;
  final BangumiService? _bangumiService;
  final PhotosStorage? _photosStorage;
  final BangumiTmdbIndex? _mappingIndex;
  final int _maxWorkConcurrency;
  final GatewayBuilder _gatewayBuilder;
  final DirectoryScanner _scanner;
  final ScrapeWorkPersister _persister;
  final ScrapeCandidateFetcher _candidateFetcher;
  final ScrapeComputeWorker _computeWorker;
  late final ScrapeMatchResolver _matchResolver;
  final Map<int, int> _tmdbCollectionIdByTmdbId = <int, int>{};

  /// 对指定媒体源执行完整的扫描 + 四段漏斗刮削流水线。
  Future<ScrapeProgress> scanAndScrapeSource(
    MediaSource source, {
    List<String>? scanRootsOverride,
    bool Function()? isCancelled,
    ScrapeProgressListener? onProgress,
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
      final scanResult = await _scanner.scan(
        gateway,
        scanRoots: effectiveRoots,
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

      final groupedWorksAll = await computeSession.groupFiles(
        sourceId: source.id,
        files: unlockedScanFiles,
        nfoByFolder: scanResult.nfoByFolder,
      );
      final ignoredFolders = (await _repository.getIgnoredFolders(source.id))
          .map((e) => e.trim().replaceAll('\\', '/'))
          .where((e) => e.isNotEmpty)
          .toSet();
      final groupedWorks = groupedWorksAll
          .where((folder) {
            final norm = folder.folderRelativePath.trim().replaceAll('\\', '/');
            return !ignoredFolders.any(
              (ig) => norm == ig || norm.startsWith('$ig/'),
            );
          })
          .toList(growable: false);

      emit(
        tracker.advance(
          phase: ScrapePhase.scraping,
          totalWorks: groupedWorks.length,
          processedWorks: 0,
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
          emit(tracker.advance(currentItemName: folder.cleanTitle));

          final ({ScrapeStatus status, String workId}) result;
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
          for (final v in folder.variants) {
            activeVariantIds.add(
              ScrapeWorkPersister.deterministicId(
                '${v.sourceId}::${v.relativePath}',
              ),
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

      // 支持全量与局部 scanRoots 范围修剪：非空 scopedRoots 仅清理对应目录前缀下的失联条目，绝不误删未选目录作品。
      await _repository.pruneStaleSourceEntries(
        sourceId: source.id,
        activeWorkIds: activeWorkIds,
        activeVariantIds: activeVariantIds,
        scopedRoots: effectiveRoots,
      );

      // 当局部扫描新入库的作品在同源范围外存在同身份/同名旧副本，且旧目录已在源端消失时，自动清除该幽灵重复作品。
      if (effectiveRoots.isNotEmpty && activeWorkIds.isNotEmpty) {
        await _pruneMovedOutOfScopeGhostWorks(
          gateway: gateway,
          sourceId: source.id,
          sourceKind: source.kind,
          newlyActiveWorkIds: activeWorkIds,
          scopedRoots: effectiveRoots,
        );
      }

      try {
        await SeriesAutoLinker.reconcileAll(
          repository: _repository,
          bangumiService: _bangumiService,
          tmdbService: _tmdbService,
          tmdbCollectionIdByTmdbId: _tmdbCollectionIdByTmdbId,
        );
      } catch (linkError) {
        if (!NetworkErrorSanitizer.isTransientNetworkError(linkError)) {
          rethrow;
        }
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

  Future<({ScrapeStatus status, String workId})> _processSingleFolderSafe(
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
        return (
          status: ScrapeStatus.needsReview,
          workId: ScrapeWorkPersister.deterministicId(
            '$sourceId::${folder.folderRelativePath}',
          ),
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
          return (status: existing.scrapeStatus, workId: workId);
        }
        final fallbackWork = Work(
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
        return (status: ScrapeStatus.needsReview, workId: workId);
      });
    }
  }

  Future<({ScrapeStatus status, String workId})> _processSingleFolder(
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

    // 增量重扫零请求快跳：已成功绑定 TMDB（或人工锁定）且目录物理文件集与字幕列表未发生变化、
    // 且未出现新的显式 ID/季提示时，直接沿用既有入库结果并跳过全部在线 API 与重复写库；
    // 仅命中 Bangumi 而缺少 TMDB ID 的非锁定条目仍允许重扫补绑，详情页也始终保留手动重抓入口。
    if (existing != null &&
        existing.scrapeStatus == ScrapeStatus.matched &&
        (existing.tmdbId != null || existing.isManualLocked) &&
        _canFastSkipUnchangedMatchedWork(
          existing: existing,
          folder: folder,
          existingUnlockedVariants:
              scanContext.unlockedVariantsByWorkId[existing.id] ?? const [],
        )) {
      return (status: existing.scrapeStatus, workId: workId);
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
        return (status: existing.scrapeStatus, workId: workId);
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
      return (status: existing.scrapeStatus, workId: workId);
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
        final bgmCandidates = await _candidateFetcher.fetchBangumiCandidates(
          folder,
          extraQueries: [detail.title, ...detail.aliases.take(2)],
        );
        final explicitDecision = await scanContext.computeWorker.evaluateMatch(
          folder,
          [detail],
          bangumiCandidates: bgmCandidates,
          mappingIndex: _mappingIndex,
        );
        if (isCancelled?.call() ?? false) {
          return (status: ScrapeStatus.unmatched, workId: workId);
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
        return (status: status, workId: workId);
      }
      // 仅在无网络异常（即双侧真实 404）时清除失效的 explicitTmdbId，防止网络故障误抹除目录显式提示。
      if (tmdbNetworkError == null) {
        effectiveFolder = folder.withoutExplicitTmdb();
      }
    }

    // 阶段 3：Bangumi 在线优先匹配 -> 离线映射直连快通道 -> 交叉关键词救回 TMDB 搜索 -> 合集父系列兜底 -> 双向互保重评。
    final resolution = await _matchResolver.resolve(
      effectiveFolder,
      tmdbUnavailable: tmdbNetworkError != null,
      computeWorker: scanContext.computeWorker,
    );
    if (isCancelled?.call() ?? false) {
      return (status: ScrapeStatus.unmatched, workId: workId);
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
      return (status: status, workId: workId);
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
      return (status: existing.scrapeStatus, workId: workId);
    }

    final fallbackBgmCandidate =
        decision.bestBangumi ??
        (tmdbNetworkError != null ? resolution.bestBangumi : null);
    if (decision.best == null && fallbackBgmCandidate != null) {
      final bgmStatus =
          (tmdbNetworkError == null && decision.level == MatchLevel.autoBind)
          ? ScrapeStatus.matched
          : ScrapeStatus.needsReview;
      final bgmReviewReason = tmdbNetworkError != null
          ? NetworkErrorSanitizer.toUserMessage(
              tmdbNetworkError!,
              prefix: 'TMDB 网络异常，已降级使用 Bangumi 元数据入库',
            )
          : decision.reviewReason;
      final work = ScrapeWorkPersister.buildBangumiOnlyWork(
        id: workId,
        folder: effectiveFolder,
        bangumiCandidate: fallbackBgmCandidate,
        status: bgmStatus,
        reviewReason: bgmReviewReason,
        isManualLocked: false,
        isHidden: existing?.keepHidden == true
            ? true
            : (existing?.isHidden ?? false),
        keepHidden: existing?.keepHidden ?? false,
      );
      final bgmEpisodes =
          (bgmStatus == ScrapeStatus.matched || tmdbNetworkError != null)
          ? await _candidateFetcher.fetchBangumiEpisodes(
              fallbackBgmCandidate.subject.id,
              type: null,
            )
          : const <BangumiEpisodeEntry>[];
      if (isCancelled?.call() ?? false) {
        return (status: bgmStatus, workId: workId);
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
      return (status: bgmStatus, workId: workId);
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
    return (status: status, workId: workId);
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

    final candidateWork = ScrapeWorkPersister.buildMatchedWork(
      id: workId,
      detail: effectiveDetail,
      folder: folder,
      matchedSeason: matchedSeason,
      seasonDetail: seasonDetail,
      bangumiCandidate: bangumiCandidate,
      fallbackYear: folder.year,
      folderTmdbHint: folder.explicitTmdbId,
      isManualLocked: isManualLocked,
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

  /// 判断已成功匹配的作品在增量重扫时其未锁定文件集是否完全未变化，允许零网络请求直接快跳。
  static bool _canFastSkipUnchangedMatchedWork({
    required Work existing,
    required GroupedWorkFolder folder,
    required List<MediaVariant> existingUnlockedVariants,
  }) {
    if (existingUnlockedVariants.isEmpty ||
        existingUnlockedVariants.length != folder.variants.length) {
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

    String signatureOf(MediaVariant v) {
      final subs = List<String>.of(v.externalSubtitles)..sort();
      return '${v.sourceId}\u0000${v.relativePath}\u0000${v.fileSize}\u0000'
          '${v.assetKind.index}\u0000${subs.join('\u0001')}';
    }

    final existingSigs = {for (final v in existingUnlockedVariants) signatureOf(v)};
    if (existingSigs.length != existingUnlockedVariants.length) {
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

      final built = ScrapeWorkPersister.buildMatchedWork(
        id: existing.id,
        detail: detail,
        folder: targetFolder,
        matchedSeason: matchedSeason,
        seasonDetail: seasonDetail,
        bangumiCandidate: matchDecision.bestBangumi,
        fallbackYear: existing.year,
        folderTmdbHint: tmdbId,
        isManualLocked: markManualLocked || existing.isManualLocked,
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
      developer.log('可恢复异常已记录', name: 'konata.scrape_orchestrator', error: error);
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
      );
      return updated;
    }

    final builtFallback = ScrapeWorkPersister.buildMatchedWork(
      id: existing.id,
      detail: detail,
      fallbackYear: existing.year,
      folderTmdbHint: tmdbId,
      isManualLocked: markManualLocked || existing.isManualLocked,
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
        return rebindWorkToTmdb(
          workId,
          existing.tmdbId!,
          existing.tmdbMediaType!,
        );
      }
      final missingLogo = existing.logoPath == null || existing.logoPath!.trim().isEmpty;
      final missingBackdrop =
          !existing.backdropLocked &&
          (existing.backdropPath == null || existing.backdropPath!.trim().isEmpty);
      if (!missingLogo && !missingBackdrop) {
        return existing;
      }
      final detail = await _tmdbService.getWorkDetail(
        existing.tmdbId!,
        existing.tmdbMediaType!,
        priority: RequestPriority.background,
      );
      if (detail == null) return existing;
      final nextLogo = missingLogo
          ? (detail.logoPath ?? existing.logoPath)
          : existing.logoPath;
      final canUpgradeRemoteBackdrop =
          !existing.backdropLocked &&
          (missingBackdrop ||
              (missingLogo &&
                  (existing.backdropPath?.startsWith('/') ?? false) &&
                  (detail.backdropPath?.trim().isNotEmpty ?? false)));
      final nextBackdrop = canUpgradeRemoteBackdrop
          ? (detail.backdropPath ?? existing.backdropPath)
          : existing.backdropPath;
      if (nextLogo == existing.logoPath && nextBackdrop == existing.backdropPath) {
        return existing;
      }
      final updated = existing.copyWith(
        logoPath: nextLogo,
        backdropPath: nextBackdrop,
      );
      await _repository.upsertWork(updated);
      await SeriesAutoLinker.reconcileAll(
        repository: _repository,
        bangumiService: _bangumiService,
        tmdbService: _tmdbService,
        tmdbCollectionIdByTmdbId: _tmdbCollectionIdByTmdbId,
      );
      return await _repository.findWorkById(workId) ?? updated;
    }

    if (!interactive && existing.metadataLocked) {
      return existing;
    }

    final variants = await _repository.getVariantsByWork(workId);
    final episodes = await _repository.getEpisodesByWork(workId);
    final mainEpNums = episodes
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
      final explicitDetail = await _candidateFetcher.fetchExplicitDetail(
        explicitFolder,
      );
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
      developer.log('可恢复异常已记录', name: 'konata.scrape_orchestrator', error: error);
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

    var candidates = await _candidateFetcher.fetchCandidateDetails(
      folder,
      bangumiCandidate: bgmEval.best,
      extraQueries: extraQueries,
    );
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
    }

    final best = decision.best;
    final allowBind =
        best != null &&
        (decision.level == MatchLevel.autoBind ||
            (existing.bangumiId != null &&
                decision.level != MatchLevel.unmatched) ||
            (interactive && decision.level != MatchLevel.unmatched));
    if (!allowBind) {
      return null;
    }
    return rebindWorkToTmdb(
      workId,
      best.detail.tmdbId,
      best.detail.mediaType,
      markManualLocked: interactive || existing.isManualLocked,
    );
  }

  /// 仅针对与本次新扫入作品同身份（相同 TMDB/Bangumi 或同名同文件）的同源旧作品核实源目录存活性，自动清理因目录改名产生的幽灵重复卡片。
  Future<void> _pruneMovedOutOfScopeGhostWorks({
    required MediaSourceGateway gateway,
    required String sourceId,
    required MediaSourceKind sourceKind,
    required Set<String> newlyActiveWorkIds,
    required List<String> scopedRoots,
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
      if (newlyActiveWorkIds.contains(w.id)) continue;
      final oldVars = variantsByWork[w.id];
      if (oldVars == null || oldVars.isEmpty) continue;
      if (oldVars.any((v) => v.workLocked || v.scopeLocked)) continue;

      // 确保该旧作品未关联其他媒体源且全部位于本次局部扫描范围之外
      final fullWorkVars = await _repository.getVariantsByWork(w.id);
      if (fullWorkVars.any((v) => v.sourceId != sourceId)) continue;
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
      if (!matchesAnyNewWork(w, oldVars)) continue;

      var allMissing = true;
      for (final d in outOfScopeDirs) {
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
