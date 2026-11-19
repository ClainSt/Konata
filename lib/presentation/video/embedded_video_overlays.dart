part of 'embedded_video_page.dart';

/// `EmbeddedVideoPage` 顶部播控条扩展（隔离桌面顶栏与 Android 悬浮胶囊，保持主页面精简）。
extension _EmbeddedVideoTopOverlays on _EmbeddedVideoPageState {
  Widget _buildAndroidFloatingTopCapsule({
    required dynamic snap,
    required VideoPlaybackController controller,
    required String epTitle,
  }) {
    final p = context.palette;
    final stats = snap.probeStats;
    final resBadge = PlaybackFormatters.formatResolutionBadge(
      stats.videoWidth,
      stats.videoHeight,
    );
    final hwActive =
        stats.hwdecCurrent.isNotEmpty && stats.hwdecCurrent != 'no';

    return LayoutBuilder(
      builder: (context, constraints) {
        final narrowTop = constraints.maxWidth < 540;
        return KonataGlassCapsule(
          key: const ValueKey('android_video_top_capsule'),
          radius: KonataAdaptiveTokens.capsuleRadius,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          enableBackdropBlur: snap.audioOnlyMode == true,
          child: Row(
            children: [
              KonataCapsuleIconButton(
                key: const ValueKey('video_collapse_button'),
                icon: widget.onCollapseToMini != null
                    ? Icons.keyboard_arrow_down_rounded
                    : Icons.arrow_back_rounded,
                tooltip: widget.onCollapseToMini != null ? '收起至小窗胶囊' : '返回',
                color: p.textPrimary,
                size: 24,
                fixedSize: KonataAdaptiveTokens.touchTarget,
                onTap: _collapseOrExit,
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      child: EllipsisTextWithTooltip(
                        text: '${controller.activeWork.title} · $epTitle',
                        style: TextStyle(
                          color: p.textPrimary,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (resBadge.isNotEmpty && !narrowTop) ...[
                      const SizedBox(width: 8),
                      KonataSpecBadge(label: resBadge, darkOverlay: true),
                    ],
                    if (hwActive && !narrowTop) ...[
                      const SizedBox(width: 6),
                      KonataSpecBadge(
                        label: '硬解 (${stats.hwdecCurrent})',
                        darkOverlay: true,
                      ),
                    ],
                  ],
                ),
              ),
              if (!narrowTop) ...[
                KonataCapsuleIconButton(
                  key: const ValueKey('video_android_screenshot_button'),
                  icon: Icons.camera_alt_outlined,
                  tooltip: '原画截图',
                  color: p.textPrimary,
                  size: 19,
                  fixedSize: KonataAdaptiveTokens.touchTarget,
                  onTap: () => unawaited(
                    controller.captureScreenshot(
                      mode: ScreenshotCaptureMode.pureVideo,
                    ),
                  ),
                ),
                KonataCapsuleIconButton(
                  key: const ValueKey('video_toggle_audio_only_button'),
                  icon: Icons.headphones_rounded,
                  tooltip: snap.audioOnlyMode ? '恢复视频画面' : '切换后台纯音频',
                  color: p.textPrimary,
                  highlighted: snap.audioOnlyMode,
                  size: 19,
                  fixedSize: KonataAdaptiveTokens.touchTarget,
                  onTap: controller.toggleAudioOnlyMode,
                ),
                KonataCapsuleIconButton(
                  key: const ValueKey('video_enter_pip_button'),
                  icon: Icons.picture_in_picture_alt_rounded,
                  tooltip: '进入画中画',
                  color: p.textPrimary,
                  size: 19,
                  fixedSize: KonataAdaptiveTokens.touchTarget,
                  onTap: () => unawaited(
                    ref
                        .read(activeVideoSessionProvider.notifier)
                        .enterPipManually(),
                  ),
                ),
              ],
              KonataCapsuleIconButton(
                key: const ValueKey('video_top_more_tune_button'),
                icon: Icons.tune_rounded,
                tooltip: '播控与画质设置',
                color: p.textPrimary,
                size: 20,
                fixedSize: KonataAdaptiveTokens.touchTarget,
                onTap: () => _openSideSheet(VideoSideSheetTab.video),
              ),
              if (widget.onCollapseToMini != null)
                KonataCapsuleIconButton(
                  key: const ValueKey('video_close_session_button'),
                  icon: Icons.close_rounded,
                  tooltip: '停止并关闭视频',
                  color: p.textPrimary,
                  size: 20,
                  fixedSize: KonataAdaptiveTokens.touchTarget,
                  onTap: () => unawaited(_closeSessionAndExit()),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildDesktopTopOverlayBar({
    required dynamic snap,
    required VideoPlaybackController controller,
    required String epTitle,
  }) {
    final p = context.palette;
    final isWindows = KonataAdaptiveTokens.isWindows;
    final stats = snap.probeStats;
    final resBadge = PlaybackFormatters.formatResolutionBadge(
      stats.videoWidth,
      stats.videoHeight,
    );
    final codecBadge = PlaybackFormatters.formatCodecShortLabel(
      stats.videoCodec,
    );
    final bitDepthBadge = PlaybackFormatters.formatVideoBitDepthLabel(
      stats.videoPixelFormat,
    );
    final hwActive =
        stats.hwdecCurrent.isNotEmpty && stats.hwdecCurrent != 'no';

    Widget bar = Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
      decoration: p.isDark
          ? BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  KonataPlaybackTokens.cinemaPureBlack.withValues(alpha: 0.72),
                  KonataPlaybackTokens.cinemaPureBlack.withValues(alpha: 0.0),
                ],
              ),
            )
          : BoxDecoration(
              color: KonataPlaybackTokens.glassSurface(p),
              border: Border(
                bottom: BorderSide(color: KonataPlaybackTokens.glassBorder(p)),
              ),
            ),
      child: Row(
        children: [
          IconButton(
            tooltip: widget.onCollapseToMini != null
                ? '收起为小窗播放胶囊 (Esc)'
                : '返回作品详情 (Esc)',
            onPressed: _collapseOrExit,
            icon: Icon(
              widget.onCollapseToMini != null
                  ? Icons.keyboard_arrow_down_rounded
                  : Icons.arrow_back_rounded,
              color: p.textPrimary,
            ),
          ),
          if (widget.onCollapseToMini != null)
            IconButton(
              tooltip: '停止并关闭视频',
              onPressed: () => unawaited(_closeSessionAndExit()),
              icon: Icon(Icons.close_rounded, size: 20, color: p.textPrimary),
            ),
          const SizedBox(width: 6),
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: EllipsisTextWithTooltip(
                    text: '${controller.activeWork.title} · $epTitle',
                    style: TextStyle(
                      color: p.textPrimary,
                      fontSize: 14.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                if (resBadge.isNotEmpty) ...[
                  KonataSpecBadge(label: resBadge, darkOverlay: true),
                  const SizedBox(width: 6),
                ],
                if (codecBadge.isNotEmpty) ...[
                  KonataSpecBadge(
                    label: bitDepthBadge.isNotEmpty
                        ? '$codecBadge · $bitDepthBadge'
                        : codecBadge,
                    darkOverlay: true,
                  ),
                  const SizedBox(width: 6),
                ],
                if (hwActive ||
                    snap.renderBackend == 'sw' ||
                    snap.hasFirstFrame)
                  KonataSpecBadge(
                    label: hwActive
                        ? '硬解 (${stats.hwdecCurrent})'
                        : (snap.renderBackend == 'sw' ? 'SW 兼容' : '软解'),
                    darkOverlay: true,
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            tooltip: snap.audioOnlyMode ? '恢复视频画面' : '切换后台纯音频',
            onPressed: controller.toggleAudioOnlyMode,
            icon: Icon(
              Icons.headphones_rounded,
              size: 19,
              color: snap.audioOnlyMode ? p.progressFill : p.textPrimary,
            ),
          ),
          IconButton(
            tooltip: '技术探针指标 (Tab)',
            onPressed: controller.toggleProbeOverlay,
            icon: Icon(
              Icons.analytics_outlined,
              size: 20,
              color: snap.probeOverlayVisible ? p.progressFill : p.textPrimary,
            ),
          ),
          if (isWindows)
            IconButton(
              tooltip: '切换外部播放器无缝接力续播',
              onPressed: _relayToExternal,
              icon: Icon(
                Icons.open_in_new_rounded,
                size: 19,
                color: p.textPrimary,
              ),
            ),
          IconButton(
            tooltip: '播控与画质设置',
            onPressed: () => _openSideSheet(VideoSideSheetTab.video),
            icon: Icon(Icons.tune_rounded, size: 20, color: p.textPrimary),
          ),
          if (isWindows && !snap.isFullscreen) ...[
            const SizedBox(width: 4),
            ref.read(konataWindowHostProvider).buildWindowControls(),
          ],
        ],
      ),
    );
    if (!p.isDark) {
      bar = ClipRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
          child: bar,
        ),
      );
    }

    if (isWindows && !snap.isFullscreen) {
      bar = ref.read(konataWindowHostProvider).buildDragToMoveArea(child: bar);
    }
    return bar;
  }
}

/// 底部播控胶囊进度叶子：当 `subscribeProgress == false`（OSD 3 秒隐藏或画中画态）时，彻底退订 `positionSeconds` 监听。
class _VideoBottomHudLeaf extends ConsumerWidget {
  const _VideoBottomHudLeaf({
    required this.request,
    required this.subscribeProgress,
    required this.isTablet,
    required this.audioOnlyMode,
    required this.isPlaying,
    required this.speed,
    required this.volume,
    required this.isMuted,
    required this.isFullscreen,
    required this.sideSheetOpen,
    required this.chapters,
    required this.externalVolumePulse,
    required this.onTogglePlayPause,
    required this.onOpenSideSheet,
    required this.onVolumePopupActiveChanged,
  });

  final VideoLaunchRequest request;
  final bool subscribeProgress;
  final bool isTablet;
  final bool audioOnlyMode;
  final bool isPlaying;
  final double speed;
  final double volume;
  final bool isMuted;
  final bool isFullscreen;
  final bool sideSheetOpen;
  final List<dynamic> chapters;
  final int externalVolumePulse;
  final VoidCallback onTogglePlayPause;
  final ValueChanged<VideoSideSheetTab> onOpenSideSheet;
  final ValueChanged<bool> onVolumePopupActiveChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.palette;
    final controller = ref.read(videoPlaybackProvider(request).notifier);
    final isAndroid = KonataAdaptiveTokens.isAndroid;
    final btnSize = isAndroid ? KonataAdaptiveTokens.touchTarget : null;

    // 关键门禁：OSD 隐藏期间停止订阅进度与时长，杜绝后台无谓 UI 重建与重绘。
    final timing = subscribeProgress
        ? ref.watch(
            videoPlaybackProvider(request).select(
              (s) => (pos: s.positionSeconds, dur: s.durationSeconds),
            ),
          )
        : (
            pos: ref.read(videoPlaybackProvider(request)).positionSeconds,
            dur: ref.read(videoPlaybackProvider(request)).durationSeconds,
          );

    final canPrev = controller.hasPreviousEpisodeAny;
    final canNext = controller.hasNextEpisodeAny;
    final speedChanged = (speed - 1.0).abs() > 0.02;
    final screenWidth = MediaQuery.sizeOf(context).width;
    final narrowAndroidHud = isAndroid && screenWidth < 680;
    final ultraNarrowAndroidHud = isAndroid && screenWidth < 400;

    return RepaintBoundary(
      child: KonataPlaybackCapsule(
        maxWidth: isTablet ? KonataAdaptiveTokens.tabletPlayerMaxWidth : null,
        enableBackdropBlur: !isAndroid || audioOnlyMode,
        title: null,
        positionSeconds: timing.pos,
        durationSeconds: timing.dur,
        isPlaying: isPlaying,
        chapters: chapters.cast(),
        onTogglePlayPause: onTogglePlayPause,
        onSeek: controller.seekAbsolute,
        onPrevious: canPrev
            ? () => unawaited(controller.goToPreviousEpisode())
            : null,
        onNext: canNext ? () => unawaited(controller.goToNextEpisode()) : null,
        onToggleList: () => onOpenSideSheet(VideoSideSheetTab.episodes),
        isListActive: sideSheetOpen,
        listTooltip: '选集与章节列表',
        supportsThumbnailPreview: !isAndroid,
        previewRevisionListenable: controller.thumbnailRevisionListenable,
        previewThumbnailResolver: controller.resolveThumbnailPreview,
        onPreviewHoverSecondsChanged: controller.requestThumbnailPreview,
        rightSlot: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!narrowAndroidHud) ...[
              KonataCapsuleIconButton(
                icon: Icons.subtitles_outlined,
                tooltip: '字幕轨道',
                color: p.textPrimary,
                size: 18,
                fixedSize: btnSize,
                onTap: () => onOpenSideSheet(VideoSideSheetTab.subtitles),
              ),
              KonataCapsuleIconButton(
                icon: Icons.audiotrack_outlined,
                tooltip: '音轨切换',
                color: p.textPrimary,
                size: 18,
                fixedSize: btnSize,
                onTap: () => onOpenSideSheet(VideoSideSheetTab.audio),
              ),
            ] else
              KonataCapsuleIconButton(
                key: const ValueKey('video_bottom_secondary_sheet_button'),
                icon: Icons.tune_rounded,
                tooltip: '音轨与字幕设置',
                color: p.textPrimary,
                size: 18,
                fixedSize: btnSize,
                onTap: () => onOpenSideSheet(VideoSideSheetTab.audio),
              ),
            if (!isAndroid)
              KonataCapsuleIconButton(
                icon: Icons.camera_alt_outlined,
                tooltip: '纯净原画截图 (S)',
                color: p.textPrimary,
                size: 18,
                onTap: () => unawaited(controller.captureCleanScreenshot()),
              ),
            if (speedChanged && !isAndroid)
              MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => onOpenSideSheet(VideoSideSheetTab.video),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 5,
                      vertical: 4,
                    ),
                    child: Text(
                      '${speed.toStringAsFixed(2).replaceFirst(RegExp(r'\.?0+$'), '')}x',
                      style: TextStyle(
                        color: p.textPrimary,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        fontFeatures: KonataPlaybackTokens.tabularNumbers,
                      ),
                    ),
                  ),
                ),
              ),
            KonataVolumeControl(
              volume: (volume / 100.0).clamp(0.0, 1.0),
              isMuted: isMuted,
              onVolumeChanged: (v) => controller.setVolume(v * 100.0),
              onToggleMute: controller.toggleMute,
              allowPopover: subscribeProgress,
              externalRevealPulse: externalVolumePulse,
              onPopupActiveChanged: onVolumePopupActiveChanged,
            ),
            if (!ultraNarrowAndroidHud)
              KonataCapsuleIconButton(
                icon: isFullscreen
                    ? Icons.fullscreen_exit_rounded
                    : Icons.fullscreen_rounded,
                tooltip: isFullscreen ? '退出全屏 (F / Esc)' : '全屏播放 (F / 双击)',
                color: p.textPrimary,
                size: 20,
                fixedSize: btnSize,
                onTap: () => unawaited(controller.toggleFullscreen()),
              ),
          ],
        ),
      ),
    );
  }
}

class _VideoStatusCueOverlayLeaf extends StatelessWidget {
  const _VideoStatusCueOverlayLeaf({
    required this.cueListenable,
    required this.isSpeedBoostActive,
  });

  final ValueListenable<({String text, IconData icon, bool centered})?>
  cueListenable;
  final bool isSpeedBoostActive;

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: ValueListenableBuilder<
        ({String text, IconData icon, bool centered})?
      >(
        valueListenable: cueListenable,
        builder: (context, cue, _) {
          if (isSpeedBoostActive) {
            return const Stack(
              fit: StackFit.expand,
              children: [
                Positioned(
                  top: 72,
                  right: 20,
                  child: IgnorePointer(
                    child: _MiniCornerStatusPill(
                      icon: Icons.fast_forward_rounded,
                      label: '2.0x 倍速快进中',
                    ),
                  ),
                ),
              ],
            );
          }
          if (cue == null) return const SizedBox.shrink();
          if (cue.centered) {
            return IgnorePointer(
              child: Center(
                key: const ValueKey('video_center_status_pill'),
                child: _MiniCornerStatusPill(
                  icon: cue.icon,
                  label: cue.text,
                ),
              ),
            );
          }
          return Stack(
            fit: StackFit.expand,
            children: [
              Positioned(
                top: 72,
                right: 20,
                child: IgnorePointer(
                  child: _MiniCornerStatusPill(
                    icon: cue.icon,
                    label: cue.text,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _MiniCornerStatusPill extends StatelessWidget {
  const _MiniCornerStatusPill({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          decoration: BoxDecoration(
            color: KonataPlaybackTokens.glassSurface(p),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: KonataPlaybackTokens.glassBorder(p)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 15, color: p.textPrimary),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  color: p.textPrimary,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SkipChapterCapsule extends StatelessWidget {
  const _SkipChapterCapsule({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: Material(
          color: KonataPlaybackTokens.glassSurface(p),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(999),
            side: BorderSide(color: KonataPlaybackTokens.glassBorder(p)),
          ),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(999),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: KonataAdaptiveTokens.isAndroid
                    ? KonataAdaptiveTokens.touchTarget
                    : 0,
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 9,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.fast_forward_rounded,
                      size: 16,
                      color: p.progressFill,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      label,
                      style: TextStyle(
                        color: p.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
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
  }
}

class _ErrorFallbackCard extends StatelessWidget {
  const _ErrorFallbackCard({
    required this.message,
    required this.showExternalButton,
    required this.onRelayExternal,
    required this.onBack,
  });

  final String message;
  final bool showExternalButton;
  final VoidCallback onRelayExternal;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: Container(
          constraints: const BoxConstraints(maxWidth: 420),
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: KonataPlaybackTokens.glassSurface(p),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: KonataPlaybackTokens.glassBorder(p)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline_rounded, size: 36, color: p.danger),
              const SizedBox(height: 12),
              Text(
                message,
                textAlign: TextAlign.center,
                style: TextStyle(color: p.textPrimary, fontSize: 13.5),
              ),
              const SizedBox(height: 18),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 12,
                runSpacing: 8,
                children: [
                  KonataPillButton.secondary(label: '返回', onPressed: onBack),
                  if (showExternalButton)
                    KonataPillButton.primary(
                      label: '外部播放器打开',
                      icon: Icons.open_in_new_rounded,
                      onPressed: onRelayExternal,
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
