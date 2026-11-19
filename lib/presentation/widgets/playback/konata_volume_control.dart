import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../theme/konata_adaptive_tokens.dart';
import '../../theme/konata_palette.dart';
import '../../theme/konata_playback_tokens.dart';
import '../../theme/konata_theme.dart';

/// 音视频播控胶囊共用的紧凑音量控件与悬浮竖向音量胶囊。
class KonataVolumeControl extends StatefulWidget {
  /// 创建紧凑音量控件。
  const KonataVolumeControl({
    super.key,
    required this.volume,
    required this.isMuted,
    required this.onVolumeChanged,
    required this.onToggleMute,
    this.onPopupActiveChanged,
    this.allowPopover = true,
    this.externalRevealPulse = 0,
  });

  /// 当前音量 (`0.0 ~ 1.0`)。
  final double volume;

  /// 是否静音。
  final bool isMuted;

  /// 音量变化回调 (`0.0 ~ 1.0`)。
  final ValueChanged<double> onVolumeChanged;

  /// 点击切换静音回调。
  final VoidCallback onToggleMute;

  /// 纵向音量浮层激活态变更回调（供视频页锁定底栏不提前淡出）。
  final ValueChanged<bool>? onPopupActiveChanged;

  /// 宿主当前是否允许保持或展示纵向音量浮层。
  final bool allowPopover;

  /// 外部（如视频画布全局鼠标滚轮或方向键）调节音量时的唤醒脉冲计数。
  final int externalRevealPulse;

  @override
  State<KonataVolumeControl> createState() => _KonataVolumeControlState();
}

class _KonataVolumeControlState extends State<KonataVolumeControl> {
  static const Duration _kAdjustIdleAutoHideDelay =
      KonataPlaybackTokens.volumeAdjustIdleAutoHideDelay;
  static const double _kPopoverClearanceBridgeHeight = 24.0;

  final LayerLink _layerLink = LayerLink();
  final OverlayPortalController _overlayController = OverlayPortalController();
  Timer? _hideTimer;
  Timer? _adjustIdleTimer;
  bool _anchorHovered = false;
  bool _popoverHovered = false;
  bool _isDragging = false;
  bool _showVolumeNumber = false;
  bool _wheelHoldOpen = false;
  bool _lastNotifiedPopupActive = false;

  @override
  void didUpdateWidget(covariant KonataVolumeControl oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.allowPopover &&
        (_overlayController.isShowing ||
            _anchorHovered ||
            _popoverHovered ||
            _isDragging ||
            _showVolumeNumber ||
            _wheelHoldOpen)) {
      _hideTimer?.cancel();
      _adjustIdleTimer?.cancel();
      _anchorHovered = false;
      _popoverHovered = false;
      _isDragging = false;
      _showVolumeNumber = false;
      _wheelHoldOpen = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || widget.allowPopover) return;
        if (_overlayController.isShowing) {
          _overlayController.hide();
        }
        _notifyPopupActiveState();
      });
      return;
    }

    if (widget.externalRevealPulse != oldWidget.externalRevealPulse &&
        widget.allowPopover) {
      _hideTimer?.cancel();
      _adjustIdleTimer?.cancel();
      _showVolumeNumber = true;
      _wheelHoldOpen = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !widget.allowPopover) return;
        _showPopoverIfPossible();
        _restartAdjustIdleTimer();
      });
    }
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _adjustIdleTimer?.cancel();
    super.dispose();
  }

  IconData _resolveVolumeIcon(double effectiveVolume) {
    if (widget.isMuted || effectiveVolume <= 0.001) {
      return Icons.volume_off_rounded;
    }
    if (effectiveVolume < 0.45) {
      return Icons.volume_down_rounded;
    }
    return Icons.volume_up_rounded;
  }

  void _markVolumeAdjusting({bool holdOpen = false}) {
    _cancelHide();
    _adjustIdleTimer?.cancel();
    final needRebuild = !_showVolumeNumber || (holdOpen && !_wheelHoldOpen);
    _showVolumeNumber = true;
    if (holdOpen) {
      _wheelHoldOpen = true;
    }
    if (needRebuild && mounted) {
      setState(() {});
    }
    _showPopoverIfPossible();
    if (!_isDragging) {
      _restartAdjustIdleTimer();
    }
  }

  void _restartAdjustIdleTimer() {
    _adjustIdleTimer?.cancel();
    _adjustIdleTimer = Timer(_kAdjustIdleAutoHideDelay, () {
      if (!mounted || _isDragging) return;
      setState(() {
        _showVolumeNumber = false;
        _wheelHoldOpen = false;
      });
      if (!_anchorHovered && !_popoverHovered) {
        if (_overlayController.isShowing) {
          _overlayController.hide();
        }
      }
      _notifyPopupActiveState();
    });
  }

  void _handlePointerSignal(PointerSignalEvent signal) {
    if (signal is! PointerScrollEvent) return;
    final dy = signal.scrollDelta.dy;
    if (dy == 0) return;
    final stepPct =
        (dy < 0
                ? KonataPlaybackTokens.wheelVolumeStep
                : -KonataPlaybackTokens.wheelVolumeStep)
            .round();
    final currentPct =
        ((widget.isMuted ? 0.0 : widget.volume.clamp(0.0, 1.0)) * 100).round();
    final nextPct = (currentPct + stepPct).clamp(0, 100);
    widget.onVolumeChanged(nextPct / 100.0);
    _markVolumeAdjusting(holdOpen: true);
  }

  void _cancelHide() {
    _hideTimer?.cancel();
    _hideTimer = null;
  }

  void _notifyPopupActiveState() {
    final active =
        _overlayController.isShowing ||
        _anchorHovered ||
        _popoverHovered ||
        _isDragging ||
        _wheelHoldOpen;
    if (_lastNotifiedPopupActive == active) return;
    _lastNotifiedPopupActive = active;
    widget.onPopupActiveChanged?.call(active);
  }

  void _showPopoverIfPossible() {
    if (!widget.allowPopover) return;
    _cancelHide();
    if (!_overlayController.isShowing && Overlay.maybeOf(context) != null) {
      _overlayController.show();
    }
    _notifyPopupActiveState();
  }

  void _scheduleHideIfIdle() {
    if (_anchorHovered || _popoverHovered || _isDragging || _wheelHoldOpen) {
      return;
    }
    _hideTimer?.cancel();
    _hideTimer = Timer(KonataPlaybackTokens.volumePopoverDismissDelay, () {
      if (!mounted ||
          _anchorHovered ||
          _popoverHovered ||
          _isDragging ||
          _wheelHoldOpen) {
        return;
      }
      _adjustIdleTimer?.cancel();
      if (_showVolumeNumber) {
        setState(() => _showVolumeNumber = false);
      }
      if (_overlayController.isShowing) {
        _overlayController.hide();
      }
      _notifyPopupActiveState();
    });
  }

  void _setDragging(bool dragging) {
    if (_isDragging != dragging || (dragging && !_showVolumeNumber)) {
      setState(() {
        _isDragging = dragging;
        if (dragging) {
          _showVolumeNumber = true;
        }
      });
    }
    if (dragging) {
      _cancelHide();
      _adjustIdleTimer?.cancel();
    }
    _notifyPopupActiveState();
  }

  void _finishDrag() {
    _setDragging(false);
    if (_anchorHovered || _popoverHovered) {
      _restartAdjustIdleTimer();
    } else {
      _wheelHoldOpen = false;
      _scheduleHideIfIdle();
    }
  }

  void _updateFromPopoverDy(double dy) {
    const topPad = KonataPlaybackTokens.volumePopoverVerticalPadding;
    final trackHeight = KonataPlaybackTokens.volumePopoverHeight - topPad * 2;
    final safeTrackHeight = trackHeight > 0 ? trackHeight : 1.0;
    final percent =
        ((1.0 - (dy - topPad) / safeTrackHeight).clamp(0.0, 1.0) * 100)
            .roundToDouble();
    widget.onVolumeChanged((percent / 100.0).clamp(0.0, 1.0));
  }

  Widget _buildPopover(BuildContext context) {
    final p = context.palette;
    final effective = widget.isMuted ? 0.0 : widget.volume.clamp(0.0, 1.0);
    final displayPct = (effective * 100).round().clamp(0, 100);
    final bgColor = KonataPlaybackTokens.glassSurface(p);
    final borderColor = KonataPlaybackTokens.glassBorder(p);
    final activeColor = p.progressFill;
    final trackColor = p.progressTrack;
    final knobSize = _isDragging
        ? KonataPlaybackTokens.volumeKnobDraggingSize
        : KonataPlaybackTokens.volumeKnobRestSize;
    final trackHeight =
        KonataPlaybackTokens.volumePopoverHeight -
        KonataPlaybackTokens.volumePopoverVerticalPadding * 2;

    return Positioned.fill(
      child: Align(
        alignment: Alignment.topLeft,
        child: CompositedTransformFollower(
          link: _layerLink,
          showWhenUnlinked: false,
          targetAnchor: Alignment.topCenter,
          followerAnchor: Alignment.bottomCenter,
          offset: Offset.zero,
          child: Material(
            type: MaterialType.transparency,
            child: Listener(
              onPointerSignal: _handlePointerSignal,
              child: MouseRegion(
                onEnter: (_) {
                  setState(() => _popoverHovered = true);
                  _cancelHide();
                  _notifyPopupActiveState();
                },
                onExit: (_) {
                  setState(() {
                    _popoverHovered = false;
                    _wheelHoldOpen = false;
                  });
                  _scheduleHideIfIdle();
                },
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: KonataTheme.borderRadiusPill,
                        boxShadow: [
                          BoxShadow(
                            color: KonataPlaybackTokens.shadowColor(p),
                            blurRadius: 18,
                            offset: const Offset(0, 6),
                          ),
                        ],
                      ),
                      child: ClipRRect(
                        borderRadius: KonataTheme.borderRadiusPill,
                        child: BackdropFilter(
                          filter: KonataTheme.blurFilterCapsule,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: bgColor,
                              borderRadius: KonataTheme.borderRadiusPill,
                              border: Border.all(color: borderColor, width: 1),
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                AnimatedSize(
                                  duration: KonataTheme.motionFast,
                                  curve: Curves.easeOutCubic,
                                  child: _showVolumeNumber
                                      ? Padding(
                                          padding: const EdgeInsets.only(
                                            top: 10,
                                            bottom: 2,
                                          ),
                                          child: SizedBox(
                                            width: KonataPlaybackTokens
                                                .volumePopoverWidth,
                                            child: Text(
                                              '$displayPct',
                                              key: const ValueKey(
                                                'konata_volume_popover_number',
                                              ),
                                              textAlign: TextAlign.center,
                                              maxLines: 1,
                                              softWrap: false,
                                              style: TextStyle(
                                                color: p.textPrimary,
                                                fontSize: KonataTheme.fontSizeCaptionXs,
                                                fontWeight: FontWeight.w700,
                                                fontFeatures:
                                                    KonataPlaybackTokens
                                                        .tabularNumbers,
                                                height: 1.1,
                                                decoration: TextDecoration.none,
                                              ),
                                            ),
                                          ),
                                        )
                                      : const SizedBox.shrink(),
                                ),
                                MouseRegion(
                                  cursor: _isDragging
                                      ? SystemMouseCursors.grabbing
                                      : SystemMouseCursors.click,
                                  child: RawGestureDetector(
                                    behavior: HitTestBehavior.opaque,
                                    gestures: {
                                      VerticalDragGestureRecognizer:
                                          GestureRecognizerFactoryWithHandlers<
                                            VerticalDragGestureRecognizer
                                          >(
                                            () => VerticalDragGestureRecognizer()
                                              ..dragStartBehavior =
                                                  DragStartBehavior.down
                                              ..gestureSettings =
                                                  const DeviceGestureSettings(
                                                    touchSlop: 1.0,
                                                  ),
                                            (instance) {
                                              instance
                                                ..dragStartBehavior =
                                                    DragStartBehavior.down
                                                ..gestureSettings =
                                                    const DeviceGestureSettings(
                                                      touchSlop: 1.0,
                                                    )
                                                ..onDown = (d) {
                                                  _setDragging(true);
                                                  _updateFromPopoverDy(
                                                    d.localPosition.dy,
                                                  );
                                                }
                                                ..onStart = (d) {
                                                  _setDragging(true);
                                                  _updateFromPopoverDy(
                                                    d.localPosition.dy,
                                                  );
                                                }
                                                ..onUpdate = (d) {
                                                  _updateFromPopoverDy(
                                                    d.localPosition.dy,
                                                  );
                                                }
                                                ..onEnd = (_) {
                                                  _finishDrag();
                                                }
                                                ..onCancel = _finishDrag;
                                            },
                                          ),
                                      TapGestureRecognizer:
                                          GestureRecognizerFactoryWithHandlers<
                                            TapGestureRecognizer
                                          >(
                                            () => TapGestureRecognizer()
                                              ..gestureSettings =
                                                  const DeviceGestureSettings(
                                                    touchSlop: 1.0,
                                                  ),
                                            (instance) {
                                              instance
                                                ..gestureSettings =
                                                    const DeviceGestureSettings(
                                                      touchSlop: 1.0,
                                                    )
                                                ..onTapDown = (d) {
                                                  _setDragging(true);
                                                  _updateFromPopoverDy(
                                                    d.localPosition.dy,
                                                  );
                                                }
                                                ..onTapUp = (_) {
                                                  _finishDrag();
                                                }
                                                ..onTapCancel = _finishDrag;
                                            },
                                          ),
                                    },
                                    child: Container(
                                      width: KonataPlaybackTokens
                                          .volumePopoverWidth,
                                      height: KonataPlaybackTokens
                                          .volumePopoverHeight,
                                      padding: const EdgeInsets.symmetric(
                                        vertical: KonataPlaybackTokens
                                            .volumePopoverVerticalPadding,
                                      ),
                                      child: Center(
                                        child: Stack(
                                          alignment: Alignment.bottomCenter,
                                          clipBehavior: Clip.none,
                                          children: [
                                            Container(
                                              width: 4,
                                              height: trackHeight,
                                              decoration: BoxDecoration(
                                                color: trackColor,
                                                borderRadius:
                                                    KonataTheme.borderRadiusPill,
                                              ),
                                            ),
                                            Container(
                                              width: 4,
                                              height: (trackHeight * effective)
                                                  .clamp(0.0, trackHeight),
                                              decoration: BoxDecoration(
                                                color: activeColor,
                                                borderRadius:
                                                    KonataTheme.borderRadiusPill,
                                              ),
                                            ),
                                            Positioned(
                                              bottom:
                                                  (trackHeight * effective -
                                                          knobSize / 2)
                                                      .clamp(
                                                        0.0,
                                                        (trackHeight - knobSize)
                                                            .clamp(
                                                              0.0,
                                                              trackHeight,
                                                            ),
                                                      ),
                                              child: AnimatedContainer(
                                                duration: KonataPlaybackTokens
                                                    .volumeKnobMotionDuration,
                                                width: knobSize,
                                                height: knobSize,
                                                decoration: BoxDecoration(
                                                  color: activeColor,
                                                  shape: BoxShape.circle,
                                                  boxShadow: [
                                                    BoxShadow(
                                                      color: KonataTheme.pureBlack
                                                          .withValues(
                                                            alpha: 0.28,
                                                          ),
                                                      blurRadius: 4,
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    Container(
                      width: KonataPlaybackTokens.volumePopoverWidth,
                      height: _kPopoverClearanceBridgeHeight,
                      color: Colors.transparent,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final effective = widget.isMuted ? 0.0 : widget.volume.clamp(0.0, 1.0);
    final primary = p.textPrimary;

    final touch = KonataAdaptiveTokens.isAndroid;
    final pill = Listener(
      onPointerSignal: _handlePointerSignal,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: touch
            ? null
            : (_) {
                setState(() => _anchorHovered = true);
                _showPopoverIfPossible();
              },
        onExit: touch
            ? null
            : (_) {
                setState(() {
                  _anchorHovered = false;
                  _wheelHoldOpen = false;
                });
                _scheduleHideIfIdle();
              },
        child: GestureDetector(
          key: const ValueKey('konata_volume_mute_button'),
          behavior: HitTestBehavior.opaque,
          onTap: () {
            widget.onToggleMute();
            if (!touch) {
              _markVolumeAdjusting();
            }
          },
          onLongPress: touch
              ? () => _markVolumeAdjusting(holdOpen: true)
              : null,
          child: SizedBox(
            width: touch ? KonataAdaptiveTokens.touchTarget : null,
            height: touch ? KonataAdaptiveTokens.touchTarget : null,
            child: Center(
              child: AnimatedContainer(
                duration: KonataTheme.motionMicro,
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: (_anchorHovered || _popoverHovered || _isDragging)
                      ? KonataPlaybackTokens.softFill(p)
                      : Colors.transparent,
                  borderRadius: KonataTheme.borderRadiusPill,
                ),
                child: Icon(
                  _resolveVolumeIcon(effective),
                  size: touch ? 19 : 17,
                  color: primary,
                ),
              ),
            ),
          ),
        ),
      ),
    );

    if (Overlay.maybeOf(context) == null) {
      return pill;
    }

    return CompositedTransformTarget(
      link: _layerLink,
      child: OverlayPortal(
        controller: _overlayController,
        overlayChildBuilder: _buildPopover,
        child: pill,
      ),
    );
  }
}
