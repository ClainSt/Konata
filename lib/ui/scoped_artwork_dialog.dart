import 'dart:convert';

import 'package:flutter/material.dart';

import '../core/catalog.dart';
import '../core/library_foundation.dart';
import '../core/scoped_artwork.dart';
import '../core/scrape_task_runner.dart';
import 'managed_image.dart';

Future<bool> editScopedArtwork(
  BuildContext context,
  String work,
  ScopedImage kind, {
  String? asset,
}) async {
  final runner = ScrapeTaskRunner.forCatalog(Catalog.instance);
  final preview = await runner.artwork.review(work, kind, asset: asset);
  if (preview == null || !context.mounted) return false;
  final zh = Localizations.localeOf(context).languageCode == 'zh';
  String tr(String cn, String en) => zh ? cn : en;
  Future<void> selectBackdrop(
    BuildContext dialog,
    Map<String, dynamic> row, {
    bool seriesWide = false,
  }) async {
    final confirmed = await showDialog<bool>(
      context: dialog,
      builder: (preview) => AlertDialog(
        scrollable: true,
        title: Text(tr('预览背景', 'Preview backdrop')),
        content: SizedBox(
          width: 760,
          child: AspectRatio(
            aspectRatio: 16 / 9,
            child: ManagedImage(
              row['url'] as String,
              fit: BoxFit.contain,
              artwork: ManagedArtwork.backdrop,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(preview),
            child: Text(tr('返回候选', 'Back to candidates')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(preview, true),
            child: Text(tr('使用此图', 'Use this image')),
          ),
        ],
      ),
    );
    if (confirmed == true && dialog.mounted) {
      Navigator.pop(dialog, (
        image: row,
        automatic: false,
        seriesWide: seriesWide,
      ));
    }
  }

  String? provider;
  if (kind == ScopedImage.poster) {
    provider = await showDialog<String>(
      context: context,
      builder: (dialog) => SimpleDialog(
        title: Text(tr('编辑封面', 'Edit cover')),
        children: [
          for (final source in (preview['providers'] as List).cast<String>())
            SimpleDialogOption(
              onPressed: () => Navigator.pop(dialog, source),
              child: Text(source == 'tmdb' ? 'TMDB' : 'Bangumi'),
            ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(dialog, 'default'),
            child: Text(tr('恢复默认封面', 'Restore default cover')),
          ),
        ],
      ),
    );
    if (!context.mounted || provider == null) return false;
    if (provider == 'default') {
      await runner.artwork.decide(work, kind, preview, null, automatic: true);
      final job = await runner.artwork.enqueue(work, kind);
      if (job != null) await runner.run(job);
      return true;
    }
  }
  Future<Map<String, dynamic>> gallery() async {
    final id = await runner.artwork.enqueue(
      work,
      kind,
      gallery: true,
      asset: asset,
      provider: provider,
    );
    if (id == null) return {};
    await runner.tasks.control(id, 'retry');
    await runner.run(id, manualRetry: true);
    final result = await runner.tasks.db.query(
      'scrape_steps',
      where: "task_id=? AND state='complete'",
      whereArgs: [id],
    );
    return result.isEmpty
        ? {}
        : jsonDecode(result.single['result_json'] as String)
              as Map<String, dynamic>;
  }

  final loading = gallery();
  final decision =
      await showDialog<
        ({Map<String, dynamic>? image, bool automatic, bool seriesWide})
      >(
        context: context,
        builder: (dialog) => AlertDialog(
          scrollable: true,
          title: Text(switch (kind) {
            ScopedImage.poster => tr('选择封面', 'Select cover'),
            ScopedImage.backdrop => tr('选择背景', 'Select backdrop'),
            ScopedImage.still => tr('选择单集缩略图', 'Select episode thumbnail'),
          }),
          content: SizedBox(
            width: 480,
            child: FutureBuilder(
              future: loading,
              builder: (_, snapshot) {
                if (snapshot.connectionState != ConnectionState.done)
                  return const LinearProgressIndicator();
                final result = snapshot.data ?? {};
                final rows = ((result['candidates'] as List?) ?? const [])
                    .whereType<Map<String, dynamic>>()
                    .toList();
                final automatic = preview['automatic'] as String?;
                final complete =
                    result['scope'] == preview['scope'] &&
                    (result['missing'] as List?)?.isEmpty == true;
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (kind == ScopedImage.still ||
                        preview['can_restore'] == true)
                      ListTile(
                        title: Text(
                          tr('恢复自动选择', 'Restore automatic selection'),
                        ),
                        subtitle: Text(
                          kind == ScopedImage.backdrop
                              ? tr(
                                  '重新获取当前范围的默认背景。',
                                  'Fetch the default backdrop for this scope.',
                                )
                              : automatic == null
                              ? tr(
                                  '当前范围没有合适图片，恢复后留空。',
                                  'The current scope has no suitable image.',
                                )
                              : tr(
                                  '将按当前范围采用下列自动候选。',
                                  'Use the automatic candidate for this scope.',
                                ),
                        ),
                        leading: automatic == null
                            ? null
                            : ManagedImage(
                                automatic,
                                width: 48,
                                height: 58,
                                fit: BoxFit.cover,
                                decodeWidth: 120,
                              ),
                        onTap: () => Navigator.pop(dialog, (
                          image: null,
                          automatic: true,
                          seriesWide: false,
                        )),
                      ),
                    if (!complete && rows.isEmpty)
                      Text(
                        tr(
                          '候选暂不可用，当前选择仍可保留。',
                          'Candidates are unavailable. Keep the current choice.',
                        ),
                      ),
                    for (final row in rows.take(8))
                      ListTile(
                        leading: ManagedImage(
                          row['url'] as String,
                          width: kind == ScopedImage.backdrop ? 96 : 48,
                          height: kind == ScopedImage.backdrop ? 54 : 58,
                          fit: kind == ScopedImage.backdrop
                              ? BoxFit.contain
                              : BoxFit.cover,
                          decodeWidth: kind == ScopedImage.backdrop ? 240 : 120,
                        ),
                        title: Text(
                          row['provider'] == 'bangumi' ? 'Bangumi' : 'TMDB',
                        ),
                        subtitle: Text(
                          row['series_only'] == true
                              ? tr(
                                  '系列图片，采用后仅用于当前页',
                                  'Series artwork. Apply to this page only.',
                                )
                              : tr('当前确认范围', 'Confirmed scope'),
                        ),
                        onTap: () => kind == ScopedImage.backdrop
                            ? selectBackdrop(dialog, row)
                            : Navigator.pop(dialog, (
                                image: row,
                                automatic: false,
                                seriesWide: false,
                              )),
                      ),
                    if (kind == ScopedImage.backdrop)
                      for (final row
                          in rows
                              .take(3)
                              .where((r) => r['series_only'] == true))
                        ListTile(
                          leading: ManagedImage(
                            row['url'] as String,
                            width: 48,
                            height: 36,
                            fit: BoxFit.cover,
                            decodeWidth: 120,
                          ),
                          title: Text(
                            tr(
                              '确认为系列通用背景',
                              'Confirm as a series-wide backdrop',
                            ),
                          ),
                          subtitle: Text(
                            tr(
                              '只补充尚未选图的页面。',
                              'Fill pages without an existing selection.',
                            ),
                          ),
                          onTap: () =>
                              selectBackdrop(dialog, row, seriesWide: true),
                        ),
                  ],
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog, (
                image: null,
                automatic: false,
                seriesWide: false,
              )),
              child: Text(tr('主动留空', 'Leave blank')),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialog),
              child: Text(tr('取消', 'Cancel')),
            ),
          ],
        ),
      );
  if (decision == null) return false;
  if (kind == ScopedImage.backdrop && decision.automatic) {
    final job = await runner.artwork.enqueue(
      work,
      kind,
      restoreBackdrop: preview,
    );
    if (job == null) return false;
    await runner.run(job);
    return true;
  }
  await runner.artwork.decide(
    work,
    kind,
    preview,
    decision.image,
    automatic: decision.automatic,
    asset: asset,
    seriesWide: decision.seriesWide,
  );
  return true;
}

Future<bool> restoreScopedField(BuildContext context, String work) async {
  final cat = Catalog.instance;
  final foundation = LibraryFoundation(cat.db);
  final available = <String, Map<String, Object?>>{};
  for (final name in ['title', 'year', 'overview']) {
    final field = await foundation.field(work, name);
    if (field['mode'] != 'auto') available[name] = field;
  }
  if (!context.mounted) return false;
  final zh = Localizations.localeOf(context).languageCode == 'zh';
  String tr(String cn, String en) => zh ? cn : en;
  final selected = await showDialog<String>(
    context: context,
    builder: (dialog) => AlertDialog(
      scrollable: true,
      title: Text(tr('按字段恢复自动资料', 'Restore automatic fields')),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (available.isEmpty)
              Text(tr('当前没有手动覆盖。', 'There are no manual overrides.')),
            for (final e in available.entries)
              ListTile(
                title: Text(switch (e.key) {
                  'title' => tr('标题', 'Title'),
                  'year' => tr('年份', 'Year'),
                  _ => tr('简介', 'Overview'),
                }),
                subtitle: Text(
                  [
                    '${tr("当前", "Current")} · ${jsonDecode(e.value['manual_json'] as String? ?? 'null') ?? tr("留空", "Blank")}',
                    '${tr("自动", "Automatic")} · ${e.value['automatic_json'] == null ? tr("尚未取得", "Unavailable") : jsonDecode(e.value['automatic_json'] as String) ?? tr("留空", "Blank")}',
                    if (e.value['automatic_source'] != null)
                      '${e.value['automatic_source']}',
                  ].join('\n'),
                ),
                enabled: e.value['automatic_json'] != null,
                onTap: e.value['automatic_json'] == null
                    ? null
                    : () => Navigator.pop(dialog, e.key),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialog),
          child: Text(tr('取消', 'Cancel')),
        ),
      ],
    ),
  );
  if (selected == null || !context.mounted) return false;
  final snapshot = available[selected]!;
  await foundation.writeField(
    work,
    selected,
    expectedScope: snapshot['scope'] as String,
    expectedRevision: snapshot['revision'] as int,
    expectedBindingRevision: snapshot['binding_revision'] as int,
    expectedAutomaticRevision: snapshot['automatic_revision'] as int,
    mode: 'auto',
  );
  await cat.reload();
  return true;
}
