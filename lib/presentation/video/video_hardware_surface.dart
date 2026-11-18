import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/playback/audio_playback_notifier.dart';
import '../../application/playback/video_playback_controller.dart';
import '../../domain/playback/video_aspect_mode.dart';
import '../../infrastructure/players/android/android_video_surface_controller.dart';
import '../theme/konata_adaptive_tokens.dart';
import '../theme/konata_playback_tokens.dart';
import '../widgets/playback/konata_cached_artwork_backdrop.dart';

/// 硬件视频渲染表面组件（视频模式零拷贝直出硬件画面；纯音频模式切换背景舞台）。
///
/// 跨端渲染路径：
/// - Android：通过根窗口底层（Underlay）`SurfaceView` + 上层透明 Flutter 画布 `BlendMode.clear` 视口挖空直出，
///   彻底消除 `PlatformView` 跨线程同步栅栏与弹窗遮挡竞态；
/// - Windows：通过 D3D11 三缓冲 DXGI 共享纹理（`rgba16hf` 内部管线）零拷贝合成，100% 兼容窗口亚克力/云母透光材质；
/// - 通过同一 `GlobalObjectKey` 在全屏舞台与悬浮小窗间平滑迁移，绝不重建解码会话。
class KonataHardwareVideoSurface extends ConsumerStatefulWidget {
  /// 创建硬件视频渲染表面。
  const KonataHardwareVideoSurface({
    super.key,
    required this.request,
    this.miniPreview = false,
    this.cornerRadius = 0.0,
  });

  /// 关联的视频播放请求键。
  final VideoLaunchRequest request;

  /// 是否处于悬浮小窗预览态。
  final bool miniPreview;

  /// 视口圆角半径（逻辑像素；悬浮小窗传入标准圆角，全屏与画中画为 0）。
  final double cornerRadius;

  @override
  ConsumerState<KonataHardwareVideoSurface> createState() =>
      _KonataHardwareVideoSurfaceState();
}

class _KonataHardwareVideoSurfaceState
    extends ConsumerState<KonataHardwareVideoSurface> {
  AndroidVideoSurfaceController? _androidUnderlayController;
  Size? _lastReportedSurfaceSize;
  double? _lastReportedDpr;

  bool get _isWidgetTest => WidgetsBinding.instance.runtimeType
      .toString()
      .contains('TestWidgetsFlutterBinding');

  @override
  void initState() {
    super.initState();
    if (KonataAdaptiveTokens.isAndroid && !_isWidgetTest) {
      final ctrl = AndroidVideoSurfaceController();
      _androidUnderlayController = ctrl;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          ref
              .read(videoPlaybackProvider(widget.request).notifier)
              .attachAndroidSurface(ctrl);
        }
      });
    }
  }

  @override
  void dispose() {
    final ctrl = _androidUnderlayController;
    _androidUnderlayController = null;
    if (ctrl != null) {
      unawaited(ctrl.hideViewport());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final snap = ref.watch(
      videoPlaybackProvider(widget.request).select(
        (s) => (
          texId: s.textureId,
          audioOnly: s.audioOnlyMode,
          aspectMode: s.aspectMode,
          videoW: s.probeStats.videoWidth,
          videoH: s.probeStats.videoHeight,
          work: s.currentWork,
        ),
      ),
    );
    final controller = ref.read(videoPlaybackProvider(widget.request).notifier);

    if (snap.audioOnly) {
      if (_androidUnderlayController != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          unawaited(_androidUnderlayController?.hideViewport());
        });
      }
      final work = snap.work ?? widget.request.work;
      final poster =
          work.posterPath ?? work.bangumiPosterPath ?? work.posterFallback;
      final cover = (poster != null && poster.isNotEmpty)
          ? ManagedPosterAudioCover(url: poster, workId: work.id)
          : const EmptyAudioCover();
      return KonataCachedArtworkBackdrop(cover: cover);
    }

    Widget rawSurface;
    if (KonataAdaptiveTokens.isAndroid) {
      if (_isWidgetTest || _androidUnderlayController == null) {
        rawSurface = const ColoredBox(
          key: ValueKey('android_hardware_surface_placeholder'),
          color: KonataPlaybackTokens.cinemaPureBlack,
        );
      } else {
        final dpr = MediaQuery.devicePixelRatioOf(context);
        rawSurface = _AndroidUnderlayCutout(
          key: const ValueKey('android_underlay_cutout_surface'),
          controller: _androidUnderlayController!,
          devicePixelRatio: dpr,
          cornerRadius: widget.cornerRadius,
        );
      }
    } else {
      final texId = snap.texId;
      if (texId == null || texId < 0) {
        rawSurface = const ColoredBox(
          color: KonataPlaybackTokens.cinemaPureBlack,
        );
      } else {
        rawSurface = LayoutBuilder(
          builder: (context, constraints) {
            final dpr = MediaQuery.devicePixelRatioOf(context);
            final sz = Size(constraints.maxWidth, constraints.maxHeight);
            if (!widget.miniPreview &&
                (_lastReportedSurfaceSize != sz || _lastReportedDpr != dpr)) {
              _lastReportedSurfaceSize = sz;
              _lastReportedDpr = dpr;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted && sz.width > 0 && sz.height > 0) {
                  controller.notifySurfaceViewportSize(
                    sz.width,
                    sz.height,
                    dpr,
                  );
                }
              });
            }
            return SizedBox.expand(
              child: Texture(
                textureId: texId,
                filterQuality: FilterQuality.medium,
              ),
            );
          },
        );
      }
    }

    final fitted = _wrapAspect(
      rawSurface,
      snap.aspectMode,
      snap.videoW ?? 0,
      snap.videoH ?? 0,
    );

    if (KonataAdaptiveTokens.isAndroid && widget.miniPreview) {
      return fitted;
    }

    return ColoredBox(
      color: KonataPlaybackTokens.cinemaPureBlack,
      child: fitted,
    );
  }

  Widget _wrapAspect(
    Widget child,
    VideoAspectMode mode,
    int videoWidth,
    int videoHeight,
  ) {
    if (mode == VideoAspectMode.stretch) {
      return SizedBox.expand(child: child);
    }
    if (mode == VideoAspectMode.ratio16x9) {
      return Center(
        child: AspectRatio(aspectRatio: 16 / 9, child: child),
      );
    }
    if (mode == VideoAspectMode.ratio4x3) {
      return Center(
        child: AspectRatio(aspectRatio: 4 / 3, child: child),
      );
    }
    if (mode == VideoAspectMode.cover && videoWidth > 0 && videoHeight > 0) {
      return ClipRect(
        child: FittedBox(
          fit: BoxFit.cover,
          child: SizedBox(
            width: videoWidth.toDouble(),
            height: videoHeight.toDouble(),
            child: child,
          ),
        ),
      );
    }
    return SizedBox.expand(child: child);
  }
}

/// Android 根窗口底层（Underlay）透明挖空渲染对象。
///
/// 在绘制阶段直接以 `BlendMode.clear` 挖空目标矩形（支持圆角），
/// 并实时同步当前物理像素几何坐标至原生底层 `SurfaceView`，避免拖拽与形变期间产生任何帧滞后。
class _AndroidUnderlayCutout extends LeafRenderObjectWidget {
  const _AndroidUnderlayCutout({
    super.key,
    required this.controller,
    required this.devicePixelRatio,
    required this.cornerRadius,
  });

  final AndroidVideoSurfaceController controller;
  final double devicePixelRatio;
  final double cornerRadius;

  @override
  RenderObject createRenderObject(BuildContext context) {
    return _RenderAndroidUnderlayCutout(
      controller,
      devicePixelRatio,
      cornerRadius,
    );
  }

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderAndroidUnderlayCutout renderObject,
  ) {
    renderObject
      ..controller = controller
      ..devicePixelRatio = devicePixelRatio
      ..cornerRadius = cornerRadius;
  }
}

class _RenderAndroidUnderlayCutout extends RenderBox {
  _RenderAndroidUnderlayCutout(
    this._controller,
    this._devicePixelRatio,
    this._cornerRadius,
  );

  static final Paint _clearPaint = Paint()
    ..blendMode = BlendMode.clear
    ..isAntiAlias = true;

  AndroidVideoSurfaceController _controller;
  double _devicePixelRatio;
  double _cornerRadius;

  set controller(AndroidVideoSurfaceController value) {
    if (identical(_controller, value)) return;
    _controller = value;
    markNeedsPaint();
  }

  set devicePixelRatio(double value) {
    if ((_devicePixelRatio - value).abs() < 0.001) return;
    _devicePixelRatio = value;
    markNeedsPaint();
  }

  set cornerRadius(double value) {
    if ((_cornerRadius - value).abs() < 0.1) return;
    _cornerRadius = value;
    markNeedsPaint();
  }

  @override
  bool get sizedByParent => true;

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.biggest;

  @override
  bool hitTestSelf(Offset position) => true;

  @override
  void paint(PaintingContext context, Offset offset) {
    if (size.isEmpty) return;
    final rect = offset & size;
    if (_cornerRadius > 0.5) {
      context.canvas.drawRRect(
        RRect.fromRectAndRadius(rect, Radius.circular(_cornerRadius)),
        _clearPaint,
      );
    } else {
      context.canvas.drawRect(rect, _clearPaint);
    }

    final globalTopLeft = localToGlobal(Offset.zero);
    final leftPx = (globalTopLeft.dx * _devicePixelRatio).round();
    final topPx = (globalTopLeft.dy * _devicePixelRatio).round();
    final rightPx = ((globalTopLeft.dx + size.width) * _devicePixelRatio)
        .round();
    final bottomPx = ((globalTopLeft.dy + size.height) * _devicePixelRatio)
        .round();
    final radiusPx = _cornerRadius * _devicePixelRatio;
    if (rightPx > leftPx && bottomPx > topPx) {
      unawaited(
        _controller.syncViewportRect(
          leftPx: leftPx,
          topPx: topPx,
          rightPx: rightPx,
          bottomPx: bottomPx,
          cornerRadiusPx: radiusPx,
        ),
      );
    }
  }
}
