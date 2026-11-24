import 'dart:ui' as ui;

import 'package:engine_scraping/engine_scraping.dart';
import 'package:flutter/widgets.dart';
import 'package:konata_design_system/konata_design_system.dart';

import 'detail_managed_image.dart';

/// 详情页顶部漂浮返回按钮条（严格 0 实心原生壳，仅保留毛玻璃圆形返回胶囊与可选右侧扩展槽）。
class WorkDetailTopBar extends StatelessWidget {
  /// 创建详情页顶部悬浮条。
  const WorkDetailTopBar({
    super.key,
    required this.onBack,
    this.forceLightChrome = true,
    this.showDesktopChrome = true,
    this.trailing,
  });

  /// 点击返回上一页面回调。
  final VoidCallback onBack;

  /// 是否强制在背景原画之上使用深底高反差白色返回胶囊。
  final bool forceLightChrome;

  /// 是否挂载桌面端窗口控制按钮区（手机端纯竖屏可关闭）。
  final bool showDesktopChrome;

  /// 可选右上角扩展按钮插槽。
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final fg = forceLightChrome ? KonataTheme.pureWhite : p.textPrimary;
    final bg = forceLightChrome
        ? KonataTheme.cinemaObsidian.withValues(alpha: 0.42)
        : p.surface.withValues(alpha: 0.78);
    final border = forceLightChrome
        ? KonataTheme.overlayWhiteBorderStrong
        : p.hairline;

    final desktopControls = showDesktopChrome
        ? KonataDesktopWindowChromeScope.buildWindowControls(
            context,
            showGlassPill: true,
          )
        : null;

    return Row(
      children: [
        Semantics(
          button: true,
          label: '返回',
          child: Tooltip(
            message: '返回上一页 (Esc)',
            child: GestureDetector(
              key: const ValueKey<String>('detail_back_button'),
              behavior: HitTestBehavior.opaque,
              onTap: onBack,
              child: ClipOval(
                child: BackdropFilter(
                  filter: KonataTheme.blurFilterControl,
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: bg,
                      border: Border.all(color: border, width: 1),
                    ),
                    child: Icon(
                      Icons.arrow_back_rounded,
                      size: 20,
                      color: fg,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        Expanded(
          child: KonataDesktopWindowChromeScope.wrapDragToMove(
            context,
            child: const SizedBox(height: 40),
          ),
        ),
        ?trailing,
        if (desktopControls != null) ...[
          if (trailing != null) const SizedBox(width: 8),
          desktopControls,
        ],
      ],
    );
  }
}

/// 当作品记录不存在、已被合并吸收或加载失败时的安全兜底视图。
class MissingWorkFallbackView extends StatelessWidget {
  /// 创建缺失作品安全兜底视图。
  const MissingWorkFallbackView({
    super.key,
    required this.onReturnToLibrary,
    this.title = '该作品记录已变更或移除',
    this.subtitle = '该条目的元数据可能已合并至其他作品或被移出媒体库。',
    this.isError = false,
  });

  /// 返回上一页或媒体库回调。
  final VoidCallback onReturnToLibrary;

  /// 兜底主标题。
  final String title;

  /// 兜底说明文本。
  final String subtitle;

  /// 是否为加载异常错误态。
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                isError
                    ? Icons.error_outline_rounded
                    : Icons.auto_stories_outlined,
                size: 48,
                color: isError ? p.danger : p.textMuted,
              ),
              const SizedBox(height: 14),
              Text(
                title,
                textAlign: TextAlign.center,
                style: KonataTheme.h2Style(p),
              ),
              const SizedBox(height: 8),
              Text(
                subtitle,
                textAlign: TextAlign.center,
                style: KonataTheme.captionStyle(
                  p,
                ).copyWith(color: p.textSecondary, fontSize: KonataTheme.fontSizeBodySm),
              ),
              const SizedBox(height: 22),
              KonataPillButton.primary(
                label: '返回媒体库',
                icon: Icons.arrow_back_rounded,
                onPressed: onReturnToLibrary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 桌面与平板宽屏详情页全幅背景原画与定向暗幕层。
class DetailWideBackdropStage extends StatelessWidget {
  /// 创建宽屏背景原画舞台。
  const DetailWideBackdropStage({
    super.key,
    required this.workId,
    required this.bgPath,
    required this.hasBackdrop,
    required this.imageLoader,
    this.backdropOwnerWorkId,
    this.fallbackPosterPath = '',
    this.showHeroBackdrop = true,
    this.isDrawerExpanded = true,
  });

  /// 作品唯一主键。
  final String workId;

  /// 实际横版背景缓存归属主键（同系列复用母剧横图时指向源作品主键）。
  final String? backdropOwnerWorkId;

  /// 横版背景路径（或无横图时回退海报路径）。
  final String bgPath;

  /// 是否持有真实 `16:9` 横版背景画作。
  final bool hasBackdrop;

  /// 是否允许渲染背景原画。
  final bool showHeroBackdrop;

  /// 底部选集抽屉是否处于展开状态（收起时进一步减弱底部遮罩，清澈透出全幅 16:9 原画）。
  final bool isDrawerExpanded;

  /// 受管图片加载器。
  final ManagedImageLoader imageLoader;

  /// 横版原画解码失败时的海报模糊兜底路径。
  final String fallbackPosterPath;

  @override
  Widget build(BuildContext context) {
    final trimmedFallback = fallbackPosterPath.trim();
    final primaryOwner =
        hasBackdrop && (backdropOwnerWorkId?.trim().isNotEmpty ?? false)
        ? backdropOwnerWorkId!.trim()
        : workId;

    return RepaintBoundary(
      child: Stack(
        fit: StackFit.expand,
        children: [
          const ColoredBox(color: KonataTheme.cinemaObsidian),
          if (showHeroBackdrop && bgPath.isNotEmpty && hasBackdrop)
            DetailManagedImage(
              bgPath,
              loader: imageLoader,
              owner: primaryOwner,
              artwork: ManagedArtwork.backdrop,
              isHeroBackdrop: true,
              imageSize: TmdbImageSize.original,
              fit: BoxFit.cover,
              alignment: Alignment.center,
              errorBuilder: (_, _, _) =>
                  trimmedFallback.isNotEmpty && trimmedFallback != bgPath
                  ? _BlurredPosterBackdrop(
                      posterPath: trimmedFallback,
                      workId: workId,
                      imageLoader: imageLoader,
                      blurFilter: KonataTheme.blurFilterCapsule,
                      scrimColor: KonataTheme.scrimBlackMedium,
                    )
                  : const ColoredBox(color: KonataTheme.cinemaObsidian),
            )
          else if (showHeroBackdrop && bgPath.isNotEmpty)
            _BlurredPosterBackdrop(
              posterPath: bgPath,
              workId: workId,
              imageLoader: imageLoader,
              blurFilter: KonataTheme.blurFilterCapsule,
              scrimColor: KonataTheme.scrimBlackMedium,
            ),
          IgnorePointer(
            child: DecoratedBox(
              key: const ValueKey<String>('detail_wide_corner_scrim'),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomLeft,
                  end: const Alignment(-0.08, 0.14),
                  stops: const [0.0, 0.42, 0.78, 1.0],
                  colors: [
                    KonataTheme.cinemaObsidian.withValues(alpha: 0.70),
                    KonataTheme.cinemaObsidian.withValues(alpha: 0.38),
                    KonataTheme.cinemaObsidian.withValues(alpha: 0.08),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),
          IgnorePointer(
            child: AnimatedContainer(
              duration: KonataTheme.motionNormal,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  stops: isDrawerExpanded
                      ? const [0.0, 0.24, 0.52]
                      : const [0.0, 0.18, 0.42],
                  colors: [
                    KonataTheme.cinemaObsidian.withValues(
                      alpha: isDrawerExpanded ? 0.82 : 0.44,
                    ),
                    KonataTheme.cinemaObsidian.withValues(
                      alpha: isDrawerExpanded ? 0.36 : 0.14,
                    ),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 手机纯竖屏与平板竖屏详情页顶部沉浸竖版原画组件。
///
/// 优先展示 `work.portraitBackdropPath` 并吸色溶入主题底色；为空时回退常规竖版海报并抬高底部溶底渐变，绝不强裁 16:9 横图。
class DetailPortraitHeroHeader extends StatelessWidget {
  /// 创建竖屏沉浸头图。
  const DetailPortraitHeroHeader({
    super.key,
    required this.work,
    required this.imageLoader,
    required this.viewportWidth,
    required this.viewportHeight,
    this.backdropPathOverride,
    this.backdropOwnerWorkId,
    this.dissolveColor,
    this.showHeroBackdrop = true,
  });

  /// 作品领域实体。
  final Work work;

  /// 受管图片加载器。
  final ManagedImageLoader imageLoader;

  /// 当前视口宽度。
  final double viewportWidth;

  /// 当前视口高度。
  final double viewportHeight;

  /// 预留字段（竖屏阶段严禁强裁 16:9 横版原画）。
  final String? backdropPathOverride;

  /// 预留字段。
  final String? backdropOwnerWorkId;

  /// 原画下缘吸色并适配深/浅主题后的背景溶底目标色（为空时回落 `palette.canvas`）。
  final Color? dissolveColor;

  /// 是否允许展示头图原画。
  final bool showHeroBackdrop;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final portraitBackdrop = (work.portraitBackdropPath ?? '').trim();
    final posterPath = (work.posterPath?.trim().isNotEmpty ?? false)
        ? work.posterPath!.trim()
        : (work.bangumiPosterPath?.trim() ?? '');
    final baseCanvas = dissolveColor ?? p.canvas;

    final isTabletPortrait = viewportWidth >= 560;
    final heroHeight = isTabletPortrait
        ? (viewportHeight * 0.46).clamp(300.0, 520.0)
        : (viewportHeight * 0.48).clamp(290.0, 420.0);

    final bool hasPortraitBackdrop =
        showHeroBackdrop && portraitBackdrop.isNotEmpty;
    final bool isPosterFallback =
        !hasPortraitBackdrop && showHeroBackdrop && posterPath.isNotEmpty;

    return SizedBox(
      key: const ValueKey<String>('detail_portrait_hero_header'),
      height: heroHeight,
      width: double.infinity,
      child: Stack(
        fit: StackFit.expand,
        children: [
          AnimatedContainer(
            duration: KonataTheme.motionNormal,
            color: baseCanvas,
          ),
          if (hasPortraitBackdrop)
            DetailManagedImage(
              portraitBackdrop,
              key: const ValueKey<String>('detail_portrait_hero_artwork'),
              loader: imageLoader,
              owner: work.id,
              artwork: ManagedArtwork.poster,
              imageSize: TmdbImageSize.original,
              fit: BoxFit.cover,
              alignment: const Alignment(0, -0.25),
              errorBuilder: (_, _, _) => posterPath.isNotEmpty
                  ? DetailManagedImage(
                      posterPath,
                      key: const ValueKey<String>(
                        'detail_portrait_hero_poster_fallback',
                      ),
                      loader: imageLoader,
                      owner: work.id,
                      artwork: ManagedArtwork.poster,
                      imageSize: TmdbImageSize.original,
                      fit: BoxFit.cover,
                      alignment: DetailSmartCoverFraming.defaultPosterAlignment,
                      errorBuilder: (_, _, _) => ColoredBox(color: baseCanvas),
                    )
                  : ColoredBox(color: baseCanvas),
            )
          else if (isPosterFallback)
            DetailManagedImage(
              posterPath,
              key: const ValueKey<String>(
                'detail_portrait_hero_poster_fallback',
              ),
              loader: imageLoader,
              owner: work.id,
              artwork: ManagedArtwork.poster,
              imageSize: TmdbImageSize.original,
              fit: BoxFit.cover,
              alignment: DetailSmartCoverFraming.defaultPosterAlignment,
              errorBuilder: (_, _, _) => ColoredBox(color: baseCanvas),
            )
          else
            DecoratedBox(
              key: const ValueKey<String>('detail_portrait_hero_neutral'),
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(0, -0.35),
                  radius: 1.15,
                  colors: [
                    p.accent.withValues(alpha: p.isDark ? 0.16 : 0.10),
                    baseCanvas,
                  ],
                ),
              ),
            ),
          IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  stops: isPosterFallback
                      ? const [0.0, 0.16, 0.30, 0.50, 0.72, 1.0]
                      : const [0.0, 0.16, 0.42, 0.66, 0.86, 1.0],
                  colors: isPosterFallback
                      ? [
                          KonataTheme.cinemaObsidian.withValues(alpha: 0.36),
                          Colors.transparent,
                          Colors.transparent,
                          baseCanvas.withValues(alpha: 0.56),
                          baseCanvas.withValues(alpha: 0.94),
                          baseCanvas,
                        ]
                      : [
                          KonataTheme.cinemaObsidian.withValues(alpha: 0.34),
                          Colors.transparent,
                          Colors.transparent,
                          baseCanvas.withValues(alpha: 0.52),
                          baseCanvas.withValues(alpha: 0.90),
                          baseCanvas,
                        ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BlurredPosterBackdrop extends StatelessWidget {
  const _BlurredPosterBackdrop({
    required this.posterPath,
    required this.workId,
    required this.imageLoader,
    required this.scrimColor,
    this.blurFilter,
  });

  final String posterPath;
  final String workId;
  final ManagedImageLoader imageLoader;
  final Color scrimColor;
  final ui.ImageFilter? blurFilter;

  @override
  Widget build(BuildContext context) {
    final trimmed = posterPath.trim();
    if (trimmed.isEmpty) {
      return const ColoredBox(color: KonataTheme.cinemaObsidian);
    }
    return RepaintBoundary(
      child: ClipRect(
        child: Stack(
          fit: StackFit.expand,
          children: [
            ImageFiltered(
              imageFilter: blurFilter ?? KonataTheme.blurFilterMedium,
              child: DetailManagedImage(
                trimmed,
                loader: imageLoader,
                owner: workId,
                artwork: ManagedArtwork.poster,
                decodeWidth: 480,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) =>
                    const ColoredBox(color: KonataTheme.cinemaObsidian),
              ),
            ),
            ColoredBox(color: scrimColor),
          ],
        ),
      ),
    );
  }
}
