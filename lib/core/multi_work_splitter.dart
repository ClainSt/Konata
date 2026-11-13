import 'package:path/path.dart' as p;

import 'cloud_media_asset_presentation.dart';
import 'cloud_media_file_classifier.dart';
import 'directory_analyzer.dart';
import 'personal_filename_parser.dart';

class SplitAssetAssignment {
  const SplitAssetAssignment({
    required this.assetId,
    required this.relativePath,
    required this.category,
    required this.season,
    this.episode,
    this.extraType,
  });

  final String assetId;
  final String relativePath;
  final String category;
  final int season;
  final int? episode;
  final String? extraType;
}

class SubWorkCluster {
  const SubWorkCluster({
    required this.slug,
    required this.virtualFolder,
    required this.inventory,
    required this.assignments,
  });

  final String slug;
  final String virtualFolder;
  final DirectoryInventory inventory;
  final List<SplitAssetAssignment> assignments;
}

/// Deterministic local clustering for collection directories containing multiple
/// installments (e.g. `Movie & OVA`, `TV+Movie`, `Work A & Work B`, or multi-part
/// theatrical/arc folders). Never performs network or stream I/O.
abstract final class MultiWorkSplitter {
  static final _explicitJoiner = RegExp(r'\s+[&＆＋]\s+');
  static final _multiKindFolder = RegExp(
    r'(?<![a-z0-9])(?:tv\s*[+&＆＋]\s*(?:movie|ova|剧场版|劇場版)s?|'
    r'(?:movie|ova)s?\s*[+&＆＋]\s*(?:tv|ova|movie|剧场版|劇場版)s?)(?![a-z0-9])',
    caseSensitive: false,
  );
  static final _seasonJoiner = RegExp(
    r'(?<![a-z0-9])s\d{1,2}\s*[+&~～\-–—]\s*s?\d{1,2}(?![a-z0-9])',
    caseSensitive: false,
  );
  static final _pureSideToken = RegExp(
    r'(?<![a-z0-9])(?:ncoped|ncop|nced|pvcm|tv[ ._-]*cm|bd[ ._-]*cm|cm|pv|'
    r'menus?(?:[ ._-]*ex)?\d*|bd[ ._-]*menu\w*|trailer|teaser|preview|'
    r'tv[ ._-]*spot|spot|making|digest|interview|iv\d+|commentary|'
    r'creditless|textless|appendix|sample|hyakka)(?:[ ._-]*\d+[a-z]?)?'
    r'(?![a-z0-9])|'
    r'予告|預告|预告|特報|メイキング|ダイジェスト|総集編|总集篇|メニュ[ー一]|百科',
    caseSensitive: false,
  );
  static final _quoteBlock = RegExp(r'「([^」]+)」|『([^』]+)』');
  static final _movieToken = RegExp(
    r'(?<![a-z0-9])(?:the[ ._-]+)?movie(?![a-z0-9])|劇場版|剧场版|映画',
    caseSensitive: false,
  );
  static final _ovaToken = RegExp(
    r'(?<![a-z0-9])(?:ova|oad)(?![a-z0-9])',
    caseSensitive: false,
  );
  static final _movieSubdir = RegExp(
    r'(?:^|/)(?:movies?|劇場版|剧场版|films?|theatrical)(?:/|$)',
    caseSensitive: false,
  );
  static final _romanFeaturePart = RegExp(
    r'^(.+?)\s+(I|II|III|IV|V|Ⅰ|Ⅱ|Ⅲ|Ⅳ)\s+(.+)$',
  );
  static final _exTagPattern = RegExp(
    r'(?:[\[(（【]\s*|(?<![a-z0-9]))(ex[ ._-]*\d{1,2})(?=\s*[\])）】]|(?![a-z0-9]))',
    caseSensitive: false,
  );
  static final _hdRemasterPattern = RegExp(
    r'\bhd\s*remaster(?:\s*\d{4})?\b|hd\s*重[制製]版',
    caseSensitive: false,
  );
  static final _genericStandaloneStem = RegExp(
    r'^(?:ep(?:isode)?|part|vol(?:ume)?|movie|film|ova|oad|sp|special|ex)?'
    r'[\s._-]*\d{0,4}$',
    caseSensitive: false,
  );

  static bool isExplicitCollectionFolder(
    String folder,
    DirectoryInventory inventory,
  ) {
    if (inventory.shape == WorkShape.anthology) return true;
    final leaf = folder
        .replaceAll('\\', '/')
        .split('/')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .lastOrNull;
    if (leaf == null || leaf.isEmpty) return false;
    if (_seasonJoiner.hasMatch(leaf) && !_explicitJoiner.hasMatch(leaf)) {
      return false;
    }
    return _multiKindFolder.hasMatch(leaf) || _explicitJoiner.hasMatch(leaf);
  }

  static List<SubWorkCluster> split(
    String folder,
    List<Map<String, Object?>> assets,
  ) {
    final editable = assets.where((a) => a['manual_mapping'] != true).toList();
    if (editable.length < 2) return const [];

    final normFolder = folder
        .replaceAll('\\', '/')
        .replaceAll(RegExp(r'^/+|/+$'), '');
    final leafRaw =
        normFolder.split('/').where((s) => s.isNotEmpty).lastOrNull ?? '';
    final folderTmdbId = PersonalFilenameParser.tmdbId(leafRaw);
    final folderTmdbType = PersonalFilenameParser.tmdbType(leafRaw);
    final leafClean = PersonalFilenameParser.withoutTmdbMarkers(leafRaw)
        .replaceAll(
          RegExp(r'\(\s*(?:19|20)\d{2}\s*\)|（\s*(?:19|20)\d{2}\s*）'),
          ' ',
        )
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final stemInfo = _extractFranchiseStems(normFolder, leafClean);
    final explicitSegments = _extractExplicitSegments(leafClean);

    final mainFiles = <_FileEntry>[];
    final extraFiles = <_FileEntry>[];
    final maxSize = editable.fold<int>(
      0,
      (m, a) => ((a['size'] as num?)?.toInt() ?? 0) > m
          ? (a['size'] as num).toInt()
          : m,
    );

    for (final asset in editable) {
      final rel = (asset['relative_path'] ?? asset['name'] ?? '')
          .toString()
          .replaceAll('\\', '/');
      final name = (asset['name'] ?? p.posix.basename(rel)).toString();
      final subPath = normFolder.isNotEmpty && rel.startsWith('$normFolder/')
          ? rel.substring(normFolder.length + 1)
          : rel;
      final dirPart = p.posix.dirname(subPath);
      final subDir = dirPart == '.' ? '' : dirPart;
      final size = (asset['size'] as num?)?.toInt() ?? 0;

      final cleanName = CloudMediaFileClassifier.stripTechnicalNoise(name);
      final inSuppDir =
          subDir.isNotEmpty &&
          CloudMediaFileClassifier.isSupplementaryDirectory(subDir);
      final isPureSide =
          inSuppDir ||
          CloudMediaFileClassifier.isPreview(cleanName) ||
          CloudMediaFileClassifier.isNoCredit(cleanName) ||
          _pureSideToken.hasMatch(cleanName) ||
          CloudMediaFileClassifier.isOpEdExtra(cleanName) ||
          (_hasBareSpTag(cleanName) &&
              maxSize > 0 &&
              size > 0 &&
              size < maxSize ~/ 3);

      final entry = _parseFileEntry(
        asset: asset,
        rel: rel,
        name: name,
        subDir: subDir,
      );
      if (isPureSide) {
        extraFiles.add(entry);
      } else {
        mainFiles.add(entry);
      }
    }

    if (mainFiles.length < 2) return const [];

    final refinedMain = _refineMainEntries(
      mainFiles,
      leafClean: leafClean,
      folderTmdbId: folderTmdbId,
    );

    // Group candidate main files by (firstNonSuppSubDir, clusterSignature).
    final buckets = <String, List<_FileEntry>>{};
    final hasMultipleKinds = refinedMain.map((e) => e.kind).toSet().length > 1;
    final movieYears = refinedMain
        .where((e) => e.kind == 'movie' && e.year != null)
        .map((e) => e.year!)
        .toSet();
    final movieQuotes = refinedMain
        .where((e) => e.kind == 'movie' && e.quote != null)
        .map((e) => e.quote!.toLowerCase())
        .toSet();

    for (final entry in refinedMain) {
      final topSub = entry.subDir.isEmpty
          ? ''
          : entry.subDir.split('/').first.trim();
      String key;
      if (entry.isHashZeroOva) {
        key = '$topSub|ova-ep0|${entry.normStem}|#00';
      } else if (entry.kind == 'movie') {
        final subId =
            entry.partKey ??
            (entry.partIndex != null
                ? 'part:${entry.partIndex}'
                : (movieQuotes.length >= 2 && entry.quote != null
                      ? entry.quote!.toLowerCase()
                      : (movieYears.length >= 2 && entry.year != null
                            ? '${entry.year}'
                            : entry.normStem)));
        key = '$topSub|movie|${entry.normStem}|$subId';
      } else if (entry.kind == 'ova') {
        final ovaArc =
            entry.exKey ??
            entry.quote?.toLowerCase() ??
            entry.partKey ??
            (entry.year != null ? '${entry.year}' : '');
        key = '$topSub|ova|${entry.normStem}|$ovaArc';
      } else if (folderTmdbId != null) {
        // Under an explicit {tmdb-N} TV folder, keep all regular TV seasons
        // and discs unified in one main TV cluster while allowing bundled
        // movies/OVAs/#00 to split out cleanly.
        key = 'tmdb-main|series';
      } else {
        final quoteKey = entry.episode == null && entry.quote != null
            ? ':${entry.quote!.toLowerCase()}'
            : '';
        final arc =
            entry.partKey ??
            (hasMultipleKinds ? 'tv' : '') +
                (entry.year != null ? ':${entry.year}' : '') +
                quoteKey;
        key = '$topSub|series|${entry.normStem}|$arc';
      }
      (buckets[key] ??= []).add(entry);
    }

    // Also split a subfolder holding multiple distinct unnumbered features
    // or a standalone two-volume Alternative OVA release (- 01 / - 02).
    final expandedBuckets = <List<_FileEntry>>[];
    for (final group in buckets.values) {
      final unnumbered = group.where((e) => e.episode == null).toList();
      if (group.length >= 2 &&
          unnumbered.length == group.length &&
          group.map((e) => e.normStem).toSet().length == group.length) {
        for (final item in group) {
          expandedBuckets.add([item]);
        }
      } else if (_isTwoVolumeAlternativeGroup(group)) {
        final sorted = [...group]
          ..sort((a, b) => (a.episode ?? 0).compareTo(b.episode ?? 0));
        for (final item in sorted) {
          expandedBuckets.add([
            item.copyWith(
              kind: 'ova',
              ovaVolume: item.episode,
              partIndex: item.episode,
            ),
          ]);
        }
      } else {
        expandedBuckets.add(group);
      }
    }

    if (expandedBuckets.length < 2) return const [];

    // For {tmdb-N} directories, split only when at least one movie or standalone
    // OVA subcluster separates from the main TV work.
    final clusterIsMainTv = <bool>[
      for (final g in expandedBuckets)
        folderTmdbId != null &&
            g.first.kind == 'series' &&
            !g.first.isHashZeroOva &&
            g.first.ovaVolume == null &&
            g.any((e) => e.episode != null),
    ];
    if (folderTmdbId != null) {
      final hasDetachedSubwork = clusterIsMainTv.any((isMain) => !isMain);
      if (!hasDetachedSubwork) return const [];
    }

    // Pair explicit folder segments greedily (including partial collection
    // folders where segments are fewer than total clusters due to extra OVAs).
    final assignedSegment = _pairExplicitSegments(
      expandedBuckets,
      explicitSegments,
    );

    // Attach extra files to the best-matching cluster.
    final clusterExtras = <int, List<_FileEntry>>{
      for (var i = 0; i < expandedBuckets.length; i++) i: [],
    };
    for (final extra in extraFiles) {
      final owner = _matchExtraToCluster(extra, expandedBuckets);
      clusterExtras[owner]!.add(extra);
    }

    final twoPartIndices =
        expandedBuckets.length == 2 &&
        expandedBuckets.map((g) => g.first.partIndex).toSet().containsAll(
          const {1, 2},
        );

    final mainSeriesFallbackHint = _mainSeriesFallbackHint(
      expandedBuckets,
      leafClean: leafClean,
      stemInfo: stemInfo,
    );

    final clusters = <SubWorkCluster>[];
    for (var i = 0; i < expandedBuckets.length; i++) {
      final group = expandedBuckets[i]
        ..sort((a, b) {
          final ea = a.episode ?? 999999;
          final eb = b.episode ?? 999999;
          if (ea != eb) return ea.compareTo(eb);
          return a.rel.compareTo(b.rel);
        });
      final extras = clusterExtras[i]!;
      final explicitTitle = assignedSegment[i];
      final keepTmdb = folderTmdbId != null && clusterIsMainTv[i];
      final clusterInfo = _buildClusterMetadata(
        index: i,
        group: group,
        extras: extras,
        stemInfo: stemInfo,
        leafClean: leafClean,
        explicitTitle: explicitTitle,
        twoPartPair: twoPartIndices,
        tmdbId: keepTmdb ? folderTmdbId : null,
        tmdbType: keepTmdb ? (folderTmdbType ?? 'tv') : null,
        parentSeriesFileHint: (folderTmdbId != null && !keepTmdb)
            ? mainSeriesFallbackHint
            : null,
      );
      clusters.add(clusterInfo);
    }
    return clusters;
  }

  static List<_FileEntry> _normalizeDashEpisodeSubtitles(
    List<_FileEntry> mainFiles,
  ) {
    final dashEpSub = RegExp(
      r'^(.+?)[\s._]+[-–—][\s._]+0*(\d{1,3})(?:v\d+)?(?![0-9a-z.])[\s._]+(?![-–—])(\S.*)$',
      caseSensitive: false,
    );
    final existingSeriesNorms = <String>{
      for (final e in mainFiles)
        if (e.kind == 'series' &&
            e.episode != null &&
            !_genericStandaloneStem.hasMatch(e.cleanStem))
          e.normStem,
    };
    final epNumsByNormPrefix = <String, Set<int>>{};
    final parsed = <int, (String prefix, String normPrefix, int ep)>{};
    for (var i = 0; i < mainFiles.length; i++) {
      final e = mainFiles[i];
      if (e.kind != 'series' || e.episode != null) continue;
      final m = dashEpSub.firstMatch(e.cleanStem);
      if (m == null) continue;
      final epNum = int.tryParse(m.group(2)!);
      final prefix = m.group(1)!.trim();
      if (epNum == null || epNum < 1 || epNum > 999 || prefix.isEmpty) continue;
      final normPrefix = DirectoryAnalyzer.normalize(prefix);
      if (normPrefix.isEmpty) continue;
      parsed[i] = (prefix, normPrefix, epNum);
      (epNumsByNormPrefix[normPrefix] ??= <int>{}).add(epNum);
    }
    if (parsed.isEmpty) return mainFiles;

    return [
      for (var i = 0; i < mainFiles.length; i++)
        if (parsed[i] case final info?
            when existingSeriesNorms.contains(info.$2) ||
                (epNumsByNormPrefix[info.$2]?.length ?? 0) >= 2)
          mainFiles[i].copyWith(
            cleanStem: info.$1,
            normStem: info.$2,
            episode: info.$3,
            hasEpisodeSubtitle: true,
          )
        else
          mainFiles[i],
    ];
  }

  static List<_FileEntry> _refineMainEntries(
    List<_FileEntry> rawMainFiles, {
    required String leafClean,
    required int? folderTmdbId,
  }) {
    final mainFiles = _normalizeDashEpisodeSubtitles(rawMainFiles);
    final numberedSeries = mainFiles
        .where((e) => e.kind == 'series' && e.episode != null && e.episode! >= 1)
        .toList();
    final hasNumberedTv = numberedSeries.length >= 2;

    String? dominantSeriesNorm;
    if (numberedSeries.isNotEmpty) {
      final counts = <String, int>{};
      for (final e in numberedSeries) {
        counts.update(e.normStem, (n) => n + 1, ifAbsent: () => 1);
      }
      dominantSeriesNorm = counts.entries
          .reduce((a, b) => a.value >= b.value ? a : b)
          .key;
    }

    final plainSiblingCount = numberedSeries
        .where((e) => !e.hasEpisodeSubtitle)
        .length;
    final folderHasMovieMarker =
        _multiKindFolder.hasMatch(leafClean) && _movieToken.hasMatch(leafClean);

    return mainFiles.map((e) {
      if (e.subDir.isNotEmpty && _movieSubdir.hasMatch(e.subDir)) {
        return e.copyWith(kind: 'movie');
      }
      if (e.hashZeroSubtitle != null &&
          e.hashZeroSubtitle!.isNotEmpty &&
          hasNumberedTv &&
          (plainSiblingCount >= (numberedSeries.length + 1) ~/ 2 ||
              e.hasStrongOvaSubtitleTrait)) {
        final combinedStem = '${e.cleanStem} ${e.hashZeroSubtitle}'.trim();
        return e.copyWith(
          kind: 'ova',
          isHashZeroOva: true,
          clearEpisode: true,
          baseSeriesStem: e.cleanStem,
          cleanStem: combinedStem,
          normStem: DirectoryAnalyzer.normalize(combinedStem),
          quote: e.quote ?? e.hashZeroSubtitle,
        );
      }
      if (e.kind == 'series' && e.episode == null && hasNumberedTv) {
        if (e.romanPartIndex != null && e.romanPartSubtitle != null) {
          return e.copyWith(
            kind: 'movie',
            partIndex: e.romanPartIndex,
            partKey: 'roman_${e.romanPartIndex}',
          );
        }
        if (folderHasMovieMarker ||
            (folderTmdbId == null &&
                e.quote != null &&
                e.normStem != dominantSeriesNorm)) {
          return e.copyWith(kind: 'movie');
        }
      }
      return e;
    }).toList();
  }

  static bool _isTwoVolumeAlternativeGroup(List<_FileEntry> group) {
    if (group.length != 2) return false;
    if (!group.every((e) => e.kind == 'series' && e.episode != null)) {
      return false;
    }
    final eps = group.map((e) => e.episode!).toSet();
    if (eps.length != 2 || !eps.containsAll(const {1, 2})) return false;
    final rep = group.first;
    if (!RegExp(r'\balternative\b', caseSensitive: false).hasMatch(rep.cleanStem)) {
      return false;
    }
    return !RegExp(
      r'\b(?:season|s\d{1,2})\b',
      caseSensitive: false,
    ).hasMatch(rep.name);
  }

  static String? _mainSeriesFallbackHint(
    List<List<_FileEntry>> buckets, {
    required String leafClean,
    required _FranchiseStems stemInfo,
  }) {
    final mainTv = buckets.firstWhere(
      (g) =>
          g.first.kind == 'series' &&
          !g.first.isHashZeroOva &&
          g.first.ovaVolume == null &&
          g.any((e) => e.episode != null),
      orElse: () => const [],
    );
    if (mainTv.isNotEmpty) return mainTv.first.cleanStem;
    return stemInfo.leafStem ??
        stemInfo.fallbackStem ??
        (leafClean.isEmpty ? null : leafClean);
  }

  static SubWorkCluster _buildClusterMetadata({
    required int index,
    required List<_FileEntry> group,
    required List<_FileEntry> extras,
    required _FranchiseStems stemInfo,
    required String leafClean,
    required String? explicitTitle,
    bool twoPartPair = false,
    int? tmdbId,
    String? tmdbType,
    String? parentSeriesFileHint,
  }) {
    final first = group.first;
    final isOvaSeasonZero =
        first.isHashZeroOva || first.exKey != null || first.ovaVolume != null;
    final clusterSeason = isOvaSeasonZero ? 0 : null;
    final isSingleFeature =
        first.kind == 'movie' ||
        isOvaSeasonZero ||
        (group.length == 1 &&
            (first.episode == null ||
                (explicitTitle != null && first.episode == 1)));
    final years = group.map((e) => e.year).whereType<int>().toSet();
    final clusterYear = years.length == 1 ? years.single : null;

    // Re-normalize contiguous multi-episode OVA arcs starting > 1
    // (e.g. an OVA arc 04..06 -> local episodes 1..3).
    final rawEpisodes = group.map((e) => e.episode).whereType<int>().toList();
    var epOffset = 0;
    if (!isSingleFeature &&
        rawEpisodes.length == group.length &&
        rawEpisodes.length >= 2) {
      final sortedEps = [...rawEpisodes]..sort();
      final minEp = sortedEps.first;
      final contiguous = List.generate(sortedEps.length, (k) => minEp + k);
      if (minEp > 1 &&
          minEp <= 10 &&
          first.kind == 'ova' &&
          sortedEps.join(',') == contiguous.join(',')) {
        epOffset = minEp - 1;
      }
    }

    final titleHints = <String>[];
    void addHint(String? value) {
      final cleaned = value?.replaceAll(RegExp(r'\s+'), ' ').trim() ?? '';
      if (cleaned.isEmpty) return;
      final norm = DirectoryAnalyzer.normalize(cleaned);
      if (norm.isEmpty) return;
      if (!titleHints.any((h) => DirectoryAnalyzer.normalize(h) == norm)) {
        titleHints.add(cleaned);
      }
    }

    if (explicitTitle != null) addHint(explicitTitle);

    final cleanStem = first.cleanStem;
    final hasIndependentTitle =
        explicitTitle != null ||
        (cleanStem.isNotEmpty && !_genericStandaloneStem.hasMatch(cleanStem));

    if (first.exKey != null) {
      final baseNoEx = cleanStem
          .replaceAll(RegExp(r'\s+ex[ ._-]*\d+\s*$', caseSensitive: false), '')
          .trim();
      final exUpper = first.exKey!.toUpperCase();
      addHint(baseNoEx.isEmpty ? exUpper : '$baseNoEx $exUpper');
    }

    if (first.ovaVolume != null) {
      final volWord = first.ovaVolume == 1
          ? 'ONE'
          : first.ovaVolume == 2
          ? 'TWO'
          : '${first.ovaVolume}';
      addHint('$cleanStem $volWord');
      addHint('$cleanStem ${first.ovaVolume}');
    }

    final localizedPart =
        _localizedPartLabel(first.partKey) ??
        (twoPartPair
            ? (first.partIndex == 1
                  ? '前篇'
                  : first.partIndex == 2
                  ? '后篇'
                  : null)
            : null);
    final combinableParent = stemInfo.combinableStem(leafClean);
    if (combinableParent != null && combinableParent.isNotEmpty) {
      if (localizedPart != null) {
        addHint('$combinableParent $localizedPart');
      }
      if (first.quote != null &&
          first.quote!.isNotEmpty &&
          !first.isHashZeroOva) {
        addHint('$combinableParent ${first.quote!}');
      }
      if (first.kind == 'movie' &&
          localizedPart == null &&
          first.quote == null &&
          !hasIndependentTitle) {
        addHint('$combinableParent 剧场版');
      }
    }

    final rawTopSub = first.subDir.isEmpty
        ? ''
        : first.subDir.split('/').first.trim();
    final isGenericSubdir = RegExp(
      r'^(?:movies?|films?|ovas?|oads?|tv|seasons?\s*\d*|s\d{1,2}|'
      r'disc\s*\d+|剧场版|劇場版)$',
      caseSensitive: false,
    ).hasMatch(rawTopSub);
    final cleanSubDir = rawTopSub.isEmpty || isGenericSubdir
        ? null
        : PersonalFilenameParser.extractAnimeTitleKeyword(rawTopSub);
    if (cleanSubDir != null && cleanSubDir.isNotEmpty) {
      addHint(_expandRomanMk(cleanSubDir));
      addHint(cleanSubDir);
    }

    if (first.quote != null &&
        first.quote!.isNotEmpty &&
        !first.isHashZeroOva) {
      final quote = first.quote!;
      final baseWithoutMovie = cleanStem
          .replaceAll(
            RegExp(r'\b(?:movie|ova|oad)\b', caseSensitive: false),
            ' ',
          )
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      if (baseWithoutMovie.isNotEmpty) {
        addHint('$baseWithoutMovie $quote');
      }
      addHint('$cleanStem $quote');
    }

    if (first.hdRemasterLabel != null &&
        !_hdRemasterPattern.hasMatch(cleanStem) &&
        cleanStem.isNotEmpty) {
      addHint('$cleanStem ${first.hdRemasterLabel}');
    }
    if (hasIndependentTitle) {
      addHint(cleanStem);
    }

    if (first.isHashZeroOva && first.hashZeroSubtitle != null) {
      addHint(first.hashZeroSubtitle);
    }

    // Isolate parent collection stem: only inject bare fallback stem when the
    // subcluster lacks an explicit segment or independent filename title.
    if (!hasIndependentTitle && stemInfo.fallbackStem != null) {
      addHint(stemInfo.fallbackStem);
    } else if (titleHints.isEmpty && stemInfo.fallbackStem != null) {
      addHint(stemInfo.fallbackStem);
    }
    if (titleHints.isEmpty) {
      addHint(cleanStem);
    }

    final primaryTitle = titleHints.firstOrNull ?? first.cleanStem;
    final logicalMain = <LogicalItem>[];
    final assignments = <SplitAssetAssignment>[];
    final assignSeason = clusterSeason ?? 1;

    if (isSingleFeature) {
      final item = LogicalItem('feature', primaryTitle, null, clusterSeason)
        ..files.addAll([for (final f in group) f.rel]);
      logicalMain.add(item);
      for (final f in group) {
        assignments.add(
          SplitAssetAssignment(
            assetId: f.assetId,
            relativePath: f.rel,
            category: 'main',
            season: assignSeason,
            episode: null,
          ),
        );
      }
    } else {
      final byEp = <int, List<_FileEntry>>{};
      final usedEps = <int>{
        for (final f in group)
          if (f.episode != null) f.episode!,
      };
      var fallbackEp = 1;
      int nextFreeEp() {
        while (usedEps.contains(fallbackEp)) {
          fallbackEp++;
        }
        usedEps.add(fallbackEp);
        return fallbackEp++;
      }

      for (final f in group) {
        final rawEp = f.episode ?? nextFreeEp();
        final normEp = rawEp - epOffset;
        (byEp[normEp] ??= []).add(f);
        assignments.add(
          SplitAssetAssignment(
            assetId: f.assetId,
            relativePath: f.rel,
            category: 'main',
            season: assignSeason,
            episode: normEp,
          ),
        );
      }
      final sortedKeys = byEp.keys.toList()..sort();
      for (final ep in sortedKeys) {
        final item = LogicalItem(
          's${assignSeason}e$ep',
          primaryTitle,
          ep,
          clusterSeason ?? 1,
        )..files.addAll([for (final f in byEp[ep]!) f.rel]);
        logicalMain.add(item);
      }
    }

    for (final ex in extras) {
      assignments.add(
        SplitAssetAssignment(
          assetId: ex.assetId,
          relativePath: ex.rel,
          category: 'extra',
          season: 0,
          episode: null,
          extraType: CloudMediaAssetPresentation.extraType({
            'name': ex.name,
            'relative_path': ex.rel,
          }),
        ),
      );
    }

    final fileHints = <String>[
      for (final f in group.take(3))
        if (f.cleanStem.isNotEmpty) f.cleanStem,
      if (first.baseSeriesStem != null && first.baseSeriesStem!.isNotEmpty)
        first.baseSeriesStem!,
      if (parentSeriesFileHint != null && parentSeriesFileHint.isNotEmpty)
        parentSeriesFileHint,
    ];

    final inventory = DirectoryInventory.synthetic(
      folder: primaryTitle,
      shape: isSingleFeature ? WorkShape.feature : WorkShape.series,
      title: primaryTitle,
      titleHints: titleHints,
      fileHints: fileHints.toSet().toList(),
      year: clusterYear,
      tmdbId: tmdbId,
      tmdbType: tmdbType,
      season: clusterSeason,
      folderMovieMarker:
          first.kind == 'movie' ||
          (!isOvaSeasonZero && _movieToken.hasMatch(primaryTitle)),
      fileMovieMarker: first.kind == 'movie',
      main: logicalMain,
      extras: [for (final ex in extras) ex.rel],
    );

    final slugSuffix =
        first.ovaVolume?.toString() ??
        first.exKey ??
        (first.isHashZeroOva ? 'ep0' : null);
    final slugRaw = DirectoryAnalyzer.normalize(
      '$index-$primaryTitle-${clusterYear ?? ''}-${slugSuffix ?? ''}',
    );
    return SubWorkCluster(
      slug: slugRaw.isEmpty ? 'part-$index' : slugRaw,
      virtualFolder: primaryTitle,
      inventory: inventory,
      assignments: assignments,
    );
  }

  static _FileEntry _parseFileEntry({
    required Map<String, Object?> asset,
    required String rel,
    required String name,
    required String subDir,
  }) {
    final cleanName = CloudMediaFileClassifier.stripTechnicalNoise(name);
    final base = PersonalFilenameParser.baseNameWithoutExtension(cleanName);
    final quoteMatch = _quoteBlock.firstMatch(base);
    final quote = (quoteMatch?.group(1) ?? quoteMatch?.group(2))?.trim();
    final yearMatch = RegExp(
      r'[\[(（]\s*((?:19|20)\d{2})\s*[\])）]|'
      r'(?<=\b(?:movie|ova|oad|tv|ver\.?)\s+)((?:19|20)\d{2})(?![a-z0-9%])|'
      r'(?<![a-z0-9])((?:19|20)\d{2})(?=\s*(?:「|『|\[|\(|ep\b|ova\b|oad\b|movie\b|anime\b|hd\b|-))|'
      r'(?<=\b(?:movie|ova|oad|part|chapter)[\s._-]*\d{1,2}[\s._-])((?:19|20)\d{2})(?=$|[\s._\-)\]])',
      caseSensitive: false,
    ).firstMatch(base);
    final year = int.tryParse(
      yearMatch?.group(1) ??
          yearMatch?.group(2) ??
          yearMatch?.group(3) ??
          yearMatch?.group(4) ??
          '',
    );

    final hdRemasterMatch = _hdRemasterPattern.firstMatch(base);
    final hdRemasterLabel = hdRemasterMatch?.group(0)?.trim();

    final exMatch = _exTagPattern.firstMatch(base);
    final exKey = exMatch
        ?.group(1)
        ?.toLowerCase()
        .replaceAll(RegExp(r'[\s._-]+'), '');

    final withoutQuote = base
        .replaceAll(_quoteBlock, ' ')
        .replaceAll(RegExp(r'[\[(]\s*(?:19|20)\d{2}\s*[\])]'), ' ')
        .replaceAll(
          RegExp(
            r'(?<=\b(?:movie|ova|oad|tv)\s+)(?:19|20)\d{2}(?![a-z0-9%])',
            caseSensitive: false,
          ),
          ' ',
        )
        .replaceAll(
          RegExp(
            r'(?<=\b(?:movie|ova|oad|part|chapter)[\s._-]*\d{1,2}[\s._-])(?:19|20)\d{2}(?=$|[\s._\-)\]])',
            caseSensitive: false,
          ),
          ' ',
        );
    var cleanStem =
        PersonalFilenameParser.extractAnimeTitleKeyword(withoutQuote)
            .replaceAll(RegExp(r'\s*[-–—]\s*\d{1,3}\s*$'), '')
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
    if (cleanStem.isEmpty) {
      cleanStem = PersonalFilenameParser.extractAnimeTitleKeyword(cleanName);
    }

    final romanMatch = _romanFeaturePart.firstMatch(cleanStem);
    int? romanPartIndex;
    String? romanPartSubtitle;
    if (romanMatch != null) {
      final token = romanMatch.group(2)!.toUpperCase();
      final sub = romanMatch.group(3)!.trim();
      final isGenericTail = RegExp(
        r'^(?:episode|ep|part|vol|ver|\d+).*$',
        caseSensitive: false,
      ).hasMatch(sub);
      if (sub.length >= 3 && !isGenericTail) {
        romanPartIndex = switch (token) {
          'I' || 'Ⅰ' => 1,
          'II' || 'Ⅱ' => 2,
          'III' || 'Ⅲ' => 3,
          'IV' || 'Ⅳ' => 4,
          'V' => 5,
          _ => null,
        };
        if (romanPartIndex != null) {
          romanPartSubtitle = sub;
        }
      }
    }

    final strippedBase = _stripGroupPrefixes(base);
    String? hashZeroSubtitle;
    var hasStrongOvaSubtitleTrait = false;
    final hashZeroMatch = RegExp(
      r'[#＃]\s*0+(?![0-9])\s*(.*)$',
    ).firstMatch(strippedBase);
    if (hashZeroMatch != null) {
      final rawAfter = hashZeroMatch.group(1)!.trim();
      final cleanedAfter = rawAfter
          .replaceFirst(RegExp(r'^[-–—:：._\s]+'), '')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      if (cleanedAfter.length >= 2) {
        hashZeroSubtitle = cleanedAfter;
        hasStrongOvaSubtitleTrait = RegExp(
          r'ova|oad|prologue|special|pilot|序章|前日譚|前日谈|前传|特別編|特别篇|番外|〜|～|「|『',
          caseSensitive: false,
        ).hasMatch(rawAfter);
      }
    }

    final partKey = _detectPartKey(base);
    final partIndex = _detectPartIndex(base);
    final isMovie =
        _movieToken.hasMatch(base) ||
        (subDir.isNotEmpty && _movieSubdir.hasMatch(subDir));
    final isOva = exKey != null || (!isMovie && _ovaToken.hasMatch(base));
    final ep = exKey != null
        ? null
        : CloudMediaFileClassifier.episodeNumberFromName(
            withoutQuote.replaceAll(RegExp(r'\b(?:19|20)\d{2}\b'), ' '),
          );
    final hasEpisodeSubtitle =
        ep != null && ep >= 1 && _hasExplicitEpisodeSubtitle(strippedBase, ep);
    final kind = isMovie
        ? 'movie'
        : isOva
        ? 'ova'
        : 'series';
    final stemForBucket = cleanStem
        .replaceAll(
          RegExp(r'\b(?:the\s+movie|movie|ova|oad)\b', caseSensitive: false),
          ' ',
        )
        .replaceAll(RegExp(r'\s+[-–—]\s*\d{1,3}\s*$'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final isGenericSeries =
        kind == 'series' &&
        ep != null &&
        _genericStandaloneStem.hasMatch(cleanStem);
    final normStem = isGenericSeries
        ? '__generic_series__'
        : DirectoryAnalyzer.normalize(
            stemForBucket.isEmpty ? cleanStem : stemForBucket,
          );

    return _FileEntry(
      assetId: asset['id'].toString(),
      rel: rel,
      name: name,
      subDir: subDir,
      cleanStem: cleanStem,
      normStem: normStem.isEmpty
          ? DirectoryAnalyzer.normalize(cleanStem)
          : normStem,
      quote: quote,
      year: year,
      partKey: partKey,
      partIndex: partIndex,
      kind: kind,
      episode: ep,
      exKey: exKey,
      hdRemasterLabel: hdRemasterLabel,
      hashZeroSubtitle: hashZeroSubtitle,
      hasStrongOvaSubtitleTrait: hasStrongOvaSubtitleTrait,
      hasEpisodeSubtitle: hasEpisodeSubtitle,
      romanPartIndex: romanPartIndex,
      romanPartSubtitle: romanPartSubtitle,
    );
  }

  static String _stripGroupPrefixes(String base) => base
      .replaceFirst(RegExp(r'^(?:\s*[\[(【（][^\]\)】）]{1,40}[\])】）])+'), '')
      .trim();

  static bool _hasExplicitEpisodeSubtitle(String strippedBase, int ep) {
    final epPat = RegExp(
      '(?:[#＃][ ._]*0*$ep|\\[\\s*0*$ep\\s*\\]|(?:^|[\\s._-])0*$ep)(?![0-9])',
    );
    final match = epPat.allMatches(strippedBase).lastOrNull;
    if (match == null) return false;
    final tail = strippedBase
        .substring(match.end)
        .replaceFirst(RegExp(r'^[-–—:：._\s\]】）)]+'), '')
        .replaceAll(
          RegExp(
            r'^(?:v\d+|end|fin|final|完|(?:tv|bd)[ ._-]*ver\.?)$',
            caseSensitive: false,
          ),
          '',
        )
        .trim();
    return tail.length >= 2;
  }

  static int? _detectPartIndex(String base) {
    final lower = base.toLowerCase();
    if (RegExp(
      r'(?:^|[^a-z0-9])zenpen(?=[^a-z0-9]|$)|前編|前篇|上篇',
    ).hasMatch(lower)) {
      return 1;
    }
    if (RegExp(
      r'(?:^|[^a-z0-9])kouhen(?=[^a-z0-9]|$)|後編|后篇|下篇',
    ).hasMatch(lower)) {
      return 2;
    }
    if (RegExp(r'中篇').hasMatch(lower)) {
      return 3;
    }
    final numMatch = RegExp(
      r'(?:^|[^a-z0-9])(?:movie|part|chapter|film|vol(?:ume)?|act)'
      r'[\s._-]*0?(\d{1,2})(?=[^a-z0-9]|$)',
    ).firstMatch(lower);
    if (numMatch != null) {
      final v = int.tryParse(numMatch.group(1)!);
      if (v != null && v >= 1 && v <= 20) return v;
    }
    return null;
  }

  static String? _detectPartKey(String base) {
    final lower = base.toLowerCase();
    for (final (pattern, key) in <(RegExp, String)>[
      (RegExp(r'(?:^|[^a-z0-9])zenpen(?=[^a-z0-9]|$)|前編|前篇'), 'zenpen'),
      (RegExp(r'(?:^|[^a-z0-9])kouhen(?=[^a-z0-9]|$)|後編|后篇'), 'kouhen'),
      (RegExp(r'(?:^|[^a-z0-9])chuhen(?=[^a-z0-9]|$)|中編|中篇'), 'chuhen'),
    ]) {
      if (pattern.hasMatch(lower)) return key;
    }
    final preEpLower = lower.replaceFirst(
      RegExp(
        r'(?:^|[\s._\-\[【])(?:ep(?:isode)?[\s._-]*|[#＃]\s*|s\d{1,2}[ ._-]*e)\d{1,3}(?![0-9]).*$'
        r'|[\s._]+[-–—][\s._]+\d{1,3}(?![0-9]).*$'
        r'|[\[【]\s*\d{1,3}(?:\.5)?(?:v\d+)?\s*[\]】].*$',
      ),
      '',
    );
    final romajiHen = RegExp(
      r'(?:^|[^a-z0-9])([a-z]{3,16})[\s._-]+hen(?![a-z0-9])',
    ).firstMatch(preEpLower);
    if (romajiHen != null) {
      return 'hen:${romajiHen.group(1)}';
    }
    final cjkHen = RegExp(
      r'([\u4e00-\u9fff\u3040-\u30ff]{1,6})[編篇]',
    ).firstMatch(preEpLower);
    if (cjkHen != null) {
      final prefix = cjkHen.group(1)!;
      if (!RegExp(r'^(?:総集|总集|特別|特别|番外|未公開|ダイジェスト)$').hasMatch(prefix)) {
        return 'hen:$prefix';
      }
    }
    final namedStage = RegExp(
      r'(?:^|[^a-z0-9])([a-z]{3,16})[\s._-]+stage(?:[\s._]+(iv|iii|ii|i|[2-4]))?(?![a-z0-9])',
    ).firstMatch(preEpLower);
    if (namedStage != null) {
      final word = namedStage.group(1)!;
      final suffix = namedStage.group(2) ?? '1';
      final numSuffix = switch (suffix) {
        'i' => '1',
        'ii' => '2',
        'iii' => '3',
        'iv' => '4',
        _ => suffix,
      };
      return 'stage:${word}_$numSuffix';
    }
    return null;
  }

  static String? _localizedPartLabel(String? partKey) => switch (partKey) {
    'zenpen' => '前篇',
    'kouhen' => '后篇',
    'chuhen' => '中篇',
    _ => null,
  };

  static String _expandRomanMk(String value) => value
      .replaceAllMapped(
        RegExp(r'\bMk\s*1\b', caseSensitive: false),
        (_) => 'Mk-I',
      )
      .replaceAllMapped(
        RegExp(r'\bMk\s*2\b', caseSensitive: false),
        (_) => 'Mk-II',
      )
      .replaceAllMapped(
        RegExp(r'\bMk\s*3\b', caseSensitive: false),
        (_) => 'Mk-III',
      )
      .replaceAllMapped(
        RegExp(r'\bMk\s*4\b', caseSensitive: false),
        (_) => 'Mk-IV',
      )
      .replaceAllMapped(
        RegExp(r'\bMk\s*5\b', caseSensitive: false),
        (_) => 'Mk-V',
      );

  static _FranchiseStems _extractFranchiseStems(
    String normFolder,
    String leafClean,
  ) {
    String? leafStem;
    if (!_explicitJoiner.hasMatch(leafClean)) {
      final stripped = leafClean
          .replaceAll(_multiKindFolder, ' ')
          .replaceAll(
            RegExp(
              r'\b(?:movies?|ovas?|oads?|extras?|specials?|tv)\b|剧场版|劇場版',
              caseSensitive: false,
            ),
            ' ',
          )
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      if (RegExp(r'[\u3040-\u9fff]').hasMatch(stripped) &&
          stripped.length >= 2) {
        leafStem = stripped;
      }
    }
    String? grandparentStem;
    final parts = normFolder
        .split('/')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    if (parts.length >= 2) {
      final parent = parts[parts.length - 2]
          .replaceFirst(
            RegExp(r'\s*(?:系列|作品集|合集|Collection)$', caseSensitive: false),
            '',
          )
          .trim();
      if (RegExp(r'[\u3040-\u9fff]').hasMatch(parent) &&
          parent.length >= 2 &&
          !RegExp(r'^(?:未添加TMDB|动画|番剧|电影|动漫)').hasMatch(parent)) {
        grandparentStem = parent;
      }
    }
    return _FranchiseStems(
      leafStem: leafStem,
      grandparentStem: grandparentStem,
    );
  }

  static List<String> _extractExplicitSegments(String leafClean) {
    if (!_explicitJoiner.hasMatch(leafClean)) return const [];
    final rawParts = leafClean
        .split(_explicitJoiner)
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    if (rawParts.length < 2) return const [];
    // Reject generic type labels such as "秀逗魔导士 Movie" & "OVA".
    if (rawParts.any(
      (p) => RegExp(
        r'^(?:movies?|ovas?|oads?|tv|specials?|sps?)$',
        caseSensitive: false,
      ).hasMatch(p),
    )) {
      return const [];
    }
    return rawParts;
  }

  static Map<int, String> _pairExplicitSegments(
    List<List<_FileEntry>> groups,
    List<String> segments,
  ) {
    if (segments.isEmpty || groups.isEmpty) return const {};
    final result = <int, String>{};
    final usedSegments = <int>{};
    final usedGroups = <int>{};

    const stopWords = {
      'hd',
      'tv',
      'ova',
      'oad',
      'movie',
      'the',
      'of',
      'to',
      'and',
      'in',
      'season',
      'ver',
    };

    List<String> asciiTokens(String s) =>
        RegExp(r'[a-z0-9]{2,}', caseSensitive: false)
            .allMatches(s.toLowerCase())
            .map((m) => m.group(0)!)
            .where((t) => !stopWords.contains(t))
            .toList();

    Set<String> cjkBigrams(String norm) {
      final cjk = RegExp(
        r'[\u3040-\u9fff\u30a0-\u30ff]+',
      ).allMatches(norm).map((m) => m.group(0)!).join();
      final out = <String>{};
      for (var i = 0; i + 1 < cjk.length; i++) {
        out.add(cjk.substring(i, i + 2));
      }
      if (cjk.length == 1) out.add(cjk);
      return out;
    }

    // Score every (group, segment) pair and resolve globally in descending
    // specificity order so specific sequels/variants claim their cluster before
    // shorter base titles.
    final candidates = <({int gi, int si, int score})>[];
    for (var gi = 0; gi < groups.length; gi++) {
      final rep = groups[gi].first;
      final groupNorm = DirectoryAnalyzer.normalize(rep.cleanStem);
      final sampleRaw = groups[gi].map((e) => '${e.subDir} ${e.name}').join(' ');
      final sampleClean = CloudMediaFileClassifier.stripTechnicalNoise(sampleRaw);
      final sampleLower = sampleClean.toLowerCase();
      final sampleNorm = DirectoryAnalyzer.normalize(sampleClean);
      final groupAscii = asciiTokens('${rep.cleanStem} $sampleClean').toSet();
      final groupCjk = cjkBigrams(sampleNorm);

      for (var si = 0; si < segments.length; si++) {
        final seg = segments[si];
        final segNorm = DirectoryAnalyzer.normalize(seg);
        final segAscii = asciiTokens(seg);
        final segCjk = cjkBigrams(segNorm);
        var lexicalScore = 0;

        if (segNorm.isNotEmpty && groupNorm.isNotEmpty) {
          if (groupNorm == segNorm) {
            lexicalScore += 300;
          } else if (segNorm.length >= 2 && groupNorm.contains(segNorm)) {
            lexicalScore += 140 - (groupNorm.length - segNorm.length).clamp(0, 60);
          } else if (groupNorm.length >= 2 && segNorm.contains(groupNorm)) {
            lexicalScore += 140 - (segNorm.length - groupNorm.length).clamp(0, 60);
          }
        }

        for (final tok in segAscii) {
          final hit =
              groupAscii.contains(tok) ||
              RegExp(
                '(^|[^a-z0-9])${RegExp.escape(tok)}([^a-z0-9]|\$)',
              ).hasMatch(sampleLower);
          if (hit) {
            lexicalScore += 40 + tok.length.clamp(2, 12) * 4;
          } else {
            lexicalScore -= 35;
          }
        }

        if (segCjk.isNotEmpty && groupCjk.isNotEmpty) {
          final overlap = segCjk.where(groupCjk.contains).length;
          if (overlap > 0) {
            lexicalScore += (overlap * 60) ~/ segCjk.length;
          }
        }

        final segIsZenpen = RegExp(r'前[篇編]').hasMatch(seg);
        final segIsKouhen = RegExp(r'[後后][篇編]').hasMatch(seg);
        if (segIsZenpen && rep.partIndex == 1) lexicalScore += 80;
        if (segIsKouhen && rep.partIndex == 2) lexicalScore += 80;
        if ((segIsZenpen && rep.partIndex == 2) ||
            (segIsKouhen && rep.partIndex == 1)) {
          lexicalScore -= 80;
        }

        if (lexicalScore <= 0) continue;

        final segMentionsOva = _ovaToken.hasMatch(seg);
        final segMentionsMovie = _movieToken.hasMatch(seg);
        var totalScore = lexicalScore;
        if (rep.kind == 'series' && !segMentionsOva && !segMentionsMovie) {
          totalScore += 45 + groups[gi].length.clamp(0, 20);
        } else if (rep.kind == 'ova' && !segMentionsOva) {
          totalScore -= 30;
        }
        if (totalScore > 0) {
          candidates.add((gi: gi, si: si, score: totalScore));
        }
      }
    }

    candidates.sort((a, b) {
      final cmp = b.score.compareTo(a.score);
      if (cmp != 0) return cmp;
      final lenCmp = groups[b.gi].length.compareTo(groups[a.gi].length);
      if (lenCmp != 0) return lenCmp;
      return a.gi.compareTo(b.gi);
    });

    for (final c in candidates) {
      if (usedGroups.contains(c.gi) || usedSegments.contains(c.si)) continue;
      result[c.gi] = segments[c.si];
      usedGroups.add(c.gi);
      usedSegments.add(c.si);
    }

    // Only force-assign remaining segments by order when segment and cluster
    // counts match (e.g. completely distinct translated titles); when extra OVA
    // clusters exist, leave unmatched OVA clusters with filename titles.
    if (segments.length == groups.length) {
      var nextSeg = 0;
      for (var gi = 0; gi < groups.length; gi++) {
        if (result.containsKey(gi)) continue;
        while (nextSeg < segments.length && usedSegments.contains(nextSeg)) {
          nextSeg++;
        }
        if (nextSeg < segments.length) {
          result[gi] = segments[nextSeg];
          usedSegments.add(nextSeg);
        }
      }
    }
    return result;
  }

  static Set<String> _distinctiveTokens(String raw) {
    const generic = {
      'the',
      'of',
      'to',
      'and',
      'in',
      'on',
      'for',
      'a',
      'an',
      'bd',
      'dvd',
      'web',
      'tv',
      'ova',
      'oad',
      'movie',
      'film',
      'ver',
      'hd',
      'remaster',
      'ncop',
      'nced',
      'ncoped',
      'op',
      'ed',
      'pv',
      'cm',
      'menu',
      'menus',
      'trailer',
      'teaser',
      'preview',
      'making',
      'creditless',
      'textless',
      'special',
      'specials',
      'sp',
      'sps',
      'extra',
      'extras',
      'bonus',
    };
    final expanded = raw
        .replaceAllMapped(
          RegExp(r'\bmenu[._-]*(ex\d{1,2})\b', caseSensitive: false),
          (m) => 'menu ${m.group(1)!}',
        )
        .toLowerCase();
    return RegExp(r'[a-z0-9]{2,}')
        .allMatches(expanded)
        .map((m) => m.group(0)!)
        .where((t) => !generic.contains(t) && !RegExp(r'^\d+$').hasMatch(t))
        .toSet();
  }

  static String _cleanExtraNormalizedStem(String name) {
    var s = CloudMediaFileClassifier.stripTechnicalNoise(name);
    s = PersonalFilenameParser.baseNameWithoutExtension(s);
    s = _stripGroupPrefixes(s);
    s = s
        .replaceAll(
          RegExp(
            r'\b(?:nc(?:oped|op|ed)|pvcm|tvcm|bdcm|pv|cm|'
            r'menus?(?:[._-]*ex)?\d*|trailer|teaser|preview|spot|making|'
            r'commentary|creditless|textless|digest|interview|appendix|hyakka)'
            r'(?:[._-]*v?\d+[a-z]?)?\b',
            caseSensitive: false,
          ),
          ' ',
        )
        .replaceAll(
          RegExp(
            r'(?<![a-z0-9])(?:op|ed)(?:v?\d{1,2})?(?![a-z0-9])',
            caseSensitive: false,
          ),
          ' ',
        )
        .replaceAll(
          RegExp(
            r'予告|預告|预告|特報|メイキング|ノンクレジット|ノンクレ|映像特典|特典|メニュ[ー一]',
          ),
          ' ',
        );
    return DirectoryAnalyzer.normalize(s);
  }

  static int _matchExtraToCluster(
    _FileEntry extra,
    List<List<_FileEntry>> groups,
  ) {
    final extraTopSub = extra.subDir.isEmpty
        ? ''
        : extra.subDir.split('/').first.trim();
    if (extraTopSub.isNotEmpty &&
        !CloudMediaFileClassifier.isSupplementaryDirectory(extraTopSub)) {
      final matchingSubs = <int>[
        for (var i = 0; i < groups.length; i++)
          if (groups[i].first.subDir.split('/').first.trim() == extraTopSub) i,
      ];
      if (matchingSubs.length == 1) return matchingSubs.single;
    }

    final clusterTokenSets = <Set<String>>[];
    final clusterNorms = <String>[];
    final tokenDocFreq = <String, int>{};

    for (final g in groups) {
      final rep = g.first;
      final tokens = _distinctiveTokens(
        '${rep.cleanStem} ${rep.quote ?? ''} ${rep.exKey ?? ''} '
        '${rep.subDir} ${rep.name}',
      );
      clusterTokenSets.add(tokens);
      clusterNorms.add(DirectoryAnalyzer.normalize(rep.cleanStem));
      for (final t in tokens) {
        tokenDocFreq.update(t, (n) => n + 1, ifAbsent: () => 1);
      }
    }

    final cleanExtraName = CloudMediaFileClassifier.stripTechnicalNoise(
      extra.name,
    );
    final extraSubClean = extra.subDir
        .split('/')
        .where((s) => s.isNotEmpty && !CloudMediaFileClassifier.isSupplementaryDirectory(s))
        .join(' ');
    final extraTokens = _distinctiveTokens('$cleanExtraName $extraSubClean');
    final extraCleanNorm = _cleanExtraNormalizedStem(extra.name);
    final lowerName = cleanExtraName.toLowerCase();
    final extraExMatch = RegExp(
      r'(?<![a-z0-9])(?:menu[ ._-]*)?(ex[ ._-]*\d{1,2})(?![a-z0-9])',
      caseSensitive: false,
    ).firstMatch(lowerName);
    final extraExKey = extraExMatch
        ?.group(1)
        ?.toLowerCase()
        .replaceAll(RegExp(r'[\s._-]+'), '');

    var bestIdx = 0;
    var bestScore = -1000000;
    for (var i = 0; i < groups.length; i++) {
      final rep = groups[i].first;
      var score = 0;

      if (extraTopSub.isNotEmpty &&
          !CloudMediaFileClassifier.isSupplementaryDirectory(extraTopSub) &&
          rep.subDir.split('/').first.trim() == extraTopSub) {
        score += 35;
      }
      if (rep.exKey != null && extraExKey == rep.exKey) {
        score += 60;
      }
      if (rep.quote != null &&
          rep.quote!.isNotEmpty &&
          lowerName.contains(rep.quote!.toLowerCase())) {
        score += 30;
      }
      if (rep.partKey != null && extra.partKey == rep.partKey) {
        score += 30;
      } else if (rep.partIndex != null && extra.partIndex == rep.partIndex) {
        score += 30;
      }

      final cNorm = clusterNorms[i];
      if (cNorm.isNotEmpty && extraCleanNorm.isNotEmpty) {
        if (extraCleanNorm == cNorm) {
          score += 55;
        } else if (cNorm.length >= 4 && extraCleanNorm.contains(cNorm)) {
          score += 15 + cNorm.length.clamp(4, 40);
        } else if (extraCleanNorm.length >= 4 && cNorm.contains(extraCleanNorm)) {
          score += 12 + extraCleanNorm.length.clamp(4, 40);
        }
      }

      final cTokens = clusterTokenSets[i];
      for (final tok in extraTokens) {
        if (cTokens.contains(tok)) {
          final df = tokenDocFreq[tok] ?? groups.length;
          final idfBonus = df == 1 ? 24 : (14 ~/ df).clamp(2, 14);
          score += idfBonus + tok.length.clamp(2, 12);
        }
      }
      // Slightly penalize unique distinguishing cluster tokens absent from extra
      // so shared-prefix extras ("Title NCOP1") stay with "Title" over "Title Subtitle".
      for (final cTok in cTokens) {
        if (!extraTokens.contains(cTok) && (tokenDocFreq[cTok] ?? 0) == 1) {
          score -= 6;
        }
      }

      if (rep.year != null && extra.year == rep.year) {
        score += 6;
      }
      if (score > bestScore) {
        bestScore = score;
        bestIdx = i;
      }
    }
    return bestScore > 0 ? bestIdx : 0;
  }

  static bool _hasBareSpTag(String name) =>
      RegExp(r'\[\s*SP\d{1,3}\s*\]', caseSensitive: false).hasMatch(name) &&
      !_ovaToken.hasMatch(name) &&
      !_movieToken.hasMatch(name);
}

class _FranchiseStems {
  const _FranchiseStems({this.leafStem, this.grandparentStem});

  final String? leafStem;
  final String? grandparentStem;

  String? get fallbackStem => leafStem ?? grandparentStem;

  String? combinableStem(String leafClean) {
    if (leafStem != null && leafStem!.isNotEmpty) return leafStem;
    if (grandparentStem != null &&
        grandparentStem!.isNotEmpty &&
        DirectoryAnalyzer.normalize(leafClean).contains(
          DirectoryAnalyzer.normalize(grandparentStem!),
        )) {
      return grandparentStem;
    }
    return null;
  }
}

class _FileEntry {
  const _FileEntry({
    required this.assetId,
    required this.rel,
    required this.name,
    required this.subDir,
    required this.cleanStem,
    required this.normStem,
    required this.kind,
    this.quote,
    this.year,
    this.partKey,
    this.partIndex,
    this.episode,
    this.exKey,
    this.hdRemasterLabel,
    this.hashZeroSubtitle,
    this.hasStrongOvaSubtitleTrait = false,
    this.hasEpisodeSubtitle = false,
    this.romanPartIndex,
    this.romanPartSubtitle,
    this.isHashZeroOva = false,
    this.ovaVolume,
    this.baseSeriesStem,
  });

  final String assetId;
  final String rel;
  final String name;
  final String subDir;
  final String cleanStem;
  final String normStem;
  final String kind;
  final String? quote;
  final int? year;
  final String? partKey;
  final int? partIndex;
  final int? episode;
  final String? exKey;
  final String? hdRemasterLabel;
  final String? hashZeroSubtitle;
  final bool hasStrongOvaSubtitleTrait;
  final bool hasEpisodeSubtitle;
  final int? romanPartIndex;
  final String? romanPartSubtitle;
  final bool isHashZeroOva;
  final int? ovaVolume;
  final String? baseSeriesStem;

  _FileEntry copyWith({
    String? kind,
    int? partIndex,
    String? partKey,
    int? episode,
    bool clearEpisode = false,
    bool? hasEpisodeSubtitle,
    String? cleanStem,
    String? normStem,
    String? quote,
    bool? isHashZeroOva,
    int? ovaVolume,
    String? baseSeriesStem,
  }) => _FileEntry(
    assetId: assetId,
    rel: rel,
    name: name,
    subDir: subDir,
    cleanStem: cleanStem ?? this.cleanStem,
    normStem: normStem ?? this.normStem,
    kind: kind ?? this.kind,
    quote: quote ?? this.quote,
    year: year,
    partKey: partKey ?? this.partKey,
    partIndex: partIndex ?? this.partIndex,
    episode: clearEpisode ? null : (episode ?? this.episode),
    exKey: exKey,
    hdRemasterLabel: hdRemasterLabel,
    hashZeroSubtitle: hashZeroSubtitle,
    hasStrongOvaSubtitleTrait: hasStrongOvaSubtitleTrait,
    hasEpisodeSubtitle: hasEpisodeSubtitle ?? this.hasEpisodeSubtitle,
    romanPartIndex: romanPartIndex,
    romanPartSubtitle: romanPartSubtitle,
    isHashZeroOva: isHashZeroOva ?? this.isHashZeroOva,
    ovaVolume: ovaVolume ?? this.ovaVolume,
    baseSeriesStem: baseSeriesStem ?? this.baseSeriesStem,
  );
}
