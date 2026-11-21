import 'dart:developer' as developer;
import '../../domain/formatting/network_error_sanitizer.dart';
import '../../domain/matching/directory_grouper.dart';
import '../../domain/models/tmdb_models.dart';
import '../../domain/models/work.dart';
import '../../domain/scraping/bangumi_models.dart';
import '../../domain/scraping/scrape_domain_adapter.dart';
import '../../domain/scraping/search_query_sanitizer.dart';
import '../../domain/scraping/work_matcher.dart' as legacy;
import '../../infrastructure/network/bangumi_service.dart';
import '../../infrastructure/network/priority_http_scheduler.dart';
import '../../infrastructure/network/tmdb_service.dart';

/// 刮削过程中的 Bangumi + TMDB 双引擎候选检索、单季元数据与分集拉取辅助器。
class ScrapeCandidateFetcher {
  /// 创建候选检索辅助器。
  const ScrapeCandidateFetcher(this._tmdbService, {this.bangumiService});

  final TmdbService _tmdbService;
  final BangumiService? bangumiService;

  /// 评分人数低于该值的前列候选视为疑似新建重复条目，触发原名补搜。
  static const int _canonicalVoteFloor = 3;

  /// Bangumi 首波检索全部失败后整体重试前的等待时长。
  static const Duration _bangumiWaveRetryDelay = Duration(seconds: 2);

  /// 并发发起一组互不依赖的请求（实际并发度由后台网络调度器限制），再按原顺序还原逐条串行的语义：
  /// 遇到首个瞬时网络异常即上报并丢弃其后的结果，非瞬时异常按顺序原样抛出，空结果跳过。
  /// 每部作品原本要逐条等待的候选详情、季详情往返因此可以重叠，刮削总耗时随之下降。
  static Future<({List<R> results, bool aborted})> _fetchAllInOrder<T, R>(
    Iterable<T> targets,
    Future<R?> Function(T target) fetch, {
    void Function(Object error)? onNetworkError,
  }) async {
    final outcomes = await Future.wait([
      for (final t in targets) _settle(() => fetch(t)),
    ]);
    final results = <R>[];
    for (final outcome in outcomes) {
      final error = outcome.error;
      if (error != null) {
        if (NetworkErrorSanitizer.isTransientNetworkError(error)) {
          onNetworkError?.call(error);
          return (results: results, aborted: true);
        }
        Error.throwWithStackTrace(error, outcome.stackTrace!);
      }
      final value = outcome.value;
      if (value != null) results.add(value);
    }
    return (results: results, aborted: false);
  }

  static Future<({R? value, Object? error, StackTrace? stackTrace})> _settle<R>(
    Future<R?> Function() run,
  ) async {
    try {
      return (value: await run(), error: null, stackTrace: null);
    } catch (error, stackTrace) {
      return (value: null, error: error, stackTrace: stackTrace);
    }
  }

  /// 若当前子簇无显式 ID 但合集父目录带 `{tmdb-N}`，拉取父系列官方标题作为补充检索线索。
  Future<({List<String> extraQueries, TmdbWorkDetail? parentDetail})>
  fetchParentCollectionContext(
    GroupedWorkFolder folder, {
    void Function(Object error)? onNetworkError,
  }) async {
    final parentId = folder.parentTmdbId;
    if (parentId == null) {
      return (extraQueries: const <String>[], parentDetail: null);
    }
    final types = folder.parentTmdbType != null
        ? [folder.parentTmdbType!]
        : const [TmdbMediaType.tv, TmdbMediaType.movie];
    for (final type in types) {
      TmdbWorkDetail? detail;
      try {
        detail = await _tmdbService.getWorkDetail(
          parentId,
          type,
          priority: RequestPriority.background,
        );
      } catch (error) {
        if (NetworkErrorSanitizer.isTransientNetworkError(error)) {
          onNetworkError?.call(error);
          return (extraQueries: const <String>[], parentDetail: null);
        }
        rethrow;
      }
      if (detail == null) continue;
      final extra = <String>[];
      final parentTitles = [
        detail.title,
        ...detail.aliases.take(2),
      ].map((s) => s.trim()).where((s) => s.isNotEmpty);
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

  /// 阶段 2：显式 TMDB ID 直连拉取。
  ///
  /// 标记写明类型时只拉取该类型；`{tmdb-999}` / `[tmdbid=999]` 未写明类型时，TMDB 剧集与电影的 ID
  /// 空间相互重叠，同号的另一侧往往是毫不相干的作品，因此两侧同时拉取：仅一侧存在时直接采用，
  /// 两侧都存在时交由目录画像打分择优，而不是盲信电影/剧集提示。
  Future<TmdbWorkDetail?> fetchExplicitDetail(
    GroupedWorkFolder folder, {
    void Function(Object error)? onNetworkError,
  }) async {
    final tmdbId = folder.explicitTmdbId;
    if (tmdbId == null) return null;

    try {
      final explicitType = folder.explicitMediaType;
      if (explicitType != null) {
        return await _tmdbService.getWorkDetail(
          tmdbId,
          explicitType,
          priority: RequestPriority.background,
        );
      }
      final details = await Future.wait([
        _tmdbService.getWorkDetail(
          tmdbId,
          TmdbMediaType.tv,
          priority: RequestPriority.background,
        ),
        _tmdbService.getWorkDetail(
          tmdbId,
          TmdbMediaType.movie,
          priority: RequestPriority.background,
        ),
      ]);
      final tv = details[0];
      final movie = details[1];
      if (tv == null || movie == null) return tv ?? movie;
      return ScrapeDomainAdapter.chooseExplicitTypeCandidate(
        folder,
        tv: tv,
        movie: movie,
      );
    } catch (error) {
      if (NetworkErrorSanitizer.isTransientNetworkError(error)) {
        onNetworkError?.call(error);
        return null;
      }
      rethrow;
    }
  }

  /// 在线 Bangumi 多波次检索并补全 Top 4 候选完整 `infobox`、封面大图与简介（不查询角色/声优接口）。
  /// 当目录或文件名携带显式 `{bgm-N}` / `[bgmid=N]` 标记时，优先按 ID 直连拉取保证 100% 召回。
  Future<List<BangumiSubjectCandidate>> fetchBangumiCandidates(
    GroupedWorkFolder folder, {
    List<String> extraQueries = const [],
  }) async {
    final bgm = bangumiService;
    if (bgm == null) return const [];

    final explicitBgmId = folder.explicitBangumiId;
    if (explicitBgmId != null && explicitBgmId > 0) {
      try {
        final direct = await bgm.getSubjectDetail(
          explicitBgmId,
          priority: RequestPriority.background,
        );
        if (direct != null) {
          return [direct];
        }
      } catch (error) {
        developer.log(
          '显式 Bangumi ID 直连拉取失败，回退关键词检索',
          name: 'konata.scrape_candidate_fetcher',
          error: error,
        );
      }
    }

    final queries = ScrapeDomainAdapter.buildSearchQueries(
      folder,
      extraQueries: extraQueries,
    );
    if (queries.isEmpty) return const [];

    final rawById = <int, BangumiSubjectCandidate>{};

    // 同一波次内各检索词互不牵连：单条失败只丢弃该条结果（Bangumi 临时异常不阻断主 TMDB 管线），返回失败条数。
    Future<int> runWave(List<String> terms) async {
      var failures = 0;
      final results = await Future.wait(
        terms.map((q) async {
          try {
            return await bgm.searchSubjects(
              q,
              priority: RequestPriority.background,
            );
          } catch (error) {
            failures++;
            developer.log(
              'Bangumi 检索失败已跳过',
              name: 'konata.scrape_candidate_fetcher',
              error: error,
            );
            return const <BangumiSubjectCandidate>[];
          }
        }),
      );
      for (final list in results) {
        for (final item in list) {
          if (item.id > 0) rawById.putIfAbsent(item.id, () => item);
        }
      }
      return failures;
    }

    final firstWave = queries.take(3).toList(growable: false);
    // 首波全部失败多为瞬时网络抖动：短暂等待后整体重试一次，避免整部作品静默降级为仅 TMDB 匹配。
    if (await runWave(firstWave) == firstWave.length) {
      await Future<void>.delayed(_bangumiWaveRetryDelay);
      await runWave(firstWave);
    }
    final needWave2 =
        queries.length > 3 &&
        (rawById.isEmpty ||
            ScrapeDomainAdapter.evaluateBangumiMatch(
                  folder,
                  rawById.values.toList(growable: false),
                ).tier ==
                legacy.MatchTier.none);
    if (needWave2) {
      await runWave(queries.skip(3).take(4).toList(growable: false));
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
        } catch (error) {
          // 保留粗搜基础条目信息。
          developer.log(
            '可恢复异常已记录',
            name: 'konata.scrape_candidate_fetcher',
            error: error,
          );
        }
      }),
    );

    // 仅当目录包含第 1 集且前排存在多个相近竞争候选（如分割放送第 1/2 部分）时，
    // 按需拉取竞争候选的少量正片分集以识别其起始 sort 序号，避免无关搜索噪音触发多余请求。
    if (!folder.isMovieHint &&
        folder.mainEpisodeNumbers.contains(1) &&
        prelim.topCandidates.length >= 2) {
      final bestScore = prelim.topCandidates.first.score;
      final competing = prelim.topCandidates
          .where((c) => c.score >= 30 || (bestScore - c.score) <= 25)
          .take(4)
          .toList(growable: false);
      if (competing.length >= 2) {
        final sortTargets = competing
            .map((e) => e.subject.id)
            .toList(growable: false);
        await Future.wait(
          sortTargets.map((id) async {
            try {
              final eps = await bgm.getSubjectEpisodes(
                id,
                type: 0,
                limit: 5,
                priority: RequestPriority.background,
              );
              double? minSort;
              for (final ep in eps) {
                final s = ep.sort ?? ep.ep;
                if (s == null || s <= 0) continue;
                if (minSort == null || s < minSort) {
                  minSort = s;
                }
              }
              if (minSort != null && rawById[id] != null) {
                rawById[id] = rawById[id]!.copyWith(firstEpisodeSort: minSort);
              }
            } catch (error) {
              // 部分测试桩或网络故障未提供 episodes 接口时静默跳过。
              developer.log(
                '可恢复异常已记录',
                name: 'konata.scrape_candidate_fetcher',
                error: error,
              );
            }
          }),
        );
      }
    }

    return rawById.values.toList(growable: false);
  }

  /// 阶段 3：严格遵循 `feat/scrape-pipeline` 多波次关键词清洗策略搜索并补充前 8 条 TMDB 候选详情。
  Future<List<TmdbWorkDetail>> fetchCandidateDetails(
    GroupedWorkFolder folder, {
    ScoredBangumiCandidate? bangumiCandidate,
    List<String> extraQueries = const [],
    void Function(Object error)? onNetworkError,
  }) async {
    final queries = ScrapeDomainAdapter.buildSearchQueries(
      folder,
      bangumiCandidate: bangumiCandidate,
      extraQueries: extraQueries,
    );
    final searchYear = ScrapeDomainAdapter.extractSearchYear(folder);
    final candidatesMap = <String, TmdbSearchResult>{};
    final typeFilter = _tvOnlyFilter(folder, bangumiCandidate?.subject);
    var networkAborted = false;

    Future<void> collectWave(
      Iterable<String> qs, {
      int? year,
      String language = 'zh-CN',
      required int cap,
    }) async {
      if (networkAborted) return;
      for (final q in qs) {
        try {
          final hits = await _tmdbService.searchAnime(
            q,
            year: year,
            language: language,
            mediaTypeFilter: typeFilter,
            priority: RequestPriority.background,
          );
          for (final h in hits) {
            candidatesMap.putIfAbsent(
              '${h.mediaType.name}:${h.tmdbId}',
              () => h,
            );
          }
          // 仅统计动画/未标分类候选计入波次上限，防止通用中文词（如 `避难所`）返回大量真人片挤掉英文文件名查询。
          final animCount = candidatesMap.values
              .where((h) => h.genreIds.contains(16) || h.genreIds.isEmpty)
              .length;
          if (animCount >= cap || candidatesMap.length >= cap * 4) break;
        } catch (error) {
          if (NetworkErrorSanitizer.isTransientNetworkError(error)) {
            networkAborted = true;
            onNetworkError?.call(error);
            return;
          }
          rethrow;
        }
      }
    }

    bool waveNeedsBackup() {
      if (networkAborted) return false;
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
    if (!networkAborted && (candidatesMap.length < 3 || waveNeedsBackup())) {
      await collectWave(queries.take(3), language: 'en-US', cap: 12);
    }
    if (!networkAborted && (candidatesMap.length < 3 || waveNeedsBackup())) {
      await collectWave(queries.take(3), language: 'ja-JP', cap: 12);
    }

    // Wave 4（零召回兜底）：前 3 波均彻底零召回时，先对多词英文/罗马音查询逐级裁去尾部外传/版本词，
    // 仍零召回且短集数（<=4 集）曾锁定仅搜 TV 时，再放开电影检索一次（如分篇剧场版）。
    // 正常已有候选的作品完全零开销。
    if (!networkAborted && candidatesMap.isEmpty) {
      final trimmedFallbacks = <String>[];
      final seenTrim = <String>{for (final q in queries) q.toLowerCase()};
      for (final q in queries.take(4)) {
        final tokens = q
            .split(RegExp(r'\s+'))
            .where((t) => t.isNotEmpty)
            .toList(growable: false);
        if (tokens.length < 3 || RegExp(r'[\u4e00-\u9fff]').hasMatch(q)) {
          continue;
        }
        for (var drop = 1; drop <= 2 && tokens.length - drop >= 2; drop++) {
          final cand = tokens.take(tokens.length - drop).join(' ').trim();
          if (cand.length >= 6 && seenTrim.add(cand.toLowerCase())) {
            trimmedFallbacks.add(cand);
          }
        }
      }
      if (trimmedFallbacks.isNotEmpty) {
        await collectWave(trimmedFallbacks.take(4), cap: 8);
      }
      if (!networkAborted &&
          candidatesMap.isEmpty &&
          typeFilter == TmdbMediaType.tv &&
          folder.mainEpisodeNumbers.toSet().length <= 4) {
        for (final q in queries.take(2)) {
          try {
            final movieHits = await _tmdbService.searchAnime(
              q,
              language: 'zh-CN',
              mediaTypeFilter: TmdbMediaType.movie,
              priority: RequestPriority.background,
            );
            for (final h in movieHits) {
              candidatesMap.putIfAbsent(
                '${h.mediaType.name}:${h.tmdbId}',
                () => h,
              );
            }
            if (candidatesMap.isNotEmpty) break;
          } catch (error) {
            if (NetworkErrorSanitizer.isTransientNetworkError(error)) {
              networkAborted = true;
              onNetworkError?.call(error);
              break;
            }
            rethrow;
          }
        }
      }
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

    final fetched = await _fetchAllInOrder(
      detailTargets,
      (item) => _tmdbService.getWorkDetail(
        item.tmdbId,
        item.mediaType,
        priority: RequestPriority.background,
        includeImages: false,
      ),
      onNetworkError: onNetworkError,
    );
    final details = fetched.results;
    networkAborted = fetched.aborted;
    if (!networkAborted) {
      details.addAll(
        await _recoverCanonicalEntries(
          folder,
          details,
          typeFilter: typeFilter,
          onNetworkError: onNetworkError,
        ),
      );
    }
    return details;
  }

  /// 前列候选几乎无人评分（多为新建的同名重复条目，常把正主挤出检索结果）时，
  /// 用其原名补搜一轮，把评分人数正常的正主条目找回候选池；最多补拉 3 条新详情。
  Future<List<TmdbWorkDetail>> _recoverCanonicalEntries(
    GroupedWorkFolder folder,
    List<TmdbWorkDetail> details, {
    TmdbMediaType? typeFilter,
    void Function(Object error)? onNetworkError,
  }) async {
    final known = {for (final d in details) '${d.mediaType.name}:${d.tmdbId}'};
    final originals = <String>{
      for (final d in details.take(3))
        if ((d.voteCount ?? _canonicalVoteFloor) < _canonicalVoteFloor &&
            (d.originalTitle?.trim().isNotEmpty ?? false))
          d.originalTitle!.trim(),
    };
    if (originals.isEmpty) return const [];
    // 任一步遇到瞬时网络异常都整体放弃补搜结果。
    final searches = await _fetchAllInOrder(
      originals.take(2),
      (original) => _tmdbService.searchAnime(
        original,
        mediaTypeFilter: typeFilter,
        priority: RequestPriority.background,
      ),
      onNetworkError: onNetworkError,
    );
    if (searches.aborted) return const [];
    final hits = <String, TmdbSearchResult>{};
    for (final results in searches.results) {
      for (final h in results) {
        final key = '${h.mediaType.name}:${h.tmdbId}';
        if (!known.contains(key)) hits.putIfAbsent(key, () => h);
      }
    }
    final ranked = [...hits.values]
      ..sort(
        (a, b) => ScrapeDomainAdapter.scoreSearchHitPreview(
          folder,
          b,
        ).compareTo(ScrapeDomainAdapter.scoreSearchHitPreview(folder, a)),
      );
    final recovered = await _fetchAllInOrder(
      ranked.take(3),
      (hit) => _tmdbService.getWorkDetail(
        hit.tmdbId,
        hit.mediaType,
        priority: RequestPriority.background,
        includeImages: false,
      ),
      onNetworkError: onNetworkError,
    );
    return recovered.aborted ? const [] : recovered.results;
  }

  /// 按 ID 补拉指定 TMDB 条目详情（映射直连或跨源补拉时使用；不存在的 ID 静默跳过）。
  Future<List<TmdbWorkDetail>> fetchDetailsByIds(
    List<({TmdbMediaType type, int id})> targets, {
    bool includeImages = false,
    void Function(Object error)? onNetworkError,
  }) async {
    final fetched = await _fetchAllInOrder(
      targets,
      (t) => _tmdbService.getWorkDetail(
        t.id,
        t.type,
        priority: RequestPriority.background,
        includeImages: includeImages,
      ),
      onNetworkError: onNetworkError,
    );
    return fetched.results;
  }

  /// TMDB 检索类型过滤：目录画像倾向剧集时锁定 `/search/tv`；
  /// 但仅 1～2 个编号正片且 Bangumi 条目标注为剧场版时放开电影检索
  /// （分上下篇放映的剧场版常被编号成两集，如 `次元大介の墓標 01/02`）。
  static TmdbMediaType? _tvOnlyFilter(
    GroupedWorkFolder folder,
    BangumiSubjectCandidate? bangumi,
  ) {
    if (!folder.prefersTvSearch) return null;
    final platform = bangumi?.platform?.trim() ?? '';
    final bangumiSaysMovie =
        platform == '剧场版' || platform.toLowerCase() == 'movie';
    if (bangumiSaysMovie && folder.mainEpisodeNumbers.toSet().length <= 4) {
      return null;
    }
    return TmdbMediaType.tv;
  }

  /// 当首轮 TMDB 未命中、跨源不一致被清空、或优胜条目缺少 16:9 横版背景图时，
  /// 使用已命中的 Bangumi 中/日文净化词干与年份进行二次 TMDB 兜底救回（如 `86` -> `tmdb-100565`）。
  Future<List<TmdbWorkDetail>> rescueTmdbByBangumi(
    GroupedWorkFolder folder,
    BangumiSubjectCandidate bangumi, {
    List<TmdbWorkDetail> existingDetails = const [],
    void Function(Object error)? onNetworkError,
  }) async {
    final rawNames = <String>[
      if (bangumi.nameCn.trim().isNotEmpty) bangumi.nameCn.trim(),
      if (bangumi.name.trim().isNotEmpty) bangumi.name.trim(),
    ];
    final querySet = <String>{};
    for (final name in rawNames) {
      for (final q in SearchQuerySanitizer.buildBangumiFallbackQueries(name)) {
        querySet.add(q);
      }
    }
    final queries = querySet.toList(growable: false);
    if (queries.isEmpty) return existingDetails;

    final seenIds = <String>{
      for (final d in existingDetails) '${d.mediaType.name}:${d.tmdbId}',
    };
    final hitMap = <String, TmdbSearchResult>{};
    final typeFilter = _tvOnlyFilter(folder, bangumi);
    var networkAborted = false;

    bool isYearCompatibleAnimation(TmdbSearchResult h) =>
        h.genreIds.contains(16) &&
        (bangumi.year == null ||
            h.year == null ||
            (h.year! - bangumi.year!).abs() <= 1);

    Future<void> runSearch(
      Iterable<String> qs, {
      int? year,
      required String lang,
    }) async {
      if (networkAborted) return;
      for (final q in qs) {
        try {
          final hits = await _tmdbService.searchAnime(
            q,
            year: year,
            language: lang,
            mediaTypeFilter: typeFilter,
            priority: RequestPriority.background,
          );
          for (final h in hits) {
            final k = '${h.mediaType.name}:${h.tmdbId}';
            if (!seenIds.contains(k)) {
              hitMap.putIfAbsent(k, () => h);
            }
          }
          final animCount = hitMap.values
              .where(isYearCompatibleAnimation)
              .length;
          if (animCount >= 6) break;
        } catch (error) {
          if (NetworkErrorSanitizer.isTransientNetworkError(error)) {
            networkAborted = true;
            onNetworkError?.call(error);
            return;
          }
          rethrow;
        }
      }
    }

    bool hasAnimationHit() => hitMap.values.any(isYearCompatibleAnimation);

    await runSearch(queries.take(3), year: bangumi.year, lang: 'zh-CN');
    if (!networkAborted && !hasAnimationHit() && bangumi.year != null) {
      await runSearch(queries.take(3), lang: 'zh-CN');
    }
    if (!networkAborted && !hasAnimationHit()) {
      final asciiQueries = queries
          .where((q) => RegExp(r'[A-Za-z]{3,}').hasMatch(q))
          .take(2)
          .toList(growable: false);
      if (asciiQueries.isNotEmpty) {
        if (bangumi.year != null) {
          await runSearch(asciiQueries, year: bangumi.year, lang: 'en-US');
        }
        if (!networkAborted && !hasAnimationHit()) {
          await runSearch(asciiQueries, lang: 'en-US');
        }
      }
    }
    if (!networkAborted && !hasAnimationHit()) {
      await runSearch(queries.take(2), lang: 'ja-JP');
    }
    if (hitMap.isEmpty) return existingDetails;

    final rankedHits = hitMap.values.toList(growable: false)
      ..sort((a, b) {
        final aAnim = a.genreIds.contains(16) ? 0 : 1;
        final bAnim = b.genreIds.contains(16) ? 0 : 1;
        if (aAnim != bAnim) return aAnim.compareTo(bAnim);
        final aYear = (bangumi.year != null && a.year == bangumi.year) ? 0 : 1;
        final bYear = (bangumi.year != null && b.year == bangumi.year) ? 0 : 1;
        if (aYear != bYear) return aYear.compareTo(bYear);
        final aPoster = (a.posterPath?.isNotEmpty ?? false) ? 0 : 1;
        final bPoster = (b.posterPath?.isNotEmpty ?? false) ? 0 : 1;
        return aPoster.compareTo(bPoster);
      });

    final rescued = await _fetchAllInOrder(
      rankedHits.take(4),
      (hit) => _tmdbService.getWorkDetail(
        hit.tmdbId,
        hit.mediaType,
        priority: RequestPriority.background,
        includeImages: false,
      ),
      onNetworkError: onNetworkError,
    );
    return [
      ...existingDetails,
      for (final detail in rescued.results)
        if (seenIds.add('${detail.mediaType.name}:${detail.tmdbId}')) detail,
    ];
  }

  /// 一次拉取各引用季完整详情（含单季专属封面、季名、简介与分集列表）。
  Future<
    ({
      List<TmdbEpisodeDetail> episodes,
      Map<int, TmdbSeasonDetail> seasonDetails,
    })
  >
  fetchSeasonBundle(
    int tmdbId,
    TmdbMediaType mediaType,
    Set<int> seasons, {
    void Function(Object error)? onNetworkError,
  }) async {
    if (mediaType != TmdbMediaType.tv) {
      return (
        episodes: const <TmdbEpisodeDetail>[],
        seasonDetails: const <int, TmdbSeasonDetail>{},
      );
    }
    final targetSeasons = seasons.isEmpty ? {1} : seasons;
    final fetched = await _fetchAllInOrder(targetSeasons, (season) async {
      final detail = await _tmdbService.getSeasonDetail(
        tmdbId,
        season,
        priority: RequestPriority.background,
      );
      return detail == null ? null : (season: season, detail: detail);
    }, onNetworkError: onNetworkError);
    final allEpisodes = <TmdbEpisodeDetail>[];
    final details = <int, TmdbSeasonDetail>{};
    for (final entry in fetched.results) {
      details[entry.season] = entry.detail;
      allEpisodes.addAll(entry.detail.episodes);
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
