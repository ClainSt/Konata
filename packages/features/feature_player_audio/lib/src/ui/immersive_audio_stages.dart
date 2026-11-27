import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:konata_design_system/konata_design_system.dart';

import '../data/data.dart';
import '../state/state.dart';
import 'audio_aurora_backdrop.dart';
import 'audio_lyrics_slot.dart';
import 'immersive_audio_queue_and_safety.dart';

/// 音频舞台右侧面板展示标签页枚举。
enum AudioStageRightTab {
  /// 沉浸滚动歌词面板。
  lyrics,

  /// 专辑曲目队列与 `.cue` 分轨清单面板。
  queue,
}

/// 渲染可选外挂歌词视口；若未注入歌词模块，则退化为安静独立的音轨元数据视图，绝不报错。
class AudioLyricsSlotPane extends StatelessWidget {
  /// 创建可插拔歌词渲染槽位。
  const AudioLyricsSlotPane({
    super.key,
    required this.controller,
    required this.snapshot,
    this.lyricsViewportBuilder,
    this.compact = false,
    this.centerAligned = false,
    this.onTapEmptyArea,
  });

  final AudioPlaybackController controller;
  final AudioPlaybackSnapshot snapshot;
  final AudioLyricsViewportBuilder? lyricsViewportBuilder;
  final bool compact;
  final bool centerAligned;
  final VoidCallback? onTapEmptyArea;

  @override
  Widget build(BuildContext context) {
    final current = snapshot.currentItem;
    if (lyricsViewportBuilder != null && current != null) {
      return lyricsViewportBuilder!(
        context,
        AudioLyricsViewportContext(
          trackKey: current.itemId,
          positionListenable: controller.positionListenable,
          isPlayingListenable: controller.playingListenable,
          onSeekTo: controller.seekToTrackPosition,
          compact: compact,
          centerAligned: centerAligned,
          onTapEmptyArea: onTapEmptyArea,
        ),
      );
    }

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: onTapEmptyArea,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.music_note_rounded,
                size: compact ? 30 : 38,
                color: Colors.white.withValues(alpha: 0.42),
              ),
              const SizedBox(height: 12),
              Text(
                current?.title ?? '等待音频曲目装填',
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.88),
                  fontSize: compact ? 15 : 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (current != null &&
                  (current.artist.isNotEmpty || current.album.isNotEmpty)) ...[
                const SizedBox(height: 6),
                Text(
                  [
                    if (current.artist.isNotEmpty) current.artist,
                    if (current.album.isNotEmpty) current.album,
                  ].join(' · '),
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.60),
                    fontSize: compact ? 12.5 : 13.5,
                  ),
                ),
              ],
              const SizedBox(height: 14),
              Text(
                '当前处于纯音频独立舞台（未接入实时歌词视图插件）',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.42),
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 桌面与平板横屏双栏舞台：左侧占比更大的无硬白边 1:1 封面与水面倒影，右侧大空气感纯白歌词与一键切换队列。
class DesktopAudioDualStage extends StatelessWidget {
  /// 构造桌面双栏舞台。
  const DesktopAudioDualStage({
    super.key,
    required this.controller,
    required this.snapshot,
    required this.alignmentCache,
    required this.rightTab,
    required this.onRightTabChanged,
    this.lyricsViewportBuilder,
    this.stageHeight,
  });

  /// 核心音频播放控制器。
  final AudioPlaybackController controller;

  /// 当前音频会话不可变快照。
  final AudioPlaybackSnapshot snapshot;

  /// 智能构图对齐缓存。
  final SmartCoverAlignmentCache alignmentCache;

  /// 右栏当前展示模式（歌词或队列）。
  final AudioStageRightTab rightTab;

  /// 右栏模式切换回调。
  final ValueChanged<AudioStageRightTab> onRightTabChanged;

  /// 可选外部歌词视口构建器。
  final AudioLyricsViewportBuilder? lyricsViewportBuilder;

  /// 舞台总高度参考（用于将封面尺寸稳定在舞台高度的 `46%~50%` 黄金比例）。
  final double? stageHeight;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final effectiveStageH = stageHeight ?? constraints.maxHeight;
        final desiredCover = effectiveStageH * 0.42;
        final maxByWidth = constraints.maxWidth * 0.38;
        final maxByAvailH = math.max(120.0, constraints.maxHeight - 156.0);
        final coverSize = desiredCover
            .clamp(
              math.min(160.0, maxByAvailH),
              math.max(
                160.0,
                math.min(340.0, math.min(maxByWidth, maxByAvailH)),
              ),
            )
            .toDouble();
        final reflectionH = (coverSize * 0.24).clamp(32.0, 92.0);
        final hGap = (constraints.maxWidth * 0.032).clamp(22.0, 48.0);
        final hPad = (constraints.maxWidth * 0.038).clamp(24.0, 52.0);

        return Padding(
          padding: EdgeInsets.symmetric(horizontal: hPad, vertical: 10),
          child: Row(
            children: [
              // 左侧：大占比无硬白边专辑封面 + 水面倒影 + 精炼元数据。
              Expanded(
                flex: 46,
                child: Center(
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ImmersiveCoverWithReflection(
                          cover: snapshot.cover,
                          coverKey: snapshot.coverVariantTag,
                          alignmentCache: alignmentCache,
                          size: coverSize,
                          borderRadius: 14.0,
                          reflectionHeight: reflectionH,
                          showBorder: false,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              SizedBox(width: hGap),
              // 右侧：大空气感纯白逐字歌词与一键切换播放队列。
              Expanded(
                flex: 54,
                child: Column(
                  children: [
                    Expanded(
                      child: AnimatedSwitcher(
                        duration: KonataTheme.motionStandard,
                        switchInCurve: Curves.easeOutCubic,
                        switchOutCurve: Curves.easeInCubic,
                        child: rightTab == AudioStageRightTab.lyrics
                            ? AudioLyricsSlotPane(
                                key: const ValueKey(
                                  'audio_desktop_lyrics_stage',
                                ),
                                controller: controller,
                                snapshot: snapshot,
                                lyricsViewportBuilder: lyricsViewportBuilder,
                              )
                            : AudioQueueListView(
                                key: const ValueKey(
                                  'audio_desktop_queue_stage',
                                ),
                                controller: controller,
                                snapshot: snapshot,
                              ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 纯竖屏单栏舞台（Android 手机独占与平板竖屏）：支持封面态与居中歌词态丝滑切换。
class PortraitPhoneAudioStage extends StatelessWidget {
  /// 构造竖屏舞台。
  const PortraitPhoneAudioStage({
    super.key,
    required this.controller,
    required this.snapshot,
    required this.alignmentCache,
    required this.showingLyrics,
    required this.onToggleShowLyrics,
    this.lyricsViewportBuilder,
    this.isTabletPortrait = false,
  });

  /// 核心音频播放控制器。
  final AudioPlaybackController controller;

  /// 当前音频会话不可变快照。
  final AudioPlaybackSnapshot snapshot;

  /// 智能构图对齐缓存。
  final SmartCoverAlignmentCache alignmentCache;

  /// 当前是否正显示居中歌词视口。
  final bool showingLyrics;

  /// 封面与歌词视图切换回调。
  final VoidCallback onToggleShowLyrics;

  /// 可选外部歌词视口构建器。
  final AudioLyricsViewportBuilder? lyricsViewportBuilder;

  /// 是否处于平板竖屏高宽口模式（适当放大封面与水平留白）。
  final bool isTabletPortrait;

  @override
  Widget build(BuildContext context) {
    final current = snapshot.currentItem;
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxCoverCap = isTabletPortrait ? 380.0 : 320.0;
        final maxByHeight = math.max(120.0, constraints.maxHeight - 138.0);
        final coverSize = math.min(
          maxCoverCap,
          math.min(
            constraints.maxWidth * (isTabletPortrait ? 0.58 : 0.78),
            math.min(constraints.maxHeight * 0.58, maxByHeight),
          ),
        );
        final reflectionH = (coverSize * 0.16).clamp(18.0, 48.0);

        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 260),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          child: showingLyrics
              ? Padding(
                  key: const ValueKey('portrait_lyrics'),
                  padding: EdgeInsets.symmetric(
                    horizontal: isTabletPortrait ? 44 : 18,
                    vertical: 4,
                  ),
                  child: AudioLyricsSlotPane(
                    controller: controller,
                    snapshot: snapshot,
                    lyricsViewportBuilder: lyricsViewportBuilder,
                    centerAligned: true,
                    onTapEmptyArea: onToggleShowLyrics,
                  ),
                )
              : GestureDetector(
                  key: const ValueKey('portrait_cover'),
                  behavior: HitTestBehavior.opaque,
                  onTap: onToggleShowLyrics,
                  child: Center(
                    child: SingleChildScrollView(
                      child: Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: isTabletPortrait ? 48 : 24,
                          vertical: 8,
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            ImmersiveCoverWithReflection(
                              cover: snapshot.cover,
                              coverKey: snapshot.coverVariantTag,
                              alignmentCache: alignmentCache,
                              size: math.max(132.0, coverSize),
                              borderRadius: 14.0,
                              reflectionHeight: reflectionH,
                              showBorder: false,
                            ),
                            const SizedBox(height: 18),
                            // 曲名右侧紧邻显示音频格式与采样率徽标，不展示「作品详情」入口按钮。
                            ConstrainedBox(
                              constraints: BoxConstraints(
                                maxWidth: math.max(240.0, coverSize + 40),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.center,
                                children: [
                                  Flexible(
                                    child: Text(
                                      current?.title ?? '未选择音轨',
                                      textAlign: TextAlign.center,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: Colors.white.withValues(
                                          alpha: 0.96,
                                        ),
                                        fontSize: 19.5,
                                        fontWeight: FontWeight.w700,
                                        height: 1.24,
                                      ),
                                    ),
                                  ),
                                  if (snapshot
                                      .formattedAudioSpec
                                      .isNotEmpty) ...[
                                    const SizedBox(width: 8),
                                    KonataSpecBadge(
                                      key: const ValueKey(
                                        'audio_portrait_format_badge',
                                      ),
                                      label: snapshot.formattedAudioSpec,
                                      darkOverlay: true,
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            if (current != null &&
                                (current.artist.isNotEmpty ||
                                    current.album.isNotEmpty)) ...[
                              const SizedBox(height: 6),
                              Text(
                                [
                                  if (current.artist.isNotEmpty) current.artist,
                                  if (current.album.isNotEmpty) current.album,
                                ].join(' · '),
                                textAlign: TextAlign.center,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.64),
                                  fontSize: 13,
                                ),
                              ),
                            ],
                          ],
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
