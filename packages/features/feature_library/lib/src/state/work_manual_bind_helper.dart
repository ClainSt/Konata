import 'package:engine_scraping/engine_scraping.dart';

import '../data/library_models.dart';

/// 作品手动混搭（Bangumi × TMDB）与纯 Bangumi 绑定执行辅助器（零 `Riverpod`）。
///
/// 负责双源/单源元数据拉取、分集与特典槽位重建、人工锁定落盘及系列关系自动重算。
final class WorkManualBindHelper {
  /// 构造手动绑定执行辅助器。
  const WorkManualBindHelper({
    required this.repository,
    required this.httpClient,
    this.tmdbServiceOverride,
    this.bangumiServiceOverride,
  });

  /// 媒体库持久化仓储。
  final LibraryRepository repository;

  /// 受控 HTTP 客户端端口。
  final KonataHttpClientPort httpClient;

  /// 可选测试替换用 TMDB 客户端。
  final TmdbService? tmdbServiceOverride;

  /// 可选测试替换用 Bangumi 客户端。
  final BangumiService? bangumiServiceOverride;

  /// 执行 Bangumi 独立条目 × TMDB 母系列双源混合绑定并写入永久人工锁。
  Future<Work> executeHybridBind({
    required String workId,
    required HybridMatchRequest request,
  }) async {
    final existing = await repository.findWorkById(workId);
    if (existing == null) {
      throw StateError('作品不存在: $workId');
    }

    final bgm = bangumiServiceOverride ?? BangumiService(httpClient: httpClient);
    final tmdb = tmdbServiceOverride ?? TmdbService(httpClient: httpClient);

    var subject = request.bangumiSubject;
    if (subject.score == null ||
        subject.summary == null ||
        subject.summary!.trim().isEmpty ||
        subject.posterUrl == null) {
      try {
        final detail = await bgm.getSubjectDetail(
          subject.id,
          priority: RequestPriority.interactive,
        );
        if (detail != null) subject = detail;
      } catch (_) {}
    }

    final tmdbDetail = request.tmdbDetail;
    TmdbSeasonDetail? seasonDetail;
    if (tmdbDetail.mediaType == TmdbMediaType.tv) {
      try {
        seasonDetail = await tmdb.getSeasonDetail(
          tmdbDetail.tmdbId,
          request.tmdbSeasonNumber,
          priority: RequestPriority.interactive,
        );
      } catch (_) {
        seasonDetail = null;
      }
    }

    var bgmEpisodes = const <BangumiEpisodeEntry>[];
    try {
      bgmEpisodes = await bgm.getSubjectEpisodes(
        subject.id,
        type: null,
        priority: RequestPriority.interactive,
      );
    } catch (_) {
      bgmEpisodes = const <BangumiEpisodeEntry>[];
    }

    final updated = _buildHybridWorkEntity(
      existing: existing,
      subject: subject,
      tmdbDetail: tmdbDetail,
      seasonDetail: seasonDetail,
      tmdbSeasonNumber: request.tmdbSeasonNumber,
    );
    await repository.upsertWork(updated);
    await repository.clearScrapeCandidates(workId);

    await _syncHybridEpisodesAndVariants(
      work: updated,
      subject: subject,
      tmdbDetail: tmdbDetail,
      seasonDetail: seasonDetail,
      bgmEpisodes: bgmEpisodes,
      tmdbSeasonNumber: request.tmdbSeasonNumber,
      startEpisodeNumber: request.startEpisodeNumber,
      customSlotsByVariantId: request.customSlotsByVariantId,
    );

    try {
      await SeriesAutoLinker.reconcileAll(
        repository: repository,
        bangumiService: bgm,
        tmdbCollectionIdByTmdbId: {
          if (tmdbDetail.collectionId != null && tmdbDetail.collectionId! > 0)
            tmdbDetail.tmdbId: tmdbDetail.collectionId!,
        },
        focusBangumiIds: {
          if ((updated.bangumiId ?? 0) > 0) updated.bangumiId!,
        },
        focusWorkIds: {updated.id},
      );
    } catch (_) {}

    return (await repository.findWorkById(workId)) ?? updated;
  }

  /// 将作品绑定到纯 Bangumi 条目（不强绑 TMDB），并静默尝试补齐高清背景图。
  Future<Work> executeBangumiOnlyBind({
    required String workId,
    required BangumiSubjectCandidate bangumiSubject,
  }) async {
    final existing = await repository.findWorkById(workId);
    if (existing == null) {
      throw StateError('作品不存在: $workId');
    }

    final bgm = bangumiServiceOverride ?? BangumiService(httpClient: httpClient);
    final tmdb = tmdbServiceOverride ?? TmdbService(httpClient: httpClient);

    var subject = bangumiSubject;
    if (subject.score == null ||
        subject.summary == null ||
        subject.summary!.trim().isEmpty ||
        subject.posterUrl == null) {
      try {
        final detail = await bgm.getSubjectDetail(
          subject.id,
          priority: RequestPriority.interactive,
        );
        if (detail != null) subject = detail;
      } catch (_) {}
    }

    var bgmEpisodes = const <BangumiEpisodeEntry>[];
    try {
      bgmEpisodes = await bgm.getSubjectEpisodes(
        subject.id,
        type: null,
        priority: RequestPriority.interactive,
      );
    } catch (_) {
      bgmEpisodes = const <BangumiEpisodeEntry>[];
    }

    var updated = existing.copyWith(
      bangumiId: subject.id,
      title: subject.displayTitle,
      originalTitle:
          subject.name.isNotEmpty ? subject.name : existing.originalTitle,
      year: subject.year ?? existing.year,
      overview: (subject.summary != null && subject.summary!.trim().isNotEmpty)
          ? subject.summary!.trim()
          : existing.overview,
      posterPath: subject.posterUrl ?? existing.posterPath,
      posterFallback: existing.posterFallback ?? subject.posterUrl,
      bangumiPosterPath: subject.posterUrl ?? existing.bangumiPosterPath,
      bangumiScore: subject.score ?? existing.bangumiScore,
      clearLogoPath: true,
      isManualLocked: true,
      metadataLocked: true,
      posterLocked: subject.posterUrl != null || existing.posterLocked,
      scrapeStatus: ScrapeStatus.matched,
      clearReviewReason: true,
    );

    if (!updated.backdropLocked &&
        (updated.backdropPath == null || updated.backdropPath!.trim().isEmpty)) {
      final silentBackdrop = await _lookupHighConfidenceTmdbBackdrop(
        tmdb: tmdb,
        subject: subject,
        preferTv: existing.tmdbMediaType != TmdbMediaType.movie,
      );
      if (silentBackdrop != null) {
        updated = updated.copyWith(backdropPath: silentBackdrop);
      }
    }

    await repository.upsertWork(updated);
    await repository.clearScrapeCandidates(workId);

    final variants = await repository.getVariantsByWork(workId);
    final videoVariants = _sortedVideoVariants(variants);
    final partitioned = _partitionVideosForManualBind(
      videoVariants,
      workTitle: updated.title,
    );
    final bgmMain = bgmEpisodes
        .where((e) => e.type == 0)
        .toList(growable: false);
    final bgmSource = bgmMain.isNotEmpty
        ? bgmMain
        : bgmEpisodes.where((e) => e.type == 1).toList(growable: false);
    final bgmByEp = <int, BangumiEpisodeEntry>{};
    for (final be in bgmSource) {
      final ep = be.ep?.round();
      final sort = be.sort?.round();
      if (ep != null && ep > 0) bgmByEp.putIfAbsent(ep, () => be);
      if (sort != null && sort > 0 && sort != ep) {
        bgmByEp.putIfAbsent(sort, () => be);
      }
    }

    final usedEpNums = <int>{
      for (final entry in partitioned.mains)
        if (entry.parsed.episode != null && entry.parsed.episode! > 0)
          entry.parsed.episode!,
    };
    var fallbackEp = 1;
    int nextFallback() {
      while (usedEpNums.contains(fallbackEp)) {
        fallbackEp++;
      }
      final allocated = fallbackEp;
      usedEpNums.add(allocated);
      fallbackEp++;
      return allocated;
    }

    for (final entry in partitioned.mains) {
      final parsedEp = entry.parsed.episode;
      final hasExplicit = parsedEp != null && parsedEp > 0;
      final epNum = hasExplicit ? parsedEp : nextFallback();
      final showEpNum = partitioned.mains.length > 1 || hasExplicit;
      final be = bgmByEp[epNum];
      final epTitle = (be != null && be.displayName.isNotEmpty)
          ? be.displayName
          : (showEpNum
                ? '第 ${epNum.toString().padLeft(2, '0')} 话'
                : subject.displayTitle);
      final epId = ScrapeWorkPersister.deterministicId('$workId::bgm:1:$epNum');
      await repository.upsertEpisode(
        Episode(
          id: epId,
          workId: workId,
          seasonNumber: 1,
          episodeNumber: epNum,
          category: EpisodeCategory.main,
          title: epTitle,
          overview: subject.summary,
        ),
      );
      await repository.upsertMediaVariant(
        entry.variant.copyWith(
          episodeId: epId,
          mappingLocked: true,
          workLocked: true,
        ),
      );
    }
    for (final extra in partitioned.extras) {
      await _upsertManualExtraVariant(
        workId: workId,
        workTitle: updated.title,
        variant: extra.variant,
        parsed: extra.parsed,
      );
    }
    await repository.deleteOrphanEpisodes(workId);
    try {
      await SeriesAutoLinker.reconcileAll(
        repository: repository,
        bangumiService: bgm,
        focusBangumiIds: {
          if ((updated.bangumiId ?? 0) > 0) updated.bangumiId!,
        },
        focusWorkIds: {updated.id},
      );
    } catch (_) {}

    return (await repository.findWorkById(workId)) ?? updated;
  }

  Work _buildHybridWorkEntity({
    required Work existing,
    required BangumiSubjectCandidate subject,
    required TmdbWorkDetail tmdbDetail,
    required TmdbSeasonDetail? seasonDetail,
    required int tmdbSeasonNumber,
  }) {
    final bgmOverview = subject.summary?.trim();
    final tmdbOverview = (seasonDetail?.overview ?? tmdbDetail.overview)?.trim();
    final overview = (bgmOverview != null && bgmOverview.isNotEmpty)
        ? bgmOverview
        : (tmdbOverview != null && tmdbOverview.isNotEmpty
              ? tmdbOverview
              : null);
    final poster =
        subject.posterUrl ?? seasonDetail?.posterPath ?? tmdbDetail.posterPath;
    final fallback = seasonDetail?.posterPath ?? tmdbDetail.posterPath;
    final backdrop = existing.backdropLocked
        ? (existing.backdropPath ?? tmdbDetail.backdropPath)
        : (tmdbDetail.backdropPath ?? existing.backdropPath);

    return existing.copyWith(
      tmdbId: tmdbDetail.tmdbId,
      tmdbMediaType: tmdbDetail.mediaType,
      bangumiId: subject.id,
      matchedSeason: tmdbDetail.mediaType == TmdbMediaType.movie
          ? null
          : tmdbSeasonNumber,
      title: subject.displayTitle.isNotEmpty
          ? subject.displayTitle
          : tmdbDetail.title,
      originalTitle:
          subject.name.isNotEmpty ? subject.name : tmdbDetail.originalTitle,
      year:
          subject.year ?? _extractYear(seasonDetail?.airDate) ?? tmdbDetail.year,
      overview: overview,
      posterPath: poster,
      posterFallback: fallback,
      bangumiPosterPath: subject.posterUrl ?? existing.bangumiPosterPath,
      backdropPath: backdrop,
      clearLogoPath: true,
      voteAverage: tmdbDetail.voteAverage,
      bangumiScore: subject.score ?? existing.bangumiScore,
      isManualLocked: true,
      metadataLocked: true,
      posterLocked: true,
      scrapeStatus: ScrapeStatus.matched,
      clearReviewReason: true,
    );
  }

  Future<void> _syncHybridEpisodesAndVariants({
    required Work work,
    required BangumiSubjectCandidate subject,
    required TmdbWorkDetail tmdbDetail,
    required TmdbSeasonDetail? seasonDetail,
    required List<BangumiEpisodeEntry> bgmEpisodes,
    required int tmdbSeasonNumber,
    required int startEpisodeNumber,
    Map<String, ({int season, int episode})>? customSlotsByVariantId,
  }) async {
    final tmdbEpByKey = <String, TmdbEpisodeDetail>{
      for (final ep in seasonDetail?.episodes ?? const <TmdbEpisodeDetail>[])
        '${ep.seasonNumber}:${ep.episodeNumber}': ep,
    };
    final bgmMain = bgmEpisodes
        .where((e) => e.type == 0)
        .toList(growable: false);
    final bgmByEp = <int, BangumiEpisodeEntry>{};
    for (final be in bgmMain) {
      final ep = be.ep?.round();
      final sort = be.sort?.round();
      if (ep != null && ep > 0) bgmByEp.putIfAbsent(ep, () => be);
      if (sort != null && sort > 0 && sort != ep) {
        bgmByEp.putIfAbsent(sort, () => be);
      }
    }

    final variants = await repository.getVariantsByWork(work.id);
    final videoVariants = _sortedVideoVariants(variants);
    final partitioned = _partitionVideosForManualBind(
      videoVariants,
      workTitle: work.title,
      forcedMainVariantIds: customSlotsByVariantId?.keys.toSet() ?? const {},
    );

    final baseEp = startEpisodeNumber <= 0 ? 1 : startEpisodeNumber;
    final useParsedEp =
        tmdbDetail.mediaType == TmdbMediaType.tv &&
        tmdbSeasonNumber > 0 &&
        baseEp == 1 &&
        (customSlotsByVariantId == null || customSlotsByVariantId.isEmpty);
    final usedEps = <int>{
      if (useParsedEp)
        for (final entry in partitioned.mains)
          if (entry.parsed.episode != null && entry.parsed.episode! > 0)
            entry.parsed.episode!,
    };
    var fallbackEp = 1;
    int nextFallback() {
      while (usedEps.contains(fallbackEp)) {
        fallbackEp++;
      }
      final allocated = fallbackEp;
      usedEps.add(allocated);
      fallbackEp++;
      return allocated;
    }

    for (var i = 0; i < partitioned.mains.length; i++) {
      final entry = partitioned.mains[i];
      final variant = entry.variant;
      final override = customSlotsByVariantId?[variant.id];
      final targetSeason =
          override?.season ??
          (tmdbDetail.mediaType == TmdbMediaType.movie ? 1 : tmdbSeasonNumber);
      final parsedEp = entry.parsed.episode;
      final targetEpNum =
          override?.episode ??
          (useParsedEp
              ? ((parsedEp != null && parsedEp > 0) ? parsedEp : nextFallback())
              : (baseEp + i));

      final tmdbEp = tmdbEpByKey['$targetSeason:$targetEpNum'];
      final bgmEp =
          bgmByEp[targetEpNum] ?? (i < bgmMain.length ? bgmMain[i] : null);
      final resolvedTitle =
          _firstNonEmpty(<String?>[
            tmdbEp?.title,
            bgmEp?.displayName,
            partitioned.mains.length == 1 ? subject.displayTitle : null,
            '第 $targetEpNum 话',
          ])!;
      final resolvedOverview = _firstNonEmpty(<String?>[
        tmdbEp?.overview,
        subject.summary,
      ]);
      final resolvedStill = _firstNonEmpty(<String?>[
        tmdbEp?.stillPath,
        tmdbDetail.mediaType == TmdbMediaType.movie
            ? tmdbDetail.backdropPath
            : null,
      ]);

      final epId = ScrapeWorkPersister.deterministicId(
        '${work.id}::hybrid:$targetSeason:$targetEpNum',
      );
      await repository.upsertEpisode(
        Episode(
          id: epId,
          workId: work.id,
          seasonNumber: targetSeason,
          episodeNumber: targetEpNum,
          category: EpisodeCategory.main,
          title: resolvedTitle,
          overview: resolvedOverview,
          stillPath: resolvedStill,
        ),
      );
      await repository.upsertMediaVariant(
        variant.copyWith(
          episodeId: epId,
          mappingLocked: true,
          workLocked: true,
        ),
      );
    }

    for (final extra in partitioned.extras) {
      await _upsertManualExtraVariant(
        workId: work.id,
        workTitle: work.title,
        variant: extra.variant,
        parsed: extra.parsed,
      );
    }
    await repository.deleteOrphanEpisodes(work.id);
  }

  Future<void> _upsertManualExtraVariant({
    required String workId,
    required String workTitle,
    required MediaVariant variant,
    required ParsedBdripRelease parsed,
  }) async {
    final slot = ScrapeDomainAdapter.resolveExtraSlotAssignment(
      fileName: variant.fileName,
      relativePath: variant.relativePath,
      parsed: parsed,
      folderCleanTitle: workTitle,
    );
    final stemKey =
        slot.unnumberedStemKey ??
        SupplementarySubclassifier.buildExtraCanonicalMergeKey(
          fileName: variant.fileName,
          relativePath: variant.relativePath,
          extraType: slot.extraType,
          titleHint: slot.extraTitleHint,
          workTitle: workTitle,
        );
    final epId = ScrapeWorkPersister.deterministicId(
      '$workId::extra:${slot.seasonNumber}:${slot.episodeNumber ?? 'unnumbered'}:${slot.extraType?.name ?? ''}:$stemKey',
    );
    final label = (slot.extraType?.name ?? 'EXTRA').toUpperCase();
    final title = _firstNonEmpty(<String?>[
      slot.fractionalLabel != null && slot.fractionalLabel!.isNotEmpty
          ? 'SP ${slot.fractionalLabel}'
          : null,
      slot.extraTitleHint,
      slot.episodeNumber != null
          ? '$label ${slot.episodeNumber.toString().padLeft(2, '0')}'
          : label,
    ])!;
    await repository.upsertEpisode(
      Episode(
        id: epId,
        workId: workId,
        seasonNumber: slot.seasonNumber,
        episodeNumber: slot.episodeNumber,
        category: EpisodeCategory.extra,
        extraType: slot.extraType,
        title: title,
      ),
    );
    await repository.upsertMediaVariant(
      variant.copyWith(
        episodeId: epId,
        mappingLocked: true,
        workLocked: true,
      ),
    );
  }

  Future<String?> _lookupHighConfidenceTmdbBackdrop({
    required TmdbService tmdb,
    required BangumiSubjectCandidate subject,
    required bool preferTv,
  }) async {
    try {
      final names = <String>[
        if (subject.nameCn.trim().isNotEmpty) subject.nameCn.trim(),
        if (subject.name.trim().isNotEmpty) subject.name.trim(),
      ];
      final queries = <String>[];
      final seen = <String>{};
      for (final raw in names) {
        for (final q in SearchQuerySanitizer.buildBangumiFallbackQueries(raw)) {
          if (seen.add(q.toLowerCase())) queries.add(q);
        }
      }
      if (queries.isEmpty) return null;

      final normBgm = <String>{
        for (final n in names)
          if (DirectoryAnalyzer.normalize(n).isNotEmpty)
            DirectoryAnalyzer.normalize(n),
      };
      for (final q in queries.take(3)) {
        final hits = await tmdb.searchAnime(
          q,
          year: subject.year,
          mediaTypeFilter: preferTv ? TmdbMediaType.tv : null,
          priority: RequestPriority.background,
        );
        for (final hit in hits) {
          final bd = hit.backdropPath?.trim();
          if (bd == null || bd.isEmpty) continue;
          if (hit.genreIds.isNotEmpty && !hit.genreIds.contains(16)) continue;
          if (subject.year != null &&
              hit.year != null &&
              (subject.year! - hit.year!).abs() > 1) {
            continue;
          }
          final hitNorms = <String>[
            DirectoryAnalyzer.normalize(hit.title),
            if (hit.originalTitle != null)
              DirectoryAnalyzer.normalize(hit.originalTitle!),
          ].where((e) => e.isNotEmpty);
          var bestSim = 0.0;
          for (final bn in normBgm) {
            for (final hn in hitNorms) {
              final sim = LegacyWorkMatcher.similarity(bn, hn);
              if (sim > bestSim) bestSim = sim;
            }
          }
          if (bestSim >= 0.72) return bd;
        }
      }
    } catch (_) {}
    return null;
  }

  static List<MediaVariant> _sortedVideoVariants(List<MediaVariant> variants) {
    final list = variants
        .where((v) => v.assetKind == AssetKind.video)
        .toList(growable: false)
      ..sort(
        (a, b) => a.relativePath.toLowerCase().compareTo(
          b.relativePath.toLowerCase(),
        ),
      );
    return list;
  }

  static ({
    List<({MediaVariant variant, ParsedBdripRelease parsed})> mains,
    List<({MediaVariant variant, ParsedBdripRelease parsed})> extras,
  })
  _partitionVideosForManualBind(
    List<MediaVariant> videoVariants, {
    required String workTitle,
    Set<String> forcedMainVariantIds = const <String>{},
  }) {
    final parsedEntries = [
      for (final v in videoVariants)
        (
          variant: v,
          parsed: BdripParser.parseFileName(
            v.fileName,
            relativePath: v.relativePath,
            folderTitle: workTitle,
          ),
        ),
    ];
    final strongMainEps = <int>{
      for (final e in parsedEntries)
        if (e.parsed.category == EpisodeCategory.main &&
            e.parsed.episode != null)
          e.parsed.episode!,
    };
    final mains = <({MediaVariant variant, ParsedBdripRelease parsed})>[];
    final extras = <({MediaVariant variant, ParsedBdripRelease parsed})>[];
    for (final entry in parsedEntries) {
      final forced = forcedMainVariantIds.contains(entry.variant.id);
      final normRel = entry.variant.relativePath.replaceAll('\\', '/');
      final slash = normRel.lastIndexOf('/');
      final parentDir = slash > 0 ? normRel.substring(0, slash) : '';
      final isExtra =
          CloudMediaFileClassifier.classifyAsset(
            parentDir,
            entry.variant.fileName,
            'video',
            videoCount: videoVariants.length,
          ) ==
          'extra';
      final isMain =
          forced ||
          (!isExtra &&
              (entry.parsed.category == EpisodeCategory.main ||
                  shouldRestoreWeakExtraToMain(entry.parsed, strongMainEps)));
      if (isMain) {
        mains.add(entry);
      } else {
        extras.add(entry);
      }
    }
    if (mains.isEmpty && extras.isNotEmpty) {
      return (mains: extras, extras: const []);
    }
    return (mains: mains, extras: extras);
  }

  static String? _firstNonEmpty(List<String?> values) {
    for (final raw in values) {
      final clean = raw?.trim();
      if (clean != null && clean.isNotEmpty) return clean;
    }
    return null;
  }

  static int? _extractYear(String? rawDate) {
    if (rawDate == null || rawDate.isEmpty) return null;
    final match = RegExp(r'(?:19|20)\d{2}').firstMatch(rawDate);
    return match == null ? null : int.tryParse(match.group(0)!);
  }
}
