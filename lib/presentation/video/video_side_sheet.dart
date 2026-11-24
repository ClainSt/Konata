import 'dart:async';

import 'package:file_picker/file_picker.dart' show FileType;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../application/playback/audiophile_safety_coordinator.dart';
import '../../application/playback/playback_preferences_provider.dart';
import '../../application/playback/video_playback_controller.dart';
import '../../application/providers/library_providers.dart';
import '../../composition/platform_composition.dart';
import '../../domain/matching/episode_title_formatter.dart';
import '../../domain/models/episode.dart';
import '../../domain/models/media_extensions.dart';
import '../../domain/models/series_group.dart';
import '../../domain/models/work.dart';
import '../../domain/playback/audiophile_safety_policy.dart';
import '../../domain/playback/playback_formatters.dart';
import '../../domain/playback/playback_probe_stats.dart';
import '../../domain/playback/subtitle_content_processor.dart';
import '../../domain/playback/track_preferences.dart';
import '../../domain/playback/video_aspect_mode.dart';
import '../../infrastructure/players/embedded_mpv_session.dart'
    show ScreenshotCaptureMode;
import '../../infrastructure/players/mpv_quality_profile.dart';
import '../theme/konata_adaptive_tokens.dart';
import '../theme/konata_palette.dart';
import '../theme/konata_playback_tokens.dart';
import '../theme/konata_theme.dart';
import '../widgets/design_system/ellipsis_text_with_tooltip.dart';
import '../widgets/design_system/konata_draggable_scrollbar.dart';
import '../widgets/design_system/konata_dropdown.dart';
import '../widgets/design_system/konata_glass_side_sheet.dart';
import '../widgets/design_system/konata_pill_button.dart';
import '../widgets/design_system/konata_segmented_capsule.dart';
import '../widgets/design_system/konata_surface_card.dart';
import '../widgets/design_system/konata_switch.dart';
import '../widgets/design_system/konata_system_file_picker.dart';
import '../widgets/design_system/konata_toast.dart';
import '../widgets/playback/konata_audiophile_unlock_dialog.dart';
import '../widgets/playback/konata_spec_badge.dart';

part 'video_side_sheet_widgets.dart';

/// 右滑侧栏五标签页枚举（覆盖选集、章节、字幕、音轨与画面比例/倍速）。
enum VideoSideSheetTab {
  episodes('选集'),
  chapters('章节'),
  subtitles('字幕'),
  audio('音频'),
  video('画面');

  const VideoSideSheetTab(this.label);
  final String label;
}

/// 内置视频播放器右滑毛玻璃侧栏（复用 [KonataGlassSideSheet] 与 [KonataDraggableScrollbar]）。
class VideoSideSheet extends ConsumerStatefulWidget {
  /// 创建视频侧滑控制面板。
  const VideoSideSheet({
    super.key,
    required this.request,
    required this.initialTab,
    required this.onClose,
  });

  final VideoLaunchRequest request;
  final VideoSideSheetTab initialTab;
  final VoidCallback onClose;

  @override
  ConsumerState<VideoSideSheet> createState() => _VideoSideSheetState();
}

class _VideoSideSheetState extends ConsumerState<VideoSideSheet> {
  late VideoSideSheetTab _tab;
  final ScrollController _epCtrl = ScrollController();
  final ScrollController _chapterCtrl = ScrollController();
  final ScrollController _subCtrl = ScrollController();
  final ScrollController _audioCtrl = ScrollController();
  final ScrollController _videoCtrl = ScrollController();
  final ScrollController _seasonCtrl = ScrollController();
  final GlobalKey _activeEpisodeKey = GlobalKey();
  bool _pendingEpisodeAutoScroll = false;
  String? _lastAutoScrolledEpId;

  late String _browsingWorkId;
  late String _lastPlayingWorkId;
  final Map<String, WorkDetailBundle> _browsingBundles = {};
  bool _loadingBrowsingBundle = false;

  @override
  void initState() {
    super.initState();
    _tab = widget.initialTab;
    _pendingEpisodeAutoScroll = _tab == VideoSideSheetTab.episodes;
    final playingState = ref.read(videoPlaybackProvider(widget.request));
    final initialWork = playingState.currentWork ?? widget.request.work;
    final initialBundle = playingState.currentBundle ?? widget.request.bundle;
    _lastPlayingWorkId = initialWork.id;
    _browsingWorkId = initialWork.id;
    _browsingBundles[initialWork.id] = initialBundle;
  }

  @override
  void didUpdateWidget(covariant VideoSideSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialTab != widget.initialTab) {
      _tab = widget.initialTab;
      if (_tab == VideoSideSheetTab.episodes) {
        _pendingEpisodeAutoScroll = true;
      }
    }
  }

  void _scheduleEpisodeAutoScroll(int activeIndex, int totalCount) {
    if (!_pendingEpisodeAutoScroll || activeIndex < 0 || totalCount <= 0) {
      return;
    }
    _pendingEpisodeAutoScroll = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final ctx = _activeEpisodeKey.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(
          ctx,
          alignment: 0.35,
          duration: KonataTheme.navSliderDuration,
          curve: Curves.easeOutCubic,
        );
        return;
      }
      if (_epCtrl.hasClients) {
        final maxExtent = _epCtrl.position.maxScrollExtent;
        final ratio = activeIndex / (totalCount - 1).clamp(1, totalCount);
        final target = (ratio * maxExtent).clamp(0.0, maxExtent);
        _epCtrl.jumpTo(target);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final nextCtx = _activeEpisodeKey.currentContext;
          if (mounted && nextCtx != null) {
            Scrollable.ensureVisible(
              nextCtx,
              alignment: 0.35,
              duration: KonataTheme.motionMedium,
              curve: Curves.easeOutCubic,
            );
          }
        });
      }
    });
  }

  @override
  void dispose() {
    _epCtrl.dispose();
    _chapterCtrl.dispose();
    _subCtrl.dispose();
    _audioCtrl.dispose();
    _videoCtrl.dispose();
    _seasonCtrl.dispose();
    super.dispose();
  }

  Future<void> _selectBrowsingSeason(
    String targetWorkId,
    VideoPlaybackController controller,
  ) async {
    if (_browsingWorkId == targetWorkId) return;
    setState(() {
      _browsingWorkId = targetWorkId;
    });
    if (_epCtrl.hasClients) {
      _epCtrl.jumpTo(0);
    }
    if (_browsingBundles.containsKey(targetWorkId)) return;

    setState(() => _loadingBrowsingBundle = true);
    final loaded = await controller.loadSeriesWorkBundle(targetWorkId);
    if (!mounted) return;
    setState(() {
      if (loaded != null) {
        _browsingBundles[targetWorkId] = loaded;
      }
      _loadingBrowsingBundle = false;
    });
  }

  Future<void> _pickExternalSubtitle(VideoPlaybackController controller) async {
    try {
      final result = await ref.read(konataSystemFilePickerProvider).pickFiles(
        dialogTitle: '选择外挂字幕文件',
        type: FileType.custom,
        allowedExtensions: KonataMediaExtensions.subtitleExtensionsNoDot,
        allowMultiple: false,
      );
      if (!mounted) return;
      if (result.isEmpty) return;
      final picked = result.first;
      if (!KonataSystemFilePicker.matchesAllowedExtension(
        picked.name,
        KonataMediaExtensions.subtitleExtensionsNoDot,
      )) {
        showKonataToast(
          context,
          '请选择受支持的字幕文件（${KonataMediaExtensions.subtitle.join(' / ')}）',
          isError: true,
        );
        return;
      }
      final path = picked.path;
      if (path != null && path.trim().isNotEmpty) {
        controller.addExternalSubtitleFile(path.trim());
      }
    } catch (e) {
      if (mounted) {
        showKonataToast(context, '打开外挂字幕文件失败：$e', isError: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // 严格排除 positionSeconds 订阅，防止播放期间侧栏列表随跳秒高频重建
    ref.watch(
      videoPlaybackProvider(widget.request).select(
        (s) => (
          s.currentWork,
          s.currentBundle,
          s.currentEpisode,
          s.chapters,
          s.subtitles,
          s.audioTracks,
          s.availableAudioDevices,
          s.availableShaders,
          s.subtitleDelaySeconds,
          s.audioDelaySeconds,
          s.subtitleOpenCcMode,
          s.secondarySubtitleTrackId,
          s.activeSubtitleSubsetState,
          s.isApplyingCloudSubset,
          s.speed,
          s.aspectMode,
          s.audioOnlyMode,
        ),
      ),
    );
    final state = ref.read(videoPlaybackProvider(widget.request));
    final controller = ref.read(videoPlaybackProvider(widget.request).notifier);
    final prefs = ref.watch(playbackPreferencesProvider);
    final pPal = context.palette;

    return KonataGlassSideSheet(
      title: '播放控制台',
      width: KonataPlaybackTokens.videoSideSheetWidth,
      bottomInset: KonataAdaptiveTokens.isAndroid
          ? 16.0
          : KonataPlaybackTokens.videoSideSheetBottomInset,
      onClose: widget.onClose,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: MediaQuery.withClampedTextScaling(
              maxScaleFactor: 1.15,
              child: KonataSegmentedCapsule<VideoSideSheetTab>(
                expand: true,
                compact: MediaQuery.sizeOf(context).width < 520,
                options: const [
                  KonataSegmentOption(
                    value: VideoSideSheetTab.episodes,
                    label: '选集',
                  ),
                  KonataSegmentOption(
                    value: VideoSideSheetTab.chapters,
                    label: '章节',
                  ),
                  KonataSegmentOption(
                    value: VideoSideSheetTab.subtitles,
                    label: '字幕',
                  ),
                  KonataSegmentOption(
                    value: VideoSideSheetTab.audio,
                    label: '音频',
                  ),
                  KonataSegmentOption(
                    value: VideoSideSheetTab.video,
                    label: '画面',
                  ),
                ],
                selected: _tab,
                onChanged: (next) => setState(() {
                  _tab = next;
                  if (next == VideoSideSheetTab.episodes) {
                    _pendingEpisodeAutoScroll = true;
                  }
                }),
              ),
            ),
          ),
          Expanded(
            child: KonataSmoothSectionSwitcher(
              switchKey: _tab,
              alignment: Alignment.topLeft,
              child: switch (_tab) {
                VideoSideSheetTab.episodes => _buildEpisodesTab(
                  pPal,
                  state,
                  controller,
                ),
                VideoSideSheetTab.chapters => _buildChaptersTab(
                  pPal,
                  state.chapters,
                  controller,
                ),
                VideoSideSheetTab.subtitles => _buildSubtitlesTab(
                  pPal,
                  state,
                  prefs,
                  controller,
                ),
                VideoSideSheetTab.audio => _buildAudioTab(
                  pPal,
                  state,
                  prefs,
                  controller,
                ),
                VideoSideSheetTab.video => _buildVideoTab(
                  pPal,
                  state,
                  prefs,
                  controller,
                ),
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChaptersTab(
    KonataPalette pPal,
    List<PlaybackChapter> chapters,
    VideoPlaybackController controller,
  ) {
    if (chapters.isEmpty) {
      return Center(
        child: Text(
          '当前视频未内嵌章节标记',
          style: TextStyle(color: pPal.textMuted, fontSize: KonataTheme.fontSizeBodyXs),
        ),
      );
    }
    return _ChapterListLeaf(
      request: widget.request,
      chapters: chapters,
      scrollController: _chapterCtrl,
      onSeekChapter: (sec) => controller.seekAbsolute(sec),
    );
  }

  Widget _buildEpisodesTab(
    KonataPalette pPal,
    VideoPlaybackState state,
    VideoPlaybackController controller,
  ) {
    final playingWork = state.currentWork ?? widget.request.work;
    final playingBundle = state.currentBundle ?? widget.request.bundle;
    _browsingBundles[playingWork.id] = playingBundle;

    if (_lastPlayingWorkId != playingWork.id) {
      _lastPlayingWorkId = playingWork.id;
      _browsingWorkId = playingWork.id;
      _pendingEpisodeAutoScroll = true;
    }

    final seriesMembers = controller.orderedSeriesMembers;
    final browsingBundle = _browsingBundles[_browsingWorkId] ?? playingBundle;
    final browsingWork = browsingBundle.work;
    final isBrowsingPlayingWork = browsingWork.id == playingWork.id;

    final playable = Episode.sortMainFirst(
      browsingBundle.episodes.where(
        (e) => browsingBundle.variantsForEpisode(e.id).isNotEmpty,
      ),
    );
    final browsingMainCount = browsingBundle.episodes
        .where((e) => e.category == EpisodeCategory.main)
        .length;
    final activeIdx = isBrowsingPlayingWork
        ? playable.indexWhere((e) => e.id == state.currentEpisode.id)
        : -1;
    final scrollKey = '${playingWork.id}::${state.currentEpisode.id}';
    if (isBrowsingPlayingWork && _lastAutoScrolledEpId != scrollKey) {
      _lastAutoScrolledEpId = scrollKey;
      _pendingEpisodeAutoScroll = true;
    }
    if (isBrowsingPlayingWork) {
      _scheduleEpisodeAutoScroll(activeIdx, playable.length);
    }

    Widget listBody;
    if (_loadingBrowsingBundle && _browsingBundles[_browsingWorkId] == null) {
      listBody = const Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2.2),
        ),
      );
    } else if (playable.isEmpty) {
      listBody = Center(
        child: Text(
          '当前季暂无可播放剧集',
          style: TextStyle(color: pPal.textMuted, fontSize: KonataTheme.fontSizeBodyXs),
        ),
      );
    } else {
      listBody = KonataDraggableScrollbar(
        controller: _epCtrl,
        padding: const EdgeInsets.only(right: 4),
        builder: (_, ctrl) => ListView.separated(
          controller: ctrl,
          padding: const EdgeInsets.fromLTRB(16, 0, 20, 20),
          itemCount: playable.length,
          separatorBuilder: (_, _) => const SizedBox(height: 8),
          itemBuilder: (context, index) {
            final ep = playable[index];
            // 严格同时校验 workId 与 episodeId，杜绝跨季同集号高亮串位
            final active =
                isBrowsingPlayingWork && ep.id == state.currentEpisode.id;
            final rec = browsingBundle.playbackByEpisodeId[ep.id];
            final title = EpisodeTitleFormatter.formatCardTitle(
              episode: ep,
              workTitle: browsingWork.title,
              workMediaType: browsingWork.tmdbMediaType,
              mainEpisodeCount: browsingMainCount,
            );
            final completed = rec != null && rec.isCompleted;

            return KeyedSubtree(
              key: active ? _activeEpisodeKey : null,
              child: _SelectableTrackTile(
                primaryTitle: title,
                selected: active,
                leadingIcon: active
                    ? Icons.play_arrow_rounded
                    : Icons.movie_outlined,
                customTrailingBadge: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (completed) ...[
                      KonataSpecBadge(label: '已看完', highlighted: active),
                      const SizedBox(width: 6),
                    ],
                    EpisodeCategoryBadge(isSpecial: ep.isSpecial),
                  ],
                ),
                onTap: active
                    ? null
                    : () => unawaited(
                        controller.switchToEpisode(
                          ep,
                          targetBundle: browsingBundle,
                          isCrossSeason: !isBrowsingPlayingWork,
                        ),
                      ),
              ),
            );
          },
        ),
      );
    }

    if (seriesMembers.length < 2) {
      return listBody;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SeriesSeasonSwitcherBar(
          scrollController: _seasonCtrl,
          seriesGroup: playingBundle.seriesGroup,
          seriesMembers: seriesMembers,
          browsingWorkId: _browsingWorkId,
          playingWorkId: playingWork.id,
          onSelectSeason: (workId) =>
              unawaited(_selectBrowsingSeason(workId, controller)),
        ),
        const SizedBox(height: 8),
        Expanded(child: listBody),
      ],
    );
  }

  Widget _buildSubtitlesTab(
    KonataPalette pPal,
    VideoPlaybackState state,
    PlaybackPreferencesState prefs,
    VideoPlaybackController controller,
  ) {
    final anySelected = state.subtitles.any((s) => s.selected);
    return KonataDraggableScrollbar(
      controller: _subCtrl,
      padding: const EdgeInsets.only(right: 4),
      builder: (_, ctrl) => ListView(
        controller: ctrl,
        padding: const EdgeInsets.fromLTRB(16, 0, 20, 24),
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '字幕轨道',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: pPal.textPrimary,
                    fontSize: KonataTheme.fontSizeBody,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              KonataPillButton.ghost(
                label: '加载外挂字幕',
                icon: Icons.add_rounded,
                compact: true,
                onPressed: () => _pickExternalSubtitle(controller),
              ),
            ],
          ),
          const SizedBox(height: 6),
          _SelectableTrackTile(
            primaryTitle: '关闭字幕',
            selected: !anySelected,
            onTap: () => controller.selectSubtitle(null),
          ),
          const SizedBox(height: 6),
          for (final sub in state.subtitles) ...[
            _SelectableTrackTile(
              primaryTitle: sub.primaryTitle,
              badgeLabel: sub.isCloudSubset ? null : sub.sourceFormatBadge,
              customTrailingBadge: sub.isCloudSubset
                  ? KonataSpecBadge(
                      label: sub.sourceFormatBadge,
                      highlighted: true,
                    )
                  : null,
              tooltipMessage: sub.rawTooltip,
              selected: sub.selected,
              onTap: () => controller.selectSubtitle(sub),
            ),
            const SizedBox(height: 6),
          ],
          if (state.subtitles.isNotEmpty) ...[
            const SizedBox(height: 10),
            _SectionLabel(pPal, '双语副字幕 (Secondary)'),
            const SizedBox(height: 6),
            Builder(
              builder: (_) {
                int? selectedSecondaryIdx;
                if (state.secondarySubtitleTrackId != null) {
                  final idx = state.subtitles.indexWhere(
                    (s) => s.mpvTrackId == state.secondarySubtitleTrackId,
                  );
                  if (idx >= 0) selectedSecondaryIdx = idx;
                }
                return KonataDropdown<int?>(
                  key: const ValueKey('secondary_subtitle_dropdown'),
                  dense: true,
                  value: selectedSecondaryIdx,
                  options: [
                    const KonataDropdownOption<int?>(
                      value: null,
                      label: '关闭副字幕',
                    ),
                    for (var i = 0; i < state.subtitles.length; i++)
                      KonataDropdownOption<int?>(
                        value: i,
                        label:
                            '${state.subtitles[i].primaryTitle} [${state.subtitles[i].sourceFormatBadge}]',
                      ),
                  ],
                  onChanged: (idx) => unawaited(
                    controller.selectSecondarySubtitle(
                      idx == null ? null : state.subtitles[idx],
                    ),
                  ),
                );
              },
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(child: _SectionLabel(pPal, '内存字幕增强 (OpenCC)')),
                if (state.activeSubtitleSubsetState ==
                    SubtitleSubsetState.opaqueObfuscatedSubset)
                  const KonataSpecBadge(
                    key: ValueKey('subtitle_subset_guard_badge'),
                    label: '混淆子集已保护',
                    highlighted: true,
                  ),
              ],
            ),
            const SizedBox(height: 6),
            KonataSegmentedCapsule<SubtitleOpenCcMode>(
              key: const ValueKey('subtitle_opencc_segmented'),
              expand: true,
              compact: true,
              options: const [
                KonataSegmentOption(
                  value: SubtitleOpenCcMode.none,
                  label: '原文',
                ),
                KonataSegmentOption(
                  value: SubtitleOpenCcMode.toSimplified,
                  label: '转简体',
                ),
                KonataSegmentOption(
                  value: SubtitleOpenCcMode.toTraditional,
                  label: '转繁体',
                ),
              ],
              selected: state.subtitleOpenCcMode,
              onChanged: (mode) =>
                  unawaited(controller.setSubtitleOpenCcMode(mode)),
            ),
          ],
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(child: _SectionLabel(pPal, '时间轴微调与样式')),
              if (state.subtitleDelaySeconds != 0 ||
                  state.subtitleOpenCcMode != SubtitleOpenCcMode.none ||
                  prefs.qualityConfig.subFontSize !=
                      PlaybackQualityConfig.defaultSubFontSize ||
                  prefs.qualityConfig.subBottomMargin !=
                      PlaybackQualityConfig.defaultSubBottomMargin ||
                  prefs.qualityConfig.subOverrideMode !=
                      SubtitleAssOverrideMode.preserveAss)
                KonataPillButton.ghost(
                  label: '恢复默认',
                  icon: Icons.restart_alt_rounded,
                  compact: true,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  onPressed: () =>
                      unawaited(controller.resetSubtitleAdjustments()),
                ),
            ],
          ),
          const SizedBox(height: 8),
          _DelayStepperRow(
            pPal: pPal,
            label: '字幕延迟',
            delaySeconds: state.subtitleDelaySeconds,
            onDelta: (d) =>
                controller.setSubtitleDelay(state.subtitleDelaySeconds + d),
            onReset: () => controller.setSubtitleDelay(0),
          ),
          if (state.subtitleDelaySeconds.abs() >= 0.01 &&
              controller.hasExternalTextSubtitleSource) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '离线重映射时间戳并归零延迟',
                    style: TextStyle(color: pPal.textMuted, fontSize: KonataTheme.fontSizeCaptionSm),
                  ),
                ),
                const SizedBox(width: 8),
                KonataPillButton.ghost(
                  key: const ValueKey('bake_subtitle_timeline_button'),
                  label: '固化时间轴',
                  icon: Icons.auto_fix_high_rounded,
                  compact: true,
                  onPressed: () =>
                      unawaited(controller.bakeSubtitleTimelineOffset()),
                ),
              ],
            ),
          ],
          if (prefs.cloudSubsetEnabled &&
              controller.hasExternalTextSubtitleSource) ...[
            const SizedBox(height: 10),
            KonataSurfaceCard(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '字幕子集化',
                          style: TextStyle(
                            color: pPal.textPrimary,
                            fontSize: KonataTheme.fontSizeBodyXs,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '按需提取云端特效字库并新增独立对比轨',
                          style: TextStyle(
                            color: pPal.textMuted,
                            fontSize: KonataTheme.fontSizeCaptionSm,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  KonataPillButton.primary(
                    key: const ValueKey('apply_cloud_subset_button'),
                    label: state.isApplyingCloudSubset ? '子集化中...' : '字幕子集化',
                    icon: state.isApplyingCloudSubset
                        ? null
                        : Icons.auto_awesome_rounded,
                    trailing: state.isApplyingCloudSubset
                        ? SizedBox(
                            width: 12,
                            height: 12,
                            child: CircularProgressIndicator(
                              strokeWidth: 1.8,
                              color: pPal.primaryButtonFg,
                            ),
                          )
                        : null,
                    compact: true,
                    onPressed: state.isApplyingCloudSubset
                        ? null
                        : () => unawaited(
                            controller.applyCloudSubsetToActiveSubtitle(),
                          ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 12),
          Text(
            '字号：${prefs.qualityConfig.subFontSize}',
            style: TextStyle(color: pPal.textSecondary, fontSize: KonataTheme.fontSizeBodyXs),
          ),
          Slider(
            key: const ValueKey('subtitle_font_size_slider'),
            value: prefs.qualityConfig.subFontSize.toDouble().clamp(24, 96),
            min: 24,
            max: 96,
            divisions: 72,
            onChanged: (v) => controller.previewLiveSubtitleStyle(
              (c) => c.copyWith(
                subFontSize: v.round(),
                subOverrideMode:
                    c.subOverrideMode == SubtitleAssOverrideMode.preserveAss
                    ? SubtitleAssOverrideMode.scaleOnly
                    : c.subOverrideMode,
              ),
            ),
            onChangeEnd: (_) => unawaited(controller.commitLiveSubtitleStyle()),
          ),
          Text(
            '底部边距：${prefs.qualityConfig.subBottomMargin}px',
            style: TextStyle(color: pPal.textSecondary, fontSize: KonataTheme.fontSizeBodyXs),
          ),
          Slider(
            key: const ValueKey('subtitle_bottom_margin_slider'),
            value: prefs.qualityConfig.subBottomMargin.toDouble().clamp(0, 120),
            min: 0,
            max: 120,
            divisions: 60,
            onChanged: (v) => controller.previewLiveSubtitleStyle(
              (c) => c.copyWith(
                subBottomMargin: v.round(),
                subOverrideMode: SubtitleAssOverrideMode.forceStyle,
              ),
            ),
            onChangeEnd: (_) => unawaited(controller.commitLiveSubtitleStyle()),
          ),
          const SizedBox(height: 8),
          Text(
            'ASS 样式覆写模式',
            style: TextStyle(color: pPal.textSecondary, fontSize: KonataTheme.fontSizeBodyXs),
          ),
          const SizedBox(height: 6),
          KonataDropdown<SubtitleAssOverrideMode>(
            value: prefs.qualityConfig.subOverrideMode,
            options: const [
              KonataDropdownOption(
                value: SubtitleAssOverrideMode.preserveAss,
                label: '高保真保留原盘特效 (推荐)',
              ),
              KonataDropdownOption(
                value: SubtitleAssOverrideMode.scaleOnly,
                label: '仅允许缩放字号 (Scale)',
              ),
              KonataDropdownOption(
                value: SubtitleAssOverrideMode.forceStyle,
                label: '统一覆写字体与边距 (Force)',
              ),
            ],
            onChanged: (mode) {
              controller.previewLiveSubtitleStyle(
                (c) => c.copyWith(subOverrideMode: mode),
              );
              unawaited(controller.commitLiveSubtitleStyle());
            },
          ),
        ],
      ),
    );
  }

  Widget _buildAudioTab(
    KonataPalette pPal,
    VideoPlaybackState state,
    PlaybackPreferencesState prefs,
    VideoPlaybackController controller,
  ) {
    final deviceOptions = <KonataDropdownOption<String>>[
      const KonataDropdownOption(value: 'auto', label: '系统默认音频输出 (Auto)'),
      for (final d in state.availableAudioDevices)
        if (d.name != 'auto')
          KonataDropdownOption(
            value: d.name,
            label: d.description.isNotEmpty ? d.description : d.name,
          ),
    ];
    final currentDevice = deviceOptions.any(
      (o) => o.value == prefs.qualityConfig.audioDevice,
    )
        ? prefs.qualityConfig.audioDevice
        : 'auto';

    return KonataDraggableScrollbar(
      controller: _audioCtrl,
      padding: const EdgeInsets.only(right: 4),
      builder: (_, ctrl) => ListView(
        controller: ctrl,
        padding: const EdgeInsets.fromLTRB(16, 0, 20, 24),
        children: [
          _SectionLabel(pPal, '音轨切换'),
          const SizedBox(height: 8),
          if (state.audioTracks.isEmpty)
            Text(
              '未检测到可选音轨',
              style: TextStyle(color: pPal.textMuted, fontSize: KonataTheme.fontSizeBodyXs),
            )
          else
            for (final aud in state.audioTracks) ...[
              _SelectableTrackTile(
                primaryTitle: aud.primaryTitle,
                badgeLabel: aud.sourceFormatBadge,
                tooltipMessage: aud.rawTooltip,
                selected: aud.selected,
                onTap: () => controller.selectAudioTrack(aud),
              ),
              const SizedBox(height: 6),
            ],
          const SizedBox(height: 14),
          _SectionLabel(pPal, '输出设备与声画同步'),
          const SizedBox(height: 8),
          KonataDropdown<String>(
            value: currentDevice,
            options: deviceOptions,
            onChanged: (dev) => controller.updateLiveQuality(
              (c) => c.copyWith(audioDevice: dev),
            ),
          ),
          const SizedBox(height: 12),
          _DelayStepperRow(
            pPal: pPal,
            label: '音频延迟',
            delaySeconds: state.audioDelaySeconds,
            onDelta: (d) =>
                controller.setAudioDelay(state.audioDelaySeconds + d),
            onReset: () => controller.setAudioDelay(0),
          ),
          if (KonataAdaptiveTokens.isWindows) ...[
            const SizedBox(height: 12),
            KonataListTile(
              padding: const EdgeInsets.symmetric(vertical: 8),
              title: ref.watch(platformExclusiveAudioSheetTitleProvider),
              subtitle: '绕过系统混音器以比特精确输出源码',
              trailing: KonataSwitch(
                value: prefs.qualityConfig.exclusiveAudioOutput,
                onChanged: (v) async {
                  await controller.updateLiveQuality(
                    (c) => c.copyWith(exclusiveAudioOutput: v),
                  );
                  await ref
                      .read(audiophileSafetyCoordinatorProvider)
                      .reapplyAll(ref.read(playbackPreferencesProvider));
                },
              ),
            ),
            KonataListTile(
              key: const ValueKey('video_sheet_hdmi_spdif_switch'),
              padding: const EdgeInsets.symmetric(vertical: 8),
              title: ref.watch(platformBitstreamTitleProvider),
              subtitle: '透传 AC3 / DTS-HD / TrueHD 比特流，严格互斥清空软 DSP',
              trailing: KonataSwitch(
                value: prefs.bitstreamPassthrough,
                onChanged: (v) async {
                  await ref
                      .read(playbackPreferencesProvider.notifier)
                      .setBitstreamPassthrough(v);
                  await ref
                      .read(audiophileSafetyCoordinatorProvider)
                      .reapplyAll(ref.read(playbackPreferencesProvider));
                },
              ),
            ),
          ],
          if (KonataAdaptiveTokens.isAndroid) ...[
            const SizedBox(height: 12),
            KonataListTile(
              key: const ValueKey('video_sheet_android_usb_bit_perfect'),
              padding: const EdgeInsets.symmetric(vertical: 8),
              title: 'USB DAC 逐位直通 (Android 14+)',
              subtitle: '尝试协商原生逐位混音器，未连接兼容外设时保持高精共享通道',
              trailing: KonataSwitch(
                value: prefs.androidBitPerfectUsb,
                onChanged: (v) async {
                  await ref
                      .read(playbackPreferencesProvider.notifier)
                      .setAndroidBitPerfectUsb(v);
                  await ref
                      .read(audiophileSafetyCoordinatorProvider)
                      .reapplyAll(ref.read(playbackPreferencesProvider));
                },
              ),
            ),
          ],
          const SizedBox(height: 10),
          Builder(
            builder: (context) {
              ref.watch(audiophileSafetyRevisionProvider);
              final safety = ref
                  .read(audiophileSafetyCoordinatorProvider)
                  .deviceSafetyState;
              final hdmiOn =
                  KonataAdaptiveTokens.isWindows && prefs.bitstreamPassthrough;
              return Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: pPal.softFill,
                  borderRadius: BorderRadius.circular(
                    KonataTheme.radiusControl,
                  ),
                  border: Border.all(color: pPal.hairline),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      hdmiOn
                          ? '当前已启用 HDMI audio-spdif 比特流直通，软件 DSP 与限幅器已严格清空。'
                          : safety.allowFullScaleBypass
                          ? '当前外设已于本次会话确认解锁满幅逐位直通，拔插外设将自动复位安全衰减。'
                          : '${AudiophileSafetyPolicy.unverifiedFullScaleLockReason}。',
                      style: KonataTheme.captionStyle(
                        pPal,
                        color: pPal.textSecondary,
                        height: 1.4,
                      ),
                    ),
                    if (!hdmiOn && !safety.allowFullScaleBypass) ...[
                      const SizedBox(height: 8),
                      KonataPillButton.ghost(
                        key: const ValueKey(
                          'video_sheet_audiophile_unlock_button',
                        ),
                        label: '当次会话满幅确认',
                        icon: Icons.shield_outlined,
                        compact: true,
                        onPressed: () =>
                            showAudiophileFullScaleUnlockDialog(context, ref),
                      ),
                    ],
                  ],
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildVideoTab(
    KonataPalette pPal,
    VideoPlaybackState state,
    PlaybackPreferencesState prefs,
    VideoPlaybackController controller,
  ) {
    final speeds = const [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0];

    return KonataDraggableScrollbar(
      controller: _videoCtrl,
      padding: const EdgeInsets.only(right: 4),
      builder: (_, ctrl) => ListView(
        controller: ctrl,
        padding: const EdgeInsets.fromLTRB(16, 0, 20, 24),
        children: [
          _SectionLabel(pPal, '渲染画质与解码策略'),
          const SizedBox(height: 8),
          KonataDropdown<VideoQualityPreset>(
            value: prefs.qualityConfig.preset,
            options: [
              for (final preset in VideoQualityPreset.values)
                KonataDropdownOption(value: preset, label: preset.label),
            ],
            onChanged: (preset) => controller.updateLiveQuality(
              (c) => c.copyWith(preset: preset),
            ),
          ),
          const SizedBox(height: 8),
          KonataListTile(
            padding: const EdgeInsets.symmetric(vertical: 8),
            title: '硬件视频解码',
            subtitle: ref.watch(platformHwdecSubtitleProvider),
            trailing: KonataSwitch(
              value: prefs.qualityConfig.hardwareDecode,
              onChanged: (v) => controller.updateLiveQuality(
                (c) => c.copyWith(hardwareDecode: v),
              ),
            ),
          ),
          KonataListTile(
            padding: const EdgeInsets.symmetric(vertical: 8),
            title: '去色带滤镜 (Deband)',
            subtitle: '平滑低码率动漫暗场渐变色块',
            trailing: KonataSwitch(
              value: prefs.qualityConfig.debandEnabled,
              onChanged: (v) => controller.updateLiveQuality(
                (c) => c.copyWith(debandEnabled: v),
              ),
            ),
          ),
          const SizedBox(height: 12),
          _SectionLabel(pPal, '画面比例'),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final mode in VideoAspectMode.values)
                _SpeedPillButton(
                  label: mode.label,
                  selected: state.aspectMode == mode,
                  onTap: () => controller.setAspectMode(mode),
                ),
            ],
          ),
          const SizedBox(height: 14),
          _SectionLabel(pPal, '播放倍速'),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final s in speeds)
                _SpeedPillButton(
                  label: '${s}x',
                  selected: (state.speed - s).abs() < 0.02,
                  onTap: () => controller.setPlaybackSpeed(s),
                ),
            ],
          ),
          const SizedBox(height: 12),
          KonataListTile(
            padding: const EdgeInsets.symmetric(vertical: 8),
            title: '后台纯音频模式',
            subtitle: '暂停视频画面渲染，仅保留音轨低功耗连续播放',
            trailing: KonataSwitch(
              value: state.audioOnlyMode,
              onChanged: controller.setAudioOnlyMode,
            ),
          ),
          const SizedBox(height: 14),
          _SectionLabel(pPal, '原画截图'),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              KonataPillButton.ghost(
                key: const ValueKey('video_sheet_screenshot_pure_button'),
                label: KonataAdaptiveTokens.isAndroid
                    ? '纯净原画'
                    : '纯净原画帧 (S)',
                icon: Icons.photo_camera_outlined,
                compact: true,
                onPressed: () => unawaited(
                  controller.captureScreenshot(
                    mode: ScreenshotCaptureMode.pureVideo,
                  ),
                ),
              ),
              KonataPillButton.ghost(
                key: const ValueKey('video_sheet_screenshot_subtitled_button'),
                label: KonataAdaptiveTokens.isAndroid
                    ? '带字幕合成'
                    : '带字幕合成帧 (Shift+S)',
                icon: Icons.subtitles_outlined,
                compact: true,
                onPressed: () => unawaited(
                  controller.captureScreenshot(
                    mode: ScreenshotCaptureMode.withSubtitles,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _SectionLabel(pPal, 'GLSL 着色器链'),
          const SizedBox(height: 6),
          if (state.availableShaders.isEmpty)
            Text(
              KonataAdaptiveTokens.isAndroid
                  ? '请先在「设置 → 播放器」中导入 .glsl / .hook 超分脚本（如 Anime4K），随后即可在此实时勾选叠加。'
                  : '请将 .glsl / .hook 着色器脚本放入 userdata/shaders/ 目录后即可在此实时勾选叠加。',
              style: TextStyle(color: pPal.textMuted, fontSize: KonataTheme.fontSizeCaption, height: 1.45),
            )
          else
            for (final file in state.availableShaders) ...[
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: Text(
                  p.basename(file.path),
                  style: TextStyle(color: pPal.textPrimary, fontSize: KonataTheme.fontSizeBodyXs),
                ),
                value: prefs.qualityConfig.activeShaderPaths.contains(file.path),
                onChanged: (checked) {
                  controller.updateLiveQuality((c) {
                    final next = List<String>.from(c.activeShaderPaths);
                    if (checked == true) {
                      if (!next.contains(file.path)) next.add(file.path);
                    } else {
                      next.remove(file.path);
                    }
                    return c.copyWith(activeShaderPaths: next);
                  });
                },
              ),
            ],
        ],
      ),
    );
  }
}
