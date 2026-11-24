/// `lyric_cache_entries` 表结构与列名常量（在线歌词自动抓取可丢弃缓存表）。
///
/// 仅存自动检索结果，严禁存放用户手动编辑歌词与偏移（此类数据隔离于 `user_state.db`）。
abstract final class LyricCacheEntriesSchema {
  /// 物理表名。
  static const String table = 'lyric_cache_entries';

  /// 物理曲目缓存键。
  static const String colTrackKey = 'track_key';

  /// 跨文件共享的歌曲规范键。
  static const String colSongKey = 'song_key';

  /// 缓存命中状态（`hit` / `miss`）。
  static const String colStatus = 'status';

  /// 命中的歌词源标识。
  static const String colSource = 'source';

  /// 来源内部歌曲编号。
  static const String colSourceId = 'source_id';

  /// 自动抓取到的增强 LRC 正文。
  static const String colLrcContent = 'lrc_content';

  /// 命中候选得分。
  static const String colScore = 'score';

  /// 歌词引擎版本号。
  static const String colEngineVersion = 'engine_version';

  /// 最近写入时间（UTC 毫秒）。
  static const String colUpdatedAtMs = 'updated_at_ms';

  /// 建表 DDL 语句。
  static const String createTableSql = '''
CREATE TABLE IF NOT EXISTS $table (
  $colTrackKey TEXT NOT NULL PRIMARY KEY,
  $colSongKey TEXT,
  $colStatus TEXT NOT NULL,
  $colSource TEXT,
  $colSourceId TEXT NOT NULL DEFAULT '',
  $colLrcContent TEXT NOT NULL DEFAULT '',
  $colScore REAL NOT NULL DEFAULT 0.0,
  $colEngineVersion INTEGER NOT NULL DEFAULT 1,
  $colUpdatedAtMs INTEGER NOT NULL DEFAULT 0
);
''';

  /// 覆盖索引语句集合。
  static const List<String> indexStatements = <String>[
    'CREATE INDEX IF NOT EXISTS idx_lyric_cache_song '
        'ON $table ($colSongKey);',
  ];
}
