import '../../domain/matching/directory_grouper.dart';
import '../../domain/models/tmdb_models.dart';
import '../../domain/models/work.dart';
import '../../domain/scraping/bangumi_models.dart';
import '../../domain/scraping/scrape_domain_adapter.dart';
import '../../domain/scraping/work_matcher.dart' as legacy;
import '../../infrastructure/network/bangumi_service.dart';
import '../../infrastructure/network/priority_http_scheduler.dart';
import '../../infrastructure/network/tmdb_service.dart';

/// 刮削过程中的 Bangumi + TMDB 双引擎候选检索、单季元数据与分集拉取辅助器。
class ScrapeCandidateFetcher {
  /// 创建候选检索辅助器。
  const ScrapeCandidateFetcher(
    this._tmdbService, {
    this.bangumiService,
  });

  final TmdbService _tmdbService;
  final BangumiService? bangumiService;

  /// 若当前子簇无显式 ID 但合集父目录带 `{tmdb-N}`，拉取父系列官方标题作为补充检索线索。
  Future<({List<String> extraQueries, TmdbWorkDetail? parentDetail})>
  fetchParentCollectionContext(GroupedWorkFolder folder) async {
    final parentId = folder.parentTmdbId;
    if (parentId == null) {
      return (extraQueries: const <String>[], parentDetail: null);
    }
    final types = folder.parentTmdbType != null
        ? [folder.parentTmdbType!]
        : const [TmdbMediaType.tv, TmdbMediaType.movie];
    for (final type in types) {
      final detail = await _tmdbService.getWorkDetail(
        parentId,
        type,
        priority: RequestPriority.background,
      );
      if (detail == null) continue;
      final extra = <String>[];
      final parentTitles = [detail.title, ...detail.aliases.take(2)]
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty);
      for (final pt in parentTitles) {
        extra.add(pt);
        if (folder.allowParentTmdbCandidate) {
          extra.add('$pt OAD');
          extra.add('$pt OVA');
        }
      }
      return (extraQueries: extra, parentDetail: detail);
    }
    return (extraQueries: const <String>[], parentDetail: null);
  }

  /// 阶段 2：显式 TMDB ID 直连拉取，并在未限定类型且首选 404 时自动尝试另一侧类型 (`tv <-> movie`)。
  Future<TmdbWorkDetail?> fetchExplicitDetail(GroupedWorkFolder folder) async {
    final tmdbId = folder.explicitTmdbId;
    if (tmdbId == null) return null;

    final primaryType =
        folder.explicitMediaType ??
        (folder.isMovieHint ? TmdbMediaType.movie : TmdbMediaType.tv);
    final primaryDetail = await _tmdbService.getWorkDetail(
      tmdbId,
      primaryType,
      priority: RequestPriority.background,
    );
    if (primaryDetail != null) return primaryDetail;

    // 若文件夹标记如 `{tmdb-999}` / `[tmdbid=999]` 未写死类型，首选 404 时自动尝试另一侧类型。
    if (folder.explicitMediaType == null) {
      final fallbackType = primaryType == TmdbMediaType.tv
          ? TmdbMediaType.movie
          : TmdbMediaType.tv;
      return _tmdbService.getWorkDetail(
        tmdbId,
        fallbackType,
        priority: RequestPriority.background,
      );
    }

    return null;
  }

  /// 在线 Bangumi 多波次检索并补全 Top 4 候选完整 `infobox`、封面大图与简介（不查询角色/声优接口）。
  Future<List<BangumiSubjectCandidate>> fetchBangumiCandidates(
    GroupedWorkFolder folder, {
    List<String> extraQueries = const [],
  }) async {
    final bgm = bangumiService;
    if (bgm == null) return const [];

    final queries = ScrapeDomainAdapter.buildSearchQueries(
      folder,
      extraQueries: extraQueries,
    );
    if (queries.isEmpty) return const [];

    final rawById = <int, BangumiSubjectCandidate>{};

    Future<void> runWave(Iterable<String> terms) async {
      final results = await Future.wait(
        terms.map(
          (q) => bgm.searchSubjects(q, priority: RequestPriority.background),
        ),
      );
      for (final list in results) {
        for (final item in list) {
          if (item.id > 0) rawById.putIfAbsent(item.id, () => item);
        }
      }
    }

    try {
      await runWave(queries.take(3));
      final needWave2 =
          queries.length > 3 &&
          (rawById.isEmpty ||
              ScrapeDomainAdapter.evaluateBangumiMatch(
                    folder,
                    rawById.values.toList(growable: false),
                  ).tier ==
                  legacy.MatchTier.none);
      if (needWave2) {
        await runWave(queries.skip(3).take(4));
      }
    } catch (_) {
      // Bangumi 临时异常不阻断主 TMDB 管线。
      if (rawById.isEmpty) return const [];
    }

    if (rawById.isEmpty) return const [];

    final prelim = ScrapeDomainAdapter.evaluateBangumiMatch(
      folder,
      rawById.values.toList(growable: false),
    );
    final limit = prelim.tier == legacy.MatchTier.high ? 2 : 4;
    final topIds = <int>{
      ...prelim.topCandidates.take(limit).map((e) => e.subject.id),
      if (prelim.best != null) ...prelim.best!.siblingIds,
    };

    await Future.wait(
      topIds.map((id) async {
        try {
          final full = await bgm.getSubjectDetail(
            id,
            priority: RequestPriority.background,
          );
          if (full != null) rawById[id] = full;
        } catch (_) {
          // 保留粗搜基础条目信息。
        }
      }),
    );

    return rawById.values.toList(growable: false);
  }

  /// 阶段 3：严格遵循 `feat/scrape-pipeline` 多波次关键词清洗策略搜索并补充前 8 条 TMDB 候选详情。
  Future<List<TmdbWorkDetail>> fetchCandidateDetails(
    GroupedWorkFolder folder, {
    ScoredBangumiCandidate? bangumiCandidate,
    List<String> extraQueries = const [],
  }) async {
    final queries = ScrapeDomainAdapter.buildSearchQueries(
      folder,
      bangumiCandidate: bangumiCandidate,
      extraQueries: extraQueries,
    );
    final searchYear = ScrapeDomainAdapter.extractSearchYear(folder);
    final candidatesMap = <String, TmdbSearchResult>{};

    Future<void> collectWave(
      Iterable<String> qs, {
      int? year,
      String language = 'zh-CN',
      required int cap,
    }) async {
      for (final q in qs) {
        final hits = await _tmdbService.searchAnime(
          q,
          year: year,
          language: language,
          priority: RequestPriority.background,
        );
        for (final h in hits) {
          candidatesMap.putIfAbsent('${h.mediaType.name}:${h.tmdbId}', () => h);
        }
        if (candidatesMap.length >= cap) break;
      }
    }

    bool waveNeedsBackup() {
      if (candidatesMap.isEmpty) return true;
      var bestPreview = 0.0;
      for (final hit in candidatesMap.values) {
        final s = ScrapeDomainAdapter.scoreSearchHitPreview(folder, hit);
        if (s > bestPreview) bestPreview = s;
      }
      return bestPreview < 42;
    }

    // Wave 1：高可信词干 + Bangumi 交叉别名（最多 3 个）+ 目录年份精准约束。
    await collectWave(queries.take(3), year: searchYear, cap: 6);

    // Wave 2：携带年份未命中或最高初筛分 < 42 时放宽年份并拓展副标题/文件名提示。
    if (searchYear != null && waveNeedsBackup()) {
      await collectWave(queries.take(3), cap: 8);
    }
    if (queries.length > 3 && waveNeedsBackup()) {
      await collectWave(queries.skip(3).take(5), cap: 10);
    }

    // Wave 3：中文搜索候选仍稀缺或失真时，回退英文与日文检索提升冷门或原名番剧召回率。
    if (candidatesMap.length < 3 || waveNeedsBackup()) {
      await collectWave(queries.take(3), language: 'en-US', cap: 12);
    }
    if (candidatesMap.length < 3 || waveNeedsBackup()) {
      await collectWave(queries.take(3), language: 'ja-JP', cap: 12);
    }

    if (candidatesMap.isEmpty) return const [];

    // 取初步打分前 6 条与原始结果前 2 条并集拉取完整详情。
    final allHits = candidatesMap.values.toList(growable: false);
    final scored = [
      for (final h in allHits)
        (hit: h, score: ScrapeDomainAdapter.scoreSearchHitPreview(folder, h)),
    ]..sort((a, b) => b.score.compareTo(a.score));

    final detailTargets = <TmdbSearchResult>[];
    final seenKeys = <String>{};
    for (final entry in scored.take(6)) {
      final k = '${entry.hit.mediaType.name}:${entry.hit.tmdbId}';
      if (seenKeys.add(k)) detailTargets.add(entry.hit);
    }
    for (final raw in allHits.take(4)) {
      if (detailTargets.length >= 8) break;
      final k = '${raw.mediaType.name}:${raw.tmdbId}';
      if (seenKeys.add(k)) detailTargets.add(raw);
    }

    final details = <TmdbWorkDetail>[];
    for (final item in detailTargets) {
      final detail = await _tmdbService.getWorkDetail(
        item.tmdbId,
        item.mediaType,
        priority: RequestPriority.background,
      );
      if (detail != null) details.add(detail);
    }
    return details;
  }

  /// 一次拉取各引用季完整详情（含单季专属封面、季名、简介与分集列表）。
  Future<({
    List<TmdbEpisodeDetail> episodes,
    Map<int, TmdbSeasonDetail> seasonDetails,
  })> fetchSeasonBundle(
    int tmdbId,
    TmdbMediaType mediaType,
    Set<int> seasons,
  ) async {
    if (mediaType != TmdbMediaType.tv) {
      return (
        episodes: const <TmdbEpisodeDetail>[],
        seasonDetails: const <int, TmdbSeasonDetail>{},
      );
    }
    final targetSeasons = seasons.isEmpty ? {1} : seasons;
    final allEpisodes = <TmdbEpisodeDetail>[];
    final details = <int, TmdbSeasonDetail>{};
    for (final season in targetSeasons) {
      final seasonDetail = await _tmdbService.getSeasonDetail(
        tmdbId,
        season,
        priority: RequestPriority.background,
      );
      if (seasonDetail != null) {
        details[season] = seasonDetail;
        allEpisodes.addAll(seasonDetail.episodes);
      }
    }
    return (episodes: allEpisodes, seasonDetails: details);
  }

  /// 拉取指定 Bangumi 条目的分集标题与集号映射（传 `type: null` 可同时获取正片与 SP）。
  Future<List<BangumiEpisodeEntry>> fetchBangumiEpisodes(
    int subjectId, {
    int? type = 0,
  }) async {
    final bgm = bangumiService;
    if (bgm == null || subjectId <= 0) return const [];
    try {
      return await bgm.getSubjectEpisodes(
        subjectId,
        type: type,
        priority: RequestPriority.background,
      );
    } catch (_) {
      return const [];
    }
  }

  /// 拉取指定季号（含正片与 `Season 0` 特典）的分集元数据。
  Future<List<TmdbEpisodeDetail>> fetchEpisodesForDetail(
    int tmdbId,
    TmdbMediaType mediaType,
    Set<int> seasons,
  ) async {
    final bundle = await fetchSeasonBundle(tmdbId, mediaType, seasons);
    return bundle.episodes;
  }
}
