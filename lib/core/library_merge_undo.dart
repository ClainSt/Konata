import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'library_foundation.dart';

typedef _Row = Map<String, Object?>;
typedef _Key = (String table, String key);
typedef _Link = (String kind, Object id);

class LibraryMergeUndo {
  LibraryMergeUndo._(this.id, this.createdAt, this._changes, this.retained);

  static const _journal = 'library_merge_undo';
  final String id, createdAt;
  final Map<_Key, ({String after, _Row? before, Set<_Link> links})> _changes;
  final int retained;
  int get affected => _changes.length;

  static Future<void> createSchema(DatabaseExecutor tx) => tx.execute('''
    CREATE TABLE $_journal (
      id INTEGER PRIMARY KEY CHECK(id=1), batch TEXT NOT NULL,
      created_at TEXT NOT NULL, changes TEXT NOT NULL)
  ''');

  static Future<void> clear(DatabaseExecutor tx) => tx.delete(_journal);

  static Future<_UndoSnapshot> _capture(
    DatabaseExecutor tx,
    List<String> portable,
  ) async {
    final rows = <_Key, _Row>{};
    final columns = <String, List<String>>{};
    for (final table in [
      ...portable,
      'library_restored_sources',
      'scan_roots',
      'scan_missing_assets',
      'scan_directory_checkpoints',
      'scan_discoveries',
    ]) {
      final info =
          (await tx.rawQuery(
              'PRAGMA table_info($table)',
            )).where((column) => (column['pk'] as int) > 0).toList()
            ..sort((a, b) => (a['pk'] as int).compareTo(b['pk'] as int));
      final key = columns[table] = info
          .map((c) => c['name'] as String)
          .toList();
      if (key.isEmpty) throw StateError('Missing undo primary key');
      for (final row in await tx.query(table)) {
        rows[(table, jsonEncode(key.map((k) => row[k]).toList()))] = row;
      }
    }
    return _UndoSnapshot(rows, columns);
  }

  static String _digest(String table, _Row row) {
    // Task runtime generations change on application restart.
    final data = {...row};
    if (table == 'scrape_tasks' || table == 'scan_directory_checkpoints') {
      data.remove('generation');
    }
    if ((table == 'scrape_tasks' || table == 'scrape_steps') &&
        data['state'] == 'running') {
      data['state'] = 'queued';
    }
    return sha256.convert(utf8.encode(jsonEncode(data))).toString();
  }

  static Future<void> record(
    DatabaseExecutor tx,
    List<String> tables,
    Future<void> Function() merge,
  ) async {
    final before = await _capture(tx, tables);
    await merge();
    final after = await _capture(tx, tables);
    if (before.rows.keys.any((key) => !after.rows.containsKey(key))) {
      throw StateError('Merge unexpectedly removed a local record');
    }
    final changes = <List<Object?>>[];
    for (final entry in after.rows.entries) {
      final key = entry.key, row = entry.value, old = before.rows[key];
      final digest = _digest(key.$1, row);
      if (old != null) {
        if (_digest(key.$1, old) == digest) continue;
        // Inserting imported overrides can change existing watch provenance.
        if (![
          'watch_identity_epochs',
          'watch_event_origins',
        ].contains(key.$1)) {
          throw StateError('Merge unexpectedly changed a local record');
        }
      }
      changes.add([
        key.$1,
        key.$2,
        digest,
        old,
        _links(key.$1, row).toList().map((link) => [link.$1, link.$2]).toList(),
      ]);
    }
    await clear(tx);
    if (changes.isEmpty) return;
    final encoded = jsonEncode(changes);
    if (utf8.encode(encoded).length > 32 * 1024 * 1024) {
      throw StateError('Merge undo journal exceeds its storage limit');
    }
    await tx.insert(_journal, {
      'id': 1,
      'batch': LibraryFoundation.newId('merge:'),
      'created_at': DateTime.now().toUtc().toIso8601String(),
      'changes': encoded,
    });
  }

  static _Link? _owner(String table, _Row row) {
    final owner = switch (table) {
      'sources' => ('source', row['id']),
      'works' => ('work', row['id']),
      'assets' => ('asset', row['id']),
      'media_chapters' => ('chapter', row['id']),
      'chapter_editions' => ('edition', row['id']),
      'scan_file_groups' => ('group', row['scope']),
      'scan_bindings' => ('binding', row['id']),
      'scrape_tasks' => ('task', row['id']),
      'watch_events' => ('event', row['event_id']),
      'mapping_versions' => ('mapping', row['version']),
      _ => null,
    };
    return owner == null || owner.$2 == null ? null : (owner.$1, owner.$2!);
  }

  static Set<_Link> _links(String table, _Row row) {
    final links = <_Link>{};
    void add(String kind, Object? value) {
      if (value != null) links.add((kind, value));
    }

    if (_owner(table, row) case final owner?) links.add(owner);
    add('source', row['source_id']);
    add('work', row['work_id']);
    add('asset', row['asset_id']);
    add('chapter', row['chapter_id']);
    add('edition', row['edition_id']);
    add('task', row['task_id']);
    add('event', row['event_id']);
    if (table == 'library_locations' || table == 'library_location_history') {
      add(row['kind'] as String, row['entity_id']);
    }
    if (table == 'scan_file_group_members' ||
        (table == 'scan_bindings' && row['layer'] == 'range')) {
      add('group', row['scope']);
    }
    if (table == 'scan_bindings' && row['parent'] != null) {
      add('binding', (jsonDecode(row['parent'] as String) as List).first);
    }
    if (table == 'library_fields' || table == 'library_field_history') {
      final scope = jsonDecode(row['scope'] as String) as List;
      if (scope.length == 6 && scope.first == 'part_overview') {
        add('binding', scope[1]);
      }
    }
    if (table == 'phantom_asset_archive') {
      add('asset', row['canonical_asset_id']);
      add('asset', row['obsolete_asset_id']);
    }
    if (table == 'watch_events') {
      for (final parent in jsonDecode(row['parents_json'] as String) as List) {
        add('event', parent);
      }
    }
    if (table == 'mapping_ancestry') {
      add('mapping', row['parent']);
      add('mapping', row['child']);
    }
    if (table == 'mapping_controls') add('mapping', row['version']);
    if (table == 'library_merge_conflicts') {
      final related = row['table_name'];
      if (related is String && related != table) {
        links.addAll(
          _links(
            related,
            Map<String, Object?>.from(
              jsonDecode(row['incoming_json'] as String) as Map,
            ),
          ),
        );
      }
    }
    return links;
  }

  static Future<LibraryMergeUndo?> preview(
    DatabaseExecutor tx,
    List<String> tables,
  ) => _preview(tx, tables);

  static Future<LibraryMergeUndo?> _preview(
    DatabaseExecutor tx,
    List<String> tables, [
    _UndoSnapshot? current,
  ]) async {
    final stored = (await tx.query(_journal)).firstOrNull;
    if (stored == null) return null;
    final state = current ?? await _capture(tx, tables);
    final changes = {
      for (final row
          in (jsonDecode(stored['changes'] as String) as List).cast<List>())
        (row[0] as String, row[1] as String): (
          after: row[2] as String,
          before: (row[3] as Map?)?.cast<String, Object?>(),
          links: {
            for (final link in row[4] as List)
              (link[0] as String, link[1] as Object),
          },
        ),
    };
    final owned = <_Link, _Key>{};
    final shared = <_Link, List<_Key>>{};
    final keep = <_Key>{};
    for (final entry in changes.entries) {
      final key = entry.key, change = entry.value, row = state.rows[key];
      if (row == null || _digest(key.$1, row) != change.after) keep.add(key);
      if (change.before == null && row != null && _owner(key.$1, row) != null) {
        owned[_owner(key.$1, row)!] = key;
      }
      for (final link in change.links) {
        (shared[link] ??= []).add(key);
      }
    }
    // New or pre-existing dependents keep imported parents. A source that was
    // reattached after merge is detected by its removed association marker.
    for (final entry in state.rows.entries) {
      if (changes.containsKey(entry.key)) continue;
      for (final link in _links(entry.key.$1, entry.value)) {
        if (owned[link] case final key?) keep.add(key);
        if (link.$1 == 'asset' && entry.key.$1 == 'watch_event_origins') {
          // An event created after the merge may rely on the current epoch,
          // including when its physical file predated the merge.
          for (final key in shared[link] ?? const <_Key>[]) {
            if (key.$1 == 'watch_identity_epochs') keep.add(key);
          }
        }
        if (link.$1 == 'work' &&
            entry.key.$1 == 'scoped_artwork' &&
            ['manual', 'empty'].contains(entry.value['state'])) {
          for (final key in shared[link] ?? const <_Key>[]) {
            if (key.$1 == 'scan_bindings') keep.add(key);
          }
        }
      }
    }
    final pending = keep.toList();
    final visited = <_Link>{};
    for (var i = 0; i < pending.length; i++) {
      for (final link in changes[pending[i]]!.links) {
        if (link.$1 == 'source') {
          // Keep the source for a retained work. Other works on the same
          // source can still be withdrawn independently.
          for (final other in shared[link]!.where(
            (key) => [
              'sources',
              'library_source_revisions',
              'library_restored_sources',
            ].contains(key.$1),
          )) {
            if (keep.add(other)) pending.add(other);
          }
          continue;
        }
        if (!visited.add(link)) continue;
        for (final other in shared[link]!) {
          if (keep.add(other)) pending.add(other);
        }
      }
    }
    return LibraryMergeUndo._(
      stored['batch'] as String,
      stored['created_at'] as String,
      {
        for (final e in changes.entries)
          if (!keep.contains(e.key)) e.key: e.value,
      },
      keep.length,
    );
  }

  static Future<void> apply(
    DatabaseExecutor tx,
    List<String> tables,
    LibraryMergeUndo reviewed,
  ) async {
    final before = await _capture(tx, tables);
    final current = await _preview(tx, tables, before);
    if (current == null ||
        current.id != reviewed.id ||
        current.affected == 0 ||
        current.affected != reviewed.affected ||
        !current._changes.keys.every(reviewed._changes.containsKey)) {
      throw StateError('Merge undo preview changed');
    }
    final changes = current._changes;
    final expected = {...before.rows};
    Future<void> revert(_Key key) async {
      final columns = before.keys[key.$1]!;
      final where = columns.map((column) => '$column IS ?').join(' AND ');
      final args = jsonDecode(key.$2) as List;
      final previous = changes[key]!.before;
      if (previous == null) {
        await tx.delete(key.$1, where: where, whereArgs: args);
        expected.remove(key);
      } else {
        await tx.update(key.$1, previous, where: where, whereArgs: args);
        expected[key] = previous;
      }
    }

    const provenance = ['watch_identity_epochs', 'watch_event_origins'];
    for (final table in before.keys.keys.toList().reversed) {
      if (provenance.contains(table)) continue;
      for (final key in changes.keys.where((key) => key.$1 == table)) {
        await revert(key);
      }
    }
    // Asset and override deletion fire watch-identity triggers.
    for (final key in changes.keys.where(
      (key) => provenance.contains(key.$1),
    )) {
      await revert(key);
    }
    final after = (await _capture(tx, tables)).rows;
    if (after.length != expected.length ||
        expected.entries.any(
          (entry) =>
              after[entry.key] == null ||
              jsonEncode(after[entry.key]) != jsonEncode(entry.value),
        )) {
      throw StateError('Undo would change records outside the reviewed set');
    }
    await clear(tx);
    await tx.rawUpdate(
      'UPDATE scrape_runtime SET session=?,cache_revision=cache_revision+1',
      [LibraryFoundation.newId('undo:')],
    );
  }
}

class _UndoSnapshot {
  const _UndoSnapshot(this.rows, this.keys);
  final Map<_Key, _Row> rows;
  final Map<String, List<String>> keys;
}
