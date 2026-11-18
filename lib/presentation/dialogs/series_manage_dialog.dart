import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/providers/library_providers.dart';
import '../../application/providers/work_management_provider.dart';
import '../../application/providers/work_split_and_series_actions.dart';
import '../../domain/models/series_group.dart';
import '../../domain/models/work.dart';
import '../theme/konata_palette.dart';
import '../widgets/design_system/konata_draggable_scrollbar.dart';
import '../widgets/design_system/konata_dropdown.dart';
import '../widgets/design_system/konata_glass_dialog.dart';
import '../widgets/design_system/konata_pill_button.dart';
import '../widgets/design_system/konata_segmented_capsule.dart';
import '../widgets/design_system/konata_soft_text_field.dart';
import '../widgets/design_system/konata_toast.dart';

enum _SeriesManagePane { members, candidates }

class _MemberDraft {
  _MemberDraft({required this.work, required String initialLabel})
    : labelCtrl = TextEditingController(text: initialLabel);

  final Work work;
  final TextEditingController labelCtrl;

  void dispose() => labelCtrl.dispose();
}

/// 系列（Series）编组管理毛玻璃弹窗：合并多部作品、排序及设定预设/自定义角色标签。
class SeriesManageDialog extends ConsumerStatefulWidget {
  /// 创建系列编组管理弹窗。
  const SeriesManageDialog({super.key, required this.bundle});

  /// 当前所在作品详情数据包。
  final WorkDetailBundle bundle;

  @override
  ConsumerState<SeriesManageDialog> createState() => _SeriesManageDialogState();
}

class _SeriesManageDialogState extends ConsumerState<SeriesManageDialog> {
  final ScrollController _membersCtrl = ScrollController();
  final ScrollController _candidatesCtrl = ScrollController();
  late final TextEditingController _titleCtrl;
  late final TextEditingController _searchCtrl;
  final List<_MemberDraft> _members = <_MemberDraft>[];
  String? _editingSeriesId;
  _SeriesManagePane _mobilePane = _SeriesManagePane.members;
  bool _saving = false;
  bool _detachedPersisted = false;

  @override
  void initState() {
    super.initState();
    _editingSeriesId = widget.bundle.seriesGroup?.id ?? widget.bundle.work.seriesId;
    final defaultTitle =
        widget.bundle.seriesGroup?.title.trim().isNotEmpty == true
        ? widget.bundle.seriesGroup!.title.trim()
        : widget.bundle.work.title.trim();
    _titleCtrl = TextEditingController(text: defaultTitle);
    _searchCtrl = TextEditingController();

    final initialWorks = widget.bundle.seriesMembers.isNotEmpty
        ? widget.bundle.seriesMembers
        : <Work>[widget.bundle.work];
    for (var i = 0; i < initialWorks.length; i++) {
      final w = initialWorks[i];
      _members.add(
        _MemberDraft(work: w, initialLabel: _inferLabel(w, i + 1)),
      );
    }
  }

  @override
  void dispose() {
    _membersCtrl.dispose();
    _candidatesCtrl.dispose();
    _titleCtrl.dispose();
    _searchCtrl.dispose();
    for (final m in _members) {
      m.dispose();
    }
    super.dispose();
  }

  String _inferLabel(Work work, int index) {
    final existing = work.seriesLabel?.trim();
    if (existing != null && existing.isNotEmpty) return existing;
    if (work.tmdbMediaType == TmdbMediaType.tv &&
        work.matchedSeason != null &&
        work.matchedSeason! > 0) {
      return SeriesLabelPresets.seasonLabel(work.matchedSeason!);
    }
    if (work.tmdbMediaType == TmdbMediaType.movie) {
      return '剧场版';
    }
    if (work.matchedSeason == 0) {
      return '特别篇';
    }
    return SeriesLabelPresets.seasonLabel(index);
  }

  void _addMember(Work work) {
    if (_members.any((m) => m.work.id == work.id)) return;
    setState(() {
      _members.add(
        _MemberDraft(
          work: work,
          initialLabel: _inferLabel(work, _members.length + 1),
        ),
      );
    });
  }

  void _removeMemberAt(int index) {
    setState(() {
      final removed = _members.removeAt(index);
      removed.dispose();
    });
  }

  void _moveMember(int index, int delta) {
    final next = index + delta;
    if (next < 0 || next >= _members.length) return;
    setState(() {
      final item = _members.removeAt(index);
      _members.insert(next, item);
    });
  }

  void _switchToExistingSeries(SeriesGroup group, List<Work> allWorks) {
    setState(() {
      _editingSeriesId = group.id;
      _titleCtrl.text = group.title;
      final groupMembers =
          allWorks
              .where((w) => w.seriesId == group.id && !w.isHidden)
              .toList()
            ..sort(
              (a, b) =>
                  (a.seriesOrder ?? 9999).compareTo(b.seriesOrder ?? 9999),
            );
      // 保留当前正在浏览的作品，避免并入后反而丢掉自己。
      final merged = <Work>[
        ...groupMembers,
        if (!groupMembers.any((w) => w.id == widget.bundle.work.id))
          widget.bundle.work,
      ];
      for (final m in _members) {
        m.dispose();
      }
      _members
        ..clear()
        ..addAll([
          for (var i = 0; i < merged.length; i++)
            _MemberDraft(
              work: merged[i],
              initialLabel: _inferLabel(merged[i], i + 1),
            ),
        ]);
    });
  }

  bool get _canDetachToIndependentSeries =>
      (_editingSeriesId != null && _editingSeriesId!.trim().isNotEmpty) ||
      _members.length >= 2 ||
      widget.bundle.seriesGroup != null ||
      (widget.bundle.work.seriesId?.trim().isNotEmpty ?? false);

  Future<void> _detachToIndependentSeries() async {
    if (_saving) return;
    final currentWork = widget.bundle.work;
    final persistedSeriesId = currentWork.seriesId?.trim();

    if (persistedSeriesId != null && persistedSeriesId.isNotEmpty) {
      setState(() => _saving = true);
      try {
        final itemsAsync = ref.read(libraryItemsProvider);
        final allWorks = itemsAsync.maybeWhen(
          data: (list) => list.map((e) => e.work).toList(growable: false),
          orElse: () => widget.bundle.seriesMembers,
        );
        final remaining =
            allWorks
                .where((w) => w.seriesId == persistedSeriesId && w.id != currentWork.id)
                .toList()
              ..sort(
                (a, b) =>
                    (a.seriesOrder ?? 9999).compareTo(b.seriesOrder ?? 9999),
              );
        final groupTitle =
            widget.bundle.seriesGroup?.title.trim().isNotEmpty == true
            ? widget.bundle.seriesGroup!.title.trim()
            : (remaining.isNotEmpty ? remaining.first.title : currentWork.title);
        final keepEdits = <SeriesMemberEdit>[
          for (var i = 0; i < remaining.length; i++)
            SeriesMemberEdit(
              workId: remaining[i].id,
              order: i + 1,
              label: _inferLabel(remaining[i], i + 1),
            ),
        ];
        await ref.read(workManagementProvider).saveSeriesGroupConfig(
              seriesId: persistedSeriesId,
              title: groupTitle,
              members: keepEdits,
            );
        _detachedPersisted = true;
      } catch (e) {
        if (mounted) {
          setState(() => _saving = false);
          showKonataToast(context, '脱离系列失败: $e', isError: true);
        }
        return;
      }
    }

    if (!mounted) return;
    setState(() {
      _saving = false;
      _editingSeriesId = null;
      _titleCtrl.text = currentWork.title.trim();
      for (final m in _members) {
        m.dispose();
      }
      _members
        ..clear()
        ..add(
          _MemberDraft(
            work: currentWork,
            initialLabel: _inferLabel(currentWork, 1),
          ),
        );
    });
    showKonataToast(context, '已从原系列脱离为独立条目');
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final edits = <SeriesMemberEdit>[
        for (var i = 0; i < _members.length; i++)
          SeriesMemberEdit(
            workId: _members[i].work.id,
            order: i + 1,
            label: _members[i].labelCtrl.text.trim(),
          ),
      ];
      await ref.read(workManagementProvider).saveSeriesGroupConfig(
            seriesId: _editingSeriesId,
            title: _titleCtrl.text,
            members: edits,
          );
      if (mounted) {
        showKonataToast(
          context,
          _members.isEmpty ? '已移出当前系列编组' : '已保存系列编组并锁定关联顺序',
        );
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        showKonataToast(context, '保存系列编组失败: $e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final itemsAsync = ref.watch(libraryItemsProvider);
    final groupsAsync = ref.watch(seriesGroupsProvider);

    final allWorks = itemsAsync.maybeWhen(
      data: (list) => list.map((e) => e.work).where((w) => !w.isHidden).toList(),
      orElse: () => const <Work>[],
    );
    final groups = groupsAsync.maybeWhen(
      data: (list) => list,
      orElse: () => const <SeriesGroup>[],
    );
    final memberIds = _members.map((m) => m.work.id).toSet();
    final query = _searchCtrl.text.trim().toLowerCase();
    final candidates = allWorks
        .where((w) {
          if (memberIds.contains(w.id)) return false;
          if (w.scrapeStatus != ScrapeStatus.matched && !w.isManualLocked) {
            return false;
          }
          if (query.isEmpty) return true;
          return w.title.toLowerCase().contains(query) ||
              (w.originalTitle?.toLowerCase().contains(query) ?? false);
        })
        .take(30)
        .toList(growable: false);

    return KonataGlassDialog(
      width: 720,
      maxHeight: 650,
      title: '管理系列编组',
      onClose: _saving
          ? null
          : () => Navigator.of(context).pop(_detachedPersisted),
      actions: [
        KonataPillButton.ghost(
          label: '取消',
          compact: true,
          onPressed: _saving
              ? null
              : () => Navigator.of(context).pop(_detachedPersisted),
        ),
        KonataPillButton.primary(
          label: _saving ? '保存中...' : '保存并锁定系列 (${_members.length})',
          compact: true,
          onPressed: _saving ? null : _save,
        ),
      ],
      child: LayoutBuilder(
        builder: (context, outerConstraints) {
          final isNarrow = outerConstraints.maxWidth < 600;
          final isTightHeight =
              outerConstraints.maxHeight.isFinite &&
              outerConstraints.maxHeight < (isNarrow ? 460 : 340);

          final formSection = isNarrow
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    KonataSoftTextField(
                      controller: _titleCtrl,
                      label: '系列名称（在详情页切换下拉中展示）',
                    ),
                    if (groups.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Text(
                        '并入已有系列',
                        style: TextStyle(color: p.textSecondary, fontSize: 11.5),
                      ),
                      const SizedBox(height: 5),
                      KonataSearchableSelect<String>(
                        value: groups.any((g) => g.id == _editingSeriesId)
                            ? _editingSeriesId
                            : null,
                        hintText: '搜索要并入的已有系列...',
                        searchHint: '输入系列标题检索...',
                        enabled: !_saving,
                        options: [
                          for (final g in groups)
                            KonataDropdownOption<String>(
                              value: g.id,
                              label: g.title,
                            ),
                        ],
                        onChanged: (selectedId) {
                          final group = groups
                              .where((g) => g.id == selectedId)
                              .firstOrNull;
                          if (group != null) {
                            _switchToExistingSeries(group, allWorks);
                          }
                        },
                      ),
                    ],
                    if (_canDetachToIndependentSeries) ...[
                      const SizedBox(height: 10),
                      Align(
                        alignment: Alignment.centerRight,
                        child: KonataPillButton.secondary(
                          label: '脱离为独立系列',
                          icon: Icons.link_off_rounded,
                          compact: true,
                          onPressed: _saving ? null : _detachToIndependentSeries,
                        ),
                      ),
                    ],
                  ],
                )
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      flex: 3,
                      child: KonataSoftTextField(
                        controller: _titleCtrl,
                        label: '系列名称（在详情页切换下拉中展示）',
                      ),
                    ),
                    if (groups.isNotEmpty) ...[
                      const SizedBox(width: 12),
                      Expanded(
                        flex: 2,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '并入已有系列',
                              style: TextStyle(
                                color: p.textSecondary,
                                fontSize: 11.5,
                              ),
                            ),
                            const SizedBox(height: 5),
                            KonataSearchableSelect<String>(
                              value: groups.any((g) => g.id == _editingSeriesId)
                                  ? _editingSeriesId
                                  : null,
                              hintText: '搜索要并入的已有系列...',
                              searchHint: '输入系列标题检索...',
                              enabled: !_saving,
                              options: [
                                for (final g in groups)
                                  KonataDropdownOption<String>(
                                    value: g.id,
                                    label: g.title,
                                  ),
                              ],
                              onChanged: (selectedId) {
                                final group = groups
                                    .where((g) => g.id == selectedId)
                                    .firstOrNull;
                                if (group != null) {
                                  _switchToExistingSeries(group, allWorks);
                                }
                              },
                            ),
                          ],
                        ),
                      ),
                    ],
                    if (_canDetachToIndependentSeries) ...[
                      const SizedBox(width: 10),
                      Padding(
                        padding: const EdgeInsets.only(bottom: 1),
                        child: KonataPillButton.secondary(
                          label: '脱离为独立系列',
                          icon: Icons.link_off_rounded,
                          compact: true,
                          onPressed: _saving ? null : _detachToIndependentSeries,
                        ),
                      ),
                    ],
                  ],
                );

          final membersPane = Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: p.softFill,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: p.hairline),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    Text(
                      '系列成员与排序 (${_members.length})',
                      style: TextStyle(
                        color: p.textPrimary,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      '海报墙仍各自独立展示',
                      style: TextStyle(color: p.textMuted, fontSize: 11),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: _members.isEmpty
                      ? Center(
                          child: Text(
                            '当前编组已清空，保存后将解除系列关联；也可切换到库内作品列表重新添加。',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: p.textMuted, fontSize: 12),
                          ),
                        )
                      : KonataDraggableScrollbar(
                          controller: _membersCtrl,
                          builder: (_, ctrl) => ListView.separated(
                            controller: ctrl,
                            padding: const EdgeInsets.only(right: 10),
                            itemCount: _members.length,
                            separatorBuilder: (_, _) =>
                                Divider(height: 10, color: p.hairline),
                            itemBuilder: (_, index) {
                              final m = _members[index];
                              return _buildMemberRow(p, m, index);
                            },
                          ),
                        ),
                ),
              ],
            ),
          );

          final candidatesPane = Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: p.softFill,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: p.hairline),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                KonataSoftTextField(
                  controller: _searchCtrl,
                  hintText: '搜索库内作品加入此系列...',
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: candidates.isEmpty
                      ? Center(
                          child: Text(
                            query.isEmpty ? '暂无更多可加入的已入库作品' : '未找到匹配的库内作品',
                            style: TextStyle(color: p.textMuted, fontSize: 12),
                          ),
                        )
                      : KonataDraggableScrollbar(
                          controller: _candidatesCtrl,
                          builder: (_, ctrl) => ListView.separated(
                            controller: ctrl,
                            padding: const EdgeInsets.only(right: 10),
                            itemCount: candidates.length,
                            separatorBuilder: (_, _) =>
                                Divider(height: 8, color: p.hairline),
                            itemBuilder: (_, idx) {
                              final w = candidates[idx];
                              return InkWell(
                                borderRadius: BorderRadius.circular(8),
                                onTap: _saving ? null : () => _addMember(w),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 4,
                                  ),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              w.title,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                color: p.textPrimary,
                                                fontSize: 12.5,
                                                fontWeight: FontWeight.w500,
                                              ),
                                            ),
                                            if (w.year != null)
                                              Text(
                                                '${w.year}',
                                                style: TextStyle(
                                                  color: p.textMuted,
                                                  fontSize: 11,
                                                ),
                                              ),
                                          ],
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Icon(
                                        Icons.add_circle_outline_rounded,
                                        size: 18,
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
          );

          final bodyContent = isNarrow
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    MediaQuery.withClampedTextScaling(
                      maxScaleFactor: 1.15,
                      child: KonataSegmentedCapsule<_SeriesManagePane>(
                        compact: true,
                        selected: _mobilePane,
                        onChanged: (pane) => setState(() => _mobilePane = pane),
                        options: [
                          KonataSegmentOption(
                            value: _SeriesManagePane.members,
                            label: '成员排序 (${_members.length})',
                          ),
                          KonataSegmentOption(
                            value: _SeriesManagePane.candidates,
                            label: '添加作品 (${candidates.length})',
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),
                    Expanded(
                      child: _mobilePane == _SeriesManagePane.members
                          ? membersPane
                          : candidatesPane,
                    ),
                  ],
                )
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(flex: 13, child: membersPane),
                    const SizedBox(width: 12),
                    Expanded(flex: 9, child: candidatesPane),
                  ],
                );

          if (isTightHeight) {
            return KonataDraggableScrollbar(
              builder: (_, scrollCtrl) => SingleChildScrollView(
                controller: scrollCtrl,
                padding: const EdgeInsets.only(right: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    formSection,
                    const SizedBox(height: 12),
                    SizedBox(height: 240, child: bodyContent),
                  ],
                ),
              ),
            );
          }

          final targetH = outerConstraints.maxHeight.isFinite
              ? math.min(500.0, outerConstraints.maxHeight)
              : 500.0;
          return SizedBox(
            height: targetH,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                formSection,
                const SizedBox(height: 12),
                Expanded(child: bodyContent),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildMemberRow(KonataPalette p, _MemberDraft draft, int index) {
    final isCurrent = draft.work.id == widget.bundle.work.id;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 22,
              height: 22,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: isCurrent
                    ? p.accent.withValues(alpha: 0.22)
                    : p.softFill,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                '${index + 1}',
                style: TextStyle(
                  color: isCurrent ? p.accent : p.textSecondary,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    draft.work.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: p.textPrimary,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (draft.work.year != null)
                    Text(
                      '${draft.work.year}${isCurrent ? ' · 当前条目' : ''}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: p.textMuted, fontSize: 10.5),
                    ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: draft.labelCtrl,
                enabled: !_saving,
                style: TextStyle(color: p.textPrimary, fontSize: 12),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: '如 第 1 季 / Code: White',
                  hintStyle: TextStyle(color: p.textMuted, fontSize: 11.5),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 7,
                  ),
                  filled: true,
                  fillColor: p.elevatedSurface.withValues(alpha: 0.72),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: p.hairline),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: p.hairline),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 4),
            IconButton(
              tooltip: '上移',
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
              padding: EdgeInsets.zero,
              iconSize: 17,
              onPressed: (_saving || index == 0)
                  ? null
                  : () => _moveMember(index, -1),
              icon: const Icon(Icons.keyboard_arrow_up_rounded),
            ),
            IconButton(
              tooltip: '下移',
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
              padding: EdgeInsets.zero,
              iconSize: 17,
              onPressed: (_saving || index == _members.length - 1)
                  ? null
                  : () => _moveMember(index, 1),
              icon: const Icon(Icons.keyboard_arrow_down_rounded),
            ),
            IconButton(
              tooltip: '从系列移出',
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
              padding: EdgeInsets.zero,
              iconSize: 16,
              color: p.danger,
              onPressed: _saving ? null : () => _removeMemberAt(index),
              icon: const Icon(Icons.remove_circle_outline_rounded),
            ),
          ],
        ),
        const SizedBox(height: 6),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final preset in SeriesLabelPresets.presets) ...[
                InkWell(
                  borderRadius: BorderRadius.circular(6),
                  onTap: _saving
                      ? null
                      : () => setState(() => draft.labelCtrl.text = preset),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 3.5,
                    ),
                    decoration: BoxDecoration(
                      color: draft.labelCtrl.text.trim() == preset
                          ? p.accent.withValues(alpha: 0.18)
                          : p.softFill,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: draft.labelCtrl.text.trim() == preset
                            ? p.accent.withValues(alpha: 0.55)
                            : p.hairline,
                      ),
                    ),
                    child: Text(
                      preset,
                      style: TextStyle(
                        color: draft.labelCtrl.text.trim() == preset
                            ? p.accent
                            : p.textSecondary,
                        fontSize: 10.5,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 4),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
