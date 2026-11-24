import 'package:konata_contracts/konata_contracts.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../engine/konata_sqlite_engine.dart';
import '../../engine/row_codec.dart';
import '../schema/media_sources_schema.dart';

/// `media_sources` 强类型持久化记录模型（不含任何明文密码）。
final class MediaSourceRecord {
  /// 创建媒体源记录。
  const MediaSourceRecord({
    required this.id,
    required this.kind,
    required this.label,
    required this.location,
    this.canonicalKey,
    this.username,
    this.createdAtMs = 0,
    this.updatedAtMs = 0,
    this.sourceDeviceId = '',
    this.deletedAtMs,
  });

  /// 媒体源主键。
  final SourceId id;

  /// 跨设备稳定规范键。
  final String? canonicalKey;

  /// 协议类型。
  final MediaSourceKind kind;

  /// 显示名称。
  final String label;

  /// 根路径或远程地址。
  final String location;

  /// 可选用户名。
  final String? username;

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

  /// 投影为跨包只读视图。
  MediaSourceView toReadView() => MediaSourceView(
    id: id,
    kind: kind,
    label: label,
    location: location,
    username: username,
  );
}

/// `media_sources` 标准 SQL 响应式 DAO。
final class MediaSourceDao {
  /// 创建媒体源 DAO。
  const MediaSourceDao(this._engine);

  final KonataSqliteEngine _engine;

  static const Set<String> _tables = <String>{MediaSourcesSchema.table};

  /// 新增或覆盖写入一条媒体源记录。
  void upsert(MediaSourceRecord record) {
    _engine.runTransaction((tx) => upsertInTx(tx, record));
  }

  /// 在已有事务内新增或覆盖写入媒体源记录。
  void upsertInTx(SqliteTransaction tx, MediaSourceRecord record) {
    tx.execute(
      '''
INSERT INTO ${MediaSourcesSchema.table} (
  ${MediaSourcesSchema.colId},
  ${MediaSourcesSchema.colCanonicalKey},
  ${MediaSourcesSchema.colKind},
  ${MediaSourcesSchema.colLabel},
  ${MediaSourcesSchema.colLocation},
  ${MediaSourcesSchema.colUsername},
  ${MediaSourcesSchema.colCreatedAtMs},
  ${MediaSourcesSchema.colUpdatedAtMs},
  ${MediaSourcesSchema.colSourceDeviceId},
  ${MediaSourcesSchema.colDeletedAtMs}
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(${MediaSourcesSchema.colId}) DO UPDATE SET
  ${MediaSourcesSchema.colCanonicalKey} = excluded.${MediaSourcesSchema.colCanonicalKey},
  ${MediaSourcesSchema.colKind} = excluded.${MediaSourcesSchema.colKind},
  ${MediaSourcesSchema.colLabel} = excluded.${MediaSourcesSchema.colLabel},
  ${MediaSourcesSchema.colLocation} = excluded.${MediaSourcesSchema.colLocation},
  ${MediaSourcesSchema.colUsername} = excluded.${MediaSourcesSchema.colUsername},
  ${MediaSourcesSchema.colCreatedAtMs} = excluded.${MediaSourcesSchema.colCreatedAtMs},
  ${MediaSourcesSchema.colUpdatedAtMs} = excluded.${MediaSourcesSchema.colUpdatedAtMs},
  ${MediaSourcesSchema.colSourceDeviceId} = excluded.${MediaSourcesSchema.colSourceDeviceId},
  ${MediaSourcesSchema.colDeletedAtMs} = excluded.${MediaSourcesSchema.colDeletedAtMs};
''',
      <Object?>[
        record.id.value,
        record.canonicalKey,
        record.kind.name,
        record.label,
        record.location,
        record.username,
        record.createdAtMs,
        record.updatedAtMs,
        record.sourceDeviceId,
        record.deletedAtMs,
      ],
      _tables,
    );
  }

  /// 按主键查询媒体源（默认过滤已软删除记录）。
  MediaSourceRecord? findById(SourceId id, {bool includeDeleted = false}) {
    final whereDeleted = includeDeleted
        ? ''
        : ' AND ${MediaSourcesSchema.colDeletedAtMs} IS NULL';
    final rs = _engine.select(
      'SELECT * FROM ${MediaSourcesSchema.table} '
      'WHERE ${MediaSourcesSchema.colId} = ?$whereDeleted LIMIT 1;',
      <Object?>[id.value],
    );
    if (rs.isEmpty) return null;
    return _mapRow(rs.first);
  }

  /// 列出全部有效媒体源（按创建时间升序）。
  List<MediaSourceRecord> listAll({bool includeDeleted = false}) {
    return _queryAll(_engine.select, includeDeleted: includeDeleted);
  }

  /// 响应式监听有效媒体源列表变化。
  Stream<List<MediaSourceRecord>> watchAll({bool includeDeleted = false}) {
    return _engine.watchQuery<List<MediaSourceRecord>>(
      tables: _tables,
      query: (db) => _queryAll(db.select, includeDeleted: includeDeleted),
    );
  }

  /// 软删除媒体源并写入墓碑时间戳。
  void softDelete(
    SourceId id, {
    required int deletedAtMs,
    String sourceDeviceId = '',
  }) {
    _engine.runTransaction((tx) {
      tx.execute(
        '''
UPDATE ${MediaSourcesSchema.table}
SET ${MediaSourcesSchema.colDeletedAtMs} = ?,
    ${MediaSourcesSchema.colUpdatedAtMs} = ?,
    ${MediaSourcesSchema.colSourceDeviceId} = ?
WHERE ${MediaSourcesSchema.colId} = ?;
''',
        <Object?>[deletedAtMs, deletedAtMs, sourceDeviceId, id.value],
        _tables,
      );
    });
  }

  /// 物理彻底删除媒体源记录（级联清理关联变体与忽略目录）。
  void hardDelete(SourceId id) {
    _engine.runTransaction((tx) {
      tx.execute(
        'DELETE FROM ${MediaSourcesSchema.table} WHERE ${MediaSourcesSchema.colId} = ?;',
        <Object?>[id.value],
        _tables,
      );
    });
  }

  List<MediaSourceRecord> _queryAll(
    ResultSet Function(String, [List<Object?>]) selectFn, {
    required bool includeDeleted,
  }) {
    final whereClause = includeDeleted
        ? ''
        : 'WHERE ${MediaSourcesSchema.colDeletedAtMs} IS NULL ';
    final rs = selectFn(
      'SELECT * FROM ${MediaSourcesSchema.table} '
      '${whereClause}ORDER BY ${MediaSourcesSchema.colCreatedAtMs} ASC, ${MediaSourcesSchema.colId} ASC;',
    );
    return <MediaSourceRecord>[for (final row in rs) _mapRow(row)];
  }

  MediaSourceRecord _mapRow(Row row) {
    return MediaSourceRecord(
      id: SourceId.trusted(row[MediaSourcesSchema.colId] as String),
      canonicalKey: row[MediaSourcesSchema.colCanonicalKey] as String?,
      kind: SqliteRowCodec.decodeEnum(
        MediaSourceKind.values,
        row[MediaSourcesSchema.colKind],
        MediaSourceKind.local,
      ),
      label: row[MediaSourcesSchema.colLabel] as String,
      location: row[MediaSourcesSchema.colLocation] as String,
      username: row[MediaSourcesSchema.colUsername] as String?,
      createdAtMs: row[MediaSourcesSchema.colCreatedAtMs] as int? ?? 0,
      updatedAtMs: row[MediaSourcesSchema.colUpdatedAtMs] as int? ?? 0,
      sourceDeviceId: row[MediaSourcesSchema.colSourceDeviceId] as String? ?? '',
      deletedAtMs: row[MediaSourcesSchema.colDeletedAtMs] as int?,
    );
  }
}
