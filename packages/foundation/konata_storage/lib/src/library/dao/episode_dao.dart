import 'package:konata_contracts/konata_contracts.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../engine/konata_sqlite_engine.dart';
import '../../engine/row_codec.dart';
import '../schema/episodes_schema.dart';

/// `episodes` 强类型持久化记录模型。
final class EpisodeRecord {
  /// 创建逻辑剧集记录。
  const EpisodeRecord({
    required this.id,
    required this.workId,
    required this.seasonNumber,
    this.canonicalKey,
    this.episodeNumber,
    this.episodeNumberEnd,
    this.category = EpisodeCategory.main,
    this.extraType,
    this.title,
    this.overview,
    this.stillPath,
    this.updatedAtMs = 0,
    this.sourceDeviceId = '',
    this.deletedAtMs,
  });

  /// 逻辑剧集主键。
  final EpisodeId id;

  /// 跨设备稳定规范键。
  final String? canonicalKey;

  /// 所属作品主键。
  final WorkId workId;

  /// 季号。
  final int seasonNumber;

  /// 集号或区间起始集号。
  final int? episodeNumber;

  /// 多集合并区间结束集号。
  final int? episodeNumberEnd;

  /// 正片或特典分类。
  final EpisodeCategory category;

  /// 特典细分类型。
  final ExtraKind? extraType;

  /// 单集标题。
  final String? title;

  /// 单集简介。
  final String? overview;

  /// 单集剧照路径。
  final String? stillPath;

  /// 最近更新时间（UTC 毫秒）。
  final int updatedAtMs;

  /// 最近修改设备标识。
  final String sourceDeviceId;

  /// 软删除墓碑时间戳（UTC 毫秒）。
  final int? deletedAtMs;

  /// 是否已软删除。
  bool get isDeleted => deletedAtMs != null;

  /// 投影为跨包只读视图。
  EpisodeSummaryView toSummaryView() => EpisodeSummaryView(
    id: id,
    workId: workId,
    seasonNumber: seasonNumber,
    category: category,
    episodeNumber: episodeNumber,
    episodeNumberEnd: episodeNumberEnd,
    extraType: extraType,
    title: title,
  );
}

/// `episodes` 标准 SQL 响应式 DAO。
final class EpisodeDao {
  /// 创建逻辑剧集 DAO。
  const EpisodeDao(this._engine);

  final KonataSqliteEngine _engine;

  static const Set<String> _tables = <String>{EpisodesSchema.table};

  /// 新增或覆盖写入一条逻辑剧集记录。
  void upsert(EpisodeRecord record) {
    _engine.runTransaction((tx) => upsertInTx(tx, record));
  }

  /// 在事务内写入一条逻辑剧集记录。
  void upsertInTx(SqliteTransaction tx, EpisodeRecord record) {
    tx.execute(
      '''
INSERT INTO ${EpisodesSchema.table} (
  ${EpisodesSchema.colId},
  ${EpisodesSchema.colCanonicalKey},
  ${EpisodesSchema.colWorkId},
  ${EpisodesSchema.colSeasonNumber},
  ${EpisodesSchema.colEpisodeNumber},
  ${EpisodesSchema.colEpisodeNumberEnd},
  ${EpisodesSchema.colCategory},
  ${EpisodesSchema.colExtraType},
  ${EpisodesSchema.colTitle},
  ${EpisodesSchema.colOverview},
  ${EpisodesSchema.colStillPath},
  ${EpisodesSchema.colUpdatedAtMs},
  ${EpisodesSchema.colSourceDeviceId},
  ${EpisodesSchema.colDeletedAtMs}
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(${EpisodesSchema.colId}) DO UPDATE SET
  ${EpisodesSchema.colCanonicalKey} = excluded.${EpisodesSchema.colCanonicalKey},
  ${EpisodesSchema.colWorkId} = excluded.${EpisodesSchema.colWorkId},
  ${EpisodesSchema.colSeasonNumber} = excluded.${EpisodesSchema.colSeasonNumber},
  ${EpisodesSchema.colEpisodeNumber} = excluded.${EpisodesSchema.colEpisodeNumber},
  ${EpisodesSchema.colEpisodeNumberEnd} = excluded.${EpisodesSchema.colEpisodeNumberEnd},
  ${EpisodesSchema.colCategory} = excluded.${EpisodesSchema.colCategory},
  ${EpisodesSchema.colExtraType} = excluded.${EpisodesSchema.colExtraType},
  ${EpisodesSchema.colTitle} = excluded.${EpisodesSchema.colTitle},
  ${EpisodesSchema.colOverview} = excluded.${EpisodesSchema.colOverview},
  ${EpisodesSchema.colStillPath} = excluded.${EpisodesSchema.colStillPath},
  ${EpisodesSchema.colUpdatedAtMs} = excluded.${EpisodesSchema.colUpdatedAtMs},
  ${EpisodesSchema.colSourceDeviceId} = excluded.${EpisodesSchema.colSourceDeviceId},
  ${EpisodesSchema.colDeletedAtMs} = excluded.${EpisodesSchema.colDeletedAtMs};
''',
      <Object?>[
        record.id.value,
        record.canonicalKey,
        record.workId.value,
        record.seasonNumber,
        record.episodeNumber,
        record.episodeNumberEnd,
        record.category.name,
        record.extraType?.name,
        record.title,
        record.overview,
        record.stillPath,
        record.updatedAtMs,
        record.sourceDeviceId,
        record.deletedAtMs,
      ],
      _tables,
    );
  }

  /// 按主键查询单条逻辑剧集记录。
  EpisodeRecord? findById(EpisodeId id, {bool includeDeleted = false}) {
    final deletedClause = includeDeleted
        ? ''
        : ' AND ${EpisodesSchema.colDeletedAtMs} IS NULL';
    final rs = _engine.select(
      'SELECT * FROM ${EpisodesSchema.table} '
      'WHERE ${EpisodesSchema.colId} = ?$deletedClause LIMIT 1;',
      <Object?>[id.value],
    );
    if (rs.isEmpty) return null;
    return _mapRow(rs.first);
  }

  /// 批量读取全部剧集，供完整目录快照使用；可包含软删除墓碑。
  List<EpisodeRecord> listAll({bool includeDeleted = false}) {
    final where = includeDeleted
        ? ''
        : ' WHERE ${EpisodesSchema.colDeletedAtMs} IS NULL';
    final rows = _engine.select('SELECT * FROM ${EpisodesSchema.table}$where;');
    return [for (final row in rows) _mapRow(row)];
  }

  /// 查询指定作品下的有效剧集列表。
  List<EpisodeRecord> listByWork(WorkId workId, {bool includeDeleted = false}) {
    return _queryByWork(_engine.select, workId, includeDeleted: includeDeleted);
  }

  /// 响应式监听指定作品的剧集列表变更。
  Stream<List<EpisodeRecord>> watchByWork(
    WorkId workId, {
    bool includeDeleted = false,
  }) {
    return _engine.watchQuery<List<EpisodeRecord>>(
      tables: _tables,
      query: (db) =>
          _queryByWork(db.select, workId, includeDeleted: includeDeleted),
    );
  }

  /// 软删除单条剧集记录。
  void softDelete(
    EpisodeId id, {
    required int deletedAtMs,
    String sourceDeviceId = '',
  }) {
    _engine.runTransaction((tx) {
      tx.execute(
        '''
UPDATE ${EpisodesSchema.table}
SET ${EpisodesSchema.colDeletedAtMs} = ?,
    ${EpisodesSchema.colUpdatedAtMs} = ?,
    ${EpisodesSchema.colSourceDeviceId} = ?
WHERE ${EpisodesSchema.colId} = ?;
''',
        <Object?>[deletedAtMs, deletedAtMs, sourceDeviceId, id.value],
        _tables,
      );
    });
  }

  List<EpisodeRecord> _queryByWork(
    ResultSet Function(String, [List<Object?>]) selectFn,
    WorkId workId, {
    required bool includeDeleted,
  }) {
    final deletedClause = includeDeleted
        ? ''
        : ' AND ${EpisodesSchema.colDeletedAtMs} IS NULL';
    final rs = selectFn(
      'SELECT * FROM ${EpisodesSchema.table} '
      'WHERE ${EpisodesSchema.colWorkId} = ?$deletedClause '
      'ORDER BY ${EpisodesSchema.colSeasonNumber} ASC, '
      '${EpisodesSchema.colEpisodeNumber} ASC, ${EpisodesSchema.colId} ASC;',
      <Object?>[workId.value],
    );
    return <EpisodeRecord>[for (final row in rs) _mapRow(row)];
  }

  EpisodeRecord _mapRow(Row row) {
    return EpisodeRecord(
      id: EpisodeId.trusted(row[EpisodesSchema.colId] as String),
      canonicalKey: row[EpisodesSchema.colCanonicalKey] as String?,
      workId: WorkId.trusted(row[EpisodesSchema.colWorkId] as String),
      seasonNumber: row[EpisodesSchema.colSeasonNumber] as int,
      episodeNumber: row[EpisodesSchema.colEpisodeNumber] as int?,
      episodeNumberEnd: row[EpisodesSchema.colEpisodeNumberEnd] as int?,
      category: SqliteRowCodec.decodeEnum(
        EpisodeCategory.values,
        row[EpisodesSchema.colCategory],
        EpisodeCategory.main,
      ),
      extraType: SqliteRowCodec.decodeNullableEnum(
        ExtraKind.values,
        row[EpisodesSchema.colExtraType],
      ),
      title: row[EpisodesSchema.colTitle] as String?,
      overview: row[EpisodesSchema.colOverview] as String?,
      stillPath: row[EpisodesSchema.colStillPath] as String?,
      updatedAtMs: row[EpisodesSchema.colUpdatedAtMs] as int? ?? 0,
      sourceDeviceId: row[EpisodesSchema.colSourceDeviceId] as String? ?? '',
      deletedAtMs: row[EpisodesSchema.colDeletedAtMs] as int?,
    );
  }
}
