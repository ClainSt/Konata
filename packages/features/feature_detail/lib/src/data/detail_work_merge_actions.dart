import 'dart:developer' as developer;

import 'package:engine_scraping/engine_scraping.dart';
import 'package:konata_storage/konata_storage.dart';

import 'detail_edit_models.dart';

/// 作品合并、文件拆分归档、双源混合绑定及纯 `Bangumi` 绑定底层执行助手（零 Riverpod）。
abstract final class DetailWorkMergeHelper {
  /// 将整部作品或指定变体迁移至已有作品并整理剧集与播放记录。
  static Future<WorkMergeOutcome> mergeWorkIntoExisting({
    required LibraryRepository repository,
    required PhotosStorage photosStorage,
    required String sourceWorkId,
    required String targetWorkId,
    EpisodeCategory? forceCategory,
  }) async {
    if (sourceWorkId == targetWorkId) {
      throw ArgumentError('源作品与目标作品不能相同');
    }
    final sourceWork = await repository.findWorkById(sourceWorkId);
    if (sourceWork == null) {
      throw StateError('待合并原作品不存在: $sourceWorkId');
    }
    final targetWork = await repository.findWorkById(targetWorkId);
    if (targetWork == null) {
      throw StateError('目标作品不存在: $targetWorkId');
    }

    final sourceVariants = await repository.getVariantsByWork(sourceWorkId);
    final outcome = await _transferVariantsToTarget(
      repository: repository,
      sourceWorkId: sourceWorkId,
      targetWork: targetWork,
      variantsToMove: sourceVariants,
      forceCategory: forceCategory,
      avoidExtraSlotCollision: true,
    );
    await photosStorage.mergeWorkPhotos(
      sourceWorkId: sourceWorkId,
      targetWorkId: outcome.targetWork.id,
      targetTitle: outcome.targetWork.title,
    );
    await repository.clearScrapeCandidates(sourceWorkId);
    await repository.deleteOrphanEpisodes(sourceWorkId);
    if (!outcome.sourceWorkDeleted) {
      await repository.deleteWork(sourceWorkId);
    }
    return WorkMergeOutcome(
      targetWork: outcome.targetWork,
      movedVariantCount: sourceVariants.length,
      sourceWorkDeleted: true,
      sourceWorkId: sourceWorkId,
    );
  }

  /// 将勾选的物理文件迁移至库内其他作品，若原条目无剩余文件则自动清理空壳。
  static Future<WorkMergeOutcome> moveVariantsToExistingWork({
    required LibraryRepository repository,
    required PhotosStorage photosStorage,
    required String sourceWorkId,
    required List<String> variantIds,
    required String targetWorkId,
    required EpisodeCategory targetCategory,
  }) async {
    if (sourceWorkId == targetWorkId) {
      throw ArgumentError('不能迁移至当前所属作品');
    }
    final targetWork = await repository.findWorkById(targetWorkId);
    if (targetWork == null) {
      throw StateError('目标作品不存在: $targetWorkId');
    }
    final sourceVariants = await repository.getVariantsByWork(sourceWorkId);
    final idSet = variantIds.toSet();
    final selected = sourceVariants
        .where((v) => idSet.contains(v.id))
        .toList(growable: false);
    if (selected.isEmpty) {
      throw StateError('未选中有效的物理媒体文件');
    }
    final outcome = await _transferVariantsToTarget(
      repository: repository,
      sourceWorkId: sourceWorkId,
      targetWork: targetWork,
      variantsToMove: selected,
      forceCategory: targetCategory,
      avoidExtraSlotCollision: targetCategory == EpisodeCategory.extra,
    );
    if (outcome.sourceWorkDeleted) {
      await photosStorage.mergeWorkPhotos(
        sourceWorkId: sourceWorkId,
        targetWorkId: outcome.targetWork.id,
        targetTitle: outcome.targetWork.title,
      );
      await photosStorage.deleteWorkPhotos(sourceWorkId);
    }
    return outcome;
  }

  /// 绑定作品为纯 `Bangumi` 独立条目（无需 `TMDB`）并加锁。
  static Future<Work> bindWorkBangumiOnly({
    required LibraryRepository repository,
    required PhotosStorage photosStorage,
    required BangumiService bangumiService,
    required String workId,
    required BangumiSubjectCandidate bangumiSubject,
  }) async {
    final existing = await repository.findWorkById(workId);
    if (existing == null) {
      throw StateError('作品不存在: $workId');
    }
    var subject = bangumiSubject;
    if (subject.score == null ||
        (subject.summary == null || subject.summary!.trim().isEmpty) ||
        subject.posterUrl == null) {
      try {
        final full = await bangumiService.getSubjectDetail(
          subject.id,
          priority: RequestPriority.interactive,
        );
        if (full != null) subject = full;
      } catch (error) {
        developer.log(
          '补充 Bangumi 详情失败，继续使用既有摘要',
          name: 'konata.detail_work_merge_actions',
          error: error,
        );
      }
    }

    var bgmEpisodes = const <BangumiEpisodeEntry>[];
    try {
      bgmEpisodes = await bangumiService.getSubjectEpisodes(
        subject.id,
        type: null,
        priority: RequestPriority.interactive,
      );
    } catch (error) {
      developer.log(
        '拉取 Bangumi 剧集失败，继续本地映射',
        name: 'konata.detail_work_merge_actions',
        error: error,
      );
    }

    final updated = existing.copyWith(
      bangumiId: subject.id,
      title: subject.displayTitle,
      originalTitle: subject.name.isNotEmpty
          ? subject.name
          : existing.originalTitle,
      year: subject.year ?? existing.year,
      overview: (subject.summary != null && subject.summary!.trim().isNotEmpty)
          ? subject.summary!.trim()
          : existing.overview,
      posterPath: subject.posterUrl ?? existing.posterPath,
      bangumiPosterPath: subject.posterUrl ?? existing.bangumiPosterPath,
      bangumiScore: subject.score ?? existing.bangumiScore,
      isManualLocked: true,
      metadataLocked: true,
      clearReviewReason: true,
      scrapeStatus: ScrapeStatus.matched,
    );
    await repository.upsertWork(updated);
    await repository.clearScrapeCandidates(workId);
    await _syncBangumiOnlyEpisodes(
      repository: repository,
      work: updated,
      bgmEpisodes: bgmEpisodes,
    );
    await SeriesAutoLinker.reconcileAll(
      repository: repository,
      bangumiService: bangumiService,
      focusBangumiIds: {if ((updated.bangumiId ?? 0) > 0) updated.bangumiId!},
      focusWorkIds: {updated.id},
    );
    await photosStorage.renameWorkFolderIfNeeded(updated.id, updated.title);
    return (await repository.findWorkById(workId)) ?? updated;
  }

  /// 执行 `Bangumi` 独立条目与 `TMDB` 指定季/集的双源混合绑定。
  static Future<Work> bindWorkHybrid({
    required LibraryRepository repository,
    required PhotosStorage photosStorage,
    required TmdbService tmdbService,
    required BangumiService bangumiService,
    required String workId,
    required HybridMatchRequest request,
  }) async {
    final existing = await repository.findWorkById(workId);
    if (existing == null) {
      throw StateError('作品不存在: $workId');
    }
    var subject = request.bangumiSubject;
    if (subject.score == null ||
        (subject.summary == null || subject.summary!.trim().isEmpty) ||
        subject.posterUrl == null) {
      try {
        final full = await bangumiService.getSubjectDetail(
          subject.id,
          priority: RequestPriority.interactive,
        );
        if (full != null) subject = full;
      } catch (error) {
        developer.log(
          '补充 Bangumi 详情失败，继续混合绑定',
          name: 'konata.detail_work_merge_actions',
          error: error,
        );
      }
    }

    final tmdbDetail = request.tmdbDetail;
    TmdbSeasonDetail? seasonDetail;
    if (tmdbDetail.mediaType == TmdbMediaType.tv) {
      try {
        seasonDetail = await tmdbService.getSeasonDetail(
          tmdbDetail.tmdbId,
          request.tmdbSeasonNumber,
          priority: RequestPriority.interactive,
        );
      } catch (error) {
        developer.log(
          '拉取 TMDB 目标季详情失败，按纯信息降级绑定',
          name: 'konata.detail_work_merge_actions',
          error: error,
        );
      }
    }

    var bgmEpisodes = const <BangumiEpisodeEntry>[];
    try {
      bgmEpisodes = await bangumiService.getSubjectEpisodes(
        subject.id,
        type: null,
        priority: RequestPriority.interactive,
      );
    } catch (error) {
      developer.log(
        '拉取 Bangumi 剧集失败，继续 TMDB 单集标题匹配',
        name: 'konata.detail_work_merge_actions',
        error: error,
      );
    }

    final updated = existing.copyWith(
      tmdbId: tmdbDetail.tmdbId,
      tmdbMediaType: tmdbDetail.mediaType,
      bangumiId: subject.id,
      tvdbId: tmdbDetail.tvdbId ?? existing.tvdbId,
      matchedSeason: tmdbDetail.mediaType == TmdbMediaType.tv
          ? request.tmdbSeasonNumber
          : null,
      title: subject.displayTitle,
      originalTitle: subject.name.isNotEmpty
          ? subject.name
          : (tmdbDetail.originalTitle ?? existing.originalTitle),
      year: subject.year ?? tmdbDetail.year ?? existing.year,
      overview: (subject.summary != null && subject.summary!.trim().isNotEmpty)
          ? subject.summary!.trim()
          : (tmdbDetail.overview ?? existing.overview),
      posterPath:
          subject.posterUrl ?? tmdbDetail.posterPath ?? existing.posterPath,
      bangumiPosterPath: subject.posterUrl ?? existing.bangumiPosterPath,
      backdropPath: tmdbDetail.backdropPath ?? existing.backdropPath,
      logoPath: tmdbDetail.logoPath ?? existing.logoPath,
      voteAverage: tmdbDetail.voteAverage ?? existing.voteAverage,
      bangumiScore: subject.score ?? existing.bangumiScore,
      isManualLocked: true,
      metadataLocked: true,
      clearReviewReason: true,
      scrapeStatus: ScrapeStatus.matched,
    );
    await repository.upsertWork(updated);
    await repository.clearScrapeCandidates(workId);
    await _syncHybridEpisodesAndVariants(
      repository: repository,
      work: updated,
      seasonDetail: seasonDetail,
      bgmEpisodes: bgmEpisodes,
      tmdbSeasonNumber: request.tmdbSeasonNumber,
      startEpisodeNumber: request.startEpisodeNumber,
      customSlotsByVariantId: request.customSlotsByVariantId,
    );
    await SeriesAutoLinker.reconcileAll(
      repository: repository,
      bangumiService: bangumiService,
      tmdbCollectionIdByTmdbId: {
        if (tmdbDetail.collectionId != null && tmdbDetail.collectionId! > 0)
          tmdbDetail.tmdbId: tmdbDetail.collectionId!,
      },
      focusBangumiIds: {if ((updated.bangumiId ?? 0) > 0) updated.bangumiId!},
      focusWorkIds: {updated.id},
    );
    await photosStorage.renameWorkFolderIfNeeded(updated.id, updated.title);
    return (await repository.findWorkById(workId)) ?? updated;
  }

  /// 检查并清理拆分后的残余空壳源作品。
  static Future<bool> cleanupSourceWorkAfterSplit(
    LibraryRepository repository,
    Work sourceWork,
  ) async {
    await repository.deleteOrphanEpisodes(sourceWork.id);
    final remaining = await repository.getVariantsByWork(sourceWork.id);
    final hasRemainingVideos = remaining.any(
      (v) => v.assetKind == AssetKind.video,
    );
    if (remaining.isEmpty ||
        (!hasRemainingVideos &&
            sourceWork.scrapeStatus != ScrapeStatus.matched)) {
      await repository.deleteWork(sourceWork.id);
      return true;
    }
    return false;
  }

  static Future<void> _syncBangumiOnlyEpisodes({
    required LibraryRepository repository,
    required Work work,
    required List<BangumiEpisodeEntry> bgmEpisodes,
  }) async {
    await ReleaseGroups.prepare();
    final variants = await repository.getVariantsByWork(work.id);
    final videoVariants = variants
        .where((v) => v.assetKind == AssetKind.video)
        .toList()
      ..sort((a, b) => a.relativePath.compareTo(b.relativePath));
    if (videoVariants.isEmpty) return;

    final mainBgmBySort = <int, BangumiEpisodeEntry>{
      for (final e in bgmEpisodes)
        if (e.type == 0 && e.sort != null) e.sort!.round(): e,
    };
    final episodeByKey = <String, Episode>{};
    var fallbackMainNum = 1;
    for (final v in videoVariants) {
      final parsed = BdripParser.parseFileName(v.fileName);
      final isExtra = parsed.extraType != null;
      final category = isExtra ? EpisodeCategory.extra : EpisodeCategory.main;
      final season = isExtra ? 0 : 1;
      final epNum = parsed.episode ?? (isExtra ? null : fallbackMainNum++);
      final key =
          '${category.name}:$season:${epNum ?? 'none'}:${parsed.extraType?.name ?? ''}';
      var ep = episodeByKey[key];
      if (ep == null) {
        final bgmEp = !isExtra && epNum != null ? mainBgmBySort[epNum] : null;
        final title = isExtra
            ? '${(parsed.extraType?.name ?? 'SP').toUpperCase()} ${epNum?.toString().padLeft(2, '0') ?? ''}'
                  .trim()
            : (bgmEp?.displayName ?? '第 ${epNum ?? 1} 话');
        ep = Episode(
          id: ScrapeWorkPersister.deterministicId('${work.id}::$key'),
          workId: work.id,
          seasonNumber: season,
          episodeNumber: epNum,
          category: category,
          extraType: parsed.extraType,
          title: title,
        );
        await repository.upsertEpisode(ep);
        episodeByKey[key] = ep;
      }
      await repository.upsertMediaVariant(
        v.copyWith(episodeId: ep.id, mappingLocked: true, workLocked: true),
      );
    }
    await repository.deleteOrphanEpisodes(work.id);
  }

  static Future<void> _syncHybridEpisodesAndVariants({
    required LibraryRepository repository,
    required Work work,
    required TmdbSeasonDetail? seasonDetail,
    required List<BangumiEpisodeEntry> bgmEpisodes,
    required int tmdbSeasonNumber,
    required int startEpisodeNumber,
    Map<String, ({int season, int episode})>? customSlotsByVariantId,
  }) async {
    await ReleaseGroups.prepare();
    final variants = await repository.getVariantsByWork(work.id);
    final videoVariants = variants
        .where((v) => v.assetKind == AssetKind.video)
        .toList()
      ..sort((a, b) => a.relativePath.compareTo(b.relativePath));
    if (videoVariants.isEmpty) return;

    final tmdbEpByNum = <int, TmdbEpisodeDetail>{
      for (final e in seasonDetail?.episodes ?? const <TmdbEpisodeDetail>[])
        e.episodeNumber: e,
    };
    final bgmEpByNum = <int, BangumiEpisodeEntry>{
      for (final e in bgmEpisodes)
        if (e.type == 0 && e.sort != null) e.sort!.round(): e,
    };
    final episodeByKey = <String, Episode>{};
    var nextSeqEp = startEpisodeNumber <= 0 ? 1 : startEpisodeNumber;
    for (final v in videoVariants) {
      final override = customSlotsByVariantId?[v.id];
      final targetSeason = override?.season ?? tmdbSeasonNumber;
      final targetEp = override?.episode ?? nextSeqEp++;
      final key = '${EpisodeCategory.main.name}:$targetSeason:$targetEp:';
      var ep = episodeByKey[key];
      if (ep == null) {
        final tmdbEp = targetSeason == tmdbSeasonNumber
            ? tmdbEpByNum[targetEp]
            : null;
        final bgmEp = bgmEpByNum[targetEp];
        final title = (tmdbEp != null && tmdbEp.title.trim().isNotEmpty)
            ? tmdbEp.title.trim()
            : (bgmEp?.displayName ?? '第 $targetEp 话');
        ep = Episode(
          id: ScrapeWorkPersister.deterministicId('${work.id}::$key'),
          workId: work.id,
          seasonNumber: targetSeason,
          episodeNumber: targetEp,
          category: EpisodeCategory.main,
          title: title,
          overview: tmdbEp?.overview,
          stillPath: tmdbEp?.stillPath,
        );
        await repository.upsertEpisode(ep);
        episodeByKey[key] = ep;
      }
      await repository.upsertMediaVariant(
        v.copyWith(episodeId: ep.id, mappingLocked: true, workLocked: true),
      );
    }
    await repository.deleteOrphanEpisodes(work.id);
  }

  static Future<WorkMergeOutcome> _transferVariantsToTarget({
    required LibraryRepository repository,
    required String sourceWorkId,
    required Work targetWork,
    required List<MediaVariant> variantsToMove,
    EpisodeCategory? forceCategory,
    required bool avoidExtraSlotCollision,
  }) async {
    await ReleaseGroups.prepare();
    final sourceEpisodes = await repository.getEpisodesByWork(sourceWorkId);
    final targetEpisodes = await repository.getEpisodesByWork(targetWork.id);
    final targetVariants = await repository.getVariantsByWork(targetWork.id);
    final sourcePlaybacks = await repository.getPlaybacksByWork(sourceWorkId);
    final targetPlaybacks = await repository.getPlaybacksByWork(targetWork.id);

    final sourceEpById = <String, Episode>{
      for (final ep in sourceEpisodes) ep.id: ep,
    };
    final targetEpByKey = <String, Episode>{
      for (final ep in targetEpisodes)
        _episodeSlotKey(
          ep.category,
          ep.seasonNumber,
          ep.episodeNumber,
          ep.extraType,
        ): ep,
    };
    final occupiedEpIds = <String>{
      for (final v in targetVariants)
        if (v.episodeId != null) v.episodeId!,
    };

    final nextMainEpBySeason = <int, int>{};
    final nextExtraEpByKind = <ExtraKind, int>{};
    for (final ep in targetEpisodes) {
      final epNum = ep.episodeNumber ?? 0;
      if (ep.category == EpisodeCategory.main) {
        final prev = nextMainEpBySeason[ep.seasonNumber] ?? 0;
        if (epNum > prev) nextMainEpBySeason[ep.seasonNumber] = epNum;
      } else {
        final kind = ep.extraType ?? ExtraKind.sp;
        final prev = nextExtraEpByKind[kind] ?? 0;
        if (epNum > prev) nextExtraEpByKind[kind] = epNum;
      }
    }

    final sorted = List<MediaVariant>.of(variantsToMove)
      ..sort(
        (a, b) =>
            a.relativePath.toLowerCase().compareTo(b.relativePath.toLowerCase()),
      );
    final oldToNewEpisode = <String, Episode>{};

    for (final variant in sorted) {
      if (variant.assetKind != AssetKind.video) {
        await repository.upsertMediaVariant(
          variant.copyWith(
            workId: targetWork.id,
            clearEpisodeId: true,
            workLocked: true,
          ),
        );
        continue;
      }

      final oldEp = variant.episodeId != null
          ? sourceEpById[variant.episodeId!]
          : null;
      final destCategory =
          forceCategory ?? (oldEp?.category ?? EpisodeCategory.main);

      late final int destSeason;
      late final int destEpNum;
      int? destEpEnd;
      ExtraKind? destExtraKind;

      if (destCategory == EpisodeCategory.extra) {
        destSeason = 0;
        destExtraKind = _resolveExtraKindForVariant(variant, oldEp);
        final candidateNum = (oldEp?.category == EpisodeCategory.extra
            ? oldEp?.episodeNumber
            : null);
        final candidateKey = candidateNum != null && candidateNum > 0
            ? _episodeSlotKey(
                EpisodeCategory.extra,
                0,
                candidateNum,
                destExtraKind,
              )
            : null;
        final collides =
            candidateKey != null &&
            avoidExtraSlotCollision &&
            targetEpByKey[candidateKey] != null &&
            occupiedEpIds.contains(targetEpByKey[candidateKey]!.id);
        if (candidateNum == null || candidateNum <= 0 || collides) {
          final next = (nextExtraEpByKind[destExtraKind] ?? 0) + 1;
          nextExtraEpByKind[destExtraKind] = next;
          destEpNum = next;
        } else {
          destEpNum = candidateNum;
          final prev = nextExtraEpByKind[destExtraKind] ?? 0;
          if (destEpNum > prev) nextExtraEpByKind[destExtraKind] = destEpNum;
        }
      } else {
        final preferredSeason =
            targetWork.matchedSeason ??
            ((oldEp != null && oldEp.seasonNumber > 0)
                ? oldEp.seasonNumber
                : 1);
        destSeason = preferredSeason <= 0 ? 1 : preferredSeason;
        final canKeepNum =
            oldEp?.category == EpisodeCategory.main &&
            oldEp?.episodeNumber != null &&
            oldEp!.episodeNumber! > 0;
        if (canKeepNum) {
          destEpNum = oldEp.episodeNumber!;
          destEpEnd = oldEp.episodeNumberEnd;
          final prev = nextMainEpBySeason[destSeason] ?? 0;
          final coveredMax = destEpEnd ?? destEpNum;
          if (coveredMax > prev) nextMainEpBySeason[destSeason] = coveredMax;
        } else {
          final next = (nextMainEpBySeason[destSeason] ?? 0) + 1;
          nextMainEpBySeason[destSeason] = next;
          destEpNum = next;
        }
      }

      final key = _episodeSlotKey(
        destCategory,
        destSeason,
        destEpNum,
        destExtraKind,
      );
      var targetEp = targetEpByKey[key];
      if (targetEp == null) {
        final title =
            (oldEp != null &&
                oldEp.category == destCategory &&
                (oldEp.title?.trim().isNotEmpty ?? false))
            ? oldEp.title!.trim()
            : (destCategory == EpisodeCategory.extra
                  ? '${(destExtraKind?.name ?? 'SP').toUpperCase()} ${destEpNum.toString().padLeft(2, '0')}'
                  : (destEpEnd != null
                        ? '第 $destEpNum-$destEpEnd 话'
                        : '第 $destEpNum 话'));
        targetEp = Episode(
          id: ScrapeWorkPersister.deterministicId('${targetWork.id}::$key'),
          workId: targetWork.id,
          seasonNumber: destSeason,
          episodeNumber: destEpNum,
          episodeNumberEnd: destCategory == EpisodeCategory.main
              ? destEpEnd
              : null,
          category: destCategory,
          extraType: destExtraKind,
          title: title,
          overview: oldEp?.category == destCategory ? oldEp?.overview : null,
          stillPath: oldEp?.category == destCategory ? oldEp?.stillPath : null,
        );
        await repository.upsertEpisode(targetEp);
        targetEpByKey[key] = targetEp;
      }

      occupiedEpIds.add(targetEp.id);
      if (oldEp != null) {
        oldToNewEpisode[oldEp.id] = targetEp;
      }
      await repository.upsertMediaVariant(
        variant.copyWith(
          workId: targetWork.id,
          episodeId: targetEp.id,
          workLocked: true,
          mappingLocked: true,
        ),
      );
    }

    final targetPlaybackByEpId = <String, PlaybackRecord>{
      for (final rec in targetPlaybacks) rec.episodeId: rec,
    };
    for (final record in sourcePlaybacks) {
      final mappedEp = oldToNewEpisode[record.episodeId];
      if (mappedEp == null) continue;
      final existingTarget = targetPlaybackByEpId[mappedEp.id];
      if (existingTarget != null &&
          existingTarget.playedAt.isAfter(record.playedAt)) {
        continue;
      }
      await repository.recordPlayback(
        PlaybackRecord(
          id: ScrapeWorkPersister.deterministicId(
            '${targetWork.id}::${mappedEp.id}',
          ),
          workId: targetWork.id,
          episodeId: mappedEp.id,
          variantId: record.variantId,
          seasonNumber: mappedEp.seasonNumber,
          episodeNumber: mappedEp.episodeNumber,
          episodeTitle: mappedEp.title ?? record.episodeTitle,
          sourceType: record.sourceType,
          playedAt: record.playedAt,
          positionSeconds: record.positionSeconds,
          durationSeconds: record.durationSeconds,
          isCompleted: record.isCompleted,
        ),
      );
    }

    final remaining = await repository.getVariantsByWork(sourceWorkId);
    var sourceDeleted = false;
    if (remaining.isEmpty) {
      await repository.clearScrapeCandidates(sourceWorkId);
      await repository.deleteOrphanEpisodes(sourceWorkId);
      await repository.deleteWork(sourceWorkId);
      sourceDeleted = true;
    } else {
      await repository.deleteOrphanEpisodes(sourceWorkId);
    }

    return WorkMergeOutcome(
      targetWork: (await repository.findWorkById(targetWork.id)) ?? targetWork,
      movedVariantCount: sorted.length,
      sourceWorkDeleted: sourceDeleted,
      sourceWorkId: sourceWorkId,
    );
  }

  static String _episodeSlotKey(
    EpisodeCategory category,
    int seasonNumber,
    int? episodeNumber,
    ExtraKind? extraType,
  ) =>
      '${category.name}:$seasonNumber:${episodeNumber ?? 'none'}:${extraType?.name ?? ''}';

  static ExtraKind _resolveExtraKindForVariant(
    MediaVariant variant,
    Episode? sourceEp,
  ) {
    return sourceEp?.extraType ??
        CloudMediaClassifier.detectExtraKind(
          fileName: variant.fileName,
          relativePath: variant.relativePath,
        ) ??
        BdripParser.parseFileName(variant.fileName).extraType ??
        ExtraKind.sp;
  }
}
