import 'dart:convert';

import 'package:flutter/material.dart';

import '../core/catalog.dart';
import '../core/library_backup_restorer.dart';
import '../core/library_merge.dart';

Future<LibraryMerge?> reviewLibraryMerge(
  BuildContext context,
  PreparedLibraryBackup backup,
  LibraryBackupRestorer restorer,
) async {
  final local = Catalog.instance.sources;
  final incoming = (backup.data.manifest['tables']['sources'] as List)
      .whereType<Map>()
      .toList();
  final zh = Localizations.localeOf(context).languageCode == 'zh';
  String tr(String cn, String en) => zh ? cn : en;
  final selected = <String, String>{};
  final choose = await showDialog<bool>(
    context: context,
    builder: (dialog) => AlertDialog(
      scrollable: true,
      title: Text(tr('核对媒体源', 'Associate media sources')),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              tr(
                '仅在确认是同一份媒体时选择已有来源。新增来源恢复后需要重新关联。',
                'Select an existing source only after checking it holds the same media. New sources need reassociation.',
              ),
            ),
            for (final source in incoming)
              DropdownButtonFormField<String>(
                isExpanded: true,
                initialValue: '',
                decoration: InputDecoration(labelText: '${source['label']}'),
                items: [
                  DropdownMenuItem(
                    value: '',
                    child: Text(
                      tr('按内部 ID 比对或新增', 'Match stable ID or add source'),
                    ),
                  ),
                  for (final target in local.where(
                    (row) => row['kind'] == source['kind'],
                  ))
                    DropdownMenuItem(
                      value: target['id'] as String,
                      child: Text(
                        target['label'] as String,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (value) {
                  if (value == null || value.isEmpty) {
                    selected.remove(source['id']);
                  } else {
                    selected[source['id'] as String] = value;
                  }
                },
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialog),
          child: Text(tr('取消', 'Cancel')),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialog, true),
          child: Text(tr('生成预览', 'Preview merge')),
        ),
      ],
    ),
  );
  if (choose != true || !context.mounted) return null;
  final preview = await restorer.previewMerge(backup, selected);
  if (!context.mounted) return null;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialog) => AlertDialog(
      scrollable: true,
      title: Text(tr('备份合并预览', 'Library merge preview')),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              tr(
                '新增 ${preview.newRows['works']?.length ?? 0} 部作品 · ${preview.newRows['assets']?.length ?? 0} 个文件',
                'Add ${preview.newRows['works']?.length ?? 0} works and ${preview.newRows['assets']?.length ?? 0} files',
              ),
            ),
            Text(
              tr(
                '${preview.conflicts.length} 条不同记录。保留两边资料，当前库继续采用本地记录。',
                '${preview.conflicts.length} differing records. Both versions are retained and the local record stays active.',
              ),
            ),
            for (final entry in preview.conflicts.take(12))
              Text(
                entry.table == 'progress'
                    ? '${tr("续播位置", "Resume")} · ${entry.local?['position_ms'] ?? "—"} / ${entry.incoming['position_ms']} ms'
                    : entry.table,
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialog),
          child: Text(tr('取消', 'Cancel')),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialog, true),
          child: Text(tr('确认合并', 'Apply merge')),
        ),
      ],
    ),
  );
  return confirmed == true ? preview : null;
}

class MergePositionsPage extends StatefulWidget {
  const MergePositionsPage({super.key});
  @override
  State<MergePositionsPage> createState() => _MergePositionsPageState();
}

class _MergePositionsPageState extends State<MergePositionsPage> {
  final catalog = Catalog.instance;
  late Future<List<Map<String, Object?>>> rows = _load();
  Future<List<Map<String, Object?>>> _load() => catalog.db.query(
    'library_merge_conflicts',
    where: "table_name='progress' AND position_choice=1 AND resolved=0",
    orderBy: 'created_at DESC',
    limit: 200,
  );
  String tr(String cn, String en) =>
      Localizations.localeOf(context).languageCode == 'zh' ? cn : en;

  Future<void> _resolve(Map row, bool incoming) async {
    try {
      await LibraryMerge.resolvePosition(
        catalog.db,
        row['id'] as String,
        useIncoming: incoming,
      );
      await catalog.reload();
      if (mounted) setState(() => rows = _load());
    } catch (_) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              tr('该文件或播放位置已有新记录。', 'The file or resume position has changed.'),
            ),
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(tr('续播位置冲突', 'Resume position conflicts'))),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900),
        child: FutureBuilder(
          future: rows,
          builder: (context, snapshot) {
            if (snapshot.hasError)
              return Center(
                child: Text(tr('无法读取记录', 'Unable to read records')),
              );
            if (!snapshot.hasData)
              return const Center(child: CircularProgressIndicator());
            final data = snapshot.data!;
            if (data.isEmpty)
              return Center(
                child: Text(tr('没有待选择的位置', 'No pending positions')),
              );
            return ListView.builder(
              itemCount: data.length,
              itemBuilder: (_, index) {
                final row = data[index];
                final local = jsonDecode(row['local_json'] as String) as Map;
                final incoming =
                    jsonDecode(row['incoming_json'] as String) as Map;
                final asset = catalog.assets
                    .where((a) => a['id'] == local['asset_id'])
                    .firstOrNull;
                return Card(
                  child: ListTile(
                    title: Text('${asset?['name'] ?? local['asset_id']}'),
                    subtitle: Wrap(
                      spacing: 10,
                      children: [
                        TextButton(
                          onPressed: () => _resolve(row, false),
                          child: Text(
                            '${tr("当前", "Current")} · ${local['position_ms']} ms',
                          ),
                        ),
                        TextButton(
                          onPressed: () => _resolve(row, true),
                          child: Text(
                            '${tr("备份", "Backup")} · ${incoming['position_ms']} ms',
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            );
          },
        ),
      ),
    ),
  );
}
