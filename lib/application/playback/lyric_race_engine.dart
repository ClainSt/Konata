import 'dart:async';

import '../../domain/lyrics/lyric_candidate.dart';
import '../../domain/lyrics/lyric_candidate_scorer.dart';
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
  });

  /// 全程最优合格候选（低于低置信度阈值时为空）。
  final ScoredLyricCandidate? best;

  /// 是否至少一个来源完整正常响应。
  final bool anySourceResponded;

  /// 是否全部来源均已结束（未因预算截止或取消而中断）。
  final bool allSourcesFinished;

  /// 是否被外部取消。
  final bool cancelled;

  /// 能否写入“未找到”负缓存：全部来源结束、至少一个正常响应且无合格候选。
  bool get isConfirmedNotFound =>
      best == null && allSourcesFinished && anySourceResponded && !cancelled;
}

/// 多来源并行歌词竞速器：首个可自动采用候选出现后经短暂宽限期即上屏；
/// 仅有低置信度候选时到达软截止即上屏；其余来源继续收集至总预算截止。
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
  Timer? _graceTimer;
  Timer? _softPaintTimer;
  Timer? _deadlineTimer;
  ScoredLyricCandidate? _best;
  var _finishedSources = 0;
  var _anyResponded = false;
  var _softPaintDue = false;

  /// 首屏可显示候选（无合格候选时为空）。
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
    final score = LyricCandidateScorer.score(_query, candidate);
    if (score == null || score < LyricMatchThresholds.lowConfidence) return;
    final current = _best;
    if (current == null || _isBetter(score, candidate, current)) {
      _best = ScoredLyricCandidate(candidate, score);
    }
    if (score >= LyricMatchThresholds.autoAccept &&
        _graceTimer == null &&
        !_firstPaint.isCompleted) {
      _graceTimer = Timer(_engine.firstPaintGrace, _completeFirstPaintIfAny);
    }
    if (_softPaintDue) _completeFirstPaintIfAny();
  }

  void _completeFirstPaintIfAny() {
    final best = _best;
    if (best != null && !_firstPaint.isCompleted) _firstPaint.complete(best);
  }

  /// 得分更高者胜；得分封顶持平时按能力（逐字 > 译文）择优，保证满分候选间仍偏好更丰富的歌词。
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
      (c.hasWordTiming ? 2 : 0) + (c.hasTranslation ? 1 : 0);

  void _settle({bool cancelled = false}) {
    if (_settled.isCompleted) return;
    _graceTimer?.cancel();
    _softPaintTimer?.cancel();
    _deadlineTimer?.cancel();
    for (final sub in _subs) {
      unawaited(sub.cancel());
    }
    if (!_firstPaint.isCompleted) _firstPaint.complete(_best);
    _settled.complete(
      LyricRaceSettlement(
        best: _best,
        anySourceResponded: _anyResponded,
        allSourcesFinished: _finishedSources >= _sources.length,
        cancelled: cancelled,
      ),
    );
  }

  /// 立即取消会话（切歌或停止播放），未完成的结果均以当前最优收束并标记为已取消。
  void cancel() => _settle(cancelled: true);
}
