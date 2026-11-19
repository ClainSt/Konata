import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../../domain/playback/lyric_version_matcher.dart';
import 'dart:developer' as developer;

/// 四级开源歌词检索集中配置常量（集中收口默认端点、超时与响应体积上限）。
abstract final class OpenLyricLookupConfig {
  /// 第二级：LRCLIB 开源同步歌词精确检索端点。
  static const String lrclibSearchEndpoint = 'https://lrclib.net/api/search';

  /// 第三级：AMLL TTML 开源社区逐字/和声歌词索引清单地址。
  static const String amllIndexEndpoint =
      'https://raw.githubusercontent.com/Steve-xmh/amll-ttml-db/main/metadata/raw-lyrics-index.jsonl';

  /// 第三级：AMLL TTML 原始逐字歌词文件基准地址。
  static const String amllRawLyricsBaseUrl =
      'https://raw.githubusercontent.com/Steve-xmh/amll-ttml-db/main/raw-lyrics/';

  /// 第四级：公开音乐曲库歌词兜底检索端点。
  static const String fallbackSearchEndpoint =
      'https://music.163.com/api/search/get';

  /// 第四级：公开音乐曲库歌词正文拉取端点。
  static const String fallbackLyricEndpoint =
      'https://music.163.com/api/song/lyric';

  /// 常规单次歌词查询超时上限。
  static const Duration requestTimeout = Duration(seconds: 6);

  /// AMLL 社区全量索引下载超时上限。
  static const Duration amllIndexTimeout = Duration(seconds: 10);

  /// AMLL 索引在内存中的最长保鲜周期。
  static const Duration amllIndexTtl = Duration(hours: 6);

  /// 统一用户代理标识。
  static const String userAgent = 'KonataPlayer/1.0 (+https://github.com/konata)';
}

/// 歌词命中来源层级枚举。
enum LyricLookupTier {
  /// 第一级：音频内嵌或同目录 `.lrc` 外挂歌词。
  localSidecar,

  /// 第二级：LRCLIB 开源精确歌词库。
  lrclib,

  /// 第三级：AMLL TTML 开源逐字与和声歌词库。
  amllTtmlDb,

  /// 第四级：公开音乐曲库双语兜底源。
  communityFallback,
}

/// 单个在线歌词候选条目（包含供 `LyricVersionMatcher` 消歧打分的元数据与 LRC 正文）。
class OnlineLyricCandidate {
  /// 创建在线歌词候选条目。
  const OnlineLyricCandidate({
    required this.meta,
    required this.lrcContent,
    required this.tier,
  });

  /// 供 `LyricVersionMatcher.selectBestCandidate` 消歧的曲目元数据。
  final LyricCandidateMeta meta;

  /// 标准化后的同步 LRC（可含 `<mm:ss.xx>` 逐字标签与 `bg:` 和声层）。
  final String lrcContent;

  /// 所属检索层级。
  final LyricLookupTier tier;
}

/// 移动计量网络（蜂窝流量 / 按量计费热点）实时探测器。
class MeteredNetworkDetector {
  /// 创建计量网络探测器。
  const MeteredNetworkDetector({this.overrideProbe});

  static const MethodChannel _networkChannel = MethodChannel(
    'ccplayer/network',
  );

  /// 可选测试注入探针。
  final Future<bool> Function()? overrideProbe;

  /// 查询当前活动网络是否属于移动计量网络（桌面端固定返回 `false`，Android 查系统 `ConnectivityManager`）。
  Future<bool> isMeteredMobileNetwork() async {
    final override = overrideProbe;
    if (override != null) {
      return override();
    }
    if (!Platform.isAndroid) {
      return false;
    }
    try {
      final metered = await _networkChannel.invokeMethod<bool>(
        'isMeteredNetwork',
      );
      return metered ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }
}

/// 四级开源歌词网络检索服务（LRCLIB -> AMLL TTML DB -> 公开兜底源）。
class OnlineLyricLookupService {
  /// 创建开源歌词检索服务。
  OnlineLyricLookupService({
    http.Client? httpClient,
    Duration? requestTimeout,
    Duration? amllIndexTimeout,
  }) : _httpClient = httpClient ?? http.Client(),
       _ownsClient = httpClient == null,
       _requestTimeout = requestTimeout ?? OpenLyricLookupConfig.requestTimeout,
       _amllIndexTimeout =
           amllIndexTimeout ?? OpenLyricLookupConfig.amllIndexTimeout;

  final http.Client _httpClient;
  final bool _ownsClient;
  final Duration _requestTimeout;
  final Duration _amllIndexTimeout;

  List<_AmllIndexRow>? _cachedAmllIndex;
  DateTime? _amllIndexLoadedAt;

  /// 第二级：检索 LRCLIB 开源同步歌词候选列表。
  Future<List<OnlineLyricCandidate>> searchLrclib({
    required String title,
    String artist = '',
  }) async {
    final queryParams = <String, String>{
      'track_name': title.trim(),
      if (artist.trim().isNotEmpty) 'artist_name': artist.trim(),
    };
    final uri = Uri.parse(
      OpenLyricLookupConfig.lrclibSearchEndpoint,
    ).replace(queryParameters: queryParams);
    final resp = await _httpClient
        .get(uri, headers: const {'User-Agent': OpenLyricLookupConfig.userAgent})
        .timeout(_requestTimeout);
    if (resp.statusCode != 200) return const [];
    final decoded = jsonDecode(utf8.decode(resp.bodyBytes, allowMalformed: true));
    if (decoded is! List) return const [];

    final out = <OnlineLyricCandidate>[];
    for (final item in decoded) {
      if (item is! Map) continue;
      final synced = (item['syncedLyrics'] as String? ?? '').trim();
      if (synced.isEmpty) continue;
      final id = '${item['id'] ?? out.length}';
      final trackName = (item['trackName'] as String? ?? '').trim();
      final artistName = (item['artistName'] as String? ?? '').trim();
      final durRaw = item['duration'];
      final durationSec = durRaw is num ? durRaw.toDouble() : null;
      out.add(
        OnlineLyricCandidate(
          meta: LyricCandidateMeta(
            id: 'lrclib:$id',
            title: trackName.isNotEmpty ? trackName : title,
            artist: artistName,
            durationSeconds: durationSec,
            sourcePriority: 30,
          ),
          lrcContent: synced,
          tier: LyricLookupTier.lrclib,
        ),
      );
    }
    return out;
  }

  /// 第三级：查询 AMLL TTML 开源逐字与和声歌词库，并将 TTML 转为增强 LRC（含 `<mm:ss.xx>` 与 `bg:` 层）。
  Future<List<OnlineLyricCandidate>> searchAmllTtmlDb({
    required String title,
    String artist = '',
    double? durationSeconds,
  }) async {
    final rows = await _ensureAmllIndex();
    if (rows.isEmpty) return const [];

    final normalizedQuery = _normalizeSearchToken(title);
    if (normalizedQuery.isEmpty) return const [];

    final matchedRows = <_AmllIndexRow>[];
    for (final row in rows) {
      final normRow = _normalizeSearchToken(row.title);
      if (normRow == normalizedQuery ||
          normRow.contains(normalizedQuery) ||
          normalizedQuery.contains(normRow)) {
        matchedRows.add(row);
        if (matchedRows.length >= 6) break;
      }
    }
    if (matchedRows.isEmpty) return const [];

    final candidatesMeta = [
      for (final r in matchedRows)
        LyricCandidateMeta(
          id: r.rawLyricFile,
          title: r.title,
          artist: r.artist,
          durationSeconds: r.durationSeconds,
          sourcePriority: 40,
        ),
    ];
    final bestMeta = LyricVersionMatcher.selectBestCandidate(
      trackTitle: title,
      trackArtist: artist,
      trackDurationSeconds: durationSeconds,
      candidates: candidatesMeta,
    );
    if (bestMeta == null) return const [];

    final rawUri = Uri.parse(
      '${OpenLyricLookupConfig.amllRawLyricsBaseUrl}${Uri.encodeComponent(bestMeta.id)}',
    );
    final resp = await _httpClient
        .get(
          rawUri,
          headers: const {'User-Agent': OpenLyricLookupConfig.userAgent},
        )
        .timeout(_requestTimeout);
    if (resp.statusCode != 200) return const [];
    final ttmlText = utf8.decode(resp.bodyBytes, allowMalformed: true);
    final convertedLrc = convertTtmlToEnhancedLrc(ttmlText);
    if (convertedLrc.trim().isEmpty) return const [];

    return [
      OnlineLyricCandidate(
        meta: bestMeta,
        lrcContent: convertedLrc,
        tier: LyricLookupTier.amllTtmlDb,
      ),
    ];
  }

  /// 第四级：查询公开兜底音乐曲库歌词候选列表。
  Future<List<OnlineLyricCandidate>> searchCommunityFallback({
    required String title,
    String artist = '',
  }) async {
    final keyword = artist.trim().isEmpty ? title.trim() : '$title $artist'.trim();
    final searchUri = Uri.parse(OpenLyricLookupConfig.fallbackSearchEndpoint)
        .replace(
          queryParameters: {
            's': keyword,
            'type': '1',
            'limit': '5',
            'offset': '0',
          },
        );
    final searchResp = await _httpClient
        .get(
          searchUri,
          headers: const {'User-Agent': OpenLyricLookupConfig.userAgent},
        )
        .timeout(_requestTimeout);
    if (searchResp.statusCode != 200) return const [];
    final searchJson = jsonDecode(
      utf8.decode(searchResp.bodyBytes, allowMalformed: true),
    );
    if (searchJson is! Map) return const [];
    final resultNode = searchJson['result'];
    if (resultNode is! Map) return const [];
    final songs = resultNode['songs'];
    if (songs is! List || songs.isEmpty) return const [];

    final metas = <LyricCandidateMeta>[];
    for (final song in songs) {
      if (song is! Map) continue;
      final songId = song['id'];
      final songName = (song['name'] as String? ?? '').trim();
      if (songId == null || songName.isEmpty) continue;
      final artists = song['artists'];
      final artistName = (artists is List && artists.isNotEmpty && artists.first is Map)
          ? ((artists.first as Map)['name'] as String? ?? '').trim()
          : '';
      final durMs = song['duration'];
      final durationSec = durMs is num && durMs > 0 ? durMs / 1000.0 : null;
      metas.add(
        LyricCandidateMeta(
          id: '$songId',
          title: songName,
          artist: artistName,
          durationSeconds: durationSec,
          sourcePriority: 15,
        ),
      );
    }
    if (metas.isEmpty) return const [];

    // 先由 `LyricVersionMatcher` 选出版本与时长最优单曲再按需拉取歌词正文，避免无效多请求。
    final best = LyricVersionMatcher.selectBestCandidate(
      trackTitle: title,
      trackArtist: artist,
      candidates: metas,
    );
    if (best == null) return const [];

    final lyricUri = Uri.parse(OpenLyricLookupConfig.fallbackLyricEndpoint)
        .replace(
          queryParameters: {'id': best.id, 'lv': '1', 'tv': '1'},
        );
    final lyricResp = await _httpClient
        .get(
          lyricUri,
          headers: const {'User-Agent': OpenLyricLookupConfig.userAgent},
        )
        .timeout(_requestTimeout);
    if (lyricResp.statusCode != 200) return const [];
    final lyricJson = jsonDecode(
      utf8.decode(lyricResp.bodyBytes, allowMalformed: true),
    );
    if (lyricJson is! Map) return const [];
    final lrcObj = lyricJson['lrc'];
    final mainLrc = (lrcObj is Map ? lrcObj['lyric'] as String? : null) ?? '';
    if (mainLrc.trim().isEmpty) return const [];
    final tlyricObj = lyricJson['tlyric'];
    final transLrc =
        (tlyricObj is Map ? tlyricObj['lyric'] as String? : null) ?? '';
    final merged = transLrc.trim().isNotEmpty
        ? '$mainLrc\n$transLrc'
        : mainLrc;

    return [
      OnlineLyricCandidate(
        meta: best,
        lrcContent: merged,
        tier: LyricLookupTier.communityFallback,
      ),
    ];
  }

  /// 将 AMLL TTML 逐字/和声 XML 转换为增强 LRC（支持 `<mm:ss.xx>` 逐字与 `bg:` 并行和声行）。
  static String convertTtmlToEnhancedLrc(String ttmlXml) {
    final pRegex = RegExp(
      r'<p\b[^>]*\bbegin="([^"]+)"[^>]*>(.*?)</p>',
      dotAll: true,
      caseSensitive: false,
    );
    final spanRegex = RegExp(
      r'<span\b([^>]*)>(.*?)</span>',
      dotAll: true,
      caseSensitive: false,
    );
    final beginAttr = RegExp(r'\bbegin="([^"]+)"', caseSensitive: false);
    final roleAttr = RegExp(
      r'\bttm:role="([^"]+)"',
      caseSensitive: false,
    );

    final out = StringBuffer();
    for (final pMatch in pRegex.allMatches(ttmlXml)) {
      final lineBeginSec = _parseTtmlTimestampSeconds(pMatch.group(1)!);
      if (lineBeginSec == null) continue;
      final lineTag = _formatLrcTag(lineBeginSec);
      final inner = pMatch.group(2)!;

      final mainBuf = StringBuffer();
      final bgBuf = StringBuffer();
      var hadWordSpan = false;
      for (final sMatch in spanRegex.allMatches(inner)) {
        final attrs = sMatch.group(1)!;
        final text = _decodeXmlEntities(
          sMatch.group(2)!.replaceAll(RegExp(r'<[^>]+>'), ''),
        );
        if (text.isEmpty) continue;
        final role = roleAttr.firstMatch(attrs)?.group(1)?.toLowerCase() ?? '';
        if (role == 'x-translation' || role == 'x-roman') {
          continue;
        }
        final bMatch = beginAttr.firstMatch(attrs);
        final spanSec = bMatch != null
            ? _parseTtmlTimestampSeconds(bMatch.group(1)!)
            : null;
        final target = role == 'x-bg' ? bgBuf : mainBuf;
        if (spanSec != null) {
          hadWordSpan = true;
          target.write('<${_formatLrcTag(spanSec)}>$text');
        } else {
          target.write(text);
        }
      }

      if (mainBuf.isNotEmpty) {
        out.writeln('[$lineTag]${mainBuf.toString().trim()}');
      } else if (!hadWordSpan) {
        final plain = _decodeXmlEntities(
          inner.replaceAll(RegExp(r'<[^>]+>'), ''),
        ).trim();
        if (plain.isNotEmpty) {
          out.writeln('[$lineTag]$plain');
        }
      }
      if (bgBuf.isNotEmpty) {
        out.writeln('[$lineTag]bg:${bgBuf.toString().trim()}');
      }
    }
    return out.toString();
  }

  Future<List<_AmllIndexRow>> _ensureAmllIndex() async {
    final now = DateTime.now();
    if (_cachedAmllIndex != null &&
        _amllIndexLoadedAt != null &&
        now.difference(_amllIndexLoadedAt!) <
            OpenLyricLookupConfig.amllIndexTtl) {
      return _cachedAmllIndex!;
    }
    final resp = await _httpClient
        .get(
          Uri.parse(OpenLyricLookupConfig.amllIndexEndpoint),
          headers: const {'User-Agent': OpenLyricLookupConfig.userAgent},
        )
        .timeout(_amllIndexTimeout);
    if (resp.statusCode != 200) return const [];

    final rows = <_AmllIndexRow>[];
    final body = utf8.decode(resp.bodyBytes, allowMalformed: true);
    for (final line in body.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      try {
        final obj = jsonDecode(trimmed);
        if (obj is! Map) continue;
        final rawFile = (obj['rawLyricFile'] as String? ?? '').trim();
        if (rawFile.isEmpty) continue;
        final metadata = obj['metadata'];
        var title = '';
        var artist = '';
        double? durationSec;
        if (metadata is List) {
          for (final pair in metadata) {
            if (pair is! List || pair.length < 2) continue;
            final key = '${pair[0]}'.toLowerCase();
            final vals = pair[1];
            final firstVal = (vals is List && vals.isNotEmpty)
                ? '${vals.first}'.trim()
                : '';
            if (key == 'musicname' && title.isEmpty) {
              title = firstVal;
            } else if (key == 'artists' && artist.isEmpty) {
              artist = firstVal;
            } else if (key == 'duration' && durationSec == null) {
              final numVal = double.tryParse(firstVal);
              if (numVal != null && numVal > 0) {
                durationSec = numVal > 1000 ? numVal / 1000.0 : numVal;
              }
            }
          }
        }
        if (title.isNotEmpty) {
          rows.add(
            _AmllIndexRow(
              rawLyricFile: rawFile,
              title: title,
              artist: artist,
              durationSeconds: durationSec,
            ),
          );
        }
      } on FormatException catch (error) {
  // 忽略索引中单行格式异常记录。
  developer.log('可恢复异常已记录', name: 'konata.online_lyric_lookup_service', error: error);
}
    }
    _cachedAmllIndex = rows;
    _amllIndexLoadedAt = now;
    return rows;
  }

  static double? _parseTtmlTimestampSeconds(String raw) {
    final trimmed = raw.trim();
    if (trimmed.endsWith('s')) {
      return double.tryParse(trimmed.substring(0, trimmed.length - 1));
    }
    final parts = trimmed.split(':');
    if (parts.length == 2) {
      final m = int.tryParse(parts[0]);
      final s = double.tryParse(parts[1]);
      if (m != null && s != null) return m * 60.0 + s;
    } else if (parts.length == 3) {
      final h = int.tryParse(parts[0]);
      final m = int.tryParse(parts[1]);
      final s = double.tryParse(parts[2]);
      if (h != null && m != null && s != null) {
        return h * 3600.0 + m * 60.0 + s;
      }
    }
    return double.tryParse(trimmed);
  }

  static String _formatLrcTag(double seconds) {
    final totalCs = (seconds < 0 ? 0.0 : seconds * 100.0).round();
    final cs = totalCs % 100;
    final totalSec = totalCs ~/ 100;
    final sec = totalSec % 60;
    final min = totalSec ~/ 60;
    return '${min.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}.${cs.toString().padLeft(2, '0')}';
  }

  static String _decodeXmlEntities(String input) {
    return input
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'");
  }

  static String _normalizeSearchToken(String raw) {
    return raw
        .toLowerCase()
        .replaceAll(RegExp(r'[\s\(\)\[\]（）【】\-_]+'), '')
        .trim();
  }

  /// 释放内部 HTTP 连接资源。
  void dispose() {
    if (_ownsClient) {
      _httpClient.close();
    }
  }
}

class _AmllIndexRow {
  const _AmllIndexRow({
    required this.rawLyricFile,
    required this.title,
    required this.artist,
    this.durationSeconds,
  });

  final String rawLyricFile;
  final String title;
  final String artist;
  final double? durationSeconds;
}
