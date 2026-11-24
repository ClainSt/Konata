/// `series_groups` 表结构与列名常量（系列编组主表）。
abstract final class SeriesGroupsSchema {
  /// 物理表名。
  static const String table = 'series_groups';

  /// 系列主键。
  static const String colId = 'id';

  /// 跨设备稳定规范键。
  static const String colCanonicalKey = 'canonical_key';

  /// 系列展示标题。
  static const String colTitle = 'title';

  /// 关联的 TMDB 电影合集编号。
  static const String colTmdbCollectionId = 'tmdb_collection_id';

  /// 合集根目录相对路径提示。
  static const String colRootFolderHint = 'root_folder_hint';

  /// 创建时间（UTC 毫秒）。
  static const String colCreatedAtMs = 'created_at_ms';

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
  $colTitle TEXT NOT NULL,
  $colTmdbCollectionId INTEGER,
  $colRootFolderHint TEXT,
  $colCreatedAtMs INTEGER NOT NULL DEFAULT 0,
  $colUpdatedAtMs INTEGER NOT NULL DEFAULT 0,
  $colSourceDeviceId TEXT NOT NULL DEFAULT '',
  $colDeletedAtMs INTEGER
);
''';

  /// 覆盖索引语句集合。
  static const List<String> indexStatements = <String>[
    'CREATE INDEX IF NOT EXISTS idx_series_groups_active '
        'ON $table ($colDeletedAtMs, $colTitle);',
    'CREATE INDEX IF NOT EXISTS idx_series_groups_canonical '
        'ON $table ($colCanonicalKey);',
  ];
}
