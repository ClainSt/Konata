import 'dart:convert';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Repairs ONLY phantom repeated-parent paths that have an identical
/// canonical asset in the same source and work. Original data is archived.
abstract final class PhantomDirectoryRepair {
  static Future<int> repair(Database db) async {
    await db.execute(
      'CREATE TABLE IF NOT EXISTS phantom_asset_archive ('
      'obsolete_asset_id TEXT PRIMARY KEY, canonical_asset_id TEXT NOT NULL, '
      'asset_json TEXT NOT NULL, progress_json TEXT, '
      'override_json TEXT, history_json TEXT, archived_at TEXT NOT NULL)',
    );
    final rows = await db.query('assets');
    final lookup = <String, Map<String, Object?>>{
      for (final row in rows)
        _key(row['source_id'].toString(), row['relative_path'].toString()): row,
    };
    var removed = 0;
    for (final ghost in rows) {
      final path = ghost['relative_path']?.toString() ?? '';
      final segments = path.split('/');
      if (segments.length < 4) continue;
      Map<String, Object?>? canonical;
      for (var i = 1; i < segments.length - 1; i++) {
        if (segments[i] != segments[i - 1] || segments[i].isEmpty) continue;
        final candidate = [...segments]..removeAt(i);
        final existing =
            lookup[_key(ghost['source_id'].toString(), candidate.join('/'))];
        if (existing == null || identical(existing, ghost)) continue;
        if (!_sameFile(ghost, existing)) continue;
        canonical = existing;
        break;
      }
      if (canonical == null) continue;
      final ghostId = ghost['id']?.toString();
      final goodId = canonical['id']?.toString();
      if (ghostId == null || goodId == null || ghostId == goodId) continue;

      final ghostOverride = await _one(db, 'asset_overrides', ghostId);
      final goodOverride = await _one(db, 'asset_overrides', goodId);
      if (ghostOverride != null &&
          goodOverride != null &&
          !_sameManual(ghostOverride, goodOverride)) {
        continue;
      }

      final ghostHistory = await _one(db, 'asset_override_history', ghostId);
      final goodHistory = await _one(db, 'asset_override_history', goodId);
      final ghostProgress = await _one(db, 'progress', ghostId);
      final goodProgress = await _one(db, 'progress', goodId);

      await db.insert('phantom_asset_archive', {
        'obsolete_asset_id': ghostId,
        'canonical_asset_id': goodId,
        'asset_json': jsonEncode(ghost),
        'progress_json': ghostProgress == null
            ? null
            : jsonEncode(ghostProgress),
        'override_json': ghostOverride == null
            ? null
            : jsonEncode(ghostOverride),
        'history_json': ghostHistory == null ? null : jsonEncode(ghostHistory),
        'archived_at': DateTime.now().toUtc().toIso8601String(),
      }, conflictAlgorithm: ConflictAlgorithm.ignore);

      if (ghostProgress != null &&
          (goodProgress == null ||
              _preferProgress(ghostProgress, goodProgress))) {
        await db.insert('progress', {
          ...ghostProgress,
          'asset_id': goodId,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      if (ghostOverride != null && goodOverride == null) {
        await db.insert('asset_overrides', {
          ...ghostOverride,
          'asset_id': goodId,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      if (ghostHistory != null && goodHistory == null) {
        await db.insert('asset_override_history', {
          ...ghostHistory,
          'asset_id': goodId,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      for (final table in [
        'progress',
        'asset_overrides',
        'asset_override_history',
      ]) {
        await db.delete(table, where: 'asset_id=?', whereArgs: [ghostId]);
      }
      await db.delete('assets', where: 'id=?', whereArgs: [ghostId]);
      removed++;
    }
    return removed;
  }

  static String _key(String sourceId, String path) => '$sourceId\u0000$path';

  static bool _sameFile(Map<String, Object?> a, Map<String, Object?> b) {
    for (final field in [
      'source_id',
      'work_id',
      'name',
      'size',
      'episode',
      'season',
      'category',
      'extra_type',
    ]) {
      if (a[field] != b[field]) return false;
    }
    return true;
  }

  static bool _sameManual(Map<String, Object?> a, Map<String, Object?> b) {
    for (final field in [
      'work_id',
      'episode',
      'season',
      'category',
      'extra_type',
    ]) {
      if (a[field] != b[field]) return false;
    }
    return true;
  }

  static Future<Map<String, Object?>?> _one(
    Database db,
    String table,
    String assetId,
  ) async {
    final rows = await db.query(
      table,
      where: 'asset_id=?',
      whereArgs: [assetId],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  static bool _preferProgress(
    Map<String, Object?> ghost,
    Map<String, Object?> canonical,
  ) {
    final gDone = ghost['completed'] == 1, cDone = canonical['completed'] == 1;
    if (gDone != cDone) return gDone;
    final gp = ghost['position_ms'] as int? ?? 0;
    final cp = canonical['position_ms'] as int? ?? 0;
    if (gp > 0 && cp <= 0) return true;
    if (cp > 0 && gp <= 0) return false;
    return (ghost['updated_at']?.toString() ?? '').compareTo(
          canonical['updated_at']?.toString() ?? '',
        ) >
        0;
  }
}
