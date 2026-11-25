import 'dart:async';

import 'package:engine_scraping/engine_scraping.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';

import '../data/library_models.dart';
import 'work_manual_bind_helper.dart';

/// 作品管理与纠偏动作控制器（零 `Riverpod` 纯构造注入业务逻辑层）。
///
/// 职责边界：
/// - 隐藏与恢复作品显示；
/// - 软删除作品索引与清理本机 `photos/` 艺术图缓存（严格只读，绝不触碰或删除媒体源物理文件）；
/// - 作品跨源/同源手动合并、目标锁定与残余空壳软删除清理；
/// - 待复核作品重新匹配、人工跳过确认、TMDB 绑定、Bangumi 独立绑定与双源混合绑定；
/// - 任意库内写操作完成后通过 `DomainEventBus` 广播 `LibraryWorkChangedEvent`。
class WorkManagementController {
  /// 创建作品管理与纠偏控制器。
  WorkManagementController({
    required this.databases,
    required this.storageRoot,
    required this.scopedPrefs,
    required this.eventBus,
    required this.httpClient,
    required this.photosStorage,
    this.diagnosticLog,
    this.sourceDeviceId = '',
    this.pipelineOverride,
    this.tmdbServiceOverride,
    this.bangumiServiceOverride,
    int Function()? nowMs,
  }) : _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch),
       _repository = StorageScrapeRepository(
         databases,
         sourceDeviceId: sourceDeviceId,
         nowMs: nowMs,
       ) {
    _bindHelper = WorkManualBindHelper(
      repository: _repository,
      httpClient: httpClient,
      tmdbServiceOverride: tmdbServiceOverride,
      bangumiServiceOverride: bangumiServiceOverride,
    );
  }

  /// 三库合一存储句柄。
  final KonataDatabaseBundle databases;

  /// 应用便携存储根目录端口。
  final StorageRootPort storageRoot;

  /// 分作用域配置存储。
  final ScopedPrefsStore scopedPrefs;

  /// 跨模块领域事件总线。
  final DomainEventBus eventBus;

  /// 受控 HTTP 客户端端口。
  final KonataHttpClientPort httpClient;

  /// 本机艺术图管理存储（仅清理缓存，不涉及源文件）。
  final PhotosStorage photosStorage;

  /// 可选诊断日志端口。
  final DiagnosticLogPort? diagnosticLog;

  /// 当前设备标识。
  final String sourceDeviceId;

  /// 可选测试替换用刮削管线。
  final ScrapePipeline? pipelineOverride;

  /// 可选测试替换用 TMDB 客户端。
  final TmdbService? tmdbServiceOverride;

  /// 可选测试替换用 Bangumi 客户端。
  final BangumiService? bangumiServiceOverride;

  final int Function() _nowMs;
  final StorageScrapeRepository _repository;
  late final WorkManualBindHelper _bindHelper;

  /// 软删除作品记录及本机 `photos/` 艺术图缓存（严禁删除媒体源物理视频或文件）。
  ///
  /// 若 [ignoreFolderOnRescan] 为 `true`，同步将其所有版本所在目录加入媒体源忽略目录清单，
  /// 防止后续增量扫描再次将已删除目录自动刮入库。
  Future<void> deleteWork(
    String workId, {
    bool ignoreFolderOnRescan = false,
  }) async {
    final now = _nowMs();
    final variants = await _repository.getVariantsByWork(workId);
    final episodes = await _repository.getEpisodesByWork(workId);

    final ignoredPairs = <(String sourceId, String relFolder)>{};
    if (ignoreFolderOnRescan) {
      for (final variant in variants) {
        final relFolder = _extractParentFolder(variant.relativePath);
        if (relFolder.isNotEmpty) {
          ignoredPairs.add((variant.sourceId, relFolder));
        }
      }
      for (final pair in ignoredPairs) {
        await _repository.addIgnoredFolder(pair.$1, pair.$2);
      }
    }

    for (final v in variants) {
      databases.library.mediaVariants.softDelete(
        VariantId.trusted(v.id),
        deletedAtMs: now,
        sourceDeviceId: sourceDeviceId,
      );
    }
    for (final ep in episodes) {
      databases.library.episodes.softDelete(
        EpisodeId.trusted(ep.id),
        deletedAtMs: now,
        sourceDeviceId: sourceDeviceId,
      );
    }
    databases.library.works.softDelete(
      WorkId.trusted(workId),
      deletedAtMs: now,
      sourceDeviceId: sourceDeviceId,
    );
    await _repository.clearScrapeCandidates(workId);
    await photosStorage.deleteWorkPhotos(workId);

    for (final sourceId in ignoredPairs.map((e) => e.$1).toSet()) {
      eventBus.publish(
        MediaSourceChangedEvent(
          sourceId: SourceId.trusted(sourceId),
          reason: 'ignored_folder_added',
          occurredAtMs: now,
        ),
      );
    }
    _publishWorkChanged(workId, 'deleted');
  }

  /// 将源作品 [sourceWorkId] 下全部物理文件与分集合并至 [targetWorkId] 并写入归属锁。
  ///
  /// 合并完成后若源作品无剩余文件则以软删除墓碑移出媒体库，绝不删除任何物理文件。
  Future<WorkMergeOutcome> mergeWorkIntoTarget({
    required String sourceWorkId,
    required String targetWorkId,
    MergeVideoCategoryMode categoryMode = MergeVideoCategoryMode.preserve,
    List<String>? onlyVariantIds,
  }) async {
    if (sourceWorkId == targetWorkId) {
      throw ArgumentError('源作品与目标作品不能相同');
    }
    final sourceWork = await _repository.findWorkById(sourceWorkId);
    final targetWork = await _repository.findWorkById(targetWorkId);
    if (sourceWork == null || targetWork == null) {
      throw StateError('待合并的作品或目标作品不存在');
    }

    final now = _nowMs();
    final sourceEpisodes = await _repository.getEpisodesByWork(sourceWorkId);
    final sourceVariants = await _repository.getVariantsByWork(sourceWorkId);
    final targetEpisodes = await _repository.getEpisodesByWork(targetWorkId);
    final selectedIdSet = onlyVariantIds?.toSet();
    final variantsToMove = selectedIdSet == null
        ? sourceVariants
        : sourceVariants
              .where((variant) => selectedIdSet.contains(variant.id))
              .toList(growable: false);
    if (variantsToMove.isEmpty) {
      throw StateError('未选中任何可迁移的视频文件');
    }

    final remainingVariants = selectedIdSet == null
        ? const <MediaVariant>[]
        : sourceVariants
              .where((variant) => !selectedIdSet.contains(variant.id))
              .toList(growable: false);
    final moveAllSource = remainingVariants.isEmpty;

    final targetEpBySlot = <String, Episode>{
      for (final ep in targetEpisodes) _episodeSlotKey(ep): ep,
    };
    final sourceEpById = <String, Episode>{
      for (final ep in sourceEpisodes) ep.id: ep,
    };
    final referencedEpIds = <String>{
      for (final v in variantsToMove)
        if (v.episodeId != null) v.episodeId!,
    };
    final episodesToMigrate = moveAllSource
        ? sourceEpisodes
        : sourceEpisodes
              .where((ep) => referencedEpIds.contains(ep.id))
              .toList(growable: false);

    var movedEpisodes = 0;
    final remappedEpisodeIds = <String, String>{};
    for (final srcEp in episodesToMigrate) {
      final adjustedCategory = switch (categoryMode) {
        MergeVideoCategoryMode.preserve => srcEp.category,
        MergeVideoCategoryMode.asExtra => EpisodeCategory.extra,
        MergeVideoCategoryMode.asMain => EpisodeCategory.main,
      };
      final adjustedExtraType = switch (categoryMode) {
        MergeVideoCategoryMode.preserve => srcEp.extraType,
        MergeVideoCategoryMode.asExtra => srcEp.extraType ?? ExtraKind.sp,
        MergeVideoCategoryMode.asMain => null,
      };
      final adjustedSeason = switch (categoryMode) {
        MergeVideoCategoryMode.preserve => srcEp.seasonNumber,
        MergeVideoCategoryMode.asExtra => 0,
        MergeVideoCategoryMode.asMain => targetWork.matchedSeason ?? 1,
      };
      final adjustedTemplate = Episode(
        id: srcEp.id,
        workId: targetWorkId,
        seasonNumber: adjustedSeason,
        episodeNumber: srcEp.episodeNumber,
        episodeNumberEnd: srcEp.episodeNumberEnd,
        category: adjustedCategory,
        extraType: adjustedExtraType,
        title: srcEp.title,
        overview: srcEp.overview,
        stillPath: srcEp.stillPath,
      );
      final slotKey = _episodeSlotKey(adjustedTemplate);
      final existingTarget = targetEpBySlot[slotKey];
      if (existingTarget != null) {
        remappedEpisodeIds[srcEp.id] = existingTarget.id;
      } else {
        final newEpId = ScrapeWorkPersister.deterministicId(
          '$targetWorkId::merged::$slotKey',
        );
        final copied = Episode(
          id: newEpId,
          workId: targetWorkId,
          seasonNumber: adjustedSeason,
          episodeNumber: srcEp.episodeNumber,
          episodeNumberEnd: srcEp.episodeNumberEnd,
          category: adjustedCategory,
          extraType: adjustedExtraType,
          title: srcEp.title,
          overview: srcEp.overview,
          stillPath: srcEp.stillPath,
        );
        await _repository.upsertEpisode(copied);
        targetEpBySlot[slotKey] = copied;
        remappedEpisodeIds[srcEp.id] = newEpId;
        movedEpisodes++;
      }
    }

    var movedVariants = 0;
    for (final variant in variantsToMove) {
      final oldEpId = variant.episodeId;
      var newEpId = oldEpId != null
          ? (remappedEpisodeIds[oldEpId] ??
                (sourceEpById.containsKey(oldEpId) ? null : oldEpId))
          : null;
      if (newEpId == null && categoryMode != MergeVideoCategoryMode.preserve) {
        final forcedCat = categoryMode == MergeVideoCategoryMode.asExtra
            ? EpisodeCategory.extra
            : EpisodeCategory.main;
        final forcedSeason = forcedCat == EpisodeCategory.extra
            ? 0
            : (targetWork.matchedSeason ?? 1);
        final forcedEp = Episode(
          id: ScrapeWorkPersister.deterministicId(
            '$targetWorkId::merged_var::${variant.id}',
          ),
          workId: targetWorkId,
          seasonNumber: forcedSeason,
          episodeNumber: forcedCat == EpisodeCategory.extra
              ? null
              : (movedVariants + 1),
          category: forcedCat,
          extraType: forcedCat == EpisodeCategory.extra ? ExtraKind.sp : null,
          title: variant.fileName,
        );
        await _repository.upsertEpisode(forcedEp);
        newEpId = forcedEp.id;
        movedEpisodes++;
      }
      await _repository.upsertMediaVariant(
        variant.copyWith(
          workId: targetWorkId,
          episodeId: newEpId,
          clearEpisodeId: newEpId == null,
          workLocked: true,
        ),
      );
      movedVariants++;
    }

    final enrichedTarget = targetWork.copyWith(
      originalTitle:
          (targetWork.originalTitle == null ||
              targetWork.originalTitle!.trim().isEmpty)
          ? sourceWork.originalTitle
          : targetWork.originalTitle,
      overview:
          (targetWork.overview == null || targetWork.overview!.trim().isEmpty)
          ? sourceWork.overview
          : targetWork.overview,
      posterPath:
          (targetWork.posterPath == null ||
              targetWork.posterPath!.trim().isEmpty)
          ? sourceWork.posterPath
          : targetWork.posterPath,
      backdropPath:
          (targetWork.backdropPath == null ||
              targetWork.backdropPath!.trim().isEmpty)
          ? sourceWork.backdropPath
          : targetWork.backdropPath,
      bangumiId: targetWork.bangumiId ?? sourceWork.bangumiId,
      bangumiScore: targetWork.bangumiScore ?? sourceWork.bangumiScore,
      isManualLocked: true,
      scrapeStatus: ScrapeStatus.matched,
      clearReviewReason: true,
    );
    await _repository.upsertWork(enrichedTarget);

    if (moveAllSource) {
      for (final srcEp in sourceEpisodes) {
        databases.library.episodes.softDelete(
          EpisodeId.trusted(srcEp.id),
          deletedAtMs: now,
          sourceDeviceId: sourceDeviceId,
        );
      }
      databases.library.works.softDelete(
        WorkId.trusted(sourceWorkId),
        deletedAtMs: now,
        sourceDeviceId: sourceDeviceId,
      );
      await _repository.clearScrapeCandidates(sourceWorkId);
      await photosStorage.mergeWorkPhotos(
        sourceWorkId: sourceWorkId,
        targetWorkId: targetWorkId,
        targetTitle: enrichedTarget.title,
      );
    } else {
      final keptEpIds = <String>{
        for (final v in remainingVariants)
          if (v.episodeId != null) v.episodeId!,
      };
      for (final srcEp in sourceEpisodes) {
        if (!keptEpIds.contains(srcEp.id)) {
          databases.library.episodes.softDelete(
            EpisodeId.trusted(srcEp.id),
            deletedAtMs: now,
            sourceDeviceId: sourceDeviceId,
          );
        }
      }
    }

    try {
      await SeriesAutoLinker.reconcileAll(
        repository: _repository,
        focusBangumiIds: {
          if ((enrichedTarget.bangumiId ?? 0) > 0) enrichedTarget.bangumiId!,
        },
        focusWorkIds: {targetWorkId},
      );
    } catch (_) {}

    _publishWorkChanged(targetWorkId, 'merged_target');
    _publishWorkChanged(
      sourceWorkId,
      moveAllSource ? 'merged_source_deleted' : 'merged_source_split',
    );

    final latestTarget =
        (await _repository.findWorkById(targetWorkId)) ?? enrichedTarget;
    return WorkMergeOutcome(
      targetWork: latestTarget,
      movedVariantCount: movedVariants,
      movedEpisodeCount: movedEpisodes,
      sourceDeleted: moveAllSource,
    );
  }

  /// 将指定的部分视频文件从原作品拆分出来，创建待绑定独立作品并返回新作品主键。
  Future<String> splitVariantsToIndependentWork({
    required String sourceWorkId,
    required List<String> variantIds,
    String? initialTitle,
  }) async {
    final sourceWork = await _repository.findWorkById(sourceWorkId);
    if (sourceWork == null) {
      throw StateError('原作品不存在: $sourceWorkId');
    }
    final allVariants = await _repository.getVariantsByWork(sourceWorkId);
    final selectedSet = variantIds.toSet();
    final selectedVariants = allVariants
        .where((v) => selectedSet.contains(v.id))
        .toList(growable: false);
    if (selectedVariants.isEmpty) {
      throw StateError('请先选择至少一个视频文件');
    }
    final now = _nowMs();
    final derivedDir = MediaDisplayFormatter.extractParentDirectory(
      selectedVariants.first.relativePath,
    );
    final folderTail = derivedDir.contains('/')
        ? derivedDir.split('/').last
        : derivedDir;
    final cleanTitle = (initialTitle != null && initialTitle.trim().isNotEmpty)
        ? initialTitle.trim()
        : (folderTail.isNotEmpty ? folderTail : sourceWork.title);
    final newWorkId = ScrapeWorkPersister.deterministicId(
      '$sourceWorkId::split::$now::${variantIds.join(",")}',
    );
    final splitWork = Work(
      id: newWorkId,
      title: cleanTitle,
      year: sourceWork.year,
      scrapeStatus: ScrapeStatus.needsReview,
    );
    await _repository.upsertWork(splitWork);
    for (final v in selectedVariants) {
      await _repository.upsertMediaVariant(
        v.copyWith(workId: newWorkId, clearEpisodeId: true, workLocked: true),
      );
    }

    final remaining = allVariants
        .where((v) => !selectedSet.contains(v.id))
        .toList(growable: false);
    final sourceEpisodes = await _repository.getEpisodesByWork(sourceWorkId);
    if (remaining.isEmpty) {
      for (final ep in sourceEpisodes) {
        databases.library.episodes.softDelete(
          EpisodeId.trusted(ep.id),
          deletedAtMs: now,
          sourceDeviceId: sourceDeviceId,
        );
      }
      databases.library.works.softDelete(
        WorkId.trusted(sourceWorkId),
        deletedAtMs: now,
        sourceDeviceId: sourceDeviceId,
      );
      await _repository.clearScrapeCandidates(sourceWorkId);
    } else {
      final keptEpIds = <String>{
        for (final v in remaining)
          if (v.episodeId != null) v.episodeId!,
      };
      for (final ep in sourceEpisodes) {
        if (!keptEpIds.contains(ep.id)) {
          databases.library.episodes.softDelete(
            EpisodeId.trusted(ep.id),
            deletedAtMs: now,
            sourceDeviceId: sourceDeviceId,
          );
        }
      }
    }

    _publishWorkChanged(sourceWorkId, 'split_source');
    _publishWorkChanged(newWorkId, 'split_created');
    return newWorkId;
  }

  /// 将待复核条目人工确认放行（转为已匹配并锁定人工标记）。
  Future<Work> dismissWorkReview(String workId) async {
    final existing = await _repository.findWorkById(workId);
    if (existing == null) {
      throw StateError('作品不存在: $workId');
    }
    final updated = existing.copyWith(
      scrapeStatus: ScrapeStatus.matched,
      isManualLocked: true,
      clearReviewReason: true,
    );
    await _repository.upsertWork(updated);
    await _repository.clearScrapeCandidates(workId);
    _publishWorkChanged(workId, 'review_dismissed');
    return updated;
  }

  /// 为指定作品执行纯 TMDB 重新绑定并可选写入人工锁定。
  Future<Work> bindWorkToTmdb({
    required String workId,
    required int tmdbId,
    required TmdbMediaType mediaType,
    bool writeIdToFolderName = false,
    bool markManualLocked = true,
    bool resetManualLocks = false,
  }) async {
    final pipeline = await _createPipeline();
    final rebound = await pipeline.rebindWorkToTmdb(
      workId,
      tmdbId,
      mediaType,
      writeIdToFolderName: writeIdToFolderName,
      markManualLocked: markManualLocked,
      resetManualLocks: resetManualLocks,
    );
    _publishWorkChanged(workId, 'manual_tmdb_bound');
    return rebound;
  }

  /// 对待复核作品发起交互式重新自动匹配。
  Future<RematchWorkResult> rematchReviewWork(String workId) async {
    final pipeline = await _createPipeline();
    final result = await pipeline.rematchReviewWork(workId);
    _publishWorkChanged(workId, 'rematched');
    return result;
  }

  /// 执行 Bangumi 独立条目 × TMDB 母系列双源混合绑定并写入永久人工锁。
  Future<Work> bindWorkHybrid({
    required String workId,
    required HybridMatchRequest request,
  }) async {
    final updated = await _bindHelper.executeHybridBind(
      workId: workId,
      request: request,
    );
    _publishWorkChanged(workId, 'hybrid_bound');
    return updated;
  }

  /// 将作品绑定到纯 Bangumi 条目（不强绑 TMDB），并静默尝试补齐高清背景图。
  Future<Work> bindWorkBangumiOnly({
    required String workId,
    required BangumiSubjectCandidate bangumiSubject,
  }) async {
    final updated = await _bindHelper.executeBangumiOnlyBind(
      workId: workId,
      bangumiSubject: bangumiSubject,
    );
    _publishWorkChanged(workId, 'bangumi_only_bound');
    return updated;
  }

  /// 查询指定待复核作品已落盘的推荐候选摘要列表。
  Future<List<ScrapeCandidateSummary>> getScrapeCandidates(String workId) {
    return _repository.getScrapeCandidates(workId);
  }

  /// 查询指定作品名下全部物理文件变体。
  Future<List<MediaVariant>> getVariantsByWork(String workId) {
    return _repository.getVariantsByWork(workId);
  }

  /// 根据媒体源 ID 查找媒体源显示信息，供源文件与待复核弹窗展示来源标签。
  Future<Map<String, MediaSource>> loadSourcesById() async {
    final sources = await _repository.getMediaSources();
    return <String, MediaSource>{for (final s in sources) s.id: s};
  }

  /// 交互式检索 TMDB 作品候选（供手动匹配弹窗搜索使用）。
  Future<List<TmdbSearchResult>> searchTmdb(
    String query, {
    int? year,
    TmdbMediaType? mediaType,
  }) {
    final tmdb = tmdbServiceOverride ?? TmdbService(httpClient: httpClient);
    return tmdb.searchAnime(
      query,
      year: year,
      mediaTypeFilter: mediaType,
      priority: RequestPriority.interactive,
    );
  }

  /// 获取 TMDB 作品完整季集详情。
  Future<TmdbWorkDetail?> fetchTmdbDetail(int tmdbId, TmdbMediaType mediaType) {
    final tmdb = tmdbServiceOverride ?? TmdbService(httpClient: httpClient);
    return tmdb.getWorkDetail(
      tmdbId,
      mediaType,
      priority: RequestPriority.interactive,
    );
  }

  /// 获取 TMDB 指定季的分集列表与单季详情（供混合匹配选季拉取）。
  Future<TmdbSeasonDetail?> fetchTmdbSeasonDetail(
    int tmdbId,
    int seasonNumber,
  ) {
    final tmdb = tmdbServiceOverride ?? TmdbService(httpClient: httpClient);
    return tmdb.getSeasonDetail(
      tmdbId,
      seasonNumber,
      priority: RequestPriority.interactive,
    );
  }

  /// 交互式检索 Bangumi 动画条目候选。
  Future<List<BangumiSubjectCandidate>> searchBangumi(String query) {
    final bgm =
        bangumiServiceOverride ?? BangumiService(httpClient: httpClient);
    return bgm.searchSubjects(query, priority: RequestPriority.interactive);
  }

  Future<ScrapePipeline> _createPipeline() async {
    if (pipelineOverride != null) return pipelineOverride!;
    BangumiTmdbIndex? index;
    try {
      final updater = BangumiTmdbMapUpdater(
        storageRoot: storageRoot,
        prefsStore: scopedPrefs,
      );
      index = (await updater.loadActiveSnapshot()).index;
    } catch (_) {
      index = null;
    }
    final tmdb = tmdbServiceOverride ?? TmdbService(httpClient: httpClient);
    final bgm =
        bangumiServiceOverride ?? BangumiService(httpClient: httpClient);
    final fanart = FanartService(httpClient: httpClient);
    final clearLogo = ClearLogoResolver(
      tmdbService: tmdb,
      fanartService: fanart,
      networkConfig: httpClient.config,
      mappingIndex: index,
    );
    return ScrapePipeline(
      repository: _repository,
      tmdbService: tmdb,
      bangumiService: bgm,
      fanartService: fanart,
      clearLogoResolver: clearLogo,
      gatewayBuilder: (_) => throw StateError('手工绑定与复核流程不打开远程文件读取流'),
      photosStorage: StorageRootWorkArtworkStorage(storageRoot: storageRoot),
      mappingIndex: index,
      diagnosticLog: diagnosticLog,
      eventBus: eventBus,
    );
  }

  void _publishWorkChanged(String workId, String reason) {
    eventBus.publish(
      LibraryWorkChangedEvent(
        workId: WorkId.trusted(workId),
        reason: reason,
        occurredAtMs: _nowMs(),
      ),
    );
  }

  static String _extractParentFolder(String relativePath) {
    final norm = relativePath.trim().replaceAll('\\', '/');
    final slash = norm.lastIndexOf('/');
    if (slash <= 0) return '';
    return norm.substring(0, slash);
  }

  static String _episodeSlotKey(Episode ep) {
    return '${ep.category.name}:${ep.seasonNumber}:${ep.episodeNumber ?? 'u'}:${ep.extraType?.name ?? ''}';
  }
}
