/// `scoped_prefs` 表结构与列名常量（分命名空间自治配置表）。
abstract final class ScopedPrefsSchema {
  /// 物理表名。
  static const String table = 'scoped_prefs';

  /// 配置命名空间唯一主键（如 `feature_player_video.playback`）。
  static const String colNamespace = 'namespace';

  /// 配置切片数据结构版本号。
  static const String colSchemaVer = 'schema_ver';

  /// 跨设备同步策略（`portable` / `deviceLocal`）。
  static const String colSyncPolicy = 'sync_policy';

  /// 配置主体 JSON 载荷（严禁存放任何密码或访问令牌）。
  static const String colPayloadJson = 'payload_json';

  /// 最近更新时间（UTC 毫秒）。
  static const String colUpdatedAtMs = 'updated_at_ms';

  /// 最近修改设备标识。
  static const String colSourceDeviceId = 'source_device_id';

  /// 建表 DDL 语句。
  static const String createTableSql = '''
CREATE TABLE IF NOT EXISTS $table (
  $colNamespace TEXT NOT NULL PRIMARY KEY,
  $colSchemaVer INTEGER NOT NULL DEFAULT 1,
  $colSyncPolicy TEXT NOT NULL DEFAULT 'deviceLocal',
  $colPayloadJson TEXT NOT NULL DEFAULT '{}',
  $colUpdatedAtMs INTEGER NOT NULL DEFAULT 0,
  $colSourceDeviceId TEXT NOT NULL DEFAULT ''
);
''';

  /// 覆盖索引语句集合。
  static const List<String> indexStatements = <String>[
    'CREATE INDEX IF NOT EXISTS idx_scoped_prefs_policy '
        'ON $table ($colSyncPolicy, $colUpdatedAtMs DESC);',
  ];
}
