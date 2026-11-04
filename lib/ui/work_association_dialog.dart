import 'package:flutter/material.dart';
import '../core/catalog.dart';

/// Lightweight CCPlayer port of NipaPlay Personal's association-management
/// dialog: edit file category, episode number and owning work, with undo.
class WorkAssociationDialog extends StatefulWidget {
  const WorkAssociationDialog({
    super.key,
    required this.work,
    required this.onSearchBind,
  });
  final Map<String, Object?> work;
  final Future<void> Function() onSearchBind;
  @override
  State<WorkAssociationDialog> createState() => _WorkAssociationDialogState();
}

class _WorkAssociationDialogState extends State<WorkAssociationDialog> {
  bool allFiles = false;
  Set<String> locked = {};
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final found = await Catalog.instance.lockedAssetIds();
    if (mounted) setState(() => locked = found);
  }

  void _notice(String text) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }
  }

  Future<void> _edit(
    Map<String, Object?> asset,
    List<Map<String, Object?>> choices,
  ) async {
    var category = asset['category'] == 'extra' ? 'extra' : 'main';
    var workId = asset['work_id'].toString();
    final episode = TextEditingController(
      text: asset['episode']?.toString() ?? '',
    );
    try {
      final save = await showDialog<bool>(
        context: context,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, update) => AlertDialog(
            title: const Text('修改文件归属'),
            content: SizedBox(
              width: 475,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      asset['name']?.toString() ?? '',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 14),
                    DropdownButtonFormField<String>(
                      initialValue: category,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: '内容分类'),
                      items: const [
                        DropdownMenuItem(value: 'main', child: Text('正片')),
                        DropdownMenuItem(value: 'extra', child: Text('特典')),
                      ],
                      onChanged: (v) {
                        if (v != null) update(() => category = v);
                      },
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      initialValue: choices.any((w) => w['id'] == workId)
                          ? workId
                          : choices.first['id'].toString(),
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: '所属作品'),
                      items: [
                        for (final work in choices)
                          DropdownMenuItem(
                            value: work['id'].toString(),
                            child: Text(
                              work['title']?.toString() ?? '',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: (v) {
                        if (v != null) update(() => workId = v);
                      },
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: episode,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: '集数（可留空）'),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      '保存后锁定人工关系；后续扫描不会覆盖。可以撤销最后一次修改。',
                      style: TextStyle(fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('保存并锁定'),
              ),
            ],
          ),
        ),
      );
      if (save != true) return;
      final raw = episode.text.trim();
      final number = raw.isEmpty ? null : int.tryParse(raw);
      if (raw.isNotEmpty && number == null) {
        _notice('请输入有效的集数');
        return;
      }
      await Catalog.instance.lockAssetRelation(
        asset['id'].toString(),
        workId: workId,
        category: category,
        episode: number,
      );
      await _load();
      _notice('文件归属已保存并锁定');
    } catch (e) {
      _notice('保存失败：$e');
    } finally {
      episode.dispose();
    }
  }

  Future<void> _undo(Map<String, Object?> asset) async {
    final done = await Catalog.instance.undoAssetRelation(
      asset['id'].toString(),
    );
    await _load();
    _notice(done ? '已撤销最近一次文件关系修改' : '没有可撤销的修改');
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Catalog.instance,
    builder: (ctx, _) {
      final cat = Catalog.instance;
      final currentAssets = cat.forWork(widget.work['id'].toString());
      final workId = widget.work['id'].toString();
      final sep = workId.indexOf(':', 5);
      final sourceId = workId.startsWith('work:') && sep > 5
          ? workId.substring(5, sep)
          : null;
      final choices = cat.works
          .where(
            (work) =>
                sourceId != null &&
                work['id'].toString().startsWith('work:$sourceId:'),
          )
          .toList();
      final assets = allFiles && sourceId != null
          ? cat.assets.where((a) => a['source_id'] == sourceId).toList()
          : currentAssets;
      return AlertDialog(
        title: Text(
          '关联管理 · ${widget.work['title']}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        content: SizedBox(
          width: 760,
          height: 520,
          child: Column(
            children: [
              Wrap(
                spacing: 10,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  OutlinedButton.icon(
                    onPressed: () async {
                      Navigator.pop(context);
                      await widget.onSearchBind();
                    },
                    icon: const Icon(Icons.manage_search),
                    label: const Text('搜索并绑定元数据'),
                  ),
                  FilterChip(
                    label: const Text('显示同源全部文件'),
                    selected: allFiles,
                    onSelected: (value) => setState(() => allFiles = value),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Expanded(
                child: assets.isEmpty
                    ? const Center(child: Text('暂无相关文件'))
                    : ListView.builder(
                        itemCount: assets.length,
                        itemBuilder: (ctx, i) {
                          final asset = assets[i];
                          final manual = locked.contains(
                            asset['id']?.toString(),
                          );
                          final category = asset['category'] == 'extra'
                              ? '特典'
                              : '正片';
                          return ListTile(
                            leading: Icon(
                              manual
                                  ? Icons.lock_outline
                                  : Icons.movie_outlined,
                            ),
                            title: Text(
                              asset['name']?.toString() ?? '',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              asset['relative_path']?.toString() ?? '',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: Wrap(
                              spacing: 4,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                Text(
                                  category +
                                      (asset['episode'] == null
                                          ? ''
                                          : ' · ${asset['episode']}'),
                                ),
                                IconButton(
                                  tooltip: '修正归属/集数',
                                  icon: const Icon(Icons.edit_outlined),
                                  onPressed: choices.isEmpty
                                      ? null
                                      : () => _edit(asset, choices),
                                ),
                                IconButton(
                                  tooltip: '撤销上次修改',
                                  icon: const Icon(Icons.undo),
                                  onPressed: manual ? () => _undo(asset) : null,
                                ),
                              ],
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      );
    },
  );
}
