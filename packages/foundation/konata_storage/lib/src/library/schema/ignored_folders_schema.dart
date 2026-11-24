import 'media_sources_schema.dart';

/// `ignored_folders` 表结构与列名常量（删除作品后的重扫防复活忽略目录表）。
abstract final class IgnoredFoldersSchema {
  /// 物理表名。
  static const String table = 'ignored_folders';

  /// 忽略规则唯一主键（如 `sourceId::relativePath`）。
  static const String colId = 'id';

  /// 跨设备稳定规范键。
  static const String colCanonicalKey = 'canonical_key';

  /// 所属媒体源主键（级联删除）。
  static const String colSourceId = 'source_id';

  /// 相对媒体源根目录的 POSIX 路径。
  static const String colRelativePath = 'relative_path';

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
  $colSourceId TEXT NOT NULL REFERENCES ${MediaSourcesSchema.table}(${MediaSourcesSchema.colId}) ON DELETE CASCADE,
  $colRelativePath TEXT NOT NULL,
  $colCreatedAtMs INTEGER NOT NULL DEFAULT 0,
  $colUpdatedAtMs INTEGER NOT NULL DEFAULT 0,
  $colSourceDeviceId TEXT NOT NULL DEFAULT '',
  $colDeletedAtMs INTEGER
);
''';

  /// 覆盖索引语句集合。
  static const List<String> indexStatements = <String>[
    'CREATE INDEX IF NOT EXISTS idx_ignored_folders_source '
        'ON $table ($colSourceId, $colDeletedAtMs);',
  ];
}
