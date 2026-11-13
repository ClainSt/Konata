import 'cloud_media_asset_presentation.dart';

/// Preserve directory identity after provider titles replace the display name.
abstract final class WorkSeason {
  // A broadcast part is a search clue, never an implicit TMDB season number.
  static final _part = RegExp(r'第\s*(\d{1,2})\s*部分|\bPart\s*(\d{1,2})\b', caseSensitive: false);
  static int? part(String title) {
    final matches = _part.allMatches(title).toList();
    if (matches.length != 1) return null;
    return int.tryParse(matches.single[1] ?? matches.single[2]!);
  }
  static String withoutPart(String title) =>
      title.replaceAll(_part, ' ').replaceAll(RegExp(r'\s+'), ' ').trim();

  static bool showSeasonInTitle(
    Map<String, Object?> work,
    Iterable<Map> seasons,
  ) {
    final directorySeason = CloudMediaAssetPresentation.explicitSeasonNumber({
      'work_title': directoryTitle(work),
    });
    return directorySeason != null ||
        seasons.where((s) => (s['season_number'] as num? ?? 0) > 0).length > 1;
  }

  static bool multiple(Map<String, Object?> work) =>
      RegExp(
            r'(?<![a-z0-9])S(\d{1,2})[ ._]*(?:[+&~～]|[-–—])[ ._]*S?(\d{1,2})(?![a-z0-9])',
            caseSensitive: false,
          )
          .allMatches(directoryTitle(work))
          .any((m) => int.parse(m.group(1)!) != int.parse(m.group(2)!));

  static bool needsRefresh(
    Map<String, Object?> work, {
    bool sharedSeries = true,
  }) {
    if (work['tmdb_type'] != 'tv' || work['tmdb_id'] == null) return false;
    if (multiple(work)) return false;
    final number = explicit(work);
    final title = work['title']?.toString() ?? '';
    if (number != null) return !title.endsWith('第$number季');
    return sharedSeries &&
        year(work) != null &&
        !RegExp(r'第\d+季$').hasMatch(title);
  }

  static String directoryTitle(Map<String, Object?> work) {
    final id = work['id']?.toString() ?? '';
    if (!id.startsWith('work:') || id.contains(':classified:')) {
      return work['title']?.toString() ?? '';
    }
    try {
      return Uri.decodeComponent(
        id.substring(id.lastIndexOf(':') + 1),
      ).replaceAll('\\', '/').split('/').last;
    } on FormatException {
      return work['title']?.toString() ?? '';
    }
  }

  static int? explicit(Map<String, Object?> work) =>
      CloudMediaAssetPresentation.explicitSeasonNumber({
        'work_title': directoryTitle(work),
      }) ??
      CloudMediaAssetPresentation.explicitSeasonNumber({
        'work_title': work['title'],
      });

  static Set<int> bracketYears(Map<String, Object?> work) => {
    for (final match in RegExp(r'\(\s*((?:19|20)\d{2})\s*\)|（\s*((?:19|20)\d{2})\s*）').allMatches(directoryTitle(work)))
      int.parse(match[1] ?? match[2]!),
  };
  static bool conflictingYears(Map<String, Object?> work) =>
      work['conflicting_years'] == true || bracketYears(work).length > 1;
  static int? year(Map<String, Object?> work) {
    // Filename parsing already separated title digits from year evidence.
    // Keep that decision (including unknown), or a subsequently inherited year.
    if (work['filename_year_parsed'] == true) {
      return conflictingYears(work) ? null : (work['year'] as num?)?.toInt();
    }
    final bracketed = bracketYears(work);
    if (bracketed.isNotEmpty) return bracketed.length == 1 ? bracketed.single : null;
    return int.tryParse(
      RegExp(r'(?<![\dx])((?:19|20)\d{2})(?![\dx])').firstMatch(
        directoryTitle(work).replaceAll(RegExp(r'\{[^}]*\}|\[[^\]]*\]'), ''),
      )?.group(1) ?? '',
    ) ?? (work['year'] as num?)?.toInt();
  }
  static int? resolve(Map<String, Object?> work, List<Map> seasons) {
    if (multiple(work)) return null;
    final requested = explicit(work);
    if (requested != null) return requested;
    final wantedYear = year(work);
    if (wantedYear == null) return null;
    final matches = seasons
        .where(
          (season) =>
              (season['season_number'] as num? ?? 0) > 0 &&
              '${season['air_date'] ?? ''}'.startsWith('$wantedYear-'),
        )
        .toList();
    return matches.length == 1
        ? (matches.single['season_number'] as num).toInt()
        : null;
  }

  static bool ambiguousYear(Map<String, Object?> work, List<Map> seasons) {
    final wanted = year(work);
    return wanted != null &&
        explicit(work) == null &&
        !multiple(work) &&
        seasons
                .where(
                  (s) =>
                      (s['season_number'] as num? ?? 0) > 0 &&
                      '${s['air_date'] ?? ''}'.startsWith('$wanted-'),
                )
                .length >
            1;
  }
}
