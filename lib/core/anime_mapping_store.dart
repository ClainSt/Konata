import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'anime_mapping.dart';
import 'library_foundation.dart';
import 'scrape_tasks.dart';
import 'player_fullscreen.dart';
import 'package:flutter/widgets.dart';

class MappingAnswer {
  const MappingAnswer(this.state, this.version, [this.targets = const []]);
  final String state;
  final String? version;
  final List<Map<String, dynamic>> targets;
}

/// Durable version floors are library data. Source indexes are disposable and
/// never overwrite adopted episode relations, fields or watch evidence.
class AnimeMappingStore {
  AnimeMappingStore(this.tasks);
  final ScrapeTasks tasks;
  Database get db => tasks.db;
  static const portableTables = [
    'mapping_versions',
    'mapping_ancestry',
    'mapping_controls',
    'mapping_review',
  ];
  static final commitPattern = RegExp(r'^[a-f0-9]{40}$');
  static final digestPattern = RegExp(r'^[a-f0-9]{64}$');
  static const maxSubjects = 100000, maxEpisodes = 1000000;
  static bool get foregroundAvailable {
    final state = WidgetsBinding.instance.lifecycleState;
    return playingHeader.value == null &&
        (state == null ||
            state == AppLifecycleState.resumed ||
            (Platform.isWindows && state == AppLifecycleState.inactive));
  }

  static void checkForeground() {
    if (!foregroundAvailable) throw const TaskPaused();
  }

  Future<void> check(TaskLease lease) async {
    checkForeground();
    await tasks.beforeNextRequest(lease);
  }

  static Future<void> createSchema(DatabaseExecutor tx) async {
    await tx.execute('CREATE TABLE mapping_versions(version TEXT PRIMARY KEY)');
    await tx.execute(
      'CREATE TABLE mapping_ancestry(parent TEXT NOT NULL,child TEXT NOT NULL,PRIMARY KEY(parent,child))',
    );
    await tx.execute(
      '''CREATE TABLE mapping_controls(subject INTEGER PRIMARY KEY,version TEXT NOT NULL,
      digest TEXT NOT NULL,excluded TEXT NOT NULL,conflict INTEGER NOT NULL DEFAULT 0,batch TEXT NOT NULL,evidence TEXT NOT NULL DEFAULT 'bulk',
      checked_at INTEGER NOT NULL DEFAULT 0,used_at INTEGER NOT NULL DEFAULT 0)''',
    );
    await tx.execute(
      'CREATE TABLE mapping_review(id INTEGER PRIMARY KEY,day INTEGER NOT NULL,count INTEGER NOT NULL)',
    );
    await tx.insert('mapping_review', {'id': 1, 'day': 0, 'count': 0});
    await tx.execute(
      '''CREATE TABLE mapping_batches(id TEXT PRIMARY KEY,version TEXT NOT NULL,kind TEXT NOT NULL,state TEXT NOT NULL)''',
    );
    await tx.execute(
      '''CREATE TABLE mapping_subjects(batch TEXT NOT NULL,subject INTEGER NOT NULL,targets TEXT NOT NULL,digest TEXT,
      excluded TEXT NOT NULL DEFAULT '[]',proof TEXT NOT NULL DEFAULT '{}',PRIMARY KEY(batch,subject))''',
    );
    await tx.execute(
      '''CREATE TABLE mapping_rows(batch TEXT NOT NULL,subject INTEGER NOT NULL,episode INTEGER NOT NULL,targets TEXT NOT NULL,
      PRIMARY KEY(batch,subject,episode))''',
    );
    await tx.execute(
      '''CREATE TABLE mapping_reverse(batch TEXT NOT NULL,type TEXT NOT NULL,tmdb INTEGER NOT NULL,subject INTEGER NOT NULL,
      PRIMARY KEY(batch,type,tmdb,subject))''',
    );
    await tx.execute(
      'CREATE TABLE mapping_index(id INTEGER PRIMARY KEY,index_batch TEXT,index_version TEXT)',
    );
    await tx.insert('mapping_index', {'id': 1});
    await tx.execute(
      '''CREATE TRIGGER mapping_batch_removed AFTER DELETE ON mapping_batches BEGIN
      DELETE FROM mapping_subjects WHERE batch=OLD.id;
      DELETE FROM mapping_rows WHERE batch=OLD.id;
      DELETE FROM mapping_reverse WHERE batch=OLD.id;
      END''',
    );
  }

  static Future<void> clearIn(DatabaseExecutor tx) async {
    await tx.delete('mapping_batches');
    await tx.update('mapping_index', {
      'index_batch': null,
      'index_version': null,
    });
  }

  /// Restore may replace adopted library relations, but it must not silently
  /// lower an already accepted source-version floor for future automatic work.
  static Future<Map<String, List<Map<String, Object?>>>> restoreGuard(
    DatabaseExecutor tx,
  ) async => {for (final table in portableTables) table: await tx.query(table)};

  static Future<void> preserveRestoreGuard(
    DatabaseExecutor tx,
    Map<String, List<Map<String, Object?>>> old,
  ) async {
    for (final table in ['mapping_versions', 'mapping_ancestry']) {
      for (final row in old[table]!) {
        await tx.insert(
          table,
          row,
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      }
    }
    final incomingReview = (await tx.query('mapping_review')).single;
    final previousReview = old['mapping_review']!.single;
    if ((previousReview['day'] as int) > (incomingReview['day'] as int) ||
        (previousReview['day'] == incomingReview['day'] &&
            (previousReview['count'] as int) >
                (incomingReview['count'] as int))) {
      await tx.update('mapping_review', previousReview, where: 'id=1');
    }
    for (final previous in old['mapping_controls']!) {
      final rows = await tx.query(
        'mapping_controls',
        where: 'subject=?',
        whereArgs: [previous['subject']],
      );
      if (rows.isEmpty) {
        await tx.insert('mapping_controls', previous);
        continue;
      }
      final incoming = rows.single;
      final before = previous['version'] as String,
          after = incoming['version'] as String;
      Map<String, Object?>? keep;
      if (before == after) {
        final different =
            previous['digest'] != incoming['digest'] ||
            (previous['evidence'] == 'detail' &&
                incoming['evidence'] == 'detail' &&
                previous['excluded'] != incoming['excluded']);
        keep = Map<String, Object?>.from(
          previous['evidence'] == 'detail' ? previous : incoming,
        );
        if (different ||
            previous['conflict'] == 1 ||
            incoming['conflict'] == 1) {
          keep['conflict'] = 1;
        }
      } else if (await _newer(tx, before, after)) {
        keep = previous;
      } else if (!await _newer(tx, after, before)) {
        keep = {...previous, 'conflict': 1};
      }
      if (keep != null) {
        await tx.update(
          'mapping_controls',
          keep,
          where: 'subject=?',
          whereArgs: [previous['subject']],
        );
      }
    }
    validateSnapshot(await restoreGuard(tx));
  }

  Future<void> clearCache() async {
    await db.transaction((tx) async {
      await tx.rawUpdate(
        'UPDATE scrape_runtime SET cache_revision=cache_revision+1',
      );
      await clearIn(tx);
    });
  }

  Future<void> recover() async {
    await db.delete('mapping_batches', where: "state='staging'");
    final downloads = Directory(
      '${tasks.cacheDirectory.parent.path}/mapping-downloads',
    );
    if (await downloads.exists()) {
      await for (final entry in downloads.list(followLinks: false)) {
        if (entry is Directory &&
            RegExp(r'^request-[a-zA-Z0-9]+$').hasMatch(
              entry.uri.pathSegments.where((s) => s.isNotEmpty).last,
            )) {
          await entry.delete(recursive: true);
        }
      }
    }
  }

  Future<void> registerVersion(String version) async {
    if (!commitPattern.hasMatch(version)) {
      throw const FormatException('Invalid mapping version');
    }
    await db.transaction((tx) async {
      if ((await tx.query('mapping_versions')).length >= 256 &&
          (await tx.query(
            'mapping_versions',
            where: 'version=?',
            whereArgs: [version],
          )).isEmpty) {
        throw StateError('Version history capacity');
      }
      await tx.insert('mapping_versions', {
        'version': version,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    });
  }

  /// Accept only an explicit GitHub compare proof, never timestamps or arrival order.
  Future<void> proveDescendant(
    String parent,
    String child,
    Map<String, dynamic> compare,
  ) async {
    if (!commitPattern.hasMatch(parent) ||
        !commitPattern.hasMatch(child) ||
        parent == child ||
        compare['status'] != 'ahead' ||
        compare['base_commit']?['sha'] != parent ||
        compare['merge_base_commit']?['sha'] != parent ||
        compare['commits'] is! List ||
        (compare['commits'] as List).isEmpty ||
        (compare['commits'] as List).last['sha'] != child) {
      throw const FormatException('Unverified version ancestry');
    }
    await registerVersion(parent);
    await registerVersion(child);
    await db.transaction((tx) async {
      if (await _newer(tx, parent, child)) {
        throw const FormatException('Cyclic version ancestry');
      }
      await tx.insert('mapping_ancestry', {
        'parent': parent,
        'child': child,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    });
  }

  static Future<bool> _newer(
    DatabaseExecutor tx,
    String candidate,
    String previous,
  ) async => (await tx.rawQuery(
    '''
    WITH RECURSIVE newer(v) AS (SELECT child FROM mapping_ancestry WHERE parent=?
      UNION SELECT child FROM mapping_ancestry JOIN newer ON parent=newer.v)
    SELECT v FROM newer WHERE v=? LIMIT 1''',
    [previous, candidate],
  )).isNotEmpty;

  Future<String> _begin(String version, String kind, TaskLease lease) async {
    await check(lease);
    final id = LibraryFoundation.newId('mapping:');
    await db.transaction((tx) async {
      await tasks.checkIn(tx, lease, cache: true);
      if ((await tx.query(
        'mapping_versions',
        where: 'version=?',
        whereArgs: [version],
      )).isEmpty) {
        throw StateError('Unregistered version');
      }
      if ((await tx.query('mapping_batches', columns: ['id'])).length >= 2048) {
        throw StateError('Mapping cache capacity');
      }
      await tx.insert('mapping_batches', {
        'id': id,
        'version': version,
        'kind': kind,
        'state': 'staging',
      });
    });
    return id;
  }

  Future<void> _verify(File file, String digest, int limit) async {
    if (!digestPattern.hasMatch(digest) ||
        await file.length() > limit ||
        (await sha256.bind(file.openRead()).first).toString() != digest) {
      throw const FormatException('Mapping asset checksum or size');
    }
  }

  Future<void> _writeSubjects(
    String batch,
    List<Map<String, dynamic>> rows,
    TaskLease lease,
  ) async {
    await db.transaction((tx) async {
      await tasks.checkIn(tx, lease, cache: true);
      final writes = tx.batch();
      for (final row in rows) {
        final id = AnimeMapping.integer(row['bangumiId']);
        final targets = AnimeMapping.targetList(row['targets']);
        writes.insert('mapping_subjects', {
          'batch': batch,
          'subject': id,
          'targets': jsonEncode(targets),
        });
        final seen = <String>{};
        for (final t in targets) {
          if (seen.add('${t['type']}:${t['id']}')) {
            writes.insert('mapping_reverse', {
              'batch': batch,
              'type': t['type'],
              'tmdb': t['id'],
              'subject': id,
            });
          }
        }
      }
      await writes.commit(noResult: true);
      lease.check();
    });
  }

  /// Download files are already private temporaries. SHA validation precedes
  /// streaming row import; staging is invisible until guarded final activation.
  Future<void> importPublished({
    required String version,
    required File subjects,
    required String subjectsDigest,
    File? episodes,
    String? episodesDigest,
    required int subjectCount,
    int? episodeCount,
    required TaskLease lease,
  }) async {
    if (subjectCount < 0 ||
        subjectCount > maxSubjects ||
        (episodeCount ?? 0) > maxEpisodes ||
        (episodes != null &&
            (episodeCount == null || episodesDigest == null))) {
      throw const FormatException('Manifest counts');
    }
    await _verify(subjects, subjectsDigest, 8 * 1024 * 1024);
    if (episodes != null) {
      await _verify(episodes, episodesDigest!, 96 * 1024 * 1024);
    }
    final batch = await _begin(
      version,
      episodes == null ? 'index' : 'bulk',
      lease,
    );
    try {
      var count = 0;
      var buffer = <Map<String, dynamic>>[];
      await for (final row in mappingRows(subjects, 'subjects')) {
        if (++count > subjectCount) {
          throw const FormatException('Subject count mismatch');
        }
        buffer.add(row);
        if (buffer.length == 256) {
          await check(lease);
          await _writeSubjects(batch, buffer, lease);
          buffer = [];
        }
      }
      if (count != subjectCount) {
        throw const FormatException('Subject count mismatch');
      }
      await _writeSubjects(batch, buffer, lease);
      if (episodes != null) {
        count = 0;
        buffer = [];
        Future<void> flush() async {
          await check(lease);
          await db.transaction((tx) async {
            await tasks.checkIn(tx, lease, cache: true);
            final writes = tx.batch();
            for (final row in buffer) {
              final subject = AnimeMapping.integer(row['bangumiId']);
              final ep = AnimeMapping.integer(row['bangumiEpisodeId']);
              final targets = AnimeMapping.targetList(
                row['targets'],
                episode: true,
              );
              if (targets.isEmpty) {
                throw const FormatException('Published rows must map');
              }
              writes.insert('mapping_rows', {
                'batch': batch,
                'subject': subject,
                'episode': ep,
                'targets': jsonEncode(targets),
              });
            }
            await writes.commit(noResult: true);
            lease.check();
          });
          buffer = [];
        }

        await for (final row in mappingRows(episodes, 'episodes')) {
          if (++count > episodeCount!) {
            throw const FormatException('Episode count mismatch');
          }
          buffer.add(row);
          if (buffer.length == 256) await flush();
        }
        await flush();
        if (count != episodeCount) {
          throw const FormatException('Episode count mismatch');
        }
        if ((await db.rawQuery(
          '''SELECT 1 FROM mapping_rows r LEFT JOIN mapping_subjects s ON s.batch=r.batch AND s.subject=r.subject
          WHERE r.batch=? AND s.subject IS NULL LIMIT 1''',
          [batch],
        )).isNotEmpty) {
          throw const FormatException('Unknown episode subject');
        }
        // Each entry is bounded; no full release object graph is retained.
        var after = 0;
        while (true) {
          final rows = await db.query(
            'mapping_subjects',
            where: 'batch=? AND subject>?',
            whereArgs: [batch, after],
            orderBy: 'subject',
            limit: 128,
          );
          if (rows.isEmpty) break;
          await check(lease);
          final digests = <int, String>{};
          for (final row in rows) {
            final entries = await db.query(
              'mapping_rows',
              where: 'batch=? AND subject=?',
              whereArgs: [batch, row['subject']],
              limit: 10001,
            );
            if (entries.length > 10000) {
              throw const FormatException('Episode entry limit');
            }
            final map = {
              for (final e in entries)
                e['episode'] as int: AnimeMapping.targetList(
                  jsonDecode(e['targets'] as String),
                  episode: true,
                ),
            };
            AnimeMapping.validateEpisodeTargets(map);
            final item = AnimeMapping(
              row['subject'] as int,
              AnimeMapping.targetList(jsonDecode(row['targets'] as String)),
              map,
              {},
            );
            digests[row['subject'] as int] = item.digest;
          }
          await db.transaction((tx) async {
            await tasks.checkIn(tx, lease, cache: true);
            final writes = tx.batch();
            for (final entry in digests.entries) {
              writes.update(
                'mapping_subjects',
                {'digest': entry.value},
                where: 'batch=? AND subject=?',
                whereArgs: [batch, entry.key],
              );
            }
            await writes.commit(noResult: true);
            lease.check();
          });
          after = rows.last['subject'] as int;
        }
      }
      await _activate(batch, version, lease, indexOnly: episodes == null);
    } catch (_) {
      await db.delete('mapping_batches', where: 'id=?', whereArgs: [batch]);
      rethrow;
    }
  }

  Future<void> importDetail(
    String version,
    Map<String, dynamic> data,
    TaskLease lease,
  ) async {
    final item = AnimeMapping.detail(data);
    final proof = data['provenance'] ?? <String, Object?>{};
    if (proof is! Map ||
        jsonEncode(proof).length > 65536 ||
        proof.values.any((v) => v is! String)) {
      throw const FormatException('Invalid mapping evidence');
    }
    final batch = await _begin(version, 'detail', lease);
    try {
      await _writeSubjects(batch, [
        {'bangumiId': item.subject, 'targets': item.targets},
      ], lease);
      await db.transaction((tx) async {
        await tasks.checkIn(tx, lease, cache: true);
        final writes = tx.batch();
        for (final entry in item.episodes.entries) {
          writes.insert('mapping_rows', {
            'batch': batch,
            'subject': item.subject,
            'episode': entry.key,
            'targets': jsonEncode(entry.value),
          });
        }
        writes.update(
          'mapping_subjects',
          {
            'digest': item.digest,
            'excluded': jsonEncode(item.excluded.toList()..sort()),
            'proof': jsonEncode(proof),
          },
          where: 'batch=?',
          whereArgs: [batch],
        );
        await writes.commit(noResult: true);
        lease.check();
      });
      await _activate(batch, version, lease);
    } catch (_) {
      await db.delete('mapping_batches', where: 'id=?', whereArgs: [batch]);
      rethrow;
    }
  }

  Future<void> _activate(
    String batch,
    String version,
    TaskLease lease, {
    bool indexOnly = false,
  }) async {
    await check(lease);
    await tasks.commit(lease, (tx) async {
      await tasks.checkIn(tx, lease, cache: true);
      // Global limits cover old + staging data, including concurrent requests.
      if ((await tx.rawQuery('SELECT COUNT(*) n FROM mapping_rows')).single['n']
                  as int >
              maxEpisodes ||
          (await tx.rawQuery(
                    'SELECT COUNT(*) n FROM mapping_subjects',
                  )).single['n']
                  as int >
              maxSubjects * 2) {
        throw StateError('Mapping cache budget');
      }
      final kind = (await tx.query(
        'mapping_batches',
        where: 'id=?',
        whereArgs: [batch],
      )).single['kind'];
      final bytes =
          (await tx.rawQuery(
                '''SELECT (SELECT COALESCE(SUM(length(CAST(targets AS BLOB))),0) FROM mapping_rows) +
        (SELECT COALESCE(SUM(length(CAST(targets AS BLOB))+length(CAST(excluded AS BLOB))+length(CAST(proof AS BLOB))),0) FROM mapping_subjects) AS n''',
              )).single['n']
              as int;
      if (bytes > 128 * 1024 * 1024) {
        throw StateError('Mapping index byte budget');
      }
      if (!indexOnly) {
        final versions = await tx.rawQuery(
          'SELECT DISTINCT version FROM mapping_controls',
        );
        final older = <String>[];
        for (final old in versions) {
          if (await _newer(tx, version, old['version'] as String)) {
            older.add(old['version'] as String);
          }
        }
        // Same-version disagreement is durable, including across cache clearing.
        await tx.rawUpdate(
          '''UPDATE mapping_controls SET conflict=1 WHERE version=? AND EXISTS
          (SELECT 1 FROM mapping_subjects s WHERE s.batch=? AND s.subject=mapping_controls.subject AND s.digest<>mapping_controls.digest)''',
          [version, batch],
        );
        if (kind == 'detail') {
          await tx.rawUpdate(
            '''UPDATE mapping_controls SET conflict=1 WHERE version=? AND evidence='detail' AND EXISTS
            (SELECT 1 FROM mapping_subjects s WHERE s.batch=? AND s.subject=mapping_controls.subject AND s.excluded<>mapping_controls.excluded)''',
            [version, batch],
          );
        }
        if (kind == 'bulk') {
          await tx.rawUpdate(
            '''UPDATE mapping_controls SET conflict=1 WHERE version=? AND (digest<>? OR excluded<>'[]')
            AND subject NOT IN (SELECT subject FROM mapping_subjects WHERE batch=?)''',
            [version, AnimeMapping(1, [], {}, {}).digest, batch],
          );
        }
        final predicate = older.isEmpty
            ? '0'
            : 'version IN (${List.filled(older.length, '?').join(',')})';
        await tx.rawInsert(
          '''INSERT INTO mapping_controls(subject,version,digest,excluded,conflict,batch)
          SELECT subject,?,digest,excluded,0,? FROM mapping_subjects s WHERE batch=? AND NOT EXISTS
          (SELECT 1 FROM mapping_controls c WHERE c.subject=s.subject)
          ''',
          [version, batch, batch],
        );
        await tx.rawUpdate(
          '''UPDATE mapping_controls SET version=?,digest=(SELECT digest FROM mapping_subjects s WHERE s.batch=? AND s.subject=mapping_controls.subject),
          excluded=(SELECT excluded FROM mapping_subjects s WHERE s.batch=? AND s.subject=mapping_controls.subject),conflict=0,batch=?,evidence='bulk'
          WHERE ($predicate) AND subject IN (SELECT subject FROM mapping_subjects WHERE batch=?)''',
          [version, batch, batch, batch, ...older, batch],
        );
        if (kind == 'bulk') {
          await tx.rawUpdate(
            '''UPDATE mapping_controls SET version=?,digest=?,excluded='[]',conflict=0,batch=?,evidence='bulk'
            WHERE ($predicate) AND subject NOT IN (SELECT subject FROM mapping_subjects WHERE batch=?)''',
            [
              version,
              AnimeMapping(1, [], {}, {}).digest,
              batch,
              ...older,
              batch,
            ],
          );
        }
        // Same-version detailed evidence enriches exclusions; bulk never erases it.
        if (kind == 'detail') {
          await tx.rawUpdate(
            '''UPDATE mapping_controls SET batch=?,evidence='detail',excluded=(SELECT excluded FROM mapping_subjects s WHERE s.batch=? AND s.subject=mapping_controls.subject)
            WHERE version=? AND conflict=0 AND subject IN (SELECT subject FROM mapping_subjects WHERE batch=?)''',
            [batch, batch, version, batch],
          );
        } else {
          // Rehydrate the same version after clearing caches, without weakening exclusions.
          await tx.rawUpdate(
            '''UPDATE mapping_controls SET batch=? WHERE version=? AND conflict=0 AND subject IN
            (SELECT subject FROM mapping_subjects WHERE batch=?) AND (evidence='bulk' OR NOT EXISTS (SELECT 1 FROM mapping_batches b WHERE b.id=mapping_controls.batch))''',
            [batch, version, batch],
          );
        }
      }
      if (kind != 'detail') {
        final index = (await tx.query('mapping_index')).single;
        final previous = index['index_version'] as String?;
        if (previous == null ||
            previous == version ||
            await _newer(tx, version, previous)) {
          await tx.update('mapping_index', {
            'index_batch': batch,
            'index_version': version,
          });
        }
      }
      await tx.update(
        'mapping_batches',
        {'state': 'ready'},
        where: 'id=?',
        whereArgs: [batch],
      );
      await tx.update(
        'mapping_controls',
        {'checked_at': tasks.now, 'used_at': tasks.now},
        where: 'batch=?',
        whereArgs: [batch],
      );
      if ((await tx.rawQuery(
                'SELECT COUNT(*) n FROM mapping_controls',
              )).single['n']
              as int >
          maxSubjects) {
        throw StateError('Mapping control capacity');
      }
      checkForeground();
      return {'version': version, 'kind': kind};
    });
    // Only unreferenced reconstructible indexes are collected; floors survive.
    try {
      await db.rawDelete(
        '''DELETE FROM mapping_batches WHERE state='ready' AND id NOT IN
      (SELECT batch FROM mapping_controls UNION SELECT index_batch FROM mapping_index WHERE index_batch IS NOT NULL)''',
      );
    } on DatabaseException {
      // Cleanup cannot undo a committed version. The next import retries it.
    }
  }

  Future<MappingAnswer> lookup(int subject, int episode) =>
      db.transaction((tx) => lookupIn(tx, subject, episode));

  Future<MappingAnswer> lookupIn(
    DatabaseExecutor tx,
    int subject,
    int episode,
  ) async {
    final rows = await tx.query(
      'mapping_controls',
      where: 'subject=?',
      whereArgs: [subject],
    );
    if (rows.isEmpty) {
      final bulk = await tx.rawQuery(
        "SELECT b.* FROM mapping_index i JOIN mapping_batches b ON b.id=i.index_batch WHERE b.kind='bulk' AND b.state='ready'",
      );
      if (bulk.isEmpty) return const MappingAnswer('not_acquired', null);
      // A complete published index also proves that this requested subject has
      // no coverage in this version, not that its episodes were excluded.
      final b = bulk.single;
      if ((await tx.rawQuery(
                'SELECT COUNT(*) n FROM mapping_controls',
              )).single['n']
              as int >=
          maxSubjects) {
        throw StateError('Mapping control capacity');
      }
      await tx.insert('mapping_controls', {
        'subject': AnimeMapping.integer(subject),
        'version': b['version'],
        'digest': AnimeMapping(subject, [], {}, {}).digest,
        'excluded': '[]',
        'batch': b['id'],
        'checked_at': tasks.now,
        'used_at': tasks.now,
      });
      return MappingAnswer('uncovered', b['version'] as String);
    }
    final head = rows.single, version = rows.single['version'] as String;
    if (tasks.now - (head['used_at'] as int) >=
        const Duration(days: 1).inMilliseconds) {
      await tx.update(
        'mapping_controls',
        {'used_at': tasks.now},
        where: 'subject=?',
        whereArgs: [subject],
      );
    }
    if (head['conflict'] == 1) return MappingAnswer('conflict', version);
    if ((jsonDecode(head['excluded'] as String) as List).contains(episode)) {
      return MappingAnswer('excluded', version);
    }
    if ((await tx.query(
      'mapping_batches',
      where: "id=? AND state='ready'",
      whereArgs: [head['batch']],
    )).isEmpty) {
      return MappingAnswer('not_acquired', version);
    }
    final found = await tx.query(
      'mapping_rows',
      where: 'batch=? AND subject=? AND episode=?',
      whereArgs: [head['batch'], subject, episode],
    );
    return found.isEmpty
        ? MappingAnswer('uncovered', version)
        : MappingAnswer(
            'mapped',
            version,
            AnimeMapping.targetList(
              jsonDecode(found.single['targets'] as String),
              episode: true,
            ),
          );
  }

  /// A detailed entry takes priority over the index. A newer control record
  /// blocks older index evidence even when the detail payload was evicted.
  Future<MappingAnswer> subjectTargets(DatabaseExecutor tx, int subject) async {
    final rows = await tx.rawQuery(
      '''SELECT b.version,s.targets,c.conflict
      FROM mapping_subjects s JOIN mapping_batches b ON b.id=s.batch
      CROSS JOIN mapping_index i LEFT JOIN mapping_controls c ON c.subject=s.subject
      WHERE s.subject=? AND b.state='ready' AND COALESCE(c.conflict,0)=0
        AND (b.id=c.batch OR (b.id=i.index_batch AND (c.version IS NULL OR c.version=b.version)))
      ORDER BY b.id=c.batch DESC LIMIT 1''',
      [subject],
    );
    if (rows.isEmpty) return const MappingAnswer('not_acquired', null);
    final row = rows.single;
    return MappingAnswer(
      'mapped',
      row['version'] as String,
      AnimeMapping.targetList(jsonDecode(row['targets'] as String)),
    );
  }

  Future<List<int>> reverse(String type, int tmdb) async {
    if (!['tv', 'movie'].contains(type)) {
      throw ArgumentError('Mapping target type');
    }
    final index = (await db.query('mapping_index')).single['index_batch'];
    if (index == null) return [];
    return [
      for (final row in await db.query(
        'mapping_reverse',
        columns: ['subject'],
        where: 'batch=? AND type=? AND tmdb=?',
        whereArgs: [index, type, tmdb],
      ))
        row['subject'] as int,
    ];
  }

  Future<Map<String, dynamic>?> evidence(int subject) async {
    final rows = await db.rawQuery(
      '''SELECT s.proof FROM mapping_controls c JOIN mapping_subjects s
      ON s.batch=c.batch AND s.subject=c.subject WHERE c.subject=? AND c.conflict=0''',
      [subject],
    );
    return rows.isEmpty
        ? null
        : Map<String, dynamic>.from(jsonDecode(rows.single['proof'] as String));
  }

  static void validateSnapshot(Map<String, dynamic> data) {
    final versions = data['mapping_versions'] as List,
        edges = data['mapping_ancestry'] as List,
        controls = data['mapping_controls'] as List;
    if (versions.length > 256 ||
        edges.length > 65536 ||
        controls.length > maxSubjects) {
      throw const FormatException('Mapping snapshot limit');
    }
    final known = <String>{};
    final review = data['mapping_review'] as List;
    if (review.length != 1 ||
        review.single['id'] != 1 ||
        review.single['day'] is! int ||
        review.single['day'] < 0 ||
        review.single['count'] is! int ||
        review.single['count'] < 0 ||
        review.single['count'] > 2) {
      throw const FormatException('Invalid mapping review budget');
    }
    for (final row in versions) {
      if (row['version'] is! String ||
          !commitPattern.hasMatch(row['version']) ||
          !known.add(row['version'])) {
        throw const FormatException('Invalid mapping version');
      }
    }
    final graph = <String, Set<String>>{};
    for (final row in edges) {
      if (!known.contains(row['parent']) ||
          !known.contains(row['child']) ||
          row['parent'] == row['child'] ||
          !(graph[row['parent']] ??= {}).add(row['child'])) {
        throw const FormatException('Invalid mapping ancestry');
      }
    }
    for (final start in known) {
      final pending = [...?graph[start]], visited = <String>{};
      while (pending.isNotEmpty) {
        final next = pending.removeLast();
        if (next == start) {
          throw const FormatException('Cyclic mapping ancestry');
        }
        if (visited.add(next)) pending.addAll(graph[next] ?? {});
      }
    }
    final subjects = <int>{};
    for (final row in controls) {
      final id = AnimeMapping.integer(row['subject']);
      if (row['checked_at'] is! int ||
          row['checked_at'] < 0 ||
          row['used_at'] is! int ||
          row['used_at'] < 0) {
        throw const FormatException('Invalid mapping timestamps');
      }
      if (!subjects.add(id) ||
          !known.contains(row['version']) ||
          row['digest'] is! String ||
          !digestPattern.hasMatch(row['digest']) ||
          ![0, 1].contains(row['conflict']) ||
          !['bulk', 'detail'].contains(row['evidence']) ||
          row['batch'] is! String ||
          !RegExp(r'^mapping:[a-f0-9]{32}$').hasMatch(row['batch']) ||
          row['excluded'] is! String ||
          row['excluded'].length > 200000) {
        throw const FormatException('Invalid mapping control');
      }
      final excluded = jsonDecode(row['excluded']);
      if (excluded is! List ||
          excluded.length > 10000 ||
          excluded.toSet().length != excluded.length) {
        throw const FormatException('Invalid exclusions');
      }
      for (final ep in excluded) {
        AnimeMapping.integer(ep);
      }
    }
  }
}
