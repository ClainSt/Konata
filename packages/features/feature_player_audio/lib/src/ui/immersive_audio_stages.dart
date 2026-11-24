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

/// 桌面端双栏舞台：左侧 1:1 封面与镜面倒影，右侧自由切换歌词与分轨队列。
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
  });

  final AudioPlaybackController controller;
  final AudioPlaybackSnapshot snapshot;
  final SmartCoverAlignmentCache alignmentCache;
  final AudioStageRightTab rightTab;
  final ValueChanged<AudioStageRightTab> onRightTabChanged;
  final AudioLyricsViewportBuilder? lyricsViewportBuilder;

  @override
  Widget build(BuildContext context) {
    final current = snapshot.currentItem;
    return LayoutBuilder(
      builder: (context, constraints) {
        final coverSize = math.min(
          340.0,
          math.max(200.0, constraints.maxHeight * 0.56),
        );
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 42, vertical: 16),
          child: Row(
            children: [
              // 左侧专辑封面与元信息区。
              Expanded(
                flex: 5,
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
                        ),
                        const SizedBox(height: 18),
                        ConstrainedBox(
                          constraints: BoxConstraints(maxWidth: coverSize + 40),
                          child: Column(
                            children: [
                              Text(
                                current?.title ?? '未选择音轨',
                                textAlign: TextAlign.center,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 20,
                                  fontWeight: FontWeight.w700,
                                  height: 1.25,
                                ),
                              ),
                              if (current != null &&
                                  (current.artist.isNotEmpty ||
                                      current.album.isNotEmpty)) ...[
                                const SizedBox(height: 6),
                                Text(
                                  [
                                    if (current.artist.isNotEmpty)
                                      current.artist,
                                    if (current.album.isNotEmpty) current.album,
                                  ].join(' · '),
                                  textAlign: TextAlign.center,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.68),
                                    fontSize: 13.5,
                                  ),
                                ),
                              ],
                              if (snapshot.formattedAudioSpec.isNotEmpty) ...[
                                const SizedBox(height: 10),
                                KonataSpecBadge(
                                  label: snapshot.formattedAudioSpec,
                                  icon: Icons.high_quality_rounded,
                                  darkOverlay: true,
                                  highlighted:
                                      snapshot.audiophilePlan.safetyLimiterEngaged,
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 36),
              // 右侧歌词 / 队列分栏。
              Expanded(
                flex: 6,
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _StageSwitchChip(
                          label: '歌词',
                          selected: rightTab == AudioStageRightTab.lyrics,
                          onTap: () =>
                              onRightTabChanged(AudioStageRightTab.lyrics),
                        ),
                        const SizedBox(width: 8),
                        _StageSwitchChip(
                          label: '队列 (${snapshot.queue.length})',
                          selected: rightTab == AudioStageRightTab.queue,
                          onTap: () =>
                              onRightTabChanged(AudioStageRightTab.queue),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Expanded(
                      child: rightTab == AudioStageRightTab.lyrics
                          ? AudioLyricsSlotPane(
                              controller: controller,
                              snapshot: snapshot,
                              lyricsViewportBuilder: lyricsViewportBuilder,
                            )
                          : AudioQueueListView(
                              controller: controller,
                              snapshot: snapshot,
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

/// 手机横屏矮视口（高度 `< 520dp`）双区紧凑布局。
class ShortPhoneLandscapeStage extends StatelessWidget {
  /// 构造矮横屏舞台。
  const ShortPhoneLandscapeStage({
    super.key,
    required this.controller,
    required this.snapshot,
    this.lyricsViewportBuilder,
  });

  final AudioPlaybackController controller;
  final AudioPlaybackSnapshot snapshot;
  final AudioLyricsViewportBuilder? lyricsViewportBuilder;

  @override
  Widget build(BuildContext context) {
    final current = snapshot.currentItem;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
      child: Row(
        children: [
          Expanded(
            flex: 4,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ImmersiveMicroCover(
                  cover: snapshot.cover,
                  coverKey: snapshot.coverVariantTag,
                  size: 76,
                ),
                const SizedBox(height: 10),
                Text(
                  current?.title ?? '未选择音轨',
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (current != null && current.album.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    current.album,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.65),
                      fontSize: 12,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            flex: 6,
            child: AudioLyricsSlotPane(
              controller: controller,
              snapshot: snapshot,
              lyricsViewportBuilder: lyricsViewportBuilder,
              compact: true,
            ),
          ),
        ],
      ),
    );
  }
}

/// 移动竖屏单栏舞台：支持轻点封面与歌词原地切换。
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
  });

  final AudioPlaybackController controller;
  final AudioPlaybackSnapshot snapshot;
  final SmartCoverAlignmentCache alignmentCache;
  final bool showingLyrics;
  final VoidCallback onToggleShowLyrics;
  final AudioLyricsViewportBuilder? lyricsViewportBuilder;

  @override
  Widget build(BuildContext context) {
    final current = snapshot.currentItem;
    return LayoutBuilder(
      builder: (context, constraints) {
        final coverSize = math.min(
          280.0,
          math.min(constraints.maxWidth * 0.72, constraints.maxHeight * 0.54),
        );
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 260),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          child: showingLyrics
              ? Padding(
                  key: const ValueKey('portrait_lyrics'),
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Column(
                    children: [
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: onToggleShowLyrics,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 6,
                          ),
                          child: Row(
                            children: [
                              ImmersiveMicroCover(
                                cover: snapshot.cover,
                                coverKey: snapshot.coverVariantTag,
                                size: 42,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      current?.title ?? '',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 15,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    if (current != null &&
                                        current.artist.isNotEmpty)
                                      Text(
                                        current.artist,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: Colors.white.withValues(
                                            alpha: 0.65,
                                          ),
                                          fontSize: 12,
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                              Icon(
                                Icons.album_outlined,
                                size: 18,
                                color: Colors.white.withValues(alpha: 0.72),
                              ),
                            ],
                          ),
                        ),
                      ),
                      Expanded(
                        child: AudioLyricsSlotPane(
                          controller: controller,
                          snapshot: snapshot,
                          lyricsViewportBuilder: lyricsViewportBuilder,
                          centerAligned: true,
                          onTapEmptyArea: onToggleShowLyrics,
                        ),
                      ),
                    ],
                  ),
                )
              : GestureDetector(
                  key: const ValueKey('portrait_cover'),
                  behavior: HitTestBehavior.opaque,
                  onTap: onToggleShowLyrics,
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          ImmersiveCoverWithReflection(
                            cover: snapshot.cover,
                            coverKey: snapshot.coverVariantTag,
                            alignmentCache: alignmentCache,
                            size: math.max(150.0, coverSize),
                            reflectionHeight: 24,
                          ),
                          const SizedBox(height: 16),
                          Text(
                            current?.title ?? '未选择音轨',
                            textAlign: TextAlign.center,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 19,
                              fontWeight: FontWeight.w700,
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
                                color: Colors.white.withValues(alpha: 0.68),
                                fontSize: 13,
                              ),
                            ),
                          ],
                          if (snapshot.formattedAudioSpec.isNotEmpty) ...[
                            const SizedBox(height: 8),
                            KonataSpecBadge(
                              label: snapshot.formattedAudioSpec,
                              darkOverlay: true,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
        );
      },
    );
  }
}

class _StageSwitchChip extends StatelessWidget {
  const _StageSwitchChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: selected
              ? Colors.white.withValues(alpha: 0.22)
              : Colors.white.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: selected
                ? Colors.white.withValues(alpha: 0.36)
                : Colors.white.withValues(alpha: 0.12),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected
                ? Colors.white
                : Colors.white.withValues(alpha: 0.68),
            fontSize: 12.5,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
          ),
        ),
      ),
    );
  }
}
