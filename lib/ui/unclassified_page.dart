import 'package:flutter/material.dart';
import '../core/catalog.dart';
import '../l10n/strings.dart';

/// File-level review uses the same catalog relations as normal scanning.
/// It never opens a media source or downloads a video.
class UnclassifiedPage extends StatefulWidget {
  const UnclassifiedPage({super.key});
  @override
  State<UnclassifiedPage> createState() => _UnclassifiedPageState();
}

class _UnclassifiedPageState extends State<UnclassifiedPage> {
  final selected = <String>{};
  final query = TextEditingController();
  String? sourceId;
  bool busy = false;
  @override
  void dispose() {
    query.dispose();
    super.dispose();
  }

  Future<void> assign() async {
    final catalog = Catalog.instance;
    query.clear();
    final choice = await showDialog<({String? id, String? title})>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) {
          final titles = catalog.works
              .where(
                (w) =>
                    w['id'].toString().startsWith('work:$sourceId:') &&
                    w['title'].toString().toLowerCase().contains(
                      query.text.trim().toLowerCase(),
                    ),
              )
              .toList();
          return AlertDialog(
            title: Text(context.l10n.assignToWork),
            content: SizedBox(
              width: 520,
              height: MediaQuery.sizeOf(context).height * .55,
              child: Column(
                children: [
                  TextField(
                    controller: query,
                    onChanged: (_) => update(() {}),
                    decoration: InputDecoration(
                      labelText: context.l10n.workName,
                    ),
                  ),
                  if (query.text.trim().isNotEmpty)
                    TextButton(
                      onPressed: () => Navigator.pop(context, (
                        id: null,
                        title: query.text.trim(),
                      )),
                      child: Text(context.l10n.createClassification),
                    ),
                  Expanded(
                    child: ListView.builder(
                      itemCount: titles.length,
                      itemBuilder: (context, index) => ListTile(
                        title: Text(titles[index]['title'].toString()),
                        subtitle: Text('${titles[index]['year'] ?? ''}'),
                        onTap: () => Navigator.pop(context, (
                          id: titles[index]['id'].toString(),
                          title: null,
                        )),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
    if (choice == null || !mounted) return;
    setState(() => busy = true);
    try {
      await catalog.classifyManually(
        selected.toSet(),
        targetWorkId: choice.id,
        title: choice.title,
      );
      if (mounted) {
        setState(() {
          selected.clear();
          sourceId = null;
        });
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(context.l10n.mappingFailed)));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Catalog.instance,
    builder: (context, _) {
      final catalog = Catalog.instance;
      final files = catalog.unclassifiedAssets;
      return Scaffold(
        appBar: AppBar(title: Text(context.l10n.unclassified)),
        body: Column(
          children: [
            if (busy) const LinearProgressIndicator(),
            Expanded(
              child: ListView.builder(
                itemCount: files.length + 1,
                itemBuilder: (context, index) {
                  if (index == 0) {
                    return Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(context.l10n.classificationHint),
                    );
                  }
                  final file = files[index - 1];
                  final id = file['id'].toString();
                  return CheckboxListTile(
                    key: ValueKey('pending-file-$id'),
                    value: selected.contains(id),
                    title: Text(file['name'].toString()),
                    subtitle: Text(file['relative_path'].toString()),
                    onChanged:
                        busy ||
                            catalog.scanning ||
                            sourceId != null && sourceId != file['source_id']
                        ? null
                        : (value) {
                            setState(() {
                              if (value == true) {
                                selected.add(id);
                                sourceId = file['source_id'].toString();
                              } else {
                                selected.remove(id);
                                if (selected.isEmpty) sourceId = null;
                              }
                            });
                          },
                  );
                },
              ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  alignment: WrapAlignment.center,
                  children: [
                    TextButton(
                      onPressed: busy || catalog.scanning || files.isEmpty
                          ? null
                          : () => setState(() {
                              sourceId ??= files.first['source_id'].toString();
                              selected.addAll(
                                files
                                    .where((f) => f['source_id'] == sourceId)
                                    .map((f) => f['id'].toString()),
                              );
                            }),
                      child: Text(context.l10n.selectSourceFiles),
                    ),
                    FilledButton(
                      onPressed: busy || catalog.scanning || selected.isEmpty
                          ? null
                          : assign,
                      child: Text(
                        '${context.l10n.assignToWork} (${selected.length})',
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
}
