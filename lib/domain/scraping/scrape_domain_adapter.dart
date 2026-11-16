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
import 'cloud_media_asset_presentation.dart';
import 'collection_asset_router.dart';
import 'directory_analyzer.dart';
import 'multi_work_splitter.dart';
import 'personal_filename_parser.dart';
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
    r'^(?:动画|番剧|电影|剧场版|劇場版|动漫|影视|日漫|国漫|美漫|动画[-_]?单作品|动画[-_]?多作品|anime|movies?|tv|series|bdmv|bdrip|video|media|downloads?)$',
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

  /// 使用无损目录分析器与多作品拆分器对扫描文件执行抗碎裂归拢与合集拆分。
  static List<GroupedWorkFolder> groupAndSplitFiles({
    required String sourceId,
    required List<ScannedFileInput> files,
    Map<String, String> nfoByFolder = const {},
  }) {
    final multiInstallmentRoots = _detectMultiInstallmentRoots(
      files,
      nfoByFolder: nfoByFolder,
    );
    final rawBuckets = <String, List<ScannedFileInput>>{};
    for (final file in files) {
      final workFolder = _resolvePhysicalWorkFolder(
        file.relativePath,
        multiInstallmentRoots: multiInstallmentRoots,
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

      var inventory = DirectoryAnalyzer.analyze(analyzePath, relativeVideos);
      if (nfoHint.tmdbId != null || nfoHint.mediaType != null) {
        inventory = inventory.withExplicitIds(
          tmdbId: inventory.tmdbId ?? nfoHint.tmdbId,
          tmdbType: inventory.tmdbType ?? nfoHint.mediaType?.name,
        );
      }

      if (videoFiles.length >= 2) {
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
                  _shouldSplitExplicitTmdb(inventory, preview));

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
            if (clusterFiles.where((f) => f.assetKind == AssetKind.video).isEmpty) {
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

            result.add(
              GroupedWorkFolder(
                folderRelativePath: clusterFolderId,
                physicalRootFolder: folderPath,
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
                : folderName);
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
      final slotMap = _buildSlotAssignmentsForSingleFolder(
        folderPath: folderPath,
        videoFiles: videoFiles,
        inventory: inventory,
        cleanTitle: cleanTitle,
      );
      final workId = '$sourceId::$folderPath';
      final variants = _buildVariants(
        sourceId: sourceId,
        workId: workId,
        files: allFiles,
        folderTitle: cleanTitle,
        seasonHint: inventory.season,
        assetScopesByPath: foldedExtras.assetScopeByPath,
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

      result.add(
        GroupedWorkFolder(
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
        ),
      );
    }

    return result;
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

    void addSingle(String raw) {
      final clean = raw
          .replaceAll(RegExp(r'\{[^}]*\}'), ' ')
          .replaceAll(RegExp(r'\(\s*(?:19|20)\d{2}\s*\)'), ' ')
          .replaceAll(RegExp(r'（\s*(?:19|20)\d{2}\s*）'), ' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      if (clean.isEmpty) return;
      final key = clean
          .toLowerCase()
          .replaceAll(RegExp(r'[\s:：\-～~·・･/—]+'), '');
      if (key.isEmpty || !seen.add(key)) return;
      out.add(clean);
    }

    void add(String raw, {bool expandVariants = true}) {
      addSingle(raw);
      if (!expandVariants) return;
      for (final rv in _romanNumeralVariants(raw)) {
        addSingle(rv);
      }
      for (final arc in legacy.WorkMatcher.expandRomajiArcQueries(raw)) {
        addSingle(arc);
      }
    }

    // Cross-provider rescue: Bangumi 的官方中日文名用于救回本地同义译名在 TMDB 搜索 0 命中的条目。
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
    for (var i = 0; i < hints.length; i++) {
      final hint = hints[i];
      add(hint, expandVariants: i == 0);
      final strippedPart = WorkSeason.withoutPart(hint);
      if (strippedPart != hint) add(strippedPart, expandVariants: false);
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

    for (final fh in inv.fileHints) {
      add(fh);
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
      for (var idx = parts.length - 2; idx >= 0 && idx >= parts.length - 3; idx--) {
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
    for (final base in [
      ...inv.titleHints.take(2),
      ...inv.fileHints.take(2),
    ]) {
      final beforePunct = base
          .split(RegExp(r'[:：～~—/·・･]+'))
          .first
          .trim();
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

    return out.take(10).toList(growable: false);
  }

  /// 提取高置信度目录括号年份提示（用于 TMDB 首波精确年份检索）。
  static int? extractSearchYear(GroupedWorkFolder folder) {
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
  }) evaluateBangumiMatch(
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
        : scored
              .where((s) => s.subject.id == result.candidate!.id)
              .firstOrNull;
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
    final matchCandidates = [
      for (final c in candidates) _toMatchCandidate(c),
    ];

    final result = legacy.WorkMatcher.tmdb(
      inv,
      matchCandidates,
      bangumi: bgmEval.rawResult,
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

    // 防跨库误拼：高置信主库与存在年份冲突的中置信副库不配对。
    if (effectiveBestTmdb != null && effectiveBestBgm != null) {
      final compatible = _providersCompatible(
        effectiveBestTmdb.detail,
        matchedSeason,
        effectiveBestBgm.subject,
      );
      if (tmdbTier == legacy.MatchTier.high &&
          bgmEval.tier == legacy.MatchTier.medium &&
          !compatible) {
        effectiveBestBgm = null;
      } else if (bgmEval.tier == legacy.MatchTier.high &&
          tmdbTier == legacy.MatchTier.medium &&
          !compatible) {
        effectiveBestTmdb = null;
        tmdbTier = legacy.MatchTier.none;
        matchedSeason = null;
      }
    }

    if (effectiveBestTmdb == null && effectiveBestBgm != null) {
      final bgmHigh = bgmEval.tier == legacy.MatchTier.high;
      return MatchDecision(
        level: bgmHigh ? MatchLevel.autoBind : MatchLevel.reviewRequired,
        best: top5.first,
        topCandidates: top5,
        bestBangumi: effectiveBestBgm,
        topBangumiCandidates: bgmEval.topCandidates,
        primaryReason: bgmHigh ? 'bangumi_high_confidence' : 'bangumi_review',
        reviewReason: bgmHigh
            ? null
            : '仅命中 Bangumi 候选，TMDB 候选分歧较大请复核',
      );
    }

    final high =
        tmdbTier == legacy.MatchTier.high ||
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
        primaryReason: 'high_confidence',
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
    return WorkSeason.resolve(
      <String, Object?>{
        'title': folder.folderName,
        'folder': folder.folderRelativePath,
        'year': folder.year,
        'season': folder.seasonHint,
      },
      rawSeasons,
    );
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
        title: bgmTitle ?? (inv.title.isNotEmpty ? inv.title : folder.folderName),
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
            !_genericSeasonName.hasMatch(normLocal.substring(normTmdb.length))) {
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
    );
  }

  static DirectoryInventory _effectiveInventory(GroupedWorkFolder folder) {
    if (folder.inventory != null) {
      return folder.inventory!;
    }
    final mainItems = <LogicalItem>[];
    final byEp = <int, LogicalItem>{};
    for (final ep in folder.mainEpisodeNumbers) {
      final item = LogicalItem('e::$ep', folder.cleanTitle, ep, folder.seasonHint);
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

  static Map<String, EpisodeSlotAssignment> _buildSlotAssignmentsForSingleFolder({
    required String folderPath,
    required List<ScannedFileInput> videoFiles,
    required DirectoryInventory inventory,
    required String cleanTitle,
  }) {
    final slotMap = <String, EpisodeSlotAssignment>{};
    final relToRaw = <String, ScannedFileInput>{
      for (final v in videoFiles) _stripFolderPrefix(v.relativePath, folderPath): v,
    };

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
        final epNum = item.episode ?? parsed.episode;
        final seasonNum =
            (item.season != null && item.season! > 0)
            ? item.season!
            : ((inventory.season != null && inventory.season! > 0)
                  ? inventory.season!
                  : (parsed.season > 0 ? parsed.season : 1));
        slotMap[raw.relativePath] = EpisodeSlotAssignment(
          category: EpisodeCategory.main,
          seasonNumber: seasonNum,
          episodeNumber: epNum,
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
      final tag = promoMatch.group(1)!.toUpperCase().replaceAll(
        RegExp(r'[ ._-]+'),
        '',
      );
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
    final normShort = (shortTitle ?? '')
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9\u3040-\u9fff]+'), '');
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
    final volSuffix = _extractVolumeOrDiscSuffix(fileName, relativePath)
        ?.toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '');
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
  }) {
    final out = <MediaVariant>[];
    for (final file in files) {
      final parsed = file.assetKind == AssetKind.video
          ? BdripParser.parseFileName(
              file.fileName,
              relativePath: file.relativePath,
              folderTitle: folderTitle,
              folderSeasonHint: seasonHint,
            )
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
  }) {
    final segments = relativePath
        .replaceAll('\\', '/')
        .split('/')
        .where((s) => s.isNotEmpty)
        .toList();
    if (segments.length <= 1) return '';
    final parentSegments = segments.sublist(0, segments.length - 1);

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
    List<SubWorkCluster> preview,
  ) {
    if (preview.length < 2) return false;
    final hasUnbound = preview.any((c) => c.inventory.tmdbId == null);
    if (!hasUnbound) return false;
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
    for (final seg in explicitSegments) {
      final clean = seg.trim();
      if (clean.isNotEmpty && !extraQueries.contains(clean)) {
        extraQueries.add(clean);
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
    if (cluster.inventory.folderMovieMarker || cluster.inventory.fileMovieMarker) {
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
    if (ty == null || by == null) return true;
    if ((ty - by).abs() <= 2) return true;
    if (tmdb.mediaType == TmdbMediaType.tv &&
        tmdb.year != null &&
        tmdb.year! <= by + 1) {
      return true;
    }
    return false;
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
            DirectoryAnalyzer.splitSeasonSuffix(bgmTitle, isSeries: true).season ??
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
      'Ⅰ': 'I', 'Ⅱ': 'II', 'Ⅲ': 'III', 'Ⅳ': 'IV', 'Ⅴ': 'V',
      'Ⅵ': 'VI', 'Ⅶ': 'VII', 'Ⅷ': 'VIII', 'Ⅸ': 'IX', 'Ⅹ': 'X',
      'ⅰ': 'I', 'ⅱ': 'II', 'ⅲ': 'III', 'ⅳ': 'IV', 'ⅴ': 'V',
      'ⅵ': 'VI', 'ⅶ': 'VII', 'ⅷ': 'VIII', 'ⅸ': 'IX', 'ⅹ': 'X',
    };
    const unicodeToArabic = <String, String>{
      'Ⅰ': '1', 'Ⅱ': '2', 'Ⅲ': '3', 'Ⅳ': '4', 'Ⅴ': '5',
      'Ⅵ': '6', 'Ⅶ': '7', 'Ⅷ': '8', 'Ⅸ': '9', 'Ⅹ': '10',
      'ⅰ': '1', 'ⅱ': '2', 'ⅲ': '3', 'ⅳ': '4', 'ⅴ': '5',
      'ⅵ': '6', 'ⅶ': '7', 'ⅷ': '8', 'ⅸ': '9', 'ⅹ': '10',
    };
    const asciiToArabic = <String, String>{
      'II': '2', 'III': '3', 'IV': '4', 'V': '5',
      'VI': '6', 'VII': '7', 'VIII': '8', 'IX': '9', 'X': '10',
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
