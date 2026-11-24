import 'package:konata_contracts/konata_contracts.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../engine/konata_sqlite_engine.dart';
import '../../engine/row_codec.dart';
import '../schema/media_variants_schema.dart';

/// `media_variants` 强类型持久化记录模型。
final class MediaVariantRecord {
  /// 创建物理版本记录。
  const MediaVariantRecord({
    required this.id,
    required this.workId,
    required this.sourceId,
    required this.relativePath,
    required this.fileName,
    required this.fileSize,
    this.canonicalKey,
    this.episodeId,
    this.assetKind = AssetKind.video,
    this.releaseGroup,
    this.subtitleGroup,
    this.videoCodec,
    this.bitDepth,
    this.resolution,
    this.audioCodec,
    this.externalSubtitles = const <String>[],
    this.mappingLocked = false,
    this.workLocked = false,
    this.assetScope = SupplementaryAssetScope.workExclusive,
    this.scopeLocked = false,
    this.updatedAtMs = 0,
    this.sourceDeviceId = '',
    this.deletedAtMs,
  });

  /// 物理版本主键。
  final VariantId id;

  /// 跨设备稳定规范键。
  final String? canonicalKey;

  /// 所属作品主键。
  final WorkId workId;

  /// 关联逻辑剧集主键。
  final EpisodeId? episodeId;

  /// 所属媒体源主键。
  final SourceId sourceId;

  /// 相对媒体源根目录的路径。
  final String relativePath;

  /// 文件名。
  final String fileName;

  /// 文件字节大小。
  final int fileSize;

  /// 资产分类。
  final AssetKind assetKind;

  /// 压制组名称。
  final String? releaseGroup;

  /// 字幕组名称。
  final String? subtitleGroup;

  /// 视频编码。
  final String? videoCodec;

  /// 色深。
  final String? bitDepth;

  /// 分辨率。
  final String? resolution;

  /// 音频编码。
  final String? audioCodec;

  /// 外挂字幕相对路径列表。
  final List<String> externalSubtitles;

  /// 剧集槽位映射人工锁。
  final bool mappingLocked;

  /// 作品归属人工锁。
  final bool workLocked;

  /// 附属资源在系列内的可见作用域。
  final SupplementaryAssetScope assetScope;

  /// 作用域人工锁。
  final bool scopeLocked;

  /// 最近更新时间（UTC 毫秒）。
  final int updatedAtMs;

  /// 最近修改设备标识。
  final String sourceDeviceId;

  /// 软删除墓碑时间戳（UTC 毫秒）。
  final int? deletedAtMs;

  /// 是否已软删除。
  bool get isDeleted => deletedAtMs != null;
}

/// `media_variants` 标准 SQL 响应式 DAO。
final class MediaVariantDao {
  /// 创建物理版本 DAO。
  const MediaVariantDao(this._engine);

  final KonataSqliteEngine _engine;

  static const Set<String> _tables = <String>{MediaVariantsSchema.table};

  /// 新增或覆盖写入一条物理版本记录。
  void upsert(MediaVariantRecord record) {
    _engine.runTransaction((tx) => upsertInTx(tx, record));
  }

  /// 在事务内写入一条物理版本记录。
  void upsertInTx(SqliteTransaction tx, MediaVariantRecord record) {
    tx.execute(
      '''
INSERT INTO ${MediaVariantsSchema.table} (
  ${MediaVariantsSchema.colId},
  ${MediaVariantsSchema.colCanonicalKey},
  ${MediaVariantsSchema.colWorkId},
  ${MediaVariantsSchema.colEpisodeId},
  ${MediaVariantsSchema.colSourceId},
  ${MediaVariantsSchema.colRelativePath},
  ${MediaVariantsSchema.colFileName},
  ${MediaVariantsSchema.colFileSize},
  ${MediaVariantsSchema.colAssetKind},
  ${MediaVariantsSchema.colReleaseGroup},
  ${MediaVariantsSchema.colSubtitleGroup},
  ${MediaVariantsSchema.colVideoCodec},
  ${MediaVariantsSchema.colBitDepth},
  ${MediaVariantsSchema.colResolution},
  ${MediaVariantsSchema.colAudioCodec},
  ${MediaVariantsSchema.colExternalSubtitlesJson},
  ${MediaVariantsSchema.colMappingLocked},
  ${MediaVariantsSchema.colWorkLocked},
  ${MediaVariantsSchema.colAssetScope},
  ${MediaVariantsSchema.colScopeLocked},
  ${MediaVariantsSchema.colUpdatedAtMs},
  ${MediaVariantsSchema.colSourceDeviceId},
  ${MediaVariantsSchema.colDeletedAtMs}
) VALUES (
  ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?
)
ON CONFLICT(${MediaVariantsSchema.colId}) DO UPDATE SET
  ${MediaVariantsSchema.colCanonicalKey} = excluded.${MediaVariantsSchema.colCanonicalKey},
  ${MediaVariantsSchema.colWorkId} = excluded.${MediaVariantsSchema.colWorkId},
  ${MediaVariantsSchema.colEpisodeId} = excluded.${MediaVariantsSchema.colEpisodeId},
  ${MediaVariantsSchema.colSourceId} = excluded.${MediaVariantsSchema.colSourceId},
  ${MediaVariantsSchema.colRelativePath} = excluded.${MediaVariantsSchema.colRelativePath},
  ${MediaVariantsSchema.colFileName} = excluded.${MediaVariantsSchema.colFileName},
  ${MediaVariantsSchema.colFileSize} = excluded.${MediaVariantsSchema.colFileSize},
  ${MediaVariantsSchema.colAssetKind} = excluded.${MediaVariantsSchema.colAssetKind},
  ${MediaVariantsSchema.colReleaseGroup} = excluded.${MediaVariantsSchema.colReleaseGroup},
  ${MediaVariantsSchema.colSubtitleGroup} = excluded.${MediaVariantsSchema.colSubtitleGroup},
  ${MediaVariantsSchema.colVideoCodec} = excluded.${MediaVariantsSchema.colVideoCodec},
  ${MediaVariantsSchema.colBitDepth} = excluded.${MediaVariantsSchema.colBitDepth},
  ${MediaVariantsSchema.colResolution} = excluded.${MediaVariantsSchema.colResolution},
  ${MediaVariantsSchema.colAudioCodec} = excluded.${MediaVariantsSchema.colAudioCodec},
  ${MediaVariantsSchema.colExternalSubtitlesJson} = excluded.${MediaVariantsSchema.colExternalSubtitlesJson},
  ${MediaVariantsSchema.colMappingLocked} = excluded.${MediaVariantsSchema.colMappingLocked},
  ${MediaVariantsSchema.colWorkLocked} = excluded.${MediaVariantsSchema.colWorkLocked},
  ${MediaVariantsSchema.colAssetScope} = excluded.${MediaVariantsSchema.colAssetScope},
  ${MediaVariantsSchema.colScopeLocked} = excluded.${MediaVariantsSchema.colScopeLocked},
  ${MediaVariantsSchema.colUpdatedAtMs} = excluded.${MediaVariantsSchema.colUpdatedAtMs},
  ${MediaVariantsSchema.colSourceDeviceId} = excluded.${MediaVariantsSchema.colSourceDeviceId},
  ${MediaVariantsSchema.colDeletedAtMs} = excluded.${MediaVariantsSchema.colDeletedAtMs};
''',
      <Object?>[
        record.id.value,
        record.canonicalKey,
        record.workId.value,
        record.episodeId?.value,
        record.sourceId.value,
        record.relativePath,
        record.fileName,
        record.fileSize,
        record.assetKind.name,
        record.releaseGroup,
        record.subtitleGroup,
        record.videoCodec,
        record.bitDepth,
        record.resolution,
        record.audioCodec,
        SqliteRowCodec.encodeStringList(record.externalSubtitles),
        SqliteRowCodec.encodeBool(record.mappingLocked),
        SqliteRowCodec.encodeBool(record.workLocked),
        record.assetScope.name,
        SqliteRowCodec.encodeBool(record.scopeLocked),
        record.updatedAtMs,
        record.sourceDeviceId,
        record.deletedAtMs,
      ],
      _tables,
    );
  }

  /// 按主键查询单条物理版本记录。
  MediaVariantRecord? findById(VariantId id, {bool includeDeleted = false}) {
    final deletedClause = includeDeleted
        ? ''
        : ' AND ${MediaVariantsSchema.colDeletedAtMs} IS NULL';
    final rs = _engine.select(
      'SELECT * FROM ${MediaVariantsSchema.table} '
      'WHERE ${MediaVariantsSchema.colId} = ?$deletedClause LIMIT 1;',
      <Object?>[id.value],
    );
    if (rs.isEmpty) return null;
    return _mapRow(rs.first);
  }

  /// 查询指定媒体源下的全部物理版本记录。
  List<MediaVariantRecord> listBySource(
    SourceId sourceId, {
    bool includeDeleted = false,
  }) {
    final deletedClause = includeDeleted
        ? ''
        : ' AND ${MediaVariantsSchema.colDeletedAtMs} IS NULL';
    final rs = _engine.select(
      'SELECT * FROM ${MediaVariantsSchema.table} '
      'WHERE ${MediaVariantsSchema.colSourceId} = ?$deletedClause '
      'ORDER BY ${MediaVariantsSchema.colRelativePath} ASC, ${MediaVariantsSchema.colId} ASC;',
      <Object?>[sourceId.value],
    );
    return <MediaVariantRecord>[for (final row in rs) _mapRow(row)];
  }

  /// 查询全库全部有效物理版本记录。
  List<MediaVariantRecord> listAll({bool includeDeleted = false}) {
    final whereClause = includeDeleted
        ? ''
        : 'WHERE ${MediaVariantsSchema.colDeletedAtMs} IS NULL ';
    final rs = _engine.select(
      'SELECT * FROM ${MediaVariantsSchema.table} '
      '${whereClause}ORDER BY ${MediaVariantsSchema.colWorkId} ASC, '
      '${MediaVariantsSchema.colRelativePath} ASC;',
    );
    return <MediaVariantRecord>[for (final row in rs) _mapRow(row)];
  }

  /// 查询指定作品的全部物理版本记录。
  List<MediaVariantRecord> listByWork(
    WorkId workId, {
    bool includeDeleted = false,
  }) {
    return _queryByWork(_engine.select, workId, includeDeleted: includeDeleted);
  }

  /// 响应式监听指定作品的物理版本列表变化。
  Stream<List<MediaVariantRecord>> watchByWork(
    WorkId workId, {
    bool includeDeleted = false,
  }) {
    return _engine.watchQuery<List<MediaVariantRecord>>(
      tables: _tables,
      query: (db) =>
          _queryByWork(db.select, workId, includeDeleted: includeDeleted),
    );
  }

  /// 软删除物理版本记录（绝不触碰用户物理媒体文件）。
  void softDelete(
    VariantId id, {
    required int deletedAtMs,
    String sourceDeviceId = '',
  }) {
    _engine.runTransaction((tx) {
      tx.execute(
        '''
UPDATE ${MediaVariantsSchema.table}
SET ${MediaVariantsSchema.colDeletedAtMs} = ?,
    ${MediaVariantsSchema.colUpdatedAtMs} = ?,
    ${MediaVariantsSchema.colSourceDeviceId} = ?
WHERE ${MediaVariantsSchema.colId} = ?;
''',
        <Object?>[deletedAtMs, deletedAtMs, sourceDeviceId, id.value],
        _tables,
      );
    });
  }

  List<MediaVariantRecord> _queryByWork(
    ResultSet Function(String, [List<Object?>]) selectFn,
    WorkId workId, {
    required bool includeDeleted,
  }) {
    final deletedClause = includeDeleted
        ? ''
        : ' AND ${MediaVariantsSchema.colDeletedAtMs} IS NULL';
    final rs = selectFn(
      'SELECT * FROM ${MediaVariantsSchema.table} '
      'WHERE ${MediaVariantsSchema.colWorkId} = ?$deletedClause '
      'ORDER BY ${MediaVariantsSchema.colRelativePath} ASC, ${MediaVariantsSchema.colId} ASC;',
      <Object?>[workId.value],
    );
    return <MediaVariantRecord>[for (final row in rs) _mapRow(row)];
  }

  MediaVariantRecord _mapRow(Row row) {
    final rawEpId = row[MediaVariantsSchema.colEpisodeId] as String?;
    return MediaVariantRecord(
      id: VariantId.trusted(row[MediaVariantsSchema.colId] as String),
      canonicalKey: row[MediaVariantsSchema.colCanonicalKey] as String?,
      workId: WorkId.trusted(row[MediaVariantsSchema.colWorkId] as String),
      episodeId: rawEpId == null || rawEpId.isEmpty
          ? null
          : EpisodeId.trusted(rawEpId),
      sourceId: SourceId.trusted(row[MediaVariantsSchema.colSourceId] as String),
      relativePath: row[MediaVariantsSchema.colRelativePath] as String,
      fileName: row[MediaVariantsSchema.colFileName] as String,
      fileSize: row[MediaVariantsSchema.colFileSize] as int? ?? 0,
      assetKind: SqliteRowCodec.decodeEnum(
        AssetKind.values,
        row[MediaVariantsSchema.colAssetKind],
        AssetKind.video,
      ),
      releaseGroup: row[MediaVariantsSchema.colReleaseGroup] as String?,
      subtitleGroup: row[MediaVariantsSchema.colSubtitleGroup] as String?,
      videoCodec: row[MediaVariantsSchema.colVideoCodec] as String?,
      bitDepth: row[MediaVariantsSchema.colBitDepth] as String?,
      resolution: row[MediaVariantsSchema.colResolution] as String?,
      audioCodec: row[MediaVariantsSchema.colAudioCodec] as String?,
      externalSubtitles: SqliteRowCodec.decodeStringList(
        row[MediaVariantsSchema.colExternalSubtitlesJson],
      ),
      mappingLocked: SqliteRowCodec.decodeBool(
        row[MediaVariantsSchema.colMappingLocked],
      ),
      workLocked: SqliteRowCodec.decodeBool(
        row[MediaVariantsSchema.colWorkLocked],
      ),
      assetScope: SqliteRowCodec.decodeEnum(
        SupplementaryAssetScope.values,
        row[MediaVariantsSchema.colAssetScope],
        SupplementaryAssetScope.workExclusive,
      ),
      scopeLocked: SqliteRowCodec.decodeBool(
        row[MediaVariantsSchema.colScopeLocked],
      ),
      updatedAtMs: row[MediaVariantsSchema.colUpdatedAtMs] as int? ?? 0,
      sourceDeviceId: row[MediaVariantsSchema.colSourceDeviceId] as String? ?? '',
      deletedAtMs: row[MediaVariantsSchema.colDeletedAtMs] as int?,
    );
  }
}
