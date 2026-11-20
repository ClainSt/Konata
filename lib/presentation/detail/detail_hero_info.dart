
import 'dart:async';
import 'dart:developer' as developer;
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/playback/artwork_palette_service.dart';
import '../../application/providers/library_providers.dart';
import '../../domain/formatting/clear_logo_legibility.dart';
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
  KonataTheme.heroCardTextShadow,
];

/// 严格锁死最大高度与最大宽度的透明背景标题徽标（ClearLogo）组件。
///
/// 无论透明徽标原图为窄长条或竖向/方形（如《86》），统一按 `BoxFit.contain`
/// 与 `Alignment.bottomLeft` 缩放约束在限定盒内，防止向下撑开详情页文档流；
/// 同时基于低分辨率像素亮度与色度采样，在暗色电影底图上自动增强深黑或深彩色无白边徽标可读性：
/// - 单色深黑/深灰字：保色相亮度反相为光学象牙白 + 字形轮廓柔和暗投影；
/// - 深彩色无白边字：保留官方原色相并沿真实 Alpha 轮廓绘制霜白背晕；
/// - 原图已足够明亮或自带浅色描边：忠实原样渲染。
class DetailLockedClearLogo extends ConsumerStatefulWidget {
  /// 创建限高透明标题徽标。
  const DetailLockedClearLogo({
    super.key,
    required this.work,
    required this.imageLoader,
    required this.maxHeight,
    required this.maxWidth,
    this.alignment = Alignment.bottomLeft,
    this.errorBuilder,
  });

  /// 目标作品实体。
  final Work work;

  /// 图片加载器。
  final ManagedImageLoader imageLoader;

  /// 徽标允许占用的最大高度。
  final double maxHeight;

  /// 徽标允许占用的最大宽度。
  final double maxWidth;

  /// 徽标在边界盒内的对齐方式（默认左下 `Alignment.bottomLeft`）。
  final Alignment alignment;

  /// 图片加载失败时的占位回退构造器。
  final Widget Function(BuildContext, Object, StackTrace?)? errorBuilder;

  @override
  ConsumerState<DetailLockedClearLogo> createState() =>
      _DetailLockedClearLogoState();
}

class _DetailLockedClearLogoState extends ConsumerState<DetailLockedClearLogo> {
  static const int _sampleMaxDim = 64;

  ClearLogoLegibilityMode? _resolvedMode;
  ImageProvider? _resolvedProvider;
  String? _inFlightCacheKey;
  int _sampleGeneration = 0;

  String get _cacheKey =>
      '${widget.work.id}|${widget.work.logoPath?.trim() ?? ''}';

  @override
  void didUpdateWidget(covariant DetailLockedClearLogo oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldKey =
        '${oldWidget.work.id}|${oldWidget.work.logoPath?.trim() ?? ''}';
    if (oldKey != _cacheKey) {
      _sampleGeneration++;
      _resolvedMode = null;
      _resolvedProvider = null;
      _inFlightCacheKey = null;
    }
  }

  void _scheduleStateUpdate(VoidCallback apply) {
    if (!mounted) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(apply);
      });
    } else {
      setState(apply);
    }
  }

  void _handleImageResolved(ui.Image image, ImageProvider provider) {
    final key = _cacheKey;
    final cached = ref.read(clearLogoLegibilityCacheProvider).get(key);
    if (_resolvedProvider != provider) {
      _scheduleStateUpdate(() {
        _resolvedProvider = provider;
        if (cached != null) {
          _resolvedMode = cached;
        }
      });
    } else if (cached != null && _resolvedMode != cached) {
      _scheduleStateUpdate(() => _resolvedMode = cached);
    }
    if (cached != null || _inFlightCacheKey == key) {
      return;
    }
    _inFlightCacheKey = key;
    final gen = ++_sampleGeneration;
    final cloned = image.clone();
    unawaited(_sampleAndCacheMode(key, gen, cloned));
  }

  Future<void> _sampleAndCacheMode(
    String key,
    int gen,
    ui.Image source,
  ) async {
    ui.Picture? picture;
    ui.Image? tiny;
    try {
      final srcW = source.width;
      final srcH = source.height;
      if (srcW <= 0 || srcH <= 0) return;

      ui.Image target = source;
      if (srcW > _sampleMaxDim || srcH > _sampleMaxDim) {
        final scale = _sampleMaxDim / math.max(srcW, srcH);
        final dstW = math.max(1, (srcW * scale).round());
        final dstH = math.max(1, (srcH * scale).round());
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        canvas.drawImageRect(
          source,
          Rect.fromLTWH(0, 0, srcW.toDouble(), srcH.toDouble()),
          Rect.fromLTWH(0, 0, dstW.toDouble(), dstH.toDouble()),
          Paint()..filterQuality = FilterQuality.low,
        );
        picture = recorder.endRecording();
        tiny = await picture.toImage(dstW, dstH);
        target = tiny;
      }

      final byteData = await target.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      if (byteData == null) return;
      final mode = analyzeClearLogoRgba(byteData.buffer.asUint8List());
      if (!mounted || gen != _sampleGeneration) return;
      ref.read(clearLogoLegibilityCacheProvider).put(key, mode);
      if (_resolvedMode != mode) {
        _scheduleStateUpdate(() => _resolvedMode = mode);
      }
    } catch (error, stackTrace) {
      developer.log(
        'ClearLogo 亮度采样失败，保持原图渲染',
        name: 'DetailLockedClearLogo',
        error: error,
        stackTrace: stackTrace,
      );
    } finally {
      tiny?.dispose();
      picture?.dispose();
      source.dispose();
    }
  }

  Widget _buildSilhouetteLayer({
    required ImageProvider provider,
    required Color tint,
    required ui.ImageFilter blur,
    Offset offset = Offset.zero,
  }) {
    final silhouette = ImageFiltered(
      imageFilter: blur,
      child: ColorFiltered(
        colorFilter: ColorFilter.mode(tint, BlendMode.srcIn),
        child: Image(
          image: provider,
          fit: BoxFit.contain,
          alignment: widget.alignment,
          filterQuality: FilterQuality.low,
          gaplessPlayback: true,
          errorBuilder: (_, _, _) => const SizedBox.shrink(),
        ),
      ),
    );
    if (offset == Offset.zero) {
      return IgnorePointer(child: silhouette);
    }
    return IgnorePointer(
      child: Transform.translate(offset: offset, child: silhouette),
    );
  }

  @override
  Widget build(BuildContext context) {
    final path = widget.work.logoPath?.trim() ?? '';
    if (path.isEmpty) {
      return const SizedBox.shrink();
    }

    final cachedMode = ref.read(clearLogoLegibilityCacheProvider).get(_cacheKey);
    final mode =
        cachedMode ?? _resolvedMode ?? ClearLogoLegibilityMode.original;
    final physicalWidth =
        (widget.maxWidth * MediaQuery.devicePixelRatioOf(context))
            .ceil()
            .clamp(1, 8192);
    final provider =
        _resolvedProvider ??
        ManagedImageProvider(
          path,
          loader: widget.imageLoader,
          targetWidth: physicalWidth,
          artwork: ManagedArtwork.logo,
          imageSize: TmdbImageSize.original,
          owner: widget.work.id,
        );

    final baseImage = ManagedImage(
      path,
      loader: widget.imageLoader,
      owner: widget.work.id,
      artwork: ManagedArtwork.logo,
      imageSize: TmdbImageSize.original,
      fit: BoxFit.contain,
      alignment: widget.alignment,
      onImageResolved: _handleImageResolved,
      errorBuilder:
          widget.errorBuilder ?? (_, _, _) => const SizedBox.shrink(),
    );

    Widget rendered;
    switch (mode) {
      case ClearLogoLegibilityMode.smartInvert:
        final inverted = ColorFiltered(
          key: const ValueKey('detail_clear_logo_smart_invert'),
          colorFilter: KonataTheme.clearLogoSmartInvertFilter,
          child: baseImage,
        );
        rendered = Stack(
          alignment: widget.alignment,
          clipBehavior: Clip.none,
          children: [
            _buildSilhouetteLayer(
              provider: provider,
              tint: KonataTheme.scrimBlackStrong,
              blur: KonataTheme.clearLogoHaloBlurTight,
              offset: const Offset(0, 2),
            ),
            inverted,
          ],
        );
      case ClearLogoLegibilityMode.softHalo:
        rendered = Stack(
          key: const ValueKey('detail_clear_logo_soft_halo'),
          alignment: widget.alignment,
          clipBehavior: Clip.none,
          children: [
            _buildSilhouetteLayer(
              provider: provider,
              tint: KonataTheme.clearLogoHaloGlowWide,
              blur: KonataTheme.clearLogoHaloBlurWide,
            ),
            _buildSilhouetteLayer(
              provider: provider,
              tint: KonataTheme.clearLogoHaloGlowTight,
              blur: KonataTheme.clearLogoHaloBlurTight,
            ),
            baseImage,
          ],
        );
      case ClearLogoLegibilityMode.original:
        rendered = Stack(
          alignment: widget.alignment,
          clipBehavior: Clip.none,
          children: [
            _buildSilhouetteLayer(
              provider: provider,
              tint: KonataTheme.scrimBlackMedium,
              blur: KonataTheme.clearLogoHaloBlurTight,
              offset: const Offset(0, 2),
            ),
            baseImage,
          ],
        );
    }

    return RepaintBoundary(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: widget.maxWidth,
          maxHeight: widget.maxHeight,
        ),
        child: rendered,
      ),
    );
  }
}

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
    this.titleFontSize = 34.0,
    this.fullWidthPlayButton = false,
    this.expandOverviewFullWidth = false,
    this.trailingPlayAccessory,
    this.overlayLogoHandledSeparately = false,
    this.lockInFlowLogoHeight = false,
    this.logoMaxHeight = 80.0,
    this.logoMaxWidth = 340.0,
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

  /// 文字主标题字号（桌面默认 `34`，手机竖屏传入较小字号防止超大折行）。
  final double titleFontSize;

  /// 主播放按钮是否撑满容器宽度。
  final bool fullWidthPlayButton;

  /// 是否取消左半屏限宽使作品简介与标题横向全行通栏显示（平板竖屏启用）。
  final bool expandOverviewFullWidth;

  /// 可选紧贴主播放按钮右侧同一行排布的附属控件（如系列切换下拉框）。
  final Widget? trailingPlayAccessory;

  /// 是否已将 ClearLogo 叠放在上方头图暗色渐变遮罩内（为 `true` 时文档流内不再占高度）。
  final bool overlayLogoHandledSeparately;

  /// 文档流模式下是否锁定透明徽标固定槽位高度（防止竖长/宽扁 Logo 引起下方播放按钮位移）。
  final bool lockInFlowLogoHeight;

  /// 透明徽标在文档流模式下的最大高度上限。
  final double logoMaxHeight;

  /// 透明徽标在文档流模式下的最大宽度上限。
  final double logoMaxWidth;

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
    final renderLogoInFlow =
        !overlayLogoHandledSeparately && showTitleLogo && hasLogo;
    final renderTextTitle = showTitleText || (showTitleLogo && !hasLogo);
    final hasTitleSection = renderLogoInFlow || renderTextTitle;
    final hasOverview =
        showOverview &&
        work.overview != null &&
        work.overview!.trim().isNotEmpty;
    final hasHeaderContent =
        hasTitleSection || metaParts.isNotEmpty || hasOverview;

    final Widget contentColumn = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (renderLogoInFlow)
          lockInFlowLogoHeight
              ? SizedBox(
                  height: logoMaxHeight,
                  child: Align(
                    alignment: Alignment.bottomLeft,
                    child: DetailLockedClearLogo(
                      key: const ValueKey('detail_hero_locked_logo'),
                      work: work,
                      imageLoader: imageLoader,
                      maxWidth: logoMaxWidth,
                      maxHeight: logoMaxHeight,
                      alignment: Alignment.bottomLeft,
                      errorBuilder: (_, _, _) => showTitleText
                          ? const SizedBox.shrink()
                          : _FallbackTitleBlock(
                              title: work.title,
                              originalTitle: work.originalTitle,
                              fontSize: titleFontSize,
                            ),
                    ),
                  ),
                )
              : DetailLockedClearLogo(
                  key: const ValueKey('detail_hero_locked_logo'),
                  work: work,
                  imageLoader: imageLoader,
                  maxWidth: logoMaxWidth,
                  maxHeight: logoMaxHeight,
                  alignment: Alignment.bottomLeft,
                  errorBuilder: (_, _, _) => showTitleText
                      ? const SizedBox.shrink()
                      : _FallbackTitleBlock(
                          title: work.title,
                          originalTitle: work.originalTitle,
                          fontSize: titleFontSize,
                        ),
                ),
        if (renderLogoInFlow && renderTextTitle) const SizedBox(height: 10),
        if (renderTextTitle)
          _FallbackTitleBlock(
            title: work.title,
            originalTitle: work.originalTitle,
            fontSize: titleFontSize,
          ),
        if (metaParts.isNotEmpty) ...[
          if (hasTitleSection) const SizedBox(height: 12),
          Text(
            metaParts.join(' · '),
            style: KonataTheme.detailTextStyle(
              fontSize: KonataTheme.fontSizeBody,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.4,
              palette: p,
              color: KonataTheme.overlayWhiteTextHigh,
            ).copyWith(shadows: _kHeroBackdropTextShadows),
          ),
        ],
        if (hasOverview) ...[
          if (hasTitleSection || metaParts.isNotEmpty)
            const SizedBox(height: 12),
          expandOverviewFullWidth
              ? SizedBox(
                  width: double.infinity,
                  child: Theme(
                    data: KonataTheme.darkTheme(),
                    child: InlineExpandableSynopsis(
                      text: work.overview!.trim(),
                      collapsedMaxLines: 4,
                      maxExpandedHeight: 240,
                    ),
                  ),
                )
              : ConstrainedBox(
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
        if (hasHeaderContent) const SizedBox(height: 18),
        if (work.scrapeStatus == ScrapeStatus.needsReview &&
            onManualMatch != null &&
            onDismissReview != null)
          WorkReviewBanner(
            reviewReason: work.reviewReason,
            onManualMatch: onManualMatch!,
            onDismiss: onDismissReview!,
          ),
        if (trailingPlayAccessory != null && !fullWidthPlayButton)
          Wrap(
            spacing: 10,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              FrostedPlayButton(
                label: buttonLabel,
                onPressed: onPrimaryPlay,
                expandWidth: false,
              ),
              trailingPlayAccessory!,
            ],
          )
        else
          FrostedPlayButton(
            label: buttonLabel,
            onPressed: onPrimaryPlay,
            expandWidth: fullWidthPlayButton,
          ),
      ],
    );

    if (expandOverviewFullWidth) {
      return contentColumn;
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 520),
      child: contentColumn,
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
    this.expandWidth = false,
  });

  /// 按钮主文案（`开始播放` 或 `继续播放`）。
  final String label;

  /// 点击回调。
  final VoidCallback? onPressed;

  /// 是否横向撑满可用容器宽度（手机竖屏网易爆米花风格主按钮）。
  final bool expandWidth;

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
    final capsuleHeight = KonataPlaybackTokens.detailActionCapsuleHeight(
      isTouch: KonataAdaptiveTokens.isAndroid,
    );
    const radius = KonataPlaybackTokens.detailActionCapsuleRadius;

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
            borderRadius: BorderRadius.circular(radius),
            boxShadow: [
              BoxShadow(
                color: KonataPlaybackTokens.shadowColor(p),
                blurRadius: 18,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(radius),
            child: BackdropFilter(
              filter: KonataTheme.blurFilterOverlay,
              child: AnimatedContainer(
                duration: KonataTheme.motionFast,
                curve: Curves.easeOutCubic,
                width: widget.expandWidth ? double.infinity : null,
                height: capsuleHeight,
                padding: const EdgeInsets.symmetric(horizontal: 22),
                decoration: BoxDecoration(
                  gradient: KonataTheme.opticalSheenGradient(
                    p,
                    hovered: _hovered,
                    baseColor: fillColor,
                  ),
                  borderRadius: BorderRadius.circular(radius),
                  border: Border.all(
                    color: borderColor,
                    width: KonataPlaybackTokens.detailActionCapsuleBorderWidth,
                  ),
                ),
                child: Row(
                  mainAxisSize: widget.expandWidth
                      ? MainAxisSize.max
                      : MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.play_arrow_rounded, size: 20, color: fgColor),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        widget.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: KonataTheme.detailTextStyle(
                          fontSize: KonataTheme.fontSizeSubtitle,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.4,
                          palette: p,
                          color: fgColor,
                        ),
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
  const _FallbackTitleBlock({
    required this.title,
    required this.originalTitle,
    this.fontSize = 34.0,
  });

  final String title;
  final String? originalTitle;
  final double fontSize;

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
            color: KonataTheme.pureWhite,
            fontSize: fontSize,
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
              color: KonataTheme.overlayWhiteTextMid,
              fontSize: KonataTheme.fontSizeBodyMd,
              fontWeight: FontWeight.w500,
              letterSpacing: 0.3,
            ).copyWith(shadows: _kHeroBackdropTextShadows),
          ),
        ],
      ],
    );
  }
}
