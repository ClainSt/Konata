import 'dart:async';
import 'dart:math' as math;

import 'package:engine_scraping/engine_scraping.dart';
import 'package:flutter/widgets.dart';
import 'package:konata_design_system/konata_design_system.dart';

import '../data/detail_edit_models.dart';
import '../state/work_detail_controller.dart';
import 'detail_artwork_view.dart';

/// 选择将整部作品或指定物理文件并入库内已有作品的目标选择器弹窗。
class WorkMergeTargetDialog extends StatefulWidget {
  /// 创建合并目标选择弹窗（`variantIds` 为空时整部并入，非空时局部迁移）。
  const WorkMergeTargetDialog({
    super.key,
    required this.controller,
    required this.sourceWorkId,
    required this.sourceWorkTitle,
    required this.imageLoader,
    this.variantIds = const <String>[],
    this.dialogTitle,
  });

  /// 详情页状态控制器。
  final WorkDetailController controller;

  /// 原作品唯一主键。
  final String sourceWorkId;

  /// 原作品标题。
  final String sourceWorkTitle;

  /// 受管图片加载器。
  final ManagedImageLoader imageLoader;

  /// 若非空则仅迁移指定物理版本列表至目标作品。
  final List<String> variantIds;

  /// 调用方指定的合并弹窗标题。
  final String? dialogTitle;

  bool get _isPartialMove => variantIds.isNotEmpty;

  @override
  State<WorkMergeTargetDialog> createState() => _WorkMergeTargetDialogState();
}

class _WorkMergeTargetDialogState extends State<WorkMergeTargetDialog> {
  final TextEditingController _searchCtrl = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  final ScrollController _listCtrl = ScrollController();

  List<Work> _works = const <Work>[];
  String _query = '';
  String? _selectedTargetId;
  MergeVideoCategoryMode _mode = MergeVideoCategoryMode.preserve;
  bool _loading = true;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _mode = widget._isPartialMove
        ? MergeVideoCategoryMode.asExtra
        : MergeVideoCategoryMode.preserve;
    unawaited(_loadWorks());
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _searchFocusNode.dispose();
    _listCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadWorks() async {
    try {
      final list = await widget.controller.listAllVisibleWorks();
      if (!mounted) return;
      setState(() {
        _works = list;
        _loading = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  List<Work> _filterCandidates() {
    final q = _query.trim().toLowerCase();
    final filtered = _works
        .where((w) {
          if (w.id == widget.sourceWorkId) return false;
          if (q.isEmpty) return true;
          if (w.title.toLowerCase().contains(q)) return true;
          if ((w.originalTitle ?? '').toLowerCase().contains(q)) return true;
          if (w.year != null && w.year.toString().contains(q)) return true;
          if (w.tmdbId != null && w.tmdbId.toString().contains(q)) return true;
          if (w.bangumiId != null && w.bangumiId.toString().contains(q)) {
            return true;
          }
          return false;
        })
        .toList();

    final srcNorm = widget.sourceWorkTitle.trim().toLowerCase();
    filtered.sort((a, b) {
      final aSim = _titleMatchWeight(a, srcNorm);
      final bSim = _titleMatchWeight(b, srcNorm);
      if (aSim != bSim) return bSim.compareTo(aSim);
      return a.title.toLowerCase().compareTo(b.title.toLowerCase());
    });
    return filtered;
  }

  int _titleMatchWeight(Work w, String srcNorm) {
    if (srcNorm.isEmpty) return 0;
    final t = w.title.toLowerCase();
    final o = (w.originalTitle ?? '').toLowerCase();
    if (t == srcNorm || o == srcNorm) return 3;
    if (srcNorm.contains(t) || t.contains(srcNorm)) return 2;
    if (o.isNotEmpty && (srcNorm.contains(o) || o.contains(srcNorm))) return 2;
    return 0;
  }

  Future<void> _submit() async {
    final targetId = _selectedTargetId;
    if (targetId == null || _submitting) return;
    setState(() => _submitting = true);
    try {
      final EpisodeCategory? forceCategory = switch (_mode) {
        MergeVideoCategoryMode.preserve => null,
        MergeVideoCategoryMode.asExtra => EpisodeCategory.extra,
        MergeVideoCategoryMode.asMain => EpisodeCategory.main,
      };
      final WorkMergeOutcome outcome;
      if (widget._isPartialMove) {
        outcome = await widget.controller.moveVariantsToExistingWork(
          variantIds: widget.variantIds,
          targetWorkId: targetId,
          targetCategory: forceCategory ?? EpisodeCategory.extra,
        );
      } else {
        outcome = await widget.controller.mergeWorkIntoExisting(
          targetWorkId: targetId,
          forceCategory: forceCategory,
        );
      }
      if (mounted) {
        Navigator.of(context).pop(outcome);
      }
    } catch (error) {
      if (mounted) {
        setState(() => _submitting = false);
        showKonataToast(context, '并入失败：$error', isError: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final candidates = _filterCandidates();

    return KonataGlassDialog(
      width: 640,
      maxHeight: 590,
      title: widget.dialogTitle ?? (widget._isPartialMove
          ? '移至其他库内作品 (${widget.variantIds.length} 个文件)'
          : '并入已有作品 · ${widget.sourceWorkTitle}'),
      onClose: _submitting ? null : () => Navigator.of(context).pop(),
      actions: [
        KonataPillButton.ghost(
          label: '取消',
          compact: true,
          onPressed: _submitting ? null : () => Navigator.of(context).pop(),
        ),
        KonataPillButton.primary(
          label: _submitting ? '正在迁移...' : '确认并入目标作品',
          icon: Icons.merge_type_rounded,
          compact: true,
          onPressed: (_submitting || _selectedTargetId == null) ? null : _submit,
        ),
      ],
      child: LayoutBuilder(
        builder: (dialogCtx, outerConstraints) {
          final targetH = outerConstraints.maxHeight.isFinite
              ? math.min(430.0, outerConstraints.maxHeight)
              : 430.0;
          final landscapeCompact =
              KonataGlassDialog.isLandscapeCompactInputActive(dialogCtx);
          return SizedBox(
            height: targetH,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                KonataSoftTextField(
                  controller: _searchCtrl,
                  focusNode: _searchFocusNode,
                  dense: true,
                  prefixIcon: Icons.search_rounded,
                  hintText: '搜索目标作品标题、原名、年份或 TMDB/Bangumi ID...',
                  onChanged: (v) => setState(() => _query = v),
                ),
                const SizedBox(height: 10),
                Offstage(
                  offstage: landscapeCompact,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            '归入方式：',
                            style: TextStyle(
                              color: p.textSecondary,
                              fontSize: KonataTheme.fontSizeCaption,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          KonataSegmentedCapsule<MergeVideoCategoryMode>(
                            compact: true,
                            selected: _mode,
                            onChanged: (next) => setState(() => _mode = next),
                            options: [
                              if (!widget._isPartialMove)
                                const KonataSegmentOption(
                                  value: MergeVideoCategoryMode.preserve,
                                  label: '保持原分类',
                                ),
                              const KonataSegmentOption(
                                value: MergeVideoCategoryMode.asExtra,
                                label: '全部作为特典',
                              ),
                              const KonataSegmentOption(
                                value: MergeVideoCategoryMode.asMain,
                                label: '归入正片分集',
                              ),
                            ],
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                    ],
                  ),
                ),
                Expanded(
                  child: _loading
                      ? const Center(child: CircularProgressIndicator())
                      : candidates.isEmpty
                      ? Center(
                          child: Text(
                            '未找到可并入的其他作品',
                            style: KonataTheme.bodyLabelStyle(
                              p,
                              color: p.textSecondary,
                            ),
                          ),
                        )
                      : KonataDraggableScrollbar(
                          controller: _listCtrl,
                          builder: (_, ctrl) => ListView.separated(
                            controller: ctrl,
                            itemCount: candidates.length,
                            separatorBuilder: (_, _) =>
                                const SizedBox(height: 6),
                            itemBuilder: (_, index) {
                              final work = candidates[index];
                              final selected = _selectedTargetId == work.id;
                              final poster = work.posterPath?.trim() ?? '';
                              return GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTap: _submitting
                                    ? null
                                    : () => setState(
                                        () => _selectedTargetId = work.id,
                                      ),
                                child: KonataSurfaceCard(
                                  enableHover: true,
                                  borderColor: selected ? p.accent : null,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 8,
                                  ),
                                  child: Row(
                                    children: [
                                      ClipRRect(
                                        borderRadius:
                                            KonataTheme.borderRadiusChip,
                                        child: SizedBox(
                                          width: 34,
                                          height: 48,
                                          child: poster.isNotEmpty
                                              ? DetailManagedImage(
                                                  poster,
                                                  loader: widget.imageLoader,
                                                  owner: work.id,
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
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              work.title,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: KonataTheme.cardTitleStyle(
                                                p,
                                                fontSize:
                                                    KonataTheme.fontSizeBodySm,
                                              ),
                                            ),
                                            const SizedBox(height: 2),
                                            Text(
                                              [
                                                if (work.year != null)
                                                  '${work.year}',
                                                if (work.tmdbId != null)
                                                  'TMDB ${work.tmdbId}',
                                                if (work.bangumiId != null)
                                                  'BGM ${work.bangumiId}',
                                              ].join(' · '),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style:
                                                  KonataTheme.captionStyle(
                                                    p,
                                                  ).copyWith(
                                                    color: p.textMuted,
                                                  ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      if (selected)
                                        Icon(
                                          Icons.check_circle_rounded,
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
        },
      ),
    );
  }
}
