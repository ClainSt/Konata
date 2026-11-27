import 'package:engine_playback/engine_playback.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';

/// 详情页直接调用桌面播放器，避免先创建内置解码舞台。
final class DetailExternalVideoService {
  DetailExternalVideoService({
    required this.databases,
    required this.gateway,
    required this.events,
    this.prepare,
    this.sourceDeviceId = '',
  });

  final KonataDatabaseBundle databases;
  final DesktopRelayGateway gateway;
  final DomainEventBus events;
  final Future<void> Function()? prepare;
  final String sourceDeviceId;
  bool _launching = false;
  int _generation = 0;

  /// 根据真实文件启动默认接力目标，并回写实际播放进度。
  Future<LaunchPlaybackResult> launch({
    required WorkId workId,
    required EpisodeId episodeId,
    required VariantId variantId,
    int? initialPositionSeconds,
  }) async {
    if (_launching) {
      return const LaunchPlaybackResult(launched: false, message: '外部播放器正在启动');
    }
    _launching = true;
    try {
      final library = databases.library;
      final work = library.works.findById(workId);
      final episode = library.episodes.findById(episodeId);
      final variant = library.mediaVariants.findById(variantId);
      if (work == null ||
          episode == null ||
          variant == null ||
          work.isDeleted ||
          episode.isDeleted ||
          variant.isDeleted ||
          episode.workId != workId ||
          variant.workId != workId ||
          variant.episodeId != episodeId ||
          variant.assetKind != AssetKind.video) {
        return const LaunchPlaybackResult(
          launched: false,
          message: '分集或视频版本已不存在',
        );
      }
      final source = library.mediaSources.findById(variant.sourceId);
      if (source == null) {
        return const LaunchPlaybackResult(launched: false, message: '媒体源已不存在');
      }
      final configured = (await gateway.listVideoTargets())
          .where((t) => t.configured)
          .toList();
      if (configured.isEmpty) {
        return const LaunchPlaybackResult(
          launched: false,
          message: '请先在设置 → 外部调用中配置视频播放器',
        );
      }
      final target =
          configured.where((t) => t.isDefault).firstOrNull ?? configured.first;
      await prepare?.call();
      final dao = databases.userState.playbackRecords;
      final previous = dao.findLatestByEpisode(episodeId);
      final start =
          initialPositionSeconds ??
          (previous != null &&
                  !previous.isCompleted &&
                  previous.positionSeconds >= 6
              ? previous.positionSeconds
              : 0);
      final generation = ++_generation;
      final mainCount = library.episodes
          .listByWork(workId)
          .where((ep) => !ep.isDeleted && ep.category == EpisodeCategory.main)
          .length;
      return await gateway.launchVideo(
        work: work,
        episode: episode.toSummaryView(),
        variant: variant,
        source: source.toReadView(),
        targetId: target.id,
        startSeconds: start < 0 ? 0 : start,
        mainEpisodeCount: mainCount,
        onProgressUpdate: (position, duration, {required isFinal}) async {
          if (generation != _generation || position < 0 || duration <= 0) {
            return;
          }
          final current = dao.findLatestByEpisode(episodeId);
          final completed =
              (current?.isCompleted ?? false) ||
              PlaybackRecordHelper.computeCompleted(
                positionSeconds: position,
                durationSeconds: duration,
              );
          final now = DateTime.now().millisecondsSinceEpoch;
          dao.upsert(
            PlaybackRecordEntity(
              id: current?.id ?? '${workId.value}::${episodeId.value}',
              canonicalKey: current?.canonicalKey,
              workId: workId,
              episodeId: episodeId,
              variantId: variantId,
              seasonNumber: episode.seasonNumber,
              episodeNumber: episode.episodeNumber,
              episodeTitle: EpisodeTitleFormatter.formatCardTitle(
                episode: episode.toSummaryView(),
                workTitle: work.title,
                workMediaType: work.tmdbMediaType,
                mainEpisodeCount: mainCount,
              ),
              sourceKind: source.kind,
              playedAtMs: now,
              positionSeconds: position.clamp(0, duration),
              durationSeconds: duration,
              isCompleted: completed,
              updatedAtMs: now,
              sourceDeviceId: sourceDeviceId,
            ),
          );
          if (completed && current?.isCompleted != true) {
            events.publish(
              EpisodeCompletionChangedEvent(
                workId: workId,
                episodeId: episodeId,
                completed: true,
                occurredAtMs: now,
              ),
            );
          }
        },
      );
    } finally {
      _launching = false;
    }
  }
}
