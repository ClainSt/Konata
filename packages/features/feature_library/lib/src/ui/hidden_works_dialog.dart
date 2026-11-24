import 'package:engine_scraping/engine_scraping.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:konata_design_system/konata_design_system.dart';

import '../data/library_models.dart';
import '../providers.dart';
import 'managed_image.dart';

/// 打开已隐藏作品管理弹窗（取消隐藏全部后自动关闭）。
Future<void> showHiddenWorksDialog(BuildContext context) {
  return showKonataGlassDialog<void>(
    context: context,
    builder: (_) => const _HiddenWorksDialog(),
  );
}

class _HiddenWorksDialog extends ConsumerStatefulWidget {
  const _HiddenWorksDialog();

  @override
  ConsumerState<_HiddenWorksDialog> createState() => _HiddenWorksDialogState();
}

class _HiddenWorksDialogState extends ConsumerState<_HiddenWorksDialog> {
  final ScrollController _scrollController = ScrollController();
  final Map<String, String> _folderLabelByWorkId = <String, String>{};
  final Set<String> _restoringIds = <String>{};
  bool _loadingFolders = false;
  int _lastWorkCount = -1;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _ensureFolderLabels(List<Work> works) async {
    if (_loadingFolders || works.length == _lastWorkCount) return;
    _lastWorkCount = works.length;
    final missing = works
        .where((w) => !_folderLabelByWorkId.containsKey(w.id))
        .toList(growable: false);
    if (missing.isEmpty) return;
    _loadingFolders = true;
    try {
      final mgmt = ref.read(workManagementControllerProvider);
      final sourcesById = await mgmt.loadSourcesById();
      final next = <String, String>{};
      for (final w in missing) {
        final variants = await mgmt.getVariantsByWork(w.id);
        next[w.id] = MediaDisplayFormatter.summarizeWorkFolderLabel(
          variants,
          sourcesById: sourcesById,
        );
      }
      if (!mounted) return;
      setState(() => _folderLabelByWorkId.addAll(next));
    } catch (_) {
    } finally {
      _loadingFolders = false;
    }
  }

  Future<void> _restoreWork(Work work) async {
    if (_restoringIds.contains(work.id)) return;
    setState(() => _restoringIds.add(work.id));
    final mgmt = ref.read(workManagementControllerProvider);
    final library = ref.read(libraryControllerProvider);
    try {
      await mgmt.setWorkHidden(work.id, hidden: false);
      await library.reload();
      if (!mounted) return;
      showKonataToast(context, '已恢复展示「${work.title}」');
      if (library.hiddenWorks.isEmpty) {
        Navigator.of(context).pop();
      }
    } catch (err) {
      if (!mounted) return;
      showKonataToast(context, '取消隐藏失败：$err', isError: true);
    } finally {
      if (mounted) {
        setState(() => _restoringIds.remove(work.id));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final controller = ref.watch(libraryControllerProvider);
    final dialogMaxHeight = (MediaQuery.sizeOf(context).height * 0.72).clamp(
      260.0,
      560.0,
    );

    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final hidden = controller.hiddenWorks;
        if (hidden.isNotEmpty) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _ensureFolderLabels(hidden);
          });
        }

        return KonataGlassDialog(
          width: 600,
          maxHeight: dialogMaxHeight,
          title: '已隐藏作品',
          headerTrailing: hidden.isEmpty
              ? null
              : Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 9,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: p.softFill,
                    borderRadius: KonataTheme.borderRadiusPill,
                    border: Border.all(color: p.hairline),
                  ),
                  child: Text(
                    '${hidden.length} 部',
                    style: KonataTheme.textStyle(
                      color: p.textSecondary,
                      fontSize: KonataTheme.fontSizeCaptionSm,
                      weight: KonataTheme.weightActive,
                      tabularFigures: true,
                    ),
                  ),
                ),
          onClose: () => Navigator.of(context).pop(),
          actions: <Widget>[
            KonataPillButton.secondary(
              label: '关闭',
              onPressed: () => Navigator.of(context).pop(),
            ),
          ],
          child: hidden.isEmpty
              ? SingleChildScrollView(
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 36),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Icon(
                            Icons.visibility_outlined,
                            size: 38,
                            color: p.textMuted,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            '当前没有隐藏任何作品',
                            style: KonataTheme.cardTitleStyle(
                              p,
                              fontSize: KonataTheme.fontSizeBodyMd,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            '可在作品详情页右下角齿轮菜单中隐藏指定作品',
                            textAlign: TextAlign.center,
                            style: KonataTheme.captionStyle(p),
                          ),
                        ],
                      ),
                    ),
                  ),
                )
              : KonataDraggableScrollbar(
                  controller: _scrollController,
                  builder: (context, sc) => ListView.separated(
                    controller: sc,
                    shrinkWrap: true,
                    padding: const EdgeInsets.only(right: 12),
                    itemCount: hidden.length,
                    separatorBuilder: (_, _) => Container(
                      height: 1,
                      margin: const EdgeInsets.symmetric(vertical: 4),
                      color: p.hairline,
                    ),
                    itemBuilder: (context, index) {
                      final work = hidden[index];
                      final folderLabel =
                          _folderLabelByWorkId[work.id] ?? '正在读取目录…';
                      final restoring = _restoringIds.contains(work.id);
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Row(
                          children: <Widget>[
                            ClipRRect(
                              borderRadius: KonataTheme.borderRadiusChipSm,
                              child: SizedBox(
                                width: 46,
                                height: 66,
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    color: p.surface,
                                    borderRadius:
                                        KonataTheme.borderRadiusChipSm,
                                    border: Border.all(color: p.posterBorder),
                                  ),
                                  child: ManagedImage(
                                    path: work.posterPath,
                                    ownerWorkId: work.id,
                                    targetWidth: 120,
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
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: <Widget>[
                                  Text(
                                    work.year == null
                                        ? work.title
                                        : '${work.title}（${work.year}）',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: KonataTheme.cardTitleStyle(
                                      p,
                                      fontSize: KonataTheme.fontSizeBodyMd,
                                    ),
                                  ),
                                  const SizedBox(height: 5),
                                  Row(
                                    children: <Widget>[
                                      Icon(
                                        Icons.folder_outlined,
                                        size: 13,
                                        color: p.textMuted,
                                      ),
                                      const SizedBox(width: 5),
                                      Expanded(
                                        child: Text(
                                          folderLabel,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: KonataTheme.captionStyle(
                                            p,
                                            fontSize:
                                                KonataTheme.fontSizeCaptionSm,
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
                              label: restoring ? '恢复中…' : '取消隐藏',
                              icon: Icons.visibility_outlined,
                              compact: true,
                              onPressed: restoring
                                  ? null
                                  : () => _restoreWork(work),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
        );
      },
    );
  }
}
