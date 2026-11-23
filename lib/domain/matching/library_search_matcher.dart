import '../models/work.dart';

/// 媒体库海报墙本地搜索匹配与相关度分级器（纯领域无副作用）。
///
/// 规则说明：
/// 1. 常规搜索仅匹配作品「译名（title）」与「原名（originalTitle）」，支持空格分词与全角半角归一，
///    绝不拿隐藏字段（TMDB/Bangumi 数字 ID 或易含 `x264`/`Vol.4`/`1440x1080p`/`Moozzi2` 的压制组标签）
///    污染普通搜索结果；
/// 2. 显式结构化前缀支持精确检索：`tmdb:ID` / `bgm:ID` / `bangumi:ID` 按完整 ID 精确命中，
///    `group:关键词` / `压制组:关键词` 按压制组命中；
/// 3. 按「译名前缀 -> 译名包含 -> 原名包含」稳定排序，同级保留原媒体库顺序。
abstract final class LibrarySearchMatcher {
  static final RegExp _tmdbPrefixRe = RegExp(r'^tmdb[:\-](\d+)$');
  static final RegExp _bgmPrefixRe = RegExp(r'^(?:bgm|bangumi)[:\-](\d+)$');
  static final RegExp _groupPrefixRe = RegExp(r'^(?:group|压制组)[:\-](.+)$');
  static final RegExp _whitespaceRe = RegExp(r'\s+');

  /// 将全角 ASCII 字符与全角空格归一为半角小写，兼容 `８６` / `Ｘ` 等日文原名检索。
  static String normalizeForSearch(String input) {
    if (input.isEmpty) return '';
    final buffer = StringBuffer();
    for (final unit in input.codeUnits) {
      if (unit == 0x3000) {
        buffer.writeCharCode(0x20);
      } else if (unit >= 0xFF01 && unit <= 0xFF5E) {
        buffer.writeCharCode(unit - 0xFEE0);
      } else {
        buffer.writeCharCode(unit);
      }
    }
    return buffer.toString().toLowerCase().trim();
  }

  /// 计算单部作品相对搜索词的匹配优先级（返回 `null` 表示未命中，数值越小越靠前）。
  static int? matchRank({
    required Work work,
    required Iterable<String> releaseGroups,
    required String rawQuery,
  }) {
    final query = normalizeForSearch(rawQuery);
    if (query.isEmpty) return 0;

    final tmdbMatch = _tmdbPrefixRe.firstMatch(query);
    if (tmdbMatch != null) {
      final targetId = int.tryParse(tmdbMatch.group(1)!);
      return (targetId != null && work.tmdbId == targetId) ? 0 : null;
    }

    final bgmMatch = _bgmPrefixRe.firstMatch(query);
    if (bgmMatch != null) {
      final targetId = int.tryParse(bgmMatch.group(1)!);
      return (targetId != null && work.bangumiId == targetId) ? 0 : null;
    }

    final groupMatch = _groupPrefixRe.firstMatch(query);
    if (groupMatch != null) {
      final groupTerms = groupMatch
          .group(1)!
          .trim()
          .split(_whitespaceRe)
          .where((t) => t.isNotEmpty)
          .toList(growable: false);
      if (groupTerms.isEmpty) return null;
      final normalizedGroups = releaseGroups
          .map(normalizeForSearch)
          .where((g) => g.isNotEmpty)
          .toList(growable: false);
      if (normalizedGroups.isEmpty) return null;
      final matched = groupTerms.every(
        (term) => normalizedGroups.any((g) => g.contains(term)),
      );
      return matched ? 0 : null;
    }

    final title = normalizeForSearch(work.title);
    final originalTitle = normalizeForSearch(work.originalTitle ?? '');

    final terms = query
        .split(_whitespaceRe)
        .where((t) => t.isNotEmpty)
        .toList(growable: false);
    if (terms.isEmpty) return 0;

    if (terms.length == 1 && (title == query || title.startsWith(query))) {
      return 0;
    }

    var allInTitle = true;
    for (final term in terms) {
      final inTitle = title.contains(term);
      final inOriginal = !inTitle && originalTitle.contains(term);
      if (!inTitle && !inOriginal) {
        return null;
      }
      if (!inTitle) {
        allInTitle = false;
      }
    }

    return allInTitle ? 1 : 2;
  }

  /// 对任意包装列表执行媒体库搜索过滤，并按相关度稳定排序（同级别保持原顺序）。
  static List<T> filterAndRank<T>({
    required List<T> items,
    required String rawQuery,
    required Work Function(T item) workOf,
    required Iterable<String> Function(T item) releaseGroupsOf,
  }) {
    final query = rawQuery.trim();
    if (query.isEmpty) return items;

    final buckets = <List<T>>[<T>[], <T>[], <T>[]];
    for (final item in items) {
      final rank = matchRank(
        work: workOf(item),
        releaseGroups: releaseGroupsOf(item),
        rawQuery: query,
      );
      if (rank != null) {
        buckets[rank].add(item);
      }
    }
    return <T>[...buckets[0], ...buckets[1], ...buckets[2]];
  }
}
