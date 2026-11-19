import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/playback/audio_playback_notifier.dart';
import '../../application/playback/playback_preferences_provider.dart';
import '../../application/playback/unified_playback_coordinator.dart';
import '../../application/playback/video_playback_controller.dart';
import '../shell/adaptive_capsule_layout.dart';
import '../shell/android_scroll_capture_bridge.dart';
import '../theme/konata_adaptive_tokens.dart';
import '../theme/konata_playback_tokens.dart';
import '../video/embedded_video_page.dart';
import '../video/video_hardware_surface.dart';
import '../widgets/design_system/konata_toast.dart';
import '../widgets/playback/konata_floating_mini_player.dart';
import 'immersive_audio_page.dart';

export '../shell/adaptive_capsule_layout.dart'
    show FloatingMiniPlayerKind, floatingMiniWindowAnchorProvider;
export '../widgets/playback/konata_floating_mini_player.dart'
    show KonataFloatingMiniPlayer;

final _immersiveAudioNavigatorKeyProvider = Provider<GlobalKey<NavigatorState>>(
  (ref) => GlobalKey<NavigatorState>(debugLabel: 'immersive_audio_nav'),
);

/// 当前是否存在任何活跃音视频会话（仅在为 `true` 时向根 `Overlay` 挂载播放浮层，静息态零图层开销）。
final _hasActivePlaybackOverlayProvider = Provider<bool>((ref) {
  final audioActive = ref.watch(
    audioPlaybackProvider.select((s) => s.isActive),
  );
  final videoActive = ref.watch(
    activeVideoSessionProvider.select((s) => s.isActive),
  );
  final videoFlag = ref.watch(videoPlaybackActiveProvider);
  final audioExpanded = ref.watch(immersiveAudioExpandedProvider);
  return audioActive || videoActive || videoFlag || audioExpanded;
});

/// 当前应展示的可拖拽悬浮小窗内容形态 Provider。
final activeFloatingMiniPlayerKindProvider = Provider<FloatingMiniPlayerKind>((
  ref,
) {
  final audioActive = ref.watch(
    audioPlaybackProvider.select((s) => s.isActive),
  );
  final videoSession = ref.watch(activeVideoSessionProvider);
  final videoActiveFlag = ref.watch(videoPlaybackActiveProvider);
  final audioExpanded = ref.watch(immersiveAudioExpandedProvider);
  if (videoSession.isMinimized && videoSession.request != null) {
    return FloatingMiniPlayerKind.video;
  }
  if (audioActive &&
      !videoActiveFlag &&
      !videoSession.isActive &&
      !audioExpanded) {
    return FloatingMiniPlayerKind.audio;
  }
  return FloatingMiniPlayerKind.none;
});

/// 当可拖拽悬浮小窗停靠于视口下半区时，供未包裹作用域的列表或桌面壳层读取的基准底部避让高度。
final miniAudioBottomClearanceProvider = Provider<double>((ref) {
  final kind = ref.watch(activeFloatingMiniPlayerKindProvider);
  if (kind == FloatingMiniPlayerKind.none) {
    return 0.0;
  }
  final anchor = ref.watch(floatingMiniWindowAnchorProvider);
  if (anchor != null &&
      anchor.dy < KonataPlaybackTokens.floatingMiniBottomZoneThresholdRatio) {
    return 0.0;
  }
  final windowHeight = kind == FloatingMiniPlayerKind.video
      ? KonataPlaybackTokens.floatingMiniVideoHeight
      : KonataPlaybackTokens.floatingMiniAudioTotalHeight;
  return windowHeight +
      KonataPlaybackTokens.floatingMiniEdgeMargin +
      KonataPlaybackTokens.floatingMiniBottomClearanceGap;
});

/// 由外壳层向页面子树透传主导航胶囊与悬浮小窗统一底部避让高度的作用域。
class KonataBottomClearanceScope extends InheritedWidget {
  /// 创建底部安全避让高度作用域。
  const KonataBottomClearanceScope({
    super.key,
    required this.bottomClearance,
    required super.child,
  });

  /// 当前生效的底部防遮挡避让高度。
  final double bottomClearance;

  /// 读取祖先节点透传的底部避让高度（未包覆时返回 `null`）。
  static double? maybeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<KonataBottomClearanceScope>()
        ?.bottomClearance;
  }

  /// 优先读取外壳层按真实视口计算的底部避让高度，同时订阅全局 Provider 以响应路由栈新页面。
  static double resolve(BuildContext context, WidgetRef ref) {
    final watched = ref.watch(miniAudioBottomClearanceProvider);
    return maybeOf(context) ?? watched;
  }

  @override
  bool updateShouldNotify(KonataBottomClearanceScope oldWidget) {
    return (bottomClearance - oldWidget.bottomClearance).abs() > 0.25;
  }
}

/// 挂载在 `MaterialApp.builder` 的全端音视频播放与轻提示按需叠加宿主。
///
/// 性能与层级架构不变量：
/// - 静息态（无活跃音视频且无活跃 Toast）向根 `NavigatorState.overlay` 注入 **0 个额外 `OverlayEntry`**，
///   消除嵌套双层 `Overlay` 与常驻空闲图层的布局/光栅化开销；
/// - 音视频会话激活期间，将悬浮小窗 `_floatingMiniEntry` 与全屏播放层 `_fullscreenPlayerEntry` 挂载于同一
///   `NavigatorState.overlay`，严格置于所有 `PageRoute` 之上、所有模态弹窗（`PopupRoute` / `ModalBarrier`）之下，
///   既保证弹窗遮罩 100% 遮盖与触控阻断，又保证 `GlobalObjectKey` 跨展开/收起零会话重建。
class MiniAudioOverlayHost extends ConsumerStatefulWidget {
  /// 创建全局音视频与轻提示叠加宿主。
  const MiniAudioOverlayHost({super.key, required this.child});

  /// 被包裹的根 `Navigator` 子树。
  final Widget child;

  @override
  ConsumerState<MiniAudioOverlayHost> createState() =>
      _MiniAudioOverlayHostState();
}

class _MiniAudioOverlayHostState extends ConsumerState<MiniAudioOverlayHost> {
  OverlayEntry? _floatingMiniEntry;
  OverlayEntry? _fullscreenPlayerEntry;
  OverlayEntry? _toastEntry;

  NavigatorState? _attachedNavigator;
  KonataRootRouteObserver? _boundObserver;
  GlobalKey<NavigatorState>? _cachedNavKey;
  Timer? _toastDetachTimer;
  bool _mediaEntriesInserted = false;
  bool _toastEntryInserted = false;
  bool _wantMediaEntries = false;
  bool _wantToastEntry = false;
  bool _useInlineFallback = false;
  bool _syncScheduled = false;
  bool _isElementActive = true;

  @override
  void initState() {
    super.initState();
    KonataToastController.registerHost();
    KonataToastController.activeToast.addListener(_handleActiveToastChanged);
    _wantToastEntry = KonataToastController.activeToast.value != null;
    KonataModalLayerRegistry.instance.addListener(_handleRouteOrModalChanged);
    if (_wantToastEntry) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _syncOverlayEntries();
      });
    }
  }

  @override
  void activate() {
    super.activate();
    _isElementActive = true;
  }

  @override
  void deactivate() {
    _isElementActive = false;
    super.deactivate();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _cachedNavKey = ref.read(rootNavigatorKeyProvider);
    final observer = ref.read(rootRouteObserverProvider);
    if (!identical(_boundObserver, observer)) {
      _boundObserver?.removeStackListener(_handleRouteOrModalChanged);
      _boundObserver = observer;
      observer.addStackListener(_handleRouteOrModalChanged);
    }
  }

  @override
  void didUpdateWidget(covariant MiniAudioOverlayHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.child != widget.child &&
        (_mediaEntriesInserted || _toastEntryInserted || _wantMediaEntries || _wantToastEntry)) {
      _scheduleOverlaySync();
    }
  }

  @override
  void dispose() {
    _toastDetachTimer?.cancel();
    _boundObserver?.removeStackListener(_handleRouteOrModalChanged);
    KonataModalLayerRegistry.instance.removeListener(_handleRouteOrModalChanged);
    KonataToastController.activeToast.removeListener(_handleActiveToastChanged);
    KonataToastController.unregisterHost();
    _removeAllEntries();
    _floatingMiniEntry?.dispose();
    _fullscreenPlayerEntry?.dispose();
    _toastEntry?.dispose();
    super.dispose();
  }

  void _handleActiveToastChanged() {
    _toastDetachTimer?.cancel();
    final hasToast = KonataToastController.activeToast.value != null;
    if (hasToast) {
      _wantToastEntry = true;
      _syncOrSchedule();
    } else if (_toastEntryInserted) {
      // 预留退场淡出动画完成后再从 Overlay 移除，静息态回到 0 额外图层
      _toastDetachTimer = Timer(
        KonataAdaptiveTokens.toastExitDuration + const Duration(milliseconds: 40),
        () {
          if (!mounted) return;
          if (KonataToastController.activeToast.value == null) {
            _wantToastEntry = false;
            _syncOrSchedule();
          }
        },
      );
    } else {
      _wantToastEntry = false;
    }
  }

  void _handleRouteOrModalChanged() {
    if (!_mediaEntriesInserted &&
        !_toastEntryInserted &&
        !_wantMediaEntries &&
        !_wantToastEntry) {
      return;
    }
    _scheduleOverlaySync();
  }

  void _updateWantedMediaEntries(bool want) {
    if (_wantMediaEntries == want) return;
    _wantMediaEntries = want;
    _syncOrSchedule();
  }

  void _syncOrSchedule() {
    if (!mounted || !_isElementActive) return;
    final phase = SchedulerBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _isElementActive) {
          _syncOverlayEntries();
        }
      });
    } else {
      _scheduleOverlaySync();
    }
  }

  void _scheduleOverlaySync() {
    if (!mounted || !_isElementActive || _syncScheduled) return;
    _syncScheduled = true;
    scheduleMicrotask(() {
      _syncScheduled = false;
      if (!mounted || !_isElementActive) return;
      _syncOverlayEntries();
    });
  }

  void _ensureEntriesAllocated() {
    _floatingMiniEntry ??= OverlayEntry(
      maintainState: true,
      builder: (_) => const _FloatingMiniOverlaySlot(),
    );
    _fullscreenPlayerEntry ??= OverlayEntry(
      maintainState: true,
      builder: (_) => const _FullscreenPlayerOverlaySlot(),
    );
    _toastEntry ??= OverlayEntry(
      maintainState: true,
      builder: (_) => const _ToastOverlaySlot(),
    );
  }

  void _removeMediaEntries() {
    if (_mediaEntriesInserted) {
      try {
        _floatingMiniEntry?.remove();
      } catch (_) {}
      try {
        _fullscreenPlayerEntry?.remove();
      } catch (_) {}
      _mediaEntriesInserted = false;
    }
  }

  void _removeToastEntry() {
    if (_toastEntryInserted) {
      try {
        _toastEntry?.remove();
      } catch (_) {}
      _toastEntryInserted = false;
    }
  }

  void _removeAllEntries() {
    _removeMediaEntries();
    _removeToastEntry();
    _attachedNavigator = null;
  }

  NavigatorState? _discoverDescendantNavigator() {
    final fromObserver = _boundObserver?.navigator;
    if (fromObserver != null && fromObserver.mounted) {
      return fromObserver;
    }
    final fromKey = _cachedNavKey?.currentState;
    if (fromKey != null && fromKey.mounted) {
      return fromKey;
    }
    NavigatorState? found;
    void visit(Element element) {
      if (found != null) return;
      if (element is StatefulElement && element.state is NavigatorState) {
        found = element.state as NavigatorState;
        return;
      }
      element.visitChildElements(visit);
    }

    if (mounted && _isElementActive) {
      context.visitChildElements(visit);
    }
    return found;
  }

  void _syncOverlayEntries() {
    if (!mounted || !_isElementActive) return;
    if (!_wantMediaEntries && !_wantToastEntry) {
      if (_mediaEntriesInserted || _toastEntryInserted) {
        _removeAllEntries();
      }
      if (_useInlineFallback) {
        setState(() => _useInlineFallback = false);
      }
      return;
    }

    final nav = _discoverDescendantNavigator();
    final overlay = nav?.overlay;
    if (nav == null || overlay == null || !overlay.mounted) {
      if (!_useInlineFallback) {
        setState(() => _useInlineFallback = true);
      }
      return;
    }

    if (_useInlineFallback) {
      setState(() => _useInlineFallback = false);
    }
    if (_attachedNavigator != null && !identical(_attachedNavigator, nav)) {
      _removeAllEntries();
    }
    _attachedNavigator = nav;
    _ensureEntriesAllocated();

    if (!_wantMediaEntries && _mediaEntriesInserted) {
      _removeMediaEntries();
    }
    if (!_wantToastEntry && _toastEntryInserted) {
      _removeToastEntry();
    }

    final miniEntry = _floatingMiniEntry!;
    final fullEntry = _fullscreenPlayerEntry!;
    final toastEntry = _toastEntry!;

    final observer = _boundObserver;
    final observerAttached =
        observer != null && identical(observer.navigator, nav);
    final registryModals = KonataModalLayerRegistry.instance.routesFor(nav);

    if (observerAttached) {
      final ordered = <OverlayEntry>[];
      void addUnique(OverlayEntry entry) {
        if (!ordered.contains(entry)) {
          ordered.add(entry);
        }
      }

      for (final r in observer.pageRoutes) {
        if (r.navigator == nav) {
          for (final e in r.overlayEntries) {
            addUnique(e);
          }
        }
      }
      if (_wantMediaEntries) {
        addUnique(miniEntry);
        addUnique(fullEntry);
      }
      for (final r in observer.modalRoutes) {
        if (r.navigator == nav) {
          for (final e in r.overlayEntries) {
            addUnique(e);
          }
        }
      }
      for (final r in registryModals) {
        if (r.navigator == nav) {
          for (final e in r.overlayEntries) {
            addUnique(e);
          }
        }
      }
      if (_wantToastEntry) {
        addUnique(toastEntry);
      }
      overlay.rearrange(ordered);
      _mediaEntriesInserted = _wantMediaEntries;
      _toastEntryInserted = _wantToastEntry;
      return;
    }

    if (_wantMediaEntries && !_mediaEntriesInserted) {
      overlay.insertAll([miniEntry, fullEntry]);
      _mediaEntriesInserted = true;
    }
    if (_wantToastEntry && !_toastEntryInserted) {
      overlay.insert(toastEntry);
      _toastEntryInserted = true;
    }

    if (_wantMediaEntries && registryModals.isNotEmpty) {
      final managed = <OverlayEntry>[miniEntry, fullEntry];
      for (final r in registryModals) {
        if (r.navigator == nav) {
          for (final e in r.overlayEntries) {
            if (!managed.contains(e)) {
              managed.add(e);
            }
          }
        }
      }
      if (_wantToastEntry) {
        managed.add(toastEntry);
      }
      overlay.rearrange(managed, below: miniEntry);
    }
  }

  @override
  Widget build(BuildContext context) {
    final wantMedia = ref.watch(_hasActivePlaybackOverlayProvider);
    if (wantMedia != _wantMediaEntries) {
      _updateWantedMediaEntries(wantMedia);
    }

    final content = _PlaybackSessionCoordinator(
      child: _AudioContentClearance(child: widget.child),
    );
    if (!_useInlineFallback) {
      return content;
    }
    return Overlay(
      initialEntries: [
        OverlayEntry(
          maintainState: true,
          builder: (_) => Stack(
            fit: StackFit.expand,
            children: [
              content,
              if (_wantMediaEntries) const _FloatingMiniOverlaySlot(),
              if (_wantMediaEntries) const _FullscreenPlayerOverlaySlot(),
              if (_wantToastEntry) const _ToastOverlaySlot(),
            ],
          ),
        ),
      ],
    );
  }
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
      final desktopClearance = ref.watch(miniAudioBottomClearanceProvider);
      return KonataBottomClearanceScope(
        bottomClearance: desktopClearance,
        child: child,
      );
    }

    final miniAnchor = ref.watch(floatingMiniWindowAnchorProvider);
    final hidden = ref.watch(capsuleNavigationHiddenProvider);
    final subRoutePushed = ref.watch(subRoutePushedProvider);
    final geometry = AdaptiveCapsuleLayout(
      size: MediaQuery.sizeOf(context),
      safe: AdaptiveCapsuleLayout.effectiveSafeInsetsOf(context),
      android: true,
      navigationVisible: !hidden && !subRoutePushed,
      miniKind: miniKind,
      normalizedMiniAnchor: miniAnchor,
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

/// 全局音频错误捕获、视频会话保活、Android 画中画同步与系统返回拦截协调器。
class _PlaybackSessionCoordinator extends ConsumerWidget {
  const _PlaybackSessionCoordinator({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (KonataAdaptiveTokens.isAndroid) {
      ref.watch(androidPipAutoSyncProvider);
    }

    ref.listen<String?>(
      audioPlaybackProvider.select((s) => s.errorMessage),
      (prev, next) {
        final msg = next?.trim() ?? '';
        if (msg.isNotEmpty && msg != (prev?.trim() ?? '')) {
          KonataToastController.show(msg, isError: true);
          Future<void>.microtask(() {
            if (context.mounted) {
              ref.read(audioPlaybackProvider.notifier).dismissError();
            }
          });
        }
      },
    );

    final videoSession = ref.watch(activeVideoSessionProvider);
    final videoReq = videoSession.request;
    // 保活当前活跃视频控制器，确保在全屏与悬浮小窗切换时绝不触发 autoDispose 重建会话
    if (videoReq != null) {
      ref.watch(videoPlaybackProvider(videoReq).select((s) => s.isClosing));
    }

    final audioExpanded = ref.watch(immersiveAudioExpandedProvider);
    final subRoutePushed = ref.watch(subRoutePushedProvider);
    final immersiveAudioNavKey = ref.watch(_immersiveAudioNavigatorKeyProvider);
    final shouldHandleSystemBack =
        (videoSession.isActive &&
            videoSession.isExpanded &&
            !videoSession.isInPipMode) ||
        audioExpanded ||
        subRoutePushed;

    return _OverlayBackInterceptor(
      handlesSystemBack: shouldHandleSystemBack,
      onBackgrounded: () =>
          ref.read(activeVideoSessionProvider.notifier).handleAppBackgrounded(),
      onForegrounded: () =>
          ref.read(activeVideoSessionProvider.notifier).handleAppForegrounded(),
      onInterceptBack: () async {
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
          await ref.read(activeVideoSessionProvider.notifier).collapseToMini();
          return true;
        }
        if (audioExpanded) {
          final audioNav = immersiveAudioNavKey.currentState;
          if (audioNav != null && audioNav.canPop()) {
            await audioNav.maybePop();
            return true;
          }
          if (ref.read(immersivePortraitQueueSheetOpenProvider)) {
            ref.read(immersivePortraitQueueSheetOpenProvider.notifier).state =
                false;
            return true;
          }
          ref.read(immersiveAudioExpandedProvider.notifier).state = false;
          return true;
        }
        return false;
      },
      child: child,
    );
  }
}

/// 位于主页面壳层之上、根路由模态弹窗遮罩之下的可拖拽音视频悬浮小窗挂载槽位。
class _FloatingMiniOverlaySlot extends ConsumerWidget {
  const _FloatingMiniOverlaySlot();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final miniKind = ref.watch(activeFloatingMiniPlayerKindProvider);
    if (miniKind == FloatingMiniPlayerKind.none) {
      return const SizedBox.shrink();
    }
    final videoSession = ref.watch(activeVideoSessionProvider);
    final videoReq = videoSession.request;
    final miniAnchor = ref.watch(floatingMiniWindowAnchorProvider);
    final hidden = ref.watch(capsuleNavigationHiddenProvider);
    final subRoutePushed = ref.watch(subRoutePushedProvider);
    final layout = AdaptiveCapsuleLayout(
      size: MediaQuery.sizeOf(context),
      safe: AdaptiveCapsuleLayout.effectiveSafeInsetsOf(context),
      android: KonataAdaptiveTokens.isAndroid,
      navigationVisible: !hidden && !subRoutePushed,
      desktopTopBarVisible: !subRoutePushed,
      miniKind: miniKind,
      normalizedMiniAnchor: miniAnchor,
    );

    final sharedSurface =
        (miniKind == FloatingMiniPlayerKind.video && videoReq != null)
        ? KonataHardwareVideoSurface(
            key: GlobalObjectKey(videoReq),
            request: videoReq,
            miniPreview: true,
            cornerRadius: KonataPlaybackTokens.floatingMiniRadius,
          )
        : null;

    return Stack(
      fit: StackFit.expand,
      children: [
        KonataFloatingMiniPlayer(
          kind: miniKind,
          layout: layout,
          videoRequest: videoReq,
          sharedVideoSurface: sharedSurface,
        ),
      ],
    );
  }
}

/// 全屏沉浸音频页与全屏内置视频页挂载槽位（与悬浮小窗共享同一 `Overlay`，支持 `GlobalObjectKey` 无损迁移）。
class _FullscreenPlayerOverlaySlot extends ConsumerWidget {
  const _FullscreenPlayerOverlaySlot();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final videoSession = ref.watch(activeVideoSessionProvider);
    final videoReq = videoSession.request;
    final audioExpanded = ref.watch(immersiveAudioExpandedProvider);

    final showImmersiveAudio = audioExpanded && !videoSession.isActive;
    final showExpandedVideo =
        videoSession.isActive && videoSession.isExpanded && videoReq != null;

    if (!showImmersiveAudio && !showExpandedVideo) {
      return const SizedBox.shrink();
    }

    final immersiveAudioNavKey = ref.watch(_immersiveAudioNavigatorKeyProvider);
    final originRect = konataFloatingMiniWindowRectNotifier.value;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (showImmersiveAudio)
          _SpringViewportMorphFrame(
            key: const ValueKey('spring_morph_audio_fullscreen'),
            originRect: originRect,
            allowClipRadius: true,
            child: HeroControllerScope.none(
              child: Navigator(
                key: immersiveAudioNavKey,
                onGenerateRoute: (_) => PageRouteBuilder<void>(
                  pageBuilder: (_, _, _) => const ImmersiveAudioPage(
                    key: ValueKey('immersive_audio'),
                  ),
                  transitionDuration: Duration.zero,
                  reverseTransitionDuration: Duration.zero,
                ),
              ),
            ),
          ),
        if (showExpandedVideo)
          _SpringViewportMorphFrame(
            key: ValueKey('spring_morph_video_${videoReq.hashCode}'),
            originRect: videoSession.isInPipMode ? null : originRect,
            allowClipRadius: !KonataAdaptiveTokens.isAndroid,
            child: EmbeddedVideoPage(
              key: ValueKey('global_embedded_video_${videoReq.hashCode}'),
              request: videoReq,
              sharedVideoSurface: KonataHardwareVideoSurface(
                key: GlobalObjectKey(videoReq),
                request: videoReq,
                miniPreview: false,
              ),
              inPipMode: videoSession.isInPipMode,
              onCollapseToMini: () => unawaited(
                ref.read(activeVideoSessionProvider.notifier).collapseToMini(),
              ),
              onCloseSession: () =>
                  ref.read(activeVideoSessionProvider.notifier).closeVideo(),
            ),
          ),
      ],
    );
  }
}

/// 悬浮小窗与全屏舞台之间的临界阻尼 `SpringSimulation` 视口矩形与圆角连续形变容器。
///
/// 过渡到达终态后立即停钟并直通返回 `child`（零闲置 Ticker、零稳态包装开销）。
class _SpringViewportMorphFrame extends StatefulWidget {
  const _SpringViewportMorphFrame({
    super.key,
    required this.originRect,
    required this.allowClipRadius,
    required this.child,
  });

  final Rect? originRect;
  final bool allowClipRadius;
  final Widget child;

  @override
  State<_SpringViewportMorphFrame> createState() =>
      _SpringViewportMorphFrameState();
}

class _SpringViewportMorphFrameState extends State<_SpringViewportMorphFrame>
    with SingleTickerProviderStateMixin {
  AnimationController? _controller;
  Rect? _startRect;
  bool _morphing = false;

  @override
  void initState() {
    super.initState();
    _startRect = widget.originRect;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_controller != null || _startRect == null) return;
    final disableAnimations = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (disableAnimations) {
      _startRect = null;
      return;
    }
    final ctrl = AnimationController.unbounded(vsync: this)
      ..addStatusListener(_onStatusChanged);
    _controller = ctrl;
    _morphing = true;
    final sim = SpringSimulation(
      KonataPlaybackTokens.stageMorphSpring,
      0.0,
      1.0,
      0.0,
      tolerance: const Tolerance(distance: 1e-3, velocity: 1e-3),
    );
    ctrl.animateWith(sim);
  }

  void _onStatusChanged(AnimationStatus status) {
    if (status == AnimationStatus.completed ||
        status == AnimationStatus.dismissed) {
      _controller?.stop();
      if (mounted && _morphing) {
        setState(() {
          _morphing = false;
          _startRect = null;
        });
      }
    }
  }

  @override
  void dispose() {
    _controller
      ?..removeStatusListener(_onStatusChanged)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = _controller;
    final startRect = _startRect;
    if (!_morphing || ctrl == null || startRect == null) {
      return widget.child;
    }
    final fullSize = MediaQuery.sizeOf(context);
    if (fullSize.width <= 0 || fullSize.height <= 0) {
      return widget.child;
    }
    final endRect = Offset.zero & fullSize;
    return AnimatedBuilder(
      animation: ctrl,
      child: widget.child,
      builder: (_, child) {
        final t = ctrl.value.clamp(0.0, 1.0);
        final rect = Rect.lerp(startRect, endRect, t) ?? endRect;
        final sx = (rect.width / endRect.width).clamp(0.05, 1.0);
        final sy = (rect.height / endRect.height).clamp(0.05, 1.0);
        final radius =
            lerpDouble(KonataPlaybackTokens.floatingMiniRadius, 0.0, t) ?? 0.0;
        final matrix = Matrix4.identity()
          ..translateByDouble(rect.left, rect.top, 0.0, 1.0)
          ..scaleByDouble(sx, sy, 1.0, 1.0);
        // 保持子页面按全屏终态尺寸一次布局，仅由 GPU 合成矩阵连续缩放平移，彻底消除形变帧溢出与逐帧重排。
        final clipped = (widget.allowClipRadius && radius > 0.5)
            ? ClipRRect(
                borderRadius: BorderRadius.circular(radius / sx),
                child: child,
              )
            : child!;
        return Transform(
          alignment: Alignment.topLeft,
          transform: matrix,
          child: clipped,
        );
      },
    );
  }
}

/// 根视口最顶层轻提示挂载槽位（固定于安全区上方并自动避让底部导航胶囊与悬浮小窗）。
class _ToastOverlaySlot extends ConsumerWidget {
  const _ToastOverlaySlot();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final videoSession = ref.watch(activeVideoSessionProvider);
    final audioExpanded = ref.watch(immersiveAudioExpandedProvider);
    final fullscreenCovering =
        audioExpanded || (videoSession.isActive && videoSession.isExpanded);

    var baseBottomClearance = 0.0;
    if (!fullscreenCovering && KonataAdaptiveTokens.isAndroid) {
      final hidden = ref.watch(capsuleNavigationHiddenProvider);
      final subRoutePushed = ref.watch(subRoutePushedProvider);
      final navLayout = AdaptiveCapsuleLayout(
        size: MediaQuery.sizeOf(context),
        safe: AdaptiveCapsuleLayout.effectiveSafeInsetsOf(context),
        android: true,
        navigationVisible: !hidden && !subRoutePushed,
      );
      baseBottomClearance = navLayout.bottomClearance;
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        KonataToastViewport(baseBottomClearance: baseBottomClearance),
      ],
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
    _syncAndroidBackRegistration();
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
