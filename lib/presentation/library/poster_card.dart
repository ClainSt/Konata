import 'package:flutter/material.dart';

import '../../application/providers/library_providers.dart';
import '../theme/konata_palette.dart';
import '../widgets/design_system/ellipsis_text_with_tooltip.dart';
import '../widgets/managed_image.dart';
import '../theme/konata_theme.dart';

/// 高密度海报墙单卡组件（圆角 10px + 悬停 1.03x 微缩放，零实时 BackdropFilter）。
class PosterCard extends StatefulWidget {
  /// 创建海报卡片。
  const PosterCard({
    super.key,
    required this.item,
    required this.imageLoader,
    required this.onTap,
  });

  /// 作品聚合视图模型。
  final WorkLibraryItem item;

  /// TMDB 图片加载器。
  final ManagedImageLoader imageLoader;

  /// 点击卡片进入详情页。
  final VoidCallback onTap;

  @override
  State<PosterCard> createState() => _PosterCardState();
}

class _PosterCardState extends State<PosterCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final work = widget.item.work;
    final subParts = <String>[
      if (work.year != null) '${work.year}',
      if (widget.item.episodeCount > 0) '${widget.item.episodeCount} 话',
    ];
    final subtitle = subParts.isEmpty ? '待完善元数据' : subParts.join(' · ');

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: AnimatedScale(
                scale: _hovered ? 1.03 : 1.0,
                duration: KonataTheme.motionMedium,
                curve: Curves.easeOutCubic,
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: KonataTheme.borderRadiusControl,
                    color: p.surface,
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (work.posterPath != null &&
                          work.posterPath!.isNotEmpty)
                        ManagedImage(
                          work.posterPath!,
                          loader: widget.imageLoader,
                          owner: work.id,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) =>
                              _PosterFallback(title: work.title),
                        )
                      else
                        _PosterFallback(title: work.title),
                      // 海报外缘内嵌 1px 微光细边
                      Positioned.fill(
                        child: IgnorePointer(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              borderRadius: KonataTheme.borderRadiusControl,
                              border: Border.all(
                                color: _hovered ? p.hoverBorder : p.posterBorder,
                                width: 1,
                              ),
                            ),
                          ),
                        ),
                      ),
                      if (widget.item.hasMultiVariants)
                        Positioned(
                          top: 8,
                          right: 8,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 7,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: p.glassOverlay,
                              borderRadius: KonataTheme.borderRadiusChip,
                              border: Border.all(color: p.posterBorder),
                            ),
                            child: Text(
                              '${widget.item.maxEpisodeVariantCount}版本',
                              style: TextStyle(
                                color: p.textPrimary,
                                fontSize: KonataTheme.fontSizeBadge,
                                fontWeight: FontWeight.w600,
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
            SizedBox(
              width: double.infinity,
              child: EllipsisTextWithTooltip(
                text: work.title,
                maxLines: 1,
                style: TextStyle(
                  color: p.textPrimary,
                  fontSize: KonataTheme.fontSizeBody,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(height: 2),
            Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: p.textSecondary,
                fontSize: KonataTheme.fontSizeCaptionSm,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PosterFallback extends StatelessWidget {
  const _PosterFallback({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      color: p.softFill,
      padding: const EdgeInsets.all(14),
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.movie_filter_outlined,
            size: 28,
            color: p.textMuted,
          ),
          const SizedBox(height: 8),
          Text(
            title,
            maxLines: 3,
            textAlign: TextAlign.center,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: p.textSecondary,
              fontSize: KonataTheme.fontSizeCaption,
            ),
          ),
        ],
      ),
    );
  }
}
