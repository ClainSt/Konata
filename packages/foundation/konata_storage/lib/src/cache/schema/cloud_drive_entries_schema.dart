/// 云盘目录快照，仅存非敏感的远端文件元数据。
abstract final class CloudDriveEntriesSchema {
  static const table = 'cloud_drive_entries';
  static const createTableSql = '''
CREATE TABLE IF NOT EXISTS cloud_drive_entries (
  source_id TEXT NOT NULL,
  file_id TEXT NOT NULL,
  parent_id TEXT NOT NULL,
  name TEXT NOT NULL,
  is_dir INTEGER NOT NULL,
  size INTEGER NOT NULL,
  mtime_ms INTEGER,
  content_hash TEXT,
  listed_at_ms INTEGER NOT NULL,
  PRIMARY KEY (source_id, file_id)
);
''';
  static const indexStatements = [
    'CREATE INDEX IF NOT EXISTS idx_cloud_entries_parent '
        'ON cloud_drive_entries (source_id, parent_id);',
  ];
}
