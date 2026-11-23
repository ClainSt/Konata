part of 'playback_history_cards.dart';

/// 展开明细中的单集/单曲子卡（视频展示 16:9 剧照，音频展示 1:1 专辑封面，深浅模式严格复用 `p.surface` 光学玻璃层）。
class _HistoryExpandedEntryRow extends StatefulWidget {
  const _HistoryExpandedEntryRow({
    required this.record,
    required this.episode,
    required this.workItem,
    required this.imageLoader,
    required this.isAudio,
    required this.inSelection,
    required this.selected,
    required this.isDeleteMode,
    required this.audioDirLabel,
    required this.onTap,
    required this.onShowMenu,
  });

  final PlaybackRecord record;
  final Episode? episode;
  final WorkLibraryItem? workItem;
  final ManagedImageLoader imageLoader;
  final bool isAudio;
  final bool inSelection;
  final bool selected;
  final bool isDeleteMode;
  final String? audioDirLabel;
  final VoidCallback onTap;
  final HistoryRowMenuCallback onShowMenu;

  @override
  State<_HistoryExpandedEntryRow> createState() =>
      _HistoryExpandedEntryRowState();
}

class _HistoryExpandedEntryRowState extends State<_HistoryExpandedEntryRow> {
  bool _hovered = false;

  Widget _mediaPlaceholder(KonataPalette p) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: p.softFill,
        border: Border.all(color: p.hairline, width: 1),
      ),
      child: Center(
        child: Icon(
          widget.isAudio
              ? Icons.album_outlined
              : Icons.play_circle_outline_rounded,
          size: 22,
          color: p.textMuted,
        ),
      ),
    );
  }

  Widget _buildVideoStill(KonataPalette p, double width, double height) {
    final work = widget.workItem?.work;
    final still = widget.episode?.stillPath?.trim();
    final backdrop = work?.backdropPath?.trim();
    final poster =
        work?.posterPath?.trim() ??
        work?.bangumiPosterPath?.trim() ??
        work?.posterFallback?.trim();

    String? source;
    ManagedArtwork artwork = ManagedArtwork.still;
    if (still != null && still.isNotEmpty) {
      source = still;
      artwork = ManagedArtwork.still;
    } else if (backdrop != null && backdrop.isNotEmpty) {
      source = backdrop;
      artwork = ManagedArtwork.backdrop;
    } else if (poster != null && poster.isNotEmpty) {
      source = poster;
      artwork = ManagedArtwork.poster;
    }

    return ClipRRect(
      borderRadius: KonataTheme.borderRadiusChip,
      child: SizedBox(
        key: ValueKey('history_video_still_${widget.record.id}'),
        width: width,
        height: height,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (source != null)
              SmartManagedImageAlignmentBuilder(
                url: source,
                loader: widget.imageLoader,
                owner: work?.id ?? widget.record.workId,
                artwork: artwork,
                targetAspectRatio: 16 / 9,
                enabled: artwork == ManagedArtwork.poster,
                builder: (_, alignment) => ManagedImage(
                  source!,
                  loader: widget.imageLoader,
                  owner: work?.id ?? widget.record.workId,
                  artwork: artwork,
                  decodeWidth: 280,
                  fit: BoxFit.cover,
                  alignment: alignment,
                  errorBuilder: (_, _, _) => _mediaPlaceholder(p),
                ),
              )
            else
              _mediaPlaceholder(p),
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: KonataTheme.borderRadiusChip,
                    border: Border.all(color: p.posterBorder, width: 1),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _resolveEntryTitle() {
    final work = widget.workItem?.work;
    if (!widget.isAudio && widget.episode != null) {
      return EpisodeTitleFormatter.formatCardTitle(
        episode: widget.episode!,
        workMediaType: work?.tmdbMediaType,
        workTitle: work?.title,
        mainEpisodeCount: widget.workItem?.episodeCount,
      );
    }
    return EpisodeTitleFormatter.formatHistorySubtitle(
      record: widget.record,
      work: work,
      mainEpisodeCount: widget.workItem?.episodeCount,
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final record = widget.record;
    final compact =
        MediaQuery.sizeOf(context).width <
        KonataAdaptiveTokens.tabletBreakpoint;
    final mediaWidth = widget.isAudio
        ? (compact
              ? PlaybackHistoryCardMetrics.compactAudioAlbumCoverSize
              : PlaybackHistoryCardMetrics.audioAlbumCoverSize)
        : (compact
              ? PlaybackHistoryCardMetrics.compactEpisodeStillWidth
              : PlaybackHistoryCardMetrics.episodeStillWidth);
    final mediaHeight = widget.isAudio
        ? mediaWidth
        : (compact
              ? PlaybackHistoryCardMetrics.compactEpisodeStillHeight
              : PlaybackHistoryCardMetrics.episodeStillHeight);

    final work = widget.workItem?.work;
    final fallbackPoster =
        work?.posterPath ?? work?.bangumiPosterPath ?? work?.posterFallback;
    final entryTitle = _resolveEntryTitle();
    final progressLabel = PlaybackHistoryCardMetrics.formatProgressLabel(
      record,
      isAudio: widget.isAudio,
      includeVerb: false,
    );
    final clockText = PlaybackHistoryTimelineBuilder.formatClockHm(
      record.playedAt,
    );
    final selectedAccent = widget.isDeleteMode ? p.danger : p.accent;
    final trimmedDir = widget.audioDirLabel?.trim() ?? '';
    final isInteractiveHover = _hovered && !KonataAdaptiveTokens.isAndroid;
    final cardBg = widget.selected
        ? selectedAccent.withValues(alpha: p.isDark ? 0.16 : 0.10)
        : (isInteractiveHover ? p.surfaceHover : p.surface);
    final cardBorder = widget.selected
        ? selectedAccent.withValues(alpha: 0.72)
        : (p.isDark
              ? (isInteractiveHover ? p.hoverBorder : p.hairline)
              : (isInteractiveHover
                    ? KonataTheme.subtleControlBorder(p)
                    : KonataTheme.subtleOutlineBorder(p)));

    final mediaBox = widget.isAudio
        ? ClipRRect(
            borderRadius: KonataTheme.borderRadiusChip,
            child: SizedBox(
              key: ValueKey('history_audio_cover_${record.id}'),
              width: mediaWidth,
              height: mediaHeight,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _AudioHistoryCover(
                    workId: record.workId,
                    variantId: record.variantId,
                    fallbackPoster: fallbackPoster,
                    imageLoader: widget.imageLoader,
                    size: mediaHeight,
                  ),
                  Positioned.fill(
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: KonataTheme.borderRadiusChip,
                          border: Border.all(color: p.posterBorder, width: 1),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          )
        : _buildVideoStill(p, mediaWidth, mediaHeight);

    return GestureDetector(
      key: ValueKey('history_entry_${record.id}'),
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap,
      onSecondaryTapUp: widget.inSelection
          ? null
          : (details) => widget.onShowMenu(
              details.globalPosition,
              record,
              widget.isAudio,
            ),
      onLongPressStart: widget.inSelection
          ? null
          : (details) => widget.onShowMenu(
              details.globalPosition,
              record,
              widget.isAudio,
            ),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: KonataAdaptiveTokens.isAndroid
            ? null
            : (_) => setState(() => _hovered = true),
        onExit: KonataAdaptiveTokens.isAndroid
            ? null
            : (_) => setState(() => _hovered = false),
        child: Container(
          key: ValueKey('history_entry_surface_${record.id}'),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: cardBg,
            borderRadius: KonataTheme.borderRadiusSm,
            border: Border.all(color: cardBorder, width: 1),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              mediaBox,
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        EllipsisTextWithTooltip(
                          text: entryTitle,
                          maxLines:
                              widget.isAudio && trimmedDir.isNotEmpty ? 1 : 2,
                          style: TextStyle(
                            color: p.textPrimary,
                            fontSize: compact ? 13.0 : 13.6,
                            fontWeight: FontWeight.w600,
                            height: 1.22,
                          ),
                        ),
                        if (widget.isAudio && trimmedDir.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          EllipsisTextWithTooltip(
                            text: trimmedDir,
                            maxLines: 1,
                            style: TextStyle(
                              color: p.textMuted,
                              fontSize: 11.4,
                              height: 1.15,
                            ),
                          ),
                        ],
                      ],
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          height: PlaybackHistoryCardMetrics.progressBarHeight,
                          child: ClipRRect(
                            borderRadius: KonataTheme.borderRadiusPill,
                            child: LinearProgressIndicator(
                              value: record.isCompleted
                                  ? 1.0
                                  : record.progressRatio,
                              backgroundColor: p.progressTrack,
                              valueColor: AlwaysStoppedAnimation(
                                record.isCompleted
                                    ? p.success
                                    : p.progressFill,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Row(
                          key: ValueKey('history_progress_row_${record.id}'),
                          children: [
                            Expanded(
                              child: Text(
                                progressLabel,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: KonataTheme.textStyle(
                                  color: record.isCompleted
                                      ? p.success
                                      : p.progressFill,
                                  fontSize: compact ? 11.2 : 11.8,
                                  weight: 600,
                                  height: 1.0,
                                  tabularFigures: true,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              clockText,
                              style: KonataTheme.textStyle(
                                color: p.textMuted,
                                fontSize: compact ? 11.0 : 11.5,
                                weight: 500,
                                height: 1.0,
                                tabularFigures: true,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              if (widget.inSelection)
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: Icon(
                    widget.selected
                        ? Icons.check_circle_rounded
                        : Icons.radio_button_unchecked_rounded,
                    size: 18,
                    color: widget.selected ? selectedAccent : p.textMuted,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 展开态音频子行的 1:1 专辑封面加载器（优先取音频内嵌/同目录专辑封面，缺省平滑回退作品海报或光盘占位）。
class _AudioHistoryCover extends ConsumerWidget {
  const _AudioHistoryCover({
    required this.workId,
    required this.variantId,
    required this.fallbackPoster,
    required this.imageLoader,
    required this.size,
  });

  final String workId;
  final String variantId;
  final String? fallbackPoster;
  final ManagedImageLoader imageLoader;
  final double size;

  Widget _buildFallback(KonataPalette p) {
    if (fallbackPoster != null && fallbackPoster!.isNotEmpty) {
      return ManagedImage(
        fallbackPoster!,
        loader: imageLoader,
        owner: workId,
        artwork: ManagedArtwork.poster,
        decodeWidth: 200,
        fit: BoxFit.cover,
        alignment: SmartCoverFraming.defaultPosterAlignment,
        errorBuilder: (_, _, _) => _buildIconPlaceholder(p),
      );
    }
    return _buildIconPlaceholder(p);
  }

  Widget _buildIconPlaceholder(KonataPalette p) {
    return SizedBox(
      width: size,
      height: size,
      child: const KonataCdDiscPlaceholder(discScale: 0.80),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.palette;
    final albumBytesAsync = ref.watch(
      audioRecordAlbumCoverProvider((workId: workId, variantId: variantId)),
    );
    final bytes = albumBytesAsync.value;
    if (bytes != null && bytes.isNotEmpty) {
      return Image.memory(
        bytes,
        width: size,
        height: size,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        filterQuality: FilterQuality.medium,
        errorBuilder: (_, _, _) => _buildFallback(p),
      );
    }
    return _buildFallback(p);
  }
}
