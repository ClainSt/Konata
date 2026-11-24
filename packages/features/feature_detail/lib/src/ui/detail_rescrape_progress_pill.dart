import 'package:flutter/widgets.dart';
import 'package:konata_design_system/konata_design_system.dart';

import '../state/work_rescrape_state.dart';

/// 详情页顶部无干扰单作重新抓取实时进度胶囊（绑定 [WorkRescrapeState] 密封状态机）。
class DetailRescrapeProgressPill extends StatelessWidget {
  /// 创建单作重刮进度胶囊组件。
  const DetailRescrapeProgressPill({
    super.key,
    required this.state,
    this.onDismiss,
  });

  /// 当前密封状态机快照。
  final WorkRescrapeState state;

  /// 点击完成或失败态胶囊时的关闭回调。
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;

    return AnimatedSwitcher(
      duration: KonataTheme.standardTransition,
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      child: switch (state) {
        WorkRescrapeIdle() => const SizedBox.shrink(
          key: ValueKey<String>('rescrape-idle'),
        ),
        WorkRescrapeRunning(
          :final stageLabel,
          :final stepIndex,
          :final totalSteps,
          :final detailText,
          :final fraction,
          :final percent,
        ) =>
          _buildCapsule(
            context,
            key: const ValueKey<String>('rescrape-running'),
            p: p,
            accentColor: p.accent,
            leading: SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(p.accent),
              ),
            ),
            text: detailText != null && detailText.isNotEmpty
                ? '$stageLabel · $detailText'
                : stageLabel,
            trailing: Text(
              '$stepIndex/$totalSteps ($percent%)',
              style: TextStyle(
                color: p.accent,
                fontSize: KonataTheme.fontSizeBadge,
                fontWeight: FontWeight.w700,
              ),
            ),
            progressFraction: fraction,
          ),
        WorkRescrapeSucceeded(:final message) => _buildCapsule(
          context,
          key: const ValueKey<String>('rescrape-succeeded'),
          p: p,
          accentColor: p.success,
          leading: Icon(
            Icons.check_circle_rounded,
            size: 15,
            color: p.success,
          ),
          text: message,
          onTap: onDismiss,
        ),
        WorkRescrapeFailed(:final errorMessage) => _buildCapsule(
          context,
          key: const ValueKey<String>('rescrape-failed'),
          p: p,
          accentColor: p.danger,
          leading: Icon(
            Icons.error_outline_rounded,
            size: 15,
            color: p.danger,
          ),
          text: errorMessage,
          onTap: onDismiss,
        ),
      },
    );
  }

  Widget _buildCapsule(
    BuildContext context, {
    required Key key,
    required KonataPalette p,
    required Color accentColor,
    required Widget leading,
    required String text,
    Widget? trailing,
    double? progressFraction,
    VoidCallback? onTap,
  }) {
    final body = ClipRRect(
      borderRadius: KonataTheme.borderRadiusCard,
      child: KonataAdaptiveBackdropBlur(
        filter: KonataTheme.blurFilterMedium,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 420),
          decoration: BoxDecoration(
            color: KonataPlaybackTokens.popoverSurface(p),
            borderRadius: KonataTheme.borderRadiusCard,
            border: Border.all(
              color: accentColor.withValues(alpha: 0.42),
              width: 1,
            ),
          ),
          padding: const EdgeInsets.fromLTRB(12, 7, 12, 7),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  leading,
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      text,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: p.textPrimary,
                        fontSize: KonataTheme.fontSizeCaption,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (trailing != null) ...[
                    const SizedBox(width: 8),
                    trailing,
                  ],
                ],
              ),
              if (progressFraction != null) ...[
                const SizedBox(height: 5),
                ClipRRect(
                  borderRadius: KonataTheme.borderRadiusPill,
                  child: LinearProgressIndicator(
                    value: progressFraction,
                    minHeight: 2.5,
                    backgroundColor: accentColor.withValues(alpha: 0.16),
                    valueColor: AlwaysStoppedAnimation<Color>(accentColor),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );

    if (onTap == null) return KeyedSubtree(key: key, child: body);
    return KeyedSubtree(
      key: key,
      child: GestureDetector(onTap: onTap, child: body),
    );
  }
}
