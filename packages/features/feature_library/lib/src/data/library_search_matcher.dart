import 'package:engine_scraping/engine_scraping.dart';

/// 媒体库海报墙内置模糊与前缀精准搜索匹配器（零外部状态依赖）。
///
/// 支持前缀语法：
/// - `tmdb:<id>`：按 TMDB 编号精准检索；
/// - `bgm:<id>` / `bangumi:<id>`：按 Bangumi 条目编号精准检索；
/// - `group:<压制组>` / `压制组:<压制组>`：按字幕组或压制组精准检索；
/// - 其余关键字自动兼容全角/半角折算、多词空格分词及中文标题/原名/年份/压制组排序。
abstract final class LibrarySearchMatcher {
  static final RegExp _tmdbPrefixRe = RegExp(r'^tmdb[:\-](\d+)$');
  static final RegExp _bgmPrefixRe = RegExp(r'^(?:bgm|bangumi)[:\-](\d+)$');
  static final RegExp _groupPrefixRe = RegExp(r'^(?:group|压制组)[:\-](.+)$');
  static final RegExp _whitespaceRe = RegExp(r'\s+');

  /// 将输入字符串归一化为小写的半角紧凑格式以便检索。
  static String normalizeForSearch(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return '';
    final buffer = StringBuffer();
    for (final unit in trimmed.codeUnits) {
      if (unit == 0x3000) {
        buffer.writeCharCode(0x20);
      } else if (unit >= 0xFF01 && unit <= 0xFF5E) {
        buffer.writeCharCode(unit - 0xFEE0);
      } else {
        buffer.writeCharCode(unit);
      }
    }
    return buffer.toString().toLowerCase().replaceAll(_whitespaceRe, ' ').trim();
  }

  /// 对单部作品计算检索命中等级（数字越小优先级越高；未命中返回 `null`）。
  static int? matchRank({
    required Work work,
    required List<String> releaseGroups,
    required String rawQuery,
  }) {
    final query = normalizeForSearch(rawQuery);
    if (query.isEmpty) return 0;

    final tmdbMatch = _tmdbPrefixRe.firstMatch(query);
    if (tmdbMatch != null) {
      final targetId = int.tryParse(tmdbMatch.group(1)!);
      if (targetId != null && work.tmdbId == targetId) return 0;
      return null;
    }

    final bgmMatch = _bgmPrefixRe.firstMatch(query);
    if (bgmMatch != null) {
      final targetId = int.tryParse(bgmMatch.group(1)!);
      if (targetId != null && work.bangumiId == targetId) return 0;
      return null;
    }

    final groupMatch = _groupPrefixRe.firstMatch(query);
    if (groupMatch != null) {
      final groupTerms = groupMatch
          .group(1)!
          .split(_whitespaceRe)
          .where((s) => s.isNotEmpty)
          .toList(growable: false);
      if (groupTerms.isEmpty) return 0;
      final normalizedGroups = [
        for (final g in releaseGroups) normalizeForSearch(g),
      ];
      final matched = groupTerms.every(
        (term) => normalizedGroups.any((g) => g.contains(term)),
      );
      return matched ? 0 : null;
    }

    final title = normalizeForSearch(work.title);
    final originalTitle = normalizeForSearch(work.originalTitle ?? '');
    final yearText = work.year?.toString() ?? '';
    final normalizedGroups = [
      for (final g in releaseGroups) normalizeForSearch(g),
    ];

    final terms = query
        .split(_whitespaceRe)
        .where((s) => s.isNotEmpty)
        .toList(growable: false);
    if (terms.isEmpty) return 0;

    var worstRank = 0;
    for (final term in terms) {
      if (title.startsWith(term)) {
        continue;
      }
      if (title.contains(term)) {
        if (worstRank < 1) worstRank = 1;
        continue;
      }
      if (originalTitle.contains(term)) {
        if (worstRank < 2) worstRank = 2;
        continue;
      }
      if (normalizedGroups.any((g) => g.contains(term)) ||
          (yearText.isNotEmpty && yearText.contains(term))) {
        if (worstRank < 3) worstRank = 3;
        continue;
      }
      return null;
    }
    return worstRank;
  }

  /// 对列表执行过滤并按检索相关性稳定排序（保持同等级项原本排列次序）。
  static List<T> filterAndRank<T>({
    required List<T> items,
    required Work Function(T item) workOf,
    required List<String> Function(T item) releaseGroupsOf,
    required String rawQuery,
  }) {
    final query = rawQuery.trim();
    if (query.isEmpty) return items;

    final ranked = <({T item, int rank, int originalIndex})>[];
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      final rank = matchRank(
        work: workOf(item),
        releaseGroups: releaseGroupsOf(item),
        rawQuery: query,
      );
      if (rank != null) {
        ranked.add((item: item, rank: rank, originalIndex: i));
      }
    }
    ranked.sort((a, b) {
      final rankCmp = a.rank.compareTo(b.rank);
      if (rankCmp != 0) return rankCmp;
      return a.originalIndex.compareTo(b.originalIndex);
    });
    return List<T>.unmodifiable([for (final entry in ranked) entry.item]);
  }
}
