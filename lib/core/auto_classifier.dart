import 'package:path/path.dart' as path;
import 'catalog.dart';
import 'personal_filename_parser.dart';
import 'cloud_media_file_classifier.dart';

/// Best-effort folder-based grouping. Never reads video bytes or hashes.
/// TMDB markers have priority, followed by folder topology.
class AutoWork {
  const AutoWork(this.folder, {required this.needsReview});
  final String folder;
  final bool needsReview;
}

class AutoClassifier {
  static final _knownContainer = RegExp(
    r'^(动画[-_ ]?(单作品|多作品|系列|电影|剧场版)?|电影|电视剧|合集|系列|番剧|'
    r'Anime|Movies|TV Shows|Library|Media|Collections?)$',
    caseSensitive: false,
  );
  static final _subResource = RegExp(
    r'^(SPs?|Extras?|Bonus|Scans?|CDs?|Season[\s._-]*\d+|S\d{1,2}|'
    r'第[一二三四五六七八九十\d]+季|BD[\s._-]?(Vol|Box|Disc)?[\s._-]*\d*|'
    r'Disc[\s._-]*\d+|Vol[\s._-]*\d+|NCOP|NCED|PV|CM)$',
    caseSensitive: false,
  );
  static bool isContainer(String title) => _knownContainer.hasMatch(title);
  static bool isSubResource(String title) => _subResource.hasMatch(title);
  static bool hasStrongId(String title) =>
      Catalog.tmdbId(title) != null ||
      RegExp(r'\{bangumi-\d+\}', caseSensitive: false).hasMatch(title);
  static bool hasIdentity(String title) =>
      Catalog.tmdbId(title) != null ||
      Catalog.year(title) != null ||
      RegExp(r'\{bangumi-\d+\}', caseSensitive: false).hasMatch(title);

  static final _releaseEpisode = RegExp(
    r'(?:\s+[-–—]\s+|[／\s]+EP[ ._-]*)(\d{1,3})(?:v\d+)?'
    r'(?!\d|[.+&~～-]\d)(?=\s|[\[(（【]|$)',
    caseSensitive: false,
  );
  static final _filmLabel = RegExp(
    r'\b(?:movie|film)\b|剧场版|劇場版',
    caseSensitive: false,
  );

  /// Infer separate releases from a complete file listing. The returned
  /// folders are catalogue identities. Media paths still point to the files.
  static Map<String, String> releaseFolders(String folder, List<String> paths,
      {Map<String, int?> sizes = const {}}) {
    if (paths.length < 3 || hasStrongId(path.posix.basename(folder))) return {};
    final groups = <String, List<({String path, String title, int? episode})>>{};
    final supplements = <String, String>{};
    final folderTitle = path.posix.basename(folder);
    final separateTitles = folderTitle.contains(RegExp(r'\s[&＆]\s'));
    final specialCollection = RegExp(r'(?:\s(?:Extras|Specials)|合集)$',
        caseSensitive: false).hasMatch(folderTitle);
    for (final file in paths) {
      if (Catalog.isExtra(file)) continue;
      if (path.posix.dirname(file) != folder) return {};
      final label = CloudMediaFileClassifier.numberedSupplementLabel;
      if (label.allMatches(path.posix.basename(file)).singleOrNull != null) {
        final original = path.posix.join(folder, path.posix.basename(file).replaceFirst(label, ''));
        final size = sizes[file], originalSize = sizes[original];
        if (size != null && originalSize != null && size > 0 && size * 2 < originalSize) {
          supplements[file] = original;
          continue;
        }
      }
      final name = path.posix.basenameWithoutExtension(file);
      final number = _releaseEpisode.firstMatch(name);
      final prefix = number == null ? name : name.substring(0, number.start);
      var title = PersonalFilenameParser.extractAnimeSearchKeyword('$prefix.mkv');
      final releaseYear = Catalog.year(prefix) ??
          int.tryParse(RegExp(r'\[((?:19|20)\d{2})\]').firstMatch(prefix)?[1] ?? '');
      if (releaseYear case final int releaseYear
          when _filmLabel.hasMatch(title) && Catalog.year(title) == null) {
        title = '$title $releaseYear';
      }
      if (title.length < 4 || title.length > 160 ||
          title.contains(RegExp(r'[/\\<>:"|?*\x00-\x1f]'))) return {};
      var chapter = number == null ? null : int.parse(number[1]!);
      if (chapter == null && specialCollection) {
        final ordinal = RegExp(r'\b(?:Stage|Part|Volume)\s+(I|II|III|IV)\s*$',
            caseSensitive: false).firstMatch(title);
        if (ordinal != null) {
          chapter = const ['I', 'II', 'III', 'IV'].indexOf(ordinal[1]!.toUpperCase()) + 1;
          title = title.substring(0, ordinal.start + ordinal[0]!.lastIndexOf(ordinal[1]!)).trim();
        }
      }
      final key = PersonalFilenameParser.normalizeIdentity(title);
      if (key.isEmpty) return {};
      (groups[key] ??= []).add((path: file, title: title, episode: chapter));
    }
    if (groups.length < 2 || groups.length > 12) return {};
    final releases = groups.values.toList();
    final numbered = releases.where((release) => release.length > 1).toList();
    if (numbered.any((release) {
      final episodes = release.map((entry) => entry.episode).toSet();
      return episodes.length != release.length ||
          !List.generate(release.length, (index) => index + 1).every(episodes.contains);
    })) return {};
    final multipleNumbered = numbered.length >= 2 ||
        separateTitles && numbered.isNotEmpty &&
            releases.every((release) => release.first.episode != null);
    final distinctSpecials = numbered.length == 1 &&
        (numbered.single.length >= 3 && releases.length >= 3 || specialCollection) &&
        releases.where((release) => release.length == 1)
            .every((release) => release.single.episode == null);
    final filmYears = releases.map((release) => Catalog.year(release.first.title)).toSet();
    final distinctFilms = separateTitles && numbered.isEmpty &&
        !filmYears.contains(null) && filmYears.length == releases.length &&
        releases.every((release) => _filmLabel.hasMatch(release.single.title));
    if (!multipleNumbered && !distinctSpecials && !distinctFilms) return {};

    // Related files must share a title prefix. Different numbered releases
    // without a common prefix need a metadata decision rather than a guess.
    final titles = releases.map((release) => release.first.title).toList()
      ..sort((a, b) => a.length.compareTo(b.length));
    final words = titles.first.toLowerCase().split(RegExp(r'[\s_-]+'));
    final common = <String>[];
    for (final word in words) {
      final next = [...common, word];
      if (!titles.every((title) => title.toLowerCase().split(RegExp(r'[\s_-]+'))
          .take(next.length).join(' ') == next.join(' '))) break;
      common.add(word);
    }
    if (common.join(' ').length < 8) return {};
    final parentTitle = common.join(' ');
    final assignments = {
      for (final release in releases)
        for (final entry in release)
          entry.path: !separateTitles && entry.title.toLowerCase() == parentTitle
              ? folder
              : '$folder/${release.first.title}',
    };
    for (final entry in supplements.entries) {
      if (assignments[entry.value] case final String release) {
        assignments[entry.key] = release;
      }
    }
    return assignments;
  }

  static AutoWork? decide({
    required String selectedRoot,
    required String relativePath,
    required bool rootHasDirectVideo,
    required String localRootName,
    bool strictMarkers = false,
  }) {
    final root = Catalog.normalizeRoot(selectedRoot);
    final file = Catalog.normalizeRoot(relativePath);
    if (!Catalog.isVideo(file)) return null;
    if (root.isNotEmpty && !file.startsWith('$root/')) return null;
    final rest = root.isEmpty ? file : file.substring(root.length + 1);
    final parts = rest.split('/');
    if (parts.isEmpty) return null;
    final directories = parts.take(parts.length - 1).toList();

    // Nested explicit IDs override collection/series folder heuristics.
    var markerFolder = '';
    var explicitFolder = '';
    bool hasMarker(String name) =>
        PersonalFilenameParser.tmdbIds(name).isNotEmpty ||
        RegExp(r'\{bangumi-\d+\}', caseSensitive: false).hasMatch(name);
    var cursor = root;
    if (root.isNotEmpty && hasIdentity(path.posix.basename(root))) {
      markerFolder = root;
    }
    if (strictMarkers && hasMarker(path.posix.basename(root))) {
      explicitFolder = root;
    }
    for (final folder in directories) {
      cursor = cursor.isEmpty ? folder : '$cursor/$folder';
      if (hasIdentity(folder)) markerFolder = cursor;
      if (strictMarkers && hasMarker(folder)) explicitFolder = cursor;
    }
    if (explicitFolder.isNotEmpty) markerFolder = explicitFolder;
    if (markerFolder.isNotEmpty) {
      return AutoWork(
        markerFolder,
        needsReview: !hasStrongId(path.posix.basename(markerFolder)),
      );
    }
    if (root.isEmpty && directories.isEmpty && hasIdentity(localRootName)) {
      return AutoWork(localRootName, needsReview: !hasStrongId(localRootName));
    }

    // A selected work containing direct video files, or containing a
    // recognized season/extras/BD folder, is a work rather than a collection.
    final rootName = root.isEmpty ? localRootName : path.posix.basename(root);
    final knownGroup = isContainer(rootName);
    if (root.isNotEmpty || localRootName.isNotEmpty) {
      if (rootHasDirectVideo && !knownGroup) {
        return AutoWork(root.isEmpty ? localRootName : root, needsReview: true);
      }
      if (directories.isNotEmpty &&
          isSubResource(directories.first) &&
          !knownGroup) {
        return AutoWork(root.isEmpty ? localRootName : root, needsReview: true);
      }
    }

    // Container depth is arbitrary. The closest ordinary directory owns the
    // video; recognized season/bonus directories remain below that work.
    if (directories.isNotEmpty) {
      final pathParts = <String>[if (root.isNotEmpty) ...root.split('/')];
      String? candidate;
      for (final folder in directories) {
        if (isSubResource(folder) || CloudMediaFileClassifier.isSupplementaryDirectory(folder)) {
          if (candidate != null) return AutoWork(candidate, needsReview: true);
          return null;
        }
        pathParts.add(folder);
        if (isContainer(folder)) continue;
        candidate = pathParts.join('/');
      }
      if (candidate != null) return AutoWork(candidate, needsReview: true);
    }

    // Direct videos of an unlabelled root are not reliable to match.
    if (!knownGroup && rootName.isNotEmpty) {
      return AutoWork(root.isEmpty ? rootName : root, needsReview: true);
    }
    // Keep direct collection files available for file-level matching.
    return AutoWork(
      root.isEmpty ? '@unclassified' : '$root/@unclassified',
      needsReview: true,
    );
  }
}
