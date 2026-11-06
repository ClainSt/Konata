/// A stable *candidate* identity for a TMDB-mapped television episode.
///
/// Unlike physical asset IDs, this key excludes source ID, path, work ID and
/// encode. A non-null key is not proof of accurate scraping: sync must still
/// validate the work binding and manual episode mapping before using it.
/// Missing fields return null rather than guessing.
abstract final class LogicalEpisodeIdentity {
  static String? forAsset({
    required Map<String, Object?> work,
    required Map<String, Object?> asset,
    bool confirmedSpecial = false,
  }) {
    final special =
        confirmedSpecial &&
        asset['category'] == 'extra' &&
        _number(asset['season']) == 0;
    if (asset['category'] != 'main' && !special) return null;
    if (work['tmdb_type']?.toString().toLowerCase() != 'tv') return null;
    final tmdbId = _number(work['tmdb_id']);
    final season = _number(asset['season']);
    final episode = _number(asset['episode']);
    if (tmdbId == null ||
        tmdbId <= 0 ||
        season == null ||
        season < 0 ||
        episode == null ||
        episode <= 0) {
      return null;
    }
    return 'tmdb:tv:$tmdbId:s$season:e$episode';
  }

  static int? _number(Object? value) {
    if (value is int) return value;
    if (value is num && value.isFinite && value == value.toInt()) {
      return value.toInt();
    }
    return null;
  }
}
