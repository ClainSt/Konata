/// `tracker_sync_queue` 表结构与列名常量（通用多平台第三方追番进度离线队列）。
///
/// 原生携带 [colTrackerId] 列，一套表结构同时支持 Bangumi、MyAnimeList、AniList、Simkl 等平台。
abstract final class TrackerSyncQueueSchema {
  /// 物理表名。
  static const String table = 'tracker_sync_queue';

  /// 队列项唯一去重主键（例如 `bangumi::12345::s1::e3`）。
  static const String colQueueKey = 'queue_key';

  /// 第三方追番平台标识（例如 `bangumi`、`mal`、`anilist`、`simkl`）。
  static const String colTrackerId = 'tracker_id';

  /// 第三方平台条目编号。
  static const String colExternalSubjectId = 'external_subject_id';

  /// 本地季号（用于区分正片与特典）。
  static const String colSeasonNumber = 'season_number';

  /// 单集集号（剧场版或单部作品可空）。
  static const String colEpisodeNumber = 'episode_number';

  /// 目标平台状态码（如 `2=看过`、`0=未看`）。
  static const String colTargetStatus = 'target_status';

  /// 平台专用附加参数 JSON。
  static const String colPayloadJson = 'payload_json';

  /// 首次入队时间戳（UTC 毫秒）。
  static const String colEnqueuedAtMs = 'enqueued_at_ms';

  /// 已失败重试次数。
  static const String colRetryCount = 'retry_count';

  /// 最近一次已脱敏失败说明。
  static const String colLastError = 'last_error';

  /// 下次允许重试的 UTC 毫秒时间戳。
  static const String colNextRetryAtMs = 'next_retry_at_ms';

  /// 建表 DDL 语句。
  static const String createTableSql = '''
CREATE TABLE IF NOT EXISTS $table (
  $colQueueKey TEXT NOT NULL PRIMARY KEY,
  $colTrackerId TEXT NOT NULL,
  $colExternalSubjectId TEXT NOT NULL,
  $colSeasonNumber INTEGER NOT NULL DEFAULT 1,
  $colEpisodeNumber INTEGER,
  $colTargetStatus INTEGER NOT NULL,
  $colPayloadJson TEXT NOT NULL DEFAULT '{}',
  $colEnqueuedAtMs INTEGER NOT NULL DEFAULT 0,
  $colRetryCount INTEGER NOT NULL DEFAULT 0,
  $colLastError TEXT,
  $colNextRetryAtMs INTEGER NOT NULL DEFAULT 0
);
''';

  /// 覆盖索引语句集合。
  static const List<String> indexStatements = <String>[
    'CREATE INDEX IF NOT EXISTS idx_tracker_queue_due '
        'ON $table ($colTrackerId, $colNextRetryAtMs ASC, $colEnqueuedAtMs ASC);',
  ];
}
