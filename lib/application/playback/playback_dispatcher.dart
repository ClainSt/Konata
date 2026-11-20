import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../composition/platform_composition.dart';
import '../../domain/models/episode.dart';
import '../../domain/models/media_source.dart';
import '../../domain/models/media_variant.dart';
import '../../domain/models/work.dart';
import '../../domain/playback/cue_variant_resolver.dart';
import '../../domain/repositories/desktop_relay_service.dart';
import '../../infrastructure/players/audio_art_extractor.dart';
import '../providers/library_providers.dart';
import '../providers/platform_capability.dart';
import '../providers/playback_providers.dart';
import 'audio_playback_notifier.dart';
import 'playback_preferences_provider.dart';
import 'unified_playback_coordinator.dart';
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

/// 分发决策：已交由桌面接力程序或已产生回退接力的执行结果。
final class LaunchedExternalVideoDecision extends VideoDispatchDecision {
  /// 创建桌面接力执行结果决策。
  const LaunchedExternalVideoDecision(this.result);

  /// 桌面接力拉起结果。
  final LaunchPlaybackResult result;
}

/// 全局统一音视频播放分发器：
/// 根据全局偏好或单次右键覆写，路由至内置高保真 `libmpv` 或桌面接力程序。
class PlaybackDispatcher {
  /// 创建统一播放分发器。
  const PlaybackDispatcher(this._ref);

  final Ref _ref;

  /// 分发播放指定剧集物理变体（无 Flutter UI / Navigator 依赖）。
  Future<VideoDispatchDecision> dispatchVideoVariant({
    required WorkDetailBundle bundle,
    required Episode episode,
    required MediaVariant variant,
    int startSeconds = 0,
    PreferredPlaybackEngine? overrideEngine,
    String? explicitTargetId,
  }) async {
    final source = bundle.sourcesById[variant.sourceId];
    final sourceType = source?.kind ?? MediaSourceKind.local;
    final mainEpisodeCount = bundle.episodes
        .where((e) => e.category == EpisodeCategory.main)
        .length;

    final prefs = _ref.read(playbackPreferencesProvider);
    final effectiveEngine = KonataPlatform.isAndroid
        ? PreferredPlaybackEngine.builtinLibmpv
        : (explicitTargetId != null
              ? PreferredPlaybackEngine.desktopRelay
              : (overrideEngine ?? prefs.defaultVideoEngine));

    if (effectiveEngine == PreferredPlaybackEngine.builtinLibmpv) {
      final runtime = await _ref.read(mpvRuntimeVersionsProvider.future);
      if (runtime.isAvailable || KonataPlatform.isAndroid) {
        // 互斥暂停全局迷你音频播放器，避免内置视频与音频同时发声
        await _ref.read(audioPlaybackProvider.notifier).pauseForVideoSession();

        final request = VideoLaunchRequest(
          work: bundle.work,
          episode: episode,
          variant: variant,
          bundle: bundle,
          source: source,
          startSeconds: startSeconds.toDouble(),
        );
        return OpenBuiltinVideoDecision(request);
      }
      // 内嵌 libmpv 不可用时优雅降级至桌面接力程序
      final fallbackResult = await _ref
          .read(playbackCoordinatorProvider)
          .playVariant(
            work: bundle.work,
            episode: episode,
            variant: variant,
            sourceType: sourceType,
            source: source,
            targetId: explicitTargetId,
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

    final extResult = await _ref
        .read(playbackCoordinatorProvider)
        .playVariant(
          work: bundle.work,
          episode: episode,
          variant: variant,
          sourceType: sourceType,
          source: source,
          targetId: explicitTargetId,
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
    String? explicitTargetId,
    bool expandImmersive = false,
    int? initialCueTrackNumber,
  }) async {
    final source = sourcesById[variant.sourceId];
    final prefs = _ref.read(playbackPreferencesProvider);
    final effectiveEngine = KonataPlatform.isAndroid
        ? PreferredPlaybackEngine.builtinLibmpv
        : (explicitTargetId != null
              ? PreferredPlaybackEngine.desktopRelay
              : (overrideEngine ?? prefs.defaultAudioEngine));

    if (effectiveEngine == PreferredPlaybackEngine.builtinLibmpv) {
      final runtime = await _ref.read(mpvRuntimeVersionsProvider.future);
      if (runtime.isAvailable || KonataPlatform.isAndroid) {
        if (_ref.read(activeVideoSessionProvider).isActive) {
          await _ref.read(activeVideoSessionProvider.notifier).closeVideo();
        }
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

    // 外部程序收到独立 CUE 的 HTTP 地址无法解析相对 FILE 引用，
    // 与内置音频共用 CUE 目标解析，将物理音轨地址交给桌面接力网关。
    var targetVariant = variant;
    var cueStartSeconds = 0;
    double? cueExactStartSeconds;
    if (AudioPlaybackNotifier.isCueSheetFile(variant.fileName)) {
      if (source == null) {
        return const LaunchPlaybackResult(
          launched: false,
          message: 'CUE 所属媒体源不可用，无法定位音频文件',
        );
      }
      try {
        final sheet = await AudioAssetExtractor.loadCueSheet(
          source: source,
          cueRelativePath: variant.relativePath,
          gatewayFactory: _ref.read(mediaSourceGatewayFactoryProvider),
          legacyDecoder: _ref.read(legacyCodePageDecoderProvider),
        );
        if (sheet == null || sheet.tracks.isEmpty) {
          return const LaunchPlaybackResult(
            launched: false,
            message: '无法解析 CUE 音轨清单',
          );
        }
        final cueDir = p.posix.dirname(
          variant.relativePath.replaceAll('\\', '/'),
        );
        final audioVariants = cdPlaylist.where((item) {
          return item.sourceId == variant.sourceId &&
              AudioPlaybackNotifier.isPlayableAudioFile(item.fileName) &&
              p.posix.dirname(item.relativePath.replaceAll('\\', '/')) ==
                  cueDir;
        }).toList();
        final track = sheet.tracks.firstWhere(
          (item) => item.trackNumber == initialCueTrackNumber,
          orElse: () => sheet.tracks.first,
        );
        final resolved = CueVariantResolver.resolve(
          cueVariant: variant,
          cueTrack: track,
          audioVariantsInDir: audioVariants,
          fallbackInitial: variant,
        );
        if (resolved == null) {
          return const LaunchPlaybackResult(
            launched: false,
            message: 'CUE 引用的音频文件不存在或无法唯一确定',
          );
        }
        targetVariant = resolved;
        cueExactStartSeconds = track.startSeconds;
        cueStartSeconds = track.startSeconds.floor();
      } catch (error) {
        return LaunchPlaybackResult(
          launched: false,
          message: 'CUE 读取失败：$error',
        );
      }
    }

    // 拉起桌面接力音频程序前互斥暂停内置迷你音频播放器
    await _ref.read(audioPlaybackProvider.notifier).pauseForVideoSession();

    return _ref
        .read(playbackCoordinatorProvider)
        .playCdVariant(
          work: work,
          variant: targetVariant,
          source: source,
          targetId: explicitTargetId,
          startSeconds: cueStartSeconds,
          exactStartSeconds: cueExactStartSeconds,
        );
  }
}

/// 全局统一音视频播放分发器 Provider。
final playbackDispatcherProvider = Provider<PlaybackDispatcher>((ref) {
  return PlaybackDispatcher(ref);
});
