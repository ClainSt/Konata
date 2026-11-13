import 'cloud_media_asset_presentation.dart';
import 'work_season.dart';

/// Shared episode metadata lookup for details and playback history.
abstract final class EpisodeMetadata {
  static bool isOva(String type) => type == 'OVA' || type == 'OAD';

  static String? specialType(Object? name) => name is String
      ? CloudMediaAssetPresentation.specialTypeFromTitle(name)
      : null;

  static String specialTitle(String name) {
    final match = RegExp(
      r'^(?:[『「“"].+?[』」”"]\s*)?(?:OVA|OAD)(?![a-z])\s*\d*\s*[:：.\-–—]?\s*',
      caseSensitive: false,
    ).firstMatch(name);
    if (match == null) {
      return name
          .replaceFirst(
            RegExp(
              r'\s*[(（\[](?:OVA|OAD)\s*\d*[)）\]]\s*$',
              caseSensitive: false,
            ),
            '',
          )
          .trim();
    }
    var title = name.substring(match.end).trim();
    for (final (open, close) in [
      ('「', '」'),
      ('『', '』'),
      ('“', '”'),
      ('"', '"'),
    ]) {
      if (title.length > 2 && title.startsWith(open) && title.endsWith(close)) {
        title = title.substring(1, title.length - 1).trim();
        break;
      }
    }
    return title;
  }

  static Map<String, dynamic> lookup(
    Map<String, Object?> work,
    Map<String, dynamic> details,
    Map<String, Object?> asset,
  ) {
    final n = asset['episode'] as int?;
    if (asset['category'] == 'extra') {
      if (asset['manual_mapping'] == true && asset['season'] == 0) {
        final rows = details['specials'];
        return rows is Map && rows[n.toString()] is Map
            ? Map<String, dynamic>.from(rows[n.toString()] as Map)
            : {};
      }
      final specials = details['specialAssets'];
      final path = asset['relative_path']?.toString();
      if (specials is Map && specials[path] is Map) {
        return Map<String, dynamic>.from(specials[path] as Map);
      }
      // A CM01 number is not the same as TMDB special episode 1.
      if (!CloudMediaAssetPresentation.isSpecialMappingCandidate(asset)) {
        return {};
      }
      final explicit = CloudMediaAssetPresentation.explicitSpecialNumber(asset);
      if (explicit == null) return {};
      final entries = details['specials'];
      if (entries is Map && entries[explicit.toString()] is Map) {
        return Map<String, dynamic>.from(entries[explicit.toString()] as Map);
      }
      return {};
    }
    if (work['tmdb_type'] == 'movie' && asset['category'] == 'main') {
      return {
        'still': details['movieStill'],
        'name': work['title']?.toString().trim().isNotEmpty == true
            ? work['title']
            : details['title'],
      };
    }
    if (n == null) return {};
    final seasons = details['seasonEpisodes'];
    final counts = details['seasonEpisodeCounts'];
    final explicitSeason = CloudMediaAssetPresentation.explicitSeasonNumber({
      ...asset,
      'work_title': WorkSeason.directoryTitle(work),
    });
    var season = asset['manual_mapping'] == true
        ? (asset['season'] as int? ?? 1)
        : explicitSeason ?? asset['season'] as int? ?? 1;
    var local = n;
    final hasExplicit =
        explicitSeason != null || asset['manual_mapping'] == true;
    if (!hasExplicit && details['seasonMappingAmbiguous'] == true) return {};
    if (!hasExplicit && season == 1 && counts is Map) {
      final keys =
          counts.keys
              .map((e) => int.tryParse(e.toString()))
              .whereType<int>()
              .where((e) => e > 0)
              .toList()
            ..sort();
      for (final s in keys) {
        final count = (counts[s.toString()] as num?)?.toInt() ?? 0;
        if (count <= 0) break;
        if (local <= count) {
          season = s;
          break;
        }
        local -= count;
      }
    }
    final entries = seasons is Map ? seasons[season.toString()] : null;
    if (entries is Map && entries[local.toString()] is Map) {
      return Map<String, dynamic>.from(entries[local.toString()] as Map);
    }
    if (season != 1) return {};
    final old = details['episodes'];
    if (old is Map && old[n.toString()] is Map) {
      return Map<String, dynamic>.from(old[n.toString()] as Map);
    }
    return {};
  }
}
