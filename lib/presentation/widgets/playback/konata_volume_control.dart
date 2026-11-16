import 'dart:async';
import 'dart:ui';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../theme/konata_palette.dart';
import '../../theme/konata_playback_tokens.dart';

/// 音视频播控胶囊共用的紧凑滚轮数字音量控件（形如 `🔊 80`，彻底去除横向滑杆与 `%`）。
///
/// 交互规范：
/// - 悬停在控件或浮层上滚动鼠标滚轮，以 `1` 步长（`0..100`）精确微调音量；
/// - 点击控件主体即刻静音 / 恢复静音前精确音量；
/// - 鼠标悬停时自动在上方弹出无遮挡毛玻璃纵向滑条浮层，支持 0 延迟点击、框外拖拽锁定与 1:1 连续调节。
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
  });

  /// 当前音量 (`0.0 ~ 1.0`)。
  final double volume;

  /// 是否静音。
  final bool isMuted;

  /// 音量变化回调 (`0.0 ~ 1.0`)。
  final ValueChanged<double> onVolumeChanged;

  /// 点击切换静音回调。
  final VoidCallback onToggleMute;

  /// 纵向音量浮层悬停或拖拽激活态变更回调（供视频页锁定底栏不自动隐藏）。
  final ValueChanged<bool>? onPopupActiveChanged;

  /// 宿主当前是否允许保持或展示纵向音量浮层（外部强制隐藏 HUD 时关闭浮层防残留）。
  final bool allowPopover;

  @override
  State<KonataVolumeControl> createState() => _KonataVolumeControlState();
}

class _KonataVolumeControlState extends State<KonataVolumeControl> {
  final LayerLink _layerLink = LayerLink();
  final OverlayPortalController _overlayController = OverlayPortalController();
  Timer? _hideTimer;
  bool _anchorHovered = false;
  bool _popoverHovered = false;
  bool _isDragging = false;
  bool _lastNotifiedPopupActive = false;

  @override
  void didUpdateWidget(covariant KonataVolumeControl oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.allowPopover &&
        (_overlayController.isShowing ||
            _anchorHovered ||
            _popoverHovered ||
            _isDragging)) {
      _hideTimer?.cancel();
      _anchorHovered = false;
      _popoverHovered = false;
      _isDragging = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || widget.allowPopover) return;
        if (_overlayController.isShowing) {
          _overlayController.hide();
        }
        _notifyPopupActiveState();
      });
    }
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
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

  void _handlePointerSignal(PointerSignalEvent signal) {
    if (signal is! PointerScrollEvent) return;
    final dy = signal.scrollDelta.dy;
    if (dy == 0) return;
    final stepPct = (dy < 0
            ? KonataPlaybackTokens.wheelVolumeStep
            : -KonataPlaybackTokens.wheelVolumeStep)
        .round();
    final currentPct =
        ((widget.isMuted ? 0.0 : widget.volume.clamp(0.0, 1.0)) * 100).round();
    final nextPct = (currentPct + stepPct).clamp(0, 100);
    widget.onVolumeChanged(nextPct / 100.0);
  }

  void _cancelHide() {
    _hideTimer?.cancel();
    _hideTimer = null;
  }

  void _notifyPopupActiveState() {
    final active = _overlayController.isShowing ||
        _anchorHovered ||
        _popoverHovered ||
        _isDragging;
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
    if (_anchorHovered || _popoverHovered || _isDragging) return;
    _hideTimer?.cancel();
    _hideTimer = Timer(KonataPlaybackTokens.volumePopoverDismissDelay, () {
      if (!mounted || _anchorHovered || _popoverHovered || _isDragging) return;
      if (_overlayController.isShowing) {
        _overlayController.hide();
      }
      _notifyPopupActiveState();
    });
  }

  void _setDragging(bool dragging) {
    if (_isDragging != dragging) {
      setState(() => _isDragging = dragging);
    }
    if (dragging) {
      _cancelHide();
    }
    _notifyPopupActiveState();
  }

  void _finishDrag() {
    _setDragging(false);
    _scheduleHideIfIdle();
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
                  setState(() => _popoverHovered = false);
                  _scheduleHideIfIdle();
                },
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    MouseRegion(
                      cursor: _isDragging
                          ? SystemMouseCursors.grabbing
                          : SystemMouseCursors.click,
                      child: RawGestureDetector(
                        behavior: HitTestBehavior.opaque,
                        gestures: {
                          VerticalDragGestureRecognizer:
                              GestureRecognizerFactoryWithHandlers<
                                  VerticalDragGestureRecognizer>(
                                () => VerticalDragGestureRecognizer()
                                  ..dragStartBehavior = DragStartBehavior.down
                                  ..gestureSettings =
                                      const DeviceGestureSettings(
                                        touchSlop: 1.0,
                                      ),
                                (instance) {
                                  instance
                                    ..dragStartBehavior = DragStartBehavior.down
                                    ..gestureSettings =
                                        const DeviceGestureSettings(
                                          touchSlop: 1.0,
                                        )
                                    ..onDown = (d) {
                                      _setDragging(true);
                                      _updateFromPopoverDy(d.localPosition.dy);
                                    }
                                    ..onStart = (d) {
                                      _setDragging(true);
                                      _updateFromPopoverDy(d.localPosition.dy);
                                    }
                                    ..onUpdate = (d) {
                                      _updateFromPopoverDy(d.localPosition.dy);
                                    }
                                    ..onEnd = (_) {
                                      _finishDrag();
                                    }
                                    ..onCancel = _finishDrag;
                                },
                              ),
                          TapGestureRecognizer:
                              GestureRecognizerFactoryWithHandlers<
                                  TapGestureRecognizer>(
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
                                      _updateFromPopoverDy(d.localPosition.dy);
                                    }
                                    ..onTapUp = (_) {
                                      _finishDrag();
                                    }
                                    ..onTapCancel = _finishDrag;
                                },
                              ),
                        },
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(999),
                          child: BackdropFilter(
                            filter: ImageFilter.blur(sigmaX: 28, sigmaY: 28),
                            child: Container(
                              width: KonataPlaybackTokens.volumePopoverWidth,
                              height: KonataPlaybackTokens.volumePopoverHeight,
                              padding: const EdgeInsets.symmetric(
                                vertical: KonataPlaybackTokens
                                    .volumePopoverVerticalPadding,
                              ),
                              decoration: BoxDecoration(
                                color: bgColor,
                                borderRadius: BorderRadius.circular(999),
                                border: Border.all(
                                  color: borderColor,
                                  width: 1,
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.28),
                                    blurRadius: 18,
                                    offset: const Offset(0, 6),
                                  ),
                                ],
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
                                        borderRadius: BorderRadius.circular(
                                          999,
                                        ),
                                      ),
                                    ),
                                    Container(
                                      width: 4,
                                      height: (trackHeight * effective).clamp(
                                        0.0,
                                        trackHeight,
                                      ),
                                      decoration: BoxDecoration(
                                        color: activeColor,
                                        borderRadius: BorderRadius.circular(
                                          999,
                                        ),
                                      ),
                                    ),
                                    Positioned(
                                      bottom:
                                          (trackHeight * effective -
                                                  knobSize / 2)
                                              .clamp(
                                                0.0,
                                                (trackHeight - knobSize).clamp(
                                                  0.0,
                                                  trackHeight,
                                                ),
                                              ),
                                      child: AnimatedContainer(
                                        duration: const Duration(
                                          milliseconds: 100,
                                        ),
                                        width: knobSize,
                                        height: knobSize,
                                        decoration: BoxDecoration(
                                          color: activeColor,
                                          shape: BoxShape.circle,
                                          boxShadow: [
                                            BoxShadow(
                                              color: Colors.black.withValues(
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
                      ),
                    ),
                    // 底部按钮与滑轨之间的透明命中桥接区，避免指针上移跨越间隙时闪断收起。
                    Container(
                      width: KonataPlaybackTokens.volumePopoverWidth,
                      height: KonataPlaybackTokens.volumePopoverBridgeHeight,
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
    final secondary = p.textSecondary;

    final pill = Listener(
      onPointerSignal: _handlePointerSignal,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) {
          setState(() => _anchorHovered = true);
          _showPopoverIfPossible();
        },
        onExit: (_) {
          setState(() => _anchorHovered = false);
          _scheduleHideIfIdle();
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onToggleMute,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: (_anchorHovered || _popoverHovered || _isDragging)
                  ? KonataPlaybackTokens.softFill(p)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Icon(
              _resolveVolumeIcon(effective),
              size: 17,
              color: widget.isMuted ? secondary : primary,
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
