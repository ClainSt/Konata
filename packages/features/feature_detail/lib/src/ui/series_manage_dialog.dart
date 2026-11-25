import 'dart:async';

import 'package:engine_scraping/engine_scraping.dart';
import 'package:flutter/widgets.dart';
import 'package:konata_design_system/konata_design_system.dart';

import '../data/detail_edit_models.dart';
import '../state/work_detail_controller.dart';
import 'detail_artwork_view.dart';

class _SeriesMemberRowState {
  _SeriesMemberRowState({required this.work, required String label})
    : labelCtrl = TextEditingController(text: label);

  final Work work;
  final TextEditingController labelCtrl;

  void dispose() {
    labelCtrl.dispose();
  }
}

/// 同系列（第一季 / 第二季 / 剧场版 / OVA）排序、标签编辑与关联作品编组弹窗。
class SeriesManageDialog extends StatefulWidget {
  /// 创建系列编组管理弹窗。
  const SeriesManageDialog({
    super.key,
    required this.controller,
    required this.anchorWork,
    required this.initialSeries,
    required this.initialMembers,
    required this.imageLoader,
  });

  /// 详情页状态控制器。
  final WorkDetailController controller;

  /// 当前入口作品。
  final Work anchorWork;

  /// 当前所属系列分组（未编组时为空）。
  final SeriesGroup? initialSeries;

  /// 当前系列已有成员清单。
  final List<Work> initialMembers;

  /// 受管图片加载器。
  final ManagedImageLoader imageLoader;

  @override
  State<SeriesManageDialog> createState() => _SeriesManageDialogState();
}

class _SeriesManageDialogState extends State<SeriesManageDialog> {
  static const List<String> _presets = <String>[
    '第一季',
    '第二季',
    '第三季',
    '第四季',
    '剧场版',
    'OVA',
    '特别篇',
  ];

  final TextEditingController _seriesTitleCtrl = TextEditingController();
  final TextEditingController _addSearchCtrl = TextEditingController();
  final ScrollController _membersScrollCtrl = ScrollController();

  final List<_SeriesMemberRowState> _members = <_SeriesMemberRowState>[];
  List<Work> _allWorks = const <Work>[];
  String _searchQuery = '';
  bool _loadingWorks = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _seriesTitleCtrl.text =
        widget.initialSeries?.title.trim().isNotEmpty == true
        ? widget.initialSeries!.title
        : widget.anchorWork.title;

    final seedList = widget.initialMembers.isNotEmpty
        ? SeriesSeasonFormatter.sortSeriesMembers(widget.initialMembers)
        : <Work>[widget.anchorWork];
    for (var i = 0; i < seedList.length; i++) {
      final work = seedList[i];
      final initialLabel = work.seriesLabel?.trim().isNotEmpty == true
          ? work.seriesLabel!.trim()
          : SeriesSeasonFormatter.formatMemberLabel(
              work,
              seedList,
              seriesGroup: widget.initialSeries,
              fallbackOrder: i + 1,
            );
      _members.add(_SeriesMemberRowState(work: work, label: initialLabel));
    }
    unawaited(_loadLibraryWorks());
  }

  @override
  void dispose() {
    _seriesTitleCtrl.dispose();
    _addSearchCtrl.dispose();
    _membersScrollCtrl.dispose();
    for (final m in _members) {
      m.dispose();
    }
    super.dispose();
  }

  Future<void> _loadLibraryWorks() async {
    try {
      final works = await widget.controller.listAllVisibleWorks();
      if (!mounted) return;
      setState(() {
        _allWorks = works;
        _loadingWorks = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() => _loadingWorks = false);
      }
    }
  }

  void _moveMember(int index, int delta) {
    final target = index + delta;
    if (target < 0 || target >= _members.length) return;
    setState(() {
      final moved = _members.removeAt(index);
      _members.insert(target, moved);
    });
  }

  void _addMemberWork(Work work) {
    if (_members.any((m) => m.work.id == work.id)) return;
    final nextOrder = _members.length + 1;
    final defaultLabel = work.seriesLabel?.trim().isNotEmpty == true
        ? work.seriesLabel!.trim()
        : '第 $nextOrder 季';
    setState(() {
      _members.add(_SeriesMemberRowState(work: work, label: defaultLabel));
    });
  }

  void _removeMemberAt(int index) {
    if (_members.length <= 1) return;
    setState(() {
      final removed = _members.removeAt(index);
      removed.dispose();
    });
  }

  Future<void> _save() async {
    if (_saving) return;
    final title = _seriesTitleCtrl.text.trim();
    if (title.isEmpty) {
      showKonataToast(context, '系列名称不能为空', isError: true);
      return;
    }
    setState(() => _saving = true);
    try {
      await widget.controller.saveSeriesGroupConfig(
        seriesId: widget.initialSeries?.id,
        title: title,
        tmdbCollectionId: widget.initialSeries?.tmdbCollectionId,
        members: [
          for (var i = 0; i < _members.length; i++)
            SeriesMemberEdit(
              workId: _members[i].work.id,
              order: i + 1,
              label: _members[i].labelCtrl.text.trim().isNotEmpty
                  ? _members[i].labelCtrl.text.trim()
                  : '第 ${i + 1} 季',
            ),
        ],
      );
      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } catch (error) {
      if (mounted) {
        setState(() => _saving = false);
        showKonataToast(context, '保存系列编组失败：$error', isError: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final existingIds = _members.map((e) => e.work.id).toSet();
    final q = _searchQuery.trim().toLowerCase();
    final addCandidates = _allWorks
        .where((w) {
          if (existingIds.contains(w.id)) return false;
          if (q.isEmpty) return false;
          return w.title.toLowerCase().contains(q) ||
              (w.originalTitle?.toLowerCase().contains(q) ?? false);
        })
        .take(6)
        .toList(growable: false);

    return KonataGlassDialog(
      width: 680,
      maxHeight: 620,
      title: '管理系列与季度编组',
      onClose: _saving ? null : () => Navigator.of(context).pop(false),
      actions: [
        KonataPillButton.ghost(
          label: '取消',
          compact: true,
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
        ),
        KonataPillButton.primary(
          label: _saving ? '保存中...' : '保存系列编组',
          icon: Icons.check_rounded,
          compact: true,
          onPressed: _saving ? null : _save,
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          KonataSoftTextField(
            controller: _seriesTitleCtrl,
            label: '系列显示总标题',
            hintText: '例如：青春猪头少年系列',
          ),
          const SizedBox(height: 12),
          Text(
            '系列内成员顺序与分季标签（${_members.length} 部）',
            style: KonataTheme.bodyLabelStyle(
              p,
              color: p.textSecondary,
              fontSize: KonataTheme.fontSizeCaption,
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: KonataDraggableScrollbar(
              controller: _membersScrollCtrl,
              builder: (_, ctrl) => ListView.separated(
                controller: ctrl,
                itemCount: _members.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (_, index) {
                  final row = _members[index];
                  final poster = row.work.posterPath?.trim() ?? '';
                  return KonataSurfaceCard(
                    padding: const EdgeInsets.all(10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            ClipRRect(
                              borderRadius: KonataTheme.borderRadiusChip,
                              child: SizedBox(
                                width: 32,
                                height: 46,
                                child: poster.isNotEmpty
                                    ? DetailManagedImage(
                                        poster,
                                        loader: widget.imageLoader,
                                        owner: row.work.id,
                                        artwork: ManagedArtwork.poster,
                                        decodeWidth: 160,
                                      )
                                    : DecoratedBox(
                                        decoration: BoxDecoration(
                                          color: p.softFill,
                                        ),
                                      ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    row.work.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: KonataTheme.cardTitleStyle(
                                      p,
                                      fontSize: KonataTheme.fontSizeBodySm,
                                    ),
                                  ),
                                  if (row.work.year != null)
                                    Text(
                                      '${row.work.year}',
                                      style: KonataTheme.captionStyle(
                                        p,
                                      ).copyWith(color: p.textMuted),
                                    ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            SizedBox(
                              width: 132,
                              child: KonataSoftTextField(
                                controller: row.labelCtrl,
                                dense: true,
                                hintText: '展示标签',
                              ),
                            ),
                            const SizedBox(width: 4),
                            KonataCapsuleIconButton(
                              icon: Icons.keyboard_arrow_up_rounded,
                              tooltip: '上移',
                              color: p.textSecondary,
                              size: 18,
                              padding: const EdgeInsets.all(6),
                              onTap: index > 0 && !_saving
                                  ? () => _moveMember(index, -1)
                                  : null,
                            ),
                            KonataCapsuleIconButton(
                              icon: Icons.keyboard_arrow_down_rounded,
                              tooltip: '下移',
                              color: p.textSecondary,
                              size: 18,
                              padding: const EdgeInsets.all(6),
                              onTap: index < _members.length - 1 && !_saving
                                  ? () => _moveMember(index, 1)
                                  : null,
                            ),
                            if (_members.length > 1)
                              KonataCapsuleIconButton(
                                icon: Icons.close_rounded,
                                tooltip: '移出本系列',
                                color: p.danger,
                                size: 17,
                                padding: const EdgeInsets.all(6),
                                onTap: _saving
                                    ? null
                                    : () => _removeMemberAt(index),
                              ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          children: [
                            for (final preset in _presets)
                              GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTap: _saving
                                    ? null
                                    : () => setState(() {
                                        row.labelCtrl.text = preset;
                                      }),
                                child: KonataSpecBadge(
                                  label: preset,
                                  highlighted: row.labelCtrl.text.trim() == preset,
                                ),
                              ),
                          ],
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
          const SizedBox(height: 10),
          KonataSoftTextField(
            controller: _addSearchCtrl,
            dense: true,
            prefixIcon: Icons.add_rounded,
            hintText: _loadingWorks
                ? '正在索引库内作品...'
                : '输入库内其他季度或剧场版名称以加入该系列...',
            onChanged: (v) => setState(() => _searchQuery = v),
          ),
          if (addCandidates.isNotEmpty) ...[
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final cand in addCandidates)
                  KonataPillButton.secondary(
                    label: cand.title,
                    icon: Icons.add_rounded,
                    compact: true,
                    onPressed: _saving ? null : () => _addMemberWork(cand),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
