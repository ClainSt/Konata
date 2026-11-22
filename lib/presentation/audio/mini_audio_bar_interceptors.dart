part of 'mini_audio_bar.dart';

/// 根视口最顶层轻提示挂载槽位（三端统一在窗口正中央弹出）。
class _ToastOverlaySlot extends StatelessWidget {
  const _ToastOverlaySlot();

  @override
  Widget build(BuildContext context) {
    return const Stack(
      fit: StackFit.expand,
      children: [KonataToastViewport()],
    );
  }
}

/// 不依赖 `Router` 祖先的根级全屏播放层返回键与前后台生命周期拦截器。
class _OverlayBackInterceptor extends StatefulWidget {
  const _OverlayBackInterceptor({
    required this.handlesSystemBack,
    required this.onInterceptBack,
    required this.onBackgrounded,
    required this.onForegrounded,
    required this.child,
  });

  final bool handlesSystemBack;
  final Future<bool> Function() onInterceptBack;
  final Future<void> Function() onBackgrounded;
  final VoidCallback onForegrounded;
  final Widget child;

  @override
  State<_OverlayBackInterceptor> createState() =>
      _OverlayBackInterceptorState();
}

class _OverlayBackInterceptorState extends State<_OverlayBackInterceptor>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.handlesSystemBack) {
      _syncAndroidBackRegistration();
    }
  }

  @override
  void didUpdateWidget(covariant _OverlayBackInterceptor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.handlesSystemBack != widget.handlesSystemBack) {
      _syncAndroidBackRegistration();
    }
  }

  void _syncAndroidBackRegistration() {
    if (!KonataAdaptiveTokens.isAndroid) return;
    unawaited(
      SystemNavigator.setFrameworkHandlesBack(widget.handlesSystemBack),
    );
  }

  @override
  void dispose() {
    if (KonataAdaptiveTokens.isAndroid && widget.handlesSystemBack) {
      unawaited(SystemNavigator.setFrameworkHandlesBack(false));
    }
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      unawaited(widget.onBackgrounded());
    } else if (state == AppLifecycleState.resumed) {
      widget.onForegrounded();
    }
  }

  @override
  Future<bool> didPopRoute() {
    return widget.onInterceptBack();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// 路由栈全局共享导航与悬浮小窗安全避让作用域，静息桌面态零 `MediaQuery` 订阅。
class _AudioContentClearance extends ConsumerWidget {
  const _AudioContentClearance({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final miniKind = ref.watch(activeFloatingMiniPlayerKindProvider);
    final android = KonataAdaptiveTokens.isAndroid;
    if (!android) {
      final desktopClearance = miniKind == FloatingMiniPlayerKind.none
          ? 0.0
          : ref.watch(miniAudioBottomClearanceProvider);
      return KonataBottomClearanceScope(
        bottomClearance: desktopClearance,
        child: child,
      );
    }

    final miniAnchor = miniKind != FloatingMiniPlayerKind.none
        ? ref.watch(floatingMiniWindowAnchorProvider)
        : null;
    final visualState = miniKind != FloatingMiniPlayerKind.none
        ? ref.watch(floatingMiniVisualStateProvider)
        : FloatingMiniVisualState.collapsed;
    final edgeSide = miniKind != FloatingMiniPlayerKind.none
        ? ref.watch(floatingMiniEdgeSideProvider)
        : FloatingMiniEdgeSide.right;
    double? videoAspectRatio;
    if (miniKind == FloatingMiniPlayerKind.video) {
      final videoReq = ref.watch(activeVideoSessionProvider).request;
      if (videoReq != null) {
        videoAspectRatio = ref.watch(
          videoPlaybackProvider(videoReq).select((s) {
            final w = s.probeStats.videoWidth;
            final h = s.probeStats.videoHeight;
            return (w != null && h != null && w > 0 && h > 0) ? w / h : null;
          }),
        );
      }
    }
    final hidden = ref.watch(capsuleNavigationHiddenProvider);
    final subRoutePushed = ref.watch(subRoutePushedProvider);
    final geometry = AdaptiveCapsuleLayout(
      size: MediaQuery.sizeOf(context),
      safe: AdaptiveCapsuleLayout.effectiveSafeInsetsOf(context),
      android: true,
      navigationVisible: !hidden && !subRoutePushed,
      miniKind: miniKind,
      normalizedMiniAnchor: miniAnchor,
      visualState: visualState,
      edgeSide: edgeSide,
      videoAspectRatio: videoAspectRatio,
    );
    final resolvedClearance = geometry.bottomClearance;
    return KonataBottomClearanceScope(
      bottomClearance: resolvedClearance,
      child: ScrollCaptureExclusionInsets(
        bottomInset: resolvedClearance,
        child: child,
      ),
    );
  }
}
