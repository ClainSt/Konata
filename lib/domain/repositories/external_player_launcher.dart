import '../models/episode.dart';
import '../models/external_player_config.dart';
import '../models/media_source.dart';
import '../models/media_variant.dart';
import '../models/work.dart';
import 'desktop_relay_service.dart';

export 'desktop_relay_service.dart'
    show LaunchPlaybackResult, PlaybackProgressCallback;

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
}
