import 'title_normalizer_tables.dart';

/// 轻量级、零外部依赖的动画/影视标题归一化工具。
///
/// 统一处理繁简汉字折叠、全角 ASCII 转半角、日文假名、Unicode 罗马数字、
/// 乘号分隔符（`×`/`✕`）以及罗马音与假名之间的音近相似度计算。
class TitleNormalizer {
  const TitleNormalizer._();

  static final Map<int, int> _tradToSimp = Map<int, int>.unmodifiable(
    _buildTradToSimpMap(),
  );
  static final RegExp _kanaPattern = RegExp(r'[\u3040-\u30ff\uff65-\uff9f]');

  static Map<int, int> _buildTradToSimpMap() {
    final tradRunes = TitleNormalizerTables.traditionalChars.runes.toList(
      growable: false,
    );
    final simpRunes = TitleNormalizerTables.simplifiedChars.runes.toList(
      growable: false,
    );
    assert(tradRunes.length == simpRunes.length);
    return <int, int>{
      for (var i = 0; i < tradRunes.length; i++) tradRunes[i]: simpRunes[i],
    };
  }

  /// 将输入文本中的高频繁体汉字转换为简体汉字，保留大小写、假名与标点。
  static String toSimplified(String input) {
    if (input.isEmpty) return input;
    var changed = false;
    final buffer = StringBuffer();
    for (final rune in input.runes) {
      final mapped = _tradToSimp[rune];
      if (mapped != null) {
        changed = true;
        buffer.writeCharCode(mapped);
      } else {
        buffer.writeCharCode(rune);
      }
    }
    return changed ? buffer.toString() : input;
  }

  /// 折叠全角 ASCII、乘号、罗马数字（`Ⅰ..Ⅻ`）、片假名（含半角与长音符）与繁体字，
  /// 生成适合跨文字精确比对的规范化小写字符串。
  static String fold(String input) {
    if (input.isEmpty) return '';
    final runes = input.runes.toList(growable: false);
    final buffer = StringBuffer();
    var lastWasProlonged = false;

    for (var i = 0; i < runes.length; i++) {
      final rune = runes[i];
      if (rune >= 0xFF01 && rune <= 0xFF5E) {
        lastWasProlonged = false;
        final half = rune - 0xFEE0;
        if (_isMultiplier(half)) {
          buffer.write(' x ');
        } else {
          buffer.writeCharCode(half);
        }
        continue;
      }
      if (rune == 0x3000) {
        lastWasProlonged = false;
        buffer.write(' ');
        continue;
      }
      if (_isMultiplier(rune)) {
        lastWasProlonged = false;
        buffer.write(' x ');
        continue;
      }
      if (rune >= 0x2160 && rune <= 0x216B) {
        lastWasProlonged = false;
        buffer.write(TitleNormalizerTables.romanFolded[rune - 0x2160]);
        continue;
      }
      if (rune >= 0x2170 && rune <= 0x217B) {
        lastWasProlonged = false;
        buffer.write(TitleNormalizerTables.romanFolded[rune - 0x2170]);
        continue;
      }
      if (rune == 0x30FC || rune == 0xFF70) {
        if (!lastWasProlonged) {
          buffer.write('ー');
          lastWasProlonged = true;
        }
        continue;
      }
      if (rune >= 0xFF66 && rune <= 0xFF9D) {
        lastWasProlonged = false;
        final next = i + 1 < runes.length ? runes[i + 1] : 0;
        final voiced = _combineHalfwidthKatakana(rune, next);
        if (voiced != null) {
          buffer.write(voiced);
          i++;
        } else {
          buffer.write(TitleNormalizerTables.halfwidthBaseHiragana[rune - 0xFF66]);
        }
        continue;
      }
      if (rune == 0xFF9E || rune == 0xFF9F) {
        continue;
      }

      lastWasProlonged = false;
      if ((rune >= 0x30A1 && rune <= 0x30F6) ||
          rune == 0x30FD ||
          rune == 0x30FE) {
        buffer.writeCharCode(rune - 0x60);
      } else {
        buffer.writeCharCode(_tradToSimp[rune] ?? rune);
      }
    }

    return buffer
        .toString()
        .toLowerCase()
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  static bool _isMultiplier(int rune) =>
      rune == 0x00D7 || rune == 0x2715 || rune == 0x2716 || rune == 0x2A2F;

  static String? _combineHalfwidthKatakana(int base, int mark) {
    const baseChars = TitleNormalizerTables.halfwidthBaseHiragana;
    if (mark == 0xFF9E) {
      if (base == 0xFF73) return 'ゔ';
      if ((base >= 0xFF76 && base <= 0xFF84) ||
          (base >= 0xFF8A && base <= 0xFF8E)) {
        final hira = baseChars.codeUnitAt(base - 0xFF66);
        return String.fromCharCode(hira + 1);
      }
    } else if (mark == 0xFF9F && base >= 0xFF8A && base <= 0xFF8E) {
      final hira = baseChars.codeUnitAt(base - 0xFF66);
      return String.fromCharCode(hira + 2);
    }
    return null;
  }

  /// 判断输入文本是否包含日文假名。
  static bool containsKana(String input) => _kanaPattern.hasMatch(input);

  static bool _isHiraganaCode(int rune) =>
      (rune >= 0x3041 && rune <= 0x309F) || rune == 0x30FC;

  /// 将输入中的日文假名片段转写为 ASCII 罗马音，保留原有拉丁字符。
  static String kanaToRomaji(String input) {
    if (!containsKana(input)) return input;
    final folded = fold(input);
    final out = StringBuffer();
    var i = 0;
    var prevWasKana = false;
    while (i < folded.length) {
      final ch = folded[i];
      if (ch == 'っ') {
        if (i + 1 < folded.length) {
          final next = folded.substring(i + 1, i + 2);
          final nextRomaji = TitleNormalizerTables.monographKana[next];
          if (nextRomaji != null && nextRomaji.isNotEmpty) {
            final c = nextRomaji[0];
            if (!'aeiouy'.contains(c)) out.write(c);
          }
        }
        prevWasKana = true;
        i++;
        continue;
      }
      final two = i + 1 < folded.length ? folded.substring(i, i + 2) : null;
      final di = two == null ? null : TitleNormalizerTables.digraphKana[two];
      if (di != null) {
        if (!prevWasKana && out.isNotEmpty && folded[i - 1] != ' ') {
          out.write(' ');
        }
        out.write(di);
        prevWasKana = true;
        i += 2;
        continue;
      }
      final mono = TitleNormalizerTables.monographKana[ch];
      if (mono != null) {
        if (!prevWasKana && out.isNotEmpty && folded[i - 1] != ' ') {
          out.write(' ');
        }
        out.write(mono);
        prevWasKana = true;
        i++;
        continue;
      }
      if (prevWasKana && ch != ' ' && !_isHiraganaCode(ch.codeUnitAt(0))) {
        out.write(' ');
      }
      prevWasKana = false;
      out.write(ch);
      i++;
    }
    return out.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  /// 将英文或罗马音折叠为音近拉丁骨架，用于跨语言模糊匹配辅助计算。
  static String phoneticLatinFold(String input) {
    final s = input.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    if (s.isEmpty) return '';
    return s
        .replaceAll('igh', 'ai')
        .replaceAll('ear', 'ar')
        .replaceAll('ee', 'i')
        .replaceAll('oo', 'u')
        .replaceAll('ph', 'f')
        .replaceAll('qu', 'ku')
        .replaceAll('th', 's')
        .replaceAllMapped(RegExp(r'c(?=[eiy])'), (_) => 's')
        .replaceAll('c', 'k')
        .replaceAll('l', 'r')
        .replaceAll('v', 'b')
        .replaceAll('y', 'i')
        .replaceAllMapped(RegExp(r'([a-z])\1+'), (m) => m.group(1)!);
  }

  static const Map<String, String> _romajiArcBridges = {
    'shinjuku kaiki': '新宿怪异',
    'kaiki': '怪异',
    'monogatari': '物语',
    'shingeki no kyojin': '进击的巨人',
    'kimetsu no yaiba': '鬼灭之刃',
    'jujutsu kaisen': '咒术回战',
    'kaguya-sama': '辉夜大小姐',
    'kaguya sama': '辉夜大小姐',
    'sousou no frieren': '葬送的芙莉莲',
    'kusuriya no hitorigoto': '药屋少女的呢喃',
    'mushoku tensei': '无职转生',
    'oshi no ko': '我推的孩子',
    'bocchi the rock': '孤独摇滚',
    'violet evergarden': '紫罗兰永恒花园',
  };

  /// 罗马数字与阿拉伯数字互转（针对结尾季/部标记如 `II` <-> `2`）。
  static String? romanArabicVariant(String title) {
    final trimmed = title.trim();
    const romanToArabic = {'II': '2', 'III': '3', 'IV': '4', 'V': '5', 'VI': '6'};
    const arabicToRoman = {'2': 'II', '3': 'III', '4': 'IV', '5': 'V', '6': 'VI'};
    for (final entry in romanToArabic.entries) {
      final m = RegExp('^(.*\\s)${entry.key}\$').firstMatch(trimmed);
      if (m != null) return '${m.group(1)}${entry.value}';
    }
    for (final entry in arabicToRoman.entries) {
      final m = RegExp('^(.*\\s)${entry.key}\$').firstMatch(trimmed);
      if (m != null) return '${m.group(1)}${entry.value}';
    }
    return null;
  }

  /// 基于标题结构、罗马数字与高频罗马音篇章词典生成多波次 TMDB 检索扩展词列表。
  static List<String> expandQueryVariants(String rawTitle) {
    final queries = <String>[];
    final seen = <String>{};

    void addQuery(String q) {
      final cleaned = q.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (cleaned.length < 2 && !RegExp(r'^\d+$').hasMatch(cleaned)) return;
      final key = cleaned.toLowerCase();
      if (seen.add(key)) queries.add(cleaned);
    }

    addQuery(rawTitle);

    // 去除常见中文/英文副标题分隔号后的主干（例如 `86 -Eighty Six-` -> `86` / `Eighty Six`）
    final dashMatch = RegExp(r'^(.+?)\s*[-–—:：/]\s*(.+)$').firstMatch(rawTitle);
    if (dashMatch != null) {
      final left = dashMatch.group(1)!.trim();
      final right = dashMatch.group(2)!.replaceAll(RegExp(r'[-–—]+$'), '').trim();
      addQuery(left);
      if (right.length >= 3) addQuery(right);
    }

    final variant = romanArabicVariant(rawTitle);
    if (variant != null) addQuery(variant);

    final folded = fold(rawTitle);
    for (final entry in _romajiArcBridges.entries) {
      if (folded.contains(entry.key)) {
        addQuery(entry.value);
      }
    }

    // 中日混排拆分独立拉丁/CJK主词块
    final cjkOnly = rawTitle
        .replaceAll(RegExp(r'[A-Za-z0-9\-_:.,!?()\[\]]+'), ' ')
        .trim();
    if (cjkOnly.length >= 2) addQuery(cjkOnly);

    return queries;
  }

  /// 将含假名或英文的标题转为归一化音译骨架（保留首音与主要辅音）。
  static String phoneticSkeleton(String input) {
    final romaji = containsKana(input) ? kanaToRomaji(input) : fold(input);
    final folded = phoneticLatinFold(romaji);
    if (folded.length <= 3) return folded;
    final head = folded[0];
    final tail = folded.substring(1).replaceAll(RegExp(r'[aeiou]'), '');
    return '$head$tail';
  }

  /// 计算两侧标题在假名转罗马音与音近折叠后的相似度（`0.0 ~ 1.0`）。
  static double romajiKanaSimilarity(String a, String b) {
    final leftRomaji = phoneticLatinFold(
      containsKana(a) ? kanaToRomaji(a) : fold(a),
    );
    final rightRomaji = phoneticLatinFold(
      containsKana(b) ? kanaToRomaji(b) : fold(b),
    );
    if (leftRomaji.isEmpty || rightRomaji.isEmpty) return 0.0;
    if (leftRomaji == rightRomaji) return 1.0;

    final rawDice = _bigramDice(leftRomaji, rightRomaji);
    final leftSk = phoneticSkeleton(a);
    final rightSk = phoneticSkeleton(b);
    final skDice = _bigramDice(leftSk, rightSk);
    return rawDice >= skDice ? rawDice : skDice * 0.94;
  }

  /// 检验 [query] 中各独立音译词条是否被 [candidate] 覆盖。
  static bool phoneticTokenCovered(String query, String candidate) {
    final qRomaji = phoneticLatinFold(
      containsKana(query) ? kanaToRomaji(query) : fold(query),
    );
    final cRomaji = phoneticLatinFold(
      containsKana(candidate) ? kanaToRomaji(candidate) : fold(candidate),
    );
    if (qRomaji.length < 3 || cRomaji.length < 3) return false;
    return cRomaji.contains(qRomaji) || qRomaji.contains(cRomaji);
  }

  static double _bigramDice(String a, String b) {
    if (a.length < 2 || b.length < 2) return a == b ? 1.0 : 0.0;
    final counts = <String, int>{};
    for (var i = 0; i < a.length - 1; i++) {
      final g = a.substring(i, i + 2);
      counts[g] = (counts[g] ?? 0) + 1;
    }
    var hit = 0;
    for (var i = 0; i < b.length - 1; i++) {
      final g = b.substring(i, i + 2);
      final left = counts[g] ?? 0;
      if (left > 0) {
        hit++;
        counts[g] = left - 1;
      }
    }
    return 2.0 * hit / (a.length + b.length - 2);
  }
}
