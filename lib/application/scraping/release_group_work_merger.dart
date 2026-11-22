import '../../domain/matching/directory_grouper.dart';
import '../../domain/models/episode.dart';
import '../../domain/models/media_variant.dart';
import '../../domain/models/playback_record.dart';
import '../../domain/models/work.dart';
import '../../domain/repositories/library_repository.dart';
import '../../infrastructure/cache/photos_storage.dart';
import 'scrape_work_persister.dart';

/// 同作品父目录下多压制组/字幕组子目录洗版自动归并器。
///
/// 当收藏者在同一作品目录（如 `孤独摇滚/`）下同时放置多个压制组原始发布包
/// （如 `[VCB-Studio] Bocchi the Rock!` 与 `[Snow-Raws] ぼっち・ざ・ろっく！`）各自携带
/// 分段正片、特典、CD 或 Scan 时，只要它们在本次扫描中均高置信自动绑定至完全相同的
/// 正片作品身份 `(tmdbId, tmdbMediaType, matchedSeason)`，自动原子归并为唯一作品卡片：
/// - 同集多压制组变体自动汇聚到同一逻辑剧集以支持播放器内切换洗版；
/// - 两组的特典、CD 与 Scan 全量保留互不覆盖；
/// - 严格排除 `Season 0` 独立特别篇、人工锁定作品、锁文件变体与 Bangumi 异条目冲突。
abstract final class ReleaseGroupWorkMerger {
  static final RegExp _leadingGroupBracket = RegExp(r'^\s*[\[【]');

  /// 执行同源同物理父目录的同身份压制组子目录自动归并，返回被吸收并移除的源作品 ID 集合。
  static Future<Set<String>> mergeSameParentReleaseGroupWorks({
    required LibraryRepository repository,
    required List<GroupedWorkFolder> groupedWorks,
    required Map<String, String> workIdByFolderPath,
    PhotosStorage? photosStorage,
  }) async {
    final candidatesByBucket = <String, List<({String workId, String folderPath})>>{};
    final worksCache = <String, Work?>{};

    Future<Work?> loadWork(String workId) async {
      if (worksCache.containsKey(workId)) return worksCache[workId];
      final w = await repository.findWorkById(workId);
      worksCache[workId] = w;
      return w;
    }

    for (final folder in groupedWorks) {
      if (folder.isSplitCluster) continue;
      final normPath = folder.folderRelativePath.trim().replaceAll('\\', '/');
      final slash = normPath.lastIndexOf('/');
      if (slash <= 0) continue;
      final parentDir = normPath.substring(0, slash);
      final leafName = normPath.substring(slash + 1);
      if (!_leadingGroupBracket.hasMatch(leafName)) continue;

      final workId = workIdByFolderPath[folder.folderRelativePath];
      if (workId == null || workId.isEmpty) continue;
      final work = await loadWork(workId);
      if (work == null ||
          work.scrapeStatus != ScrapeStatus.matched ||
          work.isManualLocked ||
          work.tmdbId == null ||
          work.tmdbMediaType == null) {
        continue;
      }
      // 严禁自动合并挂载于同一母剧 Season 0 下的不同独立 OVA/SP 目录。
      if (work.tmdbMediaType == TmdbMediaType.tv && work.matchedSeason == 0) {
        continue;
      }
      final seasonKey = work.tmdbMediaType == TmdbMediaType.tv
          ? 'S${work.matchedSeason ?? 1}'
          : 'M';
      final bucketKey =
          '$parentDir|${work.tmdbMediaType!.name}:${work.tmdbId}:$seasonKey';
      final bucket = candidatesByBucket.putIfAbsent(bucketKey, () => []);
      if (!bucket.any((e) => e.workId == workId)) {
        bucket.add((workId: workId, folderPath: normPath));
      }
    }

    final absorbedIds = <String>{};
    for (final entries in candidatesByBucket.values) {
      if (entries.length < 2) continue;
      final hydrated = <({Work work, List<MediaVariant> variants})>[];
      for (final entry in entries) {
        if (absorbedIds.contains(entry.workId)) continue;
        final work = await loadWork(entry.workId);
        if (work == null) continue;
        final variants = await repository.getVariantsByWork(work.id);
        if (variants.isEmpty) continue;
        hydrated.add((work: work, variants: variants));
      }
      if (hydrated.length < 2) continue;

      // 优先以变体数多者为主卡，同数按 ID 字典序确定，保证多次重扫幂等。
      hydrated.sort((a, b) {
        final byCount = b.variants.length.compareTo(a.variants.length);
        if (byCount != 0) return byCount;
        return a.work.id.compareTo(b.work.id);
      });
      final target = hydrated.first.work;

      for (final sourceEntry in hydrated.skip(1)) {
        final source = sourceEntry.work;
        if (source.id == target.id) continue;
        // 两者均存在 Bangumi 绑定且指向不同独立条目时禁止合并。
        if (target.bangumiId != null &&
            source.bangumiId != null &&
            target.bangumiId != source.bangumiId) {
          continue;
        }
        // 源作品包含人工锁定变体时尊重用户显式归属，不自动迁移。
        if (sourceEntry.variants.any((v) => v.workLocked || v.scopeLocked)) {
          continue;
        }

        await _mergeSingleIntoTarget(
          repository: repository,
          sourceWork: source,
          targetWork: target,
          photosStorage: photosStorage,
        );
        absorbedIds.add(source.id);
      }
    }
    return absorbedIds;
  }

  static Future<void> _mergeSingleIntoTarget({
    required LibraryRepository repository,
    required Work sourceWork,
    required Work targetWork,
    PhotosStorage? photosStorage,
  }) async {
    final sourceEpisodes = await repository.getEpisodesByWork(sourceWork.id);
    final sourceVariants = await repository.getVariantsByWork(sourceWork.id);
    final sourcePlaybacks = await repository.getPlaybacksByWork(sourceWork.id);
    final targetEpisodes = await repository.getEpisodesByWork(targetWork.id);
    final targetPlaybacks = await repository.getPlaybacksByWork(targetWork.id);

    final sourceEpById = <String, Episode>{
      for (final ep in sourceEpisodes) ep.id: ep,
    };
    final targetMainBySlot = <String, Episode>{
      for (final ep in targetEpisodes)
        if (ep.category == EpisodeCategory.main && ep.episodeNumber != null)
          '${ep.seasonNumber}:${ep.episodeNumber}:${ep.episodeNumberEnd ?? ''}':
              ep,
    };
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
          variant.copyWith(workId: targetWork.id, clearEpisodeId: true),
        );
        continue;
      }
      final srcEp = sourceEpById[variant.episodeId!];
      if (srcEp == null) {
        variantsToUpsert.add(
          variant.copyWith(workId: targetWork.id, clearEpisodeId: true),
        );
        continue;
      }

      String targetEpisodeId;
      if (srcEp.category == EpisodeCategory.main &&
          srcEp.episodeNumber != null) {
        final slotKey =
            '${srcEp.seasonNumber}:${srcEp.episodeNumber}:${srcEp.episodeNumberEnd ?? ''}';
        final existingMain = targetMainBySlot[slotKey];
        if (existingMain != null) {
          targetEpisodeId = existingMain.id;
        } else {
          final epSuffix = srcEp.episodeNumberEnd != null
              ? 'E${srcEp.episodeNumber}-${srcEp.episodeNumberEnd}'
              : 'E${srcEp.episodeNumber}';
          targetEpisodeId = ScrapeWorkPersister.deterministicId(
            '${targetWork.id}::main::S${srcEp.seasonNumber}::$epSuffix',
          );
          final created = Episode(
            id: targetEpisodeId,
            workId: targetWork.id,
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
        // 特典按目标作品 + 原变体相对路径派生唯一确定性 ID，确保不同压制组特典全量保留互不覆写。
        var candidateId = ScrapeWorkPersister.deterministicId(
          '${targetWork.id}::extra::${srcEp.extraType?.name ?? 'sp'}::${variant.relativePath}',
        );
        if (targetExtraIds.contains(candidateId)) {
          candidateId = ScrapeWorkPersister.deterministicId(
            '${targetWork.id}::extra::${variant.id}',
          );
        }
        targetEpisodeId = candidateId;
        targetExtraIds.add(targetEpisodeId);
        episodesToUpsert[targetEpisodeId] = Episode(
          id: targetEpisodeId,
          workId: targetWork.id,
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
        variant.copyWith(workId: targetWork.id, episodeId: targetEpisodeId),
      );
    }

    await repository.runInTransaction(() async {
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
              'pb::${targetWork.id}::$nextEpId',
            ),
            workId: targetWork.id,
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
      targetWorkId: targetWork.id,
      targetTitle: targetWork.title,
    );
  }
}
