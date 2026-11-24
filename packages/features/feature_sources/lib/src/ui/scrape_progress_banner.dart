import 'package:flutter/widgets.dart';
import 'package:konata_design_system/konata_design_system.dart';

import '../state/scrape_task_phase.dart';

/// 媒体源页面顶部常驻或按需收起的扫库刮削进度横幅。
class ScrapeProgressBanner extends StatelessWidget {
  /// 创建扫库进度横幅。
  const ScrapeProgressBanner({
    super.key,
    required this.phase,
    required this.onInspectDetail,
    required this.onCancelScan,
    required this.onDismissTerminal,
  });

  /// 当前扫库状态机阶段快照。
  final ScrapeTaskPhase phase;

  /// 点击「查看详情」打开实时进度弹窗的回调。
  final VoidCallback onInspectDetail;

  /// 点击「取消」触发安全中断的回调。
  final VoidCallback onCancelScan;

  /// 终态下点击关闭横幅的回调。
  final VoidCallback onDismissTerminal;

  @override
  Widget build(BuildContext context) {
    if (phase is ScrapeIdlePhase) {
      return const SizedBox.shrink();
    }

    final p = context.palette;
    final compact = MediaQuery.sizeOf(context).width < 640;
    final isFailed = phase is ScrapeFailedPhase;
    final isCompleted = phase is ScrapeCompletedPhase;
    final isCancelled = phase is ScrapeCancelledPhase;

    final accentColor = isFailed
        ? p.danger
        : isCompleted
        ? p.success
        : isCancelled
        ? p.warning
        : p.accent;

    final ratio = phase.progressRatio;
    final statusTitle = phase.sourceLabel.isEmpty
        ? phase.statusLabel
        : '${phase.sourceLabel} · ${phase.statusLabel}';

    return KonataSurfaceCard(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      backgroundColor: accentColor.withValues(alpha: 0.08),
      borderColor: accentColor.withValues(alpha: 0.28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              _buildLeadingIcon(accentColor),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      statusTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                        color: p.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      phase.detailLabel,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: p.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              if (!compact) ...[
                const SizedBox(width: 12),
                _buildActions(),
              ],
            ],
          ),
          if (phase.isActive || ratio != null) ...[
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: LinearProgressIndicator(
                value: ratio,
                minHeight: 5,
                backgroundColor: p.hairline,
                valueColor: AlwaysStoppedAnimation<Color>(accentColor),
              ),
            ),
          ],
          if (compact) ...[
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerRight,
              child: _buildActions(),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildLeadingIcon(Color color) {
    if (phase.isActive) {
      return SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(
          strokeWidth: 2.2,
          valueColor: AlwaysStoppedAnimation<Color>(color),
        ),
      );
    }
    return Icon(
      switch (phase.stage) {
        ScrapeTaskStage.completed => Icons.check_circle_outline_rounded,
        ScrapeTaskStage.cancelled => Icons.pause_circle_outline_rounded,
        ScrapeTaskStage.failed => Icons.error_outline_rounded,
        _ => Icons.radar_rounded,
      },
      size: 20,
      color: color,
    );
  }

  Widget _buildActions() {
    return Wrap(
      spacing: 8,
      runSpacing: 6,
      children: [
        KonataPillButton.secondary(
          label: '查看详情',
          compact: true,
          onPressed: onInspectDetail,
        ),
        if (phase.isActive)
          KonataPillButton.ghost(
            label: phase.cancelRequested ? '正在停止' : '取消扫描',
            compact: true,
            onPressed: phase.cancelRequested ? null : onCancelScan,
          )
        else
          KonataPillButton.ghost(
            label: '收起',
            compact: true,
            onPressed: onDismissTerminal,
          ),
      ],
    );
  }
}
