import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/providers/artwork_provider.dart';
import '../../application/providers/library_providers.dart';
import '../../domain/formatting/media_display_formatter.dart';
import '../../domain/matching/episode_title_formatter.dart';
import '../../domain/models/playback_record.dart';
import '../audio/smart_cover_framing.dart';
import '../theme/konata_adaptive_tokens.dart';
import '../theme/konata_palette.dart';
import '../theme/konata_theme.dart';
import '../widgets/design_system/ellipsis_text_with_tooltip.dart';
import '../widgets/design_system/konata_surface_card.dart';
import '../widgets/managed_image.dart';

/// 播放记录行级上下文菜单打开回调。
typedef HistoryRowMenuCallback =
    void Function(Offset globalPosition, PlaybackRecord record, bool isAudio);

/// 播放记录卡片共享排版几何常量。
abstract final class PlaybackHistoryCardMetrics {
  /// 双列网格切换断点。
  static const double twoColumnBreakpoint = 900.0;

  /// 桌面/平板横屏视频海报宽度。
  static const double videoCoverWidth = 112.0;

  /// 桌面/平板横屏视频海报高度。
  static const double videoCoverHeight = 160.0;

  /// 桌面/平板横屏音频封面边长。
  static const double audioCoverSize = 86.0;

  /// 手机横屏音视频封面统一折中高度。
  static const double phoneLandscapeUnifiedCoverHeight = 108.0;

  /// 桌面卡片默认内边距。
  static const double cardPadding = 16.0;

  /// 桌面封面与文字间距。
  static const double coverTextGap = 16.0;

  /// 双列间距。
  static const double colGap = 14.0;

  /// 桌面标题字号。
  static const double titleFontSize = 20.5;

  /// 桌面标题行高倍率。
  static const double titleLineHeight = 1.28;

  /// 桌面分集副标题字号。
  static const double subtitleFontSize = 15.5;

  /// 桌面音频碟片目录字号。
  static const double audioDirFontSize = 13.5;

  /// 桌面进度文字字号。
  static const double progressFontSize = 14.0;

  /// 桌面观看日期字号。
  static const double dateFontSize = 13.5;

  /// 桌面进度条高度。
  static const double progressBarHeight = 6.5;

  /// 桌面标题与副标题间距。
  static const double titleSubtitleGap = 8.0;

  /// 桌面进度文案与进度条间距。
  static const double progressBarGap = 10.0;

  /// 生成时间进度显示文案；[includeVerb] 为 `false` 时仅输出时间进度而不带前缀。
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

/// 播放记录自适应条目卡片（涵盖全端五层紧凑音频卡、手机/竖版平板五层紧凑视频卡及桌面宽屏视频卡）。
class PlaybackHistoryItemCard extends StatelessWidget {
  /// 创建播放记录卡片。
  const PlaybackHistoryItemCard({
    super.key,
    required this.record,
    required this.workItem,
    required this.imageLoader,
    required this.isAudio,
    required this.stretchHeight,
    required this.inSelection,
    required this.selected,
    required this.isDeleteMode,
    required this.onTapCard,
    required this.onShowMenu,
    this.audioDirLabel,
  });

  /// 当前播放记录实体。
  final PlaybackRecord record;

  /// 关联媒体库作品聚合项。
  final WorkLibraryItem? workItem;

  /// 封面加载器。
  final ManagedImageLoader imageLoader;

  /// 是否为音频播放记录。
  final bool isAudio;

  /// 双列模式下是否拉伸高度对齐同行最高卡片。
  final bool stretchHeight;

  /// 是否处于批量选择态。
  final bool inSelection;

  /// 当前条目是否已勾选。
  final bool selected;

  /// 批量模式是否为删除模式。
  final bool isDeleteMode;

  /// 点击整张卡片回调。
  final VoidCallback onTapCard;

  /// 右键、长按或点击右上角更多图标回调。
  final HistoryRowMenuCallback onShowMenu;

  /// 可选音频专辑子目录名称。
  final String? audioDirLabel;

  Widget _buildLineAlignedMoreTarget(
    BuildContext context,
    KonataPalette p,
    Color selectedAccent,
  ) {
    if (inSelection) {
      return Padding(
        padding: const EdgeInsets.only(top: 1),
        child: Icon(
          selected
              ? Icons.check_circle_rounded
              : Icons.radio_button_unchecked_rounded,
          size: 20,
          color: selected ? selectedAccent : p.textMuted,
        ),
      );
    }
    if (!KonataAdaptiveTokens.isAndroid) {
      return const SizedBox.shrink();
    }
    return Builder(
      builder: (btnContext) => GestureDetector(
        key: ValueKey('history_more_${record.id}'),
        behavior: HitTestBehavior.opaque,
        onTap: () {
          final box = btnContext.findRenderObject() as RenderBox?;
          final anchor = box != null
              ? box.localToGlobal(const Offset(24, 12))
              : Offset.zero;
          onShowMenu(anchor, record, isAudio);
        },
        child: SizedBox.square(
          dimension: KonataAdaptiveTokens.touchTarget,
          child: Align(
            alignment: Alignment.topRight,
            child: Padding(
              padding: const EdgeInsets.only(top: 1, right: 2),
              child: Icon(
                Icons.more_horiz_rounded,
                size: 20,
                color: p.textSecondary,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _wrapInteractiveShell(Widget card) {
    return GestureDetector(
      onSecondaryTapUp: inSelection
          ? null
          : (details) => onShowMenu(details.globalPosition, record, isAudio),
      onLongPressStart: inSelection
          ? null
          : (details) => onShowMenu(details.globalPosition, record, isAudio),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTapCard,
          child: card,
        ),
      ),
    );
  }

  Widget _posterFallback(KonataPalette p, {required bool audio}) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: p.softFill,
        border: Border.all(color: p.hairline, width: 1),
      ),
      child: Center(
        child: Icon(
          audio ? Icons.album_outlined : Icons.movie_outlined,
          size: 30,
          color: p.textMuted,
        ),
      ),
    );
  }

  Widget _buildAudioCompactCard(BuildContext context, KonataPalette p) {
    final work = workItem?.work;
    final epLabel = EpisodeTitleFormatter.formatHistorySubtitle(
      record: record,
      work: work,
      mainEpisodeCount: workItem?.episodeCount,
    );
    final selectedAccent = isDeleteMode ? p.danger : p.accent;
    final poster =
        work?.posterPath ?? work?.bangumiPosterPath ?? work?.posterFallback;
    final hasTrailing = inSelection || KonataAdaptiveTokens.isAndroid;
    final mqSize = MediaQuery.sizeOf(context);
    final isPhoneLandscape =
        KonataAdaptiveTokens.isAndroid &&
        mqSize.shortestSide < KonataAdaptiveTokens.tabletBreakpoint &&
        mqSize.width > mqSize.height;
    final veryNarrow =
        KonataAdaptiveTokens.isAndroid && mqSize.width < 380.0;
    final coverSize = isPhoneLandscape
        ? PlaybackHistoryCardMetrics.phoneLandscapeUnifiedCoverHeight
        : (veryNarrow
              ? 82.0
              : PlaybackHistoryCardMetrics.audioCoverSize);
    final coverGap = veryNarrow ? 10.0 : 12.0;
    final progressStatus = PlaybackHistoryCardMetrics.formatProgressLabel(
      record,
      isAudio: true,
      includeVerb: false,
    );

    final card = KonataSurfaceCard(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      enableHover: !selected,
      backgroundColor: selected
          ? selectedAccent.withValues(alpha: p.isDark ? 0.14 : 0.08)
          : null,
      borderColor: selected ? selectedAccent.withValues(alpha: 0.72) : null,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: SizedBox.square(
              key: ValueKey('history_audio_cover_${record.id}'),
              dimension: coverSize,
              child: _AudioHistoryCover(
                workId: record.workId,
                variantId: record.variantId,
                fallbackPoster: poster,
                imageLoader: imageLoader,
                size: coverSize,
              ),
            ),
          ),
          SizedBox(width: coverGap),
          Expanded(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: coverSize),
              child: Stack(
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Padding(
                            padding: EdgeInsets.only(
                              right: hasTrailing ? 32 : 0,
                            ),
                            child: Text(
                              work?.title ?? '未知作品',
                              key: ValueKey(
                                'history_audio_work_title_${record.id}',
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: p.textPrimary,
                                fontSize: veryNarrow ? 15.0 : 15.8,
                                fontWeight: FontWeight.w700,
                                height: 1.24,
                              ),
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            epLabel,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: p.textSecondary,
                              fontSize: veryNarrow ? 13.0 : 13.5,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          if (audioDirLabel != null &&
                              audioDirLabel!.trim().isNotEmpty) ...[
                            const SizedBox(height: 2),
                            EllipsisTextWithTooltip(
                              text: audioDirLabel!.trim(),
                              maxLines: 1,
                              style: TextStyle(
                                color: p.textMuted,
                                fontSize: 11.8,
                                fontWeight: FontWeight.w400,
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
                            height: 4.5,
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(999),
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
                          const SizedBox(height: 5),
                          MediaQuery.withClampedTextScaling(
                            maxScaleFactor: 1.15,
                            child: LayoutBuilder(
                              builder: (context, rowConstraints) {
                                final compactRow =
                                    rowConstraints.maxWidth < 210.0;
                                return Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        progressStatus,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: KonataTheme.textStyle(
                                          color: record.isCompleted
                                              ? p.success
                                              : p.progressFill,
                                          fontSize: compactRow ? 11.0 : 12.0,
                                          weight: 600,
                                          tabularFigures: true,
                                        ),
                                      ),
                                    ),
                                    SizedBox(width: compactRow ? 4 : 8),
                                    ConstrainedBox(
                                      constraints: BoxConstraints(
                                        maxWidth:
                                            rowConstraints.maxWidth * 0.60,
                                      ),
                                      child: Text(
                                        MediaDisplayFormatter
                                            .formatDateTimeMinute(
                                              record.playedAt,
                                            ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        textAlign: TextAlign.right,
                                        style: KonataTheme.textStyle(
                                          color: p.textMuted,
                                          fontSize: compactRow ? 10.8 : 11.8,
                                          weight: 500,
                                          tabularFigures: true,
                                        ),
                                      ),
                                    ),
                                  ],
                                );
                              },
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  if (hasTrailing)
                    Positioned(
                      top: 0,
                      right: 0,
                      child: _buildLineAlignedMoreTarget(
                        context,
                        p,
                        selectedAccent,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
    return _wrapInteractiveShell(card);
  }

  Widget _buildCompactFiveLayerVideoCard(
    BuildContext context,
    KonataPalette p, {
    required bool isPhoneLandscape,
  }) {
    final work = workItem?.work;
    final epLabel = EpisodeTitleFormatter.formatHistorySubtitle(
      record: record,
      work: work,
      mainEpisodeCount: workItem?.episodeCount,
    );
    final progressStatus = PlaybackHistoryCardMetrics.formatProgressLabel(
      record,
      isAudio: false,
      includeVerb: false,
    );
    final selectedAccent = isDeleteMode ? p.danger : p.accent;
    final poster =
        work?.posterPath ?? work?.bangumiPosterPath ?? work?.posterFallback;
    final hasTrailing = inSelection || KonataAdaptiveTokens.isAndroid;
    final veryNarrow = MediaQuery.sizeOf(context).width < 380.0;

    final coverHeight = isPhoneLandscape
        ? PlaybackHistoryCardMetrics.phoneLandscapeUnifiedCoverHeight
        : 104.0;
    final coverWidth = isPhoneLandscape ? 76.0 : 74.0;
    final coverGap = veryNarrow ? 10.0 : 12.0;

    final coverWidget = poster != null && poster.isNotEmpty
        ? ManagedImage(
            poster,
            loader: imageLoader,
            owner: work?.id ?? record.workId,
            artwork: ManagedArtwork.poster,
            decodeWidth: 260,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => _posterFallback(p, audio: false),
          )
        : _posterFallback(p, audio: false);

    final card = KonataSurfaceCard(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      enableHover: !selected,
      backgroundColor: selected
          ? selectedAccent.withValues(alpha: p.isDark ? 0.14 : 0.08)
          : null,
      borderColor: selected ? selectedAccent.withValues(alpha: 0.72) : null,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(9),
            child: SizedBox(
              key: ValueKey('history_video_cover_${record.id}'),
              width: coverWidth,
              height: coverHeight,
              child: coverWidget,
            ),
          ),
          SizedBox(width: coverGap),
          Expanded(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: coverHeight),
              child: Stack(
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Padding(
                            padding: EdgeInsets.only(
                              right: hasTrailing ? 32 : 0,
                            ),
                            child: Text(
                              work?.title ?? '未知作品',
                              key: ValueKey(
                                'history_video_work_title_${record.id}',
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: p.textPrimary,
                                fontSize: veryNarrow ? 15.2 : 16.0,
                                fontWeight: FontWeight.w700,
                                height: 1.24,
                              ),
                            ),
                          ),
                          const SizedBox(height: 4),
                          EllipsisTextWithTooltip(
                            text: epLabel,
                            maxLines: 1,
                            style: TextStyle(
                              color: p.textSecondary,
                              fontSize: veryNarrow ? 13.0 : 13.5,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            height: 5.0,
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(999),
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
                          const SizedBox(height: 5),
                          MediaQuery.withClampedTextScaling(
                            maxScaleFactor: 1.15,
                            child: LayoutBuilder(
                              builder: (context, rowConstraints) {
                                final compactRow =
                                    rowConstraints.maxWidth < 210.0;
                                return Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        progressStatus,
                                        key: ValueKey(
                                          'history_video_time_${record.id}',
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: KonataTheme.textStyle(
                                          color: record.isCompleted
                                              ? p.success
                                              : p.progressFill,
                                          fontSize: compactRow ? 11.0 : 12.2,
                                          weight: 600,
                                          tabularFigures: true,
                                        ),
                                      ),
                                    ),
                                    SizedBox(width: compactRow ? 4 : 8),
                                    ConstrainedBox(
                                      constraints: BoxConstraints(
                                        maxWidth:
                                            rowConstraints.maxWidth * 0.60,
                                      ),
                                      child: Text(
                                        MediaDisplayFormatter
                                            .formatDateTimeMinute(
                                              record.playedAt,
                                            ),
                                        key: ValueKey(
                                          'history_video_date_${record.id}',
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        textAlign: TextAlign.right,
                                        style: KonataTheme.textStyle(
                                          color: p.textMuted,
                                          fontSize: compactRow ? 10.8 : 11.8,
                                          weight: 500,
                                          tabularFigures: true,
                                        ),
                                      ),
                                    ),
                                  ],
                                );
                              },
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  if (hasTrailing)
                    Positioned(
                      top: 0,
                      right: 0,
                      child: _buildLineAlignedMoreTarget(
                        context,
                        p,
                        selectedAccent,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
    return _wrapInteractiveShell(card);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    if (isAudio) {
      return _buildAudioCompactCard(context, p);
    }
    final mqSize = MediaQuery.sizeOf(context);
    final isPhone =
        mqSize.shortestSide < KonataAdaptiveTokens.tabletBreakpoint;
    final isPortraitTablet =
        mqSize.shortestSide >= KonataAdaptiveTokens.tabletBreakpoint &&
        mqSize.height >= mqSize.width;
    if (KonataAdaptiveTokens.isAndroid && (isPhone || isPortraitTablet)) {
      return _buildCompactFiveLayerVideoCard(
        context,
        p,
        isPhoneLandscape: isPhone && mqSize.width > mqSize.height,
      );
    }

    final work = workItem?.work;
    final epLabel = EpisodeTitleFormatter.formatHistorySubtitle(
      record: record,
      work: work,
      mainEpisodeCount: workItem?.episodeCount,
    );
    final progressText = PlaybackHistoryCardMetrics.formatProgressLabel(
      record,
      isAudio: false,
      includeVerb: true,
    );
    final selectedAccent = isDeleteMode ? p.danger : p.accent;
    final poster =
        work?.posterPath ?? work?.bangumiPosterPath ?? work?.posterFallback;
    final hasTrailing = inSelection || KonataAdaptiveTokens.isAndroid;

    final coverWidget = poster != null && poster.isNotEmpty
        ? ManagedImage(
            poster,
            loader: imageLoader,
            owner: work?.id ?? record.workId,
            artwork: ManagedArtwork.poster,
            decodeWidth: 280,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => _posterFallback(p, audio: false),
          )
        : _posterFallback(p, audio: false);

    final topBlock = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: EdgeInsets.only(right: hasTrailing ? 36 : 0),
          child: Text(
            work?.title ?? '未知作品',
            softWrap: true,
            style: TextStyle(
              color: p.textPrimary,
              fontSize: PlaybackHistoryCardMetrics.titleFontSize,
              fontWeight: FontWeight.w700,
              height: PlaybackHistoryCardMetrics.titleLineHeight,
            ),
          ),
        ),
        const SizedBox(height: PlaybackHistoryCardMetrics.titleSubtitleGap),
        EllipsisTextWithTooltip(
          text: epLabel,
          maxLines: 1,
          style: TextStyle(
            color: p.textSecondary,
            fontSize: PlaybackHistoryCardMetrics.subtitleFontSize,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );

    final bottomBlock = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          progressText,
          style: KonataTheme.textStyle(
            color: record.isCompleted ? p.success : p.progressFill,
            fontSize: PlaybackHistoryCardMetrics.progressFontSize,
            weight: 600,
            tabularFigures: true,
          ),
        ),
        const SizedBox(height: PlaybackHistoryCardMetrics.progressBarGap),
        LayoutBuilder(
          builder: (context, barBox) {
            final progressBar = SizedBox(
              height: PlaybackHistoryCardMetrics.progressBarHeight,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: LinearProgressIndicator(
                  value: record.isCompleted ? 1.0 : record.progressRatio,
                  backgroundColor: p.progressTrack,
                  valueColor: AlwaysStoppedAnimation(
                    record.isCompleted ? p.success : p.progressFill,
                  ),
                ),
              ),
            );
            final dateLabel = MediaQuery.withClampedTextScaling(
              maxScaleFactor: 1.15,
              child: Text(
                MediaDisplayFormatter.formatDateTimeMinute(record.playedAt),
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
                style: KonataTheme.textStyle(
                  color: p.textMuted,
                  fontSize: PlaybackHistoryCardMetrics.dateFontSize,
                  weight: 500,
                  tabularFigures: true,
                ),
              ),
            );
            if (barBox.maxWidth < 260.0) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  progressBar,
                  const SizedBox(height: 6),
                  Align(alignment: Alignment.centerRight, child: dateLabel),
                ],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(child: progressBar),
                const SizedBox(width: 10),
                Flexible(flex: 0, child: dateLabel),
              ],
            );
          },
        ),
      ],
    );

    final card = KonataSurfaceCard(
      padding: const EdgeInsets.all(PlaybackHistoryCardMetrics.cardPadding),
      enableHover: !selected,
      backgroundColor: selected
          ? selectedAccent.withValues(alpha: p.isDark ? 0.14 : 0.08)
          : null,
      borderColor: selected ? selectedAccent.withValues(alpha: 0.72) : null,
      child: Row(
        crossAxisAlignment: stretchHeight
            ? CrossAxisAlignment.stretch
            : CrossAxisAlignment.start,
        children: [
          Align(
            alignment: Alignment.topCenter,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: SizedBox(
                width: PlaybackHistoryCardMetrics.videoCoverWidth,
                height: PlaybackHistoryCardMetrics.videoCoverHeight,
                child: coverWidget,
              ),
            ),
          ),
          const SizedBox(width: PlaybackHistoryCardMetrics.coverTextGap),
          Expanded(
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                minHeight: PlaybackHistoryCardMetrics.videoCoverHeight,
              ),
              child: Stack(
                children: [
                  stretchHeight
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [topBlock, bottomBlock],
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            topBlock,
                            const SizedBox(height: 16),
                            bottomBlock,
                          ],
                        ),
                  if (hasTrailing)
                    Positioned(
                      top: 0,
                      right: 0,
                      child: _buildLineAlignedMoreTarget(
                        context,
                        p,
                        selectedAccent,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
    return _wrapInteractiveShell(card);
  }
}

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
        decodeWidth: 280,
        fit: BoxFit.cover,
        alignment: SmartCoverFraming.defaultPosterAlignment,
        errorBuilder: (_, _, _) => _buildIconPlaceholder(p),
      );
    }
    return _buildIconPlaceholder(p);
  }

  Widget _buildIconPlaceholder(KonataPalette p) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: p.softFill,
        border: Border.all(color: p.hairline, width: 1),
      ),
      child: Center(
        child: Icon(Icons.album_outlined, size: 34, color: p.textMuted),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.palette;
    final albumBytesAsync = ref.watch(
      audioRecordAlbumCoverProvider((workId: workId, variantId: variantId)),
    );
    final bytes = albumBytesAsync.valueOrNull;
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
