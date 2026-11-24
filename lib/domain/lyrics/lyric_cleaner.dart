import '../playback/lyric_version_matcher.dart';
import 'ttml_lyric_converter.dart';

/// 单条带时间轴的歌词行（供清洗、对齐、跨源合并与时间轴校验复用）。
class TimedLyricEntry {
  /// 创建时间轴歌词行。
  const TimedLyricEntry({
    required this.timeSeconds,
    required this.text,
    this.rawBody = '',
  });

  /// 起始时间（秒，已应用 `[offset:]` 偏移并钳制非负）。
  final double timeSeconds;

  /// 去除行内逐字标签后的纯展示文本。
  final String text;

  /// 原始行正文（保留 `<mm:ss.xx>` 逐字标签与 `bg:`/`roma:` 前缀，供无损重建）。
  final String rawBody;

  /// 实际用于重建 LRC 的正文文本。
  String get effectiveBody => rawBody.isNotEmpty ? rawBody : text;
}

/// 歌词清洗与质量预检结果。
class CleanedLyricResult {
  /// 创建清洗结果。
  const CleanedLyricResult({
    required this.lines,
    required this.credits,
    required this.isPlaceholder,
    required this.cleanedLrc,
    required this.outOfOrderRatio,
    required this.firstLineSeconds,
    required this.lastLineSeconds,
  });

  /// 去除署名、贡献者、占位与相邻重复后的有效演唱行（不含 `bg:` 与 `roma:` 附属行）。
  final List<TimedLyricEntry> lines;

  /// 提取出的作词、作曲、编曲等制作人员署名信息。
  final List<String> credits;

  /// 是否判定为纯音乐占位、暂无歌词或有效演唱行不足（`<= 2` 行）。
  final bool isPlaceholder;

  /// 清洗后重建的增强 LRC 文本（占位内容返回空串）。
  final String cleanedLrc;

  /// 原始带时间戳行中出现时间倒退的逆序行比例（`0.0 ~ 1.0`）。
  final double outOfOrderRatio;

  /// 有效演唱首行时间（秒），无有效行时为空。
  final double? firstLineSeconds;

  /// 有效演唱末行时间（秒），无有效行时为空。
  final double? lastLineSeconds;
}

/// 歌词文本清洗器：解码常见实体、提取署名行、剥离贡献者与相邻重复行、识别纯音乐占位与异常时间轴。
abstract final class LyricCleaner {
  /// 有效同步歌词最少主唱行数阈值（低于等于 2 行视为占位或残缺歌词）。
  static const int minValidLyricLines = 3;

  static final RegExp _lineSplitRegex = RegExp(r'\r?\n');
  static final RegExp _timeTagRegex = RegExp(
    r'\[(?:(\d{1,2}):)?(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?\]',
  );
  static final RegExp _offsetTagRegex = RegExp(
    r'^\[offset\s*:\s*([+-]?\d+)\s*\]$',
    caseSensitive: false,
  );
  static final RegExp _htmlNumericEntityRegex = RegExp(r'&#(x?[0-9a-fA-F]+);');

  /// 制作人员署名键名（匹配 `键 : 值` / `键：值` 形式，避免误伤包含同类词的正常歌词句）。
  static final RegExp _creditLineRegex = RegExp(
    r'^(?:'
    r'作词|作詞|作曲|编曲|編曲|制作人|製作人|词|詞|曲|填词|填詞|谱曲|譜曲|'
    r'演唱|主唱|歌手|原唱|翻唱|和声|和聲|和音|合音|配唱|伴唱|'
    r'混音|母带|母帶|录音|錄音|录混|音频编辑|人声编辑|弦乐编写|弦樂編寫|'
    r'吉他|贝斯|貝斯|鼓|键盘|鍵盤|钢琴|鋼琴|小提琴|大提琴|管弦乐|弦乐|弦樂|'
    r'监制|監製|统筹|統籌|企划|企劃|出品|发行|發行|唱片公司|版权|版權|OP|SP|'
    r'翻译|翻譯|译词|譯詞|校对|校對|时轴|時軸|时间轴|時間軸|后期|後期|统筹|'
    r'lyrics?\s*by|lyricist|composer|composed\s*by|arranger|arranged\s*by|'
    r'producer|produced\s*by|vocal(?:s)?|singer|mixing|mixed\s*by|'
    r'mastering|mastered\s*by|guitar|bass|drums|piano|strings'
    r')\s*[:：/／]\s*\S+',
    caseSensitive: false,
  );

  /// 平台贡献者、著作权与水军广告垃圾行。
  static final RegExp _contributorLineRegex = RegExp(
    r'(?:'
    r'歌词贡献者|翻譯貢獻者|翻译贡献者|罗马音贡献者|羅馬音貢獻者|歌词编辑|歌词制作|LRC制作|'
    r'腾讯音乐享有本翻译作品的著作权|未经许可[,，]?\s*不得翻唱或使用|'
    r'QQ\s*[:：]\s*\d{5,}|微信\s*[:：]\s*\S+|'
    r'本歌曲来自.*曲库|歌词由.*提供'
    r')',
    caseSensitive: false,
  );

  /// 纯音乐 / 无歌词显式占位文案。
  static final RegExp _placeholderLineRegex = RegExp(
    r'^(?:'
    r'纯音乐[，,\s。!！~～·]*请欣赏.*|'
    r'純音樂[，,\s。!！~～·]*請欣賞.*|'
    r'此歌曲为没有填词的纯音乐.*|'
    r'此歌曲為沒有填詞的純音樂.*|'
    r'没有填词的纯音乐.*|'
    r'暂无歌词.*|暫無歌詞.*|无歌词|無歌詞|'
    r'pure\s*music(?:\s*,?\s*please\s*enjoy)?\.?|'
    r'instrumental(?:\s*(?:ver\.?|version|track))?\.?|'
    r'no\s+lyrics?(?:\s+available)?\.?'
    r')$',
    caseSensitive: false,
  );

  /// 仅由分隔符、空白或无意义符号构成的占位文本（如 QQ 译文里的 `//`）。
  static final RegExp _punctuationOnlyRegex = RegExp(
    r'^[\s/\-_~～·•・.。…,:;!?！？()（）\[\]【】「」『』]+$',
  );

  /// 曲目开头（前 2 秒）常见的 `歌名 - 歌手` 平台自动标题行。
  static final RegExp _leadingTitleArtistRegex = RegExp(r'^.+\s+-\s+.+$');

  /// 解码 QQ 音乐等平台响应中常见的 HTML 字符实体。
  static String decodeHtmlEntities(String raw) {
    if (!raw.contains('&')) return raw;
    var text = raw
        .replaceAll('&apos;', "'")
        .replaceAll('&quot;', '"')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&');
    if (!text.contains('&#')) return text;
    text = text.replaceAllMapped(_htmlNumericEntityRegex, (m) {
      final token = m.group(1) ?? '';
      final code = token.startsWith('x') || token.startsWith('X')
          ? int.tryParse(token.substring(1), radix: 16)
          : int.tryParse(token);
      if (code == null || code <= 0 || code > 0x10FFFF) return m.group(0)!;
      return String.fromCharCode(code);
    });
    return text;
  }

  /// 解析原始 LRC 文本为按出现顺序排列的时间轴条目（正确应用 `[offset:]` 提前偏移）。
  static List<TimedLyricEntry> parseTimedEntries(String rawLrc) {
    final decoded = decodeHtmlEntities(rawLrc);
    var offsetMillis = 0;
    final rawEntries = <TimedLyricEntry>[];

    for (final rawLine in decoded.split(_lineSplitRegex)) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;
      final matches = _timeTagRegex.allMatches(line).toList();
      if (matches.isEmpty) {
        final offsetMatch = _offsetTagRegex.firstMatch(line);
        if (offsetMatch != null) {
          offsetMillis = int.tryParse(offsetMatch.group(1) ?? '') ?? offsetMillis;
        }
        continue;
      }
      final body = line.replaceAll(_timeTagRegex, '').trim();
      if (body.isEmpty) continue;
      final plain = LyricVersionMatcher.stripInlineWordTags(body).trim();
      for (final match in matches) {
        final hours = int.tryParse(match.group(1) ?? '0') ?? 0;
        final mins = int.tryParse(match.group(2) ?? '0') ?? 0;
        final secs = int.tryParse(match.group(3) ?? '0') ?? 0;
        final fracRaw = match.group(4) ?? '0';
        final fracSeconds = switch (fracRaw.length) {
          1 => (int.tryParse(fracRaw) ?? 0) / 10.0,
          2 => (int.tryParse(fracRaw) ?? 0) / 100.0,
          _ =>
            (int.tryParse(fracRaw.padRight(3, '0').substring(0, 3)) ?? 0) /
                1000.0,
        };
        final baseTime = hours * 3600.0 + mins * 60.0 + secs + fracSeconds;
        rawEntries.add(
          TimedLyricEntry(
            timeSeconds: baseTime,
            text: plain,
            rawBody: body,
          ),
        );
      }
    }

    if (offsetMillis == 0) return rawEntries;
    final offsetSec = offsetMillis / 1000.0;
    return [
      for (final e in rawEntries)
        TimedLyricEntry(
          timeSeconds: (e.timeSeconds - offsetSec) < 0
              ? 0.0
              : (e.timeSeconds - offsetSec),
          text: e.text,
          rawBody: LyricVersionMatcher.shiftInlineWordTags(
            e.rawBody,
            offsetSec,
          ),
        ),
    ];
  }

  /// 判断单行文本是否属于制作人员署名行（作词 / 作曲 / 编曲 / 首行 `歌名 - 歌手`）。
  static bool isCreditLine(
    String text, {
    double? timeSeconds,
    bool isLeadingSection = false,
  }) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return false;
    if (_creditLineRegex.hasMatch(trimmed)) return true;
    if (isLeadingSection &&
        timeSeconds != null &&
        timeSeconds <= 2.0 &&
        _leadingTitleArtistRegex.hasMatch(trimmed) &&
        trimmed.length <= 120) {
      return true;
    }
    return false;
  }

  /// 判断单行文本是否属于平台贡献者、版权提示或无意义分隔符。
  static bool isContributorOrNoiseLine(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return true;
    if (_punctuationOnlyRegex.hasMatch(trimmed)) return true;
    return _contributorLineRegex.hasMatch(trimmed);
  }

  /// 判断单行文本是否为纯音乐 / 无歌词占位句。
  static bool isPlaceholderLine(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return false;
    return _placeholderLineRegex.hasMatch(trimmed);
  }

  /// 执行完整清洗：提取署名、移除贡献者/占位/相邻重复行，计算逆序比例与重建干净 LRC。
  static CleanedLyricResult clean(String rawLrc) {
    final rawEntries = parseTimedEntries(rawLrc);
    if (rawEntries.isEmpty) {
      return const CleanedLyricResult(
        lines: [],
        credits: [],
        isPlaceholder: true,
        cleanedLrc: '',
        outOfOrderRatio: 0.0,
        firstLineSeconds: null,
        lastLineSeconds: null,
      );
    }

    // 在排序前统计主轨道逆序比例（忽略紧邻同时间戳的译文 / 和声 / 罗马音行）。
    var transitionCount = 0;
    var outOfOrderCount = 0;
    double? prevMainTime;
    for (final entry in rawEntries) {
      final isAux =
          entry.rawBody.startsWith('bg:') || entry.rawBody.startsWith('roma:');
      if (isAux) continue;
      if (prevMainTime != null) {
        if ((entry.timeSeconds - prevMainTime).abs() > 0.05) {
          transitionCount++;
          if (entry.timeSeconds < prevMainTime - 0.5) {
            outOfOrderCount++;
          }
        }
      }
      prevMainTime = entry.timeSeconds;
    }
    final outOfOrderRatio = transitionCount == 0
        ? 0.0
        : outOfOrderCount / transitionCount;

    final sorted = [...rawEntries]
      ..sort((a, b) => a.timeSeconds.compareTo(b.timeSeconds));

    final credits = <String>[];
    final keptAll = <TimedLyricEntry>[];
    final uniqueMainTimestamps = <double>[];
    var sawExplicitPlaceholder = false;
    var passedLeadSection = false;
    String? prevNormText;
    double? prevKeptTime;
    String? prevPrefix;

    for (final entry in sorted) {
      final rawBody = entry.rawBody;
      final isBg = rawBody.startsWith('bg:');
      final isRoma = rawBody.startsWith('roma:');
      final prefix = isBg ? 'bg:' : (isRoma ? 'roma:' : '');
      final contentText = isBg
          ? entry.text.substring(3).trim()
          : (isRoma ? entry.text.substring(5).trim() : entry.text.trim());

      if (contentText.isEmpty) continue;
      if (isPlaceholderLine(contentText)) {
        sawExplicitPlaceholder = true;
        continue;
      }
      if (isContributorOrNoiseLine(contentText)) continue;
      if (!isBg &&
          !isRoma &&
          isCreditLine(
            contentText,
            timeSeconds: entry.timeSeconds,
            isLeadingSection: !passedLeadSection,
          )) {
        if (!credits.contains(contentText)) {
          credits.add(contentText);
        }
        continue;
      }

      if (!isBg && !isRoma) {
        passedLeadSection = true;
      }

      // 去除相邻时间极近（<= 0.15s）且规范化文本完全一致的重复行。
      final normText = _normalizeDup(contentText);
      if (prevNormText != null &&
          prevKeptTime != null &&
          prevPrefix == prefix &&
          normText == prevNormText &&
          (entry.timeSeconds - prevKeptTime).abs() <= 0.15) {
        continue;
      }
      prevNormText = normText;
      prevKeptTime = entry.timeSeconds;
      prevPrefix = prefix;

      keptAll.add(entry);
      if (!isBg && !isRoma) {
        if (uniqueMainTimestamps.isEmpty ||
            (entry.timeSeconds - uniqueMainTimestamps.last).abs() > 0.05) {
          uniqueMainTimestamps.add(entry.timeSeconds);
        }
      }
    }

    // 统计独立时间槽上的主唱有效行数（同时间戳的原文+译文计为 1 行）。
    final validMainLines = <TimedLyricEntry>[];
    for (final entry in keptAll) {
      if (entry.rawBody.startsWith('bg:') ||
          entry.rawBody.startsWith('roma:')) {
        continue;
      }
      if (validMainLines.isNotEmpty &&
          (entry.timeSeconds - validMainLines.last.timeSeconds).abs() <= 0.05) {
        continue;
      }
      validMainLines.add(entry);
    }

    final isPlaceholder =
        validMainLines.length < minValidLyricLines ||
        (sawExplicitPlaceholder && validMainLines.length <= minValidLyricLines);

    if (isPlaceholder) {
      return CleanedLyricResult(
        lines: const [],
        credits: credits,
        isPlaceholder: true,
        cleanedLrc: '',
        outOfOrderRatio: outOfOrderRatio,
        firstLineSeconds: null,
        lastLineSeconds: null,
      );
    }

    final buf = StringBuffer();
    for (final entry in keptAll) {
      final tag = TtmlLyricConverter.formatLrcTag(entry.timeSeconds);
      buf.writeln('[$tag]${entry.effectiveBody}');
    }

    return CleanedLyricResult(
      lines: validMainLines,
      credits: credits,
      isPlaceholder: false,
      cleanedLrc: buf.toString().trimRight(),
      outOfOrderRatio: outOfOrderRatio,
      firstLineSeconds: validMainLines.first.timeSeconds,
      lastLineSeconds: validMainLines.last.timeSeconds,
    );
  }

  /// 校验纯文本无时间戳歌词是否为纯音乐占位或内容过短。
  static bool isValidPlainLyrics(String plain) {
    final decoded = decodeHtmlEntities(plain);
    var validCount = 0;
    for (final raw in decoded.split(RegExp(r'\r?\n'))) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      if (isPlaceholderLine(line)) return false;
      if (isContributorOrNoiseLine(line)) continue;
      if (isCreditLine(line, isLeadingSection: validCount == 0)) continue;
      validCount++;
    }
    return validCount >= minValidLyricLines;
  }

  static String _normalizeDup(String raw) =>
      raw.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
}
