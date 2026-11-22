import 'dart:developer' as developer;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models/episode.dart';
import '../../domain/models/media_variant.dart';
import '../../domain/models/series_group.dart';
import '../../domain/models/tmdb_models.dart';
import '../../domain/models/work.dart';
import '../../domain/parsing/bdrip_parser.dart';
import '../../domain/repositories/library_repository.dart';
import '../../domain/scraping/bangumi_models.dart';
import '../../domain/scraping/directory_analyzer.dart';
import '../../domain/scraping/search_query_sanitizer.dart';
import '../../domain/scraping/work_matcher.dart';
import '../../infrastructure/network/bangumi_service.dart';
import '../../infrastructure/network/priority_http_scheduler.dart';
import '../../infrastructure/network/tmdb_http_client.dart';
import '../../infrastructure/network/tmdb_service.dart';
import '../scraping/scrape_work_persister.dart';
import '../scraping/series_auto_linker.dart';
import 'library_providers.dart';
import 'scraping_providers.dart';

/// Bangumi 独立条目 × TMDB 指定季/集的双源混合绑定请求参数。
class HybridMatchRequest {
  /// 创建双源混合绑定请求。
  const HybridMatchRequest({
    required this.bangumiSubject,
    required this.tmdbDetail,
    required this.tmdbSeasonNumber,
    required this.startEpisodeNumber,
    this.customSlotsByVariantId,
  });

  /// 选定的 Bangumi 独立条目（提供独立封面、标题、年份、简介与评分）。
  final BangumiSubjectCandidate bangumiSubject;

  /// 选定的 TMDB 母系列作品（提供系列横版背景图与剧集剧照）。
  final TmdbWorkDetail tmdbDetail;

  /// 目标 TMDB 季号（例如特别篇为 `0`）。
  final int tmdbSeasonNumber;

  /// 起始映射 TMDB 集号（多文件按顺序递增，也可由 [customSlotsByVariantId] 精确指定）。
  final int startEpisodeNumber;

  /// 可选按物理版本 ID 显式覆盖的目标季/集号。
  final Map<String, ({int season, int episode})>? customSlotsByVariantId;
}

/// 将指定作品执行 Bangumi × TMDB 双源混合绑定并锁定。
Future<Work> executeHybridBind(
  Ref ref, {
  required String workId,
  required HybridMatchRequest request,
  BangumiService? bangumiServiceOverride,
  TmdbService? tmdbServiceOverride,
}) async {
  final repo = ref.read(libraryRepositoryProvider);
  final existing = await repo.findWorkById(workId);
  if (existing == null) {
    throw StateError('作品不存在: $workId');
  }

  TmdbHttpClient? ownedClient;
  late final BangumiService bgm;
  late final TmdbService tmdb;
  if (bangumiServiceOverride != null && tmdbServiceOverride != null) {
    bgm = bangumiServiceOverride;
    tmdb = tmdbServiceOverride;
  } else {
    final config = await ref.read(tmdbNetworkConfigProvider.future);
    final scheduler = ref.read(priorityHttpSchedulerProvider);
    final cooldown = ref.read(domainCooldownRegistryProvider);
    ownedClient = TmdbHttpClient(
      config: config,
      scheduler: scheduler,
      cooldownRegistry: cooldown,
    );
    bgm = bangumiServiceOverride ?? BangumiService(httpClient: ownedClient);
    tmdb = tmdbServiceOverride ?? TmdbService(httpClient: ownedClient);
  }

  try {
    var subject = request.bangumiSubject;
    if (subject.score == null ||
        (subject.summary == null || subject.summary!.trim().isEmpty) ||
        subject.posterUrl == null) {
      try {
        final full = await bgm.getSubjectDetail(
          subject.id,
          priority: RequestPriority.interactive,
        );
        if (full != null) {
          subject = full;
        }
      } catch (error) {
      // 保留已选基础候选项，不阻断绑定。
      developer.log('可恢复异常已记录', name: 'konata.work_split_and_series_actions', error: error);
    }
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
    await repo.upsertWork(updated);
    await repo.clearScrapeCandidates(workId);

    await _syncHybridEpisodesAndVariants(
      repo: repo,
      work: updated,
      subject: subject,
      tmdbDetail: tmdbDetail,
      seasonDetail: seasonDetail,
      bgmEpisodes: bgmEpisodes,
      tmdbSeasonNumber: request.tmdbSeasonNumber,
      startEpisodeNumber: request.startEpisodeNumber,
      customSlotsByVariantId: request.customSlotsByVariantId,
    );
    await SeriesAutoLinker.reconcileAll(
      repository: repo,
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
    return (await repo.findWorkById(workId)) ?? updated;
  } finally {
    ownedClient?.close();
  }
}

/// 将指定作品绑定到纯 Bangumi 条目（不依赖 TMDB）并锁定。
Future<Work> executeBangumiOnlyBind(
  Ref ref, {
  required String workId,
  required BangumiSubjectCandidate bangumiSubject,
  BangumiService? bangumiServiceOverride,
  TmdbService? tmdbServiceOverride,
}) async {
  final repo = ref.read(libraryRepositoryProvider);
  final existing = await repo.findWorkById(workId);
  if (existing == null) {
    throw StateError('作品不存在: $workId');
  }

  TmdbHttpClient? ownedClient;
  late final BangumiService bgm;
  TmdbService? tmdb = tmdbServiceOverride;
  if (bangumiServiceOverride != null) {
    bgm = bangumiServiceOverride;
  } else {
    final config = await ref.read(tmdbNetworkConfigProvider.future);
    final scheduler = ref.read(priorityHttpSchedulerProvider);
    final cooldown = ref.read(domainCooldownRegistryProvider);
    ownedClient = TmdbHttpClient(
      config: config,
      scheduler: scheduler,
      cooldownRegistry: cooldown,
    );
    bgm = BangumiService(httpClient: ownedClient);
    tmdb ??= TmdbService(httpClient: ownedClient);
  }

  try {
    var subject = bangumiSubject;
    if (subject.score == null ||
        (subject.summary == null || subject.summary!.trim().isEmpty) ||
        subject.posterUrl == null) {
      try {
        final full = await bgm.getSubjectDetail(
          subject.id,
          priority: RequestPriority.interactive,
        );
        if (full != null) {
          subject = full;
        }
      } catch (error) {
      developer.log('可恢复异常已记录', name: 'konata.work_split_and_series_actions', error: error);
    }
    }

    var bgmEpisodes = const <BangumiEpisodeEntry>[];
    try {
      bgmEpisodes = await bgm.getSubjectEpisodes(
        subject.id,
        type: null,
        priority: RequestPriority.interactive,
      );
    } catch (error) {
      developer.log('可恢复异常已记录', name: 'konata.work_split_and_series_actions', error: error);
    }

    var updated = existing.copyWith(
      bangumiId: subject.id,
      title: subject.displayTitle,
      originalTitle: subject.name.isNotEmpty ? subject.name : existing.originalTitle,
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

    // 仅绑定 Bangumi 且当前缺少背景原画时，静默向 TMDB 检索高置信度动画（genre=16）横版背景图并仅回填 backdropPath。
    if (tmdb != null &&
        !updated.backdropLocked &&
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

    await repo.upsertWork(updated);
    await repo.clearScrapeCandidates(workId);

    final variants = await repo.getVariantsByWork(workId);
    final videoVariants = _sortedVideoVariants(variants);
    final bgmByEp = <int, BangumiEpisodeEntry>{
      for (final be in bgmEpisodes.where((e) => e.type == 0))
        if ((be.ep ?? be.sort) != null) (be.ep ?? be.sort)!.round(): be,
    };

    for (var i = 0; i < videoVariants.length; i++) {
      final variant = videoVariants[i];
      final parsed = BdripParser.parseFileName(variant.fileName);
      final parsedEp = parsed.episode;
      final epNum =
          (videoVariants.length == 1 && parsedEp != null && parsedEp > 0)
              ? parsedEp
              : (i + 1);
      final hasExplicitEpNum =
          videoVariants.length > 1 || (parsedEp != null && parsedEp > 0);
      final be = bgmByEp[epNum];
      final title = (be != null && be.displayName.isNotEmpty)
          ? be.displayName
          : (hasExplicitEpNum
                ? '第 ${epNum.toString().padLeft(2, '0')} 话'
                : subject.displayTitle);
      final epId = ScrapeWorkPersister.deterministicId('$workId::bgm:1:$epNum');
      await repo.upsertEpisode(
        Episode(
          id: epId,
          workId: workId,
          seasonNumber: 1,
          episodeNumber: epNum,
          category: EpisodeCategory.main,
          title: title,
          overview: subject.summary,
        ),
      );
      await repo.upsertMediaVariant(
        variant.copyWith(
          episodeId: epId,
          mappingLocked: true,
          workLocked: true,
        ),
      );
    }
    await repo.deleteOrphanEpisodes(workId);
    await SeriesAutoLinker.reconcileAll(
      repository: repo,
      bangumiService: bgm,
      focusBangumiIds: {
        if ((updated.bangumiId ?? 0) > 0) updated.bangumiId!,
      },
      focusWorkIds: {updated.id},
    );
    return (await repo.findWorkById(workId)) ?? updated;
  } finally {
    ownedClient?.close();
  }
}

/// 仅绑定 Bangumi 后用于静默补全 16:9 横版背景图的保守高置信度 TMDB 校验查询。
Future<String?> _lookupHighConfidenceTmdbBackdrop({
  required TmdbService tmdb,
  required BangumiSubjectCandidate subject,
  required bool preferTv,
}) async {
  try {
    final bgmNames = <String>[
      if (subject.nameCn.trim().isNotEmpty) subject.nameCn.trim(),
      if (subject.name.trim().isNotEmpty) subject.name.trim(),
    ];
    final queries = <String>[];
    final seenQ = <String>{};
    for (final raw in bgmNames) {
      for (final q in SearchQuerySanitizer.buildBangumiFallbackQueries(raw)) {
        if (seenQ.add(q.toLowerCase())) queries.add(q);
      }
    }
    if (queries.isEmpty) return null;

    final normBgmTitles = <String>{};
    for (final name in bgmNames) {
      final s1 = DirectoryAnalyzer.normalize(name);
      final s2 = DirectoryAnalyzer.normalize(
        SearchQuerySanitizer.stripPartAndSeasonSuffix(name),
      );
      if (s1.isNotEmpty) normBgmTitles.add(s1);
      if (s2.isNotEmpty) normBgmTitles.add(s2);
    }

    final hits = <TmdbSearchResult>[];
    final seenHit = <String>{};
    for (final q in queries.take(3)) {
      final list = await tmdb.searchAnime(
        q,
        year: subject.year,
        mediaTypeFilter: preferTv ? TmdbMediaType.tv : null,
        priority: RequestPriority.background,
      );
      for (final h in list) {
        final k = '${h.mediaType.name}:${h.tmdbId}';
        if (seenHit.add(k)) hits.add(h);
      }
      if (hits.length >= 8) break;
    }

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
        if (hit.originalTitle != null && hit.originalTitle!.trim().isNotEmpty)
          DirectoryAnalyzer.normalize(hit.originalTitle!),
      ].where((e) => e.isNotEmpty).toList(growable: false);

      var bestSim = 0.0;
      for (final bn in normBgmTitles) {
        for (final hn in hitNorms) {
          final sim = WorkMatcher.similarity(bn, hn);
          if (sim > bestSim) bestSim = sim;
        }
      }
      if (bestSim < 0.72) continue;

      if (hit.genreIds.isEmpty) {
        final detail = await tmdb.getWorkDetail(
          hit.tmdbId,
          hit.mediaType,
          priority: RequestPriority.background,
        );
        if (detail == null || !detail.genreIds.contains(16)) continue;
        final dBd = detail.backdropPath?.trim();
        if (dBd != null && dBd.isNotEmpty) return dBd;
      }
      return bd;
    }
  } catch (error) {
      // 静默兜底失败绝不影响 Bangumi 独立绑定主流程。
      developer.log('可恢复异常已记录', name: 'konata.work_split_and_series_actions', error: error);
    }
  return null;
}

/// 从原作品中拆出选中物理视频文件为独立媒体库作品，并将原拆出文件写入永久归属锁定。
///
/// 返回新建独立作品的 `Work` 实体；若原待复核条目所有文件均被分配，会自动清理原残余待复核记录。
Future<Work> executeSplitVariantsToIndependentWork(
  Ref ref, {
  required String sourceWorkId,
  required List<String> variantIds,
  HybridMatchRequest? hybridRequest,
  ({int tmdbId, TmdbMediaType mediaType})? tmdbTarget,
  BangumiSubjectCandidate? bangumiOnlySubject,
  bool writeTmdbIdToFolderName = false,
  BangumiService? bangumiServiceOverride,
  TmdbService? tmdbServiceOverride,
}) async {
  if (hybridRequest == null &&
      tmdbTarget == null &&
      bangumiOnlySubject == null) {
    throw ArgumentError('必须指定一种目标绑定方式（混合绑定 / TMDB / Bangumi）');
  }

  final repo = ref.read(libraryRepositoryProvider);
  final sourceWork = await repo.findWorkById(sourceWorkId);
  if (sourceWork == null) {
    throw StateError('原作品不存在: $sourceWorkId');
  }

  final sourceVariants = await repo.getVariantsByWork(sourceWorkId);
  final idSet = variantIds.toSet();
  final selected = sourceVariants
      .where((v) => idSet.contains(v.id))
      .toList(growable: false);
  if (selected.isEmpty) {
    throw StateError('请至少选择一个有效源文件后再拆分');
  }
  final sortedSelected = List<MediaVariant>.of(selected)
    ..sort(
      (a, b) => a.relativePath.toLowerCase().compareTo(
        b.relativePath.toLowerCase(),
      ),
    );

  final newWorkId = ScrapeWorkPersister.deterministicId(
    'split::$sourceWorkId::${DateTime.now().microsecondsSinceEpoch}::${sortedSelected.first.relativePath}',
  );
  final placeholderTitle =
      hybridRequest?.bangumiSubject.displayTitle ??
      bangumiOnlySubject?.displayTitle ??
      sortedSelected.first.fileName;

  final initialWork = Work(
    id: newWorkId,
    title: placeholderTitle,
    tmdbId: tmdbTarget?.tmdbId ?? hybridRequest?.tmdbDetail.tmdbId,
    tmdbMediaType: tmdbTarget?.mediaType ?? hybridRequest?.tmdbDetail.mediaType,
    bangumiId: hybridRequest?.bangumiSubject.id ?? bangumiOnlySubject?.id,
    isManualLocked: true,
    scrapeStatus: ScrapeStatus.matched,
  );
  await repo.upsertWork(initialWork);

  for (final variant in sortedSelected) {
    await repo.upsertMediaVariant(
      variant.copyWith(
        workId: newWorkId,
        clearEpisodeId: true,
        mappingLocked: true,
        workLocked: true,
      ),
    );
  }

  late final Work boundWork;
  if (hybridRequest != null) {
    boundWork = await executeHybridBind(
      ref,
      workId: newWorkId,
      request: hybridRequest,
      bangumiServiceOverride: bangumiServiceOverride,
      tmdbServiceOverride: tmdbServiceOverride,
    );
  } else if (tmdbTarget != null) {
    boundWork = await ref
        .read(scrapeControllerProvider.notifier)
        .rebindWork(
          workId: newWorkId,
          tmdbId: tmdbTarget.tmdbId,
          mediaType: tmdbTarget.mediaType,
          writeIdToFolderName: writeTmdbIdToFolderName,
          resetManualLocks: false,
        );
    // 确保从父作品拆分出的变体在纯 TMDB 重绑定后也全部写入归属锁。
    final newVariants = await repo.getVariantsByWork(newWorkId);
    for (final v in newVariants) {
      if (!v.workLocked) {
        await repo.upsertMediaVariant(v.copyWith(workLocked: true));
      }
    }
  } else {
    boundWork = await executeBangumiOnlyBind(
      ref,
      workId: newWorkId,
      bangumiSubject: bangumiOnlySubject!,
      bangumiServiceOverride: bangumiServiceOverride,
    );
  }

  final sourceDeleted = await _cleanupSourceWorkAfterSplit(repo, sourceWork);
  await SeriesAutoLinker.reconcileAll(
    repository: repo,
    bangumiService: bangumiServiceOverride,
    focusBangumiIds: {
      if ((boundWork.bangumiId ?? 0) > 0) boundWork.bangumiId!,
    },
    focusWorkIds: {boundWork.id, if (!sourceDeleted) sourceWork.id},
  );
  final resolvedTarget = (await repo.findWorkById(newWorkId)) ?? boundWork;
  if (sourceDeleted) {
    recordWorkRedirect(ref, sourceWork.id, resolvedTarget.id);
    ref.invalidate(workDetailBundleProvider(sourceWork.id));
    ref.invalidate(libraryItemsProvider);
    ref.invalidate(worksCountProvider);
  }
  return resolvedTarget;
}

Future<bool> _cleanupSourceWorkAfterSplit(
  LibraryRepository repo,
  Work sourceWork,
) async {
  await repo.deleteOrphanEpisodes(sourceWork.id);
  final remaining = await repo.getVariantsByWork(sourceWork.id);
  final hasRemainingVideos = remaining.any(
    (v) => v.assetKind == AssetKind.video,
  );
  if (remaining.isEmpty ||
      (!hasRemainingVideos && sourceWork.scrapeStatus != ScrapeStatus.matched)) {
    await repo.deleteWork(sourceWork.id);
    return true;
  }
  return false;
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
  final resolvedOverview =
      (bgmOverview != null && bgmOverview.isNotEmpty)
      ? bgmOverview
      : (tmdbOverview != null && tmdbOverview.isNotEmpty ? tmdbOverview : null);

  final resolvedPoster =
      subject.posterUrl ?? seasonDetail?.posterPath ?? tmdbDetail.posterPath;
  final resolvedFallback = seasonDetail?.posterPath ?? tmdbDetail.posterPath;
  final resolvedBackdrop = existing.backdropLocked
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
    originalTitle: subject.name.isNotEmpty
        ? subject.name
        : tmdbDetail.originalTitle,
    year: subject.year ?? _extractYear(seasonDetail?.airDate) ?? tmdbDetail.year,
    overview: resolvedOverview,
    posterPath: resolvedPoster,
    posterFallback: resolvedFallback,
    bangumiPosterPath: subject.posterUrl ?? existing.bangumiPosterPath,
    backdropPath: resolvedBackdrop,
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
  required LibraryRepository repo,
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
  final bgmMainEps = bgmEpisodes.where((e) => e.type == 0).toList(growable: false);
  final variants = await repo.getVariantsByWork(work.id);
  final videoVariants = _sortedVideoVariants(variants);

  final baseEp = startEpisodeNumber <= 0 ? 1 : startEpisodeNumber;
  for (var i = 0; i < videoVariants.length; i++) {
    final variant = videoVariants[i];
    final override = customSlotsByVariantId?[variant.id];
    final targetSeason = override?.season ??
        (tmdbDetail.mediaType == TmdbMediaType.movie ? 1 : tmdbSeasonNumber);
    final targetEpNum = override?.episode ?? (baseEp + i);

    final tmdbEp = tmdbEpByKey['$targetSeason:$targetEpNum'];
    final bgmEp = i < bgmMainEps.length ? bgmMainEps[i] : null;
    final resolvedTitle = _firstNonEmpty([
      tmdbEp?.title,
      bgmEp?.displayName,
      videoVariants.length == 1 ? subject.displayTitle : null,
      '第 ${i + 1} 话',
    ])!;
    final resolvedOverview = _firstNonEmpty([
      tmdbEp?.overview,
      subject.summary,
    ]);
    final resolvedStill = _firstNonEmpty([
      tmdbEp?.stillPath,
      tmdbDetail.mediaType == TmdbMediaType.movie
          ? tmdbDetail.backdropPath
          : null,
    ]);

    final epId = ScrapeWorkPersister.deterministicId(
      '${work.id}::hybrid:$targetSeason:$targetEpNum',
    );
    await repo.upsertEpisode(
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
    await repo.upsertMediaVariant(
      variant.copyWith(
        episodeId: epId,
        mappingLocked: true,
        workLocked: true,
      ),
    );
  }
  await repo.deleteOrphanEpisodes(work.id);
}

List<MediaVariant> _sortedVideoVariants(List<MediaVariant> variants) {
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

String? _firstNonEmpty(List<String?> values) {
  for (final raw in values) {
    final clean = raw?.trim();
    if (clean != null && clean.isNotEmpty) return clean;
  }
  return null;
}

int? _extractYear(String? dateStr) {
  if (dateStr == null || dateStr.isEmpty) return null;
  final match = RegExp(r'(?:19|20)\d{2}').firstMatch(dateStr);
  return match == null ? null : int.tryParse(match.group(0)!);
}

/// 单个系列成员编辑配置。
class SeriesMemberEdit {
  /// 创建系列成员编辑项。
  const SeriesMemberEdit({
    required this.workId,
    required this.order,
    required this.label,
  });

  /// 成员作品 ID。
  final String workId;

  /// 在系列中的显示顺序（从 1 开始）。
  final int order;

  /// 成员角色标签（例如 `第 1 季`、`剧场版 Code: White`）。
  final String label;
}

/// 单个附属资源（特典 / CD / Scan）作用域与归属调整项。
class SupplementaryScopeEdit {
  /// 创建附属资源作用域修改项。
  const SupplementaryScopeEdit({
    required this.variantId,
    required this.scope,
    required this.targetWorkId,
  });

  /// 物理媒体文件变体 ID。
  final String variantId;

  /// 目标共享策略（全系列共享 / 仅指定条目独享）。
  final SupplementaryAssetScope scope;

  /// 当仅指定条目独享时归属的目标作品 ID（共享时亦可保持原所属或指定宿主）。
  final String targetWorkId;
}

/// 创建或更新系列编组、调整成员顺序/角色标签并人工锁定；返回受影响的全部作品 ID。
Future<({SeriesGroup? group, Set<String> affectedWorkIds})>
executeSaveSeriesGroupConfig(
  Ref ref, {
  String? seriesId,
  required String title,
  required List<SeriesMemberEdit> members,
  int? tmdbCollectionId,
}) async {
  final repo = ref.read(libraryRepositoryProvider);
  final allWorks = await repo.getAllWorks();
  final workById = {for (final w in allWorks) w.id: w};
  final affected = <String>{};
  final normalizedTitle = title.trim().isEmpty ? '未命名系列' : title.trim();

  final validMembers = [
    for (final m in members)
      if (workById.containsKey(m.workId)) m,
  ];
  final targetIds = validMembers.map((m) => m.workId).toSet();

  final resolvedSeriesId =
      (seriesId != null && seriesId.trim().isNotEmpty)
      ? seriesId.trim()
      : ScrapeWorkPersister.deterministicId(
          'manual_series::${validMembers.isNotEmpty ? validMembers.first.workId : DateTime.now().microsecondsSinceEpoch}',
        );

  final existingGroup = await repo.findSeriesGroupById(resolvedSeriesId);
  // 若有原属该系列的成员被用户移出，写入 clearSeries + seriesLocked: true 防止后续重扫被重新拉入。
  for (final w in allWorks) {
    if (w.seriesId == resolvedSeriesId && !targetIds.contains(w.id)) {
      await repo.upsertWork(w.copyWith(clearSeries: true, seriesLocked: true));
      affected.add(w.id);
    }
  }

  if (validMembers.isEmpty) {
    if (existingGroup != null) {
      await repo.deleteSeriesGroup(resolvedSeriesId);
    }
    return (group: null, affectedWorkIds: affected);
  }

  final now = DateTime.now();
  final savedGroup = SeriesGroup(
    id: resolvedSeriesId,
    title: normalizedTitle,
    tmdbCollectionId: tmdbCollectionId ?? existingGroup?.tmdbCollectionId,
    createdAt: existingGroup?.createdAt ?? now,
    updatedAt: now,
  );
  await repo.upsertSeriesGroup(savedGroup);

  for (var i = 0; i < validMembers.length; i++) {
    final edit = validMembers[i];
    final current = workById[edit.workId]!;
    final previousSeriesId = current.seriesId;
    final cleanLabel = edit.label.trim().isEmpty
        ? current.title
        : edit.label.trim();
    await repo.upsertWork(
      current.copyWith(
        seriesId: resolvedSeriesId,
        seriesOrder: edit.order > 0 ? edit.order : (i + 1),
        seriesLabel: cleanLabel,
        seriesLocked: true,
      ),
    );
    affected.add(current.id);
    if (previousSeriesId != null &&
        previousSeriesId != resolvedSeriesId &&
        previousSeriesId.isNotEmpty) {
      // 若原系列还有其他成员，刷新之；若原系列被掏空则清理空组。
      final stillInOld = allWorks
          .where((w) => w.seriesId == previousSeriesId && w.id != current.id)
          .toList();
      if (stillInOld.isEmpty) {
        await repo.deleteSeriesGroup(previousSeriesId);
      } else {
        for (final sibling in stillInOld) {
          affected.add(sibling.id);
        }
      }
    }
  }

  // 同时刷新现有组内原本就在系列里的所有成员详情缓存。
  for (final w in allWorks) {
    if (w.seriesId == resolvedSeriesId) {
      affected.add(w.id);
    }
  }

  return (group: savedGroup, affectedWorkIds: affected);
}

/// 人工覆写附属资源（特典 / CD / Scan）的系列共享或单作独享作用域，并永久写入 `scopeLocked`。
Future<Set<String>> executeUpdateSupplementaryScopes(
  Ref ref, {
  required List<SupplementaryScopeEdit> edits,
}) async {
  if (edits.isEmpty) return const {};
  final repo = ref.read(libraryRepositoryProvider);
  final editByVariantId = {for (final e in edits) e.variantId: e};
  final allWorks = await repo.getAllWorks();
  final workById = {for (final w in allWorks) w.id: w};
  final affected = <String>{};
  final worksWithMovedEpisodes = <String>{};

  // 先汇总各源作品现有的变体与分集，精确定位需要变更的变体记录。
  final variantLocations = <String, ({MediaVariant variant, Episode? episode})>{};
  for (final work in allWorks) {
    final variants = await repo.getVariantsByWork(work.id);
    final needAny = variants.any((v) => editByVariantId.containsKey(v.id));
    if (!needAny) continue;
    final eps = await repo.getEpisodesByWork(work.id);
    final epById = {for (final e in eps) e.id: e};
    for (final v in variants) {
      if (editByVariantId.containsKey(v.id)) {
        variantLocations[v.id] = (
          variant: v,
          episode: v.episodeId != null ? epById[v.episodeId] : null,
        );
      }
    }
  }

  for (final edit in edits) {
    final loc = variantLocations[edit.variantId];
    if (loc == null) continue;
    final variant = loc.variant;
    final oldWorkId = variant.workId;
    final desiredWorkId =
        (edit.scope == SupplementaryAssetScope.workExclusive &&
            workById.containsKey(edit.targetWorkId))
        ? edit.targetWorkId
        : oldWorkId;

    String? resolvedEpisodeId = variant.episodeId;
    if (desiredWorkId != oldWorkId &&
        variant.assetKind == AssetKind.video &&
        loc.episode != null) {
      final oldEp = loc.episode!;
      final newEpId = ScrapeWorkPersister.deterministicId(
        '$desiredWorkId::scope_extra:${variant.id}',
      );
      await repo.upsertEpisode(
        Episode(
          id: newEpId,
          workId: desiredWorkId,
          seasonNumber: oldEp.seasonNumber,
          episodeNumber: oldEp.episodeNumber,
          category: oldEp.category,
          extraType: oldEp.extraType,
          title: oldEp.title,
          overview: oldEp.overview,
          stillPath: oldEp.stillPath,
        ),
      );
      resolvedEpisodeId = newEpId;
      worksWithMovedEpisodes.add(oldWorkId);
    }

    await repo.upsertMediaVariant(
      variant.copyWith(
        workId: desiredWorkId,
        episodeId: resolvedEpisodeId,
        assetScope: edit.scope,
        scopeLocked: true,
      ),
    );
    affected.add(oldWorkId);
    affected.add(desiredWorkId);

    final seriesId =
        workById[oldWorkId]?.seriesId ?? workById[desiredWorkId]?.seriesId;
    if (seriesId != null && seriesId.isNotEmpty) {
      for (final m in allWorks) {
        if (m.seriesId == seriesId) {
          affected.add(m.id);
        }
      }
    }
  }

  for (final wId in worksWithMovedEpisodes) {
    await repo.deleteOrphanEpisodes(wId);
  }
  return affected;
}
