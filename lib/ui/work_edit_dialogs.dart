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
import '../core/scan_recognition.dart';
import '../core/cover_options.dart';

/// Explicit work metadata and poster editors, separate from file association.
abstract final class WorkEditDialogs {
  static Future<void> metadata(
    BuildContext context,
    Map<String, Object?> work, {
    required Future<void> Function() searchAndBind,
    String? partBinding,
  }) async {
    final catalog = Catalog.instance;
    final part = partBinding == null
        ? null
        : await ScanRecognition.partOverviewPreview(catalog, partBinding);
    if (!context.mounted) return;
    if (partBinding != null && part == null) throw StateError('Part changed');
    final initialOverview =
        (part == null ? work['overview'] : part['value'])?.toString() ?? '';
    final title = TextEditingController(text: work['title']?.toString() ?? '');
    final year = TextEditingController(text: work['year']?.toString() ?? '');
    final overview = TextEditingController(text: initialOverview);
    final links = TextEditingController(
      text: BangumiLinks.ids(work).join(', '),
    );
    var message = '';
    final scroll = ScrollController();
    try {
      final route = DialogRoute<String>(
        context: context,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, update) => AlertDialog(
            title: Text(ctx.l10n.editMetadata),
            content: SizedBox(
              width: 540,
              child: ScrollConfiguration(
                behavior: ScrollConfiguration.of(
                  ctx,
                ).copyWith(scrollbars: false),
                child: Scrollbar(
                  key: const ValueKey('metadata-scrollbar'),
                  controller: scroll,
                  thumbVisibility: true,
                  notificationPredicate: (notification) =>
                      notification.depth == 0,
                  child: SingleChildScrollView(
                    controller: scroll,
                    padding: const EdgeInsets.fromLTRB(0, 12, 18, 4),
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
                          decoration: InputDecoration(
                            labelText: part == null
                                ? ctx.l10n.synopsis
                                : (Localizations.localeOf(ctx).languageCode ==
                                          'zh'
                                      ? '此部分简介'
                                      : 'Part overview'),
                          ),
                        ),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 16,
                          runSpacing: 8,
                          children: [
                            Text(
                              'TMDB: ${work['tmdb_id'] ?? ctx.l10n.notLinked}',
                            ),
                            Text(
                              'Bangumi: ${work['bangumi_id'] ?? ctx.l10n.notLinked}',
                            ),
                          ],
                        ),
                        const SizedBox(height: 24),
                        TextField(
                          controller: links,
                          decoration: InputDecoration(
                            labelText: ctx.l10n.bangumiIds,
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
              ),
            ),
            actions: [
              UniformActionBar(
                stackFirstWhenNarrow: true,
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
        if (part != null && overview.text.trim() != initialOverview.trim()) {
          await ScanRecognition.savePartOverview(
            catalog,
            part,
            overview.text.trim().isEmpty ? 'empty' : 'manual',
            overview.text,
          );
        }
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
          overview: part == null
              ? overview.text
              : work['overview']?.toString() ?? '',
        );
      }
    } finally {
      scroll.dispose();
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

  static Widget _artworkChoiceCard({
    required BuildContext context,
    required String imageUrl,
    required String label,
    required double aspectRatio,
    required VoidCallback onTap,
  }) => InkWell(
    borderRadius: BorderRadius.circular(10),
    onTap: onTap,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: AspectRatio(
            aspectRatio: aspectRatio,
            child: ManagedImage(imageUrl, fit: BoxFit.cover),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      ],
    ),
  );

  static Future<void> cover(
    BuildContext context,
    Map<String, Object?> work,
  ) async {
    final service = CoverOptionService();
    try {
      final optionsFuture = service.fetch(work);
      if (!context.mounted) return;
      final baseChoices = <String, String>{};
      try {
        final edit = jsonDecode(work['cover_edit_json']?.toString() ?? '{}');
        if (edit is Map && edit['original'] is String) {
          baseChoices['重新裁剪当前封面'] = edit['original'] as String;
        }
      } catch (_) {}
      var resolvedChoices = <String, String>{...baseChoices};
      final chosen = await showDialog<String>(
        context: context,
        builder: (ctx) => FutureBuilder<CoverOptions>(
          future: optionsFuture,
          builder: (context, snapshot) {
            final choices = <String, String>{...baseChoices};
            final options = snapshot.data;
            if (options != null) {
              if (options.tmdb != null) choices['TMDB'] = options.tmdb!;
              for (final e in options.bangumiCovers.entries) {
                choices[options.bangumiCovers.length == 1
                        ? 'Bangumi'
                        : 'Bangumi ${e.key}'] =
                    e.value;
              }
              if (options.bangumiCovers.isEmpty && options.bangumi != null) {
                choices['Bangumi'] = options.bangumi!;
              }
            }
            resolvedChoices = choices;
            final loading = snapshot.connectionState != ConnectionState.done;
            final count = choices.length;
            final targetWidth = count <= 1
                ? 240.0
                : count == 2
                ? 360.0
                : 510.0;
            return AlertDialog(
              title: Text(ctx.l10n.editCover),
              content: SizedBox(
                width: loading && count == 0 ? 320.0 : targetWidth,
                child: loading && count == 0
                    ? const Padding(
                        padding: EdgeInsets.symmetric(vertical: 36),
                        child: Center(child: CircularProgressIndicator()),
                      )
                    : SingleChildScrollView(
                        child: LayoutBuilder(
                          builder: (context, bounds) {
                            final entries = choices.entries.toList();
                            if (entries.isEmpty) {
                              return const SizedBox.shrink();
                            }
                            final cols = entries.length == 1
                                ? 1
                                : entries.length == 2
                                ? 2
                                : (bounds.maxWidth < 380 ? 2 : 3);
                            const gap = 14.0;
                            final cardW = entries.length == 1
                                ? bounds.maxWidth.clamp(120.0, 190.0)
                                : (bounds.maxWidth - (cols - 1) * gap) / cols;
                            return Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (loading)
                                  const Padding(
                                    padding: EdgeInsets.only(bottom: 10),
                                    child: LinearProgressIndicator(),
                                  ),
                                Wrap(
                                  alignment: entries.length == 1
                                      ? WrapAlignment.center
                                      : WrapAlignment.start,
                                  spacing: gap,
                                  runSpacing: gap,
                                  children: [
                                    for (final choice in entries)
                                      SizedBox(
                                        width: cardW,
                                        child: _artworkChoiceCard(
                                          context: context,
                                          imageUrl: choice.value,
                                          aspectRatio: 2 / 3,
                                          label: choice.key == '重新裁剪当前封面'
                                              ? context.l10n.recropCover
                                              : choice.key.startsWith('Bangumi')
                                              ? choice.key
                                              : 'TMDB',
                                          onTap: () =>
                                              Navigator.pop(ctx, choice.key),
                                        ),
                                      ),
                                  ],
                                ),
                              ],
                            );
                          },
                        ),
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
            );
          },
        ),
      );
      if (chosen == null) return;
      if (chosen == 'reset') {
        await Catalog.instance.setManualCover(work['id'].toString());
        return;
      }
      String? original = resolvedChoices[chosen];
      String source = chosen.startsWith('TMDB') ? 'tmdb' : 'bangumi';
      int? subjectId = int.tryParse(chosen.replaceFirst('Bangumi ', ''));
      if (subjectId == null && source == 'bangumi') {
        subjectId = (work['bangumi_id'] as num?)?.toInt();
      }
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

  static Future<void> backdrop(
    BuildContext context,
    Map<String, Object?> work, {
    String? fallbackBackdrop,
  }) async {
    final service = CoverOptionService();
    try {
      final optionsFuture = service.fetchBackdrops(
        work,
        fallbackBackdrop: fallbackBackdrop,
      );
      if (!context.mounted) return;
      final previousState = Catalog.backdropEditState(work);
      final recropOriginal = previousState?['original'] as String?;
      var resolvedOptions = <String, BackdropOption>{};
      final chosen = await showDialog<String>(
        context: context,
        builder: (ctx) => FutureBuilder<List<BackdropOption>>(
          future: optionsFuture,
          builder: (context, snapshot) {
            final map = <String, BackdropOption>{
              if (recropOriginal != null && recropOriginal.isNotEmpty)
                'recrop': BackdropOption(
                  key: 'recrop',
                  label: context.l10n.recropBackdrop,
                  url:
                      (previousState?['resource'] as String?) ?? recropOriginal,
                  source: (previousState?['source'] as String?) ?? 'local',
                  subjectId: previousState?['subjectId'] as int?,
                ),
              for (final item in snapshot.data ?? const <BackdropOption>[])
                item.key: item,
            };
            resolvedOptions = map;
            final loading = snapshot.connectionState != ConnectionState.done;
            final entries = map.entries.toList();
            final targetWidth = entries.length <= 1 ? 340.0 : 520.0;
            return AlertDialog(
              title: Text(ctx.l10n.editBackdrop),
              content: SizedBox(
                width: loading && entries.isEmpty ? 340.0 : targetWidth,
                child: loading && entries.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.symmetric(vertical: 36),
                        child: Center(child: CircularProgressIndicator()),
                      )
                    : SingleChildScrollView(
                        child: LayoutBuilder(
                          builder: (context, bounds) {
                            if (entries.isEmpty) {
                              return const SizedBox.shrink();
                            }
                            final cols =
                                entries.length == 1 || bounds.maxWidth < 360
                                ? 1
                                : 2;
                            const gap = 14.0;
                            final cardW =
                                (bounds.maxWidth - (cols - 1) * gap) / cols;
                            return Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (loading)
                                  const Padding(
                                    padding: EdgeInsets.only(bottom: 10),
                                    child: LinearProgressIndicator(),
                                  ),
                                Wrap(
                                  spacing: gap,
                                  runSpacing: gap,
                                  children: [
                                    for (final entry in entries)
                                      SizedBox(
                                        width: cardW,
                                        child: _artworkChoiceCard(
                                          context: context,
                                          imageUrl: entry.value.url,
                                          aspectRatio: 16 / 9,
                                          label: entry.value.label,
                                          onTap: () =>
                                              Navigator.pop(ctx, entry.key),
                                        ),
                                      ),
                                  ],
                                ),
                              ],
                            );
                          },
                        ),
                      ),
              ),
              actions: [
                UniformActionBar(
                  children: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx, 'reset'),
                      child: Text(ctx.l10n.automaticBackdrop),
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
            );
          },
        ),
      );
      if (chosen == null) return;
      if (chosen == 'reset') {
        await Catalog.instance.setManualBackdrop(work['id'].toString());
        return;
      }
      String? original;
      String source = 'local';
      int? subjectId;
      if (chosen == 'local') {
        final picked = await FilePicker.pickFiles(type: FileType.image);
        if (picked.isEmpty) return;
        original = picked.single.path;
        source = 'local';
        if (original != null &&
            await File(original).length() > 32 * 1024 * 1024) {
          throw const FormatException('图片超过 32 MB');
        }
      } else if (chosen == 'recrop' && recropOriginal != null) {
        original = recropOriginal;
        source = (previousState?['source'] as String?) ?? 'local';
        subjectId = previousState?['subjectId'] as int?;
      } else if (resolvedOptions[chosen] case final selected?) {
        original = selected.url;
        source = selected.source;
        subjectId = selected.subjectId;
      }
      if (original == null) return;
      DebugLog.write('BackdropCrop', 'source=$source crop begin');
      final bytes = await ImageStore.load(original);
      await ImageStore.validate(bytes);
      if (!context.mounted) return;
      final result = await Navigator.push<Map<String, Object>>(
        context,
        MaterialPageRoute(
          builder: (_) => PosterCropPage(
            bytes: bytes,
            aspectRatio: 16 / 9,
            maxExportWidth: 1920,
            isBackdrop: true,
          ),
        ),
      );
      if (result == null) return;
      final originalId = await ImageStore.save(bytes, 'original');
      final output = await ImageStore.save(
        result['bytes'] as Uint8List,
        'crop',
      );
      await Catalog.instance.saveCroppedBackdrop(
        work['id'].toString(),
        source,
        originalId,
        output,
        result['crop']!,
        subjectId: subjectId,
      );
      DebugLog.write('BackdropCrop', 'source=$source crop complete');
    } catch (e) {
      DebugLog.write('BackdropCrop', 'failed ${e.runtimeType}', level: 'ERROR');
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(context.l10n.backdropFailed)));
      }
    } finally {
      service.close();
    }
  }
}
