import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../domain/playback/playback_formatters.dart';
import '../../../domain/playback/playback_probe_stats.dart';
import '../../theme/konata_adaptive_tokens.dart';
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

  String? _chapterTitleNear(double seconds, double total) {
    final idx = _activeChapterIndexNear(seconds, total);
    if (idx < 0) return null;
    final title = widget.chapters[idx].title.trim();
    return title.isNotEmpty ? title : null;
  }

  void _notifyPreviewSeconds(double? seconds) {
    widget.onPreviewHoverSecondsChanged?.call(seconds);
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

    final bgColor = widget.enableBackdropBlur
        ? KonataPlaybackTokens.glassSurface(p)
        : (p.isDark ? const Color(0xCC161618) : p.surface);
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
    final effectiveRadius = touch
        ? KonataAdaptiveTokens.capsuleRadius
        : KonataPlaybackTokens.capsuleRadius;
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
              final inset = KonataPlaybackTokens.capsuleProgressHorizontalInset;
              final barSpan = (capsuleWidth - inset * 2).clamp(
                1.0,
                capsuleWidth,
              );

              final activeChapterIndex = _activeChapterIndexNear(
                previewSeconds ?? effectivePos,
                total,
              );
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

              final hasTitle = widget.title != null && widget.title!.isNotEmpty;
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
                                  fontFeatures:
                                      KonataPlaybackTokens.tabularNumbers,
                                  height: 1.15,
                                ),
                              ),
                            ],
                          )
                        : Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              '$currentText / $totalText',
                              maxLines: 1,
                              softWrap: false,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: primaryFg.withValues(alpha: 0.88),
                                fontSize: 12,
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

              return Stack(
                clipBehavior: Clip.none,
                children: [
                  Container(
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
                    foregroundDecoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(effectiveRadius),
                      border: Border.all(color: borderColor, width: 1),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(effectiveRadius),
                      child: Builder(
                        builder: (context) {
                          final capsuleSurface = Container(
                            height: effectiveHeight,
                            decoration: BoxDecoration(
                              color: bgColor,
                              borderRadius: BorderRadius.circular(
                                effectiveRadius,
                              ),
                            ),
                            child: Stack(
                              children: [
                                // 1. 响应式三区对称枢轴主控内容区（锁死上一话/播放暂停/下一话严格位于胶囊 50.0% 绝对正中心）
                                Padding(
                                  padding: touch
                                      ? const EdgeInsets.fromLTRB(12, 2, 12, 10)
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
                                          tooltip: widget.isPlaying
                                              ? '暂停'
                                              : '播放',
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
                                      final listButton =
                                          widget.onToggleList != null
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
                                          rowConstraints.maxWidth >=
                                          symmetricMinWidth;

                                      if (useSymmetricCenter) {
                                        final centerGap = touch ? 6.0 : 12.0;
                                        final fiveKeyCenter =
                                            widget
                                                    .trailingCenterPrimaryButton !=
                                                null &&
                                            widget.leadingCenterButton != null;
                                        return Row(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.center,
                                          children: [
                                            Expanded(
                                              child: Row(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.center,
                                                children: [
                                                  Expanded(child: leftContent),
                                                  if (!fiveKeyCenter &&
                                                      widget
                                                              .leadingCenterButton !=
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
                                                  widget
                                                      .trailingCenterPrimaryButton!,
                                                ],
                                              ],
                                            ),
                                            const SizedBox(width: 8),
                                            Expanded(
                                              child: Align(
                                                alignment:
                                                    Alignment.centerRight,
                                                child: FittedBox(
                                                  fit: BoxFit.scaleDown,
                                                  alignment:
                                                      Alignment.centerRight,
                                                  child: Row(
                                                    mainAxisSize:
                                                        MainAxisSize.min,
                                                    crossAxisAlignment:
                                                        CrossAxisAlignment
                                                            .center,
                                                    children: [
                                                      if (!fiveKeyCenter &&
                                                          widget
                                                                  .trailingCenterPrimaryButton !=
                                                              null) ...[
                                                        widget
                                                            .trailingCenterPrimaryButton!,
                                                        if (listButton !=
                                                                null ||
                                                            widget
                                                                .trailingCenterButtons
                                                                .isNotEmpty ||
                                                            widget.rightSlot !=
                                                                null)
                                                          const SizedBox(
                                                            width: 2,
                                                          ),
                                                      ],
                                                      if (listButton !=
                                                          null) ...[
                                                        listButton,
                                                        if (widget
                                                                .trailingCenterButtons
                                                                .isNotEmpty ||
                                                            widget.rightSlot !=
                                                                null)
                                                          const SizedBox(
                                                            width: 2,
                                                          ),
                                                      ],
                                                      if (widget
                                                          .trailingCenterButtons
                                                          .isNotEmpty) ...[
                                                        Row(
                                                          mainAxisSize:
                                                              MainAxisSize.min,
                                                          children: widget
                                                              .trailingCenterButtons,
                                                        ),
                                                        if (widget.rightSlot !=
                                                            null)
                                                          const SizedBox(
                                                            width: 4,
                                                          ),
                                                      ],
                                                      if (widget.rightSlot !=
                                                          null)
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
                                          touch &&
                                          rowConstraints.maxWidth < 350.0;
                                      return Row(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.center,
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
                                              ?widget
                                                  .trailingCenterPrimaryButton,
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
                                // 2. 胶囊内部底置内缩全圆角细滑轨与 45° 菱形章节点
                                Positioned(
                                  left: inset,
                                  right: inset,
                                  bottom: 0,
                                  height: KonataPlaybackTokens
                                      .capsuleProgressHitHeight,
                                  child: _InsetBottomProgressRail(
                                    progressRatio: progressRatio,
                                    totalDurationSeconds: total,
                                    chapters: widget.chapters,
                                    activeChapterIndex: activeChapterIndex,
                                    hovered:
                                        _progressHovered ||
                                        _dragSeconds != null,
                                    activeColor: accentFg,
                                    inactiveColor: trackInactive,
                                    onHoverChanged: (hovering, ratio) {
                                      setState(() {
                                        _progressHovered = hovering;
                                        _hoverRatio = hovering ? ratio : null;
                                      });
                                      if (hovering &&
                                          ratio != null &&
                                          total > 0) {
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
                              ],
                            ),
                          );
                          if (!widget.enableBackdropBlur) {
                            return capsuleSurface;
                          }
                          return BackdropFilter(
                            filter: ImageFilter.blur(
                              sigmaX: KonataPlaybackTokens.capsuleBlurSigma,
                              sigmaY: KonataPlaybackTokens.capsuleBlurSigma,
                            ),
                            child: capsuleSurface,
                          );
                        },
                      ),
                    ),
                  ),
                  // 3. 进度条悬停 / 拖拽预览气泡（视频模式下上方展示 16:9 缩略图）
                  if (showBubble)
                    Positioned(
                      left: bubbleLeft,
                      bottom:
                          KonataPlaybackTokens.capsuleHoverBubbleBottomOffset,
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

class _TopHoverPreviewBubble extends StatelessWidget {
  const _TopHoverPreviewBubble({
    required this.supportsThumbnailPreview,
    required this.previewRevisionListenable,
    required this.previewThumbnailResolver,
    required this.previewSeconds,
    required this.timeLabel,
    required this.chapterTitle,
    required this.maxWidth,
    required this.bgColor,
    required this.borderColor,
    required this.primaryFg,
    required this.secondaryFg,
  });

  final bool supportsThumbnailPreview;
  final ValueListenable<int>? previewRevisionListenable;
  final Uint8List? Function(double seconds)? previewThumbnailResolver;
  final double previewSeconds;
  final String timeLabel;
  final String? chapterTitle;
  final double maxWidth;
  final Color bgColor;
  final Color borderColor;
  final Color primaryFg;
  final Color secondaryFg;

  Widget _buildThumbnailFrame(Uint8List? bytes) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(
        KonataPlaybackTokens.thumbnailPreviewRadius,
      ),
      child: Container(
        width: KonataPlaybackTokens.thumbnailPreviewDisplayWidth,
        height: KonataPlaybackTokens.thumbnailPreviewDisplayHeight,
        color: Colors.black.withValues(alpha: 0.48),
        child: bytes != null && bytes.isNotEmpty
            ? Image.memory(
                bytes,
                width: KonataPlaybackTokens.thumbnailPreviewDisplayWidth,
                height: KonataPlaybackTokens.thumbnailPreviewDisplayHeight,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                filterQuality: FilterQuality.medium,
                errorBuilder: (_, _, _) => Center(
                  child: Icon(
                    Icons.movie_outlined,
                    size: 22,
                    color: secondaryFg,
                  ),
                ),
              )
            : Center(
                child: Icon(Icons.movie_outlined, size: 22, color: secondaryFg),
              ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!supportsThumbnailPreview) {
      final pillText = (chapterTitle != null && chapterTitle!.isNotEmpty)
          ? '$chapterTitle · $timeLabel'
          : timeLabel;
      return Material(
        type: MaterialType.transparency,
        child: DefaultTextStyle.merge(
          style: const TextStyle(decoration: TextDecoration.none),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
              child: Container(
                constraints: BoxConstraints(maxWidth: maxWidth),
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
                  pillText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: primaryFg,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    fontFeatures: KonataPlaybackTokens.tabularNumbers,
                    decoration: TextDecoration.none,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    Widget thumbnailSlot() {
      if (previewRevisionListenable != null &&
          previewThumbnailResolver != null) {
        return ValueListenableBuilder<int>(
          valueListenable: previewRevisionListenable!,
          builder: (_, _, _) =>
              _buildThumbnailFrame(previewThumbnailResolver!(previewSeconds)),
        );
      }
      return _buildThumbnailFrame(
        previewThumbnailResolver?.call(previewSeconds),
      );
    }

    return Material(
      type: MaterialType.transparency,
      child: DefaultTextStyle.merge(
        style: const TextStyle(decoration: TextDecoration.none),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
            child: Container(
              constraints: BoxConstraints(maxWidth: maxWidth),
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: bgColor,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: borderColor, width: 1),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  thumbnailSlot(),
                  const SizedBox(height: 6),
                  SizedBox(
                    width: KonataPlaybackTokens.thumbnailPreviewDisplayWidth,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        if (chapterTitle != null &&
                            chapterTitle!.isNotEmpty) ...[
                          Flexible(
                            child: Text(
                              chapterTitle!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: secondaryFg,
                                fontSize: 11.0,
                                fontWeight: FontWeight.w500,
                                decoration: TextDecoration.none,
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                        ],
                        Text(
                          timeLabel,
                          maxLines: 1,
                          softWrap: false,
                          style: TextStyle(
                            color: primaryFg,
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                            fontFeatures: KonataPlaybackTokens.tabularNumbers,
                            decoration: TextDecoration.none,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _InsetBottomProgressRail extends StatelessWidget {
  const _InsetBottomProgressRail({
    required this.progressRatio,
    required this.totalDurationSeconds,
    required this.chapters,
    required this.activeChapterIndex,
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
  final int activeChapterIndex;
  final bool hovered;
  final Color activeColor;
  final Color inactiveColor;
  final void Function(bool hovering, double? ratio) onHoverChanged;
  final ValueChanged<double> onScrubStartOrUpdate;
  final VoidCallback onScrubEnd;
  final ValueChanged<double> onScrubCommitRatio;

  @override
  Widget build(BuildContext context) {
    if (totalDurationSeconds <= 0) {
      return const SizedBox.shrink();
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth > 0 ? constraints.maxWidth : 1.0;
        double ratioAt(double dx) => (dx / width).clamp(0.0, 1.0);
        final visualHeight = hovered
            ? KonataPlaybackTokens.capsuleProgressHoverHeight
            : KonataPlaybackTokens.capsuleProgressRestHeight;

        return MouseRegion(
          cursor: SystemMouseCursors.click,
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
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: KonataPlaybackTokens.capsuleProgressBottomInset,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 140),
                    curve: Curves.easeOutCubic,
                    height: visualHeight,
                    decoration: ShapeDecoration(
                      color: inactiveColor,
                      shape: const StadiumBorder(),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: FractionallySizedBox(
                        widthFactor: progressRatio,
                        heightFactor: 1.0,
                        child: DecoratedBox(
                          decoration: ShapeDecoration(
                            color: activeColor,
                            shape: const StadiumBorder(),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                for (var i = 0; i < chapters.length; i++)
                  if (chapters[i].startSeconds > 0 &&
                      chapters[i].startSeconds < totalDurationSeconds)
                    _ChapterDiamondMarker(
                      key: ValueKey(
                        'konata_chapter_diamond_${chapters[i].index}',
                      ),
                      ratio: (chapters[i].startSeconds / totalDurationSeconds)
                          .clamp(0.0, 1.0),
                      trackWidth: width,
                      railHeight: visualHeight,
                      hovered: hovered,
                      highlighted: hovered && i == activeChapterIndex,
                      activeColor: activeColor,
                    ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _ChapterDiamondMarker extends StatelessWidget {
  const _ChapterDiamondMarker({
    super.key,
    required this.ratio,
    required this.trackWidth,
    required this.railHeight,
    required this.hovered,
    required this.highlighted,
    required this.activeColor,
  });

  final double ratio;
  final double trackWidth;
  final double railHeight;
  final bool hovered;
  final bool highlighted;
  final Color activeColor;

  @override
  Widget build(BuildContext context) {
    final size = hovered
        ? (highlighted
              ? KonataPlaybackTokens.chapterDiamondHoverSize + 1.0
              : KonataPlaybackTokens.chapterDiamondHoverSize)
        : KonataPlaybackTokens.chapterDiamondRestSize;
    final left = (ratio * trackWidth - size / 2).clamp(
      0.0,
      (trackWidth - size).clamp(0.0, trackWidth),
    );
    final bottom =
        KonataPlaybackTokens.capsuleProgressBottomInset +
        (railHeight - size) / 2;
    final fillColor = highlighted
        ? activeColor
        : Colors.white.withValues(alpha: hovered ? 0.96 : 0.88);

    return Positioned(
      left: left,
      bottom: bottom,
      child: Transform.rotate(
        angle: math.pi / 4,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOutCubic,
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: fillColor,
            borderRadius: BorderRadius.circular(1.0),
            border: Border.all(
              color: Colors.black.withValues(alpha: 0.90),
              width: KonataPlaybackTokens.chapterDiamondStrokeWidth,
            ),
            boxShadow: highlighted
                ? [
                    BoxShadow(
                      color: activeColor.withValues(alpha: 0.72),
                      blurRadius: 6,
                    ),
                  ]
                : null,
          ),
        ),
      ),
    );
  }
}
