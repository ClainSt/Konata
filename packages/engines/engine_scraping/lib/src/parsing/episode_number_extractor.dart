import 'season_number_parser.dart';

/// 集号正则提取结果。
class ExtractedEpisodeMatch {
  /// 构造集号提取结果。
  const ExtractedEpisodeMatch({
    this.seasonNumber,
    this.episodeNumber,
    this.episodeEnd,
    this.fractionalEpisode,
    this.isExplicitSeasonEpisode = false,
    required this.remainingText,
  });

  /// 从集号片段中显式提取到的季号（如 `S02E03` 中的 `2`）。
  final int? seasonNumber;

  /// 提取到的起始/主集号。
  final int? episodeNumber;

  /// 若为区间集（如 `01-04` 或 `003&004`），记录结束集号。
  final int? episodeEnd;

  /// 小数半集原始文本（如 `11.5` 或 `04.5`）。
  final String? fractionalEpisode;

  /// 是否来自 `SxxEyy` 显式季集表达式。
  final bool isExplicitSeasonEpisode;

  /// 移除命中的集号片段后剩余的标题/上下文文本。
  final String remainingText;
}

/// 15 级优先链集号提取器（严格参照 BDRip / Scene / 字幕组常见命名规范）。
class EpisodeNumberExtractor {
  const EpisodeNumberExtractor._();

  static final RegExp _noiseShield = RegExp(
    r'(?:1920x1080|1280x720|3840x2160|2160p|1440p|1080p|720p|576p|540p|480p|360p|240p|x264|x265|h264|h265|av1|10bit|8bit|12bit|\[[0-9A-Fa-f]{8}\]|\b(?:19\d\d|20[0-3]\d)[.\-](?:0[1-9]|1[0-2])[.\-](?:0[1-9]|[12]\d|3[01])\b)',
    caseSensitive: false,
  );

  // 1. S01E11.5 / S01E01-E02 / S02E05
  static final RegExp _l1SeasonEpisodeFractional = RegExp(
    r'(?:^|[\s._\-\[\(【！!？?])S(\d{1,2})[\s._-]*E(\d{1,3})\.(5)(?:v\d+)?(?=$|[\s._\-\]\)】「『（《！!？?])',
    caseSensitive: false,
  );
  static final RegExp _l2SeasonEpisodeRange = RegExp(
    r'(?:^|[\s._\-\[\(【！!？?])S(\d{1,2})[\s._-]*E(\d{1,4})[\s._-]*[-~&][\s._-]*E?(\d{1,4})(?:v\d+)?(?=$|[\s._\-\]\)】「『（《！!？?])',
    caseSensitive: false,
  );
  static final RegExp _l3SeasonEpisode = RegExp(
    r'(?:^|[\s._\-\[\(【！!？?])S(\d{1,2})[\s._-]*E(\d{1,4})(?:v\d+)?(?=$|[\s._\-\]\)】「『（《！!？?])',
    caseSensitive: false,
  );

  // 4. EP05 / Ep.05 / Episode 05 / E11.5（支持日文汉字/假名紧接 EP，如 アラモードEP37）
  static final RegExp _l4ExplicitEpFractional = RegExp(
    r'(?<=^|[\s._\-\[\(【！!？?\u4e00-\u9fa5\u3040-\u30ff])(?:Episode|EP|E)[.\s_-]*0*(\d{1,3})\.(5)(?:v\d+)?(?=$|[\s._\-\]\)】「『（《！!？?])',
    caseSensitive: false,
  );
  static final RegExp _l5ExplicitEp = RegExp(
    r'(?<=^|[\s._\-\[\(【！!？?\u4e00-\u9fa5\u3040-\u30ff])(?:Episode|EP|E)[.\s_-]*(\d{1,4})(?:[\s._-]*[-~&][\s._-]*E?(\d{1,4}))?(?:v\d+)?(?=$|[\s._\-\]\)】「『（《！!？?])',
    caseSensitive: false,
  );

  // 6. 第05話 / 第十二集 / 第11.5话 / 巻ノ一
  static final RegExp _l6CjkFractional = RegExp(
    r'第\s*(\d{1,3})\.(5)\s*[話话集回]',
    caseSensitive: false,
  );
  static final RegExp _l7CjkEpisode = RegExp(
    r'第\s*([0-9一二三四五六七八九十百零〇]{1,5})\s*[話话集回](?:\s*[-~&]\s*([0-9一二三四五六七八九十百零〇]{1,5})\s*[話话集回]?)?|巻\s*[ノの之]\s*([0-9一二三四五六七八九十百零〇]{1,3})(?=\s|[「『]|$)',
  );

  // 8. 括号内完结/版本/分段标识，如 [12 END] / [48_END] / [05v2] / [14(Final Act 01)] / [13 Part1]
  static final RegExp _l8BracketEndOrVer = RegExp(
    r'[\[\(【]\s*(\d{1,4})(?:(?:v\d+)|(?:[\s_]*[\(\[]?(?:END|FIN|FINAL|完|终)[\)\]]?)|(?:[\s_]+(?:Part\s*[A-Z0-9]+|前編|後編|前篇|后篇))|(?:\s*\([^)]+\)))\s*[\]\)】]',
    caseSensitive: false,
  );

  // 9a. 括号内区间集 [01-04] / (003&004) / [01+02]
  static final RegExp _l9BracketRange = RegExp(
    r'[\[\(【]\s*(\d{2,4})\s*[-~&+]\s*(\d{2,4})(?:v\d+)?\s*[\]\)】]',
  );

  // 9b. 裸区间集 01-04 / 01+02（排在独立 [01] / " - 01" 之后）
  static final RegExp _l9BareRange = RegExp(
    r'(?:^|[\s._\-！!])(\d{2,4})\s*[-~&+]\s*(\d{2,4})(?:v\d+)?(?=$|[\s._\-\]\)】「『（《！!])',
  );

  // 10. [11.5] / - 11.5 小数半集（避免命中 "2.5-jigen" 等标题固有小数）
  static final RegExp _l10Fractional = RegExp(
    r'(?:^|[\s._\-\[\(【])(\d{1,3})\.(5)(?:v\d+)?(?=$|[\s_\]\)】「]|\.(?!\d)|-(?![a-zA-Z]))',
  );

  // 11. #01 / #12（支持 CJK 紧接 #，不吞掉前缀汉字）
  static final RegExp _l11Hash = RegExp(
    r'(?<=^|[\s._\-\[\(【\u4e00-\u9fa5\u3040-\u30ff])#(\d{1,4})(?:v\d+)?(?=$|[\s._\-\]\)】「『（《！!？?～~・])',
  );

  // 12. 独立括号集号 [01] / (05) / 【05】 与 [01 Subtitle]
  static final RegExp _l12BracketIsolated = RegExp(
    r'[\[\(【]\s*(\d{1,4})\s*[\]\)】]',
  );
  static final RegExp _l12bBracketLeadingEp = RegExp(
    r'[\[\(【]\s*(0\d|[1-9]\d?)[_\s]+[^\d\]\)】][^\]\)】]{1,40}[\]\)】]',
  );

  // 13. 横杠/下划线分隔集号: " - 01" / "_01_" / " - 1 - Subtitle"
  static final RegExp _l13DashSeparator = RegExp(
    r'(?:(?:[\s._]+-[\s._]*|_)(\d{2,4})(?:v\d+)?(?![-~&+]\d)(?!\.5)(?=$|[\s._\-\[\(【「『（《！!？?])|(?:[\s._]+-[\s._]*)([1-9])(?:v\d+)?(?=[\s._]+-[\s._]*\S))',
  );

  // 14. 点号分隔 ".01." 或 行首 "01 - " / 中段补零集号 " 01 - Subtitle" / " 01 「..." / " 01."
  static final RegExp _l14DotOrLeading = RegExp(
    r'(?:\.(\d{2,3})(?:v\d+)?\.)|(?:^\s*(0\d|[1-3]\d)(?:v\d+)?[\s._-]+(?=\S))',
  );
  static final RegExp _l14bMidSubtitleOrParen = RegExp(
    r'(?:^|[\s！!？?\)）])(0\d|[1-9]\d{1,2})(?:v\d+)?(?=\.?(?:\s*(?:[「『【\(（～~]|-\s+\S))|\.\s+[\u4e00-\u9fa5\u3040-\u30ffA-Za-z]|\s{2,}[\u4e00-\u9fa5\u3040-\u30ff])|(?<=[\u4e00-\u9fa5\u3040-\u30ff0-9] )(0\d|[1-4]\d)(?=\s+[A-Z][a-z])',
  );

  // 15. 裸尾随集号（如 "Show Name 01" / "Kyoukai no Rinne 53" / "「... 01」"）
  static final RegExp _l15TrailingBare = RegExp(
    r'(?:^|[\s！!？?])(0\d|[1-9]\d{1,2})(?:v\d+)?(?:\s+(?:END|FIN|FINAL|完|终))?(?=\s*」?\s*$)',
    caseSensitive: false,
  );

  // 16. CJK 无空格尾随集号（如 "大人的防具店1"、"某番12"）
  static final RegExp _l16CjkTrailing = RegExp(
    r'[\u4e00-\u9fa5\u3040-\u30ff](\d{1,2})(?:v\d+)?\s*$',
  );

  /// 在剥离技术噪音后的清洗文件名中按 15 级优先链提取集号。
  static ExtractedEpisodeMatch extract(String rawStem) {
    final cleanedForScan = _shieldNoiseTokens(rawStem);

    // L1: S01E11.5
    final m1 = _l1SeasonEpisodeFractional.firstMatch(cleanedForScan);
    if (m1 != null) {
      final s = int.tryParse(m1.group(1) ?? '');
      final e = int.tryParse(m1.group(2) ?? '');
      final frac = '${e ?? 0}.${m1.group(3)}';
      if (e != null) {
        return ExtractedEpisodeMatch(
          seasonNumber: s,
          episodeNumber: e,
          fractionalEpisode: frac,
          isExplicitSeasonEpisode: true,
          remainingText: _cutMatch(rawStem, m1.start, m1.end),
        );
      }
    }

    // L2: S01E01-E02
    final m2 = _l2SeasonEpisodeRange.firstMatch(cleanedForScan);
    if (m2 != null) {
      final s = int.tryParse(m2.group(1) ?? '');
      final eStart = int.tryParse(m2.group(2) ?? '');
      final eEnd = int.tryParse(m2.group(3) ?? '');
      if (eStart != null && eEnd != null && eEnd >= eStart && eEnd - eStart <= 24) {
        return ExtractedEpisodeMatch(
          seasonNumber: s,
          episodeNumber: eStart,
          episodeEnd: eEnd,
          isExplicitSeasonEpisode: true,
          remainingText: _cutMatch(rawStem, m2.start, m2.end),
        );
      }
    }

    // L3: S01E05
    final m3 = _l3SeasonEpisode.firstMatch(cleanedForScan);
    if (m3 != null) {
      final s = int.tryParse(m3.group(1) ?? '');
      final e = int.tryParse(m3.group(2) ?? '');
      if (e != null && _isPlausibleEpisode(e)) {
        return ExtractedEpisodeMatch(
          seasonNumber: s,
          episodeNumber: e,
          isExplicitSeasonEpisode: true,
          remainingText: _cutMatch(rawStem, m3.start, m3.end),
        );
      }
    }

    // L4: EP11.5
    final m4 = _l4ExplicitEpFractional.firstMatch(cleanedForScan);
    if (m4 != null) {
      final e = int.tryParse(m4.group(1) ?? '');
      if (e != null && _isPlausibleEpisode(e)) {
        return ExtractedEpisodeMatch(
          episodeNumber: e,
          fractionalEpisode: '$e.${m4.group(2)}',
          remainingText: _cutMatch(rawStem, m4.start, m4.end),
        );
      }
    }

    // L5：显式集数前缀匹配（如 EP05 / Episode 05 / E01-02）
    final m5 = _l5ExplicitEp.firstMatch(cleanedForScan);
    if (m5 != null) {
      final eStart = int.tryParse(m5.group(1) ?? '');
      final eEnd = int.tryParse(m5.group(2) ?? '');
      if (eStart != null && _isPlausibleEpisode(eStart)) {
        return ExtractedEpisodeMatch(
          episodeNumber: eStart,
          episodeEnd: (eEnd != null && eEnd > eStart && eEnd - eStart <= 24)
              ? eEnd
              : null,
          remainingText: _cutMatch(rawStem, m5.start, m5.end),
        );
      }
    }

    // L6: 第11.5话
    final m6 = _l6CjkFractional.firstMatch(cleanedForScan);
    if (m6 != null) {
      final e = int.tryParse(m6.group(1) ?? '');
      if (e != null && _isPlausibleEpisode(e)) {
        return ExtractedEpisodeMatch(
          episodeNumber: e,
          fractionalEpisode: '$e.${m6.group(2)}',
          remainingText: _cutMatch(rawStem, m6.start, m6.end),
        );
      }
    }

    // L7: 第05話 / 第十二集 / 巻ノ一
    final m7 = _l7CjkEpisode.firstMatch(cleanedForScan);
    if (m7 != null) {
      final eStart = SeasonNumberParser.parseSeasonToken(m7.group(1) ?? m7.group(3));
      final eEnd = SeasonNumberParser.parseSeasonToken(m7.group(2));
      if (eStart != null && _isPlausibleEpisode(eStart)) {
        return ExtractedEpisodeMatch(
          episodeNumber: eStart,
          episodeEnd: (eEnd != null && eEnd > eStart && eEnd - eStart <= 24)
              ? eEnd
              : null,
          remainingText: _cutMatch(rawStem, m7.start, m7.end),
        );
      }
    }

    // L8：括号内完结与修订版本号集数匹配（如 [12 END] / [05v2]）
    for (final m8 in _l8BracketEndOrVer.allMatches(cleanedForScan)) {
      final e = int.tryParse(m8.group(1) ?? '');
      if (e != null && _isSafeStandaloneEpisode(e)) {
        return ExtractedEpisodeMatch(
          episodeNumber: e,
          remainingText: _cutMatch(rawStem, m8.start, m8.end),
        );
      }
    }

    // L9a: 括号内区间集 [01-04] / (003&004) / [01+02]
    for (final m9 in _l9BracketRange.allMatches(cleanedForScan)) {
      final eStart = int.tryParse(m9.group(1) ?? '');
      final eEnd = int.tryParse(m9.group(2) ?? '');
      if (eStart != null &&
          eEnd != null &&
          eEnd > eStart &&
          eEnd - eStart <= 24 &&
          _isSafeStandaloneEpisode(eStart) &&
          _isSafeStandaloneEpisode(eEnd)) {
        return ExtractedEpisodeMatch(
          episodeNumber: eStart,
          episodeEnd: eEnd,
          remainingText: _cutMatch(rawStem, m9.start, m9.end),
        );
      }
    }

    // L11: #01
    for (final m11 in _l11Hash.allMatches(cleanedForScan)) {
      final e = int.tryParse(m11.group(1) ?? '');
      if (e != null && _isSafeStandaloneEpisode(e)) {
        return ExtractedEpisodeMatch(
          episodeNumber: e,
          remainingText: _cutMatch(rawStem, m11.start, m11.end),
        );
      }
    }

    // L12: 括号孤立集数 [01] / (05) / 【05】
    for (final m12 in _l12BracketIsolated.allMatches(cleanedForScan)) {
      final e = int.tryParse(m12.group(1) ?? '');
      if (e != null && _isSafeExplicitEpisode(e)) {
        return ExtractedEpisodeMatch(
          episodeNumber: e,
          remainingText: _cutMatch(rawStem, m12.start, m12.end),
        );
      }
    }

    // L12b: 括号前置集号 [01 Music in the world] / [07_OzoraNaom.ver]
    for (final m12b in _l12bBracketLeadingEp.allMatches(cleanedForScan)) {
      final token = m12b.group(1) ?? '';
      final e = int.tryParse(token);
      if (e != null && (token.startsWith('0') || e <= 52) && _isSafeStandaloneEpisode(e)) {
        return ExtractedEpisodeMatch(
          episodeNumber: e,
          remainingText: _cutMatch(rawStem, m12b.start, m12b.end),
        );
      }
    }

    // L13：横杠或下划线分隔集号匹配（如 " - 01" / "_01_" / " - 1 - 标题"）
    for (final m13 in _l13DashSeparator.allMatches(cleanedForScan)) {
      final e = int.tryParse(m13.group(1) ?? m13.group(2) ?? '');
      if (e != null && _isSafeExplicitEpisode(e)) {
        return ExtractedEpisodeMatch(
          episodeNumber: e,
          remainingText: _cutMatch(rawStem, m13.start, m13.end),
        );
      }
    }

    // L9b(降级至独立 [01] / " - 01" 之后): 裸区间集 01-04 / 01+02
    for (final m9b in _l9BareRange.allMatches(cleanedForScan)) {
      final eStart = int.tryParse(m9b.group(1) ?? '');
      final eEnd = int.tryParse(m9b.group(2) ?? '');
      if (eStart != null &&
          eEnd != null &&
          eEnd > eStart &&
          eEnd - eStart <= 24 &&
          _isSafeStandaloneEpisode(eStart) &&
          _isSafeStandaloneEpisode(eEnd)) {
        return ExtractedEpisodeMatch(
          episodeNumber: eStart,
          episodeEnd: eEnd,
          remainingText: _cutMatch(rawStem, m9b.start, m9b.end),
        );
      }
    }

    // L10(降级至独立集号之后): 小数半集 11.5 / 04.5（避免误伤 "2.5-jigen" 等标题前缀）
    for (final m10 in _l10Fractional.allMatches(cleanedForScan)) {
      final e = int.tryParse(m10.group(1) ?? '');
      if (e != null && e >= 0 && e <= 999) {
        return ExtractedEpisodeMatch(
          episodeNumber: e,
          fractionalEpisode: '$e.${m10.group(2)}',
          remainingText: _cutMatch(rawStem, m10.start, m10.end),
        );
      }
    }

    // L14: ".01." 或 行首 "01 "
    for (final m14 in _l14DotOrLeading.allMatches(cleanedForScan)) {
      final rawNum = m14.group(1) ?? m14.group(2);
      final e = int.tryParse(rawNum ?? '');
      if (e != null && _isSafeStandaloneEpisode(e)) {
        return ExtractedEpisodeMatch(
          episodeNumber: e,
          remainingText: _cutMatch(rawStem, m14.start, m14.end),
        );
      }
    }

    // L14b: 中段空格/感叹号后接副标题或括号前的补零/常规集号（如 "01 「..." / "01 - Title" / "！01"）
    for (final m14b in _l14bMidSubtitleOrParen.allMatches(cleanedForScan)) {
      final token = m14b.group(1) ?? m14b.group(2) ?? '';
      final e = int.tryParse(token);
      if (e != null && e >= 1 && e <= 399 && e != 100 && _isSafeStandaloneEpisode(e) && (token.startsWith('0') || e <= 52)) {
        final skipFirst = m14b.start < rawStem.length && '！!？?)）'.contains(rawStem[m14b.start]);
        return ExtractedEpisodeMatch(episodeNumber: e, remainingText: _cutMatch(rawStem, skipFirst ? m14b.start + 1 : m14b.start, m14b.end));
      }
    }

    // L15: 裸尾随补零/三位及合理长篇集数（放宽非补零上限至 99 以支持 3 季连播）
    final m15 = _l15TrailingBare.firstMatch(cleanedForScan);
    if (m15 != null) {
      final token = m15.group(1) ?? '';
      final e = int.tryParse(token);
      if (e != null && e >= 1 && e <= 399 && e != 100 && _isSafeStandaloneEpisode(e) && (token.startsWith('0') || e <= 99)) {
        final skipFirst = m15.start < rawStem.length && '！!？?'.contains(rawStem[m15.start]);
        return ExtractedEpisodeMatch(episodeNumber: e, remainingText: _cutMatch(rawStem, skipFirst ? m15.start + 1 : m15.start, m15.end));
      }
    }

    // L16: CJK 无空格尾随集号（如 "大人的防具店1"）
    final m16 = _l16CjkTrailing.firstMatch(cleanedForScan);
    if (m16 != null) {
      final e = int.tryParse(m16.group(1) ?? '');
      if (e != null && e >= 1 && e <= 26) {
        return ExtractedEpisodeMatch(
          episodeNumber: e,
          remainingText: _cutMatch(rawStem, m16.start + 1, m16.end),
        );
      }
    }

    return ExtractedEpisodeMatch(remainingText: rawStem);
  }

  /// 用等长空格替换分辨率、年份日期、编码与 CRC32，保持字符串索引对齐不失真。
  static String _shieldNoiseTokens(String input) {
    return input.replaceAllMapped(_noiseShield, (m) => ' ' * m.group(0)!.length);
  }

  static String _cutMatch(String source, int start, int end) {
    if (start < 0 || end > source.length || start >= end) return source;
    final cutStart = start;
    var cutEnd = end;
    final first = source[cutStart];
    if (cutEnd < source.length) {
      final next = source[cutEnd];
      if ((first == '[' && next == ']') ||
          (first == '(' && next == ')') ||
          (first == '【' && next == '】')) {
        cutEnd++;
      }
    }
    return '${source.substring(0, cutStart)} ${source.substring(cutEnd)}';
  }

  static bool _isPlausibleEpisode(int value) => value >= 0 && value <= 1999;

  static bool _isSafeExplicitEpisode(int value) =>
      value >= 0 && value <= 1999 &&
      value != 1080 && value != 1440 && value != 2160 &&
      (value < 1980 || value > 2039);

  static bool _isSafeStandaloneEpisode(int value) =>
      _isSafeExplicitEpisode(value) &&
      value != 240 && value != 360 && value != 480 &&
      value != 540 && value != 576 && value != 720;
}
