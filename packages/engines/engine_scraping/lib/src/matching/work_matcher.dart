import '../models/tmdb_models.dart';
import '../scraping/bangumi_models.dart';
import 'directory_grouper.dart';
import 'work_matcher_scoring.dart';

/// 候选匹配决策等级。
enum MatchLevel {
  /// 高置信度，可安全自动绑定。
  autoBind,

  /// 存在歧义或中等置信度，进入待复核并保存 Top-5 候选。
  reviewRequired,

  /// 未找到有效匹配候选。
  unmatched,
}

/// 单个候选的打分明细。
class ScoredTmdbCandidate {
  /// 创建候选打分明细。
  const ScoredTmdbCandidate({
    required this.detail,
    required this.score,
    required this.reasons,
    this.matchedSeason,
  });

  /// TMDB 候选详情。
  final TmdbWorkDetail detail;

  /// 综合得分。
  final double score;

  /// 得分与扣分原因说明码列表。
  final List<String> reasons;

  /// 该候选命中的季号（仅 TV 多季作品可能非空）。
  final int? matchedSeason;
}

/// 最终匹配决策结果（强类型输出）。
class MatchDecision {
  /// 创建决策结果。
  const MatchDecision({
    required this.level,
    this.best,
    required this.topCandidates,
    this.bestBangumi,
    this.topBangumiCandidates = const [],
    this.matchedSeason,
    this.primaryReason = '',
    this.reviewReason,
  });

  /// 最终匹配等级。
  final MatchLevel level;

  /// 排名第一的最佳 TMDB 候选。
  final ScoredTmdbCandidate? best;

  /// 按得分降序排列的 Top-5 TMDB 候选列表。
  final List<ScoredTmdbCandidate> topCandidates;

  /// 排名第一的最佳 Bangumi 候选。
  final ScoredBangumiCandidate? bestBangumi;

  /// Bangumi Top 候选列表。
  final List<ScoredBangumiCandidate> topBangumiCandidates;

  /// 最佳候选绑定的目标季号（由 WorkMatcher 季级消歧得出）。
  final int? matchedSeason;

  /// 主要决策/待复核原因码。
  final String primaryReason;

  /// 供 UI 与数据库直接展示的简体中文待复核说明。
  final String? reviewReason;
}

/// 确定性多信号作品匹配打分器（纯函数，零 IO）。
class WorkMatcher {
  const WorkMatcher._();

  static const Set<String> _hardConflictCodes = {
    'year_mismatch',
    'media_type_conflict',
    'explicit_id_mismatch',
  };

  /// 对候选集执行归一化打分并给出自动绑定或人工复核决策。
  static MatchDecision evaluate(
    GroupedWorkFolder folder,
    List<TmdbWorkDetail> candidates,
  ) {
    if (candidates.isEmpty) {
      return const MatchDecision(
        level: MatchLevel.unmatched,
        topCandidates: [],
        primaryReason: 'no_candidates',
        reviewReason: '未检索到任何匹配的 TMDB 条目',
      );
    }

    final scored = <ScoredTmdbCandidate>[];
    for (final candidate in candidates) {
      final result = WorkMatcherScoring.scoreCandidate(folder, candidate);
      scored.add(
        ScoredTmdbCandidate(
          detail: candidate,
          score: result.score,
          reasons: result.reasons,
        ),
      );
    }
    scored.sort((a, b) => b.score.compareTo(a.score));

    final top5 = scored.take(5).toList(growable: false);
    final best = top5.first;
    final second = top5.length > 1 ? top5[1] : null;

    if (folder.explicitTmdbId != null &&
        best.detail.tmdbId == folder.explicitTmdbId) {
      return MatchDecision(
        level: MatchLevel.autoBind,
        best: best,
        topCandidates: top5,
        primaryReason: 'explicit_tmdb_match',
      );
    }

    final margin = second == null ? 999.0 : best.score - second.score;
    final hasHardConflict = best.reasons.any(_hardConflictCodes.contains);
    // 无年份提示但标题精确一致且无任何硬冲突与强竞争者时，50 分同样允许安全自动绑定。
    final meetsAutoBindScore =
        best.score >= 52.0 ||
        (best.score >= 50.0 && best.reasons.contains('exact_title_match'));

    if (meetsAutoBindScore && margin >= 10.0 && !hasHardConflict) {
      return MatchDecision(
        level: MatchLevel.autoBind,
        best: best,
        topCandidates: top5,
        primaryReason: 'high_confidence',
      );
    }

    if (best.score >= 22.0) {
      final isClose =
          margin < 10.0 && second != null && second.score >= 25.0;
      final primaryCode = isClose
          ? 'close_candidates'
          : (hasHardConflict
                ? best.reasons.firstWhere(
                    _hardConflictCodes.contains,
                    orElse: () => 'low_confidence',
                  )
                : 'low_confidence');
      return MatchDecision(
        level: MatchLevel.reviewRequired,
        best: best,
        topCandidates: top5,
        primaryReason: primaryCode,
        reviewReason: _buildChineseReviewSummary(
          primaryCode: primaryCode,
          reasons: best.reasons,
        ),
      );
    }

    return MatchDecision(
      level: MatchLevel.unmatched,
      best: best,
      topCandidates: top5,
      primaryReason: 'no_match',
      reviewReason: '候选评分过低，请手动指定正确作品',
    );
  }

  static String _buildChineseReviewSummary({
    required String primaryCode,
    required List<String> reasons,
  }) {
    if (primaryCode == 'close_candidates') {
      return '存在多个高分相近候选，请确认准确条目';
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
}
