import 'dart:math' as math;

import '../matching/work_matcher_scoring.dart';
import 'lyric_candidate.dart';
import 'lyric_cleaner.dart';
import 'ttml_lyric_converter.dart';

/// 同源歌词合并结果（原文主轴 + DP 对齐译文与罗马音）。
class SameSourceMergeResult {
  /// 创建合并结果。
  const SameSourceMergeResult({
    required this.lrcContent,
    required this.hasTranslation,
    required this.hasRomaji,
    required this.credits,
  });

  /// 合并后的增强 LRC 正文（译文同时间戳紧随原文，罗马音使用 `roma:` 前缀）。
  final String lrcContent;

  /// 是否包含有效中文译文行。
  final bool hasTranslation;

  /// 是否包含有效罗马音行。
  final bool hasRomaji;

  /// 清洗阶段提取出的制作人员署名行。
  final List<String> credits;
}

/// 跨源原文序列对齐结果。
class CrossSourceAlignment {
  /// 创建跨源对齐结果。
  const CrossSourceAlignment({
    required this.matchRatio,
    required this.medianShiftSeconds,
    required this.matchedPairs,
  });

  /// 原文按行对齐比例（`matchedPairs / min(lenA, lenB)`，`0.0 ~ 1.0`）。
  final double matchRatio;

  /// 配对原文行时间差 `t_primary - t_other` 的中位数（秒）。
  final double medianShiftSeconds;

  /// 成功对齐的原文行对数量。
  final int matchedPairs;
}

/// 跨源增强结果（包含时间一致性验证与借译文/借罗马音后的新候选）。
class CrossSourceEnrichment {
  /// 创建跨源增强结果。
  const CrossSourceEnrichment({
    required this.candidate,
    required this.crossSourceAgreed,
    required this.borrowedTranslation,
    required this.borrowedRomaji,
  });

  /// 增强后的候选（若未借用任何轨道则为原候选）。
  final LyricCandidate candidate;

  /// 是否与其他独立来源达成时间轴一致性验证（对齐 `>= 0.9` 且中位差 `<= 0.3s`）。
  final bool crossSourceAgreed;

  /// 是否从其他候选借入了译文。
  final bool borrowedTranslation;

  /// 是否从其他候选借入了罗马音。
  final bool borrowedRomaji;
}

/// 歌词动态规划（DP）对齐与跨源字段合并器。
abstract final class LyricMerger {
  /// 精确时间配对优先阈值（秒）。
  static const double tightMatchToleranceSeconds = 0.15;

  /// DP 单调配对最大允许时间差（秒），超出禁止强行错配。
  static const double maxDpMatchGapSeconds = 1.20;

  /// DP 跳过单行的惩罚代价（秒）。
  static const double dpSkipPenaltySeconds = 0.85;

  /// 跨源交叉验证所需的最低原文行对齐比例。
  static const double crossVerifyMinMatchRatio = 0.90;

  /// 跨源交叉验证允许的最大中位时间差（秒）。
  static const double crossVerifyMaxMedianShiftSeconds = 0.30;

  /// 跨源借译文/借罗马音所需的最低原文行对齐比例。
  static const double crossBorrowMinMatchRatio = 0.80;

  static final RegExp _kanaRegex = RegExp(r'[\u3040-\u309F\u30A0-\u30FF]');
  static final RegExp _cjkHanRegex = RegExp(r'[\u4E00-\u9FFF]');

  /// 合并同一来源的原文、译文与罗马音 LRC（先清洗噪声，再按两阶段 + 带跳过 DP 单调配对）。
  static SameSourceMergeResult mergeSameSource({
    required String mainLrc,
    String translationLrc = '',
    String romajiLrc = '',
  }) {
    final cleanedMain = LyricCleaner.clean(mainLrc);
    if (cleanedMain.isPlaceholder) {
      return SameSourceMergeResult(
        lrcContent: '',
        hasTranslation: false,
        hasRomaji: false,
        credits: cleanedMain.credits,
      );
    }

    // 保留原清洗结果中附带的逐字/和声行，主轴用于对齐译文和罗马音。
    final rawCleanedEntries = LyricCleaner.parseTimedEntries(
      cleanedMain.cleanedLrc,
    );
    final mainRows = <TimedLyricEntry>[];
    final extraBySlot = <int, List<TimedLyricEntry>>{};
    for (final entry in rawCleanedEntries) {
      final isAux =
          entry.rawBody.startsWith('bg:') || entry.rawBody.startsWith('roma:');
      if (!isAux &&
          (mainRows.isEmpty ||
              (entry.timeSeconds - mainRows.last.timeSeconds).abs() > 0.05)) {
        mainRows.add(entry);
      } else if (mainRows.isNotEmpty) {
        final slot = mainRows.length - 1;
        extraBySlot.putIfAbsent(slot, () => []).add(entry);
      }
    }

    final transEntries = _extractAuxTrackEntries(translationLrc);
    final romaEntries = _extractAuxTrackEntries(romajiLrc);

    final transMap = transEntries.isEmpty
        ? const <int, String>{}
        : alignTrackWithDp(mainRows, transEntries);
    final romaMap = romaEntries.isEmpty
        ? const <int, String>{}
        : alignTrackWithDp(mainRows, romaEntries);

    final buf = StringBuffer();
    var hasTranslation = false;
    var hasRomaji = false;

    for (var i = 0; i < mainRows.length; i++) {
      final main = mainRows[i];
      final tag = TtmlLyricConverter.formatLrcTag(main.timeSeconds);
      var leadBody = main.effectiveBody;
      var leadPlain = main.text;
      var transText = _filterSecondaryText(transMap[i], leadPlain);

      // 若原文与译文倒挂（主行为纯中文译文而副行含日文假名），自动交换位置。
      if (transText != null &&
          !leadBody.contains('<') &&
          _isLikelyOriginalOverChineseTranslation(transText, leadPlain)) {
        final swapped = leadPlain;
        leadBody = transText;
        leadPlain = transText;
        transText = swapped;
      }

      buf.writeln('[$tag]$leadBody');
      if (transText != null) {
        hasTranslation = true;
        buf.writeln('[$tag]$transText');
      }

      // 保留原有伴随行（如已有的 `bg:` 和声或原有译文行），避免重复输出。
      final extras = extraBySlot[i];
      if (extras != null) {
        for (final extra in extras) {
          if (extra.rawBody.startsWith('roma:')) {
            if (!romaMap.containsKey(i)) {
              hasRomaji = true;
              buf.writeln('[$tag]${extra.rawBody}');
            }
          } else if (extra.rawBody.startsWith('bg:')) {
            buf.writeln('[$tag]${extra.rawBody}');
          } else if (transText == null) {
            final filtered = _filterSecondaryText(extra.text, leadPlain);
            if (filtered != null) {
              hasTranslation = true;
              buf.writeln('[$tag]$filtered');
            }
          }
        }
      }

      final romaText = _filterSecondaryText(romaMap[i], leadPlain);
      if (romaText != null) {
        hasRomaji = true;
        buf.writeln('[$tag]roma:$romaText');
      }
    }

    return SameSourceMergeResult(
      lrcContent: buf.toString().trimRight(),
      hasTranslation: hasTranslation,
      hasRomaji: hasRomaji,
      credits: cleanedMain.credits,
    );
  }

  /// 两阶段 + 带跳过 DP 单调时间轴配对：返回 `mainIndex -> matchedSecondaryText` 映射。
  ///
  /// 1. 优先锁定时间差 `<= 0.15s` 的最近邻锚点配对；
  /// 2. 剩余区间使用带跳过惩罚的动态规划求全局最小时间差单调对齐（单对上限 `1.20s`）。
  static Map<int, String> alignTrackWithDp(
    List<TimedLyricEntry> mainRows,
    List<TimedLyricEntry> auxRows, {
    double timeShiftSeconds = 0.0,
  }) {
    if (mainRows.isEmpty || auxRows.isEmpty) return const {};
    final shiftedAux = timeShiftSeconds == 0.0
        ? auxRows
        : [
            for (final e in auxRows)
              TimedLyricEntry(
                timeSeconds: math.max(0.0, e.timeSeconds + timeShiftSeconds),
                text: e.text,
                rawBody: e.rawBody,
              ),
          ];

    final n = mainRows.length;
    final m = shiftedAux.length;
    // 防御极端超长输入导致 O(n*m) 矩阵过大，超过 400 行时退化为滑动窗口双指针。
    if (n * m > 160000) {
      return _alignGreedyWindow(mainRows, shiftedAux);
    }

    // 使用扁平浮点数组与回溯动作表（0=匹配，1=跳过主行，2=跳过副行）降低 GC 压力。
    final stride = m + 1;
    final dp = List<double>.filled((n + 1) * stride, 0.0);
    final action = List<int>.filled((n + 1) * stride, 0);

    for (var i = 1; i <= n; i++) {
      dp[i * stride] = i * dpSkipPenaltySeconds;
      action[i * stride] = 1;
    }
    for (var j = 1; j <= m; j++) {
      dp[j] = j * dpSkipPenaltySeconds;
      action[j] = 2;
    }

    for (var i = 1; i <= n; i++) {
      final tMain = mainRows[i - 1].timeSeconds;
      final rowOffset = i * stride;
      final prevRowOffset = (i - 1) * stride;
      for (var j = 1; j <= m; j++) {
        final skipMain = dp[prevRowOffset + j] + dpSkipPenaltySeconds;
        final skipAux = dp[rowOffset + j - 1] + dpSkipPenaltySeconds;
        var best = skipMain;
        var bestAct = 1;
        if (skipAux < best) {
          best = skipAux;
          bestAct = 2;
        }
        final dt = (tMain - shiftedAux[j - 1].timeSeconds).abs();
        if (dt <= maxDpMatchGapSeconds) {
          // 精确容差内额外折减代价，确保 <= 0.15s 的精确对齐始终优先于远距离配对。
          final matchCost = dt <= tightMatchToleranceSeconds ? dt * 0.25 : dt;
          final cand = dp[prevRowOffset + j - 1] + matchCost;
          if (cand <= best) {
            best = cand;
            bestAct = 0;
          }
        }
        dp[rowOffset + j] = best;
        action[rowOffset + j] = bestAct;
      }
    }

    final result = <int, String>{};
    var i = n;
    var j = m;
    while (i > 0 && j > 0) {
      final act = action[i * stride + j];
      if (act == 0) {
        result[i - 1] = shiftedAux[j - 1].text;
        i--;
        j--;
      } else if (act == 1) {
        i--;
      } else {
        j--;
      }
    }
    return result;
  }

  /// 对两份同步歌词原文行执行文本相似度 DP 序列对齐，返回对齐比例与时间差中位数。
  static CrossSourceAlignment crossSourceAlign(
    List<TimedLyricEntry> primaryRows,
    List<TimedLyricEntry> otherRows,
  ) {
    if (primaryRows.isEmpty || otherRows.isEmpty) {
      return const CrossSourceAlignment(
        matchRatio: 0.0,
        medianShiftSeconds: 0.0,
        matchedPairs: 0,
      );
    }

    final keysA = [
      for (final r in primaryRows) WorkMatcherScoring.normalizeKey(r.text),
    ];
    final keysB = [
      for (final r in otherRows) WorkMatcherScoring.normalizeKey(r.text),
    ];
    final n = keysA.length;
    final m = keysB.length;
    if (n * m > 160000) {
      return const CrossSourceAlignment(
        matchRatio: 0.0,
        medianShiftSeconds: 0.0,
        matchedPairs: 0,
      );
    }

    final stride = m + 1;
    final dp = List<int>.filled((n + 1) * stride, 0);
    final dir = List<int>.filled((n + 1) * stride, 0);

    for (var i = 1; i <= n; i++) {
      final rowOff = i * stride;
      final prevOff = (i - 1) * stride;
      final ka = keysA[i - 1];
      for (var j = 1; j <= m; j++) {
        var best = dp[prevOff + j];
        var bestDir = 1;
        if (dp[rowOff + j - 1] > best) {
          best = dp[rowOff + j - 1];
          bestDir = 2;
        }
        if (_linesTextMatch(ka, keysB[j - 1])) {
          final cand = dp[prevOff + j - 1] + 1;
          if (cand >= best) {
            best = cand;
            bestDir = 0;
          }
        }
        dp[rowOff + j] = best;
        dir[rowOff + j] = bestDir;
      }
    }

    final deltas = <double>[];
    var i = n;
    var j = m;
    while (i > 0 && j > 0) {
      final d = dir[i * stride + j];
      if (d == 0) {
        deltas.add(primaryRows[i - 1].timeSeconds - otherRows[j - 1].timeSeconds);
        i--;
        j--;
      } else if (d == 1) {
        i--;
      } else {
        j--;
      }
    }

    final denom = math.min(n, m);
    if (denom == 0 || deltas.isEmpty) {
      return const CrossSourceAlignment(
        matchRatio: 0.0,
        medianShiftSeconds: 0.0,
        matchedPairs: 0,
      );
    }
    deltas.sort();
    final mid = deltas.length >> 1;
    final medianShift = deltas.length.isOdd
        ? deltas[mid]
        : (deltas[mid - 1] + deltas[mid]) / 2.0;

    return CrossSourceAlignment(
      matchRatio: deltas.length / denom,
      medianShiftSeconds: medianShift,
      matchedPairs: deltas.length,
    );
  }

  /// 使用其他独立来源的候选为主候选进行交叉时间一致性验证，并在主候选缺少译文/罗马音时安全借入合并。
  static CrossSourceEnrichment enrichWithCrossSource(
    LyricCandidate primary,
    List<LyricCandidate> others,
  ) {
    if (!primary.isSynced || others.isEmpty) {
      return CrossSourceEnrichment(
        candidate: primary,
        crossSourceAgreed: false,
        borrowedTranslation: false,
        borrowedRomaji: false,
      );
    }

    final primaryMainRows = extractPrimaryRows(primary.lrcContent);
    if (primaryMainRows.isEmpty) {
      return CrossSourceEnrichment(
        candidate: primary,
        crossSourceAgreed: false,
        borrowedTranslation: false,
        borrowedRomaji: false,
      );
    }

    var agreed = false;
    var current = primary;
    var borrowedTrans = false;
    var borrowedRoma = false;

    for (final other in others) {
      if (!other.isSynced || other.source == primary.source) continue;
      final otherMainRows = extractPrimaryRows(other.lrcContent);
      if (otherMainRows.isEmpty) continue;
      final align = crossSourceAlign(primaryMainRows, otherMainRows);
      if (align.matchRatio >= crossVerifyMinMatchRatio &&
          align.medianShiftSeconds.abs() <= crossVerifyMaxMedianShiftSeconds) {
        agreed = true;
      }

      if (align.matchRatio < crossBorrowMinMatchRatio) continue;

      List<TimedLyricEntry> transToBorrow = const [];
      if (!current.hasTranslation && other.hasTranslation) {
        transToBorrow = other.translationLrc.trim().isNotEmpty
            ? _extractAuxTrackEntries(other.translationLrc)
            : extractTranslationRows(other.lrcContent);
      }

      List<TimedLyricEntry> romaToBorrow = const [];
      if (!current.hasRomaji && other.hasRomaji) {
        romaToBorrow = other.romajiLrc.trim().isNotEmpty
            ? _extractAuxTrackEntries(other.romajiLrc)
            : extractRomajiRows(other.lrcContent);
      }

      if (transToBorrow.isEmpty && romaToBorrow.isEmpty) continue;

      final merged = _attachBorrowedTracks(
        baseLrc: current.lrcContent,
        baseMainRows: primaryMainRows,
        translationRows: transToBorrow,
        romajiRows: romaToBorrow,
        timeShiftSeconds: align.medianShiftSeconds,
      );
      if (merged.addedTranslation || merged.addedRomaji) {
        current = current.copyWith(
          lrcContent: merged.lrcContent,
          hasTranslation: current.hasTranslation || merged.addedTranslation,
          hasRomaji: current.hasRomaji || merged.addedRomaji,
        );
        borrowedTrans = borrowedTrans || merged.addedTranslation;
        borrowedRoma = borrowedRoma || merged.addedRomaji;
      }
    }

    return CrossSourceEnrichment(
      candidate: current,
      crossSourceAgreed: agreed,
      borrowedTranslation: borrowedTrans,
      borrowedRomaji: borrowedRoma,
    );
  }

  /// 从增强 LRC 中提取主唱原文行（按时间槽去重，排除译文、`bg:` 与 `roma:` 行）。
  static List<TimedLyricEntry> extractPrimaryRows(String lrcContent) {
    final cleaned = LyricCleaner.clean(lrcContent);
    if (cleaned.isPlaceholder) return const [];
    return cleaned.lines;
  }

  /// 从已合并的增强 LRC 中提取同时间戳译文行。
  static List<TimedLyricEntry> extractTranslationRows(String lrcContent) {
    final entries = LyricCleaner.parseTimedEntries(lrcContent)
      ..sort((a, b) => a.timeSeconds.compareTo(b.timeSeconds));
    final out = <TimedLyricEntry>[];
    double? slotTime;
    String? slotPrimary;
    for (final entry in entries) {
      if (entry.rawBody.startsWith('bg:') || entry.rawBody.startsWith('roma:')) {
        continue;
      }
      if (slotTime == null || (entry.timeSeconds - slotTime).abs() > 0.05) {
        slotTime = entry.timeSeconds;
        slotPrimary = entry.text;
        continue;
      }
      final filtered = _filterSecondaryText(entry.text, slotPrimary ?? '');
      if (filtered != null) {
        out.add(
          TimedLyricEntry(timeSeconds: entry.timeSeconds, text: filtered),
        );
      }
    }
    return out;
  }

  /// 从已合并的增强 LRC 中提取 `roma:` 罗马音行。
  static List<TimedLyricEntry> extractRomajiRows(String lrcContent) {
    final entries = LyricCleaner.parseTimedEntries(lrcContent)
      ..sort((a, b) => a.timeSeconds.compareTo(b.timeSeconds));
    final out = <TimedLyricEntry>[];
    for (final entry in entries) {
      if (!entry.rawBody.startsWith('roma:')) continue;
      final body = entry.rawBody.substring(5).trim();
      if (body.isNotEmpty) {
        out.add(TimedLyricEntry(timeSeconds: entry.timeSeconds, text: body));
      }
    }
    return out;
  }

  static ({String lrcContent, bool addedTranslation, bool addedRomaji})
  _attachBorrowedTracks({
    required String baseLrc,
    required List<TimedLyricEntry> baseMainRows,
    required List<TimedLyricEntry> translationRows,
    required List<TimedLyricEntry> romajiRows,
    required double timeShiftSeconds,
  }) {
    final transMap = translationRows.isEmpty
        ? const <int, String>{}
        : alignTrackWithDp(
            baseMainRows,
            translationRows,
            timeShiftSeconds: timeShiftSeconds,
          );
    final romaMap = romajiRows.isEmpty
        ? const <int, String>{}
        : alignTrackWithDp(
            baseMainRows,
            romajiRows,
            timeShiftSeconds: timeShiftSeconds,
          );

    if (transMap.isEmpty && romaMap.isEmpty) {
      return (
        lrcContent: baseLrc,
        addedTranslation: false,
        addedRomaji: false,
      );
    }

    // 将原有增强 LRC 中的行按主槽位分组，保持原有逐字标签、译文、和声行丝毫不损。
    final allBaseEntries = LyricCleaner.parseTimedEntries(baseLrc)
      ..sort((a, b) => a.timeSeconds.compareTo(b.timeSeconds));
    final slotBuckets = <int, List<TimedLyricEntry>>{};
    var slotIdx = 0;
    for (final entry in allBaseEntries) {
      while (slotIdx + 1 < baseMainRows.length &&
          (entry.timeSeconds - baseMainRows[slotIdx + 1].timeSeconds).abs() <
              (entry.timeSeconds - baseMainRows[slotIdx].timeSeconds).abs()) {
        slotIdx++;
      }
      slotBuckets.putIfAbsent(slotIdx, () => []).add(entry);
    }

    final buf = StringBuffer();
    var addedTrans = false;
    var addedRoma = false;
    for (var i = 0; i < baseMainRows.length; i++) {
      final main = baseMainRows[i];
      final tag = TtmlLyricConverter.formatLrcTag(main.timeSeconds);
      final bucket = slotBuckets[i] ?? [main];
      var wroteLead = false;
      for (final e in bucket) {
        buf.writeln('[$tag]${e.effectiveBody}');
        if (!wroteLead &&
            !e.rawBody.startsWith('bg:') &&
            !e.rawBody.startsWith('roma:')) {
          wroteLead = true;
          final borrowedT = _filterSecondaryText(transMap[i], main.text);
          if (borrowedT != null) {
            addedTrans = true;
            buf.writeln('[$tag]$borrowedT');
          }
        }
      }
      final borrowedR = _filterSecondaryText(romaMap[i], main.text);
      if (borrowedR != null) {
        addedRoma = true;
        buf.writeln('[$tag]roma:$borrowedR');
      }
    }

    return (
      lrcContent: buf.toString().trimRight(),
      addedTranslation: addedTrans,
      addedRomaji: addedRoma,
    );
  }

  static List<TimedLyricEntry> _extractAuxTrackEntries(String rawLrc) {
    if (rawLrc.trim().isEmpty) return const [];
    final entries = LyricCleaner.parseTimedEntries(rawLrc)
      ..sort((a, b) => a.timeSeconds.compareTo(b.timeSeconds));
    final out = <TimedLyricEntry>[];
    for (final e in entries) {
      final text = e.text.trim();
      if (text.isEmpty) continue;
      if (LyricCleaner.isContributorOrNoiseLine(text)) continue;
      if (LyricCleaner.isPlaceholderLine(text)) continue;
      if (LyricCleaner.isCreditLine(
        text,
        timeSeconds: e.timeSeconds,
        isLeadingSection: out.isEmpty,
      )) {
        continue;
      }
      out.add(TimedLyricEntry(timeSeconds: e.timeSeconds, text: text));
    }
    return out;
  }

  static String? _filterSecondaryText(String? candidate, String primary) {
    if (candidate == null) return null;
    final trimmed = candidate.trim();
    if (trimmed.isEmpty) return null;
    if (LyricCleaner.isContributorOrNoiseLine(trimmed)) return null;
    final normCand = trimmed.replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
    final normPrim = primary.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
    if (normCand == normPrim) return null;
    return trimmed;
  }

  static bool _isLikelyOriginalOverChineseTranslation(
    String candidate,
    String currentPrimary,
  ) {
    final candHasKana = _kanaRegex.hasMatch(candidate);
    final primHasKana = _kanaRegex.hasMatch(currentPrimary);
    return candHasKana && !primHasKana && _cjkHanRegex.hasMatch(currentPrimary);
  }

  static bool _linesTextMatch(String keyA, String keyB) {
    if (keyA.isEmpty || keyB.isEmpty) return false;
    if (keyA == keyB) return true;
    final shorter = keyA.length <= keyB.length ? keyA : keyB;
    final longer = keyA.length <= keyB.length ? keyB : keyA;
    if (shorter.length >= 4 && longer.contains(shorter)) return true;
    return WorkMatcherScoring.bigramDice(keyA, keyB) >= 0.65;
  }

  static Map<int, String> _alignGreedyWindow(
    List<TimedLyricEntry> mainRows,
    List<TimedLyricEntry> auxRows,
  ) {
    final result = <int, String>{};
    var j = 0;
    for (var i = 0; i < mainRows.length && j < auxRows.length; i++) {
      final t = mainRows[i].timeSeconds;
      while (j + 1 < auxRows.length &&
          (auxRows[j + 1].timeSeconds - t).abs() <=
              (auxRows[j].timeSeconds - t).abs()) {
        j++;
      }
      if ((auxRows[j].timeSeconds - t).abs() <= maxDpMatchGapSeconds) {
        result[i] = auxRows[j].text;
        j++;
      }
    }
    return result;
  }
}
