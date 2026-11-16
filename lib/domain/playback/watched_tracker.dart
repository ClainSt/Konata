/// 单段连续观看时间区间（秒）。
class WatchedSegment {
  /// 创建观看区间。
  const WatchedSegment(this.startSeconds, this.endSeconds);

  /// 起始播放位置（秒）。
  final double startSeconds;

  /// 结束播放位置（秒）。
  final double endSeconds;

  /// 区间跨度（秒）。
  double get durationSeconds =>
      endSeconds > startSeconds ? endSeconds - startSeconds : 0.0;
}

/// 观看区间并集时间线，精确剔除重复拖拽与未观看跳段，用于完播率判定。
class WatchedTimeline {
  /// 创建空的观看时间线。
  WatchedTimeline();

  final List<WatchedSegment> _segments = [];

  /// 当前已合并的无重叠观看区间列表。
  List<WatchedSegment> get segments => List.unmodifiable(_segments);

  /// 累计唯一有效观看时长（秒）。
  double get totalWatchedSeconds {
    var sum = 0.0;
    for (final s in _segments) {
      sum += s.durationSeconds;
    }
    return sum;
  }

  /// 添加一段观看区间并自动与既有重叠/相邻区间（<= 0.5s 间隙）合并。
  void addSegment(double startSeconds, double endSeconds) {
    if (!startSeconds.isFinite || !endSeconds.isFinite) return;
    final start = startSeconds < 0 ? 0.0 : startSeconds;
    final end = endSeconds < start ? start : endSeconds;
    if (end - start <= 0.0) return;

    const mergeGap = 0.5;
    var mergedStart = start;
    var mergedEnd = end;
    final next = <WatchedSegment>[];

    for (final seg in _segments) {
      if (seg.endSeconds + mergeGap < mergedStart) {
        next.add(seg);
      } else if (seg.startSeconds - mergeGap > mergedEnd) {
        next.add(seg);
      } else {
        if (seg.startSeconds < mergedStart) mergedStart = seg.startSeconds;
        if (seg.endSeconds > mergedEnd) mergedEnd = seg.endSeconds;
      }
    }
    next.add(WatchedSegment(mergedStart, mergedEnd));
    next.sort((a, b) => a.startSeconds.compareTo(b.startSeconds));
    _segments
      ..clear()
      ..addAll(next);
  }

  /// 计算当前有效观看占比（`0.0 ~ 1.0`）。
  double watchedRatio(double totalDurationSeconds) {
    if (!totalDurationSeconds.isFinite || totalDurationSeconds <= 0) {
      return 0.0;
    }
    return (totalWatchedSeconds / totalDurationSeconds).clamp(0.0, 1.0);
  }

  /// 判断有效观看时长是否已达到完播阈值（默认 `>= 85%`）。
  bool hasReachedCompletion(
    double totalDurationSeconds, {
    double completionThreshold = 0.85,
  }) {
    return watchedRatio(totalDurationSeconds) >= completionThreshold;
  }

  /// 清空记录。
  void clear() {
    _segments.clear();
  }
}

/// 基于单调时钟的高精度真实观看行为追踪器。
///
/// 核心约束：
/// 1. 使用单调时钟采样间隔，超过 3s 的挂起/休眠空窗截断丢弃；
/// 2. 位移与 `wallDelta * speed` 偏差需在 200ms 抖动容差内，快进/拖拽跳转不计入有效观看；
/// 3. 播放进入最后 1%（`>= duration * 0.99`）时触发结尾复位约定，避免下次续播停在黑屏最后一秒。
class WatchedTracker {
  /// 创建观看追踪器，可注入单调毫秒时钟便于确定性单测。
  WatchedTracker({
    int Function()? monotonicClockMs,
    this.completionThreshold = 0.85,
  }) : _clockMs = monotonicClockMs ?? _defaultMonotonicClockMs;

  static final Stopwatch _sharedStopwatch = Stopwatch()..start();

  static int _defaultMonotonicClockMs() => _sharedStopwatch.elapsedMilliseconds;

  /// 最大连续墙钟采样间隙（3 秒）。
  static const int maxWallGapMillis = 3000;

  /// 连续播放位置抖动容差（200 毫秒）。
  static const double jitterToleranceSeconds = 0.200;

  /// 结尾重置阈值（最后 1%）。
  static const double finalTailRatioThreshold = 0.99;

  final int Function() _clockMs;

  /// 自动完播判定阈值。
  final double completionThreshold;

  /// 累计并集时间线。
  final WatchedTimeline timeline = WatchedTimeline();

  int? _lastWallMs;
  double? _lastPositionSeconds;
  bool _enteredFinalTail = false;

  /// 是否已经进入过片尾最后 1%。
  bool get hasEnteredFinalTail => _enteredFinalTail;

  /// 每次播放器心跳或位置更新时调用。
  void sample({
    required double positionSeconds,
    required double durationSeconds,
    required bool isPlaying,
    double speed = 1.0,
  }) {
    final nowMs = _clockMs();
    if (!positionSeconds.isFinite ||
        !durationSeconds.isFinite ||
        durationSeconds <= 0) {
      _resetAnchor(nowMs, positionSeconds);
      return;
    }

    if (positionSeconds >= durationSeconds * finalTailRatioThreshold) {
      _enteredFinalTail = true;
    }

    if (!isPlaying) {
      _lastWallMs = null;
      _lastPositionSeconds = positionSeconds;
      return;
    }

    final prevWallMs = _lastWallMs;
    final prevPos = _lastPositionSeconds;
    _lastWallMs = nowMs;
    _lastPositionSeconds = positionSeconds;

    if (prevWallMs == null || prevPos == null) {
      return;
    }

    final wallDeltaMs = nowMs - prevWallMs;
    if (wallDeltaMs <= 0 || wallDeltaMs > maxWallGapMillis) {
      return;
    }

    final clampedSpeed = speed.isFinite ? speed.clamp(0.25, 8.0) : 1.0;
    final expectedDelta = (wallDeltaMs / 1000.0) * clampedSpeed;
    final actualDelta = positionSeconds - prevPos;
    final tolerance = jitterToleranceSeconds * clampedSpeed + 0.05;

    if (actualDelta >= -0.05 &&
        (actualDelta - expectedDelta).abs() <= tolerance) {
      final segStart = prevPos < positionSeconds ? prevPos : positionSeconds;
      timeline.addSegment(segStart, positionSeconds);
    }
  }

  /// 显式跳转前断开连续采样锚点，确保拖拽不记入有效观看区间。
  void notifySeek() {
    _lastWallMs = null;
    _lastPositionSeconds = null;
  }

  /// 是否已满足自动完播条件。
  bool isCompleted(double durationSeconds) {
    return timeline.hasReachedCompletion(
      durationSeconds,
      completionThreshold: completionThreshold,
    );
  }

  /// 当前累计有效观看占比（`0.0 ~ 1.0`）。
  double watchedRatio(double durationSeconds) {
    return timeline.watchedRatio(durationSeconds);
  }

  /// 计算应写入数据库的历史续播秒数：
  /// 若已播放进入最后 1%（或非常接近片尾），则归零以便下次从头观看。
  int resolvePersistedPositionSeconds({
    required double positionSeconds,
    required double durationSeconds,
  }) {
    if (!positionSeconds.isFinite || positionSeconds <= 0) {
      return 0;
    }
    if (durationSeconds.isFinite &&
        durationSeconds > 0 &&
        positionSeconds >= durationSeconds * finalTailRatioThreshold) {
      return 0;
    }
    return positionSeconds.round();
  }

  /// 切换剧集或重头重看时彻底清零状态。
  void reset() {
    timeline.clear();
    _lastWallMs = null;
    _lastPositionSeconds = null;
    _enteredFinalTail = false;
  }

  void _resetAnchor(int nowMs, double positionSeconds) {
    _lastWallMs = nowMs;
    _lastPositionSeconds = positionSeconds.isFinite ? positionSeconds : null;
  }
}
