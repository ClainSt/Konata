import 'package:engine_scraping/engine_scraping.dart';

import 'lyric_search_query.dart';

/// Bangumi 音乐曲目补全结果。
class BangumiTrackEnrichment {
  /// 创建补全结果。
  const BangumiTrackEnrichment({
    this.recoveredTitle,
    this.extraTitleAliases = const [],
  });

  /// 当本地曲名为 `Track 01` 等无意义占位时恢复出的真实日文原名。
  final String? recoveredTitle;

  /// 供多步检索与打分复用的附加标题别名（日文原名 / 中文名）。
  final List<String> extraTitleAliases;

  /// 是否产生有效补全。
  bool get hasEnhancement =>
      (recoveredTitle != null && recoveredTitle!.isNotEmpty) ||
      extraTitleAliases.isNotEmpty;
}

/// 基于作品关联 Bangumi 音乐曲目表的本地曲目身份补全器（纯领域无状态算法）。
///
/// 典型收益：
/// - 修复 `Track 01.flac` / `01.wav` 等无信息文件名（按专辑名与轨号回填真实日文原名）；
/// - 为中文/罗马音命名的本地单曲自动补充 Bangumi 日文原名别名，提高网易云与 AMLL 命中率。
abstract final class BangumiTrackEnricher {
  static final RegExp _weakTitleRegex = RegExp(
    r'^(?:(?:audio[\s._-]*)?track|tr|(?:cd|disc)\d*(?:[\s._-]*track)?|m|bgm)?[\s._-]*0*\d{1,3}$',
    caseSensitive: false,
  );

  /// 判断本地曲名是否属于无信息占位标题（如 `Track 01`、`01`、`CD1-02`、`M03`）。
  static bool isWeakTrackTitle(String rawTitle) {
    final cleaned = LyricSearchQuery.cleanTitle(rawTitle).trim();
    if (cleaned.isEmpty) return true;
    return _weakTitleRegex.hasMatch(cleaned);
  }

  /// 结合关联 Bangumi 音乐曲目表为当前曲目恢复真实曲名或补充跨语种别名。
  static BangumiTrackEnrichment enrich({
    required String title,
    String album = '',
    int? trackNumber,
    required List<BangumiMusicTrack> musicTracks,
  }) {
    if (musicTracks.isEmpty) return const BangumiTrackEnrichment();
    final cleanedTitle = LyricSearchQuery.cleanTitle(title);
    final isWeak = isWeakTrackTitle(title);

    BangumiMusicTrack? matched;
    var bestScore = 0.0;
    var weakAmbiguous = false;
    final singleSubject =
        musicTracks.map((t) => t.subjectId).toSet().length == 1;

    for (final track in musicTracks) {
      final candidateTitle = track.title.trim();
      final candidateCn = track.titleCn.trim();
      if (candidateTitle.isEmpty && candidateCn.isEmpty) continue;

      if (isWeak) {
        // 弱标题仅在轨号一致且专辑名吻合（或仅关联单张单曲/专辑）时安全恢复，防止张冠李戴。
        if (trackNumber == null || track.trackNumber != trackNumber) continue;
        final albumSim = _albumSimilarity(album, track);
        // 仅在专辑信息缺失且关联专辑唯一时允许以轨号兜底。
        final score = album.trim().isEmpty
            ? (singleSubject ? 0.65 : 0.0)
            : albumSim;
        if (score < 0.60) continue;
        if (score > bestScore + 1e-6) {
          bestScore = score;
          matched = track;
          weakAmbiguous = false;
        } else if ((score - bestScore).abs() <= 1e-6 &&
            matched != null &&
            (matched.subjectId != track.subjectId ||
                matched.title != track.title ||
                matched.titleCn != track.titleCn)) {
          weakAmbiguous = true;
        }
      } else {
        final simOrig = candidateTitle.isEmpty
            ? 0.0
            : LyricTextSimilarity.titleSimilarity(cleanedTitle, candidateTitle);
        final simCn = candidateCn.isEmpty
            ? 0.0
            : LyricTextSimilarity.titleSimilarity(cleanedTitle, candidateCn);
        var score = simOrig >= simCn ? simOrig : simCn;
        if (trackNumber != null && track.trackNumber == trackNumber) {
          score += 0.08;
        }
        if (score >= 0.78 && score > bestScore) {
          bestScore = score;
          matched = track;
        }
      }
    }

    if (matched == null || weakAmbiguous) return const BangumiTrackEnrichment();

    final aliases = <String>[];
    final seen = <String>{
      if (!isWeak) WorkMatcherScoring.normalizeKey(cleanedTitle),
    };
    void addAlias(String raw) {
      final t = raw.trim();
      if (t.isEmpty) return;
      final k = WorkMatcherScoring.normalizeKey(t);
      if (k.isNotEmpty && seen.add(k)) aliases.add(t);
    }

    final primaryRecovered = matched.title.trim().isNotEmpty
        ? matched.title.trim()
        : matched.titleCn.trim();
    addAlias(matched.title);
    addAlias(matched.titleCn);

    return BangumiTrackEnrichment(
      recoveredTitle: isWeak && primaryRecovered.isNotEmpty
          ? primaryRecovered
          : null,
      extraTitleAliases: List<String>.unmodifiable(aliases),
    );
  }

  static double _albumSimilarity(String localAlbum, BangumiMusicTrack track) {
    final trimmed = localAlbum.trim();
    if (trimmed.isEmpty) return 0.0;
    final s1 = track.subjectTitle.trim().isEmpty
        ? 0.0
        : LyricTextSimilarity.titleSimilarity(trimmed, track.subjectTitle);
    final s2 = track.subjectTitleCn.trim().isEmpty
        ? 0.0
        : LyricTextSimilarity.titleSimilarity(trimmed, track.subjectTitleCn);
    return s1 >= s2 ? s1 : s2;
  }
}
