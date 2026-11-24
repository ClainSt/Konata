import 'package:engine_scraping/engine_scraping.dart';
import 'package:flutter/widgets.dart';
import 'package:konata_design_system/konata_design_system.dart';

/// 待复核或未匹配作品在详情页内展示的辅助核对横幅（严禁使用实心弹窗或 `material_ui`）。
class WorkReviewBanner extends StatelessWidget {
  /// 创建人工复核横幅组件。
  const WorkReviewBanner({
    super.key,
    required this.work,
    required this.candidates,
    required this.folderPath,
    required this.onRematch,
    required this.onOpenManualMatch,
    required this.onOpenSourceFiles,
    required this.onDismissReview,
    required this.onSelectCandidate,
    this.rematching = false,
  });

  /// 目标作品。
  final Work work;

  /// Top-5 备选刮削候选摘要列表。
  final List<ScrapeCandidateSummary> candidates;

  /// 来源相对目录路径提示。
  final String? folderPath;

  /// 是否正在执行在线自动重新匹配。
  final bool rematching;

  /// 触发单作重新自动匹配。
  final VoidCallback onRematch;

  /// 打开手动精确搜索匹配弹窗。
  final VoidCallback onOpenManualMatch;

  /// 打开源文件列表审查与拆分弹窗。
  final VoidCallback onOpenSourceFiles;

  /// 确认保留当前本地原名并解除复核提示。
  final VoidCallback onDismissReview;

  /// 直接一键绑定某条 `TMDB` 候选。
  final void Function(ScrapeCandidateSummary candidate) onSelectCandidate;

  @override
  Widget build(BuildContext context) {
    if (work.scrapeStatus == ScrapeStatus.matched) {
      return const SizedBox.shrink();
    }
    final p = context.palette;
    final isReview = work.scrapeStatus == ScrapeStatus.needsReview;
    final accentColor = isReview ? p.warning : p.danger;

    return KonataSurfaceCard(
      padding: const EdgeInsets.all(14),
      borderColor: accentColor.withValues(alpha: 0.45),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(
                isReview
                    ? Icons.fact_check_outlined
                    : Icons.help_outline_rounded,
                size: 18,
                color: accentColor,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  isReview ? '该条目匹配置信度偏低，建议人工复核确认' : '暂未自动匹配到在线元数据条目',
                  style: TextStyle(
                    color: p.textPrimary,
                    fontSize: KonataTheme.fontSizeBodySm,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              KonataPillButton.ghost(
                label: '忽略并保留原名',
                compact: true,
                onPressed: onDismissReview,
              ),
            ],
          ),
          if ((work.reviewReason?.trim().isNotEmpty ?? false) ||
              (folderPath?.trim().isNotEmpty ?? false)) ...[
            const SizedBox(height: 6),
            Text(
              [
                if (work.reviewReason?.trim().isNotEmpty ?? false)
                  work.reviewReason!.trim(),
                if (folderPath?.trim().isNotEmpty ?? false)
                  '来源目录：$folderPath',
              ].join(' · '),
              style: TextStyle(
                color: p.textSecondary,
                fontSize: KonataTheme.fontSizeCaption,
              ),
            ),
          ],
          if (candidates.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                for (final cand in candidates.take(4))
                  KonataPillButton.secondary(
                    label: cand.year != null
                        ? '${cand.title} (${cand.year})'
                        : cand.title,
                    icon: Icons.check_circle_outline_rounded,
                    compact: true,
                    onPressed: () => onSelectCandidate(cand),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              KonataPillButton.primary(
                label: rematching ? '正在重试匹配...' : '重新自动匹配',
                icon: Icons.auto_fix_high_rounded,
                compact: true,
                onPressed: rematching ? null : onRematch,
              ),
              KonataPillButton.secondary(
                label: '手动精确匹配',
                icon: Icons.search_rounded,
                compact: true,
                onPressed: onOpenManualMatch,
              ),
              KonataPillButton.ghost(
                label: '查看源文件',
                icon: Icons.folder_open_rounded,
                compact: true,
                onPressed: onOpenSourceFiles,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
