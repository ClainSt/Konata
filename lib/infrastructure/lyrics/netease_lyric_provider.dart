import 'dart:convert';

import '../../domain/lyrics/lyric_candidate.dart';
import '../../domain/lyrics/lyric_search_query.dart';
import 'lyric_http_transport.dart';

/// 网易云搜索命中的歌曲元数据。
class NeteaseSongHit {
  /// 创建歌曲元数据。
  const NeteaseSongHit({
    required this.id,
    required this.title,
    this.artist = '',
    this.album = '',
    this.durationSeconds,
  });

  /// 网易云歌曲 ID（同时作为 AMLL `ncm-lyrics` 文件名）。
  final String id;

  /// 曲名。
  final String title;

  /// 歌手（多歌手以 `/` 连接）。
  final String artist;

  /// 专辑名。
  final String album;

  /// 时长（秒）。
  final double? durationSeconds;
}

/// 网易云音乐公开接口歌曲搜索与歌词拉取。
class NeteaseLyricProvider {
  /// 创建检索器。
  const NeteaseLyricProvider(this._transport);

  final LyricHttpTransport _transport;

  /// 按“原始曲名 + 歌手”关键词搜索歌曲。
  Future<List<NeteaseSongHit>> searchSongs(LyricSearchQuery query) async {
    final uri = Uri.parse(LyricLookupConfig.neteaseSearchEndpoint).replace(
      queryParameters: {
        's': query.keyword,
        'type': '1',
        'limit': '${LyricLookupConfig.neteaseSearchLimit}',
        'offset': '0',
      },
    );
    final resp = await _transport.get(
      uri,
      timeout: LyricLookupConfig.requestTimeout,
    );
    if (resp.statusCode != 200) return const [];
    final decoded = jsonDecode(utf8.decode(resp.bodyBytes, allowMalformed: true));
    if (decoded is! Map) return const [];
    final result = decoded['result'];
    if (result is! Map) return const [];
    final songs = result['songs'];
    if (songs is! List) return const [];

    final hits = <NeteaseSongHit>[];
    for (final song in songs) {
      if (song is! Map) continue;
      final id = song['id'];
      final name = (song['name'] as String? ?? '').trim();
      if (id == null || name.isEmpty) continue;
      final artists = song['artists'];
      final artistNames = <String>[
        if (artists is List)
          for (final a in artists)
            if (a is Map && (a['name'] as String? ?? '').trim().isNotEmpty)
              (a['name'] as String).trim(),
      ];
      final album = song['album'];
      final durMs = song['duration'];
      hits.add(
        NeteaseSongHit(
          id: '$id',
          title: name,
          artist: artistNames.join('/'),
          album: album is Map ? (album['name'] as String? ?? '').trim() : '',
          durationSeconds: durMs is num && durMs > 0 ? durMs / 1000.0 : null,
        ),
      );
    }
    return hits;
  }

  /// 拉取原文与中文译文（同时间戳拼接，由 LRC 解析器聚合为主行 + 译文行）；无原文返回 `null`。
  Future<LyricCandidate?> fetchLyric(NeteaseSongHit hit) async {
    final uri = Uri.parse(LyricLookupConfig.neteaseLyricEndpoint).replace(
      queryParameters: {'id': hit.id, 'lv': '1', 'tv': '1'},
    );
    final resp = await _transport.get(
      uri,
      timeout: LyricLookupConfig.requestTimeout,
    );
    if (resp.statusCode != 200) return null;
    final decoded = jsonDecode(utf8.decode(resp.bodyBytes, allowMalformed: true));
    if (decoded is! Map) return null;
    final main = _lyricText(decoded['lrc']);
    if (main.trim().isEmpty) return null;
    final translation = _lyricText(decoded['tlyric']);
    final hasTranslation = translation.trim().isNotEmpty;
    return LyricCandidate(
      source: LyricSource.netease,
      sourceId: hit.id,
      title: hit.title,
      artist: hit.artist,
      album: hit.album,
      durationSeconds: hit.durationSeconds,
      lrcContent: hasTranslation ? '$main\n$translation' : main,
      hasTranslation: hasTranslation,
    );
  }

  static String _lyricText(Object? node) {
    if (node is! Map) return '';
    return node['lyric'] as String? ?? '';
  }
}
