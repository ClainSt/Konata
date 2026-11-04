import 'package:flutter/material.dart';
import '../core/catalog.dart';
import '../core/cover_options.dart';

/// Explicit work metadata and poster editors, separate from file association.
abstract final class WorkEditDialogs {
  static Future<void> metadata(
    BuildContext context,
    Map<String, Object?> work, {
    required Future<void> Function() searchAndBind,
  }) async {
    final title = TextEditingController(text: work['title']?.toString() ?? '');
    final year = TextEditingController(text: work['year']?.toString() ?? '');
    final overview = TextEditingController(
      text: work['overview']?.toString() ?? '',
    );
    var message = '';
    try {
      final result = await showDialog<String>(
        context: context,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, update) => AlertDialog(
            title: const Text('编辑元数据'),
            content: SizedBox(
              width: 540,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: title,
                      decoration: const InputDecoration(labelText: '作品标题'),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: year,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: '年份（可留空）'),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: overview,
                      maxLines: 6,
                      minLines: 3,
                      decoration: const InputDecoration(labelText: '作品简介'),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'TMDB: ${work['tmdb_id'] ?? '未绑定'}   Bangumi: ${work['bangumi_id'] ?? '未绑定'}',
                    ),
                    if (message.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: Text(
                          message,
                          style: const TextStyle(color: Colors.red),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton.icon(
                key: const ValueKey('metadata-search-bind'),
                onPressed: () => Navigator.pop(ctx, 'search'),
                icon: const Icon(Icons.manage_search),
                label: const Text('搜索并绑定作品'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('取消'),
              ),
              FilledButton(
                key: const ValueKey('metadata-save'),
                onPressed: () {
                  final label = title.text.trim();
                  final y = year.text.trim();
                  final parsed = y.isEmpty ? null : int.tryParse(y);
                  if (label.isEmpty ||
                      (y.isNotEmpty &&
                          (parsed == null || parsed < 1888 || parsed > 2100))) {
                    update(() => message = '请输入作品标题和有效年份');
                    return;
                  }
                  Navigator.pop(ctx, 'save');
                },
                child: const Text('保存'),
              ),
            ],
          ),
        ),
      );
      if (result == 'search') {
        if (context.mounted) await searchAndBind();
      } else if (result == 'save') {
        await Catalog.instance.updateWorkMetadata(
          work['id'].toString(),
          title: title.text,
          year: year.text.trim().isEmpty ? null : int.parse(year.text.trim()),
          overview: overview.text,
        );
      }
    } finally {
      title.dispose();
      year.dispose();
      overview.dispose();
    }
  }

  static Future<void> cover(
    BuildContext context,
    Map<String, Object?> work,
  ) async {
    final service = CoverOptionService();
    final candidates = service.fetch(work);
    final savedSource = work['manual_cover_source']?.toString();
    String selected = savedSource == 'tmdb' || savedSource == 'bangumi'
        ? savedSource!
        : '';
    try {
      final action = await showDialog<String>(
        context: context,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, update) => AlertDialog(
            title: const Text('编辑封面'),
            content: SizedBox(
              width: 545,
              child: FutureBuilder<CoverOptions>(
                future: candidates,
                builder: (ctx, snapshot) {
                  if (!snapshot.hasData) {
                    if (snapshot.hasError) return const Text('获取封面来源失败');
                    return const SizedBox(
                      height: 96,
                      child: Center(child: CircularProgressIndicator()),
                    );
                  }
                  final options = snapshot.data!;
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final source in ['tmdb', 'bangumi'])
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: InkWell(
                            key: ValueKey('cover-choice-$source'),
                            onTap: options.forSource(source) == null
                                ? null
                                : () => update(() => selected = source),
                            borderRadius: BorderRadius.circular(8),
                            child: Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: selected == source
                                      ? Theme.of(ctx).colorScheme.primary
                                      : Theme.of(ctx).dividerColor,
                                  width: selected == source ? 2 : 1,
                                ),
                              ),
                              child: Row(
                                children: [
                                  SizedBox(
                                    width: 68,
                                    height: 96,
                                    child: options.forSource(source) == null
                                        ? const Center(
                                            child: Icon(
                                              Icons
                                                  .image_not_supported_outlined,
                                            ),
                                          )
                                        : Image.network(
                                            options.forSource(source)!,
                                            fit: BoxFit.cover,
                                            errorBuilder: (_, _, _) =>
                                                const Icon(
                                                  Icons.broken_image_outlined,
                                                ),
                                          ),
                                  ),
                                  const SizedBox(width: 14),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          source == 'tmdb' ? 'TMDB' : 'Bangumi',
                                          style: Theme.of(
                                            ctx,
                                          ).textTheme.titleMedium,
                                        ),
                                        Text(
                                          options.forSource(source) == null
                                              ? '暂无可用封面，请先绑定对应来源'
                                              : '使用此来源的作品封面',
                                        ),
                                      ],
                                    ),
                                  ),
                                  Icon(
                                    selected == source
                                        ? Icons.radio_button_checked
                                        : Icons.radio_button_unchecked,
                                    color: options.forSource(source) == null
                                        ? Colors.grey
                                        : Theme.of(ctx).colorScheme.primary,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      const Text('手动选择会优先于后续自动刮削；恢复自动将重新使用默认封面来源。'),
                    ],
                  );
                },
              ),
            ),
            actions: [
              TextButton(
                key: const ValueKey('cover-reset'),
                onPressed: () => Navigator.pop(ctx, 'reset'),
                child: const Text('恢复自动'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('取消'),
              ),
              FilledButton(
                key: const ValueKey('cover-save'),
                onPressed: selected.isEmpty
                    ? null
                    : () => Navigator.pop(ctx, 'save'),
                child: const Text('保存'),
              ),
            ],
          ),
        ),
      );
      if (action == 'reset') {
        await Catalog.instance.setManualCover(work['id'].toString());
      } else if (action == 'save') {
        final options = await candidates;
        final url = options.forSource(selected);
        if (url != null) {
          await Catalog.instance.setManualCover(
            work['id'].toString(),
            source: selected,
            url: url,
          );
        }
      }
    } finally {
      service.close();
    }
  }
}
