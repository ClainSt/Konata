import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import '../../domain/models/episode.dart';
import '../theme/konata_adaptive_tokens.dart';
import '../theme/konata_palette.dart';
import '../widgets/design_system/ellipsis_text_with_tooltip.dart';
import '../widgets/design_system/konata_draggable_scrollbar.dart';
import '../widgets/design_system/konata_dropdown.dart';
import '../widgets/design_system/konata_glass_dialog.dart';
import '../widgets/design_system/konata_pill_button.dart';
import '../widgets/design_system/konata_segmented_capsule.dart';
import '../widgets/design_system/konata_soft_text_field.dart';
import 'episode_slot_picker_popover.dart';
import '../theme/konata_theme.dart';

enum _MappingCategoryFilter { all, main, extra }

/// 「手动编辑 -> 文件映射修正」可视化选集与 Shift 区间批量处理面板。
class FileMappingPanel extends StatefulWidget {
  /// 创建文件映射修正面板。
  const FileMappingPanel({
    super.key,
    required this.rows,
    required this.referenceEpisodes,
    required this.defaultMainSeason,
    required this.selectedVariantIds,
    required this.saving,
    required this.hasAnyMappingLock,
    required this.onChanged,
    required this.onResetMappings,
    required this.onSplitSelected,
    required this.onMoveSelectedToWork,
  });

  /// 全部可编辑视频文件行。
  final List<EditableFileMappingRow> rows;

  /// 当前作品关联的正片与特典逻辑剧集目录（供单行可视化点击选集）。
  final List<Episode> referenceEpisodes;

  /// 默认正片季号。
  final int defaultMainSeason;

  /// 已选中的物理文件变体 ID 集合（由父级持有，供提交/拆分/迁移复用）。
  final Set<String> selectedVariantIds;

  /// 是否正在保存/执行迁移。
  final bool saving;

  /// 当前是否存在已人工锁定的文件映射。
  final bool hasAnyMappingLock;

  /// 行数据或勾选集合变更回调。
  final VoidCallback onChanged;

  /// 恢复自动映射回调。
  final VoidCallback onResetMappings;

  /// 将勾选文件拆分为独立作品回调。
  final VoidCallback onSplitSelected;

  /// 将勾选文件移至其他库内作品回调。
  final VoidCallback onMoveSelectedToWork;

  @override
  State<FileMappingPanel> createState() => _FileMappingPanelState();
}

class _FileMappingPanelState extends State<FileMappingPanel> {
  final ScrollController _scrollCtrl = ScrollController();
  final FocusNode _searchFocusNode = FocusNode();
  final FocusNode _seqSeasonFocusNode = FocusNode();
  final FocusNode _seqStartEpFocusNode = FocusNode();
  final TextEditingController _searchCtrl = TextEditingController();
  late final TextEditingController _seqSeasonCtrl;
  final TextEditingController _seqStartEpCtrl = TextEditingController(
    text: '1',
  );
  _MappingCategoryFilter _filter = _MappingCategoryFilter.all;
  String _query = '';
  int? _lastClickedVisibleIndex;
  bool _showSequentialBar = false;

  @override
  void initState() {
    super.initState();
    final safeSeason = widget.defaultMainSeason <= 0
        ? 1
        : widget.defaultMainSeason;
    _seqSeasonCtrl = TextEditingController(text: safeSeason.toString());
  }

  @override
  void dispose() {
    _scrollCtrl.dispose();
    _searchFocusNode.dispose();
    _seqSeasonFocusNode.dispose();
    _seqStartEpFocusNode.dispose();
    _searchCtrl.dispose();
    _seqSeasonCtrl.dispose();
    _seqStartEpCtrl.dispose();
    super.dispose();
  }

  bool get _isShiftPressed {
    return HardwareKeyboard.instance.isShiftPressed ||
        HardwareKeyboard.instance.logicalKeysPressed.any(
          (k) =>
              k == LogicalKeyboardKey.shiftLeft ||
              k == LogicalKeyboardKey.shiftRight,
        );
  }

  String _parentFolder(String relPath) {
    final norm = relPath.replaceAll('\\', '/');
    final idx = norm.lastIndexOf('/');
    if (idx <= 0) return '(根目录)';
    return norm.substring(0, idx);
  }

  List<EditableFileMappingRow> _filteredRows() {
    final q = _query.trim().toLowerCase();
    return widget.rows
        .where((r) {
          if (_filter == _MappingCategoryFilter.main &&
              r.category != EpisodeCategory.main) {
            return false;
          }
          if (_filter == _MappingCategoryFilter.extra &&
              r.category != EpisodeCategory.extra) {
            return false;
          }
          if (q.isEmpty) return true;
          return r.variant.relativePath.toLowerCase().contains(q) ||
              r.variant.fileName.toLowerCase().contains(q);
        })
        .toList(growable: false);
  }

  void _handleCheckboxTap(
    List<EditableFileMappingRow> visibleRows,
    int index,
    bool? targetValue,
  ) {
    final row = visibleRows[index];
    final nextSelected = targetValue ?? !widget.selectedVariantIds.contains(row.variant.id);
    if (_isShiftPressed &&
        _lastClickedVisibleIndex != null &&
        _lastClickedVisibleIndex! >= 0 &&
        _lastClickedVisibleIndex! < visibleRows.length) {
      final start = math.min(_lastClickedVisibleIndex!, index);
      final end = math.max(_lastClickedVisibleIndex!, index);
      for (var i = start; i <= end; i++) {
        final id = visibleRows[i].variant.id;
        if (nextSelected) {
          widget.selectedVariantIds.add(id);
        } else {
          widget.selectedVariantIds.remove(id);
        }
      }
    } else {
      if (nextSelected) {
        widget.selectedVariantIds.add(row.variant.id);
      } else {
        widget.selectedVariantIds.remove(row.variant.id);
      }
    }
    _lastClickedVisibleIndex = index;
    setState(() {});
    widget.onChanged();
  }

  void _selectSubfolder(String folderPath) {
    for (final r in widget.rows) {
      if (_parentFolder(r.variant.relativePath) == folderPath) {
        widget.selectedVariantIds.add(r.variant.id);
      }
    }
    setState(() {});
    widget.onChanged();
  }

  void _offsetSelectedEpisodes(int delta) {
    for (final r in widget.rows) {
      if (!widget.selectedVariantIds.contains(r.variant.id)) continue;
      final next = r.episodeNumber + delta;
      if (next >= 1) {
        r.episodeNumber = next;
      }
    }
    setState(() {});
    widget.onChanged();
  }

  void _applyCategoryToSelected(EpisodeCategory cat) {
    final fallbackSeason = widget.defaultMainSeason <= 0
        ? 1
        : widget.defaultMainSeason;
    for (final r in widget.rows) {
      if (!widget.selectedVariantIds.contains(r.variant.id)) continue;
      r.category = cat;
      if (cat == EpisodeCategory.main && r.seasonNumber <= 0) {
        r.seasonNumber = fallbackSeason;
      } else if (cat == EpisodeCategory.extra) {
        r.seasonNumber = 0;
      }
    }
    setState(() {});
    widget.onChanged();
  }

  void _applySequentialNumbering(List<EditableFileMappingRow> visibleRows) {
    final season =
        int.tryParse(_seqSeasonCtrl.text.trim()) ?? widget.defaultMainSeason;
    final startEp = int.tryParse(_seqStartEpCtrl.text.trim()) ?? 1;
    final safeStart = startEp < 1 ? 1 : startEp;
    var cursor = safeStart;
    // 按照当前展示顺序为勾选条目分配连续集号
    for (final r in visibleRows) {
      if (!widget.selectedVariantIds.contains(r.variant.id)) continue;
      if (r.category == EpisodeCategory.main) {
        r.seasonNumber = season <= 0 ? 1 : season;
      }
      r.episodeNumber = cursor;
      cursor++;
    }
    setState(() => _showSequentialBar = false);
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    if (widget.rows.isEmpty) {
      return Center(
        child: Text(
          '当前作品下暂无视频物理文件',
          style: TextStyle(color: p.textSecondary),
        ),
      );
    }

    final visibleRows = _filteredRows();
    final mainCount = widget.rows
        .where((r) => r.category == EpisodeCategory.main)
        .length;
    final extraCount = widget.rows
        .where((r) => r.category == EpisodeCategory.extra)
        .length;
    final selectedCount = widget.rows
        .where((r) => widget.selectedVariantIds.contains(r.variant.id))
        .length;

    final folderSet = <String>{
      for (final r in widget.rows) _parentFolder(r.variant.relativePath),
    };
    final folderList = folderSet.toList()..sort();
    final landscapeCompact = KonataGlassDialog.isLandscapeCompactInputActive(
      context,
    );
    final shortViewport =
        MediaQuery.sizeOf(context).height <
        KonataAdaptiveTokens.shortViewportHeight;

    final categoryCapsule = SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: MediaQuery.withClampedTextScaling(
        maxScaleFactor: 1.15,
        child: KonataSegmentedCapsule<_MappingCategoryFilter>(
          compact: true,
          selected: _filter,
          options: [
            KonataSegmentOption(
              value: _MappingCategoryFilter.all,
              label: '全部 (${widget.rows.length})',
            ),
            KonataSegmentOption(
              value: _MappingCategoryFilter.main,
              label: '正片 ($mainCount)',
            ),
            KonataSegmentOption(
              value: _MappingCategoryFilter.extra,
              label: '特典 ($extraCount)',
            ),
          ],
          onChanged: (v) => setState(() {
            _filter = v;
            _lastClickedVisibleIndex = null;
          }),
        ),
      ),
    );

    return LayoutBuilder(
      builder: (context, panelConstraints) {
        final inlineFilterInSearchRow =
            !landscapeCompact &&
            shortViewport &&
            panelConstraints.maxWidth >= 560;
        final controlHeight = KonataAdaptiveTokens.isAndroid
            ? KonataAdaptiveTokens.touchTarget
            : 32.0;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Offstage(
              offstage: landscapeCompact || inlineFilterInSearchRow,
              child: Padding(
                padding: EdgeInsets.only(bottom: shortViewport ? 6 : 8),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    categoryCapsule,
                    if (widget.hasAnyMappingLock)
                      KonataPillButton.ghost(
                        label: '恢复自动重排',
                        compact: true,
                        onPressed: widget.saving ? null : widget.onResetMappings,
                      ),
                  ],
                ),
              ),
            ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                if (inlineFilterInSearchRow) ...[
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: panelConstraints.maxWidth * 0.44,
                    ),
                    child: categoryCapsule,
                  ),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  key: const ValueKey('file_mapping_search_slot'),
                  child: KonataSoftTextField(
                    key: const ValueKey('file_mapping_search_field'),
                    controller: _searchCtrl,
                    focusNode: _searchFocusNode,
                    dense: true,
                    height: controlHeight,
                    hintText: '搜索文件名...',
                    prefixIcon: Icons.search_rounded,
                    onChanged: (v) => setState(() {
                      _query = v;
                      _lastClickedVisibleIndex = null;
                    }),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  key: const ValueKey('file_mapping_folder_slot'),
                  child: KonataDropdown<String>(
                    key: const ValueKey('file_mapping_folder_dropdown'),
                    dense: true,
                    hintText: '按目录全选',
                    value: null,
                    enabled: !widget.saving && folderList.isNotEmpty,
                    options: [
                      for (final dir in folderList)
                        KonataDropdownOption(
                          value: dir,
                          label: dir.split('/').last,
                          subtitle: dir,
                        ),
                    ],
                    onChanged: _selectSubfolder,
                  ),
                ),
              ],
            ),
            SizedBox(height: shortViewport ? 6 : 8),
            if (selectedCount > 0) ...[
              _buildBatchToolbar(p, selectedCount, visibleRows),
              const SizedBox(height: 8),
            ] else
              Offstage(
                offstage:
                    landscapeCompact ||
                    shortViewport ||
                    KonataAdaptiveTokens.isAndroid,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    '提示：右侧下拉可直接指定 TMDB 正片/特别篇集数，特典默认按原识别结果保留；按住 Shift 点击复选框可区间多选批量处理。',
                    style: TextStyle(color: p.textMuted, fontSize: KonataTheme.fontSizeCaptionSm),
                  ),
                ),
              ),
        Expanded(
          child: visibleRows.isEmpty
              ? Center(
                  child: Text(
                    '当前筛选条件下暂无视频文件',
                    style: TextStyle(color: p.textSecondary, fontSize: KonataTheme.fontSizeBodySm),
                  ),
                )
              : KonataDraggableScrollbar(
                  controller: _scrollCtrl,
                  builder: (_, ctrl) => ListView.separated(
                    controller: ctrl,
                    padding: const EdgeInsets.only(right: 16),
                    itemCount: visibleRows.length,
                    separatorBuilder: (_, _) =>
                        Divider(height: 12, color: p.hairline),
                    itemBuilder: (_, index) {
                      final row = visibleRows[index];
                      final isSelected = widget.selectedVariantIds.contains(
                        row.variant.id,
                      );
                      final slotPicker = EpisodeSlotPickerButton(
                        row: row,
                        referenceEpisodes: widget.referenceEpisodes,
                        defaultMainSeason: widget.defaultMainSeason,
                        enabled: !widget.saving,
                        onPicked: (cat, season, epNum, extraType, isSpecial) {
                          setState(() {
                            row.category = cat;
                            row.seasonNumber = season;
                            row.episodeNumber = epNum;
                            row.isTmdbSpecial = isSpecial;
                            if (extraType != null) {
                              row.extraType = extraType;
                            }
                          });
                          widget.onChanged();
                        },
                      );

                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          SizedBox(
                            width: 24,
                            height: 24,
                            child: Checkbox(
                              value: isSelected,
                              onChanged: widget.saving
                                  ? null
                                  : (checked) => _handleCheckboxTap(
                                      visibleRows,
                                      index,
                                      checked,
                                    ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: EllipsisTextWithTooltip(
                              text: row.variant.fileName,
                              tooltipMessage: row.variant.relativePath,
                              maxLines: 1,
                              style: TextStyle(
                                color: p.textPrimary,
                                fontSize: KonataTheme.fontSizeBodyXs,
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          slotPicker,
                        ],
                      );
                    },
                  ),
                ),
        ),
      ],
    );
      },
    );
  }

  Widget _buildBatchToolbar(
    KonataPalette p,
    int selectedCount,
    List<EditableFileMappingRow> visibleRows,
  ) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: p.accent.withValues(alpha: 0.12),
        borderRadius: KonataTheme.borderRadiusControl,
        border: Border.all(color: p.accent.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 6,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                '已选 $selectedCount 项',
                style: TextStyle(
                  color: p.accent,
                  fontSize: KonataTheme.fontSizeCaption,
                  fontWeight: FontWeight.w700,
                ),
              ),
              KonataPillButton.ghost(
                label: '清空',
                compact: true,
                onPressed: widget.saving
                    ? null
                    : () {
                        setState(() => widget.selectedVariantIds.clear());
                        widget.onChanged();
                      },
              ),
              KonataPillButton.secondary(
                label: '连续编号',
                icon: Icons.format_list_numbered_rounded,
                compact: true,
                onPressed: widget.saving
                    ? null
                    : () => setState(
                        () => _showSequentialBar = !_showSequentialBar,
                      ),
              ),
              KonataPillButton.ghost(
                label: '集号 -1',
                compact: true,
                onPressed: widget.saving
                    ? null
                    : () => _offsetSelectedEpisodes(-1),
              ),
              KonataPillButton.ghost(
                label: '集号 +1',
                compact: true,
                onPressed: widget.saving
                    ? null
                    : () => _offsetSelectedEpisodes(1),
              ),
              KonataPillButton.ghost(
                label: '设为正片',
                compact: true,
                onPressed: widget.saving
                    ? null
                    : () => _applyCategoryToSelected(EpisodeCategory.main),
              ),
              KonataPillButton.ghost(
                label: '设为特典',
                compact: true,
                onPressed: widget.saving
                    ? null
                    : () => _applyCategoryToSelected(EpisodeCategory.extra),
              ),
              KonataPillButton.secondary(
                label: '拆分独立作品',
                icon: Icons.call_split_rounded,
                compact: true,
                onPressed: widget.saving ? null : widget.onSplitSelected,
              ),
              KonataPillButton.primary(
                label: '移至其他库内作品',
                icon: Icons.merge_type_rounded,
                compact: true,
                onPressed: widget.saving ? null : widget.onMoveSelectedToWork,
              ),
            ],
          ),
          if (_showSequentialBar) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  '批量重排季/起始集：',
                  style: TextStyle(color: p.textSecondary, fontSize: KonataTheme.fontSizeCaption),
                ),
                SizedBox(
                  width: 78,
                  child: KonataSoftTextField(
                    controller: _seqSeasonCtrl,
                    focusNode: _seqSeasonFocusNode,
                    label: '季号',
                    dense: true,
                    keyboardType: TextInputType.number,
                  ),
                ),
                SizedBox(
                  width: 78,
                  child: KonataSoftTextField(
                    controller: _seqStartEpCtrl,
                    focusNode: _seqStartEpFocusNode,
                    label: '起始集',
                    dense: true,
                    keyboardType: TextInputType.number,
                  ),
                ),
                KonataPillButton.primary(
                  label: '应用连续编号',
                  compact: true,
                  onPressed: () => _applySequentialNumbering(visibleRows),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
