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
    this.episodeEnd,
    this.extraType,
  });

  final String assetId;
  final String relativePath;
  final String category;
  final int season;
  final int? episode;

  /// 多集合并文件的区间结束集号（仅正片，已应用集号偏移）。
  final int? episodeEnd;
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

/// 针对多作混装合集目录（如 `Movie & OVA`、`TV+Movie`、双作合集或剧场版上下篇）
/// 执行纯粹的本地确定性聚类拆分，
/// 全程绝不执行任何网络请求或媒体流文件读写。
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
    r'menus?(?:[ ._-]*ex)?\d*|menue\d*|hauptmenue|vorschau|'
    r'bd[ ._-]*menu\w*|bd[ ._-]*sp[ ._-]*live\w*|sp[ ._-]*live\w*|'
    r'bd[ ._-]*special[ ._-]*talk|special[ ._-]*talk|tokuten(?:[ ._-]*dvd)?|'
    r'greeting[ ._-]*event|stage[ ._-]*events?|premiere[ ._-]*event|'
    r'cv[ ._-]*chat|japan[ ._-]*expo|memorial[ ._-]*movie|'
    r'weekly[ ._-]*movies?|weekly[ ._-]*hero[ ._-]*countdown|shinka[ ._-]*scene|'
    r'picture[ ._-]*drama|trailer|teaser|preview|'
    r'music[ ._-]*(?:video|clip)|mv[ ._-]*making|'
    r'tv[ ._-]*spot|spot|making|digest|interview|iv\d+|commentary|'
    r'creditless|textless|appendix|sample|hyakka)(?:[ ._-]*\d+[a-z]?)?'
    r'(?![a-z0-9])|'
    r'[\[(（【]\s*mv\s*[\])）】]|'
    r'予告|預告|预告|特報|メイキング|ダイジェスト|総集編|总集篇|メニュ[ー一]|百科|'
    r'舞台挨拶|撮りおろし[^\r\n]*インタビュー|先付けミニアニメ|ミニアニメ|'
    r'ピクチャードラマ|スペシャル[ ._-]*映像|未公開(?:映像)?|プロモーション映像|劇場アナウンス|'
    r'アイキャッチ(?:集)?|オーディオ[ ._-]*コメンタリー|'
    r'(?:ミュージック|ミコージック)[ ._-・]*(?:ビデオ|クリップ)',
    caseSensitive: false,
  );
  static final _quoteBlock = RegExp(r'「([^」]+)」|『([^』]+)』');
  static const _minQuotedFeatureBytes = 300 * 1024 * 1024;
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
    r'^(?:ep(?:isode)?|part|vol(?:ume)?|'
    r'(?:the[\s._-]+)?movie(?:[\s._-]+(?:edition|ver(?:sion)?))?|'
    r'theatrical(?:[\s._-]+edition)?|film|ova|oad|sp|special|ex)?'
    r'[\s._-]*\d{0,4}$',
    caseSensitive: false,
  );

  static bool isExplicitCollectionFolder(
    String folder,
    DirectoryInventory inventory,
  ) {
    if (inventory.shape == WorkShape.anthology) return true;
    return _isExplicitCollectionName(folder);
  }

  /// 仅依据目录名判断是否显式声明多作合集（如 `A & B`、`TV+Movie`），不考虑目录内容形态。
  static bool _isExplicitCollectionName(String folder) {
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

  static List<String> explicitCollectionSegments(String folder) {
    final normFolder = folder
        .replaceAll('\\', '/')
        .replaceAll(RegExp(r'^/+|/+$'), '');
    final leafRaw =
        normFolder.split('/').where((s) => s.isNotEmpty).lastOrNull ?? '';
    if (leafRaw.isEmpty) return const [];
    final leafClean = PersonalFilenameParser.withoutTmdbMarkers(leafRaw)
        .replaceAll(
          RegExp(r'\(\s*(?:19|20)\d{2}\s*\)|（\s*(?:19|20)\d{2}\s*）'),
          ' ',
        )
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return _extractExplicitSegments(leafClean);
  }

  static bool shouldAutoSplitUnboundFolder(
    String folder,
    DirectoryInventory inventory,
    List<SubWorkCluster> preview,
  ) {
    if (preview.length < 2) return false;
    if (isExplicitCollectionFolder(folder, inventory)) return true;
    if (preview.length == 2 &&
        preview.every(
          (c) =>
              c.inventory.season == 0 &&
              RegExp(
                r'\balternative\b',
                caseSensitive: false,
              ).hasMatch('${c.virtualFolder} ${c.inventory.title}'),
        )) {
      return true;
    }
    final hasLongSeries = preview.any(
      (c) =>
          c.inventory.shape == WorkShape.series &&
          c.inventory.episodeCount >= 12 &&
          (c.inventory.season ?? 1) > 0,
    );
    // 长篇连续剧附带的 OVA、特别篇、广播剧、迷你短篇都是该剧的特典，只有明确的剧场版才独立成作。
    final hasStandaloneSubwork = preview.any((c) => c.inventory.movieMarker);
    if (hasLongSeries && hasStandaloneSubwork) return true;
    final hasMovie = preview.any((c) => c.inventory.movieMarker);
    final hasNonMovieSeries = preview.any(
      (c) => !c.inventory.movieMarker && c.inventory.episodeCount >= 6,
    );
    if (hasMovie && hasNonMovieSeries) return true;
    // 同目录合装多部独立剧场版（如 `剧场版 窈窕淑女` 内同时含 `zenpen`/`kouhen` 上下篇）：
    // 仅当全部拆出子簇均为独立单部剧场版且彼此标题不同（非同片多版本压制）时自动拆簇。
    if (preview.every(
      (c) => c.inventory.movieMarker && c.inventory.shape == WorkShape.feature,
    )) {
      final distinctTitles = preview
          .map((c) => DirectoryAnalyzer.normalize(c.inventory.title))
          .where((s) => s.isNotEmpty)
          .toSet();
      if (distinctTitles.length == preview.length) {
        return true;
      }
    }
    return false;
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

    final parsedRecords =
        <
          ({_FileEntry entry, bool isUnconditionalSide, bool isContextualSide})
        >[];

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

      final withoutUploaderTail = name.replaceFirst(
      RegExp(
        r'(?<=\])\s+[-–—]\s+[a-zA-Z][a-zA-Z0-9._-]{3,24}(?=\.[a-zA-Z0-9]{2,5}$|\s*$)',
      ),
      '',
    );
    final cleanName = CloudMediaFileClassifier.stripTechnicalNoise(
      withoutUploaderTail,
    );
      final inSuppDir =
          subDir.isNotEmpty &&
          CloudMediaFileClassifier.isSupplementarySubdirectory(subDir);
      final isUnconditionalSide =
          inSuppDir ||
          CloudMediaFileClassifier.isPreview(cleanName) ||
          CloudMediaFileClassifier.isNoCredit(cleanName) ||
          CloudMediaFileClassifier.bundledExtraTag.hasMatch(cleanName) ||
          _pureSideToken.hasMatch(cleanName) ||
          CloudMediaFileClassifier.isOpEdExtra(cleanName) ||
          (_hasBareSpTag(cleanName) &&
              maxSize > 0 &&
              size > 0 &&
              size < maxSize ~/ 3);
      final isContextualSide =
          !isUnconditionalSide &&
          (CloudMediaFileClassifier.adjacentBracketExtra.hasMatch(cleanName) ||
              CloudMediaFileClassifier.contextualJapanBdExtra.hasMatch(
                cleanName,
              ));

      final entry = _parseFileEntry(
        asset: asset,
        rel: rel,
        name: name,
        subDir: subDir,
      );
      parsedRecords.add((
        entry: entry,
        isUnconditionalSide: isUnconditionalSide,
        isContextualSide: isContextualSide,
      ));
    }

    final hasPrimaryNonExtra = parsedRecords.any(
      (r) => !r.isUnconditionalSide && !r.isContextualSide,
    );
    for (final record in parsedRecords) {
      if (record.isUnconditionalSide ||
          (hasPrimaryNonExtra && record.isContextualSide)) {
        extraFiles.add(record.entry);
      } else {
        mainFiles.add(record.entry);
      }
    }

    if (mainFiles.length < 2) return const [];

    final refinedMain = _refineMainEntries(
      mainFiles,
      leafClean: leafClean,
      folderTmdbId: folderTmdbId,
    );

    // 按 `(首个非特典子目录, 聚类签名)` 对候选正片文件分组。
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
        // 在显式声明 `{tmdb-N}` 的剧集目录内，保留全部常规 TV 季与光盘分卷于同一主聚类，
        // 同时仅允许目录内捆绑的独立剧场版、OVA 或 `#00` 序章章节
        // 干净拆分出去作为独立逻辑作品。
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

    // 同时拆分子目录内同存多部不同名无编号正片，或包含两卷独立外传 OVA
    //（如 `- 01 / - 02` 篇目）的复合结构。
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
            item.copyWith(kind: 'ova', ovaVolume: item.episode),
          ]);
        }
      } else {
        expandedBuckets.add(group);
      }
    }

    if (expandedBuckets.length < 2) return const [];

    // 防止非显式合集的同人短片/MV 合盘（无集号、非显式电影且普遍小于 300 MB）被碎片化拆成数十部假电影。
    if (folderTmdbId == null &&
        explicitSegments.isEmpty &&
        !_isExplicitCollectionName(normFolder) &&
        expandedBuckets.length >= 6 &&
        expandedBuckets.every(
          (g) =>
              g.length == 1 &&
              g.single.episode == null &&
              g.single.kind != 'movie',
        )) {
      final sizedCount = expandedBuckets.where((g) => g.single.size > 0).length;
      final smallCount = expandedBuckets
          .where(
            (g) => g.single.size > 0 && g.single.size < _minQuotedFeatureBytes,
          )
          .length;
      if (sizedCount >= 6 && smallCount * 10 >= sizedCount * 7) {
        return const [];
      }
    }

    // 对显式 `{tmdb-N}` 目录，仅当存在至少一个明确的独立剧场版或独立 OVA 子聚类时
    // 才执行与主 TV 剧集之间的拆分。
    bool isExplicitStandaloneCluster(List<_FileEntry> g) =>
        g.first.kind == 'movie' ||
        g.first.kind == 'ova' ||
        g.first.isHashZeroOva ||
        g.first.ovaVolume != null ||
        g.first.exKey != null ||
        g.any(
          (e) => _ovaToken.hasMatch(e.name) || _movieToken.hasMatch(e.name),
        );

    final clusterIsMainTv = <bool>[
      for (final g in expandedBuckets)
        folderTmdbId != null &&
            ((g.first.kind == 'series' &&
                    !g.first.isHashZeroOva &&
                    g.first.ovaVolume == null &&
                    g.any((e) => e.episode != null)) ||
                !isExplicitStandaloneCluster(g)),
    ];
    if (folderTmdbId != null) {
      final hasDetachedSubwork = clusterIsMainTv.any((isMain) => !isMain);
      if (!hasDetachedSubwork) return const [];
    }

    // 贪心配对目录名显式拆出的名称片段（兼容因附加 OVA 导致目录片段少于实际聚类的情况）。
    // 保障部分显式分段目录依然能对齐所属作品。
    final assignedSegment = _pairExplicitSegments(
      expandedBuckets,
      explicitSegments,
    );

    // 将特典文件归属至词法相似度最高的目标正片聚类。
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
    // 同目录内即使与 TV 正片混放，只要同一剧场版主干恰好拆出 `01`/`02` 两部共享完全相同主干名且无独立副标题的剧场版
    // （如 `DDDD The Movie - 01/02`、`地球外少年少女 [Movie 01]/[Movie 02]`），按上下/前后篇成对标注；
    // 自带独立章节副标题的双部剧场版（如 `薄樱鬼 第一章 京都乱舞 / 第二章 士魂苍穹`）保持原副标题不覆盖。
    final movieIndicesByStem = <String, Set<int>>{};
    final movieBucketsByStem = <String, int>{};
    final movieCleanStemsByStem = <String, Set<String>>{};
    for (final g in expandedBuckets) {
      final rep = g.first;
      if (rep.kind == 'movie' &&
          rep.partKey == null &&
          rep.quote == null &&
          rep.partIndex != null) {
        movieBucketsByStem.update(
          rep.normStem,
          (n) => n + 1,
          ifAbsent: () => 1,
        );
        (movieIndicesByStem[rep.normStem] ??= <int>{}).add(rep.partIndex!);
        (movieCleanStemsByStem[rep.normStem] ??= <String>{}).add(
          DirectoryAnalyzer.normalize(rep.cleanStem),
        );
      }
    }
    final twoPartMovieStems = <String>{
      for (final e in movieIndicesByStem.entries)
        if (movieBucketsByStem[e.key] == 2 &&
            (movieCleanStemsByStem[e.key]?.length ?? 0) == 1 &&
            e.value.length == 2 &&
            e.value.containsAll(const {1, 2}))
          e.key,
    };

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
      final isTwoPartCluster =
          (twoPartIndices &&
              expandedBuckets
                      .map((g) => DirectoryAnalyzer.normalize(g.first.cleanStem))
                      .toSet()
                      .length ==
                  1) ||
          (group.first.kind == 'movie' &&
              twoPartMovieStems.contains(group.first.normStem));
      final clusterInfo = _buildClusterMetadata(
        index: i,
        group: group,
        extras: extras,
        stemInfo: stemInfo,
        leafClean: leafClean,
        explicitTitle: explicitTitle,
        twoPartPair: isTwoPartCluster,
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

  /// `标题 10` 这类无前导零的集号会被保守地保留在片名里（防止误删 `86`、`Mob Psycho 100` 等数字片名）；
  /// 若剥离末尾集号后的主干与同目录其他编号正片一致，则归并为同一主干，避免逐集拆成独立作品。
  static List<_FileEntry> _foldTrailingEpisodeIntoStem(List<_FileEntry> files) {
    final stems = <String>{
      for (final e in files)
        if (e.kind == 'series' && e.episode != null) e.normStem,
    };
    return [
      for (final e in files)
        if (e.kind == 'series' &&
            e.episode != null &&
            e.normStem.length > '${e.episode}'.length &&
            e.normStem.endsWith('${e.episode}') &&
            stems.contains(
              e.normStem.substring(
                0,
                e.normStem.length - '${e.episode}'.length,
              ),
            ))
          e.copyWith(
            normStem: e.normStem.substring(
              0,
              e.normStem.length - '${e.episode}'.length,
            ),
            cleanStem: e.cleanStem
                .replaceFirst(RegExp('[\\s._-]*0*${e.episode}\\s*\$'), '')
                .trim(),
          )
        else
          e,
    ];
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
      if (e.kind != 'series') continue;
      final m = dashEpSub.firstMatch(e.cleanStem);
      if (m == null) continue;
      final epNum = int.tryParse(m.group(2)!);
      final prefix = m.group(1)!.trim();
      if (epNum == null || epNum < 1 || epNum > 999 || prefix.isEmpty) continue;
      if (e.episode != null && e.episode != epNum) continue;
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
    final mainFiles = _foldTrailingEpisodeIntoStem(
      _normalizeDashEpisodeSubtitles(rawMainFiles),
    );
    final numberedSeries = mainFiles
        .where(
          (e) => e.kind == 'series' && e.episode != null && e.episode! >= 1,
        )
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

    final refined = mainFiles.map((e) {
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
        // 「引号副标题」只在体量接近剧场版时才视作独立剧场版，几十 MB 的引号短片（迷你剧场、PV）仍按特典处理。
        if (folderHasMovieMarker ||
            (folderTmdbId == null &&
                e.quote != null &&
                e.normStem != dominantSeriesNorm &&
                (e.size <= 0 || e.size >= _minQuotedFeatureBytes))) {
          return e.copyWith(kind: 'movie');
        }
      }
      return e;
    }).toList();

    return _detachLongSeriesNamedOvaSubworks(
      refined,
      folderTmdbId: folderTmdbId,
    );
  }

  /// 从长篇连续 TV 主系列中拆出带专属副标题的衍生 OVA 子系列与独立特别剧场版
  /// （例如主线 `001..112` 与独立外传 `II - 01..04`、`Two Shots` 拆分），
  /// 同时确保诸如 `Title Season 2`、`Title II` 等常规续季条目不被错误割裂。
  /// 兼顾外传拆分精度与多季连贯性。
  static List<_FileEntry> _detachLongSeriesNamedOvaSubworks(
    List<_FileEntry> entries, {
    int? folderTmdbId,
  }) {
    final seriesEpsByNorm = <String, Set<int>>{};
    for (final e in entries) {
      if (e.kind == 'series' && e.episode != null && e.episode! >= 1) {
        (seriesEpsByNorm[e.normStem] ??= <int>{}).add(e.episode!);
      }
    }
    if (seriesEpsByNorm.isEmpty) return entries;

    final domEntry = seriesEpsByNorm.entries.reduce(
      (a, b) => a.value.length >= b.value.length ? a : b,
    );
    final domNorm = domEntry.key;
    final domEps = domEntry.value;
    final maxDomEp = domEps.fold<int>(0, (m, ep) => ep > m ? ep : m);
    if (domEps.length < 12 || maxDomEp < 12) return entries;

    final otherByNorm = <String, List<_FileEntry>>{};
    for (final e in entries) {
      if (e.kind == 'series' && e.normStem != domNorm) {
        (otherByNorm[e.normStem] ??= []).add(e);
      }
    }
    if (otherByNorm.isEmpty) return entries;

    final seasonSuffix = RegExp(
      r'\b(?:season\s*\d{1,2}|s\d{1,2}|\d{1,2}(?:st|nd|rd|th)\s+season|'
      r'part\s*\d{1,2}|cour\s*\d{1,2}|(?:zoku|final)\s+season)\b|'
      r'第[0-9一二三四五六七八九十]+[季期部]|'
      r'\s+(?:II|III|IV|V|Ⅰ|Ⅱ|Ⅲ|Ⅳ|Ⅴ|[2-4])$',
      caseSensitive: false,
    );

    final detachedNorms = <String>{};
    for (final item in otherByNorm.entries) {
      final rep = item.value.first;
      final strippedNorm = DirectoryAnalyzer.normalize(
        rep.cleanStem.replaceAll(seasonSuffix, ' '),
      );
      if (strippedNorm == domNorm) continue;

      final groupEps = item.value
          .map((e) => e.episode)
          .whereType<int>()
          .toSet();
      final unnumbered = groupEps.isEmpty;
      final shortOverlappingRun =
          groupEps.isNotEmpty &&
          groupEps.length <= 8 &&
          groupEps.length < domEps.length ~/ 3 &&
          groupEps.any((ep) => ep <= 4) &&
          groupEps.any(domEps.contains);
      final hasExplicitStandaloneMarker = item.value.any(
        (e) =>
            _ovaToken.hasMatch(e.name) ||
            _movieToken.hasMatch(e.name) ||
            e.isHashZeroOva ||
            e.ovaVolume != null ||
            e.exKey != null,
      );
      final hasDatedSpinOff =
          unnumbered && item.value.any((e) => e.year != null);
      if (folderTmdbId != null &&
          !hasExplicitStandaloneMarker &&
          !shortOverlappingRun &&
          !hasDatedSpinOff) {
        continue;
      }
      if (unnumbered || shortOverlappingRun) {
        detachedNorms.add(item.key);
      }
    }
    if (detachedNorms.isEmpty) return entries;

    return [
      for (final e in entries)
        if (e.kind == 'series' && detachedNorms.contains(e.normStem))
          e.copyWith(kind: 'ova')
        else
          e,
    ];
  }

  static bool _isTwoVolumeAlternativeGroup(List<_FileEntry> group) {
    if (group.length != 2) return false;
    if (!group.every((e) => e.kind == 'series' && e.episode != null)) {
      return false;
    }
    final eps = group.map((e) => e.episode!).toSet();
    if (eps.length != 2 || !eps.containsAll(const {1, 2})) return false;
    final rep = group.first;
    if (!RegExp(
      r'\balternative\b',
      caseSensitive: false,
    ).hasMatch(rep.cleanStem)) {
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
    final isMultiEpisodeEx =
        first.exKey != null &&
        group.length >= 2 &&
        group.every((e) => e.episode != null);
    final isSingleFeature =
        first.kind == 'movie' ||
        (!isMultiEpisodeEx && isOvaSeasonZero) ||
        (group.length == 1 &&
            (first.episode == null ||
                (explicitTitle != null && first.episode == 1)));
    final years = group.map((e) => e.year).whereType<int>().toSet();
    final clusterYear = years.length == 1 ? years.single : null;

    // 对起始集号大于 `1` 的连续多集 OVA 篇章重新归一化局部编号
    // （例如 OVA 篇章 `04..06` 重映射为本地连续第 `1..3` 话）。
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
          .replaceAll(
            RegExp(
              r'\s*[\[(（【]?\s*ex[ ._-]*\d*\s*[\])）】]?\s*$',
              caseSensitive: false,
            ),
            '',
          )
          .trim();
      final exUpper = first.exKey!.toUpperCase();
      addHint(baseNoEx.isEmpty ? exUpper : '$baseNoEx $exUpper');
    }

    final combinableParent = stemInfo.combinableStem(leafClean);
    if (first.ovaVolume != null) {
      final volWord = first.ovaVolume == 1
          ? 'ONE'
          : first.ovaVolume == 2
          ? 'TWO'
          : '${first.ovaVolume}';
      final parentAlt = combinableParent ?? stemInfo.fallbackStem;
      if (parentAlt != null && parentAlt.isNotEmpty) {
        final hasAltWord = RegExp(
          r'\balternative\b',
          caseSensitive: false,
        ).hasMatch(parentAlt);
        final stemHasAltWord = RegExp(
          r'\balternative\b',
          caseSensitive: false,
        ).hasMatch(cleanStem);
        final altBase = !hasAltWord && stemHasAltWord
            ? '$parentAlt Alternative'
            : parentAlt;
        addHint('$altBase $volWord');
        addHint('$altBase ${first.ovaVolume}');
      }
      addHint('$cleanStem $volWord');
      addHint('$cleanStem ${first.ovaVolume}');
    }

    final localizedPart =
        _localizedPartLabel(first.partKey) ??
        (twoPartPair && first.partKey == null
            ? (first.partIndex == 1
                  ? '前篇'
                  : first.partIndex == 2
                  ? '后篇'
                  : null)
            : null);
    final arcLabelMatch =
        first.partKey != null && first.partKey!.startsWith('hen:')
        ? RegExp(
            r'([a-z]{3,16}[\s._-]+hen|[\u4e00-\u9fff\u3040-\u30ff]{1,6}[編篇])(?![a-z0-9])',
            caseSensitive: false,
          ).firstMatch('$cleanStem ${first.subDir}')
        : null;
    final arcLabel = arcLabelMatch?.group(1)?.trim();
    if (combinableParent != null && combinableParent.isNotEmpty) {
      if (arcLabel != null &&
          arcLabel.isNotEmpty &&
          (!hasIndependentTitle || !RegExp(r'\d').hasMatch(cleanStem))) {
        addHint('$combinableParent $arcLabel');
      }
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
            RegExp(r'\b(?:the\s+movie|movie|ova|oad)\b', caseSensitive: false),
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
      final movieHasOwnQuote =
          first.kind == 'movie' &&
          first.quote != null &&
          first.quote!.isNotEmpty &&
          !first.isHashZeroOva;
      if (twoPartPair && localizedPart != null && first.partKey == null) {
        final stemNoMovie = cleanStem
            .replaceAll(
              RegExp(
                r'\b(?:the\s+movie|movie)\b|剧场版|劇場版',
                caseSensitive: false,
              ),
              ' ',
            )
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
        if (stemNoMovie.isNotEmpty) {
          addHint('$stemNoMovie $localizedPart');
          addHint('$stemNoMovie Part ${first.partIndex}');
        }
      }
      // 已携带专属方括号/引号副标题的独立剧场版（如 `The Movie - 02 [ Tachiagare!! Avan no Shito ]`）
      // 不再把剥离副标题后的裸主干注入标题提示，避免与同系列第 1 部无副标题剧场版打平。
      if (!movieHasOwnQuote) {
        addHint(cleanStem);
        if (first.kind == 'movie') {
          final strippedMovie = cleanStem
              .replaceAll(
                RegExp(
                  r'\b(?:the\s+movie|movie)\b|剧场版|劇場版',
                  caseSensitive: false,
                ),
                ' ',
              )
              .replaceAll(RegExp(r'\s+'), ' ')
              .trim();
          if (strippedMovie.isNotEmpty && strippedMovie != cleanStem) {
            addHint(strippedMovie);
          }
        }
      }
    }
    if (combinableParent != null &&
        combinableParent.isNotEmpty &&
        arcLabel != null &&
        arcLabel.isNotEmpty) {
      addHint('$combinableParent $arcLabel');
    }

    if (first.isHashZeroOva && first.hashZeroSubtitle != null) {
      addHint(first.hashZeroSubtitle);
    }

    // 隔离外层合集目录词干：仅当子聚类本身既无目录分段又无独立文件名主标题时，
    // 才注入父级合集目录词干作为兜底检索名称。
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
      // 区间文件按 (起始集, 结束集) 分桶，避免与单独的起始集文件并成多版本。
      final byEp = <String, List<_FileEntry>>{};
      final epOfKey = <String, ({int ep, int? end})>{};
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
        final rawEnd = f.episode == null ? null : f.episodeEnd;
        final normEnd = rawEnd == null ? null : rawEnd - epOffset;
        final bucketKey = normEnd == null ? '$normEp' : '$normEp-$normEnd';
        (byEp[bucketKey] ??= []).add(f);
        epOfKey[bucketKey] = (ep: normEp, end: normEnd);
        assignments.add(
          SplitAssetAssignment(
            assetId: f.assetId,
            relativePath: f.rel,
            category: 'main',
            season: assignSeason,
            episode: normEp,
            episodeEnd: normEnd,
          ),
        );
      }
      final sortedKeys = byEp.keys.toList()
        ..sort((a, b) {
          final ka = epOfKey[a]!;
          final kb = epOfKey[b]!;
          final c = ka.ep.compareTo(kb.ep);
          return c != 0 ? c : (ka.end ?? 0).compareTo(kb.end ?? 0);
        });
      for (final bucketKey in sortedKeys) {
        final info = epOfKey[bucketKey]!;
        final item = LogicalItem(
          's${assignSeason}e$bucketKey',
          primaryTitle,
          info.ep,
          clusterSeason,
          episodeEnd: info.end,
        )..files.addAll([for (final f in byEp[bucketKey]!) f.rel]);
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

    final movieOwnQuote =
        first.kind == 'movie' &&
        first.quote != null &&
        first.quote!.isNotEmpty &&
        !first.isHashZeroOva;
    final fileHints = <String>[
      for (final f in group.take(3))
        if (movieOwnQuote && f.quote != null && f.quote!.isNotEmpty)
          '${f.cleanStem} ${f.quote!}'.trim()
        else if (f.cleanStem.isNotEmpty)
          f.cleanStem,
      if (first.baseSeriesStem != null && first.baseSeriesStem!.isNotEmpty)
        first.baseSeriesStem!,
      if (!movieOwnQuote &&
          parentSeriesFileHint != null &&
          parentSeriesFileHint.isNotEmpty)
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
    final withoutUploaderTail = name.replaceFirst(
      RegExp(
        r'(?<=\])\s+[-–—]\s+[a-zA-Z][a-zA-Z0-9._-]{3,24}(?=\.[a-zA-Z0-9]{2,5}$|\s*$)',
      ),
      '',
    );
    final rawBaseBeforeTechStrip = PersonalFilenameParser.baseNameWithoutExtension(
      withoutUploaderTail,
    );
    final cleanName = CloudMediaFileClassifier.stripTechnicalNoise(
      withoutUploaderTail,
    );
    final base = PersonalFilenameParser.baseNameWithoutExtension(cleanName);
    final quoteMatch = _quoteBlock.firstMatch(base);
    final quote = (quoteMatch?.group(1) ?? quoteMatch?.group(2))?.trim();
    final yearMatch = RegExp(
      r'[\[(（]\s*((?:19|20)\d{2})\s*[\])）]|'
      r'(?<=\b(?:movie|ova|oad|tv|ver\.?)\s+)((?:19|20)\d{2})(?![a-z0-9%])|'
      r'(?<![a-z0-9])((?:19|20)\d{2})(?=\s*(?:「|『|\[|\(|ep\d*\b|ova\b|oad\b|movie\b|anime\b|hd\b|-))|'
      r'(?<=\b(?:movie|ova|oad|part|chapter)[\s._-]*\d{1,2}[\s._-])((?:19|20)\d{2})(?=$|[\s._\-)\]])',
      caseSensitive: false,
    ).firstMatch(rawBaseBeforeTechStrip);
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
    final rawEx = exMatch?.group(1);
    final exEp = rawEx == null
        ? null
        : int.tryParse(RegExp(r'(\d{1,2})$').firstMatch(rawEx)?.group(1) ?? '');
    final exKey = rawEx != null ? 'ex' : null;

    final epBeforeQuote = RegExp(
      r'[\s._]+[-–—][\s._]+\d{1,3}(?:v\d+)?[\s._]+[-–—][\s._]+(?=[「『])',
    ).firstMatch(base);
    final baseForStem = epBeforeQuote != null
        ? base.substring(0, epBeforeQuote.start)
        : base;
    final sceneStrippedBase = PersonalFilenameParser.stripUnbracketedTechTokens(
      baseForStem,
    );

    final withoutQuote = sceneStrippedBase
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
        )
        .replaceFirst(RegExp(r'(?:\s*[-–—]+)+\s*$'), '');
    final stemSource = exKey != null
        ? withoutQuote.replaceAll(_exTagPattern, ' ')
        : withoutQuote;
    var cleanStem = PersonalFilenameParser.extractAnimeTitleKeyword(stemSource)
        .replaceAll(
          RegExp(r'\s*[-–—]\s*\d{1,3}(?:v\d+)?(?:\s*[-–—]+)?\s*$'),
          '',
        )
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (year != null && cleanStem.endsWith(' $year')) {
      final withoutTrailingYear = cleanStem
          .substring(0, cleanStem.length - ' $year'.length)
          .trim();
      if (withoutTrailingYear.length >= 4) {
        cleanStem = withoutTrailingYear;
      }
    }
    if (cleanStem.isEmpty) {
      cleanStem = PersonalFilenameParser.extractAnimeTitleKeyword(
        PersonalFilenameParser.stripUnbracketedTechTokens(cleanName),
      );
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

    var effectiveCleanStem = cleanStem;
    var effectivePartKey = _detectPartKey(base);
    var effectivePartIndex = _detectPartIndex(base);
    var effectiveRomanPartIndex = romanPartIndex;
    var effectiveRomanPartSubtitle = romanPartSubtitle;
    final hasBundledRangeMovie = RegExp(
      r'[\[【]\s*\d{1,3}\s*[-–—~～]\s*\d{1,3}\s*[\(（]\s*movie\s*[\)）]\s*[\]】]',
      caseSensitive: false,
    ).hasMatch(base);
    final isNonFeatureMovieExtra = RegExp(
      r'memorial[ ._-]*movie|weekly[ ._-]*movies?|digest[ ._-]*movie',
      caseSensitive: false,
    ).hasMatch(base);
    final hasChapterVolumeMovie =
        RegExp(r'[#＃]\s*0*[1-9]\s*[～~〜][^～~〜]+?[の之]?[巻卷]').hasMatch(base) &&
        ((asset['size'] as num?)?.toInt() ?? 0) >= _minQuotedFeatureBytes;
    final epQuoteClean = PersonalFilenameParser.stripUnbracketedTechTokens(base)
        .replaceAll(_quoteBlock, ' ')
        .replaceAll(RegExp(r'[\[(]\s*(?:19|20)\d{2}\s*[\])]'), ' ')
        .replaceAll(RegExp(r'\b(?:19|20)\d{2}\b'), ' ')
        .replaceFirst(RegExp(r'(?:\s*[-–—]+)+\s*$'), '');
    final prelimSpan = exKey != null
        ? null
        : CloudMediaFileClassifier.episodeSpanFromName(epQuoteClean);
    // 裸汉字「映画」若出现在带常规集号的单集副标题中（如 `映画監督は宇宙人`），不视作独立剧场版。
    final strongMovieToken = RegExp(
      r'(?<![a-z0-9])(?:the[ ._-]+)?movie(?![a-z0-9])|劇場版|剧场版',
      caseSensitive: false,
    );
    final movieTokenHit =
        strongMovieToken.hasMatch(base) ||
        (prelimSpan == null && _movieToken.hasMatch(base));
    final isMovie =
        hasChapterVolumeMovie ||
        (!hasBundledRangeMovie &&
            !isNonFeatureMovieExtra &&
            (movieTokenHit ||
                (subDir.isNotEmpty && _movieSubdir.hasMatch(subDir))));
    final isOva = exKey != null || (!isMovie && _ovaToken.hasMatch(base));
    // 提取剧场版文件名在 `Movie` / 序号之后方括号内的非技术副标题（如 `The Movie - 02 [ Tachiagare!! Avan no Shito ]`），
    // 自动排除集号区间（如 `[ EP.05~08 ]`）、技术标签、压制组与纯数字校验码。
    var effectiveQuote = quote;
    if (isMovie && effectiveQuote == null) {
      final moviePos = _movieToken.firstMatch(rawBaseBeforeTechStrip);
      if (moviePos != null) {
        final afterMovie = rawBaseBeforeTechStrip.substring(moviePos.end);
        for (final bm in RegExp(r'\[([^\[\]]{4,80})\]').allMatches(afterMovie)) {
          final inner = bm.group(1)!.replaceAll(RegExp(r'\s+'), ' ').trim();
          if (inner.isEmpty) continue;
          if (PersonalFilenameParser.isTechnicalBracketBlock(inner) ||
              PersonalFilenameParser.isReleaseGroupTag(inner)) {
            continue;
          }
          if (RegExp(
            r'^(?:ep\.?\s*\d|movie\s*\d|sp\s*\d|vol\.?\s*\d|part\s*\d|[0-9a-f]{8}$|\d+$)',
            caseSensitive: false,
          ).hasMatch(inner)) {
            continue;
          }
          final letters = inner.replaceAll(RegExp(r'[^a-zA-Z\u3040-\u9fff]'), '');
          if (letters.length >= 4) {
            effectiveQuote = inner;
            break;
          }
        }
      }
    }
    var hashMovieMatched = false;
    if (isMovie && effectiveRomanPartIndex == null) {
      final hashMovieMatch = RegExp(
        r'^(.*?\S)\s*[#＃]\s*0*([1-9])\s*(?:[～~〜]\s*)?(\S.*)$',
      ).firstMatch(effectiveCleanStem);
      if (hashMovieMatch != null) {
        final numIdx = int.tryParse(hashMovieMatch.group(2)!);
        final sub = hashMovieMatch.group(3)!.trim();
        if (numIdx != null && numIdx >= 1 && numIdx <= 9 && sub.length >= 2) {
          const romans = [
            'I',
            'II',
            'III',
            'IV',
            'V',
            'VI',
            'VII',
            'VIII',
            'IX',
          ];
          final roman = romans[numIdx - 1];
          final cleanSub = sub
              .replaceAll(RegExp(r'^[～~〜\s]+|[～~〜\s]+$'), '')
              .trim();
          final isPurePartSub = RegExp(
            r'^(?:前編|後編|中編|前篇|后篇|中篇|上篇|下篇)$',
          ).hasMatch(cleanSub);
          // `#1～雪の巻～` 或 `#01 前編`/`#02 後編` 保持原卷名或分篇名，不注入原片名中不存在的罗马数字 I/II/III。
          effectiveCleanStem =
              (hasChapterVolumeMovie || isPurePartSub) && cleanSub.isNotEmpty
              ? '${hashMovieMatch.group(1)!.trim()} $cleanSub'
              : '${hashMovieMatch.group(1)!.trim()} $roman $sub';
          effectiveRomanPartIndex = numIdx;
          effectiveRomanPartSubtitle = sub;
          effectivePartIndex ??= numIdx;
          effectivePartKey ??= hasChapterVolumeMovie
              ? 'vol_$numIdx'
              : 'roman_$numIdx';
          hashMovieMatched = true;
        }
      }
    }
    final span = hashMovieMatched ? null : prelimSpan;
    final ep = hashMovieMatched ? null : (exKey != null ? exEp : span?.start);
    final epEnd = span?.end;
    final hasEpisodeSubtitle =
        ep != null && ep >= 1 && _hasExplicitEpisodeSubtitle(strippedBase, ep);
    final kind = isMovie
        ? 'movie'
        : isOva
        ? 'ova'
        : 'series';
    final stemForBucket = effectiveCleanStem
        .replaceAll(
          RegExp(r'\b(?:the\s+movie|movie|ova|oad)\b', caseSensitive: false),
          ' ',
        )
        .replaceAll(
          RegExp(r'\s+[-–—]\s*\d{1,3}(?:v\d+)?(?:\s*[-–—]+)?\s*$'),
          '',
        )
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final isGenericSeries =
        kind == 'series' &&
        ep != null &&
        _genericStandaloneStem.hasMatch(effectiveCleanStem);
    final normStem = isGenericSeries
        ? '__generic_series__'
        : DirectoryAnalyzer.normalize(
            stemForBucket.isEmpty ? effectiveCleanStem : stemForBucket,
          );

    return _FileEntry(
      size: (asset['size'] as num?)?.toInt() ?? 0,
      assetId: asset['id'].toString(),
      rel: rel,
      name: name,
      subDir: subDir,
      cleanStem: effectiveCleanStem,
      normStem: normStem.isEmpty
          ? DirectoryAnalyzer.normalize(effectiveCleanStem)
          : normStem,
      quote: effectiveQuote,
      year: year,
      partKey: effectivePartKey,
      partIndex: effectivePartIndex,
      kind: kind,
      episode: ep,
      episodeEnd: epEnd,
      exKey: exKey,
      hdRemasterLabel: hdRemasterLabel,
      hashZeroSubtitle: hashZeroSubtitle,
      hasStrongOvaSubtitleTrait: hasStrongOvaSubtitleTrait,
      hasEpisodeSubtitle: hasEpisodeSubtitle,
      romanPartIndex: effectiveRomanPartIndex,
      romanPartSubtitle: effectiveRomanPartSubtitle,
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
    final cjkChapter = RegExp(
      r'第\s*([0-9一二三四五六七八九十]{1,2})\s*[章部巻卷]',
    ).firstMatch(base);
    if (cjkChapter != null) {
      const zhNum = <String, int>{
        '一': 1,
        '二': 2,
        '三': 3,
        '四': 4,
        '五': 5,
        '六': 6,
        '七': 7,
        '八': 8,
        '九': 9,
        '十': 10,
      };
      final raw = cjkChapter.group(1)!;
      final v = int.tryParse(raw) ?? zhNum[raw];
      if (v != null && v >= 1 && v <= 20) return v;
    }
    final hashVol = RegExp(
      r'[#＃]\s*0*([1-9])\s*[～~〜][^～~〜]+?[の之]?[巻卷]',
    ).firstMatch(base);
    if (hashVol != null) {
      return int.tryParse(hashVol.group(1)!);
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

    // 对所有 `(文件名组, 目录分段)` 组合计算匹配分值，并按特异度从高到低全局贪心指派，
    // 确保特征鲜明的续作或外传优先认领对应聚类，避免被较短的通配基础片名提前抢占。
    // 防止跨季或衍生作品分配错位。
    final candidates = <({int gi, int si, int score})>[];
    for (var gi = 0; gi < groups.length; gi++) {
      final rep = groups[gi].first;
      final groupNorm = DirectoryAnalyzer.normalize(rep.cleanStem);
      final sampleRaw = groups[gi]
          .map((e) => '${e.subDir} ${e.name}')
          .join(' ');
      final sampleClean = CloudMediaFileClassifier.stripTechnicalNoise(
        sampleRaw,
      );
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
            lexicalScore +=
                140 - (groupNorm.length - segNorm.length).clamp(0, 60);
          } else if (groupNorm.length >= 2 && segNorm.contains(groupNorm)) {
            lexicalScore +=
                140 - (segNorm.length - groupNorm.length).clamp(0, 60);
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

    // 仅当目录片段与剩余聚类数量一致，且具备部分词汇重叠或至少一组缺乏独立多词文件名标题时，
    // 才允许按目录排序强制兜底绑定；若词汇重叠完全为零且各组均自带清晰独立文件名主标题
    // （例如简中合集目录名搭配乱序罗马音文件名），则保留组内文件名解析标题，
    // 严禁按顺序强行错配。
    // 避免中英/日罗马音目录文件排列顺序差异造成集体错绑。
    // 保留高可信的文件名级作品识别线索。
    // 杜绝顺序强绑导致的交叉错配问题。
    final allGroupsHaveDistinctDescriptiveTitles =
        groups.every(
          (g) =>
              g.first.cleanStem.isNotEmpty &&
              !_genericStandaloneStem.hasMatch(g.first.cleanStem) &&
              RegExp(
                    r'[a-z\u3040-\u9fff]{3,}',
                    caseSensitive: false,
                  ).allMatches(g.first.cleanStem).length >=
                  2,
        ) &&
        groups.map((g) => g.first.normStem).toSet().length == groups.length;
    if (segments.length == groups.length &&
        (result.isNotEmpty || !allGroupsHaveDistinctDescriptiveTitles)) {
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
          RegExp(r'予告|預告|预告|特報|メイキング|ノンクレジット|ノンクレ|映像特典|特典|メニュ[ー一]'),
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
        .where(
          (s) =>
              s.isNotEmpty &&
              !CloudMediaFileClassifier.isSupplementaryDirectory(s),
        )
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

    final extraMentionsMovie = _movieToken.hasMatch(cleanExtraName);
    final extraMentionsOva = _ovaToken.hasMatch(cleanExtraName);
    var largestMainTvIdx = -1;
    var largestMainTvLen = 0;
    for (var i = 0; i < groups.length; i++) {
      final rep = groups[i].first;
      if (rep.kind == 'series' &&
          !rep.isHashZeroOva &&
          rep.exKey == null &&
          rep.ovaVolume == null &&
          groups[i].length > largestMainTvLen) {
        largestMainTvLen = groups[i].length;
        largestMainTvIdx = i;
      }
    }

    var bestIdx = 0;
    var bestScore = -1000000;
    for (var i = 0; i < groups.length; i++) {
      final rep = groups[i].first;
      var score = 0;
      final isMainTv =
          rep.kind == 'series' &&
          !rep.isHashZeroOva &&
          rep.exKey == null &&
          rep.ovaVolume == null;

      if (extraTopSub.isNotEmpty &&
          !CloudMediaFileClassifier.isSupplementaryDirectory(extraTopSub) &&
          rep.subDir.split('/').first.trim() == extraTopSub) {
        score += 35;
      }
      if (rep.exKey != null &&
          extraExKey != null &&
          (extraExKey == rep.exKey || rep.exKey == 'ex')) {
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

      if (extraExKey == null) {
        if (extraMentionsMovie && rep.kind == 'movie') {
          score += 25;
        } else if (extraMentionsOva && rep.kind == 'ova') {
          score += 20;
        } else if (!extraMentionsMovie && !extraMentionsOva && isMainTv) {
          score += 18 + groups[i].length.clamp(0, 24);
        }
      }

      final cNorm = clusterNorms[i];
      if (cNorm.isNotEmpty && extraCleanNorm.isNotEmpty) {
        if (extraCleanNorm == cNorm) {
          score += 55;
        } else if (cNorm.length >= 4 && extraCleanNorm.contains(cNorm)) {
          score += 15 + cNorm.length.clamp(4, 40);
        } else if (extraCleanNorm.length >= 4 &&
            cNorm.contains(extraCleanNorm)) {
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
      // 若其他聚类特有的区分词元未出现在当前特典文件上，则对其略作扣分，
      // 使共享前缀的无副标题特典（如 `Title NCOP1`）优先留给主作 `Title`。
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
    if (bestScore > 0) return bestIdx;
    return largestMainTvIdx >= 0 ? largestMainTvIdx : 0;
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
        DirectoryAnalyzer.normalize(
          leafClean,
        ).contains(DirectoryAnalyzer.normalize(grandparentStem!))) {
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
    this.episodeEnd,
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
    this.size = 0,
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
  final int? episodeEnd;
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

  /// 文件字节大小（未知时为 0）。
  final int size;

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
    // 集号被改写（或清空）后原区间不再可信，一并清除。
    episodeEnd: (clearEpisode || (episode != null && episode != this.episode))
        ? null
        : episodeEnd,
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
    size: size,
  );
}
