import 'package:engine_scraping/engine_scraping.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:konata_design_system/konata_design_system.dart';

import '../data/library_models.dart';
import '../providers.dart';
import 'managed_image.dart';

/// 待复核弹窗内的单条待纠偏作品卡片组件。
class ReviewWorkItemCard extends ConsumerStatefulWidget {
  /// 创建待复核作品卡片。
  const ReviewWorkItemCard({
    super.key,
    required this.work,
    required this.onRematch,
    required this.onManualMatch,
    required this.onDismissReview,
    required this.onInspectSourceFiles,
    required this.onDeleteWork,
    required this.onApplyCandidate,
  });

  /// 待复核作品模型。
  final Work work;

  /// 点击「重新匹配」回调。
  final Future<void> Function() onRematch;

  /// 点击「手动搜索匹配」回调。
  final VoidCallback onManualMatch;

  /// 点击「直接确认放行」回调。
  final Future<void> Function() onDismissReview;

  /// 点击「查看源文件」回调。
  final VoidCallback onInspectSourceFiles;

  /// 点击「移出媒体库」回调。
  final VoidCallback onDeleteWork;

  /// 一键套用预设 TMDB 候选的回调。
  final Future<void> Function(ScrapeCandidateSummary candidate) onApplyCandidate;

  @override
  ConsumerState<ReviewWorkItemCard> createState() => _ReviewWorkItemCardState();
}

class _ReviewWorkItemCardState extends ConsumerState<ReviewWorkItemCard> {
  List<ScrapeCandidateSummary> _candidates = const <ScrapeCandidateSummary>[];
  bool _loadingCandidates = false;
  bool _busy = false;
  bool _expandedCandidates = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadCandidates());
  }

  Future<void> _loadCandidates() async {
    setState(() => _loadingCandidates = true);
    try {
      final list = await ref
          .read(workManagementControllerProvider)
          .getScrapeCandidates(widget.work.id);
      if (!mounted) return;
      setState(() {
        _candidates = list;
        _loadingCandidates = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingCandidates = false);
    }
  }

  Future<void> _runGuarded(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final work = widget.work;
    final reasonText = ReviewReasonLabels.format(work.reviewReason);
    final isNetErr = ReviewReasonLabels.isNetworkError(work.reviewReason);

    return KonataSurfaceCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 50,
                  height: 75,
                  child: ManagedImage(
                    path: work.posterPath ?? work.bangumiPosterPath,
                    targetWidth: 256,
                    ownerWorkId: work.id,
                    subfolder: PhotoSubfolder.posters,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      work.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w600,
                        color: p.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      reasonText,
                      style: TextStyle(
                        fontSize: 12,
                        color: isNetErr ? p.danger : p.warning,
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        if (work.year != null)
                          KonataSpecBadge(label: '${work.year}'),
                        if (work.tmdbId != null)
                          KonataSpecBadge(label: 'TMDB ${work.tmdbId}'),
                        if (work.bangumiId != null)
                          KonataSpecBadge(label: 'BGM ${work.bangumiId}'),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (!_loadingCandidates && _candidates.isNotEmpty) ...[
            const SizedBox(height: 10),
            InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () =>
                  setState(() => _expandedCandidates = !_expandedCandidates),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
                child: Row(
                  children: [
                    Icon(
                      _expandedCandidates
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                      size: 16,
                      color: p.accent,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '系统推荐候选 (${_candidates.length})',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: p.accent,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (_expandedCandidates) ...[
              const SizedBox(height: 6),
              for (final candidate in _candidates.take(5))
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: p.elevatedSurface.withValues(alpha: 0.45),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: p.hairline),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                candidate.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w600,
                                  color: p.textPrimary,
                                ),
                              ),
                              Text(
                                [
                                  candidate.mediaType == TmdbMediaType.movie
                                      ? '剧场版'
                                      : 'TV 动画',
                                  if (candidate.year != null)
                                    '${candidate.year}',
                                  'TMDB ${candidate.tmdbId}',
                                  '匹配分 ${candidate.score.toStringAsFixed(0)}',
                                ].join(' · '),
                                style: TextStyle(
                                  fontSize: 11.5,
                                  color: p.textMuted,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        KonataPillButton.secondary(
                          label: '采用',
                          compact: true,
                          onPressed: _busy
                              ? null
                              : () => _runGuarded(
                                  () => widget.onApplyCandidate(candidate),
                                ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ],
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              KonataPillButton.primary(
                label: '手动匹配',
                icon: Icons.manage_search_rounded,
                compact: true,
                onPressed: _busy ? null : widget.onManualMatch,
              ),
              KonataPillButton.secondary(
                label: '重新识别',
                icon: Icons.refresh_rounded,
                compact: true,
                onPressed: _busy ? null : () => _runGuarded(widget.onRematch),
              ),
              KonataPillButton.ghost(
                label: '确认放行',
                icon: Icons.check_rounded,
                compact: true,
                onPressed:
                    _busy ? null : () => _runGuarded(widget.onDismissReview),
              ),
              KonataPillButton.ghost(
                label: '源文件',
                icon: Icons.description_outlined,
                compact: true,
                onPressed: _busy ? null : widget.onInspectSourceFiles,
              ),
              KonataPillButton.ghost(
                label: '移出',
                icon: Icons.delete_outline_rounded,
                compact: true,
                onPressed: _busy ? null : widget.onDeleteWork,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
