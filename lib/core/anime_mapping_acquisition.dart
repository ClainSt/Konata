import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'anime_mapping.dart';
import 'anime_mapping_store.dart';
import 'scrape_tasks.dart';
import 'shared_metadata_requests.dart';

/// On-demand fixed-commit acquisition. No startup work, polling, source writes,
/// bundled data, account token or signed redirect URL persistence.
class AnimeMappingAcquisition {
  AnimeMappingAcquisition(this.store, this.requests);
  final AnimeMappingStore store;
  final SharedMetadataRequests requests;
  ScrapeTasks get tasks => store.tasks;
  static final _busy = Expando<bool>();
  static const individualThreshold = 24;
  static const _base = 'https://api.github.com/repos/open-ani/bangumi-tmdb';
  MetadataResource _resource(String path) => MetadataResource(
    service: 'github',
    resource: path,
    routes: [Uri.parse('$_base/$path')],
    headers: {'Accept': 'application/vnd.github+json'},
  );

  static String chooseMode(int distinctMissing, {int? remaining}) =>
      distinctMissing > min(individualThreshold, max(0, (remaining ?? 60) - 6))
      ? 'bulk'
      : 'detail';

  Future<String> enqueue(
    String version,
    String operation, {
    int? subject,
  }) async {
    if (!AnimeMappingStore.commitPattern.hasMatch(version) ||
        !['release', 'index', 'bulk', 'detail'].contains(operation)) {
      throw const FormatException('Mapping task intent');
    }
    if (operation == 'detail') AnimeMapping.integer(subject);
    final id =
        'mapping:$operation:$version${subject == null ? '' : ':$subject'}';
    await tasks.enqueue(
      id,
      intent: {
        'kind': 'mapping',
        'version': version,
        'operation': operation,
        'subject': ?subject,
      },
      steps: ['acquire'],
      restartComplete: operation != 'release',
    );
    return id;
  }

  Future<String> enqueueDiscovery() => tasks.enqueue(
    'mapping:discover',
    intent: {'kind': 'mapping', 'operation': 'discover'},
    steps: ['acquire'],
    restartComplete: true,
  );

  /// Returns persistent task IDs. Existing valid entries are not re-downloaded
  /// just because the release or small reverse index has advanced.
  Future<List<String>> plan(
    String version,
    Iterable<int> subjects, {
    Set<int> evidence = const {},
  }) async {
    final unique = subjects.toSet();
    if (unique.isEmpty && evidence.isEmpty) return [];
    if (unique.length > AnimeMappingStore.maxSubjects) {
      throw StateError('Mapping demand capacity');
    }
    final missing = <int>[];
    final older = <int>[];
    for (final id in unique) {
      AnimeMapping.integer(id);
      final answer = await store.lookup(id, 0);
      if (answer.version != null &&
          answer.version != version &&
          !['not_acquired', 'conflict'].contains(answer.state) &&
          !evidence.contains(id)) {
        older.add(id);
      }
      if (['not_acquired', 'conflict'].contains(answer.state) &&
          !evidence.contains(id)) {
        missing.add(id);
      }
    }
    final jobs = <String>[];
    final release = await enqueue(version, 'release');
    if ((await tasks.db.query(
      'scrape_tasks',
      where: "id=? AND state='complete'",
      whereArgs: [release],
    )).isEmpty) {
      jobs.add(release);
    }
    final index = (await tasks.db.query('mapping_index')).single;
    if (missing.isNotEmpty &&
        chooseMode(missing.length, remaining: requests.githubRemaining) ==
            'bulk') {
      jobs.add(await enqueue(version, 'bulk'));
    } else {
      if (index['index_version'] != version || index['index_batch'] == null) {
        jobs.add(await enqueue(version, 'index'));
      }
      for (final id in missing) {
        jobs.add(await enqueue(version, 'detail', subject: id));
      }
    }
    for (final id in evidence) {
      jobs.add(await enqueue(version, 'detail', subject: id));
    }
    // On-demand rotation only, never a timer or whole-library refresh. A fixed
    // commit cannot change; review older entries against a newly pinned release.
    final review = await tasks.db.transaction((tx) async {
      final row = (await tx.query('mapping_review')).single;
      final day = tasks.now ~/ const Duration(days: 1).inMilliseconds;
      final used = row['day'] == day ? row['count'] as int : 0;
      final selected = <int>[];
      for (
        var offset = 0;
        offset < older.length && selected.length < 2 - used;
        offset += 128
      ) {
        final ids = older.skip(offset).take(128).toList();
        final found = await tx.query(
          'mapping_controls',
          columns: ['subject'],
          where:
              'subject IN (${List.filled(ids.length, '?').join(',')}) AND checked_at<?',
          whereArgs: [
            ...ids,
            tasks.now - const Duration(days: 28).inMilliseconds,
          ],
          orderBy: 'checked_at,subject',
          limit: 2 - used - selected.length,
        );
        selected.addAll(found.map((r) => r['subject'] as int));
      }
      if (selected.isNotEmpty) {
        await tx.update('mapping_review', {
          'day': day,
          'count': used + selected.length,
        }, where: 'id=1');
      }
      return selected;
    });
    for (final subject in review) {
      jobs.add(await enqueue(version, 'detail', subject: subject));
    }
    return jobs;
  }

  Future<Map<String, dynamic>> _release(
    String version,
    TaskLease lease,
    Directory temp,
  ) async {
    final id = 'mapping:release:$version';
    final saved = await tasks.db.query(
      'scrape_steps',
      where: "task_id=? AND state='complete'",
      whereArgs: [id],
    );
    if (saved.isNotEmpty) {
      return Map<String, dynamic>.from(
        jsonDecode(saved.single['result_json'] as String),
      );
    }
    final release = await requests.get(
      _resource('releases/tags/data-$version'),
      lease,
    );
    if (release['tag_name'] != 'data-$version' ||
        release['draft'] != false ||
        release['prerelease'] != false ||
        release['assets'] is! List) {
      throw const FormatException('Unpinned mapping release');
    }
    final assets = <String, Map<String, dynamic>>{};
    for (final name in ['manifest.json', 'subjects.json', 'episodes.json']) {
      final rows = (release['assets'] as List)
          .where((a) => a is Map && a['name'] == name)
          .toList();
      if (rows.length != 1) {
        throw const FormatException('Incomplete mapping release');
      }
      final asset = rows.single as Map;
      final number = AnimeMapping.integer(asset['id']);
      final size = AnimeMapping.integer(asset['size']);
      final digest = asset['digest'];
      if (digest is! String ||
          !RegExp(r'^sha256:[a-f0-9]{64}$').hasMatch(digest)) {
        throw const FormatException('Missing asset checksum');
      }
      final limit = name == 'manifest.json'
          ? 16384
          : name == 'subjects.json'
          ? 8 * 1024 * 1024
          : 96 * 1024 * 1024;
      if (size > limit) throw const FormatException('Mapping asset budget');
      assets[name] = {
        'id': number,
        'sha256': digest.substring(7),
        'size': size,
      };
    }
    final file = File('${temp.path}/manifest.part');
    await _download(assets['manifest.json']!, file, lease, 16384);
    final manifest = jsonDecode(await file.readAsString());
    if (manifest is! Map ||
        manifest['schemaVersion'] != 1 ||
        manifest['sourceCommit'] != version ||
        manifest['sourceDirty'] != false ||
        manifest['counts'] is! Map ||
        manifest['files'] is! Map) {
      throw const FormatException('Invalid mapping manifest');
    }
    for (final name in ['subjects.json', 'episodes.json']) {
      if (manifest['files'][name]?['sha256'] != assets[name]!['sha256']) {
        throw const FormatException('Manifest asset disagreement');
      }
    }
    final subjects = AnimeMapping.integer(
      manifest['counts']['subjects'],
      minimum: 0,
    );
    final episodes = AnimeMapping.integer(
      manifest['counts']['episodes'],
      minimum: 0,
    );
    if (subjects > AnimeMappingStore.maxSubjects ||
        episodes > AnimeMappingStore.maxEpisodes) {
      throw const FormatException('Mapping count budget');
    }
    await store.registerVersion(version);
    final old = await tasks.db.rawQuery(
      'SELECT DISTINCT version FROM mapping_controls WHERE version<>? UNION SELECT index_version AS version FROM mapping_index WHERE index_version IS NOT NULL AND index_version<>?',
      [version, version],
    );
    // Unverifiable ancestry never activates over an existing version. Retain
    // cached compare proofs and do not re-query every subject in the library.
    for (final row in old) {
      final previous = row['version'] as String;
      final existing = await tasks.db.query(
        'mapping_ancestry',
        where: 'parent=? AND child=?',
        whereArgs: [previous, version],
      );
      if (existing.isNotEmpty) continue;
      final comparison = await requests.get(
        _resource('compare/$previous...$version'),
        lease,
      );
      if (comparison['status'] == 'ahead') {
        await store.proveDescendant(previous, version, comparison);
      }
    }
    return {
      'version': version,
      'assets': assets,
      'subjects': subjects,
      'episodes': episodes,
    };
  }

  Future<void> _download(Map asset, File file, TaskLease lease, int limit) =>
      requests.download(
        _resource('releases/assets/${asset['id']}'),
        lease,
        file,
        maxBytes: limit,
        digest: asset['sha256'] as String,
        checkActive: AnimeMappingStore.checkForeground,
      );

  /// Shared store-level serialization bounds disk and import CPU across pages.
  /// A second caller leaves its persistent task queued for explicit continuation.
  Future<void> run(String id) async {
    if (_busy[store] == true) return;
    _busy[store] = true;
    TaskLease? lease;
    Directory? temp;
    try {
      final rows = await tasks.db.query(
        'scrape_tasks',
        where: 'id=?',
        whereArgs: [id],
      );
      if (rows.isEmpty) return;
      final intent = jsonDecode(rows.single['intent_json'] as String) as Map;
      if (intent['kind'] != 'mapping') {
        throw const FormatException('Not a mapping task');
      }
      final op = intent['operation'] as String;
      if (op == 'discover') {
        lease = await tasks.claim(id, 'acquire');
        if (lease == null) return;
        await store.check(lease);
        final release = await requests.get(_resource('releases/latest'), lease);
        final tag = release['tag_name'];
        final version = tag is String && tag.startsWith('data-')
            ? tag.substring(5)
            : '';
        if (!AnimeMappingStore.commitPattern.hasMatch(version) ||
            release['draft'] != false ||
            release['prerelease'] != false) {
          throw const FormatException('No pinned mapping release');
        }
        await tasks.commit(lease, (_) async => {'version': version});
        return;
      }
      final version = intent['version'] as String;
      if (!AnimeMappingStore.commitPattern.hasMatch(version) ||
          !['release', 'index', 'bulk', 'detail'].contains(op)) {
        throw const FormatException('Invalid mapping intent');
      }
      lease = await tasks.claim(id, 'acquire');
      if (lease == null) return;
      await store.check(lease);
      final private = await Directory(
        '${tasks.cacheDirectory.parent.path}/mapping-downloads',
      ).create(recursive: true);
      temp = await private.createTemp('request-');
      final release = await _release(version, lease, temp);
      if (op == 'release') {
        await tasks.commit(lease, (_) async => release);
      } else if (op == 'detail') {
        final subject = AnimeMapping.integer(intent['subject']);
        final path = 'data/$subject.json';
        final response = await requests.get(
          _resource('contents/$path?ref=$version'),
          lease,
        );
        if (response['path'] != path ||
            response['encoding'] != 'base64' ||
            response['content'] is! String ||
            response['sha'] is! String) {
          throw const FormatException('Invalid Git blob');
        }
        final bytes = base64Decode(
          (response['content'] as String).replaceAll(RegExp(r'\s'), ''),
        );
        if (bytes.length > 512 * 1024 ||
            sha1.convert([
                  ...utf8.encode('blob ${bytes.length}\u0000'),
                  ...bytes,
                ]).toString() !=
                response['sha']) {
          throw const FormatException('Git blob integrity');
        }
        final data = jsonDecode(utf8.decode(bytes));
        if (data is! Map<String, dynamic> || data['bangumiId'] != subject) {
          throw const FormatException('Wrong mapping subject');
        }
        await store.importDetail(version, data, lease);
      } else {
        final assets = release['assets'] as Map;
        // Admission estimate includes old logical payload, raw temporaries and
        // SQLite row/index overhead. Disk-full errors still roll back staging.
        final payload =
            (await tasks.db.rawQuery(
                  '''SELECT (SELECT COALESCE(SUM(length(CAST(targets AS BLOB))),0) FROM mapping_rows) +
          (SELECT COALESCE(SUM(length(CAST(targets AS BLOB))+length(CAST(proof AS BLOB))),0) FROM mapping_subjects) AS n''',
                )).single['n']
                as int;
        final incoming =
            (assets['subjects.json']['size'] as int) +
            (op == 'bulk' ? assets['episodes.json']['size'] as int : 0);
        if (payload * 4 + incoming * 5 > 384 * 1024 * 1024) {
          throw StateError('Mapping staging disk budget');
        }
        final subjects = File('${temp.path}/subjects.part');
        await _download(
          assets['subjects.json'] as Map,
          subjects,
          lease,
          8 * 1024 * 1024,
        );
        File? episodes;
        if (op == 'bulk') {
          episodes = File('${temp.path}/episodes.part');
          await _download(
            assets['episodes.json'] as Map,
            episodes,
            lease,
            96 * 1024 * 1024,
          );
        }
        await store.importPublished(
          version: version,
          subjects: subjects,
          subjectsDigest: assets['subjects.json']['sha256'] as String,
          episodes: episodes,
          episodesDigest: assets['episodes.json']['sha256'] as String,
          subjectCount: release['subjects'] as int,
          episodeCount: release['episodes'] as int,
          lease: lease,
        );
      }
    } on TaskPaused {
      if (lease != null) {
        await tasks.control(id, 'pause', expectedGeneration: lease.generation);
        await tasks.park(lease);
      }
    } on TaskStopped {
      if (lease != null) {
        await tasks.control(id, 'cancel', expectedGeneration: lease.generation);
        tasks.release(lease);
      }
    } on MetadataFailure catch (e) {
      if (lease != null) {
        await tasks.fail(lease, e.category, notBefore: e.notBefore);
      }
    } catch (_) {
      if (lease != null) await tasks.fail(lease, 'mapping_validation');
      rethrow;
    } finally {
      if (temp != null && await temp.exists()) {
        await temp.delete(recursive: true);
      }
      _busy[store] = false;
    }
  }
}
