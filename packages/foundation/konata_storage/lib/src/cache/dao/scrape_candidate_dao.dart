import 'package:konata_contracts/konata_contracts.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../engine/konata_sqlite_engine.dart';
import '../../engine/row_codec.dart';
import '../schema/scrape_candidates_schema.dart';

/// `scrape_candidates` 强类型缓存记录模型。
final class ScrapeCandidateRecord {
  /// 创建待复核候选记录。
  const ScrapeCandidateRecord({
    required this.workId,
    required this.rank,
    required this.tmdbId,
    required this.mediaType,
    required this.title,
    required this.score,
    this.originalTitle,
    this.year,
    this.posterPath,
    this.reasons = const <String>[],
    this.episodeCount,
    this.cachedAtMs = 0,
  });

  /// 所属作品主键。
  final WorkId workId;

  /// 候选排名（`1..5`）。
  final int rank;

  /// 候选 TMDB 条目编号。
  final int tmdbId;

  /// 候选媒体类型。
  final TmdbMediaType mediaType;

  /// 候选展示标题。
  final String title;

  /// 候选原始标题。
  final String? originalTitle;

  /// 候选发行年份。
  final int? year;

  /// 候选海报相对路径。
  final String? posterPath;

  /// 匹配综合得分。
  final double score;

  /// 得分原因码列表。
  final List<String> reasons;

  /// 候选总集数。
  final int? episodeCount;

  /// 写入时间（UTC 毫秒）。
  final int cachedAtMs;
}

/// `scrape_candidates` 标准 SQL 响应式 DAO。
final class ScrapeCandidateDao {
  /// 创建刮削候选缓存 DAO。
  const ScrapeCandidateDao(this._engine);

  final KonataSqliteEngine _engine;

  static const Set<String> _tables = <String>{ScrapeCandidatesSchema.table};

  /// 原子替换指定作品的全部待复核候选列表。
  void replaceForWork(WorkId workId, List<ScrapeCandidateRecord> candidates) {
    _engine.runTransaction((tx) {
      tx.execute(
        'DELETE FROM ${ScrapeCandidatesSchema.table} '
        'WHERE ${ScrapeCandidatesSchema.colWorkId} = ?;',
        <Object?>[workId.value],
        _tables,
      );
      for (final item in candidates) {
        tx.execute(
          '''
INSERT INTO ${ScrapeCandidatesSchema.table} (
  ${ScrapeCandidatesSchema.colWorkId},
  ${ScrapeCandidatesSchema.colRank},
  ${ScrapeCandidatesSchema.colTmdbId},
  ${ScrapeCandidatesSchema.colMediaType},
  ${ScrapeCandidatesSchema.colTitle},
  ${ScrapeCandidatesSchema.colOriginalTitle},
  ${ScrapeCandidatesSchema.colYear},
  ${ScrapeCandidatesSchema.colPosterPath},
  ${ScrapeCandidatesSchema.colScore},
  ${ScrapeCandidatesSchema.colReasonsJson},
  ${ScrapeCandidatesSchema.colEpisodeCount},
  ${ScrapeCandidatesSchema.colCachedAtMs}
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
''',
          <Object?>[
            item.workId.value,
            item.rank,
            item.tmdbId,
            item.mediaType.name,
            item.title,
            item.originalTitle,
            item.year,
            item.posterPath,
            item.score,
            SqliteRowCodec.encodeStringList(item.reasons),
            item.episodeCount,
            item.cachedAtMs,
          ],
          _tables,
        );
      }
    });
  }

  /// 查询指定作品的待复核候选列表（按排名升序）。
  List<ScrapeCandidateRecord> listByWork(WorkId workId) {
    return _queryByWork(_engine.select, workId);
  }

  /// 响应式监听指定作品的待复核候选列表变化。
  Stream<List<ScrapeCandidateRecord>> watchByWork(WorkId workId) {
    return _engine.watchQuery<List<ScrapeCandidateRecord>>(
      tables: _tables,
      query: (db) => _queryByWork(db.select, workId),
    );
  }

  /// 清理指定作品的全部候选缓存。
  void clearForWork(WorkId workId) {
    _engine.runTransaction((tx) {
      tx.execute(
        'DELETE FROM ${ScrapeCandidatesSchema.table} '
        'WHERE ${ScrapeCandidatesSchema.colWorkId} = ?;',
        <Object?>[workId.value],
        _tables,
      );
    });
  }

  List<ScrapeCandidateRecord> _queryByWork(
    ResultSet Function(String, [List<Object?>]) selectFn,
    WorkId workId,
  ) {
    final rs = selectFn(
      'SELECT * FROM ${ScrapeCandidatesSchema.table} '
      'WHERE ${ScrapeCandidatesSchema.colWorkId} = ? '
      'ORDER BY ${ScrapeCandidatesSchema.colRank} ASC;',
      <Object?>[workId.value],
    );
    return <ScrapeCandidateRecord>[for (final row in rs) _mapRow(row)];
  }

  ScrapeCandidateRecord _mapRow(Row row) {
    return ScrapeCandidateRecord(
      workId: WorkId.trusted(row[ScrapeCandidatesSchema.colWorkId] as String),
      rank: row[ScrapeCandidatesSchema.colRank] as int,
      tmdbId: row[ScrapeCandidatesSchema.colTmdbId] as int,
      mediaType: SqliteRowCodec.decodeEnum(
        TmdbMediaType.values,
        row[ScrapeCandidatesSchema.colMediaType],
        TmdbMediaType.tv,
      ),
      title: row[ScrapeCandidatesSchema.colTitle] as String,
      originalTitle: row[ScrapeCandidatesSchema.colOriginalTitle] as String?,
      year: row[ScrapeCandidatesSchema.colYear] as int?,
      posterPath: row[ScrapeCandidatesSchema.colPosterPath] as String?,
      score: (row[ScrapeCandidatesSchema.colScore] as num?)?.toDouble() ?? 0.0,
      reasons: SqliteRowCodec.decodeStringList(
        row[ScrapeCandidatesSchema.colReasonsJson],
      ),
      episodeCount: row[ScrapeCandidatesSchema.colEpisodeCount] as int?,
      cachedAtMs: row[ScrapeCandidatesSchema.colCachedAtMs] as int? ?? 0,
    );
  }
}
