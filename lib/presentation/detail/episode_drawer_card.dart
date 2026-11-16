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

const List<Shadow> _kDrawerOverlayTextShadows = [
  Shadow(color: Color(0xA6000000), blurRadius: 8, offset: Offset(0, 1.5)),
];

/// 详情页底部抽屉与完整列表共用的单集卡片（展示 16:9 剧照、进度条、集数标题、多版本徽章与文件名）。
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
    this.onDarkBackdrop = true,
  });

  final Episode episode;
  final List<MediaVariant> variants;
  final String? fallbackBackdropPath;
  final ManagedImageLoader imageLoader;
  final VoidCallback onTap;
  final VoidCallback onAdjustSlot;
  final VoidCallback? onPlayBuiltin;
  final VoidCallback? onPlayExternal;
  final PlaybackRecord? playback;
  final VoidCallback? onMarkCompleted;
  final String? workTitle;
  final TmdbMediaType? workMediaType;
  final int? mainEpisodeCount;
  final String? displayTitleOverride;
  final bool showRawFileName;

  /// 是否直接叠放于详情页底部原画暗角之上（完整列表弹窗传 `false` 以适配亮/暗双主题面板）。
  final bool onDarkBackdrop;

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
    final primaryVariant = widget.variants.isNotEmpty
        ? widget.variants.first
        : null;
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
        playback != null &&
        (playback.isCompleted || playback.positionSeconds > 0);
    final progressRatio = playback?.progressRatio ?? 0.0;

    final useDarkOverlayStyle = widget.onDarkBackdrop || p.isDark;
    final effectiveMetaPalette = useDarkOverlayStyle ? KonataPalette.dark : p;
    final titleColor = useDarkOverlayStyle ? Colors.white : p.textPrimary;
    final fileNameColor = useDarkOverlayStyle
        ? Colors.white.withValues(alpha: 0.80)
        : p.textSecondary;
    final metaShadows = widget.onDarkBackdrop
        ? _kDrawerOverlayTextShadows
        : const <Shadow>[];
    final frameBorderColor = useDarkOverlayStyle
        ? Colors.white.withValues(alpha: _hovered ? 0.36 : 0.16)
        : const Color(0xFF0F172A).withValues(alpha: _hovered ? 0.28 : 0.12);

    Widget metaSection = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: EllipsisTextWithTooltip(
                text: displayTitle,
                maxLines: 1,
                style: KonataTheme.detailTextStyle(
                  palette: effectiveMetaPalette,
                  color: titleColor,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ).copyWith(shadows: metaShadows),
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
                palette: effectiveMetaPalette,
                color: fileNameColor,
                fontSize: 12,
                fontWeight: FontWeight.w400,
                height: 1.3,
              ).copyWith(shadows: metaShadows),
            ),
          ),
        ],
      ],
    );

    if (widget.onDarkBackdrop && !p.isDark) {
      metaSection = Theme(data: KonataTheme.darkTheme(), child: metaSection);
    }

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
                  border: Border.all(color: frameBorderColor, width: 1),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(
                        alpha: useDarkOverlayStyle ? 0.28 : 0.12,
                      ),
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
              metaSection,
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
        border: Border.all(color: borderColor, width: 0.8),
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
