part of 'video_side_sheet.dart';

/// 章节清单仅在真实播放位置跨越章节边界时刷新选中态。
class _ChaptersSection extends StatefulWidget {
  const _ChaptersSection({required this.controller, required this.state});

  final VideoPlaybackController controller;
  final VideoPlaybackState state;

  @override
  State<_ChaptersSection> createState() => _ChaptersSectionState();
}

class _ChaptersSectionState extends State<_ChaptersSection> {
  late int _activeIndex;

  int _resolveActiveIndex() {
    final seconds =
        widget.controller.positionNotifier.value.inMicroseconds / 1e6;
    final chapters = widget.state.chapters;
    for (var i = chapters.length - 1; i >= 0; i--) {
      if (seconds >= chapters[i].startSeconds) return i;
    }
    return -1;
  }

  void _onPositionChanged() {
    final next = _resolveActiveIndex();
    if (next != _activeIndex) setState(() => _activeIndex = next);
  }

  @override
  void initState() {
    super.initState();
    _activeIndex = _resolveActiveIndex();
    widget.controller.positionNotifier.addListener(_onPositionChanged);
  }

  @override
  void didUpdateWidget(covariant _ChaptersSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.positionNotifier.removeListener(_onPositionChanged);
      widget.controller.positionNotifier.addListener(_onPositionChanged);
    }
    _activeIndex = _resolveActiveIndex();
  }

  @override
  void dispose() {
    widget.controller.positionNotifier.removeListener(_onPositionChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final chapters = widget.state.chapters;
    if (chapters.isEmpty) {
      return Center(
        child: Text(
          '当前视频未嵌入章节标记',
          style: KonataTheme.bodyLabelStyle(context.palette),
        ),
      );
    }
    return KonataDraggableScrollbar(
      builder: (_, scrollController) => ListView.separated(
        controller: scrollController,
        padding: EdgeInsets.zero,
        itemCount: chapters.length,
        separatorBuilder: (_, _) => const SizedBox(height: 8),
        itemBuilder: (_, index) {
          final chapter = chapters[index];
          return _TrackSelectionRow(
            key: ValueKey('video_chapter_${chapter.index}'),
            title: chapter.title.trim().isEmpty
                ? '章节 ${index + 1}'
                : chapter.title.trim(),
            badge: PlaybackFormatters.formatMediaDuration(chapter.startSeconds),
            icon: Icons.bookmark_outline_rounded,
            selected: index == _activeIndex,
            onTap: () => unawaited(widget.controller.seekToChapter(chapter)),
          );
        },
      ),
    );
  }
}

/// 章节、字幕和音轨共用单行选项，完整名称按需悬停展开。
class _TrackSelectionRow extends StatelessWidget {
  const _TrackSelectionRow({
    super.key,
    required this.title,
    required this.selected,
    required this.onTap,
    this.badge,
    this.icon,
  });

  final String title;
  final String? badge;
  final IconData? icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Semantics(
      button: true,
      selected: selected,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: KonataSurfaceCard(
            radius: KonataTheme.radiusTile,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            enableHover: true,
            backgroundColor: selected
                ? KonataPlaybackTokens.activePillBg(p)
                : null,
            borderColor: selected
                ? KonataPlaybackTokens.activeGlassBorder(p)
                : null,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: KonataAdaptiveTokens.isAndroid
                    ? KonataAdaptiveTokens.touchTarget - 20
                    : 18,
              ),
              child: Row(
                children: [
                  Icon(
                    icon ??
                        (selected
                            ? Icons.radio_button_checked_rounded
                            : Icons.radio_button_unchecked_rounded),
                    size: 16,
                    color: selected ? p.textPrimary : p.textMuted,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: EllipsisTextWithTooltip(
                      text: title,
                      style: KonataTheme.detailTextStyle(
                        palette: p,
                        color: p.textPrimary,
                        fontSize: KonataTheme.fontSizeBodySm,
                        fontWeight: selected
                            ? FontWeight.w600
                            : FontWeight.w400,
                      ),
                    ),
                  ),
                  if (badge?.isNotEmpty == true) ...[
                    const SizedBox(width: 8),
                    KonataSpecBadge(label: badge!, highlighted: selected),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 音轨与字幕的实时延迟、样式数值使用同一组步进控件。
class _PlaybackValueStepper extends StatelessWidget {
  const _PlaybackValueStepper({
    required this.label,
    required this.value,
    required this.onDecrease,
    required this.onIncrease,
    required this.onReset,
  });

  final String label;
  final String value;
  final VoidCallback onDecrease;
  final VoidCallback onIncrease;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: Text(label, style: KonataTheme.bodyLabelStyle(context.palette)),
      ),
      KonataCapsuleIconButton(
        icon: Icons.remove_circle_outline_rounded,
        tooltip: '减少$label',
        color: context.palette.textPrimary,
        onTap: onDecrease,
      ),
      KonataPillButton.ghost(label: value, compact: true, onPressed: onReset),
      KonataCapsuleIconButton(
        icon: Icons.add_circle_outline_rounded,
        tooltip: '增加$label',
        color: context.palette.textPrimary,
        onTap: onIncrease,
      ),
    ],
  );
}
