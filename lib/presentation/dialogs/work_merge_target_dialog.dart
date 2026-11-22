import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/providers/artwork_provider.dart';
import '../../application/providers/library_providers.dart';
import '../../application/providers/work_management_provider.dart';
import '../../domain/models/episode.dart';
import '../../domain/models/work.dart';
import '../theme/konata_palette.dart';
import '../widgets/design_system/ellipsis_text_with_tooltip.dart';
import '../widgets/design_system/konata_draggable_scrollbar.dart';
import '../widgets/design_system/konata_glass_dialog.dart';
import '../widgets/design_system/konata_pill_button.dart';
import '../widgets/design_system/konata_segmented_capsule.dart';
import '../widgets/design_system/konata_soft_text_field.dart';
import '../widgets/design_system/konata_toast.dart';
import '../widgets/managed_image.dart';
import '../theme/konata_theme.dart';

/// 并入已有作品时的视频分类归属模式。
enum MergeVideoCategoryMode {
  /// 保持原文件所属分类（全作品合并时默认可选）。
  preserve,

  /// 全部作为「特典 / 附加映像」归入目标作品。
  asExtra,

  /// 全部作为「正片剧集」顺延或对应集号并入目标作品。
  asMain,
}

/// 可搜索的库内已有作品选择与并入弹窗。
class WorkMergeTargetDialog extends ConsumerStatefulWidget {
  /// 创建「将整部作品或指定文件并入已有作品」弹窗。
  const WorkMergeTargetDialog({
    super.key,
    required this.sourceWorkId,
    required this.sourceWorkTitle,
    this.variantIds = const [],
    this.initialMode,
  });

  /// 来源作品 ID。
  final String sourceWorkId;

  /// 来源作品名称（用于展示提示）。
  final String sourceWorkTitle;

  /// 若非空则仅迁移指定文件；为空时整部作品合并并删除空壳。
  final List<String> variantIds;

  /// 默认选中的分类模式。
  final MergeVideoCategoryMode? initialMode;

  bool get _isPartialMove => variantIds.isNotEmpty;

  @override
  ConsumerState<WorkMergeTargetDialog> createState() =>
      _WorkMergeTargetDialogState();
}

class _WorkMergeTargetDialogState extends ConsumerState<WorkMergeTargetDialog> {
  final TextEditingController _searchCtrl = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  final ScrollController _listCtrl = ScrollController();
  String _query = '';
  String? _selectedTargetId;
  late MergeVideoCategoryMode _mode;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _mode = widget.initialMode ??
        (widget._isPartialMove
            ? MergeVideoCategoryMode.asExtra
            : MergeVideoCategoryMode.preserve);
  }

  @override
  void dispose() {
    _searchFocusNode.dispose();
    _searchCtrl.dispose();
    _listCtrl.dispose();
    super.dispose();
  }

  List<WorkLibraryItem> _filterCandidates(List<WorkLibraryItem> items) {
    final q = _query.trim().toLowerCase();
    final filtered = items.where((item) {
      final w = item.work;
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
    }).toList();

    final srcNorm = widget.sourceWorkTitle.trim().toLowerCase();
    filtered.sort((a, b) {
      final aSim = _titleMatchWeight(a.work, srcNorm);
      final bSim = _titleMatchWeight(b.work, srcNorm);
      if (aSim != bSim) return bSim.compareTo(aSim);
      return a.work.title.toLowerCase().compareTo(b.work.title.toLowerCase());
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
      final actions = ref.read(workManagementProvider);
      final EpisodeCategory? forceCat = switch (_mode) {
        MergeVideoCategoryMode.preserve => null,
        MergeVideoCategoryMode.asExtra => EpisodeCategory.extra,
        MergeVideoCategoryMode.asMain => EpisodeCategory.main,
      };
      final WorkMergeOutcome outcome;
      if (widget._isPartialMove) {
        outcome = await actions.moveVariantsToExistingWork(
          sourceWorkId: widget.sourceWorkId,
          variantIds: widget.variantIds,
          targetWorkId: targetId,
          targetCategory: forceCat ?? EpisodeCategory.extra,
        );
      } else {
        outcome = await actions.mergeWorkIntoExisting(
          sourceWorkId: widget.sourceWorkId,
          targetWorkId: targetId,
          forceCategory: forceCat,
        );
      }
      if (mounted) {
        Navigator.of(context).pop(outcome);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _submitting = false);
        showKonataToast(context, '并入失败: $e', isError: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final confirmedAsync = ref.watch(confirmedLibraryItemsProvider);
    final imageLoader = ref.watch(tmdbImageLoaderProvider);
    final candidates = _filterCandidates(confirmedAsync.value ?? const []);

    return KonataGlassDialog(
      width: 640,
      maxHeight: 590,
      title: widget._isPartialMove
          ? '移至其他库内作品 (${widget.variantIds.length} 个文件)'
          : '并入已有作品 · ${widget.sourceWorkTitle}',
      onClose: _submitting ? () {} : () => Navigator.of(context).pop(),
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
                KonataSearchField(
                  controller: _searchCtrl,
                  focusNode: _searchFocusNode,
                  dense: true,
                  onChanged: (v) => setState(() => _query = v),
                ),
                const SizedBox(height: 10),
                Offstage(
                  offstage: landscapeCompact,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Text(
                            '归入方式：',
                            style: TextStyle(
                              color: p.textSecondary,
                              fontSize: KonataTheme.fontSizeCaption,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: MediaQuery.withClampedTextScaling(
                                maxScaleFactor: 1.15,
                                child:
                                    KonataSegmentedCapsule<
                                      MergeVideoCategoryMode
                                    >(
                                      compact: true,
                                      selected: _mode,
                                      options: [
                                        if (!widget._isPartialMove)
                                          const KonataSegmentOption(
                                            value:
                                                MergeVideoCategoryMode.preserve,
                                            label: '原分类',
                                          ),
                                        const KonataSegmentOption(
                                          value: MergeVideoCategoryMode.asExtra,
                                          label: '特典',
                                        ),
                                        const KonataSegmentOption(
                                          value: MergeVideoCategoryMode.asMain,
                                          label: '正片',
                                        ),
                                      ],
                                      onChanged: _submitting
                                          ? (_) {}
                                          : (m) => setState(() => _mode = m),
                                    ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                    ],
                  ),
                ),
                Expanded(
                  child: candidates.isEmpty
                  ? Center(
                      child: Text(
                        confirmedAsync.isLoading
                            ? '正在加载媒体库条目...'
                            : '未找到匹配的已入库作品',
                        style: TextStyle(color: p.textSecondary, fontSize: KonataTheme.fontSizeBodySm),
                      ),
                    )
                  : KonataDraggableScrollbar(
                      controller: _listCtrl,
                      builder: (_, ctrl) => ListView.separated(
                        controller: ctrl,
                        padding: const EdgeInsets.only(right: 12),
                        itemCount: candidates.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 6),
                        itemBuilder: (_, index) {
                          final item = candidates[index];
                          final work = item.work;
                          final selected = work.id == _selectedTargetId;
                          final seasonText =
                              work.tmdbMediaType == TmdbMediaType.movie
                              ? '剧场版'
                              : (work.matchedSeason != null
                                    ? 'S${work.matchedSeason.toString().padLeft(2, '0')}'
                                    : 'TV');
                          return InkWell(
                            borderRadius: KonataTheme.borderRadiusControl,
                            onTap: _submitting
                                ? null
                                : () =>
                                      setState(() => _selectedTargetId = work.id),
                            child: AnimatedContainer(
                              duration: KonataTheme.motionFast,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 8,
                              ),
                              decoration: BoxDecoration(
                                color: selected
                                    ? p.accent.withValues(alpha: 0.16)
                                    : p.softFill,
                                borderRadius: KonataTheme.borderRadiusControl,
                                border: Border.all(
                                  color: selected
                                      ? p.accent.withValues(alpha: 0.65)
                                      : p.hairline,
                                ),
                              ),
                              child: Row(
                                children: [
                                  ClipRRect(
                                    borderRadius: KonataTheme.borderRadiusChipSm,
                                    child: SizedBox(
                                      width: 34,
                                      height: 48,
                                      child: (work.posterPath ?? '').isNotEmpty
                                          ? ManagedImage(
                                              work.posterPath!,
                                              loader: imageLoader,
                                              owner: work.id,
                                              artwork: ManagedArtwork.poster,
                                              fit: BoxFit.cover,
                                            )
                                          : Container(color: p.surface),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        EllipsisTextWithTooltip(
                                          text: work.title,
                                          maxLines: 1,
                                          style: TextStyle(
                                            color: p.textPrimary,
                                            fontSize: KonataTheme.fontSizeBodySm,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          [
                                            if (work.year != null)
                                              '${work.year}',
                                            seasonText,
                                            '正片 ${item.episodeCount} 集',
                                            if (work.tmdbId != null)
                                              'TMDB #${work.tmdbId}',
                                            if (work.bangumiId != null)
                                              'BGM #${work.bangumiId}',
                                          ].join(' · '),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            color: p.textSecondary,
                                            fontSize: KonataTheme.fontSizeCaptionSm,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Icon(
                                    selected
                                        ? Icons.check_circle_rounded
                                        : Icons.radio_button_unchecked_rounded,
                                    size: 18,
                                    color: selected ? p.accent : p.textMuted,
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
