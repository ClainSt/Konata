import '../models/work.dart';

/// 媒体库海报墙本地搜索匹配与相关度分级器（纯领域无副作用）。
///
/// 规则说明：
/// 1. 支持 `tmdb:ID` / `tmdb-ID` 与 `bgm:ID` / `bangumi:ID` 显式精确 ID 查询；
/// 2. 纯数字关键词仅在等于完整 TMDB ID 或 Bangumi ID 时才按 ID 命中，杜绝子串碰撞
///    （如搜索 `86` 误召回 TMDB ID `486947` 的作品）；
/// 3. 常规关键词支持空格分词全命中，按「标题前缀/精确 ID -> 标题包含 -> 原名包含 -> 压制组」稳定排序。
abstract final class LibrarySearchMatcher {
  static final RegExp _tmdbPrefixRe = RegExp(r'^tmdb[:\-](\d+)$');
  static final RegExp _bgmPrefixRe = RegExp(r'^(?:bgm|bangumi)[:\-](\d+)$');
  static final RegExp _pureDigitsRe = RegExp(r'^\d+$');
  static final RegExp _whitespaceRe = RegExp(r'\s+');

  /// 计算单部作品相对搜索词的匹配优先级（返回 `null` 表示未命中，数值越小越靠前）。
  static int? matchRank({
    required Work work,
    required Iterable<String> releaseGroups,
    required String rawQuery,
  }) {
    final query = rawQuery.trim().toLowerCase();
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

    if (_pureDigitsRe.hasMatch(query)) {
      final exactId = int.tryParse(query);
      if (exactId != null &&
          (work.tmdbId == exactId || work.bangumiId == exactId)) {
        return 0;
      }
    }

    final title = work.title.toLowerCase();
    final originalTitle = (work.originalTitle ?? '').toLowerCase();
    final groups = releaseGroups
        .map((g) => g.toLowerCase())
        .where((g) => g.isNotEmpty)
        .toList(growable: false);

    final terms = query
        .split(_whitespaceRe)
        .where((t) => t.isNotEmpty)
        .toList(growable: false);
    if (terms.isEmpty) return 0;

    if (terms.length == 1 && (title == query || title.startsWith(query))) {
      return 0;
    }

    var allInTitle = true;
    var allInTitleOrOriginal = true;
    for (final term in terms) {
      final inTitle = title.contains(term);
      final inOriginal = !inTitle && originalTitle.contains(term);
      final inGroup =
          !inTitle && !inOriginal && groups.any((g) => g.contains(term));
      if (!inTitle && !inOriginal && !inGroup) {
        return null;
      }
      if (!inTitle) {
        allInTitle = false;
      }
      if (!inTitle && !inOriginal) {
        allInTitleOrOriginal = false;
      }
    }

    if (allInTitle) return 1;
    if (allInTitleOrOriginal) return 2;
    return 3;
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

    final buckets = <List<T>>[<T>[], <T>[], <T>[], <T>[]];
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
    return <T>[...buckets[0], ...buckets[1], ...buckets[2], ...buckets[3]];
  }
}
