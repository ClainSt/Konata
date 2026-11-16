import 'dart:async';
import 'dart:ui';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../theme/konata_palette.dart';
import '../../theme/konata_playback_tokens.dart';

/// 音视频播控胶囊共用的紧凑滚轮数字音量控件（形如 `🔊 80`，彻底去除横向滑杆与 `%`）。
///
/// 交互规范：
/// - 悬停在控件或浮层上滚动鼠标滚轮，以 `5` 步长（`0..100`）实时精细微调音量；
/// - 点击控件主体即刻静音 / 恢复原音量；
/// - 鼠标悬停时自动在上方弹出紧凑毛玻璃纵向滑条浮层，支持直觉点击或上下拖拽调节。
class KonataVolumeControl extends StatefulWidget {
  /// 创建紧凑音量控件。
  const KonataVolumeControl({
    super.key,
    required this.volume,
    required this.isMuted,
    required this.onVolumeChanged,
    required this.onToggleMute,
    this.forceOnDarkOverlay = false,
  });

  /// 当前音量 (`0.0 ~ 1.0`)。
  final double volume;

  /// 是否静音。
  final bool isMuted;

  /// 音量变化回调 (`0.0 ~ 1.0`)。
  final ValueChanged<double> onVolumeChanged;

  /// 点击切换静音回调。
  final VoidCallback onToggleMute;

  /// 是否渲染在深色视频或沉浸音频流光层之上。
  final bool forceOnDarkOverlay;

  @override
  State<KonataVolumeControl> createState() => _KonataVolumeControlState();
}

class _KonataVolumeControlState extends State<KonataVolumeControl> {
  final LayerLink _layerLink = LayerLink();
  final OverlayPortalController _overlayController = OverlayPortalController();
  Timer? _hideTimer;
  bool _anchorHovered = false;
  bool _popoverHovered = false;

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
    final step = signal.scrollDelta.dy < 0 ? 0.05 : -0.05;
    final base = widget.isMuted ? 0.0 : widget.volume;
    final next = (base + step).clamp(0.0, 1.0);
    widget.onVolumeChanged(next);
  }

  void _cancelHide() {
    _hideTimer?.cancel();
    _hideTimer = null;
  }

  void _showPopoverIfPossible() {
    _cancelHide();
    if (!_overlayController.isShowing && Overlay.maybeOf(context) != null) {
      _overlayController.show();
    }
  }

  void _scheduleHideIfIdle() {
    if (_anchorHovered || _popoverHovered) return;
    _hideTimer?.cancel();
    _hideTimer = Timer(KonataPlaybackTokens.volumePopoverDismissDelay, () {
      if (!mounted || _anchorHovered || _popoverHovered) return;
      if (_overlayController.isShowing) {
        _overlayController.hide();
      }
    });
  }

  void _updateVerticalSlider(Offset localPos, double trackHeight) {
    final safeHeight = trackHeight > 0 ? trackHeight : 1.0;
    final ratio = (1.0 - (localPos.dy / safeHeight)).clamp(0.0, 1.0);
    widget.onVolumeChanged(ratio);
  }

  Widget _buildPopover(BuildContext context) {
    final p = context.palette;
    final effective = widget.isMuted ? 0.0 : widget.volume.clamp(0.0, 1.0);
    final bgColor = widget.forceOnDarkOverlay
        ? KonataPlaybackTokens.osdSurfaceDark
        : p.elevatedSurface.withValues(alpha: p.isDark ? 0.88 : 0.94);
    final borderColor = widget.forceOnDarkOverlay
        ? KonataPlaybackTokens.osdBorderLight
        : p.hairline;
    final activeColor = widget.forceOnDarkOverlay
        ? KonataPlaybackTokens.osdAccent
        : p.accent;
    final trackColor = widget.forceOnDarkOverlay
        ? Colors.white.withValues(alpha: 0.22)
        : p.hairline;

    return Positioned.fill(
      child: Align(
        alignment: Alignment.topLeft,
        child: CompositedTransformFollower(
          link: _layerLink,
          showWhenUnlinked: false,
          targetAnchor: Alignment.topCenter,
          followerAnchor: Alignment.bottomCenter,
          offset: const Offset(0, -8),
          child: Listener(
            onPointerSignal: _handlePointerSignal,
            child: MouseRegion(
              onEnter: (_) {
                setState(() => _popoverHovered = true);
                _cancelHide();
              },
              onExit: (_) {
                setState(() => _popoverHovered = false);
                _scheduleHideIfIdle();
              },
              child: ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 28, sigmaY: 28),
                  child: Container(
                    width: KonataPlaybackTokens.volumePopoverWidth,
                    height: KonataPlaybackTokens.volumePopoverHeight,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    decoration: BoxDecoration(
                      color: bgColor,
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: borderColor, width: 1),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.28),
                          blurRadius: 18,
                          offset: const Offset(0, 6),
                        ),
                      ],
                    ),
                    child: LayoutBuilder(
                      builder: (_, constraints) {
                        final trackH = constraints.maxHeight;
                        return GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTapDown: (d) =>
                              _updateVerticalSlider(d.localPosition, trackH),
                          onVerticalDragUpdate: (d) =>
                              _updateVerticalSlider(d.localPosition, trackH),
                          child: Center(
                            child: Stack(
                              alignment: Alignment.bottomCenter,
                              clipBehavior: Clip.none,
                              children: [
                                Container(
                                  width: 4,
                                  height: trackH,
                                  decoration: BoxDecoration(
                                    color: trackColor,
                                    borderRadius: BorderRadius.circular(999),
                                  ),
                                ),
                                Container(
                                  width: 4,
                                  height: (trackH * effective).clamp(0, trackH),
                                  decoration: BoxDecoration(
                                    color: activeColor,
                                    borderRadius: BorderRadius.circular(999),
                                  ),
                                ),
                                Positioned(
                                  bottom: (trackH * effective - 5).clamp(
                                    0.0,
                                    (trackH - 10).clamp(0.0, trackH),
                                  ),
                                  child: Container(
                                    width: 10,
                                    height: 10,
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
                        );
                      },
                    ),
                  ),
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
    final level = (effective * 100).round().clamp(0, 100);

    final primary = widget.forceOnDarkOverlay
        ? KonataPlaybackTokens.osdTextPrimary
        : p.textPrimary;
    final secondary = widget.forceOnDarkOverlay
        ? KonataPlaybackTokens.osdTextSecondary
        : p.textSecondary;

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
          child: Tooltip(
            message: '滚轮微调音量 · 点击静音 ($level)',
            waitDuration: const Duration(milliseconds: 500),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
              decoration: BoxDecoration(
                color: (_anchorHovered || _popoverHovered)
                    ? (widget.forceOnDarkOverlay
                          ? Colors.white.withValues(alpha: 0.12)
                          : p.softFill)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _resolveVolumeIcon(effective),
                    size: 17,
                    color: widget.isMuted ? secondary : primary,
                  ),
                  const SizedBox(width: 4),
                  SizedBox(
                    width: 24,
                    child: Text(
                      '$level',
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        color: widget.isMuted ? secondary : primary,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        fontFeatures: KonataPlaybackTokens.tabularNumbers,
                      ),
                    ),
                  ),
                ],
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
