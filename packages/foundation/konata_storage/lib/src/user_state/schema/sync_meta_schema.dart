/// `sync_meta` 表结构与列名常量（仅存非敏感同步状态，如设备 ID、切片摘要与上次同步时间）。
abstract final class SyncMetaSchema {
  /// 物理表名。
  static const String table = 'sync_meta';

  /// 元信息键名。
  static const String colMetaKey = 'meta_key';

  /// 元信息值文本（严禁存储任何明文密码或令牌）。
  static const String colMetaValue = 'meta_value';

  /// 最近更新时间（UTC 毫秒）。
  static const String colUpdatedAtMs = 'updated_at_ms';

  /// 建表 DDL 语句。
  static const String createTableSql = '''
CREATE TABLE IF NOT EXISTS $table (
  $colMetaKey TEXT NOT NULL PRIMARY KEY,
  $colMetaValue TEXT NOT NULL,
  $colUpdatedAtMs INTEGER NOT NULL DEFAULT 0
);
''';
}
