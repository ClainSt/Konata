import 'package:sqlite3/sqlite3.dart';

import '../../engine/konata_sqlite_engine.dart';
import '../../engine/row_codec.dart';
import '../schema/lyric_user_overrides_schema.dart';

/// 用户歌词覆盖作用域枚举。
enum LyricOverrideScope {
  /// 单曲级覆盖（手选歌词或单曲偏移）。
  track,

  /// 整张 CD 专辑共享偏移覆盖。
  album,
}

/// `lyric_user_overrides` 强类型持久化记录模型。
final class LyricUserOverrideRecord {
  /// 创建用户歌词覆盖记录。
  const LyricUserOverrideRecord({
    required this.overrideKey,
    required this.scope,
    this.trackKey,
    this.albumKey,
    this.lrcContent,
    this.offsetMillis = 0,
    this.userOffsetLocked = false,
    this.userEdited = false,
    this.updatedAtMs = 0,
    this.sourceDeviceId = '',
    this.deletedAtMs,
  });

  /// 覆盖记录主键。
  final String overrideKey;

  /// 单曲或专辑级作用域。
  final LyricOverrideScope scope;

  /// 可选曲目规范键。
  final String? trackKey;

  /// 可选专辑规范键。
  final String? albumKey;

  /// 用户手动编辑或选定的增强 LRC 正文。
  final String? lrcContent;

  /// 时间轴偏移（毫秒）。
  final int offsetMillis;

  /// 偏移是否已锁定。
  final bool userOffsetLocked;

  /// 歌词正文是否由用户手动编辑。
  final bool userEdited;

  /// 最近更新时间（UTC 毫秒）。
  final int updatedAtMs;

  /// 最近修改设备标识。
  final String sourceDeviceId;

  /// 软删除墓碑时间戳（UTC 毫秒）。
  final int? deletedAtMs;

  /// 是否已软删除。
  bool get isDeleted => deletedAtMs != null;
}

/// `lyric_user_overrides` 标准 SQL 响应式 DAO。
final class LyricUserOverrideDao {
  /// 创建用户歌词覆盖 DAO。
  const LyricUserOverrideDao(this._engine);

  final KonataSqliteEngine _engine;

  static const Set<String> _tables = <String>{LyricUserOverridesSchema.table};

  /// 新增或覆盖写入一条用户歌词覆盖记录。
  void upsert(LyricUserOverrideRecord record) {
    _engine.runTransaction((tx) => upsertInTx(tx, record));
  }

  /// 在事务内写入用户歌词覆盖记录。
  void upsertInTx(SqliteTransaction tx, LyricUserOverrideRecord record) {
    tx.execute(
      '''
INSERT INTO ${LyricUserOverridesSchema.table} (
  ${LyricUserOverridesSchema.colOverrideKey},
  ${LyricUserOverridesSchema.colScope},
  ${LyricUserOverridesSchema.colTrackKey},
  ${LyricUserOverridesSchema.colAlbumKey},
  ${LyricUserOverridesSchema.colLrcContent},
  ${LyricUserOverridesSchema.colOffsetMillis},
  ${LyricUserOverridesSchema.colUserOffsetLocked},
  ${LyricUserOverridesSchema.colUserEdited},
  ${LyricUserOverridesSchema.colUpdatedAtMs},
  ${LyricUserOverridesSchema.colSourceDeviceId},
  ${LyricUserOverridesSchema.colDeletedAtMs}
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(${LyricUserOverridesSchema.colOverrideKey}) DO UPDATE SET
  ${LyricUserOverridesSchema.colScope} = excluded.${LyricUserOverridesSchema.colScope},
  ${LyricUserOverridesSchema.colTrackKey} = excluded.${LyricUserOverridesSchema.colTrackKey},
  ${LyricUserOverridesSchema.colAlbumKey} = excluded.${LyricUserOverridesSchema.colAlbumKey},
  ${LyricUserOverridesSchema.colLrcContent} = excluded.${LyricUserOverridesSchema.colLrcContent},
  ${LyricUserOverridesSchema.colOffsetMillis} = excluded.${LyricUserOverridesSchema.colOffsetMillis},
  ${LyricUserOverridesSchema.colUserOffsetLocked} = excluded.${LyricUserOverridesSchema.colUserOffsetLocked},
  ${LyricUserOverridesSchema.colUserEdited} = excluded.${LyricUserOverridesSchema.colUserEdited},
  ${LyricUserOverridesSchema.colUpdatedAtMs} = excluded.${LyricUserOverridesSchema.colUpdatedAtMs},
  ${LyricUserOverridesSchema.colSourceDeviceId} = excluded.${LyricUserOverridesSchema.colSourceDeviceId},
  ${LyricUserOverridesSchema.colDeletedAtMs} = excluded.${LyricUserOverridesSchema.colDeletedAtMs};
''',
      <Object?>[
        record.overrideKey,
        record.scope.name,
        record.trackKey,
        record.albumKey,
        record.lrcContent,
        record.offsetMillis,
        SqliteRowCodec.encodeBool(record.userOffsetLocked),
        SqliteRowCodec.encodeBool(record.userEdited),
        record.updatedAtMs,
        record.sourceDeviceId,
        record.deletedAtMs,
      ],
      _tables,
    );
  }

  /// 按覆盖主键查询有效记录。
  LyricUserOverrideRecord? findByKey(
    String overrideKey, {
    bool includeDeleted = false,
  }) {
    final deletedClause = includeDeleted
        ? ''
        : ' AND ${LyricUserOverridesSchema.colDeletedAtMs} IS NULL';
    final rs = _engine.select(
      'SELECT * FROM ${LyricUserOverridesSchema.table} '
      'WHERE ${LyricUserOverridesSchema.colOverrideKey} = ?$deletedClause LIMIT 1;',
      <Object?>[overrideKey],
    );
    if (rs.isEmpty) return null;
    return _mapRow(rs.first);
  }

  /// 查询全部用户歌词覆盖记录（可含软删除墓碑，供同步切片导出）。
  List<LyricUserOverrideRecord> listAll({bool includeDeleted = false}) {
    return _queryAll(_engine.select, includeDeleted: includeDeleted);
  }

  /// 响应式监听全部有效用户歌词覆盖记录。
  Stream<List<LyricUserOverrideRecord>> watchAll({bool includeDeleted = false}) {
    return _engine.watchQuery<List<LyricUserOverrideRecord>>(
      tables: _tables,
      query: (db) => _queryAll(db.select, includeDeleted: includeDeleted),
    );
  }

  /// 软删除指定歌词覆盖记录。
  void softDelete(
    String overrideKey, {
    required int deletedAtMs,
    String sourceDeviceId = '',
  }) {
    _engine.runTransaction((tx) {
      tx.execute(
        '''
UPDATE ${LyricUserOverridesSchema.table}
SET ${LyricUserOverridesSchema.colDeletedAtMs} = ?,
    ${LyricUserOverridesSchema.colUpdatedAtMs} = ?,
    ${LyricUserOverridesSchema.colSourceDeviceId} = ?
WHERE ${LyricUserOverridesSchema.colOverrideKey} = ?;
''',
        <Object?>[deletedAtMs, deletedAtMs, sourceDeviceId, overrideKey],
        _tables,
      );
    });
  }

  List<LyricUserOverrideRecord> _queryAll(
    ResultSet Function(String, [List<Object?>]) selectFn, {
    required bool includeDeleted,
  }) {
    final whereClause = includeDeleted
        ? ''
        : 'WHERE ${LyricUserOverridesSchema.colDeletedAtMs} IS NULL ';
    final rs = selectFn(
      'SELECT * FROM ${LyricUserOverridesSchema.table} '
      '${whereClause}ORDER BY ${LyricUserOverridesSchema.colUpdatedAtMs} DESC;',
    );
    return <LyricUserOverrideRecord>[for (final row in rs) _mapRow(row)];
  }

  LyricUserOverrideRecord _mapRow(Row row) {
    return LyricUserOverrideRecord(
      overrideKey: row[LyricUserOverridesSchema.colOverrideKey] as String,
      scope: SqliteRowCodec.decodeEnum(
        LyricOverrideScope.values,
        row[LyricUserOverridesSchema.colScope],
        LyricOverrideScope.track,
      ),
      trackKey: row[LyricUserOverridesSchema.colTrackKey] as String?,
      albumKey: row[LyricUserOverridesSchema.colAlbumKey] as String?,
      lrcContent: row[LyricUserOverridesSchema.colLrcContent] as String?,
      offsetMillis: row[LyricUserOverridesSchema.colOffsetMillis] as int? ?? 0,
      userOffsetLocked: SqliteRowCodec.decodeBool(
        row[LyricUserOverridesSchema.colUserOffsetLocked],
      ),
      userEdited: SqliteRowCodec.decodeBool(
        row[LyricUserOverridesSchema.colUserEdited],
      ),
      updatedAtMs: row[LyricUserOverridesSchema.colUpdatedAtMs] as int? ?? 0,
      sourceDeviceId:
          row[LyricUserOverridesSchema.colSourceDeviceId] as String? ?? '',
      deletedAtMs: row[LyricUserOverridesSchema.colDeletedAtMs] as int?,
    );
  }
}
