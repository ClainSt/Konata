import 'dart:async';
import 'dart:convert';

import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';

import '../models/artwork_ref_codec.dart';
import '../models/episode.dart';
import '../models/media_source.dart';
import '../models/media_variant.dart';
import '../models/playback_record.dart';
import '../models/series_group.dart';
import '../models/tmdb_models.dart';
import '../models/work.dart';
import 'library_repository.dart';

final Object _txZoneKey = Object();

final class _AsyncTxContext {
  int depth = 0;
  int savepointCounter = 0;
  final Set<String> dirtyLibraryTables = <String>{};
}

typedef _SqlExec =
    void Function(String sql, List<Object?> params, Set<String> affectedTables);

/// 基于 `konata_storage` 三库合一实例（[KonataDatabaseBundle]）的 [LibraryRepository] 实现。
///
/// - `library.db`：存储 `media_sources`、`series_groups`、`works`、`episodes`、`media_variants`、`ignored_folders`；
/// - `user_state.db`：存储 `playback_records`；
/// - `cache.db`：存储 `scrape_candidates` 与 `artwork_negative_cache`（Logo 负缓存冷却）；
/// - 作品艺术图通过 [ArtworkRefCodec] 无损转换为 `ArtworkRef.remote(...)` / `ArtworkRef.localCustom(...)` 落盘。
final class StorageScrapeRepository implements LibraryRepository {
  /// 使用三库合一门面构造持久化仓储；可选指定当前设备标识与时间源。
  StorageScrapeRepository(
    this._bundle, {
    this.sourceDeviceId = '',
    int Function()? nowMs,
  }) : _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  final KonataDatabaseBundle _bundle;

  /// 写入记录时附带的来源设备标识。
  final String sourceDeviceId;

  final int Function() _nowMs;
  Future<void> _txMutexTail = Future<void>.value();

  LibraryDatabase get _lib => _bundle.library;
  UserStateDatabase get _user => _bundle.userState;
  CacheDatabase get _cache => _bundle.cache;

  @override
  Future<T> runInTransaction<T>(Future<T> Function() action) async {
    final existingCtx = Zone.current[_txZoneKey] as _AsyncTxContext?;
    if (existingCtx != null) {
      final sp = 'konata_scrape_sp_${++existingCtx.savepointCounter}';
      _lib.engine.execute('SAVEPOINT $sp;');
      existingCtx.depth++;
      try {
        final result = await action();
        _lib.engine.execute('RELEASE SAVEPOINT $sp;');
        return result;
      } catch (_) {
        _lib.engine.execute('ROLLBACK TO SAVEPOINT $sp;');
        _lib.engine.execute('RELEASE SAVEPOINT $sp;');
        rethrow;
      } finally {
        existingCtx.depth--;
      }
    }

    final previous = _txMutexTail;
    final done = Completer<void>();
    _txMutexTail = done.future;
    await previous;

    final ctx = _AsyncTxContext()..depth = 1;
    try {
      _lib.engine.execute('BEGIN IMMEDIATE;');
      final result = await runZoned(
        action,
        zoneValues: <Object, Object?>{_txZoneKey: ctx},
      );
      _lib.engine.execute('COMMIT;');
      if (ctx.dirtyLibraryTables.isNotEmpty) {
        _lib.engine.changeBus.notifyTables(ctx.dirtyLibraryTables);
      }
      return result;
    } catch (_) {
      try {
        _lib.engine.execute('ROLLBACK;');
      } catch (_) {
        // 事务已自动回滚时保留原始异常继续上抛。
      }
      rethrow;
    } finally {
      done.complete();
    }
  }

  void _writeLibrarySql(
    String sql,
    List<Object?> params,
    Set<String> affectedTables,
  ) {
    final ctx = Zone.current[_txZoneKey] as _AsyncTxContext?;
    if (ctx != null) {
      _lib.engine.execute(sql, params);
      ctx.dirtyLibraryTables.addAll(affectedTables);
    } else {
      _lib.engine.execute(sql, params, affectedTables);
    }
  }

  void _runAtomicLibraryWrite(void Function(_SqlExec exec) body) {
    final ctx = Zone.current[_txZoneKey] as _AsyncTxContext?;
    if (ctx != null) {
      final sp = 'konata_scrape_op_${++ctx.savepointCounter}';
      _lib.engine.execute('SAVEPOINT $sp;');
      try {
        body(_writeLibrarySql);
        _lib.engine.execute('RELEASE SAVEPOINT $sp;');
      } catch (_) {
        _lib.engine.execute('ROLLBACK TO SAVEPOINT $sp;');
        _lib.engine.execute('RELEASE SAVEPOINT $sp;');
        rethrow;
      }
      return;
    }
    _lib.engine.runTransaction(
      (tx) => body((sql, params, tables) => tx.execute(sql, params, tables)),
    );
  }

  // 媒体源管理接口实现。

  @override
  Future<void> upsertMediaSource(MediaSource source) async {
    final existing = _lib.mediaSources.findById(
      SourceId.trusted(source.id),
      includeDeleted: true,
    );
    final now = _nowMs();
    final canonicalKey =
        existing?.canonicalKey ?? 'source:${source.kind.name}:${source.id}';
    final createdAtMs =
        source.createdAt?.millisecondsSinceEpoch ??
        existing?.createdAtMs ??
        now;
    _runAtomicLibraryWrite((exec) {
      exec(
        '''
INSERT INTO ${MediaSourcesSchema.table} (
  ${MediaSourcesSchema.colId},
  ${MediaSourcesSchema.colCanonicalKey},
  ${MediaSourcesSchema.colKind},
  ${MediaSourcesSchema.colLabel},
  ${MediaSourcesSchema.colLocation},
  ${MediaSourcesSchema.colUsername},
  ${MediaSourcesSchema.colCreatedAtMs},
  ${MediaSourcesSchema.colUpdatedAtMs},
  ${MediaSourcesSchema.colSourceDeviceId},
  ${MediaSourcesSchema.colDeletedAtMs}
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)
ON CONFLICT(${MediaSourcesSchema.colId}) DO UPDATE SET
  ${MediaSourcesSchema.colCanonicalKey} = excluded.${MediaSourcesSchema.colCanonicalKey},
  ${MediaSourcesSchema.colKind} = excluded.${MediaSourcesSchema.colKind},
  ${MediaSourcesSchema.colLabel} = excluded.${MediaSourcesSchema.colLabel},
  ${MediaSourcesSchema.colLocation} = excluded.${MediaSourcesSchema.colLocation},
  ${MediaSourcesSchema.colUsername} = excluded.${MediaSourcesSchema.colUsername},
  ${MediaSourcesSchema.colCreatedAtMs} = excluded.${MediaSourcesSchema.colCreatedAtMs},
  ${MediaSourcesSchema.colUpdatedAtMs} = excluded.${MediaSourcesSchema.colUpdatedAtMs},
  ${MediaSourcesSchema.colSourceDeviceId} = excluded.${MediaSourcesSchema.colSourceDeviceId},
  ${MediaSourcesSchema.colDeletedAtMs} = NULL;
''',
        <Object?>[
          source.id,
          canonicalKey,
          source.kind.name,
          source.label,
          source.location,
          source.username,
          createdAtMs,
          now,
          sourceDeviceId,
        ],
        const <String>{MediaSourcesSchema.table},
      );
    });
  }

  @override
  Future<MediaSource?> findSourceById(String sourceId) async {
    final rec = _lib.mediaSources.findById(SourceId.trusted(sourceId));
    return rec == null ? null : _mapMediaSource(rec);
  }

  @override
  Future<List<MediaSource>> getMediaSources() async {
    return <MediaSource>[
      for (final rec in _lib.mediaSources.listAll()) _mapMediaSource(rec),
    ];
  }

  @override
  Future<void> deleteMediaSource(String sourceId) async {
    _writeLibrarySql(
      'DELETE FROM ${MediaSourcesSchema.table} '
      'WHERE ${MediaSourcesSchema.colId} = ?;',
      <Object?>[sourceId],
      const <String>{
        MediaSourcesSchema.table,
        MediaVariantsSchema.table,
        IgnoredFoldersSchema.table,
      },
    );
  }

  // 作品主表读写实现。

  @override
  Future<void> upsertWork(Work work) async {
    final now = _nowMs();
    final existing = _lib.works.findById(
      WorkId.trusted(work.id),
      includeDeleted: true,
    );
    final canonicalKey =
        existing?.canonicalKey ?? _deriveWorkCanonicalKey(work);
    final posterRef = ArtworkRefCodec.fromPath(
      work.posterPath,
      locked: work.posterLocked,
    );
    final backdropRef = ArtworkRefCodec.fromPath(
      work.backdropPath,
      locked: work.backdropLocked,
    );
    final portraitBackdropRef = ArtworkRefCodec.fromPath(
      work.portraitBackdropPath,
      locked: work.portraitBackdropLocked,
    );
    final logoRef = ArtworkRefCodec.fromPath(
      work.logoPath,
      locked: work.logoLocked,
    );
    _runAtomicLibraryWrite((exec) {
      exec(
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
  ${WorksSchema.colPortraitBackdropRefJson},
  ${WorksSchema.colLogoRefJson},
  ${WorksSchema.colVoteAverage},
  ${WorksSchema.colBangumiScore},
  ${WorksSchema.colFolderTmdbHint},
  ${WorksSchema.colIsManualLocked},
  ${WorksSchema.colMetadataLocked},
  ${WorksSchema.colScrapeStatus},
  ${WorksSchema.colReviewReason},
  ${WorksSchema.colSeriesId},
  ${WorksSchema.colSeriesOrder},
  ${WorksSchema.colSeriesLabel},
  ${WorksSchema.colSeriesLocked},
  ${WorksSchema.colUpdatedAtMs},
  ${WorksSchema.colSourceDeviceId},
  ${WorksSchema.colDeletedAtMs}
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)
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
  ${WorksSchema.colPortraitBackdropRefJson} = excluded.${WorksSchema.colPortraitBackdropRefJson},
  ${WorksSchema.colLogoRefJson} = excluded.${WorksSchema.colLogoRefJson},
  ${WorksSchema.colVoteAverage} = excluded.${WorksSchema.colVoteAverage},
  ${WorksSchema.colBangumiScore} = excluded.${WorksSchema.colBangumiScore},
  ${WorksSchema.colFolderTmdbHint} = excluded.${WorksSchema.colFolderTmdbHint},
  ${WorksSchema.colIsManualLocked} = excluded.${WorksSchema.colIsManualLocked},
  ${WorksSchema.colMetadataLocked} = excluded.${WorksSchema.colMetadataLocked},
  ${WorksSchema.colScrapeStatus} = excluded.${WorksSchema.colScrapeStatus},
  ${WorksSchema.colReviewReason} = excluded.${WorksSchema.colReviewReason},
  ${WorksSchema.colSeriesId} = excluded.${WorksSchema.colSeriesId},
  ${WorksSchema.colSeriesOrder} = excluded.${WorksSchema.colSeriesOrder},
  ${WorksSchema.colSeriesLabel} = excluded.${WorksSchema.colSeriesLabel},
  ${WorksSchema.colSeriesLocked} = excluded.${WorksSchema.colSeriesLocked},
  ${WorksSchema.colUpdatedAtMs} = excluded.${WorksSchema.colUpdatedAtMs},
  ${WorksSchema.colSourceDeviceId} = excluded.${WorksSchema.colSourceDeviceId},
  ${WorksSchema.colDeletedAtMs} = NULL;
''',
        <Object?>[
          work.id,
          canonicalKey,
          work.tmdbId,
          work.tmdbMediaType?.name,
          work.bangumiId,
          work.tvdbId,
          work.matchedSeason,
          work.title,
          work.originalTitle,
          work.year,
          work.overview,
          posterRef == null ? null : jsonEncode(posterRef.toLocalJson()),
          work.posterFallback,
          work.bangumiPosterPath,
          backdropRef == null ? null : jsonEncode(backdropRef.toLocalJson()),
          portraitBackdropRef == null
              ? null
              : jsonEncode(portraitBackdropRef.toLocalJson()),
          logoRef == null ? null : jsonEncode(logoRef.toLocalJson()),
          work.voteAverage,
          work.bangumiScore,
          work.folderTmdbHint,
          work.isManualLocked ? 1 : 0,
          work.metadataLocked ? 1 : 0,
          work.scrapeStatus.name,
          work.reviewReason,
          work.seriesId,
          work.seriesOrder,
          work.seriesLabel,
          work.seriesLocked ? 1 : 0,
          now,
          sourceDeviceId,
        ],
        const <String>{WorksSchema.table},
      );
    });

    final workId = WorkId.trusted(work.id);
    if (work.logoNegativeUntil != null || work.logoNegativeMask != 0) {
      _cache.artworkNegativeCache.upsert(
        ArtworkNegativeCacheRecord(
          workId: workId,
          slot: ArtworkSlot.logo,
          negativeUntilMs:
              work.logoNegativeUntil?.toUtc().millisecondsSinceEpoch ?? 0,
          probedSourceMask: work.logoNegativeMask,
          updatedAtMs: now,
        ),
      );
    } else {
      _cache.engine.execute(
        'DELETE FROM ${ArtworkNegativeCacheSchema.table} '
        'WHERE ${ArtworkNegativeCacheSchema.colWorkId} = ? '
        'AND ${ArtworkNegativeCacheSchema.colSlot} = ?;',
        <Object?>[work.id, ArtworkSlot.logo.name],
        const <String>{ArtworkNegativeCacheSchema.table},
      );
    }
  }

  @override
  Future<Work?> findWorkById(String workId) async {
    final rec = _lib.works.findById(WorkId.trusted(workId));
    if (rec == null) return null;
    final neg = _cache.artworkNegativeCache.find(
      WorkId.trusted(workId),
      ArtworkSlot.logo,
    );
    return _mapWork(rec, neg);
  }

  @override
  Future<List<Work>> getAllWorks() async {
    final negByWork = _loadAllLogoNegatives();
    final records = _lib.works.listAllWithTombstones().where(
      (r) => !r.isDeleted,
    );
    return <Work>[
      for (final rec in records) _mapWork(rec, negByWork[rec.id.value]),
    ];
  }

  @override
  Future<List<Work>> getWorksBySeries(String seriesId) async {
    final negByWork = _loadAllLogoNegatives();
    final rs = _lib.engine.select(
      'SELECT * FROM ${WorksSchema.table} '
      'WHERE ${WorksSchema.colSeriesId} = ? '
      'AND ${WorksSchema.colDeletedAtMs} IS NULL;',
      <Object?>[seriesId],
    );
    return <Work>[
      for (final row in rs)
        _mapWorkRow(row, negByWork[row[WorksSchema.colId] as String]),
    ];
  }

  @override
  Future<void> deleteWork(String workId) async {
    _runAtomicLibraryWrite((exec) {
      exec(
        'DELETE FROM ${MediaVariantsSchema.table} '
        'WHERE ${MediaVariantsSchema.colWorkId} = ?;',
        <Object?>[workId],
        const <String>{MediaVariantsSchema.table},
      );
      exec(
        'DELETE FROM ${EpisodesSchema.table} '
        'WHERE ${EpisodesSchema.colWorkId} = ?;',
        <Object?>[workId],
        const <String>{EpisodesSchema.table},
      );
      exec(
        'DELETE FROM ${WorksSchema.table} WHERE ${WorksSchema.colId} = ?;',
        <Object?>[workId],
        const <String>{WorksSchema.table},
      );
    });
    _cache.scrapeCandidates.clearForWork(WorkId.trusted(workId));
    _cache.engine.execute(
      'DELETE FROM ${ArtworkNegativeCacheSchema.table} '
      'WHERE ${ArtworkNegativeCacheSchema.colWorkId} = ?;',
      <Object?>[workId],
      const <String>{ArtworkNegativeCacheSchema.table},
    );
    _user.engine.execute(
      'DELETE FROM ${PlaybackRecordsSchema.table} '
      'WHERE ${PlaybackRecordsSchema.colWorkId} = ?;',
      <Object?>[workId],
      const <String>{PlaybackRecordsSchema.table},
    );
  }

  // 逻辑剧集管理实现。

  @override
  Future<void> upsertEpisode(Episode episode) =>
      upsertEpisodesBatch(<Episode>[episode]);

  @override
  Future<void> upsertEpisodesBatch(List<Episode> episodes) async {
    if (episodes.isEmpty) return;
    final now = _nowMs();
    _runAtomicLibraryWrite((exec) {
      for (final ep in episodes) {
        exec(
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
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)
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
  ${EpisodesSchema.colDeletedAtMs} = NULL;
''',
          <Object?>[
            ep.id,
            '${ep.workId}:${ep.category.name}:s${ep.seasonNumber}:e${ep.episodeNumber ?? ep.id}',
            ep.workId,
            ep.seasonNumber,
            ep.episodeNumber,
            ep.episodeNumberEnd,
            ep.category.name,
            ep.extraType?.name,
            ep.title,
            ep.overview,
            ep.stillPath,
            now,
            sourceDeviceId,
          ],
          const <String>{EpisodesSchema.table},
        );
      }
    });
  }

  @override
  Future<List<Episode>> getEpisodesByWork(String workId) async {
    return <Episode>[
      for (final rec in _lib.episodes.listByWork(WorkId.trusted(workId)))
        _mapEpisode(rec),
    ];
  }

  @override
  Future<List<Episode>> getAllEpisodes() async {
    final rs = _lib.engine.select(
      'SELECT * FROM ${EpisodesSchema.table} '
      'WHERE ${EpisodesSchema.colDeletedAtMs} IS NULL '
      'ORDER BY ${EpisodesSchema.colWorkId} ASC, '
      '${EpisodesSchema.colSeasonNumber} ASC, '
      '${EpisodesSchema.colEpisodeNumber} ASC, ${EpisodesSchema.colId} ASC;',
    );
    return <Episode>[for (final row in rs) _mapEpisodeRow(row)];
  }

  @override
  Future<List<Episode>> getEpisodesByWorkIds(List<String> workIds) async {
    if (workIds.isEmpty) return const <Episode>[];
    final out = <Episode>[];
    const chunkSize = 400;
    for (var i = 0; i < workIds.length; i += chunkSize) {
      final end = (i + chunkSize) > workIds.length
          ? workIds.length
          : i + chunkSize;
      final chunk = workIds.sublist(i, end);
      final placeholders = List<String>.filled(chunk.length, '?').join(', ');
      final rs = _lib.engine.select(
        'SELECT * FROM ${EpisodesSchema.table} '
        'WHERE ${EpisodesSchema.colWorkId} IN ($placeholders) '
        'AND ${EpisodesSchema.colDeletedAtMs} IS NULL;',
        chunk,
      );
      for (final row in rs) {
        out.add(_mapEpisodeRow(row));
      }
    }
    return out;
  }

  @override
  Future<void> deleteOrphanEpisodes(String workId) async {
    final rs = _lib.engine.select(
      'SELECT DISTINCT ${MediaVariantsSchema.colEpisodeId} '
      'FROM ${MediaVariantsSchema.table} '
      'WHERE ${MediaVariantsSchema.colWorkId} = ? '
      'AND ${MediaVariantsSchema.colDeletedAtMs} IS NULL '
      'AND ${MediaVariantsSchema.colEpisodeId} IS NOT NULL;',
      <Object?>[workId],
    );
    final referencedIds = <String>{
      for (final row in rs) row[MediaVariantsSchema.colEpisodeId] as String,
    };
    final epRows = _lib.engine.select(
      'SELECT ${EpisodesSchema.colId} FROM ${EpisodesSchema.table} '
      'WHERE ${EpisodesSchema.colWorkId} = ?;',
      <Object?>[workId],
    );
    final orphanIds = <String>[
      for (final row in epRows)
        if (!referencedIds.contains(row[EpisodesSchema.colId] as String))
          row[EpisodesSchema.colId] as String,
    ];
    if (orphanIds.isEmpty) return;
    const chunkSize = 400;
    _runAtomicLibraryWrite((exec) {
      for (var i = 0; i < orphanIds.length; i += chunkSize) {
        final end = (i + chunkSize) > orphanIds.length
            ? orphanIds.length
            : i + chunkSize;
        final chunk = orphanIds.sublist(i, end);
        final placeholders = List<String>.filled(chunk.length, '?').join(', ');
        exec(
          'DELETE FROM ${EpisodesSchema.table} '
          'WHERE ${EpisodesSchema.colId} IN ($placeholders);',
          chunk,
          const <String>{EpisodesSchema.table},
        );
      }
    });
  }

  // 物理文件版本读写实现。

  @override
  Future<void> upsertMediaVariant(MediaVariant variant) =>
      upsertMediaVariantsBatch(<MediaVariant>[variant]);

  @override
  Future<void> upsertMediaVariantsBatch(List<MediaVariant> variants) async {
    if (variants.isEmpty) return;
    final now = _nowMs();
    _runAtomicLibraryWrite((exec) {
      for (final v in variants) {
        exec(
          '''
INSERT INTO ${MediaVariantsSchema.table} (
  ${MediaVariantsSchema.colId},
  ${MediaVariantsSchema.colCanonicalKey},
  ${MediaVariantsSchema.colWorkId},
  ${MediaVariantsSchema.colEpisodeId},
  ${MediaVariantsSchema.colSourceId},
  ${MediaVariantsSchema.colRelativePath},
  ${MediaVariantsSchema.colRemoteFileId},
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
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)
ON CONFLICT(${MediaVariantsSchema.colId}) DO UPDATE SET
  ${MediaVariantsSchema.colCanonicalKey} = excluded.${MediaVariantsSchema.colCanonicalKey},
  ${MediaVariantsSchema.colWorkId} = excluded.${MediaVariantsSchema.colWorkId},
  ${MediaVariantsSchema.colEpisodeId} = excluded.${MediaVariantsSchema.colEpisodeId},
  ${MediaVariantsSchema.colSourceId} = excluded.${MediaVariantsSchema.colSourceId},
  ${MediaVariantsSchema.colRelativePath} = excluded.${MediaVariantsSchema.colRelativePath},
  ${MediaVariantsSchema.colRemoteFileId} = excluded.${MediaVariantsSchema.colRemoteFileId},
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
  ${MediaVariantsSchema.colDeletedAtMs} = NULL;
''',
          <Object?>[
            v.id,
            '${v.sourceId}::${v.relativePath}',
            v.workId,
            v.episodeId,
            v.sourceId,
            v.relativePath,
            v.remoteFileId,
            v.fileName,
            v.fileSize,
            v.assetKind.name,
            v.releaseGroup,
            v.subtitleGroup,
            v.videoCodec,
            v.bitDepth,
            v.resolution,
            v.audioCodec,
            jsonEncode(v.externalSubtitles),
            v.mappingLocked ? 1 : 0,
            v.workLocked ? 1 : 0,
            v.assetScope.name,
            v.scopeLocked ? 1 : 0,
            now,
            sourceDeviceId,
          ],
          const <String>{MediaVariantsSchema.table},
        );
      }
    });
  }

  @override
  Future<void> deleteMediaVariantsBatch(List<String> variantIds) async {
    if (variantIds.isEmpty) return;
    const chunkSize = 200;
    _runAtomicLibraryWrite((exec) {
      for (var i = 0; i < variantIds.length; i += chunkSize) {
        final end = (i + chunkSize) > variantIds.length
            ? variantIds.length
            : i + chunkSize;
        final chunk = variantIds.sublist(i, end);
        final placeholders = List<String>.filled(chunk.length, '?').join(', ');
        exec(
          'DELETE FROM ${MediaVariantsSchema.table} '
          'WHERE ${MediaVariantsSchema.colId} IN ($placeholders);',
          chunk,
          const <String>{MediaVariantsSchema.table},
        );
      }
    });
  }

  @override
  Future<List<MediaVariant>> getVariantsByWork(String workId) async {
    return <MediaVariant>[
      for (final rec in _lib.mediaVariants.listByWork(WorkId.trusted(workId)))
        _mapVariant(rec),
    ];
  }

  @override
  Future<List<MediaVariant>> getVariantsByWorkIds(List<String> workIds) async {
    if (workIds.isEmpty) return const <MediaVariant>[];
    final out = <MediaVariant>[];
    const chunkSize = 400;
    for (var i = 0; i < workIds.length; i += chunkSize) {
      final end = (i + chunkSize) > workIds.length
          ? workIds.length
          : i + chunkSize;
      final chunk = workIds.sublist(i, end);
      final placeholders = List<String>.filled(chunk.length, '?').join(', ');
      final rs = _lib.engine.select(
        'SELECT * FROM ${MediaVariantsSchema.table} '
        'WHERE ${MediaVariantsSchema.colWorkId} IN ($placeholders) '
        'AND ${MediaVariantsSchema.colDeletedAtMs} IS NULL;',
        chunk,
      );
      for (final row in rs) {
        out.add(_mapVariantRow(row));
      }
    }
    return out;
  }

  @override
  Future<List<MediaVariant>> getVariantsBySource(String sourceId) async {
    final rs = _lib.engine.select(
      'SELECT * FROM ${MediaVariantsSchema.table} '
      'WHERE ${MediaVariantsSchema.colSourceId} = ? '
      'AND ${MediaVariantsSchema.colDeletedAtMs} IS NULL;',
      <Object?>[sourceId],
    );
    return <MediaVariant>[for (final row in rs) _mapVariantRow(row)];
  }

  @override
  Future<List<MediaVariant>> getAllVariants() async {
    final rs = _lib.engine.select(
      'SELECT * FROM ${MediaVariantsSchema.table} '
      'WHERE ${MediaVariantsSchema.colDeletedAtMs} IS NULL;',
    );
    return <MediaVariant>[for (final row in rs) _mapVariantRow(row)];
  }

  // 待复核候选与源条目修剪实现。

  @override
  Future<void> saveScrapeCandidates(
    String workId,
    List<ScrapeCandidateSummary> candidates,
  ) async {
    final now = _nowMs();
    final typedWorkId = WorkId.trusted(workId);
    final records = <ScrapeCandidateRecord>[
      for (final c in candidates)
        ScrapeCandidateRecord(
          workId: typedWorkId,
          rank: c.rank,
          tmdbId: c.tmdbId,
          mediaType: c.mediaType,
          title: c.title,
          originalTitle: c.originalTitle,
          year: c.year,
          posterPath: c.posterPath,
          score: c.score,
          reasons: c.reasons,
          episodeCount: c.episodeCount,
          cachedAtMs: now,
        ),
    ];
    _cache.scrapeCandidates.replaceForWork(typedWorkId, records);
  }

  @override
  Future<List<ScrapeCandidateSummary>> getScrapeCandidates(
    String workId,
  ) async {
    final records = _cache.scrapeCandidates.listByWork(WorkId.trusted(workId));
    return <ScrapeCandidateSummary>[
      for (final r in records)
        ScrapeCandidateSummary(
          workId: r.workId.value,
          tmdbId: r.tmdbId,
          mediaType: r.mediaType,
          title: r.title,
          originalTitle: r.originalTitle,
          year: r.year,
          episodeCount: r.episodeCount,
          posterPath: r.posterPath,
          score: r.score,
          rank: r.rank,
          reasons: r.reasons,
        ),
    ];
  }

  @override
  Future<void> clearScrapeCandidates(String workId) async {
    _cache.scrapeCandidates.clearForWork(WorkId.trusted(workId));
  }

  @override
  Future<void> pruneStaleSourceEntries({
    required String sourceId,
    required Set<String> activeWorkIds,
    required Set<String> activeVariantIds,
    List<String> scopedRoots = const [],
  }) async {
    final normalizedRoots = scopedRoots
        .map(
          (r) =>
              r.trim().replaceAll('\\', '/').replaceAll(RegExp(r'^/+|/+$'), ''),
        )
        .where((r) => r.isNotEmpty)
        .toList(growable: false);

    bool inScope(String relativePath) {
      if (normalizedRoots.isEmpty) return true;
      final norm = relativePath
          .trim()
          .replaceAll('\\', '/')
          .replaceAll(RegExp(r'^/+|/+$'), '');
      return normalizedRoots.any(
        (root) => norm == root || norm.startsWith('$root/'),
      );
    }

    await runInTransaction(() async {
      final existingVariants = await getVariantsBySource(sourceId);
      final staleVariantIds = <String>[];
      final worksWithDeletedVariants = <String>{};
      for (final v in existingVariants) {
        if (!inScope(v.relativePath)) continue;
        if (!activeVariantIds.contains(v.id)) {
          staleVariantIds.add(v.id);
          worksWithDeletedVariants.add(v.workId);
        }
      }

      if (staleVariantIds.isNotEmpty) {
        await deleteMediaVariantsBatch(staleVariantIds);
      }

      for (final workId in worksWithDeletedVariants.intersection(
        activeWorkIds,
      )) {
        await deleteOrphanEpisodes(workId);
      }

      final occupiedRows = _lib.engine.select(
        'SELECT DISTINCT ${MediaVariantsSchema.colWorkId} '
        'FROM ${MediaVariantsSchema.table} '
        'WHERE ${MediaVariantsSchema.colDeletedAtMs} IS NULL;',
      );
      final occupiedWorkIds = <String>{
        for (final row in occupiedRows)
          row[MediaVariantsSchema.colWorkId] as String,
      };

      final allWorkRows = _lib.engine.select(
        'SELECT ${WorksSchema.colId} FROM ${WorksSchema.table} '
        'WHERE ${WorksSchema.colDeletedAtMs} IS NULL;',
      );
      final emptyWorkIds = <String>[
        for (final row in allWorkRows)
          if (!activeWorkIds.contains(row[WorksSchema.colId] as String) &&
              !occupiedWorkIds.contains(row[WorksSchema.colId] as String))
            row[WorksSchema.colId] as String,
      ];

      const chunkSize = 400;
      for (var i = 0; i < emptyWorkIds.length; i += chunkSize) {
        final end = (i + chunkSize) > emptyWorkIds.length
            ? emptyWorkIds.length
            : i + chunkSize;
        final chunk = emptyWorkIds.sublist(i, end);
        final placeholders = List<String>.filled(chunk.length, '?').join(', ');
        _writeLibrarySql(
          'DELETE FROM ${EpisodesSchema.table} '
          'WHERE ${EpisodesSchema.colWorkId} IN ($placeholders);',
          chunk,
          const <String>{EpisodesSchema.table},
        );
        _writeLibrarySql(
          'DELETE FROM ${WorksSchema.table} '
          'WHERE ${WorksSchema.colId} IN ($placeholders);',
          chunk,
          const <String>{WorksSchema.table},
        );
      }
    });
  }

  // 播放记录、忽略目录与系列分组实现。

  @override
  Future<void> recordPlayback(PlaybackRecord record) async {
    final now = _nowMs();
    _user.playbackRecords.upsert(
      PlaybackRecordEntity(
        id: record.id,
        canonicalKey:
            '${record.workId}:${record.episodeId}:${record.variantId}',
        workId: WorkId.trusted(record.workId),
        episodeId: EpisodeId.trusted(record.episodeId),
        variantId: VariantId.trusted(record.variantId),
        seasonNumber: record.seasonNumber,
        episodeNumber: record.episodeNumber,
        episodeTitle: record.episodeTitle,
        sourceKind: record.sourceType,
        playedAtMs: record.playedAt.toUtc().millisecondsSinceEpoch,
        positionSeconds: record.positionSeconds,
        durationSeconds: record.durationSeconds,
        isCompleted: record.isCompleted,
        updatedAtMs: now,
        sourceDeviceId: sourceDeviceId,
      ),
    );
  }

  @override
  Future<List<PlaybackRecord>> getPlaybackHistory({int limit = 100}) async {
    return <PlaybackRecord>[
      for (final e in _user.playbackRecords.listRecent(limit: limit))
        _mapPlayback(e),
    ];
  }

  @override
  Future<List<PlaybackRecord>> getPlaybacksByWork(String workId) async {
    final rs = _user.engine.select(
      'SELECT * FROM ${PlaybackRecordsSchema.table} '
      'WHERE ${PlaybackRecordsSchema.colWorkId} = ? '
      'AND ${PlaybackRecordsSchema.colDeletedAtMs} IS NULL '
      'ORDER BY ${PlaybackRecordsSchema.colPlayedAtMs} DESC;',
      <Object?>[workId],
    );
    return <PlaybackRecord>[for (final row in rs) _mapPlaybackRow(row)];
  }

  @override
  Future<PlaybackRecord?> getLatestPlaybackForWork(String workId) async {
    final entity = _user.playbackRecords.findLatestByWork(
      WorkId.trusted(workId),
    );
    return entity == null ? null : _mapPlayback(entity);
  }

  @override
  Future<void> deletePlaybackRecord(String recordId) async {
    _user.engine.execute(
      'DELETE FROM ${PlaybackRecordsSchema.table} '
      'WHERE ${PlaybackRecordsSchema.colId} = ?;',
      <Object?>[recordId],
      const <String>{PlaybackRecordsSchema.table},
    );
  }

  @override
  Future<void> clearPlaybackHistory() async {
    _user.engine.execute(
      'DELETE FROM ${PlaybackRecordsSchema.table};',
      const <Object?>[],
      const <String>{PlaybackRecordsSchema.table},
    );
  }

  @override
  Future<void> addIgnoredFolder(String sourceId, String relativePath) async {
    final normalized = relativePath.trim().replaceAll('\\', '/');
    if (normalized.isEmpty) return;
    final now = _nowMs();
    final id = '$sourceId::$normalized';
    _runAtomicLibraryWrite((exec) {
      exec(
        '''
INSERT INTO ${IgnoredFoldersSchema.table} (
  ${IgnoredFoldersSchema.colId},
  ${IgnoredFoldersSchema.colCanonicalKey},
  ${IgnoredFoldersSchema.colSourceId},
  ${IgnoredFoldersSchema.colRelativePath},
  ${IgnoredFoldersSchema.colCreatedAtMs},
  ${IgnoredFoldersSchema.colUpdatedAtMs},
  ${IgnoredFoldersSchema.colSourceDeviceId},
  ${IgnoredFoldersSchema.colDeletedAtMs}
) VALUES (?, ?, ?, ?, ?, ?, ?, NULL)
ON CONFLICT(${IgnoredFoldersSchema.colId}) DO UPDATE SET
  ${IgnoredFoldersSchema.colCanonicalKey} = excluded.${IgnoredFoldersSchema.colCanonicalKey},
  ${IgnoredFoldersSchema.colSourceId} = excluded.${IgnoredFoldersSchema.colSourceId},
  ${IgnoredFoldersSchema.colRelativePath} = excluded.${IgnoredFoldersSchema.colRelativePath},
  ${IgnoredFoldersSchema.colUpdatedAtMs} = excluded.${IgnoredFoldersSchema.colUpdatedAtMs},
  ${IgnoredFoldersSchema.colSourceDeviceId} = excluded.${IgnoredFoldersSchema.colSourceDeviceId},
  ${IgnoredFoldersSchema.colDeletedAtMs} = NULL;
''',
        <Object?>[id, id, sourceId, normalized, now, now, sourceDeviceId],
        const <String>{IgnoredFoldersSchema.table},
      );
    });
  }

  @override
  Future<List<String>> getIgnoredFolders(String sourceId) async {
    return <String>[
      for (final rec in _lib.ignoredFolders.listBySource(
        SourceId.trusted(sourceId),
      ))
        rec.relativePath,
    ];
  }

  @override
  Future<void> removeIgnoredFolder(String sourceId, String relativePath) async {
    final normalized = relativePath.trim().replaceAll('\\', '/');
    _writeLibrarySql(
      'DELETE FROM ${IgnoredFoldersSchema.table} '
      'WHERE ${IgnoredFoldersSchema.colId} = ?;',
      <Object?>['$sourceId::$normalized'],
      const <String>{IgnoredFoldersSchema.table},
    );
  }

  @override
  Future<void> upsertSeriesGroup(SeriesGroup group) async {
    final existing = _lib.seriesGroups.findById(
      SeriesGroupId.trusted(group.id),
      includeDeleted: true,
    );
    final canonicalKey =
        existing?.canonicalKey ??
        (group.tmdbCollectionId != null
            ? 'tmdb_col:${group.tmdbCollectionId}'
            : 'series:${group.id}');
    _runAtomicLibraryWrite((exec) {
      exec(
        '''
INSERT INTO ${SeriesGroupsSchema.table} (
  ${SeriesGroupsSchema.colId},
  ${SeriesGroupsSchema.colCanonicalKey},
  ${SeriesGroupsSchema.colTitle},
  ${SeriesGroupsSchema.colTmdbCollectionId},
  ${SeriesGroupsSchema.colRootFolderHint},
  ${SeriesGroupsSchema.colCreatedAtMs},
  ${SeriesGroupsSchema.colUpdatedAtMs},
  ${SeriesGroupsSchema.colSourceDeviceId},
  ${SeriesGroupsSchema.colDeletedAtMs}
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL)
ON CONFLICT(${SeriesGroupsSchema.colId}) DO UPDATE SET
  ${SeriesGroupsSchema.colCanonicalKey} = excluded.${SeriesGroupsSchema.colCanonicalKey},
  ${SeriesGroupsSchema.colTitle} = excluded.${SeriesGroupsSchema.colTitle},
  ${SeriesGroupsSchema.colTmdbCollectionId} = excluded.${SeriesGroupsSchema.colTmdbCollectionId},
  ${SeriesGroupsSchema.colRootFolderHint} = excluded.${SeriesGroupsSchema.colRootFolderHint},
  ${SeriesGroupsSchema.colCreatedAtMs} = excluded.${SeriesGroupsSchema.colCreatedAtMs},
  ${SeriesGroupsSchema.colUpdatedAtMs} = excluded.${SeriesGroupsSchema.colUpdatedAtMs},
  ${SeriesGroupsSchema.colSourceDeviceId} = excluded.${SeriesGroupsSchema.colSourceDeviceId},
  ${SeriesGroupsSchema.colDeletedAtMs} = NULL;
''',
        <Object?>[
          group.id,
          canonicalKey,
          group.title,
          group.tmdbCollectionId,
          group.rootFolderHint,
          group.createdAt.toUtc().millisecondsSinceEpoch,
          group.updatedAt.toUtc().millisecondsSinceEpoch,
          sourceDeviceId,
        ],
        const <String>{SeriesGroupsSchema.table},
      );
    });
  }

  @override
  Future<SeriesGroup?> findSeriesGroupById(String seriesId) async {
    final rec = _lib.seriesGroups.findById(SeriesGroupId.trusted(seriesId));
    return rec == null ? null : _mapSeriesGroup(rec);
  }

  @override
  Future<List<SeriesGroup>> getAllSeriesGroups() async {
    return <SeriesGroup>[
      for (final rec in _lib.seriesGroups.listAll()) _mapSeriesGroup(rec),
    ];
  }

  @override
  Future<void> deleteSeriesGroup(String seriesId) async {
    _runAtomicLibraryWrite((exec) {
      exec(
        'UPDATE ${WorksSchema.table} '
        'SET ${WorksSchema.colSeriesId} = NULL, '
        '${WorksSchema.colSeriesOrder} = NULL, '
        '${WorksSchema.colSeriesLabel} = NULL, '
        '${WorksSchema.colSeriesLocked} = 0 '
        'WHERE ${WorksSchema.colSeriesId} = ?;',
        <Object?>[seriesId],
        const <String>{WorksSchema.table},
      );
      exec(
        'DELETE FROM ${SeriesGroupsSchema.table} '
        'WHERE ${SeriesGroupsSchema.colId} = ?;',
        <Object?>[seriesId],
        const <String>{SeriesGroupsSchema.table},
      );
    });
  }

  // 数据模型映射辅助工具。

  Map<String, ArtworkNegativeCacheRecord> _loadAllLogoNegatives() {
    final rs = _cache.engine.select(
      'SELECT * FROM ${ArtworkNegativeCacheSchema.table} '
      'WHERE ${ArtworkNegativeCacheSchema.colSlot} = ?;',
      <Object?>[ArtworkSlot.logo.name],
    );
    final out = <String, ArtworkNegativeCacheRecord>{};
    for (final row in rs) {
      final workId = row[ArtworkNegativeCacheSchema.colWorkId] as String;
      out[workId] = ArtworkNegativeCacheRecord(
        workId: WorkId.trusted(workId),
        slot: ArtworkSlot.logo,
        negativeUntilMs:
            row[ArtworkNegativeCacheSchema.colNegativeUntilMs] as int? ?? 0,
        probedSourceMask:
            row[ArtworkNegativeCacheSchema.colProbedSourceMask] as int? ?? 0,
        updatedAtMs:
            row[ArtworkNegativeCacheSchema.colUpdatedAtMs] as int? ?? 0,
      );
    }
    return out;
  }

  static String? _deriveWorkCanonicalKey(Work work) {
    if (work.tmdbId != null && work.tmdbMediaType != null) {
      final season = work.matchedSeason ?? 1;
      return 'tmdb:${work.tmdbMediaType!.name}:${work.tmdbId}:s$season';
    }
    if (work.bangumiId != null) {
      return 'bgm:${work.bangumiId}';
    }
    return null;
  }

  static MediaSource _mapMediaSource(MediaSourceRecord rec) {
    return MediaSource(
      id: rec.id.value,
      kind: rec.kind,
      label: rec.label,
      location: rec.location,
      username: rec.username,
      createdAt: rec.createdAtMs > 0
          ? DateTime.fromMillisecondsSinceEpoch(rec.createdAtMs)
          : null,
    );
  }

  static Work _mapWork(WorkRecord rec, ArtworkNegativeCacheRecord? logoNeg) {
    final artworks = ArtworkRefCodec.unpackWorkArtworks(
      posterRef: rec.posterRef,
      backdropRef: rec.backdropRef,
      portraitBackdropRef: rec.portraitBackdropRef,
      logoRef: rec.logoRef,
    );
    return Work(
      id: rec.id.value,
      tmdbId: rec.tmdbId,
      tmdbMediaType: rec.tmdbMediaType,
      bangumiId: rec.bangumiId,
      tvdbId: rec.tvdbId,
      matchedSeason: rec.matchedSeason,
      title: rec.title,
      originalTitle: rec.originalTitle,
      year: rec.year,
      overview: rec.overview,
      posterPath: artworks.posterPath,
      posterFallback: rec.posterFallback,
      bangumiPosterPath: rec.bangumiPosterPath,
      backdropPath: artworks.backdropPath,
      portraitBackdropPath: artworks.portraitBackdropPath,
      logoPath: artworks.logoPath,
      voteAverage: rec.voteAverage,
      bangumiScore: rec.bangumiScore,
      folderTmdbHint: rec.folderTmdbHint,
      isManualLocked: rec.isManualLocked,
      metadataLocked: rec.metadataLocked,
      posterLocked: artworks.posterLocked,
      backdropLocked: artworks.backdropLocked,
      portraitBackdropLocked: artworks.portraitBackdropLocked,
      logoLocked: artworks.logoLocked,
      logoNegativeUntil: logoNeg != null && logoNeg.negativeUntilMs > 0
          ? DateTime.fromMillisecondsSinceEpoch(logoNeg.negativeUntilMs)
          : null,
      logoNegativeMask: logoNeg?.probedSourceMask ?? 0,
      scrapeStatus: rec.scrapeStatus,
      reviewReason: rec.reviewReason,
      seriesId: rec.seriesId?.value,
      seriesOrder: rec.seriesOrder,
      seriesLabel: rec.seriesLabel,
      seriesLocked: rec.seriesLocked,
    );
  }

  static Work _mapWorkRow(
    Map<String, Object?> row,
    ArtworkNegativeCacheRecord? logoNeg,
  ) {
    final posterRef = _decodeArtworkRef(row[WorksSchema.colPosterRefJson]);
    final backdropRef = _decodeArtworkRef(row[WorksSchema.colBackdropRefJson]);
    final portraitBackdropRef = _decodeArtworkRef(
      row[WorksSchema.colPortraitBackdropRefJson],
    );
    final logoRef = _decodeArtworkRef(row[WorksSchema.colLogoRefJson]);
    final artworks = ArtworkRefCodec.unpackWorkArtworks(
      posterRef: posterRef,
      backdropRef: backdropRef,
      portraitBackdropRef: portraitBackdropRef,
      logoRef: logoRef,
    );
    return Work(
      id: row[WorksSchema.colId] as String,
      tmdbId: row[WorksSchema.colTmdbId] as int?,
      tmdbMediaType: _parseOptionalMediaType(
        row[WorksSchema.colTmdbMediaType] as String?,
      ),
      bangumiId: row[WorksSchema.colBangumiId] as int?,
      tvdbId: row[WorksSchema.colTvdbId] as int?,
      matchedSeason: row[WorksSchema.colMatchedSeason] as int?,
      title: row[WorksSchema.colTitle] as String,
      originalTitle: row[WorksSchema.colOriginalTitle] as String?,
      year: row[WorksSchema.colYear] as int?,
      overview: row[WorksSchema.colOverview] as String?,
      posterPath: artworks.posterPath,
      posterFallback: row[WorksSchema.colPosterFallback] as String?,
      bangumiPosterPath: row[WorksSchema.colBangumiPosterPath] as String?,
      backdropPath: artworks.backdropPath,
      portraitBackdropPath: artworks.portraitBackdropPath,
      logoPath: artworks.logoPath,
      voteAverage: (row[WorksSchema.colVoteAverage] as num?)?.toDouble(),
      bangumiScore: (row[WorksSchema.colBangumiScore] as num?)?.toDouble(),
      folderTmdbHint: row[WorksSchema.colFolderTmdbHint] as int?,
      isManualLocked: (row[WorksSchema.colIsManualLocked] as int? ?? 0) != 0,
      metadataLocked: (row[WorksSchema.colMetadataLocked] as int? ?? 0) != 0,
      posterLocked: artworks.posterLocked,
      backdropLocked: artworks.backdropLocked,
      portraitBackdropLocked: artworks.portraitBackdropLocked,
      logoLocked: artworks.logoLocked,
      logoNegativeUntil: logoNeg != null && logoNeg.negativeUntilMs > 0
          ? DateTime.fromMillisecondsSinceEpoch(logoNeg.negativeUntilMs)
          : null,
      logoNegativeMask: logoNeg?.probedSourceMask ?? 0,
      scrapeStatus: _parseScrapeStatus(
        row[WorksSchema.colScrapeStatus] as String?,
      ),
      reviewReason: row[WorksSchema.colReviewReason] as String?,
      seriesId: row[WorksSchema.colSeriesId] as String?,
      seriesOrder: row[WorksSchema.colSeriesOrder] as int?,
      seriesLabel: row[WorksSchema.colSeriesLabel] as String?,
      seriesLocked: (row[WorksSchema.colSeriesLocked] as int? ?? 0) != 0,
    );
  }

  static Episode _mapEpisode(EpisodeRecord rec) {
    return Episode(
      id: rec.id.value,
      workId: rec.workId.value,
      seasonNumber: rec.seasonNumber,
      episodeNumber: rec.episodeNumber,
      episodeNumberEnd: rec.episodeNumberEnd,
      category: rec.category,
      extraType: rec.extraType,
      title: rec.title,
      overview: rec.overview,
      stillPath: rec.stillPath,
    );
  }

  static Episode _mapEpisodeRow(Map<String, Object?> row) {
    return Episode(
      id: row[EpisodesSchema.colId] as String,
      workId: row[EpisodesSchema.colWorkId] as String,
      seasonNumber: row[EpisodesSchema.colSeasonNumber] as int,
      episodeNumber: row[EpisodesSchema.colEpisodeNumber] as int?,
      episodeNumberEnd: row[EpisodesSchema.colEpisodeNumberEnd] as int?,
      category: _parseEpisodeCategory(
        row[EpisodesSchema.colCategory] as String?,
      ),
      extraType: _parseOptionalExtraKind(
        row[EpisodesSchema.colExtraType] as String?,
      ),
      title: row[EpisodesSchema.colTitle] as String?,
      overview: row[EpisodesSchema.colOverview] as String?,
      stillPath: row[EpisodesSchema.colStillPath] as String?,
    );
  }

  static MediaVariant _mapVariant(MediaVariantRecord rec) {
    return MediaVariant(
      id: rec.id.value,
      workId: rec.workId.value,
      episodeId: rec.episodeId?.value,
      sourceId: rec.sourceId.value,
      relativePath: rec.relativePath,
      remoteFileId: rec.remoteFileId,
      fileName: rec.fileName,
      fileSize: rec.fileSize,
      assetKind: rec.assetKind,
      releaseGroup: rec.releaseGroup,
      subtitleGroup: rec.subtitleGroup,
      videoCodec: rec.videoCodec,
      bitDepth: rec.bitDepth,
      resolution: rec.resolution,
      audioCodec: rec.audioCodec,
      externalSubtitles: rec.externalSubtitles,
      mappingLocked: rec.mappingLocked,
      workLocked: rec.workLocked,
      assetScope: rec.assetScope,
      scopeLocked: rec.scopeLocked,
    );
  }

  static MediaVariant _mapVariantRow(Map<String, Object?> row) {
    return MediaVariant(
      id: row[MediaVariantsSchema.colId] as String,
      workId: row[MediaVariantsSchema.colWorkId] as String,
      episodeId: row[MediaVariantsSchema.colEpisodeId] as String?,
      sourceId: row[MediaVariantsSchema.colSourceId] as String,
      relativePath: row[MediaVariantsSchema.colRelativePath] as String,
      remoteFileId: row[MediaVariantsSchema.colRemoteFileId] as String?,
      fileName: row[MediaVariantsSchema.colFileName] as String,
      fileSize: row[MediaVariantsSchema.colFileSize] as int? ?? 0,
      assetKind: _parseAssetKind(
        row[MediaVariantsSchema.colAssetKind] as String?,
      ),
      releaseGroup: row[MediaVariantsSchema.colReleaseGroup] as String?,
      subtitleGroup: row[MediaVariantsSchema.colSubtitleGroup] as String?,
      videoCodec: row[MediaVariantsSchema.colVideoCodec] as String?,
      bitDepth: row[MediaVariantsSchema.colBitDepth] as String?,
      resolution: row[MediaVariantsSchema.colResolution] as String?,
      audioCodec: row[MediaVariantsSchema.colAudioCodec] as String?,
      externalSubtitles: _decodeStringList(
        row[MediaVariantsSchema.colExternalSubtitlesJson],
      ),
      mappingLocked:
          (row[MediaVariantsSchema.colMappingLocked] as int? ?? 0) != 0,
      workLocked: (row[MediaVariantsSchema.colWorkLocked] as int? ?? 0) != 0,
      assetScope: _parseScope(
        row[MediaVariantsSchema.colAssetScope] as String?,
      ),
      scopeLocked: (row[MediaVariantsSchema.colScopeLocked] as int? ?? 0) != 0,
    );
  }

  static SeriesGroup _mapSeriesGroup(SeriesGroupRecord rec) {
    return SeriesGroup(
      id: rec.id.value,
      title: rec.title,
      tmdbCollectionId: rec.tmdbCollectionId,
      rootFolderHint: rec.rootFolderHint,
      createdAt: DateTime.fromMillisecondsSinceEpoch(rec.createdAtMs),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(rec.updatedAtMs),
    );
  }

  static PlaybackRecord _mapPlayback(PlaybackRecordEntity e) {
    return PlaybackRecord(
      id: e.id,
      workId: e.workId.value,
      episodeId: e.episodeId.value,
      variantId: e.variantId.value,
      seasonNumber: e.seasonNumber,
      episodeNumber: e.episodeNumber,
      episodeTitle: e.episodeTitle,
      sourceType: e.sourceKind,
      playedAt: DateTime.fromMillisecondsSinceEpoch(e.playedAtMs),
      positionSeconds: e.positionSeconds,
      durationSeconds: e.durationSeconds,
      isCompleted: e.isCompleted,
    );
  }

  static PlaybackRecord _mapPlaybackRow(Map<String, Object?> row) {
    return PlaybackRecord(
      id: row[PlaybackRecordsSchema.colId] as String,
      workId: row[PlaybackRecordsSchema.colWorkId] as String,
      episodeId: row[PlaybackRecordsSchema.colEpisodeId] as String,
      variantId: row[PlaybackRecordsSchema.colVariantId] as String,
      seasonNumber: row[PlaybackRecordsSchema.colSeasonNumber] as int? ?? 1,
      episodeNumber: row[PlaybackRecordsSchema.colEpisodeNumber] as int?,
      episodeTitle: row[PlaybackRecordsSchema.colEpisodeTitle] as String? ?? '',
      sourceType: _parseMediaSourceKind(
        row[PlaybackRecordsSchema.colSourceKind] as String?,
      ),
      playedAt: DateTime.fromMillisecondsSinceEpoch(
        row[PlaybackRecordsSchema.colPlayedAtMs] as int? ?? 0,
      ),
      positionSeconds:
          row[PlaybackRecordsSchema.colPositionSeconds] as int? ?? 0,
      durationSeconds:
          row[PlaybackRecordsSchema.colDurationSeconds] as int? ?? 0,
      isCompleted:
          (row[PlaybackRecordsSchema.colIsCompleted] as int? ?? 0) != 0,
    );
  }

  static ArtworkRef? _decodeArtworkRef(Object? raw) {
    if (raw is! String || raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<Object?, Object?>) {
        final typed = <String, Object?>{
          for (final e in decoded.entries)
            if (e.key is String) e.key! as String: e.value,
        };
        return ArtworkRef.tryFromJson(typed);
      }
    } catch (_) {
      return null;
    }
    return null;
  }

  static List<String> _decodeStringList(Object? raw) {
    if (raw is! String || raw.trim().isEmpty) return const <String>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return <String>[
          for (final item in decoded)
            if (item is String && item.isNotEmpty) item,
        ];
      }
    } catch (_) {
      return const <String>[];
    }
    return const <String>[];
  }

  static TmdbMediaType? _parseOptionalMediaType(String? raw) {
    for (final v in TmdbMediaType.values) {
      if (v.name == raw) return v;
    }
    return null;
  }

  static ScrapeStatus _parseScrapeStatus(String? raw) {
    for (final v in ScrapeStatus.values) {
      if (v.name == raw) return v;
    }
    return ScrapeStatus.unmatched;
  }

  static EpisodeCategory _parseEpisodeCategory(String? raw) {
    for (final v in EpisodeCategory.values) {
      if (v.name == raw) return v;
    }
    return EpisodeCategory.main;
  }

  static ExtraKind? _parseOptionalExtraKind(String? raw) {
    for (final v in ExtraKind.values) {
      if (v.name == raw) return v;
    }
    return null;
  }

  static AssetKind _parseAssetKind(String? raw) {
    for (final v in AssetKind.values) {
      if (v.name == raw) return v;
    }
    return AssetKind.video;
  }

  static SupplementaryAssetScope _parseScope(String? raw) {
    for (final v in SupplementaryAssetScope.values) {
      if (v.name == raw) return v;
    }
    return SupplementaryAssetScope.workExclusive;
  }

  static MediaSourceKind _parseMediaSourceKind(String? raw) {
    for (final v in MediaSourceKind.values) {
      if (v.name == raw) return v;
    }
    return MediaSourceKind.local;
  }
}
