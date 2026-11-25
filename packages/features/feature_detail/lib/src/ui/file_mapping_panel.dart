import 'dart:math' as math;

import 'package:engine_scraping/engine_scraping.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:konata_design_system/konata_design_system.dart';

import '../data/detail_edit_models.dart';
import 'episode_slot_picker_popover.dart';

enum _MappingCategoryFilter { all, main, extra }

/// 多物理文件剧集/特典批量映射、顺序顺延编号及单行精准修正面板。
class FileMappingPanel extends StatefulWidget {
  /// 创建文件映射修正面板。
  const FileMappingPanel({
    super.key,
    required this.rows,
    required this.selectedVariantIds,
    required this.referenceEpisodes,
    required this.defaultMainSeason,
    required this.saving,
    required this.hasLockedMappings,
    required this.onChanged,
    required this.onResetAutoMappings,
    this.onSplitSelectedToNewWork,
    this.onMoveSelectedToExistingWork,
  });

  /// 当前作品下所有物理视频行编辑模型。
  final List<EditableFileMappingRow> rows;

  /// 多选框当前勾选的物理版本主键集合。
  final Set<String> selectedVariantIds;

  /// 参考正片与特别篇剧集目录。
  final List<Episode> referenceEpisodes;

  /// 默认正片季号。
  final int defaultMainSeason;

  /// 是否处于异步保存中。
  final bool saving;

  /// 是否已有手动锁定的文件映射。
  final bool hasLockedMappings;

  /// 任一勾选、编号或分类发生变更时通知宿主刷新状态。
  final VoidCallback onChanged;

  /// 解除全部手动映射锁定并恢复自动重映射回调。
  final VoidCallback onResetAutoMappings;

  /// 将勾选文件拆分为独立作品回调。
  final VoidCallback? onSplitSelectedToNewWork;

  /// 将勾选文件迁移并入库内其他作品回调。
  final VoidCallback? onMoveSelectedToExistingWork;

  @override
  State<FileMappingPanel> createState() => _FileMappingPanelState();
}

class _FileMappingPanelState extends State<FileMappingPanel> {
  final TextEditingController _searchCtrl = TextEditingController();
  final TextEditingController _seqSeasonCtrl = TextEditingController();
  final TextEditingController _seqStartEpCtrl = TextEditingController(
    text: '1',
  );
  final ScrollController _listScrollCtrl = ScrollController();

  String _query = '';
  _MappingCategoryFilter _filter = _MappingCategoryFilter.all;
  int? _lastClickedVisibleIndex;

  @override
  void initState() {
    super.initState();
    _seqSeasonCtrl.text =
        (widget.defaultMainSeason <= 0 ? 1 : widget.defaultMainSeason)
            .toString();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _seqSeasonCtrl.dispose();
    _seqStartEpCtrl.dispose();
    _listScrollCtrl.dispose();
    super.dispose();
  }

  bool get _isShiftPressed =>
      HardwareKeyboard.instance.logicalKeysPressed.contains(
        LogicalKeyboardKey.shiftLeft,
      ) ||
      HardwareKeyboard.instance.logicalKeysPressed.contains(
        LogicalKeyboardKey.shiftRight,
      );

  String _parentFolder(String relativePath) {
    final norm = relativePath.replaceAll('\\', '/');
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

  void _handleCheckboxTap(List<EditableFileMappingRow> visibleRows, int index) {
    final row = visibleRows[index];
    final nextSelected = !widget.selectedVariantIds.contains(row.variant.id);
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
    for (final r in visibleRows) {
      if (!widget.selectedVariantIds.contains(r.variant.id)) continue;
      r.category = EpisodeCategory.main;
      r.seasonNumber = season <= 0 ? 1 : season;
      r.episodeNumber = cursor++;
      r.isTmdbSpecial = false;
    }
    setState(() {});
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final visibleRows = _filteredRows();
    final selectedCount = widget.selectedVariantIds.length;
    final folderSet = <String>{
      for (final r in widget.rows) _parentFolder(r.variant.relativePath),
    };
    final allVisibleSelected =
        visibleRows.isNotEmpty &&
        visibleRows.every(
          (r) => widget.selectedVariantIds.contains(r.variant.id),
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final search = KonataSoftTextField(
              controller: _searchCtrl,
              dense: true,
              prefixIcon: Icons.search_rounded,
              hintText: '筛选文件名或子目录路径...',
              onChanged: (v) => setState(() => _query = v),
            );
            final filter = KonataSegmentedCapsule<_MappingCategoryFilter>(
              compact: true,
              selected: _filter,
              onChanged: (next) => setState(() => _filter = next),
              options: const [
                KonataSegmentOption(
                  value: _MappingCategoryFilter.all,
                  label: '全部',
                ),
                KonataSegmentOption(
                  value: _MappingCategoryFilter.main,
                  label: '正片',
                ),
                KonataSegmentOption(
                  value: _MappingCategoryFilter.extra,
                  label: '特典',
                ),
              ],
            );
            if (constraints.maxWidth < 420) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [search, const SizedBox(height: 6), filter],
              );
            }
            return Row(
              children: [
                Expanded(child: search),
                const SizedBox(width: 8),
                filter,
              ],
            );
          },
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            KonataPillButton.ghost(
              label: allVisibleSelected ? '取消全选' : '全选可见',
              compact: true,
              onPressed: widget.saving || visibleRows.isEmpty
                  ? null
                  : () {
                      setState(() {
                        if (allVisibleSelected) {
                          for (final r in visibleRows) {
                            widget.selectedVariantIds.remove(r.variant.id);
                          }
                        } else {
                          for (final r in visibleRows) {
                            widget.selectedVariantIds.add(r.variant.id);
                          }
                        }
                      });
                      widget.onChanged();
                    },
            ),
            if (widget.hasLockedMappings)
              KonataPillButton.ghost(
                label: '恢复自动映射',
                icon: Icons.restart_alt_rounded,
                compact: true,
                onPressed: widget.saving ? null : widget.onResetAutoMappings,
              ),
            if (folderSet.length > 1)
              SizedBox(
                width: 220,
                child: KonataDropdown<String>(
                  key: const ValueKey('mapping_folder_select'),
                  hintText: '按目录批选',
                  dense: true,
                  enabled: !widget.saving,
                  menuWidth: 480,
                  options: [
                    for (final dir in folderSet)
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
        if (selectedCount > 0) ...[
          const SizedBox(height: 8),
          KonataSurfaceCard(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Wrap(
              spacing: 8,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  '已选 $selectedCount 项：',
                  style: TextStyle(
                    color: p.textSecondary,
                    fontSize: KonataTheme.fontSizeCaption,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                KonataPillButton.secondary(
                  label: '设为正片',
                  compact: true,
                  onPressed: widget.saving
                      ? null
                      : () => _applyCategoryToSelected(EpisodeCategory.main),
                ),
                KonataPillButton.secondary(
                  label: '设为特典',
                  compact: true,
                  onPressed: widget.saving
                      ? null
                      : () => _applyCategoryToSelected(EpisodeCategory.extra),
                ),
                KonataPillButton.ghost(
                  label: '集数 -1',
                  compact: true,
                  onPressed: widget.saving
                      ? null
                      : () => _offsetSelectedEpisodes(-1),
                ),
                KonataPillButton.ghost(
                  label: '集数 +1',
                  compact: true,
                  onPressed: widget.saving
                      ? null
                      : () => _offsetSelectedEpisodes(1),
                ),
                SizedBox(
                  width: 58,
                  child: KonataSoftTextField(
                    controller: _seqSeasonCtrl,
                    dense: true,
                    hintText: '季',
                  ),
                ),
                SizedBox(
                  width: 66,
                  child: KonataSoftTextField(
                    controller: _seqStartEpCtrl,
                    dense: true,
                    hintText: '起始集',
                  ),
                ),
                KonataPillButton.secondary(
                  label: '顺延编号',
                  compact: true,
                  onPressed: widget.saving
                      ? null
                      : () => _applySequentialNumbering(visibleRows),
                ),
                if (widget.onSplitSelectedToNewWork != null)
                  KonataPillButton.secondary(
                    label: '拆为独立作品',
                    compact: true,
                    onPressed: widget.saving
                        ? null
                        : widget.onSplitSelectedToNewWork,
                  ),
                if (widget.onMoveSelectedToExistingWork != null)
                  KonataPillButton.secondary(
                    label: '移至已有作品',
                    compact: true,
                    onPressed: widget.saving
                        ? null
                        : widget.onMoveSelectedToExistingWork,
                  ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 10),
        Expanded(
          child: visibleRows.isEmpty
              ? Center(
                  child: Text(
                    '未找到匹配的物理文件记录',
                    style: KonataTheme.bodyLabelStyle(
                      p,
                      color: p.textSecondary,
                    ),
                  ),
                )
              : KonataDraggableScrollbar(
                  controller: _listScrollCtrl,
                  builder: (_, ctrl) => ListView.separated(
                    controller: ctrl,
                    itemCount: visibleRows.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 6),
                    itemBuilder: (_, index) {
                      final row = visibleRows[index];
                      final checked = widget.selectedVariantIds.contains(
                        row.variant.id,
                      );
                      return _FileMappingRowTile(
                        row: row,
                        checked: checked,
                        enabled: !widget.saving,
                        referenceEpisodes: widget.referenceEpisodes,
                        defaultMainSeason: widget.defaultMainSeason,
                        onToggleCheck: () =>
                            _handleCheckboxTap(visibleRows, index),
                        onPickedSlot:
                            (
                              category,
                              seasonNumber,
                              episodeNumber,
                              extraType,
                              isTmdbSpecial,
                            ) {
                              setState(() {
                                row.category = category;
                                row.seasonNumber = seasonNumber;
                                row.episodeNumber = episodeNumber;
                                if (extraType != null) {
                                  row.extraType = extraType;
                                }
                                row.isTmdbSpecial = isTmdbSpecial;
                              });
                              widget.onChanged();
                            },
                      );
                    },
                  ),
                ),
        ),
      ],
    );
  }
}

class _FileMappingRowTile extends StatelessWidget {
  const _FileMappingRowTile({
    required this.row,
    required this.checked,
    required this.enabled,
    required this.referenceEpisodes,
    required this.defaultMainSeason,
    required this.onToggleCheck,
    required this.onPickedSlot,
  });

  final EditableFileMappingRow row;
  final bool checked;
  final bool enabled;
  final List<Episode> referenceEpisodes;
  final int defaultMainSeason;
  final VoidCallback onToggleCheck;
  final void Function(
    EpisodeCategory category,
    int seasonNumber,
    int episodeNumber,
    ExtraKind? extraType,
    bool isTmdbSpecial,
  )
  onPickedSlot;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return KonataSurfaceCard(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      borderColor: checked ? p.accent : null,
      child: Row(
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: enabled ? onToggleCheck : null,
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Container(
                width: 18,
                height: 18,
                decoration: BoxDecoration(
                  color: checked ? p.accent : p.softFill,
                  borderRadius: KonataTheme.borderRadiusXs,
                  border: Border.all(
                    color: checked ? p.accent : p.hairline,
                    width: 1.2,
                  ),
                ),
                child: checked
                    ? const Icon(
                        Icons.check_rounded,
                        size: 13,
                        color: KonataTheme.pureWhite,
                      )
                    : null,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 3,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  row.variant.fileName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: KonataTheme.bodyLabelStyle(
                    p,
                    fontSize: KonataTheme.fontSizeCaption,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  row.variant.relativePath,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: KonataTheme.captionStyle(p).copyWith(
                    color: p.textMuted,
                    fontSize: KonataTheme.fontSizeCaptionXs,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 170,
            child: EpisodeSlotPickerButton(
              row: row,
              referenceEpisodes: referenceEpisodes,
              defaultMainSeason: defaultMainSeason,
              enabled: enabled,
              onPicked: onPickedSlot,
            ),
          ),
        ],
      ),
    );
  }
}
