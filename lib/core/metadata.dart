import 'dart:convert';
import 'package:http/http.dart' as http;

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
  static String token = '';
  static Future<List<Candidate>> search(String keyword, String provider) async {
    final query = keyword.trim();
    if (query.isEmpty) return [];
    if (provider == 'tmdb') {
      if (token.isEmpty) throw StateError('请先设置 TMDB Read Access Token');
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
    final response = await http
        .post(
          Uri.parse('https://api.bgm.tv/v0/search/subjects'),
          headers: {
            'Content-Type': 'application/json',
            'User-Agent': 'CCPlayer/0.1 (personal library)',
          },
          body: jsonEncode({
            'keyword': query,
            'sort': 'match',
            'filter': {
              'type': [2],
            },
          }),
        )
        .timeout(const Duration(seconds: 15));
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
      poster: poster == null ? null : 'https://image.tmdb.org/t/p/w500$poster',
      overview: item['overview']?.toString(),
    );
  }

  static Future<Map<String, dynamic>?> _tmdb(
    String path,
    Map<String, String> params,
  ) async {
    final url = Uri.parse(
      'https://api.themoviedb.org/3$path',
    ).replace(queryParameters: params);
    final response = await http
        .get(
          url,
          headers: {
            'Authorization': 'Bearer $token',
            'Accept': 'application/json',
          },
        )
        .timeout(const Duration(seconds: 15));
    if (response.statusCode == 404) return null;
    if (response.statusCode != 200) {
      throw StateError('TMDB HTTP ${response.statusCode}');
    }
    return jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
  }
}
