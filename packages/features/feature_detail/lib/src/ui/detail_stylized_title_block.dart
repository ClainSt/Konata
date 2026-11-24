import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:engine_scraping/engine_scraping.dart';
import 'package:flutter/widgets.dart';
import 'package:konata_design_system/konata_design_system.dart';

import '../data/clear_logo_legibility.dart';
import '../data/detail_title_typography.dart';
import 'detail_managed_image.dart';

/// 详情页主舞台标题区：
/// - 若存在官方透明标题徽标（ClearLogo），结合像素亮度采样自适应托底高对比渲染；
/// - 若无官方徽标或图片加载失败，自动降级为海报级排版字号与衬底文字标题。
class DetailStylizedTitleBlock extends StatefulWidget {
  /// 创建详情页标题展示区。
  const DetailStylizedTitleBlock({
    super.key,
    required this.work,
    required this.imageLoader,
    required this.isCompactViewport,
    this.logoAlignment = Alignment.bottomLeft,
    this.maxLogoHeight,
    this.maxLogoWidth,
    this.onTapEditLogo,
    this.showTitleText = true,
    this.showTitleLogo = true,
    this.onDarkBackdrop = true,
  });

  /// 目标作品。
  final Work work;

  /// 受管图片加载器。
  final ManagedImageLoader imageLoader;

  /// 是否紧凑视口。
  final bool isCompactViewport;

  /// 徽标图片对齐方式。
  final Alignment logoAlignment;

  /// 可选徽标最大高度限制。
  final double? maxLogoHeight;

  /// 可选徽标最大宽度限制。
  final double? maxLogoWidth;

  /// 可选交互编辑徽标回调。
  final VoidCallback? onTapEditLogo;

  /// 是否显示作品标题文字。
  final bool showTitleText;

  /// 是否显示透明标题徽标。
  final bool showTitleLogo;

  /// 是否处于深色原画护字遮罩之上（影响浅色模式下竖屏文字/徽标底衬对比度）。
  final bool onDarkBackdrop;

  @override
  State<DetailStylizedTitleBlock> createState() =>
      _DetailStylizedTitleBlockState();
}

class _DetailStylizedTitleBlockState extends State<DetailStylizedTitleBlock> {
  String? _analyzedUrl;
  bool _logoLoadFailed = false;
  ClearLogoLegibilityResult _legibility = ClearLogoLegibilityResult.neutral;

  @override
  void didUpdateWidget(covariant DetailStylizedTitleBlock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.work.id != widget.work.id ||
        oldWidget.work.logoPath != widget.work.logoPath) {
      _analyzedUrl = null;
      _logoLoadFailed = false;
      _legibility = ClearLogoLegibilityResult.neutral;
    }
  }

  void _handleLogoResolved(ui.Image image, String url) {
    if (_analyzedUrl == url) return;
    _analyzedUrl = url;
    final surfaceBg = widget.onDarkBackdrop || context.palette.isDark
        ? KonataTheme.cinemaObsidian
        : KonataTheme.themePreviewLightCanvas;
    unawaited(
      ClearLogoLegibility.analyzeImage(image).then((stats) {
        if (!mounted || widget.work.logoPath?.trim() != url) return;
        final next = ClearLogoLegibility.evaluateForSurface(
          stats: stats,
          estimatedBackground: surfaceBg,
        );
        setState(() {
          _legibility = next;
          _logoLoadFailed = false;
        });
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.showTitleText && !widget.showTitleLogo) {
      return const SizedBox.shrink();
    }
    final logoUrl = widget.work.logoPath?.trim() ?? '';
    if (widget.showTitleLogo && logoUrl.isNotEmpty && !_logoLoadFailed) {
      return _buildLogoView(context, logoUrl);
    }
    if (!widget.showTitleText) {
      return const SizedBox.shrink();
    }
    return _buildStylizedTextTitle(context);
  }

  Widget _buildLogoView(BuildContext context, String logoUrl) {
    final p = context.palette;
    final maxH =
        widget.maxLogoHeight ?? (widget.isCompactViewport ? 72.0 : 124.0);
    final maxW =
        widget.maxLogoWidth ?? (widget.isCompactViewport ? 280.0 : 520.0);

    final Widget scrimContainer;
    if (_legibility.needsLightScrim) {
      scrimContainer = Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          borderRadius: KonataTheme.borderRadiusCard,
          gradient: RadialGradient(
            center: Alignment.center,
            radius: 1.25,
            colors: [
              KonataTheme.pureWhite.withValues(
                alpha: (_legibility.recommendedScrimStrength * 0.92).clamp(
                  0.18,
                  0.72,
                ),
              ),
              KonataTheme.pureWhite.withValues(alpha: 0.0),
            ],
          ),
        ),
        child: _buildRawLogoImage(logoUrl, maxW: maxW, maxH: maxH),
      );
    } else if (_legibility.needsDarkScrim && !p.isDark) {
      scrimContainer = Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          borderRadius: KonataTheme.borderRadiusCard,
          gradient: RadialGradient(
            center: Alignment.center,
            radius: 1.35,
            colors: [
              KonataTheme.cinemaObsidian.withValues(
                alpha: (_legibility.recommendedScrimStrength * 0.85).clamp(
                  0.22,
                  0.68,
                ),
              ),
              KonataTheme.cinemaObsidian.withValues(alpha: 0.0),
            ],
          ),
        ),
        child: _buildRawLogoImage(logoUrl, maxW: maxW, maxH: maxH),
      );
    } else {
      scrimContainer = _buildRawLogoImage(logoUrl, maxW: maxW, maxH: maxH);
    }

    if (widget.onTapEditLogo == null) return scrimContainer;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onSecondaryTap: widget.onTapEditLogo,
      child: scrimContainer,
    );
  }

  Widget _buildRawLogoImage(
    String logoUrl, {
    required double maxW,
    required double maxH,
  }) {
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxW, maxHeight: maxH),
      child: DetailManagedImage(
        logoUrl,
        loader: widget.imageLoader,
        owner: widget.work.id,
        artwork: ManagedArtwork.logo,
        imageSize: TmdbImageSize.original,
        fit: BoxFit.contain,
        alignment: widget.logoAlignment,
        onImageResolved: (img, _) => _handleLogoResolved(img, logoUrl),
        errorBuilder: (_, _, _) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && !_logoLoadFailed) {
              setState(() => _logoLoadFailed = true);
            }
          });
          return _buildStylizedTextTitle(context);
        },
      ),
    );
  }

  Widget _buildStylizedTextTitle(BuildContext context) {
    final p = context.palette;
    final textScaler = MediaQuery.textScalerOf(context);
    final locale = Localizations.maybeLocaleOf(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        final maxW = constraints.hasBoundedWidth
            ? math.min(constraints.maxWidth, 640.0)
            : (widget.isCompactViewport ? 320.0 : 540.0);
        final plan = DetailTitleTypographyResolver.resolve(
          title: widget.work.title,
          originalTitle: widget.work.originalTitle,
          maxWidth: maxW,
          isCompactViewport: widget.isCompactViewport,
          textScaler: textScaler,
          locale: locale,
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              plan.primaryText,
              maxLines: plan.primaryMaxLines,
              overflow: TextOverflow.ellipsis,
              style: KonataTheme.detailTextStyle(
                palette: p,
                fontSize: plan.primaryFontSize,
                fontWeight: plan.useCondensedWeight
                    ? FontWeight.w700
                    : FontWeight.w800,
                height: plan.primaryLineHeight,
                letterSpacing: plan.primaryLetterSpacing,
                color: (widget.onDarkBackdrop || p.isDark)
                    ? KonataTheme.pureWhite
                    : KonataTheme.detailPrimaryTextColor(p),
              ),
            ),
            if (plan.secondaryText != null) ...[
              const SizedBox(height: 5),
              Text(
                plan.secondaryText!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: KonataTheme.detailTextStyle(
                  palette: p,
                  fontSize: widget.isCompactViewport
                      ? KonataTheme.fontSizeBodyXs
                      : KonataTheme.fontSizeSubtitle,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 0.4,
                  color: (widget.onDarkBackdrop || p.isDark)
                      ? KonataTheme.overlayWhiteTextSub
                      : KonataTheme.detailSecondaryTextColor(p),
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}
