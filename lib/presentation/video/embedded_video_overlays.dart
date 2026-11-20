part of 'embedded_video_page.dart';

/// `EmbeddedVideoPage` 顶部播控条扩展（隔离桌面顶栏与 Android 悬浮胶囊，保持主页面精简）。
extension _EmbeddedVideoTopOverlays on _EmbeddedVideoPageState {
  /// 弹出双模原画截图毛玻璃菜单（纯净原画帧 / 带字幕合成帧），供桌面底栏与触屏顶栏统一调用。
  Future<void> _showScreenshotModeMenu(
    BuildContext anchorContext,
    VideoPlaybackController controller,
  ) async {
    _onUserActivity();
    final isAndroid = KonataAdaptiveTokens.isAndroid;
    final selected = await showKonataGlassMenu<ScreenshotCaptureMode>(
      anchorContext: anchorContext,
      items: isAndroid
          ? const [
              KonataGlassMenuItem<ScreenshotCaptureMode>(
                key: ValueKey('video_screenshot_mode_with_subtitles'),
                value: ScreenshotCaptureMode.withSubtitles,
                icon: Icons.subtitles_outlined,
                label: '含字幕原画',
              ),
              KonataGlassMenuItem<ScreenshotCaptureMode>(
                key: ValueKey('video_screenshot_mode_pure_video'),
                value: ScreenshotCaptureMode.pureVideo,
                icon: Icons.photo_camera_outlined,
                label: '纯净原画',
              ),
            ]
          : const [
              KonataGlassMenuItem<ScreenshotCaptureMode>(
                key: ValueKey('video_screenshot_mode_pure_video'),
                value: ScreenshotCaptureMode.pureVideo,
                icon: Icons.photo_camera_outlined,
                label: '纯净原画帧 (S)',
              ),
              KonataGlassMenuItem<ScreenshotCaptureMode>(
                key: ValueKey('video_screenshot_mode_with_subtitles'),
                value: ScreenshotCaptureMode.withSubtitles,
                icon: Icons.subtitles_outlined,
                label: '带字幕合成帧 (Shift+S)',
              ),
            ],
    );
    if (selected == null || !mounted) return;
    _flashCornerStatus('正在截取${selected.label}...', Icons.camera_alt_outlined);
    unawaited(controller.captureScreenshot(mode: selected));
  }

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
        var topBarDragDownPx = 0.0;
        final capsule = KonataGlassCapsule(
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
                          fontSize: KonataTheme.fontSizeBodyMd,
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
              Builder(
                builder: (btnCtx) => KonataCapsuleIconButton(
                  key: const ValueKey('video_android_screenshot_button'),
                  icon: Icons.camera_alt_outlined,
                  tooltip: '原画截图（轻触选含字幕/纯净，长按直出含字幕）',
                  color: p.textPrimary,
                  size: 19,
                  fixedSize: KonataAdaptiveTokens.touchTarget,
                  onTap: () => unawaited(
                    _showScreenshotModeMenu(btnCtx, controller),
                  ),
                  onLongPress: () {
                    _onUserActivity();
                    _flashCornerStatus(
                      '正在截取含字幕原画...',
                      Icons.subtitles_outlined,
                    );
                    unawaited(
                      controller.captureScreenshot(
                        mode: ScreenshotCaptureMode.withSubtitles,
                      ),
                    );
                  },
                ),
              ),
              if (!narrowTop) ...[
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
        if (widget.onCollapseToMini == null) {
          return capsule;
        }
        return GestureDetector(
          behavior: HitTestBehavior.translucent,
          onVerticalDragStart: (_) => topBarDragDownPx = 0.0,
          onVerticalDragUpdate: (d) {
            if (d.delta.dy > 0) {
              topBarDragDownPx += d.delta.dy;
            }
          },
          onVerticalDragEnd: (details) {
            final vel = details.primaryVelocity ?? 0.0;
            if (topBarDragDownPx >= 56.0 || vel >= 360.0) {
              _collapseOrExit(releaseVelocityPxPerSec: vel);
            }
            topBarDragDownPx = 0.0;
          },
          child: capsule,
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

    Widget bar = KonataGlassCapsule(
      key: const ValueKey('desktop_video_top_capsule'),
      radius: KonataTheme.radiusPill,
      showShadow: true,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          KonataCapsuleIconButton(
            icon: widget.onCollapseToMini != null
                ? Icons.keyboard_arrow_down_rounded
                : Icons.arrow_back_rounded,
            tooltip: widget.onCollapseToMini != null
                ? '收起为小窗播放胶囊 (Esc)'
                : '返回作品详情 (Esc)',
            color: p.textPrimary,
            size: 22,
            fixedSize: 34,
            padding: EdgeInsets.zero,
            onTap: _collapseOrExit,
          ),
          if (widget.onCollapseToMini != null)
            KonataCapsuleIconButton(
              icon: Icons.close_rounded,
              tooltip: '停止并关闭视频',
              color: p.textPrimary,
              size: 19,
              fixedSize: 34,
              padding: EdgeInsets.zero,
              onTap: () => unawaited(_closeSessionAndExit()),
            ),
          const SizedBox(width: 8),
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: EllipsisTextWithTooltip(
                    text: '${controller.activeWork.title} · $epTitle',
                    style: TextStyle(
                      color: p.textPrimary,
                      fontSize: KonataTheme.fontSizeSubtitle,
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
          KonataCapsuleIconButton(
            icon: Icons.headphones_rounded,
            tooltip: snap.audioOnlyMode ? '恢复视频画面' : '切换后台纯音频',
            color: p.textPrimary,
            highlighted: snap.audioOnlyMode,
            highlightColor: p.progressFill,
            size: 19,
            fixedSize: 34,
            padding: EdgeInsets.zero,
            onTap: controller.toggleAudioOnlyMode,
          ),
          KonataCapsuleIconButton(
            icon: Icons.analytics_outlined,
            tooltip: '技术探针指标 (Tab)',
            color: p.textPrimary,
            highlighted: snap.probeOverlayVisible,
            highlightColor: p.progressFill,
            size: 19,
            fixedSize: 34,
            padding: EdgeInsets.zero,
            onTap: controller.toggleProbeOverlay,
          ),
          if (isWindows)
            KonataCapsuleIconButton(
              icon: Icons.open_in_new_rounded,
              tooltip: '切换外部播放器无缝接力续播',
              color: p.textPrimary,
              size: 19,
              fixedSize: 34,
              padding: EdgeInsets.zero,
              onTap: _relayToExternal,
            ),
          KonataCapsuleIconButton(
            icon: Icons.tune_rounded,
            tooltip: '播控与画质设置',
            color: p.textPrimary,
            size: 19,
            fixedSize: 34,
            padding: EdgeInsets.zero,
            onTap: () => _openSideSheet(VideoSideSheetTab.video),
          ),
          if (isWindows && !snap.isFullscreen) ...[
            const SizedBox(width: 6),
            ref.read(konataWindowHostProvider).buildWindowControls(),
          ],
        ],
      ),
    );

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
    required this.onShowScreenshotMenu,
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
  final Future<void> Function(BuildContext anchorContext) onShowScreenshotMenu;
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
              Builder(
                builder: (btnCtx) => KonataCapsuleIconButton(
                  key: const ValueKey('video_desktop_screenshot_button'),
                  icon: Icons.camera_alt_outlined,
                  tooltip: '原画截图（纯净 S / 带字幕 Shift+S）',
                  color: p.textPrimary,
                  size: 18,
                  onTap: () => unawaited(onShowScreenshotMenu(btnCtx)),
                ),
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
                        fontSize: KonataTheme.fontSizeCaptionSm,
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
      borderRadius: KonataTheme.borderRadiusPill,
      child: BackdropFilter(
        filter: KonataTheme.blurFilterControl,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          decoration: BoxDecoration(
            color: KonataPlaybackTokens.glassSurface(p),
            borderRadius: KonataTheme.borderRadiusPill,
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
                  fontSize: KonataTheme.fontSizeBodyXs,
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
      borderRadius: KonataTheme.borderRadiusPill,
      child: BackdropFilter(
        filter: KonataTheme.blurFilterOverlay,
        child: Material(
          color: KonataPlaybackTokens.glassSurface(p),
          shape: RoundedRectangleBorder(
            borderRadius: KonataTheme.borderRadiusPill,
            side: BorderSide(color: KonataPlaybackTokens.glassBorder(p)),
          ),
          child: InkWell(
            onTap: onTap,
            borderRadius: KonataTheme.borderRadiusPill,
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
                        fontSize: KonataTheme.fontSizeBodySm,
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
    required this.onRetry,
    required this.onRelayExternal,
    required this.onBack,
  });

  final String message;
  final bool showExternalButton;
  final VoidCallback onRetry;
  final VoidCallback onRelayExternal;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return ClipRRect(
      borderRadius: KonataTheme.borderRadiusDialog,
      child: BackdropFilter(
        filter: KonataTheme.blurFilterOverlay,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 440),
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            gradient: KonataTheme.opticalSheenGradient(
              p,
              baseColor: KonataPlaybackTokens.glassSurface(p),
            ),
            borderRadius: KonataTheme.borderRadiusDialog,
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
                style: TextStyle(
                  color: p.textPrimary,
                  fontSize: KonataTheme.fontSizeBody,
                ),
              ),
              const SizedBox(height: 18),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 10,
                runSpacing: 8,
                children: [
                  KonataPillButton.secondary(label: '返回', onPressed: onBack),
                  KonataPillButton.primary(
                    label: '重试',
                    icon: Icons.refresh_rounded,
                    onPressed: onRetry,
                  ),
                  if (showExternalButton)
                    KonataPillButton.secondary(
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
