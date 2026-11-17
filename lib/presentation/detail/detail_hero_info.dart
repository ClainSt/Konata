import 'dart:ui';

import 'package:flutter/material.dart';

import '../../application/providers/library_providers.dart';
import '../../domain/formatting/media_display_formatter.dart';
import '../../domain/matching/playback_resume_resolver.dart';
import '../../domain/models/episode.dart';
import '../../domain/models/tmdb_models.dart';
import '../../domain/models/work.dart';
import '../theme/konata_adaptive_tokens.dart';
import '../theme/konata_palette.dart';
import '../theme/konata_playback_tokens.dart';
import '../theme/konata_theme.dart';
import '../widgets/managed_image.dart';
import 'inline_expandable_synopsis.dart';
import 'work_review_banner.dart';

const List<Shadow> _kHeroBackdropTextShadows = [
  Shadow(color: Color(0x8C000000), blurRadius: 12, offset: Offset(0, 2)),
];

/// 详情页左侧透明标题 Logo、单行元信息与唯一主播放按钮。
class DetailHeroInfo extends StatelessWidget {
  /// 创建详情主视觉信息区。
  const DetailHeroInfo({
    super.key,
    required this.bundle,
    required this.imageLoader,
    required this.onPrimaryPlay,
    this.showTitleText = true,
    this.showTitleLogo = false,
    this.showOverview = true,
    this.onManualMatch,
    this.onDismissReview,
  });

  /// 作品详情聚合数据包。
  final WorkDetailBundle bundle;

  /// 图片加载器。
  final ManagedImageLoader imageLoader;

  /// 点击唯一主按钮回调。
  final VoidCallback? onPrimaryPlay;

  /// 是否展示文字标题与副标题原名。
  final bool showTitleText;

  /// 是否展示透明标题徽标（Logo）。
  final bool showTitleLogo;

  /// 是否展示作品简介正文与展开控制。
  final bool showOverview;

  /// 从待复核横幅快速打开手动匹配弹窗回调。
  final VoidCallback? onManualMatch;

  /// 从待复核横幅忽略复核提示回调。
  final VoidCallback? onDismissReview;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final work = bundle.work;
    final mainEpisodes = bundle.episodes
        .where((e) => e.category == EpisodeCategory.main)
        .toList();

    final metaParts = <String>[
      if (work.year != null) '${work.year}',
      if (mainEpisodes.isNotEmpty) '${mainEpisodes.length} 话',
      if (work.bangumiScore != null && work.bangumiScore! > 0)
        'Bangumi ${work.bangumiScore!.toStringAsFixed(1)}',
    ];

    final resumePlan = PlaybackResumeResolver.resolve(
      episodes: bundle.episodes,
      latestPlayback: bundle.latestPlayback,
      playbackByEpisodeId: bundle.playbackByEpisodeId,
      workTitle: work.title,
      workMediaType: work.tmdbMediaType,
    );
    final buttonLabel = resumePlan?.buttonLabel ?? '开始播放';

    final hasLogo = work.logoPath != null && work.logoPath!.trim().isNotEmpty;
    final renderLogo = showTitleLogo && hasLogo;
    final renderTextTitle = showTitleText || (showTitleLogo && !hasLogo);
    final hasTitleSection = renderLogo || renderTextTitle;
    final hasOverview =
        showOverview &&
        work.overview != null &&
        work.overview!.trim().isNotEmpty;
    final hasHeaderContent =
        hasTitleSection || metaParts.isNotEmpty || hasOverview;

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 520),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (renderLogo)
            DecoratedBox(
              decoration: BoxDecoration(
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.38),
                    blurRadius: 28,
                    spreadRadius: -8,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: 360,
                  maxHeight: 110,
                ),
                child: ManagedImage(
                  work.logoPath!,
                  loader: imageLoader,
                  owner: work.id,
                  artwork: ManagedArtwork.logo,
                  imageSize: TmdbImageSize.original,
                  fit: BoxFit.contain,
                  alignment: Alignment.centerLeft,
                  errorBuilder: (_, _, _) => showTitleText
                      ? const SizedBox.shrink()
                      : _FallbackTitleBlock(
                          title: work.title,
                          originalTitle: work.originalTitle,
                        ),
                ),
              ),
            ),
          if (renderLogo && renderTextTitle) const SizedBox(height: 10),
          if (renderTextTitle)
            _FallbackTitleBlock(
              title: work.title,
              originalTitle: work.originalTitle,
            ),
          if (metaParts.isNotEmpty) ...[
            if (hasTitleSection) const SizedBox(height: 12),
            Text(
              metaParts.join(' · '),
              style: KonataTheme.detailTextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.4,
                palette: p,
                color: Colors.white.withValues(alpha: 0.90),
              ).copyWith(shadows: _kHeroBackdropTextShadows),
            ),
          ],
          if (hasOverview) ...[
            if (hasTitleSection || metaParts.isNotEmpty)
              const SizedBox(height: 12),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 496),
              child: Theme(
                data: KonataTheme.darkTheme(),
                child: InlineExpandableSynopsis(
                  text: work.overview!.trim(),
                  collapsedMaxLines: 3,
                  maxExpandedHeight: 200,
                ),
              ),
            ),
          ],
          if (hasHeaderContent) const SizedBox(height: 22),
          if (work.scrapeStatus == ScrapeStatus.needsReview &&
              onManualMatch != null &&
              onDismissReview != null)
            WorkReviewBanner(
              reviewReason: work.reviewReason,
              onManualMatch: onManualMatch!,
              onDismiss: onDismissReview!,
            ),
          FrostedPlayButton(label: buttonLabel, onPressed: onPrimaryPlay),
        ],
      ),
    );
  }
}

/// 详情页专属高透磨砂毛玻璃播放胶囊主按钮。
class FrostedPlayButton extends StatefulWidget {
  /// 创建毛玻璃播放主按钮。
  const FrostedPlayButton({
    super.key,
    required this.label,
    required this.onPressed,
  });

  /// 按钮主文案（`开始播放` 或 `继续播放`）。
  final String label;

  /// 点击回调。
  final VoidCallback? onPressed;

  @override
  State<FrostedPlayButton> createState() => _FrostedPlayButtonState();
}

class _FrostedPlayButtonState extends State<FrostedPlayButton> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final enabled = widget.onPressed != null;
    final fillColor = KonataPlaybackTokens.heroPlayButtonFill(
      p,
      enabled: enabled,
      hovered: _hovered,
      pressed: _pressed,
    );
    final borderColor = _hovered
        ? KonataPlaybackTokens.activeGlassBorder(p)
        : KonataPlaybackTokens.glassBorder(p);
    final fgColor = KonataTheme.detailPrimaryTextColor(p);

    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() {
        _hovered = false;
        _pressed = false;
      }),
      child: GestureDetector(
        onTap: widget.onPressed,
        onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
        onTapUp: enabled ? (_) => setState(() => _pressed = false) : null,
        onTapCancel: enabled ? () => setState(() => _pressed = false) : null,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            boxShadow: [
              BoxShadow(
                color: KonataPlaybackTokens.shadowColor(p),
                blurRadius: 18,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 140),
                curve: Curves.easeOutCubic,
                constraints: KonataAdaptiveTokens.isAndroid
                    ? const BoxConstraints(
                        minHeight: KonataAdaptiveTokens.touchTarget,
                      )
                    : null,
                padding: const EdgeInsets.symmetric(
                  horizontal: 22,
                  vertical: 11,
                ),
                decoration: BoxDecoration(
                  color: fillColor,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: borderColor, width: 1),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.play_arrow_rounded, size: 20, color: fgColor),
                    const SizedBox(width: 8),
                    Text(
                      widget.label,
                      style: KonataTheme.detailTextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.4,
                        palette: p,
                        color: fgColor,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _FallbackTitleBlock extends StatelessWidget {
  const _FallbackTitleBlock({required this.title, required this.originalTitle});

  final String title;
  final String? originalTitle;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final showOriginal = MediaDisplayFormatter.shouldShowOriginalSubtitle(
      title: title,
      originalTitle: originalTitle,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: KonataTheme.detailTextStyle(
            palette: p,
            color: Colors.white,
            fontSize: 34,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.5,
            height: 1.22,
          ).copyWith(shadows: _kHeroBackdropTextShadows),
        ),
        if (showOriginal) ...[
          const SizedBox(height: 6),
          Text(
            originalTitle!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: KonataTheme.detailTextStyle(
              palette: p,
              color: Colors.white.withValues(alpha: 0.84),
              fontSize: 14,
              fontWeight: FontWeight.w500,
              letterSpacing: 0.3,
            ).copyWith(shadows: _kHeroBackdropTextShadows),
          ),
        ],
      ],
    );
  }
}
