import 'dart:convert';

import 'package:flutter/material.dart';

import '../core/incremental_scan.dart';
import '../core/scan_recognition.dart';
import '../core/scrape_task_runner.dart';
import '../core/metadata_servers.dart';
import 'managed_image.dart';

class ScanReviewsPage extends StatefulWidget {
  const ScanReviewsPage({
    super.key,
    required this.runner,
    this.source,
    this.workId,
  }) : assert(source == null || workId == null);

  final ScrapeTaskRunner runner;
  final String? source;
  final String? workId;

  @override
  State<ScanReviewsPage> createState() => _ScanReviewsPageState();
}

class _ScanReviewsPageState extends State<ScanReviewsPage> {
  static const _pageSize = 40;
  bool _includeResolved = false;
  bool _advanced = false;
  int _offset = 0;
  late Future<List<Map<String, Object?>>> _rows;
  bool get _zh => Localizations.localeOf(context).languageCode == 'zh';
  String _label(String zh, String en) => _zh ? zh : en;

  @override
  void initState() {
    super.initState();
    _load();
    widget.runner.tasks.addListener(_changed);
    widget.runner.catalog.addListener(_changed);
  }

  @override
  void dispose() {
    widget.runner.tasks.removeListener(_changed);
    widget.runner.catalog.removeListener(_changed);
    super.dispose();
  }

  void _load() {
    final scope = widget.workId != null ? 'b.work_id=?' :
        widget.source != null ? 'l.source_id=?' : '1=1';
    _rows = widget.runner.tasks.db.rawQuery(
      '''
      SELECT m.folder AS raw_path,'move' AS layer,
        CASE WHEN m.skipped=1 THEN 'skipped' ELSE 'pending' END AS state,
        m.source_id,m.folder,m.revision,m.evidence,
        NULL AS id,NULL AS work_id,NULL AS provider,NULL AS candidates,NULL AS adopted,
        NULL AS previous,'move_candidate' AS reason,0 AS level,s.session,NULL AS identity_revision,
        NULL AS group_name,NULL AS group_revision,r.revision AS source_revision
      FROM scan_move_reviews m JOIN library_source_revisions r ON r.source_id=m.source_id
      CROSS JOIN scrape_runtime s
      WHERE (? IS NULL OR m.source_id=?) AND ? IS NULL
        AND m.revision=r.revision AND (?=1 OR m.skipped=0)
      UNION ALL
      SELECT CASE WHEN a.id IS NOT NULL THEN a.relative_path
        WHEN g.scope IS NOT NULL THEN l.relative_path ||
          CASE WHEN g.directory='' THEN '' ELSE '/' || g.directory END || ' · ' || g.name
        WHEN b.scope='' THEN l.relative_path ELSE l.relative_path || '/' || b.scope END,
        b.layer,b.state,l.source_id,NULL,b.revision,NULL,b.id,b.work_id,b.provider,b.candidates,
        b.adopted,b.previous,b.reason,CASE b.layer WHEN 'work' THEN 1 WHEN 'range' THEN 2 ELSE 3 END,
        s.session,protection.revision,g.name,g.revision,COALESCE(r.revision,0)
      FROM scan_bindings b JOIN library_locations l ON l.kind='work' AND l.entity_id=b.work_id
      JOIN works w ON w.id=b.work_id LEFT JOIN assets a ON a.id=b.asset_id
      JOIN library_work_protection protection ON protection.work_id=w.id CROSS JOIN scrape_runtime s
      LEFT JOIN scan_file_groups g ON b.layer='range' AND g.scope=b.scope
      LEFT JOIN library_source_revisions r ON r.source_id=l.source_id
      WHERE $scope
        AND w.hidden=0 AND (?=1 OR b.state='pending' OR b.reason='mapping_changed')
        AND w.tmdb_type IS NULL AND w.bangumi_id IS NULL AND protection.legacy_lock=0
        AND (b.layer!='episode' OR b.parent IS NOT NULL)
        AND (?=1 OR b.layer='work')
        AND NOT EXISTS (SELECT 1 FROM scan_missing_assets m WHERE m.asset_id=a.id)
      ORDER BY level,raw_path,provider LIMIT ? OFFSET ?
      ''',
      [
        widget.source,
        widget.source,
        widget.workId,
        _includeResolved ? 1 : 0,
        if (widget.workId != null || widget.source != null) widget.workId ?? widget.source,
        _includeResolved ? 1 : 0,
        _advanced ? 1 : 0,
        _pageSize + 1,
        _offset,
      ],
    );
  }

  void _changed() {
    if (mounted) setState(_load);
  }

  String _layer(Object? layer) => switch (layer) {
    'move' => _label('疑似目录移动', 'Possible folder move'),
    'work' => _label('作品身份', 'Work identity'),
    'range' => _label('季／部分', 'Season or part'),
    _ => _label('单个文件', 'Individual file'),
  };

  String _reason(Object? reason) => switch (reason) {
    'unsearched' => _label('等待查询', 'Search pending'),
    'request_failed' => _label('来源暂未返回完整结果', 'Provider results incomplete'),
    'query_incomplete' => _label('查询未完成', 'Search incomplete'),
    'detail_budget_exhausted' => _label('候选补查已达上限，需核对', 'Candidate check limit reached; review needed'),
    'invalid_response' => _label('来源返回的条目与请求不符', 'Provider returned a different or invalid entry'),
    'untyped_id' => _label('目录中的 ID 未注明类型', 'Folder ID has no media type'),
    'conflicting_markers' => _label('目录中的标记相互冲突', 'Conflicting folder markers'),
    'conflicting_title' => _label('名称或年份与候选不一致', 'Title or year differs'),
    'ambiguous' => _label(
      '多个候选或结果未列全',
      'Multiple candidates or incomplete listing',
    ),
    'no_match' || 'no_title' => _label('暂无可靠候选', 'No reliable candidate'),
    'separate_file_review' => _label(
      '特别篇或其他文件需单独确认',
      'File needs separate review',
    ),
    'verified_movie_attachment' => _label('电影宣传附录', 'Movie promotional extra'),
    'move_candidate' => _label(
      '文件名和大小与旧位置一致',
      'Names and sizes match the previous location',
    ),
    'mapping_changed' => _label(
      '映射已变化，当前采用仍保留',
      'Mapping changed. The adopted match is retained.',
    ),
    _ => _label('等待确认', 'Awaiting confirmation'),
  };

  String _choice(Map choice) {
    if (choice['attachment'] case final String attachment) {
      return attachment == 'teaser' ? _label('特报', 'Teaser') : _label('预告', 'Trailer');
    }
    final title = choice['title']?.toString() ?? '';
    final id = choice['id'];
    if (id != null) {
      return [
        title,
        if (choice['year'] != null) choice['year'],
        choice['type'],
        '#$id',
        if (choice['sort'] != null) 'E${choice['sort']}',
        if (choice['subject'] != null)
          '${_label('条目', 'Subject')} #${choice['subject']}',
        if (choice['offset'] != null && choice['offset'] != 0)
          '${_label('偏移', 'Offset')} ${choice['offset']}',
      ].where((value) => value != null && value != '').join(' · ');
    }
    if (choice['episode'] != null) {
      return 'S${choice['season']} E${choice['episode']} ${title.trim()}'
          .trimRight();
    }
    final offset = choice['offset'];
    return 'S${choice['season']} · ${choice['first']}–${choice['last']}'
        '${offset == 0 ? '' : ' · ${_label('偏移', 'Offset')} $offset'}';
  }

  Future<void> _apply(Future<void> Function() action) async {
    try {
      await action();
      if (mounted) {
        setState(() {
          _offset = 0;
          _load();
        });
      }
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _label(
              '记录已变化或输入无效，请重新核对',
              'Review changed or the input was invalid. Check it and try again.',
            ),
          ),
        ),
      );
      _changed();
    }
  }

  Future<void> _inspect(Map<String, Object?> row) async {
    final move = row['layer'] == 'move';
    final choices = move
        ? ((jsonDecode(row['evidence'] as String) as Map)['choices'] as List)
              .cast<Map<String, dynamic>>()
        : ScanRecognition.candidates(row);
    final adopted = move ? null : ScanRecognition.adopted(row);
    final action = await showDialog<({String action, Map<String, Object?>? choice})>(
      context: context,
      builder: (dialogContext) {
        void select(String action, [Map<String, Object?>? choice]) =>
            Navigator.pop(dialogContext, (action: action, choice: choice));
        return AlertDialog(
          title: Text(_layer(row['layer'])),
          scrollable: true,
          content: SizedBox(
            width: 480,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SelectableText(row['raw_path'] as String),
                const SizedBox(height: 8),
                Text(_reason(row['reason'])),
                if (!move && row['layer'] != 'episode')
                  Text(
                    _label(
                      '改绑后会重新核对该来源的下级范围。',
                      'Relinking reopens dependent reviews for this provider.',
                    ),
                  ),
                if (adopted != null)
                  Text('${_label('已采用', 'Adopted')} · ${_choice(adopted)}'),
                for (final choice in choices)
                  if (row['reason'] == 'query_incomplete')
                    Text(_choice(choice))
                  else
                    Card(child: Padding(padding: const EdgeInsets.all(12), child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (choice['poster'] case final String poster
                            when MetadataServers.imageResource(poster) != null) ...[
                          ManagedImage(poster, width: 64, height: 96, fit: BoxFit.cover, decodeWidth: 192),
                          const SizedBox(width: 12),
                        ],
                        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(move
                            ? '${choice['folder']} → ${row['folder']} · ${(choice['paths'] as Map).length} ${_label('个文件', 'files')}'
                            : _choice(choice), style: Theme.of(context).textTheme.titleMedium),
                          if (choice['summary'] case final String summary)
                            Text(summary, maxLines: 3, overflow: TextOverflow.ellipsis),
                          const SizedBox(height: 8),
                          FilledButton.tonal(onPressed: () => select('adopt', choice),
                            child: Text(_label('采用此对应', 'Use this match'))),
                        ])),
                      ],
                    ))),
                if (move)
                  TextButton(
                    onPressed: () => select('adopt'),
                    child: Text(_label('作为新作品添加', 'Add as a new work')),
                  )
                else ...[
                  TextButton(
                    onPressed: () => select('manual'),
                    child: Text(_label('输入其他对应', 'Enter a different match')),
                  ),
                  if (row['layer'] == 'work' &&
                      row['state'] == 'pending' &&
                      (widget.runner.catalog.automaticRecognition
                          ? ScanRecognition.canSupplementWorkQuery(row)
                          : ScanRecognition.canRetryWorkQuery(row)))
                    TextButton(
                      onPressed: () => select('retry'),
                      child: Text(_label('查询待补来源', 'Search pending providers')),
                    ),
                  if (adopted != null || row['previous'] != null)
                    TextButton(
                      onPressed: () => select('undo'),
                      child: Text(_label('撤回本次采用', 'Undo adoption')),
                    ),
                  if (adopted != null && row['layer'] == 'range')
                    TextButton(
                      onPressed: () => select('fetch_scope'),
                      child: Text(
                        _label('获取此范围的章节', 'Fetch chapters for this range'),
                      ),
                    ),
                  if (row['layer'] == 'range')
                    TextButton(
                      key: const ValueKey('scan-file-group'),
                      onPressed: () => select('file_group'),
                      child: Text(
                        row['group_name'] == null
                            ? _label('将同目录文件分组', 'Group files in this folder')
                            : _label('编辑同目录文件组', 'Edit file group'),
                      ),
                    ),
                  if (adopted != null && row['layer'] == 'range')
                    TextButton(
                      key: const ValueKey('scan-numbering-preview'),
                      onPressed: () => select('numbering'),
                      child: Text(_label('预览编号规则', 'Preview numbering rule')),
                    ),
                ],
              ],
            ),
          ),
          actions: [
            if (adopted == null && row['state'] != 'skipped')
              TextButton(
                onPressed: () => select('skip'),
                child: Text(_label('暂时跳过', 'Skip for now')),
              ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(_label('关闭', 'Close')),
            ),
          ],
        );
      },
    );
    if (!mounted || action == null) return;
    final source = row['source_id'] as String;
    if (action.action == 'file_group') {
      await _apply(() => _editGroup(row));
      return;
    }
    if (action.action == 'numbering') {
      await _apply(() => _previewNumbering(row));
      return;
    }
    if (move) {
      await _apply(() async {
        await IncrementalScan(widget.runner.catalog).resolveMove(
          row,
          action.choice?['work'] as String?,
          skip: action.action == 'skip',
        );
        if (action.action == 'adopt' && action.choice == null) {
          await widget.runner.recognition.schedule(source);
        }
      });
      return;
    }
    if (action.action == 'retry') {
      await _apply(() async {
        final id = await widget.runner.recognition.enqueue(
          source,
          row['work_id'] as String,
          retry: true,
        );
        await widget.runner.run(id, manualRetry: true);
      });
      return;
    }
    if (action.action == 'fetch_scope') {
      await _apply(() async {
        final id = await widget.runner.recognition.enqueueRange(
          source,
          row['id'] as String,
        );
        await widget.runner.tasks.control(id, 'retry');
        await widget.runner.run(id, manualRetry: true);
      });
      return;
    }
    final choice = action.action == 'manual'
        ? await _manual(row, adopted ?? choices.firstOrNull)
        : action.choice;
    if (action.action == 'manual' && choice == null) return;
    await _apply(
      () => widget.runner.recognition.decide(
        row,
        choice,
        skip: action.action == 'skip',
        undo: action.action == 'undo',
      ),
    );
  }

  Future<void> _editGroup(Map<String, Object?> row) async {
    final files = await widget.runner.recognition.groupFiles(row);
    if (!mounted) return;
    var name = row['group_name'] as String? ?? '';
    final selected = {
      for (final file in files)
        if (file['file_group'] != null) file['id'] as String,
    };
    final editing = row['group_name'] != null;
    final save = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            title: Text(_label('同目录文件组', 'File group')),
            content: SizedBox(
              width: 520,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextFormField(
                    key: const ValueKey('scan-group-name'),
                    initialValue: name,
                    maxLength: 80,
                    decoration: InputDecoration(
                      labelText: _label('组名', 'Group name'),
                    ),
                    onChanged: (value) => setDialogState(() => name = value),
                  ),
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: files.length,
                      itemBuilder: (context, index) {
                        final file = files[index];
                        final id = file['id'] as String;
                        return CheckboxListTile(
                          title: Text(file['name'] as String),
                          value: selected.contains(id),
                          onChanged: (value) => setDialogState(() {
                            if (value == true) {
                              selected.add(id);
                            } else {
                              selected.remove(id);
                            }
                          }),
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
                child: Text(_label('取消', 'Cancel')),
              ),
              FilledButton(
                key: const ValueKey('scan-save-group'),
                onPressed: (selected.isEmpty ? editing : name.trim().isNotEmpty)
                    ? () => Navigator.pop(context, true)
                    : null,
                child: Text(
                  selected.isEmpty && editing
                      ? _label('解散组', 'Dissolve group')
                      : _label('保存分组', 'Save group'),
                ),
              ),
            ],
          );
        },
      ),
    );
    if (save == true && mounted) {
      await widget.runner.recognition.saveFileGroup(
        row,
        name,
        selected,
        groupRevision: row['group_revision'] as int?,
      );
    }
  }

  Future<void> _previewNumbering(Map<String, Object?> row) async {
    final preview = await widget.runner.recognition.previewNumbering(row);
    if (!mounted) return;
    final count = preview.matches.length;
    final save = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_label('编号规则预览', 'Numbering preview')),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _label(
                  '可确认 $count 个文件 · 保留 ${preview.deferred.length} 个待核对',
                  '$count ready · ${preview.deferred.length} need individual review',
                ),
              ),
              if (count == 0)
                Text(
                  _label('可先获取此范围的章节。', 'Fetch chapters for this range first.'),
                ),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: count + preview.deferred.length,
                  itemBuilder: (context, index) => index < count
                      ? ListTile(
                          title: Text(preview.matches[index].path),
                          subtitle: Text(
                            _choice(preview.matches[index].choice),
                          ),
                        )
                      : ListTile(
                          title: Text(preview.deferred[index - count]),
                          subtitle: Text(_label('待单独核对', 'Individual review')),
                        ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(_label('关闭', 'Close')),
          ),
          FilledButton(
            key: const ValueKey('scan-apply-numbering'),
            onPressed: count == 0 ? null : () => Navigator.pop(context, true),
            child: Text(_label('确认所列对应', 'Confirm listed matches')),
          ),
        ],
      ),
    );
    if (save == true && mounted) {
      await widget.runner.recognition.applyNumbering(row, preview);
    }
  }

  Future<Map<String, Object?>?> _manual(Map row, Map? defaults) async {
    final tmdb = row['provider'] == 'tmdb';
    final layer = row['layer'];
    final fields = <String, String>{
      if (!tmdb || layer == 'work') 'id': 'ID',
      if (!tmdb && layer == 'episode')
        'subject': _label('条目 ID（可选）', 'Subject ID (optional)'),
      if (tmdb && layer != 'work') 'season': _label('季号', 'Season'),
      if (tmdb && layer == 'episode') 'episode': _label('集号', 'Episode'),
      if (tmdb && layer == 'range') ...{
        'first': _label('起始集', 'First episode'),
        'last': _label('末集', 'Last episode'),
      },
      if (layer == 'range')
        'offset': _label('源站集号减本地集号', 'Provider number minus local number'),
    };
    final values = {
      for (final key in fields.keys)
        key:
            (defaults?[key] ??
                    (key == 'first'
                        ? 1
                        : key == 'offset'
                        ? 0
                        : ''))
                .toString(),
    };
    var type = defaults?['type'] as String? ?? (tmdb ? 'tv' : 'anime');
    final form = GlobalKey<FormState>();
    return showDialog<Map<String, Object?>>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        scrollable: true,
        title: Text(_label('输入对应关系', 'Enter a match')),
        content: SizedBox(
          width: 420,
          child: Form(
            key: form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (tmdb && layer == 'work')
                  DropdownButtonFormField<String>(
                    initialValue: type,
                    items: [
                      DropdownMenuItem(
                        value: 'tv',
                        child: Text(_label('剧集', 'TV')),
                      ),
                      DropdownMenuItem(
                        value: 'movie',
                        child: Text(_label('电影', 'Movie')),
                      ),
                    ],
                    onChanged: (value) {
                      if (value != null) type = value;
                    },
                  ),
                for (final field in fields.entries)
                  TextFormField(
                    initialValue: values[field.key],
                    decoration: InputDecoration(labelText: field.value),
                    keyboardType: const TextInputType.numberWithOptions(
                      signed: true,
                    ),
                    onChanged: (value) => values[field.key] = value,
                    validator: (value) =>
                        (field.key != 'subject' ||
                                value?.trim().isNotEmpty == true) &&
                            int.tryParse(value?.trim() ?? '') == null
                        ? _label('请输入整数', 'Enter a whole number')
                        : null,
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(_label('取消', 'Cancel')),
          ),
          FilledButton(
            onPressed: () {
              if (form.currentState?.validate() != true) return;
              Navigator.pop(dialogContext, <String, Object?>{
                for (final entry in values.entries)
                  if (entry.value.trim().isNotEmpty)
                    entry.key: int.parse(entry.value.trim()),
                if (layer == 'work') 'type': type,
              });
            },
            child: Text(_label('确认采用', 'Confirm match')),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        widget.workId == null
            ? _label('识别与目录确认', 'Scan review')
            : _label('本作品刮削纠错', 'Review this title'),
      ),
      actions: [
        if (widget.workId == null)
          IconButton(
            tooltip: _label('检查映射版本', 'Check mapping version'),
            onPressed: () => _apply(widget.runner.refreshMappingIndex),
            icon: const Icon(Icons.sync),
          ),
      ],
    ),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 920),
        child: FutureBuilder(
          future: _rows,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Center(
                child: Text(_label('无法读取确认记录', 'Unable to load reviews')),
              );
            }
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final rows = snapshot.data!;
            final count = rows.take(_pageSize).length;
            return ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: count + 2,
              itemBuilder: (context, index) {
                if (index == 0) {
                  return Column(children: [
                    CheckboxListTile(
                      title: Text(_label('季集与单文件设置', 'Season and file settings')),
                      value: _advanced,
                      onChanged: (value) => setState(() {
                        _advanced = value!;
                        _offset = 0;
                        _load();
                      }),
                    ),
                    if (_advanced) CheckboxListTile(
                    title: Text(
                      _label('显示已采用及已跳过', 'Show adopted and skipped reviews'),
                    ),
                    value: _includeResolved,
                    onChanged: (value) => setState(() {
                      _includeResolved = value!;
                      _offset = 0;
                      _load();
                    }),
                    ),
                  ]);
                }
                if (index > count) {
                  return Wrap(
                    alignment: WrapAlignment.center,
                    children: [
                      if (_offset > 0)
                        TextButton(
                          onPressed: () => setState(() {
                            _offset -= _pageSize;
                            _load();
                          }),
                          child: Text(_label('上一页', 'Previous')),
                        ),
                      if (rows.length > _pageSize)
                        TextButton(
                          onPressed: () => setState(() {
                            _offset += _pageSize;
                            _load();
                          }),
                          child: Text(_label('下一页', 'Next')),
                        ),
                      if (rows.isEmpty) Text(_label('暂无确认记录', 'No reviews')),
                    ],
                  );
                }
                final row = rows[index - 1];
                final choices = row['layer'] == 'work' && row['state'] == 'pending' &&
                    !['request_failed', 'query_incomplete', 'invalid_response'].contains(row['reason'])
                    ? ScanRecognition.candidates(row) : const <Map<String, dynamic>>[];
                if (!_advanced && choices.isNotEmpty) {
                  return Card(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    ListTile(title: Text(row['raw_path'] as String),
                      subtitle: Text(row['provider'] == 'tmdb' ? 'TMDB' : 'Bangumi')),
                    for (final choice in choices)
                      ListTile(
                        leading: switch (choice['poster']) {
                          final String poster when MetadataServers.imageResource(poster) != null =>
                            ManagedImage(poster, width: 36, height: 52, fit: BoxFit.cover, decodeWidth: 108),
                          _ => const Icon(Icons.movie_outlined),
                        },
                        title: Text(_choice(choice)),
                        trailing: const Icon(Icons.check),
                        onTap: () => _apply(() => widget.runner.recognition.decide(row, choice)),
                      ),
                  ]));
                }
                return Card(
                  child: ListTile(
                    onTap: () => _inspect(row),
                    title: Text(row['raw_path'] as String),
                    subtitle: Text(
                      [
                        _layer(row['layer']),
                        if (row['provider'] != null)
                          row['provider'] == 'tmdb' ? 'TMDB' : 'Bangumi',
                        switch (row['state']) {
                          'confirmed' =>
                            row['reason'] == 'mapping_changed'
                                ? _reason(row['reason'])
                                : _label('已采用', 'Adopted'),
                          'skipped' => _label('已跳过', 'Skipped'),
                          _ => _reason(row['reason']),
                        },
                      ].join(' · '),
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
