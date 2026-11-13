import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'anime_mapping_store.dart';
import 'catalog.dart';
import 'library_foundation.dart';
import 'metadata.dart';
import 'metadata_servers.dart';
import 'personal_filename_parser.dart';
import 'personal_scraper.dart';
import 'scrape_tasks.dart';
import 'shared_metadata_requests.dart';
import 'work_season.dart';
import 'cloud_media_asset_presentation.dart';
import 'cloud_media_file_classifier.dart';
import 'app_language.dart';
import 'scoped_artwork.dart';

typedef ScanNumberingMatch = ({
  Map<String, Object?> binding,
  String path,
  Map<String, dynamic> choice,
});

class ScanNumberingPreview {
  const ScanNumberingPreview(this.matches, this.deferred);
  final List<ScanNumberingMatch> matches;
  final List<String> deferred;
}

typedef _TvLocal = ({
  String directory,
  int? season,
  int? absoluteOffset,
  bool explicitEpisodes,
  List<({String id, String path, int number})> files,
});

typedef _TvEvidence = ({
  _TvLocal local,
  int series,
  int subject,
  int season,
  int first,
  int last,
  List<String> aliases,
  MappingAnswer subjectMap,
  List<Map<String, Object?>> tv,
  List<Map<String, Object?>> bangumi,
  String? summary,
  String language,
  bool discOrder,
});

typedef _ContinuousTvEvidence = ({
  _TvLocal local,
  Map<String, Object?> choice,
  List<String> aliases,
  int subject,
  List<List<Map<String, Object?>>> seasons,
  List<Map<String, Object?>> bangumi,
});

typedef _SpecialEvidence = ({
  Map<String, Object?> subjectDetails,
  Map<String, Object?> identity,
  Map<String, Object?> tv,
  Map<String, Object?> bg,
  Map<String, Object?> file,
  Map<String, Object?> parentSubject,
  String folder,
  int subject,
});

/// Each provider has independent work, directory range and file decisions.
class ScanRecognition {
  ScanRecognition(this.catalog, this.requests, {this.manualRetry = false});
  final bool manualRetry;
  final Catalog catalog;
  final SharedMetadataRequests requests;
  Future<Map<String, dynamic>> _get(MetadataResource resource, TaskLease lease) =>
      requests.get(resource, lease, reuseCompleted: true, manualRetry: manualRetry);
  ScrapeTasks get tasks => catalog.taskStore!;
  static const portableTables = ['scan_bindings'];
  static const fileGroupTables = [
    'scan_file_groups',
    'scan_file_group_members',
  ];
  static const providers = ['tmdb', 'bangumi'];
  static const layers = ['work', 'range', 'episode'];

  static Future<void> createFileGroupSchema(DatabaseExecutor tx) async {
    await tx.execute('''CREATE TABLE scan_file_groups (
      scope TEXT PRIMARY KEY, work_id TEXT NOT NULL, directory TEXT NOT NULL,
      name TEXT NOT NULL, revision INTEGER NOT NULL DEFAULT 0,
      UNIQUE(work_id,directory,name))''');
    await tx.execute('''CREATE TABLE scan_file_group_members (
      asset_id TEXT PRIMARY KEY, scope TEXT NOT NULL)''');
    await tx.execute(
      'CREATE INDEX scan_file_group_scope ON scan_file_group_members(scope)',
    );
    await tx.execute(
      '''CREATE TRIGGER scan_file_group_removed AFTER DELETE ON scan_file_groups BEGIN
      DELETE FROM scan_file_group_members WHERE scope=OLD.scope;
      DELETE FROM scan_bindings WHERE work_id=OLD.work_id AND layer='range' AND scope=OLD.scope;
      END''',
    );
    await tx.execute(
      '''CREATE TRIGGER scan_file_group_work_removed AFTER DELETE ON works BEGIN
      DELETE FROM scan_file_groups WHERE work_id=OLD.id; END''',
    );
    await tx.execute(
      '''CREATE TRIGGER scan_file_group_asset_removed AFTER DELETE ON assets BEGIN
      DELETE FROM scan_file_group_members WHERE asset_id=OLD.id; END''',
    );
    await tx.execute(
      '''CREATE TRIGGER scan_file_group_asset_changed AFTER UPDATE OF work_id ON assets
      WHEN OLD.work_id IS NOT NEW.work_id BEGIN
      DELETE FROM scan_file_group_members WHERE asset_id=NEW.id; END''',
    );
  }

  static Future<void> createSchema(DatabaseExecutor tx) async {
    await tx.execute('''CREATE TABLE scan_bindings (
      id TEXT PRIMARY KEY, work_id TEXT NOT NULL, asset_id TEXT, provider TEXT NOT NULL,
      layer TEXT NOT NULL, scope TEXT NOT NULL, parent TEXT, revision INTEGER NOT NULL DEFAULT 0,
      state TEXT NOT NULL DEFAULT 'pending', reason TEXT NOT NULL DEFAULT 'unsearched',
      candidates TEXT NOT NULL DEFAULT '[]', adopted TEXT, previous TEXT)''');
    await tx.execute(
      'CREATE INDEX scan_bindings_work ON scan_bindings(work_id,provider,layer)',
    );
    await tx.execute(
      'CREATE INDEX scan_bindings_asset ON scan_bindings(asset_id)',
    );
    await tx.execute(
      'CREATE TABLE scan_dirty_works (work_id TEXT PRIMARY KEY)',
    );
    await tx.execute(
      '''CREATE TRIGGER scan_phase4_work_removed AFTER DELETE ON works BEGIN
      DELETE FROM scan_bindings WHERE work_id=OLD.id;
      DELETE FROM scan_dirty_works WHERE work_id=OLD.id; END''',
    );
    await tx.execute(
      '''CREATE TRIGGER scan_phase4_binding_asset_removed AFTER DELETE ON assets BEGIN
      DELETE FROM scan_bindings WHERE asset_id=OLD.id; END''',
    );
    // Manual relinking or a suspected new file invalidates only the file's decision.
    await tx.execute(
      '''CREATE TRIGGER scan_phase4_binding_asset_changed AFTER UPDATE OF work_id ON assets
      WHEN OLD.work_id IS NOT NEW.work_id BEGIN DELETE FROM scan_bindings WHERE asset_id=NEW.id; END''',
    );
    await tx.execute(
      '''CREATE TRIGGER scan_phase4_binding_content_changed AFTER UPDATE OF revision ON library_content
      WHEN NEW.revision IS NOT OLD.revision BEGIN
      UPDATE scan_bindings SET revision=revision+1 WHERE asset_id=NEW.asset_id;
      END''',
    );
  }

  static String _id(String work, String provider, String layer, String scope) =>
      jsonEncode([work, provider, layer, scope]);
  static String _token(Map row) => jsonEncode([row['id'], row['revision']]);
  static List<Map<String, dynamic>> candidates(Map row) =>
      (jsonDecode(row['candidates'] as String) as List)
          .cast<Map<String, dynamic>>();
  static Map<String, dynamic>? adopted(Map row) => row['adopted'] == null
      ? null
      : jsonDecode(row['adopted'] as String) as Map<String, dynamic>;

  static Future<Map<String, Object?>?> _row(
    DatabaseExecutor tx,
    String id,
  ) async => (await tx.query(
    'scan_bindings',
    where: 'id=?',
    whereArgs: [id],
  )).firstOrNull;

  static Future<void> _put(
    DatabaseExecutor tx,
    String work,
    String provider,
    String layer,
    String scope, {
    String? asset,
    String? parent,
    String reason = 'unsearched',
    List<Map<String, Object?>> choices = const [],
  }) async {
    final id = _id(work, provider, layer, scope);
    final old = await _row(tx, id);
    final encoded = jsonEncode(choices);
    if (old != null && old['parent'] == parent) {
      if (old['adopted'] != null ||
          (old['candidates'] == encoded && old['reason'] == reason)) {
        return;
      }
    }
    final values = {
      'id': id,
      'work_id': work,
      'asset_id': asset,
      'provider': provider,
      'layer': layer,
      'scope': scope,
      'parent': parent,
      'reason': reason,
      'candidates': encoded,
      'revision': old == null ? 0 : (old['revision'] as int) + 1,
      'state': 'pending',
      'adopted': null,
      'previous': null,
    };
    if (old == null) {
      await tx.insert('scan_bindings', values);
    } else {
      await tx.update('scan_bindings', values, where: 'id=?', whereArgs: [id]);
    }
  }

  /// Called after a complete scan. Existing identities are not searched again.
  Future<List<String>> schedule(
    String source, {
    TaskLease? lease,
    bool newJobsOnly = false,
    List<String>? priorityWorks,
    Set<String> skipWorks = const {},
  }) async {
    if (priorityWorks?.isEmpty == true) return [];
    if (!newJobsOnly && catalog.automaticRecognition) {
      await tasks.db.transaction((tx) async {
        if (lease != null) await tasks.checkIn(tx, lease);
        final rows = await tx.rawQuery('''SELECT b.*, a.name, a.relative_path, a.category,
          c.state AS content_state
          FROM scan_bindings b JOIN assets a ON a.id=b.asset_id
          JOIN library_content c ON c.asset_id=a.id
          JOIN library_work_protection p ON p.work_id=b.work_id
          JOIN works w ON w.id=b.work_id
          WHERE b.provider='tmdb' AND b.layer='episode'
            AND b.state='confirmed' AND b.reason='verified_specials'
            AND c.state='current'
            AND p.identity_locked=0 AND p.legacy_lock=0 AND w.hidden=0
            AND EXISTS (SELECT 1 FROM library_locations l
              WHERE l.entity_id=b.work_id AND l.kind='work' AND l.source_id=?)''', [source]);
        for (final row in rows) {
          final value = adopted(row);
          if (value?['by'] != 'verified_specials' ||
              value?['season'] != 0 ||
              _specialCandidate(row)) {
            continue;
          }
          await tx.rawUpdate('''UPDATE scan_bindings SET revision=revision+1,
            state='pending', reason='special_no_longer_eligible',
            previous=adopted, adopted=NULL, candidates='[]', parent=NULL WHERE id=?''', [row['id']]);
        }
      });
    }
    final works = await tasks.db.rawQuery(
      '''SELECT w.id FROM library_locations l
      JOIN works w ON w.id=l.entity_id JOIN library_work_protection protection ON protection.work_id=w.id
      WHERE l.source_id=? AND l.kind='work' AND w.hidden=0 AND protection.legacy_lock=0
        ${priorityWorks == null ? '' : 'AND w.id IN (${List.filled(priorityWorks.length, '?').join(',')})'}
        AND w.tmdb_type IS NULL AND w.bangumi_id IS NULL
        AND (?=0 OR NOT EXISTS
          (SELECT 1 FROM scrape_tasks t WHERE t.id='recognize:' || w.id))
        AND (EXISTS (SELECT 1 FROM scan_dirty_works d WHERE d.work_id=w.id)
          OR EXISTS (SELECT 1 FROM scan_bindings b WHERE b.work_id=w.id
            AND b.layer='work' AND b.reason='unsearched' AND b.state='pending')
          OR NOT EXISTS (SELECT 1 FROM scan_bindings b WHERE b.work_id=w.id))
        AND (EXISTS (SELECT 1 FROM assets a WHERE a.work_id=w.id
          AND NOT EXISTS (SELECT 1 FROM scan_missing_assets m WHERE m.asset_id=a.id))
          OR EXISTS (SELECT 1 FROM scan_bindings b WHERE b.work_id=w.id
            AND b.layer='work' AND b.provider='tmdb'
            AND json_type(b.adopted,'\$.special_inventory')='array'))''',
      [source, ...?priorityWorks, newJobsOnly ? 1 : 0],
    );
    final jobs = <String>[];
    for (final work in works) {
      final id = work['id'] as String;
      if (skipWorks.contains(id)) continue;
      final needsSearch = await tasks.db.transaction((tx) async {
        if (lease != null) await tasks.checkIn(tx, lease);
        var needsSearch = false;
        final dirty =
            await tx.delete(
              'scan_dirty_works',
              where: 'work_id=?',
              whereArgs: [id],
            ) >
            0;
        final invalidPart = dirty && (await _invalidateStandaloneInventory(tx, id) ||
            await _invalidateDiscInventory(tx, id) ||
            await _invalidateCorrectedInventory(tx, id) ||
            await _invalidateChangedPart(tx, id));
        for (final provider in providers) {
          final identity = await _row(tx, _id(id, provider, 'work', ''));
          if (identity == null) {
            await _put(tx, id, provider, 'work', '');
            needsSearch = true;
          } else if (identity['state'] == 'pending' &&
              identity['reason'] == 'unsearched') {
            needsSearch = true;
          }
          if (dirty && !invalidPart) await _syncChildren(tx, id, provider);
          if (dirty && !invalidPart && catalog.automaticRecognition && provider == 'tmdb' &&
              adopted(identity ?? {})?['verified_part_season'] != null) {
            needsSearch = true;
          }
        }
        return needsSearch;
      });
      if (needsSearch && jobs.length < 16) {
        jobs.add(await enqueue(source, id, retry: true, parentLease: lease));
      }
    }
    if (!newJobsOnly && catalog.automaticRecognition) {
      // Explicit rescans may revisit an automatic conflict or a restored inventory.
      // No startup sweep, background loop, or change to a confirmed row here.
      final bound = await tasks.db.rawQuery('''SELECT DISTINCT b.work_id
        FROM scan_bindings b JOIN library_locations l ON l.entity_id=b.work_id
        JOIN works w ON w.id=b.work_id AND w.hidden=0
        WHERE l.source_id=? AND l.kind='work' AND b.layer='work'
          AND (b.state='confirmed' OR
            b.state='pending' AND b.reason IN ('corrected_inventory_changed','no_match','request_failed','query_incomplete','invalid_response','detail_budget_exhausted','conflicting_title')) ''', [source]);
      for (final row in bound) {
        if (jobs.length >= 16) break;
        final id = row['work_id'] as String;
        if (skipWorks.contains(id)) continue;
        if (!jobs.contains('recognize:$id') &&
            (await _automaticConflict(tasks.db, id) != null ||
                await _pendingAutomaticRetry(tasks.db, id) ||
                await _hasMixedFilmCandidate(tasks.db, id))) {
          jobs.add(await enqueue(source, id, retry: true, parentLease: lease));
        }
      }
      final existing = await tasks.db.rawQuery(
        r"""SELECT DISTINCT b.work_id FROM scan_bindings b
        JOIN library_locations l ON l.kind='work' AND l.entity_id=b.work_id
        JOIN works w ON w.id=b.work_id AND w.hidden=0
        WHERE l.source_id=? AND b.provider='tmdb' AND b.layer='work'
          AND b.state='confirmed' AND json_extract(b.adopted,'$.type')='tv'
          AND (EXISTS (SELECT 1 FROM scrape_tasks t WHERE t.id='scope:specials:' || b.work_id)
            OR EXISTS (SELECT 1 FROM assets a WHERE a.work_id=b.work_id
              AND a.category='extra' AND a.extra_type IN ('OVA','OAD','SP')))""",
        [source],
      );
      for (final work in existing) {
        if (skipWorks.contains(work['work_id'])) continue;
        final job = await enqueueSpecials(
          source,
          work['work_id'] as String,
          parentLease: lease,
        );
        if (job != null) jobs.add(job);
      }
    }
    return jobs;
  }

  Future<String> enqueue(
    String source,
    String work, {
    bool retry = false,
    TaskLease? parentLease,
  }) => tasks.enqueue(
    'recognize:$work',
    workId: work,
    sourceId: source,
    intent: {'kind': 'recognition'},
    steps: ['recognize'],
    restartComplete: retry,
    parentLease: parentLease,
  );

  Future<String> enqueueRange(String source, String id) async {
    final row = await _row(tasks.db, id);
    if (row == null || row['layer'] != 'range' || adopted(row) == null) {
      throw StateError('Range is not confirmed');
    }
    final digest = sha256.convert(utf8.encode(id));
    return tasks.enqueue(
      'scope:$digest',
      workId: row['work_id'] as String,
      sourceId: source,
      intent: {
        'kind': 'scope_evidence',
        'range': id,
        'revision': row['revision'],
      },
      steps: ['scope_evidence'],
      restartComplete: true,
    );
  }

  static String? _decimalSpecial(Map<String, Object?> file) {
    if (file['category'] != 'extra' || file['content_state'] != 'current')
      return null;
    final name = file['name'] as String;
    return RegExp(
          r'\[(\d{1,3}\.\d{1,2})(?=\]|\()',
          caseSensitive: false,
        ).firstMatch(name)?.group(1) ??
        RegExp(
          r'\bSP\s*(\d{1,3}\.\d{1,2})\b',
          caseSensitive: false,
        ).firstMatch(name)?.group(1);
  }

  static bool _specialCandidate(Map<String, Object?> file) =>
      file['content_state'] == 'current' &&
      (_decimalSpecial(file) != null ||
          CloudMediaAssetPresentation.isSpecialMappingCandidate(file));

  static const _mixedSpecialScope = '@tmdb-specials';

  Future<String?> enqueueSpecials(
    String source,
    String work, {
    TaskLease? parentLease,
  }) async {
    final row = await _row(tasks.db, _id(work, 'tmdb', 'work', ''));
    final identity = row == null ? null : adopted(row);
    if (identity?['type'] != 'tv' ||
        !(identity?['seasons'] as List? ?? []).any(
          (season) => season['season'] == 0,
        )) {
      return null;
    }
    final files = (await _workFiles(
      tasks.db,
      work,
    )).files.where(_specialCandidate).toList();
    if (files.isEmpty) return null;
    final fingerprint = sha256
        .convert(
          utf8.encode(
            jsonEncode([
              for (final file in files)
                [file['id'], file['name'], file['file_group']],
            ]),
          ),
        )
        .toString();
    return tasks.enqueue(
      'scope:specials:$work',
      workId: work,
      sourceId: source,
      intent: {
        'kind': 'tmdb_specials',
        'identity': _token(row!),
        'matcher': 2,
        'files': fingerprint,
      },
      steps: ['tmdb_specials'],
      parentLease: parentLease,
    );
  }

  static Map<String, dynamic>? _ovaChapter(
    Map<String, Object?> file,
    List<Map<String, dynamic>> specials,
    int? year,
    Iterable<int> seasonYears,
  ) {
    if (year == null) return null;
    final later = seasonYears.where((value) => value > year).toList()..sort();
    final pool = specials.where((chapter) {
      final type = CloudMediaAssetPresentation.specialTypeFromTitle(
        chapter['title'] as String,
      );
      final date = DateTime.tryParse('${chapter['date']}');
      return (type == 'OVA' || type == 'OAD') &&
          date != null &&
          date.year >= year &&
          date.year <= year + 1 &&
          (later.isEmpty || date.year < later.first);
    }).toList();
    final ordinal = CloudMediaAssetPresentation.explicitSpecialNumber(file);
    if (ordinal != null) {
      final numbered = pool
          .where(
            (chapter) =>
                CloudMediaAssetPresentation.explicitSpecialNumber({
                  'name': chapter['title'],
                }) ==
                ordinal,
          )
          .singleOrNull;
      if (numbered != null) return numbered;
      if (pool.any(
        (chapter) =>
            CloudMediaAssetPresentation.explicitSpecialNumber({
              'name': chapter['title'],
            }) !=
            null,
      )) {
        return null;
      }
    }
    return pool.singleOrNull;
  }

  Future<void> runSpecials(TaskLease lease, String token) async {
    final work = lease.workId!;
    final identity = await _row(tasks.db, _id(work, 'tmdb', 'work', ''));
    if (identity == null ||
        adopted(identity) == null ||
        _token(identity) != token) {
      throw const TaskStopped();
    }
    final result = await _fetchChapters(
      lease,
      'tmdb',
      id: adopted(identity)!['id'] as int,
      season: 0,
    );
    await tasks.commit(lease, (tx) async {
      final current = await _row(tx, identity['id'] as String);
      if (current == null || _token(current) != token)
        throw const TaskStopped();
      if (!result.complete || result.chapters.isEmpty) return {'matched': 0};
      final inventory = await _workFiles(tx, work);
      final files = inventory.files.where(_specialCandidate).toList();
      final seasons = (adopted(identity)!['seasons'] as List)
          .whereType<Map>()
          .where((season) => _positive(season['season']));
      final seasonYears = seasons
          .map((season) => season['year'])
          .whereType<int>();
      var year = Catalog.year(p.posix.basename(inventory.folder));
      if (year == null) {
        final numbered = (await tx.query(
          'scan_bindings',
          where:
              "work_id=? AND provider='tmdb' AND layer='range' AND state='confirmed'",
          whereArgs: [work],
        )).map(adopted).map((row) => row?['season']).where(_positive).toSet();
        if (numbered.length == 1) {
          year = seasons
              .where((s) => s['season'] == numbered.single)
              .map((s) => s['year'])
              .whereType<int>()
              .firstOrNull;
        }
      }
      String scopeFor(Map file) =>
          file['file_group'] as String? ??
          _directoryScope(file['relative_path'] as String, inventory.folder);
      final mainScopes = inventory.files
          .where((file) => file['category'] == 'main')
          .map(scopeFor)
          .toSet();
      final specials = [
        for (final chapter in result.chapters)
          <String, dynamic>{
            ...chapter,
            'name': chapter['title'],
            'episode_number': chapter['sort'],
            'air_date': chapter['date'],
          },
      ];
      final oldMatches = CloudMediaAssetPresentation.mapSpecialEpisodes(
        assets: files,
        specials: specials,
      );
      final matches = <String, Map<String, dynamic>>{};
      final counts = <Object?, int>{};
      for (final file in files) {
        final id = file['id'] as String;
        final decimal = _decimalSpecial(file);
        final old = oldMatches[file['relative_path']];
        final type = CloudMediaAssetPresentation.specialType(file);
        final candidate = decimal == null
            ? (type == 'OVA' || type == 'OAD')
                  ? _ovaChapter(file, specials, year, seasonYears)
                  : (CloudMediaAssetPresentation.explicitSpecialNumber(file) ==
                            old?['sort']
                        ? old
                        : null)
            : specials
                  .where(
                    (chapter) => RegExp(
                      '(?:\\bSP\\s*|(?<![0-9.]))${RegExp.escape(decimal)}(?![0-9.])',
                      caseSensitive: false,
                    ).hasMatch('${chapter['title']} ${chapter['overview'] ?? ''}'),
                  )
                  .singleOrNull;
        if (candidate == null || candidate['sort'] is! int) continue;
        matches[id] = candidate;
        counts.update(
          candidate['sort'],
          (count) => count + 1,
          ifAbsent: () => 1,
        );
      }
      final claimed =
          (await tx.query(
                'scan_bindings',
                where:
                    "work_id=? AND provider='tmdb' AND layer='episode' AND state='confirmed'",
                whereArgs: [work],
              ))
              .map(adopted)
              .where((item) => item?['season'] == 0)
              .map((item) => item!['episode'])
              .toSet();
      var matched = 0;
      for (final file in files) {
        final asset = file['id'] as String;
        final chapter = matches[asset];
        if (chapter == null ||
            counts[chapter['sort']] != 1 ||
            claimed.contains(chapter['sort']))
          continue;
        final existing = await _row(tx, _id(work, 'tmdb', 'episode', asset));
        if (existing != null && existing['state'] != 'pending') continue;
        final dir = scopeFor(file);
        final directoryRange = await _row(tx, _id(work, 'tmdb', 'range', dir));
        if (directoryRange?['state'] == 'skipped') continue;
        final mixed = mainScopes.contains(dir);
        final scope = mixed ? _mixedSpecialScope : dir;
        if (mixed) {
          await _put(
            tx,
            work,
            'tmdb',
            'range',
            scope,
            parent: token,
            reason: 'range_unconfirmed',
          );
        }
        final range = mixed
            ? await _row(tx, _id(work, 'tmdb', 'range', scope))
            : directoryRange;
        if (range == null ||
            range['state'] == 'skipped' ||
            (adopted(range) != null && adopted(range)!['season'] != 0))
          continue;
        if (adopted(range) == null) {
          final last = specials
              .map((item) => item['sort'])
              .whereType<int>()
              .fold(0, (max, number) => number > max ? number : max);
          await _saveDecision(
            tx,
            range,
            {
              'season': 0,
              'first': 1,
              'last': last,
              'offset': 0,
              'chapters': result.chapters,
            },
            reason: 'verified_specials',
            by: 'verified_specials',
          );
        }
        final confirmed = (await _row(tx, range['id'] as String))!;
        await _put(
          tx,
          work,
          'tmdb',
          'episode',
          asset,
          asset: asset,
          parent: _token(confirmed),
          reason: 'separate_file_review',
        );
        final episode = (await _row(tx, _id(work, 'tmdb', 'episode', asset)))!;
        if (episode['state'] != 'pending') continue;
        await _saveDecision(
          tx,
          episode,
          {
            'season': 0,
            'episode': chapter['sort'],
            'chapter_id': chapter['id'],
            'title': chapter['title'],
            if (chapter['still'] != null) 'still': chapter['still'],
          },
          reason: 'verified_specials',
          by: 'verified_specials',
        );
        matched++;
      }
      if (matched > 0) await _syncChildren(tx, work, 'tmdb');
      return {'matched': matched};
    });
    await catalog.reload();
  }

  Future<void> runRange(TaskLease lease, String id, int revision) async {
    final range = await _row(tasks.db, id);
    final choice = range == null ? null : adopted(range);
    if (range == null || choice == null || range['revision'] != revision) {
      throw const TaskStopped();
    }
    final work = lease.workId!;
    final provider = range['provider'] as String;
    final tmdb = provider == 'tmdb';
    final identity = await _row(tasks.db, _id(work, provider, 'work', ''));
    if (identity == null || _token(identity) != range['parent']) {
      throw const TaskStopped();
    }
    final result = await _fetchChapters(
      lease,
      provider,
      id: (tmdb ? adopted(identity)!['id'] : choice['id']) as int,
      season: choice['season'] as int?,
    );
    final chapters = result.chapters;
    await tasks.commit(lease, (tx) async {
      final current = await _row(tx, id);
      if (current?['revision'] != revision ||
          current?['adopted'] != range['adopted']) {
        throw const TaskStopped();
      }
      await tx.update(
        'scan_bindings',
        {
          // Enrich the confirmed scope without invalidating child tokens.
          'adopted': jsonEncode({
            ...choice,
            'chapters': chapters,
            if (result.summary != null) ...{
              'summary': result.summary,
              if (tmdb) 'summary_language': result.language,
            },
          }),
        },
        where: 'id=?',
        whereArgs: [id],
      );
      await _syncChildren(tx, work, provider);
      await ScopedArtwork.publishDrafts(catalog, tx, work);
      return {'chapters': chapters.length};
    });
    await catalog.reload();
  }

  Future<
    ({
      List<Map<String, Object?>> chapters,
      bool complete,
      String? summary,
      String language,
    })
  >
  _fetchChapters(
    TaskLease lease,
    String provider, {
    required int id,
    int? season,
    bool regularOnly = false,
    String? languageOverride,
  }) async {
    final tmdb = provider == 'tmdb';
    final language = languageOverride ?? AppLanguage.instance.metadataLanguage;
    final path = tmdb ? 'tv/$id/season/$season' : 'episodes';
    AnimeMappingStore.checkForeground();
    final body = await _get(
      metadataResource(
        provider,
        path,
        parameters: tmdb
            ? {'language': season == 0 && languageOverride == null ? 'zh-CN' : language}
            : {
                'subject_id': '$id',
                'limit': '100',
                if (regularOnly) 'type': '0',
              },
      ),
      lease,
    );
    final raw = body[tmdb ? 'episodes' : 'data'];
    if (raw is! List || (tmdb && body['season_number'] != season)) {
      throw const MetadataFailure('protocol', 0);
    }
    final chapters = <Map<String, Object?>>[];
    for (final episode in raw.whereType<Map>().take(100)) {
      final chapterId = episode['id'];
      final sort = episode[tmdb ? 'episode_number' : 'sort'];
      if (!_positive(chapterId) ||
          sort is! num ||
          !sort.isFinite ||
          sort < 0 ||
          (tmdb && episode['season_number'] != season) ||
          (!tmdb &&
              episode['subject_id'] != null &&
              episode['subject_id'] != id)) {
        continue;
      }
      final title = !tmdb && languageOverride == 'ja-JP'
          ? '${episode['name'] ?? ''}' : _title(episode);
      chapters.add({
        'id': chapterId,
        'sort': sort == sort.toInt() ? sort.toInt() : sort,
        'type': tmdb ? 0 : episode['type'],
        'title': title.substring(0, title.length.clamp(0, 256)),
        if (!tmdb && languageOverride != 'ja-JP' && episode['name'] is String &&
            (episode['name'] as String).trim().isNotEmpty)
          'verification_title': (episode['name'] as String).substring(0, (episode['name'] as String).length.clamp(0, 256)),
        if (!tmdb && languageOverride == 'ja-JP') 'display_title': _title(episode),
        'date': episode[tmdb ? 'air_date' : 'airdate'],
        if (episode['overview'] case final String summary when season == 0)
          'overview': summary.substring(0, summary.length.clamp(0, 4096)),
        if (episode['still_path'] case final String still
            when tmdb &&
                RegExp(
                  r'^/[A-Za-z0-9_-]{1,160}\.(jpg|png|webp)$',
                ).hasMatch(still))
          'still': MetadataServers.endpoint(
            1,
            'w300$still',
            base: MetadataServers.official[1],
          ).toString(),
      });
    }
    final summary = body['overview'];
    return (
      chapters: chapters,
      complete:
          chapters.length == raw.length &&
          (tmdb || body['total'] == raw.length),
      summary: summary is String
          ? summary.substring(0, summary.length.clamp(0, 4096))
          : null,
      language: language,
    );
  }

  static MetadataResource metadataResource(
    String provider,
    String path, {
    Map<String, String> parameters = const {},
    String body = '',
    bool listResponse = false,
  }) {
    final tmdb = provider == 'tmdb';
    final credentials = Metadata.credentials;
    if (tmdb && !credentials.isConfigured) {
      throw const MetadataFailure('missing_credentials', 0);
    }
    final index = tmdb ? 0 : 2;
    return MetadataResource(
      service: provider,
      resource: path,
      routes: MetadataServers.routes(index, path),
      headers: {
        'Accept': 'application/json',
        if (tmdb) ...credentials.headers,
        if (body.isNotEmpty) 'Content-Type': 'application/json',
      },
      parameters: {
        if (tmdb) 'language': AppLanguage.instance.metadataLanguage,
        if (tmdb && credentials.mode == 'apiKey')
          'api_key': credentials.value.trim(),
        ...parameters,
      },
      method: body.isEmpty ? 'GET' : 'POST',
      body: body,
      listResponse: listResponse,
      trustCustom: tmdb && MetadataServers.trustCustomTmdb,
    );
  }

  static String _title(Map row) => [row['name_cn'], row['title'], row['name']]
      .whereType<String>()
      .firstWhere((s) => s.trim().isNotEmpty, orElse: () => '');
  static int? _year(Map row) => DateTime.tryParse(
    (row['date'] ?? row['first_air_date'] ?? row['release_date'] ?? '')
        .toString(),
  )?.year;

  static bool canRetryWorkQuery(Map<String, Object?> row) {
    final reason = row['reason'];
    return reason == 'unsearched' ||
        (reason != 'detail_budget_exhausted' && workQueryIncomplete(reason)) ||
        (row['provider'] == 'bangumi' &&
            reason == 'ambiguous' &&
            candidates(row).singleOrNull?['exact'] == true);
  }

  static bool canSupplementWorkQuery(Map<String, Object?> row) =>
      row['previous'] == null &&
      (canRetryWorkQuery(row) ||
          const {'verify_candidate', 'untyped_id', 'ambiguous', 'conflicting_title', 'no_match', 'detail_budget_exhausted'}
              .contains(row['reason']));

  static bool workQueryIncomplete(Object? reason) => const {
    'request_failed', 'invalid_response', 'query_incomplete', 'detail_budget_exhausted',
  }.contains(reason);

  Future<({String reason, List<Map<String, Object?>> choices})> _search(
    TaskLease lease,
    String provider,
    String raw,
    String title,
    int? year,
    Set<int> markers,
    Set<String> types,
    List<String> hints, {
    bool filenameFallback = false,
    bool firstBangumiPage = false,
    List<String>? bangumiAirDates,
    int? movieReleaseYear,
    bool liveBangumiOnly = false,
    int? tvPremiereYear,
  }) async {
    final tmdb = provider == 'tmdb';
    final bangumiMarkers = {
      for (final match in RegExp(
        r'\{bangumi-(\d+)\}',
        caseSensitive: false,
      ).allMatches(raw))
        int.parse(match[1]!),
    };
    if ((tmdb && (markers.length > 1 || types.length > 1)) ||
        (!tmdb && bangumiMarkers.length > 1)) {
      return (reason: 'conflicting_markers', choices: <Map<String, Object?>>[]);
    }
    final candidates = <Map<String, Object?>>[];
    if (tmdb && WorkSeason.part(raw) != null) {
      hints = <String>{...hints, ...hints.map(WorkSeason.withoutPart)}.toList();
      title = WorkSeason.withoutPart(title);
    }
    final aliasDetails = <String, Map<String, dynamic>>{};
    Future<Map<String, dynamic>> get(
      String path, {
      Map<String, String> query = const {},
      String body = '',
    }) async {
      AnimeMappingStore.checkForeground();
      return _get(
        metadataResource(provider, path, parameters: query, body: body),
        lease,
      );
    }

    void add(Map row, String type, {int? expected, bool reverse = false}) {
      final id = row['id'];
      final label = _title(row);
      if (id is! int ||
          id <= 0 ||
          id > 2147483647 ||
          label.isEmpty ||
          (expected != null && id != expected) ||
          (!tmdb && row['type'] != 2)) {
        return;
      }
      final aliases = PersonalMetadataScraper.officialTitles(row);
      final titleMatches = aliases.any(
        (name) =>
            hints.any((hint) => _sameLocalTitle(hint, name) ||
                type == 'movie' && _movieTitle(hint) == _movieTitle(name)),
      );
      final remoteYear = _year(row);
      final seasonYearMatches =
          tmdb &&
          type == 'tv' &&
          year != null &&
          (row['seasons'] as List? ?? []).whereType<Map>().any(
            (season) =>
                _positive(season['season_number']) &&
                '${season['air_date'] ?? ''}'.startsWith('$year-'),
          );
      if (expected == null &&
          (!titleMatches ||
              (type != 'tv' && year != null && remoteYear != year))) {
        return;
      }
      if (!tmdb) {
        final requested = WorkSeason.explicit({'title': raw});
        final actual = WorkSeason.explicit({'title': label});
        if (requested != null &&
            (actual != null && requested != actual ||
                requested > 1 && actual == null && expected == null))
          return;
      }
      final seasons = row['seasons'];
      final synopsis = row[tmdb ? 'overview' : 'summary'];
      candidates.add({
        'id': id,
        'type': type,
        'title': label,
        'year': remoteYear,
        if (type == 'movie' && row['release_date'] is String)
          'release_date': row['release_date'],
        if (type == 'movie' && row['original_title'] is String)
          'original_title': row['original_title'],
        if (row['poster_path'] case final String poster
            when tmdb && RegExp(r'^/[A-Za-z0-9_-]+\.(jpg|png|webp)$').hasMatch(poster))
          'poster': MetadataServers.endpoint(1, 'w185$poster').toString(),
        if (!tmdb && row['images'] is Map &&
            MetadataServers.imageResource('${(row['images'] as Map)['large']}') != null)
          'poster': (row['images'] as Map)['large'],
        'exact':
            titleMatches &&
            (year == null ||
                remoteYear == year ||
                seasonYearMatches ||
                (tmdb && type == 'tv' && seasons == null)),
        'title_matches': titleMatches,
        'directory_title_matches': aliases.any((name) =>
            PersonalMetadataScraper.queries(
                title.replaceFirst(RegExp(r'^(?:电影|劇場版|剧场版)\s+'), '')).any((hint) =>
                PersonalMetadataScraper.exactTitle(hint, name))),
        'aliases': aliases.take(12).toList(),
        if (expected != null) 'marker': !reverse,
        if (reverse) 'reverse': true,
        if (seasons is List)
          'seasons': [
            for (final s in seasons.whereType<Map>().take(100))
              if (s['season_number'] is int && s['episode_count'] is int)
                {
                  'season': s['season_number'],
                  'count': s['episode_count'],
                  'year': DateTime.tryParse('${s['air_date'] ?? ''}')?.year,
                },
          ],
        if (synopsis is String)
          'summary': synopsis.substring(0, synopsis.length.clamp(0, 4096)),
        if (tmdb) 'summary_language': AppLanguage.instance.metadataLanguage,
        if (tmdb && row['backdrop_path'] is String)
          'backdrop_path': row['backdrop_path'],
      });
    }

    Future<bool> searchBangumi(String hint) async {
      const limit = 24;
      // The service can return 20 rows despite limit=24; common series queries
      // have 174 hits and need nine pages. Keep a finite budget, and still
      // refuse confirmation when the entire result cannot be checked.
      final maxPages = firstBangumiPage ? 1 : 12;
      final body = jsonEncode({
        'keyword': hint,
        'sort': 'match',
        'filter': {
          'type': [2],
          if (bangumiAirDates != null)
            'air_date': bangumiAirDates
          else if (year != null)
            'air_date': ['>=$year-01-01', '<${year + 1}-01-01'],
        },
      });
      final seen = <int>{};
      var offset = 0;
      int? expectedTotal;
      int? stride;
      var lookAhead = true;
      final fetched = <int, Map<String, dynamic>?>{};
      Future<Map<String, dynamic>?> readPage(int start) async {
        try {
          return await get('search/subjects',
            query: {'limit': '$limit', if (start > 0) 'offset': '$start'},
            body: body);
        } on MetadataFailure {
          if (start == 0) rethrow;
          return null;
        }
      }
      for (var page = 0; page < maxPages; page++) {
        if (lookAhead && fetched.isEmpty && stride != null && expectedTotal != null) {
          final starts = [
            for (var i = 0; i < 3 && page + i < maxPages &&
                offset + i * stride < expectedTotal; i++) offset + i * stride,
          ];
          final responses = await Future.wait(starts.map(readPage));
          for (var i = 0; i < starts.length; i++) {
            fetched[starts[i]] = responses[i];
          }
        }
        final response = fetched.containsKey(offset)
            ? fetched.remove(offset) : await readPage(offset);
        if (response == null) return false;
        final rows = response['data'];
        final total = response['total'];
        if (rows is! List ||
            rows.length > limit ||
            (total != null && total is! int) ||
            (expectedTotal != null && total != expectedTotal) ||
            (total is int && total < offset + rows.length)) {
          return false;
        }
        final before = seen.length;
        for (final row in rows) {
          if (row is! Map || !_positive(row['id'])) return false;
          if (seen.add(row['id'] as int)) add(row, 'anime');
        }
        // Advance by the rows actually returned. Bangumi may return fewer than
        // requested, and a repeated or empty page cannot prove completeness.
        if (offset > 0 && seen.length == before) return false;
        offset += rows.length;
        if (total == null || offset == total) return true;
        if (rows.isEmpty) return false;
        expectedTotal = total as int;
        stride ??= rows.length;
        if (rows.length != stride) {
          // The server shortened an intermediate page. Follow its actual
          // offsets and ignore speculative pages that no longer line up.
          lookAhead = false;
          fetched.clear();
        }
      }
      return false;
    }

    var incomplete = false;
    var detailBudgetExhausted = false;
    var invalidResponse = false;
    final searchYears = <String, int>{};
    var searchYearConflict = false;
    var queryIncomplete = false;
    var truncated = false;
    try {
      if (tmdb && markers.isNotEmpty) {
        final id = markers.single;
        for (final type in (types.isEmpty ? ['tv', 'movie'] : types)) {
          try {
            add(
              await get(
                '$type/$id',
                query: {
                  'append_to_response': 'alternative_titles,translations',
                },
              ),
              type,
              expected: id,
            );
          } on MetadataFailure catch (e) {
            if (e.category != 'not_found') incomplete = true;
          }
        }
      } else if (!tmdb && bangumiMarkers.isNotEmpty) {
        final id = bangumiMarkers.single;
        add(await get('subjects/$id'), 'anime', expected: id);
      } else {
        if (title.isEmpty) {
          return (reason: 'no_title', choices: <Map<String, Object?>>[]);
        }
        if (!tmdb && !liveBangumiOnly) {
          final old = PersonalMetadataScraper();
          try {
            final local = await old.lookupOfflineBangumi(
              title,
              year,
              hints: hints,
              tmdbId: markers.singleOrNull,
            );
            if (local != null) add(local, 'anime');
          } finally {
            old.close();
          }
        }
        for (final hint in hints.take(6)) {
          // No-ID filenames may reveal a different work after a folder hit.
          // Finish the bounded hint set before treating a candidate as unique.
          if (candidates.isNotEmpty && !filenameFallback) break;
          if (!tmdb) {
            queryIncomplete = !await searchBangumi(hint);
            if (queryIncomplete) break;
            continue;
          }
          final maxPages = filenameFallback ? 3 : 1;
          final seenPages = <String>{};
          final nextPages = <int, Map<String, dynamic>?>{};
          Future<Map<String, dynamic>?> readSearchPage(int page) async {
            try {
              return await get(
                movieReleaseYear != null ? 'search/movie' :
                    tvPremiereYear != null ? 'search/tv' : 'search/multi',
                query: {
                'query': hint, if (page > 1) 'page': '$page',
                if (movieReleaseYear != null) 'primary_release_year': '$movieReleaseYear',
                if (tvPremiereYear != null) 'first_air_date_year': '$tvPremiereYear',
              });
            } on MetadataFailure {
              if (page == 1) rethrow;
              return null;
            }
          }
          for (var page = 1; page <= maxPages; page++) {
            final response = nextPages.containsKey(page)
                ? nextPages.remove(page) : await readSearchPage(page);
            if (response == null) {
              incomplete = true;
              break;
            }
            final rows = response['results'];
            if (rows is! List) {
              return (
                reason: 'request_failed',
                choices: <Map<String, Object?>>[],
              );
            }
            final limit = filenameFallback ? 20 : 12;
            final totalPages = (response['total_pages'] as num? ?? 1).toInt();
            final signature = jsonEncode(rows);
            if (!seenPages.add(signature) || (rows.isEmpty && page < totalPages)) {
              queryIncomplete = true;
              break;
            }
            truncated = truncated ||
                rows.length > limit || totalPages > maxPages;
            for (final row in rows.whereType<Map>().take(limit)) {
              final type = movieReleaseYear != null ? 'movie' :
                  tvPremiereYear != null ? 'tv' : row['media_type'];
              if (!['tv', 'movie'].contains(type)) continue;
              if (types.isNotEmpty && !types.contains(type)) continue;
              final candidateYear = _year(row);
              if (_positive(row['id']) && candidateYear != null) {
                final key = '$type/${row['id']}';
                final before = searchYears[key];
                if (before != null && before != candidateYear) searchYearConflict = true;
                searchYears[key] = candidateYear;
              }
              // An older series can contain a later season; a newer series
              // cannot contain a season before its own first-air year.
              if (filenameFallback && year != null && candidateYear != null &&
                  (type == 'movie' && candidateYear != year ||
                      type == 'tv' && candidateYear > year)) continue;
              final nameMatches = PersonalMetadataScraper.officialTitles(row).any(
                (name) => hints.any((hint) => PersonalMetadataScraper.exactTitle(hint, name)),
              );
              final directoryMatches = PersonalMetadataScraper.officialTitles(row).any(
                (name) => PersonalMetadataScraper.queries(
                  title.replaceFirst(RegExp(r'^(?:电影|劇場版|剧场版)\s+'), ''),
                ).any((hint) => PersonalMetadataScraper.exactTitle(hint, name)),
              );
              // A filename match alone does not connect a translated directory
              // title to this identity. Verify its official aliases as well.
              if (filenameFallback && (!nameMatches || !directoryMatches) && _positive(row['id'])) {
                // Preserve a filename-only proposal even when detail verification
                // fails; the incomplete reason still forbids automatic adoption.
                if (nameMatches) add(row, type as String);
                final key = '$type/${row['id']}';
                if (!aliasDetails.containsKey(key)) {
                  // Budget applies across all hints, not separately per query.
                  if (aliasDetails.length >= 12) {
                    detailBudgetExhausted = true;
                    continue;
                  }
                  aliasDetails[key] = await get(key, query: {
                    'append_to_response': 'alternative_titles,translations',
                  });
                }
                final detail = aliasDetails[key]!;
                if (detail['id'] != row['id']) {
                  invalidResponse = true;
                  continue;
                }
                add({...row, ...detail}, type as String);
              } else {
                add(row, type as String);
              }
            }
            if (page >= totalPages) break;
            if (page == 1) {
              final following = [for (var n = 2; n <= maxPages && n <= totalPages; n++) n];
              final responses = await Future.wait(following.map(readSearchPage));
              for (var i = 0; i < following.length; i++) {
                nextPages[following[i]] = responses[i];
              }
            }
          }
        }
        if (!tmdb && !queryIncomplete && markers.length == 1) {
          // Reverse lookup offers additional choices; a mapping alone does not
          // identify the local season or a local file.
          final related = <int>{};
          for (final type in (types.isEmpty ? ['tv', 'movie'] : types)) {
            related.addAll(
              await catalog.mappingStore!.reverse(type, markers.single),
            );
          }
          truncated = truncated || related.length > 6;
          for (final id in related.take(6)) {
            if (candidates.any((row) => row['id'] == id)) continue;
            try {
              add(
                await get('subjects/$id'),
                'anime',
                expected: id,
                reverse: true,
              );
            } on MetadataFailure {
              incomplete = true;
            }
          }
        }
      }
    } on MetadataFailure {
      incomplete = true;
    }
    final unique = <String, Map<String, Object?>>{};
    var conflictingEvidence = false;
    for (final candidate in candidates) {
      final key = '${candidate['type']}:${candidate['id']}';
      final previous = unique[key];
      if (previous == null) {
        unique[key] = candidate;
        continue;
      }
      if (previous['year'] != null && candidate['year'] != null &&
          previous['year'] != candidate['year']) {
        conflictingEvidence = true;
      }
      // Search language can change labels for the same identity. Preserve
      // earlier matching evidence instead of letting the last query erase it.
      unique[key] = {
        ...candidate,
        ...previous,
        'year': previous['year'] ?? candidate['year'],
        for (final flag in ['exact', 'title_matches', 'directory_title_matches'])
          flag: previous[flag] == true || candidate[flag] == true,
        if (tmdb) 'aliases': <String>{
          ...(previous['aliases'] as List? ?? []).whereType<String>(),
          ...(candidate['aliases'] as List? ?? []).whereType<String>(),
        }.take(12).toList(),
      };
    }
    final reason = queryIncomplete
        ? 'query_incomplete'
        : incomplete
        ? 'request_failed'
        : invalidResponse
        ? 'invalid_response'
        : detailBudgetExhausted
        ? 'detail_budget_exhausted'
        : conflictingEvidence || searchYearConflict
        ? 'conflicting_title'
        : tmdb && markers.isNotEmpty && types.isEmpty
        ? 'untyped_id'
        : unique.isEmpty
        ? 'no_match'
        : truncated || unique.length != 1
        ? 'ambiguous'
        : unique.values.single['exact'] == true &&
              (!filenameFallback || unique.values.single['directory_title_matches'] == true)
        ? 'verify_candidate'
        : 'conflicting_title';
    return (reason: reason, choices: unique.values.toList());
  }

  Future<bool> _invalidateStandaloneInventory(DatabaseExecutor tx, String work) async {
    final rows = await tx.query('scan_bindings', where: 'work_id=?', whereArgs: [work]);
    final identity = rows.where((r) => r['provider'] == 'tmdb' && r['layer'] == 'work').singleOrNull;
    final saved = identity == null ? null : adopted(identity)?['special_inventory'];
    if (saved is! List) return false;
    final inventory = await _workFiles(tx, work);
    final current = _specialInventory(inventory.files);
    if (jsonEncode(current) == jsonEncode(saved)) return false;
    final protection = (await tx.query('library_work_protection', where: 'work_id=?', whereArgs: [work])).single;
    const automatic = {'verified_standalone_special', 'verified_bangumi'};
    if (protection['identity_locked'] == 1 || protection['legacy_lock'] == 1 ||
        rows.any((r) => r['state'] == 'skipped' || adopted(r) != null &&
            (!automatic.contains(r['reason']) || adopted(r)?['by'] != r['reason']))) return true;
    for (final row in rows) {
      if (adopted(row) != null) await _saveDecision(tx, row, null);
      await tx.update('scan_bindings', {
        'reason': row['layer'] == 'work' ? 'unsearched' : 'special_inventory_changed',
        'candidates': '[]',
      }, where: 'id=?', whereArgs: [row['id']]);
    }
    for (final scope in (adopted(identity!)?['special_groups'] as List? ?? [])) {
      await tx.delete('scan_file_groups', where: 'work_id=? AND scope=?', whereArgs: [work, scope]);
    }
    return true;
  }

  static List<Map<String, Object?>> _specialInventory(List<Map<String, Object?>> files) => [
    for (final file in files.where((f) => f['category'] == 'main'))
      {'id': file['id'], 'path': file['relative_path'], 'size': file['size'],
        'content_state': file['content_state']},
  ];

  Future<bool> _invalidateDiscInventory(DatabaseExecutor tx, String work) async {
    final rows = await tx.query('scan_bindings', where: 'work_id=?', whereArgs: [work]);
    if (rows.any((r) => r['reason'] == 'disc_inventory_changed' && r['state'] == 'pending')) return true;
    final range = rows.where((r) => r['provider'] == 'tmdb' && r['layer'] == 'range' &&
        adopted(r)?['disc_inventory'] is List).singleOrNull;
    if (range == null) return false;
    final inventory = await _workFiles(tx, work);
    final current = [for (final f in inventory.files.where((f) => f['category'] == 'main'))
      {'id': f['id'], 'path': f['relative_path'], 'number': f['episode']}];
    List<String> signature(List values) => values.map(jsonEncode).toList()..sort();
    if (listEquals(signature(current), signature(adopted(range)!['disc_inventory'] as List))) return false;
    final protection = (await tx.query('library_work_protection', where: 'work_id=?', whereArgs: [work])).single;
    const automatic = {'verified_tv_chapters', 'verified_tv_mapping', 'verified_numbering'};
    if (protection['identity_locked'] == 1 || protection['legacy_lock'] == 1 ||
        rows.any((r) => r['state'] == 'skipped' || adopted(r) != null &&
            (!automatic.contains(r['reason']) || adopted(r)?['by'] != r['reason']))) {
      return true;
    }
    for (final row in rows.where((r) => r['layer'] != 'work')) {
      await tx.update('scan_bindings', {
        'previous': row['adopted'] ?? row['previous'], 'adopted': null,
        'state': 'pending', 'reason': 'disc_inventory_changed', 'candidates': '[]',
        'revision': (row['revision'] as int) + 1,
      }, where: 'id=?', whereArgs: [row['id']]);
    }
    return true;
  }

  /// A corrected folder identity depends on the complete filename inventory.
  /// Revoke automatic evidence before child bindings can inherit it on rescan.
  Future<bool> _invalidateCorrectedInventory(DatabaseExecutor tx, String work) async {
    final rows = await tx.query('scan_bindings', where: 'work_id=?', whereArgs: [work]);
    if (rows.any((r) => r['layer'] == 'work' && r['state'] == 'pending' &&
        r['reason'] == 'corrected_inventory_changed')) {
      return true;
    }
    final identities = rows.where((r) => r['layer'] == 'work').toList();
    if (!identities.any((r) => adopted(r)?['directory_title_corrected'] == true)) return false;
    final protection = (await tx.query('library_work_protection',
        where: 'work_id=?', whereArgs: [work])).single;
    const automatic = {'verified_tv_chapters', 'verified_tv_mapping', 'verified_numbering'};
    if (protection['identity_locked'] == 1 || protection['legacy_lock'] == 1 ||
        rows.any((r) => r['state'] == 'skipped' || adopted(r) != null &&
            (!automatic.contains(r['reason']) || adopted(r)?['by'] != r['reason']))) {
      // Do not re-parent protected records or attach newly mixed files to them.
      return true;
    }
    final tv = identities.where((r) => r['provider'] == 'tmdb').singleOrNull;
    final identity = tv == null ? null : adopted(tv);
    final ranges = rows.where((r) => r['provider'] == 'tmdb' && r['layer'] == 'range' &&
        r['state'] == 'confirmed').toList();
    final range = ranges.singleOrNull;
    final selection = range == null ? null : adopted(range);
    final inventory = await _workFiles(tx, work);
    final files = inventory.files.where((f) => f['category'] == 'main').toList();
    final title = files.isEmpty ? '' : PersonalFilenameParser.extractAnimeSearchKeyword(files.first['name'] as String);
    final local = await _tvLocal(tx, work, p.posix.basename(inventory.folder), title,
        Catalog.year(p.posix.basename(inventory.folder)));
    final aliases = [identity?['title'], ...(identity?['aliases'] as List? ?? [])].whereType<String>();
    final valid = identity != null && selection != null && local != null &&
        aliases.any((a) => PersonalMetadataScraper.exactTitle(a, title)) &&
        local.directory == range!['scope'] &&
        (local.season == null || local.season == selection['season']) &&
        local.files.length == (selection['last'] as int) - (selection['first'] as int) + 1 &&
        local.files.every((f) => f.number + (selection['offset'] as int) >= (selection['first'] as int) &&
            f.number + (selection['offset'] as int) <= (selection['last'] as int));
    if (valid) return false;
    for (final row in rows) {
      if (adopted(row) != null) await _saveDecision(tx, row, null);
      await tx.update('scan_bindings', {'reason': 'corrected_inventory_changed',
        'candidates': '[]', 'revision': (row['revision'] as int) + 1},
        where: 'id=?', whereArgs: [row['id']]);
    }
    return true;
  }

  Future<bool> _invalidateChangedPart(DatabaseExecutor tx, String work) async {
    final rows = await tx.query('scan_bindings', where: 'work_id=?', whereArgs: [work]);
    // Keep revoked automatic scopes pending until an explicit new decision.
    if (rows.any((r) => r['layer'] == 'range' && r['state'] == 'pending' &&
        r['reason'] == 'part_inventory_changed')) {
      return true;
    }
    final tv = rows.where((r) => r['provider'] == 'tmdb' && r['layer'] == 'work').singleOrNull;
    if (tv == null || adopted(tv)?['verified_part_season'] == null) return false;
    final ranges = rows.where((r) => r['layer'] == 'range').toList();
    final range = ranges.where((r) => r['provider'] == 'tmdb' &&
        (adopted(r)?['offset'] as int? ?? 0) < 0).singleOrNull;
    if (range == null) return false;
    final selection = adopted(range)!;
    final first = (selection['first'] as int) - (selection['offset'] as int);
    final last = (selection['last'] as int) - (selection['offset'] as int);
    final inventory = await _workFiles(tx, work);
    final files = inventory.files.where((f) => f['category'] == 'main').toList();
    final numbers = files.map((f) => f['episode']).toSet();
    final valid = files.length == last - first + 1 && numbers.length == files.length &&
        files.every((f) => _singleRegularFile(f) &&
            _explicitFileSeason(f['name'] as String) == null &&
            !RegExp(r'\d\s*[&+]\s*\d').hasMatch(f['name'] as String) &&
            (f['episode'] as int) >= first && (f['episode'] as int) <= last &&
            (f['file_group'] as String? ?? _directoryScope(f['relative_path'] as String, inventory.folder)) == range['scope']);
    if (valid) return false;
    final affected = ranges.where((r) => r['scope'] == range['scope'] &&
        ['verified_tmdb', 'verified_tv_chapters'].contains(adopted(r)?['by'])).toList();
    for (final parent in affected) {
      for (final child in rows.where((r) => r['layer'] == 'episode' &&
          r['provider'] == parent['provider'] && r['parent'] == _token(parent) &&
          adopted(r)?['by'] == 'verified_numbering')) {
        await _saveDecision(tx, child, null);
        await tx.update('scan_bindings', {'reason': 'part_inventory_changed'}, where: 'id=?', whereArgs: [child['id']]);
      }
      await _saveDecision(tx, parent, null);
      await tx.update('scan_bindings', {'reason': 'part_inventory_changed'}, where: 'id=?', whereArgs: [parent['id']]);
    }
    return affected.isNotEmpty;
  }

  Future<bool> _refreshPartAfterFill(TaskLease lease, String raw) async {
    if (!catalog.automaticRecognition) return false;
    final work = lease.workId!;
    final tv = await _row(tasks.db, _id(work, 'tmdb', 'work', ''));
    final bg = await _row(tasks.db, _id(work, 'bangumi', 'work', ''));
    final choice = tv == null ? null : adopted(tv);
    final subject = bg == null ? null : adopted(bg);
    if (choice?['verified_part_season'] == null || subject == null ||
        tv?['reason'] != 'verified_tmdb' || bg?['reason'] != 'verified_bangumi') {
      return false;
    }
    final inventory = await _workFiles(tasks.db, work);
    final scopes = _tmdbRanges(inventory, choice!, raw);
    if (scopes.length != 1) return false;
    final scope = scopes.keys.single;
    final range = await _row(tasks.db, _id(work, 'tmdb', 'range', scope));
    final bgRange = await _row(tasks.db, _id(work, 'bangumi', 'range', scope));
    final selection = range == null ? null : adopted(range);
    if (selection == null || range?['reason'] != 'verified_tmdb' ||
        selection['by'] != 'verified_tmdb' || selection['offset'] != 0 ||
        bgRange?['state'] != 'pending') {
      return false;
    }
    final files = inventory.files.where((f) => f['category'] == 'main').toList();
    final count = scopes.values.single['count'] as int;
    if (files.length != count || files.any((f) => !_singleRegularFile(f) ||
        _explicitFileSeason(f['name'] as String) != null ||
        RegExp(r'\d\s*[&+]\s*\d').hasMatch(f['name'] as String) ||
        (f['episode'] as int) <= count ||
        (f['file_group'] as String? ?? _directoryScope(f['relative_path'] as String, inventory.folder)) != scope)) {
      return false;
    }
    final before = await tasks.db.query('scan_bindings', where: 'work_id=?', whereArgs: [work], orderBy: 'id');
    if (before.any((r) => r['layer'] == 'episode' && r['state'] != 'pending')) return false;
    final protection = (await tasks.db.query('library_work_protection', where: 'work_id=?', whereArgs: [work])).single;
    if (protection['identity_locked'] == 1 || protection['legacy_lock'] == 1) return false;
    final evidence = await _verifiedPartSeason(lease, raw, Catalog.year(raw), choice, subject);
    if (evidence == null || evidence.season != selection['season']) return false;
    final numbers = files.map((f) => f['episode']).toSet();
    if (numbers.length != count || !evidence.chapters.every((c) => numbers.contains(c['sort']))) return false;
    await tasks.commit(lease, (tx) async {
      final latest = await _workFiles(tx, work);
      final current = await tx.query('scan_bindings', where: 'work_id=?', whereArgs: [work], orderBy: 'id');
      final guard = (await tx.query('library_work_protection', where: 'work_id=?', whereArgs: [work])).single;
      if (latest.folder != inventory.folder || jsonEncode(latest.files) != jsonEncode(inventory.files) ||
          jsonEncode(current) != jsonEncode(before) || jsonEncode(guard) != jsonEncode(protection)) {
        return {'changed': false};
      }
      await _saveDecision(tx, range!, {...selection,
        'offset': 1 - (evidence.chapters.first['sort'] as int)},
        reason: 'verified_tmdb', by: 'verified_tmdb');
      await _syncChildren(tx, work, 'tmdb');
      await _adoptPartOffset(tx, work, raw, choice, evidence.chapters, latest);
      return {'changed': true};
    });
    return true;
  }

  /// Only known automatic provenance is eligible; unknown historical records
  /// are protected just like manual decisions. This is a read-only preflight.
  Future<List<Map<String, Object?>>?> _automaticConflict(
    DatabaseExecutor tx, String work,
  ) async {
    final protection = (await tx.query('library_work_protection',
        where: 'work_id=?', whereArgs: [work])).singleOrNull;
    final legacy = (await tx.query('works', where: 'id=?', whereArgs: [work])).singleOrNull;
    if (protection == null || protection['identity_locked'] == 1 ||
        protection['legacy_lock'] == 1 || legacy == null || legacy['hidden'] == 1 ||
        legacy['tmdb_type'] != null || legacy['bangumi_id'] != null) {
      return null;
    }
    final rows = await tx.query('scan_bindings', where: 'work_id=?',
        whereArgs: [work], orderBy: 'id');
    const automatic = {'verified_tmdb', 'verified_bangumi',
      'verified_tv_chapters', 'verified_tv_mapping', 'verified_numbering'};
    Map? previous(Map row) => row['previous'] == null
        ? null : jsonDecode(row['previous'] as String) as Map;
    final identities = rows.where((r) => r['layer'] == 'work').toList();
    final ordinaryIncomplete = identities.length == 2 &&
        identities.every((r) => r['state'] == 'confirmed') &&
        rows.any((r) => r['provider'] == 'bangumi' && r['layer'] == 'range' && r['state'] == 'pending') &&
        !rows.any((r) => r['provider'] == 'bangumi' && r['layer'] == 'range' && r['state'] == 'confirmed');
    // Revoked evidence is only a preflight hint. Never directly reinstate it.
    final restoring = identities.length == 2 && identities.every((r) =>
        r['state'] == 'pending' && r['reason'] == 'corrected_inventory_changed' &&
        previous(r)?['directory_title_corrected'] == true &&
        automatic.contains(previous(r)?['by']));
    for (final row in rows) {
      final choice = adopted(row);
      if (row['state'] == 'skipped' ||
          choice != null && (!automatic.contains(row['reason']) || choice['by'] != row['reason']) ||
          row['previous'] != null && choice == null && !restoring &&
              !(row['reason'] == 'disc_inventory_changed' && automatic.contains(previous(row)?['by'])) ||
          restoring && (choice != null ||
              row['previous'] != null && !automatic.contains(previous(row)?['by']))) {
        return null;
      }
    }
    if (identities.length != 2 || !restoring && !identities.any((r) => r['state'] == 'confirmed')) {
      return null;
    }
    final local = await _workFiles(tx, work);
    final raw = p.posix.basename(local.folder);
    if (_isMovieDirectoryWithoutId(raw) &&
        identities.every((row) => row['state'] == 'confirmed') &&
        identities.any((row) => adopted(row)?['type'] == 'tv') &&
        rows.every((row) => row['layer'] == 'work' || row['state'] == 'pending')) {
      return rows;
    }
    if ((!ordinaryIncomplete && Catalog.year(raw) == null) || WorkSeason.conflictingYears({'title': raw}) ||
        (!ordinaryIncomplete && PersonalFilenameParser.tmdbIds(raw).isNotEmpty) ||
        RegExp(r'\{bangumi-\d+\}', caseSensitive: false).hasMatch(raw)) {
      return null;
    }
    final titles = local.files.where((f) => f['category'] == 'main' && f['episode'] != 0)
        .map((f) => PersonalFilenameParser.extractAnimeSearchKeyword(f['name'] as String,
            episodeNumber: f['episode'] as int?)).toList();
    final title = titles.firstOrNull;
    if (title == null || title.isEmpty ||
        !titles.every((t) => PersonalMetadataScraper.exactTitle(t, title))) {
      return null;
    }
    final files = await _tvLocal(tx, work, raw, title, Catalog.year(raw));
    if (files == null) return null;
    if (ordinaryIncomplete) {
      final identity = adopted(identities.singleWhere((r) => r['provider'] == 'tmdb'))!;
      final aliases = [identity['title'], ...(identity['aliases'] as List? ?? [])].whereType<String>();
      if (aliases.any((a) => _sameLocalTitle(a, title))) return rows;
    }
    if (restoring) {
      final identity = previous(identities.singleWhere((r) => r['provider'] == 'tmdb'))!;
      final range = rows.where((r) => r['provider'] == 'tmdb' && r['layer'] == 'range' &&
          previous(r) != null).singleOrNull;
      final selection = range == null ? null : previous(range);
      final aliases = [identity['title'], ...(identity['aliases'] as List? ?? [])].whereType<String>();
      if (selection == null ||
          !aliases.any((a) => PersonalMetadataScraper.exactTitle(a, title)) ||
          files.directory != range!['scope'] ||
          (files.season != null && files.season != selection['season']) ||
          files.files.length != (selection['last'] as int) - (selection['first'] as int) + 1 ||
          !files.files.every((f) => f.number + (selection['offset'] as int) >= (selection['first'] as int) &&
              f.number + (selection['offset'] as int) <= (selection['last'] as int))) {
        return null;
      }
      return rows;
    }
    final folderTitle = Catalog.cleanTitle(raw);
    final linkedTv = adopted(identities.singleWhere((r) => r['provider'] == 'tmdb'));
    final linkedBg = adopted(identities.singleWhere((r) => r['provider'] == 'bangumi'));
    if (linkedTv?['directory_subject'] != null &&
        linkedTv?['directory_subject'] == linkedBg?['id'] &&
        linkedBg?['directory_title_matches'] == true &&
        (linkedTv?['aliases'] as List? ?? []).whereType<String>().any(
            (alias) => _sameLocalTitle(alias, title))) {
      return null;
    }
    final conflict = identities.any((r) {
      final choice = adopted(r);
      if (choice == null) return false;
      final names = [choice['title'], ...(choice['aliases'] as List? ?? [])].whereType<String>();
      return names.any((n) => PersonalMetadataScraper.exactTitle(n, folderTitle)) &&
          !names.any((n) => PersonalMetadataScraper.exactTitle(n, title));
    });
    return conflict ? rows : null;
  }

  static List<String> _bangumiPremiereWindow(DateTime premiere) {
    String day(DateTime value) => value.toIso8601String().split('T').first;
    return [
      '>=${day(premiere.subtract(const Duration(days: 3)))}',
      '<${day(premiere.add(const Duration(days: 4)))}',
    ];
  }

  Future<({String reason, List<Map<String, Object?>> choices})?> _narrowBangumiPremiere(
    TaskLease lease, String raw, String title, int? year,
    List<Map<String, Object?>> choices, {
    String? filmFile,
  }) async {
    final candidate = choices.singleOrNull;
    if (candidate?['exact'] != true || candidate?['directory_title_matches'] != true ||
        candidate?['id'] is! int) return null;
    final id = candidate!['id'] as int;
    try {
      final subject = await _get(metadataResource('bangumi', 'subjects/$id'), lease);
      final premiere = DateTime.tryParse('${subject['date']}');
      final aliases = PersonalMetadataScraper.officialTitles(subject);
      final original = subject['name'];
      if (subject['id'] != id || subject['type'] != 2 || premiere == null ||
          (year != null && premiere.year != year) ||
          !aliases.any((name) => _sameLocalTitle(name, title))) {
        return null;
      }
      if (filmFile != null &&
          (!const {'剧场版', '劇場版', '电影', '映画', 'Movie'}.contains(subject['platform']) ||
              original is! String ||
              !_movieFileTitles(filmFile, premiere.year).any(
                  (names) => names.length == 1 && names.single == _movieReleaseTitle(original)))) {
        return null;
      }
      final result = await _search(lease, 'bangumi', raw, title, filmFile == null ? year : premiere.year,
        const {}, const {}, [filmFile == null ? title : original as String],
        filenameFallback: true, firstBangumiPage: filmFile == null, liveBangumiOnly: filmFile != null,
        bangumiAirDates: _bangumiPremiereWindow(premiere));
      if (result.reason != 'verify_candidate' || result.choices.single['id'] != id) return null;
      final images = subject['images'];
      return (reason: result.reason, choices: [{
        ...candidate, ...result.choices.single,
        'title': _title(subject),
        'summary': subject['summary'],
        if (filmFile != null) ...{
          'movie': true, 'original_title': original, 'aliases': aliases.toList(),
        },
        if (images is Map && MetadataServers.imageResource('${images['large']}')?.$1 == 3)
          'poster': images['large'],
      }]);
    } on MetadataFailure {
      return null;
    }
  }

  Future<void> run(TaskLease lease) async {
    final workId = lease.workId!;
    if (manualRetry && catalog.automaticRecognition) {
      final protection = (await tasks.db.query('library_work_protection',
          where: 'work_id=?', whereArgs: [workId])).singleOrNull;
      if (protection?['identity_locked'] == 1 || protection?['legacy_lock'] == 1) {
        await tasks.commit(lease, (_) async => {'sources': 0});
        return;
      }
    }
    final rawLocation = await tasks.db.query(
      'library_locations',
      where: "kind='work' AND entity_id=?",
      whereArgs: [workId],
    );
    if (rawLocation.isEmpty) throw const TaskStopped();
    final raw = p.posix.basename(rawLocation.single['relative_path'] as String);
    if (await _refreshPartAfterFill(lease, raw)) return;
    final rawTitle = PersonalFilenameParser.withoutTmdbMarkers(
      raw,
    ).replaceAll(RegExp(r'\{bangumi-\d+\}', caseSensitive: false), '').trim();
    final clean = Catalog.cleanTitle(rawTitle);
    final title = raw == '@unclassified'
        ? ''
        : PersonalFilenameParser.extractAnimeSearchKeyword('$clean.mkv');
    final markers = PersonalFilenameParser.tmdbIds(raw);
    final types = PersonalFilenameParser.tmdbTypes(raw);
    final year = Catalog.year(raw);
    var local = await _workFiles(tasks.db, workId);
    final splitRelease = local.files.any((file) => file['category'] == 'main') &&
        local.files.where((file) => file['category'] == 'main').every((file) =>
            p.posix.dirname(file['relative_path'] as String) ==
            p.posix.dirname(local.folder));
    if (catalog.automaticRecognition &&
        await _reclassifyNumberedSupplements(lease, local)) {
      await catalog.reload();
      local = await _workFiles(tasks.db, workId);
    }
    if (catalog.automaticRecognition && markers.isEmpty && types.isEmpty &&
        !raw.contains(RegExp(r'\{bangumi-\d+\}', caseSensitive: false)) &&
        !WorkSeason.conflictingYears({'title': raw}) &&
        local.files.where((file) => file['category'] == 'main').take(9).length == 9) {
      final identities = await tasks.db.query('scan_bindings',
          where:"work_id=? AND layer='work'", whereArgs:[workId]);
      final tv = identities.where((row) => row['provider'] == 'tmdb').singleOrNull;
      final bg = identities.where((row) => row['provider'] == 'bangumi').singleOrNull;
      if (tv != null && bg != null && tv['state'] == 'pending' &&
          (await _recognizeSplitSubjectSeason(lease, raw, title, year, local, tv, bg) ||
           await _recognizeCombinedBroadcast(lease, raw, title, year, local, tv, bg))) return;
    }
    if (catalog.automaticRecognition && await _splitRelatedFilms(lease, local)) {
      await catalog.reload();
      local = await _workFiles(tasks.db, workId);
    }
    if (catalog.automaticRecognition &&
        await _repairVerifiedTvRanges(lease, local)) return;
    final hints = title.isEmpty
        ? <String>[]
        : PersonalMetadataScraper.titleHints(
            title.replaceFirst(RegExp(r'^(?:电影|劇場版|剧场版)\s+'), ''),
            markers.length <= 1
                ? local.files
                      .where((file) => file['category'] == 'main')
                      .map((file) => file['name'] as String)
                      .take(6)
                      .toList()
                : const [],
          );
    final recheck = catalog.automaticRecognition
        ? await _automaticConflict(tasks.db, workId) : null;
    if (recheck != null && await _rejectTvRecutOfOva(lease, local, recheck)) {
      await catalog.reload();
      return;
    }
    final retryAutomatic = catalog.automaticRecognition &&
        await _pendingAutomaticRetry(tasks.db, workId);
    final movieDirectory = catalog.automaticRecognition && _isMovieDirectoryWithoutId(raw);
    final pending = <String, Map<String, Object?>>{};
    for (final provider in providers) {
      final row = await _row(tasks.db, _id(workId, provider, 'work', ''));
      if (row != null && (recheck != null || retryAutomatic ||
           row['state'] == 'pending' && (movieDirectory || canRetryWorkQuery(row) ||
               manualRetry && canSupplementWorkQuery(row)))) {
        pending[provider] = row;
      }
    }
    final pendingRelease = pending['tmdb'];
    if (catalog.automaticRecognition && markers.isEmpty && types.isEmpty &&
        pendingRelease != null && pending['bangumi'] != null &&
        !WorkSeason.conflictingYears({'title': raw}) &&
        await _verifyStoredMoviePair(lease, title, year, local,
            pendingRelease, pending['bangumi']!)) return;
    if (catalog.automaticRecognition && markers.isEmpty && types.isEmpty &&
        !RegExp(r'\{bangumi-\d+\}', caseSensitive: false).hasMatch(raw) &&
        !WorkSeason.conflictingYears({'title': raw}) &&
        pendingRelease != null &&
        await _recognizeStandaloneVideo(lease, raw, title, year, local, pendingRelease)) {
      return;
    }
    if (movieDirectory) {
      if (await _recognizeMarkedMovie(lease, raw, title, year, local, pending, recheck)) return;
    }
    final savedTv = pending['tmdb'];
    final savedTvChoice = savedTv == null ? null : adopted(savedTv);
    final savedBg = pending['bangumi'];
    final revisitSeason = markers.isEmpty && !raw.contains(RegExp(r'\{bangumi-\d+\}', caseSensitive: false)) &&
        _canRevisitSeason(savedTv, savedBg);
    final recoveringTv = retryAutomatic &&
        savedTv?['reason'] == 'verified_tmdb' &&
        savedTvChoice?['by'] == 'verified_tmdb' &&
        savedTvChoice?['type'] == 'tv' && savedTvChoice?['exact'] == true &&
        savedBg?['state'] == 'pending';
    final recoveringMovieAlias = recoveringTv &&
        savedBg?['reason'] == 'conflicting_title' &&
        await _verifiedTvDisambiguatesMovieAlias(
          tasks.db, workId, candidates(savedBg!).singleOrNull,
        );
    final recoveredBg = recoveringTv
        ? await _narrowBangumiPremiere(lease, raw, title, year, candidates(savedBg!))
        : null;
    final results = Map.fromEntries(
      await Future.wait([
        for (final provider in pending.keys)
          (revisitSeason
              ? Future.value((
                  reason: provider == 'bangumi' ? 'verify_candidate' : 'conflicting_title',
                  choices: candidates(pending[provider]!),
                ))
              : recoveredBg != null
              ? Future.value(provider == 'bangumi'
                  ? recoveredBg
                  : (reason: 'verify_candidate', choices: [Map<String, Object?>.from(savedTvChoice!)]))
              : _search(
            lease,
            provider,
            raw,
            title,
            year,
            markers,
             movieDirectory && provider == 'tmdb' ? const {'movie'} : types,
            hints,
            filenameFallback: markers.isEmpty,
          )).then((result) => MapEntry(provider, result)),
      ]),
    );
    final films = results['tmdb'];
    final subjects = results['bangumi'];
    if (catalog.automaticRecognition && RegExp(r'\bS0?1\s*[+&~～-]\s*S?0?2\b',
        caseSensitive: false).hasMatch(raw) &&
        pendingRelease?['state'] == 'pending' && pending['bangumi']?['state'] == 'pending' &&
        films != null && subjects != null &&
        await _recognizeSplitSubjectSeason(lease, raw, title, year, local,
          {...pendingRelease!, 'reason': films.reason, 'candidates': jsonEncode(films.choices)},
          {...pending['bangumi']!, 'reason': subjects.reason, 'candidates': jsonEncode(subjects.choices)},
          separateWorks: true)) return;
    final ovaSeries = films?.choices.singleOrNull;
    if (catalog.automaticRecognition && markers.isEmpty && types.isEmpty &&
        !RegExp(r'\{bangumi-\d+\}', caseSensitive: false).hasMatch(raw) &&
        !WorkSeason.conflictingYears({'title': raw}) &&
        pendingRelease != null && films?.reason == 'verify_candidate' &&
        ovaSeries?['type'] == 'tv' &&
        await _recognizeTwoPartOva(lease, raw, title, year, local, pendingRelease, ovaSeries!)) {
      return;
    }
    if (catalog.automaticRecognition && markers.isEmpty && !types.contains('tv') &&
        !WorkSeason.conflictingYears({'title': raw}) &&
        films?.reason == 'ambiguous' && subjects != null &&
        await _recognizeCompetingAnimatedMovies(
          lease, raw, title, year, local, pending, films!.choices,
          subjects.choices.isEmpty && savedBg != null ? candidates(savedBg) : subjects.choices,
        )) {
      return;
    }
    final recoveredMovieAlias = recoveringMovieAlias && recoveredBg != null;
    var narrowedPremiere = recoveredBg != null && !recoveredMovieAlias;
    final incompleteBg = results['bangumi'];
    if (catalog.automaticRecognition && workQueryIncomplete(incompleteBg?.reason) &&
        results['tmdb']?.choices.isNotEmpty == true) {
      final choices = incompleteBg!.choices.isEmpty && savedBg != null
          ? candidates(savedBg) : incompleteBg.choices;
      final narrowed = await _narrowBangumiPremiere(lease, raw, title, year, choices);
      if (narrowed != null) {
        results['bangumi'] = narrowed;
        narrowedPremiere = true;
      }
    }
    final bgIdentity = catalog.automaticRecognition && results.containsKey('tmdb')
        ? await _row(tasks.db, _id(workId, 'bangumi', 'work', '')) : null;
    final bgResult = results['bangumi'];
    if (catalog.automaticRecognition && markers.isEmpty &&
        results['tmdb']?.reason == 'no_match' &&
        !WorkSeason.conflictingYears({'title': raw})) {
      final subject = bgResult?.choices.singleOrNull ??
          (bgIdentity?['reason'] == 'verified_bangumi' ? adopted(bgIdentity!) : null);
      final filename = local.files.where((file) => file['category'] == 'main')
          .singleOrNull?['name'] as String?;
      final release = filename == null ? '' :
          PersonalFilenameParser.extractAnimeSearchKeyword(filename);
      final filmPrefix = RegExp(r'^(?:劇場版|剧场版|电影|映画|Gekijouban\b)\s*',
          caseSensitive: false);
      final filmName = filmPrefix.hasMatch(release)
          ? release.replaceFirst(filmPrefix, '').trim() : '';
      final queries = <String>{
        if (filmName.length >= 4) filmName,
        if (subject?['exact'] == true && subject?['directory_title_matches'] == true)
          ...(subject!['aliases'] as List? ?? []).whereType<String>(),
      }.where((alias) => !hints.contains(alias)).take(3).toList();
      if (queries.isNotEmpty) {
        final alternate = await _search(lease, 'tmdb', raw, title, year, markers,
            filmName.isNotEmpty && !types.contains('tv') ? const {'movie'} : types,
            queries, filenameFallback: true);
        if (alternate.choices.isNotEmpty ||
            workQueryIncomplete(alternate.reason)) results['tmdb'] = alternate;
      }
    }
    final confirmedMovieSubject = bgIdentity?['reason'] == 'verified_bangumi' &&
            adopted(bgIdentity!)?['by'] == 'verified_bangumi'
        ? adopted(bgIdentity)
        : null;
    final movieSubject = confirmedMovieSubject ??
        (bgResult?.reason == 'verify_candidate' ? bgResult?.choices.singleOrNull : null);
    final originalTmdb = results['tmdb'];
    ({String reason, List<Map<String, Object?>> choices})? supplementalMovieResult;
    final mayVerifyMovie = catalog.automaticRecognition && !recoveringTv &&
        !WorkSeason.conflictingYears({'title': raw}) && !types.contains('tv');
    var verifiedMovie = mayVerifyMovie &&
            const {'untyped_id', 'verify_candidate', 'conflicting_title'}.contains(originalTmdb?.reason)
        ? _verifiedMovieCandidate(originalTmdb!.choices, local.files, title, year, movieSubject)
        : null;
    if (mayVerifyMovie && verifiedMovie == null && movieSubject != null &&
        const {'untyped_id', 'verify_candidate', 'conflicting_title'}.contains(originalTmdb?.reason)) {
      verifiedMovie = await _verifyMoviePremiere(
        lease, originalTmdb!.choices, local.files, title, year, movieSubject,
      );
    }
    final movieOption = originalTmdb?.choices.singleOrNull;
    if (mayVerifyMovie && verifiedMovie == null && movieSubject != null &&
        originalTmdb?.reason == 'verify_candidate' && movieOption?['type'] == 'movie' &&
        movieOption?['marker'] != true && movieOption?['year'] == movieSubject['year'] &&
        movieSubject['directory_title_matches'] == true &&
        local.files.where((file) => file['category'] == 'main').length == 1) {
      final names = (movieSubject['aliases'] as List? ?? const []).whereType<String>().map(_movieTitle).toSet();
      final movie = movieOption!;
      final aliases = (movie['aliases'] as List? ?? const []).whereType<String>();
      if (aliases.map(_movieTitle).any((name) => name.length >= 4 && names.contains(name))) {
        try {
          final detail = await _get(metadataResource('tmdb', 'movie/${movie['id']}',
              parameters: {'append_to_response': 'alternative_titles,translations'}), lease);
          if (detail['id'] == movie['id'] && _year(detail) == movie['year']) {
            verifiedMovie = _verifiedMovieCandidate([
              {...movie, 'aliases': {...aliases, ...PersonalMetadataScraper.officialTitles(detail)}.toList()},
            ], local.files, title, year, movieSubject);
          }
        } on MetadataFailure {
          // Keep the existing candidate when supplemental aliases are unavailable.
        }
      }
    }
    if (mayVerifyMovie && markers.isEmpty && movieSubject != null &&
        const {'detail_budget_exhausted', 'no_match'}.contains(originalTmdb?.reason)) {
      // Recheck a supported candidate under a narrower query. The partial
      // response from the broad search cannot itself establish uniqueness.
      final original = (movieSubject['aliases'] as List? ?? const []).whereType<String>().firstOrNull;
      final candidatesWithOriginal = originalTmdb!.choices.where((choice) =>
          choice['type'] != 'movie' ||
          original != null && choice['original_title'] is String &&
              _movieTitle(choice['original_title'] as String) == _movieTitle(original)).toList();
      final proposed = _verifiedMovieCandidate(candidatesWithOriginal, local.files,
          title, year, movieSubject);
      var releaseYear = proposed?['year'] as int?;
      if (originalTmdb.reason == 'no_match' && movieSubject['directory_title_matches'] == true) {
        final main = local.files.where((file) => file['category'] == 'main').singleOrNull;
        if (main != null && (movieDirectory || RegExp(
            r'\b(?:movie|film|gekijouban)\b|劇場版|剧场版|映画', caseSensitive: false,
        ).hasMatch(main['name'] as String))) {
          releaseYear = movieSubject['year'] as int?;
        }
      }
      if (original != null && releaseYear != null) {
        final narrow = await _search(lease, 'tmdb', raw, title, releaseYear, const {},
            const {'movie'}, [original], filenameFallback: true, movieReleaseYear: releaseYear);
        if (const {'verify_candidate', 'conflicting_title'}.contains(narrow.reason)) {
          final candidate = _verifiedMovieCandidate(narrow.choices, local.files,
              title, year, movieSubject);
          if (proposed == null || candidate?['id'] == proposed['id']) verifiedMovie = candidate;
        }
        if (originalTmdb.reason == 'no_match' && verifiedMovie == null &&
            (workQueryIncomplete(narrow.reason) || narrow.choices.isNotEmpty)) {
          supplementalMovieResult = (
            reason: workQueryIncomplete(narrow.reason) ? narrow.reason : 'conflicting_title',
            choices: narrow.choices,
          );
        }
      }
    }
    if (verifiedMovie != null) {
      results['tmdb'] = (reason: 'verify_candidate', choices: [verifiedMovie]);
    }
    // An untyped marker may resolve to a TV and an unrelated movie with the
    // same numeric ID. Use the existing inventory/year filter before paired
    // chapter verification, never the marker alone as identity proof.
    _TvEvidence? boundaryEvidence;
    _ContinuousTvEvidence? continuousEvidence;
    var verifiedSameTitleSeries = false;
    final untyped = results['tmdb'];
    if (catalog.automaticRecognition && untyped?.reason == 'untyped_id') {
      final selected = _automaticTmdb(untyped!.choices, local.files, year, hints,
          explicitMovie: false, allowUnverifiedSeasonYear: false);
      if (selected?['type'] == 'tv' && selected?['exact'] == true) {
        results['tmdb'] = (reason: 'verify_candidate', choices: [selected!]);
      }
    }
    // Bangumi may name a season separately while TMDB keeps it as a series
    // alias. Bridge only the verified folder subject's original name, and
    // still require the local filenames and the subsequent chapter proof.
    final savedSubject = bgResult == null && bgIdentity?['reason'] == 'verified_bangumi'
        ? adopted(bgIdentity!) : null;
    final pendingSeries = results['tmdb'];
    if (catalog.automaticRecognition && !movieDirectory && markers.isEmpty &&
        pendingSeries?.reason == 'ambiguous' && savedSubject?['by'] == 'verified_bangumi' &&
        savedSubject?['exact'] == true && savedSubject?['directory_title_matches'] == true &&
        !WorkSeason.conflictingYears({'title': raw})) {
      final subject = savedSubject!;
      final premiere = subject['year'];
      final original = (subject['aliases'] as List? ?? const []).whereType<String>().firstOrNull;
      final main = local.files.where((file) => file['category'] == 'main').toList();
      final numbers = main.map((file) => file['episode']).toSet();
      if (premiere is int && (year == null || year == premiere) && original != null &&
          main.length >= 3 && main.length <= 100 && numbers.length == main.length &&
          main.every((file) => _singleRegularFile(file) && file['file_group'] == null) &&
          List.generate(main.length, (index) => index + 1).every(numbers.contains)) {
        bool matches(Map choice) => choice['type'] == 'tv' && choice['year'] == premiere &&
            (choice['aliases'] as List? ?? const []).whereType<String>().any(
                (alias) => PersonalMetadataScraper.exactTitle(alias, original));
        final saved = pendingSeries!.choices.where(matches).singleOrNull;
        if (saved != null) {
          final narrowed = await _search(lease, 'tmdb', raw, title, premiere, const {},
              const {'tv'}, [original], filenameFallback: true, tvPremiereYear: premiere);
          final candidate = narrowed.choices.singleOrNull;
          if (candidate != null && candidate['id'] == saved['id'] && matches(candidate) &&
              const {'verify_candidate', 'conflicting_title'}.contains(narrowed.reason)) {
            final aliases = {
              ...(candidate['aliases'] as List? ?? const []).whereType<String>(),
              ...(subject['aliases'] as List? ?? const []).whereType<String>(),
            }.toList();
            final choice = {...candidate, 'aliases': aliases};
            try {
              final evidence = await _fetchTvEvidence(
                  lease, raw, title, premiere, choice, subject, refreshAliases: true);
              if (evidence != null && evidence.first == 1 && evidence.last == main.length &&
                  evidence.season == 1 && (evidence.tv.indexed.every(
                      (episode) => _chapterAgreement(episode.$2, evidence.bangumi[episode.$1])) ||
                      _sameSeasonTitlesWithDateDifferences(evidence.tv, evidence.bangumi))) {
                boundaryEvidence = evidence;
                verifiedSameTitleSeries = true;
                results['tmdb'] = (reason: 'verify_candidate', choices: [choice]);
                results['bangumi'] = (reason: 'verify_candidate', choices: [subject]);
              } else {
                continuousEvidence = await _fetchContinuousTv(
                  lease, raw, title, premiere, choice, subject, aliases,
                );
              }
            } on MetadataFailure {
              // A narrower search is not enough without chapter proof.
            }
          }
        }
      }
    }
    final reuseBangumi = catalog.automaticRecognition && !movieDirectory &&
        pendingSeries?.reason == 'conflicting_title' &&
        pendingSeries?.choices.singleOrNull?['type'] == 'tv' &&
        pendingSeries?.choices.singleOrNull?['exact'] == true &&
        savedSubject?['by'] == 'verified_bangumi' && savedSubject?['exact'] == true &&
        savedSubject?['directory_title_matches'] == true && savedSubject?['year'] is int;
    if (reuseBangumi) {
      results['bangumi'] = (reason: 'verify_candidate', choices: [savedSubject!]);
    }
    final subjectResult = results['bangumi'];
    final folderSubject = subjectResult?.choices.singleOrNull;
    if (catalog.automaticRecognition && year != null &&
        subjectResult?.reason == 'verify_candidate' &&
        folderSubject?['directory_title_matches'] == true && folderSubject?['year'] == year &&
        ['untyped_id', 'conflicting_title', 'no_match'].contains(results['tmdb']?.reason)) {
      final main = local.files.where((f) => f['category'] == 'main').toList();
      final original = (folderSubject!['aliases'] as List? ?? []).whereType<String>().firstOrNull;
      var found = results['tmdb']!;
      if (found.reason == 'no_match' && original != null && main.length == 1) {
        found = await _search(lease, 'tmdb', raw, title, year, markers, types, [original], filenameFallback: true);
      }
      final movie = ['untyped_id', 'conflicting_title', 'verify_candidate'].contains(found.reason)
          ? found.choices.where((c) => c['type'] == 'movie' &&
          c['year'] == year && original != null &&
          (c['aliases'] as List? ?? []).whereType<String>().any(
              (a) => _movieTitle(a) == _movieTitle(original))).singleOrNull : null;
      if (movie != null && main.length == 1 &&
          _movieReleaseName(main.single['name'] as String, movie)) {
        results['tmdb'] = (reason: 'verify_candidate', choices: [{
          ...movie, 'exact': true, 'title_matches': true,
          'directory_subject': folderSubject['id'], 'verified_movie_alias': true,
        }]);
      }
    }
    if (catalog.automaticRecognition && year != null &&
        subjectResult?.reason == 'verify_candidate' && folderSubject?['exact'] == true &&
        folderSubject?['directory_title_matches'] == true &&
        ['untyped_id', 'conflicting_title'].contains(results['tmdb']?.reason)) {
      final original = (folderSubject!['aliases'] as List? ?? []).whereType<String>().firstOrNull;
      final candidate = results['tmdb']!.choices.where((c) => c['type'] == 'tv' &&
          c['title_matches'] == true && original != null &&
          (c['aliases'] as List? ?? []).whereType<String>().any(
              (a) => PersonalMetadataScraper.exactTitle(a, original))).singleOrNull;
      if (candidate != null) {
        try {
          boundaryEvidence = await _fetchTvEvidence(lease, raw, title, year,
              candidate, folderSubject, verifyDiscOrder: true);
          if (boundaryEvidence != null) {
            results['tmdb'] = (reason: 'verify_candidate', choices: [
              {...candidate, 'exact': true, 'directory_subject': folderSubject['id']},
            ]);
          }
        } on MetadataFailure {
          // A cross-year premiere is not established by an unavailable endpoint.
        }
      }
    }
    if (boundaryEvidence == null && catalog.automaticRecognition && markers.isEmpty &&
        subjectResult?.reason == 'verify_candidate' &&
        folderSubject?['directory_title_matches'] == true &&
        ['no_match', 'conflicting_title'].contains(results['tmdb']?.reason)) {
      final originalName = (folderSubject!['aliases'] as List? ?? []).whereType<String>().firstOrNull;
      if (originalName != null && originalName.isNotEmpty) {
        var found = results['tmdb']!;
        if (found.reason == 'no_match') {
          final stem = originalName.replaceFirst(RegExp(r'\s*第\s*[0-9０-９]+\s*[幕期季]\s*$'), '').trim();
          found = await _search(lease, 'tmdb', raw, title, year, markers, types,
              [originalName, if (stem.length >= 4 && stem != originalName) stem],
              filenameFallback: true);
        }
        final candidate = found.choices.singleOrNull;
        if (['verify_candidate', 'conflicting_title'].contains(found.reason) &&
            candidate?['type'] == 'tv' && candidate?['exact'] == true) {
          final aliases = (candidate!['aliases'] as List? ?? []).whereType<String>();
          final sameOriginal = aliases.any(
              (alias) => PersonalMetadataScraper.exactTitle(alias, originalName));
          if (!sameOriginal || revisitSeason || reuseBangumi) {
            // A series can omit a season's subtitle from its aliases.
            // Require the complete original chapter sequence in that case.
            try {
              final evidence = await _fetchTvEvidence(
                  lease, raw, title, year, candidate, folderSubject,
                  allowDualNumbers: revisitSeason,
                  requireSubjectFilenames: reuseBangumi);
              if (evidence != null && (evidence.tv.indexed.every(
                  (chapter) => _chapterAgreement(chapter.$2, evidence.bangumi[chapter.$1])) ||
                  _dualSeasonChapterAgreement(evidence)) &&
                  (!reuseBangumi || evidence.local.files.length == evidence.tv.length)) {
                boundaryEvidence = evidence;
              }
            } on MetadataFailure {
              // Preserve the original candidates when season verification fails.
            }
          }
          if (boundaryEvidence != null || !reuseBangumi && !revisitSeason && sameOriginal &&
              await _tvLocal(tasks.db, workId, raw, title, year, aliases: aliases) != null) {
            results['tmdb'] = (reason: 'verify_candidate', choices: [
              {...candidate, 'directory_subject': folderSubject['id']},
            ]);
          }
        }
      }
    }
    if (revisitSeason && boundaryEvidence == null) {
      await tasks.commit(lease, (_) async => {'sources': 0});
      return;
    }
    var bangumiMovieAliasConflict = false;
    // One provider may miss a romanized filename query entirely. That absence
    // cannot erase the other provider's positive evidence of a different work.
    if (markers.isEmpty &&
        !RegExp(r'\{bangumi-\d+\}', caseSensitive: false).hasMatch(raw)) {
      final fileTitles = local.files.where((f) => f['category'] == 'main')
          .take(6).map((f) => PersonalFilenameParser.extractAnimeSearchKeyword(f['name'] as String))
          .where((name) => name.isNotEmpty && !RegExp(r'^\d+$').hasMatch(name)).toList();
      bool matchesFiles(Map candidate) =>
          (candidate['aliases'] as List? ?? [candidate['title']]).whereType<String>().any(
            (name) => fileTitles.any((file) => PersonalMetadataScraper.exactTitle(file, name)));
      final originalResults = Map.of(results);
      for (final provider in providers) {
        final result = originalResults[provider];
        final selected = result?.choices.singleOrNull;
        if (result?.reason != 'verify_candidate' || selected == null || matchesFiles(selected)) continue;
        final other = originalResults[provider == 'tmdb' ? 'bangumi' : 'tmdb'];
        if (provider == 'bangumi' &&
            other?.choices.singleOrNull?['directory_subject'] == selected['id']) {
          continue;
        }
        final conflicts = (other?.choices ?? const <Map<String, Object?>>[])
            .where((candidate) => candidate['exact'] == true &&
                candidate['directory_title_matches'] != true && matchesFiles(candidate))
            .toList();
        if (conflicts.isNotEmpty) {
          bangumiMovieAliasConflict = bangumiMovieAliasConflict ||
              provider == 'bangumi' &&
                  conflicts.every((candidate) => candidate['type'] == 'movie');
          results[provider] = (reason: 'conflicting_title', choices: result!.choices);
        }
      }
    }
    final freshAliases =
        results['tmdb']?.choices
                .where((row) => row['exact'] == true &&
                    (markers.isNotEmpty ||
                        results['tmdb']?.reason == 'verify_candidate' &&
                            row['directory_title_matches'] == true))
                .singleOrNull?['aliases']
            as List?;
    final savedAliasYear = _bangumiAliasRetryYear(savedTv, savedBg);
    final linkedAliases = freshAliases ??
        (savedAliasYear != null && (year == null || year == savedAliasYear)
            ? (savedTvChoice?['aliases'] as List?)
            : null);
    if (results['bangumi']?.reason == 'no_match' && linkedAliases != null) {
      final aliases = linkedAliases
          .whereType<String>()
          .where((alias) => !hints.contains(alias))
          .take(3)
          .toList();
      if (aliases.isNotEmpty) {
        results['bangumi'] = await _search(
          lease,
          'bangumi',
          raw,
          title,
          freshAliases == null ? year ?? savedAliasYear : year,
          markers,
          types,
          aliases,
        );
      }
    }
    _SpecialEvidence? specialEvidence;
    List<_SpecialEvidence>? numberedSpecials;
    if (catalog.automaticRecognition && !movieDirectory && results['tmdb']?.reason == 'no_match') {
      final bgRow = await _row(tasks.db, _id(workId, 'bangumi', 'work', ''));
      final subject = results['bangumi']?.reason == 'verify_candidate'
          ? results['bangumi']!.choices.singleOrNull
          : bgRow?['reason'] == 'verified_bangumi' && adopted(bgRow!)?['by'] == 'verified_bangumi'
              ? adopted(bgRow) : null;
      if (subject != null) {
        try {
          specialEvidence = await _standaloneSpecial(lease, raw, title, year, subject);
          if (specialEvidence != null) results['tmdb'] =
              (reason: 'verify_candidate', choices: [specialEvidence.identity]);
        } on MetadataFailure {
          // An unavailable evidence endpoint is not evidence of no match.
          results['tmdb'] = (reason: 'request_failed', choices: <Map<String, Object?>>[]);
        }
      }
    }
    if (catalog.automaticRecognition && !movieDirectory && results.length == 2 &&
        results.values.every((r) => r.reason == 'no_match')) {
      try {
        numberedSpecials = await _numberedSpecials(lease, raw, title, year);
        if (numberedSpecials != null) {
          results['tmdb'] = (reason: 'verify_candidate', choices: [numberedSpecials.first.identity]);
          results['bangumi'] = (reason: 'verify_candidate', choices: [numberedSpecials.first.parentSubject]);
        }
      } on MetadataFailure {
        // Retry incomplete discovery; never present network loss as no match.
        for (final provider in providers) {
          results[provider] = (reason: 'request_failed', choices: <Map<String, Object?>>[]);
        }
      }
    }
    String? correctedTitle;
    _TvEvidence? correctionEvidence;
    // A wrong folder is not an alias. Re-establish the filename identity from
    // official names and a complete season before replacing either candidate.
    if (catalog.automaticRecognition && pending.length == 2 &&
        markers.isEmpty && !RegExp(r'\{bangumi-\d+\}', caseSensitive: false).hasMatch(raw) &&
        year != null && !WorkSeason.conflictingYears({'title': raw}) &&
        results.values.every((r) => ['ambiguous', 'conflicting_title', 'verify_candidate', 'no_match'].contains(r.reason))) {
      final titles = local.files.where((f) => f['category'] == 'main')
          .map((f) => PersonalFilenameParser.extractAnimeSearchKeyword(f['name'] as String)).toList();
      final fileTitle = titles.firstOrNull;
      if (fileTitle != null && fileTitle.isNotEmpty &&
          titles.every((t) => PersonalMetadataScraper.exactTitle(fileTitle, t)) &&
          !PersonalMetadataScraper.exactTitle(title, fileTitle)) {
        final candidate = results['tmdb']?.choices.where((c) =>
            c['type'] == 'tv' && c['exact'] == true && c['directory_title_matches'] != true &&
            (c['aliases'] as List? ?? []).whereType<String>().any((a) => PersonalMetadataScraper.exactTitle(a, fileTitle))).singleOrNull;
        if (candidate != null && await _tvLocal(tasks.db, workId, raw, fileTitle, year) != null) {
          final aliases = (candidate['aliases'] as List).whereType<String>()
              .where((a) => !PersonalMetadataScraper.exactTitle(a, fileTitle)).take(3).toList();
          if (aliases.isNotEmpty) {
            try {
              final found = await _search(lease, 'bangumi', raw, fileTitle, year, markers, types, aliases);
              final subject = found.choices.singleOrNull;
              if (found.reason == 'verify_candidate' && subject != null && subject['year'] == year &&
                  (subject['aliases'] as List? ?? []).whereType<String>().any((a) =>
                      aliases.any((b) => PersonalMetadataScraper.exactTitle(a, b)))) {
                final evidence = await _fetchTvEvidence(lease, raw, fileTitle, year, candidate, subject,
                    languageOverride: 'ja-JP');
                if (evidence != null && evidence.local.files.length == evidence.tv.length &&
                    evidence.local.files.every((f) => f.number >= evidence.first && f.number <= evidence.last) &&
                    evidence.tv.indexed.every((p) => _chapterAgreement(p.$2, evidence.bangumi[p.$1], allowReading: true)) &&
                    evidence.tv.indexed.where((p) => _chapterAgreement(p.$2, evidence.bangumi[p.$1])).length >= evidence.tv.length - 1) {
                  correctedTitle = fileTitle;
                  correctionEvidence = evidence;
                  results['tmdb'] = (reason: 'verify_candidate', choices: [{...candidate, 'directory_title_corrected': true}]);
                  results['bangumi'] = (reason: 'verify_candidate', choices: [{...subject, 'directory_title_corrected': true}]);
                }
              }
            } on MetadataFailure {
              // Preserve the original conflict; a failed supplement proves nothing.
            }
          }
        }
      }
    }
    if (recheck != null && correctionEvidence == null &&
        results.length == 2 && results.values.every((r) => r.reason == 'verify_candidate') &&
        results['tmdb']?.choices.singleOrNull?['type'] == 'tv' &&
        providers.every((provider) => adopted(recheck.singleWhere((r) =>
            r['layer'] == 'work' && r['provider'] == provider))?['id'] == results[provider]!.choices.single['id'])) {
      try {
        correctionEvidence = boundaryEvidence ?? await _fetchTvEvidence(lease, raw, title, year,
            results['tmdb']!.choices.single, results['bangumi']!.choices.single);
        if (correctionEvidence != null) correctedTitle = title;
      } on MetadataFailure {
        // Preserve confirmed identities and pending ranges on failed evidence.
      }
    }
    if (recheck != null) {
      var corrected = false;
      await tasks.commit(lease, (tx) async {
        final current = await _automaticConflict(tx, workId);
        if (correctionEvidence == null || correctedTitle == null ||
            current == null || jsonEncode(current) != jsonEncode(recheck)) {
          return {'corrected': false};
        }
        // Keep all old decisions until every evidence endpoint has succeeded.
        // Roll back the entire replacement if the final adoption guard fails.
        await tx.execute('SAVEPOINT automatic_identity_correction');
        try {
          await tx.delete('scan_bindings', where: 'work_id=?', whereArgs: [workId]);
          for (final provider in providers) {
            await _put(tx, workId, provider, 'work', '',
                reason: 'verify_candidate', choices: results[provider]!.choices);
          }
          corrected = await _adoptVerifiedTv(tx, workId, raw,
              correctedTitle, year, correctionEvidence,
              correctedDirectory: results['tmdb']!.choices.single['directory_title_corrected'] == true);
          if (!corrected) {
            await tx.execute('ROLLBACK TO automatic_identity_correction');
          } else {
            // Preserve prior identity and monotonically increasing revisions;
            // stale review tokens and in-flight range jobs must not match again.
            final changedTokens = <String, String>{};
            for (final old in recheck) {
              final next = await _row(tx, old['id'] as String);
              if (next == null) continue;
              final revision = (old['revision'] as int) + (next['revision'] as int) + 1;
              changedTokens[_token(next)] = jsonEncode([next['id'], revision]);
              await tx.update('scan_bindings', {
                'previous': old['adopted'] ?? old['previous'],
                'revision': revision,
              }, where: 'id=?', whereArgs: [old['id']]);
            }
            for (final entry in changedTokens.entries) {
              await tx.update('scan_bindings', {'parent': entry.value},
                  where: 'work_id=? AND parent=?', whereArgs: [workId, entry.key]);
            }
          }
          await tx.execute('RELEASE automatic_identity_correction');
        } catch (_) {
          await tx.execute('ROLLBACK TO automatic_identity_correction');
          await tx.execute('RELEASE automatic_identity_correction');
          rethrow;
        }
        return {'corrected': corrected};
      });
      if (corrected) await catalog.reload();
      return;
    }
    final eligible =
        catalog.automaticRecognition &&
        results.length == providers.length &&
        results.values.every((result) => result.reason == 'verify_candidate');
    final tvOption = results['tmdb']?.choices.singleOrNull;
    final bgOption = results['bangumi']?.choices.singleOrNull;
    _TvEvidence? tvEvidence = correctionEvidence ?? boundaryEvidence;
    if (tvEvidence == null && eligible && !recoveredMovieAlias &&
        tvOption?['type'] == 'tv' &&
        bgOption != null &&
        !WorkSeason.conflictingYears({'title': raw})) {
      try {
        tvEvidence = await _fetchTvEvidence(
          lease,
          raw,
          title,
          year,
          tvOption!,
          bgOption,
          refreshAliases: recoveringTv,
        );
        tvEvidence ??= await _fetchTvEvidence(lease, raw, title, year,
            tvOption, bgOption, verifyDiscOrder: true);
      } on MetadataFailure {
        // Keep the identity candidates when a chapter endpoint fails.
      }
    }
    if (results['tmdb']?.reason == 'no_match' && supplementalMovieResult != null) {
      results['tmdb'] = supplementalMovieResult;
    }
    final tmdbResult = results['tmdb'];
    final inventory = catalog.automaticRecognition && tmdbResult != null
        ? local
        : null;
    Map<String, Object?>? tmdbChoice;
    List<Map<String, Object?>>? verifiedPartChapters;
    final seasons = <int, Map<String, Object?>>{};
    if (continuousEvidence == null && !recoveringTv && correctedTitle == null && inventory != null &&
        tmdbResult != null && !WorkSeason.conflictingYears({'title': raw}) &&
        (verifiedMovie != null ||
            ['untyped_id', 'verify_candidate', 'ambiguous'].contains(tmdbResult.reason))) {
      tmdbChoice = verifiedMovie ?? _automaticTmdb(
        tmdbResult.choices,
        inventory.files,
        year,
        PersonalMetadataScraper.queries(
          title.replaceFirst(RegExp(r'^(?:电影|劇場版|剧场版)\s+'), ''),
        ),
        explicitMovie: RegExp(r'^(?:电影|劇場版|剧场版)\s+').hasMatch(clean),
      );
      if (tmdbChoice?['type'] == 'tv') {
        final series = tmdbChoice!['id'] as int;
        try {
          if (tmdbChoice['seasons'] == null) {
            final details = await _get(
              metadataResource('tmdb', 'tv/$series'),
              lease,
            );
            if (details['id'] == series && details['seasons'] is List) {
              tmdbChoice = {
                ...tmdbChoice,
                'year': _year(details) ?? tmdbChoice['year'],
                if (details['backdrop_path'] is String)
                  'backdrop_path': details['backdrop_path'],
                'seasons': [
                  for (final row
                      in (details['seasons'] as List).whereType<Map>())
                    {
                      'season': row['season_number'],
                      'count': row['episode_count'],
                      'year': DateTime.tryParse(
                        '${row['air_date'] ?? ''}',
                      )?.year,
                    },
                ],
              };
            }
          }
          tmdbChoice = _automaticTmdb(
            [tmdbChoice], inventory.files, year, const [],
            explicitMovie: false, allowUnverifiedSeasonYear: false,
          );
          final subject = results['bangumi'];
          if (tmdbChoice != null && WorkSeason.part(raw) != null &&
              subject?.reason == 'verify_candidate' && subject!.choices.length == 1) {
            final matchedSeason = await _verifiedPartSeason(
              lease, raw, year, tmdbChoice, subject.choices.single,
            );
            if (matchedSeason != null) {
              verifiedPartChapters = matchedSeason.chapters;
              tmdbChoice = {...tmdbChoice, 'verified_part_season': matchedSeason.season,
                'part_subject': subject.choices.single['id']};
            }
          }
          for (final season in (tmdbChoice == null ? <String, Map>{} : _tmdbRanges(
            inventory,
            tmdbChoice,
            raw,
          )).values.toSet()) {
            final number = season['season'] as int;
            if (seasons.containsKey(number)) continue;
            final result = await _fetchChapters(
              lease,
              'tmdb',
              id: series,
              season: number,
            );
            final count = season['count'] as int;
            final numbers = result.chapters
                .map((chapter) => chapter['sort'])
                .toSet();
            if (result.complete &&
                result.chapters.length == count &&
                List.generate(
                  count,
                  (index) => index + 1,
                ).every(numbers.contains) &&
                result.chapters
                        .map((chapter) => chapter['id'])
                        .toSet()
                        .length ==
                    count) {
              seasons[number] = {
                'chapters': result.chapters,
                'summary':
                    (result.summary?.trim().isNotEmpty == true || number != 1)
                    ? result.summary
                    : tmdbChoice?['summary'],
                'summary_language': result.language,
              };
            }
          }
        } on MetadataFailure {
          // A failed chapter request cannot invalidate the verified identity.
        }
        // Failure to fetch details cannot turn an unexplained year mismatch
        // into a verified identity. Recheck even after the request failed.
        if (tmdbChoice != null) {
          tmdbChoice = _automaticTmdb(
            [tmdbChoice], inventory.files, year, const [],
            explicitMovie: false, allowUnverifiedSeasonYear: false,
          );
        }
      }
    }
    if (tmdbChoice?['type'] == 'tv' && inventory != null &&
        bgOption?['exact'] == true && bgOption?['directory_title_matches'] == true &&
        bgOption?['year'] is int && tmdbChoice?['year'] is int &&
        bgOption?['year'] != tmdbChoice?['year']) {
      final season = (tmdbChoice!['seasons'] as List? ?? [])
          .whereType<Map>().where((season) => _positive(season['season'])).singleOrNull;
      final regular = inventory.files.where(_singleRegularFile).toList();
      if (season != null && regular.isNotEmpty &&
          _unmarkedPartialTvRange(raw, tmdbChoice, regular, season['count'])) {
        results['tmdb'] = (reason: 'conflicting_title', choices: tmdbResult!.choices);
        tmdbChoice = null;
      }
    }
    // A TMDB alternative title can describe a season or special of a much
    // larger series. For an inferred release, a series ID alone is insufficient.
    if (splitRelease && tmdbChoice?['type'] == 'tv' && seasons.isEmpty) {
      results['tmdb'] = (reason: 'conflicting_title', choices: tmdbResult!.choices);
      tmdbChoice = null;
    }
    final inferredSubject = results['bangumi']?.choices.singleOrNull;
    if (splitRelease && results['bangumi']?.reason == 'verify_candidate' &&
        inferredSubject?['directory_title_matches'] != true) {
      final regular = local.files.where((file) => file['category'] == 'main').toList();
      final numbers = regular.map((file) => file['episode']).toSet();
      var reason = 'conflicting_title';
      if (regular.isNotEmpty && regular.every(_singleRegularFile) &&
          numbers.length == regular.length && numbers.contains(1)) {
        try {
          final evidence = await _fetchChapters(lease, 'bangumi',
              id: inferredSubject!['id'] as int, regularOnly: true);
          final chapters = evidence.chapters;
          if (!evidence.complete) {
            reason = 'query_incomplete';
          } else if (chapters.length == regular.length &&
              chapters.map((chapter) => chapter['sort']).toSet().containsAll(numbers)) {
            reason = 'verify_candidate';
          }
        } on MetadataFailure {
          reason = 'query_incomplete';
        }
      }
      if (reason != 'verify_candidate') {
        results['bangumi'] = (reason: reason, choices: [inferredSubject!]);
      }
    }
    var adoptedAutomatically = false;
    await tasks.commit(lease, (tx) async {
      final checkedProviders = <String>{};
      final tmdb =
          results['tmdb']?.choices ??
          candidates(
            await _row(tx, _id(workId, 'tmdb', 'work', '')) ??
                {'candidates': '[]'},
          );
      for (final entry in pending.entries) {
        final before = entry.value;
        final result = results[entry.key]!;
        final current = await _row(tx, before['id'] as String);
        if (current?['revision'] != before['revision']) continue;
        checkedProviders.add(entry.key);
        final choices = <Map<String, Object?>>[];
        for (final option in result.choices) {
          if (entry.key == 'bangumi') {
            final mapping = await catalog.mappingStore!.subjectTargets(
              tx,
              option['id'] as int,
            );
            final paired = mapping.targets
                .where(
                  (target) => tmdb.any(
                    (candidate) =>
                        target['type'] == candidate['type'] &&
                        target['id'] == candidate['id'],
                  ),
                )
                .toList();
            choices.add({
              ...option,
              'mapping': mapping.state,
              'mapping_target_count': mapping.targets.length,
              if (mapping.version != null) 'mapping_version': mapping.version,
              if (paired.isNotEmpty) 'targets': paired,
            });
          } else {
            choices.add(option);
          }
        }
        await _put(
          tx,
          workId,
          entry.key,
          'work',
          '',
          reason: result.reason,
          choices:
              choices.isEmpty &&
                  (result.reason == 'request_failed' ||
                      result.reason == 'invalid_response' ||
                      result.reason == 'query_incomplete')
              ? candidates(before)
              : choices,
        );
      }
      if (continuousEvidence case final evidence?
          when checkedProviders.contains('tmdb')) {
        final currentBg = await _row(tx, _id(workId, 'bangumi', 'work', ''));
        if (currentBg?['revision'] == bgIdentity?['revision']) {
          adoptedAutomatically = await _adoptContinuousTv(
            tx, workId, raw, title, evidence,
          );
        }
      } else if (numberedSpecials != null) {
        adoptedAutomatically = await _adoptNumberedSpecials(tx, workId, numberedSpecials);
      } else if (specialEvidence != null) {
        adoptedAutomatically = await _adoptStandaloneSpecial(tx, workId, specialEvidence);
      } else if (eligible &&
          markers.length == 1 &&
          types.length == 1 &&
          types.single == 'movie' &&
          year != null) {
        adoptedAutomatically = await _adoptVerifiedMovie(
          tx,
          workId,
          title,
          markers.single,
        );
      } else if (tvEvidence case final evidence?) {
        adoptedAutomatically = await _adoptVerifiedTv(
          tx,
          workId,
          raw,
          correctedTitle ?? title,
          year,
          evidence,
          correctedDirectory: correctedTitle != null,
          allowAutomaticTmdb: recoveringTv,
          allowSeasonDateDifferences: verifiedSameTitleSeries,
        );
      }
      if (narrowedPremiere && !adoptedAutomatically && verifiedMovie == null) {
        final row = await _row(tx, _id(workId, 'bangumi', 'work', ''));
        if (row?['state'] == 'pending' && row?['reason'] == 'verify_candidate') {
          await _put(tx, workId, 'bangumi', 'work', '',
              reason: 'query_incomplete', choices: candidates(row!));
        }
      }
      if (correctedTitle != null && !adoptedAutomatically) {
        for (final provider in providers) {
          final row = await _row(tx, _id(workId, provider, 'work', ''));
          if (row?['state'] == 'pending') {
            await _put(tx, workId, provider, 'work', '',
                reason: 'conflicting_title', choices: candidates(row!));
          }
        }
      }
      if (!adoptedAutomatically && tmdbChoice != null) {
        final identity = await _row(tx, _id(workId, 'tmdb', 'work', ''));
        final original = pending['tmdb'];
        final protection = (await tx.query(
          'library_work_protection',
          where: 'work_id=?',
          whereArgs: [workId],
        )).single;
        final latest = await _workFiles(tx, workId);
        var bgUnchanged = true;
        if (verifiedMovie != null && movieSubject != null) {
          final currentBg = await _row(tx, _id(workId, 'bangumi', 'work', ''));
          if (confirmedMovieSubject == null && bgResult?.reason == 'verify_candidate') {
            bgUnchanged = checkedProviders.contains('bangumi') &&
                currentBg?['reason'] == 'verify_candidate' &&
                candidates(currentBg!).singleOrNull?['id'] == movieSubject['id'];
          } else {
            bgUnchanged = currentBg?['revision'] == bgIdentity?['revision'];
          }
        }
        if (identity != null && identity['state'] == 'pending' && bgUnchanged &&
            original != null &&
            (verifiedMovie == null
                ? identity['revision'] == (original['revision'] as int) + 1
                : checkedProviders.contains('tmdb')) &&
            protection['identity_locked'] != 1 &&
            protection['legacy_lock'] != 1 &&
            inventory!.folder == latest.folder &&
            jsonEncode(inventory.files) == jsonEncode(latest.files)) {
          const reason = 'verified_tmdb';
          final planned = _tmdbRanges(latest, tmdbChoice, raw);
          if (tmdbChoice['verified_part_season'] != null) {
            final bg = await _row(tx, _id(workId, 'bangumi', 'work', ''));
            final originalBg = pending['bangumi'];
            if (originalBg == null || bg == null ||
                bg['revision'] != (originalBg['revision'] as int) + 1 ||
                candidates(bg).singleOrNull?['id'] != tmdbChoice['part_subject']) {
              planned.clear();
            }
          }
          final selectedSeason = planned.values.toSet().singleOrNull;
          final published = <String, Object?>{
            ...tmdbChoice,
            if (selectedSeason?['year'] case final int seasonYear)
              'year': seasonYear,
            if ((selectedSeason?['season'] as int? ?? 0) > 1 &&
                (WorkSeason.explicit({'title': raw}) != null ||
                    tmdbChoice['verified_part_season'] != null))
              'title': clean,
          };
          await _saveDecision(
            tx,
            identity,
            published,
            reason: reason,
            by: reason,
          );
          final confirmed = (await _row(tx, identity['id'] as String))!;
          for (final entry in planned.entries) {
            final season = entry.value;
            final number = season['season'] as int;
            final evidence = seasons[number];
            if (evidence == null) continue;
            final scope = entry.key;
            await _put(
              tx,
              workId,
              'tmdb',
              'range',
              scope,
              parent: _token(confirmed),
            );
            final range = (await _row(
              tx,
              _id(workId, 'tmdb', 'range', scope),
            ))!;
            if (range['state'] != 'pending') continue;
            var localOffset = 0;
            // Only a complete, disjoint absolute sequence proves this numbering.
            // Partial downloads and explicit SxxExx names retain their normal rules.
            final partChapters = verifiedPartChapters;
            if (partChapters != null && planned.length == 1) {
              final files = latest.files.where((file) => file['category'] == 'main').toList();
              final start = partChapters.first['sort'] as int;
              final numbers = files.map((file) => file['episode']).toSet();
              // Mixed local/absolute numbering cannot establish a safe range,
              // even for the subset that happens to fit season-local numbers.
              if (numbers.whereType<int>().any((n) => n >= 1 && n <= (season['count'] as int)) &&
                  numbers.whereType<int>().any((n) => n > (season['count'] as int))) {
                continue;
              }
              if (start > (season['count'] as int) &&
                  files.length == partChapters.length &&
                  numbers.length == files.length &&
                  files.every((file) => _singleRegularFile(file) &&
                      _explicitFileSeason(file['name'] as String) == null &&
                      !RegExp(r'\d\s*[&+]\s*\d').hasMatch(file['name'] as String) &&
                      (file['file_group'] as String? ?? _directoryScope(file['relative_path'] as String, latest.folder)) == scope) &&
                  partChapters.every((chapter) => numbers.contains(chapter['sort']))) {
                localOffset = 1 - start;
              }
            }
            await _saveDecision(
              tx,
              range,
              {
                'season': number,
                'first': 1,
                'last': season['count'],
                'offset': localOffset,
                ...evidence,
              },
              reason: reason,
              by: reason,
            );
          }
          await _syncChildren(tx, workId, 'tmdb');
          adoptedAutomatically = true;
        }
      }
      final bangumiResult = results['bangumi'];
      final ignoreMovieAlias = bangumiMovieAliasConflict &&
          bangumiResult?.reason == 'conflicting_title' &&
          await _verifiedTvDisambiguatesMovieAlias(
            tx, workId, bangumiResult?.choices.singleOrNull,
          );
      final validRecoveredAlias = !recoveredMovieAlias ||
          await _verifiedTvDisambiguatesMovieAlias(
            tx, workId, bangumiResult?.choices.singleOrNull,
          );
      if (pending.containsKey('bangumi') && correctedTitle == null &&
          (!narrowedPremiere || adoptedAutomatically && verifiedMovie != null) &&
          catalog.automaticRecognition &&
          validRecoveredAlias &&
          (!movieDirectory || verifiedMovie != null) &&
          (bangumiResult?.reason == 'verify_candidate' || ignoreMovieAlias)) {
        final original = pending['bangumi']!;
        final row = await _row(tx, original['id'] as String);
        final protection = (await tx.query(
          'library_work_protection',
          where: 'work_id=?',
          whereArgs: [workId],
        )).single;
        if (row?['state'] == 'pending' &&
            (row!['revision'] as int) == (original['revision'] as int) + 1 &&
            protection['identity_locked'] != 1 &&
            protection['legacy_lock'] != 1) {
          final candidate = candidates(row).single;
          final targets = candidate['targets'] as List?;
          final adoptedTmdb = adopted(
            await _row(tx, _id(workId, 'tmdb', 'work', '')) ?? {},
          );
          if (candidate['mapping_target_count'] == 0 ||
              (adoptedTmdb != null &&
                  targets?.any(
                        (target) =>
                            target['id'] == adoptedTmdb['id'] &&
                            target['type'] == adoptedTmdb['type'],
                      ) ==
                      true)) {
            const reason = 'verified_bangumi';
            await _saveDecision(
              tx,
              row,
              {
                ...candidate,
                if (adoptedTmdb?['type'] == 'movie') 'movie': true,
              },
              reason: reason,
              by: reason,
            );
            await _syncChildren(tx, workId, 'bangumi');
            adoptedAutomatically = true;
          }
        }
      }
      if (verifiedPartChapters != null && inventory != null && tmdbChoice != null) {
        final latest = await _workFiles(tx, workId);
        if (latest.folder == inventory.folder &&
            jsonEncode(latest.files) == jsonEncode(inventory.files)) {
          await _adoptPartOffset(tx, workId, raw, tmdbChoice, verifiedPartChapters, latest);
        }
      }
      if (adoptedAutomatically || recoveringTv) {
        await ScopedArtwork.publishDrafts(catalog, tx, workId);
      }
      if (catalog.automaticRecognition && results.isEmpty) {
        adoptedAutomatically = await _syncMovieAttachments(tx, workId);
      }
      return {'sources': results.length};
    });
    if (adoptedAutomatically || recoveringTv) await catalog.reload();
  }

  static Map<String, Object?>? _automaticTmdb(
    List<Map<String, Object?>> choices,
    List<Map<String, Object?>> files,
    int? year,
    List<String> hints, {
    required bool explicitMovie,
    bool allowUnverifiedSeasonYear = true,
  }) {
    final main = files.where((file) => file['category'] == 'main').toList();
    if (main.isEmpty) return null;
    final numbered = main
        .where(_singleRegularFile)
        .map((file) => file['episode'])
        .toSet()
        .length;
    final matches = choices.where((choice) {
      if (choice['type'] == 'tv' && main.length == 1 && numbered == 0 &&
          choice['title_matches'] != true) return false;
      final matchingSeason =
          choice['type'] == 'tv' &&
          (choice['seasons'] as List? ?? []).whereType<Map>().any(
            (season) => _positive(season['season']) && season['year'] == year,
          );
      if (year != null &&
          choice['year'] != null &&
          choice['year'] != year &&
          !matchingSeason &&
          !(allowUnverifiedSeasonYear &&
              choice['type'] == 'tv' && choice['seasons'] == null)) {
        return false;
      }
      if (choice['type'] == 'movie' &&
          (main.length != 1 ||
              !(explicitMovie &&
                      choice['marker'] == true &&
                      year != null &&
                      choice['exact'] == true &&
                      numbered == 0) &&
                  !hints.any(
                    (hint) => PersonalMetadataScraper.exactTitle(
                      hint,
                      PersonalFilenameParser.extractAnimeSearchKeyword(
                        main.single['name'] as String,
                      ),
                    ),
                  ) &&
                  !(choice['verified_movie_alias'] == true ||
                    choice['exact'] == true && year != null && choice['year'] == year &&
                      (choice['aliases'] as List? ?? []).whereType<String>().any(
                        (alias) => PersonalMetadataScraper.exactTitle(alias,
                            PersonalFilenameParser.extractAnimeSearchKeyword(main.single['name'] as String)))))) {
        return false;
      }
      return choice['title_matches'] == true ||
          (choice['marker'] == true &&
              ((year != null && choice['year'] == year) ||
                  (choice['type'] == 'tv' && numbered >= 2)));
    }).toList();
    final exact = matches.where((choice) => choice['title_matches'] == true);
    return exact.isNotEmpty ? exact.singleOrNull : matches.singleOrNull;
  }

  static Map<String, Map> _tmdbRanges(
    ({String folder, List<Map<String, Object?>> files}) inventory,
    Map identity,
    String raw, {
    int? corroboratedYear,
  }) {
    if (identity['type'] != 'tv') return {};
    if (WorkSeason.part(raw) != null && identity['verified_part_season'] == null) return {};
    final seasons = ((identity['seasons'] as List?) ?? const [])
        .whereType<Map>()
        .where(
          (row) =>
              _positive(row['season']) &&
              _positive(row['count']) &&
              (row['count'] as int) <= 100,
        )
        .toList();
    final groups = <String, List<Map<String, Object?>>>{};
    for (final file in inventory.files.where(_singleRegularFile)) {
      final scope =
          file['file_group'] as String? ??
          _directoryScope(file['relative_path'] as String, inventory.folder);
      groups.putIfAbsent(scope, () => []).add(file);
    }
    final result = <String, Map>{};
    for (final entry in groups.entries) {
      final named = <int>{
        if (identity['verified_part_season'] case final int season) season,
        ...[raw, p.posix.basename(entry.key)]
            .map((title) => WorkSeason.explicit({'title': title}))
            .whereType<int>(),
        ...entry.value
            .map((file) => _explicitFileSeason(file['name'] as String))
            .whereType<int>(),
      };
      if (named.length > 1 ||
          named.contains(0) ||
          WorkSeason.multiple({'title': raw})) {
        continue;
      }
      final available = seasons
          .where((season) => named.isEmpty || season['season'] == named.single)
          .toList();
      final year = WorkSeason.year({'title': raw}) ?? corroboratedYear;
      final dated = available.where(
        (season) => year != null && season['year'] == year,
      );
      // Unmarked regular episodes start with season one. A title with multiple
      // plausible seasons still requires a directory-level decision.
      final season = available.singleOrNull ?? dated.singleOrNull;
      if (season != null &&
          year != null &&
          season['year'] != null &&
          season['year'] != year)
        continue;
      if (season != null) {
        result[entry.key] = season;
      }
    }
    if (groups.length > 1) {
      final claimed = <(Object?, Object?), String>{};
      final ambiguous = <String>{};
      for (final entry in result.entries) {
        for (final file in groups[entry.key]!) {
          final target = (entry.value['season'], file['episode']);
          final previous = claimed.putIfAbsent(target, () => entry.key);
          if (previous != entry.key) ambiguous.addAll([previous, entry.key]);
        }
      }
      result.removeWhere((scope, _) => ambiguous.contains(scope));
    }
    return result;
  }

  static bool _unmarkedPartialTvRange(
    String folder,
    Map identity,
    Iterable<Map<String, Object?>> files,
    Object? count,
  ) => identity['marker'] != true && WorkSeason.year({'title': folder}) == null &&
      WorkSeason.explicit({'title': folder}) == null &&
      files.every((file) => _explicitFileSeason(file['name'] as String) == null) &&
      count is int && files.map((file) => file['episode']).toSet().length < count;

  Future<_TvLocal?> _tvLocal(
    DatabaseExecutor tx,
    String work,
    String raw,
    String title,
    int? year, {
    Iterable<String> aliases = const [],
    bool allowDualNumbers = false,
    bool allowCombinedDirectory = false,
  }) async {
    final inventory = await _workFiles(tx, work);
    final files = inventory.files
        .where((file) => file['category'] == 'main' && file['episode'] != 0)
        .toList();
    if (files.length < 2 ||
        files.length > 100 ||
        files.any(
          (file) => file['file_group'] != null ||
              !_singleRegularFile(file, allowDualNumbers: allowDualNumbers),
        )) {
      return null;
    }
    final dirs = {
      for (final file in files)
        _directoryScope(file['relative_path'] as String, inventory.folder),
    };
    if (dirs.length != 1) return null;
    final dual = [
      for (final file in files)
        allowDualNumbers ? _dualEpisodeNumber(file['name'] as String) : null,
    ];
    final hasDual = dual.any((number) => number != null);
    final numbered = dual.whereType<({int season, int episode, int absolute})>().toList();
    final absoluteOffset = hasDual
        ? numbered.map((n) => n.episode - n.absolute).toSet().singleOrNull : null;
    if (hasDual && (numbered.length != files.length || absoluteOffset == null ||
        absoluteOffset >= 0 || numbered.map((n) => n.episode).toSet().length != files.length ||
        numbered.any((n) => n.episode < 1 || n.episode > files.length))) return null;
    final explicit = [
      for (final (index, file) in files.indexed)
        dual[index]?.season ?? _explicitFileSeason(file['name'] as String),
    ];
    final namedSeasons = {
      ...explicit.whereType<int>(),
      ...[
        raw,
        p.posix.basename(dirs.single),
      ].map((name) => WorkSeason.explicit({'title': name})).whereType<int>(),
    };
    if (namedSeasons.length > 1 ||
        namedSeasons.contains(0) ||
        !allowCombinedDirectory && WorkSeason.multiple({'title': raw})) {
      return null;
    }
    var localTitle = false;
    final numbers = <int>{};
    for (final (index, file) in files.indexed) {
      if (!numbers.add(file['episode'] as int)) return null;
      final filename = file['name'] as String;
      if (dual[index] != null && dual[index]!.absolute != file['episode']) return null;
      final clue = PersonalFilenameParser.extractAnimeSearchKeyword(
        hasDual ? filename.replaceFirst(_dualEpisodeLabel, ' ') : filename,
        episodeNumber: file['episode'] as int?,
      );
      if (clue.isEmpty || RegExp(r'^\d+$').hasMatch(clue)) continue;
      if (!_sameLocalTitle(title, clue) &&
          !aliases.any((alias) => _sameLocalTitle(alias, clue))) {
        return null;
      }
      localTitle = true;
    }
    final explicitEpisodes = explicit.every((season) => season != null);
    if (!localTitle &&
        !(explicitEpisodes &&
            year != null &&
            PersonalFilenameParser.tmdbType(raw) == 'tv')) {
      return null;
    }
    return (
      directory: dirs.single,
      season: namedSeasons.singleOrNull,
      absoluteOffset: absoluteOffset,
      explicitEpisodes: explicitEpisodes,
      files: [
        for (final file in files)
          (
            id: file['id'] as String,
            path: file['relative_path'] as String,
            number: file['episode'] as int,
          ),
      ],
    );
  }

  Future<_ContinuousTvEvidence?> _fetchContinuousTv(
    TaskLease lease,
    String raw,
    String title,
    int year,
    Map<String, Object?> choice,
    Map<String, Object?> bangumi,
    List<String> aliases,
  ) async {
    final local = await _tvLocal(tasks.db, lease.workId!, raw, title, year, aliases: aliases);
    if (local == null || local.season != null || WorkSeason.part(raw) != null ||
        !_completeAbsoluteNumbering(local)) return null;
    final series = choice['id'] as int, subject = bangumi['id'] as int;
    final details = await _get(metadataResource('tmdb', 'tv/$series'), lease);
    final rawSeasons = details['seasons'];
    if (details['id'] != series || _year(details) != year || rawSeasons is! List ||
        rawSeasons.any((row) => row is! Map || row['season_number'] is! int)) {
      return null;
    }
    final seasons = [
      for (final row in rawSeasons.cast<Map>())
        if (row['season_number'] != 0)
          {
            'season': row['season_number'],
            'count': row['episode_count'],
            'year': DateTime.tryParse('${row['air_date'] ?? ''}')?.year,
          },
    ]..sort((a, b) => (a['season'] as int).compareTo(b['season'] as int));
    if (seasons.length < 2 || seasons.length > 6 ||
        seasons.indexed.any((entry) => entry.$2['season'] != entry.$1 + 1 ||
            !_positive(entry.$2['count'])) ||
        seasons.fold<int>(0, (total, row) => total + (row['count'] as int)) != local.files.length) {
      return null;
    }
    final chapters = <List<Map<String, Object?>>>[];
    for (final season in seasons) {
      final result = await _fetchChapters(lease, 'tmdb', id: series,
          season: season['season'] as int, languageOverride: 'ja-JP');
      if (!result.complete || !_continuousChapters(result.chapters, season['count'] as int)) {
        return null;
      }
      chapters.add(result.chapters);
    }
    final result = await _fetchChapters(lease, 'bangumi', id: subject,
        regularOnly: true, languageOverride: 'ja-JP');
    final bg = result.chapters;
    if (!result.complete || !_continuousChapters(bg, local.files.length)) return null;
    final localizedDate = RegExp(r'^(\d{4})年(\d{1,2})月(\d{1,2})日$');
    for (final chapter in bg) {
      final rawDate = chapter['date'];
      if (rawDate is! String) return null;
      final parts = localizedDate.firstMatch(rawDate);
      if (parts != null) {
        final year = int.parse(parts[1]!), month = int.parse(parts[2]!), day = int.parse(parts[3]!);
        final date = DateTime.utc(year, month, day);
        if (date.month != month || date.day != day) return null;
        chapter['date'] = date.toIso8601String().split('T').first;
      }
    }
    final tv = chapters.expand((season) => season).toList();
    if (tv.map((row) => row['id']).toSet().length != tv.length ||
        tv.any((row) => DateTime.tryParse('${row['date']}') == null) ||
        bg.any((row) => DateTime.tryParse('${row['date']}') == null)) {
      return null;
    }
    final uniqueTitles = tv.map((row) => PersonalMetadataScraper.normalize(
        _originalChapterTitle(row))).toSet();
    if (uniqueTitles.length != tv.length ||
        !(tv.indexed.every((entry) => _chapterAgreement(entry.$2, bg[entry.$1])) ||
            _seasonChapterAgreement(tv, bg))) {
      return null;
    }
    return (local: local, choice: {
      ...choice,
      'seasons': seasons,
      if (details['backdrop_path'] is String) 'backdrop_path': details['backdrop_path'],
    }, aliases: aliases, subject: subject, seasons: chapters, bangumi: bg);
  }

  static bool _continuousChapters(List<Map<String, Object?>> chapters, int count) {
    if (chapters.length != count ||
        chapters.map((row) => row['id']).toSet().length != count ||
        chapters.any((row) => row['type'] != 0 || row['sort'] is! int ||
            _originalChapterTitle(row).trim().length < 2 ||
            _genericChapterTitle.hasMatch(_originalChapterTitle(row).trim()))) {
      return false;
    }
    chapters.sort((a, b) => (a['sort'] as int).compareTo(b['sort'] as int));
    return chapters.indexed.every((entry) => entry.$2['sort'] == entry.$1 + 1);
  }

  static bool _completeAbsoluteNumbering(_TvLocal local) {
    // _tvLocal already excludes duplicate and non-positive file numbers.
    // An equal total alone does not prove the local sequence begins at one.
    return local.files.every((file) => file.number <= local.files.length);
  }

  Future<_TvEvidence?> _fetchTvEvidence(
    TaskLease lease,
    String raw,
    String title,
    int? year,
    Map tmdb,
    Map bangumi, {
    String? languageOverride,
    bool verifyDiscOrder = false,
    bool refreshAliases = false,
    bool requireSubjectFilenames = false,
    bool allowDualNumbers = false,
  }) async {
    year ??= bangumi['year'] as int?;
    final series = tmdb['id'] as int, subject = bangumi['id'] as int;
    final aliases = (tmdb['aliases'] as List? ?? []).whereType<String>().toList();
    final subjectAliases = (bangumi['aliases'] as List? ?? []).whereType<String>();
    if (requireSubjectFilenames) aliases.addAll(subjectAliases);
    var local = await _tvLocal(tasks.db, lease.workId!, raw, title, year,
        aliases: aliases, allowDualNumbers: allowDualNumbers);
    if (local == null && refreshAliases && tmdb['exact'] == true) {
      final details = await _get(metadataResource('tmdb', 'tv/$series',
          parameters: {'append_to_response': 'alternative_titles,translations'}), lease);
      if (details['id'] != series) return null;
      aliases.addAll(PersonalMetadataScraper.officialTitles(details)
          .where((alias) => !aliases.contains(alias)).toList());
      local = await _tvLocal(tasks.db, lease.workId!, raw, title, year,
          aliases: aliases, allowDualNumbers: allowDualNumbers);
    }
    if (local == null || (!verifyDiscOrder && tmdb['exact'] != true) || bangumi['exact'] != true) {
      return null;
    }
    if (requireSubjectFilenames && local.files.any((file) {
      final clue = PersonalFilenameParser.extractAnimeSearchKeyword(
          p.posix.basename(file.path), episodeNumber: file.number);
      return !subjectAliases.any((alias) => _sameLocalTitle(alias, clue));
    })) return null;
    final subjectMap = await catalog.mappingStore!.subjectTargets(
      tasks.db,
      subject,
    );
    final target = subjectMap.targets.singleOrNull;
    if (subjectMap.targets.isNotEmpty &&
        (target == null || target['type'] != 'tv' || target['id'] != series)) {
      return null;
    }
    var seasons = (tmdb['seasons'] as List? ?? []).whereType<Map>().toList();
    if (seasons.isEmpty) {
      AnimeMappingStore.checkForeground();
      final details = await _get(
        metadataResource('tmdb', 'tv/$series'),
        lease,
      );
      if (details['id'] != series || details['seasons'] is! List) return null;
      seasons = [
        for (final row in (details['seasons'] as List).whereType<Map>())
          {
            'season': row['season_number'],
            'count': row['episode_count'],
            'year': DateTime.tryParse('${row['air_date'] ?? ''}')?.year,
          },
      ];
    }
    final positiveSeasons = seasons
        .where((s) => _positive(s['season']) && _positive(s['count']))
        .toList();
    final yearMatches = positiveSeasons
        .where((s) => year != null && s['year'] == year)
        .toList();
    final mappedSeason = target?['season'] as int?;
    final boundarySeason = verifyDiscOrder && year != null
        ? positiveSeasons.where((s) => s['year'] == year! - 1).singleOrNull : null;
    final season =
        local.season ??
        mappedSeason ??
        yearMatches.singleOrNull?['season'] ??
        boundarySeason?['season'] ??
        positiveSeasons.singleOrNull?['season'] ??
        (!verifyDiscOrder && target == null && yearMatches.length > 1
            ? _completeSeasonByCount(local, yearMatches, title, tmdb, aliases)
            : null);
    if (season is! int ||
        season < 1 ||
        (mappedSeason != null && season != mappedSeason)) {
      return null;
    }
    final spec = positiveSeasons
        .where((s) => s['season'] == season)
        .singleOrNull;
    final count = spec?['count'];
    if (count is! int ||
        count > 100 ||
        (!verifyDiscOrder && year != null && spec?['year'] != null && spec?['year'] != year)) {
      return null;
    }
    final first = target?['episode'] as int? ?? 1;
    final last =
        target?['episodeEnd'] as int? ?? target?['episode'] as int? ?? count;
    if (local.absoluteOffset != null) {
      final preceding = [
        for (var n = 1; n < season; n++)
          positiveSeasons.where((row) => row['season'] == n).singleOrNull?['count'],
      ];
      if (season < 2 || year == null || spec?['year'] != year ||
          first != 1 || last != count || local.files.length != count ||
          !preceding.every(_positive) ||
          preceding.cast<int>().fold(0, (a, b) => a + b) != -local.absoluteOffset!) return null;
    }
    final fetched = await Future.wait([
      _fetchChapters(lease, 'tmdb', id: series, season: season, languageOverride: languageOverride),
      _fetchChapters(lease, 'bangumi', id: subject, regularOnly: true, languageOverride: languageOverride),
    ]);
    if (fetched.any((result) => !result.complete) ||
        fetched[0].chapters.length != count) {
      return null;
    }
    final tv =
        fetched[0].chapters
            .where(
              (row) =>
                  row['sort'] is int &&
                  (row['sort'] as int) >= first &&
                  (row['sort'] as int) <= last,
            )
            .toList()
          ..sort((a, b) => (a['sort'] as int).compareTo(b['sort'] as int));
    final bg =
        fetched[1].chapters
            .where((row) => row['type'] == 0 && row['sort'] is int)
            .toList()
          ..sort((a, b) => (a['sort'] as int).compareTo(b['sort'] as int));
    if (first > last ||
        last > count ||
        tv.length != last - first + 1 ||
        bg.length != tv.length ||
        bg.length != fetched[1].chapters.length ||
        bg.isEmpty ||
        tv.map((row) => row['id']).toSet().length != tv.length ||
        bg.map((row) => row['id']).toSet().length != bg.length) {
      return null;
    }
    for (var i = 0; i < tv.length; i++) {
      if (tv[i]['sort'] != first + i ||
          bg[i]['sort'] != (bg.first['sort'] as int) + i) {
        return null;
      }
    }
    if (local.absoluteOffset case final int offset) {
      if (bg.first['sort'] != 1 && bg.first['sort'] != 1 - offset) return null;
    }
    if (languageOverride == null &&
        !tv.indexed.every((entry) => _chapterAgreement(entry.$2, bg[entry.$1]))) {
      // Compare original episode names, not translations from different locales.
      // Keep the configured display titles and require the same IDs and order.
      // Bangumi already includes its original names in the first response.
      final originals = await _fetchChapters(lease, 'tmdb', id: series,
          season: season, languageOverride: 'ja-JP');
      if (!originals.complete) return null;
      for (final chapter in tv) {
        final original = originals.chapters.where((r) => r['id'] == chapter['id'] &&
            r['sort'] == chapter['sort'] && r['date'] == chapter['date']).singleOrNull;
        if (original == null) return null;
        chapter['verification_title'] = original['title'];
      }
    }
    if (local.absoluteOffset != null && fetched[0].language != 'zh-CN' && tv.length >= 12) {
      final conflict = tv.indexed.where((item) =>
          !_chapterAgreement(item.$2, bg[item.$1])).singleOrNull;
      if (conflict != null) {
        final translated = await _fetchChapters(lease, 'tmdb', id: series,
            season: season, languageOverride: 'zh-CN');
        final original = conflict.$2;
        final alternate = translated.complete ? translated.chapters.where((row) =>
            row['id'] == original['id'] && row['sort'] == original['sort'] &&
            row['date'] == original['date']).singleOrNull : null;
        if (alternate != null) original['comparison_title_zh'] = alternate['title'];
      }
    }
    if (verifyDiscOrder) {
      final inventory = await _workFiles(tasks.db, lease.workId!);
      final files = inventory.files.where((f) => f['category'] == 'main').toList();
      if (year == null || local.explicitEpisodes || local.files.length != count ||
          first != 1 || last != count || bg.first['sort'] != 1 ||
          files.any((f) => !RegExp(r'\bBD(?:Rip)?\b', caseSensitive: false).hasMatch('${f['name']}')) ||
          !_discSeasonOrder(tv, bg, year)) {
        return null;
      }
    }
    return (
      local: local,
      series: series,
      subject: subject,
      season: season,
      first: first,
      last: last,
      aliases: aliases,
      subjectMap: subjectMap,
      tv: tv,
      bangumi: bg,
      summary: fetched[0].summary,
      language: fetched[0].language,
      discOrder: verifyDiscOrder,
    );
  }

  static int? _completeSeasonByCount(
    _TvLocal local,
    List<Map> seasons,
    String title,
    Map series,
    List<String> aliases,
  ) {
    final count = local.files.length;
    if (local.files.any((file) => file.number < 1 || file.number > count)) return null;
    if (series['directory_title_matches'] == false) {
      final directory = PersonalMetadataScraper.normalize(title);
      // When the directory extends a known series name, require its
      // distinguishing suffix on every file before using the local count.
      final base = [series['title'], ...aliases].whereType<String>()
          .map(PersonalMetadataScraper.normalize)
          .where((name) => name.length >= 4 && name != directory && directory.startsWith(name))
          .fold('', (longest, name) => name.length > longest.length ? name : longest);
      if (base.isNotEmpty) {
        final suffix = directory.substring(base.length);
        if (local.files.any((file) => !PersonalMetadataScraper.normalize(
            PersonalFilenameParser.extractAnimeSearchKeyword(
                p.posix.basename(file.path), episodeNumber: file.number)).endsWith(suffix))) {
          return null;
        }
      }
    }
    // A complete local sequence only selects which season to verify. Both
    // providers still have to supply the full matching chapter sequence.
    return seasons.where((season) => season['count'] == count)
        .map((season) => season['season'] as int).singleOrNull;
  }

  Future<({int season, List<Map<String, Object?>> chapters})?> _verifiedPartSeason(
    TaskLease lease, String raw, int? year, Map identity, Map subject,
  ) async {
    final part = WorkSeason.part(raw);
    if (part == null || year == null ||
        WorkSeason.part('${subject['title']}') != part) {
      return null;
    }
    final options = (identity['seasons'] as List? ?? []).whereType<Map>()
        .where((s) => _positive(s['season']) &&
            (s['year'] == null || s['year'] == year)).toList();
    if (options.isEmpty || options.length > 4 ||
        options.any((s) => s['year'] == null || !_positive(s['count']) ||
            (s['count'] as int) > 100)) {
      return null;
    }
    final bg = await _fetchChapters(lease, 'bangumi', id: subject['id'] as int,
        regularOnly: true, languageOverride: 'ja-JP');
    final chapters = bg.chapters.toList()..sort((a, b) => (a['sort'] as num).compareTo(b['sort'] as num));
    if (!bg.complete || chapters.length < 3 ||
        chapters.any((c) => c['type'] != 0 || c['sort'] is! int) ||
        chapters.map((c) => c['id']).toSet().length != chapters.length ||
        chapters.map((c) => PersonalFilenameParser.normalizeIdentity('${c['title']}')).toSet().length < 3) {
      return null;
    }
    for (var i = 0; i < chapters.length; i++) {
      if (chapters[i]['sort'] != (chapters.first['sort'] as int) + i) return null;
    }
    final matched = <int>[];
    for (final option in options) {
      if (option['count'] != chapters.length) continue;
      final season = option['season'] as int;
      final tv = await _fetchChapters(lease, 'tmdb', id: identity['id'] as int,
          season: season, languageOverride: 'ja-JP');
      final episodes = tv.chapters.toList()..sort((a, b) => (a['sort'] as num).compareTo(b['sort'] as num));
      if (!tv.complete || episodes.length != chapters.length ||
          episodes.map((c) => c['id']).toSet().length != episodes.length) {
        return null;
      }
      var agrees = true;
      for (var i = 0; i < episodes.length; i++) {
        if (episodes[i]['sort'] != i + 1 || !_chapterAgreement(episodes[i], chapters[i])) agrees = false;
      }
      if (agrees) matched.add(season);
    }
    final season = matched.singleOrNull;
    return season == null ? null : (season: season, chapters: chapters);
  }

  Future<void> _adoptPartOffset(
    DatabaseExecutor tx, String work, String raw, Map choice,
    List<Map<String, Object?>> chapters,
    ({String folder, List<Map<String, Object?>> files}) inventory,
  ) async {
    final tv = await _row(tx, _id(work, 'tmdb', 'work', ''));
    final bg = await _row(tx, _id(work, 'bangumi', 'work', ''));
    if (tv?['state'] != 'confirmed' || bg?['state'] != 'confirmed' ||
        adopted(tv!)?['id'] != choice['id'] ||
        adopted(bg!)?['id'] != choice['part_subject']) {
      return;
    }
    final scopes = _tmdbRanges(inventory, choice, raw);
    if (scopes.length != 1) return;
    final scope = scopes.keys.single;
    final tvRow = await _row(tx, _id(work, 'tmdb', 'range', scope));
    final bgRow = await _row(tx, _id(work, 'bangumi', 'range', scope));
    final range = tvRow == null ? null : adopted(tvRow);
    if (range == null || tvRow!['parent'] != _token(tv) ||
        range['season'] != choice['verified_part_season'] ||
        bgRow == null || bgRow['state'] != 'pending' ||
        bgRow['parent'] != _token(bg)) {
      return;
    }
    final first = range['first'] as int, last = range['last'] as int;
    final offset = range['offset'] as int;
    if (last - first + 1 != chapters.length) return;
    final files = inventory.files.where((f) => f['category'] == 'main').toList();
    final numbers = <int>{};
    for (final file in files) {
      if (!_singleRegularFile(file) ||
          RegExp(r'\d\s*[&+]\s*\d').hasMatch(file['name'] as String) ||
          (file['file_group'] as String? ?? _directoryScope(file['relative_path'] as String, inventory.folder)) != scope ||
          !numbers.add(file['episode'] as int) ||
          (file['episode'] as int) + offset < first ||
          (file['episode'] as int) + offset > last) {
        return;
      }
    }
    if (files.isEmpty) return;
    // Do not re-parent previously confirmed per-file decisions (including manual ones).
    if ((await tx.query('scan_bindings', columns: ['id'],
        where: "work_id=? AND provider='bangumi' AND layer='episode' AND state='confirmed'",
        whereArgs: [work], limit: 1)).isNotEmpty) {
      return;
    }
    // A user/source mapping conflict outranks inferred numbering.
    for (var i = 0; i < chapters.length; i++) {
      final mapping = await catalog.mappingStore!.lookupIn(tx,
          choice['part_subject'] as int, chapters[i]['id'] as int);
      if (['excluded', 'conflict'].contains(mapping.state)) return;
      if (mapping.state == 'mapped') {
        final target = mapping.targets.singleOrNull;
        if (target == null || target['type'] != 'tv' ||
            target['id'] != choice['id'] || target['season'] != range['season'] ||
            target['episode'] != first + i) {
          return;
        }
      }
    }
    await _saveDecision(tx, bgRow, {
      'id': choice['part_subject'],
      'offset': offset + (chapters.first['sort'] as int) - first,
      'chapters': [for (final chapter in chapters) {
        ...chapter, 'title': chapter['display_title'] ?? chapter['title'],
      }],
    }, reason: 'verified_tv_chapters', by: 'verified_tv_chapters');
    await _syncChildren(tx, work, 'bangumi');
  }

  // A release's Roman sequel suffix can match an explicit official Act label.
  // Do not strip the number or equate a sequel with the unsuffixed base title.
  static bool _sameLocalTitle(String a, String b) {
    if (PersonalMetadataScraper.exactTitle(a, b)) return true;
    String? ordinal(String value) {
      final match = RegExp(r'^(.*?)\s*(?::\s*)?(?:Act\s+(\d{1,2})|\b(II|III|IV|V|VI|VII|VIII|IX|X))$',
          caseSensitive: false).firstMatch(value.trim());
      if (match == null || match[1]!.trim().length < 4) return null;
      const roman = {'II': 2, 'III': 3, 'IV': 4, 'V': 5, 'VI': 6, 'VII': 7, 'VIII': 8, 'IX': 9, 'X': 10};
      final number = match[2] ?? '${roman[match[3]!.toUpperCase()]}';
      return '${PersonalMetadataScraper.normalize(match[1]!)}#$number';
    }
    final first = ordinal(a), second = ordinal(b);
    return first != null && second != null && first == second;
  }

  static bool _isMovieDirectoryWithoutId(String raw) =>
      RegExp(r'^(?:劇場版|剧场版|(?:电影|映画|Gekijouban)\s+)', caseSensitive: false)
          .hasMatch(raw) &&
      PersonalFilenameParser.tmdbIds(raw).isEmpty &&
      !RegExp(r'\{bangumi-\d+\}', caseSensitive: false).hasMatch(raw);

  static final _compilationMarker = RegExp(
    r'総集編|總集[篇編]|总集[篇编]|\b(?:recap\s+movie|compilation\s+(?:movie|film))\b',
    caseSensitive: false,
  );

  static final _ovaMarker = RegExp(r'番外[編篇]|\bOVA\b', caseSensitive: false);
  static final _ovaFormat = RegExp(r'\bOVA\b', caseSensitive: false);

  Future<bool> _recognizeTwoPartOva(
    TaskLease lease,
    String raw,
    String title,
    int? year,
    ({String folder, List<Map<String, Object?>> files}) inventory,
    Map<String, Object?> tmdb,
    Map<String, Object?> series,
  ) async {
    if (tmdb['state'] != 'pending' || tmdb['previous'] != null ||
        inventory.files.any((file) => file['category'] == 'main')) return false;
    final numbered = inventory.files.where((file) => file['extra_type'] == 'OVA' &&
        file['episode'] is int).toList();
    final numbers = numbered.map((file) => file['episode']).toSet();
    if (numbered.length > 6 || numbers.length != 2 ||
        !numbers.contains(1) || !numbers.contains(2) ||
        numbered.any((file) => file['category'] != 'extra' || file['file_group'] != null ||
            file['content_state'] != 'current' ||
            p.posix.dirname(file['relative_path'] as String) != inventory.folder ||
            !_ovaFormat.hasMatch(file['name'] as String))) {
      return false;
    }
    final work = lease.workId!;
    final bgRow = await _row(tasks.db, _id(work, 'bangumi', 'work', ''));
    final saved = adopted(bgRow ?? {});
    final premiere = saved?['year'];
    final subject = saved?['id'];
    final seriesId = series['id'];
    if (bgRow?['reason'] != 'verified_bangumi' || saved?['by'] != 'verified_bangumi' ||
        saved?['directory_title_matches'] != true || saved?['exact'] != true ||
        premiere is! int || subject is! int || seriesId is! int ||
        (year != null && premiere != year) || series['year'] is! int ||
        (series['year'] as int) <= premiere) {
      return false;
    }
    late final List<Map<String, Object?>> chapters;
    try {
      final bg = await _get(metadataResource('bangumi', 'subjects/$subject'), lease);
      final original = bg['name'];
      final aliases = PersonalMetadataScraper.officialTitles(bg);
      if (bg['id'] != subject || bg['type'] != 2 || bg['platform'] != 'OVA' ||
          bg['eps'] != 2 || _year(bg) != premiere || original is! String ||
          !aliases.any((alias) => _sameLocalTitle(alias, title))) return false;
      final localTitles = {
        for (final alias in aliases) _movieTitle(alias.replaceAll(_ovaFormat, ' ')),
        for (final alias in aliases)
          if (RegExp(r'[A-Za-z][A-Za-z _-]+$').firstMatch(alias.replaceAll(_ovaFormat, '').trim())
              case final suffix?) _movieTitle(suffix[0]!),
      }..removeWhere((value) => value.length < 8);
      for (final file in numbered) {
        final filename = file['name'] as String;
        final fileYear = Catalog.year(filename);
        if (WorkSeason.conflictingYears({'title': filename}) ||
            (fileYear != null && fileYear != premiere) ||
            ![
              PersonalFilenameParser.extractAnimeSearchKeyword(filename, episodeNumber: file['episode'] as int),
              ...PersonalFilenameParser.bracketTitleCandidates(filename),
            ].any((name) => localTitles.contains(_movieTitle(name.replaceAll(_ovaFormat, ' '))))) {
          return false;
        }
      }
      final independent = await Future.wait([
        _search(lease, 'tmdb', raw, title, premiere, const {}, const {'movie'},
            [original], filenameFallback: true, movieReleaseYear: premiere),
        _search(lease, 'tmdb', raw, title, premiere, const {}, const {'tv'},
            [original], filenameFallback: true, tvPremiereYear: premiere),
      ]);
      if (independent.any((result) => result.reason != 'no_match')) return false;
      final tv = await _get(metadataResource('tmdb', 'tv/$seriesId'), lease);
      final season = (tv['seasons'] as List? ?? []).whereType<Map>()
          .where((row) => row['season_number'] == 0).singleOrNull;
      if (tv['id'] != seriesId || _year(tv) != series['year'] || season == null ||
          !PersonalMetadataScraper.officialTitles(tv).any((alias) =>
              _sameLocalTitle(alias.split(RegExp(r'[~〜～:：]')).first.trim(), original))) {
        return false;
      }
      final ova = await _fetchChapters(lease, 'bangumi', id: subject, regularOnly: true,
          languageOverride: 'ja-JP');
      final specials = await _fetchChapters(lease, 'tmdb', id: seriesId,
          season: 0, languageOverride: 'ja-JP');
      if (!ova.complete || ova.chapters.length != 2 ||
          !specials.complete || specials.chapters.length != season['episode_count'] ||
          specials.chapters.any((chapter) =>
              _ovaFormat.hasMatch(_originalChapterTitle(chapter)) &&
              DateTime.tryParse('${chapter['date']}') == null)) return false;
      final bgChapters = ova.chapters..sort((a, b) => (a['sort'] as num).compareTo(b['sort'] as num));
      chapters = specials.chapters.where((chapter) =>
          DateTime.tryParse('${chapter['date']}')?.year == premiere).toList()
        ..sort((a, b) => (a['sort'] as num).compareTo(b['sort'] as num));
      if (chapters.length != 2 || chapters.first['sort'] is! int ||
          !_positive(chapters.first['sort']) || chapters.last['sort'] != (chapters.first['sort'] as int) + 1 ||
          chapters.first['id'] == chapters.last['id']) return false;
      final volume = RegExp(r'^(上|下)(?:巻|卷|編|篇)?$');
      for (final (index, chapter) in chapters.indexed) {
        final local = bgChapters[index];
        final name = _originalChapterTitle(chapter);
        final half = index == 0 ? '上' : '下';
        final bgDate = DateTime.tryParse('${local['date']}');
        final tvDate = DateTime.tryParse('${chapter['date']}')!;
        if (local['sort'] != index + 1 || local['type'] != 0 ||
            !_ovaFormat.hasMatch(name) ||
            volume.firstMatch(name.replaceAll(_ovaFormat, '').trim())?[1] != half ||
            volume.firstMatch(_originalChapterTitle(local).trim())?[1] != half ||
            bgDate == null || bgDate.year != premiere) return false;
        // The upper volume may have a limited release before general sale.
        // The lower volume must independently match the exact date.
        final lead = bgDate.difference(tvDate).inDays;
        if (index == 0 ? lead < 0 || lead > 45 : lead != 0) return false;
      }
      bool ordered(List<Map<String, Object?>> pair) => DateTime.parse(pair.first['date'] as String)
          .isBefore(DateTime.parse(pair.last['date'] as String));
      if (!ordered(chapters) || !ordered(bgChapters)) {
        return false;
      }
    } on MetadataFailure {
      return false;
    }
    var applied = false;
    await tasks.commit(lease, (tx) async {
      final protection = (await tx.query('library_work_protection',
          where: 'work_id=?', whereArgs: [work])).single;
      final latest = await _workFiles(tx, work);
      if (protection['identity_locked'] == 1 || protection['legacy_lock'] == 1 ||
          latest.folder != inventory.folder || jsonEncode(latest.files) != jsonEncode(inventory.files) ||
          (await _row(tx, tmdb['id'] as String))?['revision'] != tmdb['revision'] ||
          (await _row(tx, bgRow!['id'] as String))?['revision'] != bgRow['revision'] ||
          (await tx.rawQuery('''
            SELECT 1 FROM scan_bindings WHERE work_id=? AND provider='tmdb' AND layer!='work'
                AND (state!='pending' OR previous IS NOT NULL)
            UNION ALL SELECT 1 FROM asset_overrides o JOIN assets a ON a.id=o.asset_id WHERE a.work_id=?
            LIMIT 1
          ''', [work, work])).isNotEmpty) return {'ova_specials': false};
      final targets = await catalog.mappingStore!.subjectTargets(tx, subject);
      if (const {'excluded', 'conflict'}.contains(targets.state) ||
          targets.targets.any((target) => target['type'] != 'tv' || target['id'] != seriesId ||
              target['season'] != null && target['season'] != 0)) {
        return {'ova_specials': false};
      }
      const reason = 'verified_ova_specials';
      // The series ID locates the S0 chapters. Its regular-season poster and
      // synopsis describe a different release.
      final choice = {
        'id': seriesId, 'type': 'tv', 'title': saved!['title'], 'year': premiere, 'exact': true,
      };
      await _put(tx, work, 'tmdb', 'work', '', choices: [choice], reason: 'verify_candidate');
      final identity = (await _row(tx, tmdb['id'] as String))!;
      await _saveDecision(tx, identity, choice, reason: reason, by: reason);
      final current = (await _row(tx, tmdb['id'] as String))!;
      await _put(tx, work, 'tmdb', 'range', '', parent: _token(current));
      final range = (await _row(tx, _id(work, 'tmdb', 'range', '')))!;
      final first = chapters.first['sort'] as int;
      await _saveDecision(tx, range, {
        'season': 0, 'first': first, 'last': chapters.last['sort'], 'offset': first - 1,
        'chapters': chapters,
      }, reason: reason, by: reason);
      final adoptedRange = (await _row(tx, range['id'] as String))!;
      for (final file in numbered) {
        final asset = file['id'] as String;
        final volume = file['episode'] as int;
        final chapter = chapters[volume - 1];
        final episode = {
          'season': 0, 'episode': chapter['sort'], 'title': chapter['title'], 'chapter_id': chapter['id'],
        };
        final unique = numbered.where((row) => row['episode'] == volume).length == 1;
        await _put(tx, work, 'tmdb', 'episode', asset, asset: asset, parent: _token(adoptedRange),
            reason: 'episode_unconfirmed', choices: [episode]);
        if (unique) {
          final row = (await _row(tx, _id(work, 'tmdb', 'episode', asset)))!;
          await _saveDecision(tx, row, episode, reason: reason, by: reason);
        }
      }
      await ScopedArtwork.publishDrafts(catalog, tx, work);
      applied = true;
      return {'ova_specials': true};
    });
    if (applied) await catalog.reload();
    return true;
  }

  static int? _subjectRuntime(Map subject) {
    final infobox = subject['infobox'];
    if (infobox is! List) return null;
    final value = infobox.whereType<Map>().where((item) =>
        const {'片长', '片長', '尺', 'runtime', 'duration'}
            .contains(item['key']?.toString().toLowerCase())).singleOrNull?['value'];
    final minutes = RegExp(r'^\s*(\d{1,3})\s*(?:分钟|分鐘|分(?:間)?|minutes?|mins?)\s*$',
        caseSensitive: false).firstMatch('$value')?[1];
    return int.tryParse(minutes ?? '');
  }

  Future<bool> _recognizeStandaloneVideo(
    TaskLease lease,
    String raw,
    String title,
    int? directoryYear,
    ({String folder, List<Map<String, Object?>> files}) inventory,
    Map<String, Object?> tmdb,
  ) async {
    final file = inventory.files.singleOrNull;
    if (tmdb['state'] != 'pending' || tmdb['previous'] != null ||
        file == null || file['category'] != 'extra' || file['file_group'] != null ||
        file['episode'] != null || file['content_state'] != 'current' ||
        p.posix.dirname(file['relative_path'] as String) != inventory.folder ||
        CloudMediaFileClassifier.isSupplementaryDirectory(p.posix.basename(inventory.folder))) {
      return false;
    }
    final filename = file['name'] as String;
    final name = PersonalFilenameParser.extractAnimeSearchKeyword(filename);
    final compilationMarkers = _compilationMarker.allMatches(name).length;
    final compilation = compilationMarkers == 1;
    if (compilationMarkers > 1 || (!compilation && !_ovaMarker.hasMatch(name)) ||
        CloudMediaFileClassifier.isPreview(name) || _moviePromotionSuffix.hasMatch(name) ||
        WorkSeason.conflictingYears({'title': filename})) {
      return false;
    }
    final fileYear = Catalog.year(filename);
    if (fileYear != null && directoryYear != null && fileYear != directoryYear) return false;
    final year = directoryYear ?? fileYear;
    // Keep the subtitle intact. Removing a format label must not reduce the
    // evidence to the parent series name.
    final format = compilation ? _compilationMarker : _ovaFormat;
    String releaseTitle(String value) =>
        value.replaceAll(format, ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    final query = releaseTitle(name);
    final key = _movieTitle(query);
    if (key.length < 5) return false;

    final work = lease.workId!;
    final bangumi = await _row(tasks.db, _id(work, 'bangumi', 'work', ''));
    if (bangumi == null || bangumi['previous'] != null) return false;
    final oldSubject = adopted(bangumi);
    if (bangumi['state'] != 'pending' &&
        (bangumi['reason'] != 'verified_bangumi' || oldSubject?['by'] != 'verified_bangumi' ||
            oldSubject?['exact'] != true || oldSubject?['directory_title_matches'] != true)) {
      return false;
    }
    late final Map<String, Object?> subject, movie;
    try {
      var candidate = oldSubject;
      if (candidate == null) {
        final found = await _search(lease, 'bangumi', raw, title, year, const {}, const {}, [query],
            filenameFallback: true, firstBangumiPage: true, liveBangumiOnly: true);
        if (found.reason != 'verify_candidate') return false;
        candidate = found.choices.single;
      }
      final bg = await _get(metadataResource('bangumi', 'subjects/${candidate['id']}'), lease);
      final original = bg['name'];
      final premiere = _year(bg);
      final minutes = _subjectRuntime(bg);
      final aliases = PersonalMetadataScraper.officialTitles(bg);
      final platform = bg['platform'];
      if (bg['id'] != candidate['id'] || bg['type'] != 2 ||
          !(platform == 'OVA' || compilation && const {'剧场版', '劇場版', 'Movie'}.contains(platform)) ||
          bg['eps'] != 1 || premiere == null || (year != null && year != premiere) ||
          (compilation && (minutes == null || minutes < 40)) ||
          original is! String || _movieTitle(releaseTitle(original)) != key ||
          !aliases.any((alias) => _sameLocalTitle(alias, title))) {
        return false;
      }
      final found = await _search(lease, 'tmdb', raw, title, premiere, const {}, const {'movie'},
          [original], filenameFallback: true, movieReleaseYear: premiere);
      if (!const {'verify_candidate', 'conflicting_title'}.contains(found.reason)) return false;
      final choice = found.choices.singleOrNull;
      if (choice == null) return false;
      final detail = await _get(metadataResource('tmdb', 'movie/${choice['id']}',
          parameters: {if (compilation) 'append_to_response': 'keywords'}), lease);
      final genres = detail['genres'];
      final tags = detail['keywords'];
      final keywords = tags is Map ? tags['keywords'] : null;
      final runtime = detail['runtime'];
      if (detail['id'] != choice['id'] || _year(detail) != premiere ||
          detail['original_title'] is! String ||
          _movieTitle(releaseTitle(detail['original_title'] as String)) != key ||
          runtime is! int || runtime < (compilation ? 40 : 10) ||
          (minutes != null && (minutes - runtime).abs() > (compilation ? 0 : 1)) ||
          genres is! List || !genres.whereType<Map>().any((genre) => genre['id'] == 16) ||
          compilation && (keywords is! List || !keywords.whereType<Map>().any((tag) =>
              const {'compilation', 'edited from tv series', 'recap'}
                  .contains(tag['name']?.toString().toLowerCase())))) {
        return false;
      }
      final episodes = await _fetchChapters(lease, 'bangumi',
          id: candidate['id'] as int, regularOnly: true);
      if (!episodes.complete || episodes.chapters.singleOrNull?['sort'] != 1 ||
          episodes.chapters.singleOrNull?['type'] != 0) {
        return false;
      }
      subject = {
        ...candidate, 'movie': true, 'year': premiere, 'aliases': aliases.toList(),
        if (minutes != null) 'runtime': minutes,
        'title': _title(bg), 'summary': bg['summary'],
      };
      movie = {
        ...choice, 'exact': true, 'runtime': runtime,
        if (detail['backdrop_path'] is String) 'backdrop_path': detail['backdrop_path'],
      };
    } on MetadataFailure {
      return false;
    }
    var applied = false;
    await tasks.commit(lease, (tx) async {
      final protection = (await tx.query('library_work_protection',
          where: 'work_id=?', whereArgs: [work])).single;
      final latest = await _workFiles(tx, work);
      if (protection['identity_locked'] == 1 || protection['legacy_lock'] == 1 ||
          latest.folder != inventory.folder || jsonEncode(latest.files) != jsonEncode(inventory.files) ||
          (await _row(tx, tmdb['id'] as String))?['revision'] != tmdb['revision'] ||
          (await _row(tx, bangumi['id'] as String))?['revision'] != bangumi['revision'] ||
          (await tx.rawQuery('''
            SELECT 1 FROM scan_bindings WHERE work_id=? AND layer!='work'
                AND (state!='pending' OR previous IS NOT NULL)
            UNION ALL SELECT 1 FROM asset_overrides WHERE asset_id=?
            LIMIT 1
          ''', [work, file['id']])).isNotEmpty) {
        return {'standalone_video': false};
      }
      final mapping = await catalog.mappingStore!.subjectTargets(tx, subject['id'] as int);
      if (const {'excluded', 'conflict'}.contains(mapping.state) ||
          mapping.targets.any((target) => target['type'] != 'movie' || target['id'] != movie['id'])) {
        return {'standalone_video': false};
      }
      await tx.update('assets', {'category': 'main', 'season': 1, 'extra_type': null},
          where: 'id=?', whereArgs: [file['id']]);
      await tx.delete('scan_bindings', where: "work_id=? AND layer!='work' AND state='pending'",
          whereArgs: [work]);
      for (final provider in providers) {
        final identity = provider == 'tmdb' ? tmdb : bangumi;
        final choice = provider == 'tmdb' ? movie : subject;
        final reason = compilation ? 'verified_standalone_compilation' : 'verified_standalone_ova';
        await tx.update('scan_bindings', {'candidates': jsonEncode([choice])},
            where: 'id=?', whereArgs: [identity['id']]);
        await _saveDecision(tx, identity, choice, reason: reason, by: reason);
      }
      await ScopedArtwork.publishDrafts(catalog, tx, work);
      applied = true;
      return {'standalone_video': true};
    });
    if (applied) await catalog.reload();
    return true;
  }

  Future<bool> _recognizeCompetingAnimatedMovies(
    TaskLease lease,
    String raw,
    String title,
    int? directoryYear,
    ({String folder, List<Map<String, Object?>> files}) inventory,
    Map<String, Map<String, Object?>> pending,
    List<Map<String, Object?>> choices,
    List<Map<String, Object?>> subjects,
  ) async {
    if (pending.length != providers.length || pending.values.any(
        (row) => row['state'] != 'pending' || row['previous'] != null) ||
        RegExp(r'\{bangumi-\d+\}', caseSensitive: false).hasMatch(raw) ||
        choices.where((row) => row['type'] == 'movie').map((row) => row['year'])
            .whereType<int>().toSet().length < 2) {
      return false;
    }
    final main = inventory.files.where((file) => file['category'] == 'main').singleOrNull;
    if (main == null || main['file_group'] != null || main['episode'] != null) return false;
    final filename = main['name'] as String;
    final releaseName = PersonalFilenameParser.extractAnimeSearchKeyword(filename);
    if (!RegExp(r'^(?:劇場版|剧场版|映画|电影|Gekijouban\b)\s*\S', caseSensitive: false)
        .hasMatch(releaseName)) {
      return false;
    }
    final fileYear = Catalog.year(filename);
    if (WorkSeason.conflictingYears({'title': filename}) ||
        (fileYear != null && directoryYear != null && fileYear != directoryYear)) {
      return false;
    }
    final year = directoryYear ?? fileYear;
    final verifiedSubject = await _narrowBangumiPremiere(
      lease, raw, title, year, subjects, filmFile: filename,
    );
    if (verifiedSubject == null) return false;
    final subject = verifiedSubject.choices.single;
    final original = subject['original_title'] as String;
    final premiereYear = subject['year'] as int;
    final proposed = _verifiedMovieCandidate(choices, inventory.files, title, year, subject);
    if (proposed == null) return false;
    final narrowed = await _search(lease, 'tmdb', raw, title, premiereYear, const {},
        const {'movie'}, [original], filenameFallback: true, movieReleaseYear: premiereYear);
    if (!const {'verify_candidate', 'conflicting_title'}.contains(narrowed.reason)) return false;
    final movie = _verifiedMovieCandidate(narrowed.choices, inventory.files, title, year, subject);
    if (movie == null || movie['id'] != proposed['id']) return false;
    Map<String, dynamic> detail;
    try {
      detail = await _get(metadataResource('tmdb', 'movie/${movie['id']}'), lease);
    } on MetadataFailure {
      return false;
    }
    // Providers can record different territorial premieres. Require the same
    // year, original title and animation format, with unique live candidates.
    final tmdbOriginal = detail['original_title'];
    final genres = detail['genres'];
    if (detail['id'] != movie['id'] || _year(detail) != premiereYear ||
        tmdbOriginal is! String || _movieTitle(tmdbOriginal) != _movieTitle(original) ||
        genres is! List || !genres.whereType<Map>().any((genre) => genre['id'] == 16)) {
      return false;
    }
    final work = lease.workId!;
    var bound = false;
    await tasks.commit(lease, (tx) async {
      final protection = (await tx.query('library_work_protection',
          where: 'work_id=?', whereArgs: [work])).single;
      if (protection['identity_locked'] == 1 || protection['legacy_lock'] == 1) {
        return {'corrected': false};
      }
      for (final row in pending.values) {
        if ((await _row(tx, row['id'] as String))?['revision'] != row['revision']) {
          return {'corrected': false};
        }
      }
      final latest = await _workFiles(tx, work);
      if (latest.folder != inventory.folder || jsonEncode(latest.files) != jsonEncode(inventory.files) ||
          (await tx.rawQuery('''
            SELECT 1 FROM scan_bindings WHERE work_id=? AND layer!='work'
                AND (state!='pending' OR previous IS NOT NULL)
            UNION ALL SELECT 1 FROM asset_overrides WHERE asset_id=?
            LIMIT 1
          ''', [work, main['id']])).isNotEmpty) {
        return {'corrected': false};
      }
      final mapping = await catalog.mappingStore!.subjectTargets(tx, subject['id'] as int);
      if (const {'excluded', 'conflict'}.contains(mapping.state) ||
          mapping.targets.any((target) => target['type'] != 'movie' || target['id'] != movie['id'])) {
        return {'corrected': false};
      }
      for (final provider in providers) {
        final choice = provider == 'tmdb' ? {
          ...movie,
          if (detail['backdrop_path'] is String) 'backdrop_path': detail['backdrop_path'],
        } : subject;
        const reason = 'verified_movie';
        await _put(tx, work, provider, 'work', '', choices: [choice], reason: 'verify_candidate');
        final row = (await _row(tx, pending[provider]!['id'] as String))!;
        await _saveDecision(tx, row, choice, reason: reason, by: reason);
        await _syncChildren(tx, work, provider);
      }
      await ScopedArtwork.publishDrafts(catalog, tx, work);
      bound = true;
      return {'corrected': true};
    });
    if (bound) await catalog.reload();
    return true;
  }

  Future<bool> _recognizeMarkedMovie(
    TaskLease lease,
    String raw,
    String title,
    int? year,
    ({String folder, List<Map<String, Object?>> files}) inventory,
    Map<String, Map<String, Object?>> pending,
    List<Map<String, Object?>>? recheck,
  ) async {
    if (pending.length != providers.length) return false;
    final work = lease.workId!;
    final protection = (await tasks.db.query('library_work_protection',
        where: 'work_id=?', whereArgs: [work])).single;
    if (protection['identity_locked'] == 1 || protection['legacy_lock'] == 1) return true;

    Map<String, Object?>? matchingSubject(List<Map<String, Object?>> choices) =>
        choices.where((choice) => (choice['aliases'] as List).whereType<String>()
            .any((name) => _sameLocalTitle(name, title))).singleOrNull;
    final bangumi = await _search(lease, 'bangumi', raw, title, year, {}, {}, [title],
        firstBangumiPage: true);
    final subject = matchingSubject(bangumi.choices);
    final main = inventory.files.where((file) => file['category'] == 'main').singleOrNull;
    final filename = main == null ? '' :
        PersonalFilenameParser.extractAnimeSearchKeyword(main['name'] as String);
    final release = RegExp(
      r'^(?:Gekijouban|劇場版|剧场版|映画|电影)\s*(.+)$', caseSensitive: false,
    ).firstMatch(filename);
    final alternateTitles = <String>[];
    // Some catalogs label a double feature by one of its two subtitles.
    final parts = RegExp(r'^(.+?)\s+-\s*(.+?)\s+&\s+(.+?)\s*-?$')
        .firstMatch(filename);
    if (parts != null) {
      alternateTitles.addAll(['${parts[1]} ${parts[2]}', '${parts[1]} ${parts[3]}']);
    }
    var bgChoices = bangumi.choices;
    var tmdbChoices = <Map<String, Object?>>[];
    var bgReason = bangumi.reason;
    var tmdbReason = 'conflicting_title';
    Map<String, Object?>? movie;
    Map<String, Object?>? filmSubject;
    if (subject != null && release != null &&
        !WorkSeason.conflictingYears({'title': raw})) {
      try {
        final details = await _get(metadataResource('bangumi', 'subjects/${subject['id']}'), lease);
        final original = details['name'];
        final premiere = DateTime.tryParse('${details['date']}');
        if (details['id'] == subject['id'] && details['type'] == 2 &&
            const {'剧场版', '劇場版', '电影', '映画', 'Movie'}.contains(details['platform']) &&
            original is String && premiere != null && (year == null || year == premiere.year) &&
            PersonalMetadataScraper.officialTitles(details).any((name) => _sameLocalTitle(name, title))) {
          final narrowed = workQueryIncomplete(bangumi.reason)
              ? await _search(lease, 'bangumi', raw, title, premiere.year, {}, {}, [title],
                  firstBangumiPage: true, bangumiAirDates: _bangumiPremiereWindow(premiere))
              : bangumi;
          bgReason = narrowed.reason;
          if (!workQueryIncomplete(narrowed.reason) &&
              matchingSubject(narrowed.choices)?['id'] == subject['id']) {
            filmSubject = {...subject, 'movie': true, 'year': premiere.year,
              'title': _title(details), 'summary': details['summary']};
            bgChoices = [filmSubject];
            final found = await _search(lease, 'tmdb', raw, title, premiere.year, {}, {'movie'},
                [original, filename, ...alternateTitles], filenameFallback: true);
            tmdbChoices = found.choices;
            tmdbReason = found.reason;
            if (!workQueryIncomplete(found.reason) && found.reason != 'ambiguous') {
              movie = tmdbChoices.where((choice) {
                final aliases = (choice['aliases'] as List).whereType<String>();
                final tmdbDate = DateTime.tryParse('${choice['release_date']}');
                final sameRelease = tmdbDate != null &&
                    tmdbDate.difference(premiere).abs() <= const Duration(days: 3);
                return choice['year'] == premiere.year &&
                    aliases.any((alias) => _movieTitle(alias.split(RegExp(r'\s+-\s*|[:：]')).first) ==
                        _movieTitle(original)) &&
                    (aliases.any((alias) => _sameLocalTitle(alias, filename)) ||
                        sameRelease && aliases.any((alias) =>
                            alternateTitles.any((hint) => _sameLocalTitle(alias, hint))));
              }).singleOrNull;
            }
          }
        }
      } on MetadataFailure {
        bgReason = 'request_failed';
      }
    }
    final verified = movie != null && filmSubject != null;
    if (!verified && recheck == null) return false;
    await tasks.commit(lease, (tx) async {
      final currentProtection = (await tx.query('library_work_protection',
          where: 'work_id=?', whereArgs: [work])).single;
      if (jsonEncode(currentProtection) != jsonEncode(protection)) {
        return {'corrected': false};
      }
      final latest = await _workFiles(tx, work);
      if (latest.folder != inventory.folder || jsonEncode(latest.files) != jsonEncode(inventory.files)) {
        return {'corrected': false};
      }
      if (recheck != null && (!verified ||
          jsonEncode(await _automaticConflict(tx, work)) != jsonEncode(recheck))) {
        return {'corrected': false};
      }
      for (final row in pending.values) {
        if ((await _row(tx, row['id'] as String))?['revision'] != row['revision']) {
          return {'corrected': false};
        }
      }
      if (recheck != null && main != null) {
        await tx.delete('scan_bindings', where: "work_id=? AND layer!='work' AND state='pending'",
            whereArgs: [work]);
        if (main['episode'] != null && Catalog.episode(main['name'] as String) == null) {
          await tx.rawUpdate('''UPDATE assets SET episode=NULL WHERE id=? AND episode=?
            AND NOT EXISTS (SELECT 1 FROM asset_overrides o WHERE o.asset_id=assets.id)''',
              [main['id'], main['episode']]);
        }
      }
      for (final provider in providers) {
        final tmdb = provider == 'tmdb';
        final choices = tmdb ? tmdbChoices : bgChoices;
        final previous = pending[provider]!;
        if (recheck == null) {
          final reason = tmdb ? tmdbReason : bgReason;
          await _put(tx, work, provider, 'work', '', choices: choices,
              reason: workQueryIncomplete(reason) ? reason : 'conflicting_title');
        } else {
          await tx.update('scan_bindings', {'candidates': jsonEncode(choices)},
              where: 'id=?', whereArgs: [previous['id']]);
        }
        if (verified) {
          final row = (await _row(tx, previous['id'] as String))!;
          const reason = 'verified_movie';
          await _saveDecision(tx, row, tmdb ? movie : filmSubject, reason: reason, by: reason);
          await _syncChildren(tx, work, provider);
        }
      }
      if (verified) await ScopedArtwork.publishDrafts(catalog, tx, work);
      return {'corrected': verified};
    });
    if (verified) await catalog.reload();
    return true;
  }

  static int? _singleMoviePremiereYear(
    Map<String, Object?> movie,
    List<Map<String, Object?>> files,
    int? folderYear,
    {Map<String, Object?>? subject}
  ) {
    final file = files.where((f) => f['category'] == 'main').singleOrNull;
    if (file == null || file['content_state'] != 'current' || file['file_group'] != null) return null;
    final name = file['name'] as String;
    if (_explicitFileSeason(name) != null || _dualEpisodeNumber(name) != null ||
        RegExp(r'[&＋+＆]').hasMatch(PersonalFilenameParser.extractAnimeSearchKeyword(name))) return null;
    if (movie['marker'] == true && folderYear != null && file['episode'] == null) return folderYear;
    final film = RegExp(r'\b(?:the[ ._-]+)?(?:movie|film)\b|剧场版|劇場版',
        caseSensitive: false).hasMatch(name);
    final year = Catalog.year(name);
    if (!film || year != null && folderYear != null && year != folderYear) return null;
    if (year != null) return year;
    if (subject == null || file['episode'] != null) return null;
    // Releases often insert an English format label into an otherwise exact
    // alias. Only infer the year from provider evidence when the full alias
    // still matches after removing that label.
    final clue = PersonalFilenameParser.extractAnimeSearchKeyword(name);
    final local = _movieTitleWithoutFormat(clue);
    final exactAlias = local.length >= 8 &&
        [...(movie['aliases'] as List? ?? []), ...(subject['aliases'] as List? ?? [])]
            .whereType<String>().any((alias) => _movieTitleWithoutFormat(alias) == local);
    return exactAlias ? folderYear ?? subject['year'] as int? : null;
  }

  Future<bool> _verifyStoredMoviePair(
    TaskLease lease, String title, int? year,
    ({String folder, List<Map<String, Object?>> files}) inventory,
    Map<String, Object?> tmdb, Map<String, Object?> bangumi,
  ) async {
    if ([tmdb, bangumi].any((row) => row['state'] != 'pending' ||
        row['reason'] != 'verify_candidate' || row['previous'] != null)) return false;
    final subject = candidates(bangumi).singleOrNull;
    final movie = candidates(tmdb).singleOrNull;
    if (subject == null || movie?['type'] != 'movie' || movie?['exact'] != true) return false;
    final file = inventory.files.where((f) => f['category'] == 'main').singleOrNull;
    if (file == null || file['episode'] != null ||
        !RegExp(r'\b(?:movie|film)\b|剧场版|劇場版', caseSensitive: false)
            .hasMatch(file['name'] as String)) return false;
    final verified = await _verifyMoviePremiere(
        lease, [movie!], inventory.files, title, year, subject, refreshMovie:true);
    if (verified == null) return false;
    final work = lease.workId!;
    var applied = false;
    await tasks.commit(lease, (tx) async {
      final protection = (await tx.query('library_work_protection',
          where:'work_id=?', whereArgs:[work])).single;
      final latest = await _workFiles(tx, work);
      if (protection['identity_locked'] == 1 || protection['legacy_lock'] == 1 ||
          latest.folder != inventory.folder || jsonEncode(latest.files) != jsonEncode(inventory.files) ||
          (await _row(tx, tmdb['id'] as String))?['revision'] != tmdb['revision'] ||
          (await _row(tx, bangumi['id'] as String))?['revision'] != bangumi['revision'] ||
          (await tx.query('scan_bindings', columns:['id'],
              where:"work_id=? AND layer!='work' AND (state!='pending' OR previous IS NOT NULL)",
              whereArgs:[work],limit:1)).isNotEmpty) {
        return {'verified_movie_pair':false};
      }
      final mapping = await catalog.mappingStore!.subjectTargets(tx, subject['id'] as int);
      if (const {'excluded', 'conflict'}.contains(mapping.state) ||
          mapping.targets.any((target) => target['type'] != 'movie' || target['id'] != verified['id'])) {
        return {'verified_movie_pair':false};
      }
      await _saveDecision(tx, tmdb, verified, reason:'verified_tmdb', by:'verified_tmdb');
      await _saveDecision(tx, bangumi, {...subject,'movie':true},
          reason:'verified_bangumi', by:'verified_bangumi');
      await _syncMovieAttachments(tx, work);
      await ScopedArtwork.publishDrafts(catalog, tx, work);
      applied = true;
      return {'verified_movie_pair':true};
    });
    if (applied) await catalog.reload();
    return true;
  }

  Future<Map<String, Object?>?> _verifyMoviePremiere(
    TaskLease lease,
    List<Map<String, Object?>> choices,
    List<Map<String, Object?>> files,
    String directoryTitle,
    int? folderYear,
    Map<String, Object?> subject, {
    bool refreshMovie = false,
  }
  ) async {
    var movie = choices.where((choice) => choice['type'] == 'movie').singleOrNull;
    if (movie == null || subject['exact'] != true ||
        (subject['directory_title_matches'] != true &&
            !_sameLocalTitle(_movieTitle('${subject['title']}'), _movieTitle(directoryTitle))) ||
        choices.any((c) => c['type'] == 'tv' && c['title_matches'] == true)) return null;
    final original = movie['original_title'];
    final release = movie['release_date'];
    if (subject['id'] is! int || original is! String || release is! String ||
        _movieTitle(original).length < 4) return null;
    final file = files.where((f) => f['category'] == 'main').singleOrNull;
    if (file == null) return null;
    final clue = PersonalFilenameParser.extractAnimeSearchKeyword(file['name'] as String);
    try {
      var year = _singleMoviePremiereYear(movie, files, folderYear, subject: subject);
      if (refreshMovie || year == null && movie['exact'] == true && movie['id'] is int &&
          RegExp(r'\b(?:movie|film)\b', caseSensitive: false).hasMatch(file['name'] as String)) {
        if (movie['id'] is! int) return null;
        final details = await _get(metadataResource('tmdb', 'movie/${movie['id']}',
            parameters: {'append_to_response': 'alternative_titles,translations'}), lease);
        if (details['id'] != movie['id'] || details['original_title'] != original ||
            details['release_date'] != release) return null;
        movie = {...movie, 'aliases': {
          ...(movie['aliases'] as List? ?? []).whereType<String>(),
          ...PersonalMetadataScraper.officialTitles(details),
        }.toList()};
        year = _singleMoviePremiereYear(movie, files, folderYear, subject: subject);
      }
      if (year == null || movie['year'] != year || subject['year'] != year ||
          !release.startsWith('$year-') || !_movieFilenameCorroborates(clue, movie, subject)) return null;
      final live = await _get(metadataResource('bangumi', 'subjects/${subject['id']}'), lease);
      final name = live['name'];
      if (live['id'] != subject['id'] || live['type'] != 2 ||
          !const {'剧场版', '劇場版', 'Movie'}.contains(live['platform']) ||
          live['date'] != release || name is! String ||
          _movieTitle(name) != _movieTitle(original)) return null;
      return {...movie, 'exact': true, 'title_matches': true, 'verified_premiere': true};
    } on MetadataFailure {
      return null;
    }
  }

  static bool _movieFilenameCorroborates(String clue, Map movie, Map subject) {
    final normalized = _movieTitle(clue);
    if (normalized.length < 4) return false;
    final withoutFormat = _movieTitleWithoutFormat(clue);
    List<String> words(String name) => name.toLowerCase().replaceAll(RegExp("['’]"), '')
        .split(RegExp(r'[^a-z0-9]+')).where((s) => s.isNotEmpty).toList();
    final local = words(clue);
    if (local.lastOrNull == 'movie' || local.lastOrNull == 'film') local.removeLast();
    for (final alias in [
      ...(movie['aliases'] as List? ?? []).whereType<String>(),
      ...(subject['aliases'] as List? ?? []).whereType<String>(),
    ]) {
      if (normalized == _movieTitle(alias)) return true;
      if (withoutFormat.length >= 8 && withoutFormat == _movieTitleWithoutFormat(alias)) return true;
      final remote = words(alias);
      var shared = 0;
      while (shared < local.length && shared < remote.length &&
          local[local.length - shared - 1] == remote[remote.length - shared - 1]) {
        shared++;
      }
      // Accept a shortened release name when it preserves the full ending.
      // The premiere comparison independently checks the complete official name.
      if (shared >= 4 && local.length - shared <= 2 && remote.length - shared <= 2) return true;
    }
    return false;
  }

  static String _movieTitleWithoutFormat(String title) => _movieTitle(title.replaceAll(
      RegExp(r'\b(?:the[ ._-]+)?(?:movie|film)\b', caseSensitive: false), ' '));

  static Map<String, Object?>? _verifiedMovieCandidate(
    List<Map<String, Object?>> choices,
    List<Map<String, Object?>> files,
    String directoryTitle,
    int? directoryYear,
    Map<String, Object?>? bangumi,
  ) {
    if (!choices.any((choice) => choice['type'] == 'movie')) return null;
    final main = files.where((file) => file['category'] == 'main').toList();
    if (main.isEmpty || main.length > 6 || main.any((file) =>
        file['file_group'] != null || _explicitFileSeason(file['name'] as String) != null)) {
      return null;
    }
    // Distinct indexed episode numbers are evidence of an episodic release,
    // even when the remote catalog represents it as one movie.
    if (main.map((file) => file['episode']).whereType<int>().toSet().length > 1) return null;
    final subjectAliases = (bangumi?['aliases'] as List? ?? const []).whereType<String>()
        .map(_movieTitle).where((name) => name.length >= 4).toSet();
    final subjectYear = bangumi?['directory_title_matches'] == true ||
            subjectAliases.contains(_movieTitle(directoryTitle))
        ? (bangumi?['year'] as int?) : null;
    if (directoryYear != null && subjectYear != null && directoryYear != subjectYear) return null;
    final year = directoryYear ?? subjectYear;
    if (year == null) return null;
    if (choices.any((choice) => choice['type'] == 'tv' && choice['title_matches'] == true &&
        (choice['year'] == null || choice['year'] == year))) return null;
    final localTitles = [for (final file in main) _movieFileTitles(file['name'] as String, year)];
    final match = choices.where((choice) {
      if (choice['type'] != 'movie' || choice['year'] != year) return false;
      final movieAliases = (choice['aliases'] as List? ?? const []).whereType<String>()
          .map(_movieTitle).where((name) => name.length >= 4).toSet();
      final corroborated = subjectYear != null && movieAliases.intersection(subjectAliases).isNotEmpty;
      if (!corroborated && choice['marker'] != true) return false;
      final allowed = {
        ...(choice['aliases'] as List? ?? const []).whereType<String>().map(_movieReleaseTitle),
        if (corroborated)
          ...(bangumi?['aliases'] as List? ?? const []).whereType<String>().map(_movieReleaseTitle),
      }..removeWhere((name) => name.length < 4);
      return localTitles.every((variants) =>
          variants.any((titles) => titles.isNotEmpty && titles.every(allowed.contains)));
    }).singleOrNull;
    return match == null ? null : {...match, 'exact': true, 'title_matches': true};
  }

  static List<Set<String>> _movieFileTitles(String filename, int year) {
    final technical = RegExp(
      r'\s+(?:' '$year' r'|\d{3,4}[pi]|[248]k|BDRip|BluRay|WEB[ ._-]?DL)(?=\s|$)',
      caseSensitive: false,
    );
    final stem = PersonalFilenameParser.baseNameWithoutExtension(filename);
    final bracketed = stem.replaceFirst(RegExp(r'\([0-9a-fA-F]{8}\)$'), '');
    final dotted = RegExp(
      r'^(.+?)\.' '$year' r'\.\d{3,4}[pi](?:\.|$)', caseSensitive: false,
    ).firstMatch(stem)?[1];
    final dottedTitles = dotted?.split(RegExp(r'(?<=[\u3400-\u9fff])\.(?=[A-Za-z])'));
    return [
      for (final title in [
        PersonalFilenameParser.extractAnimeSearchKeyword(filename),
        ...PersonalFilenameParser.bracketTitleCandidates('$bracketed.mkv'),
      ])
        {_movieReleaseTitle(title.split(technical).first)},
      if (dottedTitles != null)
        dottedTitles.map(_movieReleaseTitle).toSet(),
    ];
  }

  static String _movieReleaseTitle(String value) => _movieTitle(value.replaceAllMapped(
      RegExp(r'\b0([1-9])(?=\s*[:：–—-]\s*\S)'), (match) => match[1]!));

  static String _movieTitle(String value) => PersonalMetadataScraper.normalize(
      value.replaceFirst(RegExp(r'^(?:劇場版|剧场版|电影|映画|Gekijouban\b)\s*', caseSensitive: false), '')
          .replaceAll(RegExp('[「」『』~～〜]'), ''));

  static bool _movieReleaseName(String filename, Map movie) {
    final name = PersonalFilenameParser.extractAnimeSearchKeyword(filename);
    if (!RegExp(r'^(?:Gekijouban|劇場版|剧场版)\s+', caseSensitive: false).hasMatch(name)) return false;
    final stem = name.replaceFirst(RegExp(r'^(?:Gekijouban|劇場版|剧场版)\s+', caseSensitive: false), '');
    if (PersonalMetadataScraper.normalize(stem).length < 8) return false;
    return (movie['aliases'] as List? ?? []).whereType<String>().any((alias) {
      // Keep the full subtitle for cross-platform identity verification above;
      // this bounded comparison only corroborates a marked movie release name.
      final parts = alias.split(RegExp(r'[:：~～〜]'));
      if (parts.length < 2) return false;
      final base = parts.first.replaceFirst(RegExp(r'\s+(?:the\s+)?movie$', caseSensitive: false), '');
      return PersonalMetadataScraper.exactTitle(stem, base);
    });
  }

  static String _chapterTitle(String value) => value.replaceAllMapped(
      RegExp(r'[０-９Ａ-Ｚａ-ｚ]'), (m) => String.fromCharCode(m[0]!.codeUnitAt(0) - 0xfee0))
      .replaceAll(RegExp('[♡❤♥]\\uFE0F?'), '♥')
      .replaceAll('‼', '!!').replaceAll('／', '/');

  static String _originalChapterTitle(Map chapter) =>
        _chapterTitle((chapter['verification_title'] ?? chapter['title']) as String)
            .replaceAll('從', '従')
            .replaceAll(RegExp(r'(?<=[\u3400-\u9fff])[（(][ァ-ヶー・]+[）)](?=[.…])'), '')
            .replaceAll(RegExp(r'…+|\.{3,}'), '…');

  static final _genericChapterTitle =
      RegExp(r'^(?:episode\s*|ep\s*|第\s*)?\d+(?:\s*[集話话])?$', caseSensitive: false);

  static bool _chapterAgreement(Map a, Map b, {bool allowReading = false}) {
    final title = _originalChapterTitle(a);
    final otherTitle = _originalChapterTitle(b);
    final date = DateTime.tryParse('${a['date'] ?? ''}');
    final otherDate = DateTime.tryParse('${b['date'] ?? ''}');
    return title.trim().length >= 2 &&
        !_genericChapterTitle.hasMatch(title.trim()) &&
        date != null &&
        otherDate != null &&
        date.difference(otherDate).abs() <= const Duration(days: 1) &&
        (PersonalMetadataScraper.exactTitle(title, otherTitle) ||
            allowReading && _sameChapterReading(title, otherTitle));
  }

  static bool _dualSeasonChapterAgreement(_TvEvidence evidence) {
    if (evidence.local.absoluteOffset == null || evidence.tv.length < 12) return false;
    final mismatch = evidence.tv.indexed.where((item) =>
        !_chapterAgreement(item.$2, evidence.bangumi[item.$1])).singleOrNull;
    if (mismatch == null) return false;
    final (index, chapter) = mismatch;
    final subject = evidence.bangumi[index];
    final translated = chapter['comparison_title_zh'] ??
        (evidence.language == 'zh-CN' ? chapter['title'] : null);
    final a = DateTime.tryParse('${chapter['date']}');
    final b = DateTime.tryParse('${subject['date']}');
    return translated is String && translated.trim().length >= 3 &&
        !_genericChapterTitle.hasMatch(translated.trim()) &&
        a != null && b != null && a.difference(b).abs().inDays <= 1 &&
        PersonalMetadataScraper.exactTitle(translated, '${subject['title']}') &&
        evidence.bangumi.where((row) =>
            PersonalMetadataScraper.exactTitle(translated, '${row['title']}')).length == 1;
  }

  static bool _sameSeasonTitlesWithDateDifferences(List<Map> tv, List<Map> bangumi) {
    if (tv.length < 12 || tv.length != bangumi.length) return false;
    final names = <String>{};
    final gaps = <int>[];
    for (var i = 0; i < tv.length; i++) {
      final original = _originalChapterTitle(tv[i]).trim();
      if (original.length < 2 || _genericChapterTitle.hasMatch(original) ||
          !PersonalMetadataScraper.exactTitle(original, _originalChapterTitle(bangumi[i])) ||
          !names.add(PersonalMetadataScraper.normalize(original))) {
        return false;
      }
      final a = DateTime.tryParse('${tv[i]['date']}');
      final b = DateTime.tryParse('${bangumi[i]['date']}');
      if (a == null || b == null) return false;
      gaps.add(a.difference(b).abs().inDays);
    }
    // Some providers use different broadcast dates. Accept this only for a
    // complete one-to-one sequence of distinct original titles in the same
    // broadcast window, allowing at most one larger date discrepancy.
    return gaps.first <= 7 && gaps.last <= 7 &&
        gaps.where((gap) => gap <= 7).length * 5 >= gaps.length * 4 &&
        gaps.where((gap) => gap > 14).length <= 1 &&
        gaps.every((gap) => gap <= 31);
  }

  static bool _sameChapterReading(String a, String b) {
    final reading = RegExp(r'^([ァ-ヶー・\s]{4,})[（(][^）)]+[）)]\s*$');
    final first = reading.firstMatch(a)?.group(1);
    final second = reading.firstMatch(b)?.group(1);
    return first != null && second != null && PersonalMetadataScraper.exactTitle(first, second);
  }

  // A complete season can corroborate isolated metadata transcription errors.
  // Never apply this tolerance to identity search, short specials or reordering.
  static bool _seasonChapterAgreement(List<Map<String, Object?>> tv,
      List<Map<String, Object?>> bg) {
    if (tv.length != bg.length || tv.length < 12) return false;
    final strict = tv.indexed.where((p) => _chapterAgreement(p.$2, bg[p.$1])).length;
    if (strict < 10 || tv.length - strict > 2) return false;
    String title(Map row) => PersonalFilenameParser.normalizeIdentity(
        _chapterTitle('${row['verification_title'] ?? row['title']}'))
        .replaceAll(RegExp('[「」『』]'), '');
    bool near(Map a, Map b) {
      if (_chapterAgreement(a, b)) return true;
      final first = title(a), second = title(b);
      final date = DateTime.tryParse('${a['date']}');
      final otherDate = DateTime.tryParse('${b['date']}');
      if (date == null || otherDate == null) return false;
      if (first == second && first.length >= 5) {
        return date.difference(otherDate).abs() <= const Duration(days: 3);
      }
      if (date != otherDate) return false;
      final shorter = first.length < second.length ? first : second;
      final longer = first.length < second.length ? second : first;
      final missing = longer.length - shorter.length;
      if (shorter.length < 5 || missing < 1 || missing > 2) return false;
      // One contiguous omission, not arbitrary fuzzy similarity.
      for (var i = 0; i <= shorter.length; i++) {
        if (longer.substring(0, i) + longer.substring(i + missing) == shorter) return true;
      }
      return false;
    }
    for (var i = 0; i < tv.length; i++) {
      if (!near(tv[i], bg[i]) ||
          bg.where((row) => near(tv[i], row)).length != 1 ||
          tv.where((row) => near(row, bg[i])).length != 1) {
        return false;
      }
    }
    return true;
  }

  static bool _discSeasonOrder(List<Map<String, Object?>> tv,
      List<Map<String, Object?>> bg, int year) {
    if (tv.length != bg.length || tv.length < 12) return false;
    final start = DateTime(year), end = DateTime(year + 1);
    for (final chapters in [tv, bg]) {
      final dates = chapters.map((c) => DateTime.tryParse('${c['date']}')).toList();
      if (dates.any((d) => d == null || d.isBefore(start.subtract(const Duration(days: 7))) || !d.isBefore(end)) ||
          dates.where((d) => d!.isBefore(start)).length > 2) {
        return false;
      }
    }
    String title(Map row) => PersonalFilenameParser.normalizeIdentity(
        _chapterTitle('${row['verification_title'] ?? row['title']}'));
    final reordered = <Map<String, Object?>>[];
    var moved = 0;
    for (final chapter in bg) {
      final name = title(chapter);
      final match = tv.where((c) => title(c) == name).singleOrNull;
      if (name.length < 2 || RegExp(r'^(?:episode|ep|第)?\d+(?:話|集)?$').hasMatch(name) || match == null ||
          bg.where((c) => title(c) == name).length != 1) {
        return false;
      }
      final changed = match['sort'] != chapter['sort'];
      if (changed) moved++;
      if (((match['sort'] as int) - (chapter['sort'] as int)).abs() > 2 ||
          DateTime.parse('${match['date']}').difference(DateTime.parse('${chapter['date']}')).abs() >
              Duration(days: changed ? 28 : 1)) {
        return false;
      }
      reordered.add(match);
    }
    if (moved > 3 || tv.length - moved < 9) return false;
    tv.setAll(0, reordered);
    return true;
  }

  Future<bool> _recognizeSplitSubjectSeason(
    TaskLease lease, String raw, String title, int? year,
    ({String folder, List<Map<String, Object?>> files}) inventory,
    Map<String, Object?> tmdb, Map<String, Object?> bangumi, {
    bool separateWorks = false,
  }) async {
    final work = lease.workId!;
    if (bangumi['state'] != 'pending' ||
        tmdb['previous'] != null || bangumi['previous'] != null ||
        !const {'ambiguous', 'verify_candidate', 'conflicting_title'}.contains(tmdb['reason']) ||
        !const {'query_incomplete', 'verify_candidate', 'conflicting_title'}.contains(bangumi['reason'])) {
      return false;
    }
    final subject = candidates(bangumi).singleOrNull;
    final premiere = subject?['year'];
    final subjectId = subject?['id'];
    final original = (subject?['aliases'] as List? ?? []).whereType<String>().firstOrNull;
    if (subject?['exact'] != true || subject?['directory_title_matches'] != true ||
        subject?['type'] != 'anime' || subjectId is! int || premiere is! int ||
        original == null || year != null && year != premiere) return false;
    final main = inventory.files.where((f) => f['category'] == 'main').toList();
    if (main.length < 12 || main.length > 60) return false;
    final choices = candidates(tmdb);
    if ((separateWorks, choices.singleOrNull) case (true, final choice?)
        when choice['type'] == 'tv' && choice['seasons'] == null && choice['id'] is int) {
      final id = choice['id'];
      try {
        final detail = await _get(metadataResource('tmdb', 'tv/$id'), lease);
        if (detail['id'] != id || detail['seasons'] is! List) return false;
        choices[0] = {...choice, 'seasons': [
          for (final row in (detail['seasons'] as List).whereType<Map>())
            {'season': row['season_number'], 'count': row['episode_count'],
              'year': DateTime.tryParse('${row['air_date'] ?? ''}')?.year},
        ]};
      } on MetadataFailure {
        return false;
      }
    }
    final matches = [
      for (final choice in choices)
        if (choice['type'] == 'tv' && choice['exact'] == true &&
            (choice['aliases'] as List? ?? []).whereType<String>().any(
                (name) => PersonalMetadataScraper.exactTitle(name, original)))
          for (final s in (choice['seasons'] as List? ?? []).whereType<Map>())
            if (_positive(s['season']) && s['year'] == premiere && s['count'] == main.length)
              (choice: choice, season: s['season'] as int),
    ];
    final match = matches.singleOrNull;
    if (match == null || match.choice['id'] is! int) return false;
    final aliases = (match.choice['aliases'] as List).whereType<String>();
    final local = await _tvLocal(tasks.db, work, raw, title, premiere, aliases: aliases,
        allowCombinedDirectory: separateWorks);
    if (local == null || local.files.length != main.length ||
        (local.season != null && local.season != match.season) ||
        local.files.any((f) => f.number < 1 || f.number > main.length)) return false;
    final series = match.choice['id'] as int;
    final nextId = await (() async {
      try {
        final response = await _get(metadataResource('bangumi', 'subjects/$subjectId/subjects',
            listResponse: true), lease);
        return (response['data'] as List? ?? []).whereType<Map>()
            .where((row) => row['type'] == 2 && row['relation'] == '续集' &&
                _positive(row['id']) && row['id'] != subjectId)
            .map((row) => row['id'] as int).toSet().singleOrNull;
      } on MetadataFailure {
        return null;
      }
    })();
    if (nextId == null) return false;
    final ids = [subjectId, nextId];
    final parts = <Map<String, Object?>>[];
    final schedules = <List<Map<String, Object?>>>[];
    late final List<Map<String, Object?>> tv;
    late final String language;
    try {
      for (final id in ids) {
        final body = await _get(metadataResource('bangumi', 'subjects/$id'), lease);
        if (body['id'] != id || body['type'] != 2 ||
            !const {'TV', 'WEB'}.contains(body['platform'])) return false;
        final episodes = await _fetchChapters(lease, 'bangumi', id: id, regularOnly: true);
        final list = [...episodes.chapters]
          ..sort((a, b) => (a['sort'] as num).compareTo(b['sort'] as num));
        if (!episodes.complete || list.length < 6 ||
            list.any((r) => r['type'] != 0 || r['sort'] is! int) ||
            list.map((r) => r['id']).toSet().length != list.length) return false;
        final first = list.first['sort'] as int;
        final prior = schedules.fold(0, (int count, list) => count + list.length);
        if ((first != 1 && first != prior + 1) ||
            !list.indexed.every((r) => r.$2['sort'] == first + r.$1)) return false;
        schedules.add(list);
        final images = body['images'];
        parts.add({'id': id, 'title': _title(body), 'year': _year(body), 'summary': body['summary'],
          if (images is Map) 'poster': images['large']});
      }
      final combined = schedules.expand((r) => r).toList();
      if (combined.length != main.length ||
          combined.map((r) => r['id']).toSet().length != combined.length) return false;
      final responses = await Future.wait([
        _fetchChapters(lease, 'tmdb', id: series, season: match.season),
        _fetchChapters(lease, 'tmdb', id: series, season: match.season, languageOverride: 'ja-JP'),
        _fetchChapters(lease, 'tmdb', id: series, season: match.season, languageOverride: 'zh-CN'),
      ]);
      if (responses.any((r) => !r.complete || r.chapters.length != combined.length)) return false;
      tv = [...responses.first.chapters]..sort((a,b) => (a['sort'] as num).compareTo(b['sort'] as num));
      language = responses.first.language;
      final originals = {for (final c in responses[1].chapters) c['id']: c};
      final translated = {for (final c in responses[2].chapters) c['id']: c};
      if (originals.length != tv.length || translated.length != tv.length ||
          tv.map((r) => r['id']).toSet().length != tv.length) return false;
      var translationMatches = 0;
      var localMatches = 0;
      final names = {for (final file in main) file['episode']: file['name'] as String};
      for (final (index, chapter) in tv.indexed) {
        final ja = originals[chapter['id']], zh = translated[chapter['id']];
        final bg = combined[index];
        if (chapter['sort'] != index + 1 || ja?['sort'] != chapter['sort'] ||
            zh?['sort'] != chapter['sort'] || ja?['date'] != chapter['date'] ||
            zh?['date'] != chapter['date']) return false;
        if (_chapterAgreement(ja!, bg)) continue;
        if (separateWorks) {
          final label = RegExp(r'「([^」]+)」|『([^』]+)』').firstMatch(names[index + 1] ?? '');
          final fileTitle = label?[1] ?? label?[2];
          if (fileTitle != null &&
              originals.values.where((episode) => PersonalMetadataScraper.exactTitle(
                  _originalChapterTitle(episode), fileTitle)).length == 1) {
            // Some official episode titles consist of a single ideograph.
            // Require the same title in all three places and a matching date.
            if (RegExp(r'^[\u3400-\u9fff]$').hasMatch(fileTitle) &&
                fileTitle == _originalChapterTitle(ja) &&
                fileTitle == _originalChapterTitle(bg) &&
                ja['date'] == bg['date'] && DateTime.tryParse('${ja['date']}') != null) continue;
            if (_chapterAgreement(ja, {...bg, 'verification_title': fileTitle}) &&
                ++localMatches <= 3) continue;
          }
        }
        if (++translationMatches > 1 ||
            !_chapterAgreement(zh!, {...bg, 'verification_title': bg['title']}) ||
            combined.where((r) => PersonalMetadataScraper.exactTitle(
                '${r['title']}', '${zh['title']}')).length != 1) return false;
      }
    } on MetadataFailure {
      return false;
    }
    var changed = false;
    await tasks.commit(lease, (tx) async {
      final latest = await _workFiles(tx, work);
      final guard = (await tx.query('library_work_protection', where:'work_id=?', whereArgs:[work])).single;
      if (guard['identity_locked'] == 1 || guard['legacy_lock'] == 1 ||
          latest.folder != inventory.folder || jsonEncode(latest.files) != jsonEncode(inventory.files)) {
        return {'split_subject_season': false};
      }
      for (final row in [tmdb, bangumi]) {
        final current = await _row(tx, row['id'] as String);
        if (current?['state'] != 'pending' || current?['revision'] != row['revision']) {
          return {'split_subject_season': false};
        }
      }
      if ((await tx.rawQuery('''
        SELECT 1 FROM scan_bindings WHERE work_id=? AND layer!='work'
          AND (state!='pending' OR previous IS NOT NULL)
        UNION ALL SELECT 1 FROM asset_overrides o JOIN assets a ON a.id=o.asset_id
          WHERE o.work_id=? OR a.work_id=?
        LIMIT 1
      ''', [work, work, work])).isNotEmpty) return {'split_subject_season': false};
      final store = catalog.mappingStore!;
      var offset = 0;
      for (final (index, list) in schedules.indexed) {
        for (final (i, chapter) in list.indexed) {
          final answer = await store.lookupIn(tx, ids[index], chapter['id'] as int);
          final target = answer.targets.singleOrNull;
          if (const {'excluded', 'conflict'}.contains(answer.state) ||
              answer.state == 'mapped' && (target?['type'] != 'tv' || target?['id'] != series ||
                target?['season'] != match.season || target?['episode'] != offset + i + 1)) {
            return {'split_subject_season': false};
          }
        }
        offset += list.length;
      }
      const reason = 'verified_tv_chapters';
      String? secondWork;
      if (separateWorks) {
        final source = lease.sourceId!;
        final folder = '${inventory.folder}/$title S02';
        if (await LibraryFoundation.locate(tx, 'work', source, folder) != null) {
          return {'split_subject_season': false};
        }
        secondWork = LibraryFoundation.newId('work:$source:id-');
        final entry = <String, Object?>{'id': secondWork,
          'title': parts.last['title'], 'year': parts.last['year']};
        await tx.insert('works', entry);
        await LibraryFoundation.attach(tx, 'work', secondWork, source, folder);
        await LibraryFoundation.seedWork(tx, entry);
        for (final provider in providers) {
          await _put(tx, secondWork, provider, 'work', '');
          final parent = (await _row(tx, _id(secondWork, provider, 'work', '')))!;
          await _saveDecision(tx, parent, provider == 'tmdb'
              ? {...match.choice, 'title': parts.last['title'], 'year': parts.last['year']}
              : {...parts.last, 'type': 'anime'}, reason: reason, by: reason);
        }
      }
      await _saveDecision(tx, tmdb, match.choice, reason: reason, by: reason);
      await _saveDecision(tx, bangumi, {...subject!, if (!separateWorks) 'subjects': ids},
          reason: reason, by: reason);
      var start = 0;
      for (final (index, chapters) in schedules.indexed) {
        final end = start + chapters.length;
        final work = index == 1 && secondWork != null ? secondWork : lease.workId!;
        final scope = LibraryFoundation.newId('file-group:');
        await tx.insert('scan_file_groups', {'scope':scope,'work_id':work,
          'directory':local.directory,'name':parts[index]['title']});
        final files = local.files.where((f) => f.number > start && f.number <= end);
        for (final file in files) {
          if (work == secondWork) {
            await tx.delete('scan_bindings', where: "asset_id=? AND state='pending'", whereArgs: [file.id]);
            await tx.update('assets', {'work_id': work}, where: 'id=?', whereArgs: [file.id]);
          }
          await tx.insert('scan_file_group_members', {'asset_id':file.id,'scope':scope});
        }
        for (final provider in providers) {
          final isTv = provider == 'tmdb';
          final parent = (await _row(tx, _id(work, provider, 'work', '')))!;
          final rangeId = _id(work, provider, 'range', scope);
          await _put(tx, work, provider, 'range', scope, parent:_token(parent));
          await _saveDecision(tx, (await _row(tx, rangeId))!, {
            if (isTv) ...{'season':match.season,'first':start+1,'last':end,'offset':0,
              'summary_language':language,'chapters':tv.sublist(start,end)}
            else ...{...parts[index], 'offset':(chapters.first['sort'] as int)-start-1,
              'chapters':chapters},
          }, reason: reason, by: reason);
          final range = (await _row(tx, rangeId))!;
          for (final file in files) {
            final chapter = isTv ? tv[file.number - 1] : chapters[file.number - start - 1];
            await _put(tx, work, provider, 'episode', file.id, asset:file.id, parent:_token(range));
            await _saveDecision(tx, (await _row(tx, _id(work, provider, 'episode', file.id)))!, {
              'title':chapter['title'],'chapter_id':chapter['id'],
              if (isTv) ...{'season':match.season,'episode':chapter['sort'],
                if (chapter['still'] != null) 'still':chapter['still']}
              else ...{'id':chapter['id'],'subject':ids[index],'sort':chapter['sort']},
            }, reason: reason, by: reason);
          }
        }
        start = end;
      }
      for (final provider in providers) {
        await tx.delete('scan_bindings', where:"id=? AND state='pending' AND previous IS NULL",
            whereArgs:[_id(work, provider, 'range', local.directory)]);
        await _syncChildren(tx, work, provider);
        if (secondWork != null) await _syncChildren(tx, secondWork, provider);
      }
      changed = true;
      return {'split_subject_season': true};
    });
    if (changed) await catalog.reload();
    return true;
  }

  Future<bool> _recognizeCombinedBroadcast(
    TaskLease lease, String raw, String title, int? year,
    ({String folder, List<Map<String, Object?>> files}) inventory,
    Map<String, Object?> tmdb, Map<String, Object?> bg,
  ) async {
    final work = lease.workId!;
    if (tmdb['previous'] != null ||
        !const {'conflicting_title', 'verify_candidate'}.contains(tmdb['reason']) ||
        bg['reason'] != 'verified_bangumi') return false;
    final subject = adopted(bg);
    final series = candidates(tmdb).singleOrNull;
    final id = subject?['id'], seriesId = series?['id'], premiere = subject?['year'];
    if (subject?['by'] != 'verified_bangumi' || subject?['exact'] != true ||
        subject?['directory_title_matches'] != true || subject?['movie'] == true ||
        id is! int || premiere is! int || (year != null && year != premiere) ||
        series?['type'] != 'tv' || series?['exact'] != true || seriesId is! int) return false;
    final subjectAliases = (subject!['aliases'] as List? ?? []).whereType<String>();
    final aliases = (series!['aliases'] as List? ?? []).whereType<String>();
    if (subjectAliases.firstOrNull == null || !aliases.any((name) =>
        PersonalMetadataScraper.exactTitle(name, subjectAliases.first))) return false;
    final main = inventory.files.where((f) => f['category'] == 'main').length;
    if (main < 9 || main > 40) return false;
    final season = (series['seasons'] as List? ?? []).whereType<Map>().where((s) =>
        _positive(s['season']) && s['year'] == premiere && s['count'] == main - 1).singleOrNull?['season'];
    if (season is! int) return false;
    final local = await _tvLocal(tasks.db, work, raw, title, premiere,
        aliases: [...aliases, ...subjectAliases]);
    if (local == null || local.files.length != main ||
        local.season != null && local.season != season ||
        local.files.any((f) => f.number < 1 || f.number > main)) return false;
    late final List<Map<String, Object?>> tv, originals, bangumi;
    late final String language;
    try {
      final r = await Future.wait([
        _fetchChapters(lease, 'tmdb', id:seriesId, season:season),
        _fetchChapters(lease, 'tmdb', id:seriesId, season:season, languageOverride:'ja-JP'),
        _fetchChapters(lease, 'bangumi', id:id, regularOnly:true),
      ]);
      if (r.any((r) => !r.complete) || r[0].chapters.length != main-1 ||
          r[1].chapters.length != main-1 || r[2].chapters.length != main) return false;
      List<Map<String, Object?>> ordered(List<Map<String, Object?>> rows) =>
          [...rows]..sort((a,b) => (a['sort'] as num).compareTo(b['sort'] as num));
      tv = ordered(r[0].chapters);
      originals = ordered(r[1].chapters);
      bangumi = ordered(r[2].chapters);
      language = r[0].language;
    } on MetadataFailure {
      return false;
    }
    for (final list in [tv, originals, bangumi]) {
      if (list.map((r) => r['id']).toSet().length != list.length ||
          !list.indexed.every((e) => e.$2['sort'] == e.$1+1)) return false;
    }
    if (bangumi.any((r) => r['type'] != 0) ||
        !tv.indexed.every((e) => e.$2['id'] == originals[e.$1]['id'] &&
            e.$2['date'] == originals[e.$1]['date'])) return false;
    List<String> fragments(Map chapter) => _originalChapterTitle(chapter)
        .split(RegExp(r'[/／]')).map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
    final first = fragments(originals.first);
    if (first.length != 2 || PersonalMetadataScraper.exactTitle(first.first, first.last)) return false;
    for (var i = 0; i < 2; i++) {
      final same = fragments(bangumi[i]).where((s) =>
          _chapterAgreement({'title':first[i], 'date':originals.first['date']},
              {'title':s, 'date':bangumi[i]['date']})).length == 1;
      if (!same || fragments(bangumi[1-i]).any(
          (s) => PersonalMetadataScraper.exactTitle(s, first[i]))) return false;
    }
    final indexes = <int>[0, 0];
    for (final chapter in bangumi.skip(2)) {
      final match = originals.indexed.skip(1).where((entry) =>
          _chapterAgreement(entry.$2, chapter)).singleOrNull;
      if (match == null || indexes.contains(match.$1)) return false;
      indexes.add(match.$1);
    }
    final moved = <int>[
      for (var i = 2; i < indexes.length; i++) if (indexes[i] != i-1) i,
    ];
    if (moved.isNotEmpty && (moved.length != 2 || moved.last != moved.first+1 ||
        indexes[moved.first] != moved.last-1 || indexes[moved.last] != moved.first-1)) return false;
    var changed = false;
    await tasks.commit(lease, (tx) async {
      final latest = await _workFiles(tx, work);
      final protection = (await tx.query('library_work_protection',
          where:'work_id=?', whereArgs:[work])).single;
      if (protection['identity_locked'] == 1 || protection['legacy_lock'] == 1 ||
          latest.folder != inventory.folder || jsonEncode(latest.files) != jsonEncode(inventory.files) ||
          (await _row(tx, tmdb['id'] as String))?['revision'] != tmdb['revision'] ||
          (await _row(tx, bg['id'] as String))?['revision'] != bg['revision'] ||
          (await tx.rawQuery('''
            SELECT 1 FROM scan_bindings WHERE work_id=? AND layer!='work'
              AND (state!='pending' OR previous IS NOT NULL)
            UNION ALL SELECT 1 FROM asset_overrides o JOIN assets a ON a.id=o.asset_id
              WHERE o.work_id=? OR a.work_id=? LIMIT 1
          ''', [work,work,work])).isNotEmpty) return {'combined_broadcast': false};
      final store = catalog.mappingStore!;
      for (final (i, chapter) in bangumi.indexed) {
        final mapping = await store.lookupIn(tx, id, chapter['id'] as int);
        final target = mapping.targets.singleOrNull;
        if (const {'excluded', 'conflict'}.contains(mapping.state) ||
            mapping.state == 'mapped' && (target?['type'] != 'tv' ||
              target?['id'] != seriesId || target?['season'] != season ||
              target?['episode'] != indexes[i]+1)) return {'combined_broadcast': false};
      }
      const reason = 'verified_tv_chapters';
      await _saveDecision(tx, tmdb, series, reason:reason, by:reason);
      final parent = (await _row(tx, tmdb['id'] as String))!;
      for (final provider in providers) {
        final isTv = provider == 'tmdb';
        final scope = local.directory;
        final rangeId = _id(work, provider, 'range', scope);
        await _put(tx, work, provider, 'range', scope, parent:_token(isTv ? parent : bg));
        await _saveDecision(tx, (await _row(tx, rangeId))!, {
          if (isTv) ...{'season':season,'first':1,'last':tv.length,'offset':0,
            'number_map':{for (final (i,n) in indexes.indexed) if (!moved.contains(i)) '${i+1}':n+1},
            'summary_language':language,'chapters':tv,
            'chapter_verification':{'method':'combined_broadcast','deferred_local_numbers':[
              for (final i in moved) i+1]}}
          else ...{'id':id,'title':subject['title'],'poster':subject['poster'],
            'summary':subject['summary'],'offset':0,'chapters':[
              for (final (i,chapter) in bangumi.indexed) if (!moved.contains(i)) chapter,
            ]},
        }, reason:reason, by:reason);
        final range = (await _row(tx, rangeId))!;
        for (final file in local.files) {
          final i = file.number-1;
          if (moved.contains(i)) continue;
          final chapter = isTv ? tv[indexes[i]] : bangumi[i];
          final episodeId = _id(work, provider, 'episode', file.id);
          await _put(tx, work, provider, 'episode', file.id, asset:file.id, parent:_token(range));
          await _saveDecision(tx, (await _row(tx, episodeId))!, {
            'chapter_id':chapter['id'], 'title':isTv && i < 2 ? bangumi[i]['title'] : chapter['title'],
            if (isTv) ...{'season':season,'episode':indexes[i]+1,
              if (i < 2) 'broadcast_part':i+1,
              if (i >= 2 && chapter['still'] != null) 'still':chapter['still']}
            else ...{'id':chapter['id'],'subject':id,'sort':chapter['sort']},
          }, reason:reason, by:reason);
        }
        await _syncChildren(tx, work, provider);
      }
      changed = true;
      return {'combined_broadcast':true,'deferred':moved.length};
    });
    if (changed) await catalog.reload();
    return true;
  }

  static List<String> _numberedSupplementIds(List<Map<String, Object?>> files) {
    final label = CloudMediaFileClassifier.numberedSupplementLabel;
    if (!files.any((f) => f['category'] == 'main' &&
        label.hasMatch(f['name'] as String))) return const [];
    final regular = files.where((f) => f['file_group'] == null && _singleRegularFile(f));
    final paths = {for (final f in regular) f['relative_path']: f};
    final result = <String>[];
    for (final file in regular) {
      final name = file['name'] as String;
      if (label.allMatches(name).singleOrNull == null) continue;
      final base = name.replaceFirst(label, '');
      final path = p.posix.normalize(p.posix.join(p.posix.dirname(file['relative_path'] as String), base));
      final sibling = paths[path];
      final size = file['size'], fullSize = sibling?['size'];
      if (sibling != null && sibling['episode'] == file['episode'] &&
          sibling['season'] == file['season'] && size is int && fullSize is int &&
          size > 0 && size * 2 < fullSize) result.add(file['id'] as String);
    }
    return result;
  }

  Future<bool> _reclassifyNumberedSupplements(
    TaskLease lease,
    ({String folder, List<Map<String, Object?>> files}) inventory,
  ) async {
    final ids = _numberedSupplementIds(inventory.files);
    if (ids.isEmpty) return false;
    return tasks.db.transaction((tx) async {
      await tasks.checkIn(tx, lease);
      final work = lease.workId!;
      final guard = (await tx.query('library_work_protection',
          where:'work_id=?', whereArgs:[work])).single;
      if (guard['identity_locked'] == 1 || guard['legacy_lock'] == 1) return false;
      final latest = await _workFiles(tx, work);
      if (latest.folder != inventory.folder ||
          jsonEncode(latest.files) != jsonEncode(inventory.files)) return false;
      var changed = false;
      for (final id in ids) {
        if ((await tx.rawQuery('''
          SELECT 1 FROM asset_overrides WHERE asset_id=?
          UNION ALL SELECT 1 FROM scan_bindings WHERE asset_id=? AND
            (state!='pending' OR previous IS NOT NULL)
          LIMIT 1
        ''', [id,id])).isNotEmpty ||
            (catalog.chapterRelationsEnabled && (await tx.query('chapter_parts',
              columns:['asset_id'], where:'asset_id=?', whereArgs:[id], limit:1)).isNotEmpty)) continue;
        await tx.update('assets', {'category':'extra','season':0,'extra_type':'SP'},
            where:'id=? AND work_id=?', whereArgs:[id,work]);
        await tx.delete('scan_bindings', where:"asset_id=? AND state='pending'", whereArgs:[id]);
        changed = true;
      }
      return changed;
    });
  }

  Future<bool> _adoptContinuousTv(DatabaseExecutor tx, String work, String raw,
      String title, _ContinuousTvEvidence evidence) async {
    final protection = (await tx.query('library_work_protection',
        where: 'work_id=?', whereArgs: [work])).single;
    if (protection['identity_locked'] == 1 || protection['legacy_lock'] == 1) return false;
    final tmdb = (await _row(tx, _id(work, 'tmdb', 'work', '')))!;
    final bg = (await _row(tx, _id(work, 'bangumi', 'work', '')))!;
    final series = evidence.choice['id'];
    final subject = adopted(bg);
    if (tmdb['state'] != 'pending' || tmdb['previous'] != null ||
        subject?['id'] != evidence.subject ||
        bg['reason'] != 'verified_bangumi' || subject?['by'] != 'verified_bangumi') {
      return false;
    }
    final local = await _tvLocal(tx, work, raw, title, evidence.choice['year'] as int,
        aliases: evidence.aliases);
    if (local == null || local.season != null || local.directory != evidence.local.directory ||
        !_completeAbsoluteNumbering(local) || !listEquals(local.files, evidence.local.files)) {
      return false;
    }
    if ((await tx.rawQuery('''
      SELECT 1 FROM scan_bindings WHERE work_id=? AND layer!='work'
          AND (state!='pending' OR previous IS NOT NULL)
      UNION ALL SELECT 1 FROM scan_file_groups WHERE work_id=?
      UNION ALL SELECT 1 FROM asset_overrides o JOIN assets a ON a.id=o.asset_id
          WHERE o.work_id=? OR a.work_id=?
      LIMIT 1
    ''', [work, work, work, work])).isNotEmpty) {
      return false;
    }
    final store = catalog.mappingStore!;
    final targets = await store.subjectTargets(tx, evidence.subject);
    if (targets.targets.any((target) => target['id'] != series || target['type'] != 'tv')) {
      return false;
    }
    var start = 0;
    for (final (index, season) in evidence.seasons.indexed) {
      for (final (chapterIndex, chapter) in season.indexed) {
        final answer = await store.lookupIn(
          tx, evidence.subject, evidence.bangumi[start + chapterIndex]['id'] as int,
        );
        if (const {'excluded', 'conflict'}.contains(answer.state)) return false;
        final target = answer.targets.singleOrNull;
        if (answer.state == 'mapped' && (target?['type'] != 'tv' ||
            target?['id'] != series || target?['season'] != index + 1 ||
            target?['episode'] != chapter['sort'])) {
          return false;
        }
      }
      start += season.length;
    }
    const reason = 'verified_tv_chapters';
    await _saveDecision(tx, tmdb, evidence.choice, reason: reason, by: reason);
    final currentTmdb = (await _row(tx, tmdb['id'] as String))!;
    // A physical directory can contain several independent range bindings.
    start = 0;
    for (final (index, season) in evidence.seasons.indexed) {
      final number = index + 1;
      final end = start + season.length;
      final scope = LibraryFoundation.newId('file-group:');
      await tx.insert('scan_file_groups', {
        'scope': scope, 'work_id': work, 'directory': local.directory, 'name': 'S$number',
      });
      final files = local.files.where((file) => file.number > start && file.number <= end);
      for (final file in files) {
        await tx.insert('scan_file_group_members', {'asset_id': file.id, 'scope': scope});
      }
      for (final provider in providers) {
        final isTmdb = provider == 'tmdb';
        final chapters = isTmdb ? season : evidence.bangumi.sublist(start, end);
        final parent = isTmdb ? currentTmdb : bg;
        await _put(tx, work, provider, 'range', scope, parent: _token(parent));
        final id = _id(work, provider, 'range', scope);
        await _saveDecision(tx, (await _row(tx, id))!, {
          if (isTmdb) ...{
            'season': number, 'first': 1, 'last': season.length, 'offset': -start,
            'chapter_verification': {'method': 'continuous_seasons'},
          } else ...{
            'id': evidence.subject, 'offset': 0,
            'title': subject!['title'], 'poster': subject['poster'], 'summary': subject['summary'],
          },
          'chapters': chapters,
        }, reason: reason, by: reason);
        final range = (await _row(tx, id))!;
        for (final file in files) {
          final chapter = chapters[file.number - start - 1];
          await _put(tx, work, provider, 'episode', file.id,
              asset: file.id, parent: _token(range));
          final row = (await _row(tx, _id(work, provider, 'episode', file.id)))!;
          await _saveDecision(tx, row, {
            'title': chapter['display_title'] ?? chapter['title'],
            'chapter_id': chapter['id'],
            if (isTmdb) ...{
              'season': number, 'episode': chapter['sort'],
              if (chapter['still'] != null) 'still': chapter['still'],
            } else ...{
              'id': chapter['id'], 'subject': evidence.subject, 'sort': chapter['sort'],
            },
          }, reason: reason, by: reason);
        }
      }
      start = end;
    }
    for (final provider in providers) {
      await tx.delete('scan_bindings',
          where: "id=? AND state='pending' AND previous IS NULL",
          whereArgs: [_id(work, provider, 'range', local.directory)]);
      await _syncChildren(tx, work, provider);
    }
    return true;
  }

  Future<bool> _adoptVerifiedTv(
    DatabaseExecutor tx,
    String work,
    String raw,
    String title,
    int? year,
    _TvEvidence evidence, {
    bool correctedDirectory = false,
    bool allowAutomaticTmdb = false,
    bool allowSeasonDateDifferences = false,
  }) async {
    final rows = await _unreviewedPair(tx, work, allowAutomaticBangumi: true,
        allowAutomaticTmdb: allowAutomaticTmdb);
    if (rows == null) return false;
    final tvCandidate = adopted(rows['tmdb']!) ?? candidates(rows['tmdb']!).single;
    if (tvCandidate['id'] != evidence.series ||
        candidates(rows['bangumi']!).single['id'] != evidence.subject) {
      return false;
    }
    year ??= candidates(rows['bangumi']!).single['year'] as int?;
    final local = await _tvLocal(tx, work, raw, title, year, aliases: evidence.aliases,
        allowDualNumbers: evidence.local.absoluteOffset != null);
    if (local == null ||
        local.season != evidence.local.season ||
        local.absoluteOffset != evidence.local.absoluteOffset ||
        local.directory != evidence.local.directory ||
        local.explicitEpisodes != evidence.local.explicitEpisodes ||
        !listEquals(local.files, evidence.local.files)) {
      return false;
    }
    // Parent changes must never invalidate a user's range or episode decision.
    if ((await tx.query('scan_bindings', columns: ['id'],
        where: "work_id=? AND layer!='work' AND state='confirmed'",
        whereArgs: [work], limit: 1)).isNotEmpty) {
      return false;
    }
    final store = catalog.mappingStore!;
    final currentMap = await store.subjectTargets(tx, evidence.subject);
    if (currentMap.version != evidence.subjectMap.version ||
        jsonEncode(currentMap.targets) !=
            jsonEncode(evidence.subjectMap.targets)) {
      return false;
    }
    var completeMap = true;
    var matchingChapters = 0;
    for (var i = 0; i < evidence.tv.length; i++) {
      final answer = await store.lookupIn(
        tx,
        evidence.subject,
        evidence.bangumi[i]['id'] as int,
      );
      if (['excluded', 'conflict'].contains(answer.state)) return false;
      if (_chapterAgreement(evidence.tv[i], evidence.bangumi[i], allowReading: correctedDirectory)) {
        matchingChapters++;
      }
      final target = answer.targets.singleOrNull;
      if (answer.state == 'mapped') {
        if (target == null ||
            target['type'] != 'tv' ||
            target['id'] != evidence.series ||
            target['season'] != evidence.season ||
            target['episode'] != evidence.tv[i]['sort'] ||
            answer.version != currentMap.version) {
          return false;
        }
      } else {
        completeMap = false;
      }
    }
    final seasonDateDifferences = allowSeasonDateDifferences &&
        _sameSeasonTitlesWithDateDifferences(evidence.tv, evidence.bangumi);
    if (!completeMap &&
        ((matchingChapters != evidence.tv.length &&
                (correctedDirectory ||
                    !(evidence.discOrder && year != null &&
                        _discSeasonOrder(List.of(evidence.tv), evidence.bangumi, year)) &&
                    !seasonDateDifferences && !_dualSeasonChapterAgreement(evidence) &&
                    !_seasonChapterAgreement(evidence.tv, evidence.bangumi))) ||
            evidence.tv
                    .map(
                      (row) => PersonalFilenameParser.normalizeIdentity(
                        _chapterTitle((row['verification_title'] ?? row['title']) as String),
                      ),
                    )
                    .toSet()
                    .length <
                3)) {
      return false;
    }
    final firstLocalNumber = local.files.map((file) => file.number).reduce((a, b) => a < b ? a : b);
    final titleOffset = evidence.first - firstLocalNumber;
    final titleVerifiedOffset = titleOffset < 0 &&
        !local.explicitEpisodes &&
        local.absoluteOffset == null &&
        local.files.length == evidence.bangumi.length &&
        local.files.every((file) {
          final index = file.number - firstLocalNumber;
          if (index >= evidence.bangumi.length) return false;
          final chapter = _originalChapterTitle(evidence.bangumi[index]);
          if (chapter.length < 2 || _genericChapterTitle.hasMatch(chapter)) return false;
          final labels = RegExp(r'\[([^\]]+)\]|【([^】]+)】|「([^」]+)」')
              .allMatches(p.posix.basename(file.path));
          return labels.any((label) => PersonalMetadataScraper.exactTitle(
              (label[1] ?? label[2] ?? label[3])!, chapter));
        });
    final offsets =
        {
              local.absoluteOffset ?? 0,
              if (!local.explicitEpisodes && local.absoluteOffset == null)
                evidence.first - (evidence.bangumi.first['sort'] as int),
              if (titleVerifiedOffset) titleOffset,
            }
            .where(
              (offset) => local.files.every(
                (file) =>
                    file.number + offset >= evidence.first &&
                    file.number + offset <= evidence.last,
              ),
            )
            .toList();
    if (offsets.length != 1) return false;
    final offset = offsets.single;
    final reason = completeMap ? 'verified_tv_mapping' : 'verified_tv_chapters';
    final bgOffset =
        offset + (evidence.bangumi.first['sort'] as int) - evidence.first;
    for (final provider in providers) {
      final tmdb = provider == 'tmdb';
      final identity = rows[provider]!;
      await _saveDecision(
        tx,
        identity,
        tmdb ? {...tvCandidate, 'aliases': evidence.aliases} : candidates(identity).single,
        reason: reason,
        by: reason,
      );
      final current = (await _row(tx, identity['id'] as String))!;
      final rangeId = _id(work, provider, 'range', local.directory);
      await _put(
        tx,
        work,
        provider,
        'range',
        local.directory,
        parent: _token(current),
      );
      final range = (await _row(tx, rangeId))!;
      await _saveDecision(
        tx,
        range,
        {
          if (tmdb) ...{
            'season': evidence.season,
            'first': evidence.first,
            'last': evidence.last,
            'offset': offset,
            'summary': evidence.summary,
            'summary_language': evidence.language,
            if (evidence.discOrder) ...{
              'number_map': {for (var i = 0; i < evidence.tv.length; i++)
                '${evidence.bangumi[i]['sort']}': evidence.tv[i]['sort']},
              'disc_inventory': [for (final f in local.files)
                {'id': f.id, 'path': f.path, 'number': f.number}],
            },
          } else ...{
            'id': evidence.subject,
            'offset': bgOffset,
            'title': candidates(identity).single['title'],
            'poster': candidates(identity).single['poster'],
            'summary': candidates(identity).single['summary'],
          },
          'chapters': tmdb ? evidence.tv : evidence.bangumi,
          if (!completeMap && matchingChapters != evidence.tv.length)
            'chapter_verification': {
              'method': evidence.discOrder ? 'disc_episode_titles' :
                  seasonDateDifferences ? 'complete_titles_broadcast_dates' :
                  _dualSeasonChapterAgreement(evidence) ? 'dual_numbering_translated_title' : 'season_consensus',
              'strict_matches': matchingChapters,
              'total': evidence.tv.length,
              'differences': [
                for (var i = 0; i < evidence.tv.length; i++)
                  if (!_chapterAgreement(evidence.tv[i], evidence.bangumi[i]))
                    {'tmdb': evidence.tv[i], 'bangumi': evidence.bangumi[i]},
              ],
            },
          if (completeMap) 'mapping_version': currentMap.version,
        },
        reason: reason,
        by: reason,
      );
      final adoptedRange = (await _row(tx, rangeId))!;
      for (final file in local.files) {
        final number = file.number + offset;
        final index = number - evidence.first;
        final chapter = (tmdb ? evidence.tv : evidence.bangumi)[index];
        await _put(
          tx,
          work,
          provider,
          'episode',
          file.id,
          asset: file.id,
          parent: _token(adoptedRange),
        );
        final row = (await _row(tx, _id(work, provider, 'episode', file.id)))!;
        await _saveDecision(
          tx,
          row,
          {
            'title': chapter['title'],
            'chapter_id': chapter['id'],
            if (chapter['still'] != null) 'still': chapter['still'],
            if (tmdb) ...{
              'season': evidence.season,
              'episode': evidence.discOrder ? chapter['sort'] : number,
              if (completeMap) ...{
                'mapping_version': currentMap.version,
                'bangumi_subject': evidence.subject,
                'bangumi_episode': evidence.bangumi[index]['id'],
              },
            } else ...{
              'id': chapter['id'],
              'subject': evidence.subject,
              'sort': chapter['sort'],
            },
          },
          reason: reason,
          by: reason,
        );
      }
      await _syncChildren(tx, work, provider);
    }
    return true;
  }

  /// Both choices must be unreviewed. Chapter-verified TV adoption may also
  /// reuse an untouched automatic Bangumi identity, never a user decision.
  Future<Map<String, Map<String, Object?>>?> _unreviewedPair(
    DatabaseExecutor tx,
    String work, {
    bool allowAutomaticBangumi = false,
    bool allowAutomaticTmdb = false,
  }) async {
    final protection = (await tx.query(
      'library_work_protection',
      where: 'work_id=?',
      whereArgs: [work],
    )).single;
    if (protection['identity_locked'] == 1 || protection['legacy_lock'] == 1) {
      return null;
    }
    final rows = await tx.query(
      'scan_bindings',
      where: "work_id=? AND layer='work'",
      whereArgs: [work],
    );
    bool eligible(Map<String, Object?> row) {
      final choices = candidates(row);
      if (row['state'] == 'pending') return row['reason'] == 'verify_candidate' && choices.length == 1;
      if (row['state'] != 'confirmed') return false;
      final choice = adopted(row);
      if (allowAutomaticTmdb && row['provider'] == 'tmdb') {
        return row['reason'] == 'verified_tmdb' && choice?['by'] == 'verified_tmdb' &&
            choice?['type'] == 'tv' && choice?['exact'] == true;
      }
      return allowAutomaticBangumi && row['provider'] == 'bangumi' &&
          row['reason'] == 'verified_bangumi' && choice?['by'] == 'verified_bangumi' &&
          choices.length == 1 && choice?['id'] == choices.single['id'];
    }
    if (rows.length != 2 || !rows.every(eligible)) {
      return null;
    }
    return {for (final row in rows) row['provider'] as String: row};
  }

  Future<bool> _adoptVerifiedMovie(
    DatabaseExecutor tx,
    String work,
    String title,
    int tmdbId,
  ) async {
    final rows = await _unreviewedPair(tx, work);
    if (rows == null) return false;
    final bangumi = candidates(rows['bangumi']!).single;
    final targets = bangumi['targets'];
    if (targets is! List ||
        targets.length != 1 ||
        bangumi['exact'] != true ||
        bangumi['mapping_target_count'] != 1 ||
        targets.single['type'] != 'movie' ||
        targets.single['id'] != tmdbId) {
      return false;
    }
    final main = await tx.rawQuery(
      '''SELECT a.name FROM assets a
      JOIN library_content c ON c.asset_id=a.id AND c.state='current'
      WHERE a.work_id=? AND a.category='main'
        AND NOT EXISTS (SELECT 1 FROM scan_missing_assets m WHERE m.asset_id=a.id) LIMIT 2''',
      [work],
    );
    if (main.length != 1 ||
        !PersonalMetadataScraper.exactTitle(
          title,
          PersonalFilenameParser.extractAnimeSearchKeyword(
            main.single['name'] as String,
          ),
        )) {
      return false;
    }
    for (final row in rows.values) {
      await tx.update(
        'scan_bindings',
        {
          'state': 'confirmed',
          'reason': 'verified_movie',
          'revision': (row['revision'] as int) + 1,
          'adopted': jsonEncode({
            ...candidates(row).single,
            'by': 'verified_movie',
            if (row['provider'] == 'bangumi') 'movie': true,
          }),
        },
        where: 'id=?',
        whereArgs: [row['id']],
      );
      await _syncChildren(tx, work, row['provider'] as String);
    }
    return true;
  }

  static String _directoryScope(String path, String workFolder) {
    final relative = path.startsWith('$workFolder/')
        ? path.substring(workFolder.length + 1)
        : path;
    final dir = p.posix.dirname(relative);
    return dir == '.' ? '' : dir;
  }

  Future<List<_SpecialEvidence>?> _numberedSpecials(TaskLease lease, String raw,
      String title, int? year) async {
    final inventory = await _workFiles(tasks.db, lease.workId!);
    final files = inventory.files.where((f) => f['category'] == 'main').toList();
    if (files.length < 2 || files.length > 6 || files.any((f) =>
        f['file_group'] != null || f['content_state'] != 'current')) return null;
    final parts = raw.split(RegExp(r'\s+[&＆]\s+')).map(Catalog.cleanTitle).toList();
    final mixed = parts.length == files.length && parts.toSet().length == files.length &&
        parts.every((p) => p.length >= 5);
    if (!mixed) {
      if (files.any((f) => f['episode'] is! int)) return null;
      files.sort((a, b) => (a['episode'] as int).compareTo(b['episode'] as int));
      if (!files.indexed.every((e) => e.$2['episode'] == e.$1 + 1)) return null;
      final filenames = files.map((f) => PersonalFilenameParser.extractAnimeSearchKeyword(
          f['name'] as String, episodeNumber: f['episode'] as int)).toSet();
      if (filenames.length != 1) return null;
    }
    const ordinals = ['ONE', 'TWO', 'THREE', 'FOUR', 'FIVE', 'SIX'];
    final evidence = <_SpecialEvidence>[];
    for (final (index, file) in files.indexed) {
      final query = mixed ? parts[index] : '$title ${ordinals[index]}';
      Future<({String reason, List<Map<String, Object?>> choices})> search({
        bool firstPage = false, List<String>? airDates,
      }) => _search(lease, 'bangumi', query, query, year,
          const <int>{}, const <String>{}, [query], filenameFallback: true,
          firstBangumiPage: firstPage, bangumiAirDates: airDates);
      Future<List<_SpecialEvidence>> match(Map<String, Object?> subject) async {
        final matches = <_SpecialEvidence>[];
        for (final candidate in mixed ? files : [file]) {
          final verified = await _standaloneSpecial(lease, raw, query, year, subject,
              asset: candidate['id'] as String, ordinal: mixed ? null : ordinals[index]);
          if (verified != null) matches.add(verified);
        }
        return matches;
      }
      var found = await search(firstPage: true);
      if (found.reason == 'query_incomplete') {
        final proposal = found.choices.singleOrNull;
        if (proposal?['exact'] == true && proposal?['directory_title_matches'] == true) {
          final verified = (await match(proposal!)).singleOrNull;
          final date = DateTime.tryParse('${verified?.tv['date']}');
          if (verified != null && date != null) {
            String day(DateTime value) => value.toIso8601String().split('T').first;
            final narrow = await search(firstPage: true, airDates: [
              '>=${day(date.subtract(const Duration(days: 3)))}',
              '<${day(date.add(const Duration(days: 4)))}',
            ]);
            if (narrow.reason == 'verify_candidate' &&
                narrow.choices.single['id'] == verified.subject) {
              evidence.add(verified);
              continue;
            }
          }
        }
        found = await search();
      }
      if (const {'request_failed', 'invalid_response', 'query_incomplete', 'detail_budget_exhausted'}.contains(found.reason)) {
        throw const MetadataFailure('special_evidence_incomplete', 0);
      }
      if (found.reason != 'verify_candidate' || found.choices.length != 1) return null;
      final matches = await match(found.choices.single);
      if (matches.length != 1) return null;
      evidence.add(matches.single);
    }
    if (evidence.map((e) => e.identity['id']).toSet().length != 1 ||
        evidence.map((e) => e.parentSubject['id']).toSet().length != 1 ||
        evidence.map((e) => e.subject).toSet().length != files.length ||
        evidence.map((e) => e.file['id']).toSet().length != files.length ||
        evidence.map((e) => e.tv['id']).toSet().length != files.length) return null;
    return evidence;
  }

  Future<bool> _adoptNumberedSpecials(DatabaseExecutor tx, String work,
      List<_SpecialEvidence> evidence) async {
    final protection = (await tx.query('library_work_protection', where: 'work_id=?', whereArgs: [work])).single;
    final rows = await tx.query('scan_bindings', where: 'work_id=?', whereArgs: [work]);
    if (protection['identity_locked'] == 1 || protection['legacy_lock'] == 1 ||
        rows.any((r) => r['state'] != 'pending')) return false;
    final inventory = await _workFiles(tx, work);
    final files = inventory.files.where((f) => f['category'] == 'main').toList();
    if (files.length != evidence.length || evidence.any((e) => e.folder != inventory.folder ||
        !files.any((f) => jsonEncode(f) == jsonEncode(e.file)))) return false;
    const reason = 'verified_standalone_special';
    final scopes = {for (final e in evidence) e.file['id']: LibraryFoundation.newId('file-group:')};
    for (final provider in providers) {
      final row = rows.singleWhere((r) => r['layer'] == 'work' && r['provider'] == provider);
      await _saveDecision(tx, row, provider == 'tmdb' ? {
        ...evidence.first.identity, 'special_inventory': _specialInventory(files),
        'special_groups': scopes.values.toList(),
      } : evidence.first.parentSubject, reason: reason, by: reason);
    }
    for (final e in evidence) {
      final asset = e.file['id'] as String, scope = scopes[e.file['id']]!;
      await tx.insert('scan_file_groups', {'scope': scope, 'work_id': work,
        'directory': _directoryScope(e.file['relative_path'] as String, inventory.folder),
        'name': '${e.tv['title']}'.substring(0, '${e.tv['title']}'.length.clamp(0, 80))});
      await tx.insert('scan_file_group_members', {'asset_id': asset, 'scope': scope});
      for (final provider in providers) {
        final tmdb = provider == 'tmdb';
        final workRow = (await _row(tx, _id(work, provider, 'work', '')))!;
        await _put(tx, work, provider, 'range', scope, parent: _token(workRow));
        final range = (await _row(tx, _id(work, provider, 'range', scope)))!;
        final chapter = tmdb ? e.tv : e.bg;
        await _saveDecision(tx, range, {
          if (tmdb) ...{'season': 0, 'first': chapter['sort'], 'last': chapter['sort'], 'offset': 0}
          else ...{'id': e.subject, 'offset': 0,
            'title': _title(e.subjectDetails),
            'year': _year(e.subjectDetails),
            'summary': e.subjectDetails['summary'],
            if (e.subjectDetails['images'] case final Map images)
              'poster': images['large'] ?? images['common'],
          },
          'chapters': [chapter],
        }, reason: reason, by: reason);
        final saved = (await _row(tx, range['id'] as String))!;
        await _put(tx, work, provider, 'episode', asset, asset: asset, parent: _token(saved));
        final episode = (await _row(tx, _id(work, provider, 'episode', asset)))!;
        await _saveDecision(tx, episode, {
          'title': chapter['title'], 'chapter_id': chapter['id'],
          if (chapter['still'] != null) 'still': chapter['still'],
          if (tmdb) ...{'season': 0, 'episode': chapter['sort']}
          else ...{'id': chapter['id'], 'subject': e.subject, 'sort': chapter['sort']},
        }, reason: reason, by: reason);
      }
    }
    return true;
  }

  Future<_SpecialEvidence?> _standaloneSpecial(TaskLease lease, String raw,
      String title, int? year, Map subject, {String? asset, String? ordinal}) async {
    final inventory = await _workFiles(tasks.db, lease.workId!);
    final files = inventory.files.where((f) => f['category'] == 'main' &&
        (asset == null || f['id'] == asset)).toList();
    if (files.length != 1 || files.single['file_group'] != null ||
        files.single['content_state'] != 'current') return null;
    final subjectId = subject['id'] as int;
    final details = await _get(metadataResource('bangumi', 'subjects/$subjectId'), lease);
    if (details['id'] != subjectId || (year != null && _year(details) != year) ||
        !PersonalMetadataScraper.officialTitles(details).any((a) => PersonalMetadataScraper.exactTitle(a, title))) return null;
    final relations = await _get(metadataResource('bangumi',
        'subjects/$subjectId/subjects', listResponse: true), lease);
    final parent = (relations['data'] as List).whereType<Map>().where((r) =>
        r['type'] == 2 && (r['relation'] == '主线故事' ||
            ordinal != null && r['relation'] == '相同世界观') && _positive(r['id'])).singleOrNull;
    if (parent == null) return null;
    final names = [parent['name'], parent['name_cn']].whereType<String>().where((s) => s.isNotEmpty).toList();
    if (names.isEmpty) return null;
    final search = await _search(lease, 'tmdb', names.first, names.first, null,
        const <int>{}, const <String>{}, names, filenameFallback: true);
    if (const {'request_failed', 'invalid_response', 'query_incomplete', 'detail_budget_exhausted'}.contains(search.reason)) {
      throw const MetadataFailure('special_evidence_incomplete', 0);
    }
    final found = search.choices.where((c) => c['type'] == 'tv' && c['exact'] == true).singleOrNull;
    if (search.reason != 'verify_candidate' || found == null) return null;
    final series = await _get(metadataResource('tmdb', 'tv/${found['id']}',
        parameters: {'append_to_response': 'alternative_titles,translations'}), lease);
    if (series['id'] != found['id'] ||
        !(series['seasons'] as List? ?? []).whereType<Map>().any((s) => s['season_number'] == 0)) return null;
    final aliases = PersonalMetadataScraper.officialTitles(series);
    if (!aliases.any((a) => PersonalMetadataScraper.exactTitle(a, names.first))) return null;
    final episodes = await _fetchChapters(lease, 'bangumi', id: subjectId);
    if (!episodes.complete || episodes.chapters.length != 1) return null;
    final bg = episodes.chapters.single;
    if ((ordinal == null ? bg['sort'] != 1 : bg['sort'] != files.single['episode']) ||
        ![0, 1].contains(bg['type'])) return null;
    final chapters = await Future.wait([
      _fetchChapters(lease, 'tmdb', id: found['id'] as int,
          season: 0, languageOverride: 'ja-JP'),
      _fetchChapters(lease, 'tmdb', id: found['id'] as int,
          season: 0, languageOverride: 'en-US'),
    ]);
    final original = chapters[0], english = chapters[1];
    if (!original.complete || !english.complete || original.chapters.length != english.chapters.length) return null;
    String? suffix(String text) {
      final normalized = PersonalMetadataScraper.normalize(text);
      final prefixes = aliases.map(PersonalMetadataScraper.normalize).where((s) => s.length >= 5).toList()
        ..sort((a, b) => b.length.compareTo(a.length));
      for (final prefix in prefixes) {
        if (normalized.startsWith(prefix) && normalized.length > prefix.length) return normalized.substring(prefix.length);
      }
      return null;
    }
    final filename = PersonalFilenameParser.extractAnimeSearchKeyword(files.single['name'] as String);
    final fileSuffix = suffix(filename);
    final matches = <Map<String, Object?>>[];
    for (final chapter in original.chapters) {
      final translated = english.chapters.where((c) => c['id'] == chapter['id'] &&
          c['sort'] == chapter['sort'] && c['date'] == chapter['date']).singleOrNull;
      if (translated == null) return null;
      final date = DateTime.tryParse('${chapter['date']}');
      final bgDate = DateTime.tryParse('${bg['date']}') ??
          (asset != null ? DateTime.tryParse('${details['date']}') : null);
      if (date == null || bgDate == null ||
          date.difference(bgDate).abs() > Duration(days: ordinal == null ? 1 : 3)) continue;
      // Strip only kana readings immediately following kanji, not arbitrary
      // parenthetical subtitles. Dates and unique official parent still apply.
      String withoutReading(String value) => value.replaceAllMapped(
          RegExp(r'([一-龯])[（(][ぁ-ゖァ-ヶー]{1,12}[）)]'), (m) => m[1]!);
      final exactChapter = _chapterAgreement(
          {...chapter, 'verification_title': withoutReading('${chapter['verification_title'] ?? chapter['title']}')},
          {...bg, 'verification_title': withoutReading('${bg['verification_title'] ?? bg['title']}')});
      final translatedSuffix = suffix('${translated['title']}');
      final specificFilename = fileSuffix != null && fileSuffix.length >= 8 && fileSuffix == translatedSuffix;
      // Some special titles abbreviate the series and translate a subtitle.
      // Require a word-boundary suffix of an official series name, plus an
      // exact distinctive main title on both sides of explicit separators.
      final translatedParts = '${translated['title']}'.split(':');
      final prefix = translatedParts.first.trim().toLowerCase();
      final shortenedSeries = translatedParts.length == 2 && prefix.split(RegExp(r'\s+')).length >= 2 &&
          prefix.length >= 8 && aliases.any((a) => a.toLowerCase().endsWith(' $prefix'));
      final mainTitle = shortenedSeries ? PersonalMetadataScraper.normalize(
          translatedParts.last.split(RegExp('[~～〜]')).first) : '';
      final fileMain = suffix(filename.split(RegExp(r'\s+-\s+')).first);
      final translatedMainMatch = asset != null && ordinal == null && mainTitle.length >= 12 &&
          (mainTitle == fileMain || mainTitle == fileSuffix);
      final shortSpecialName = fileSuffix != null && const {'ss', 'sp', 'special', 'summerspecial'}.contains(fileSuffix);
      final subjectSuffix = suffix(_chapterTitle('${details['name']}'));
      final chapterSuffix = PersonalMetadataScraper.normalize(_chapterTitle('${chapter['title']}'));
      final numberedName = ordinal != null && fileSuffix != null && fileSuffix.length >= 5 &&
          subjectSuffix != null && subjectSuffix.length >= 12 &&
          subjectSuffix == chapterSuffix &&
          PersonalMetadataScraper.normalize('${translated['title']}'.split(':').first) == '$fileSuffix${ordinal.toLowerCase()}';
      if (numberedName || ordinal == null && (specificFilename || translatedMainMatch || exactChapter && (shortSpecialName ||
          PersonalMetadataScraper.officialTitles(details).any((a) => PersonalMetadataScraper.exactTitle(a, filename))))) {
        matches.add({...chapter, 'title': translated['title'], 'verification_title': chapter['title']});
      }
    }
    final match = matches.singleOrNull;
    if (match == null) return null;
    return (subjectDetails: details, identity: {...found, 'aliases': aliases.toList(), 'standalone_subject': subjectId,
      'special_inventory': _specialInventory(files),
      'seasons': [{'season': 0, 'count': original.chapters.length, 'year': null}],
      if (series['backdrop_path'] is String) 'backdrop_path': series['backdrop_path']},
      tv: match, bg: bg, file: files.single, folder: inventory.folder, subject: subjectId,
      parentSubject: {'id': parent['id'], 'type': 'anime', 'title': _title(parent),
        'aliases': names});
  }

  Future<bool> _pendingAutomaticRetry(DatabaseExecutor tx, String work) async {
    final guard = (await tx.query('library_work_protection', where: 'work_id=?', whereArgs: [work])).single;
    if (guard['identity_locked'] == 1 || guard['legacy_lock'] == 1) return false;
    final rows = await tx.query('scan_bindings', where: 'work_id=?', whereArgs: [work]);
    final tv = rows.where((r) => r['provider'] == 'tmdb' && r['layer'] == 'work').singleOrNull;
    final bg = rows.where((r) => r['provider'] == 'bangumi' && r['layer'] == 'work').singleOrNull;
    if (tv?['state'] == 'pending' && tv?['previous'] == null &&
        const {'verify_candidate', 'conflicting_title'}.contains(tv?['reason']) &&
        bg?['reason'] == 'verified_bangumi') {
      final subject = adopted(bg!);
      final candidate = candidates(tv!).singleOrNull;
      if (candidate?['type'] == 'tv' && candidate?['exact'] == true &&
          subject?['exact'] == true && subject?['directory_title_matches'] == true) {
        final matches = (candidate?['seasons'] as List? ?? []).whereType<Map>().where(
          (s) => _positive(s['season']) && s['year'] == subject?['year'] && _positive(s['count']),
        );
        if (matches.isNotEmpty) {
          final inventory = await _workFiles(tx, work);
          final main = inventory.files.where((f) => f['category'] == 'main').length;
          if (main >= 9 && main <= 40 && matches.any((s) => s['count'] == main-1)) return true;
        }
      }
    }
    if (tv?['state'] == 'pending' && tv?['previous'] == null &&
        const {'untyped_id', 'verify_candidate', 'conflicting_title'}.contains(tv?['reason']) &&
        bg?['state'] == 'confirmed' && bg?['reason'] == 'verified_bangumi' &&
        adopted(bg!)?['directory_title_matches'] == true) {
      final movie = candidates(tv!).where((row) => row['type'] == 'movie').singleOrNull;
      if (movie != null) {
        final local = await _workFiles(tx, work);
        if (_singleMoviePremiereYear(movie, local.files, Catalog.year(p.posix.basename(local.folder)),
            subject: adopted(bg)) ==
            movie['year'] && movie['year'] is int) return true;
      }
    }
    if (_bangumiAliasRetryYear(tv, bg) != null) return true;
    if (tv?['state'] == 'confirmed' && tv?['reason'] == 'verified_tmdb' &&
        !rows.any((row) => row['provider'] == 'tmdb' && row['layer'] == 'range' &&
            row['state'] == 'confirmed' && adopted(row)?['season'] != 0)) {
      final inventory = await _workFiles(tx, work);
      final selection = adopted(tv!);
      if (selection != null &&
          _recoverableTvRanges(inventory, selection, bg).isNotEmpty) {
        return true;
      }
    }
    if (bg?['state'] == 'pending' && bg?['reason'] == 'conflicting_title' &&
        await _verifiedTvDisambiguatesMovieAlias(
          tx, work, candidates(bg!).singleOrNull,
        )) {
      return true;
    }
    if (rows.every((r) => r['state'] == 'pending') && _canRevisitSeason(tv, bg)) return true;
    const automatic = {'verified_tmdb', 'verified_bangumi', 'verified_tv_chapters',
      'verified_tv_mapping', 'verified_numbering', 'verified_standalone_special'};
    if (rows.any((r) => r['layer'] == 'work' && r['state'] == 'pending' &&
        workQueryIncomplete(r['reason'])) && rows.every((r) => r['state'] == 'pending' ||
        r['state'] == 'confirmed' && automatic.contains(r['reason']) && adopted(r)?['by'] == r['reason'])) {
      return true;
    }
    const retryable = {'no_match', 'request_failed'};
    if (tv?['state'] == 'pending' && retryable.contains(tv?['reason']) &&
        bg?['state'] == 'pending' && retryable.contains(bg?['reason']) &&
        rows.every((r) => r['state'] == 'pending')) {
      final files = (await _workFiles(tx, work)).files.where((f) => f['category'] == 'main').toList();
      return _numberedSupplementIds(files).isNotEmpty ||
          files.length >= 2 && files.length <= 6 && files.every((f) => f['file_group'] == null);
    }
    if (tv?['state'] != 'pending' || !retryable.contains(tv?['reason']) ||
        bg?['reason'] != 'verified_bangumi' || adopted(bg!)?['by'] != 'verified_bangumi' ||
        rows.any((r) => r['layer'] != 'work' && r['state'] != 'pending')) return false;
    return (await _workFiles(tx, work)).files.where((f) => f['category'] == 'main').length == 1;
  }

  static int? _bangumiAliasRetryYear(
    Map<String, Object?>? tmdb,
    Map<String, Object?>? bangumi,
  ) {
    if (bangumi?['state'] != 'pending' || bangumi?['reason'] != 'no_match' ||
        bangumi?['previous'] != null || tmdb?['state'] != 'confirmed' ||
        tmdb?['reason'] != 'verified_tmdb') return null;
    final choice = adopted(tmdb!);
    final year = choice?['year'];
    if (choice?['by'] != 'verified_tmdb' || choice?['exact'] != true ||
        year is! int || (choice?['aliases'] as List? ?? []).whereType<String>().isEmpty) {
      return null;
    }
    if (choice?['type'] == 'movie') return year;
    final regular = (choice?['seasons'] as List? ?? []).whereType<Map>()
        .where((season) => _positive(season['season'])).singleOrNull;
    return choice?['type'] == 'tv' && regular?['year'] == year ? year : null;
  }

  Future<bool> _rejectTvRecutOfOva(
    TaskLease lease,
    ({String folder, List<Map<String, Object?>> files}) inventory,
    List<Map<String, Object?>> bindings,
  ) async {
    final tvRow = bindings.where((row) =>
        row['layer'] == 'work' && row['provider'] == 'tmdb').single;
    final bgRow = bindings.where((row) =>
        row['layer'] == 'work' && row['provider'] == 'bangumi').single;
    final tv = adopted(tvRow);
    final bg = adopted(bgRow);
    final subjectId = bg?['id'];
    final year = bg?['year'];
    final tvYear = tv?['year'];
    if (tv?['type'] != 'tv' || tv?['directory_title_matches'] != false ||
        tv?['directory_subject'] != subjectId || bg?['exact'] != true ||
        bg?['directory_title_matches'] != true || subjectId is! int ||
        year is! int || tvYear is! int || tvYear <= year) return false;
    final regular = inventory.files.where((file) => file['category'] == 'main').toList();
    if (regular.length < 2 || !regular.every(_singleRegularFile)) return false;
    final numbers = regular.map((file) => file['episode']).toSet();
    if (!List.generate(regular.length, (index) => index + 1).every(numbers.contains)) {
      return false;
    }
    final seasons = (tv?['seasons'] as List? ?? []).whereType<Map>()
        .where((season) => _positive(season['season']));
    if (!_unmarkedPartialTvRange(p.posix.basename(inventory.folder), tv!, regular,
        seasons.singleOrNull?['count'])) return false;
    try {
      final official = await _get(metadataResource('bangumi', 'subjects/$subjectId'), lease);
      final name = p.posix.basename(inventory.folder);
      if (official['id'] != subjectId || official['type'] != 2 ||
          official['platform'] != 'OVA' || official['eps'] != regular.length ||
          _year(official) != year ||
          !PersonalMetadataScraper.officialTitles(official).any((title) =>
              _sameLocalTitle(title, name))) return false;
    } on MetadataFailure {
      return false;
    }
    var corrected = false;
    await tasks.commit(lease, (tx) async {
      final work = lease.workId!;
      final current = await _automaticConflict(tx, work);
      final latest = await _workFiles(tx, work);
      if (jsonEncode(current) != jsonEncode(bindings) ||
          latest.folder != inventory.folder ||
          jsonEncode(latest.files) != jsonEncode(inventory.files)) {
        throw const TaskStopped();
      }
      // Preserve the original decisions for review, including episode stills.
      for (final row in bindings.where((row) => row['provider'] == 'tmdb')) {
        await tx.update('scan_bindings', {
          'state': 'pending',
          'reason': row['layer'] == 'work' ? 'conflicting_title' : 'parent_changed',
          'adopted': null,
          'previous': row['adopted'] ?? row['previous'],
          'revision': (row['revision'] as int) + 1,
        }, where: 'id=?', whereArgs: [row['id']]);
      }
      corrected = true;
      return {'corrected_tv_recut': true};
    });
    return corrected;
  }

  static bool _datedFilm(Map<String, Object?> file) =>
      file['file_group'] == null && file['content_state'] == 'current' &&
      CloudMediaAssetPresentation.isIndependentMovie(file) &&
      Catalog.year(file['name'] as String) != null;

  static Future<bool> _hasMixedFilmCandidate(DatabaseExecutor tx, String work) async {
    final files = await tx.rawQuery(
      r"""SELECT a.name,a.relative_path,a.category,a.episode,c.state AS content_state
      FROM assets a JOIN library_content c ON c.asset_id=a.id
      JOIN library_work_protection p ON p.work_id=a.work_id
      WHERE a.work_id=? AND a.category='main' AND a.episode IS NULL
        AND c.state='current' AND p.identity_locked=0 AND p.legacy_lock=0
        AND NOT EXISTS (SELECT 1 FROM scan_missing_assets m WHERE m.asset_id=a.id)
        AND NOT EXISTS (SELECT 1 FROM scan_file_group_members m WHERE m.asset_id=a.id)
        AND EXISTS (SELECT 1 FROM scan_bindings b WHERE b.work_id=a.work_id
          AND b.layer='work' AND b.provider='tmdb' AND b.state='confirmed'
          AND b.reason='verified_tmdb' AND json_extract(b.adopted,'$.type')='tv')
        AND EXISTS (SELECT 1 FROM scan_bindings b WHERE b.work_id=a.work_id
          AND b.layer='work' AND b.provider='bangumi' AND b.state='confirmed'
          AND b.reason='verified_bangumi')""",
      [work],
    );
    return files.any(_datedFilm);
  }

  static String _filmTitleWithPartNumber(String title) => title.replaceFirstMapped(
    RegExp(r'\b(?:part|movie)\s+(one|two|three|[1-9])$', caseSensitive: false),
    (match) {
      final part = match[1]!.toLowerCase();
      return 'Part ${const {'one': 1, 'two': 2, 'three': 3}[part] ?? part}';
    },
  );

  Future<bool> _splitRelatedFilms(
    TaskLease lease,
    ({String folder, List<Map<String, Object?>> files}) inventory,
  ) async {
    final films = inventory.files.where(_datedFilm).take(4).toList();
    if (films.isEmpty || !inventory.files.any(_singleRegularFile)) return false;
    final work = lease.workId!, source = lease.sourceId!;
    final tv = await _row(tasks.db, _id(work, 'tmdb', 'work', ''));
    final bg = await _row(tasks.db, _id(work, 'bangumi', 'work', ''));
    final subjectId = bg == null ? null : adopted(bg)?['id'];
    if (tv == null || tv['state'] != 'confirmed' || tv['reason'] != 'verified_tmdb' ||
        adopted(tv)?['type'] != 'tv' || bg?['state'] != 'confirmed' ||
        bg?['reason'] != 'verified_bangumi' || subjectId is! int) return false;
    final guard = (await tasks.db.query('library_work_protection',
      where: 'work_id=?', whereArgs: [work])).single;
    if (guard['identity_locked'] == 1 || guard['legacy_lock'] == 1) return false;
    final subjects = <Map<String, dynamic>>[];
    Future<List<int>> related(int id, Set<String> relations) async {
      final body = await _get(metadataResource('bangumi', 'subjects/$id/subjects',
          listResponse: true), lease);
      return (body['data'] as List? ?? []).whereType<Map>()
          .where((row) => row['type'] == 2 && relations.contains(row['relation']) && row['id'] is int)
          .map((row) => row['id'] as int).take(4).toList();
    }
    try {
      final initial = await related(subjectId, {'不同演绎', '剧场版'});
      final ids = <int>{...initial};
      for (final id in initial.take(2)) {
        ids.addAll(await related(id, {'续集'}));
      }
      for (final id in ids.take(6)) {
        final details = await _get(metadataResource('bangumi', 'subjects/$id'), lease);
        if (details['id'] == id && details['type'] == 2 &&
            const {'剧场版', '劇場版', '电影', '映画', 'Movie'}.contains(details['platform'])) {
          subjects.add(details);
        }
      }
    } on MetadataFailure {
      return false;
    }
    var changed = false;
    for (final file in films) {
      final filename = file['name'] as String;
      final year = Catalog.year(filename)!;
      final subject = subjects.where((row) => _year(row) == year).singleOrNull;
      if (subject == null || subject['name'] is! String) continue;
      final original = subject['name'] as String;
      final release = p.posix.basenameWithoutExtension(filename)
          .replaceAll(RegExp(r'[._]+'), ' ')
          .split(RegExp('(?<![0-9])$year(?![0-9])')).first.trim();
      if (release.length < 8) continue;
      final result = await _search(lease, 'tmdb', original, original, year, {}, {'movie'},
          [original, release, _filmTitleWithPartNumber(release)],
          movieReleaseYear: year, filenameFallback: true);
      if (workQueryIncomplete(result.reason)) continue;
      final candidate = result.choices.where((choice) {
        final names = (choice['aliases'] as List? ?? []).whereType<String>();
        return choice['type'] == 'movie' && choice['year'] == year &&
            names.any((name) => _sameLocalTitle(name, original));
      }).singleOrNull;
      if (candidate == null) continue;
      Map<String, dynamic> details;
      try {
        details = await _get(metadataResource('tmdb', 'movie/${candidate['id']}',
          parameters: {'language': 'en-US', 'append_to_response': 'alternative_titles,translations'}), lease);
      } on MetadataFailure {
        continue;
      }
      final aliases = PersonalMetadataScraper.officialTitles(details);
      if (details['id'] != candidate['id'] || _year(details) != year ||
          !aliases.any((name) => _sameLocalTitle(name, original)) ||
          !aliases.any((name) => _sameLocalTitle(
              _filmTitleWithPartNumber(name), _filmTitleWithPartNumber(release)))) {
        continue;
      }
      final movie = <String, Object?>{...candidate, 'aliases': aliases.take(12).toList()};
      final asset = file['id'] as String;
      final path = file['relative_path'] as String;
      final moved = await tasks.db.transaction((tx) async {
        await tasks.checkIn(tx, lease);
        final current = await _row(tx, tv['id'] as String);
        final currentSubject = await _row(tx, bg!['id'] as String);
        final protection = (await tx.query('library_work_protection',
          where: 'work_id=?', whereArgs: [work])).single;
        if (current?['revision'] != tv['revision'] ||
            currentSubject?['revision'] != bg['revision'] ||
            protection['identity_locked'] == 1 || protection['legacy_lock'] == 1) return false;
        final latest = (await _workFiles(tx, work)).files
            .where((row) => row['id'] == asset).singleOrNull;
        if (latest == null || jsonEncode(latest) != jsonEncode(file) ||
            (await tx.query('asset_overrides', where: 'asset_id=?', whereArgs: [asset])).isNotEmpty ||
            (await tx.query('scan_bindings', where: "asset_id=? AND state!='pending'",
              whereArgs: [asset])).isNotEmpty ||
            await LibraryFoundation.locate(tx, 'work', source, path) != null) return false;
        final id = LibraryFoundation.newId('work:$source:id-');
        final row = <String, Object?>{'id': id, 'title': _title(subject), 'year': year};
        await tx.insert('works', row);
        await LibraryFoundation.attach(tx, 'work', id, source, path);
        await LibraryFoundation.seedWork(tx, row);
        await tx.delete('scan_bindings', where: "asset_id=? AND state='pending'", whereArgs: [asset]);
        await tx.update('assets', {'work_id': id}, where: 'id=?', whereArgs: [asset]);
        final images = subject['images'];
        for (final provider in providers) {
          final choice = provider == 'tmdb' ? movie : {
            'id': subject['id'], 'title': _title(subject), 'type': 'anime',
            'movie': true, 'year': year, 'summary': subject['summary'],
            if (images is Map && images['large'] is String) 'poster': images['large'],
          };
          await _put(tx, id, provider, 'work', '', choices: [choice]);
          final binding = (await _row(tx, _id(id, provider, 'work', '')))!;
          await _saveDecision(tx, binding, choice, reason: 'verified_movie', by: 'verified_movie');
        }
        lease.check();
        return true;
      });
      changed |= moved;
    }
    return changed;
  }

  static Map<String, Map> _recoverableTvRanges(
    ({String folder, List<Map<String, Object?>> files}) inventory,
    Map<String, Object?> identity,
    Map<String, Object?>? bangumi,
  ) {
    final raw = p.posix.basename(inventory.folder);
    final planned = _tmdbRanges(inventory, identity, raw);
    final explicit = <String, Set<int>>{};
    final numbers = <String, List<int>>{};
    final dualNumbers = <String, List<({int season, int episode, int absolute})>>{};
    for (final file in inventory.files.where((file) =>
        _singleRegularFile(file, allowDualNumbers: true))) {
      final scope = file['file_group'] as String? ??
          _directoryScope(file['relative_path'] as String, inventory.folder);
      final dual = _dualEpisodeNumber(file['name'] as String);
      final season = dual?.season ?? _explicitFileSeason(file['name'] as String);
      explicit.putIfAbsent(scope, () => {}).add(season ?? -1);
      numbers.putIfAbsent(scope, () => []).add(file['episode'] as int);
      if (dual != null) dualNumbers.putIfAbsent(scope, () => []).add(dual);
    }
    planned.removeWhere((scope, range) =>
        explicit[scope]?.singleOrNull != range['season']);
    final subject = bangumi == null ? null : adopted(bangumi);
    final year = subject?['year'];
    if (bangumi?['reason'] == 'verified_bangumi' &&
        subject?['by'] == 'verified_bangumi' && subject?['exact'] == true &&
        subject?['directory_title_matches'] == true && subject?['movie'] != true &&
        year is int && WorkSeason.year({'title': raw}) == null) {
      final dated = _tmdbRanges(inventory, identity, raw, corroboratedYear: year);
      for (final entry in dated.entries) {
        final scope = entry.key;
        final count = entry.value['count'] as int;
        final local = numbers[scope]!;
        if (entry.value['year'] == year && local.length == count &&
            local.toSet().length == count && local.every((n) => n >= 1 && n <= count)) {
          planned.putIfAbsent(scope, () => entry.value);
        }
      }
    }
    for (final entry in dualNumbers.entries) {
      planned.remove(entry.key);
      final number = explicit[entry.key]?.singleOrNull;
      final folderSeason = WorkSeason.explicit({'title': raw});
      final folderYear = WorkSeason.year({'title': raw});
      if (number == null || number < 2 || WorkSeason.multiple({'title': raw}) ||
          WorkSeason.part(raw) != null ||
          (folderSeason != null && folderSeason != number)) continue;
      final seasons = (identity['seasons'] as List? ?? []).whereType<Map>();
      final choice = seasons.where((s) => s['season'] == number).singleOrNull;
      if (choice == null) continue;
      final count = choice['count'];
      if (count is! int || count < 2 || count > 100 ||
          entry.value.length != count || numbers[entry.key]?.length != count ||
          (folderYear != null && folderYear != choice['year']) ||
          subject?['year'] is! int || subject?['year'] != choice['year'] ||
          bangumi?['reason'] != 'verified_bangumi' ||
          subject?['by'] != 'verified_bangumi' || subject?['exact'] != true ||
          subject?['directory_title_matches'] != true) continue;
      final precedingCounts = [
        for (var season = 1; season < number; season++)
          seasons.where((s) => s['season'] == season).singleOrNull?['count'],
      ];
      if (!precedingCounts.every(_positive)) continue;
      final preceding = precedingCounts.cast<int>().fold(0, (a, b) => a + b);
      if (entry.value.map((e) => e.episode).toSet().length == count &&
          entry.value.every((e) => e.season == number && e.episode >= 1 &&
              e.episode <= count && e.absolute == preceding + e.episode)) {
        planned[entry.key] = {...choice, 'offset': -preceding};
      }
    }
    return planned;
  }

  Future<bool> _repairVerifiedTvRanges(
    TaskLease lease,
    ({String folder, List<Map<String, Object?>> files}) inventory,
  ) async {
    final work = lease.workId!;
    final identity = await _row(tasks.db, _id(work, 'tmdb', 'work', ''));
    if (identity?['state'] != 'confirmed' ||
        identity?['reason'] != 'verified_tmdb') return false;
    final selected = adopted(identity!);
    if (selected?['type'] != 'tv' || selected?['by'] != 'verified_tmdb') return false;
    final protection = (await tasks.db.query('library_work_protection',
      where: 'work_id=?', whereArgs: [work])).single;
    if (protection['identity_locked'] == 1 || protection['legacy_lock'] == 1) return false;
    final bangumi = await _row(tasks.db, _id(work, 'bangumi', 'work', ''));
    final planned = _recoverableTvRanges(inventory, selected!, bangumi);
    if (planned.isEmpty) return false;
    final eligible = <String, Map>{};
    for (final entry in planned.entries) {
      final range = await _row(tasks.db, _id(work, 'tmdb', 'range', entry.key));
      if (range == null || range['state'] == 'pending') eligible[entry.key] = entry.value;
    }
    if (eligible.isEmpty) return false;
    final evidence = <int, Map<String, Object?>>{};
    for (final season in eligible.values.toSet()) {
      final number = season['season'] as int;
      final count = season['count'] as int;
      final result = await _fetchChapters(lease, 'tmdb', id: selected['id'] as int,
        season: number);
      final sorts = result.chapters.map((chapter) => chapter['sort']).toSet();
      if (result.complete && result.chapters.length == count &&
          result.chapters.map((chapter) => chapter['id']).toSet().length == count &&
          List.generate(count, (index) => index + 1).every(sorts.contains)) {
        evidence[number] = {
          'chapters': result.chapters,
          'summary': result.summary,
          'summary_language': result.language,
        };
      }
    }
    if (evidence.isEmpty) return false;
    await tasks.commit(lease, (tx) async {
      final current = await _row(tx, identity['id'] as String);
      final currentSubject = await _row(tx, _id(work, 'bangumi', 'work', ''));
      final guard = (await tx.query('library_work_protection', where: 'work_id=?',
        whereArgs: [work])).single;
      final latest = await _workFiles(tx, work);
      if (current?['revision'] != identity['revision'] ||
          currentSubject?['revision'] != bangumi?['revision'] ||
          guard['identity_locked'] == 1 || guard['legacy_lock'] == 1 ||
          latest.folder != inventory.folder ||
          jsonEncode(latest.files) != jsonEncode(inventory.files)) {
        throw const TaskStopped();
      }
      var scopes = 0;
      for (final entry in eligible.entries) {
        final number = entry.value['season'] as int;
        final chapters = evidence[number];
        if (chapters == null) continue;
        final id = _id(work, 'tmdb', 'range', entry.key);
        final before = await _row(tx, id);
        if (before != null && before['state'] != 'pending') continue;
        await _put(tx, work, 'tmdb', 'range', entry.key, parent: _token(identity));
        final range = (await _row(tx, id))!;
        await _saveDecision(tx, range, {
          'season': number, 'first': 1, 'last': entry.value['count'],
          'offset': entry.value['offset'] ?? 0,
          if (entry.value['offset'] != null) 'dual_numbering': true,
          ...chapters,
        }, reason: 'verified_tmdb', by: 'verified_tmdb');
        scopes++;
      }
      if (scopes > 0) await _syncChildren(tx, work, 'tmdb');
      return {'recovered_tv_ranges': scopes};
    });
    await catalog.reload();
    return true;
  }

  Future<bool> _verifiedTvDisambiguatesMovieAlias(
    DatabaseExecutor tx,
    String work,
    Map<String, Object?>? subject,
  ) async {
    if (subject?['type'] != 'anime' || subject?['exact'] != true ||
        subject?['directory_title_matches'] != true || subject?['year'] == null) {
      return false;
    }
    final tv = await _row(tx, _id(work, 'tmdb', 'work', ''));
    if (tv?['state'] != 'confirmed' || tv?['reason'] != 'verified_tmdb') {
      return false;
    }
    final series = adopted(tv!);
    if (series?['type'] != 'tv' || series?['by'] != 'verified_tmdb' ||
        series?['exact'] != true ||
        series?['directory_title_matches'] != true ||
        series?['year'] != subject!['year']) {
      return false;
    }
    final competitors = candidates(tv)
        .where((candidate) => candidate['exact'] == true &&
            (candidate['type'] != 'tv' || candidate['id'] != series!['id']))
        .toList();
    if (competitors.isEmpty || competitors.any((candidate) =>
        candidate['type'] != 'movie' || candidate['directory_title_matches'] == true)) {
      return false;
    }
    final ranges = await tx.query('scan_bindings',
      where: "work_id=? AND provider='tmdb' AND layer='range' AND state='confirmed' AND reason='verified_tmdb' AND parent=?",
      whereArgs: [work, _token(tv)],
    );
    return ranges.any((range) {
      final choice = adopted(range);
      return choice?['by'] == 'verified_tmdb' &&
          ((choice?['season'] as int?) ?? 0) > 0 &&
          (choice?['chapters'] as List?)?.isNotEmpty == true;
    });
  }

  static bool _canRevisitSeason(Map<String, Object?>? tv, Map<String, Object?>? bg) {
    if (tv == null || bg == null || tv['state'] != 'pending' || bg['state'] != 'pending' ||
        tv['reason'] != 'conflicting_title' ||
        !const {'verify_candidate', 'conflicting_title'}.contains(bg['reason'])) return false;
    final series = candidates(tv).singleOrNull;
    final subject = candidates(bg).singleOrNull;
    return series?['type'] == 'tv' && series?['exact'] == true &&
        series?['directory_title_matches'] == false &&
        subject?['type'] == 'anime' && subject?['exact'] == true &&
        subject?['directory_title_matches'] == true;
  }

  Future<bool> _adoptStandaloneSpecial(DatabaseExecutor tx, String work, _SpecialEvidence evidence) async {
    final protection = (await tx.query('library_work_protection', where: 'work_id=?', whereArgs: [work])).single;
    final all = await tx.query('scan_bindings', where: 'work_id=?', whereArgs: [work]);
    if (protection['identity_locked'] == 1 || protection['legacy_lock'] == 1 ||
        all.any((r) => r['state'] == 'skipped' || r['state'] == 'confirmed' &&
            !(r['layer'] == 'work' && r['provider'] == 'bangumi' &&
                r['reason'] == 'verified_bangumi' && adopted(r)?['by'] == 'verified_bangumi'))) return false;
    final inventory = await _workFiles(tx, work);
    final files = inventory.files.where((f) => f['category'] == 'main').toList();
    if (inventory.folder != evidence.folder || files.length != 1 ||
        jsonEncode(files.single) != jsonEncode(evidence.file)) return false;
    final bgWork = all.singleWhere((r) => r['layer'] == 'work' && r['provider'] == 'bangumi');
    if ((adopted(bgWork) ?? candidates(bgWork).singleOrNull)?['id'] != evidence.subject) return false;
    const reason = 'verified_standalone_special';
    final scope = _directoryScope(evidence.file['relative_path'] as String, inventory.folder);
    for (final provider in providers) {
      final tmdb = provider == 'tmdb';
      final identity = all.singleWhere((r) => r['layer'] == 'work' && r['provider'] == provider);
      if (identity['state'] != 'confirmed') await _saveDecision(tx, identity,
          tmdb ? evidence.identity : candidates(identity).single, reason: reason, by: reason);
      final current = (await _row(tx, identity['id'] as String))!;
      await _put(tx, work, provider, 'range', scope, parent: _token(current));
      final range = (await _row(tx, _id(work, provider, 'range', scope)))!;
      final chapter = tmdb ? evidence.tv : evidence.bg;
      await _saveDecision(tx, range, {
        if (tmdb) ...{'season': 0, 'first': chapter['sort'], 'last': chapter['sort'], 'offset': 0}
        else ...{'id': evidence.subject, 'offset': 0},
        'chapters': [chapter],
      }, reason: reason, by: reason);
      final saved = (await _row(tx, range['id'] as String))!;
      final asset = evidence.file['id'] as String;
      await _put(tx, work, provider, 'episode', asset, asset: asset, parent: _token(saved));
      final episode = (await _row(tx, _id(work, provider, 'episode', asset)))!;
      await _saveDecision(tx, episode, {
        'title': chapter['title'], 'chapter_id': chapter['id'],
        if (chapter['still'] != null) 'still': chapter['still'],
        if (tmdb) ...{'season': 0, 'episode': chapter['sort']}
        else ...{'id': chapter['id'], 'subject': evidence.subject, 'sort': chapter['sort']},
      }, reason: reason, by: reason);
    }
    return true;
  }

  static Future<({String folder, List<Map<String, Object?>> files})> _workFiles(
    DatabaseExecutor tx,
    String work,
  ) async {
    final location = await tx.query(
      'library_locations',
      columns: ['relative_path'],
      where: "kind='work' AND entity_id=?",
      whereArgs: [work],
    );
    final files = await tx.rawQuery(
      '''SELECT a.*,c.state AS content_state,m.scope AS file_group
      FROM assets a JOIN library_content c ON c.asset_id=a.id
      LEFT JOIN scan_file_group_members m ON m.asset_id=a.id
      WHERE a.work_id=? AND NOT EXISTS (SELECT 1 FROM scan_missing_assets x WHERE x.asset_id=a.id)
      ORDER BY a.relative_path''',
      [work],
    );
    return (folder: location.single['relative_path'] as String, files: files);
  }

  Future<List<Map<String, Object?>>> groupFiles(
    Map<String, Object?> preview,
  ) async {
    return tasks.db.transaction((tx) async {
      final row = await _checkedReview(tx, preview);
      return _groupFiles(tx, row);
    });
  }

  Future<List<Map<String, Object?>>> _groupFiles(
    DatabaseExecutor tx,
    Map row,
  ) async {
    if (row['layer'] != 'range') throw StateError('Select a directory range');
    final work = row['work_id'] as String;
    final scope = row['scope'] as String;
    final group = (await tx.query(
      'scan_file_groups',
      where: 'scope=?',
      whereArgs: [scope],
    )).firstOrNull;
    final inventory = await _workFiles(tx, work);
    final directory = group?['directory'] as String? ?? scope;
    return [
      for (final file in inventory.files)
        if ((file['file_group'] == null ||
                file['file_group'] == group?['scope']) &&
            _directoryScope(
                  file['relative_path'] as String,
                  inventory.folder,
                ) ==
                directory)
          {...file, 'group_revision': group?['revision']},
    ];
  }

  Future<void> saveFileGroup(
    Map<String, Object?> preview,
    String name,
    Set<String> selected, {
    int? groupRevision,
  }) async {
    await tasks.db.transaction((tx) async {
      final row = await _checkedReview(tx, preview);
      final files = await _groupFiles(tx, row);
      final currentScope = row['scope'] as String;
      final work = row['work_id'] as String;
      final group = (await tx.query(
        'scan_file_groups',
        where: 'scope=?',
        whereArgs: [currentScope],
      )).firstOrNull;
      if (group?['revision'] != groupRevision ||
          !files.map((file) => file['id']).toSet().containsAll(selected)) {
        throw StateError('Group files changed');
      }
      final label = name.trim();
      if ((selected.isEmpty && group == null) ||
          (selected.isNotEmpty && (label.isEmpty || label.length > 80))) {
        throw const FormatException('A group needs a name and files');
      }
      final scope = group == null
          ? LibraryFoundation.newId('file-group:')
          : currentScope;
      final previous = {
        for (final member in await tx.query(
          'scan_file_group_members',
          where: 'scope=?',
          whereArgs: [scope],
        ))
          member['asset_id'] as String,
      };
      // Keep unavailable members associated with the group while editing the
      // files currently visible. Explicitly emptying it removes the group.
      final available = files.map((file) => file['id']).toSet();
      final next = {
        ...selected,
        if (selected.isNotEmpty)
          ...previous.where((id) => !available.contains(id)),
      };
      if (next.isEmpty) {
        await tx.delete(
          'scan_file_groups',
          where: 'scope=?',
          whereArgs: [scope],
        );
      } else if (group == null) {
        await tx.insert('scan_file_groups', {
          'scope': scope,
          'work_id': work,
          'directory': currentScope,
          'name': label,
        });
      } else {
        await tx.update(
          'scan_file_groups',
          {'name': label, 'revision': (group['revision'] as int) + 1},
          where: 'scope=?',
          whereArgs: [scope],
        );
      }
      final removed = previous.difference(next);
      final added = next.difference(previous);
      for (final asset in removed) {
        await tx.delete(
          'scan_file_group_members',
          where: 'asset_id=?',
          whereArgs: [asset],
        );
      }
      for (final asset in added) {
        await tx.insert('scan_file_group_members', {
          'asset_id': asset,
          'scope': scope,
        });
      }
      for (final asset in {...removed, ...added}) {
        await tx.rawUpdate(
          '''UPDATE scan_bindings SET revision=revision+1, parent=NULL,
          state='pending', reason='group_changed', previous=COALESCE(adopted,previous), adopted=NULL
          WHERE asset_id=?''',
          [asset],
        );
      }
      for (final provider in providers) {
        await _syncChildren(tx, work, provider);
      }
    });
    await catalog.reload();
  }

  static const _movieAttachmentReason = 'verified_movie_attachment';
  static final _moviePromotionSuffix = RegExp(
    r'[\s._–—-]+(劇場予告編|予告編|予告|預告片|预告片|預告|预告|特報|特报|trailer|teaser)$',
    caseSensitive: false,
  );

  Future<bool> _syncMovieAttachments(DatabaseExecutor tx, String work) async {
    final identities = {
      for (final row in await tx.query('scan_bindings',
          where: "work_id=? AND layer='work'", whereArgs: [work]))
        row['provider'] as String: row,
    };
    final tmdb = adopted(identities['tmdb'] ?? {});
    final bangumi = adopted(identities['bangumi'] ?? {});
    final prior = await tx.query('scan_bindings',
        where: "work_id=? AND layer='episode' AND reason=?",
        whereArgs: [work, _movieAttachmentReason]);
    final verifiedMovie = tmdb?['type'] == 'movie' && bangumi?['movie'] == true &&
        tmdb?['by'] == 'verified_movie' && bangumi?['by'] == 'verified_movie' &&
        tmdb?['year'] is int && tmdb?['year'] == bangumi?['year'];
    if (!verifiedMovie && prior.isEmpty) return false;
    final protection = (await tx.query('library_work_protection',
        where: 'work_id=?', whereArgs: [work])).single;
    if (protection['identity_locked'] == 1 || protection['legacy_lock'] == 1) return false;
    final overrides = (await tx.rawQuery('''
      SELECT o.asset_id FROM asset_overrides o JOIN assets a ON a.id=o.asset_id
      WHERE a.work_id=?
    ''', [work])).map((row) => row['asset_id']).toSet();
    final matches = <String, String>{};
    if (verifiedMovie) {
      final inventory = await _workFiles(tx, work);
      final main = inventory.files.where((file) => file['category'] == 'main').singleOrNull;
      final year = tmdb!['year'] as int;
      bool ungroupedFilmFile(Map<String, Object?> file) {
        final name = file['name'] as String;
        final fileYear = Catalog.year(name);
        return !overrides.contains(file['id']) && file['content_state'] == 'current' &&
            file['file_group'] == null &&
            file['episode'] == null && _explicitFileSeason(name) == null &&
            !WorkSeason.conflictingYears({'title': name}) &&
            (fileYear == null || fileYear == year);
      }

      if (main != null && ungroupedFilmFile(main)) {
        final title = _movieReleaseTitle(
            PersonalFilenameParser.extractAnimeSearchKeyword(main['name'] as String));
        bool agrees(Map identity) => (identity['aliases'] as List? ?? const [])
            .whereType<String>().map(_movieReleaseTitle).contains(title);
        if (title.length >= 4 && agrees(tmdb) && agrees(bangumi!)) {
          final directory = p.posix.dirname(main['relative_path'] as String);
          for (final file in inventory.files) {
            if (file['category'] != 'extra' || !ungroupedFilmFile(file) ||
                p.posix.dirname(file['relative_path'] as String) != directory) {
              continue;
            }
            final name = PersonalFilenameParser.extractAnimeSearchKeyword(file['name'] as String);
            final suffix = _moviePromotionSuffix.firstMatch(name);
            if (suffix == null || _movieReleaseTitle(name.substring(0, suffix.start)) != title) {
              continue;
            }
            matches[file['id'] as String] = const {'特報', '特报', 'teaser'}
                .contains(suffix[1]!.toLowerCase()) ? 'teaser' : 'trailer';
          }
        }
      }
    }
    var changed = false;
    for (final row in prior) {
      final choice = adopted(row);
      if (!overrides.contains(row['asset_id']) && choice?['by'] == _movieAttachmentReason &&
          (matches[row['asset_id']] != choice?['attachment'] ||
              row['parent'] != _token(identities[row['provider']] ?? {}))) {
        await tx.update('scan_bindings', {
          'adopted': null, 'state': 'pending', 'reason': 'separate_file_review',
          'revision': (row['revision'] as int) + 1,
        }, where: 'id=?', whereArgs: [row['id']]);
        changed = true;
      }
    }
    if (matches.isEmpty) return changed;
    for (final entry in matches.entries) {
      for (final provider in providers) {
        final identity = identities[provider]!;
        final id = _id(work, provider, 'episode', entry.key);
        final existing = await _row(tx, id);
        if (existing != null && (existing['state'] != 'pending' ||
            existing['previous'] != null ||
            !const {'separate_file_review', 'parent_changed'}.contains(existing['reason']))) {
          continue;
        }
        await _put(tx, work, provider, 'episode', entry.key, asset: entry.key,
            parent: _token(identity), reason: 'separate_file_review');
        final row = (await _row(tx, id))!;
        await _saveDecision(tx, row, {
          'attachment': entry.value, 'movie_id': adopted(identity)!['id'],
        }, reason: _movieAttachmentReason, by: _movieAttachmentReason);
        changed = true;
      }
    }
    return changed;
  }

  Future<void> _syncChildren(
    DatabaseExecutor tx,
    String work,
    String provider,
  ) async {
    final identity = await _row(tx, _id(work, provider, 'work', ''));
    final source = identity == null ? null : adopted(identity);
    if (source == null) return;
    final inventory = await _workFiles(tx, work);
    final rangeRows = <String, Map<String, Object?>?>{};
    String scopeFor(Map file) =>
        file['file_group'] as String? ??
        _directoryScope(file['relative_path'] as String, inventory.folder);
    final mainScopes = inventory.files
        .where((file) => file['category'] == 'main')
        .map(scopeFor)
        .toSet();
    final mixedSpecials = provider == 'tmdb'
        ? await _row(tx, _id(work, provider, 'range', _mixedSpecialScope))
        : null;
    for (final file in inventory.files) {
      final asset = file['id'] as String;
      final dir = scopeFor(file);
      if (file['category'] == 'extra' &&
          mainScopes.contains(dir) &&
          mixedSpecials != null &&
          mixedSpecials['parent'] == _token(identity!) &&
          adopted(mixedSpecials) != null) {
        final binding = await _row(tx, _id(work, provider, 'episode', asset));
        if (binding?['parent'] == _token(mixedSpecials) &&
            binding?['state'] != 'pending') {
          continue;
        }
      }
      if (catalog.automaticRecognition &&
          !mainScopes.contains(dir) &&
          !_specialCandidate(file))
        continue;
      final movie = source['type'] == 'movie' || source['movie'] == true;
      Map<String, Object?>? parent = identity;
      if (!movie) {
        if (!rangeRows.containsKey(dir)) {
          final main = mainScopes.contains(dir);
          final options = provider == 'tmdb'
              ? (source['seasons'] as List? ?? [])
                    .map(
                      (s) => <String, Object?>{
                        'season': s['season'],
                        'first': 1,
                        'last': s['count'],
                        'offset': 0,
                      },
                    )
                    .where(
                      (s) =>
                          (s['last'] as int) > 0 &&
                          (!catalog.automaticRecognition ||
                              (main ? s['season'] != 0 : s['season'] == 0)),
                    )
                    .toList()
              : <Map<String, Object?>>[
                  {
                    'id': source['id'],
                    'title': source['title'],
                    'poster': source['poster'],
                    'summary': source['summary'],
                  },
                  for (final option in candidates(identity!))
                    if (option['id'] != source['id'] &&
                        option['targets'] != null)
                      {
                        'id': option['id'],
                        'title': option['title'],
                        'poster': option['poster'],
                        'summary': option['summary'],
                        'mapping_version': option['mapping_version'],
                      },
                ];
          await _put(
            tx,
            work,
            provider,
            'range',
            dir,
            parent: _token(identity!),
            reason: 'range_unconfirmed',
            choices: options,
          );
          rangeRows[dir] = await _row(tx, _id(work, provider, 'range', dir));
        }
        parent = rangeRows[dir];
      }
      if (parent == null || adopted(parent) == null) continue;
      if (movie && file['category'] == 'main') continue;
      if (movie && (await _row(tx, _id(work, provider, 'episode', asset)))?['reason'] ==
          _movieAttachmentReason) {
        continue;
      }
      final range = adopted(parent)!;
      final number = file['episode'] as int?;
      final offset = range['offset'] as int? ?? 0;
      final candidate = number == null ? null :
          (provider == 'tmdb' && range['number_map'] is Map
              ? (range['number_map'] as Map)['$number'] as int?
              : number + offset);
      final normal =
          file['category'] == 'main' &&
          file['content_state'] == 'current' &&
          !RegExp(
            r'\d[.]\d',
          ).hasMatch(_episodeFileStem(file['name'] as String));
      final options = <Map<String, Object?>>[
        if (!movie &&
            provider == 'tmdb' &&
            normal &&
            candidate != null &&
            candidate >= (range['first'] as int) &&
            candidate <= (range['last'] as int))
          {'season': range['season'], 'episode': candidate},
      ];
      for (final chapter
          in (range['chapters'] as List? ?? []).whereType<Map>()) {
        if (movie) break;
        if (provider == 'tmdb' &&
            options.isNotEmpty &&
            chapter['sort'] == options.first['episode']) {
          options[0] = {
            ...options.first,
            'title': chapter['title'],
            'chapter_id': chapter['id'],
            if (chapter['still'] != null) 'still': chapter['still'],
          };
        } else if (provider == 'bangumi' &&
            (normal
                ? chapter['type'] == 0 && chapter['sort'] == candidate
                : chapter['type'] == 1) &&
            options.length < 12) {
          options.add({
            'id': chapter['id'],
            'title': chapter['title'],
            'sort': chapter['sort'],
            'chapter_id': chapter['id'],
          });
        }
      }
      if (!movie && provider == 'tmdb') {
        final other = await _row(tx, _id(work, 'bangumi', 'episode', asset));
        final chapter = other == null ? null : adopted(other);
        if (chapter?['subject'] is int && chapter?['id'] is int) {
          final mapping = await catalog.mappingStore!.lookupIn(
            tx,
            chapter!['subject'] as int,
            chapter['id'] as int,
          );
          for (final target in mapping.targets) {
            final episode = target['episode'];
            if (target['type'] != 'tv' ||
                target['id'] != source['id'] ||
                episode is! int ||
                (normal &&
                    (target['season'] != range['season'] ||
                        episode < (range['first'] as int) ||
                        episode > (range['last'] as int)))) {
              continue;
            }
            final documented = options
                .where(
                  (option) =>
                      option['season'] == target['season'] &&
                      option['episode'] == episode,
                )
                .firstOrNull;
            options.removeWhere((option) => option == documented);
            options.add({
              ...?documented,
              'season': target['season'],
              'episode': episode,
              'mapping_version': mapping.version,
              'bangumi_episode': chapter['id'],
              'bangumi_subject': chapter['subject'],
            });
          }
        }
      }
      await _put(
        tx,
        work,
        provider,
        'episode',
        asset,
        asset: asset,
        parent: _token(parent),
        reason: normal ? 'episode_unconfirmed' : 'separate_file_review',
        choices: options,
      );
    }
    if (catalog.automaticRecognition) {
      if (source['type'] == 'movie' || source['movie'] == true) {
        await _syncMovieAttachments(tx, work);
      }
      for (final row in rangeRows.values.nonNulls) {
        if (adopted(row)?['chapters'] == null) continue;
        final preview = await _numberingForRange(tx, row);
        for (final item in preview.matches) {
          await _saveDecision(
            tx,
            item.binding,
            item.choice,
            reason: 'verified_numbering',
            by: 'verified_numbering',
          );
        }
      }
    }
  }

  Future<Map<String, Object?>> _checkedReview(
    DatabaseExecutor tx,
    Map<String, Object?> preview,
  ) async {
    final session = (await tx.query(
      'scrape_runtime',
      columns: ['session'],
    )).single['session'];
    final current = await _row(tx, preview['id'] as String);
    if (session != preview['session'] ||
        current == null ||
        current['revision'] != preview['revision']) {
      throw StateError('Review changed');
    }
    final protection = await tx.rawQuery(
      '''SELECT p.*,w.hidden,w.tmdb_type,w.bangumi_id
      FROM library_work_protection p JOIN works w ON w.id=p.work_id WHERE p.work_id=?''',
      [current['work_id']],
    );
    if (protection.isEmpty ||
        protection.single['revision'] != preview['identity_revision'] ||
        protection.single['legacy_lock'] == 1 ||
        protection.single['hidden'] == 1 ||
        protection.single['tmdb_type'] != null ||
        protection.single['bangumi_id'] != null) {
      throw StateError('Work binding changed');
    }
    if (preview['source_revision'] case final int revision) {
      await LibraryFoundation.checkSource(
        tx,
        preview['source_id'] as String,
        revision,
      );
    }
    return current;
  }

  static int? _explicitFileSeason(String name) {
    final match = RegExp(
      r'(?<![a-z0-9])S(\d{1,2})E\d{1,4}(?![0-9])',
      caseSensitive: false,
    ).firstMatch(name);
    return match == null ? null : int.parse(match[1]!);
  }

  static final _dualEpisodeLabel = RegExp(
    r'(?<![a-z0-9])S([1-9]\d?)\s+-\s+(\d{1,3})(?:\s+(?:end|fin))?\s+\[\s*(\d{1,4})\s*\](?:\s+(?:end|fin)\b)?',
    caseSensitive: false,
  );

  static ({int season, int episode, int absolute})? _dualEpisodeNumber(String name) {
    final match = _dualEpisodeLabel.allMatches(name).singleOrNull;
    if (match == null) return null;
    return (season: int.parse(match[1]!), episode: int.parse(match[2]!),
        absolute: int.parse(match[3]!));
  }

  static String _episodeFileStem(String name) =>
      p.posix.basenameWithoutExtension(name)
        .replaceAll(RegExp(r'(?<![a-z0-9])\d{3,4}p(?![a-z0-9])',
            caseSensitive: false), ' ')
        .replaceAll(RegExp(r'\b(?:[hx][ .]?26[45]|hevc|avc)[ ._-]+(?:8|10|12)bit\b',
            caseSensitive: false), ' ')
        .replaceAll(RegExp(r'\b\d{2,3}\.\d{1,3}fps\b',
            caseSensitive: false), ' ');

  static bool _singleRegularFile(Map file, {bool allowDualNumbers = false}) {
    final name = _episodeFileStem(file['name'] as String);
    final dual = allowDualNumbers ? _dualEpisodeNumber(name) : null;
    final label = dual != null && dual.absolute == file['episode']
        ? name.replaceFirst(_dualEpisodeLabel, ' ')
        : name;
    return file['category'] == 'main' &&
        file['content_state'] == 'current' &&
        _positive(file['episode']) &&
        !RegExp(
          r'\d[.]\d|\d\s*[-–~～]\s*(?:S\d{1,2})?E?\d',
          caseSensitive: false,
        ).hasMatch(label);
  }

  Future<ScanNumberingPreview> previewNumbering(Map<String, Object?> range) =>
      tasks.db.transaction((tx) => _numbering(tx, range));

  Future<ScanNumberingPreview> _numbering(
    DatabaseExecutor tx,
    Map<String, Object?> preview,
  ) async => _numberingForRange(tx, await _checkedReview(tx, preview));

  Future<ScanNumberingPreview> _numberingForRange(
    DatabaseExecutor tx,
    Map<String, Object?> row,
  ) async {
    final range = adopted(row);
    if (row['layer'] != 'range' || range == null) {
      throw StateError('Range is not confirmed');
    }
    final work = row['work_id'] as String;
    final provider = row['provider'] as String;
    final identity = await _row(tx, _id(work, provider, 'work', ''));
    if (identity == null ||
        row['parent'] != _token(identity) ||
        adopted(identity) == null) {
      throw StateError('Identity changed');
    }
    final tmdb = provider == 'tmdb';
    final inventory = await _workFiles(tx, work);
    final bindings = {
      for (final binding in await tx.query(
        'scan_bindings',
        where: "work_id=? AND provider=? AND layer='episode' AND parent=?",
        whereArgs: [work, provider, _token(row)],
      ))
        binding['asset_id']: binding,
    };
    final matches = <ScanNumberingMatch>[];
    final deferred = <String>[];
    final numbers = <int, int>{};
    (Object?, Object?) target(Map choice) => tmdb
        ? (choice['season'], choice['episode'])
        : (choice['subject'] ?? range['id'], choice['id']);
    final claimed = {
      for (final binding in bindings.values)
        if (adopted(binding) case final choice?) target(choice),
    };
    final files = inventory.files.where(
      (file) =>
          (file['file_group'] ??
              _directoryScope(
                file['relative_path'] as String,
                inventory.folder,
              )) ==
          row['scope'],
    );
    final offset = range['offset'] as int? ?? 0;
    bool regularForRange(Map<String, Object?> file) {
      if (range['dual_numbering'] != true) return _singleRegularFile(file);
      final dual = _dualEpisodeNumber(file['name'] as String);
      return dual != null && dual.season == range['season'] &&
          dual.episode == dual.absolute + offset &&
          _singleRegularFile(file, allowDualNumbers: true);
    }
    for (final file in files.where(regularForRange)) {
      final number = file['episode'] as int;
      numbers.update(number, (count) => count + 1, ifAbsent: () => 1);
    }
    for (final file in files) {
      final binding = bindings[file['id']];
      if (binding?['state'] == 'confirmed') continue;
      final path = file['relative_path'] as String;
      final local = file['episode'] as int?;
      final season = _explicitFileSeason(file['name'] as String);
      if (binding == null ||
          binding['state'] != 'pending' ||
          !regularForRange(file) ||
          numbers[local] != 1 ||
          (tmdb && season != null && season != range['season'])) {
        deferred.add(path);
        continue;
      }
      final number = tmdb && range['number_map'] is Map
          ? (range['number_map'] as Map)['$local'] as int?
          : local! + (range['offset'] as int? ?? 0);
      final options = candidates(binding);
      if (options.length != 1 ||
          options.single['chapter_id'] == null ||
          options.single[tmdb ? 'episode' : 'sort'] != number ||
          (tmdb && options.single['season'] != range['season'])) {
        deferred.add(path);
        continue;
      }
      final choice = {...options.single, if (!tmdb) 'subject': range['id']};
      if (claimed.contains(target(choice))) {
        deferred.add(path);
        continue;
      }
      matches.add((binding: binding, path: path, choice: choice));
    }
    return ScanNumberingPreview(matches, deferred);
  }

  Future<void> applyNumbering(
    Map<String, Object?> range,
    ScanNumberingPreview preview,
  ) async {
    await tasks.db.transaction((tx) async {
      final latest = await _numbering(tx, range);
      List<Object?> fingerprint(ScanNumberingPreview value) => [
        for (final item in value.matches)
          [
            item.binding['id'],
            item.binding['revision'],
            item.path,
            item.choice,
          ],
        value.deferred,
      ];
      if (latest.matches.isEmpty ||
          jsonEncode(fingerprint(latest)) != jsonEncode(fingerprint(preview))) {
        throw StateError('Numbering preview changed');
      }
      for (final item in latest.matches) {
        await _saveDecision(
          tx,
          item.binding,
          item.choice,
          reason: 'confirmed_numbering',
        );
      }
      if (range['provider'] == 'bangumi') {
        await _syncChildren(tx, range['work_id'] as String, 'tmdb');
      }
    });
    await catalog.reload();
  }

  static Future<void> _saveDecision(
    DatabaseExecutor tx,
    Map row,
    Map? choice, {
    bool skip = false,
    String reason = 'manual_confirmed',
    String by = 'user',
  }) async {
    if (choice != null) _validateChoice(row, choice);
    await tx.update(
      'scan_bindings',
      {
        'revision': (row['revision'] as int) + 1,
        'state': skip
            ? 'skipped'
            : choice == null
            ? 'pending'
            : 'confirmed',
        'adopted': choice == null ? null : jsonEncode({...choice, 'by': by}),
        'previous': row['adopted'],
        if (choice != null) 'reason': reason,
      },
      where: 'id=?',
      whereArgs: [row['id']],
    );
  }

  static bool _positive(Object? value) =>
      value is int && value > 0 && value <= 2147483647;
  static bool _season(Object? value) =>
      value is int && value >= 0 && value <= 999;

  static void _validateChoice(Map row, Map choice) {
    final tmdb = row['provider'] == 'tmdb';
    final layer = row['layer'];
    if (layer == 'work' &&
        (!_positive(choice['id']) ||
            !(tmdb ? ['tv', 'movie'] : ['anime']).contains(choice['type']))) {
      throw const FormatException('Invalid provider identity');
    }
    if (layer == 'range' &&
        (tmdb
            ? !_season(choice['season']) ||
                  !_positive(choice['first']) ||
                  !_positive(choice['last']) ||
                  (choice['last'] as int) < (choice['first'] as int) ||
                  choice['offset'] is! int ||
                  (choice['offset'] as int).abs() > 10000
            : !_positive(choice['id']) ||
                  (choice['offset'] != null &&
                      (choice['offset'] is! int ||
                          (choice['offset'] as int).abs() > 10000)))) {
      throw const FormatException('Invalid range');
    }
    if (layer == 'episode' && choice.containsKey('attachment')) {
      if (!const {'trailer', 'teaser'}.contains(choice['attachment']) ||
          !_positive(choice['movie_id']) ||
          const {'id', 'season', 'episode', 'chapter_id'}.any(choice.containsKey)) {
        throw const FormatException('Invalid movie attachment');
      }
      return;
    }
    if (layer == 'episode' &&
        (tmdb
            ? !_season(choice['season']) || !_positive(choice['episode'])
            : !_positive(choice['id']) ||
                  (choice['subject'] != null &&
                      !_positive(choice['subject'])))) {
      throw const FormatException('Invalid episode');
    }
  }

  /// Revisions are optimistic locks, including when undoing a decision.
  Future<void> decide(
    Map<String, Object?> preview,
    Map<String, Object?>? choice, {
    bool skip = false,
    bool undo = false,
  }) async {
    await tasks.db.transaction((tx) async {
      final current = await _checkedReview(tx, preview);
      final parent = current['parent'] as String?;
      Map<String, dynamic>? parentChoice;
      if (parent != null) {
        final token = jsonDecode(parent) as List;
        final row = await _row(tx, token[0] as String);
        if (row == null ||
            row['revision'] != token[1] ||
            adopted(row) == null) {
          throw StateError('Parent binding changed');
        }
        parentChoice = adopted(row);
      }
      final previous = current['previous'] as String?;
      final next = undo
          ? (previous == null
                ? null
                : jsonDecode(previous) as Map<String, dynamic>)
          : choice;
      if (skip && adopted(current) != null) {
        throw StateError('Binding already adopted');
      }
      final work = current['work_id'] as String;
      final provider = current['provider'] as String;
      final layer = current['layer'] as String;
      if (layer == 'episode') {
        final files = await tx.rawQuery(
          '''SELECT c.state FROM assets a
          JOIN library_content c ON c.asset_id=a.id WHERE a.id=? AND a.work_id=?
          AND NOT EXISTS (SELECT 1 FROM scan_missing_assets m WHERE m.asset_id=a.id)''',
          [current['asset_id'], work],
        );
        if (files.isEmpty || files.single['state'] != 'current') {
          throw StateError('File changed');
        }
      }
      await _saveDecision(
        tx,
        current,
        next == null
            ? null
            : {
                ...next,
                if (provider == 'bangumi' && layer == 'episode')
                  'subject': next['subject'] ?? parentChoice!['id'],
              },
        skip: skip,
      );
      // A parent change invalidates its children, never the other provider.
      if (layer != 'episode' && !skip) {
        await tx.rawUpdate(
          '''UPDATE scan_bindings SET revision=revision+1,state='pending',
            reason='parent_changed',previous=COALESCE(adopted,previous),adopted=NULL
            WHERE work_id=? AND provider=? AND ${layer == 'work' ? "layer!='work'" : "layer='episode' AND parent=?"}''',
          [work, provider, if (layer != 'work') _token(current)],
        );
      }
      await _syncChildren(tx, work, provider);
      if (provider == 'bangumi' && layer == 'episode') {
        await _syncChildren(tx, work, 'tmdb');
      }
      if (layer == 'work' && catalog.automaticRecognition) {
        await _syncMovieAttachments(tx, work);
      }
      if (layer != 'episode')
        await ScopedArtwork.publishDrafts(catalog, tx, work);
    });
    await catalog.reload();
  }

  Future<void> auditMappings() async {
    final store = catalog.mappingStore!;
    final session = (await tasks.db.query(
      'scrape_runtime',
      columns: ['session'],
    )).single['session'];
    final rows = await tasks.db.query(
      'scan_bindings',
      where:
          "provider='tmdb' AND layer='episode' AND state='confirmed' AND adopted LIKE '%bangumi_subject%'",
    );
    var changedAny = false;
    for (final row in rows) {
      try {
        AnimeMappingStore.checkForeground();
      } on TaskPaused {
        break;
      }
      await tasks.db.transaction((tx) async {
        if ((await tx.query(
              'scrape_runtime',
              columns: ['session'],
            )).single['session'] !=
            session) {
          return;
        }
        final current = await _row(tx, row['id'] as String);
        if (current?['revision'] != row['revision'] ||
            current?['adopted'] != row['adopted']) {
          return;
        }
        final choice = adopted(row)!;
        if (choice['bangumi_subject'] is! int ||
            choice['bangumi_episode'] is! int) {
          return;
        }
        final identity = await _row(
          tx,
          _id(row['work_id'] as String, 'tmdb', 'work', ''),
        );
        if (identity == null || adopted(identity) == null) return;
        final mapping = await store.lookupIn(
          tx,
          choice['bangumi_subject'] as int,
          choice['bangumi_episode'] as int,
        );
        if (mapping.version == null || mapping.state == 'not_acquired') return;
        final tv = adopted(identity)!['id'];
        final same = mapping.targets.any(
          (t) =>
              t['type'] == 'tv' &&
              t['id'] == tv &&
              t['season'] == choice['season'] &&
              t['episode'] == choice['episode'],
        );
        final changed = !same || mapping.targets.length != 1;
        if (!changed &&
            mapping.version == choice['mapping_version'] &&
            row['reason'] != 'mapping_changed') {
          return;
        }
        final options = [
          for (final t in mapping.targets)
            if (t['type'] == 'tv' && t['id'] == tv)
              {
                'season': t['season'],
                'episode': t['episode'],
                'mapping_version': mapping.version,
                'bangumi_subject': choice['bangumi_subject'],
                'bangumi_episode': choice['bangumi_episode'],
              },
        ];
        final next = {
          if (changed) ...{
            'reason': 'mapping_changed',
            'candidates': jsonEncode(options),
          } else ...{
            'reason': 'manual_confirmed',
            'adopted': jsonEncode({
              ...choice,
              'mapping_version': mapping.version,
            }),
          },
        };
        if (next.entries.every((entry) => row[entry.key] == entry.value)) {
          return;
        }
        await tx.update(
          'scan_bindings',
          {...next, 'revision': (row['revision'] as int) + 1},
          where: 'id=?',
          whereArgs: [row['id']],
        );
        changedAny = true;
      });
    }
    if (changedAny) await catalog.reload();
  }

  static void validateSnapshot(Map<String, dynamic> tables) {
    final works = {for (final row in tables['works'] as List) row['id']};
    final assets = {
      for (final row in tables['assets'] as List) row['id']: row['work_id'],
    };
    final groups = <String, Object?>{};
    final labels = <(Object?, Object?, Object?)>{};
    for (final group in (tables['scan_file_groups'] as List? ?? [])) {
      final scope = group['scope'];
      final name = group['name'];
      if (scope is! String ||
          !RegExp(r'^file-group:[a-f0-9]{32}$').hasMatch(scope) ||
          groups.containsKey(scope) ||
          !works.contains(group['work_id']) ||
          !labels.add((group['work_id'], group['directory'], name)) ||
          group['directory'] is! String ||
          name is! String ||
          name.trim().isEmpty ||
          name.length > 80 ||
          group['revision'] is! int ||
          group['revision'] < 0) {
        throw const FormatException('Invalid scan file group');
      }
      groups[scope] = group['work_id'];
    }
    final members = <Object?>{};
    for (final member in (tables['scan_file_group_members'] as List? ?? [])) {
      if (!members.add(member['asset_id']) ||
          !groups.containsKey(member['scope']) ||
          assets[member['asset_id']] != groups[member['scope']]) {
        throw const FormatException('Invalid scan file group membership');
      }
    }
    for (final row in tables['scan_bindings'] as List) {
      if (!works.contains(row['work_id']) ||
          !providers.contains(row['provider']) ||
          !layers.contains(row['layer']) ||
          row['scope'] is! String ||
          row['revision'] is! int ||
          row['revision'] < 0 ||
          !['pending', 'confirmed', 'skipped'].contains(row['state']) ||
          (row['layer'] == 'episode' &&
              assets[row['asset_id']] != row['work_id']) ||
          row['id'] !=
              _id(
                row['work_id'],
                row['provider'],
                row['layer'],
                row['scope'],
              )) {
        throw const FormatException('Invalid recognition binding');
      }
      final choices = candidates(row);
      if (choices.length > 100 ||
          (row['state'] == 'confirmed') != (row['adopted'] != null)) {
        throw const FormatException('Invalid recognition choices');
      }
      if (adopted(row) case final choice?) _validateChoice(row, choice);
    }
  }

  static String _partFieldScope(Map binding) {
    final choice = adopted(binding)!;
    return jsonEncode([
      'part_overview',
      binding['id'],
      choice['id'],
      choice['season'],
      choice['first'],
      choice['last'],
    ]);
  }

  static Future<Map<String, Object?>?> partOverviewPreview(
    Catalog catalog,
    String binding,
  ) async {
    return catalog.db.transaction((tx) async {
      final row = await _row(tx, binding);
      if (row == null || row['layer'] != 'range' || adopted(row) == null)
        return null;
      final scope = _partFieldScope(row);
      final field = (await tx.query(
        'library_fields',
        where: "work_id=? AND scope=? AND field='overview'",
        whereArgs: [row['work_id'], scope],
      )).firstOrNull;
      final session = (await tx.query('scrape_runtime')).single['session'];
      return {
        'work': row['work_id'],
        'binding': binding,
        'scope': scope,
        'session': session,
        'binding_revision': row['revision'],
        'field_revision': field?['revision'] ?? -1,
        'automatic': adopted(row)!['summary'],
        'provider': row['provider'],
        'value': switch (field?['mode']) {
          'manual' => jsonDecode(field!['manual_json'] as String),
          'empty' => null,
          _ => adopted(row)!['summary'],
        },
      };
    });
  }

  static Future<void> savePartOverview(
    Catalog catalog,
    Map preview,
    String mode,
    String? value,
  ) async {
    if (!['manual', 'empty', 'auto'].contains(mode) ||
        (mode == 'manual' &&
            (value == null || value.trim().isEmpty || value.length > 16000))) {
      throw const FormatException('Invalid part overview');
    }
    await catalog.db.transaction((tx) async {
      final row = await _row(tx, preview['binding'] as String);
      final work = preview['work'];
      final scope = preview['scope'];
      final session = (await tx.query('scrape_runtime')).single['session'];
      if (row == null ||
          adopted(row) == null ||
          row['work_id'] != work ||
          row['revision'] != preview['binding_revision'] ||
          _partFieldScope(row) != scope ||
          session != preview['session'] ||
          adopted(row)!['summary'] != preview['automatic']) {
        throw const TaskStopped();
      }
      final field = (await tx.query(
        'library_fields',
        where: "work_id=? AND scope=? AND field='overview'",
        whereArgs: [work, scope],
      )).firstOrNull;
      if ((field?['revision'] ?? -1) != preview['field_revision'] ||
          (mode == 'auto' && preview['automatic'] == null)) {
        throw const TaskStopped();
      }
      if (field != null) {
        await tx.insert('library_field_history', {
          'id': LibraryFoundation.newId('field:'),
          'work_id': work,
          'scope': scope,
          'field': 'overview',
          'revision': field['revision'],
          'previous_json': jsonEncode(field),
        });
        await tx.rawDelete(
          '''DELETE FROM library_field_history WHERE work_id=? AND scope=? AND field='overview'
          AND id NOT IN (SELECT id FROM library_field_history WHERE work_id=? AND scope=? AND field='overview'
            ORDER BY revision DESC LIMIT 32)''',
          [work, scope, work, scope],
        );
      }
      await tx.insert('library_fields', {
        'work_id': work,
        'scope': scope,
        'field': 'overview',
        'mode': mode,
        'revision': ((field?['revision'] as int?) ?? -1) + 1,
        'automatic_revision': 0,
        'automatic_source': row['provider'],
        'automatic_json': preview['automatic'] == null
            ? null
            : jsonEncode(preview['automatic']),
        'manual_json': mode == 'manual' ? jsonEncode(value!.trim()) : null,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }

  /// Older libraries keep their normal detail path. For managed works only
  /// verified scopes may contribute provider details.
  static Future<Map<String, dynamic>?> details(
    Catalog catalog,
    Map<String, Object?> work,
  ) async {
    if (!catalog.recognitionEnabled ||
        work['tmdb_type'] != null ||
        work['bangumi_id'] != null) {
      return null;
    }
    final id = work['id'] as String;
    final rows = await catalog.db.rawQuery(
      '''SELECT b.*,g.name AS group_name,l.relative_path AS work_folder FROM scan_bindings b
      LEFT JOIN library_content c ON c.asset_id=b.asset_id
      LEFT JOIN scan_file_groups g ON b.layer='range' AND g.scope=b.scope
      LEFT JOIN library_locations l ON l.kind='work' AND l.entity_id=b.work_id
      WHERE b.work_id=? AND (b.asset_id IS NULL OR (c.state='current' AND
        NOT EXISTS (SELECT 1 FROM scan_missing_assets m WHERE m.asset_id=b.asset_id)))
      ORDER BY CASE b.provider WHEN 'bangumi' THEN 0 ELSE 1 END,b.scope''',
      [id],
    );
    if (rows.isEmpty) return null;
    final saved = rows.where((r) => r['state'] == 'confirmed');
    final tvWork = saved.where((r) => r['provider'] == 'tmdb' &&
        r['layer'] == 'work' && r['reason'] == 'verified_tmdb').singleOrNull;
    final tvChoice = tvWork == null ? null : adopted(tvWork);
    final subject = saved.where((r) => r['provider'] == 'bangumi' &&
        r['layer'] == 'work' && r['reason'] == 'verified_bangumi').map(adopted).singleOrNull;
    final raw = p.posix.basename(tvWork?['work_folder'] as String? ?? '');
    final rejected = <String>{};
    if (tvChoice?['type'] == 'tv' && tvChoice?['marker'] != true &&
        subject?['exact'] == true && subject?['directory_title_matches'] == true &&
        subject?['year'] is int && tvChoice?['year'] is int &&
        subject?['year'] != tvChoice?['year'] &&
        WorkSeason.year({'title': raw}) == null &&
        WorkSeason.explicit({'title': raw}) == null) {
      final tvRanges = saved.where((r) => r['provider'] == 'tmdb' &&
          r['layer'] == 'range' && (adopted(r)?['season'] as int? ?? 0) > 0).toList();
      if (tvRanges.any((row) => row['reason'] == 'verified_tmdb')) {
        final files = (await _workFiles(catalog.db, id)).files.where(_singleRegularFile);
        for (final range in tvRanges.where((row) => row['reason'] == 'verified_tmdb')) {
          final choice = adopted(range)!;
          final scope = range['scope'] as String;
          if (choice['offset'] != 0 || choice['first'] != 1 ||
              WorkSeason.explicit({'title': p.posix.basename(scope)}) != null) continue;
          final regular = files.where((file) => (file['file_group'] ??
              _directoryScope(file['relative_path'] as String, tvWork!['work_folder'] as String)) == scope);
          if (regular.isNotEmpty &&
              _unmarkedPartialTvRange(raw, tvChoice!, regular, choice['last'])) {
            rejected.add(_token(range));
          }
        }
        if (rejected.isNotEmpty && rejected.length == tvRanges.length) {
          rejected.add(_token(tvWork!));
        }
      }
    }
    final confirmed = rejected.isEmpty ? saved : saved.where((r) =>
        !rejected.contains(_token(r)) && !rejected.contains(r['parent']));
    final identities = confirmed.where((r) => r['layer'] == 'work');
    final ranges = confirmed.where((r) => r['layer'] == 'range');
    final movie = identities.any(
      (r) => adopted(r)?['type'] == 'movie' || adopted(r)?['movie'] == true,
    );
    final tmdb = identities
        .where((r) => r['provider'] == 'tmdb')
        .map(adopted)
        .firstOrNull;
    final people = <int>{
      for (final row in (movie ? identities : ranges))
        if (row['provider'] == 'bangumi' &&
            (movie ||
                rows.any(
                  (r) =>
                      r['parent'] == _token(row) &&
                      r['reason'] != 'separate_file_review',
                )))
          if (adopted(row)?['id'] case final int id) id,
    };
    if (people.isEmpty &&
        catalog.forWork(id).any((file) => file['category'] == 'main')) {
      for (final row in identities.where(
        (row) => row['provider'] == 'bangumi',
      )) {
        if (adopted(row)?['id'] case final int subject) people.add(subject);
      }
    }
    final title = identities.length == 1 && ranges.isEmpty &&
            tmdb?['by'] == 'verified_tmdb' &&
            tmdb?['directory_title_matches'] == false &&
            tmdb?['directory_subject'] is int
        ? work['title'] as String?
        : identities
        .map((r) => adopted(r)?['title'])
        .whereType<String>()
        .firstOrNull;
    final descriptions = <Object?, Map<String, Object?>>{};
    final language = AppLanguage.instance.metadataLanguage;
    final partFields = catalog.scopedArtworkEnabled
        ? {
            for (final field in await catalog.db.query(
              'library_fields',
              where: "work_id=? AND field='overview'",
              whereArgs: [id],
            ))
              field['scope']: field,
          }
        : const <Object?, Map<String, Object?>>{};
    for (final row in [
      ...ranges,
      ...identities.where(
        (r) =>
            adopted(r)?['type'] == 'movie' ||
            adopted(r)?['movie'] == true ||
            (r['provider'] == 'bangumi' &&
                !ranges.any((range) => range['provider'] == 'bangumi')),
      ),
    ]) {
      final choice = adopted(row)!;
      if (choice['season'] == 0) continue;
      final field = row['layer'] == 'range'
          ? partFields[_partFieldScope(row)]
          : null;
      final summary = switch (field?['mode']) {
        'manual' => jsonDecode(field!['manual_json'] as String),
        'empty' => '',
        _ =>
          row['provider'] == 'bangumi'
              ? AppLanguage.bangumiSynopsis(choice['summary'], language)
              : (choice['summary_language'] ?? 'zh-CN') == language &&
                    (choice['summary']?.toString().trim().isNotEmpty ?? false)
              ? choice['summary']
              : null,
      };
      final old = descriptions[row['scope']];
      if (old != null &&
          (old['mode'] == 'manual' ||
              old['mode'] == 'empty' ||
              (old['summary'] != null &&
                  !(row['provider'] == 'bangumi' &&
                      summary != null &&
                      old['provider'] != 'bangumi'))))
        continue;
      descriptions[row['scope']] = {
        if (row['provider'] == 'bangumi' && choice['id'] is int)
          'bangumi_subject': choice['id'],
        if (row['provider'] == 'bangumi' && choice['title'] is String)
          'bangumi_title': choice['title'],
        if (choice['poster'] case final String poster
            when MetadataServers.imageResource(poster) != null) 'poster': poster,
        'label':
            choice['title'] ??
            row['group_name'] ??
            (row['scope'] == '' ? null : row['scope']),
        'summary': summary,
        'mode': field?['mode'],
        'provider': row['provider'],
        if (row['layer'] == 'range') 'binding': row['id'],
        if (row['layer'] != 'range' && old?['binding'] != null)
          'binding': old!['binding'],
        if (summary == null && row['provider'] == 'tmdb' && tmdb != null)
          'overview_target': {
            'id': tmdb['id'],
            'type': tmdb['type'],
            'season': choice['season'],
          },
      };
    }
    final titleField = await LibraryFoundation(catalog.db).field(id, 'title');
    final overviewField = await LibraryFoundation(
      catalog.db,
    ).field(id, 'overview');
    final fileDetails = <Object?, Map<String, Object?>>{};
    final stillChoices =
        catalog.scopedArtworkEnabled && !catalog.automaticRecognition
        ? {
            for (final row in await catalog.db.query(
              'scoped_artwork',
              where: "work_id=? AND kind='still'",
              whereArgs: [id],
            ))
              row['scope']: row,
          }
        : const <Object?, Map<String, Object?>>{};
    for (final row in [
      ...confirmed.where((r) => r['layer'] == 'episode' && r['provider'] == 'tmdb'),
      ...confirmed.where((r) => r['layer'] == 'episode' && r['provider'] != 'tmdb'),
    ]) {
      final value = adopted(row)!;
      if (value['attachment'] != null) continue;
      final item = fileDetails.putIfAbsent(row['asset_id'], () => {});
      final special = row['provider'] == 'tmdb' && value['season'] == 0;
      if (special) item['special_number'] = value['episode'];
      if (special && row['reason'] == 'verified_standalone_special' &&
          value['chapter_id'] is int) {
        item['localized_special_chapter'] = value['chapter_id'];
      }
      if (value['title'] case final String title when title.trim().isNotEmpty) {
        if (special &&
            CloudMediaAssetPresentation.specialTypeFromTitle(title) != null) {
          item['name'] = title;
        } else {
          item.putIfAbsent('name', () => title);
        }
      }
      if (value['still'] case final String still) {
        if (MetadataServers.imageResource(still)?.$1 == 1)
          item['still'] = still;
      }
      final target =
          catalog.scopedArtworkEnabled && !catalog.automaticRecognition
          ? ScopedArtwork.episodeTarget(rows, row)
          : null;
      if (target != null) {
        item['editable_still'] = true;
        final choice = stillChoices[target.scope.key];
        if (choice?['state'] == 'empty') {
          item.remove('still');
          item['blank_still'] = true;
        } else if (choice?['state'] == 'manual') {
          item['still'] =
              (jsonDecode(choice!['selected'] as String) as Map)['url'];
        }
      }
    }
    final bangumiParts = <int, Map<Object?, Object?>>{
      for (final description in descriptions.values)
        if (description['bangumi_subject'] case final int subject)
          subject: {...description, 'label': description['bangumi_title']},
    };
    final regular = ranges.where((row) => row['provider'] == 'tmdb' &&
        _positive(adopted(row)?['season'])).singleOrNull;
    final regularChoice = regular == null ? null : adopted(regular);
    final regularChapters = (regularChoice?['chapters'] as List? ?? []).whereType<Map>().toList()
      ..sort((a, b) => (a['sort'] as num).compareTo(b['sort'] as num));
    final dates = [
      for (final chapter in regularChapters) DateTime.tryParse('${chapter['date']}'),
    ];
    return {
      if (title != null && titleField['mode'] == 'auto')
        'recognized_title': title,
      'recognized_overview_mode': overviewField['mode'],
      if (descriptions.values.firstOrNull?['summary'] case final String summary
          when overviewField['mode'] == 'auto')
        'overview': summary,
      'recognized_work': identities.length,
      if (tmdb?['type'] is String) 'recognized_tmdb_type': tmdb!['type'],
      if (tmdb?['id'] is int) 'recognized_tmdb_id': tmdb!['id'],
      if (bangumiParts.length == 1 && regularChoice?['first'] == 1 &&
          regularChoice?['last'] == dates.length && dates.length >= 6 &&
          regularChapters.indexed.every((e) => e.$2['sort'] == e.$1 + 1) &&
          dates.every((date) => date != null) &&
          dates.indexed.skip(1).any((e) => e.$2!.difference(dates[e.$1 - 1]!) >= const Duration(days: 45)))
        'recognized_split_dates': [for (final date in dates) date!.toIso8601String()],
      if (movie) 'recognized_movie': true,
      if (movie && tmdb?['type'] == 'movie') ...{
        'recognized_movie_tmdb': tmdb!['id'],
        if (ScopedArtwork.tmdbBackdrop(tmdb['backdrop_path'])
            case final String url)
          'movieStill': url,
      },
      if (catalog.scopedArtworkEnabled && descriptions.isNotEmpty)
        'recognized_synopses': bangumiParts.isEmpty
            ? descriptions.values.where((part) => part['label'] != null).toList()
            : bangumiParts.values.toList(),
      if (catalog.scopedArtworkEnabled)
        'recognized_people': <String, Object?>{
          if (people.isNotEmpty) 'bangumi_ids': jsonEncode(people.toList()),
          if (tmdb != null) ...{
            'tmdb_id': tmdb['id'],
            'tmdb_type': tmdb['type'],
          },
        },
      'recognized_ranges': ranges.length,
      'recognized_episodes': confirmed
          .where((r) => r['layer'] == 'episode')
          .map((r) => r['asset_id'])
          .toSet()
          .length,
      'recognized_pending': rows.where((r) => r['state'] == 'pending').length,
      'recognized_file_details': fileDetails,
    };
  }
}
