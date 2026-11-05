import 'dart:convert';
import 'package:http/http.dart' as http;
import 'metadata.dart';
import 'cloud_media_asset_presentation.dart';
import 'anime_detail_metadata.dart';

/// Standalone adaptation of NipaPlay Personal's public Bangumi cast and TMDB
/// episode-artwork pipeline. No dependency on NipaPlay's providers or players.
class DetailMetadataService {
  static const schemaVersion = 6;
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

  /// Faithful port of NipaPlay Personal BangumiApiService.sortSubjectCharacters.
  /// Stable original index breaks ties, not `type` grouping.
  static List<Map<String, dynamic>> sortSubjectCharacters(
    List<Map<String, dynamic>> characters,
  ) {
    int role(Map<String, dynamic> c) => switch (c['relation']) {
      '主角' || 1 => 0,
      '配角' || 2 => 1,
      '客串' || 3 => 2,
      _ => 3,
    };
    final indexed = characters.asMap().entries.toList();
    indexed.sort((a, b) {
      final group = role(a.value).compareTo(role(b.value));
      if (group != 0) return group;
      final x = num.tryParse('${a.value['order'] ?? ''}');
      final y = num.tryParse('${b.value['order'] ?? ''}');
      if (x != null && y != null && x != y) return x.compareTo(y);
      return a.key.compareTo(b.key);
    });
    return indexed.map((e) => e.value).toList();
  }

  void close() {
    if (_ownsClient) _client.close();
  }

  static String? image(String? path, {String size = 'w780'}) {
    if (path == null || path.isEmpty) return null;
    if (path.startsWith('https://')) return path;
    if (path.startsWith('/')) return 'https://image.tmdb.org/t/p/$size$path';
    return null;
  }

  Future<Map<String, dynamic>> fetch(
    Map<String, Object?> work, {
    List<Map<String, Object?>> assets = const [],
  }) async {
    final result = <String, dynamic>{
      'schemaVersion': schemaVersion,
      'characters': <Map<String, dynamic>>[],
      'seasonEpisodes': <String, dynamic>{},
      'seasonEpisodeCounts': <String, dynamic>{},
      'specialAssets': <String, dynamic>{},
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
          result['companies'] = overview['production_companies'];
          result['year'] =
              (overview['first_air_date'] ?? overview['release_date'])
                  ?.toString();
          result['source'] = 'TMDB';
        }
        if (type == 'movie') {
          // Personal uses landscape work artwork for a movie's main feature.
          // Movies have no TV season/episode still endpoint.
          var artwork = image(
            overview?['backdrop_path']?.toString(),
            size: 'w780',
          );
          if (artwork == null) {
            final images = await _tmdb('/movie/$tmdbId/images', {
              'include_image_language': 'zh,ja,en,null',
            });
            final backdrops = (images?['backdrops'] as List? ?? [])
                .whereType<Map>()
                .where((entry) => image(entry['file_path']?.toString()) != null)
                .toList();
            backdrops.sort((a, b) {
              final score = (num.tryParse('${b['vote_average']}') ?? 0)
                  .compareTo(num.tryParse('${a['vote_average']}') ?? 0);
              if (score != 0) return score;
              return (num.tryParse('${b['width']}') ?? 0).compareTo(
                num.tryParse('${a['width']}') ?? 0,
              );
            });
            if (backdrops.isNotEmpty) {
              artwork = image(
                backdrops.first['file_path']?.toString(),
                size: 'w780',
              );
            }
          }
          result['movieStill'] = artwork;
          result['backdrop'] ??= artwork;
        }
        if (type == 'tv') {
          // Unlike the initial prototype, episode artwork is keyed by
          // TMDB season AND episode number, not only season 1.
          final counts = <String, int>{};
          for (final season in (overview?['seasons'] as List? ?? [])) {
            if (season is! Map) continue;
            final number = (season['season_number'] as num?)?.toInt();
            final count = (season['episode_count'] as num?)?.toInt();
            if (number != null && number > 0 && count != null && count > 0) {
              counts[number.toString()] = count;
            }
          }
          result['seasonEpisodeCounts'] = counts;
          final requested = <int>{1, 0};
          var maxUnseasoned = 0;
          for (final asset in assets) {
            final n = asset['episode'] as int? ?? 0;
            if (n <= 0) continue;
            final explicit = CloudMediaAssetPresentation.explicitSeasonNumber({
              ...asset,
              'episode_number': n,
            });
            final season = (asset['season'] as int? ?? 1);
            if (explicit != null) {
              requested.add(explicit);
            } else if (season > 1) {
              requested.add(season);
            } else if (season == 0) {
              requested.add(0);
            } else if (n > maxUnseasoned) {
              maxUnseasoned = n;
            }
          }
          if (maxUnseasoned > 0) {
            var sum = 0;
            final sorted = counts.keys.map(int.parse).toList()..sort();
            for (final season in sorted) {
              sum += counts['$season']!;
              requested.add(season);
              if (sum >= maxUnseasoned) break;
            }
          }
          final seasons = <String, dynamic>{};
          var specialEntries = <Map<String, dynamic>>[];
          // Sequential bounded calls avoid flooding TMDB for large libraries.
          for (final number in (requested.toList()..sort())) {
            try {
              final payload = await _tmdb('/tv/$tmdbId/season/$number', {
                'language': 'zh-CN',
              });
              final items = <String, dynamic>{};
              for (final episode in (payload?['episodes'] as List? ?? [])) {
                if (episode is! Map) continue;
                final raw = episode['episode_number'];
                if (raw is! num) continue;
                final n = raw.toInt();
                items[n.toString()] = {
                  'name': episode['name'],
                  'overview': episode['overview'],
                  'still': image(
                    episode['still_path']?.toString(),
                    size: 'w500',
                  ),
                  'air_date': episode['air_date'],
                };
                if (number == 0) {
                  specialEntries.add(Map<String, dynamic>.from(episode));
                }
              }
              seasons[number.toString()] = items;
              if (number == 1) result['episodes'] = items;
              if (number == 0) result['specials'] = items;
            } catch (_) {
              /* Optional episode metadata must not block the library. */
            }
          }
          result['seasonEpisodes'] = seasons;
          if (specialEntries.isNotEmpty &&
              assets.any((a) => a['category'] == 'extra')) {
            final matched = CloudMediaAssetPresentation.mapSpecialEpisodes(
              assets: assets,
              specials: specialEntries,
              yearHint: work['year']?.toString(),
            );
            result['specialAssets'] = {
              for (final entry in matched.entries)
                entry.key: {
                  'name': entry.value['name'],
                  'overview': entry.value['overview'],
                  'still': image(
                    entry.value['still_path']?.toString(),
                    size: 'w500',
                  ),
                },
            };
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
              .toList();
          if (tags.isNotEmpty) result['tags'] = tags;
          result['infobox'] = subject['infobox'];
          result['bangumiType'] = subject['type'];
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
        final entries = cast is List
            ? cast
                  .whereType<Map>()
                  .map((e) => Map<String, dynamic>.from(e))
                  .toList()
            : <Map<String, dynamic>>[];
        final sorted = sortSubjectCharacters(entries);
        result['characters'] = sorted.take(40).map((c) {
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
            'relation': c['relation'],
            'order': c['order'],
            'id': c['id'],
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
    // Same stable tag precedence as NipaPlay Personal:
    // format -> studio -> adaptation -> up to 8 remaining tags.
    result['tags'] = AnimeDetailMetadata.tags({
      'metadata_json': jsonEncode({
        'tags': result['tags'],
        // TMDB movie is a storage type, not proof of a theatrical release.
        'typeDescription': work['tmdb_type'] == 'movie' ? null : 'TV',
        'production_companies': result['companies'],
        'infobox': result['infobox'],
      }),
    });
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
