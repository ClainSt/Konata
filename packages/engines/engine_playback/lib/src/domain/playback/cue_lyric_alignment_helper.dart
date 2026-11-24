import 'dart:math' as math;

/// 单条带时间轴的歌词行（供 CUE/LRC 解析与跨轨时间对齐复用）。
class CueTimedLyricEntry {
  /// 创建带时间戳的歌词条目。
  const CueTimedLyricEntry({
    required this.timeSeconds,
    required this.text,
    this.rawBody = '',
  });

  /// 起始时间（秒）。
  final double timeSeconds;

  /// 纯展示文本。
  final String text;

  /// 保留原始行内标签的正文。
  final String rawBody;
}

/// CUE/LRC 解析器专用的轻量 HTML 实体解码与动态规划时间轴对齐助手。
abstract final class CueLyricAlignmentHelper {
  /// 精确时间配对优先阈值（秒）。
  static const double tightMatchToleranceSeconds = 0.15;

  /// DP 单调配对最大允许时间差（秒），超出禁止强行错配。
  static const double maxDpMatchGapSeconds = 1.20;

  /// DP 跳过单行的惩罚代价（秒）。
  static const double dpSkipPenaltySeconds = 0.85;

  static final RegExp _htmlNumericEntityRegex = RegExp(
    r'&#(x?[0-9a-fA-F]+);',
  );

  /// 解码歌词文本中常见的 HTML 字符实体。
  static String decodeHtmlEntities(String raw) {
    if (!raw.contains('&')) {
      return raw;
    }
    var text = raw
        .replaceAll('&apos;', "'")
        .replaceAll('&quot;', '"')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&');
    if (!text.contains('&#')) {
      return text;
    }
    text = text.replaceAllMapped(_htmlNumericEntityRegex, (m) {
      final token = m.group(1) ?? '';
      final code = token.startsWith('x') || token.startsWith('X')
          ? int.tryParse(token.substring(1), radix: 16)
          : int.tryParse(token);
      if (code == null || code <= 0 || code > 0x10FFFF) {
        return m.group(0)!;
      }
      return String.fromCharCode(code);
    });
    return text;
  }

  /// 使用带跳过惩罚的动态规划求主轨与辅助轨（译文/罗马音）的单调最小时间差对齐。
  static Map<int, String> alignTrackWithDp(
    List<CueTimedLyricEntry> mainRows,
    List<CueTimedLyricEntry> auxRows, {
    double timeShiftSeconds = 0.0,
  }) {
    if (mainRows.isEmpty || auxRows.isEmpty) {
      return const <int, String>{};
    }
    final shiftedAux = timeShiftSeconds == 0.0
        ? auxRows
        : <CueTimedLyricEntry>[
            for (final e in auxRows)
              CueTimedLyricEntry(
                timeSeconds: math.max(0.0, e.timeSeconds + timeShiftSeconds),
                text: e.text,
                rawBody: e.rawBody,
              ),
          ];

    final n = mainRows.length;
    final m = shiftedAux.length;
    // 防御极端超长输入导致数组膨胀，超过阈值时退化为滑动窗口双指针。
    if (n * m > 160000) {
      return _alignGreedyWindow(mainRows, shiftedAux);
    }

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
          // 精确容差内额外折减代价，确保优先于远距离配对。
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

  static Map<int, String> _alignGreedyWindow(
    List<CueTimedLyricEntry> mainRows,
    List<CueTimedLyricEntry> auxRows,
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
