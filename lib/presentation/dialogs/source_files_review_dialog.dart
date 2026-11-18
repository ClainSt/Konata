import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/providers/library_providers.dart';
import '../../application/providers/work_management_provider.dart';
import '../../domain/formatting/media_display_formatter.dart';
import '../../domain/models/media_source.dart';
import '../../domain/models/media_variant.dart';
import '../../domain/models/work.dart';
import '../../domain/parsing/bdrip_parser.dart';
import '../theme/konata_palette.dart';
import '../theme/konata_theme.dart';
import '../widgets/design_system/ellipsis_text_with_tooltip.dart';
import '../widgets/design_system/konata_draggable_scrollbar.dart';
import '../widgets/design_system/konata_glass_dialog.dart';
import '../widgets/design_system/konata_pill_button.dart';
import '../widgets/design_system/konata_soft_text_field.dart';
import '../widgets/design_system/konata_surface_card.dart';
import '../widgets/design_system/konata_toast.dart';
import 'manual_match_dialog.dart';
import 'work_merge_target_dialog.dart';

/// 待复核卡片「查看源文件」毛玻璃检视与单/多选弹窗。
///
/// 完整展示条目下全部源文件（不截断关键集数或篇章名），支持搜索过滤与单选/多选/全选，
/// 并衔接「将所选文件绑定为独立作品」双源混合拆作流程。
class SourceFilesReviewDialog extends ConsumerStatefulWidget {
  /// 创建源文件检视弹窗。
  const SourceFilesReviewDialog({
    super.key,
    required this.item,
    this.onBindSelected,
  });

  /// 待复核作品聚合项。
  final WorkLibraryItem item;

  /// 用户点击「将所选文件绑定为独立作品」时的回调。
  final Future<void> Function(List<MediaVariant> selectedVariants)?
  onBindSelected;

  @override
  ConsumerState<SourceFilesReviewDialog> createState() =>
      _SourceFilesReviewDialogState();
}

/// 打开待复核源文件检视与多选弹窗。
Future<List<MediaVariant>?> showSourceFilesReviewDialog(
  BuildContext context, {
  required WorkLibraryItem item,
  Future<void> Function(List<MediaVariant> selectedVariants)? onBindSelected,
}) {
  return showKonataGlassDialog<List<MediaVariant>>(
    context: context,
    builder: (_) =>
        SourceFilesReviewDialog(item: item, onBindSelected: onBindSelected),
  );
}

class _SourceFilesReviewDialogState
    extends ConsumerState<SourceFilesReviewDialog> {
  final TextEditingController _filterController = TextEditingController();
  final ScrollController _listCtrl = ScrollController();
  final Set<String> _selectedIds = <String>{};
  String _query = '';
  bool _submitting = false;

  @override
  void dispose() {
    _listCtrl.dispose();
    _filterController.dispose();
    super.dispose();
  }

  List<MediaVariant> _sortedVariants(List<MediaVariant> source) {
    final list = List<MediaVariant>.of(source)
      ..sort((a, b) {
        if (a.assetKind != b.assetKind) {
          if (a.assetKind == AssetKind.video) return -1;
          if (b.assetKind == AssetKind.video) return 1;
        }
        return a.relativePath.toLowerCase().compareTo(
          b.relativePath.toLowerCase(),
        );
      });
    return list;
  }

  String _commonDirectoryPrefix(List<MediaVariant> variants) {
    if (variants.isEmpty) return '';
    final dirs = variants
        .map((v) => _parentDir(v.relativePath))
        .where((d) => d.isNotEmpty)
        .toList(growable: false);
    if (dirs.isEmpty) return '';
    var prefixSegments = dirs.first.split('/');
    for (final dir in dirs.skip(1)) {
      final segs = dir.split('/');
      var matchLen = 0;
      while (matchLen < prefixSegments.length &&
          matchLen < segs.length &&
          prefixSegments[matchLen] == segs[matchLen]) {
        matchLen++;
      }
      prefixSegments = prefixSegments.sublist(0, matchLen);
    }
    return prefixSegments.join('/');
  }

  String _parentDir(String relativePath) {
    final norm = relativePath.replaceAll('\\', '/');
    final idx = norm.lastIndexOf('/');
    if (idx <= 0) return '';
    return norm.substring(0, idx);
  }

  String _subHierarchy(MediaVariant variant, String commonDir) {
    final norm = variant.relativePath.replaceAll('\\', '/');
    if (commonDir.isNotEmpty && norm.startsWith('$commonDir/')) {
      final rel = norm.substring(commonDir.length + 1);
      final idx = rel.lastIndexOf('/');
      return idx > 0 ? rel.substring(0, idx) : '';
    }
    return _parentDir(norm);
  }

  void _toggleVariant(MediaVariant variant) {
    if (variant.assetKind != AssetKind.video) return;
    setState(() {
      if (!_selectedIds.remove(variant.id)) {
        _selectedIds.add(variant.id);
      }
    });
  }

  void _toggleSelectAllVisible(List<MediaVariant> visibleVideos) {
    if (visibleVideos.isEmpty) return;
    final allSelected = visibleVideos.every((v) => _selectedIds.contains(v.id));
    setState(() {
      if (allSelected) {
        for (final v in visibleVideos) {
          _selectedIds.remove(v.id);
        }
      } else {
        for (final v in visibleVideos) {
          _selectedIds.add(v.id);
        }
      }
    });
  }

  Future<void> _submitSelection(List<MediaVariant> allVariants) async {
    final picked = allVariants
        .where((v) => _selectedIds.contains(v.id))
        .toList(growable: false);
    if (picked.isEmpty || _submitting) return;
    final callback = widget.onBindSelected;
    if (callback != null) {
      setState(() => _submitting = true);
      try {
        await callback(picked);
      } finally {
        if (mounted) {
          setState(() => _submitting = false);
        }
      }
      return;
    }

    final initialQuery = _deriveSplitInitialQuery(
      picked,
      widget.item.work.title,
    );
    final created = await showKonataGlassDialog<Work>(
      context: context,
      builder: (_) => ManualMatchDialog.splitFiles(
        workId: widget.item.work.id,
        splitVariants: picked,
        initialQuery: initialQuery,
      ),
    );
    if (created == null || !mounted) return;
    final pickedIds = picked.map((v) => v.id).toSet();
    final remainingVideos = allVariants
        .where(
          (v) => v.assetKind == AssetKind.video && !pickedIds.contains(v.id),
        )
        .length;
    setState(() => _selectedIds.removeAll(pickedIds));
    showKonataToast(
      context,
      '已将 ${picked.length} 个文件绑定为独立作品「${created.title}」',
    );
    if (remainingVideos == 0 && mounted) {
      Navigator.of(context).pop(picked);
    }
  }

  Future<void> _mergeIntoExistingWork(List<MediaVariant> allVariants) async {
    if (_submitting || allVariants.isEmpty) return;
    final picked = allVariants
        .where((v) => _selectedIds.contains(v.id))
        .toList(growable: false);
    final isFullMerge =
        picked.isEmpty || picked.length >= allVariants.length;
    final outcome = await showKonataGlassDialog<WorkMergeOutcome>(
      context: context,
      builder: (_) => WorkMergeTargetDialog(
        sourceWorkId: widget.item.work.id,
        sourceWorkTitle: widget.item.work.title,
        variantIds: isFullMerge
            ? const []
            : [for (final v in picked) v.id],
        initialMode: widget.item.episodeCount == 0
            ? MergeVideoCategoryMode.asExtra
            : MergeVideoCategoryMode.preserve,
      ),
    );
    if (outcome == null || !mounted) return;
    setState(() => _selectedIds.clear());
    showKonataToast(
      context,
      '已将 ${outcome.movedVariantCount} 个文件并入「${outcome.targetWork.title}」',
    );
    if (outcome.sourceWorkDeleted && mounted) {
      Navigator.of(context).pop();
    }
  }

  String _deriveSplitInitialQuery(List<MediaVariant> picked, String fallback) {
    if (picked.isEmpty) return fallback;
    final parsed = BdripParser.parseFileName(picked.first.fileName);
    final candidate = parsed.cleanTitle.trim();
    return candidate.isNotEmpty ? candidate : fallback;
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final bundle = ref
        .watch(workDetailBundleProvider(widget.item.work.id))
        .valueOrNull;
    final sources = ref.watch(mediaSourcesProvider).valueOrNull ?? const [];
    final sourcesById = <String, MediaSource>{
      for (final s in sources) s.id: s,
    };

    final allVariants = _sortedVariants(
      bundle?.variants ?? widget.item.variants,
    );
    final commonDir = _commonDirectoryPrefix(allVariants);
    final firstSource = allVariants.isNotEmpty
        ? sourcesById[allVariants.first.sourceId]
        : null;

    final q = _query.trim().toLowerCase();
    final filtered = q.isEmpty
        ? allVariants
        : allVariants
              .where(
                (v) =>
                    v.fileName.toLowerCase().contains(q) ||
                    v.relativePath.toLowerCase().contains(q),
              )
              .toList(growable: false);
    final visibleVideos = filtered
        .where((v) => v.assetKind == AssetKind.video)
        .toList(growable: false);
    final allVisibleSelected =
        visibleVideos.isNotEmpty &&
        visibleVideos.every((v) => _selectedIds.contains(v.id));
    final selectedCount = allVariants
        .where((v) => _selectedIds.contains(v.id))
        .length;

    return KonataGlassDialog(
      width: 780,
      maxHeight: 640,
      title: '查看源文件 · ${widget.item.work.title}',
      onClose: _submitting ? () {} : () => Navigator.of(context).pop(),
      actions: [
        KonataPillButton.ghost(
          label: '关闭',
          compact: true,
          onPressed: _submitting ? null : () => Navigator.of(context).pop(),
        ),
        KonataPillButton.secondary(
          label: selectedCount == 0 ? '并入已有作品' : '并入已有作品 ($selectedCount)',
          icon: Icons.merge_type_rounded,
          compact: true,
          onPressed: (_submitting || allVariants.isEmpty)
              ? null
              : () => _mergeIntoExistingWork(allVariants),
        ),
        KonataPillButton.primary(
          label: '将所选文件绑定为独立作品 ($selectedCount)',
          icon: Icons.call_split_rounded,
          compact: true,
          onPressed: (_submitting || selectedCount == 0)
              ? null
              : () => _submitSelection(allVariants),
        ),
      ],
      child: SizedBox(
        height: 468,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildHeaderSummary(p, firstSource, commonDir, allVariants.length),
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: KonataSoftTextField(
                    controller: _filterController,
                    height: 36,
                    dense: true,
                    prefixIcon: Icons.search_rounded,
                    borderRadius: BorderRadius.circular(999),
                    hintText: '过滤文件名或子目录路径...',
                    onChanged: (value) => setState(() => _query = value),
                  ),
                ),
                const SizedBox(width: 10),
                KonataPillButton.secondary(
                  height: 36,
                  borderColor: p.hairline,
                  label: allVisibleSelected ? '取消全选' : '全选视频',
                  compact: true,
                  onPressed: visibleVideos.isEmpty
                      ? null
                      : () => _toggleSelectAllVisible(visibleVideos),
                ),
                if (_selectedIds.isNotEmpty) ...[
                  const SizedBox(width: 6),
                  KonataPillButton.ghost(
                    height: 36,
                    label: '清空 (${_selectedIds.length})',
                    compact: true,
                    onPressed: () => setState(() => _selectedIds.clear()),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 10),
            Expanded(
              child: KonataSurfaceCard(
                padding: EdgeInsets.zero,
                child: filtered.isEmpty
                    ? Center(
                        child: Text(
                          allVariants.isEmpty
                              ? '当前条目下没有关联源文件'
                              : '未找到匹配 “$_query” 的源文件',
                          style: TextStyle(color: p.textSecondary, fontSize: 13),
                        ),
                      )
                    : KonataDraggableScrollbar(
                        controller: _listCtrl,
                        builder: (_, ctrl) => ListView.separated(
                          controller: ctrl,
                          padding: const EdgeInsets.fromLTRB(6, 4, 14, 4),
                          itemCount: filtered.length,
                          separatorBuilder: (_, _) =>
                              Divider(height: 1, color: p.hairline),
                          itemBuilder: (_, index) {
                            final variant = filtered[index];
                            final isVideo = variant.assetKind == AssetKind.video;
                            final isSelected = _selectedIds.contains(variant.id);
                            final subDir = _subHierarchy(variant, commonDir);
                            return _SourceFileRow(
                              variant: variant,
                              subHierarchy: subDir,
                              selected: isSelected,
                              selectable: isVideo,
                              onToggle: () => _toggleVariant(variant),
                            );
                          },
                        ),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeaderSummary(
    KonataPalette p,
    MediaSource? source,
    String commonDir,
    int totalCount,
  ) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: p.softFill,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: p.hairline),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (source != null) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: p.accent.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: p.accent.withValues(alpha: 0.35)),
              ),
              child: Text(
                source.label,
                style: TextStyle(
                  color: p.accent,
                  fontSize: 11.2,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: SelectableText(
              commonDir.isEmpty ? '媒体源根目录' : commonDir,
              style: TextStyle(
                color: p.textSecondary,
                fontSize: 11.8,
                fontFamily: 'Consolas',
              ),
            ),
          ),
          const SizedBox(width: 10),
          Text(
            '共 $totalCount 个文件',
            style: TextStyle(color: p.textMuted, fontSize: 11.5),
          ),
        ],
      ),
    );
  }
}

class _SourceFileRow extends StatelessWidget {
  const _SourceFileRow({
    required this.variant,
    required this.subHierarchy,
    required this.selected,
    required this.selectable,
    required this.onToggle,
  });

  final MediaVariant variant;
  final String subHierarchy;
  final bool selected;
  final bool selectable;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final (icon, kindLabel) = switch (variant.assetKind) {
      AssetKind.video => (Icons.movie_outlined, null),
      AssetKind.cdAlbum => (Icons.library_music_outlined, 'CD'),
      AssetKind.scanGallery => (Icons.photo_library_outlined, 'Scan'),
    };

    return InkWell(
      onTap: selectable ? onToggle : null,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        height: 46,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: selected ? p.accent.withValues(alpha: 0.14) : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            _SourceZeroPaddingCheckbox(
              checked: selected,
              enabled: selectable,
            ),
            const SizedBox(width: 10),
            Icon(
              icon,
              size: 17,
              color: selectable ? p.textSecondary : p.textMuted,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: LayoutBuilder(
                builder: (context, rowBox) {
                  final subTag = subHierarchy.isNotEmpty
                      ? Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: p.accentBadge.bg,
                            borderRadius: BorderRadius.circular(5),
                            border: Border.all(color: p.accentBadge.border),
                          ),
                          child: Text(
                            '$subHierarchy/',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: p.accentBadge.fg,
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              fontFamily: 'Consolas',
                              height: 1.15,
                            ),
                          ),
                        )
                      : null;
                  final nameText = EllipsisTextWithTooltip(
                    text: variant.fileName,
                    tooltipMessage: subHierarchy.isNotEmpty
                        ? '$subHierarchy/${variant.fileName}'
                        : variant.fileName,
                    maxLines: 1,
                    style: TextStyle(
                      color: selectable ? p.textPrimary : p.textSecondary,
                      fontSize: 12.8,
                      fontWeight: FontWeight.w500,
                      height: 1.25,
                    ),
                  );
                  final kindPill = kindLabel != null
                      ? Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: p.softFill,
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(color: p.hairline),
                          ),
                          child: Text(
                            kindLabel,
                            maxLines: 1,
                            softWrap: false,
                            style: TextStyle(color: p.textMuted, fontSize: 10.5),
                          ),
                        )
                      : null;
                  final sizeText = Text(
                    MediaDisplayFormatter.formatBytes(
                      variant.fileSize,
                      emptyFallback: '0 B',
                    ),
                    textAlign: TextAlign.right,
                    maxLines: 1,
                    softWrap: false,
                    style: KonataTheme.textStyle(
                      color: p.textMuted,
                      fontSize: 11.8,
                      weight: 500,
                      tabularFigures: true,
                    ),
                  );

                  if (rowBox.maxWidth >= 360) {
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        if (subTag != null) ...[
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 160),
                            child: subTag,
                          ),
                          const SizedBox(width: 7),
                        ],
                        Expanded(child: nameText),
                        const SizedBox(width: 10),
                        if (kindPill != null) ...[
                          kindPill,
                          const SizedBox(width: 8),
                        ],
                        SizedBox(width: 76, child: sizeText),
                      ],
                    );
                  }
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      nameText,
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          ?subTag,
                          ?kindPill,
                          sizeText,
                        ],
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SourceZeroPaddingCheckbox extends StatelessWidget {
  const _SourceZeroPaddingCheckbox({
    required this.checked,
    required this.enabled,
  });

  final bool checked;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      width: 18,
      height: 18,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: checked ? p.accent : Colors.transparent,
        borderRadius: BorderRadius.circular(5),
        border: Border.all(
          color: checked
              ? p.accent
              : (enabled ? p.textMuted : p.hairline),
          width: 1.5,
        ),
      ),
      child: checked
          ? const Icon(Icons.check_rounded, size: 13, color: Colors.white)
          : null,
    );
  }
}
