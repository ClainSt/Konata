import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';

/// 歌词用户覆盖切片的事务合并计划。
final class LyricOverrideMergePlan {
  /// 创建覆盖合并计划。
  const LyricOverrideMergePlan({required this.upserts});

  /// 冲突裁决后需要覆盖落盘的记录集合。
  final List<LyricUserOverrideRecord> upserts;
}

/// 歌词手选正文与单曲/专辑偏移同步切片贡献者（覆盖软删除墓碑与确定性最后写入胜出合并）。
final class LyricOverridesSyncSlice
    implements SyncSliceContributor<LyricOverrideMergePlan> {
  /// 使用用户态数据库构造歌词用户覆盖同步切片。
  LyricOverridesSyncSlice({
    required this._userStateDb,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// 切片全局唯一稳定标识。
  static const String stableSliceId = 'lyric_overrides_slice';

  final UserStateDatabase _userStateDb;
  final DateTime Function() _now;

  @override
  String get sliceId => stableSliceId;

  @override
  String get displayName => '歌词覆盖与时间轴偏移';

  @override
  int get schemaVersion => 1;

  @override
  Future<SyncSlicePayload> exportSlice({required String localDeviceId}) async {
    final rows = _userStateDb.lyricUserOverrides.listAll(includeDeleted: true)
      ..sort((a, b) => a.overrideKey.compareTo(b.overrideKey));
    return SyncSlicePayload(
      sliceId: sliceId,
      schemaVersion: schemaVersion,
      exportedAtMs: _now().toUtc().millisecondsSinceEpoch,
      sourceDeviceId: localDeviceId,
      data: <String, Object?>{
        'overrides': <Map<String, Object?>>[
          for (final row in rows) encodeRecord(row),
        ],
      },
    );
  }

  @override
  SyncMergePlan<LyricOverrideMergePlan> planMerge({
    required SyncSlicePayload local,
    required SyncSlicePayload remote,
  }) {
    final localMap = decodeSliceMap(local);
    final remoteMap = decodeSliceMap(remote);
    final sortedKeys = remoteMap.keys.toList()..sort();

    final upserts = <LyricUserOverrideRecord>[];
    var insertCount = 0;
    var updateCount = 0;
    var deleteCount = 0;
    var skippedCount = 0;

    for (final key in sortedKeys) {
      final remoteRec = remoteMap[key]!;
      final localRec = localMap[key];
      if (localRec == null) {
        upserts.add(remoteRec);
        if (remoteRec.isDeleted) {
          deleteCount++;
        } else {
          insertCount++;
        }
        continue;
      }
      if (_recordsEqual(localRec, remoteRec)) {
        skippedCount++;
        continue;
      }
      if (_shouldRemoteWin(local: localRec, remote: remoteRec)) {
        upserts.add(remoteRec);
        if (remoteRec.isDeleted && !localRec.isDeleted) {
          deleteCount++;
        } else {
          updateCount++;
        }
      } else {
        skippedCount++;
      }
    }

    final summary = <String>[
      if (insertCount > 0) '新增 $insertCount 条歌词覆盖',
      if (updateCount > 0) '更新 $updateCount 条歌词覆盖',
      if (deleteCount > 0) '同步删除 $deleteCount 条歌词覆盖',
      if (skippedCount > 0) '保留本地或忽略重复 $skippedCount 条',
    ];

    return SyncMergePlan<LyricOverrideMergePlan>(
      sliceId: sliceId,
      insertCount: insertCount,
      updateCount: updateCount,
      deleteCount: deleteCount,
      skippedCount: skippedCount,
      planData: LyricOverrideMergePlan(
        upserts: List<LyricUserOverrideRecord>.unmodifiable(upserts),
      ),
      summaryLines: List<String>.unmodifiable(summary),
    );
  }

  @override
  Future<void> applyMergePlan(
    SyncTransactionContext tx,
    SyncMergePlan<LyricOverrideMergePlan> plan,
  ) async {
    final upserts = plan.planData.upserts;
    if (upserts.isEmpty) return;

    final dao = _userStateDb.lyricUserOverrides;
    final raw = tx.rawHandleFor('user_state');
    if (raw is SqliteTransaction) {
      for (final record in upserts) {
        dao.upsertInTx(raw, record);
      }
      return;
    }
    if (raw is UserStateDatabase) {
      raw.engine.runTransaction((dbTx) {
        for (final record in upserts) {
          raw.lyricUserOverrides.upsertInTx(dbTx, record);
        }
      });
      return;
    }
    if (raw is KonataSqliteEngine) {
      raw.runTransaction((dbTx) {
        for (final record in upserts) {
          dao.upsertInTx(dbTx, record);
        }
      });
      return;
    }

    _userStateDb.engine.runTransaction((dbTx) {
      for (final record in upserts) {
        dao.upsertInTx(dbTx, record);
      }
    });
  }

  /// 将单条覆盖记录序列化为可移植字典。
  static Map<String, Object?> encodeRecord(LyricUserOverrideRecord rec) {
    return <String, Object?>{
      'overrideKey': rec.overrideKey,
      'scope': rec.scope.name,
      'trackKey': rec.trackKey,
      'albumKey': rec.albumKey,
      'lrcContent': rec.lrcContent,
      'offsetMillis': rec.offsetMillis,
      'userOffsetLocked': rec.userOffsetLocked,
      'userEdited': rec.userEdited,
      'updatedAtMs': rec.updatedAtMs,
      'sourceDeviceId': rec.sourceDeviceId,
      'deletedAtMs': rec.deletedAtMs,
    };
  }

  /// 将字典反序列化为强类型覆盖记录（字段缺失或非法时返回 `null`）。
  static LyricUserOverrideRecord? decodeRecord(Map<String, Object?> json) {
    final key = (json['overrideKey'] as String? ?? '').trim();
    if (key.isEmpty) return null;
    final scopeName = (json['scope'] as String? ?? '').trim();
    final scope = LyricOverrideScope.values.firstWhere(
      (s) => s.name == scopeName,
      orElse: () => LyricOverrideScope.track,
    );
    return LyricUserOverrideRecord(
      overrideKey: key,
      scope: scope,
      trackKey: json['trackKey'] as String?,
      albumKey: json['albumKey'] as String?,
      lrcContent: json['lrcContent'] as String?,
      offsetMillis: (json['offsetMillis'] as num?)?.toInt() ?? 0,
      userOffsetLocked: json['userOffsetLocked'] as bool? ?? false,
      userEdited: json['userEdited'] as bool? ?? false,
      updatedAtMs: (json['updatedAtMs'] as num?)?.toInt() ?? 0,
      sourceDeviceId: json['sourceDeviceId'] as String? ?? '',
      deletedAtMs: (json['deletedAtMs'] as num?)?.toInt(),
    );
  }

  /// 从切片载荷中解析并按确定性最后写入胜出规则去重构建主键映射。
  static Map<String, LyricUserOverrideRecord> decodeSliceMap(
    SyncSlicePayload payload,
  ) {
    final rawList = payload.data['overrides'];
    if (rawList is! List) return const <String, LyricUserOverrideRecord>{};
    final out = <String, LyricUserOverrideRecord>{};
    for (final item in rawList) {
      if (item is! Map) continue;
      final normalized = <String, Object?>{
        for (final entry in item.entries) entry.key.toString(): entry.value,
      };
      final record = decodeRecord(normalized);
      if (record == null) continue;
      final prev = out[record.overrideKey];
      if (prev == null || _shouldRemoteWin(local: prev, remote: record)) {
        out[record.overrideKey] = record;
      }
    }
    return out;
  }

  static bool _shouldRemoteWin({
    required LyricUserOverrideRecord local,
    required LyricUserOverrideRecord remote,
  }) {
    if (remote.updatedAtMs != local.updatedAtMs) {
      return remote.updatedAtMs > local.updatedAtMs;
    }
    if (remote.isDeleted != local.isDeleted) {
      return remote.isDeleted;
    }
    final devCmp = remote.sourceDeviceId.compareTo(local.sourceDeviceId);
    if (devCmp != 0) return devCmp > 0;
    final localLrc = local.lrcContent ?? '';
    final remoteLrc = remote.lrcContent ?? '';
    final lrcCmp = remoteLrc.compareTo(localLrc);
    if (lrcCmp != 0) return lrcCmp > 0;
    if (remote.offsetMillis != local.offsetMillis) {
      return remote.offsetMillis > local.offsetMillis;
    }
    if (remote.userEdited != local.userEdited) {
      return remote.userEdited;
    }
    if (remote.userOffsetLocked != local.userOffsetLocked) {
      return remote.userOffsetLocked;
    }
    return false;
  }

  static bool _recordsEqual(
    LyricUserOverrideRecord a,
    LyricUserOverrideRecord b,
  ) {
    return a.overrideKey == b.overrideKey &&
        a.scope == b.scope &&
        a.trackKey == b.trackKey &&
        a.albumKey == b.albumKey &&
        a.lrcContent == b.lrcContent &&
        a.offsetMillis == b.offsetMillis &&
        a.userOffsetLocked == b.userOffsetLocked &&
        a.userEdited == b.userEdited &&
        a.updatedAtMs == b.updatedAtMs &&
        a.sourceDeviceId == b.sourceDeviceId &&
        a.deletedAtMs == b.deletedAtMs;
  }
}
