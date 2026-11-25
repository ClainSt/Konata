import 'package:engine_scraping/engine_scraping.dart';
import 'package:flutter/widgets.dart';
import 'package:konata_design_system/konata_design_system.dart';

/// 选图弹窗内的正片视频抽帧候选网格单元卡片。
class VideoFrameCandidateTile extends StatefulWidget {
  /// 创建视频抽帧候选卡片。
  const VideoFrameCandidateTile({
    super.key,
    required this.sample,
    required this.selected,
    required this.onTap,
  });

  /// 抽帧采样候选数据。
  final VideoFrameSample sample;

  /// 是否处于选中态。
  final bool selected;

  /// 点击选中回调。
  final VoidCallback onTap;

  @override
  State<VideoFrameCandidateTile> createState() =>
      _VideoFrameCandidateTileState();
}

class _VideoFrameCandidateTileState extends State<VideoFrameCandidateTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final selected = widget.selected;
    final borderColor = selected
        ? p.accent
        : (_hovered ? p.hoverBorder : p.posterBorder);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: KonataTheme.motionFast,
          decoration: BoxDecoration(
            borderRadius: KonataTheme.borderRadiusControl,
            color: p.softFill,
            border: Border.all(color: borderColor, width: selected ? 2.2 : 1.0),
          ),
          child: ClipRRect(
            borderRadius: KonataTheme.borderRadiusThumb,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Image.memory(
                  widget.sample.imageBytes,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                ),
                Positioned(
                  left: 6,
                  top: 6,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ArtworkOverlayMiniBadge(
                        text: '视频抽帧',
                        backgroundColor: KonataTheme.specVideoPurple.withValues(
                          alpha: 0.28,
                        ),
                        borderColor: KonataTheme.specVideoPurple.withValues(
                          alpha: 0.62,
                        ),
                        fontWeight: FontWeight.w700,
                      ),
                      const SizedBox(width: 4),
                      ArtworkOverlayMiniBadge(
                        text: widget.sample.formattedTimestamp,
                        backgroundColor: KonataTheme.scrimBlackDeep,
                        tabularFigures: true,
                      ),
                    ],
                  ),
                ),
                if (selected)
                  const Positioned(
                    top: 6,
                    right: 6,
                    child: _SelectedBadgeChip(),
                  ),
                if (widget.sample.width > 0 && widget.sample.height > 0)
                  Positioned(
                    right: 6,
                    bottom: 6,
                    child: ArtworkOverlayMiniBadge.resolution(
                      '${widget.sample.width}×${widget.sample.height}',
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SelectedBadgeChip extends StatelessWidget {
  const _SelectedBadgeChip();

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: p.accent,
        borderRadius: KonataTheme.borderRadiusPill,
        border: Border.all(color: KonataTheme.overlayWhiteTextMid, width: 1),
        boxShadow: const [
          BoxShadow(
            color: KonataTheme.scrimBlackSubtle,
            blurRadius: 6,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.check_rounded, size: 12, color: KonataTheme.pureWhite),
          SizedBox(width: 2.5),
          Text(
            '已选',
            style: TextStyle(
              color: KonataTheme.pureWhite,
              fontSize: KonataTheme.fontSizeBadge,
              fontWeight: FontWeight.w700,
              height: 1.1,
            ),
          ),
        ],
      ),
    );
  }
}

/// 选图弹窗内图片加载失败时的可点击重试兜底视图。
class ArtworkErrorFallback extends StatelessWidget {
  /// 创建图片失败兜底视图。
  const ArtworkErrorFallback({
    super.key,
    required this.compact,
    required this.onRetry,
  });

  /// 是否使用紧凑单行样式。
  final bool compact;

  /// 点击重试回调。
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Center(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onRetry,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: 6,
            vertical: compact ? 2 : 10,
          ),
          child: compact
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.broken_image_outlined,
                      size: 14,
                      color: p.textMuted,
                    ),
                    const SizedBox(width: 5),
                    Flexible(
                      child: Text(
                        '图片加载失败，点击重试',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: p.textSecondary,
                          fontSize: KonataTheme.fontSizeCaptionXs,
                          fontWeight: FontWeight.w500,
                          height: 1.15,
                        ),
                      ),
                    ),
                  ],
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.broken_image_outlined,
                      size: 26,
                      color: p.textMuted,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '图片加载失败，点击重试',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: p.textSecondary,
                        fontSize: KonataTheme.fontSizeCaption,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}

/// 透明标题徽标候选网格的棋盘格底板（兼顾浅色与深色透明字标对比度）。
class DarkLogoCheckerBackground extends StatelessWidget {
  /// 创建透明棋盘格底板。
  const DarkLogoCheckerBackground({super.key});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(painter: _DarkLogoCheckerPainter());
  }
}

class _DarkLogoCheckerPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    const cell = 12.0;
    final paintA = Paint()..color = KonataTheme.logoCheckerDarkCellA;
    final paintB = Paint()..color = KonataTheme.logoCheckerDarkCellB;
    canvas.drawRect(Offset.zero & size, paintA);
    for (var y = 0.0; y < size.height; y += cell) {
      final rowEven = ((y / cell).floor() % 2) == 0;
      for (var x = rowEven ? cell : 0.0; x < size.width; x += cell * 2) {
        canvas.drawRect(Rect.fromLTWH(x, y, cell, cell), paintB);
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// 选图弹窗通用的角标徽章（来源、语言、时间码与分辨率）。
class ArtworkOverlayMiniBadge extends StatelessWidget {
  /// 创建通用角标徽章。
  const ArtworkOverlayMiniBadge({
    super.key,
    required this.text,
    required this.backgroundColor,
    this.textColor = KonataTheme.pureWhite,
    this.textGradient,
    this.borderColor,
    this.fontWeight = FontWeight.w600,
    this.tabularFigures = false,
    this.shadows,
  });

  /// 分辨率角标便捷构造器。
  const ArtworkOverlayMiniBadge.resolution(this.text, {super.key})
    : backgroundColor = KonataTheme.scrimBlackDeep,
      textColor = KonataTheme.pureWhite,
      textGradient = null,
      borderColor = KonataTheme.overlayWhiteBorder,
      fontWeight = FontWeight.w600,
      tabularFigures = true,
      shadows = null;

  /// 角标文本。
  final String text;

  /// 背景填充色。
  final Color backgroundColor;

  /// 前景文字色。
  final Color textColor;

  /// 可选品牌渐变文字色。
  final Gradient? textGradient;

  /// 可选边框色。
  final Color? borderColor;

  /// 字重。
  final FontWeight fontWeight;

  /// 是否使用等宽数字。
  final bool tabularFigures;

  /// 可选投影列表。
  final List<Shadow>? shadows;

  @override
  Widget build(BuildContext context) {
    final textWidget = Text(
      text,
      textAlign: TextAlign.center,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        color: textGradient == null ? textColor : KonataTheme.pureWhite,
        fontSize: KonataTheme.fontSizeBadge,
        fontWeight: fontWeight,
        height: 1.2,
        leadingDistribution: TextLeadingDistribution.even,
        fontFeatures: tabularFigures
            ? const [FontFeature.tabularFigures()]
            : null,
        shadows: shadows,
      ),
    );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2.5),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: KonataTheme.borderRadiusChip,
        border: borderColor == null
            ? null
            : Border.all(color: borderColor!, width: 0.9),
      ),
      child: Align(
        alignment: Alignment.center,
        widthFactor: 1,
        heightFactor: 1,
        child: textGradient == null
            ? textWidget
            : ShaderMask(
                shaderCallback: (bounds) => textGradient!.createShader(
                  Rect.fromLTWH(0, 0, bounds.width, bounds.height),
                ),
                blendMode: BlendMode.srcIn,
                child: textWidget,
              ),
      ),
    );
  }
}
