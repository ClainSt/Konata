import 'package:flutter/material.dart';

import '../theme/konata_palette.dart';
import '../theme/konata_playback_tokens.dart';
import '../theme/konata_theme.dart';

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
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(
            Icons.auto_awesome_outlined,
            size: 18,
            color: p.warning,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '待人工复核确认',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: p.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  detailText,
                  style: TextStyle(
                    fontSize: 12,
                    color: p.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          TextButton(
            onPressed: onDismiss,
            style: TextButton.styleFrom(
              foregroundColor: p.textSecondary,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            ),
            child: const Text('忽略提示', style: TextStyle(fontSize: 12)),
          ),
          const SizedBox(width: 6),
          FilledButton.tonalIcon(
            onPressed: onManualMatch,
            icon: const Icon(Icons.saved_search_rounded, size: 16),
            label: const Text('确认匹配', style: TextStyle(fontSize: 12)),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            ),
          ),
        ],
      ),
    );
  }
}
