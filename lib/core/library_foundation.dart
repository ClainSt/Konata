import 'dart:convert';
import 'dart:math';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Phase 1 storage, enabled only by Catalog's explicit development entry point.
/// Locations are case-sensitive decoded paths, never URL strings/aliases.
class LibraryFoundation {
  const LibraryFoundation(this.db);
  final Database db;
  static final _random = Random.secure();
  static const tables = [
    'library_source_revisions',
    'library_locations',
    'library_location_history',
    'library_content',
    'library_content_history',
    'library_work_protection',
    'library_fields',
    'library_field_history',
  ];
  static String newId(String prefix) =>
      '$prefix${List.generate(16, (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
  static String path(String value) {
    final normalized = p.posix.normalize(value.replaceAll('\\', '/'));
    if (normalized == '.' ||
        p.posix.isAbsolute(normalized) ||
        normalized == '..' ||
        normalized.startsWith('../')) {
      throw ArgumentError('Expected a source-relative path');
    }
    // Do not decode percent escapes here: the source adapter owns URL decoding.
    return normalized;
  }

  static Future<void> createSchema(DatabaseExecutor tx) async {
    await tx.execute('''CREATE TABLE library_source_revisions (
      source_id TEXT PRIMARY KEY, revision INTEGER NOT NULL DEFAULT 0)''');
    await tx.execute('''CREATE TABLE library_locations (
      kind TEXT NOT NULL CHECK(kind IN ('work','asset')), entity_id TEXT NOT NULL,
      source_id TEXT NOT NULL, relative_path TEXT NOT NULL, revision INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY(kind,source_id,relative_path), UNIQUE(kind,entity_id))''');
    await tx.execute('''CREATE TABLE library_location_history (
      id TEXT PRIMARY KEY, kind TEXT NOT NULL, entity_id TEXT NOT NULL,
      source_id TEXT NOT NULL, old_path TEXT NOT NULL, new_path TEXT NOT NULL,
      revision INTEGER NOT NULL)''');
    await tx.execute('''CREATE TABLE library_content (
      asset_id TEXT PRIMARY KEY, revision INTEGER NOT NULL DEFAULT 0,
      state TEXT NOT NULL DEFAULT 'current' CHECK(state IN ('current','suspected','blocked')),
      observed_size INTEGER, pending_progress TEXT)''');
    await tx.execute('''CREATE TABLE library_content_history (
      id TEXT PRIMARY KEY, asset_id TEXT NOT NULL, revision INTEGER NOT NULL,
      decision TEXT NOT NULL, pending_progress TEXT)''');
    await tx.execute('''CREATE TABLE library_work_protection (
      work_id TEXT PRIMARY KEY, legacy_lock INTEGER NOT NULL CHECK(legacy_lock IN (0,1)),
      identity_locked INTEGER NOT NULL CHECK(identity_locked IN (0,1)),
      revision INTEGER NOT NULL DEFAULT 0, legacy_json TEXT NOT NULL)''');
    await tx.execute('''CREATE TABLE library_fields (
      work_id TEXT NOT NULL, scope TEXT NOT NULL, field TEXT NOT NULL,
      automatic_json TEXT, automatic_source TEXT, automatic_revision INTEGER NOT NULL DEFAULT 0,
      updated_at TEXT, mode TEXT NOT NULL DEFAULT 'auto' CHECK(mode IN ('auto','manual','empty')),
      manual_json TEXT, revision INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY(work_id,scope,field))''');
    await tx.execute(
      '''CREATE TABLE library_field_history (
      id TEXT PRIMARY KEY, work_id TEXT NOT NULL, scope TEXT NOT NULL,
      field TEXT NOT NULL, revision INTEGER NOT NULL, previous_json TEXT NOT NULL)''',
    );
    await tx.execute(
      '''CREATE TRIGGER library_binding_revision AFTER UPDATE OF
      tmdb_id,tmdb_type,bangumi_id,bangumi_ids ON works
      WHEN OLD.tmdb_id IS NOT NEW.tmdb_id OR OLD.tmdb_type IS NOT NEW.tmdb_type
        OR OLD.bangumi_id IS NOT NEW.bangumi_id OR OLD.bangumi_ids IS NOT NEW.bangumi_ids
      BEGIN UPDATE library_work_protection SET revision=revision+1 WHERE work_id=NEW.id; END''',
    );
    await tx.execute(
      '''CREATE TRIGGER library_source_changed AFTER UPDATE OF location ON sources
      WHEN OLD.location IS NOT NEW.location BEGIN
      INSERT OR IGNORE INTO library_source_revisions(source_id) VALUES(NEW.id);
      UPDATE library_source_revisions SET revision=revision+1 WHERE source_id=NEW.id; END''',
    );
    for (final kind in ['asset', 'work']) {
      final owner = kind == 'asset' ? 'assets' : 'works';
      final dependent = kind == 'asset'
          ? ['library_content', 'library_content_history']
          : [
              'library_work_protection',
              'library_fields',
              'library_field_history',
            ];
      await tx.execute(
        '''CREATE TRIGGER library_${kind}_removed AFTER DELETE ON $owner BEGIN
        DELETE FROM library_locations WHERE kind='$kind' AND entity_id=OLD.id;
        DELETE FROM library_location_history WHERE kind='$kind' AND entity_id=OLD.id;
        ${dependent.map((t) => 'DELETE FROM $t WHERE ${kind}_id=OLD.id;').join('\n')}
        END''',
      );
    }
    await tx.execute(
      '''CREATE TRIGGER library_source_removed AFTER DELETE ON sources BEGIN
      DELETE FROM library_source_revisions WHERE source_id=OLD.id; END''',
    );
    await seed(tx);
  }

  static String scope(Map<String, Object?> work) => jsonEncode([
    work['tmdb_type'],
    work['tmdb_id'],
    work['bangumi_id'],
    work['bangumi_ids'],
  ]);

  static Future<void> seedWork(
    DatabaseExecutor tx,
    Map<String, Object?> work,
  ) async {
    final id = work['id'];
    final scopes = await tx.rawQuery(
      'SELECT DISTINCT scope FROM library_fields WHERE work_id=?',
      [id],
    );
    if (scopes.length >= 32 && !scopes.any((r) => r['scope'] == scope(work))) {
      throw StateError(
        'Binding history capacity reached; preserve/export before further changes',
      );
    }
    await tx.insert('library_work_protection', {
      'work_id': id,
      'legacy_lock': work['manual_lock'] ?? 0,
      'identity_locked': work['manual_lock'] ?? 0,
      'legacy_json': jsonEncode(work),
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
    for (final field in [
      'title',
      'year',
      'overview',
      'poster',
      'manual_cover_url',
    ]) {
      final manual = field == 'manual_cover_url' && work[field] != null;
      await tx.insert('library_fields', {
        'work_id': id, 'scope': scope(work), 'field': field,
        // Unknown legacy provenance stays unknown, not a guessed auto value.
        'automatic_json': work['manual_lock'] == 1 || manual
            ? null
            : jsonEncode(work[field]),
        'automatic_source': 'legacy', 'mode': manual ? 'manual' : 'auto',
        'manual_json': manual ? jsonEncode(work[field]) : null,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    }
  }

  static Future<void> seed(DatabaseExecutor tx) async {
    for (final work in await tx.query('works')) {
      await seedWork(tx, work);
    }
    for (final source in await tx.query('sources')) {
      await tx.insert('library_source_revisions', {
        'source_id': source['id'],
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    }
    for (final asset in await tx.query('assets')) {
      await attach(
        tx,
        'asset',
        asset['id'] as String,
        asset['source_id'] as String,
        path(asset['relative_path'] as String),
      );
      await tx.insert('library_content', {
        'asset_id': asset['id'],
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    }
    // Only old path-derived work IDs prove a directory association. Virtual or
    // arbitrary legacy groups remain unlocated rather than guessing a merge.
    for (final source in await tx.query('sources')) {
      final prefix = 'work:${source['id']}:';
      for (final work in await tx.query('works')) {
        final id = work['id'] as String;
        if (!id.startsWith(prefix)) continue;
        final suffix = id.substring(prefix.length);
        if (suffix.startsWith('classified:') || suffix.startsWith('id-')) {
          continue;
        }
        await attach(
          tx,
          'work',
          id,
          source['id'] as String,
          path(Uri.decodeComponent(suffix)),
        );
      }
    }
  }

  static Future<void> attach(
    DatabaseExecutor tx,
    String kind,
    String id,
    String source,
    String relative,
  ) async {
    final found = await tx.query(
      'library_locations',
      where: 'kind=? AND entity_id=?',
      whereArgs: [kind, id],
    );
    if (found.isNotEmpty) return;
    await tx.insert('library_locations', {
      'kind': kind,
      'entity_id': id,
      'source_id': source,
      'relative_path': relative,
    });
  }

  static Future<String?> locate(
    DatabaseExecutor tx,
    String kind,
    String source,
    String relative,
  ) async {
    final rows = await tx.query(
      'library_locations',
      where: 'kind=? AND source_id=? AND relative_path=?',
      whereArgs: [kind, source, relative],
    );
    return rows.isEmpty ? null : rows.single['entity_id'] as String;
  }

  static Future<int> sourceRevision(DatabaseExecutor tx, String source) async {
    final rows = await tx.query(
      'library_source_revisions',
      where: 'source_id=?',
      whereArgs: [source],
    );
    return rows.isEmpty ? 0 : rows.single['revision'] as int;
  }

  static Future<void> checkSource(
    DatabaseExecutor tx,
    String source,
    int revision,
  ) async {
    if (await sourceRevision(tx, source) != revision) {
      throw StateError('Source location changed; restart discovery');
    }
  }

  /// Caller supplies the reviewed mapping; this never infers moves from a name.
  /// A directory move is one transaction, including all file paths and history.
  Future<void> relocate(
    String source,
    Map<String, String> assetPaths, {
    required int expectedRevision,
    String? workId,
    String? workPath,
    DatabaseExecutor? executor,
  }) async {
    Future<void> write(DatabaseExecutor tx) async {
      await checkSource(tx, source, expectedRevision);
      if ((workId == null) != (workPath == null) || assetPaths.isEmpty) {
        throw ArgumentError('Incomplete location mapping');
      }
      if (workId != null) {
        final members = await tx.query(
          'assets',
          where: 'work_id=?',
          whereArgs: [workId],
        );
        if (members.length != assetPaths.length ||
            members.any((a) => !assetPaths.containsKey(a['id']))) {
          throw StateError('Directory move must include every member');
        }
      }
      Future<void> move(String kind, String id, String next) async {
        next = path(next);
        final rows = await tx.query(
          'library_locations',
          where: 'kind=? AND entity_id=? AND source_id=?',
          whereArgs: [kind, id, source],
        );
        if (rows.isEmpty) throw StateError('Location missing');
        final old = rows.single;
        if (old['relative_path'] == next) return;
        final revision = (old['revision'] as int) + 1;
        // Unique path conflicts abort the entire reviewed move.
        await tx.update(
          'library_locations',
          {'relative_path': next, 'revision': revision},
          where: 'kind=? AND entity_id=?',
          whereArgs: [kind, id],
        );
        if (kind == 'asset') {
          await tx.update(
            'assets',
            {'relative_path': next, 'name': p.posix.basename(next)},
            where: 'id=? AND source_id=?',
            whereArgs: [id, source],
          );
        }
        await tx.insert('library_location_history', {
          'id': newId('move:'),
          'kind': kind,
          'entity_id': id,
          'source_id': source,
          'old_path': old['relative_path'],
          'new_path': next,
          'revision': revision,
        });
        await tx.rawDelete(
          '''DELETE FROM library_location_history WHERE kind=? AND entity_id=?
          AND id NOT IN (SELECT id FROM library_location_history WHERE kind=? AND entity_id=?
          ORDER BY revision DESC LIMIT 32)''',
          [kind, id, kind, id],
        );
      }

      for (final entry in assetPaths.entries) {
        await move('asset', entry.key, entry.value);
      }
      if (workId != null) await move('work', workId, workPath!);
      await tx.insert('library_source_revisions', {
        'source_id': source,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
      await tx.rawUpdate(
        'UPDATE library_source_revisions SET revision=revision+1 WHERE source_id=?',
        [source],
      );
    }

    if (executor == null) {
      await db.transaction(write);
    } else {
      await write(executor);
    }
  }

  static Future<bool> observeSize(
    DatabaseExecutor tx,
    Map<String, Object?> old,
    int? size,
  ) async {
    await tx.insert('library_content', {
      'asset_id': old['id'],
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
    final row = (await tx.query(
      'library_content',
      where: 'asset_id=?',
      whereArgs: [old['id']],
    )).single;
    if (row['state'] == 'blocked') return true;
    if (size != null && old['size'] != null && size != old['size']) {
      if (row['state'] == 'suspected' && row['observed_size'] == size) {
        return true;
      }
      if (row['pending_progress'] != null) {
        if (await _contentHistoryFull(tx, old['id'] as String)) {
          await tx.update(
            'library_content',
            {'state': 'blocked'},
            where: 'asset_id=?',
            whereArgs: [old['id']],
          );
          return true;
        }
        await tx.insert('library_content_history', {
          'id': newId('content:'),
          'asset_id': old['id'],
          'revision': row['revision'],
          'decision': 'observation_changed',
          'pending_progress': row['pending_progress'],
        });
      }
      await tx.update(
        'library_content',
        {
          'state': 'suspected',
          'observed_size': size,
          'revision': (row['revision'] as int) + 1,
          'pending_progress': null,
        },
        where: 'asset_id=?',
        whereArgs: [old['id']],
      );
      return true;
    }
    return row['state'] != 'current';
  }

  static Future<bool> _contentHistoryFull(
    DatabaseExecutor tx,
    String id,
  ) async =>
      (await tx.rawQuery(
            'SELECT COUNT(*) AS n FROM library_content_history WHERE asset_id=?',
            [id],
          )).single['n']
          as int >=
      32;

  static Future<bool> suspected(DatabaseExecutor tx, String id) async =>
      (await tx.query(
        'library_content',
        where: "asset_id=? AND state!='current'",
        whereArgs: [id],
      )).isNotEmpty;

  /// Phase 1 only resolves the non-destructive 'same content' decision. Other
  /// decisions stay quarantined for explicit version/binding workflows.
  Future<void> confirmSameContent(String assetId, int expectedRevision) async {
    await db.transaction((tx) async {
      final row = (await tx.query(
        'library_content',
        where: 'asset_id=?',
        whereArgs: [assetId],
      )).single;
      if (row['revision'] != expectedRevision || row['state'] != 'suspected') {
        throw StateError('Content review changed');
      }
      if (await _contentHistoryFull(tx, assetId)) {
        throw StateError(
          'Content history capacity reached; export before resolving',
        );
      }
      await tx.insert('library_content_history', {
        'id': newId('content:'),
        'asset_id': assetId,
        'revision': expectedRevision,
        'decision': 'same',
        'pending_progress': row['pending_progress'],
      });
      await tx.update(
        'assets',
        {'size': row['observed_size']},
        where: 'id=?',
        whereArgs: [assetId],
      );
      await tx.update(
        'library_content',
        {
          'revision': expectedRevision + 1,
          'state': 'current',
          'observed_size': null,
          'pending_progress': null,
        },
        where: 'asset_id=?',
        whereArgs: [assetId],
      );
    });
  }

  static const displayFields = [
    'title',
    'year',
    'overview',
    'poster',
    'manual_cover_url',
  ];
  Future<Map<String, Object?>> field(String workId, String name) async {
    final work = (await db.query(
      'works',
      where: 'id=?',
      whereArgs: [workId],
    )).single;
    final rows = await db.query(
      'library_fields',
      where: 'work_id=? AND scope=? AND field=?',
      whereArgs: [workId, scope(work), name],
    );
    final protection = (await db.query(
      'library_work_protection',
      where: 'work_id=?',
      whereArgs: [workId],
    )).single;
    return {
      ...(rows.isEmpty
          ? {
              'revision': 0,
              'automatic_revision': 0,
              'scope': scope(work),
              'mode': 'auto',
            }
          : rows.single),
      'binding_revision': protection['revision'],
    };
  }

  /// Versions are captured at preview/request start, never fetched after await.
  Future<void> writeField(
    String workId,
    String name, {
    required String expectedScope,
    required int expectedRevision,
    required String mode,
    Object? value,
    required int expectedBindingRevision,
    int? expectedAutomaticRevision,
    String source = 'manual',
    bool automatic = false,
    DatabaseExecutor? executor,
  }) async {
    if (!displayFields.contains(name) ||
        !['auto', 'manual', 'empty'].contains(mode)) {
      throw ArgumentError('Unsupported field/mode');
    }
    if (value != null && (name == 'year' ? value is! int : value is! String)) {
      throw ArgumentError('Invalid field value');
    }
    if ((!automatic && mode == 'manual' && value == null) ||
        (automatic && mode != 'auto')) {
      throw ArgumentError('Use explicit empty state or an automatic draft');
    }
    if (name == 'title' &&
        (mode == 'empty' || (value is String && value.trim().isEmpty))) {
      throw ArgumentError('Title required');
    }
    Future<void> write(DatabaseExecutor tx) async {
      final work = (await tx.query(
        'works',
        where: 'id=?',
        whereArgs: [workId],
      )).single;
      if (scope(work) != expectedScope) throw StateError('Binding changed');
      await seedWork(tx, work);
      final old = (await tx.query(
        'library_fields',
        where: 'work_id=? AND scope=? AND field=?',
        whereArgs: [workId, expectedScope, name],
      )).single;
      final versionKey = automatic ? 'automatic_revision' : 'revision';
      if (old[versionKey] != expectedRevision) {
        throw StateError('Field changed');
      }
      if (expectedAutomaticRevision != null &&
          old['automatic_revision'] != expectedAutomaticRevision) {
        throw StateError('Automatic draft changed');
      }
      final protection = (await tx.query(
        'library_work_protection',
        where: 'work_id=?',
        whereArgs: [workId],
      )).single;
      if (protection['revision'] != expectedBindingRevision) {
        throw StateError('Binding revision changed');
      }
      if (automatic && protection['legacy_lock'] == 1) {
        throw StateError('Legacy whole-work protection');
      }
      if (!automatic && mode == 'auto' && old['automatic_json'] == null) {
        throw StateError('Automatic value has not been obtained');
      }
      if (!automatic) {
        await tx.insert('library_field_history', {
          'id': newId('field:'),
          'work_id': workId,
          'scope': expectedScope,
          'field': name,
          'revision': expectedRevision,
          'previous_json': jsonEncode(old),
        });
        await tx.rawDelete(
          '''DELETE FROM library_field_history WHERE work_id=? AND scope=? AND field=?
          AND id NOT IN (SELECT id FROM library_field_history WHERE work_id=? AND scope=? AND field=?
          ORDER BY revision DESC LIMIT 32)''',
          [workId, expectedScope, name, workId, expectedScope, name],
        );
      }
      final next = {
        ...old,
        versionKey: expectedRevision + 1,
        if (automatic) ...{
          'automatic_json': jsonEncode(value),
          'automatic_source': source,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        } else ...{
          'mode': mode,
          'manual_json': mode == 'manual' ? jsonEncode(value) : null,
        },
      };
      await tx.update(
        'library_fields',
        next,
        where: 'work_id=? AND scope=? AND field=?',
        whereArgs: [workId, expectedScope, name],
      );
      final effective = next['mode'] == 'empty'
          ? null
          : jsonDecode(
              (next[next['mode'] == 'manual' ? 'manual_json' : 'automatic_json']
                      as String?) ??
                  'null',
            );
      if (name == 'title' && effective == null) {
        throw StateError('Title required');
      }
      await tx.update(
        'works',
        {name: effective},
        where: 'id=?',
        whereArgs: [workId],
      );
    }

    if (executor == null) {
      await db.transaction(write);
    } else {
      await write(executor);
    }
  }

  static Future<void> bindWork(
    DatabaseExecutor tx,
    String id,
    Map<String, Object?> values,
  ) async {
    final old = (await tx.query(
      'works',
      where: 'id=?',
      whereArgs: [id],
    )).single;
    await seedWork(tx, old);
    final protection = (await tx.query(
      'library_work_protection',
      where: 'work_id=?',
      whereArgs: [id],
    )).single;
    final changed = scope(old) != scope({...old, ...values});
    final update = {
      ...values,
      'manual_lock': protection['legacy_lock'],
      if (changed) ...{
        'manual_cover_url': null,
        'manual_cover_source': null,
        'cover_edit_json': null,
        'poster_fallback': null,
      },
    };
    await tx.update('works', update, where: 'id=?', whereArgs: [id]);
    await tx.update(
      'library_work_protection',
      {'identity_locked': 1},
      where: 'work_id=?',
      whereArgs: [id],
    );
    final next = (await tx.query(
      'works',
      where: 'id=?',
      whereArgs: [id],
    )).single;
    await seedWork(tx, next);
    // Old scope records remain available for reviewed undo, never copied to a
    // different identity. Same-scope manual values remain authoritative.
    if (!changed) {
      final fields = await tx.query(
        'library_fields',
        where: 'work_id=? AND scope=?',
        whereArgs: [id, scope(next)],
      );
      final overrides = <String, Object?>{};
      for (final field in fields) {
        if (field['mode'] == 'empty') {
          overrides[field['field'] as String] = null;
        }
        if (field['mode'] == 'manual') {
          overrides[field['field'] as String] = jsonDecode(
            field['manual_json'] as String,
          );
        }
      }
      if (overrides.isNotEmpty) {
        await tx.update('works', overrides, where: 'id=?', whereArgs: [id]);
      }
    }
  }

  /// Adopt already-fetched fields without releasing manual overrides or binding.
  static Future<bool> applyAutomatic(
    DatabaseExecutor tx,
    String id,
    Map<String, Object?> update,
  ) async {
    final work = (await tx.query(
      'works',
      where: 'id=?',
      whereArgs: [id],
    )).single;
    await seedWork(tx, work);
    final protection = (await tx.query(
      'library_work_protection',
      where: 'work_id=?',
      whereArgs: [id],
    )).single;
    if (protection['legacy_lock'] == 1 || work['manual_lock'] == 1) {
      return false;
    }
    for (final key in ['tmdb_id', 'tmdb_type', 'bangumi_id', 'bangumi_ids']) {
      if (work[key] != null &&
          update.containsKey(key) &&
          update[key] != work[key]) {
        return false;
      }
    }
    final nextWork = {...work, ...update};
    // Phase 1 only refreshes an established scope. New source associations and
    // initial automatic bindings require phase 4's evidence/confirmation path.
    if (scope(nextWork) != scope(work)) return false;
    // New scope does not inherit old scope's manual values.
    final nextScope = scope(nextWork);
    final visible = {...update};
    for (final name in displayFields.where(update.containsKey)) {
      final rows = await tx.query(
        'library_fields',
        where: 'work_id=? AND scope=? AND field=?',
        whereArgs: [id, nextScope, name],
      );
      final old = rows.isEmpty ? <String, Object?>{} : rows.single;
      final values = {
        'work_id': id,
        'scope': nextScope,
        'field': name,
        'automatic_json': jsonEncode(update[name]),
        'automatic_source': 'scraper',
        'automatic_revision': ((old['automatic_revision'] as int?) ?? 0) + 1,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      };
      if (rows.isEmpty) {
        await tx.insert('library_fields', values);
      } else {
        await tx.update(
          'library_fields',
          values,
          where: 'work_id=? AND scope=? AND field=?',
          whereArgs: [id, nextScope, name],
        );
      }
      if (old['mode'] == 'empty') visible[name] = null;
      if (old['mode'] == 'manual') {
        visible[name] = jsonDecode(old['manual_json'] as String);
      }
    }
    await tx.update('works', visible, where: 'id=?', whereArgs: [id]);
    return true;
  }

  static void validateSnapshot(Map<String, dynamic> tables) {
    final works = {for (final r in tables['works'] as List) r['id']};
    final assets = {for (final r in tables['assets'] as List) r['id']};
    final sources = {for (final r in tables['sources'] as List) r['id']};
    for (final table in LibraryFoundation.tables) {
      final keys = <String>{};
      for (final raw in tables[table] as List) {
        final r = raw as Map;
        if ((r.containsKey('work_id') && !works.contains(r['work_id'])) ||
            (r.containsKey('asset_id') && !assets.contains(r['asset_id'])) ||
            (r.containsKey('source_id') && !sources.contains(r['source_id']))) {
          throw const FormatException('Orphaned foundation record');
        }
        if (r['revision'] is! int || r['revision'] < 0) {
          throw const FormatException('Invalid revision');
        }
        if (table == 'library_locations' ||
            table == 'library_location_history') {
          if (!(r['kind'] == 'work'
                  ? works
                  : r['kind'] == 'asset'
                  ? assets
                  : <Object?>{})
              .contains(r['entity_id'])) {
            throw const FormatException('Invalid location owner');
          }
          for (final name
              in table == 'library_locations'
                  ? ['relative_path']
                  : ['old_path', 'new_path']) {
            try {
              if (path(r[name] as String) != r[name]) {
                throw const FormatException('Noncanonical location');
              }
            } catch (_) {
              throw const FormatException('Invalid location');
            }
          }
        }
        final key = jsonEncode(switch (table) {
          'library_locations' => [r['kind'], r['entity_id']],
          'library_fields' => [r['work_id'], r['scope'], r['field']],
          'library_work_protection' => r['work_id'],
          'library_source_revisions' => r['source_id'],
          'library_content' => r['asset_id'],
          _ => r['id'],
        });
        if (!keys.add(key)) {
          throw const FormatException('Duplicate foundation record');
        }
        if (table == 'library_content' &&
            !['current', 'suspected', 'blocked'].contains(r['state'])) {
          throw const FormatException('Invalid content state');
        }
        if (table == 'library_work_protection' &&
            (![0, 1].contains(r['legacy_lock']) ||
                ![0, 1].contains(r['identity_locked']))) {
          throw const FormatException('Invalid identity protection');
        }
        for (final jsonField in [
          'pending_progress',
          'previous_json',
          'legacy_json',
        ]) {
          if (r[jsonField] != null &&
              jsonDecode(r[jsonField] as String) is! Map) {
            throw const FormatException('Invalid persisted snapshot');
          }
        }
        if (table == 'library_fields') {
          if (!displayFields.contains(r['field']) ||
              !['auto', 'manual', 'empty'].contains(r['mode']) ||
              r['automatic_revision'] is! int ||
              r['automatic_revision'] < 0) {
            throw const FormatException('Invalid field state');
          }
          if (jsonDecode(r['scope'] as String) is! List ||
              (r['mode'] == 'manual' && r['manual_json'] == null)) {
            throw const FormatException('Invalid field scope/override');
          }
          for (final name in ['automatic_json', 'manual_json']) {
            if (r[name] == null) continue;
            final value = jsonDecode(r[name] as String);
            if (value != null &&
                (r['field'] == 'year' ? value is! int : value is! String)) {
              throw const FormatException('Invalid field value');
            }
          }
        }
      }
    }
    final locations = {
      for (final r in tables['library_locations'] as List)
        if (r['kind'] == 'asset') r['entity_id']: r,
    };
    final contentIds = {
      for (final r in tables['library_content'] as List) r['asset_id'],
    };
    for (final asset in tables['assets'] as List) {
      final location = locations[asset['id']];
      if (location == null ||
          location['source_id'] != asset['source_id'] ||
          location['relative_path'] != asset['relative_path'] ||
          !contentIds.contains(asset['id'])) {
        throw const FormatException('Incomplete asset foundation');
      }
    }
    if ((tables['library_work_protection'] as List).length != works.length) {
      throw const FormatException('Incomplete work protection');
    }
  }
}
