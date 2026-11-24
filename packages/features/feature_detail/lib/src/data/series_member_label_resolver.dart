import 'package:engine_scraping/engine_scraping.dart';

/// 系列成员形态筛选维度（对应三端系列切换器内的胶囊筛选条）。
enum SeriesWorkMediaFilter {
  /// 全部形态。
  all('全部'),

  /// 连续剧集 / 番剧（TV）。
  tv('TV'),

  /// 剧场版 / 电影（Movie）。
  movie('剧场版'),

  /// OVA / OAD / 特别篇。
  ova('OVA');

  const SeriesWorkMediaFilter(this.label);

  /// 筛选胶囊展示文案。
  final String label;
}

/// 同系列作品形态识别、胶囊摘要生成与筛选排序工具（纯逻辑、零 Riverpod）。
abstract final class SeriesMemberLabelResolver {
  static final RegExp _ovaTokenPattern = RegExp(
    r'(^|[\s\-_·:：()\[\]【】])(ova|oad|ona)($|[\s\-_·:：()\[\]【】0-9])',
    caseSensitive: false,
  );
  static final RegExp _ovaCjkPattern = RegExp(r'特别篇|番外篇|外传|短篇');
  static final RegExp _movieTitlePattern = RegExp(
    r'剧场版|劇場版|\bthe\s+movie\b|\bmovie\b',
    caseSensitive: false,
  );
  static final RegExp _genericSeasonPattern = RegExp(r'^第\s*\d+\s*季$');

  /// 识别单个系列成员的规范媒体形态（用于筛选与 2:3 卡片角标）。
  static SeriesWorkMediaFilter classifyMember(Work work) {
    final seriesLabel = (work.seriesLabel ?? '').trim();
    final combinedTitles = '${work.title} ${work.originalTitle ?? ''}';

    if (_movieTitlePattern.hasMatch(seriesLabel)) {
      return SeriesWorkMediaFilter.movie;
    }
    if (_ovaTokenPattern.hasMatch(seriesLabel) ||
        _ovaCjkPattern.hasMatch(seriesLabel)) {
      return SeriesWorkMediaFilter.ova;
    }
    if (_ovaTokenPattern.hasMatch(combinedTitles) ||
        _ovaCjkPattern.hasMatch(combinedTitles)) {
      return SeriesWorkMediaFilter.ova;
    }
    if (work.tmdbMediaType == TmdbMediaType.movie ||
        _movieTitlePattern.hasMatch(combinedTitles)) {
      return SeriesWorkMediaFilter.movie;
    }
    return SeriesWorkMediaFilter.tv;
  }

  /// 返回形态短标签（`TV` / `剧场版` / `OVA`）。
  static String mediaKindBadge(Work work) => classifyMember(work).label;

  /// 判断系列是否属于包含多形态或异构独立条目的大系列（禁止强加无意义 `第 1 季 · `）。
  static bool isHeterogeneousSeries(List<Work> members) {
    if (members.length <= 1) return false;
    final kinds = <SeriesWorkMediaFilter>{
      for (final m in members) classifyMember(m),
    };
    if (kinds.length > 1 ||
        kinds.contains(SeriesWorkMediaFilter.ova) ||
        kinds.contains(SeriesWorkMediaFilter.movie)) {
      return true;
    }
    final distinctTmdbIds = <int>{
      for (final m in members)
        if (m.tmdbId != null && m.tmdbId! > 0) m.tmdbId!,
    };
    return distinctTmdbIds.length >= 2;
  }

  /// 生成系列成员的规范标签，杜绝对 OVA/剧场版或异构大系列强加无意义的 `第 1 季` 前缀。
  static String resolveMemberLabel(
    Work work, {
    required List<Work> members,
    SeriesGroup? seriesGroup,
    int? fallbackOrder,
  }) {
    final kind = classifyMember(work);
    final rawCustom = (work.seriesLabel ?? '').trim();

    if (kind == SeriesWorkMediaFilter.ova) {
      if (rawCustom.isNotEmpty && !_genericSeasonPattern.hasMatch(rawCustom)) {
        return rawCustom;
      }
      return 'OVA';
    }
    if (kind == SeriesWorkMediaFilter.movie) {
      if (rawCustom.isNotEmpty && !_genericSeasonPattern.hasMatch(rawCustom)) {
        return rawCustom;
      }
      return '剧场版';
    }
    if (isHeterogeneousSeries(members)) {
      if (rawCustom.isNotEmpty && !_genericSeasonPattern.hasMatch(rawCustom)) {
        return rawCustom;
      }
      final year = work.year;
      return year != null && year > 0 ? '$year · TV' : 'TV';
    }

    if (rawCustom.isNotEmpty) return rawCustom;
    final formatted = SeriesSeasonFormatter.formatMemberLabel(
      work,
      members,
      seriesGroup: seriesGroup,
      fallbackOrder: fallbackOrder,
    ).trim();
    if (formatted.isEmpty ||
        (_genericSeasonPattern.hasMatch(formatted) &&
            isHeterogeneousSeries(members))) {
      return mediaKindBadge(work);
    }
    return formatted;
  }

  /// 生成详情页主操作行「系列胶囊」入口简洁摘要（如 `高达系列 · 26 部` / `系列 26部`）。
  ///
  /// 严禁强加无意义 `第 1 季 · ` 前缀，亦严禁重复或截断超长当前作品全名。
  static String resolveCapsuleSummary({
    required List<Work> members,
    required Work activeWork,
    SeriesGroup? seriesGroup,
    bool compact = false,
  }) {
    final total = members.isEmpty ? 1 : members.length;
    final cleanGroupTitle = _resolveConciseSeriesTitle(
      seriesGroup: seriesGroup,
      activeWork: activeWork,
    );

    if (cleanGroupTitle == null) {
      return compact ? '系列 $total部' : '系列 · $total 部';
    }
    final runeLen = cleanGroupTitle.runes.length;
    if (compact && runeLen > 8) {
      return '系列 $total部';
    }
    return compact && !cleanGroupTitle.endsWith('系列')
        ? '$cleanGroupTitle $total部'
        : '$cleanGroupTitle · $total 部';
  }

  /// 按形态筛选与实时搜索关键词过滤并排序系列成员列表。
  static List<Work> filterMembers({
    required List<Work> members,
    SeriesWorkMediaFilter mediaFilter = SeriesWorkMediaFilter.all,
    String query = '',
  }) {
    final sorted = SeriesSeasonFormatter.sortSeriesMembers(members);
    final normalizedQuery = query.trim().toLowerCase();

    return <Work>[
      for (final member in sorted)
        if (_matchesFilter(member, mediaFilter) &&
            _matchesQuery(member, normalizedQuery))
          member,
    ];
  }

  /// 统计各个形态筛选项下的作品数量。
  static Map<SeriesWorkMediaFilter, int> countByFilter(List<Work> members) {
    final counts = <SeriesWorkMediaFilter, int>{
      SeriesWorkMediaFilter.all: members.length,
      SeriesWorkMediaFilter.tv: 0,
      SeriesWorkMediaFilter.movie: 0,
      SeriesWorkMediaFilter.ova: 0,
    };
    for (final m in members) {
      final kind = classifyMember(m);
      counts[kind] = (counts[kind] ?? 0) + 1;
    }
    return counts;
  }

  static bool _matchesFilter(Work member, SeriesWorkMediaFilter filter) {
    if (filter == SeriesWorkMediaFilter.all) return true;
    return classifyMember(member) == filter;
  }

  static bool _matchesQuery(Work member, String normalizedQuery) {
    if (normalizedQuery.isEmpty) return true;
    final haystack = [
      member.title,
      member.originalTitle ?? '',
      member.seriesLabel ?? '',
      if (member.year != null) '${member.year}',
      mediaKindBadge(member),
    ].join('\n').toLowerCase();
    return haystack.contains(normalizedQuery);
  }

  static String? _resolveConciseSeriesTitle({
    required SeriesGroup? seriesGroup,
    required Work activeWork,
  }) {
    final rawGroup = (seriesGroup?.title ?? '').trim();
    if (rawGroup.isEmpty) return null;

    final activeTitle = activeWork.title.trim();
    final runes = rawGroup.runes.length;
    if (rawGroup == activeTitle && runes > 10 && !rawGroup.endsWith('系列')) {
      return null;
    }
    if (runes > 14) {
      return null;
    }
    return rawGroup;
  }
}
