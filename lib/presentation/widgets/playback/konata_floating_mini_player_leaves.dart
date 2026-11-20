part of 'konata_floating_mini_player.dart';

/// 视频小窗悬停或轻触后临时显现 3 秒的角标与播放暂停浮层。
class _FloatingMiniTransientChromeOverlay extends StatelessWidget {
  const _FloatingMiniTransientChromeOverlay({
    required this.visibleListenable,
    required this.videoRequest,
    required this.onExpand,
    required this.onTuck,
    required this.onClose,
  });

  final ValueNotifier<bool> visibleListenable;
  final VideoLaunchRequest videoRequest;
  final VoidCallback onExpand;
  final VoidCallback onTuck;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: visibleListenable,
      builder: (context, visible, _) {
        if (!visible) {
          return const SizedBox.shrink();
        }
        return Stack(
          fit: StackFit.expand,
          children: [
            IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    stops: const [0.0, 0.45, 1.0],
                    colors: const [
                      KonataPlaybackTokens.floatingMiniChromeScrimTop,
                      KonataPlaybackTokens.floatingMiniChromeScrimMid,
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
            Align(
              alignment: Alignment.topLeft,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _FloatingOverlayCornerButton(
                    buttonKey: const ValueKey('floating_mini_expand_button'),
                    icon: Icons.open_in_full_rounded,
                    tooltip: '展开全屏',
                    onTap: onExpand,
                  ),
                  _FloatingOverlayCornerButton(
                    buttonKey: const ValueKey('floating_mini_tuck_button'),
                    icon: Icons.last_page_rounded,
                    tooltip: '贴边暂停隐藏',
                    onTap: onTuck,
                  ),
                ],
              ),
            ),
            Align(
              alignment: Alignment.topRight,
              child: _FloatingOverlayCornerButton(
                buttonKey: const ValueKey('floating_mini_close_button'),
                icon: Icons.close_rounded,
                tooltip: '停止并关闭',
                onTap: onClose,
              ),
            ),
            Align(
              alignment: Alignment.bottomRight,
              child: _FloatingVideoPlayPauseCornerLeaf(request: videoRequest),
            ),
          ],
        );
      },
    );
  }
}

class _FloatingVideoPlayPauseCornerLeaf extends ConsumerWidget {
  const _FloatingVideoPlayPauseCornerLeaf({required this.request});

  final VideoLaunchRequest request;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isPlaying = ref.watch(
      videoPlaybackProvider(request).select((s) => s.isPlaying),
    );
    return Tooltip(
      message: isPlaying ? '暂停' : '播放',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          key: const ValueKey('floating_mini_video_play_pause'),
          behavior: HitTestBehavior.opaque,
          onTap: () =>
              ref.read(videoPlaybackProvider(request).notifier).togglePlayPause(),
          child: SizedBox.square(
            dimension: KonataAdaptiveTokens.touchTarget,
            child: Center(
              child: Container(
                width: KonataPlaybackTokens.floatingMiniOverlayPillSize,
                height: KonataPlaybackTokens.floatingMiniOverlayPillSize,
                decoration: BoxDecoration(
                  color: KonataPlaybackTokens.videoOverlayBadgeBg,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: KonataPlaybackTokens.videoOverlayBadgeBorder,
                    width: KonataPlaybackTokens.floatingMiniBorderWidth,
                  ),
                ),
                alignment: Alignment.center,
                child: Icon(
                  isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  size: KonataPlaybackTokens.floatingMiniOverlayIconSize,
                  color: KonataPlaybackTokens.videoOverlayBadgeFg,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _FloatingOverlayCornerButton extends StatelessWidget {
  const _FloatingOverlayCornerButton({
    required this.buttonKey,
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final Key buttonKey;
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          key: buttonKey,
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: SizedBox.square(
            dimension: KonataAdaptiveTokens.touchTarget,
            child: Center(
              child: Container(
                width: KonataPlaybackTokens.floatingMiniOverlayPillSize,
                height: KonataPlaybackTokens.floatingMiniOverlayPillSize,
                decoration: BoxDecoration(
                  color: KonataPlaybackTokens.videoOverlayBadgeBg,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: KonataPlaybackTokens.videoOverlayBadgeBorder,
                    width: KonataPlaybackTokens.floatingMiniBorderWidth,
                  ),
                ),
                child: Icon(
                  icon,
                  size: KonataPlaybackTokens.floatingMiniOverlayIconSize,
                  color: KonataPlaybackTokens.videoOverlayBadgeFg,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 仅订阅音频播放/暂停布尔状态的独立叶子按钮，防止曲目时间推进触发播控条重绘。
class _FloatingAudioPlayPauseLeaf extends ConsumerWidget {
  const _FloatingAudioPlayPauseLeaf({
    required this.onTap,
    required this.fixedSize,
  });

  final VoidCallback onTap;
  final double fixedSize;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.palette;
    final isPlaying = ref.watch(
      audioPlaybackProvider.select((s) => s.isPlaying),
    );
    return KonataCapsuleIconButton(
      key: const ValueKey('floating_mini_audio_play_pause'),
      icon: isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
      tooltip: isPlaying ? '暂停' : '播放',
      color: p.textPrimary,
      size: 20,
      fixedSize: fixedSize,
      padding: EdgeInsets.zero,
      onTap: onTap,
    );
  }
}

/// 仅订阅封面数据源变更的正方形/圆形封面叶子组件。
class _FloatingAudioCoverLeaf extends ConsumerWidget {
  const _FloatingAudioCoverLeaf({required this.size});

  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.palette;
    final cover = ref.watch(audioPlaybackProvider.select((s) => s.cover));
    final expanded = ref.watch(immersiveAudioExpandedProvider);
    final loader = ref.watch(tmdbImageLoaderProvider);

    return HeroMode(
      enabled: !expanded,
      child: Hero(
        tag: 'konata_audio_cover_hero',
        child: SmartCoverAlignmentBuilder(
          cover: cover,
          loader: loader,
          builder: (context, coverAlignment) {
            switch (cover) {
              case MemoryAudioCover(:final bytes):
                return Image.memory(
                  bytes,
                  width: size,
                  height: size,
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
                  key: ValueKey('floating_mini_cov_${workId}_${url}_$revision'),
                  loader: loader,
                  owner: workId,
                  width: size,
                  height: size,
                  decodeWidth: KonataPlaybackTokens.floatingMiniCoverDecodeWidth,
                  fit: BoxFit.cover,
                  alignment: coverAlignment,
                  errorBuilder: (_, _, _) => _fallbackCover(p),
                );
              case EmptyAudioCover():
                return _fallbackCover(p);
            }
          },
        ),
      ),
    );
  }

  Widget _fallbackCover(KonataPalette p) {
    return SizedBox(
      width: size,
      height: size,
      child: const KonataCdDiscPlaceholder(discScale: 0.92),
    );
  }
}

/// 视频悬浮小窗底部发光细进度叶子（高频进度仅重绘此叶子，零外层重建）。
class _FloatingVideoProgressLeaf extends ConsumerWidget {
  const _FloatingVideoProgressLeaf({required this.request});

  final VideoLaunchRequest request;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final timing = ref.watch(
      videoPlaybackProvider(request).select(
        (s) => (pos: s.positionSeconds, dur: s.durationSeconds),
      ),
    );
    final ratio = timing.dur > 0
        ? (timing.pos / timing.dur).clamp(0.0, 1.0)
        : 0.0;
    return IgnorePointer(
      child: LinearProgressIndicator(
        key: const ValueKey('floating_mini_video_progress'),
        value: ratio,
        minHeight: KonataPlaybackTokens.capsuleProgressRestHeight,
        color: context.palette.progressFill,
        backgroundColor: Colors.transparent,
      ),
    );
  }
}

/// 音频悬浮小窗发光进度环 / 顶沿细进度条叶子（高频进度仅重绘此叶子，零外层与壳层重建）。
class _FloatingAudioProgressLeaf extends ConsumerWidget {
  const _FloatingAudioProgressLeaf({this.linear = false});

  final bool linear;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.palette;
    final timing = ref.watch(
      audioPlaybackProvider.select(
        (s) => (pos: s.positionSeconds, dur: s.durationSeconds),
      ),
    );
    final ratio = timing.dur > 0
        ? (timing.pos / timing.dur).clamp(0.0, 1.0)
        : 0.0;

    if (linear) {
      return CustomPaint(
        key: const ValueKey('floating_mini_audio_progress'),
        painter: _CapsuleContourAudioProgressPainter(
          progress: ratio,
          activeColor: p.progressFill,
          borderColor: KonataPlaybackTokens.glassBorder(p),
          borderWidth: KonataAdaptiveTokens.borderWidth,
          progressStrokeWidth:
              KonataPlaybackTokens.floatingMiniAudioContourStrokeWidth,
        ),
      );
    }

    return CustomPaint(
      key: const ValueKey('floating_mini_audio_progress'),
      painter: _CircularAudioRingPainter(
        progress: ratio,
        activeColor: p.progressFill,
        trackColor: p.progressTrack,
        strokeWidth: KonataPlaybackTokens.floatingMiniAudioRingWidth,
      ),
    );
  }
}

class _CircularAudioRingPainter extends CustomPainter {
  const _CircularAudioRingPainter({
    required this.progress,
    required this.activeColor,
    required this.trackColor,
    required this.strokeWidth,
  });

  final double progress;
  final Color activeColor;
  final Color trackColor;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (math.min(size.width, size.height) - strokeWidth) / 2;
    if (radius <= 0) return;

    final trackPaint = Paint()
      ..color = trackColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;
    canvas.drawCircle(center, radius, trackPaint);

    if (progress <= 0.001) return;
    final arcPaint = Paint()
      ..color = activeColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi / 2,
      2 * math.pi * progress.clamp(0.0, 1.0),
      false,
      arcPaint,
    );
  }

  @override
  bool shouldRepaint(covariant _CircularAudioRingPainter oldDelegate) {
    return (oldDelegate.progress - progress).abs() > 0.001 ||
        oldDelegate.activeColor != activeColor ||
        oldDelegate.trackColor != trackColor ||
        oldDelegate.strokeWidth != strokeWidth;
  }
}

/// 展开态音频胶囊一体化外轮廓描边与上半沿贴边进度弧绘制器：
/// 将胶囊 1px 玻璃边框与沿上半轮廓（9 点钟左圆弧 -> 顶直边 -> 3 点钟右圆弧）流淌的进度弧融为一体，
/// 配合外层胶囊圆角裁切彻底消除顶部白边与切角错层。
class _CapsuleContourAudioProgressPainter extends CustomPainter {
  const _CapsuleContourAudioProgressPainter({
    required this.progress,
    required this.activeColor,
    required this.borderColor,
    required this.borderWidth,
    required this.progressStrokeWidth,
  });

  final double progress;
  final Color activeColor;
  final Color borderColor;
  final double borderWidth;
  final double progressStrokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final w = size.width;
    final h = size.height;
    final halfH = h / 2.0;
    final inset = borderWidth / 2.0;
    final arcRadius = math.max(0.0, math.min(w, h) / 2.0 - inset);
    final leftArcCenterX = inset + arcRadius;
    final rightArcCenterX = w - inset - arcRadius;

    final borderPaint = Paint()
      ..color = borderColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = borderWidth
      ..strokeCap = StrokeCap.butt
      ..isAntiAlias = true;

    final clamped = progress.clamp(0.0, 1.0);
    if (clamped <= 0.001) {
      final rrect = RRect.fromRectAndRadius(
        Rect.fromLTWH(inset, inset, w - inset * 2, h - inset * 2),
        Radius.circular(arcRadius),
      );
      canvas.drawRRect(rrect, borderPaint);
      return;
    }

    // 1. 下半轮廓（3 点钟 -> 右下弧 -> 底直边 -> 左下弧 -> 9 点钟）绘制标准 1px 玻璃边框。
    final bottomPath = Path()
      ..arcTo(
        Rect.fromCircle(
          center: Offset(rightArcCenterX, halfH),
          radius: arcRadius,
        ),
        0.0,
        math.pi / 2.0,
        false,
      );
    if (rightArcCenterX > leftArcCenterX) {
      bottomPath.lineTo(leftArcCenterX, h - inset);
    }
    bottomPath.arcTo(
      Rect.fromCircle(center: Offset(leftArcCenterX, halfH), radius: arcRadius),
      math.pi / 2.0,
      math.pi / 2.0,
      false,
    );
    canvas.drawPath(bottomPath, borderPaint);

    // 2. 上半轮廓（9 点钟 -> 左上弧 -> 顶直边 -> 右上弧 -> 3 点钟）：
    // 未走过区间绘 1px 玻璃边框，已走过区间直接绘制纯净贴边进度弧，杜绝双层叠加与顶部抗锯齿白边。
    final topPath = Path()
      ..arcTo(
        Rect.fromCircle(
          center: Offset(leftArcCenterX, halfH),
          radius: arcRadius,
        ),
        math.pi,
        math.pi / 2.0,
        false,
      );
    if (rightArcCenterX > leftArcCenterX) {
      topPath.lineTo(rightArcCenterX, inset);
    }
    topPath.arcTo(
      Rect.fromCircle(
        center: Offset(rightArcCenterX, halfH),
        radius: arcRadius,
      ),
      -math.pi / 2.0,
      math.pi / 2.0,
      false,
    );

    final progressPaint = Paint()
      ..color = activeColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = progressStrokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;

    for (final metric in topPath.computeMetrics()) {
      final targetLen = metric.length * clamped;
      if (targetLen < metric.length) {
        canvas.drawPath(
          metric.extractPath(targetLen, metric.length),
          borderPaint,
        );
      }
      if (targetLen > 0.0) {
        canvas.drawPath(metric.extractPath(0.0, targetLen), progressPaint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _CapsuleContourAudioProgressPainter oldDelegate) {
    return (oldDelegate.progress - progress).abs() > 0.001 ||
        oldDelegate.activeColor != activeColor ||
        oldDelegate.borderColor != borderColor ||
        oldDelegate.borderWidth != borderWidth ||
        oldDelegate.progressStrokeWidth != progressStrokeWidth;
  }
}

/// 独立订阅音频播放态的微缩三柱律动指示器（暂停与单测环境立即停钟，零空闲 Ticker）。
class _FloatingMiniEqualizerLeaf extends ConsumerStatefulWidget {
  const _FloatingMiniEqualizerLeaf({
    this.compact = false,
    this.contrastAgainstRing = false,
  });

  final bool compact;

  /// 是否叠加在圆形封面与外圈进度环上：深色模式（白进度环）用纯黑条，浅色模式（黑进度环）用纯白条，清晰区分。
  final bool contrastAgainstRing;

  @override
  ConsumerState<_FloatingMiniEqualizerLeaf> createState() =>
      _FloatingMiniEqualizerLeafState();
}

class _FloatingMiniEqualizerLeafState
    extends ConsumerState<_FloatingMiniEqualizerLeaf>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  bool get _isWidgetTestBinding => WidgetsBinding.instance.runtimeType
      .toString()
      .contains('TestWidgetsFlutterBinding');

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: KonataPlaybackTokens.equalizerCycleDuration,
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _sync(bool playing) {
    if (playing && !_isWidgetTestBinding) {
      if (!_ctrl.isAnimating) {
        _ctrl.repeat();
      }
    } else if (_ctrl.isAnimating) {
      _ctrl.stop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final isPlaying = ref.watch(
      audioPlaybackProvider.select((s) => s.isPlaying),
    );
    _sync(isPlaying);
    final bool useDarkBarOnDisc = widget.contrastAgainstRing && p.isDark;
    final bool useWhiteBarOnDisc = widget.contrastAgainstRing && !p.isDark;
    final barColor = useDarkBarOnDisc
        ? KonataPlaybackTokens.floatingMiniDiscEqualizerDarkBar
        : (useWhiteBarOnDisc ? KonataTheme.pureWhite : p.textPrimary);
    final barShadows = useDarkBarOnDisc
        ? const [
            BoxShadow(
              color: KonataPlaybackTokens.floatingMiniDiscEqualizerLightHalo,
              blurRadius: 3.5,
              spreadRadius: 0.4,
            ),
          ]
        : (useWhiteBarOnDisc
              ? const [
                  BoxShadow(
                    color: KonataTheme.scrimBlackStrong,
                    blurRadius: 3,
                    offset: Offset(0, 1),
                  ),
                ]
              : null);
    final maxH = widget.compact ? 9.0 : 12.0;
    final barW = widget.compact ? 2.0 : 2.4;

    return SizedBox(
      width: barW * 3 + 4,
      height: maxH,
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (_, _) {
          const phases = <double>[0.0, 1.5, 2.8];
          const paused = <double>[0.40, 0.72, 0.50];
          final t = _ctrl.value * 2 * math.pi;
          return Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (var i = 0; i < 3; i++)
                Container(
                  width: barW,
                  height:
                      (maxH *
                              (isPlaying
                                  ? (0.28 +
                                        0.72 *
                                            (0.5 +
                                                0.5 * math.sin(t + phases[i])))
                                  : paused[i]))
                          .clamp(2.4, maxH),
                  decoration: BoxDecoration(
                    color: barColor,
                    borderRadius: KonataTheme.borderRadiusPill,
                    boxShadow: barShadows,
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
