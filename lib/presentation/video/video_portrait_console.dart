import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/playback/video_playback_controller.dart';
import '../../domain/matching/episode_title_formatter.dart';
import '../../domain/models/episode.dart';
import '../../domain/models/work.dart';
import '../../domain/playback/playback_formatters.dart';
import '../../domain/playback/playback_probe_stats.dart';
import '../theme/konata_adaptive_tokens.dart';
import '../theme/konata_palette.dart';
import '../theme/konata_playback_tokens.dart';
import '../widgets/design_system/ellipsis_text_with_tooltip.dart';
import '../widgets/design_system/konata_draggable_scrollbar.dart';
import '../widgets/design_system/konata_glass_capsule.dart';
import '../widgets/design_system/konata_segmented_capsule.dart';
import '../widgets/playback/konata_spec_badge.dart';
import 'video_side_sheet.dart';

enum _PortraitLowerTab { episodes, chapters }

/// 手机竖屏视频下部控制台：承载快捷音轨/字幕/倍速/纯音频/画中画胶囊，以及选集队列与章节面板。
class VideoPortraitConsole extends ConsumerStatefulWidget {
  /// 创建手机竖屏下部控制台。
  const VideoPortraitConsole({
    super.key,
    required this.request,
    required this.onOpenSideSheet,
    required this.onEnterPip,
  });

  final VideoLaunchRequest request;
  final ValueChanged<VideoSideSheetTab> onOpenSideSheet;
  final VoidCallback onEnterPip;

  @override
  ConsumerState<VideoPortraitConsole> createState() =>
      _VideoPortraitConsoleState();
}

class _VideoPortraitConsoleState extends ConsumerState<VideoPortraitConsole> {
  _PortraitLowerTab _tab = _PortraitLowerTab.episodes;
  final ScrollController _epScrollCtrl = ScrollController();
  final ScrollController _chScrollCtrl = ScrollController();
  final ScrollController _quickActionsCtrl = ScrollController();

  @override
  void dispose() {
    _epScrollCtrl.dispose();
    _chScrollCtrl.dispose();
    _quickActionsCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final snap = ref.watch(
      videoPlaybackProvider(widget.request).select(
        (s) => (
          work: s.currentWork,
          bundle: s.currentBundle,
          episode: s.currentEpisode,
          chapters: s.chapters,
          speed: s.speed,
          audioOnly: s.audioOnlyMode,
          stats: s.probeStats,
        ),
      ),
    );
    final controller = ref.read(videoPlaybackProvider(widget.request).notifier);
    final work = snap.work ?? widget.request.work;
    final bundle = snap.bundle ?? widget.request.bundle;
    final epTitle = controller.currentEpisodeTitle;

    final resBadge = PlaybackFormatters.formatResolutionBadge(
      snap.stats.videoWidth,
      snap.stats.videoHeight,
    );
    final codecBadge = PlaybackFormatters.formatCodecShortLabel(
      snap.stats.videoCodec,
    );

    final playableEpisodes = Episode.sortMainFirst(
      bundle.episodes.where((e) => bundle.variantsForEpisode(e.id).isNotEmpty),
    );
    final mainCount = bundle.episodes
        .where((e) => e.category == EpisodeCategory.main)
        .length;

    return Container(
      color: p.isDark
          ? KonataPlaybackTokens.auroraCanvasDark
          : KonataPlaybackTokens.auroraCanvas(p),
      child: SafeArea(
        top: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    work.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: p.textSecondary,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          epTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: p.textPrimary,
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      if (resBadge.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        KonataSpecBadge(label: resBadge),
                      ],
                      if (codecBadge.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        KonataSpecBadge(label: codecBadge),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            // 音轨、字幕、倍速比例、后台纯音频、画中画快捷胶囊横排（全部热区 >= 48dp）
            SizedBox(
              height: KonataAdaptiveTokens.touchTarget + 4,
              child: SingleChildScrollView(
                controller: _quickActionsCtrl,
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: Row(
                  children: [
                    _QuickActionCapsule(
                      key: const ValueKey('portrait_quick_audio'),
                      icon: Icons.audiotrack_rounded,
                      label: '音轨',
                      onTap: () =>
                          widget.onOpenSideSheet(VideoSideSheetTab.audio),
                    ),
                    const SizedBox(width: 8),
                    _QuickActionCapsule(
                      key: const ValueKey('portrait_quick_subtitles'),
                      icon: Icons.subtitles_rounded,
                      label: '字幕与延迟',
                      onTap: () =>
                          widget.onOpenSideSheet(VideoSideSheetTab.subtitles),
                    ),
                    const SizedBox(width: 8),
                    _QuickActionCapsule(
                      key: const ValueKey('portrait_quick_video'),
                      icon: Icons.aspect_ratio_rounded,
                      label:
                          '${snap.speed.toStringAsFixed(2).replaceFirst(RegExp(r'\.?0+$'), '')}x · 比例',
                      onTap: () =>
                          widget.onOpenSideSheet(VideoSideSheetTab.video),
                    ),
                    const SizedBox(width: 8),
                    _QuickActionCapsule(
                      key: const ValueKey('portrait_quick_audio_only'),
                      icon: Icons.headphones_rounded,
                      label: snap.audioOnly ? '恢复画面' : '后台听番',
                      highlighted: snap.audioOnly,
                      onTap: controller.toggleAudioOnlyMode,
                    ),
                    const SizedBox(width: 8),
                    _QuickActionCapsule(
                      key: const ValueKey('portrait_quick_pip'),
                      icon: Icons.picture_in_picture_alt_rounded,
                      label: '画中画',
                      onTap: widget.onEnterPip,
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
              child: KonataSegmentedCapsule<_PortraitLowerTab>(
                expand: true,
                options: [
                  KonataSegmentOption(
                    value: _PortraitLowerTab.episodes,
                    label: '选集队列 (${playableEpisodes.length})',
                    icon: Icons.playlist_play_rounded,
                  ),
                  KonataSegmentOption(
                    value: _PortraitLowerTab.chapters,
                    label: '章节 (${snap.chapters.length})',
                    icon: Icons.bookmark_border_rounded,
                  ),
                ],
                selected: _tab,
                onChanged: (next) => setState(() => _tab = next),
              ),
            ),
            Expanded(
              child: _tab == _PortraitLowerTab.episodes
                  ? _buildEpisodesList(
                      p: p,
                      episodes: playableEpisodes,
                      activeEpisodeId: snap.episode.id,
                      workTitle: work.title,
                      mediaType: work.tmdbMediaType,
                      mainCount: mainCount,
                      bundle: bundle,
                      controller: controller,
                    )
                  : _buildChaptersList(
                      p: p,
                      chapters: snap.chapters,
                      controller: controller,
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEpisodesList({
    required KonataPalette p,
    required List<Episode> episodes,
    required String activeEpisodeId,
    required String workTitle,
    required TmdbMediaType? mediaType,
    required int mainCount,
    required dynamic bundle,
    required VideoPlaybackController controller,
  }) {
    if (episodes.isEmpty) {
      return Center(
        child: Text(
          '暂无可播放剧集',
          style: TextStyle(color: p.textMuted, fontSize: 13),
        ),
      );
    }
    return KonataDraggableScrollbar(
      controller: _epScrollCtrl,
      padding: const EdgeInsets.only(right: 4),
      builder: (_, ctrl) => ListView.separated(
        controller: ctrl,
        padding: const EdgeInsets.fromLTRB(16, 2, 18, 16),
        itemCount: episodes.length,
        separatorBuilder: (_, _) => const SizedBox(height: 8),
        itemBuilder: (context, index) {
          final ep = episodes[index];
          final active = ep.id == activeEpisodeId;
          final title = EpisodeTitleFormatter.formatCardTitle(
            episode: ep,
            workTitle: workTitle,
            workMediaType: mediaType,
            mainEpisodeCount: mainCount,
          );
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: active
                ? null
                : () => unawaited(controller.switchToEpisode(ep)),
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                minHeight: KonataAdaptiveTokens.touchTarget,
              ),
              child: KonataGlassCapsule(
                radius: 14,
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                child: Row(
                  children: [
                    Icon(
                      active
                          ? Icons.play_circle_fill_rounded
                          : Icons.play_circle_outline_rounded,
                      size: 20,
                      color: active ? p.progressFill : p.textSecondary,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: EllipsisTextWithTooltip(
                        text: title,
                        style: TextStyle(
                          color: active ? p.textPrimary : p.textSecondary,
                          fontSize: 13.5,
                          fontWeight: active
                              ? FontWeight.w700
                              : FontWeight.w500,
                        ),
                      ),
                    ),
                    EpisodeCategoryBadge(isSpecial: ep.isSpecial),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildChaptersList({
    required KonataPalette p,
    required List<PlaybackChapter> chapters,
    required VideoPlaybackController controller,
  }) {
    if (chapters.isEmpty) {
      return Center(
        child: Text(
          '当前视频未内嵌章节标记',
          style: TextStyle(color: p.textMuted, fontSize: 13),
        ),
      );
    }
    return KonataDraggableScrollbar(
      controller: _chScrollCtrl,
      padding: const EdgeInsets.only(right: 4),
      builder: (_, ctrl) => ListView.separated(
        controller: ctrl,
        padding: const EdgeInsets.fromLTRB(16, 2, 18, 16),
        itemCount: chapters.length,
        separatorBuilder: (_, _) => const SizedBox(height: 8),
        itemBuilder: (context, index) {
          final ch = chapters[index];
          final title = ch.title.trim().isNotEmpty
              ? ch.title.trim()
              : '章节 ${index + 1}';
          final stamp = PlaybackFormatters.formatMediaDuration(ch.startSeconds);
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => controller.seekAbsolute(ch.startSeconds),
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                minHeight: KonataAdaptiveTokens.touchTarget,
              ),
              child: KonataGlassCapsule(
                radius: 14,
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.bookmark_outline_rounded,
                      size: 18,
                      color: p.progressFill,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: EllipsisTextWithTooltip(
                        text: title,
                        style: TextStyle(
                          color: p.textPrimary,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    KonataSpecBadge(label: stamp),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _QuickActionCapsule extends StatelessWidget {
  const _QuickActionCapsule({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.highlighted = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final fg = highlighted ? p.progressFill : p.textPrimary;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          minHeight: KonataAdaptiveTokens.touchTarget,
        ),
        child: KonataGlassCapsule(
          radius: 999,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 17, color: fg),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  color: fg,
                  fontSize: 12.5,
                  fontWeight: highlighted ? FontWeight.w700 : FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
