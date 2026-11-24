import 'package:engine_scraping/engine_scraping.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_design_system/konata_design_system.dart';

import '../providers.dart';
import 'delete_work_dialog.dart';
import 'managed_image.dart';

/// 弹出「已隐藏作品」管理弹窗，支持一键恢复上墙、查看详情或彻底移出库。
Future<void> showHiddenWorksDialog(BuildContext context) {
  return showKonataGlassDialog<void>(
    context: context,
    builder: (_) => const _HiddenWorksDialog(),
  );
}

class _HiddenWorksDialog extends ConsumerWidget {
  const _HiddenWorksDialog();

  Future<void> _restoreWork(
    BuildContext context,
    WidgetRef ref,
    Work work,
  ) async {
    await ref
        .read(workManagementControllerProvider)
        .setWorkHidden(work.id, hidden: false, keepHidden: false);
    if (!context.mounted) return;
    showKonataToast(context, '已恢复「${work.title}」在海报墙显示');
  }

  Future<void> _deleteWork(
    BuildContext context,
    WidgetRef ref,
    Work work,
  ) async {
    final confirm = await showDeleteWorkDialog(context, work: work);
    if (!context.mounted || confirm == null) return;
    await ref
        .read(workManagementControllerProvider)
        .deleteWork(
          work.id,
          ignoreFolderOnRescan: confirm.ignoreFolderOnRescan,
        );
    if (!context.mounted) return;
    showKonataToast(context, '已将「${work.title}」移出媒体库');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.palette;
    final libraryController = ref.watch(libraryControllerProvider);
    final navigator = ref.watch(featureLibraryDependenciesProvider).navigator;
    final screen = MediaQuery.sizeOf(context);
    final bodyHeight = (screen.height * 0.62).clamp(240.0, 500.0);

    return ListenableBuilder(
      listenable: libraryController,
      builder: (context, _) {
        final works = libraryController.hiddenWorks;
        return KonataGlassDialog(
          title: '已隐藏作品 (${works.length})',
          width: (screen.width - 28).clamp(300.0, 560.0),
          actions: [
            KonataPillButton.primary(
              label: '完成',
              onPressed: () => Navigator.of(context).pop(),
            ),
          ],
          child: SizedBox(
            height: bodyHeight,
            child: works.isEmpty
                ? Center(
                    child: Text(
                      '当前没有被隐藏的作品',
                      style: TextStyle(fontSize: 13.5, color: p.textMuted),
                    ),
                  )
                : KonataDraggableScrollbar(
                    builder: (context, scrollCtrl) => ListView.separated(
                      controller: scrollCtrl,
                      padding: const EdgeInsets.only(right: 6),
                      itemCount: works.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        final work = works[index];
                        return Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: p.elevatedSurface.withValues(alpha: 0.45),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: p.hairline),
                          ),
                          child: Row(
                            children: [
                              ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: SizedBox(
                                  width: 44,
                                  height: 66,
                                  child: ManagedImage(
                                    path:
                                        work.posterPath ??
                                        work.bangumiPosterPath,
                                    targetWidth: 256,
                                    ownerWorkId: work.id,
                                    subfolder: PhotoSubfolder.posters,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      work.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 13.5,
                                        fontWeight: FontWeight.w600,
                                        color: p.textPrimary,
                                      ),
                                    ),
                                    if (work.year != null) ...[
                                      const SizedBox(height: 2),
                                      Text(
                                        '${work.year}',
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: p.textMuted,
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                              const SizedBox(width: 8),
                              Wrap(
                                spacing: 6,
                                runSpacing: 6,
                                children: [
                                  KonataPillButton.secondary(
                                    label: '恢复',
                                    compact: true,
                                    onPressed: () =>
                                        _restoreWork(context, ref, work),
                                  ),
                                  KonataCapsuleIconButton(
                                    icon: Icons.open_in_new_rounded,
                                    tooltip: '打开详情',
                                    color: p.textSecondary,
                                    size: 16,
                                    padding: const EdgeInsets.all(6),
                                    onTap: () {
                                      Navigator.of(context).pop();
                                      navigator.openWorkDetail(
                                        WorkId.trusted(work.id),
                                      );
                                    },
                                  ),
                                  KonataCapsuleIconButton(
                                    icon: Icons.delete_outline_rounded,
                                    tooltip: '移出库',
                                    color: p.danger,
                                    size: 16,
                                    padding: const EdgeInsets.all(6),
                                    onTap: () =>
                                        _deleteWork(context, ref, work),
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
        );
      },
    );
  }
}
