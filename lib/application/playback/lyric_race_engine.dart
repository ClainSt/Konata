import 'dart:async';

import '../../domain/lyrics/lyric_candidate.dart';
import '../../domain/lyrics/lyric_candidate_scorer.dart';
import '../../domain/lyrics/lyric_merger.dart';
import '../../domain/lyrics/lyric_search_query.dart';
import 'lyric_candidate_sources.dart';

/// 竞速收束结果。
class LyricRaceSettlement {
  /// 创建收束结果。
  const LyricRaceSettlement({
    required this.best,
    required this.anySourceResponded,
    required this.allSourcesFinished,
    required this.cancelled,
    this.plainFallback,
    this.allCandidates = const [],
  });

  /// 全程最优合格同步候选（经跨源验证与借译文/借罗马音增强；低于低置信度阈值时为空）。
  final ScoredLyricCandidate? best;

  /// 无同步歌词时的最佳纯文本候选（保留供后续展示或对齐使用）。
  final ScoredLyricCandidate? plainFallback;

  /// 本次竞速收集到的全部合格同步候选。
  final List<ScoredLyricCandidate> allCandidates;

  /// 是否至少一个来源完整正常响应。
  final bool anySourceResponded;

  /// 是否全部来源均已结束（未因预算截止或取消而中断）。
  final bool allSourcesFinished;

  /// 是否被外部取消。
  final bool cancelled;

  /// 能否写入“未找到”负缓存：全部来源结束、至少一个正常响应且无合格同步候选。
  bool get isConfirmedNotFound =>
      best == null && allSourcesFinished && anySourceResponded && !cancelled;
}

/// 多来源并行歌词竞速器：首个可自动采用候选出现后经短暂宽限期即上屏；
/// 仅有低置信度候选时到达软截止即上屏；其余来源继续收集并在收束时执行跨源一致性验证与借译文/罗马音合并。
class LyricRaceEngine {
  /// 创建竞速器。
  const LyricRaceEngine({
    required this.firstPaintGrace,
    required this.lowConfidencePaintAfter,
    required this.deadline,
    this.onSourceError,
  });

  /// 首个可自动采用候选出现后的宽限期。
  final Duration firstPaintGrace;

  /// 自竞速开始起，仅有低置信度合格候选时的首屏软截止。
  final Duration lowConfidencePaintAfter;

  /// 单次竞速总预算。
  final Duration deadline;

  /// 来源异常回调。
  final void Function(String label, Object error)? onSourceError;

  /// 启动一次竞速会话。
  LyricRaceSession start(
    LyricSearchQuery query,
    List<LyricCandidateSource> sources,
  ) {
    return LyricRaceSession._(this, query, sources).._run();
  }
}

/// 单次歌词竞速会话。
class LyricRaceSession {
  LyricRaceSession._(this._engine, this._query, this._sources);

  final LyricRaceEngine _engine;
  final LyricSearchQuery _query;
  final List<LyricCandidateSource> _sources;

  final Completer<ScoredLyricCandidate?> _firstPaint = Completer();
  final Completer<LyricRaceSettlement> _settled = Completer();
  final List<StreamSubscription<LyricCandidate>> _subs = [];
  final List<LyricCandidate> _qualifiedSynced = [];
  Timer? _graceTimer;
  Timer? _softPaintTimer;
  Timer? _deadlineTimer;
  ScoredLyricCandidate? _best;
  ScoredLyricCandidate? _bestPlain;
  var _finishedSources = 0;
  var _anyResponded = false;
  var _softPaintDue = false;

  /// 首屏可显示候选（无合格同步候选时为空）。
  Future<ScoredLyricCandidate?> get firstPaint => _firstPaint.future;

  /// 全部来源结束或预算截止后的最终收束结果。
  Future<LyricRaceSettlement> get settled => _settled.future;

  void _run() {
    if (_sources.isEmpty) {
      _settle();
      return;
    }
    _deadlineTimer = Timer(_engine.deadline, _settle);
    _softPaintTimer = Timer(_engine.lowConfidencePaintAfter, () {
      _softPaintDue = true;
      _completeFirstPaintIfAny();
    });
    for (final source in _sources) {
      var sourceFailed = false;
      _subs.add(
        source
            .candidates(_query)
            .listen(
              _onCandidate,
              onError: (Object error) {
                sourceFailed = true;
                _engine.onSourceError?.call(source.label, error);
              },
              onDone: () {
                if (!sourceFailed) _anyResponded = true;
                _finishedSources++;
                if (_finishedSources >= _sources.length) _settle();
              },
            ),
      );
    }
  }

  void _onCandidate(LyricCandidate candidate) {
    if (_settled.isCompleted) return;
    final baseScore = LyricCandidateScorer.score(_query, candidate);
    if (baseScore == null || baseScore < LyricMatchThresholds.lowConfidence) {
      return;
    }

    if (!candidate.isSynced) {
      final currentPlain = _bestPlain;
      if (currentPlain == null || baseScore > currentPlain.score) {
        _bestPlain = ScoredLyricCandidate(candidate, baseScore);
      }
      return;
    }

    _qualifiedSynced.add(candidate);
    _recomputeBest();

    final best = _best;
    if (best != null &&
        best.score >= LyricMatchThresholds.autoAccept &&
        _graceTimer == null &&
        !_firstPaint.isCompleted) {
      _graceTimer = Timer(_engine.firstPaintGrace, _completeFirstPaintIfAny);
    }
    if (_softPaintDue) _completeFirstPaintIfAny();
  }

  /// 基于已收集的全部合格同步候选执行跨源验证与借译文/借罗马音合并，并刷新当前最优候选。
  void _recomputeBest() {
    if (_qualifiedSynced.isEmpty) {
      _best = null;
      return;
    }

    ScoredLyricCandidate? best;
    for (var i = 0; i < _qualifiedSynced.length; i++) {
      final raw = _qualifiedSynced[i];
      final others = <LyricCandidate>[
        for (var j = 0; j < _qualifiedSynced.length; j++)
          if (j != i) _qualifiedSynced[j],
      ];
      final enriched = others.isEmpty
          ? CrossSourceEnrichment(
              candidate: raw,
              crossSourceAgreed: false,
              borrowedTranslation: false,
              borrowedRomaji: false,
            )
          : LyricMerger.enrichWithCrossSource(raw, others);
      final score = LyricCandidateScorer.score(
        _query,
        enriched.candidate,
        crossSourceAgree: enriched.crossSourceAgreed,
      );
      if (score == null || score < LyricMatchThresholds.lowConfidence) continue;
      final scored = ScoredLyricCandidate(
        enriched.candidate,
        score,
        crossSourceAgreed: enriched.crossSourceAgreed,
      );
      if (best == null || _isBetter(scored.score, scored.candidate, best)) {
        best = scored;
      }
    }
    _best = best;
  }

  void _completeFirstPaintIfAny() {
    final best = _best;
    if (best != null && !_firstPaint.isCompleted) _firstPaint.complete(best);
  }

  /// 得分更高者胜；得分持平时按能力（逐字 > 译文 > 罗马音）择优，保证高分候选间仍偏好更丰富的歌词。
  static bool _isBetter(
    double score,
    LyricCandidate candidate,
    ScoredLyricCandidate current,
  ) {
    const epsilon = 1e-6;
    if (score > current.score + epsilon) return true;
    if (score < current.score - epsilon) return false;
    return _capabilityRank(candidate) > _capabilityRank(current.candidate);
  }

  static int _capabilityRank(LyricCandidate c) =>
      (c.hasWordTiming ? 4 : 0) +
      (c.hasTranslation ? 2 : 0) +
      (c.hasRomaji ? 1 : 0);

  void _settle({bool cancelled = false}) {
    if (_settled.isCompleted) return;
    _graceTimer?.cancel();
    _softPaintTimer?.cancel();
    _deadlineTimer?.cancel();
    for (final sub in _subs) {
      unawaited(sub.cancel().catchError((Object _) {}));
    }
    _recomputeBest();
    if (!_firstPaint.isCompleted) _firstPaint.complete(_best);
    final allScored = <ScoredLyricCandidate>[
      for (final c in _qualifiedSynced)
        if (LyricCandidateScorer.score(_query, c) case final double s
            when s >= LyricMatchThresholds.lowConfidence)
          ScoredLyricCandidate(c, s),
    ]..sort((a, b) => b.score.compareTo(a.score));

    _settled.complete(
      LyricRaceSettlement(
        best: _best,
        plainFallback: _bestPlain,
        allCandidates: allScored,
        anySourceResponded: _anyResponded,
        allSourcesFinished: _finishedSources >= _sources.length,
        cancelled: cancelled,
      ),
    );
  }

  /// 立即取消会话（切歌或停止播放），未完成的结果均以当前最优收束并标记为已取消。
  void cancel() => _settle(cancelled: true);
}
