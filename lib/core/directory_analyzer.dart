import 'package:path/path.dart' as p;

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

  /// Side content that is never the work itself, even when nothing else exists.
  static final _hardExtra = RegExp(
    r'(?:^|[^a-z])(?:nc(?:op|ed)\w*|op|ed|pv\w*|cm\w*|menus?|trailers?|teasers?|'
    r'previews?|samples?|drama[ ._-]*cd|making|interviews?|events?|talk|'
    r'radio|karaoke|logo|eyecatch|gallery|advice|mv|music[ ._-]*clip|'
    r'spots?|tv[ ._-]*cm|bd[ ._-]*cm|bd[ ._-]*menu|info|commentary|'
    r'supporters?|digest|recap)(?:\d+|[^a-z]|$)|'
    r'予告|預告|预告|特報|メニュ|インタビュー|メイキング|イベント|トーク|'
    r'ラジオ|映像特典|特典|宣伝|スポット|ノンクレ|座談会|上映会',
    caseSensitive: false,
  );

  static final _technical = RegExp(
    r'(?:^|[\s._\-\[(])(?:(?:19|20)\d{2}[\s._-]+(?=.*\b\d{3,4}p\b)|'
    r'(?:480|576|720|1080|1440|2160|4320)[pi]\b|'
    r'(?:bd|uhd|web|dvd|hd)[ ._-]?(?:rip|dl|remux)\b|blu-?ray\b|remux\b|'
    r'\d{3,4}x\d{3,4}\b)',
    caseSensitive: false,
  );

  static final _bangumiMarker = RegExp(
    r'[\[{]\s*(?:bgm|bangumi)(?:id)?\s*[-=:]\s*(\d+)\s*[\]}]',
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
    final title = cleanTitle(name);
    final main = <String, LogicalItem>{};
    final soft = <String>[];
    final extras = <String>[];
    final videos = files
        .map((f) => f.path.replaceAll('\\', '/'))
        .where(_isVideo)
        .toList();

    for (final path in videos) {
      final file = p.posix.basename(path);
      final directory = p.posix.dirname(path) == '.'
          ? ''
          : p.posix.dirname(path);
      if (supplementaryFolder ||
          CloudMediaFileClassifier.isSupplementaryDirectory(directory) ||
          _hardExtra.hasMatch(_plain(file)) ||
          CloudMediaFileClassifier.isPreview(file) ||
          CloudMediaFileClassifier.isNoCredit(file)) {
        extras.add(path);
      } else if (CloudMediaFileClassifier.isClearlySupplementary(
        directory,
        file,
      )) {
        soft.add(path);
      } else {
        _add(main, directory, file, path);
      }
    }
    // OVA / special-edition / extra-stage folders: their "specials" are the
    // work. Trailers and menus never get promoted.
    if (main.isEmpty && !supplementaryFolder) {
      for (final path in soft) {
        final directory = p.posix.dirname(path) == '.'
            ? ''
            : p.posix.dirname(path);
        _add(main, directory, p.posix.basename(path), path, promoted: true);
      }
    } else {
      extras.addAll(soft);
    }

    var items = main.values.toList();
    // A single numbered file is a numbered title (Legend 01, Movie 3, #02),
    // not episode N of a series, unless it carries an explicit SxxExx marker.
    final numbered = items.where((i) => i.episode != null).toList();
    if (numbered.length == 1 &&
        !RegExp(
          r'(?<![a-z0-9])s\d{1,2}[ ._-]*e\d{1,4}',
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
    } else if (episodeTitles.length >= 4 && dominant < episodic * 0.5 ||
        featureTitles.length >= 6 &&
            featureTitles.length > episodeTitles.length * 4 &&
            items.where((i) => i.episode != null).length < 6) {
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

    final titleHints = <String>[];
    hint(titleHints, title);
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
    for (final value in ranked) {
      hint(fileHints, value);
    }

    final allMain = items.expand((i) => i.files).map(p.posix.basename);
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
    final bangumi = _bangumiMarker.firstMatch(name);
    return DirectoryInventory._(
      folder: normalizedFolder,
      title: title,
      year: folderYear ?? fileYear,
      tmdbId: PersonalFilenameParser.tmdbId(name),
      tmdbType: PersonalFilenameParser.tmdbType(name),
      bangumiId: bangumi == null ? null : int.tryParse(bangumi.group(1)!),
      season: WorkSeason.explicit({'title': name}),
      folderMovieMarker: _movieMarker.hasMatch(name),
      fileMovieMarker:
          shape == WorkShape.feature &&
          allMain.any((f) => _movieMarker.hasMatch(_plain(f))),
      main: items,
      extras: extras,
      shape: shape,
      titleHints: titleHints,
      fileHints: fileHints,
    );
  }

  static bool isOva(DirectoryInventory inventory) =>
      _ovaMarker.hasMatch(inventory.folder) ||
      inventory.main.any((i) => i.files.any((f) => _ovaMarker.hasMatch(f)));

  static void _add(
    Map<String, LogicalItem> main,
    String directory,
    String file,
    String path, {
    bool promoted = false,
  }) {
    final episode = CloudMediaFileClassifier.episodeNumberFromNameInDirectory(
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
  /// "SD Gundam Mk3".
  static String seriesTitle(String keyword, int? episode) {
    var value = keyword;
    final hash = value.indexOf(RegExp(r'[#＃]'));
    if (hash > 0) value = value.substring(0, hash);
    if (episode != null) {
      final number = RegExp(
        '(?<![0-9A-Za-z.])0*$episode(?![0-9.])',
      ).allMatches(value).where((m) => m.start > 0).firstOrNull;
      if (number != null) value = value.substring(0, number.start);
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
    if (keyword.isNotEmpty) yield _trimTechnical(seriesTitle(keyword, episode));
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
        file,
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
