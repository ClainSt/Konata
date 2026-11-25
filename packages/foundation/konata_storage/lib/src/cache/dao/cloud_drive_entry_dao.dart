import 'package:konata_contracts/konata_contracts.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../engine/konata_sqlite_engine.dart';
import '../schema/cloud_drive_entries_schema.dart';

/// 单条目录快照记录，文件标识按媒体源隔离。
final class CloudDriveEntryRecord {
  const CloudDriveEntryRecord({
    required this.sourceId,
    required this.fileId,
    required this.parentId,
    required this.name,
    required this.isDirectory,
    required this.size,
    required this.listedAtMs,
    this.mtimeMs,
    this.contentHash,
  });

  final SourceId sourceId;
  final String fileId;
  final String parentId;
  final String name;
  final bool isDirectory;
  final int size;
  final int listedAtMs;
  final int? mtimeMs;
  final String? contentHash;
}

/// 目录缓存不保存凭据或临时直链，完整列举后原子替换单层快照。
final class CloudDriveEntryDao {
  const CloudDriveEntryDao(this._engine);
  final KonataSqliteEngine _engine;
  static const _tables = {CloudDriveEntriesSchema.table};

  void replaceDirectory(
    SourceId sourceId,
    String parentId,
    Iterable<CloudDriveEntryRecord> entries,
  ) {
    final rows = entries.toList(growable: false);
    if (rows.any((r) => r.sourceId != sourceId || r.parentId != parentId)) {
      throw ArgumentError('目录快照包含不同媒体源或父目录');
    }
    _engine.runTransaction((tx) {
      tx.execute(
        'DELETE FROM cloud_drive_entries WHERE source_id = ? AND parent_id = ?;',
        [sourceId.value, parentId],
        _tables,
      );
      for (final r in rows) {
        tx.execute(
          '''
INSERT INTO cloud_drive_entries
(source_id,file_id,parent_id,name,is_dir,size,mtime_ms,content_hash,listed_at_ms)
VALUES (?,?,?,?,?,?,?,?,?)
ON CONFLICT(source_id,file_id) DO UPDATE SET
parent_id=excluded.parent_id,name=excluded.name,is_dir=excluded.is_dir,
size=excluded.size,mtime_ms=excluded.mtime_ms,
content_hash=excluded.content_hash,listed_at_ms=excluded.listed_at_ms;
''',
          [
            r.sourceId.value,
            r.fileId,
            r.parentId,
            r.name,
            r.isDirectory ? 1 : 0,
            r.size,
            r.mtimeMs,
            r.contentHash,
            r.listedAtMs,
          ],
          _tables,
        );
      }
    });
  }

  CloudDriveEntryRecord? find(SourceId sourceId, String fileId) {
    final rows = _engine.select(
      'SELECT * FROM cloud_drive_entries WHERE source_id = ? AND file_id = ?;',
      [sourceId.value, fileId],
    );
    return rows.isEmpty ? null : _map(rows.single);
  }

  List<CloudDriveEntryRecord> listDirectory(
    SourceId sourceId,
    String parentId,
  ) => [
    for (final row in _engine.select(
      'SELECT * FROM cloud_drive_entries WHERE source_id = ? AND parent_id = ? ORDER BY name,file_id;',
      [sourceId.value, parentId],
    ))
      _map(row),
  ];

  void clearSource(SourceId sourceId) {
    _engine.runTransaction((tx) {
      tx.execute('DELETE FROM cloud_drive_entries WHERE source_id = ?;', [
        sourceId.value,
      ], _tables);
    });
  }

  CloudDriveEntryRecord _map(Row row) => CloudDriveEntryRecord(
    sourceId: SourceId.trusted(row['source_id'] as String),
    fileId: row['file_id'] as String,
    parentId: row['parent_id'] as String,
    name: row['name'] as String,
    isDirectory: row['is_dir'] == 1,
    size: row['size'] as int,
    mtimeMs: row['mtime_ms'] as int?,
    contentHash: row['content_hash'] as String?,
    listedAtMs: row['listed_at_ms'] as int,
  );
}
