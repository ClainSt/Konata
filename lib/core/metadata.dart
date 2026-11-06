import 'metadata_servers.dart';
import 'metadata_http.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'tmdb_auth.dart';

class Candidate {
  Candidate({
    required this.provider,
    required this.id,
    required this.title,
    this.year,
    this.poster,
    this.overview,
    this.mediaType = 'tv',
  });
  final String provider, title, mediaType;
  final int id;
  final int? year;
  final String? poster, overview;
}

class Metadata {
  static final http.Client _client = MetadataHttp();
  static String token = '';
  static String apiKey = '';
  static String authMode = 'token';
  static TmdbCredentials get credentials => TmdbCredentials(
    mode: authMode,
    value: authMode == 'apiKey' ? apiKey : token,
  );
  static Future<void> testTmdbCredentials(TmdbCredentials credentials) async {
    final data = await _requestTmdb('/tv/100565', const {
      'language': 'zh-CN',
    }, credentials);
    if (data?['id'] != 100565 ||
        data?['name'] is! String ||
        data?['poster_path'] is! String) {
      throw const FormatException('TMDB 作品响应无效');
    }
  }

  static Future<List<Candidate>> search(String keyword, String provider) async {
    final query = keyword.trim();
    if (query.isEmpty) return [];
    if (provider == 'tmdb') {
      if (!credentials.isConfigured) {
        throw StateError('请先设置 TMDB 访问令牌或 API Key');
      }
      final candidates = <Candidate>[];
      final numeric = int.tryParse(
        query.replaceFirst(RegExp(r'^(?:tv|movie)[:#]?'), ''),
      );
      if (numeric != null) {
        for (final type in ['tv', 'movie']) {
          final item = await _tmdb('/$type/$numeric', {});
          if (item != null) candidates.add(_fromTmdb(item, type));
        }
        return candidates;
      }
      for (final type in ['tv', 'movie']) {
        final result = await _tmdb('/search/$type', {
          'query': query,
          'language': 'zh-CN',
        });
        for (final item in (result?['results'] as List? ?? [])) {
          if (item is Map<String, dynamic>) {
            candidates.add(_fromTmdb(item, type));
          }
        }
      }
      return candidates;
    }
    final response = await _client.post(
      Uri.parse('https://api.bgm.tv/v0/search/subjects'),
      headers: {
        'Content-Type': 'application/json',
        'User-Agent': 'Konata/0.1 (personal library)',
      },
      body: jsonEncode({
        'keyword': query,
        'sort': 'match',
        'filter': {
          'type': [2],
        },
      }),
    );
    if (response.statusCode != 200) {
      throw StateError('Bangumi HTTP ${response.statusCode}');
    }
    final body =
        jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    return (body['data'] as List? ?? []).whereType<Map<String, dynamic>>().map((
      item,
    ) {
      final images = item['images'] as Map?;
      final date = item['date']?.toString() ?? '';
      return Candidate(
        provider: 'bangumi',
        id: (item['id'] as num).toInt(),
        title:
            (item['name_cn']?.toString().isNotEmpty == true
                    ? item['name_cn']
                    : item['name'])
                .toString(),
        year: int.tryParse(date.length >= 4 ? date.substring(0, 4) : ''),
        poster: images?['large']?.toString() ?? images?['common']?.toString(),
        overview: item['summary']?.toString(),
      );
    }).toList();
  }

  static Future<Map<String, dynamic>> tvDetails(int id, {int? season}) async {
    final data = await _tmdb(
      '/tv/$id${season == null ? '' : '/season/$season'}',
      {'language': 'zh-CN'},
    );
    if (data == null) throw StateError('TMDB title not found');
    return data;
  }

  static Candidate _fromTmdb(Map<String, dynamic> item, String type) {
    final date = (item['first_air_date'] ?? item['release_date'] ?? '')
        .toString();
    final poster = item['poster_path']?.toString();
    return Candidate(
      provider: 'tmdb',
      id: (item['id'] as num).toInt(),
      mediaType: type,
      title: (item['name'] ?? item['title'] ?? '未命名').toString(),
      year: int.tryParse(date.length >= 4 ? date.substring(0, 4) : ''),
      poster: poster == null ? null : MetadataServers.tmdbImage(poster),
      overview: item['overview']?.toString(),
    );
  }

  static Future<Map<String, dynamic>?> _tmdb(
    String path,
    Map<String, String> params,
  ) => _requestTmdb(path, params, credentials);

  static Future<Map<String, dynamic>?> _requestTmdb(
    String path,
    Map<String, String> params,
    TmdbCredentials auth,
  ) async {
    if (!auth.isConfigured) throw StateError('请先配置 TMDB 访问凭证');
    // Avoid including a v3 API key in HTTP exception messages.
    http.Response response;
    try {
      response = await _client.get(
        auth.uri(path, params),
        headers: auth.headers,
      );
    } catch (_) {
      throw StateError('TMDB 网络访问失败，请检查网络或代理设置');
    }
    if (response.statusCode == 404) return null;
    if (response.statusCode != 200) {
      throw StateError('TMDB HTTP ${response.statusCode}（请检查凭证和网络）');
    }
    return jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
  }
}
