import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../domain/playback/playback_formatters.dart';
import '../theme/konata_adaptive_tokens.dart';
import '../theme/konata_palette.dart';
import '../theme/konata_playback_tokens.dart';
import '../widgets/design_system/konata_glass_capsule.dart';
import '../widgets/playback/konata_playback_capsule.dart';
import '../theme/konata_theme.dart';

enum _TouchDragKind { none, brightness, volume, seek, collapse }

/// 视频舞台统一触控手势与屏幕锁定防误触层。
///
/// 覆盖能力：
/// - 左侧纵向滑动调节窗口亮度 + 居中毛玻璃数值胶囊；
/// - 右侧纵向滑动调节音量 + 居中毛玻璃数值胶囊；
/// - 水平滑动预览目标时间与差值 + 松手精准跳转；
/// - 左 `1/3` 双击快退 10 秒、中央 `1/3` 双击播放/暂停、右 `1/3` 双击快进 10 秒；
/// - 长按激活 `2.0x` 倍速快进，松手恢复；
/// - 屏幕锁定开关：锁定时屏蔽所有手势与控制坞，仅保留解锁入口。
class VideoTouchGestureLayer extends StatefulWidget {
  /// 创建视频触控手势与锁定层。
  const VideoTouchGestureLayer({
    super.key,
    required this.screenLocked,
    required this.showLockButton,
    required this.gesturesBlocked,
    required this.currentPositionReader,
    required this.durationReader,
    required this.brightnessReader,
    required this.volumeReader,
    required this.onToggleScreenLock,
    required this.onSingleTap,
    required this.onDesktopDoubleTapFullscreen,
    required this.onTogglePlayPause,
    required this.onSeekRelative,
    required this.onSeekAbsolute,
    required this.onBrightnessChanged,
    required this.onVolumeChanged,
    required this.onStartSpeedBoost,
    required this.onEndSpeedBoost,
    this.onCollapseDragEnd,
  });

  /// 当前是否处于锁屏防误触状态。
  final bool screenLocked;

  /// 当前是否显示左侧锁屏/解锁胶囊按钮。
  final bool showLockButton;

  /// 是否暂时禁用手势（例如右侧抽屉打开时）。
  final bool gesturesBlocked;

  /// 按需读取当前秒数（零 `watch` 重建）。
  final double Function() currentPositionReader;

  /// 按需读取总时长秒数。
  final double Function() durationReader;

  /// 按需读取当前窗口亮度（`0.0 ~ 1.0`）。
  final double Function() brightnessReader;

  /// 按需读取当前音量（`0.0 ~ 100.0`）。
  final double Function() volumeReader;

  /// 切换锁屏状态回调。
  final VoidCallback onToggleScreenLock;

  /// 单击视频舞台回调（切换或唤醒 HUD）。
  final VoidCallback onSingleTap;

  /// 桌面端鼠标双击切换全屏回调。
  final VoidCallback onDesktopDoubleTapFullscreen;

  /// 中央区域双击切换播放/暂停回调。
  final VoidCallback onTogglePlayPause;

  /// 左右区域双击相对快退/快进回调。
  final ValueChanged<double> onSeekRelative;

  /// 水平滑动预览松手绝对跳转回调。
  final ValueChanged<double> onSeekAbsolute;

  /// 亮度连续变更回调（`0.0 ~ 1.0`）。
  final ValueChanged<double> onBrightnessChanged;

  /// 音量连续变更回调（`0.0 ~ 100.0`）。
  final ValueChanged<double> onVolumeChanged;

  /// 长按开始二倍速回调。
  final VoidCallback onStartSpeedBoost;

  /// 长按结束恢复原速回调。
  final VoidCallback onEndSpeedBoost;

  /// 中央非冲突区纵向跟手下拉收起回调，透传真实释放初速度（px/s）。
  final ValueChanged<double>? onCollapseDragEnd;

  @override
  State<VideoTouchGestureLayer> createState() => _VideoTouchGestureLayerState();
}

class _VideoTouchGestureLayerState extends State<VideoTouchGestureLayer> {
  _TouchDragKind _dragKind = _TouchDragKind.none;
  Offset _dragOrigin = Offset.zero;
  double _startBrightness = 0.5;
  double _startVolume = 100.0;
  double _startSeekSeconds = 0.0;
  double? _previewSeekSeconds;
  double _collapseDragDownPx = 0.0;

  PointerDeviceKind _lastTapKind = PointerDeviceKind.touch;
  Offset _lastDoubleTapLocal = Offset.zero;

  bool _pillVisible = false;
  IconData _pillIcon = Icons.brightness_6_rounded;
  String _pillLabel = '';
  double? _pillProgress;
  Timer? _pillFadeTimer;
  bool _longPressBoosting = false;

  @override
  void dispose() {
    _pillFadeTimer?.cancel();
    super.dispose();
  }

  void _showCenterPill({
    required IconData icon,
    required String label,
    double? progress,
    bool autoDismiss = true,
  }) {
    _pillFadeTimer?.cancel();
    setState(() {
      _pillIcon = icon;
      _pillLabel = label;
      _pillProgress = progress;
      _pillVisible = true;
    });
    if (autoDismiss) {
      _pillFadeTimer = Timer(KonataTheme.gesturePillSlowFadeDelay, () {
        if (mounted) {
          setState(() => _pillVisible = false);
        }
      });
    }
  }

  void _dismissPillSoon() {
    _pillFadeTimer?.cancel();
    _pillFadeTimer = Timer(KonataTheme.gesturePillFastFadeDelay, () {
      if (mounted) {
        setState(() => _pillVisible = false);
      }
    });
  }

  void _handleDoubleTap(Size stageSize) {
    if (widget.screenLocked || widget.gesturesBlocked) return;
    if (!KonataAdaptiveTokens.isAndroid &&
        _lastTapKind == PointerDeviceKind.mouse) {
      widget.onDesktopDoubleTapFullscreen();
      return;
    }

    final width = stageSize.width > 0 ? stageSize.width : 1.0;
    final ratio = (_lastDoubleTapLocal.dx / width).clamp(0.0, 1.0);
    if (ratio < 1.0 / 3.0) {
      widget.onSeekRelative(-10.0);
      _showCenterPill(icon: Icons.replay_10_rounded, label: '快退 10 秒');
    } else if (ratio > 2.0 / 3.0) {
      widget.onSeekRelative(10.0);
      _showCenterPill(icon: Icons.forward_10_rounded, label: '快进 10 秒');
    } else {
      widget.onTogglePlayPause();
    }
  }

  void _onVerticalDragStart(
    DragStartDetails details,
    Size stageSize, {
    required bool allowBrightnessVolume,
  }) {
    if (widget.screenLocked || widget.gesturesBlocked) return;
    _dragOrigin = details.localPosition;
    _collapseDragDownPx = 0.0;
    final ratioX = stageSize.width > 0
        ? (details.localPosition.dx / stageSize.width).clamp(0.0, 1.0)
        : 0.5;
    if (widget.onCollapseDragEnd != null &&
        ratioX >= 1.0 / 3.0 &&
        ratioX <= 2.0 / 3.0) {
      _dragKind = _TouchDragKind.collapse;
      return;
    }
    if (!allowBrightnessVolume) {
      _dragKind = _TouchDragKind.none;
      return;
    }
    final isLeftSide = ratioX < 0.5;
    _dragKind = isLeftSide ? _TouchDragKind.brightness : _TouchDragKind.volume;
    _startBrightness = widget.brightnessReader();
    _startVolume = widget.volumeReader();
  }

  void _onVerticalDragUpdate(DragUpdateDetails details, Size stageSize) {
    if (widget.screenLocked || widget.gesturesBlocked) return;
    if (_dragKind == _TouchDragKind.collapse) {
      final dy = details.localPosition.dy - _dragOrigin.dy;
      _collapseDragDownPx = dy > 0 ? dy : 0.0;
      if (_collapseDragDownPx >= 24.0) {
        _showCenterPill(
          icon: Icons.keyboard_arrow_down_rounded,
          label: _collapseDragDownPx >= 72.0 ? '松手收起小窗' : '下拉收起小窗',
          autoDismiss: false,
        );
      }
      return;
    }
    final span = (stageSize.height * 0.72).clamp(120.0, 640.0);
    final deltaRatio = (_dragOrigin.dy - details.localPosition.dy) / span;

    if (_dragKind == _TouchDragKind.brightness) {
      final next = (_startBrightness + deltaRatio).clamp(0.0, 1.0);
      widget.onBrightnessChanged(next);
      final pct = (next * 100).round();
      _showCenterPill(
        icon: next < 0.35
            ? Icons.brightness_low_rounded
            : (next < 0.72
                  ? Icons.brightness_medium_rounded
                  : Icons.brightness_high_rounded),
        label: '亮度 $pct%',
        progress: next,
        autoDismiss: false,
      );
    } else if (_dragKind == _TouchDragKind.volume) {
      final next = (_startVolume + deltaRatio * 100.0).clamp(0.0, 100.0);
      widget.onVolumeChanged(next);
      final pct = next.round();
      _showCenterPill(
        icon: pct == 0
            ? Icons.volume_off_rounded
            : (pct < 50
                  ? Icons.volume_down_rounded
                  : Icons.volume_up_rounded),
        label: '音量 $pct%',
        progress: next / 100.0,
        autoDismiss: false,
      );
    }
  }

  void _onVerticalDragEnd(DragEndDetails? details) {
    final kind = _dragKind;
    final dragDown = _collapseDragDownPx;
    _collapseDragDownPx = 0.0;
    if (kind != _TouchDragKind.none) {
      _dragKind = _TouchDragKind.none;
      _dismissPillSoon();
    }
    if (kind == _TouchDragKind.collapse && widget.onCollapseDragEnd != null) {
      final primaryVelocity = details?.primaryVelocity ?? 0.0;
      if (dragDown >= 72.0 || primaryVelocity >= 420.0) {
        widget.onCollapseDragEnd!(primaryVelocity);
      }
    }
  }

  void _onHorizontalDragStart(DragStartDetails details) {
    if (widget.screenLocked || widget.gesturesBlocked) return;
    final dur = widget.durationReader();
    if (dur <= 0) return;
    _dragKind = _TouchDragKind.seek;
    _dragOrigin = details.localPosition;
    _startSeekSeconds = widget.currentPositionReader();
    _previewSeekSeconds = _startSeekSeconds;
  }

  void _onHorizontalDragUpdate(DragUpdateDetails details, Size stageSize) {
    if (widget.screenLocked ||
        widget.gesturesBlocked ||
        _dragKind != _TouchDragKind.seek) {
      return;
    }
    final dur = widget.durationReader();
    if (dur <= 0) return;
    final width = stageSize.width.clamp(180.0, 1600.0);
    // 全宽滑动最大跨越 120 秒（短片按总长自适应），手感细腻防跳飞
    final fullSwipeSeconds = dur < 180.0 ? dur * 0.65 : 120.0;
    final deltaSec =
        ((details.localPosition.dx - _dragOrigin.dx) / width) *
        fullSwipeSeconds;
    final target = (_startSeekSeconds + deltaSec).clamp(0.0, dur);
    _previewSeekSeconds = target;

    final showHours = dur >= 3600;
    final targetText = PlaybackFormatters.formatMediaDuration(
      target,
      alwaysShowHours: showHours,
    );
    final totalText = PlaybackFormatters.formatMediaDuration(
      dur,
      alwaysShowHours: showHours,
    );
    final diff = (target - _startSeekSeconds).round();
    final diffSign = diff >= 0 ? '+$diff' : '$diff';
    _showCenterPill(
      icon: diff >= 0
          ? Icons.fast_forward_rounded
          : Icons.fast_rewind_rounded,
      label: '$targetText / $totalText (${diffSign}s)',
      progress: (target / dur).clamp(0.0, 1.0),
      autoDismiss: false,
    );
  }

  void _onHorizontalDragEnd() {
    if (_dragKind == _TouchDragKind.seek) {
      final commit = _previewSeekSeconds;
      _dragKind = _TouchDragKind.none;
      _previewSeekSeconds = null;
      _dismissPillSoon();
      if (commit != null) {
        widget.onSeekAbsolute(commit);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final safe = MediaQuery.paddingOf(context);
    final enableTouchDrag = KonataAdaptiveTokens.isAndroid;

    return LayoutBuilder(
      builder: (context, constraints) {
        final stageSize = Size(constraints.maxWidth, constraints.maxHeight);

        return Stack(
          fit: StackFit.expand,
          children: [
            Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: (e) => _lastTapKind = e.kind,
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: widget.onSingleTap,
                onDoubleTapDown: widget.screenLocked || widget.gesturesBlocked
                    ? null
                    : (d) => _lastDoubleTapLocal = d.localPosition,
                onDoubleTap: widget.screenLocked || widget.gesturesBlocked
                    ? null
                    : () => _handleDoubleTap(stageSize),
                onLongPressStart:
                    (!enableTouchDrag ||
                        widget.screenLocked ||
                        widget.gesturesBlocked)
                    ? null
                    : (_) {
                        _longPressBoosting = true;
                        widget.onStartSpeedBoost();
                      },
                onLongPressEnd: (!enableTouchDrag)
                    ? null
                    : (_) {
                        if (_longPressBoosting) {
                          _longPressBoosting = false;
                          widget.onEndSpeedBoost();
                        }
                      },
                onLongPressCancel: (!enableTouchDrag)
                    ? null
                    : () {
                        if (_longPressBoosting) {
                          _longPressBoosting = false;
                          widget.onEndSpeedBoost();
                        }
                      },
                onVerticalDragStart:
                    ((!enableTouchDrag && widget.onCollapseDragEnd == null) ||
                        widget.screenLocked ||
                        widget.gesturesBlocked)
                    ? null
                    : (d) => _onVerticalDragStart(
                        d,
                        stageSize,
                        allowBrightnessVolume: enableTouchDrag,
                      ),
                onVerticalDragUpdate:
                    ((!enableTouchDrag && widget.onCollapseDragEnd == null) ||
                        widget.screenLocked ||
                        widget.gesturesBlocked)
                    ? null
                    : (d) => _onVerticalDragUpdate(d, stageSize),
                onVerticalDragEnd:
                    (!enableTouchDrag && widget.onCollapseDragEnd == null)
                    ? null
                    : _onVerticalDragEnd,
                onVerticalDragCancel:
                    (!enableTouchDrag && widget.onCollapseDragEnd == null)
                    ? null
                    : () => _onVerticalDragEnd(null),
                onHorizontalDragStart:
                    (!enableTouchDrag ||
                        widget.screenLocked ||
                        widget.gesturesBlocked)
                    ? null
                    : _onHorizontalDragStart,
                onHorizontalDragUpdate:
                    (!enableTouchDrag ||
                        widget.screenLocked ||
                        widget.gesturesBlocked)
                    ? null
                    : (d) => _onHorizontalDragUpdate(d, stageSize),
                onHorizontalDragEnd: (!enableTouchDrag)
                    ? null
                    : (_) => _onHorizontalDragEnd(),
                onHorizontalDragCancel: (!enableTouchDrag)
                    ? null
                    : _onHorizontalDragEnd,
                child: const SizedBox.expand(),
              ),
            ),

            // 居中数值/预览毛玻璃胶囊
            if (_pillVisible && !widget.screenLocked)
              Center(
                child: IgnorePointer(
                  child: KonataGlassCapsule(
                    key: const ValueKey('video_gesture_center_pill'),
                    radius: 20,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 12,
                    ),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(
                        minWidth: 132,
                        maxWidth: 260,
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(_pillIcon, size: 19, color: p.textPrimary),
                              const SizedBox(width: 8),
                              Flexible(
                                child: Text(
                                  _pillLabel,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: p.textPrimary,
                                    fontSize: KonataTheme.fontSizeBody,
                                    fontWeight: FontWeight.w600,
                                    fontFeatures:
                                        KonataPlaybackTokens.tabularNumbers,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          if (_pillProgress != null) ...[
                            const SizedBox(height: 8),
                            ClipRRect(
                              borderRadius: KonataTheme.borderRadiusPill,
                              child: SizedBox(
                                width: 124,
                                height: 3.5,
                                child: LinearProgressIndicator(
                                  value: _pillProgress!.clamp(0.0, 1.0),
                                  color: p.progressFill,
                                  backgroundColor: p.progressTrack,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),

            // 左侧屏幕锁定开关胶囊（Android 触屏常驻随 HUD 显隐，锁定态单点唤醒独立解锁键）
            if (enableTouchDrag && widget.showLockButton)
              Positioned(
                left: safe.left + 14,
                top: (stageSize.height - KonataAdaptiveTokens.touchTarget) / 2,
                child: KonataGlassCapsule(
                  radius: 999,
                  child: KonataCapsuleIconButton(
                    key: const ValueKey('video_screen_lock_button'),
                    icon: widget.screenLocked
                        ? Icons.lock_rounded
                        : Icons.lock_open_rounded,
                    tooltip: widget.screenLocked ? '解锁屏幕手势' : '锁定屏幕防误触',
                    color: widget.screenLocked ? p.progressFill : p.textPrimary,
                    size: 20,
                    fixedSize: KonataAdaptiveTokens.touchTarget,
                    onTap: widget.onToggleScreenLock,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
