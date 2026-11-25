part of 'video_side_sheet.dart';

class _EpisodesSection extends StatelessWidget {
  const _EpisodesSection({required this.controller, required this.state});

  final VideoPlaybackController controller;
  final VideoPlaybackState state;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final bundle = state.currentBundle;
    final episodes = bundle?.episodes ?? const <EpisodeRecord>[];
    final members = bundle?.seriesMembers ?? const <WorkRecord>[];

    if (episodes.isEmpty) {
      return Center(
        child: Text(
          '暂无分集数据',
          style: TextStyle(color: p.textMuted, fontSize: 13),
        ),
      );
    }

    final sameEpVariants =
        bundle?.variantsForEpisode(state.currentEpisode.id) ??
        const <MediaVariantRecord>[];

    return KonataDraggableScrollbar(
      builder: (context, scrollController) {
        return ListView(
          controller: scrollController,
          padding: const EdgeInsets.only(right: 8),
          children: [
            if (members.length > 1) ...[
              Text(
                '所属系列季度',
                style: TextStyle(
                  color: p.textSecondary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (var i = 0; i < members.length; i++)
                    KonataPillButton.secondary(
                      compact: true,
                      label: VideoSeriesHelper.formatMemberLabel(
                        members[i],
                        members,
                        seriesGroup: bundle?.seriesGroup,
                        fallbackOrder: i + 1,
                      ),
                      borderColor: members[i].id == state.currentWork?.id
                          ? p.accent
                          : null,
                      onPressed: () =>
                          unawaited(controller.switchSeriesWork(members[i].id)),
                    ),
                ],
              ),
              const SizedBox(height: 12),
            ],
            if (sameEpVariants.length > 1) ...[
              Text(
                '当前分集版本切换',
                style: TextStyle(
                  color: p.textSecondary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 6),
              for (final variant in sameEpVariants)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: _SelectableOptionRow(
                    title: VideoSeriesHelper.formatVariantSummary(variant),
                    selected: variant.id == state.currentVariant.id,
                    onTap: () => unawaited(controller.switchVariant(variant)),
                  ),
                ),
              const SizedBox(height: 10),
            ],
            for (final ep in episodes)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: _SelectableOptionRow(
                  title: EpisodeTitleFormatter.formatCardTitle(
                    episode: ep.toSummaryView(),
                    workTitle: state.currentWork?.title,
                    workMediaType: state.currentWork?.tmdbMediaType,
                    mainEpisodeCount: bundle?.mainEpisodes.length,
                  ),
                  subtitle:
                      (bundle?.playbackByEpisodeId[ep.id.value]?.isCompleted ??
                          false)
                      ? '已看完'
                      : null,
                  selected: ep.id == state.currentEpisode.id,
                  trailing: KonataCapsuleIconButton(
                    icon:
                        (ep.id == state.currentEpisode.id
                            ? state.isCompletedCurrentEpisode
                            : (bundle
                                      ?.playbackByEpisodeId[ep.id.value]
                                      ?.isCompleted ??
                                  false))
                        ? Icons.check_circle_rounded
                        : Icons.check_circle_outline_rounded,
                    tooltip: '切换看完状态',
                    size: 18,
                    color: p.accent,
                    onTap: () {
                      final currentlyCompleted =
                          ep.id == state.currentEpisode.id
                          ? state.isCompletedCurrentEpisode
                          : (bundle
                                    ?.playbackByEpisodeId[ep.id.value]
                                    ?.isCompleted ??
                                false);
                      unawaited(
                        controller.markEpisodeCompleted(
                          ep.id,
                          completed: !currentlyCompleted,
                        ),
                      );
                    },
                  ),
                  onTap: () => unawaited(controller.switchEpisode(ep)),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _ChaptersSection extends StatelessWidget {
  const _ChaptersSection({required this.controller, required this.state});

  final VideoPlaybackController controller;
  final VideoPlaybackState state;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    if (state.chapters.isEmpty) {
      return Center(
        child: Text(
          '当前视频未嵌入章节标记',
          style: TextStyle(color: p.textMuted, fontSize: 13),
        ),
      );
    }
    return KonataDraggableScrollbar(
      builder: (context, scrollController) {
        return ListView.builder(
          controller: scrollController,
          padding: const EdgeInsets.only(right: 8),
          itemCount: state.chapters.length,
          itemBuilder: (context, idx) {
            final ch = state.chapters[idx];
            return Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: _SelectableOptionRow(
                title: ch.title.trim().isEmpty
                    ? '第 ${ch.index + 1} 章'
                    : ch.title.trim(),
                subtitle: PlaybackRecordHelper.formatClock(
                  ch.startSeconds.round(),
                ),
                selected: false,
                onTap: () => unawaited(controller.seekToChapter(ch)),
              ),
            );
          },
        );
      },
    );
  }
}

class _SubtitlesSection extends StatelessWidget {
  const _SubtitlesSection({required this.controller, required this.state});

  final VideoPlaybackController controller;
  final VideoPlaybackState state;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return KonataDraggableScrollbar(
      builder: (context, scrollController) {
        return ListView(
          controller: scrollController,
          padding: const EdgeInsets.only(right: 8),
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                KonataPillButton.secondary(
                  compact: true,
                  icon: Icons.add_rounded,
                  label: '挂载外挂字幕',
                  onPressed: () =>
                      unawaited(controller.pickAndAddExternalSubtitle()),
                ),
                KonataPillButton.secondary(
                  compact: true,
                  icon: Icons.cloud_sync_outlined,
                  label: state.isApplyingCloudSubset ? '字库子集化中…' : '云端子集化',
                  onPressed: state.isApplyingCloudSubset
                      ? null
                      : () => unawaited(
                          controller.applyCloudSubsetToCurrentSubtitle(),
                        ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            KonataSegmentedCapsule<SubtitleOpenCcMode>(
              expand: true,
              compact: true,
              selected: state.subtitleOpenCcMode,
              options: const <KonataSegmentOption<SubtitleOpenCcMode>>[
                KonataSegmentOption(
                  value: SubtitleOpenCcMode.none,
                  label: '原字形',
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
              onChanged: (mode) =>
                  unawaited(controller.setSubtitleOpenCcMode(mode)),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Text(
                  '字幕偏移: ${state.subtitleDelaySeconds.toStringAsFixed(1)}s',
                  style: TextStyle(color: p.textSecondary, fontSize: 12),
                ),
                const Spacer(),
                KonataPillButton.ghost(
                  compact: true,
                  label: '-0.5s',
                  onPressed: () => controller.adjustSubtitleDelay(-0.5),
                ),
                KonataPillButton.ghost(
                  compact: true,
                  label: '归零',
                  onPressed: () => controller.setSubtitleDelay(0.0),
                ),
                KonataPillButton.ghost(
                  compact: true,
                  label: '+0.5s',
                  onPressed: () => controller.adjustSubtitleDelay(0.5),
                ),
              ],
            ),
            const SizedBox(height: 8),
            _SelectableOptionRow(
              title: '关闭主字幕',
              selected: state.subtitles.every((s) => !s.selected),
              onTap: () => unawaited(controller.selectSubtitleChoice(null)),
            ),
            const SizedBox(height: 6),
            for (final sub in state.subtitles)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: _SelectableOptionRow(
                  title: sub.primaryTitle,
                  subtitle: sub.sourceFormatBadge,
                  selected: sub.selected,
                  onTap: () => unawaited(controller.selectSubtitleChoice(sub)),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _AudioSection extends StatelessWidget {
  const _AudioSection({
    required this.controller,
    required this.state,
    required this.currentAudioDevice,
  });

  final VideoPlaybackController controller;
  final VideoPlaybackState state;
  final String currentAudioDevice;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return KonataDraggableScrollbar(
      builder: (context, scrollController) {
        return ListView(
          controller: scrollController,
          padding: const EdgeInsets.only(right: 8),
          children: [
            Row(
              children: [
                Text(
                  '音频延迟: ${state.audioDelaySeconds.toStringAsFixed(2)}s',
                  style: TextStyle(color: p.textSecondary, fontSize: 12),
                ),
                const Spacer(),
                KonataPillButton.ghost(
                  compact: true,
                  label: '-0.1s',
                  onPressed: () =>
                      controller.setAudioDelay(state.audioDelaySeconds - 0.1),
                ),
                KonataPillButton.ghost(
                  compact: true,
                  label: '归零',
                  onPressed: () => controller.setAudioDelay(0.0),
                ),
                KonataPillButton.ghost(
                  compact: true,
                  label: '+0.1s',
                  onPressed: () =>
                      controller.setAudioDelay(state.audioDelaySeconds + 0.1),
                ),
              ],
            ),
            const SizedBox(height: 10),
            for (final track in state.audioTracks)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: _SelectableOptionRow(
                  title: track.title.trim().isEmpty
                      ? '音轨 #${track.mpvTrackId ?? ''}'
                      : track.title.trim(),
                  subtitle: [
                    if (track.language.isNotEmpty) track.language,
                    if (track.codec.isNotEmpty) track.codec.toUpperCase(),
                  ].join(' · '),
                  selected: track.selected,
                  onTap: () => unawaited(controller.selectAudioTrack(track)),
                ),
              ),
            if (state.availableAudioDevices.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                '音频输出设备',
                style: TextStyle(
                  color: p.textSecondary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 6),
              for (final dev in state.availableAudioDevices)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: _SelectableOptionRow(
                    title: dev.description.isEmpty ? dev.name : dev.description,
                    subtitle: dev.name,
                    selected: dev.name == currentAudioDevice,
                    onTap: () =>
                        unawaited(controller.selectAudioDevice(dev.name)),
                  ),
                ),
            ],
          ],
        );
      },
    );
  }
}

class _VideoAndShadersSection extends StatelessWidget {
  const _VideoAndShadersSection({
    required this.controller,
    required this.state,
    required this.activeShaderPaths,
    required this.quality,
  });

  final VideoPlaybackController controller;
  final VideoPlaybackState state;
  final List<String> activeShaderPaths;
  final PlaybackQualityConfig quality;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return KonataDraggableScrollbar(
      builder: (context, scrollController) {
        return ListView(
          controller: scrollController,
          padding: const EdgeInsets.only(right: 8),
          children: [
            Text('渲染画质与解码策略', style: KonataTheme.bodyLabelStyle(p)),
            const SizedBox(height: 8),
            KonataDropdown<VideoQualityPreset>(
              value: quality.preset,
              options: [
                for (final preset in VideoQualityPreset.values)
                  KonataDropdownOption(value: preset, label: preset.label),
              ],
              onChanged: (preset) => controller.env.preferencesStore
                  .updateQualityConfig((c) => c.copyWith(preset: preset)),
            ),
            const SizedBox(height: 8),
            AdaptiveSettingTile(
              title: '硬件视频解码',
              subtitle: '自动启用硬件加速，异常源回退软解',
              trailing: KonataSwitch(
                value: quality.hardwareDecode,
                onChanged: (v) => controller.env.preferencesStore
                    .updateQualityConfig((c) => c.copyWith(hardwareDecode: v)),
              ),
            ),
            AdaptiveSettingTile(
              title: '去色带滤镜 (Deband)',
              subtitle: '平滑低码率动漫暗场渐变色块',
              trailing: KonataSwitch(
                value: quality.debandEnabled,
                onChanged: (v) => controller.env.preferencesStore
                    .updateQualityConfig((c) => c.copyWith(debandEnabled: v)),
              ),
            ),
            const SizedBox(height: 12),
            Text('画面比例', style: KonataTheme.bodyLabelStyle(p)),
            const SizedBox(height: 8),
            for (final mode in VideoAspectMode.values)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: state.aspectMode == mode
                    ? KonataPillButton.primary(
                        compact: true,
                        label: mode.label,
                        onPressed: () => controller.setAspectMode(mode),
                      )
                    : KonataPillButton.secondary(
                        compact: true,
                        label: mode.label,
                        onPressed: () => controller.setAspectMode(mode),
                      ),
              ),
            const SizedBox(height: 12),
            Text('播放倍速', style: KonataTheme.bodyLabelStyle(p)),
            const SizedBox(height: 8),
            for (final speed in [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0])
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: (state.speed - speed).abs() < 0.01
                    ? KonataPillButton.primary(
                        compact: true,
                        label: '${speed}x',
                        onPressed: () => controller.setPlaybackSpeed(speed),
                      )
                    : KonataPillButton.secondary(
                        compact: true,
                        label: '${speed}x',
                        onPressed: () => controller.setPlaybackSpeed(speed),
                      ),
              ),
            const SizedBox(height: 12),
            AdaptiveSettingTile(
              title: '仅听声音省电模式',
              subtitle: '关闭视频画面解码与渲染，仅保留音轨输出',
              trailing: KonataSwitch(
                value: state.audioOnlyMode,
                onChanged: (_) => controller.toggleAudioOnlyMode(),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              '自定义显卡着色器脚本',
              style: TextStyle(
                color: p.textSecondary,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            if (state.availableShaders.isEmpty)
              Text(
                '暂无可用着色器文件，可在播放器设置中导入脚本',
                style: TextStyle(color: p.textMuted, fontSize: 12),
              )
            else
              for (final shader in state.availableShaders)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: AdaptiveSettingTile(
                    title: shader.name,
                    trailing: KonataSwitch(
                      value: activeShaderPaths.contains(shader.path),
                      onChanged: (enabled) =>
                          controller.toggleShaderPath(shader.path, enabled),
                    ),
                  ),
                ),
          ],
        );
      },
    );
  }
}

class _SelectableOptionRow extends StatelessWidget {
  const _SelectableOptionRow({
    required this.title,
    required this.selected,
    required this.onTap,
    this.subtitle,
    this.trailing,
  });

  final String title;
  final bool selected;
  final VoidCallback onTap;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: selected
              ? p.accent.withValues(alpha: 0.16)
              : p.hairline.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? p.accent.withValues(alpha: 0.55) : p.hairline,
            width: 1,
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: p.textPrimary,
                      fontSize: 13,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                  if (subtitle != null && subtitle!.trim().isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: p.textMuted, fontSize: 11.5),
                    ),
                  ],
                ],
              ),
            ),
            ?trailing,
          ],
        ),
      ),
    );
  }
}
