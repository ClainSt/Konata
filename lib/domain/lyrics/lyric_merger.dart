import 'dart:math' as math;
import 'dart:typed_data';

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
  static final RegExp _whitespaceRegex = RegExp(r'\s+');

  /// 合并同一来源的原文、译文与罗马音 LRC（先清洗噪声，再按两阶段 + 带跳过 DP 单调配对）。
  ///
  /// 当同一来源同时提供逐字对齐辅助轨（如网易云 `ytlrc` / `yromalrc`）与完整行级辅助轨
  /// （如 `tlyric` / `romalrc`）时，优先采用主辅助轨并自动用完整兜底轨填补残缺漏句。
  static SameSourceMergeResult mergeSameSource({
    required String mainLrc,
    String translationLrc = '',
    String fallbackTranslationLrc = '',
    String romajiLrc = '',
    String fallbackRomajiLrc = '',
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

    final transMap = _alignPrimaryWithFallbackTrack(
      mainRows,
      primaryLrc: translationLrc,
      fallbackLrc: fallbackTranslationLrc,
    );
    final romaMap = _alignPrimaryWithFallbackTrack(
      mainRows,
      primaryLrc: romajiLrc,
      fallbackLrc: fallbackRomajiLrc,
    );

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

  /// 对两份同步歌词原文行执行稀疏倒排 + 耐心排序（Hunt-Szymanski）精确 LCS 序列对齐，返回对齐比例与时间差中位数。
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
    if (primaryRows.length * otherRows.length > 160000) {
      return const CrossSourceAlignment(
        matchRatio: 0.0,
        medianShiftSeconds: 0.0,
        matchedPairs: 0,
      );
    }
    final trackA = _PreparedLyricTrack.fromRows(0, primaryRows);
    final trackB = _PreparedLyricTrack.fromRows(1, otherRows);
    return _alignPreparedTracks(trackA, trackB);
  }

  /// 使用其他独立来源的候选为主候选进行交叉时间一致性验证，并在主候选缺少译文/罗马音时安全借入合并。
  static CrossSourceEnrichment enrichWithCrossSource(
    LyricCandidate primary,
    List<LyricCandidate> others, {
    LyricCrossSourceCache? cache,
  }) {
    if (!primary.isSynced || others.isEmpty) {
      return CrossSourceEnrichment(
        candidate: primary,
        crossSourceAgreed: false,
        borrowedTranslation: false,
        borrowedRomaji: false,
      );
    }
    final activeCache = cache ?? LyricCrossSourceCache();
    return activeCache.enrich(primary, others);
  }

  /// 基于预计算行签名与稀疏倒排索引执行精确最长公共子序列对齐（零热路径子串分配）。
  static CrossSourceAlignment _alignPreparedTracks(
    _PreparedLyricTrack trackA,
    _PreparedLyricTrack trackB,
  ) {
    final primaryRows = trackA.primaryRows;
    final otherRows = trackB.primaryRows;
    final n = primaryRows.length;
    final m = otherRows.length;
    if (n == 0 || m == 0 || n * m > 160000) {
      return const CrossSourceAlignment(
        matchRatio: 0.0,
        medianShiftSeconds: 0.0,
        matchedPairs: 0,
      );
    }

    final sigA = trackA.signatures;
    final sigB = trackB.signatures;
    final invB = trackB.bigramIndex;
    final singleCharB = trackB.singleCharIndex;

    // 按 i 递增遍历主轨行，借助倒排索引仅对共享双字或单字相等的候选列求值，
    // 再按列号降序更新耐心排序尾数组以求精确 LCS 长度并回溯时间差。
    final tailsJ = <int>[];
    final tailsNode = <int>[];
    final nodeI = <int>[];
    final nodeJ = <int>[];
    final nodePrev = <int>[];
    final seenStamp = Int32List(m);
    final matchedCols = <int>[];

    for (var i = 0; i < n; i++) {
      final sa = sigA[i];
      if (sa.key.isEmpty) continue;
      matchedCols.clear();
      if (sa.key.length == 1) {
        final list = singleCharB[sa.key.codeUnitAt(0)];
        if (list != null) {
          matchedCols.addAll(list);
        }
      } else {
        final stamp = i + 1;
        var visited = 0;
        var prevBigram = -1;
        final bg = sa.sortedBigrams;
        for (var k = 0; k < bg.length && visited < m; k++) {
          final g = bg[k];
          if (g == prevBigram) continue;
          prevBigram = g;
          final list = invB[g];
          if (list == null) continue;
          for (var p = 0; p < list.length; p++) {
            final j = list[p];
            if (seenStamp[j] == stamp) continue;
            seenStamp[j] = stamp;
            visited++;
            if (_signaturesMatch(sa, sigB[j])) {
              matchedCols.add(j);
            }
            if (visited >= m) break;
          }
        }
      }
      if (matchedCols.isEmpty) continue;
      if (matchedCols.length > 1) {
        matchedCols.sort((a, b) => b.compareTo(a));
      }
      for (var c = 0; c < matchedCols.length; c++) {
        final j = matchedCols[c];
        var lo = 0;
        var hi = tailsJ.length;
        while (lo < hi) {
          final mid = (lo + hi) >> 1;
          if (tailsJ[mid] < j) {
            lo = mid + 1;
          } else {
            hi = mid;
          }
        }
        final prevNode = lo > 0 ? tailsNode[lo - 1] : -1;
        final id = nodeI.length;
        nodeI.add(i);
        nodeJ.add(j);
        nodePrev.add(prevNode);
        if (lo == tailsJ.length) {
          tailsJ.add(j);
          tailsNode.add(id);
        } else {
          tailsJ[lo] = j;
          tailsNode[lo] = id;
        }
      }
    }

    final denom = math.min(n, m);
    if (denom == 0 || tailsNode.isEmpty) {
      return const CrossSourceAlignment(
        matchRatio: 0.0,
        medianShiftSeconds: 0.0,
        matchedPairs: 0,
      );
    }

    final deltas = <double>[];
    var cur = tailsNode.last;
    while (cur != -1) {
      deltas.add(
        primaryRows[nodeI[cur]].timeSeconds -
            otherRows[nodeJ[cur]].timeSeconds,
      );
      cur = nodePrev[cur];
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

  static bool _signaturesMatch(_LineSignature a, _LineSignature b) {
    final ka = a.key;
    final kb = b.key;
    if (ka.isEmpty || kb.isEmpty) return false;
    if (ka == kb) return true;
    final aShorter = ka.length <= kb.length;
    final shortSig = aShorter ? a : b;
    final longSig = aShorter ? b : a;
    // 字符位掩码为子串包含的必要条件，不满足时 O(1) 排除以省去子串扫描。
    if (shortSig.key.length >= 4 &&
        (shortSig.charMask & longSig.charMask) == shortSig.charMask &&
        longSig.key.contains(shortSig.key)) {
      return true;
    }

    final ga = a.sortedBigrams;
    final gb = b.sortedBigrams;
    final na = ga.length;
    final nb = gb.length;
    if (na == 0 || nb == 0) return false;
    if ((a.bigramMask & b.bigramMask) == 0) return false;
    final total = na + nb;
    // 2 * shared / total >= 0.65 等价于 200 * shared >= 65 * total。
    final minShared = (65 * total + 199) ~/ 200;
    final maxPossible = na < nb ? na : nb;
    if (maxPossible < minShared) return false;

    var i = 0;
    var j = 0;
    var shared = 0;
    while (i < na && j < nb) {
      final remA = na - i;
      final remB = nb - j;
      if (shared + (remA < remB ? remA : remB) < minShared) return false;
      final va = ga[i];
      final vb = gb[j];
      if (va == vb) {
        shared++;
        if (shared >= minShared && (2.0 * shared / total) >= 0.65) {
          return true;
        }
        i++;
        j++;
      } else if (va < vb) {
        i++;
      } else {
        j++;
      }
    }
    return shared >= minShared && (2.0 * shared / total) >= 0.65;
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

  static Map<int, String> _alignPrimaryWithFallbackTrack(
    List<TimedLyricEntry> mainRows, {
    required String primaryLrc,
    required String fallbackLrc,
  }) {
    final primaryEntries = _extractAuxTrackEntries(primaryLrc);
    final fallbackEntries = _extractAuxTrackEntries(fallbackLrc);
    if (primaryEntries.isEmpty && fallbackEntries.isEmpty) {
      return const <int, String>{};
    }
    if (primaryEntries.isEmpty) {
      return alignTrackWithDp(mainRows, fallbackEntries);
    }
    final primaryMap = alignTrackWithDp(mainRows, primaryEntries);
    if (fallbackEntries.isEmpty) {
      return primaryMap;
    }
    final fallbackMap = alignTrackWithDp(mainRows, fallbackEntries);
    if (fallbackMap.isEmpty) return primaryMap;
    final merged = <int, String>{...primaryMap};
    for (final entry in fallbackMap.entries) {
      merged.putIfAbsent(entry.key, () => entry.value);
    }
    return merged;
  }

  static ({Set<int> transSlots, Set<int> romaSlots}) _inspectSlotCoverage(
    String baseLrc,
    List<TimedLyricEntry> baseMainRows,
  ) {
    final allEntries = LyricCleaner.parseTimedEntries(baseLrc)
      ..sort((a, b) => a.timeSeconds.compareTo(b.timeSeconds));
    final transSlots = <int>{};
    final romaSlots = <int>{};
    final sawLeadInSlot = <int>{};
    var slotIdx = 0;
    for (final entry in allEntries) {
      while (slotIdx + 1 < baseMainRows.length &&
          (entry.timeSeconds - baseMainRows[slotIdx + 1].timeSeconds).abs() <
              (entry.timeSeconds - baseMainRows[slotIdx].timeSeconds).abs()) {
        slotIdx++;
      }
      if (entry.rawBody.startsWith('roma:')) {
        if (entry.rawBody.substring(5).trim().isNotEmpty) {
          romaSlots.add(slotIdx);
        }
        continue;
      }
      if (entry.rawBody.startsWith('bg:')) {
        continue;
      }
      if (sawLeadInSlot.add(slotIdx)) {
        continue;
      }
      if (_filterSecondaryText(entry.text, baseMainRows[slotIdx].text) != null) {
        transSlots.add(slotIdx);
      }
    }
    return (transSlots: transSlots, romaSlots: romaSlots);
  }

  static ({String lrcContent, bool addedTranslation, bool addedRomaji})
  _attachBorrowedTracks({
    required String baseLrc,
    required List<TimedLyricEntry> baseMainRows,
    required Set<int> existingTransSlots,
    required Set<int> existingRomaSlots,
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
          if (!existingTransSlots.contains(i)) {
            final borrowedT = _filterSecondaryText(transMap[i], main.text);
            if (borrowedT != null) {
              addedTrans = true;
              buf.writeln('[$tag]$borrowedT');
            }
          }
        }
      }
      if (!existingRomaSlots.contains(i)) {
        final borrowedR = _filterSecondaryText(romaMap[i], main.text);
        if (borrowedR != null) {
          addedRoma = true;
          buf.writeln('[$tag]roma:$borrowedR');
        }
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
    final normCand = trimmed.replaceAll(_whitespaceRegex, ' ').toLowerCase();
    final normPrim = primary
        .trim()
        .replaceAll(_whitespaceRegex, ' ')
        .toLowerCase();
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

/// 单次歌词竞速或手动重搜会话内的跨源对齐与预解析缓存。
///
/// 在同一批候选的多次重算间复用意图清洗结果、行级签名索引、覆盖槽位与对称两两对齐结果，
/// 彻底消除 `O(K^3 * N * M)` 重复解析与重复序列对齐造成的主线程卡顿。
class LyricCrossSourceCache {
  final Map<String, _PreparedLyricTrack> _tracksByLrc = {};
  final Map<int, CrossSourceAlignment> _pairAlignments = {};
  final Map<String, List<TimedLyricEntry>> _auxEntriesCache = {};
  int _nextTrackId = 0;

  /// 获取候选歌词的缓存清洗结果（同一正文仅清洗一次）。
  CleanedLyricResult cleanedFor(LyricCandidate candidate) {
    return _trackForLrc(candidate.lrcContent).cleaned;
  }

  /// 计算或复用两份同步候选的对称跨源原文对齐结果。
  CrossSourceAlignment align(LyricCandidate primary, LyricCandidate other) {
    final trackA = _trackForLrc(primary.lrcContent);
    final trackB = _trackForLrc(other.lrcContent);
    return _alignTracks(trackA, trackB);
  }

  /// 复用缓存对主候选执行跨源一致性验证与缺失译文/罗马音回填。
  CrossSourceEnrichment enrich(
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

    final primaryTrack = _trackForLrc(primary.lrcContent);
    final primaryMainRows = primaryTrack.primaryRows;
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
    ({Set<int> transSlots, Set<int> romaSlots})? coverage;

    for (final other in others) {
      if (!other.isSynced || other.source == primary.source) continue;
      final otherTrack = _trackForLrc(other.lrcContent);
      if (otherTrack.primaryRows.isEmpty) continue;

      final canInspectTrans = other.hasTranslation;
      final canInspectRoma = other.hasRomaji;
      if (agreed && !canInspectTrans && !canInspectRoma) {
        continue;
      }

      if (agreed && (canInspectTrans || canInspectRoma)) {
        coverage ??= primaryTrack.initialCoverage;
        final needTrans =
            canInspectTrans &&
            coverage.transSlots.length < primaryMainRows.length;
        final needRoma =
            canInspectRoma &&
            coverage.romaSlots.length < primaryMainRows.length;
        if (!needTrans && !needRoma) continue;
      }

      final align = _alignTracks(primaryTrack, otherTrack);
      if (align.matchRatio >= LyricMerger.crossVerifyMinMatchRatio &&
          align.medianShiftSeconds.abs() <=
              LyricMerger.crossVerifyMaxMedianShiftSeconds) {
        agreed = true;
      }

      if (align.matchRatio < LyricMerger.crossBorrowMinMatchRatio) continue;
      if (!canInspectTrans && !canInspectRoma) continue;

      coverage ??= primaryTrack.initialCoverage;
      List<TimedLyricEntry> transToBorrow = const [];
      if (canInspectTrans &&
          coverage.transSlots.length < primaryMainRows.length) {
        transToBorrow = _translationRowsFor(other, otherTrack);
      }

      List<TimedLyricEntry> romaToBorrow = const [];
      if (canInspectRoma &&
          coverage.romaSlots.length < primaryMainRows.length) {
        romaToBorrow = _romajiRowsFor(other, otherTrack);
      }

      if (transToBorrow.isEmpty && romaToBorrow.isEmpty) continue;

      final merged = LyricMerger._attachBorrowedTracks(
        baseLrc: current.lrcContent,
        baseMainRows: primaryMainRows,
        existingTransSlots: coverage.transSlots,
        existingRomaSlots: coverage.romaSlots,
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
        coverage = LyricMerger._inspectSlotCoverage(
          current.lrcContent,
          primaryMainRows,
        );
      }
    }

    return CrossSourceEnrichment(
      candidate: current,
      crossSourceAgreed: agreed,
      borrowedTranslation: borrowedTrans,
      borrowedRomaji: borrowedRoma,
    );
  }

  _PreparedLyricTrack _trackForLrc(String lrcContent) {
    return _tracksByLrc.putIfAbsent(
      lrcContent,
      () => _PreparedLyricTrack.fromLrc(_nextTrackId++, lrcContent),
    );
  }

  CrossSourceAlignment _alignTracks(
    _PreparedLyricTrack trackA,
    _PreparedLyricTrack trackB,
  ) {
    if (trackA.primaryRows.isEmpty || trackB.primaryRows.isEmpty) {
      return const CrossSourceAlignment(
        matchRatio: 0.0,
        medianShiftSeconds: 0.0,
        matchedPairs: 0,
      );
    }
    if (trackA.id == trackB.id) {
      return CrossSourceAlignment(
        matchRatio: 1.0,
        medianShiftSeconds: 0.0,
        matchedPairs: trackA.primaryRows.length,
      );
    }
    final swapped = trackA.id > trackB.id;
    final lo = swapped ? trackB : trackA;
    final hi = swapped ? trackA : trackB;
    final pairKey = (lo.id << 24) | hi.id;
    final cached = _pairAlignments.putIfAbsent(
      pairKey,
      () => LyricMerger._alignPreparedTracks(lo, hi),
    );
    if (!swapped) return cached;
    return CrossSourceAlignment(
      matchRatio: cached.matchRatio,
      medianShiftSeconds: cached.medianShiftSeconds == 0.0
          ? 0.0
          : -cached.medianShiftSeconds,
      matchedPairs: cached.matchedPairs,
    );
  }

  List<TimedLyricEntry> _translationRowsFor(
    LyricCandidate other,
    _PreparedLyricTrack track,
  ) {
    if (other.translationLrc.trim().isNotEmpty) {
      return _auxEntriesCache.putIfAbsent(
        't::${other.translationLrc}',
        () => LyricMerger._extractAuxTrackEntries(other.translationLrc),
      );
    }
    return track.embeddedTranslationRows;
  }

  List<TimedLyricEntry> _romajiRowsFor(
    LyricCandidate other,
    _PreparedLyricTrack track,
  ) {
    if (other.romajiLrc.trim().isNotEmpty) {
      return _auxEntriesCache.putIfAbsent(
        'r::${other.romajiLrc}',
        () => LyricMerger._extractAuxTrackEntries(other.romajiLrc),
      );
    }
    return track.embeddedRomajiRows;
  }
}

final class _LineSignature {
  const _LineSignature(
    this.key,
    this.charMask,
    this.bigramMask,
    this.sortedBigrams,
  );

  final String key;
  final int charMask;
  final int bigramMask;
  final Int32List sortedBigrams;

  static final Int32List _empty = Int32List(0);

  factory _LineSignature.fromKey(String key) {
    final len = key.length;
    if (len == 0) return _LineSignature(key, 0, 0, _empty);
    var cMask = 0;
    for (var i = 0; i < len; i++) {
      cMask |= 1 << (key.codeUnitAt(i) & 63);
    }
    if (len < 2) return _LineSignature(key, cMask, 0, _empty);
    final bgLen = len - 1;
    final bg = Int32List(bgLen);
    var bMask = 0;
    var prev = key.codeUnitAt(0);
    for (var i = 0; i < bgLen; i++) {
      final next = key.codeUnitAt(i + 1);
      bg[i] = (prev << 16) | next;
      bMask |= 1 << (((prev * 31) ^ next) & 63);
      prev = next;
    }
    bg.sort();
    return _LineSignature(key, cMask, bMask, bg);
  }
}

final class _PreparedLyricTrack {
  _PreparedLyricTrack._({
    required this.id,
    required this.rawLrc,
    required this.cleaned,
    required this.primaryRows,
  });

  factory _PreparedLyricTrack.fromLrc(int id, String rawLrc) {
    final cleaned = LyricCleaner.clean(rawLrc);
    final rows = cleaned.isPlaceholder ? const <TimedLyricEntry>[] : cleaned.lines;
    return _PreparedLyricTrack._(
      id: id,
      rawLrc: rawLrc,
      cleaned: cleaned,
      primaryRows: rows,
    );
  }

  factory _PreparedLyricTrack.fromRows(int id, List<TimedLyricEntry> rows) {
    return _PreparedLyricTrack._(
      id: id,
      rawLrc: '',
      cleaned: CleanedLyricResult(
        lines: rows,
        credits: const [],
        isPlaceholder: rows.isEmpty,
        cleanedLrc: '',
        outOfOrderRatio: 0.0,
        firstLineSeconds: rows.isEmpty ? null : rows.first.timeSeconds,
        lastLineSeconds: rows.isEmpty ? null : rows.last.timeSeconds,
      ),
      primaryRows: rows,
    );
  }

  final int id;
  final String rawLrc;
  final CleanedLyricResult cleaned;
  final List<TimedLyricEntry> primaryRows;

  List<_LineSignature>? _signatures;
  Map<int, List<int>>? _bigramIndex;
  Map<int, List<int>>? _singleCharIndex;
  ({Set<int> transSlots, Set<int> romaSlots})? _initialCoverage;
  List<TimedLyricEntry>? _embeddedTranslationRows;
  List<TimedLyricEntry>? _embeddedRomajiRows;

  List<_LineSignature> get signatures => _signatures ??= List<_LineSignature>.generate(
    primaryRows.length,
    (i) => _LineSignature.fromKey(
      WorkMatcherScoring.normalizeKey(primaryRows[i].text),
    ),
    growable: false,
  );

  Map<int, List<int>> get bigramIndex {
    if (_bigramIndex == null) _buildInvertedIndex();
    return _bigramIndex!;
  }

  Map<int, List<int>> get singleCharIndex {
    if (_singleCharIndex == null) _buildInvertedIndex();
    return _singleCharIndex!;
  }

  ({Set<int> transSlots, Set<int> romaSlots}) get initialCoverage {
    return _initialCoverage ??= LyricMerger._inspectSlotCoverage(
      rawLrc,
      primaryRows,
    );
  }

  List<TimedLyricEntry> get embeddedTranslationRows {
    return _embeddedTranslationRows ??= LyricMerger.extractTranslationRows(
      rawLrc,
    );
  }

  List<TimedLyricEntry> get embeddedRomajiRows {
    return _embeddedRomajiRows ??= LyricMerger.extractRomajiRows(rawLrc);
  }

  void _buildInvertedIndex() {
    final bgMap = <int, List<int>>{};
    final scMap = <int, List<int>>{};
    final sigs = signatures;
    for (var j = 0; j < sigs.length; j++) {
      final sig = sigs[j];
      if (sig.key.isEmpty) continue;
      if (sig.key.length == 1) {
        scMap.putIfAbsent(sig.key.codeUnitAt(0), () => <int>[]).add(j);
        continue;
      }
      var prev = -1;
      final bg = sig.sortedBigrams;
      for (var k = 0; k < bg.length; k++) {
        final g = bg[k];
        if (g == prev) continue;
        prev = g;
        bgMap.putIfAbsent(g, () => <int>[]).add(j);
      }
    }
    _bigramIndex = bgMap;
    _singleCharIndex = scMap;
  }
}
