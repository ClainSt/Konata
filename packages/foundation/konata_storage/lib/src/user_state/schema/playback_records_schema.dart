/// `playback_records` 表结构与列名常量（高频播放记录表，位于 `user_state.db` 避免锁 `library.db`）。
abstract final class PlaybackRecordsSchema {
  /// 物理表名。
  static const String table = 'playback_records';

  /// 记录唯一主键（UUID）。
  static const String colId = 'id';

  /// 跨设备稳定规范键（如 `<workCanonicalKey>::s1::e3`）。
  static const String colCanonicalKey = 'canonical_key';

  /// 所属作品主键（跨库软关联 `library.db`）。
  static const String colWorkId = 'work_id';

  /// 所属逻辑剧集主键。
  static const String colEpisodeId = 'episode_id';

  /// 实际播放物理版本主键。
  static const String colVariantId = 'variant_id';

  /// 季号。
  static const String colSeasonNumber = 'season_number';

  /// 集号（未识别或剧场版可空）。
  static const String colEpisodeNumber = 'episode_number';

  /// 单集展示标题快照。
  static const String colEpisodeTitle = 'episode_title';

  /// 媒体源协议类型。
  static const String colSourceKind = 'source_kind';

  /// 最近播放时间戳（UTC 毫秒）。
  static const String colPlayedAtMs = 'played_at_ms';

  /// 当前播放进度（秒）。
  static const String colPositionSeconds = 'position_seconds';

  /// 媒体总时长（秒）。
  static const String colDurationSeconds = 'duration_seconds';

  /// 是否已达完播状态（`0`/`1`）。
  static const String colIsCompleted = 'is_completed';

  /// 最近更新时间（UTC 毫秒）。
  static const String colUpdatedAtMs = 'updated_at_ms';

  /// 最近修改设备标识。
  static const String colSourceDeviceId = 'source_device_id';

  /// 软删除墓碑时间戳（UTC 毫秒）。
  static const String colDeletedAtMs = 'deleted_at_ms';

  /// 建表 DDL 语句。
  static const String createTableSql = '''
CREATE TABLE IF NOT EXISTS $table (
  $colId TEXT NOT NULL PRIMARY KEY,
  $colCanonicalKey TEXT,
  $colWorkId TEXT NOT NULL,
  $colEpisodeId TEXT NOT NULL,
  $colVariantId TEXT NOT NULL,
  $colSeasonNumber INTEGER NOT NULL DEFAULT 1,
  $colEpisodeNumber INTEGER,
  $colEpisodeTitle TEXT NOT NULL DEFAULT '',
  $colSourceKind TEXT NOT NULL DEFAULT 'local',
  $colPlayedAtMs INTEGER NOT NULL DEFAULT 0,
  $colPositionSeconds INTEGER NOT NULL DEFAULT 0,
  $colDurationSeconds INTEGER NOT NULL DEFAULT 0,
  $colIsCompleted INTEGER NOT NULL DEFAULT 0,
  $colUpdatedAtMs INTEGER NOT NULL DEFAULT 0,
  $colSourceDeviceId TEXT NOT NULL DEFAULT '',
  $colDeletedAtMs INTEGER
);
''';

  /// 覆盖索引语句集合。
  static const List<String> indexStatements = <String>[
    'CREATE INDEX IF NOT EXISTS idx_playback_records_work_played '
        'ON $table ($colWorkId, $colDeletedAtMs, $colPlayedAtMs DESC);',
    'CREATE INDEX IF NOT EXISTS idx_playback_records_episode '
        'ON $table ($colEpisodeId, $colDeletedAtMs, $colPlayedAtMs DESC);',
    'CREATE INDEX IF NOT EXISTS idx_playback_records_played '
        'ON $table ($colDeletedAtMs, $colPlayedAtMs DESC);',
    'CREATE INDEX IF NOT EXISTS idx_playback_records_canonical '
        'ON $table ($colCanonicalKey);',
  ];
}
