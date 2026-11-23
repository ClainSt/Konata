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
    for (final snap in remoteSnapshots) {
      for (final e in snap.playbackEntries) {
        registerWorkKeys(e.allWorkKeys);
      }
      for (final o in snap.workOverrides) {
        registerWorkKeys(o.allWorkKeys);
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

    return KonataSyncMergeResult(
      mergedPlaybacks: playbacks,
      mergedWorkOverrides: overrides,
      mergedTombstones: tombstones,
      mergedPreferences: winningPrefs,
      suppressedPlaybackKeys: suppressedPlaybackKeys,
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
