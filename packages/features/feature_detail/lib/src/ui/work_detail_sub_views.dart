import 'dart:math' as math;
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
    this.trailing,
  });

  /// 点击返回上一页面回调。
  final VoidCallback onBack;

  /// 是否强制在背景原画之上使用深底高反差白色返回胶囊。
  final bool forceLightChrome;

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
        const Spacer(),
        ?trailing,
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
                    KonataTheme.cinemaObsidian.withValues(alpha: 0.76),
                    KonataTheme.cinemaObsidian.withValues(alpha: 0.44),
                    KonataTheme.cinemaObsidian.withValues(alpha: 0.12),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),
          IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  stops: const [0.0, 0.24, 0.56],
                  colors: [
                    KonataTheme.cinemaObsidian.withValues(alpha: 0.86),
                    KonataTheme.cinemaObsidian.withValues(alpha: 0.42),
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

/// 手机与窄屏竖向详情页顶部沉浸海报 / 横幅头图组件。
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

  /// 可选共享横版背景路径。
  final String? backdropPathOverride;

  /// 可选共享横版背景归属作品主键。
  final String? backdropOwnerWorkId;

  /// 是否允许展示头图原画。
  final bool showHeroBackdrop;

  @override
  Widget build(BuildContext context) {
    final resolvedBackdrop = (backdropPathOverride?.trim().isNotEmpty ?? false)
        ? backdropPathOverride!.trim()
        : (work.backdropPath?.trim() ?? '');
    final resolvedOwner = (backdropOwnerWorkId?.trim().isNotEmpty ?? false)
        ? backdropOwnerWorkId!.trim()
        : work.id;
    final posterPath = (work.posterPath?.trim().isNotEmpty ?? false)
        ? work.posterPath!.trim()
        : (work.bangumiPosterPath?.trim() ?? '');

    final isWide = viewportWidth >= 560;
    final double heroHeight;
    if (isWide) {
      heroHeight = math.max(150.0, math.min(viewportWidth * 9 / 16, viewportHeight * 0.42));
    } else {
      heroHeight = (viewportHeight * 0.42).clamp(180.0, 360.0);
    }

    return SizedBox(
      key: const ValueKey<String>('detail_portrait_hero_header'),
      height: heroHeight,
      width: double.infinity,
      child: Stack(
        fit: StackFit.expand,
        children: [
          const ColoredBox(color: KonataTheme.cinemaObsidian),
          if (showHeroBackdrop && !isWide && posterPath.isNotEmpty)
            DetailManagedImage(
              posterPath,
              loader: imageLoader,
              owner: work.id,
              artwork: ManagedArtwork.poster,
              imageSize: TmdbImageSize.original,
              fit: BoxFit.cover,
              alignment: DetailSmartCoverFraming.defaultPosterAlignment,
              errorBuilder: (_, _, _) =>
                  const ColoredBox(color: KonataTheme.cinemaObsidian),
            )
          else if (showHeroBackdrop && resolvedBackdrop.isNotEmpty)
            DetailManagedImage(
              resolvedBackdrop,
              loader: imageLoader,
              owner: resolvedOwner,
              artwork: ManagedArtwork.backdrop,
              isHeroBackdrop: true,
              imageSize: TmdbImageSize.original,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => _BlurredPosterBackdrop(
                posterPath: posterPath,
                workId: work.id,
                imageLoader: imageLoader,
                blurFilter: KonataTheme.blurFilterMedium,
                scrimColor: KonataTheme.scrimBlackLight,
              ),
            )
          else if (showHeroBackdrop && posterPath.isNotEmpty)
            _BlurredPosterBackdrop(
              posterPath: posterPath,
              workId: work.id,
              imageLoader: imageLoader,
              blurFilter: KonataTheme.blurFilterMedium,
              scrimColor: KonataTheme.scrimBlackLight,
            ),
          IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  stops: const [0.0, 0.18, 0.58, 0.88, 1.0],
                  colors: [
                    KonataTheme.cinemaObsidian.withValues(alpha: 0.34),
                    Colors.transparent,
                    Colors.transparent,
                    KonataTheme.cinemaObsidian.withValues(alpha: 0.78),
                    KonataTheme.cinemaObsidian,
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
