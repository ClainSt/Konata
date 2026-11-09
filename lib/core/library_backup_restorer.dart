import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'library_backup_exporter.dart';
import 'library_backup_inspector.dart';
import 'artwork_cache.dart';
import 'debug_log.dart';

/// A private, validated copy keeps the confirmation preview and restore identical
/// even if the original file is replaced while the dialog is open.
class PreparedLibraryBackup {
  PreparedLibraryBackup._(this.directory, this.data);
  final Directory directory;
  final LibraryBackupData data;
  LibraryBackupPreview get preview => data.preview;
  Future<void> dispose() => directory.delete(recursive: true);

  static Future<PreparedLibraryBackup> open(
    File input, {
    Directory? workspace,
  }) async {
    if (await input.length() > 600 * 1024 * 1024) {
      throw const FormatException('Backup exceeds size limit');
    }
    final base = workspace ?? await getTemporaryDirectory();
    await base.create(recursive: true);
    final temp = await base.createTemp('konata-restore-');
    try {
      final copy = await input.copy(p.join(temp.path, 'backup.zip'));
      final images = await Directory(p.join(temp.path, 'artwork')).create();
      return PreparedLibraryBackup._(
        temp,
        await LibraryBackupInspector.read(copy, staging: images),
      );
    } catch (_) {
      await temp.delete(recursive: true);
      rethrow;
    }
  }
}

class LibraryBackupRestorer {
  LibraryBackupRestorer({
    required this.database,
    required this.artworkDirectory,
    this.preferences,
  });
  final Database database;
  final Directory artworkDirectory;
  final SharedPreferences? preferences;
  bool _running = false;

  Directory get recoveryDirectory =>
      Directory(p.join(p.dirname(database.path), 'restore-backups'));

  Directory get stagingDirectory =>
      Directory(p.join(p.dirname(database.path), 'restore-staging'));

  Future<PreparedLibraryBackup> prepare(File input) =>
      PreparedLibraryBackup.open(input, workspace: stagingDirectory);

  /// Only called at startup, before any new restore can be prepared.
  Future<void> clearAbandonedStaging() async {
    if (await stagingDirectory.exists()) {
      await stagingDirectory.delete(recursive: true);
    }
  }

  static Future<void> createSchema(DatabaseExecutor db) async {
    await db.execute('''CREATE TABLE IF NOT EXISTS library_restore_state (
      id INTEGER PRIMARY KEY CHECK(id=1), committed INTEGER NOT NULL,
      old_preferences TEXT NOT NULL, new_preferences TEXT NOT NULL,
      added_artwork TEXT NOT NULL)''');
    // Old secure-storage entries remain available for rollback, but are never
    // silently attached to sources imported from a portable archive.
    await db.execute('''CREATE TABLE IF NOT EXISTS library_restored_sources (
      source_id TEXT PRIMARY KEY)''');
  }

  Future<void> _preferences(Map<String, dynamic> values) async {
    final preferences =
        this.preferences ?? await SharedPreferences.getInstance();
    for (final key in LibraryBackupExporter.preferenceKeys) {
      final value = values[key];
      final saved = value == null
          ? await preferences.remove(key)
          : value is bool
          ? await preferences.setBool(key, value)
          : value is int
          ? await preferences.setInt(key, value)
          : await preferences.setString(key, value as String);
      if (!saved) throw StateError('Could not persist restored settings');
    }
  }

  /// SQLite is the commit authority. A crash during preference writes therefore
  /// resolves to the old settings or the new settings, never a mixed snapshot.
  /// Must run before loading application settings or exposing the catalog.
  Future<void> recover() async {
    await createSchema(database);
    final rows = await database.query('library_restore_state');
    if (rows.isEmpty) return;
    final state = rows.single;
    final committed = state['committed'] != 0;
    // State 2 only awaits disposable-cache cleanup. The user may have changed
    // settings since the successful restore, so do not replay preferences.
    if (state['committed'] != 2) {
      await _preferences(
        jsonDecode(
              state[committed ? 'new_preferences' : 'old_preferences']
                  as String,
            )
            as Map<String, dynamic>,
      );
    }
    if (!committed) {
      for (final name in jsonDecode(state['added_artwork'] as String) as List) {
        if (name is! String ||
            !LibraryBackupExporter.customArtworkName.hasMatch(name)) {
          throw const FormatException('Invalid restore journal');
        }
        final file = File(p.join(artworkDirectory.path, name));
        if (await file.exists()) await file.delete();
      }
    }
    // A rollback can also have superseded a previous cache-cleanup retry.
    // Reconcile against whichever library SQLite retained, after settling its
    // preferences/artwork, and keep the cache-only marker until cleanup works.
    await database.update('library_restore_state', {
      'committed': 2,
    }, where: 'id=1');
    if (!await _reconcileArtwork()) return;
    await database.delete('library_restore_state');
  }

  Future<bool> _reconcileArtwork() async {
    // Do not create a cache merely to restore a library. A separate connection
    // lets maintenance finish without closing the running ImageStore handle.
    final index = File(p.join(artworkDirectory.path, 'cache-index.sqlite'));
    ArtworkCache? cache;
    try {
      if (!await index.exists()) return true;
      final owners = {
        for (final work in await database.query('works', columns: ['id']))
          work['id'] as String,
      };
      cache = ArtworkCache(artworkDirectory, singleInstance: false);
      await cache.reconcileOwners(owners);
      return true;
    } catch (error, stack) {
      // The library is already committed. Keep its journal for a startup retry
      // rather than reporting a failed restore or rolling back user data.
      DebugLog.exception('Backup', 'artwork_reconcile_failed', error, stack);
      return false;
    } finally {
      try {
        await cache?.close();
      } catch (_) {}
    }
  }

  Future<List<File>> recoveryBackups() async {
    if (!await recoveryDirectory.exists()) return [];
    final files = await recoveryDirectory
        .list(followLinks: false)
        .where(
          (entry) =>
              entry is File &&
              RegExp(
                r'^before-restore-[0-9]+\.zip$',
              ).hasMatch(p.basename(entry.path)),
        )
        .cast<File>()
        .toList();
    files.sort((a, b) => b.path.compareTo(a.path));
    return files;
  }

  /// Caller holds the modal UI and rejects active playback/scans. This service
  /// never downloads media, contacts sources, or modifies credentials.
  Future<File> restore(PreparedLibraryBackup backup) async {
    if (_running) throw StateError('Restore already running');
    _running = true;
    try {
      await recover();
      final preferences =
          this.preferences ?? await SharedPreferences.getInstance();
      final manifest = backup.data.manifest;
      final tables = manifest['tables'] as Map<String, dynamic>;
      await _validateRows(tables);
      final artwork = manifest['artwork'] as Map<String, dynamic>;
      final added = <String>[];
      await artworkDirectory.create(recursive: true);
      for (final entry in artwork.entries) {
        final file = File(p.join(artworkDirectory.path, entry.key));
        final type = await FileSystemEntity.type(file.path, followLinks: false);
        if (type == FileSystemEntityType.notFound) {
          added.add(entry.key);
        } else if (type != FileSystemEntityType.file ||
            (await sha256.bind(file.openRead()).first).toString() !=
                entry.value) {
          throw const FormatException('Existing artwork differs from backup');
        }
      }
      // Keep the most recent earlier recovery point plus this new one. Only
      // files created by this service in its private directory are rotated.
      final previous = await recoveryBackups();
      for (final file in previous.skip(1)) {
        await file.delete();
      }
      final rollback = File(
        p.join(
          recoveryDirectory.path,
          'before-restore-${DateTime.now().microsecondsSinceEpoch}.zip',
        ),
      );
      await LibraryBackupExporter(
        database: database,
        artworkDirectory: artworkDirectory,
        preferences: preferences,
      ).export(rollback);
      await database.transaction((tx) async {
        // A settled restore may still await disposable-cache cleanup. The new
        // restore will reconcile that same cache against its committed library.
        // Never supersede an unsettled journal: its row makes INSERT abort.
        await tx.delete('library_restore_state', where: 'id=1 AND committed=2');
        await tx.insert('library_restore_state', {
          'id': 1,
          'committed': 0,
          'old_preferences': jsonEncode({
            for (final key in LibraryBackupExporter.preferenceKeys)
              key: preferences.get(key),
          }),
          'new_preferences': jsonEncode(manifest['preferences']),
          'added_artwork': jsonEncode(added),
        });
      });
      try {
        for (final name in added) {
          // Content was hash checked in the private staging directory.
          final bytes = await File(
            p.join(backup.directory.path, 'artwork', name),
          ).readAsBytes();
          await File(
            p.join(artworkDirectory.path, name),
          ).writeAsBytes(bytes, flush: true);
        }
        await database.transaction((tx) async {
          for (final table in LibraryBackupExporter.tables.reversed) {
            await tx.delete(table);
          }
          await tx.delete('scan_roots');
          await tx.delete('library_restored_sources');
          // Never reuse an imported device identity or an old sequence counter.
          await tx.delete('watch_event_local');
          for (final table in LibraryBackupExporter.tables) {
            // Identity triggers run while assets/overrides are inserted. Replace
            // their derived epochs only after all identity-changing inserts.
            if (table == 'watch_identity_epochs') await tx.delete(table);
            for (final raw in (tables[table] as List? ?? [])) {
              final row = Map<String, Object?>.from(raw as Map);
              if (table == 'sources') {
                row['username'] = null;
                row['password'] = null;
                row['location'] = LibraryBackupExporter.redactLocation(
                  row['location'] as String,
                );
                await tx.insert('library_restored_sources', {
                  'source_id': row['id'],
                });
              }
              // Default INSERT aborts conflicts without overriding the OR IGNORE
              // used inside the identity-maintenance triggers.
              await tx.insert(table, row);
            }
          }
          await _preferences(manifest['preferences'] as Map<String, dynamic>);
          // Preferences are settled before this transaction commits. Persist
          // the cache-only phase atomically with the new library, not later.
          await tx.update('library_restore_state', {
            'committed': 2,
          }, where: 'id=1');
        });
      } catch (_) {
        await recover(); // Transaction rolled back; restore preferences/images.
        rethrow;
      }
      // Cache cleanup is retryable after commit and cannot roll back user data.
      try {
        if (await _reconcileArtwork()) {
          await database.delete('library_restore_state');
        }
      } catch (_) {}
      return rollback;
    } finally {
      _running = false;
    }
  }

  Future<void> _validateRows(Map<String, dynamic> tables) async {
    for (final table in LibraryBackupExporter.tables) {
      final columns = {
        for (final col in await database.rawQuery('PRAGMA table_info($table)'))
          col['name'] as String: col,
      };
      for (final raw in tables[table] as List? ?? []) {
        final row = raw as Map;
        if (row.keys.any((key) => !columns.containsKey(key))) {
          throw const FormatException('Unsupported backup column');
        }
        for (final entry in columns.entries) {
          final value = row[entry.key];
          final column = entry.value;
          if (value == null) {
            if (column['pk'] != 0 ||
                (column['notnull'] == 1 &&
                    (row.containsKey(entry.key) ||
                        column['dflt_value'] == null))) {
              throw const FormatException('Missing required backup field');
            }
          } else if (switch (column['type']) {
            'TEXT' => value is! String,
            'INTEGER' => value is! int,
            'REAL' => value is! num || !value.isFinite,
            _ => true,
          }) {
            throw const FormatException('Invalid backup field type');
          }
        }
      }
    }
  }
}
