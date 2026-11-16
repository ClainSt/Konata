import 'dart:ui';

import 'package:flutter/material.dart';

import '../../../domain/playback/playback_formatters.dart';
import '../../../domain/playback/playback_probe_stats.dart';
import '../../theme/konata_palette.dart';
import '../../theme/konata_playback_tokens.dart';
import '../design_system/ellipsis_text_with_tooltip.dart';

/// 播控胶囊与流光浮层专用的无边框纯图标按钮（零 M3 灰色水波纹残留）。
class KonataCapsuleIconButton extends StatefulWidget {
  /// 创建无边框 OSD 图标按钮。
  const KonataCapsuleIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.color,
    required this.onTap,
    this.size = 20,
    this.padding = const EdgeInsets.all(6),
    this.highlighted = false,
    this.highlightColor,
  });

  final IconData icon;
  final String tooltip;
  final Color color;
  final VoidCallback? onTap;
  final double size;
  final EdgeInsetsGeometry padding;
  final bool highlighted;
  final Color? highlightColor;

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
      waitDuration: const Duration(milliseconds: 450),
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
          child: AnimatedScale(
            scale: _pressed ? 0.90 : 1.0,
            duration: const Duration(milliseconds: 100),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              padding: widget.padding,
              decoration: BoxDecoration(
                color: (_hovered && enabled)
                    ? baseColor.withValues(alpha: 0.12)
                    : (widget.highlighted
                          ? baseColor.withValues(alpha: 0.10)
                          : Colors.transparent),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Icon(widget.icon, size: widget.size, color: effectiveColor),
            ),
          ),
        ),
      ),
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
    required this.durationSeconds,
    required this.isPlaying,
    required this.onTogglePlayPause,
    required this.onSeek,
    this.title,
    this.leading,
    this.onTapInfo,
    this.leadingCenterButton,
    this.onPrevious,
    this.onNext,
    this.onToggleList,
    this.isListActive = false,
    this.listTooltip = '列表',
    this.rightSlot,
    this.chapters = const [],
    this.forceOnDarkOverlay = true,
  });

  /// 当前播放秒数。
  final double positionSeconds;

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

  /// 右侧插槽（放置实时规格微标、音量控件与功能图标）。
  final Widget? rightSlot;

  /// 章节列表（用于顶边细线刻度展示及悬停预览章节名）。
  final List<PlaybackChapter> chapters;

  /// 是否强制使用深色毛玻璃外观（视频页与全屏流光页开启，浅色/深色主界面迷你底栏跟随系统主题）。
  final bool forceOnDarkOverlay;

  @override
  State<KonataPlaybackCapsule> createState() => _KonataPlaybackCapsuleState();
}

class _KonataPlaybackCapsuleState extends State<KonataPlaybackCapsule> {
  double? _dragSeconds;
  bool _progressHovered = false;
  double? _hoverRatio;

  String? _chapterTitleNear(double seconds, double total) {
    if (widget.chapters.isEmpty || total <= 0) return null;
    for (var i = widget.chapters.length - 1; i >= 0; i--) {
      final ch = widget.chapters[i];
      if (seconds >= ch.startSeconds) {
        return ch.title.trim().isNotEmpty ? ch.title.trim() : null;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final total = widget.durationSeconds > 0 ? widget.durationSeconds : 0.0;
    final effectivePos = (_dragSeconds ?? widget.positionSeconds).clamp(
      0.0,
      total > 0 ? total : 1.0,
    );
    final progressRatio = total > 0
        ? (effectivePos / total).clamp(0.0, 1.0)
        : 0.0;
    final showHours = total >= 3600;
    final currentText = PlaybackFormatters.formatMediaDuration(
      total > 0 ? effectivePos : 0.0,
      alwaysShowHours: showHours,
    );
    final totalText = PlaybackFormatters.formatMediaDuration(
      total,
      alwaysShowHours: showHours,
    );

    final bgColor = widget.forceOnDarkOverlay
        ? KonataPlaybackTokens.osdSurfaceDark
        : p.elevatedSurface.withValues(alpha: p.isDark ? 0.84 : 0.90);
    final borderColor = widget.forceOnDarkOverlay
        ? KonataPlaybackTokens.osdBorderLight
        : p.hairline;
    final primaryFg = widget.forceOnDarkOverlay
        ? KonataPlaybackTokens.osdTextPrimary
        : p.textPrimary;
    final secondaryFg = widget.forceOnDarkOverlay
        ? KonataPlaybackTokens.osdTextSecondary
        : p.textSecondary;
    final accentFg = widget.forceOnDarkOverlay
        ? KonataPlaybackTokens.osdAccent
        : p.accent;
    final trackInactive = widget.forceOnDarkOverlay
        ? Colors.white.withValues(alpha: 0.18)
        : p.hairline.withValues(alpha: 0.55);

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

    return ConstrainedBox(
      constraints: const BoxConstraints(
        maxWidth: KonataPlaybackTokens.capsuleMaxWidth,
        minWidth: KonataPlaybackTokens.capsuleMinWidth,
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final capsuleWidth = constraints.maxWidth.isFinite
              ? constraints.maxWidth
              : KonataPlaybackTokens.capsuleMaxWidth;
          final inset = KonataPlaybackTokens.capsuleProgressHorizontalInset;
          final barSpan = (capsuleWidth - inset * 2).clamp(1.0, capsuleWidth);

          final previewText = showBubble
              ? PlaybackFormatters.formatMediaDuration(
                  previewSeconds,
                  alwaysShowHours: total >= 3600,
                )
              : '';
          final previewChapter = showBubble
              ? _chapterTitleNear(previewSeconds, total)
              : null;
          final bubbleLabel =
              previewChapter != null && previewChapter.isNotEmpty
              ? '$previewText · $previewChapter'
              : previewText;
          final bubbleWidthEstimate = (bubbleLabel.length * 7.2 + 24.0).clamp(
            58.0,
            240.0,
          );
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

          Widget leftContent = Row(
            mainAxisSize: MainAxisSize.max,
            children: [
              if (widget.leading != null) ...[
                widget.leading!,
                const SizedBox(width: 10),
              ],
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (widget.title != null && widget.title!.isNotEmpty)
                      EllipsisTextWithTooltip(
                        text: widget.title!,
                        style: TextStyle(
                          color: primaryFg,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          height: 1.2,
                        ),
                      ),
                    const SizedBox(height: 1.5),
                    Text(
                      '$currentText / $totalText',
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: secondaryFg,
                        fontSize: 11,
                        fontWeight: FontWeight.w400,
                        fontFeatures: KonataPlaybackTokens.tabularNumbers,
                        height: 1.15,
                      ),
                    ),
                  ],
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

          return Stack(
            clipBehavior: Clip.none,
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(
                    KonataPlaybackTokens.capsuleRadius,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.30),
                      blurRadius: 28,
                      offset: const Offset(0, 10),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(
                    KonataPlaybackTokens.capsuleRadius,
                  ),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(
                      sigmaX: KonataPlaybackTokens.capsuleBlurSigma,
                      sigmaY: KonataPlaybackTokens.capsuleBlurSigma,
                    ),
                    child: Container(
                      height: KonataPlaybackTokens.capsuleHeight,
                      decoration: BoxDecoration(
                        color: bgColor,
                        borderRadius: BorderRadius.circular(
                          KonataPlaybackTokens.capsuleRadius,
                        ),
                        border: Border.all(color: borderColor, width: 1),
                      ),
                      child: Stack(
                        children: [
                          // 1. 单层三栏主控内容区
                          Padding(
                            padding: KonataPlaybackTokens.capsulePadding,
                            child: Row(
                              children: [
                                Expanded(flex: 4, child: leftContent),
                                const SizedBox(width: 8),
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (widget.leadingCenterButton != null)
                                      widget.leadingCenterButton!,
                                    if (widget.onPrevious != null)
                                      KonataCapsuleIconButton(
                                        icon: Icons.skip_previous_rounded,
                                        tooltip: '上一项',
                                        color: primaryFg,
                                        size: 22,
                                        onTap: widget.onPrevious,
                                      ),
                                    KonataCapsuleIconButton(
                                      icon: widget.isPlaying
                                          ? Icons.pause_rounded
                                          : Icons.play_arrow_rounded,
                                      tooltip: widget.isPlaying ? '暂停' : '播放',
                                      color: primaryFg,
                                      size: 27,
                                      padding: const EdgeInsets.all(6),
                                      onTap: widget.onTogglePlayPause,
                                    ),
                                    if (widget.onNext != null)
                                      KonataCapsuleIconButton(
                                        icon: Icons.skip_next_rounded,
                                        tooltip: '下一项',
                                        color: primaryFg,
                                        size: 22,
                                        onTap: widget.onNext,
                                      ),
                                    if (widget.onToggleList != null)
                                      KonataCapsuleIconButton(
                                        icon: Icons.menu_rounded,
                                        tooltip: widget.listTooltip,
                                        color: primaryFg,
                                        size: 19,
                                        highlighted: widget.isListActive,
                                        highlightColor: accentFg,
                                        onTap: widget.onToggleList,
                                      ),
                                  ],
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  flex: 4,
                                  child: Align(
                                    alignment: Alignment.centerRight,
                                    child: FittedBox(
                                      fit: BoxFit.scaleDown,
                                      alignment: Alignment.centerRight,
                                      child:
                                          widget.rightSlot ??
                                          const SizedBox.shrink(),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          // 2. 紧贴胶囊最顶边内沿的超薄交互进度线
                          Positioned(
                            top: 0,
                            left: inset,
                            right: inset,
                            height: KonataPlaybackTokens.capsuleProgressHitHeight,
                            child: _TopProgressLine(
                              progressRatio: progressRatio,
                              totalDurationSeconds: total,
                              chapters: widget.chapters,
                              hovered: _progressHovered || _dragSeconds != null,
                              activeColor: primaryFg,
                              inactiveColor: trackInactive,
                              onHoverChanged: (hovering, ratio) {
                                setState(() {
                                  _progressHovered = hovering;
                                  _hoverRatio = hovering ? ratio : null;
                                });
                              },
                              onScrubStartOrUpdate: (ratio) {
                                if (total <= 0) return;
                                setState(() {
                                  _dragSeconds = ratio * total;
                                  _hoverRatio = ratio;
                                });
                              },
                              onScrubEnd: () {
                                final target = _dragSeconds;
                                setState(() => _dragSeconds = null);
                                if (target != null && total > 0) {
                                  widget.onSeek(target);
                                }
                              },
                              onScrubCommitRatio: (ratio) {
                                if (total <= 0) return;
                                final target = ratio * total;
                                setState(() => _dragSeconds = null);
                                widget.onSeek(target);
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              // 3. 顶边进度条悬停 / 拖拽时间戳预览气泡
              if (showBubble)
                Positioned(
                  left: bubbleLeft,
                  bottom: KonataPlaybackTokens.capsuleHoverBubbleBottomOffset,
                  child: IgnorePointer(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(999),
                      child: BackdropFilter(
                        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                        child: Container(
                          constraints: BoxConstraints(
                            maxWidth: bubbleWidthEstimate,
                          ),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: bgColor,
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(color: borderColor, width: 1),
                          ),
                          child: Text(
                            bubbleLabel,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: primaryFg,
                              fontSize: 11.5,
                              fontWeight: FontWeight.w600,
                              fontFeatures: KonataPlaybackTokens.tabularNumbers,
                            ),
                          ),
                        ),
                      ),
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

class _TopProgressLine extends StatelessWidget {
  const _TopProgressLine({
    required this.progressRatio,
    required this.totalDurationSeconds,
    required this.chapters,
    required this.hovered,
    required this.activeColor,
    required this.inactiveColor,
    required this.onHoverChanged,
    required this.onScrubStartOrUpdate,
    required this.onScrubEnd,
    required this.onScrubCommitRatio,
  });

  final double progressRatio;
  final double totalDurationSeconds;
  final List<PlaybackChapter> chapters;
  final bool hovered;
  final Color activeColor;
  final Color inactiveColor;
  final void Function(bool hovering, double? ratio) onHoverChanged;
  final ValueChanged<double> onScrubStartOrUpdate;
  final VoidCallback onScrubEnd;
  final ValueChanged<double> onScrubCommitRatio;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth > 0 ? constraints.maxWidth : 1.0;
        double ratioAt(double dx) => (dx / width).clamp(0.0, 1.0);
        final visualHeight = hovered
            ? KonataPlaybackTokens.capsuleProgressHoverHeight
            : KonataPlaybackTokens.capsuleProgressRestHeight;

        return MouseRegion(
          cursor: totalDurationSeconds > 0
              ? SystemMouseCursors.click
              : SystemMouseCursors.basic,
          onEnter: (e) => onHoverChanged(true, ratioAt(e.localPosition.dx)),
          onHover: (e) => onHoverChanged(true, ratioAt(e.localPosition.dx)),
          onExit: (_) => onHoverChanged(false, null),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (d) => onScrubCommitRatio(ratioAt(d.localPosition.dx)),
            onHorizontalDragStart: (d) =>
                onScrubStartOrUpdate(ratioAt(d.localPosition.dx)),
            onHorizontalDragUpdate: (d) =>
                onScrubStartOrUpdate(ratioAt(d.localPosition.dx)),
            onHorizontalDragEnd: (_) => onScrubEnd(),
            onHorizontalDragCancel: onScrubEnd,
            child: Align(
              alignment: Alignment.topCenter,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 140),
                curve: Curves.easeOutCubic,
                height: visualHeight,
                width: width,
                child: ClipRRect(
                  borderRadius: const BorderRadius.vertical(
                    bottom: Radius.circular(999),
                  ),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      ColoredBox(color: inactiveColor),
                      FractionallySizedBox(
                        alignment: Alignment.centerLeft,
                        widthFactor: progressRatio,
                        child: ColoredBox(color: activeColor),
                      ),
                      if (hovered && totalDurationSeconds > 0)
                        for (final ch in chapters)
                          if (ch.startSeconds > 0 &&
                              ch.startSeconds < totalDurationSeconds)
                            Positioned(
                              left:
                                  ((ch.startSeconds / totalDurationSeconds)
                                              .clamp(0.0, 1.0) *
                                          width -
                                      1.0)
                                  .clamp(0.0, width - 2.0),
                              top: 0,
                              bottom: 0,
                              width: 2.0,
                              child: ColoredBox(
                                color: Colors.black.withValues(alpha: 0.45),
                              ),
                            ),
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
