import 'dart:convert';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'auto_classifier.dart';
import 'anime_mapping_store.dart';
import 'catalog.dart';
import 'debug_log.dart';
import 'library_foundation.dart';
import 'local_media.dart';
import 'personal_filename_parser.dart';
import 'scan_activity.dart';
import 'scrape_tasks.dart';
import 'selected_scanner.dart';
import 'sources.dart';

typedef ScanEntry = ({String name, bool directory, int? size});

/// Directory enumeration and publication are separate. A stopped enumeration
/// retains its queue, but cannot publish a disappearance or a duplicate move.
class IncrementalScan {
  IncrementalScan(this.catalog);
  final Catalog catalog;
  ScrapeTasks get tasks => catalog.taskStore!;

  static const portableTables = ['scan_move_reviews'];

  static Future<void> createSchema(DatabaseExecutor tx) async {
    await tx.execute('''CREATE TABLE scan_directory_checkpoints (
      source_id TEXT NOT NULL, generation INTEGER NOT NULL, path TEXT NOT NULL,
      root TEXT NOT NULL, root_has_video INTEGER, complete INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY(source_id,path))''');
    await tx.execute('''CREATE TABLE scan_discoveries (
      source_id TEXT NOT NULL, path TEXT NOT NULL, folder TEXT NOT NULL, size INTEGER,
      PRIMARY KEY(source_id,path))''');
    await tx.execute('''CREATE TABLE scan_missing_assets (
      asset_id TEXT PRIMARY KEY)''');
    await tx.execute('''CREATE TABLE scan_move_reviews (
      source_id TEXT NOT NULL, folder TEXT NOT NULL, revision INTEGER NOT NULL,
      evidence TEXT NOT NULL, skipped INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY(source_id,folder))''');
    await tx.execute(
      '''CREATE TRIGGER scan_phase4_source_removed AFTER DELETE ON sources BEGIN
      DELETE FROM scan_directory_checkpoints WHERE source_id=OLD.id;
      DELETE FROM scan_discoveries WHERE source_id=OLD.id;
      DELETE FROM scan_move_reviews WHERE source_id=OLD.id;
      END''',
    );
    await tx.execute(
      '''CREATE TRIGGER scan_phase4_asset_removed AFTER DELETE ON assets BEGIN
      DELETE FROM scan_missing_assets WHERE asset_id=OLD.id;
      END''',
    );
  }

  static Future<void> clearCheckpoints(
    DatabaseExecutor tx, {
    String? source,
  }) async {
    for (final table in ['scan_directory_checkpoints', 'scan_discoveries']) {
      await tx.delete(
        table,
        where: source == null ? null : 'source_id=?',
        whereArgs: source == null ? null : [source],
      );
    }
  }

  static bool _inside(String path, String folder) =>
      folder.isEmpty || path.startsWith('$folder/');

  Future<void> run(
    TaskLease lease,
    Map<String, Object?> source,
    List<Map<String, Object?>> selected, {
    String? timingId,
    Future<void> Function(List<String> works)? startPriority,
  }) async {
    final sourceId = lease.sourceId!;
    final local = source['kind'] == 'local';
    final base = source['location'] as String;
    final localName = local ? LocalMedia.label(base) : '';
    final dav = local
        ? null
        : WebDav(await catalog.withCredentials(source), reuseListings: true);
    final roots = [
      for (final row in SelectedScanner.nonOverlappingRoots(selected))
        Catalog.normalizeRoot(row['relative_path'] as String),
    ];
    // SMB shares a session. Local and WebDAV listings can overlap safely.
    final listingWindow = source['kind'] == 'smb' ? 1 : 4;
    final activity = ScanActivityStore.instance;
    if (catalog.scanning) throw StateError('Scan already running');
    final run = activity.begin(sourceId, roots);
    final enumeration = Stopwatch()..start();
    catalog.updateStatus('正在扫描已选目录', true);
    try {
      await tasks.db.transaction((tx) async {
        await tasks.checkIn(tx, lease);
        final existing = await tx.query(
          'scan_directory_checkpoints',
          where: 'source_id=? AND generation=?',
          whereArgs: [sourceId, lease.generation],
          limit: 1,
        );
        if (existing.isNotEmpty) {
          final folders = {
            for (final row in await tx.query(
              'scan_directory_checkpoints',
              columns: ['path'],
              where: 'source_id=? AND generation=? AND complete=1',
              whereArgs: [sourceId, lease.generation],
            ))
              row['path'] as String: 0,
          };
          for (final row in await tx.query(
            'scan_discoveries',
            columns: ['path'],
            where: 'source_id=?',
            whereArgs: [sourceId],
          )) {
            final path = row['path'] as String;
            final separator = path.lastIndexOf('/');
            final folder = separator < 0 ? '' : path.substring(0, separator);
            folders.update(folder, (count) => count + 1);
          }
          activity.restoreFolders(sourceId, folders);
          return;
        }
        await tx.update('scrape_steps', {'result_json': null},
          where: 'task_id=? AND step=?', whereArgs: [lease.taskId, lease.step]);
        await clearCheckpoints(tx, source: sourceId);
        for (final root in roots) {
          await tx.insert('scan_directory_checkpoints', {
            'source_id': sourceId,
            'generation': lease.generation,
            'path': root,
            'root': root,
          });
        }
      });
      while (true) {
        AnimeMappingStore.checkForeground();
        await tasks.beforeNextRequest(lease);
        run.checkCancelled();
        final rows = await tasks.db.query(
          'scan_directory_checkpoints',
          where: 'source_id=? AND generation=? AND complete=0',
          whereArgs: [sourceId, lease.generation],
          orderBy: 'path',
          limit: listingWindow,
        );
        if (rows.isEmpty) break;
        activity.beginFolder(sourceId, rows.first['path'] as String);
        final listings = await Future.wait(rows.map((row) async {
          final dir = row['path'] as String;
          return dav == null
              ? await LocalMedia.list(base, dir)
              : <ScanEntry>[
                  for (final entry in await dav.list(
                    dav.directoryUri(dir),
                    requireComplete: true,
                  ))
                    (
                      name: entry.name,
                      directory: entry.isDirectory,
                      size: entry.size,
                    ),
                ];
        }));
        run.checkCancelled();
        final videoCounts = <int>[];
        await tasks.db.transaction((tx) async {
          await tasks.checkIn(tx, lease);
          final batch = tx.batch();
          for (var index = 0; index < rows.length; index++) {
            final row = rows[index];
            final dir = row['path'] as String;
            final root = row['root'] as String;
            final entries = listings[index];
            final hasDirect = row['root_has_video'] == null
                ? entries.any((e) => !e.directory && Catalog.isVideo(e.name))
                : row['root_has_video'] == 1;
            var videos = 0;
            for (final entry in entries) {
              run.checkCancelled();
              if (entry.name.isEmpty || entry.name.contains('/')) {
                throw const FormatException('Invalid directory entry');
              }
              final path = dir.isEmpty ? entry.name : '$dir/${entry.name}';
              LocalMedia.validateRelative(path);
              if (SelectedScanner.excluded(path, root)) continue;
              if (entry.directory) {
                batch.insert('scan_directory_checkpoints', {
                  'source_id': sourceId,
                  'generation': lease.generation,
                  'path': path,
                  'root': root,
                  'root_has_video': hasDirect ? 1 : 0,
                });
              } else if (Catalog.isVideo(entry.name)) {
                final classification = AutoClassifier.decide(
                  selectedRoot: root,
                  relativePath: path,
                  rootHasDirectVideo: hasDirect,
                  localRootName: localName,
                  strictMarkers: true,
                );
                batch.insert('scan_discoveries', {
                  'source_id': sourceId,
                  'path': path,
                  'size': entry.size,
                  'folder':
                      classification?.folder ??
                      '${root.isEmpty ? "" : "$root/"}@unclassified',
                });
                videos++;
              }
            }
            batch.update(
              'scan_directory_checkpoints',
              {'complete': 1},
              where: 'source_id=? AND path=?',
              whereArgs: [sourceId, dir],
            );
            videoCounts.add(videos);
          }
          await batch.commit(noResult: true);
          run.checkCancelled();
          lease.check();
        });
        for (var index = 0; index < rows.length; index++) {
          final dir = rows[index]['path'] as String;
          for (var i = 0; i < videoCounts[index]; i++) {
            activity.video(sourceId, dir);
          }
          activity.endFolder(sourceId, dir);
        }
      }
      AnimeMappingStore.checkForeground();
      enumeration.stop();
      dav?.close();
      final publication = Stopwatch()..start();
      if (catalog.automaticRecognition) {
        await _separateReleaseFolders(lease, run.checkCancelled);
      }
      var earlyAdded = 0;
      var earlyMs = 0;
      var earlyWorks = <String>[];
      if (startPriority != null) {
        final early = await _publishPriority(lease, run.checkCancelled);
        earlyAdded = early.added;
        earlyWorks = early.works;
        publication.stop();
        earlyMs = publication.elapsedMilliseconds;
        await tasks.beforeNextRequest(lease);
        run.checkCancelled();
        await startPriority(early.works);
        await tasks.beforeNextRequest(lease);
        run.checkCancelled();
        AnimeMappingStore.checkForeground();
        publication.start();
      }
      await tasks.commit(
        lease,
        (tx) async {
          final result = await _publish(tx, lease, roots, run.checkCancelled);
          return {
            ...result,
            'added': (result['added'] as int) + earlyAdded,
            'priority_added': earlyAdded,
            'priority_works': earlyWorks,
            'enumeration_ms': enumeration.elapsedMilliseconds,
            'publication_ms': publication.elapsedMilliseconds,
          };
        },
      );
      publication.stop();
      DebugLog.event('ScrapeScan', 'scan_phases', {
        'source': sourceId,
        'scan': timingId,
        'enumerationMs': enumeration.elapsedMilliseconds,
        'publicationMs': publication.elapsedMilliseconds,
        'priorityPublicationMs': earlyMs,
        'priorityVideos': earlyAdded,
        'videos': run.videoCount,
      }, level: 'INFO');
      await catalog.reload();
      activity.complete(sourceId);
      catalog.updateStatus('目录扫描完成');
    } on ScanCancelled {
      activity.cancelled(sourceId);
      rethrow;
    } on TaskPaused {
      rethrow;
    } catch (_) {
      activity.fail(sourceId, '目录扫描中断');
      rethrow;
    } finally {
      dav?.close();
      if (catalog.scanning) catalog.updateStatus('目录扫描已停止');
    }
  }

  Future<void> _separateReleaseFolders(TaskLease lease, void Function() check) async {
    await tasks.db.transaction((tx) async {
      await tasks.checkIn(tx, lease);
      final source = lease.sourceId!;
      final files = await tx.rawQuery('''
        SELECT d.folder, d.path, d.size, a.id AS existing_asset, l.relative_path AS existing_folder
        FROM scan_discoveries d
        LEFT JOIN assets a ON a.source_id=d.source_id AND a.relative_path=d.path
        LEFT JOIN library_locations l ON l.kind='work' AND l.entity_id=a.work_id
        WHERE d.source_id=? ORDER BY d.path
      ''', [source]);
      final grouped = <String, List<Map<String, Object?>>>{};
      for (final file in files) {
        (grouped[file['folder'] as String] ??= []).add(file);
      }
      final batch = tx.batch();
      for (final group in grouped.entries) {
        check();
        final assignments = AutoClassifier.releaseFolders(group.key,
            group.value.map((row) => row['path'] as String).toList(),
            sizes: {for (final row in group.value) row['path'] as String: row['size'] as int?});
        if (assignments.isEmpty ||
            assignments.values.any((folder) => folder != group.key && grouped.containsKey(folder)) ||
            group.value.any((row) => row['existing_asset'] != null &&
                assignments.containsKey(row['path']) &&
                assignments[row['path']] != row['existing_folder'])) {
          continue;
        }
        for (final assignment in assignments.entries) {
          if (assignment.value == group.key) continue;
          batch.update('scan_discoveries', {'folder': assignment.value},
              where: 'source_id=? AND path=?', whereArgs: [source, assignment.key]);
        }
      }
      await batch.commit(noResult: true);
      check();
      lease.check();
    });
  }

  Future<({List<String> works, int added})> _publishPriority(
    TaskLease lease,
    void Function() check,
  ) => tasks.db.transaction((tx) async {
    await tasks.checkIn(tx, lease);
    check();
    final source = lease.sourceId!;
    final step = (await tx.query('scrape_steps', columns: ['result_json'],
      where: 'task_id=? AND step=?', whereArgs: [lease.taskId, lease.step],
    )).single;
    if (step['result_json'] case final String saved) {
      final checkpoint = jsonDecode(saved) as Map<String, dynamic>;
      if (checkpoint['priority_works'] case final List works) {
        return (works: works.cast<String>(), added: checkpoint['priority_added'] as int);
      }
    }
    // An absent old path could be a move. Resolve moves in the full transaction
    // before publishing any replacement identity.
    final missing = await tx.rawQuery('''SELECT 1 FROM assets a
      WHERE a.source_id=? AND NOT EXISTS (SELECT 1 FROM scan_discoveries d
        WHERE d.source_id=a.source_id AND d.path=a.relative_path) LIMIT 1''', [source]);
    if (missing.isNotEmpty) return (works: <String>[], added: 0);
    final groups = (await tx.rawQuery('''SELECT d.folder, COUNT(*) AS videos
      FROM scan_discoveries d WHERE d.source_id=? AND NOT EXISTS (
        SELECT 1 FROM library_locations l WHERE l.kind='work'
        AND l.source_id=d.source_id AND l.relative_path=d.folder)
      AND NOT EXISTS (SELECT 1 FROM scan_move_reviews r
        WHERE r.source_id=d.source_id AND r.folder=d.folder)
      GROUP BY d.folder HAVING COUNT(*)<=48 ORDER BY d.folder''', [source])).toList();
    int priority(Map<String, Object?> group) {
      final folder = (group['folder'] as String).split('/').last;
      if (Catalog.tmdbId(folder) != null ||
          RegExp(r'\{bangumi-\d+\}', caseSensitive: false).hasMatch(folder)) return 2;
      return Catalog.year(folder) != null ? 1 : 0;
    }
    groups.sort((a, b) {
      final rank = priority(b).compareTo(priority(a));
      return rank == 0 ? (a['folder'] as String).compareTo(b['folder'] as String) : rank;
    });
    final works = <String>[];
    var added = 0;
    for (final group in groups) {
      if (works.length == 6) break;
      final folder = group['folder'] as String;
      final name = folder.split('/').last;
      if (name == '@unclassified' || added + (group['videos'] as int) > 96 ||
          PersonalFilenameParser.extractAnimeSearchKeyword('${Catalog.cleanTitle(name)}.mkv').isEmpty) continue;
      final files = await tx.query('scan_discoveries', where: 'source_id=? AND folder=?',
        whereArgs: [source, folder], orderBy: 'path');
      if (!files.any((file) => !Catalog.isExtra(file['path'] as String))) continue;
      // An existing path can belong to a manually assigned work.
      final existing = await tx.rawQuery('''SELECT 1 FROM scan_discoveries d
        JOIN assets a ON a.source_id=d.source_id AND a.relative_path=d.path
        WHERE d.source_id=? AND d.folder=? LIMIT 1''', [source, folder]);
      if (existing.isNotEmpty) continue;
      for (final file in files) {
        check();
        lease.check();
        await catalog.indexVideo(source, file['path'] as String, file['size'] as int?,
          workFolder: folder, executor: tx);
      }
      final work = await LibraryFoundation.locate(tx, 'work', source, folder);
      if (work != null) {
        works.add(work);
        added += files.length;
      }
    }
    await tx.update('scrape_steps', {'result_json': jsonEncode({
      'priority_works': works, 'priority_added': added,
    })}, where: 'task_id=? AND step=?', whereArgs: [lease.taskId, lease.step]);
    check();
    lease.check();
    return (works: works, added: added);
  });

  static String? _signature(Iterable<({String path, int? size})> files) {
    if (files.isEmpty || files.any((f) => f.size == null || f.size! <= 0)) {
      return null;
    }
    return jsonEncode(
      files.map((f) => jsonEncode([f.path, f.size])).toList()..sort(),
    );
  }

  Future<Map<String, Object?>> _publish(
    DatabaseExecutor tx,
    TaskLease lease,
    List<String> roots,
    void Function() check,
  ) async {
    final source = lease.sourceId!;
    await tx.insert('library_source_revisions', {
      'source_id': source,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
    bool covered(String path) => roots.any(
      (root) => _inside(path, root) && !SelectedScanner.excluded(path, root),
    );
    final found = {
      for (final row in await tx.query(
        'scan_discoveries',
        where: 'source_id=?',
        whereArgs: [source],
        orderBy: 'path',
      ))
        row['path'] as String: row,
    };
    final existing = {
      for (final row in await tx.rawQuery(
        '''SELECT a.*, m.asset_id IS NOT NULL AS missing,
        c.state AS content_state, c.observed_size FROM assets a
        LEFT JOIN scan_missing_assets m ON m.asset_id=a.id
        LEFT JOIN library_content c ON c.asset_id=a.id WHERE a.source_id=?
        ORDER BY a.relative_path''',
        [source],
      ))
        row['relative_path'] as String: row,
    };
    final oldByWork = <String, List<Map<String, Object?>>>{};
    for (final row in existing.values) {
      (oldByWork[row['work_id'] as String] ??= []).add(row);
    }
    final oldBySignature =
        <
          String,
          List<
            ({String work, String folder, List<Map<String, Object?>> members})
          >
        >{};
    for (final location in await tx.query(
      'library_locations',
      where: "kind='work' AND source_id=?",
      whereArgs: [source],
      orderBy: 'relative_path',
    )) {
      final folder = location['relative_path'] as String;
      final work = location['entity_id'] as String;
      final members = oldByWork[work];
      if (members == null ||
          members.any((a) {
            final path = a['relative_path'] as String;
            return !_inside(path, folder) ||
                !covered(path) ||
                found.containsKey(path) ||
                a['content_state'] != 'current';
          })) {
        continue;
      }
      final signature = _signature(
        members.map(
          (a) => (
            path: (a['relative_path'] as String).substring(folder.length + 1),
            size: a['size'] as int?,
          ),
        ),
      );
      if (signature != null) {
        (oldBySignature[signature] ??= []).add((
          work: work,
          folder: folder,
          members: members,
        ));
      }
    }
    final newByFolder = <String, List<Map<String, Object?>>>{};
    for (final entry in found.entries) {
      (newByFolder[entry.value['folder'] as String] ??= []).add(entry.value);
    }
    final matches = <String, List<String>>{};
    for (final entry in newByFolder.entries) {
      final folder = entry.key;
      if (entry.value.any((a) {
        final path = a['path'] as String;
        return !_inside(path, folder) || existing.containsKey(path);
      })) {
        continue;
      }
      final signature = _signature(
        entry.value.map(
          (a) => (
            path: (a['path'] as String).substring(folder.length + 1),
            size: a['size'] as int?,
          ),
        ),
      );
      if (signature != null && oldBySignature.containsKey(signature)) {
        (matches[signature] ??= []).add(folder);
      }
    }
    final saved = {
      for (final row in await tx.query(
        'scan_move_reviews',
        where: 'source_id=?',
        whereArgs: [source],
      ))
        row['folder'] as String: row,
    };
    final held = <String>{};
    for (final match in matches.entries) {
      final candidates = oldBySignature[match.key]!;
      for (final folder in match.value) {
        final evidence = jsonEncode({
          'files': [
            for (final row in newByFolder[folder]!) [row['path'], row['size']],
          ],
          'choices': [
            for (final old in candidates)
              {
                'work': old.work,
                'folder': old.folder,
                'paths': {
                  for (final a in old.members)
                    a['id'] as String: [
                      a['relative_path'],
                      a['size'],
                      '$folder/${(a['relative_path'] as String).substring(old.folder.length + 1)}',
                    ],
                },
              },
          ],
        });
        final old = saved.remove(folder);
        final review = {
          'source_id': source,
          'folder': folder,
          'revision': lease.locationRevision,
          'evidence': evidence,
          'skipped': old?['evidence'] == evidence ? old!['skipped'] : 0,
        };
        if (old == null) {
          await tx.insert('scan_move_reviews', review);
        } else if (old['evidence'] != evidence ||
            old['revision'] != lease.locationRevision) {
          await tx.update(
            'scan_move_reviews',
            review,
            where: 'source_id=? AND folder=?',
            whereArgs: [source, folder],
          );
        }
        held.add(folder);
      }
    }
    for (final folder in saved.keys) {
      if (found.values.any((a) => a['folder'] == folder) ||
          roots.any((root) => folder == root || _inside(folder, root))) {
        await tx.delete(
          'scan_move_reviews',
          where: 'source_id=? AND folder=?',
          whereArgs: [source, folder],
        );
      }
    }
    var added = 0, changed = 0, missing = 0;
    for (final entry in found.entries) {
      check();
      lease.check();
      final row = entry.value;
      if (held.contains(row['folder'])) continue;
      final old = existing[entry.key];
      if (old?['missing'] == 1) {
        await tx.delete(
          'scan_missing_assets',
          where: 'asset_id=?',
          whereArgs: [old!['id']],
        );
      }
      if (old != null &&
          (row['size'] == null ||
              row['size'] ==
                  (old['content_state'] == 'suspected'
                      ? old['observed_size']
                      : old['size']))) {
        continue;
      }
      await catalog.indexVideo(
        source,
        entry.key,
        row['size'] as int?,
        workFolder: row['folder'] as String,
        executor: tx,
      );
      if (old == null) {
        added++;
      } else {
        changed++;
      }
    }
    for (final entry in existing.entries) {
      check();
      if (!covered(entry.key) || found.containsKey(entry.key)) continue;
      missing++;
      if (entry.value['missing'] == 0) {
        await tx.insert('scan_missing_assets', {'asset_id': entry.value['id']});
        if (catalog.recognitionEnabled) {
          await tx.insert('scan_dirty_works', {'work_id': entry.value['work_id']},
              conflictAlgorithm: ConflictAlgorithm.ignore);
        }
      }
    }
    await clearCheckpoints(tx, source: source);
    check();
    return {
      'videos': found.length,
      'added': added,
      'changed': changed,
      'missing': missing,
      'move_reviews': held.length,
    };
  }

  Future<void> resolveMove(
    Map<String, Object?> review,
    String? work, {
    bool skip = false,
  }) async {
    final source = review['source_id'] as String;
    final folder = review['folder'] as String;
    final revision = review['revision'] as int;
    await tasks.db.transaction((tx) async {
      final session = (await tx.query(
        'scrape_runtime',
        columns: ['session'],
      )).single['session'];
      if (review['session'] != session) {
        throw StateError('Move preview session changed');
      }
      await LibraryFoundation.checkSource(tx, source, revision);
      final rows = await tx.query(
        'scan_move_reviews',
        where: 'source_id=? AND folder=?',
        whereArgs: [source, folder],
      );
      if (rows.isEmpty ||
          rows.single['evidence'] != review['evidence'] ||
          rows.single['revision'] != revision) {
        throw StateError('Move preview changed');
      }
      if (skip) {
        await tx.update(
          'scan_move_reviews',
          {'skipped': 1},
          where: 'source_id=? AND folder=?',
          whereArgs: [source, folder],
        );
        return;
      }
      final evidence = jsonDecode(review['evidence'] as String) as Map;
      final files = evidence['files'] as List;
      for (final file in files) {
        final target = await tx.query(
          'assets',
          where: 'source_id=? AND relative_path=?',
          whereArgs: [source, file[0]],
        );
        if (target.isNotEmpty) throw StateError('Target is already indexed');
      }
      if (work == null) {
        for (final file in files) {
          await catalog.indexVideo(
            source,
            file[0] as String,
            file[1] as int,
            workFolder: folder,
            executor: tx,
          );
        }
      } else {
        final choice =
            (evidence['choices'] as List).singleWhere((c) => c['work'] == work)
                as Map;
        final paths = <String, String>{};
        for (final e in (choice['paths'] as Map).entries) {
          final row = await tx.rawQuery(
            '''SELECT a.relative_path,a.size FROM assets a
            JOIN scan_missing_assets m ON m.asset_id=a.id JOIN library_content c ON c.asset_id=a.id
            WHERE a.id=? AND a.work_id=? AND a.source_id=? AND c.state='current' ''',
            [e.key, work, source],
          );
          if (row.isEmpty ||
              row.single['relative_path'] != e.value[0] ||
              row.single['size'] != e.value[1]) {
            throw StateError('Original files changed');
          }
          paths[e.key as String] = e.value[2] as String;
        }
        await LibraryFoundation(catalog.db).relocate(
          source,
          paths,
          expectedRevision: revision,
          workId: work,
          workPath: folder,
          executor: tx,
        );
        for (final asset in paths.keys) {
          await tx.delete(
            'scan_missing_assets',
            where: 'asset_id=?',
            whereArgs: [asset],
          );
        }
      }
      await tx.delete(
        'scan_move_reviews',
        where: 'source_id=? AND folder=?',
        whereArgs: [source, folder],
      );
    });
    await catalog.reload();
  }

  static void validateSnapshot(Map<String, dynamic> tables) {
    final sources = {for (final row in tables['sources'] as List) row['id']};
    final assets = {for (final row in tables['assets'] as List) row['id']: row};
    final seen = <(Object?, String)>{};
    for (final row in tables['scan_move_reviews'] as List) {
      final source = row['source_id'];
      final folder = row['folder'] as String;
      final data = jsonDecode(row['evidence'] as String) as Map;
      final files = data['files'] as List;
      final choices = data['choices'] as List;
      if (!sources.contains(source) ||
          LibraryFoundation.path(folder) != folder ||
          !seen.add((source, folder)) ||
          ![0, 1].contains(row['skipped']) ||
          row['revision'] is! int ||
          row['revision'] < 0 ||
          files.isEmpty ||
          choices.isEmpty) {
        throw const FormatException('Invalid move review');
      }
      for (final file in files) {
        if (file.length != 2 ||
            !_inside(file[0] as String, folder) ||
            LibraryFoundation.path(file[0]) != file[0] ||
            file[1] is! int ||
            file[1] <= 0) {
          throw const FormatException('Invalid move preview file');
        }
      }
      for (final choice in choices) {
        for (final entry in (choice['paths'] as Map).entries) {
          final asset = assets[entry.key];
          if (asset == null ||
              asset['source_id'] != source ||
              asset['work_id'] != choice['work'] ||
              entry.value.length != 3 ||
              !files.any(
                (f) => f[0] == entry.value[2] && f[1] == entry.value[1],
              )) {
            throw const FormatException('Invalid move preview relation');
          }
        }
      }
    }
  }
}
