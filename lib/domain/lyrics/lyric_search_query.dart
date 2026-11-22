import '../matching/work_matcher_scoring.dart';
import '../playback/lyric_version_matcher.dart';

/// 歌词检索请求（由当前曲目的标题、歌手、专辑与时长构成）。
class LyricSearchQuery {
  /// 创建歌词检索请求。
  LyricSearchQuery({
    required String title,
    this.artist = '',
    this.album = '',
    this.fileName = '',
    this.durationSeconds,
  }) : title = cleanTitle(title);

  static final RegExp _leadingTrackNumber = RegExp(r'^\d{1,3}\s*[\s._\-、．]\s*');
  static final RegExp _audioExtension = RegExp(
    r'\.(flac|wav|ape|mp3|m4a|aac|ogg|opus|tak|tta|wv|dsf|dff)$',
    caseSensitive: false,
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

  /// 关键词搜索使用的关键词（保留原始假名与汉字，不做规范化）。
  String get keyword =>
      artist.trim().isEmpty ? title : '$title ${artist.trim()}';

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

/// 曲名与歌手相似度计算（复用全仓统一的标题折叠与二元组 Dice 实现）。
abstract final class LyricTextSimilarity {
  static final RegExp _artistSplit = RegExp(
    r'\s*(?:/|／|、|,|，|&|＆|;|；|\sx\s|×|\sfeat\.?\s|\sft\.?\s|\swith\s)\s*',
    caseSensitive: false,
  );
  static final RegExp _cvPattern = RegExp(
    r'^(.*?)\s*[\(（]\s*(?:cv|ｃｖ)\s*[.:：．]?\s*(.+?)\s*[\)）]\s*$',
    caseSensitive: false,
  );

  /// 去除版本后缀后的曲名比对键。
  static String coreTitleKey(String raw) {
    return WorkMatcherScoring.normalizeKey(LyricVersionMatcher.coreTitle(raw));
  }

  /// 曲名相似度：完全一致为 1.0，较短一方不少于 4 字且被包含为 0.9，其余取二元组 Dice 系数。
  static double titleSimilarity(String a, String b) {
    final ka = coreTitleKey(a);
    final kb = coreTitleKey(b);
    if (ka.isEmpty || kb.isEmpty) return 0.0;
    if (ka == kb) return 1.0;
    final aShorter = ka.length <= kb.length;
    final shorter = aShorter ? ka : kb;
    final longer = aShorter ? kb : ka;
    if (shorter.runes.length >= 4 && longer.contains(shorter)) return 0.9;
    return WorkMatcherScoring.bigramDice(ka, kb);
  }

  /// 歌手相似度：双方拆分为独立歌手名（含 `角色(CV:声优)` 拆分）后取两两最大相似度；任一方缺失返回 0.5。
  static double artistSimilarity(String a, String b) {
    final la = splitArtists(a);
    final lb = splitArtists(b);
    if (la.isEmpty || lb.isEmpty) return 0.5;
    var best = 0.0;
    for (final x in la) {
      for (final y in lb) {
        final double sim;
        if (x == y) {
          sim = 1.0;
        } else if (x.runes.length >= 2 &&
            y.runes.length >= 2 &&
            (x.contains(y) || y.contains(x))) {
          sim = 0.9;
        } else {
          sim = WorkMatcherScoring.bigramDice(x, y);
        }
        if (sim > best) best = sim;
      }
    }
    return best;
  }

  /// 将歌手字段拆分为规范化后的独立名字集合。
  static Set<String> splitArtists(String raw) {
    final out = <String>{};
    for (final part in raw.split(_artistSplit)) {
      final trimmed = part.trim();
      if (trimmed.isEmpty) continue;
      final cv = _cvPattern.firstMatch(trimmed);
      if (cv != null) {
        final role = WorkMatcherScoring.normalizeKey(cv.group(1) ?? '');
        final actor = WorkMatcherScoring.normalizeKey(cv.group(2) ?? '');
        if (role.isNotEmpty) out.add(role);
        if (actor.isNotEmpty) out.add(actor);
        continue;
      }
      final key = WorkMatcherScoring.normalizeKey(trimmed);
      if (key.isNotEmpty) out.add(key);
    }
    return out;
  }
}
