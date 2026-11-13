import 'package:flutter/material.dart';
import '../core/scan_recognition.dart';
import '../core/scrape_task_runner.dart';
import 'scrape_task_panel.dart';
import 'scan_reviews_page.dart';

class ScrapeTasksPage extends StatefulWidget {
  const ScrapeTasksPage({
    super.key,
    required this.runner,
    this.sourceId,
  });
  final ScrapeTaskRunner runner;
  final String? sourceId;
  @override
  State<ScrapeTasksPage> createState() => _ScrapeTasksPageState();
}

class _ScrapeTasksPageState extends State<ScrapeTasksPage> {
  late Future<List<Map<String, Object?>>> _rows;
  final _retryingWorks = <String>{};
  @override
  void initState() {
    super.initState();
    _load();
    widget.runner.tasks.addListener(_changed);
  }

  void _load() {
    final reviews = widget.runner.catalog.recognitionEnabled
        ? "(SELECT COUNT(*) FROM scan_bindings b WHERE b.work_id=scrape_tasks.work_id AND b.state='pending' AND b.layer='work' AND json_array_length(b.candidates)>0)"
        : '0';
    final unresolved = widget.runner.catalog.recognitionEnabled
        ? "(SELECT COUNT(*) FROM scan_bindings b WHERE b.work_id=scrape_tasks.work_id AND b.state='pending' AND b.layer='work')"
        : '0';
    final failure = widget.runner.catalog.recognitionEnabled
        ? "(SELECT b.reason FROM scan_bindings b WHERE b.work_id=scrape_tasks.work_id AND b.layer='work' AND b.state='pending' AND b.reason IN ('request_failed','query_incomplete','invalid_response','detail_budget_exhausted') LIMIT 1)"
        : 'NULL';
    _rows = widget.runner.tasks.db.rawQuery(
      '''SELECT scrape_tasks.*,works.title,
      $reviews AS review_count, $unresolved AS review_pending, $failure AS review_error
      FROM scrape_tasks
    LEFT JOIN works ON works.id=scrape_tasks.work_id WHERE ? IS NULL OR scrape_tasks.source_id=? OR scrape_tasks.id LIKE 'mapping:%' ORDER BY updated_at DESC''',
      [widget.sourceId, widget.sourceId],
    );
  }

  void _changed() {
    if (mounted) setState(_load);
  }

  @override
  void dispose() {
    widget.runner.tasks.removeListener(_changed);
    super.dispose();
  }

  Future<void> _action(String id, String action) async {
    try {
      if (action != 'run') await widget.runner.tasks.control(id, action);
      if (action == 'run' || action == 'resume' || action == 'retry') {
        await widget.runner.run(id, manualRetry: action == 'retry');
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              Localizations.localeOf(context).languageCode == 'zh'
                  ? '任务状态已变化，请刷新后重试'
                  : 'Task changed. Refresh and try again.',
            ),
          ),
        );
      }
    }
  }

  Future<void> _retryWork(String work) async {
    if (!_retryingWorks.add(work)) return;
    final zh = Localizations.localeOf(context).languageCode == 'zh';
    void message(String cn, String en) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(zh ? cn : en)));
    }
    try {
      message('正在重新查询未完成的资料…', 'Retrying unfinished metadata…');
      final source = widget.sourceId ?? (await widget.runner.tasks.db.query('scrape_tasks',
        columns: ['source_id'], where: 'id=?', whereArgs: ['recognize:$work'])).single['source_id'] as String;
      final id = await widget.runner.recognition.enqueue(source, work, retry: true);
      await widget.runner.run(id, manualRetry: true);
      final pending = await widget.runner.tasks.db.query('scan_bindings',
        where: "work_id=? AND layer='work' AND state='pending'", whereArgs: [work]);
      if (pending.any((r) => ScanRecognition.workQueryIncomplete(r['reason']))) {
        message('重试后平台查询仍未完成，请检查服务连接或凭据。',
            'Provider query is still incomplete. Check the connection and credentials.');
      } else if (pending.any((r) => ScanRecognition.candidates(r).isNotEmpty)) {
        message('查询已返回，仍有对应需要确认。', 'Query returned. Some matches still need review.');
      } else if (pending.isNotEmpty) {
        message('查询已完成，未找到可用候选。', 'Query finished. No usable candidate was found.');
      } else {
        message('作品身份查询已完成。', 'Work identity query completed.');
      }
    } catch (_) {
      message('未能完成重试，请查看任务状态。', 'Retry could not complete. Check task status.');
    } finally {
      _retryingWorks.remove(work);
      _changed();
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        Localizations.localeOf(context).languageCode == 'zh'
            ? '刮削任务'
            : 'Scraping tasks',
      ),
      actions: [
        if (widget.runner.catalog.recognitionEnabled)
          IconButton(
            tooltip: Localizations.localeOf(context).languageCode == 'zh'
                ? '识别与目录确认'
                : 'Scan review',
            icon: const Icon(Icons.rule_folder_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => ScanReviewsPage(
                  runner: widget.runner,
                  source: widget.sourceId,
                ),
              ),
            ),
          ),
        IconButton(
          onPressed: _changed,
          tooltip: Localizations.localeOf(context).languageCode == 'zh'
              ? '刷新'
              : 'Refresh',
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: FutureBuilder(
      future: _rows,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return const Center(child: Icon(Icons.error_outline));
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        return ScrapeWorkPanel(tasks: snapshot.data!, onAction: _action,
          onRetryWork: _retryWork,
          onReview: (work) => Navigator.of(context).push(MaterialPageRoute<void>(
            builder: (_) => ScanReviewsPage(runner: widget.runner,
                workId: work))));
      },
    ),
  );
}
