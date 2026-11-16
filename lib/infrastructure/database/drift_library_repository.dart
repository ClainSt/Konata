import 'dart:convert';

import 'package:drift/drift.dart';

import '../../domain/models/episode.dart';
import '../../domain/models/external_player_config.dart';
import '../../domain/models/media_source.dart';
import '../../domain/models/media_variant.dart';
import '../../domain/models/playback_record.dart';
import '../../domain/models/series_group.dart';
import '../../domain/models/tmdb_models.dart';
import '../../domain/models/work.dart';
import '../../domain/repositories/library_repository.dart';
import 'drift_playback_helpers.dart';
import 'drift_series_helpers.dart';
import 'drift_source_helpers.dart';
import 'konata_database.dart';

/// 基于 Drift 实现的强类型媒体库仓储。
class DriftLibraryRepository implements LibraryRepository {
  /// 创建仓储实例。
  const DriftLibraryRepository(this._db);

  final KonataDatabase _db;

  @override
  Future<void> upsertMediaSource(MediaSource source) async {
    await _db
        .into(_db.mediaSources)
        .insertOnConflictUpdate(
          MediaSourcesCompanion(
            id: Value(source.id),
            kind: Value(source.kind),
            label: Value(source.label),
            location: Value(source.location),
            username: Value(source.username),
            createdAt: Value(source.createdAt),
          ),
        );
  }

  @override
  Future<MediaSource?> findSourceById(String sourceId) async {
    final query = _db.select(_db.mediaSources)
      ..where((t) => t.id.equals(sourceId));
    final row = await query.getSingleOrNull();
    return row == null ? null : _mapMediaSource(row);
  }

  @override
  Future<List<MediaSource>> getMediaSources() async {
    final rows = await _db.select(_db.mediaSources).get();
    return rows.map(_mapMediaSource).toList(growable: false);
  }

  MediaSource _mapMediaSource(MediaSourceRow row) {
    return MediaSource(
      id: row.id,
      kind: row.kind,
      label: row.label,
      location: row.location,
      username: row.username,
      createdAt: row.createdAt,
    );
  }

  @override
  Future<void> upsertWork(Work work) async {
    await _db
        .into(_db.works)
        .insertOnConflictUpdate(
          WorksCompanion(
            id: Value(work.id),
            tmdbId: Value(work.tmdbId),
            bangumiId: Value(work.bangumiId),
            tmdbMediaType: Value(work.tmdbMediaType),
            matchedSeason: Value(work.matchedSeason),
            title: Value(work.title),
            originalTitle: Value(work.originalTitle),
            year: Value(work.year),
            overview: Value(work.overview),
            posterPath: Value(work.posterPath),
            posterFallback: Value(work.posterFallback),
            bangumiPosterPath: Value(work.bangumiPosterPath),
            backdropPath: Value(work.backdropPath),
            logoPath: Value(work.logoPath),
            voteAverage: Value(work.voteAverage),
            bangumiScore: Value(work.bangumiScore),
            folderTmdbHint: Value(work.folderTmdbHint),
            isManualLocked: Value(work.isManualLocked),
            metadataLocked: Value(work.metadataLocked),
            posterLocked: Value(work.posterLocked),
            backdropLocked: Value(work.backdropLocked),
            isHidden: Value(work.isHidden),
            keepHidden: Value(work.keepHidden),
            scrapeStatus: Value(work.scrapeStatus),
            reviewReason: Value(work.reviewReason),
            seriesId: Value(work.seriesId),
            seriesOrder: Value(work.seriesOrder),
            seriesLabel: Value(work.seriesLabel),
            seriesLocked: Value(work.seriesLocked),
          ),
        );
  }

  @override
  Future<Work?> findWorkById(String workId) async {
    final query = _db.select(_db.works)..where((t) => t.id.equals(workId));
    final row = await query.getSingleOrNull();
    return row == null ? null : _mapWork(row);
  }

  @override
  Future<List<Work>> getAllWorks() async {
    final rows = await _db.select(_db.works).get();
    return [for (final row in rows) _mapWork(row)];
  }

  @override
  Future<void> upsertEpisode(Episode episode) async {
    await _db
        .into(_db.episodes)
        .insertOnConflictUpdate(
          EpisodesCompanion(
            id: Value(episode.id),
            workId: Value(episode.workId),
            seasonNumber: Value(episode.seasonNumber),
            episodeNumber: Value(episode.episodeNumber),
            category: Value(episode.category),
            extraType: Value(episode.extraType),
            title: Value(episode.title),
            overview: Value(episode.overview),
            stillPath: Value(episode.stillPath),
          ),
        );
  }

  @override
  Future<List<Episode>> getEpisodesByWork(String workId) async {
    final query = _db.select(_db.episodes)
      ..where((t) => t.workId.equals(workId))
      ..orderBy([
        (t) => OrderingTerm.asc(t.seasonNumber),
        (t) => OrderingTerm.asc(t.episodeNumber),
      ]);
    final rows = await query.get();
    return Episode.sortMainFirst([
      for (final row in rows)
        Episode(
          id: row.id,
          workId: row.workId,
          seasonNumber: row.seasonNumber,
          episodeNumber: row.episodeNumber,
          category: row.category,
          extraType: row.extraType,
          title: row.title,
          overview: row.overview,
          stillPath: row.stillPath,
        ),
    ]);
  }

  @override
  Future<void> upsertMediaVariant(MediaVariant variant) async {
    await _db
        .into(_db.mediaVariants)
        .insertOnConflictUpdate(
          MediaVariantsCompanion(
            id: Value(variant.id),
            workId: Value(variant.workId),
            episodeId: Value(variant.episodeId),
            sourceId: Value(variant.sourceId),
            relativePath: Value(variant.relativePath),
            fileName: Value(variant.fileName),
            fileSize: Value(variant.fileSize),
            assetKind: Value(variant.assetKind),
            releaseGroup: Value(variant.releaseGroup),
            subtitleGroup: Value(variant.subtitleGroup),
            videoCodec: Value(variant.videoCodec),
            bitDepth: Value(variant.bitDepth),
            resolution: Value(variant.resolution),
            audioCodec: Value(variant.audioCodec),
            externalSubtitlesJson: Value(
              jsonEncode(variant.externalSubtitles),
            ),
            mappingLocked: Value(variant.mappingLocked),
            workLocked: Value(variant.workLocked),
            assetScope: Value(variant.assetScope),
            scopeLocked: Value(variant.scopeLocked),
          ),
        );
  }

  @override
  Future<List<MediaVariant>> getVariantsByWork(String workId) async {
    final query = _db.select(_db.mediaVariants)
      ..where((t) => t.workId.equals(workId));
    final rows = await query.get();
    return [for (final row in rows) _mapVariant(row)];
  }

  @override
  Future<List<MediaVariant>> getVariantsBySource(String sourceId) async {
    final query = _db.select(_db.mediaVariants)
      ..where((t) => t.sourceId.equals(sourceId));
    final rows = await query.get();
    return [for (final row in rows) _mapVariant(row)];
  }

  MediaVariant _mapVariant(MediaVariantRow row) => MediaVariant(
    id: row.id,
    workId: row.workId,
    episodeId: row.episodeId,
    sourceId: row.sourceId,
    relativePath: row.relativePath,
    fileName: row.fileName,
    fileSize: row.fileSize,
    assetKind: row.assetKind,
    releaseGroup: row.releaseGroup,
    subtitleGroup: row.subtitleGroup,
    videoCodec: row.videoCodec,
    bitDepth: row.bitDepth,
    resolution: row.resolution,
    audioCodec: row.audioCodec,
    externalSubtitles: _decodeSubtitles(row.externalSubtitlesJson),
    mappingLocked: row.mappingLocked,
    workLocked: row.workLocked,
    assetScope: row.assetScope,
    scopeLocked: row.scopeLocked,
  );

  @override
  Future<void> upsertExternalPlayer(ExternalPlayerConfig config) async {
    await _db
        .into(_db.externalPlayers)
        .insertOnConflictUpdate(
          ExternalPlayersCompanion(
            id: Value(config.id),
            name: Value(config.name),
            kind: Value(config.kind),
            executablePath: Value(config.executablePath),
            argumentsTemplate: Value(config.argumentsTemplate),
            isDefault: Value(config.isDefault),
          ),
        );
  }

  @override
  Future<List<ExternalPlayerConfig>> getExternalPlayers() async {
    final rows = await _db.select(_db.externalPlayers).get();
    return [
      for (final row in rows)
        ExternalPlayerConfig(
          id: row.id,
          name: row.name,
          kind: row.kind,
          executablePath: row.executablePath,
          argumentsTemplate: row.argumentsTemplate,
          isDefault: row.isDefault,
        ),
    ];
  }

  @override
  Future<void> saveScrapeCandidates(
    String workId,
    List<ScrapeCandidateSummary> candidates,
  ) => saveScrapeCandidatesInDb(_db, workId, candidates);

  @override
  Future<List<ScrapeCandidateSummary>> getScrapeCandidates(String workId) =>
      readScrapeCandidatesInDb(_db, workId);

  @override
  Future<void> clearScrapeCandidates(String workId) async {
    await (_db.delete(
      _db.scrapeCandidates,
    )..where((t) => t.workId.equals(workId))).go();
  }

  @override
  Future<void> deleteMediaSource(String sourceId) async {
    await (_db.delete(
      _db.mediaSources,
    )..where((t) => t.id.equals(sourceId))).go();
  }

  @override
  Future<void> pruneStaleSourceEntries({
    required String sourceId,
    required Set<String> activeWorkIds,
    required Set<String> activeVariantIds,
    List<String> scopedRoots = const [],
  }) => pruneStaleSourceEntriesInDb(
    _db,
    sourceId: sourceId,
    activeWorkIds: activeWorkIds,
    activeVariantIds: activeVariantIds,
    scopedRoots: scopedRoots,
  );

  @override
  Future<void> recordPlayback(PlaybackRecord record) =>
      upsertPlaybackRecordInDb(_db, record);

  @override
  Future<List<PlaybackRecord>> getPlaybackHistory({int limit = 100}) =>
      readPlaybackHistoryInDb(_db, limit: limit);

  @override
  Future<List<PlaybackRecord>> getPlaybacksByWork(String workId) =>
      readPlaybacksByWorkInDb(_db, workId);

  @override
  Future<PlaybackRecord?> getLatestPlaybackForWork(String workId) =>
      readLatestPlaybackForWorkInDb(_db, workId);

  @override
  Future<void> deletePlaybackRecord(String recordId) async {
    await (_db.delete(
      _db.playbackRecords,
    )..where((t) => t.id.equals(recordId))).go();
  }

  @override
  Future<void> clearPlaybackHistory() async {
    await _db.delete(_db.playbackRecords).go();
  }

  Work _mapWork(WorkRow row) => Work(
    id: row.id,
    tmdbId: row.tmdbId,
    bangumiId: row.bangumiId,
    tmdbMediaType: row.tmdbMediaType,
    matchedSeason: row.matchedSeason,
    title: row.title,
    originalTitle: row.originalTitle,
    year: row.year,
    overview: row.overview,
    posterPath: row.posterPath,
    posterFallback: row.posterFallback,
    bangumiPosterPath: row.bangumiPosterPath,
    backdropPath: row.backdropPath,
    logoPath: row.logoPath,
    voteAverage: row.voteAverage,
    bangumiScore: row.bangumiScore,
    folderTmdbHint: row.folderTmdbHint,
    isManualLocked: row.isManualLocked,
    metadataLocked: row.metadataLocked,
    posterLocked: row.posterLocked,
    backdropLocked: row.backdropLocked,
    isHidden: row.isHidden,
    keepHidden: row.keepHidden,
    scrapeStatus: row.scrapeStatus,
    reviewReason: row.reviewReason,
    seriesId: row.seriesId,
    seriesOrder: row.seriesOrder,
    seriesLabel: row.seriesLabel,
    seriesLocked: row.seriesLocked,
  );

  @override
  Future<void> setWorkHidden(
    String workId, {
    required bool isHidden,
    bool? keepHidden,
  }) async {
    await (_db.update(_db.works)..where((t) => t.id.equals(workId))).write(
      WorksCompanion(
        isHidden: Value(isHidden),
        keepHidden: keepHidden != null ? Value(keepHidden) : const Value.absent(),
      ),
    );
  }

  @override
  Future<void> deleteWork(String workId) => deleteWorkInDb(_db, workId);

  @override
  Future<void> deleteOrphanEpisodes(String workId) =>
      deleteOrphanEpisodesInDb(_db, workId);

  @override
  Future<void> addIgnoredFolder(String sourceId, String relativePath) =>
      addIgnoredFolderInDb(_db, sourceId, relativePath);

  @override
  Future<List<String>> getIgnoredFolders(String sourceId) =>
      readIgnoredFoldersInDb(_db, sourceId);

  @override
  Future<void> removeIgnoredFolder(String sourceId, String relativePath) =>
      removeIgnoredFolderInDb(_db, sourceId, relativePath);

  @override
  Future<void> upsertSeriesGroup(SeriesGroup group) =>
      upsertSeriesGroupInDb(_db, group);

  @override
  Future<SeriesGroup?> findSeriesGroupById(String seriesId) =>
      findSeriesGroupByIdInDb(_db, seriesId);

  @override
  Future<List<SeriesGroup>> getAllSeriesGroups() =>
      getAllSeriesGroupsInDb(_db);

  @override
  Future<void> deleteSeriesGroup(String seriesId) =>
      deleteSeriesGroupInDb(_db, seriesId);

  List<String> _decodeSubtitles(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! List) return const [];
    return [for (final item in decoded) item.toString()];
  }
}
