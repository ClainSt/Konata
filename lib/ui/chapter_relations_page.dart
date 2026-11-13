import 'package:flutter/material.dart';

import '../core/catalog.dart';
import '../core/chapter_relations.dart';
import '../core/watch_settings.dart';
import 'watch_page.dart';

class ChapterRelationsPage extends StatefulWidget {
  const ChapterRelationsPage({super.key, required this.work});
  final String work;

  @override
  State<ChapterRelationsPage> createState() => _ChapterRelationsPageState();
}

class _ChapterRelationsPageState extends State<ChapterRelationsPage> {
  final catalog = Catalog.instance;
  late final relations = ChapterRelations(catalog.db);
  late Future<List<Map<String, Object?>>> rows = relations.chapters(
    widget.work,
  );
  bool continuous = false;

  String tr(String cn, String en) =>
      Localizations.localeOf(context).languageCode == 'zh' ? cn : en;

  Future<void> _change(Future<void> Function() action) async {
    try {
      await action();
      if (mounted) setState(() => rows = relations.chapters(widget.work));
    } catch (_) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              tr(
                '文件、范围或资料已变化，请核对后重试。',
                'Check the files, boundaries and current data.',
              ),
            ),
          ),
        );
    }
  }

  Future<void> _edit([Map? chapter, Map? edition]) async {
    final session = await relations.session();
    if (!mounted) return;
    final assets = catalog.assets
        .where((a) => a['work_id'] == widget.work)
        .toList();
    if (assets.isEmpty) return;
    var title = chapter?['title'] as String? ?? '';
    var label = edition?['label'] as String? ?? tr('默认版本', 'Default edition');
    var expected = edition?['expected_parts'] as int? ?? 1;
    final parts = [
      if (edition != null)
        for (final part in ChapterRelations.parts(edition))
          _PartEdit(
            part['asset_id'] as String,
            part['start_ms'] as int?,
            part['end_ms'] as int?,
          ),
    ];
    if (parts.isEmpty)
      parts.add(_PartEdit(assets.first['id'] as String, null, null));
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (dialog, update) => AlertDialog(
          scrollable: true,
          title: Text(tr('章节与文件范围', 'Chapter and file spans')),
          content: SizedBox(
            width: 530,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  initialValue: title,
                  onChanged: (s) => title = s,
                  decoration: InputDecoration(
                    labelText: tr('章节名称', 'Chapter title'),
                  ),
                ),
                TextFormField(
                  initialValue: label,
                  onChanged: (s) => label = s,
                  decoration: InputDecoration(
                    labelText: tr('版本名称', 'Edition label'),
                  ),
                ),
                TextFormField(
                  initialValue: '$expected',
                  keyboardType: TextInputType.number,
                  onChanged: (s) => expected = int.tryParse(s) ?? 0,
                  decoration: InputDecoration(
                    labelText: tr('所需部分数', 'Required parts'),
                  ),
                ),
                for (final entry in parts.asMap().entries)
                  Padding(
                    key: ObjectKey(entry.value),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Column(
                      children: [
                        DropdownButtonFormField<String>(
                          isExpanded: true,
                          initialValue:
                              assets.any((a) => a['id'] == entry.value.asset)
                              ? entry.value.asset
                              : null,
                          items: [
                            for (final asset in assets)
                              DropdownMenuItem(
                                value: asset['id'] as String,
                                child: Text(
                                  asset['name'] as String,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          decoration: InputDecoration(
                            labelText: '${tr("文件", "File")} ${entry.key + 1}',
                          ),
                          onChanged: (value) {
                            if (value != null) entry.value.asset = value;
                          },
                        ),
                        TextFormField(
                          initialValue: entry.value.start,
                          onChanged: (s) => entry.value.start = s,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          decoration: InputDecoration(
                            labelText: tr(
                              '起点秒数（整文件留空）',
                              'Start seconds (blank for whole file)',
                            ),
                          ),
                        ),
                        TextFormField(
                          initialValue: entry.value.end,
                          onChanged: (s) => entry.value.end = s,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          decoration: InputDecoration(
                            labelText: tr(
                              '终点秒数（整文件留空）',
                              'End seconds (blank for whole file)',
                            ),
                          ),
                        ),
                        if (parts.length > 1)
                          TextButton(
                            onPressed: () =>
                                update(() => parts.remove(entry.value)),
                            child: Text(tr('移除此部分', 'Remove this part')),
                          ),
                      ],
                    ),
                  ),
                TextButton(
                  onPressed: parts.length >= 50
                      ? null
                      : () => update(() {
                          parts.add(
                            _PartEdit(assets.first['id'] as String, null, null),
                          );
                        }),
                  child: Text(tr('添加下一个部分', 'Add next part')),
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
              child: Text(tr('保存范围', 'Save spans')),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !mounted) return;
    await relations.saveEdition(
      work: widget.work,
      chapter: chapter?['id'] as String?,
      edition: edition?['id'] as String?,
      title: title,
      label: label,
      expectedParts: expected,
      parts: [for (final part in parts) part.value],
      session: session,
      chapterRevision: chapter?['revision'] as int?,
      editionRevision: edition?['revision'] as int?,
    );
  }

  Future<void> _play(Map edition) async {
    final library = await relations.chapters(widget.work);
    final current = library
        .expand(ChapterRelations.editions)
        .where(
          (row) =>
              row['id'] == edition['id'] &&
              row['revision'] == edition['revision'],
        )
        .firstOrNull;
    if (!mounted || current == null || !ChapterRelations.playable(current))
      return;
    final parts = ChapterRelations.parts(current);
    final percent = WatchSettings.instance.completionPercent;
    final pending = parts.indexWhere(
      (part) => !ChapterRelations.partWatched(part, percent),
    );
    var index = pending < 0 ? 0 : pending;
    while (mounted && index < parts.length) {
      final part = parts[index];
      final asset = catalog.assets
          .where((a) => a['id'] == part['asset_id'])
          .firstOrNull;
      if (asset == null) break;
      var end = part['end_ms'] as int?;
      var next = index + 1;
      // Adjacent spans in this edition keep a single native media session.
      while (continuous &&
          end != null &&
          next < parts.length &&
          parts[next]['asset_id'] == part['asset_id'] &&
          parts[next]['start_ms'] == end) {
        end = parts[next]['end_ms'] as int?;
        next++;
      }
      if (continuous && next == parts.length && end != null) {
        // A unique confirmed neighbor in the same file needs no second open.
        final neighbors = [
          for (final chapter in library)
            if (chapter['id'] != current['chapter_id'])
              if (ChapterRelations.editions(chapter).singleOrNull
                  case final neighbor?)
                if (ChapterRelations.playable(neighbor))
                  if (ChapterRelations.parts(neighbor).singleOrNull
                      case final span?)
                    if (span['asset_id'] == part['asset_id'] &&
                        span['end_ms'] != null)
                      span,
        ];
        while (end != null) {
          final candidates = neighbors.where((span) => span['start_ms'] == end);
          final neighbor = candidates.singleOrNull;
          if (neighbor == null) break;
          neighbors.remove(neighbor);
          end = neighbor['end_ms'] as int?;
        }
      }
      final result = await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          builder: (_) => WatchPage(
            asset: asset,
            chapterStartMs: part['start_ms'] == null
                ? null
                : ChapterRelations.startPosition(part),
            chapterFloorMs: part['start_ms'] as int?,
            chapterEndMs: end,
            returnOnCompletion: continuous && next < parts.length,
          ),
        ),
      );
      if (!continuous || result != true) break;
      index = next;
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(tr('章节与版本', 'Chapters and editions')),
      actions: [
        IconButton(
          onPressed: () => _change(() => _edit()),
          tooltip: tr('新增章节', 'Add chapter'),
          icon: const Icon(Icons.add),
        ),
      ],
    ),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 980),
        child: FutureBuilder(
          future: rows,
          builder: (context, snapshot) {
            if (snapshot.hasError)
              return Center(
                child: Text(tr('无法读取章节', 'Unable to load chapters')),
              );
            if (!snapshot.hasData)
              return const Center(child: CircularProgressIndicator());
            final data = snapshot.data!;
            final combined = <String, List<Map<String, Object?>>>{};
            final standalone = <Map<String, Object?>>[];
            for (final chapter in data) {
              final edition = ChapterRelations.editions(chapter).singleOrNull;
              final part = edition == null
                  ? null
                  : ChapterRelations.parts(edition).singleOrNull;
              if (part != null && part['start_ms'] == null) {
                (combined[part['asset_id'] as String] ??= []).add(chapter);
              } else {
                standalone.add(chapter);
              }
            }
            final groups = combined.values.toList();
            final percent = WatchSettings.instance.completionPercent;
            return ListView.builder(
              padding: const EdgeInsets.all(10),
              itemCount: 1 + groups.length + standalone.length,
              itemBuilder: (context, index) {
                if (index == 0)
                  return SwitchListTile(
                    value: continuous,
                    onChanged: (value) => setState(() => continuous = value),
                    title: Text(
                      tr('连续播放版本的组成部分', 'Play edition parts continuously'),
                    ),
                  );
                final chapters = index <= groups.length
                    ? groups[index - 1]
                    : [standalone[index - groups.length - 1]];
                return Card(
                  child: ExpansionTile(
                    title: Text(
                      chapters.map((row) => row['title']).join(' ／ '),
                    ),
                    subtitle: Text(
                      chapters.length > 1
                          ? tr(
                              '合并文件 · 整文件播放',
                              'Combined file · play whole file',
                            )
                          : ChapterRelations.completed(chapters.single, percent)
                          ? tr('已看', 'Watched')
                          : tr('待看', 'Unwatched'),
                    ),
                    children: [
                      for (final chapter in chapters) ...[
                        for (final edition in ChapterRelations.editions(
                          chapter,
                        ))
                          ListTile(
                            enabled: ChapterRelations.playable(edition),
                            title: Text(edition['label'] as String),
                            subtitle: Text(
                              ChapterRelations.parts(edition)
                                  .map(
                                    (part) =>
                                        '${part["name"] ?? tr("缺失文件", "Missing file")}${ChapterRelations.partWatched(part, percent) ? " ✓" : ""}',
                                  )
                                  .join('\n'),
                            ),
                            onTap: () => _change(() => _play(edition)),
                            trailing: IconButton(
                              onPressed: () =>
                                  _change(() => _edit(chapter, edition)),
                              icon: const Icon(Icons.edit),
                              tooltip: tr('编辑版本', 'Edit edition'),
                            ),
                          ),
                        Wrap(
                          children: [
                            if (ChapterRelations.preferredEdition(chapter)
                                case final preferred?)
                              TextButton(
                                onPressed: () =>
                                    _change(() => _play(preferred)),
                                child: Text(tr('继续观看', 'Continue watching')),
                              ),
                            TextButton(
                              onPressed: () => _change(() => _edit(chapter)),
                              child: Text(tr('新增版本', 'Add edition')),
                            ),
                            PopupMenuButton<int>(
                              onSelected: (value) => _change(
                                () async => relations.mark(
                                  chapter['id'] as String,
                                  chapter['revision'] as int,
                                  value < 0 ? null : value == 1,
                                  await relations.session(),
                                ),
                              ),
                              itemBuilder: (_) => [
                                PopupMenuItem(
                                  value: 1,
                                  child: Text(tr('标为已看', 'Mark watched')),
                                ),
                                PopupMenuItem(
                                  value: 0,
                                  child: Text(tr('标为未看', 'Mark unwatched')),
                                ),
                                PopupMenuItem(
                                  value: -1,
                                  child: Text(
                                    tr('按实际观看区间计算', 'Use viewing evidence'),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ],
                    ],
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

class _PartEdit {
  _PartEdit(this.asset, int? begin, int? finish)
    : start = begin == null ? '' : '${begin / 1000}',
      end = finish == null ? '' : '${finish / 1000}';
  String asset, start, end;
  int? _milliseconds(String text) {
    if (text.trim().isEmpty) return null;
    final seconds = double.tryParse(text);
    if (seconds == null ||
        !seconds.isFinite ||
        seconds < 0 ||
        seconds > 10000000) {
      throw const FormatException('Invalid playback time');
    }
    return (seconds * 1000).round();
  }

  ChapterPart get value =>
      (asset: asset, start: _milliseconds(start), end: _milliseconds(end));
}
