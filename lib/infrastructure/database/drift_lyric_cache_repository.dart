import 'package:drift/drift.dart';

import '../../domain/lyrics/lyric_offset_resolver.dart';
import '../../domain/repositories/lyric_cache_repository.dart';
import 'konata_database.dart';

/// 基于 Drift 的在线歌词检索结果与三级偏移持久化仓储。
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
            offsetMillis: Value(
              LyricOffsetSnapshot.clampTrackOrAlbum(entry.offsetMillis),
            ),
            userOffsetLocked: Value(entry.userOffsetLocked),
            userEdited: Value(entry.userEdited),
          ),
        );
  }

  @override
  Future<int> findAlbumOffsetMillis(String albumKey) async {
    if (albumKey.trim().isEmpty) return 0;
    final row = await (_db.select(
      _db.albumLyricOffsets,
    )..where((t) => t.albumKey.equals(albumKey))).getSingleOrNull();
    return row?.offsetMillis ?? 0;
  }

  @override
  Future<void> saveAlbumOffsetMillis(String albumKey, int offsetMillis) async {
    if (albumKey.trim().isEmpty) return;
    final clamped = LyricOffsetSnapshot.clampTrackOrAlbum(offsetMillis);
    if (clamped == 0) {
      await (_db.delete(
        _db.albumLyricOffsets,
      )..where((t) => t.albumKey.equals(albumKey))).go();
      return;
    }
    await _db
        .into(_db.albumLyricOffsets)
        .insertOnConflictUpdate(
          AlbumLyricOffsetsCompanion.insert(
            albumKey: albumKey,
            offsetMillis: Value(clamped),
            updatedAt: DateTime.now(),
          ),
        );
  }

  @override
  Future<void> updateTrackOffset(
    String trackKey, {
    required int offsetMillis,
    required bool userOffsetLocked,
  }) async {
    final clamped = LyricOffsetSnapshot.clampTrackOrAlbum(offsetMillis);
    final existing = await findByTrackKey(trackKey);
    if (existing != null) {
      await (_db.update(
        _db.lyricCacheEntries,
      )..where((t) => t.trackKey.equals(trackKey))).write(
        LyricCacheEntriesCompanion(
          offsetMillis: Value(clamped),
          userOffsetLocked: Value(userOffsetLocked),
          updatedAt: Value(DateTime.now()),
        ),
      );
      return;
    }
    // 尚未生成在线歌词缓存行（例如本地外挂 `.lrc` 曲目）时仅落盘偏移锚点，`engineVersion = 0` 不干扰后续在线检索。
    await _db
        .into(_db.lyricCacheEntries)
        .insertOnConflictUpdate(
          LyricCacheEntriesCompanion.insert(
            trackKey: trackKey,
            status: LyricCacheStatus.notFound,
            engineVersion: 0,
            updatedAt: DateTime.now(),
            offsetMillis: Value(clamped),
            userOffsetLocked: Value(userOffsetLocked),
            userEdited: const Value(false),
          ),
        );
  }

  @override
  Future<void> unlockUserEdit(String trackKey) async {
    await (_db.update(
      _db.lyricCacheEntries,
    )..where((t) => t.trackKey.equals(trackKey))).write(
      LyricCacheEntriesCompanion(
        userEdited: const Value(false),
        engineVersion: const Value(0),
        updatedAt: Value(DateTime.now()),
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
      offsetMillis: row.offsetMillis,
      userOffsetLocked: row.userOffsetLocked,
      userEdited: row.userEdited,
    );
  }
}
