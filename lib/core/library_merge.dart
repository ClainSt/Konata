import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'library_foundation.dart';

typedef MergeConflict = ({
  String table,
  String key,
  Map<String, Object?>? local,
  Map<String, Object?> incoming,
  bool positionChoice,
});

class LibraryMerge {
  LibraryMerge._(
    this.fingerprint,
    this.associations,
    this.newRows,
    this.conflicts,
  );
  final String fingerprint;
  final Map<String, String> associations;
  final Map<String, List<Map<String, Object?>>> newRows;
  final List<MergeConflict> conflicts;

  static Future<void> createSchema(DatabaseExecutor tx) async {
    await tx.execute(
      '''CREATE TABLE library_merge_conflicts (
      id TEXT PRIMARY KEY, table_name TEXT NOT NULL, entity_key TEXT NOT NULL,
      local_json TEXT, incoming_json TEXT NOT NULL, created_at TEXT NOT NULL,
      position_choice INTEGER NOT NULL, resolved INTEGER NOT NULL DEFAULT 0)''',
    );
  }

  static Future<LibraryMerge> preview(
    DatabaseExecutor tx,
    List<String> tables,
    Map<String, dynamic> incoming,
    Map<String, String> associations,
  ) async {
    final current = <String, List<Map<String, Object?>>>{};
    final keys = <String, List<String>>{};
    for (final table in tables) {
      final columns =
          (await tx.rawQuery(
              'PRAGMA table_info($table)',
            )).where((c) => (c['pk'] as int) > 0).toList()
            ..sort((a, b) => (a['pk'] as int).compareTo(b['pk'] as int));
      keys[table] = columns.map((c) => c['name'] as String).toList();
      current[table] = await tx.query(table, orderBy: keys[table]!.join(','));
    }
    final digest = sha256
        .convert(utf8.encode(jsonEncode([current, incoming, associations])))
        .toString();
    List<Map<String, Object?>> rows(String table) =>
        ((incoming[table] as List?) ?? const [])
            .map((row) => Map<String, Object?>.from(row as Map))
            .toList();
    final localSources = {
      for (final row in current['sources']!) row['id'] as String: row,
    };
    final incomingSources = {
      for (final row in rows('sources')) row['id'] as String: row,
    };
    final sourceMap = <String, String>{};
    for (final row in incomingSources.entries) {
      final target =
          associations[row.key] ??
          (localSources.containsKey(row.key) ? row.key : null);
      if (target != null) {
        if (localSources[target]?['kind'] != row.value['kind'] ||
            sourceMap.values.contains(target)) {
          throw StateError('Media source association is ambiguous');
        }
        sourceMap[row.key] = target;
      } else if (localSources.values.any(
        (s) =>
            s['kind'] == row.value['kind'] &&
            s['location'] == row.value['location'],
      )) {
        throw StateError('Confirm the matching source before merging');
      }
    }
    if (associations.keys.any((key) => !incomingSources.containsKey(key))) {
      throw StateError('Backup source changed');
    }
    final localAssets = {
      for (final a in current['assets']!) a['id'] as String: a,
    };
    final localPaths = {
      for (final a in localAssets.values)
        (a['source_id'], a['relative_path']): a,
    };
    final assetMap = <String, String>{};
    final workMap = <String, String>{};
    final matchedAssets = <String>{};
    final matchedWorks = <String>{};
    for (final asset in rows('assets')) {
      final id = asset['id'] as String, source = asset['source_id'] as String;
      final targetSource = sourceMap[source];
      final exact = localAssets[id];
      final byPath = targetSource == null
          ? null
          : localPaths[(targetSource, asset['relative_path'])];
      final target = exact ?? byPath;
      if (target == null) continue;
      if (target['source_id'] != targetSource ||
          (exact != null && byPath != null && exact['id'] != byPath['id']) ||
          (asset['size'] != null &&
              target['size'] != null &&
              asset['size'] != target['size']) ||
          (exact == null &&
              (asset['size'] == null || target['size'] == null))) {
        throw StateError('Matching file needs a reviewed content association');
      }
      final localId = target['id'] as String;
      if (!matchedAssets.add(localId))
        throw StateError('Multiple incoming files match one file');
      assetMap[id] = localId;
      final work = asset['work_id'] as String,
          localWork = target['work_id'] as String;
      if (workMap.containsKey(work)
          ? workMap[work] != localWork
          : !matchedWorks.add(localWork)) {
        throw StateError('Incoming and current works do not match one-to-one');
      }
      workMap[work] = localWork;
    }
    final localWorkPaths = {
      for (final row in current['library_locations']!)
        if (row['kind'] == 'work')
          (row['source_id'], row['relative_path']): row['entity_id'],
    };
    for (final row in rows(
      'library_locations',
    ).where((r) => r['kind'] == 'work')) {
      final source = sourceMap[row['source_id']];
      if (source == null) continue;
      final occupant = localWorkPaths[(source, row['relative_path'])];
      final candidate = workMap[row['entity_id']] ?? row['entity_id'];
      if (occupant != null && occupant != candidate) {
        throw StateError('Review files in a matching folder before merging');
      }
    }
    final content = {
      for (final r in current['library_content']!) r['asset_id']: r,
    };
    final incomingContent = {
      for (final r in rows('library_content')) r['asset_id']: r,
    };
    final uncertain = {
      for (final e in assetMap.entries)
        if (content[e.value]?['state'] != 'current' ||
            incomingContent[e.key]?['state'] != 'current' ||
            content[e.value]?['revision'] !=
                incomingContent[e.key]?['revision'])
          e.key,
    };
    final workIdentity = {
      for (final r in current['works']!) r['id']: LibraryFoundation.scope(r),
    };
    final incomingWorkIdentity = {
      for (final r in rows('works')) r['id']: LibraryFoundation.scope(r),
    };
    Map<(Object?, Object?), String> confirmedIdentities(
      Iterable<Map<String, Object?>> bindings,
    ) => {
      for (final row in bindings)
        if (row['layer'] == 'work' && row['state'] == 'confirmed')
          (row['work_id'], row['provider']): _identityOf(row),
    };
    final localBindings = confirmedIdentities(current['scan_bindings']!);
    final incomingBindings = confirmedIdentities(rows('scan_bindings'));
    final identityConflicts = {
      for (final e in workMap.entries)
        if (workIdentity[e.value] != incomingWorkIdentity[e.key] ||
            ['tmdb', 'bangumi'].any((source) {
              final a = localBindings[(e.value, source)];
              final b = incomingBindings[(e.key, source)];
              return a != null && b != null && a != b;
            }))
          e.key,
    };
    final inserts = <String, List<Map<String, Object?>>>{};
    final conflicts = <MergeConflict>[];
    final accepted = <String, Map<String, Map<String, Object?>>>{};

    String key(String table, Map row) =>
        jsonEncode([for (final column in keys[table]!) row[column]]);
    String bindingId(String input) {
      final value = jsonDecode(input) as List;
      return jsonEncode([
        workMap[value[0]] ?? value[0],
        value[1],
        value[2],
        value[2] == 'episode' ? assetMap[value[3]] ?? value[3] : value[3],
      ]);
    }

    for (final table in tables) {
      final byKey = accepted[table] = {
        for (final row in current[table]!) key(table, row): row,
      };
      final incomingRows = rows(table);
      if (table == 'scan_bindings') {
        const priority = {'work': 0, 'range': 1, 'episode': 2};
        incomingRows.sort(
          (a, b) => priority[a['layer']]!.compareTo(priority[b['layer']]!),
        );
      }
      for (final original in incomingRows) {
        final row = {...original};
        void remap(String column, Map<String, String> ids) {
          if (ids[row[column]] case final id?) row[column] = id;
        }

        if (table == 'sources' && sourceMap.containsKey(row['id'])) continue;
        if (table == 'works') remap('id', workMap);
        if (table == 'assets') remap('id', assetMap);
        remap('source_id', sourceMap);
        remap('work_id', workMap);
        remap('asset_id', assetMap);
        if (['library_locations', 'library_location_history'].contains(table)) {
          remap('entity_id', row['kind'] == 'asset' ? assetMap : workMap);
        }
        if (table == 'scan_bindings') {
          row['id'] = bindingId(original['id'] as String);
          if (row['layer'] == 'episode') remap('scope', assetMap);
          if (row['parent'] case final String parent) {
            final token = jsonDecode(parent) as List;
            row['parent'] = jsonEncode([
              bindingId(token[0] as String),
              token[1],
            ]);
          }
        }
        if (['library_fields', 'library_field_history'].contains(table)) {
          final scope = jsonDecode(row['scope'] as String) as List;
          if (scope.length == 6 && scope.first == 'part_overview') {
            scope[1] = bindingId(scope[1] as String);
            row['scope'] = jsonEncode(scope);
          }
        }
        final id = key(table, row);
        final local = byKey[id];
        if (local != null && jsonEncode(local) == jsonEncode(row)) continue;
        final bindingParent =
            table == 'scan_bindings' && row['parent'] is String
            ? jsonDecode(row['parent'] as String) as List
            : null;
        final needsReview =
            (identityConflicts.contains(original['work_id']) &&
                [
                  'scan_bindings',
                  'scoped_artwork',
                  'library_fields',
                  'media_chapters',
                ].contains(table)) ||
            (uncertain.contains(original['asset_id']) &&
                [
                  'progress',
                  'chapter_parts',
                  'watch_event_origins',
                ].contains(table)) ||
            (table == 'watch_event_origins' &&
                assetMap.containsKey(original['asset_id'])) ||
            (bindingParent != null &&
                byKey[jsonEncode([bindingParent[0]])]?['revision'] !=
                    bindingParent[1]) ||
            (table == 'chapter_editions' &&
                !(accepted['media_chapters']?.containsKey(
                      jsonEncode([row['chapter_id']]),
                    ) ??
                    false)) ||
            (table == 'chapter_parts' &&
                !(accepted['chapter_editions']?.containsKey(
                      jsonEncode([row['edition_id']]),
                    ) ??
                    false)) ||
            (table == 'library_locations' &&
                current['library_locations']!.any(
                  (r) =>
                      r['kind'] == row['kind'] &&
                      r['entity_id'] == row['entity_id'],
                )) ||
            (table == 'scan_move_reviews' &&
                sourceMap.containsKey(original['source_id'])) ||
            (table == 'scrape_tasks' &&
                (sourceMap.containsKey(original['source_id']) ||
                    workMap.containsKey(original['work_id']))) ||
            (table == 'scrape_steps' &&
                !(accepted['scrape_tasks']?.containsKey(
                      jsonEncode([row['task_id']]),
                    ) ??
                    false)) ||
            (table == 'mapping_controls' && row['batch'] != 'restored');
        if (local != null || needsReview) {
          conflicts.add((
            table: table,
            key: id,
            local: local,
            incoming: row,
            positionChoice:
                table == 'progress' &&
                !needsReview &&
                local != null &&
                local['duration_ms'] == row['duration_ms'],
          ));
          continue;
        }
        byKey[id] = row;
        (inserts[table] ??= []).add(row);
      }
    }
    return LibraryMerge._(
      digest,
      Map.unmodifiable(associations),
      inserts,
      conflicts,
    );
  }

  static String _identityOf(Map row) {
    final value = jsonDecode(row['adopted'] as String) as Map;
    return jsonEncode([value['type'], value['id']]);
  }

  Future<void> apply(DatabaseExecutor tx) async {
    final now = DateTime.now().toUtc().toIso8601String();
    for (final entry in newRows.entries) {
      for (final row in entry.value) {
        if (entry.key == 'watch_identity_epochs') {
          // New asset inserts already created an empty derived epoch.
          await tx.delete(
            entry.key,
            where: 'asset_id=?',
            whereArgs: [row['asset_id']],
          );
        }
        await tx.insert(entry.key, row);
        if (entry.key == 'sources') {
          await tx.insert('library_restored_sources', {'source_id': row['id']});
        }
      }
    }
    for (final conflict in conflicts) {
      final id = sha256
          .convert(
            utf8.encode(
              jsonEncode([
                conflict.table,
                conflict.key,
                conflict.local,
                conflict.incoming,
              ]),
            ),
          )
          .toString();
      await tx.insert('library_merge_conflicts', {
        'id': id,
        'table_name': conflict.table,
        'entity_key': conflict.key,
        'local_json': conflict.local == null
            ? null
            : jsonEncode(conflict.local),
        'incoming_json': jsonEncode(conflict.incoming),
        'created_at': now,
        'position_choice': conflict.positionChoice ? 1 : 0,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    }
  }

  static Future<void> resolvePosition(
    Database db,
    String id, {
    required bool useIncoming,
  }) async {
    await db.transaction((tx) async {
      final review = (await tx.query(
        'library_merge_conflicts',
        where:
            "id=? AND table_name='progress' AND position_choice=1 AND resolved=0",
        whereArgs: [id],
      )).firstOrNull;
      if (review == null) throw StateError('Review changed');
      final local = jsonDecode(review['local_json'] as String) as Map;
      final remote = jsonDecode(review['incoming_json'] as String) as Map;
      final asset = local['asset_id'];
      final current = (await tx.query(
        'progress',
        where: 'asset_id=?',
        whereArgs: [asset],
      )).firstOrNull;
      final version = (await tx.query(
        'library_content',
        where: 'asset_id=? AND state=?',
        whereArgs: [asset, 'current'],
      )).firstOrNull;
      if (current == null ||
          jsonEncode(current) != jsonEncode(local) ||
          version == null) {
        throw StateError('Current file or playback history changed');
      }
      if (useIncoming) {
        final position = remote['position_ms'];
        if (position is! int ||
            position < 0 ||
            position > (current['duration_ms'] as int)) {
          throw StateError('Invalid incoming position');
        }
        await tx.update(
          'progress',
          {'position_ms': position},
          where: 'asset_id=?',
          whereArgs: [asset],
        );
      }
      await tx.update(
        'library_merge_conflicts',
        {'resolved': 1},
        where: 'id=?',
        whereArgs: [id],
      );
    });
  }

  static void validateSnapshot(Map<String, dynamic> tables) {
    for (final row in tables['library_merge_conflicts'] as List) {
      if (row['id'] is! String ||
          row['table_name'] is! String ||
          row['entity_key'] is! String ||
          row['created_at'] is! String ||
          ![0, 1].contains(row['position_choice']) ||
          ![0, 1].contains(row['resolved']) ||
          jsonDecode(row['incoming_json'] as String) is! Map ||
          (row['local_json'] != null &&
              jsonDecode(row['local_json'] as String) is! Map)) {
        throw const FormatException('Invalid merge review');
      }
    }
  }
}
