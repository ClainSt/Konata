import 'dart:async';

import 'package:engine_scraping/engine_scraping.dart';
import 'package:flutter/widgets.dart';
import 'package:konata_design_system/konata_design_system.dart';

import '../data/series_member_label_resolver.dart';
import 'detail_managed_image.dart';

/// 展示三端自适应系列作品选择器（手机端底部全宽毛玻璃抽屉；桌面/平板端居中宽毛玻璃弹窗）。
Future<void> showSeriesSelectorModal(
  BuildContext context, {
  required SeriesGroup? seriesGroup,
  required List<Work> members,
  required Work activeWork,
  required ManagedImageLoader imageLoader,
  required ValueChanged<String> onSelectWork,
  required bool useBottomSheet,
}) {
  if (members.isEmpty) return Future<void>.value();

  final title = _resolveModalTitle(
    seriesGroup: seriesGroup,
    members: members,
  );

  if (useBottomSheet) {
    final screenH = MediaQuery.sizeOf(context).height;
    final sheetHeight = (screenH * 0.78).clamp(380.0, 660.0);
    return Navigator.of(context, rootNavigator: true).push<void>(
      RawDialogRoute<void>(
        barrierDismissible: true,
        barrierLabel: '关闭系列选择抽屉',
        barrierColor: KonataTheme.scrimBlackMedium,
        transitionDuration: KonataTheme.standardTransition,
        pageBuilder: (dialogCtx, animation, secondaryAnimation) {
          final p = dialogCtx.palette;
          return Align(
            alignment: Alignment.bottomCenter,
            child: KonataFollowFingerSheetSurface(
              surfaceKey: const Key('series_selector_bottom_sheet'),
              height: sheetHeight,
              maxHeight: screenH * 0.86,
              onDismiss: () => Navigator.of(dialogCtx).pop(),
              headerBuilder: (ctx) => Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                child: Row(
                  children: [
                    Icon(
                      Icons.layers_rounded,
                      size: 18,
                      color: p.accent,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: p.textPrimary,
                          fontSize: KonataTheme.fontSizeSubtitle,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _SeriesCountBadge(count: members.length),
                    const SizedBox(width: 8),
                    KonataGlassCloseButton(
                      onPressed: () => Navigator.of(dialogCtx).pop(),
                    ),
                  ],
                ),
              ),
              body: Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                  child: _SeriesSelectorBody(
                    seriesGroup: seriesGroup,
                    members: members,
                    activeWork: activeWork,
                    imageLoader: imageLoader,
                    compactGrid: false,
                    onSelectWork: (id) {
                      Navigator.of(dialogCtx).pop();
                      onSelectWork(id);
                    },
                  ),
                ),
              ),
            ),
          );
        },
        transitionBuilder: (ctx, animation, secondaryAnimation, child) {
          final curved = CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeInCubic,
          );
          return SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 1),
              end: Offset.zero,
            ).animate(curved),
            child: child,
          );
        },
      ),
    );
  }

  return showKonataGlassDialog<void>(
    context: context,
    builder: (dialogCtx) {
      final size = MediaQuery.sizeOf(dialogCtx);
      final dialogWidth = (size.width - 48).clamp(520.0, 760.0);
      final dialogHeight = (size.height - 64).clamp(440.0, 620.0);
      return KonataGlassDialog(
        key: const Key('series_selector_glass_dialog'),
        width: dialogWidth,
        height: dialogHeight,
        maxHeight: dialogHeight,
        title: title,
        inlineHeaderTrailing: true,
        headerTrailing: Padding(
          padding: const EdgeInsets.only(left: 10),
          child: _SeriesCountBadge(count: members.length),
        ),
        onClose: () => Navigator.of(dialogCtx).pop(),
        child: _SeriesSelectorBody(
          seriesGroup: seriesGroup,
          members: members,
          activeWork: activeWork,
          imageLoader: imageLoader,
          compactGrid: true,
          onSelectWork: (id) {
            Navigator.of(dialogCtx).pop();
            onSelectWork(id);
          },
        ),
      );
    },
  );
}

String _resolveModalTitle({
  required SeriesGroup? seriesGroup,
  required List<Work> members,
}) {
  final groupTitle = (seriesGroup?.title ?? '').trim();
  if (groupTitle.isNotEmpty) return groupTitle;
  if (members.isNotEmpty) return '同系列作品';
  return '系列切换';
}

class _SeriesCountBadge extends StatelessWidget {
  const _SeriesCountBadge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: p.accent.withValues(alpha: 0.14),
        borderRadius: KonataTheme.borderRadiusPill,
        border: Border.all(color: p.accent.withValues(alpha: 0.42)),
      ),
      child: Text(
        '$count 部',
        style: TextStyle(
          color: p.accent,
          fontSize: KonataTheme.fontSizeBadge,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _SeriesSelectorBody extends StatefulWidget {
  const _SeriesSelectorBody({
    required this.seriesGroup,
    required this.members,
    required this.activeWork,
    required this.imageLoader,
    required this.compactGrid,
    required this.onSelectWork,
  });

  final SeriesGroup? seriesGroup;
  final List<Work> members;
  final Work activeWork;
  final ManagedImageLoader imageLoader;
  final bool compactGrid;
  final ValueChanged<String> onSelectWork;

  @override
  State<_SeriesSelectorBody> createState() => _SeriesSelectorBodyState();
}

class _SeriesSelectorBodyState extends State<_SeriesSelectorBody> {
  final TextEditingController _searchCtrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();

  SeriesWorkMediaFilter _mediaFilter = SeriesWorkMediaFilter.all;
  String _query = '';

  @override
  void dispose() {
    _searchCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final counts = SeriesMemberLabelResolver.countByFilter(widget.members);
    final filtered = SeriesMemberLabelResolver.filterMembers(
      members: widget.members,
      mediaFilter: _mediaFilter,
      query: _query,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (var i = 0; i < SeriesWorkMediaFilter.values.length; i++) ...[
                if (i > 0) const SizedBox(width: 8),
                _MediaFilterPill(
                  filter: SeriesWorkMediaFilter.values[i],
                  count: counts[SeriesWorkMediaFilter.values[i]] ?? 0,
                  selected: _mediaFilter == SeriesWorkMediaFilter.values[i],
                  onTap: () => setState(
                    () => _mediaFilter = SeriesWorkMediaFilter.values[i],
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 10),
        KonataSoftTextField(
          key: const Key('series_selector_search_field'),
          controller: _searchCtrl,
          dense: true,
          height: 38,
          prefixIcon: Icons.search_rounded,
          hintText: '搜索系列作品标题、原名或年份...',
          onChanged: (value) => setState(() => _query = value),
          suffix: _query.isNotEmpty
              ? GestureDetector(
                  onTap: () => setState(() {
                    _searchCtrl.clear();
                    _query = '';
                  }),
                  child: Icon(
                    Icons.close_rounded,
                    size: 16,
                    color: p.textSecondary,
                  ),
                )
              : null,
        ),
        const SizedBox(height: 12),
        Expanded(
          child: filtered.isEmpty
              ? _buildEmptyState(p)
              : widget.compactGrid
              ? _buildWideGrid(filtered)
              : _buildMobileList(filtered),
        ),
      ],
    );
  }

  Widget _buildEmptyState(KonataPalette p) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.collections_bookmark_outlined,
            size: 30,
            color: p.textSecondary.withValues(alpha: 0.72),
          ),
          const SizedBox(height: 10),
          Text(
            '没有匹配当前筛选条件的系列作品',
            style: KonataTheme.bodyLabelStyle(
              p,
              color: p.textSecondary,
              fontSize: KonataTheme.fontSizeBody,
            ),
          ),
          const SizedBox(height: 10),
          KonataPillButton.ghost(
            label: '重置筛选',
            compact: true,
            onPressed: () => setState(() {
              _mediaFilter = SeriesWorkMediaFilter.all;
              _searchCtrl.clear();
              _query = '';
            }),
          ),
        ],
      ),
    );
  }

  Widget _buildWideGrid(List<Work> items) {
    return KonataDraggableScrollbar(
      controller: _scrollCtrl,
      builder: (_, ctrl) => GridView.builder(
        controller: ctrl,
        itemCount: items.length,
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          mainAxisSpacing: 10,
          crossAxisSpacing: 12,
          mainAxisExtent: 106,
        ),
        itemBuilder: (ctx, index) => _SeriesMemberCard(
          work: items[index],
          members: widget.members,
          seriesGroup: widget.seriesGroup,
          active: items[index].id == widget.activeWork.id,
          orderIndex: index + 1,
          imageLoader: widget.imageLoader,
          onTap: () => widget.onSelectWork(items[index].id),
        ),
      ),
    );
  }

  Widget _buildMobileList(List<Work> items) {
    return ListView.separated(
      controller: _scrollCtrl,
      itemCount: items.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (ctx, index) => _SeriesMemberCard(
        work: items[index],
        members: widget.members,
        seriesGroup: widget.seriesGroup,
        active: items[index].id == widget.activeWork.id,
        orderIndex: index + 1,
        imageLoader: widget.imageLoader,
        onTap: () => widget.onSelectWork(items[index].id),
      ),
    );
  }
}

class _MediaFilterPill extends StatelessWidget {
  const _MediaFilterPill({
    required this.filter,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  final SeriesWorkMediaFilter filter;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        key: ValueKey<String>('series_filter_${filter.name}'),
        onTap: onTap,
        child: AnimatedContainer(
          duration: KonataTheme.motionMicro,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: selected ? p.primaryButtonBg : p.softFill,
            borderRadius: KonataTheme.borderRadiusPill,
            border: Border.all(
              color: selected ? p.primaryButtonBg : p.hoverBorder,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                filter.label,
                style: TextStyle(
                  color: selected ? p.primaryButtonFg : p.textPrimary,
                  fontSize: KonataTheme.fontSizeCaption,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                ),
              ),
              const SizedBox(width: 5),
              Text(
                '$count',
                style: TextStyle(
                  color: selected
                      ? p.primaryButtonFg.withValues(alpha: 0.85)
                      : p.textSecondary,
                  fontSize: KonataTheme.fontSizeBadge,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SeriesMemberCard extends StatelessWidget {
  const _SeriesMemberCard({
    required this.work,
    required this.members,
    required this.seriesGroup,
    required this.active,
    required this.orderIndex,
    required this.imageLoader,
    required this.onTap,
  });

  final Work work;
  final List<Work> members;
  final SeriesGroup? seriesGroup;
  final bool active;
  final int orderIndex;
  final ManagedImageLoader imageLoader;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final posterPath = (work.posterPath ?? work.bangumiPosterPath ?? '').trim();
    final kindBadge = SeriesMemberLabelResolver.mediaKindBadge(work);
    final memberLabel = SeriesMemberLabelResolver.resolveMemberLabel(
      work,
      members: members,
      seriesGroup: seriesGroup,
      fallbackOrder: orderIndex,
    );
    final showExtraLabel =
        memberLabel.isNotEmpty &&
        memberLabel != kindBadge &&
        !memberLabel.endsWith(' · $kindBadge');

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        key: ValueKey<String>('series_member_item_${work.id}'),
        onTap: onTap,
        child: AnimatedContainer(
          duration: KonataTheme.motionMicro,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: active ? p.accent.withValues(alpha: 0.14) : p.softFill,
            borderRadius: KonataTheme.borderRadiusCard,
            border: Border.all(
              color: active ? p.accent.withValues(alpha: 0.55) : p.hairline,
              width: active ? 1.4 : 1.0,
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 56,
                  height: 84,
                  child: posterPath.isNotEmpty
                      ? DetailManagedImage(
                          posterPath,
                          loader: imageLoader,
                          owner: work.id,
                          artwork: ManagedArtwork.poster,
                          decodeWidth: 192,
                        )
                      : ColoredBox(
                          color: p.elevatedSurface,
                          child: Center(
                            child: Icon(
                              Icons.photo_outlined,
                              size: 20,
                              color: p.textSecondary,
                            ),
                          ),
                        ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: active
                                ? p.accent.withValues(alpha: 0.18)
                                : p.elevatedSurface,
                            borderRadius: KonataTheme.borderRadiusChip,
                          ),
                          child: Text(
                            kindBadge,
                            style: TextStyle(
                              color: active ? p.accent : p.textSecondary,
                              fontSize: KonataTheme.fontSizeBadge,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        if (showExtraLabel) ...[
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              memberLabel,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: p.textSecondary,
                                fontSize: KonataTheme.fontSizeBadge,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                        if (work.year != null && work.year! > 0) ...[
                          const SizedBox(width: 6),
                          Text(
                            '${work.year}',
                            style: TextStyle(
                              color: p.textMuted,
                              fontSize: KonataTheme.fontSizeBadge,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                        const Spacer(),
                        if (active)
                          Icon(
                            Icons.check_rounded,
                            size: 16,
                            color: p.accent,
                          ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      work.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: p.textPrimary,
                        fontSize: KonataTheme.fontSizeBody,
                        fontWeight: active ? FontWeight.w700 : FontWeight.w600,
                        height: 1.28,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
