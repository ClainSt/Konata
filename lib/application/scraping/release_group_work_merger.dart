import '../../domain/models/episode.dart';
import '../../domain/models/media_variant.dart';
import '../../domain/models/playback_record.dart';
import '../../domain/models/work.dart';
import '../../domain/repositories/library_repository.dart';
import '../../infrastructure/cache/photos_storage.dart';
import 'scrape_work_persister.dart';

/// 同媒体源强身份多版本作品自动归并器（方案 A）。
///
/// 当同一媒体源下存在多个目录或合集拆簇（如 `剧场版 窈窕淑女` 的猫萌版与
/// `窈窕淑女 (1978)` 内附带的 CoolFansSub 剧场版，或同目录下多压制组洗版目录）
/// 均已高置信匹配至**完全相同的强元数据身份**——即相同 `(tmdbMediaType, tmdbId, matchedSeason)`
/// （排除 `Season 0`）或相同 `bangumiId` 且双源 ID 无冲突时，自动原子归并为唯一多版本作品卡：
/// - 同集 TV 正片与单部剧场版正片（`episodeNumber == null`）汇聚至同一逻辑正片供播放器实时切版；
/// - 两方特典、CD、Scan、播放进度与本地图片缓存全量保留互不覆盖；
/// - 目标主卡优先保留元数据更完整者并自动补全缺失的 TMDB / Bangumi 标识与艺术图；
/// - 严格隔离不同媒体源，绝不合并 `Season 0` 独立特别篇、人工锁定作品、锁文件变体与跨源冲突条目。
abstract final class ReleaseGroupWorkMerger {
  /// 合并归并结果：包含被吸收删除的源作品 ID 与已保留并可能被补全元数据的目标作品 ID。
  static Future<({Set<String> absorbedIds, Set<String> survivingTargetIds})>
  mergeSameSourceIdentityWorks({
    required LibraryRepository repository,
    required String sourceId,
    Set<String>? focusWorkIds,
    PhotosStorage? photosStorage,
  }) async {
    final sourceVariants = await repository.getVariantsBySource(sourceId);
    if (sourceVariants.isEmpty) {
      return (absorbedIds: <String>{}, survivingTargetIds: <String>{});
    }

    final variantsByWorkId = <String, List<MediaVariant>>{};
    for (final v in sourceVariants) {
      variantsByWorkId.putIfAbsent(v.workId, () => <MediaVariant>[]).add(v);
    }
    if (variantsByWorkId.length < 2) {
      return (absorbedIds: <String>{}, survivingTargetIds: <String>{});
    }

    final eligible = <({Work work, List<MediaVariant> variants})>[];
    for (final entry in variantsByWorkId.entries) {
      final work = await repository.findWorkById(entry.key);
      if (work == null || !_isEligibleForAutoMerge(work)) continue;
      // 严禁自动跨源归并：若目标作品本身包含其他媒体源变体，跳过以免破坏多源隔离。
      final allWorkVariants = await repository.getVariantsByWork(work.id);
      if (allWorkVariants.isEmpty ||
          allWorkVariants.any((v) => v.sourceId != sourceId)) {
        continue;
      }
      eligible.add((work: work, variants: allWorkVariants));
    }
    if (eligible.length < 2) {
      return (absorbedIds: <String>{}, survivingTargetIds: <String>{});
    }

    // 先按元数据完备度、艺术图完整度、变体数量与确定性 ID 降序排列，
    // 随后贪心聚合无冲突的同强身份簇，防止传递合并把不同 Bangumi/TMDB 条目误并到一起。
    eligible.sort((a, b) => _compareTargetPriority(a, b));

    final clusters = <List<({Work work, List<MediaVariant> variants})>>[];
    for (final item in eligible) {
      List<({Work work, List<MediaVariant> variants})>? matchedCluster;
      for (final cluster in clusters) {
        final hasStrongIdentityMatch = cluster.any(
          (member) => _sharesStrongIdentity(member.work, item.work),
        );
        if (!hasStrongIdentityMatch) continue;
        final conflictsWithAny = cluster.any(
          (member) => _hasIdentityConflict(member.work, item.work),
        );
        if (!conflictsWithAny) {
          matchedCluster = cluster;
          break;
        }
      }
      if (matchedCluster != null) {
        matchedCluster.add(item);
      } else {
        clusters.add([item]);
      }
    }

    final absorbedIds = <String>{};
    final survivingTargetIds = <String>{};
    for (final cluster in clusters) {
      if (cluster.length < 2) continue;
      if (focusWorkIds != null &&
          !cluster.any((entry) => focusWorkIds.contains(entry.work.id))) {
        continue;
      }

      var target = cluster.first.work;
      var targetMerged = false;
      for (final sourceEntry in cluster.skip(1)) {
        final source = sourceEntry.work;
        if (source.id == target.id || absorbedIds.contains(source.id)) continue;
        if (_hasIdentityConflict(target, source)) continue;
        // 源作品包含人工锁定变体时尊重用户显式归属，不自动迁移。
        if (sourceEntry.variants.any((v) => v.workLocked || v.scopeLocked)) {
          continue;
        }

        target = await _mergeSingleIntoTarget(
          repository: repository,
          sourceWork: source,
          targetWork: target,
          photosStorage: photosStorage,
        );
        absorbedIds.add(source.id);
        targetMerged = true;
      }
      if (targetMerged) {
        survivingTargetIds.add(target.id);
      }
    }

    return (
      absorbedIds: absorbedIds,
      survivingTargetIds: survivingTargetIds,
    );
  }

  static bool _isEligibleForAutoMerge(Work work) {
    if (work.scrapeStatus != ScrapeStatus.matched) return false;
    if (work.isManualLocked) return false;
    // 严禁自动合并挂载于同一母剧 Season 0 下的不同独立 OVA/SP 目录。
    if (work.tmdbMediaType == TmdbMediaType.tv && work.matchedSeason == 0) {
      return false;
    }
    final hasTmdb =
        work.tmdbId != null && work.tmdbId! > 0 && work.tmdbMediaType != null;
    final hasBangumi = work.bangumiId != null && work.bangumiId! > 0;
    return hasTmdb || hasBangumi;
  }

  static String? _tmdbIdentityKey(Work work) {
    if (work.tmdbId == null || work.tmdbId! <= 0 || work.tmdbMediaType == null) {
      return null;
    }
    if (work.tmdbMediaType == TmdbMediaType.tv) {
      return 'tv:${work.tmdbId}:S${work.matchedSeason ?? 1}';
    }
    return 'movie:${work.tmdbId}';
  }

  static bool _sharesStrongIdentity(Work a, Work b) {
    final tmdbA = _tmdbIdentityKey(a);
    final tmdbB = _tmdbIdentityKey(b);
    if (tmdbA != null && tmdbB != null && tmdbA == tmdbB) {
      return true;
    }
    if (a.bangumiId != null &&
        a.bangumiId! > 0 &&
        b.bangumiId != null &&
        b.bangumiId! > 0 &&
        a.bangumiId == b.bangumiId) {
      return true;
    }
    return false;
  }

  static bool _hasIdentityConflict(Work a, Work b) {
    final tmdbA = _tmdbIdentityKey(a);
    final tmdbB = _tmdbIdentityKey(b);
    if (tmdbA != null && tmdbB != null && tmdbA != tmdbB) {
      return true;
    }
    if (a.bangumiId != null &&
        a.bangumiId! > 0 &&
        b.bangumiId != null &&
        b.bangumiId! > 0 &&
        a.bangumiId != b.bangumiId) {
      return true;
    }
    return false;
  }

  static int _compareTargetPriority(
    ({Work work, List<MediaVariant> variants}) a,
    ({Work work, List<MediaVariant> variants}) b,
  ) {
    int metadataRank(Work w) {
      final hasTmdb = w.tmdbId != null && w.tmdbId! > 0 && w.tmdbMediaType != null;
      final hasBgm = w.bangumiId != null && w.bangumiId! > 0;
      if (hasTmdb && hasBgm) return 3;
      if (hasTmdb) return 2;
      if (hasBgm) return 1;
      return 0;
    }

    int artworkRank(Work w) {
      var score = 0;
      if (w.backdropPath != null && w.backdropPath!.trim().isNotEmpty) score += 2;
      if (w.posterPath != null && w.posterPath!.trim().isNotEmpty) score += 1;
      if (w.logoPath != null && w.logoPath!.trim().isNotEmpty) score += 1;
      return score;
    }

    final byMeta = metadataRank(b.work).compareTo(metadataRank(a.work));
    if (byMeta != 0) return byMeta;
    final byArt = artworkRank(b.work).compareTo(artworkRank(a.work));
    if (byArt != 0) return byArt;
    final byVariants = b.variants.length.compareTo(a.variants.length);
    if (byVariants != 0) return byVariants;
    return a.work.id.compareTo(b.work.id);
  }

  static Work _enrichTargetMetadata(Work target, Work source) {
    final nextTmdbId = (target.tmdbId == null || target.tmdbId! <= 0)
        ? source.tmdbId
        : target.tmdbId;
    final nextTmdbType = target.tmdbMediaType ?? source.tmdbMediaType;
    final nextBangumiId = (target.bangumiId == null || target.bangumiId! <= 0)
        ? source.bangumiId
        : target.bangumiId;
    final nextTvdbId = target.tvdbId ?? source.tvdbId;
    final nextSeason = target.matchedSeason ?? source.matchedSeason;
    final nextOriginalTitle =
        (target.originalTitle?.trim().isNotEmpty ?? false)
        ? target.originalTitle
        : source.originalTitle;
    final nextYear = target.year ?? source.year;
    final nextOverview = (target.overview?.trim().isNotEmpty ?? false)
        ? target.overview
        : source.overview;
    final nextPoster = (target.posterPath?.trim().isNotEmpty ?? false)
        ? target.posterPath
        : source.posterPath;
    final nextPosterFallback =
        (target.posterFallback?.trim().isNotEmpty ?? false)
        ? target.posterFallback
        : source.posterFallback;
    final nextBgmPoster =
        (target.bangumiPosterPath?.trim().isNotEmpty ?? false)
        ? target.bangumiPosterPath
        : source.bangumiPosterPath;
    final nextBackdrop = (target.backdropPath?.trim().isNotEmpty ?? false)
        ? target.backdropPath
        : source.backdropPath;
    final nextLogo = (target.logoPath?.trim().isNotEmpty ?? false)
        ? target.logoPath
        : source.logoPath;
    final nextVote = target.voteAverage ?? source.voteAverage;
    final nextBgmScore = target.bangumiScore ?? source.bangumiScore;

    if (nextTmdbId == target.tmdbId &&
        nextTmdbType == target.tmdbMediaType &&
        nextBangumiId == target.bangumiId &&
        nextTvdbId == target.tvdbId &&
        nextSeason == target.matchedSeason &&
        nextOriginalTitle == target.originalTitle &&
        nextYear == target.year &&
        nextOverview == target.overview &&
        nextPoster == target.posterPath &&
        nextPosterFallback == target.posterFallback &&
        nextBgmPoster == target.bangumiPosterPath &&
        nextBackdrop == target.backdropPath &&
        nextLogo == target.logoPath &&
        nextVote == target.voteAverage &&
        nextBgmScore == target.bangumiScore) {
      return target;
    }

    return target.copyWith(
      tmdbId: nextTmdbId,
      tmdbMediaType: nextTmdbType,
      bangumiId: nextBangumiId,
      tvdbId: nextTvdbId,
      matchedSeason: nextSeason,
      originalTitle: nextOriginalTitle,
      year: nextYear,
      overview: nextOverview,
      posterPath: nextPoster,
      posterFallback: nextPosterFallback,
      bangumiPosterPath: nextBgmPoster,
      backdropPath: nextBackdrop,
      logoPath: nextLogo,
      voteAverage: nextVote,
      bangumiScore: nextBgmScore,
    );
  }

  static Future<Work> _mergeSingleIntoTarget({
    required LibraryRepository repository,
    required Work sourceWork,
    required Work targetWork,
    PhotosStorage? photosStorage,
  }) async {
    final enrichedTarget = _enrichTargetMetadata(targetWork, sourceWork);
    final sourceEpisodes = await repository.getEpisodesByWork(sourceWork.id);
    final sourceVariants = await repository.getVariantsByWork(sourceWork.id);
    final sourcePlaybacks = await repository.getPlaybacksByWork(sourceWork.id);
    final targetEpisodes = await repository.getEpisodesByWork(targetWork.id);
    final targetPlaybacks = await repository.getPlaybacksByWork(targetWork.id);

    final sourceEpById = <String, Episode>{
      for (final ep in sourceEpisodes) ep.id: ep,
    };
    final targetMainBySlot = <String, Episode>{};
    Episode? targetFeatureMain;
    for (final ep in targetEpisodes) {
      if (ep.category != EpisodeCategory.main) continue;
      if (ep.episodeNumber != null) {
        final key =
            'ep:${ep.seasonNumber}:${ep.episodeNumber}:${ep.episodeNumberEnd ?? ''}';
        targetMainBySlot[key] = ep;
      } else {
        final key = 'feature:${ep.seasonNumber}';
        targetMainBySlot[key] = ep;
        targetFeatureMain ??= ep;
      }
    }
    final targetExtraIds = <String>{
      for (final ep in targetEpisodes)
        if (ep.category == EpisodeCategory.extra) ep.id,
    };
    final targetPlaybackByEp = <String, PlaybackRecord>{
      for (final rec in targetPlaybacks) rec.episodeId: rec,
    };

    final episodesToUpsert = <String, Episode>{};
    final variantsToUpsert = <MediaVariant>[];
    final episodeIdMap = <String, String>{};

    for (final variant in sourceVariants) {
      if (variant.assetKind != AssetKind.video || variant.episodeId == null) {
        variantsToUpsert.add(
          variant.copyWith(workId: enrichedTarget.id, clearEpisodeId: true),
        );
        continue;
      }
      final srcEp = sourceEpById[variant.episodeId!];
      if (srcEp == null) {
        variantsToUpsert.add(
          variant.copyWith(workId: enrichedTarget.id, clearEpisodeId: true),
        );
        continue;
      }

      String targetEpisodeId;
      if (srcEp.category == EpisodeCategory.main) {
        if (srcEp.episodeNumber != null) {
          final slotKey =
              'ep:${srcEp.seasonNumber}:${srcEp.episodeNumber}:${srcEp.episodeNumberEnd ?? ''}';
          final existingMain = targetMainBySlot[slotKey];
          if (existingMain != null) {
            targetEpisodeId = existingMain.id;
          } else {
            final epSuffix = srcEp.episodeNumberEnd != null
                ? 'E${srcEp.episodeNumber}-${srcEp.episodeNumberEnd}'
                : 'E${srcEp.episodeNumber}';
            targetEpisodeId = ScrapeWorkPersister.deterministicId(
              '${enrichedTarget.id}::main::S${srcEp.seasonNumber}::$epSuffix',
            );
            final created = Episode(
              id: targetEpisodeId,
              workId: enrichedTarget.id,
              seasonNumber: srcEp.seasonNumber,
              episodeNumber: srcEp.episodeNumber,
              episodeNumberEnd: srcEp.episodeNumberEnd,
              category: EpisodeCategory.main,
              title: srcEp.title,
              overview: srcEp.overview,
              stillPath: srcEp.stillPath,
            );
            targetMainBySlot[slotKey] = created;
            episodesToUpsert[targetEpisodeId] = created;
          }
        } else {
          // 剧场版 / 单部正片（episodeNumber == null）合并至目标正片单集下作为多版本变体，严禁误归入特典。
          final slotKey = 'feature:${srcEp.seasonNumber}';
          final existingFeature =
              targetMainBySlot[slotKey] ?? targetFeatureMain;
          if (existingFeature != null) {
            targetEpisodeId = existingFeature.id;
          } else {
            targetEpisodeId = ScrapeWorkPersister.deterministicId(
              '${enrichedTarget.id}::main:${srcEp.seasonNumber}:unnumbered::feature',
            );
            final created = Episode(
              id: targetEpisodeId,
              workId: enrichedTarget.id,
              seasonNumber: srcEp.seasonNumber,
              episodeNumber: null,
              category: EpisodeCategory.main,
              title: srcEp.title,
              overview: srcEp.overview,
              stillPath: srcEp.stillPath,
            );
            targetMainBySlot[slotKey] = created;
            targetFeatureMain ??= created;
            episodesToUpsert[targetEpisodeId] = created;
          }
        }
      } else {
        // 特典按目标作品 + 原变体相对路径派生唯一确定性 ID，确保不同压制组特典全量保留互不覆写。
        var candidateId = ScrapeWorkPersister.deterministicId(
          '${enrichedTarget.id}::extra::${srcEp.extraType?.name ?? 'sp'}::${variant.relativePath}',
        );
        if (targetExtraIds.contains(candidateId)) {
          candidateId = ScrapeWorkPersister.deterministicId(
            '${enrichedTarget.id}::extra::${variant.id}',
          );
        }
        targetEpisodeId = candidateId;
        targetExtraIds.add(targetEpisodeId);
        episodesToUpsert[targetEpisodeId] = Episode(
          id: targetEpisodeId,
          workId: enrichedTarget.id,
          seasonNumber: srcEp.seasonNumber,
          episodeNumber: srcEp.episodeNumber,
          category: EpisodeCategory.extra,
          extraType: srcEp.extraType,
          title: srcEp.title,
          overview: srcEp.overview,
          stillPath: srcEp.stillPath,
        );
      }

      episodeIdMap[srcEp.id] = targetEpisodeId;
      variantsToUpsert.add(
        variant.copyWith(
          workId: enrichedTarget.id,
          episodeId: targetEpisodeId,
        ),
      );
    }

    await repository.runInTransaction(() async {
      if (!identical(enrichedTarget, targetWork)) {
        await repository.upsertWork(enrichedTarget);
      }
      if (episodesToUpsert.isNotEmpty) {
        await repository.upsertEpisodesBatch(
          episodesToUpsert.values.toList(growable: false),
        );
      }
      if (variantsToUpsert.isNotEmpty) {
        await repository.upsertMediaVariantsBatch(variantsToUpsert);
      }
      for (final rec in sourcePlaybacks) {
        final nextEpId = rec.isAudioRecord
            ? rec.episodeId
            : (episodeIdMap[rec.episodeId] ?? rec.episodeId);
        final existingTargetRec = targetPlaybackByEp[nextEpId];
        if (existingTargetRec != null &&
            existingTargetRec.playedAt.isAfter(rec.playedAt)) {
          continue;
        }
        await repository.recordPlayback(
          PlaybackRecord(
            id: ScrapeWorkPersister.deterministicId(
              'pb::${enrichedTarget.id}::$nextEpId',
            ),
            workId: enrichedTarget.id,
            episodeId: nextEpId,
            variantId: rec.variantId,
            seasonNumber: rec.seasonNumber,
            episodeNumber: rec.episodeNumber,
            episodeTitle: rec.episodeTitle,
            sourceType: rec.sourceType,
            playedAt: rec.playedAt,
            positionSeconds: rec.positionSeconds,
            durationSeconds: rec.durationSeconds,
            isCompleted: rec.isCompleted,
          ),
        );
      }
      await repository.clearScrapeCandidates(sourceWork.id);
      await repository.deleteOrphanEpisodes(sourceWork.id);
      await repository.deleteWork(sourceWork.id);
    });

    await photosStorage?.mergeWorkPhotos(
      sourceWorkId: sourceWork.id,
      targetWorkId: enrichedTarget.id,
      targetTitle: enrichedTarget.title,
    );
    return enrichedTarget;
  }
}
