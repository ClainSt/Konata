import 'package:flutter/material.dart';

import '../../theme/konata_palette.dart';
import '../../theme/konata_playback_tokens.dart';

/// 实时音画规格胶囊徽标（如 `HEVC · 10bit · 1080p`、`FLAC · 24-bit · 96 kHz`、`WASAPI 独占`）。
///
/// 全站音频迷你栏、流光音频页与内置视频页唯一共用实现。
class KonataSpecBadge extends StatelessWidget {
  /// 创建实时规格徽标。
  const KonataSpecBadge({
    super.key,
    required this.label,
    this.icon,
    this.highlighted = false,
    this.forceOnDarkOverlay = false,
  });

  /// 规格标签文本（非空时显示）。
  final String label;

  /// 可选前置小图标。
  final IconData? icon;

  /// 是否突出强调（如 HDR / 无损独占状态）。
  final bool highlighted;

  /// 是否强制适配深色视频或暗夜流光背景。
  final bool forceOnDarkOverlay;

  @override
  Widget build(BuildContext context) {
    if (label.trim().isEmpty) return const SizedBox.shrink();
    final p = context.palette;

    final Color bgColor;
    final Color borderColor;
    final Color textColor;

    if (forceOnDarkOverlay) {
      bgColor = highlighted
          ? Colors.white.withValues(alpha: 0.20)
          : KonataPlaybackTokens.osdSoftFill;
      borderColor = highlighted
          ? Colors.white.withValues(alpha: 0.36)
          : KonataPlaybackTokens.osdBorderLight;
      textColor = KonataPlaybackTokens.osdTextPrimary;
    } else {
      bgColor = highlighted ? p.primaryButtonBg.withValues(alpha: 0.14) : p.softFill;
      borderColor = highlighted
          ? p.primaryButtonBg.withValues(alpha: 0.35)
          : p.hairline;
      textColor = highlighted ? p.textPrimary : p.textSecondary;
    }

    return Container(
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
          Text(
            label,
            maxLines: 1,
            softWrap: false,
            style: TextStyle(
              color: textColor,
              fontSize: KonataPlaybackTokens.specBadgeFontSize,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.15,
              fontFeatures: KonataPlaybackTokens.tabularNumbers,
              height: 1.1,
            ),
          ),
        ],
      ),
    );
  }
}
