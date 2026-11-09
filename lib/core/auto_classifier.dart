import 'package:path/path.dart' as path;
import 'catalog.dart';

/// Best-effort folder-based grouping. Never reads video bytes or hashes.
/// TMDB markers have priority, then folder topology; ambiguous results need
/// manual review in the media library.
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

  static AutoWork? decide({
    required String selectedRoot,
    required String relativePath,
    required bool rootHasDirectVideo,
    required String localRootName,
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
    var cursor = root;
    if (root.isNotEmpty && hasIdentity(path.posix.basename(root))) {
      markerFolder = root;
    }
    for (final folder in directories) {
      cursor = cursor.isEmpty ? folder : '$cursor/$folder';
      if (hasIdentity(folder)) markerFolder = cursor;
    }
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

    // The first child under a collection is normally the anime. Further
    // season, SP and BD folders remain attached to it.
    if (directories.isNotEmpty) {
      final pathParts = <String>[if (root.isNotEmpty) ...root.split('/')];
      for (final folder in directories) {
        pathParts.add(folder);
        if (isContainer(folder)) continue;
        if (isSubResource(folder)) return null;
        return AutoWork(pathParts.join('/'), needsReview: true);
      }
    }

    // Direct videos of an unlabelled root are not reliable to match.
    if (!knownGroup && rootName.isNotEmpty) {
      return AutoWork(root.isEmpty ? rootName : root, needsReview: true);
    }
    // Direct files in a collection/root must remain available for file-level
    // matching and manual review, rather than silently disappearing.
    return AutoWork(
      root.isEmpty ? '@unclassified' : '$root/@unclassified',
      needsReview: true,
    );
  }
}
