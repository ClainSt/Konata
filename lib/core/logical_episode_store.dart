import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'logical_episode_identity.dart';

/// Confirmations are append-only; revocation never changes a physical file or
/// its progress. Current manual episode corrections take precedence.
class LogicalEpisodeStore {
  const LogicalEpisodeStore(this.db);
  final Database db;

  static Future<void> createSchema(DatabaseExecutor db) async {
    await db.execute(
      '''CREATE TABLE IF NOT EXISTS logical_episode_confirmations (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      asset_id TEXT NOT NULL, logical_key TEXT NOT NULL,
      revoked INTEGER NOT NULL DEFAULT 0 CHECK(revoked IN (0,1)),
      created_at TEXT NOT NULL)''',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS logical_confirmation_asset '
      'ON logical_episode_confirmations(asset_id,id)',
    );
  }

  static Future<String?> _candidate(
    DatabaseExecutor tx,
    String assetId, {
    bool manualOnly = false,
  }) async {
    final rows = await tx.rawQuery(
      '''SELECT a.*, w.tmdb_id, w.tmdb_type,
      o.asset_id AS manual_asset, o.work_id AS manual_work,
      o.category AS manual_category, o.season AS manual_season,
      o.episode AS manual_episode
      FROM assets a JOIN works w ON w.id=a.work_id
      LEFT JOIN asset_overrides o ON o.asset_id=a.id WHERE a.id=?''',
      [assetId],
    );
    if (rows.isEmpty) return null;
    final row = rows.single;
    final manual = row['manual_asset'] != null;
    if (manualOnly && !manual) return null;
    // An inconsistent override is never evidence for a different work.
    if (manual && row['manual_work'] != row['work_id']) return null;
    return LogicalEpisodeIdentity.forAsset(
      work: row,
      asset: {
        ...row,
        if (manual) ...{
          'category': row['manual_category'],
          'season': row['manual_season'],
          'episode': row['manual_episode'],
        },
      },
      confirmedSpecial: manual,
    );
  }

  /// Explicit confirmation requires the exact candidate the caller reviewed.
  /// A concurrent scraper correction aborts rather than confirming stale data.
  Future<void> confirm(String assetId, String expectedKey) async {
    await db.transaction((tx) async {
      if (await _candidate(tx, assetId) != expectedKey) {
        throw StateError('Episode identity changed or is ambiguous');
      }
      if (await resolveIn(tx, assetId) == expectedKey) return;
      await tx.insert('logical_episode_confirmations', {
        'asset_id': assetId,
        'logical_key': expectedKey,
        'created_at': DateTime.now().toUtc().toIso8601String(),
      });
    });
  }

  Future<void> revoke(String assetId) async {
    await db.transaction((tx) async {
      final rows = await tx.query(
        'logical_episode_confirmations',
        where: 'asset_id=?',
        whereArgs: [assetId],
        orderBy: 'id DESC',
        limit: 1,
      );
      if (rows.isEmpty || rows.single['revoked'] == 1) return;
      await tx.insert('logical_episode_confirmations', {
        'asset_id': assetId,
        'logical_key': rows.single['logical_key'],
        'revoked': 1,
        'created_at': DateTime.now().toUtc().toIso8601String(),
      });
    });
  }

  Future<String?> resolve(String assetId) =>
      db.transaction((tx) => resolveIn(tx, assetId));

  static Future<String?> resolveIn(DatabaseExecutor tx, String assetId) async {
    final manual = await _candidate(tx, assetId, manualOnly: true);
    if (manual != null) return manual;
    // A manual "other" mapping must also block older confirmations.
    if ((await tx.query(
      'asset_overrides',
      columns: ['asset_id'],
      where: 'asset_id=?',
      whereArgs: [assetId],
    )).isNotEmpty) {
      return null;
    }
    final candidate = await _candidate(tx, assetId);
    if (candidate == null) return null;
    final rows = await tx.query(
      'logical_episode_confirmations',
      where: 'asset_id=?',
      whereArgs: [assetId],
      orderBy: 'id DESC',
      limit: 1,
    );
    if (rows.isEmpty ||
        rows.single['revoked'] == 1 ||
        rows.single['logical_key'] != candidate) {
      return null;
    }
    return candidate;
  }
}
