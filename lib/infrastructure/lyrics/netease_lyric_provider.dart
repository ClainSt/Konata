import 'dart:convert';

import '../../domain/lyrics/lyric_candidate.dart';
import '../../domain/lyrics/lyric_cleaner.dart';
import '../../domain/lyrics/lyric_merger.dart';
import '../../domain/lyrics/lyric_search_query.dart';
import '../../domain/lyrics/yrc_lyric_parser.dart';
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

/// 网易云音乐公开接口歌曲搜索与歌词拉取（支持原文、中文译文、罗马音 `rv=1` 与 DP 合并清洗）。
class NeteaseLyricProvider {
  /// 创建检索器。
  const NeteaseLyricProvider(this._transport);

  final LyricHttpTransport _transport;

  /// 按“原始曲名 + 歌手”或覆盖关键词搜索歌曲。
  Future<List<NeteaseSongHit>> searchSongs(
    LyricSearchQuery query, {
    String? keywordOverride,
  }) async {
    final keyword = (keywordOverride ?? query.keyword).trim();
    if (keyword.isEmpty) return const [];
    final uri = Uri.parse(LyricLookupConfig.neteaseSearchEndpoint).replace(
      queryParameters: {
        's': keyword,
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
    final decoded = jsonDecode(
      utf8.decode(resp.bodyBytes, allowMalformed: true),
    );
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

  /// 拉取原文、逐字 YRC、中文译文与罗马音（`lv=1&tv=1&rv=1&yv=1`），优先产出保留精确结束时间的逐字候选。
  Future<LyricCandidate?> fetchLyric(NeteaseSongHit hit) async {
    final uri = Uri.parse(LyricLookupConfig.neteaseLyricEndpoint).replace(
      queryParameters: {
        'id': hit.id,
        'lv': '1',
        'tv': '1',
        'rv': '1',
        'yv': '1',
      },
    );
    final resp = await _transport.get(
      uri,
      timeout: LyricLookupConfig.requestTimeout,
    );
    if (resp.statusCode != 200) return null;
    final decoded = jsonDecode(
      utf8.decode(resp.bodyBytes, allowMalformed: true),
    );
    if (decoded is! Map) return null;

    final rawYrc = _lyricText(decoded['yrc']);
    final ytlrc = _lyricText(decoded['ytlrc']);
    final yromalrc = _lyricText(decoded['yromalrc']);
    final translation = _lyricText(decoded['tlyric']);
    final romaji = _lyricText(decoded['romalrc']);

    if (rawYrc.trim().isNotEmpty) {
      final parsedYrc = YrcLyricParser.parse(rawYrc);
      if (parsedYrc.hasWordTiming && parsedYrc.lrcContent.isNotEmpty) {
        // 网易云服务端自动生成的 ytlrc / yromalrc 常因空格或拆行差异遗漏部分句段，
        // 以其为主轨并以完整行级 tlyric / romalrc 兜底填补缺句，兼顾精确时间戳与译文完整度。
        final mergedYrc = LyricMerger.mergeSameSource(
          mainLrc: parsedYrc.lrcContent,
          translationLrc: ytlrc,
          fallbackTranslationLrc: translation,
          romajiLrc: yromalrc,
          fallbackRomajiLrc: romaji,
        );
        if (mergedYrc.lrcContent.isNotEmpty) {
          final mergedCredits = <String>[
            ...parsedYrc.credits,
            for (final c in mergedYrc.credits)
              if (!parsedYrc.credits.contains(c)) c,
          ];
          return LyricCandidate(
            source: LyricSource.netease,
            sourceId: hit.id,
            title: hit.title,
            artist: hit.artist,
            album: hit.album,
            durationSeconds: hit.durationSeconds,
            lrcContent: mergedYrc.lrcContent,
            hasTranslation: mergedYrc.hasTranslation,
            hasWordTiming: true,
            hasRomaji: mergedYrc.hasRomaji,
            translationLrc: _pickRicherAuxLrc(ytlrc, translation),
            romajiLrc: _pickRicherAuxLrc(yromalrc, romaji),
            credits: mergedCredits,
          );
        }
      }
    }

    final main = _lyricText(decoded['lrc']);
    if (main.trim().isEmpty) return null;

    final merged = LyricMerger.mergeSameSource(
      mainLrc: main,
      translationLrc: translation,
      romajiLrc: romaji,
    );
    if (merged.lrcContent.isEmpty) return null;

    return LyricCandidate(
      source: LyricSource.netease,
      sourceId: hit.id,
      title: hit.title,
      artist: hit.artist,
      album: hit.album,
      durationSeconds: hit.durationSeconds,
      lrcContent: merged.lrcContent,
      hasTranslation: merged.hasTranslation,
      hasRomaji: merged.hasRomaji,
      translationLrc: translation,
      romajiLrc: romaji,
      credits: merged.credits,
    );
  }

  static String _pickRicherAuxLrc(String primary, String fallback) {
    final pTrim = primary.trim();
    final fTrim = fallback.trim();
    if (pTrim.isEmpty) return fallback;
    if (fTrim.isEmpty) return primary;
    final pCount = LyricCleaner.parseTimedEntries(pTrim).length;
    final fCount = LyricCleaner.parseTimedEntries(fTrim).length;
    return fCount > pCount ? fallback : primary;
  }

  static String _lyricText(Object? node) {
    if (node is! Map) return '';
    return node['lyric'] as String? ?? '';
  }
}
