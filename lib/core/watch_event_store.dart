import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'watched_timeline.dart';
import 'watch_event_origin.dart';
import 'logical_episode_store.dart';

class WatchUploadCandidate {
  const WatchUploadCandidate(this.reason, this.completed, this.eventIds);
  final String reason;
  final bool? completed;
  final List<String> eventIds;
  bool get ready => reason == 'ready';
}

class LogicalWatchState {
  const LogicalWatchState({
    required this.completed,
    required this.conflict,
    required this.manualHeads,
  });
  final bool? completed;
  final bool conflict;
  final List<String> manualHeads;
}

/// Immutable, versioned evidence. No wall-clock ordering or cross-cut timeline
/// conversion. Network adapters must validate/import a complete batch atomically.
class WatchEventStore {
  const WatchEventStore(this.db);
  final Database db;
  static final keyPattern = RegExp(
    r'^tmdb:tv:[1-9][0-9]*:s[0-9]+:e[1-9][0-9]*$',
  );

  static Future<void> createSchema(DatabaseExecutor tx) async {
    await tx.execute('''CREATE TABLE IF NOT EXISTS watch_events (
      event_id TEXT PRIMARY KEY, device_id TEXT NOT NULL,
      episode_key TEXT NOT NULL, kind TEXT NOT NULL,
      parents_json TEXT NOT NULL, payload_json TEXT NOT NULL,
      created_at TEXT NOT NULL, version INTEGER NOT NULL)''');
    await tx.execute(
      'CREATE INDEX IF NOT EXISTS watch_events_episode ON watch_events(episode_key)',
    );
    // Operational identity is deliberately excluded from portable backups.
    await tx.execute(
      'CREATE TABLE IF NOT EXISTS watch_event_local (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
    );
  }

  static Future<String> _device(DatabaseExecutor tx) async {
    final rows = await tx.query(
      'watch_event_local',
      where: 'key=?',
      whereArgs: ['device'],
    );
    if (rows.isNotEmpty) return rows.single['value'] as String;
    final random = Random.secure();
    final id = List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    await tx.insert('watch_event_local', {'key': 'device', 'value': id});
    return id;
  }

  static Future<String> _append(
    DatabaseExecutor tx,
    String key,
    String kind,
    List<String> parents,
    Map<String, Object?> payload, {
    String? assetId,
  }) async {
    final device = await _device(tx);
    final rows = await tx.query(
      'watch_event_local',
      where: 'key=?',
      whereArgs: ['sequence'],
    );
    final sequence = rows.isEmpty
        ? 1
        : int.parse(rows.single['value'] as String) + 1;
    await tx.insert('watch_event_local', {
      'key': 'sequence',
      'value': '$sequence',
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    final event = <String, Object?>{
      'event_id': '$device:$sequence',
      'device_id': device,
      'episode_key': key,
      'kind': kind,
      'parents_json': jsonEncode(parents..sort()),
      'payload_json': jsonEncode(payload),
      'version': kind == 'retract' ? 2 : 1,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    };
    validate(event);
    await tx.insert('watch_events', event);
    if (assetId != null && await _hasOrigins(tx)) {
      await WatchEventOrigin.attach(tx, event['event_id'] as String, assetId);
    }
    return event['event_id'] as String;
  }

  static Future<bool> _hasOrigins(
    DatabaseExecutor tx,
  ) async => (await tx.rawQuery(
    "SELECT name FROM sqlite_master WHERE type='table' AND name='watch_event_origins'",
  )).isNotEmpty;

  /// SQL identity observers invalidate proofs in the editing transaction.
  /// Materialize portable retractions before any read/export/upload decision.
  static Future<void> reconcileIn(DatabaseExecutor tx) async {
    if (!await _hasOrigins(tx)) return;
    final invalid = await tx.rawQuery('''SELECT e.* FROM watch_events e
      JOIN watch_event_origins o ON o.event_id=e.event_id
      WHERE o.invalidated=1 AND o.retracted=0 ORDER BY e.event_id''');
    final groups = <String, List<String>>{};
    final device = invalid.isEmpty ? null : await _device(tx);
    for (final e in invalid) {
      if (e['device_id'] != device) continue;
      (groups[e['episode_key'] as String] ??= []).add(e['event_id'] as String);
    }
    for (final group in groups.entries) {
      for (var offset = 0; offset < group.value.length; offset += 500) {
        final ids = group.value.sublist(
          offset,
          min(offset + 500, group.value.length),
        );
        await _append(tx, group.key, 'retract', ids, {
          'reason': 'identity_changed',
        });
        for (final id in ids) {
          await tx.update(
            'watch_event_origins',
            {'retracted': 1},
            where: 'event_id=?',
            whereArgs: [id],
          );
        }
      }
    }
  }

  Future<List<Map<String, Object?>>> exportEvents() =>
      db.transaction((tx) async {
        await reconcileIn(tx);
        return tx.query('watch_events', orderBy: 'rowid');
      });

  static Future<void> recordCoverage(
    DatabaseExecutor tx,
    String key,
    String assetId,
    WatchedTimeline timeline,
    int duration,
    int percent,
  ) async {
    if (duration <= 0 || timeline.ranges.isEmpty) return;
    await reconcileIn(tx);
    final device = await _device(tx);
    // Device-local timeline identity: equal durations do NOT prove equal edits.
    final revision = await _hasOrigins(tx)
        ? await WatchEventOrigin.revision(tx, assetId)
        : 0;
    final stream = sha256
        .convert(utf8.encode('$device|$assetId|$duration|$revision'))
        .toString();
    final previous = await tx.query(
      'watch_events',
      columns: ['payload_json'],
      where: 'episode_key=? AND device_id=? AND kind=? AND payload_json LIKE ?',
      whereArgs: [key, device, 'coverage', '%"stream":"$stream"%'],
      orderBy: 'rowid DESC',
      limit: 1,
    );
    final evidence = WatchedTimeline(timeline.ranges);
    if (previous.isNotEmpty) {
      final p = jsonDecode(previous.single['payload_json'] as String) as Map;
      evidence.addAll(WatchedTimeline.decode(jsonEncode(p['ranges'])).ranges);
    }
    final payload = <String, Object?>{
      'stream': stream,
      'duration': duration,
      'percent': percent,
      'ranges': [
        for (final r in evidence.ranges)
          if (r.start < duration) [r.start, min(r.end, duration)],
      ],
    };
    final encoded = jsonEncode(payload);
    final existing = await tx.query(
      'watch_events',
      columns: ['event_id'],
      where: 'episode_key=? AND device_id=? AND kind=? AND payload_json=?',
      whereArgs: [key, device, 'coverage', encoded],
      limit: 1,
    );
    if (existing.isEmpty) {
      await _append(tx, key, 'coverage', [], payload, assetId: assetId);
    }
  }

  static Future<void> recordManual(
    DatabaseExecutor tx,
    String key,
    bool completed, {
    String? assetId,
  }) async {
    await reconcileIn(tx);
    final rows = await tx.query(
      'watch_events',
      where: 'episode_key=?',
      whereArgs: [key],
    );
    final state = reduce(rows);
    if (!state.conflict &&
        state.manualHeads.isNotEmpty &&
        state.completed == completed) {
      if (assetId == null || !await _hasOrigins(tx)) return;
      var sameProof = true;
      for (final id in state.manualHeads) {
        final proofs = await tx.query(
          'watch_event_origins',
          where: 'event_id=?',
          whereArgs: [id],
        );
        if (proofs.isEmpty ||
            proofs.single['asset_id'] != assetId ||
            proofs.single['invalidated'] == 1 ||
            proofs.single['revision'] !=
                await WatchEventOrigin.revision(tx, assetId)) {
          sameProof = false;
        }
      }
      if (sameProof) return;
    }
    await _append(tx, key, 'manual', state.manualHeads.toList(), {
      'completed': completed,
    }, assetId: assetId);
  }

  Future<LogicalWatchState> state(String key) => db.transaction((tx) async {
    await reconcileIn(tx);
    return reduce(
      await tx.query('watch_events', where: 'episode_key=?', whereArgs: [key]),
    );
  });

  /// Local preflight only. A ready result is NOT a queue entry or API success.
  /// Imported/legacy evidence requires a separate confirmation path.
  Future<WatchUploadCandidate> uploadCandidate(String key) => db.transaction((
    tx,
  ) async {
    await reconcileIn(tx);
    final rows = await tx.query(
      'watch_events',
      where: 'episode_key=?',
      whereArgs: [key],
    );
    final state = reduce(rows);
    if (state.conflict) return const WatchUploadCandidate('conflict', null, []);
    if (state.completed == null) {
      return const WatchUploadCandidate('no_evidence', null, []);
    }
    final retracted = _retracted(rows);
    final ids = state.manualHeads.isNotEmpty
        ? state.manualHeads
        : rows
              .where((r) {
                if (r['kind'] != 'coverage' ||
                    retracted.contains(r['event_id'])) {
                  return false;
                }
                final p = jsonDecode(r['payload_json'] as String) as Map;
                return WatchedTimeline.decode(
                  jsonEncode(p['ranges']),
                ).reaches(p['duration'] as int, p['percent'] as int);
              })
              .map((r) => r['event_id'] as String)
              .toList();
    if (ids.isEmpty) return const WatchUploadCandidate('incomplete', null, []);
    if (!await _hasOrigins(tx)) {
      return const WatchUploadCandidate('unproven_origin', null, []);
    }
    final valid = <String>[];
    final localDevice = await _device(tx);
    for (final id in ids) {
      final event = rows.firstWhere((row) => row['event_id'] == id);
      if (event['device_id'] != localDevice) {
        if (state.manualHeads.isNotEmpty) {
          return const WatchUploadCandidate('unproven_origin', null, []);
        }
        continue;
      }
      final origins = await tx.query(
        'watch_event_origins',
        where: 'event_id=?',
        whereArgs: [id],
      );
      if (origins.isEmpty) {
        if (state.manualHeads.isNotEmpty) {
          return const WatchUploadCandidate('unproven_origin', null, []);
        }
        continue;
      }
      final origin = origins.single;
      final asset = origin['asset_id'] as String;
      if (origin['invalidated'] == 1 ||
          origin['revision'] != await WatchEventOrigin.revision(tx, asset) ||
          await LogicalEpisodeStore.resolveIn(tx, asset) != key) {
        if (state.manualHeads.isNotEmpty) {
          return const WatchUploadCandidate('identity_changed', null, []);
        }
        continue;
      }
      valid.add(id);
    }
    return valid.isEmpty
        ? const WatchUploadCandidate('unproven_origin', null, [])
        : WatchUploadCandidate(
            'ready',
            state.completed,
            List.unmodifiable(valid..sort()),
          );
  });

  static Set<String> _retracted(List<Map<String, Object?>> rows) => {
    for (final row in rows.where((r) => r['kind'] == 'retract'))
      ...(jsonDecode(row['parents_json'] as String) as List).cast<String>(),
  };

  static LogicalWatchState reduce(List<Map<String, Object?>> rows) {
    final retracted = _retracted(rows);
    final manual = rows.where((r) => r['kind'] == 'manual').toList();
    final superseded = <String>{};
    for (final row in manual) {
      superseded.addAll(
        (jsonDecode(row['parents_json'] as String) as List).cast<String>(),
      );
    }
    final heads = manual
        .where(
          (r) =>
              !superseded.contains(r['event_id']) &&
              !retracted.contains(r['event_id']),
        )
        .toList();
    if (heads.isNotEmpty) {
      final values = heads
          .map(
            (r) =>
                (jsonDecode(r['payload_json'] as String) as Map)['completed']
                    as bool,
          )
          .toSet();
      return LogicalWatchState(
        completed: values.length == 1 ? values.single : null,
        conflict: values.length > 1,
        manualHeads: heads.map((r) => r['event_id'] as String).toList()..sort(),
      );
    }
    final coverage = rows
        .where(
          (r) => r['kind'] == 'coverage' && !retracted.contains(r['event_id']),
        )
        .toList();
    final completed = coverage.any((r) {
      final p = jsonDecode(r['payload_json'] as String) as Map;
      return WatchedTimeline.decode(
        jsonEncode(p['ranges']),
      ).reaches(p['duration'] as int, p['percent'] as int);
    });
    return LogicalWatchState(
      completed: coverage.isEmpty ? null : completed,
      conflict: false,
      manualHeads: const [],
    );
  }

  /// Bounded and strict: malformed, missing-parent or same-ID/different-content
  /// batches roll back together. Import order never decides the watched state.
  Future<int> importEvents(List<Map<String, Object?>> incoming) async {
    if (incoming.length > 10000) {
      throw const FormatException('Event batch too large');
    }
    return db.transaction((tx) async {
      await reconcileIn(tx);
      final all = {
        for (final row in await tx.query('watch_events'))
          row['event_id'] as String: row,
      };
      final local = await tx.query(
        'watch_event_local',
        where: 'key=?',
        whereArgs: ['device'],
      );
      var added = 0;
      for (final row in incoming) {
        validate(row);
        final id = row['event_id'] as String;
        final old = all[id];
        if (old != null) {
          if (row.keys.any((key) => row[key] != old[key])) {
            throw const FormatException('Event ID collision');
          }
          continue;
        }
        if (local.isNotEmpty && row['device_id'] == local.single['value']) {
          throw const FormatException('Unexpected event for local device');
        }
        all[id] = row;
        added++;
      }
      validateGraph(all.values.toList());
      for (final row in incoming) {
        await tx.insert(
          'watch_events',
          row,
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      }
      return added;
    });
  }

  static void validate(Map<String, Object?> r) {
    const fields = {
      'event_id',
      'device_id',
      'episode_key',
      'kind',
      'parents_json',
      'payload_json',
      'created_at',
      'version',
    };
    if (r.length != fields.length ||
        !r.keys.toSet().containsAll(fields) ||
        (r['kind'] == 'retract' ? r['version'] != 2 : r['version'] != 1) ||
        r['device_id'] is! String ||
        !RegExp(r'^[a-f0-9]{32}$').hasMatch(r['device_id'] as String) ||
        r['event_id'] is! String ||
        !RegExp(
          '^${r['device_id']}:[1-9][0-9]{0,15}\$',
        ).hasMatch(r['event_id'] as String) ||
        r['episode_key'] is! String ||
        !keyPattern.hasMatch(r['episode_key'] as String) ||
        r['created_at'] is! String ||
        DateTime.tryParse(r['created_at'] as String) == null ||
        r['payload_json'] is! String ||
        (r['payload_json'] as String).length > 262144 ||
        r['parents_json'] is! String ||
        (r['parents_json'] as String).length > 65536) {
      throw const FormatException('Invalid watch event');
    }
    final parents = jsonDecode(r['parents_json'] as String);
    final p = jsonDecode(r['payload_json'] as String);
    if (parents is! List ||
        parents.length > 1000 ||
        parents.any((e) => e is! String) ||
        parents.toSet().length != parents.length ||
        p is! Map) {
      throw const FormatException('Invalid event payload');
    }
    if (r['kind'] == 'retract') {
      if (parents.isEmpty ||
          p.length != 1 ||
          p['reason'] != 'identity_changed') {
        throw const FormatException('Invalid retraction');
      }
    } else if (r['kind'] == 'manual') {
      if (p.length != 1 || p['completed'] is! bool) {
        throw const FormatException('Invalid manual event');
      }
    } else if (r['kind'] == 'coverage') {
      final duration = p['duration'];
      final percent = p['percent'];
      final ranges = p['ranges'];
      if (parents.isNotEmpty ||
          p.length != 4 ||
          p['stream'] is! String ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(p['stream'] as String) ||
          duration is! int ||
          duration <= 0 ||
          duration > 604800000 ||
          percent is! int ||
          percent < 1 ||
          percent > 100 ||
          ranges is! List ||
          ranges.length > 10000 ||
          ranges.any(
            (r) =>
                r is! List ||
                r.length != 2 ||
                r[0] is! int ||
                r[1] is! int ||
                r[0] < 0 ||
                r[1] <= r[0] ||
                r[1] > duration,
          )) {
        throw const FormatException('Invalid coverage evidence');
      }
    } else {
      throw const FormatException('Unknown watch event kind');
    }
  }

  static void validateGraph(List<Map<String, Object?>> rows) {
    final all = <String, Map<String, Object?>>{};
    for (final row in rows) {
      validate(row);
      if (all.containsKey(row['event_id'])) {
        throw const FormatException('Duplicate event ID');
      }
      all[row['event_id'] as String] = row;
    }
    final pending = <String, Set<String>>{};
    for (final row in rows) {
      final parents = (jsonDecode(row['parents_json'] as String) as List)
          .cast<String>()
          .toSet();
      for (final id in parents) {
        final parent = all[id];
        if (parent == null ||
            (row['kind'] == 'retract'
                ? (parent['kind'] == 'retract' ||
                      parent['device_id'] != row['device_id'])
                : parent['kind'] != 'manual') ||
            parent['episode_key'] != row['episode_key']) {
          throw const FormatException('Missing or unrelated causal parent');
        }
      }
      pending[row['event_id'] as String] = parents;
    }
    // Iterative traversal also handles malicious deep graphs without recursion.
    final children = <String, List<String>>{};
    for (final e in pending.entries) {
      for (final parent in e.value) {
        (children[parent] ??= []).add(e.key);
      }
    }
    final ready = pending.keys.where((id) => pending[id]!.isEmpty).toList();
    var visited = 0;
    while (ready.isNotEmpty) {
      final id = ready.removeLast();
      visited++;
      for (final child in children[id] ?? <String>[]) {
        pending[child]!.remove(id);
        if (pending[child]!.isEmpty) ready.add(child);
      }
    }
    if (visited != rows.length) throw const FormatException('Causal cycle');
  }
}
