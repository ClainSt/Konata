import 'dart:math' as math;

/// 动漫音乐曲目版本标签（用于歌词候选版本消歧）。
enum TrackVersionTag {
  tvSize,
  shortVer,
  fullVer,
  live,
  acoustic,
  remix,
  characterVoice,
  featuring,
}

/// 单个逐字/和声歌词片段（完整保留起始与结束时间，支持词间停顿与主唱/和声并行扫光）。
class TimedLyricSpan {
  /// 创建逐字时间片段。
  const TimedLyricSpan({
    required this.startSeconds,
    required this.endSeconds,
    required this.text,
    this.isHarmony = false,
  });

  /// 片段起始时刻（秒）。
  final double startSeconds;

  /// 片段精确结束时刻（秒，来源于 TTML `end`、YRC/QRC 字时长或相邻标签边界）。
  final double endSeconds;

  /// 当前片段展示文本。
  final String text;

  /// 是否属于和声/背景人声并行层。
  final bool isHarmony;

  /// 计算指定播放时刻 [positionSeconds] 在当前字/片段上的扫光进度（`[0.0, 1.0]`）。
  double sweepProgressAt(double positionSeconds) {
    if (positionSeconds <= startSeconds) return 0.0;
    if (positionSeconds >= endSeconds || endSeconds <= startSeconds) return 1.0;
    return ((positionSeconds - startSeconds) / (endSeconds - startSeconds))
        .clamp(0.0, 1.0);
  }

  /// 判断当前时刻是否落在该时间跨度激活区间内。
  bool isActiveAt(double positionSeconds) {
    return positionSeconds >= startSeconds && positionSeconds <= endSeconds;
  }
}

/// 逐字歌词时间单元语义别名（与 [TimedLyricSpan] 同构，零重复模型）。
typedef LyricWord = TimedLyricSpan;

/// 支持主唱与和声并行 Active Span Set 的增强歌词行。
class ActiveSpanLyricLine {
  /// 创建增强歌词行。
  const ActiveSpanLyricLine({
    required this.startSeconds,
    required this.endSeconds,
    required this.spans,
    this.translation = '',
  });

  final double startSeconds;
  final double endSeconds;
  final List<TimedLyricSpan> spans;
  final String translation;

  /// 返回指定时刻同时激活的全部主唱与和声片段集合（支持并行重叠扫光）。
  List<TimedLyricSpan> activeSpansAt(double positionSeconds) {
    return spans
        .where((span) => span.isActiveAt(positionSeconds))
        .toList(growable: false);
  }
}

/// 动漫音乐版本消歧歌词匹配器与 Active Span Set 逐字和声解析器（纯领域算法）。
class LyricVersionMatcher {
  LyricVersionMatcher._();

  static final RegExp _instrumentalRegex = RegExp(
    r'(?:^|[\s(\[（【\-_.])(?:instrumental|off[\s._-]*vocal|karaoke|inst\.?|bgm|カラオケ|オフボーカル|伴奏|纯音乐)(?:$|[\s)\]）】\-_.])',
    caseSensitive: false,
  );
  static final RegExp _tvSizeRegex = RegExp(
    r'\b(?:tv[\s._-]*size|tv[\s._-]*ver\.?|op[\s._-]*size|ed[\s._-]*size|anime[\s._-]*size)\b',
    caseSensitive: false,
  );
  static final RegExp _shortVerRegex = RegExp(
    r'\b(?:short[\s._-]*ver\.?|short[\s._-]*edit|radio[\s._-]*edit)\b',
    caseSensitive: false,
  );
  static final RegExp _fullVerRegex = RegExp(
    r'\b(?:full[\s._-]*ver\.?|full[\s._-]*size)\b',
    caseSensitive: false,
  );
  static final RegExp _liveRegex = RegExp(
    r'\b(?:live|concert|budokan|acoustic[\s._-]*live)\b',
    caseSensitive: false,
  );
  static final RegExp _acousticRegex = RegExp(
    r'\b(?:acoustic|unplugged|piano[\s._-]*ver\.?)\b',
    caseSensitive: false,
  );
  static final RegExp _remixRegex = RegExp(
    r'\b(?:remix|arrange|ver\.?\s*2|eurobeat)\b',
    caseSensitive: false,
  );
  static final RegExp _cvRegex = RegExp(
    r'(?:\bcv\.?\b|キャラクターソング|キャラソン)',
    caseSensitive: false,
  );
  static final RegExp _featRegex = RegExp(
    r'\b(?:feat\.?|ft\.?|featuring|with)\b',
    caseSensitive: false,
  );

  /// 匹配行内逐字时间标签：同时兼容标准 `<mm:ss.xx>` 与带精确结束时间的 `<mm:ss.xxx-mm:ss.xxx>`。
  static final RegExp _wordTagRegex = RegExp(
    r'<(\d{1,2}):(\d{2})(?:[.:](\d{1,3}))?(?:-(\d{1,2}):(\d{2})(?:[.:](\d{1,3}))?)?>',
  );
  static final RegExp _harmonyLineRegex = RegExp(
    r'^\[\d{1,2}:\d{2}(?:[.:]\d{1,3})?\]\s*bg:',
    multiLine: true,
  );
  static final RegExp _offsetTagRegex = RegExp(
    r'^\[offset\s*:\s*([+-]?\d+)\s*\]$',
    caseSensitive: false,
  );
  static final RegExp _linePrefixRegex = RegExp(
    r'^\[(\d{1,2}):(\d{2})(?:[.:](\d{1,3}))?\](.*)$',
  );
  static final RegExp _bracketPunctRegex = RegExp(r'[\(\)\[\]（）【】\-_]+');
  static final RegExp _spacesRegex = RegExp(r'\s+');

  /// 将单个逐字片段的起始与可选精确结束秒数格式化为行内标签（毫秒精度，兼容缓存无损往返）。
  static String formatWordSpanTag(double startSeconds, [double? endSeconds]) {
    final start = math.max(0.0, startSeconds);
    if (endSeconds != null && endSeconds.isFinite) {
      final end = math.max(start, endSeconds);
      return '<${_formatMmSsMs(start)}-${_formatMmSsMs(end)}>';
    }
    return '<${_formatMmSsMs(start)}>';
  }

  /// 判断单行正文是否包含行内逐字标签。
  static bool hasInlineWordTags(String body) => _wordTagRegex.hasMatch(body);

  /// 移除单行正文中的全部行内逐字标签（同时支持含结束时间与不含结束时间格式）。
  static String stripInlineWordTags(String body) =>
      body.replaceAll(_wordTagRegex, '');

  /// 将单行正文中的全部行内逐字标签整体按 `[offset:]` 偏移平移（正值提前、负值延后，钳制非负）。
  static String shiftInlineWordTags(String body, double offsetSeconds) {
    if (offsetSeconds == 0.0 || !_wordTagRegex.hasMatch(body)) return body;
    return body.replaceAllMapped(_wordTagRegex, (m) {
      final start = math.max(
        0.0,
        _parseMmSsFrac(m.group(1)!, m.group(2)!, m.group(3)) - offsetSeconds,
      );
      if (m.group(4) != null && m.group(5) != null) {
        final end = math.max(
          start,
          _parseMmSsFrac(m.group(4)!, m.group(5)!, m.group(6)) - offsetSeconds,
        );
        return formatWordSpanTag(start, end);
      }
      return formatWordSpanTag(start);
    });
  }

  /// 判断原始歌词文本是否包含显式逐字时间戳 `<mm:ss.xx>` / `<mm:ss.xxx-mm:ss.xxx>` 或并行和声层 `bg:` 标记。
  ///
  /// 普通双语 LRC（仅原文行 + 同时间戳中文译文行）不含这两类标记，绝不能误并入主唱逐字分片。
  static bool hasExplicitEnhancedTags(String content) {
    return _wordTagRegex.hasMatch(content) || _harmonyLineRegex.hasMatch(content);
  }

  /// 判断曲目是否为伴奏/Off Vocal/纯音乐（命中时立即短路跳过远端歌词抓取）。
  static bool isInstrumentalTrack({
    required String title,
    String fileName = '',
  }) {
    return _instrumentalRegex.hasMatch(title) ||
        _instrumentalRegex.hasMatch(fileName);
  }

  /// 从曲目标题与歌手名中提取版本消歧标签集合（保留 `TV Size / Short Ver. / Live / feat. / CV`）。
  static Set<TrackVersionTag> extractVersionTags({
    required String title,
    String artist = '',
  }) {
    final combined = '$title $artist';
    final tags = <TrackVersionTag>{};
    if (_tvSizeRegex.hasMatch(combined)) tags.add(TrackVersionTag.tvSize);
    if (_shortVerRegex.hasMatch(combined)) tags.add(TrackVersionTag.shortVer);
    if (_fullVerRegex.hasMatch(combined)) tags.add(TrackVersionTag.fullVer);
    if (_liveRegex.hasMatch(combined)) tags.add(TrackVersionTag.live);
    if (_acousticRegex.hasMatch(combined)) tags.add(TrackVersionTag.acoustic);
    if (_remixRegex.hasMatch(combined)) tags.add(TrackVersionTag.remix);
    if (_cvRegex.hasMatch(combined)) tags.add(TrackVersionTag.characterVoice);
    if (_featRegex.hasMatch(combined)) tags.add(TrackVersionTag.featuring);
    return tags;
  }

  /// 去除 TV Size / Short / Full / Live / Acoustic / Remix 版本后缀与括号后的核心曲名（小写）。
  static String coreTitle(String raw) {
    return raw
        .toLowerCase()
        .replaceAll(_tvSizeRegex, ' ')
        .replaceAll(_shortVerRegex, ' ')
        .replaceAll(_fullVerRegex, ' ')
        .replaceAll(_liveRegex, ' ')
        .replaceAll(_acousticRegex, ' ')
        .replaceAll(_remixRegex, ' ')
        .replaceAll(_bracketPunctRegex, ' ')
        .replaceAll(_spacesRegex, ' ')
        .trim();
  }

  /// 解析单行正文内的逐字标签为 [TimedLyricSpan] 列表（保留精确 `end` 并统一应用 `[offset:]` 偏移）。
  static List<TimedLyricSpan> parseInlineWordSpans(
    String body, {
    required double lineStart,
    required bool isHarmony,
    double offsetSeconds = 0.0,
  }) {
    final matches = _wordTagRegex.allMatches(body).toList();
    if (matches.isEmpty) {
      return [
        TimedLyricSpan(
          startSeconds: lineStart,
          endSeconds: lineStart + 3.0,
          text: body,
          isHarmony: isHarmony,
        ),
      ];
    }

    final spans = <TimedLyricSpan>[];
    if (matches.first.start > 0) {
      final leadingText = body.substring(0, matches.first.start);
      if (leadingText.isNotEmpty) {
        final firstStart = math.max(
          0.0,
          _parseMmSsFrac(
                matches.first.group(1)!,
                matches.first.group(2)!,
                matches.first.group(3),
              ) -
              offsetSeconds,
        );
        spans.add(
          TimedLyricSpan(
            startSeconds: lineStart,
            endSeconds: math.max(lineStart, firstStart),
            text: leadingText,
            isHarmony: isHarmony,
          ),
        );
      }
    }

    for (var i = 0; i < matches.length; i++) {
      final cur = matches[i];
      final spanStart = math.max(
        0.0,
        _parseMmSsFrac(cur.group(1)!, cur.group(2)!, cur.group(3)) -
            offsetSeconds,
      );
      final textStart = cur.end;
      final textEnd = i + 1 < matches.length ? matches[i + 1].start : body.length;
      final wordText = body.substring(textStart, textEnd);
      final double spanEnd;
      if (cur.group(4) != null && cur.group(5) != null) {
        spanEnd = math.max(
          spanStart,
          _parseMmSsFrac(cur.group(4)!, cur.group(5)!, cur.group(6)) -
              offsetSeconds,
        );
      } else if (i + 1 < matches.length) {
        final nextStart = math.max(
          0.0,
          _parseMmSsFrac(
                matches[i + 1].group(1)!,
                matches[i + 1].group(2)!,
                matches[i + 1].group(3),
              ) -
              offsetSeconds,
        );
        spanEnd = math.max(spanStart, nextStart);
      } else {
        spanEnd = spanStart + 0.5;
      }
      if (wordText.isNotEmpty) {
        spans.add(
          TimedLyricSpan(
            startSeconds: spanStart,
            endSeconds: spanEnd,
            text: wordText,
            isHarmony: isHarmony,
          ),
        );
      }
    }
    return spans;
  }

  /// 解析支持逐字标签与并行和声层 (`bg:` 前缀行) 的增强歌词为 Active Span Set 列表。
  ///
  /// 统一应用 `[offset:]` 全局偏移（正值提前、负值延后），且同一时间桶内多条非 `bg:` 普通文本
  /// 严禁拼接进主唱 `spans`，而是作为独立的 `translation` 归位保存。
  static List<ActiveSpanLyricLine> parseActiveSpanLines(String content) {
    final rawLines = content.split(RegExp(r'\r?\n'));
    var offsetMillis = 0;
    for (final rawLine in rawLines) {
      final offsetMatch = _offsetTagRegex.firstMatch(rawLine.trim());
      if (offsetMatch != null) {
        offsetMillis = int.tryParse(offsetMatch.group(1)!) ?? offsetMillis;
      }
    }
    final offsetSeconds = offsetMillis / 1000.0;

    final grouped =
        <
          double,
          ({
            List<TimedLyricSpan> spans,
            bool hasWordLead,
            String leadPlainText,
            String translation,
          })
        >{};

    for (final rawLine in rawLines) {
      final trimmed = rawLine.trim();
      final match = _linePrefixRegex.firstMatch(trimmed);
      if (match == null) continue;
      final lineStart = math.max(
        0.0,
        _parseMmSsFrac(match.group(1)!, match.group(2)!, match.group(3)) -
            offsetSeconds,
      );
      var body = match.group(4)!.trim();
      if (body.isEmpty || body.startsWith('roma:')) continue;

      final isHarmony = body.startsWith('bg:');
      if (isHarmony) {
        body = body.substring(3).trim();
      }
      final hasWordTags = _wordTagRegex.hasMatch(body);
      final parsedSpans = parseInlineWordSpans(
        body,
        lineStart: lineStart,
        isHarmony: isHarmony,
        offsetSeconds: offsetSeconds,
      );
      final plainText = parsedSpans.map((s) => s.text).join().trim();

      final bucketKey = (lineStart * 20).round() / 20.0;
      final existing = grouped[bucketKey];
      if (existing == null) {
        grouped[bucketKey] = (
          spans: parsedSpans,
          hasWordLead: !isHarmony && hasWordTags,
          leadPlainText: isHarmony ? '' : plainText,
          translation: '',
        );
      } else if (isHarmony) {
        existing.spans.addAll(parsedSpans);
      } else if (existing.leadPlainText.isEmpty) {
        // 原桶仅含先到达的 bg: 和声行，补齐主唱行。
        grouped[bucketKey] = (
          spans: [...parsedSpans, ...existing.spans],
          hasWordLead: hasWordTags,
          leadPlainText: plainText,
          translation: existing.translation,
        );
      } else if (hasWordTags && !existing.hasWordLead) {
        // 新行自带逐字标签而旧行为普通译文行：升级新行作主唱，旧行降为译文。
        final harmonyOnly = existing.spans.where((s) => s.isHarmony).toList();
        grouped[bucketKey] = (
          spans: [...parsedSpans, ...harmonyOnly],
          hasWordLead: true,
          leadPlainText: plainText,
          translation: existing.leadPlainText != plainText
              ? existing.leadPlainText
              : existing.translation,
        );
      } else if (existing.translation.isEmpty &&
          plainText.isNotEmpty &&
          plainText != existing.leadPlainText) {
        grouped[bucketKey] = (
          spans: existing.spans,
          hasWordLead: existing.hasWordLead,
          leadPlainText: existing.leadPlainText,
          translation: plainText,
        );
      }
    }

    final sortedKeys = grouped.keys.toList()..sort();
    final lines = <ActiveSpanLyricLine>[];
    for (var i = 0; i < sortedKeys.length; i++) {
      final start = sortedKeys[i];
      final entry = grouped[start]!;
      var maxEnd = start;
      for (final s in entry.spans) {
        maxEnd = math.max(maxEnd, s.endSeconds);
      }
      if (maxEnd <= start) {
        maxEnd = start + 3.0;
      }
      lines.add(
        ActiveSpanLyricLine(
          startSeconds: start,
          endSeconds: maxEnd,
          spans: List<TimedLyricSpan>.unmodifiable(entry.spans),
          translation: entry.translation,
        ),
      );
    }
    return lines;
  }

  /// 按起始时间戳匹配最接近的增强歌词行（供外部独立解析路径兼容调用，使用二分查找避免线性扫描）。
  static ActiveSpanLyricLine? matchLineForTimestamp(
    List<ActiveSpanLyricLine> lines,
    double startSeconds, {
    double toleranceSeconds = 0.08,
  }) {
    if (lines.isEmpty) return null;
    var low = 0;
    var high = lines.length - 1;
    while (low < high) {
      final mid = (low + high) >> 1;
      if (lines[mid].startSeconds < startSeconds) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    ActiveSpanLyricLine? best;
    var bestDelta = toleranceSeconds;
    for (var idx = math.max(0, low - 1); idx <= math.min(lines.length - 1, low + 1); idx++) {
      final candidate = lines[idx];
      final delta = (candidate.startSeconds - startSeconds).abs();
      if (delta <= bestDelta) {
        bestDelta = delta;
        best = candidate;
      }
    }
    return best;
  }

  static double _parseMmSsFrac(String mm, String ss, String? frac) {
    final mins = int.tryParse(mm) ?? 0;
    final secs = int.tryParse(ss) ?? 0;
    final f = frac ?? '0';
    final fracSec = switch (f.length) {
      1 => (int.tryParse(f) ?? 0) / 10.0,
      2 => (int.tryParse(f) ?? 0) / 100.0,
      _ => (int.tryParse(f.padRight(3, '0').substring(0, 3)) ?? 0) / 1000.0,
    };
    return mins * 60.0 + secs + fracSec;
  }

  static String _formatMmSsMs(double seconds) {
    final totalMs = (seconds < 0 ? 0.0 : seconds * 1000.0).round();
    final ms = totalMs % 1000;
    final totalSec = totalMs ~/ 1000;
    final sec = totalSec % 60;
    final min = totalSec ~/ 60;
    return '${min.toString().padLeft(2, '0')}:'
        '${sec.toString().padLeft(2, '0')}.'
        '${ms.toString().padLeft(3, '0')}';
  }
}
