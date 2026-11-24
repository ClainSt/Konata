/// `lyric_user_overrides` 表结构与列名常量（用户手动编辑歌词与单曲/专辑偏移表）。
///
/// 物理隔离于 `user_state.db`，确保清理 `cache.db` 时永不丢失用户校准过的歌词与时间轴偏移。
abstract final class LyricUserOverridesSchema {
  /// 物理表名。
  static const String table = 'lyric_user_overrides';

  /// 覆盖记录唯一主键（如 `track::<trackKey>` 或 `album::<albumKey>`）。
  static const String colOverrideKey = 'override_key';

  /// 覆盖作用域（`track` / `album`）。
  static const String colScope = 'scope';

  /// 可选曲目规范键。
  static const String colTrackKey = 'track_key';

  /// 可选 CD 专辑规范键。
  static const String colAlbumKey = 'album_key';

  /// 用户手动选定或编辑后的增强 LRC 正文（为空表示仅保存偏移覆盖）。
  static const String colLrcContent = 'lrc_content';

  /// 用户校准时间轴偏移（毫秒，正值提前、负值延后）。
  static const String colOffsetMillis = 'offset_millis';

  /// 偏移是否已由用户主动锁定（`0`/`1`）。
  static const String colUserOffsetLocked = 'user_offset_locked';

  /// 歌词正文是否已由用户手动锁定（`0`/`1`）。
  static const String colUserEdited = 'user_edited';

  /// 最近更新时间（UTC 毫秒）。
  static const String colUpdatedAtMs = 'updated_at_ms';

  /// 最近修改设备标识。
  static const String colSourceDeviceId = 'source_device_id';

  /// 软删除墓碑时间戳（UTC 毫秒）。
  static const String colDeletedAtMs = 'deleted_at_ms';

  /// 建表 DDL 语句。
  static const String createTableSql = '''
CREATE TABLE IF NOT EXISTS $table (
  $colOverrideKey TEXT NOT NULL PRIMARY KEY,
  $colScope TEXT NOT NULL DEFAULT 'track',
  $colTrackKey TEXT,
  $colAlbumKey TEXT,
  $colLrcContent TEXT,
  $colOffsetMillis INTEGER NOT NULL DEFAULT 0,
  $colUserOffsetLocked INTEGER NOT NULL DEFAULT 0,
  $colUserEdited INTEGER NOT NULL DEFAULT 0,
  $colUpdatedAtMs INTEGER NOT NULL DEFAULT 0,
  $colSourceDeviceId TEXT NOT NULL DEFAULT '',
  $colDeletedAtMs INTEGER
);
''';

  /// 覆盖索引语句集合。
  static const List<String> indexStatements = <String>[
    'CREATE INDEX IF NOT EXISTS idx_lyric_overrides_track '
        'ON $table ($colTrackKey, $colDeletedAtMs);',
    'CREATE INDEX IF NOT EXISTS idx_lyric_overrides_album '
        'ON $table ($colAlbumKey, $colDeletedAtMs);',
  ];
}
