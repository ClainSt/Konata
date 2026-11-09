import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Persistent, content-addressed artwork. SQLite tracks URL aliases and owners;
/// no directory walk or whole-library JSON rewrite occurs on an image download.
class ArtworkCache {
  ArtworkCache(this.root, {this.singleInstance = true});
  final Directory root;
  final bool singleInstance;
  Future<Database>? _opening;
  Directory get images => Directory(p.join(root.path, 'images'));
  static String digest(String value) =>
      sha256.convert(utf8.encode(value)).toString();

  Future<Database> get database => _opening ??= _open();
  Future<Database> _open() async {
    await images.create(recursive: true);
    final factory = Platform.isAndroid || Platform.isIOS
        ? databaseFactory
        : databaseFactoryFfi;
    if (!Platform.isAndroid && !Platform.isIOS) sqfliteFfiInit();
    return factory.openDatabase(
      p.join(root.path, 'cache-index.sqlite'),
      options: OpenDatabaseOptions(
        singleInstance: singleInstance,
        version: 1,
        onCreate: (db, _) async {
          await db.execute(
            'CREATE TABLE images (key TEXT PRIMARY KEY, file TEXT NOT NULL, bytes INTEGER NOT NULL, quality INTEGER NOT NULL)',
          );
          await db.execute('CREATE INDEX image_files ON images(file)');
          await db.execute(
            'CREATE TABLE owners (owner TEXT NOT NULL, key TEXT NOT NULL, PRIMARY KEY(owner,key))',
          );
          await db.execute('CREATE INDEX image_owners ON owners(key)');
          await db.execute(
            'CREATE TABLE data (owner TEXT NOT NULL, key TEXT NOT NULL, payload TEXT NOT NULL, PRIMARY KEY(owner,key))',
          );
        },
      ),
    );
  }

  Future<void> close() async {
    final opening = _opening;
    _opening = null;
    if (opening != null) await (await opening).close();
  }

  Future<void> retain(String owner, Iterable<String> keys) async {
    final db = await database;
    final batch = db.batch();
    for (final key in keys.toSet()) {
      batch.insert('owners', {
        'owner': owner,
        'key': key,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    }
    await batch.commit(noResult: true);
  }

  Future<Uint8List?> read(String key, {int minimumQuality = 0}) async {
    final db = await database;
    final rows = await db.query(
      'images',
      columns: ['file'],
      where: 'key=? AND quality>=?',
      whereArgs: [key, minimumQuality],
    );
    if (rows.isEmpty) return null;
    final file = File(p.join(images.path, rows.single['file'] as String));
    try {
      return await file.readAsBytes();
    } on FileSystemException {
      return null; // A user may have removed the file in the directory viewer.
    }
  }

  Future<void> invalidate(String key) async {
    final db = await database;
    await db.transaction((tx) async {
      final rows = await tx.query(
        'images',
        columns: ['file'],
        where: 'key=?',
        whereArgs: [key],
      );
      if (rows.isEmpty) return;
      final name = rows.single['file'] as String;
      await tx.delete('images', where: 'file=?', whereArgs: [name]);
      final file = File(p.join(images.path, name));
      if (await file.exists()) await file.delete();
    });
  }

  Future<void> write(
    String key,
    Uint8List bytes, {
    void Function()? checkActive,
    int quality = 0,
  }) async {
    final db = await database;
    final hash = sha256.convert(bytes).toString();
    final extension =
        bytes.length > 12 &&
            ascii.decode(bytes.sublist(0, 4), allowInvalid: true) == 'RIFF'
        ? 'webp'
        : bytes.length > 3 && bytes[0] == 0xff && bytes[1] == 0xd8
        ? 'jpg'
        : bytes.length > 3 && bytes[0] == 0x47 && bytes[1] == 0x49
        ? 'gif'
        : 'png';
    final name = '${hash.substring(0, 2)}/$hash.$extension';
    final file = File(p.join(images.path, name));
    await db.transaction((tx) async {
      checkActive?.call();
      final old = await tx.query('images', where: 'key=?', whereArgs: [key]);
      if (old.isNotEmpty &&
          (old.single['quality'] as int) > quality &&
          await File(
            p.join(images.path, old.single['file'] as String),
          ).exists()) {
        return;
      }
      final previouslyUsed = await tx.query(
        'images',
        where: 'file=?',
        whereArgs: [name],
        limit: 1,
      );
      final intact =
          await file.exists() &&
          await file.length() == bytes.length &&
          (await sha256.bind(file.openRead()).first).toString() == hash;
      if (!intact) {
        await file.parent.create(recursive: true);
        final temporary = File('${file.path}.part');
        try {
          await temporary.writeAsBytes(bytes, flush: true);
          checkActive?.call();
          // Windows cannot rename over an existing corrupt file.
          if (await file.exists()) await file.delete();
          await temporary.rename(file.path);
        } finally {
          if (await temporary.exists()) await temporary.delete();
        }
      }
      try {
        checkActive?.call();
        await tx.insert('images', {
          'key': key,
          'file': name,
          'bytes': bytes.length,
          'quality': quality,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
        checkActive?.call();
      } catch (_) {
        if (previouslyUsed.isEmpty && await file.exists()) await file.delete();
        rethrow;
      }
      if (old.isNotEmpty && old.single['file'] != name) {
        final previous = old.single['file'] as String;
        if ((await tx.query(
          'images',
          where: 'file=?',
          whereArgs: [previous],
          limit: 1,
        )).isEmpty) {
          final obsolete = File(p.join(images.path, previous));
          if (await obsolete.exists()) await obsolete.delete();
        }
      }
    });
  }

  Future<Object?> readData(String owner, String key) async {
    final db = await database;
    final rows = await db.query(
      'data',
      columns: ['payload'],
      where: 'owner=? AND key=?',
      whereArgs: [owner, key],
    );
    if (rows.isEmpty) return null;
    try {
      return jsonDecode(rows.single['payload'] as String);
    } catch (_) {
      return null;
    }
  }

  Future<void> writeData(
    String owner,
    String key,
    Object value, {
    required void Function() checkActive,
  }) async {
    final db = await database;
    await db.transaction((tx) async {
      checkActive();
      await tx.insert('data', {
        'owner': owner,
        'key': key,
        'payload': jsonEncode(value),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      checkActive();
      await tx.rawDelete(
        'DELETE FROM data WHERE owner=? AND rowid NOT IN (SELECT rowid FROM data WHERE owner=? ORDER BY rowid DESC LIMIT 8)',
        [owner, owner],
      );
      checkActive();
    });
  }

  /// Only explicit work removal drops owned artwork. Other works' references
  /// and user-imported originals (outside images/) are preserved.
  Future<void> removeOwner(String owner) async {
    final db = await database;
    await db.transaction((tx) async {
      final keys = await tx.query(
        'owners',
        columns: ['key'],
        where: 'owner=?',
        whereArgs: [owner],
      );
      await tx.delete('owners', where: 'owner=?', whereArgs: [owner]);
      await tx.delete('data', where: 'owner=?', whereArgs: [owner]);
      for (final row in keys) {
        final key = row['key'];
        final shared = await tx.query(
          'owners',
          where: 'key=?',
          whereArgs: [key],
          limit: 1,
        );
        if (shared.isNotEmpty) continue;
        final entries = await tx.query(
          'images',
          where: 'key=?',
          whereArgs: [key],
        );
        await tx.delete('images', where: 'key=?', whereArgs: [key]);
        for (final entry in entries) {
          final file = entry['file'] as String;
          if ((await tx.query(
            'images',
            where: 'file=?',
            whereArgs: [file],
            limit: 1,
          )).isEmpty) {
            final target = File(p.join(images.path, file));
            if (await target.exists()) await target.delete();
          }
        }
      }
    });
  }

  /// A library replacement can remove works without invoking per-work removal.
  /// Keep hidden works and shared images; user originals are outside images/.
  Future<void> reconcileOwners(Set<String> validOwners) async {
    final db = await database;
    final rows = await db.rawQuery(
      'SELECT owner FROM owners UNION SELECT owner FROM data',
    );
    for (final row in rows) {
      final owner = row['owner'] as String;
      if (!validOwners.contains(owner)) await removeOwner(owner);
    }
  }

  /// Preview/search images have no work owner. Bound only this disposable pool.
  Future<void> trimUnowned({int limit = 256 * 1024 * 1024}) async {
    final db = await database;
    final total =
        (await db.rawQuery(
              'SELECT SUM(bytes) AS bytes FROM images WHERE key NOT IN (SELECT key FROM owners)',
            )).single['bytes']
            as int? ??
        0;
    if (total <= limit) return;
    var remaining = total;
    await db.transaction((tx) async {
      final rows = await tx.rawQuery(
        'SELECT rowid, * FROM images WHERE key NOT IN (SELECT key FROM owners) ORDER BY rowid',
      );
      for (final row in rows) {
        if (remaining <= limit) break;
        await tx.delete('images', where: 'key=?', whereArgs: [row['key']]);
        remaining -= row['bytes'] as int;
        if ((await tx.query(
          'images',
          where: 'file=?',
          whereArgs: [row['file']],
          limit: 1,
        )).isEmpty) {
          final file = File(p.join(images.path, row['file'] as String));
          if (await file.exists()) await file.delete();
        }
      }
    });
  }
}
