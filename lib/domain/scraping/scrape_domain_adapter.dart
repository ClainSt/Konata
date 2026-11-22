import '../matching/directory_grouper.dart';
import '../matching/supplementary_folder_rules.dart';
import '../matching/supplementary_subclassifier.dart';
import '../matching/work_matcher.dart';
import '../models/episode.dart';
import '../models/media_variant.dart';
import '../models/tmdb_models.dart';
import '../models/work.dart';
import '../parsing/bdrip_parser.dart';
import '../parsing/media_tech_parser.dart';
import 'bangumi_models.dart';
import 'bangumi_tmdb_index.dart';
import 'cloud_media_asset_presentation.dart';
import 'cloud_media_file_classifier.dart';
import 'collection_asset_router.dart';
import 'directory_analyzer.dart';
import 'match_difficulty_classifier.dart';
import 'multi_work_splitter.dart';
import 'personal_filename_parser.dart';
import 'search_query_sanitizer.dart';
import 'work_matcher.dart' as legacy;
import 'work_season.dart';

/// 将 `feat/scrape-pipeline` 无损核心算法与 v2 强类型领域模型桥接的纯领域适配器（零 IO）。
abstract final class ScrapeDomainAdapter {
  static final RegExp _movieMarkerPattern = RegExp(
    r'\b(?:movie|film|theatrical)\b|剧场版|劇場版|映画',
    caseSensitive: false,
  );

  static final RegExp _collectionSubdirLeaf = RegExp(
    r'^(?:movies?|films?|theatrical|劇場版|剧场版|tv(?:版)?|ovas?)$',
    caseSensitive: false,
  );

  static final RegExp _categoryFolderPattern = RegExp(
    r'^(?:动画|番剧|电影|剧场版|劇場版|动漫|影视|日漫|国漫|美漫|'
    r'动画[-_]?单作品|动画[-_]?多作品|动画[-_]?天雪论坛|动画[-_]?系列作未收集|'
    r'天雪论坛|系列作未收集|未添加\s*tmdb(?:\s*id)?|'
    r'乱目录测试|测试目录?|待整理|未整理|临时|未分类|杂项|收藏夹?|'
    r'anime|movies?|tv|series|bdmv|bdrip|video|media|downloads?)$',
    caseSensitive: false,
  );

  /// 独立大型剧场版最低体积门槛（300 MB；测试夹具无体积时放行）。
  static const int _minAnchoredMovieSplitBytes = 300 * 1024 * 1024;

  static final RegExp _anchoredMovieFilePattern = RegExp(
    r'(?<![a-z0-9])(?:the[ ._-]+)?movie(?![a-z0-9])|剧场版|劇場版',
    caseSensitive: false,
  );

  static final RegExp _singleIndexedMovieFolderPattern = RegExp(
    r'第\s*[0-9一二三四五六七八九十]{1,2}\s*[章部]|'
    r'(?<![a-z0-9])(?:movie|part|chapter)\s*(?:1st|2nd|3rd|\d+)(?![a-z0-9])',
    caseSensitive: false,
  );

  static final RegExp _anchoredMovieExcludedPattern = RegExp(
    r'memorial[ ._-]*movie|weekly[ ._-]*movies?|digest[ ._-]*movie|'
    r'[\[【]\s*\d{1,3}\s*[-–—~～]\s*\d{1,3}\s*[\(（]\s*movie\s*[\)）]\s*[\]】]',
    caseSensitive: false,
  );

  static final RegExp _anchoredChapterFeaturePattern = RegExp(
    r'第\s*[0-9一二三四五六七八九十]{1,2}\s*[章部]|'
    r'(?:^|[^a-z0-9])(?:zenpen|kouhen|chuhen)(?=[^a-z0-9]|$)|'
    r'前[篇編]|后[篇編]|後[篇編]|中[篇編]|'
    r'[#＃]\s*0*[1-9]\s*[～~〜][^～~〜]+?[の之]?[巻卷]|'
    r'(?<![a-z0-9])movie[ ._-]*0*[1-9](?![0-9a-z])',
    caseSensitive: false,
  );

  static final RegExp _genericSeasonName = RegExp(
    r'^(?:season\s*\d+|series\s*\d+|specials?|第\s*[0-9一二三四五六七八九十百]+\s*[季期部]|特别篇|特別編|特典)$',
    caseSensitive: false,
  );

  static final RegExp _parenYearPattern = RegExp(
    r'[（(]\s*((?:19|20)\d{2})\s*[）)]',
  );

  static final RegExp _independentInstallmentMarker = RegExp(
    r'(?:^|[\s._\-\[(])(?:ova|oad|movie|film|theatrical|剧场版|劇場版|外伝|外传|spin[._-]?off)(?=$|[\s._\-\])])',
    caseSensitive: false,
  );

  static final RegExp _ovaOrSpMarker = RegExp(
    r'(?:^|[\s._\-\[(])(?:ova|oad|sp|special|ex\d{0,2})(?=$|[\s._\-\])])',
    caseSensitive: false,
  );

  static final RegExp _bangumiMarker = RegExp(
    r'[\[{]\s*(?:bgm|bangumi)(?:id)?\s*[-=:_]\s*(\d+)\s*[\]}]',
    caseSensitive: false,
  );

  static final RegExp _yearParentPattern = RegExp(
    r'^(?:19|20)\d{2}(?:[-._]\d{1,2})?(?:年.*)?$',
  );

  /// 媒体库「标题 (年份)」命名约定：年份括号位于末尾，其后只允许跟随 `{...}`/`[...]` 标识块。
  static final RegExp _trailingYearAnchor = RegExp(
    r'\S.*?[(（]\s*(?:19|20)\d{2}\s*[)）](?:\s*[\[{【][^\]}】]*[\]}】])*\s*$',
  );

  /// 判定目录段是否为锚定作品根目录：0 表示非锚定，1 表示「标题 (年份)」约定，2 表示携带显式刮削 ID。
  ///
  /// 锚定根目录代表用户已按媒体库规范整理好的单部作品，其下所有子目录（压制组目录、分卷、
  /// 字幕语言版本、特典目录等）一律向上归并，不再按子目录碎片化成独立作品。
  static int _workRootAnchorKind(String segment) {
    final trimmed = segment.trim();
    if (trimmed.isEmpty) return 0;
    if (PersonalFilenameParser.tmdbIds(trimmed).isNotEmpty ||
        _bangumiMarker.hasMatch(trimmed)) {
      return 2;
    }
    if (!_trailingYearAnchor.hasMatch(trimmed)) return 0;
    if (_categoryFolderPattern.hasMatch(trimmed) ||
        SupplementaryFolderRules.isSupplementarySegment(trimmed)) {
      return 0;
    }
    return 1;
  }

  /// 判断「标题 (年份)」目录名中的 ` & ` 是否真的并列了多部作品：每一段都必须拥有其他段没有的独有词，
  /// 且这些独有词分别命中互不重叠的视频文件（如 `FLCL Alternative & FLCL Progressive`）。
  /// `TIGER & BUNNY`、`NULL & PETA` 这类片名本身含 `&` 的目录，各段词在全部文件中同时出现，不满足条件。
  static bool _isDisjointAmpersandCollection(
    String folderLeaf,
    List<ScannedFileInput> videos,
  ) {
    final segments = DirectoryAnalyzer.cleanTitle(folderLeaf)
        .split(RegExp(r'\s+[&＆]\s+'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList(growable: false);
    if (segments.length < 2) return false;
    Set<String> tokens(String value) => value
        .toLowerCase()
        .split(RegExp(r'[^a-z0-9぀-鿿]+'))
        .where((t) => t.length >= 2)
        .toSet();
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
  static bool _hasAnchoredStandaloneMovieToSplit(
    List<ScannedFileInput> videoFiles, {
    required String folderPath,
    required String folderLeafName,
  }) {
    // 目录名已明确声明为单部带序号的剧场版（如 `第一章 觉醒之刻`、`The MOVIE 1st`），不再按多章拆开。
    if (_singleIndexedMovieFolderPattern.hasMatch(folderLeafName)) {
      return false;
    }
    final normFolder = folderPath
        .replaceAll('\\', '/')
        .replaceAll(RegExp(r'^/+|/+$'), '');
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
          RegExp(
            r'ncop|nced|menu|pv|cm|spot|making|digest|予告|預告|预告|特報',
            caseSensitive: false,
          ).hasMatch(name)) {
        continue;
      }
      final isLarge =
          v.fileSize <= 0 || v.fileSize >= _minAnchoredMovieSplitBytes;
      final isMovieFile =
          isLarge &&
          _anchoredMovieFilePattern.hasMatch(name) &&
          !_anchoredMovieExcludedPattern.hasMatch(name);
      final chapterMatch = isLarge
          ? _anchoredChapterFeaturePattern.firstMatch(name)
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
        chapterMarkers.add(
          DirectoryAnalyzer.normalize(chapterMatch.group(0)!),
        );
      }
    }

    // 场景 A：常规多集 TV 目录内捆绑了明确独立剧场版（排除全片都是剧场版同片多版本）。
    if (regularEpisodeCount >= 4 && bigMovieCount >= 1 && bigMovieCount <= 3) {
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
  static int _deepestAnchorIndex(List<String> dirSegments) {
    for (var i = dirSegments.length - 1; i >= 0; i--) {
      if (_workRootAnchorKind(dirSegments[i]) > 0) return i;
    }
    return -1;
  }

  /// 检测「锚定父目录下直接包含多个自带独立附属目录（SPs/CDs/Scans/Extras）的子作品包」
  /// （例如 `物语系列 第二季 (2013) {tmdb-46195}/倾物语`、`囮物语`、`恋物语` 等），
  /// 以便将每个子篇章拆为独立作品并各自保留专属封面与附属资源。
  static Set<String> _detectAnchoredPackageCollectionRoots(
    List<ScannedFileInput> files,
  ) {
    final childMainVideos = <String, Map<String, int>>{};
    final childSuppDirs = <String, Set<String>>{};
    final groupPrefix = RegExp(r'^[\[【]');
    final discOrLang = RegExp(
      r'^(?:vol(?:ume)?|disc|disk|bd|dvd|cd|part|chs|cht|sc|tc|jp|en|sub|subs|subtitles|fonts?)\b',
      caseSensitive: false,
    );

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
          SupplementaryFolderRules.isSupplementarySegment(
            dirSegs[anchor + 2],
          )) {
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
  static List<GroupedWorkFolder> groupAndSplitFiles({
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
            <String, Object?>{
              'id': v.relativePath,
              'relative_path': v.relativePath,
              'name': v.fileName,
              'size': v.fileSize,
            },
        ];
        final preview = MultiWorkSplitter.split(folderPath, rawAssets);
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
              .split(RegExp(r'[^a-z0-9\u4e00-\u9fff]+'))
              .where((t) => t.length >= 3)
              .toSet();
          for (final c in preview) {
            final isMovieCluster =
                c.inventory.tmdbType == 'movie' ||
                c.inventory.movieMarker ||
                (c.inventory.shape == WorkShape.feature &&
                    !_ovaOrSpMarker.hasMatch(c.inventory.title) &&
                    c.inventory.season != 0);
            final leafTokens = c.inventory.title
                .toLowerCase()
                .split(RegExp(r'[^a-z0-9\u4e00-\u9fff]+'))
                .where((t) => t.length >= 3 && !splitParentTokens.contains(t))
                .toSet();
            splitTargets.add(
              CollectionTargetDescriptor(
                key: c.slug,
                seasonNumber: c.inventory.season,
                isMovie: isMovieCluster,
                titleTokens: leafTokens,
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
                .map(
                  (f) => (fileName: f.fileName, relativePath: f.relativePath),
                )
                .toList(growable: false);

            final clusterParsedCache = <String, ParsedBdripRelease>{};
            for (final item in cluster.assignments) {
              final raw = fileByRelPath[item.relativePath];
              if (raw == null) continue;
              clusterFiles.add(raw);
              final isExtra = item.category == 'extra';
              final parsed = BdripParser.parseFileName(
                raw.fileName,
                relativePath: raw.relativePath,
                folderTitle: cluster.inventory.title,
                folderSeasonHint: cluster.inventory.season,
              );
              clusterParsedCache[raw.relativePath] = parsed;
              if (isExtra) {
                slotMap[raw.relativePath] = resolveExtraSlotAssignment(
                  fileName: raw.fileName,
                  relativePath: raw.relativePath,
                  parsed: parsed,
                  folderCleanTitle: cluster.inventory.title,
                  overrideExtraType: item.extraType,
                  overrideEpisode: item.episode,
                  workVideoEntries: clusterVideoEntries,
                  cdAlbumPaths: clusterCdPaths,
                );
              } else {
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
              explicitMediaType: _parseTmdbMediaType(
                cluster.inventory.tmdbType,
              ),
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
  static String? _resolveDedicatedClusterLocalCover({
    required String parentFolderPath,
    required List<ScannedFileInput> clusterFiles,
    required Map<String, EpisodeSlotAssignment> slotMap,
    required Map<String, String> localCoverByFolder,
  }) {
    if (localCoverByFolder.isEmpty) return null;
    final normParent = parentFolderPath
        .trim()
        .replaceAll('\\', '/')
        .replaceAll(RegExp(r'^/+|/+$'), '');
    final mainDirs = <String>{};
    for (final f in clusterFiles) {
      if (f.assetKind != AssetKind.video) continue;
      final slot = slotMap[f.relativePath];
      if (slot != null && slot.category != EpisodeCategory.main) continue;
      final normRel = f.relativePath
          .trim()
          .replaceAll('\\', '/')
          .replaceAll(RegExp(r'^/+|/+$'), '');
      final slash = normRel.lastIndexOf('/');
      final dir = slash > 0 ? normRel.substring(0, slash) : '';
      mainDirs.add(dir);
    }
    if (mainDirs.length != 1) return null;
    final onlyDir = mainDirs.first;
    if (onlyDir.isEmpty || onlyDir == normParent) return null;
    return localCoverByFolder[onlyDir];
  }

  /// 构建遵循 `feat/scrape-pipeline` 多波次检索策略的去重搜索词表（最多 10 个；支持 Bangumi 交叉词救回）。
  static List<String> buildSearchQueries(
    GroupedWorkFolder folder, {
    ScoredBangumiCandidate? bangumiCandidate,
    List<String> extraQueries = const [],
  }) {
    final inv = _effectiveInventory(folder);
    final seen = <String>{};
    final out = <String>[];

    void addSingle(String raw, {bool allowGroupHomonym = false}) {
      final stripped = raw
          .replaceAll(RegExp(r'\{[^}]*\}'), ' ')
          .replaceAll(RegExp(r'\(\s*(?:19|20)\d{2}\s*\)'), ' ')
          .replaceAll(RegExp(r'（\s*(?:19|20)\d{2}\s*）'), ' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      final sanitized = SearchQuerySanitizer.sanitize(
        _cutTechnicalTail(stripped),
      );
      final clean = sanitized.isNotEmpty ? sanitized : stripped;
      if (clean.isEmpty ||
          _isJunkQuery(clean, allowGroupHomonym: allowGroupHomonym) ||
          _isJunkQuery(stripped, allowGroupHomonym: allowGroupHomonym)) {
        return;
      }
      final key = clean.toLowerCase().replaceAll(
        RegExp(r'[\s:：\-～~·・･/—]+'),
        '',
      );
      if (key.isEmpty || !seen.add(key)) return;
      out.add(clean);
    }

    final deferredFallbacks = <String>[];

    void add(
      String raw, {
      bool expandVariants = true,
      bool allowGroupHomonym = false,
      bool immediateSpecialFallback = false,
    }) {
      addSingle(raw, allowGroupHomonym: allowGroupHomonym);
      if (!expandVariants) return;
      void emitFallback(String term) {
        if (immediateSpecialFallback) {
          addSingle(term, allowGroupHomonym: allowGroupHomonym);
        } else {
          deferredFallbacks.add(term);
        }
      }

      // 根目录仅附带蓝光单卷标签（如 `孤独摇滚 Vol.1`、`葬送的芙莉莲 第1卷`，排除 `Alternative Vol.1`/`OVA Vol.1` 独立卷）时，
      // 立即补充剥离分卷后的纯净母剧名检索词，避免单卷先扫时在线检索漏召回。
      if (!RegExp(
        r'(?<![a-z0-9])(?:alternative|ova|oad|oav|sp\d*|special)(?![a-z0-9])',
        caseSensitive: false,
      ).hasMatch(raw)) {
        final volTail = RegExp(
          r'^(.*?)\s*(?:[-–—:：]\s*|\s+)(?:(?:bd|dvd)\s*)?(?:vol(?:ume)?\.?\s*0*\d{1,2}|第\s*[0-9一二三四五六七八九十]+\s*[卷巻])\s*$',
          caseSensitive: false,
        ).firstMatch(raw.trim());
        final baseNoVol = volTail?.group(1)?.trim() ?? '';
        if (baseNoVol.length >= 2) {
          addSingle(baseNoVol, allowGroupHomonym: allowGroupHomonym);
        }
      }
      // 剥离尾部或中置 OVA/OAD/OADs/OVA1/TVSP/The Movie 及其后副标题，提炼母系列检索词。
      final beforeSpecial = RegExp(
        r'^(.+?)\s+(?:the\s+movie|movie|ova\d*|oads?|oav\d*|tvsp|sp\d+|special\s+ride)\b',
        caseSensitive: false,
      ).firstMatch(raw.trim());
      if (beforeSpecial != null) {
        final baseSeries = beforeSpecial
            .group(1)!
            .replaceFirst(
              RegExp(r'\s+the\s+animation$', caseSensitive: false),
              '',
            )
            .trim();
        if (baseSeries.length >= 4 || _hasCjk(baseSeries)) {
          emitFallback(baseSeries);
        }
      }
      // 罗马音 + 日文假名双语拼接文件名（如 `Yowamushi Pedal 弱虫ペダル`、`Himouto! Umaru chan 干物妹! うまるちゃん`、`Yuyushiki ゆゆ式`）：
      // 仅当日文段含平/片假名时拆出拉丁段与日文段，绝不误拆 `Code Geass 亡国的阿基德` 这类单语中英混合正式片名。
      final bilingual = RegExp(
        r'^([A-Za-z0-9][A-Za-z0-9\s!\-’\x27.,]{3,}?)\s+([\u3040-\u9fff][^\r\n]{1,})$',
      ).firstMatch(raw.trim());
      if (bilingual != null &&
          RegExp(r'[\u3040-\u30ff]').hasMatch(bilingual.group(2)!)) {
        final latinSeg = bilingual.group(1)!.trim();
        final cjkSeg = bilingual
            .group(2)!
            .split(
              RegExp(
                r'\s+(?:ova\d*|oads?|oab|sp\d*|special|「|『)',
                caseSensitive: false,
              ),
            )
            .first
            .trim();
        if (latinSeg.length >= 4) {
          emitFallback(latinSeg);
        }
        if (cjkSeg.length >= 2 &&
            (RegExp(r'[\u4e00-\u9fff]').hasMatch(cjkSeg) ||
                cjkSeg.length >= 5)) {
          emitFallback(cjkSeg);
        }
      }
      final withoutInfixOva = raw
          .replaceAll(
            RegExp(r'(?<=\s)(?:OVA|OAD|OAV)(?=\s+\S)', caseSensitive: false),
            ' ',
          )
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      if (withoutInfixOva != raw && withoutInfixOva.length >= 4) {
        addSingle(withoutInfixOva);
      }
      for (final rv in _romanNumeralVariants(raw)) {
        addSingle(rv);
      }
      for (final arc in legacy.WorkMatcher.expandRomajiArcQueries(raw)) {
        addSingle(arc);
      }
    }

    // 跨源救回：使用 Bangumi 官方中日文名补搜本地同义译名在 TMDB 零命中的条目。
    if (bangumiCandidate != null) {
      final bgm = bangumiCandidate.subject;
      if (bgm.displayTitle.isNotEmpty) {
        add(bgm.displayTitle);
        final strippedRemasterBgm = _stripRemasterTag(bgm.displayTitle);
        if (strippedRemasterBgm != bgm.displayTitle &&
            strippedRemasterBgm.isNotEmpty) {
          add(strippedRemasterBgm);
        }
      }
      if (bgm.name.trim().isNotEmpty) {
        add(bgm.name.trim());
      }
      for (final a in bgm.aliases.take(2)) {
        add(a);
      }
      final base = bgm.displayTitle
          .split(RegExp(r'\s+|[:：～~—\-/·・･]+'))
          .first
          .trim();
      if (base.isNotEmpty && _isSafeFirstToken(base, bgm.displayTitle)) {
        add(base, expandVariants: false);
      }
    }

    final hints = inv.titleHints.isNotEmpty
        ? inv.titleHints
        : [folder.cleanTitle];
    // 当首条一致文件名主干与目录名明显不同（常见于不规范目录名如 `阿伟推荐/` 内含规范番剧文件）时，
    // 将一致文件名主干紧随目录主名置入第 2 检索位，确保首波（前 3 词）必然同时召回文件主干对应作品。
    final divergentPrimaryFile =
        inv.fileHints.isNotEmpty &&
        legacy.WorkMatcher.similarity(
              DirectoryAnalyzer.normalize(hints.first),
              DirectoryAnalyzer.normalize(inv.fileHints.first),
            ) <
            0.50;
    for (var i = 0; i < hints.length; i++) {
      final hint = hints[i];
      add(hint, expandVariants: i == 0, allowGroupHomonym: i == 0);
      if (i == 0 && divergentPrimaryFile) {
        add(
          inv.fileHints.first,
          expandVariants: true,
          allowGroupHomonym: true,
          // 仅当目录主提示单一（典型于乱目录名，如 `阿伟推荐的神作2`）时立即展开双语/去后缀兜底词进第一波；
          // 规范中文目录（如 `飙速宅男 OAD`）已含去后缀主名 `hints[1]`，避免挤占第一波槽位。
          immediateSpecialFallback: hints.length == 1,
        );
      }
      final strippedPart = WorkSeason.withoutPart(hint);
      if (strippedPart != hint) add(strippedPart, expandVariants: false);
      final strippedMultiSeason = hint
          .replaceFirst(
            RegExp(
              r'\s+s\d{1,2}(?:\s*[+&~～\-]\s*(?:s?\d{1,2}|ova|oad|sp|movie))+\s*$',
              caseSensitive: false,
            ),
            '',
          )
          .trim();
      if (strippedMultiSeason != hint && strippedMultiSeason.isNotEmpty) {
        add(strippedMultiSeason, expandVariants: false);
      }
      final strippedRemaster = _stripRemasterTag(hint);
      if (strippedRemaster != hint && strippedRemaster.isNotEmpty) {
        add(strippedRemaster, expandVariants: false);
      }
    }

    for (final eq in [...folder.extraSearchQueries, ...extraQueries]) {
      add(eq, expandVariants: true);
    }

    if (RegExp(r'\balternative\b', caseSensitive: false).hasMatch(inv.title) &&
        !RegExp(
          r'\balternative\s+(?:one|two)\b',
          caseSensitive: false,
        ).hasMatch(inv.titleHints.join(' ')) &&
        (inv.episodeCount <= 2 || inv.featureCount <= 2)) {
      add('${inv.title} ONE');
      add('${inv.title} TWO');
    }

    for (var i = 0; i < inv.fileHints.length; i++) {
      final fh = inv.fileHints[i];
      add(fh, allowGroupHomonym: i == 0);
      final strippedRemaster = _stripRemasterTag(fh);
      if (strippedRemaster != fh && strippedRemaster.isNotEmpty) {
        add(strippedRemaster, expandVariants: false);
      }
    }

    // 父级系列目录提示（如 `动画-多作品/XX 作品集/XX 篇章名` -> `XX`）。
    final physPath = (folder.physicalRootFolder ?? folder.folderRelativePath)
        .replaceAll('\\', '/');
    final parts = physPath
        .split('/')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    if (parts.length >= 2) {
      for (
        var idx = parts.length - 2;
        idx >= 0 && idx >= parts.length - 3;
        idx--
      ) {
        final parent = parts[idx]
            .replaceFirst(
              RegExp(
                r'\s*(?:系列|作品集|合集|全集|Series|Collection)$',
                caseSensitive: false,
              ),
              '',
            )
            .trim();
        if (parent.isNotEmpty &&
            !_categoryFolderPattern.hasMatch(parent) &&
            !_genericSeasonName.hasMatch(parent)) {
          add(parent, expandVariants: false);
        }
      }
    }

    // 主系列词干与尾部副标题剥离（如 `系列名：副标题` / `前辈 主标题`）。
    for (final base in [...inv.titleHints.take(2), ...inv.fileHints.take(2)]) {
      final beforePunct = base.split(RegExp(r'[:：～~—/·・･]+')).first.trim();
      if (beforePunct.isNotEmpty &&
          beforePunct != base &&
          (_hasCjk(beforePunct)
              ? beforePunct.length >= 2
              : beforePunct.length >= 4)) {
        add(beforePunct, expandVariants: false);
      }
      final tokens = base
          .split(RegExp(r'\s+|[:：～~—\-/·・･]+'))
          .where((t) => t.isNotEmpty)
          .toList();
      if (tokens.length >= 2) {
        final first = tokens.first.trim();
        if (first != base && _isSafeFirstToken(first, base)) {
          add(first, expandVariants: false);
        }
        final tail = tokens.skip(1).join(' ').trim();
        if (tail != base &&
            first.length <= 6 &&
            (_hasCjk(tail) ? tail.length >= 2 : tail.length >= 4)) {
          add(tail, expandVariants: false);
        }
      }
    }

    for (final fb in deferredFallbacks) {
      addSingle(fb);
    }

    // 极短真片名兜底（如 `W'Z`、`86`、`K`、`C`）：避免全部候选词被长度门限滤空导致零检索。
    if (out.isEmpty) {
      final rawFallback = (inv.title.isNotEmpty ? inv.title : folder.cleanTitle)
          .replaceAll(RegExp(r'\{[^}]*\}'), ' ')
          .replaceAll(RegExp(r'\(\s*(?:19|20)\d{2}\s*\)'), ' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      final cleanFallback = SearchQuerySanitizer.sanitize(rawFallback);
      final chosen = cleanFallback.isNotEmpty ? cleanFallback : rawFallback;
      if (chosen.isNotEmpty && !_genericQueryWord.hasMatch(chosen)) {
        out.add(chosen);
      }
    }

    return out.take(10).toList(growable: false);
  }

  /// 提取高置信度目录括号年份提示（用于 TMDB 首波精确年份检索）；
  /// 当目录分析器已主动清空通用乱目录伪年份时不再从路径中强行复活该伪年份；
  /// 当目录名与文件主干显著偏离且文件自身携带一致发行年份时，优先采用文件年份。
  static int? extractSearchYear(GroupedWorkFolder folder) {
    final inv = folder.inventory;
    if (inv != null && inv.year == null) {
      return null;
    }
    if (inv != null && inv.fileYear != null && inv.fileHints.isNotEmpty) {
      final sim = legacy.WorkMatcher.similarity(
        DirectoryAnalyzer.normalize(inv.title),
        DirectoryAnalyzer.normalize(inv.fileHints.first),
      );
      if (sim < 0.45) {
        return inv.fileYear;
      }
    }
    final physPath = (folder.physicalRootFolder ?? folder.folderRelativePath)
        .replaceAll('\\', '/');
    final segments = physPath
        .split('/')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    for (var i = segments.length - 1; i >= 0; i--) {
      final m = _parenYearPattern.firstMatch(segments[i]);
      if (m != null) return int.tryParse(m.group(1)!);
    }
    return folder.year;
  }

  /// 对检索到的 Bangumi 候选集执行无损 `WorkMatcher.bangumi` 打分，返回分级结果与最佳候选明细。
  static ({
    legacy.MatchTier tier,
    ScoredBangumiCandidate? best,
    List<ScoredBangumiCandidate> topCandidates,
    legacy.MatchResult rawResult,
  })
  evaluateBangumiMatch(
    GroupedWorkFolder folder,
    List<BangumiSubjectCandidate> candidates,
  ) {
    if (candidates.isEmpty) {
      return (
        tier: legacy.MatchTier.none,
        best: null,
        topCandidates: const [],
        rawResult: legacy.MatchResult.empty,
      );
    }
    final inv = _effectiveInventory(folder);
    final byId = <int, BangumiSubjectCandidate>{
      for (final c in candidates) c.id: c,
    };
    final result = legacy.WorkMatcher.bangumi(
      inv,
      [for (final c in candidates) c.toMatchCandidate()],
      ignoreBangumiMarker: folder.ignoreExplicitTmdb,
    );
    final scored = <ScoredBangumiCandidate>[];
    for (final s in result.ranking) {
      final subject = byId[s.candidate.id];
      if (subject == null) continue;
      scored.add(
        ScoredBangumiCandidate(
          subject: subject,
          score: s.score,
          reasons: List.unmodifiable(s.reasons),
          siblingIds: s.candidate.id == result.candidate?.id
              ? List.unmodifiable(result.siblingIds)
              : const [],
        ),
      );
    }
    final best = result.candidate == null
        ? null
        : scored.where((s) => s.subject.id == result.candidate!.id).firstOrNull;
    return (
      tier: result.tier,
      best: best,
      topCandidates: scored.take(5).toList(growable: false),
      rawResult: result,
    );
  }

  /// 使用无损 `WorkMatcher.tmdb` 对检索候选执行确定性打分、季级消歧与分层决策（支持 Bangumi 双引擎联评与交叉互保）。
  static MatchDecision evaluateMatch(
    GroupedWorkFolder folder,
    List<TmdbWorkDetail> candidates, {
    List<BangumiSubjectCandidate> bangumiCandidates = const [],
    BangumiTmdbIndex? mappingIndex,
  }) {
    final inv = _effectiveInventory(folder);
    final bgmEval = evaluateBangumiMatch(folder, bangumiCandidates);

    if (candidates.isEmpty) {
      if (bgmEval.best != null && bgmEval.tier != legacy.MatchTier.none) {
        return MatchDecision(
          level: bgmEval.tier == legacy.MatchTier.high
              ? MatchLevel.autoBind
              : MatchLevel.reviewRequired,
          topCandidates: const [],
          bestBangumi: bgmEval.best,
          topBangumiCandidates: bgmEval.topCandidates,
          primaryReason: bgmEval.tier == legacy.MatchTier.high
              ? 'bangumi_only_high'
              : 'bangumi_only_review',
          reviewReason: bgmEval.tier == legacy.MatchTier.high
              ? null
              : '仅命中 Bangumi 候选条目，请核对或补充 TMDB 绑定',
        );
      }
      return MatchDecision(
        level: MatchLevel.unmatched,
        topCandidates: const [],
        bestBangumi: bgmEval.best,
        topBangumiCandidates: bgmEval.topCandidates,
        primaryReason: 'no_candidates',
        reviewReason: inv.shape == WorkShape.anthology
            ? '检测到混合多作品目录，需手动拆分或绑定'
            : '未搜索到匹配词条',
      );
    }

    final byKey = <String, TmdbWorkDetail>{
      for (final c in candidates) '${c.mediaType.name}:${c.tmdbId}': c,
    };
    final matchCandidates = [for (final c in candidates) _toMatchCandidate(c)];
    // Bangumi 高置信条目经离线映射表命中的 TMDB 目标（仅限已在候选池中的），作为跨源加权与保守季参考依据。
    // 零评分人数条目仅在具备动画分类与封面且候选池无同类型同年份已评分竞争正主时允许参与（如冷门独立 OAD）。
    bool mappedCandidateEligible(TmdbWorkDetail d) {
      if (d.voteCount != 0) return true;
      final hasPoster = d.posterPath?.trim().isNotEmpty ?? false;
      if (!d.genreIds.contains(16) || !hasPoster) return false;
      final hasRatedPeer = byKey.values.any(
        (other) =>
            !identical(other, d) &&
            other.mediaType == d.mediaType &&
            (other.voteCount ?? 0) > 0 &&
            other.genreIds.contains(16) &&
            (d.year == null ||
                other.year == null ||
                (d.year! - other.year!).abs() <= 1),
      );
      return !hasRatedPeer;
    }

    final eligibleMappedKeys = {
      for (final e in byKey.entries)
        if (mappedCandidateEligible(e.value)) e.key,
    };
    var mappedTargets = bgmEval.tier == legacy.MatchTier.high
        ? bangumiMappedTmdbTargets(
            bgmEval.best?.subject,
            eligibleMappedKeys,
            mappingIndex: mappingIndex,
          )
        : const <BangumiTmdbTarget>[];
    // 中置信 Bangumi 特别篇/OVA/独立剧场版条目（含 1~2 集电视特别篇或单文件独立剧场版）
    // 若经离线映射精确指向候选池内已有母剧的 Season 0 动画条目或独立动画电影，则借该映射补齐跨源锚定，避免漏绑待复核。
    if (mappedTargets.isEmpty &&
        bgmEval.tier == legacy.MatchTier.medium &&
        bgmEval.best != null) {
      final bgmScored = bgmEval.best!;
      final bgmTitlePts = bgmScored.reasons
          .where((r) => r.endsWith(' title'))
          .map((r) => double.tryParse(r.split(' ').first) ?? 0.0)
          .fold<double>(0.0, (m, v) => v > m ? v : m);
      final bgmTitleTrustworthy = bgmTitlePts >= 32.0;
      final bgmSubj = bgmScored.subject;
      final bgmPlatform = bgmSubj.platform?.trim().toUpperCase() ?? '';
      final bgmEps = bgmSubj.totalEpisodes ?? 0;
      final isBgmMovie = bgmPlatform == '剧场版' || bgmPlatform == 'MOVIE';
      final isSpecialLocalOrBgm =
          bgmTitleTrustworthy &&
          (inv.season == 0 ||
              DirectoryAnalyzer.isOvaText(inv.title) ||
              inv.fileHints.any(DirectoryAnalyzer.isOvaText) ||
              DirectoryAnalyzer.isOva(inv) ||
              bgmPlatform == 'OVA' ||
              bgmPlatform == 'OAD' ||
              (inv.shape == WorkShape.feature &&
                  (isBgmMovie || (bgmEps > 0 && bgmEps <= 2))));
      final isExactSpecialOrOna =
          bgmScored.score >= 45.0 &&
          bgmTitlePts >= 36.0 &&
          inv.parentFolderTmdbId == null &&
          (bgmPlatform == 'WEB' ||
              bgmPlatform == 'OVA' ||
              bgmPlatform == 'OAD' ||
              bgmPlatform == 'ONA') &&
          inv.shape == WorkShape.series &&
          inv.episodeCount > 0 &&
          inv.episodeCount <= 12 &&
          bgmEps == inv.episodeCount;
      final isMultiPartMovie =
          bgmTitleTrustworthy &&
          isBgmMovie &&
          inv.shape == WorkShape.series &&
          inv.episodeCount > 0 &&
          inv.episodeCount <= 4 &&
          bgmEps == inv.episodeCount;
      final seqMatch = RegExp(r'(?<!\d)([2-9])(?!\d)').firstMatch(inv.title);
      final localSeqDigit = seqMatch?.group(1);
      final isSequelCorroboratedTv =
          localSeqDigit != null &&
          bgmSubj.displayTitle.contains(localSeqDigit) &&
          inv.shape == WorkShape.series;
      if (isSpecialLocalOrBgm ||
          isExactSpecialOrOna ||
          isMultiPartMovie ||
          isSequelCorroboratedTv) {
        mappedTargets = bangumiMappedTmdbTargets(
          bgmSubj,
          eligibleMappedKeys,
          mappingIndex: mappingIndex,
        )
            .where((t) {
              final detail = byKey[t.key];
              if (detail == null || !detail.genreIds.contains(16)) return false;
              if ((isSpecialLocalOrBgm || isExactSpecialOrOna) &&
                  t.type == TmdbMediaType.tv &&
                  t.season == 0) {
                if (isExactSpecialOrOna &&
                    !detail.seasons.any(
                      (s) =>
                          s.seasonNumber == 0 &&
                          s.episodeCount >= inv.episodeCount,
                    )) {
                  return false;
                }
                return true;
              }
              if ((isSpecialLocalOrBgm || isMultiPartMovie) &&
                  t.type == TmdbMediaType.movie &&
                  (isMultiPartMovie ||
                      (inv.shape == WorkShape.feature &&
                          (isBgmMovie ||
                              bgmPlatform == 'OVA' ||
                              bgmPlatform == 'OAD')))) {
                return true;
              }
              if (isSequelCorroboratedTv &&
                  t.type == TmdbMediaType.tv &&
                  detail.title.contains(localSeqDigit)) {
                return true;
              }
              return false;
            })
            .toList(growable: false);
      }
    }
    // 强跨源唯一动画候选互证：当 TMDB 候选池仅含 1 个动画 TV 候选、本地多集片名（>= 2 词）
    // 为其别名的词边界前缀、Bangumi 首选显著领先次名（>= 20 分）且双库集数完全一致、
    // 且离线映射表精确指向该唯一 TMDB 条目与季号时，采纳该跨源映射锚定（如简写压制名）。
    if (mappedTargets.isEmpty &&
        inv.shape == WorkShape.series &&
        inv.episodeCount >= 6 &&
        bgmEval.topCandidates.isNotEmpty) {
      final animTvs = byKey.values
          .where(
            (d) =>
                d.mediaType == TmdbMediaType.tv &&
                d.genreIds.contains(16) &&
                (d.voteCount ?? 1) > 0,
          )
          .toList(growable: false);
      final bgmTop = bgmEval.topCandidates.first;
      final bgmSecondScore = bgmEval.topCandidates.length >= 2
          ? bgmEval.topCandidates[1].score
          : 0.0;
      if (animTvs.length == 1 &&
          bgmTop.score >= 34.0 &&
          bgmTop.score - bgmSecondScore >= 20.0 &&
          bgmTop.subject.totalEpisodes == inv.episodeCount) {
        final soleTv = animTvs.single;
        final soleKey = _detailKey(soleTv);
        final localPrefixSeeds = <String>[
          inv.title,
          ...inv.fileHints.take(1),
        ]
            .map(
              (s) => s
                  .toLowerCase()
                  .replaceAll(RegExp(r'[^a-z0-9\u3040-\u9fff]+'), ' ')
                  .trim(),
            )
            .where((s) => s.length >= 6 && s.split(' ').length >= 2)
            .toList(growable: false);
        final candNormSpaced = <String>[
          soleTv.title,
          if (soleTv.originalTitle != null) soleTv.originalTitle!,
          ...soleTv.aliases,
        ]
            .map(
              (s) => s
                  .toLowerCase()
                  .replaceAll(RegExp(r'[^a-z0-9\u3040-\u9fff]+'), ' ')
                  .trim(),
            )
            .where((s) => s.isNotEmpty)
            .toList(growable: false);
        final isWordPrefix = localPrefixSeeds.any(
          (lp) => candNormSpaced.any(
            (cn) =>
                cn == lp ||
                cn.startsWith('$lp ') ||
                (cn.length >= 10 &&
                    cn.split(' ').length >= 2 &&
                    lp.endsWith(' $cn')),
          ),
        );
        if (isWordPrefix) {
          final corroborated = bangumiMappedTmdbTargets(
            bgmTop.subject,
            eligibleMappedKeys,
            mappingIndex: mappingIndex,
          ).where((t) {
            if (t.key != soleKey || t.season == null || t.season! <= 0) {
              return false;
            }
            return soleTv.seasons.any(
              (s) =>
                  s.seasonNumber == t.season &&
                  s.episodeCount == inv.episodeCount,
            );
          }).toList(growable: false);
          if (corroborated.isNotEmpty) {
            mappedTargets = corroborated;
          }
        }
      }
    }
    final mappedKeys = {
      for (final t in mappedTargets) t.key,
    }.toList(growable: false);
    final isMultiSeasonBundle = DirectoryAnalyzer.isMultiSeasonTitle(inv.title);
    var primaryMapped = mappedTargets.firstOrNull;
    // 当本地目录或 Bangumi 明确指向剧场版、且候选池已有同名独立 Movie 条目时，
    // 不让映射表里遗留的母剧 TV 映射加权（+20）反压真正的独立剧场版。
    final expectsMovie =
        folder.isMovieHint ||
        (bgmEval.best?.subject.platform?.trim() ?? '') == '剧场版';
    if (expectsMovie &&
        primaryMapped != null &&
        primaryMapped.type == TmdbMediaType.tv) {
      final hasMatchingStandaloneMovie = byKey.values.any((c) {
        if (c.mediaType != TmdbMediaType.movie || (c.voteCount ?? 1) == 0) {
          return false;
        }
        final movieNames = [
          c.title,
          if (c.originalTitle != null) c.originalTitle!,
          ...c.aliases,
        ];
        final localRef = [
          inv.title,
          if (bgmEval.best != null) bgmEval.best!.subject.displayTitle,
          if (bgmEval.best != null) bgmEval.best!.subject.name,
        ];
        return movieNames.any((mn) {
          final mNorm = legacy.WorkMatcher.canonTitleKey(mn);
          if (mNorm.length < 4) return false;
          return localRef.any((lr) {
            final lNorm = legacy.WorkMatcher.canonTitleKey(lr);
            return lNorm.length >= 4 &&
                legacy.WorkMatcher.similarity(lNorm, mNorm) >= 0.80;
          });
        });
      });
      if (hasMatchingStandaloneMovie) {
        primaryMapped = null;
      }
    }
    final mappedSeasonHint = isMultiSeasonBundle ? null : primaryMapped?.season;

    final result = legacy.WorkMatcher.tmdb(
      inv,
      matchCandidates,
      bangumi: bgmEval.rawResult,
      mappedTarget: primaryMapped == null
          ? null
          : (key: primaryMapped.key, season: mappedSeasonHint),
      ignoreTmdbMarker: folder.ignoreExplicitTmdb,
    );

    final scoredList = <ScoredTmdbCandidate>[];
    for (final s in result.ranking) {
      final detail = byKey['${s.candidate.type}:${s.candidate.id}'];
      if (detail == null) continue;
      scoredList.add(
        ScoredTmdbCandidate(
          detail: detail,
          score: s.score,
          reasons: _normalizeReasonsToCodes(s.reasons),
          matchedSeason: s.season,
        ),
      );
    }

    if (scoredList.isEmpty) {
      return MatchDecision(
        level: MatchLevel.unmatched,
        topCandidates: const [],
        bestBangumi: bgmEval.best,
        topBangumiCandidates: bgmEval.topCandidates,
        primaryReason: 'no_candidates',
        reviewReason: '未搜索到匹配词条',
      );
    }

    final top5 = scoredList.take(5).toList(growable: false);
    var bestTmdb = result.candidate == null ? top5.first : top5.first;
    if (result.candidate != null) {
      bestTmdb =
          scoredList
              .where(
                (e) =>
                    e.detail.tmdbId == result.candidate!.id &&
                    e.detail.mediaType.name == result.candidate!.type,
              )
              .firstOrNull ??
          top5.first;
    }
    var tmdbTier = result.tier;
    var matchedSeason = result.season ?? bestTmdb.matchedSeason;
    var effectiveBestTmdb = result.tier == legacy.MatchTier.none
        ? null
        : bestTmdb;
    var effectiveBestBgm = bgmEval.tier == legacy.MatchTier.none
        ? null
        : bgmEval.best;

    // 防跨库误拼：校验年份、动画分类 (genre 16) 与基础标题一致性，杜绝不相关条目嫁接污染。
    if (effectiveBestTmdb != null && effectiveBestBgm != null) {
      final compatible = _providersCompatible(
        effectiveBestTmdb.detail,
        matchedSeason,
        effectiveBestBgm.subject,
      );
      final nonAnimTmdb =
          effectiveBestTmdb.detail.genreIds.isNotEmpty &&
          !effectiveBestTmdb.detail.genreIds.contains(16);
      if (!compatible &&
          (bgmEval.tier == legacy.MatchTier.high || nonAnimTmdb)) {
        effectiveBestTmdb = null;
        tmdbTier = legacy.MatchTier.none;
        matchedSeason = null;
      } else if (tmdbTier == legacy.MatchTier.high &&
          bgmEval.tier == legacy.MatchTier.medium &&
          !compatible) {
        effectiveBestBgm = null;
      }
    }

    // Bangumi 高置信时以 Bangumi 条目锚定 TMDB：候选任一名称与 Bangumi 中/日文名或别名归一化后完全一致
    // 且年份吻合即视为同一作品。适用于 TMDB 因分差过小或跨源校验被整体放弃，以及当前优胜条目
    // 只是把单独上架的特别篇归入母剧第 0 季、而另有名称完全一致的专属条目两种情形；
    // 当前优胜条目已对上母剧正片季时不覆盖（续季常另有同名的低质量重复条目）。
    var anchoredByBangumi = false;
    if (effectiveBestBgm != null && bgmEval.tier == legacy.MatchTier.high) {
      final bgmSubject = effectiveBestBgm.subject;
      final current = effectiveBestTmdb;
      final anchored = _bangumiAnchoredTmdb(scoredList, bgmSubject, mappedKeys);
      if (anchored != null &&
          (current == null ||
              (!identical(anchored, current) &&
                  current.detail.mediaType == TmdbMediaType.tv &&
                  matchedSeason == 0 &&
                  !mappedKeys.contains(_detailKey(current.detail)) &&
                  !_tmdbNamesMatchBangumi(current.detail, bgmSubject)))) {
        effectiveBestTmdb = anchored;
        tmdbTier = legacy.MatchTier.medium;
        matchedSeason = anchored.matchedSeason;
        anchoredByBangumi = true;
      } else if (current == null) {
        final parent = _bangumiParentSeriesTmdb(scoredList, bgmSubject, inv);
        if (parent != null) {
          effectiveBestTmdb = parent;
          tmdbTier = legacy.MatchTier.medium;
          matchedSeason = parent.matchedSeason;
          anchoredByBangumi = true;
        }
      }
    }

    // 当 WorkMatcher 未能定季且优胜 TMDB 剧集恰好命中映射表季号、且本地集数不超出该季容量时，保守采纳映射季号。
    if (effectiveBestTmdb != null &&
        matchedSeason == null &&
        !isMultiSeasonBundle &&
        effectiveBestTmdb.detail.mediaType == TmdbMediaType.tv) {
      final winnerKey = _detailKey(effectiveBestTmdb.detail);
      final targetSeason = mappedTargets
          .where((t) => t.key == winnerKey && t.season != null)
          .firstOrNull
          ?.season;
      if (targetSeason != null) {
        final seasonInfo = effectiveBestTmdb.detail.seasons
            .where((s) => s.seasonNumber == targetSeason)
            .firstOrNull;
        if (seasonInfo != null &&
            (inv.episodeCount == 0 ||
                seasonInfo.episodeCount == 0 ||
                inv.episodeCount <= seasonInfo.episodeCount + 2)) {
          matchedSeason = targetSeason;
        }
      }
    }

    if (effectiveBestTmdb == null && effectiveBestBgm != null) {
      final bgmHigh = bgmEval.tier == legacy.MatchTier.high;
      return MatchDecision(
        level: bgmHigh ? MatchLevel.autoBind : MatchLevel.reviewRequired,
        best: null,
        topCandidates: top5,
        bestBangumi: effectiveBestBgm,
        topBangumiCandidates: bgmEval.topCandidates,
        primaryReason: bgmHigh ? 'bangumi_high_confidence' : 'bangumi_review',
        reviewReason: bgmHigh ? null : '仅命中 Bangumi 候选，TMDB 候选分歧较大请复核',
      );
    }

    // 双源互证：TMDB 中置信且标题、年份吻合、无硬冲突，Bangumi 虽因同系列条目（TV/OVA、各季）分差过小
    // 未达高置信，但其首选与 TMDB 优胜条目跨源兼容时，两个独立数据源一致即视为高置信。
    // Bangumi 侧仍不绑定，避免在分差过小的同系列条目间误选。
    final bgmTop = bgmEval.topCandidates.firstOrNull;
    final crossConfirmed =
        tmdbTier == legacy.MatchTier.medium &&
        effectiveBestTmdb != null &&
        bgmEval.tier != legacy.MatchTier.high &&
        bgmTop != null &&
        bgmTop.score >= _crossConfirmBangumiScore &&
        _hasStrongTitleAndYear(effectiveBestTmdb.reasons) &&
        _providersCompatible(
          effectiveBestTmdb.detail,
          matchedSeason,
          bgmTop.subject,
        );

    final high =
        tmdbTier == legacy.MatchTier.high ||
        crossConfirmed ||
        (effectiveBestBgm != null && bgmEval.tier == legacy.MatchTier.high);

    if (tmdbTier == legacy.MatchTier.none && effectiveBestBgm == null) {
      return MatchDecision(
        level: MatchLevel.unmatched,
        best: bestTmdb,
        topCandidates: top5,
        bestBangumi: bgmEval.best,
        topBangumiCandidates: bgmEval.topCandidates,
        matchedSeason: matchedSeason,
        primaryReason: 'no_match',
        reviewReason: inv.shape == WorkShape.anthology
            ? '检测到多作品混合目录，请手动绑定'
            : '未匹配到可靠词条，请手动指定',
      );
    }

    if (high) {
      return MatchDecision(
        level: MatchLevel.autoBind,
        best: effectiveBestTmdb ?? top5.first,
        topCandidates: top5,
        bestBangumi: effectiveBestBgm,
        topBangumiCandidates: bgmEval.topCandidates,
        matchedSeason: matchedSeason,
        primaryReason: anchoredByBangumi
            ? 'bangumi_anchored'
            : (crossConfirmed ? 'cross_source_confirmed' : 'high_confidence'),
      );
    }

    final primary = _derivePrimaryReviewCode(top5);
    return MatchDecision(
      level: MatchLevel.reviewRequired,
      best: effectiveBestTmdb ?? top5.first,
      topCandidates: top5,
      bestBangumi: effectiveBestBgm,
      topBangumiCandidates: bgmEval.topCandidates,
      matchedSeason: matchedSeason,
      primaryReason: primary,
      reviewReason: _buildChineseReviewSummary(
        primaryCode: primary,
        reasons: (effectiveBestTmdb ?? top5.first).reasons,
      ),
    );
  }

  /// 对未抓取完整 details 的粗搜条目做轻量初步打分排序（用于多波次备选筛选 Top N）。
  static double scoreSearchHitPreview(
    GroupedWorkFolder folder,
    TmdbSearchResult hit,
  ) {
    final inv = _effectiveInventory(folder);
    final cand = legacy.MatchCandidate(
      provider: 'tmdb',
      id: hit.tmdbId,
      type: hit.mediaType.name,
      title: hit.title,
      year: hit.year,
      aliases: [
        if (hit.originalTitle != null && hit.originalTitle!.trim().isNotEmpty)
          hit.originalTitle!.trim(),
      ],
    );
    return legacy.WorkMatcher.tmdb(
          inv,
          [cand],
          ignoreTmdbMarker: folder.ignoreExplicitTmdb,
        ).ranking.firstOrNull?.score ??
        0;
  }

  /// 显式 `{tmdb-N}` 未标注类型而剧集与电影两侧同号条目都存在时（两类 ID 空间相互重叠），
  /// 忽略目录 ID 标记、按标题/年份/正片形态为两侧打分择优；分数相同时回退目录的电影/剧集提示。
  static TmdbWorkDetail chooseExplicitTypeCandidate(
    GroupedWorkFolder folder, {
    required TmdbWorkDetail tv,
    required TmdbWorkDetail movie,
  }) {
    final ranking = legacy.WorkMatcher.tmdb(_effectiveInventory(folder), [
      _toMatchCandidate(tv),
      _toMatchCandidate(movie),
    ], ignoreTmdbMarker: true).ranking;
    double scoreOf(TmdbWorkDetail detail) =>
        ranking
            .where(
              (r) =>
                  r.candidate.id == detail.tmdbId &&
                  r.candidate.type == detail.mediaType.name,
            )
            .firstOrNull
            ?.score
            .toDouble() ??
        double.negativeInfinity;
    final tvScore = scoreOf(tv);
    final movieScore = scoreOf(movie);
    if (tvScore == movieScore) return folder.isMovieHint ? movie : tv;
    return tvScore > movieScore ? tv : movie;
  }

  /// 当 `WorkMatcher` 未显式定季（如单文件显式 `{tmdb-N}` 绑定）时，回退使用 `WorkSeason.resolve` 定季。
  static int? fallbackResolveSeason({
    required GroupedWorkFolder folder,
    required TmdbWorkDetail detail,
  }) {
    if (detail.mediaType != TmdbMediaType.tv || detail.seasons.isEmpty) {
      return null;
    }
    final rawSeasons = [
      for (final s in detail.seasons)
        <String, dynamic>{
          'season_number': s.seasonNumber,
          'name': s.name,
          'air_date': s.airDate,
          'poster_path': s.posterPath,
        },
    ];
    return WorkSeason.resolve(<String, Object?>{
      'title': folder.folderName,
      'folder': folder.folderRelativePath,
      'year': folder.year,
      'season': folder.seasonHint,
    }, rawSeasons);
  }

  /// 为绑定作品解析季级身份（季专属标题、首播年份、季海报、Bangumi 封面、系列回退海报与简介）。
  ///
  /// 严格对齐 `feat/scrape-pipeline` 规则：
  /// - 第 1 季保留作品主标题，不强加 `' 第1季'`；
  /// - 续季（如 `Wake Up, Girls! 新章`）优先使用 Bangumi 季名或 TMDB 非泛化季名或本地续作副标题；
  /// - 单季独播年份与 Bangumi 年份协同确定；
  /// - 合并多季于 TMDB 单季的派生子作品（如 `OVA`/Split-cour/Season 0/重制版）优先使用 Bangumi 独立封面，
  ///   同时始终返回 `bangumiPosterPath` 与 TMDB 封面以便用户在详情页自由切换。
  static ({
    String title,
    int? year,
    String? posterPath,
    String? posterFallback,
    String? bangumiPosterPath,
    String? overview,
  })
  resolveSeasonPresentation({
    required GroupedWorkFolder folder,
    TmdbWorkDetail? detail,
    int? matchedSeason,
    TmdbSeasonDetail? seasonDetail,
    ScoredBangumiCandidate? bangumiCandidate,
  }) {
    final bgmSubject = bangumiCandidate?.subject;
    final bgmPoster = _nonEmpty(bgmSubject?.posterUrl);
    final bgmOverview = _nonEmpty(bgmSubject?.summary);

    if (detail == null) {
      final inv = _effectiveInventory(folder);
      final bgmTitle = _nonEmpty(bgmSubject?.displayTitle);
      return (
        title:
            bgmTitle ?? (inv.title.isNotEmpty ? inv.title : folder.folderName),
        year: bgmSubject?.year ?? folder.year,
        posterPath: bgmPoster,
        posterFallback: null,
        bangumiPosterPath: bgmPoster,
        overview: bgmOverview,
      );
    }

    final summary = matchedSeason == null
        ? null
        : detail.seasons
              .where((s) => s.seasonNumber == matchedSeason)
              .firstOrNull;
    final seasonPoster =
        _nonEmpty(seasonDetail?.posterPath) ?? _nonEmpty(summary?.posterPath);
    final tmdbPoster = seasonPoster ?? _nonEmpty(detail.posterPath);
    final posterFallback = seasonPoster != null
        ? _nonEmpty(detail.posterPath)
        : null;

    final tmdbCandidate = _toMatchCandidate(detail);
    final bgmMatchCand = bgmSubject?.toMatchCandidate();
    final inv = _effectiveInventory(folder);

    final specificSubWork =
        bgmMatchCand != null &&
        _isSpecificSubWork(
          inventory: inv,
          tmdbPick: tmdbCandidate,
          resolvedSeason: matchedSeason,
          bgmPick: bgmMatchCand,
        );
    final bangumiSeasonIdentity = _useBangumiSeasonIdentity(
      inventory: inv,
      tmdbPick: tmdbCandidate,
      bgmPick: bgmMatchCand,
    );
    final regularCount = detail.seasons.where((s) => s.seasonNumber > 0).length;
    final mergedSequelSubWork =
        specificSubWork &&
        regularCount <= 1 &&
        detail.mediaType == TmdbMediaType.tv;
    final lacksDistinctSeasonPoster =
        seasonPoster == null || regularCount <= 1 || matchedSeason == 0;
    final preferBgmPoster =
        bgmPoster != null &&
        (matchedSeason == 0 ||
            bangumiSeasonIdentity ||
            (specificSubWork &&
                detail.mediaType == TmdbMediaType.tv &&
                lacksDistinctSeasonPoster));

    final primaryPoster = preferBgmPoster
        ? bgmPoster
        : (tmdbPoster ?? bgmPoster);
    final effectiveFallback = preferBgmPoster
        ? tmdbPoster
        : (posterFallback ?? bgmPoster);

    final remasterIdentity = _isBangumiRemasterIdentity(
      inv,
      tmdbCandidate,
      bgmMatchCand,
    );
    final seasonYear = matchedSeason == 0
        ? null
        : _parseYear(seasonDetail?.airDate ?? summary?.airDate);
    final resolvedYear = (remasterIdentity || mergedSequelSubWork)
        ? (bgmSubject?.year ?? seasonYear ?? detail.year ?? folder.year)
        : (seasonYear ?? bgmSubject?.year ?? detail.year ?? folder.year);

    final seasonOverview = _nonEmpty(seasonDetail?.overview);
    final tmdbOverview = _nonEmpty(detail.overview);
    String? resolvedOverview;
    if (matchedSeason == 0 && bgmOverview != null) {
      resolvedOverview = bgmOverview;
    } else if (mergedSequelSubWork && bgmOverview != null) {
      resolvedOverview = bgmOverview;
    } else if (seasonOverview != null) {
      resolvedOverview = seasonOverview;
    } else if ((specificSubWork || bangumiSeasonIdentity) &&
        bgmOverview != null) {
      resolvedOverview = bgmOverview;
    } else if (bgmOverview != null &&
        (tmdbOverview == null || !_hasCjk(tmdbOverview))) {
      resolvedOverview = bgmOverview;
    } else {
      resolvedOverview = tmdbOverview ?? bgmOverview;
    }

    final resolvedTitle = _chooseDisplayTitle(
      folder: folder,
      detail: detail,
      matchedSeason: matchedSeason,
      seasonName:
          _nonEmpty(seasonDetail?.name) ?? _nonEmpty(summary?.name) ?? '',
      bangumiCandidate: bangumiCandidate,
      specificSubWork: specificSubWork,
      bangumiSeasonIdentity: bangumiSeasonIdentity,
    );

    return (
      title: resolvedTitle,
      year: resolvedYear,
      posterPath: primaryPoster,
      posterFallback: effectiveFallback,
      bangumiPosterPath: bgmPoster,
      overview: resolvedOverview,
    );
  }

  /// 使用无损 `CloudMediaAssetPresentation.mapSpecialEpisodes` 将特典文件精准映射至 TMDB Season 0。
  ///
  /// 自动保护 `CM`/`PV`/`NCOP`/`NCED`/`Menu`（包括 `OVA CM`）不被误绑为 OVA 正片标题。
  static Map<String, TmdbEpisodeDetail> mapSpecialEpisodes({
    required Work work,
    required List<MediaVariant> extraVariants,
    required List<TmdbEpisodeDetail> seasonZeroEpisodes,
    String? seasonName,
  }) {
    if (extraVariants.isEmpty || seasonZeroEpisodes.isEmpty) return const {};
    final assets = [
      for (final v in extraVariants)
        <String, Object?>{
          'relative_path': v.relativePath,
          'name': v.fileName,
          'category': 'extra',
        },
    ];
    final specials = [
      for (final ep in seasonZeroEpisodes)
        <String, dynamic>{
          'season_number': ep.seasonNumber,
          'episode_number': ep.episodeNumber,
          'name': ep.title,
          'overview': ep.overview,
          'air_date': ep.airDate,
          'still_path': ep.stillPath,
        },
    ];
    final rawMap = CloudMediaAssetPresentation.mapSpecialEpisodes(
      assets: assets,
      specials: specials,
      yearHint: work.year?.toString(),
      workTitle: work.title,
      seasonNumber: work.matchedSeason,
      seasonName: seasonName,
    );
    if (rawMap.isEmpty) return const {};

    final epByNum = <int, TmdbEpisodeDetail>{
      for (final ep in seasonZeroEpisodes) ep.episodeNumber: ep,
    };
    final out = <String, TmdbEpisodeDetail>{};
    for (final entry in rawMap.entries) {
      final numVal = int.tryParse('${entry.value['episode_number']}');
      if (numVal == null) continue;
      final ep = epByNum[numVal];
      if (ep != null) {
        out[entry.key] = ep;
      }
    }
    return out;
  }

  /// 为当前 `GroupedWorkFolder` 计算正片内部未对齐的 `folderSeason -> tmdbSeason` 重映射表。
  static Set<int> referencedSeasonsToFetch(
    GroupedWorkFolder folder, {
    int? matchedSeason,
    TmdbWorkDetail? detail,
  }) {
    final seasons = <int>{};
    if (matchedSeason != null && matchedSeason >= 0) {
      seasons.add(matchedSeason);
    }
    var hasSpecialCandidate = false;
    for (final v in folder.variants) {
      if (v.assetKind != AssetKind.video) continue;
      final slot = folder.slotAssignmentsByPath[v.relativePath];
      if (slot != null) {
        if (slot.category == EpisodeCategory.main && slot.seasonNumber > 0) {
          seasons.add(slot.seasonNumber);
        } else if (slot.category == EpisodeCategory.extra &&
            CloudMediaAssetPresentation.isSpecialMappingCandidate({
              'name': v.fileName,
              'relative_path': v.relativePath,
              'category': 'extra',
            })) {
          hasSpecialCandidate = true;
        }
      }
    }
    if (seasons.isEmpty) {
      seasons.add(folder.seasonHint ?? 1);
    }
    final detailHasS0 =
        detail?.seasons.any((s) => s.seasonNumber == 0 && s.episodeCount > 0) ??
        true;
    if (hasSpecialCandidate && detailHasS0) {
      seasons.add(0);
    }
    return seasons;
  }

  // -------------------- 内部工具实现 --------------------

  static String _chooseDisplayTitle({
    required GroupedWorkFolder folder,
    required TmdbWorkDetail detail,
    required int? matchedSeason,
    required String seasonName,
    ScoredBangumiCandidate? bangumiCandidate,
    bool specificSubWork = false,
    bool bangumiSeasonIdentity = false,
  }) {
    final inv = _effectiveInventory(folder);
    final bgmSubject = bangumiCandidate?.subject;
    final bgmTitle = bgmSubject?.displayTitle.trim() ?? '';
    if (bangumiCandidate != null &&
        bangumiCandidate.siblingIds.length >= 2 &&
        folder.cleanTitle.trim().isNotEmpty) {
      return folder.cleanTitle.trim();
    }
    if (bangumiSeasonIdentity && bgmTitle.isNotEmpty) {
      return bgmTitle;
    }

    var baseTitle = detail.title.trim().isNotEmpty
        ? detail.title.trim()
        : (detail.originalTitle?.trim() ?? folder.cleanTitle);
    if (!_hasCjk(baseTitle) &&
        bgmTitle.isNotEmpty &&
        _hasCjk(bgmTitle) &&
        matchedSeason == null) {
      baseTitle = bgmTitle;
    }
    if (baseTitle.isEmpty) {
      baseTitle = bgmTitle.isNotEmpty ? bgmTitle : folder.cleanTitle;
    }
    if (specificSubWork && bgmTitle.isNotEmpty) {
      return bgmTitle;
    }

    if (detail.mediaType != TmdbMediaType.tv || matchedSeason == null) {
      if (bgmSubject == null &&
          detail.mediaType == TmdbMediaType.tv &&
          matchedSeason == null) {
        final normLocal = DirectoryAnalyzer.normalize(inv.title);
        final normTmdb = DirectoryAnalyzer.normalize(baseTitle);
        if (normTmdb.isNotEmpty &&
            normLocal.startsWith(normTmdb) &&
            normLocal.length >= normTmdb.length + 2 &&
            !_genericSeasonName.hasMatch(
              normLocal.substring(normTmdb.length),
            )) {
          return inv.title;
        }
      }
      return baseTitle;
    }

    if (matchedSeason == 0) {
      if (bgmTitle.isNotEmpty) return bgmTitle;
      if (seasonName.isNotEmpty && !_genericSeasonName.hasMatch(seasonName)) {
        return seasonName.contains(baseTitle)
            ? seasonName
            : '$baseTitle $seasonName';
      }
      return inv.title.isNotEmpty ? inv.title : '$baseTitle 特别篇';
    }

    if (matchedSeason > 1) {
      if (bgmTitle.isNotEmpty &&
          !_genericSeasonName.hasMatch(bgmTitle) &&
          DirectoryAnalyzer.normalize(bgmTitle) !=
              DirectoryAnalyzer.normalize(baseTitle)) {
        return bgmTitle;
      }
      if (seasonName.isNotEmpty && !_genericSeasonName.hasMatch(seasonName)) {
        final normSeason = DirectoryAnalyzer.normalize(seasonName);
        final normBase = DirectoryAnalyzer.normalize(baseTitle);
        if (seasonName.contains(baseTitle) ||
            (normBase.isNotEmpty && normSeason.startsWith(normBase))) {
          return seasonName;
        }
        return '$baseTitle $seasonName';
      }
      // 当 TMDB 季名仅写泛化「第 2 季」而本地目录具备明确续作副标题（如 `Wake Up, Girls! 新章`）时，
      // 遵循 WorkSeason 规则保留本地续季识别标题，避免两季在媒体库出现完全重名卡片。
      final normLocal = DirectoryAnalyzer.normalize(inv.title);
      final normBase = DirectoryAnalyzer.normalize(baseTitle);
      if (normBase.isNotEmpty &&
          normLocal.startsWith(normBase) &&
          normLocal.length >= normBase.length + 2 &&
          !_genericSeasonName.hasMatch(normLocal.substring(normBase.length))) {
        return inv.title;
      }
    }

    return baseTitle;
  }

  static legacy.MatchCandidate _toMatchCandidate(TmdbWorkDetail detail) {
    final aliases = <String>[...detail.aliases];
    final seen = <String>{
      detail.title.trim().toLowerCase(),
      for (final a in aliases) a.trim().toLowerCase(),
    };
    void addAlias(String value) {
      final t = value.trim();
      if (t.isEmpty) return;
      if (seen.add(t.toLowerCase())) aliases.add(t);
    }

    if (detail.originalTitle != null) {
      addAlias(detail.originalTitle!);
    }

    final seasons = <legacy.SeasonInfo>[];
    if (detail.mediaType == TmdbMediaType.tv) {
      for (final s in detail.seasons) {
        final sName = s.name.trim();
        seasons.add(
          legacy.SeasonInfo(
            s.seasonNumber,
            s.episodeCount,
            _parseYear(s.airDate),
            name: sName.isNotEmpty ? sName : null,
            airDate: s.airDate,
          ),
        );
        if (sName.isNotEmpty && !_genericSeasonName.hasMatch(sName)) {
          addAlias(sName);
          if (detail.title.isNotEmpty && !sName.contains(detail.title)) {
            addAlias('${detail.title} $sName');
          }
        }
      }
    }

    return legacy.MatchCandidate(
      provider: 'tmdb',
      id: detail.tmdbId,
      type: detail.mediaType.name,
      title: detail.title,
      year: detail.year,
      aliases: aliases,
      seasons: seasons,
      genreIds: detail.genreIds,
      voteCount: detail.voteCount,
      originalTitle: detail.originalTitle,
    );
  }

  static DirectoryInventory _effectiveInventory(GroupedWorkFolder folder) {
    if (folder.inventory != null) {
      return folder.inventory!;
    }
    final mainItems = <LogicalItem>[];
    final byEp = <int, LogicalItem>{};
    for (final ep in folder.mainEpisodeNumbers) {
      final item = LogicalItem(
        'e::$ep',
        folder.cleanTitle,
        ep,
        folder.seasonHint,
      );
      byEp[ep] = item;
      mainItems.add(item);
    }
    if (mainItems.isEmpty && folder.variants.isNotEmpty) {
      mainItems.add(
        LogicalItem('f:main', folder.cleanTitle, null, folder.seasonHint),
      );
    }
    final inferredShape = folder.mainEpisodeNumbers.length >= 2
        ? WorkShape.series
        : (folder.variants.isEmpty ? WorkShape.empty : WorkShape.feature);
    return DirectoryInventory.synthetic(
      folder: folder.folderRelativePath,
      title: folder.cleanTitle,
      year: folder.year,
      tmdbId: folder.explicitTmdbId,
      tmdbType: folder.explicitMediaType?.name,
      season: folder.seasonHint,
      folderMovieMarker: folder.isMovieHint,
      main: mainItems,
      shape: inferredShape,
      titleHints: folder.titleHints.isNotEmpty
          ? folder.titleHints
          : [folder.cleanTitle],
      fileHints: folder.fileHints,
    );
  }

  static Map<String, EpisodeSlotAssignment>
  _buildSlotAssignmentsForSingleFolder({
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
        final parsed = BdripParser.parseFileName(
          raw.fileName,
          relativePath: raw.relativePath,
          folderTitle: cleanTitle,
          folderSeasonHint: inventory.season,
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
      final parsed = BdripParser.parseFileName(
        raw.fileName,
        relativePath: raw.relativePath,
        folderTitle: cleanTitle,
        folderSeasonHint: inventory.season,
      );
      if (parsedCache != null) parsedCache[raw.relativePath] = parsed;
      slotMap[raw.relativePath] = resolveExtraSlotAssignment(
        fileName: raw.fileName,
        relativePath: raw.relativePath,
        parsed: parsed,
        folderCleanTitle: cleanTitle,
        workVideoEntries: workVideoEntries,
      );
    }

    return slotMap;
  }

  /// 为单个特典视频提取精简短标题、精准类型与防误合并键。
  static EpisodeSlotAssignment resolveExtraSlotAssignment({
    required String fileName,
    required String relativePath,
    required ParsedBdripRelease parsed,
    String? folderCleanTitle,
    String? overrideExtraType,
    int? overrideEpisode,
    List<({String fileName, String relativePath})> workVideoEntries =
        const <({String fileName, String relativePath})>[],
    List<String> cdAlbumPaths = const <String>[],
  }) {
    final assetMap = <String, Object?>{
      'name': fileName,
      'relative_path': relativePath,
      'category': 'extra',
    };
    final legacyTypeStr = CloudMediaAssetPresentation.extraType(assetMap);
    final fallbackKind =
        _mapExtraKindFromName(legacyTypeStr) ?? parsed.extraType;
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
        CloudMediaAssetPresentation.explicitSpecialNumber(assetMap) ??
        parsed.episode;
    final extractedTitle = CloudMediaAssetPresentation.extraTitle(assetMap);
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

  static final RegExp _volDiscTokenPattern = RegExp(
    r'(?:[\[(（【_\s.-]|^)(Vol|Disc|BD|DVD|Part)[ ._-]*0*(\d{1,2})(?=[\])）】_\s.-]|$)',
    caseSensitive: false,
  );

  static String? _extractVolumeOrDiscSuffix(
    String fileName,
    String relativePath,
  ) {
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

  static String? _resolveConciseExtraTitle({
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
      if (!RegExp(r'\d').hasMatch(trimmedExtracted)) {
        final volSuffix = _extractVolumeOrDiscSuffix(fileName, relativePath);
        if (volSuffix != null) {
          return '$trimmedExtracted $volSuffix';
        }
      }
      return trimmedExtracted;
    }

    final previewMatch = RegExp(
      r'(?:\b(web)[ ._-]+)?\b(preview|teaser|trailer)\b(?:[ ._-]*(\d{1,3}))?|'
      r'([予預]告)(?:[ ._-]*(\d{1,3}))?',
      caseSensitive: false,
    ).firstMatch(fileName);
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

    final promoMatch = RegExp(
      r'(?<![a-z0-9])(TV[ ._-]*CM|BD[ ._-]*CM|PV[ ._-]*CM|CM|PV)(?:[ ._-]*0*(\d{1,3}))?(?![a-z0-9])',
      caseSensitive: false,
    ).firstMatch(fileName);
    if (promoMatch != null) {
      final tag = promoMatch
          .group(1)!
          .toUpperCase()
          .replaceAll(RegExp(r'[ ._-]+'), '');
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
          .replaceFirst(RegExp(r'^[\s\-–—_:：]+'), '')
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

  static String _buildExtraUnnumberedStemKey({
    required String fileName,
    required String relativePath,
    required ParsedBdripRelease parsed,
    required String? shortTitle,
  }) {
    final normShort = (shortTitle ?? '').toLowerCase().replaceAll(
      RegExp(r'[^a-z0-9\u3040-\u9fff]+'),
      '',
    );
    var stem = fileName.replaceFirst(RegExp(r'\.[^.]+$'), '');
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
    stem = stem.replaceAll(RegExp(r'\[[0-9a-fA-F]{8}\]'), ' ');
    stem = MediaTechParser.parse(stem).strippedText;
    final normStem = stem
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9\u3040-\u9fff]+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    final volSuffix = _extractVolumeOrDiscSuffix(
      fileName,
      relativePath,
    )?.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');
    final parts = <String>[
      if (normShort.isNotEmpty) normShort,
      if (volSuffix != null && volSuffix.isNotEmpty) volSuffix,
      normStem.isNotEmpty ? normStem : relativePath.toLowerCase(),
    ];
    return parts.join('::');
  }

  static List<MediaVariant> _buildVariants({
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

  static Set<String> _detectMultiInstallmentRoots(
    List<ScannedFileInput> files, {
    required Map<String, String> nfoByFolder,
  }) {
    final childSegsByParent = <String, Set<String>>{};
    for (final file in files) {
      if (file.assetKind != AssetKind.video) continue;
      final segments = file.relativePath
          .replaceAll('\\', '/')
          .split('/')
          .where((s) => s.isNotEmpty)
          .toList();
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

  static String _resolvePhysicalWorkFolder(
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
            SupplementaryFolderRules.isExplicitSeasonSubdir(
              parentSegments[k],
            )) {
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

  static Map<String, List<ScannedFileInput>> _foldNestedBuckets(
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

  static String? _findNearestAncestorFolder(
    String folderPath,
    Set<String> candidates,
  ) {
    if (folderPath.isEmpty) return null;
    final parts = folderPath.split('/');
    for (var len = parts.length - 1; len >= 1; len--) {
      final candidate = parts.sublist(0, len).join('/');
      if (candidates.contains(candidate)) return candidate;
    }
    return candidates.contains('') ? '' : null;
  }

  static bool _shouldSplitExplicitTmdb(
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

  static String _buildSplitVirtualFolder(String physicalFolder, String slug) {
    final cleanSlug = slug.trim().isEmpty ? 'part' : slug.trim();
    if (physicalFolder.isEmpty) return '::$cleanSlug';
    return '$physicalFolder::$cleanSlug';
  }

  static String _stripFolderPrefix(String relativePath, String folderPath) {
    final normRel = relativePath.replaceAll('\\', '/');
    final normFolder = folderPath
        .replaceAll('\\', '/')
        .replaceAll(RegExp(r'^/+|/+$'), '');
    if (normFolder.isEmpty) return normRel;
    if (normRel.startsWith('$normFolder/')) {
      return normRel.substring(normFolder.length + 1);
    }
    return normRel;
  }

  static String _lastSegment(String path) {
    if (path.isEmpty) return 'Root';
    final norm = path.replaceAll('\\', '/');
    final idx = norm.lastIndexOf('/');
    return idx >= 0 ? norm.substring(idx + 1) : norm;
  }

  static TmdbMediaType? _parseTmdbMediaType(String? raw) {
    if (raw == 'tv') return TmdbMediaType.tv;
    if (raw == 'movie') return TmdbMediaType.movie;
    return null;
  }

  static ExtraKind? _mapExtraKindFromName(String? raw) {
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

  static List<String> _normalizeReasonsToCodes(List<String> rawReasons) {
    final out = <String>[];
    final seen = <String>{};
    void add(String code) {
      if (seen.add(code)) out.add(code);
    }

    final scoredPrefixRe = RegExp(r'^([+-]?\d+)\s+(.+)$');
    for (final raw in rawReasons) {
      final trimmed = raw.trim();
      if (trimmed.isEmpty) continue;
      final scoredMatch = scoredPrefixRe.firstMatch(trimmed);
      final points = scoredMatch == null
          ? null
          : int.tryParse(scoredMatch.group(1)!);
      final label = (scoredMatch?.group(2) ?? trimmed).trim();

      if (label == 'marker') {
        add((points ?? 1) > 0 ? 'explicit_tmdb_match' : 'explicit_id_mismatch');
      } else if (label == 'other than marker' || label == 'marker type') {
        add('explicit_id_mismatch');
      } else if (label == 'title') {
        if (points != null && points >= 42) {
          add('exact_title');
        } else if (points == null || points >= 34) {
          add('high_title_similarity');
        } else if (points >= 20) {
          add('partial_title_similarity');
        } else {
          add('low_title_similarity');
        }
      } else if (label == 'season name') {
        add('season_name_match');
      } else if (label == 'bangumi-tmdb mapping') {
        add('bangumi_tmdb_mapping');
      } else if (label == 'bangumi agrees') {
        add('bangumi_cross_match');
      } else if (label == 'partial latin token match') {
        add('partial_latin_prefix');
      } else if (label == 'conflicting subtitle') {
        add('subtitle_conflict');
      } else if (label.startsWith('missing sequel number')) {
        add('missing_sequel_number');
      } else if (label.startsWith('installment slot conflict')) {
        add('subtitle_conflict');
      } else if (label.startsWith('installment slot ')) {
        add('season_name_match');
      } else if (label == 'year' || label == 'year (via Bangumi)') {
        if (points != null && points >= 12) {
          add('year_exact');
        } else if (points != null && points > 0) {
          add('year_near');
        } else if (points != null && points >= -10) {
          add('year_span_tolerance');
        } else {
          add('year_mismatch');
        }
      } else if (label == 'year ~') {
        add('year_near');
      } else if (label == 'year mismatch') {
        add('year_mismatch');
      } else if (label == 'remaster -> original year' ||
          label == 'remaster match') {
        add('remaster_match');
      } else if (label == 'franchise special year') {
        add('season_year_match');
      } else if (label == 'merged single-season sequel year') {
        add('merged_sequel_year');
      } else if (label == 'season count' || label == 'all seasons count') {
        add('season_episode_match');
      } else if (label == 'cumulative offset') {
        add('cumulative_offset_match');
      } else if (label == 'incomplete season vs offset' ||
          label == 'insufficient seasons vs offset') {
        add('incomplete_season_offset');
      } else if (label == 'special season' ||
          label == 'mapped special season' ||
          label == 'special/short season') {
        add('special_season_match');
      } else if (label == 'series') {
        add('series_structure_match');
      } else if (label == 'movie vs tv' ||
          label == 'feature vs tv' ||
          label == 'series vs movie') {
        add('media_type_conflict');
      } else if (label == 'anthology') {
        add('anthology_conflict');
      } else if (label == 'short ova vs long tv') {
        add('short_ova_vs_long_tv');
      } else if (label == 'ex special missing ex/s0') {
        add('ex_missing_special_slot');
      } else if (label == 'feature' ||
          label == 'folder says movie' ||
          label == 'file says movie') {
        add('media_type_match');
      } else if (label == 'stub entry') {
        add('stub_entry');
      } else if (label == 'unpopular duplicate') {
        add('unpopular_duplicate');
      } else {
        add(label);
      }
    }
    return out;
  }

  static String _derivePrimaryReviewCode(List<ScoredTmdbCandidate> top5) {
    if (top5.length >= 2 && (top5[0].score - top5[1].score) < 12) {
      return 'close_candidates';
    }
    final reasons = top5.first.reasons;
    for (final code in const [
      'explicit_id_mismatch',
      'media_type_conflict',
      'missing_sequel_number',
      'subtitle_conflict',
      'year_mismatch',
    ]) {
      if (reasons.contains(code)) return code;
    }
    return 'low_confidence';
  }

  static String _buildChineseReviewSummary({
    required String primaryCode,
    required List<String> reasons,
  }) {
    if (primaryCode == 'close_candidates') {
      return '存在多个高分相近候选，请确认准确条目';
    }
    if (reasons.contains('explicit_id_mismatch')) {
      return '与目录指定的 TMDB 编号存在冲突，请确认';
    }
    if (reasons.contains('year_mismatch')) {
      return '目录年份与 TMDB 首播年份差距较大，建议复核';
    }
    if (reasons.contains('subtitle_conflict')) {
      return '副标题与候选条目存在差异，请人工确认';
    }
    if (reasons.contains('missing_sequel_number')) {
      return '目录包含续集/多季标识，请核对是否对应正确季度';
    }
    if (reasons.contains('media_type_conflict')) {
      return '剧集与剧场版类型判断存在冲突，请确认';
    }
    return '标题相似度置信度不足，请从候选中选择准确作品';
  }

  static final RegExp _remasterPattern = RegExp(
    r'(?:HD\s*)?(?:重制版|重製版|Remaster(?:ed)?)|リマスター',
    caseSensitive: false,
  );

  static String _stripRemasterTag(String value) => value
      .replaceAll(_remasterPattern, ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  static bool _hasCjk(String s) => RegExp(r'[\u3040-\u9fff]').hasMatch(s);

  /// 场景式命名在标题后紧跟合理发行年份（1950~2029）、分辨率、编码或季集标记，搜索词从首个此类标记处截断（标记不在开头时）；
  /// 科幻片名自带的未来年份（如 `Demon Lord 2099`）不被截断。
  static final RegExp _queryTechnicalTail = RegExp(
    r'(?<![a-z0-9぀-鿿])(?:(?:19[5-9]\d|20[0-2]\d)|s\d{1,2}e\d{1,4}|tvsp\d{1,3}|\d{3,4}[pi]|[248]k|x26[45]|h\.?26[45]|'
    r'hevc|avc|flac|aac|ac3|dual[ ._-]?audio|10bits?|8bits?|bdrip|dvdrip|webrip|web[ ._-]?dl|blu[ ._-]?ray)(?![a-z0-9])',
    caseSensitive: false,
  );

  static String _cutTechnicalTail(String query) {
    final m = _queryTechnicalTail.firstMatch(query);
    if (m == null || m.start == 0) {
      return query
          .replaceAll(
            RegExp(
              r'(?<![a-z0-9])(?:\d{3,4}[pi]|[248]k)(?![a-z0-9])',
              caseSensitive: false,
            ),
            ' ',
          )
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
    }
    return query.substring(0, m.start).trim();
  }

  /// 压制组名、纯技术/语言标签、通用类型词与过短的版本号片段都不是有效作品搜索词。
  static final RegExp _genericQueryWord = RegExp(
    r'^(?:电影|映画|剧场版|劇場版|the[ ._-]+movie|movie|film|(?:ova|oad|oav|oab|ona|sp|special)\d*|sps|specials|tv|'
    r'dts[ ._-]*hd(?:ma)?|'
    r'完结篇|完結編|前篇|前編|后篇|後編|中篇|中編|上篇|下篇|'
    r'特典|特别篇|特別編|总集篇|総集編|extras?|bonus|bd|dvd|web|v\d+|\d{1,2}d)$',
    caseSensitive: false,
  );

  static bool _isJunkQuery(String query, {bool allowGroupHomonym = false}) {
    final trimmed = query.trim();
    if (_genericQueryWord.hasMatch(trimmed)) return true;
    if (!allowGroupHomonym &&
        PersonalFilenameParser.isReleaseGroupTag(trimmed) &&
        !_hasCjk(
          trimmed.replaceAll(RegExp(r'字幕[组組社]|[汉漢]化[组組]|[压壓]制[组組]'), ''),
        )) {
      return true;
    }
    final letters = trimmed.replaceAll(RegExp(r'[\W_]+', unicode: true), '');
    if (!_hasCjk(trimmed) && letters.length <= 2) return true;
    return false;
  }

  static bool _isSafeFirstToken(String firstToken, String fullQuery) {
    if (_hasCjk(firstToken)) return firstToken.length >= 2;
    final stripped = fullQuery
        .replaceAll(
          RegExp(
            r'(?<![a-z0-9])(?:oad|ova|ona|sp|specials?|ex\d{0,2}|the\s+movie|movie|tv)(?![a-z0-9])',
            caseSensitive: false,
          ),
          ' ',
        )
        .toLowerCase();
    final latinWords = stripped
        .split(RegExp(r'[^a-z0-9]+'))
        .where((w) => w.length >= 3)
        .toList();
    return latinWords.length <= 1 && firstToken.length >= 4;
  }

  static ({
    List<String> extraTitleHints,
    List<String> extraQueries,
    bool isSpecial,
  })
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
      final hasVolSuffix = RegExp(
        r'(?:^|\s)(?:one|two|[12])$',
        caseSensitive: false,
      );
      for (final hint in [
        cluster.inventory.title,
        ...cluster.inventory.titleHints,
      ]) {
        final trimmed = hint.trim();
        if (RegExp(
              r'\balternative\b',
              caseSensitive: false,
            ).hasMatch(trimmed) &&
            !hasVolSuffix.hasMatch(trimmed)) {
          extraTitleHints.add('$trimmed $vol');
          extraQueries.add('$trimmed $vol');
        }
      }
      if (parentSeriesTitle.isNotEmpty) {
        final trimmedParent = parentSeriesTitle.trim();
        final hasAltWord = RegExp(
              r'\balternative\b',
              caseSensitive: false,
            ).hasMatch(trimmedParent);
        if (hasAltWord) {
          if (!hasVolSuffix.hasMatch(trimmedParent)) {
            extraTitleHints.add('$trimmedParent $vol');
            extraQueries.add('$trimmedParent $vol');
          }
          final pureParent = trimmedParent
              .replaceFirst(
                RegExp(
                  r'\s*\balternative(?:\s+(?:one|two|[12]))?\s*$',
                  caseSensitive: false,
                ),
                '',
              )
              .trim();
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
        ...legacy.WorkMatcher.romajiArcSuffixesFor(hint),
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
    final clusterTitleNorm = DirectoryAnalyzer.normalize(
      cluster.inventory.title,
    );
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

  static String _extractParentSeriesTitle(String folder) {
    final segments = folder
        .replaceAll('\\', '/')
        .split('/')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    if (segments.isEmpty) return '';
    var raw = segments.last
        .replaceAll(RegExp(r'\{[^}]*\}'), ' ')
        .replaceAll(RegExp(r'\(\s*(?:19|20)\d{2}\s*\)'), ' ')
        .replaceAll(RegExp(r'（\s*(?:19|20)\d{2}\s*）'), ' ')
        .replaceAll(RegExp(r'\[[^\]]*\]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final suffixRe = RegExp(
      r'[\s\-+_,]*(?:TV\s*\+\s*Movie|TV\s*\+\s*OVA|TV|OVA|OAD|SP|Movies?|系列|作品集|合集|全集|Series|Collection)\s*$',
      caseSensitive: false,
    );
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

  static bool _isClusterEx(SubWorkCluster cluster) {
    final texts = [
      cluster.inventory.title,
      ...cluster.inventory.titleHints,
      ...cluster.inventory.fileHints,
    ];
    return texts.any(
      (t) => RegExp(
        r'(?<![a-z0-9])ex(?:\d{1,2})?(?![a-z0-9])',
        caseSensitive: false,
      ).hasMatch(t),
    );
  }

  static bool _isClusterSpecial(SubWorkCluster cluster) {
    if (cluster.inventory.folderMovieMarker ||
        cluster.inventory.fileMovieMarker) {
      return false;
    }
    if (cluster.inventory.season == 0 || _isClusterEx(cluster)) return true;
    final specialRe = RegExp(
      r'(?<![a-z0-9])(?:ova|oad|sp|specials?)(?![a-z0-9])|特典|特别篇|番外',
      caseSensitive: false,
    );
    return [
      cluster.inventory.title,
      ...cluster.inventory.titleHints,
      ...cluster.inventory.fileHints,
    ].any(specialRe.hasMatch);
  }

  static int? _alternativePartForCluster(
    SubWorkCluster cluster,
    Map<String, ScannedFileInput> fileByRelPath,
  ) {
    final allTexts = [
      cluster.inventory.title,
      ...cluster.inventory.titleHints,
      ...cluster.inventory.fileHints,
    ];
    final hasAlt = allTexts.any(
      (t) => RegExp(r'\balternative\b', caseSensitive: false).hasMatch(t),
    );
    if (!hasAlt) return null;
    final alreadyPart = cluster.inventory.titleHints.any(
      (h) => RegExp(
          r'\balternative\s+(?:one|two)\b',
          caseSensitive: false,
        ).hasMatch(h),
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
      if (RegExp(r'(?:^|[^0-9])0?1(?:[^0-9]|$)').hasMatch(name)) return 1;
      if (RegExp(r'(?:^|[^0-9])0?2(?:[^0-9]|$)').hasMatch(name)) return 2;
    }
    return null;
  }

  static List<String> _dedupePreserveOrder(List<String> values) {
    final seen = <String>{};
    final out = <String>[];
    for (final v in values) {
      final t = v.trim();
      if (t.isEmpty) continue;
      if (seen.add(t.toLowerCase())) out.add(t);
    }
    return out;
  }

  static bool _providersCompatible(
    TmdbWorkDetail tmdb,
    int? resolvedSeason,
    BangumiSubjectCandidate bgm,
  ) {
    if (tmdb.genreIds.isNotEmpty && !tmdb.genreIds.contains(16)) {
      return false;
    }
    final ty = resolvedSeason != null
        ? _parseYear(
                tmdb.seasons
                    .where((s) => s.seasonNumber == resolvedSeason)
                    .firstOrNull
                    ?.airDate,
              ) ??
              tmdb.year
        : tmdb.year;
    final by = bgm.year;
    final yearsMatch =
        ty == null ||
        by == null ||
        (ty - by).abs() <= 2 ||
        (tmdb.mediaType == TmdbMediaType.tv &&
            tmdb.year != null &&
            tmdb.year! <= by + 1);
    if (!yearsMatch) return false;

    final tmdbNorms = <String>{
      DirectoryAnalyzer.normalize(tmdb.title),
      if (tmdb.originalTitle != null)
        DirectoryAnalyzer.normalize(tmdb.originalTitle!),
      for (final a in tmdb.aliases) DirectoryAnalyzer.normalize(a),
    }..removeWhere((e) => e.isEmpty);
    final bgmNorms = <String>{
      DirectoryAnalyzer.normalize(bgm.displayTitle),
      DirectoryAnalyzer.normalize(bgm.name),
      for (final a in bgm.aliases) DirectoryAnalyzer.normalize(a),
    }..removeWhere((e) => e.isEmpty);

    for (final bn in bgmNorms) {
      for (final tn in tmdbNorms) {
        if (legacy.WorkMatcher.similarity(bn, tn) >= 0.45) {
          return true;
        }
      }
    }
    return false;
  }

  /// 以 Bangumi 高置信条目锚定 TMDB 候选：任一名称归一化后与 Bangumi 名称完全一致或命中
  /// Wikidata 映射（[mappedKeys]），且年份吻合（剧集取任一季首播年，相差不超过 1 年）。
  /// 唯一锚定或锚定候选间分差不小于 5 时返回，否则返回 `null` 交由原降级逻辑处理。
  /// 身份已由名称或映射确认，因此不再要求 TMDB 标注动画类型（小型条目常漏标），
  /// 但空壳条目与得分过低（合集/类型硬冲突）的候选不参与锚定。
  static ScoredTmdbCandidate? _bangumiAnchoredTmdb(
    List<ScoredTmdbCandidate> scored,
    BangumiSubjectCandidate bgm,
    List<String> mappedKeys,
  ) {
    final bgmYear = bgm.year;
    if (bgmYear == null) return null;

    bool yearOk(TmdbWorkDetail d) {
      final years = <int>{
        ?d.year,
        if (d.mediaType == TmdbMediaType.tv)
          for (final s in d.seasons) ?_parseYear(s.airDate),
      };
      return years.any((y) => (y - bgmYear).abs() <= 1);
    }

    // 漏标动画类型(16)的日本小条目仅在含中日文独有片名且年份完全一致时放行锚定，
    // 杜绝纯拉丁通用词（如英文 `Shelter`）误将真人惊悚/剧情片锚定为动画。
    bool genreSafeForAnchor(TmdbWorkDetail d) {
      if (mappedKeys.contains(_detailKey(d))) return true;
      if (d.genreIds.isEmpty || d.genreIds.contains(16)) return true;
      final tmdbText = '${d.title} ${d.originalTitle ?? ''}';
      final bgmText = '${bgm.name} ${bgm.nameCn}';
      return _hasCjk(tmdbText) && _hasCjk(bgmText) && d.year == bgmYear;
    }

    final anchored = [
      for (final c in scored)
        if (c.score >= 30 &&
            !c.reasons.contains('stub_entry') &&
            yearOk(c.detail) &&
            genreSafeForAnchor(c.detail) &&
            (mappedKeys.contains(_detailKey(c.detail)) ||
                _tmdbNamesMatchBangumi(c.detail, bgm)))
          c,
    ];
    if (anchored.isEmpty) return null;
    if (anchored.length == 1) return anchored.first;
    if (anchored[0].score - anchored[1].score >= 5) return anchored[0];
    // 多个锚定候选分差过小时，以 Wikidata 映射唯一指向的条目定夺（如母剧与续作专属条目同名）。
    final close = anchored
        .where((c) => anchored[0].score - c.score < 5)
        .toList(growable: false);
    final mapped = close
        .where((c) => mappedKeys.contains(_detailKey(c.detail)))
        .toList(growable: false);
    if (mapped.length == 1) return mapped.single;
    // 其余均为零评分人数的新建重复条目时，取唯一有评分人数的正主条目。
    final rated = close
        .where((c) => (c.detail.voteCount ?? 1) > 0)
        .toList(growable: false);
    return rated.length == 1 ? rated.single : null;
  }

  static final RegExp _seasonOrPartSuffix = RegExp(
    r'^(?:第?[0-9一二三四五六七八九十]+(?:季|期|部分|部|章|クール)|最终季.*|finalseason.*|'
    r'season[0-9]+|s[0-9]+|[0-9]+(?:st|nd|rd|th)season|part[0-9]+|volume[0-9]+|vol[0-9]+)$',
    caseSensitive: false,
  );

  /// Bangumi 高置信条目是某部 TMDB 剧集的续季、分部或篇章（Bangumi 名称 = 剧集名称 + 后缀）时绑定母剧
  /// （TMDB 常把续季并入同一剧集条目，以累计集号续接）。满足该关系的剧集候选中取评分人数最多者为正主
  /// （同名的零评分新建重复条目让位），且其得分不得比全体第一名低超过 10 分。
  /// 仅在 TMDB 已被整体放弃时使用；剧场版条目不走此路径，避免把独立电影错挂到母剧。
  /// 后缀须为季/分部标记，或目录本身是多集正片（续作篇章、OVA 系列）。
  static ScoredTmdbCandidate? _bangumiParentSeriesTmdb(
    List<ScoredTmdbCandidate> scored,
    BangumiSubjectCandidate bgm,
    DirectoryInventory inv,
  ) {
    final bgmYear = bgm.year;
    if (scored.isEmpty ||
        bgmYear == null ||
        (bgm.platform?.trim() ?? '') == '剧场版') {
      return null;
    }
    final bgmNorms = [
      for (final raw in [bgm.nameCn, bgm.name, ...bgm.aliases])
        DirectoryAnalyzer.normalize(raw),
    ];
    final multiEpisode = inv.shape == WorkShape.series && inv.episodeCount >= 2;

    // 仅以正式标题与原名作前缀：别名常含系列总称（如 `宇宙戦艦ヤマト`），会把同系列的另一部作品误判为母剧。
    bool isParentOf(TmdbWorkDetail d) {
      final tmdbNorms = <String>{
        DirectoryAnalyzer.normalize(d.title),
        if (d.originalTitle != null)
          DirectoryAnalyzer.normalize(d.originalTitle!),
      }..removeWhere((e) => e.length < 2);
      for (final n in bgmNorms) {
        for (final t in tmdbNorms) {
          if (n.length <= t.length || !n.startsWith(t)) continue;
          if (multiEpisode ||
              _seasonOrPartSuffix.hasMatch(n.substring(t.length))) {
            return true;
          }
        }
      }
      return false;
    }

    final parents = [
      for (final c in scored)
        if (c.detail.mediaType == TmdbMediaType.tv &&
            !c.reasons.contains('stub_entry') &&
            c.detail.year != null &&
            c.detail.year! <= bgmYear + 1 &&
            scored.first.score - c.score <= 10 &&
            isParentOf(c.detail))
          c,
    ];
    if (parents.isEmpty) return null;
    parents.sort((a, b) {
      final byVotes = (b.detail.voteCount ?? 0).compareTo(
        a.detail.voteCount ?? 0,
      );
      return byVotes != 0 ? byVotes : b.score.compareTo(a.score);
    });
    return parents.first;
  }

  /// 双源互证要求的 Bangumi 首选最低得分（标题需高度一致，约等于标题精确命中再无明显冲突）。
  static const double _crossConfirmBangumiScore = 50;

  static const Set<String> _hardConflictReasonCodes = {
    'year_mismatch',
    'media_type_conflict',
    'explicit_id_mismatch',
    'anthology_conflict',
    'subtitle_conflict',
    'missing_sequel_number',
    'stub_entry',
    'unpopular_duplicate',
  };

  /// TMDB 候选打分原因中标题高度一致、年份吻合且不含任何硬冲突。
  static bool _hasStrongTitleAndYear(List<String> reasons) =>
      (reasons.contains('exact_title') ||
          reasons.contains('high_title_similarity')) &&
      (reasons.contains('year_exact') || reasons.contains('year_near')) &&
      !reasons.any(_hardConflictReasonCodes.contains);

  static String _detailKey(TmdbWorkDetail d) =>
      '${d.mediaType.name}:${d.tmdbId}';

  /// 查询 Bangumi 条目经离线映射表（优先二进制索引，回退静态 Wikidata）得到、
  /// 且已在 [availableKeys]（`类型:ID`）中的 TMDB 目标，按放送平台、季信息与来源权威度排序。
  static List<BangumiTmdbTarget> bangumiMappedTmdbTargets(
    BangumiSubjectCandidate? bgm,
    Set<String> availableKeys, {
    BangumiTmdbIndex? mappingIndex,
  }) {
    if (bgm == null) return const [];
    final preferMovie = (bgm.platform?.trim() ?? '') == '剧场版';
    final targets = [
      for (final m in BangumiTmdbIndex.resolveTargets(
        bgm.id,
        index: mappingIndex,
      ))
        if (availableKeys.contains(m.key)) m,
    ];
    targets.sort((a, b) {
      int typeRank(BangumiTmdbTarget t) =>
          (preferMovie
                  ? t.type == TmdbMediaType.movie
                  : t.type == TmdbMediaType.tv)
              ? 0
              : 1;
      final byType = typeRank(a).compareTo(typeRank(b));
      if (byType != 0) return byType;
      final aHasSeason = a.season != null && a.season! > 0 ? 0 : 1;
      final bHasSeason = b.season != null && b.season! > 0 ? 0 : 1;
      if (aHasSeason != bHasSeason) return aHasSeason.compareTo(bHasSeason);
      final aOpenAni = a.isOpenAni ? 0 : 1;
      final bOpenAni = b.isOpenAni ? 0 : 1;
      return aOpenAni.compareTo(bOpenAni);
    });
    return targets;
  }

  /// Bangumi 条目经离线映射表得到、且已在 [availableKeys]（`类型:ID`）中的 TMDB 键，
  /// 按 Bangumi 放送平台排序：剧场版条目优先电影映射，其余优先剧集映射。
  static List<String> bangumiMappedTmdbKeys(
    BangumiSubjectCandidate? bgm,
    Set<String> availableKeys, {
    BangumiTmdbIndex? mappingIndex,
  }) {
    final seen = <String>{};
    return [
      for (final t in bangumiMappedTmdbTargets(
        bgm,
        availableKeys,
        mappingIndex: mappingIndex,
      ))
        if (seen.add(t.key)) t.key,
    ];
  }

  /// TMDB 条目任一名称（标题、原名、别名）与 Bangumi 条目任一名称归一化后是否完全一致。
  static bool _tmdbNamesMatchBangumi(
    TmdbWorkDetail tmdb,
    BangumiSubjectCandidate bgm,
  ) {
    final bgmNorms = <String>{
      DirectoryAnalyzer.normalize(bgm.nameCn),
      DirectoryAnalyzer.normalize(bgm.name),
      for (final a in bgm.aliases) DirectoryAnalyzer.normalize(a),
    }..removeWhere((e) => e.length < 2);
    if (bgmNorms.isEmpty) return false;
    return <String>{
      DirectoryAnalyzer.normalize(tmdb.title),
      if (tmdb.originalTitle != null)
        DirectoryAnalyzer.normalize(tmdb.originalTitle!),
      for (final a in tmdb.aliases) DirectoryAnalyzer.normalize(a),
    }.any(bgmNorms.contains);
  }

  static bool _isBangumiRemasterIdentity(
    DirectoryInventory inventory,
    legacy.MatchCandidate? tmdbPick,
    legacy.MatchCandidate? bgmPick,
  ) =>
      bgmPick != null &&
      _remasterPattern.hasMatch(inventory.title) &&
      _remasterPattern.hasMatch(bgmPick.title) &&
      (tmdbPick == null || !_remasterPattern.hasMatch(tmdbPick.title));

  static bool _useBangumiSeasonIdentity({
    required DirectoryInventory inventory,
    required legacy.MatchCandidate? tmdbPick,
    required legacy.MatchCandidate? bgmPick,
  }) {
    if (tmdbPick == null || tmdbPick.type != 'tv' || bgmPick == null) {
      return false;
    }
    if (_isBangumiRemasterIdentity(inventory, tmdbPick, bgmPick)) {
      return true;
    }
    final bgmTitle = bgmPick.title.trim();
    final localTitle = inventory.title.trim();
    if (!_hasCjk(bgmTitle) || !_hasCjk(localTitle)) return false;
    final normLocal = DirectoryAnalyzer.normalize(localTitle);
    final normBgm = DirectoryAnalyzer.normalize(bgmTitle);
    final normTmdb = DirectoryAnalyzer.normalize(tmdbPick.title);
    if (normLocal.isEmpty || normBgm.isEmpty || normBgm == normTmdb) {
      return false;
    }
    final localToBgm = legacy.WorkMatcher.similarity(normLocal, normBgm);
    final localToTmdb = normTmdb.isEmpty
        ? 0.0
        : legacy.WorkMatcher.similarity(normLocal, normTmdb);
    return localToBgm >= 0.85 && localToBgm >= localToTmdb + 0.25;
  }

  static bool _isSpecificSubWork({
    required DirectoryInventory inventory,
    required legacy.MatchCandidate tmdbPick,
    required int? resolvedSeason,
    required legacy.MatchCandidate? bgmPick,
  }) {
    if (bgmPick == null) return false;
    final regular = tmdbPick.seasons.where((s) => s.number > 0).toList();
    var mergedSingleSeason = false;
    if (resolvedSeason != null && resolvedSeason > 0) {
      final matched = regular
          .where((s) => s.number == resolvedSeason)
          .firstOrNull;
      mergedSingleSeason =
          regular.length <= 1 &&
          matched != null &&
          inventory.episodeCount > 0 &&
          matched.count >= inventory.episodeCount + 4;
      if (!mergedSingleSeason) return false;
    } else if (regular.length <= 1 &&
        regular.isNotEmpty &&
        inventory.episodeCount > 0 &&
        regular.first.count >= inventory.episodeCount + 4) {
      mergedSingleSeason = true;
    }
    final bgmTitle = bgmPick.title.trim();
    final tmdbTitle = tmdbPick.title.trim();
    if (bgmTitle.isEmpty || tmdbTitle.isEmpty) return false;
    final normBgm = DirectoryAnalyzer.normalize(bgmTitle);
    final normTmdb = DirectoryAnalyzer.normalize(tmdbTitle);
    if (normBgm.isEmpty || normTmdb.isEmpty || normBgm == normTmdb) {
      return false;
    }
    if (normBgm.startsWith(normTmdb) && normBgm.length >= normTmdb.length + 2) {
      final suffix = bgmTitle.length > tmdbTitle.length
          ? bgmTitle.substring(tmdbTitle.length).trim()
          : '';
      if (suffix.isNotEmpty && _genericSeasonName.hasMatch(suffix)) {
        final seqSeason =
            DirectoryAnalyzer.splitSeasonSuffix(
              bgmTitle,
              isSeries: true,
            ).season ??
            inventory.season;
        return mergedSingleSeason && (seqSeason ?? 0) >= 2;
      }
      return true;
    }
    final normLocal = DirectoryAnalyzer.normalize(inventory.title);
    if (_hasCjk(bgmTitle) &&
        normLocal.length >= normTmdb.length + 2 &&
        legacy.WorkMatcher.similarity(normLocal, normBgm) >
            legacy.WorkMatcher.similarity(normLocal, normTmdb) + 0.15) {
      return true;
    }
    return false;
  }

  static List<String> _romanNumeralVariants(String raw) {
    const unicodeToAscii = <String, String>{
      'Ⅰ': 'I',
      'Ⅱ': 'II',
      'Ⅲ': 'III',
      'Ⅳ': 'IV',
      'Ⅴ': 'V',
      'Ⅵ': 'VI',
      'Ⅶ': 'VII',
      'Ⅷ': 'VIII',
      'Ⅸ': 'IX',
      'Ⅹ': 'X',
      'ⅰ': 'I',
      'ⅱ': 'II',
      'ⅲ': 'III',
      'ⅳ': 'IV',
      'ⅴ': 'V',
      'ⅵ': 'VI',
      'ⅶ': 'VII',
      'ⅷ': 'VIII',
      'ⅸ': 'IX',
      'ⅹ': 'X',
    };
    const unicodeToArabic = <String, String>{
      'Ⅰ': '1',
      'Ⅱ': '2',
      'Ⅲ': '3',
      'Ⅳ': '4',
      'Ⅴ': '5',
      'Ⅵ': '6',
      'Ⅶ': '7',
      'Ⅷ': '8',
      'Ⅸ': '9',
      'Ⅹ': '10',
      'ⅰ': '1',
      'ⅱ': '2',
      'ⅲ': '3',
      'ⅳ': '4',
      'ⅴ': '5',
      'ⅵ': '6',
      'ⅶ': '7',
      'ⅷ': '8',
      'ⅸ': '9',
      'ⅹ': '10',
    };
    const asciiToArabic = <String, String>{
      'II': '2',
      'III': '3',
      'IV': '4',
      'V': '5',
      'VI': '6',
      'VII': '7',
      'VIII': '8',
      'IX': '9',
      'X': '10',
    };

    var ascii = raw;
    var asciiChanged = false;
    unicodeToAscii.forEach((k, v) {
      if (ascii.contains(k)) {
        ascii = ascii.replaceAll(k, ' $v ');
        asciiChanged = true;
      }
    });

    var arabic = raw;
    var arabicChanged = false;
    unicodeToArabic.forEach((k, v) {
      if (arabic.contains(k)) {
        arabic = arabic.replaceAll(k, ' $v ');
        arabicChanged = true;
      }
    });
    arabic = arabic.replaceAllMapped(
      RegExp(
        r'(?:^|(?<=[\s\u3040-\u9fff\-:：]))(II|III|IV|VI{0,3}|IX|V|X)(?=$|[\s\u3040-\u9fff\-:：])',
      ),
      (m) {
        final rep = asciiToArabic[m.group(1)!];
        if (rep == null) return m.group(0)!;
        arabicChanged = true;
        return ' $rep ';
      },
    );

    final out = <String>[];
    if (asciiChanged) {
      final clean = ascii.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (clean.isNotEmpty) out.add(clean);
    }
    if (arabicChanged) {
      final clean = arabic.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (clean.isNotEmpty && !out.contains(clean)) out.add(clean);
    }
    return out;
  }

  static int? _parseYear(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    final m = RegExp(r'(19|20)\d{2}').firstMatch(raw);
    return m == null ? null : int.tryParse(m.group(0)!);
  }

  static String? _nonEmpty(String? raw) {
    final trimmed = raw?.trim();
    return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
  }
}
