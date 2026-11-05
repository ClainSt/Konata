import 'dart:convert';
import 'package:http/http.dart' as http;
import 'metadata.dart';
import 'personal_filename_parser.dart';
import 'work_season.dart';

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
  });
  final String title, provider;
  final int? tmdbId, bangumiId, year;
  final String? tmdbType, poster, bangumiPoster, overview;
}

class ScrapeReport {
  const ScrapeReport(this.matched, this.skipped, this.review, this.errors);
  final int matched, skipped, review, errors;
}

class PersonalMetadataScraper {
  PersonalMetadataScraper({
    http.Client? client,
    this._bangumiBase = 'https://api.bgm.tv',
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null;
  final http.Client _client;
  final bool _ownsClient;
  final String _bangumiBase;
  void close() {
    if (_ownsClient) _client.close();
  }

  static String normalize(String title) => title
      .toLowerCase()
      .replaceAll(RegExp(r'\{tmdb-\d+\}', caseSensitive: false), ' ')
      .replaceAll(RegExp(r'\[[^\]]*\]'), ' ')
      .replaceAll(RegExp(r'\b(?:19|20)\d{2}\b'), ' ')
      .replaceAll(RegExp(r'[\s\-_—–:：.()（）\[\]【】{}!?！？・·,，、]'), '')
      .trim();
  static bool exactTitle(String a, String b) {
    final x = normalize(a), y = normalize(b);
    return x.length >= 3 && x == y;
  }

  static bool subjectTitleMatches(String query, String candidate, int? year) {
    if (exactTitle(query, candidate)) return true;
    // Personal permits subtitle containment. Require a release-year guard
    // and keep the unique-subject check below before accepting that fallback.
    if (year == null) return false;
    final x = normalize(query), y = normalize(candidate);
    if (x.length < 3 || y.length < 3) return false;
    final wantedSeason = WorkSeason.explicit({'title': query});
    final candidateSeason = WorkSeason.explicit({'title': candidate});
    if (wantedSeason != null &&
        candidateSeason != null &&
        wantedSeason != candidateSeason) {
      return false;
    }
    return x.contains(y) || y.contains(x);
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
        if (keyword.length < 3) continue;
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
  ) async {
    final credentials = Metadata.credentials;
    if (!credentials.isConfigured) return null;
    http.Response response;
    try {
      response = await _client
          .get(credentials.uri(path, params), headers: credentials.headers)
          .timeout(const Duration(seconds: 15));
    } catch (_) {
      throw StateError('TMDB 网络连接失败');
    }
    if (response.statusCode == 404) return null;
    if (response.statusCode != 200) {
      throw StateError('TMDB HTTP ${response.statusCode}');
    }
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    return decoded is Map<String, dynamic> ? decoded : null;
  }

  Future<Map<String, dynamic>?> _tmdbById(int id, String type) async {
    // TMDB ID is authoritative; retry movie when a folder was provisionally
    // classified as TV (or vice versa).
    for (final kind in [
      type == 'movie' ? 'movie' : 'tv',
      type == 'movie' ? 'tv' : 'movie',
    ]) {
      final item = await _tmdb('/$kind/$id', {'language': 'zh-CN'});
      if (item == null) continue;
      if (item['id'] is! num || (item['id'] as num).toInt() != id) continue;
      return {...item, '_cc_kind': kind};
    }
    return null;
  }

  Future<Map<String, dynamic>?> _tmdbByTitle(
    String title,
    int? year,
    List<String> hints,
  ) async {
    if (!Metadata.credentials.isConfigured) return null;
    final candidates = <Map<String, dynamic>>[];
    for (final query in hints) {
      for (final type in ['tv', 'movie']) {
        final data = await _tmdb('/search/$type', {
          'language': 'zh-CN',
          'query': query,
        });
        for (final item in (data?['results'] as List? ?? []).whereType<Map>()) {
          final name = (item['name'] ?? item['title'] ?? '').toString();
          final original =
              (item['original_name'] ?? item['original_title'] ?? '')
                  .toString();
          final date = (item['first_air_date'] ?? item['release_date'])
              ?.toString();
          if (!(exactTitle(query, name) || exactTitle(query, original))) {
            continue;
          }
          Map<String, dynamic> full = Map<String, dynamic>.from(item);
          if (!yearCompatible(year, date)) {
            if (type != 'tv') continue;
            final show = await _tmdb('/tv/${item['id']}', {
              'language': 'zh-CN',
            });
            final seasons = (show?['seasons'] as List? ?? [])
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
            full.addAll(show!);
          }
          candidates.add({...full, '_cc_kind': type});
        }
      }
      if (candidates.isNotEmpty) break;
    }
    // Never auto-assign an ambiguous title; user can search manually.
    final distinct = {
      for (final item in candidates) "${item['_cc_kind']}:${item['id']}": item,
    };
    return distinct.length == 1 ? distinct.values.first : null;
  }

  Future<Map<String, dynamic>?> _bangumi(
    String title,
    int? year, {
    int? tmdbId,
    List<String> hints = const [],
  }) async {
    for (final query in hints.isEmpty ? queries(title) : hints) {
      http.Response result;
      try {
        result = await _client
            .post(
              Uri.parse('$_bangumiBase/v0/search/subjects'),
              headers: {
                'User-Agent': 'CCPlayer/0.1 (personal media library)',
                'Content-Type': 'application/json',
                'Accept': 'application/json',
              },
              body: jsonEncode({
                'keyword': query,
                'sort': 'match',
                'filter': {
                  'type': [2],
                },
              }),
            )
            .timeout(const Duration(seconds: 12));
      } catch (_) {
        return null;
      }
      if (result.statusCode != 200) continue;
      final body = jsonDecode(utf8.decode(result.bodyBytes));
      final all = body is Map ? body['data'] : null;
      if (all is! List) continue;
      final matches = all.whereType<Map>().where((c) {
        return (subjectTitleMatches(
                  query,
                  c['name_cn']?.toString() ?? '',
                  year,
                ) ||
                subjectTitleMatches(
                  query,
                  c['name']?.toString() ?? '',
                  year,
                )) &&
            yearCompatible(year, c['date']?.toString());
      }).toList();
      final ids = {for (final c in matches) int.tryParse(c['id'].toString())};
      ids.remove(null);
      if (ids.length != 1) continue;
      final id = ids.first!;
      http.Response info;
      try {
        info = await _client
            .get(
              Uri.parse('$_bangumiBase/v0/subjects/$id'),
              headers: {
                'User-Agent': 'CCPlayer/0.1 (personal media library)',
                'Accept': 'application/json',
              },
            )
            .timeout(const Duration(seconds: 12));
      } catch (_) {
        continue;
      }
      if (info.statusCode != 200) continue;
      final decoded = jsonDecode(utf8.decode(info.bodyBytes));
      if (decoded is! Map<String, dynamic>) continue;
      if (!yearCompatible(year, decoded['date']?.toString())) continue;
      if (tmdbId != null) {
        // Reject an explicitly conflicting TMDB identifier in Bangumi infobox.
        final entries = decoded['infobox'];
        if (entries is List) {
          for (final row in entries.whereType<Map>()) {
            final key = row['key']?.toString().toLowerCase() ?? '';
            if (!key.contains('tmdb')) continue;
            final value = row['value']?.toString() ?? '';
            final found = int.tryParse(
              RegExp(r'\d+').firstMatch(value)?.group(0) ?? '',
            );
            if (found != null && found != tmdbId) return null;
          }
        }
      }
      return decoded;
    }
    return null;
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

  Future<ScrapedWork?> scrape(
    Map<String, Object?> work, {
    List<String> filenames = const [],
  }) async {
    final title = WorkSeason.directoryTitle(
      work,
    ).replaceAll(RegExp(r'\{[^}]*\}|\((?:19|20)\d{2}\)'), '').trim();
    if (title.isEmpty) return null;
    final year = WorkSeason.year(work);
    final hints = titleHints(title, filenames);
    final id = work['tmdb_id'] is num ? (work['tmdb_id'] as num).toInt() : null;
    Map<String, dynamic>? tmdb;
    if (id != null && id > 0) {
      try {
        tmdb = await _tmdbById(id, work['tmdb_type']?.toString() ?? 'tv');
      } catch (_) {
        /* Bangumi may be reachable even when TMDB is blocked. */
      }
    } else {
      try {
        tmdb = await _tmdbByTitle(title, year, hints);
      } catch (_) {
        /* Fall back to public Bangumi lookup. */
      }
    }
    var tmdbTitle = (tmdb?['name'] ?? tmdb?['title'] ?? '').toString();
    Map? season;
    if (tmdb?['_cc_kind'] == 'tv') {
      final seasons = (tmdb?['seasons'] as List? ?? [])
          .whereType<Map>()
          .toList();
      final number = WorkSeason.resolve(work, seasons);
      if (number == null &&
          year != null &&
          seasons.length > 1 &&
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
        tmdbTitle = '$tmdbTitle 第$number季';
      }
    }
    final bangumi = await _bangumi(
      title,
      year,
      hints: hints,
      tmdbId: tmdb?['id'] is num ? (tmdb!['id'] as num).toInt() : id,
    );
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
        ? 'https://image.tmdb.org/t/p/w500$posterPath'
        : null;
    final bangumiPoster = _poster(bangumi?['images'] as Map?);
    final date =
        (tmdb?['first_air_date'] ?? tmdb?['release_date'] ?? bangumi?['date'])
            ?.toString();
    return ScrapedWork(
      title: tmdbTitle.isNotEmpty
          ? tmdbTitle
          : bangumiTitle.isNotEmpty
          ? bangumiTitle
          : title,
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
