import 'package:konata_contracts/konata_contracts.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../engine/konata_sqlite_engine.dart';
import '../../engine/row_codec.dart';
import '../schema/playback_records_schema.dart';

/// `playback_records` 强类型持久化记录模型。
final class PlaybackRecordEntity {
  /// 创建播放历史记录。
  const PlaybackRecordEntity({
    required this.id,
    required this.workId,
    required this.episodeId,
    required this.variantId,
    required this.playedAtMs,
    this.canonicalKey,
    this.seasonNumber = 1,
    this.episodeNumber,
    this.episodeTitle = '',
    this.sourceKind = MediaSourceKind.local,
    this.positionSeconds = 0,
    this.durationSeconds = 0,
    this.isCompleted = false,
    this.updatedAtMs = 0,
    this.sourceDeviceId = '',
    this.deletedAtMs,
  });

  /// 播放记录主键。
  final String id;

  /// 跨设备稳定规范键。
  final String? canonicalKey;

  /// 所属作品主键。
  final WorkId workId;

  /// 所属逻辑剧集主键。
  final EpisodeId episodeId;

  /// 物理版本主键。
  final VariantId variantId;

  /// 季号。
  final int seasonNumber;

  /// 集号。
  final int? episodeNumber;

  /// 单集标题快照。
  final String episodeTitle;

  /// 媒体源协议类型。
  final MediaSourceKind sourceKind;

  /// 播放时间戳（UTC 毫秒）。
  final int playedAtMs;

  /// 当前播放进度（秒）。
  final int positionSeconds;

  /// 视频总时长（秒）。
  final int durationSeconds;

  /// 是否已看完。
  final bool isCompleted;

  /// 最近更新时间（UTC 毫秒）。
  final int updatedAtMs;

  /// 最近修改设备标识。
  final String sourceDeviceId;

  /// 软删除墓碑时间戳（UTC 毫秒）。
  final int? deletedAtMs;

  /// 是否已软删除。
  bool get isDeleted => deletedAtMs != null;

  /// 投影为跨包只读续播摘要。
  PlaybackResumeView toResumeView() => PlaybackResumeView(
    workId: workId,
    episodeId: episodeId,
    variantId: variantId,
    positionSeconds: positionSeconds,
    durationSeconds: durationSeconds,
    completed: isCompleted,
    playedAtMs: playedAtMs,
  );
}

/// `playback_records` 标准 SQL 响应式 DAO。
final class PlaybackRecordDao {
  /// 创建播放记录 DAO。
  const PlaybackRecordDao(this._engine);

  final KonataSqliteEngine _engine;

  static const Set<String> _tables = <String>{PlaybackRecordsSchema.table};

  /// 新增或覆盖写入一条播放记录。
  void upsert(PlaybackRecordEntity record) {
    _engine.runTransaction((tx) => upsertInTx(tx, record));
  }

  /// 在事务内写入播放记录。
  void upsertInTx(SqliteTransaction tx, PlaybackRecordEntity record) {
    tx.execute(
      '''
INSERT INTO ${PlaybackRecordsSchema.table} (
  ${PlaybackRecordsSchema.colId},
  ${PlaybackRecordsSchema.colCanonicalKey},
  ${PlaybackRecordsSchema.colWorkId},
  ${PlaybackRecordsSchema.colEpisodeId},
  ${PlaybackRecordsSchema.colVariantId},
  ${PlaybackRecordsSchema.colSeasonNumber},
  ${PlaybackRecordsSchema.colEpisodeNumber},
  ${PlaybackRecordsSchema.colEpisodeTitle},
  ${PlaybackRecordsSchema.colSourceKind},
  ${PlaybackRecordsSchema.colPlayedAtMs},
  ${PlaybackRecordsSchema.colPositionSeconds},
  ${PlaybackRecordsSchema.colDurationSeconds},
  ${PlaybackRecordsSchema.colIsCompleted},
  ${PlaybackRecordsSchema.colUpdatedAtMs},
  ${PlaybackRecordsSchema.colSourceDeviceId},
  ${PlaybackRecordsSchema.colDeletedAtMs}
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(${PlaybackRecordsSchema.colId}) DO UPDATE SET
  ${PlaybackRecordsSchema.colCanonicalKey} = excluded.${PlaybackRecordsSchema.colCanonicalKey},
  ${PlaybackRecordsSchema.colWorkId} = excluded.${PlaybackRecordsSchema.colWorkId},
  ${PlaybackRecordsSchema.colEpisodeId} = excluded.${PlaybackRecordsSchema.colEpisodeId},
  ${PlaybackRecordsSchema.colVariantId} = excluded.${PlaybackRecordsSchema.colVariantId},
  ${PlaybackRecordsSchema.colSeasonNumber} = excluded.${PlaybackRecordsSchema.colSeasonNumber},
  ${PlaybackRecordsSchema.colEpisodeNumber} = excluded.${PlaybackRecordsSchema.colEpisodeNumber},
  ${PlaybackRecordsSchema.colEpisodeTitle} = excluded.${PlaybackRecordsSchema.colEpisodeTitle},
  ${PlaybackRecordsSchema.colSourceKind} = excluded.${PlaybackRecordsSchema.colSourceKind},
  ${PlaybackRecordsSchema.colPlayedAtMs} = excluded.${PlaybackRecordsSchema.colPlayedAtMs},
  ${PlaybackRecordsSchema.colPositionSeconds} = excluded.${PlaybackRecordsSchema.colPositionSeconds},
  ${PlaybackRecordsSchema.colDurationSeconds} = excluded.${PlaybackRecordsSchema.colDurationSeconds},
  ${PlaybackRecordsSchema.colIsCompleted} = excluded.${PlaybackRecordsSchema.colIsCompleted},
  ${PlaybackRecordsSchema.colUpdatedAtMs} = excluded.${PlaybackRecordsSchema.colUpdatedAtMs},
  ${PlaybackRecordsSchema.colSourceDeviceId} = excluded.${PlaybackRecordsSchema.colSourceDeviceId},
  ${PlaybackRecordsSchema.colDeletedAtMs} = excluded.${PlaybackRecordsSchema.colDeletedAtMs};
''',
      <Object?>[
        record.id,
        record.canonicalKey,
        record.workId.value,
        record.episodeId.value,
        record.variantId.value,
        record.seasonNumber,
        record.episodeNumber,
        record.episodeTitle,
        record.sourceKind.name,
        record.playedAtMs,
        record.positionSeconds,
        record.durationSeconds,
        SqliteRowCodec.encodeBool(record.isCompleted),
        record.updatedAtMs,
        record.sourceDeviceId,
        record.deletedAtMs,
      ],
      _tables,
    );
  }

  /// 查询指定作品最近一次有效播放记录。
  PlaybackRecordEntity? findLatestByWork(WorkId workId) {
    final rs = _engine.select(
      'SELECT * FROM ${PlaybackRecordsSchema.table} '
      'WHERE ${PlaybackRecordsSchema.colWorkId} = ? '
      'AND ${PlaybackRecordsSchema.colDeletedAtMs} IS NULL '
      'ORDER BY ${PlaybackRecordsSchema.colPlayedAtMs} DESC LIMIT 1;',
      <Object?>[workId.value],
    );
    if (rs.isEmpty) return null;
    return _mapRow(rs.first);
  }

  /// 查询指定剧集最近一次有效播放记录。
  PlaybackRecordEntity? findLatestByEpisode(EpisodeId episodeId) {
    final rs = _engine.select(
      'SELECT * FROM ${PlaybackRecordsSchema.table} '
      'WHERE ${PlaybackRecordsSchema.colEpisodeId} = ? '
      'AND ${PlaybackRecordsSchema.colDeletedAtMs} IS NULL '
      'ORDER BY ${PlaybackRecordsSchema.colPlayedAtMs} DESC LIMIT 1;',
      <Object?>[episodeId.value],
    );
    if (rs.isEmpty) return null;
    return _mapRow(rs.first);
  }

  /// 按最近播放时间倒序查询播放历史时间轴。
  List<PlaybackRecordEntity> listRecent({
    int limit = 100,
    bool includeDeleted = false,
  }) {
    return _queryRecent(
      _engine.select,
      limit: limit,
      includeDeleted: includeDeleted,
    );
  }

  /// 响应式监听最近播放记录时间轴变化。
  Stream<List<PlaybackRecordEntity>> watchRecent({int limit = 100}) {
    return _engine.watchQuery<List<PlaybackRecordEntity>>(
      tables: _tables,
      query: (db) => _queryRecent(db.select, limit: limit, includeDeleted: false),
    );
  }

  /// 软删除指定播放记录并保留同步墓碑。
  void softDelete(
    String id, {
    required int deletedAtMs,
    String sourceDeviceId = '',
  }) {
    _engine.runTransaction((tx) {
      tx.execute(
        '''
UPDATE ${PlaybackRecordsSchema.table}
SET ${PlaybackRecordsSchema.colDeletedAtMs} = ?,
    ${PlaybackRecordsSchema.colUpdatedAtMs} = ?,
    ${PlaybackRecordsSchema.colSourceDeviceId} = ?
WHERE ${PlaybackRecordsSchema.colId} = ?;
''',
        <Object?>[deletedAtMs, deletedAtMs, sourceDeviceId, id],
        _tables,
      );
    });
  }

  List<PlaybackRecordEntity> _queryRecent(
    ResultSet Function(String, [List<Object?>]) selectFn, {
    required int limit,
    required bool includeDeleted,
  }) {
    final whereClause = includeDeleted
        ? ''
        : 'WHERE ${PlaybackRecordsSchema.colDeletedAtMs} IS NULL ';
    final rs = selectFn(
      'SELECT * FROM ${PlaybackRecordsSchema.table} '
      '${whereClause}ORDER BY ${PlaybackRecordsSchema.colPlayedAtMs} DESC LIMIT ?;',
      <Object?>[limit],
    );
    return <PlaybackRecordEntity>[for (final row in rs) _mapRow(row)];
  }

  PlaybackRecordEntity _mapRow(Row row) {
    return PlaybackRecordEntity(
      id: row[PlaybackRecordsSchema.colId] as String,
      canonicalKey: row[PlaybackRecordsSchema.colCanonicalKey] as String?,
      workId: WorkId.trusted(row[PlaybackRecordsSchema.colWorkId] as String),
      episodeId: EpisodeId.trusted(
        row[PlaybackRecordsSchema.colEpisodeId] as String,
      ),
      variantId: VariantId.trusted(
        row[PlaybackRecordsSchema.colVariantId] as String,
      ),
      seasonNumber: row[PlaybackRecordsSchema.colSeasonNumber] as int? ?? 1,
      episodeNumber: row[PlaybackRecordsSchema.colEpisodeNumber] as int?,
      episodeTitle: row[PlaybackRecordsSchema.colEpisodeTitle] as String? ?? '',
      sourceKind: SqliteRowCodec.decodeEnum(
        MediaSourceKind.values,
        row[PlaybackRecordsSchema.colSourceKind],
        MediaSourceKind.local,
      ),
      playedAtMs: row[PlaybackRecordsSchema.colPlayedAtMs] as int? ?? 0,
      positionSeconds: row[PlaybackRecordsSchema.colPositionSeconds] as int? ?? 0,
      durationSeconds: row[PlaybackRecordsSchema.colDurationSeconds] as int? ?? 0,
      isCompleted: SqliteRowCodec.decodeBool(
        row[PlaybackRecordsSchema.colIsCompleted],
      ),
      updatedAtMs: row[PlaybackRecordsSchema.colUpdatedAtMs] as int? ?? 0,
      sourceDeviceId:
          row[PlaybackRecordsSchema.colSourceDeviceId] as String? ?? '',
      deletedAtMs: row[PlaybackRecordsSchema.colDeletedAtMs] as int?,
    );
  }
}
