import 'package:engine_scraping/engine_scraping.dart';
import 'package:flutter/widgets.dart';
import 'package:konata_contracts/konata_contracts.dart'
    show EpisodeTitleFormatter;
import 'package:konata_design_system/konata_design_system.dart';

import '../data/media_display_formatter.dart';
import '../state/detail_supplementary_view_data.dart';
import 'detail_artwork_view.dart';

/// 详情页底部抽屉与完整选集页共用的 `16:9` 单集 / 特典卡片。
class EpisodeDrawerCard extends StatefulWidget {
  /// 创建分集展示卡片。
  const EpisodeDrawerCard({
    super.key,
    required this.episode,
    required this.variants,
    required this.imageLoader,
    required this.onTap,
    this.playback,
    this.workTitle,
    this.workMediaType,
    this.mainEpisodeCount,
    this.showSeasonPrefix = false,
    this.showStillThumbnail = true,
    this.showOriginalFileName = true,
    this.workBackdropFallbackPath,
    this.workPosterFallbackPath,
    this.workPosterOwnerId,
    this.onDarkBackdrop = true,
    this.cardWidth = 228.0,
    this.onShowMediaInfo,
  });

  /// 目标逻辑剧集或特典条目。
  final Episode episode;

  /// 关联的物理文件版本列表。
  final List<MediaVariant> variants;

  /// 受管图片加载器。
  final ManagedImageLoader imageLoader;

  /// 点击卡片播放或选版本回调。
  final VoidCallback onTap;

  /// 该集最新播放记录（用于进度条与完播徽标）。
  final PlaybackRecord? playback;

  /// 所属作品标题（单剧场版标题兜底）。
  final String? workTitle;

  /// 所属作品 `TMDB` 媒体类型。
  final TmdbMediaType? workMediaType;

  /// 正片总集数（控制单正片免除 `01 ·` 前缀）。
  final int? mainEpisodeCount;

  /// 多季合并展示时是否附带 `S1E01` 前缀。
  final bool showSeasonPrefix;

  /// 是否显示单集剧照缩略图。
  final bool showStillThumbnail;

  /// 是否在卡片下方显示原始物理文件名。
  final bool showOriginalFileName;

  /// 无单集剧照时用于兜底的作品背景图路径。
  final String? workBackdropFallbackPath;

  /// 无背景图时兜底的竖版海报路径。
  final String? workPosterFallbackPath;

  /// 回落图归属作品主键。
  final String? workPosterOwnerId;

  /// 是否位于暗色背景舞台之上。
  final bool onDarkBackdrop;

  /// 卡片逻辑宽度。
  final double cardWidth;

  /// 右键或长按弹出媒体参数详情弹窗回调。
  final VoidCallback? onShowMediaInfo;

  @override
  State<EpisodeDrawerCard> createState() => _EpisodeDrawerCardState();
}

class _EpisodeDrawerCardState extends State<EpisodeDrawerCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final ep = widget.episode;
    final title = EpisodeTitleFormatter.formatCardTitle(
      episode: DetailSupplementaryHelper.toEpisodeSummaryView(ep),
      workTitle: widget.workTitle,
      workMediaType: widget.workMediaType,
      mainEpisodeCount: widget.mainEpisodeCount,
      showSeasonPrefix: widget.showSeasonPrefix,
    );
    final primaryVariant = widget.variants.isNotEmpty
        ? widget.variants.first
        : null;
    final progress = MediaDisplayFormatter.computeProgressFraction(
      widget.playback,
    );
    final hasWatched = widget.playback?.isCompleted ?? false;
    final position = widget.playback?.positionSeconds ?? 0;
    final borderColor = _hovered
        ? KonataPlaybackTokens.activeGlassBorder(p)
        : KonataPlaybackTokens.glassBorder(p);

    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.15,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onTap,
          onSecondaryTap: widget.onShowMediaInfo,
          onLongPress: widget.onShowMediaInfo,
          child: SizedBox(
            width: widget.cardWidth,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedContainer(
                  duration: KonataTheme.motionFast,
                  curve: Curves.easeOutCubic,
                  decoration: BoxDecoration(
                    borderRadius: KonataTheme.borderRadiusCard,
                    border: Border.all(
                      color: borderColor,
                      width: _hovered ? 1.3 : 0.9,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: KonataPlaybackTokens.shadowColor(p),
                        blurRadius: _hovered ? 16 : 10,
                        offset: const Offset(0, 5),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: KonataTheme.borderRadiusTile,
                    child: AspectRatio(
                      aspectRatio: 16 / 9,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          _buildThumbnail(p),
                          if (_hovered)
                            const IgnorePointer(
                              child: ColoredBox(
                                color: KonataTheme.scrimBlackLight,
                              ),
                            ),
                          if (widget.variants.length > 1 ||
                              ep.category == EpisodeCategory.extra)
                            Positioned(
                              top: 6,
                              left: 6,
                              child: _CardMiniBadge(
                                label: widget.variants.length > 1
                                    ? '${widget.variants.length} 版本'
                                    : '特典',
                                accentColor: widget.variants.length > 1
                                    ? p.accent
                                    : KonataTheme.specVideoPurple,
                              ),
                            ),
                          if (hasWatched || position > 0)
                            Positioned(
                              top: 6,
                              right: 6,
                              child: Container(
                                key: const ValueKey('episode_playback_badge'),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 7,
                                  vertical: 2.5,
                                ),
                                decoration: BoxDecoration(
                                  color: hasWatched
                                      ? p.success.withValues(alpha: 0.90)
                                      : KonataTheme.scrimBlackDense,
                                  borderRadius: KonataTheme.borderRadiusChip,
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (hasWatched) ...[
                                      const Icon(
                                        Icons.check_rounded,
                                        size: 11,
                                        color: KonataTheme.pureWhite,
                                      ),
                                      const SizedBox(width: 3),
                                    ],
                                    Text(
                                      hasWatched
                                          ? '已看'
                                          : MediaDisplayFormatter.formatDurationSeconds(
                                              position,
                                            ),
                                      style: const TextStyle(
                                        color: KonataTheme.pureWhite,
                                        fontSize: KonataTheme.fontSizeBadge,
                                        fontWeight: FontWeight.w600,
                                        height: 1.2,
                                        leadingDistribution:
                                            TextLeadingDistribution.even,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          if (!KonataAdaptiveTokens.isAndroid && _hovered)
                            Center(
                              child: Container(
                                width: 38,
                                height: 38,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: KonataTheme.scrimBlackDense,
                                  border: Border.all(
                                    color: KonataTheme.overlayWhiteBorderStrong,
                                  ),
                                ),
                                alignment: Alignment.center,
                                child: const Icon(
                                  Icons.play_arrow_rounded,
                                  size: 22,
                                  color: KonataTheme.pureWhite,
                                ),
                              ),
                            ),
                          if (progress > 0)
                            Positioned(
                              left: 0,
                              right: 0,
                              bottom: 0,
                              height: 3,
                              child: Container(
                                key: const ValueKey(
                                  'episode_playback_progress',
                                ),
                                color: KonataTheme.scrimBlackStrong,
                                alignment: Alignment.centerLeft,
                                child: FractionallySizedBox(
                                  widthFactor: progress,
                                  heightFactor: 1,
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      color: hasWatched
                                          ? p.success
                                          : KonataTheme.pureWhite,
                                      boxShadow: [
                                        BoxShadow(
                                          color:
                                              (hasWatched
                                                      ? p.success
                                                      : KonataTheme.pureWhite)
                                                  .withValues(alpha: 0.45),
                                          blurRadius: 6,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: EllipsisTextWithTooltip(
                        text: title,
                        maxLines: 1,
                        style: KonataTheme.detailTextStyle(
                          palette: p,
                          color: (widget.onDarkBackdrop || p.isDark)
                              ? (_hovered
                                    ? KonataTheme.pureWhite
                                    : KonataTheme.overlayWhiteTextStrong)
                              : p.textPrimary,
                          fontSize: KonataTheme.fontSizeBodyXs,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (widget.onShowMediaInfo != null)
                      GestureDetector(
                        onTap: widget.onShowMediaInfo,
                        child: Padding(
                          padding: const EdgeInsets.only(left: 4),
                          child: Icon(
                            Icons.info_outline_rounded,
                            size: 14,
                            color: (widget.onDarkBackdrop || p.isDark)
                                ? KonataTheme.overlayWhiteTextSub
                                : p.textMuted,
                          ),
                        ),
                      ),
                  ],
                ),
                if (widget.showOriginalFileName && primaryVariant != null) ...[
                  const SizedBox(height: 1.5),
                  EllipsisTextWithTooltip(
                    text: MediaDisplayFormatter.formatWrappableFileName(
                      primaryVariant.fileName,
                    ),
                    maxLines: 1,
                    style: KonataTheme.detailTextStyle(
                      palette: p,
                      color: (widget.onDarkBackdrop || p.isDark)
                          ? KonataTheme.overlayWhiteTextSub
                          : p.textSecondary,
                      fontSize: KonataTheme.fontSizeCaptionXs,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildThumbnail(KonataPalette p) {
    final still = widget.episode.stillPath?.trim() ?? '';
    if (widget.showStillThumbnail && still.isNotEmpty) {
      return DetailManagedImage(
        still,
        loader: widget.imageLoader,
        owner: widget.episode.workId,
        artwork: ManagedArtwork.still,
        imageSize: TmdbImageSize.w500,
        decodeWidth: 640,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => _buildFallbackSurface(p),
      );
    }
    return _buildFallbackSurface(p);
  }

  Widget _buildFallbackSurface(KonataPalette p) {
    final bg = widget.workBackdropFallbackPath?.trim() ?? '';
    if (bg.isNotEmpty) {
      return DetailManagedImage(
        bg,
        loader: widget.imageLoader,
        owner: widget.workPosterOwnerId ?? widget.episode.workId,
        artwork: ManagedArtwork.backdrop,
        imageSize: TmdbImageSize.w780,
        decodeWidth: 640,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => _buildPosterOrNeutralFallback(p),
      );
    }
    return _buildPosterOrNeutralFallback(p);
  }

  Widget _buildPosterOrNeutralFallback(KonataPalette p) {
    final poster = widget.workPosterFallbackPath?.trim() ?? '';
    if (poster.isNotEmpty) {
      final owner = widget.workPosterOwnerId ?? widget.episode.workId;
      return KonataCoverAlignmentBuilder(
        url: poster,
        loader: detailArtworkLoader(
          widget.imageLoader,
          owner: owner,
          imageSize: TmdbImageSize.w342,
        ),
        owner: owner,
        isPosterFallback: true,
        targetAspectRatio: 16 / 9,
        builder: (_, align) => Stack(
          fit: StackFit.expand,
          children: [
            DetailManagedImage(
              poster,
              loader: widget.imageLoader,
              owner: owner,
              artwork: ManagedArtwork.poster,
              imageSize: TmdbImageSize.w500,
              decodeWidth: 512,
              fit: BoxFit.cover,
              alignment: align,
              errorBuilder: (_, _, _) => _neutralPlaceholder(p),
            ),
            ColoredBox(
              color: KonataTheme.cinemaObsidian.withValues(alpha: 0.28),
            ),
          ],
        ),
      );
    }
    return _neutralPlaceholder(p);
  }

  Widget _neutralPlaceholder(KonataPalette p) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: (widget.onDarkBackdrop || p.isDark)
            ? KonataTheme.cinemaObsidian.withValues(alpha: 0.72)
            : p.softFill,
      ),
      child: Center(
        child: Icon(
          Icons.movie_outlined,
          size: 26,
          color: p.textMuted.withValues(alpha: 0.55),
        ),
      ),
    );
  }
}

class _CardMiniBadge extends StatelessWidget {
  const _CardMiniBadge({required this.label, required this.accentColor});

  final String label;
  final Color accentColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6.5, vertical: 2),
      decoration: BoxDecoration(
        color: KonataTheme.scrimBlackDense,
        borderRadius: KonataTheme.borderRadiusChip,
        border: Border.all(
          color: accentColor.withValues(alpha: 0.65),
          width: 0.8,
        ),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: KonataTheme.pureWhite,
          fontSize: KonataTheme.fontSizeBadge,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
