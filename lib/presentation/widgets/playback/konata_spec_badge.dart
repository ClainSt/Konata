import 'package:flutter/material.dart';

import '../../theme/konata_palette.dart';
import '../../theme/konata_playback_tokens.dart';
import '../../theme/konata_theme.dart';

/// 实时音画规格胶囊徽标（如 `HEVC · 10bit · 1080p`、`FLAC · 24-bit · 96 kHz`、`WASAPI 独占`）。
class KonataSpecBadge extends StatelessWidget {
  /// 创建实时规格徽标。
  const KonataSpecBadge({
    super.key,
    required this.label,
    this.icon,
    this.highlighted = false,
    this.darkOverlay = false,
  });

  /// 规格标签文本（非空时显示）。
  final String label;

  /// 可选前置小图标。
  final IconData? icon;

  /// 是否突出强调（如 HDR / 无损独占状态）。
  final bool highlighted;

  /// 是否叠放于视频画面顶栏（统一高对比度半透明深色衬底 + 亮白锐利文字与细微描边）。
  final bool darkOverlay;

  @override
  Widget build(BuildContext context) {
    if (label.trim().isEmpty) return const SizedBox.shrink();
    final p = context.palette;

    final Color bgColor;
    final Color borderColor;
    final Color textColor;

    if (darkOverlay) {
      bgColor = KonataPlaybackTokens.videoOverlayBadgeBg;
      borderColor = KonataPlaybackTokens.videoOverlayBadgeBorder;
      textColor = KonataPlaybackTokens.videoOverlayBadgeFg;
    } else if (highlighted) {
      bgColor = p.primaryButtonBg.withValues(alpha: 0.14);
      borderColor = p.primaryButtonBg.withValues(alpha: 0.35);
      textColor = p.textPrimary;
    } else {
      bgColor = KonataPlaybackTokens.softFill(p);
      borderColor = p.isDark
          ? KonataPlaybackTokens.glassBorder(p)
          : KonataTheme.darkInkBorder(p);
      textColor = p.isDark ? p.textSecondary : p.textPrimary;
    }

    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.15,
      child: Container(
        padding: KonataPlaybackTokens.specBadgePadding,
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(
            KonataPlaybackTokens.specBadgeRadius,
          ),
          border: Border.all(color: borderColor, width: 1),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 12, color: textColor),
              const SizedBox(width: 4),
            ],
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: textColor,
                  fontSize: KonataPlaybackTokens.specBadgeFontSize,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.15,
                  fontFeatures: KonataPlaybackTokens.tabularNumbers,
                  height: 1.1,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 选集列表与详情卡共用的「正片 / 特典」语义胶囊徽标。
class EpisodeCategoryBadge extends StatelessWidget {
  /// 创建选集类别胶囊徽标。
  const EpisodeCategoryBadge({super.key, required this.isSpecial});

  /// 是否为特典条目（`false` 时显示显式 `正片`）。
  final bool isSpecial;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final accentBadge = p.accentBadge;

    final Color bgColor;
    final Color borderColor;
    final Color textColor;
    final String label;

    if (!isSpecial) {
      label = '正片';
      bgColor = accentBadge.bg;
      borderColor = accentBadge.border;
      textColor = accentBadge.fg;
    } else {
      label = '特典';
      bgColor = KonataTheme.specNeutralBadgeBg(p);
      borderColor = KonataTheme.specNeutralBadgeBorder(p);
      textColor = p.textPrimary;
    }

    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.15,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6.5, vertical: 2),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(
            KonataPlaybackTokens.specBadgeRadius,
          ),
          border: Border.all(color: borderColor, width: 1.0),
        ),
        child: Text(
          label,
          maxLines: 1,
          softWrap: false,
          style: TextStyle(
            color: textColor,
            fontSize: KonataTheme.fontSizeBadge,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.15,
            height: 1.1,
          ),
        ),
      ),
    );
  }
}
