import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/providers/artwork_provider.dart';
import '../../application/providers/library_providers.dart';
import '../audio/mini_audio_bar.dart';
import '../detail/work_detail_page.dart';
import '../theme/konata_palette.dart';
import '../theme/konata_theme.dart';
import '../widgets/design_system/konata_draggable_scrollbar.dart';
import '../widgets/design_system/konata_page_header.dart';
import '../widgets/design_system/konata_pill_button.dart';
import 'hidden_works_dialog.dart';
import 'poster_card.dart';
import 'review_dialog.dart';

/// 高密度媒体库海报墙主页（透明穿透底 + 同行右侧「待复核」微光胶囊 + 自适应高密度海报网格）。
class LibraryPage extends ConsumerStatefulWidget {
  /// 创建媒体库主页。
  const LibraryPage({super.key});

  @override
  ConsumerState<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends ConsumerState<LibraryPage> {
  final ScrollController _gridCtrl = ScrollController();

  @override
  void dispose() {
    _gridCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final filteredAsync = ref.watch(filteredLibraryItemsProvider);
    final totalCountAsync = ref.watch(worksCountProvider);
    final reviewCount =
        ref.watch(needsReviewItemsProvider).valueOrNull?.length ?? 0;
    final hiddenCount = ref.watch(hiddenWorksProvider).valueOrNull?.length ?? 0;
    final imageLoader = ref.watch(tmdbImageLoaderProvider);
    final bottomClearance = KonataBottomClearanceScope.resolve(context, ref);
    final totalCount = totalCountAsync.valueOrNull ?? 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        KonataPageHeader(
          title: '全部作品',
          badge: totalCount > 0
              ? Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: p.softFill,
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: p.hairline, width: 1),
                  ),
                  child: Text(
                    '$totalCount 部',
                    style: KonataTheme.textStyle(
                      color: p.textSecondary,
                      fontSize: 13,
                      weight: KonataTheme.weightActive,
                    ),
                  ),
                )
              : null,
          actions: [
            if (hiddenCount > 0)
              _HiddenWorksHeaderButton(
                count: hiddenCount,
                onTap: () => showHiddenWorksDialog(context),
              ),
            if (reviewCount > 0)
              _ReviewHeaderPill(
                count: reviewCount,
                onTap: () => showReviewDialog(context),
              ),
          ],
        ),
        Expanded(
          child: filteredAsync.when(
            data: (items) {
              if (items.isEmpty) {
                return _EmptyLibraryState(
                  isSearching: ref
                      .watch(librarySearchQueryProvider)
                      .trim()
                      .isNotEmpty,
                  onGoSources: () {
                    ref.read(selectedNavSectionProvider.notifier).state =
                        KonataNavSection.sources;
                  },
                );
              }
              return LayoutBuilder(
                builder: (context, constraints) {
                  final width = constraints.maxWidth;
                  final columns = (width / 196).floor().clamp(2, 8);
                  return KonataDraggableScrollbar(
                    controller: _gridCtrl,
                    builder: (_, ctrl) => GridView.builder(
                      controller: ctrl,
                      padding: EdgeInsets.fromLTRB(
                        KonataTheme.pageHorizontalPadding,
                        0,
                        KonataTheme.pageHorizontalPadding,
                        28 + bottomClearance,
                      ),
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: columns,
                        mainAxisSpacing: 20,
                        crossAxisSpacing: 16,
                        childAspectRatio: 0.58,
                      ),
                      itemCount: items.length,
                      itemBuilder: (_, index) {
                        final item = items[index];
                        return PosterCard(
                          item: item,
                          imageLoader: imageLoader,
                          onTap: () {
                            Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) =>
                                    WorkDetailPage(workId: item.work.id),
                              ),
                            );
                          },
                        );
                      },
                    ),
                  );
                },
              );
            },
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (err, _) => Center(
              child: Text('加载媒体库失败: $err', style: TextStyle(color: p.danger)),
            ),
          ),
        ),
      ],
    );
  }
}

class _HiddenWorksHeaderButton extends StatefulWidget {
  const _HiddenWorksHeaderButton({required this.count, required this.onTap});

  final int count;
  final VoidCallback onTap;

  @override
  State<_HiddenWorksHeaderButton> createState() =>
      _HiddenWorksHeaderButtonState();
}

class _HiddenWorksHeaderButtonState extends State<_HiddenWorksHeaderButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    if (widget.count <= 0) {
      return const SizedBox.shrink();
    }
    final p = context.palette;
    final tooltip = '已隐藏作品 (${widget.count})';

    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 350),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: SizedBox(
            width: 32,
            height: 32,
            child: Center(
              child: Icon(
                Icons.visibility_off_outlined,
                size: 18,
                color: _hovered ? p.textPrimary : p.textSecondary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ReviewHeaderPill extends StatefulWidget {
  const _ReviewHeaderPill({required this.count, required this.onTap});

  final int count;
  final VoidCallback onTap;

  @override
  State<_ReviewHeaderPill> createState() => _ReviewHeaderPillState();
}

class _ReviewHeaderPillState extends State<_ReviewHeaderPill> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final hasPending = widget.count > 0;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
          decoration: BoxDecoration(
            color: _hovered ? p.surfaceHover : p.surface,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: _hovered ? p.hoverBorder : p.hairline,
              width: 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (hasPending) ...[
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: p.warning,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 6),
              ],
              Text(
                hasPending ? '待复核 · ${widget.count}' : '待复核',
                style: TextStyle(
                  color: hasPending ? p.textPrimary : p.textMuted,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyLibraryState extends StatelessWidget {
  const _EmptyLibraryState({
    required this.isSearching,
    required this.onGoSources,
  });

  final bool isSearching;
  final VoidCallback onGoSources;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isSearching
                ? Icons.search_off_rounded
                : Icons.video_library_outlined,
            size: 46,
            color: p.textMuted,
          ),
          const SizedBox(height: 12),
          Text(
            isSearching ? '没有匹配当前筛选条件的作品' : '媒体库尚未入库任何作品',
            style: TextStyle(
              color: p.textPrimary,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            isSearching
                ? '可尝试按日文原名、压制组或 TMDB ID 检索'
                : '前往「媒体源」添加本地目录、WebDAV 或 SMB 共享并启动扫描',
            style: TextStyle(color: p.textSecondary, fontSize: 12.5),
          ),
          if (!isSearching) ...[
            const SizedBox(height: 18),
            KonataPillButton.primary(
              label: '前往添加媒体源',
              icon: Icons.add_rounded,
              onPressed: onGoSources,
            ),
          ],
        ],
      ),
    );
  }
}
