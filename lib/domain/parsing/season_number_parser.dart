/// 标题拆解后的纯净剧名与季号结果。
class ParsedSeasonTitle {
  /// 构造季号拆解结果。
  const ParsedSeasonTitle({required this.title, this.seasonNumber});

  /// 剥离尾部季号标记后的主标题。
  final String title;

  /// 提取到的季号（未命中则为 null）。
  final int? seasonNumber;
}

/// 季号解析与多季目录折叠识别工具。
class SeasonNumberParser {
  const SeasonNumberParser._();

  static final RegExp _standaloneSeasonDir = RegExp(
    r'^(?:season|s|series)[\s._-]*0*(\d{1,2})(?:\b|$)|^0*(\d{1,2})(?:st|nd|rd|th)\s+season$|^第\s*([0-9一二三四五六七八九十百零〇]+)\s*[季期部]$',
    caseSensitive: false,
  );

  static final RegExp _embeddedSeasonDir = RegExp(
    r'(?:^|[\s._\-\[\(])(?:season[\s._-]*0*(\d{1,2})|s0*(\d{1,2})|0*(\d{1,2})(?:st|nd|rd|th)[\s._-]+season|第\s*([0-9一二三四五六七八九十百零〇]+)\s*[季期部])(?=$|[\s._\-\]\)])',
    caseSensitive: false,
  );

  static final RegExp _trailingExplicitSeason = RegExp(
    r'^(.*?)(?:[\s._-]+(?:season[\s._-]*0*(\d{1,2})|s0*(\d{1,2})|0*(\d{1,2})(?:st|nd|rd|th)[\s._-]+season)|[\s._-]*第\s*([0-9一二三四五六七八九十百零〇]+)\s*[季期部])\s*$',
    caseSensitive: false,
  );

  static final RegExp _trailingRomanSeason = RegExp(
    r'^(.*?)(?:[\s._-]+(VI|IV|III|II|V)|[\s._-]*(Ⅳ|Ⅲ|Ⅱ))\s*$',
  );

  /// 罗马数字前缀黑名单：防止把机体编号或章节标识误判为续作季号。
  static final RegExp _romanBlacklistTail = RegExp(
    r'(?:mk|mark|type|part|pt|vol|volume|act|ver|version|phase|stage|chapter|ch|ep|episode|unit|model|gen|grade|class|tier|no)[\s._-]*$',
    caseSensitive: false,
  );

  static const Map<String, int> _romanMap = <String, int>{
    'I': 1,
    'II': 2,
    'III': 3,
    'IV': 4,
    'V': 5,
    'VI': 6,
    'Ⅱ': 2,
    'Ⅲ': 3,
    'Ⅳ': 4,
  };

  /// 从相对路径的多级目录分段中提取季号。
  ///
  /// 优先检查靠近文件所在子目录（如 `Season 2/`、`S02/`、`第二季/`、`2nd Season/`），
  /// 若标准季目录未命中，再识别折叠到父目录名中的尾部罗马数字或季号后缀（如 `Overlord II/`）。
  static int? extractSeasonFromPath(String relativePath) {
    final normalized = relativePath.replaceAll('\\', '/').trim();
    if (normalized.isEmpty) return null;
    final segments = normalized
        .split('/')
        .where((s) => s.trim().isNotEmpty)
        .toList(growable: false);
    if (segments.length <= 1) return null;

    // 仅遍历目录部分（跳过末尾文件名），从最内层向外层匹配。
    final dirSegments = segments.sublist(0, segments.length - 1);
    for (var i = dirSegments.length - 1; i >= 0; i--) {
      final seg = dirSegments[i].trim();
      final standalone = _standaloneSeasonDir.firstMatch(seg);
      if (standalone != null) {
        final raw = standalone.group(1) ?? standalone.group(2) ?? standalone.group(3);
        final parsed = parseSeasonToken(raw);
        if (parsed != null && parsed >= 0 && parsed <= 50) return parsed;
      }

      final embedded = _embeddedSeasonDir.firstMatch(seg);
      if (embedded != null) {
        final raw =
            embedded.group(1) ??
            embedded.group(2) ??
            embedded.group(3) ??
            embedded.group(4);
        final parsed = parseSeasonToken(raw);
        if (parsed != null && parsed >= 0 && parsed <= 50) return parsed;
      }

      final split = splitSeasonSuffix(seg);
      if (split.seasonNumber != null) {
        return split.seasonNumber;
      }
    }
    return null;
  }

  /// 拆解标题尾部的季号后缀与罗马数字（如 `II`、`III`、`IV`、`第二季`、`2nd Season`、`S02`）。
  static ParsedSeasonTitle splitSeasonSuffix(String rawTitle) {
    final trimmed = rawTitle.trim();
    if (trimmed.isEmpty) {
      return const ParsedSeasonTitle(title: '');
    }

    final explicit = _trailingExplicitSeason.firstMatch(trimmed);
    if (explicit != null) {
      final base = (explicit.group(1) ?? '').trim();
      final token =
          explicit.group(2) ??
          explicit.group(3) ??
          explicit.group(4) ??
          explicit.group(5);
      final season = parseSeasonToken(token);
      if (base.isNotEmpty && season != null && season >= 1 && season <= 50) {
        return ParsedSeasonTitle(title: base, seasonNumber: season);
      }
    }

    final roman = _trailingRomanSeason.firstMatch(trimmed);
    if (roman != null) {
      final base = (roman.group(1) ?? '').trim();
      final symbol = (roman.group(2) ?? roman.group(3) ?? '').trim();
      final season = _romanMap[symbol];
      if (base.isNotEmpty &&
          season != null &&
          season >= 2 &&
          !_romanBlacklistTail.hasMatch(base)) {
        return ParsedSeasonTitle(title: base, seasonNumber: season);
      }
    }

    return ParsedSeasonTitle(title: trimmed);
  }

  /// 解析阿拉伯数字或中文数字为季号（`0`~`50`）。
  static int? parseSeasonToken(String? raw) {
    if (raw == null) return null;
    final cleaned = raw.trim();
    if (cleaned.isEmpty) return null;
    final ascii = int.tryParse(cleaned);
    if (ascii != null) return ascii;
    return parseChineseNumber(cleaned);
  }

  /// 将常见中文数字（如 `一`、`二`、`十`、`十二`、`二十`）转换为整数。
  static int? parseChineseNumber(String raw) {
    const digits = <String, int>{
      '零': 0,
      '〇': 0,
      '一': 1,
      '二': 2,
      '两': 2,
      '三': 3,
      '四': 4,
      '五': 5,
      '六': 6,
      '七': 7,
      '八': 8,
      '九': 9,
    };
    final text = raw.trim();
    if (text.isEmpty) return null;
    if (text == '十') return 10;
    if (digits.containsKey(text)) return digits[text];
    if (text.contains('十')) {
      final parts = text.split('十');
      if (parts.length == 2) {
        final tens = parts[0].isEmpty ? 1 : (digits[parts[0]] ?? -1);
        final ones = parts[1].isEmpty ? 0 : (digits[parts[1]] ?? -1);
        if (tens >= 1 && ones >= 0) return tens * 10 + ones;
      }
    }
    if (text.contains('百')) {
      final parts = text.split('百');
      if (parts.length == 2) {
        final hundreds = digits[parts[0]] ?? -1;
        if (hundreds >= 1) {
          if (parts[1].isEmpty) return hundreds * 100;
          final rem = parts[1].startsWith('零')
              ? parseChineseNumber(parts[1].substring(1))
              : parseChineseNumber(parts[1]);
          if (rem != null && rem >= 0) return hundreds * 100 + rem;
        }
      }
    }
    return null;
  }
}
