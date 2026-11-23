import '../lyrics/lyric_candidate.dart';

/// 歌词缓存条目状态。
enum LyricCacheStatus {
  /// 已命中并保存了歌词正文。
  found,

  /// 各来源均有响应但无合格候选（负缓存，按有效期重试）。
  notFound,
}

/// 持久化的单曲歌词检索结果（含单曲偏移与用户手动锁定标记，保障用户修改永不被自动流程覆盖）。
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
    this.offsetMillis = 0,
    this.userOffsetLocked = false,
    this.userEdited = false,
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

  /// 单曲级手动时间轴偏移（毫秒，正值使歌词提前、负值使歌词延后）。
  final int offsetMillis;

  /// 单曲偏移是否由用户主动锁定（自动更新缓存时必须保留）。
  final bool userOffsetLocked;

  /// 当前歌词是否由用户手动切换候选或编辑锁定（自动检索与引擎版本升级绝不覆盖）。
  final bool userEdited;

  /// 复制并修改局部字段。
  LyricCacheEntry copyWith({
    String? songKey,
    LyricCacheStatus? status,
    LyricSource? source,
    String? sourceId,
    String? lrcContent,
    double? score,
    int? engineVersion,
    DateTime? updatedAt,
    int? offsetMillis,
    bool? userOffsetLocked,
    bool? userEdited,
  }) {
    return LyricCacheEntry(
      trackKey: trackKey,
      songKey: songKey ?? this.songKey,
      status: status ?? this.status,
      source: source ?? this.source,
      sourceId: sourceId ?? this.sourceId,
      lrcContent: lrcContent ?? this.lrcContent,
      score: score ?? this.score,
      engineVersion: engineVersion ?? this.engineVersion,
      updatedAt: updatedAt ?? this.updatedAt,
      offsetMillis: offsetMillis ?? this.offsetMillis,
      userOffsetLocked: userOffsetLocked ?? this.userOffsetLocked,
      userEdited: userEdited ?? this.userEdited,
    );
  }
}

/// 歌词检索结果与三级偏移持久化仓储。
abstract interface class LyricCacheRepository {
  /// 按物理曲目键读取缓存。
  Future<LyricCacheEntry?> findByTrackKey(String trackKey);

  /// 按歌曲身份键读取任一已命中缓存（跨文件复用同一首歌）。
  Future<LyricCacheEntry?> findFoundBySongKey(String songKey);

  /// 写入或覆盖缓存条目。
  Future<void> save(LyricCacheEntry entry);

  /// 读取指定专辑键的专辑级歌词偏移（毫秒，不存在返回 `0`）。
  Future<int> findAlbumOffsetMillis(String albumKey);

  /// 持久化指定专辑键的专辑级歌词偏移（毫秒，为 `0` 时清除记录）。
  Future<void> saveAlbumOffsetMillis(String albumKey, int offsetMillis);

  /// 仅更新单曲偏移与偏移锁定标记（不覆盖已有歌词正文与用户编辑状态）。
  Future<void> updateTrackOffset(
    String trackKey, {
    required int offsetMillis,
    required bool userOffsetLocked,
  });

  /// 解除用户手动选定锁定，允许后续自动检索重新评估（保留已锁定的单曲偏移）。
  Future<void> unlockUserEdit(String trackKey);
}
