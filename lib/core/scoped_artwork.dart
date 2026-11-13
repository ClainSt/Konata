import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'anime_mapping_store.dart';
import 'catalog.dart';
import 'image_store.dart';
import 'library_foundation.dart';
import 'metadata.dart';
import 'metadata_servers.dart';
import 'scan_recognition.dart';
import 'app_language.dart';
import 'scrape_tasks.dart';
import 'shared_metadata_requests.dart';

enum ScopedImage { poster, backdrop, still }

typedef ArtworkScope = ({
  String key,
  int? bangumi,
  int? tmdb,
  int? season,
  bool movie,
  bool wholeSeason,
  String? backdropPath,
});

class ScopedArtwork {
  ScopedArtwork(
    this.catalog,
    this.requests, {
    this.fetchImage,
    this.budget = const Duration(seconds: 8),
  });
  final Catalog catalog;
  final SharedMetadataRequests requests;
  final Future<void> Function(String url, void Function() check)? fetchImage;
  final Duration budget;
  ScrapeTasks get tasks => catalog.taskStore!;

  static ({
    ArtworkScope scope,
    int episode,
    int? chapter,
    String? still,
    String token,
  })?
  episodeTarget(
    Iterable<Map<String, Object?>> rows,
    Map<String, Object?> binding,
  ) {
    if (binding['provider'] != 'tmdb' ||
        binding['layer'] != 'episode' ||
        binding['state'] != 'confirmed')
      return null;
    final range = rows
        .where(
          (row) =>
              row['layer'] == 'range' &&
              row['state'] == 'confirmed' &&
              jsonEncode([row['id'], row['revision']]) == binding['parent'],
        )
        .firstOrNull;
    final identity = rows
        .where(
          (row) =>
              row['provider'] == 'tmdb' &&
              row['layer'] == 'work' &&
              row['state'] == 'confirmed',
        )
        .firstOrNull;
    if (range == null ||
        identity == null ||
        jsonEncode([identity['id'], identity['revision']]) != range['parent']) {
      return null;
    }
    final item = ScanRecognition.adopted(binding)!;
    final series = ScanRecognition.adopted(identity)!;
    final id = series['id'], season = item['season'], episode = item['episode'];
    final chapter = item['chapter_id'];
    if (series['type'] != 'tv' ||
        id is! int ||
        season is! int ||
        episode is! int ||
        ScanRecognition.adopted(range)?['season'] != season)
      return null;
    return (
      scope: (
        key: jsonEncode(['episode', id, season, episode]),
        bangumi: null,
        tmdb: id,
        season: season,
        movie: false,
        wholeSeason: false,
        backdropPath: null,
      ),
      episode: episode,
      chapter: chapter is int ? chapter : null,
      still: item['still'] is String ? item['still'] as String : null,
      token: jsonEncode([
        binding['id'],
        binding['revision'],
        binding['parent'],
        range['parent'],
      ]),
    );
  }

  static Future<
    ({
      ArtworkScope scope,
      int episode,
      int? chapter,
      String? still,
      String token,
    })?
  >
  _episodeIn(DatabaseExecutor tx, String work, String asset) async {
    final rows = await tx.rawQuery(
      """SELECT b.* FROM scan_bindings b
         LEFT JOIN library_content c ON c.asset_id=b.asset_id
         WHERE b.work_id=? AND b.provider='tmdb' AND b.state='confirmed' AND
           (b.asset_id IS NULL OR (b.asset_id=? AND c.state='current' AND
            NOT EXISTS (SELECT 1 FROM scan_missing_assets m WHERE m.asset_id=b.asset_id)))""",
      [work, asset],
    );
    final binding = rows.where((row) => row['layer'] == 'episode').firstOrNull;
    return binding == null ? null : episodeTarget(rows, binding);
  }

  static Future<void> createSchema(DatabaseExecutor tx) async {
    await tx.execute('''CREATE TABLE scoped_artwork (
      work_id TEXT NOT NULL, scope TEXT NOT NULL, kind TEXT NOT NULL,
      state TEXT NOT NULL, revision INTEGER NOT NULL, selected TEXT,
      alternatives TEXT NOT NULL, missing TEXT NOT NULL, not_before INTEGER NOT NULL,
      PRIMARY KEY(work_id,scope,kind))''');
    await tx.execute(
      '''CREATE TRIGGER scoped_artwork_work_removed AFTER DELETE ON works BEGIN
      DELETE FROM scoped_artwork WHERE work_id=OLD.id; END''',
    );
  }

  static Future<void> publishDrafts(
    Catalog catalog,
    DatabaseExecutor tx,
    String workId,
  ) async {
    if (!catalog.scopedArtworkEnabled) return;
    final work = (await tx.query(
      'works',
      where: 'id=?',
      whereArgs: [workId],
    )).single;
    final protection = (await tx.query(
      'library_work_protection',
      where: 'work_id=?',
      whereArgs: [workId],
    )).single;
    if (protection['legacy_lock'] == 1) return;
    final bindings = await tx.query(
      'scan_bindings',
      where: "work_id=? AND state='confirmed' AND layer IN ('work','range')",
      whereArgs: [workId],
      orderBy: 'provider,scope',
    );
    final primary = await scopeIn(tx, workId);
    final primaryDirectory = primary == null
        ? null
        : (jsonDecode(primary.key) as List).last;
    final drafts = <String, ({Object value, String provider})>{};
    final language = AppLanguage.instance.metadataLanguage;
    for (final binding in bindings) {
      final item = ScanRecognition.adopted(binding)!;
      final provider = binding['provider'] as String;
      if (binding['layer'] == 'work') {
        var displayTitle = item['title'];
        if (protection['identity_locked'] != 1 && primary?.season == null &&
            binding['reason'] == 'verified_tmdb' && item['by'] == 'verified_tmdb' &&
            item['type'] == 'tv' && item['directory_title_matches'] == false &&
            item['directory_subject'] is int) {
          final locations = await tx.query('library_locations',
              columns: ['relative_path'], where: "kind='work' AND entity_id=?",
              whereArgs: [workId]);
          if (locations.singleOrNull?['relative_path'] case final String path) {
            displayTitle = Catalog.cleanTitle(p.posix.basename(path));
          }
        }
        if (displayTitle case final String title
            when title.trim().isNotEmpty) {
          drafts.putIfAbsent('title', () => (value: title, provider: provider));
        }
        if (item['year'] case final int year) {
          drafts.putIfAbsent('year', () => (value: year, provider: provider));
        }
      }
      if ((binding['layer'] == 'range' &&
              item['season'] != 0 &&
              binding['scope'] == primaryDirectory) ||
          (binding['layer'] == 'work' &&
              (primary?.movie == true ||
                  provider == 'bangumi' &&
                      !bindings.any(
                        (row) =>
                            row['layer'] == 'range' &&
                            row['provider'] == 'bangumi',
                      )))) {
        final overview = provider == 'bangumi'
            ? AppLanguage.bangumiSynopsis(item['summary'], language)
            : (item['summary_language'] ?? 'zh-CN') == language
            ? item['summary'] as String?
            : null;
        if (overview != null && overview.trim().isNotEmpty) {
          drafts.putIfAbsent(
            'overview',
            () => (value: overview, provider: provider),
          );
        }
      }
    }
    final scope = LibraryFoundation.scope(work);
    for (final entry in drafts.entries) {
      final field = (await tx.query(
        'library_fields',
        where: 'work_id=? AND scope=? AND field=?',
        whereArgs: [workId, scope, entry.key],
      )).single;
      if (field['automatic_json'] == jsonEncode(entry.value.value) &&
          field['automatic_source'] == entry.value.provider)
        continue;
      await LibraryFoundation(catalog.db).writeField(
        workId,
        entry.key,
        expectedScope: scope,
        expectedRevision: field['automatic_revision'] as int,
        expectedBindingRevision: protection['revision'] as int,
        mode: 'auto',
        automatic: true,
        source: entry.value.provider,
        value: entry.value.value,
        executor: tx,
      );
    }
  }

  static Future<ArtworkScope?> scopeIn(DatabaseExecutor tx, String work) async {
    final rows = await tx.rawQuery(
      '''SELECT b.* FROM scan_bindings b
      JOIN works w ON w.id=b.work_id WHERE b.work_id=? AND w.hidden=0
      AND w.tmdb_id IS NULL AND w.bangumi_id IS NULL AND b.state='confirmed'
      AND b.layer IN ('work','range') ORDER BY b.layer DESC,b.scope,b.provider''',
      [work],
    );
    final identities = {
      for (final r in rows.where((r) => r['layer'] == 'work'))
        r['provider']: ScanRecognition.adopted(r)!,
    };
    final tmdb = identities['tmdb'];
    final bg = identities['bangumi'];
    final movie = tmdb?['type'] == 'movie' || bg?['movie'] == true;
    final ranges = rows
        .where(
          (r) =>
              r['layer'] == 'range' &&
              ScanRecognition.adopted(r)?['season'] != 0,
        )
        .toList();
    // Pick the main range by its confirmed first episode, then its directory.
    ranges.sort((a, b) {
      final first = (ScanRecognition.adopted(a)?['first'] as int?) ?? 1;
      final second = (ScanRecognition.adopted(b)?['first'] as int?) ?? 1;
      return first == second
          ? (a['scope'] as String).compareTo(b['scope'] as String)
          : first.compareTo(second);
    });
    final main = ranges.firstOrNull?['scope'];
    Map<String, dynamic>? range(String source) => ranges
        .where((r) => r['scope'] == main && r['provider'] == source)
        .map(ScanRecognition.adopted)
        .firstOrNull;
    final tmdbRange = range('tmdb');
    final bgRange = range('bangumi');
    final tmdbId = tmdb?['id'] as int?;
    final bgId = (movie ? bg : bgRange ?? bg)?['id'] as int?;
    final season = tmdbRange?['season'] as int?;
    final knownCount = ((tmdb?['seasons'] as List?) ?? const [])
        .whereType<Map>()
        .where((s) => s['season'] == season)
        .firstOrNull?['count'];
    final chapters = tmdbRange?['chapters'] as List?;
    final last = tmdbRange?['last'] as int?;
    final wholeSeason =
        season != null &&
        tmdbRange?['first'] == 1 &&
        (knownCount != null
            ? knownCount == last
            : chapters != null &&
                  chapters.length == last &&
                  chapters.every(
                    (c) =>
                        c['sort'] is int && c['sort'] > 0 && c['sort'] <= last!,
                  ));
    if (identities.isEmpty) return null;
    final key = jsonEncode([
      tmdbId,
      bgId,
      movie,
      season,
      tmdbRange?['first'],
      last,
      main,
    ]);
    return (
      key: key,
      bangumi: bgId,
      tmdb: tmdbId,
      movie: movie,
      season: season,
      wholeSeason: wholeSeason,
      backdropPath: tmdb?['backdrop_path'] as String?,
    );
  }

  Future<Map<String, Object?>?> _row(
    DatabaseExecutor tx,
    String work,
    ArtworkScope scope,
    ScopedImage kind,
  ) async => (await tx.query(
    'scoped_artwork',
    where: 'work_id=? AND scope=? AND kind=?',
    whereArgs: [work, scope.key, kind.name],
  )).firstOrNull;

  Future<String?> displayed(String work, ScopedImage kind) async {
    final scope = await scopeIn(tasks.db, work);
    if (scope == null) return null;
    final row = await _row(tasks.db, work, scope, kind);
    return (await _displayedChoice(scope, kind, row))?['url'] as String?;
  }

  Future<Map<String, dynamic>?> _displayedChoice(
    ArtworkScope scope,
    ScopedImage kind,
    Map? row,
  ) async {
    if (row?['state'] == 'empty') return null;
    return _selected(row) ??
        await _seriesBackdrop(tasks.db, scope, kind, row) ??
        (kind == ScopedImage.backdrop ? _seedBackdrop(scope) : null);
  }

  static String _seriesKey(int series) =>
      jsonEncode(['series_backdrop', series]);

  static Future<Map<String, dynamic>?> _seriesBackdrop(
    DatabaseExecutor tx,
    ArtworkScope scope,
    ScopedImage kind,
    Map? row,
  ) async {
    if (kind != ScopedImage.backdrop ||
        scope.movie ||
        scope.tmdb == null ||
        row?['state'] == 'empty') {
      return null;
    }
    final saved = (await tx.query(
      'scoped_artwork',
      where: "scope=? AND kind='backdrop' AND state='manual'",
      whereArgs: [_seriesKey(scope.tmdb!)],
      orderBy: 'rowid DESC',
      limit: 1,
    )).firstOrNull;
    return _selected(saved);
  }

  static Map<String, dynamic>? _selected(Map? row) => row?['selected'] == null
      ? null
      : jsonDecode(row!['selected'] as String) as Map<String, dynamic>;

  Map<String, MetadataResource> _resources(
    ArtworkScope scope,
    ScopedImage kind, {
    bool manual = false,
  }) {
    final result = <String, MetadataResource>{};
    if (kind == ScopedImage.poster && scope.bangumi != null) {
      result['bangumi'] = ScanRecognition.metadataResource(
        'bangumi',
        'subjects/${scope.bangumi}',
      );
    }
    if (scope.tmdb != null && Metadata.credentials.isConfigured) {
      final series = scope.tmdb;
      final path = kind == ScopedImage.poster && !manual
          ? scope.movie
                ? 'movie/$series'
                : scope.wholeSeason && scope.season != 1
                ? 'tv/$series/season/${scope.season}'
                : 'tv/$series'
          : scope.movie
          ? 'movie/$series/images'
          : kind == ScopedImage.poster
          ? scope.wholeSeason && scope.season != 1
                ? 'tv/$series/season/${scope.season}/images'
                : 'tv/$series/images'
          : kind == ScopedImage.backdrop && (manual || scope.wholeSeason)
          ? manual
                ? 'tv/$series/images'
                : 'tv/$series'
          : null;
      if (path != null) {
        result['tmdb'] = ScanRecognition.metadataResource(
          'tmdb',
          path,
          parameters: {'include_image_language': 'zh,ja,en,null'},
        );
      }
    }
    return result;
  }

  static Map<String, dynamic>? _defaultBackdrop(Object? path) {
    final url = tmdbBackdrop(path);
    return url == null
        ? null
        : {'url': url, 'provider': 'tmdb', 'language': 'unknown'};
  }

  static String? tmdbBackdrop(Object? path) {
    if (path is! String ||
        !RegExp(
          r'^/[A-Za-z0-9_-]{1,160}\.(jpg|jpeg|png|webp)$',
        ).hasMatch(path)) {
      return null;
    }
    return MetadataServers.endpoint(
      1,
      'w780$path',
      base: MetadataServers.official[1],
    ).toString();
  }

  static Map<String, dynamic>? _seedBackdrop(ArtworkScope scope) =>
      scope.movie || scope.wholeSeason
      ? _defaultBackdrop(scope.backdropPath)
      : null;

  Future<String?> enqueue(
    String work,
    ScopedImage kind, {
    bool gallery = false,
    String? asset,
    String? provider,
    Map<String, Object?>? restoreBackdrop,
  }) async {
    final episode = asset == null
        ? null
        : await _episodeIn(tasks.db, work, asset);
    final scope = kind == ScopedImage.still
        ? episode?.scope
        : await scopeIn(tasks.db, work);
    if (scope == null) return null;
    if (kind == ScopedImage.still && !gallery) return null;
    if (!gallery &&
        _resources(scope, kind).isEmpty &&
        (kind != ScopedImage.backdrop || _seedBackdrop(scope) == null)) {
      return null;
    }
    final current = await _row(tasks.db, work, scope, kind);
    final restoringBackdrop = restoreBackdrop != null;
    if (restoreBackdrop != null) {
      final session = (await tasks.db.query(
        'scrape_runtime',
      )).single['session'];
      if (kind != ScopedImage.backdrop ||
          scope.key != restoreBackdrop['scope'] ||
          session != restoreBackdrop['session'] ||
          (current?['revision'] ?? -1) != restoreBackdrop['revision']) {
        return null;
      }
    }
    if (!gallery &&
        !restoringBackdrop &&
        ([
              'complete',
              'manual',
              'empty',
              'unavailable',
            ].contains(current?['state']) ||
            (current?['not_before'] as int? ?? 0) > tasks.now))
      return null;
    final source =
        (await tasks.db.query(
              'library_locations',
              columns: ['source_id'],
              where: "kind='work' AND entity_id=?",
              whereArgs: [work],
            )).firstOrNull?['source_id']
            as String?;
    final hash = sha256.convert(utf8.encode(scope.key));
    final id =
        'art:${gallery ? "gallery" : kind.name}:$work:$hash:${asset ?? kind.name}${provider == null ? "" : ":$provider"}${restoringBackdrop ? ":restore" : ""}';
    return tasks.enqueue(
      id,
      workId: work,
      sourceId: source,
      restartComplete: true,
      intent: {
        'kind': 'scoped_artwork',
        'image': kind.name,
        'scope_key': scope.key,
        'revision': current?['revision'] ?? -1,
        'gallery': gallery,
        if (restoringBackdrop) 'restore_backdrop': true,
        if (provider != null) 'provider': provider,
        if (episode != null) ...{'asset': asset, 'target': episode.token},
      },
      steps: ['scoped_artwork'],
    );
  }

  static List<Map<String, dynamic>> rank(Iterable<Map<String, dynamic>> rows) {
    int language(Map row) => switch (row['language']) {
      'none' => 0,
      'zh' => 1,
      'ja' => 2,
      'en' => 3,
      _ => 4,
    };
    int source(Map row) => row['provider'] == 'bangumi' ? 0 : 1;
    return rows.toList()..sort((a, b) {
      final byLanguage = language(a).compareTo(language(b));
      if (byLanguage != 0) return byLanguage;
      final bySource = source(a).compareTo(source(b));
      if (bySource != 0) return bySource;
      final rating = ((b['rating'] as num?) ?? 0).compareTo(
        (a['rating'] as num?) ?? 0,
      );
      return rating == 0
          ? (a['url'] as String).compareTo(b['url'] as String)
          : rating;
    });
  }

  static List<Map<String, dynamic>> _parse(
    ArtworkScope scope,
    ScopedImage kind,
    String provider,
    Map<String, dynamic> body, {
    int? chapter,
  }) {
    if (provider == 'bangumi') {
      if (body['id'] != scope.bangumi)
        throw const FormatException('Artwork subject mismatch');
      final images = body['images'];
      final raw = images is Map ? images['common'] ?? images['large'] : null;
      if (raw is! String) return [];
      final uri = Uri.tryParse(raw);
      final source = MetadataServers.imageResource(raw);
      if (uri == null ||
          uri.scheme != 'https' ||
          uri.userInfo.isNotEmpty ||
          source?.$1 != 3)
        return [];
      return [
        {
          'url': MetadataServers.endpoint(
            3,
            source!.$2,
            base: MetadataServers.official[3],
          ).toString(),
          'provider': provider,
          'language': 'unknown',
        },
      ];
    }
    if (kind == ScopedImage.still &&
        (body['id'] is! int || (chapter != null && body['id'] != chapter))) {
      throw const FormatException('Episode artwork identity mismatch');
    }
    if ((scope.movie || kind == ScopedImage.backdrop) &&
        body['id'] != scope.tmdb) {
      throw const FormatException('Artwork identity mismatch');
    }
    final defaultBackdrop = body['backdrop_path'];
    if (kind == ScopedImage.backdrop &&
        !scope.movie &&
        body.containsKey('backdrop_path')) {
      final selected = _defaultBackdrop(defaultBackdrop);
      return [if (selected != null) selected];
    }
    final result = <Map<String, dynamic>>[];
    final entries =
        body[switch (kind) {
          ScopedImage.poster => 'posters',
          ScopedImage.backdrop => 'backdrops',
          ScopedImage.still => 'stills',
        }];
    if (entries is! List) throw const FormatException('Missing artwork list');
    for (final row in entries.whereType<Map>()) {
      final w = row['width'], h = row['height'], path = row['file_path'];
      if (w is! int ||
          h is! int ||
          h < (kind == ScopedImage.still ? 180 : 400) ||
          w < 270 ||
          path is! String ||
          !RegExp(
            r'^/[A-Za-z0-9_-]{1,160}\.(jpg|jpeg|png|webp)$',
          ).hasMatch(path))
        continue;
      final ratio = w / h;
      if (kind == ScopedImage.poster
          ? ratio < .54 || ratio > .8
          : ratio < 1.45 ||
                ratio > 2.2 ||
                w < (kind == ScopedImage.still ? 320 : 700)) {
        continue;
      }
      result.add({
        'url': MetadataServers.endpoint(
          1,
          '${kind == ScopedImage.backdrop ? "w780" : "w500"}$path',
          base: MetadataServers.official[1],
        ).toString(),
        'provider': provider,
        'language': row.containsKey('iso_639_1')
            ? (row['iso_639_1'] ?? 'none')
            : 'unknown',
        'rating': row['vote_average'] is num ? row['vote_average'] : 0,
        if (kind == ScopedImage.backdrop && !scope.movie) 'series_only': true,
      });
    }
    return (kind == ScopedImage.poster ? result : rank(result))
        .take(10)
        .toList();
  }

  Future<void> _defaultPoster(
    TaskLease lease,
    ArtworkScope scope,
    Map<String, Object?>? old,
  ) async {
    final work = lease.workId!;
    final missing = <String>[];
    Map<String, dynamic>? selected;
    for (final entry in _resources(scope, ScopedImage.poster).entries) {
      try {
        await tasks.beforeNextRequest(lease);
        final body = await requests.get(entry.value, lease);
        final Map<String, dynamic>? candidate;
        if (entry.key == 'bangumi') {
          candidate = _parse(
            scope,
            ScopedImage.poster,
            entry.key,
            body,
          ).firstOrNull;
        } else {
          final matches = scope.wholeSeason && !scope.movie && scope.season != 1
              ? body['season_number'] == scope.season
              : body['id'] == scope.tmdb;
          if (!matches)
            throw const FormatException('Artwork identity mismatch');
          final path = body['poster_path'];
          candidate =
              path is String &&
                  RegExp(
                    r'^/[A-Za-z0-9_-]{1,160}\.(jpg|jpeg|png|webp)$',
                  ).hasMatch(path)
              ? {
                  'url': MetadataServers.endpoint(
                    1,
                    'w342$path',
                    base: MetadataServers.official[1],
                  ).toString(),
                  'provider': 'tmdb',
                }
              : null;
        }
        if (candidate == null) continue;
        await _image(
          candidate['url'] as String,
          ScopedImage.poster,
          lease.check,
        );
        selected = candidate;
        break;
      } on TaskPaused {
        rethrow;
      } on TaskStopped {
        rethrow;
      } on MetadataFailure catch (error) {
        if (error.category != 'not_found') missing.add(entry.key);
      } catch (_) {
        missing.add(entry.key);
      }
    }
    final state = selected != null
        ? 'complete'
        : missing.isEmpty
        ? 'unavailable'
        : 'pending';
    await tasks.commit(lease, (tx) async {
      await tasks.checkIn(tx, lease, cache: true);
      final current = await _row(tx, work, scope, ScopedImage.poster);
      if ((await scopeIn(tx, work))?.key != scope.key ||
          current?['revision'] != old?['revision']) {
        throw const TaskStopped();
      }
      await _write(
        tx,
        work,
        scope,
        ScopedImage.poster,
        old,
        state,
        selected,
        [],
        missing,
        state == 'pending'
            ? tasks.now + const Duration(hours: 1).inMilliseconds
            : 0,
      );
      return {'state': state};
    });
    await catalog.reload();
  }

  Future<void> _image(
    String url,
    ScopedImage kind,
    void Function() active,
  ) async {
    if (fetchImage case final loader?) {
      await loader(url, active);
      return;
    }
    final data = await ImageStore.load(
      url,
      checkActive: active,
      displayWidth:
          kind == ScopedImage.poster &&
              MetadataServers.imageResource(url)?.$1 == 3
          ? 500
          : null,
    );
    final image = await ImageStore.dimensions(data);
    final ratio = image.width / image.height;
    final valid = kind == ScopedImage.poster
        ? image.width >= 270 &&
              image.height >= 400 &&
              ratio >= .54 &&
              ratio <= .8
        : image.width >= (kind == ScopedImage.still ? 320 : 700) &&
              image.height >= (kind == ScopedImage.still ? 180 : 350) &&
              ratio >= 1.45 &&
              ratio <= 2.2;
    if (!valid)
      throw const FormatException(
        'Artwork dimensions outside the supported range',
      );
    active();
  }

  Future<void> run(TaskLease lease, Map intent) async {
    final work = lease.workId!;
    final kind = ScopedImage.values.byName(intent['image'] as String);
    final asset = intent['asset'] as String?;
    final episode = asset == null
        ? null
        : await _episodeIn(tasks.db, work, asset);
    final scope = kind == ScopedImage.still
        ? episode?.scope
        : await scopeIn(tasks.db, work);
    if (scope == null || scope.key != intent['scope_key'])
      throw const TaskStopped();
    if (episode != null && episode.token != intent['target'])
      throw const TaskStopped();
    final old = await _row(tasks.db, work, scope, kind);
    if ((old?['revision'] ?? -1) != intent['revision'])
      throw const TaskStopped();
    final gallery = intent['gallery'] == true;
    final restoringBackdrop = intent['restore_backdrop'] == true;
    if (kind == ScopedImage.poster && !gallery) {
      await _defaultPoster(lease, scope, old);
      return;
    }
    final seed = kind == ScopedImage.backdrop && !gallery
        ? _seedBackdrop(scope)
        : null;
    final resources = seed != null
        ? <String, MetadataResource>{}
        : episode == null
        ? _resources(scope, kind, manual: gallery)
        : {
            if (Metadata.credentials.isConfigured)
              'tmdb': ScanRecognition.metadataResource(
                'tmdb',
                'tv/${scope.tmdb}/season/${scope.season}/episode/${episode.episode}/images',
                parameters: {'include_image_language': 'zh,ja,en,null'},
              ),
          };
    if (intent['provider'] case final String provider) {
      resources.removeWhere((key, _) => key != provider);
    }
    final previousMissing =
        (jsonDecode(old?['missing'] as String? ?? '[]') as List).cast<String>();
    final retries =
        !gallery && !restoringBackdrop && previousMissing.isNotEmpty;
    final step = (await tasks.db.query(
      'scrape_steps',
      where: 'task_id=? AND step=?',
      whereArgs: [lease.taskId, lease.step],
    )).single;
    final saved = jsonDecode(step['result_json'] as String? ?? '{}') as Map;
    final snapshot = saved['candidate_checkpoint'] == true;
    final settled = ((saved['settled'] as List?) ?? const [])
        .cast<String>()
        .toSet();
    final elapsed = saved['elapsed_ms'] as int? ?? 0;
    final candidates = <Map<String, dynamic>>[
      if (seed != null) seed,
      if (snapshot)
        ...((saved['candidates'] as List?) ?? const [])
            .cast<Map<String, dynamic>>(),
      if (retries)
        ...(jsonDecode(old?['alternatives'] as String? ?? '[]') as List)
            .cast<Map<String, dynamic>>(),
    ];
    final missing = <String>[
      if (gallery && resources.isEmpty) 'source_unavailable',
      ...((saved['missing'] as List?) ?? const []).cast<String>(),
    ];
    final enabled =
        (retries
                ? resources.keys.where(previousMissing.contains)
                : resources.keys)
            .where((provider) => !settled.contains(provider))
            .toList();
    AnimeMappingStore.checkForeground();
    await tasks.beforeNextRequest(lease);
    if (enabled.isNotEmpty) {
      final remaining = (budget.inMilliseconds - elapsed).clamp(
        0,
        budget.inMilliseconds,
      );
      final deadline = Completer<void>();
      final watch = Stopwatch()..start();
      final timer = Timer(Duration(milliseconds: remaining), deadline.complete);
      Future<void> save() => tasks.checkpoint(lease, {
        'candidate_checkpoint': true,
        'elapsed_ms': elapsed + watch.elapsedMilliseconds,
        'settled': settled.toList(),
        'missing': missing.toSet().toList(),
        'candidates': rank(candidates).take(12).toList(),
      });
      try {
        if (remaining == 0) {
          missing.addAll(enabled);
          settled.addAll(enabled);
        } else {
          await Future.wait(
            enabled.map((provider) async {
              try {
                final body = await requests.get(
                  resources[provider]!,
                  lease,
                  consumerDeadline: deadline.future,
                );
                candidates.addAll(
                  _parse(
                    scope,
                    kind,
                    provider,
                    body,
                    chapter: episode?.chapter,
                  ),
                );
              } on MetadataFailure {
                missing.add(provider);
              } on FormatException {
                missing.add(provider);
              }
              settled.add(provider);
            }),
            eagerError: true,
          );
        }
        await save();
      } on TaskPaused {
        watch.stop();
        await save();
        rethrow;
      } finally {
        timer.cancel();
      }
    }
    final unique = {for (final c in candidates) c['url']: c}.values;
    final ranked = (kind == ScopedImage.poster ? unique : rank(unique))
        .take(12)
        .toList();
    if (gallery) {
      await tasks.commit(lease, (tx) async {
        if (asset == null
            ? (await scopeIn(tx, work))?.key != scope.key
            : (await _episodeIn(tx, work, asset))?.token != episode?.token)
          throw const TaskStopped();
        return {'scope': scope.key, 'candidates': ranked, 'missing': missing};
      });
      return;
    }
    var choice = restoringBackdrop ? null : _selected(old);
    final original = choice;
    var downloadFailed = false;
    // Stable or degraded choices never change on score alone.
    for (final candidate in ranked.take(3)) {
      if (candidate['series_only'] == true ||
          (original != null &&
              (original['language'] == 'none' ||
                  candidate['language'] != 'none')))
        continue;
      try {
        AnimeMappingStore.checkForeground();
        await tasks.beforeNextRequest(lease);
        await _image(candidate['url'] as String, kind, lease.check);
        choice = candidate;
        downloadFailed = false;
        break;
      } on TaskStopped {
        rethrow;
      } on TaskPaused {
        rethrow;
      } catch (_) {
        downloadFailed = true;
      }
    }
    final state = choice != null
        ? (missing.isEmpty && !downloadFailed ? 'complete' : 'degraded')
        : missing.isEmpty && !downloadFailed
        ? 'unavailable'
        : 'pending';
    await tasks.commit(lease, (tx) async {
      await tasks.checkIn(tx, lease, cache: true);
      final currentScope = await scopeIn(tx, work);
      final current = await _row(tx, work, scope, kind);
      if (currentScope?.key != scope.key ||
          current?['revision'] != old?['revision']) {
        throw const TaskStopped();
      }
      if (restoringBackdrop && choice == null) return {'state': state};
      await _write(
        tx,
        work,
        scope,
        kind,
        old,
        state,
        choice,
        ranked,
        missing,
        state == 'pending' || state == 'degraded'
            ? tasks.now + const Duration(hours: 1).inMilliseconds
            : 0,
      );
      return {'state': state};
    });
  }

  static Future<void> _write(
    DatabaseExecutor tx,
    String work,
    ArtworkScope scope,
    ScopedImage kind,
    Map? old,
    String state,
    Map? selected,
    List<Map<String, dynamic>> alternatives,
    List<String> missing,
    int notBefore,
  ) async {
    await tx.insert('scoped_artwork', {
      'work_id': work,
      'scope': scope.key,
      'kind': kind.name,
      'state': state,
      'revision': ((old?['revision'] as int?) ?? -1) + 1,
      'selected': selected == null ? null : jsonEncode(selected),
      'alternatives': jsonEncode(alternatives),
      'missing': jsonEncode(missing),
      'not_before': notBefore,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<Map<String, Object?>?> review(
    String work,
    ScopedImage kind, {
    String? asset,
  }) async {
    final episode = asset == null
        ? null
        : await _episodeIn(tasks.db, work, asset);
    final scope = kind == ScopedImage.still
        ? episode?.scope
        : await scopeIn(tasks.db, work);
    if (scope == null) return null;
    final session = (await tasks.db.query('scrape_runtime')).single['session'];
    final row = await _row(tasks.db, work, scope, kind);
    return {
      'scope': scope.key,
      'session': session,
      'revision': row?['revision'] ?? -1,
      'selected': await _displayedChoice(scope, kind, row),
      'state': row?['state'],
      if (kind == ScopedImage.poster)
        'providers': _resources(scope, kind, manual: true).keys.toList(),
      if (kind == ScopedImage.backdrop)
        'can_restore':
            _seedBackdrop(scope) != null || _resources(scope, kind).isNotEmpty,
      if (episode != null) ...{
        'target': episode.token,
        'automatic': episode.still,
      },
    };
  }

  Future<void> decide(
    String work,
    ScopedImage kind,
    Map preview,
    Map<String, dynamic>? choice, {
    bool automatic = false,
    bool seriesWide = false,
    String? asset,
  }) async {
    final episode = asset == null
        ? null
        : await _episodeIn(tasks.db, work, asset);
    final scope = kind == ScopedImage.still
        ? episode?.scope
        : await scopeIn(tasks.db, work);
    if (scope == null || scope.key != preview['scope'])
      throw const TaskStopped();
    if (seriesWide &&
        (choice?['series_only'] != true ||
            kind != ScopedImage.backdrop ||
            scope.movie ||
            scope.tmdb == null ||
            automatic)) {
      throw const FormatException(
        'Series backdrop must be confirmed explicitly',
      );
    }
    if (choice != null) {
      _validateImage(choice);
      await _image(choice['url'] as String, kind, () {});
    }
    await tasks.db.transaction((tx) async {
      final session = (await tx.query('scrape_runtime')).single['session'];
      final row = await _row(tx, work, scope, kind);
      final current = asset == null
          ? (await scopeIn(tx, work))?.key
          : (await _episodeIn(tx, work, asset))?.token;
      if (session != preview['session'] ||
          current != (asset == null ? scope.key : preview['target']) ||
          current == null ||
          (row?['revision'] ?? -1) != preview['revision'])
        throw const TaskStopped();
      if (kind == ScopedImage.still && automatic) {
        await _write(tx, work, scope, kind, row, 'complete', null, [], [], 0);
        return;
      }
      if (kind == ScopedImage.poster && automatic) {
        await _write(tx, work, scope, kind, row, 'pending', null, [], [], 0);
        return;
      }
      await _write(
        tx,
        work,
        scope,
        kind,
        row,
        automatic
            ? (choice == null ? 'unavailable' : 'complete')
            : choice == null
            ? 'empty'
            : 'manual',
        choice,
        [],
        [],
        0,
      );
      if (seriesWide) {
        final common = (
          key: _seriesKey(scope.tmdb!),
          bangumi: null as int?,
          tmdb: scope.tmdb,
          season: null as int?,
          movie: false,
          wholeSeason: false,
          backdropPath: null,
        );
        await _write(
          tx,
          work,
          common,
          kind,
          await _row(tx, work, common, kind),
          'manual',
          choice,
          [],
          [],
          0,
        );
      }
    });
    if (kind == ScopedImage.poster) await catalog.reload();
  }

  static void _validateImage(Map value) {
    final url = value['url'];
    final parsed = url is String ? Uri.tryParse(url) : null;
    if (parsed == null ||
        parsed.scheme != 'https' ||
        parsed.userInfo.isNotEmpty ||
        parsed.hasQuery ||
        parsed.hasFragment ||
        MetadataServers.imageResource(url as String) == null) {
      throw const FormatException('Invalid scoped artwork URL');
    }
  }

  static void validateSnapshot(Map<String, dynamic> tables) {
    final works = {for (final w in tables['works'] as List) w['id']};
    for (final row in tables['scoped_artwork'] as List) {
      if (!works.contains(row['work_id']) ||
          !ScopedImage.values.any((k) => k.name == row['kind']) ||
          ![
            'complete',
            'manual',
            'empty',
            'unavailable',
            'pending',
            'degraded',
          ].contains(row['state']) ||
          row['revision'] is! int ||
          row['revision'] < 0 ||
          jsonDecode(row['scope'] as String) is! List)
        throw const FormatException('Invalid scoped artwork row');
      final choice = _selected(row);
      if (choice != null) _validateImage(choice);
      final options = jsonDecode(row['alternatives'] as String) as List;
      if (options.length > 12)
        throw const FormatException('Artwork options limit');
      for (final option in options) {
        _validateImage(option as Map);
      }
    }
  }
}
