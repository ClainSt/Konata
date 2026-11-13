import 'bangumi_links.dart';
import 'metadata_servers.dart';
import 'metadata_http.dart';
import 'work_season.dart';
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

class BackdropOption {
  const BackdropOption({
    required this.key,
    required this.label,
    required this.url,
    required this.source,
    this.subjectId,
  });
  final String key, label, url, source;
  final int? subjectId;
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
      final kind = work['tmdb_type'] == 'movie' ? 'movie' : 'tv';
      try {
        final auth = Metadata.credentials;
        final explicitSeason = kind == 'tv' ? WorkSeason.explicit(work) : null;
        var gotSeasonPoster = false;
        if (explicitSeason != null && explicitSeason > 0) {
          final seasonResp = await _client.get(
            auth.uri('/tv/${tmdbId.toInt()}/season/$explicitSeason', {
              'language': 'zh-CN',
            }),
            headers: auth.headers,
          );
          if (seasonResp.statusCode == 200) {
            final seasonBody = jsonDecode(utf8.decode(seasonResp.bodyBytes));
            if (seasonBody is Map) {
              final seasonPoster = seasonBody['poster_path']?.toString() ?? '';
              if (seasonPoster.startsWith('/')) {
                tmdb = 'https://images.tmdb.org/t/p/original$seasonPoster';
                gotSeasonPoster = true;
              }
            }
          }
        }
        if (!gotSeasonPoster) {
          final response = await _client.get(
            auth.uri('/$kind/${tmdbId.toInt()}', {'language': 'zh-CN'}),
            headers: auth.headers,
          );
          if (response.statusCode == 200) {
            final body = jsonDecode(utf8.decode(response.bodyBytes));
            if (body is Map) {
              final posterPath = body['poster_path']?.toString() ?? '';
              if (posterPath.startsWith('/')) {
                tmdb = 'https://images.tmdb.org/t/p/original$posterPath';
              }
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

  Future<List<BackdropOption>> fetchBackdrops(
    Map<String, Object?> work, {
    String? fallbackBackdrop,
  }) async {
    final results = <BackdropOption>[];
    final seen = <String>{};
    void addOption({
      required String key,
      required String label,
      required String? url,
      required String source,
      int? subjectId,
    }) {
      final clean = validUrl(url);
      if (clean == null || !seen.add(clean)) return;
      results.add(
        BackdropOption(
          key: key,
          label: label,
          url: clean,
          source: source,
          subjectId: subjectId,
        ),
      );
    }

    final tmdbId = work['tmdb_id'];
    if (tmdbId is num && Metadata.credentials.isConfigured) {
      final kind = work['tmdb_type'] == 'movie' ? 'movie' : 'tv';
      final id = tmdbId.toInt();
      final auth = Metadata.credentials;
      try {
        final response = await _client.get(
          auth.uri('/$kind/$id', {'language': 'zh-CN'}),
          headers: auth.headers,
        );
        if (response.statusCode == 200) {
          final body = jsonDecode(utf8.decode(response.bodyBytes));
          if (body is Map) {
            final backdropPath = body['backdrop_path']?.toString() ?? '';
            if (backdropPath.startsWith('/')) {
              addOption(
                key: 'tmdb-0',
                label: 'TMDB',
                url: MetadataServers.tmdbImage(backdropPath, 'original'),
                source: 'tmdb',
                subjectId: id,
              );
            }
          }
        }
      } catch (_) {}
      try {
        final imagesResp = await _client.get(
          auth.uri('/$kind/$id/images', {
            'include_image_language': 'null,ja,zh,en',
          }),
          headers: auth.headers,
        );
        if (imagesResp.statusCode == 200) {
          final body = jsonDecode(utf8.decode(imagesResp.bodyBytes));
          if (body is Map && body['backdrops'] is List) {
            var idx = results.length;
            for (final item in (body['backdrops'] as List).whereType<Map>()) {
              if (idx >= 6) break;
              final filePath = item['file_path']?.toString() ?? '';
              if (!filePath.startsWith('/')) continue;
              idx++;
              addOption(
                key: 'tmdb-$idx',
                label: idx == 1 && results.isEmpty ? 'TMDB' : 'TMDB $idx',
                url: MetadataServers.tmdbImage(filePath, 'original'),
                source: 'tmdb',
                subjectId: id,
              );
            }
          }
        }
      } catch (_) {}
    }

    if (results.isEmpty && fallbackBackdrop != null) {
      final isTmdb = MetadataServers.imageResource(fallbackBackdrop)?.$1 == 1;
      addOption(
        key: isTmdb ? 'tmdb-cached' : 'bangumi-cached',
        label: isTmdb ? 'TMDB' : 'Bangumi',
        url: fallbackBackdrop,
        source: isTmdb ? 'tmdb' : 'bangumi',
        subjectId: isTmdb
            ? (work['tmdb_id'] as num?)?.toInt()
            : (work['bangumi_id'] as num?)?.toInt(),
      );
    }

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
            for (final key in ['large', 'common', 'medium']) {
              final found = validUrl(images[key]?.toString());
              if (found != null) {
                addOption(
                  key: 'bangumi-$bgmId',
                  label: 'Bangumi',
                  url: found,
                  source: 'bangumi',
                  subjectId: bgmId,
                );
                break;
              }
            }
          }
        }
      } catch (_) {}
    }
    if (results.every((o) => o.source != 'bangumi')) {
      final fallback = validUrl(work['poster_fallback']?.toString());
      if (fallback != null) {
        addOption(
          key: 'bangumi-fallback',
          label: 'Bangumi',
          url: fallback,
          source: 'bangumi',
          subjectId: (work['bangumi_id'] as num?)?.toInt(),
        );
      }
    }
    return results;
  }
}
