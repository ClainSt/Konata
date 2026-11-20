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
import '../widgets/playback/konata_cd_disc_placeholder.dart';

/// 播放记录行级上下文菜单打开回调。
typedef HistoryRowMenuCallback =
    void Function(Offset globalPosition, PlaybackRecord record, bool isAudio);

/// 播放记录卡片共享排版几何常量。
abstract final class PlaybackHistoryCardMetrics {
  /// 双列网格切换断点。
  static const double twoColumnBreakpoint = 900.0;

  /// 桌面与平板横屏视频海报宽度。
  static const double videoCoverWidth = 112.0;

  /// 桌面与平板横屏视频海报高度。
  static const double videoCoverHeight = 160.0;

  /// 紧凑视频海报宽度。
  static const double compactVideoCoverWidth = 74.0;

  /// 紧凑视频海报高度。
  static const double compactVideoCoverHeight = 104.0;

  /// 手机横屏视频海报宽度。
  static const double phoneLandscapeVideoCoverWidth = 76.0;

  /// 常规音频封面边长。
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
  static const double titleLineHeight = 1.24;

  /// 桌面分集副标题字号。
  static const double subtitleFontSize = 15.5;

  /// 桌面音频碟片目录字号。
  static const double audioDirFontSize = 13.5;

  /// 桌面进度文字字号。
  static const double progressFontSize = 14.0;

  /// 桌面观看日期字号。
  static const double dateFontSize = 13.5;

  /// 桌面进度条高度（流光细轨）。
  static const double progressBarHeight = 3.5;

  /// 桌面标题与副标题间距。
  static const double titleSubtitleGap = 6.0;

  /// 桌面进度条与底部时间日期行间距。
  static const double progressBarGap = 6.0;

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

/// 播放记录统一卡片组件（视频紧凑卡、音频卡、桌面/平板横屏宽屏视频卡共用同一套等高贴底骨架）。
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

  /// 是否为双列并排模式。
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

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final mqSize = MediaQuery.sizeOf(context);
    final isPhone = mqSize.shortestSide < KonataAdaptiveTokens.tabletBreakpoint;
    final isPhoneLandscape = isPhone && mqSize.width > mqSize.height;
    final isPortraitTablet =
        mqSize.shortestSide >= KonataAdaptiveTokens.tabletBreakpoint &&
        mqSize.height >= mqSize.width &&
        mqSize.width < PlaybackHistoryCardMetrics.twoColumnBreakpoint;
    final veryNarrow = mqSize.width < 380.0;
    final isCompactVideo = !isAudio && (isPhone || isPortraitTablet);
    final isWideDesktopVideo = !isAudio && !isCompactVideo;

    final double coverWidth;
    final double coverHeight;
    final double coverRadius;
    final EdgeInsets cardPadding;
    final double coverGap;
    final double titleFontSize;
    final double titleLineHeight;
    final double subtitleFontSize;
    final double titleSubGap;
    final double progressBarHeight;
    final double progressRowGap;
    final double progressFontSize;
    final double dateFontSize;

    if (isAudio) {
      final side = isPhoneLandscape
          ? PlaybackHistoryCardMetrics.phoneLandscapeUnifiedCoverHeight
          : (veryNarrow ? 82.0 : PlaybackHistoryCardMetrics.audioCoverSize);
      coverWidth = side;
      coverHeight = side;
      coverRadius = 10.0;
      cardPadding = const EdgeInsets.symmetric(horizontal: 10, vertical: 8);
      coverGap = veryNarrow ? 10.0 : 12.0;
      titleFontSize = veryNarrow ? 14.2 : 14.8;
      titleLineHeight = 1.18;
      subtitleFontSize = veryNarrow ? 12.2 : 12.8;
      titleSubGap = 2.0;
      progressBarHeight = 3.0;
      progressRowGap = 4.0;
      progressFontSize = 11.8;
      dateFontSize = 11.5;
    } else if (isCompactVideo) {
      coverWidth = isPhoneLandscape
          ? PlaybackHistoryCardMetrics.phoneLandscapeVideoCoverWidth
          : PlaybackHistoryCardMetrics.compactVideoCoverWidth;
      coverHeight = isPhoneLandscape
          ? PlaybackHistoryCardMetrics.phoneLandscapeUnifiedCoverHeight
          : PlaybackHistoryCardMetrics.compactVideoCoverHeight;
      coverRadius = 9.0;
      cardPadding = const EdgeInsets.symmetric(horizontal: 10, vertical: 8);
      coverGap = veryNarrow ? 10.0 : 12.0;
      titleFontSize = veryNarrow ? 14.8 : 15.6;
      titleLineHeight = 1.20;
      subtitleFontSize = veryNarrow ? 12.6 : 13.2;
      titleSubGap = 3.0;
      progressBarHeight = 3.2;
      progressRowGap = 5.0;
      progressFontSize = 12.0;
      dateFontSize = 11.8;
    } else {
      coverWidth = PlaybackHistoryCardMetrics.videoCoverWidth;
      coverHeight = PlaybackHistoryCardMetrics.videoCoverHeight;
      coverRadius = 10.0;
      cardPadding = const EdgeInsets.all(PlaybackHistoryCardMetrics.cardPadding);
      coverGap = PlaybackHistoryCardMetrics.coverTextGap;
      titleFontSize = PlaybackHistoryCardMetrics.titleFontSize;
      titleLineHeight = PlaybackHistoryCardMetrics.titleLineHeight;
      subtitleFontSize = PlaybackHistoryCardMetrics.subtitleFontSize;
      titleSubGap = PlaybackHistoryCardMetrics.titleSubtitleGap;
      progressBarHeight = PlaybackHistoryCardMetrics.progressBarHeight;
      progressRowGap = PlaybackHistoryCardMetrics.progressBarGap;
      progressFontSize = PlaybackHistoryCardMetrics.progressFontSize;
      dateFontSize = PlaybackHistoryCardMetrics.dateFontSize;
    }

    final work = workItem?.work;
    final epLabel = EpisodeTitleFormatter.formatHistorySubtitle(
      record: record,
      work: work,
      mainEpisodeCount: workItem?.episodeCount,
    );
    final progressStatus = PlaybackHistoryCardMetrics.formatProgressLabel(
      record,
      isAudio: isAudio,
      includeVerb: false,
    );
    final selectedAccent = isDeleteMode ? p.danger : p.accent;
    final poster =
        work?.posterPath ?? work?.bangumiPosterPath ?? work?.posterFallback;
    final hasTrailing = inSelection || KonataAdaptiveTokens.isAndroid;
    final kindTag = isAudio ? 'audio' : 'video';

    final Widget coverChild = isAudio
        ? _AudioHistoryCover(
            workId: record.workId,
            variantId: record.variantId,
            fallbackPoster: poster,
            imageLoader: imageLoader,
            size: coverHeight,
          )
        : (poster != null && poster.isNotEmpty
              ? ManagedImage(
                  poster,
                  loader: imageLoader,
                  owner: work?.id ?? record.workId,
                  artwork: ManagedArtwork.poster,
                  decodeWidth: isWideDesktopVideo ? 280 : 260,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => _posterFallback(p, audio: false),
                )
              : _posterFallback(p, audio: false));

    final trimmedAudioDir = audioDirLabel?.trim() ?? '';

    final card = KonataSurfaceCard(
      padding: cardPadding,
      enableHover: !selected,
      backgroundColor: selected
          ? selectedAccent.withValues(alpha: p.isDark ? 0.14 : 0.08)
          : null,
      borderColor: selected ? selectedAccent.withValues(alpha: 0.72) : null,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(coverRadius),
            child: SizedBox(
              key: ValueKey('history_${kindTag}_cover_${record.id}'),
              width: coverWidth,
              height: coverHeight,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  coverChild,
                  Positioned.fill(
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(coverRadius),
                          border: Border.all(color: p.posterBorder, width: 1),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          SizedBox(width: coverGap),
          Expanded(
            child: ConstrainedBox(
              constraints: BoxConstraints.tightFor(height: coverHeight),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // 顶部信息组置顶，中间剩余高度自然弹性撑开，标题超长仅截断自身而不挤压底部两行
                      Expanded(
                        child: ClipRect(
                          child: LayoutBuilder(
                            builder: (context, topConstraints) {
                              final showAudioSubDir =
                                  isAudio &&
                                  trimmedAudioDir.isNotEmpty &&
                                  topConstraints.maxHeight >= 66.0;
                              final maxTitleLines =
                                  topConstraints.maxHeight < 46.0 ? 1 : 2;
                              return Align(
                                alignment: Alignment.topLeft,
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Padding(
                                      padding: EdgeInsets.only(
                                        right: hasTrailing ? 32 : 0,
                                      ),
                                      child: Text(
                                        work?.title ?? '未知作品',
                                        key: ValueKey(
                                          'history_${kindTag}_work_title_${record.id}',
                                        ),
                                        maxLines: maxTitleLines,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: p.textPrimary,
                                          fontSize: titleFontSize,
                                          fontWeight: FontWeight.w700,
                                          height: titleLineHeight,
                                        ),
                                      ),
                                    ),
                                    SizedBox(height: titleSubGap),
                                    EllipsisTextWithTooltip(
                                      text: epLabel,
                                      maxLines: 1,
                                      style: TextStyle(
                                        color: p.textSecondary,
                                        fontSize: subtitleFontSize,
                                        fontWeight: FontWeight.w500,
                                        height: 1.16,
                                      ),
                                    ),
                                    if (showAudioSubDir) ...[
                                      const SizedBox(height: 2),
                                      EllipsisTextWithTooltip(
                                        text: trimmedAudioDir,
                                        maxLines: 1,
                                        style: TextStyle(
                                          color: p.textMuted,
                                          fontSize: isWideDesktopVideo
                                              ? PlaybackHistoryCardMetrics
                                                    .audioDirFontSize
                                              : 11.4,
                                          fontWeight: FontWeight.w400,
                                          height: 1.14,
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                      // 底部两行（进度条 + 时间进度与观看日期）严格贴齐封面底边
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            height: progressBarHeight,
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
                          SizedBox(height: progressRowGap),
                          MediaQuery.withClampedTextScaling(
                            maxScaleFactor: 1.15,
                            child: LayoutBuilder(
                              builder: (context, rowConstraints) {
                                final compactRow =
                                    rowConstraints.maxWidth < 210.0;
                                return Row(
                                  key: ValueKey(
                                    'history_progress_row_${record.id}',
                                  ),
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    Expanded(
                                      child: Text(
                                        progressStatus,
                                        key: ValueKey(
                                          'history_${kindTag}_time_${record.id}',
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: KonataTheme.textStyle(
                                          color: record.isCompleted
                                              ? p.success
                                              : p.progressFill,
                                          fontSize: compactRow
                                              ? 10.8
                                              : progressFontSize,
                                          weight: 600,
                                          height: 1.0,
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
                                          'history_${kindTag}_date_${record.id}',
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        textAlign: TextAlign.right,
                                        style: KonataTheme.textStyle(
                                          color: p.textMuted,
                                          fontSize: compactRow
                                              ? 10.5
                                              : dateFontSize,
                                          weight: 500,
                                          height: 1.0,
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
