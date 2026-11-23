import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/logging/diagnostic_event.dart';
import '../../domain/models/episode.dart';
import '../../domain/models/media_source.dart';
import '../../domain/models/playback_record.dart';
import '../../domain/models/work.dart';
import '../../domain/repositories/library_repository.dart';
import '../../domain/sync/konata_sync_merge_engine.dart';
import '../../domain/sync/konata_sync_models.dart';
import '../../infrastructure/logging/diagnostics_log_store.dart';
import '../../infrastructure/sync/konata_sync_store.dart';

/// 本地 `.konata` 备份恢复服务与跨设备同步快照编解码核心。
///
/// 统一承接本地数据库状态到跨端标准快照 [KonataSyncSnapshotEnvelope] 的导出、
/// gzip `.konata` 完整性校验、以及合并态回写到本地 SQLite 与便携偏好的事务落库。
class KonataBackupService {
  /// 创建备份与快照服务。
  KonataBackupService({
    required LibraryRepository repository,
    required this._syncStore,
    this._logStore,
    Future<SharedPreferences> Function()? prefsLoader,
    DateTime Function()? clock,
    this.appVersion = '1.0.0+2006',
  }) : _repo = repository,
       _prefsLoader = prefsLoader ?? SharedPreferences.getInstance,
       _clock = clock ?? DateTime.now;

  final LibraryRepository _repo;
  final KonataSyncStore _syncStore;
  final DiagnosticsLogStore? _logStore;
  final Future<SharedPreferences> Function() _prefsLoader;
  final DateTime Function() _clock;

  /// 当前应用版本标识。
  final String appVersion;

  /// 将当前设备上的观看进度、作品整理锁、墓碑与便携非敏感偏好构建为带 SHA-256 校验的标准快照。
  Future<KonataSyncSnapshotEnvelope> buildLocalSnapshotEnvelope() async {
    final nowMs = _clock().millisecondsSinceEpoch;
    final deviceId = await _syncStore.getOrCreateDeviceId();
    final deviceName = _syncStore.resolveLocalDeviceName();

    final works = await _repo.getAllWorks();
    final workById = <String, Work>{for (final w in works) w.id: w};
    final playbacks = await _repo.getPlaybackHistory(limit: 10000);
    final seriesGroups = await _repo.getAllSeriesGroups();
    final seriesTitleById = <String, String>{
      for (final s in seriesGroups) s.id: s.title,
    };
    final workUpdatedMap = await _syncStore.readWorkUpdatedAtMsMap();
    final playbackUpdatedMap = await _syncStore.readPlaybackUpdatedAtMsMap();
    final tombstones = await _syncStore.getAllTombstones();

    final syncPlaybacks = <SyncPlaybackEntry>[];
    for (final rec in playbacks) {
      final work = workById[rec.workId];
      if (work == null) continue;
      final primaryKey = CanonicalWorkIdentity.primaryKeyFor(work);
      final secondaryKeys = CanonicalWorkIdentity.allKeysFor(work)
          .where((k) => k != primaryKey)
          .toList(growable: false);
      final pbKey = CanonicalWorkIdentity.playbackKey(
        canonicalWorkKey: primaryKey,
        seasonNumber: rec.seasonNumber,
        episodeNumber: rec.episodeNumber,
        isAudio: rec.isAudioRecord,
        audioTrackHint: rec.isAudioRecord ? rec.episodeTitle : null,
      );
      final playedAtMs = rec.playedAt.millisecondsSinceEpoch;
      final storedUpdated = playbackUpdatedMap[rec.id] ?? 0;
      final updatedAtMs = storedUpdated > 0 ? storedUpdated : playedAtMs;
      syncPlaybacks.add(
        SyncPlaybackEntry(
          playbackKey: pbKey,
          canonicalWorkKey: primaryKey,
          secondaryWorkKeys: secondaryKeys,
          seasonNumber: rec.seasonNumber,
          episodeNumber: rec.episodeNumber,
          isAudio: rec.isAudioRecord,
          episodeTitle: rec.episodeTitle,
          positionSeconds: rec.positionSeconds,
          durationSeconds: rec.durationSeconds,
          isCompleted: rec.isCompleted,
          playedAtMs: playedAtMs,
          updatedAtMs: updatedAtMs,
          sourceDeviceId: deviceId,
        ),
      );
    }

    final syncOverrides = <SyncWorkOverrideEntry>[];
    for (final work in works) {
      final hasUserCuration =
          work.isManualLocked ||
          work.metadataLocked ||
          work.isHidden ||
          work.keepHidden ||
          work.seriesLocked ||
          work.tmdbId != null ||
          work.bangumiId != null;
      if (!hasUserCuration) continue;
      final primaryKey = CanonicalWorkIdentity.primaryKeyFor(work);
      final secondaryKeys = CanonicalWorkIdentity.allKeysFor(work)
          .where((k) => k != primaryKey)
          .toList(growable: false);
      final storedUpdated = workUpdatedMap[work.id] ?? 0;
      syncOverrides.add(
        SyncWorkOverrideEntry(
          canonicalWorkKey: primaryKey,
          secondaryWorkKeys: secondaryKeys,
          title: work.title,
          tmdbId: work.tmdbId,
          tmdbMediaType: work.tmdbMediaType,
          bangumiId: work.bangumiId,
          matchedSeason: work.matchedSeason,
          isManualLocked: work.isManualLocked,
          metadataLocked: work.metadataLocked,
          isHidden: work.isHidden,
          keepHidden: work.keepHidden,
          seriesTitle: work.seriesId == null
              ? null
              : seriesTitleById[work.seriesId!],
          seriesOrder: work.seriesOrder,
          seriesLabel: work.seriesLabel,
          seriesLocked: work.seriesLocked,
          updatedAtMs: storedUpdated > 0 ? storedUpdated : nowMs,
          sourceDeviceId: deviceId,
        ),
      );
    }

    final rawPrefs = await readPortablePreferences();
    final preferences = rawPrefs.values.isNotEmpty && rawPrefs.updatedAtMs == 0
        ? SyncPreferencesBundle(
            values: rawPrefs.values,
            updatedAtMs: nowMs,
          )
        : rawPrefs;

    return KonataSyncSnapshotEnvelope.create(
      exportedAtMs: nowMs,
      deviceId: deviceId,
      deviceName: deviceName,
      platform: Platform.operatingSystem,
      appVersion: appVersion,
      playbackEntries: syncPlaybacks,
      workOverrides: syncOverrides,
      tombstones: tombstones,
      preferences: preferences,
    );
  }

  /// 读取允许备份与跨设备同步的便携非敏感偏好集合（绝不读取任何密码、PAT 或 API 密钥）。
  Future<SyncPreferencesBundle> readPortablePreferences() async {
    final prefs = await _prefsLoader();
    final raw = <String, Object?>{};
    for (final key in SyncPreferencesBundle.portableKeysAllowlist) {
      if (prefs.containsKey(key)) {
        raw[key] = prefs.get(key);
      }
    }
    final storedTs = int.tryParse(
      (await _syncStore.readMeta(KonataSyncStore.metaKeyPrefsUpdatedAtMs)) ??
          '',
    );
    return SyncPreferencesBundle.sanitized(
      raw,
      // 未记录明确修改时间时保持为 0，确保导入备份或远端已同步设备的新配置不会被本机默认空时间戳误覆盖。
      updatedAtMs: storedTs ?? 0,
    );
  }

  /// 导出 gzip 压缩的本地 `.konata` 备份文件字节流。
  Future<Uint8List> exportKonataArchiveBytes() async {
    final envelope = await buildLocalSnapshotEnvelope();
    final jsonBytes = utf8.encode(jsonEncode(envelope.toJson()));
    final compressed = Uint8List.fromList(gzip.encode(jsonBytes));
    _logStore?.logEvent(
      subsystem: DiagnosticSubsystem.sync,
      code: 'BACKUP_EXPORTED',
      message:
          '已导出 .konata 备份：${envelope.playbackEntries.length} 条进度、${envelope.workOverrides.length} 项作品整理',
      source:
          'lib/application/sync/konata_backup_service.dart:exportKonataArchiveBytes',
      context: <String, Object?>{
        'playbacks': envelope.playbackEntries.length,
        'overrides': envelope.workOverrides.length,
        'preferences': envelope.preferences.values.length,
        'bytes': compressed.length,
      },
    );
    return compressed;
  }

  /// 解码并校验 `.konata` 备份字节（兼容 gzip 压缩与明文 JSON），损坏或篡改立即抛 [FormatException]。
  KonataSyncSnapshotEnvelope decodeAndVerifyArchiveBytes(Uint8List bytes) {
    if (bytes.isEmpty) {
      throw const FormatException('备份文件为空');
    }
    final List<int> plainBytes;
    if (bytes.length >= 2 && bytes[0] == 0x1f && bytes[1] == 0x8b) {
      try {
        plainBytes = gzip.decode(bytes);
      } catch (_) {
        throw const FormatException('备份文件 gzip 解压失败，文件可能已损坏');
      }
    } else {
      plainBytes = bytes;
    }
    return KonataSyncSnapshotEnvelope.parseAndVerify(utf8.decode(plainBytes));
  }

  /// 干跑预检 `.konata` 备份文件，返回待恢复数据摘要供弹窗确认。
  KonataBackupPreview inspectKonataArchiveBytes(Uint8List bytes) {
    final envelope = decodeAndVerifyArchiveBytes(bytes);
    return KonataBackupPreview(
      exportedAt: DateTime.fromMillisecondsSinceEpoch(envelope.exportedAtMs),
      deviceName: envelope.deviceName.isEmpty ? '未知设备' : envelope.deviceName,
      platform: envelope.platform.isEmpty ? 'unknown' : envelope.platform,
      appVersion: envelope.appVersion,
      playbackCount: envelope.playbackEntries.length,
      workOverrideCount: envelope.workOverrides.length,
      tombstoneCount: envelope.tombstones.length,
      preferenceCount: envelope.preferences.values.length,
    );
  }

  /// 从 `.konata` 备份字节恢复数据（支持智能合并或覆盖还原，原子事务落库）。
  Future<KonataSyncOutcome> restoreFromKonataArchiveBytes(
    Uint8List bytes, {
    required KonataBackupRestoreMode mode,
  }) async {
    final incoming = decodeAndVerifyArchiveBytes(bytes);
    final nowMs = _clock().millisecondsSinceEpoch;

    final KonataSyncMergeResult merged;
    if (mode == KonataBackupRestoreMode.overwrite) {
      merged = KonataSyncMergeResult(
        mergedPlaybacks: <String, SyncPlaybackEntry>{
          for (final e in incoming.playbackEntries) e.playbackKey: e,
        },
        mergedWorkOverrides: <String, SyncWorkOverrideEntry>{
          for (final o in incoming.workOverrides) o.canonicalWorkKey: o,
        },
        mergedTombstones: <String, SyncTombstoneEntry>{
          for (final t in incoming.tombstones) t.entityKey: t,
        },
        mergedPreferences: incoming.preferences,
        suppressedPlaybackKeys: const <String>{},
      );
    } else {
      final local = await buildLocalSnapshotEnvelope();
      final localPrefs = await readPortablePreferences();
      merged = KonataSyncMergeEngine.merge(
        localPlaybacks: local.playbackEntries,
        localOverrides: local.workOverrides,
        localTombstones: local.tombstones,
        localPreferences: localPrefs,
        remoteSnapshots: <KonataSyncSnapshotEnvelope>[incoming],
        nowMs: nowMs,
      );
    }

    final outcome = await applyMergedState(
      merged,
      clearExistingPlaybacksBeforeApply:
          mode == KonataBackupRestoreMode.overwrite,
      applyPreferences: incoming.preferences.values.isNotEmpty,
    );

    _logStore?.logEvent(
      subsystem: DiagnosticSubsystem.sync,
      code: 'BACKUP_RESTORED',
      message: '已恢复 .konata 备份（模式=${mode.name}）：${outcome.toSummaryMessage()}',
      source:
          'lib/application/sync/konata_backup_service.dart:restoreFromKonataArchiveBytes',
      context: <String, Object?>{
        'mode': mode.name,
        'playbacksUpdated': outcome.playbacksUpdated,
        'workOverridesApplied': outcome.workOverridesApplied,
        'preferencesRestored': outcome.preferencesRestored,
      },
    );
    return outcome;
  }

  /// 将合并后的同步状态原子写入本地数据库与便携偏好设置（仅匹配本机已入库作品，不伪造悬空物理文件）。
  Future<KonataSyncOutcome> applyMergedState(
    KonataSyncMergeResult merged, {
    bool clearExistingPlaybacksBeforeApply = false,
    bool applyPreferences = true,
    int remoteDevicesMerged = 0,
    bool uploadedShard = false,
  }) async {
    var playbacksUpdated = 0;
    var playbacksSkippedUnmatched = 0;
    var workOverridesApplied = 0;
    var tombstonesApplied = 0;

    await _repo.runInTransaction(() async {
      if (clearExistingPlaybacksBeforeApply) {
        await _repo.clearPlaybackHistory();
      }

      final works = await _repo.getAllWorks();
      final allEpisodes = await _repo.getAllEpisodes();
      final allVariants = await _repo.getAllVariants();
      final existingPlaybacks = await _repo.getPlaybackHistory(limit: 10000);

      // 建立 跨端身份键 -> 本地 Work 列表 索引（支持多源同名作品同时受益）
      final worksByCanonicalKey = <String, List<Work>>{};
      for (final work in works) {
        for (final key in CanonicalWorkIdentity.allKeysFor(work)) {
          worksByCanonicalKey.putIfAbsent(key, () => <Work>[]).add(work);
        }
      }

      // 1. 应用作品人工整理与隐藏状态覆盖
      for (final ov in merged.mergedWorkOverrides.values) {
        final matchedWorks = _resolveMatchingWorks(
          ov.allWorkKeys,
          worksByCanonicalKey,
        );
        for (final work in matchedWorks) {
          final next = work.copyWith(
            isHidden: ov.isHidden,
            keepHidden: ov.keepHidden,
            isManualLocked: work.isManualLocked || ov.isManualLocked,
            metadataLocked: work.metadataLocked || ov.metadataLocked,
            seriesOrder: ov.seriesLocked ? ov.seriesOrder : work.seriesOrder,
            seriesLabel: ov.seriesLocked ? ov.seriesLabel : work.seriesLabel,
            seriesLocked: work.seriesLocked || ov.seriesLocked,
            bangumiId: work.bangumiId ?? ov.bangumiId,
            tmdbId: work.tmdbId ?? ov.tmdbId,
            tmdbMediaType: work.tmdbMediaType ?? ov.tmdbMediaType,
            matchedSeason: work.matchedSeason ?? ov.matchedSeason,
          );
          if (_workSyncFieldsChanged(work, next)) {
            await _repo.upsertWork(next);
            workOverridesApplied++;
          }
        }
      }

      final episodesByWorkId = <String, List<Episode>>{};
      for (final ep in allEpisodes) {
        episodesByWorkId.putIfAbsent(ep.workId, () => <Episode>[]).add(ep);
      }
      final variantByEpisodeId = <String, String>{};
      for (final v in allVariants) {
        final epId = v.episodeId;
        if (epId != null && epId.isNotEmpty) {
          variantByEpisodeId.putIfAbsent(epId, () => v.id);
        }
      }

      final existingByWorkEp = <String, PlaybackRecord>{
        for (final rec in existingPlaybacks) '${rec.workId}::${rec.episodeId}': rec,
      };
      final workById = <String, Work>{for (final w in works) w.id: w};

      // 2. 应用远端删除墓碑，移除已被更新墓碑覆盖的本地播放记录（匹配主/辅全部身份别名键）
      if (merged.suppressedPlaybackKeys.isNotEmpty) {
        for (final rec in existingPlaybacks) {
          final work = workById[rec.workId];
          if (work == null) continue;
          final hitTombstone = CanonicalWorkIdentity.allKeysFor(work).any((wk) {
            final key = CanonicalWorkIdentity.playbackKey(
              canonicalWorkKey: wk,
              seasonNumber: rec.seasonNumber,
              episodeNumber: rec.episodeNumber,
              isAudio: rec.isAudioRecord,
              audioTrackHint: rec.isAudioRecord ? rec.episodeTitle : null,
            );
            return merged.suppressedPlaybackKeys.contains(key);
          });
          if (hitTombstone) {
            await _repo.deletePlaybackRecord(rec.id);
            existingByWorkEp.remove('${rec.workId}::${rec.episodeId}');
            tombstonesApplied++;
          }
        }
      }

      // 3. 应用冲突消解后的观看进度到本地匹配的剧集
      for (final entry in merged.mergedPlaybacks.values) {
        if (entry.isAudio) continue;
        final matchedWorks = _resolveMatchingWorks(
          entry.allWorkKeys,
          worksByCanonicalKey,
        );
        if (matchedWorks.isEmpty) {
          playbacksSkippedUnmatched++;
          continue;
        }
        for (final work in matchedWorks) {
          final workEps = episodesByWorkId[work.id] ?? const <Episode>[];
          final targetEp = _matchLocalEpisode(workEps, entry);
          if (targetEp == null) {
            playbacksSkippedUnmatched++;
            continue;
          }
          final mapKey = '${work.id}::${targetEp.id}';
          final existing = existingByWorkEp[mapKey];
          final needsWrite =
              existing == null ||
              existing.isCompleted != entry.isCompleted ||
              existing.positionSeconds != entry.positionSeconds ||
              existing.durationSeconds != entry.durationSeconds ||
              existing.playedAt.millisecondsSinceEpoch != entry.playedAtMs;
          if (!needsWrite) continue;

          final variantId =
              existing?.variantId ?? variantByEpisodeId[targetEp.id] ?? '';
          final nextRec = PlaybackRecord(
            id: existing?.id ?? '${work.id}::${targetEp.id}',
            workId: work.id,
            episodeId: targetEp.id,
            variantId: variantId,
            seasonNumber: targetEp.seasonNumber,
            episodeNumber: targetEp.episodeNumber,
            episodeTitle: entry.episodeTitle.isNotEmpty
                ? entry.episodeTitle
                : (targetEp.title ?? work.title),
            sourceType: existing?.sourceType ?? MediaSourceKind.local,
            playedAt: DateTime.fromMillisecondsSinceEpoch(
              entry.playedAtMs > 0
                  ? entry.playedAtMs
                  : _clock().millisecondsSinceEpoch,
            ),
            positionSeconds: entry.positionSeconds,
            durationSeconds: entry.durationSeconds,
            isCompleted: entry.isCompleted,
          );
          await _repo.recordPlayback(nextRec);
          existingByWorkEp[mapKey] = nextRec;
          playbacksUpdated++;
        }
      }

      // 4. 持久化合并后的墓碑并清理过期项
      if (merged.mergedTombstones.isNotEmpty) {
        await _syncStore.upsertTombstonesBatch(
          merged.mergedTombstones.values.toList(growable: false),
        );
      }
      final cutoffMs =
          _clock().millisecondsSinceEpoch -
          const Duration(
            days: KonataSyncMergeEngine.tombstoneRetentionDays,
          ).inMilliseconds;
      await _syncStore.pruneTombstonesBefore(cutoffMs);
    });

    var preferencesRestored = 0;
    if (applyPreferences && merged.mergedPreferences.values.isNotEmpty) {
      preferencesRestored = await _writePortablePreferences(
        merged.mergedPreferences,
      );
    }

    return KonataSyncOutcome(
      playbacksUpdated: playbacksUpdated,
      playbacksSkippedUnmatched: playbacksSkippedUnmatched,
      workOverridesApplied: workOverridesApplied,
      tombstonesApplied: tombstonesApplied,
      preferencesRestored: preferencesRestored,
      remoteDevicesMerged: remoteDevicesMerged,
      uploadedShard: uploadedShard,
    );
  }

  /// 当用户主动删除某条播放记录时写入同步删除墓碑，防止多设备同步后旧记录复活。
  Future<void> recordPlaybackDeletionTombstone({
    required Work work,
    required PlaybackRecord record,
  }) async {
    final deviceId = await _syncStore.getOrCreateDeviceId();
    final key = CanonicalWorkIdentity.playbackKey(
      canonicalWorkKey: CanonicalWorkIdentity.primaryKeyFor(work),
      seasonNumber: record.seasonNumber,
      episodeNumber: record.episodeNumber,
      isAudio: record.isAudioRecord,
      audioTrackHint: record.isAudioRecord ? record.episodeTitle : null,
    );
    await _syncStore.upsertTombstone(
      SyncTombstoneEntry(
        entityKey: key,
        entityType: 'playback',
        deletedAtMs: _clock().millisecondsSinceEpoch,
        deviceId: deviceId,
      ),
    );
  }

  List<Work> _resolveMatchingWorks(
    Iterable<String> candidateKeys,
    Map<String, List<Work>> index,
  ) {
    final seenIds = <String>{};
    final out = <Work>[];
    for (final key in candidateKeys) {
      final hits = index[key];
      if (hits == null) continue;
      for (final w in hits) {
        if (seenIds.add(w.id)) {
          out.add(w);
        }
      }
    }
    return out;
  }

  Episode? _matchLocalEpisode(List<Episode> episodes, SyncPlaybackEntry entry) {
    if (episodes.isEmpty) return null;
    for (final ep in episodes) {
      if (ep.seasonNumber == entry.seasonNumber &&
          ep.episodeNumber == entry.episodeNumber) {
        return ep;
      }
    }
    // 兼容跨端季号差异（如一端 matchedSeason=2 写 s2、另一端按单季番写 s1）但同属正片同集号
    if (entry.episodeNumber != null) {
      for (final ep in episodes) {
        if (ep.category == EpisodeCategory.main &&
            ep.episodeNumber == entry.episodeNumber) {
          return ep;
        }
      }
    } else {
      // 独立剧场版/单部作品（episodeNumber == null）匹配唯一正片项
      final mainEps = episodes
          .where((e) => e.category == EpisodeCategory.main)
          .toList(growable: false);
      if (mainEps.length == 1) {
        return mainEps.first;
      }
    }
    return null;
  }

  bool _workSyncFieldsChanged(Work a, Work b) {
    return a.isHidden != b.isHidden ||
        a.keepHidden != b.keepHidden ||
        a.isManualLocked != b.isManualLocked ||
        a.metadataLocked != b.metadataLocked ||
        a.seriesOrder != b.seriesOrder ||
        a.seriesLabel != b.seriesLabel ||
        a.seriesLocked != b.seriesLocked ||
        a.bangumiId != b.bangumiId ||
        a.tmdbId != b.tmdbId ||
        a.tmdbMediaType != b.tmdbMediaType ||
        a.matchedSeason != b.matchedSeason;
  }

  Future<int> _writePortablePreferences(SyncPreferencesBundle bundle) async {
    final prefs = await _prefsLoader();
    var count = 0;
    for (final entry in bundle.values.entries) {
      if (!SyncPreferencesBundle.isPortableKey(entry.key)) continue;
      final value = entry.value;
      final existing = prefs.get(entry.key);
      if (existing == value) continue;
      if (value is bool) {
        await prefs.setBool(entry.key, value);
        count++;
      } else if (value is int) {
        await prefs.setInt(entry.key, value);
        count++;
      } else if (value is double) {
        await prefs.setDouble(entry.key, value);
        count++;
      } else if (value is String) {
        await prefs.setString(entry.key, value);
        count++;
      }
    }
    if (bundle.updatedAtMs > 0) {
      await _syncStore.writeMeta(
        KonataSyncStore.metaKeyPrefsUpdatedAtMs,
        bundle.updatedAtMs.toString(),
      );
    }
    return count;
  }
}
