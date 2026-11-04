import 'dart:convert';
import 'package:http/http.dart' as http;
import 'metadata.dart';

/// Standalone adaptation of NipaPlay Personal's public Bangumi cast and TMDB
/// episode-artwork pipeline. No dependency on NipaPlay's providers or players.
class DetailMetadataService {
  DetailMetadataService({
    http.Client? client,
    this.tmdbRequest,
    this.bangumiBase = 'https://api.bgm.tv',
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null;

  final http.Client _client;
  final bool _ownsClient;
  final String bangumiBase;
  final Future<Map<String, dynamic>?> Function(
    String path,
    Map<String, String> params,
  )?
  tmdbRequest;
  static const _userAgent = 'CCPlayer/0.1 (personal anime library)';
  void close() {
    if (_ownsClient) _client.close();
  }

  static String? image(String? path, {String size = 'w780'}) {
    if (path == null || path.isEmpty) return null;
    if (path.startsWith('https://')) return path;
    if (path.startsWith('/')) return 'https://image.tmdb.org/t/p/$size$path';
    return null;
  }

  Future<Map<String, dynamic>> fetch(Map<String, Object?> work) async {
    final result = <String, dynamic>{
      'characters': <Map<String, dynamic>>[],
      'episodes': <String, dynamic>{},
      'specials': <String, dynamic>{},
      'tags': <String>[],
      'errors': <String>[],
    };
    final tmdbId = work['tmdb_id'] as int?;
    final bangumiId = work['bangumi_id'] as int?;
    if (tmdbId != null &&
        (tmdbRequest != null || Metadata.credentials.isConfigured)) {
      final type = work['tmdb_type'] == 'movie' ? 'movie' : 'tv';
      try {
        final overview = await _tmdb('/$type/$tmdbId', {'language': 'zh-CN'});
        if (overview != null) {
          result['backdrop'] = image(
            overview['backdrop_path']?.toString(),
            size: 'original',
          );
          result['poster'] = image(
            overview['poster_path']?.toString(),
            size: 'w500',
          );
          result['score'] = (overview['vote_average'] as num?)?.toDouble();
          result['episodeCount'] = overview['number_of_episodes'];
          result['overview'] = overview['overview'];
          result['tags'] = (overview['genres'] as List? ?? [])
              .whereType<Map>()
              .map((g) => g['name']?.toString() ?? '')
              .where((t) => t.isNotEmpty)
              .toList();
          result['year'] =
              (overview['first_air_date'] ?? overview['release_date'])
                  ?.toString();
          result['source'] = 'TMDB';
        }
        if (type == 'tv') {
          for (final (number, field) in [(1, 'episodes'), (0, 'specials')]) {
            try {
              final season = await _tmdb('/tv/$tmdbId/season/$number', {
                'language': 'zh-CN',
              });
              final episodes = <String, dynamic>{};
              for (final e in (season?['episodes'] as List? ?? [])) {
                if (e is! Map) continue;
                final n = e['episode_number'];
                if (n is! num) continue;
                episodes[n.toInt().toString()] = {
                  'name': e['name'],
                  'overview': e['overview'],
                  'still': image(e['still_path']?.toString(), size: 'w500'),
                  'air_date': e['air_date'],
                };
              }
              result[field] = episodes;
            } catch (_) {
              /* Missing optional season metadata must not block details. */
            }
          }
        }
      } catch (_) {
        (result['errors'] as List<String>).add('TMDB 暂时不可用');
      }
    }
    if (bangumiId != null) {
      try {
        final subject = await _getBangumi('/v0/subjects/$bangumiId');
        if (subject is Map<String, dynamic>) {
          final rating = subject['rating'] is Map
              ? subject['rating'] as Map
              : null;
          if (rating?['score'] is num) {
            result['score'] = (rating!['score'] as num).toDouble();
          }
          final tags = (subject['tags'] as List? ?? [])
              .whereType<Map>()
              .map((t) => t['name']?.toString() ?? '')
              .where((t) => t.isNotEmpty)
              .take(14)
              .toList();
          if (tags.isNotEmpty) result['tags'] = tags;
          result['episodeCount'] ??=
              subject['total_episodes'] ?? subject['eps'];
          if ((result['overview']?.toString().trim().isNotEmpty ?? false) ==
              false) {
            result['overview'] = subject['summary'];
          }
          result['poster'] ??= (subject['images'] is Map)
              ? (subject['images'] as Map)['large']?.toString()
              : null;
          result['source'] = result['source'] == null
              ? 'Bangumi'
              : 'TMDB + Bangumi';
        }
      } catch (_) {
        (result['errors'] as List<String>).add('Bangumi 资料暂时不可用');
      }
      try {
        final cast = await _getBangumi('/v0/subjects/$bangumiId/characters');
        final entries = cast is List ? cast.whereType<Map>().toList() : <Map>[];
        entries.sort(
          (a, b) => (a['type'] == 1 ? 0 : 1).compareTo(b['type'] == 1 ? 0 : 1),
        );
        result['characters'] = entries.take(40).map((c) {
          final imageSet = c['images'] as Map?;
          final actors = (c['actors'] as List? ?? [])
              .whereType<Map>()
              .map(
                (a) => a['name_cn']?.toString().trim().isNotEmpty == true
                    ? a['name_cn'].toString()
                    : a['name']?.toString() ?? '',
              )
              .where((a) => a.isNotEmpty)
              .toList();
          return <String, dynamic>{
            'name': c['name_cn']?.toString().trim().isNotEmpty == true
                ? c['name_cn'].toString()
                : c['name']?.toString() ?? '',
            'image': imageSet?['medium'] ?? imageSet?['small'],
            'actors': actors,
            'type': c['type'],
          };
        }).toList();
      } catch (_) {
        (result['errors'] as List<String>).add('角色资料暂时不可用');
      }
      try {
        final episodes = await _getBangumi(
          '/v0/episodes?subject_id=$bangumiId&type=0&limit=100',
        );
        final rows = episodes is Map
            ? (episodes['data'] as List? ?? [])
            : <dynamic>[];
        final episodeMap = Map<String, dynamic>.from(result['episodes'] as Map);
        for (final item in rows.whereType<Map>()) {
          final number = (item['sort'] as num?)?.toInt();
          if (number == null || number < 1) continue;
          final key = number.toString();
          final old = episodeMap[key] is Map
              ? Map<String, dynamic>.from(episodeMap[key] as Map)
              : <String, dynamic>{};
          final bangumiName =
              (item['name_cn']?.toString().trim().isNotEmpty == true
                      ? item['name_cn']
                      : item['name'])
                  ?.toString();
          if (old['name']?.toString().trim().isNotEmpty != true &&
              bangumiName?.isNotEmpty == true) {
            old['name'] = bangumiName;
          }
          episodeMap[key] = old;
        }
        result['episodes'] = episodeMap;
      } catch (_) {
        /* Optional fallback episode names. */
      }
    }
    return result;
  }

  Future<Map<String, dynamic>?> _tmdb(
    String resource,
    Map<String, String> params,
  ) async {
    if (tmdbRequest != null) return tmdbRequest!(resource, params);
    final credentials = Metadata.credentials;
    if (!credentials.isConfigured) return null;
    final response = await _client
        .get(credentials.uri(resource, params), headers: credentials.headers)
        .timeout(const Duration(seconds: 15));
    if (response.statusCode == 404) return null;
    if (response.statusCode != 200) {
      throw StateError('TMDB HTTP ${response.statusCode}');
    }
    return jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
  }

  Future<dynamic> _getBangumi(String path) async {
    final response = await _client
        .get(
          Uri.parse('$bangumiBase$path'),
          headers: {'User-Agent': _userAgent, 'Accept': 'application/json'},
        )
        .timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      throw StateError('Bangumi HTTP ${response.statusCode}');
    }
    return jsonDecode(utf8.decode(response.bodyBytes));
  }
}
