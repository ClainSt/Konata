import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../composition/platform_composition.dart';
import '../../domain/models/episode.dart';
import '../../domain/models/media_source.dart';
import '../../domain/models/media_variant.dart';
import '../../domain/models/playback_record.dart';
import '../../domain/models/work.dart';
import '../../domain/repositories/desktop_relay_service.dart';
import '../../infrastructure/sources/source_gateway_factory.dart';
import '../../infrastructure/sources/webdav_source_gateway.dart';
import '../../infrastructure/sources/work_detail_warmup_service.dart';
import '../../infrastructure/storage/storage_root_provider.dart';
import '../../infrastructure/stream_bridge/local_stream_bridge.dart';
import '../playback/playback_preferences_provider.dart';
import 'library_providers.dart';

/// 全局共享 WebDAV HTTP Keep-Alive 连接池与 Digest 质询缓存 Provider。
final webDavConnectionPoolProvider = Provider<WebDavConnectionPool>((ref) {
  final pool = WebDavConnectionPool();
  ref.onDispose(pool.dispose);
  return pool;
});

/// 共享只读媒体源网关工厂 Provider（复用全局 WebDAV 连接池）。
final mediaSourceGatewayFactoryProvider = Provider<MediaSourceGatewayFactory>((
  ref,
) {
  final pool = ref.watch(webDavConnectionPoolProvider);
  return MediaSourceGatewayFactory(webDavPool: pool);
});

/// 本地 HTTP Range 流网桥全局按需 Provider（随容器销毁释放端口）。
final localStreamBridgeProvider = Provider<LocalStreamBridge>((ref) {
  final storageRoot = ref.watch(storageRootProvider);
  final bridge = LocalStreamBridge(storageRoot: storageRoot);
  ref.onDispose(() {
    bridge.dispose();
  });
  return bridge;
});

/// 同级字幕与外挂音轨目录内存索引表 Provider（供详情页静默预热与起播 0 ms 查表）。
final subtitleDirectoryIndexProvider = Provider<SubtitleDirectoryIndex>((ref) {
  final index = SubtitleDirectoryIndex();
  ref.onDispose(index.clear);
  return index;
});

/// 详情页浏览期静默预热服务 Provider（预热 Keep-Alive、Digest 握手与同级字幕表）。
final workDetailWarmupServiceProvider = Provider<WorkDetailWarmupService>((ref) {
  final factory = ref.watch(mediaSourceGatewayFactoryProvider);
  final index = ref.watch(subtitleDirectoryIndexProvider);
  final service = WorkDetailWarmupService(
    gatewayFactory: factory,
    directoryIndex: index,
  );
  ref.onDispose(service.cancelPending);
  return service;
});

/// 播放动作协调器：记录与实时更新秒级播放历史，并委托可选桌面接力网关。
class PlaybackCoordinator {
  /// 创建播放协调器。
  const PlaybackCoordinator(this._ref);

  final Ref _ref;

  /// 启动桌面接力播放指定变体，并绑定秒级双向进度回写。
  Future<LaunchPlaybackResult> playVariant({
    required Work work,
    required Episode episode,
    required MediaVariant variant,
    required MediaSourceKind sourceType,
    MediaSource? source,
    String? targetId,
    int startSeconds = 0,
    int? mainEpisodeCount,
  }) async {
    final gateway = _ref.read(desktopRelayGatewayProvider);
    if (gateway == null) {
      return const LaunchPlaybackResult(
        launched: false,
        message: '当前平台仅支持内置播放器',
      );
    }

    final repo = _ref.read(libraryRepositoryProvider);
    final existingRecords = await repo.getPlaybacksByWork(work.id);
    PlaybackRecord? prevRecord;
    for (final item in existingRecords) {
      if (item.episodeId == episode.id) {
        prevRecord = item;
        break;
      }
    }

    final effectiveStart = startSeconds > 0
        ? startSeconds
        : ((prevRecord != null &&
                  !prevRecord.isCompleted &&
                  prevRecord.positionSeconds > 5)
              ? prevRecord.positionSeconds
              : 0);
    final initialPosition = effectiveStart > 0
        ? effectiveStart
        : (prevRecord?.positionSeconds ?? 0);
    final initialDuration = prevRecord?.durationSeconds ?? 0;
    final initialCompleted = prevRecord?.isCompleted ?? false;
    final recordId = prevRecord?.id ?? '${work.id}::${episode.id}';

    MediaSource? resolvedSource = source;
    if (resolvedSource == null) {
      final allSources = await repo.getMediaSources();
      for (final s in allSources) {
        if (s.id == variant.sourceId) {
          resolvedSource = s;
          break;
        }
      }
    }

    final preferredKindKey = _ref
        .read(playbackPreferencesProvider)
        .preferredRelayKindKey;
    final launchRes = await gateway.launchVideo(
      work: work,
      episode: episode,
      variant: variant,
      source: resolvedSource,
      targetId: targetId,
      preferredKindKey: preferredKindKey,
      startSeconds: effectiveStart,
      mainEpisodeCount: mainEpisodeCount,
      onProgressUpdate:
          (posSeconds, durSeconds, {required bool isFinal}) async {
            final completed = PlaybackRecord.computeCompleted(
              positionSeconds: posSeconds,
              durationSeconds: durSeconds,
            );
            await repo.recordPlayback(
              PlaybackRecord(
                id: recordId,
                workId: work.id,
                episodeId: episode.id,
                variantId: variant.id,
                seasonNumber: episode.seasonNumber,
                episodeNumber: episode.episodeNumber,
                episodeTitle:
                    episode.title ??
                    (episode.episodeNumber != null
                        ? '第 ${episode.episodeNumber} 话'
                        : (episode.category == EpisodeCategory.extra
                              ? (episode.extraType?.name.toUpperCase() ?? '特典')
                              : work.title)),
                sourceType: sourceType,
                playedAt: DateTime.now(),
                positionSeconds: posSeconds,
                durationSeconds: durSeconds,
                isCompleted: completed,
              ),
            );
            _invalidateWorkAndHistory(work.id);
          },
    );

    if (launchRes.launched) {
      await repo.recordPlayback(
        PlaybackRecord(
          id: recordId,
          workId: work.id,
          episodeId: episode.id,
          variantId: variant.id,
          seasonNumber: episode.seasonNumber,
          episodeNumber: episode.episodeNumber,
          episodeTitle:
              episode.title ??
              (episode.episodeNumber != null
                  ? '第 ${episode.episodeNumber} 话'
                  : (episode.category == EpisodeCategory.extra
                        ? (episode.extraType?.name.toUpperCase() ?? '特典')
                        : work.title)),
          sourceType: sourceType,
          playedAt: DateTime.now(),
          positionSeconds: initialPosition,
          durationSeconds: initialDuration,
          isCompleted: initialCompleted,
        ),
      );
      _invalidateWorkAndHistory(work.id);
    }
    return launchRes;
  }

  /// 手动将单集或历史记录标记为「已看完」。
  Future<void> markEpisodeCompleted({
    required Work work,
    required Episode episode,
    MediaVariant? variant,
    MediaSourceKind sourceType = MediaSourceKind.local,
  }) async {
    final repo = _ref.read(libraryRepositoryProvider);
    final existingRecords = await repo.getPlaybacksByWork(work.id);
    PlaybackRecord? existing;
    for (final r in existingRecords) {
      if (r.episodeId == episode.id) {
        existing = r;
        break;
      }
    }
    final dur = existing != null && existing.durationSeconds > 0
        ? existing.durationSeconds
        : (existing != null && existing.positionSeconds > 0
              ? existing.positionSeconds
              : 1);
    final recordId = existing?.id ?? '${work.id}::${episode.id}';

    await repo.recordPlayback(
      PlaybackRecord(
        id: recordId,
        workId: work.id,
        episodeId: episode.id,
        variantId: variant?.id ?? existing?.variantId ?? '',
        seasonNumber: episode.seasonNumber,
        episodeNumber: episode.episodeNumber,
        episodeTitle:
            episode.title ??
            (episode.episodeNumber != null
                ? '第 ${episode.episodeNumber} 话'
                : (episode.category == EpisodeCategory.extra
                      ? (episode.extraType?.name.toUpperCase() ?? '特典')
                      : work.title)),
        sourceType: existing?.sourceType ?? sourceType,
        playedAt: DateTime.now(),
        positionSeconds: dur,
        durationSeconds: dur,
        isCompleted: true,
      ),
    );
    _invalidateWorkAndHistory(work.id);
  }

  /// 直接将一条既有播放历史记录标记为「已看完」。
  Future<void> markRecordCompleted(PlaybackRecord record) async {
    await markRecordsCompleted([record]);
  }

  /// 批量将多条播放历史记录标记为「已看完」。
  Future<void> markRecordsCompleted(List<PlaybackRecord> records) async {
    if (records.isEmpty) return;
    final repo = _ref.read(libraryRepositoryProvider);
    final affectedWorkIds = <String>{};
    final now = DateTime.now();
    for (final record in records) {
      final dur = record.durationSeconds > 0
          ? record.durationSeconds
          : (record.positionSeconds > 0 ? record.positionSeconds : 1);
      await repo.recordPlayback(
        record.copyWith(
          positionSeconds: dur,
          durationSeconds: dur,
          isCompleted: true,
          playedAt: now,
        ),
      );
      affectedWorkIds.add(record.workId);
    }
    for (final workId in affectedWorkIds) {
      _ref.invalidate(workDetailBundleProvider(workId));
    }
    _ref.invalidate(playbackHistoryProvider);
  }

  /// 删除单条播放记录。
  Future<void> deleteHistoryRecord(PlaybackRecord record) async {
    await deleteHistoryRecords([record]);
  }

  /// 批量删除多条播放记录。
  Future<void> deleteHistoryRecords(List<PlaybackRecord> records) async {
    if (records.isEmpty) return;
    final repo = _ref.read(libraryRepositoryProvider);
    final affectedWorkIds = <String>{};
    for (final record in records) {
      await repo.deletePlaybackRecord(record.id);
      affectedWorkIds.add(record.workId);
    }
    for (final workId in affectedWorkIds) {
      _ref.invalidate(workDetailBundleProvider(workId));
    }
    _ref.invalidate(playbackHistoryProvider);
  }

  /// 清空全部播放历史记录。
  Future<void> clearAllHistory() async {
    final repo = _ref.read(libraryRepositoryProvider);
    await repo.clearPlaybackHistory();
    _ref.invalidate(playbackHistoryProvider);
  }

  /// 调用桌面接力程序播放附属 CD 无损/音频音轨，并同步写入 `cd::` 独立音频记录（支持精确 CUE 扇区秒数）。
  Future<LaunchPlaybackResult> playCdVariant({
    required Work work,
    required MediaVariant variant,
    MediaSource? source,
    String? targetId,
    int startSeconds = 0,
    double? exactStartSeconds,
  }) async {
    final gateway = _ref.read(desktopRelayGatewayProvider);
    if (gateway == null) {
      return const LaunchPlaybackResult(
        launched: false,
        message: '当前平台仅支持内置播放器',
      );
    }

    final repo = _ref.read(libraryRepositoryProvider);
    final existingRecords = await repo.getPlaybacksByWork(work.id);
    final defaultEpisodeId =
        '${PlaybackRecord.audioEpisodePrefix}${variant.id}';
    PlaybackRecord? prevRecord;
    for (final item in existingRecords) {
      final isAudioRec =
          item.episodeId.startsWith(PlaybackRecord.audioEpisodePrefix) ||
          item.id.startsWith(PlaybackRecord.audioEpisodePrefix);
      if (isAudioRec &&
          (item.episodeId == defaultEpisodeId ||
              item.variantId == variant.id)) {
        prevRecord = item;
        break;
      }
    }

    final effectiveStart = startSeconds > 0
        ? startSeconds
        : (exactStartSeconds != null && exactStartSeconds > 0
              ? exactStartSeconds.floor()
              : ((prevRecord != null &&
                        !prevRecord.isCompleted &&
                        prevRecord.positionSeconds > 5)
                    ? prevRecord.positionSeconds
                    : 0));
    final effectiveExactStart =
        (exactStartSeconds != null && exactStartSeconds > 0)
        ? exactStartSeconds
        : null;
    final initialPosition = effectiveStart > 0
        ? effectiveStart
        : (prevRecord?.positionSeconds ?? 0);
    final initialDuration = prevRecord?.durationSeconds ?? 0;
    final initialCompleted = prevRecord?.isCompleted ?? false;
    final recordId = prevRecord?.id ?? defaultEpisodeId;
    final episodeId = prevRecord?.episodeId ?? defaultEpisodeId;
    final trackTitle = prevRecord?.episodeTitle.isNotEmpty == true
        ? prevRecord!.episodeTitle
        : variant.fileName;

    MediaSource? resolvedSource = source;
    if (resolvedSource == null) {
      final allSources = await repo.getMediaSources();
      for (final s in allSources) {
        if (s.id == variant.sourceId) {
          resolvedSource = s;
          break;
        }
      }
    }
    final sourceType = resolvedSource?.kind ?? MediaSourceKind.local;

    final tempEpisode = Episode(
      id: episodeId,
      workId: work.id,
      seasonNumber: 0,
      episodeNumber: prevRecord?.episodeNumber,
      category: EpisodeCategory.extra,
      title: trackTitle,
    );
    final launchRes = await gateway.launchAudio(
      work: work,
      episode: tempEpisode,
      variant: variant,
      source: resolvedSource,
      targetId: targetId,
      startSeconds: effectiveStart,
      exactStartSeconds: effectiveExactStart,
      onProgressUpdate:
          (posSeconds, durSeconds, {required bool isFinal}) async {
            final completed = PlaybackRecord.computeCompleted(
              positionSeconds: posSeconds,
              durationSeconds: durSeconds,
              isAudio: true,
            );
            await repo.recordPlayback(
              PlaybackRecord(
                id: recordId,
                workId: work.id,
                episodeId: episodeId,
                variantId: variant.id,
                seasonNumber: 0,
                episodeNumber: prevRecord?.episodeNumber,
                episodeTitle: trackTitle,
                sourceType: sourceType,
                playedAt: DateTime.now(),
                positionSeconds: completed && durSeconds > 0
                    ? durSeconds
                    : posSeconds,
                durationSeconds: durSeconds,
                isCompleted: completed,
              ),
            );
            _invalidateWorkAndHistory(work.id);
          },
    );

    if (launchRes.launched) {
      await repo.recordPlayback(
        PlaybackRecord(
          id: recordId,
          workId: work.id,
          episodeId: episodeId,
          variantId: variant.id,
          seasonNumber: 0,
          episodeNumber: prevRecord?.episodeNumber,
          episodeTitle: trackTitle,
          sourceType: sourceType,
          playedAt: DateTime.now(),
          positionSeconds: initialPosition,
          durationSeconds: initialDuration,
          isCompleted: initialCompleted,
        ),
      );
      _invalidateWorkAndHistory(work.id);
    }
    return launchRes;
  }

  /// 调用桌面接力程序播放完整 CD 专辑或 `.cue` 分轨队列，并按分轨独立持久化秒级进度。
  Future<LaunchPlaybackResult> playCdAlbumRelay({
    required ExternalAudioAlbumRelayRequest request,
  }) async {
    final gateway = _ref.read(desktopRelayGatewayProvider);
    if (gateway == null) {
      return const LaunchPlaybackResult(
        launched: false,
        message: '当前平台仅支持内置播放器',
      );
    }

    final repo = _ref.read(libraryRepositoryProvider);
    MediaSource? resolvedSource = request.source;
    if (resolvedSource == null) {
      final targetSourceId = request.initialTrack.variant.sourceId;
      final allSources = await repo.getMediaSources();
      for (final s in allSources) {
        if (s.id == targetSourceId) {
          resolvedSource = s;
          break;
        }
      }
    }
    final sourceType = resolvedSource?.kind ?? MediaSourceKind.local;

    final existingRecords = await repo.getPlaybacksByWork(request.work.id);
    final existingByEpId = <String, PlaybackRecord>{
      for (final r in existingRecords)
        if (r.isAudioRecord) r.episodeId: r,
    };

    final effectiveReq = ExternalAudioAlbumRelayRequest(
      work: request.work,
      tracks: request.tracks,
      initialTrackIndex: request.initialTrackIndex,
      startSeconds: request.startSeconds,
      exactStartSeconds: request.exactStartSeconds,
      pairedCueVariant: request.pairedCueVariant,
      parsedCueSheet: request.parsedCueSheet,
      source: resolvedSource,
      targetId: request.targetId,
      beefwebPort: request.beefwebPort,
      allowWithoutBeefweb: request.allowWithoutBeefweb,
    );

    final launchRes = await gateway.launchAudioAlbum(
      effectiveReq,
      onTrackProgress: (
        track,
        posSeconds,
        durSeconds, {
        required bool isCompleted,
        required bool isFinal,
      }) async {
        final completed =
            isCompleted ||
            PlaybackRecord.computeCompleted(
              positionSeconds: posSeconds,
              durationSeconds: durSeconds,
              isAudio: true,
            );
        await repo.recordPlayback(
          PlaybackRecord(
            id: track.recordId,
            workId: request.work.id,
            episodeId: track.episodeId,
            variantId: track.variant.id,
            seasonNumber: 0,
            episodeNumber: track.trackNumber,
            episodeTitle: track.title,
            sourceType: sourceType,
            playedAt: DateTime.now(),
            positionSeconds: completed && durSeconds > 0
                ? durSeconds
                : posSeconds,
            durationSeconds: durSeconds,
            isCompleted: completed,
          ),
        );
        _invalidateWorkAndHistory(request.work.id);
      },
    );

    if (launchRes.launched) {
      final initTrack = effectiveReq.initialTrack;
      final prev = existingByEpId[initTrack.episodeId];
      final initPos = effectiveReq.startSeconds > 0
          ? effectiveReq.startSeconds
          : (prev != null && !prev.isCompleted ? prev.positionSeconds : 0);
      final initDur = initTrack.resolvedDurationSeconds > 0
          ? initTrack.resolvedDurationSeconds
          : (prev?.durationSeconds ?? 0);
      await repo.recordPlayback(
        PlaybackRecord(
          id: initTrack.recordId,
          workId: request.work.id,
          episodeId: initTrack.episodeId,
          variantId: initTrack.variant.id,
          seasonNumber: 0,
          episodeNumber: initTrack.trackNumber,
          episodeTitle: initTrack.title,
          sourceType: sourceType,
          playedAt: DateTime.now(),
          positionSeconds: initPos,
          durationSeconds: initDur,
          isCompleted: false,
        ),
      );
      _invalidateWorkAndHistory(request.work.id);
    }
    return launchRes;
  }

  void _invalidateWorkAndHistory(String workId) {
    _ref.invalidate(playbackHistoryProvider);
    _ref.invalidate(workDetailBundleProvider(workId));
  }
}

/// 播放动作协调器 Provider。
final playbackCoordinatorProvider = Provider<PlaybackCoordinator>((ref) {
  return PlaybackCoordinator(ref);
});
