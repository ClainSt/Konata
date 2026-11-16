import '../models/episode.dart';
import '../models/external_player_config.dart';
import '../models/media_source.dart';
import '../models/media_variant.dart';
import '../models/work.dart';

/// 外部播放器进度回调签名。
typedef PlaybackProgressCallback =
    Future<void> Function(
      int positionSeconds,
      int durationSeconds, {
      required bool isFinal,
    });

/// 外部播放器启动请求结果。
class LaunchPlaybackResult {
  /// 创建启动结果。
  const LaunchPlaybackResult({
    required this.launched,
    required this.message,
  });

  /// 是否已实际拉起外部播放器进程。
  final bool launched;

  /// 面向用户的中文状态反馈信息。
  final String message;
}

/// 外部播放器启动器抽象接口（Phase 4 接入本地 HTTP Range 流网桥与秒级进度追踪）。
abstract interface class ExternalPlayerLauncher {
  /// 使用指定（或自动探测的默认）外部播放器启动播放。
  Future<LaunchPlaybackResult> launch({
    required Work work,
    required Episode episode,
    required MediaVariant variant,
    ExternalPlayerConfig? player,
    MediaSource? source,
    int startSeconds = 0,
    int? mainEpisodeCount,
    PlaybackProgressCallback? onProgressUpdate,
  });
}
