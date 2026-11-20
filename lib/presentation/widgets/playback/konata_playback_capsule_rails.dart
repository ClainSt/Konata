part of 'konata_playback_capsule.dart';

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
        color: KonataTheme.scrimBlackStrong,
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
            borderRadius: KonataTheme.borderRadiusPill,
            child: BackdropFilter(
              filter: KonataTheme.blurFilterControl,
              child: Container(
                constraints: BoxConstraints(maxWidth: maxWidth),
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: bgColor,
                  borderRadius: KonataTheme.borderRadiusPill,
                  border: Border.all(color: borderColor, width: 1),
                ),
                child: Text(
                  pillText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: primaryFg,
                    fontSize: KonataTheme.fontSizeCaptionSm,
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
          borderRadius: KonataTheme.borderRadiusPanel,
          child: BackdropFilter(
            filter: KonataTheme.blurFilterMedium,
            child: Container(
              constraints: BoxConstraints(maxWidth: maxWidth),
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: bgColor,
                borderRadius: KonataTheme.borderRadiusPanel,
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
                                fontSize: KonataTheme.fontSizeCaptionXs,
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
                            fontSize: KonataTheme.fontSizeCaptionSm,
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

class _InsetTopProgressRail extends StatelessWidget {
  const _InsetTopProgressRail({
    required this.progressRatio,
    required this.totalDurationSeconds,
    required this.chapters,
    required this.activeChapterIndex,
    required this.hovered,
    required this.isDark,
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
  final bool isDark;
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
        final thumbSize = visualHeight + 3.0;
        final thumbLeft = (progressRatio * width - thumbSize / 2).clamp(
          0.0,
          (width - thumbSize).clamp(0.0, width),
        );
        final thumbCenterX = thumbLeft + thumbSize / 2;

        final markerSizeForBounds = hovered
            ? KonataPlaybackTokens.chapterDiamondHoverSize
            : KonataPlaybackTokens.chapterDiamondRestSize;
        final halfDiagBound = markerSizeForBounds * math.sqrt2 * 0.5;
        final minMarkerCenter = math.min(halfDiagBound, width * 0.5);
        final maxMarkerCenter = math.max(
          minMarkerCenter,
          width - halfDiagBound,
        );
        double markerCenterXFor(int chapterIdx) {
          final ratio = (chapters[chapterIdx].startSeconds / totalDurationSeconds)
              .clamp(0.0, 1.0);
          return (ratio * width).clamp(minMarkerCenter, maxMarkerCenter);
        }

        // 碰撞稀疏筛选：优先保留当前高亮章节，跳过间距不足阈值的紧邻重叠章节点，避免挤成一团干扰点击进度条。
        final candidateIndices = <int>[];
        for (var i = 0; i < chapters.length; i++) {
          final start = chapters[i].startSeconds;
          if (start > 0 && start < totalDurationSeconds) {
            candidateIndices.add(i);
          }
        }
        final acceptedCenters = <double>[];
        final visibleIndices = <int>[];
        if (hovered &&
            activeChapterIndex >= 0 &&
            candidateIndices.contains(activeChapterIndex)) {
          visibleIndices.add(activeChapterIndex);
          acceptedCenters.add(markerCenterXFor(activeChapterIndex));
        }
        for (final idx in candidateIndices) {
          if (visibleIndices.contains(idx)) continue;
          final cx = markerCenterXFor(idx);
          var overlapsExisting = false;
          for (final existingCx in acceptedCenters) {
            if ((cx - existingCx).abs() <
                KonataPlaybackTokens.chapterDiamondMinSpacingPx) {
              overlapsExisting = true;
              break;
            }
          }
          if (!overlapsExisting) {
            visibleIndices.add(idx);
            acceptedCenters.add(cx);
          }
        }
        visibleIndices.sort((a, b) {
          if (hovered && a == activeChapterIndex) return 1;
          if (hovered && b == activeChapterIndex) return -1;
          return a.compareTo(b);
        });

        var thumbOverlapsMarker = false;
        if (hovered) {
          for (final cx in acceptedCenters) {
            if ((cx - thumbCenterX).abs() < thumbSize * 0.72) {
              thumbOverlapsMarker = true;
              break;
            }
          }
        }

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
                  top: KonataPlaybackTokens.capsuleProgressTopInset,
                  child: AnimatedContainer(
                    duration: KonataTheme.motionFast,
                    curve: Curves.easeOutCubic,
                    height: visualHeight,
                    decoration: BoxDecoration(
                      color: inactiveColor,
                      borderRadius: BorderRadius.vertical(
                        bottom: Radius.circular(visualHeight),
                      ),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: FractionallySizedBox(
                        widthFactor: progressRatio,
                        heightFactor: 1.0,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: activeColor,
                            borderRadius: BorderRadius.only(
                              bottomLeft: Radius.circular(visualHeight),
                              bottomRight: Radius.circular(visualHeight),
                              topRight: Radius.circular(visualHeight * 0.5),
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: activeColor.withValues(
                                  alpha: isDark ? 0.56 : 0.22,
                                ),
                                blurRadius: hovered ? 8 : 5,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                // 进度圆点置于章节点下方，且与章节点重合时自动退让，彻底防止开头章节点被圆点遮挡。
                if (hovered && !thumbOverlapsMarker)
                  Positioned(
                    left: thumbLeft,
                    top: math.max(
                      0.5,
                      KonataPlaybackTokens.capsuleProgressTopInset +
                          (visualHeight - thumbSize) / 2,
                    ),
                    child: IgnorePointer(
                      child: Container(
                        width: thumbSize,
                        height: thumbSize,
                        decoration: BoxDecoration(
                          color: activeColor,
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: activeColor.withValues(
                                alpha: isDark ? 0.72 : 0.30,
                              ),
                              blurRadius: 7,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                for (final i in visibleIndices)
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

/// 播控胶囊外轮廓描边画笔：有活跃顶沿进度条时让出顶边直轨段，使进度条直接融为胶囊顶沿边缘，消除上方白线。
class _PlaybackCapsuleBorderPainter extends CustomPainter {
  const _PlaybackCapsuleBorderPainter({
    required this.borderColor,
    required this.omitTopRailSpan,
    required this.railHorizontalInset,
  });

  final Color borderColor;
  final bool omitTopRailSpan;
  final double railHorizontalInset;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    const strokeWidth = 1.0;
    const half = strokeWidth * 0.5;
    final r = (size.height - strokeWidth) * 0.5;
    if (r <= 0) return;

    final paint = Paint()
      ..color = borderColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..isAntiAlias = true;

    if (!omitTopRailSpan || size.width <= railHorizontalInset * 2 + 2) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            half,
            half,
            size.width - strokeWidth,
            size.height - strokeWidth,
          ),
          Radius.circular(r),
        ),
        paint,
      );
      return;
    }

    final rightArcRect = Rect.fromLTWH(
      size.width - half - r * 2,
      half,
      r * 2,
      r * 2,
    );
    final leftArcRect = Rect.fromLTWH(half, half, r * 2, r * 2);

    // 仅描边右半圆 + 底边 + 左半圆，顶边由贴边进度滑轨无缝承接。
    final path = Path()
      ..moveTo(size.width - half - r, half)
      ..arcTo(rightArcRect, -math.pi / 2, math.pi, false)
      ..lineTo(half + r, size.height - half)
      ..arcTo(leftArcRect, math.pi / 2, math.pi, false);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _PlaybackCapsuleBorderPainter oldDelegate) {
    return oldDelegate.borderColor != borderColor ||
        oldDelegate.omitTopRailSpan != omitTopRailSpan ||
        oldDelegate.railHorizontalInset != railHorizontalInset;
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
              ? KonataPlaybackTokens.chapterDiamondHoverSize +
                    KonataPlaybackTokens.chapterDiamondHighlightSizeDelta
              : KonataPlaybackTokens.chapterDiamondHoverSize)
        : KonataPlaybackTokens.chapterDiamondRestSize;
    final diagOverflow = size * (math.sqrt2 - 1.0) * 0.5;
    final minLeft = diagOverflow;
    final maxLeft = (trackWidth - size - diagOverflow).clamp(
      minLeft,
      trackWidth,
    );
    final left = (ratio * trackWidth - size / 2).clamp(minLeft, maxLeft);
    final idealTop =
        KonataPlaybackTokens.capsuleProgressTopInset +
        (railHeight - size) / 2;
    final top = math.max(idealTop, diagOverflow + 1.0);
    final fillColor = highlighted
        ? activeColor
        : (hovered
              ? KonataTheme.overlayWhiteTextPeak
              : KonataTheme.overlayWhiteTextHigh);

    return Positioned(
      left: left,
      top: top,
      child: IgnorePointer(
        child: Transform.rotate(
          angle: math.pi / 4,
          child: AnimatedContainer(
            duration: KonataTheme.motionFast,
            curve: Curves.easeOutCubic,
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: fillColor,
              borderRadius: KonataTheme.borderRadiusHairline,
              border: Border.all(
                color: KonataTheme.scrimBlackOpaque,
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
      ),
    );
  }
}
