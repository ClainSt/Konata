part of 'work_matcher.dart';

/// 候选匹配决策等级。
enum MatchLevel {
  /// 高置信度，可安全自动绑定。
  autoBind,

  /// 存在歧义或中等置信度，进入待复核并保存 Top-5 候选。
  reviewRequired,

  /// 未找到有效匹配候选。
  unmatched,
}

/// 单个候选的打分明细。
class ScoredTmdbCandidate {
  /// 创建候选打分明细。
  const ScoredTmdbCandidate({
    required this.detail,
    required this.score,
    required this.reasons,
    this.matchedSeason,
  });

  /// TMDB 候选详情。
  final TmdbWorkDetail detail;

  /// 综合得分。
  final double score;

  /// 得分与扣分原因说明码列表。
  final List<String> reasons;

  /// 该候选命中的季号（仅 TV 多季作品可能非空）。
  final int? matchedSeason;
}

/// 最终匹配决策结果（强类型输出）。
class MatchDecision {
  /// 创建决策结果。
  const MatchDecision({
    required this.level,
    this.best,
    required this.topCandidates,
    this.bestBangumi,
    this.topBangumiCandidates = const [],
    this.matchedSeason,
    this.primaryReason = '',
    this.reviewReason,
  });

  /// 最终匹配等级。
  final MatchLevel level;

  /// 排名第一的最佳 TMDB 候选。
  final ScoredTmdbCandidate? best;

  /// 按得分降序排列的 Top-5 TMDB 候选列表。
  final List<ScoredTmdbCandidate> topCandidates;

  /// 排名第一的最佳 Bangumi 候选。
  final ScoredBangumiCandidate? bestBangumi;

  /// Bangumi Top 候选列表。
  final List<ScoredBangumiCandidate> topBangumiCandidates;

  /// 最佳候选绑定的目标季号（由 WorkMatcher 季级消歧得出）。
  final int? matchedSeason;

  /// 主要决策/待复核原因码。
  final String primaryReason;

  /// 供 UI 与数据库直接展示的简体中文待复核说明。
  final String? reviewReason;
}

/// 待打分评估的单条刮削源候选模型，由在线搜索结果、离线基准索引或历史候选构建；
/// 打分器纯内存计算，绝不执行任何文件或网络 I/O。
class MatchCandidate {
  const MatchCandidate({
    required this.provider,
    required this.id,
    required this.type,
    required this.title,
    this.year,
    this.aliases = const [],
    this.seasons = const [],
    this.airDate,
    this.isSpecialFormat = false,
    this.genreIds = const [],
    this.firstEpisodeSort,
    this.voteCount,
    this.originalTitle,
  });

  static final _genericTmdbSeasonName = RegExp(
    r'^(?:season\s*\d+|series\s*\d+|specials?|第\s*[0-9一二三四五六七八九十百]+\s*[季期部]|特别篇|特別編|特典)$',
    caseSensitive: false,
  );
  static final _releaseYear = RegExp(r'(19|20)\d{2}');

  /// 从 TMDB 详情读取打分所需的字段，补齐原名与季别名。
  factory MatchCandidate.fromTmdb(TmdbWorkDetail detail) {
    final aliases = <String>[...detail.aliases];
    final seen = <String>{
      detail.title.trim().toLowerCase(),
      for (final a in aliases) a.trim().toLowerCase(),
    };
    void addAlias(String value) {
      final t = value.trim();
      if (t.isEmpty) return;
      if (seen.add(t.toLowerCase())) aliases.add(t);
    }

    if (detail.originalTitle != null) {
      addAlias(detail.originalTitle!);
    }

    final seasons = <SeasonInfo>[];
    if (detail.mediaType == TmdbMediaType.tv) {
      for (final s in detail.seasons) {
        final sName = s.name.trim();
        seasons.add(
          SeasonInfo(
            s.seasonNumber,
            s.episodeCount,
            int.tryParse(
              _releaseYear.firstMatch(s.airDate ?? '')?.group(0) ?? '',
            ),
            name: sName.isNotEmpty ? sName : null,
            airDate: s.airDate,
          ),
        );
        if (sName.isNotEmpty && !_genericTmdbSeasonName.hasMatch(sName)) {
          addAlias(sName);
          if (detail.title.isNotEmpty && !sName.contains(detail.title)) {
            addAlias('${detail.title} $sName');
          }
        }
      }
    }

    return MatchCandidate(
      provider: 'tmdb',
      id: detail.tmdbId,
      type: detail.mediaType.name,
      title: detail.title,
      year: detail.year,
      aliases: aliases,
      seasons: seasons,
      genreIds: detail.genreIds,
      voteCount: detail.voteCount,
      originalTitle: detail.originalTitle,
    );
  }

  /// 刮削数据来源标识：`tmdb` 或 `bangumi`。
  final String provider;
  final int id;

  /// 条目介质类型（TMDB 为 `tv`/`movie`，Bangumi 为 `anime`）。
  final String type;
  final String title;
  final int? year;

  /// 对 Bangumi 条目而言，别名列表首项始终为其原始日文片名。
  final List<String> aliases;
  final List<SeasonInfo> seasons;
  final String? airDate;
  final bool isSpecialFormat;
  final List<int> genreIds;
  final double? firstEpisodeSort;

  /// TMDB 评分人数（未知时为空），用于识别新建的低质量重复条目。
  final int? voteCount;

  /// TMDB 原始语言标题（与 [title] 一起构成识别重复条目的正式名称）。
  final String? originalTitle;

  String get key => '$type:$id';

  factory MatchCandidate.fromJson(
    String provider,
    Map<String, dynamic> json,
  ) => MatchCandidate(
    provider: provider,
    id: (json['id'] as num).toInt(),
    type: '${json['type'] ?? (provider == 'tmdb' ? 'tv' : 'anime')}',
    title: '${json['title'] ?? ''}',
    year: (json['year'] as num?)?.toInt(),
    airDate: (json['air_date'] ?? json['airDate'] ?? json['date'])?.toString(),
    isSpecialFormat:
        json['is_special_format'] == true || json['isSpecialFormat'] == true,
    aliases: [
      for (final alias in json['aliases'] as List? ?? const [])
        if (alias is String && alias.trim().isNotEmpty) alias,
    ],
    seasons: [
      for (final row in json['seasons'] as List? ?? const [])
        if (row is List && row.length >= 2)
          SeasonInfo(
            (row[0] as num).toInt(),
            (row[1] as num).toInt(),
            (row.length > 2 ? row[2] as num? : null)?.toInt(),
            name: row.length > 3 && row[3] is String ? row[3] as String : null,
            airDate: row.length > 4 && row[4] is String
                ? row[4] as String
                : null,
          )
        else if (row is Map)
          SeasonInfo(
            (row['season'] as num).toInt(),
            (row['count'] as num? ?? 0).toInt(),
            (row['year'] as num?)?.toInt(),
            name: row['name']?.toString(),
            airDate: (row['air_date'] ?? row['airDate'])?.toString(),
          ),
    ],
  );
}

class SeasonInfo {
  const SeasonInfo(
    this.number,
    this.count,
    this.year, {
    this.name,
    this.airDate,
  });
  final int number, count;
  final int? year;
  final String? name;
  final String? airDate;
}

enum MatchTier {
  /// 高置信度，直接自动绑定该条目。
  high,

  /// 采用榜首候选展示于海报墙，并保留待人工复核标记。
  medium,

  /// 保持未绑定状态，沿用清洗后的本地作品名称。
  none,
}

class ScoredCandidate {
  ScoredCandidate(this.candidate);
  final MatchCandidate candidate;
  double score = 0;
  int? season;
  bool cumulativeOffsetMatched = false;
  bool seasonNameMatched = false;
  bool tmdbMarkerSeasonMatched = false;
  final List<String> reasons = [];
  void add(double value, String reason) {
    if (value == 0) return;
    score += value;
    reasons.add('${value > 0 ? '+' : ''}${value.round()} $reason');
  }
}

class MatchResult {
  const MatchResult(this.tier, this.ranking, {this.siblingIds = const []});
  final MatchTier tier;
  final List<ScoredCandidate> ranking;
  final List<int> siblingIds;
  ScoredCandidate? get best =>
      tier == MatchTier.none || ranking.isEmpty ? null : ranking.first;
  MatchCandidate? get candidate => best?.candidate;
  int? get season => best?.season;
  static const empty = MatchResult(MatchTier.none, []);

  @override
  String toString() => ranking.isEmpty
      ? 'none'
      : '$tier ${[for (final s in ranking.take(3)) '${s.candidate.key}=${s.score.round()}${s.season == null ? '' : '/S${s.season}'} ${s.reasons}'].join(' | ')}';
}

const _latinStopwords = <String>{
  'the',
  'a',
  'an',
  'of',
  'in',
  'on',
  'at',
  'to',
  'no',
  'ni',
  'wa',
  'ga',
  'wo',
  'de',
  'and',
  'or',
  'for',
  'vs',
  'part',
  'season',
  'vol',
  'hen',
  'arc',
  'episode',
  'ep',
  'i',
  'ii',
  'iii',
  'iv',
  'v',
};

const _romajiArcBridges =
    <(String romaji, String queryArc, List<String> cjkNorms)>[
      ('miraihen', '未来篇', ['未来篇', '未来編']),
      ('zetsubouhen', '绝望篇', ['绝望篇', '絶望編', '絕望篇']),
      ('zetsubohen', '绝望篇', ['绝望篇', '絶望編', '絕望篇']),
      ('kibouhen', '希望篇', ['希望篇', '希望編']),
      ('kibohen', '希望篇', ['希望篇', '希望編']),
      ('kakohen', '过去篇', ['过去篇', '過去編']),
      ('gendaihen', '现代篇', ['现代篇', '現代編']),
      ('shinsouhen', '真相篇', ['真相篇', '真相編']),
      ('kanketsuhen', '完结篇', ['完结篇', '完結編']),
      ('kakuseihen', '觉醒篇', ['觉醒篇', '覚醒編']),
      ('hangekihen', '反击篇', ['反击篇', '反撃編']),
      ('shidouhen', '始动篇', ['始动篇', '始動編']),
      ('tsuiokuhen', '追忆篇', ['追忆篇', '追憶編']),
      ('saishuuhen', '最终篇', ['最终篇', '最終編']),
      ('saishuhen', '最终篇', ['最终篇', '最終編']),
      ('zenpen', '前篇', ['前篇', '前編']),
      ('kouhen', '后篇', ['后篇', '後編', '後篇']),
      ('kohen', '后篇', ['后篇', '後編', '後篇']),
    ];

const _precomputedArcBridges = <(String romaji, List<String> canonCjks)>[
  ('miraihen', ['未来篇']),
  ('zetsubouhen', ['绝望篇']),
  ('zetsubohen', ['绝望篇']),
  ('kibouhen', ['希望篇']),
  ('kibohen', ['希望篇']),
  ('kakohen', ['过去篇', '過去篇']),
  ('gendaihen', ['现代篇', '現代篇']),
  ('shinsouhen', ['真相篇']),
  ('kanketsuhen', ['完结篇', '完結篇']),
  ('kakuseihen', ['觉醒篇']),
  ('hangekihen', ['反击篇']),
  ('shidouhen', ['始动篇']),
  ('tsuiokuhen', ['追忆篇']),
  ('saishuuhen', ['最终篇']),
  ('saishuhen', ['最终篇']),
  ('zenpen', ['前篇']),
  ('kouhen', ['后篇']),
  ('kohen', ['后篇']),
];

const _cjkCanonCodeMap = <int, int>{
  0x7DE8: 0x7BC7, // 編 -> 篇
  0x7D76: 0x7EDD, // 絶 -> 绝
  0x7D55: 0x7EDD, // 絕 -> 绝
  0x5B78: 0x5B66, // 學 -> 学
  0x5712: 0x56ED, // 園 -> 园
  0x528D: 0x5251, // 劍 -> 剑
  0x6AFB: 0x6A31, // 櫻 -> 樱
  0x9F8D: 0x9F99, // 龍 -> 龙
  0x6230: 0x6218, // 戰 -> 战
  0x570B: 0x56FD, // 國 -> 国
  0x5287: 0x5267, // 劇 -> 剧
  0x8A71: 0x8BDD, // 話 -> 话
  0x5F48: 0x5F39, // 彈 -> 弹
  0x6C23: 0x6C14, // 氣 -> 气
  0x60E1: 0x6076, // 惡 -> 恶
  0x7D42: 0x7EC8, // 終 -> 终
  0x908A: 0x8FB9, // 邊 -> 边
  0x5BE6: 0x5B9E, // 實 -> 实
  0x8207: 0x4E0E, // 與 -> 与
  0x89BA: 0x89C9, // 覺 -> 觉
  0x64CA: 0x51FB, // 擊 -> 击
  0x52D5: 0x52A8, // 動 -> 动
  0x61B6: 0x5FC6, // 憶 -> 忆
  0x5F8C: 0x540E, // 後 -> 后
  0x842C: 0x4E07, // 萬 -> 万
  0x9AD4: 0x4F53, // 體 -> 体
  0x865F: 0x53F7, // 號 -> 号
};

DateTime? _parseFullDate(String? raw) {
  if (raw == null) return null;
  final m = RegExp(
    r'((?:19|20)\d{2})\D+(\d{1,2})\D+(\d{1,2})',
  ).firstMatch(raw.trim());
  if (m == null) return null;
  final y = int.tryParse(m.group(1)!);
  final mo = int.tryParse(m.group(2)!);
  final d = int.tryParse(m.group(3)!);
  if (y == null || mo == null || d == null) return null;
  if (mo < 1 || mo > 12 || d < 1 || d > 31) return null;
  return DateTime.utc(y, mo, d);
}

double _wmSimilarity(String a, String b) {
  if (a == b) return 1;
  final shorter = a.length <= b.length ? a : b;
  final longer = identical(shorter, a) ? b : a;
  if (shorter.length >= 3 && longer.contains(shorter)) {
    return 0.55 + 0.4 * shorter.length / longer.length;
  }
  if (shorter.length < 2) return 0;
  final grams = <int, int>{};
  for (var i = 0; i < a.length - 1; i++) {
    final gram = (a.codeUnitAt(i) << 16) | a.codeUnitAt(i + 1);
    grams[gram] = (grams[gram] ?? 0) + 1;
  }
  var shared = 0;
  for (var i = 0; i < b.length - 1; i++) {
    final gram = (b.codeUnitAt(i) << 16) | b.codeUnitAt(i + 1);
    final left = grams[gram];
    if (left != null && left > 0) {
      shared++;
      grams[gram] = left - 1;
    }
  }
  final dice = 2 * shared / (a.length + b.length - 2) * 0.9;
  // 较长的本地标题几乎完整落入更长官方名称且包含独立分隔词元时的补充匹配分支
  // （如 `キノの旅 病気の国` 与 `キノの旅 the Beautiful World 病気の国`），即使 Dice 被稀释仍保持有效召回。
  final coverage = shorter.length >= 6
      ? shared / (shorter.length - 1) * 0.8
      : 0.0;
  return dice > coverage ? dice : coverage;
}
