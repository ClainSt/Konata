import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'library_backup_exporter.dart';
import 'watch_event_store.dart';
import 'library_foundation.dart';
import 'scrape_tasks.dart';
import 'scan_recognition.dart';
import 'scoped_artwork.dart';
import 'chapter_relations.dart';
import 'library_merge.dart';
import 'incremental_scan.dart';
import 'anime_mapping_store.dart';

/// Read-only inspection. Never extracts files or changes a running library.
class LibraryBackupInspector {
  static const maxManifestBytes = 64 * 1024 * 1024;
  static const maxArtworkBytes = 32 * 1024 * 1024;
  static const maxTotalArtworkBytes = 512 * 1024 * 1024;

  static Future<LibraryBackupPreview> inspect(File zipFile) async =>
      (await read(zipFile)).preview;

  /// Extraction is only into a caller-owned staging directory. Never the live
  /// artwork directory: later validation can still reject this archive.
  static Future<LibraryBackupData> read(
    File zipFile, {
    Directory? staging,
  }) async {
    final stream = InputFileStream(zipFile.path);
    try {
      final archive = ZipDecoder().decodeStream(stream);
      final entries = <String, ArchiveFile>{};
      var artworkBytes = 0;
      for (final entry in archive.files) {
        if (!entry.isFile ||
            entry.isSymbolicLink ||
            entries.containsKey(entry.name)) {
          throw const FormatException('Invalid ZIP entry');
        }
        if (entry.name == 'manifest.json') {
          if (entry.size < 1 || entry.size > maxManifestBytes) {
            throw const FormatException('Invalid manifest size');
          }
        } else {
          final match = RegExp(r'^artwork/([^/]+)$').firstMatch(entry.name);
          if (match == null ||
              !LibraryBackupExporter.customArtworkName.hasMatch(
                match.group(1)!,
              )) {
            throw const FormatException('Unsupported ZIP path');
          }
          artworkBytes += entry.size;
          if (entry.size > maxArtworkBytes ||
              artworkBytes > maxTotalArtworkBytes) {
            throw const FormatException('Artwork exceeds size limit');
          }
        }
        entries[entry.name] = entry;
      }
      final manifestFile = entries['manifest.json'];
      if (manifestFile == null) {
        throw const FormatException('Missing backup manifest');
      }
      final bytes = manifestFile.readBytes();
      if (bytes == null || bytes.length > maxManifestBytes) {
        throw const FormatException('Invalid backup manifest');
      }
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map<String, dynamic> ||
          decoded['format'] != 'ccplayer-library' ||
          decoded['format_version'] != 1 ||
          ![
            15,
            16,
            17,
            18,
            19,
            20,
            21,
            22,
            23,
            24,
            25,
            26,
            27,
          ].contains(decoded['db_schema_version'])) {
        throw const FormatException('Unsupported backup format/schema');
      }
      final tables = decoded['tables'];
      final expectedTables =
          LibraryBackupExporter.tablesForSchema(
                decoded['db_schema_version'] as int,
              )
              .where(
                (name) =>
                    (decoded['db_schema_version'] != 15 ||
                        name != 'logical_episode_confirmations') &&
                    ((decoded['db_schema_version'] as int) >= 17 ||
                        name != 'watch_events') &&
                    ((decoded['db_schema_version'] as int) >= 18 ||
                        ![
                          'watch_identity_epochs',
                          'bangumi_episode_mappings',
                          'watch_event_origins',
                        ].contains(name)),
              )
              .toList();
      if (tables is! Map<String, dynamic> ||
          tables.length != expectedTables.length ||
          !tables.keys.toSet().containsAll(expectedTables)) {
        throw const FormatException('Backup tables missing');
      }
      for (final name in expectedTables) {
        final records = tables[name];
        if (records is! List ||
            records.any(
              (record) =>
                  record is! Map<String, dynamic> ||
                  record.values.any(
                    (v) => v != null && v is! num && v is! String,
                  ),
            )) {
          throw const FormatException('Invalid backup records');
        }
      }
      final sourceIds = (tables['sources'] as List).map((r) => r['id']).toSet();
      final workIds = (tables['works'] as List).map((r) => r['id']).toSet();
      final assetIds = (tables['assets'] as List).map((r) => r['id']).toSet();
      if (decoded['db_schema_version'] != 15) {
        final ids = <int>{};
        for (final row in tables['logical_episode_confirmations'] as List) {
          if (row['id'] is! int ||
              !ids.add(row['id'] as int) ||
              row['asset_id'] is! String ||
              row['logical_key'] is! String ||
              !RegExp(
                r'^tmdb:tv:[1-9][0-9]*:s[0-9]+:e[1-9][0-9]*$',
              ).hasMatch(row['logical_key'] as String) ||
              ![0, 1].contains(row['revoked']) ||
              row['created_at'] is! String ||
              DateTime.tryParse(row['created_at'] as String) == null) {
            throw const FormatException('Invalid episode confirmation');
          }
        }
      }
      if ((decoded['db_schema_version'] as int) >= 17) {
        WatchEventStore.validateGraph(
          (tables['watch_events'] as List)
              .map((r) => Map<String, Object?>.from(r as Map))
              .toList(),
        );
      }
      if ((decoded['db_schema_version'] as int) >= 18) {
        final events = {
          for (final r in tables['watch_events'] as List) r['event_id'],
        };
        final epochs = <String, int>{};
        for (final r in tables['watch_identity_epochs'] as List) {
          if (r['asset_id'] is! String ||
              epochs.containsKey(r['asset_id']) ||
              r['revision'] is! int ||
              r['revision'] < 0) {
            throw const FormatException('Invalid identity revision');
          }
          epochs[r['asset_id'] as String] = r['revision'] as int;
        }
        final origins = <Object?>{};
        for (final r in tables['watch_event_origins'] as List) {
          if (!events.contains(r['event_id']) ||
              !origins.add(r['event_id']) ||
              r['asset_id'] is! String ||
              !epochs.containsKey(r['asset_id']) ||
              r['revision'] is! int ||
              r['revision'] < 0 ||
              r['revision'] > epochs[r['asset_id']] ||
              ![0, 1].contains(r['invalidated']) ||
              ![0, 1].contains(r['retracted']) ||
              (r['retracted'] == 1 && r['invalidated'] != 1)) {
            throw const FormatException('Invalid event provenance');
          }
        }
        final mappingIds = <int>{};
        for (final r in tables['bangumi_episode_mappings'] as List) {
          if (r['id'] is! int ||
              !mappingIds.add(r['id'] as int) ||
              r['episode_key'] is! String ||
              !WatchEventStore.keyPattern.hasMatch(
                r['episode_key'] as String,
              ) ||
              r['asset_id'] is! String ||
              !epochs.containsKey(r['asset_id']) ||
              r['revision'] is! int ||
              r['revision'] < 0 ||
              r['revision'] > epochs[r['asset_id']] ||
              r['subject_id'] is! int ||
              r['subject_id'] < 1 ||
              r['episode_id'] is! int ||
              r['episode_id'] < 1 ||
              ![0, 1].contains(r['episode_type']) ||
              ![0, 1].contains(r['revoked']) ||
              r['episode_sort'] is! num ||
              !(r['episode_sort'] as num).isFinite ||
              r['episode_sort'] < 0 ||
              r['episode_name'] is! String ||
              r['verified_at'] is! String ||
              DateTime.tryParse(r['verified_at'] as String) == null) {
            throw const FormatException('Invalid Bangumi episode mapping');
          }
        }
      }
      for (final item in tables['assets'] as List) {
        if (!sourceIds.contains(item['source_id']) ||
            !workIds.contains(item['work_id'])) {
          throw const FormatException('Orphaned media entry');
        }
      }
      if ((decoded['db_schema_version'] as int) >= 19) {
        LibraryFoundation.validateSnapshot(tables);
      }
      if ((decoded['db_schema_version'] as int) >= 20) {
        ScrapeTasks.validateSnapshot(tables);
      }
      if ((decoded['db_schema_version'] as int) >= 21) {
        AnimeMappingStore.validateSnapshot(tables);
      }
      if ((decoded['db_schema_version'] as int) >= 22) {
        ScanRecognition.validateSnapshot(tables);
        IncrementalScan.validateSnapshot(tables);
      }
      if ((decoded['db_schema_version'] as int) >= 24) {
        ScopedArtwork.validateSnapshot(tables);
      }
      if ((decoded['db_schema_version'] as int) >= 25) {
        ChapterRelations.validateSnapshot(tables);
      }
      if ((decoded['db_schema_version'] as int) >= 26) {
        LibraryMerge.validateSnapshot(tables);
      }
      for (final record in tables['progress'] as List) {
        if (!assetIds.contains(record['asset_id'])) {
          throw const FormatException('Orphaned playback entry');
        }
      }
      final artwork = decoded['artwork'];
      if (artwork is! Map<String, dynamic> ||
          artwork.length != entries.length - 1) {
        throw const FormatException('Artwork manifest mismatch');
      }
      for (final item in artwork.entries) {
        if (!LibraryBackupExporter.customArtworkName.hasMatch(item.key) ||
            item.value is! String) {
          throw const FormatException('Invalid artwork hash');
        }
        final content = entries['artwork/${item.key}']?.readBytes();
        if (content == null ||
            sha256.convert(content).toString() != item.value ||
            item.key.split('_').last.replaceFirst('.png', '') != item.value) {
          throw const FormatException('Artwork checksum mismatch');
        }
        if (staging != null) {
          await File(
            p.join(staging.path, item.key),
          ).writeAsBytes(content, flush: true);
        }
      }
      final savedPrefs = decoded['preferences'];
      if (savedPrefs is! Map<String, dynamic> ||
          savedPrefs.keys.any(
            (k) => !LibraryBackupExporter.preferenceKeys.contains(k),
          )) {
        throw const FormatException('Invalid backup preferences');
      }
      const choices = {
        'theme_mode': ['system', 'light', 'dark'],
        'theme_accent': ['red', 'pink', 'lightBlue'],
        'ui_language': ['system', 'zhHans', 'zhHant', 'en'],
      };
      for (final entry in savedPrefs.entries) {
        if (entry.key == 'detail_backdrop_enabled'
            ? entry.value is! bool
            : entry.key == 'watched_completion_percent'
            ? entry.value is! int || entry.value < 1 || entry.value > 100
            : !(choices[entry.key]?.contains(entry.value) ?? false)) {
          throw const FormatException('Invalid preference value');
        }
      }
      final preview = LibraryBackupPreview(
        createdAt: DateTime.parse(decoded['created_at'] as String),
        works: (tables['works'] as List).length,
        assets: (tables['assets'] as List).length,
        sources: (tables['sources'] as List).length,
        history: (tables['progress'] as List).length,
        artwork: artwork.length,
      );
      return LibraryBackupData(decoded, preview);
    } finally {
      stream.closeSync();
    }
  }
}

class LibraryBackupData {
  const LibraryBackupData(this.manifest, this.preview);
  final Map<String, dynamic> manifest;
  final LibraryBackupPreview preview;
}

class LibraryBackupPreview {
  const LibraryBackupPreview({
    required this.createdAt,
    required this.works,
    required this.assets,
    required this.sources,
    required this.history,
    required this.artwork,
  });
  final DateTime createdAt;
  final int works, assets, sources, history, artwork;
}
