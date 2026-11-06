import '../l10n/strings.dart';
import 'uniform_action_bar.dart';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import '../core/image_store.dart';
import '../core/debug_log.dart';
import '../core/bangumi_links.dart';
import 'managed_image.dart';
import 'poster_crop_page.dart';
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
    final links = TextEditingController(
      text: BangumiLinks.ids(work).join(', '),
    );
    var message = '';
    try {
      final route = DialogRoute<String>(
        context: context,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, update) => AlertDialog(
            title: Text(ctx.l10n.editMetadata),
            content: SizedBox(
              width: 540,
              child: SingleChildScrollView(
                padding: const EdgeInsets.only(top: 12, bottom: 4),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: title,
                      decoration: InputDecoration(
                        labelText: ctx.l10n.workTitle,
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: year,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                        labelText: ctx.l10n.year,
                        helperText: ctx.l10n.optional,
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: overview,
                      maxLines: 6,
                      minLines: 3,
                      decoration: InputDecoration(labelText: ctx.l10n.synopsis),
                    ),
                    const SizedBox(height: 10),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          Text(
                            'TMDB: ${work['tmdb_id'] ?? ctx.l10n.notLinked}',
                          ),
                          const SizedBox(width: 16),
                          Text(
                            'Bangumi: ${work['bangumi_id'] ?? ctx.l10n.notLinked}',
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),
                    TextField(
                      controller: links,
                      decoration: InputDecoration(
                        labelText: ctx.l10n.bangumiIds,
                        helperText: ctx.l10n.bangumiIdsHint,
                        helperMaxLines: 5,
                        helperStyle: TextStyle(fontSize: 13, height: 1.6),
                      ),
                    ),
                    if (message.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: Text(
                          message == 'ids'
                              ? ctx.l10n.invalidBangumiIds
                              : ctx.l10n.invalidTitleYear,
                          style: const TextStyle(color: Colors.red),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            actions: [
              UniformActionBar(
                children: [
                  TextButton.icon(
                    key: const ValueKey('metadata-search-bind'),
                    onPressed: () => Navigator.pop(ctx, 'search'),
                    icon: const Icon(Icons.manage_search),
                    label: Text(ctx.l10n.searchAndLink),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: Text(ctx.l10n.cancel),
                  ),
                  FilledButton(
                    key: const ValueKey('metadata-save'),
                    onPressed: () {
                      final rawIds = links.text.trim();
                      if (rawIds.isNotEmpty &&
                          rawIds
                              .split(RegExp(r'[,，\s]+'))
                              .any((s) => (int.tryParse(s) ?? 0) <= 0)) {
                        update(() => message = 'ids');
                        return;
                      }
                      final label = title.text.trim();
                      final y = year.text.trim();
                      final parsed = y.isEmpty ? null : int.tryParse(y);
                      if (label.isEmpty ||
                          (y.isNotEmpty &&
                              (parsed == null ||
                                  parsed < 1888 ||
                                  parsed > 2100))) {
                        update(() => message = 'fields');
                        return;
                      }
                      Navigator.pop(ctx, 'save');
                    },
                    child: Text(ctx.l10n.save),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
      final result = await Navigator.of(
        context,
        rootNavigator: true,
      ).push<String>(route);
      await route.completed;
      if (result == 'search') {
        if (context.mounted) await searchAndBind();
      } else if (result == 'save') {
        await Catalog.instance.setBangumiLinks(
          work['id'].toString(),
          links.text.trim().isEmpty
              ? []
              : links.text
                    .trim()
                    .split(RegExp(r'[,，\s]+'))
                    .map(int.parse)
                    .toList(),
        );
        await Catalog.instance.updateWorkMetadata(
          work['id'].toString(),
          title: title.text,
          year: year.text.trim().isEmpty ? null : int.parse(year.text.trim()),
          overview: overview.text,
        );
      }
    } finally {
      links.dispose();
      title.dispose();
      year.dispose();
      overview.dispose();
    }
  }

  static Future<void> characterOrder(
    BuildContext context,
    Map<String, Object?> work,
  ) async {
    final details = await Catalog.instance.readWorkDetails(work);
    final cast = (details?['characters'] as List? ?? [])
        .whereType<Map>()
        .toList();
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (dialog, refresh) => AlertDialog(
          title: Text(dialog.l10n.characterOrder),
          content: SizedBox(
            width: 400,
            height: 360,
            child: cast.isEmpty
                ? Center(child: Text(dialog.l10n.noCharactersYet))
                : ReorderableListView.builder(
                    itemCount: cast.length,
                    onReorderItem: (oldIndex, newIndex) => refresh(() {
                      cast.insert(newIndex, cast.removeAt(oldIndex));
                    }),
                    itemBuilder: (_, i) => ListTile(
                      key: ValueKey(cast[i]['id']),
                      title: Text(cast[i]['name']?.toString() ?? ''),
                      subtitle: Text(cast[i]['relation']?.toString() ?? ''),
                    ),
                  ),
          ),
          actions: [
            UniformActionBar(
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(dialog),
                  child: Text(dialog.l10n.cancel),
                ),
                FilledButton(
                  onPressed: () async {
                    await Catalog.instance.setCharacterOrder(
                      work['id'].toString(),
                      cast.map((e) => e['id']).whereType<int>().toList(),
                    );
                    if (dialog.mounted) Navigator.pop(dialog);
                  },
                  child: Text(dialog.l10n.save),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static Future<void> cover(
    BuildContext context,
    Map<String, Object?> work,
  ) async {
    final service = CoverOptionService();
    try {
      final optionsFuture = service.fetch(work);
      if (!context.mounted) return;
      final choices = <String, String>{};
      try {
        final edit = jsonDecode(work['cover_edit_json']?.toString() ?? '{}');
        if (edit is Map && edit['original'] is String) {
          choices['重新裁剪当前封面'] = edit['original'];
        }
      } catch (_) {}
      final chosen = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(ctx.l10n.editCover),
          content: SizedBox(
            width: 540,
            child: FutureBuilder<CoverOptions>(
              future: optionsFuture,
              builder: (context, snapshot) {
                final options = snapshot.data;
                if (options != null) {
                  if (options.tmdb != null) choices['TMDB'] = options.tmdb!;
                  for (final e in options.bangumiCovers.entries) {
                    choices['Bangumi ${e.key}'] = e.value;
                  }
                  if (options.bangumiCovers.isEmpty &&
                      options.bangumi != null) {
                    choices['Bangumi'] = options.bangumi!;
                  }
                }
                return SingleChildScrollView(
                  child: Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      if (snapshot.connectionState != ConnectionState.done)
                        const Padding(
                          padding: EdgeInsets.all(20),
                          child: CircularProgressIndicator(),
                        ),
                      for (final choice in choices.entries)
                        InkWell(
                          onTap: () => Navigator.pop(ctx, choice.key),
                          child: SizedBox(
                            width: 140,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                AspectRatio(
                                  aspectRatio: 2 / 3,
                                  child: ManagedImage(
                                    choice.value,
                                    fit: BoxFit.cover,
                                  ),
                                ),
                                Text(
                                  choice.key == '重新裁剪当前封面'
                                      ? context.l10n.recropCover
                                      : choice.key.startsWith('Bangumi')
                                      ? 'Bangumi'
                                      : 'TMDB',
                                  style: Theme.of(context).textTheme.bodyMedium,
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
          actions: [
            UniformActionBar(
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, 'reset'),
                  child: Text(ctx.l10n.automaticCover),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(ctx, 'local'),
                  child: Text(ctx.l10n.importImage),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: Text(ctx.l10n.cancel),
                ),
              ],
            ),
          ],
        ),
      );
      if (chosen == null) return;
      if (chosen == 'reset') {
        await Catalog.instance.setManualCover(work['id'].toString());
        return;
      }
      String? original = choices[chosen];
      String source = chosen.startsWith('TMDB') ? 'tmdb' : 'bangumi';
      int? subjectId = int.tryParse(chosen.replaceFirst('Bangumi ', ''));
      if (chosen == 'local') {
        final picked = await FilePicker.pickFiles(type: FileType.image);
        if (picked.isEmpty) return;
        original = picked.single.path;
        source = 'local';
        if (original != null &&
            await File(original).length() > 32 * 1024 * 1024) {
          throw const FormatException('图片超过 32 MB');
        }
      } else if (chosen == '重新裁剪当前封面') {
        final old = jsonDecode(work['cover_edit_json'].toString()) as Map;
        source = old['source'] as String;
        subjectId = old['subjectId'] as int?;
      }
      if (original == null) return;
      if (source == 'tmdb') subjectId = (work['tmdb_id'] as num?)?.toInt();
      DebugLog.write('CoverCrop', 'source=$source crop begin');
      final bytes = await ImageStore.load(original);
      await ImageStore.validate(bytes);
      if (!context.mounted) return;
      final result = await Navigator.push<Map<String, Object>>(
        context,
        MaterialPageRoute(builder: (_) => PosterCropPage(bytes: bytes)),
      );
      if (result == null) return;
      final originalId = await ImageStore.save(bytes, 'original');
      final output = await ImageStore.save(
        result['bytes'] as Uint8List,
        'crop',
      );
      await Catalog.instance.saveCroppedCover(
        work['id'].toString(),
        source,
        originalId,
        output,
        result['crop']!,
        subjectId: subjectId,
      );
      DebugLog.write('CoverCrop', 'source=$source crop complete');
    } catch (e) {
      DebugLog.write('CoverCrop', 'failed ${e.runtimeType}', level: 'ERROR');
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(context.l10n.coverFailed)));
      }
    } finally {
      service.close();
    }
  }
}
