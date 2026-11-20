import 'dart:math' as math;

/// 动漫音乐曲目版本标签（用于四级歌词检索版本消歧）。
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

/// 歌词网络检索前导决策指令。
enum LyricLookupDirective {
  /// 正常执行多源版本消歧检索。
  proceed,

  /// 识别为伴奏/纯音乐/Off Vocal，直接短路跳过远端歌词抓取。
  shortCircuitInstrumental,

  /// 移动计量网络下访问 AMLL 索引前必须弹窗征求用户确认。
  promptMobileAmllConfirmation,
}

/// 待匹配的歌词候选条目元数据。
class LyricCandidateMeta {
  /// 创建歌词候选条目。
  const LyricCandidateMeta({
    required this.id,
    required this.title,
    this.artist = '',
    this.durationSeconds,
    this.sourcePriority = 0,
  });

  final String id;
  final String title;
  final String artist;
  final double? durationSeconds;

  /// 来源优先级附加分（例如本地同级 > 精确元数据源 > 社区索引）。
  final int sourcePriority;
}

/// 单个时间跨度逐字/和声歌词片段（支持 Active Span Set 主唱与和声并行扫光）。
class TimedLyricSpan {
  /// 创建时间片段。
  const TimedLyricSpan({
    required this.startSeconds,
    required this.endSeconds,
    required this.text,
    this.isHarmony = false,
  });

  final double startSeconds;
  final double endSeconds;
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
  static final RegExp _wordTagRegex = RegExp(
    r'<(\d{1,2}):(\d{2})(?:[.:](\d{1,3}))?>',
  );
  static final RegExp _harmonyLineRegex = RegExp(
    r'^\[\d{1,2}:\d{2}(?:[.:]\d{1,3})?\]\s*bg:',
    multiLine: true,
  );

  /// 判断原始歌词文本是否包含显式逐字时间戳 `<mm:ss.xx>` 或并行和声层 `bg:` 标记。
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

  /// 在发起网络歌词检索前评估前导指令（伴奏短路 + 移动网络下 AMLL 索引弹窗保护）。
  static LyricLookupDirective evaluateLookupDirective({
    required String title,
    String fileName = '',
    bool targetingAmllIndex = false,
    bool isMeteredMobileNetwork = false,
    bool mobileAmllConfirmed = false,
  }) {
    if (isInstrumentalTrack(title: title, fileName: fileName)) {
      return LyricLookupDirective.shortCircuitInstrumental;
    }
    if (targetingAmllIndex &&
        isMeteredMobileNetwork &&
        !mobileAmllConfirmed) {
      return LyricLookupDirective.promptMobileAmllConfirmation;
    }
    return LyricLookupDirective.proceed;
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

  /// 从候选列表中挑选版本与时长综合最优的歌词候选；若全部因版本或时长严重失配则返回 `null`。
  static LyricCandidateMeta? selectBestCandidate({
    required String trackTitle,
    String trackArtist = '',
    double? trackDurationSeconds,
    required List<LyricCandidateMeta> candidates,
  }) {
    if (candidates.isEmpty) return null;
    final queryTags = extractVersionTags(
      title: trackTitle,
      artist: trackArtist,
    );
    final queryCore = _normalizeCoreTitle(trackTitle);

    LyricCandidateMeta? best;
    var bestScore = -100000;

    for (final candidate in candidates) {
      final candTags = extractVersionTags(
        title: candidate.title,
        artist: candidate.artist,
      );
      final candCore = _normalizeCoreTitle(candidate.title);
      var score = candidate.sourcePriority;

      // 1. 核心曲名相似度
      if (candCore == queryCore) {
        score += 120;
      } else if (candCore.contains(queryCore) || queryCore.contains(candCore)) {
        score += 70;
      } else {
        score -= 80;
      }

      // 2. 版本标签消歧（TV Size / Short Ver. / Live / CV / feat.）
      for (final tag in TrackVersionTag.values) {
        final inQuery = queryTags.contains(tag);
        final inCand = candTags.contains(tag);
        if (inQuery && inCand) {
          score += 90;
        } else if (inQuery != inCand) {
          // 明确请求 TV Size / Short Ver. / Live / CV 却匹配到异版本时重罚。
          final isCriticalVersion =
              tag == TrackVersionTag.tvSize ||
              tag == TrackVersionTag.shortVer ||
              tag == TrackVersionTag.live ||
              tag == TrackVersionTag.characterVoice;
          score -= isCriticalVersion ? 110 : 40;
        }
      }

      // 3. 精确时长容差校验（防 TV Size 90s 错配 Full 240s）
      if (trackDurationSeconds != null &&
          trackDurationSeconds > 0 &&
          candidate.durationSeconds != null &&
          candidate.durationSeconds! > 0) {
        final diff = (trackDurationSeconds - candidate.durationSeconds!).abs();
        if (diff <= 2.5) {
          score += 100;
        } else if (diff <= 6.0) {
          score += 50;
        } else if (diff > 25.0) {
          // 时长差距超过 25 秒直接淘汰（如 1:30 TV Size 与 4:00 Full Ver.）。
          continue;
        } else {
          score -= (diff * 4).round();
        }
      }

      if (score > bestScore) {
        bestScore = score;
        best = candidate;
      }
    }

    return bestScore >= 20 ? best : null;
  }

  /// 解析支持逐字 `<mm:ss.xx>` 与并行和声层 (`bg:` 前缀行) 的增强歌词为 Active Span Set 列表。
  ///
  /// 同一时间桶内若出现多条非 `bg:` 普通文本（例如双语 LRC 的原文与中文译文），
  /// 严禁拼接进主唱 `spans`，而是作为独立的 `translation` 归位保存。
  static List<ActiveSpanLyricLine> parseActiveSpanLines(String content) {
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
    final linePrefixRegex = RegExp(
      r'^\[(\d{1,2}):(\d{2})(?:[.:](\d{1,3}))?\](.*)$',
    );

    for (final rawLine in content.split(RegExp(r'\r?\n'))) {
      final trimmed = rawLine.trim();
      final match = linePrefixRegex.firstMatch(trimmed);
      if (match == null) continue;
      final lineStart = _parseMmSsFrac(
        match.group(1)!,
        match.group(2)!,
        match.group(3),
      );
      var body = match.group(4)!.trim();
      if (body.isEmpty) continue;

      final isHarmony = body.startsWith('bg:');
      if (isHarmony) {
        body = body.substring(3).trim();
      }
      final hasWordTags = _wordTagRegex.hasMatch(body);
      final parsedSpans = _parseWordSpans(
        body,
        lineStart: lineStart,
        isHarmony: isHarmony,
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
      var maxEnd = start + 3.0;
      for (final s in entry.spans) {
        maxEnd = math.max(maxEnd, s.endSeconds);
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

  /// 按起始时间戳匹配最接近的增强歌词行（用于将普通 LRC 行对齐至 Active Span Set 逐字和声数据）。
  static ActiveSpanLyricLine? matchLineForTimestamp(
    List<ActiveSpanLyricLine> lines,
    double startSeconds, {
    double toleranceSeconds = 0.08,
  }) {
    if (lines.isEmpty) return null;
    ActiveSpanLyricLine? best;
    var bestDelta = toleranceSeconds;
    for (final candidate in lines) {
      final delta = (candidate.startSeconds - startSeconds).abs();
      if (delta <= bestDelta) {
        bestDelta = delta;
        best = candidate;
      }
    }
    return best;
  }

  static List<TimedLyricSpan> _parseWordSpans(
    String body, {
    required double lineStart,
    required bool isHarmony,
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
    for (var i = 0; i < matches.length; i++) {
      final cur = matches[i];
      final spanStart = _parseMmSsFrac(
        cur.group(1)!,
        cur.group(2)!,
        cur.group(3),
      );
      final textStart = cur.end;
      final textEnd = i + 1 < matches.length ? matches[i + 1].start : body.length;
      final wordText = body.substring(textStart, textEnd);
      final spanEnd = i + 1 < matches.length
          ? _parseMmSsFrac(
              matches[i + 1].group(1)!,
              matches[i + 1].group(2)!,
              matches[i + 1].group(3),
            )
          : spanStart + 0.5;
      if (wordText.isNotEmpty) {
        spans.add(
          TimedLyricSpan(
            startSeconds: spanStart,
            endSeconds: math.max(spanStart, spanEnd),
            text: wordText,
            isHarmony: isHarmony,
          ),
        );
      }
    }
    return spans;
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

  static String _normalizeCoreTitle(String raw) {
    return raw
        .toLowerCase()
        .replaceAll(_tvSizeRegex, ' ')
        .replaceAll(_shortVerRegex, ' ')
        .replaceAll(_fullVerRegex, ' ')
        .replaceAll(_liveRegex, ' ')
        .replaceAll(_acousticRegex, ' ')
        .replaceAll(_remixRegex, ' ')
        .replaceAll(RegExp(r'[\(\)\[\]（）【】\-_]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }
}
