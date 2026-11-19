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
                    duration: KonataTheme.motionFast,
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
        : (hovered
              ? KonataTheme.overlayWhiteTextPeak
              : KonataTheme.overlayWhiteTextHigh);

    return Positioned(
      left: left,
      bottom: bottom,
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
    );
  }
}
