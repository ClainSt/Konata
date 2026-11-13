import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';

import '../core/scan_activity.dart';

/// Present works first; low-level jobs remain available in the expanded row.
enum _TaskGroup { review, incomplete, noCandidates, active, finished }

class ScrapeWorkPanel extends StatefulWidget {
  const ScrapeWorkPanel({super.key, required this.tasks, required this.onAction,
    required this.onReview, required this.onRetryWork});
  final List<Map<String, Object?>> tasks;
  final void Function(String id, String action) onAction;
  final void Function(String work) onReview;
  final void Function(String work) onRetryWork;
  @override
  State<ScrapeWorkPanel> createState() => _ScrapeWorkPanelState();
}

class _ScrapeWorkPanelState extends State<ScrapeWorkPanel> {
  _TaskGroup? _selected;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final zh = Localizations.localeOf(context).languageCode == 'zh';
    String text(String cn, String en) => zh ? cn : en;
    final groups = <String, List<Map<String, Object?>>>{};
    for (final task in widget.tasks) {
      groups.putIfAbsent('${task['work_id'] ?? task['id']}', () => []).add(task);
    }
    _TaskGroup classify(List<Map<String, Object?>> rows) {
      if (rows.any((r) => ['queued', 'running', 'paused'].contains(r['state']))) {
        return _TaskGroup.active;
      }
      if (rows.first['review_error'] != null || rows.any((r) => r['state'] == 'failed')) {
        return _TaskGroup.incomplete;
      }
      if ((rows.first['review_count'] as int? ?? 0) > 0) return _TaskGroup.review;
      if ((rows.first['review_pending'] as int? ?? 0) > 0) return _TaskGroup.noCandidates;
      return _TaskGroup.finished;
    }
    final grouped = {for (final group in _TaskGroup.values)
      group: <MapEntry<String, List<Map<String, Object?>>>>[]};
    for (final entry in groups.entries) {
      grouped[classify(entry.value)]!.add(entry);
    }
    final selected = _selected ??
        _TaskGroup.values.firstWhere((g) => grouped[g]!.isNotEmpty, orElse: () => _TaskGroup.review);
    final visible = grouped[selected]!;
    final labels = {
      _TaskGroup.review: text('候选待确认', 'Candidates to confirm'),
      _TaskGroup.incomplete: text('查询未完成', 'Incomplete'),
      _TaskGroup.noCandidates: text('无候选', 'No candidates'),
      _TaskGroup.active: text('进行中', 'In progress'),
      _TaskGroup.finished: text('已结束', 'Finished'),
    };
    return Column(children: [
      Padding(padding: const EdgeInsets.all(12), child: Wrap(spacing: 12, children: [
        for (final group in _TaskGroup.values)
          ChoiceChip(
            label: Text('${labels[group]} ${grouped[group]!.length}'),
            selected: selected == group,
            selectedColor: colors.primary,
            checkmarkColor: colors.onPrimary,
            labelStyle: selected == group
                ? TextStyle(color: colors.onPrimary, fontWeight: FontWeight.w600)
                : null,
            onSelected: (_) => setState(() => _selected = group),
          ),
      ])),
      Expanded(child: visible.isEmpty ? Center(child: Text(text('暂无任务', 'No tasks'))) :
        ListView.builder(padding: const EdgeInsets.symmetric(horizontal: 16),
          itemCount: visible.length, itemBuilder: (context, index) {
            final entry = visible[index], rows = entry.value, first = rows.first;
            final running = rows.any((r) => r['state'] == 'running');
            final queued = rows.any((r) => r['state'] == 'queued');
            final failed = rows.where((r) => r['state'] == 'failed').firstOrNull;
            final paused = rows.where((r) => r['state'] == 'paused').firstOrNull;
            final reviews = first['review_count'] as int? ?? 0;
            final networkFailure = first['review_error'] != null;
            final noCandidates = selected == _TaskGroup.noCandidates;
            final scanSource = entry.key.startsWith('scan:')
                ? first['source_id'] as String?
                : null;
            final status = running ? text('正在处理', 'Processing') : queued ? text('等待处理', 'Waiting') :
                failed != null ? text('未完成，需要重试', 'Incomplete — retry needed') :
                paused != null ? text('已暂停', 'Paused') : networkFailure ?
                text('平台查询未完成，点击重试', 'Provider query incomplete — retry') : reviews > 0 ?
                text('有 $reviews 项对应尚未确认', '$reviews matches need review') :
                noCandidates ? text('未找到可用候选', 'No usable candidate found') :
                text('任务已结束', 'Tasks finished');
            return Card(child: ExpansionTile(key: PageStorageKey(entry.key),
              title: Text(first['title']?.toString() ?? text('扫描媒体目录', 'Scan media folders')),
              subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(status),
                if (scanSource != null && running)
                  ListenableBuilder(
                    listenable: ScanActivityStore.instance,
                    builder: (context, child) {
                      final scan = ScanActivityStore.instance.forSource(scanSource);
                      if (scan == null) return const SizedBox.shrink();
                      final directories = scan.completedFolders.length;
                      final videos = scan.videoCount;
                      return Text(text(
                        '已扫描 $directories 个目录，发现 $videos 个视频',
                        '$directories folders scanned · $videos videos found',
                      ));
                    },
                  ),
                if (running) const Padding(padding: EdgeInsets.symmetric(vertical: 8),
                    child: LinearProgressIndicator()),
                if (!running && !queued && failed != null)
                  TextButton(onPressed: () => widget.onAction(failed['id'] as String, 'retry'),
                    child: Text(text('重试', 'Retry')))
                else if (!running && !queued && networkFailure && first['work_id'] is String)
                  TextButton(onPressed: () => widget.onRetryWork(first['work_id'] as String),
                    child: Text(text('重试未完成的识别', 'Retry identification')))
                else if (!running && !queued && reviews > 0 && first['work_id'] is String)
                  TextButton(onPressed: () => widget.onReview(first['work_id'] as String),
                    child: Text(text('查看并确认', 'Review matches')))
                else if (noCandidates && first['work_id'] is String)
                  TextButton(onPressed: () => widget.onReview(first['work_id'] as String),
                    child: Text(text('查看详情', 'View details')))
                else if (paused != null)
                  TextButton(onPressed: () => widget.onAction(paused['id'] as String, 'resume'),
                    child: Text(text('继续', 'Resume'))),
              ]),
              children: [for (final task in rows) ListTile(
                title: Text(_jobLabel('${task['id']}', zh)),
                subtitle: Text(switch(task['state']) {
                  'complete' => text('此步骤已结束', 'Step finished'),
                  'running' => text('处理中', 'Running'),
                  'queued' => text('等待处理', 'Waiting'),
                  'failed' => text('未完成', 'Incomplete'),
                  'paused' => text('已暂停', 'Paused'),
                  _ => text('已取消', 'Cancelled'),
                }),
                trailing: PopupMenuButton<String>(onSelected: (action) =>
                    widget.onAction(task['id'] as String, action), itemBuilder: (_) => [
                    if (['queued', 'running'].contains(task['state']))
                      PopupMenuItem(value: 'pause', child: Text(text('暂停', 'Pause'))),
                    if (['paused'].contains(task['state']))
                      PopupMenuItem(value: 'resume', child: Text(text('继续', 'Resume'))),
                    if (['failed', 'cancelled'].contains(task['state']))
                      PopupMenuItem(value: 'retry', child: Text(text('重试', 'Retry'))),
                    if (!['complete', 'cancelled'].contains(task['state']))
                      PopupMenuItem(value: 'cancel', child: Text(text('取消', 'Cancel'))),
                  ]),
              )]));
          })),
    ]);
  }

  String _jobLabel(String id, bool zh) {
    final labels = <String, (String, String)>{
      'scan:': ('扫描文件', 'Scan files'), 'recognize:': ('识别作品与季集', 'Identify work and episodes'),
      'scope:': ('补充季集资料', 'Fetch episode details'), 'art:': ('获取图片', 'Fetch artwork'),
      'metadata:': ('获取作品资料', 'Fetch metadata'), 'specials:': ('核对特别篇', 'Match specials'),
    };
    for (final entry in labels.entries) {
      if (id.startsWith(entry.key)) return zh ? entry.value.$1 : entry.value.$2;
    }
    return zh ? '资料补查' : 'Supplement metadata';
  }
}

/// Pure view: previews never open a database, request media, or start timers.
class ScrapeTaskPanel extends StatelessWidget {
  const ScrapeTaskPanel({
    super.key,
    required this.tasks,
    required this.onAction,
  });
  final List<Map<String, Object?>> tasks;
  final void Function(String id, String action) onAction;
  @override
  Widget build(BuildContext context) {
    final zh = Localizations.localeOf(context).languageCode == 'zh';
    String text(String cn, String en) => zh ? cn : en;
    final states = zh
        ? {
            'queued': '等待处理',
            'running': '处理中',
            'paused': '已暂停',
            'cancelled': '已取消',
            'failed': '待重试',
            'complete': '已完成',
          }
        : {
            'queued': 'Waiting',
            'running': 'Running',
            'paused': 'Paused',
            'cancelled': 'Cancelled',
            'failed': 'Needs retry',
            'complete': 'Complete',
          };
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1000),
        child: tasks.isEmpty
            ? Text(text('暂无刮削任务', 'No scraping tasks'))
            : ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: tasks.length,
                itemBuilder: (context, index) {
                  final task = tasks[index], state = task['state'];
                  return Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            task['title']?.toString() ??
                                text('媒体资料任务', 'Media metadata task'),
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 8),
                          Text(states[state] ?? state.toString()),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              if (state == 'queued')
                                TextButton(
                                  onPressed: () =>
                                      onAction(task['id'] as String, 'run'),
                                  child: Text(text('开始', 'Start')),
                                ),
                              if (['queued', 'running'].contains(state))
                                TextButton(
                                  onPressed: () =>
                                      onAction(task['id'] as String, 'pause'),
                                  child: Text(text('暂停', 'Pause')),
                                ),
                              if (state == 'paused')
                                TextButton(
                                  onPressed: () =>
                                      onAction(task['id'] as String, 'resume'),
                                  child: Text(text('继续', 'Resume')),
                                ),
                              if (['failed', 'cancelled'].contains(state))
                                TextButton(
                                  onPressed: () =>
                                      onAction(task['id'] as String, 'retry'),
                                  child: Text(text('重试', 'Retry')),
                                ),
                              if (!['cancelled', 'complete'].contains(state))
                                TextButton(
                                  onPressed: () =>
                                      onAction(task['id'] as String, 'cancel'),
                                  child: Text(text('取消', 'Cancel')),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
      ),
    );
  }
}

void previewTaskAction(String id, String action) {}
@Preview(
  name: 'Scraping tasks narrow',
  size: Size(320, 600),
  textScaleFactor: 1.8,
)
@Preview(name: 'Scraping tasks wide', size: Size(1100, 700))
Widget scrapeTaskPreview() => MaterialApp(
  home: Scaffold(
    body: ScrapeTaskPanel(
      tasks: const [
        {
          'id': '1',
          'title': 'A long media title / 较长的作品名称',
          'state': 'running',
        },
        {'id': '2', 'title': 'Interrupted metadata request', 'state': 'failed'},
      ],
      onAction: previewTaskAction,
    ),
  ),
);
