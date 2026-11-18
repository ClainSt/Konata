import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/playback/audio_playback_notifier.dart';
import '../../application/playback/video_playback_controller.dart';
import '../../domain/playback/video_aspect_mode.dart';
import '../../infrastructure/players/android/android_video_surface_controller.dart';
import '../theme/konata_adaptive_tokens.dart';
import '../theme/konata_playback_tokens.dart';
import '../widgets/playback/konata_cached_artwork_backdrop.dart';

/// 硬件视频渲染表面组件（视频模式关闭背景模糊直出硬件纹理；纯音频模式切换静态缓存三层封面背景）。
///
/// 通过同一 `GlobalKey` 可在全屏舞台与底部播放胶囊圆角预览间平滑迁移，不重建底层解码会话或 `PlatformView`。
class KonataHardwareVideoSurface extends ConsumerStatefulWidget {
  /// 创建硬件视频渲染表面。
  const KonataHardwareVideoSurface({
    super.key,
    required this.request,
    this.miniPreview = false,
  });

  /// 关联的视频播放请求键。
  final VideoLaunchRequest request;

  /// 是否处于迷你胶囊圆角小窗预览态。
  final bool miniPreview;

  @override
  ConsumerState<KonataHardwareVideoSurface> createState() =>
      _KonataHardwareVideoSurfaceState();
}

class _KonataHardwareVideoSurfaceState
    extends ConsumerState<KonataHardwareVideoSurface> {
  final GlobalKey _androidSurfaceViewKey = GlobalKey(
    debugLabel: 'konata_android_surface_view',
  );
  Size? _lastReportedSurfaceSize;
  double? _lastReportedDpr;

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
      // 测试绑定下避免真实 PlatformView 通道阻塞，真机直接挂载硬件 SurfaceView
      final isWidgetTest = WidgetsBinding.instance.runtimeType
          .toString()
          .contains('TestWidgetsFlutterBinding');
      if (isWidgetTest) {
        rawSurface = const ColoredBox(
          key: ValueKey('android_hardware_surface_placeholder'),
          color: KonataPlaybackTokens.cinemaPureBlack,
        );
      } else {
        rawSurface = PlatformViewLink(
          key: _androidSurfaceViewKey,
          viewType: AndroidVideoSurfaceController.viewType,
          surfaceFactory: (context, platformController) => AndroidViewSurface(
            controller: platformController as AndroidViewController,
            gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
            hitTestBehavior: PlatformViewHitTestBehavior.transparent,
          ),
          onCreatePlatformView: (params) {
            // 在原生视图创建完成前预先注册通道与控制器，防止丢失首帧表面尺寸变更回调
            controller.attachAndroidSurface(
              AndroidVideoSurfaceController(params.id),
            );
            return PlatformViewsService.initExpensiveAndroidView(
                id: params.id,
                viewType: AndroidVideoSurfaceController.viewType,
                layoutDirection: TextDirection.ltr,
              )
              ..addOnPlatformViewCreatedListener(params.onPlatformViewCreated)
              ..create();
          },
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

    return ColoredBox(
      color: KonataPlaybackTokens.cinemaPureBlack,
      child: _wrapAspect(
        rawSurface,
        snap.aspectMode,
        snap.videoW ?? 0,
        snap.videoH ?? 0,
      ),
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
