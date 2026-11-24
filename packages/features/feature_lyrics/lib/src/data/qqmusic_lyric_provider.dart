import 'dart:convert';

import '../domain/lyric_candidate.dart';
import '../domain/lyric_cleaner.dart';
import '../domain/lyric_merger.dart';
import '../domain/lyric_search_query.dart';
import '../domain/qrc_lyric_parser.dart';
import 'lyric_http_transport.dart';
import 'qrc_decryptor.dart';

/// QQ 音乐搜索命中的歌曲元数据。
class QqMusicSongHit {
  /// 创建歌曲元数据。
  const QqMusicSongHit({
    required this.mid,
    required this.id,
    required this.title,
    this.artist = '',
    this.album = '',
    this.durationSeconds,
  });

  /// QQ 音乐歌曲媒体标识（`songmid`）。
  final String mid;

  /// QQ 音乐歌曲数字标识（`songid`）。
  final int id;

  /// 曲名。
  final String title;

  /// 歌手（多歌手以 `/` 连接）。
  final String artist;

  /// 专辑名。
  final String album;

  /// 时长（秒）。
  final double? durationSeconds;
}

/// QQ 音乐非官方公开接口检索器（使用匿名移动网关搜索并拉取逐字或明文歌词与译文）。
class QqMusicLyricProvider {
  /// 创建检索器。
  const QqMusicLyricProvider(this._transport);

  final LyricHttpTransport _transport;

  static const Map<String, String> _headers = <String, String>{
    'Content-Type': 'application/json',
    'Referer': LyricLookupConfig.qqMusicReferer,
    'Origin': 'https://y.qq.com',
  };

  /// 按关键词搜索 QQ 音乐单曲列表。
  Future<List<QqMusicSongHit>> searchSongs(
    LyricSearchQuery query, {
    String? keywordOverride,
  }) async {
    final keyword = (keywordOverride ?? query.keyword).trim();
    if (keyword.isEmpty) return const [];

    final payload = jsonEncode({
      'comm': {
        'ct': 11,
        'cv': '1003006',
        'v': '1003006',
        'tmeAppID': 'qqmusic',
        'format': 'json',
      },
      'req': {
        'module': 'music.search.SearchCgiService',
        'method': 'DoSearchForQQMusicMobile',
        'param': {
          'search_type': 0,
          'query': keyword,
          'page_num': 1,
          'num_per_page': LyricLookupConfig.qqSearchLimit,
        },
      },
    });

    final resp = await _transport.post(
      Uri.parse(LyricLookupConfig.qqMusicUnifiedEndpoint),
      headers: _headers,
      body: payload,
      timeout: LyricLookupConfig.requestTimeout,
    );
    if (resp.statusCode != 200) return const [];
    final decoded = jsonDecode(
      utf8.decode(resp.bodyBytes, allowMalformed: true),
    );
    if (decoded is! Map) return const [];
    final req = decoded['req'];
    if (req is! Map) return const [];
    final data = req['data'];
    if (data is! Map) return const [];
    final body = data['body'];
    if (body is! Map) return const [];
    final songs = body['item_song'];
    if (songs is! List) return const [];

    final hits = <QqMusicSongHit>[];
    for (final item in songs) {
      if (item is! Map) continue;
      final mid = (item['mid'] as String? ?? '').trim();
      final idRaw = item['id'];
      final id = idRaw is num ? idRaw.toInt() : int.tryParse('$idRaw') ?? 0;
      final name = ((item['name'] ?? item['title']) as String? ?? '').trim();
      if (mid.isEmpty || name.isEmpty) continue;
      final singers = item['singer'];
      final singerNames = <String>[
        if (singers is List)
          for (final s in singers)
            if (s is Map && (s['name'] as String? ?? '').trim().isNotEmpty)
              (s['name'] as String).trim(),
      ];
      final album = item['album'];
      final interval = item['interval'];
      hits.add(
        QqMusicSongHit(
          mid: mid,
          id: id,
          title: LyricCleaner.decodeHtmlEntities(name),
          artist: LyricCleaner.decodeHtmlEntities(singerNames.join('/')),
          album: album is Map
              ? LyricCleaner.decodeHtmlEntities(
                  (album['name'] as String? ?? '').trim(),
                )
              : '',
          durationSeconds:
              interval is num && interval > 0 ? interval.toDouble() : null,
        ),
      );
    }
    return hits;
  }

  /// 拉取单曲逐字或明文歌词与中文译文；有加密逐字数据时优先解密解析，失败自动无感回退明文。
  Future<LyricCandidate?> fetchLyric(QqMusicSongHit hit) async {
    final payload = jsonEncode({
      'comm': {'ct': 19, 'cv': 1859, 'uin': 0},
      'req': {
        'module': 'music.musichallSong.PlayLyricInfo',
        'method': 'GetPlayLyricInfo',
        'param': {
          'songMID': hit.mid,
          'songID': hit.id,
          'trans': 1,
          'roma': 0,
          'qrc': 1,
          'crypt': 0,
          'lrc_t': 0,
          'qrc_t': 0,
        },
      },
    });

    final resp = await _transport.post(
      Uri.parse(LyricLookupConfig.qqMusicUnifiedEndpoint),
      headers: _headers,
      body: payload,
      timeout: LyricLookupConfig.requestTimeout,
    );
    if (resp.statusCode != 200) return null;
    final decoded = jsonDecode(
      utf8.decode(resp.bodyBytes, allowMalformed: true),
    );
    if (decoded is! Map) return null;
    final req = decoded['req'];
    if (req is! Map) return null;
    final data = req['data'];
    if (data is! Map) return null;

    final rawTrans = _decodeBase64Text(data['trans']);
    final rawLyricField = (data['lyric'] as String? ?? '').trim();
    if (rawLyricField.isEmpty) return null;

    final qrcFlag = data['qrc'] == 1 || data['qrc'] == true;
    if (qrcFlag && QrcDecryptor.isValidCipherHex(rawLyricField)) {
      final decrypted = QrcDecryptor.decryptHex(rawLyricField);
      if (decrypted != null && decrypted.trim().isNotEmpty) {
        final parsedQrc = QrcLyricParser.parse(decrypted);
        if (parsedQrc.hasWordTiming && parsedQrc.lrcContent.isNotEmpty) {
          final mergedQrc = LyricMerger.mergeSameSource(
            mainLrc: parsedQrc.lrcContent,
            translationLrc: rawTrans,
          );
          if (mergedQrc.lrcContent.isNotEmpty) {
            final mergedCredits = <String>[
              ...parsedQrc.credits,
              for (final c in mergedQrc.credits)
                if (!parsedQrc.credits.contains(c)) c,
            ];
            return LyricCandidate(
              source: LyricSource.qq,
              sourceId: hit.mid,
              title: hit.title,
              artist: hit.artist,
              album: hit.album,
              durationSeconds: hit.durationSeconds,
              lrcContent: mergedQrc.lrcContent,
              hasTranslation: mergedQrc.hasTranslation,
              hasWordTiming: true,
              translationLrc: rawTrans,
              credits: mergedCredits,
            );
          }
        }
      }
    }

    final rawLrc = _decodeBase64Text(rawLyricField);
    if (rawLrc.trim().isEmpty) return null;

    final merged = LyricMerger.mergeSameSource(
      mainLrc: rawLrc,
      translationLrc: rawTrans,
    );
    if (merged.lrcContent.isEmpty) return null;

    return LyricCandidate(
      source: LyricSource.qq,
      sourceId: hit.mid,
      title: hit.title,
      artist: hit.artist,
      album: hit.album,
      durationSeconds: hit.durationSeconds,
      lrcContent: merged.lrcContent,
      hasTranslation: merged.hasTranslation,
      translationLrc: rawTrans,
      credits: merged.credits,
    );
  }

  static String _decodeBase64Text(Object? raw) {
    final text = (raw as String? ?? '').trim();
    if (text.isEmpty) return '';
    try {
      final bytes = base64Decode(text);
      return LyricCleaner.decodeHtmlEntities(
        utf8.decode(bytes, allowMalformed: true),
      );
    } catch (_) {
      return LyricCleaner.decodeHtmlEntities(text);
    }
  }
}
