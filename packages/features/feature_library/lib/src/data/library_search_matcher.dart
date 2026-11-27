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
    return buffer
        .toString()
        .toLowerCase()
        .replaceAll(_whitespaceRe, ' ')
        .trim();
  }

  /// 对单部作品计算检索命中等级（数字越小优先级越高；未命中返回 null）。
  static int? matchRank({
    required Work work,
    required List<String> releaseGroups,
    required String rawQuery,
  }) => _compile(rawQuery).rank(work, releaseGroups);

  /// 每轮检索只解析一次查询，避免每部作品重复运行正则与分词。
  static _CompiledQuery _compile(String rawQuery) {
    final query = normalizeForSearch(rawQuery);
    if (query.isEmpty) return const _CompiledQuery(_QueryKind.empty);
    final tmdb = _tmdbPrefixRe.firstMatch(query);
    if (tmdb != null) {
      return _CompiledQuery(_QueryKind.tmdb, id: int.tryParse(tmdb.group(1)!));
    }
    final bgm = _bgmPrefixRe.firstMatch(query);
    if (bgm != null) {
      return _CompiledQuery(_QueryKind.bgm, id: int.tryParse(bgm.group(1)!));
    }
    final group = _groupPrefixRe.firstMatch(query);
    return _CompiledQuery(
      group == null ? _QueryKind.general : _QueryKind.group,
      terms: (group?.group(1) ?? query)
          .split(_whitespaceRe)
          .where((s) => s.isNotEmpty)
          .toList(growable: false),
    );
  }

  /// 四级命中分桶保持原始顺序，无须为每个命中项分配排序记录。
  static List<T> filterAndRank<T>({
    required List<T> items,
    required Work Function(T item) workOf,
    required List<String> Function(T item) releaseGroupsOf,
    required String rawQuery,
  }) {
    if (rawQuery.trim().isEmpty) return items;
    final query = _compile(rawQuery);
    final buckets = List.generate(4, (_) => <T>[]);
    for (final item in items) {
      final rank = query.rank(workOf(item), releaseGroupsOf(item));
      if (rank != null) buckets[rank].add(item);
    }
    return List<T>.unmodifiable(buckets.expand((bucket) => bucket));
  }
}

/// 当前有序海报墙快照的检索索引；只在该快照内复用归一化字段。
/// 查询结果仍按原有四级相关性和输入顺序排列。
final class LibrarySearchIndex<T> {
  LibrarySearchIndex({
    required List<T> items,
    required Work Function(T item) workOf,
    required List<String> Function(T item) releaseGroupsOf,
  }) : _items = List<T>.unmodifiable(items),
       _entries = [
         for (final item in items)
           (
             item: item,
             fields: _SearchFields(workOf(item), releaseGroupsOf(item)),
           ),
       ];

  final List<T> _items;
  final List<({T item, _SearchFields fields})> _entries;

  /// 对同一快照重复搜索，不重新处理已归一化的作品字段。
  List<T> search(String rawQuery) {
    if (rawQuery.trim().isEmpty) return _items;
    final query = LibrarySearchMatcher._compile(rawQuery);
    final buckets = List.generate(4, (_) => <T>[]);
    for (final entry in _entries) {
      final fields = entry.fields;
      final rank = query.rank(
        fields.work,
        fields.releaseGroups,
        prepared: fields,
      );
      if (rank != null) buckets[rank].add(entry.item);
    }
    return List<T>.unmodifiable(buckets.expand((bucket) => bucket));
  }
}

/// 懒加载检索字段，精准 ID 查询不触发标题与压制组字符串分配。
final class _SearchFields {
  _SearchFields(this.work, List<String> releaseGroups)
    : releaseGroups = List<String>.unmodifiable(releaseGroups);

  final Work work;
  final List<String> releaseGroups;
  late final String title = LibrarySearchMatcher.normalizeForSearch(work.title);
  late final String originalTitle = LibrarySearchMatcher.normalizeForSearch(
    work.originalTitle ?? '',
  );
  late final String yearText = work.year?.toString() ?? '';
  late final List<String> groups = [
    for (final group in releaseGroups)
      LibrarySearchMatcher.normalizeForSearch(group),
  ];
}

enum _QueryKind { empty, tmdb, bgm, group, general }

/// 单次查询的临时解析结果，不缓存作品元数据或跨查询状态。
final class _CompiledQuery {
  const _CompiledQuery(this.kind, {this.id, this.terms = const []});

  final _QueryKind kind;
  final int? id;
  final List<String> terms;

  int? rank(Work work, List<String> releaseGroups, {_SearchFields? prepared}) {
    switch (kind) {
      case _QueryKind.empty:
        return 0;
      case _QueryKind.tmdb:
        return id != null && work.tmdbId == id ? 0 : null;
      case _QueryKind.bgm:
        return id != null && work.bangumiId == id ? 0 : null;
      case _QueryKind.group:
        if (terms.isEmpty) return 0;
        final normalizedGroups =
            prepared?.groups ??
            [
              for (final group in releaseGroups)
                LibrarySearchMatcher.normalizeForSearch(group),
            ];
        return terms.every(
              (term) => normalizedGroups.any((group) => group.contains(term)),
            )
            ? 0
            : null;
      case _QueryKind.general:
        final title =
            prepared?.title ??
            LibrarySearchMatcher.normalizeForSearch(work.title);
        // 只有标题未命中时才归一化原名、压制组与年份。
        String? originalTitle;
        String? yearText;
        List<String>? groups;
        var worstRank = 0;
        for (final term in terms) {
          if (title.startsWith(term)) continue;
          if (title.contains(term)) {
            if (worstRank < 1) worstRank = 1;
            continue;
          }
          originalTitle ??=
              prepared?.originalTitle ??
              LibrarySearchMatcher.normalizeForSearch(work.originalTitle ?? '');
          if (originalTitle.contains(term)) {
            if (worstRank < 2) worstRank = 2;
            continue;
          }
          groups ??=
              prepared?.groups ??
              [
                for (final group in releaseGroups)
                  LibrarySearchMatcher.normalizeForSearch(group),
              ];
          yearText ??= prepared?.yearText ?? work.year?.toString() ?? '';
          if (groups.any((group) => group.contains(term)) ||
              (yearText.isNotEmpty && yearText.contains(term))) {
            if (worstRank < 3) worstRank = 3;
            continue;
          }
          return null;
        }
        return worstRank;
    }
  }
}
