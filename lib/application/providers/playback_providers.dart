import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models/episode.dart';
import '../../domain/models/external_player_config.dart';
import '../../domain/models/media_source.dart';
import '../../domain/models/media_variant.dart';
import '../../domain/models/playback_record.dart';
import '../../domain/models/work.dart';
import '../../domain/repositories/external_player_launcher.dart';
import '../../infrastructure/players/real_external_player_launcher.dart';
import '../../infrastructure/sources/source_gateway_factory.dart';
import '../../infrastructure/sources/webdav_source_gateway.dart';
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

/// 外部播放器启动器 Provider（Phase 4 接入真实进程拉起与秒级双向进度同步）。
final externalPlayerLauncherProvider = Provider<ExternalPlayerLauncher>((ref) {
  final bridge = ref.watch(localStreamBridgeProvider);
  final factory = ref.watch(mediaSourceGatewayFactoryProvider);
  return RealExternalPlayerLauncher(
    streamBridge: bridge,
    gatewayFactory: factory,
  );
});

/// 播放动作协调器：记录与实时更新秒级播放历史，并委托外部播放器启动器。
class PlaybackCoordinator {
  /// 创建播放协调器。
  const PlaybackCoordinator(this._ref);

  final Ref _ref;

  /// 启动外部播放器播放指定变体，并绑定秒级双向进度回写。
  Future<LaunchPlaybackResult> playVariant({
    required Work work,
    required Episode episode,
    required MediaVariant variant,
    required MediaSourceKind sourceType,
    MediaSource? source,
    ExternalPlayerConfig? player,
    int startSeconds = 0,
    int? mainEpisodeCount,
  }) async {
    final repo = _ref.read(libraryRepositoryProvider);
    final existingRecords = await repo.getPlaybacksByWork(work.id);
    PlaybackRecord? prevRecord;
    for (final item in existingRecords) {
      if (item.episodeId == episode.id) {
        prevRecord = item;
        break;
      }
    }

    final effectivePlayer =
        player ??
        await _pickDefaultVideoPlayer(await repo.getExternalPlayers());
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

    final launcher = _ref.read(externalPlayerLauncherProvider);
    final launchRes = await launcher.launch(
      work: work,
      episode: episode,
      variant: variant,
      player: effectivePlayer,
      source: resolvedSource,
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

  /// 调用外部播放器播放附属 CD 无损/音频音轨（不污染正片续播历史）。
  Future<LaunchPlaybackResult> playCdVariant({
    required Work work,
    required MediaVariant variant,
    MediaSource? source,
    ExternalPlayerConfig? player,
  }) async {
    final repo = _ref.read(libraryRepositoryProvider);
    final effectivePlayer =
        player ??
        await _pickDefaultVideoPlayer(await repo.getExternalPlayers());
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
    final tempEpisode = Episode(
      id: 'cd::${variant.id}',
      workId: work.id,
      seasonNumber: 0,
      category: EpisodeCategory.extra,
      title: variant.fileName,
    );
    final launcher = _ref.read(externalPlayerLauncherProvider);
    return launcher.launch(
      work: work,
      episode: tempEpisode,
      variant: variant,
      player: effectivePlayer,
      source: resolvedSource,
      startSeconds: 0,
    );
  }

  Future<ExternalPlayerConfig?> _pickDefaultVideoPlayer(
    List<ExternalPlayerConfig> players,
  ) async {
    final videoPlayers = players
        .where(
          (p) =>
              (p.kind == ExternalPlayerKind.mpv ||
                  p.kind == ExternalPlayerKind.potplayer ||
                  p.kind == ExternalPlayerKind.custom) &&
              p.executablePath.trim().isNotEmpty,
        )
        .toList();
    if (videoPlayers.isEmpty) return null;
    final preferredKind = _ref
        .read(playbackPreferencesProvider)
        .preferredExternalVideoKind;
    for (final p in videoPlayers) {
      if (p.kind == preferredKind) return p;
    }
    for (final p in videoPlayers) {
      if (p.isDefault) return p;
    }
    return videoPlayers.first;
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
