import '../models/episode.dart';
import '../models/external_player_config.dart';
import '../models/media_source.dart';
import '../models/media_variant.dart';
import '../models/work.dart';
import 'desktop_relay_service.dart';

export 'desktop_relay_service.dart'
    show
        ExternalAudioAlbumRelayRequest,
        ExternalAudioProgressCallback,
        ExternalAudioTrackDescriptor,
        FoobarBeefwebConfig,
        FoobarComponentState,
        FoobarComponentStatusSnapshot,
        LaunchPlaybackResult,
        PlaybackProgressCallback;

/// 桌面外部播放器启动器抽象接口（仅 Windows 组装根与桌面测试使用）。
abstract interface class ExternalPlayerLauncher {
  /// 使用指定（或自动探测的默认）外部播放器启动播放（支持精确到 `1/75 s` 扇区的 [exactStartSeconds]）。
  Future<LaunchPlaybackResult> launch({
    required Work work,
    required Episode episode,
    required MediaVariant variant,
    ExternalPlayerConfig? player,
    MediaSource? source,
    int startSeconds = 0,
    double? exactStartSeconds,
    int? mainEpisodeCount,
    PlaybackProgressCallback? onProgressUpdate,
  });

  /// 使用外部音频播放器启动完整专辑或 `.cue` 分轨会话并绑定跨轨秒级回写。
  Future<LaunchPlaybackResult> launchAudioAlbum({
    required ExternalAudioAlbumRelayRequest request,
    ExternalPlayerConfig? player,
    ExternalAudioProgressCallback? onTrackProgress,
  }) {
    final target = request.initialTrack;
    final tempEp = Episode(
      id: target.episodeId,
      workId: request.work.id,
      seasonNumber: 0,
      episodeNumber: target.trackNumber,
      category: EpisodeCategory.extra,
      title: target.title,
    );
    return launch(
      work: request.work,
      episode: tempEp,
      variant: target.variant,
      player: player,
      source: request.source,
      startSeconds: request.startSeconds,
      exactStartSeconds: request.exactStartSeconds,
      onProgressUpdate: onTrackProgress == null
          ? null
          : (pos, dur, {required isFinal}) => onTrackProgress(
              target,
              pos,
              dur,
              isCompleted: false,
              isFinal: isFinal,
            ),
    );
  }

  /// 探测给定外部音频播放器的可执行文件与 `foo_beefweb` 组件状态。
  Future<FoobarComponentStatusSnapshot> probeAudioPlayerStatus({
    required ExternalPlayerConfig? player,
    int beefwebPort = FoobarBeefwebConfig.defaultPort,
  }) async {
    if (player == null || player.executablePath.trim().isEmpty) {
      return FoobarComponentStatusSnapshot(
        state: FoobarComponentState.unconfigured,
        port: beefwebPort,
      );
    }
    return FoobarComponentStatusSnapshot(
      state: FoobarComponentState.notFoobar,
      executablePath: player.executablePath,
      port: beefwebPort,
    );
  }

  /// 停止当前由 `Konata` 投递的外部音频接力会话。
  Future<void> stopActiveExternalAudioSession({
    int beefwebPort = FoobarBeefwebConfig.defaultPort,
  }) async {}
}
