import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/providers/detail_display_preferences_provider.dart';
import '../../application/providers/library_providers.dart';
import '../../composition/platform_composition.dart';
import '../../domain/matching/playback_resume_resolver.dart';
import '../../domain/models/episode.dart';
import '../../domain/models/tmdb_models.dart';
import '../../domain/models/work.dart';
import '../audio/smart_cover_framing.dart';
import '../theme/konata_adaptive_tokens.dart';
import '../theme/konata_palette.dart';
import '../theme/konata_playback_tokens.dart';
import '../theme/konata_theme.dart';
import '../widgets/design_system/konata_pill_button.dart';
import '../widgets/managed_image.dart';
import 'detail_hero_info.dart';

/// 手机竖屏与平板竖屏共用的 `16:9` 原生比例背景头图（严格从状态栏安全区下方起绘 + 底部锚定限高透明徽标）。
class DetailPortraitHeroHeader extends StatelessWidget {
  /// 创建竖屏定比头图。
  const DetailPortraitHeroHeader({
    super.key,
    required this.work,
    required this.imageLoader,
    required this.screenSize,
    required this.isTablet,
    required this.showTitleLogo,
    required this.logoMaxHeight,
    required this.logoMaxWidth,
  });

  /// 目标作品实体。
  final Work work;

  /// 图片加载器。
  final ManagedImageLoader imageLoader;

  /// 当前视口尺寸。
  final Size screenSize;

  /// 是否为平板竖屏。
  final bool isTablet;

  /// 是否显示透明标题徽标。
  final bool showTitleLogo;

  /// 徽标最大高度。
  final double logoMaxHeight;

  /// 徽标最大宽度。
  final double logoMaxWidth;

  @override
  Widget build(BuildContext context) {
    final hasBackdrop =
        work.backdropPath != null && work.backdropPath!.trim().isNotEmpty;
    final posterPath =
        (work.posterPath != null && work.posterPath!.trim().isNotEmpty)
        ? work.posterPath!.trim()
        : (work.bangumiPosterPath?.trim() ?? '');
    final hasLogo = work.logoPath != null && work.logoPath!.trim().isNotEmpty;

    final raw169 = screenSize.width * 9 / 16;
    final maxH = screenSize.height * (isTablet ? 0.36 : 0.42);
    final heroHeight = hasBackdrop
        ? math.max(120.0, math.min(raw169, maxH))
        : (screenSize.height * (isTablet ? 0.32 : 0.36)).clamp(190.0, 320.0);

    return SizedBox(
      key: const ValueKey('detail_portrait_hero_header'),
      height: heroHeight,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (hasBackdrop)
            ManagedImage(
              work.backdropPath!,
              loader: imageLoader,
              owner: work.id,
              artwork: ManagedArtwork.backdrop,
              isHeroBackdrop: true,
              imageSize: TmdbImageSize.original,
              fit: BoxFit.cover,
              alignment: Alignment.center,
            )
          else if (posterPath.isNotEmpty)
            ClipRect(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ManagedImage(
                    posterPath,
                    loader: imageLoader,
                    owner: work.id,
                    artwork: ManagedArtwork.poster,
                    fit: BoxFit.cover,
                    alignment: SmartCoverFraming.defaultPosterAlignment,
                  ),
                  BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
                    child: ColoredBox(
                      color: KonataTheme.scrimBlackLight,
                    ),
                  ),
                ],
              ),
            )
          else
            const ColoredBox(color: KonataTheme.cinemaObsidian),
          IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  stops: const [0.0, 0.24, 0.58, 0.86, 1.0],
                  colors: [
                    KonataTheme.scrimBlackLight,
                    Colors.transparent,
                    Colors.transparent,
                    KonataTheme.cinemaObsidian.withValues(alpha: 0.72),
                    KonataTheme.cinemaObsidian,
                  ],
                ),
              ),
            ),
          ),
          if (showTitleLogo && hasLogo)
            Positioned(
              left: isTablet ? 28 : 16,
              right: isTablet ? 28 : 16,
              bottom: 8,
              child: Align(
                alignment: Alignment.bottomLeft,
                child: DetailLockedClearLogo(
                  key: const ValueKey('detail_hero_locked_logo'),
                  work: work,
                  imageLoader: imageLoader,
                  maxHeight: logoMaxHeight,
                  maxWidth: logoMaxWidth,
                  alignment: Alignment.bottomLeft,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 手机横屏专属沉浸式放大背景头图（向上覆盖状态栏 + 左右两侧及底部双向平滑渐隐 + 播放按钮与系列下拉同行）。
class DetailLandscapeHeroBanner extends StatelessWidget {
  /// 创建手机横屏沉浸头图。
  const DetailLandscapeHeroBanner({
    super.key,
    required this.bundle,
    required this.imageLoader,
    required this.displayPrefs,
    required this.screenSize,
    required this.leadingBackButton,
    required this.onPrimaryPlay,
    this.seriesSwitcher,
  });

  /// 作品详情数据包。
  final WorkDetailBundle bundle;

  /// 图片加载器。
  final ManagedImageLoader imageLoader;

  /// 详情页展示偏好。
  final DetailDisplayPreferences displayPrefs;

  /// 屏幕尺寸。
  final Size screenSize;

  /// 左上角返回按钮。
  final Widget leadingBackButton;

  /// 点击主播放按钮回调。
  final VoidCallback onPrimaryPlay;

  /// 可选紧邻播放按钮右侧同行的系列切换组件。
  final Widget? seriesSwitcher;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final safe = MediaQuery.paddingOf(context);
    final work = bundle.work;
    final hasBackdrop =
        work.backdropPath != null && work.backdropPath!.trim().isNotEmpty;
    final posterPath =
        (work.posterPath != null && work.posterPath!.trim().isNotEmpty)
        ? work.posterPath!.trim()
        : (work.bangumiPosterPath?.trim() ?? '');
    final hasLogo = work.logoPath != null && work.logoPath!.trim().isNotEmpty;
    final renderLogo = displayPrefs.showTitleLogo && hasLogo;

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

    final heroH = math
        .max(216.0, screenSize.height * 0.68)
        .clamp(216.0, 320.0);
    final artWidth = math.min(screenSize.width * 0.86, heroH * 16 / 9 * 1.24);
    final leftInset = math.max(16.0, safe.left + 12.0);
    const topBackInset = 7.0;

    return SizedBox(
      key: const ValueKey('detail_phone_landscape_hero'),
      height: heroH,
      child: Stack(
        fit: StackFit.expand,
        children: [
          const ColoredBox(color: KonataTheme.cinemaObsidian),
          if (hasBackdrop)
            Align(
              alignment: Alignment.centerRight,
              child: SizedBox(
                width: artWidth,
                height: heroH,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    ManagedImage(
                      work.backdropPath!,
                      loader: imageLoader,
                      owner: work.id,
                      artwork: ManagedArtwork.backdrop,
                      isHeroBackdrop: true,
                      imageSize: TmdbImageSize.original,
                      fit: BoxFit.cover,
                      alignment: Alignment.center,
                    ),
                    // 背景图左右双向平滑渐隐至暗色底板
                    IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.centerLeft,
                            end: Alignment.centerRight,
                            stops: const [0.0, 0.28, 0.82, 1.0],
                            colors: [
                              KonataTheme.cinemaObsidian,
                              KonataTheme.cinemaObsidian.withValues(
                                alpha: 0.26,
                              ),
                              Colors.transparent,
                              KonataTheme.cinemaObsidian.withValues(
                                alpha: 0.78,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            )
          else if (posterPath.isNotEmpty)
            Positioned.fill(
              child: ClipRect(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    ManagedImage(
                      posterPath,
                      loader: imageLoader,
                      owner: work.id,
                      artwork: ManagedArtwork.poster,
                      fit: BoxFit.cover,
                      alignment: SmartCoverFraming.defaultPosterAlignment,
                    ),
                    BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
                      child: ColoredBox(
                        color: KonataTheme.scrimBlackMedium,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          // 整体左暗晕承托文字可读性
          IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                  stops: const [0.0, 0.42, 0.78, 1.0],
                  colors: [
                    KonataTheme.cinemaObsidian.withValues(alpha: 0.92),
                    KonataTheme.cinemaObsidian.withValues(alpha: 0.56),
                    Colors.transparent,
                    KonataTheme.cinemaObsidian.withValues(alpha: 0.62),
                  ],
                ),
              ),
            ),
          ),
          // 底部平滑融入暗色底板渐变遮罩
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: 76,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    stops: const [0.0, 0.55, 1.0],
                    colors: [
                      Colors.transparent,
                      KonataTheme.cinemaObsidian.withValues(alpha: 0.72),
                      KonataTheme.cinemaObsidian,
                    ],
                  ),
                ),
              ),
            ),
          ),
          // 左上角返回箭头胶囊靠近顶边并保留防误触安全空隙
          Positioned(
            top: topBackInset,
            left: leftInset,
            child: leadingBackButton,
          ),
          // 左下方标题、元信息与「继续播放 + 系列切换」同行操作区
          Positioned(
            left: leftInset,
            right: math.max(16.0, safe.right + 12.0),
            bottom: 12,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (renderLogo)
                  DetailLockedClearLogo(
                    key: const ValueKey('detail_hero_locked_logo'),
                    work: work,
                    imageLoader: imageLoader,
                    maxHeight: 48.0,
                    maxWidth: math.min(screenSize.width * 0.44, 240.0),
                    alignment: Alignment.bottomLeft,
                    errorBuilder: (_, _, _) => Text(
                      work.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: KonataTheme.detailTextStyle(
                        fontSize: KonataTheme.fontSizeH2,
                        fontWeight: FontWeight.w700,
                        palette: p,
                        color: Colors.white,
                      ),
                    ),
                  )
                else
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: screenSize.width * 0.65,
                    ),
                    child: Text(
                      work.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: KonataTheme.detailTextStyle(
                        fontSize: KonataTheme.fontSizeH2,
                        fontWeight: FontWeight.w700,
                        palette: p,
                        color: Colors.white,
                      ),
                    ),
                  ),
                if (metaParts.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    metaParts.join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: KonataTheme.detailTextStyle(
                      fontSize: KonataTheme.fontSizeBodySm,
                      fontWeight: FontWeight.w600,
                      palette: p,
                      color: KonataTheme.overlayWhiteTextHigh,
                    ),
                  ),
                ],
                const SizedBox(height: 10),
                Theme(
                  data: KonataTheme.darkTheme(),
                  child: Wrap(
                    spacing: 10,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      FrostedPlayButton(
                        label: buttonLabel,
                        onPressed: onPrimaryPlay,
                      ),
                      ?seriesSwitcher,
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 详情页顶部返回圆钮（供竖屏顶栏与横屏首行共用）。
class WorkDetailBackCircle extends StatelessWidget {
  /// 创建顶部返回圆钮。
  const WorkDetailBackCircle({
    super.key,
    required this.forceLightIcons,
    required this.onBack,
  });

  /// 是否强制使用亮色图标（深色背景图上）。
  final bool forceLightIcons;

  /// 点击返回回调。
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final iconColor = forceLightIcons ? Colors.white : p.textPrimary;
    final bgColor = forceLightIcons
        ? KonataTheme.scrimBlackSubtle
        : p.surface;
    final borderColor = forceLightIcons
        ? KonataTheme.overlayWhiteBorderStrong
        : p.hairline;
    final btnSize = KonataAdaptiveTokens.isAndroid
        ? KonataAdaptiveTokens.touchTarget
        : 38.0;

    return Semantics(
      button: true,
      label: '返回',
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: KonataPlaybackTokens.shadowColor(p),
              blurRadius: 12,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: SizedBox(
          key: const ValueKey('work_detail_back_button'),
          width: btnSize,
          height: btnSize,
          child: ClipOval(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
              child: Material(
                color: bgColor,
                shape: CircleBorder(side: BorderSide(color: borderColor)),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  hoverColor: forceLightIcons
                      ? KonataTheme.overlayWhiteDim
                      : p.surfaceHover,
                  onTap: onBack,
                  child: Center(
                    child: Icon(
                      Icons.arrow_back_ios_new_rounded,
                      size: 16,
                      color: iconColor,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 详情页顶部常驻防死锁导航栏（左上返回按钮 + Windows 可拖拽标题区 + 右上控制胶囊）。
class WorkDetailTopBar extends ConsumerWidget {
  /// 创建详情页顶部导航栏。
  const WorkDetailTopBar({
    super.key,
    required this.forceLightIcons,
    required this.showGlassChrome,
    required this.onBack,
    this.trailingOps,
  });

  /// 是否强制使用亮色图标。
  final bool forceLightIcons;

  /// 是否显示玻璃描边。
  final bool showGlassChrome;

  /// 点击返回回调。
  final VoidCallback onBack;

  /// 可选右上角操作胶囊（手机竖屏置顶展示）。
  final Widget? trailingOps;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    const dragZone = SizedBox(height: 38);
    final windowHost = ref.watch(konataWindowHostProvider);

    return Row(
      children: [
        WorkDetailBackCircle(
          forceLightIcons: forceLightIcons,
          onBack: onBack,
        ),
        Expanded(
          child: KonataAdaptiveTokens.isWindows
              ? windowHost.buildDragToMoveArea(child: dragZone)
              : dragZone,
        ),
        if (trailingOps != null)
          trailingOps!
        else
          windowHost.buildWindowControls(
            forceLightIcons: forceLightIcons,
            showGlassPill: showGlassChrome,
          ),
      ],
    );
  }
}

/// 当作品记录被合并、删除或失效时的安全空状态兜底视图。
class MissingWorkFallbackView extends StatelessWidget {
  /// 创建缺失作品兜底视图。
  const MissingWorkFallbackView({
    super.key,
    required this.onReturnToLibrary,
    this.title = '该作品记录已变更或移除',
    this.subtitle = '该条目的元数据可能已合并至其他作品或被移出媒体库。',
    this.isError = false,
  });

  /// 点击返回媒体库回调。
  final VoidCallback onReturnToLibrary;

  /// 主标题。
  final String title;

  /// 辅助说明。
  final String subtitle;

  /// 是否为错误状态。
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
                  fontSize: KonataTheme.fontSizeBodySm,
                  color: p.textSecondary,
                ),
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
