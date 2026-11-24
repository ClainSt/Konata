import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import '../../../domain/playback/playback_formatters.dart';
import '../../../domain/playback/playback_probe_stats.dart';
import '../../theme/konata_adaptive_tokens.dart';
import '../../theme/konata_palette.dart';
import '../../theme/konata_playback_tokens.dart';
import '../design_system/ellipsis_text_with_tooltip.dart';
import '../design_system/konata_adaptive_blur.dart';
import '../../theme/konata_theme.dart';

part 'konata_playback_capsule_rails.dart';

/// 播控胶囊与流光浮层专用的无边框纯图标按钮（零 M3 灰色水波纹残留）。
class KonataCapsuleIconButton extends StatefulWidget {
  /// 创建无边框 OSD 图标按钮。
  const KonataCapsuleIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.color,
    required this.onTap,
    this.onLongPress,
    this.size = 20,
    this.padding = const EdgeInsets.all(6),
    this.highlighted = false,
    this.highlightColor,
    this.highlightBgColor,
    this.showHighlightBorder = true,
    this.showHoverBackground = true,
    this.borderRadius = 999,
    this.fixedSize,
  });

  final IconData icon;
  final String tooltip;
  final Color color;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final double size;
  final EdgeInsetsGeometry padding;
  final bool highlighted;
  final Color? highlightColor;
  final Color? highlightBgColor;
  final bool showHighlightBorder;
  final bool showHoverBackground;
  final double borderRadius;
  final double? fixedSize;

  @override
  State<KonataCapsuleIconButton> createState() =>
      _KonataCapsuleIconButtonState();
}

class _KonataCapsuleIconButtonState extends State<KonataCapsuleIconButton> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    final baseColor = widget.highlighted
        ? (widget.highlightColor ?? widget.color)
        : widget.color;
    final effectiveColor = !enabled
        ? baseColor.withValues(alpha: 0.34)
        : (_hovered || widget.highlighted
              ? baseColor
              : baseColor.withValues(alpha: 0.88));

    return Tooltip(
      message: widget.tooltip,
      waitDuration: KonataTheme.tooltipSlowWaitDuration,
      triggerMode: widget.onLongPress != null
          ? TooltipTriggerMode.manual
          : null,
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() {
          _hovered = false;
          _pressed = false;
        }),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
          onTapUp: enabled ? (_) => setState(() => _pressed = false) : null,
          onTapCancel: () => setState(() => _pressed = false),
          onTap: widget.onTap,
          onLongPress: widget.onLongPress,
          child: AnimatedScale(
            scale: _pressed ? 0.90 : 1.0,
            duration: KonataTheme.capsuleSlideDuration,
            child: AnimatedContainer(
              duration: KonataTheme.motionFast,
              width: widget.fixedSize,
              height: widget.fixedSize,
              padding: widget.padding,
              alignment: widget.fixedSize != null ? Alignment.center : null,
              decoration: BoxDecoration(
                color: widget.highlighted
                    ? (widget.highlightBgColor ??
                          baseColor.withValues(
                            alpha: _hovered && enabled ? 0.28 : 0.22,
                          ))
                    : ((_hovered && enabled && widget.showHoverBackground)
                          ? baseColor.withValues(alpha: 0.12)
                          : Colors.transparent),
                border: (widget.highlighted && widget.showHighlightBorder)
                    ? Border.all(
                        color: baseColor.withValues(alpha: 0.42),
                        width: 1,
                      )
                    : null,
                borderRadius: BorderRadius.circular(widget.borderRadius),
              ),
              child: Icon(
                widget.icon,
                size: widget.size,
                color: effectiveColor,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 音视频播控胶囊左翼最右端共用的 `32×32` 纯图标循环模式切换按钮（严禁附加文字标签）。
class KonataAudioLoopButton extends StatelessWidget {
  /// 创建纯图标循环模式切换按钮（无灰色背景块、无蓝色高亮）。
  const KonataAudioLoopButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.highlighted,
    required this.onTap,
  });

  /// 当前循环模式对应的纯图标。
  final IconData icon;

  /// 悬停提示文案。
  final String tooltip;

  /// 保留字段以兼容调用侧签名（不再施加蓝色或灰底高亮）。
  final bool highlighted;

  /// 点击切换循环模式回调。
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final btnSize = KonataAdaptiveTokens.isAndroid
        ? KonataAdaptiveTokens.touchTarget
        : KonataPlaybackTokens.immersiveSwitchButtonSize;
    return KonataCapsuleIconButton(
      key: const ValueKey('konata_audio_loop_button'),
      icon: icon,
      tooltip: tooltip,
      color: p.textPrimary,
      size: 18,
      fixedSize: btnSize,
      borderRadius: KonataPlaybackTokens.immersiveSwitchButtonRadius,
      padding: EdgeInsets.zero,
      highlighted: false,
      showHighlightBorder: false,
      showHoverBackground: false,
      onTap: onTap,
    );
  }
}

/// 视频页、全屏流光音频页与全局迷你底栏 100% 同源共用的单层悬浮毛玻璃播控胶囊。
///
/// 布局规范：
/// - 高度 `58px`、最大宽度 `760px`、大圆角磨砂悬浮；
/// - 极细进度轨（常态 `2.5px`、悬停平滑增粗至 `6px`）贴紧胶囊最顶内沿并内置章节刻度与悬浮时间预览气泡；
/// - 左侧展示可选微缩封面 + 单行截断标题 + 等宽跳秒计时；
/// - 中央纯粹无底圆纯图标群（播放/暂停绝不切换为缓冲转圈）；
/// - 右侧容纳自定义动作与 [KonataVolumeControl] / [KonataSpecBadge]。
class KonataPlaybackCapsule extends StatefulWidget {
  /// 创建同源单层悬浮毛玻璃播控胶囊。
  const KonataPlaybackCapsule({
    super.key,
    required this.positionSeconds,
    this.positionListenable,
    required this.durationSeconds,
    required this.isPlaying,
    required this.onTogglePlayPause,
    required this.onSeek,
    this.title,
    this.leading,
    this.onTapInfo,
    this.leadingCenterButton,
    this.trailingCenterPrimaryButton,
    this.onPrevious,
    this.onNext,
    this.onToggleList,
    this.isListActive = false,
    this.listTooltip = '列表',
    this.trailingCenterButtons = const [],
    this.rightSlot,
    this.chapters = const [],
    this.supportsThumbnailPreview = false,
    this.previewRevisionListenable,
    this.previewThumbnailResolver,
    this.onPreviewHoverSecondsChanged,
    this.maxWidth,
    this.enableBackdropBlur = true,
  });

  /// 可选最大宽度覆写（例如平板端底部控制坞限制为 `640dp`）。
  final double? maxWidth;

  /// 是否启用底层高斯模糊（Android 硬件视频前景可关闭以消除透明覆盖层双影）。
  final bool enableBackdropBlur;

  /// 当前播放秒数（静态快照或在未传入 [positionListenable] 时作为数据源）。
  final double positionSeconds;

  /// 可选高频播放进度监听源；传入后仅驱动独立细滑轨重绘与 1Hz 时间文本叶子，杜绝 60Hz 整胶囊及毛玻璃重建。
  final ValueListenable<double>? positionListenable;

  /// 总时长秒数。
  final double durationSeconds;

  /// 是否正在播放（与真实播放状态严格同步）。
  final bool isPlaying;

  /// 播放/暂停切换回调。
  final VoidCallback onTogglePlayPause;

  /// 点击或拖拽释放顶边进度轨 Seek 回调（秒）。
  final ValueChanged<double> onSeek;

  /// 左侧单行标题（曲名或集标题）。
  final String? title;

  /// 左侧前置微缩图标（例如音频模式下的微缩圆角封面）。
  final Widget? leading;

  /// 点击左侧信息区回调（例如迷你音频栏展开沉浸页）。
  final VoidCallback? onTapInfo;

  /// 中央左侧扩展图标（例如循环模式切换）。
  final Widget? leadingCenterButton;

  /// 中央五键对称组最右侧扩展图标（例如全屏音频控制坞与循环键等距对称的音量键）。
  final Widget? trailingCenterPrimaryButton;

  /// 上一项回调。
  final VoidCallback? onPrevious;

  /// 下一项回调。
  final VoidCallback? onNext;

  /// `☰` 列表/选集/歌词切换回调。
  final VoidCallback? onToggleList;

  /// 列表切换按钮当前是否处于激活态。
  final bool isListActive;

  /// 列表切换按钮提示文案。
  final String listTooltip;

  /// 中央播控区尾部附加按钮组（例如全屏音乐页独立的「曲目列表 / 同步歌词」双图标）。
  final List<Widget> trailingCenterButtons;

  /// 右侧插槽（放置实时规格微标、音量控件与功能图标）。
  final Widget? rightSlot;

  /// 章节列表（用于顶边细线刻度展示及悬停预览章节名）。
  final List<PlaybackChapter> chapters;

  /// 是否在进度条悬停气泡中展示 `16:9` 视频关键帧缩略图（音频模式关闭）。
  final bool supportsThumbnailPreview;

  /// 缩略图缓存版本号监听句柄（仅局部重建悬停气泡）。
  final ValueListenable<int>? previewRevisionListenable;

  /// 根据秒数解析精确或邻近缓存缩略图帧字节的回调。
  final Uint8List? Function(double seconds)? previewThumbnailResolver;

  /// 进度条悬停/拖拽秒数变更回调（传 `null` 表示指针离开）。
  final ValueChanged<double?>? onPreviewHoverSecondsChanged;

  @override
  State<KonataPlaybackCapsule> createState() => _KonataPlaybackCapsuleState();
}

class _KonataPlaybackCapsuleState extends State<KonataPlaybackCapsule> {
  double? _dragSeconds;
  bool _progressHovered = false;
  double? _hoverRatio;

  int _activeChapterIndexNear(double seconds, double total) {
    if (widget.chapters.isEmpty || total <= 0) return -1;
    for (var i = widget.chapters.length - 1; i >= 0; i--) {
      final ch = widget.chapters[i];
      if (seconds >= ch.startSeconds) {
        return i;
      }
    }
    return -1;
  }

  /// 统一解析悬停/拖拽态命中的章节索引：指针贴近章节点菱形时优先磁吸至最近章节点，确保气泡标题与高亮菱形严格一致。
  int _resolvePreviewChapterIndex({
    required double previewSeconds,
    required double previewRatio,
    required double total,
    required double barSpan,
  }) {
    if (widget.chapters.isEmpty || total <= 0) return -1;
    final hoverX = previewRatio.clamp(0.0, 1.0) * barSpan;
    final halfDiag =
        KonataPlaybackTokens.chapterDiamondHoverSize * math.sqrt2 * 0.5;
    final minCenter = math.min(halfDiag, barSpan * 0.5);
    final maxCenter = math.max(minCenter, barSpan - halfDiag);

    final markerCenters = <(int index, double cx)>[];
    for (var i = 0; i < widget.chapters.length; i++) {
      final start = widget.chapters[i].startSeconds;
      if (start > 0 && start < total) {
        final cx = (start / total * barSpan).clamp(minCenter, maxCenter);
        markerCenters.add((i, cx));
      }
    }

    if (markerCenters.isNotEmpty) {
      var bestIdx = -1;
      var bestCx = 0.0;
      var bestDist = double.infinity;
      for (final entry in markerCenters) {
        final dist = (hoverX - entry.$2).abs();
        if (dist < bestDist) {
          bestDist = dist;
          bestIdx = entry.$1;
          bestCx = entry.$2;
        }
      }
      if (bestIdx >= 0) {
        var nearestNeighbor = double.infinity;
        for (final entry in markerCenters) {
          if (entry.$1 == bestIdx) continue;
          final d = (entry.$2 - bestCx).abs();
          if (d < nearestNeighbor) nearestNeighbor = d;
        }
        final snapRadius = math.min(
          KonataPlaybackTokens.chapterDiamondSnapRadiusPx,
          nearestNeighbor * 0.45,
        );
        if (bestDist <= snapRadius) {
          return bestIdx;
        }
      }
    }

    return _activeChapterIndexNear(
      previewSeconds + KonataPlaybackTokens.chapterHoverBoundaryEpsilonSec,
      total,
    );
  }

  String? _chapterTitleAt(int index) {
    if (index < 0 || index >= widget.chapters.length) return null;
    final title = widget.chapters[index].title.trim();
    return title.isNotEmpty ? title : null;
  }

  void _notifyPreviewSeconds(double? seconds) {
    widget.onPreviewHoverSecondsChanged?.call(seconds);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final total = widget.durationSeconds > 0 ? widget.durationSeconds : 0.0;
    final currentPosSnapshot =
        (_dragSeconds ??
                widget.positionListenable?.value ??
                widget.positionSeconds)
            .clamp(0.0, total > 0 ? total : 1.0);

    final bgColor = widget.enableBackdropBlur
        ? KonataPlaybackTokens.glassSurface(p)
        : KonataTheme.capsuleDarkSurface(p);
    final borderColor = KonataPlaybackTokens.glassBorder(p);
    final primaryFg = p.textPrimary;
    final secondaryFg = p.isDark ? p.textSecondary : p.textPrimary;
    final accentFg = p.progressFill;
    final trackInactive = p.progressTrack;

    final previewRatio = _dragSeconds != null && total > 0
        ? (_dragSeconds! / total).clamp(0.0, 1.0)
        : _hoverRatio;
    final previewSeconds = previewRatio != null && total > 0
        ? previewRatio * total
        : null;
    final showBubble =
        (_progressHovered || _dragSeconds != null) &&
        previewSeconds != null &&
        total > 0;

    final effectiveMaxWidth =
        widget.maxWidth ?? KonataPlaybackTokens.capsuleMaxWidth;
    final touch = KonataAdaptiveTokens.isAndroid;
    final effectiveHeight = touch
        ? KonataAdaptiveTokens.playerHeight
        : KonataPlaybackTokens.capsuleHeight;
    final effectiveRadius = KonataPlaybackTokens.capsuleRadius;
    final actionFixedSize = touch
        ? KonataAdaptiveTokens.touchTarget
        : KonataPlaybackTokens.immersiveSwitchButtonSize;
    final playFixedSize = touch ? KonataAdaptiveTokens.touchTarget : 38.0;

    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.15,
      child: Material(
        type: MaterialType.transparency,
        child: DefaultTextStyle.merge(
          style: const TextStyle(decoration: TextDecoration.none),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: effectiveMaxWidth,
              minWidth: math.min(
                effectiveMaxWidth,
                touch ? 280.0 : KonataPlaybackTokens.capsuleMinWidth,
              ),
            ),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final capsuleWidth = constraints.maxWidth.isFinite
                    ? constraints.maxWidth
                    : effectiveMaxWidth;
                final inset =
                    KonataPlaybackTokens.capsuleProgressHorizontalInset;
                final barSpan = (capsuleWidth - inset * 2).clamp(
                  1.0,
                  capsuleWidth,
                );

                final activeChapterIndex = showBubble
                    ? _resolvePreviewChapterIndex(
                        previewSeconds: previewSeconds,
                        previewRatio: previewRatio!,
                        total: total,
                        barSpan: barSpan,
                      )
                    : _activeChapterIndexNear(currentPosSnapshot, total);
                final previewText = showBubble
                    ? PlaybackFormatters.formatMediaDuration(
                        previewSeconds,
                        alwaysShowHours: total >= 3600,
                      )
                    : '';
                final previewChapter = showBubble
                    ? _chapterTitleAt(activeChapterIndex)
                    : null;
                final bubbleLabel =
                    previewChapter != null && previewChapter.isNotEmpty
                    ? '$previewChapter · $previewText'
                    : previewText;
                final minThumbBubbleWidth = widget.supportsThumbnailPreview
                    ? (KonataPlaybackTokens.thumbnailPreviewDisplayWidth + 16.0)
                    : 58.0;
                final bubbleWidthEstimate = (bubbleLabel.length * 7.4 + 24.0)
                    .clamp(minThumbBubbleWidth, 248.0);
                final anchorX = showBubble
                    ? (inset + previewRatio! * barSpan)
                    : inset;
                final bubbleLeft = (anchorX - bubbleWidthEstimate / 2).clamp(
                  4.0,
                  (capsuleWidth - bubbleWidthEstimate - 4.0).clamp(
                    4.0,
                    capsuleWidth,
                  ),
                );

                final hasTitle =
                    widget.title != null && widget.title!.isNotEmpty;
                Widget leftContent = Row(
                  mainAxisSize: MainAxisSize.max,
                  children: [
                    if (widget.leading != null) ...[
                      widget.leading!,
                      const SizedBox(width: 10),
                    ],
                    Expanded(
                      child: hasTitle
                          ? Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                EllipsisTextWithTooltip(
                                  text: widget.title!,
                                  style: TextStyle(
                                    color: primaryFg,
                                    fontSize: KonataTheme.fontSizeBodySm,
                                    fontWeight: FontWeight.w600,
                                    height: 1.2,
                                  ),
                                ),
                                const SizedBox(height: 1.5),
                                _CapsuleTimeTextLeaf(
                                  positionListenable: widget.positionListenable,
                                  fallbackPositionSeconds:
                                      widget.positionSeconds,
                                  dragSeconds: _dragSeconds,
                                  totalDurationSeconds: total,
                                  style: TextStyle(
                                    color: secondaryFg,
                                    fontSize: KonataTheme.fontSizeCaptionXs,
                                    fontWeight: FontWeight.w400,
                                    fontFeatures:
                                        KonataPlaybackTokens.tabularNumbers,
                                    height: 1.15,
                                  ),
                                ),
                              ],
                            )
                          : Align(
                              alignment: Alignment.centerLeft,
                              child: _CapsuleTimeTextLeaf(
                                positionListenable: widget.positionListenable,
                                fallbackPositionSeconds: widget.positionSeconds,
                                dragSeconds: _dragSeconds,
                                totalDurationSeconds: total,
                                style: TextStyle(
                                  color: primaryFg.withValues(alpha: 0.88),
                                  fontSize: KonataTheme.fontSizeCaption,
                                  fontWeight: FontWeight.w500,
                                  fontFeatures:
                                      KonataPlaybackTokens.tabularNumbers,
                                  height: 1.15,
                                ),
                              ),
                            ),
                    ),
                  ],
                );

                if (widget.onTapInfo != null) {
                  leftContent = MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: widget.onTapInfo,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          vertical: 4,
                          horizontal: 2,
                        ),
                        child: leftContent,
                      ),
                    ),
                  );
                }

                final capsuleSurface = Container(
                  height: effectiveHeight,
                  decoration: BoxDecoration(
                    gradient: KonataTheme.opticalSheenGradient(
                      p,
                      baseColor: bgColor,
                    ),
                    borderRadius: BorderRadius.circular(effectiveRadius),
                  ),
                  child: Stack(
                    children: [
                      // 0. 胶囊外轮廓描边（有活跃进度条时让出顶沿平直段，使进度条与胶囊边缘浑然一体无双线夹缝）
                      Positioned.fill(
                        child: IgnorePointer(
                          child: CustomPaint(
                            painter: _PlaybackCapsuleBorderPainter(
                              borderColor: borderColor,
                              omitTopRailSpan: total > 0,
                              railHorizontalInset: inset,
                            ),
                          ),
                        ),
                      ),
                      // 1. 响应式三区对称枢轴主控内容区（锁死上一话/播放暂停/下一话严格位于胶囊 50.0% 绝对正中心）
                      Padding(
                        padding: touch
                            ? const EdgeInsets.fromLTRB(18, 9, 18, 4)
                            : KonataPlaybackTokens.capsulePadding,
                        child: LayoutBuilder(
                          builder: (context, rowConstraints) {
                            final playPauseButton = KeyedSubtree(
                              key: const ValueKey(
                                'konata_capsule_play_pause_button',
                              ),
                              child: KonataCapsuleIconButton(
                                icon: widget.isPlaying
                                    ? Icons.pause_rounded
                                    : Icons.play_arrow_rounded,
                                tooltip: widget.isPlaying ? '暂停' : '播放',
                                color: primaryFg,
                                size: 24,
                                fixedSize: playFixedSize,
                                borderRadius: 999,
                                padding: EdgeInsets.zero,
                                onTap: widget.onTogglePlayPause,
                              ),
                            );
                            final prevSlot = KonataCapsuleIconButton(
                              icon: Icons.skip_previous_rounded,
                              tooltip: '上一项',
                              color: primaryFg,
                              size: 20,
                              fixedSize: actionFixedSize,
                              borderRadius: KonataPlaybackTokens
                                  .immersiveSwitchButtonRadius,
                              padding: EdgeInsets.zero,
                              onTap: widget.onPrevious,
                            );
                            final nextSlot = KonataCapsuleIconButton(
                              icon: Icons.skip_next_rounded,
                              tooltip: '下一项',
                              color: primaryFg,
                              size: 20,
                              fixedSize: actionFixedSize,
                              borderRadius: KonataPlaybackTokens
                                  .immersiveSwitchButtonRadius,
                              padding: EdgeInsets.zero,
                              onTap: widget.onNext,
                            );
                            final listButton = widget.onToggleList != null
                                ? KonataCapsuleIconButton(
                                    icon: Icons.menu_rounded,
                                    tooltip: widget.listTooltip,
                                    color: primaryFg,
                                    size: 18,
                                    fixedSize: actionFixedSize,
                                    borderRadius: KonataPlaybackTokens
                                        .immersiveSwitchButtonRadius,
                                    padding: EdgeInsets.zero,
                                    highlighted: widget.isListActive,
                                    highlightColor: accentFg,
                                    showHighlightBorder: false,
                                    onTap: widget.onToggleList,
                                  )
                                : null;

                            final symmetricMinWidth = touch
                                ? 420.0
                                : (KonataPlaybackTokens
                                          .capsuleCenterSymmetricBreakpoint -
                                      KonataPlaybackTokens
                                          .capsulePadding
                                          .horizontal);
                            final useSymmetricCenter =
                                rowConstraints.maxWidth >= symmetricMinWidth;

                            if (useSymmetricCenter) {
                              final centerGap = touch ? 6.0 : 12.0;
                              final fiveKeyCenter =
                                  widget.trailingCenterPrimaryButton != null &&
                                  widget.leadingCenterButton != null;
                              return Row(
                                crossAxisAlignment: CrossAxisAlignment.center,
                                children: [
                                  Expanded(
                                    child: Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.center,
                                      children: [
                                        Expanded(child: leftContent),
                                        if (!fiveKeyCenter &&
                                            widget.leadingCenterButton !=
                                                null) ...[
                                          const SizedBox(width: 4),
                                          widget.leadingCenterButton!,
                                        ],
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Row(
                                    key: const ValueKey(
                                      'konata_capsule_center_transport',
                                    ),
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.center,
                                    children: [
                                      if (fiveKeyCenter) ...[
                                        widget.leadingCenterButton!,
                                        SizedBox(width: centerGap),
                                      ],
                                      prevSlot,
                                      SizedBox(width: centerGap),
                                      playPauseButton,
                                      SizedBox(width: centerGap),
                                      nextSlot,
                                      if (fiveKeyCenter) ...[
                                        SizedBox(width: centerGap),
                                        widget.trailingCenterPrimaryButton!,
                                      ],
                                    ],
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Align(
                                      alignment: Alignment.centerRight,
                                      child: FittedBox(
                                        fit: BoxFit.scaleDown,
                                        alignment: Alignment.centerRight,
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          crossAxisAlignment:
                                              CrossAxisAlignment.center,
                                          children: [
                                            if (!fiveKeyCenter &&
                                                widget
                                                        .trailingCenterPrimaryButton !=
                                                    null) ...[
                                              widget
                                                  .trailingCenterPrimaryButton!,
                                              if (listButton != null ||
                                                  widget
                                                      .trailingCenterButtons
                                                      .isNotEmpty ||
                                                  widget.rightSlot != null)
                                                const SizedBox(width: 2),
                                            ],
                                            if (listButton != null) ...[
                                              listButton,
                                              if (widget
                                                      .trailingCenterButtons
                                                      .isNotEmpty ||
                                                  widget.rightSlot != null)
                                                const SizedBox(width: 2),
                                            ],
                                            if (widget
                                                .trailingCenterButtons
                                                .isNotEmpty) ...[
                                              Row(
                                                mainAxisSize: MainAxisSize.min,
                                                children: widget
                                                    .trailingCenterButtons,
                                              ),
                                              if (widget.rightSlot != null)
                                                const SizedBox(width: 4),
                                            ],
                                            if (widget.rightSlot != null)
                                              widget.rightSlot!,
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              );
                            }

                            final ultraCompactTouch =
                                touch && rowConstraints.maxWidth < 350.0;
                            return Row(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                Expanded(child: leftContent),
                                const SizedBox(width: 8),
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    ?widget.leadingCenterButton,
                                    if (widget.onPrevious != null &&
                                        !ultraCompactTouch)
                                      prevSlot,
                                    playPauseButton,
                                    if (widget.onNext != null &&
                                        !ultraCompactTouch)
                                      nextSlot,
                                    ?widget.trailingCenterPrimaryButton,
                                    ?listButton,
                                    if (!ultraCompactTouch)
                                      ...widget.trailingCenterButtons,
                                  ],
                                ),
                                if (widget.rightSlot != null) ...[
                                  const SizedBox(width: 8),
                                  widget.rightSlot!,
                                ],
                              ],
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                );

                return Stack(
                  clipBehavior: Clip.none,
                  children: [
                    // 静态毛玻璃主体与按钮群（60Hz 进度推进零脏区传播，与顶沿细滑轨物理隔离合成层）
                    RepaintBoundary(
                      child: Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(effectiveRadius),
                          boxShadow: [
                            BoxShadow(
                              color: KonataPlaybackTokens.shadowColor(p),
                              blurRadius: 28,
                              offset: const Offset(0, 10),
                            ),
                          ],
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(effectiveRadius),
                          child: widget.enableBackdropBlur
                              ? KonataAdaptiveBackdropBlur(
                                  filter: KonataTheme.blurFilterCapsule,
                                  child: capsuleSurface,
                                )
                              : capsuleSurface,
                        ),
                      ),
                    ),
                    // 2. 胶囊顶沿内嵌发光全圆角细滑轨与全量 45° 菱形章节点（独立 RepaintBoundary，位于 BackdropFilter 之上）
                    Positioned(
                      left: inset,
                      right: inset,
                      top: 0,
                      height: KonataPlaybackTokens.capsuleProgressHitHeight,
                      child: RepaintBoundary(
                        child: _InsetTopProgressRail(
                          positionListenable: widget.positionListenable,
                          fallbackPositionSeconds: widget.positionSeconds,
                          dragSeconds: _dragSeconds,
                          totalDurationSeconds: total,
                          chapters: widget.chapters,
                          activeChapterIndex: activeChapterIndex,
                          hovered: _progressHovered || _dragSeconds != null,
                          isDark: p.isDark,
                          activeColor: accentFg,
                          inactiveColor: trackInactive,
                          onHoverChanged: (hovering, ratio) {
                            setState(() {
                              _progressHovered = hovering;
                              _hoverRatio = hovering ? ratio : null;
                            });
                            if (hovering && ratio != null && total > 0) {
                              _notifyPreviewSeconds(ratio * total);
                            } else if (_dragSeconds == null) {
                              _notifyPreviewSeconds(null);
                            }
                          },
                          onScrubStartOrUpdate: (ratio) {
                            if (total <= 0) return;
                            final sec = ratio * total;
                            setState(() {
                              _dragSeconds = sec;
                              _hoverRatio = ratio;
                            });
                            _notifyPreviewSeconds(sec);
                          },
                          onScrubEnd: () {
                            final target = _dragSeconds;
                            setState(() => _dragSeconds = null);
                            if (!_progressHovered) {
                              _notifyPreviewSeconds(null);
                            }
                            if (target != null && total > 0) {
                              widget.onSeek(target);
                            }
                          },
                          onScrubCommitRatio: (ratio) {
                            if (total <= 0) return;
                            final target = ratio * total;
                            setState(() => _dragSeconds = null);
                            if (!_progressHovered) {
                              _notifyPreviewSeconds(null);
                            }
                            widget.onSeek(target);
                          },
                        ),
                      ),
                    ),
                    // 3. 顶沿进度条悬停 / 拖拽预览气泡（视频模式下紧贴顶沿上方展示 16:9 缩略图）
                    if (showBubble)
                      Positioned(
                        left: bubbleLeft,
                        bottom: effectiveHeight + 10.0,
                        child: IgnorePointer(
                          child: _TopHoverPreviewBubble(
                            supportsThumbnailPreview:
                                widget.supportsThumbnailPreview,
                            previewRevisionListenable:
                                widget.previewRevisionListenable,
                            previewThumbnailResolver:
                                widget.previewThumbnailResolver,
                            previewSeconds: previewSeconds,
                            timeLabel: previewText,
                            chapterTitle: previewChapter,
                            maxWidth: bubbleWidthEstimate,
                            bgColor: bgColor,
                            borderColor: borderColor,
                            primaryFg: primaryFg,
                            secondaryFg: secondaryFg,
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

