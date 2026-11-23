import 'dart:math' as math;

import '../matching/work_matcher_scoring.dart';
import '../playback/lyric_version_matcher.dart';

/// 歌词检索请求（由当前曲目的标题、歌手、专辑与时长构成，内置别名扩展与多步查询计划）。
class LyricSearchQuery {
  /// 创建歌词检索请求。
  LyricSearchQuery({
    required String title,
    this.artist = '',
    this.album = '',
    this.fileName = '',
    this.durationSeconds,
    this.extraTitleAliases = const [],
  }) : title = cleanTitle(title);

  static final RegExp _leadingTrackNumber = RegExp(r'^\d{1,3}\s*[\s._\-、．]\s*');
  static final RegExp _audioExtension = RegExp(
    r'\.(flac|wav|ape|mp3|m4a|aac|ogg|opus|tak|tta|wv|dsf|dff)$',
    caseSensitive: false,
  );
  static final RegExp _quotedTitleRegex = RegExp(r'[「『]([^「」『』]{2,})[」』]');
  static final RegExp _waveSubtitleRegex = RegExp(
    r'\s*[～~─—－-]\s*[^～~─—]+?[～~─—－-]\s*$',
  );
  static final RegExp _trailingParenRegex = RegExp(
    r'\s*[\(（\[【][^()（）\[\]【】]+[\)）\]】]\s*$',
  );

  /// 去除音轨序号与扩展名后的检索曲名。
  final String title;

  /// 歌手（可为空）。
  final String artist;

  /// 专辑名（可为空）。
  final String album;

  /// 物理文件名（仅用于伴奏判定）。
  final String fileName;

  /// 本地曲目时长（秒，未知为 `null`）。
  final double? durationSeconds;

  /// 外部补充的额外曲名别名（如 Bangumi 关联音乐曲目表的日文原名/中文名）。
  final List<String> extraTitleAliases;

  /// 去除文件名形态曲名开头的音轨序号与音频扩展名；清洗后为空时保留原文。
  static String cleanTitle(String raw) {
    final trimmed = raw.trim();
    final stripped = trimmed
        .replaceFirst(_audioExtension, '')
        .replaceFirst(_leadingTrackNumber, '')
        .replaceAll('_', ' ')
        .trim();
    return stripped.isEmpty ? trimmed : stripped;
  }

  /// 关键词搜索使用的首选关键词（保留原始假名与汉字，不做规范化）。
  String get keyword =>
      artist.trim().isEmpty ? title : '$title ${artist.trim()}';

  /// 扩展后的标题别名列表（最多 6 个）：原标题、去版本后缀、`「」『』` 内核心曲名、去 `～副标题～`、去尾部括号译名。
  List<String> get titleAliases {
    final seen = <String>{};
    final out = <String>[];
    void add(String raw) {
      final t = raw.trim();
      if (t.isEmpty || out.length >= 6) return;
      final key = WorkMatcherScoring.normalizeKey(t);
      if (key.isEmpty || !seen.add(key)) return;
      out.add(t);
    }

    add(title);
    for (final extra in extraTitleAliases) {
      add(extra);
    }
    // 抽取书名号/日文引号内文本（优先最后一对，典型如 `TVアニメ「作品名」OP「曲名」`）。
    final quotes = _quotedTitleRegex.allMatches(title).toList();
    if (quotes.isNotEmpty) {
      for (final match in quotes.reversed) {
        add(match.group(1) ?? '');
      }
    }
    // 去除波浪号副标题（如 `名前のない怪物 ～TV Edit～`）。
    final withoutWave = title.replaceFirst(_waveSubtitleRegex, '').trim();
    if (withoutWave != title) add(withoutWave);
    // 去除尾部括号附注（译名 / 动画标注 / 版本括号）。
    final withoutParen = title.replaceFirst(_trailingParenRegex, '').trim();
    if (withoutParen != title) add(withoutParen);
    // 去除版本标签后的核心标题。
    final core = LyricVersionMatcher.coreTitle(title);
    if (core.isNotEmpty) add(core);
    return out;
  }

  /// 提取用于关键词检索的清洗歌手名列表（含 `角色(CV:声优)` 拆出的声优名与括号外主名）。
  List<String> get searchArtists {
    final trimmed = artist.trim();
    if (trimmed.isEmpty) return const [];
    final out = <String>[];
    final seen = <String>{};
    void add(String raw) {
      final s = raw.trim();
      if (s.isEmpty) return;
      final k = WorkMatcherScoring.normalizeKey(s);
      if (k.isEmpty || !seen.add(k)) return;
      out.add(s);
    }

    final cv = LyricTextSimilarity.extractCvParts(trimmed);
    if (cv != null) {
      // 角色歌检索时声优名往往比“角色(CV:声优)”整串命中率更高。
      add(cv.actor);
      add(cv.role);
    }
    final strippedParen = trimmed.replaceFirst(_trailingParenRegex, '').trim();
    add(strippedParen);
    add(trimmed);
    return out;
  }

  /// 构造多步降级查询关键词计划（首步保留原词，仅无合格命中时按序降级重试，避免拖慢正常命中路径）。
  List<String> buildSearchKeywords() {
    final out = <String>[];
    final seen = <String>{};
    void add(String kw) {
      final t = kw.trim().replaceAll(RegExp(r'\s+'), ' ');
      if (t.isEmpty) return;
      if (seen.add(t.toLowerCase())) out.add(t);
    }

    // 步骤 1：原标题 + 原歌手（默认最优，不丢假名）。
    add(keyword);
    final aliases = titleAliases;
    final artists = searchArtists;
    // 步骤 2：原标题或去后缀核心标题 + 清洗后的主歌手/声优名。
    if (artists.isNotEmpty) {
      add('$title ${artists.first}');
      if (aliases.length > 1) {
        add('${aliases[1]} ${artists.first}');
      }
    }
    // 步骤 3：仅主标题或核心别名（应对歌手中日译名差异，如 `DAOKO×米津玄師` 或 `いきものがかり` vs `生物股长`）。
    add(title);
    if (aliases.length > 1) {
      add(aliases[1]);
    }
    return out;
  }

  /// 跨文件共享的歌曲身份键；时长未知时返回 `null`（不跨文件共享）。
  String? get songKey {
    final dur = durationSeconds;
    if (dur == null || dur <= 0) return null;
    final t = WorkMatcherScoring.normalizeKey(title);
    if (t.isEmpty) return null;
    final a = WorkMatcherScoring.normalizeKey(artist);
    return '$t|$a|${(dur / 3).round()}';
  }
}

/// 曲名与歌手相似度计算（复用全仓统一的标题折叠、二元组 Dice 与编辑距离实现）。
abstract final class LyricTextSimilarity {
  static final RegExp _artistSplit = RegExp(
    r'\s*(?:/|／|、|,|，|&|＆|;|；|\sx\s|×|\sfeat\.?\s|\sft\.?\s|\swith\s)\s*',
    caseSensitive: false,
  );
  static final RegExp _cvPattern = RegExp(
    r'^(.*?)\s*[\(（]\s*(?:cv|ｃｖ)\s*[.:：．]?\s*(.+?)\s*[\)）]\s*$',
    caseSensitive: false,
  );
  static final RegExp _parenNotePattern = RegExp(
    r'^(.+?)\s*[\(（]([^()（）]+)[\)）]\s*$',
  );
  static final RegExp _waveSubtitlePattern = RegExp(
    r'\s*[～~─—－-]\s*[^～~─—]+?[～~─—－-]\s*$',
  );
  static final RegExp _quotedPattern = RegExp(r'[「『]([^「」『』]{2,})[」』]');

  /// 从 `角色(CV.声优)` 形态中提取角色名与声优名。
  static ({String role, String actor})? extractCvParts(String raw) {
    final match = _cvPattern.firstMatch(raw.trim());
    if (match == null) return null;
    final role = (match.group(1) ?? '').trim();
    final actor = (match.group(2) ?? '').trim();
    if (role.isEmpty && actor.isEmpty) return null;
    return (role: role, actor: actor);
  }

  /// 去除版本后缀后的曲名比对键。
  static String coreTitleKey(String raw) {
    return WorkMatcherScoring.normalizeKey(LyricVersionMatcher.coreTitle(raw));
  }

  /// 提取单条曲名的多个规范化比对键（含去括号译名、去波浪副标题、`「」` 内核心名）。
  static Set<String> extractTitleKeys(String raw) {
    final keys = <String>{};
    void add(String s) {
      final k = coreTitleKey(s);
      if (k.isNotEmpty) keys.add(k);
    }

    final trimmed = raw.trim();
    add(trimmed);
    final paren = _parenNotePattern.firstMatch(trimmed);
    if (paren != null) {
      add(paren.group(1) ?? '');
    }
    final withoutWave = trimmed.replaceFirst(_waveSubtitlePattern, '').trim();
    if (withoutWave != trimmed) add(withoutWave);
    for (final m in _quotedPattern.allMatches(trimmed)) {
      add(m.group(1) ?? '');
    }
    return keys;
  }

  /// 曲名相似度：双方提取规范化别名键后取两两最大值（全等 1.0 / 包含且短串 >= 4 取 0.9 / 编辑距离与 Dice 最大值）。
  static double titleSimilarity(String a, String b) {
    final keysA = extractTitleKeys(a);
    final keysB = extractTitleKeys(b);
    if (keysA.isEmpty || keysB.isEmpty) return 0.0;
    var best = 0.0;
    for (final ka in keysA) {
      for (final kb in keysB) {
        final sim = _pairSimilarity(ka, kb, containMinLen: 4);
        if (sim > best) best = sim;
        if (best >= 1.0) return 1.0;
      }
    }
    return best;
  }

  /// 歌手相似度：双方拆分为独立歌手名（含 `角色(CV:声优)` 与括号译名/假名读音拆分）后取两两最大相似度；任一方缺失返回 0.5。
  static double artistSimilarity(String a, String b) {
    final la = splitArtists(a);
    final lb = splitArtists(b);
    if (la.isEmpty || lb.isEmpty) return 0.5;
    var best = 0.0;
    for (final x in la) {
      for (final y in lb) {
        final sim = _pairSimilarity(x, y, containMinLen: 2);
        if (sim > best) best = sim;
        if (best >= 1.0) return 1.0;
      }
    }
    return best;
  }

  /// 将歌手字段拆分为规范化后的独立名字集合（兼容 `角色(CV:声优)`、括号译名/读音与谨慎中点拆分）。
  static Set<String> splitArtists(String raw) {
    final out = <String>{};
    void addNormalized(String text) {
      final key = WorkMatcherScoring.normalizeKey(text);
      if (key.isNotEmpty) out.add(key);
    }

    for (final part in raw.split(_artistSplit)) {
      final trimmed = part.trim();
      if (trimmed.isEmpty) continue;
      final cv = _cvPattern.firstMatch(trimmed);
      if (cv != null) {
        addNormalized(cv.group(1) ?? '');
        addNormalized(cv.group(2) ?? '');
        continue;
      }
      // 处理 QQ 等平台常见的 `LiSA (织部里沙)`、`高橋洋子 (たかはし ようこ)` 括号附注。
      final paren = _parenNotePattern.firstMatch(trimmed);
      if (paren != null) {
        addNormalized(paren.group(1) ?? '');
        addNormalized(paren.group(2) ?? '');
      }
      // 谨慎处理中点 `・`（仅当两侧各至少 2 字符时作为附加别名，防止拆坏单名）。
      if (trimmed.contains('・')) {
        final dotParts = trimmed.split('・').map((e) => e.trim()).toList();
        if (dotParts.length >= 2 &&
            dotParts.every((p) => p.runes.length >= 2)) {
          for (final dp in dotParts) {
            addNormalized(dp);
          }
        }
      }
      addNormalized(trimmed);
    }
    return out;
  }

  /// 标准化键两两相似度：`全等 1.0` / `较短方 >= containMinLen 且被包含 0.9` / `max(1 - 编辑距离比, bigramDice)`。
  static double _pairSimilarity(
    String a,
    String b, {
    required int containMinLen,
  }) {
    if (a.isEmpty || b.isEmpty) return 0.0;
    if (a == b) return 1.0;
    final aShorter = a.length <= b.length;
    final shorter = aShorter ? a : b;
    final longer = aShorter ? b : a;
    if (shorter.runes.length >= containMinLen && longer.contains(shorter)) {
      return 0.9;
    }
    final dice = WorkMatcherScoring.bigramDice(a, b);
    final editSim = _levenshteinSimilarity(a, b);
    return math.max(dice, editSim);
  }

  /// 基于编辑距离的归一化字符串相似度（`0.0 ~ 1.0`）。
  static double _levenshteinSimilarity(String a, String b) {
    final ra = a.runes.toList(growable: false);
    final rb = b.runes.toList(growable: false);
    final la = ra.length;
    final lb = rb.length;
    final maxLen = math.max(la, lb);
    if (maxLen == 0) return 1.0;
    // 过长字符串（如冗长专辑/曲名备注）直接交由 bigramDice，避免无谓 O(n*m) 分配。
    if (la > 64 || lb > 64) return 0.0;

    var prev = List<int>.generate(lb + 1, (j) => j);
    var curr = List<int>.filled(lb + 1, 0);
    for (var i = 1; i <= la; i++) {
      curr[0] = i;
      for (var j = 1; j <= lb; j++) {
        final cost = ra[i - 1] == rb[j - 1] ? 0 : 1;
        final del = prev[j] + 1;
        final ins = curr[j - 1] + 1;
        final sub = prev[j - 1] + cost;
        curr[j] = math.min(math.min(del, ins), sub);
      }
      final tmp = prev;
      prev = curr;
      curr = tmp;
    }
    return 1.0 - (prev[lb] / maxLen);
  }
}
