part of 'mini_audio_bar.dart';

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
    // 桌面置顶迷你窗模式期间若活跃播放意外结束或被关闭，自动退出迷你窗并还原主窗口，防滞留空白小窗；
    // 同时按需通知 WebDAV 同步控制器执行停播静默同步。
    ref.listen<bool>(
      activeVideoSessionProvider.select((s) => s.isActive),
      (prev, next) {
        if (prev == true && !next) {
          ref.read(webDavSyncControllerProvider.notifier).notifyPlaybackStopped();
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
          ref.read(webDavSyncControllerProvider.notifier).notifyPlaybackStopped();
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
      onInterceptBack: () => _interceptFullscreenMediaBack(ref),
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
