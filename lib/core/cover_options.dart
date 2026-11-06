import 'bangumi_links.dart';
import 'metadata_servers.dart';
import 'metadata_http.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'metadata.dart';

class CoverOptions {
  const CoverOptions({this.tmdb, this.bangumi, this.bangumiCovers = const {}});
  final Map<int, String> bangumiCovers;
  final String? tmdb, bangumi;
  String? forSource(String source) => source == 'tmdb'
      ? tmdb
      : source == 'bangumi'
      ? bangumi
      : null;
}

/// Discover provider cover options without modifying work metadata.
class CoverOptionService {
  CoverOptionService({
    http.Client? client,
    this.bangumiBase = 'https://api.bgm.tv',
  }) : _client = client ?? MetadataHttp(),
       _ownsClient = client == null;
  final http.Client _client;
  final bool _ownsClient;
  final String bangumiBase;
  void close() {
    if (_ownsClient) _client.close();
  }

  static String? validUrl(String? value) {
    final raw = value?.trim() ?? '';
    final uri = Uri.tryParse(raw);
    if (uri == null ||
        !uri.hasAuthority ||
        !(uri.isScheme('https') || uri.isScheme('http'))) {
      return null;
    }
    return raw;
  }

  Future<CoverOptions> fetch(Map<String, Object?> work) async {
    String? tmdb, bangumi;
    final saved = validUrl(work['poster']?.toString());
    final fallback = validUrl(work['poster_fallback']?.toString());
    final selected = validUrl(work['manual_cover_url']?.toString());
    final selectedSource = work['manual_cover_source']?.toString();
    final savedIsTmdb =
        saved != null && MetadataServers.imageResource(saved)?.$1 == 1;
    if (saved != null && savedIsTmdb) {
      tmdb = saved;
    }
    if (saved != null && !savedIsTmdb) {
      bangumi = saved;
    }
    if (fallback != null) bangumi = fallback;
    if (selectedSource == 'tmdb' && selected != null) tmdb = selected;
    if (selectedSource == 'bangumi' && selected != null) bangumi = selected;

    final tmdbId = work['tmdb_id'];
    if (tmdbId is num && Metadata.credentials.isConfigured) {
      final path = work['tmdb_type'] == 'movie' ? 'movie' : 'tv';
      try {
        final auth = Metadata.credentials;
        final response = await _client.get(
          auth.uri('/$path/${tmdbId.toInt()}', {'language': 'zh-CN'}),
          headers: auth.headers,
        );
        if (response.statusCode == 200) {
          final body = jsonDecode(utf8.decode(response.bodyBytes));
          if (body is Map) {
            final path = body['poster_path']?.toString() ?? '';
            if (path.startsWith('/')) {
              tmdb = MetadataServers.tmdbImage(path, 'original');
            }
          }
        }
      } catch (_) {
        /* Preserve stored candidate when provider is unavailable. */
      }
    }
    final bangumiCovers = <int, String>{};
    for (final bgmId in BangumiLinks.ids(work)) {
      try {
        final response = await _client.get(
          Uri.parse('$bangumiBase/v0/subjects/${bgmId.toInt()}'),
          headers: {
            'User-Agent': 'Konata/0.1 (personal library)',
            'Accept': 'application/json',
          },
        );
        if (response.statusCode == 200) {
          final body = jsonDecode(utf8.decode(response.bodyBytes));
          if (body is Map && body['images'] is Map) {
            final images = body['images'] as Map;
            for (final key in ['large', 'common', 'medium', 'small']) {
              final found = validUrl(images[key]?.toString());
              if (found != null) {
                bangumiCovers[bgmId] = found;
                bangumi ??= found;
                break;
              }
            }
          }
        }
      } catch (_) {
        /* Preserve fallback candidate. */
      }
    }
    return CoverOptions(
      tmdb: tmdb,
      bangumi: bangumi,
      bangumiCovers: bangumiCovers,
    );
  }
}
