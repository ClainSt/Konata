import 'dart:async';

import 'package:flutter/material.dart';
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
import '../widgets/playback/konata_stage_morph_frame.dart';
import 'immersive_audio_page.dart';

export '../shell/adaptive_capsule_layout.dart'
    show FloatingMiniPlayerKind, floatingMiniWindowAnchorProvider;
export '../widgets/playback/konata_floating_mini_player.dart'
    show KonataFloatingMiniPlayer;
export '../widgets/playback/konata_stage_morph_frame.dart'
    show
        KonataStageMorphFrame,
        KonataStageMorphFrameState,
        captureStageMorphOriginRect,
        stageMorphOriginRectProvider,
        stageMorphReleaseVelocityProvider,
        stageMorphReverseVideoActiveProvider;

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

  /// 优先读取外壳层按真实视口计算的底部避让高度，未包裹作用域时再订阅全局 Provider。
  static double resolve(BuildContext context, WidgetRef ref) {
    final scoped = maybeOf(context);
    if (scoped != null) {
      return scoped;
    }
    return ref.watch(miniAudioBottomClearanceProvider);
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
  KonataToastController? _toastController;
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
    final toastCtrl = ref.read(konataToastControllerProvider);
    _toastController = toastCtrl;
    toastCtrl.registerHost();
    toastCtrl.activeToast.addListener(_handleActiveToastChanged);
    _wantToastEntry = toastCtrl.activeToast.value != null;
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
    final toastCtrl = _toastController;
    _toastController = null;
    if (toastCtrl != null) {
      toastCtrl.activeToast.removeListener(_handleActiveToastChanged);
      toastCtrl.unregisterHost();
    }
    _removeAllEntries();
    _floatingMiniEntry?.dispose();
    _fullscreenPlayerEntry?.dispose();
    _toastEntry?.dispose();
    super.dispose();
  }

  void _handleActiveToastChanged() {
    _toastDetachTimer?.cancel();
    final toastCtrl = _toastController;
    final hasToast = toastCtrl?.activeToast.value != null;
    if (hasToast) {
      _wantToastEntry = true;
      _syncOrSchedule();
    } else if (_toastEntryInserted) {
      // 预留退场淡出动画完成后再从 Overlay 移除，静息态回到 0 额外图层
      _toastDetachTimer = Timer(
        KonataAdaptiveTokens.toastExitDuration + const Duration(milliseconds: 40),
        () {
          if (!mounted) return;
          if (_toastController?.activeToast.value == null) {
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
      _floatingMiniEntry?.remove();
      _fullscreenPlayerEntry?.remove();
      _mediaEntriesInserted = false;
    }
  }

  void _removeToastEntry() {
    if (_toastEntryInserted) {
      _toastEntry?.remove();
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

    final miniAnchor = miniKind != FloatingMiniPlayerKind.none
        ? ref.watch(floatingMiniWindowAnchorProvider)
        : null;
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
    final videoSession = ref.watch(activeVideoSessionProvider);
    final videoReq = videoSession.request;
    if (KonataAdaptiveTokens.isAndroid &&
        (videoReq != null || videoSession.isInPipMode)) {
      ref.watch(androidPipAutoSyncProvider);
    }

    ref.listen<String?>(
      audioPlaybackProvider.select((s) => s.errorMessage),
      (prev, next) {
        final msg = next?.trim() ?? '';
        if (msg.isNotEmpty && msg != (prev?.trim() ?? '')) {
          ref.read(konataToastControllerProvider).show(msg, isError: true);
          Future<void>.microtask(() {
            if (context.mounted) {
              ref.read(audioPlaybackProvider.notifier).dismissError();
            }
          });
        }
      },
    );

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
    // 视频全屏舞台正在执行反向弹簧收起过渡时，暂由全屏槽位独占 GlobalObjectKey，
    // 待反向弹簧到达终态当帧原子移交，确保零帧跳变且零会话重建。
    if (miniKind == FloatingMiniPlayerKind.video &&
        ref.watch(stageMorphReverseVideoActiveProvider)) {
      return const SizedBox.shrink();
    }
    final videoSession = ref.watch(activeVideoSessionProvider);
    final videoReq = videoSession.request;
    final miniAnchor = miniKind != FloatingMiniPlayerKind.none
        ? ref.watch(floatingMiniWindowAnchorProvider)
        : null;
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

/// 全屏沉浸音频页与全屏内置视频页挂载槽位（双向 `SpringSimulation` 形变过渡 + `GlobalObjectKey` 原子无损移交）。
class _FullscreenPlayerOverlaySlot extends ConsumerStatefulWidget {
  const _FullscreenPlayerOverlaySlot();

  @override
  ConsumerState<_FullscreenPlayerOverlaySlot> createState() =>
      _FullscreenPlayerOverlaySlotState();
}

class _FullscreenPlayerOverlaySlotState
    extends ConsumerState<_FullscreenPlayerOverlaySlot> {
  ProviderSubscription<ActiveVideoSessionState>? _videoSub;
  ProviderSubscription<bool>? _audioSub;

  bool _collapsingAudio = false;
  Rect? _collapsingAudioTargetRect;
  double _collapsingAudioVelocityPx = 0.0;

  VideoLaunchRequest? _collapsingVideoReq;
  Rect? _collapsingVideoTargetRect;
  double _collapsingVideoVelocityPx = 0.0;

  @override
  void initState() {
    super.initState();
    _videoSub = ref.listenManual<ActiveVideoSessionState>(
      activeVideoSessionProvider,
      (prev, next) {
        if (!mounted) return;
        final wasExpanded =
            prev != null &&
            prev.isActive &&
            prev.isExpanded &&
            prev.request != null &&
            !prev.isInPipMode;
        final nowMinimized =
            next.isActive &&
            !next.isExpanded &&
            !next.isInPipMode &&
            next.request != null;
        final disableAnim = MediaQuery.maybeDisableAnimationsOf(context) ?? false;

        if (wasExpanded && nowMinimized && !disableAnim) {
          final targetRect = _computeTargetMiniRect(FloatingMiniPlayerKind.video);
          final releaseVel = ref.read(stageMorphReleaseVelocityProvider);
          ref.read(stageMorphReleaseVelocityProvider.notifier).state = 0.0;
          ref.read(stageMorphReverseVideoActiveProvider.notifier).state = true;
          setState(() {
            _collapsingVideoReq = next.request;
            _collapsingVideoTargetRect = targetRect;
            _collapsingVideoVelocityPx = releaseVel;
          });
        } else if (next.isExpanded || !next.isActive || next.isInPipMode) {
          if (_collapsingVideoReq != null ||
              ref.read(stageMorphReverseVideoActiveProvider)) {
            ref.read(stageMorphReverseVideoActiveProvider.notifier).state = false;
            setState(() {
              _collapsingVideoReq = null;
              _collapsingVideoTargetRect = null;
              _collapsingVideoVelocityPx = 0.0;
            });
          }
        }
      },
    );

    _audioSub = ref.listenManual<bool>(
      immersiveAudioExpandedProvider,
      (prev, next) {
        if (!mounted) return;
        final audioActive = ref.read(audioPlaybackProvider).isActive;
        final videoActive = ref.read(activeVideoSessionProvider).isActive;
        final disableAnim = MediaQuery.maybeDisableAnimationsOf(context) ?? false;

        if (prev == true && !next && audioActive && !videoActive && !disableAnim) {
          final targetRect = _computeTargetMiniRect(FloatingMiniPlayerKind.audio);
          final releaseVel = ref.read(stageMorphReleaseVelocityProvider);
          ref.read(stageMorphReleaseVelocityProvider.notifier).state = 0.0;
          setState(() {
            _collapsingAudio = true;
            _collapsingAudioTargetRect = targetRect;
            _collapsingAudioVelocityPx = releaseVel;
          });
        } else if (next || !audioActive || videoActive) {
          if (_collapsingAudio) {
            setState(() {
              _collapsingAudio = false;
              _collapsingAudioTargetRect = null;
              _collapsingAudioVelocityPx = 0.0;
            });
          }
        }
      },
    );
  }

  Rect _computeTargetMiniRect(FloatingMiniPlayerKind kind) {
    final cached = ref
        .read(konataToastControllerProvider)
        .floatingMiniWindowRect
        .value;
    if (cached != null && cached.width > 0 && cached.height > 0) {
      return cached;
    }
    final size = MediaQuery.maybeSizeOf(context) ?? const Size(1280, 720);
    final safe = AdaptiveCapsuleLayout.effectiveSafeInsetsOf(context);
    final anchor = ref.read(floatingMiniWindowAnchorProvider);
    final hidden = ref.read(capsuleNavigationHiddenProvider);
    final subRoutePushed = ref.read(subRoutePushedProvider);
    final layout = AdaptiveCapsuleLayout(
      size: size,
      safe: safe,
      android: KonataAdaptiveTokens.isAndroid,
      navigationVisible: !hidden && !subRoutePushed,
      desktopTopBarVisible: !subRoutePushed,
      miniKind: kind,
      normalizedMiniAnchor: anchor,
    );
    return layout.floatingMiniWindowRect ??
        Rect.fromLTWH(
          size.width - KonataPlaybackTokens.floatingMiniVideoWidth - 16,
          size.height - KonataPlaybackTokens.floatingMiniVideoHeight - 16,
          KonataPlaybackTokens.floatingMiniVideoWidth,
          KonataPlaybackTokens.floatingMiniVideoHeight,
        );
  }

  void _finishAudioCollapseMorph() {
    if (!mounted) return;
    setState(() {
      _collapsingAudio = false;
      _collapsingAudioTargetRect = null;
      _collapsingAudioVelocityPx = 0.0;
    });
  }

  void _finishVideoCollapseMorph() {
    if (!mounted) return;
    // 在同一渲染帧同步清除反向标记并卸载全屏外壳，确保 GlobalObjectKey 无缝移交至悬浮小窗。
    ref.read(stageMorphReverseVideoActiveProvider.notifier).state = false;
    setState(() {
      _collapsingVideoReq = null;
      _collapsingVideoTargetRect = null;
      _collapsingVideoVelocityPx = 0.0;
    });
  }

  @override
  void dispose() {
    _videoSub?.close();
    _audioSub?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final videoSession = ref.watch(activeVideoSessionProvider);
    final videoReq = videoSession.request;
    final audioExpanded = ref.watch(immersiveAudioExpandedProvider);

    final showImmersiveAudio = audioExpanded && !videoSession.isActive;
    final showAudioCollapsing = _collapsingAudio && !showImmersiveAudio;
    final showExpandedVideo =
        videoSession.isActive && videoSession.isExpanded && videoReq != null;
    final activeCollapseVideoReq =
        (!showExpandedVideo && videoSession.isActive) ? _collapsingVideoReq : null;
    final showVideoCollapsing = activeCollapseVideoReq != null;

    if (!showImmersiveAudio &&
        !showAudioCollapsing &&
        !showExpandedVideo &&
        !showVideoCollapsing) {
      return const SizedBox.shrink();
    }

    final immersiveAudioNavKey = ref.watch(_immersiveAudioNavigatorKeyProvider);
    final originRect =
        ref.read(konataToastControllerProvider).floatingMiniWindowRect.value ??
        ref.read(stageMorphOriginRectProvider);
    final effectiveVideoReq = showExpandedVideo
        ? videoReq
        : activeCollapseVideoReq;

    return Stack(
      fit: StackFit.expand,
      children: [
        if (showImmersiveAudio || showAudioCollapsing)
          KonataStageMorphFrame(
            key: const ValueKey('spring_morph_audio_fullscreen'),
            originRect: showAudioCollapsing
                ? _collapsingAudioTargetRect
                : originRect,
            isCollapsing: showAudioCollapsing,
            releaseVelocityPxPerSec: showAudioCollapsing
                ? _collapsingAudioVelocityPx
                : 0.0,
            onCollapseCompleted: _finishAudioCollapseMorph,
            allowClipRadius: true,
            child: IgnorePointer(
              ignoring: showAudioCollapsing,
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
          ),
        if (effectiveVideoReq != null)
          KonataStageMorphFrame(
            key: ValueKey('spring_morph_video_${effectiveVideoReq.hashCode}'),
            originRect: videoSession.isInPipMode
                ? null
                : (showVideoCollapsing
                      ? _collapsingVideoTargetRect
                      : originRect),
            isCollapsing: showVideoCollapsing,
            releaseVelocityPxPerSec: showVideoCollapsing
                ? _collapsingVideoVelocityPx
                : 0.0,
            onCollapseCompleted: _finishVideoCollapseMorph,
            allowClipRadius: !KonataAdaptiveTokens.isAndroid,
            child: IgnorePointer(
              ignoring: showVideoCollapsing,
              child: EmbeddedVideoPage(
                key: ValueKey(
                  'global_embedded_video_${effectiveVideoReq.hashCode}',
                ),
                request: effectiveVideoReq,
                sharedVideoSurface: KonataHardwareVideoSurface(
                  key: GlobalObjectKey(effectiveVideoReq),
                  request: effectiveVideoReq,
                  miniPreview: showVideoCollapsing,
                ),
                inPipMode: videoSession.isInPipMode,
                onCollapseToMini: () => unawaited(
                  ref
                      .read(activeVideoSessionProvider.notifier)
                      .collapseToMini(),
                ),
                onCloseSession: () =>
                    ref.read(activeVideoSessionProvider.notifier).closeVideo(),
              ),
            ),
          ),
      ],
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
