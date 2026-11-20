import '../../domain/matching/directory_grouper.dart';
import '../../domain/matching/work_matcher.dart';
import '../../domain/models/tmdb_models.dart';
import '../../domain/scraping/bangumi_models.dart';
import '../../domain/scraping/bangumi_tmdb_map.dart';
import '../../domain/scraping/work_matcher.dart' as legacy;
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
    this.networkError,
  });

  /// TMDB 与 Bangumi 联合打分后的最终决策。
  final MatchDecision decision;

  /// Bangumi 初轮检索的匹配等级。
  final legacy.MatchTier bangumiTier;

  /// Bangumi 初轮检索的最佳候选（网络异常降级入库时使用）。
  final ScoredBangumiCandidate? bestBangumi;

  /// 参与决策的全部 Bangumi 候选。
  final List<BangumiSubjectCandidate> bangumiCandidates;

  /// 参与决策的全部 TMDB 候选详情。
  final List<TmdbWorkDetail> candidates;

  /// 本阶段首个 TMDB 瞬时网络异常（无异常时为空）。
  final Object? networkError;
}

/// 刮削阶段 3 在线匹配决策器：Bangumi 在线优先匹配 → 交叉关键词救回 TMDB 搜索 →
/// 合集父系列兜底 → Bangumi 反向救回 → 双向互保重评。只做检索与打分，不写数据库，
/// 供调度器入库流程与离线/在线准确率评测共用同一套决策逻辑。
class ScrapeMatchResolver {
  /// 创建匹配决策器。
  const ScrapeMatchResolver({
    required this._fetcher,
    this._computeWorker = const ScrapeComputeWorker(),
  });

  final ScrapeCandidateFetcher _fetcher;
  final ScrapeComputeWorker _computeWorker;

  /// 对单个作品分组执行在线匹配；[tmdbUnavailable] 为真时（前序阶段已遇 TMDB 网络异常）跳过 TMDB 检索。
  Future<ScrapeMatchResolution> resolve(
    GroupedWorkFolder folder, {
    bool tmdbUnavailable = false,
  }) async {
    Object? networkError;
    void recordError(Object err) {
      networkError ??= err;
    }

    bool tmdbBlocked() => tmdbUnavailable || networkError != null;

    final parentCtx = await _fetcher.fetchParentCollectionContext(
      folder,
      onNetworkError: recordError,
    );
    var bgmCandidates = await _fetcher.fetchBangumiCandidates(
      folder,
      extraQueries: parentCtx.extraQueries,
    );
    final bgmEval = await _computeWorker.evaluateBangumiMatch(
      folder,
      bgmCandidates,
    );

    var candidates = tmdbBlocked()
        ? const <TmdbWorkDetail>[]
        : await _fetcher.fetchCandidateDetails(
            folder,
            bangumiCandidate: bgmEval.best,
            extraQueries: parentCtx.extraQueries,
            onNetworkError: recordError,
          );
    // Bangumi 高置信条目经 Wikidata 映射到的 TMDB 条目若未被关键词检索召回，按 ID 补拉进候选池。
    final bgmBest = bgmEval.best;
    if (!tmdbBlocked() &&
        bgmBest != null &&
        bgmEval.tier == legacy.MatchTier.high) {
      final missing = [
        for (final m in BangumiTmdbMap.lookup(bgmBest.subject.id))
          if (!candidates.any((c) => c.mediaType == m.type && c.tmdbId == m.id))
            m,
      ];
      if (missing.isNotEmpty) {
        candidates = [
          ...candidates,
          ...await _fetcher.fetchDetailsByIds(
            missing,
            onNetworkError: recordError,
          ),
        ];
      }
    }
    var decision = await _computeWorker.evaluateMatch(
      folder,
      candidates,
      bangumiCandidates: bgmCandidates,
    );

    // 若独立子簇（如 `Accel World EX`）未命中独立 TMDB 条目且允许回退父系列，将父 TMDB 加入重评。
    if (folder.allowParentTmdbCandidate &&
        parentCtx.parentDetail != null &&
        decision.best == null) {
      final pDetail = parentCtx.parentDetail!;
      final mergedDetails = <String, TmdbWorkDetail>{
        for (final c in candidates) '${c.mediaType.name}:${c.tmdbId}': c,
        '${pDetail.mediaType.name}:${pDetail.tmdbId}': pDetail,
      }.values.toList(growable: false);
      final rescored = await _computeWorker.evaluateMatch(
        folder,
        mergedDetails,
        bangumiCandidates: bgmCandidates,
      );
      if (rescored.level != MatchLevel.unmatched) {
        candidates = mergedDetails;
        decision = rescored;
      }
    }

    // 当初轮 TMDB 未命中、跨源不一致被清空、或优胜条目缺少 16:9 横版背景图时，
    // 使用已命中的 Bangumi 中/日文净化词干与年份进行二次 `/search/tv` 兜底救回。
    final rescueBgmTarget = decision.bestBangumi ?? bgmEval.best;
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
        decision = await _computeWorker.evaluateMatch(
          folder,
          candidates,
          bangumiCandidates: bgmCandidates,
        );
      }
    }

    // 若 Bangumi 初搜落空但 TMDB 给出强候选，使用 TMDB 中/原名反向救回 Bangumi 条目。
    if (bgmEval.tier == legacy.MatchTier.none &&
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
          decision = await _computeWorker.evaluateMatch(
            folder,
            candidates,
            bangumiCandidates: bgmCandidates,
          );
        }
      }
    }

    return ScrapeMatchResolution(
      decision: decision,
      bangumiTier: bgmEval.tier,
      bestBangumi: bgmEval.best,
      bangumiCandidates: bgmCandidates,
      candidates: candidates,
      networkError: networkError,
    );
  }
}
