/// `media_sources` 表结构与列名常量（绝不在 DAO 中手写裸列名字符串）。
abstract final class MediaSourcesSchema {
  /// 物理表名。
  static const String table = 'media_sources';

  /// 媒体源主键。
  static const String colId = 'id';

  /// 跨设备稳定规范键。
  static const String colCanonicalKey = 'canonical_key';

  /// 协议类型（`local` / `webdav` / `smb`）。
  static const String colKind = 'kind';

  /// 用户可见名称。
  static const String colLabel = 'label';

  /// 本地根目录或远程地址。
  static const String colLocation = 'location';

  /// 可选登录用户名（密码严禁落库，统一走 `SecureStoragePort`）。
  static const String colUsername = 'username';

  /// 创建时间（UTC 毫秒）。
  static const String colCreatedAtMs = 'created_at_ms';

  /// 最近更新时间（UTC 毫秒）。
  static const String colUpdatedAtMs = 'updated_at_ms';

  /// 最近修改设备标识。
  static const String colSourceDeviceId = 'source_device_id';

  /// 软删除墓碑时间戳（UTC 毫秒，非空代表已软删除）。
  static const String colDeletedAtMs = 'deleted_at_ms';

  /// 建表 DDL 语句。
  static const String createTableSql = '''
CREATE TABLE IF NOT EXISTS $table (
  $colId TEXT NOT NULL PRIMARY KEY,
  $colCanonicalKey TEXT,
  $colKind TEXT NOT NULL,
  $colLabel TEXT NOT NULL,
  $colLocation TEXT NOT NULL,
  $colUsername TEXT,
  $colCreatedAtMs INTEGER NOT NULL DEFAULT 0,
  $colUpdatedAtMs INTEGER NOT NULL DEFAULT 0,
  $colSourceDeviceId TEXT NOT NULL DEFAULT '',
  $colDeletedAtMs INTEGER
);
''';

  /// 覆盖索引语句集合。
  static const List<String> indexStatements = <String>[
    'CREATE INDEX IF NOT EXISTS idx_media_sources_active '
        'ON $table ($colDeletedAtMs, $colCreatedAtMs ASC);',
    'CREATE INDEX IF NOT EXISTS idx_media_sources_canonical '
        'ON $table ($colCanonicalKey);',
  ];
}
