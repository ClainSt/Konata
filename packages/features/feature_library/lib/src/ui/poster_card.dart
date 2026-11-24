import 'package:engine_scraping/engine_scraping.dart';
import 'package:flutter/widgets.dart';
import 'package:konata_design_system/konata_design_system.dart';

import '../data/library_models.dart';
import '../providers.dart';
import 'managed_image.dart';

/// 2:3 番剧海报墙核心卡片组件（集成惰性悬停缩放、无毛玻璃静止降载与防误触工具提示）。
///
/// 遵循高速滚动性能契约：
/// - 仅在鼠标悬停且 [suppressHoverCheck] 返回 `false` 时惰性分配 `AnimationController`；
/// - 评分微标毛玻璃效果（`BackdropFilter`）仅在激活悬停瞬间开启，静止网格零模糊层开销；
/// - 海报内存解码宽度按卡片几何与 DPR 吸附分档，避免全屏大图挤爆纹理池。
class PosterCard extends StatefulWidget {
  /// 创建番剧海报卡片。
  const PosterCard({
    super.key,
    required this.item,
    required this.cardWidth,
    this.devicePixelRatio = 1.0,
    this.textScaler = TextScaler.noScaling,
    this.suppressHoverCheck,
    this.imageLoaderOverride,
    required this.onTap,
    this.onOpenMenu,
  });

  /// 聚合后的媒体库作品条目。
  final WorkLibraryItem item;

  /// 当前网格列分配的卡片逻辑宽度。
  final double cardWidth;

  /// 外层提前缓存的屏幕像素密度（避免在海量 `itemBuilder` 中高频查 `MediaQuery`）。
  final double devicePixelRatio;

  /// 外层提前缓存的字体缩放器。
  final TextScaler textScaler;

  /// 返回 `true` 时表示列表处于高速滚动冷却期，禁止激活动效与延迟 Tooltip。
  final bool Function()? suppressHoverCheck;

  /// 可选图像字节加载覆盖回调（主要用于测试注入）。
  final LibraryArtworkLoader? imageLoaderOverride;

  /// 点击海报卡片跳转到作品详情页的回调。
  final VoidCallback onTap;

  /// 可选右键/更多操作菜单呼出回调。
  final ValueChanged<BuildContext>? onOpenMenu;

  @override
  State<PosterCard> createState() => _PosterCardState();
}

class _PosterCardState extends State<PosterCard> {
  bool _hovered = false;

  void _handleHoverChanged(bool hovered) {
    final suppressed = widget.suppressHoverCheck?.call() ?? false;
    final effective = hovered && !suppressed;
    if (_hovered == effective) return;
    setState(() => _hovered = effective);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final work = widget.item.work;
    final score = work.bangumiScore ?? work.voteAverage;
    final decodeWidth = quantizeManagedImageWidth(
      widget.cardWidth,
      widget.devicePixelRatio,
    );
    final showOriginal = MediaDisplayFormatter.shouldShowOriginalSubtitle(
      title: work.title,
      originalTitle: work.originalTitle,
    );
    final subtitleText = _buildSubtitleText(work);
    final compactCard = widget.cardWidth < 136;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => _handleHoverChanged(true),
      onHover: (_) => _handleHoverChanged(true),
      onExit: (_) => _handleHoverChanged(false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        onLongPress: widget.onOpenMenu == null
            ? null
            : () => widget.onOpenMenu!(context),
        onSecondaryTapDown: widget.onOpenMenu == null
            ? null
            : (_) => widget.onOpenMenu!(context),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            AspectRatio(
              aspectRatio: 2 / 3,
              child: _LazyHoverScale(
                hovered: _hovered,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(KonataTheme.radiusCard),
                    border: Border.all(
                      color: _hovered ? p.hoverBorder : p.posterBorder,
                      width: _hovered ? 1.4 : 1.0,
                    ),
                    boxShadow: _hovered
                        ? [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.28),
                              blurRadius: 16,
                              offset: const Offset(0, 8),
                            ),
                          ]
                        : const <BoxShadow>[],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(KonataTheme.radiusCard),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        ManagedImage(
                          path: work.posterPath ?? work.bangumiPosterPath,
                          targetWidth: decodeWidth,
                          imageSize: TmdbImageSize.w500,
                          ownerWorkId: work.id,
                          subfolder: PhotoSubfolder.posters,
                          imageLoaderOverride: widget.imageLoaderOverride,
                          errorWidget: _FallbackPosterPlaceholder(
                            title: work.title,
                          ),
                        ),
                        if (score != null && score > 0)
                          Positioned(
                            top: 8,
                            left: 8,
                            child: BangumiScoreWordmarkBadge(
                              score: score,
                              wordmarkHeight: compactCard ? 10.5 : 12.5,
                              enableBackdropBlur: _hovered,
                            ),
                          ),
                        if (widget.item.crossSourceBadgeLabel != null)
                          Positioned(
                            top: 8,
                            right: 8,
                            child: _SourceTagChip(
                              label: widget.item.crossSourceBadgeLabel!,
                            ),
                          ),
                        if (widget.item.episodeCount > 0)
                          Positioned(
                            right: 8,
                            bottom: 8,
                            child: _EpisodeCountChip(
                              count: widget.item.episodeCount,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            EllipsisTextWithTooltip(
              text: work.title,
              maxLines: 1,
              maxWidth: widget.cardWidth,
              textScaler: widget.textScaler,
              deferTooltipToHover: true,
              suppressHoverCheck: widget.suppressHoverCheck,
              style: TextStyle(
                fontSize: compactCard ? 12.5 : 13.5,
                fontWeight: FontWeight.w600,
                color: p.textPrimary,
                height: 1.25,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              showOriginal && subtitleText.isEmpty
                  ? (work.originalTitle?.trim() ?? '')
                  : subtitleText,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11.5,
                color: p.textMuted,
                height: 1.2,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _buildSubtitleText(Work work) {
    final parts = <String>[
      if (work.year != null && work.year! > 0) '${work.year}',
      if (widget.item.releaseGroups.isNotEmpty) widget.item.releaseGroups.first,
    ];
    return parts.join(' · ');
  }
}

/// 懒初始化悬停微浮起容器：未发生真实悬停前绝不分配 `AnimationController` 与 `Ticker`。
class _LazyHoverScale extends StatefulWidget {
  const _LazyHoverScale({
    required this.hovered,
    required this.child,
  });

  final bool hovered;
  final Widget child;

  @override
  State<_LazyHoverScale> createState() => _LazyHoverScaleState();
}

class _LazyHoverScaleState extends State<_LazyHoverScale>
    with SingleTickerProviderStateMixin {
  AnimationController? _controller;
  Animation<double>? _scale;

  @override
  void didUpdateWidget(covariant _LazyHoverScale oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.hovered == oldWidget.hovered) return;
    if (widget.hovered) {
      final ctrl =
          _controller ??= AnimationController(
            vsync: this,
            duration: const Duration(milliseconds: 140),
          );
      _scale ??= Tween<double>(begin: 1.0, end: 1.028).animate(
        CurvedAnimation(parent: ctrl, curve: Curves.easeOutCubic),
      );
      ctrl.forward();
    } else {
      _controller?.reverse();
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scale = _scale;
    if (scale == null) return widget.child;
    return ScaleTransition(
      scale: scale,
      child: widget.child,
    );
  }
}

class _FallbackPosterPlaceholder extends StatelessWidget {
  const _FallbackPosterPlaceholder({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      color: p.elevatedSurface,
      padding: const EdgeInsets.all(12),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.local_movies_outlined, size: 30, color: p.textMuted),
          const SizedBox(height: 8),
          Text(
            title,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: p.textSecondary,
              height: 1.35,
            ),
          ),
        ],
      ),
    );
  }
}

class _SourceTagChip extends StatelessWidget {
  const _SourceTagChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 88),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.68),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w600,
          color: Colors.white,
        ),
      ),
    );
  }
}

class _EpisodeCountChip extends StatelessWidget {
  const _EpisodeCountChip({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.68),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
      ),
      child: Text(
        '$count 话',
        style: const TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w600,
          color: Colors.white,
        ),
      ),
    );
  }
}
