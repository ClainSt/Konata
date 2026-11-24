import 'package:sqlite3/sqlite3.dart';

import '../../engine/konata_sqlite_engine.dart';
import '../schema/sync_meta_schema.dart';

/// `sync_meta` 非敏感同步元信息记录模型。
final class SyncMetaEntry {
  /// 创建同步元信息记录。
  const SyncMetaEntry({
    required this.key,
    required this.value,
    required this.updatedAtMs,
  });

  /// 元信息键名。
  final String key;

  /// 元信息值文本。
  final String value;

  /// 最近更新时间（UTC 毫秒）。
  final int updatedAtMs;
}

/// `sync_meta` 标准 SQL 响应式 DAO。
final class SyncMetaDao {
  /// 创建同步元信息 DAO。
  const SyncMetaDao(this._engine);

  final KonataSqliteEngine _engine;

  static const Set<String> _tables = <String>{SyncMetaSchema.table};

  /// 写入或覆盖一条同步元信息。
  void put(String key, String value, {required int updatedAtMs}) {
    _engine.runTransaction((tx) {
      tx.execute(
        '''
INSERT INTO ${SyncMetaSchema.table} (
  ${SyncMetaSchema.colMetaKey},
  ${SyncMetaSchema.colMetaValue},
  ${SyncMetaSchema.colUpdatedAtMs}
) VALUES (?, ?, ?)
ON CONFLICT(${SyncMetaSchema.colMetaKey}) DO UPDATE SET
  ${SyncMetaSchema.colMetaValue} = excluded.${SyncMetaSchema.colMetaValue},
  ${SyncMetaSchema.colUpdatedAtMs} = excluded.${SyncMetaSchema.colUpdatedAtMs};
''',
        <Object?>[key, value, updatedAtMs],
        _tables,
      );
    });
  }

  /// 按键查询单条元信息。
  SyncMetaEntry? get(String key) {
    final rs = _engine.select(
      'SELECT * FROM ${SyncMetaSchema.table} '
      'WHERE ${SyncMetaSchema.colMetaKey} = ? LIMIT 1;',
      <Object?>[key],
    );
    if (rs.isEmpty) return null;
    return _mapRow(rs.first);
  }

  /// 读取全部同步元信息映射。
  Map<String, String> readAllMap() {
    final rs = _engine.select(
      'SELECT * FROM ${SyncMetaSchema.table} '
      'ORDER BY ${SyncMetaSchema.colMetaKey} ASC;',
    );
    return <String, String>{
      for (final row in rs)
        row[SyncMetaSchema.colMetaKey] as String:
            row[SyncMetaSchema.colMetaValue] as String,
    };
  }

  /// 响应式监听指定元信息键变更。
  Stream<String?> watchValue(String key) {
    return _engine.watchQuery<String?>(
      tables: _tables,
      query: (db) {
        final rs = db.select(
          'SELECT ${SyncMetaSchema.colMetaValue} FROM ${SyncMetaSchema.table} '
          'WHERE ${SyncMetaSchema.colMetaKey} = ? LIMIT 1;',
          <Object?>[key],
        );
        if (rs.isEmpty) return null;
        return rs.first[SyncMetaSchema.colMetaValue] as String?;
      },
    );
  }

  /// 删除指定同步元信息键。
  void delete(String key) {
    _engine.runTransaction((tx) {
      tx.execute(
        'DELETE FROM ${SyncMetaSchema.table} WHERE ${SyncMetaSchema.colMetaKey} = ?;',
        <Object?>[key],
        _tables,
      );
    });
  }

  SyncMetaEntry _mapRow(Row row) {
    return SyncMetaEntry(
      key: row[SyncMetaSchema.colMetaKey] as String,
      value: row[SyncMetaSchema.colMetaValue] as String,
      updatedAtMs: row[SyncMetaSchema.colUpdatedAtMs] as int? ?? 0,
    );
  }
}
