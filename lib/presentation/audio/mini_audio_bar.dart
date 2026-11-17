import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/playback/audio_playback_notifier.dart';
import '../../application/playback/playback_preferences_provider.dart';
import '../../application/playback/unified_playback_coordinator.dart';
import '../../application/playback/video_playback_controller.dart';
import '../../application/providers/artwork_provider.dart';
import '../../domain/playback/playback_formatters.dart';
import '../shell/adaptive_capsule_layout.dart';
import '../theme/konata_adaptive_tokens.dart';
import '../theme/konata_palette.dart';
import '../theme/konata_playback_tokens.dart';
import '../theme/konata_theme.dart';
import '../video/embedded_video_page.dart';
import '../video/video_hardware_surface.dart';
import '../widgets/design_system/ellipsis_text_with_tooltip.dart';
import '../widgets/design_system/konata_draggable_scrollbar.dart';
import '../widgets/design_system/konata_glass_capsule.dart';
import '../widgets/design_system/konata_glass_dialog.dart';
import '../widgets/managed_image.dart';
import '../widgets/playback/konata_playback_capsule.dart';
import '../widgets/playback/konata_spec_badge.dart';
import '../widgets/playback/konata_volume_control.dart';
import 'immersive_audio_page.dart';
import 'smart_cover_framing.dart';

/// 当常驻播放胶囊（纯音频或最小化视频小窗）处于可视状态时，供底部滚动视图预留防遮挡留白的高度 Provider。
final miniAudioBottomClearanceProvider = Provider<double>((ref) {
  final audioActive = ref.watch(
    audioPlaybackProvider.select((s) => s.isActive),
  );
  final videoSession = ref.watch(activeVideoSessionProvider);
  final videoActiveFlag = ref.watch(videoPlaybackActiveProvider);
  final audioExpanded = ref.watch(immersiveAudioExpandedProvider);
  final miniVideoVisible = videoSession.isMinimized;
  final miniAudioVisible =
      audioActive &&
      !videoActiveFlag &&
      !videoSession.isActive &&
      !audioExpanded;
  return (miniVideoVisible || miniAudioVisible)
      ? KonataPlaybackTokens.miniBarClearanceHeight
      : 0.0;
});

/// 由 [DesktopShell] 或宿主层向页面子树透传迷你音频栏安全避让高度的作用域。
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

  /// 优先读取 [DesktopShell] 透传的底部避让高度，同时订阅全局 Provider 以保证路由栈新页面实时响应。
  static double resolve(BuildContext context, WidgetRef ref) {
    final watched = ref.watch(miniAudioBottomClearanceProvider);
    return maybeOf(context) ?? watched;
  }

  @override
  bool updateShouldNotify(KonataBottomClearanceScope oldWidget) {
    return bottomClearance != oldWidget.bottomClearance;
  }
}

/// 挂载在 `MaterialApp.builder` 的全局音频宿主（提供合法根级 [Overlay] 祖先，杜绝 Tooltip/Toast 缺失异常，
/// 并确保内置视频页打开时自动隐藏迷你栏且全程零指针拦截）。
class MiniAudioOverlayHost extends StatefulWidget {
  /// 创建全局音频叠加宿主。
  const MiniAudioOverlayHost({super.key, required this.child});

  /// 被包裹的根 `Navigator` 子树。
  final Widget child;

  @override
  State<MiniAudioOverlayHost> createState() => _MiniAudioOverlayHostState();
}

class _MiniAudioOverlayHostState extends State<MiniAudioOverlayHost> {
  late final OverlayEntry _rootEntry;

  @override
  void initState() {
    super.initState();
    _rootEntry = OverlayEntry(
      maintainState: true,
      builder: (_) => Stack(
        fit: StackFit.expand,
        children: [
          _AudioContentClearance(child: widget.child),
          const _GlobalAudioOverlayLayer(),
        ],
      ),
    );
  }

  @override
  void didUpdateWidget(covariant MiniAudioOverlayHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.child != widget.child) {
      _rootEntry.markNeedsBuild();
    }
  }

  @override
  void dispose() {
    _rootEntry.remove();
    _rootEntry.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Overlay(initialEntries: [_rootEntry]);
  }
}

/// 路由栈全局共享播放条避让，子路由不会丢失安全区信息。
class _AudioContentClearance extends ConsumerWidget {
  const _AudioContentClearance({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final visible = ref.watch(miniAudioBottomClearanceProvider) > 0;
    final hidden = ref.watch(capsuleNavigationHiddenProvider);
    final android = KonataAdaptiveTokens.isAndroid;
    final geometry = AdaptiveCapsuleLayout(
      size: MediaQuery.sizeOf(context),
      safe: MediaQuery.paddingOf(context),
      android: android,
      playerVisible: visible,
      navigationVisible: !hidden,
    );
    return KonataBottomClearanceScope(
      bottomClearance: android
          ? geometry.bottomClearance
          : ref.watch(miniAudioBottomClearanceProvider),
      child: child,
    );
  }
}

class _GlobalAudioOverlayLayer extends ConsumerWidget {
  const _GlobalAudioOverlayLayer();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 驱动 Android 画中画自动进入资格与比例实时同步
    ref.watch(androidPipAutoSyncProvider);

    final audio = ref.watch(
      audioPlaybackProvider.select((s) => (s.isActive, s.errorMessage)),
    );
    final videoSession = ref.watch(activeVideoSessionProvider);
    final videoReq = videoSession.request;
    // 保活当前活跃视频控制器，确保在全屏与小窗胶囊切换时绝不触发 autoDispose 重建会话
    if (videoReq != null) {
      ref.watch(videoPlaybackProvider(videoReq).select((s) => s.isClosing));
    }

    final hidden = ref.watch(capsuleNavigationHiddenProvider);
    final android = KonataAdaptiveTokens.isAndroid;
    final videoActiveFlag = ref.watch(videoPlaybackActiveProvider);
    final audioExpanded = ref.watch(immersiveAudioExpandedProvider);

    final miniVideoVisible = videoSession.isMinimized;
    final miniAudioVisible =
        audio.$1 && !videoActiveFlag && !videoSession.isActive && !audioExpanded;
    final anyMiniCapsuleVisible = miniVideoVisible || miniAudioVisible;

    final geometry = AdaptiveCapsuleLayout(
      size: MediaQuery.sizeOf(context),
      safe: MediaQuery.paddingOf(context),
      android: android,
      playerVisible: anyMiniCapsuleVisible,
      navigationVisible: !hidden,
    );

    if (videoActiveFlag && !videoSession.isActive) {
      return const SizedBox.shrink();
    }

    final sharedVideoSurface = videoReq != null
        ? KonataHardwareVideoSurface(
            key: GlobalObjectKey(videoReq),
            request: videoReq,
            miniPreview: videoSession.isMinimized,
          )
        : null;

    final errorMsg = audio.$2?.trim() ?? '';

    return _OverlayBackInterceptor(
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
          ref.read(immersiveAudioExpandedProvider.notifier).state = false;
          return true;
        }
        return false;
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 持久浮动毛玻璃播放胶囊（承载纯音频或收起后的视频圆角实时预览）
          AnimatedPositioned(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            left: android
                ? geometry.playerRect.left
                : KonataPlaybackTokens.miniBarHorizontalInset,
            right: android
                ? MediaQuery.sizeOf(context).width - geometry.playerRect.right
                : KonataPlaybackTokens.miniBarHorizontalInset,
            bottom: !anyMiniCapsuleVisible
                ? -(KonataPlaybackTokens.miniBarHeight + 36)
                : (android
                      ? MediaQuery.sizeOf(context).height -
                            geometry.playerRect.bottom
                      : KonataPlaybackTokens.miniBarBottomInset),
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 180),
              opacity: anyMiniCapsuleVisible ? 1.0 : 0.0,
              child: IgnorePointer(
                ignoring: !anyMiniCapsuleVisible,
                child: (miniVideoVisible && videoReq != null)
                    ? Center(
                        key: ValueKey('mini_video_${videoReq.hashCode}'),
                        child: _MiniVideoCapsuleBar(
                          request: videoReq,
                          previewSurface: sharedVideoSurface!,
                        ),
                      )
                    : AnimatedSwitcher(
                        duration: KonataTheme.standardTransition,
                        child: miniAudioVisible
                            ? const Center(
                                key: ValueKey('mini_visible'),
                                child: MiniAudioBar(),
                              )
                            : const SizedBox.shrink(),
                      ),
              ),
            ),
          ),
          // 全屏流光倒影沉浸音频页
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 260),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            transitionBuilder: (child, animation) => FadeTransition(
              opacity: animation,
              child: ScaleTransition(
                scale: Tween<double>(begin: 0.97, end: 1.0).animate(animation),
                child: child,
              ),
            ),
            child: (audioExpanded && !videoSession.isActive)
                ? const ImmersiveAudioPage(key: ValueKey('immersive_audio'))
                : const SizedBox.shrink(),
          ),
          // 全屏内置视频页（展开态复用同一 GlobalObjectKey 表面，零重建解码会话）
          if (videoSession.isActive &&
              videoSession.isExpanded &&
              videoReq != null)
            EmbeddedVideoPage(
              key: ValueKey('global_embedded_video_${videoReq.hashCode}'),
              request: videoReq,
              sharedVideoSurface: sharedVideoSurface,
              inPipMode: videoSession.isInPipMode,
              onCollapseToMini: () => unawaited(
                ref.read(activeVideoSessionProvider.notifier).collapseToMini(),
              ),
              onCloseSession: () =>
                  ref.read(activeVideoSessionProvider.notifier).closeVideo(),
            ),
          // 音频路径失效或读取异常全局醒目提示横幅
          if (errorMsg.isNotEmpty && !videoSession.isActive)
            Positioned(
              left: 28,
              right: 28,
              top: audioExpanded ? 62 : null,
              bottom: audioExpanded
                  ? null
                  : (android
                        ? geometry.errorBottomInset
                        : KonataPlaybackTokens.miniBarBottomInset +
                              KonataPlaybackTokens.miniBarHeight +
                              10),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 680),
                  child: Material(
                    type: MaterialType.transparency,
                    child: _AudioErrorBanner(
                      message: errorMsg,
                      onDismiss: () => ref
                          .read(audioPlaybackProvider.notifier)
                          .dismissError(),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 不依赖 `Router` 祖先的根级全屏播放层返回键拦截器。
class _OverlayBackInterceptor extends StatefulWidget {
  const _OverlayBackInterceptor({
    required this.onInterceptBack,
    required this.child,
  });

  final Future<bool> Function() onInterceptBack;
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
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Future<bool> didPopRoute() {
    return widget.onInterceptBack();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _AudioErrorBanner extends StatelessWidget {
  const _AudioErrorBanner({required this.message, required this.onDismiss});

  final String message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: p.dangerBadge.bg.withValues(alpha: p.isDark ? 0.90 : 0.95),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: p.dangerBadge.border, width: 1),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.error_outline_rounded,
                size: 18,
                color: p.dangerBadge.fg,
              ),
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  message,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: p.dangerBadge.fg,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    decoration: TextDecoration.none,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              KonataCapsuleIconButton(
                key: const ValueKey('mini_error_close'),
                icon: Icons.close_rounded,
                tooltip: '关闭播放错误提示',
                size: 16,
                padding: const EdgeInsets.all(2),
                fixedSize: KonataAdaptiveTokens.isAndroid
                    ? KonataAdaptiveTokens.touchTarget
                    : null,
                color: p.dangerBadge.fg,
                onTap: onDismiss,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 全局持久 CD / 无损音乐悬浮毛玻璃迷你底栏（直接复用 [KonataPlaybackCapsule]）。
///
/// 交互热区严格隔离：
/// - 仅左侧封面/标题/时间区域（含右侧延展空白底板）及右上角显式 `↗` 按钮可进入全屏流光页；
/// - 点击中区 `☰` 通过 [CompositedTransformTarget] + [OverlayPortal] 在胶囊正上方弹出毛玻璃曲目列表。
class MiniAudioBar extends ConsumerStatefulWidget {
  /// 创建迷你音频底栏。
  const MiniAudioBar({super.key});

  @override
  ConsumerState<MiniAudioBar> createState() => _MiniAudioBarState();
}

class _MiniAudioBarState extends ConsumerState<MiniAudioBar> {
  final LayerLink _capsuleLink = LayerLink();
  final OverlayPortalController _queuePortalCtrl = OverlayPortalController();
  final ScrollController _queueScrollCtrl = ScrollController();
  final Object _tapRegionGroupId = Object();

  AudioPlaybackState? _lastVisibleState;
  bool _queueOpen = false;
  bool _keyHandlerRegistered = false;

  @override
  void dispose() {
    _unregisterKeyHandler();
    _queueScrollCtrl.dispose();
    super.dispose();
  }

  void _registerKeyHandler() {
    if (_keyHandlerRegistered) return;
    HardwareKeyboard.instance.addHandler(_handleGlobalKeyEvent);
    _keyHandlerRegistered = true;
  }

  void _unregisterKeyHandler() {
    if (!_keyHandlerRegistered) return;
    HardwareKeyboard.instance.removeHandler(_handleGlobalKeyEvent);
    _keyHandlerRegistered = false;
  }

  bool _handleGlobalKeyEvent(KeyEvent event) {
    if (!mounted || !_queueOpen) return false;
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape) {
      _closeQueueOverlay();
      return true;
    }
    return false;
  }

  void _openQueueOverlay() {
    if (_queueOpen) return;
    _queuePortalCtrl.show();
    _registerKeyHandler();
    setState(() => _queueOpen = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_queueOpen || !_queueScrollCtrl.hasClients) return;
      final state = ref.read(audioPlaybackProvider);
      if (state.currentIndex > 2 && state.queue.length > 1) {
        final maxExt = _queueScrollCtrl.position.maxScrollExtent;
        final ratio = (state.currentIndex / (state.queue.length - 1)).clamp(
          0.0,
          1.0,
        );
        _queueScrollCtrl.jumpTo((ratio * maxExt).clamp(0.0, maxExt));
      }
    });
  }

  void _closeQueueOverlay({bool skipSetState = false}) {
    _unregisterKeyHandler();
    if (_queuePortalCtrl.isShowing) {
      _queuePortalCtrl.hide();
    }
    if (!skipSetState && _queueOpen && mounted) {
      setState(() => _queueOpen = false);
    } else {
      _queueOpen = false;
    }
  }

  void _toggleQueueOverlay() {
    if (_queueOpen) {
      _closeQueueOverlay();
    } else {
      _openQueueOverlay();
    }
  }

  void _openImmersive() {
    _closeQueueOverlay();
    ref.read(immersiveAudioExpandedProvider.notifier).state = true;
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<bool>(immersiveAudioExpandedProvider, (_, expanded) {
      if (expanded && _queueOpen) _closeQueueOverlay();
    });
    ref.listen<bool>(videoPlaybackActiveProvider, (_, videoActive) {
      if (videoActive && _queueOpen) _closeQueueOverlay();
    });
    ref.listen<bool>(audioPlaybackProvider.select((s) => s.isActive), (
      _,
      active,
    ) {
      if (!active && _queueOpen) _closeQueueOverlay();
    });

    ref.watch(
      audioPlaybackProvider.select(
        (s) => (
          s.isActive,
          s.isPlaying,
          s.currentIndex,
          s.queue,
          s.cover,
          s.loopMode,
          s.volume,
          s.isMuted,
          s.audioCodecLabel,
          s.sampleRateAndBitDepthLabel,
        ),
      ),
    );
    final liveState = KonataAdaptiveTokens.isAndroid
        ? ref.read(audioPlaybackProvider)
        : ref.watch(audioPlaybackProvider);
    if (liveState.currentItem != null) _lastVisibleState = liveState;
    final state = liveState.currentItem != null
        ? liveState
        : _lastVisibleState ?? liveState;
    final notifier = ref.read(audioPlaybackProvider.notifier);
    final item = state.currentItem;
    if (item == null) {
      if (_queueOpen) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _queueOpen) _closeQueueOverlay();
        });
      }
      return const SizedBox.shrink();
    }

    final specLabel = state.audioCodecLabel.isNotEmpty
        ? (state.sampleRateAndBitDepthLabel.isNotEmpty
              ? '${state.audioCodecLabel} · ${state.sampleRateAndBitDepthLabel}'
              : state.audioCodecLabel)
        : '';

    return Material(
      type: MaterialType.transparency,
      child: DefaultTextStyle.merge(
        style: const TextStyle(decoration: TextDecoration.none),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final availableWidth = constraints.maxWidth.isFinite
                ? constraints.maxWidth
                : MediaQuery.sizeOf(context).width;
            final showSpecBadge =
                specLabel.isNotEmpty &&
                availableWidth >=
                    KonataPlaybackTokens.miniBarHideBadgeBreakpoint;

            return TapRegion(
              groupId: _tapRegionGroupId,
              child: CompositedTransformTarget(
                link: _capsuleLink,
                child: OverlayPortal(
                  controller: _queuePortalCtrl,
                  overlayChildBuilder: (overlayContext) {
                    final overlaySize = MediaQuery.sizeOf(overlayContext);
                    final maxH = (overlaySize.height - 140.0).clamp(
                      KonataPlaybackTokens.miniQueuePopoverMinHeight,
                      KonataPlaybackTokens.miniQueuePopoverMaxHeight,
                    );
                    final maxW = (availableWidth - 16.0).clamp(
                      KonataPlaybackTokens.capsuleMinWidth,
                      KonataPlaybackTokens.miniQueuePopoverMaxWidth,
                    );
                    return Positioned.fill(
                      child: Align(
                        alignment: Alignment.topLeft,
                        child: CompositedTransformFollower(
                          link: _capsuleLink,
                          showWhenUnlinked: false,
                          targetAnchor: Alignment.topCenter,
                          followerAnchor: Alignment.bottomCenter,
                          offset: const Offset(
                            0,
                            KonataPlaybackTokens.miniQueuePopoverOffsetY,
                          ),
                          child: Material(
                            type: MaterialType.transparency,
                            child: DefaultTextStyle.merge(
                              style: const TextStyle(
                                decoration: TextDecoration.none,
                              ),
                              child: TapRegion(
                                groupId: _tapRegionGroupId,
                                onTapOutside: (_) => _closeQueueOverlay(),
                                child: _MiniAudioQueuePopover(
                                  state: state,
                                  scrollController: _queueScrollCtrl,
                                  maxWidth: maxW,
                                  maxHeight: maxH,
                                  onSelectTrack: (idx) {
                                    notifier.playQueueIndex(idx);
                                  },
                                  onClose: _closeQueueOverlay,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                  child: KonataAdaptiveTokens.isAndroid
                      ? _buildTouchCapsule(context, state)
                      : KonataPlaybackCapsule(
                          leading: _MiniCoverThumbnail(
                            cover: state.cover,
                            size: 38,
                          ),
                          title: item.title,
                          onTapInfo: _openImmersive,
                          positionSeconds: state.positionSeconds,
                          durationSeconds: state.durationSeconds,
                          isPlaying: state.isPlaying,
                          onTogglePlayPause: notifier.togglePlayPause,
                          onSeek: notifier.seekRelativeTrackSeconds,
                          leadingCenterButton: KonataAudioLoopButton(
                            icon: switch (state.loopMode) {
                              AudioLoopMode.sequence =>
                                Icons.trending_flat_rounded,
                              AudioLoopMode.loopAll => Icons.repeat_rounded,
                              AudioLoopMode.loopOne => Icons.repeat_one_rounded,
                            },
                            tooltip: '循环模式：${state.loopMode.label}',
                            highlighted:
                                state.loopMode != AudioLoopMode.sequence,
                            onTap: notifier.cycleLoopMode,
                          ),
                          onPrevious: notifier.previous,
                          onNext: notifier.next,
                          onToggleList: _toggleQueueOverlay,
                          isListActive: _queueOpen,
                          listTooltip: _queueOpen ? '收起专辑曲目' : '展开专辑曲目',
                          rightSlot: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (showSpecBadge) ...[
                                Flexible(
                                  child: KonataSpecBadge(label: specLabel),
                                ),
                                const SizedBox(width: 4),
                              ],
                              KonataVolumeControl(
                                volume: (state.volume / 100.0).clamp(0.0, 1.0),
                                isMuted: state.isMuted,
                                onVolumeChanged: (v) =>
                                    notifier.setVolume(v * 100.0),
                                onToggleMute: notifier.toggleMute,
                              ),
                              KonataCapsuleIconButton(
                                icon: Icons.open_in_full_rounded,
                                tooltip: '展开全屏流光页',
                                size: 16,
                                color: context.palette.textPrimary,
                                onTap: _openImmersive,
                              ),
                              KonataCapsuleIconButton(
                                icon: Icons.close_rounded,
                                tooltip: '停止并关闭音乐栏',
                                size: 17,
                                color: context.palette.textPrimary,
                                onTap: () {
                                  _closeQueueOverlay();
                                  notifier.stopAndClose();
                                },
                              ),
                            ],
                          ),
                        ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildTouchCapsule(BuildContext context, AudioPlaybackState state) {
    final notifier = ref.read(audioPlaybackProvider.notifier);
    return GestureDetector(
      onHorizontalDragUpdate: (details) {
        final current = ref.read(audioPlaybackProvider);
        final box = context.findRenderObject() as RenderBox?;
        if (box == null || current.durationSeconds <= 0) return;
        final local = box.globalToLocal(details.globalPosition);
        notifier.seekRelativeTrackSeconds(
          (local.dx / box.size.width).clamp(0.0, 1.0) * current.durationSeconds,
        );
      },
      child: SizedBox(
        height: KonataAdaptiveTokens.playerHeight,
        child: KonataGlassCapsule(
          child: Stack(
            children: [
              const Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: RepaintBoundary(child: _TouchAudioProgress()),
              ),
              Positioned.fill(
                child: Row(
                  children: [
                    const SizedBox(width: KonataAdaptiveTokens.safeGap),
                    GestureDetector(
                      onTap: _openImmersive,
                      behavior: HitTestBehavior.opaque,
                      child: SizedBox(
                        key: const ValueKey('mini_cover_target'),
                        width: KonataAdaptiveTokens.touchTarget,
                        height: KonataAdaptiveTokens.touchTarget,
                        child: Center(
                          child: HeroMode(
                            enabled: !ref.watch(immersiveAudioExpandedProvider),
                            child: Hero(
                              tag: 'konata_audio_cover_hero',
                              child: _MiniCoverThumbnail(cover: state.cover),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: KonataAdaptiveTokens.safeGap),
                    Expanded(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: _openImmersive,
                        onLongPress: _toggleQueueOverlay,
                        child: SizedBox(
                          key: const ValueKey('mini_title_target'),
                          height: KonataAdaptiveTokens.touchTarget,
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              state.currentItem?.title ?? '',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: KonataTheme.textStyle(
                                color: context.palette.textPrimary,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    KonataCapsuleIconButton(
                      icon: state.isPlaying
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                      tooltip: state.isPlaying ? '暂停' : '播放',
                      fixedSize: KonataAdaptiveTokens.touchTarget,
                      color: context.palette.textPrimary,
                      onTap: notifier.togglePlayPause,
                    ),
                    KonataCapsuleIconButton(
                      icon: Icons.skip_next_rounded,
                      tooltip: '下一曲',
                      fixedSize: KonataAdaptiveTokens.touchTarget,
                      color: context.palette.textPrimary,
                      onTap: notifier.next,
                    ),
                    KonataCapsuleIconButton(
                      icon: Icons.queue_music_rounded,
                      tooltip: MediaQuery.sizeOf(context).shortestSide >=
                              KonataAdaptiveTokens.tabletBreakpoint
                          ? '专辑曲目'
                          : '更多播放控制',
                      fixedSize: KonataAdaptiveTokens.touchTarget,
                      color: context.palette.textPrimary,
                      onTap: MediaQuery.sizeOf(context).shortestSide >=
                              KonataAdaptiveTokens.tabletBreakpoint
                          ? _toggleQueueOverlay
                          : _showTouchControls,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showTouchControls() {
    final notifier = ref.read(audioPlaybackProvider.notifier);
    showKonataGlassDialog<void>(
      context: context,
      builder: (dialogContext) => KonataGlassDialog(
        title: '播放控制',
        child: Wrap(
          children: [
            for (final action in <(IconData, String, VoidCallback)>[
              (Icons.skip_previous_rounded, '上一曲', notifier.previous),
              (Icons.repeat_rounded, '切换循环模式', notifier.cycleLoopMode),
              (Icons.volume_off_rounded, '切换静音', notifier.toggleMute),
              (Icons.queue_music_rounded, '专辑曲目', _toggleQueueOverlay),
              (Icons.open_in_full_rounded, '展开全屏', _openImmersive),
              (Icons.close_rounded, '停止并关闭', notifier.stopAndClose),
            ])
              KonataCapsuleIconButton(
                icon: action.$1,
                tooltip: action.$2,
                fixedSize: KonataAdaptiveTokens.touchTarget,
                color: context.palette.textPrimary,
                onTap: () {
                  Navigator.of(dialogContext).pop();
                  action.$3();
                },
              ),
          ],
        ),
      ),
    );
  }
}

class _MiniAudioQueuePopover extends StatelessWidget {
  const _MiniAudioQueuePopover({
    required this.state,
    required this.scrollController,
    required this.maxWidth,
    required this.maxHeight,
    required this.onSelectTrack,
    required this.onClose,
  });

  final AudioPlaybackState state;
  final ScrollController scrollController;
  final double maxWidth;
  final double maxHeight;
  final ValueChanged<int> onSelectTrack;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final queue = state.queue;
    final displayRows = state.buildDisplayRows(includeDetailedSubtitle: true);
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth, maxHeight: maxHeight),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(
            KonataPlaybackTokens.miniQueuePopoverRadius,
          ),
          boxShadow: [
            BoxShadow(
              color: KonataPlaybackTokens.shadowColor(p),
              blurRadius: 28,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        foregroundDecoration: BoxDecoration(
          borderRadius: BorderRadius.circular(
            KonataPlaybackTokens.miniQueuePopoverRadius,
          ),
          border: Border.all(
            color: KonataPlaybackTokens.glassBorder(p),
            width: 1,
          ),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(
            KonataPlaybackTokens.miniQueuePopoverRadius,
          ),
          child: BackdropFilter(
            filter: ImageFilter.blur(
              sigmaX: KonataPlaybackTokens.capsuleBlurSigma,
              sigmaY: KonataPlaybackTokens.capsuleBlurSigma,
            ),
            child: Container(
              decoration: BoxDecoration(
                color: KonataPlaybackTokens.popoverSurface(p),
                borderRadius: BorderRadius.circular(
                  KonataPlaybackTokens.miniQueuePopoverRadius,
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 11, 10, 8),
                    child: Row(
                      children: [
                        Icon(
                          Icons.queue_music_rounded,
                          size: 16,
                          color: p.progressFill,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '专辑曲目 (${queue.length})',
                            style: TextStyle(
                              color: p.textPrimary,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        KonataCapsuleIconButton(
                          key: const ValueKey('mini_queue_close'),
                          icon: Icons.close_rounded,
                          tooltip: '收起曲目列表 (Esc)',
                          size: 16,
                          fixedSize:
                              KonataAdaptiveTokens.isAndroid
                              ? KonataAdaptiveTokens.touchTarget
                              : null,
                          color: p.textSecondary,
                          onTap: onClose,
                        ),
                      ],
                    ),
                  ),
                  Divider(
                    height: 1,
                    thickness: 1,
                    color: KonataPlaybackTokens.glassBorder(p),
                  ),
                  Flexible(
                    child: KonataDraggableScrollbar(
                      controller: scrollController,
                      padding: const EdgeInsets.only(right: 4),
                      builder: (_, ctrl) => ListView.separated(
                        controller: ctrl,
                        shrinkWrap: true,
                        padding: const EdgeInsets.fromLTRB(10, 8, 16, 10),
                        itemCount: displayRows.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 2),
                        itemBuilder: (context, index) {
                          final row = displayRows[index];
                          final durLabel = row.duration > Duration.zero
                              ? PlaybackFormatters.formatMediaDuration(
                                  row.duration.inMilliseconds / 1000.0,
                                )
                              : '';

                          return _MiniQueueTrackTile(
                            trackPrefix: row.trackPrefix,
                            title: row.title,
                            subtitle: row.subtitle,
                            durationLabel: durLabel,
                            active: row.isActiveTrack,
                            isExpandedParent: row.isExpandedParent,
                            isSubTrack:
                                row.kind ==
                                AudioQueueDisplayRowKind.cueSubTrack,
                            onTap: () => onSelectTrack(row.targetQueueIndex),
                          );
                        },
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MiniQueueTrackTile extends StatefulWidget {
  const _MiniQueueTrackTile({
    required this.trackPrefix,
    required this.title,
    required this.subtitle,
    required this.durationLabel,
    required this.active,
    this.isExpandedParent = false,
    this.isSubTrack = false,
    required this.onTap,
  });

  final String trackPrefix;
  final String title;
  final String subtitle;
  final String durationLabel;
  final bool active;
  final bool isExpandedParent;
  final bool isSubTrack;
  final VoidCallback onTap;

  @override
  State<_MiniQueueTrackTile> createState() => _MiniQueueTrackTileState();
}

class _MiniQueueTrackTileState extends State<_MiniQueueTrackTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final active = widget.active;
    final bgColor = active
        ? p.progressFill.withValues(alpha: 0.16)
        : (_hovered ? KonataPlaybackTokens.hoverFill(p) : Colors.transparent);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          constraints: KonataAdaptiveTokens.isAndroid
              ? const BoxConstraints(
                  minHeight: KonataAdaptiveTokens.touchTarget,
                )
              : null,
          duration: const Duration(milliseconds: 140),
          padding: EdgeInsets.fromLTRB(
            widget.isSubTrack ? 26 : 10,
            widget.isSubTrack ? 6 : 8,
            10,
            widget.isSubTrack ? 6 : 8,
          ),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              SizedBox(
                width: widget.isSubTrack ? 22 : 26,
                child: active
                    ? Icon(
                        Icons.graphic_eq_rounded,
                        size: 16,
                        color: p.progressFill,
                      )
                    : (widget.trackPrefix.isEmpty
                          ? const SizedBox.shrink()
                          : Text(
                              widget.trackPrefix,
                              style: TextStyle(
                                color: widget.isExpandedParent
                                    ? p.textPrimary
                                    : (_hovered ? p.textPrimary : p.textMuted),
                                fontSize: 12,
                                fontWeight: widget.isExpandedParent
                                    ? FontWeight.w600
                                    : FontWeight.w500,
                                fontFeatures:
                                    KonataPlaybackTokens.tabularNumbers,
                              ),
                            )),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    EllipsisTextWithTooltip(
                      text: widget.title,
                      style: TextStyle(
                        color: p.textPrimary,
                        fontSize: widget.isSubTrack ? 12.5 : 13,
                        fontWeight: (active || widget.isExpandedParent)
                            ? FontWeight.w600
                            : FontWeight.w400,
                      ),
                    ),
                    if (widget.subtitle.isNotEmpty) ...[
                      const SizedBox(height: 1.5),
                      EllipsisTextWithTooltip(
                        text: widget.subtitle,
                        style: TextStyle(
                          color: active ? p.textSecondary : p.textMuted,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (widget.durationLabel.isNotEmpty) ...[
                const SizedBox(width: 10),
                Text(
                  widget.durationLabel,
                  style: TextStyle(
                    color: active ? p.textPrimary : p.textSecondary,
                    fontSize: 11.5,
                    fontFeatures: KonataPlaybackTokens.tabularNumbers,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _MiniCoverThumbnail extends ConsumerWidget {
  const _MiniCoverThumbnail({required this.cover, this.size = 38});

  final AudioCoverSource cover;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.palette;
    final loader = ref.watch(tmdbImageLoaderProvider);

    return SmartCoverAlignmentBuilder(
      cover: cover,
      loader: loader,
      builder: (context, coverAlignment) {
        Widget content;
        switch (cover) {
          case MemoryAudioCover(:final bytes):
            content = Image.memory(
              bytes,
              width: size,
              height: size,
              fit: BoxFit.cover,
              alignment: coverAlignment,
              filterQuality: FilterQuality.medium,
              gaplessPlayback: true,
            );
          case ManagedPosterAudioCover(
            :final url,
            :final workId,
            :final revision,
          ):
            content = ManagedImage(
              url,
              key: ValueKey('mini_cov_${workId}_${url}_$revision'),
              loader: loader,
              owner: workId,
              width: size,
              height: size,
              decodeWidth: 256,
              fit: BoxFit.cover,
              alignment: coverAlignment,
              errorBuilder: (_, _, _) => _fallbackTile(p),
            );
          case EmptyAudioCover():
            content = _fallbackTile(p);
        }

        return ClipRRect(
          borderRadius: BorderRadius.circular(9),
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              border: Border.all(
                color: KonataPlaybackTokens.glassBorder(p),
                width: 1,
              ),
              borderRadius: BorderRadius.circular(9),
            ),
            child: content,
          ),
        );
      },
    );
  }

  Widget _fallbackTile(KonataPalette p) {
    return Container(
      width: size,
      height: size,
      color: KonataPlaybackTokens.softFill(p),
      alignment: Alignment.center,
      child: Icon(Icons.music_note_rounded, size: 18, color: p.textSecondary),
    );
  }
}

/// 播放位置只由进度叶子订阅，毛玻璃表面与列表不随时钟重建。
class _TouchAudioProgress extends ConsumerWidget {
  const _TouchAudioProgress();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(
      audioPlaybackProvider.select(
        (s) => (s.positionSeconds, s.durationSeconds),
      ),
    );
    return LayoutBuilder(
      builder: (context, constraints) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: (details) {
          if (value.$2 <= 0 || constraints.maxWidth <= 0) return;
          ref
              .read(audioPlaybackProvider.notifier)
              .seekRelativeTrackSeconds(
                (details.localPosition.dx / constraints.maxWidth).clamp(
                      0.0,
                      1.0,
                    ) *
                    value.$2,
              );
        },
        child: SizedBox(
          key: const ValueKey('mini_progress_target'),
          height: KonataAdaptiveTokens.touchTarget,
          child: Align(
            alignment: Alignment.bottomCenter,
            child: LinearProgressIndicator(
              value: value.$2 > 0 ? (value.$1 / value.$2).clamp(0.0, 1.0) : 0,
              minHeight: KonataAdaptiveTokens.progressHeight,
              color: context.palette.progressFill,
              backgroundColor: Colors.transparent,
            ),
          ),
        ),
      ),
    );
  }
}

/// 视频收起后的常驻毛玻璃播放胶囊（左侧圆角实时视频预览、支持切后台纯音频、展开与关闭不断流）。
class _MiniVideoCapsuleBar extends ConsumerWidget {
  const _MiniVideoCapsuleBar({
    required this.request,
    required this.previewSurface,
  });

  final VideoLaunchRequest request;
  final Widget previewSurface;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.palette;
    final snap = ref.watch(
      videoPlaybackProvider(request).select(
        (s) => (
          isPlaying: s.isPlaying,
          audioOnly: s.audioOnlyMode,
          work: s.currentWork,
          episodeId: s.currentEpisode.id,
        ),
      ),
    );
    final controller = ref.read(videoPlaybackProvider(request).notifier);
    final sessionNotifier = ref.read(activeVideoSessionProvider.notifier);
    final epTitle = controller.currentEpisodeTitle;
    final workTitle = (snap.work ?? request.work).title;
    final btnSize = KonataAdaptiveTokens.isAndroid
        ? KonataAdaptiveTokens.touchTarget
        : 38.0;

    return Material(
      type: MaterialType.transparency,
      child: DefaultTextStyle.merge(
        style: const TextStyle(decoration: TextDecoration.none),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: KonataAdaptiveTokens.isAndroid
                ? KonataAdaptiveTokens.playerMaxWidth
                : KonataPlaybackTokens.miniBarMaxWidth,
          ),
          child: SizedBox(
            height: KonataAdaptiveTokens.playerHeight,
            child: KonataGlassCapsule(
              child: Stack(
                children: [
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: RepaintBoundary(
                      child: _TouchVideoMiniProgress(request: request),
                    ),
                  ),
                  Positioned.fill(
                    child: Row(
                      children: [
                        const SizedBox(width: KonataAdaptiveTokens.safeGap),
                        GestureDetector(
                          key: const ValueKey('mini_video_preview_target'),
                          behavior: HitTestBehavior.opaque,
                          onTap: sessionNotifier.expandToFull,
                          child: SizedBox(
                            height: KonataAdaptiveTokens.touchTarget,
                            child: Center(
                              child: Container(
                                width: KonataPlaybackTokens.miniVideoPreviewWidth,
                                height:
                                    KonataPlaybackTokens.miniVideoPreviewHeight,
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(
                                    KonataPlaybackTokens.miniVideoPreviewRadius,
                                  ),
                                  border: Border.all(
                                    color: KonataPlaybackTokens.glassBorder(p),
                                  ),
                                ),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(
                                    KonataPlaybackTokens.miniVideoPreviewRadius,
                                  ),
                                  child: previewSurface,
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: KonataAdaptiveTokens.safeGap),
                        Expanded(
                          child: GestureDetector(
                            key: const ValueKey('mini_video_title_target'),
                            behavior: HitTestBehavior.opaque,
                            onTap: sessionNotifier.expandToFull,
                            child: SizedBox(
                              height: KonataAdaptiveTokens.touchTarget,
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    epTitle,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: p.textPrimary,
                                      fontSize: 13.5,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  Text(
                                    snap.audioOnly
                                        ? '$workTitle · 后台纯音频'
                                        : workTitle,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: p.textSecondary,
                                      fontSize: 11,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        KonataCapsuleIconButton(
                          key: const ValueKey('mini_video_audio_only_toggle'),
                          icon: Icons.headphones_rounded,
                          tooltip: snap.audioOnly ? '恢复视频画面' : '切换后台纯音频',
                          highlighted: snap.audioOnly,
                          fixedSize: btnSize,
                          color: p.textPrimary,
                          onTap: controller.toggleAudioOnlyMode,
                        ),
                        KonataCapsuleIconButton(
                          key: const ValueKey('mini_video_play_pause'),
                          icon: snap.isPlaying
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                          tooltip: snap.isPlaying ? '暂停' : '播放',
                          fixedSize: btnSize,
                          color: p.textPrimary,
                          onTap: controller.togglePlayPause,
                        ),
                        if (controller.hasNextEpisodeAny)
                          KonataCapsuleIconButton(
                            icon: Icons.skip_next_rounded,
                            tooltip: '下一话',
                            fixedSize: btnSize,
                            color: p.textPrimary,
                            onTap: () =>
                                unawaited(controller.goToNextEpisode()),
                          ),
                        KonataCapsuleIconButton(
                          key: const ValueKey('mini_video_close'),
                          icon: Icons.close_rounded,
                          tooltip: '停止并关闭视频',
                          fixedSize: btnSize,
                          color: p.textPrimary,
                          onTap: () => unawaited(sessionNotifier.closeVideo()),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 视频小窗胶囊底部 2dp 独立进度叶子（重绘隔离，不带动胶囊与列表重建）。
class _TouchVideoMiniProgress extends ConsumerWidget {
  const _TouchVideoMiniProgress({required this.request});

  final VideoLaunchRequest request;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final timing = ref.watch(
      videoPlaybackProvider(request).select(
        (s) => (pos: s.positionSeconds, dur: s.durationSeconds),
      ),
    );
    return LayoutBuilder(
      builder: (context, constraints) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: (details) {
          if (timing.dur <= 0 || constraints.maxWidth <= 0) return;
          ref.read(videoPlaybackProvider(request).notifier).seekAbsolute(
            (details.localPosition.dx / constraints.maxWidth).clamp(0.0, 1.0) *
                timing.dur,
          );
        },
        child: SizedBox(
          height: 12,
          child: Align(
            alignment: Alignment.bottomCenter,
            child: LinearProgressIndicator(
              value: timing.dur > 0
                  ? (timing.pos / timing.dur).clamp(0.0, 1.0)
                  : 0,
              minHeight: KonataAdaptiveTokens.progressHeight,
              color: context.palette.progressFill,
              backgroundColor: Colors.transparent,
            ),
          ),
        ),
      ),
    );
  }
}
