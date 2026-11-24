import 'package:konata_contracts/konata_contracts.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../engine/konata_sqlite_engine.dart';
import '../../engine/row_codec.dart';
import '../schema/works_schema.dart';

/// `works` 强类型持久化记录模型（原生集成 `ArtworkRef` 与同步墓碑元数据）。
final class WorkRecord {
  /// 创建作品持久化记录。
  const WorkRecord({
    required this.id,
    required this.title,
    this.canonicalKey,
    this.tmdbId,
    this.tmdbMediaType,
    this.bangumiId,
    this.tvdbId,
    this.matchedSeason,
    this.originalTitle,
    this.year,
    this.overview,
    this.posterRef,
    this.posterFallback,
    this.bangumiPosterPath,
    this.backdropRef,
    this.logoRef,
    this.voteAverage,
    this.bangumiScore,
    this.folderTmdbHint,
    this.isManualLocked = false,
    this.metadataLocked = false,
    this.isHidden = false,
    this.keepHidden = false,
    this.scrapeStatus = ScrapeStatus.unmatched,
    this.reviewReason,
    this.seriesId,
    this.seriesOrder,
    this.seriesLabel,
    this.seriesLocked = false,
    this.updatedAtMs = 0,
    this.sourceDeviceId = '',
    this.deletedAtMs,
  });

  /// 作品主键。
  final WorkId id;

  /// 跨设备稳定规范键。
  final String? canonicalKey;

  /// 绑定的 TMDB 条目编号。
  final int? tmdbId;

  /// TMDB 媒体类型。
  final TmdbMediaType? tmdbMediaType;

  /// 绑定的 Bangumi 条目编号。
  final int? bangumiId;

  /// 关联的 TheTVDB 编号。
  final int? tvdbId;

  /// 季级匹配绑定季号。
  final int? matchedSeason;

  /// 展示标题。
  final String title;

  /// 原始语言标题。
  final String? originalTitle;

  /// 发行或首播年份。
  final int? year;

  /// 作品简介。
  final String? overview;

  /// 封面海报强类型引用。
  final ArtworkRef? posterRef;

  /// 剧集级海报回退路径。
  final String? posterFallback;

  /// 关联 Bangumi 官方封面 URL。
  final String? bangumiPosterPath;

  /// 横版背景强类型引用。
  final ArtworkRef? backdropRef;

  /// 透明标题徽标强类型引用。
  final ArtworkRef? logoRef;

  /// TMDB 评分。
  final double? voteAverage;

  /// Bangumi 评分。
  final double? bangumiScore;

  /// 文件夹显式 TMDB 编号提示。
  final int? folderTmdbHint;

  /// 匹配条目人工锁。
  final bool isManualLocked;

  /// 基础元数据人工锁。
  final bool metadataLocked;

  /// 是否在主媒体库隐藏。
  final bool isHidden;

  /// 重扫后是否继续保持隐藏。
  final bool keepHidden;

  /// 刮削匹配状态。
  final ScrapeStatus scrapeStatus;

  /// 待复核或未匹配原因码。
  final String? reviewReason;

  /// 所属系列编组主键。
  final SeriesGroupId? seriesId;

  /// 在所属系列中的排序序号。
  final int? seriesOrder;

  /// 在所属系列中的展示标签。
  final String? seriesLabel;

  /// 系列编组人工锁。
  final bool seriesLocked;

  /// 最近更新时间（UTC 毫秒）。
  final int updatedAtMs;

  /// 最近修改设备标识。
  final String sourceDeviceId;

  /// 软删除墓碑时间戳（UTC 毫秒）。
  final int? deletedAtMs;

  /// 是否已软删除。
  bool get isDeleted => deletedAtMs != null;

  /// 投影为跨包只读作品摘要视图。
  WorkSummaryView toSummaryView() => WorkSummaryView(
    id: id,
    title: title,
    scrapeStatus: scrapeStatus,
    canonicalKey: canonicalKey,
    originalTitle: originalTitle,
    year: year,
    tmdbId: tmdbId,
    bangumiId: bangumiId,
    posterRef: posterRef,
    backdropRef: backdropRef,
    logoRef: logoRef,
    seriesGroupId: seriesId,
    isHidden: isHidden,
  );
}

/// `works` 标准 SQL 响应式 DAO。
final class WorkDao {
  /// 创建作品 DAO。
  const WorkDao(this._engine);

  final KonataSqliteEngine _engine;

  static const Set<String> _tables = <String>{WorksSchema.table};

  /// 新增或覆盖写入一条作品记录。
  void upsert(WorkRecord record) {
    _engine.runTransaction((tx) => upsertInTx(tx, record));
  }

  /// 在已有事务内新增或覆盖写入作品记录。
  void upsertInTx(SqliteTransaction tx, WorkRecord record) {
    tx.execute(
      '''
INSERT INTO ${WorksSchema.table} (
  ${WorksSchema.colId},
  ${WorksSchema.colCanonicalKey},
  ${WorksSchema.colTmdbId},
  ${WorksSchema.colTmdbMediaType},
  ${WorksSchema.colBangumiId},
  ${WorksSchema.colTvdbId},
  ${WorksSchema.colMatchedSeason},
  ${WorksSchema.colTitle},
  ${WorksSchema.colOriginalTitle},
  ${WorksSchema.colYear},
  ${WorksSchema.colOverview},
  ${WorksSchema.colPosterRefJson},
  ${WorksSchema.colPosterFallback},
  ${WorksSchema.colBangumiPosterPath},
  ${WorksSchema.colBackdropRefJson},
  ${WorksSchema.colLogoRefJson},
  ${WorksSchema.colVoteAverage},
  ${WorksSchema.colBangumiScore},
  ${WorksSchema.colFolderTmdbHint},
  ${WorksSchema.colIsManualLocked},
  ${WorksSchema.colMetadataLocked},
  ${WorksSchema.colIsHidden},
  ${WorksSchema.colKeepHidden},
  ${WorksSchema.colScrapeStatus},
  ${WorksSchema.colReviewReason},
  ${WorksSchema.colSeriesId},
  ${WorksSchema.colSeriesOrder},
  ${WorksSchema.colSeriesLabel},
  ${WorksSchema.colSeriesLocked},
  ${WorksSchema.colUpdatedAtMs},
  ${WorksSchema.colSourceDeviceId},
  ${WorksSchema.colDeletedAtMs}
) VALUES (
  ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
  ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?
)
ON CONFLICT(${WorksSchema.colId}) DO UPDATE SET
  ${WorksSchema.colCanonicalKey} = excluded.${WorksSchema.colCanonicalKey},
  ${WorksSchema.colTmdbId} = excluded.${WorksSchema.colTmdbId},
  ${WorksSchema.colTmdbMediaType} = excluded.${WorksSchema.colTmdbMediaType},
  ${WorksSchema.colBangumiId} = excluded.${WorksSchema.colBangumiId},
  ${WorksSchema.colTvdbId} = excluded.${WorksSchema.colTvdbId},
  ${WorksSchema.colMatchedSeason} = excluded.${WorksSchema.colMatchedSeason},
  ${WorksSchema.colTitle} = excluded.${WorksSchema.colTitle},
  ${WorksSchema.colOriginalTitle} = excluded.${WorksSchema.colOriginalTitle},
  ${WorksSchema.colYear} = excluded.${WorksSchema.colYear},
  ${WorksSchema.colOverview} = excluded.${WorksSchema.colOverview},
  ${WorksSchema.colPosterRefJson} = excluded.${WorksSchema.colPosterRefJson},
  ${WorksSchema.colPosterFallback} = excluded.${WorksSchema.colPosterFallback},
  ${WorksSchema.colBangumiPosterPath} = excluded.${WorksSchema.colBangumiPosterPath},
  ${WorksSchema.colBackdropRefJson} = excluded.${WorksSchema.colBackdropRefJson},
  ${WorksSchema.colLogoRefJson} = excluded.${WorksSchema.colLogoRefJson},
  ${WorksSchema.colVoteAverage} = excluded.${WorksSchema.colVoteAverage},
  ${WorksSchema.colBangumiScore} = excluded.${WorksSchema.colBangumiScore},
  ${WorksSchema.colFolderTmdbHint} = excluded.${WorksSchema.colFolderTmdbHint},
  ${WorksSchema.colIsManualLocked} = excluded.${WorksSchema.colIsManualLocked},
  ${WorksSchema.colMetadataLocked} = excluded.${WorksSchema.colMetadataLocked},
  ${WorksSchema.colIsHidden} = excluded.${WorksSchema.colIsHidden},
  ${WorksSchema.colKeepHidden} = excluded.${WorksSchema.colKeepHidden},
  ${WorksSchema.colScrapeStatus} = excluded.${WorksSchema.colScrapeStatus},
  ${WorksSchema.colReviewReason} = excluded.${WorksSchema.colReviewReason},
  ${WorksSchema.colSeriesId} = excluded.${WorksSchema.colSeriesId},
  ${WorksSchema.colSeriesOrder} = excluded.${WorksSchema.colSeriesOrder},
  ${WorksSchema.colSeriesLabel} = excluded.${WorksSchema.colSeriesLabel},
  ${WorksSchema.colSeriesLocked} = excluded.${WorksSchema.colSeriesLocked},
  ${WorksSchema.colUpdatedAtMs} = excluded.${WorksSchema.colUpdatedAtMs},
  ${WorksSchema.colSourceDeviceId} = excluded.${WorksSchema.colSourceDeviceId},
  ${WorksSchema.colDeletedAtMs} = excluded.${WorksSchema.colDeletedAtMs};
''',
      <Object?>[
        record.id.value,
        record.canonicalKey,
        record.tmdbId,
        record.tmdbMediaType?.name,
        record.bangumiId,
        record.tvdbId,
        record.matchedSeason,
        record.title,
        record.originalTitle,
        record.year,
        record.overview,
        SqliteRowCodec.encodeArtworkRef(record.posterRef),
        record.posterFallback,
        record.bangumiPosterPath,
        SqliteRowCodec.encodeArtworkRef(record.backdropRef),
        SqliteRowCodec.encodeArtworkRef(record.logoRef),
        record.voteAverage,
        record.bangumiScore,
        record.folderTmdbHint,
        SqliteRowCodec.encodeBool(record.isManualLocked),
        SqliteRowCodec.encodeBool(record.metadataLocked),
        SqliteRowCodec.encodeBool(record.isHidden),
        SqliteRowCodec.encodeBool(record.keepHidden),
        record.scrapeStatus.name,
        record.reviewReason,
        record.seriesId?.value,
        record.seriesOrder,
        record.seriesLabel,
        SqliteRowCodec.encodeBool(record.seriesLocked),
        record.updatedAtMs,
        record.sourceDeviceId,
        record.deletedAtMs,
      ],
      _tables,
    );
  }

  /// 按主键查询作品（默认过滤软删除墓碑）。
  WorkRecord? findById(WorkId id, {bool includeDeleted = false}) {
    final whereDeleted = includeDeleted
        ? ''
        : ' AND ${WorksSchema.colDeletedAtMs} IS NULL';
    final rs = _engine.select(
      'SELECT * FROM ${WorksSchema.table} '
      'WHERE ${WorksSchema.colId} = ?$whereDeleted LIMIT 1;',
      <Object?>[id.value],
    );
    if (rs.isEmpty) return null;
    return _mapRow(rs.first);
  }

  /// 按跨设备规范键查询作品。
  WorkRecord? findByCanonicalKey(
    String canonicalKey, {
    bool includeDeleted = false,
  }) {
    final whereDeleted = includeDeleted
        ? ''
        : ' AND ${WorksSchema.colDeletedAtMs} IS NULL';
    final rs = _engine.select(
      'SELECT * FROM ${WorksSchema.table} '
      'WHERE ${WorksSchema.colCanonicalKey} = ?$whereDeleted LIMIT 1;',
      <Object?>[canonicalKey],
    );
    if (rs.isEmpty) return null;
    return _mapRow(rs.first);
  }

  /// 查询全部有效可见作品（过滤已隐藏与软删除记录）。
  List<WorkRecord> listVisible() {
    return _queryVisible(_engine.select);
  }

  /// 响应式监听可见作品列表变化。
  Stream<List<WorkRecord>> watchVisible() {
    return _engine.watchQuery<List<WorkRecord>>(
      tables: _tables,
      query: (db) => _queryVisible(db.select),
    );
  }

  /// 查询全部未软删除作品（包含已隐藏作品）。
  List<WorkRecord> listAll({bool includeDeleted = false}) {
    return _queryAll(_engine.select, includeDeleted: includeDeleted);
  }

  /// 响应式监听全部未软删除作品（包含已隐藏作品）。
  Stream<List<WorkRecord>> watchAll({bool includeDeleted = false}) {
    return _engine.watchQuery<List<WorkRecord>>(
      tables: _tables,
      query: (db) => _queryAll(db.select, includeDeleted: includeDeleted),
    );
  }

  /// 查询全部已隐藏且未软删除作品。
  List<WorkRecord> listHidden() {
    return _queryHidden(_engine.select);
  }

  /// 响应式监听全部已隐藏且未软删除作品。
  Stream<List<WorkRecord>> watchHidden() {
    return _engine.watchQuery<List<WorkRecord>>(
      tables: _tables,
      query: (db) => _queryHidden(db.select),
    );
  }

  /// 查询全部待复核或未匹配作品（不含隐藏与软删除）。
  List<WorkRecord> listNeedsReview() {
    return _queryNeedsReview(_engine.select);
  }

  /// 响应式监听待复核与未匹配作品列表变化。
  Stream<List<WorkRecord>> watchNeedsReview() {
    return _engine.watchQuery<List<WorkRecord>>(
      tables: _tables,
      query: (db) => _queryNeedsReview(db.select),
    );
  }

  /// 按系列编组主键查询有效成员作品（按系列顺序与标题排序）。
  List<WorkRecord> listBySeries(SeriesGroupId seriesId) {
    final rs = _engine.select(
      'SELECT * FROM ${WorksSchema.table} '
      'WHERE ${WorksSchema.colSeriesId} = ? '
      'AND ${WorksSchema.colDeletedAtMs} IS NULL '
      'ORDER BY ${WorksSchema.colSeriesOrder} ASC, '
      '${WorksSchema.colYear} ASC, ${WorksSchema.colTitle} ASC;',
      <Object?>[seriesId.value],
    );
    return <WorkRecord>[for (final row in rs) _mapRow(row)];
  }

  /// 查询含已软删除墓碑在内的全部作品（供增量同步切片导出）。
  List<WorkRecord> listAllWithTombstones() {
    final rs = _engine.select(
      'SELECT * FROM ${WorksSchema.table} '
      'ORDER BY ${WorksSchema.colUpdatedAtMs} DESC, ${WorksSchema.colId} ASC;',
    );
    return <WorkRecord>[for (final row in rs) _mapRow(row)];
  }

  /// 软删除作品并写入墓碑时间戳（不删除用户物理文件）。
  void softDelete(
    WorkId id, {
    required int deletedAtMs,
    String sourceDeviceId = '',
  }) {
    _engine.runTransaction((tx) {
      tx.execute(
        '''
UPDATE ${WorksSchema.table}
SET ${WorksSchema.colDeletedAtMs} = ?,
    ${WorksSchema.colUpdatedAtMs} = ?,
    ${WorksSchema.colSourceDeviceId} = ?
WHERE ${WorksSchema.colId} = ?;
''',
        <Object?>[deletedAtMs, deletedAtMs, sourceDeviceId, id.value],
        _tables,
      );
    });
  }

  /// 物理删除作品行（将触发 `episodes` 与 `media_variants` 外键级联删除）。
  void hardDelete(WorkId id) {
    _engine.runTransaction((tx) {
      tx.execute(
        'DELETE FROM ${WorksSchema.table} WHERE ${WorksSchema.colId} = ?;',
        <Object?>[id.value],
        _tables,
      );
    });
  }

  List<WorkRecord> _queryVisible(
    ResultSet Function(String, [List<Object?>]) selectFn,
  ) {
    final rs = selectFn(
      'SELECT * FROM ${WorksSchema.table} '
      'WHERE ${WorksSchema.colDeletedAtMs} IS NULL '
      'AND ${WorksSchema.colIsHidden} = 0 '
      'ORDER BY ${WorksSchema.colTitle} ASC, ${WorksSchema.colId} ASC;',
    );
    return <WorkRecord>[for (final row in rs) _mapRow(row)];
  }

  List<WorkRecord> _queryAll(
    ResultSet Function(String, [List<Object?>]) selectFn, {
    required bool includeDeleted,
  }) {
    final whereClause = includeDeleted
        ? ''
        : 'WHERE ${WorksSchema.colDeletedAtMs} IS NULL ';
    final rs = selectFn(
      'SELECT * FROM ${WorksSchema.table} '
      '${whereClause}ORDER BY ${WorksSchema.colTitle} ASC, ${WorksSchema.colId} ASC;',
    );
    return <WorkRecord>[for (final row in rs) _mapRow(row)];
  }

  List<WorkRecord> _queryHidden(
    ResultSet Function(String, [List<Object?>]) selectFn,
  ) {
    final rs = selectFn(
      'SELECT * FROM ${WorksSchema.table} '
      'WHERE ${WorksSchema.colDeletedAtMs} IS NULL '
      'AND ${WorksSchema.colIsHidden} = 1 '
      'ORDER BY ${WorksSchema.colTitle} ASC, ${WorksSchema.colId} ASC;',
    );
    return <WorkRecord>[for (final row in rs) _mapRow(row)];
  }

  List<WorkRecord> _queryNeedsReview(
    ResultSet Function(String, [List<Object?>]) selectFn,
  ) {
    final rs = selectFn(
      'SELECT * FROM ${WorksSchema.table} '
      'WHERE ${WorksSchema.colDeletedAtMs} IS NULL '
      'AND ${WorksSchema.colIsHidden} = 0 '
      'AND ${WorksSchema.colScrapeStatus} != ? '
      'ORDER BY ${WorksSchema.colUpdatedAtMs} DESC, ${WorksSchema.colTitle} ASC;',
      <Object?>[ScrapeStatus.matched.name],
    );
    return <WorkRecord>[for (final row in rs) _mapRow(row)];
  }

  WorkRecord _mapRow(Row row) {
    final rawSeriesId = row[WorksSchema.colSeriesId] as String?;
    return WorkRecord(
      id: WorkId.trusted(row[WorksSchema.colId] as String),
      canonicalKey: row[WorksSchema.colCanonicalKey] as String?,
      tmdbId: row[WorksSchema.colTmdbId] as int?,
      tmdbMediaType: SqliteRowCodec.decodeNullableEnum(
        TmdbMediaType.values,
        row[WorksSchema.colTmdbMediaType],
      ),
      bangumiId: row[WorksSchema.colBangumiId] as int?,
      tvdbId: row[WorksSchema.colTvdbId] as int?,
      matchedSeason: row[WorksSchema.colMatchedSeason] as int?,
      title: row[WorksSchema.colTitle] as String,
      originalTitle: row[WorksSchema.colOriginalTitle] as String?,
      year: row[WorksSchema.colYear] as int?,
      overview: row[WorksSchema.colOverview] as String?,
      posterRef: SqliteRowCodec.decodeArtworkRef(
        row[WorksSchema.colPosterRefJson],
      ),
      posterFallback: row[WorksSchema.colPosterFallback] as String?,
      bangumiPosterPath: row[WorksSchema.colBangumiPosterPath] as String?,
      backdropRef: SqliteRowCodec.decodeArtworkRef(
        row[WorksSchema.colBackdropRefJson],
      ),
      logoRef: SqliteRowCodec.decodeArtworkRef(row[WorksSchema.colLogoRefJson]),
      voteAverage: (row[WorksSchema.colVoteAverage] as num?)?.toDouble(),
      bangumiScore: (row[WorksSchema.colBangumiScore] as num?)?.toDouble(),
      folderTmdbHint: row[WorksSchema.colFolderTmdbHint] as int?,
      isManualLocked: SqliteRowCodec.decodeBool(
        row[WorksSchema.colIsManualLocked],
      ),
      metadataLocked: SqliteRowCodec.decodeBool(
        row[WorksSchema.colMetadataLocked],
      ),
      isHidden: SqliteRowCodec.decodeBool(row[WorksSchema.colIsHidden]),
      keepHidden: SqliteRowCodec.decodeBool(row[WorksSchema.colKeepHidden]),
      scrapeStatus: SqliteRowCodec.decodeEnum(
        ScrapeStatus.values,
        row[WorksSchema.colScrapeStatus],
        ScrapeStatus.unmatched,
      ),
      reviewReason: row[WorksSchema.colReviewReason] as String?,
      seriesId: rawSeriesId == null || rawSeriesId.isEmpty
          ? null
          : SeriesGroupId.trusted(rawSeriesId),
      seriesOrder: row[WorksSchema.colSeriesOrder] as int?,
      seriesLabel: row[WorksSchema.colSeriesLabel] as String?,
      seriesLocked: SqliteRowCodec.decodeBool(row[WorksSchema.colSeriesLocked]),
      updatedAtMs: row[WorksSchema.colUpdatedAtMs] as int? ?? 0,
      sourceDeviceId: row[WorksSchema.colSourceDeviceId] as String? ?? '',
      deletedAtMs: row[WorksSchema.colDeletedAtMs] as int?,
    );
  }
}
