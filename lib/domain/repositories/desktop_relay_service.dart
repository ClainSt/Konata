import '../models/episode.dart';
import '../models/media_source.dart';
import '../models/media_variant.dart';
import '../models/relay_target_descriptor.dart';
import '../models/work.dart';

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
  });

  /// 是否已实际拉起目标进程。
  final bool launched;

  /// 面向用户的中文状态反馈信息。
  final String message;
}

/// 跨平台桌面接力服务抽象接口（Android 端不注入任何实现，保持零桌面依赖树摇）。
abstract interface class DesktopRelayGateway {
  /// 查询全部已配置的桌面视频接力目标。
  Future<List<RelayTargetDescriptor>> listVideoTargets();

  /// 启动指定或默认的桌面视频程序并绑定进度回调。
  Future<LaunchPlaybackResult> launchVideo({
    required Work work,
    required Episode episode,
    required MediaVariant variant,
    MediaSource? source,
    String? targetId,
    String? preferredKindKey,
    int startSeconds = 0,
    int? mainEpisodeCount,
    PlaybackProgressCallback? onProgressUpdate,
  });

  /// 启动指定或默认的桌面音频程序并绑定进度回调。
  Future<LaunchPlaybackResult> launchAudio({
    required Work work,
    required Episode episode,
    required MediaVariant variant,
    MediaSource? source,
    String? targetId,
    int startSeconds = 0,
    double? exactStartSeconds,
    PlaybackProgressCallback? onProgressUpdate,
  });

  /// 若已配置桌面看图程序且扫图位于本地磁盘则拉起外部查看，否则返回 `null`。
  Future<LaunchPlaybackResult?> openLocalScan({
    required Work work,
    required MediaVariant variant,
    MediaSource? source,
  });
}
