import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';

import '../models/external_audio_relay_models.dart';
import '../models/relay_target_descriptor.dart';

export '../models/external_audio_relay_models.dart';

/// 外部程序播放进度回写回调签名。
typedef PlaybackProgressCallback =
    Future<void> Function(
      int positionSeconds,
      int durationSeconds, {
      required bool isFinal,
    });

/// 外部程序拉起请求执行结果。
class LaunchPlaybackResult {
  /// 创建拉起结果。
  const LaunchPlaybackResult({
    required this.launched,
    required this.message,
    this.requiresBeefwebPrompt = false,
  });

  /// 是否已实际拉起目标进程或成功移交播放会话。
  final bool launched;

  /// 面向用户的中文状态反馈信息。
  final String message;

  /// 是否因 `foobar2000` 未安装 `foo_beefweb` 组件而需向用户展示组件下载引导弹窗。
  final bool requiresBeefwebPrompt;
}

/// 跨平台桌面接力服务抽象接口（Android 端不注入任何实现，保持零桌面依赖树摇）。
abstract interface class DesktopRelayGateway {
  /// 查询全部已配置的桌面视频接力目标。
  Future<List<RelayTargetDescriptor>> listVideoTargets();

  /// 启动指定或默认的桌面视频程序并绑定进度回调。
  Future<LaunchPlaybackResult> launchVideo({
    required WorkRecord work,
    required EpisodeSummaryView episode,
    required MediaVariantRecord variant,
    MediaSourceView? source,
    String? targetId,
    String? preferredKindKey,
    int startSeconds = 0,
    int? mainEpisodeCount,
    PlaybackProgressCallback? onProgressUpdate,
  });

  /// 启动指定或默认的桌面音频程序并绑定单轨进度回调。
  Future<LaunchPlaybackResult> launchAudio({
    required WorkRecord work,
    required EpisodeSummaryView episode,
    required MediaVariantRecord variant,
    MediaSourceView? source,
    String? targetId,
    int startSeconds = 0,
    double? exactStartSeconds,
    PlaybackProgressCallback? onProgressUpdate,
  });

  /// 启动桌面音频专辑/分轨队列（支持 WebDAV 虚拟 `.cue` / `.m3u8` 与跨轨进度回写）。
  Future<LaunchPlaybackResult> launchAudioAlbum(
    ExternalAudioAlbumRelayRequest request, {
    ExternalAudioProgressCallback? onTrackProgress,
  });

  /// 探测当前已配置外部音频播放器的存在性与 `foo_beefweb` 组件状态。
  Future<FoobarComponentStatusSnapshot> probeAudioPlayerStatus({
    int beefwebPort = FoobarBeefwebConfig.defaultPort,
  });

  /// 当切换回内置音视频舞台时，按需停止由 `Konata` 投递的活跃外部音频会话以释放独占声卡。
  Future<void> stopActiveExternalAudioSession({
    int beefwebPort = FoobarBeefwebConfig.defaultPort,
  });
}
