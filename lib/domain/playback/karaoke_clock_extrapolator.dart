import 'dart:math' as math;

/// 卡拉 OK 扫白单调时钟外推与柔性漂移纠偏状态机（纯领域算法）。
///
/// 在 VSync 帧循环中以 `pos = 锚点 + Δt × 倍速` 连续外推播放时刻；
/// 收到底层播放器进度回报时：
/// - 偏差小于 `60ms`：在约 `150ms` 窗口内微调推进速率平滑收敛（零肉眼硬跳）；
/// - 偏差达到或超过 `60ms`、发生手动跳转或处于暂停态：立即硬对齐至真实进度。
class KaraokeClockExtrapolator {
  /// 触发柔性纠偏的最大时间偏差阈值（秒，60 毫秒）。
  static const double softCorrectionThresholdSeconds = 0.060;

  /// 柔性纠偏目标收敛时长（秒，150 毫秒）。
  static const double softCorrectionWindowSeconds = 0.150;

  /// 柔性纠偏允许叠加的最大相对速率偏移（确保始终正向平滑推进，不倒退）。
  static const double maxSoftRateDeltaRatio = 0.40;

  double _currentPositionSeconds = 0.0;
  double _lastClockSeconds = 0.0;
  double _playbackRate = 1.0;
  double _correctionRemainingSeconds = 0.0;
  double _correctionRateDelta = 0.0;
  bool _initialized = false;

  /// 当前外推播放位置（秒）。
  double get currentPositionSeconds => _currentPositionSeconds;

  /// 当前是否正处于柔性速率纠偏窗口中。
  bool get isSoftCorrecting => _correctionRemainingSeconds > 1e-6;

  /// 立即硬对齐至指定媒体位置并清空残余柔性纠偏（用于首帧初始化、切行、暂停与 Seek）。
  double snapTo(
    double positionSeconds, {
    required double clockSeconds,
    double playbackRate = 1.0,
  }) {
    _currentPositionSeconds = positionSeconds;
    _lastClockSeconds = clockSeconds;
    _playbackRate = playbackRate > 0 ? playbackRate : 1.0;
    _correctionRemainingSeconds = 0.0;
    _correctionRateDelta = 0.0;
    _initialized = true;
    return _currentPositionSeconds;
  }

  /// 随单调渲染时钟推进至 [clockSeconds] 并返回平滑外推后的播放位置（秒）。
  double advanceTo(double clockSeconds) {
    if (!_initialized) {
      _lastClockSeconds = clockSeconds;
      _initialized = true;
      return _currentPositionSeconds;
    }
    final dt = math.max(0.0, clockSeconds - _lastClockSeconds);
    _lastClockSeconds = clockSeconds;
    if (dt <= 0.0) return _currentPositionSeconds;

    _currentPositionSeconds += dt * _playbackRate;
    if (_correctionRemainingSeconds > 0.0) {
      final applyDt = math.min(dt, _correctionRemainingSeconds);
      _currentPositionSeconds += applyDt * _correctionRateDelta;
      _correctionRemainingSeconds -= applyDt;
      if (_correctionRemainingSeconds <= 1e-6) {
        _correctionRemainingSeconds = 0.0;
        _correctionRateDelta = 0.0;
      }
    }
    if (_currentPositionSeconds < 0.0) {
      _currentPositionSeconds = 0.0;
    }
    return _currentPositionSeconds;
  }

  /// 融合底层播放器的最新回报位置 [reportedPositionSeconds]：小于 60ms 柔性收敛，大于等于 60ms 立即对齐。
  double reconcileFromMediaClock(
    double reportedPositionSeconds, {
    required double clockSeconds,
    required bool isPlaying,
    bool forceSnap = false,
    double playbackRate = 1.0,
  }) {
    final safeRate = playbackRate > 0 ? playbackRate : 1.0;
    if (!_initialized || !isPlaying || forceSnap) {
      return snapTo(
        reportedPositionSeconds,
        clockSeconds: clockSeconds,
        playbackRate: safeRate,
      );
    }

    advanceTo(clockSeconds);
    _playbackRate = safeRate;
    final error = reportedPositionSeconds - _currentPositionSeconds;
    if (error.abs() >= softCorrectionThresholdSeconds) {
      return snapTo(
        reportedPositionSeconds,
        clockSeconds: clockSeconds,
        playbackRate: safeRate,
      );
    }
    if (error.abs() <= 0.001) {
      _correctionRemainingSeconds = 0.0;
      _correctionRateDelta = 0.0;
      return _currentPositionSeconds;
    }

    final maxDelta = safeRate * maxSoftRateDeltaRatio;
    final rateDelta = (error / softCorrectionWindowSeconds).clamp(
      -maxDelta,
      maxDelta,
    );
    _correctionRateDelta = rateDelta;
    _correctionRemainingSeconds = rateDelta.abs() > 1e-6
        ? (error.abs() / rateDelta.abs())
        : 0.0;
    return _currentPositionSeconds;
  }
}
