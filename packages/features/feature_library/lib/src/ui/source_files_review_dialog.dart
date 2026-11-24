import 'package:engine_scraping/engine_scraping.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:konata_design_system/konata_design_system.dart';

import '../data/library_models.dart';
import '../providers.dart';

/// 弹出待复核或问题作品的关联源文件清单只读检查弹窗。
Future<void> showSourceFilesReviewDialog(
  BuildContext context, {
  required Work work,
}) {
  return showKonataGlassDialog<void>(
    context: context,
    builder: (_) => _SourceFilesReviewDialog(work: work),
  );
}

class _SourceFilesReviewDialog extends ConsumerStatefulWidget {
  const _SourceFilesReviewDialog({required this.work});

  final Work work;

  @override
  ConsumerState<_SourceFilesReviewDialog> createState() =>
      _SourceFilesReviewDialogState();
}

class _SourceFilesReviewDialogState
    extends ConsumerState<_SourceFilesReviewDialog> {
  bool _loading = true;
  List<MediaVariant> _variants = const <MediaVariant>[];
  Map<String, MediaSource> _sourcesById = const <String, MediaSource>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final mgmt = ref.read(workManagementControllerProvider);
    final results = await Future.wait<Object>(<Future<Object>>[
      mgmt.getVariantsByWork(widget.work.id),
      mgmt.loadSourcesById(),
    ]);
    if (!mounted) return;
    setState(() {
      _variants = results[0] as List<MediaVariant>;
      _sourcesById = results[1] as Map<String, MediaSource>;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final screen = MediaQuery.sizeOf(context);
    final bodyHeight = (screen.height * 0.58).clamp(240.0, 480.0);

    return KonataGlassDialog(
      title: '源文件列表 · ${widget.work.title}',
      width: (screen.width - 28).clamp(300.0, 620.0),
      actions: [
        KonataPillButton.primary(
          label: '关闭',
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
      child: SizedBox(
        height: bodyHeight,
        child: _loading
            ? const Center(
                child: SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2.2),
                ),
              )
            : _variants.isEmpty
            ? Center(
                child: Text(
                  '暂无关联物理文件记录',
                  style: TextStyle(fontSize: 13.5, color: p.textMuted),
                ),
              )
            : KonataDraggableScrollbar(
                builder: (context, scrollCtrl) => ListView.separated(
                  controller: scrollCtrl,
                  padding: const EdgeInsets.only(right: 6),
                  itemCount: _variants.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final variant = _variants[index];
                    final source = _sourcesById[variant.sourceId];
                    final ext = MediaDisplayFormatter.fileExtensionUpper(
                      variant.fileName,
                    );
                    final sizeStr = MediaDisplayFormatter.formatBytes(
                      variant.fileSize,
                    );
                    return Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: p.elevatedSurface.withValues(alpha: 0.42),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: p.hairline),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            MediaDisplayFormatter.formatWrappableFileName(
                              variant.fileName,
                            ),
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: p.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            variant.relativePath,
                            style: TextStyle(
                              fontSize: 11.5,
                              color: p.textMuted,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              if (source != null)
                                KonataSpecBadge(label: source.label),
                              if (ext.isNotEmpty) KonataSpecBadge(label: ext),
                              if (sizeStr.isNotEmpty)
                                KonataSpecBadge(label: sizeStr),
                              if (variant.resolution != null &&
                                  variant.resolution!.isNotEmpty)
                                KonataSpecBadge(label: variant.resolution!),
                              if (variant.releaseGroup != null &&
                                  variant.releaseGroup!.isNotEmpty)
                                KonataSpecBadge(label: variant.releaseGroup!),
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
  }
}
