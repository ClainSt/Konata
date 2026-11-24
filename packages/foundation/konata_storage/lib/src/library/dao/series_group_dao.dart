import 'package:konata_contracts/konata_contracts.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../engine/konata_sqlite_engine.dart';
import '../schema/series_groups_schema.dart';

/// `series_groups` 强类型持久化记录模型。
final class SeriesGroupRecord {
  /// 创建系列编组记录。
  const SeriesGroupRecord({
    required this.id,
    required this.title,
    this.canonicalKey,
    this.tmdbCollectionId,
    this.rootFolderHint,
    this.createdAtMs = 0,
    this.updatedAtMs = 0,
    this.sourceDeviceId = '',
    this.deletedAtMs,
  });

  /// 系列主键。
  final SeriesGroupId id;

  /// 跨设备稳定规范键。
  final String? canonicalKey;

  /// 系列标题。
  final String title;

  /// 关联的 TMDB 电影合集编号。
  final int? tmdbCollectionId;

  /// 合集根目录相对路径提示。
  final String? rootFolderHint;

  /// 创建时间（UTC 毫秒）。
  final int createdAtMs;

  /// 最近更新时间（UTC 毫秒）。
  final int updatedAtMs;

  /// 最近修改设备标识。
  final String sourceDeviceId;

  /// 软删除墓碑时间戳（UTC 毫秒）。
  final int? deletedAtMs;

  /// 是否已被软删除。
  bool get isDeleted => deletedAtMs != null;
}

/// `series_groups` 标准 SQL 响应式 DAO。
final class SeriesGroupDao {
  /// 创建系列编组 DAO。
  const SeriesGroupDao(this._engine);

  final KonataSqliteEngine _engine;

  static const Set<String> _tables = <String>{SeriesGroupsSchema.table};

  /// 新增或覆盖写入系列编组。
  void upsert(SeriesGroupRecord record) {
    _engine.runTransaction((tx) => upsertInTx(tx, record));
  }

  /// 在事务内写入系列编组。
  void upsertInTx(SqliteTransaction tx, SeriesGroupRecord record) {
    tx.execute(
      '''
INSERT INTO ${SeriesGroupsSchema.table} (
  ${SeriesGroupsSchema.colId},
  ${SeriesGroupsSchema.colCanonicalKey},
  ${SeriesGroupsSchema.colTitle},
  ${SeriesGroupsSchema.colTmdbCollectionId},
  ${SeriesGroupsSchema.colRootFolderHint},
  ${SeriesGroupsSchema.colCreatedAtMs},
  ${SeriesGroupsSchema.colUpdatedAtMs},
  ${SeriesGroupsSchema.colSourceDeviceId},
  ${SeriesGroupsSchema.colDeletedAtMs}
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(${SeriesGroupsSchema.colId}) DO UPDATE SET
  ${SeriesGroupsSchema.colCanonicalKey} = excluded.${SeriesGroupsSchema.colCanonicalKey},
  ${SeriesGroupsSchema.colTitle} = excluded.${SeriesGroupsSchema.colTitle},
  ${SeriesGroupsSchema.colTmdbCollectionId} = excluded.${SeriesGroupsSchema.colTmdbCollectionId},
  ${SeriesGroupsSchema.colRootFolderHint} = excluded.${SeriesGroupsSchema.colRootFolderHint},
  ${SeriesGroupsSchema.colCreatedAtMs} = excluded.${SeriesGroupsSchema.colCreatedAtMs},
  ${SeriesGroupsSchema.colUpdatedAtMs} = excluded.${SeriesGroupsSchema.colUpdatedAtMs},
  ${SeriesGroupsSchema.colSourceDeviceId} = excluded.${SeriesGroupsSchema.colSourceDeviceId},
  ${SeriesGroupsSchema.colDeletedAtMs} = excluded.${SeriesGroupsSchema.colDeletedAtMs};
''',
      <Object?>[
        record.id.value,
        record.canonicalKey,
        record.title,
        record.tmdbCollectionId,
        record.rootFolderHint,
        record.createdAtMs,
        record.updatedAtMs,
        record.sourceDeviceId,
        record.deletedAtMs,
      ],
      _tables,
    );
  }

  /// 按主键查询系列编组。
  SeriesGroupRecord? findById(
    SeriesGroupId id, {
    bool includeDeleted = false,
  }) {
    final whereDeleted = includeDeleted
        ? ''
        : ' AND ${SeriesGroupsSchema.colDeletedAtMs} IS NULL';
    final rs = _engine.select(
      'SELECT * FROM ${SeriesGroupsSchema.table} '
      'WHERE ${SeriesGroupsSchema.colId} = ?$whereDeleted LIMIT 1;',
      <Object?>[id.value],
    );
    if (rs.isEmpty) return null;
    return _mapRow(rs.first);
  }

  /// 列出全部系列编组。
  List<SeriesGroupRecord> listAll({bool includeDeleted = false}) {
    return _queryAll(_engine.select, includeDeleted: includeDeleted);
  }

  /// 响应式监听系列编组列表变化。
  Stream<List<SeriesGroupRecord>> watchAll({bool includeDeleted = false}) {
    return _engine.watchQuery<List<SeriesGroupRecord>>(
      tables: _tables,
      query: (db) => _queryAll(db.select, includeDeleted: includeDeleted),
    );
  }

  /// 软删除系列编组并写入墓碑时间戳。
  void softDelete(
    SeriesGroupId id, {
    required int deletedAtMs,
    String sourceDeviceId = '',
  }) {
    _engine.runTransaction((tx) {
      tx.execute(
        '''
UPDATE ${SeriesGroupsSchema.table}
SET ${SeriesGroupsSchema.colDeletedAtMs} = ?,
    ${SeriesGroupsSchema.colUpdatedAtMs} = ?,
    ${SeriesGroupsSchema.colSourceDeviceId} = ?
WHERE ${SeriesGroupsSchema.colId} = ?;
''',
        <Object?>[deletedAtMs, deletedAtMs, sourceDeviceId, id.value],
        _tables,
      );
    });
  }

  List<SeriesGroupRecord> _queryAll(
    ResultSet Function(String, [List<Object?>]) selectFn, {
    required bool includeDeleted,
  }) {
    final whereClause = includeDeleted
        ? ''
        : 'WHERE ${SeriesGroupsSchema.colDeletedAtMs} IS NULL ';
    final rs = selectFn(
      'SELECT * FROM ${SeriesGroupsSchema.table} '
      '${whereClause}ORDER BY ${SeriesGroupsSchema.colTitle} ASC, ${SeriesGroupsSchema.colId} ASC;',
    );
    return <SeriesGroupRecord>[for (final row in rs) _mapRow(row)];
  }

  SeriesGroupRecord _mapRow(Row row) {
    return SeriesGroupRecord(
      id: SeriesGroupId.trusted(row[SeriesGroupsSchema.colId] as String),
      canonicalKey: row[SeriesGroupsSchema.colCanonicalKey] as String?,
      title: row[SeriesGroupsSchema.colTitle] as String,
      tmdbCollectionId: row[SeriesGroupsSchema.colTmdbCollectionId] as int?,
      rootFolderHint: row[SeriesGroupsSchema.colRootFolderHint] as String?,
      createdAtMs: row[SeriesGroupsSchema.colCreatedAtMs] as int? ?? 0,
      updatedAtMs: row[SeriesGroupsSchema.colUpdatedAtMs] as int? ?? 0,
      sourceDeviceId: row[SeriesGroupsSchema.colSourceDeviceId] as String? ?? '',
      deletedAtMs: row[SeriesGroupsSchema.colDeletedAtMs] as int?,
    );
  }
}
