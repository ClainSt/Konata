import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Portable, read-only export. Media files and secure-storage tokens are excluded.
class LibraryBackupExporter {
  const LibraryBackupExporter({
    required this.database,
    required this.artworkDirectory,
    required this.preferences,
  });

  final Database database;
  final Directory artworkDirectory;
  final SharedPreferences preferences;

  static const tables = [
    'sources', 'works', 'assets', 'progress', 'work_details',
    'asset_overrides', 'asset_override_history', 'phantom_asset_archive',
    'logical_episode_confirmations',
    'watch_events',
    'watch_identity_epochs', 'watch_event_origins',
    'bangumi_episode_mappings',
  ];
  static const preferenceKeys = [
    'theme_mode', 'theme_accent', 'ui_language', 'watched_completion_percent',
  ];
  static final customArtworkName = RegExp(
    r'^(?:original|crop)_[a-f0-9]{64}\.png$',
  );

  /// Fails rather than overwriting a backup. Does not modify the library.
  Future<File> export(File destination) async {
    if (await destination.exists()) {
      throw StateError('The destination file already exists');
    }
    final snapshot = await database.transaction((tx) async {
      final data = <String, List<Map<String, Object?>>>{};
      for (final table in tables) {
        data[table] = [
          for (final row in await tx.query(table))
            if (table == 'sources')
              <String, Object?>{
                ...row,
                'password': null,
                'username': null,
                'location': redactLocation(row['location']?.toString() ?? ''),
              }
            else
              {...row},
        ];
      }
      return data;
    }, exclusive: false);

    final images = <File>[];
    final checksums = <String, String>{};
    var totalBytes = 0;
    if (await artworkDirectory.exists()) {
      await for (final entity in artworkDirectory.list(followLinks: false)) {
        if (entity is! File) continue;
        final filename = p.basename(entity.path);
        if (!customArtworkName.hasMatch(filename)) continue;
        final bytes = await entity.length();
        totalBytes += bytes;
        if (bytes > 32 * 1024 * 1024 || totalBytes > 512 * 1024 * 1024) {
          throw const FormatException('Custom artwork exceeds backup limits');
        }
        final digest = (await sha256.bind(entity.openRead()).first).toString();
        if (digest != filename.substring(filename.indexOf('_') + 1, filename.length - 4)) {
          throw const FormatException('Custom artwork checksum mismatch');
        }
        images.add(entity);
        checksums[filename] = digest;
      }
    }
    images.sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));

    final manifest = utf8.encode(jsonEncode({
      'format': 'ccplayer-library',
      'format_version': 1,
      'db_schema_version': await database.getVersion(),
      'created_at': DateTime.now().toUtc().toIso8601String(),
      'tables': snapshot,
      'preferences': {
        for (final key in preferenceKeys)
          if (preferences.get(key) is String || preferences.get(key) is int)
            key: preferences.get(key),
      },
      'artwork': checksums,
    }));
    if (manifest.length > 64 * 1024 * 1024) {
      throw const FormatException('Library metadata exceeds backup limits');
    }

    await destination.parent.create(recursive: true);
    final zip = ZipFileEncoder();
    var open = false;
    try {
      zip.create(destination.path);
      open = true;
      zip.addArchiveFile(ArchiveFile.bytes('manifest.json', manifest));
      for (final image in images) {
        await zip.addFile(image, 'artwork/${p.basename(image.path)}');
      }
      await zip.close();
      open = false;
      return destination;
    } catch (_) {
      if (open) {
        try { await zip.close(); } catch (_) {}
      }
      if (await destination.exists()) await destination.delete();
      rethrow;
    }
  }

  static String redactLocation(String raw) {
    final uri = Uri.tryParse(raw);
    if (uri == null || !uri.hasAuthority) return raw;
    const sensitive = {
      'token', 'access_token', 'api_key', 'key',
      'password', 'secret', 'signature', 'authorization', 'auth',
    };
    final safeQuery = {
      for (final entry in uri.queryParameters.entries)
        if (!sensitive.contains(entry.key.toLowerCase()))
          entry.key: entry.value,
    };
    return uri.replace(
      userInfo: '',
      queryParameters: uri.hasQuery && safeQuery.isNotEmpty ? safeQuery : null,
    ).toString();
  }
}
