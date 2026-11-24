import 'package:flutter/widgets.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_design_system/konata_design_system.dart';

import '../state/scrape_task_phase.dart';

/// 媒体源页面顶部的后台扫描与刮削实时进度条横幅。
class ScrapeProgressBanner extends StatelessWidget {
  /// 创建扫描进度横幅。
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
    final rawSummary = phase is ScrapeFailedPhase
        ? '扫描失败: ${NetworkErrorSanitizer.toUserMessage(phase.errorMessage ?? '')}'
        : phase.bannerSummaryLabel;
    final phaseLabel = phase.sourceLabel.isEmpty
        ? rawSummary
        : '${phase.sourceLabel} · $rawSummary';

    final actions = <Widget>[
      if (phase.isActive)
        KonataPillButton.ghost(
          label: phase.cancelRequested ? '正在取消' : '取消',
          compact: true,
          onPressed: phase.cancelRequested ? null : onCancelScan,
        ),
      KonataPillButton.secondary(
        label: '查看详情',
        icon: Icons.open_in_new_rounded,
        compact: true,
        onPressed: onInspectDetail,
      ),
      if (!phase.isActive) _BannerDismissButton(onPressed: onDismissTerminal),
    ];

    return KonataSurfaceCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _buildLeadingIndicator(p, isFailed: isFailed),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      phaseLabel,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: isFailed ? p.danger : p.textPrimary,
                        fontSize: KonataTheme.fontSizeBody,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (phase.currentItemName.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        phase.currentItemName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: p.textSecondary,
                          fontSize: KonataTheme.fontSizeCaption,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (!compact) ...[
                const SizedBox(width: 10),
                ..._withHorizontalGaps(actions),
              ],
            ],
          ),
          if (phase.isActive) ...[
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: KonataTheme.borderRadiusPill,
              child: LinearProgressIndicator(
                value:
                    phase.stage == ScrapeTaskStage.running &&
                        phase.totalWorks > 0
                    ? phase.progressRatio
                    : null,
                minHeight: 3,
                backgroundColor: p.progressTrack,
                valueColor: AlwaysStoppedAnimation<Color>(p.progressFill),
              ),
            ),
          ],
          if (compact) ...[
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerRight,
              child: Wrap(
                spacing: 8,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: actions,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildLeadingIndicator(KonataPalette p, {required bool isFailed}) {
    if (phase.isActive) {
      return SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          valueColor: AlwaysStoppedAnimation<Color>(p.progressFill),
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
      size: 18,
      color: switch (phase.stage) {
        ScrapeTaskStage.completed => p.success,
        ScrapeTaskStage.cancelled => p.warning,
        ScrapeTaskStage.failed => p.danger,
        _ => isFailed ? p.danger : p.accent,
      },
    );
  }

  List<Widget> _withHorizontalGaps(List<Widget> items) {
    final result = <Widget>[];
    for (var i = 0; i < items.length; i++) {
      if (i > 0) result.add(const SizedBox(width: 8));
      result.add(items[i]);
    }
    return result;
  }
}

class _BannerDismissButton extends StatefulWidget {
  const _BannerDismissButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  State<_BannerDismissButton> createState() => _BannerDismissButtonState();
}

class _BannerDismissButtonState extends State<_BannerDismissButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final visual = AnimatedContainer(
      duration: KonataTheme.motionFast,
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        color: _hovered ? p.surfaceHover : p.softFill,
        shape: BoxShape.circle,
        border: Border.all(
          color: _hovered ? p.hoverBorder : p.hairline,
          width: 1,
        ),
      ),
      child: Icon(
        Icons.close_rounded,
        size: 16,
        color: _hovered ? p.textPrimary : p.textSecondary,
      ),
    );

    final button = KonataAdaptiveTokens.isAndroid
        ? ConstrainedBox(
            constraints: const BoxConstraints(
              minWidth: KonataAdaptiveTokens.touchTarget,
              minHeight: KonataAdaptiveTokens.touchTarget,
            ),
            child: Center(widthFactor: 1, heightFactor: 1, child: visual),
          )
        : visual;

    return Tooltip(
      message: '关闭提示',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onPressed,
          child: button,
        ),
      ),
    );
  }
}
