import 'metadata_servers.dart';
import 'metadata_http.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'metadata.dart';
import 'personal_filename_parser.dart';
import 'work_season.dart';
import 'scan_activity.dart';
import 'bangumi_offline_index.dart';

/// TMDB/Bangumi-only port of the metadata-only NipaPlay Personal cloud
/// scraper. Never reads video bytes, invokes Dandanplay, or changes filenames.
class ScrapedWork {
  const ScrapedWork({
    required this.title,
    required this.provider,
    this.tmdbId,
    this.tmdbType,
    this.bangumiId,
    this.poster,
    this.bangumiPoster,
    this.overview,
    this.year,
    this.aliases = const {},
  });
  final String title, provider;
  final int? tmdbId, bangumiId, year;
  final String? tmdbType, poster, bangumiPoster, overview;
  final Set<String> aliases;

  bool sameWork(ScrapedWork other) {
    if (tmdbId != null && other.tmdbId != null) {
      if (tmdbId != other.tmdbId) return false;
      if (tmdbType != null && other.tmdbType != null) {
        return tmdbType == other.tmdbType;
      }
    }
    return bangumiId != null && bangumiId == other.bangumiId;
  }
}

class _ReviewRequired implements Exception {}

class _SearchIncomplete implements Exception {}

class ScrapeReport {
  const ScrapeReport(this.matched, this.skipped, this.review, this.errors);
  final int matched, skipped, review, errors;
}

class PersonalMetadataScraper {
  PersonalMetadataScraper({
    http.Client? client,
    BangumiOfflineIndex? offlineIndex,
    this._bangumiBase = 'https://api.bgm.tv',
  }) : _client = client ?? MetadataHttp(),
       _offlineIndex =
           offlineIndex ??
           (BangumiOfflineIndex.directory == null
               ? null
               : BangumiOfflineIndex(BangumiOfflineIndex.directory!)),
       _ownsClient = client == null;
  final BangumiOfflineIndex? _offlineIndex;
  final http.Client _client;
  final bool _ownsClient;
  final String _bangumiBase;
  void Function()? checkCancelled;
  // One scrape batch only, bounded and discarded on close. Failed requests
  // are never memoized, so a later visit can recover from a network outage.
  final _responses = <String, Map<String, dynamic>>{};
  final _pendingResponses = <String, Future<Map<String, dynamic>?>>{};
  Future<Map<String, dynamic>?> _memo(
    String key,
    Future<Map<String, dynamic>?> Function() fetch,
  ) async {
    checkCancelled?.call();
    if (_responses.containsKey(key)) return _responses[key];
    return _pendingResponses.putIfAbsent(key, () async {
      try {
        final value = await fetch();
        checkCancelled?.call();
        if (value != null &&
            utf8.encode(jsonEncode(value)).length <= 64 * 1024) {
          if (_responses.length >= 128) {
            _responses.remove(_responses.keys.first);
          }
          _responses[key] = value;
        }
        return value;
      } finally {
        _pendingResponses.remove(key);
      }
    });
  }

  void close() {
    _responses.clear();
    if (_ownsClient) _client.close();
  }

  static String normalize(String title) =>
      PersonalFilenameParser.normalizeIdentity(title);
  static bool exactTitle(String a, String b) {
    final x = normalize(a), y = normalize(b);
    return x.isNotEmpty && x == y;
  }

  static bool subjectTitleMatches(String query, String candidate, int? year) {
    return exactTitle(query, candidate);
  }

  static List<String> queries(String title) {
    final queries = <String>{};
    var name = title
        .trim()
        .replaceAll(RegExp(r'\{[^}]*\}'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (name.isEmpty) return [];
    queries.add(name);
    name = name
        .replaceAll(RegExp(r'\((?:19|20)\d{2}\)'), ' ')
        .replaceAll(RegExp(r'\b(?:19|20)\d{2}\b'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (name.isNotEmpty) queries.add(name);
    final noSeason = name
        .replaceAll(
          RegExp(
            r'(?<![a-z0-9])s\d{1,2}(?:[ ._+&~～-]+s?\d{1,2})*|'
            r'第[ ._-]*[0-9一二三四五六七八九十百]+[ ._-]*[季期]|'
            r'(?<![a-z0-9])season[ ._-]*\d{1,2}|'
            r'\d{1,2}(?:st|nd|rd|th)[ ._-]*season',
            caseSensitive: false,
          ),
          ' ',
        )
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (noSeason.isNotEmpty) queries.add(noSeason);
    final noPrefix = name
        .replaceFirst(RegExp(r'^\d{1,4}\s*[-:：._、 ]+'), '')
        .trim();
    if (noPrefix.isNotEmpty) queries.add(noPrefix);
    return queries.take(6).toList();
  }

  /// Adapted from NipaPlay Personal's file-name keyword fallback, using
  /// its pure Dart parser without the larger Rust runtime dependency.
  static List<String> titleHints(String title, List<String> filenames) {
    final result = <String>{...queries(title)};
    for (final file in filenames.take(6)) {
      for (final keyword in [
        PersonalFilenameParser.extractAnimeTitleKeyword(file),
        PersonalFilenameParser.extractAnimeSearchKeyword(file),
      ]) {
        if (keyword.isEmpty) continue;
        result.addAll(queries(keyword));
        if (result.length >= 12) break;
      }
      if (result.length >= 12) break;
    }
    return result.take(12).toList();
  }

  static bool yearCompatible(int? wanted, String? date) {
    if (wanted == null) return true;
    final year = date != null && date.length >= 4
        ? int.tryParse(date.substring(0, 4))
        : null;
    return year == null || year == wanted;
  }

  Future<Map<String, dynamic>?> _tmdb(
    String path,
    Map<String, String> params,
  ) => _memo('tmdb:$path:${jsonEncode(params)}', () async {
    final credentials = Metadata.credentials;
    if (!credentials.isConfigured) return null;
    http.Response response;
    try {
      response = await _client.get(
        credentials.uri(path, params),
        headers: credentials.headers,
      );
    } catch (_) {
      throw StateError('TMDB 网络连接失败');
    }
    if (response.statusCode == 404) return null;
    if (response.statusCode != 200) {
      throw StateError('TMDB HTTP ${response.statusCode}');
    }
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    return decoded is Map<String, dynamic> ? decoded : null;
  });

  Future<Map<String, dynamic>?> _tmdbById(
    int id,
    String? type,
    Map<String, Object?> work,
    List<String> hints,
  ) async {
    final candidates = <Map<String, dynamic>>[];
    Set<String>? linkedAliases;
    final typed = type == 'movie' || type == 'tv';
    // TV and movies use independent numeric ID namespaces. An untyped marker
    // cannot be resolved by whichever endpoint returns first.
    for (final kind in typed ? [type!] : ['tv', 'movie']) {
      Map<String, dynamic>? item;
      try {
        item = await _tmdb('/$kind/$id', {
          'language': 'zh-CN',
          'append_to_response': 'alternative_titles,translations',
        });
      } on ScanCancelled {
        rethrow;
      } catch (_) {
        if (typed) rethrow;
        // A failed endpoint is not proof that this namespace has no candidate.
        throw _ReviewRequired();
      }
      if (item == null) continue;
      if (item['id'] is! num || (item['id'] as num).toInt() != id) continue;
      if (typed) return {...item, '_cc_kind': kind};
      final year = WorkSeason.year(work);
      final requested = WorkSeason.explicit(work);
      if (kind == 'movie') {
        if (requested != null ||
            !yearCompatible(year, item['release_date']?.toString())) {
          continue;
        }
      } else {
        final seasons = (item['seasons'] as List? ?? [])
            .whereType<Map>()
            .toList();
        final number = WorkSeason.resolve(work, seasons);
        if (!WorkSeason.multiple(work)) {
          if (number != null) {
            final selected = seasons.where((s) => s['season_number'] == number);
            if (selected.length != 1 ||
                !yearCompatible(
                  year,
                  selected.single['air_date']?.toString(),
                )) {
              continue;
            }
          } else if (requested != null ||
              year != null &&
                  seasons.any((s) => (s['season_number'] as num? ?? 0) > 0) ||
              !yearCompatible(year, item['first_air_date']?.toString())) {
            continue;
          }
        }
      }
      if (hints.isNotEmpty &&
          !officialTitles(
            item,
          ).any((name) => hints.any((hint) => exactTitle(hint, name)))) {
        // A translated directory title can be a formal Bangumi alias even if
        // TMDB only supplies its Japanese/English name. Require a unique formal
        // Bangumi identity and an exact shared official alias, not fuzzy text.
        linkedAliases ??= officialTitles(
          await matchBangumi(
                PersonalFilenameParser.withoutTmdbMarkers(WorkSeason.directoryTitle(work)),
                year,
                tmdbId: id,
                hints: hints,
              ) ?? const {},
        );
        if (!officialTitles(item).any((name) => linkedAliases!.any((alias) => exactTitle(alias, name)))) {
          continue;
        }
      }
      candidates.add({...item, '_cc_kind': kind});
    }
    if (!typed && candidates.length != 1) throw _ReviewRequired();
    return candidates.isEmpty ? null : candidates.single;
  }

  static Set<String> officialTitles(Map item) {
    final result = <String>{};
    void add(Object? value) {
      if (value is String && value.trim().isNotEmpty) result.add(value.trim());
    }

    for (final key in [
      'name',
      'title',
      'original_name',
      'original_title',
      'name_cn',
    ]) {
      add(item[key]);
    }
    final alternative = item['alternative_titles'];
    if (alternative is Map) {
      for (final row
          in (alternative['results'] ?? alternative['titles'] ?? []) as List) {
        if (row is Map) add(row['title']);
      }
    }
    final translations = item['translations'];
    if (translations is Map) {
      for (final row
          in (translations['translations'] as List? ?? []).whereType<Map>()) {
        final data = row['data'];
        if (data is Map) {
          add(data['name']);
          add(data['title']);
        }
      }
    }
    for (final row in (item['infobox'] as List? ?? []).whereType<Map>()) {
      if (![
        '别名',
        '中文名',
        'alias',
        'aliases',
      ].contains(row['key']?.toString().toLowerCase())) {
        continue;
      }
      final value = row['value'];
      if (value is List) {
        for (final alias in value) {
          if (alias is Map) {
            add(alias['v']);
          } else {
            add(alias);
          }
        }
      } else {
        add(value);
      }
    }
    return result;
  }

  Future<Map<String, dynamic>?> _tmdbByTitle(
    String title,
    int? year,
    List<String> hints,
  ) async {
    if (!Metadata.credentials.isConfigured) return null;
    for (final query in hints) {
      final distinct = <String, Map<String, dynamic>>{};
      const types = ['tv', 'movie'];
      final searches = await Future.wait(
        types.map(
          (type) =>
              _tmdb('/search/$type', {'language': 'zh-CN', 'query': query}),
        ),
      );
      for (var searchIndex = 0; searchIndex < types.length; searchIndex++) {
        final type = types[searchIndex], data = searches[searchIndex];
        final rows = (data?['results'] as List? ?? [])
            .whereType<Map>()
            .toList();
        // Do not declare uniqueness from a truncated candidate set.
        if ((data?['total_pages'] as num? ?? 1) > 1 || rows.length > 8) {
          throw _SearchIncomplete();
        }
        for (final item in rows) {
          if (item['id'] is! num) continue;
          final date = (item['first_air_date'] ?? item['release_date'])
              ?.toString();
          if (type == 'movie' && !yearCompatible(year, date)) continue;
          final direct = officialTitles(
            item,
          ).any((name) => exactTitle(query, name));
          final needsDetails =
              !direct ||
              type == 'tv' &&
                  (WorkSeason.explicit({'title': title}) != null ||
                      !yearCompatible(year, date));
          Map<String, dynamic> full = Map<String, dynamic>.from(item);
          if (needsDetails) {
            final details = await _tmdb('/$type/${item['id']}', {
              'language': 'zh-CN',
              'append_to_response': 'alternative_titles,translations',
            });
            if (details == null || details['id'] != item['id']) {
              throw _ReviewRequired();
            }
            full.addAll(details);
          }
          if (!officialTitles(full).any((name) => exactTitle(query, name))) {
            continue;
          }
          if (!yearCompatible(year, date)) {
            final seasons = (full['seasons'] as List? ?? [])
                .whereType<Map>()
                .toList();
            final number = WorkSeason.resolve({
              'title': title,
              'year': year,
            }, seasons);
            if (number == null ||
                !seasons.any(
                  (s) =>
                      s['season_number'] == number &&
                      yearCompatible(year, s['air_date']?.toString()),
                )) {
              continue;
            }
          }
          distinct['$type:${item['id']}'] = {...full, '_cc_kind': type};
        }
      }
      if (distinct.length > 1) throw _ReviewRequired();
      if (distinct.isNotEmpty) return distinct.values.single;
    }
    return null;
  }

  Future<Map<String, dynamic>?> _bangumi(
    String path, {
    String? query,
    int? year,
  }) => _memo('bangumi:$path:$query:$year', () async {
    final uri = Uri.parse('$_bangumiBase/v0/$path');
    final headers = {
      'User-Agent': MetadataHttp.userAgent,
      'Accept': 'application/json',
    };
    final response = query == null
        ? await _client.get(uri, headers: headers)
        : await _client.post(
            uri.replace(queryParameters: {'limit': '10'}),
            headers: {...headers, 'Content-Type': 'application/json'},
            body: jsonEncode({
              'keyword': query,
              'sort': 'match',
              'filter': {
                'type': [2],
                if (year != null)
                  'air_date': ['>=$year-01-01', '<${year + 1}-01-01'],
              },
            }),
          );
    if (response.statusCode == 404) return null;
    if (response.statusCode != 200) {
      throw StateError('Bangumi HTTP ${response.statusCode}');
    }
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    return decoded is Map<String, dynamic> ? decoded : null;
  });

  Future<Map<String, dynamic>?> matchBangumi(
    String title,
    int? year, {
    int? tmdbId,
    List<String> hints = const [],
  }) async {
    final local = await _offlineBangumi(
      title,
      year,
      hints: hints,
      tmdbId: tmdbId,
    );
    if (local != null) return local;
    for (final query in hints.isEmpty ? queries(title) : hints) {
      final body = await _bangumi('search/subjects', query: query, year: year);
      final rows = (body?['data'] as List? ?? []).whereType<Map>().toList();
      if ((body?['total'] as num? ?? rows.length) > rows.length ||
          rows.length > 8) {
        throw _ReviewRequired();
      }
      final matches = <int, Map<String, dynamic>>{};
      for (final row in rows) {
        final id = (row['id'] as num?)?.toInt();
        if (id == null || !yearCompatible(year, row['date']?.toString())) {
          continue;
        }
        final detail = await _bangumi('subjects/$id');
        if (detail == null || detail['id'] != id) throw _ReviewRequired();
        final full = {...row, ...detail};
        if (!yearCompatible(year, full['date']?.toString())) continue;
        if (!officialTitles(full).any((name) => exactTitle(query, name))) {
          continue;
        }
        final requestedSeason = WorkSeason.explicit({'title': title});
        final actualSeason = WorkSeason.explicit({
          'title': full['name_cn'] ?? full['name'],
        });
        if (requestedSeason != null &&
            requestedSeason > 1 &&
            actualSeason != requestedSeason) {
          continue;
        }
        if (requestedSeason != null &&
            actualSeason != null &&
            requestedSeason != actualSeason) {
          continue;
        }
        if (tmdbId != null) {
          for (final entry
              in (full['infobox'] as List? ?? []).whereType<Map>()) {
            if (!entry['key'].toString().toLowerCase().contains('tmdb')) {
              continue;
            }
            final found = int.tryParse(
              RegExp(r'\d+').firstMatch('${entry['value']}')?.group(0) ?? '',
            );
            if (found != null && found != tmdbId) throw _ReviewRequired();
          }
        }
        matches[id] = Map<String, dynamic>.from(full);
      }
      if (matches.length > 1) throw _ReviewRequired();
      if (matches.isNotEmpty) return matches.values.single;
    }
    return null;
  }

  Future<Map<String, dynamic>?> _offlineBangumi(
    String title,
    int? year, {
    List<String> hints = const [],
    int? tmdbId,
  }) async {
    final index = _offlineIndex;
    if (index == null) return null;
    final generation = BangumiOfflineIndex.generation;
    final matches = <int, Map<String, dynamic>>{};
    try {
      for (final query in hints.isEmpty ? queries(title) : hints) {
        final cached = await _memo(
          'offline:$generation:$query',
          () async => {'rows': await index.lookup(query)},
        );
        final rows = (cached?['rows'] as List? ?? [])
            .cast<Map<String, dynamic>>();
        if (rows.length > 32) return null;
        for (final row in rows) {
          if (!yearCompatible(year, row['date']?.toString()) ||
              !officialTitles(row).any((name) => exactTitle(query, name))) {
            continue;
          }
          final requested = WorkSeason.explicit({'title': title});
          final actual = WorkSeason.explicit({
            'title': row['name_cn'] ?? row['name'],
          });
          if (requested != null &&
              (requested > 1 && requested != actual ||
                  actual != null && requested != actual)) {
            continue;
          }
          if (tmdbId != null) {
            for (final field
                in (row['infobox'] as List? ?? []).whereType<Map>()) {
              if (!'${field['key']}'.toLowerCase().contains('tmdb')) continue;
              final id = int.tryParse(
                RegExp(r'\d+').firstMatch('${field['value']}')?.group(0) ?? '',
              );
              if (id != null && id != tmdbId) return null;
            }
          }
          matches[row['id'] as int] = row;
        }
      }
    } on ScanCancelled {
      rethrow;
    } catch (_) {
      return null;
    } // A missing/corrupt index must not disable online scraping.
    return generation == BangumiOfflineIndex.generation && matches.length == 1
        ? matches.values.single
        : null;
  }

  Future<ScrapedWork?> _offlineWork(Map<String, dynamic> row, int? year) async {
    Map<String, dynamic>? detail;
    try {
      // Identity is already resolved locally. One ID lookup supplies artwork;
      // offline/unreachable servers do not prevent accepting the local identity.
      detail = await _bangumi('subjects/${row['id']}');
    } on ScanCancelled {
      rethrow;
    } catch (_) {
      /* Artwork can be fetched on a later online visit. */
    }
    if (detail != null &&
        (detail['id'] != row['id'] ||
            !yearCompatible(year, detail['date']?.toString()))) {
      return null;
    }
    return ScrapedWork(
      title: '${row['name_cn'] ?? ''}'.trim().isNotEmpty
          ? '${row['name_cn']}'
          : '${row['name']}',
      provider: 'Bangumi',
      bangumiId: row['id'] as int,
      year: int.tryParse('${row['date']}'.split('-').first),
      aliases: officialTitles(row),
      poster: _poster(detail?['images'] as Map?),
      bangumiPoster: _poster(detail?['images'] as Map?),
      overview: detail?['summary']?.toString(),
    );
  }

  static String? _poster(Map<dynamic, dynamic>? images) {
    for (final key in const ['large', 'common', 'medium', 'small', 'grid']) {
      final value = images?[key]?.toString().trim();
      final uri = Uri.tryParse(value ?? '');
      if (uri != null &&
          (uri.isScheme('https') || uri.isScheme('http')) &&
          uri.hasAuthority) {
        return value;
      }
    }
    return null;
  }

  /// Each distinct filename identity is resolved once, never once per episode.
  /// A directory match may fill an episode-only name; it cannot override a
  /// conflicting named file. The caller keeps unresolved files for review.
  Future<Map<String, ScrapedWork?>> classify(
    Map<String, Object?> work,
    List<Map<String, Object?>> assets, {
    ScrapedWork? unnamedFallback,
  }) async {
    work = _sourceEvidence(work);
    final folder = await scrape(work);
    if (folder == null &&
        PersonalFilenameParser.tmdbIds(WorkSeason.directoryTitle(work)).isNotEmpty) {
      // An unresolved explicit directory ID remains authoritative evidence to
      // review. A filename match cannot silently replace or discard that ID.
      return {for (final asset in assets) asset['id'].toString(): null};
    }
    final groups = <String, Future<ScrapedWork?>>{};
    final result = <String, ScrapedWork?>{};
    String directory(Map<String, Object?> asset) {
      final path = (asset['relative_path'] ?? asset['name'] ?? '')
          .toString()
          .replaceAll('\\', '/');
      final slash = path.lastIndexOf('/');
      return slash < 0 ? '' : path.substring(0, slash);
    }

    final siblings = <String, List<String>>{};
    for (final asset in assets.where((a) => a['category'] != 'extra')) {
      (siblings[directory(asset)] ??= []).add('${asset['name']}');
    }
    final sequences = {
      for (final entry in siblings.entries)
        entry.key: PersonalFilenameParser.sequentialEpisodePrefixes(
          entry.value,
        ),
    };
    for (final asset in assets) {
      checkCancelled?.call();
      final name = asset['name']?.toString() ?? '';
      final files = filenameCandidates(
        name,
        supplementary: asset['category'] == 'extra',
        sequentialPrefixes: sequences[directory(asset)] ?? const {},
      );
      if (files.isEmpty) {
        result[asset['id'].toString()] = folder ?? unnamedFallback;
        continue;
      }
      if (files.length > 8) {
        result[asset['id'].toString()] = null;
        continue;
      }
      final matches = <ScrapedWork>[];
      var ambiguous = false;
      for (final file in files) {
        // A directory year narrows alias searches without imposing its provider
        // ID on the file; another identifiable work still triggers review.
        file['year'] ??= WorkSeason.year(work);
        final title = file['title'].toString();
        final year = file['year'] as int?;
        final season = WorkSeason.explicit(file);
        final folderSeason = WorkSeason.explicit(work);
        final knownAlias =
            folder != null &&
            file['conflicting_ids'] != true &&
            (file['tmdb_id'] == null ||
                file['tmdb_id'] == folder.tmdbId &&
                    file['tmdb_type'] == folder.tmdbType) &&
            (year == null || folder.year == null || year == folder.year) &&
            (season == null ||
                season == folderSeason ||
                season == 1 && folderSeason == null) &&
            folder.aliases.any((alias) => exactTitle(title, alias));
        final key =
            '$title|$year|$season|${file['tmdb_id']}|${file['tmdb_type']}|${file['conflicting_ids']}';
        ScrapedWork? candidate;
        try {
          candidate = knownAlias
              ? folder
              : await groups.putIfAbsent(
                  key,
                  () => scrape(file, requireUnambiguous: true),
                );
        } on _ReviewRequired {
          ambiguous = true;
          continue;
        }
        if (folder != null &&
            candidate != null &&
            (!folder.sameWork(candidate) ||
                WorkSeason.year(work) != null &&
                    year != null &&
                    WorkSeason.year(work) != year ||
                folderSeason != null &&
                    season != null &&
                    folderSeason != season)) {
          ambiguous = true;
        }
        if (candidate != null) matches.add(candidate);
      }
      if (matches.isNotEmpty &&
          matches.any(
            (m) =>
                !m.sameWork(matches.first) ||
                m.year != matches.first.year ||
                WorkSeason.explicit({'title': m.title}) !=
                    WorkSeason.explicit({'title': matches.first.title}),
          )) {
        ambiguous = true;
      }
      result[asset['id'].toString()] = ambiguous || matches.isEmpty
          ? null
          : matches.first;
    }
    return result;
  }

  static List<Map<String, Object?>> filenameCandidates(
    String name, {
    bool supplementary = false,
    Set<String> sequentialPrefixes = const {},
  }) {
    final primary = filenameWork(name, supplementary: supplementary);
    if (primary == null) return const [];
    final candidates = <Map<String, Object?>>[primary];
    final season = WorkSeason.explicit({
      'title': PersonalFilenameParser.baseNameWithoutExtension(name),
    });
    for (final variant in [
      name,
      ?PersonalFilenameParser.withoutKnownReleaseGroups(name),
    ]) {
      if (variant != name) {
        final parsed = filenameWork(variant, supplementary: supplementary);
        if (parsed != null) {
          candidates.add({...primary, 'title': parsed['title']});
        }
      }
      for (final title in PersonalFilenameParser.bracketTitleCandidates(
        variant,
      )) {
        candidates.add({
          ...primary,
          'title': season == null ? title : '$title S$season',
        });
      }
      final episode = PersonalFilenameParser.bareEpisode(variant);
      if (!supplementary &&
          episode != null &&
          sequentialPrefixes.contains(episode.title.toLowerCase())) {
        candidates.add({...primary, 'title': episode.title});
      }
    }
    final distinct = <String, Map<String, Object?>>{};
    for (final candidate in candidates) {
      distinct.putIfAbsent(jsonEncode(candidate), () => candidate);
    }
    return distinct.values.toList();
  }

  static Map<String, Object?>? filenameWork(
    String name, {
    bool supplementary = false,
  }) {
    var title = PersonalFilenameParser.extractAnimeSearchKeyword(name);
    if (supplementary) {
      title = title
          .replaceFirst(
            RegExp(
              r'(?:^|[\s_-])(?:NCOP|NCED|OP|ED|PV|CM|SP|SPECIALS?|BONUS|MENU)(?:\d{1,3}|v\d+)?(?:\s.*)?$',
              caseSensitive: false,
            ),
            '',
          )
          .trim();
    }
    // A bare episode number supplies no title evidence. Numeric titles such
    // as "86 - 01" survive because the parser has already removed the episode.
    final base = PersonalFilenameParser.baseNameWithoutExtension(name);
    if (RegExp(
      r'^(?:\[)?(?:S\d+E|EP?|第)?\s*\d{1,3}(?:[话話集])?(?:\])?$',
      caseSensitive: false,
    ).hasMatch(base)) {
      return null;
    }
    final tmdbId = PersonalFilenameParser.tmdbId(base);
    if (title.isEmpty && tmdbId == null) return null;
    final season = WorkSeason.explicit({'title': base});
    return {
      'title': season != null ? '$title S$season' : title,
      'year': WorkSeason.year({'title': base}),
      'tmdb_id': tmdbId,
      'tmdb_type': PersonalFilenameParser.tmdbType(base),
      if (PersonalFilenameParser.tmdbIds(base).length > 1)
        'conflicting_ids': true,
    };
  }

  Future<ScrapedWork?> scrape(
    Map<String, Object?> work, {
    List<String> filenames = const [],
    bool requireUnambiguous = false,
  }) async {
    work = _sourceEvidence(work);
    try {
      if (work['conflicting_ids'] == true ||
          PersonalFilenameParser.tmdbTypes(
                WorkSeason.directoryTitle(work),
              ).length >
              1 ||
          PersonalFilenameParser.tmdbIds(
                WorkSeason.directoryTitle(work),
              ).length >
              1) {
        return null;
      }
      if (filenames.isEmpty) return await _resolve(work);
      final results = await classify(work, [
        for (var i = 0; i < filenames.length; i++)
          {'id': '$i', 'name': filenames[i]},
      ]);
      if (results.values.any((value) => value == null)) return null;
      final resolved = results.values.whereType<ScrapedWork>().toList();
      if (resolved.isEmpty ||
          resolved.any((value) => !resolved.first.sameWork(value))) {
        return null;
      }
      return resolved.first;
    } on _ReviewRequired {
      if (requireUnambiguous) rethrow;
      return null;
    }
  }

  static Map<String, Object?> _sourceEvidence(Map<String, Object?> work) {
    final id = work['id']?.toString() ?? '';
    if (!id.startsWith('work:') ||
        id.contains(':classified:') ||
        work['manual_lock'] == 1) {
      return work;
    }
    // Display metadata from a previous automatic match is not filename evidence.
    return {
      ...work,
      'title': WorkSeason.directoryTitle(work),
      'year': null,
      'tmdb_id': null,
      'tmdb_type': null,
    };
  }

  Future<ScrapedWork?> _resolve(Map<String, Object?> work) async {
    final rawTitle = WorkSeason.directoryTitle(work);
    if (rawTitle == '@unclassified') return null;
    final directoryId = PersonalFilenameParser.tmdbId(rawTitle);
    final indexedDirectory =
        work['id']?.toString().startsWith('work:') == true &&
        work['id']?.toString().contains(':classified:') != true;
    // Previously automatic metadata is not an explicit user ID. Recheck its
    // directory/filename evidence when asked to rescrape an unlocked work.
    final id =
        directoryId ??
        (indexedDirectory && work['manual_lock'] != 1
            ? null
            : (work['tmdb_id'] as num?)?.toInt());
    final title = PersonalFilenameParser.withoutTmdbMarkers(
      rawTitle,
    ).replaceAll(RegExp(r'\{[^}]*\}|\((?:19|20)\d{2}\)'), '').trim();
    if (title.isEmpty && id == null) return null;
    final year = WorkSeason.year(work);
    final hints = queries(title);
    if (id == null) {
      final local = await _offlineBangumi(title, year, hints: hints);
      if (local != null) {
        if (!indexedDirectory &&
            work['bangumi_id'] != null &&
            work['bangumi_id'] != local['id']) {
          throw _ReviewRequired();
        }
        final resolved = await _offlineWork(local, year);
        if (resolved != null) return resolved;
      }
    }
    Map<String, dynamic>? tmdb;
    if (id != null && id > 0) {
      try {
        tmdb = await _tmdbById(
          id,
          PersonalFilenameParser.tmdbType(rawTitle) ??
              (indexedDirectory && work['manual_lock'] != 1
                  ? null
                  : work['tmdb_type']?.toString()),
          work,
          hints,
        );
      } on _ReviewRequired {
        rethrow;
      } on ScanCancelled {
        rethrow;
      } catch (_) {
        /* Bangumi may be reachable even when TMDB is blocked. */
      }
    } else {
      try {
        tmdb = await _tmdbByTitle(title, year, hints);
      } on _ReviewRequired {
        rethrow;
      } on ScanCancelled {
        rethrow;
      } catch (_) {
        /* Fall back to public Bangumi lookup. */
      }
    }
    var tmdbTitle = (tmdb?['name'] ?? tmdb?['title'] ?? '').toString();
    if (tmdb?['_cc_kind'] == 'movie' &&
        !yearCompatible(year, tmdb?['release_date']?.toString())) {
      return null;
    }
    Map? season;
    if (tmdb?['_cc_kind'] == 'tv') {
      final seasons = (tmdb?['seasons'] as List? ?? [])
          .whereType<Map>()
          .toList();
      final number = WorkSeason.resolve(work, seasons);
      if (number == null &&
          year != null &&
          seasons.isEmpty &&
          !yearCompatible(year, tmdb?['first_air_date']?.toString())) {
        return null;
      }
      if (number == null &&
          year != null &&
          seasons.any((s) => (s['season_number'] as num? ?? 0) > 0) &&
          !WorkSeason.multiple(work)) {
        return null;
      }
      if (WorkSeason.multiple(work)) tmdbTitle = title;
      if (number != null && number > 0) {
        final matches = seasons.where((s) => s['season_number'] == number);
        if (matches.isNotEmpty) season = matches.first;
        try {
          final fetched = await _tmdb('/tv/${tmdb!['id']}/season/$number', {
            'language': 'zh-CN',
          });
          if (fetched?['season_number'] == number) season = fetched;
        } catch (_) {
          /* Season summary may still provide artwork. */
        }
        final date = season?['air_date']?.toString();
        if (season == null ||
            (year != null &&
                date != null &&
                date.length >= 4 &&
                int.tryParse(date.substring(0, 4)) != year)) {
          // An explicit season conflicting with its year must be reviewed.
          return null;
        }
        if (WorkSeason.showSeasonInTitle(work, seasons)) {
          tmdbTitle = '$tmdbTitle 第$number季';
        }
      }
    }
    Map<String, dynamic>? bangumi;
    try {
      bangumi = await matchBangumi(
        title,
        year,
        hints: tmdb != null
            ? <String>{
                ...hints,
                ...queries(tmdbTitle),
                if (tmdb['original_name'] is String)
                  ...queries(tmdb['original_name']),
                if (tmdb['original_title'] is String)
                  ...queries(tmdb['original_title']),
              }.take(4).toList()
            : hints,
        tmdbId: tmdb?['id'] is num ? (tmdb!['id'] as num).toInt() : id,
      );
    } on _ReviewRequired {
      // An ambiguous auxiliary provider must not discard an independently
      // verified TMDB identity. Keep it unlinked instead of guessing a subject.
      if (tmdb == null) rethrow;
    } on ScanCancelled {
      rethrow;
    } catch (_) {
      if (tmdb == null) rethrow;
    }
    final bangumiTitle =
        (bangumi?['name_cn']?.toString().trim().isNotEmpty == true
                ? bangumi!['name_cn']
                : bangumi?['name'])
            ?.toString()
            .trim() ??
        '';
    if (tmdb == null && bangumi == null) return null;
    final posterPath = (season?['poster_path'] ?? tmdb?['poster_path'])
        ?.toString()
        .trim();
    final tmdbPoster = posterPath != null && posterPath.startsWith('/')
        ? MetadataServers.tmdbImage(posterPath)
        : null;
    final bangumiPoster = _poster(bangumi?['images'] as Map?);
    final date =
        (season?['air_date'] ??
                tmdb?['first_air_date'] ??
                tmdb?['release_date'] ??
                bangumi?['date'])
            ?.toString();
    return ScrapedWork(
      title: tmdbTitle.isNotEmpty
          ? tmdbTitle
          : bangumiTitle.isNotEmpty
          ? bangumiTitle
          : title,
      aliases: {
        ...officialTitles(tmdb ?? {}),
        ...officialTitles(bangumi ?? {}),
      },
      provider: tmdb != null
          ? (bangumi != null ? 'TMDB + Bangumi' : 'TMDB')
          : 'Bangumi',
      tmdbId: tmdb?['id'] is num ? (tmdb!['id'] as num).toInt() : id,
      tmdbType: tmdb?['_cc_kind']?.toString() ?? work['tmdb_type']?.toString(),
      bangumiId: bangumi?['id'] is num ? (bangumi!['id'] as num).toInt() : null,
      poster: tmdbPoster ?? bangumiPoster,
      bangumiPoster: bangumiPoster,
      overview: season?['overview']?.toString().trim().isNotEmpty == true
          ? season!['overview'].toString()
          : (tmdb?['overview']?.toString().trim().isNotEmpty == true
                    ? tmdb!['overview']
                    : bangumi?['summary'])
                ?.toString(),
      year:
          year ??
          (date != null && date.length >= 4
              ? int.tryParse(date.substring(0, 4))
              : null),
    );
  }
}
