part of 'video_side_sheet.dart';

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.pPal, this.text);

  final KonataPalette pPal;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        color: pPal.textPrimary,
        fontSize: 13.5,
        fontWeight: FontWeight.w600,
      ),
    );
  }
}

class _SeriesSeasonSwitcherBar extends StatelessWidget {
  const _SeriesSeasonSwitcherBar({
    required this.scrollController,
    required this.seriesGroup,
    required this.seriesMembers,
    required this.browsingWorkId,
    required this.playingWorkId,
    required this.onSelectSeason,
  });

  final ScrollController scrollController;
  final SeriesGroup? seriesGroup;
  final List<Work> seriesMembers;
  final String browsingWorkId;
  final String playingWorkId;
  final ValueChanged<String> onSelectSeason;

  @override
  Widget build(BuildContext context) {
    final pPal = context.palette;
    return SizedBox(
      height: 36,
      child: ListView.separated(
        controller: scrollController,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: seriesMembers.length,
        separatorBuilder: (_, _) => const SizedBox(width: 6),
        itemBuilder: (context, index) {
          final member = seriesMembers[index];
          final isBrowsing = member.id == browsingWorkId;
          final isPlaying = member.id == playingWorkId;
          final label = SeriesSeasonFormatter.formatMemberLabel(
            member,
            seriesMembers,
            seriesGroup: seriesGroup,
            fallbackOrder: index + 1,
          );
          final bg = isBrowsing
              ? pPal.primaryButtonBg
              : pPal.softFill.withValues(alpha: 0.72);
          final fg = isBrowsing ? pPal.primaryButtonFg : pPal.textPrimary;
          final border = isBrowsing ? pPal.primaryButtonBg : pPal.hairline;

          return Tooltip(
            message: label,
            waitDuration: const Duration(milliseconds: 400),
            child: Material(
              color: bg,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(KonataTheme.radiusPill),
                side: BorderSide(color: border),
              ),
              child: InkWell(
                borderRadius: BorderRadius.circular(KonataTheme.radiusPill),
                onTap: () => onSelectSeason(member.id),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 11,
                    vertical: 6,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (isPlaying) ...[
                        Icon(
                          Icons.play_arrow_rounded,
                          size: 13.5,
                          color: isBrowsing ? fg : pPal.progressFill,
                        ),
                        const SizedBox(width: 3),
                      ],
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 168),
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: fg,
                            fontSize: 12,
                            fontWeight: isBrowsing
                                ? FontWeight.w600
                                : FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _SelectableTrackTile extends StatefulWidget {
  const _SelectableTrackTile({
    required this.primaryTitle,
    required this.selected,
    required this.onTap,
    this.badgeLabel,
    this.customTrailingBadge,
    this.tooltipMessage,
    this.leadingIcon,
  });

  final String primaryTitle;
  final String? badgeLabel;
  final Widget? customTrailingBadge;
  final String? tooltipMessage;
  final IconData? leadingIcon;
  final bool selected;
  final VoidCallback? onTap;

  @override
  State<_SelectableTrackTile> createState() => _SelectableTrackTileState();
}

class _SelectableTrackTileState extends State<_SelectableTrackTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final pPal = context.palette;
    final selected = widget.selected;
    final bgColor = selected
        ? (pPal.isDark
              ? Colors.white.withValues(alpha: 0.13)
              : pPal.textPrimary.withValues(alpha: 0.08))
        : (_hovered
              ? pPal.softFill.withValues(alpha: 0.92)
              : pPal.softFill.withValues(alpha: 0.56));
    final borderColor = selected
        ? (pPal.isDark
              ? Colors.white.withValues(alpha: 0.24)
              : pPal.textPrimary.withValues(alpha: 0.20))
        : (_hovered ? pPal.hoverBorder : pPal.hairline);

    Widget content = MouseRegion(
      cursor: widget.onTap != null
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: KonataPlaybackTokens.queueRowTransitionDuration,
          constraints: BoxConstraints(
            minHeight: KonataAdaptiveTokens.isAndroid
                ? KonataAdaptiveTokens.touchTarget
                : 0,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(11),
            border: Border.all(
              color: borderColor,
              width: KonataAdaptiveTokens.borderWidth,
            ),
          ),
          child: Row(
            children: [
              if (widget.leadingIcon != null) ...[
                Icon(
                  widget.leadingIcon,
                  size: 16,
                  color: selected ? pPal.textPrimary : pPal.textMuted,
                ),
                const SizedBox(width: 9),
              ] else ...[
                Icon(
                  selected
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_unchecked_rounded,
                  size: 15,
                  color: selected
                      ? pPal.textPrimary
                      : pPal.textMuted.withValues(alpha: 0.6),
                ),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: EllipsisTextWithTooltip(
                  text: widget.primaryTitle,
                  style: TextStyle(
                    color: pPal.textPrimary,
                    fontSize: 13,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ),
              if (widget.customTrailingBadge != null) ...[
                const SizedBox(width: 8),
                widget.customTrailingBadge!,
              ] else if (widget.badgeLabel != null &&
                  widget.badgeLabel!.isNotEmpty) ...[
                const SizedBox(width: 8),
                KonataSpecBadge(
                  label: widget.badgeLabel!,
                  highlighted: selected,
                ),
              ],
            ],
          ),
        ),
      ),
    );

    if (widget.tooltipMessage != null &&
        widget.tooltipMessage!.trim().isNotEmpty) {
      content = Tooltip(
        message: widget.tooltipMessage!,
        waitDuration: const Duration(milliseconds: 350),
        child: content,
      );
    }
    return content;
  }
}

class _SpeedPillButton extends StatefulWidget {
  const _SpeedPillButton({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_SpeedPillButton> createState() => _SpeedPillButtonState();
}

class _SpeedPillButtonState extends State<_SpeedPillButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final pPal = context.palette;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minWidth: KonataAdaptiveTokens.isAndroid
                ? KonataAdaptiveTokens.touchTarget
                : 0,
            minHeight: KonataAdaptiveTokens.isAndroid
                ? KonataAdaptiveTokens.touchTarget
                : 0,
          ),
          child: AnimatedContainer(
            duration: KonataPlaybackTokens.queueRowTransitionDuration,
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: widget.selected
                  ? pPal.primaryButtonBg
                  : (_hovered ? pPal.softFill : Colors.transparent),
              borderRadius: BorderRadius.circular(KonataTheme.radiusPill),
              border: Border.all(
                color: widget.selected ? pPal.primaryButtonBg : pPal.hairline,
              ),
            ),
            child: Text(
              widget.label,
              style: TextStyle(
                color: widget.selected
                    ? pPal.primaryButtonFg
                    : pPal.textPrimary,
                fontSize: 12,
                fontWeight: widget.selected ? FontWeight.w600 : FontWeight.w400,
                fontFeatures: KonataPlaybackTokens.tabularNumbers,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DelayStepperRow extends StatelessWidget {
  const _DelayStepperRow({
    required this.pPal,
    required this.label,
    required this.delaySeconds,
    required this.onDelta,
    required this.onReset,
  });

  final KonataPalette pPal;
  final String label;
  final double delaySeconds;
  final ValueChanged<double> onDelta;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    final sign = delaySeconds > 0 ? '+' : '';
    final btnConstraints = KonataAdaptiveTokens.isAndroid
        ? const BoxConstraints(
            minWidth: KonataAdaptiveTokens.touchTarget,
            minHeight: KonataAdaptiveTokens.touchTarget,
          )
        : null;
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: pPal.textSecondary, fontSize: 12.5),
          ),
        ),
        const SizedBox(width: 8),
        IconButton(
          constraints: btnConstraints,
          visualDensity: KonataAdaptiveTokens.isAndroid
              ? VisualDensity.standard
              : VisualDensity.compact,
          tooltip: '-0.1s',
          onPressed: () => onDelta(-0.1),
          icon: const Icon(Icons.remove_circle_outline_rounded, size: 18),
        ),
        KonataPillButton.ghost(
          label: '$sign${delaySeconds.toStringAsFixed(1)}s',
          compact: true,
          onPressed: onReset,
        ),
        IconButton(
          constraints: btnConstraints,
          visualDensity: KonataAdaptiveTokens.isAndroid
              ? VisualDensity.standard
              : VisualDensity.compact,
          tooltip: '+0.1s',
          onPressed: () => onDelta(0.1),
          icon: const Icon(Icons.add_circle_outline_rounded, size: 18),
        ),
      ],
    );
  }
}

class _ChapterListLeaf extends ConsumerWidget {
  const _ChapterListLeaf({
    required this.request,
    required this.chapters,
    required this.scrollController,
    required this.onSeekChapter,
  });

  final VideoLaunchRequest request;
  final List<PlaybackChapter> chapters;
  final ScrollController scrollController;
  final ValueChanged<double> onSeekChapter;

  static int _activeChapterIdx(List<PlaybackChapter> list, double pos) {
    for (var i = list.length - 1; i >= 0; i--) {
      if (pos >= list[i].startSeconds - 0.3) return i;
    }
    return 0;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activeIdx = ref.watch(
      videoPlaybackProvider(request).select(
        (s) => _activeChapterIdx(chapters, s.positionSeconds),
      ),
    );
    return KonataDraggableScrollbar(
      controller: scrollController,
      padding: const EdgeInsets.only(right: 4),
      builder: (_, ctrl) => ListView.separated(
        controller: ctrl,
        padding: const EdgeInsets.fromLTRB(16, 0, 20, 20),
        itemCount: chapters.length,
        separatorBuilder: (_, _) => const SizedBox(height: 8),
        itemBuilder: (context, index) {
          final ch = chapters[index];
          final title = ch.title.trim().isNotEmpty
              ? ch.title.trim()
              : '章节 ${index + 1}';
          final stamp = PlaybackFormatters.formatMediaDuration(ch.startSeconds);
          return _SelectableTrackTile(
            primaryTitle: title,
            badgeLabel: stamp,
            leadingIcon: Icons.bookmark_outline_rounded,
            selected: index == activeIdx,
            onTap: () => onSeekChapter(ch.startSeconds),
          );
        },
      ),
    );
  }
}
