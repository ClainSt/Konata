import 'package:konata_storage/konata_storage.dart';

/// 播放记录领域判定与时间格式化纯函数辅助集。
abstract final class PlaybackRecordHelper {
  /// 音频播放记录在主键与集号标识中的统一前缀，用于与视频历史分栏隔离。
  static const String audioEpisodePrefix = 'cd::';

  /// 静态格式化季集编号标签（例如 `S01E03`；未解析集号时返回 `S01`）。
  static String formatEpisodeTag(int seasonNumber, int? episodeNumber) {
    final sStr = seasonNumber.toString().padLeft(2, '0');
    if (episodeNumber == null) {
      return 'S$sStr';
    }
    return 'S${sStr}E${episodeNumber.toString().padLeft(2, '0')}';
  }

  /// 完播判定规则：
  /// - 视频记录：进度 `>= 90%` 或剩余时长 `<= 90` 秒时自动标记已看完；
  /// - 音频记录：避免 90 秒片尾阈值误伤短单曲，仅在进度 `>= 95%` 或（总长 `> 15` 秒且剩余 `<= 5` 秒）时标记已听完。
  static bool computeCompleted({
    required int positionSeconds,
    required int durationSeconds,
    bool isAudio = false,
  }) {
    if (durationSeconds <= 0 || positionSeconds <= 0) {
      return false;
    }
    if (isAudio) {
      if (positionSeconds / durationSeconds >= 0.95) {
        return true;
      }
      return durationSeconds > 15 && (durationSeconds - positionSeconds <= 5);
    }
    if (positionSeconds / durationSeconds >= 0.90) {
      return true;
    }
    return durationSeconds > 90 && (durationSeconds - positionSeconds <= 90);
  }

  /// 格式化秒数为时钟展示（`< 1 小时` 为 `MM:SS`，`>= 1 小时` 为 `HH:MM:SS`）。
  static String formatClock(int totalSeconds) {
    final safe = totalSeconds < 0 ? 0 : totalSeconds;
    final hours = safe ~/ 3600;
    final minutes = (safe % 3600) ~/ 60;
    final seconds = safe % 60;
    final mm = minutes.toString().padLeft(2, '0');
    final ss = seconds.toString().padLeft(2, '0');
    if (hours > 0) {
      final hh = hours.toString().padLeft(2, '0');
      return '$hh:$mm:$ss';
    }
    return '$mm:$ss';
  }

  /// 固定输出 `HH:MM:SS` 时长格式（供 PotPlayer `/seek=` 参数使用）。
  static String formatHms(int totalSeconds) {
    final safe = totalSeconds < 0 ? 0 : totalSeconds;
    final hh = (safe ~/ 3600).toString().padLeft(2, '0');
    final mm = ((safe % 3600) ~/ 60).toString().padLeft(2, '0');
    final ss = (safe % 60).toString().padLeft(2, '0');
    return '$hh:$mm:$ss';
  }
}

/// 面向 [PlaybackRecordEntity] 的播放进度语义扩展。
extension PlaybackRecordEntityPlaybackX on PlaybackRecordEntity {
  /// 还原 UTC 更新对应的本地时间点对象。
  DateTime get playedAt =>
      DateTime.fromMillisecondsSinceEpoch(playedAtMs, isUtc: true);

  /// 当前进度百分比（0.0 ~ 1.0）。
  double get progressRatio {
    if (isCompleted) {
      return 1.0;
    }
    if (durationSeconds <= 0) {
      return 0.0;
    }
    return (positionSeconds / durationSeconds).clamp(0.0, 1.0);
  }

  /// 是否属于可断点续播状态（视频需超过 5 秒，音频满 2 秒即可断点续播）。
  bool get hasResumableProgress =>
      !isCompleted && positionSeconds >= (isAudioRecord ? 2 : 6);

  /// 是否为音频 / CD 播放历史记录。
  bool get isAudioRecord =>
      episodeId.value.startsWith(PlaybackRecordHelper.audioEpisodePrefix) ||
      id.startsWith(PlaybackRecordHelper.audioEpisodePrefix);

  /// 生成用于展示的 `S01E03` 编号标签。
  String get episodeTag =>
      PlaybackRecordHelper.formatEpisodeTag(seasonNumber, episodeNumber);
}
