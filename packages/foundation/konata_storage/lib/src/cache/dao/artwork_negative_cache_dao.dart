import 'package:konata_contracts/konata_contracts.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../engine/konata_sqlite_engine.dart';
import '../../engine/row_codec.dart';
import '../schema/artwork_negative_cache_schema.dart';

/// `artwork_negative_cache` 强类型记录模型。
final class ArtworkNegativeCacheRecord {
  /// 创建艺术图负缓存记录。
  const ArtworkNegativeCacheRecord({
    required this.workId,
    required this.slot,
    required this.negativeUntilMs,
    required this.probedSourceMask,
    required this.updatedAtMs,
  });

  /// 所属作品主键。
  final WorkId workId;

  /// 艺术图槽位（海报 / 背景 / 透明徽标）。
  final ArtworkSlot slot;

  /// 负缓存冷却截止时间戳（UTC 毫秒）。
  final int negativeUntilMs;

  /// 上次无图探测已覆盖的数据源位掩码。
  final int probedSourceMask;

  /// 最近写入时间（UTC 毫秒）。
  final int updatedAtMs;

  /// 在 [nowMs] 时刻是否仍处于冷却期内。
  bool isCoolingDownAt(int nowMs) => negativeUntilMs > nowMs;
}

/// `artwork_negative_cache` 标准 SQL 响应式 DAO。
final class ArtworkNegativeCacheDao {
  /// 创建艺术图负缓存 DAO。
  const ArtworkNegativeCacheDao(this._engine);

  final KonataSqliteEngine _engine;

  static const Set<String> _tables = <String>{ArtworkNegativeCacheSchema.table};

  /// 写入或刷新指定作品槽位的无图负缓存冷却记录。
  void upsert(ArtworkNegativeCacheRecord record) {
    _engine.runTransaction((tx) {
      tx.execute(
        '''
INSERT INTO ${ArtworkNegativeCacheSchema.table} (
  ${ArtworkNegativeCacheSchema.colWorkId},
  ${ArtworkNegativeCacheSchema.colSlot},
  ${ArtworkNegativeCacheSchema.colNegativeUntilMs},
  ${ArtworkNegativeCacheSchema.colProbedSourceMask},
  ${ArtworkNegativeCacheSchema.colUpdatedAtMs}
) VALUES (?, ?, ?, ?, ?)
ON CONFLICT(
  ${ArtworkNegativeCacheSchema.colWorkId},
  ${ArtworkNegativeCacheSchema.colSlot}
) DO UPDATE SET
  ${ArtworkNegativeCacheSchema.colNegativeUntilMs} = excluded.${ArtworkNegativeCacheSchema.colNegativeUntilMs},
  ${ArtworkNegativeCacheSchema.colProbedSourceMask} = excluded.${ArtworkNegativeCacheSchema.colProbedSourceMask},
  ${ArtworkNegativeCacheSchema.colUpdatedAtMs} = excluded.${ArtworkNegativeCacheSchema.colUpdatedAtMs};
''',
        <Object?>[
          record.workId.value,
          record.slot.name,
          record.negativeUntilMs,
          record.probedSourceMask,
          record.updatedAtMs,
        ],
        _tables,
      );
    });
  }

  /// 查询指定作品与槽位的负缓存记录。
  ArtworkNegativeCacheRecord? find(WorkId workId, ArtworkSlot slot) {
    final rs = _engine.select(
      'SELECT * FROM ${ArtworkNegativeCacheSchema.table} '
      'WHERE ${ArtworkNegativeCacheSchema.colWorkId} = ? '
      'AND ${ArtworkNegativeCacheSchema.colSlot} = ? LIMIT 1;',
      <Object?>[workId.value, slot.name],
    );
    if (rs.isEmpty) return null;
    return _mapRow(rs.first);
  }

  /// 清理全部已过期的负缓存条目，返回删除条数估算后的刷新通知。
  void purgeExpired({required int nowMs}) {
    _engine.runTransaction((tx) {
      tx.execute(
        'DELETE FROM ${ArtworkNegativeCacheSchema.table} '
        'WHERE ${ArtworkNegativeCacheSchema.colNegativeUntilMs} <= ?;',
        <Object?>[nowMs],
        _tables,
      );
    });
  }

  /// 响应式监听指定作品的负缓存条目列表。
  Stream<List<ArtworkNegativeCacheRecord>> watchForWork(WorkId workId) {
    return _engine.watchQuery<List<ArtworkNegativeCacheRecord>>(
      tables: _tables,
      query: (db) {
        final rs = db.select(
          'SELECT * FROM ${ArtworkNegativeCacheSchema.table} '
          'WHERE ${ArtworkNegativeCacheSchema.colWorkId} = ? '
          'ORDER BY ${ArtworkNegativeCacheSchema.colSlot} ASC;',
          <Object?>[workId.value],
        );
        return <ArtworkNegativeCacheRecord>[for (final row in rs) _mapRow(row)];
      },
    );
  }

  ArtworkNegativeCacheRecord _mapRow(Row row) {
    return ArtworkNegativeCacheRecord(
      workId: WorkId.trusted(
        row[ArtworkNegativeCacheSchema.colWorkId] as String,
      ),
      slot: SqliteRowCodec.decodeEnum(
        ArtworkSlot.values,
        row[ArtworkNegativeCacheSchema.colSlot],
        ArtworkSlot.logo,
      ),
      negativeUntilMs:
          row[ArtworkNegativeCacheSchema.colNegativeUntilMs] as int? ?? 0,
      probedSourceMask:
          row[ArtworkNegativeCacheSchema.colProbedSourceMask] as int? ?? 0,
      updatedAtMs: row[ArtworkNegativeCacheSchema.colUpdatedAtMs] as int? ?? 0,
    );
  }
}
