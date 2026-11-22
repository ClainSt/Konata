/// 歌词候选来源。
enum LyricSource {
  /// 音频同目录外挂 `.lrc` 或内嵌歌词。
  local,

  /// LRCLIB 开源同步歌词库。
  lrclib,

  /// 网易云音乐公开歌词接口。
  netease,

  /// AMLL TTML 开源逐字歌词库（按网易云歌曲 ID 直取）。
  amll,
}

/// 单条在线歌词候选（元数据用于打分，`lrcContent` 为统一的增强 LRC 正文）。
class LyricCandidate {
  /// 创建歌词候选。
  const LyricCandidate({
    required this.source,
    required this.sourceId,
    required this.title,
    required this.lrcContent,
    this.artist = '',
    this.album = '',
    this.durationSeconds,
    this.hasTranslation = false,
    this.hasWordTiming = false,
  });

  /// 候选来源。
  final LyricSource source;

  /// 来源内部歌曲标识（用于缓存与换候选）。
  final String sourceId;

  /// 候选曲名。
  final String title;

  /// 候选歌手（多歌手以 `/` 连接）。
  final String artist;

  /// 候选专辑名。
  final String album;

  /// 候选时长（秒）。
  final double? durationSeconds;

  /// 增强 LRC 正文（可含同时间戳译文行、`<mm:ss.xx>` 逐字标签与 `bg:` 和声行）。
  final String lrcContent;

  /// 是否携带中文译文。
  final bool hasTranslation;

  /// 是否携带逐字时间轴。
  final bool hasWordTiming;
}

/// 已打分的歌词候选。
class ScoredLyricCandidate {
  /// 创建已打分候选。
  const ScoredLyricCandidate(this.candidate, this.score);

  /// 原始候选。
  final LyricCandidate candidate;

  /// 综合得分（元数据 `0.0 ~ 1.0` 加能力加分，可略高于 1.0）。
  final double score;
}
