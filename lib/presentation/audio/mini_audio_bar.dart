import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/playback/audio_playback_notifier.dart';
import '../../application/playback/playback_preferences_provider.dart';
import '../../application/providers/artwork_provider.dart';
import '../../domain/playback/playback_formatters.dart';
import '../theme/konata_palette.dart';
import '../theme/konata_playback_tokens.dart';
import '../widgets/design_system/ellipsis_text_with_tooltip.dart';
import '../widgets/design_system/konata_draggable_scrollbar.dart';
import '../widgets/managed_image.dart';
import '../widgets/playback/konata_playback_capsule.dart';
import '../widgets/playback/konata_spec_badge.dart';
import '../widgets/playback/konata_volume_control.dart';
import 'immersive_audio_page.dart';
import 'smart_cover_framing.dart';

/// 当持久迷你音频底栏处于可视状态时，供底部滚动视图预留防遮挡留白的高度 Provider。
final miniAudioBottomClearanceProvider = Provider<double>((ref) {
  final audio = ref.watch(audioPlaybackProvider);
  final videoActive = ref.watch(videoPlaybackActiveProvider);
  final expanded = ref.watch(immersiveAudioExpandedProvider);
  final visible = audio.isActive && !videoActive && !expanded;
  return visible ? KonataPlaybackTokens.miniBarClearanceHeight : 0.0;
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
        children: [widget.child, const _GlobalAudioOverlayLayer()],
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

class _GlobalAudioOverlayLayer extends ConsumerWidget {
  const _GlobalAudioOverlayLayer();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final audioState = ref.watch(audioPlaybackProvider);
    final videoActive = ref.watch(videoPlaybackActiveProvider);
    final expanded = ref.watch(immersiveAudioExpandedProvider);

    if (!audioState.isActive || videoActive) {
      return const SizedBox.shrink();
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        // 持久浮动毛玻璃迷你底栏（沉浸页未展开时显示）
        AnimatedPositioned(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          left: KonataPlaybackTokens.miniBarHorizontalInset,
          right: KonataPlaybackTokens.miniBarHorizontalInset,
          bottom: expanded
              ? -(KonataPlaybackTokens.miniBarHeight + 36)
              : KonataPlaybackTokens.miniBarBottomInset,
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 180),
            opacity: expanded ? 0.0 : 1.0,
            child: IgnorePointer(
              ignoring: expanded,
              child: const Center(child: MiniAudioBar()),
            ),
          ),
        ),
        // 全屏流光倒影沉浸音频页
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 260),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          child: expanded
              ? const ImmersiveAudioPage(key: ValueKey('immersive_audio'))
              : const SizedBox.shrink(),
        ),
      ],
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

    final state = ref.watch(audioPlaybackProvider);
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
                  child: KonataPlaybackCapsule(
                    leading: _MiniCoverThumbnail(cover: state.cover, size: 38),
                    title: item.title,
                    onTapInfo: _openImmersive,
                    positionSeconds: state.positionSeconds,
                    durationSeconds: state.durationSeconds,
                    isPlaying: state.isPlaying,
                    onTogglePlayPause: notifier.togglePlayPause,
                    onSeek: notifier.seekRelativeTrackSeconds,
                    leadingCenterButton: KonataAudioLoopButton(
                      icon: switch (state.loopMode) {
                        AudioLoopMode.sequence => Icons.trending_flat_rounded,
                        AudioLoopMode.loopAll => Icons.repeat_rounded,
                        AudioLoopMode.loopOne => Icons.repeat_one_rounded,
                      },
                      tooltip: '循环模式：${state.loopMode.label}',
                      highlighted: state.loopMode != AudioLoopMode.sequence,
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
                          Flexible(child: KonataSpecBadge(label: specLabel)),
                          const SizedBox(width: 4),
                        ],
                        KonataVolumeControl(
                          volume: (state.volume / 100.0).clamp(0.0, 1.0),
                          isMuted: state.isMuted,
                          onVolumeChanged: (v) => notifier.setVolume(v * 100.0),
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
                          icon: Icons.close_rounded,
                          tooltip: '收起曲目列表 (Esc)',
                          size: 16,
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
