import '../models/tmdb_models.dart';
import '../models/work.dart';
import '../parsing/title_normalizer.dart';
import 'directory_grouper.dart';

/// WorkMatcher 多信号打分细节计算工具（纯函数，零 IO）。
class WorkMatcherScoring {
  const WorkMatcherScoring._();

  static final RegExp _stripSymbols = RegExp(
    r'[\s\-_—–:：;；/／.()（）\[\]【】{}!?！？・·,，、～〜~「」『』《》☆★♪"\x27’‘]+',
  );
  static final RegExp _subtitleSplit = RegExp(r'^(.+?)\s*[:：\-–—/]\s*(.+)$');
  static final RegExp _sequelTailNum = RegExp(
    r'(?:^|\s)(2|3|4|5|II|III|IV|V)\s*$',
    caseSensitive: false,
  );

  /// 计算单个 TMDB 候选与本地目录提示的综合得分与完整信号明细。
  static ({double score, List<String> reasons}) scoreCandidate(
    GroupedWorkFolder folder,
    TmdbWorkDetail candidate,
  ) {
    var score = 0.0;
    final reasons = <String>[];
    final remoteNames = [
      candidate.title,
      ?candidate.originalTitle,
      ...candidate.aliases,
    ];

    if (folder.explicitTmdbId != null) {
      if (folder.explicitTmdbId == candidate.tmdbId) {
        score += 80.0;
        reasons.add('explicit_tmdb_match');
      } else {
        score -= 60.0;
        reasons.add('explicit_id_mismatch');
      }
    }

    // 1. 标题归一化与罗马音音译打分
    final titleSim = _bestTitleSimilarity(folder.cleanTitle, remoteNames);
    if (titleSim >= 0.999) {
      score += 50.0;
      reasons.add('exact_title_match');
    } else if (titleSim >= 0.85) {
      score += 40.0 * titleSim;
      reasons.add('high_title_similarity');
    } else {
      final romajiSim = _bestRomajiSimilarity(folder.cleanTitle, remoteNames);
      if (romajiSim >= 0.72) {
        score += 26.0 * romajiSim + 12.0;
        reasons.add('romaji_similarity');
      } else if (titleSim > 0.4) {
        score += 25.0 * titleSim;
        reasons.add('partial_title_similarity');
      } else {
        reasons.add('low_title_similarity');
      }
    }

    // 2. 多词拉丁前缀撞车惩罚 + 副标题冲突 + 续集数字缺失检查
    if (_isPartialLatinPrefixOnly(folder.cleanTitle, candidate.title, titleSim)) {
      score -= 15.0;
      reasons.add('partial_latin_prefix');
    }
    if (_hasSubtitleConflict(folder.cleanTitle, remoteNames)) {
      score -= 12.0;
      reasons.add('subtitle_conflict');
    }
    if (_isMissingSequelNumber(folder, remoteNames)) {
      score -= 14.0;
      reasons.add('missing_sequel_number');
    }

    // 3. 季级元数据（SeasonInfo 年份 / 集数 / 季名）消歧与 2 年跨度容差
    var seasonYearMatched = false;
    if (candidate.mediaType == TmdbMediaType.tv && candidate.seasons.isNotEmpty) {
      final targetSeason = folder.seasonHint ?? 1;
      final matchedSeason = _findSeason(candidate.seasons, targetSeason);
      if (matchedSeason != null) {
        if (folder.seasonHint != null && folder.seasonHint! >= 2) {
          score += 6.0;
          reasons.add('season_name_match');
        }
        final seasonYear = _parseYear(matchedSeason.airDate);
        if (folder.year != null &&
            seasonYear != null &&
            (folder.year! - seasonYear).abs() <= 1) {
          score += 12.0;
          reasons.add('season_year_match');
          seasonYearMatched = true;
        }
        final localEpCount = folder.mainEpisodeNumbers.length;
        if (localEpCount >= 4 &&
            matchedSeason.episodeCount >= 4 &&
            (localEpCount - matchedSeason.episodeCount).abs() <= 1) {
          score += 12.0;
          reasons.add('season_episode_match');
        }
      }
    }

    // 4. 作品首播年份与 2 年跨度容差（若季年份已对齐则免除总年份差额扣分）
    if (!seasonYearMatched && folder.year != null && candidate.year != null) {
      final diff = (folder.year! - candidate.year!).abs();
      if (diff == 0) {
        score += 15.0;
        reasons.add('year_exact_match');
      } else if (diff == 1) {
        score += 5.0;
        reasons.add('year_close_match');
      } else if (diff == 2) {
        score -= 5.0;
        reasons.add('year_span_tolerance');
      } else {
        score -= 25.0;
        reasons.add('year_mismatch');
      }
    }

    // 5. 媒体类型信号
    if (folder.explicitMediaType != null) {
      if (folder.explicitMediaType == candidate.mediaType) {
        score += 8.0;
        reasons.add('media_type_match');
      } else {
        score -= 40.0;
        reasons.add('media_type_conflict');
      }
    } else if (folder.isMovieHint && candidate.mediaType == TmdbMediaType.tv) {
      score -= 10.0;
      reasons.add('tv_vs_movie_hint');
    }

    return (score: score, reasons: reasons);
  }

  static double _bestTitleSimilarity(
    String localTitle,
    List<String> remoteNames,
  ) {
    final localKey = normalizeKey(localTitle);
    if (localKey.isEmpty) return 0.0;
    var best = 0.0;
    for (final raw in remoteNames) {
      final remoteKey = normalizeKey(raw);
      if (remoteKey.isEmpty) continue;
      if (localKey == remoteKey) return 1.0;
      final dice = bigramDice(localKey, remoteKey);
      if (dice > best) best = dice;
    }
    return best;
  }

  static double _bestRomajiSimilarity(
    String localTitle,
    List<String> remoteNames,
  ) {
    var best = 0.0;
    for (final raw in remoteNames) {
      if (raw.trim().isEmpty) continue;
      final sim = TitleNormalizer.romajiKanaSimilarity(localTitle, raw);
      if (sim > best) best = sim;
    }
    return best;
  }

  static bool _isPartialLatinPrefixOnly(
    String localTitle,
    String candidateTitle,
    double titleSim,
  ) {
    if (titleSim >= 0.65) return false;
    final words = localTitle
        .trim()
        .split(RegExp(r'\s+'))
        .where((w) => RegExp(r'^[A-Za-z0-9]+$').hasMatch(w))
        .toList();
    if (words.length < 3) return false;
    final candWords = candidateTitle.trim().split(RegExp(r'\s+'));
    if (candWords.length < 2) return false;
    return words.first.toLowerCase() == candWords.first.toLowerCase() &&
        words.last.toLowerCase() != candWords.last.toLowerCase();
  }

  static bool _hasSubtitleConflict(
    String localTitle,
    List<String> remoteNames,
  ) {
    final lMatch = _subtitleSplit.firstMatch(localTitle.trim());
    if (lMatch == null) return false;
    final lMain = normalizeKey(lMatch.group(1)!);
    final lSub = normalizeKey(lMatch.group(2)!);
    if (lMain.length < 2 || lSub.length < 2) return false;

    for (final raw in remoteNames) {
      final rMatch = _subtitleSplit.firstMatch(raw.trim());
      if (rMatch == null) continue;
      final rMain = normalizeKey(rMatch.group(1)!);
      final rSub = normalizeKey(rMatch.group(2)!);
      if (rMain == lMain && rSub.length >= 2) {
        if (bigramDice(lSub, rSub) < 0.25) return true;
      }
    }
    return false;
  }

  static bool _isMissingSequelNumber(
    GroupedWorkFolder folder,
    List<String> remoteNames,
  ) {
    final hintSeason = folder.seasonHint;
    final tailMatch = _sequelTailNum.firstMatch(folder.cleanTitle.trim());
    final targetNum = hintSeason ?? _romanOrDigit(tailMatch?.group(1));
    if (targetNum == null || targetNum < 2) return false;

    final hasNumberInRemote = remoteNames.any((n) {
      final folded = TitleNormalizer.fold(n);
      return RegExp('\\b$targetNum\\b').hasMatch(folded) ||
          (targetNum == 2 && folded.contains('ii')) ||
          (targetNum == 3 && folded.contains('iii'));
    });
    return !hasNumberInRemote;
  }

  static TmdbSeasonSummary? _findSeason(
    List<TmdbSeasonSummary> seasons,
    int seasonNumber,
  ) {
    for (final s in seasons) {
      if (s.seasonNumber == seasonNumber) return s;
    }
    return null;
  }

  static int? _parseYear(String? dateStr) {
    if (dateStr == null || dateStr.length < 4) return null;
    return int.tryParse(dateStr.substring(0, 4));
  }

  static int? _romanOrDigit(String? token) {
    if (token == null) return null;
    switch (token.toUpperCase()) {
      case 'II':
        return 2;
      case 'III':
        return 3;
      case 'IV':
        return 4;
      case 'V':
        return 5;
      default:
        return int.tryParse(token);
    }
  }

  /// 标准化标题键（折叠繁简与假名并剥除符号）。
  static String normalizeKey(String input) {
    final folded = TitleNormalizer.fold(input);
    return folded.replaceAll(_stripSymbols, '').trim();
  }

  /// 计算二元组 Dice 系数相似度。
  static double bigramDice(String a, String b) {
    if (a.length < 2 || b.length < 2) return a == b ? 1.0 : 0.0;
    final grams = <String, int>{};
    for (var i = 0; i < a.length - 1; i++) {
      final g = a.substring(i, i + 2);
      grams[g] = (grams[g] ?? 0) + 1;
    }
    var shared = 0;
    for (var i = 0; i < b.length - 1; i++) {
      final g = b.substring(i, i + 2);
      final left = grams[g] ?? 0;
      if (left > 0) {
        shared++;
        grams[g] = left - 1;
      }
    }
    return 2.0 * shared / (a.length + b.length - 2);
  }
}
