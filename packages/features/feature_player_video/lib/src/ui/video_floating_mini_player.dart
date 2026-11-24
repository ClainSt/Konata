import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:konata_design_system/konata_design_system.dart';

import '../state/video_playback_controller.dart';
import '../state/video_playback_state.dart';

/// 16:9 比例可拖拽悬浮视频小窗（拖拽偏移坐标直连叶子 `ValueNotifier`，杜绝拖帧重建全树）。
class VideoFloatingMiniPlayer extends StatefulWidget {
  /// 创建可拖拽悬浮视频小窗。
  const VideoFloatingMiniPlayer({
    super.key,
    required this.controller,
    this.offsetNotifier,
    this.videoSurfaceBuilder,
    this.onExpand,
    this.onClose,
    this.viewportSize,
    this.width = KonataPlaybackTokens.floatingMiniVideoWidth,
    this.edgeMargin = KonataPlaybackTokens.floatingMiniEdgeMargin,
    this.initialOffset,
  });

  /// 视频播放核心状态控制器。
  final VideoPlaybackController controller;

  /// 可选外部注入的拖拽坐标叶子监听器；未传入时自动复用控制器内坐标监听器。
  final ValueNotifier<Offset>? offsetNotifier;

  /// 可选宿主平台视频画面构建回调；未传入时展示暗色视频舞台占位。
  final Widget Function(BuildContext context, int? textureId)?
  videoSurfaceBuilder;

  /// 点击回弹恢复至全屏或主舞台回调。
  final VoidCallback? onExpand;

  /// 点击关闭小窗回调。
  final VoidCallback? onClose;

  /// 可选外层可见区域边界尺寸（用于限制拖拽不出界）。
  final Size? viewportSize;

  /// 悬浮小窗基准逻辑宽度（高度按 16:9 自动推导）。
  final double width;

  /// 距容器边缘的安全保留边距。
  final double edgeMargin;

  /// 若当前坐标尚未初始化，使用的初始左上角偏移坐标。
  final Offset? initialOffset;

  @override
  State<VideoFloatingMiniPlayer> createState() =>
      _VideoFloatingMiniPlayerState();
}

class _VideoFloatingMiniPlayerState extends State<VideoFloatingMiniPlayer> {
  bool _hovered = false;

  ValueNotifier<Offset> get _offsetNotifier =>
      widget.offsetNotifier ?? widget.controller.miniPlayerOffsetNotifier;

  double get _height => widget.width * 9.0 / 16.0;

  @override
  void initState() {
    super.initState();
    final initOff = widget.initialOffset;
    if (initOff != null && _offsetNotifier.value == Offset.zero) {
      _offsetNotifier.value = initOff;
    }
  }

  Offset _clampOffset(Offset candidate, Size bounds) {
    if (bounds.isEmpty) {
      return Offset(
        candidate.dx < widget.edgeMargin ? widget.edgeMargin : candidate.dx,
        candidate.dy < widget.edgeMargin ? widget.edgeMargin : candidate.dy,
      );
    }
    final maxX = (bounds.width - widget.width - widget.edgeMargin).clamp(
      widget.edgeMargin,
      double.infinity,
    );
    final maxY = (bounds.height - _height - widget.edgeMargin).clamp(
      widget.edgeMargin,
      double.infinity,
    );
    return Offset(
      candidate.dx.clamp(widget.edgeMargin, maxX).toDouble(),
      candidate.dy.clamp(widget.edgeMargin, maxY).toDouble(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bounds = widget.viewportSize ?? MediaQuery.maybeSizeOf(context) ?? Size.zero;

    return ValueListenableBuilder<Offset>(
      valueListenable: _offsetNotifier,
      builder: (context, rawOffset, _) {
        final effectiveOffset = _clampOffset(rawOffset, bounds);
        return Positioned(
          left: effectiveOffset.dx,
          top: effectiveOffset.dy,
          width: widget.width,
          height: _height,
          child: MouseRegion(
            onEnter: (_) => setState(() => _hovered = true),
            onExit: (_) => setState(() => _hovered = false),
            child: GestureDetector(
              key: const ValueKey('video_floating_mini_player'),
              behavior: HitTestBehavior.opaque,
              onPanUpdate: (details) {
                final next = _clampOffset(
                  _offsetNotifier.value + details.delta,
                  bounds,
                );
                _offsetNotifier.value = next;
              },
              child: ListenableBuilder(
                listenable: widget.controller,
                builder: (context, _) {
                  final state = widget.controller.state;
                  return _MiniPlayerFrame(
                    state: state,
                    controller: widget.controller,
                    hovered: _hovered,
                    videoSurfaceBuilder: widget.videoSurfaceBuilder,
                    onExpand: widget.onExpand,
                    onClose: widget.onClose,
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }
}

class _MiniPlayerFrame extends StatelessWidget {
  const _MiniPlayerFrame({
    required this.state,
    required this.controller,
    required this.hovered,
    required this.videoSurfaceBuilder,
    required this.onExpand,
    required this.onClose,
  });

  final VideoPlaybackState state;
  final VideoPlaybackController controller;
  final bool hovered;
  final Widget Function(BuildContext context, int? textureId)?
  videoSurfaceBuilder;
  final VoidCallback? onExpand;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(
      KonataPlaybackTokens.floatingMiniRadius,
    );
    final surface = videoSurfaceBuilder != null
        ? videoSurfaceBuilder!(context, state.textureId)
        : Container(
            key: const ValueKey('video_mini_placeholder_surface'),
            color: KonataPlaybackTokens.cinemaPureBlack,
            alignment: Alignment.center,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.smart_display_outlined,
                  size: KonataPlaybackTokens.floatingMiniFallbackIconSize,
                  color: KonataPlaybackTokens.osdTextSecondary,
                ),
                const SizedBox(height: 4),
                Text(
                  state.currentWork?.title.isNotEmpty == true
                      ? state.currentWork!.title
                      : '视频小窗播放中',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: KonataPlaybackTokens.osdTextSecondary,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          );

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: const <BoxShadow>[
          BoxShadow(
            color: Color(0x55000000),
            blurRadius: KonataPlaybackTokens.floatingMiniShadowBlur,
            offset: KonataPlaybackTokens.floatingMiniShadowOffset,
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: Container(
          decoration: BoxDecoration(
            color: KonataPlaybackTokens.cinemaPureBlack,
            borderRadius: radius,
            border: Border.all(
              color: KonataPlaybackTokens.osdBorderLight,
              width: KonataPlaybackTokens.floatingMiniBorderWidth,
            ),
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onDoubleTap: () {
                  if (onExpand != null) {
                    onExpand!();
                  } else {
                    unawaited(controller.exitMiniPlayerToStage());
                  }
                },
                child: surface,
              ),
              Positioned(
                top: 6,
                left: 6,
                right: 6,
                child: AnimatedOpacity(
                  opacity: hovered || !state.isPlaying ? 1.0 : 0.85,
                  duration: KonataPlaybackTokens.desktopMiniChromeFadeDuration,
                  child: Row(
                    children: [
                      KonataCapsuleIconButton(
                        key: const ValueKey('mini_player_expand_button'),
                        icon: Icons.open_in_full_rounded,
                        tooltip: '回到全屏舞台',
                        size: KonataPlaybackTokens.floatingMiniOverlayIconSize,
                        padding: const EdgeInsets.all(5),
                        color: KonataPlaybackTokens.osdTextPrimary,
                        onTap: () {
                          if (onExpand != null) {
                            onExpand!();
                          } else {
                            unawaited(controller.exitMiniPlayerToStage());
                          }
                        },
                      ),
                      const Spacer(),
                      KonataCapsuleIconButton(
                        key: const ValueKey('mini_player_play_pause_button'),
                        icon: state.isPlaying
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                        tooltip: state.isPlaying ? '暂停' : '播放',
                        size: KonataPlaybackTokens.floatingMiniOverlayIconSize,
                        padding: const EdgeInsets.all(5),
                        color: KonataPlaybackTokens.osdTextPrimary,
                        onTap: () => unawaited(controller.togglePlayPause()),
                      ),
                      const SizedBox(width: 4),
                      KonataCapsuleIconButton(
                        key: const ValueKey('mini_player_close_button'),
                        icon: Icons.close_rounded,
                        tooltip: '关闭小窗',
                        size: KonataPlaybackTokens.floatingMiniOverlayIconSize,
                        padding: const EdgeInsets.all(5),
                        color: KonataPlaybackTokens.osdTextPrimary,
                        onTap: () {
                          if (onClose != null) {
                            onClose!();
                          } else {
                            unawaited(controller.closeSession());
                          }
                        },
                      ),
                    ],
                  ),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: KonataAdaptiveTokens.progressHeight,
                child: ValueListenableBuilder<Duration>(
                  valueListenable: controller.durationNotifier,
                  builder: (context, dur, _) {
                    final total = dur.inMilliseconds;
                    return ValueListenableBuilder<Duration>(
                      valueListenable: controller.positionNotifier,
                      builder: (context, pos, _) {
                        final ratio = total > 0
                            ? (pos.inMilliseconds / total).clamp(0.0, 1.0)
                            : 0.0;
                        return Align(
                          alignment: Alignment.centerLeft,
                          child: FractionallySizedBox(
                            widthFactor: ratio,
                            heightFactor: 1.0,
                            child: const ColoredBox(
                              color: KonataPlaybackTokens.capsuleProgressFill,
                            ),
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
