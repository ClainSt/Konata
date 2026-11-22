import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../application/providers/artwork_provider.dart';
import '../../application/providers/library_providers.dart';
import '../../domain/matching/episode_title_formatter.dart';
import '../../domain/models/episode.dart';
import '../../domain/models/playback_record.dart';
import '../../domain/playback/playback_history_timeline.dart';
import '../audio/smart_cover_framing.dart';
import '../theme/konata_adaptive_tokens.dart';
import '../theme/konata_palette.dart';
import '../theme/konata_theme.dart';
import '../widgets/design_system/ellipsis_text_with_tooltip.dart';
import '../widgets/design_system/konata_surface_card.dart';
import '../widgets/managed_image.dart';
import '../widgets/playback/konata_cd_disc_placeholder.dart';

/// 单条播放记录的上下文菜单回调。
typedef HistoryRowMenuCallback =
    void Function(Offset globalPosition, PlaybackRecord record, bool isAudio);

/// 单日作品分组的上下文菜单回调。
typedef HistoryGroupMenuCallback =
    void Function(
      Offset globalPosition,
      PlaybackHistoryWorkGroup group,
      bool isAudio,
    );

/// 播放记录时间轴与展开明细卡片的统一几何常量。
abstract final class PlaybackHistoryCardMetrics {
  /// 时间轴宽屏最大内容宽度（防止桌面超宽屏列表过度拉伸）。
  static const double maxTimelineWidth = 960.0;

  /// 展开明细区切为双列排布的容器宽度阈值。
  static const double expandedTwoColumnBreakpoint = 640.0;

  /// 左侧时间轴轨宽（容纳圆点与垂直连线）。
  static const double timelineRailWidth = 22.0;

  /// 左侧时间轴圆点直径。
  static const double timelineDotSize = 9.0;

  /// 左侧时间轴竖线宽度。
  static const double timelineLineWidth = 1.5;

  /// 桌面与平板收起态作品海报宽度。
  static const double workCoverWidth = 60.0;

  /// 桌面与平板收起态作品海报高度（2:3）。
  static const double workCoverHeight = 88.0;

  /// 手机紧凑态作品海报宽度。
  static const double compactWorkCoverWidth = 52.0;

  /// 手机紧凑态作品海报高度（2:3）。
  static const double compactWorkCoverHeight = 76.0;

  /// 展开区视频 16:9 单集剧照宽度（宽屏）。
  static const double episodeStillWidth = 124.0;

  /// 展开区视频 16:9 单集剧照高度（宽屏）。
  static const double episodeStillHeight = 70.0;

  /// 展开区视频 16:9 单集剧照宽度（手机窄屏）。
  static const double compactEpisodeStillWidth = 104.0;

  /// 展开区视频 16:9 单集剧照高度（手机窄屏）。
  static const double compactEpisodeStillHeight = 58.0;

  /// 展开区音频 1:1 专辑封面边长（宽屏）。
  static const double audioAlbumCoverSize = 64.0;

  /// 展开区音频 1:1 专辑封面边长（手机窄屏）。
  static const double compactAudioAlbumCoverSize = 56.0;

  /// 展开明细进度条高度。
  static const double progressBarHeight = 3.2;

  /// 展开动画时长（复用全站标准 220ms 切换时长 Token）。
  static const Duration expandAnimationDuration =
      KonataTheme.tabSwitchDuration;

  /// 生成时间进度文案；[includeVerb] 为 `false` 时不带「观看至/收听至」前缀。
  static String formatProgressLabel(
    PlaybackRecord rec, {
    required bool isAudio,
    required bool includeVerb,
  }) {
    if (rec.isCompleted) return isAudio ? '已听完' : '已看完';
    final prefix = includeVerb ? '${isAudio ? '收听至' : '观看至'} ' : '';
    if (rec.positionSeconds > 0 && rec.durationSeconds > 0) {
      return '$prefix${PlaybackRecord.formatClock(rec.positionSeconds)} / '
          '${PlaybackRecord.formatClock(rec.durationSeconds)}';
    }
    if (rec.positionSeconds > 0) {
      return '$prefix${PlaybackRecord.formatClock(rec.positionSeconds)}';
    }
    return '刚刚打开';
  }
}

/// 时间轴单日节点头（左侧小圆点 + 右侧 `YYYY.MM.DD` 日期）。
class PlaybackHistoryDayHeader extends StatelessWidget {
  /// 创建日期节点头。
  const PlaybackHistoryDayHeader({
    super.key,
    required this.section,
    required this.showTopConnector,
  });

  /// 单日分组模型。
  final PlaybackHistoryDaySection section;

  /// 是否绘制上方延伸下来的时间轴连线（非首日时为 `true`）。
  final bool showTopConnector;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    const railW = PlaybackHistoryCardMetrics.timelineRailWidth;
    const dotSize = PlaybackHistoryCardMetrics.timelineDotSize;
    const lineW = PlaybackHistoryCardMetrics.timelineLineWidth;
    final lineLeft = (railW - lineW) / 2;

    return SizedBox(
      height: 30,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: railW,
            height: 30,
            child: Stack(
              alignment: Alignment.center,
              children: [
                if (showTopConnector)
                  Positioned(
                    left: lineLeft,
                    top: 0,
                    bottom: 15,
                    child: ColoredBox(
                      color: p.hairline,
                      child: const SizedBox(width: lineW),
                    ),
                  ),
                Positioned(
                  left: lineLeft,
                  top: 15,
                  bottom: 0,
                  child: ColoredBox(
                    color: p.hairline,
                    child: const SizedBox(width: lineW),
                  ),
                ),
                Container(
                  key: ValueKey('history_day_dot_${section.dateKey}'),
                  width: dotSize,
                  height: dotSize,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: p.accent,
                    boxShadow: [
                      BoxShadow(
                        color: p.accent.withValues(alpha: 0.28),
                        blurRadius: 0,
                        spreadRadius: 2.5,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Text(
            section.dateLabel,
            key: ValueKey('history_day_header_${section.dateKey}'),
            style: KonataTheme.textStyle(
              color: p.textSecondary,
              fontSize: KonataTheme.fontSizeBodyMd,
              weight: 600,
              height: 1.0,
              tabularFigures: true,
            ),
          ),
        ],
      ),
    );
  }
}

/// 日记时间轴中的单日作品聚合卡片（点击封面进详情，点击卡片原地展开当日分集/曲目）。
class PlaybackHistoryWorkGroupCard extends StatelessWidget {
  /// 创建单日作品聚合卡片。
  const PlaybackHistoryWorkGroupCard({
    super.key,
    required this.group,
    required this.workItem,
    required this.imageLoader,
    required this.isAudio,
    required this.isExpanded,
    required this.isLastInDay,
    required this.isLastSection,
    required this.inSelection,
    required this.selectedIds,
    required this.isDeleteMode,
    required this.audioDirLabelResolver,
    required this.onTapCover,
    required this.onTapCardBody,
    required this.onTapEntry,
    required this.onShowGroupMenu,
    required this.onShowEntryMenu,
  });

  /// 单日内按作品聚合的数据分组。
  final PlaybackHistoryWorkGroup group;

  /// 关联作品媒体库聚合项。
  final WorkLibraryItem? workItem;

  /// 统一图片加载器。
  final ManagedImageLoader imageLoader;

  /// 是否处于音频分类页签。
  final bool isAudio;

  /// 当前作品卡片是否处于展开态。
  final bool isExpanded;

  /// 是否为该日期下最后一张作品卡。
  final bool isLastInDay;

  /// 是否为整个时间轴最后一个日期分组。
  final bool isLastSection;

  /// 是否处于批量选择态。
  final bool inSelection;

  /// 当前已勾选的记录 ID 集合。
  final Set<String> selectedIds;

  /// 批量模式是否为删除模式。
  final bool isDeleteMode;

  /// 解析音频记录对应 CD 专辑子目录名。
  final String? Function(PlaybackRecord rec) audioDirLabelResolver;

  /// 点击作品封面回调（正常态进入作品详情页，保留滚动位置）。
  final VoidCallback onTapCover;

  /// 点击卡片非封面区域回调（正常态展开/收起，批量态切换整组选中）。
  final VoidCallback onTapCardBody;

  /// 点击展开后的单集/单曲行回调（正常态直接续播，批量态切换单条选中）。
  final ValueChanged<PlaybackRecord> onTapEntry;

  /// 作品卡片右键/长按/更多菜单回调。
  final HistoryGroupMenuCallback onShowGroupMenu;

  /// 展开子行右键/长按/更多菜单回调。
  final HistoryRowMenuCallback onShowEntryMenu;

  Widget _posterFallback(KonataPalette p) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: p.softFill,
        border: Border.all(color: p.hairline, width: 1),
      ),
      child: Center(
        child: Icon(
          isAudio ? Icons.album_outlined : Icons.movie_outlined,
          size: 24,
          color: p.textMuted,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final mqSize = MediaQuery.sizeOf(context);
    final isCompact = mqSize.width < KonataAdaptiveTokens.tabletBreakpoint;
    final coverWidth = isCompact
        ? PlaybackHistoryCardMetrics.compactWorkCoverWidth
        : PlaybackHistoryCardMetrics.workCoverWidth;
    final coverHeight = isCompact
        ? PlaybackHistoryCardMetrics.compactWorkCoverHeight
        : PlaybackHistoryCardMetrics.workCoverHeight;

    final work = workItem?.work;
    final latest = group.latestRecord;
    final poster =
        work?.posterPath ?? work?.bangumiPosterPath ?? work?.posterFallback;
    final summaryText = PlaybackHistoryTimelineBuilder.formatCollapsedSummary(
      latestRecord: latest,
      entryCount: group.entryCount,
      isAudio: isAudio,
      work: work,
      mainEpisodeCount: workItem?.episodeCount,
    );

    final selectedCount = group.records
        .where((r) => selectedIds.contains(r.id))
        .length;
    final allSelected = selectedCount == group.entryCount;
    final partialSelected = selectedCount > 0 && !allSelected;
    final selectedAccent = isDeleteMode ? p.danger : p.accent;
    final disableAnimations = MediaQuery.disableAnimationsOf(context);
    const railW = PlaybackHistoryCardMetrics.timelineRailWidth;
    const lineW = PlaybackHistoryCardMetrics.timelineLineWidth;
    final lineLeft = (railW - lineW) / 2;
    final showBottomRail = !(isLastInDay && isLastSection);

    final coverWidget = GestureDetector(
      key: ValueKey('history_work_cover_${group.groupKey}'),
      behavior: HitTestBehavior.opaque,
      onTap: onTapCover,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Tooltip(
          message: inSelection ? '选择该作品当天记录' : '查看作品详情',
          waitDuration: KonataTheme.tooltipSlowWaitDuration,
          child: ClipRRect(
            borderRadius: KonataTheme.borderRadiusBadge,
            child: SizedBox(
              width: coverWidth,
              height: coverHeight,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (poster != null && poster.isNotEmpty)
                    ManagedImage(
                      poster,
                      loader: imageLoader,
                      owner: work?.id ?? group.workId,
                      artwork: ManagedArtwork.poster,
                      decodeWidth: 180,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => _posterFallback(p),
                    )
                  else
                    _posterFallback(p),
                  Positioned.fill(
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: KonataTheme.borderRadiusBadge,
                          border: Border.all(color: p.posterBorder, width: 1),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    Widget? trailingWidget;
    if (inSelection) {
      trailingWidget = Padding(
        padding: const EdgeInsets.only(left: 8),
        child: Icon(
          allSelected
              ? Icons.check_circle_rounded
              : (partialSelected
                    ? Icons.remove_circle_outline_rounded
                    : Icons.radio_button_unchecked_rounded),
          size: 20,
          color: (allSelected || partialSelected)
              ? selectedAccent
              : p.textMuted,
        ),
      );
    } else if (KonataAdaptiveTokens.isAndroid) {
      trailingWidget = Builder(
        builder: (btnContext) => GestureDetector(
          key: ValueKey('history_more_${latest.id}'),
          behavior: HitTestBehavior.opaque,
          onTap: () {
            final box = btnContext.findRenderObject() as RenderBox?;
            final anchor = box != null
                ? box.localToGlobal(const Offset(24, 24))
                : Offset.zero;
            onShowGroupMenu(anchor, group, isAudio);
          },
          child: SizedBox.square(
            dimension: KonataAdaptiveTokens.touchTarget,
            child: Center(
              child: Icon(
                Icons.more_horiz_rounded,
                size: 20,
                color: p.textSecondary,
              ),
            ),
          ),
        ),
      );
    }

    final headerRow = GestureDetector(
      key: ValueKey('history_work_card_${group.groupKey}'),
      behavior: HitTestBehavior.opaque,
      onTap: onTapCardBody,
      onSecondaryTapUp: inSelection
          ? null
          : (details) =>
                onShowGroupMenu(details.globalPosition, group, isAudio),
      onLongPressStart: inSelection
          ? null
          : (details) =>
                onShowGroupMenu(details.globalPosition, group, isAudio),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            isCompact ? 10 : 12,
            isCompact ? 9 : 10,
            trailingWidget != null && KonataAdaptiveTokens.isAndroid && !inSelection
                ? 2
                : (isCompact ? 10 : 14),
            isCompact ? 9 : 10,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              coverWidget,
              SizedBox(width: isCompact ? 12 : 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      work?.title ?? '未知作品',
                      key: ValueKey('history_work_title_${group.groupKey}'),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: p.textPrimary,
                        fontSize: isCompact ? 14.8 : 16.0,
                        fontWeight: FontWeight.w700,
                        height: 1.24,
                      ),
                    ),
                    const SizedBox(height: 6),
                    EllipsisTextWithTooltip(
                      text: summaryText,
                      maxLines: 1,
                      style: KonataTheme.textStyle(
                        color: p.textSecondary,
                        fontSize: isCompact ? 12.6 : 13.4,
                        weight: 500,
                        height: 1.2,
                        tabularFigures: true,
                      ),
                    ),
                  ],
                ),
              ),
              ?trailingWidget,
            ],
          ),
        ),
      ),
    );

    final cardContent = KonataSurfaceCard(
      padding: EdgeInsets.zero,
      enableHover: !allSelected && !isExpanded,
      backgroundColor: allSelected
          ? selectedAccent.withValues(alpha: p.isDark ? 0.14 : 0.08)
          : null,
      borderColor: allSelected
          ? selectedAccent.withValues(alpha: 0.72)
          : (isExpanded ? p.accent.withValues(alpha: 0.34) : null),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          headerRow,
          AnimatedSize(
            duration: disableAnimations
                ? Duration.zero
                : PlaybackHistoryCardMetrics.expandAnimationDuration,
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: isExpanded
                ? _ExpandedHistoryWorkEntries(
                    group: group,
                    workItem: workItem,
                    imageLoader: imageLoader,
                    isAudio: isAudio,
                    inSelection: inSelection,
                    selectedIds: selectedIds,
                    isDeleteMode: isDeleteMode,
                    audioDirLabelResolver: audioDirLabelResolver,
                    onTapEntry: onTapEntry,
                    onShowEntryMenu: onShowEntryMenu,
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );

    return Stack(
      children: [
        Positioned(
          left: lineLeft,
          top: 0,
          bottom: showBottomRail ? 0 : null,
          height: showBottomRail ? null : 24,
          child: ColoredBox(
            color: p.hairline,
            child: const SizedBox(width: lineW),
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(
            railW + 10,
            0,
            0,
            isLastInDay ? 14 : 10,
          ),
          child: cardContent,
        ),
      ],
    );
  }
}

/// 展开态下的单日明细区（懒加载对应作品的单集剧照，音频复用专辑封面提取器）。
class _ExpandedHistoryWorkEntries extends ConsumerWidget {
  const _ExpandedHistoryWorkEntries({
    required this.group,
    required this.workItem,
    required this.imageLoader,
    required this.isAudio,
    required this.inSelection,
    required this.selectedIds,
    required this.isDeleteMode,
    required this.audioDirLabelResolver,
    required this.onTapEntry,
    required this.onShowEntryMenu,
  });

  final PlaybackHistoryWorkGroup group;
  final WorkLibraryItem? workItem;
  final ManagedImageLoader imageLoader;
  final bool isAudio;
  final bool inSelection;
  final Set<String> selectedIds;
  final bool isDeleteMode;
  final String? Function(PlaybackRecord rec) audioDirLabelResolver;
  final ValueChanged<PlaybackRecord> onTapEntry;
  final HistoryRowMenuCallback onShowEntryMenu;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.palette;
    final bundle = isAudio
        ? null
        : ref.watch(workDetailBundleProvider(group.workId)).value;
    final episodesById = <String, Episode>{
      if (bundle != null)
        for (final ep in bundle.episodes) ep.id: ep,
    };

    return Container(
      key: ValueKey('history_expanded_${group.groupKey}'),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: p.hairline, width: 1)),
        color: p.softFill,
      ),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final useTwoColumns =
              group.records.length >= 2 &&
              constraints.maxWidth >=
                  PlaybackHistoryCardMetrics.expandedTwoColumnBreakpoint;
          if (!useTwoColumns) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < group.records.length; i++) ...[
                  if (i > 0) const SizedBox(height: 8),
                  _HistoryExpandedEntryRow(
                    record: group.records[i],
                    episode: episodesById[group.records[i].episodeId],
                    workItem: workItem,
                    imageLoader: imageLoader,
                    isAudio: isAudio,
                    inSelection: inSelection,
                    selected: selectedIds.contains(group.records[i].id),
                    isDeleteMode: isDeleteMode,
                    audioDirLabel: isAudio
                        ? audioDirLabelResolver(group.records[i])
                        : null,
                    onTap: () => onTapEntry(group.records[i]),
                    onShowMenu: onShowEntryMenu,
                  ),
                ],
              ],
            );
          }

          final rowCount = (group.records.length + 1) ~/ 2;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var r = 0; r < rowCount; r++) ...[
                if (r > 0) const SizedBox(height: 8),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: _HistoryExpandedEntryRow(
                        record: group.records[r * 2],
                        episode: episodesById[group.records[r * 2].episodeId],
                        workItem: workItem,
                        imageLoader: imageLoader,
                        isAudio: isAudio,
                        inSelection: inSelection,
                        selected: selectedIds.contains(group.records[r * 2].id),
                        isDeleteMode: isDeleteMode,
                        audioDirLabel: isAudio
                            ? audioDirLabelResolver(group.records[r * 2])
                            : null,
                        onTap: () => onTapEntry(group.records[r * 2]),
                        onShowMenu: onShowEntryMenu,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: (r * 2 + 1) < group.records.length
                          ? _HistoryExpandedEntryRow(
                              record: group.records[r * 2 + 1],
                              episode:
                                  episodesById[group
                                      .records[r * 2 + 1]
                                      .episodeId],
                              workItem: workItem,
                              imageLoader: imageLoader,
                              isAudio: isAudio,
                              inSelection: inSelection,
                              selected: selectedIds.contains(
                                group.records[r * 2 + 1].id,
                              ),
                              isDeleteMode: isDeleteMode,
                              audioDirLabel: isAudio
                                  ? audioDirLabelResolver(
                                      group.records[r * 2 + 1],
                                    )
                                  : null,
                              onTap: () => onTapEntry(group.records[r * 2 + 1]),
                              onShowMenu: onShowEntryMenu,
                            )
                          : const SizedBox.shrink(),
                    ),
                  ],
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

/// 展开明细中的单集/单曲子行（视频展示 16:9 剧照，音频展示 1:1 专辑封面，均含标题、进度条与 24 小时制时间）。
class _HistoryExpandedEntryRow extends StatelessWidget {
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

  Widget _mediaPlaceholder(KonataPalette p) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: p.softFill,
        border: Border.all(color: p.hairline, width: 1),
      ),
      child: Center(
        child: Icon(
          isAudio ? Icons.album_outlined : Icons.play_circle_outline_rounded,
          size: 22,
          color: p.textMuted,
        ),
      ),
    );
  }

  Widget _buildVideoStill(KonataPalette p, double width, double height) {
    final work = workItem?.work;
    final still = episode?.stillPath?.trim();
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
        key: ValueKey('history_video_still_${record.id}'),
        width: width,
        height: height,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (source != null)
              ManagedImage(
                source,
                loader: imageLoader,
                owner: work?.id ?? record.workId,
                artwork: artwork,
                decodeWidth: 280,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => _mediaPlaceholder(p),
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
    final work = workItem?.work;
    if (!isAudio && episode != null) {
      return EpisodeTitleFormatter.formatCardTitle(
        episode: episode!,
        workMediaType: work?.tmdbMediaType,
        workTitle: work?.title,
        mainEpisodeCount: workItem?.episodeCount,
      );
    }
    return EpisodeTitleFormatter.formatHistorySubtitle(
      record: record,
      work: work,
      mainEpisodeCount: workItem?.episodeCount,
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final compact =
        MediaQuery.sizeOf(context).width <
        KonataAdaptiveTokens.tabletBreakpoint;
    final mediaWidth = isAudio
        ? (compact
              ? PlaybackHistoryCardMetrics.compactAudioAlbumCoverSize
              : PlaybackHistoryCardMetrics.audioAlbumCoverSize)
        : (compact
              ? PlaybackHistoryCardMetrics.compactEpisodeStillWidth
              : PlaybackHistoryCardMetrics.episodeStillWidth);
    final mediaHeight = isAudio
        ? mediaWidth
        : (compact
              ? PlaybackHistoryCardMetrics.compactEpisodeStillHeight
              : PlaybackHistoryCardMetrics.episodeStillHeight);

    final work = workItem?.work;
    final fallbackPoster =
        work?.posterPath ?? work?.bangumiPosterPath ?? work?.posterFallback;
    final entryTitle = _resolveEntryTitle();
    final progressLabel = PlaybackHistoryCardMetrics.formatProgressLabel(
      record,
      isAudio: isAudio,
      includeVerb: false,
    );
    final clockText = PlaybackHistoryTimelineBuilder.formatClockHm(
      record.playedAt,
    );
    final selectedAccent = isDeleteMode ? p.danger : p.accent;
    final trimmedDir = audioDirLabel?.trim() ?? '';

    final mediaBox = isAudio
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
                    imageLoader: imageLoader,
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
      onTap: onTap,
      onSecondaryTapUp: inSelection
          ? null
          : (details) => onShowMenu(details.globalPosition, record, isAudio),
      onLongPressStart: inSelection
          ? null
          : (details) => onShowMenu(details.globalPosition, record, isAudio),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: selected
                ? selectedAccent.withValues(alpha: p.isDark ? 0.16 : 0.10)
                : p.surface.withValues(alpha: p.isDark ? 0.55 : 0.72),
            borderRadius: KonataTheme.borderRadiusSm,
            border: Border.all(
              color: selected
                  ? selectedAccent.withValues(alpha: 0.72)
                  : p.hairline,
              width: 1,
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              mediaBox,
              const SizedBox(width: 10),
              Expanded(
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: mediaHeight),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          EllipsisTextWithTooltip(
                            text: entryTitle,
                            maxLines: isAudio && trimmedDir.isNotEmpty ? 1 : 2,
                            style: TextStyle(
                              color: p.textPrimary,
                              fontSize: compact ? 13.0 : 13.6,
                              fontWeight: FontWeight.w600,
                              height: 1.22,
                            ),
                          ),
                          if (isAudio && trimmedDir.isNotEmpty) ...[
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
                      const SizedBox(height: 6),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            height:
                                PlaybackHistoryCardMetrics.progressBarHeight,
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
              ),
              if (inSelection)
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: Icon(
                    selected
                        ? Icons.check_circle_rounded
                        : Icons.radio_button_unchecked_rounded,
                    size: 18,
                    color: selected ? selectedAccent : p.textMuted,
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
