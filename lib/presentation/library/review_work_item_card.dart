import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/providers/artwork_provider.dart';
import '../../application/providers/library_providers.dart';
import '../../application/providers/scraping_providers.dart';
import '../../application/providers/work_management_provider.dart';
import '../../domain/models/tmdb_models.dart';
import '../../domain/models/work.dart';
import '../dialogs/manual_match_dialog.dart';
import '../dialogs/source_files_review_dialog.dart';
import '../dialogs/work_merge_target_dialog.dart';
import '../theme/konata_palette.dart';
import '../widgets/design_system/ellipsis_text_with_tooltip.dart';
import '../widgets/design_system/konata_glass_dialog.dart';
import '../widgets/design_system/konata_pill_button.dart';
import '../widgets/design_system/konata_surface_card.dart';
import '../widgets/design_system/konata_toast.dart';
import '../widgets/managed_image.dart';
import 'review_reason_labels.dart';

/// 待复核作品共用展示与快速处置卡片（复用于媒体库右侧抽屉与扫描进度弹窗）。
class ReviewWorkItemCard extends ConsumerStatefulWidget {
  /// 创建待复核作品卡片。
  const ReviewWorkItemCard({super.key, required this.item});

  /// 待复核作品聚合项。
  final WorkLibraryItem item;

  @override
  ConsumerState<ReviewWorkItemCard> createState() => _ReviewWorkItemCardState();
}

class _ReviewWorkItemCardState extends ConsumerState<ReviewWorkItemCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final item = widget.item;
    final work = item.work;
    final candidatesAsync = ref.watch(workScrapeCandidatesProvider(work.id));
    final imageLoader = ref.watch(tmdbImageLoaderProvider);
    final folderSummary = _deriveFolderLabel(item);

    return KonataSurfaceCard(
      padding: const EdgeInsets.all(14),
      enableHover: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _expanded = !_expanded),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(
                      child: EllipsisTextWithTooltip(
                        text: work.title,
                        maxLines: 1,
                        style: TextStyle(
                          color: p.textPrimary,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    KonataPillButton.ghost(
                      label: '查看源文件',
                      icon: Icons.folder_open_rounded,
                      compact: true,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      onPressed: () {
                        showSourceFilesReviewDialog(context, item: item);
                      },
                    ),
                  ],
                ),
                if (folderSummary.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(
                    folderSummary,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: p.textMuted,
                      fontSize: 11.2,
                      fontFamily: 'Consolas',
                    ),
                  ),
                ],
                const SizedBox(height: 3),
                Text(
                  '${item.variants.length} 个文件${work.year != null ? ' · ${work.year}' : ''}',
                  style: TextStyle(color: p.textSecondary, fontSize: 12),
                ),
              ],
            ),
          ),
          if ((work.reviewReason != null &&
                  work.reviewReason!.trim().isNotEmpty) ||
              work.scrapeStatus == ScrapeStatus.unmatched) ...[
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: p.warning.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: p.warning.withValues(alpha: 0.35)),
              ),
              child: Text(
                (work.reviewReason != null &&
                        work.reviewReason!.trim().isNotEmpty)
                    ? work.reviewReason!.trim()
                    : '未搜索到匹配词条，请手动检索或指定 TMDB ID',
                style: TextStyle(
                  color: p.warning,
                  fontSize: 11.2,
                  height: 1.35,
                ),
              ),
            ),
          ],
          const SizedBox(height: 10),
          LayoutBuilder(
            builder: (context, constraints) {
              final isCompactRow = constraints.maxWidth < 490;
              final actionPadding = EdgeInsets.symmetric(
                horizontal: isCompactRow ? 5.5 : 9,
                vertical: 6.5,
              );
              final searchBtn = KonataPillButton.secondary(
                label: '手动搜索',
                compact: true,
                padding: EdgeInsets.symmetric(
                  horizontal: isCompactRow ? 6.5 : 10,
                  vertical: 6.5,
                ),
                onPressed: () {
                  showKonataGlassDialog<void>(
                    context: context,
                    builder: (_) => ManualMatchDialog(
                      workId: work.id,
                      initialQuery: work.title,
                    ),
                  );
                },
              );
              final dismissBtn = KonataPillButton.ghost(
                label: '忽略复核',
                compact: true,
                padding: actionPadding,
                onPressed: () async {
                  await ref
                      .read(workManagementProvider)
                      .dismissWorkReview(work.id);
                  if (context.mounted) {
                    showKonataToast(context, '已忽略「${work.title}」的复核提醒');
                  }
                },
              );
              final mergeBtn = KonataPillButton.ghost(
                label: '并入已有作品',
                compact: true,
                padding: actionPadding,
                onPressed: () async {
                  final outcome = await showKonataGlassDialog<WorkMergeOutcome>(
                    context: context,
                    builder: (_) => WorkMergeTargetDialog(
                      sourceWorkId: work.id,
                      sourceWorkTitle: work.title,
                      initialMode: item.episodeCount == 0
                          ? MergeVideoCategoryMode.asExtra
                          : MergeVideoCategoryMode.preserve,
                    ),
                  );
                  if (outcome != null && context.mounted) {
                    showKonataToast(
                      context,
                      '已将「${work.title}」并入「${outcome.targetWork.title}」',
                    );
                  }
                },
              );
              final hideBtn = KonataPillButton.ghost(
                label: '隐藏作品',
                compact: true,
                padding: actionPadding,
                onPressed: () async {
                  await ref.read(workManagementProvider).hideWork(work.id);
                  if (context.mounted) {
                    showKonataToast(context, '已隐藏「${work.title}」');
                  }
                },
              );
              final toggleBtn = candidatesAsync.maybeWhen(
                data: (candidates) {
                  final topCount = candidates.take(5).length;
                  if (topCount == 0) return const SizedBox.shrink();
                  return KonataPillButton.ghost(
                    label: _expanded ? '收起候选' : '展开候选 ($topCount)',
                    compact: true,
                    padding: EdgeInsets.symmetric(
                      horizontal: isCompactRow ? 5.5 : 8,
                      vertical: 6.5,
                    ),
                    trailing: AnimatedRotation(
                      turns: _expanded ? 0.5 : 0.0,
                      duration: const Duration(milliseconds: 180),
                      curve: Curves.easeOutCubic,
                      child: Icon(
                        Icons.keyboard_arrow_down_rounded,
                        size: isCompactRow ? 16 : 18,
                        color: p.textSecondary,
                      ),
                    ),
                    onPressed: () => setState(() => _expanded = !_expanded),
                  );
                },
                orElse: () => const SizedBox.shrink(),
              );

              if (constraints.maxWidth >= 420) {
                final gap = isCompactRow ? 3.0 : 6.0;
                return Row(
                  children: [
                    searchBtn,
                    SizedBox(width: gap),
                    mergeBtn,
                    SizedBox(width: gap),
                    dismissBtn,
                    SizedBox(width: gap),
                    hideBtn,
                    const Spacer(),
                    toggleBtn,
                  ],
                );
              }
              return Wrap(
                spacing: 6,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  searchBtn,
                  mergeBtn,
                  dismissBtn,
                  hideBtn,
                  toggleBtn,
                ],
              );
            },
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: candidatesAsync.when(
              data: (candidates) {
                final topCandidates = candidates.take(5).toList(growable: false);
                if (topCandidates.isEmpty) {
                  return Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      '暂无自动候选，请点击上方「手动搜索」或输入 TMDB ID。',
                      style: TextStyle(color: p.textMuted, fontSize: 12),
                    ),
                  );
                }
                if (!_expanded) {
                  return const SizedBox.shrink();
                }
                return Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Column(
                    children: [
                      for (final c in topCandidates)
                        _ReviewCandidateRow(
                          candidate: c,
                          imageLoader: imageLoader,
                          onAdopt: () async {
                            final result = await ref
                                .read(scrapeControllerProvider.notifier)
                                .rebindWork(
                                  workId: work.id,
                                  tmdbId: c.tmdbId,
                                  mediaType: c.mediaType,
                                );
                            if (context.mounted && result.id != work.id) {
                              showKonataToast(
                                context,
                                '已自动并入已有作品「${result.title}」',
                              );
                            }
                          },
                        ),
                    ],
                  ),
                );
              },
              loading: () => _expanded
                  ? const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: LinearProgressIndicator(minHeight: 2),
                    )
                  : const SizedBox.shrink(),
              error: (_, _) => const SizedBox.shrink(),
            ),
          ),
        ],
      ),
    );
  }
}

class _ReviewCandidateRow extends StatelessWidget {
  const _ReviewCandidateRow({
    required this.candidate,
    required this.imageLoader,
    required this.onAdopt,
  });

  final ScrapeCandidateSummary candidate;
  final ManagedImageLoader imageLoader;
  final VoidCallback onAdopt;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final labels = ReviewReasonLabels.formatAll(
      candidate.reasons,
    ).toSet().take(4).toList(growable: false);

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(5),
            child: SizedBox(
              width: 32,
              height: 44,
              child: candidate.posterPath != null
                  ? ManagedImage(
                      candidate.posterPath!,
                      loader: imageLoader,
                      fit: BoxFit.cover,
                    )
                  : Container(color: p.softFill),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  candidate.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: p.textPrimary, fontSize: 12.5),
                ),
                if (candidate.originalTitle != null &&
                    candidate.originalTitle!.trim().isNotEmpty &&
                    candidate.originalTitle!.trim() != candidate.title)
                  Text(
                    candidate.originalTitle!.trim(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: p.textMuted, fontSize: 10.5),
                  ),
                Text(
                  '${candidate.mediaType.name.toUpperCase()} · '
                  '${candidate.year ?? '未知年份'}'
                  '${candidate.episodeCount != null && candidate.episodeCount! > 0 ? ' · 共 ${candidate.episodeCount} 集' : ''}'
                  ' · 匹配度 ${candidate.score.toStringAsFixed(0)}',
                  style: TextStyle(color: p.textMuted, fontSize: 11),
                ),
                if (labels.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Wrap(
                    spacing: 4,
                    runSpacing: 3,
                    children: [
                      for (final label in labels)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 1.5,
                          ),
                          decoration: BoxDecoration(
                            color: p.softFill,
                            borderRadius: BorderRadius.circular(5),
                          ),
                          child: Text(
                            label,
                            style: TextStyle(
                              color: p.textSecondary,
                              fontSize: 10,
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          KonataPillButton.primary(
            label: '采纳',
            compact: true,
            onPressed: onAdopt,
          ),
        ],
      ),
    );
  }
}

String _deriveFolderLabel(WorkLibraryItem item) {
  if (item.variants.isEmpty) return '';
  final rel = item.variants.first.relativePath.replaceAll('\\', '/');
  final idx = rel.lastIndexOf('/');
  return idx > 0 ? rel.substring(0, idx) : rel;
}
