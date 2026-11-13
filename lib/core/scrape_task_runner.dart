import 'dart:async';
import 'dart:convert';
import 'package:flutter/widgets.dart';
import 'catalog.dart';
import 'debug_log.dart';
import 'library_foundation.dart';
import 'metadata.dart';
import 'metadata_servers.dart';
import 'scrape_tasks.dart';
import 'selected_scanner.dart';
import 'scan_activity.dart';
import 'anime_mapping_acquisition.dart';
import 'anime_mapping_store.dart';
import 'shared_metadata_requests.dart';
import 'incremental_scan.dart';
import 'scan_recognition.dart';
import 'scoped_artwork.dart';
import 'player_fullscreen.dart';

class _ScanTiming {
  final id = DebugLog.newId('scan');
  final elapsed = Stopwatch()..start();
  final firstRequest = Completer<void>();
  final jobs = <String>{};
}

class ScrapeTaskRunner {
  static const maxConcurrentWorks = 6;
  ScrapeTaskRunner(this.catalog, {SharedMetadataRequests? requests})
    : tasks = catalog.taskStore!,
      requests = requests ?? SharedMetadataRequests(catalog.taskStore!) {
    this.requests.onRequestStart = _recordFirstScanRequest;
    tasks.onClose(this.requests.close);
    tasks.onClose(_scanTimings.clear);
  }
  static final _runners = Expando<ScrapeTaskRunner>();
  static ScrapeTaskRunner forCatalog(Catalog catalog) =>
      _runners[catalog.taskStore!] ??= ScrapeTaskRunner(catalog);
  final Catalog catalog;
  final ScrapeTasks tasks;
  final SharedMetadataRequests requests;
  ScanRecognition get recognition => ScanRecognition(catalog, requests);
  ScopedArtwork get artwork => ScopedArtwork(catalog, requests);
  final _running = <String>{};
  final _scanTimings = <String, _ScanTiming>{};
  bool _background = false, _draining = false, _closed = false;
  bool _resumeRequested = false;

  bool get _ready => !_closed && AnimeMappingStore.foregroundAvailable;

  @visibleForTesting
  bool get isIdle => !_draining && _running.isEmpty;

  void _recordFirstScanRequest(TaskLease lease) {
    final timing = _scanTimings[lease.sourceId];
    if (timing == null || !timing.jobs.contains(lease.taskId)) return;
    _scanTimings.remove(lease.sourceId);
    timing.elapsed.stop();
    DebugLog.event('ScrapeScan', 'first_scrape_request', {
      'source': lease.sourceId,
      'scan': timing.id,
      'elapsedMs': timing.elapsed.elapsedMilliseconds,
    }, level: 'INFO');
    timing.firstRequest.complete();
  }

  void startAutomaticQueue() {
    if (_background) return;
    _background = true;
    final listener = AppLifecycleListener(onStateChange: (_) => _resume());
    playingHeader.addListener(_resume);
    tasks.onClose(() {
      _closed = true;
      listener.dispose();
      playingHeader.removeListener(_resume);
    });
    _wake();
  }

  void _resume() {
    if (!_ready) return;
    if (_draining) {
      _resumeRequested = true;
    } else {
      _wake();
    }
  }

  void _wake() {
    if (!_background || !_ready || _draining) return;
    unawaited(_drain());
  }

  Future<void> _drain() async {
    _draining = true;
    requests.beginRecognitionBatch();
    final attempted = <String>{};
    final active = <String, Future<void>>{};
    void start(String id) {
      attempted.add(id);
      active[id] = run(id).catchError((Object error, StackTrace stack) {
        if (!_closed) {
          FlutterError.reportError(FlutterErrorDetails(
            exception: error, stack: stack, library: 'scraping queue'));
        }
      }).whenComplete(() { active.remove(id); });
    }
    try {
      while (_ready) {
        if (active.length >= maxConcurrentWorks) {
          await Future.any(active.values.toList());
          continue;
        }
        final queued = await tasks.db.rawQuery(
          """SELECT DISTINCT t.id FROM scrape_tasks t
          JOIN scrape_steps s ON s.task_id=t.id
          WHERE t.state='queued' AND s.state='queued' AND s.not_before<=?
          AND (t.id LIKE 'scan:%' OR t.id LIKE 'recognize:%'
            OR t.id LIKE 'scope:%' OR t.id LIKE 'art:poster:%')
          ORDER BY t.updated_at""",
          [tasks.now],
        );
        final ready = queued
            .map((row) => row['id'] as String)
            .where((id) => !_running.contains(id) && !attempted.contains(id))
            .toList();
        if (ready.isEmpty) {
          if (active.isNotEmpty) {
            await Future.any(active.values.toList());
            continue;
          }
          final sources = await tasks.db.rawQuery(
            """SELECT DISTINCT l.source_id FROM scan_bindings b
            JOIN library_locations l ON l.kind='work' AND l.entity_id=b.work_id
            JOIN works w ON w.id=b.work_id AND w.hidden=0
            WHERE b.layer='work' AND b.state='pending' AND b.reason='unsearched'
            AND NOT EXISTS (SELECT 1 FROM scrape_tasks t WHERE t.id='recognize:' || b.work_id)""",
          );
          var scheduled = 0;
          for (final source in sources) {
            if (!_ready) break;
            scheduled += (await recognition.schedule(
              source['source_id'] as String,
              newJobsOnly: true,
            )).length;
          }
          if (scheduled == 0) break;
          continue;
        }
        final scans = ready.where((id) => id.startsWith('scan:'));
        if (scans.isNotEmpty) {
          // Scans update shared inventory: finish current readers first.
          if (active.isNotEmpty) {
            await Future.wait(active.values.toList());
          } else {
            requests.endRecognitionBatch();
            attempted.add(scans.first);
            await run(scans.first);
            requests.beginRecognitionBatch();
          }
          continue;
        }
        for (final id in ready.take(maxConcurrentWorks - active.length)) {
          start(id);
        }
      }
    } catch (error, stack) {
      if (!_closed)
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: error,
            stack: stack,
            library: 'scraping queue',
          ),
        );
    } finally {
      if (active.isNotEmpty) await Future.wait(active.values.toList());
      requests.endRecognitionBatch();
      _draining = false;
      if (_resumeRequested) {
        _resumeRequested = false;
        _wake();
      }
    }
  }

  Future<void> refreshMappingIndex() async {
    final mapping = AnimeMappingAcquisition(catalog.mappingStore!, requests);
    final discovery = await mapping.enqueueDiscovery();
    await tasks.control(discovery, 'retry');
    await run(discovery);
    final result = await tasks.db.query(
      'scrape_steps',
      where: "task_id=? AND state='complete'",
      whereArgs: [discovery],
    );
    if (result.isEmpty) return;
    final version =
        (jsonDecode(result.single['result_json'] as String) as Map)['version']
            as String;
    if ((await tasks.db.query('mapping_index')).single['index_version'] !=
        version) {
      await run(await mapping.enqueue(version, 'index'));
    }
  }

  Future<String> enqueueScan(String sourceId) async {
    if (await catalog.sourceNeedsAssociation(sourceId)) {
      throw StateError('Confirm the restored media source before scanning');
    }
    final roots = catalog.rootsFor(sourceId);
    if (roots.isEmpty) throw StateError('No selected roots');
    return tasks.enqueue(
      'scan:$sourceId',
      sourceId: sourceId,
      intent: {
        'kind': 'scan',
        if (catalog.recognitionEnabled) 'incremental': true,
        'revision': await LibraryFoundation.sourceRevision(tasks.db, sourceId),
        'roots': [
          for (final r in roots)
            {'relative_path': r['relative_path'], 'mode': r['mode']},
        ],
      },
      steps: ['enumerate', 'schedule_metadata'],
      restartComplete: true,
    );
  }

  Future<List<String>> enqueueMetadata(
    String sourceId, {
    Set<String>? workIds,
  }) async {
    final works = await tasks.db.rawQuery(
      '''SELECT DISTINCT works.* FROM works JOIN assets ON assets.work_id=works.id
      WHERE assets.source_id=? AND works.hidden=0 AND works.manual_lock=0''',
      [sourceId],
    );
    final ids = <String>[];
    for (final work in works) {
      if (workIds != null && !workIds.contains(work['id'])) continue;
      final steps = [
        if (work['tmdb_id'] != null) 'tmdb',
        if (work['bangumi_id'] != null) 'bangumi',
      ];
      if (steps.isEmpty) continue;
      ids.add(
        await tasks.enqueue(
          'metadata:${work['id']}',
          workId: work['id'] as String,
          sourceId: sourceId,
          intent: {'kind': 'metadata', 'scope': LibraryFoundation.scope(work)},
          steps: steps,
        ),
      );
    }
    return ids;
  }

  MetadataResource _resource(String step, Map<String, Object?> work) {
    final index = step == 'tmdb' ? 0 : 2;
    final path = step == 'tmdb'
        ? '${work['tmdb_type'] ?? 'tv'}/${work['tmdb_id']}'
        : 'subjects/${work['bangumi_id']}';
    final headers = <String, String>{'Accept': 'application/json'};
    final parameters = <String, String>{};
    if (step == 'tmdb') {
      final credentials = Metadata.credentials;
      if (!credentials.isConfigured) {
        throw const MetadataFailure('missing_credentials', 0);
      }
      headers.addAll(credentials.headers);
      if (credentials.mode == 'apiKey') {
        parameters['api_key'] = credentials.value.trim();
      }
      parameters['language'] = 'zh-CN';
    }
    return MetadataResource(
      service: step,
      resource: path,
      routes: MetadataServers.routes(index, path),
      headers: headers,
      parameters: parameters,
      trustCustom: step == 'tmdb' && MetadataServers.trustCustomTmdb,
      accept: (body) {
        final title = step == 'tmdb'
            ? (body['name'] ?? body['title'])
            : (body['name_cn'] ?? body['name']);
        final overview = body[step == 'tmdb' ? 'overview' : 'summary'];
        return body['id'] == work[step == 'tmdb' ? 'tmdb_id' : 'bangumi_id'] &&
            title is String &&
            title.trim().isNotEmpty &&
            (overview == null || overview is String);
      },
    );
  }

  Future<void> run(String id, {bool manualRetry = false}) async {
    if (!_running.add(id)) return;
    final recognition = ScanRecognition(catalog, requests, manualRetry: manualRetry);
    Future<void>? priorityJobs;
    try {
      final rows = await tasks.db.query(
        'scrape_tasks',
        where: 'id=?',
        whereArgs: [id],
      );
      if (rows.isEmpty) return;
      final task = rows.single;
      final intent = jsonDecode(task['intent_json'] as String) as Map;
      if (intent['kind'] == 'mapping' && catalog.mappingStore != null) {
        await AnimeMappingAcquisition(catalog.mappingStore!, requests).run(id);
        if (catalog.recognitionEnabled &&
            ['detail', 'bulk', 'index'].contains(intent['operation'])) {
          await recognition.auditMappings();
        }
        return;
      }
      final steps = await tasks.db.query(
        'scrape_steps',
        where: 'task_id=?',
        whereArgs: [id],
        orderBy: 'rowid',
      );
      for (final stepRow in steps) {
        if (stepRow['state'] == 'complete') continue;
        final step = stepRow['step'] as String;
        TaskLease? lease;
        try {
          lease = await tasks.claim(
            id,
            step,
            dependsOnLocation: [
              'scan',
              'recognition',
              'scope_evidence',
              'tmdb_specials',
            ].contains(intent['kind']),
            manualRetry: manualRetry,
            fields: intent['kind'] == 'metadata'
                ? ['title', 'overview', 'year']
                : [],
          );
        } on TaskStopped {
          await tasks.control(
            id,
            'cancel',
            expectedGeneration: task['generation'] as int,
          );
          return;
        }
        if (lease == null) return;
        try {
          if (step == 'enumerate') {
            if (await catalog.sourceNeedsAssociation(
              task['source_id'] as String,
            )) {
              throw const TaskPaused();
            }
            if (intent['revision'] != lease.locationRevision) {
              throw const TaskStopped();
            }
            final source = (await tasks.db.query(
              'sources',
              where: 'id=?',
              whereArgs: [task['source_id']],
            )).single;
            final roots = [
              for (final r in intent['roots'] as List)
                Map<String, Object?>.from(r as Map),
            ];
            if (intent['incremental'] == true) {
              final scanLease = lease;
              final sourceId = scanLease.sourceId!;
              final timing = _scanTimings[sourceId] = _ScanTiming();
              try {
                await IncrementalScan(catalog).run(
                  scanLease, source, roots,
                  timingId: timing.id,
                  startPriority: catalog.automaticRecognition ? (works) async {
                    if (works.isEmpty) return;
                    await recognition.schedule(
                      sourceId, lease: scanLease, newJobsOnly: true, priorityWorks: works,
                    );
                    final queued = await tasks.db.query('scrape_tasks', columns: ['id'],
                      where: "state='queued' AND id IN (${List.filled(works.length, '?').join(',')})",
                      whereArgs: works.map((work) => 'recognize:$work').toList(),
                    );
                    final jobs = queued.map((row) => row['id'] as String).toList();
                    if (jobs.isEmpty) return;
                    await tasks.beforeNextRequest(scanLease);
                    timing.jobs.addAll(jobs);
                    final started = Future.wait(jobs.map((job) => run(job)))
                        .then<void>((_) {});
                    priorityJobs = started;
                    await Future.any([started, timing.firstRequest.future, scanLease.cancelled]);
                  } : null,
                );
              } catch (_) {
                if (identical(_scanTimings[sourceId], timing)) _scanTimings.remove(sourceId);
                rethrow;
              }
              continue;
            }
            final result = await SelectedScanner.scanDetailed(
              source,
              savedRoots: roots,
              checkActive: lease.check,
              beforeFolder: () => tasks.beforeNextRequest(lease!),
            );
            await tasks.commit(
              lease,
              (tx) async => {
                'works': result.workIds.length,
                'videos': result.videoCount,
              },
            );
          } else if (step == 'schedule_metadata') {
            // Enqueue is idempotent, so a crash between enqueue and checkpoint is safe.
            if (intent['revision'] != lease.locationRevision) {
              throw const TaskStopped();
            }
            final source = task['source_id'] as String;
            final List<String> children;
            if (intent['incremental'] == true) {
              final row = (await tasks.db.query('scrape_steps', columns: ['result_json'],
                where: "task_id=? AND step='enumerate'", whereArgs: [id],
              )).single;
              final publication = jsonDecode(row['result_json'] as String? ?? '{}') as Map;
              final priority = (publication['priority_works'] as List? ?? []).cast<String>().toSet();
              children = await recognition.schedule(source, lease: lease, skipWorks: priority);
              _scanTimings[source]?.jobs.addAll(children);
            } else {
              children = await enqueueMetadata(source);
            }
            await tasks.commit(
              lease,
              (tx) async => {'scheduled': children.length},
            );
            if (!_background) {
              await priorityJobs;
              for (final child in children) {
                await run(child);
              }
            }
            if (children.isEmpty && priorityJobs == null) _scanTimings.remove(source);
          } else if (step == 'scoped_artwork') {
            await artwork.run(lease, intent);
          } else if (step == 'recognize') {
            await recognition.run(lease);
            if (catalog.automaticRecognition) {
              final specials = await recognition.enqueueSpecials(
                lease.sourceId!,
                lease.workId!,
              );
              if (specials != null && !_background) await run(specials);
            }
            if (catalog.automaticRecognition && catalog.scopedArtworkEnabled) {
              final poster = await artwork.enqueue(
                lease.workId!,
                ScopedImage.poster,
              );
              if (poster != null && !_background) await run(poster);
            }
          } else if (step == 'tmdb_specials') {
            await recognition.runSpecials(lease, intent['identity'] as String);
          } else if (step == 'scope_evidence') {
            await recognition.runRange(
              lease,
              intent['range'] as String,
              intent['revision'] as int,
            );
          } else {
            final work = (await tasks.db.query(
              'works',
              where: 'id=?',
              whereArgs: [lease.workId],
            )).single;
            final body = await requests.get(
              _resource(step, work),
              lease,
              manualRetry: manualRetry,
            );
            // Source identity and response schema must match before any adoption.
            final expected = work[step == 'tmdb' ? 'tmdb_id' : 'bangumi_id'];
            if (body['id'] != expected) {
              throw const MetadataFailure('protocol', 0);
            }
            final title = step == 'tmdb'
                ? (body['name'] ?? body['title'])
                : (body['name_cn'] ?? body['name']);
            final overview = body[step == 'tmdb' ? 'overview' : 'summary'];
            final date =
                body[step == 'tmdb'
                    ? (work['tmdb_type'] == 'movie'
                          ? 'release_date'
                          : 'first_air_date')
                    : 'date'];
            if (title is! String ||
                title.trim().isEmpty ||
                (overview != null && overview is! String)) {
              throw const MetadataFailure('protocol', 0);
            }
            final fields = <String, Object?>{
              'title': title,
              if (overview is String) 'overview': overview,
              if (date is String && DateTime.tryParse(date) != null)
                'year': DateTime.parse(date).year,
            };
            await tasks.commitFields(lease, fields);
            // UI reloads committed DB state; raw response never enters the view.
            await catalog.reload();
          }
        } on TaskPaused {
          await tasks.park(lease);
          if (intent['kind'] == 'scan') catalog.updateStatus('扫描已暂停');
          return;
        } on ScanCancelled {
          await tasks.control(
            id,
            'cancel',
            expectedGeneration: lease.generation,
          );
          tasks.release(lease);
          return;
        } on TaskStopped {
          await tasks.control(
            id,
            'cancel',
            expectedGeneration: lease.generation,
          );
          tasks.release(lease);
          if (intent['kind'] == 'scan') catalog.updateStatus('扫描已取消');
          return;
        } on MetadataFailure catch (e) {
          await tasks.fail(lease, e.category, notBefore: e.notBefore);
          return;
        } catch (_) {
          await tasks.fail(lease, 'processing');
          return;
        }
      }
    } finally {
      try {
        await priorityJobs;
      } finally {
        _running.remove(id);
        _wake();
      }
    }
  }
}
