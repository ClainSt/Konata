part of 'scrape_rules.dart';

/// 对检索到的 Bangumi 候选集执行无损 `WorkMatcher.bangumi` 打分，返回分级结果与最佳候选明细。
({
  MatchTier tier,
  ScoredBangumiCandidate? best,
  List<ScoredBangumiCandidate> topCandidates,
  MatchResult rawResult,
})
evaluateBangumiMatch(
  GroupedWorkFolder folder,
  List<BangumiSubjectCandidate> candidates,
) {
  if (candidates.isEmpty) {
    return (
      tier: MatchTier.none,
      best: null,
      topCandidates: const [],
      rawResult: MatchResult.empty,
    );
  }
  final inv = folder.matchingInventory;
  final byId = <int, BangumiSubjectCandidate>{
    for (final c in candidates) c.id: c,
  };
  final result = WorkMatcher.bangumi(inv, [
    for (final c in candidates) c.toMatchCandidate(),
  ], ignoreBangumiMarker: folder.ignoreExplicitTmdb);
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
MatchDecision evaluateMatch(
  GroupedWorkFolder folder,
  List<TmdbWorkDetail> candidates, {
  List<BangumiSubjectCandidate> bangumiCandidates = const [],
  BangumiTmdbIndex? mappingIndex,
}) {
  final inv = folder.matchingInventory;
  final bgmEval = evaluateBangumiMatch(folder, bangumiCandidates);

  if (candidates.isEmpty) {
    if (bgmEval.best != null && bgmEval.tier != MatchTier.none) {
      return MatchDecision(
        level: bgmEval.tier == MatchTier.high
            ? MatchLevel.autoBind
            : MatchLevel.reviewRequired,
        topCandidates: const [],
        bestBangumi: bgmEval.best,
        topBangumiCandidates: bgmEval.topCandidates,
        primaryReason: bgmEval.tier == MatchTier.high
            ? 'bangumi_only_high'
            : 'bangumi_only_review',
        reviewReason: bgmEval.tier == MatchTier.high
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
    for (final c in candidates) MatchCandidate.fromTmdb(c),
  ];
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
  var mappedTargets = bgmEval.tier == MatchTier.high
      ? bangumiMappedTmdbTargets(
          bgmEval.best?.subject,
          eligibleMappedKeys,
          mappingIndex: mappingIndex,
        )
      : const <BangumiTmdbTarget>[];
  // 中置信 Bangumi 特别篇/OVA/独立剧场版条目（含 1~2 集电视特别篇或单文件独立剧场版）
  // 若经离线映射精确指向候选池内已有母剧的 Season 0 动画条目或独立动画电影，则借该映射补齐跨源锚定，避免漏绑待复核。
  if (mappedTargets.isEmpty &&
      bgmEval.tier == MatchTier.medium &&
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
    final seqMatch = _reHot28.firstMatch(inv.title);
    final localSeqDigit = seqMatch?.group(1);
    final isSequelCorroboratedTv =
        localSeqDigit != null &&
        bgmSubj.displayTitle.contains(localSeqDigit) &&
        inv.shape == WorkShape.series;
    if (isSpecialLocalOrBgm ||
        isExactSpecialOrOna ||
        isMultiPartMovie ||
        isSequelCorroboratedTv) {
      mappedTargets =
          bangumiMappedTmdbTargets(
                bgmSubj,
                eligibleMappedKeys,
                mappingIndex: mappingIndex,
              )
              .where((t) {
                final detail = byKey[t.key];
                if (detail == null || !detail.genreIds.contains(16)) {
                  return false;
                }
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
      final localPrefixSeeds = <String>[inv.title, ...inv.fileHints.take(1)]
          .map((s) => s.toLowerCase().replaceAll(_reHot29, ' ').trim())
          .where((s) => s.length >= 6 && s.split(' ').length >= 2)
          .toList(growable: false);
      final candNormSpaced =
          <String>[
                soleTv.title,
                if (soleTv.originalTitle != null) soleTv.originalTitle!,
                ...soleTv.aliases,
              ]
              .map((s) => s.toLowerCase().replaceAll(_reHot29, ' ').trim())
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
        final corroborated =
            bangumiMappedTmdbTargets(
                  bgmTop.subject,
                  eligibleMappedKeys,
                  mappingIndex: mappingIndex,
                )
                .where((t) {
                  if (t.key != soleKey || t.season == null || t.season! <= 0) {
                    return false;
                  }
                  return soleTv.seasons.any(
                    (s) =>
                        s.seasonNumber == t.season &&
                        s.episodeCount == inv.episodeCount,
                  );
                })
                .toList(growable: false);
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
  // 不让映射表里遗留的母剧 TV 映射加权（+20）反压真正的独立剧场版；
  // 若 Bangumi 明确为非剧场版（TV/OVA/OAD/WEB/ONA）且目录/文件名均无电影标记，
  // 则不把单文件弱猜测 `isMovieHint` 当作剧场版。
  final expectsMovie = expectsStandaloneMovie(folder, bgmEval.best?.subject);
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
        final mNorm = WorkMatcher.canonTitleKey(mn);
        if (mNorm.length < 4) return false;
        return localRef.any((lr) {
          final lNorm = WorkMatcher.canonTitleKey(lr);
          return lNorm.length >= 4 &&
              WorkMatcher.similarity(lNorm, mNorm) >= 0.80;
        });
      });
    });
    if (hasMatchingStandaloneMovie) {
      primaryMapped = null;
    }
  }
  final mappedSeasonHint = isMultiSeasonBundle ? null : primaryMapped?.season;

  final result = WorkMatcher.tmdb(
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
  var effectiveBestTmdb = result.tier == MatchTier.none ? null : bestTmdb;
  var effectiveBestBgm = bgmEval.tier == MatchTier.none ? null : bgmEval.best;

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
    if (!compatible && (bgmEval.tier == MatchTier.high || nonAnimTmdb)) {
      effectiveBestTmdb = null;
      tmdbTier = MatchTier.none;
      matchedSeason = null;
    } else if (tmdbTier == MatchTier.high &&
        bgmEval.tier == MatchTier.medium &&
        !compatible) {
      effectiveBestBgm = null;
    }
  }

  // Bangumi 高置信时以 Bangumi 条目锚定 TMDB：候选任一名称与 Bangumi 中/日文名或别名归一化后完全一致
  // 且年份吻合即视为同一作品。适用于 TMDB 因分差过小或跨源校验被整体放弃，以及当前优胜条目
  // 只是把单独上架的特别篇归入母剧第 0 季、而另有名称完全一致的专属条目两种情形；
  // 当前优胜条目已对上母剧正片季时不覆盖（续季常另有同名的低质量重复条目）。
  var anchoredByBangumi = false;
  if (effectiveBestBgm != null && bgmEval.tier == MatchTier.high) {
    final bgmSubject = effectiveBestBgm.subject;
    final current = effectiveBestTmdb;
    final anchored = _bangumiAnchoredTmdb(
      scoredList,
      bgmSubject,
      mappedKeys,
      inv: inv,
    );
    final anchoredIsOrphanMovieVsParentTv =
        anchored != null &&
        current != null &&
        anchored.detail.mediaType == TmdbMediaType.movie &&
        !expectsMovie &&
        (anchored.detail.backdropPath?.trim().isEmpty ?? true) &&
        (anchored.detail.voteCount ?? 0) < 20 &&
        current.detail.mediaType == TmdbMediaType.tv &&
        matchedSeason == 0 &&
        (current.detail.backdropPath?.trim().isNotEmpty ?? false);
    if (anchored != null &&
        !anchoredIsOrphanMovieVsParentTv &&
        (current == null ||
            (!identical(anchored, current) &&
                current.detail.mediaType == TmdbMediaType.tv &&
                matchedSeason == 0 &&
                !mappedKeys.contains(_detailKey(current.detail)) &&
                !_tmdbNamesMatchBangumi(current.detail, bgmSubject)))) {
      effectiveBestTmdb = anchored;
      tmdbTier = MatchTier.medium;
      matchedSeason = anchored.matchedSeason;
      anchoredByBangumi = true;
    } else if (current == null) {
      final parent = _bangumiParentSeriesTmdb(scoredList, bgmSubject, inv);
      if (parent != null) {
        effectiveBestTmdb = parent;
        tmdbTier = MatchTier.medium;
        matchedSeason = parent.matchedSeason;
        anchoredByBangumi = true;
      }
    }
  }

  // 非剧场版电视特别篇/OVA（如 Bangumi 标注 TV/OVA 且无电影标记）若被 TMDB 上无横版背景图的
  // 低人气孤岛电影条目抢占，优先归入候选池中带 Season 0 与横版背景图的母剧 TV 正主。
  if (effectiveBestTmdb != null && effectiveBestBgm != null) {
    final parentTvSpecial = _bangumiParentSpecialTvForOrphanMovie(
      scored: scoredList,
      current: effectiveBestTmdb,
      bgm: effectiveBestBgm.subject,
      folder: folder,
      mappedKeys: mappedKeys,
    );
    if (parentTvSpecial != null) {
      effectiveBestTmdb = parentTvSpecial;
      matchedSeason = 0;
      if (tmdbTier == MatchTier.none) {
        tmdbTier = MatchTier.medium;
      }
      anchoredByBangumi = true;
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

  // 当 Bangumi 明确指向短篇 OVA/OAD（如 2 话《创星的大天使》）且被绑定至长篇母剧 TV（如 S1=26 话的《创圣的大天使》）
  // 但尚未定季或被默认归到 S1 时，若母剧具备足以容纳本地集数的 Season 0，强制归入 Season 0，防止回退成 S1 集名与伪季号。
  if (effectiveBestTmdb != null &&
      (matchedSeason == null || matchedSeason == 1) &&
      folder.seasonHint == null &&
      !isMultiSeasonBundle &&
      effectiveBestTmdb.detail.mediaType == TmdbMediaType.tv &&
      effectiveBestBgm != null) {
    final bgmSubj = effectiveBestBgm.subject;
    final bgmPlat = (bgmSubj.platform?.trim() ?? '').toUpperCase();
    final bgmEps = bgmSubj.totalEpisodes ?? 0;
    final isExplicitOvaBgm =
        bgmPlat == 'OVA' || bgmPlat == 'OAD' || bgmSubj.isSpecialFormat;
    final isShortOvaBgm =
        isExplicitOvaBgm ||
        (matchedSeason == null &&
            inv.episodeCount > 0 &&
            inv.episodeCount <= 4 &&
            bgmEps > 0 &&
            bgmEps <= 4);
    final s0 = effectiveBestTmdb.detail.seasons
        .where((s) => s.seasonNumber == 0)
        .firstOrNull;
    final s1 = effectiveBestTmdb.detail.seasons
        .where((s) => s.seasonNumber == 1)
        .firstOrNull;
    if (isShortOvaBgm &&
        s0 != null &&
        s0.episodeCount >= inv.episodeCount &&
        s1 != null &&
        s1.episodeCount >= 10 &&
        (inv.episodeCount == 0 || inv.episodeCount <= 4) &&
        (bgmEps == 0 || bgmEps <= 4)) {
      matchedSeason = 0;
    }
  }

  if (effectiveBestTmdb == null && effectiveBestBgm != null) {
    final bgmHigh = bgmEval.tier == MatchTier.high;
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
      tmdbTier == MatchTier.medium &&
      effectiveBestTmdb != null &&
      bgmEval.tier != MatchTier.high &&
      bgmTop != null &&
      bgmTop.score >= _crossConfirmBangumiScore &&
      _hasStrongTitleAndYear(effectiveBestTmdb.reasons) &&
      _providersCompatible(
        effectiveBestTmdb.detail,
        matchedSeason,
        bgmTop.subject,
      );

  final high =
      tmdbTier == MatchTier.high ||
      crossConfirmed ||
      (effectiveBestBgm != null && bgmEval.tier == MatchTier.high);

  if (tmdbTier == MatchTier.none && effectiveBestBgm == null) {
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
double scoreSearchHitPreview(GroupedWorkFolder folder, TmdbSearchResult hit) {
  final inv = folder.matchingInventory;
  final cand = MatchCandidate(
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
  return WorkMatcher.tmdb(
        inv,
        [cand],
        ignoreTmdbMarker: folder.ignoreExplicitTmdb,
      ).ranking.firstOrNull?.score ??
      0;
}

/// 显式 `{tmdb-N}` 未标注类型而剧集与电影两侧同号条目都存在时（两类 ID 空间相互重叠），
/// 忽略目录 ID 标记、按标题/年份/正片形态为两侧打分择优；分数相同时回退目录的电影/剧集提示。
TmdbWorkDetail chooseExplicitTypeCandidate(
  GroupedWorkFolder folder, {
  required TmdbWorkDetail tv,
  required TmdbWorkDetail movie,
}) {
  final ranking = WorkMatcher.tmdb(folder.matchingInventory, [
    MatchCandidate.fromTmdb(tv),
    MatchCandidate.fromTmdb(movie),
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

List<String> _normalizeReasonsToCodes(List<String> rawReasons) {
  final out = <String>[];
  final seen = <String>{};
  void add(String code) {
    if (seen.add(code)) out.add(code);
  }

  final scoredPrefixRe = _reHot40;
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

String _derivePrimaryReviewCode(List<ScoredTmdbCandidate> top5) {
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

String _buildChineseReviewSummary({
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

bool _providersCompatible(
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
      if (WorkMatcher.similarity(bn, tn) >= 0.45) {
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
ScoredTmdbCandidate? _bangumiAnchoredTmdb(
  List<ScoredTmdbCandidate> scored,
  BangumiSubjectCandidate bgm,
  List<String> mappedKeys, {
  DirectoryInventory? inv,
}) {
  final bgmYear = bgm.year;
  if (bgmYear == null) return null;
  final disallowSingleMovieAnchor =
      inv != null &&
      inv.shape == WorkShape.series &&
      inv.episodeCount >= 4 &&
      !inv.folderMovieMarker &&
      !inv.fileMovieMarker;

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
          !(disallowSingleMovieAnchor &&
              c.detail.mediaType == TmdbMediaType.movie) &&
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

final RegExp _seasonOrPartSuffix = RegExp(
  r'^(?:第?[0-9一二三四五六七八九十]+(?:季|期|部分|部|章|クール)|最终季.*|finalseason.*|'
  r'season[0-9]+|s[0-9]+|[0-9]+(?:st|nd|rd|th)season|part[0-9]+|volume[0-9]+|vol[0-9]+)$',
  caseSensitive: false,
);

/// Bangumi 高置信条目是某部 TMDB 剧集的续季、分部或篇章（Bangumi 名称 = 剧集名称 + 后缀）时绑定母剧
/// （TMDB 常把续季并入同一剧集条目，以累计集号续接）。满足该关系的剧集候选中取评分人数最多者为正主
/// （同名的零评分新建重复条目让位），且其得分不得比全体第一名低超过 10 分。
/// 仅在 TMDB 已被整体放弃时使用；剧场版条目不走此路径，避免把独立电影错挂到母剧。
/// 后缀须为季/分部标记，或目录本身是多集正片（续作篇章、OVA 系列）。
ScoredTmdbCandidate? _bangumiParentSeriesTmdb(
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

/// 依据显式媒体标记与 Bangumi 放送平台，判断该目录是否真正预期匹配为独立剧场版（Movie）。
///
/// 仅凭单文件形态推演出的 `folder.isMovieHint` 属于弱猜测：若 Bangumi 明确标注为
/// `TV`/`OVA`/`OAD`/`WEB`/`ONA` 等非剧场版形态、且目录与文件名均无显式剧场版标记，
/// 则不应将其视作剧场版去反压母剧 `Season 0` 映射。
bool expectsStandaloneMovie(
  GroupedWorkFolder folder,
  BangumiSubjectCandidate? bgmSubject,
) {
  final bgmPlatform = (bgmSubject?.platform?.trim() ?? '').toUpperCase();
  if (bgmPlatform == '剧场版' || bgmPlatform == 'MOVIE') {
    return true;
  }
  final inv = folder.inventory;
  if (folder.explicitMediaType == TmdbMediaType.movie ||
      (inv?.folderMovieMarker ?? false) ||
      (inv?.fileMovieMarker ?? false)) {
    return true;
  }
  if (bgmSubject != null &&
      const {'TV', 'OVA', 'OAD', 'WEB', 'ONA'}.contains(bgmPlatform)) {
    return false;
  }
  return folder.isMovieHint;
}

/// 当 Bangumi 明确为非剧场版（TV/OVA/OAD/WEB/ONA）且目录/文件均无电影标记时，
/// 若当前优胜条目是缺少横版背景图的低人气 TMDB 孤岛电影，
/// 即使离线映射指向该孤岛电影，也优先在候选池中回退匹配带 `Season 0` 与横版背景图的母剧 TV 正主。
ScoredTmdbCandidate? _bangumiParentSpecialTvForOrphanMovie({
  required List<ScoredTmdbCandidate> scored,
  required ScoredTmdbCandidate current,
  required BangumiSubjectCandidate bgm,
  required GroupedWorkFolder folder,
  required List<String> mappedKeys,
}) {
  if (current.detail.mediaType != TmdbMediaType.movie) return null;
  if (expectsStandaloneMovie(folder, bgm)) return null;
  final bgmPlatform = (bgm.platform?.trim() ?? '').toUpperCase();
  if (!const {'TV', 'OVA', 'OAD', 'WEB', 'ONA'}.contains(bgmPlatform)) {
    return null;
  }
  final currentHasBackdrop =
      current.detail.backdropPath?.trim().isNotEmpty ?? false;
  if (currentHasBackdrop) return null;
  final currentVotes = current.detail.voteCount ?? 0;
  if (currentVotes >= 20) return null;

  final bgmYear = bgm.year ?? folder.year;
  final bgmNorms = <String>[
    for (final raw in [bgm.nameCn, bgm.name, ...bgm.aliases])
      DirectoryAnalyzer.normalize(raw),
  ].where((s) => s.length >= 4).toList(growable: false);
  if (bgmNorms.isEmpty) return null;

  bool isParentTvOf(TmdbWorkDetail d) {
    final tmdbNorms = <String>{
      DirectoryAnalyzer.normalize(d.title),
      if (d.originalTitle != null)
        DirectoryAnalyzer.normalize(d.originalTitle!),
    }..removeWhere((e) => e.length < 4);
    for (final bn in bgmNorms) {
      for (final tn in tmdbNorms) {
        if (bn.length > tn.length && bn.startsWith(tn)) {
          return true;
        }
      }
    }
    return false;
  }

  final parents = <ScoredTmdbCandidate>[
    for (final c in scored)
      if (c.detail.mediaType == TmdbMediaType.tv &&
          !c.reasons.contains('stub_entry') &&
          (c.detail.backdropPath?.trim().isNotEmpty ?? false) &&
          c.detail.seasons.any((s) => s.seasonNumber == 0) &&
          (bgmYear == null ||
              c.detail.year == null ||
              c.detail.year! <= bgmYear + 1) &&
          (c.detail.voteCount ?? 0) > currentVotes &&
          isParentTvOf(c.detail))
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
const double _crossConfirmBangumiScore = 50;

const Set<String> _hardConflictReasonCodes = {
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
bool _hasStrongTitleAndYear(List<String> reasons) =>
    (reasons.contains('exact_title') ||
        reasons.contains('high_title_similarity')) &&
    (reasons.contains('year_exact') || reasons.contains('year_near')) &&
    !reasons.any(_hardConflictReasonCodes.contains);

String _detailKey(TmdbWorkDetail d) => '${d.mediaType.name}:${d.tmdbId}';

/// 查询 Bangumi 条目经离线映射表（优先二进制索引，回退静态 Wikidata）得到、
/// 且已在 [availableKeys]（`类型:ID`）中的 TMDB 目标，按放送平台、季信息与来源权威度排序。
List<BangumiTmdbTarget> bangumiMappedTmdbTargets(
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
List<String> bangumiMappedTmdbKeys(
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
bool _tmdbNamesMatchBangumi(TmdbWorkDetail tmdb, BangumiSubjectCandidate bgm) {
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

final RegExp _reHot28 = RegExp(r'(?<!\d)([2-9])(?!\d)');

final RegExp _reHot40 = RegExp(r'^([+-]?\d+)\s+(.+)$');
