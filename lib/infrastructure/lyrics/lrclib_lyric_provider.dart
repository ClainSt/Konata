import 'dart:convert';

import '../../domain/lyrics/lyric_candidate.dart';
import '../../domain/lyrics/lyric_search_query.dart';
import 'lyric_http_transport.dart';

/// LRCLIB 开源同步歌词检索。
class LrclibLyricProvider {
  /// 创建检索器。
  const LrclibLyricProvider(this._transport);

  final LyricHttpTransport _transport;

  /// 按曲名与歌手搜索，仅返回带同步时间轴的候选；非 200 响应返回空列表。
  Future<List<LyricCandidate>> search(LyricSearchQuery query) async {
    final uri = Uri.parse(LyricLookupConfig.lrclibSearchEndpoint).replace(
      queryParameters: {
        'track_name': query.title,
        if (query.artist.trim().isNotEmpty) 'artist_name': query.artist.trim(),
      },
    );
    final resp = await _transport.get(
      uri,
      headers: const {'User-Agent': LyricLookupConfig.userAgent},
      timeout: LyricLookupConfig.requestTimeout,
    );
    if (resp.statusCode != 200) return const [];
    final decoded = jsonDecode(utf8.decode(resp.bodyBytes, allowMalformed: true));
    if (decoded is! List) return const [];

    final out = <LyricCandidate>[];
    for (final item in decoded) {
      if (item is! Map) continue;
      final synced = (item['syncedLyrics'] as String? ?? '').trim();
      if (synced.isEmpty) continue;
      final trackName = (item['trackName'] as String? ?? '').trim();
      final duration = item['duration'];
      out.add(
        LyricCandidate(
          source: LyricSource.lrclib,
          sourceId: '${item['id'] ?? out.length}',
          title: trackName.isNotEmpty ? trackName : query.title,
          artist: (item['artistName'] as String? ?? '').trim(),
          album: (item['albumName'] as String? ?? '').trim(),
          durationSeconds: duration is num ? duration.toDouble() : null,
          lrcContent: synced,
        ),
      );
    }
    return out;
  }
}
