import 'package:drift/drift.dart';

import '../../domain/repositories/lyric_cache_repository.dart';
import 'konata_database.dart';

/// 基于 Drift 的在线歌词检索结果缓存仓储。
class DriftLyricCacheRepository implements LyricCacheRepository {
  /// 创建缓存仓储。
  DriftLyricCacheRepository(this._db);

  final KonataDatabase _db;

  @override
  Future<LyricCacheEntry?> findByTrackKey(String trackKey) async {
    final row = await (_db.select(
      _db.lyricCacheEntries,
    )..where((t) => t.trackKey.equals(trackKey))).getSingleOrNull();
    return row == null ? null : _toEntry(row);
  }

  @override
  Future<LyricCacheEntry?> findFoundBySongKey(String songKey) async {
    final row =
        await (_db.select(_db.lyricCacheEntries)
              ..where(
                (t) =>
                    t.songKey.equals(songKey) &
                    t.status.equalsValue(LyricCacheStatus.found),
              )
              ..orderBy([(t) => OrderingTerm.desc(t.score)])
              ..limit(1))
            .getSingleOrNull();
    return row == null ? null : _toEntry(row);
  }

  @override
  Future<void> save(LyricCacheEntry entry) async {
    await _db
        .into(_db.lyricCacheEntries)
        .insertOnConflictUpdate(
          LyricCacheEntriesCompanion.insert(
            trackKey: entry.trackKey,
            songKey: Value(entry.songKey),
            status: entry.status,
            source: Value(entry.source),
            sourceId: Value(entry.sourceId),
            lrcContent: Value(entry.lrcContent),
            score: Value(entry.score),
            engineVersion: entry.engineVersion,
            updatedAt: entry.updatedAt,
          ),
        );
  }

  LyricCacheEntry _toEntry(LyricCacheRow row) {
    return LyricCacheEntry(
      trackKey: row.trackKey,
      songKey: row.songKey,
      status: row.status,
      source: row.source,
      sourceId: row.sourceId,
      lrcContent: row.lrcContent,
      score: row.score,
      engineVersion: row.engineVersion,
      updatedAt: row.updatedAt,
    );
  }
}
