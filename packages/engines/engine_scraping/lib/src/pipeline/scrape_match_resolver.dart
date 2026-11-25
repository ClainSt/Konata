import '../matching/directory_grouper.dart';
import '../matching/work_matcher.dart';
import '../models/tmdb_models.dart';
import '../models/work.dart';
import '../scraping/bangumi_models.dart';
import '../scraping/bangumi_tmdb_index.dart';
import '../scraping/scrape_rules.dart' as rules;
import 'hard_work_rescue_engine.dart';
import 'scrape_candidate_fetcher.dart';
import 'scrape_compute_worker.dart';

/// 刮削阶段 3 在线匹配的决策结果（不含任何落库动作）。
class ScrapeMatchResolution {
  /// 创建匹配决策结果。
  const ScrapeMatchResolution({
    required this.decision,
    required this.bangumiTier,
    required this.bestBangumi,
    required this.bangumiCandidates,
    required this.candidates,
    this.rescuedByHardRules = false,
    this.networkError,
  });

  /// TMDB 与 Bangumi 联合打分后的最终决策。
  final MatchDecision decision;

  /// Bangumi 初轮检索的匹配等级。
  final MatchTier bangumiTier;

  /// Bangumi 初轮检索的最佳候选（网络异常降级入库时使用）。
  final ScoredBangumiCandidate? bestBangumi;

  /// 参与决策的全部 Bangumi 候选。
  final List<BangumiSubjectCandidate> bangumiCandidates;

  /// 参与决策的全部 TMDB 候选详情。
  final List<TmdbWorkDetail> candidates;

  /// 是否经由第二套困难目录专属救援规则成功升格自动绑定。
  final bool rescuedByHardRules;

  /// 本阶段首个 TMDB 瞬时网络异常（无异常时为空）。
  final Object? networkError;
}

/// 刮削阶段 3 在线匹配决策器：Bangumi 在线优先匹配 → 离线映射表直连快通道 →
/// 交叉关键词救回 TMDB 搜索 → 合集父系列兜底 → Bangumi 反向救回 → 双向互保重评。
/// 只做检索与打分，不写数据库，供调度器入库流程与离线/在线准确率评测共用同一套决策逻辑。
class ScrapeMatchResolver {
  /// 创建匹配决策器。
  const ScrapeMatchResolver({
    required this._fetcher,
    this._computeWorker = const ScrapeComputeWorker(),
    this._mappingIndex,
  });

  /// 允许触发离线映射直连快通道的单条最大去重目标数（过多剧场版分拆目标直接走常规检索）。
  static const int _fastPathMaxTargets = 3;

  final ScrapeCandidateFetcher _fetcher;
  final ScrapeComputeWorker _computeWorker;
  final BangumiTmdbIndex? _mappingIndex;

  /// 对单个作品分组执行在线匹配；[tmdbUnavailable] 为真时（前序阶段已遇 TMDB 网络异常）跳过 TMDB 检索。
  Future<ScrapeMatchResolution> resolve(
    GroupedWorkFolder folder, {
    bool tmdbUnavailable = false,
    ScrapeComputeWorker? computeWorker,
  }) async {
    final compute = computeWorker ?? _computeWorker;
    Object? networkError;
    void recordError(Object err) {
      networkError ??= err;
    }

    bool tmdbBlocked() => tmdbUnavailable || networkError != null;

    // 父系列目录上下文仅作为可选补充检索词；其瞬时网络波动不阻断后续主作品 TMDB 检索。
    final parentCtx = await _fetcher.fetchParentCollectionContext(folder);
    var bgmCandidates = await _fetcher.fetchBangumiCandidates(
      folder,
      extraQueries: parentCtx.extraQueries,
    );
    final bgmEval = await compute.evaluateBangumiMatch(folder, bgmCandidates);

    // 离线映射直连快通道：Bangumi 高置信命中离线映射且目标数精简（<= 3）时，
    // 仅拉取映射指向的 1~3 条 TMDB 轻量详情并执行完整复核；若确认高置信 autoBind 则直接短路跳过全部 TMDB 关键词检索，
    // 否则无缝回退常规全量检索并复用已拉取详情，保证准确率零妥协。
    final bgmBest = bgmEval.best;
    final expectsMovie = rules.expectsStandaloneMovie(
      folder,
      bgmBest?.subject,
    );
    final preloadedMapped = <TmdbWorkDetail>[];
    final orderedMappedTargets = (!tmdbBlocked() &&
            bgmBest != null &&
            bgmEval.tier == MatchTier.high)
        ? _orderedUniqueMappedTargets(bgmBest.subject)
        : const <({TmdbMediaType type, int id})>[];

    if (!tmdbBlocked() &&
        orderedMappedTargets.isNotEmpty &&
        orderedMappedTargets.length <= _fastPathMaxTargets) {
      final fastDetails = await _fetcher.fetchDetailsByIds(
        orderedMappedTargets,
        includeImages: false,
        onNetworkError: recordError,
      );
      if (fastDetails.isNotEmpty) {
        preloadedMapped.addAll(fastDetails);
        if (!tmdbBlocked()) {
          final fastDecision = await compute.evaluateMatch(
            folder,
            fastDetails,
            bangumiCandidates: bgmCandidates,
            mappingIndex: _mappingIndex,
          );
          final fastBest = fastDecision.best;
          // 当本地目录或 Bangumi 明确指向剧场版、但映射仅返回母剧 TV 条目时，
          // 或非剧场版电视特别篇/OVA 被映射指向无横版背景图的低人气孤岛电影时，
          // 均不短路快通道，继续搜索正主条目参与同池竞争。
          final movieHijackedByTv =
              expectsMovie &&
              fastBest != null &&
              fastBest.detail.mediaType == TmdbMediaType.tv;
          final nonMovieHijackedByOrphanMovie =
              !expectsMovie &&
              fastBest != null &&
              fastBest.detail.mediaType == TmdbMediaType.movie &&
              (fastBest.detail.backdropPath?.trim().isEmpty ?? true) &&
              (fastBest.detail.voteCount ?? 0) < 20;
          if (fastDecision.level == MatchLevel.autoBind &&
              fastDecision.primaryReason == 'high_confidence' &&
              fastBest != null &&
              !movieHijackedByTv &&
              !nonMovieHijackedByOrphanMovie &&
              fastBest.score >= 70 &&
              (fastBest.detail.voteCount ?? 1) > 0) {
            return ScrapeMatchResolution(
              decision: fastDecision,
              bangumiTier: bgmEval.tier,
              bestBangumi: bgmEval.best,
              bangumiCandidates: bgmCandidates,
              candidates: fastDetails,
              networkError: networkError,
            );
          }
        }
      }
    }

    // 仅当 Bangumi 达到高置信、或中置信且标题分足够可信（避免仅靠单字巧合的弱候选污染 TMDB 第一波词）时，才借用其别名扩展检索。
    final bgmTitleScore = bgmBest == null
        ? 0.0
        : bgmBest.reasons
              .where((r) => r.endsWith(' title'))
              .map((r) => double.tryParse(r.split(' ').first) ?? 0.0)
              .fold<double>(0.0, (m, v) => v > m ? v : m);
    final trustedBgmForTmdb =
        bgmBest != null &&
        (bgmEval.tier == MatchTier.high ||
            (bgmEval.tier == MatchTier.medium && bgmTitleScore >= 32.0));

    var candidates = tmdbBlocked()
        ? List<TmdbWorkDetail>.of(preloadedMapped)
        : await _fetcher.fetchCandidateDetails(
            folder,
            bangumiCandidate: trustedBgmForTmdb ? bgmBest : null,
            extraQueries: parentCtx.extraQueries,
            onNetworkError: recordError,
          );
    if (preloadedMapped.isNotEmpty) {
      final mergedByKey = <String, TmdbWorkDetail>{
        for (final c in candidates) '${c.mediaType.name}:${c.tmdbId}': c,
        for (final m in preloadedMapped) '${m.mediaType.name}:${m.tmdbId}': m,
      };
      candidates = mergedByKey.values.toList(growable: false);
    }

    // Bangumi 命中（高置信或标题可信的中置信）经离线映射指向的 TMDB 条目若未被关键词检索召回，按 ID 补拉进候选池参与公平打分。
    final supplementMappedTargets = (!tmdbBlocked() && trustedBgmForTmdb)
        ? (orderedMappedTargets.isNotEmpty
              ? orderedMappedTargets
              : _orderedUniqueMappedTargets(
                  bgmBest.subject,
                ).take(2).toList(growable: false))
        : const <({TmdbMediaType type, int id})>[];
    if (!tmdbBlocked() && supplementMappedTargets.isNotEmpty) {
      final missing = <({TmdbMediaType type, int id})>[
        for (final m in supplementMappedTargets)
          if (!candidates.any((c) => c.mediaType == m.type && c.tmdbId == m.id))
            m,
      ];
      if (missing.isNotEmpty) {
        candidates = [
          ...candidates,
          ...await _fetcher.fetchDetailsByIds(
            missing,
            includeImages: false,
            onNetworkError: recordError,
          ),
        ];
      }
    }
    var decision = await compute.evaluateMatch(
      folder,
      candidates,
      bangumiCandidates: bgmCandidates,
      mappingIndex: _mappingIndex,
    );

    // 若独立子簇（如 `Accel World EX` 或电视特别篇）未命中独立 TMDB 条目、或仅命中缺横版背景图的孤岛电影，
    // 且允许回退父系列，将父 TMDB 加入候选池参与重评。
    final orphanBackdropMissingNonMovie =
        decision.best != null &&
        decision.best!.detail.mediaType == TmdbMediaType.movie &&
        (decision.best!.detail.backdropPath?.trim().isEmpty ?? true) &&
        !expectsMovie;
    if (folder.allowParentTmdbCandidate &&
        parentCtx.parentDetail != null &&
        (decision.best == null || orphanBackdropMissingNonMovie)) {
      final pDetail = parentCtx.parentDetail!;
      final mergedDetails = <String, TmdbWorkDetail>{
        for (final c in candidates) '${c.mediaType.name}:${c.tmdbId}': c,
        '${pDetail.mediaType.name}:${pDetail.tmdbId}': pDetail,
      }.values.toList(growable: false);
      final rescored = await compute.evaluateMatch(
        folder,
        mergedDetails,
        bangumiCandidates: bgmCandidates,
        mappingIndex: _mappingIndex,
      );
      if (rescored.level != MatchLevel.unmatched) {
        candidates = mergedDetails;
        decision = rescored;
      }
    }

    // 当初轮 TMDB 未命中、跨源不一致被清空、或优胜条目缺少 16:9 横版背景图时，
    // 使用已命中的可信 Bangumi 中/日文净化词干与年份进行二次 `/search/tv` 兜底救回。
    final rescueBgmTarget =
        decision.bestBangumi ?? (trustedBgmForTmdb ? bgmEval.best : null);
    if (!tmdbBlocked() &&
        rescueBgmTarget != null &&
        (decision.best == null ||
            (decision.best!.detail.backdropPath?.trim().isEmpty ?? true))) {
      final rescued = await _fetcher.rescueTmdbByBangumi(
        folder,
        rescueBgmTarget.subject,
        existingDetails: candidates,
        onNetworkError: recordError,
      );
      if (rescued.length > candidates.length) {
        candidates = rescued;
        decision = await compute.evaluateMatch(
          folder,
          candidates,
          bangumiCandidates: bgmCandidates,
          mappingIndex: _mappingIndex,
        );
      }
    }

    // 若 Bangumi 初搜落空但 TMDB 给出强候选，使用 TMDB 中/原名反向救回 Bangumi 条目。
    if (bgmEval.tier == MatchTier.none &&
        decision.best != null &&
        _fetcher.bangumiService != null) {
      final tWinner = decision.best!.detail;
      final rescueQueries = [
        tWinner.title,
        if (tWinner.originalTitle != null) tWinner.originalTitle!,
        ...tWinner.aliases.take(2),
      ].map((s) => s.trim()).where((s) => s.isNotEmpty).toSet().toList();
      if (rescueQueries.isNotEmpty) {
        final extraBgm = await _fetcher.fetchBangumiCandidates(
          folder,
          extraQueries: rescueQueries,
        );
        if (extraBgm.isNotEmpty) {
          bgmCandidates = <int, BangumiSubjectCandidate>{
            for (final b in bgmCandidates) b.id: b,
            for (final b in extraBgm) b.id: b,
          }.values.toList(growable: false);
          decision = await compute.evaluateMatch(
            folder,
            candidates,
            bangumiCandidates: bgmCandidates,
            mappingIndex: _mappingIndex,
          );
        }
      }
    }

    // 第二套困难目录专属救援规则（Pass 2）：仅在首轮未达成 autoBind 且网络可用时按需触发，
    // 首轮高置信命中作品零开销；通过深度去噪、文件名主干接管、增量补搜与安全门禁挽救高难目录。
    var rescuedByHardRules = false;
    if (!tmdbBlocked() && decision.level != MatchLevel.autoBind) {
      final rescueEngine = HardWorkRescueEngine(
        fetcher: _fetcher,
        mappingIndex: _mappingIndex,
      );
      final rescueOutcome = await rescueEngine.rescue(
        originalFolder: folder,
        pass1Decision: decision,
        existingBangumi: bgmCandidates,
        existingTmdb: candidates,
        computeWorker: compute,
        onNetworkError: recordError,
      );
      bgmCandidates = rescueOutcome.bangumiCandidates;
      candidates = rescueOutcome.candidates;
      if (rescueOutcome.adopted) {
        decision = rescueOutcome.decision;
        rescuedByHardRules = rescueOutcome.rescuedToAutoBind;
      }
    }

    return ScrapeMatchResolution(
      decision: decision,
      bangumiTier: bgmEval.tier,
      bestBangumi: bgmEval.best,
      bangumiCandidates: bgmCandidates,
      candidates: candidates,
      rescuedByHardRules: rescuedByHardRules,
      networkError: networkError,
    );
  }

  List<({TmdbMediaType type, int id})> _orderedUniqueMappedTargets(
    BangumiSubjectCandidate subject,
  ) {
    final preferMovie = (subject.platform?.trim() ?? '') == '剧场版';
    final raw = BangumiTmdbIndex.resolveTargets(
      subject.id,
      index: _mappingIndex,
    );
    if (raw.isEmpty) return const [];
    final sorted = List<BangumiTmdbTarget>.of(raw)
      ..sort((a, b) {
        int typeRank(BangumiTmdbTarget t) =>
            (preferMovie
                    ? t.type == TmdbMediaType.movie
                    : t.type == TmdbMediaType.tv)
                ? 0
                : 1;
        final byType = typeRank(a).compareTo(typeRank(b));
        if (byType != 0) return byType;
        final aSeason = a.season != null && a.season! > 0 ? 0 : 1;
        final bSeason = b.season != null && b.season! > 0 ? 0 : 1;
        if (aSeason != bSeason) return aSeason.compareTo(bSeason);
        final aOpen = a.isOpenAni ? 0 : 1;
        final bOpen = b.isOpenAni ? 0 : 1;
        return aOpen.compareTo(bOpen);
      });
    final seen = <String>{};
    return [
      for (final t in sorted)
        if (seen.add(t.key)) (type: t.type, id: t.id),
    ];
  }
}
