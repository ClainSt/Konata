import '../lyrics/lyric_candidate.dart';

/// 歌词缓存条目状态。
enum LyricCacheStatus {
  /// 已命中并保存了歌词正文。
  found,

  /// 各来源均有响应但无合格候选（负缓存，按有效期重试）。
  notFound,
}

/// 持久化的单曲歌词检索结果。
class LyricCacheEntry {
  /// 创建缓存条目。
  const LyricCacheEntry({
    required this.trackKey,
    required this.status,
    required this.engineVersion,
    required this.updatedAt,
    this.songKey,
    this.source,
    this.sourceId = '',
    this.lrcContent = '',
    this.score = 0.0,
  });

  /// 物理曲目键（媒体源 + 相对路径 + 文件大小 + CUE 分轨起点）。
  final String trackKey;

  /// 跨文件共享的歌曲身份键（时长未知时为空）。
  final String? songKey;

  /// 缓存状态。
  final LyricCacheStatus status;

  /// 命中来源（`notFound` 时为空）。
  final LyricSource? source;

  /// 来源内部歌曲标识。
  final String sourceId;

  /// 增强 LRC 正文。
  final String lrcContent;

  /// 命中候选得分。
  final double score;

  /// 生成该条目时的歌词引擎版本。
  final int engineVersion;

  /// 最近写入时间。
  final DateTime updatedAt;
}

/// 歌词检索结果持久化仓储。
abstract interface class LyricCacheRepository {
  /// 按物理曲目键读取缓存。
  Future<LyricCacheEntry?> findByTrackKey(String trackKey);

  /// 按歌曲身份键读取任一已命中缓存（跨文件复用同一首歌）。
  Future<LyricCacheEntry?> findFoundBySongKey(String songKey);

  /// 写入或覆盖缓存条目。
  Future<void> save(LyricCacheEntry entry);
}
