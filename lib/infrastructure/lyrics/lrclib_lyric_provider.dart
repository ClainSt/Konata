import 'dart:convert';

import '../../domain/lyrics/lyric_candidate.dart';
import '../../domain/lyrics/lyric_cleaner.dart';
import '../../domain/lyrics/lyric_search_query.dart';
import 'lyric_http_transport.dart';

/// LRCLIB 开源同步歌词检索（支持 `/api/get` 精确时长匹配，404 自动回退 `/api/search`，并保留纯文本候选）。
class LrclibLyricProvider {
  /// 创建检索器。
  const LrclibLyricProvider(this._transport);

  final LyricHttpTransport _transport;

  /// 先尝试 `/api/get` 精确匹配（需具备歌手与时长）；未命中或无同步歌词时自动回退 `/api/search`。
  Future<List<LyricCandidate>> fetchCandidates(LyricSearchQuery query) async {
    LyricCandidate? plainFromGet;
    final hasExactArgs =
        query.artist.trim().isNotEmpty &&
        query.durationSeconds != null &&
        query.durationSeconds! > 0;

    if (hasExactArgs) {
      final exact = await getExact(query);
      if (exact != null) {
        if (exact.isSynced) return [exact];
        plainFromGet = exact;
      }
    }

    final searched = await search(query);
    if (searched.isNotEmpty) return searched;
    return plainFromGet == null ? const [] : [plainFromGet];
  }

  /// 调用 `/api/get` 按曲名、歌手与整秒时长精确获取单曲歌词；404 或非 200 返回 `null`。
  Future<LyricCandidate?> getExact(
    LyricSearchQuery query, {
    String? titleOverride,
    String? artistOverride,
  }) async {
    final trackName = (titleOverride ?? query.title).trim();
    final artistName = (artistOverride ?? query.artist).trim();
    final duration = query.durationSeconds;
    if (trackName.isEmpty || artistName.isEmpty || duration == null || duration <= 0) {
      return null;
    }

    final uri = Uri.parse(LyricLookupConfig.lrclibGetEndpoint).replace(
      queryParameters: {
        'track_name': trackName,
        'artist_name': artistName,
        'duration': '${duration.round()}',
      },
    );
    final resp = await _transport.get(
      uri,
      headers: const {'User-Agent': LyricLookupConfig.userAgent},
      timeout: LyricLookupConfig.requestTimeout,
    );
    if (resp.statusCode != 200) return null;
    final decoded = jsonDecode(
      utf8.decode(resp.bodyBytes, allowMalformed: true),
    );
    if (decoded is! Map) return null;
    return _parseItem(decoded, fallbackTitle: trackName, fallbackIndex: 0);
  }

  /// 按曲名与歌手调用 `/api/search` 搜索，返回同步歌词候选以及仅含纯文本的备选候选。
  Future<List<LyricCandidate>> search(
    LyricSearchQuery query, {
    String? titleOverride,
    String? artistOverride,
  }) async {
    final trackName = (titleOverride ?? query.title).trim();
    final artistName = (artistOverride ?? query.artist).trim();
    if (trackName.isEmpty) return const [];

    final uri = Uri.parse(LyricLookupConfig.lrclibSearchEndpoint).replace(
      queryParameters: {
        'track_name': trackName,
        if (artistName.isNotEmpty) 'artist_name': artistName,
      },
    );
    final resp = await _transport.get(
      uri,
      headers: const {'User-Agent': LyricLookupConfig.userAgent},
      timeout: LyricLookupConfig.requestTimeout,
    );
    if (resp.statusCode != 200) return const [];
    final decoded = jsonDecode(
      utf8.decode(resp.bodyBytes, allowMalformed: true),
    );
    if (decoded is! List) return const [];

    final out = <LyricCandidate>[];
    for (final item in decoded) {
      if (item is! Map) continue;
      final parsed = _parseItem(
        item,
        fallbackTitle: trackName,
        fallbackIndex: out.length,
      );
      if (parsed != null) out.add(parsed);
    }
    return out;
  }

  static LyricCandidate? _parseItem(
    Map<dynamic, dynamic> item, {
    required String fallbackTitle,
    required int fallbackIndex,
  }) {
    final isInstrumental = item['instrumental'] == true;
    final rawSynced = (item['syncedLyrics'] as String? ?? '').trim();
    final rawPlain = (item['plainLyrics'] as String? ?? '').trim();
    if (rawSynced.isEmpty && rawPlain.isEmpty) return null;

    final trackName = (item['trackName'] as String? ?? '').trim();
    final duration = item['duration'];
    final baseId = '${item['id'] ?? fallbackIndex}';
    final title = trackName.isNotEmpty ? trackName : fallbackTitle;
    final artist = (item['artistName'] as String? ?? '').trim();
    final album = (item['albumName'] as String? ?? '').trim();
    final durationSec = duration is num ? duration.toDouble() : null;

    if (rawSynced.isNotEmpty) {
      final cleaned = LyricCleaner.clean(rawSynced);
      if (!cleaned.isPlaceholder) {
        return LyricCandidate(
          source: LyricSource.lrclib,
          sourceId: baseId,
          title: title,
          artist: artist,
          album: album,
          durationSeconds: durationSec,
          lrcContent: cleaned.cleanedLrc,
          plainLyrics: rawPlain,
          isSynced: true,
          isInstrumental: isInstrumental,
          credits: cleaned.credits,
        );
      }
    }

    if (rawPlain.isNotEmpty && LyricCleaner.isValidPlainLyrics(rawPlain)) {
      return LyricCandidate(
        source: LyricSource.lrclib,
        sourceId: baseId,
        title: title,
        artist: artist,
        album: album,
        durationSeconds: durationSec,
        lrcContent: '',
        plainLyrics: LyricCleaner.decodeHtmlEntities(rawPlain),
        isSynced: false,
        isInstrumental: isInstrumental,
      );
    }
    return null;
  }
}
