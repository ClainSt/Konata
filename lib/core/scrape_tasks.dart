import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'library_foundation.dart';
import 'optional_feature_scope.dart';

class TaskStopped implements Exception {
  const TaskStopped();
}

class TaskPaused implements Exception {
  const TaskPaused();
}

class TaskLease {
  TaskLease(
    this.taskId,
    this.step,
    this.generation,
    this.session,
    this.cacheRevision,
    this.workId,
    this.scope,
    this.bindingRevision,
    this.sourceId,
    this.locationRevision,
    this.fields,
    this.feature,
  );
  final String taskId, step, session;
  final int generation, cacheRevision;
  final String? workId, scope, sourceId;
  final int? bindingRevision, locationRevision;
  final Map<String, int> fields;
  final OptionalFeatureScope? feature;
  final _cancelled = Completer<void>();
  bool get active => !_cancelled.isCompleted && !(feature?.disposed ?? false);
  Future<void> get cancelled => _cancelled.future;
  void check() {
    if (!active) throw const TaskStopped();
  }

  void cancel() {
    if (!_cancelled.isCompleted) _cancelled.complete();
  }
}

/// One database commit authority for task controls, fields and cache publication.
/// No polling/timer. Callers run only on explicit use/resume, with bounded work.
class ScrapeTasks extends ChangeNotifier {
  ScrapeTasks(this.db, this.cacheDirectory, {DateTime Function()? clock})
    : clock = clock ?? DateTime.now {
    _instances[db] = this;
  }
  static final _instances = <Database, ScrapeTasks>{};
  static Future<void> resetAfterRestore(
    Database db,
    Directory directory,
  ) async {
    final existing = _instances[db];
    if (existing != null) {
      await existing.recover();
      return;
    }
    final temporary = ScrapeTasks(db, directory);
    try {
      await temporary.recover();
    } finally {
      temporary.dispose();
    }
  }

  final Database db;
  final Directory cacheDirectory;
  final DateTime Function() clock;
  String _session = '';
  bool _closed = false;
  final _leases = <String, TaskLease>{};
  final _closers = <VoidCallback>[];
  void onClose(VoidCallback close) => _closers.add(close);
  static const portableTables = [
    'scrape_tasks',
    'scrape_steps',
    'scrape_network',
  ];
  static const maxTasks = 5000,
      maxCompleted = 500,
      maxNetwork = 2048,
      maxSteps = 16;
  int get now => clock().toUtc().millisecondsSinceEpoch;

  static Future<void> createSchema(DatabaseExecutor tx) async {
    await tx.execute('''CREATE TABLE scrape_tasks(
      id TEXT PRIMARY KEY, work_id TEXT, source_id TEXT, intent_json TEXT NOT NULL,
      state TEXT NOT NULL CHECK(state IN ('queued','running','paused','cancelled','failed','complete')),
      generation INTEGER NOT NULL DEFAULT 0, updated_at INTEGER NOT NULL)''');
    await tx.execute('''CREATE TABLE scrape_steps(
      task_id TEXT NOT NULL, step TEXT NOT NULL, state TEXT NOT NULL,
      attempts INTEGER NOT NULL DEFAULT 0, not_before INTEGER NOT NULL DEFAULT 0,
      error TEXT, result_json TEXT, PRIMARY KEY(task_id,step))''');
    await tx.execute('''CREATE TABLE scrape_network(
      key TEXT PRIMARY KEY, failures INTEGER NOT NULL, not_before INTEGER NOT NULL,
      category TEXT NOT NULL, updated_at INTEGER NOT NULL)''');
    await tx.execute(
      '''CREATE TABLE scrape_runtime(
      id INTEGER PRIMARY KEY CHECK(id=1), session TEXT NOT NULL, cache_revision INTEGER NOT NULL)''',
    );
    await tx.execute(
      '''CREATE TABLE scrape_cache(
      key TEXT PRIMARY KEY, filename TEXT NOT NULL, bytes INTEGER NOT NULL, created_at INTEGER NOT NULL)''',
    );
    await tx.execute(
      'CREATE INDEX scrape_steps_state ON scrape_steps(state,not_before)',
    );
    await tx.execute(
      '''CREATE TRIGGER scrape_task_removed AFTER DELETE ON scrape_tasks
      BEGIN DELETE FROM scrape_steps WHERE task_id=OLD.id; END''',
    );
    for (final owner in ['work', 'source']) {
      await tx.execute(
        '''CREATE TRIGGER scrape_${owner}_removed AFTER DELETE ON ${owner}s
        BEGIN DELETE FROM scrape_tasks WHERE ${owner}_id=OLD.id; END''',
      );
    }
    await tx.execute(
      '''CREATE TRIGGER scrape_work_hidden AFTER UPDATE OF hidden ON works
      WHEN NEW.hidden=1 BEGIN UPDATE scrape_tasks SET state='cancelled',generation=generation+1
      WHERE work_id=NEW.id; END''',
    );
  }

  /// Also called after restore: runtime use rights never come from a backup.
  Future<void> recover() async {
    for (final lease in _leases.values) {
      lease.cancel();
    }
    _leases.clear();
    _session = LibraryFoundation.newId('session:');
    await db.transaction((tx) async {
      await tx.insert('scrape_runtime', {
        'id': 1,
        'session': _session,
        'cache_revision': 0,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      if ((await tx.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='scan_directory_checkpoints'",
      )).isNotEmpty) {
        await tx.rawUpdate('''UPDATE scan_directory_checkpoints AS d
          SET generation=generation+1 WHERE EXISTS (SELECT 1 FROM scrape_tasks t
          WHERE t.id='scan:' || d.source_id AND t.generation=d.generation
            AND t.state NOT IN ('cancelled','complete'))''');
      }
      await tx.rawUpdate(
        "UPDATE scrape_tasks SET generation=generation+1,state=CASE WHEN state='running' THEN 'queued' ELSE state END",
      );
      await tx.rawUpdate(
        "UPDATE scrape_steps SET state='queued' WHERE state='running'",
      );
      await tx.delete('scrape_cache');
    });
    await cacheDirectory.create(recursive: true);
    await for (final file in cacheDirectory.list(followLinks: false)) {
      if (file is File &&
          RegExp(
            r'^[a-f0-9]{32}\.(part|cache)$',
          ).hasMatch(file.uri.pathSegments.last)) {
        await file.delete();
      }
    }
    _notify();
  }

  void _notify() {
    if (!_closed) notifyListeners();
  }

  @override
  void dispose() {
    _closed = true;
    if (identical(_instances[db], this)) _instances.remove(db);
    for (final lease in _leases.values) {
      lease.cancel();
    }
    _leases.clear();
    for (final close in _closers) {
      close();
    }
    _closers.clear();
    super.dispose();
  }

  Future<String> enqueue(
    String id, {
    String? workId,
    String? sourceId,
    required Map<String, Object?> intent,
    required List<String> steps,
    bool restartComplete = false,
    TaskLease? parentLease,
  }) async {
    if (_closed ||
        id.length > 512 ||
        steps.isEmpty ||
        steps.length > maxSteps ||
        steps.toSet().length != steps.length ||
        steps.any((s) => !RegExp(r'^[a-z0-9_-]{1,64}$').hasMatch(s))) {
      throw ArgumentError('Invalid task intent');
    }
    final encoded = jsonEncode(intent);
    var replaced = false;
    if (encoded.length > 32768) throw ArgumentError('Task intent limit');
    await db.transaction((tx) async {
      if (parentLease != null) await _check(tx, parentLease);
      if (workId != null &&
          (await tx.query(
            'works',
            where: 'id=? AND hidden=0',
            whereArgs: [workId],
          )).isEmpty) {
        throw const TaskStopped();
      }
      if (sourceId != null &&
          (await tx.query(
            'sources',
            where: 'id=?',
            whereArgs: [sourceId],
          )).isEmpty) {
        throw const TaskStopped();
      }
      final old = await tx.query(
        'scrape_tasks',
        where: 'id=?',
        whereArgs: [id],
      );
      if (old.isNotEmpty &&
          old.single['intent_json'] == encoded &&
          !(restartComplete &&
              ['complete', 'cancelled'].contains(old.single['state']))) {
        return;
      }
      if (old.isEmpty) {
        await tx.rawDelete(
          "DELETE FROM scrape_tasks WHERE state IN ('complete','cancelled') AND id NOT IN (SELECT id FROM scrape_tasks WHERE state IN ('complete','cancelled') ORDER BY updated_at DESC LIMIT $maxCompleted)",
        );
        if ((await tx.rawQuery(
                  'SELECT COUNT(*) AS n FROM scrape_tasks',
                )).single['n']
                as int >=
            maxTasks) {
          throw StateError('Task capacity reached');
        }
        await tx.insert('scrape_tasks', {
          'id': id,
          'work_id': workId,
          'source_id': sourceId,
          'intent_json': encoded,
          'state': 'queued',
          'updated_at': now,
        });
      } else {
        replaced = true;
        await tx.update(
          'scrape_tasks',
          {
            'intent_json': encoded,
            'work_id': workId,
            'source_id': sourceId,
            'state': 'queued',
            'generation': (old.single['generation'] as int) + 1,
            'updated_at': now,
          },
          where: 'id=?',
          whereArgs: [id],
        );
        await tx.delete('scrape_steps', where: 'task_id=?', whereArgs: [id]);
      }
      for (final step in steps) {
        await tx.insert('scrape_steps', {
          'task_id': id,
          'step': step,
          'state': 'queued',
        });
      }
    });
    if (replaced) _leases[id]?.cancel();
    _notify();
    return id;
  }

  Future<List<Map<String, Object?>>> list({String? sourceId}) => db.query(
    'scrape_tasks',
    where: sourceId == null ? null : 'source_id=?',
    whereArgs: sourceId == null ? null : [sourceId],
    orderBy: 'updated_at DESC',
    limit: 200,
  );

  Future<void> control(
    String id,
    String action, {
    int? expectedGeneration,
  }) async {
    if (!['pause', 'resume', 'cancel', 'retry'].contains(action)) {
      throw ArgumentError('Invalid task action');
    }
    var revoke = false;
    await db.transaction((tx) async {
      final rows = await tx.query(
        'scrape_tasks',
        where: 'id=?',
        whereArgs: [id],
      );
      if (rows.isEmpty) return;
      final old = rows.single;
      if (expectedGeneration != null &&
          old['generation'] != expectedGeneration) {
        return;
      }
      if (old['state'] == 'complete') return;
      if (action == 'pause' && !['queued', 'running'].contains(old['state'])) {
        return;
      }
      if (action == 'resume' && old['state'] != 'paused') return;
      if (action == 'retry' &&
          !['failed', 'cancelled'].contains(old['state'])) {
        return;
      }
      revoke = action == 'cancel' || action == 'retry';
      if (action == 'retry' &&
          old['state'] == 'failed' &&
          (jsonDecode(old['intent_json'] as String) as Map)['incremental'] ==
              true) {
        await tx.rawUpdate(
          '''UPDATE scan_directory_checkpoints
          SET generation=generation+1 WHERE source_id=? AND generation=?''',
          [old['source_id'], old['generation']],
        );
      }
      await tx.update(
        'scrape_tasks',
        {
          'state': action == 'pause'
              ? 'paused'
              : action == 'cancel'
              ? 'cancelled'
              : action == 'resume' && (_leases[id]?.active ?? false)
              ? 'running'
              : 'queued',
          'generation': (old['generation'] as int) + (revoke ? 1 : 0),
          'updated_at': now,
        },
        where: 'id=?',
        whereArgs: [id],
      );
      if (action == 'retry') {
        await tx.rawUpdate(
          "UPDATE scrape_steps SET state='queued' WHERE task_id=? AND state!='complete'",
          [id],
        );
      }
    });
    if (revoke) _leases[id]?.cancel();
    _notify();
  }

  Future<TaskLease?> claim(
    String id,
    String step, {
    bool dependsOnLocation = false,
    List<String> fields = const [],
    OptionalFeatureScope? feature,
    bool manualRetry = false,
  }) async {
    if (_closed) throw const TaskStopped();
    feature?.checkActive();
    final lease = await db.transaction((tx) async {
      final rows = await tx.query(
        'scrape_tasks',
        where: 'id=?',
        whereArgs: [id],
      );
      if (rows.isEmpty || rows.single['state'] != 'queued') return null;
      final task = rows.single;
      final steps = await tx.query(
        'scrape_steps',
        where: 'task_id=? AND step=?',
        whereArgs: [id, step],
      );
      if (steps.isEmpty ||
          steps.single['state'] == 'running' ||
          steps.single['state'] == 'complete' ||
          (!manualRetry && (steps.single['not_before'] as int) > now)) {
        return null;
      }
      final workId = task['work_id'] as String?;
      String? scope;
      int? binding;
      final versions = <String, int>{};
      if (workId != null) {
        final works = await tx.query(
          'works',
          where: 'id=? AND hidden=0',
          whereArgs: [workId],
        );
        if (works.isEmpty) throw const TaskStopped();
        scope = LibraryFoundation.scope(works.single);
        final intent = jsonDecode(task['intent_json'] as String) as Map;
        if (intent['scope'] != null && intent['scope'] != scope) {
          throw const TaskStopped();
        }
        await LibraryFoundation.seedWork(tx, works.single);
        binding =
            (await tx.query(
                  'library_work_protection',
                  where: 'work_id=?',
                  whereArgs: [workId],
                )).single['revision']
                as int;
        for (final name in fields) {
          final row = (await tx.query(
            'library_fields',
            where: 'work_id=? AND scope=? AND field=?',
            whereArgs: [workId, scope, name],
          )).single;
          versions[name] = row['automatic_revision'] as int;
        }
      }
      final runtime = (await tx.query('scrape_runtime')).single;
      if (runtime['session'] != _session) throw const TaskStopped();
      final sourceId = task['source_id'] as String?;
      final revision = dependsOnLocation && sourceId != null
          ? await LibraryFoundation.sourceRevision(tx, sourceId)
          : null;
      await tx.update(
        'scrape_tasks',
        {'state': 'running', 'updated_at': now},
        where: 'id=?',
        whereArgs: [id],
      );
      await tx.update(
        'scrape_steps',
        {'state': 'running', 'attempts': (steps.single['attempts'] as int) + 1},
        where: 'task_id=? AND step=?',
        whereArgs: [id, step],
      );
      return TaskLease(
        id,
        step,
        task['generation'] as int,
        _session,
        runtime['cache_revision'] as int,
        workId,
        scope,
        binding,
        sourceId,
        revision,
        versions,
        feature,
      );
    });
    if (lease != null) {
      _leases[id] = lease;
      feature?.acquire(() => lease, (l) => l.cancel());
    }
    _notify();
    return lease;
  }

  Future<String> _check(
    DatabaseExecutor tx,
    TaskLease lease, {
    bool cache = false,
  }) async {
    lease.check();
    if (_closed) throw const TaskStopped();
    final runtime = (await tx.query('scrape_runtime')).single;
    final rows = await tx.query(
      'scrape_tasks',
      where: 'id=?',
      whereArgs: [lease.taskId],
    );
    if (runtime['session'] != lease.session ||
        rows.isEmpty ||
        rows.single['generation'] != lease.generation ||
        !['running', 'paused'].contains(rows.single['state']) ||
        (cache && runtime['cache_revision'] != lease.cacheRevision)) {
      throw const TaskStopped();
    }
    if (lease.workId != null) {
      final works = await tx.query(
        'works',
        where: 'id=? AND hidden=0',
        whereArgs: [lease.workId],
      );
      final protection = await tx.query(
        'library_work_protection',
        where: 'work_id=?',
        whereArgs: [lease.workId],
      );
      if (works.isEmpty ||
          protection.isEmpty ||
          LibraryFoundation.scope(works.single) != lease.scope ||
          protection.single['revision'] != lease.bindingRevision) {
        throw const TaskStopped();
      }
    }
    if (lease.locationRevision != null) {
      await LibraryFoundation.checkSource(
        tx,
        lease.sourceId!,
        lease.locationRevision!,
      );
    }
    lease.check();
    return rows.single['state'] as String;
  }

  Future<bool> valid(TaskLease lease, {bool cache = false}) async {
    try {
      await db.transaction((tx) => _check(tx, lease, cache: cache));
      return true;
    } catch (_) {
      return false;
    }
  }

  /// For owned index publication inside the same transaction as its checkpoint.
  Future<void> checkIn(
    DatabaseExecutor tx,
    TaskLease lease, {
    bool cache = false,
  }) => _check(tx, lease, cache: cache);

  Future<void> beforeNextRequest(TaskLease lease) async {
    lease.check();
    await db.transaction((tx) async {
      if (await _check(tx, lease) == 'paused') {
        throw const TaskPaused();
      }
    });
  }

  Future<void> park(TaskLease lease) async {
    await db.transaction((tx) async {
      await _check(tx, lease);
      await tx.rawUpdate(
        "UPDATE scrape_tasks SET state=CASE WHEN state='paused' THEN state ELSE 'queued' END WHERE id=?",
        [lease.taskId],
      );
      await tx.update(
        'scrape_steps',
        {'state': 'queued'},
        where: 'task_id=? AND step=?',
        whereArgs: [lease.taskId, lease.step],
      );
    });
    release(lease);
    _notify();
  }

  void release(TaskLease lease) {
    if (identical(_leases[lease.taskId], lease)) _leases.remove(lease.taskId);
    lease.feature?.release(lease);
    lease.cancel();
  }

  Future<Map<String, String>> commitFields(
    TaskLease lease,
    Map<String, Object?> values,
  ) async {
    final outcomes = <String, String>{};
    await commit(lease, (tx) async {
      if (lease.workId == null) throw const TaskStopped();
      for (final entry in values.entries) {
        if (!lease.fields.containsKey(entry.key)) {
          throw ArgumentError('Uncaptured field');
        }
        final row = (await tx.query(
          'library_fields',
          where: 'work_id=? AND scope=? AND field=?',
          whereArgs: [lease.workId, lease.scope, entry.key],
        )).single;
        if (row['automatic_revision'] != lease.fields[entry.key]) {
          outcomes[entry.key] = 'superseded';
          continue;
        }
        await LibraryFoundation(db).writeField(
          lease.workId!,
          entry.key,
          expectedScope: lease.scope!,
          expectedBindingRevision: lease.bindingRevision!,
          expectedRevision: lease.fields[entry.key]!,
          mode: 'auto',
          value: entry.value,
          automatic: true,
          source: lease.step,
          executor: tx,
        );
        outcomes[entry.key] = row['mode'] == 'auto' ? 'adopted' : 'draft_only';
      }
      return outcomes;
    });
    return outcomes;
  }

  Future<void> commit(
    TaskLease lease,
    Future<Map<String, Object?>> Function(DatabaseExecutor) write,
  ) async {
    await db.transaction((tx) async {
      await _check(tx, lease);
      final result = await write(tx);
      final encoded = jsonEncode(result);
      if (encoded.length > 32768) throw StateError('Step result limit');
      await tx.update(
        'scrape_steps',
        {'state': 'complete', 'error': null, 'result_json': encoded},
        where: 'task_id=? AND step=?',
        whereArgs: [lease.taskId, lease.step],
      );
      final pending = await tx.query(
        'scrape_steps',
        where: "task_id=? AND state!='complete'",
        whereArgs: [lease.taskId],
        limit: 1,
      );
      await tx.rawUpdate(
        "UPDATE scrape_tasks SET state=CASE WHEN ?=1 THEN 'complete' WHEN state='paused' THEN 'paused' ELSE 'queued' END,updated_at=? WHERE id=?",
        [pending.isEmpty ? 1 : 0, now, lease.taskId],
      );
      // Final synchronous lifetime check is the publication linearization point.
      lease.check();
    });
    release(lease);
    _notify();
  }

  Future<void> checkpoint(
    TaskLease lease,
    Map<String, Object?> checkpoint,
  ) async {
    final encoded = jsonEncode(checkpoint);
    if (encoded.length > 32768) throw StateError('Step checkpoint limit');
    await db.transaction((tx) async {
      await _check(tx, lease, cache: true);
      await tx.update(
        'scrape_steps',
        {'result_json': encoded},
        where: "task_id=? AND step=? AND state='running'",
        whereArgs: [lease.taskId, lease.step],
      );
      lease.check();
    });
  }

  Future<void> fail(
    TaskLease lease,
    String category, {
    int notBefore = 0,
  }) async {
    try {
      await db.transaction((tx) async {
        await _check(tx, lease);
        await tx.update(
          'scrape_steps',
          {'state': 'failed', 'error': category, 'not_before': notBefore},
          where: 'task_id=? AND step=?',
          whereArgs: [lease.taskId, lease.step],
        );
        await tx.rawUpdate(
          "UPDATE scrape_tasks SET state=CASE WHEN state='paused' THEN state ELSE 'failed' END,updated_at=? WHERE id=?",
          [now, lease.taskId],
        );
        lease.check();
      });
    } on TaskStopped {
      /* Cancellation wins. */
    } finally {
      release(lease);
      _notify();
    }
  }

  /// Immutable filenames plus transactional registration make crash leftovers
  /// disposable; no caller-supplied filesystem path is ever renamed/deleted.
  Future<File> publishCache(
    TaskLease lease,
    String key,
    List<int> bytes,
  ) async {
    if (bytes.length > 4 * 1024 * 1024) throw StateError('Cache entry limit');
    await cacheDirectory.create(recursive: true);
    final name = LibraryFoundation.newId('');
    final part = File('${cacheDirectory.path}/$name.part');
    final target = File('${cacheDirectory.path}/$name.cache');
    String? previous;
    await part.writeAsBytes(bytes, flush: true);
    try {
      await db.transaction((tx) async {
        await _check(tx, lease, cache: true);
        final old = await tx.query(
          'scrape_cache',
          where: 'key=?',
          whereArgs: [key],
        );
        previous = old.isEmpty ? null : old.single['filename'] as String;
        final total =
            (await tx.rawQuery(
                  'SELECT COALESCE(SUM(bytes),0) AS n FROM scrape_cache',
                )).single['n']
                as int;
        if (total -
                    (old.isEmpty ? 0 : old.single['bytes'] as int) +
                    bytes.length >
                32 * 1024 * 1024 ||
            (old.isEmpty &&
                (await tx.query('scrape_cache', columns: ['key'])).length >=
                    128)) {
          throw StateError('Cache capacity reached');
        }
        part.renameSync(target.path);
        // The old immutable file is removed only after the registry commits.
        await tx.insert('scrape_cache', {
          'key': key,
          'filename': '$name.cache',
          'bytes': bytes.length,
          'created_at': now,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
        lease.check();
      });
      if (previous != null &&
          RegExp(r'^[a-f0-9]{32}\.cache$').hasMatch(previous!)) {
        final oldFile = File('${cacheDirectory.path}/$previous');
        try {
          if (oldFile.existsSync()) oldFile.deleteSync();
        } on FileSystemException {
          // Recovery retries orphan cleanup; never delete the committed file.
        }
      }
      return target;
    } catch (_) {
      if (await target.exists()) await target.delete();
      rethrow;
    } finally {
      if (await part.exists()) await part.delete();
    }
  }

  Future<void> clearCache() async {
    await db.transaction((tx) async {
      await tx.rawUpdate(
        'UPDATE scrape_runtime SET cache_revision=cache_revision+1',
      );
      final rows = await tx.query('scrape_cache');
      await tx.delete('scrape_cache');
      for (final row in rows) {
        final file = File('${cacheDirectory.path}/${row['filename']}');
        if (file.existsSync()) file.deleteSync();
      }
    });
    _notify();
  }

  static void validateSnapshot(Map<String, dynamic> data) {
    final tasks = data['scrape_tasks'] as List,
        steps = data['scrape_steps'] as List,
        network = data['scrape_network'] as List;
    if (tasks.length > maxTasks ||
        steps.length > maxTasks * maxSteps ||
        network.length > maxNetwork) {
      throw const FormatException('Task snapshot limit');
    }
    final works = {for (final r in data['works'] as List) r['id']},
        sources = {for (final r in data['sources'] as List) r['id']};
    final ids = <String>{}, keys = <String>{};
    for (final r in tasks) {
      if (r['id'] is! String ||
          !ids.add(r['id']) ||
          r['id'].length > 512 ||
          (r['work_id'] != null && !works.contains(r['work_id'])) ||
          (r['source_id'] != null && !sources.contains(r['source_id'])) ||
          ![
            'queued',
            'running',
            'paused',
            'cancelled',
            'failed',
            'complete',
          ].contains(r['state']) ||
          r['generation'] is! int ||
          r['generation'] < 0 ||
          r['updated_at'] is! int ||
          r['intent_json'] is! String ||
          r['intent_json'].length > 32768 ||
          jsonDecode(r['intent_json']) is! Map) {
        throw const FormatException('Invalid task');
      }
    }
    final counts = <String, int>{};
    for (final r in steps) {
      if (!ids.contains(r['task_id']) ||
          r['step'] is! String ||
          !RegExp(r'^[a-z0-9_-]{1,64}$').hasMatch(r['step']) ||
          !keys.add(jsonEncode([r['task_id'], r['step']])) ||
          !['queued', 'running', 'failed', 'complete'].contains(r['state']) ||
          r['attempts'] is! int ||
          r['attempts'] < 0 ||
          r['not_before'] is! int ||
          r['not_before'] < 0 ||
          (r['result_json'] != null &&
              (r['result_json'] is! String ||
                  r['result_json'].length > 32768 ||
                  jsonDecode(r['result_json']) is! Map))) {
        throw const FormatException('Invalid task step');
      }
      counts.update(r['task_id'], (v) => v + 1, ifAbsent: () => 1);
    }
    if (ids.any((id) => (counts[id] ?? 0) == 0 || counts[id]! > maxSteps)) {
      throw const FormatException('Incomplete task');
    }
    keys.clear();
    for (final r in network) {
      if (r['key'] is! String ||
          !RegExp(r'^(resource|service):[a-f0-9]{64}$').hasMatch(r['key']) ||
          !keys.add(r['key']) ||
          r['failures'] is! int ||
          r['failures'] < 1 ||
          r['not_before'] is! int ||
          r['not_before'] < 0 ||
          r['updated_at'] is! int ||
          ![
            'transport',
            'timeout',
            'protocol',
            'rate_limit',
            'authentication',
            'not_found',
          ].contains(r['category'])) {
        throw const FormatException('Invalid retry control');
      }
    }
  }
}
