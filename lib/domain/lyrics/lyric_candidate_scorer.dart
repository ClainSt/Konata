import '../playback/lyric_version_matcher.dart';
import 'lyric_candidate.dart';
import 'lyric_search_query.dart';

/// 歌词候选自动采用与低置信度阈值。
abstract final class LyricMatchThresholds {
  /// 达到该分数的带时间轴候选可立即上屏。
  static const double autoAccept = 0.85;

  /// 低于该分数的候选一律不自动显示。
  static const double lowConfidence = 0.60;

  /// 时长差超过该秒数直接淘汰（防止 TV Size 与 Full 版错配）。
  static const double hardDurationRejectSeconds = 25.0;
}

/// 跨来源统一歌词候选打分器（曲名 / 歌手 / 时长 / 专辑加权 + 能力加分 + 版本冲突与曲名否决扣分）。
abstract final class LyricCandidateScorer {
  static const Set<TrackVersionTag> _criticalTags = {
    TrackVersionTag.tvSize,
    TrackVersionTag.shortVer,
    TrackVersionTag.live,
    TrackVersionTag.acoustic,
    TrackVersionTag.remix,
  };

  /// 对单个候选打分（元数据 `0.0 ~ 1.0` 加能力加分）；时长严重失配返回 `null`（淘汰）。
  static double? score(LyricSearchQuery query, LyricCandidate candidate) {
    final meta = scoreMetadata(
      query,
      title: candidate.title,
      artist: candidate.artist,
      album: candidate.album,
      durationSeconds: candidate.durationSeconds,
    );
    if (meta == null) return null;
    if (candidate.lrcContent.trim().isEmpty) return 0.0;
    var value = meta + 0.08;
    if (candidate.hasTranslation) value += 0.05;
    if (candidate.hasWordTiming) value += 0.04;
    // 能力加分允许超过 1.0，保证元数据同为满分的候选之间仍按译文 / 逐字能力排序。
    return value < 0.0 ? 0.0 : value;
  }

  /// 仅依据元数据打分（用于搜索结果预筛，不含能力加分）；时长严重失配返回 `null`。
  static double? scoreMetadata(
    LyricSearchQuery query, {
    required String title,
    String artist = '',
    String album = '',
    double? durationSeconds,
  }) {
    final durS = _durationScore(query.durationSeconds, durationSeconds);
    if (durS == null) return null;
    final titleS = LyricTextSimilarity.titleSimilarity(query.title, title);
    final artistS = LyricTextSimilarity.artistSimilarity(query.artist, artist);
    final albumS = query.album.trim().isEmpty || album.trim().isEmpty
        ? 0.5
        : LyricTextSimilarity.titleSimilarity(query.album, album);

    var value = 0.40 * titleS + 0.25 * artistS + 0.25 * durS + 0.10 * albumS;
    if (_hasVersionConflict(query.title, title)) {
      value -= 0.30;
    }
    if (titleS < 0.6) value -= 0.50;
    return value.clamp(0.0, 1.0);
  }

  static double? _durationScore(double? local, double? remote) {
    if (local == null || local <= 0 || remote == null || remote <= 0) {
      return 0.5;
    }
    final d = (local - remote).abs();
    if (d > LyricMatchThresholds.hardDurationRejectSeconds) return null;
    if (d <= 1.0) return 1.0;
    if (d <= 2.5) return 0.9;
    if (d <= 5.0) return 0.6;
    if (d <= 10.0) return 0.3;
    return 0.0;
  }

  /// 仅比较曲名中的关键版本标签（TV Size / Short / Live / Acoustic / Remix），歌手字段中的 `CV` 与 `feat.` 不参与。
  static bool _hasVersionConflict(String queryTitle, String candidateTitle) {
    final queryTags = LyricVersionMatcher.extractVersionTags(title: queryTitle);
    final candTags = LyricVersionMatcher.extractVersionTags(
      title: candidateTitle,
    );
    for (final tag in _criticalTags) {
      if (queryTags.contains(tag) != candTags.contains(tag)) return true;
    }
    return false;
  }
}
