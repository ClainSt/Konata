/// `artwork_negative_cache` 表结构与列名常量（封面/背景/透明 Logo 无图负缓存冷却表）。
abstract final class ArtworkNegativeCacheSchema {
  /// 物理表名。
  static const String table = 'artwork_negative_cache';

  /// 所属作品主键。
  static const String colWorkId = 'work_id';

  /// 艺术图槽位（`poster` / `backdrop` / `logo`）。
  static const String colSlot = 'slot';

  /// 负缓存冷却截止时间（UTC 毫秒）。
  static const String colNegativeUntilMs = 'negative_until_ms';

  /// 上次探测已覆盖的数据源位掩码。
  static const String colProbedSourceMask = 'probed_source_mask';

  /// 最近写入时间（UTC 毫秒）。
  static const String colUpdatedAtMs = 'updated_at_ms';

  /// 建表 DDL 语句。
  static const String createTableSql = '''
CREATE TABLE IF NOT EXISTS $table (
  $colWorkId TEXT NOT NULL,
  $colSlot TEXT NOT NULL,
  $colNegativeUntilMs INTEGER NOT NULL DEFAULT 0,
  $colProbedSourceMask INTEGER NOT NULL DEFAULT 0,
  $colUpdatedAtMs INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY ($colWorkId, $colSlot)
);
''';

  /// 覆盖索引语句集合。
  static const List<String> indexStatements = <String>[
    'CREATE INDEX IF NOT EXISTS idx_artwork_neg_until '
        'ON $table ($colNegativeUntilMs ASC);',
  ];
}
