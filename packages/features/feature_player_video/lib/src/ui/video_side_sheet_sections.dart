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
          padding: EdgeInsets.zero,
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
                    tooltip: '标记完播',
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

class _SubtitlesSection extends StatelessWidget {
  const _SubtitlesSection({
    required this.controller,
    required this.state,
    required this.prefs,
  });

  final VideoPlaybackController controller;
  final VideoPlaybackState state;
  final VideoPlaybackPreferences prefs;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final q = prefs.qualityConfig;
    final store = controller.env.preferencesStore;
    final hasAss = state.subtitles.any(
      (s) =>
          s.selected &&
          !s.isCloudSubset &&
          s.isExternal &&
          (s.codec.toLowerCase() == 'ass' || s.codec.toLowerCase() == 'ssa'),
    );
    return KonataDraggableScrollbar(
      builder: (context, scrollController) => ListView(
        controller: scrollController,
        padding: EdgeInsets.zero,
        children: [
          _TrackSelectionRow(
            title: '关闭字幕',
            selected: state.subtitles.every((s) => !s.selected),
            onTap: () => unawaited(controller.selectSubtitleChoice(null)),
          ),
          const SizedBox(height: 8),
          for (final sub in state.subtitles)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _TrackSelectionRow(
                title: sub.primaryTitle,
                badge: sub.sourceFormatBadge,
                selected: sub.selected,
                onTap: () => unawaited(controller.selectSubtitleChoice(sub)),
              ),
            ),
          KonataPillButton.secondary(
            compact: true,
            icon: Icons.add_rounded,
            label: '添加外挂字幕',
            onPressed: () => unawaited(controller.pickAndAddExternalSubtitle()),
          ),
          const SizedBox(height: 16),
          Text('内存字幕增强（OpenCC）', style: KonataTheme.bodyLabelStyle(p)),
          const SizedBox(height: 8),
          KonataSegmentedCapsule<SubtitleOpenCcMode>(
            expand: true,
            compact: true,
            selected: state.subtitleOpenCcMode,
            options: const [
              KonataSegmentOption(value: SubtitleOpenCcMode.none, label: '原文'),
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
          const SizedBox(height: 8),
          Text(
            '适用于外挂文本字幕，保留原始文件。',
            style: TextStyle(color: p.textMuted, fontSize: 12),
          ),
          if (prefs.enableCloudSubset &&
              prefs.fontInAssEndpoint.trim().isNotEmpty) ...[
            const SizedBox(height: 8),
            KonataPillButton.secondary(
              compact: true,
              icon: Icons.cloud_sync_outlined,
              label: state.isApplyingCloudSubset ? '字库子集化中…' : '云端字库子集化',
              onPressed: state.isApplyingCloudSubset || !hasAss
                  ? null
                  : () => unawaited(
                      controller.applyCloudSubsetToCurrentSubtitle(),
                    ),
            ),
          ],
          const SizedBox(height: 16),
          Text('字幕同步与样式', style: KonataTheme.bodyLabelStyle(p)),
          const SizedBox(height: 8),
          _PlaybackValueStepper(
            label: '字幕延迟',
            value: '${state.subtitleDelaySeconds.toStringAsFixed(1)}s',
            onDecrease: () => controller.adjustSubtitleDelay(-0.1),
            onIncrease: () => controller.adjustSubtitleDelay(0.1),
            onReset: () => controller.setSubtitleDelay(0),
          ),
          const SizedBox(height: 8),
          KonataDropdown<SubtitleAssOverrideMode>(
            value: q.subOverrideMode,
            options: const [
              KonataDropdownOption(
                value: SubtitleAssOverrideMode.preserveAss,
                label: '保留原始特效',
              ),
              KonataDropdownOption(
                value: SubtitleAssOverrideMode.scaleOnly,
                label: '仅缩放字号',
              ),
              KonataDropdownOption(
                value: SubtitleAssOverrideMode.forceStyle,
                label: '覆盖字幕样式',
              ),
            ],
            onChanged: (mode) => store.updateQualityConfig(
              (c) => c.copyWith(subOverrideMode: mode),
            ),
          ),
          const SizedBox(height: 8),
          _PlaybackValueStepper(
            label: '字幕字号',
            value: '${q.subFontSize}',
            onDecrease: () => store.updateQualityConfig(
              (c) => c.copyWith(subFontSize: (c.subFontSize - 2).clamp(24, 96)),
            ),
            onIncrease: () => store.updateQualityConfig(
              (c) => c.copyWith(subFontSize: (c.subFontSize + 2).clamp(24, 96)),
            ),
            onReset: () => store.updateQualityConfig(
              (c) => c.copyWith(
                subFontSize: const PlaybackQualityConfig().subFontSize,
              ),
            ),
          ),
          _PlaybackValueStepper(
            label: '底部边距',
            value: '${q.subBottomMargin}',
            onDecrease: () => store.updateQualityConfig(
              (c) => c.copyWith(
                subBottomMargin: (c.subBottomMargin - 2).clamp(0, 120),
              ),
            ),
            onIncrease: () => store.updateQualityConfig(
              (c) => c.copyWith(
                subBottomMargin: (c.subBottomMargin + 2).clamp(0, 120),
              ),
            ),
            onReset: () => store.updateQualityConfig(
              (c) => c.copyWith(
                subBottomMargin: const PlaybackQualityConfig().subBottomMargin,
              ),
            ),
          ),
          Text(
            '保留原始特效时，ASS 字幕沿用原文件的样式。',
            style: TextStyle(color: p.textMuted, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _AudioSection extends StatelessWidget {
  const _AudioSection({
    required this.controller,
    required this.state,
    required this.prefs,
  });

  final VideoPlaybackController controller;
  final VideoPlaybackState state;
  final VideoPlaybackPreferences prefs;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final devices = <String, String>{'auto': '系统默认音频输出 (Auto)'};
    for (final dev in state.availableAudioDevices) {
      if (dev.name.isEmpty || devices.containsKey(dev.name)) continue;
      final description = dev.description.trim();
      devices[dev.name] = description.isEmpty || description == dev.name
          ? '音频设备 ${devices.length}'
          : description;
    }
    final device = prefs.qualityConfig.audioDevice;
    return KonataDraggableScrollbar(
      builder: (context, scrollController) => ListView(
        controller: scrollController,
        padding: EdgeInsets.zero,
        children: [
          Text('音轨', style: KonataTheme.bodyLabelStyle(p)),
          const SizedBox(height: 8),
          for (final track in state.audioTracks)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _TrackSelectionRow(
                title: track.primaryTitle,
                badge: track.sourceFormatBadge,
                selected: track.selected,
                onTap: () => unawaited(controller.selectAudioTrack(track)),
              ),
            ),
          const SizedBox(height: 12),
          Text('音频输出设备', style: KonataTheme.bodyLabelStyle(p)),
          const SizedBox(height: 8),
          KonataDropdown<String>(
            value: devices.containsKey(device) ? device : null,
            hintText: '已选设备不可用，请重新选择',
            options: [
              for (final entry in devices.entries)
                KonataDropdownOption(value: entry.key, label: entry.value),
            ],
            onChanged: (value) =>
                unawaited(controller.selectAudioDevice(value)),
          ),
          const SizedBox(height: 12),
          _PlaybackValueStepper(
            label: '音频延迟',
            value: '${state.audioDelaySeconds.toStringAsFixed(1)}s',
            onDecrease: () =>
                controller.setAudioDelay(state.audioDelaySeconds - 0.1),
            onIncrease: () =>
                controller.setAudioDelay(state.audioDelaySeconds + 0.1),
            onReset: () => controller.setAudioDelay(0),
          ),
          const SizedBox(height: 16),
          VideoAudioRouteControls(
            platform: controller.env.platform,
            preferences: prefs,
            store: controller.env.preferencesStore,
            coordinator: controller.env.audiophileCoordinator,
          ),
        ],
      ),
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
          padding: EdgeInsets.zero,
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
            for (final speed in [
              0.5,
              0.75,
              1.0,
              1.25,
              1.5,
              1.75,
              2.0,
              2.5,
              3.0,
            ])
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
              title: '纯音频模式',
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
