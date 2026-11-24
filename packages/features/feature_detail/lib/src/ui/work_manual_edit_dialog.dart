import 'dart:async';

import 'package:engine_scraping/engine_scraping.dart';
import 'package:flutter/widgets.dart';
import 'package:konata_contracts/konata_contracts.dart' show WorkId;
import 'package:konata_design_system/konata_design_system.dart';

import '../data/detail_edit_models.dart';
import '../state/detail_supplementary_view_data.dart';
import '../state/work_detail_controller.dart';
import 'file_mapping_panel.dart';
import 'manual_match_dialog.dart';
import 'series_manage_dialog.dart';
import 'supplementary_scope_panel.dart';
import 'work_merge_target_dialog.dart';

/// 手动编辑作品信息弹窗初始聚焦分区。
enum WorkManualEditSection {
  /// 基本元数据（名称、原名、年份、简介）。
  metadata,

  /// 物理视频文件剧集/特典重映射及拆分迁移。
  mappings,

  /// 特典 / CD / 扫图系列可见范围设置。
  supplementary,
}

/// 作品综合手动编辑、文件映射、附属作用域调整与拆合工作台弹窗。
class WorkManualEditDialog extends StatefulWidget {
  /// 创建综合手动编辑弹窗。
  const WorkManualEditDialog({
    super.key,
    required this.controller,
    required this.bundle,
    required this.imageLoader,
    this.initialSection = WorkManualEditSection.metadata,
  });

  /// 详情页状态控制器。
  final WorkDetailController controller;

  /// 当前作品详情聚合包。
  final WorkDetailBundle bundle;

  /// 受管图片加载器。
  final ManagedImageLoader imageLoader;

  /// 初始展示分区。
  final WorkManualEditSection initialSection;

  @override
  State<WorkManualEditDialog> createState() => _WorkManualEditDialogState();
}

class _WorkManualEditDialogState extends State<WorkManualEditDialog> {
  final TextEditingController _titleCtrl = TextEditingController();
  final TextEditingController _originalTitleCtrl = TextEditingController();
  final TextEditingController _yearCtrl = TextEditingController();
  final TextEditingController _overviewCtrl = TextEditingController();
  final ScrollController _metaScrollCtrl = ScrollController();

  late WorkManualEditSection _section;
  late List<EditableFileMappingRow> _mappingRows;
  late List<SupplementaryScopeDraft> _suppDrafts;
  final Set<String> _selectedVariantIds = <String>{};
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _section = widget.initialSection;
    final work = widget.bundle.work;
    _titleCtrl.text = work.title;
    _originalTitleCtrl.text = work.originalTitle ?? '';
    _yearCtrl.text = work.year?.toString() ?? '';
    _overviewCtrl.text = work.overview ?? '';

    final epById = <String, Episode>{
      for (final ep in widget.bundle.episodes) ep.id: ep,
    };
    _mappingRows = [
      for (final variant in widget.bundle.variants)
        if (variant.assetKind == AssetKind.video)
          () {
            final ep = variant.episodeId != null
                ? epById[variant.episodeId]
                : null;
            final category = ep?.category ?? EpisodeCategory.main;
            final seasonNumber = ep?.seasonNumber ??
                (category == EpisodeCategory.extra ? 0 : (work.matchedSeason ?? 1));
            final episodeNumber = ep?.episodeNumber ?? 1;
            final extraType = ep?.extraType ?? ExtraKind.sp;
            return EditableFileMappingRow(
              variant: variant,
              category: category,
              seasonNumber: seasonNumber,
              episodeNumber: episodeNumber,
              extraType: extraType,
              recognizedExtraLabel: category == EpisodeCategory.extra
                  ? (ep?.title ?? '')
                  : '',
              isTmdbSpecial:
                  category == EpisodeCategory.extra &&
                  seasonNumber == 0 &&
                  extraType == ExtraKind.sp,
            );
          }(),
    ]..sort(
        (a, b) => a.variant.relativePath.toLowerCase().compareTo(
          b.variant.relativePath.toLowerCase(),
        ),
      );

    _suppDrafts = [
      for (final item in widget.bundle.editableSupplementaryItems)
        SupplementaryScopeDraft(item: item),
    ];
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _originalTitleCtrl.dispose();
    _yearCtrl.dispose();
    _overviewCtrl.dispose();
    _metaScrollCtrl.dispose();
    super.dispose();
  }

  Future<void> _saveAll() async {
    if (_saving) return;
    final title = _titleCtrl.text.trim();
    if (title.isEmpty) {
      showKonataToast(context, '作品主标题不能为空', isError: true);
      return;
    }
    final rawYear = _yearCtrl.text.trim();
    final parsedYear = rawYear.isEmpty ? null : int.tryParse(rawYear);
    if (rawYear.isNotEmpty && parsedYear == null) {
      showKonataToast(context, '年份格式须为整数数字', isError: true);
      return;
    }

    setState(() => _saving = true);
    try {
      final work = widget.bundle.work;
      final metaChanged =
          title != work.title ||
          _originalTitleCtrl.text.trim() != (work.originalTitle ?? '').trim() ||
          parsedYear != work.year ||
          _overviewCtrl.text.trim() != (work.overview ?? '').trim();

      if (metaChanged) {
        await widget.controller.updateWorkManualMetadata(
          title: title,
          originalTitle: _originalTitleCtrl.text.trim().isEmpty
              ? null
              : _originalTitleCtrl.text.trim(),
          year: parsedYear,
          overview: _overviewCtrl.text.trim().isEmpty
              ? null
              : _overviewCtrl.text.trim(),
        );
      }

      final mappingEdits = <EpisodeFileMappingEdit>[
        for (final row in _mappingRows)
          if (row.isModified)
            EpisodeFileMappingEdit(
              variantId: row.variant.id,
              category: row.category,
              seasonNumber: row.seasonNumber,
              episodeNumber: row.episodeNumber,
              extraType: row.extraType,
            ),
      ];
      if (mappingEdits.isNotEmpty) {
        await widget.controller.saveEpisodeMappings(mappingEdits);
      }

      final scopeEdits = <SupplementaryScopeEdit>[
        for (final draft in _suppDrafts)
          if (draft.isModified)
            SupplementaryScopeEdit(
              variantId: draft.item.variant.id,
              scope: draft.scope,
              targetWorkId: draft.ownerWorkId,
            ),
      ];
      if (scopeEdits.isNotEmpty) {
        await widget.controller.updateSupplementaryScopes(scopeEdits);
      }

      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } catch (error) {
      if (mounted) {
        setState(() => _saving = false);
        showKonataToast(context, '保存编辑内容失败：$error', isError: true);
      }
    }
  }

  Future<void> _resetMetadataLock() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await widget.controller.resetMetadataLockToAuto();
      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } catch (error) {
      if (mounted) {
        setState(() => _saving = false);
        showKonataToast(context, '恢复自动抓取元数据失败：$error', isError: true);
      }
    }
  }

  Future<void> _resetMappingsToAuto() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await widget.controller.resetFileMappingsToAuto();
      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } catch (error) {
      if (mounted) {
        setState(() => _saving = false);
        showKonataToast(context, '解除文件映射锁定失败：$error', isError: true);
      }
    }
  }

  Future<void> _openSplitToNewWork() async {
    if (_selectedVariantIds.isEmpty || _saving) return;
    final selectedIds = _selectedVariantIds.toList(growable: false);
    final split = await showKonataGlassDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => ManualMatchDialog(
        controller: widget.controller,
        bundle: widget.bundle,
        imageLoader: widget.imageLoader,
        splitVariantIds: selectedIds,
      ),
    );
    if (split == true && mounted) {
      Navigator.of(context).pop(true);
    }
  }

  Future<void> _openMoveToExistingWork() async {
    if (_selectedVariantIds.isEmpty || _saving) return;
    final selectedIds = _selectedVariantIds.toList(growable: false);
    final outcome = await showKonataGlassDialog<WorkMergeOutcome>(
      context: context,
      barrierDismissible: false,
      builder: (_) => WorkMergeTargetDialog(
        controller: widget.controller,
        sourceWorkId: widget.bundle.work.id,
        sourceWorkTitle: widget.bundle.work.title,
        imageLoader: widget.imageLoader,
        variantIds: selectedIds,
      ),
    );
    if (outcome != null && mounted) {
      Navigator.of(context).pop(true);
      if (outcome.sourceWorkDeleted) {
        await widget.controller.switchSeriesMember(
          WorkId.trusted(outcome.targetWork.id),
        );
      }
    }
  }

  Future<void> _openSeriesManage() async {
    await showKonataGlassDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => SeriesManageDialog(
        controller: widget.controller,
        anchorWork: widget.bundle.work,
        initialSeries: widget.bundle.seriesGroup,
        initialMembers: widget.bundle.seriesMembers,
        imageLoader: widget.imageLoader,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final work = widget.bundle.work;
    final hasLockedMappings = widget.bundle.variants.any((v) => v.mappingLocked);

    return KonataGlassDialog(
      width: 760,
      height: 620,
      title: '编辑信息与文件映射 · ${work.title}',
      onClose: _saving ? null : () => Navigator.of(context).pop(false),
      actions: [
        if (work.metadataLocked &&
            (work.tmdbId != null || work.bangumiId != null))
          KonataPillButton.ghost(
            label: '恢复元数据自动抓取',
            compact: true,
            onPressed: _saving ? null : _resetMetadataLock,
          ),
        KonataPillButton.ghost(
          label: '取消',
          compact: true,
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
        ),
        KonataPillButton.primary(
          label: _saving ? '保存中...' : '保存并锁定变更',
          icon: Icons.check_rounded,
          compact: true,
          onPressed: _saving ? null : _saveAll,
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          KonataSegmentedCapsule<WorkManualEditSection>(
            expand: true,
            compact: true,
            selected: _section,
            onChanged: (next) => setState(() => _section = next),
            options: [
              const KonataSegmentOption(
                value: WorkManualEditSection.metadata,
                label: '基础元数据',
              ),
              KonataSegmentOption(
                value: WorkManualEditSection.mappings,
                label: '分集映射 (${_mappingRows.length})',
              ),
              KonataSegmentOption(
                value: WorkManualEditSection.supplementary,
                label: '特典/CD 作用域 (${_suppDrafts.length})',
              ),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: switch (_section) {
              WorkManualEditSection.metadata => _buildMetadataSection(p),
              WorkManualEditSection.mappings => FileMappingPanel(
                rows: _mappingRows,
                selectedVariantIds: _selectedVariantIds,
                referenceEpisodes: widget.bundle.episodes,
                defaultMainSeason: work.matchedSeason ?? 1,
                saving: _saving,
                hasLockedMappings: hasLockedMappings,
                onChanged: () => setState(() {}),
                onResetAutoMappings: _resetMappingsToAuto,
                onSplitSelectedToNewWork: _openSplitToNewWork,
                onMoveSelectedToExistingWork: _openMoveToExistingWork,
              ),
              WorkManualEditSection.supplementary => SupplementaryScopePanel(
                drafts: _suppDrafts,
                seriesMembers: widget.bundle.seriesMembers,
                saving: _saving,
                onChanged: () => setState(() {}),
                onOpenSeriesManage: _openSeriesManage,
              ),
            },
          ),
        ],
      ),
    );
  }

  Widget _buildMetadataSection(KonataPalette p) {
    return KonataDraggableScrollbar(
      controller: _metaScrollCtrl,
      builder: (_, ctrl) => SingleChildScrollView(
        controller: ctrl,
        padding: const EdgeInsets.only(right: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            KonataSoftTextField(
              controller: _titleCtrl,
              label: '主展示标题',
              hintText: '输入作品中文或常用显示名称',
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  flex: 3,
                  child: KonataSoftTextField(
                    controller: _originalTitleCtrl,
                    label: '原始标题',
                    hintText: '日文/英文原名（可选）',
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: KonataSoftTextField(
                    controller: _yearCtrl,
                    label: '首播年份',
                    hintText: '例如 2024',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            KonataSoftTextField(
              controller: _overviewCtrl,
              label: '作品剧情简介',
              hintText: '输入或修正剧情简介...',
              maxLines: 6,
            ),
            const SizedBox(height: 10),
            Text(
              '保存基础元数据修改将自动锁定对应字段，防止后续全库重刮覆盖。',
              style: KonataTheme.captionStyle(p).copyWith(color: p.textMuted),
            ),
          ],
        ),
      ),
    );
  }
}
