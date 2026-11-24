import 'package:engine_scraping/engine_scraping.dart';
import 'package:flutter/widgets.dart';
import 'package:konata_design_system/konata_design_system.dart';

import '../data/library_models.dart';
import '../data/library_search_matcher.dart';
import 'managed_image.dart';

/// 弹出选择合并目标作品弹窗；用户选中并确认目标作品时返回对应 `Work`，取消返回 `null`。
Future<Work?> showWorkMergeTargetDialog(
  BuildContext context, {
  required Work sourceWork,
  required List<WorkLibraryItem> candidates,
}) {
  return showKonataGlassDialog<Work>(
    context: context,
    builder: (_) => _WorkMergeTargetDialog(
      sourceWork: sourceWork,
      candidates: candidates,
    ),
  );
}

class _WorkMergeTargetDialog extends StatefulWidget {
  const _WorkMergeTargetDialog({
    required this.sourceWork,
    required this.candidates,
  });

  final Work sourceWork;
  final List<WorkLibraryItem> candidates;

  @override
  State<_WorkMergeTargetDialog> createState() => _WorkMergeTargetDialogState();
}

class _WorkMergeTargetDialogState extends State<_WorkMergeTargetDialog> {
  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';
  String? _selectedId;

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final available = widget.candidates
        .where((item) => item.work.id != widget.sourceWork.id)
        .toList(growable: false);
    final filtered = LibrarySearchMatcher.filterAndRank<WorkLibraryItem>(
      items: available,
      workOf: (item) => item.work,
      releaseGroupsOf: (item) => item.releaseGroups,
      rawQuery: _query,
    );
    Work? selectedTarget;
    for (final item in available) {
      if (item.work.id == _selectedId) {
        selectedTarget = item.work;
        break;
      }
    }

    final screen = MediaQuery.sizeOf(context);
    final bodyHeight = (screen.height * 0.62).clamp(240.0, 500.0);

    return KonataGlassDialog(
      title: '合并「${widget.sourceWork.title}」到目标作品',
      width: (screen.width - 28).clamp(300.0, 580.0),
      actions: [
        KonataPillButton.ghost(
          label: '取消',
          onPressed: () => Navigator.of(context).pop(),
        ),
        KonataPillButton.primary(
          label: '确认合并',
          icon: Icons.merge_rounded,
          onPressed: selectedTarget == null
              ? null
              : () => Navigator.of(context).pop(selectedTarget),
        ),
      ],
      child: SizedBox(
        height: bodyHeight,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '选中目标作品后，会将当前条目下全部物理视频文件迁移并归属锁定到目标作品中；绝不删改任何物理文件。',
              style: TextStyle(
                fontSize: 12.5,
                color: p.textSecondary,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 10),
            KonataSoftTextField(
              controller: _searchCtrl,
              hintText: '搜索目标作品标题、年份或压制组…',
              prefixIcon: Icons.search_rounded,
              dense: true,
              suffix: _query.isEmpty
                  ? null
                  : KonataCapsuleIconButton(
                      icon: Icons.close_rounded,
                      tooltip: '清空搜索词',
                      color: p.textMuted,
                      size: 14,
                      padding: const EdgeInsets.all(4),
                      onTap: () {
                        _searchCtrl.clear();
                        setState(() => _query = '');
                      },
                    ),
              onChanged: (String v) => setState(() => _query = v),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: filtered.isEmpty
                  ? Center(
                      child: Text(
                        '没有找到可合并的目标作品',
                        style: TextStyle(fontSize: 13, color: p.textMuted),
                      ),
                    )
                  : KonataDraggableScrollbar(
                      builder: (context, scrollCtrl) => ListView.separated(
                        controller: scrollCtrl,
                        padding: const EdgeInsets.only(right: 6),
                        itemCount: filtered.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 6),
                        itemBuilder: (context, index) {
                          final item = filtered[index];
                          final target = item.work;
                          final isSelected = target.id == _selectedId;
                          return InkWell(
                            borderRadius: BorderRadius.circular(12),
                            onTap: () => setState(() => _selectedId = target.id),
                            child: Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: isSelected
                                    ? p.accent.withValues(alpha: 0.14)
                                    : p.elevatedSurface.withValues(alpha: 0.42),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: isSelected ? p.accent : p.hairline,
                                ),
                              ),
                              child: Row(
                                children: [
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(8),
                                    child: SizedBox(
                                      width: 40,
                                      height: 60,
                                      child: ManagedImage(
                                        path:
                                            target.posterPath ??
                                            target.bangumiPosterPath,
                                        targetWidth: 256,
                                        ownerWorkId: target.id,
                                        subfolder: PhotoSubfolder.posters,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          target.title,
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
                                          [
                                            if (target.year != null)
                                              '${target.year}',
                                            '${item.variantCount} 个文件',
                                            if (item.primarySourceLabel != null)
                                              item.primarySourceLabel!,
                                          ].join(' · '),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 11.5,
                                            color: p.textMuted,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  if (isSelected)
                                    Icon(
                                      Icons.check_circle_rounded,
                                      size: 20,
                                      color: p.accent,
                                    ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
