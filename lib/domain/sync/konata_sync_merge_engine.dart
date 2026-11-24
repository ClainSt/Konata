import '../models/episode.dart';
import '../models/work.dart';
import 'konata_sync_models.dart';

/// 多设备同步合并结果容器（纯领域无副作用产出，交由应用层原子落库）。
class KonataSyncMergeResult {
  /// 创建合并结果。
  const KonataSyncMergeResult({
    required this.mergedPlaybacks,
    required this.mergedWorkOverrides,
    required this.mergedTombstones,
    required this.mergedPreferences,
    required this.suppressedPlaybackKeys,
    this.mergedCatalog,
    this.suppressedWorkKeys = const <String>{},
  });

  /// 冲突消解后的最终播放进度映射（按归一化 `playbackKey` 索引）。
  final Map<String, SyncPlaybackEntry> mergedPlaybacks;

  /// 冲突消解后的最终作品人工整理映射（按归一化 `canonicalWorkKey` 索引）。
  final Map<String, SyncWorkOverrideEntry> mergedWorkOverrides;

  /// 合并并清理过陈旧项后的删除墓碑映射（按 `entityKey` 索引）。
  final Map<String, SyncTombstoneEntry> mergedTombstones;

  /// 合并后的便携偏好设置包。
  final SyncPreferencesBundle mergedPreferences;

  /// 因远端存在更新时间戳删除墓碑而应当在本地移除的播放进度键集合（含全部等价别名键）。
  final Set<String> suppressedPlaybackKeys;

  /// 冲突消解后的完整已整理媒体库目录（v2 快照非空，旧版 v1 精简快照为空）。
  final SyncLibraryCatalog? mergedCatalog;

  /// 因远端存在更新时间戳作品删除墓碑而应当在本地移除的作品 ID 与跨端身份键集合。
  final Set<String> suppressedWorkKeys;

  /// 是否包含可落库的完整媒体库目录。
  bool get hasMergedCatalog =>
      mergedCatalog != null && mergedCatalog!.hasContent;
}

/// 无锁确定性多设备状态合并引擎（纯领域算法，满足交换律、结合律与幂等性）。
///
/// 合并核心规则：
/// 1. 跨源等价聚类：通过并查集将共享 `tmdb:` 或 `bgm:` 身份键的作品条目归入同一逻辑作品，
///    确保一端仅匹配 Bangumi、另一端同时匹配 TMDB+Bangumi 时同一集进度正确汇流而非彼此覆盖；
/// 2. 墓碑裁决：若某逻辑集对应的任一等价键存在 `deletedAtMs > entry.updatedAtMs` 墓碑，
///    则抑制旧条目防止复活并把所有等价键写入 [suppressedPlaybackKeys]；
/// 3. 播放进度：`isCompleted` 遵循单调或合并，播放位置与时间取 `updatedAtMs` / `playedAtMs` 更新的一侧；
/// 4. 作品整理锁/隐藏/系列与便携偏好：按 `updatedAtMs` 执行确定性最后写入胜出（LWW）。
abstract final class KonataSyncMergeEngine {
  /// 墓碑默认保留天数（超过 90 天自动回收，防止同步分片无限膨胀）。
  static const int tombstoneRetentionDays = 90;

  /// 将本地快照状态与一组远端设备快照执行确定性冲突消解合并。
  static KonataSyncMergeResult merge({
    required List<SyncPlaybackEntry> localPlaybacks,
    required List<SyncWorkOverrideEntry> localOverrides,
    required List<SyncTombstoneEntry> localTombstones,
    required SyncPreferencesBundle localPreferences,
    required List<KonataSyncSnapshotEnvelope> remoteSnapshots,
    required int nowMs,
    SyncLibraryCatalog? localCatalog,
    String localDeviceId = '',
  }) {
    final tombstones = <String, SyncTombstoneEntry>{};
    final retentionFloorMs =
        nowMs - Duration(days: tombstoneRetentionDays).inMilliseconds;

    void absorbTombstone(SyncTombstoneEntry item) {
      if (item.entityKey.isEmpty) return;
      if (item.deletedAtMs > 0 && item.deletedAtMs < retentionFloorMs) {
        return;
      }
      final prev = tombstones[item.entityKey];
      if (prev == null || item.deletedAtMs > prev.deletedAtMs) {
        tombstones[item.entityKey] = item;
      }
    }

    for (final t in localTombstones) {
      absorbTombstone(t);
    }
    for (final snap in remoteSnapshots) {
      for (final t in snap.tombstones) {
        absorbTombstone(t);
      }
    }

    // 1. 基于所有本地与远端条目的主/辅强身份键（tmdb: 与 bgm:）构建跨端等价作品聚类
    final aliasUnion = _WorkAliasUnion();
    void registerWorkKeys(Iterable<String> keys) {
      final strongKeys = <String>[
        for (final k in keys)
          if (k.startsWith('tmdb:') || k.startsWith('bgm:')) k,
      ];
      if (strongKeys.length >= 2) {
        for (var i = 1; i < strongKeys.length; i++) {
          aliasUnion.union(strongKeys.first, strongKeys[i]);
        }
      }
    }

    for (final e in localPlaybacks) {
      registerWorkKeys(e.allWorkKeys);
    }
    for (final o in localOverrides) {
      registerWorkKeys(o.allWorkKeys);
    }
    if (localCatalog != null) {
      for (final w in localCatalog.works) {
        registerWorkKeys(w.allWorkKeys);
      }
    }
    for (final snap in remoteSnapshots) {
      for (final e in snap.playbackEntries) {
        registerWorkKeys(e.allWorkKeys);
      }
      for (final o in snap.workOverrides) {
        registerWorkKeys(o.allWorkKeys);
      }
      final remoteCat = snap.libraryCatalog;
      if (remoteCat != null) {
        for (final w in remoteCat.works) {
          registerWorkKeys(w.allWorkKeys);
        }
      }
    }

    String resolveCanonicalWorkGroup(Iterable<String> keys, String fallback) {
      for (final k in keys) {
        if (k.startsWith('tmdb:') || k.startsWith('bgm:')) {
          return aliasUnion.findPreferredRepresentative(k);
        }
      }
      return fallback;
    }

    String buildClusterPlaybackKey(SyncPlaybackEntry entry) {
      final groupWorkKey = resolveCanonicalWorkGroup(
        entry.allWorkKeys,
        entry.canonicalWorkKey,
      );
      return CanonicalWorkIdentity.playbackKey(
        canonicalWorkKey: groupWorkKey,
        seasonNumber: entry.seasonNumber,
        episodeNumber: entry.episodeNumber,
        isAudio: entry.isAudio,
        audioTrackHint: entry.isAudio ? entry.episodeTitle : null,
      );
    }

    // 2. 按跨端等价集键合并播放进度
    final playbacks = <String, SyncPlaybackEntry>{};
    void absorbPlayback(SyncPlaybackEntry entry) {
      if (entry.playbackKey.isEmpty) return;
      final clusterKey = buildClusterPlaybackKey(entry);
      final normalized = entry.copyWith(playbackKey: clusterKey);
      final existing = playbacks[clusterKey];
      if (existing == null) {
        playbacks[clusterKey] = normalized;
      } else {
        playbacks[clusterKey] = _mergeSinglePlayback(existing, normalized);
      }
    }

    for (final entry in localPlaybacks) {
      absorbPlayback(entry);
    }
    for (final snap in remoteSnapshots) {
      for (final remote in snap.playbackEntries) {
        absorbPlayback(remote);
      }
    }

    // 3. 墓碑匹配（支持任意等价别名键触发删除，且产出全部等价键供本地精确移除）
    final suppressedPlaybackKeys = <String>{};
    playbacks.removeWhere((clusterKey, entry) {
      final candidateKeys = _allPlaybackAliasKeys(entry, aliasUnion)
        ..add(clusterKey);
      SyncTombstoneEntry? latestTomb;
      for (final key in candidateKeys) {
        final tomb = tombstones[key];
        if (tomb != null &&
            (latestTomb == null || tomb.deletedAtMs > latestTomb.deletedAtMs)) {
          latestTomb = tomb;
        }
      }
      if (latestTomb != null && latestTomb.deletedAtMs > entry.updatedAtMs) {
        suppressedPlaybackKeys.addAll(candidateKeys);
        return true;
      }
      return false;
    });

    // 4. 按跨端等价作品键合并作品整理锁、隐藏态与系列编组
    final overrides = <String, SyncWorkOverrideEntry>{};
    void absorbOverride(SyncWorkOverrideEntry ov) {
      if (ov.canonicalWorkKey.isEmpty) return;
      final groupKey = resolveCanonicalWorkGroup(
        ov.allWorkKeys,
        ov.canonicalWorkKey,
      );
      final existing = overrides[groupKey];
      if (existing == null || _isNewerOverride(ov, existing)) {
        overrides[groupKey] = ov;
      }
    }

    for (final ov in localOverrides) {
      absorbOverride(ov);
    }
    for (final snap in remoteSnapshots) {
      for (final remote in snap.workOverrides) {
        absorbOverride(remote);
      }
    }
    overrides.removeWhere((groupKey, entry) {
      final tomb = tombstones['work_override::$groupKey'] ??
          tombstones['work_override::${entry.canonicalWorkKey}'];
      return tomb != null && tomb.deletedAtMs > entry.updatedAtMs;
    });

    // 5. 合并便携偏好设置包
    var winningPrefs = localPreferences;
    for (final snap in remoteSnapshots) {
      final candidate = snap.preferences;
      if (candidate.values.isNotEmpty &&
          candidate.updatedAtMs >= winningPrefs.updatedAtMs &&
          (candidate.updatedAtMs > winningPrefs.updatedAtMs ||
              winningPrefs.updatedAtMs == 0)) {
        winningPrefs = candidate;
      }
    }

    // 6. 合并完整已整理媒体库目录（媒体源、系列、作品、剧集、物理文件变体与忽略目录）
    final catalogMerge = _mergeLibraryCatalogs(
      localCatalog: localCatalog,
      localDeviceId: localDeviceId,
      remoteSnapshots: remoteSnapshots,
      tombstones: tombstones,
      resolveCanonicalWorkGroup: resolveCanonicalWorkGroup,
    );

    return KonataSyncMergeResult(
      mergedPlaybacks: playbacks,
      mergedWorkOverrides: overrides,
      mergedTombstones: tombstones,
      mergedPreferences: winningPrefs,
      suppressedPlaybackKeys: suppressedPlaybackKeys,
      mergedCatalog: catalogMerge.catalog,
      suppressedWorkKeys: catalogMerge.suppressedWorkKeys,
    );
  }

  static ({SyncLibraryCatalog? catalog, Set<String> suppressedWorkKeys})
  _mergeLibraryCatalogs({
    required SyncLibraryCatalog? localCatalog,
    required String localDeviceId,
    required List<KonataSyncSnapshotEnvelope> remoteSnapshots,
    required Map<String, SyncTombstoneEntry> tombstones,
    required String Function(Iterable<String> keys, String fallback)
    resolveCanonicalWorkGroup,
  }) {
    final hasAnyRemote = remoteSnapshots.any((s) => s.hasLibraryCatalog);
    final hasLocal = localCatalog != null && localCatalog.hasContent;
    if (!hasLocal && !hasAnyRemote) {
      return (catalog: null, suppressedWorkKeys: const <String>{});
    }

    final orderedRemotes =
        remoteSnapshots.where((s) => s.hasLibraryCatalog).toList()
          ..sort((a, b) => a.exportedAtMs.compareTo(b.exportedAtMs));

    final batches = <({bool isLocal, SyncLibraryCatalog catalog})>[
      if (hasLocal) (isLocal: true, catalog: localCatalog),
      for (final snap in orderedRemotes)
        (isLocal: false, catalog: snap.libraryCatalog!),
    ];

    final mergedSources = <String, SyncMediaSourceEntry>{};
    final sourceIdByLocKey = <String, String>{};
    final mergedSeries = <String, SyncSeriesGroupEntry>{};
    final seriesIdByCollection = <int, String>{};
    final seriesIdByTitle = <String, String>{};
    final mergedWorks = <String, SyncWorkEntry>{};
    final workIdByClusterKey = <String, String>{};
    final mergedEpisodes = <String, SyncEpisodeEntry>{};
    final episodeIdBySlotKey = <String, String>{};
    final mergedVariants = <String, SyncMediaVariantEntry>{};
    final variantIdBySourcePath = <String, String>{};
    final mergedIgnored = <String, SyncIgnoredFolderEntry>{};
    final suppressedWorkKeys = <String>{};

    bool isWorkSuppressed(SyncWorkEntry work, String groupKey) {
      final candidateKeys = <String>{
        if (work.id.isNotEmpty) 'work_id::${work.id}',
        if (groupKey.isNotEmpty) 'work_catalog::$groupKey',
        for (final k in work.allWorkKeys) 'work_catalog::$k',
      };
      SyncTombstoneEntry? latest;
      for (final k in candidateKeys) {
        final tomb = tombstones[k];
        if (tomb != null &&
            (latest == null || tomb.deletedAtMs > latest.deletedAtMs)) {
          latest = tomb;
        }
      }
      if (latest != null && latest.deletedAtMs > work.updatedAtMs) {
        if (work.id.isNotEmpty) suppressedWorkKeys.add(work.id);
        if (groupKey.isNotEmpty) suppressedWorkKeys.add(groupKey);
        suppressedWorkKeys.addAll(work.allWorkKeys);
        return true;
      }
      return false;
    }

    for (final batch in batches) {
      final cat = batch.catalog;

      // 1) 媒体源按 ID -> 归一化协议地址 去重对齐，保留本机媒体源 ID 以守护本地安全密码。
      final sourceRemap = <String, String>{};
      for (final src in cat.mediaSources) {
        if (src.id.isEmpty) continue;
        final locKey = src.normalizedLocationKey;
        final existingById = mergedSources[src.id];
        if (existingById != null) {
          sourceRemap[src.id] = existingById.id;
          sourceIdByLocKey.putIfAbsent(locKey, () => existingById.id);
          continue;
        }
        final existingByLoc = sourceIdByLocKey[locKey];
        if (existingByLoc != null) {
          sourceRemap[src.id] = existingByLoc;
          continue;
        }
        mergedSources[src.id] = src;
        sourceIdByLocKey[locKey] = src.id;
        sourceRemap[src.id] = src.id;
      }

      // 2) 系列编组按 ID -> TMDB Collection -> 归一化标题 去重合并。
      final seriesRemap = <String, String>{};
      for (final group in cat.seriesGroups) {
        if (group.id.isEmpty) continue;
        final titleKey = CanonicalWorkIdentity.normalizeTitleKey(group.title);
        String? targetId;
        if (mergedSeries.containsKey(group.id)) {
          targetId = group.id;
        } else if (group.tmdbCollectionId != null &&
            seriesIdByCollection.containsKey(group.tmdbCollectionId!)) {
          targetId = seriesIdByCollection[group.tmdbCollectionId!];
        } else if (titleKey.isNotEmpty &&
            seriesIdByTitle.containsKey(titleKey)) {
          targetId = seriesIdByTitle[titleKey];
        }
        if (targetId == null) {
          mergedSeries[group.id] = group;
          targetId = group.id;
        } else {
          final prev = mergedSeries[targetId]!;
          if (group.updatedAtMs > prev.updatedAtMs) {
            mergedSeries[targetId] = SyncSeriesGroupEntry(
              id: targetId,
              title: group.title.isNotEmpty ? group.title : prev.title,
              tmdbCollectionId:
                  group.tmdbCollectionId ?? prev.tmdbCollectionId,
              rootFolderHint: group.rootFolderHint ?? prev.rootFolderHint,
              createdAtMs: prev.createdAtMs > 0
                  ? prev.createdAtMs
                  : group.createdAtMs,
              updatedAtMs: group.updatedAtMs,
            );
          }
        }
        seriesRemap[group.id] = targetId;
        if (group.tmdbCollectionId != null) {
          seriesIdByCollection.putIfAbsent(
            group.tmdbCollectionId!,
            () => targetId!,
          );
        }
        if (titleKey.isNotEmpty) {
          seriesIdByTitle.putIfAbsent(titleKey, () => targetId!);
        }
      }

      // 3) 作品按 ID -> 跨端等价聚类 合并，同时支持删除墓碑抑制与同设备双源双卡保留。
      final workRemap = <String, String>{};
      final droppedWorkIds = <String>{};
      final seenClusterInBatch = <String>{};
      for (final work in cat.works) {
        if (work.id.isEmpty) continue;
        final groupKey = resolveCanonicalWorkGroup(
          work.allWorkKeys,
          work.canonicalWorkKey,
        );
        if (isWorkSuppressed(work, groupKey)) {
          droppedWorkIds.add(work.id);
          continue;
        }
        final remappedSeriesId = work.seriesId == null
            ? null
            : (seriesRemap[work.seriesId!] ?? work.seriesId);
        final normalizedWork = work.copyWith(
          seriesId: remappedSeriesId,
          clearSeriesId: remappedSeriesId == null,
        );

        String targetWorkId;
        if (mergedWorks.containsKey(work.id)) {
          targetWorkId = work.id;
        } else if (groupKey.isNotEmpty &&
            !seenClusterInBatch.contains(groupKey) &&
            workIdByClusterKey.containsKey(groupKey)) {
          targetWorkId = workIdByClusterKey[groupKey]!;
        } else {
          targetWorkId = work.id;
        }
        if (groupKey.isNotEmpty) {
          seenClusterInBatch.add(groupKey);
          workIdByClusterKey.putIfAbsent(groupKey, () => targetWorkId);
        }

        final existing = mergedWorks[targetWorkId];
        if (existing == null) {
          mergedWorks[targetWorkId] = normalizedWork.copyWith(id: targetWorkId);
        } else {
          mergedWorks[targetWorkId] = _mergeSingleWork(
            existing,
            normalizedWork,
            keepId: targetWorkId,
          );
        }
        workRemap[work.id] = targetWorkId;
      }

      // 4) 逻辑剧集与特典按 (workId, 分类, 季/集号/特典标题) 去重并补全丰富元数据。
      final episodeRemap = <String, String>{};
      for (final ep in cat.episodes) {
        if (ep.id.isEmpty || droppedWorkIds.contains(ep.workId)) continue;
        final targetWorkId = workRemap[ep.workId];
        if (targetWorkId == null) continue;
        final slotKey = _buildEpisodeSlotKey(targetWorkId, ep);
        String? targetEpId;
        final existingById = mergedEpisodes[ep.id];
        if (existingById != null && existingById.workId == targetWorkId) {
          targetEpId = ep.id;
        } else if (episodeIdBySlotKey.containsKey(slotKey)) {
          targetEpId = episodeIdBySlotKey[slotKey];
        }
        if (targetEpId == null) {
          targetEpId = mergedEpisodes.containsKey(ep.id)
              ? '$targetWorkId::${ep.id}'
              : ep.id;
          mergedEpisodes[targetEpId] = ep.copyWith(
            id: targetEpId,
            workId: targetWorkId,
          );
        } else {
          final prev = mergedEpisodes[targetEpId]!;
          mergedEpisodes[targetEpId] = _mergeSingleEpisode(prev, ep);
        }
        episodeIdBySlotKey.putIfAbsent(slotKey, () => targetEpId!);
        episodeRemap[ep.id] = targetEpId;
      }

      // 5) 物理文件变体按 (映射后 sourceId, 归一化相对路径) 去重并保留人工锁定映射。
      for (final v in cat.variants) {
        if (v.id.isEmpty || droppedWorkIds.contains(v.workId)) continue;
        final targetWorkId = workRemap[v.workId];
        if (targetWorkId == null) continue;
        final targetSourceId = sourceRemap[v.sourceId] ?? v.sourceId;
        if (!mergedSources.containsKey(targetSourceId)) continue;
        final targetEpId = v.episodeId == null
            ? null
            : (episodeRemap[v.episodeId!] ?? v.episodeId);
        final pathKey =
            '$targetSourceId::${v.normalizedRelativePath.toLowerCase()}';
        String? targetVarId;
        final existingById = mergedVariants[v.id];
        if (existingById != null && existingById.sourceId == targetSourceId) {
          targetVarId = v.id;
        } else if (variantIdBySourcePath.containsKey(pathKey)) {
          targetVarId = variantIdBySourcePath[pathKey];
        }
        final incomingRemapped = v.copyWith(
          id: targetVarId ?? v.id,
          workId: targetWorkId,
          episodeId: targetEpId,
          clearEpisodeId: targetEpId == null,
          sourceId: targetSourceId,
        );
        if (targetVarId == null) {
          final safeId = mergedVariants.containsKey(v.id)
              ? '$targetSourceId::${v.id}'
              : v.id;
          mergedVariants[safeId] = incomingRemapped.copyWith(id: safeId);
          variantIdBySourcePath[pathKey] = safeId;
        } else {
          final prev = mergedVariants[targetVarId]!;
          mergedVariants[targetVarId] = _mergeSingleVariant(
            prev,
            incomingRemapped,
          );
        }
      }

      // 6) 忽略目录按 (映射后 sourceId, 归一化相对路径) 幂等合并。
      for (final f in cat.ignoredFolders) {
        final targetSourceId = sourceRemap[f.sourceId] ?? f.sourceId;
        if (!mergedSources.containsKey(targetSourceId)) continue;
        final normPath = SyncMediaVariantEntry.normalizeRelativePath(
          f.relativePath,
        );
        if (normPath.isEmpty) continue;
        final key = '$targetSourceId::${normPath.toLowerCase()}';
        mergedIgnored.putIfAbsent(
          key,
          () => SyncIgnoredFolderEntry(
            sourceId: targetSourceId,
            relativePath: normPath,
          ),
        );
      }
    }

    return (
      catalog: SyncLibraryCatalog(
        mediaSources: mergedSources.values.toList(growable: false),
        seriesGroups: mergedSeries.values.toList(growable: false),
        works: mergedWorks.values.toList(growable: false),
        episodes: mergedEpisodes.values.toList(growable: false),
        variants: mergedVariants.values.toList(growable: false),
        ignoredFolders: mergedIgnored.values.toList(growable: false),
      ),
      suppressedWorkKeys: suppressedWorkKeys,
    );
  }

  static SyncWorkEntry _mergeSingleWork(
    SyncWorkEntry existing,
    SyncWorkEntry incoming, {
    required String keepId,
  }) {
    final bool incomingWins;
    if (incoming.updatedAtMs != existing.updatedAtMs) {
      incomingWins = incoming.updatedAtMs > existing.updatedAtMs;
    } else if (incoming.scrapeStatus != existing.scrapeStatus) {
      incomingWins = incoming.scrapeStatus == ScrapeStatus.matched;
    } else {
      incomingWins =
          _workRichnessScore(incoming) > _workRichnessScore(existing);
    }
    final winner = incomingWins ? incoming : existing;
    final loser = incomingWins ? existing : incoming;

    final allKeys = <String>[
      winner.canonicalWorkKey,
      ...winner.secondaryWorkKeys,
      loser.canonicalWorkKey,
      ...loser.secondaryWorkKeys,
    ];
    final primary = _pickPreferredWorkKey(allKeys);
    final secondary = <String>[];
    for (final k in allKeys) {
      if (k.isNotEmpty && k != primary && !secondary.contains(k)) {
        secondary.add(k);
      }
    }

    String? pickNonEmpty(String? a, String? b) =>
        (a != null && a.trim().isNotEmpty) ? a : b;

    return SyncWorkEntry(
      id: keepId,
      canonicalWorkKey: primary,
      secondaryWorkKeys: secondary,
      title: winner.title.trim().isNotEmpty ? winner.title : loser.title,
      tmdbId: winner.tmdbId ?? loser.tmdbId,
      tmdbMediaType: winner.tmdbMediaType ?? loser.tmdbMediaType,
      bangumiId: winner.bangumiId ?? loser.bangumiId,
      tvdbId: winner.tvdbId ?? loser.tvdbId,
      matchedSeason: winner.matchedSeason ?? loser.matchedSeason,
      originalTitle: pickNonEmpty(winner.originalTitle, loser.originalTitle),
      year: winner.year ?? loser.year,
      overview: pickNonEmpty(winner.overview, loser.overview),
      posterPath: pickNonEmpty(winner.posterPath, loser.posterPath),
      posterFallback: pickNonEmpty(winner.posterFallback, loser.posterFallback),
      bangumiPosterPath: pickNonEmpty(
        winner.bangumiPosterPath,
        loser.bangumiPosterPath,
      ),
      backdropPath: pickNonEmpty(winner.backdropPath, loser.backdropPath),
      logoPath: pickNonEmpty(winner.logoPath, loser.logoPath),
      voteAverage: winner.voteAverage ?? loser.voteAverage,
      bangumiScore: winner.bangumiScore ?? loser.bangumiScore,
      folderTmdbHint: winner.folderTmdbHint ?? loser.folderTmdbHint,
      isManualLocked: existing.isManualLocked || incoming.isManualLocked,
      metadataLocked: existing.metadataLocked || incoming.metadataLocked,
      posterLocked: existing.posterLocked || incoming.posterLocked,
      backdropLocked: existing.backdropLocked || incoming.backdropLocked,
      logoLocked: existing.logoLocked || incoming.logoLocked,
      isHidden: winner.isHidden,
      keepHidden: winner.keepHidden,
      scrapeStatus:
          winner.scrapeStatus == ScrapeStatus.unmatched &&
              loser.scrapeStatus != ScrapeStatus.unmatched
          ? loser.scrapeStatus
          : winner.scrapeStatus,
      reviewReason: winner.scrapeStatus == ScrapeStatus.matched
          ? null
          : pickNonEmpty(winner.reviewReason, loser.reviewReason),
      seriesId: pickNonEmpty(winner.seriesId, loser.seriesId),
      seriesOrder: winner.seriesOrder ?? loser.seriesOrder,
      seriesLabel: pickNonEmpty(winner.seriesLabel, loser.seriesLabel),
      seriesLocked: existing.seriesLocked || incoming.seriesLocked,
      updatedAtMs: winner.updatedAtMs >= loser.updatedAtMs
          ? winner.updatedAtMs
          : loser.updatedAtMs,
      sourceDeviceId: winner.sourceDeviceId.isNotEmpty
          ? winner.sourceDeviceId
          : loser.sourceDeviceId,
    );
  }

  static int _workRichnessScore(SyncWorkEntry w) {
    var score = 0;
    if (w.scrapeStatus == ScrapeStatus.matched) score += 8;
    if (w.tmdbId != null) score += 4;
    if (w.bangumiId != null) score += 4;
    if (w.isManualLocked || w.metadataLocked) score += 3;
    if (w.posterPath != null && w.posterPath!.isNotEmpty) score += 2;
    if (w.backdropPath != null && w.backdropPath!.isNotEmpty) score += 2;
    if (w.logoPath != null && w.logoPath!.isNotEmpty) score += 2;
    if (w.overview != null && w.overview!.isNotEmpty) score += 1;
    if (w.seriesId != null && w.seriesId!.isNotEmpty) score += 1;
    return score;
  }

  static String _buildEpisodeSlotKey(String workId, SyncEpisodeEntry ep) {
    if (ep.category == EpisodeCategory.main && ep.episodeNumber != null) {
      return '$workId::main::s${ep.seasonNumber}::e${ep.episodeNumber}::${ep.episodeNumberEnd ?? ''}';
    }
    if (ep.category == EpisodeCategory.extra) {
      return '$workId::extra::${ep.extraType?.name ?? ''}::${ep.episodeNumber ?? ''}::${CanonicalWorkIdentity.normalizeTitleKey(ep.title ?? '')}';
    }
    return '$workId::single::${ep.category.name}::${CanonicalWorkIdentity.normalizeTitleKey(ep.title ?? '')}';
  }

  static SyncEpisodeEntry _mergeSingleEpisode(
    SyncEpisodeEntry existing,
    SyncEpisodeEntry incoming,
  ) {
    String? pickNonEmpty(String? a, String? b) =>
        (a != null && a.trim().isNotEmpty) ? a : b;
    return SyncEpisodeEntry(
      id: existing.id,
      workId: existing.workId,
      seasonNumber: existing.seasonNumber,
      episodeNumber: existing.episodeNumber ?? incoming.episodeNumber,
      episodeNumberEnd: existing.episodeNumberEnd ?? incoming.episodeNumberEnd,
      category: existing.category,
      extraType: existing.extraType ?? incoming.extraType,
      title: pickNonEmpty(incoming.title, existing.title),
      overview: pickNonEmpty(incoming.overview, existing.overview),
      stillPath: pickNonEmpty(incoming.stillPath, existing.stillPath),
    );
  }

  static SyncMediaVariantEntry _mergeSingleVariant(
    SyncMediaVariantEntry existing,
    SyncMediaVariantEntry incoming,
  ) {
    final useIncomingMapping =
        incoming.mappingLocked && !existing.mappingLocked;
    final useIncomingWork = incoming.workLocked && !existing.workLocked;
    final useIncomingScope = incoming.scopeLocked && !existing.scopeLocked;
    return SyncMediaVariantEntry(
      id: existing.id,
      workId: useIncomingWork ? incoming.workId : existing.workId,
      episodeId: useIncomingMapping
          ? (incoming.episodeId ?? existing.episodeId)
          : (existing.episodeId ?? incoming.episodeId),
      sourceId: existing.sourceId,
      relativePath: existing.relativePath,
      fileName: existing.fileName.isNotEmpty
          ? existing.fileName
          : incoming.fileName,
      fileSize: existing.fileSize > 0 ? existing.fileSize : incoming.fileSize,
      assetKind: existing.assetKind,
      releaseGroup: existing.releaseGroup ?? incoming.releaseGroup,
      subtitleGroup: existing.subtitleGroup ?? incoming.subtitleGroup,
      videoCodec: existing.videoCodec ?? incoming.videoCodec,
      bitDepth: existing.bitDepth ?? incoming.bitDepth,
      resolution: existing.resolution ?? incoming.resolution,
      audioCodec: existing.audioCodec ?? incoming.audioCodec,
      externalSubtitles: existing.externalSubtitles.isNotEmpty
          ? existing.externalSubtitles
          : incoming.externalSubtitles,
      mappingLocked: existing.mappingLocked || incoming.mappingLocked,
      workLocked: existing.workLocked || incoming.workLocked,
      assetScope: useIncomingScope ? incoming.assetScope : existing.assetScope,
      scopeLocked: existing.scopeLocked || incoming.scopeLocked,
    );
  }

  static Set<String> _allPlaybackAliasKeys(
    SyncPlaybackEntry entry,
    _WorkAliasUnion union,
  ) {
    final workAliases = <String>{...entry.allWorkKeys};
    for (final k in entry.allWorkKeys) {
      workAliases.addAll(union.membersOf(k));
    }
    return <String>{
      entry.playbackKey,
      for (final wk in workAliases)
        CanonicalWorkIdentity.playbackKey(
          canonicalWorkKey: wk,
          seasonNumber: entry.seasonNumber,
          episodeNumber: entry.episodeNumber,
          isAudio: entry.isAudio,
          audioTrackHint: entry.isAudio ? entry.episodeTitle : null,
        ),
    };
  }

  static SyncPlaybackEntry _mergeSinglePlayback(
    SyncPlaybackEntry a,
    SyncPlaybackEntry b,
  ) {
    final bool bIsNewer;
    if (b.updatedAtMs != a.updatedAtMs) {
      bIsNewer = b.updatedAtMs > a.updatedAtMs;
    } else if (b.playedAtMs != a.playedAtMs) {
      bIsNewer = b.playedAtMs > a.playedAtMs;
    } else if (b.isCompleted != a.isCompleted) {
      bIsNewer = b.isCompleted;
    } else {
      bIsNewer = b.positionSeconds > a.positionSeconds;
    }

    final newer = bIsNewer ? b : a;
    final older = bIsNewer ? a : b;
    final mergedCompleted = newer.isCompleted || older.isCompleted;
    final mergedDuration = newer.durationSeconds > 0
        ? newer.durationSeconds
        : older.durationSeconds;
    final mergedPosition = (mergedCompleted && newer.positionSeconds <= 0)
        ? (mergedDuration > 0 ? mergedDuration : older.positionSeconds)
        : newer.positionSeconds;

    final allWorkKeys = <String>[
      newer.canonicalWorkKey,
      ...newer.secondaryWorkKeys,
      older.canonicalWorkKey,
      ...older.secondaryWorkKeys,
    ];
    final preferredPrimary = _pickPreferredWorkKey(allWorkKeys);
    final secondaryKeys = <String>[];
    for (final k in allWorkKeys) {
      if (k.isNotEmpty && k != preferredPrimary && !secondaryKeys.contains(k)) {
        secondaryKeys.add(k);
      }
    }

    return newer.copyWith(
      canonicalWorkKey: preferredPrimary,
      secondaryWorkKeys: secondaryKeys,
      positionSeconds: mergedPosition,
      durationSeconds: mergedDuration,
      isCompleted: mergedCompleted,
      playedAtMs: newer.playedAtMs >= older.playedAtMs
          ? newer.playedAtMs
          : older.playedAtMs,
      updatedAtMs: newer.updatedAtMs >= older.updatedAtMs
          ? newer.updatedAtMs
          : older.updatedAtMs,
      episodeTitle: newer.episodeTitle.isNotEmpty
          ? newer.episodeTitle
          : older.episodeTitle,
    );
  }

  static String _pickPreferredWorkKey(List<String> keys) {
    for (final k in keys) {
      if (k.startsWith('tmdb:')) return k;
    }
    for (final k in keys) {
      if (k.startsWith('bgm:')) return k;
    }
    return keys.isEmpty ? '' : keys.first;
  }

  static bool _isNewerOverride(
    SyncWorkOverrideEntry candidate,
    SyncWorkOverrideEntry existing,
  ) {
    if (candidate.updatedAtMs != existing.updatedAtMs) {
      return candidate.updatedAtMs > existing.updatedAtMs;
    }
    return candidate.sourceDeviceId.compareTo(existing.sourceDeviceId) > 0;
  }
}

/// 轻量跨源强身份键并查集（保证 TMDB 键优先作为聚类规范代表键）。
class _WorkAliasUnion {
  final Map<String, String> _parent = <String, String>{};

  String _find(String x) {
    final p = _parent[x];
    if (p == null || p == x) return x;
    final root = _find(p);
    _parent[x] = root;
    return root;
  }

  void union(String a, String b) {
    _parent.putIfAbsent(a, () => a);
    _parent.putIfAbsent(b, () => b);
    final ra = _find(a);
    final rb = _find(b);
    if (ra == rb) return;
    if (_rankKey(ra) <= _rankKey(rb)) {
      _parent[rb] = ra;
    } else {
      _parent[ra] = rb;
    }
  }

  String findPreferredRepresentative(String x) {
    if (!_parent.containsKey(x)) return x;
    return _find(x);
  }

  Set<String> membersOf(String x) {
    if (!_parent.containsKey(x)) return <String>{x};
    final root = _find(x);
    final out = <String>{x};
    for (final k in _parent.keys) {
      if (_find(k) == root) {
        out.add(k);
      }
    }
    return out;
  }

  int _rankKey(String key) {
    if (key.startsWith('tmdb:')) return 0;
    if (key.startsWith('bgm:')) return 1;
    return 2;
  }
}
