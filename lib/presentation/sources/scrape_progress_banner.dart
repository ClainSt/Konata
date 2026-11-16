import 'package:flutter/material.dart';

import '../../application/scraping/scrape_progress.dart';
import '../theme/konata_palette.dart';
import '../widgets/design_system/konata_pill_button.dart';
import '../widgets/design_system/konata_surface_card.dart';

/// 媒体源页面顶部的后台扫描与刮削实时进度条横幅。
class ScrapeProgressBanner extends StatelessWidget {
  /// 创建扫描进度横幅。
  const ScrapeProgressBanner({
    super.key,
    required this.progress,
    required this.onInspect,
    this.onCancel,
    this.onDismiss,
  });

  /// 当前刮削管线状态快照。
  final ScrapeProgress progress;

  /// 点击查看详细扫描日志弹窗回调。
  final VoidCallback onInspect;

  /// 点击取消扫描回调（运行中可用）。
  final VoidCallback? onCancel;

  /// 点击关闭横幅回调（非运行状态可用）。
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final phaseLabel = switch (progress.phase) {
      ScrapePhase.idle => '就绪',
      ScrapePhase.scanning =>
        '正在遍历目录 (${progress.scannedDirectories} 目录 · ${progress.totalVideos} 视频)',
      ScrapePhase.grouping => '后台 Isolate 归组解析中...',
      ScrapePhase.scraping =>
        '正在刮削 (${progress.processedWorks}/${progress.totalWorks})',
      ScrapePhase.completed =>
        '扫描刮削完成：已匹配 ${progress.matchedWorks}，待复核 ${progress.reviewWorks}，未识别 ${progress.unmatchedWorks}',
      ScrapePhase.cancelled =>
        '已取消扫描：已遍历 ${progress.scannedDirectories} 目录，已处理 ${progress.processedWorks} 部作品',
      ScrapePhase.failed => '扫描失败: ${progress.errorMessage ?? ''}',
    };

    return KonataSurfaceCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      phaseLabel,
                      style: TextStyle(
                        color: p.textPrimary,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (progress.currentItemName.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        progress.currentItemName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: p.textSecondary,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 10),
              if (onCancel != null) ...[
                KonataPillButton.ghost(
                  label: '取消',
                  compact: true,
                  onPressed: onCancel,
                ),
                const SizedBox(width: 8),
              ],
              KonataPillButton.secondary(
                label: '查看详情',
                icon: Icons.open_in_new_rounded,
                compact: true,
                onPressed: onInspect,
              ),
              if (onDismiss != null) ...[
                const SizedBox(width: 8),
                _BannerDismissButton(onPressed: onDismiss!),
              ],
            ],
          ),
          if (progress.isRunning) ...[
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: progress.totalWorks > 0 ? progress.fraction : null,
                minHeight: 4,
                backgroundColor: p.softFill,
                valueColor: AlwaysStoppedAnimation<Color>(p.textPrimary),
              ),
            ),
          ],
        ],
      ),
    );
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
    return Tooltip(
      message: '关闭提示',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onPressed,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
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
          ),
        ),
      ),
    );
  }
}
