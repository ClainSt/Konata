import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../application/playback/audio_playback_notifier.dart';
import '../../../application/playback/playback_preferences_provider.dart';
import '../../../application/playback/unified_playback_coordinator.dart';
import '../../../application/playback/video_playback_controller.dart';
import '../../../application/providers/artwork_provider.dart';
import '../../../composition/platform_composition.dart';
import '../../../domain/playback/playback_formatters.dart';
import '../../audio/smart_cover_framing.dart';
import '../../theme/konata_playback_tokens.dart';
import '../../theme/konata_theme.dart';
import '../design_system/ellipsis_text_with_tooltip.dart';
import '../managed_image.dart';
import 'konata_cd_disc_placeholder.dart';
import 'konata_playback_capsule.dart';

/// Windows 桌面主窗口「始终置顶迷你窗」形态枚举。
enum DesktopAlwaysOnTopMiniKind {
  /// 正常主窗口形态。
  none,

  /// 视频置顶迷你窗（按片源比例缩放、完整保留特效/双语字幕与悬浮播控）。
  video,

  /// 音频置顶迷你窗（紧凑全画幅封面 + 单行同步歌词 + 播控与进度条）。
  audio,
}

/// Windows 桌面置顶迷你窗运行态快照。
class DesktopAlwaysOnTopMiniState {
  /// 创建桌面置顶迷你窗状态。
  const DesktopAlwaysOnTopMiniState({
    this.kind = DesktopAlwaysOnTopMiniKind.none,
    this.restoreToExpanded = true,
  });

  /// 当前置顶迷你窗内容形态。
  final DesktopAlwaysOnTopMiniKind kind;

  /// 点击「还原主窗口」时是否恢复为全屏播放舞台（否则回到窗口内悬浮小窗）。
  final bool restoreToExpanded;

  /// 当前是否正处于桌面置顶迷你窗模式。
  bool get isActive => kind != DesktopAlwaysOnTopMiniKind.none;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other is DesktopAlwaysOnTopMiniState &&
            other.kind == kind &&
            other.restoreToExpanded == restoreToExpanded);
  }

  @override
  int get hashCode => Object.hash(kind, restoreToExpanded);
}

/// Windows 桌面置顶迷你窗统一编排控制器（协调主窗口缩放置顶、边界记忆与零重建还原）。
class DesktopAlwaysOnTopMiniController
    extends Notifier<DesktopAlwaysOnTopMiniState> {
  @override
  DesktopAlwaysOnTopMiniState build() => const DesktopAlwaysOnTopMiniState();

  /// 将桌面主窗口一键切换为视频置顶迷你窗（按真实片源比例自动计算目标尺寸）。
  Future<void> enterVideoMini({
    required bool fromExpanded,
    double? aspectRatio,
  }) async {
    final host = ref.read(konataWindowHostProvider);
    if (!host.supportsAlwaysOnTopMiniWindow) return;
    final videoSession = ref.read(activeVideoSessionProvider);
    if (!videoSession.isActive || videoSession.request == null) return;

    final ratio = (aspectRatio != null && aspectRatio.isFinite && aspectRatio > 0)
        ? aspectRatio.clamp(0.75, 2.5)
        : (16.0 / 9.0);
    final width = KonataPlaybackTokens.desktopAlwaysOnTopVideoDefaultWidth;
    final height = (width / ratio).clamp(
      KonataPlaybackTokens.desktopAlwaysOnTopVideoMinHeight,
      KonataPlaybackTokens.desktopAlwaysOnTopVideoMaxHeight,
    );

    // 先切换至不透明置顶迷你窗舞台，避免底层主界面页面在窗口缩小时触发无效布局与溢出。
    state = DesktopAlwaysOnTopMiniState(
      kind: DesktopAlwaysOnTopMiniKind.video,
      restoreToExpanded: fromExpanded,
    );
    await host.enterAlwaysOnTopMiniWindow(
      targetSize: Size(width, height),
      minimumSize: KonataPlaybackTokens.desktopAlwaysOnTopVideoMinSize,
    );
  }

  /// 将桌面主窗口一键切换为音频置顶迷你窗（紧凑方形全画幅封面 + 歌词与播控）。
  Future<void> enterAudioMini({required bool fromExpanded}) async {
    final host = ref.read(konataWindowHostProvider);
    if (!host.supportsAlwaysOnTopMiniWindow) return;
    if (!ref.read(audioPlaybackProvider).isActive) return;

    state = DesktopAlwaysOnTopMiniState(
      kind: DesktopAlwaysOnTopMiniKind.audio,
      restoreToExpanded: fromExpanded,
    );
    await host.enterAlwaysOnTopMiniWindow(
      targetSize: KonataPlaybackTokens.desktopAlwaysOnTopAudioSize,
      minimumSize: KonataPlaybackTokens.desktopAlwaysOnTopAudioMinSize,
    );
  }

  /// 退出桌面置顶迷你窗并无损还原进入前的主窗口尺寸与位置。
  Future<void> exitToMainWindow({bool? forceExpanded}) async {
    if (!state.isActive) return;
    final previous = state;
    final host = ref.read(konataWindowHostProvider);
    // 先恢复主窗口尺寸与非置顶态，再卸载迷你窗覆盖层，彻底杜绝底层页面在窄窗下闪现溢出。
    await host.exitAlwaysOnTopMiniWindow();
    if (!ref.mounted) return;
    state = const DesktopAlwaysOnTopMiniState();

    final prefs = ref.read(playbackPreferencesProvider);
    if (previous.kind == DesktopAlwaysOnTopMiniKind.video) {
      final videoSession = ref.read(activeVideoSessionProvider);
      if (videoSession.isActive) {
        final wantExpanded =
            forceExpanded ??
            (previous.restoreToExpanded || !prefs.videoFloatingMiniEnabled);
        if (wantExpanded) {
          ref.read(activeVideoSessionProvider.notifier).expandToFull();
        } else {
          await ref.read(activeVideoSessionProvider.notifier).collapseToMini();
        }
      }
    } else if (previous.kind == DesktopAlwaysOnTopMiniKind.audio) {
      if (ref.read(audioPlaybackProvider).isActive) {
        final wantExpanded =
            forceExpanded ??
            (previous.restoreToExpanded || !prefs.audioFloatingMiniEnabled);
        ref.read(immersiveAudioExpandedProvider.notifier).state = wantExpanded;
      }
    }
  }

  /// 停止当前活跃播放并同步还原主窗口。
  Future<void> closePlaybackAndExit() async {
    final activeKind = state.kind;
    if (activeKind == DesktopAlwaysOnTopMiniKind.none) return;
    final host = ref.read(konataWindowHostProvider);
    await host.exitAlwaysOnTopMiniWindow();
    if (!ref.mounted) return;
    state = const DesktopAlwaysOnTopMiniState();
    if (activeKind == DesktopAlwaysOnTopMiniKind.video) {
      await ref.read(activeVideoSessionProvider.notifier).closeVideo();
    } else if (activeKind == DesktopAlwaysOnTopMiniKind.audio) {
      await ref.read(audioPlaybackProvider.notifier).stopAndClose();
    }
  }

  /// 当播放会话意外结束或被其他入口关闭时自动退出置顶迷你窗并还原主窗口，防止滞留空白小窗。
  Future<void> handleActiveSessionEnded() async {
    if (!state.isActive) return;
    final host = ref.read(konataWindowHostProvider);
    await host.exitAlwaysOnTopMiniWindow();
    if (!ref.mounted) return;
    state = const DesktopAlwaysOnTopMiniState();
  }
}

/// 全局 Windows 桌面置顶迷你窗模式状态 Provider。
final desktopAlwaysOnTopMiniModeProvider =
    NotifierProvider<
      DesktopAlwaysOnTopMiniController,
      DesktopAlwaysOnTopMiniState
    >(DesktopAlwaysOnTopMiniController.new);

/// Windows 桌面主窗口置顶迷你窗独占舞台（视频原画含字幕 / 音频全画幅封面 + 同步歌词）。
///
/// 核心不变量：
/// - 视频模式复用 `GlobalObjectKey(videoRequest)` 硬件渲染表面，`miniPreview: false` 完整保留特效与双语字幕；
/// - 主体包裹 `KonataWindowHost.buildDragToMoveArea`，按住任意空白区域即可拖至任意屏幕角落；
/// - 高频播放进度与同步歌词全部下沉至独立叶子控件，鼠标离开后隐藏视频浮层实现纯净零干扰观影。
class DesktopAlwaysOnTopMiniStage extends ConsumerStatefulWidget {
  /// 创建桌面置顶迷你窗舞台。
  const DesktopAlwaysOnTopMiniStage({
    super.key,
    required this.kind,
    this.videoRequest,
    this.sharedVideoSurface,
  });

  /// 当前迷你窗内容类型（视频或音频）。
  final DesktopAlwaysOnTopMiniKind kind;

  /// 视频模式关联的播放请求。
  final VideoLaunchRequest? videoRequest;

  /// 视频模式复用的共享硬件纹理/原生表面控件。
  final Widget? sharedVideoSurface;

  @override
  ConsumerState<DesktopAlwaysOnTopMiniStage> createState() =>
      _DesktopAlwaysOnTopMiniStageState();
}

class _DesktopAlwaysOnTopMiniStageState
    extends ConsumerState<DesktopAlwaysOnTopMiniStage> {
  final ValueNotifier<bool> _hoveredNotifier = ValueNotifier<bool>(false);
  final FocusNode _focusNode = FocusNode(debugLabel: 'desktop_mini_stage');

  @override
  void dispose() {
    _hoveredNotifier.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      unawaited(
        ref.read(desktopAlwaysOnTopMiniModeProvider.notifier).exitToMainWindow(),
      );
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.space) {
      if (widget.kind == DesktopAlwaysOnTopMiniKind.video &&
          widget.videoRequest != null) {
        ref
            .read(videoPlaybackProvider(widget.videoRequest!).notifier)
            .togglePlayPause();
        return KeyEventResult.handled;
      }
      if (widget.kind == DesktopAlwaysOnTopMiniKind.audio) {
        unawaited(ref.read(audioPlaybackProvider.notifier).togglePlayPause());
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final host = ref.watch(konataWindowHostProvider);
    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: _handleKeyEvent,
      child: MouseRegion(
        onEnter: (_) => _hoveredNotifier.value = true,
        onExit: (_) => _hoveredNotifier.value = false,
        child: widget.kind == DesktopAlwaysOnTopMiniKind.video
            ? _buildVideoMiniStage(context, host)
            : _buildAudioMiniStage(context, host),
      ),
    );
  }

  Widget _buildVideoMiniStage(BuildContext context, KonataWindowHost host) {
    final req = widget.videoRequest;
    if (req == null) {
      return const ColoredBox(color: KonataPlaybackTokens.cinemaPureBlack);
    }
    final videoMiniEnabled = ref.watch(
      playbackPreferencesProvider.select((s) => s.videoFloatingMiniEnabled),
    );
    final titleText = ref.watch(
      videoPlaybackProvider(req).select((s) {
        final ep = s.currentEpisode;
        final epTitle = ep.title?.trim() ?? '';
        final epLabel = epTitle.isNotEmpty
            ? epTitle
            : (ep.episodeNumber != null ? '第 ${ep.episodeNumber} 集' : '');
        final workTitle = s.currentWork?.title ?? req.work.title;
        return epLabel.isNotEmpty ? '$workTitle · $epLabel' : workTitle;
      }),
    );

    return ColoredBox(
      key: const ValueKey('desktop_always_on_top_video_stage'),
      color: KonataPlaybackTokens.cinemaPureBlack,
      child: Listener(
        onPointerSignal: (signal) {
          if (signal is PointerScrollEvent) {
            final delta = signal.scrollDelta.dy < 0 ? 5.0 : -5.0;
            ref.read(videoPlaybackProvider(req).notifier).adjustVolume(delta);
          }
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            host.buildDragToMoveArea(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onDoubleTap: () => unawaited(
                  ref
                      .read(desktopAlwaysOnTopMiniModeProvider.notifier)
                      .exitToMainWindow(),
                ),
                child:
                    widget.sharedVideoSurface ??
                    const ColoredBox(
                      color: KonataPlaybackTokens.cinemaPureBlack,
                    ),
              ),
            ),
            ValueListenableBuilder<bool>(
              valueListenable: _hoveredNotifier,
              builder: (context, hovered, _) {
                return IgnorePointer(
                  ignoring: !hovered,
                  child: AnimatedOpacity(
                    opacity: hovered ? 1.0 : 0.0,
                    duration: KonataPlaybackTokens.desktopMiniChromeFadeDuration,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        _buildMiniTopBar(
                          title: titleText,
                          showBackToInWindowButton: videoMiniEnabled,
                        ),
                        _DesktopMiniVideoBottomBarLeaf(request: req),
                      ],
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAudioMiniStage(BuildContext context, KonataWindowHost host) {
    final audioMiniEnabled = ref.watch(
      playbackPreferencesProvider.select((s) => s.audioFloatingMiniEnabled),
    );
    final trackMeta = ref.watch(
      audioPlaybackProvider.select(
        (s) => (
          title: s.currentItem?.title ?? '未在播放',
          subtitle: s.currentItem?.displaySubtitle ?? '',
        ),
      ),
    );

    return ColoredBox(
      key: const ValueKey('desktop_always_on_top_audio_stage'),
      color: KonataPlaybackTokens.auroraCanvasDark,
      child: Stack(
        fit: StackFit.expand,
        children: [
          host.buildDragToMoveArea(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onDoubleTap: () => unawaited(
                ref
                    .read(desktopAlwaysOnTopMiniModeProvider.notifier)
                    .exitToMainWindow(),
              ),
              child: const _DesktopMiniAudioCoverLeaf(),
            ),
          ),
          // 底部平滑暗渐变遮罩，保证亮色/暗色封面上的曲名、单行歌词与播控按钮始终清晰可读。
          const IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  stops: [0.0, 0.35, 0.68, 1.0],
                  colors: [
                    KonataPlaybackTokens.desktopMiniTopScrimStart,
                    Colors.transparent,
                    KonataPlaybackTokens.desktopMiniAudioScrimMid,
                    KonataPlaybackTokens.desktopMiniBottomScrimEnd,
                  ],
                ),
              ),
            ),
          ),
          Column(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              ValueListenableBuilder<bool>(
                valueListenable: _hoveredNotifier,
                builder: (context, hovered, _) {
                  return AnimatedOpacity(
                    opacity: hovered ? 1.0 : 0.72,
                    duration: KonataPlaybackTokens.desktopMiniChromeFadeDuration,
                    child: _buildMiniTopBar(
                      title: '',
                      showGradient: false,
                      showBackToInWindowButton: audioMiniEnabled,
                    ),
                  );
                },
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    EllipsisTextWithTooltip(
                      text: trackMeta.title,
                      style: const TextStyle(
                        color: KonataPlaybackTokens.osdTextPrimary,
                        fontSize: KonataTheme.fontSizeBody,
                        fontWeight: FontWeight.w700,
                        height: 1.2,
                      ),
                    ),
                    const SizedBox(height: 2),
                    _DesktopMiniAudioLyricOrSubtitleLeaf(
                      fallbackSubtitle: trackMeta.subtitle,
                    ),
                    const SizedBox(height: 6),
                    const _DesktopMiniAudioProgressLeaf(),
                    const SizedBox(height: 4),
                    const _DesktopMiniAudioControlsLeaf(),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildMiniTopBar({
    required String title,
    required bool showBackToInWindowButton,
    bool showGradient = true,
  }) {
    final miniCtrl = ref.read(desktopAlwaysOnTopMiniModeProvider.notifier);
    final bar = Padding(
      padding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
      child: Row(
        children: [
          if (title.isNotEmpty)
            Expanded(
              child: EllipsisTextWithTooltip(
                text: title,
                style: const TextStyle(
                  color: KonataPlaybackTokens.osdTextPrimary,
                  fontSize: KonataTheme.fontSizeCaption,
                  fontWeight: FontWeight.w600,
                ),
              ),
            )
          else
            const Spacer(),
          if (showBackToInWindowButton)
            KonataCapsuleIconButton(
              key: const ValueKey('desktop_mini_back_to_in_window_button'),
              icon: Icons.picture_in_picture_rounded,
              tooltip: '还原主窗口并保持窗内小窗',
              color: KonataPlaybackTokens.osdTextPrimary,
              size: 16,
              fixedSize: 30,
              padding: EdgeInsets.zero,
              onTap: () => unawaited(
                miniCtrl.exitToMainWindow(forceExpanded: false),
              ),
            ),
          KonataCapsuleIconButton(
            key: const ValueKey('desktop_mini_restore_button'),
            icon: Icons.open_in_full_rounded,
            tooltip: '还原主窗口 (Esc)',
            color: KonataPlaybackTokens.osdTextPrimary,
            size: 16,
            fixedSize: 30,
            padding: EdgeInsets.zero,
            onTap: () => unawaited(miniCtrl.exitToMainWindow()),
          ),
          KonataCapsuleIconButton(
            key: const ValueKey('desktop_mini_close_button'),
            icon: Icons.close_rounded,
            tooltip: '停止并关闭',
            color: KonataPlaybackTokens.osdTextPrimary,
            size: 16,
            fixedSize: 30,
            padding: EdgeInsets.zero,
            onTap: () => unawaited(miniCtrl.closePlaybackAndExit()),
          ),
        ],
      ),
    );
    if (!showGradient) return bar;
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            KonataPlaybackTokens.desktopMiniTopScrimStart,
            Colors.transparent,
          ],
        ),
      ),
      child: bar,
    );
  }
}

/// 视频置顶迷你窗底部独立进度与播控叶子控件（隔离高频时间刷新）。
class _DesktopMiniVideoBottomBarLeaf extends ConsumerWidget {
  const _DesktopMiniVideoBottomBarLeaf({required this.request});

  final VideoLaunchRequest request;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final snap = ref.watch(
      videoPlaybackProvider(request).select(
        (s) => (
          isPlaying: s.isPlaying,
          isMuted: s.isMuted,
          pos: s.positionSeconds,
          dur: s.durationSeconds,
        ),
      ),
    );
    final ctrl = ref.read(videoPlaybackProvider(request).notifier);
    final ratio = snap.dur > 0 ? (snap.pos / snap.dur).clamp(0.0, 1.0) : 0.0;

    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.transparent,
            KonataPlaybackTokens.desktopMiniBottomScrimEnd,
          ],
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 10, 10, 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _DesktopMiniSlimScrubber(
              value: ratio,
              onScrub: snap.dur > 0
                  ? (r) => ctrl.seekAbsolute(r * snap.dur)
                  : null,
            ),
            const SizedBox(height: 2),
            Row(
              children: [
                KonataCapsuleIconButton(
                  key: const ValueKey('desktop_mini_video_play_pause'),
                  icon: snap.isPlaying
                      ? Icons.pause_rounded
                      : Icons.play_arrow_rounded,
                  tooltip: snap.isPlaying ? '暂停 (Space)' : '播放 (Space)',
                  color: KonataPlaybackTokens.osdTextPrimary,
                  size: 19,
                  fixedSize: 30,
                  padding: EdgeInsets.zero,
                  onTap: ctrl.togglePlayPause,
                ),
                KonataCapsuleIconButton(
                  key: const ValueKey('desktop_mini_video_mute'),
                  icon: snap.isMuted
                      ? Icons.volume_off_rounded
                      : Icons.volume_up_rounded,
                  tooltip: snap.isMuted ? '取消静音' : '静音',
                  color: KonataPlaybackTokens.osdTextSecondary,
                  size: 16,
                  fixedSize: 28,
                  padding: EdgeInsets.zero,
                  onTap: ctrl.toggleMute,
                ),
                const Spacer(),
                Text(
                  '${PlaybackFormatters.formatMediaDuration(snap.pos)} / ${PlaybackFormatters.formatMediaDuration(snap.dur)}',
                  style: const TextStyle(
                    color: KonataPlaybackTokens.osdTextSecondary,
                    fontSize: KonataTheme.fontSizeMicro,
                    fontFeatures: KonataPlaybackTokens.tabularNumbers,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 音频置顶迷你窗全画幅封面叶子组件（复用人像防裁头智能取景）。
class _DesktopMiniAudioCoverLeaf extends ConsumerWidget {
  const _DesktopMiniAudioCoverLeaf();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cover = ref.watch(audioPlaybackProvider.select((s) => s.cover));
    final loader = ref.watch(tmdbImageLoaderProvider);
    return SmartCoverAlignmentBuilder(
      cover: cover,
      loader: loader,
      builder: (context, coverAlignment) {
        switch (cover) {
          case MemoryAudioCover(:final bytes):
            return Image.memory(
              bytes,
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
            return ManagedImage(
              url,
              key: ValueKey('desktop_mini_audio_cov_${workId}_${url}_$revision'),
              loader: loader,
              owner: workId,
              fit: BoxFit.cover,
              alignment: coverAlignment,
              decodeWidth: KonataPlaybackTokens.albumCoverDecodeWidth,
              errorBuilder: (_, _, _) => const KonataCdDiscPlaceholder(),
            );
          case EmptyAudioCover():
            return const KonataCdDiscPlaceholder();
        }
      },
    );
  }
}

/// 音频置顶迷你窗单行实时歌词或副标题叶子组件（仅订阅歌词索引变更）。
class _DesktopMiniAudioLyricOrSubtitleLeaf extends ConsumerWidget {
  const _DesktopMiniAudioLyricOrSubtitleLeaf({required this.fallbackSubtitle});

  final String fallbackSubtitle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lyricLine = ref.watch(
      audioPlaybackProvider.select((s) {
        final lines = s.lrcDocument?.lines;
        if (lines == null || lines.isEmpty) return '';
        final idx = s.activeLyricIndex < 0
            ? 0
            : s.activeLyricIndex.clamp(0, lines.length - 1);
        return lines[idx].primaryText.trim();
      }),
    );
    final display = lyricLine.isNotEmpty ? lyricLine : fallbackSubtitle;
    if (display.isEmpty) return const SizedBox.shrink();
    return Text(
      display,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(
        color: KonataPlaybackTokens.osdTextSecondary,
        fontSize: KonataTheme.fontSizeCaption,
        height: 1.25,
      ),
    );
  }
}

/// 音频置顶迷你窗进度条叶子控件。
class _DesktopMiniAudioProgressLeaf extends ConsumerWidget {
  const _DesktopMiniAudioProgressLeaf();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final snap = ref.watch(
      audioPlaybackProvider.select(
        (s) => (pos: s.positionSeconds, dur: s.durationSeconds),
      ),
    );
    final notifier = ref.read(audioPlaybackProvider.notifier);
    final ratio = snap.dur > 0 ? (snap.pos / snap.dur).clamp(0.0, 1.0) : 0.0;
    return _DesktopMiniSlimScrubber(
      value: ratio,
      onScrub: snap.dur > 0
          ? (r) => unawaited(notifier.seekRelativeTrackSeconds(r * snap.dur))
          : null,
    );
  }
}

/// 音频置顶迷你窗紧凑三键播控叶子控件。
class _DesktopMiniAudioControlsLeaf extends ConsumerWidget {
  const _DesktopMiniAudioControlsLeaf();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isPlaying = ref.watch(
      audioPlaybackProvider.select((s) => s.isPlaying),
    );
    final notifier = ref.read(audioPlaybackProvider.notifier);
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        KonataCapsuleIconButton(
          key: const ValueKey('desktop_mini_audio_prev'),
          icon: Icons.skip_previous_rounded,
          tooltip: '上一首',
          color: KonataPlaybackTokens.osdTextPrimary,
          size: 20,
          fixedSize: 34,
          padding: EdgeInsets.zero,
          onTap: () => unawaited(notifier.previous()),
        ),
        const SizedBox(width: 8),
        KonataCapsuleIconButton(
          key: const ValueKey('desktop_mini_audio_play_pause'),
          icon: isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
          tooltip: isPlaying ? '暂停 (Space)' : '播放 (Space)',
          color: KonataPlaybackTokens.osdTextPrimary,
          size: 24,
          fixedSize: 38,
          padding: EdgeInsets.zero,
          onTap: () => unawaited(notifier.togglePlayPause()),
        ),
        const SizedBox(width: 8),
        KonataCapsuleIconButton(
          key: const ValueKey('desktop_mini_audio_next'),
          icon: Icons.skip_next_rounded,
          tooltip: '下一首',
          color: KonataPlaybackTokens.osdTextPrimary,
          size: 20,
          fixedSize: 34,
          padding: EdgeInsets.zero,
          onTap: () => unawaited(notifier.next()),
        ),
      ],
    );
  }
}

/// 桌面置顶迷你窗专用极细可点击/拖拽进度条。
class _DesktopMiniSlimScrubber extends StatelessWidget {
  const _DesktopMiniSlimScrubber({required this.value, required this.onScrub});

  final double value;
  final ValueChanged<double>? onScrub;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        void emitAt(double dx) {
          if (onScrub == null || width <= 0) return;
          onScrub!((dx / width).clamp(0.0, 1.0));
        }

        return MouseRegion(
          cursor: onScrub != null
              ? SystemMouseCursors.click
              : SystemMouseCursors.basic,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) => emitAt(d.localPosition.dx),
            onHorizontalDragUpdate: (d) => emitAt(d.localPosition.dx),
            child: SizedBox(
              height: 12,
              child: Center(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(KonataTheme.radiusPill),
                  child: SizedBox(
                    height: 3,
                    width: double.infinity,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        const ColoredBox(
                          color: KonataPlaybackTokens.capsuleProgressTrack,
                        ),
                        FractionallySizedBox(
                          alignment: Alignment.centerLeft,
                          widthFactor: value.clamp(0.0, 1.0),
                          child: const ColoredBox(
                            color: KonataPlaybackTokens.capsuleProgressFill,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
