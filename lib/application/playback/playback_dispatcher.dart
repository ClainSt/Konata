import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models/episode.dart';
import '../../domain/models/external_player_config.dart';
import '../../domain/models/media_source.dart';
import '../../domain/models/media_variant.dart';
import '../../domain/models/work.dart';
import '../../domain/repositories/external_player_launcher.dart';
import '../providers/library_providers.dart';
import '../providers/playback_providers.dart';
import 'audio_playback_notifier.dart';
import 'playback_preferences_provider.dart';
import 'video_playback_controller.dart';

/// 视频播放统一分发决策结果（保持 `application -> presentation` 严格单向隔离）。
sealed class VideoDispatchDecision {
  const VideoDispatchDecision();
}

/// 分发决策：暂停纯音频后由表现层推入内置高保真视频播放器页。
final class OpenBuiltinVideoDecision extends VideoDispatchDecision {
  /// 创建内置播放器启动决策。
  const OpenBuiltinVideoDecision(this.request);

  /// 完整视频播放启动请求。
  final VideoLaunchRequest request;
}

/// 分发决策：已交由外部播放器或已产生回退外部播放器的执行结果。
final class LaunchedExternalVideoDecision extends VideoDispatchDecision {
  /// 创建外部播放器执行结果决策。
  const LaunchedExternalVideoDecision(this.result);

  /// 外部播放器拉起结果。
  final LaunchPlaybackResult result;
}

/// 全局统一音视频播放分发器：
/// 根据全局偏好或单次右键覆写，路由至内置高保真 `libmpv`（D3D11/Surface/音频）或外部播放器。
class PlaybackDispatcher {
  /// 创建统一播放分发器。
  const PlaybackDispatcher(this._ref);

  final Ref _ref;

  Future<ExternalPlayerConfig?> _resolvePreferredVideoPlayer(
    ExternalPlayerKind preferredKind,
  ) async {
    List<ExternalPlayerConfig> players =
        _ref.read(externalPlayersProvider).valueOrNull ?? const [];
    if (players.isEmpty) {
      try {
        players = await _ref
            .read(externalPlayersProvider.future)
            .timeout(const Duration(milliseconds: 120));
      } catch (_) {
        players = const [];
      }
    }
    final configured = players
        .where(
          (p) =>
              (p.kind == ExternalPlayerKind.mpv ||
                  p.kind == ExternalPlayerKind.potplayer ||
                  p.kind == ExternalPlayerKind.custom) &&
              p.executablePath.trim().isNotEmpty,
        )
        .toList(growable: false);
    if (configured.isEmpty) {
      return null;
    }
    for (final p in configured) {
      if (p.kind == preferredKind) {
        return p;
      }
    }
    for (final p in configured) {
      if (p.isDefault) {
        return p;
      }
    }
    return configured.first;
  }

  /// 分发播放指定剧集物理变体（无 Flutter UI / Navigator 依赖）。
  Future<VideoDispatchDecision> dispatchVideoVariant({
    required WorkDetailBundle bundle,
    required Episode episode,
    required MediaVariant variant,
    int startSeconds = 0,
    PreferredPlaybackEngine? overrideEngine,
    ExternalPlayerConfig? explicitPlayer,
  }) async {
    final source = bundle.sourcesById[variant.sourceId];
    final sourceType = source?.kind ?? MediaSourceKind.local;
    final mainEpisodeCount = bundle.episodes
        .where((e) => e.category == EpisodeCategory.main)
        .length;

    final prefs = _ref.read(playbackPreferencesProvider);
    final effectiveEngine = explicitPlayer != null
        ? PreferredPlaybackEngine.externalPlayer
        : (overrideEngine ?? prefs.defaultVideoEngine);

    if (effectiveEngine == PreferredPlaybackEngine.builtinLibmpv) {
      final runtime = await _ref.read(mpvRuntimeVersionsProvider.future);
      if (runtime.isAvailable) {
        // 互斥暂停全局迷你音频播放器，避免内置视频与音频同时发声
        await _ref.read(audioPlaybackProvider.notifier).pauseForVideoSession();

        final request = VideoLaunchRequest(
          work: bundle.work,
          episode: episode,
          variant: variant,
          bundle: bundle,
          source: source,
          startSeconds: startSeconds,
        );
        return OpenBuiltinVideoDecision(request);
      }
      final fallbackPlayer =
          explicitPlayer ??
          await _resolvePreferredVideoPlayer(prefs.preferredExternalVideoKind);
      // 内嵌 libmpv 不可用时优雅降级至外部播放器
      final fallbackResult = await _ref
          .read(playbackCoordinatorProvider)
          .playVariant(
            work: bundle.work,
            episode: episode,
            variant: variant,
            sourceType: sourceType,
            source: source,
            player: fallbackPlayer,
            startSeconds: startSeconds,
            mainEpisodeCount: mainEpisodeCount,
          );
      return LaunchedExternalVideoDecision(
        LaunchPlaybackResult(
          launched: fallbackResult.launched,
          message: '内置播放器运行时未就绪，已自动回退外部播放器：${fallbackResult.message}',
        ),
      );
    }

    final resolvedPlayer =
        explicitPlayer ??
        await _resolvePreferredVideoPlayer(prefs.preferredExternalVideoKind);
    final extResult = await _ref
        .read(playbackCoordinatorProvider)
        .playVariant(
          work: bundle.work,
          episode: episode,
          variant: variant,
          sourceType: sourceType,
          source: source,
          player: resolvedPlayer,
          startSeconds: startSeconds,
          mainEpisodeCount: mainEpisodeCount,
        );
    return LaunchedExternalVideoDecision(extResult);
  }

  /// 分发播放指定 CD / 无损音频资产。
  Future<LaunchPlaybackResult> playCdVariant({
    required Work work,
    required MediaVariant variant,
    required List<MediaVariant> cdPlaylist,
    required Map<String, MediaSource> sourcesById,
    PreferredPlaybackEngine? overrideEngine,
    ExternalPlayerConfig? explicitPlayer,
    bool expandImmersive = false,
    int? initialCueTrackNumber,
  }) async {
    final source = sourcesById[variant.sourceId];
    final prefs = _ref.read(playbackPreferencesProvider);
    final effectiveEngine = explicitPlayer != null
        ? PreferredPlaybackEngine.externalPlayer
        : (overrideEngine ?? prefs.defaultAudioEngine);

    if (effectiveEngine == PreferredPlaybackEngine.builtinLibmpv) {
      final runtime = await _ref.read(mpvRuntimeVersionsProvider.future);
      if (runtime.isAvailable) {
        final effectiveList = cdPlaylist.isEmpty ? [variant] : cdPlaylist;
        await _ref
            .read(audioPlaybackProvider.notifier)
            .playCdCollection(
              work: work,
              cdVariants: effectiveList,
              initialVariant: variant,
              sourcesById: sourcesById,
              initialCueTrackNumber: initialCueTrackNumber,
            );
        if (expandImmersive) {
          _ref.read(immersiveAudioExpandedProvider.notifier).state = true;
        }
        return const LaunchPlaybackResult(launched: true, message: '');
      }
    }

    // 拉起外部音频播放器前互斥暂停内置迷你音频播放器
    await _ref.read(audioPlaybackProvider.notifier).pauseForVideoSession();

    return _ref
        .read(playbackCoordinatorProvider)
        .playCdVariant(
          work: work,
          variant: variant,
          source: source,
          player: explicitPlayer,
        );
  }

  /// 若已配置外部图片查看器且媒体源为本地文件则优先拉起，否则返回 `null` 交由内置预览处理。
  Future<LaunchPlaybackResult?> tryOpenExternalScan({
    required Work work,
    required MediaVariant variant,
    MediaSource? source,
  }) {
    return _ref
        .read(playbackCoordinatorProvider)
        .openExternalScan(work: work, variant: variant, source: source);
  }
}

/// 全局统一音视频播放分发器 Provider。
final playbackDispatcherProvider = Provider<PlaybackDispatcher>((ref) {
  return PlaybackDispatcher(ref);
});
