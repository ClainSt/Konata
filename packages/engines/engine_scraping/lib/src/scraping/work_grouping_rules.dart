part of 'scrape_rules.dart';

final RegExp _movieMarkerPattern = RegExp(
  r'\b(?:movie|film|theatrical)\b|剧场版|劇場版|映画',
  caseSensitive: false,
);

final RegExp _collectionSubdirLeaf = RegExp(
  r'^(?:movies?|films?|theatrical|劇場版|剧场版|tv(?:版)?|ovas?)$',
  caseSensitive: false,
);

/// 独立大型剧场版最低体积门槛（300 MB；测试夹具无体积时放行）。
const int _minAnchoredMovieSplitBytes = 300 * 1024 * 1024;

final RegExp _anchoredMovieFilePattern = RegExp(
  r'(?<![a-z0-9])(?:the[ ._-]+)?movie(?![a-z0-9])|剧场版|劇場版',
  caseSensitive: false,
);

final RegExp _singleIndexedMovieFolderPattern = RegExp(
  r'第\s*[0-9一二三四五六七八九十]{1,2}\s*[章部]|'
  r'(?<![a-z0-9])(?:movie|part|chapter)\s*(?:1st|2nd|3rd|\d+)(?![a-z0-9])',
  caseSensitive: false,
);

final RegExp _anchoredMovieExcludedPattern = RegExp(
  r'memorial[ ._-]*movie|weekly[ ._-]*movies?|digest[ ._-]*movie|'
  r'[\[【]\s*\d{1,3}\s*[-–—~～]\s*\d{1,3}\s*[\(（]\s*movie\s*[\)）]\s*[\]】]',
  caseSensitive: false,
);

final RegExp _anchoredChapterFeaturePattern = RegExp(
  r'第\s*[0-9一二三四五六七八九十]{1,2}\s*[章部]|'
  r'(?:^|[^a-z0-9])(?:zenpen|kouhen|chuhen)(?=[^a-z0-9]|$)|'
  r'前[篇編]|后[篇編]|後[篇編]|中[篇編]|'
  r'[#＃]\s*0*[1-9]\s*[～~〜][^～~〜]+?[の之]?[巻卷]|'
  r'(?<![a-z0-9])movie[ ._-]*0*[1-9](?![0-9a-z])',
  caseSensitive: false,
);

/// 大小写敏感的罗马数字分部电影标记（如 `I: Promise`、`II: Song I am.`、`III. spring song`）。
final RegExp _anchoredRomanPartFeaturePattern = RegExp(
  r'(?<=\s)(?:I{1,3}|IV|Ⅰ|Ⅱ|Ⅲ|Ⅳ)(?=\s*[:：\-–—]\s*\S|\.\s+[A-Za-z\u4e00-\u9fff\u3040-\u30ff])',
);

final RegExp _anchoredMovieSubdirPattern = RegExp(
  r'(?:^|/)(?:movies?|劇場版|剧场版|films?|theatrical)(?:/|$)',
  caseSensitive: false,
);

const int _maxAnchoredStandaloneMovieCount = 8;

final RegExp _independentInstallmentMarker = RegExp(
  r'(?:^|[\s._\-\[(])(?:ova|oad|movie|film|theatrical|剧场版|劇場版|外伝|外传|spin[._-]?off)(?=$|[\s._\-\])])',
  caseSensitive: false,
);

final RegExp _ovaOrSpMarker = RegExp(
  r'(?:^|[\s._\-\[(])(?:ova|oad|sp|special|ex\d{0,2})(?=$|[\s._\-\])])',
  caseSensitive: false,
);

final RegExp _bangumiMarker = RegExp(
  r'[\[{]\s*(?:bgm|bangumi)(?:id)?\s*[-=:_]\s*(\d+)\s*[\]}]',
  caseSensitive: false,
);

final RegExp _yearParentPattern = RegExp(
  r'^(?:19|20)\d{2}(?:[-._]\d{1,2})?(?:年.*)?$',
);

/// 媒体库「标题 (年份)」命名约定：年份括号位于末尾，其后只允许跟随 `{...}`/`[...]` 标识块。
final RegExp _trailingYearAnchor = RegExp(
  r'\S.*?[(（]\s*(?:19|20)\d{2}\s*[)）](?:\s*[\[{【][^\]}】]*[\]}】])*\s*$',
);

/// 判定目录段是否为锚定作品根目录：0 表示非锚定，1 表示「标题 (年份)」约定，2 表示携带显式刮削 ID。
///
/// 锚定根目录代表用户已按媒体库规范整理好的单部作品，其下所有子目录（压制组目录、分卷、
/// 字幕语言版本、特典目录等）一律向上归并，不再按子目录碎片化成独立作品。
int _workRootAnchorKind(String segment) {
  final trimmed = segment.trim();
  if (trimmed.isEmpty) return 0;
  if (PersonalFilenameParser.tmdbIds(trimmed).isNotEmpty ||
      _bangumiMarker.hasMatch(trimmed)) {
    return 2;
  }
  if ((!trimmed.contains('(') && !trimmed.contains('（')) ||
      !_trailingYearAnchor.hasMatch(trimmed)) {
    return 0;
  }
  if (_categoryFolderPattern.hasMatch(trimmed) ||
      SupplementaryFolderRules.isSupplementarySegment(trimmed)) {
    return 0;
  }
  return 1;
}

/// 判断「标题 (年份)」目录名中的 ` & ` 是否真的并列了多部作品：每一段都必须拥有其他段没有的独有词，
/// 且这些独有词分别命中互不重叠的视频文件（如 `FLCL Alternative & FLCL Progressive`）。
/// `TIGER & BUNNY`、`NULL & PETA` 这类片名本身含 `&` 的目录，各段词在全部文件中同时出现，不满足条件。
bool _isDisjointAmpersandCollection(
  String folderLeaf,
  List<ScannedFileInput> videos,
) {
  final segments = DirectoryAnalyzer.cleanTitle(folderLeaf)
      .split(_reHot1)
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList(growable: false);
  if (segments.length < 2) return false;
  Set<String> tokens(String value) =>
      value.toLowerCase().split(_reHot2).where((t) => t.length >= 2).toSet();
  final segmentTokens = segments.map(tokens).toList(growable: false);
  final fileTokens = [for (final v in videos) tokens(v.fileName)];
  final hitSets = <Set<int>>[];
  for (var i = 0; i < segmentTokens.length; i++) {
    final others = <String>{
      for (var j = 0; j < segmentTokens.length; j++)
        if (j != i) ...segmentTokens[j],
    };
    final distinct = segmentTokens[i].difference(others);
    if (distinct.isEmpty) return false;
    final hits = <int>{
      for (var f = 0; f < fileTokens.length; f++)
        if (fileTokens[f].intersection(distinct).isNotEmpty) f,
    };
    if (hits.isEmpty) return false;
    if (hitSets.any((prev) => prev.intersection(hits).isNotEmpty)) {
      return false;
    }
    hitSets.add(hits);
  }
  return true;
}

/// 判断锚定目录内是否包含需要拆分出去的独立剧场版：
/// 1. 常规 TV 目录内捆绑了明确带剧场版标记的大型正片（如 `Dance with Devils Fortuna The Movie`）；
/// 2. 剧场版合放目录内包含 2~4 部不同章节/卷号的大型剧场版（如 `薄樱鬼 第一章/第二章`、`刀剑乱舞 雪/月/花之卷`）。
bool _hasAnchoredStandaloneMovieToSplit(
  List<ScannedFileInput> videoFiles, {
  required String folderPath,
  required String folderLeafName,
}) {
  // 目录名已明确声明为单部带序号的剧场版（如 `第一章 觉醒之刻`、`The MOVIE 1st`），不再按多章拆开。
  if (_singleIndexedMovieFolderPattern.hasMatch(folderLeafName)) {
    return false;
  }
  final normFolder = folderPath.replaceAll('\\', '/').replaceAll(_reHot3, '');
  var bigMovieCount = 0;
  var bigChapterCount = 0;
  final chapterMarkers = <String>{};
  var regularEpisodeCount = 0;

  for (final v in videoFiles) {
    final rel = v.relativePath.replaceAll('\\', '/');
    final sub = normFolder.isNotEmpty && rel.startsWith('$normFolder/')
        ? rel.substring(normFolder.length + 1)
        : v.fileName;
    final slash = sub.lastIndexOf('/');
    final subDir = slash > 0 ? sub.substring(0, slash) : '';
    if (subDir.isNotEmpty &&
        SupplementaryFolderRules.isSupplementarySegment(
          subDir.split('/').first,
        )) {
      continue;
    }
    final name = v.fileName;
    if (CloudMediaFileClassifier.isPreview(name) ||
        CloudMediaFileClassifier.isNoCredit(name) ||
        CloudMediaFileClassifier.contextualJapanBdExtra.hasMatch(name) ||
        _reHot4.hasMatch(name)) {
      continue;
    }
    final isLarge =
        v.fileSize <= 0 || v.fileSize >= _minAnchoredMovieSplitBytes;
    final inMovieSubdir =
        subDir.isNotEmpty && _anchoredMovieSubdirPattern.hasMatch(subDir);
    final isMovieFile =
        isLarge &&
        (inMovieSubdir || _anchoredMovieFilePattern.hasMatch(name)) &&
        !_anchoredMovieExcludedPattern.hasMatch(name);
    final chapterMatch = isLarge
        ? (_anchoredChapterFeaturePattern.firstMatch(name) ??
              _anchoredRomanPartFeaturePattern.firstMatch(name))
        : null;
    if (isMovieFile) {
      bigMovieCount++;
    } else if (chapterMatch == null &&
        isLarge &&
        CloudMediaFileClassifier.episodeNumberFromName(name) != null) {
      regularEpisodeCount++;
    }
    if (chapterMatch != null) {
      bigChapterCount++;
      chapterMarkers.add(DirectoryAnalyzer.normalize(chapterMatch.group(0)!));
    }
  }

  // 场景 A：常规多集 TV 目录内捆绑了明确独立剧场版（含 `Movies/` 子目录多部曲，如《高达 G 之复国运动》5 部剧场版）。
  if (regularEpisodeCount >= 4 &&
      bigMovieCount >= 1 &&
      bigMovieCount <= _maxAnchoredStandaloneMovieCount) {
    return true;
  }
  // 场景 B：2~4 部不同章节/卷号的大型剧场版合放于同一目录（避免把 7 集 OVA 长篇如高达 UC 拆散）。
  if (regularEpisodeCount == 0 &&
      bigChapterCount >= 2 &&
      bigChapterCount <= 4 &&
      chapterMarkers.length >= 2) {
    return true;
  }
  return false;
}

/// 返回路径中最深一层锚定作品根目录的段下标，不存在时返回 -1。
int _deepestAnchorIndex(List<String> dirSegments) {
  for (var i = dirSegments.length - 1; i >= 0; i--) {
    if (_workRootAnchorKind(dirSegments[i]) > 0) return i;
  }
  return -1;
}

/// 检测「锚定父目录下直接包含多个自带独立附属目录（SPs/CDs/Scans/Extras）的子作品包」
/// （例如 `物语系列 第二季 (2013) {tmdb-46195}/倾物语`、`囮物语`、`恋物语` 等），
/// 以便将每个子篇章拆为独立作品并各自保留专属封面与附属资源。
Set<String> _detectAnchoredPackageCollectionRoots(
  List<ScannedFileInput> files,
) {
  final childMainVideos = <String, Map<String, int>>{};
  final childSuppDirs = <String, Set<String>>{};
  final groupPrefix = _reHot5;
  final discOrLang = _reHot6;

  final seenNonVideoDirs = <String>{};
  for (final file in files) {
    final rawPath = file.relativePath;
    final normPath = rawPath.contains('\\')
        ? rawPath.replaceAll('\\', '/')
        : rawPath;
    final lastSlash = normPath.lastIndexOf('/');
    if (lastSlash <= 0) continue;
    final dirPath = normPath.substring(0, lastSlash);
    if (file.assetKind != AssetKind.video && !seenNonVideoDirs.add(dirPath)) {
      continue;
    }
    final dirSegs = dirPath
        .split('/')
        .where((s) => s.isNotEmpty)
        .toList(growable: false);
    if (dirSegs.length < 2) continue;
    final anchor = _deepestAnchorIndex(dirSegs);
    if (anchor < 0 || anchor + 1 >= dirSegs.length) continue;

    final anchorPath = dirSegs.sublist(0, anchor + 1).join('/');
    final childSeg = dirSegs[anchor + 1].trim();
    if (childSeg.isEmpty ||
        groupPrefix.hasMatch(childSeg) ||
        discOrLang.hasMatch(childSeg) ||
        SupplementaryFolderRules.isSupplementarySegment(childSeg) ||
        SupplementaryFolderRules.isSeasonOrVolumeSegment(childSeg)) {
      continue;
    }

    if (anchor + 2 < dirSegs.length &&
        SupplementaryFolderRules.isSupplementarySegment(dirSegs[anchor + 2])) {
      (childSuppDirs[anchorPath] ??= <String>{}).add(childSeg);
    } else if (file.assetKind == AssetKind.video) {
      final byChild = childMainVideos[anchorPath] ??= <String, int>{};
      byChild.update(childSeg, (n) => n + 1, ifAbsent: () => 1);
    }
  }

  final roots = <String>{};
  for (final entry in childMainVideos.entries) {
    final anchorPath = entry.key;
    final suppChildren = childSuppDirs[anchorPath] ?? const <String>{};
    final qualified = entry.value.entries
        .where((e) => e.value >= 2 && suppChildren.contains(e.key))
        .length;
    if (qualified >= 2) {
      roots.add(anchorPath);
    }
  }
  return roots;
}

/// 使用无损目录分析器与多作品拆分器对扫描文件执行抗碎裂归拢与合集拆分。
List<GroupedWorkFolder> groupAndSplitFiles({
  required String sourceId,
  required List<ScannedFileInput> files,
  Map<String, String> nfoByFolder = const {},
  Map<String, String> localCoverByFolder = const {},
}) {
  final multiInstallmentRoots = _detectMultiInstallmentRoots(
    files,
    nfoByFolder: nfoByFolder,
  );
  final anchoredPackageRoots = _detectAnchoredPackageCollectionRoots(files);
  final rawBuckets = <String, List<ScannedFileInput>>{};
  final resolvedByParentDir = <String, String>{};
  for (final file in files) {
    final rawPath = file.relativePath;
    final normPath = rawPath.contains('\\')
        ? rawPath.replaceAll('\\', '/')
        : rawPath;
    final lastSlash = normPath.lastIndexOf('/');
    final parentDir = lastSlash > 0 ? normPath.substring(0, lastSlash) : '';
    final workFolder = resolvedByParentDir.putIfAbsent(
      parentDir,
      () => _resolvePhysicalWorkFolder(
        normPath,
        multiInstallmentRoots: multiInstallmentRoots,
        anchoredPackageRoots: anchoredPackageRoots,
      ),
    );
    rawBuckets.putIfAbsent(workFolder, () => []).add(file);
  }

  final foldedBuckets = _foldNestedBuckets(rawBuckets);
  final foldedExtras = CollectionAssetRouter.foldParentCollectionExtras(
    foldedBuckets,
  );
  final result = <GroupedWorkFolder>[];

  for (final entry in foldedBuckets.entries) {
    final folderPath = entry.key;
    final allFiles = entry.value;
    final videoFiles = allFiles
        .where((e) => e.assetKind == AssetKind.video)
        .toList();
    if (videoFiles.isEmpty) continue;

    final nfoHint = DirectoryGrouper.parseNfoText(
      nfoByFolder[folderPath] ?? '',
    );

    final relativeVideos = [
      for (final v in videoFiles)
        (
          path: _stripFolderPrefix(v.relativePath, folderPath),
          size: v.fileSize > 0 ? v.fileSize : null,
        ),
    ];

    final folderLeafName = _lastSegment(folderPath);
    var analyzePath = folderPath;
    String? inheritedParentClean;
    String? parentDirOfFolder;
    if (folderPath.contains('/')) {
      final slash = folderPath.lastIndexOf('/');
      final parentDir = folderPath.substring(0, slash);
      final parentLeaf = _lastSegment(parentDir);
      if (!_categoryFolderPattern.hasMatch(parentLeaf) &&
          !_yearParentPattern.hasMatch(parentLeaf.trim())) {
        final parentClean = _extractParentSeriesTitle(parentDir);
        if (parentClean.isNotEmpty) {
          inheritedParentClean = parentClean;
          parentDirOfFolder = parentDir;
          if (_genericSeasonName.hasMatch(folderLeafName)) {
            analyzePath = '$parentDir/$parentClean $folderLeafName';
          }
        }
      }
    }

    final anchorKind = _workRootAnchorKind(folderLeafName);
    var inventory = DirectoryAnalyzer.analyze(
      analyzePath,
      relativeVideos,
      anchoredRoot: anchorKind > 0,
    );
    if (nfoHint.tmdbId != null || nfoHint.mediaType != null) {
      inventory = inventory.withExplicitIds(
        tmdbId: inventory.tmdbId ?? nfoHint.tmdbId,
        tmdbType: inventory.tmdbType ?? nfoHint.mediaType?.name,
      );
    }

    // 非锚定目录默认允许拆簇；锚定目录在满足显式 `A & B` 独立双作并列、
    // 多部章节剧场版合放或 TV 内捆绑独立大型剧场版时亦允许拆分为独立条目。
    final anchoredMovieSplit =
        anchorKind > 0 &&
        _hasAnchoredStandaloneMovieToSplit(
          videoFiles,
          folderPath: folderPath,
          folderLeafName: folderLeafName,
        );
    final splitAllowed =
        anchorKind == 0 ||
        _isDisjointAmpersandCollection(folderLeafName, videoFiles) ||
        anchoredMovieSplit;
    if (splitAllowed && videoFiles.length >= 2) {
      final rawAssets = [
        for (final v in videoFiles)
          (
            relativePath: v.relativePath,
            name: v.fileName,
            size: v.fileSize,
            assetId: v.relativePath,
          ),
      ];
      final preview = MultiWorkSplitter.splitEntries(folderPath, rawAssets);
      final shouldSplit =
          (inventory.tmdbId == null && inventory.bangumiId == null)
          ? MultiWorkSplitter.shouldAutoSplitUnboundFolder(
              folderPath,
              inventory,
              preview,
            )
          : (inventory.tmdbId != null &&
                _shouldSplitExplicitTmdb(
                  inventory,
                  preview,
                  anchoredMovieSplit: anchoredMovieSplit,
                ));

      if (shouldSplit && preview.length >= 2) {
        final fileByRelPath = <String, ScannedFileInput>{
          for (final v in videoFiles) v.relativePath: v,
        };
        final nonVideoFiles = allFiles
            .where((f) => f.assetKind != AssetKind.video)
            .toList();
        final parentSeriesTitle = _extractParentSeriesTitle(folderPath);
        final parentTmdbId = inventory.tmdbId;
        final parentTmdbType = _parseTmdbMediaType(inventory.tmdbType);
        final explicitSegments = MultiWorkSplitter.explicitCollectionSegments(
          folderPath,
        );
        final splitTargets = <CollectionTargetDescriptor>[];
        final splitParentTokens = folderPath
            .toLowerCase()
            .split(_reHot7)
            .where((t) => t.length >= 3)
            .toSet();
        for (final c in preview) {
          final isMovieCluster =
              c.inventory.tmdbType == 'movie' ||
              c.inventory.movieMarker ||
              (c.inventory.shape == WorkShape.feature &&
                  !_ovaOrSpMarker.hasMatch(c.inventory.title) &&
                  c.inventory.season != 0);
          final leafTokens = <String>{
            for (final src in <String>[
              c.inventory.title,
              ...c.inventory.titleHints,
            ])
              for (final tok in src.toLowerCase().split(_reHot7))
                if (tok.length >= 3 && !splitParentTokens.contains(tok)) tok,
          };
          int? clusterPartIndex = CollectionAssetRouter.extractPartIndex(
            c.inventory.title,
          );
          if (clusterPartIndex == null) {
            for (final hint in c.inventory.titleHints) {
              clusterPartIndex = CollectionAssetRouter.extractPartIndex(hint);
              if (clusterPartIndex != null) break;
            }
          }
          clusterPartIndex ??= CollectionAssetRouter.extractPartIndex(c.slug);
          if (clusterPartIndex == null) {
            for (final a in c.assignments) {
              if (a.category != 'main') continue;
              clusterPartIndex = CollectionAssetRouter.extractPartIndex(
                a.relativePath,
              );
              if (clusterPartIndex != null) break;
            }
          }
          splitTargets.add(
            CollectionTargetDescriptor(
              key: c.slug,
              seasonNumber: c.inventory.season,
              isMovie: isMovieCluster,
              titleTokens: leafTokens,
              partIndex: clusterPartIndex,
            ),
          );
        }
        final routedNonVideo = CollectionAssetRouter.routeSplitClusterExtras(
          collectionRoot: folderPath,
          targets: splitTargets,
          supplementaryFiles: nonVideoFiles,
        );

        for (var ci = 0; ci < preview.length; ci++) {
          final cluster = preview[ci];
          final clusterFolderId = _buildSplitVirtualFolder(
            folderPath,
            cluster.slug,
          );
          final clusterWorkId = '$sourceId::$clusterFolderId';
          final clusterFiles = <ScannedFileInput>[];
          final slotMap = <String, EpisodeSlotAssignment>{};
          final clusterScopeMap = <String, SupplementaryAssetScope>{};

          final extraNonVideo =
              routedNonVideo.filesByClusterKey[cluster.slug] ?? const [];
          final clusterCdPaths = extraNonVideo
              .where((f) => f.assetKind == AssetKind.cdAlbum)
              .map((f) => f.relativePath)
              .toList(growable: false);
          final clusterVideoEntries = cluster.assignments
              .map((a) => fileByRelPath[a.relativePath])
              .whereType<ScannedFileInput>()
              .map((f) => (fileName: f.fileName, relativePath: f.relativePath))
              .toList(growable: false);

          final clusterParsedCache = <String, ParsedBdripRelease>{};
          for (final item in cluster.assignments) {
            final raw = fileByRelPath[item.relativePath];
            if (raw == null) continue;
            clusterFiles.add(raw);
            final isExtra = item.category == 'extra';
            if (isExtra) {
              final legacyTypeStr =
                  CloudMediaAssetPresentation.extraTypeFromName(
                    raw.fileName,
                    relativePath: raw.relativePath,
                  );
              final mappedLegacyKind = _mapExtraKindFromName(legacyTypeStr);
              final explicitSpecialNum =
                  item.episode ??
                  CloudMediaAssetPresentation.explicitSpecialNumberFromName(
                    raw.fileName,
                  );
              final parsed = BdripParser.parseFileName(
                raw.fileName,
                relativePath: raw.relativePath,
                folderTitle: cluster.inventory.title,
                folderSeasonHint: cluster.inventory.season,
                resolveEpisode:
                    explicitSpecialNum == null || raw.fileName.contains('.5'),
                resolveExtraClassification:
                    (item.extraType == null && mappedLegacyKind == null) ||
                    explicitSpecialNum == null,
                resolveTitleAndSeason: false,
              );
              clusterParsedCache[raw.relativePath] = parsed;
              slotMap[raw.relativePath] = resolveExtraSlotAssignment(
                fileName: raw.fileName,
                relativePath: raw.relativePath,
                parsed: parsed,
                folderCleanTitle: cluster.inventory.title,
                overrideExtraType: item.extraType,
                overrideEpisode: item.episode,
                workVideoEntries: clusterVideoEntries,
                cdAlbumPaths: clusterCdPaths,
                preLegacyTypeStr: legacyTypeStr,
                preExplicitSpecialNum: explicitSpecialNum,
                hasPreExplicitSpecialNum: true,
              );
            } else {
              final parsed = BdripParser.parseFileName(
                raw.fileName,
                relativePath: raw.relativePath,
                folderTitle: cluster.inventory.title,
                folderSeasonHint: cluster.inventory.season,
                resolveEpisode: raw.fileName.contains('.5'),
                resolveExtraClassification: false,
                resolveTitleAndSeason: false,
              );
              clusterParsedCache[raw.relativePath] = parsed;
              slotMap[raw.relativePath] = EpisodeSlotAssignment(
                category: EpisodeCategory.main,
                seasonNumber: item.season > 0
                    ? item.season
                    : (cluster.inventory.season ?? 1),
                episodeNumber: item.episode,
                episodeEnd: item.episode == null ? null : item.episodeEnd,
                extraType: null,
                fractionalLabel: parsed.fractionalEpisode,
              );
            }
          }

          if (extraNonVideo.isNotEmpty) {
            clusterFiles.addAll(extraNonVideo);
            for (final nv in extraNonVideo) {
              final scope = routedNonVideo.assetScopeByPath[nv.relativePath];
              if (scope != null) {
                clusterScopeMap[nv.relativePath] = scope;
              }
            }
          }
          if (clusterFiles
              .where((f) => f.assetKind == AssetKind.video)
              .isEmpty) {
            continue;
          }

          final clusterExtraHints = _buildClusterParentHints(
            cluster: cluster,
            fileByRelPath: fileByRelPath,
            parentSeriesTitle: parentSeriesTitle,
            explicitSegments: explicitSegments,
          );

          final variants = _buildVariants(
            sourceId: sourceId,
            workId: clusterWorkId,
            files: clusterFiles,
            folderTitle: cluster.inventory.title,
            seasonHint: cluster.inventory.season,
            assetScopesByPath: clusterScopeMap,
            parsedCache: clusterParsedCache,
          );
          final sortedEps = cluster.inventory.episodes.toList()..sort();
          final clusterTitle = cluster.inventory.title.isNotEmpty
              ? cluster.inventory.title
              : _lastSegment(folderPath);
          final isMovieCluster =
              cluster.inventory.tmdbType == 'movie' ||
              cluster.inventory.movieMarker ||
              (cluster.inventory.shape == WorkShape.feature &&
                  !_ovaOrSpMarker.hasMatch(clusterTitle) &&
                  cluster.inventory.season != 0);
          final passParentTmdb =
              cluster.inventory.tmdbId == null && parentTmdbId != null;
          final clusterLocalCover = _resolveDedicatedClusterLocalCover(
            parentFolderPath: folderPath,
            clusterFiles: clusterFiles,
            slotMap: slotMap,
            localCoverByFolder: localCoverByFolder,
          );

          final groupedCluster = GroupedWorkFolder(
            folderRelativePath: clusterFolderId,
            physicalRootFolder:
                foldedExtras.physicalRootByBucket[folderPath] ?? folderPath,
            folderName: clusterTitle,
            cleanTitle: clusterTitle,
            explicitTmdbId: cluster.inventory.tmdbId,
            explicitMediaType: _parseTmdbMediaType(cluster.inventory.tmdbType),
            year: cluster.inventory.year,
            seasonHint: cluster.inventory.season,
            mainEpisodeNumbers: List.unmodifiable(sortedEps),
            isMovieHint: isMovieCluster,
            variants: variants,
            inventory: cluster.inventory,
            slotAssignmentsByPath: Map.unmodifiable(slotMap),
            isSplitCluster: true,
            titleHints: List.unmodifiable(
              _dedupePreserveOrder([
                ...cluster.inventory.titleHints,
                ...clusterExtraHints.extraTitleHints,
              ]),
            ),
            fileHints: List.unmodifiable(cluster.inventory.fileHints),
            extraSearchQueries: List.unmodifiable(
              clusterExtraHints.extraQueries,
            ),
            parentTmdbId: passParentTmdb ? parentTmdbId : null,
            parentTmdbType: passParentTmdb ? parentTmdbType : null,
            allowParentTmdbCandidate: clusterExtraHints.isSpecial,
            assetScopesByPath: Map.unmodifiable(clusterScopeMap),
            localPosterPath: clusterLocalCover,
          );
          result.add(
            groupedCluster.withMatchDifficulty(
              MatchDifficultyClassifier.classify(groupedCluster),
            ),
          );
        }
        continue;
      }
    }

    // 单一作品目录（含标准多集、单 OVA/电影、TV + 附属特典/CD/Scan）
    final folderName = _lastSegment(folderPath);
    final cleanTitle = inventory.title.isNotEmpty
        ? inventory.title
        : (inventory.titleHints.isNotEmpty
              ? inventory.titleHints.first
              : (inventory.fileHints.isNotEmpty
                    ? inventory.fileHints.first
                    : folderName));
    final isCollectionChild =
        parentDirOfFolder != null &&
        (multiInstallmentRoots.contains(parentDirOfFolder) ||
            foldedExtras.physicalRootByBucket.containsKey(folderPath));
    final augmentedTitleHints = <String>[
      ...inventory.titleHints,
      if (isCollectionChild &&
          inheritedParentClean != null &&
          !cleanTitle.toLowerCase().contains(
            inheritedParentClean.toLowerCase(),
          ))
        '$inheritedParentClean $cleanTitle',
    ];
    final uniqueTitleHints = <String>{
      for (final h in augmentedTitleHints)
        if (h.trim().isNotEmpty) h.trim(),
    }.toList(growable: false);
    if (uniqueTitleHints.length != inventory.titleHints.length) {
      inventory = DirectoryInventory.synthetic(
        folder: inventory.folder,
        title: inventory.title,
        year: inventory.year,
        fileYear: inventory.fileYear,
        tmdbId: inventory.tmdbId,
        tmdbType: inventory.tmdbType,
        bangumiId: inventory.bangumiId,
        season: inventory.season,
        folderMovieMarker: inventory.folderMovieMarker,
        fileMovieMarker: inventory.fileMovieMarker,
        main: inventory.main,
        extras: inventory.extras,
        shape: inventory.shape,
        titleHints: uniqueTitleHints,
        fileHints: inventory.fileHints,
      );
    }
    final singleParsedCache = <String, ParsedBdripRelease>{};
    final slotMap = _buildSlotAssignmentsForSingleFolder(
      folderPath: folderPath,
      videoFiles: videoFiles,
      inventory: inventory,
      cleanTitle: cleanTitle,
      parsedCache: singleParsedCache,
    );
    final workId = '$sourceId::$folderPath';
    final variants = _buildVariants(
      sourceId: sourceId,
      workId: workId,
      files: allFiles,
      folderTitle: cleanTitle,
      seasonHint: inventory.season,
      assetScopesByPath: foldedExtras.assetScopeByPath,
      parsedCache: singleParsedCache,
    );
    final sortedEps = inventory.episodes.toList()..sort();
    final explicitType =
        nfoHint.mediaType ?? _parseTmdbMediaType(inventory.tmdbType);
    final isMovieHint =
        explicitType == TmdbMediaType.movie ||
        inventory.movieMarker ||
        _movieMarkerPattern.hasMatch(folderName) ||
        (inventory.shape == WorkShape.feature &&
            inventory.season != 0 &&
            !_ovaOrSpMarker.hasMatch(cleanTitle));

    final groupedSingle = GroupedWorkFolder(
      folderRelativePath: folderPath,
      physicalRootFolder:
          foldedExtras.physicalRootByBucket[folderPath] ?? folderPath,
      folderName: folderName,
      cleanTitle: cleanTitle,
      explicitTmdbId: nfoHint.tmdbId ?? inventory.tmdbId,
      explicitMediaType: explicitType,
      year: inventory.year,
      seasonHint: inventory.season,
      mainEpisodeNumbers: List.unmodifiable(sortedEps),
      isMovieHint: isMovieHint,
      variants: variants,
      inventory: inventory,
      slotAssignmentsByPath: Map.unmodifiable(slotMap),
      isSplitCluster: false,
      titleHints: List.unmodifiable(uniqueTitleHints),
      fileHints: List.unmodifiable(inventory.fileHints),
      assetScopesByPath: Map.unmodifiable({
        for (final f in allFiles)
          if (foldedExtras.assetScopeByPath.containsKey(f.relativePath))
            f.relativePath: foldedExtras.assetScopeByPath[f.relativePath]!,
      }),
      localPosterPath: localCoverByFolder[folderPath],
    );
    result.add(
      groupedSingle.withMatchDifficulty(
        MatchDifficultyClassifier.classify(groupedSingle),
      ),
    );
  }

  return result;
}

/// 拆簇子作品严禁继承父合集根目录封面，仅在全部正片视频归属同一独立子目录且该子目录自有封面时才采纳。
String? _resolveDedicatedClusterLocalCover({
  required String parentFolderPath,
  required List<ScannedFileInput> clusterFiles,
  required Map<String, EpisodeSlotAssignment> slotMap,
  required Map<String, String> localCoverByFolder,
}) {
  if (localCoverByFolder.isEmpty) return null;
  final normParent = parentFolderPath
      .trim()
      .replaceAll('\\', '/')
      .replaceAll(_reHot3, '');
  final mainDirs = <String>{};
  for (final f in clusterFiles) {
    if (f.assetKind != AssetKind.video) continue;
    final slot = slotMap[f.relativePath];
    if (slot != null && slot.category != EpisodeCategory.main) continue;
    final normRel = f.relativePath
        .trim()
        .replaceAll('\\', '/')
        .replaceAll(_reHot3, '');
    final slash = normRel.lastIndexOf('/');
    final dir = slash > 0 ? normRel.substring(0, slash) : '';
    mainDirs.add(dir);
  }
  if (mainDirs.length != 1) return null;
  final onlyDir = mainDirs.first;
  if (onlyDir.isEmpty || onlyDir == normParent) return null;
  return localCoverByFolder[onlyDir];
}

Map<String, EpisodeSlotAssignment> _buildSlotAssignmentsForSingleFolder({
  required String folderPath,
  required List<ScannedFileInput> videoFiles,
  required DirectoryInventory inventory,
  required String cleanTitle,
  Map<String, ParsedBdripRelease>? parsedCache,
}) {
  final slotMap = <String, EpisodeSlotAssignment>{};
  final relToRaw = <String, ScannedFileInput>{
    for (final v in videoFiles)
      _stripFolderPrefix(v.relativePath, folderPath): v,
  };
  // 多季合辑目录（`S1+S2`、`X & X 第2期`）的路径季号只描述其中一季，不能套用到目录内全部正片。
  final multiSeasonFolder = DirectoryAnalyzer.isMultiSeasonTitle(
    inventory.title,
  );

  for (final item in inventory.main) {
    for (final subRel in item.files) {
      final raw = relToRaw[subRel];
      if (raw == null) continue;
      final needsSeason =
          (item.season == null || item.season! <= 0) &&
          (inventory.season == null || inventory.season! <= 0) &&
          !multiSeasonFolder;
      final needsEpisode =
          item.episode == null || needsSeason || raw.fileName.contains('.5');
      final parsed = BdripParser.parseFileName(
        raw.fileName,
        relativePath: raw.relativePath,
        folderTitle: cleanTitle,
        folderSeasonHint: inventory.season,
        resolveEpisode: needsEpisode,
        resolveExtraClassification: item.episode == null || needsSeason,
        resolveTitleAndSeason: needsSeason,
      );
      if (parsedCache != null) parsedCache[raw.relativePath] = parsed;
      final epNum = item.episode ?? parsed.episode;
      final seasonNum = (item.season != null && item.season! > 0)
          ? item.season!
          : ((inventory.season != null && inventory.season! > 0)
                ? inventory.season!
                : (!multiSeasonFolder && parsed.season > 0
                      ? parsed.season
                      : 1));
      slotMap[raw.relativePath] = EpisodeSlotAssignment(
        category: EpisodeCategory.main,
        seasonNumber: seasonNum,
        episodeNumber: epNum,
        episodeEnd: item.episode == null ? null : item.episodeEnd,
        extraType: null,
        fractionalLabel: parsed.fractionalEpisode,
      );
    }
  }

  final workVideoEntries = videoFiles
      .map((v) => (fileName: v.fileName, relativePath: v.relativePath))
      .toList(growable: false);
  for (final subRel in inventory.extras) {
    final raw = relToRaw[subRel];
    if (raw == null) continue;
    final legacyTypeStr = CloudMediaAssetPresentation.extraTypeFromName(
      raw.fileName,
      relativePath: raw.relativePath,
    );
    final mappedLegacyKind = _mapExtraKindFromName(legacyTypeStr);
    final explicitSpecialNum =
        CloudMediaAssetPresentation.explicitSpecialNumberFromName(raw.fileName);
    final parsed = BdripParser.parseFileName(
      raw.fileName,
      relativePath: raw.relativePath,
      folderTitle: cleanTitle,
      folderSeasonHint: inventory.season,
      resolveEpisode: explicitSpecialNum == null || raw.fileName.contains('.5'),
      resolveExtraClassification:
          mappedLegacyKind == null || explicitSpecialNum == null,
      resolveTitleAndSeason: false,
    );
    if (parsedCache != null) parsedCache[raw.relativePath] = parsed;
    slotMap[raw.relativePath] = resolveExtraSlotAssignment(
      fileName: raw.fileName,
      relativePath: raw.relativePath,
      parsed: parsed,
      folderCleanTitle: cleanTitle,
      workVideoEntries: workVideoEntries,
      preLegacyTypeStr: legacyTypeStr,
      preExplicitSpecialNum: explicitSpecialNum,
      hasPreExplicitSpecialNum: true,
    );
  }

  return slotMap;
}

/// 为单个特典视频提取精简短标题、精准类型与防误合并键。
EpisodeSlotAssignment resolveExtraSlotAssignment({
  required String fileName,
  required String relativePath,
  required ParsedBdripRelease parsed,
  String? folderCleanTitle,
  String? overrideExtraType,
  int? overrideEpisode,
  List<({String fileName, String relativePath})> workVideoEntries =
      const <({String fileName, String relativePath})>[],
  List<String> cdAlbumPaths = const <String>[],
  String? preLegacyTypeStr,
  int? preExplicitSpecialNum,
  bool hasPreExplicitSpecialNum = false,
}) {
  final legacyTypeStr =
      preLegacyTypeStr ??
      CloudMediaAssetPresentation.extraTypeFromName(
        fileName,
        relativePath: relativePath,
      );
  final fallbackKind = _mapExtraKindFromName(legacyTypeStr) ?? parsed.extraType;
  final extraKind = overrideExtraType != null
      ? (_mapExtraKindFromName(overrideExtraType) ?? fallbackKind)
      : SupplementarySubclassifier.classifyExtraVideo(
          fileName: fileName,
          relativePath: relativePath,
          fallbackExtraType: fallbackKind,
        );
  final typeStr = overrideExtraType ?? extraKind?.name.toUpperCase() ?? 'SP';
  final explicitNum =
      overrideEpisode ??
      (hasPreExplicitSpecialNum
          ? preExplicitSpecialNum
          : CloudMediaAssetPresentation.explicitSpecialNumberFromName(
              fileName,
            )) ??
      parsed.episode;
  final extractedTitle = CloudMediaAssetPresentation.extraTitleFromName(
    fileName,
    relativePath: relativePath,
  );
  final cdBundledTitle =
      SupplementarySubclassifier.formatCdBundledExtraTitleFromRaw(
        fileName: fileName,
        relativePath: relativePath,
        workVideoEntries: workVideoEntries,
        cdAlbumPaths: cdAlbumPaths,
      );
  final shortTitle =
      cdBundledTitle ??
      _resolveConciseExtraTitle(
        fileName: fileName,
        relativePath: relativePath,
        extractedTitle: extractedTitle,
        typeStr: typeStr,
        explicitNum: explicitNum,
        folderCleanTitle: folderCleanTitle,
      );
  final unnumberedStemKey = cdBundledTitle != null
      ? _buildExtraUnnumberedStemKey(
          fileName: fileName,
          relativePath: relativePath,
          parsed: parsed,
          shortTitle: shortTitle,
        )
      : SupplementarySubclassifier.buildExtraCanonicalMergeKey(
          fileName: fileName,
          relativePath: relativePath,
          extraType: extraKind,
          titleHint: shortTitle,
          workTitle: folderCleanTitle,
        );
  return EpisodeSlotAssignment(
    category: EpisodeCategory.extra,
    seasonNumber: 0,
    episodeNumber: explicitNum,
    extraType: extraKind,
    fractionalLabel: parsed.fractionalEpisode,
    extraTitleHint: shortTitle,
    unnumberedStemKey: unnumberedStemKey,
  );
}

final RegExp _volDiscTokenPattern = RegExp(
  r'(?:[\[(（【_\s.-]|^)(Vol|Disc|BD|DVD|Part)[ ._-]*0*(\d{1,2})(?=[\])）】_\s.-]|$)',
  caseSensitive: false,
);

String? _extractVolumeOrDiscSuffix(String fileName, String relativePath) {
  final fileMatch = _volDiscTokenPattern.firstMatch(fileName);
  if (fileMatch != null) {
    final rawKind = fileMatch.group(1)!.toLowerCase();
    final kind = switch (rawKind) {
      'vol' => 'Vol.',
      'disc' => 'Disc ',
      'bd' => 'BD',
      'dvd' => 'DVD',
      _ => 'Part ',
    };
    return '$kind${fileMatch.group(2)!}';
  }
  final parentDir = relativePath.replaceAll('\\', '/');
  final dirOnly = parentDir.contains('/')
      ? parentDir.substring(0, parentDir.lastIndexOf('/'))
      : '';
  if (dirOnly.isNotEmpty) {
    final dirMatch = _volDiscTokenPattern.firstMatch(dirOnly);
    if (dirMatch != null) {
      final rawKind = dirMatch.group(1)!.toLowerCase();
      final kind = switch (rawKind) {
        'vol' => 'Vol.',
        'disc' => 'Disc ',
        'bd' => 'BD',
        'dvd' => 'DVD',
        _ => 'Part ',
      };
      return '$kind${dirMatch.group(2)!}';
    }
  }
  return null;
}

String? _resolveConciseExtraTitle({
  required String fileName,
  required String relativePath,
  required String? extractedTitle,
  required String typeStr,
  required int? explicitNum,
  String? folderCleanTitle,
}) {
  final trimmedExtracted = extractedTitle?.trim() ?? '';
  if (trimmedExtracted.isNotEmpty) {
    // 若短标签仅提取了分类词（如 `MENU`/`CM`）且不含序号，保留文件名/父目录中的 `(Vol.1)`/`Disc 1` 区分卷次。
    if (!_reHot30.hasMatch(trimmedExtracted)) {
      final volSuffix = _extractVolumeOrDiscSuffix(fileName, relativePath);
      if (volSuffix != null) {
        return '$trimmedExtracted $volSuffix';
      }
    }
    return trimmedExtracted;
  }

  final previewMatch = _reHot31.firstMatch(fileName);
  if (previewMatch != null) {
    final webPrefix = previewMatch.group(1) != null ? 'Web ' : '';
    final word = (previewMatch.group(2) ?? previewMatch.group(4))!;
    final numPart = previewMatch.group(3) ?? previewMatch.group(5) ?? '';
    final normalizedWord = switch (word.toLowerCase()) {
      'preview' => '${webPrefix}Preview',
      'teaser' => 'Teaser',
      'trailer' => 'Trailer',
      _ => '预告',
    };
    if (numPart.isNotEmpty) return '$normalizedWord $numPart';
    final volSuffix = _extractVolumeOrDiscSuffix(fileName, relativePath);
    return volSuffix != null ? '$normalizedWord $volSuffix' : normalizedWord;
  }

  final promoMatch = _reHot32.firstMatch(fileName);
  if (promoMatch != null) {
    final tag = promoMatch.group(1)!.toUpperCase().replaceAll(_reHot33, '');
    final numPart = promoMatch.group(2) ?? '';
    return numPart.isEmpty ? tag : '$tag$numPart';
  }

  var cleaned = CloudMediaAssetPresentation.cleanedExtraFilename({
    'name': fileName,
    'relative_path': relativePath,
  });
  if (folderCleanTitle != null && folderCleanTitle.trim().isNotEmpty) {
    final normTitle = folderCleanTitle.trim();
    final prefixPattern = RegExp(
      '^${RegExp.escape(normTitle)}(?:\\s*[-–—_:：]\\s*|\\s+)',
      caseSensitive: false,
    );
    final stripped = cleaned
        .replaceFirst(prefixPattern, '')
        .replaceFirst(_reHot34, '')
        .trim();
    if (stripped.isNotEmpty && stripped.length >= 2) {
      cleaned = stripped;
    }
  }
  if (typeStr.trim().isNotEmpty &&
      typeStr != '特典' &&
      typeStr != '其他' &&
      explicitNum != null) {
    return '${typeStr.trim()}${explicitNum.toString().padLeft(2, '0')}';
  }
  if (cleaned.isNotEmpty) return cleaned;
  if (typeStr.trim().isNotEmpty && typeStr != '特典' && typeStr != '其他') {
    return typeStr.trim();
  }
  return null;
}

String _buildExtraUnnumberedStemKey({
  required String fileName,
  required String relativePath,
  required ParsedBdripRelease parsed,
  required String? shortTitle,
}) {
  final normShort = (shortTitle ?? '').toLowerCase().replaceAll(_reHot29, '');
  var stem = fileName.replaceFirst(_reHot35, '');
  for (final grp in [parsed.releaseGroup, parsed.subtitleGroup]) {
    if (grp != null && grp.trim().isNotEmpty) {
      final esc = RegExp.escape(grp.trim());
      stem = stem.replaceAll(
        RegExp(
          '\\[\\s*$esc\\s*\\]|\\(\\s*$esc\\s*\\)|(?<=[-_\\s])$esc\$',
          caseSensitive: false,
        ),
        ' ',
      );
    }
  }
  // 剔除 CRC32 与常见技术规格参数块，仅保留作品/特典本体内容标识。
  stem = stem.replaceAll(_reHot36, ' ');
  stem = MediaTechParser.stripTechTokens(stem).strippedText;
  final normStem = stem
      .toLowerCase()
      .replaceAll(_reHot29, '_')
      .replaceAll(_reHot37, '_')
      .replaceAll(_reHot38, '');
  final volSuffix = _extractVolumeOrDiscSuffix(
    fileName,
    relativePath,
  )?.toLowerCase().replaceAll(_reHot39, '');
  final parts = <String>[
    if (normShort.isNotEmpty) normShort,
    if (volSuffix != null && volSuffix.isNotEmpty) volSuffix,
    normStem.isNotEmpty ? normStem : relativePath.toLowerCase(),
  ];
  return parts.join('::');
}

List<MediaVariant> _buildVariants({
  required String sourceId,
  required String workId,
  required List<ScannedFileInput> files,
  required String folderTitle,
  int? seasonHint,
  Map<String, SupplementaryAssetScope> assetScopesByPath = const {},
  Map<String, ParsedBdripRelease>? parsedCache,
}) {
  final out = <MediaVariant>[];
  for (final file in files) {
    final parsed = file.assetKind == AssetKind.video
        ? (parsedCache?[file.relativePath] ??
              BdripParser.parseFileName(
                file.fileName,
                relativePath: file.relativePath,
                folderTitle: folderTitle,
                folderSeasonHint: seasonHint,
                resolveEpisode: false,
                resolveExtraClassification: false,
                resolveTitleAndSeason: false,
              ))
        : null;
    out.add(
      MediaVariant(
        id: '$sourceId::${file.relativePath}',
        workId: workId,
        sourceId: sourceId,
        relativePath: file.relativePath,
        fileName: file.fileName,
        fileSize: file.fileSize,
        assetKind: file.assetKind,
        releaseGroup: parsed?.releaseGroup,
        subtitleGroup: parsed?.subtitleGroup ?? file.subtitleGroupHint,
        videoCodec: parsed?.videoCodec,
        bitDepth: parsed?.bitDepth,
        resolution: parsed?.resolution,
        audioCodec: parsed?.audioCodec,
        externalSubtitles: file.externalSubtitles,
        assetScope:
            assetScopesByPath[file.relativePath] ??
            SupplementaryAssetScope.workExclusive,
      ),
    );
  }
  return out;
}

Set<String> _detectMultiInstallmentRoots(
  List<ScannedFileInput> files, {
  required Map<String, String> nfoByFolder,
}) {
  final childSegsByParent = <String, Set<String>>{};
  final visitedVideoDirs = <String>{};
  for (final file in files) {
    if (file.assetKind != AssetKind.video) continue;
    final path = file.relativePath.replaceAll('\\', '/');
    final slash = path.lastIndexOf('/');
    if (slash <= 0 ||
        (slash < path.length - 1 &&
            !visitedVideoDirs.add(path.substring(0, slash)))) {
      continue;
    }
    final segments = path.split('/').where((s) => s.isNotEmpty).toList();
    if (segments.length < 3) continue;
    final dirSegs = segments.sublist(0, segments.length - 1);
    for (var k = 1; k < dirSegs.length; k++) {
      final parentPath = dirSegs.sublist(0, k).join('/');
      final parentLeaf = dirSegs[k - 1].trim();
      if (parentLeaf.isEmpty ||
          _categoryFolderPattern.hasMatch(parentLeaf) ||
          _yearParentPattern.hasMatch(parentLeaf)) {
        continue;
      }
      final childSeg = dirSegs[k].trim();
      // 排除纯特典/CD/Scan 目录与纯光盘分卷目录（Disc/Vol/BD），仅统计季/独立篇章正片目录。
      final isPureExtraDir =
          SupplementaryFolderRules.isSupplementarySegment(childSeg) &&
          !SupplementaryFolderRules.isSeasonOrVolumeSegment(childSeg);
      final isDiscVolumeOnly =
          SupplementaryFolderRules.isSeasonOrVolumeSegment(childSeg) &&
          !SupplementaryFolderRules.isExplicitSeasonSubdir(childSeg);
      if (isPureExtraDir || isDiscVolumeOnly) continue;
      childSegsByParent.putIfAbsent(parentPath, () => {}).add(childSeg);
    }
  }

  final roots = <String>{};
  for (final entry in childSegsByParent.entries) {
    final parentPath = entry.key;
    final children = entry.value;
    if (children.length < 2) continue;
    if (!children.any(SupplementaryFolderRules.isExplicitSeasonSubdir)) {
      continue;
    }
    final parentLeaf = _lastSegment(parentPath);
    if (PersonalFilenameParser.tmdbIds(parentLeaf).isNotEmpty ||
        _bangumiMarker.hasMatch(parentLeaf)) {
      continue;
    }
    final nfoText = nfoByFolder[parentPath];
    if (nfoText != null &&
        DirectoryGrouper.parseNfoText(nfoText).tmdbId != null) {
      continue;
    }
    roots.add(parentPath);
  }
  return roots;
}

String _resolvePhysicalWorkFolder(
  String relativePath, {
  Set<String> multiInstallmentRoots = const {},
  Set<String> anchoredPackageRoots = const {},
}) {
  final segments = relativePath
      .replaceAll('\\', '/')
      .split('/')
      .where((s) => s.isNotEmpty)
      .toList();
  if (segments.length <= 1) return '';
  final parentSegments = segments.sublist(0, segments.length - 1);

  final anchor = _deepestAnchorIndex(parentSegments);
  if (anchor >= 0) {
    final anchorPath = parentSegments.sublist(0, anchor + 1).join('/');
    if (anchoredPackageRoots.contains(anchorPath) &&
        anchor + 1 < parentSegments.length &&
        !SupplementaryFolderRules.isSupplementarySegment(
          parentSegments[anchor + 1],
        )) {
      return parentSegments.sublist(0, anchor + 2).join('/');
    }
    return anchorPath;
  }

  var scanStart = 1;
  if (multiInstallmentRoots.isNotEmpty) {
    for (var k = 1; k < parentSegments.length; k++) {
      final candidateRoot = parentSegments.sublist(0, k).join('/');
      if (multiInstallmentRoots.contains(candidateRoot) &&
          SupplementaryFolderRules.isExplicitSeasonSubdir(parentSegments[k])) {
        scanStart = k + 1;
        break;
      }
    }
  }

  var firstSuppIndex = -1;
  for (var i = scanStart; i < parentSegments.length; i++) {
    if (SupplementaryFolderRules.isSupplementarySegment(parentSegments[i])) {
      firstSuppIndex = i;
      break;
    }
  }
  if (firstSuppIndex > 0) {
    return parentSegments.sublist(0, firstSuppIndex).join('/');
  }

  while (parentSegments.length > scanStart &&
      SupplementaryFolderRules.isSupplementarySegment(parentSegments.last)) {
    parentSegments.removeLast();
  }
  return parentSegments.join('/');
}

Map<String, List<ScannedFileInput>> _foldNestedBuckets(
  Map<String, List<ScannedFileInput>> rawBuckets,
) {
  final buckets = <String, List<ScannedFileInput>>{};
  final videoFolderKeys = rawBuckets.entries
      .where(
        (e) =>
            e.key.isNotEmpty &&
            e.value.any((f) => f.assetKind == AssetKind.video),
      )
      .map((e) => e.key)
      .toSet();
  final hasRootVideo =
      rawBuckets['']?.any((f) => f.assetKind == AssetKind.video) ?? false;

  for (final entry in rawBuckets.entries) {
    final path = entry.key;
    if (path.isNotEmpty &&
        !videoFolderKeys.contains(path) &&
        SupplementaryFolderRules.isAudioOrScanPath(path)) {
      final ancestor = _findNearestAncestorFolder(path, videoFolderKeys);
      if (ancestor != null) {
        buckets.putIfAbsent(ancestor, () => []).addAll(entry.value);
        continue;
      }
      if (hasRootVideo) {
        buckets.putIfAbsent('', () => []).addAll(entry.value);
        continue;
      }
    }

    // 若目录结构为 `合集父目录/Movie/xxx.mkv` 或 `合集父目录/TV/xxx.mkv`，
    // 且父目录自身不是「电影/剧场版/动画」分类根，则折叠到合集父目录交由 MultiWorkSplitter 统一拆簇。
    if (path.contains('/')) {
      final slash = path.lastIndexOf('/');
      final parent = path.substring(0, slash);
      final leaf = path.substring(slash + 1);
      final parentLeaf = _lastSegment(parent);
      final parentIsCollection =
          rawBuckets.containsKey(parent) ||
          MultiWorkSplitter.isExplicitCollectionFolder(
            parent,
            DirectoryInventory.synthetic(
              folder: parent,
              title: parentLeaf,
              main: const [],
              shape: WorkShape.series,
              titleHints: [parentLeaf],
            ),
          );
      if (parent.isNotEmpty &&
          !_categoryFolderPattern.hasMatch(parentLeaf) &&
          _collectionSubdirLeaf.hasMatch(leaf) &&
          parentIsCollection) {
        buckets.putIfAbsent(parent, () => []).addAll(entry.value);
        continue;
      }
    }

    buckets.putIfAbsent(path, () => []).addAll(entry.value);
  }
  return buckets;
}

String? _findNearestAncestorFolder(String folderPath, Set<String> candidates) {
  if (folderPath.isEmpty) return null;
  final parts = folderPath.split('/');
  for (var len = parts.length - 1; len >= 1; len--) {
    final candidate = parts.sublist(0, len).join('/');
    if (candidates.contains(candidate)) return candidate;
  }
  return candidates.contains('') ? '' : null;
}

bool _shouldSplitExplicitTmdb(
  DirectoryInventory inventory,
  List<SubWorkCluster> preview, {
  bool anchoredMovieSplit = false,
}) {
  if (preview.length < 2) return false;
  final hasUnbound = preview.any((c) => c.inventory.tmdbId == null);
  if (!hasUnbound) return false;
  if (anchoredMovieSplit) {
    return preview.any((c) => c.inventory.movieMarker);
  }
  if (preview.any((c) => c.inventory.tmdbId != null)) return true;
  return preview.any(
    (c) =>
        c.inventory.movieMarker ||
        _independentInstallmentMarker.hasMatch(
          '${c.virtualFolder} ${c.inventory.title} ${c.inventory.titleHints.join(' ')}',
        ),
  );
}

String _buildSplitVirtualFolder(String physicalFolder, String slug) {
  final cleanSlug = slug.trim().isEmpty ? 'part' : slug.trim();
  if (physicalFolder.isEmpty) return '::$cleanSlug';
  return '$physicalFolder::$cleanSlug';
}

String _stripFolderPrefix(String relativePath, String folderPath) {
  final normRel = relativePath.replaceAll('\\', '/');
  final normFolder = folderPath.replaceAll('\\', '/').replaceAll(_reHot3, '');
  if (normFolder.isEmpty) return normRel;
  if (normRel.startsWith('$normFolder/')) {
    return normRel.substring(normFolder.length + 1);
  }
  return normRel;
}

String _lastSegment(String path) {
  if (path.isEmpty) return 'Root';
  final norm = path.replaceAll('\\', '/');
  final idx = norm.lastIndexOf('/');
  return idx >= 0 ? norm.substring(idx + 1) : norm;
}

TmdbMediaType? _parseTmdbMediaType(String? raw) {
  if (raw == 'tv') return TmdbMediaType.tv;
  if (raw == 'movie') return TmdbMediaType.movie;
  return null;
}

ExtraKind? _mapExtraKindFromName(String? raw) {
  if (raw == null || raw.trim().isEmpty) return null;
  switch (raw.trim().toUpperCase()) {
    case 'NCOP':
    case 'NCOPED':
      return ExtraKind.ncop;
    case 'NCED':
      return ExtraKind.nced;
    case 'PV':
    case 'CM':
    case 'PVCM':
    case 'TVCM':
    case 'BDCM':
    case 'TRAILER':
    case 'TEASER':
    case 'SPOT':
      return ExtraKind.pv;
    case 'OVA':
    case 'OAD':
    case 'EX':
      return ExtraKind.ova;
    case 'SP':
    case 'SPECIAL':
    case 'OAB':
    case 'IV':
    case 'INTERVIEW':
    case 'MAKING':
    case 'DIGEST':
    case 'EVENT':
    case 'EYECATCH':
    case 'PROMOTION':
    case 'INFO':
    case 'INFORMATION':
      return ExtraKind.sp;
    case 'MENU':
    case 'MENUEX':
      return ExtraKind.menu;
    case 'MV':
    case 'MUSIC VIDEO':
    case 'MUSIC CLIP':
      return ExtraKind.mv;
    default:
      return ExtraKind.sp;
  }
}

({List<String> extraTitleHints, List<String> extraQueries, bool isSpecial})
_buildClusterParentHints({
  required SubWorkCluster cluster,
  required Map<String, ScannedFileInput> fileByRelPath,
  required String parentSeriesTitle,
  required List<String> explicitSegments,
}) {
  final extraQueries = <String>[];
  final extraTitleHints = <String>[];
  final altPart = _alternativePartForCluster(cluster, fileByRelPath);
  final isSpecial = _isClusterSpecial(cluster);
  final isEx = _isClusterEx(cluster);

  if (altPart != null) {
    final vol = altPart == 1 ? 'ONE' : 'TWO';
    final hasVolSuffix = _reHot46;
    for (final hint in [
      cluster.inventory.title,
      ...cluster.inventory.titleHints,
    ]) {
      final trimmed = hint.trim();
      if (_reHot47.hasMatch(trimmed) && !hasVolSuffix.hasMatch(trimmed)) {
        extraTitleHints.add('$trimmed $vol');
        extraQueries.add('$trimmed $vol');
      }
    }
    if (parentSeriesTitle.isNotEmpty) {
      final trimmedParent = parentSeriesTitle.trim();
      final hasAltWord = _reHot47.hasMatch(trimmedParent);
      if (hasAltWord) {
        if (!hasVolSuffix.hasMatch(trimmedParent)) {
          extraTitleHints.add('$trimmedParent $vol');
          extraQueries.add('$trimmedParent $vol');
        }
        final pureParent = trimmedParent.replaceFirst(_reHot48, '').trim();
        if (pureParent.isNotEmpty && pureParent != trimmedParent) {
          extraQueries.add(pureParent);
        }
      } else {
        extraTitleHints.add('$trimmedParent Alternative $vol');
        extraQueries.add('$trimmedParent Alternative $vol');
      }
    }
  }

  final matchedArcs = <String>{
    for (final hint in [
      cluster.inventory.title,
      ...cluster.inventory.titleHints,
    ])
      ...WorkMatcher.romajiArcSuffixesFor(hint),
  };
  if (parentSeriesTitle.isNotEmpty) {
    if (isSpecial || isEx || altPart != null || matchedArcs.isNotEmpty) {
      extraQueries.add(parentSeriesTitle);
    }
    for (final arcCjk in matchedArcs) {
      extraTitleHints.add('$parentSeriesTitle $arcCjk');
      extraQueries.add('$parentSeriesTitle $arcCjk');
    }
    if (isEx) {
      extraQueries.add('$parentSeriesTitle EX');
      extraTitleHints.add('$parentSeriesTitle EX');
    } else if (isSpecial) {
      extraQueries.add('$parentSeriesTitle OAD');
      extraQueries.add('$parentSeriesTitle OVA');
      extraTitleHints.add('$parentSeriesTitle OAD');
      extraTitleHints.add('$parentSeriesTitle OVA');
    }
  }
  // 若子簇已精确对齐至 `A & B` 合集目录中的某一段标题，则仅保留该段而不注入兄弟段，
  // 防止兄弟作品的 Bangumi/TMDB 候选反向拉平本簇分差。
  final clusterTitleNorm = DirectoryAnalyzer.normalize(cluster.inventory.title);
  final matchedSeg = explicitSegments.where((seg) {
    final sn = DirectoryAnalyzer.normalize(seg);
    return sn.isNotEmpty && sn == clusterTitleNorm;
  }).firstOrNull;
  if (matchedSeg != null) {
    final clean = matchedSeg.trim();
    if (clean.isNotEmpty && !extraQueries.contains(clean)) {
      extraQueries.add(clean);
    }
  } else {
    for (final seg in explicitSegments) {
      final clean = seg.trim();
      if (clean.isNotEmpty && !extraQueries.contains(clean)) {
        extraQueries.add(clean);
      }
    }
  }
  return (
    extraTitleHints: _dedupePreserveOrder(extraTitleHints),
    extraQueries: _dedupePreserveOrder(extraQueries),
    isSpecial: isSpecial,
  );
}

String _extractParentSeriesTitle(String folder) {
  final segments = folder
      .replaceAll('\\', '/')
      .split('/')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();
  if (segments.isEmpty) return '';
  var raw = segments.last
      .replaceAll(_reHot8, ' ')
      .replaceAll(_reHot9, ' ')
      .replaceAll(_reHot10, ' ')
      .replaceAll(_reHot49, ' ')
      .replaceAll(_reHot11, ' ')
      .trim();
  final suffixRe = _reHot50;
  for (var i = 0; i < 3; i++) {
    final next = raw.replaceFirst(suffixRe, '').trim();
    if (next == raw) break;
    raw = next;
  }
  if (raw.isEmpty ||
      _categoryFolderPattern.hasMatch(raw) ||
      _genericSeasonName.hasMatch(raw)) {
    return '';
  }
  return _hasCjk(raw) ? raw : (raw.length >= 3 ? raw : '');
}

bool _isClusterEx(SubWorkCluster cluster) {
  final texts = [
    cluster.inventory.title,
    ...cluster.inventory.titleHints,
    ...cluster.inventory.fileHints,
  ];
  return texts.any((t) => _reHot51.hasMatch(t));
}

bool _isClusterSpecial(SubWorkCluster cluster) {
  if (cluster.inventory.folderMovieMarker ||
      cluster.inventory.fileMovieMarker) {
    return false;
  }
  if (cluster.inventory.season == 0 || _isClusterEx(cluster)) return true;
  final specialRe = _reHot52;
  return [
    cluster.inventory.title,
    ...cluster.inventory.titleHints,
    ...cluster.inventory.fileHints,
  ].any(specialRe.hasMatch);
}

int? _alternativePartForCluster(
  SubWorkCluster cluster,
  Map<String, ScannedFileInput> fileByRelPath,
) {
  final allTexts = [
    cluster.inventory.title,
    ...cluster.inventory.titleHints,
    ...cluster.inventory.fileHints,
  ];
  final hasAlt = allTexts.any((t) => _reHot24.hasMatch(t));
  if (!hasAlt) return null;
  final alreadyPart = cluster.inventory.titleHints.any(
    (h) => _reHot25.hasMatch(h),
  );
  if (alreadyPart) return null;
  if (cluster.inventory.episodes.length == 1) {
    final ep = cluster.inventory.episodes.single;
    if (ep == 1 || ep == 2) return ep;
  }
  final mainEps = cluster.assignments
      .where((a) => a.category == 'main' && a.episode != null)
      .map((a) => a.episode!)
      .toSet();
  if (mainEps.length == 1) {
    final ep = mainEps.single;
    if (ep == 1 || ep == 2) return ep;
  }
  for (final a in cluster.assignments.where((a) => a.category == 'main')) {
    final name = fileByRelPath[a.relativePath]?.fileName ?? '';
    if (_reHot53.hasMatch(name)) return 1;
    if (_reHot54.hasMatch(name)) return 2;
  }
  return null;
}

List<String> _dedupePreserveOrder(List<String> values) {
  final seen = <String>{};
  final out = <String>[];
  for (final v in values) {
    final t = v.trim();
    if (t.isEmpty) continue;
    if (seen.add(t.toLowerCase())) out.add(t);
  }
  return out;
}

/// 预编译热点正则表达式（避免在逐文件遍历与归组打分热路径中重复编译）。
final RegExp _reHot1 = RegExp(r'\s+[&＆]\s+');

final RegExp _reHot2 = RegExp(r'[^a-z0-9぀-鿿]+');

final RegExp _reHot3 = RegExp(r'^/+|/+$');

final RegExp _reHot4 = RegExp(
  r'ncop|nced|menu|pv|cm|spot|making|digest|予告|預告|预告|特報',
  caseSensitive: false,
);

final RegExp _reHot5 = RegExp(r'^[\[【]');

final RegExp _reHot6 = RegExp(
  r'^(?:vol(?:ume)?|disc|disk|bd|dvd|cd|part|chs|cht|sc|tc|jp|en|sub|subs|subtitles|fonts?)\b',
  caseSensitive: false,
);

final RegExp _reHot7 = RegExp(r'[^a-z0-9\u4e00-\u9fff]+');

final RegExp _reHot30 = RegExp(r'\d');

final RegExp _reHot31 = RegExp(
  r'(?:\b(web)[ ._-]+)?\b(preview|teaser|trailer)\b(?:[ ._-]*(\d{1,3}))?|'
  r'([予預]告)(?:[ ._-]*(\d{1,3}))?',
  caseSensitive: false,
);

final RegExp _reHot32 = RegExp(
  r'(?<![a-z0-9])(TV[ ._-]*CM|BD[ ._-]*CM|PV[ ._-]*CM|CM|PV)(?:[ ._-]*0*(\d{1,3}))?(?![a-z0-9])',
  caseSensitive: false,
);

final RegExp _reHot33 = RegExp(r'[ ._-]+');

final RegExp _reHot34 = RegExp(r'^[\s\-–—_:：]+');

final RegExp _reHot35 = RegExp(r'\.[^.]+$');

final RegExp _reHot36 = RegExp(r'\[[0-9a-fA-F]{8}\]');

final RegExp _reHot37 = RegExp(r'_+');

final RegExp _reHot38 = RegExp(r'^_+|_+$');

final RegExp _reHot46 = RegExp(
  r'(?:^|\s)(?:one|two|[12])$',
  caseSensitive: false,
);

final RegExp _reHot47 = RegExp(r'\balternative\b', caseSensitive: false);

final RegExp _reHot48 = RegExp(
  r'\s*\balternative(?:\s+(?:one|two|[12]))?\s*$',
  caseSensitive: false,
);

final RegExp _reHot49 = RegExp(r'\[[^\]]*\]');

final RegExp _reHot50 = RegExp(
  r'[\s\-+_,]*(?:TV\s*\+\s*Movie|TV\s*\+\s*OVA|TV|OVA|OAD|SP|Movies?|系列|作品集|合集|全集|Series|Collection)\s*$',
  caseSensitive: false,
);

final RegExp _reHot51 = RegExp(
  r'(?<![a-z0-9])ex(?:\d{1,2})?(?![a-z0-9])',
  caseSensitive: false,
);

final RegExp _reHot52 = RegExp(
  r'(?<![a-z0-9])(?:ova|oad|sp|specials?)(?![a-z0-9])|特典|特别篇|番外',
  caseSensitive: false,
);

final RegExp _reHot53 = RegExp(r'(?:^|[^0-9])0?1(?:[^0-9]|$)');

final RegExp _reHot54 = RegExp(r'(?:^|[^0-9])0?2(?:[^0-9]|$)');
