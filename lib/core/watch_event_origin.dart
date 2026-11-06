import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Local provenance. Only opaque event IDs and retractions cross devices.
abstract final class WatchEventOrigin {
  static Future<void> createSchema(DatabaseExecutor tx) async {
    await tx.execute('''CREATE TABLE IF NOT EXISTS watch_identity_epochs (
      asset_id TEXT PRIMARY KEY, revision INTEGER NOT NULL)''');
    await tx.execute('''CREATE TABLE IF NOT EXISTS watch_event_origins (
      event_id TEXT PRIMARY KEY, asset_id TEXT NOT NULL, revision INTEGER NOT NULL,
      invalidated INTEGER NOT NULL DEFAULT 0 CHECK(invalidated IN (0,1)),
      retracted INTEGER NOT NULL DEFAULT 0 CHECK(retracted IN (0,1)))''');
    await tx.execute(
      'CREATE INDEX IF NOT EXISTS watch_origins_asset ON watch_event_origins(asset_id)',
    );
    await tx.execute(
      'INSERT OR IGNORE INTO watch_identity_epochs SELECT id,1 FROM assets',
    );
    String bump(String asset) =>
        '''
      INSERT OR IGNORE INTO watch_identity_epochs VALUES ($asset,0);
      UPDATE watch_identity_epochs SET revision=revision+1 WHERE asset_id=$asset;
      UPDATE watch_event_origins SET invalidated=1 WHERE asset_id=$asset;
    ''';
    await tx.execute('''CREATE TRIGGER IF NOT EXISTS watch_asset_identity
      AFTER UPDATE OF work_id,category,season,episode,extra_type ON assets
      WHEN OLD.work_id IS NOT NEW.work_id OR OLD.category IS NOT NEW.category
        OR OLD.season IS NOT NEW.season OR OLD.episode IS NOT NEW.episode
        OR OLD.extra_type IS NOT NEW.extra_type
      BEGIN ${bump('NEW.id')} END''');
    await tx.execute('''CREATE TRIGGER IF NOT EXISTS watch_asset_removed
      AFTER DELETE ON assets BEGIN ${bump('OLD.id')} END''');
    await tx.execute('''CREATE TRIGGER IF NOT EXISTS watch_asset_inserted
      AFTER INSERT ON assets BEGIN ${bump('NEW.id')} END''');
    final tables = (await tx.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table'",
    )).map((r) => r['name']).toSet();
    for (final op
        in tables.contains('asset_overrides')
            ? ['INSERT', 'UPDATE', 'DELETE']
            : <String>[]) {
      final ref = op == 'DELETE' ? 'OLD' : 'NEW';
      await tx.execute(
        '''CREATE TRIGGER IF NOT EXISTS watch_override_${op.toLowerCase()}
        AFTER $op ON asset_overrides
        ${op == 'UPDATE' ? 'WHEN OLD.work_id IS NOT NEW.work_id OR OLD.category IS NOT NEW.category OR OLD.season IS NOT NEW.season OR OLD.episode IS NOT NEW.episode OR OLD.extra_type IS NOT NEW.extra_type' : ''}
        BEGIN ${bump('$ref.asset_id')} END''',
      );
    }
    await tx.execute(
      '''CREATE TRIGGER IF NOT EXISTS watch_confirmation_inserted
      AFTER INSERT ON logical_episode_confirmations BEGIN ${bump('NEW.asset_id')} END''',
    );
    await tx.execute('''CREATE TRIGGER IF NOT EXISTS watch_work_identity
      AFTER UPDATE OF tmdb_id,tmdb_type ON works
      WHEN OLD.tmdb_id IS NOT NEW.tmdb_id OR OLD.tmdb_type IS NOT NEW.tmdb_type
      BEGIN
        UPDATE watch_identity_epochs SET revision=revision+1
          WHERE asset_id IN (SELECT id FROM assets WHERE work_id=NEW.id);
        UPDATE watch_event_origins SET invalidated=1
          WHERE asset_id IN (SELECT id FROM assets WHERE work_id=NEW.id);
      END''');
    await tx.execute('''CREATE TRIGGER IF NOT EXISTS watch_work_removed
      AFTER DELETE ON works BEGIN
        UPDATE watch_identity_epochs SET revision=revision+1
          WHERE asset_id IN (SELECT id FROM assets WHERE work_id=OLD.id);
        UPDATE watch_event_origins SET invalidated=1
          WHERE asset_id IN (SELECT id FROM assets WHERE work_id=OLD.id);
      END''');
  }

  static Future<int> revision(DatabaseExecutor tx, String assetId) async {
    final rows = await tx.query(
      'watch_identity_epochs',
      where: 'asset_id=?',
      whereArgs: [assetId],
    );
    return rows.isEmpty ? 0 : rows.single['revision'] as int;
  }

  static Future<void> attach(
    DatabaseExecutor tx,
    String eventId,
    String assetId,
  ) async {
    await tx.insert('watch_event_origins', {
      'event_id': eventId,
      'asset_id': assetId,
      'revision': await revision(tx, assetId),
    });
  }
}
