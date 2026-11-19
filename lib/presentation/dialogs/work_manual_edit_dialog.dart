import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/providers/library_providers.dart';
import '../../application/providers/work_management_provider.dart';
import '../../domain/models/episode.dart';
import '../../domain/models/media_variant.dart';
import '../../domain/models/work.dart';
import '../../domain/parsing/bdrip_parser.dart';
import '../theme/konata_adaptive_tokens.dart';
import '../theme/konata_palette.dart';
import '../widgets/design_system/adaptive_responsive_row.dart';
import '../widgets/design_system/konata_draggable_scrollbar.dart';
import '../widgets/design_system/konata_glass_dialog.dart';
import '../widgets/design_system/konata_pill_button.dart';
import '../widgets/design_system/konata_segmented_capsule.dart';
import '../widgets/design_system/konata_soft_text_field.dart';
import '../widgets/design_system/konata_toast.dart';
import 'episode_slot_picker_popover.dart';
import 'file_mapping_panel.dart';
import 'manual_match_dialog.dart';
import 'series_manage_dialog.dart';
import 'supplementary_scope_panel.dart';
import 'work_merge_target_dialog.dart';
import '../theme/konata_theme.dart';

enum _ManualEditSection { metadata, episodes, supplementary }

/// 作品基础信息与单集/特典归属手动画修正弹窗（严格毛玻璃表面）。
class WorkManualEditDialog extends ConsumerStatefulWidget {
  /// 创建手动编辑弹窗。
  const WorkManualEditDialog({super.key, required this.bundle});

  /// 当前作品详情聚合包。
  final WorkDetailBundle bundle;

  @override
  ConsumerState<WorkManualEditDialog> createState() =>
      _WorkManualEditDialogState();
}

class _WorkManualEditDialogState extends ConsumerState<WorkManualEditDialog> {
  final ScrollController _metaScrollCtrl = ScrollController();
  final FocusNode _titleFocusNode = FocusNode();
  final FocusNode _origFocusNode = FocusNode();
  final FocusNode _yearFocusNode = FocusNode();
  final FocusNode _overviewFocusNode = FocusNode();
  late final TextEditingController _titleCtrl;
  late final TextEditingController _origCtrl;
  late final TextEditingController _yearCtrl;
  late final TextEditingController _overviewCtrl;
  late final List<EditableFileMappingRow> _rows;
  late final List<SupplementaryScopeDraft> _scopeDrafts;
  final Set<String> _selectedForSplit = <String>{};
  _ManualEditSection _section = _ManualEditSection.metadata;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final work = widget.bundle.work;
    _titleCtrl = TextEditingController(text: work.title);
    _origCtrl = TextEditingController(text: work.originalTitle ?? '');
    _yearCtrl = TextEditingController(text: work.year?.toString() ?? '');
    _overviewCtrl = TextEditingController(text: work.overview ?? '');

    final epById = {for (final e in widget.bundle.episodes) e.id: e};
    final videos = widget.bundle.variants
        .where((v) => v.assetKind == AssetKind.video)
        .toList()
      ..sort((a, b) => a.relativePath.compareTo(b.relativePath));

    _rows = videos.map((v) {
      final ep = v.episodeId != null ? epById[v.episodeId!] : null;
      return EditableFileMappingRow(
        variant: v,
        category: ep?.category ?? EpisodeCategory.main,
        seasonNumber: ep?.seasonNumber ?? (work.matchedSeason ?? 1),
        episodeNumber: ep?.episodeNumber ?? 1,
        extraType: ep?.extraType ?? ExtraKind.sp,
      );
    }).toList();

    _scopeDrafts = [
      for (final item in widget.bundle.editableSupplementaryItems)
        SupplementaryScopeDraft(item: item),
    ];
  }

  @override
  void dispose() {
    _metaScrollCtrl.dispose();
    _titleFocusNode.dispose();
    _origFocusNode.dispose();
    _yearFocusNode.dispose();
    _overviewFocusNode.dispose();
    _titleCtrl.dispose();
    _origCtrl.dispose();
    _yearCtrl.dispose();
    _overviewCtrl.dispose();
    super.dispose();
  }

  bool get _isMetadataModified {
    final work = widget.bundle.work;
    return _titleCtrl.text.trim() != work.title.trim() ||
        _origCtrl.text.trim() != (work.originalTitle ?? '').trim() ||
        int.tryParse(_yearCtrl.text.trim()) != work.year ||
        _overviewCtrl.text.trim() != (work.overview ?? '').trim();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final actions = ref.read(workManagementProvider);
      final metaChanged = _isMetadataModified;
      if (metaChanged || widget.bundle.work.metadataLocked) {
        await actions.updateWorkManualMetadata(
          workId: widget.bundle.work.id,
          title: _titleCtrl.text,
          originalTitle: _origCtrl.text,
          year: int.tryParse(_yearCtrl.text.trim()),
          overview: _overviewCtrl.text,
          lockMetadata: metaChanged || widget.bundle.work.metadataLocked,
        );
      }
      final mappingEdits = [
        for (final row in _rows)
          if (row.isModified || row.variant.mappingLocked)
            EpisodeFileMappingEdit(
              variantId: row.variant.id,
              category: row.category,
              seasonNumber: row.seasonNumber,
              episodeNumber: row.episodeNumber,
              extraType: row.extraType,
              lockMapping: row.isModified || row.variant.mappingLocked,
            ),
      ];
      if (mappingEdits.isNotEmpty) {
        await actions.saveEpisodeMappings(
          workId: widget.bundle.work.id,
          mappings: mappingEdits,
        );
      }
      final scopeEdits = [
        for (final draft in _scopeDrafts)
          if (draft.isModified) draft.toEdit(),
      ];
      if (scopeEdits.isNotEmpty) {
        await actions.updateSupplementaryScopes(scopeEdits);
      }
      if (mounted) {
        showKonataToast(context, '已保存手动修改并持久化锁定已调整项');
        Navigator.of(context).pop<String?>(null);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        showKonataToast(context, '保存失败: $e');
      }
    }
  }

  Future<void> _resetMetadataToAuto() async {
    setState(() => _saving = true);
    try {
      final updated = await ref
          .read(workManagementProvider)
          .resetMetadataLockToAuto(widget.bundle.work.id);
      if (mounted) {
        final redirectId =
            (updated != null && updated.id != widget.bundle.work.id)
                ? updated.id
                : null;
        showKonataToast(
          context,
          redirectId != null
              ? '已自动并入已有作品「${updated!.title}」'
              : '已恢复基础元数据自动抓取默认',
        );
        Navigator.of(context).pop<String?>(redirectId);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        showKonataToast(context, '恢复默认失败: $e');
      }
    }
  }

  Future<void> _resetMappingsToAuto() async {
    setState(() => _saving = true);
    try {
      final updated = await ref
          .read(workManagementProvider)
          .resetFileMappingsToAuto(widget.bundle.work.id);
      if (mounted) {
        final redirectId =
            (updated != null && updated.id != widget.bundle.work.id)
                ? updated.id
                : null;
        showKonataToast(
          context,
          redirectId != null
              ? '已自动并入已有作品「${updated!.title}」'
              : '已解除文件映射锁定并重新自动对齐剧集',
        );
        Navigator.of(context).pop<String?>(redirectId);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        showKonataToast(context, '恢复默认失败: $e');
      }
    }
  }

  Future<void> _splitSelectedToIndependentWork() async {
    final picked = _rows
        .where((r) => _selectedForSplit.contains(r.variant.id))
        .map((r) => r.variant)
        .toList(growable: false);
    if (picked.isEmpty || _saving) return;

    final parsedTitle = BdripParser.parseFileName(
      picked.first.fileName,
    ).cleanTitle.trim();
    final created = await showKonataGlassDialog<Work>(
      context: context,
      builder: (_) => ManualMatchDialog.splitFiles(
        workId: widget.bundle.work.id,
        splitVariants: picked,
        initialQuery: parsedTitle.isNotEmpty
            ? parsedTitle
            : widget.bundle.work.title,
      ),
    );
    if (created == null || !mounted) return;
    final pickedIds = picked.map((v) => v.id).toSet();
    setState(() {
      _rows.removeWhere((r) => pickedIds.contains(r.variant.id));
      _selectedForSplit.removeAll(pickedIds);
    });
    showKonataToast(
      context,
      '已将 ${picked.length} 个文件拆分为独立作品「${created.title}」',
    );
    if (_rows.isEmpty && mounted) {
      final survived = await ref
          .read(libraryRepositoryProvider)
          .findWorkById(widget.bundle.work.id);
      if (mounted) {
        Navigator.of(context).pop<String?>(survived == null ? created.id : null);
      }
    }
  }

  Future<void> _moveSelectedToOtherWork() async {
    final pickedIds = _rows
        .where((r) => _selectedForSplit.contains(r.variant.id))
        .map((r) => r.variant.id)
        .toList(growable: false);
    if (pickedIds.isEmpty || _saving) return;

    final outcome = await showKonataGlassDialog<WorkMergeOutcome>(
      context: context,
      builder: (_) => WorkMergeTargetDialog(
        sourceWorkId: widget.bundle.work.id,
        sourceWorkTitle: widget.bundle.work.title,
        variantIds: pickedIds,
        initialMode: MergeVideoCategoryMode.asExtra,
      ),
    );
    if (outcome == null || !mounted) return;
    final idSet = pickedIds.toSet();
    setState(() {
      _rows.removeWhere((r) => idSet.contains(r.variant.id));
      _selectedForSplit.removeAll(idSet);
    });
    showKonataToast(
      context,
      '已将 ${pickedIds.length} 个文件移至「${outcome.targetWork.title}」',
    );
    if ((_rows.isEmpty || outcome.sourceWorkDeleted) && mounted) {
      Navigator.of(
        context,
      ).pop<String?>(outcome.sourceWorkDeleted ? outcome.targetWork.id : null);
    }
  }

  Future<void> _openSeriesManageFromDialog() async {
    final changed = await showKonataGlassDialog<bool>(
      context: context,
      builder: (_) => SeriesManageDialog(bundle: widget.bundle),
    );
    if (changed == true && mounted) {
      Navigator.of(context).pop<String?>(null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final hasMappingLock = _rows.any((r) => r.variant.mappingLocked) &&
        widget.bundle.work.tmdbId != null;
    final screenSize = MediaQuery.sizeOf(context);
    final inlineHeaderTabs =
        screenSize.height < KonataAdaptiveTokens.shortViewportHeight &&
        screenSize.width >= KonataAdaptiveTokens.tabletBreakpoint;

    Widget buildSectionTabs({required bool compact}) {
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: MediaQuery.withClampedTextScaling(
          maxScaleFactor: 1.15,
          child: KonataSegmentedCapsule<_ManualEditSection>(
            compact: compact,
            selected: _section,
            options: const [
              KonataSegmentOption(
                value: _ManualEditSection.metadata,
                label: '元数据',
              ),
              KonataSegmentOption(
                value: _ManualEditSection.episodes,
                label: '文件映射',
              ),
              KonataSegmentOption(
                value: _ManualEditSection.supplementary,
                label: '附属共享',
              ),
            ],
            onChanged: (v) => setState(() => _section = v),
          ),
        ),
      );
    }

    return KonataGlassDialog(
      width: 760,
      maxHeight: 640,
      title: '手动编辑作品信息与分集归属',
      headerTrailing: inlineHeaderTabs ? buildSectionTabs(compact: true) : null,
      onClose: _saving ? null : () => Navigator.of(context).pop<String?>(null),
      actions: [
        KonataPillButton.ghost(
          label: '取消',
          compact: true,
          onPressed: _saving ? null : () => Navigator.of(context).pop<String?>(null),
        ),
        KonataPillButton.primary(
          label: _saving ? '保存中...' : '保存并锁定',
          compact: true,
          onPressed: _saving ? null : _save,
        ),
      ],
      child: Builder(
        builder: (dialogCtx) {
          final landscapeCompact =
              KonataGlassDialog.isLandscapeCompactInputActive(dialogCtx);
          final shortViewport =
              MediaQuery.sizeOf(dialogCtx).height <
              KonataAdaptiveTokens.shortViewportHeight;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Offstage(
                offstage: landscapeCompact || inlineHeaderTabs,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    buildSectionTabs(
                      compact: MediaQuery.sizeOf(dialogCtx).width < 560,
                    ),
                    SizedBox(height: shortViewport ? 8 : 14),
                  ],
                ),
              ),
              Expanded(
                child: KonataSmoothSectionSwitcher(
                  switchKey: _section,
                  alignment: Alignment.topLeft,
                  child: switch (_section) {
                    _ManualEditSection.metadata => _buildMetadataForm(p),
                    _ManualEditSection.episodes => FileMappingPanel(
                      rows: _rows,
                      referenceEpisodes: widget.bundle.episodes,
                      defaultMainSeason: widget.bundle.work.matchedSeason ?? 1,
                      selectedVariantIds: _selectedForSplit,
                      saving: _saving,
                      hasAnyMappingLock: hasMappingLock,
                      onChanged: () => setState(() {}),
                      onResetMappings: _resetMappingsToAuto,
                      onSplitSelected: _splitSelectedToIndependentWork,
                      onMoveSelectedToWork: _moveSelectedToOtherWork,
                    ),
                    _ManualEditSection.supplementary => SupplementaryScopePanel(
                      drafts: _scopeDrafts,
                      seriesMembers: widget.bundle.seriesMembers,
                      saving: _saving,
                      onChanged: () => setState(() {}),
                      onOpenSeriesManage: _openSeriesManageFromDialog,
                    ),
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildMetadataForm(KonataPalette p) {
    final compactIme = KonataGlassDialog.isLandscapeCompactInputActive(context);
    return KonataDraggableScrollbar(
      controller: _metaScrollCtrl,
      builder: (_, ctrl) => ListView(
        controller: ctrl,
        padding: const EdgeInsets.only(right: 14),
        children: [
          KonataSoftTextField(
            controller: _titleCtrl,
            focusNode: _titleFocusNode,
            label: '中文 / 主标题',
          ),
          const SizedBox(height: 12),
          AdaptiveResponsiveRow(
            minLeadingWidth: 160,
            estimatedTrailingWidth: 110,
            expandTrailingWhenStacked: true,
            leading: KonataSoftTextField(
              controller: _origCtrl,
              focusNode: _origFocusNode,
              label: '日文 / 原始标题',
            ),
            trailing: KonataSoftTextField(
              controller: _yearCtrl,
              focusNode: _yearFocusNode,
              label: '年份',
              keyboardType: TextInputType.number,
            ),
          ),
          const SizedBox(height: 12),
          KonataSoftTextField(
            controller: _overviewCtrl,
            focusNode: _overviewFocusNode,
            label: '剧情简介',
            maxLines: compactIme ? 1 : 5,
          ),
          const SizedBox(height: 10),
          AdaptiveResponsiveRow(
            minLeadingWidth: 180,
            estimatedTrailingWidth: 150,
            leading: Text(
              widget.bundle.work.metadataLocked
                  ? '当前元数据已人工锁定，点击「重新抓取 TMDB 数据」或重扫不会覆盖这里的标题、年份与简介。'
                  : '仅当你修改了这里的标题、年份或简介并保存时，才会开启元数据锁定。',
              style: TextStyle(color: p.textMuted, fontSize: KonataTheme.fontSizeCaption),
            ),
            trailing: (widget.bundle.work.metadataLocked &&
                    widget.bundle.work.tmdbId != null)
                ? KonataPillButton.ghost(
                    label: '恢复自动抓取默认',
                    compact: true,
                    onPressed: _saving ? null : _resetMetadataToAuto,
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}
