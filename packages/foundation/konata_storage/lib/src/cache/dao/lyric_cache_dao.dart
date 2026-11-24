import 'package:sqlite3/sqlite3.dart';

import '../../engine/konata_sqlite_engine.dart';
import '../../engine/row_codec.dart';
import '../schema/lyric_cache_entries_schema.dart';

/// 在线歌词缓存命中状态。
enum LyricCacheHitStatus {
  /// 命中有效在线歌词。
  hit,

  /// 检索未命中（用于短期负缓存冷却）。
  miss,
}

/// `lyric_cache_entries` 强类型缓存记录模型。
final class LyricCacheEntryRecord {
  /// 创建歌词缓存条目。
  const LyricCacheEntryRecord({
    required this.trackKey,
    required this.status,
    required this.engineVersion,
    required this.updatedAtMs,
    this.songKey,
    this.source,
    this.sourceId = '',
    this.lrcContent = '',
    this.score = 0.0,
  });

  /// 物理曲目键。
  final String trackKey;

  /// 跨文件共享歌曲键。
  final String? songKey;

  /// 命中状态。
  final LyricCacheHitStatus status;

  /// 命中来源标识（如 `amll`、`netease`、`qqmusic`、`lrclib`）。
  final String? source;

  /// 来源内部歌曲编号。
  final String sourceId;

  /// 增强 LRC 正文。
  final String lrcContent;

  /// 候选得分。
  final double score;

  /// 歌词引擎版本号。
  final int engineVersion;

  /// 最近写入时间（UTC 毫秒）。
  final int updatedAtMs;
}

/// `lyric_cache_entries` 标准 SQL 响应式 DAO。
final class LyricCacheDao {
  /// 创建在线歌词缓存 DAO。
  const LyricCacheDao(this._engine);

  final KonataSqliteEngine _engine;

  static const Set<String> _tables = <String>{LyricCacheEntriesSchema.table};

  /// 写入或覆盖一条在线歌词缓存记录。
  void upsert(LyricCacheEntryRecord record) {
    _engine.runTransaction((tx) {
      tx.execute(
        '''
INSERT INTO ${LyricCacheEntriesSchema.table} (
  ${LyricCacheEntriesSchema.colTrackKey},
  ${LyricCacheEntriesSchema.colSongKey},
  ${LyricCacheEntriesSchema.colStatus},
  ${LyricCacheEntriesSchema.colSource},
  ${LyricCacheEntriesSchema.colSourceId},
  ${LyricCacheEntriesSchema.colLrcContent},
  ${LyricCacheEntriesSchema.colScore},
  ${LyricCacheEntriesSchema.colEngineVersion},
  ${LyricCacheEntriesSchema.colUpdatedAtMs}
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(${LyricCacheEntriesSchema.colTrackKey}) DO UPDATE SET
  ${LyricCacheEntriesSchema.colSongKey} = excluded.${LyricCacheEntriesSchema.colSongKey},
  ${LyricCacheEntriesSchema.colStatus} = excluded.${LyricCacheEntriesSchema.colStatus},
  ${LyricCacheEntriesSchema.colSource} = excluded.${LyricCacheEntriesSchema.colSource},
  ${LyricCacheEntriesSchema.colSourceId} = excluded.${LyricCacheEntriesSchema.colSourceId},
  ${LyricCacheEntriesSchema.colLrcContent} = excluded.${LyricCacheEntriesSchema.colLrcContent},
  ${LyricCacheEntriesSchema.colScore} = excluded.${LyricCacheEntriesSchema.colScore},
  ${LyricCacheEntriesSchema.colEngineVersion} = excluded.${LyricCacheEntriesSchema.colEngineVersion},
  ${LyricCacheEntriesSchema.colUpdatedAtMs} = excluded.${LyricCacheEntriesSchema.colUpdatedAtMs};
''',
        <Object?>[
          record.trackKey,
          record.songKey,
          record.status.name,
          record.source,
          record.sourceId,
          record.lrcContent,
          record.score,
          record.engineVersion,
          record.updatedAtMs,
        ],
        _tables,
      );
    });
  }

  /// 按物理曲目键查询缓存。
  LyricCacheEntryRecord? findByTrackKey(String trackKey) {
    final rs = _engine.select(
      'SELECT * FROM ${LyricCacheEntriesSchema.table} '
      'WHERE ${LyricCacheEntriesSchema.colTrackKey} = ? LIMIT 1;',
      <Object?>[trackKey],
    );
    if (rs.isEmpty) return null;
    return _mapRow(rs.first);
  }

  /// 按跨文件歌曲规范键查询最佳命中缓存。
  LyricCacheEntryRecord? findBestHitBySongKey(String songKey) {
    final rs = _engine.select(
      'SELECT * FROM ${LyricCacheEntriesSchema.table} '
      'WHERE ${LyricCacheEntriesSchema.colSongKey} = ? '
      'AND ${LyricCacheEntriesSchema.colStatus} = ? '
      'ORDER BY ${LyricCacheEntriesSchema.colScore} DESC, '
      '${LyricCacheEntriesSchema.colUpdatedAtMs} DESC LIMIT 1;',
      <Object?>[songKey, LyricCacheHitStatus.hit.name],
    );
    if (rs.isEmpty) return null;
    return _mapRow(rs.first);
  }

  /// 响应式监听指定曲目键的缓存条目。
  Stream<LyricCacheEntryRecord?> watchTrackKey(String trackKey) {
    return _engine.watchQuery<LyricCacheEntryRecord?>(
      tables: _tables,
      query: (db) {
        final rs = db.select(
          'SELECT * FROM ${LyricCacheEntriesSchema.table} '
          'WHERE ${LyricCacheEntriesSchema.colTrackKey} = ? LIMIT 1;',
          <Object?>[trackKey],
        );
        if (rs.isEmpty) return null;
        return _mapRow(rs.first);
      },
    );
  }

  LyricCacheEntryRecord _mapRow(Row row) {
    return LyricCacheEntryRecord(
      trackKey: row[LyricCacheEntriesSchema.colTrackKey] as String,
      songKey: row[LyricCacheEntriesSchema.colSongKey] as String?,
      status: SqliteRowCodec.decodeEnum(
        LyricCacheHitStatus.values,
        row[LyricCacheEntriesSchema.colStatus],
        LyricCacheHitStatus.miss,
      ),
      source: row[LyricCacheEntriesSchema.colSource] as String?,
      sourceId: row[LyricCacheEntriesSchema.colSourceId] as String? ?? '',
      lrcContent: row[LyricCacheEntriesSchema.colLrcContent] as String? ?? '',
      score: (row[LyricCacheEntriesSchema.colScore] as num?)?.toDouble() ?? 0.0,
      engineVersion: row[LyricCacheEntriesSchema.colEngineVersion] as int? ?? 1,
      updatedAtMs: row[LyricCacheEntriesSchema.colUpdatedAtMs] as int? ?? 0,
    );
  }
}
