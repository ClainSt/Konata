import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models/episode.dart';
import '../../domain/models/media_variant.dart';
import '../../domain/models/playback_record.dart';
import '../../domain/models/work.dart';
import '../../domain/parsing/bdrip_parser.dart';
import '../../domain/parsing/cloud_media_classifier.dart';
import '../../domain/repositories/library_repository.dart';
import '../scraping/scrape_work_persister.dart';
import 'library_providers.dart';

/// 合并或迁移操作的可观测结果。
class WorkMergeOutcome {
  /// 创建合并结果实体。
  const WorkMergeOutcome({
    required this.targetWork,
    required this.movedVariantCount,
    required this.sourceWorkDeleted,
    this.sourceWorkId,
  });

  /// 合并后的目标作品实体。
  final Work targetWork;

  /// 成功迁移的物理媒体文件数量。
  final int movedVariantCount;

  /// 原作品是否因空壳被自动清理移除。
  final bool sourceWorkDeleted;

  /// 原作品 ID（若已合并清理则与 [targetWork.id] 不同）。
  final String? sourceWorkId;
}

String _episodeSlotKey(
  EpisodeCategory category,
  int seasonNumber,
  int? episodeNumber,
  ExtraKind? extraType,
) {
  return '${category.name}:$seasonNumber:${episodeNumber ?? 'none'}:${extraType?.name ?? ''}';
}

ExtraKind _resolveExtraKindForVariant(MediaVariant variant, Episode? sourceEp) {
  return sourceEp?.extraType ??
      CloudMediaClassifier.detectExtraKind(
        fileName: variant.fileName,
        relativePath: variant.relativePath,
      ) ??
      BdripParser.parseFileName(variant.fileName).extraType ??
      ExtraKind.sp;
}

/// 在纯仓储层将 [sourceWorkId] 下的全部媒体变体、剧集与播放记录合并进 [targetWorkId] 并删除原作品。
Future<WorkMergeOutcome> mergeWorkIntoExistingInRepo(
  LibraryRepository repo, {
  required String sourceWorkId,
  required String targetWorkId,
  EpisodeCategory? forceCategory,
  Future<void> Function(String sourceWorkId, Work targetWork)? onPhotosMerge,
}) async {
  if (sourceWorkId == targetWorkId) {
    throw ArgumentError('源作品与目标作品不能相同');
  }
  final sourceWork = await repo.findWorkById(sourceWorkId);
  if (sourceWork == null) {
    throw StateError('待合并原作品不存在: $sourceWorkId');
  }
  final targetWork = await repo.findWorkById(targetWorkId);
  if (targetWork == null) {
    throw StateError('目标作品不存在: $targetWorkId');
  }

  final sourceVariants = await repo.getVariantsByWork(sourceWorkId);
  final outcome = await _transferVariantsToTargetInRepo(
    repo,
    sourceWorkId: sourceWorkId,
    targetWork: targetWork,
    variantsToMove: sourceVariants,
    forceCategory: forceCategory,
    avoidExtraSlotCollision: true,
  );

  // 全量合并时确保迁移照片目录并清理源作品残余元数据
  await onPhotosMerge?.call(sourceWorkId, outcome.targetWork);
  await repo.clearScrapeCandidates(sourceWorkId);
  await repo.deleteOrphanEpisodes(sourceWorkId);
  if (!outcome.sourceWorkDeleted) {
    await repo.deleteWork(sourceWorkId);
  }
  return WorkMergeOutcome(
    targetWork: outcome.targetWork,
    movedVariantCount: sourceVariants.length,
    sourceWorkDeleted: true,
    sourceWorkId: sourceWorkId,
  );
}

/// 在纯仓储层将指定的 [variantIds] 迁移至 [targetWorkId]；若原作品不再剩任何文件，自动移除原空壳。
Future<WorkMergeOutcome> moveVariantsToWorkInRepo(
  LibraryRepository repo, {
  required String sourceWorkId,
  required List<String> variantIds,
  required String targetWorkId,
  required EpisodeCategory targetCategory,
  Future<void> Function(String sourceWorkId, Work targetWork)? onPhotosMerge,
  Future<void> Function(String deletedWorkId)? onEmptySourceDeleted,
}) async {
  if (sourceWorkId == targetWorkId) {
    throw ArgumentError('不能迁移至当前所属作品');
  }
  final targetWork = await repo.findWorkById(targetWorkId);
  if (targetWork == null) {
    throw StateError('目标作品不存在: $targetWorkId');
  }
  final sourceVariants = await repo.getVariantsByWork(sourceWorkId);
  final idSet = variantIds.toSet();
  final selected = sourceVariants
      .where((v) => idSet.contains(v.id))
      .toList(growable: false);
  if (selected.isEmpty) {
    throw StateError('未选中有效的物理媒体文件');
  }

  final outcome = await _transferVariantsToTargetInRepo(
    repo,
    sourceWorkId: sourceWorkId,
    targetWork: targetWork,
    variantsToMove: selected,
    forceCategory: targetCategory,
    avoidExtraSlotCollision: targetCategory == EpisodeCategory.extra,
  );

  if (outcome.sourceWorkDeleted) {
    await onPhotosMerge?.call(sourceWorkId, outcome.targetWork);
    await onEmptySourceDeleted?.call(sourceWorkId);
  }
  return outcome;
}

Future<WorkMergeOutcome> _transferVariantsToTargetInRepo(
  LibraryRepository repo, {
  required String sourceWorkId,
  required Work targetWork,
  required List<MediaVariant> variantsToMove,
  EpisodeCategory? forceCategory,
  required bool avoidExtraSlotCollision,
}) async {
  final sourceEpisodes = await repo.getEpisodesByWork(sourceWorkId);
  final targetEpisodes = await repo.getEpisodesByWork(targetWork.id);
  final targetVariants = await repo.getVariantsByWork(targetWork.id);
  final sourcePlaybacks = await repo.getPlaybacksByWork(sourceWorkId);
  final targetPlaybacks = await repo.getPlaybacksByWork(targetWork.id);

  final sourceEpById = {for (final ep in sourceEpisodes) ep.id: ep};
  final targetEpByKey = <String, Episode>{
    for (final ep in targetEpisodes)
      _episodeSlotKey(ep.category, ep.seasonNumber, ep.episodeNumber, ep.extraType):
          ep,
  };
  final occupiedEpIds = {
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
      (a, b) => a.relativePath.toLowerCase().compareTo(
        b.relativePath.toLowerCase(),
      ),
    );
  final oldToNewEpisode = <String, Episode>{};

  for (final variant in sorted) {
    if (variant.assetKind != AssetKind.video) {
      await repo.upsertMediaVariant(
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
    ExtraKind? destExtraKind;

    if (destCategory == EpisodeCategory.extra) {
      destSeason = 0;
      destExtraKind = _resolveExtraKindForVariant(variant, oldEp);
      final candidateNum =
          (oldEp?.category == EpisodeCategory.extra ? oldEp?.episodeNumber : null);
      final candidateKey = candidateNum != null && candidateNum > 0
          ? _episodeSlotKey(
              EpisodeCategory.extra,
              0,
              candidateNum,
              destExtraKind,
            )
          : null;
      final collides = candidateKey != null &&
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
      final preferredSeason = targetWork.matchedSeason ??
          ((oldEp != null && oldEp.seasonNumber > 0) ? oldEp.seasonNumber : 1);
      destSeason = preferredSeason <= 0 ? 1 : preferredSeason;
      final canKeepNum =
          oldEp?.category == EpisodeCategory.main &&
          oldEp?.episodeNumber != null &&
          oldEp!.episodeNumber! > 0;
      if (canKeepNum) {
        destEpNum = oldEp.episodeNumber!;
        final prev = nextMainEpBySeason[destSeason] ?? 0;
        if (destEpNum > prev) nextMainEpBySeason[destSeason] = destEpNum;
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
      final title = (oldEp != null &&
              oldEp.category == destCategory &&
              (oldEp.title?.trim().isNotEmpty ?? false))
          ? oldEp.title!.trim()
          : (destCategory == EpisodeCategory.extra
                ? '${(destExtraKind?.name ?? 'SP').toUpperCase()} ${destEpNum.toString().padLeft(2, '0')}'
                : '第 $destEpNum 话');
      targetEp = Episode(
        id: ScrapeWorkPersister.deterministicId('${targetWork.id}::$key'),
        workId: targetWork.id,
        seasonNumber: destSeason,
        episodeNumber: destEpNum,
        category: destCategory,
        extraType: destExtraKind,
        title: title,
        overview: oldEp?.category == destCategory ? oldEp?.overview : null,
        stillPath: oldEp?.category == destCategory ? oldEp?.stillPath : null,
      );
      await repo.upsertEpisode(targetEp);
      targetEpByKey[key] = targetEp;
    }

    occupiedEpIds.add(targetEp.id);
    if (oldEp != null) {
      oldToNewEpisode[oldEp.id] = targetEp;
    }
    await repo.upsertMediaVariant(
      variant.copyWith(
        workId: targetWork.id,
        episodeId: targetEp.id,
        workLocked: true,
        mappingLocked: true,
      ),
    );
  }

  // 迁移播放历史进度至目标剧集
  final targetPlaybackByEpId = {
    for (final p in targetPlaybacks) p.episodeId: p,
  };
  for (final record in sourcePlaybacks) {
    final mappedEp = oldToNewEpisode[record.episodeId];
    if (mappedEp == null) continue;
    final existingTarget = targetPlaybackByEpId[mappedEp.id];
    if (existingTarget != null &&
        existingTarget.playedAt.isAfter(record.playedAt)) {
      continue;
    }
    await repo.recordPlayback(
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

  final remaining = await repo.getVariantsByWork(sourceWorkId);
  var sourceDeleted = false;
  if (remaining.isEmpty) {
    await repo.clearScrapeCandidates(sourceWorkId);
    await repo.deleteOrphanEpisodes(sourceWorkId);
    await repo.deleteWork(sourceWorkId);
    sourceDeleted = true;
  } else {
    await repo.deleteOrphanEpisodes(sourceWorkId);
  }

  return WorkMergeOutcome(
    targetWork: (await repo.findWorkById(targetWork.id)) ?? targetWork,
    movedVariantCount: sorted.length,
    sourceWorkDeleted: sourceDeleted,
    sourceWorkId: sourceWorkId,
  );
}

/// 当待复核/待绑定的作品自身无任何正片（`正片 (0)`），且库内已存在匹配的正片或已入库条目时，
/// 返回应当自动并入的目标作品实体（避免生成重复 `正片 (0)` 空壳卡片）。
Future<Work?> findAutoMergeTargetInRepo(
  LibraryRepository repo, {
  required String sourceWorkId,
  int? bangumiId,
  int? tmdbId,
  TmdbMediaType? tmdbMediaType,
  int? matchedSeason,
}) async {
  final sourceEps = await repo.getEpisodesByWork(sourceWorkId);
  final hasMainEpisode = sourceEps.any(
    (e) => e.category == EpisodeCategory.main,
  );
  if (hasMainEpisode) return null;

  final allWorks = await repo.getAllWorks();
  final candidates = <Work>[];
  for (final w in allWorks) {
    if (w.id == sourceWorkId || w.isHidden) continue;
    final confirmed =
        w.scrapeStatus == ScrapeStatus.matched || w.isManualLocked;
    if (!confirmed) continue;

    final matchesBgm =
        bangumiId != null && bangumiId > 0 && w.bangumiId == bangumiId;
    final matchesTmdb =
        tmdbId != null &&
        tmdbId > 0 &&
        w.tmdbId == tmdbId &&
        (tmdbMediaType == null ||
            w.tmdbMediaType == null ||
            w.tmdbMediaType == tmdbMediaType) &&
        (tmdbMediaType == TmdbMediaType.movie ||
            matchedSeason == null ||
            w.matchedSeason == null ||
            w.matchedSeason == matchedSeason);

    if (matchesBgm || matchesTmdb) {
      candidates.add(w);
    }
  }
  if (candidates.isEmpty) return null;

  // 优先并入包含正片分集的目标作品
  for (final c in candidates) {
    final eps = await repo.getEpisodesByWork(c.id);
    if (eps.any((e) => e.category == EpisodeCategory.main)) {
      return c;
    }
  }
  return candidates.first;
}

/// 通过 Riverpod 执行整部作品并入已有作品，并刷新相关媒体库视图状态。
Future<WorkMergeOutcome> executeMergeWorkIntoExisting(
  Ref ref, {
  required String sourceWorkId,
  required String targetWorkId,
  EpisodeCategory? forceCategory,
}) async {
  final repo = ref.read(libraryRepositoryProvider);
  final photos = ref.read(photosStorageProvider);
  final outcome = await mergeWorkIntoExistingInRepo(
    repo,
    sourceWorkId: sourceWorkId,
    targetWorkId: targetWorkId,
    forceCategory: forceCategory,
    onPhotosMerge: (srcId, targetWork) => photos.mergeWorkPhotos(
      sourceWorkId: srcId,
      targetWorkId: targetWork.id,
      targetTitle: targetWork.title,
    ),
  );
  _invalidateAfterMerge(
    ref,
    {sourceWorkId, targetWorkId},
    redirectedFrom: sourceWorkId,
    redirectedTo: targetWorkId,
  );
  return outcome;
}

/// 通过 Riverpod 将勾选的部分物理文件迁移至其他已有作品。
Future<WorkMergeOutcome> executeMoveVariantsToExistingWork(
  Ref ref, {
  required String sourceWorkId,
  required List<String> variantIds,
  required String targetWorkId,
  required EpisodeCategory targetCategory,
}) async {
  final repo = ref.read(libraryRepositoryProvider);
  final photos = ref.read(photosStorageProvider);
  final outcome = await moveVariantsToWorkInRepo(
    repo,
    sourceWorkId: sourceWorkId,
    variantIds: variantIds,
    targetWorkId: targetWorkId,
    targetCategory: targetCategory,
    onPhotosMerge: (srcId, targetWork) => photos.mergeWorkPhotos(
      sourceWorkId: srcId,
      targetWorkId: targetWork.id,
      targetTitle: targetWork.title,
    ),
    onEmptySourceDeleted: photos.deleteWorkPhotos,
  );
  _invalidateAfterMerge(
    ref,
    {sourceWorkId, targetWorkId},
    redirectedFrom: outcome.sourceWorkDeleted ? sourceWorkId : null,
    redirectedTo: outcome.sourceWorkDeleted ? outcome.targetWork.id : null,
  );
  return outcome;
}

/// 若 [sourceWorkId] 为 0 正片附属条目且库内已有匹配作品，直接自动合并并返回目标作品；否则返回 `null`。
Future<Work?> tryAutoMergeSupplementaryWork(
  Ref ref, {
  required String sourceWorkId,
  int? bangumiId,
  int? tmdbId,
  TmdbMediaType? tmdbMediaType,
  int? matchedSeason,
}) async {
  final repo = ref.read(libraryRepositoryProvider);
  final autoTarget = await findAutoMergeTargetInRepo(
    repo,
    sourceWorkId: sourceWorkId,
    bangumiId: bangumiId,
    tmdbId: tmdbId,
    tmdbMediaType: tmdbMediaType,
    matchedSeason: matchedSeason,
  );
  if (autoTarget == null) return null;
  final photos = ref.read(photosStorageProvider);
  final outcome = await mergeWorkIntoExistingInRepo(
    repo,
    sourceWorkId: sourceWorkId,
    targetWorkId: autoTarget.id,
    forceCategory: EpisodeCategory.extra,
    onPhotosMerge: (srcId, targetWork) => photos.mergeWorkPhotos(
      sourceWorkId: srcId,
      targetWorkId: targetWork.id,
      targetTitle: targetWork.title,
    ),
  );
  _invalidateAfterMerge(
    ref,
    {sourceWorkId, autoTarget.id},
    redirectedFrom: sourceWorkId,
    redirectedTo: outcome.targetWork.id,
  );
  return outcome.targetWork;
}

void _invalidateAfterMerge(
  Ref ref,
  Set<String> workIds, {
  String? redirectedFrom,
  String? redirectedTo,
}) {
  if (redirectedFrom != null &&
      redirectedTo != null &&
      redirectedFrom != redirectedTo) {
    recordWorkRedirect(ref, redirectedFrom, redirectedTo);
  }
  ref.invalidate(libraryItemsProvider);
  ref.invalidate(worksCountProvider);
  ref.invalidate(hiddenWorksProvider);
  ref.invalidate(seriesGroupsProvider);
  for (final id in workIds) {
    ref.invalidate(workDetailBundleProvider(id));
    ref.invalidate(workScrapeCandidatesProvider(id));
  }
}
