import 'package:path/path.dart' as p;

import 'cloud_media_asset_presentation.dart';
import 'cloud_media_file_classifier.dart';
import 'personal_filename_parser.dart';
import 'work_season.dart';

/// What a work folder contains, derived only from paths and sizes.
/// No network, no video reads. Pure and cheap enough to run on every scan.
enum WorkShape {
  /// One logical feature (movie / one-shot OVA), possibly several encodes.
  feature,

  /// Two or more logical episodes.
  series,

  /// Many unrelated titles in one folder; never auto-bind to one entry.
  anthology,

  /// No playable main content (only extras, or a sample/bonus folder).
  empty,
}

class LogicalItem {
  LogicalItem(this.key, this.title, this.episode, this.season);
  final String key, title;
  final int? episode, season;
  final List<String> files = [];

  /// Normalized series title of every encode merged into this item.
  final List<String> titles = [];
}

class DirectoryInventory {
  DirectoryInventory._({
    required this.folder,
    required this.title,
    required this.year,
    required this.tmdbId,
    required this.tmdbType,
    required this.bangumiId,
    required this.season,
    required this.folderMovieMarker,
    required this.fileMovieMarker,
    required this.main,
    required this.extras,
    required this.shape,
    required this.titleHints,
    required this.fileHints,
  });

  DirectoryInventory.synthetic({
    required String folder,
    required String title,
    int? year,
    int? tmdbId,
    String? tmdbType,
    int? bangumiId,
    int? season,
    bool folderMovieMarker = false,
    bool fileMovieMarker = false,
    required List<LogicalItem> main,
    List<String> extras = const [],
    required WorkShape shape,
    required List<String> titleHints,
    List<String> fileHints = const [],
  }) : this._(
         folder: folder,
         title: title,
         year: year,
         tmdbId: tmdbId,
         tmdbType: tmdbType,
         bangumiId: bangumiId,
         season: season,
         folderMovieMarker: folderMovieMarker,
         fileMovieMarker: fileMovieMarker,
         main: main,
         extras: extras,
         shape: shape,
         titleHints: titleHints,
         fileHints: fileHints,
       );

  final String folder, title;
  final int? year, tmdbId, bangumiId, season;
  final String? tmdbType;

  /// The user wrote 剧场版 / Movie in the folder name.
  final bool folderMovieMarker;

  /// Only filenames say movie (weaker evidence).
  final bool fileMovieMarker;
  final List<LogicalItem> main;
  final List<String> extras;
  final WorkShape shape;

  /// Folder-derived titles, highest trust first.
  final List<String> titleHints;

  /// Filename-derived titles (romaji / original / subtitles).
  final List<String> fileHints;

  Set<int> get episodes => {
    for (final item in main)
      if (item.episode != null) item.episode!,
  };
  int get episodeCount => episodes.length;
  int get featureCount => main.where((item) => item.episode == null).length;
  bool get movieMarker => folderMovieMarker || fileMovieMarker;

  DirectoryInventory withExplicitIds({
    int? tmdbId,
    String? tmdbType,
    int? bangumiId,
  }) => DirectoryInventory._(
    folder: folder,
    title: title,
    year: year,
    tmdbId: this.tmdbId ?? tmdbId,
    tmdbType: this.tmdbType ?? tmdbType,
    bangumiId: this.bangumiId ?? bangumiId,
    season: season,
    folderMovieMarker: folderMovieMarker,
    fileMovieMarker: fileMovieMarker,
    main: main,
    extras: extras,
    shape: shape,
    titleHints: titleHints,
    fileHints: fileHints,
  );

  @override
  String toString() =>
      '$shape "$title" y=$year eps=$episodeCount features=$featureCount '
      'tmdb=$tmdbType:$tmdbId bgm=$bangumiId hints=$titleHints files=$fileHints';
}

abstract final class DirectoryAnalyzer {
  static final _movieMarker = RegExp(
    r'剧场版|劇場版|映画|gekijou?ban|(?:^|[^a-z])(?:the[ ._-]+)?movie(?:[^a-z]|$)|'
    r'(?:^|[^a-z])film(?:[ ._-]*\d)?(?:[^a-z]|$)',
    caseSensitive: false,
  );
  static final _ovaMarker = RegExp(
    r'(?:^|[^a-z])(?:ova|oad|oav)(?:[^a-z]|$)',
    caseSensitive: false,
  );

  /// Unambiguous side content that is never the main feature, even alone.
  static final _unambiguousExtra = RegExp(
    r'(?<![a-z0-9])(?:nc(?:op|ed)\w*|pv\w*|cm\w*|menus?(?:[ ._-]*ex)?\d*|'
    r'trailers?\d*|teasers?\d*|previews?\d*|samples?\d*|drama[ ._-]*cd|'
    r'making|commentary|eyecatch|karaoke|'
    r'tv[ ._-]*cm|bd[ ._-]*cm|bd[ ._-]*menu\w*)(?![a-z0-9])|'
    r'[\[(【]\s*(?<![a-z0-9])(?:op|ed)\d*(?:v\d+)?(?![a-z0-9])\s*[\])】]|'
    r'予告|預告|预告|特報|メニュ|メイキング|映像特典|ノンクレ',
    caseSensitive: false,
  );

  /// Context-dependent extra words: extra alongside main episodes or when small,
  /// but a sole large feature (>= 150 MB) whose title touches "Event"/"Talk"/"MV"
  /// must not be wiped into [WorkShape.empty]. OP/ED is matched separately with
  /// strict alphanumeric boundaries via [CloudMediaFileClassifier.isOpEdExtra].
  static final _ambiguousExtra = RegExp(
    r'(?<![a-z0-9])(?:interviews?|events?|talk|radio|logo|gallery|advice|'
    r'mv|music[ ._-]*clip|spots?|info|supporters?|digest|recap)(?:[ ._-]*\d+)?(?![a-z0-9])|'
    r'インタビュー|イベント|トーク|ラジオ|特典|宣伝|スポット|座談会|上映会',
    caseSensitive: false,
  );

  static final _specialCollectionFolderSuffix = RegExp(
    r'^(.+?)(?:\s*[-–—_:：]\s*|\s+|[\s]*[\[(（【]\s*)'
    r'(?:extras?|specials|sps|特典|映像特典)(?:\s*[\])）】])?\s*$',
    caseSensitive: false,
  );

  /// Extracts the clean base title from a pure special-collection directory
  /// such as `<Title> Extras`, `<Title> Specials`, `<Title> SPs`, `<Title> 特典`,
  /// or `<Title> Extra`, while preserving proper work titles like `Extra Stage`.
  static String? _extractSpecialCollectionTitle(String cleanFolderTitle) {
    final match = _specialCollectionFolderSuffix.firstMatch(cleanFolderTitle);
    if (match == null) return null;
    final base = match.group(1)?.trim() ?? '';
    return base.isEmpty ? null : base;
  }

  static const _minStandaloneFeatureBytes = 150 * 1024 * 1024;
  static const _minEpisodeReferenceBytes = 100 * 1024 * 1024;
  static const _maxTinyClipBytes = 120 * 1024 * 1024;

  static final _technical = RegExp(
    r'(?:^|[\s._\-\[(])(?:(?:19|20)\d{2}[\s._-]+(?=.*\b\d{3,4}p\b)|'
    r'(?:480|576|720|1080|1440|2160|4320)[pi]\b|'
    r'(?:bd|uhd|web|dvd|hd)[ ._-]?(?:rip|dl|remux)\b|blu-?ray\b|remux\b|'
    r'\d{3,4}x\d{3,4}\b)',
    caseSensitive: false,
  );

  static final _bangumiMarker = RegExp(
    r'[\[{]\s*(?:bgm|bangumi)(?:id)?\s*[-=:_]\s*(\d+)\s*[\]}]',
    caseSensitive: false,
  );

  /// [files] are paths relative to [folder] (posix or windows separators).
  static DirectoryInventory analyze(
    String folder,
    Iterable<({String path, int? size})> files,
  ) {
    final normalizedFolder = folder.replaceAll('\\', '/');
    final name = p.posix.basename(normalizedFolder);
    final supplementaryFolder =
        CloudMediaFileClassifier.isSupplementaryDirectory(name);
    final rawCleanTitle = cleanTitle(name);
    final specialCollectionTitle = supplementaryFolder
        ? null
        : _extractSpecialCollectionTitle(rawCleanTitle);
    final title = specialCollectionTitle ?? rawCleanTitle;
    final main = <String, LogicalItem>{};
    var soft = <({String path, int? size, bool ambiguous})>[];
    final extras = <String>[];
    final videoEntries = [
      for (final f in files)
        if (_isVideo(f.path))
          (path: f.path.replaceAll('\\', '/'), size: f.size),
    ];
    final sizeByPath = <String, int>{
      for (final v in videoEntries)
        if (v.size != null && v.size! > 0) v.path: v.size!,
    };

    for (final entry in videoEntries) {
      final path = entry.path;
      final file = p.posix.basename(path);
      final directory = p.posix.dirname(path) == '.'
          ? ''
          : p.posix.dirname(path);
      final cleanFile = CloudMediaFileClassifier.stripTechnicalNoise(file);
      final plainFile = _plain(file);
      if (supplementaryFolder ||
          CloudMediaFileClassifier.isSupplementaryDirectory(directory) ||
          _unambiguousExtra.hasMatch(plainFile) ||
          CloudMediaFileClassifier.isPreview(cleanFile) ||
          CloudMediaFileClassifier.isNoCredit(cleanFile)) {
        extras.add(path);
      } else if (_ambiguousExtra.hasMatch(plainFile) ||
          CloudMediaFileClassifier.isOpEdExtra(cleanFile)) {
        soft.add((path: path, size: entry.size, ambiguous: true));
      } else if (CloudMediaFileClassifier.isClearlySupplementary(
        directory,
        cleanFile,
      )) {
        soft.add((path: path, size: entry.size, ambiguous: false));
      } else {
        _add(main, directory, file, path);
      }
    }
    if (specialCollectionTitle != null) {
      // Pure special-collection directories (e.g., "<Title> Extras/Specials/SPs")
      // map non-OP/ED soft items into main so Season 0 matching can pair them.
      for (final item in soft) {
        final file = p.posix.basename(item.path);
        if (CloudMediaFileClassifier.isOpEdExtra(file)) {
          extras.add(item.path);
          continue;
        }
        final directory = p.posix.dirname(item.path) == '.'
            ? ''
            : p.posix.dirname(item.path);
        _add(main, directory, file, item.path, promoted: true);
      }
    } else {
      soft = _protectContiguousMainEpisodes(
        main,
        soft,
        supplementaryFolder: supplementaryFolder,
      );
      // OVA / special-edition / extra-stage folders: their "specials" are the
      // work. Trailers and menus never get promoted; ambiguous extra words only
      // promote when backed by main-feature file size (>= 150 MB).
      if (main.isEmpty && !supplementaryFolder) {
        for (final item in soft) {
          if (item.ambiguous &&
              (item.size == null || item.size! < _minStandaloneFeatureBytes)) {
            extras.add(item.path);
            continue;
          }
          final directory = p.posix.dirname(item.path) == '.'
              ? ''
              : p.posix.dirname(item.path);
          _add(
            main,
            directory,
            p.posix.basename(item.path),
            item.path,
            promoted: true,
          );
        }
      } else {
        for (final item in soft) {
          extras.add(item.path);
        }
        // Demote unnumbered tiny clips (< 20% of median episode size and < 120 MB)
        // when mixed into a real multi-episode BDRip folder.
        final epSizes = [
          for (final item in main.values)
            if (item.episode != null)
              for (final f in item.files)
                if (sizeByPath.containsKey(f)) sizeByPath[f]!,
        ]..sort();
        if (epSizes.length >= 3) {
          final median = epSizes[epSizes.length ~/ 2];
          if (median >= _minEpisodeReferenceBytes) {
            final demoteKeys = <String>[];
            for (final entry in main.entries) {
              if (entry.value.episode != null) continue;
              final itemSizes = [
                for (final f in entry.value.files)
                  if (sizeByPath.containsKey(f)) sizeByPath[f]!,
              ];
              if (itemSizes.isNotEmpty &&
                  itemSizes.length == entry.value.files.length &&
                  itemSizes.every(
                    (s) => s < median * 0.2 && s < _maxTinyClipBytes,
                  )) {
                demoteKeys.add(entry.key);
              }
            }
            for (final key in demoteKeys) {
              extras.addAll(main.remove(key)!.files);
            }
          }
        }
      }
    }

    var items = main.values.toList();
    // A single numbered file is a numbered title (Legend 01, Movie 3, #02),
    // not episode N of a series, unless it carries an explicit episodic marker
    // (SxxExx, EPxx, 第x話, or 02v2 revision).
    final numbered = items.where((i) => i.episode != null).toList();
    if (numbered.length == 1 &&
        !RegExp(
          r'(?<![a-z0-9])(?:s\d{1,2}[ ._-]*e\d{1,4}|ep[ ._-]*\d{1,4}|\d{1,3}v\d+)\b|'
          r'第\s*\d{1,3}\s*[话話集]',
          caseSensitive: false,
        ).hasMatch(numbered.single.files.first)) {
      final only = numbered.single;
      final core = versionKey(p.posix.basename(only.files.first));
      final feature = LogicalItem('f:$core', core, null, only.season)
        ..files.addAll(only.files)
        ..titles.add(core);
      items = [for (final i in items) identical(i, only) ? feature : i];
    }

    bool meaningful(String title) =>
        title.length >= 3 && !RegExp(r'^[0-9a-f]{6,8}$').hasMatch(title);
    final episodeTitles = {
      for (final i in items)
        if (i.episode != null) ...i.titles.where(meaningful),
    };
    final featureTitles = {
      for (final i in items)
        if (i.episode == null) i.title,
    };
    // One dominant series with side content (digests, recap shorts) is still
    // that series; anthology needs several comparable runs.
    final perSeries = <String, int>{};
    for (final item in items.where((i) => i.episode != null)) {
      for (final title in item.titles.where(meaningful)) {
        perSeries.update(title, (n) => n + 1, ifAbsent: () => 1);
      }
    }
    final episodic = perSeries.values.fold<int>(0, (a, b) => a + b);
    final dominant = perSeries.values.fold<int>(0, (a, b) => a > b ? a : b);
    final WorkShape shape;
    if (items.isEmpty) {
      shape = WorkShape.empty;
    } else if (specialCollectionTitle == null &&
        (episodeTitles.length >= 4 && dominant < episodic * 0.5 ||
            featureTitles.length >= 6 &&
                featureTitles.length > episodeTitles.length * 4 &&
                items.where((i) => i.episode != null).length < 6)) {
      // Many unrelated series or films (e.g. SD Gundam Mk1..Mk5 + Gaiden).
      shape = WorkShape.anthology;
    } else if (items.any((i) => i.episode != null)) {
      shape = WorkShape.series;
    } else {
      shape = WorkShape.feature;
    }

    final fileHints = <String>[];
    void hint(List<String> target, String value) {
      final text = value.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (text.length < 2 || RegExp(r'^\d+$').hasMatch(text)) return;
      final key = normalize(text);
      if (key.length < 2 ||
          RegExp(r'^[0-9a-f]{6,8}$').hasMatch(key) ||
          target.any((existing) => normalize(existing) == key) ||
          target.length >= 8) {
        return;
      }
      target.add(text);
    }

    final allMain = items.expand((i) => i.files).map(p.posix.basename).toList();
    final folderMovie = _movieMarker.hasMatch(name);
    final fileMovie =
        shape == WorkShape.feature &&
        allMain.any((f) => _movieMarker.hasMatch(_plain(f)));
    final isSeries = shape == WorkShape.series && !folderMovie && !fileMovie;

    int? inferredSeason = specialCollectionTitle != null
        ? 0
        : WorkSeason.explicit({'title': name});
    final titleHints = <String>[];
    hint(titleHints, title);
    final folderSplit = splitSeasonSuffix(title, isSeries: isSeries);
    inferredSeason ??= folderSplit.season;
    if (folderSplit.baseTitle != title) {
      hint(titleHints, folderSplit.baseTitle);
    }
    final withoutMarker = title
        .replaceAll(
          RegExp(r'剧场版|劇場版|\bOVA\b|\bOAD\b', caseSensitive: false),
          ' ',
        )
        .trim();
    hint(titleHints, withoutMarker);
    // Collapse counts by frequency: the dominant filename title first.
    final counts = <String, int>{};
    for (final item in items) {
      for (final file in item.files) {
        for (final candidate in _fileTitles(
          p.posix.basename(file),
          item.episode,
        )) {
          counts.update(candidate, (n) => n + 1, ifAbsent: () => 1);
        }
      }
    }
    final ranked = counts.keys.toList()
      ..sort((a, b) => counts[b]!.compareTo(counts[a]!));
    if (ranked.isNotEmpty) {
      final dominantFile = ranked.first;
      inferredSeason ??= CloudMediaAssetPresentation.explicitSeasonNumber({
        'work_title': dominantFile,
      });
      final domSplit = splitSeasonSuffix(dominantFile, isSeries: isSeries);
      inferredSeason ??= domSplit.season;
    }
    for (final value in ranked) {
      hint(fileHints, value);
      final split = splitSeasonSuffix(value, isSeries: isSeries);
      if (split.baseTitle != value) {
        hint(fileHints, split.baseTitle);
      }
    }

    final folderYear = WorkSeason.year({'title': name});
    int? fileYear;
    if (folderYear == null && shape == WorkShape.feature) {
      final years = {
        for (final file in allMain)
          ?int.tryParse(
            RegExp(
                  r'[(\[ ._]((?:19|20)\d{2})[)\] ._]',
                ).firstMatch(file)?.group(1) ??
                '',
          ),
      };
      if (years.length == 1) fileYear = years.single;
    }
    var tmdbId = PersonalFilenameParser.tmdbId(name);
    var tmdbType = PersonalFilenameParser.tmdbType(name);
    if (tmdbId == null && allMain.isNotEmpty) {
      final fileTmdb = {
        for (final f in allMain) ?PersonalFilenameParser.tmdbId(f),
      };
      if (fileTmdb.length == 1) {
        tmdbId = fileTmdb.single;
        final fileTypes = {
          for (final f in allMain) ?PersonalFilenameParser.tmdbType(f),
        };
        if (fileTypes.length == 1) tmdbType = fileTypes.single;
      }
    }
    final bangumi = _bangumiMarker.firstMatch(name);
    var bangumiId = bangumi == null ? null : int.tryParse(bangumi.group(1)!);
    if (bangumiId == null && allMain.isNotEmpty) {
      final fileBgm = {
        for (final f in allMain)
          ?int.tryParse(_bangumiMarker.firstMatch(f)?.group(1) ?? ''),
      };
      if (fileBgm.length == 1) bangumiId = fileBgm.single;
    }
    return DirectoryInventory._(
      folder: normalizedFolder,
      title: title,
      year: folderYear ?? fileYear,
      tmdbId: tmdbId,
      tmdbType: tmdbType,
      bangumiId: bangumiId,
      season: inferredSeason,
      folderMovieMarker: folderMovie,
      fileMovieMarker: fileMovie,
      main: items,
      extras: extras,
      shape: shape,
      titleHints: titleHints,
      fileHints: fileHints,
    );
  }

  /// Splits trailing season/sequel suffixes into `(baseTitle, season)` so
  /// search queries include the clean base title while `WorkMatcher` receives
  /// the season signal (e.g. `Mob Psycho 100 II` -> base `Mob Psycho 100`, S2).
  static ({String baseTitle, int? season}) splitSeasonSuffix(
    String raw, {
    required bool isSeries,
  }) {
    final trimmed = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (trimmed.length < 3) return (baseTitle: trimmed, season: null);

    // 1. Explicit Season N / Nnd Season / S2 / 第N期 / 第N季 at tail.
    final explicitTail = RegExp(
      r'^(.*?S?)\s*(?:[:：\-–—~～]\s*|\s+)'
      r'(?:Season[ ._-]*(\d{1,2})|(\d{1,2})(?:st|nd|rd|th)[ ._-]+Season|'
      r'S0*(\d{1,2})|第[ ._-]*([0-9一二三四五六七八九十两]+)[ ._-]*[季期])\s*$',
      caseSensitive: false,
    ).firstMatch(trimmed);
    if (explicitTail != null) {
      final base = explicitTail.group(1)!.trim();
      final season = CloudMediaAssetPresentation.explicitSeasonNumber({
        'work_title': trimmed.substring(explicitTail.group(1)!.length),
      });
      if (base.length >= 2 && season != null) {
        return (baseTitle: base, season: season);
      }
    }

    if (!isSeries) return (baseTitle: trimmed, season: null);

    // 2. Trailing Roman numeral season (II / III / IV / Ⅱ / Ⅲ / Ⅳ) on series,
    //    excluding technical/mecha model designators (Mk-II, Mark II, Type II, Part II).
    final romanTail = RegExp(
      r'^(.+?)\s+(II|III|IV|Ⅱ|Ⅲ|Ⅳ)$',
      caseSensitive: false,
    ).firstMatch(trimmed);
    if (romanTail != null) {
      final base = romanTail.group(1)!.trim();
      final badPrefix = RegExp(
        r'(?:^|\s)(?:mk|mark|type|part|vol\.?|act|stage|episode|ep|ver\.?|movie|film|chapter)[- ]*$',
        caseSensitive: false,
      ).hasMatch(base);
      if (!badPrefix && base.length >= 2) {
        final token = romanTail.group(2)!.toUpperCase();
        final season = switch (token) {
          'II' || 'Ⅱ' => 2,
          'III' || 'Ⅲ' => 3,
          'IV' || 'Ⅳ' => 4,
          _ => null,
        };
        if (season != null) return (baseTitle: base, season: season);
      }
    }

    return (baseTitle: trimmed, season: null);
  }

  static bool isOva(DirectoryInventory inventory) =>
      _ovaMarker.hasMatch(inventory.folder) ||
      inventory.main.any((i) => i.files.any((f) => _ovaMarker.hasMatch(f)));

  /// Preserves main-directory numbered episodes whose weak bracketed/recap notes
  /// would otherwise demote them out of a contiguous 1..N integer sequence.
  static List<({String path, int? size, bool ambiguous})>
  _protectContiguousMainEpisodes(
    Map<String, LogicalItem> main,
    List<({String path, int? size, bool ambiguous})> soft, {
    required bool supplementaryFolder,
  }) {
    if (supplementaryFolder || soft.isEmpty || main.isEmpty) return soft;
    final mainEpisodes = <int>{
      for (final item in main.values)
        if (item.episode != null && item.episode! >= 1) item.episode!,
    };
    if (mainEpisodes.length < 2) return soft;

    final candidates =
        <
          int,
          ({String path, int? size, bool ambiguous, String dir, String file})
        >{};
    final kept = <({String path, int? size, bool ambiguous})>[];

    for (final item in soft) {
      final path = item.path;
      final dir = p.posix.dirname(path) == '.' ? '' : p.posix.dirname(path);
      final file = p.posix.basename(path);
      if (CloudMediaFileClassifier.isStrongSupplementary(dir, file)) {
        kept.add(item);
        continue;
      }
      final cleanStem = PersonalFilenameParser.baseNameWithoutExtension(
        CloudMediaFileClassifier.stripTechnicalNoise(file),
      );
      var ep = CloudMediaFileClassifier.episodeNumberFromNameInDirectory(
        dir,
        file,
      );
      if (ep == null) {
        final fallback = RegExp(
          r'(?:^|[\s\]】)])[-–—]\s*(\d{1,3})\s+'
          r'(?:recap|summary|digest|special|総集編|総集篇|总集篇|特別編|特别篇)',
          caseSensitive: false,
        ).firstMatch(cleanStem);
        ep = fallback == null ? null : int.tryParse(fallback.group(1)!);
      }
      if (ep == null ||
          ep < 1 ||
          mainEpisodes.contains(ep) ||
          candidates.containsKey(ep) ||
          RegExp(
            '(?<![a-z0-9])(?:sp|special|ova|oad|ex|bonus)[ ._-]*0*$ep(?![0-9])',
            caseSensitive: false,
          ).hasMatch(cleanStem)) {
        kept.add(item);
        continue;
      }
      candidates[ep] = (
        path: item.path,
        size: item.size,
        ambiguous: item.ambiguous,
        dir: dir,
        file: file,
      );
    }

    if (candidates.isEmpty) return soft;

    final union = <int>{...mainEpisodes, ...candidates.keys};
    final minMain = mainEpisodes.reduce((a, b) => a < b ? a : b);
    for (final entry in candidates.entries) {
      final ep = entry.key;
      var start = ep;
      while (union.contains(start - 1)) {
        start--;
      }
      var end = ep;
      while (union.contains(end + 1)) {
        end++;
      }
      var mainInRun = 0;
      for (var i = start; i <= end; i++) {
        if (mainEpisodes.contains(i)) mainInRun++;
      }
      final contiguousWithMainRun =
          end - start + 1 >= 3 &&
          mainInRun >= 2 &&
          (start == 1 || start <= minMain);
      if (contiguousWithMainRun) {
        _add(
          main,
          entry.value.dir,
          entry.value.file,
          entry.value.path,
          promoted: true,
          episodeOverride: ep,
        );
      } else {
        kept.add((
          path: entry.value.path,
          size: entry.value.size,
          ambiguous: entry.value.ambiguous,
        ));
      }
    }
    return kept;
  }

  static void _add(
    Map<String, LogicalItem> main,
    String directory,
    String file,
    String path, {
    bool promoted = false,
    int? episodeOverride,
  }) {
    final episode =
        episodeOverride ??
        CloudMediaFileClassifier.episodeNumberFromNameInDirectory(
          directory,
          file,
        );
    final season = RegExp(
      r'(?<![a-z0-9])s(\d{1,2})(?:[ ._-]*e\d{1,4}|[ ._-]+-)',
      caseSensitive: false,
    ).firstMatch(file);
    final core = versionKey(file);
    final title = episode == null
        ? core
        : normalize(
            seriesTitle(
              PersonalFilenameParser.extractAnimeSearchKeyword(file),
              episode,
              rawFile: file,
            ),
          );
    // Encodes of one episode collapse on (season, number); the series title
    // is kept for anthology detection and hints only.
    final key = episode == null
        ? 'f:$core'
        : 'e:${season?.group(1) ?? ''}:$episode';
    (main[key] ??= LogicalItem(
        key,
        title,
        episode,
        season == null ? null : int.parse(season.group(1)!),
      ))
      ..files.add(path)
      ..titles.add(title);
  }

  /// Text before the episode number: "Wake Up, Girls! 10" -> "Wake Up, Girls!",
  /// "キノの旅 #03 予言の国" -> "キノの旅", "SD Gundam Mk3 - Episode 01" ->
  /// "SD Gundam Mk3", while preserving numeric titles ("86", "Mob Psycho 100",
  /// "Steins;Gate 0") when the right-side episode token was already stripped.
  static String seriesTitle(String keyword, int? episode, {String? rawFile}) {
    var value = keyword;
    if (episode != null) {
      final hash = value.indexOf(RegExp(r'[#＃]'));
      if (hash > 0) value = value.substring(0, hash);
      final epPattern = RegExp('(?<![0-9A-Za-z.])0*$episode(?![0-9.])');
      final inKeyword = epPattern.allMatches(value).length;
      final alreadyStripped =
          rawFile != null &&
          inKeyword > 0 &&
          epPattern
                  .allMatches(
                    PersonalFilenameParser.baseNameWithoutExtension(rawFile),
                  )
                  .length >
              inKeyword;
      if (!alreadyStripped) {
        final number = epPattern
            .allMatches(value)
            .where((m) => m.start > 0)
            .firstOrNull;
        if (number != null) value = value.substring(0, number.start);
      }
    }
    value = value
        .replaceFirst(
          RegExp(
            r'(?:[\s._\-–—]+(?:episode|ep\.?|vol\.?)|第)?[\s._\-–—]*$',
            caseSensitive: false,
          ),
          '',
        )
        .trim();
    return value.isEmpty ? keyword : value;
  }

  /// Same work, different encode: drop brackets, parentheses and every token
  /// from the first resolution / source / year-before-resolution onward.
  static String versionKey(String file) {
    var base = PersonalFilenameParser.baseNameWithoutExtension(file);
    final withoutBlocks = base
        .replaceAll(RegExp(r'\[[^\]]*\]|【[^】]*】|\([^)]*\)|（[^）]*）'), ' ')
        .replaceAll(RegExp(r'[._]+'), ' ');
    final cut = _technical.firstMatch(withoutBlocks);
    var core = cut == null
        ? withoutBlocks
        : withoutBlocks.substring(0, cut.start);
    core = core.replaceAll(
      RegExp(
        r'\b(?:sdr|hdr\d*|uhd|v\d|rev|x26[45]|hevc|avc|flac|aac|chs|cht)\b',
        caseSensitive: false,
      ),
      ' ',
    );
    var key = normalize(core);
    if (key.isEmpty) {
      key = normalize(
        PersonalFilenameParser.bracketTitleCandidates(file).join(' '),
      );
    }
    if (key.isEmpty) {
      key = normalize(PersonalFilenameParser.extractAnimeSearchKeyword(file));
    }
    return key.isEmpty ? normalize(base) : key;
  }

  static Iterable<String> _fileTitles(String file, int? episode) sync* {
    final keyword = PersonalFilenameParser.extractAnimeSearchKeyword(file);
    if (keyword.isNotEmpty) {
      if (episode == null) {
        final movieClean = keyword
            .replaceAll(RegExp(r'[#＃]\s*\d{1,3}\b'), ' ')
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
        yield _trimTechnical(movieClean);
        final withoutPart = movieClean
            .replaceAll(
              RegExp(r'\b(?:前篇|後篇|后篇|中篇|前編|後編)\b|(?:前篇|後篇|后篇|中篇|前編|後編)'),
              ' ',
            )
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
        if (withoutPart.isNotEmpty && withoutPart != movieClean) {
          yield _trimTechnical(withoutPart);
        }
      }
      yield _trimTechnical(seriesTitle(keyword, episode, rawFile: file));
    }
    for (final block in PersonalFilenameParser.bracketTitleCandidates(file)) {
      yield block.replaceAll('_', ' ');
    }
    final stripped = PersonalFilenameParser.withoutKnownReleaseGroups(file);
    if (stripped != null) {
      final value = PersonalFilenameParser.extractAnimeSearchKeyword(stripped);
      if (value.isNotEmpty) yield _trimTechnical(seriesTitle(value, episode));
    }
  }

  static String _trimTechnical(String value) {
    final cut = _technical.firstMatch(value);
    var result = cut == null ? value : value.substring(0, cut.start);
    result = result.replaceAll(
      RegExp(
        r'[\s._-]+(?:19|20)\d{2}$|[\s._-]+(?:movie|ova)$',
        caseSensitive: false,
      ),
      '',
    );
    return result.trim().isEmpty ? value : result.trim();
  }

  static String _plain(String file) =>
      PersonalFilenameParser.baseNameWithoutExtension(
        CloudMediaFileClassifier.stripTechnicalNoise(file),
      ).replaceAll(RegExp(r'[._]+'), ' ');

  static bool _isVideo(String path) => RegExp(
    r'\.(?:mkv|mp4|avi|m2ts|ts|webm|mov|wmv)$',
    caseSensitive: false,
  ).hasMatch(path);

  /// Folder name without provider markers, years and bracketed tags.
  static String cleanTitle(String folderName) {
    var title = PersonalFilenameParser.withoutTmdbMarkers(folderName)
        .replaceAll(_bangumiMarker, ' ')
        .replaceAll(RegExp(r'[(（]\s*(?:19|20)\d{2}\s*[)）]'), ' ')
        .replaceAll(RegExp(r'\{[^}]*\}'), ' ');
    title = title.replaceAll(RegExp(r'\s+'), ' ').trim();
    return title.isEmpty ? folderName : title;
  }

  static const _roman = {
    'Ⅰ': 'i',
    'Ⅱ': 'ii',
    'Ⅲ': 'iii',
    'Ⅳ': 'iv',
    'Ⅴ': 'v',
    'Ⅵ': 'vi',
    'Ⅶ': 'vii',
    'Ⅷ': 'viii',
    'Ⅸ': 'ix',
    'Ⅹ': 'x',
  };

  /// Comparison key: width-folded, lower-case, punctuation-free, and numbers
  /// without leading zeros ("Legend 01" == "Legend 1").
  static String normalize(String value) {
    final buffer = StringBuffer();
    for (final rune in value.runes) {
      if (rune >= 0xFF01 && rune <= 0xFF5E) {
        buffer.writeCharCode(rune - 0xFEE0);
      } else if (rune == 0x3000) {
        buffer.write(' ');
      } else {
        final char = String.fromCharCode(rune);
        buffer.write(_roman[char] ?? char);
      }
    }
    return buffer
        .toString()
        .toLowerCase()
        .replaceAll(RegExp(r'(?<!\d)0+(?=\d)'), '')
        .replaceAll(
          RegExp(
            r'''[\s\-_—–~～〜:：.,，、;；!！?？・·•'’‘"“”()（）\[\]【】{}「」『』<>《》/\\|&＆+＋*☆★♪]''',
          ),
          '',
        );
  }
}
