import 'dart:io';
import 'dart:math';

import 'package:drift/drift.dart';

import '../../domain/sync/konata_sync_models.dart';
import '../database/konata_database.dart';

/// Bangumi 离线重试队列条目只读模型。
class BangumiSyncQueueItem {
  /// 创建队列项。
  const BangumiSyncQueueItem({
    required this.queueKey,
    required this.subjectId,
    required this.seasonNumber,
    this.episodeNumber,
    required this.targetStatus,
    required this.enqueuedAtMs,
    required this.retryCount,
    this.lastError,
    required this.nextRetryAtMs,
  });

  final String queueKey;
  final int subjectId;
  final int seasonNumber;
  final int? episodeNumber;
  final int targetStatus;
  final int enqueuedAtMs;
  final int retryCount;
  final String? lastError;
  final int nextRetryAtMs;
}

/// 基于 Drift v15 的同步元数据、删除墓碑与 Bangumi 离线队列仓储。
class KonataSyncStore {
  /// 创建同步仓储实例。
  KonataSyncStore(this._db, {this._random});

  /// 元信息键：当前设备稳定唯一标识。
  static const String metaKeyDeviceId = 'device_id';

  /// 元信息键：WebDAV 最近同步时间（UTC 毫秒）。
  static const String metaKeyWebDavLastSyncMs = 'webdav_last_sync_ms';

  /// 元信息键：WebDAV 最近同步中文摘要。
  static const String metaKeyWebDavLastSummary = 'webdav_last_summary';

  /// 元信息键：便携偏好最近一次变更时间（UTC 毫秒）。
  static const String metaKeyPrefsUpdatedAtMs = 'prefs_updated_at_ms';

  /// 元信息键：本地备份最近一次恢复时间（UTC 毫秒）。
  static const String metaKeyLocalBackupLastAtMs = 'local_backup_last_at_ms';

  /// 元信息键：本地备份最近一次恢复中文摘要。
  static const String metaKeyLocalBackupLastSummary =
      'local_backup_last_summary';

  /// 元信息键：Bangumi 最近同步时间（UTC 毫秒）。
  static const String metaKeyBangumiLastSyncMs = 'bangumi_last_sync_ms';

  /// 元信息键：Bangumi 最近同步中文摘要。
  static const String metaKeyBangumiLastSummary = 'bangumi_last_summary';

  /// 元信息键：已校验的 Bangumi 用户信息 JSON（非敏感公开字段）。
  static const String metaKeyBangumiProfileJson = 'bangumi_profile_json';

  final KonataDatabase _db;
  final Random? _random;

  /// 获取或首次生成持久化设备唯一 ID（跨重启稳定不变）。
  Future<String> getOrCreateDeviceId() async {
    final existing = await readMeta(metaKeyDeviceId);
    if (existing != null && existing.trim().isNotEmpty) {
      return existing.trim();
    }
    final rng = _random ?? Random.secure();
    final bytes = List<int>.generate(12, (_) => rng.nextInt(256));
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    final prefix = Platform.operatingSystem.toLowerCase();
    final deviceId = '${prefix}_$hex';
    await writeMeta(metaKeyDeviceId, deviceId);
    return deviceId;
  }

  /// 生成用于远端清单展示的可读设备名称。
  String resolveLocalDeviceName() {
    try {
      final host = Platform.localHostname.trim();
      if (host.isNotEmpty) {
        return '$host (${Platform.operatingSystem})';
      }
    } catch (_) {
      return 'Konata (${Platform.operatingSystem})';
    }
    return 'Konata (${Platform.operatingSystem})';
  }

  /// 读取单条同步元信息。
  Future<String?> readMeta(String key) async {
    final query = _db.select(_db.syncKvMeta)..where((t) => t.key.equals(key));
    final row = await query.getSingleOrNull();
    return row?.value;
  }

  /// 写入或更新单条同步元信息。
  Future<void> writeMeta(String key, String value, {int? updatedAtMs}) async {
    final nowMs = updatedAtMs ?? DateTime.now().millisecondsSinceEpoch;
    await _db
        .into(_db.syncKvMeta)
        .insertOnConflictUpdate(
          SyncKvMetaCompanion(
            key: Value(key),
            value: Value(value),
            updatedAtMs: Value(nowMs),
          ),
        );
  }

  /// 删除单条同步元信息。
  Future<void> deleteMeta(String key) async {
    await (_db.delete(_db.syncKvMeta)..where((t) => t.key.equals(key))).go();
  }

  /// 读取全部同步删除墓碑。
  Future<List<SyncTombstoneEntry>> getAllTombstones() async {
    final rows = await _db.select(_db.syncTombstones).get();
    return [
      for (final row in rows)
        SyncTombstoneEntry(
          entityKey: row.entityKey,
          entityType: row.entityType,
          deletedAtMs: row.deletedAtMs,
          deviceId: row.deviceId,
        ),
    ];
  }

  /// 写入或刷新单条同步删除墓碑（仅当新时间戳更大时覆盖）。
  Future<void> upsertTombstone(SyncTombstoneEntry entry) async {
    await upsertTombstonesBatch(<SyncTombstoneEntry>[entry]);
  }

  /// 批量写入同步删除墓碑。
  Future<void> upsertTombstonesBatch(List<SyncTombstoneEntry> entries) async {
    if (entries.isEmpty) return;
    await _db.batch((batch) {
      batch.insertAllOnConflictUpdate(
        _db.syncTombstones,
        [
          for (final item in entries)
            SyncTombstonesCompanion(
              entityKey: Value(item.entityKey),
              entityType: Value(item.entityType),
              deletedAtMs: Value(item.deletedAtMs),
              deviceId: Value(item.deviceId),
            ),
        ],
      );
    });
  }

  /// 清理过陈旧的墓碑记录。
  Future<void> pruneTombstonesBefore(int cutoffMs) async {
    await (_db.delete(
      _db.syncTombstones,
    )..where((t) => t.deletedAtMs.isSmallerThanValue(cutoffMs))).go();
  }

  /// 批量读取作品表中记录的 `updatedAtMs` 时间戳字典（`workId -> updatedAtMs`）。
  Future<Map<String, int>> readWorkUpdatedAtMsMap() async {
    final rows = await _db
        .customSelect('SELECT id, updated_at_ms FROM works')
        .get();
    return <String, int>{
      for (final row in rows)
        row.read<String>('id'): row.read<int>('updated_at_ms'),
    };
  }

  /// 保留并回写单部作品的同步时间戳（防止同步落库被本机当前墙钟覆写导致跨端墓碑失效）。
  Future<void> setWorkUpdatedAtMs(String workId, int updatedAtMs) async {
    if (workId.isEmpty || updatedAtMs <= 0) return;
    await (_db.update(_db.works)..where((t) => t.id.equals(workId))).write(
      WorksCompanion(updatedAtMs: Value(updatedAtMs)),
    );
  }

  /// 批量读取播放记录表中记录的 `updatedAtMs` 时间戳字典（`recordId -> updatedAtMs`）。
  Future<Map<String, int>> readPlaybackUpdatedAtMsMap() async {
    final rows = await _db
        .customSelect('SELECT id, updated_at_ms FROM playback_records')
        .get();
    return <String, int>{
      for (final row in rows)
        row.read<String>('id'): row.read<int>('updated_at_ms'),
    };
  }

  /// 向 Bangumi 离线同步队列入队或刷新单集上报意图。
  Future<void> enqueueBangumiSyncItem({
    required String queueKey,
    required int subjectId,
    required int seasonNumber,
    int? episodeNumber,
    required int targetStatus,
    int? nowMs,
  }) async {
    final ts = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    await _db
        .into(_db.bangumiSyncQueue)
        .insertOnConflictUpdate(
          BangumiSyncQueueCompanion(
            queueKey: Value(queueKey),
            subjectId: Value(subjectId),
            seasonNumber: Value(seasonNumber),
            episodeNumber: Value(episodeNumber),
            targetStatus: Value(targetStatus),
            enqueuedAtMs: Value(ts),
            retryCount: const Value(0),
            lastError: const Value(null),
            nextRetryAtMs: Value(ts),
          ),
        );
  }

  /// 读取全部待上报的 Bangumi 队列项（可选仅筛选已到重试窗口的项）。
  Future<List<BangumiSyncQueueItem>> readBangumiSyncQueue({
    int? dueBeforeMs,
  }) async {
    final query = _db.select(_db.bangumiSyncQueue)
      ..orderBy([(t) => OrderingTerm.asc(t.enqueuedAtMs)]);
    if (dueBeforeMs != null) {
      query.where((t) => t.nextRetryAtMs.isSmallerOrEqualValue(dueBeforeMs));
    }
    final rows = await query.get();
    return [
      for (final row in rows)
        BangumiSyncQueueItem(
          queueKey: row.queueKey,
          subjectId: row.subjectId,
          seasonNumber: row.seasonNumber,
          episodeNumber: row.episodeNumber,
          targetStatus: row.targetStatus,
          enqueuedAtMs: row.enqueuedAtMs,
          retryCount: row.retryCount,
          lastError: row.lastError,
          nextRetryAtMs: row.nextRetryAtMs,
        ),
    ];
  }

  /// 标记指定队列项重试失败并按指数退避延后下次调度时间。
  Future<void> markBangumiQueueRetryFailed({
    required String queueKey,
    required int retryCount,
    required String errorMessage,
    required int nextRetryAtMs,
  }) async {
    await (_db.update(
      _db.bangumiSyncQueue,
    )..where((t) => t.queueKey.equals(queueKey))).write(
      BangumiSyncQueueCompanion(
        retryCount: Value(retryCount),
        lastError: Value(errorMessage),
        nextRetryAtMs: Value(nextRetryAtMs),
      ),
    );
  }

  /// 移除已成功同步的 Bangumi 队列项。
  Future<void> removeBangumiQueueKeys(List<String> queueKeys) async {
    if (queueKeys.isEmpty) return;
    await (_db.delete(
      _db.bangumiSyncQueue,
    )..where((t) => t.queueKey.isIn(queueKeys))).go();
  }

  /// 清空全部 Bangumi 待重试队列。
  Future<void> clearBangumiSyncQueue() async {
    await _db.delete(_db.bangumiSyncQueue).go();
  }
}
