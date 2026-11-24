import 'dart:async';

import 'package:engine_scraping/engine_scraping.dart';
import 'package:flutter/widgets.dart';
import 'package:konata_design_system/konata_design_system.dart';

import '../data/media_display_formatter.dart';
import '../state/detail_supplementary_view_data.dart';
import '../state/work_detail_controller.dart';
import 'manual_match_dialog.dart';
import 'work_manual_edit_dialog.dart';

/// 作品源路径与包含文件清单只读复核弹窗（帮助定位误合并或错配文件）。
class SourceFilesReviewDialog extends StatefulWidget {
  /// 创建源文件清单复核弹窗。
  const SourceFilesReviewDialog({
    super.key,
    required this.controller,
    required this.bundle,
    required this.imageLoader,
  });

  /// 详情页状态控制器。
  final WorkDetailController controller;

  /// 当前作品详情聚合包。
  final WorkDetailBundle bundle;

  /// 受管图片加载器。
  final ManagedImageLoader imageLoader;

  @override
  State<SourceFilesReviewDialog> createState() =>
      _SourceFilesReviewDialogState();
}

class _SourceFilesReviewDialogState extends State<SourceFilesReviewDialog> {
  final TextEditingController _searchCtrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();
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
    final bundle = widget.bundle;
    final epById = <String, Episode>{
      for (final e in bundle.episodes) e.id: e,
    };
    final q = _query.trim().toLowerCase();
    final filtered = bundle.variants
        .where((v) {
          if (q.isEmpty) return true;
          return v.fileName.toLowerCase().contains(q) ||
              v.relativePath.toLowerCase().contains(q);
        })
        .toList(growable: false);

    return KonataGlassDialog(
      width: 640,
      maxHeight: 580,
      title: '源文件清单 (${bundle.variants.length}) · ${bundle.work.title}',
      onClose: () => Navigator.of(context).pop(),
      actions: [
        KonataPillButton.secondary(
          label: '手动精确匹配 / 拆分文件',
          icon: Icons.manage_search_rounded,
          compact: true,
          onPressed: () {
            Navigator.of(context).pop();
            unawaited(
              showKonataGlassDialog<bool>(
                context: context,
                barrierDismissible: false,
                builder: (_) => ManualMatchDialog(
                  controller: widget.controller,
                  bundle: bundle,
                  imageLoader: widget.imageLoader,
                ),
              ),
            );
          },
        ),
        KonataPillButton.secondary(
          label: '进入编辑与文件映射',
          icon: Icons.edit_outlined,
          compact: true,
          onPressed: () {
            Navigator.of(context).pop();
            unawaited(
              showKonataGlassDialog<bool>(
                context: context,
                barrierDismissible: false,
                builder: (_) => WorkManualEditDialog(
                  controller: widget.controller,
                  bundle: bundle,
                  imageLoader: widget.imageLoader,
                  initialSection: WorkManualEditSection.mappings,
                ),
              ),
            );
          },
        ),
        KonataPillButton.primary(
          label: '关闭',
          compact: true,
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          KonataSoftTextField(
            controller: _searchCtrl,
            dense: true,
            prefixIcon: Icons.search_rounded,
            hintText: '搜索文件名或目录...',
            onChanged: (v) => setState(() => _query = v),
          ),
          const SizedBox(height: 10),
          Expanded(
            child: filtered.isEmpty
                ? Center(
                    child: Text(
                      '暂无匹配的媒体文件',
                      style: KonataTheme.bodyLabelStyle(
                        p,
                        color: p.textSecondary,
                      ),
                    ),
                  )
                : KonataDraggableScrollbar(
                    controller: _scrollCtrl,
                    builder: (_, ctrl) => ListView.separated(
                      controller: ctrl,
                      itemCount: filtered.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 6),
                      itemBuilder: (_, index) {
                        final variant = filtered[index];
                        final source = bundle.sourcesById[variant.sourceId];
                        final ep = variant.episodeId != null
                            ? epById[variant.episodeId]
                            : null;
                        final kindLabel = switch (variant.assetKind) {
                          AssetKind.cdAlbum => '音乐 CD',
                          AssetKind.scanGallery => '扫图画册',
                          AssetKind.video =>
                            ep?.category == EpisodeCategory.extra
                                ? '特典视频'
                                : '正片剧集',
                        };
                        final sizeText = variant.fileSize > 0
                            ? MediaDisplayFormatter.formatBytes(
                                variant.fileSize,
                              )
                            : '';

                        return KonataSurfaceCard(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 9,
                          ),
                          child: Row(
                            children: [
                              KonataSpecBadge(label: kindLabel),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      variant.fileName,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: KonataTheme.bodyLabelStyle(
                                        p,
                                        fontSize: KonataTheme.fontSizeCaption,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    SelectableText(
                                      variant.relativePath,
                                      style: KonataTheme.captionStyle(p)
                                          .copyWith(
                                            color: p.textMuted,
                                            fontSize:
                                                KonataTheme.fontSizeCaptionXs,
                                          ),
                                    ),
                                  ],
                                ),
                              ),
                              if (source != null) ...[
                                const SizedBox(width: 8),
                                KonataSpecBadge(
                                  label:
                                      MediaDisplayFormatter.formatSourceKindShort(
                                        source.kind,
                                      ),
                                ),
                              ],
                              if (sizeText.isNotEmpty) ...[
                                const SizedBox(width: 6),
                                KonataSpecBadge(label: sizeText),
                              ],
                            ],
                          ),
                        );
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

/// 打开作品源文件只读复核弹窗。
Future<void> showSourceFilesReviewDialog({
  required BuildContext context,
  required WorkDetailController controller,
  required WorkDetailBundle bundle,
  required ManagedImageLoader imageLoader,
}) {
  return showKonataGlassDialog<void>(
    context: context,
    builder: (_) => SourceFilesReviewDialog(
      controller: controller,
      bundle: bundle,
      imageLoader: imageLoader,
    ),
  );
}
