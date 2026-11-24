import 'dart:io';

import '../../domain/models/episode.dart';
import '../../domain/models/media_source.dart';
import '../../domain/models/media_variant.dart';
import '../../domain/models/playback_record.dart';
import '../../domain/models/series_group.dart';
import '../../domain/models/work.dart';
import '../../domain/repositories/library_repository.dart';
import '../../domain/sync/konata_sync_models.dart';
import '../../infrastructure/sync/konata_sync_store.dart';

/// 完整媒体库目录落库后的精确变更统计。
class CatalogApplyStats {
  /// 创建目录落库统计。
  const CatalogApplyStats({
    this.worksSynced = 0,
    this.sourcesAdded = 0,
    this.worksDeleted = 0,
    this.sourcesNeedingPassword = 0,
  });

  final int worksSynced;
  final int sourcesAdded;
  final int worksDeleted;
  final int sourcesNeedingPassword;
}

/// 完整已整理媒体库的可移植导出与原子落库协调器。
///
/// 负责将本地 SQLite 中的媒体源元数据、系列编组、完整作品、逻辑剧集/特典、
/// 物理文件相对路径映射与忽略目录打包为 [SyncLibraryCatalog]，并在恢复或 WebDAV
/// 同步时以幂等、去重、守护本机媒体源密码的方式原子写入目标设备数据库。
abstract final class KonataLibraryCatalogApplier {
  /// 导出当前本机完整的已整理媒体库目录快照（绝不含任何媒体源密码）。
  static Future<SyncLibraryCatalog> buildLocalLibraryCatalog({
    required LibraryRepository repo,
    required KonataSyncStore syncStore,
    required String deviceId,
    required int nowMs,
  }) async {
    final sources = await repo.getMediaSources();
    final seriesGroups = await repo.getAllSeriesGroups();
    final works = await repo.getAllWorks();
    final episodes = await repo.getAllEpisodes();
    final variants = await repo.getAllVariants();
    final workUpdatedMap = await syncStore.readWorkUpdatedAtMsMap();

    final ignoredFolders = <SyncIgnoredFolderEntry>[];
    for (final src in sources) {
      final folders = await repo.getIgnoredFolders(src.id);
      for (final rel in folders) {
        final norm = SyncMediaVariantEntry.normalizeRelativePath(rel);
        if (norm.isNotEmpty) {
          ignoredFolders.add(
            SyncIgnoredFolderEntry(sourceId: src.id, relativePath: norm),
          );
        }
      }
    }

    final syncWorks = <SyncWorkEntry>[];
    for (final w in works) {
      final primaryKey = CanonicalWorkIdentity.primaryKeyFor(w);
      final secondaryKeys = CanonicalWorkIdentity.allKeysFor(
        w,
      ).where((k) => k != primaryKey).toList(growable: false);
      final storedUpdated = workUpdatedMap[w.id] ?? 0;
      syncWorks.add(
        SyncWorkEntry.fromWork(
          work: w,
          canonicalWorkKey: primaryKey,
          secondaryWorkKeys: secondaryKeys,
          updatedAtMs: storedUpdated > 0 ? storedUpdated : nowMs,
          sourceDeviceId: deviceId,
        ),
      );
    }

    return SyncLibraryCatalog(
      mediaSources: [
        for (final s in sources) SyncMediaSourceEntry.fromMediaSource(s),
      ],
      seriesGroups: [
        for (final g in seriesGroups) SyncSeriesGroupEntry.fromSeriesGroup(g),
      ],
      works: syncWorks,
      episodes: [for (final e in episodes) SyncEpisodeEntry.fromEpisode(e)],
      variants: [
        for (final v in variants) SyncMediaVariantEntry.fromMediaVariant(v),
      ],
      ignoredFolders: ignoredFolders,
    );
  }

  /// 在现有数据库事务内原子应用完整媒体库目录与作品删除墓碑。
  static Future<CatalogApplyStats> applyCatalogInTransaction({
    required LibraryRepository repo,
    required KonataSyncStore syncStore,
    required SyncLibraryCatalog? catalog,
    required Set<String> suppressedWorkKeys,
    required bool overwriteExistingCatalog,
    required bool preserveLocalPlaybacksOnOverwrite,
  }) async {
    var worksSynced = 0;
    var sourcesAdded = 0;
    var worksDeleted = 0;
    var sourcesNeedingPassword = 0;

    // 1) 若非覆盖模式且存在作品删除墓碑，先按跨端身份键或 ID 移除本地已删作品。
    if (!overwriteExistingCatalog && suppressedWorkKeys.isNotEmpty) {
      final localWorks = await repo.getAllWorks();
      for (final w in localWorks) {
        final isSuppressed =
            suppressedWorkKeys.contains(w.id) ||
            CanonicalWorkIdentity.allKeysFor(
              w,
            ).any(suppressedWorkKeys.contains);
        if (isSuppressed) {
          await repo.deleteWork(w.id);
          worksDeleted++;
        }
      }
    }

    if (catalog == null || catalog.isEmpty) {
      return CatalogApplyStats(worksDeleted: worksDeleted);
    }

    // 覆盖模式且未勾选覆盖播放记录时，先暂存本地播放历史，重建目录后再按作品还原，绝不误清。
    final preservedPlaybacks = <({List<String> workKeys, PlaybackRecord rec})>[];
    if (overwriteExistingCatalog && preserveLocalPlaybacksOnOverwrite) {
      final oldWorks = await repo.getAllWorks();
      final oldWorkById = <String, Work>{for (final w in oldWorks) w.id: w};
      final oldPlaybacks = await repo.getPlaybackHistory(limit: 10000);
      for (final rec in oldPlaybacks) {
        final work = oldWorkById[rec.workId];
        if (work == null) continue;
        preservedPlaybacks.add((
          workKeys: CanonicalWorkIdentity.allKeysFor(work),
          rec: rec,
        ));
      }
    }

    // 2) 对齐并写入媒体源（优先复用同 ID 或同协议地址的本机源，守护已加密存储的登录密码）。
    final existingSources = await repo.getMediaSources();
    final localSourceById = <String, MediaSource>{
      for (final s in existingSources) s.id: s,
    };
    final localSourceByLocKey = <String, MediaSource>{
      for (final s in existingSources)
        SyncMediaSourceEntry.normalizeLocationKey(s.kind, s.location): s,
    };
    final sourceIdMap = <String, String>{};
    final activeSourceIds = <String>{};

    for (final src in catalog.mediaSources) {
      if (src.id.isEmpty) continue;
      final locKey = src.normalizedLocationKey;
      final matchById = localSourceById[src.id];
      if (matchById != null) {
        sourceIdMap[src.id] = matchById.id;
        activeSourceIds.add(matchById.id);
        if (overwriteExistingCatalog &&
            _sourceFieldsChanged(matchById, src.toMediaSource(overrideId: matchById.id))) {
          await repo.upsertMediaSource(
            src.toMediaSource(overrideId: matchById.id),
          );
        }
        continue;
      }
      final matchByLoc = localSourceByLocKey[locKey];
      if (matchByLoc != null) {
        sourceIdMap[src.id] = matchByLoc.id;
        activeSourceIds.add(matchByLoc.id);
        continue;
      }
      final created = src.toMediaSource();
      await repo.upsertMediaSource(created);
      localSourceById[created.id] = created;
      localSourceByLocKey[locKey] = created;
      sourceIdMap[src.id] = created.id;
      activeSourceIds.add(created.id);
      sourcesAdded++;
      if (src.isRemoteWithUsername) {
        sourcesNeedingPassword++;
      }
    }

    // 3) 若处于覆盖媒体库模式，清理旧作品、旧系列与无归属旧媒体源（保留复用中的本地媒体源与密码）。
    if (overwriteExistingCatalog) {
      final oldWorks = await repo.getAllWorks();
      for (final oldWork in oldWorks) {
        await repo.deleteWork(oldWork.id);
      }
      final oldSeries = await repo.getAllSeriesGroups();
      for (final oldGroup in oldSeries) {
        await repo.deleteSeriesGroup(oldGroup.id);
      }
      for (final oldSource in existingSources) {
        if (!activeSourceIds.contains(oldSource.id)) {
          await repo.deleteMediaSource(oldSource.id);
        }
      }
    }

    // 4) 对齐并写入系列编组。
    final existingSeries = await repo.getAllSeriesGroups();
    final localSeriesById = <String, SeriesGroup>{
      for (final g in existingSeries) g.id: g,
    };
    final localSeriesByCollection = <int, SeriesGroup>{
      for (final g in existingSeries)
        if (g.tmdbCollectionId != null) g.tmdbCollectionId!: g,
    };
    final localSeriesByTitle = <String, SeriesGroup>{
      for (final g in existingSeries)
        if (CanonicalWorkIdentity.normalizeTitleKey(g.title).isNotEmpty)
          CanonicalWorkIdentity.normalizeTitleKey(g.title): g,
    };
    final seriesIdMap = <String, String>{};

    for (final group in catalog.seriesGroups) {
      if (group.id.isEmpty) continue;
      final titleKey = CanonicalWorkIdentity.normalizeTitleKey(group.title);
      final existing =
          localSeriesById[group.id] ??
          (group.tmdbCollectionId != null
              ? localSeriesByCollection[group.tmdbCollectionId!]
              : null) ??
          (titleKey.isNotEmpty ? localSeriesByTitle[titleKey] : null);
      if (existing != null) {
        seriesIdMap[group.id] = existing.id;
        final candidate = group.toSeriesGroup(overrideId: existing.id);
        if (_seriesChanged(existing, candidate)) {
          await repo.upsertSeriesGroup(candidate);
          localSeriesById[existing.id] = candidate;
        }
      } else {
        final created = group.toSeriesGroup();
        await repo.upsertSeriesGroup(created);
        localSeriesById[created.id] = created;
        if (created.tmdbCollectionId != null) {
          localSeriesByCollection[created.tmdbCollectionId!] = created;
        }
        if (titleKey.isNotEmpty) {
          localSeriesByTitle[titleKey] = created;
        }
        seriesIdMap[group.id] = created.id;
      }
    }

    // 5) 写入或幂等更新完整作品元数据（非 Windows 平台自动屏蔽 Windows 盘符本地图片路径）。
    final sanitizeWindowsArtwork = !Platform.isWindows;
    final existingWorks = await repo.getAllWorks();
    final localWorkById = <String, Work>{for (final w in existingWorks) w.id: w};
    final localWorkByCanonical = <String, Work>{};
    for (final w in existingWorks) {
      for (final key in CanonicalWorkIdentity.allKeysFor(w)) {
        localWorkByCanonical.putIfAbsent(key, () => w);
      }
    }

    final workIdMap = <String, String>{};
    final usedLocalWorkIds = <String>{};
    for (final entry in catalog.works) {
      if (entry.id.isEmpty) continue;
      final mappedSeriesId = entry.seriesId == null
          ? null
          : (seriesIdMap[entry.seriesId!] ?? entry.seriesId);
      Work? existing = localWorkById[entry.id];
      if (existing == null) {
        for (final key in entry.allWorkKeys) {
          final hit = localWorkByCanonical[key];
          if (hit != null && !usedLocalWorkIds.contains(hit.id)) {
            existing = hit;
            break;
          }
        }
      }
      final targetWorkId = existing?.id ?? entry.id;
      usedLocalWorkIds.add(targetWorkId);
      workIdMap[entry.id] = targetWorkId;

      final nextWork = entry.toWork(
        overrideId: targetWorkId,
        overrideSeriesId: mappedSeriesId,
        sanitizeWindowsLocalArtworkPaths: sanitizeWindowsArtwork,
      );
      if (existing == null || _workCatalogFieldsChanged(existing, nextWork)) {
        await repo.upsertWork(nextWork);
        if (entry.updatedAtMs > 0) {
          await syncStore.setWorkUpdatedAtMs(targetWorkId, entry.updatedAtMs);
        }
        localWorkById[targetWorkId] = nextWork;
        worksSynced++;
      }
    }

    // 6) 批量对齐并写入逻辑剧集与特典。
    final existingEpisodes = await repo.getAllEpisodes();
    final localEpById = <String, Episode>{
      for (final ep in existingEpisodes) ep.id: ep,
    };
    final localEpBySlot = <String, Episode>{
      for (final ep in existingEpisodes) _episodeSlotKey(ep.workId, ep): ep,
    };
    final episodeIdMap = <String, String>{};
    final episodesToUpsert = <Episode>[];

    for (final epEntry in catalog.episodes) {
      if (epEntry.id.isEmpty) continue;
      final targetWorkId = workIdMap[epEntry.workId];
      if (targetWorkId == null) continue;
      final candidateRaw = epEntry.toEpisode(
        overrideWorkId: targetWorkId,
        sanitizeWindowsLocalArtworkPaths: sanitizeWindowsArtwork,
      );
      final slotKey = _episodeSlotKey(targetWorkId, candidateRaw);
      final existingById = localEpById[epEntry.id];
      final existing =
          (existingById != null && existingById.workId == targetWorkId)
          ? existingById
          : localEpBySlot[slotKey];
      final targetEpId =
          existing?.id ??
          (localEpById.containsKey(epEntry.id)
              ? '$targetWorkId::${epEntry.id}'
              : epEntry.id);
      final nextEp = epEntry.toEpisode(
        overrideId: targetEpId,
        overrideWorkId: targetWorkId,
        sanitizeWindowsLocalArtworkPaths: sanitizeWindowsArtwork,
      );
      episodeIdMap[epEntry.id] = targetEpId;
      if (existing == null || _episodeChanged(existing, nextEp)) {
        episodesToUpsert.add(nextEp);
        localEpById[targetEpId] = nextEp;
        localEpBySlot[slotKey] = nextEp;
      }
    }
    if (episodesToUpsert.isNotEmpty) {
      await repo.upsertEpisodesBatch(episodesToUpsert);
    }

    // 7) 批量对齐并写入物理文件变体与人工映射锁。
    final existingVariants = await repo.getAllVariants();
    final localVarById = <String, MediaVariant>{
      for (final v in existingVariants) v.id: v,
    };
    final localVarBySourcePath = <String, MediaVariant>{
      for (final v in existingVariants)
        '${v.sourceId}::${SyncMediaVariantEntry.normalizeRelativePath(v.relativePath).toLowerCase()}':
            v,
    };
    final variantsToUpsert = <MediaVariant>[];

    for (final vEntry in catalog.variants) {
      if (vEntry.id.isEmpty) continue;
      final targetWorkId = workIdMap[vEntry.workId];
      final targetSourceId = sourceIdMap[vEntry.sourceId];
      if (targetWorkId == null || targetSourceId == null) continue;
      final targetEpId = vEntry.episodeId == null
          ? null
          : episodeIdMap[vEntry.episodeId!];
      final pathKey =
          '$targetSourceId::${vEntry.normalizedRelativePath.toLowerCase()}';
      final existingById = localVarById[vEntry.id];
      final existing =
          (existingById != null && existingById.sourceId == targetSourceId)
          ? existingById
          : localVarBySourcePath[pathKey];
      final targetVarId =
          existing?.id ??
          (localVarById.containsKey(vEntry.id)
              ? '$targetSourceId::${vEntry.id}'
              : vEntry.id);
      final nextVar = vEntry.toMediaVariant(
        overrideId: targetVarId,
        overrideWorkId: targetWorkId,
        overrideEpisodeId: targetEpId,
        clearEpisodeId: targetEpId == null,
        overrideSourceId: targetSourceId,
      );
      if (existing == null || _variantChanged(existing, nextVar)) {
        variantsToUpsert.add(nextVar);
        localVarById[targetVarId] = nextVar;
        localVarBySourcePath[pathKey] = nextVar;
      }
    }
    if (variantsToUpsert.isNotEmpty) {
      await repo.upsertMediaVariantsBatch(variantsToUpsert);
    }

    // 8) 同步媒体源忽略目录。
    final existingIgnoredBySource = <String, Set<String>>{};
    for (final srcId in activeSourceIds) {
      final list = await repo.getIgnoredFolders(srcId);
      existingIgnoredBySource[srcId] = {
        for (final rel in list)
          SyncMediaVariantEntry.normalizeRelativePath(rel).toLowerCase(),
      };
    }
    for (final folder in catalog.ignoredFolders) {
      final mappedSourceId = sourceIdMap[folder.sourceId];
      if (mappedSourceId == null) continue;
      final norm = SyncMediaVariantEntry.normalizeRelativePath(
        folder.relativePath,
      );
      if (norm.isEmpty) continue;
      final seen = existingIgnoredBySource.putIfAbsent(
        mappedSourceId,
        () => <String>{},
      );
      if (seen.add(norm.toLowerCase())) {
        await repo.addIgnoredFolder(mappedSourceId, norm);
      }
    }

    // 9) 若覆盖媒体库但用户未勾选覆盖播放记录，按跨端身份键还原暂存的本机播放进度。
    if (preservedPlaybacks.isNotEmpty) {
      final rebuiltWorks = await repo.getAllWorks();
      final rebuiltByKey = <String, Work>{};
      for (final w in rebuiltWorks) {
        for (final k in CanonicalWorkIdentity.allKeysFor(w)) {
          rebuiltByKey.putIfAbsent(k, () => w);
        }
      }
      final rebuiltEps = await repo.getAllEpisodes();
      final rebuiltEpsByWork = <String, List<Episode>>{};
      for (final ep in rebuiltEps) {
        rebuiltEpsByWork.putIfAbsent(ep.workId, () => <Episode>[]).add(ep);
      }
      for (final saved in preservedPlaybacks) {
        Work? matched;
        for (final k in saved.workKeys) {
          matched = rebuiltByKey[k];
          if (matched != null) break;
        }
        if (matched == null) continue;
        final rec = saved.rec;
        if (rec.isAudioRecord) {
          await repo.recordPlayback(
            PlaybackRecord(
              id: rec.id,
              workId: matched.id,
              episodeId: rec.episodeId,
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
          continue;
        }
        final workEps = rebuiltEpsByWork[matched.id] ?? const <Episode>[];
        Episode? matchedEp;
        for (final ep in workEps) {
          if (ep.seasonNumber == rec.seasonNumber &&
              ep.episodeNumber == rec.episodeNumber) {
            matchedEp = ep;
            break;
          }
        }
        if (matchedEp == null) continue;
        await repo.recordPlayback(
          PlaybackRecord(
            id: '${matched.id}::${matchedEp.id}',
            workId: matched.id,
            episodeId: matchedEp.id,
            variantId: rec.variantId,
            seasonNumber: matchedEp.seasonNumber,
            episodeNumber: matchedEp.episodeNumber,
            episodeTitle: rec.episodeTitle,
            sourceType: rec.sourceType,
            playedAt: rec.playedAt,
            positionSeconds: rec.positionSeconds,
            durationSeconds: rec.durationSeconds,
            isCompleted: rec.isCompleted,
          ),
        );
      }
    }

    return CatalogApplyStats(
      worksSynced: worksSynced,
      sourcesAdded: sourcesAdded,
      worksDeleted: worksDeleted,
      sourcesNeedingPassword: sourcesNeedingPassword,
    );
  }

  /// 统计目标备份中的新增远程带账号源数量（本机尚未保存对应地址时提醒恢复后补填密码）。
  static Future<int> countRemoteSourcesNeedingPassword({
    required LibraryRepository repo,
    required SyncLibraryCatalog catalog,
  }) async {
    final existingSources = await repo.getMediaSources();
    final localIds = <String>{for (final s in existingSources) s.id};
    final localLocKeys = <String>{
      for (final s in existingSources)
        SyncMediaSourceEntry.normalizeLocationKey(s.kind, s.location),
    };
    var count = 0;
    for (final src in catalog.mediaSources) {
      if (!src.isRemoteWithUsername) continue;
      if (localIds.contains(src.id) ||
          localLocKeys.contains(src.normalizedLocationKey)) {
        continue;
      }
      count++;
    }
    return count;
  }

  static String _episodeSlotKey(String workId, Episode ep) {
    if (ep.category == EpisodeCategory.main && ep.episodeNumber != null) {
      return '$workId::main::s${ep.seasonNumber}::e${ep.episodeNumber}::${ep.episodeNumberEnd ?? ''}';
    }
    if (ep.category == EpisodeCategory.extra) {
      return '$workId::extra::${ep.extraType?.name ?? ''}::${ep.episodeNumber ?? ''}::${CanonicalWorkIdentity.normalizeTitleKey(ep.title ?? '')}';
    }
    return '$workId::single::${ep.category.name}::${CanonicalWorkIdentity.normalizeTitleKey(ep.title ?? '')}';
  }

  static bool _sourceFieldsChanged(MediaSource a, MediaSource b) {
    return a.kind != b.kind ||
        a.label != b.label ||
        a.location != b.location ||
        a.username != b.username;
  }

  static bool _seriesChanged(SeriesGroup a, SeriesGroup b) {
    return a.title != b.title ||
        a.tmdbCollectionId != b.tmdbCollectionId ||
        a.rootFolderHint != b.rootFolderHint;
  }

  static bool _workCatalogFieldsChanged(Work a, Work b) {
    return a.tmdbId != b.tmdbId ||
        a.tmdbMediaType != b.tmdbMediaType ||
        a.bangumiId != b.bangumiId ||
        a.tvdbId != b.tvdbId ||
        a.matchedSeason != b.matchedSeason ||
        a.title != b.title ||
        a.originalTitle != b.originalTitle ||
        a.year != b.year ||
        a.overview != b.overview ||
        a.posterPath != b.posterPath ||
        a.posterFallback != b.posterFallback ||
        a.bangumiPosterPath != b.bangumiPosterPath ||
        a.backdropPath != b.backdropPath ||
        a.logoPath != b.logoPath ||
        a.voteAverage != b.voteAverage ||
        a.bangumiScore != b.bangumiScore ||
        a.folderTmdbHint != b.folderTmdbHint ||
        a.isManualLocked != b.isManualLocked ||
        a.metadataLocked != b.metadataLocked ||
        a.posterLocked != b.posterLocked ||
        a.backdropLocked != b.backdropLocked ||
        a.logoLocked != b.logoLocked ||
        a.isHidden != b.isHidden ||
        a.keepHidden != b.keepHidden ||
        a.scrapeStatus != b.scrapeStatus ||
        a.reviewReason != b.reviewReason ||
        a.seriesId != b.seriesId ||
        a.seriesOrder != b.seriesOrder ||
        a.seriesLabel != b.seriesLabel ||
        a.seriesLocked != b.seriesLocked;
  }

  static bool _episodeChanged(Episode a, Episode b) {
    return a.workId != b.workId ||
        a.seasonNumber != b.seasonNumber ||
        a.episodeNumber != b.episodeNumber ||
        a.episodeNumberEnd != b.episodeNumberEnd ||
        a.category != b.category ||
        a.extraType != b.extraType ||
        a.title != b.title ||
        a.overview != b.overview ||
        a.stillPath != b.stillPath;
  }

  static bool _variantChanged(MediaVariant a, MediaVariant b) {
    if (a.workId != b.workId ||
        a.episodeId != b.episodeId ||
        a.sourceId != b.sourceId ||
        a.relativePath != b.relativePath ||
        a.fileName != b.fileName ||
        a.fileSize != b.fileSize ||
        a.assetKind != b.assetKind ||
        a.releaseGroup != b.releaseGroup ||
        a.subtitleGroup != b.subtitleGroup ||
        a.videoCodec != b.videoCodec ||
        a.bitDepth != b.bitDepth ||
        a.resolution != b.resolution ||
        a.audioCodec != b.audioCodec ||
        a.mappingLocked != b.mappingLocked ||
        a.workLocked != b.workLocked ||
        a.assetScope != b.assetScope ||
        a.scopeLocked != b.scopeLocked) {
      return true;
    }
    if (a.externalSubtitles.length != b.externalSubtitles.length) return true;
    for (var i = 0; i < a.externalSubtitles.length; i++) {
      if (a.externalSubtitles[i] != b.externalSubtitles[i]) return true;
    }
    return false;
  }
}
