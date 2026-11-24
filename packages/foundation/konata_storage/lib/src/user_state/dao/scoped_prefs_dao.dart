import 'package:konata_contracts/konata_contracts.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../engine/konata_sqlite_engine.dart';
import '../../engine/row_codec.dart';
import '../schema/scoped_prefs_schema.dart';

/// `scoped_prefs` 原始持久化记录模型。
final class ScopedPrefRecord {
  /// 创建配置切片持久化记录。
  const ScopedPrefRecord({
    required this.namespace,
    required this.schemaVersion,
    required this.syncPolicy,
    required this.payloadJson,
    required this.updatedAtMs,
    this.sourceDeviceId = '',
  });

  /// 配置命名空间唯一标识。
  final String namespace;

  /// 配置切片模式版本号。
  final int schemaVersion;

  /// 跨设备同步策略（`portable` / `deviceLocal`）。
  final SyncPolicy syncPolicy;

  /// JSON 编码后的配置载荷。
  final String payloadJson;

  /// 最近更新时间（UTC 毫秒）。
  final int updatedAtMs;

  /// 最近修改设备标识。
  final String sourceDeviceId;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ScopedPrefRecord &&
          namespace == other.namespace &&
          schemaVersion == other.schemaVersion &&
          syncPolicy == other.syncPolicy &&
          payloadJson == other.payloadJson &&
          updatedAtMs == other.updatedAtMs &&
          sourceDeviceId == other.sourceDeviceId;

  @override
  int get hashCode => Object.hash(
    namespace,
    schemaVersion,
    syncPolicy,
    payloadJson,
    updatedAtMs,
    sourceDeviceId,
  );
}

/// `scoped_prefs` 标准 SQL 响应式 DAO。
final class ScopedPrefsDao {
  /// 创建分命名空间配置 DAO。
  const ScopedPrefsDao(this._engine);

  final KonataSqliteEngine _engine;

  static const Set<String> _tables = <String>{ScopedPrefsSchema.table};

  /// 新增或覆盖写入一条配置切片记录。
  void upsert(ScopedPrefRecord record) {
    _engine.runTransaction((tx) => upsertInTx(tx, record));
  }

  /// 在事务内写入配置切片记录。
  void upsertInTx(SqliteTransaction tx, ScopedPrefRecord record) {
    tx.execute(
      '''
INSERT INTO ${ScopedPrefsSchema.table} (
  ${ScopedPrefsSchema.colNamespace},
  ${ScopedPrefsSchema.colSchemaVer},
  ${ScopedPrefsSchema.colSyncPolicy},
  ${ScopedPrefsSchema.colPayloadJson},
  ${ScopedPrefsSchema.colUpdatedAtMs},
  ${ScopedPrefsSchema.colSourceDeviceId}
) VALUES (?, ?, ?, ?, ?, ?)
ON CONFLICT(${ScopedPrefsSchema.colNamespace}) DO UPDATE SET
  ${ScopedPrefsSchema.colSchemaVer} = excluded.${ScopedPrefsSchema.colSchemaVer},
  ${ScopedPrefsSchema.colSyncPolicy} = excluded.${ScopedPrefsSchema.colSyncPolicy},
  ${ScopedPrefsSchema.colPayloadJson} = excluded.${ScopedPrefsSchema.colPayloadJson},
  ${ScopedPrefsSchema.colUpdatedAtMs} = excluded.${ScopedPrefsSchema.colUpdatedAtMs},
  ${ScopedPrefsSchema.colSourceDeviceId} = excluded.${ScopedPrefsSchema.colSourceDeviceId};
''',
      <Object?>[
        record.namespace,
        record.schemaVersion,
        record.syncPolicy.name,
        record.payloadJson,
        record.updatedAtMs,
        record.sourceDeviceId,
      ],
      _tables,
    );
  }

  /// 按命名空间查询单条配置记录。
  ScopedPrefRecord? findByNamespace(String namespace) {
    final rs = _engine.select(
      'SELECT * FROM ${ScopedPrefsSchema.table} '
      'WHERE ${ScopedPrefsSchema.colNamespace} = ? LIMIT 1;',
      <Object?>[namespace],
    );
    if (rs.isEmpty) return null;
    return _mapRow(rs.first);
  }

  /// 按同步策略筛选配置记录（如仅导出 `SyncPolicy.portable`）。
  List<ScopedPrefRecord> listByPolicy(SyncPolicy policy) {
    final rs = _engine.select(
      'SELECT * FROM ${ScopedPrefsSchema.table} '
      'WHERE ${ScopedPrefsSchema.colSyncPolicy} = ? '
      'ORDER BY ${ScopedPrefsSchema.colNamespace} ASC;',
      <Object?>[policy.name],
    );
    return <ScopedPrefRecord>[for (final row in rs) _mapRow(row)];
  }

  /// 列出全部配置切片记录。
  List<ScopedPrefRecord> listAll() {
    final rs = _engine.select(
      'SELECT * FROM ${ScopedPrefsSchema.table} '
      'ORDER BY ${ScopedPrefsSchema.colNamespace} ASC;',
    );
    return <ScopedPrefRecord>[for (final row in rs) _mapRow(row)];
  }

  /// 响应式监听指定命名空间的配置记录变更（自动过滤无关命名空间写入导致的重复快照）。
  Stream<ScopedPrefRecord?> watchNamespace(String namespace) {
    return _engine
        .watchQuery<ScopedPrefRecord?>(
          tables: _tables,
          query: (db) {
            final rs = db.select(
              'SELECT * FROM ${ScopedPrefsSchema.table} '
              'WHERE ${ScopedPrefsSchema.colNamespace} = ? LIMIT 1;',
              <Object?>[namespace],
            );
            if (rs.isEmpty) return null;
            return _mapRow(rs.first);
          },
        )
        .distinct();
  }

  /// 删除指定命名空间的配置记录。
  void delete(String namespace) {
    _engine.runTransaction((tx) {
      tx.execute(
        'DELETE FROM ${ScopedPrefsSchema.table} '
        'WHERE ${ScopedPrefsSchema.colNamespace} = ?;',
        <Object?>[namespace],
        _tables,
      );
    });
  }

  ScopedPrefRecord _mapRow(Row row) {
    return ScopedPrefRecord(
      namespace: row[ScopedPrefsSchema.colNamespace] as String,
      schemaVersion: row[ScopedPrefsSchema.colSchemaVer] as int? ?? 1,
      syncPolicy: SqliteRowCodec.decodeEnum(
        SyncPolicy.values,
        row[ScopedPrefsSchema.colSyncPolicy],
        SyncPolicy.deviceLocal,
      ),
      payloadJson: row[ScopedPrefsSchema.colPayloadJson] as String? ?? '{}',
      updatedAtMs: row[ScopedPrefsSchema.colUpdatedAtMs] as int? ?? 0,
      sourceDeviceId: row[ScopedPrefsSchema.colSourceDeviceId] as String? ?? '',
    );
  }
}
