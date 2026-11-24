import 'package:konata_contracts/konata_contracts.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../engine/konata_sqlite_engine.dart';
import '../schema/ignored_folders_schema.dart';

/// `ignored_folders` 强类型持久化记录模型。
final class IgnoredFolderRecord {
  /// 创建忽略目录记录。
  const IgnoredFolderRecord({
    required this.id,
    required this.sourceId,
    required this.relativePath,
    this.canonicalKey,
    this.createdAtMs = 0,
    this.updatedAtMs = 0,
    this.sourceDeviceId = '',
    this.deletedAtMs,
  });

  /// 规则主键（如 `sourceId::relativePath`）。
  final String id;

  /// 跨设备稳定规范键。
  final String? canonicalKey;

  /// 所属媒体源主键。
  final SourceId sourceId;

  /// 相对媒体源根目录的 POSIX 路径。
  final String relativePath;

  /// 添加时间（UTC 毫秒）。
  final int createdAtMs;

  /// 最近更新时间（UTC 毫秒）。
  final int updatedAtMs;

  /// 最近修改设备标识。
  final String sourceDeviceId;

  /// 软删除墓碑时间戳（UTC 毫秒）。
  final int? deletedAtMs;

  /// 是否已软删除。
  bool get isDeleted => deletedAtMs != null;
}

/// `ignored_folders` 标准 SQL 响应式 DAO。
final class IgnoredFolderDao {
  /// 创建忽略目录 DAO。
  const IgnoredFolderDao(this._engine);

  final KonataSqliteEngine _engine;

  static const Set<String> _tables = <String>{IgnoredFoldersSchema.table};

  /// 新增或覆盖写入一条忽略目录规则。
  void upsert(IgnoredFolderRecord record) {
    _engine.runTransaction((tx) => upsertInTx(tx, record));
  }

  /// 在事务内写入忽略目录规则。
  void upsertInTx(SqliteTransaction tx, IgnoredFolderRecord record) {
    tx.execute(
      '''
INSERT INTO ${IgnoredFoldersSchema.table} (
  ${IgnoredFoldersSchema.colId},
  ${IgnoredFoldersSchema.colCanonicalKey},
  ${IgnoredFoldersSchema.colSourceId},
  ${IgnoredFoldersSchema.colRelativePath},
  ${IgnoredFoldersSchema.colCreatedAtMs},
  ${IgnoredFoldersSchema.colUpdatedAtMs},
  ${IgnoredFoldersSchema.colSourceDeviceId},
  ${IgnoredFoldersSchema.colDeletedAtMs}
) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(${IgnoredFoldersSchema.colId}) DO UPDATE SET
  ${IgnoredFoldersSchema.colCanonicalKey} = excluded.${IgnoredFoldersSchema.colCanonicalKey},
  ${IgnoredFoldersSchema.colSourceId} = excluded.${IgnoredFoldersSchema.colSourceId},
  ${IgnoredFoldersSchema.colRelativePath} = excluded.${IgnoredFoldersSchema.colRelativePath},
  ${IgnoredFoldersSchema.colCreatedAtMs} = excluded.${IgnoredFoldersSchema.colCreatedAtMs},
  ${IgnoredFoldersSchema.colUpdatedAtMs} = excluded.${IgnoredFoldersSchema.colUpdatedAtMs},
  ${IgnoredFoldersSchema.colSourceDeviceId} = excluded.${IgnoredFoldersSchema.colSourceDeviceId},
  ${IgnoredFoldersSchema.colDeletedAtMs} = excluded.${IgnoredFoldersSchema.colDeletedAtMs};
''',
      <Object?>[
        record.id,
        record.canonicalKey,
        record.sourceId.value,
        record.relativePath,
        record.createdAtMs,
        record.updatedAtMs,
        record.sourceDeviceId,
        record.deletedAtMs,
      ],
      _tables,
    );
  }

  /// 查询指定媒体源下全部有效忽略目录。
  List<IgnoredFolderRecord> listBySource(
    SourceId sourceId, {
    bool includeDeleted = false,
  }) {
    return _queryBySource(
      _engine.select,
      sourceId,
      includeDeleted: includeDeleted,
    );
  }

  /// 响应式监听指定媒体源下的忽略目录列表。
  Stream<List<IgnoredFolderRecord>> watchBySource(
    SourceId sourceId, {
    bool includeDeleted = false,
  }) {
    return _engine.watchQuery<List<IgnoredFolderRecord>>(
      tables: _tables,
      query: (db) =>
          _queryBySource(db.select, sourceId, includeDeleted: includeDeleted),
    );
  }

  /// 软删除指定忽略目录规则。
  void softDelete(
    String id, {
    required int deletedAtMs,
    String sourceDeviceId = '',
  }) {
    _engine.runTransaction((tx) {
      tx.execute(
        '''
UPDATE ${IgnoredFoldersSchema.table}
SET ${IgnoredFoldersSchema.colDeletedAtMs} = ?,
    ${IgnoredFoldersSchema.colUpdatedAtMs} = ?,
    ${IgnoredFoldersSchema.colSourceDeviceId} = ?
WHERE ${IgnoredFoldersSchema.colId} = ?;
''',
        <Object?>[deletedAtMs, deletedAtMs, sourceDeviceId, id],
        _tables,
      );
    });
  }

  List<IgnoredFolderRecord> _queryBySource(
    ResultSet Function(String, [List<Object?>]) selectFn,
    SourceId sourceId, {
    required bool includeDeleted,
  }) {
    final deletedClause = includeDeleted
        ? ''
        : ' AND ${IgnoredFoldersSchema.colDeletedAtMs} IS NULL';
    final rs = selectFn(
      'SELECT * FROM ${IgnoredFoldersSchema.table} '
      'WHERE ${IgnoredFoldersSchema.colSourceId} = ?$deletedClause '
      'ORDER BY ${IgnoredFoldersSchema.colRelativePath} ASC;',
      <Object?>[sourceId.value],
    );
    return <IgnoredFolderRecord>[for (final row in rs) _mapRow(row)];
  }

  IgnoredFolderRecord _mapRow(Row row) {
    return IgnoredFolderRecord(
      id: row[IgnoredFoldersSchema.colId] as String,
      canonicalKey: row[IgnoredFoldersSchema.colCanonicalKey] as String?,
      sourceId: SourceId.trusted(
        row[IgnoredFoldersSchema.colSourceId] as String,
      ),
      relativePath: row[IgnoredFoldersSchema.colRelativePath] as String,
      createdAtMs: row[IgnoredFoldersSchema.colCreatedAtMs] as int? ?? 0,
      updatedAtMs: row[IgnoredFoldersSchema.colUpdatedAtMs] as int? ?? 0,
      sourceDeviceId:
          row[IgnoredFoldersSchema.colSourceDeviceId] as String? ?? '',
      deletedAtMs: row[IgnoredFoldersSchema.colDeletedAtMs] as int?,
    );
  }
}
