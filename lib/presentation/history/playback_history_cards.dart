import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
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

part 'playback_history_sub_cards.dart';

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
  /// 单日作品卡片区切为双列并排的可用宽度阈值（空间充足时一行展示两个作品）。
  static const double twoColumnWorkBreakpoint = 860.0;

  /// 双列作品卡片之间的水平间距。
  static const double workColumnGap = 12.0;

  /// 展开明细横向条带中子卡片之间的水平间距。
  static const double entryRailGap = 10.0;

  /// 展开明细横向条带在宽卡下直接并排展示两张且露出探头的宽度阈值。
  static const double expandedTwoVisibleBreakpoint = 500.0;

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

/// 时间轴单行作品槽位容器（统一绘制左侧时间轴竖线并承接单列或宽屏双列作品卡片）。
class PlaybackHistoryTimelineRow extends StatelessWidget {
  /// 创建时间轴作品行容器。
  const PlaybackHistoryTimelineRow({
    super.key,
    required this.children,
    required this.columns,
    required this.isLastRowInDay,
    required this.isLastSection,
  });

  /// 本行包含的 1 或 2 张作品卡片。
  final List<Widget> children;

  /// 当前布局列数（1 或 2）。
  final int columns;

  /// 是否为该日期分组的最后一行。
  final bool isLastRowInDay;

  /// 是否为整个时间轴的最后一个日期分组。
  final bool isLastSection;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    const railW = PlaybackHistoryCardMetrics.timelineRailWidth;
    const lineW = PlaybackHistoryCardMetrics.timelineLineWidth;
    final lineLeft = (railW - lineW) / 2;
    final showBottomRail = !(isLastRowInDay && isLastSection);

    final Widget rowContent;
    if (columns <= 1) {
      rowContent = children.first;
    } else {
      rowContent = Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: children.first),
          const SizedBox(width: PlaybackHistoryCardMetrics.workColumnGap),
          Expanded(
            child: children.length > 1
                ? children[1]
                : const SizedBox.shrink(),
          ),
        ],
      );
    }

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
            isLastRowInDay ? 14 : 10,
          ),
          child: rowContent,
        ),
      ],
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
    this.showTimelineRail = true,
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

  /// 是否在卡片自身外侧绘制左侧时间轴竖线（交由 [PlaybackHistoryTimelineRow] 统一承接时置为 `false`）。
  final bool showTimelineRail;

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

    if (!showTimelineRail) {
      return cardContent;
    }

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

/// 支持鼠标、触控与触控板水平拖拽的轻量滚动行为。
class _HistoryHorizontalDragScrollBehavior extends MaterialScrollBehavior {
  const _HistoryHorizontalDragScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => const <PointerDeviceKind>{
    PointerDeviceKind.touch,
    PointerDeviceKind.mouse,
    PointerDeviceKind.trackpad,
    PointerDeviceKind.stylus,
    PointerDeviceKind.unknown,
  };
}

/// 展开态下的单日明细横向可拖拽条带（懒加载对应作品的单集剧照，音频复用专辑封面提取器，三端统一横向单行排布避免纵向堆积）。
class _ExpandedHistoryWorkEntries extends ConsumerStatefulWidget {
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
  ConsumerState<_ExpandedHistoryWorkEntries> createState() =>
      _ExpandedHistoryWorkEntriesState();
}

class _ExpandedHistoryWorkEntriesState
    extends ConsumerState<_ExpandedHistoryWorkEntries> {
  final ScrollController _railCtrl = ScrollController();

  @override
  void dispose() {
    _railCtrl.dispose();
    super.dispose();
  }

  /// 计算横向单行剧集子卡片宽度：单条撑满卡片内宽，双条在宽卡下工整平分，多条或窄卡自动留出下一张探头提示左右拖动。
  double _resolveTileWidth(double availableWidth, int count) {
    if (count <= 1) {
      return availableWidth;
    }
    const gap = PlaybackHistoryCardMetrics.entryRailGap;
    if (availableWidth >=
        PlaybackHistoryCardMetrics.expandedTwoVisibleBreakpoint) {
      if (count == 2) {
        return (availableWidth - gap) / 2.0;
      }
      return ((availableWidth - gap * 2) / 2.22).clamp(248.0, 310.0);
    }
    if (availableWidth < 252.0) {
      return math.max(180.0, availableWidth - 16.0);
    }
    return (availableWidth * 0.82).clamp(236.0, 296.0);
  }

  void _handleRailPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || !_railCtrl.hasClients) return;
    final maxExtent = _railCtrl.position.maxScrollExtent;
    if (maxExtent <= 0.5) return;
    final dx = event.scrollDelta.dx;
    final dy = event.scrollDelta.dy;
    final useShiftWheel =
        dx == 0 && dy != 0 && HardwareKeyboard.instance.isShiftPressed;
    final delta = dx != 0 ? dx : (useShiftWheel ? dy : 0.0);
    if (delta == 0.0) return;
    final target = (_railCtrl.offset + delta).clamp(0.0, maxExtent);
    if ((target - _railCtrl.offset).abs() > 0.5) {
      _railCtrl.jumpTo(target);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final bundle = widget.isAudio
        ? null
        : ref.watch(workDetailBundleProvider(widget.group.workId)).value;
    final episodesById = <String, Episode>{
      if (bundle != null)
        for (final ep in bundle.episodes) ep.id: ep,
    };
    final compact =
        MediaQuery.sizeOf(context).width <
        KonataAdaptiveTokens.tabletBreakpoint;
    final mediaHeight = widget.isAudio
        ? (compact
              ? PlaybackHistoryCardMetrics.compactAudioAlbumCoverSize
              : PlaybackHistoryCardMetrics.audioAlbumCoverSize)
        : (compact
              ? PlaybackHistoryCardMetrics.compactEpisodeStillHeight
              : PlaybackHistoryCardMetrics.episodeStillHeight);
    final textScale = (MediaQuery.textScalerOf(context).scale(14.0) / 14.0)
        .clamp(1.0, 1.5);
    final innerHeight = math.max(mediaHeight, (54.0 * textScale) + 16.0);
    final tileHeight = innerHeight + 18.0;
    final records = widget.group.records;
    final showRailBottomSpace = records.length > 1;
    // 深色模式采用轻度沉降暗腔，浅色模式采用柔和石板灰凹槽，与子卡片自然形成同源层次。
    final trayBg = p.isDark
        ? KonataTheme.scrimBlackHairline
        : p.secondaryButtonBg;

    return ClipRRect(
      borderRadius: const BorderRadius.vertical(
        bottom: Radius.circular(KonataTheme.radiusCard - 1),
      ),
      child: Container(
        key: ValueKey('history_expanded_${widget.group.groupKey}'),
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(
              color: KonataTheme.subtleOutlineBorder(p),
              width: 1,
            ),
          ),
          color: trayBg,
        ),
        padding: EdgeInsets.fromLTRB(
          10,
          8,
          10,
          showRailBottomSpace ? 6 : 10,
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final tileWidth = _resolveTileWidth(
              constraints.maxWidth,
              records.length,
            );
            final listHeight = tileHeight + (showRailBottomSpace ? 8.0 : 0.0);

            return Listener(
              onPointerSignal: _handleRailPointerSignal,
              child: ScrollConfiguration(
                behavior: const _HistoryHorizontalDragScrollBehavior(),
                child: SizedBox(
                  height: listHeight,
                  child: Scrollbar(
                    controller: _railCtrl,
                    interactive: true,
                    thumbVisibility: false,
                    scrollbarOrientation: ScrollbarOrientation.bottom,
                    child: ListView.separated(
                      key: ValueKey(
                        'history_expanded_rail_${widget.group.groupKey}',
                      ),
                      controller: _railCtrl,
                      scrollDirection: Axis.horizontal,
                      physics: const BouncingScrollPhysics(
                        parent: AlwaysScrollableScrollPhysics(),
                      ),
                      padding: EdgeInsets.only(
                        bottom: showRailBottomSpace ? 8.0 : 0.0,
                      ),
                      itemCount: records.length,
                      separatorBuilder: (_, _) => const SizedBox(
                        width: PlaybackHistoryCardMetrics.entryRailGap,
                      ),
                      itemBuilder: (_, index) {
                        final rec = records[index];
                        return SizedBox(
                          width: tileWidth,
                          height: tileHeight,
                          child: _HistoryExpandedEntryRow(
                            record: rec,
                            episode: episodesById[rec.episodeId],
                            workItem: widget.workItem,
                            imageLoader: widget.imageLoader,
                            isAudio: widget.isAudio,
                            inSelection: widget.inSelection,
                            selected: widget.selectedIds.contains(rec.id),
                            isDeleteMode: widget.isDeleteMode,
                            audioDirLabel: widget.isAudio
                                ? widget.audioDirLabelResolver(rec)
                                : null,
                            onTap: () => widget.onTapEntry(rec),
                            onShowMenu: widget.onShowEntryMenu,
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
