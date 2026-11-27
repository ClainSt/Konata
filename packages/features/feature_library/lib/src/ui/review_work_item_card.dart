import 'package:engine_scraping/engine_scraping.dart';
import 'package:flutter/widgets.dart';
import 'package:konata_design_system/konata_design_system.dart';

import '../data/library_models.dart';
import 'library_artwork_view.dart';

/// 待复核队列中单个待确认作品的交互卡片组件。
class ReviewWorkItemCard extends StatefulWidget {
  /// 创建待复核作品卡片。
  const ReviewWorkItemCard({
    super.key,
    required this.work,
    required this.folderLabel,
    required this.variantCount,
    required this.candidates,
    required this.isLoadingCandidates,
    required this.isBusy,
    required this.onEnsureCandidatesLoaded,
    required this.onRematch,
    required this.onManualMatch,
    required this.onInspectSourceFiles,
    required this.onMergeIntoExisting,
    required this.onDismissReview,
    required this.onAcceptCandidate,
  });

  /// 待复核作品元数据。
  final Work work;

  /// 整理后的目录与媒体源摘要路径。
  final String folderLabel;

  /// 关联本地或远程物理变体数量。
  final int variantCount;

  /// 数据库或刚重跑生成的候选匹配列表。
  final List<ScrapeCandidateSummary> candidates;

  /// 候选列表是否正在异步读取中。
  final bool isLoadingCandidates;

  /// 当前卡片是否正在执行网络请求或数据库提交。
  final bool isBusy;

  /// 展开候选项时触发的按需加载回调。
  final VoidCallback onEnsureCandidatesLoaded;

  /// 触发自动重新匹配。
  final VoidCallback onRematch;

  /// 打开手动搜索与混合匹配弹窗。
  final VoidCallback? onManualMatch;

  /// 打开源文件核对与拆包弹窗。
  final VoidCallback? onInspectSourceFiles;

  /// 打开并入已有作品弹窗。
  final VoidCallback? onMergeIntoExisting;

  /// 确认保留当前元数据并移出待复核队列。
  final VoidCallback onDismissReview;

  /// 采纳并绑定指定高潜候选。
  final ValueChanged<ScrapeCandidateSummary> onAcceptCandidate;

  @override
  State<ReviewWorkItemCard> createState() => _ReviewWorkItemCardState();
}

class _ReviewWorkItemCardState extends State<ReviewWorkItemCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _expandController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );
  late final Animation<double> _expandAnimation = CurvedAnimation(
    parent: _expandController,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  );
  bool _expanded = false;

  @override
  void dispose() {
    _expandController.dispose();
    super.dispose();
  }

  void _toggleExpanded() {
    final next = !_expanded;
    setState(() => _expanded = next);
    if (next) {
      widget.onEnsureCandidatesLoaded();
      _expandController.forward();
    } else {
      _expandController.reverse();
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final work = widget.work;
    final compact = MediaQuery.sizeOf(context).width < 640;
    final reasonText = ReviewReasonLabels.format(work.reviewReason);

    final quickHeaderActions = Wrap(
      spacing: 6,
      runSpacing: 6,
      children: <Widget>[
        KonataPillButton.ghost(
          label: widget.isBusy ? '处理中…' : '重新匹配',
          icon: Icons.auto_awesome_outlined,
          compact: true,
          onPressed: widget.isBusy ? null : widget.onRematch,
        ),
        KonataPillButton.ghost(
          label: '源文件',
          icon: Icons.video_library_outlined,
          compact: true,
          onPressed: widget.isBusy ? null : widget.onInspectSourceFiles,
        ),
      ],
    );

    return KonataSurfaceCard(
      enableHover: true,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (compact) ...<Widget>[
            _buildTitleMeta(context, reasonText),
            const SizedBox(height: 8),
            Align(alignment: Alignment.centerRight, child: quickHeaderActions),
          ] else
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(child: _buildTitleMeta(context, reasonText)),
                const SizedBox(width: 12),
                quickHeaderActions,
              ],
            ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  KonataPillButton.secondary(
                    label: '手动搜索',
                    icon: Icons.search_rounded,
                    compact: true,
                    onPressed: widget.isBusy ? null : widget.onManualMatch,
                  ),
                  KonataPillButton.secondary(
                    label: '并入已有作品',
                    icon: Icons.merge_type_rounded,
                    compact: true,
                    onPressed: widget.isBusy
                        ? null
                        : widget.onMergeIntoExisting,
                  ),
                  KonataPillButton.ghost(
                    label: '忽略复核',
                    icon: Icons.check_circle_outline_rounded,
                    compact: true,
                    onPressed: widget.isBusy ? null : widget.onDismissReview,
                  ),
                ],
              ),
              _CandidateToggleButton(
                expanded: _expanded,
                candidateCount: widget.candidates.length,
                loading: widget.isLoadingCandidates,
                onTap: _toggleExpanded,
              ),
            ],
          ),
          AnimatedBuilder(
            animation: _expandAnimation,
            builder: (context, child) {
              if (!_expanded && _expandAnimation.isDismissed) {
                return const SizedBox.shrink();
              }
              return ClipRect(
                child: Align(
                  alignment: Alignment.topCenter,
                  heightFactor: _expandAnimation.value,
                  child: FadeTransition(
                    opacity: _expandAnimation,
                    child: child,
                  ),
                ),
              );
            },
            child: _buildCandidatesPanel(p),
          ),
        ],
      ),
    );
  }

  Widget _buildTitleMeta(BuildContext context, String reasonText) {
    final p = context.palette;
    final work = widget.work;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          work.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: KonataTheme.cardTitleStyle(
            p,
            fontSize: KonataTheme.fontSizeBodyMd,
          ),
        ),
        const SizedBox(height: 5),
        Row(
          children: <Widget>[
            Icon(Icons.folder_outlined, size: 13, color: p.textMuted),
            const SizedBox(width: 5),
            Expanded(
              child: Text(
                widget.folderLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: KonataTheme.textStyle(
                  color: p.textSecondary,
                  fontSize: KonataTheme.fontSizeCaptionSm,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            _MetaChip(
              label: '${widget.variantCount} 个文件',
              bg: p.softFill,
              fg: p.textSecondary,
              border: p.hairline,
            ),
            if (work.year != null)
              _MetaChip(
                label: '${work.year} 年',
                bg: p.softFill,
                fg: p.textSecondary,
                border: p.hairline,
              ),
            _MetaChip(
              label: reasonText,
              bg: p.warningBadge.bg,
              fg: p.warningBadge.fg,
              border: p.warningBadge.border,
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildCandidatesPanel(KonataPalette p) {
    if (widget.isLoadingCandidates && widget.candidates.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: p.hairline)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              ClipRRect(
                borderRadius: KonataTheme.borderRadiusPill,
                child: LinearProgressIndicator(
                  minHeight: 2,
                  color: p.accent,
                  backgroundColor: p.hairline,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                '正在读取候选条目…',
                textAlign: TextAlign.center,
                style: KonataTheme.captionStyle(p),
              ),
            ],
          ),
        ),
      );
    }

    if (widget.candidates.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
          decoration: BoxDecoration(
            color: p.softFill,
            borderRadius: KonataTheme.borderRadiusControl,
            border: Border.all(color: p.hairline),
          ),
          child: Text(
            '暂无可自动采纳的高潜候选，建议点击「手动搜索」或检查源文件名',
            style: KonataTheme.captionStyle(p),
          ),
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.only(top: 10),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: p.hairline)),
      ),
      child: Column(
        children: <Widget>[
          for (var i = 0; i < widget.candidates.length; i++) ...<Widget>[
            if (i > 0) const SizedBox(height: 8),
            _ReviewCandidateRow(
              candidate: widget.candidates[i],
              busy: widget.isBusy,
              onAccept: () => widget.onAcceptCandidate(widget.candidates[i]),
            ),
          ],
        ],
      ),
    );
  }
}

class _CandidateToggleButton extends StatefulWidget {
  const _CandidateToggleButton({
    required this.expanded,
    required this.candidateCount,
    required this.loading,
    required this.onTap,
  });

  final bool expanded;
  final int candidateCount;
  final bool loading;
  final VoidCallback onTap;

  @override
  State<_CandidateToggleButton> createState() => _CandidateToggleButtonState();
}

class _CandidateToggleButtonState extends State<_CandidateToggleButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final label = widget.expanded
        ? '收起候选'
        : widget.candidateCount > 0
        ? '展开候选 (${widget.candidateCount})'
        : '查看候选';

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: KonataTheme.motionMicro,
          height: 30,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: widget.expanded
                ? p.accentBadge.bg
                : (_hovered ? p.surfaceHover : p.softFill),
            borderRadius: KonataTheme.borderRadiusPill,
            border: Border.all(
              color: widget.expanded
                  ? p.accentBadge.border
                  : (_hovered ? p.hoverBorder : p.hairline),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                label,
                style: KonataTheme.textStyle(
                  color: widget.expanded ? p.accentBadge.fg : p.textSecondary,
                  fontSize: KonataTheme.fontSizeCaption,
                  weight: KonataTheme.weightActive,
                  tabularFigures: true,
                ),
              ),
              const SizedBox(width: 4),
              AnimatedRotation(
                turns: widget.expanded ? 0.5 : 0.0,
                duration: KonataTheme.motionFast,
                child: Icon(
                  Icons.expand_more_rounded,
                  size: 16,
                  color: widget.expanded ? p.accentBadge.fg : p.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 单个 TMDB 候选条目预览与一键采纳行组件。
class _ReviewCandidateRow extends StatelessWidget {
  const _ReviewCandidateRow({
    required this.candidate,
    required this.busy,
    required this.onAccept,
  });

  final ScrapeCandidateSummary candidate;
  final bool busy;
  final VoidCallback onAccept;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final pct = (candidate.score * 100).round().clamp(0, 100);
    final scoreBadge = pct >= 80
        ? p.successBadge
        : pct >= 60
        ? p.accentBadge
        : p.warningBadge;
    final reasonLabels = ReviewReasonLabels.formatAll(candidate.reasons);
    final typeLabel = candidate.mediaType == TmdbMediaType.tv ? '剧集' : '剧场版';

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: p.softFill,
        borderRadius: KonataTheme.borderRadiusControl,
        border: Border.all(color: KonataTheme.subtleOutlineBorder(p)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          ClipRRect(
            borderRadius: KonataTheme.borderRadiusSm,
            child: SizedBox(
              width: 56,
              height: 80,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: p.surface,
                  borderRadius: KonataTheme.borderRadiusSm,
                  border: Border.all(color: p.posterBorder),
                ),
                child: ManagedImage(
                  path: candidate.posterPath,
                  targetWidth: 160,
                  fit: BoxFit.cover,
                  errorWidget: Icon(
                    Icons.movie_outlined,
                    size: 20,
                    color: p.textMuted,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  candidate.year == null
                      ? candidate.title
                      : '${candidate.title}（${candidate.year}）',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: KonataTheme.cardTitleStyle(
                    p,
                    fontSize: KonataTheme.fontSizeBody,
                  ),
                ),
                if (candidate.originalTitle != null &&
                    candidate.originalTitle!.trim().isNotEmpty &&
                    candidate.originalTitle!.trim() !=
                        candidate.title) ...<Widget>[
                  const SizedBox(height: 2),
                  Text(
                    candidate.originalTitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: KonataTheme.captionStyle(
                      p,
                      fontSize: KonataTheme.fontSizeCaptionSm,
                    ),
                  ),
                ],
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: <Widget>[
                    _MetaChip(
                      label: 'TMDB #${candidate.tmdbId}',
                      bg: p.accentBadge.bg,
                      fg: p.accentBadge.fg,
                      border: p.accentBadge.border,
                    ),
                    _MetaChip(
                      label: '匹配度 $pct%',
                      bg: scoreBadge.bg,
                      fg: scoreBadge.fg,
                      border: scoreBadge.border,
                    ),
                    _MetaChip(
                      label: typeLabel,
                      bg: KonataTheme.specNeutralBadgeBg(p),
                      fg: p.textSecondary,
                      border: KonataTheme.specNeutralBadgeBorder(p),
                    ),
                    if (candidate.episodeCount != null &&
                        candidate.episodeCount! > 0)
                      _MetaChip(
                        label: '${candidate.episodeCount} 话',
                        bg: KonataTheme.specNeutralBadgeBg(p),
                        fg: p.textSecondary,
                        border: KonataTheme.specNeutralBadgeBorder(p),
                      ),
                    for (final label in reasonLabels.take(3))
                      _MetaChip(
                        label: label,
                        bg: p.surface,
                        fg: p.textMuted,
                        border: p.hairline,
                      ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          KonataPillButton.primary(
            label: '采纳',
            compact: true,
            onPressed: busy ? null : onAccept,
          ),
        ],
      ),
    );
  }
}

class _MetaChip extends StatelessWidget {
  const _MetaChip({
    required this.label,
    required this.bg,
    required this.fg,
    required this.border,
  });

  final String label;
  final Color bg;
  final Color fg;
  final Color border;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: KonataTheme.borderRadiusChip,
        border: Border.all(color: border),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: KonataTheme.textStyle(
          color: fg,
          fontSize: KonataTheme.fontSizeCaptionXs,
          weight: KonataTheme.weightActive,
          tabularFigures: true,
        ),
      ),
    );
  }
}
