part of 'work_matcher.dart';

/// One provider entry to score. Built from search results, the offline
/// index, or saved candidates; the scorer never performs I/O.
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
  });

  /// 'tmdb' or 'bangumi'.
  final String provider;
  final int id;

  /// TMDB: 'tv' / 'movie'. Bangumi: 'anime'.
  final String type;
  final String title;
  final int? year;

  /// For Bangumi the first alias is the original (Japanese) name.
  final List<String> aliases;
  final List<SeasonInfo> seasons;
  final String? airDate;
  final bool isSpecialFormat;

  String get key => '$type:$id';

  factory MatchCandidate.fromJson(String provider, Map<String, dynamic> json) =>
      MatchCandidate(
        provider: provider,
        id: (json['id'] as num).toInt(),
        type: '${json['type'] ?? (provider == 'tmdb' ? 'tv' : 'anime')}',
        title: '${json['title'] ?? ''}',
        year: (json['year'] as num?)?.toInt(),
        airDate: (json['air_date'] ?? json['airDate'] ?? json['date'])
            ?.toString(),
        isSpecialFormat:
            json['is_special_format'] == true ||
            json['isSpecialFormat'] == true,
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
                name: row.length > 3 && row[3] is String
                    ? row[3] as String
                    : null,
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
  /// Bind automatically.
  high,

  /// Adopt Top-1 on the poster wall, mark for optional review.
  medium,

  /// Leave unbound; keep the clean local title.
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

const _romajiArcBridges = <(String romaji, String queryArc, List<String> cjkNorms)>[
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

const _cjkCanonMap = <String, String>{
    '編': '篇',
    '絶': '绝',
    '絕': '绝',
    '學': '学',
    '園': '园',
    '劍': '剑',
    '櫻': '樱',
    '龍': '龙',
    '戰': '战',
    '國': '国',
    '劇': '剧',
    '話': '话',
    '彈': '弹',
    '氣': '气',
    '惡': '恶',
    '終': '终',
    '邊': '边',
    '實': '实',
    '與': '与',
    '覺': '觉',
    '擊': '击',
    '動': '动',
    '憶': '忆',
    '後': '后',
    '萬': '万',
    '體': '体',
    '號': '号',
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
    final grams = <String, int>{};
    for (var i = 0; i < a.length - 1; i++) {
      final gram = a.substring(i, i + 2);
      grams[gram] = (grams[gram] ?? 0) + 1;
    }
    var shared = 0;
    for (var i = 0; i < b.length - 1; i++) {
      final gram = b.substring(i, i + 2);
      final left = grams[gram] ?? 0;
      if (left > 0) {
        shared++;
        grams[gram] = left - 1;
      }
    }
    final dice = 2 * shared / (a.length + b.length - 2) * 0.9;
    // A long local title almost fully inside a longer official name with an
    // inserted subtitle ("キノの旅 病気の国" vs "キノの旅 the Beautiful World
    // 病気の国") is strong evidence even when Dice is diluted.
    final coverage = shorter.length >= 6
        ? shared / (shorter.length - 1) * 0.8
        : 0.0;
    return dice > coverage ? dice : coverage;
  }

