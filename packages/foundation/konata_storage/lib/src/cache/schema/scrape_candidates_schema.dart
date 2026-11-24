/// `scrape_candidates` 表结构与列名常量（待复核 Top-5 候选摘要可丢弃缓存表）。
abstract final class ScrapeCandidatesSchema {
  /// 物理表名。
  static const String table = 'scrape_candidates';

  /// 所属作品主键（跨库软关联 `library.db`）。
  static const String colWorkId = 'work_id';

  /// 候选排名（`1..5`）。
  static const String colRank = 'rank';

  /// 候选 TMDB 条目编号。
  static const String colTmdbId = 'tmdb_id';

  /// 候选媒体类型（`tv` / `movie`）。
  static const String colMediaType = 'media_type';

  /// 候选展示标题。
  static const String colTitle = 'title';

  /// 候选原始标题。
  static const String colOriginalTitle = 'original_title';

  /// 候选发行年份。
  static const String colYear = 'year';

  /// 候选海报相对路径。
  static const String colPosterPath = 'poster_path';

  /// 匹配综合得分。
  static const String colScore = 'score';

  /// 得分原因码列表 JSON。
  static const String colReasonsJson = 'reasons_json';

  /// 候选总集数。
  static const String colEpisodeCount = 'episode_count';

  /// 写入时间（UTC 毫秒）。
  static const String colCachedAtMs = 'cached_at_ms';

  /// 建表 DDL 语句。
  static const String createTableSql = '''
CREATE TABLE IF NOT EXISTS $table (
  $colWorkId TEXT NOT NULL,
  $colRank INTEGER NOT NULL,
  $colTmdbId INTEGER NOT NULL,
  $colMediaType TEXT NOT NULL,
  $colTitle TEXT NOT NULL,
  $colOriginalTitle TEXT,
  $colYear INTEGER,
  $colPosterPath TEXT,
  $colScore REAL NOT NULL DEFAULT 0.0,
  $colReasonsJson TEXT NOT NULL DEFAULT '[]',
  $colEpisodeCount INTEGER,
  $colCachedAtMs INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY ($colWorkId, $colRank)
);
''';

  /// 覆盖索引语句集合。
  static const List<String> indexStatements = <String>[
    'CREATE INDEX IF NOT EXISTS idx_scrape_candidates_work '
        'ON $table ($colWorkId, $colRank ASC);',
  ];
}
