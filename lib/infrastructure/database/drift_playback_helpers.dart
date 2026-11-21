import 'dart:convert';

import 'package:drift/drift.dart';

import '../../domain/models/playback_record.dart';
import '../../domain/models/tmdb_models.dart';
import 'konata_database.dart';

/// 保存或更新作品待复核 Top-5 候选列表。
Future<void> saveScrapeCandidatesInDb(
  KonataDatabase db,
  String workId,
  List<ScrapeCandidateSummary> candidates,
) async {
  await db.transaction(() async {
    await (db.delete(
      db.scrapeCandidates,
    )..where((t) => t.workId.equals(workId))).go();
    for (final item in candidates.take(5)) {
      await db
          .into(db.scrapeCandidates)
          .insert(
            ScrapeCandidatesCompanion(
              workId: Value(workId),
              rank: Value(item.rank),
              tmdbId: Value(item.tmdbId),
              mediaType: Value(item.mediaType),
              title: Value(item.title),
              originalTitle: Value(item.originalTitle),
              year: Value(item.year),
              episodeCount: Value(item.episodeCount),
              posterPath: Value(item.posterPath),
              score: Value(item.score),
              reasonsJson: Value(jsonEncode(item.reasons)),
            ),
          );
    }
  });
}

/// 读取指定作品待复核 Top-5 候选列表。
Future<List<ScrapeCandidateSummary>> readScrapeCandidatesInDb(
  KonataDatabase db,
  String workId,
) async {
  final query = db.select(db.scrapeCandidates)
    ..where((t) => t.workId.equals(workId))
    ..orderBy([(t) => OrderingTerm.asc(t.rank)]);
  final rows = await query.get();
  return [
    for (final row in rows)
      ScrapeCandidateSummary(
        workId: row.workId,
        tmdbId: row.tmdbId,
        mediaType: row.mediaType,
        title: row.title,
        originalTitle: row.originalTitle,
        year: row.year,
        episodeCount: row.episodeCount,
        posterPath: row.posterPath,
        score: row.score,
        rank: row.rank,
        reasons: _decodeStringList(row.reasonsJson),
      ),
  ];
}

/// 写入或刷新单集播放记录（同一 `workId + episodeId` 自动收敛为单条最新进度）。
Future<void> upsertPlaybackRecordInDb(
  KonataDatabase db,
  PlaybackRecord record,
) async {
  final completed =
      record.isCompleted ||
      PlaybackRecord.computeCompleted(
        positionSeconds: record.positionSeconds,
        durationSeconds: record.durationSeconds,
        isAudio: record.isAudioRecord,
      );

  await db.transaction(() async {
    final existingRows =
        await (db.select(db.playbackRecords)..where(
              (t) =>
                  t.workId.equals(record.workId) &
                  t.episodeId.equals(record.episodeId),
            ))
            .get();

    final effectiveId = existingRows.isNotEmpty
        ? existingRows.first.id
        : record.id;

    // 清理同一剧集冗余旧记录，确保每集仅保留一条实时进度记录。
    for (final old in existingRows) {
      if (old.id != effectiveId) {
        await (db.delete(
          db.playbackRecords,
        )..where((t) => t.id.equals(old.id))).go();
      }
    }

    await db
        .into(db.playbackRecords)
        .insertOnConflictUpdate(
          PlaybackRecordsCompanion(
            id: Value(effectiveId),
            workId: Value(record.workId),
            episodeId: Value(record.episodeId),
            variantId: Value(record.variantId),
            seasonNumber: Value(record.seasonNumber),
            episodeNumber: Value(record.episodeNumber),
            episodeTitle: Value(record.episodeTitle),
            sourceType: Value(record.sourceType),
            playedAt: Value(record.playedAt),
            positionSeconds: Value(record.positionSeconds),
            durationSeconds: Value(record.durationSeconds),
            isCompleted: Value(completed),
          ),
        );
  });
}

/// 按播放时间倒序查询全局播放历史。
Future<List<PlaybackRecord>> readPlaybackHistoryInDb(
  KonataDatabase db, {
  int limit = 100,
}) async {
  final query = db.select(db.playbackRecords)
    ..orderBy([(t) => OrderingTerm.desc(t.playedAt)])
    ..limit(limit);
  final rows = await query.get();
  return [for (final row in rows) mapPlaybackRow(row)];
}

/// 查询指定作品下全部剧集的最新播放记录。
Future<List<PlaybackRecord>> readPlaybacksByWorkInDb(
  KonataDatabase db,
  String workId,
) async {
  final query = db.select(db.playbackRecords)
    ..where((t) => t.workId.equals(workId))
    ..orderBy([(t) => OrderingTerm.desc(t.playedAt)]);
  final rows = await query.get();
  return [for (final row in rows) mapPlaybackRow(row)];
}

/// 查询指定作品最近一条视频播放记录（排除 `cd::` 音频记录，避免干扰正片续播推荐）。
Future<PlaybackRecord?> readLatestPlaybackForWorkInDb(
  KonataDatabase db,
  String workId,
) async {
  final query = db.select(db.playbackRecords)
    ..where((t) => t.workId.equals(workId) & t.episodeId.like('cd::%').not())
    ..orderBy([(t) => OrderingTerm.desc(t.playedAt)])
    ..limit(1);
  final row = await query.getSingleOrNull();
  return row == null ? null : mapPlaybackRow(row);
}

/// 将数据库行映射为强类型 [PlaybackRecord]。
PlaybackRecord mapPlaybackRow(PlaybackRecordRow row) => PlaybackRecord(
  id: row.id,
  workId: row.workId,
  episodeId: row.episodeId,
  variantId: row.variantId,
  seasonNumber: row.seasonNumber,
  episodeNumber: row.episodeNumber,
  episodeTitle: row.episodeTitle,
  sourceType: row.sourceType,
  playedAt: row.playedAt,
  positionSeconds: row.positionSeconds,
  durationSeconds: row.durationSeconds,
  isCompleted: row.isCompleted,
);

List<String> _decodeStringList(String raw) {
  final decoded = jsonDecode(raw);
  if (decoded is! List) return const [];
  return [for (final item in decoded) item.toString()];
}
