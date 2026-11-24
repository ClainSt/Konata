import 'package:engine_scraping/engine_scraping.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:konata_design_system/konata_design_system.dart';

import '../data/library_models.dart';
import '../providers.dart';
import 'manual_match_dialog.dart';
import 'work_merge_target_dialog.dart';

/// 弹出物理源文件核对与多选拆包弹窗（支持将选中视频并入已有作品或绑定为独立作品）。
Future<void> showSourceFilesReviewDialog(
  BuildContext context, {
  required Work work,
}) {
  return showKonataGlassDialog<void>(
    context: context,
    builder: (_) => _SourceFilesReviewDialog(work: work),
  );
}

class _SourceFilesReviewDialog extends ConsumerStatefulWidget {
  const _SourceFilesReviewDialog({required this.work});

  final Work work;

  @override
  ConsumerState<_SourceFilesReviewDialog> createState() =>
      _SourceFilesReviewDialogState();
}

class _SourceFilesReviewDialogState
    extends ConsumerState<_SourceFilesReviewDialog> {
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _filterController = TextEditingController();
  final Set<String> _selectedIds = <String>{};

  bool _loading = true;
  bool _submitting = false;
  String _query = '';
  List<MediaVariant> _allVariants = const <MediaVariant>[];
  Map<String, MediaSource> _sourcesById = const <String, MediaSource>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _filterController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final mgmt = ref.read(workManagementControllerProvider);
      final variants = await mgmt.getVariantsByWork(widget.work.id);
      final sourcesById = await mgmt.loadSourcesById();
      if (!mounted) return;
      setState(() {
        _allVariants = variants;
        _sourcesById = sourcesById;
        _selectedIds.removeWhere(
          (id) => variants.every(
            (v) => v.id != id || v.assetKind != AssetKind.video,
          ),
        );
        _loading = false;
      });
    } catch (err) {
      if (!mounted) return;
      setState(() => _loading = false);
      showKonataToast(context, '读取源文件清单失败：$err', isError: true);
    }
  }

  List<MediaVariant> get _videoVariants => _allVariants
      .where((v) => v.assetKind == AssetKind.video)
      .toList(growable: false);

  int get _audioCount =>
      _allVariants.where((v) => v.assetKind == AssetKind.cdAlbum).length;

  int get _scanCount =>
      _allVariants.where((v) => v.assetKind == AssetKind.scanGallery).length;

  List<MediaVariant> get _filteredAllVariants {
    final clean = _query.trim().toLowerCase();
    if (clean.isEmpty) return _allVariants;
    return _allVariants
        .where(
          (v) =>
              v.fileName.toLowerCase().contains(clean) ||
              v.relativePath.toLowerCase().contains(clean),
        )
        .toList(growable: false);
  }

  List<MediaVariant> get _filteredSelectableVideos => _filteredAllVariants
      .where((v) => v.assetKind == AssetKind.video)
      .toList(growable: false);

  String _commonFolderSummary() {
    return MediaDisplayFormatter.summarizeWorkFolderLabel(
      _allVariants,
      sourcesById: _sourcesById,
    );
  }

  Future<void> _mergeSelectedIntoExisting() async {
    final selectedVideos = _videoVariants
        .where((v) => _selectedIds.contains(v.id))
        .toList(growable: false);
    if (selectedVideos.isEmpty || _submitting) return;

    final selection = await showWorkMergeSelectionDialog(
      context,
      sourceWork: widget.work,
      overrideFileCount: selectedVideos.length,
      dialogTitle: '将所选文件并入已有作品',
    );
    if (!mounted || selection == null) return;

    setState(() => _submitting = true);
    final mgmt = ref.read(workManagementControllerProvider);
    final library = ref.read(libraryControllerProvider);
    try {
      final outcome = await mgmt.mergeWorkIntoTarget(
        sourceWorkId: widget.work.id,
        targetWorkId: selection.targetWork.id,
        categoryMode: selection.categoryMode,
        onlyVariantIds: selectedVideos.map((v) => v.id).toList(growable: false),
      );
      await library.reload();
      if (!mounted) return;
      showKonataToast(
        context,
        '已将 ${outcome.movedVariantCount} 个文件并入「${outcome.targetWork.title}」',
      );
      if (outcome.sourceDeleted) {
        Navigator.of(context).pop();
      } else {
        _selectedIds.clear();
        await _load();
      }
    } catch (err) {
      if (!mounted) return;
      showKonataToast(context, '合并所选文件失败：$err', isError: true);
    } finally {
      if (mounted) {
        setState(() => _submitting = false);
      }
    }
  }

  Future<void> _splitSelectedToNewWork() async {
    final selectedVideos = _videoVariants
        .where((v) => _selectedIds.contains(v.id))
        .toList(growable: false);
    if (selectedVideos.isEmpty || _submitting) return;

    final bound = await showManualMatchDialog(
      context,
      work: widget.work,
      splitFiles: selectedVideos,
    );
    if (!mounted || !bound) return;

    await ref.read(libraryControllerProvider).reload();
    if (!mounted) return;
    _selectedIds.clear();
    await _load();
    if (!mounted) return;
    if (_videoVariants.isEmpty) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final filteredAll = _filteredAllVariants;
    final selectableVideos = _filteredSelectableVideos;
    final allFilteredSelected =
        selectableVideos.isNotEmpty &&
        selectableVideos.every((v) => _selectedIds.contains(v.id));
    final selectedCount = _selectedIds.length;

    final primarySourceId = _allVariants.isNotEmpty
        ? _allVariants.first.sourceId
        : null;
    final sourceLabel = primarySourceId != null
        ? _sourcesById[primarySourceId]?.label
        : null;

    return KonataGlassDialog(
      width: 720,
      maxHeight: 640,
      title: '源文件清单：${widget.work.title}',
      onClose: () => Navigator.of(context).pop(),
      actions: <Widget>[
        KonataPillButton.ghost(
          label: '关闭',
          onPressed: _submitting ? null : () => Navigator.of(context).pop(),
        ),
        if (selectedCount > 0) ...<Widget>[
          KonataPillButton.secondary(
            label: '并入已有作品 ($selectedCount)',
            icon: Icons.merge_type_rounded,
            onPressed: _submitting ? null : _mergeSelectedIntoExisting,
          ),
          KonataPillButton.primary(
            label: '将所选绑定为独立作品 ($selectedCount)',
            icon: Icons.call_split_rounded,
            onPressed: _submitting ? null : _splitSelectedToNewWork,
          ),
        ],
      ],
      child: LayoutBuilder(
        builder: (dialogCtx, outerConstraints) {
          final targetH = outerConstraints.maxHeight.isFinite
              ? outerConstraints.maxHeight.clamp(0.0, 468.0)
              : 468.0;
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
                              Icons.folder_outlined,
                              size: 15,
                              color: p.accent,
                            ),
                            const SizedBox(width: 8),
                            if (sourceLabel != null &&
                                sourceLabel.isNotEmpty) ...<Widget>[
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 7,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: p.accentBadge.bg,
                                  borderRadius: KonataTheme.borderRadiusChip,
                                  border: Border.all(
                                    color: p.accentBadge.border,
                                  ),
                                ),
                                child: Text(
                                  sourceLabel,
                                  style: KonataTheme.textStyle(
                                    color: p.accentBadge.fg,
                                    fontSize: KonataTheme.fontSizeCaptionXs,
                                    weight: KonataTheme.weightActive,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                            ],
                            Expanded(
                              child: Text(
                                _commonFolderSummary(),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: KonataTheme.captionStyle(
                                  p,
                                  fontSize: KonataTheme.fontSizeCaptionSm,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              '共 ${_videoVariants.length} 视频'
                              '${_audioCount > 0 ? " · $_audioCount 音轨" : ""}'
                              '${_scanCount > 0 ? " · $_scanCount 画廊" : ""}',
                              style: KonataTheme.textStyle(
                                color: p.textSecondary,
                                fontSize: KonataTheme.fontSizeCaptionSm,
                                tabularFigures: true,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                  ),
                ),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: KonataSearchField(
                        controller: _filterController,
                        onChanged: (v) => setState(() => _query = v),
                        onClear: () {
                          _filterController.clear();
                          setState(() => _query = '');
                        },
                      ),
                    ),
                    const SizedBox(width: 10),
                    KonataPillButton.secondary(
                      label: allFilteredSelected ? '取消全选' : '全选当前',
                      compact: true,
                      onPressed: selectableVideos.isEmpty
                          ? null
                          : () {
                              setState(() {
                                if (allFilteredSelected) {
                                  for (final v in selectableVideos) {
                                    _selectedIds.remove(v.id);
                                  }
                                } else {
                                  for (final v in selectableVideos) {
                                    _selectedIds.add(v.id);
                                  }
                                }
                              });
                            },
                    ),
                    if (selectedCount > 0) ...<Widget>[
                      const SizedBox(width: 6),
                      KonataPillButton.ghost(
                        label: '清空',
                        compact: true,
                        onPressed: () => setState(() => _selectedIds.clear()),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 10),
                Expanded(
                  child: _loading
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 32),
                            child: SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: p.accent,
                              ),
                            ),
                          ),
                        )
                      : filteredAll.isEmpty
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 28),
                            child: Text(
                              _allVariants.isEmpty
                                  ? '当前作品下暂无关联文件'
                                  : '未筛选到匹配文件',
                              style: KonataTheme.captionStyle(p),
                            ),
                          ),
                        )
                      : KonataDraggableScrollbar(
                          controller: _scrollController,
                          builder: (_, sc) => ListView.separated(
                            controller: sc,
                            padding: const EdgeInsets.only(right: 12),
                            itemCount: filteredAll.length,
                            separatorBuilder: (_, _) =>
                                const SizedBox(height: 6),
                            itemBuilder: (_, index) {
                              final variant = filteredAll[index];
                              final selectable =
                                  variant.assetKind == AssetKind.video;
                              final selected =
                                  selectable &&
                                  _selectedIds.contains(variant.id);
                              return _SourceFileRow(
                                variant: variant,
                                selectable: selectable,
                                selected: selected,
                                onToggle: selectable
                                    ? () {
                                        setState(() {
                                          if (selected) {
                                            _selectedIds.remove(variant.id);
                                          } else {
                                            _selectedIds.add(variant.id);
                                          }
                                        });
                                      }
                                    : null,
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

class _SourceFileRow extends StatefulWidget {
  const _SourceFileRow({
    required this.variant,
    required this.selectable,
    required this.selected,
    required this.onToggle,
  });

  final MediaVariant variant;
  final bool selectable;
  final bool selected;
  final VoidCallback? onToggle;

  @override
  State<_SourceFileRow> createState() => _SourceFileRowState();
}

class _SourceFileRowState extends State<_SourceFileRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final variant = widget.variant;
    final selectable = widget.selectable;
    final subDir = MediaDisplayFormatter.extractParentDirectory(
      variant.relativePath,
    );
    final sizeText = MediaDisplayFormatter.formatBytes(variant.fileSize);
    final kindLabel = switch (variant.assetKind) {
      AssetKind.video => null,
      AssetKind.cdAlbum => 'CD 音轨',
      AssetKind.scanGallery => '画廊扫图',
    };
    final kindIcon = switch (variant.assetKind) {
      AssetKind.video => Icons.movie_outlined,
      AssetKind.cdAlbum => Icons.album_outlined,
      AssetKind.scanGallery => Icons.photo_library_outlined,
    };

    return MouseRegion(
      cursor: selectable
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      onEnter: selectable ? (_) => setState(() => _hovered = true) : null,
      onExit: selectable ? (_) => setState(() => _hovered = false) : null,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onToggle,
        child: AnimatedContainer(
          duration: KonataTheme.motionMicro,
          constraints: const BoxConstraints(minHeight: 46),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
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
              if (selectable)
                SizedBox(
                  width: 20,
                  height: 20,
                  child: Checkbox(
                    value: widget.selected,
                    activeColor: p.accent,
                    onChanged: (_) => widget.onToggle?.call(),
                  ),
                )
              else
                SizedBox(
                  width: 20,
                  height: 20,
                  child: Center(
                    child: Icon(kindIcon, size: 15, color: p.textMuted),
                  ),
                ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      MediaDisplayFormatter.formatWrappableFileName(
                        variant.fileName,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: KonataTheme.textStyle(
                        color: selectable ? p.textPrimary : p.textSecondary,
                        fontSize: KonataTheme.fontSizeBodySm,
                        weight: widget.selected
                            ? KonataTheme.weightActive
                            : KonataTheme.weightRegularLabel,
                      ),
                    ),
                    if (subDir.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 2),
                      Text(
                        subDir,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: KonataTheme.captionStyle(
                          p,
                          fontSize: KonataTheme.fontSizeCaptionXs,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (kindLabel != null) ...<Widget>[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: KonataTheme.specNeutralBadgeBg(p),
                    borderRadius: KonataTheme.borderRadiusChip,
                    border: Border.all(
                      color: KonataTheme.specNeutralBadgeBorder(p),
                    ),
                  ),
                  child: Text(
                    kindLabel,
                    style: KonataTheme.textStyle(
                      color: p.textMuted,
                      fontSize: KonataTheme.fontSizeMicro,
                      weight: KonataTheme.weightActive,
                    ),
                  ),
                ),
              ] else if (variant.releaseGroup != null &&
                  variant.releaseGroup!.trim().isNotEmpty) ...<Widget>[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: p.accentBadge.bg,
                    borderRadius: KonataTheme.borderRadiusChip,
                    border: Border.all(color: p.accentBadge.border),
                  ),
                  child: Text(
                    variant.releaseGroup!.trim(),
                    style: KonataTheme.textStyle(
                      color: p.accentBadge.fg,
                      fontSize: KonataTheme.fontSizeMicro,
                      weight: KonataTheme.weightActive,
                    ),
                  ),
                ),
              ],
              if (sizeText.isNotEmpty) ...<Widget>[
                const SizedBox(width: 10),
                Text(
                  sizeText,
                  style: KonataTheme.textStyle(
                    color: p.textSecondary,
                    fontSize: KonataTheme.fontSizeCaptionSm,
                    tabularFigures: true,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
