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

/// 根级全屏播放返回键统一拦截函数（供 `KonataRootBackGate` 与独立组件测试回退路径共用）。
Future<bool> _interceptFullscreenMediaBack(WidgetRef ref) async {
  final routeObserver = ref.read(rootRouteObserverProvider);
  if (routeObserver.modalRoutes.any((r) => r.isCurrent)) {
    return false;
  }
  final nav = ref.read(rootNavigatorKeyProvider).currentState;
  if (nav != null &&
      ref
          .read(konataModalLayerRegistryProvider)
          .routesFor(nav)
          .any((r) => r.isCurrent)) {
    return false;
  }

  final videoSession = ref.read(activeVideoSessionProvider);
  if (videoSession.isActive &&
      videoSession.isExpanded &&
      !videoSession.isInPipMode) {
    final vState = ref.read(videoPlaybackProvider(videoSession.request!));
    if (vState.sideSheetOpen) {
      ref
          .read(videoPlaybackProvider(videoSession.request!).notifier)
          .setSideSheetOpen(false);
      return true;
    }
    if (ref.read(playbackPreferencesProvider).videoFloatingMiniEnabled) {
      await ref.read(activeVideoSessionProvider.notifier).collapseToMini();
    } else {
      await ref.read(activeVideoSessionProvider.notifier).closeVideo();
    }
    return true;
  }

  final audioExpanded = ref.read(immersiveAudioExpandedProvider);
  if (audioExpanded) {
    final audioNav = ref.read(_immersiveAudioNavigatorKeyProvider).currentState;
    if (audioNav != null && audioNav.canPop()) {
      await audioNav.maybePop();
      return true;
    }
    if (ref.read(immersivePortraitQueueSheetOpenProvider)) {
      ref.read(immersivePortraitQueueSheetOpenProvider.notifier).state = false;
      return true;
    }
    if (ref.read(playbackPreferencesProvider).audioFloatingMiniEnabled) {
      ref.read(immersiveAudioExpandedProvider.notifier).state = false;
    } else {
      await ref.read(audioPlaybackProvider.notifier).stopAndClose();
    }
    return true;
  }

  return false;
}

class _KonataRootBackGateScope extends InheritedWidget {
  const _KonataRootBackGateScope({required super.child});

  static bool isProvided(BuildContext context) =>
      context.getInheritedWidgetOfExactType<_KonataRootBackGateScope>() != null;

  @override
  bool updateShouldNotify(covariant _KonataRootBackGateScope oldWidget) =>
      false;
}

/// 挂载于 `MaterialApp` 之上的全屏播放系统返回键高优先级拦截门控。
///
/// 在 `_WidgetsAppState` 之前注册 `WidgetsBindingObserver`，确保全屏音视频叠加于子页面之上时，
/// Android 系统返回键优先收起/退出全屏播放层而非静默弹出底层详情页，
/// 并在模态弹窗退场后重新同步 Android 预测返回状态以防被 `Navigator` 覆盖。
class KonataRootBackGate extends ConsumerStatefulWidget {
  /// 创建根级全屏播放返回门控。
  const KonataRootBackGate({super.key, required this.child});

  /// 被包裹的根应用子树（通常为 `MaterialApp`）。
  final Widget child;

  @override
  ConsumerState<KonataRootBackGate> createState() => _KonataRootBackGateState();
}

class _KonataRootBackGateState extends ConsumerState<KonataRootBackGate>
    with WidgetsBindingObserver {
  KonataRootRouteObserver? _boundObserver;
  bool _lastFullscreenActive = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final observer = ref.read(rootRouteObserverProvider);
    if (!identical(_boundObserver, observer)) {
      _boundObserver?.removeStackListener(_handleRootRouteStackChanged);
      _boundObserver = observer;
      observer.addStackListener(_handleRootRouteStackChanged);
    }
  }

  @override
  void dispose() {
    _boundObserver?.removeStackListener(_handleRootRouteStackChanged);
    _boundObserver = null;
    if (KonataAdaptiveTokens.isAndroid && _lastFullscreenActive) {
      unawaited(SystemNavigator.setFrameworkHandlesBack(false));
    }
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  bool _isFullscreenMediaActive() {
    final videoSession = ref.read(activeVideoSessionProvider);
    final videoFullscreen =
        videoSession.isActive &&
        videoSession.isExpanded &&
        !videoSession.isInPipMode;
    return videoFullscreen || ref.read(immersiveAudioExpandedProvider);
  }

  void _handleRootRouteStackChanged() {
    if (!mounted || !KonataAdaptiveTokens.isAndroid) return;
    // Navigator 在弹窗或子页面退场后会重写预测返回开关；若全屏播放仍展开，帧末立即重申接管。
    if (_isFullscreenMediaActive()) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _isFullscreenMediaActive()) {
          unawaited(SystemNavigator.setFrameworkHandlesBack(true));
        }
      });
    }
  }

  void _syncBackRegistration(bool active) {
    if (!KonataAdaptiveTokens.isAndroid) return;
    if (active) {
      unawaited(SystemNavigator.setFrameworkHandlesBack(true));
      return;
    }
    final nav = ref.read(rootNavigatorKeyProvider).currentState;
    if (nav == null || !nav.canPop()) {
      unawaited(SystemNavigator.setFrameworkHandlesBack(false));
    }
  }

  @override
  Future<bool> didPopRoute() {
    if (!mounted) return Future<bool>.value(false);
    return _interceptFullscreenMediaBack(ref);
  }

  @override
  Widget build(BuildContext context) {
    final videoFullscreen = ref.watch(
      activeVideoSessionProvider.select(
        (s) => s.isActive && s.isExpanded && !s.isInPipMode,
      ),
    );
    final audioFullscreen = ref.watch(immersiveAudioExpandedProvider);
    final active = videoFullscreen || audioFullscreen;
    if (active != _lastFullscreenActive) {
      _lastFullscreenActive = active;
      _syncBackRegistration(active);
    }
    return _KonataRootBackGateScope(child: widget.child);
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
  bool _delegatedToRootGate = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final delegated = _KonataRootBackGateScope.isProvided(context);
    if (delegated != _delegatedToRootGate) {
      _delegatedToRootGate = delegated;
    }
    if (!_delegatedToRootGate && widget.handlesSystemBack) {
      _syncAndroidBackRegistration();
    }
  }

  @override
  void didUpdateWidget(covariant _OverlayBackInterceptor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_delegatedToRootGate &&
        oldWidget.handlesSystemBack != widget.handlesSystemBack) {
      _syncAndroidBackRegistration();
    }
  }

  void _syncAndroidBackRegistration() {
    if (!KonataAdaptiveTokens.isAndroid || _delegatedToRootGate) return;
    unawaited(
      SystemNavigator.setFrameworkHandlesBack(widget.handlesSystemBack),
    );
  }

  @override
  void dispose() {
    if (KonataAdaptiveTokens.isAndroid &&
        !_delegatedToRootGate &&
        widget.handlesSystemBack) {
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
    if (_delegatedToRootGate) return Future<bool>.value(false);
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
