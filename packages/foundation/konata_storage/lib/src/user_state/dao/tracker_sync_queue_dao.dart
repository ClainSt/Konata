import 'package:sqlite3/sqlite3.dart';

import '../../engine/konata_sqlite_engine.dart';
import '../schema/tracker_sync_queue_schema.dart';

/// `tracker_sync_queue` 通用多平台追番进度队列条目模型。
final class TrackerSyncQueueItem {
  /// 创建追番进度队列条目。
  const TrackerSyncQueueItem({
    required this.queueKey,
    required this.trackerId,
    required this.externalSubjectId,
    required this.seasonNumber,
    required this.targetStatus,
    required this.enqueuedAtMs,
    this.episodeNumber,
    this.payloadJson = '{}',
    this.retryCount = 0,
    this.lastError,
    this.nextRetryAtMs = 0,
  });

  /// 队列去重主键。
  final String queueKey;

  /// 第三方追番平台标识（如 `bangumi`、`mal`、`anilist`）。
  final String trackerId;

  /// 第三方平台条目编号。
  final String externalSubjectId;

  /// 本地季号。
  final int seasonNumber;

  /// 单集集号（剧场版可空）。
  final int? episodeNumber;

  /// 目标平台状态码。
  final int targetStatus;

  /// 平台专用附加 JSON 载荷。
  final String payloadJson;

  /// 首次入队时间（UTC 毫秒）。
  final int enqueuedAtMs;

  /// 已失败重试次数。
  final int retryCount;

  /// 最近一次已脱敏失败原因。
  final String? lastError;

  /// 下次允许重试的 UTC 毫秒时间戳。
  final int nextRetryAtMs;
}

/// `tracker_sync_queue` 标准 SQL 响应式 DAO（支持多平台隔离排队与退避重试）。
final class TrackerSyncQueueDao {
  /// 创建多平台追番队列 DAO。
  const TrackerSyncQueueDao(this._engine);

  final KonataSqliteEngine _engine;

  static const Set<String> _tables = <String>{TrackerSyncQueueSchema.table};

  /// 入队或覆盖合并同一去重键的待同步条目。
  void enqueue(TrackerSyncQueueItem item) {
    _engine.runTransaction((tx) => enqueueInTx(tx, item));
  }

  /// 在事务内入队待同步条目。
  void enqueueInTx(SqliteTransaction tx, TrackerSyncQueueItem item) {
    tx.execute(
      '''
INSERT INTO ${TrackerSyncQueueSchema.table} (
  ${TrackerSyncQueueSchema.colQueueKey},
  ${TrackerSyncQueueSchema.colTrackerId},
  ${TrackerSyncQueueSchema.colExternalSubjectId},
  ${TrackerSyncQueueSchema.colSeasonNumber},
  ${TrackerSyncQueueSchema.colEpisodeNumber},
  ${TrackerSyncQueueSchema.colTargetStatus},
  ${TrackerSyncQueueSchema.colPayloadJson},
  ${TrackerSyncQueueSchema.colEnqueuedAtMs},
  ${TrackerSyncQueueSchema.colRetryCount},
  ${TrackerSyncQueueSchema.colLastError},
  ${TrackerSyncQueueSchema.colNextRetryAtMs}
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(${TrackerSyncQueueSchema.colQueueKey}) DO UPDATE SET
  ${TrackerSyncQueueSchema.colTrackerId} = excluded.${TrackerSyncQueueSchema.colTrackerId},
  ${TrackerSyncQueueSchema.colExternalSubjectId} = excluded.${TrackerSyncQueueSchema.colExternalSubjectId},
  ${TrackerSyncQueueSchema.colSeasonNumber} = excluded.${TrackerSyncQueueSchema.colSeasonNumber},
  ${TrackerSyncQueueSchema.colEpisodeNumber} = excluded.${TrackerSyncQueueSchema.colEpisodeNumber},
  ${TrackerSyncQueueSchema.colTargetStatus} = excluded.${TrackerSyncQueueSchema.colTargetStatus},
  ${TrackerSyncQueueSchema.colPayloadJson} = excluded.${TrackerSyncQueueSchema.colPayloadJson},
  ${TrackerSyncQueueSchema.colEnqueuedAtMs} = excluded.${TrackerSyncQueueSchema.colEnqueuedAtMs},
  ${TrackerSyncQueueSchema.colRetryCount} = excluded.${TrackerSyncQueueSchema.colRetryCount},
  ${TrackerSyncQueueSchema.colLastError} = excluded.${TrackerSyncQueueSchema.colLastError},
  ${TrackerSyncQueueSchema.colNextRetryAtMs} = excluded.${TrackerSyncQueueSchema.colNextRetryAtMs};
''',
      <Object?>[
        item.queueKey,
        item.trackerId,
        item.externalSubjectId,
        item.seasonNumber,
        item.episodeNumber,
        item.targetStatus,
        item.payloadJson,
        item.enqueuedAtMs,
        item.retryCount,
        item.lastError,
        item.nextRetryAtMs,
      ],
      _tables,
    );
  }

  /// 查询指定平台在 [nowMs] 时刻已到重试窗口的待发送队列项。
  List<TrackerSyncQueueItem> listDueForTracker(
    String trackerId, {
    required int nowMs,
    int limit = 50,
  }) {
    final rs = _engine.select(
      'SELECT * FROM ${TrackerSyncQueueSchema.table} '
      'WHERE ${TrackerSyncQueueSchema.colTrackerId} = ? '
      'AND ${TrackerSyncQueueSchema.colNextRetryAtMs} <= ? '
      'ORDER BY ${TrackerSyncQueueSchema.colEnqueuedAtMs} ASC LIMIT ?;',
      <Object?>[trackerId, nowMs, limit],
    );
    return <TrackerSyncQueueItem>[for (final row in rs) _mapRow(row)];
  }

  /// 响应式监听指定平台的全部待同步队列长度或条目。
  Stream<List<TrackerSyncQueueItem>> watchForTracker(String trackerId) {
    return _engine.watchQuery<List<TrackerSyncQueueItem>>(
      tables: _tables,
      query: (db) {
        final rs = db.select(
          'SELECT * FROM ${TrackerSyncQueueSchema.table} '
          'WHERE ${TrackerSyncQueueSchema.colTrackerId} = ? '
          'ORDER BY ${TrackerSyncQueueSchema.colEnqueuedAtMs} ASC;',
          <Object?>[trackerId],
        );
        return <TrackerSyncQueueItem>[for (final row in rs) _mapRow(row)];
      },
    );
  }

  /// 标记队列项同步失败并记录退避重试时间。
  void markRetryFailed(
    String queueKey, {
    required int retryCount,
    required int nextRetryAtMs,
    required String lastError,
  }) {
    _engine.runTransaction((tx) {
      tx.execute(
        '''
UPDATE ${TrackerSyncQueueSchema.table}
SET ${TrackerSyncQueueSchema.colRetryCount} = ?,
    ${TrackerSyncQueueSchema.colNextRetryAtMs} = ?,
    ${TrackerSyncQueueSchema.colLastError} = ?
WHERE ${TrackerSyncQueueSchema.colQueueKey} = ?;
''',
        <Object?>[retryCount, nextRetryAtMs, lastError, queueKey],
        _tables,
      );
    });
  }

  /// 同步成功后移除队列项。
  void remove(String queueKey) {
    _engine.runTransaction((tx) {
      tx.execute(
        'DELETE FROM ${TrackerSyncQueueSchema.table} '
        'WHERE ${TrackerSyncQueueSchema.colQueueKey} = ?;',
        <Object?>[queueKey],
        _tables,
      );
    });
  }

  TrackerSyncQueueItem _mapRow(Row row) {
    return TrackerSyncQueueItem(
      queueKey: row[TrackerSyncQueueSchema.colQueueKey] as String,
      trackerId: row[TrackerSyncQueueSchema.colTrackerId] as String,
      externalSubjectId:
          row[TrackerSyncQueueSchema.colExternalSubjectId] as String,
      seasonNumber: row[TrackerSyncQueueSchema.colSeasonNumber] as int? ?? 1,
      episodeNumber: row[TrackerSyncQueueSchema.colEpisodeNumber] as int?,
      targetStatus: row[TrackerSyncQueueSchema.colTargetStatus] as int,
      payloadJson: row[TrackerSyncQueueSchema.colPayloadJson] as String? ?? '{}',
      enqueuedAtMs: row[TrackerSyncQueueSchema.colEnqueuedAtMs] as int? ?? 0,
      retryCount: row[TrackerSyncQueueSchema.colRetryCount] as int? ?? 0,
      lastError: row[TrackerSyncQueueSchema.colLastError] as String?,
      nextRetryAtMs: row[TrackerSyncQueueSchema.colNextRetryAtMs] as int? ?? 0,
    );
  }
}
