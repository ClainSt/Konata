import 'directory_analyzer.dart';

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

  String get key => '$type:$id';

  factory MatchCandidate.fromJson(String provider, Map<String, dynamic> json) =>
      MatchCandidate(
        provider: provider,
        id: (json['id'] as num).toInt(),
        type: '${json['type'] ?? (provider == 'tmdb' ? 'tv' : 'anime')}',
        title: '${json['title'] ?? ''}',
        year: (json['year'] as num?)?.toInt(),
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
              )
            else if (row is Map)
              SeasonInfo(
                (row['season'] as num).toInt(),
                (row['count'] as num? ?? 0).toInt(),
                (row['year'] as num?)?.toInt(),
              ),
        ],
      );
}

class SeasonInfo {
  const SeasonInfo(this.number, this.count, this.year);
  final int number, count;
  final int? year;
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
  final List<String> reasons = [];
  void add(double value, String reason) {
    if (value == 0) return;
    score += value;
    reasons.add('${value > 0 ? '+' : ''}${value.round()} $reason');
  }
}

class MatchResult {
  const MatchResult(this.tier, this.ranking);
  final MatchTier tier;
  final List<ScoredCandidate> ranking;
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

/// Deterministic multi-signal scorer. All weights live here so tuning is one
/// place and one benchmark (test/work_matcher_benchmark_test.dart).
abstract final class WorkMatcher {
  static const _highScore = 70.0, _mediumScore = 50.0;
  static const _highMargin = 15.0, _mediumMargin = 8.0;

  static final _movieWord = RegExp(
    r'剧场版|劇場版|映画|gekijou?ban|movie|film',
    caseSensitive: false,
  );

  static MatchResult bangumi(
    DirectoryInventory inventory,
    List<MatchCandidate> candidates,
  ) {
    if (inventory.shape == WorkShape.empty) return MatchResult.empty;
    final ranking = <ScoredCandidate>[];
    for (final candidate in candidates) {
      final scored = ScoredCandidate(candidate);
      if (inventory.bangumiId != null) {
        scored.add(inventory.bangumiId == candidate.id ? 60 : -60, 'marker');
      }
      scored.add(45 * _title(inventory, candidate), 'title');
      _year(scored, inventory.year, candidate.year);
      final names = [candidate.title, ...candidate.aliases];
      if (inventory.folderMovieMarker && !names.any(_movieWord.hasMatch)) {
        scored.add(-30, 'folder says movie');
      }
      if (inventory.shape == WorkShape.anthology) {
        scored.add(-40, 'anthology');
      }
      ranking.add(scored);
    }
    // Bangumi has no type/episode data here: an exact title is the evidence.
    return _decide(ranking, high: 45, medium: 36);
  }

  static MatchResult tmdb(
    DirectoryInventory inventory,
    List<MatchCandidate> candidates, {
    MatchResult? bangumi,
  }) {
    if (inventory.shape == WorkShape.empty) return MatchResult.empty;
    final linked = bangumi?.candidate;
    final year = inventory.year ?? linked?.year;
    // A year borrowed from Bangumi can differ for OVA/TV editions: softer.
    final borrowed = inventory.year == null;
    final ranking = <ScoredCandidate>[];
    for (final candidate in candidates) {
      final scored = ScoredCandidate(candidate);
      if (inventory.tmdbId != null) {
        if (inventory.tmdbId == candidate.id) {
          scored.add(30, 'marker');
          if (inventory.tmdbType != null &&
              inventory.tmdbType != candidate.type) {
            scored.add(-80, 'marker type');
          }
        } else {
          scored.add(-30, 'other than marker');
        }
      }
      var titleSim = _title(inventory, candidate);
      if (titleSim < 0.85 &&
          bangumi?.tier == MatchTier.high &&
          linked != null) {
        final bridged = _bridgedTitle(linked, candidate) * 0.85;
        if (bridged > titleSim) titleSim = bridged;
      }
      scored.add(45 * titleSim, 'title');
      if (candidate.type == 'movie') {
        _movie(scored, inventory);
        _year(scored, year, candidate.year, borrowed: borrowed);
      } else {
        _tv(scored, inventory, year, borrowed);
      }
      if (linked != null) _linked(scored, linked);
      ranking.add(scored);
    }
    return _decide(ranking);
  }

  static void _movie(ScoredCandidate scored, DirectoryInventory inventory) {
    switch (inventory.shape) {
      case WorkShape.feature:
        scored.add(inventory.featureCount == 1 ? 15 : 5, 'feature');
        if (inventory.folderMovieMarker) {
          scored.add(5, 'folder says movie');
        } else if (inventory.fileMovieMarker) {
          scored.add(5, 'file says movie');
        }
      case WorkShape.series:
        // A short explicit run (IGLOO S03E01-03) can still be one film entry.
        scored.add(inventory.episodeCount <= 3 ? -5 : -35, 'series vs movie');
      case WorkShape.anthology:
        scored.add(-80, 'anthology');
      case WorkShape.empty:
        break;
    }
  }

  static void _tv(
    ScoredCandidate scored,
    DirectoryInventory inventory,
    int? year,
    bool borrowed,
  ) {
    final candidate = scored.candidate;
    final regular = candidate.seasons.where((s) => s.number > 0).toList();
    final specials = candidate.seasons.where((s) => s.number == 0).toList();
    final episodes = inventory.episodeCount;
    final local = inventory.shape == WorkShape.series
        ? episodes
        : inventory.featureCount;
    int? yearOf = candidate.year;

    if (inventory.shape == WorkShape.anthology) {
      scored.add(-40, 'anthology');
    }
    if (inventory.shape == WorkShape.series) {
      final season = _season(inventory, regular, year);
      if (season != null) {
        scored.season = season.number;
        yearOf = season.year ?? yearOf;
        scored.add(season.count == episodes ? 15 : 8, 'season count');
      } else if (regular.isNotEmpty &&
          regular.fold<int>(0, (n, s) => n + s.count) == episodes) {
        scored.add(15, 'all seasons count');
      } else if (regular.isEmpty) {
        scored.add(episodes >= 10 ? 10 : 5, 'series');
      } else if (regular.any((s) => s.count >= episodes) || episodes > 30) {
        scored.add(5, 'series');
      }
    } else if (inventory.shape == WorkShape.feature) {
      // A special / OVA set can live in season 0 or a tiny season.
      final small = [...specials, ...regular.where((s) => s.count <= 3)].where((
        s,
      ) {
        final diff = _yearDiff(year, s.year);
        return s.count >= local && (diff <= 1 || diff == 99);
      });
      if (small.isNotEmpty) {
        final match = small.first;
        scored.season = match.number;
        yearOf = match.year ?? yearOf;
        scored.add(
          regular.isEmpty && specials.isEmpty ? 0 : 10,
          'special/short season',
        );
      } else if (inventory.folderMovieMarker || inventory.fileMovieMarker) {
        scored.add(-35, 'movie vs tv');
      } else if (candidate.seasons.isNotEmpty) {
        scored.add(-20, 'feature vs tv');
      } else {
        scored.add(-10, 'feature vs tv');
      }
    }
    _year(scored, year, yearOf, borrowed: borrowed);
  }

  static SeasonInfo? _season(
    DirectoryInventory inventory,
    List<SeasonInfo> regular,
    int? year,
  ) {
    if (regular.isEmpty) return null;
    final explicit =
        inventory.season ??
        (inventory.main.map((i) => i.season).whereType<int>().toSet().length ==
                1
            ? inventory.main.map((i) => i.season).whereType<int>().first
            : null);
    final episodes = inventory.episodeCount;
    SeasonInfo? best;
    var bestScore = 0, tie = false;
    for (final season in regular) {
      var score = 0;
      if (explicit != null) score += season.number == explicit ? 6 : -6;
      if (season.count == episodes) {
        score += 3;
      } else if ((season.count - episodes).abs() <= 1) {
        score += 2;
      }
      final diff = _yearDiff(year, season.year);
      if (diff == 0) score += 2;
      if (diff >= 2 && diff < 99) score -= 2;
      if (score > bestScore) {
        best = season;
        bestScore = score;
        tie = false;
      } else if (score == bestScore && score > 0) {
        tie = true;
      }
    }
    return tie || bestScore < 2 ? null : best;
  }

  static void _year(
    ScoredCandidate scored,
    int? local,
    int? remote, {
    bool borrowed = false,
  }) {
    final diff = _yearDiff(local, remote);
    if (diff == 99) return;
    scored.add(switch (diff) {
      0 => 15,
      1 => 4,
      2 => -5,
      3 || 4 when borrowed => -10,
      _ => -25,
    }, borrowed ? 'year (via Bangumi)' : 'year');
  }

  static int _yearDiff(int? a, int? b) =>
      a == null || b == null ? 99 : (a - b).abs();

  /// Cross-provider agreement: TMDB lists the Bangumi original name.
  static void _linked(ScoredCandidate scored, MatchCandidate bangumi) {
    final remote = {
      for (final name in [scored.candidate.title, ...scored.candidate.aliases])
        DirectoryAnalyzer.normalize(name),
    }..remove('');
    final original = bangumi.aliases.isEmpty
        ? ''
        : DirectoryAnalyzer.normalize(bangumi.aliases.first);
    var bonus = original.isNotEmpty && remote.contains(original) ? 12.0 : 0.0;
    var others = 0;
    for (final name in {bangumi.title, ...bangumi.aliases.skip(1)}) {
      final key = DirectoryAnalyzer.normalize(name);
      if (key.isNotEmpty && key != original && remote.contains(key)) others++;
    }
    bonus += (others * 5).clamp(0, 10).toDouble();
    scored.add(bonus, 'bangumi agrees');
  }

  /// Best similarity between local titles and remote names, 0..1.
  /// Folder titles are trusted more than filename titles.
  static double _title(DirectoryInventory inventory, MatchCandidate candidate) {
    final remote = {
      for (final name in [candidate.title, ...candidate.aliases])
        DirectoryAnalyzer.normalize(name),
    }..removeWhere((name) => name.isEmpty);
    var best = 0.0;
    void check(Iterable<String> hints, double weight) {
      for (final hint in hints) {
        final local = DirectoryAnalyzer.normalize(hint);
        if (local.isEmpty) continue;
        for (final name in remote) {
          final value = similarity(local, name) * weight;
          if (value > best) best = value;
        }
      }
    }

    check(inventory.titleHints, 1);
    check(inventory.fileHints, 0.92);
    return best;
  }

  static double _bridgedTitle(
    MatchCandidate bangumi,
    MatchCandidate tmdbCandidate,
  ) {
    final remote = {
      for (final name in [tmdbCandidate.title, ...tmdbCandidate.aliases])
        DirectoryAnalyzer.normalize(name),
    }..removeWhere((name) => name.isEmpty);
    final trusted = {
      DirectoryAnalyzer.normalize(bangumi.title),
      if (bangumi.aliases.isNotEmpty)
        DirectoryAnalyzer.normalize(bangumi.aliases.first),
    }..removeWhere((name) => name.isEmpty);
    var best = 0.0;
    for (final b in trusted) {
      for (final r in remote) {
        final sim = similarity(b, r);
        if (sim > best) best = sim;
      }
    }
    return best;
  }

  /// Exact 1.0; containment scales with length ratio; otherwise bigram Dice.
  static double similarity(String a, String b) {
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

  static MatchResult _decide(
    List<ScoredCandidate> ranking, {
    double high = _highScore,
    double medium = _mediumScore,
  }) {
    if (ranking.isEmpty) return MatchResult.empty;
    ranking.sort((a, b) => b.score.compareTo(a.score));
    final top = ranking.first.score;
    final margin = ranking.length < 2
        ? double.infinity
        : top - ranking[1].score;
    final tier = top >= high && margin >= _highMargin
        ? MatchTier.high
        : top >= medium && margin >= _mediumMargin
        ? MatchTier.medium
        : MatchTier.none;
    return MatchResult(tier, ranking);
  }
}
