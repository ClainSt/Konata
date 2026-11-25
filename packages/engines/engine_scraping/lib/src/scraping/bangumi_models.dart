import '../matching/work_matcher.dart';

/// Bangumi 动画条目候选元数据（严格不包含角色/声优等冗余资料）。
class BangumiSubjectCandidate {
  /// 创建 Bangumi 条目候选实例。
  const BangumiSubjectCandidate({
    required this.id,
    required this.name,
    this.nameCn = '',
    this.year,
    this.airDate,
    this.totalEpisodes,
    this.summary,
    this.posterUrl,
    this.score,
    this.aliases = const [],
    this.platform,
    this.isSpecialFormat = false,
    this.firstEpisodeSort,
  });

  /// Bangumi 条目 ID。
  final int id;

  /// 日文或原始条目名。
  final String name;

  /// 中文条目名。
  final String nameCn;

  /// 首播 / 上映 / 发售年份。
  final int? year;

  /// 完整开播或发售日期字符串 (`YYYY-MM-DD`)。
  final String? airDate;

  /// 正片集数。
  final int? totalEpisodes;

  /// 条目简介。
  final String? summary;

  /// Bangumi 官方封面 URL（如 `https://lain.bgm.tv/...`）。
  final String? posterUrl;

  /// Bangumi 条目评分（0.0 ~ 10.0）。
  final double? score;

  /// 别名与补充标题列表。
  final List<String> aliases;

  /// 平台类型（如 `TV`、`OVA`、`剧场版`）。
  final String? platform;

  /// 是否属于 OVA/OAD 特殊发行格式。
  final bool isSpecialFormat;

  /// Bangumi 正片最小连续话数 `sort`（如分割放送第 2 部分常从 `12` 开始，用于与第 1 集匹配消歧）。
  final double? firstEpisodeSort;

  /// 首选展示标题（优先简体中文名）。
  String get displayTitle => nameCn.trim().isNotEmpty ? nameCn.trim() : name.trim();

  /// 复制并补充最小正片起始话数。
  BangumiSubjectCandidate copyWith({double? firstEpisodeSort}) {
    return BangumiSubjectCandidate(
      id: id,
      name: name,
      nameCn: nameCn,
      year: year,
      airDate: airDate,
      totalEpisodes: totalEpisodes,
      summary: summary,
      posterUrl: posterUrl,
      score: score,
      aliases: aliases,
      platform: platform,
      isSpecialFormat: isSpecialFormat,
      firstEpisodeSort: firstEpisodeSort ?? this.firstEpisodeSort,
    );
  }

  /// 转换为 `WorkMatcher` 所需的统一候选结构。
  MatchCandidate toMatchCandidate() {
    final mergedAliases = <String>[];
    final seen = <String>{};
    void addAlias(String raw) {
      final clean = raw.trim();
      if (clean.isEmpty) return;
      if (seen.add(clean.toLowerCase())) {
        mergedAliases.add(clean);
      }
    }

    if (name.trim().isNotEmpty) addAlias(name);
    if (nameCn.trim().isNotEmpty) addAlias(nameCn);
    for (final a in aliases) {
      addAlias(a);
    }
    if (platform != null &&
        RegExp(
          r'剧场版|劇場版|映画|动画电影|movie|film',
          caseSensitive: false,
        ).hasMatch(platform!) &&
        displayTitle.isNotEmpty) {
      addAlias('$displayTitle 剧场版');
    }

    final effectiveIsSpecialFormat =
        isSpecialFormat ||
        (platform != null &&
            RegExp(r'^(?:ova|oad)$', caseSensitive: false)
                .hasMatch(platform!.trim()));

    return MatchCandidate(
      provider: 'bangumi',
      id: id,
      type: 'anime',
      title: displayTitle,
      year: year,
      airDate: airDate,
      isSpecialFormat: effectiveIsSpecialFormat,
      firstEpisodeSort: firstEpisodeSort,
      aliases: mergedAliases,
      seasons: totalEpisodes != null && totalEpisodes! > 0
          ? [
              SeasonInfo(
                1,
                totalEpisodes!,
                year,
                name: displayTitle,
                airDate: airDate,
              ),
            ]
          : const [],
    );
  }
}

/// Bangumi 单集条目元数据（用于正片标题回落与分部/SP 对齐）。
class BangumiEpisodeEntry {
  /// 创建 Bangumi 单集条目实例。
  const BangumiEpisodeEntry({
    required this.id,
    this.ep,
    this.sort,
    this.type = 0,
    required this.name,
    this.nameCn = '',
    this.airDate,
  });

  /// 单集 ID。
  final int id;

  /// 本季内集号（`ep`）。
  final double? ep;

  /// 连续排序集号（`sort`，跨分割放送/续季尤为关键）。
  final double? sort;

  /// 类型：`0` 正片，`1` SP。
  final int type;

  /// 原语言集标题。
  final String name;

  /// 中文集标题。
  final String nameCn;

  /// 播出日期。
  final String? airDate;

  /// 首选集标题（优先中文）。
  String get displayName => nameCn.trim().isNotEmpty ? nameCn.trim() : name.trim();
}

/// Bangumi 条目打分命中明细。
class ScoredBangumiCandidate {
  /// 创建 Bangumi 候选打分明细。
  const ScoredBangumiCandidate({
    required this.subject,
    required this.score,
    required this.reasons,
    this.siblingIds = const [],
  });

  /// Bangumi 条目实体。
  final BangumiSubjectCandidate subject;

  /// 匹配得分。
  final double score;

  /// 命中的打分说明列表。
  final List<String> reasons;

  /// 连续分期/分割放送兄弟条目 ID 列表（如上下部）。
  final List<int> siblingIds;
}

/// Bangumi 关联条目摘要（用于自动系列编组：前传 / 续集 / 剧场版 / 番外篇）。
class BangumiRelatedSubject {
  /// 创建 Bangumi 关联条目实例。
  const BangumiRelatedSubject({
    required this.id,
    required this.relation,
    this.name = '',
    this.nameCn = '',
  });

  /// 关联条目 ID。
  final int id;

  /// 关联关系类型（如 `前传`、`续集`、`剧场版`、`番外篇`、`衍生`）。
  final String relation;

  /// 原标题。
  final String name;

  /// 中文标题。
  final String nameCn;

  /// 展示标题。
  String get displayTitle => nameCn.trim().isNotEmpty ? nameCn.trim() : name.trim();
}
