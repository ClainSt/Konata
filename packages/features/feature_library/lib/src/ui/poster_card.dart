import 'package:engine_scraping/engine_scraping.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:konata_design_system/konata_design_system.dart';

import '../data/library_models.dart';
import '../providers.dart';
import 'library_artwork_view.dart';

/// 媒体库作品网格的单张 2:3 海报卡片组件。
class PosterCard extends StatefulWidget {
  /// 创建海报卡片组件。
  const PosterCard({
    super.key,
    required this.item,
    required this.onTap,
    this.cardWidth,
    this.onOpenMenu,
    this.imageLoaderOverride,
    this.suppressHoverCheck,
    this.scrollingListenable,
    this.compactText = false,
    this.badgeFontSize = KonataTheme.fontSizeBadge,
    this.titleFontSize = KonataTheme.fontSizeBody,
    this.subtitleFontSize = KonataTheme.fontSizeCaptionSm,
  });

  /// 媒体库作品展示聚合项。
  final WorkLibraryItem item;

  /// 点击卡片主体跳转详情页回调。
  final VoidCallback onTap;

  /// 外层自适应网格传入的当前列宽提示（可选）。
  final double? cardWidth;

  /// 右键或长按触发管理菜单回调。
  final void Function(BuildContext anchorContext)? onOpenMenu;

  /// 可选图像加载器覆盖（用于测试环境无网注入伪图字节）。
  final LibraryArtworkLoader? imageLoaderOverride;

  /// 快速滚动或后台视频播放期间抑制桌面端悬停状态切换，避免闪烁与无谓模糊合成。
  final bool Function()? suppressHoverCheck;

  /// 滚动冷却由页面持有，仅指针所在的卡片订阅其变化。
  final ValueListenable<bool>? scrollingListenable;

  /// 是否启用手机窄屏紧凑排布尺寸。
  final bool compactText;

  /// 顶角来源与多版本玻璃徽标字号。
  final double badgeFontSize;

  /// 底部主标题字号。
  final double titleFontSize;

  /// 底部年份与话数副标题字号。
  final double subtitleFontSize;

  @override
  State<PosterCard> createState() => _PosterCardState();
}

class _PosterCardState extends State<PosterCard> {
  bool _pointerInside = false;
  bool _hovered = false;

  bool get _resolvedHover =>
      _pointerInside &&
      !(widget.scrollingListenable?.value ?? false) &&
      !(widget.suppressHoverCheck?.call() ?? false);

  void _syncHover() {
    final next = _resolvedHover;
    if (mounted && _hovered != next) {
      setState(() => _hovered = next);
    }
  }

  void _setPointerInside(bool inside) {
    if (_pointerInside != inside) {
      _pointerInside = inside;
      if (inside) {
        widget.scrollingListenable?.addListener(_syncHover);
      } else {
        widget.scrollingListenable?.removeListener(_syncHover);
      }
    }
    _syncHover();
  }

  @override
  void didUpdateWidget(covariant PosterCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_pointerInside &&
        !identical(oldWidget.scrollingListenable, widget.scrollingListenable)) {
      oldWidget.scrollingListenable?.removeListener(_syncHover);
      widget.scrollingListenable?.addListener(_syncHover);
    }
    _hovered = _resolvedHover;
  }

  @override
  void dispose() {
    if (_pointerInside) widget.scrollingListenable?.removeListener(_syncHover);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final work = widget.item.work;
    final score = work.bangumiScore;
    final effectiveHover = _hovered;
    final subtitleText = _buildSubtitleText(work);
    final hasSourceBadge =
        widget.item.crossSourceBadgeLabel != null &&
        widget.item.crossSourceBadgeLabel!.isNotEmpty;
    final hasMultiVersion = widget.item.maxEpisodeVariantCount > 1;
    final posterPath = work.posterPath?.trim();
    final hasPoster = posterPath != null && posterPath.isNotEmpty;

    final posterFrame = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: KonataTheme.borderRadiusCard,
        color: p.surface,
        boxShadow: effectiveHover
            ? <BoxShadow>[
                BoxShadow(
                  color: KonataTheme.pureBlack.withValues(
                    alpha: p.isDark ? 0.42 : 0.16,
                  ),
                  blurRadius: 18,
                  offset: const Offset(0, 8),
                ),
              ]
            : null,
      ),
      child: ClipRRect(
        borderRadius: KonataTheme.borderRadiusCard,
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            if (hasPoster)
              ManagedImage(
                path: posterPath,
                ownerWorkId: work.id,
                subfolder: PhotoSubfolder.posters,
                targetWidth: 360,
                fit: BoxFit.cover,
                imageLoaderOverride: widget.imageLoaderOverride,
                errorWidget: _FallbackPosterPlaceholder(title: work.title),
              )
            else
              _FallbackPosterPlaceholder(title: work.title),
            if (hasSourceBadge || hasMultiVersion)
              Positioned(
                top: 8,
                right: 8,
                child: IgnorePointer(
                  child: Wrap(
                    spacing: 4,
                    runSpacing: 4,
                    alignment: WrapAlignment.end,
                    children: <Widget>[
                      if (hasSourceBadge)
                        _PosterGlassBadge(
                          label: widget.item.crossSourceBadgeLabel!,
                          fontSize: widget.badgeFontSize,
                          compact: widget.compactText,
                        ),
                      if (hasMultiVersion)
                        _PosterGlassBadge(
                          label: '${widget.item.maxEpisodeVariantCount}版本',
                          fontSize: widget.badgeFontSize,
                          compact: widget.compactText,
                        ),
                    ],
                  ),
                ),
              ),
            if (score != null && score > 0)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: 64,
                child: IgnorePointer(
                  child: AnimatedOpacity(
                    opacity: effectiveHover ? 1.0 : 0.0,
                    duration: KonataTheme.motionFast,
                    curve: Curves.easeOutCubic,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.bottomCenter,
                          end: Alignment.topCenter,
                          colors: <Color>[
                            KonataTheme.pureBlack.withValues(alpha: 0.72),
                            KonataTheme.pureBlack.withValues(alpha: 0.0),
                          ],
                        ),
                      ),
                      child: Align(
                        alignment: Alignment.bottomLeft,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(9, 0, 9, 9),
                          child: BangumiScoreWordmarkBadge(
                            score: score,
                            wordmarkHeight: widget.compactText ? 10.5 : 12.5,
                            enableBackdropBlur: effectiveHover,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: KonataTheme.borderRadiusCard,
                    border: Border.all(
                      color: effectiveHover ? p.hoverBorder : p.posterBorder,
                      width: 1,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );

    final titleStyle = KonataTheme.textStyle(
      color: effectiveHover
          ? p.textPrimary
          : p.textPrimary.withValues(alpha: 0.94),
      fontSize: widget.titleFontSize,
      weight: KonataTheme.weightActive,
      height: 1.25,
    );
    // 仅当前允许悬停的卡片检测标题截断，滚动期保持普通文本。
    final titleWidget = effectiveHover
        ? EllipsisTextWithTooltip(
            text: work.title,
            style: titleStyle,
            maxWidth: widget.cardWidth,
            deferTooltipToHover: true,
            suppressHoverCheck: () => !_resolvedHover,
          )
        : Text(
            work.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: titleStyle,
          );

    final subtitleWidget = Text(
      subtitleText,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: KonataTheme.textStyle(
        color: p.textSecondary,
        fontSize: widget.subtitleFontSize,
        height: 1.25,
      ),
    );

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => _setPointerInside(true),
      onHover: (_) => _setPointerInside(true),
      onExit: (_) => _setPointerInside(false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        onSecondaryTapDown: widget.onOpenMenu == null
            ? null
            : (_) => widget.onOpenMenu!(context),
        onLongPress: widget.onOpenMenu == null
            ? null
            : () => widget.onOpenMenu!(context),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final scaled = _LazyHoverScale(
              hovered: effectiveHover,
              child: posterFrame,
            );
            if (constraints.hasBoundedHeight) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Expanded(child: scaled),
                  SizedBox(height: widget.compactText ? 6 : 8),
                  titleWidget,
                  const SizedBox(height: 2),
                  subtitleWidget,
                ],
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                AspectRatio(aspectRatio: 2 / 3, child: scaled),
                SizedBox(height: widget.compactText ? 6 : 8),
                titleWidget,
                const SizedBox(height: 2),
                subtitleWidget,
              ],
            );
          },
        ),
      ),
    );
  }

  String _buildSubtitleText(Work work) {
    final ep = widget.item.episodeCount;
    if (work.year != null && ep > 0) return '${work.year} · $ep 话';
    if (work.year != null) return '${work.year}';
    if (ep > 0) return '$ep 话';
    return '待完善元数据';
  }
}

/// 惰性分配动画控制器的微缩悬停容器，防止长列表静止状态产生多余的合成层开销。
class _LazyHoverScale extends StatefulWidget {
  const _LazyHoverScale({required this.hovered, required this.child});

  final bool hovered;
  final Widget child;

  @override
  State<_LazyHoverScale> createState() => _LazyHoverScaleState();
}

class _LazyHoverScaleState extends State<_LazyHoverScale>
    with SingleTickerProviderStateMixin {
  AnimationController? _controller;
  Animation<double>? _scale;

  void _ensureController({required bool initiallyExpanded}) {
    if (_controller != null) return;
    _controller = AnimationController(
      vsync: this,
      duration: KonataTheme.motionFast,
      value: initiallyExpanded ? 1.0 : 0.0,
    );
    _scale = Tween<double>(begin: 1.0, end: 1.025).animate(
      CurvedAnimation(parent: _controller!, curve: Curves.easeOutCubic),
    );
  }

  @override
  void initState() {
    super.initState();
    if (widget.hovered) {
      _ensureController(initiallyExpanded: true);
    }
  }

  @override
  void didUpdateWidget(covariant _LazyHoverScale oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.hovered == oldWidget.hovered) return;
    if (widget.hovered) {
      _ensureController(initiallyExpanded: false);
      _controller!.forward();
    } else if (_controller != null) {
      _controller!.reverse();
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
    return ScaleTransition(scale: scale, child: widget.child);
  }
}

/// 缺省封面海报占位视图。
class _FallbackPosterPlaceholder extends StatelessWidget {
  const _FallbackPosterPlaceholder({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[p.elevatedSurface, p.surface],
        ),
      ),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.movie_outlined, size: 32, color: p.textMuted),
              const SizedBox(height: 10),
              Text(
                title,
                textAlign: TextAlign.center,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: KonataTheme.textStyle(
                  color: p.textSecondary,
                  fontSize: KonataTheme.fontSizeCaption,
                  height: 1.3,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 海报右上角磨砂来源或版本数角标胶囊。
class _PosterGlassBadge extends StatelessWidget {
  const _PosterGlassBadge({
    required this.label,
    required this.fontSize,
    required this.compact,
  });

  final String label;
  final double fontSize;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 6 : 7,
        vertical: compact ? 2.5 : 3,
      ),
      decoration: BoxDecoration(
        color: p.glassOverlay,
        borderRadius: KonataTheme.borderRadiusChip,
        border: Border.all(color: p.posterBorder),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: KonataTheme.textStyle(
          color: p.textPrimary,
          fontSize: fontSize,
          weight: KonataTheme.weightActive,
          height: 1.1,
        ),
      ),
    );
  }
}
