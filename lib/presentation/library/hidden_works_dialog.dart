import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/providers/artwork_provider.dart';
import '../../application/providers/library_providers.dart';
import '../../application/providers/work_management_provider.dart';
import '../../domain/models/work.dart';
import '../theme/konata_palette.dart';
import '../theme/konata_theme.dart';
import '../widgets/design_system/ellipsis_text_with_tooltip.dart';
import '../widgets/design_system/konata_draggable_scrollbar.dart';
import '../widgets/design_system/konata_glass_dialog.dart';
import '../widgets/design_system/konata_pill_button.dart';
import '../widgets/design_system/konata_toast.dart';
import '../widgets/managed_image.dart';

/// 呼出居中毛玻璃「已隐藏作品」管理弹窗。
Future<void> showHiddenWorksDialog(BuildContext context) {
  return showKonataGlassDialog<void>(
    context: context,
    builder: (_) => const HiddenWorksDialog(),
  );
}

final _hiddenWorkSourcePathsProvider = FutureProvider.autoDispose<Map<String, String>>((
  ref,
) async {
  final works = await ref.watch(hiddenWorksProvider.future);
  if (works.isEmpty) return const <String, String>{};
  final repo = ref.watch(libraryRepositoryProvider);
  final sources = await repo.getMediaSources();
  final sourceById = {for (final s in sources) s.id: s};
  final paths = <String, String>{};
  for (final work in works) {
    final variants = await repo.getVariantsByWork(work.id);
    if (variants.isEmpty) continue;
    final first = variants.first;
    final source = sourceById[first.sourceId];
    final normalized = first.relativePath.replaceAll('\\', '/');
    final slashIdx = normalized.lastIndexOf('/');
    final relDir = slashIdx > 0 ? normalized.substring(0, slashIdx) : normalized;
    paths[work.id] = source != null ? '[${source.label}] $relDir' : relDir;
  }
  return paths;
});

/// 居中毛玻璃「已隐藏作品」管理弹窗：展示已隐藏作品清单并支持一键取消隐藏。
class HiddenWorksDialog extends ConsumerStatefulWidget {
  /// 创建已隐藏作品管理弹窗。
  const HiddenWorksDialog({super.key});

  @override
  ConsumerState<HiddenWorksDialog> createState() => _HiddenWorksDialogState();
}

class _HiddenWorksDialogState extends ConsumerState<HiddenWorksDialog> {
  final ScrollController _scrollCtrl = ScrollController();
  bool _unhiding = false;

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final hiddenAsync = ref.watch(hiddenWorksProvider);
    final pathsAsync = ref.watch(_hiddenWorkSourcePathsProvider);
    final pathMap = pathsAsync.value ?? const <String, String>{};
    final imageLoader = ref.watch(tmdbImageLoaderProvider);
    final size = MediaQuery.sizeOf(context);
    final maxAllowedWidth = math.max(
      320.0,
      size.width - KonataTheme.dialogViewportMargin * 2,
    );
    final targetWidth = (size.width * 0.58).clamp(560.0, 620.0);
    final dialogWidth = math.min(maxAllowedWidth, targetWidth);
    final dialogMaxHeight = math.min(560.0, math.max(260.0, size.height * 0.72));

    return Center(
      child: KonataGlassDialog(
        title: '已隐藏作品',
        width: dialogWidth,
        maxHeight: dialogMaxHeight,
        child: SizedBox(
          width: double.infinity,
          child: hiddenAsync.when(
            loading: () => const SizedBox(
              height: 160,
              child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
            ),
            error: (err, _) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 28),
              child: Center(
                child: Text(
                  '读取已隐藏作品失败: $err',
                  style: TextStyle(color: p.danger, fontSize: KonataTheme.fontSizeBodySm),
                ),
              ),
            ),
            data: (works) {
              if (works.isEmpty) {
                return SizedBox(
                  width: double.infinity,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 34),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.visibility_outlined,
                          size: 36,
                          color: p.textMuted,
                        ),
                        const SizedBox(height: 10),
                        Text(
                          '当前没有隐藏任何作品',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: p.textPrimary,
                            fontSize: KonataTheme.fontSizeBodyMd,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '可在作品详情页右下角齿轮菜单中隐藏指定作品',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: p.textSecondary,
                            fontSize: KonataTheme.fontSizeBodyXs,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }

              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Flexible(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 380),
                      child: KonataDraggableScrollbar(
                        controller: _scrollCtrl,
                        builder: (_, ctrl) => ListView.separated(
                          controller: ctrl,
                          shrinkWrap: true,
                          padding: const EdgeInsets.only(right: 12),
                          itemCount: works.length,
                          separatorBuilder: (_, _) =>
                              Divider(height: 12, color: p.hairline),
                          itemBuilder: (_, index) {
                            final work = works[index];
                            final sourcePath = pathMap[work.id];
                            return _HiddenWorkRow(
                              work: work,
                              sourcePath: sourcePath,
                              imageLoader: imageLoader,
                              onUnhide: () async {
                                if (_unhiding) return;
                                _unhiding = true;
                                final remaining = works.length - 1;
                                try {
                                  await ref
                                      .read(workManagementProvider)
                                      .unhideWork(work.id);
                                  if (context.mounted) {
                                    showKonataToast(
                                      context,
                                      '已取消隐藏：${work.title}',
                                    );
                                    if (remaining <= 0) {
                                      await Navigator.of(context).maybePop();
                                    }
                                  }
                                } finally {
                                  _unhiding = false;
                                }
                              },
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _HiddenWorkRow extends StatelessWidget {
  const _HiddenWorkRow({
    required this.work,
    required this.sourcePath,
    required this.imageLoader,
    required this.onUnhide,
  });

  final Work work;
  final String? sourcePath;
  final ManagedImageLoader imageLoader;
  final VoidCallback onUnhide;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final poster = work.posterPath ?? work.bangumiPosterPath ?? work.posterFallback;
    final titleText =
        '${work.title}${work.year != null ? ' (${work.year})' : ''}';
    final subtitleText = (sourcePath != null && sourcePath!.trim().isNotEmpty)
        ? sourcePath!.trim()
        : (work.originalTitle?.trim().isNotEmpty == true
              ? work.originalTitle!.trim()
              : '已在媒体库主视图中隐藏');

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        ClipRRect(
          borderRadius: KonataTheme.borderRadiusChip,
          child: SizedBox(
            width: 46,
            height: 66,
            child: poster != null && poster.isNotEmpty
                ? ManagedImage(
                    poster,
                    loader: imageLoader,
                    owner: work.id,
                    artwork: ManagedArtwork.poster,
                    decodeWidth: 120,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => _fallbackCover(p),
                  )
                : _fallbackCover(p),
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              EllipsisTextWithTooltip(
                text: titleText,
                maxLines: 1,
                style: TextStyle(
                  color: p.textPrimary,
                  fontSize: KonataTheme.fontSizeBodyMd,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Icon(
                    Icons.folder_outlined,
                    size: 13.5,
                    color: p.textMuted,
                  ),
                  const SizedBox(width: 5),
                  Expanded(
                    child: EllipsisTextWithTooltip(
                      text: subtitleText,
                      maxLines: 1,
                      style: TextStyle(
                        color: p.textSecondary,
                        fontSize: KonataTheme.fontSizeCaption,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        KonataPillButton.secondary(
          label: '取消隐藏',
          compact: true,
          onPressed: onUnhide,
        ),
      ],
    );
  }

  Widget _fallbackCover(KonataPalette p) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: p.softFill,
        border: Border.all(color: p.hairline, width: 1),
      ),
      child: Center(
        child: Icon(
          Icons.movie_outlined,
          size: 18,
          color: p.textMuted,
        ),
      ),
    );
  }
}
