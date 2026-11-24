import 'dart:math' as math;

import 'package:engine_scraping/engine_scraping.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:konata_design_system/konata_design_system.dart';

import '../data/library_models.dart';
import '../providers.dart';
import 'managed_image.dart';

/// 并入已有作品弹窗的选择结果（包含目标作品与正片/特典归类策略）。
class WorkMergeSelection {
  /// 构造合并选择结果。
  const WorkMergeSelection({
    required this.targetWork,
    required this.categoryMode,
  });

  /// 接收合并文件的目标作品。
  final Work targetWork;

  /// 正片或特典归类模式。
  final MergeVideoCategoryMode categoryMode;
}

/// 弹出并入已有作品目标选择框，返回目标作品及分类策略（取消返回空）。
Future<WorkMergeSelection?> showWorkMergeSelectionDialog(
  BuildContext context, {
  required Work sourceWork,
  int? overrideFileCount,
  String? dialogTitle,
}) {
  return showKonataGlassDialog<WorkMergeSelection>(
    context: context,
    builder: (_) => _WorkMergeTargetDialog(
      sourceWork: sourceWork,
      overrideFileCount: overrideFileCount,
      dialogTitle: dialogTitle,
    ),
  );
}

/// 向后兼容入口：弹出目标选择框并仅返回所选目标作品。
Future<Work?> showWorkMergeTargetDialog(
  BuildContext context, {
  required Work sourceWork,
}) async {
  final selection = await showWorkMergeSelectionDialog(
    context,
    sourceWork: sourceWork,
  );
  return selection?.targetWork;
}

class _WorkMergeTargetDialog extends ConsumerStatefulWidget {
  const _WorkMergeTargetDialog({
    required this.sourceWork,
    this.overrideFileCount,
    this.dialogTitle,
  });

  final Work sourceWork;
  final int? overrideFileCount;
  final String? dialogTitle;

  @override
  ConsumerState<_WorkMergeTargetDialog> createState() =>
      _WorkMergeTargetDialogState();
}

class _WorkMergeTargetDialogState
    extends ConsumerState<_WorkMergeTargetDialog> {
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _searchController = TextEditingController();
  String _query = '';
  String? _selectedWorkId;
  MergeVideoCategoryMode _categoryMode = MergeVideoCategoryMode.preserve;

  @override
  void dispose() {
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  List<Work> _buildSortedCandidates(List<Work> raw) {
    final cleanQuery = _query.trim().toLowerCase();
    final sourceTokens = _extractCompareTokens(widget.sourceWork);
    final filtered = raw.where((w) {
      if (w.id == widget.sourceWork.id) return false;
      if (cleanQuery.isEmpty) return true;
      final hay = <String>[
        w.title,
        w.originalTitle ?? '',
        if (w.year != null) '${w.year}',
        if (w.tmdbId != null) '${w.tmdbId}',
        if (w.bangumiId != null) '${w.bangumiId}',
      ].join('\n').toLowerCase();
      return hay.contains(cleanQuery);
    }).toList();

    int scoreOf(Work candidate) {
      var score = 0;
      if (widget.sourceWork.tmdbId != null &&
          candidate.tmdbId == widget.sourceWork.tmdbId) {
        score += 1000;
      }
      if (widget.sourceWork.bangumiId != null &&
          candidate.bangumiId == widget.sourceWork.bangumiId) {
        score += 900;
      }
      if (widget.sourceWork.year != null &&
          candidate.year == widget.sourceWork.year) {
        score += 80;
      }
      final targetTokens = _extractCompareTokens(candidate);
      for (final token in sourceTokens) {
        if (targetTokens.contains(token)) {
          score += 60;
        }
      }
      final srcTitle = widget.sourceWork.title.trim().toLowerCase();
      final dstTitle = candidate.title.trim().toLowerCase();
      if (srcTitle.isNotEmpty &&
          (dstTitle.contains(srcTitle) || srcTitle.contains(dstTitle))) {
        score += 140;
      }
      return score;
    }

    filtered.sort((a, b) {
      final cmp = scoreOf(b).compareTo(scoreOf(a));
      if (cmp != 0) return cmp;
      return a.title.compareTo(b.title);
    });
    return filtered;
  }

  static Set<String> _extractCompareTokens(Work work) {
    final raw = '${work.title} ${work.originalTitle ?? ''}'.toLowerCase();
    return raw
        .split(RegExp(r'[\s\-_:：·,，。()（）\[\]【】/]+'))
        .where((e) => e.trim().length >= 2)
        .map((e) => e.trim())
        .toSet();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final controller = ref.watch(libraryControllerProvider);
    final allWorks = <Work>[
      for (final item in controller.allVisibleItems) item.work,
      ...controller.hiddenWorks,
      ...controller.reviewWorks,
    ];
    final deduped = <String, Work>{
      for (final w in allWorks) w.id: w,
    }.values.toList(growable: false);
    final candidates = _buildSortedCandidates(deduped);
    final selectedWork = candidates
        .where((w) => w.id == _selectedWorkId)
        .firstOrNull;

    return KonataGlassDialog(
      width: 660,
      maxHeight: 590,
      title: widget.dialogTitle ?? '并入已有作品',
      onClose: () => Navigator.of(context).pop(),
      actions: <Widget>[
        KonataPillButton.ghost(
          label: '取消',
          onPressed: () => Navigator.of(context).pop(),
        ),
        KonataPillButton.primary(
          label: '确认并入',
          onPressed: selectedWork == null
              ? null
              : () => Navigator.of(context).pop(
                  WorkMergeSelection(
                    targetWork: selectedWork,
                    categoryMode: _categoryMode,
                  ),
                ),
        ),
      ],
      child: LayoutBuilder(
        builder: (dialogCtx, outerConstraints) {
          final targetH = outerConstraints.maxHeight.isFinite
              ? math.min(430.0, outerConstraints.maxHeight)
              : 430.0;
          final compactIme =
              KonataGlassDialog.isLandscapeCompactInputActive(dialogCtx);
          return SizedBox(
            height: targetH,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Offstage(
                  offstage: compactIme,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: p.softFill,
                          borderRadius: KonataTheme.borderRadiusControl,
                          border: Border.all(color: p.hairline),
                        ),
                        child: Row(
                          children: <Widget>[
                            Icon(
                              Icons.merge_type_rounded,
                              size: 16,
                              color: p.accent,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                widget.overrideFileCount != null
                                    ? '待并入来源：「${widget.sourceWork.title}」中选中的 ${widget.overrideFileCount} 个文件'
                                    : '待合并来源：「${widget.sourceWork.title}」',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: KonataTheme.bodyLabelStyle(
                                  p,
                                  fontSize: KonataTheme.fontSizeBodySm,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: <Widget>[
                          Text(
                            '归类方式：',
                            style: KonataTheme.captionStyle(
                              p,
                              fontSize: KonataTheme.fontSizeBodySm,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Flexible(
                            child: KonataSegmentedCapsule<MergeVideoCategoryMode>(
                              compact: true,
                              selected: _categoryMode,
                              onChanged: (mode) =>
                                  setState(() => _categoryMode = mode),
                              options:
                                  <KonataSegmentOption<MergeVideoCategoryMode>>[
                                    for (final m in MergeVideoCategoryMode.values)
                                      KonataSegmentOption<MergeVideoCategoryMode>(
                                        value: m,
                                        label: m.label,
                                      ),
                                  ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                    ],
                  ),
                ),
                KonataSearchField(
                  controller: _searchController,
                  onChanged: (v) => setState(() => _query = v),
                  onClear: () {
                    _searchController.clear();
                    setState(() => _query = '');
                  },
                ),
                const SizedBox(height: 10),
                Expanded(
                  child: candidates.isEmpty
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 28),
                            child: Text(
                              '未找到匹配的目标作品',
                              style: KonataTheme.captionStyle(p),
                            ),
                          ),
                        )
                      : KonataDraggableScrollbar(
                          controller: _scrollController,
                          builder: (_, sc) => ListView.separated(
                            controller: sc,
                            padding: const EdgeInsets.only(right: 12),
                            itemCount: candidates.length,
                            separatorBuilder: (_, _) =>
                                const SizedBox(height: 8),
                            itemBuilder: (_, index) {
                              final work = candidates[index];
                              final selected = work.id == _selectedWorkId;
                              return _MergeTargetRow(
                                work: work,
                                selected: selected,
                                onTap: () =>
                                    setState(() => _selectedWorkId = work.id),
                              );
                            },
                          ),
                        ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _MergeTargetRow extends StatefulWidget {
  const _MergeTargetRow({
    required this.work,
    required this.selected,
    required this.onTap,
  });

  final Work work;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_MergeTargetRow> createState() => _MergeTargetRowState();
}

class _MergeTargetRowState extends State<_MergeTargetRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final work = widget.work;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: KonataTheme.motionMicro,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: widget.selected
                ? p.accentBadge.bg
                : (_hovered ? p.surfaceHover : p.softFill),
            borderRadius: KonataTheme.borderRadiusControl,
            border: Border.all(
              color: widget.selected
                  ? KonataTheme.activeControlBorder(p)
                  : (_hovered ? p.hoverBorder : p.hairline),
            ),
          ),
          child: Row(
            children: <Widget>[
              ClipRRect(
                borderRadius: KonataTheme.borderRadiusChipSm,
                child: SizedBox(
                  width: 44,
                  height: 62,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: p.surface,
                      borderRadius: KonataTheme.borderRadiusChipSm,
                      border: Border.all(color: p.posterBorder),
                    ),
                    child: ManagedImage(
                      path: work.posterPath,
                      ownerWorkId: work.id,
                      targetWidth: 120,
                      fit: BoxFit.cover,
                      errorWidget: Icon(
                        Icons.movie_outlined,
                        size: 18,
                        color: p.textMuted,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      work.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: KonataTheme.cardTitleStyle(
                        p,
                        fontSize: KonataTheme.fontSizeBody,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      [
                        if (work.year != null) '${work.year}',
                        if (work.tmdbId != null) 'TMDB #${work.tmdbId}',
                        if (work.bangumiId != null) 'BGM #${work.bangumiId}',
                        if (work.originalTitle != null &&
                            work.originalTitle!.trim().isNotEmpty &&
                            work.originalTitle != work.title)
                          work.originalTitle!.trim(),
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: KonataTheme.captionStyle(
                        p,
                        fontSize: KonataTheme.fontSizeCaptionSm,
                      ),
                    ),
                  ],
                ),
              ),
              if (widget.selected) ...<Widget>[
                const SizedBox(width: 8),
                Icon(Icons.check_circle_rounded, size: 18, color: p.accent),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
