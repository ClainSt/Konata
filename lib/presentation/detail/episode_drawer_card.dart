import 'package:flutter/material.dart';

import '../../domain/formatting/media_display_formatter.dart';
import '../../domain/matching/episode_title_formatter.dart';
import '../../domain/models/episode.dart';
import '../../domain/models/media_variant.dart';
import '../../domain/models/playback_record.dart';
import '../../domain/models/work.dart';
import '../theme/konata_palette.dart';
import '../theme/konata_theme.dart';
import '../widgets/design_system/ellipsis_text_with_tooltip.dart';
import '../widgets/managed_image.dart';
import '../widgets/playback/konata_spec_badge.dart';

/// 详情页底部抽屉单集卡片（展示 16:9 剧照、进度条、集数标题、多版本徽章与文件名）。
class EpisodeDrawerCard extends StatefulWidget {
  /// 创建单集卡片。
  const EpisodeDrawerCard({
    super.key,
    required this.episode,
    required this.variants,
    required this.fallbackBackdropPath,
    required this.imageLoader,
    required this.onTap,
    required this.onAdjustSlot,
    this.onPlayBuiltin,
    this.onPlayExternal,
    this.workTitle,
    this.workMediaType,
    this.mainEpisodeCount,
    this.playback,
    this.onMarkCompleted,
    this.displayTitleOverride,
    this.showRawFileName = true,
  });

  /// 逻辑剧集实体。
  final Episode episode;

  /// 归属该集的物理版本列表。
  final List<MediaVariant> variants;

  /// 剧照缺失时使用的作品背景图回退路径。
  final String? fallbackBackdropPath;

  /// 图片加载器。
  final ManagedImageLoader imageLoader;

  /// 点击播放/选播回调。
  final VoidCallback onTap;

  /// 右键微调单集话数/特典分类回调。
  final VoidCallback onAdjustSlot;

  /// 右键指定内置播放器播放回调。
  final VoidCallback? onPlayBuiltin;

  /// 右键指定外部播放器播放回调。
  final VoidCallback? onPlayExternal;

  /// 该剧集对应的最新观看记录（用于底边进度条与状态徽标）。
  final PlaybackRecord? playback;

  /// 右键快捷标为已看回调（为空时右键直接打开编号微调）。
  final VoidCallback? onMarkCompleted;

  /// 所属作品标题（用于单一正片视频占位回退）。
  final String? workTitle;

  /// 所属作品媒体类型（用于识别 movie 单一正片免序号前缀）。
  final TmdbMediaType? workMediaType;

  /// 所属作品正片总集数（仅 1 集且集号<=1 时免 `01 ·` 前缀）。
  final int? mainEpisodeCount;

  /// 外部覆盖展示标题（例如 CD 附带特典映像拼接清洗后专辑短名）。
  final String? displayTitleOverride;

  /// 是否展示原始视频文件名（联动设置「显示原始视频文件名」开关）。
  final bool showRawFileName;

  @override
  State<EpisodeDrawerCard> createState() => _EpisodeDrawerCardState();
}

class _EpisodeDrawerCardState extends State<EpisodeDrawerCard> {
  bool _hovered = false;

  Future<void> _handleSecondaryTap(TapUpDetails details) async {
    final hasAnyMenuAction =
        widget.onMarkCompleted != null ||
        widget.onPlayBuiltin != null ||
        widget.onPlayExternal != null;
    if (!hasAnyMenuAction) {
      widget.onAdjustSlot();
      return;
    }
    final isCompleted = widget.playback?.isCompleted ?? false;
    final pos = RelativeRect.fromLTRB(
      details.globalPosition.dx,
      details.globalPosition.dy,
      details.globalPosition.dx,
      details.globalPosition.dy,
    );
    final action = await showMenu<String>(
      context: context,
      position: pos,
      items: [
        if (widget.onPlayBuiltin != null)
          const PopupMenuItem<String>(
            value: 'builtin',
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.smart_display_outlined, size: 17),
                SizedBox(width: 8),
                Text('使用内置播放器播放'),
              ],
            ),
          ),
        if (widget.onPlayExternal != null)
          const PopupMenuItem<String>(
            value: 'external',
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.open_in_new_rounded, size: 17),
                SizedBox(width: 8),
                Text('使用外部播放器播放'),
              ],
            ),
          ),
        if (!isCompleted && widget.onMarkCompleted != null)
          const PopupMenuItem<String>(
            value: 'complete',
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.check_circle_outline_rounded, size: 17),
                SizedBox(width: 8),
                Text('标为已看'),
              ],
            ),
          ),
        const PopupMenuItem<String>(
          value: 'adjust',
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.tune_rounded, size: 17),
              SizedBox(width: 8),
              Text('微调季集号 / 分类'),
            ],
          ),
        ),
      ],
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'builtin':
        widget.onPlayBuiltin?.call();
      case 'external':
        widget.onPlayExternal?.call();
      case 'complete':
        widget.onMarkCompleted?.call();
      case 'adjust':
        widget.onAdjustSlot();
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final ep = widget.episode;
    final playback = widget.playback;
    final primaryVariant =
        widget.variants.isNotEmpty ? widget.variants.first : null;
    final hasStill = ep.stillPath != null && ep.stillPath!.isNotEmpty;
    final thumbPath = hasStill
        ? ep.stillPath!
        : (widget.fallbackBackdropPath ?? '');
    final overrideTitle = widget.displayTitleOverride?.trim();
    final displayTitle = (overrideTitle != null && overrideTitle.isNotEmpty)
        ? overrideTitle
        : EpisodeTitleFormatter.formatCardTitle(
            episode: ep,
            workTitle: widget.workTitle,
            workMediaType: widget.workMediaType,
            mainEpisodeCount: widget.mainEpisodeCount,
          );

    final hasProgressBadge =
        playback != null && (playback.isCompleted || playback.positionSeconds > 0);
    final progressRatio = playback?.progressRatio ?? 0.0;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        onSecondaryTapUp: _handleSecondaryTap,
        child: SizedBox(
          width: 244,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                curve: Curves.easeOutCubic,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: Colors.white.withValues(
                      alpha: _hovered ? 0.36 : 0.16,
                    ),
                    width: 1,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.28),
                      blurRadius: 14,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(11),
                  child: AspectRatio(
                    aspectRatio: 16 / 9,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        thumbPath.isNotEmpty
                            ? ManagedImage(
                                thumbPath,
                                loader: widget.imageLoader,
                                owner: ep.workId,
                                artwork: hasStill
                                    ? ManagedArtwork.still
                                    : ManagedArtwork.backdrop,
                                fit: BoxFit.cover,
                              )
                            : Container(
                                color: Colors.black.withValues(alpha: 0.35),
                                alignment: Alignment.center,
                                child: Icon(
                                  Icons.play_circle_outline_rounded,
                                  size: 32,
                                  color: Colors.white.withValues(alpha: 0.72),
                                ),
                              ),
                        if (hasProgressBadge)
                          Positioned(
                            top: 6,
                            right: 6,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 7,
                                vertical: 2.5,
                              ),
                              decoration: BoxDecoration(
                                color: playback.isCompleted
                                    ? p.success.withValues(alpha: 0.90)
                                    : Colors.black.withValues(alpha: 0.65),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (playback.isCompleted) ...[
                                    const Icon(
                                      Icons.check_rounded,
                                      size: 11,
                                      color: Colors.white,
                                    ),
                                    const SizedBox(width: 3),
                                  ],
                                  Text(
                                    playback.isCompleted
                                        ? '已看'
                                        : PlaybackRecord.formatClock(
                                            playback.positionSeconds,
                                          ),
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 10.5,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        if (progressRatio > 0)
                          Positioned(
                            left: 0,
                            right: 0,
                            bottom: 0,
                            height: 3,
                            child: Container(
                              color: Colors.black.withValues(alpha: 0.48),
                              alignment: Alignment.centerLeft,
                              child: FractionallySizedBox(
                                widthFactor: progressRatio,
                                child: Container(
                                  color: playback!.isCompleted
                                      ? p.success
                                      : p.accent,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: EllipsisTextWithTooltip(
                      text: displayTitle,
                      maxLines: 1,
                      style: KonataTheme.detailTextStyle(
                        palette: p,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  EpisodeCategoryBadge(isSpecial: ep.isSpecial),
                  if (widget.variants.length >= 2) ...[
                    const SizedBox(width: 6),
                    _FrostedMiniBadge(
                      label: '${widget.variants.length}版本',
                      isWarning: true,
                    ),
                  ],
                ],
              ),
              if (widget.showRawFileName && primaryVariant != null) ...[
                const SizedBox(height: 3),
                Tooltip(
                  message: primaryVariant.relativePath,
                  child: Text(
                    MediaDisplayFormatter.formatWrappableFileName(
                      primaryVariant.fileName,
                    ),
                    softWrap: true,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: KonataTheme.detailTextStyle(
                      palette: p,
                      color: KonataTheme.detailSecondaryTextColor(p),
                      fontSize: 12,
                      fontWeight: FontWeight.w400,
                      height: 1.3,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _FrostedMiniBadge extends StatelessWidget {
  const _FrostedMiniBadge({required this.label, this.isWarning = false});

  final String label;
  final bool isWarning;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final tintColor = isWarning ? p.warningBadge.bg : p.softFill;
    final borderColor = isWarning ? p.warningBadge.border : p.hairline;
    final fgColor = isWarning ? p.warningBadge.fg : p.textPrimary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: tintColor,
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: borderColor, width: 0.6),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: fgColor,
          fontSize: 10,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
