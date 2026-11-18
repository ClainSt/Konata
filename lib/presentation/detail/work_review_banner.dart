import 'package:flutter/material.dart';

import '../theme/konata_palette.dart';
import '../theme/konata_playback_tokens.dart';
import '../theme/konata_theme.dart';
import '../widgets/design_system/adaptive_responsive_row.dart';
import '../widgets/design_system/konata_pill_button.dart';

/// 作品详情页「待复核」温和快捷横幅（展示中文原因并提供手动匹配与忽略按钮）。
class WorkReviewBanner extends StatelessWidget {
  /// 创建待复核快捷横幅。
  const WorkReviewBanner({
    super.key,
    this.reviewReason,
    required this.onManualMatch,
    required this.onDismiss,
  });

  /// 数据库持久化的中文待复核说明。
  final String? reviewReason;

  /// 点击「手动确认 / 更换匹配」回调。
  final VoidCallback onManualMatch;

  /// 点击「忽略提示」回调。
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final detailText = (reviewReason != null && reviewReason!.trim().isNotEmpty)
        ? reviewReason!.trim()
        : '当前作品匹配置信度不足或存在多个相近候选，建议人工确认。';

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: p.isDark
            ? KonataTheme.reviewBannerDarkBg.withValues(alpha: 0.80)
            : KonataPlaybackTokens.glassSurface(p),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: p.warning.withValues(alpha: 0.55),
        ),
      ),
      child: AdaptiveResponsiveRow(
        minLeadingWidth: 160,
        estimatedTrailingWidth: 185,
        horizontalGap: 12,
        verticalGap: 10,
        leading: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(
                Icons.auto_awesome_outlined,
                size: 18,
                color: p.warning,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '待人工复核确认',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: p.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    detailText,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: p.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        trailing: Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            KonataPillButton.ghost(
              label: '忽略提示',
              compact: true,
              onPressed: onDismiss,
            ),
            KonataPillButton.secondary(
              label: '确认匹配',
              icon: Icons.saved_search_rounded,
              compact: true,
              onPressed: onManualMatch,
            ),
          ],
        ),
      ),
    );
  }
}
