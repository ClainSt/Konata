import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/widgets.dart';
import 'package:konata_design_system/konata_design_system.dart';

enum _TouchDragKind { none, horizontalSeek, leftBrightness, rightVolume }

/// 移动端视频播放触控手势交互层。
///
/// 支持单击显隐控制层、双击左右区段快退快进十秒、双击中央切换播放暂停、
/// 长按开启两倍速快放、左右上下滑动调节亮度与音量以及横向拖动精调进度。
class VideoTouchGestureLayer extends StatefulWidget {
  /// 创建触控手势交互层。
  const VideoTouchGestureLayer({
    super.key,
    required this.isPlaying,
    required this.durationSeconds,
    required this.positionListenable,
    required this.currentVolume,
    required this.currentBrightness,
    required this.onSingleTap,
    required this.onDoubleTapCenter,
    required this.onDoubleTapLeftSeek,
    required this.onDoubleTapRightSeek,
    required this.onLongPressBoostStart,
    required this.onLongPressBoostEnd,
    required this.onSeekCommitted,
    required this.onVolumeChanged,
    required this.onBrightnessChanged,
    this.enableTouchGestures = true,
  });

  /// 当前是否正在播放。
  final bool isPlaying;

  /// 视频总时长（秒）。
  final double durationSeconds;

  /// 高频只读当前进度监听对象。
  final ValueListenable<Duration> positionListenable;

  /// 当前音量（0.0 到 100.0）。
  final double currentVolume;

  /// 当前虚拟亮度（0.05 到 1.0）。
  final double currentBrightness;

  /// 单击画布切换控制层显隐回调。
  final VoidCallback onSingleTap;

  /// 双击中央区域切换播放暂停回调。
  final VoidCallback onDoubleTapCenter;

  /// 双击左侧区域快退十秒回调。
  final VoidCallback onDoubleTapLeftSeek;

  /// 双击右侧区域快进十秒回调。
  final VoidCallback onDoubleTapRightSeek;

  /// 长按开始两倍速回调。
  final VoidCallback onLongPressBoostStart;

  /// 松开长按结束倍速回调。
  final VoidCallback onLongPressBoostEnd;

  /// 横向手势拖拽松手确认跳转时间点（秒）回调。
  final ValueChanged<double> onSeekCommitted;

  /// 垂直手势调节音量（0.0 到 100.0）回调。
  final ValueChanged<double> onVolumeChanged;

  /// 垂直手势调节虚拟亮度（0.05 到 1.0）回调。
  final ValueChanged<double> onBrightnessChanged;

  /// 是否启用完整触屏滑动与长按手势。
  final bool enableTouchGestures;

  @override
  State<VideoTouchGestureLayer> createState() => _VideoTouchGestureLayerState();
}

class _VideoTouchGestureLayerState extends State<VideoTouchGestureLayer> {
  _TouchDragKind _dragKind = _TouchDragKind.none;
  double _startVolume = 100.0;
  double _startBrightness = 0.5;
  double _startSeekSeconds = 0.0;
  double? _previewSeekSeconds;
  Offset _dragStartGlobal = Offset.zero;
  Offset _lastTapLocal = Offset.zero;
  String? _gestureFeedbackLabel;
  Timer? _feedbackTimer;

  @override
  void dispose() {
    _feedbackTimer?.cancel();
    super.dispose();
  }

  void _showFeedback(String label) {
    _feedbackTimer?.cancel();
    if (mounted) {
      setState(() => _gestureFeedbackLabel = label);
    }
    _feedbackTimer = Timer(const Duration(milliseconds: 900), () {
      if (mounted) {
        setState(() => _gestureFeedbackLabel = null);
      }
    });
  }

  void _handleDoubleTap(double width) {
    if (width <= 0) {
      widget.onDoubleTapCenter();
      return;
    }
    final ratio = _lastTapLocal.dx / width;
    if (ratio < 0.30) {
      widget.onDoubleTapLeftSeek();
      _showFeedback('快退 10 秒');
    } else if (ratio > 0.70) {
      widget.onDoubleTapRightSeek();
      _showFeedback('快进 10 秒');
    } else {
      widget.onDoubleTapCenter();
    }
  }

  void _onHorizontalStart(DragStartDetails details) {
    if (!widget.enableTouchGestures || widget.durationSeconds <= 0) return;
    _dragKind = _TouchDragKind.horizontalSeek;
    _dragStartGlobal = details.globalPosition;
    _startSeekSeconds = widget.positionListenable.value.inMilliseconds / 1000.0;
    _previewSeekSeconds = _startSeekSeconds;
    _showFeedback(_formatClock(_startSeekSeconds));
  }

  void _onHorizontalUpdate(DragUpdateDetails details, double width) {
    if (_dragKind != _TouchDragKind.horizontalSeek || width <= 0) return;
    final dx = details.globalPosition.dx - _dragStartGlobal.dx;
    final span = (widget.durationSeconds * 0.45).clamp(30.0, 240.0);
    final next = (_startSeekSeconds + (dx / width) * span)
        .clamp(0.0, widget.durationSeconds)
        .toDouble();
    setState(() {
      _previewSeekSeconds = next;
      _gestureFeedbackLabel = '${_formatClock(next)} / ${_formatClock(widget.durationSeconds)}';
    });
  }

  void _onHorizontalEnd(DragEndDetails details) {
    if (_dragKind != _TouchDragKind.horizontalSeek) return;
    final target = _previewSeekSeconds;
    _dragKind = _TouchDragKind.none;
    _previewSeekSeconds = null;
    if (target != null) {
      widget.onSeekCommitted(target);
    }
    _feedbackTimer?.cancel();
    _feedbackTimer = Timer(const Duration(milliseconds: 450), () {
      if (mounted) {
        setState(() => _gestureFeedbackLabel = null);
      }
    });
  }

  void _onVerticalStart(DragStartDetails details, double width) {
    if (!widget.enableTouchGestures || width <= 0) return;
    _dragStartGlobal = details.globalPosition;
    final isLeftSide = details.localPosition.dx < width * 0.5;
    if (isLeftSide) {
      _dragKind = _TouchDragKind.leftBrightness;
      _startBrightness = widget.currentBrightness;
      _showFeedback('亮度 ${(_startBrightness * 100).round()}%');
    } else {
      _dragKind = _TouchDragKind.rightVolume;
      _startVolume = widget.currentVolume;
      _showFeedback('音量 ${_startVolume.round()}%');
    }
  }

  void _onVerticalUpdate(DragUpdateDetails details, double height) {
    if (height <= 0) return;
    final dy = _dragStartGlobal.dy - details.globalPosition.dy;
    final ratioDelta = dy / (height * 0.65);
    if (_dragKind == _TouchDragKind.leftBrightness) {
      final next = (_startBrightness + ratioDelta).clamp(0.05, 1.0).toDouble();
      widget.onBrightnessChanged(next);
      _showFeedback('亮度 ${(next * 100).round()}%');
    } else if (_dragKind == _TouchDragKind.rightVolume) {
      final next = (_startVolume + ratioDelta * 100.0).clamp(0.0, 100.0).toDouble();
      widget.onVolumeChanged(next);
      _showFeedback('音量 ${next.round()}%');
    }
  }

  void _onVerticalEnd(DragEndDetails details) {
    _dragKind = _TouchDragKind.none;
  }

  String _formatClock(double seconds) {
    final safe = seconds.isFinite && seconds > 0 ? seconds.round() : 0;
    final mm = ((safe % 3600) ~/ 60).toString().padLeft(2, '0');
    final ss = (safe % 60).toString().padLeft(2, '0');
    final hh = safe ~/ 3600;
    return hh > 0 ? '${hh.toString().padLeft(2, '0')}:$mm:$ss' : '$mm:$ss';
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final height = constraints.maxHeight;
        return GestureDetector(
          key: const ValueKey('video_touch_gesture_surface'),
          behavior: HitTestBehavior.translucent,
          onTapDown: (details) => _lastTapLocal = details.localPosition,
          onTap: widget.onSingleTap,
          onDoubleTapDown: (details) => _lastTapLocal = details.localPosition,
          onDoubleTap: () => _handleDoubleTap(width),
          onLongPressStart: widget.enableTouchGestures
              ? (_) {
                  widget.onLongPressBoostStart();
                  _showFeedback('2.0x 倍速快放中');
                }
              : null,
          onLongPressEnd: widget.enableTouchGestures
              ? (_) => widget.onLongPressBoostEnd()
              : null,
          onHorizontalDragStart: widget.enableTouchGestures
              ? _onHorizontalStart
              : null,
          onHorizontalDragUpdate: widget.enableTouchGestures
              ? (details) => _onHorizontalUpdate(details, width)
              : null,
          onHorizontalDragEnd: widget.enableTouchGestures
              ? _onHorizontalEnd
              : null,
          onVerticalDragStart: widget.enableTouchGestures
              ? (details) => _onVerticalStart(details, width)
              : null,
          onVerticalDragUpdate: widget.enableTouchGestures
              ? (details) => _onVerticalUpdate(details, height)
              : null,
          onVerticalDragEnd: widget.enableTouchGestures
              ? _onVerticalEnd
              : null,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (_gestureFeedbackLabel != null)
                Center(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: KonataPlaybackTokens.osdSurfaceDark,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(
                        color: KonataPlaybackTokens.osdBorderLight,
                        width: 1,
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 8,
                      ),
                      child: Text(
                        _gestureFeedbackLabel!,
                        style: const TextStyle(
                          color: KonataPlaybackTokens.osdTextPrimary,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
