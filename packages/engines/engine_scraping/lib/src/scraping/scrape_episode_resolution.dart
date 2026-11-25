part of 'scrape_rules.dart';

/// 当 `WorkMatcher` 未显式定季（如单文件显式 `{tmdb-N}` 绑定）时，回退使用 `WorkSeason.resolve` 定季。
int? fallbackResolveSeason({
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
({
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
    final inv = folder.matchingInventory;
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
  final effectiveTmdbPoster = ArtworkRanker.resolveEffectiveTmdbPoster(
    detail: detail,
    seasonDetail: seasonDetail,
    matchedSeason: matchedSeason,
  );
  final tmdbPoster = effectiveTmdbPoster.posterPath;
  final posterFallback = effectiveTmdbPoster.fallbackPosterPath;
  final tmdbPosterSuboptimal = effectiveTmdbPoster.isSuboptimal;

  final tmdbCandidate = MatchCandidate.fromTmdb(detail);
  final bgmMatchCand = bgmSubject?.toMatchCandidate();
  final inv = folder.matchingInventory;

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
          tmdbPosterSuboptimal ||
          (specificSubWork &&
              detail.mediaType == TmdbMediaType.tv &&
              lacksDistinctSeasonPoster));

  final primaryPoster = preferBgmPoster ? bgmPoster : (tmdbPoster ?? bgmPoster);
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
    seasonName: _nonEmpty(seasonDetail?.name) ?? _nonEmpty(summary?.name) ?? '',
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
Map<String, TmdbEpisodeDetail> mapSpecialEpisodes({
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
Set<int> referencedSeasonsToFetch(
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
      if (slot.category == EpisodeCategory.main &&
          slot.seasonNumber > 0 &&
          matchedSeason != 0) {
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

final RegExp _japaneseKanaPattern = RegExp(r'[\u3040-\u30ff]');

final RegExp _leadingSeasonPrefixPattern = RegExp(r'^第\s*\d+\s*季[\s:：\-—·]+');

bool _isPreferredChineseTitle(String s) {
  final trimmed = s.trim();
  return trimmed.isNotEmpty &&
      _hasCjk(trimmed) &&
      !_japaneseKanaPattern.hasMatch(trimmed);
}

bool _lacksChineseTitle(String s) {
  final trimmed = s.trim();
  return trimmed.isEmpty ||
      !_hasCjk(trimmed) ||
      _japaneseKanaPattern.hasMatch(trimmed);
}

String _chooseDisplayTitle({
  required GroupedWorkFolder folder,
  required TmdbWorkDetail detail,
  required int? matchedSeason,
  required String seasonName,
  ScoredBangumiCandidate? bangumiCandidate,
  bool specificSubWork = false,
  bool bangumiSeasonIdentity = false,
}) {
  final inv = folder.matchingInventory;
  final bgmSubject = bangumiCandidate?.subject;
  final bgmTitle = bgmSubject?.displayTitle.trim() ?? '';
  final bgmCnTitle = bgmSubject?.nameCn.trim() ?? '';
  final preferredBgmChinese = _isPreferredChineseTitle(bgmCnTitle)
      ? bgmCnTitle
      : (_isPreferredChineseTitle(bgmTitle) ? bgmTitle : '');
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
  // TMDB 缺少中文译名时会回退为日文假名原名或纯英文名；若 Bangumi 已具备有效中文名则优先采用中文名。
  if (_lacksChineseTitle(baseTitle) &&
      preferredBgmChinese.isNotEmpty &&
      (detail.mediaType == TmdbMediaType.movie ||
          matchedSeason == null ||
          matchedSeason == 1)) {
    baseTitle = preferredBgmChinese;
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
    final rawFolderLeaf = folder.folderRelativePath
        .replaceAll('\\', '/')
        .split('/')
        .where((s) => s.trim().isNotEmpty)
        .lastOrNull;
    final isSpecialCollectionFolder =
        DirectoryAnalyzer.extractSpecialCollectionTitle(folder.cleanTitle) !=
            null ||
        (rawFolderLeaf != null &&
            DirectoryAnalyzer.extractSpecialCollectionTitle(
                  DirectoryAnalyzer.cleanTitle(rawFolderLeaf),
                ) !=
                null);
    final bgmDuplicatesBase =
        bgmTitle.isNotEmpty &&
        DirectoryAnalyzer.normalize(bgmTitle) ==
            DirectoryAnalyzer.normalize(baseTitle);
    if (bgmTitle.isNotEmpty &&
        !(isSpecialCollectionFolder && bgmDuplicatesBase)) {
      return bgmTitle;
    }
    if (seasonName.isNotEmpty && !_genericSeasonName.hasMatch(seasonName)) {
      return seasonName.contains(baseTitle)
          ? seasonName
          : '$baseTitle $seasonName';
    }
    if (isSpecialCollectionFolder) {
      return '$baseTitle 特别篇';
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
      final strippedSeasonName = seasonName
          .replaceFirst(_leadingSeasonPrefixPattern, '')
          .trim();
      final effectiveSeasonName =
          strippedSeasonName.isNotEmpty &&
              !_genericSeasonName.hasMatch(strippedSeasonName)
          ? strippedSeasonName
          : seasonName;
      final normSeason = DirectoryAnalyzer.normalize(effectiveSeasonName);
      final normBase = DirectoryAnalyzer.normalize(baseTitle);
      if (effectiveSeasonName.contains(baseTitle) ||
          (normBase.isNotEmpty && normSeason.startsWith(normBase))) {
        return effectiveSeasonName;
      }
      return '$baseTitle $effectiveSeasonName';
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

bool _isBangumiRemasterIdentity(
  DirectoryInventory inventory,
  MatchCandidate? tmdbPick,
  MatchCandidate? bgmPick,
) =>
    bgmPick != null &&
    _remasterPattern.hasMatch(inventory.title) &&
    _remasterPattern.hasMatch(bgmPick.title) &&
    (tmdbPick == null || !_remasterPattern.hasMatch(tmdbPick.title));

bool _useBangumiSeasonIdentity({
  required DirectoryInventory inventory,
  required MatchCandidate? tmdbPick,
  required MatchCandidate? bgmPick,
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
  final localToBgm = WorkMatcher.similarity(normLocal, normBgm);
  final localToTmdb = normTmdb.isEmpty
      ? 0.0
      : WorkMatcher.similarity(normLocal, normTmdb);
  return localToBgm >= 0.85 && localToBgm >= localToTmdb + 0.25;
}

bool _isSpecificSubWork({
  required DirectoryInventory inventory,
  required MatchCandidate tmdbPick,
  required int? resolvedSeason,
  required MatchCandidate? bgmPick,
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
      WorkMatcher.similarity(normLocal, normBgm) >
          WorkMatcher.similarity(normLocal, normTmdb) + 0.15) {
    return true;
  }
  return false;
}

String? _nonEmpty(String? raw) {
  final trimmed = raw?.trim();
  return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
}
