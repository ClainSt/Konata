import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/playback/audio_playback_notifier.dart';
import '../../application/playback/playback_preferences_provider.dart';
import '../../application/playback/unified_playback_coordinator.dart';
import '../../application/playback/video_playback_controller.dart';
import '../../application/providers/konata_value_notifier.dart';
import '../../application/providers/memory_coordinator.dart';
import '../shell/adaptive_capsule_layout.dart';
import '../shell/android_scroll_capture_bridge.dart';
import '../theme/konata_adaptive_tokens.dart';
import '../theme/konata_playback_tokens.dart';
import '../video/embedded_video_page.dart';
import '../video/video_hardware_surface.dart';
import '../widgets/design_system/konata_toast.dart';
import '../widgets/playback/desktop_always_on_top_mini_stage.dart';
import '../widgets/playback/konata_floating_mini_player.dart';
import '../widgets/playback/konata_stage_morph_frame.dart';
import 'immersive_audio_page.dart';
import '../theme/konata_theme.dart';

export '../widgets/playback/desktop_always_on_top_mini_stage.dart'
    show
        DesktopAlwaysOnTopMiniKind,
        DesktopAlwaysOnTopMiniStage,
        DesktopAlwaysOnTopMiniState,
        desktopAlwaysOnTopMiniModeProvider;

export '../shell/adaptive_capsule_layout.dart'
    show
        FloatingMiniEdgeSide,
        FloatingMiniPlayerKind,
        FloatingMiniVisualState,
        floatingMiniEdgeSideProvider,
        floatingMiniVisualStateProvider,
        floatingMiniWindowAnchorProvider;
export '../widgets/playback/konata_floating_mini_player.dart'
    show KonataFloatingMiniPlayer;
export '../widgets/playback/konata_stage_morph_frame.dart'
    show
        KonataStageMorphFrame,
        KonataStageMorphFrameState,
        captureStageMorphOriginRect,
        clearStageMorphOrigin,
        stageMorphOriginKindProvider,
        stageMorphOriginRectProvider,
        stageMorphReleaseVelocityProvider,
        stageMorphReverseVideoActiveProvider;

part 'mini_audio_bar_interceptors.dart';

final _immersiveAudioNavigatorKeyProvider = Provider<GlobalKey<NavigatorState>>(
  (ref) => GlobalKey<NavigatorState>(debugLabel: 'immersive_audio_nav'),
);

/// 当前是否存在任何活跃音视频会话（仅在为 `true` 时向根 `Overlay` 挂载播放浮层，静息态零图层开销）。
final _hasActivePlaybackOverlayProvider = Provider<bool>((ref) {
  final desktopMiniActive = ref.watch(
    desktopAlwaysOnTopMiniModeProvider.select((s) => s.isActive),
  );
  final audioActive = ref.watch(
    audioPlaybackProvider.select((s) => s.isActive),
  );
  final videoActive = ref.watch(
    activeVideoSessionProvider.select((s) => s.isActive),
  );
  final videoFlag = ref.watch(videoPlaybackActiveProvider);
  final audioExpanded = ref.watch(immersiveAudioExpandedProvider);
  return desktopMiniActive ||
      audioActive ||
      videoActive ||
      videoFlag ||
      audioExpanded;
});

/// 当前应展示的可拖拽悬浮小窗内容形态 Provider。
final activeFloatingMiniPlayerKindProvider = Provider<FloatingMiniPlayerKind>((
  ref,
) {
  final desktopMiniActive = ref.watch(
    desktopAlwaysOnTopMiniModeProvider.select((s) => s.isActive),
  );
  if (desktopMiniActive) {
    return FloatingMiniPlayerKind.none;
  }
  final videoMiniEnabled = ref.watch(
    playbackPreferencesProvider.select((s) => s.videoFloatingMiniEnabled),
  );
  final audioMiniEnabled = ref.watch(
    playbackPreferencesProvider.select((s) => s.audioFloatingMiniEnabled),
  );
  final audioActive = ref.watch(
    audioPlaybackProvider.select((s) => s.isActive),
  );
  final videoSession = ref.watch(activeVideoSessionProvider);
  final videoActiveFlag = ref.watch(videoPlaybackActiveProvider);
  final audioExpanded = ref.watch(immersiveAudioExpandedProvider);
  if (videoMiniEnabled &&
      videoSession.isMinimized &&
      videoSession.request != null) {
    return FloatingMiniPlayerKind.video;
  }
  if (audioMiniEnabled &&
      audioActive &&
      !videoActiveFlag &&
      !videoSession.isActive &&
      !audioExpanded) {
    return FloatingMiniPlayerKind.audio;
  }
  return FloatingMiniPlayerKind.none;
});

/// 当可拖拽悬浮小窗停靠于视口下半区时，供未包裹作用域的列表读取的基准底部避让高度（桌面端恒为 0，不顶推页面内容）。
final miniAudioBottomClearanceProvider = Provider<double>((ref) {
  if (!KonataAdaptiveTokens.isAndroid) {
    return 0.0;
  }
  final kind = ref.watch(activeFloatingMiniPlayerKindProvider);
  if (kind == FloatingMiniPlayerKind.none) {
    return 0.0;
  }
  final visualState = ref.watch(floatingMiniVisualStateProvider);
  if (visualState == FloatingMiniVisualState.tucked) {
    return 0.0;
  }
  final anchor = ref.watch(floatingMiniWindowAnchorProvider);
  if (anchor != null &&
      anchor.dy < KonataPlaybackTokens.floatingMiniBottomZoneThresholdRatio) {
    return 0.0;
  }
  final windowHeight = kind == FloatingMiniPlayerKind.video
      ? KonataPlaybackTokens.floatingMiniVideoHeight
      : (visualState == FloatingMiniVisualState.expanded
            ? KonataPlaybackTokens.floatingMiniAudioPillHeight
            : KonataPlaybackTokens.floatingMiniAudioDiscSize);
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
  KonataModalLayerRegistry? _modalRegistry;
  Timer? _toastDetachTimer;
  bool _mediaEntriesInserted = false;
  bool _toastEntryInserted = false;
  bool _wantMediaEntries = false;
  bool _wantToastEntry = false;
  bool _useInlineFallback = false;
  bool _syncScheduled = false;
  bool _isElementActive = true;
  bool _fullscreenEntryOpaque = false;

  @override
  void initState() {
    super.initState();
    final toastCtrl = ref.read(konataToastControllerProvider);
    _toastController = toastCtrl;
    toastCtrl.registerHost();
    toastCtrl.activeToast.addListener(_handleActiveToastChanged);
    _wantToastEntry = toastCtrl.activeToast.value != null;
    final modalRegistry = ref.read(konataModalLayerRegistryProvider);
    _modalRegistry = modalRegistry;
    modalRegistry.addListener(_handleRouteOrModalChanged);
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
    _modalRegistry?.removeListener(_handleRouteOrModalChanged);
    _modalRegistry = null;
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
        KonataAdaptiveTokens.toastExitDuration + KonataTheme.toastRemovalGraceDelay,
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
      builder: (_) => _FullscreenPlayerOverlaySlot(
        onOpaqueChanged: _setFullscreenEntryOpaque,
      ),
    );
    _toastEntry ??= OverlayEntry(
      maintainState: true,
      builder: (_) => const _ToastOverlaySlot(),
    );
  }

  /// 全屏舞台稳态切入 `opaque = true`，跳过底层页面重绘合成；收起/退出前立即还原为 `false`。
  void _setFullscreenEntryOpaque(bool opaque) {
    final entry = _fullscreenPlayerEntry;
    if (_fullscreenEntryOpaque == opaque &&
        (entry == null || entry.opaque == opaque)) {
      return;
    }
    _fullscreenEntryOpaque = opaque;
    if (entry == null || !_mediaEntriesInserted) return;
    void apply() {
      final overlayMounted = _attachedNavigator?.overlay?.mounted ?? false;
      if (mounted &&
          _isElementActive &&
          _mediaEntriesInserted &&
          overlayMounted &&
          entry.mounted &&
          entry.opaque != _fullscreenEntryOpaque) {
        entry.opaque = _fullscreenEntryOpaque;
      }
    }
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) => apply());
    } else {
      apply();
    }
  }

  void _removeMediaEntries() {
    _fullscreenEntryOpaque = false;
    final entry = _fullscreenPlayerEntry;
    if (_mediaEntriesInserted) {
      _floatingMiniEntry?.remove();
      entry?.remove();
      _mediaEntriesInserted = false;
    }
    if (entry != null && entry.opaque) {
      if (!entry.mounted) {
        entry.opaque = false;
      } else {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!entry.mounted && entry.opaque) {
            entry.opaque = false;
          }
        });
      }
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
    if (!_fullscreenEntryOpaque && fullEntry.opaque && !fullEntry.mounted) {
      fullEntry.opaque = false;
    }

    final observer = _boundObserver;
    final observerAttached =
        observer != null && identical(observer.navigator, nav);
    final registryModals =
        _modalRegistry?.routesFor(nav) ?? const <OverlayRoute<dynamic>>[];

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

    // 保活当前活跃视频控制器，确保在全屏与悬浮小窗切换时绝不触发 autoDispose 重建会话；
    // 悬浮小窗态同步转发视频瞬态提示至全站居中毛玻璃胶囊（全屏态由 EmbeddedVideoPage 直接承接）。
    if (videoReq != null) {
      ref.watch(videoPlaybackProvider(videoReq).select((s) => s.isClosing));
      ref.listen<VideoTransientNotice?>(
        videoPlaybackProvider(videoReq).select((s) => s.transientNotice),
        (prev, next) {
          if (next == null || next.seq == prev?.seq) return;
          final currentSession = ref.read(activeVideoSessionProvider);
          if (currentSession.isExpanded) return;
          ref
              .read(konataToastControllerProvider)
              .show(
                next.message,
                isError: next.isError,
                duration: next.duration,
              );
        },
      );
    }

    final audioExpanded = ref.watch(immersiveAudioExpandedProvider);
    final subRoutePushed = ref.watch(subRoutePushedProvider);
    final shouldHandleSystemBack =
        (videoSession.isActive &&
            videoSession.isExpanded &&
            !videoSession.isInPipMode) ||
        audioExpanded ||
        subRoutePushed;

    void syncForegroundAudioObservation() {
      if (!ref.read(audioPlaybackProvider).isActive) return;
      final expanded = ref.read(immersiveAudioExpandedProvider);
      final visual = ref.read(floatingMiniVisualStateProvider);
      final mode = expanded
          ? AudioProgressObservationMode.highFrequency
          : (visual == FloatingMiniVisualState.tucked
                ? AudioProgressObservationMode.suspended
                : AudioProgressObservationMode.lowFrequency);
      ref.read(audioPlaybackProvider.notifier).setProgressObservationMode(mode);
    }

    ref.listen<bool>(immersiveAudioExpandedProvider, (_, _) {
      syncForegroundAudioObservation();
    });
    ref.listen<FloatingMiniVisualState>(floatingMiniVisualStateProvider, (_, _) {
      syncForegroundAudioObservation();
    });
    // 关闭视频/音频悬浮小窗开关时，若当前存在处于收起小窗态的会话则立即停止，避免无界面后台发声。
    ref.listen<bool>(
      playbackPreferencesProvider.select((s) => s.videoFloatingMiniEnabled),
      (prev, next) {
        if (prev == true && !next) {
          final current = ref.read(activeVideoSessionProvider);
          if (current.isMinimized) {
            unawaited(ref.read(activeVideoSessionProvider.notifier).closeVideo());
          }
        }
      },
    );
    ref.listen<bool>(
      playbackPreferencesProvider.select((s) => s.audioFloatingMiniEnabled),
      (prev, next) {
        if (prev == true && !next) {
          final audioActive = ref.read(audioPlaybackProvider).isActive;
          final expanded = ref.read(immersiveAudioExpandedProvider);
          final videoActive = ref.read(activeVideoSessionProvider).isActive;
          if (audioActive && !expanded && !videoActive) {
            unawaited(ref.read(audioPlaybackProvider.notifier).stopAndClose());
          }
        }
      },
    );
    // 桌面置顶迷你窗模式期间若活跃播放意外结束或被关闭，自动退出迷你窗并还原主窗口，防滞留空白小窗。
    ref.listen<bool>(
      activeVideoSessionProvider.select((s) => s.isActive),
      (prev, next) {
        if (prev == true && !next) {
          final mini = ref.read(desktopAlwaysOnTopMiniModeProvider);
          if (mini.kind == DesktopAlwaysOnTopMiniKind.video) {
            unawaited(
              ref
                  .read(desktopAlwaysOnTopMiniModeProvider.notifier)
                  .handleActiveSessionEnded(),
            );
          }
        }
      },
    );
    ref.listen<bool>(
      audioPlaybackProvider.select((s) => s.isActive),
      (prev, next) {
        if (prev == true && !next) {
          final mini = ref.read(desktopAlwaysOnTopMiniModeProvider);
          if (mini.kind == DesktopAlwaysOnTopMiniKind.audio) {
            unawaited(
              ref
                  .read(desktopAlwaysOnTopMiniModeProvider.notifier)
                  .handleActiveSessionEnded(),
            );
          }
        }
      },
    );

    return _OverlayBackInterceptor(
      handlesSystemBack: shouldHandleSystemBack,
      onBackgrounded: () async {
        if (ref.read(audioPlaybackProvider).isActive) {
          ref
              .read(audioPlaybackProvider.notifier)
              .setProgressObservationMode(
                AudioProgressObservationMode.suspended,
              );
        }
        await ref
            .read(activeVideoSessionProvider.notifier)
            .handleAppBackgrounded();
        unawaited(
          ref.read(konataMemoryCoordinatorProvider).onAppHiddenOrMinimized(),
        );
      },
      onForegrounded: () {
        syncForegroundAudioObservation();
        ref.read(activeVideoSessionProvider.notifier).handleAppForegrounded();
      },
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
          if (ref.read(playbackPreferencesProvider).videoFloatingMiniEnabled) {
            await ref.read(activeVideoSessionProvider.notifier).collapseToMini();
          } else {
            await ref.read(activeVideoSessionProvider.notifier).closeVideo();
          }
          return true;
        }
        if (audioExpanded) {
          final audioNav = ref.read(_immersiveAudioNavigatorKeyProvider).currentState;
          if (audioNav != null && audioNav.canPop()) {
            await audioNav.maybePop();
            return true;
          }
          if (ref.read(immersivePortraitQueueSheetOpenProvider)) {
            ref.read(immersivePortraitQueueSheetOpenProvider.notifier).state =
                false;
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
    final visualState = ref.watch(floatingMiniVisualStateProvider);
    final edgeSide = ref.watch(floatingMiniEdgeSideProvider);
    double? videoAspectRatio;
    if (miniKind == FloatingMiniPlayerKind.video && videoReq != null) {
      videoAspectRatio = ref.watch(
        videoPlaybackProvider(videoReq).select((s) {
          final w = s.probeStats.videoWidth;
          final h = s.probeStats.videoHeight;
          return (w != null && h != null && w > 0 && h > 0) ? w / h : null;
        }),
      );
    }
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
      visualState: visualState,
      edgeSide: edgeSide,
      videoAspectRatio: videoAspectRatio,
    );

    final sharedSurface =
        (miniKind == FloatingMiniPlayerKind.video &&
            videoReq != null &&
            visualState != FloatingMiniVisualState.tucked)
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
  const _FullscreenPlayerOverlaySlot({this.onOpaqueChanged});

  final ValueChanged<bool>? onOpaqueChanged;

  @override
  ConsumerState<_FullscreenPlayerOverlaySlot> createState() =>
      _FullscreenPlayerOverlaySlotState();
}

class _FullscreenPlayerOverlaySlotState
    extends ConsumerState<_FullscreenPlayerOverlaySlot> {
  ProviderSubscription<ActiveVideoSessionState>? _videoSub;
  ProviderSubscription<bool>? _audioSub;
  KonataValueNotifier<bool>? _reverseVideoActiveNotifier;

  bool _collapsingAudio = false;
  Rect? _collapsingAudioTargetRect;
  double _collapsingAudioVelocityPx = 0.0;

  VideoLaunchRequest? _collapsingVideoReq;
  Rect? _collapsingVideoTargetRect;
  double _collapsingVideoVelocityPx = 0.0;

  @override
  void initState() {
    super.initState();
    _reverseVideoActiveNotifier = ref.read(
      stageMorphReverseVideoActiveProvider.notifier,
    );
    if (ref.read(activeVideoSessionProvider).isExpanded) {
      ref.read(konataMemoryCoordinatorProvider).onEnterFullscreenVideo();
      if (ref.read(floatingMiniVisualStateProvider) !=
          FloatingMiniVisualState.collapsed) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted &&
              ref.read(floatingMiniVisualStateProvider) !=
                  FloatingMiniVisualState.collapsed) {
            ref.read(floatingMiniVisualStateProvider.notifier).state =
                FloatingMiniVisualState.collapsed;
          }
        });
      }
    }
    _videoSub = ref.listenManual<ActiveVideoSessionState>(
      activeVideoSessionProvider,
      (prev, next) {
        if (!mounted) return;
        // 仅画中画 sourceRect 坐标刷新时绝不触发全屏/小窗状态流转，避免中途误清反向形变标记。
        if (prev != null &&
            prev.request == next.request &&
            prev.isExpanded == next.isExpanded &&
            prev.isInPipMode == next.isInPipMode) {
          return;
        }
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

        if (next.isActive && next.isExpanded && !(prev?.isExpanded ?? false)) {
          ref.read(konataMemoryCoordinatorProvider).onEnterFullscreenVideo();
          if (ref.read(floatingMiniVisualStateProvider) !=
              FloatingMiniVisualState.collapsed) {
            ref.read(floatingMiniVisualStateProvider.notifier).state =
                FloatingMiniVisualState.collapsed;
          }
        }
        if (wasExpanded && nowMinimized && !disableAnim) {
          widget.onOpaqueChanged?.call(false);
          if (ref.read(floatingMiniVisualStateProvider) !=
              FloatingMiniVisualState.collapsed) {
            ref.read(floatingMiniVisualStateProvider.notifier).state =
                FloatingMiniVisualState.collapsed;
          }
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
          if (!next.isActive || !next.isExpanded || next.isInPipMode) {
            widget.onOpaqueChanged?.call(false);
          }
          if (_collapsingVideoReq != null ||
              ref.read(stageMorphReverseVideoActiveProvider)) {
            ref.read(stageMorphReverseVideoActiveProvider.notifier).state = false;
            setState(() {
              _collapsingVideoReq = null;
              _collapsingVideoTargetRect = null;
              _collapsingVideoVelocityPx = 0.0;
            });
          }
        } else if (nowMinimized) {
          widget.onOpaqueChanged?.call(false);
          if (ref.read(floatingMiniVisualStateProvider) !=
              FloatingMiniVisualState.collapsed) {
            ref.read(floatingMiniVisualStateProvider.notifier).state =
                FloatingMiniVisualState.collapsed;
          }
          if (_collapsingVideoReq == null &&
              ref.read(stageMorphReverseVideoActiveProvider)) {
            ref.read(stageMorphReverseVideoActiveProvider.notifier).state = false;
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
        final audioMiniEnabled = ref
            .read(playbackPreferencesProvider)
            .audioFloatingMiniEnabled;
        final disableAnim = MediaQuery.maybeDisableAnimationsOf(context) ?? false;

        if (prev == true &&
            !next &&
            audioActive &&
            !videoActive &&
            audioMiniEnabled &&
            !disableAnim) {
          widget.onOpaqueChanged?.call(false);
          final targetRect = _computeTargetMiniRect(FloatingMiniPlayerKind.audio);
          final releaseVel = ref.read(stageMorphReleaseVelocityProvider);
          ref.read(stageMorphReleaseVelocityProvider.notifier).state = 0.0;
          setState(() {
            _collapsingAudio = true;
            _collapsingAudioTargetRect = targetRect;
            _collapsingAudioVelocityPx = releaseVel;
          });
        } else if (next || !audioActive || videoActive) {
          if (!next || !audioActive) {
            widget.onOpaqueChanged?.call(false);
          }
          if (_collapsingAudio) {
            setState(() {
              _collapsingAudio = false;
              _collapsingAudioTargetRect = null;
              _collapsingAudioVelocityPx = 0.0;
            });
          }
        } else if (!next) {
          widget.onOpaqueChanged?.call(false);
        }
      },
    );
  }

  Rect _computeTargetMiniRect(FloatingMiniPlayerKind kind) {
    final size = MediaQuery.maybeSizeOf(context) ?? const Size(1280, 720);
    final safe = AdaptiveCapsuleLayout.effectiveSafeInsetsOf(context);
    final anchor = ref.read(floatingMiniWindowAnchorProvider);
    final visualState = kind == FloatingMiniPlayerKind.video
        ? FloatingMiniVisualState.collapsed
        : ref.read(floatingMiniVisualStateProvider);
    final edgeSide = ref.read(floatingMiniEdgeSideProvider);
    final hidden = ref.read(capsuleNavigationHiddenProvider);
    final subRoutePushed = ref.read(subRoutePushedProvider);
    double? videoAspectRatio;
    if (kind == FloatingMiniPlayerKind.video) {
      final vReq = ref.read(activeVideoSessionProvider).request;
      if (vReq != null) {
        final stats = ref.read(videoPlaybackProvider(vReq)).probeStats;
        final w = stats.videoWidth;
        final h = stats.videoHeight;
        if (w != null && h != null && w > 0 && h > 0) {
          videoAspectRatio = w / h;
        }
      }
    }
    final layout = AdaptiveCapsuleLayout(
      size: size,
      safe: safe,
      android: KonataAdaptiveTokens.isAndroid,
      navigationVisible: !hidden && !subRoutePushed,
      desktopTopBarVisible: !subRoutePushed,
      miniKind: kind,
      normalizedMiniAnchor: anchor,
      visualState: visualState,
      edgeSide: edgeSide,
      videoAspectRatio: videoAspectRatio,
    );
    return layout.floatingMiniWindowRect ??
        Rect.fromLTWH(
          size.width - KonataPlaybackTokens.floatingMiniVideoWidth - 16,
          size.height - KonataPlaybackTokens.floatingMiniVideoHeight - 16,
          KonataPlaybackTokens.floatingMiniVideoWidth,
          KonataPlaybackTokens.floatingMiniVideoHeight,
        );
  }

  Rect? _resolveStageOriginRect(FloatingMiniPlayerKind targetKind) {
    final liveMiniRect = ref
        .read(konataToastControllerProvider)
        .floatingMiniWindowRect
        .value;
    if (liveMiniRect != null &&
        liveMiniRect.width > 0 &&
        liveMiniRect.height > 0) {
      return liveMiniRect;
    }
    final capturedKind = ref.read(stageMorphOriginKindProvider);
    if (capturedKind != null && capturedKind != targetKind) {
      return null;
    }
    return ref.read(stageMorphOriginRectProvider);
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
    final reverseNotifier = _reverseVideoActiveNotifier;
    _reverseVideoActiveNotifier = null;
    if (_collapsingVideoReq != null && reverseNotifier != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (reverseNotifier.isMounted && reverseNotifier.state) {
          reverseNotifier.state = false;
        }
      });
    }
    _videoSub?.close();
    _audioSub?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final desktopMini = ref.watch(desktopAlwaysOnTopMiniModeProvider);
    final videoSession = ref.watch(activeVideoSessionProvider);
    final videoReq = videoSession.request;
    final audioActive = ref.watch(
      audioPlaybackProvider.select((s) => s.isActive),
    );
    final audioExpanded = ref.watch(immersiveAudioExpandedProvider);
    final videoMiniEnabled = ref.watch(
      playbackPreferencesProvider.select((s) => s.videoFloatingMiniEnabled),
    );

    if (desktopMini.isActive) {
      final canShowDesktopVideo =
          desktopMini.kind == DesktopAlwaysOnTopMiniKind.video &&
          videoSession.isActive &&
          videoReq != null;
      final canShowDesktopAudio =
          desktopMini.kind == DesktopAlwaysOnTopMiniKind.audio && audioActive;
      if (canShowDesktopVideo || canShowDesktopAudio) {
        // 桌面置顶迷你窗直接切入 opaque=true 遮蔽底层主页面，窗口缩小至 300×300 时零冗余重绘与零溢出。
        widget.onOpaqueChanged?.call(true);
        return DesktopAlwaysOnTopMiniStage(
          key: ValueKey('desktop_mini_stage_${desktopMini.kind.name}'),
          kind: desktopMini.kind,
          videoRequest: canShowDesktopVideo ? videoReq : null,
          sharedVideoSurface: canShowDesktopVideo
              ? KonataHardwareVideoSurface(
                  key: GlobalObjectKey(videoReq),
                  request: videoReq,
                  miniPreview: false,
                )
              : null,
        );
      }
    }

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
      widget.onOpaqueChanged?.call(false);
      if (ref.read(stageMorphReverseVideoActiveProvider)) {
        final reverseNotifier = _reverseVideoActiveNotifier;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted &&
              _collapsingVideoReq == null &&
              reverseNotifier != null &&
              reverseNotifier.isMounted &&
              reverseNotifier.state) {
            reverseNotifier.state = false;
          }
        });
      }
      return const SizedBox.shrink();
    }

    final immersiveAudioNavKey = ref.watch(_immersiveAudioNavigatorKeyProvider);
    final audioOriginRect = _resolveStageOriginRect(FloatingMiniPlayerKind.audio);
    final videoOriginRect = _resolveStageOriginRect(FloatingMiniPlayerKind.video);
    final effectiveVideoReq = showExpandedVideo
        ? videoReq
        : activeCollapseVideoReq;
    final windowsVideoUnderlay =
        !KonataAdaptiveTokens.isAndroid &&
        effectiveVideoReq != null &&
        ref.watch(
          videoPlaybackProvider(
            effectiveVideoReq,
          ).select((s) => s.windowsUnderlayActive && !s.audioOnlyMode),
        );
    final usesVideoCanvasHolePunch =
        KonataAdaptiveTokens.isAndroid || windowsVideoUnderlay;

    return Stack(
      fit: StackFit.expand,
      children: [
        if (showImmersiveAudio || showAudioCollapsing)
          KonataStageMorphFrame(
            key: const ValueKey('spring_morph_audio_fullscreen'),
            originRect: showAudioCollapsing
                ? _collapsingAudioTargetRect
                : audioOriginRect,
            isCollapsing: showAudioCollapsing,
            releaseVelocityPxPerSec: showAudioCollapsing
                ? _collapsingAudioVelocityPx
                : 0.0,
            onExpandCompleted: () {
              clearStageMorphOrigin(ref);
              widget.onOpaqueChanged?.call(true);
            },
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
                      : videoOriginRect),
            isCollapsing: showVideoCollapsing,
            releaseVelocityPxPerSec: showVideoCollapsing
                ? _collapsingVideoVelocityPx
                : 0.0,
            onExpandCompleted: videoSession.isInPipMode
                ? null
                : () {
                    clearStageMorphOrigin(ref);
                    widget.onOpaqueChanged?.call(true);
                  },
            onCollapseCompleted: _finishVideoCollapseMorph,
            allowClipRadius: !usesVideoCanvasHolePunch,
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
                onCollapseToMini: videoMiniEnabled
                    ? () => unawaited(
                        ref
                            .read(activeVideoSessionProvider.notifier)
                            .collapseToMini(),
                      )
                    : null,
                onCloseSession: () =>
                    ref.read(activeVideoSessionProvider.notifier).closeVideo(),
              ),
            ),
          ),
      ],
    );
  }
}
