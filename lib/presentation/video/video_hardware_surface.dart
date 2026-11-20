import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
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
/// 跨端同构底层挖空渲染路径：
/// - Android：通过根窗口底层（Underlay）`SurfaceView` + 上层透明 Flutter 画布 `BlendMode.clear` 视口挖空直出；
/// - Windows：优先通过底层 10-bit/HDR 子窗口（`vo=gpu-next`）或非顶置 DirectComposition 10-bit 交换链 +
///   上层透明 Flutter 画布 `BlendMode.clear` 视口挖空直出，老旧驱动回退至 8-bit 兼容共享纹理；
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
  VideoPlaybackController? _cachedVideoController;
  Size? _lastReportedSurfaceSize;
  double? _lastReportedDpr;
  bool _windowsUnderlayVisible = false;

  @override
  void initState() {
    super.initState();
    if (KonataAdaptiveTokens.isAndroid) {
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
    final videoCtrl = _cachedVideoController;
    _cachedVideoController = null;
    if (_windowsUnderlayVisible &&
        KonataAdaptiveTokens.isWindows &&
        videoCtrl != null &&
        videoCtrl.mounted) {
      _windowsUnderlayVisible = false;
      unawaited(
        videoCtrl.syncWindowsUnderlayViewport(
          leftPx: 0,
          topPx: 0,
          rightPx: 0,
          bottomPx: 0,
          visible: false,
        ),
      );
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final snap = ref.watch(
      videoPlaybackProvider(widget.request).select(
        (s) => (
          texId: s.textureId,
          windowsUnderlay: s.windowsUnderlayActive,
          audioOnly: s.audioOnlyMode,
          hasError: s.errorMessage != null,
          aspectMode: s.aspectMode,
          videoW: s.probeStats.videoWidth,
          videoH: s.probeStats.videoHeight,
          work: s.currentWork,
        ),
      ),
    );
    final controller = ref.read(videoPlaybackProvider(widget.request).notifier);
    _cachedVideoController = controller;

    if (snap.hasError) {
      if (_windowsUnderlayVisible && KonataAdaptiveTokens.isWindows) {
        _windowsUnderlayVisible = false;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            unawaited(
              controller.syncWindowsUnderlayViewport(
                leftPx: 0,
                topPx: 0,
                rightPx: 0,
                bottomPx: 0,
                visible: false,
              ),
            );
          }
        });
      }
      return const ColoredBox(color: KonataPlaybackTokens.cinemaPureBlack);
    }

    if (snap.audioOnly) {
      if (_androidUnderlayController != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          unawaited(_androidUnderlayController?.hideViewport());
        });
      }
      if (_windowsUnderlayVisible && KonataAdaptiveTokens.isWindows) {
        _windowsUnderlayVisible = false;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            unawaited(
              controller.syncWindowsUnderlayViewport(
                leftPx: 0,
                topPx: 0,
                rightPx: 0,
                bottomPx: 0,
                visible: false,
              ),
            );
          }
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

    final isUnderlayCutout =
        KonataAdaptiveTokens.isAndroid || snap.windowsUnderlay;
    Widget rawSurface;
    if (KonataAdaptiveTokens.isAndroid) {
      final dpr = MediaQuery.devicePixelRatioOf(context);
      final androidCtrl = _androidUnderlayController!;
      rawSurface = _UnderlayCutout(
        key: const ValueKey('android_underlay_cutout_surface'),
        devicePixelRatio: dpr,
        cornerRadius: widget.cornerRadius,
        identityToken: androidCtrl,
        isDisposedReader: () => androidCtrl.isDisposed,
        onSyncViewportRect:
            ({
              required leftPx,
              required topPx,
              required rightPx,
              required bottomPx,
              required cornerRadiusPx,
            }) => androidCtrl.syncViewportRect(
              leftPx: leftPx,
              topPx: topPx,
              rightPx: rightPx,
              bottomPx: bottomPx,
              cornerRadiusPx: cornerRadiusPx,
            ),
      );
    } else if (snap.windowsUnderlay) {
      _windowsUnderlayVisible = true;
      final dpr = MediaQuery.devicePixelRatioOf(context);
      rawSurface = _UnderlayCutout(
        key: const ValueKey('windows_underlay_cutout_surface'),
        devicePixelRatio: dpr,
        cornerRadius: widget.cornerRadius,
        identityToken: controller,
        isDisposedReader: () => !controller.mounted,
        onSyncViewportRect:
            ({
              required leftPx,
              required topPx,
              required rightPx,
              required bottomPx,
              required cornerRadiusPx,
            }) => controller.syncWindowsUnderlayViewport(
              leftPx: leftPx,
              topPx: topPx,
              rightPx: rightPx,
              bottomPx: bottomPx,
              cornerRadiusPx: cornerRadiusPx,
              visible: true,
            ),
      );
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

    if (isUnderlayCutout && widget.miniPreview) {
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

typedef _UnderlayViewportSyncCallback = Future<void> Function({
  required int leftPx,
  required int topPx,
  required int rightPx,
  required int bottomPx,
  required double cornerRadiusPx,
});

/// 跨端同构底层（Underlay）透明挖空渲染对象（统一驱动 Android `SurfaceView` 与 Windows 10-bit/HDR 底层视口）。
///
/// 在绘制阶段直接以 `BlendMode.clear` 挖空目标矩形（支持圆角），
/// 并严格合并至当前帧结束回调去重下发物理像素几何坐标至原生底层渲染宿主。
class _UnderlayCutout extends LeafRenderObjectWidget {
  const _UnderlayCutout({
    super.key,
    required this.devicePixelRatio,
    required this.cornerRadius,
    required this.identityToken,
    required this.isDisposedReader,
    required this.onSyncViewportRect,
  });

  final double devicePixelRatio;
  final double cornerRadius;
  final Object identityToken;
  final bool Function() isDisposedReader;
  final _UnderlayViewportSyncCallback onSyncViewportRect;

  @override
  RenderObject createRenderObject(BuildContext context) {
    return _RenderUnderlayCutout(
      devicePixelRatio,
      cornerRadius,
      identityToken,
      isDisposedReader,
      onSyncViewportRect,
    );
  }

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderUnderlayCutout renderObject,
  ) {
    renderObject
      ..devicePixelRatio = devicePixelRatio
      ..cornerRadius = cornerRadius
      ..updateTarget(
        identityToken: identityToken,
        isDisposedReader: isDisposedReader,
        onSyncViewportRect: onSyncViewportRect,
      );
  }
}

class _RenderUnderlayCutout extends RenderBox {
  _RenderUnderlayCutout(
    this._devicePixelRatio,
    this._cornerRadius,
    this._identityToken,
    this._isDisposedReader,
    this._onSyncViewportRect,
  );

  static final Paint _clearPaint = Paint()
    ..blendMode = BlendMode.clear
    ..isAntiAlias = true;

  double _devicePixelRatio;
  double _cornerRadius;
  Object _identityToken;
  bool Function() _isDisposedReader;
  _UnderlayViewportSyncCallback _onSyncViewportRect;

  ({int leftPx, int topPx, int rightPx, int bottomPx, double radiusPx})?
  _lastScheduledRect;
  ({int leftPx, int topPx, int rightPx, int bottomPx, double radiusPx})?
  _pendingRect;
  bool _postFrameSyncScheduled = false;

  void updateTarget({
    required Object identityToken,
    required bool Function() isDisposedReader,
    required _UnderlayViewportSyncCallback onSyncViewportRect,
  }) {
    _isDisposedReader = isDisposedReader;
    _onSyncViewportRect = onSyncViewportRect;
    if (identical(_identityToken, identityToken)) return;
    _identityToken = identityToken;
    _lastScheduledRect = null;
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
  void detach() {
    _pendingRect = null;
    _lastScheduledRect = null;
    super.detach();
  }

  bool _isSameRect(
    ({int leftPx, int topPx, int rightPx, int bottomPx, double radiusPx})? a,
    ({int leftPx, int topPx, int rightPx, int bottomPx, double radiusPx}) b,
  ) {
    if (a == null) return false;
    return a.leftPx == b.leftPx &&
        a.topPx == b.topPx &&
        a.rightPx == b.rightPx &&
        a.bottomPx == b.bottomPx &&
        (a.radiusPx - b.radiusPx).abs() <= 0.25;
  }

  void _scheduleFrameSyncedViewportDispatch(
    ({int leftPx, int topPx, int rightPx, int bottomPx, double radiusPx}) next,
  ) {
    if (_isSameRect(_lastScheduledRect, next)) return;
    _lastScheduledRect = next;
    _pendingRect = next;
    if (_postFrameSyncScheduled) return;
    _postFrameSyncScheduled = true;
    // 严禁在 paint() 阶段直接触发异步平台通道调用；统一合并至当前帧结束回调去重下发。
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _postFrameSyncScheduled = false;
      if (!attached || _isDisposedReader()) {
        _pendingRect = null;
        return;
      }
      final rect = _pendingRect;
      _pendingRect = null;
      if (rect == null) return;
      unawaited(
        _onSyncViewportRect(
          leftPx: rect.leftPx,
          topPx: rect.topPx,
          rightPx: rect.rightPx,
          bottomPx: rect.bottomPx,
          cornerRadiusPx: rect.radiusPx,
        ),
      );
    });
  }

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
      _scheduleFrameSyncedViewportDispatch((
        leftPx: leftPx,
        topPx: topPx,
        rightPx: rightPx,
        bottomPx: bottomPx,
        radiusPx: radiusPx,
      ));
    }
  }
}
