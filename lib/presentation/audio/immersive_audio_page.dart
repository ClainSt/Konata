import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../../application/playback/audio_playback_notifier.dart';
import '../../application/playback/playback_preferences_provider.dart';
import '../../application/providers/artwork_provider.dart';
import '../../domain/playback/cue_and_lrc_parser.dart';
import '../../domain/playback/playback_formatters.dart';
import '../shell/window_controls.dart';
import '../theme/konata_palette.dart';
import '../theme/konata_playback_tokens.dart';
import '../widgets/design_system/ellipsis_text_with_tooltip.dart';
import '../widgets/design_system/konata_draggable_scrollbar.dart';
import '../widgets/design_system/konata_segmented_capsule.dart';
import '../widgets/managed_image.dart';
import '../widgets/playback/konata_playback_capsule.dart';
import '../widgets/playback/konata_spec_badge.dart';
import '../widgets/playback/konata_volume_control.dart';

enum _ImmersiveRightPane { lyrics, queue }

/// 全屏流光倒影 CD / 无损音频播放器页面。
///
/// 特性：
/// - `RepaintBoundary` 隔离的封面高饱和流光主色采样 + 超大半径高斯模糊背景；
/// - 居中偏上的 336px 圆角正方形专辑封面 + `ShaderMask` 垂直镜像倒影（零冗余重复文字堆砌）；
/// - 无框透明歌词与专辑曲目双视图（由底栏 `☰` 键切换 + `KonataSmoothSectionSwitcher` 过渡 + 上下边缘渐隐）；
/// - 与内置视频页 / 迷你底栏 100% 同源的单层悬浮毛玻璃播控胶囊 [KonataPlaybackCapsule]。
class ImmersiveAudioPage extends ConsumerStatefulWidget {
  /// 创建全屏流光音频页。
  const ImmersiveAudioPage({super.key});

  @override
  ConsumerState<ImmersiveAudioPage> createState() => _ImmersiveAudioPageState();
}

class _ImmersiveAudioPageState extends ConsumerState<ImmersiveAudioPage> {
  final FocusNode _focusNode = FocusNode(debugLabel: 'immersive_audio_focus');
  final ScrollController _lyricScrollCtrl = ScrollController();
  final ScrollController _queueScrollCtrl = ScrollController();

  _ImmersiveRightPane _pane = _ImmersiveRightPane.lyrics;
  bool _userPinnedPane = false;
  bool _isUserScrollingLyrics = false;
  Timer? _scrollResetTimer;
  List<GlobalKey> _lyricKeys = const [];
  String? _lastItemId;
  int _lastActiveLyricIndex = -1;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _scrollResetTimer?.cancel();
    _focusNode.dispose();
    _lyricScrollCtrl.dispose();
    _queueScrollCtrl.dispose();
    super.dispose();
  }

  void _collapseToMiniBar() {
    ref.read(immersiveAudioExpandedProvider.notifier).state = false;
  }

  void _syncLyricKeys(LrcDocument? doc) {
    final len = doc?.lines.length ?? 0;
    if (_lyricKeys.length != len) {
      _lyricKeys = List<GlobalKey>.generate(len, (_) => GlobalKey());
    }
  }

  void _onUserLyricScrollActivity() {
    if (!_isUserScrollingLyrics) {
      setState(() => _isUserScrollingLyrics = true);
    }
    _scrollResetTimer?.cancel();
    _scrollResetTimer = Timer(
      KonataPlaybackTokens.lyricUserScrollResetDelay,
      () {
        if (!mounted) return;
        setState(() => _isUserScrollingLyrics = false);
        _scrollToActiveLyric(animated: true);
      },
    );
  }

  void _scrollToActiveLyric({bool animated = true}) {
    final idx = _lastActiveLyricIndex;
    if (idx < 0 || idx >= _lyricKeys.length) return;
    final ctx = _lyricKeys[idx].currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(
        ctx,
        alignment: 0.38,
        duration: animated ? const Duration(milliseconds: 360) : Duration.zero,
        curve: Curves.easeOutCubic,
      );
      return;
    }
    if (_lyricScrollCtrl.hasClients && _lyricKeys.isNotEmpty) {
      final estRatio = idx / _lyricKeys.length;
      final targetOffset =
          (estRatio * _lyricScrollCtrl.position.maxScrollExtent).clamp(
            0.0,
            _lyricScrollCtrl.position.maxScrollExtent,
          );
      if (animated) {
        _lyricScrollCtrl.animateTo(
          targetOffset,
          duration: const Duration(milliseconds: 360),
          curve: Curves.easeOutCubic,
        );
      } else {
        _lyricScrollCtrl.jumpTo(targetOffset);
      }
    }
  }

  KeyEventResult _handleKeyEvent(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final notifier = ref.read(audioPlaybackProvider.notifier);
    final state = ref.read(audioPlaybackProvider);

    if (key == LogicalKeyboardKey.escape) {
      _collapseToMiniBar();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.space) {
      notifier.togglePlayPause();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      notifier.seekRelativeTrackSeconds(state.positionSeconds - 5.0);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      notifier.seekRelativeTrackSeconds(state.positionSeconds + 5.0);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyM) {
      notifier.toggleMute();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(audioPlaybackProvider);
    final notifier = ref.read(audioPlaybackProvider.notifier);
    final item = state.currentItem;
    if (item == null) return const SizedBox.shrink();

    final lrc = state.lrcDocument;
    final hasLyrics = lrc != null && lrc.lines.isNotEmpty;
    if (_lastItemId != item.id) {
      _lastItemId = item.id;
      _isUserScrollingLyrics = false;
      _scrollResetTimer?.cancel();
    }
    final effectivePane = _userPinnedPane
        ? _pane
        : (hasLyrics ? _ImmersiveRightPane.lyrics : _ImmersiveRightPane.queue);

    _syncLyricKeys(lrc);
    if (state.activeLyricIndex != _lastActiveLyricIndex) {
      _lastActiveLyricIndex = state.activeLyricIndex;
      if (!_isUserScrollingLyrics &&
          effectivePane == _ImmersiveRightPane.lyrics) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && !_isUserScrollingLyrics) {
            _scrollToActiveLyric(animated: true);
          }
        });
      }
    }

    final screenWidth = MediaQuery.sizeOf(context).width;
    final isWide = screenWidth >= 820;

    final specLabel = state.audioCodecLabel.isNotEmpty
        ? (state.sampleRateAndBitDepthLabel.isNotEmpty
              ? '${state.audioCodecLabel} · ${state.sampleRateAndBitDepthLabel}'
              : state.audioCodecLabel)
        : (state.bitrateLabel.isNotEmpty ? state.bitrateLabel : '');

    final rightPaneBody = KonataSmoothSectionSwitcher(
      switchKey: effectivePane,
      alignment: Alignment.center,
      child: effectivePane == _ImmersiveRightPane.lyrics
          ? KeyedSubtree(
              key: const ValueKey('immersive_lyrics_pane'),
              child: _buildLyricsViewport(lrc, state, notifier),
            )
          : KeyedSubtree(
              key: const ValueKey('immersive_queue_pane'),
              child: _buildQueueViewport(state, notifier),
            ),
    );

    final p = context.palette;

    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: _handleKeyEvent,
      child: Material(
        color: KonataPlaybackTokens.auroraCanvas(p),
        child: Stack(
          fit: StackFit.expand,
          children: [
            // 高饱和封面主色采样 + 超大半径流光动态背景（RepaintBoundary 隔离歌词帧重绘）
            RepaintBoundary(child: _AmbientFlowBackdrop(cover: state.cover)),
            // 内容前景色调与安全边距层
            SafeArea(
              child: Column(
                children: [
                  _buildTopBar(item, state),
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(
                        isWide ? 48 : 20,
                        8,
                        isWide ? 48 : 20,
                        10,
                      ),
                      child: isWide
                          ? Row(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                Expanded(
                                  flex: 5,
                                  child: Align(
                                    alignment: const Alignment(0, -0.10),
                                    child: _CoverAndReflectionColumn(
                                      cover: state.cover,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 44),
                                Expanded(flex: 6, child: rightPaneBody),
                              ],
                            )
                          : rightPaneBody,
                    ),
                  ),
                  // 底部居中同源单层悬浮毛玻璃播控胶囊
                  Padding(
                    padding: const EdgeInsets.only(
                      left: 24,
                      right: 24,
                      bottom: KonataPlaybackTokens.capsuleBottomOffset,
                    ),
                    child: KonataPlaybackCapsule(
                      leading: _ImmersiveMicroCover(cover: state.cover),
                      title: item.title,
                      positionSeconds: state.positionSeconds,
                      durationSeconds: state.durationSeconds,
                      isPlaying: state.isPlaying,
                      onTogglePlayPause: notifier.togglePlayPause,
                      onSeek: notifier.seekRelativeTrackSeconds,
                      onPrevious: notifier.previous,
                      onNext: notifier.next,
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
                      trailingCenterButtons: [
                        KonataCapsuleIconButton(
                          icon: Icons.queue_music_rounded,
                          tooltip: '专辑曲目列表',
                          color: p.textPrimary,
                          size: 19,
                          fixedSize:
                              KonataPlaybackTokens.immersiveSwitchButtonSize,
                          borderRadius:
                              KonataPlaybackTokens.immersiveSwitchButtonRadius,
                          padding: EdgeInsets.zero,
                          highlighted:
                              effectivePane == _ImmersiveRightPane.queue,
                          highlightColor: p.textPrimary,
                          highlightBgColor: KonataPlaybackTokens.activePillBg(
                            p,
                          ),
                          showHighlightBorder: false,
                          onTap: () {
                            setState(() {
                              _pane = _ImmersiveRightPane.queue;
                              _userPinnedPane = true;
                            });
                          },
                        ),
                        const SizedBox(width: 2),
                        KonataCapsuleIconButton(
                          icon: Icons.lyrics_rounded,
                          tooltip: '同步歌词',
                          color: p.textPrimary,
                          size: 18,
                          fixedSize:
                              KonataPlaybackTokens.immersiveSwitchButtonSize,
                          borderRadius:
                              KonataPlaybackTokens.immersiveSwitchButtonRadius,
                          padding: EdgeInsets.zero,
                          highlighted:
                              effectivePane == _ImmersiveRightPane.lyrics,
                          highlightColor: p.textPrimary,
                          highlightBgColor: KonataPlaybackTokens.activePillBg(
                            p,
                          ),
                          showHighlightBorder: false,
                          onTap: () {
                            setState(() {
                              _pane = _ImmersiveRightPane.lyrics;
                              _userPinnedPane = true;
                            });
                          },
                        ),
                      ],
                      rightSlot: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (specLabel.isNotEmpty &&
                              screenWidth >=
                                  KonataPlaybackTokens
                                      .miniBarHideBadgeBreakpoint) ...[
                            Flexible(child: KonataSpecBadge(label: specLabel)),
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
                            icon: Icons.keyboard_arrow_down_rounded,
                            tooltip: '收起为迷你底栏 (Esc)',
                            color: p.textPrimary,
                            size: 20,
                            onTap: _collapseToMiniBar,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar(AudioQueueItem item, AudioPlaybackState state) {
    final p = context.palette;
    final isWindows =
        !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

    Widget headerRow = SizedBox(
      height: 52,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            IconButton(
              tooltip: '收起为迷你底栏 (Esc)',
              onPressed: _collapseToMiniBar,
              icon: Icon(
                Icons.keyboard_arrow_down_rounded,
                size: 26,
                color: p.textPrimary,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  EllipsisTextWithTooltip(
                    text: item.work.title,
                    style: TextStyle(
                      color: p.textPrimary,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (item.albumTitle.isNotEmpty &&
                      item.albumTitle != item.work.title)
                    EllipsisTextWithTooltip(
                      text: item.albumTitle,
                      style: TextStyle(color: p.textSecondary, fontSize: 11.5),
                    ),
                ],
              ),
            ),
            if (isWindows) ...[
              const SizedBox(width: 8),
              const WindowControls(),
            ],
          ],
        ),
      ),
    );

    if (isWindows) {
      headerRow = DragToMoveArea(child: headerRow);
    }
    return headerRow;
  }

  Widget _buildLyricsViewport(
    LrcDocument? lrc,
    AudioPlaybackState state,
    AudioPlaybackNotifier notifier,
  ) {
    final p = context.palette;
    if (lrc == null || lrc.lines.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.lyrics_outlined, size: 40, color: p.textMuted),
            const SizedBox(height: 12),
            Text(
              '当前曲目暂无同步歌词',
              style: TextStyle(color: p.textSecondary, fontSize: 14),
            ),
          ],
        ),
      );
    }

    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification is ScrollStartNotification &&
            notification.dragDetails != null) {
          _onUserLyricScrollActivity();
        } else if (notification is UserScrollNotification) {
          _onUserLyricScrollActivity();
        }
        return false;
      },
      child: ShaderMask(
        shaderCallback: (bounds) => const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.transparent,
            Colors.white,
            Colors.white,
            Colors.transparent,
          ],
          stops: [0.0, 0.08, 0.90, 1.0],
        ).createShader(bounds),
        blendMode: BlendMode.dstIn,
        child: KonataDraggableScrollbar(
          controller: _lyricScrollCtrl,
          padding: const EdgeInsets.only(right: 4),
          builder: (_, ctrl) => ListView.builder(
            controller: ctrl,
            padding: const EdgeInsets.fromLTRB(4, 48, 22, 64),
            itemCount: lrc.lines.length,
            itemBuilder: (context, index) {
              final line = lrc.lines[index];
              final isActive = index == state.activeLyricIndex;
              final distance = state.activeLyricIndex >= 0
                  ? (index - state.activeLyricIndex).abs()
                  : 0;
              final blurSigma = _isUserScrollingLyrics
                  ? 0.0
                  : switch (distance) {
                      0 => 0.0,
                      1 => KonataPlaybackTokens.lyricBlurStep1,
                      2 => KonataPlaybackTokens.lyricBlurStep2,
                      _ => KonataPlaybackTokens.lyricBlurStepFar,
                    };

              final rowContent = GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  _scrollResetTimer?.cancel();
                  setState(() => _isUserScrollingLyrics = false);
                  notifier.seekRelativeTrackSeconds(line.startSeconds);
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      AnimatedDefaultTextStyle(
                        duration: const Duration(milliseconds: 220),
                        curve: Curves.easeOutCubic,
                        style: TextStyle(
                          color: isActive ? p.textPrimary : p.textSecondary,
                          fontSize: isActive
                              ? KonataPlaybackTokens.lyricActiveFontSize
                              : KonataPlaybackTokens.lyricInactiveFontSize,
                          fontWeight: isActive
                              ? FontWeight.w600
                              : FontWeight.w400,
                          height: 1.35,
                          shadows: isActive
                              ? [
                                  Shadow(
                                    color: p.isDark
                                        ? Colors.white.withValues(alpha: 0.32)
                                        : Colors.black.withValues(alpha: 0.10),
                                    blurRadius: 16,
                                  ),
                                ]
                              : null,
                        ),
                        child: Text(line.primaryText),
                      ),
                      for (final sec in line.secondaryLines) ...[
                        const SizedBox(height: 4),
                        Text(
                          sec,
                          style: TextStyle(
                            color: isActive ? p.textSecondary : p.textMuted,
                            fontSize:
                                KonataPlaybackTokens.lyricSecondaryFontSize,
                            height: 1.3,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              );

              return KeyedSubtree(
                key: _lyricKeys[index],
                child: blurSigma > 0.05
                    ? ImageFiltered(
                        imageFilter: ui.ImageFilter.blur(
                          sigmaX: blurSigma,
                          sigmaY: blurSigma,
                        ),
                        child: rowContent,
                      )
                    : rowContent,
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildQueueViewport(
    AudioPlaybackState state,
    AudioPlaybackNotifier notifier,
  ) {
    return ShaderMask(
      shaderCallback: (bounds) => const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Colors.transparent,
          Colors.white,
          Colors.white,
          Colors.transparent,
        ],
        stops: [0.0, 0.08, 0.90, 1.0],
      ).createShader(bounds),
      blendMode: BlendMode.dstIn,
      child: KonataDraggableScrollbar(
        controller: _queueScrollCtrl,
        padding: const EdgeInsets.only(right: 4),
        builder: (_, ctrl) => ListView.separated(
          controller: ctrl,
          padding: const EdgeInsets.fromLTRB(4, 36, 22, 56),
          itemCount: state.queue.length,
          separatorBuilder: (_, _) => const SizedBox(height: 6),
          itemBuilder: (context, index) {
            final qItem = state.queue[index];
            final active = index == state.currentIndex;
            final trackPrefix = (qItem.trackNumber ?? (index + 1))
                .toString()
                .padLeft(2, '0');
            return _BorderlessQueueRow(
              item: qItem,
              trackPrefix: trackPrefix,
              active: active,
              onTap: () => notifier.playQueueIndex(index),
            );
          },
        ),
      ),
    );
  }
}

class _BorderlessQueueRow extends StatefulWidget {
  const _BorderlessQueueRow({
    required this.item,
    required this.trackPrefix,
    required this.active,
    required this.onTap,
  });

  final AudioQueueItem item;
  final String trackPrefix;
  final bool active;
  final VoidCallback onTap;

  @override
  State<_BorderlessQueueRow> createState() => _BorderlessQueueRowState();
}

class _BorderlessQueueRowState extends State<_BorderlessQueueRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final active = widget.active;
    final color = active
        ? p.textPrimary
        : (_hovered ? p.textPrimary.withValues(alpha: 0.88) : p.textSecondary);
    final resolvedDuration = widget.item.resolvedDuration;
    final durationText = resolvedDuration > Duration.zero
        ? PlaybackFormatters.formatMediaDuration(
            resolvedDuration.inMilliseconds / 1000.0,
          )
        : '';

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          child: Row(
            children: [
              SizedBox(
                width: 30,
                child: active
                    ? Icon(
                        Icons.graphic_eq_rounded,
                        size: 18,
                        color: p.textPrimary,
                      )
                    : Text(
                        widget.trackPrefix,
                        style: TextStyle(
                          color: _hovered ? p.textSecondary : p.textMuted,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w500,
                          fontFeatures: KonataPlaybackTokens.tabularNumbers,
                        ),
                      ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AnimatedDefaultTextStyle(
                      duration: const Duration(milliseconds: 200),
                      curve: Curves.easeOutCubic,
                      style: TextStyle(
                        color: color,
                        fontSize: active ? 16.5 : 14.5,
                        fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                        shadows: active
                            ? [
                                Shadow(
                                  color: p.isDark
                                      ? Colors.white.withValues(alpha: 0.42)
                                      : Colors.black.withValues(alpha: 0.10),
                                  blurRadius: 14,
                                ),
                              ]
                            : null,
                      ),
                      child: EllipsisTextWithTooltip(
                        text: widget.item.title,
                        style: const TextStyle(),
                      ),
                    ),
                    if (widget.item.performer.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      EllipsisTextWithTooltip(
                        text: widget.item.performer,
                        style: TextStyle(
                          color: active
                              ? p.textSecondary
                              : (_hovered ? p.textSecondary : p.textMuted),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (durationText.isNotEmpty) ...[
                const SizedBox(width: 12),
                Text(
                  durationText,
                  style: TextStyle(
                    color: active
                        ? p.textPrimary
                        : (_hovered ? p.textSecondary : p.textMuted),
                    fontSize: 12,
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

class _AmbientFlowBackdrop extends ConsumerStatefulWidget {
  const _AmbientFlowBackdrop({required this.cover});

  final AudioCoverSource cover;

  @override
  ConsumerState<_AmbientFlowBackdrop> createState() =>
      _AmbientFlowBackdropState();
}

class _AmbientFlowBackdropState extends ConsumerState<_AmbientFlowBackdrop> {
  static final Map<String, List<Color>> _paletteCache = {};
  static const int _maxPaletteCacheEntries = 32;

  List<Color> _glowColors = const [
    KonataPlaybackTokens.auroraDefaultGlowA,
    KonataPlaybackTokens.auroraDefaultGlowB,
    KonataPlaybackTokens.auroraDefaultGlowC,
  ];
  String _sampledKey = '';
  int _sampleEpoch = 0;

  @override
  void initState() {
    super.initState();
    _scheduleSamplePalette();
  }

  @override
  void didUpdateWidget(covariant _AmbientFlowBackdrop oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.cover != widget.cover) {
      _scheduleSamplePalette();
    }
  }

  String _coverKey(AudioCoverSource cover) {
    return switch (cover) {
      MemoryAudioCover() => 'mem:${cover.bytes.length}:${cover.contentHash}',
      ManagedPosterAudioCover(:final url, :final workId, :final revision) =>
        'url:$workId:$url#$revision',
      EmptyAudioCover() => 'empty',
    };
  }

  Future<void> _scheduleSamplePalette() async {
    final key = _coverKey(widget.cover);
    if (key == _sampledKey) return;
    _sampledKey = key;
    final epoch = ++_sampleEpoch;

    if (widget.cover is EmptyAudioCover) {
      return;
    }

    final cachedPalette = _paletteCache[key];
    if (cachedPalette != null) {
      if (mounted) {
        setState(() => _glowColors = cachedPalette);
      }
      return;
    }

    Uint8List? bytes;
    switch (widget.cover) {
      case MemoryAudioCover(bytes: final mem):
        bytes = mem;
      case ManagedPosterAudioCover(:final url):
        try {
          final loader = ref.read(tmdbImageLoaderProvider);
          bytes = await loader(url, targetWidth: 96);
        } catch (_) {}
      case EmptyAudioCover():
        return;
    }
    if (bytes == null || bytes.isEmpty || !mounted || epoch != _sampleEpoch) {
      return;
    }

    final palette = await _extractAuroraPalette(bytes);
    if (!mounted || epoch != _sampleEpoch || palette == null) return;
    _paletteCache.remove(key);
    _paletteCache[key] = palette;
    while (_paletteCache.length > _maxPaletteCacheEntries) {
      _paletteCache.remove(_paletteCache.keys.first);
    }
    setState(() => _glowColors = palette);
  }

  static Future<List<Color>?> _extractAuroraPalette(Uint8List bytes) async {
    try {
      final codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: 24,
        targetHeight: 24,
      );
      final frame = await codec.getNextFrame();
      final bd = await frame.image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      frame.image.dispose();
      codec.dispose();
      if (bd == null) return null;

      final data = bd.buffer.asUint8List();
      final buckets = List<({int count, double r, double g, double b})>.filled(
        12,
        (count: 0, r: 0, g: 0, b: 0),
      );
      for (var i = 0; i + 3 < data.length; i += 4) {
        final a = data[i + 3];
        if (a < 140) continue;
        final r = data[i];
        final g = data[i + 1];
        final b = data[i + 2];
        final hsv = HSVColor.fromColor(Color.fromARGB(255, r, g, b));
        if (hsv.saturation < 0.14 || hsv.value < 0.12) continue;
        final bin = (hsv.hue ~/ 30).clamp(0, 11);
        final prev = buckets[bin];
        buckets[bin] = (
          count: prev.count + 1,
          r: prev.r + r,
          g: prev.g + g,
          b: prev.b + b,
        );
      }

      final ranked = <({int count, Color color})>[];
      for (final b in buckets) {
        if (b.count == 0) continue;
        final raw = Color.fromARGB(
          255,
          (b.r / b.count).round().clamp(0, 255),
          (b.g / b.count).round().clamp(0, 255),
          (b.b / b.count).round().clamp(0, 255),
        );
        final hsv = HSVColor.fromColor(raw);
        final boosted = HSVColor.fromAHSV(
          1.0,
          hsv.hue,
          hsv.saturation.clamp(0.68, 0.88),
          hsv.value.clamp(0.45, 0.65),
        ).toColor();
        ranked.add((count: b.count, color: boosted));
      }
      ranked.sort((a, b) => b.count.compareTo(a.count));
      if (ranked.isEmpty) return null;
      final c1 = ranked[0].color;
      final c2 = ranked.length > 1 ? ranked[1].color : _shiftHue(c1, 36);
      final c3 = ranked.length > 2 ? ranked[2].color : _shiftHue(c1, -42);
      return [c1, c2, c3];
    } catch (_) {
      return null;
    }
  }

  static Color _shiftHue(Color base, double delta) {
    final hsv = HSVColor.fromColor(base);
    return hsv.withHue((hsv.hue + delta) % 360.0).toColor();
  }

  static List<double> _saturationBoostMatrix(double saturation) {
    const lumR = 0.2126;
    const lumG = 0.7152;
    const lumB = 0.0722;
    final inv = 1.0 - saturation;
    final r = lumR * inv;
    final g = lumG * inv;
    final b = lumB * inv;
    return [
      r + saturation,
      g,
      b,
      0,
      0,
      r,
      g + saturation,
      b,
      0,
      0,
      r,
      g,
      b + saturation,
      0,
      0,
      0,
      0,
      0,
      1,
      0,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final loader = ref.watch(tmdbImageLoaderProvider);
    final c1 = _glowColors[0];
    final c2 = _glowColors[1];
    final c3 = _glowColors[2];
    final scrimBase = KonataPlaybackTokens.detailScrimBase(p);

    Widget? art;
    switch (widget.cover) {
      case MemoryAudioCover(:final bytes):
        art = Image.memory(
          bytes,
          fit: BoxFit.cover,
          width: double.infinity,
          height: double.infinity,
          gaplessPlayback: true,
        );
      case ManagedPosterAudioCover(:final url, :final workId, :final revision):
        art = ManagedImage(
          url,
          key: ValueKey('imm_bg_${workId}_${url}_$revision'),
          loader: loader,
          owner: workId,
          fit: BoxFit.cover,
          decodeWidth: 512,
          width: double.infinity,
          height: double.infinity,
          errorBuilder: (_, _, _) => const SizedBox.shrink(),
        );
      case EmptyAudioCover():
        art = null;
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: KonataPlaybackTokens.auroraCanvas(p)),
        // 封面主色采样流光弥散层
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: const Alignment(-0.55, -0.35),
              radius: 1.05,
              colors: [c1.withValues(alpha: 0.78), Colors.transparent],
            ),
          ),
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: const Alignment(0.60, 0.20),
              radius: 1.0,
              colors: [c2.withValues(alpha: 0.64), Colors.transparent],
            ),
          ),
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: const Alignment(-0.20, 0.75),
              radius: 0.95,
              colors: [c3.withValues(alpha: 0.56), Colors.transparent],
            ),
          ),
        ),
        if (art != null)
          Transform.scale(
            scale: 1.28,
            child: Opacity(
              opacity: 0.72,
              child: ColorFiltered(
                colorFilter: ColorFilter.matrix(_saturationBoostMatrix(1.42)),
                child: ImageFiltered(
                  imageFilter: ui.ImageFilter.blur(
                    sigmaX: KonataPlaybackTokens.auroraBlurSigma,
                    sigmaY: KonataPlaybackTokens.auroraBlurSigma,
                  ),
                  child: art,
                ),
              ),
            ),
          ),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                scrimBase.withValues(alpha: p.isDark ? 0.22 : 0.72),
                scrimBase.withValues(alpha: p.isDark ? 0.18 : 0.64),
                scrimBase.withValues(alpha: p.isDark ? 0.44 : 0.80),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _CoverAndReflectionColumn extends ConsumerWidget {
  const _CoverAndReflectionColumn({required this.cover});

  final AudioCoverSource cover;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.palette;
    final loader = ref.watch(tmdbImageLoaderProvider);

    Widget buildArtwork(double size) {
      switch (cover) {
        case MemoryAudioCover(:final bytes):
          return Image.memory(
            bytes,
            width: size,
            height: size,
            fit: BoxFit.cover,
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
            key: ValueKey('imm_cov_${workId}_${url}_$revision'),
            loader: loader,
            owner: workId,
            width: size,
            height: size,
            decodeWidth: 800,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => _emptyArt(p, size),
          );
        case EmptyAudioCover():
          return _emptyArt(p, size);
      }
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final coverSize = constraints.maxWidth.clamp(
          200.0,
          KonataPlaybackTokens.albumCoverSize,
        );

        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              width: coverSize,
              height: coverSize,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(
                  KonataPlaybackTokens.albumCoverRadius,
                ),
                boxShadow: [
                  BoxShadow(
                    color: KonataPlaybackTokens.shadowColor(p),
                    blurRadius: 38,
                    offset: const Offset(0, 20),
                  ),
                ],
                border: Border.all(
                  color: KonataPlaybackTokens.glassBorder(p),
                  width: 1,
                ),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(
                  KonataPlaybackTokens.albumCoverRadius,
                ),
                child: buildArtwork(coverSize),
              ),
            ),
            // 底部紧贴垂直镜像渐隐倒影（精简纯净，不再堆砌冗余长标题）
            SizedBox(
              width: coverSize,
              height: KonataPlaybackTokens.albumReflectionHeight,
              child: ClipRect(
                child: OverflowBox(
                  alignment: Alignment.topCenter,
                  maxHeight: coverSize,
                  child: ShaderMask(
                    shaderCallback: (bounds) =>
                        const LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors:
                              KonataPlaybackTokens.albumReflectionMaskColors,
                          stops: [0.0, 0.38, 0.94],
                        ).createShader(
                          Rect.fromLTWH(
                            0,
                            0,
                            coverSize,
                            KonataPlaybackTokens.albumReflectionHeight,
                          ),
                        ),
                    blendMode: BlendMode.dstIn,
                    child: Transform(
                      alignment: Alignment.center,
                      transform: Matrix4.diagonal3Values(1.0, -1.0, 1.0),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(
                          KonataPlaybackTokens.albumCoverRadius,
                        ),
                        child: buildArtwork(coverSize),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _emptyArt(KonataPalette p, double size) {
    return Container(
      width: size,
      height: size,
      color: KonataPlaybackTokens.softFill(p),
      alignment: Alignment.center,
      child: Icon(
        Icons.album_rounded,
        size: size * 0.34,
        color: p.textMuted.withValues(alpha: 0.56),
      ),
    );
  }
}

class _ImmersiveMicroCover extends ConsumerWidget {
  const _ImmersiveMicroCover({required this.cover});

  final AudioCoverSource cover;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.palette;
    final loader = ref.watch(tmdbImageLoaderProvider);
    const size = 38.0;

    Widget art;
    switch (cover) {
      case MemoryAudioCover(:final bytes):
        art = Image.memory(
          bytes,
          width: size,
          height: size,
          fit: BoxFit.cover,
          filterQuality: FilterQuality.medium,
          gaplessPlayback: true,
        );
      case ManagedPosterAudioCover(:final url, :final workId, :final revision):
        art = ManagedImage(
          url,
          key: ValueKey('imm_bg_${workId}_${url}_$revision'),
          loader: loader,
          owner: workId,
          width: size,
          height: size,
          decodeWidth: 160,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => _fallback(p, size),
        );
      case EmptyAudioCover():
        art = _fallback(p, size);
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(9),
      child: SizedBox(width: size, height: size, child: art),
    );
  }

  Widget _fallback(KonataPalette p, double size) {
    return Container(
      width: size,
      height: size,
      color: KonataPlaybackTokens.softFill(p),
      alignment: Alignment.center,
      child: Icon(Icons.music_note_rounded, size: 18, color: p.textSecondary),
    );
  }
}
