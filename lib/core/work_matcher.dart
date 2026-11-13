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

/// Deterministic multi-signal scorer. All weights live here so tuning is one
/// place and one benchmark (test/work_matcher_benchmark_test.dart).
abstract final class WorkMatcher {
  static const _highScore = 70.0, _mediumScore = 50.0;
  static const _highMargin = 15.0, _mediumMargin = 8.0;

  static final _movieWord = RegExp(
    r'剧场版|劇場版|映画|gekijou?ban|movie|film',
    caseSensitive: false,
  );

  static final _sequelOrSpinoffSuffix = RegExp(
    r'^(?:ii|iii|iv|2|3|4|2nd|3rd|s2|s3|season2|season3|'
    r'第[234二三四][季期部]|新章|shinshou|two|通|续|続|续篇|続編|'
    r'break|burst|try|next|plus|kai|改|z|zoo|revolution|rebellion)s?$',
    caseSensitive: false,
  );

  static final _remasterPattern = RegExp(
    r'(?:HD\s*)?(?:重制版|重製版|Remaster(?:ed)?)|リマスター',
    caseSensitive: false,
  );

  static final _genericSeasonName = RegExp(
    r'^(?:season\s*\d+|series\s*\d+|specials?|第\s*[0-9一二三四五六七八九十百]+\s*[季期部]|特别篇|特典)$',
    caseSensitive: false,
  );

  static bool _hasRemasterTag(String value) => _remasterPattern.hasMatch(value);

  static bool _hasRemasterInInventory(DirectoryInventory inventory) =>
      _hasRemasterTag(inventory.title) ||
      inventory.titleHints.any(_hasRemasterTag);

  static bool _hasRemasterInCandidate(MatchCandidate candidate) =>
      _hasRemasterTag(candidate.title) ||
      candidate.aliases.any(_hasRemasterTag);

  static String _stripRemaster(String value) => value
      .replaceAll(_remasterPattern, ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  static DateTime? _parseFullDate(String? raw) {
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

  static MatchResult bangumi(
    DirectoryInventory inventory,
    List<MatchCandidate> candidates,
  ) {
    if (inventory.shape == WorkShape.empty) return MatchResult.empty;
    final localIsRemaster = _hasRemasterInInventory(inventory);
    final ranking = <ScoredCandidate>[];
    for (final candidate in candidates) {
      final scored = ScoredCandidate(candidate);
      if (inventory.bangumiId != null) {
        scored.add(inventory.bangumiId == candidate.id ? 60 : -60, 'marker');
      }
      final titleSim = _title(inventory, candidate);
      scored.add(45 * titleSim, 'title');
      if (localIsRemaster && _hasRemasterInCandidate(candidate)) {
        scored.add(10, 'remaster match');
      }
      if (titleSim < 0.9) {
        scored.add(
          _subtitleConflictPenalty(inventory, candidate),
          'conflicting subtitle',
        );
      }
      _year(scored, inventory.year, candidate.year);
      if (inventory.shape == WorkShape.series &&
          candidate.seasons.isNotEmpty &&
          inventory.episodeCount > 0) {
        final remoteEps = candidate.seasons.first.count;
        final localEps = inventory.episodeCount;
        if (remoteEps > 0) {
          if (remoteEps == localEps) {
            scored.add(8, 'episode count');
          } else if ((remoteEps - localEps).abs() == 1 && localEps >= 6) {
            scored.add(4, 'episode count ~');
          } else if (localEps >= 6 &&
              (remoteEps - localEps).abs() >= 8 &&
              remoteEps != localEps * 2) {
            scored.add(-8, 'episode count mismatch');
          } else if (localEps <= 4 &&
              remoteEps >= 11 &&
              _hasConflictingCjkTitle(inventory.title, candidate.title)) {
            scored.add(-18, 'short ova vs long tv');
          }
        }
      } else if (inventory.shape == WorkShape.feature &&
          candidate.seasons.isNotEmpty &&
          inventory.featureCount > 0) {
        final remoteEps = candidate.seasons.first.count;
        if (remoteEps > 0) {
          if (remoteEps == inventory.featureCount) {
            scored.add(6, 'feature episode count');
          } else if (inventory.featureCount == 1 && remoteEps == 2) {
            scored.add(4, 'ova pair count');
          } else if (inventory.featureCount == 1 &&
              remoteEps >= 11 &&
              (inventory.folderMovieMarker ||
                  inventory.fileMovieMarker ||
                  _hasConflictingCjkTitle(inventory.title, candidate.title))) {
            scored.add(-12, 'feature vs long tv');
          }
        }
      }
      final names = [candidate.title, ...candidate.aliases];
      if (inventory.season != null &&
          inventory.season! > 1 &&
          titleSim < 0.92 &&
          !_candidateHasSequelSignal(inventory, names)) {
        scored.add(-16, 'base entry vs sequel');
      }
      if (inventory.folderMovieMarker && !names.any(_movieWord.hasMatch)) {
        scored.add(-30, 'folder says movie');
      }
      if (inventory.shape == WorkShape.anthology) {
        scored.add(-40, 'anthology');
      }
      ranking.add(scored);
    }
    // Bangumi has no type/season tree here; title + optional year/eps decide.
    final baseDecision = _decide(ranking, high: 45, medium: 36);
    if (baseDecision.tier != MatchTier.high) {
      final multiPart = _resolveBangumiMultiPartTie(inventory, ranking);
      if (multiPart != null) return multiPart;
      if (baseDecision.tier == MatchTier.medium &&
          inventory.year == null &&
          ranking.isNotEmpty) {
        final top = ranking.first;
        final margin = ranking.length < 2
            ? double.infinity
            : top.score - ranking[1].score;
        if (top.score >= 44.5 &&
            margin >= 12.0 &&
            DirectoryAnalyzer.normalize(inventory.title) ==
                DirectoryAnalyzer.normalize(top.candidate.title)) {
          return MatchResult(MatchTier.high, ranking);
        }
      }
    }
    return baseDecision;
  }

  static MatchResult tmdb(
    DirectoryInventory inventory,
    List<MatchCandidate> candidates, {
    MatchResult? bangumi,
    ({String key, int? season})? mappedTarget,
    bool ignoreTmdbMarker = false,
  }) {
    if (inventory.shape == WorkShape.empty) return MatchResult.empty;
    final linked = bangumi?.candidate;
    final year = inventory.year ?? linked?.year;
    // A year borrowed from Bangumi can differ for OVA/TV editions: softer.
    final borrowed = inventory.year == null;
    final matchedBgm =
        bangumi != null && bangumi.tier != MatchTier.none ? linked : null;
    final ranking = <ScoredCandidate>[];
    for (final candidate in candidates) {
      final scored = ScoredCandidate(candidate);
      if (inventory.tmdbId != null && !ignoreTmdbMarker) {
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
      final isMapped =
          mappedTarget != null && mappedTarget.key == candidate.key;
      if (isMapped) {
        scored.add(20, 'bangumi-tmdb mapping');
      }
      var titleSim = _title(inventory, candidate);
      final verifiedBgm = bangumi?.tier == MatchTier.high ? linked : null;
      final parentTvSpecial =
          verifiedBgm != null &&
          _isParentTvForBangumiSpecial(inventory, candidate, verifiedBgm);
      if (titleSim < 0.85 && verifiedBgm != null) {
        final bridged = _bridgedTitle(verifiedBgm, candidate) * 0.85;
        if (bridged > titleSim) titleSim = bridged;
      }
      if (parentTvSpecial && titleSim < 0.80) {
        titleSim = 0.80;
      }
      scored.add(45 * titleSim, 'title');
      if (candidate.type == 'movie') {
        if (!isMapped && !parentTvSpecial && titleSim < 0.9) {
          scored.add(
            _subtitleConflictPenalty(
              inventory,
              candidate,
              verifiedBangumi: verifiedBgm,
            ),
            'conflicting subtitle',
          );
        }
        _movie(scored, inventory);
        _year(scored, year, candidate.year, borrowed: borrowed);
      } else {
        _tv(
          scored,
          inventory,
          year,
          borrowed,
          mappedSeason: isMapped ? mappedTarget.season : null,
          verifiedBangumi: verifiedBgm,
          matchedBangumi: matchedBgm,
          parentTvSpecial: parentTvSpecial,
          titleSim: titleSim,
          ignoreTmdbMarker: ignoreTmdbMarker,
        );
        if (scored.seasonNameMatched && titleSim < 0.85) {
          scored.add(45 * (0.85 - titleSim), 'season name');
        }
        if (!isMapped &&
            !parentTvSpecial &&
            titleSim < 0.9 &&
            !scored.seasonNameMatched &&
            !scored.tmdbMarkerSeasonMatched) {
          scored.add(
            _subtitleConflictPenalty(
              inventory,
              candidate,
              verifiedBangumi: verifiedBgm,
            ),
            'conflicting subtitle',
          );
        }
      }
      if (linked != null) {
        _linked(scored, linked, parentTvSpecial: parentTvSpecial);
      }
      ranking.add(scored);
    }
    final decision = _decide(ranking);
    if (decision.tier == MatchTier.medium &&
        year == null &&
        ranking.isNotEmpty &&
        inventory.shape != WorkShape.anthology) {
      final top = ranking.first;
      final margin = ranking.length < 2
          ? double.infinity
          : top.score - ranking[1].score;
      var cumulativeWithoutYear = false;
      if (top.candidate.type == 'tv' &&
          top.season != null &&
          top.season! > 0 &&
          inventory.episodes.isNotEmpty) {
        final matchedSeason = top.candidate.seasons
            .where((s) => s.number == top.season)
            .firstOrNull;
        final maxEp = inventory.episodes.reduce((a, b) => a > b ? a : b);
        if (matchedSeason != null &&
            matchedSeason.count > 0 &&
            maxEp > matchedSeason.count) {
          cumulativeWithoutYear = true;
        }
      }
      if (!cumulativeWithoutYear && top.score >= 59.5 && margin >= 20.0) {
        return MatchResult(MatchTier.high, ranking);
      }
    }
    return decision;
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
    bool borrowed, {
    int? mappedSeason,
    MatchCandidate? verifiedBangumi,
    MatchCandidate? matchedBangumi,
    bool parentTvSpecial = false,
    double titleSim = 0,
    bool ignoreTmdbMarker = false,
  }) {
    final candidate = scored.candidate;
    final regular = candidate.seasons.where((s) => s.number > 0).toList();
    final specials = candidate.seasons.where((s) => s.number == 0).toList();
    final episodes = inventory.episodeCount;
    final local = inventory.shape == WorkShape.series
        ? episodes
        : inventory.featureCount;
    int? yearOf = candidate.year;
    final bridgedSpecial =
        parentTvSpecial ||
        (verifiedBangumi != null &&
            !inventory.folderMovieMarker &&
            _bridgedTitle(verifiedBangumi, candidate) >= 0.60);
    final localIsRemaster =
        _hasRemasterInInventory(inventory) ||
        (matchedBangumi != null && _hasRemasterInCandidate(matchedBangumi));

    if (inventory.shape == WorkShape.anthology) {
      scored.add(-40, 'anthology');
    }
    if (inventory.shape == WorkShape.series) {
      final epsSet = inventory.episodes;
      final minEp = epsSet.isEmpty
          ? null
          : epsSet.reduce((a, b) => a < b ? a : b);
      final maxEp = epsSet.isEmpty
          ? null
          : epsSet.reduce((a, b) => a > b ? a : b);
      if (!parentTvSpecial &&
          inventory.season != 0 &&
          !(matchedBangumi?.isSpecialFormat ?? false) &&
          episodes <= 4 &&
          regular.isNotEmpty &&
          regular.every((s) => s.count >= 11) &&
          _hasConflictingCjkTitle(inventory.title, candidate.title)) {
        scored.add(-18, 'short ova vs long tv');
      }
      final seasonPick = _season(
        inventory,
        candidate,
        regular,
        year,
        mappedSeason: mappedSeason,
        linkedBangumi: matchedBangumi,
        localIsRemaster: localIsRemaster,
        ignoreTmdbMarker: ignoreTmdbMarker,
      );
      final maxSpecialEps = inventory.season == 0
          ? (specials.isNotEmpty ? specials.first.count : 0)
          : ((mappedSeason == 0 || (matchedBangumi?.isSpecialFormat ?? false))
                ? 12
                : 4);
      final allowSpecialSeason =
          inventory.season == 0 ||
          mappedSeason == 0 ||
          parentTvSpecial ||
          (bridgedSpecial &&
              DirectoryAnalyzer.normalize(inventory.title).length >=
                  DirectoryAnalyzer.normalize(candidate.title).length + 2);
      final sortedRegular = [...regular]
        ..sort((a, b) => a.number.compareTo(b.number));
      if (seasonPick != null) {
        final season = seasonPick.season;
        scored.season = season.number;
        scored.cumulativeOffsetMatched = seasonPick.cumulativeOffset;
        scored.seasonNameMatched = seasonPick.nameMatched;
        scored.tmdbMarkerSeasonMatched = seasonPick.tmdbMarkerMatched;
        yearOf = season.year ?? yearOf;
        scored.add(season.count == episodes ? 15 : 8, 'season count');
        if (seasonPick.cumulativeOffset) {
          scored.add(6, 'cumulative offset');
        }
      } else if (episodes > 0 &&
          episodes <= maxSpecialEps &&
          specials.isNotEmpty &&
          specials.first.count >= episodes &&
          allowSpecialSeason) {
        final s0 = specials.first;
        scored.season = 0;
        yearOf = s0.year ?? yearOf;
        scored.add(
          parentTvSpecial || inventory.season == 0 ? 12 : 10,
          'special season',
        );
      } else if (regular.isNotEmpty &&
          (regular.fold<int>(0, (n, s) => n + s.count) == episodes ||
              (minEp == 1 &&
                  sortedRegular.length >= 2 &&
                  _matchesConsecutivePrefixSum(sortedRegular, episodes)))) {
        scored.add(15, 'all seasons count');
      } else if (regular.isEmpty) {
        scored.add(episodes >= 10 ? 10 : 5, 'series');
      } else if (regular.any((s) => s.count >= episodes) || episodes > 30) {
        scored.add(5, 'series');
      }

      if (!scored.cumulativeOffsetMatched && minEp != null && minEp > 1 && maxEp != null) {
        final totalRegular = regular.fold<int>(0, (n, s) => n + s.count);
        if (regular.length == 1 &&
            totalRegular > 0 &&
            (minEp > 2 ? totalRegular < maxEp : totalRegular < maxEp - 1)) {
          scored.add(-16, 'incomplete season vs offset');
        } else if (regular.length > 1 &&
            seasonPick == null &&
            totalRegular > 0 &&
            totalRegular < maxEp - 1) {
          scored.add(-12, 'insufficient seasons vs offset');
        }
      }
    } else if (inventory.shape == WorkShape.feature) {
      if ((inventory.season == 0 || mappedSeason == 0 || parentTvSpecial) &&
          specials.isNotEmpty) {
        final s0 = specials.first;
        scored.season = 0;
        yearOf = s0.year ?? yearOf;
        scored.add(12, 'mapped special season');
      } else {
        // A special / OVA set can live in season 0 or a tiny season.
        final small = [...specials, ...regular.where((s) => s.count <= 3)]
            .where((s) {
              final diff = _yearDiff(year, s.year);
              if (s.count < local) return false;
              if (diff <= 1 || diff == 99) return true;
              if (s.number == 0 &&
                  s.count >= 2 &&
                  bridgedSpecial &&
                  year != null &&
                  s.year != null &&
                  year >= s.year! - 1) {
                return true;
              }
              return false;
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
    }
    if (localIsRemaster &&
        titleSim >= 0.80 &&
        year != null &&
        yearOf != null &&
        year > yearOf &&
        !_hasRemasterInCandidate(candidate)) {
      scored.add(4, 'remaster -> original year');
    } else if (inventory.season == 0 &&
        scored.season == 0 &&
        _yearDiff(year, yearOf) > 1 &&
        _yearDiff(year, candidate.year) <= 1) {
      _year(scored, year, candidate.year, borrowed: borrowed);
    } else if (scored.season == 0 &&
        bridgedSpecial &&
        (parentTvSpecial
            ? (year == null || yearOf == null || year >= yearOf - 1)
            : (year != null && yearOf != null && year > yearOf + 1))) {
      scored.add(
        _yearDiff(year, yearOf) == 0 ? 15 : 8,
        'franchise special year',
      );
    } else {
      _year(scored, year, yearOf, borrowed: borrowed);
    }
  }

  static bool _matchesConsecutivePrefixSum(
    List<SeasonInfo> sortedRegular,
    int episodes,
  ) {
    if (episodes <= 0) return false;
    var sum = 0;
    for (var i = 0; i < sortedRegular.length; i++) {
      final c = sortedRegular[i].count;
      if (c <= 0) return false;
      sum += c;
      if (i >= 1 && sum == episodes) return true;
      if (sum > episodes) return false;
    }
    return false;
  }

  static double _seasonNameMatchScore(
    DirectoryInventory inventory,
    MatchCandidate candidate,
    SeasonInfo season, {
    MatchCandidate? linkedBangumi,
  }) {
    final rawName = season.name?.trim() ?? '';
    if (rawName.isEmpty || _genericSeasonName.hasMatch(rawName)) return 0.0;
    final sNorm = DirectoryAnalyzer.normalize(rawName);
    if (sNorm.length < 2) return 0.0;
    final baseNorm = DirectoryAnalyzer.normalize(_stripRemaster(candidate.title));
    final seasonResidual =
        baseNorm.isNotEmpty &&
            sNorm.startsWith(baseNorm) &&
            sNorm.length > baseNorm.length + 1
        ? sNorm.substring(baseNorm.length)
        : sNorm;
    final combinedNorm =
        baseNorm.isNotEmpty && !sNorm.startsWith(baseNorm)
        ? '$baseNorm$sNorm'
        : sNorm;

    final primaryNorm = DirectoryAnalyzer.normalize(
      _stripRemaster(inventory.title),
    );
    final localResidual =
        baseNorm.isNotEmpty &&
            primaryNorm.startsWith(baseNorm) &&
            primaryNorm.length >= baseNorm.length + 2
        ? primaryNorm.substring(baseNorm.length)
        : '';

    final localNorms = <String>{
      if (primaryNorm.isNotEmpty) primaryNorm,
      for (final h in inventory.titleHints)
        DirectoryAnalyzer.normalize(_stripRemaster(h)),
      for (final f in inventory.fileHints.take(2))
        DirectoryAnalyzer.normalize(_stripRemaster(f)),
      if (linkedBangumi != null) ...[
        DirectoryAnalyzer.normalize(_stripRemaster(linkedBangumi.title)),
        for (final a in linkedBangumi.aliases.take(2))
          DirectoryAnalyzer.normalize(_stripRemaster(a)),
      ],
    }..removeWhere((s) => s.isEmpty);

    var best = 0.0;
    if (localResidual.isNotEmpty && sNorm != baseNorm) {
      final sim = similarity(localResidual, seasonResidual);
      if (sim > best) best = sim;
      final simRaw = similarity(localResidual, sNorm);
      if (simRaw > best) best = simRaw;
    }
    for (final local in localNorms) {
      if (sNorm == baseNorm &&
          local.length > baseNorm.length + 1 &&
          local.startsWith(baseNorm)) {
        continue;
      }
      final s1 = similarity(local, combinedNorm);
      if (s1 > best) best = s1;
      if (sNorm.length >= 3 || local == sNorm) {
        final s2 = similarity(local, sNorm);
        if (s2 > best) best = s2;
      }
    }
    return best;
  }

  static ({
    SeasonInfo season,
    bool cumulativeOffset,
    bool nameMatched,
    bool tmdbMarkerMatched,
  })?
  _season(
    DirectoryInventory inventory,
    MatchCandidate candidate,
    List<SeasonInfo> regular,
    int? year, {
    int? mappedSeason,
    MatchCandidate? linkedBangumi,
    bool localIsRemaster = false,
    bool ignoreTmdbMarker = false,
  }) {
    if (regular.isEmpty) return null;
    final explicit =
        inventory.season ??
        (inventory.main.map((i) => i.season).whereType<int>().toSet().length ==
                1
            ? inventory.main.map((i) => i.season).whereType<int>().first
            : null);
    if (explicit == 0) return null;
    final epsSet = inventory.episodes;
    final episodes = epsSet.length;
    final minEp = epsSet.isEmpty
        ? null
        : epsSet.reduce((a, b) => a < b ? a : b);
    final maxEp = epsSet.isEmpty
        ? null
        : epsSet.reduce((a, b) => a > b ? a : b);
    final sortedRegular = [...regular]
      ..sort((a, b) => a.number.compareTo(b.number));
    final bgmAirDate = _parseFullDate(linkedBangumi?.airDate);
    final nameScores = <int, double>{
      for (final s in sortedRegular)
        s.number: _seasonNameMatchScore(
          inventory,
          candidate,
          s,
          linkedBangumi: linkedBangumi,
        ),
    };
    final bestNameScore = nameScores.values.fold<double>(
      0.0,
      (m, v) => v > m ? v : m,
    );

    if (explicit == null &&
        mappedSeason == null &&
        minEp == 1 &&
        sortedRegular.length >= 2 &&
        bestNameScore < 0.72) {
      final allSum = sortedRegular.fold<int>(0, (n, s) => n + s.count);
      final singleExactMatch = sortedRegular.any(
        (s) =>
            s.count == episodes &&
            (_yearDiff(year, s.year) == 0 || (nameScores[s.number] ?? 0) >= 0.72),
      );
      if (!singleExactMatch &&
          ((allSum > 0 && episodes == allSum) ||
              (_matchesConsecutivePrefixSum(sortedRegular, episodes) &&
                  (year == null ||
                      _yearDiff(year, sortedRegular.first.year) <= 1)))) {
        return null;
      }
    }

    final exactBareBase =
        explicit == null &&
        mappedSeason == null &&
        year == null &&
        minEp == 1 &&
        DirectoryAnalyzer.normalize(inventory.title) ==
            DirectoryAnalyzer.normalize(candidate.title);

    SeasonInfo? best;
    var bestScore = 0, tie = false;
    var bestCumOffset = false, bestNameHit = false, bestMarkerMatched = false;
    var priorCount = 0;
    for (final season in sortedRegular) {
      var score = 0;
      if (mappedSeason != null) {
        score += season.number == mappedSeason ? 8 : -6;
      }
      if (explicit != null) score += season.number == explicit ? 6 : -6;
      if (season.count == episodes) {
        score += 3;
      } else if ((season.count - episodes).abs() <= 1) {
        score += 2;
      } else if (localIsRemaster &&
          season.count >= episodes &&
          season.count - episodes <= 4) {
        score += 2;
      }
      // Split-cour cumulative episode numbering (e.g. S2 files numbered 13..24).
      var cumOffset = false;
      if (priorCount > 0 &&
          minEp != null &&
          maxEp != null &&
          minEp == priorCount + 1) {
        final span = maxEp - minEp + 1;
        if (season.count > 0 && maxEp == priorCount + season.count) {
          score += 9;
          cumOffset = true;
        } else if (season.count >= span &&
            maxEp <= priorCount + season.count + 1) {
          score += 6;
          cumOffset = true;
        }
      }
      final diff = _yearDiff(year, season.year);
      if (diff == 0) {
        score += 2;
      } else if (diff >= 2 && diff < 99) {
        if (!(localIsRemaster &&
            year != null &&
            season.year != null &&
            year > season.year!)) {
          score -= 2;
        }
      }
      final markerMatched =
          !ignoreTmdbMarker &&
          inventory.tmdbId == candidate.id &&
          diff == 0 &&
          season.count == episodes;
      if (markerMatched) score += 2;

      final nScore = nameScores[season.number] ?? 0.0;
      final nameHit = nScore >= 0.72;
      if (nScore >= 0.88) {
        score += 8;
      } else if (nScore >= 0.72) {
        score += 5;
      }

      final sAirDate = _parseFullDate(season.airDate);
      if (bgmAirDate != null && sAirDate != null) {
        final days = bgmAirDate.difference(sAirDate).inDays.abs();
        if (days <= 7) {
          score += 7;
        } else if (days <= 35) {
          score += 5;
        } else if (bgmAirDate.year == sAirDate.year && days > 120) {
          score -= 2;
        }
      }

      if (exactBareBase && season.number == 1 && season.count == episodes) {
        score += 1;
      }
      if (score > bestScore) {
        best = season;
        bestScore = score;
        tie = false;
        bestCumOffset = cumOffset;
        bestNameHit = nameHit;
        bestMarkerMatched = markerMatched;
      } else if (score == bestScore && score > 0) {
        tie = true;
      }
      if (season.count > 0) priorCount += season.count;
    }
    if (tie || best == null || bestScore < 2) return null;
    return (
      season: best,
      cumulativeOffset: bestCumOffset,
      nameMatched: bestNameHit,
      tmdbMarkerMatched: bestMarkerMatched,
    );
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
  static void _linked(
    ScoredCandidate scored,
    MatchCandidate bangumi, {
    bool parentTvSpecial = false,
  }) {
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
    if (bonus == 0 && parentTvSpecial && scored.season == 0) {
      bonus = 10.0;
    }
    scored.add(bonus, 'bangumi agrees');
  }

  /// True when a verified short Bangumi special/OVA belongs to the franchise of
  /// [candidate] (a multi-episode TMDB TV series hosting specials in Season 0).
  static bool _isParentTvForBangumiSpecial(
    DirectoryInventory inventory,
    MatchCandidate candidate,
    MatchCandidate verifiedBangumi,
  ) {
    if (candidate.type != 'tv') return false;
    if ((inventory.season != null && inventory.season != 0) ||
        inventory.folderMovieMarker ||
        inventory.fileMovieMarker) {
      return false;
    }
    final localCount = inventory.shape == WorkShape.series
        ? inventory.episodeCount
        : inventory.shape == WorkShape.feature
        ? inventory.featureCount
        : 0;
    final maxCount =
        verifiedBangumi.isSpecialFormat || inventory.season == 0 ? 12 : 4;
    if (localCount < 1 || localCount > maxCount) return false;
    if ((verifiedBangumi.seasons.firstOrNull?.count ?? 0) > maxCount) {
      return false;
    }

    final specials = candidate.seasons.where((s) => s.number == 0).toList();
    if (specials.isEmpty || specials.first.count < localCount) return false;
    // Do not hijack a short TV season that already matches the episode count.
    final regular = candidate.seasons.where((s) => s.number > 0).toList();
    if (inventory.season != 0 &&
        regular.any(
          (s) =>
              (s.count - localCount).abs() <= 1 &&
              (!verifiedBangumi.isSpecialFormat ||
                  _yearDiff(verifiedBangumi.year, s.year) <= 1),
        )) {
      return false;
    }

    final candNorms = [candidate.title, ...candidate.aliases]
        .map(DirectoryAnalyzer.normalize)
        .where(
          (s) =>
              RegExp(r'[\u3040-\u9fff]').allMatches(s).length >= 4 ||
              s.length >= 8,
        )
        .toList();
    if (candNorms.isEmpty) return false;

    final bgmTitle = DirectoryAnalyzer.normalize(verifiedBangumi.title);
    final bgmOrig = verifiedBangumi.aliases.isEmpty
        ? ''
        : DirectoryAnalyzer.normalize(verifiedBangumi.aliases.first);
    final localNorm = DirectoryAnalyzer.normalize(inventory.title);

    final bgmMatchesPrefix = candNorms.any(
      (c) =>
          (bgmOrig.startsWith(c) && bgmOrig.length > c.length) ||
          (bgmTitle.startsWith(c) && bgmTitle.length > c.length),
    );
    if (!bgmMatchesPrefix) return false;

    return candNorms.any(
          (c) => localNorm.startsWith(c) && localNorm.length > c.length,
        ) ||
        _bridgedTitle(verifiedBangumi, candidate) >= 0.60;
  }

  static bool _candidateHasSequelSignal(
    DirectoryInventory inventory,
    List<String> names,
  ) {
    final fullNorm = DirectoryAnalyzer.normalize(inventory.title);
    for (final name in names) {
      final norm = DirectoryAnalyzer.normalize(name);
      if (norm == fullNorm) return true;
      final split = DirectoryAnalyzer.splitSeasonSuffix(name, isSeries: true);
      if (split.season != null && split.season == inventory.season) return true;
    }
    return false;
  }

  /// Penalizes candidates whose subtitle after a shared base prefix conflicts
  /// with the local folder's explicit subtitle (e.g. "快盗天使双胞胎~心跳不已~"
  /// vs "快盗天使BREAK", or "Wake Up, Girls! 七人的偶像" vs "Wake Up, Girls! 新章").
  static double _subtitleConflictPenalty(
    DirectoryInventory inventory,
    MatchCandidate candidate, {
    MatchCandidate? verifiedBangumi,
  }) {
    if (verifiedBangumi != null &&
        _bridgedTitle(verifiedBangumi, candidate) >= 0.70) {
      return 0;
    }
    final localPrimary = DirectoryAnalyzer.normalize(
      _stripRemaster(inventory.title.replaceAll(_movieWord, ' ')),
    );
    if (localPrimary.length < 4) return 0;

    final remoteNames = [
      candidate.title,
      ...candidate.aliases,
      if (candidate.type == 'tv')
        for (final s in candidate.seasons)
          if (s.name != null &&
              s.name!.trim().isNotEmpty &&
              !_genericSeasonName.hasMatch(s.name!.trim())) ...[
            s.name!.trim(),
            '${candidate.title} ${s.name!.trim()}',
          ],
    ]
        .map(
          (n) => DirectoryAnalyzer.normalize(
            _stripRemaster(n.replaceAll(_movieWord, ' ')),
          ),
        )
        .where((n) => n.isNotEmpty)
        .toList();
    if (remoteNames.any((r) => similarity(localPrimary, r) >= 0.80)) {
      return 0;
    }

    // If a filename carries an explicit subtitle that agrees strongly with a
    // candidate alias (without unilateral sequel suffix), do not penalize
    // cross-language folder/TMDB translation differences.
    for (final fh in inventory.fileHints.take(2)) {
      final fn = DirectoryAnalyzer.normalize(fh.replaceAll(_movieWord, ' '));
      if (fn.length < 6) continue;
      for (final rn in remoteNames) {
        if (rn.startsWith(fn) &&
            rn.length > fn.length &&
            _sequelOrSpinoffSuffix.hasMatch(rn.substring(fn.length))) {
          continue;
        }
        if (similarity(fn, rn) >= 0.70) return 0;
      }
    }

    final candPrimary = DirectoryAnalyzer.normalize(
      _stripRemaster(candidate.title.replaceAll(_movieWord, ' ')),
    );
    if (candPrimary.length < 4 || localPrimary == candPrimary) return 0;

    var prefixLen = 0;
    final limit = localPrimary.length < candPrimary.length
        ? localPrimary.length
        : candPrimary.length;
    while (prefixLen < limit &&
        localPrimary.codeUnitAt(prefixLen) ==
            candPrimary.codeUnitAt(prefixLen)) {
      prefixLen++;
    }
    final prefix = localPrimary.substring(0, prefixLen);
    final hasCjkPrefix =
        RegExp(r'[\u3040-\u9fff]').allMatches(prefix).length >= 3;
    if (!hasCjkPrefix && prefixLen < 6) return 0;

    var localRem = localPrimary.substring(prefixLen);
    var candRem = candPrimary.substring(prefixLen);
    while (localRem.isNotEmpty &&
        candRem.isNotEmpty &&
        localRem.codeUnitAt(localRem.length - 1) ==
            candRem.codeUnitAt(candRem.length - 1)) {
      localRem = localRem.substring(0, localRem.length - 1);
      candRem = candRem.substring(0, candRem.length - 1);
    }
    if (candidate.provider == 'bangumi' &&
        candRem.isEmpty &&
        localRem.length >= 2 &&
        inventory.season == null &&
        (inventory.shape == WorkShape.feature || inventory.episodeCount <= 4) &&
        !RegExp(
          r'^(?:ova|oad|sp|specials?)$',
          caseSensitive: false,
        ).hasMatch(localRem)) {
      return -18;
    }
    if (localRem.length < 2 || candRem.length < 2) return 0;
    if (candidate.provider == 'tmdb' &&
        prefixLen >= 7 &&
        prefixLen >= localPrimary.length * 0.65) {
      return 0;
    }

    if (similarity(localRem, candRem) < 0.25) {
      return -25;
    }
    return 0;
  }

  static bool _hasConflictingCjkTitle(String localTitle, String candTitle) {
    String cjkOnly(String s) => RegExp(
      r'[\u4e00-\u9fff]+',
    ).allMatches(s).map((m) => m.group(0)!).join();
    final a = cjkOnly(localTitle);
    final b = cjkOnly(candTitle);
    if (a.length < 4 || b.length < 4) return false;
    return a != b && similarity(a, b) < 0.85;
  }

  static int? _partIndexFromSuffix(String suffix) {
    final trimmed = suffix.trim();
    if (trimmed.isEmpty) return null;
    final patterns = <(RegExp, int)>[
      (
        RegExp(
          r'^(?:one|1|i|前篇|前編|上篇?|前章)(?:[^a-z0-9]|$)',
          caseSensitive: false,
        ),
        1,
      ),
      (
        RegExp(
          r'^(?:two|2|ii|后篇|後編|下篇?|后章|後章)(?:[^a-z0-9]|$)',
          caseSensitive: false,
        ),
        2,
      ),
      (RegExp(r'^(?:three|3|iii|中篇?)(?:[^a-z0-9]|$)', caseSensitive: false), 3),
      (RegExp(r'^(?:four|4|iv)(?:[^a-z0-9]|$)', caseSensitive: false), 4),
    ];
    for (final (re, part) in patterns) {
      if (re.hasMatch(trimmed)) return part;
    }
    return null;
  }

  static MatchResult? _resolveBangumiMultiPartTie(
    DirectoryInventory inventory,
    List<ScoredCandidate> ranking,
  ) {
    final k = inventory.episodeCount;
    if (inventory.shape != WorkShape.series || k < 2 || k > 4) return null;
    if (ranking.length < k) return null;
    final normLocal = DirectoryAnalyzer.normalize(inventory.title);
    if (normLocal.length < 5) return null;

    final sorted = [...ranking]..sort((a, b) => b.score.compareTo(a.score));
    final topScore = sorted.first.score;
    if (topScore < 36) return null;

    final partsByIndex = <int, ScoredCandidate>{};
    final partIds = <int>{};
    for (final item in sorted) {
      if (topScore - item.score > 6.0) break;
      for (final rawName in [item.candidate.title, ...item.candidate.aliases]) {
        final normCand = DirectoryAnalyzer.normalize(rawName);
        if (!normCand.startsWith(normLocal) ||
            normCand.length <= normLocal.length) {
          continue;
        }
        final part = _partIndexFromSuffix(normCand.substring(normLocal.length));
        if (part != null && part <= k && !partsByIndex.containsKey(part)) {
          partsByIndex[part] = item;
          partIds.add(item.candidate.id);
          break;
        }
      }
    }
    if (partsByIndex.length != k) return null;
    for (var i = 1; i <= k; i++) {
      if (!partsByIndex.containsKey(i)) return null;
    }
    final bestOutsider = sorted
        .where((s) => !partIds.contains(s.candidate.id))
        .firstOrNull;
    if (bestOutsider != null && topScore - bestOutsider.score < 10.0) {
      return null;
    }
    final orderedParts = [for (var i = 1; i <= k; i++) partsByIndex[i]!];
    final rest = sorted.where((s) => !partIds.contains(s.candidate.id));
    return MatchResult(
      MatchTier.high,
      [...orderedParts, ...rest],
      siblingIds: [for (final p in orderedParts) p.candidate.id],
    );
  }

  /// Best similarity between local titles and remote names, 0..1.
  /// Folder titles are trusted more than filename titles.
  static double _title(DirectoryInventory inventory, MatchCandidate candidate) {
    final primaryNorm = DirectoryAnalyzer.normalize(inventory.title);
    final baseCandNorm = DirectoryAnalyzer.normalize(candidate.title);
    final sharesBase =
        baseCandNorm.length >= 2 && primaryNorm.contains(baseCandNorm);
    final remote = {
      for (final name in [candidate.title, ...candidate.aliases])
        DirectoryAnalyzer.normalize(name),
      if (candidate.type == 'tv')
        for (final s in candidate.seasons)
          if (s.name != null &&
              s.name!.trim().isNotEmpty &&
              !_genericSeasonName.hasMatch(s.name!.trim())) ...[
            DirectoryAnalyzer.normalize('${candidate.title} ${s.name!.trim()}'),
            if (DirectoryAnalyzer.normalize(s.name!.trim()).length >= 4 ||
                sharesBase)
              DirectoryAnalyzer.normalize(s.name!.trim()),
          ],
    }..removeWhere((name) => name.isEmpty);
    final multiSeasonTv =
        candidate.provider == 'tmdb' &&
        candidate.type == 'tv' &&
        inventory.season != null &&
        candidate.seasons.where((s) => s.number > 0).length >=
            inventory.season!;
    final localHasSequel =
        inventory.season != null && inventory.season! > 1 ||
        DirectoryAnalyzer.splitSeasonSuffix(
              inventory.title,
              isSeries: true,
            ).season !=
            null;

    var best = 0.0;
    void check(Iterable<String> hints, double weight) {
      for (final hint in hints) {
        final local = DirectoryAnalyzer.normalize(hint);
        if (local.isEmpty) continue;
        // Season-stripped base hints are recall helpers: full weight on multi-season
        // TMDB TV entries, discounted on per-season Bangumi entries.
        var effectiveWeight = weight;
        if (inventory.season != null &&
            inventory.season! > 1 &&
            primaryNorm.startsWith(local) &&
            local.length < primaryNorm.length) {
          effectiveWeight = weight * (multiSeasonTv ? 1.0 : 0.80);
        }
        for (final name in remote) {
          var pairSim = similarity(local, name);
          if (!localHasSequel &&
              name.startsWith(local) &&
              name.length > local.length &&
              _sequelOrSpinoffSuffix.hasMatch(name.substring(local.length))) {
            pairSim *= 0.62;
          } else if (inventory.shape == WorkShape.feature &&
              inventory.featureCount == 1 &&
              weight == 1.0 &&
              local == primaryNorm &&
              RegExp(r'[\u3040-\u9fff]').allMatches(local).length >= 5 &&
              name.startsWith(local) &&
              name.length > local.length &&
              !_sequelOrSpinoffSuffix.hasMatch(name.substring(local.length)) &&
              (candidate.type == 'movie' ||
                  (candidate.provider == 'bangumi' &&
                      (candidate.seasons.isEmpty ||
                          candidate.seasons.first.count <= 2)))) {
            if (pairSim < 0.94) pairSim = 0.94;
          }
          final value = pairSim * effectiveWeight;
          if (value > best) best = value;
        }
      }
    }

    check(inventory.titleHints, 1);
    check(inventory.fileHints, 0.92);
    if (candidate.provider == 'tmdb' &&
        _hasRemasterInInventory(inventory) &&
        !_hasRemasterInCandidate(candidate)) {
      check([for (final h in inventory.titleHints) _stripRemaster(h)], 0.95);
    }
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
