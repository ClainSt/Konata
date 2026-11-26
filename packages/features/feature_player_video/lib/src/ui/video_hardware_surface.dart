import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_design_system/konata_design_system.dart';

import '../state/video_playback_controller.dart';
import '../state/video_playback_state.dart';

/// 主舞台及两类小窗共享硬件表面，统一处理透明视口、纹理尺寸和生命周期。
class VideoHardwareSurface extends StatefulWidget {
  const VideoHardwareSurface({
    super.key,
    required this.controller,
    required this.state,
    required this.fallback,
    this.textureBuilder,
    this.cornerRadius = 0,
  });

  final VideoPlaybackController controller;
  final VideoPlaybackState state;
  final Widget fallback;
  final Widget Function(BuildContext, int?)? textureBuilder;
  final double cornerRadius;

  static bool hasUnderlay(
    VideoPlaybackController controller,
    VideoPlaybackState state,
  ) {
    if (state.audioOnlyMode || state.isClosing || state.errorMessage != null) {
      return false;
    }
    if (controller.env.platform == KonataPlatform.windows) {
      return state.windowsUnderlayActive;
    }
    final port = controller.env.androidSurfacePort;
    return port != null && !port.isDisposed;
  }

  @override
  State<VideoHardwareSurface> createState() => _VideoHardwareSurfaceState();
}

class _VideoHardwareSurfaceState extends State<VideoHardwareSurface> {
  Object _owner = Object();
  Size? _lastSize;
  int? _lastTextureId;

  @override
  void didUpdateWidget(covariant VideoHardwareSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      _owner = Object();
      _lastSize = null;
      _lastTextureId = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final state = widget.state;
    if (VideoHardwareSurface.hasUnderlay(controller, state)) {
      _lastSize = null;
      _lastTextureId = null;
      final owner = _owner;
      return KonataUnderlayViewport(
        key: const ValueKey('video_hardware_underlay'),
        owner: owner,
        cornerRadius: widget.cornerRadius,
        onGeometryChanged: (geometry) {
          final rect = geometry?.rect;
          unawaited(
            controller.updateHardwareViewport(
              owner: owner,
              leftPx: rect?.left.toInt() ?? 0,
              topPx: rect?.top.toInt() ?? 0,
              rightPx: rect?.right.toInt() ?? 0,
              bottomPx: rect?.bottom.toInt() ?? 0,
              cornerRadiusPx: geometry?.radius ?? 0,
              visible: geometry != null,
            ),
          );
        },
      );
    }
    final textureId = state.textureId;
    final builder = widget.textureBuilder;
    if (state.audioOnlyMode || state.isClosing || state.errorMessage != null) {
      _lastSize = null;
      _lastTextureId = null;
      return widget.fallback;
    }
    final surface = builder != null
        ? builder(context, textureId)
        : textureId != null && textureId >= 0
        ? Texture(textureId: textureId)
        : widget.fallback;
    if (controller.env.platform != KonataPlatform.windows ||
        textureId == null ||
        textureId < 0) {
      _lastSize = null;
      _lastTextureId = null;
      return surface;
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final dpr = MediaQuery.devicePixelRatioOf(context);
        final size = Size(
          (constraints.maxWidth * dpr).roundToDouble(),
          (constraints.maxHeight * dpr).roundToDouble(),
        );
        if (constraints.hasBoundedWidth &&
            constraints.hasBoundedHeight &&
            !size.isEmpty &&
            size.isFinite &&
            (_lastSize != size || _lastTextureId != textureId)) {
          _lastSize = size;
          _lastTextureId = textureId;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted ||
                !identical(controller, widget.controller) ||
                _lastSize != size ||
                _lastTextureId != textureId) {
              return;
            }
            unawaited(
              controller.resizeDesktopSurfaceTarget(
                size.width.toInt(),
                size.height.toInt(),
              ),
            );
          });
        }
        return surface;
      },
    );
  }
}
