// Konata 歌词引擎离线 fixtures 回放评测工具（零网络，纯 Dart）。
// 用法：dart run tool/lyric_bench.dart [fixtures路径]
import 'dart:convert';
import 'dart:io';

import 'package:konata/application/playback/lyric_candidate_sources.dart';
import 'package:konata/application/playback/lyric_race_engine.dart';
import 'package:konata/domain/lyrics/lyric_candidate.dart';
import 'package:konata/domain/lyrics/lyric_candidate_scorer.dart';
import 'package:konata/domain/lyrics/lyric_search_query.dart';
import 'package:konata/domain/lyrics/ttml_lyric_converter.dart';
import 'package:konata/domain/matching/work_matcher_scoring.dart';
import 'package:konata/domain/playback/cue_and_lrc_parser.dart';
import 'package:konata/domain/playback/lyric_version_matcher.dart';
import 'package:konata/infrastructure/lyrics/amll_lyric_provider.dart';
import 'package:konata/infrastructure/lyrics/lrclib_lyric_provider.dart';
import 'package:konata/infrastructure/lyrics/lyric_http_transport.dart';
import 'package:konata/infrastructure/lyrics/netease_lyric_provider.dart';
import 'package:konata/infrastructure/lyrics/qqmusic_lyric_provider.dart';
import 'package:http/http.dart' as http;

/// 单条离线评测用例。
class _BenchFixture {
  const _BenchFixture({
    required this.id,
    required this.category,
    required this.expectMatch,
    required this.title,
    required this.artist,
    required this.fileName,
    required this.duration,
    required this.expectedTitleKeyword,
    required this.expectedArtistKeyword,
    required this.raw,
  });

  factory _BenchFixture.fromMap(Map<String, Object?> map) {
    return _BenchFixture(
      id: map['id'] as String? ?? '',
      category: map['category'] as String? ?? 'general',
      expectMatch: map['expectMatch'] as bool? ?? true,
      title: map['title'] as String? ?? '',
      artist: map['artist'] as String? ?? '',
      fileName: map['fileName'] as String? ?? '',
      duration: (map['duration'] as num?)?.toDouble(),
      expectedTitleKeyword: map['expectedTitleKeyword'] as String? ?? '',
      expectedArtistKeyword: map['expectedArtistKeyword'] as String? ?? '',
      raw: map,
    );
  }

  final String id;
  final String category;
  final bool expectMatch;
  final String title;
  final String artist;
  final String fileName;
  final double? duration;
  final String expectedTitleKeyword;
  final String expectedArtistKeyword;
  final Map<String, Object?> raw;
}

/// 基于离线 fixtures 的零网络歌词传输回放器。
class _FixtureReplayTransport implements LyricHttpTransport {
  _FixtureReplayTransport(this.fixture, {this.disableLrclibGet = false});

  final _BenchFixture fixture;
  final bool disableLrclibGet;

  @override
  Future<http.Response> get(
    Uri uri, {
    Map<String, String> headers = const {},
    required Duration timeout,
  }) async {
    final host = uri.host;
    final path = uri.path;

    if (host == 'music.163.com' && path.endsWith('/search/get')) {
      final keyword = (uri.queryParameters['s'] ?? '').toLowerCase();
      final byKeyword = fixture.raw['ncmSongsByKeyword'];
      List<Object?> songs = const [];
      if (byKeyword is Map) {
        for (final entry in byKeyword.entries) {
          if (keyword == entry.key.toString().toLowerCase()) {
            songs = (entry.value as List?)?.cast<Object?>() ?? const [];
            break;
          }
        }
      }
      if (songs.isEmpty) {
        final fallback = fixture.raw['ncmSongs'];
        if (fallback is List) songs = fallback.cast<Object?>();
      }
      return _jsonResponse({'result': {'songs': songs}});
    }

    if (host == 'music.163.com' && path.endsWith('/song/lyric')) {
      final id = uri.queryParameters['id'] ?? '';
      final lyricsMap = fixture.raw['ncmLyrics'];
      if (lyricsMap is Map && lyricsMap[id] is Map) {
        return _jsonResponse(lyricsMap[id] as Map);
      }
      return _jsonResponse(const {});
    }

    if (host == 'raw.githubusercontent.com' || host == 'fastly.jsdelivr.net') {
      final fileName = path.split('/').last;
      final id = fileName.replaceFirst(RegExp(r'\.ttml$'), '');
      final amllMap = fixture.raw['amllTtmls'];
      if (amllMap is Map && amllMap[id] is String) {
        return http.Response.bytes(utf8.encode(amllMap[id] as String), 200);
      }
      return http.Response('Not Found', 404);
    }

    if (host == 'lrclib.net' && path == '/api/get') {
      if (disableLrclibGet) return http.Response('Not Found', 404);
      final exact = fixture.raw['lrclibGet'];
      if (exact is Map) return _jsonResponse(exact);
      return http.Response('Not Found', 404);
    }

    if (host == 'lrclib.net' && path == '/api/search') {
      final list = fixture.raw['lrclibSearch'];
      if (list is List) return _jsonResponse(list);
      return _jsonResponse(const []);
    }

    return http.Response('Not Found', 404);
  }

  @override
  Future<http.Response> post(
    Uri uri, {
    Map<String, String> headers = const {},
    Object? body,
    required Duration timeout,
  }) async {
    if (uri.host != 'u.y.qq.com') return http.Response('Not Found', 404);
    final decoded = body is String ? jsonDecode(body) : const {};
    if (decoded is! Map) return http.Response('{}', 400);
    final req = decoded['req'];
    final method = req is Map ? req['method'] as String? : null;

    if (method == 'DoSearchForQQMusicMobile') {
      final param = req is Map ? req['param'] : null;
      final kw = param is Map ? (param['query'] as String? ?? '').toLowerCase() : '';
      final byKw = fixture.raw['qqSongsByKeyword'];
      List<Object?> songs = const [];
      if (byKw is Map) {
        for (final entry in byKw.entries) {
          if (kw == entry.key.toString().toLowerCase()) {
            songs = (entry.value as List?)?.cast<Object?>() ?? const [];
            break;
          }
        }
      }
      if (songs.isEmpty) {
        final fallback = fixture.raw['qqSongs'];
        if (fallback is List) songs = fallback.cast<Object?>();
      }
      return _jsonResponse({
        'req': {
          'code': 0,
          'data': {'body': {'item_song': songs}},
        },
      });
    }

    if (method == 'GetPlayLyricInfo') {
      final param = req is Map ? req['param'] : null;
      final mid = param is Map ? (param['songMID'] as String? ?? '') : '';
      final lyricsMap = fixture.raw['qqLyrics'];
      if (lyricsMap is Map && lyricsMap[mid] is Map) {
        return _jsonResponse({
          'req': {'code': 0, 'data': lyricsMap[mid]},
        });
      }
      return _jsonResponse({'req': {'code': 0, 'data': const {}}});
    }

    return http.Response('Not Found', 404);
  }

  static http.Response _jsonResponse(Object payload) {
    return http.Response.bytes(utf8.encode(jsonEncode(payload)), 200);
  }
}

/// 评测汇总指标。
class _EvalSummary {
  _EvalSummary(this.label);

  final String label;
  var positiveTotal = 0;
  var negativeTotal = 0;
  var positiveHit = 0;
  var wrongMatch = 0;
  var falsePositive = 0;
  var translated = 0;
  var wordTimed = 0;
  var romaji = 0;
  var totalSecondaryLines = 0;
  var badSecondaryLines = 0;
  final List<String> issues = [];

  int get totalCases => positiveTotal + negativeTotal;
  double get hitRate => positiveTotal == 0 ? 0.0 : positiveHit / positiveTotal;
  double get misselectRate =>
      totalCases == 0 ? 0.0 : (wrongMatch + falsePositive) / totalCases;
  double get translationRate =>
      positiveTotal == 0 ? 0.0 : translated / positiveTotal;
  double get wordRate => positiveTotal == 0 ? 0.0 : wordTimed / positiveTotal;
  double get romajiRate => positiveTotal == 0 ? 0.0 : romaji / positiveTotal;
  double get badSecondaryRate => totalSecondaryLines == 0
      ? 0.0
      : badSecondaryLines / totalSecondaryLines;
}

/// 复刻 S1 逻辑（无清洗占位过滤、无跨源合并、无多步降级、无 QQ 音乐、无 `/api/get`），用于同集横向对比。
Future<ScoredLyricCandidate?> _runS1Baseline(_BenchFixture f) async {
  final q = LyricSearchQuery(
    title: f.title,
    artist: f.artist,
    fileName: f.fileName,
    durationSeconds: f.duration,
  );
  if (LyricVersionMatcher.isInstrumentalTrack(
    title: q.title,
    fileName: q.fileName,
  )) {
    return null;
  }

  final transport = _FixtureReplayTransport(f, disableLrclibGet: true);
  final candidates = <LyricCandidate>[];

  // S1 LRCLIB：仅 /api/search，无清洗。
  final lrcResp = await transport.get(
    Uri.parse(LyricLookupConfig.lrclibSearchEndpoint).replace(
      queryParameters: {
        'track_name': q.title,
        if (q.artist.trim().isNotEmpty) 'artist_name': q.artist.trim(),
      },
    ),
    timeout: LyricLookupConfig.requestTimeout,
  );
  if (lrcResp.statusCode == 200) {
    final list = jsonDecode(utf8.decode(lrcResp.bodyBytes));
    if (list is List) {
      for (final item in list) {
        if (item is! Map) continue;
        final synced = (item['syncedLyrics'] as String? ?? '').trim();
        if (synced.isEmpty) continue;
        candidates.add(
          LyricCandidate(
            source: LyricSource.lrclib,
            sourceId: '${item['id'] ?? 0}',
            title: (item['trackName'] as String? ?? '').trim(),
            artist: (item['artistName'] as String? ?? '').trim(),
            album: (item['albumName'] as String? ?? '').trim(),
            durationSeconds: (item['duration'] as num?)?.toDouble(),
            lrcContent: synced,
          ),
        );
      }
    }
  }

  // S1 网易云：仅一次主关键词搜索，无清洗（纯音乐占位会被当成歌词）且无罗马音。
  final ncmResp = await transport.get(
    Uri.parse(LyricLookupConfig.neteaseSearchEndpoint).replace(
      queryParameters: {'s': q.keyword, 'type': '1', 'limit': '8', 'offset': '0'},
    ),
    timeout: LyricLookupConfig.requestTimeout,
  );
  if (ncmResp.statusCode == 200) {
    final decoded = jsonDecode(utf8.decode(ncmResp.bodyBytes));
    final result = decoded is Map ? decoded['result'] : null;
    final songs = result is Map ? result['songs'] as List? : null;
    if (songs != null && songs.isNotEmpty) {
      Map? bestHit;
      var bestScore = LyricMatchThresholds.lowConfidence;
      for (final s in songs) {
        if (s is! Map) continue;
        final artists = ((s['artists'] as List?) ?? const [])
            .whereType<Map>()
            .map((a) => '${a['name'] ?? ''}')
            .join('/');
        final dur = (s['duration'] as num?)?.toDouble();
        final sc = LyricCandidateScorer.scoreMetadata(
          q,
          title: '${s['name'] ?? ''}',
          artist: artists,
          album: '${(s['album'] as Map?)?['name'] ?? ''}',
          durationSeconds: dur != null && dur > 0 ? dur / 1000.0 : null,
        );
        if (sc != null && sc > bestScore) {
          bestScore = sc;
          bestHit = s;
        }
      }
      if (bestHit != null) {
        final id = '${bestHit['id']}';
        final artists = ((bestHit['artists'] as List?) ?? const [])
            .whereType<Map>()
            .map((a) => '${a['name'] ?? ''}')
            .join('/');
        final dur = (bestHit['duration'] as num?)?.toDouble();
        final durSec = dur != null && dur > 0 ? dur / 1000.0 : null;
        final lr = await transport.get(
          Uri.parse(LyricLookupConfig.neteaseLyricEndpoint).replace(
            queryParameters: {'id': id, 'lv': '1', 'tv': '1'},
          ),
          timeout: LyricLookupConfig.requestTimeout,
        );
        if (lr.statusCode == 200) {
          final lj = jsonDecode(utf8.decode(lr.bodyBytes)) as Map;
          final main = (lj['lrc'] as Map?)?['lyric'] as String? ?? '';
          final trans = (lj['tlyric'] as Map?)?['lyric'] as String? ?? '';
          if (main.trim().isNotEmpty) {
            final hasT = trans.trim().isNotEmpty;
            candidates.add(
              LyricCandidate(
                source: LyricSource.netease,
                sourceId: id,
                title: '${bestHit['name'] ?? ''}',
                artist: artists,
                album: '${(bestHit['album'] as Map?)?['name'] ?? ''}',
                durationSeconds: durSec,
                lrcContent: hasT ? '$main\n$trans' : main,
                hasTranslation: hasT,
              ),
            );
          }
        }
        final ar = await transport.get(
          Uri.parse('${LyricLookupConfig.amllNcmLyricMirrors.first}$id.ttml'),
          timeout: LyricLookupConfig.requestTimeout,
        );
        if (ar.statusCode == 200) {
          final conv = TtmlLyricConverter.convert(utf8.decode(ar.bodyBytes));
          if (conv.lrc.trim().isNotEmpty) {
            candidates.add(
              LyricCandidate(
                source: LyricSource.amll,
                sourceId: id,
                title: '${bestHit['name'] ?? ''}',
                artist: artists,
                album: '${(bestHit['album'] as Map?)?['name'] ?? ''}',
                durationSeconds: durSec,
                lrcContent: conv.lrc,
                hasTranslation: conv.hasTranslation,
                hasWordTiming: conv.hasWordTiming,
              ),
            );
          }
        }
      }
    }
  }

  // S1 打分：不含 Cleaner 占位零分拦截与时间轴校验。
  ScoredLyricCandidate? best;
  for (final c in candidates) {
    final meta = LyricCandidateScorer.scoreMetadata(
      q,
      title: c.title,
      artist: c.artist,
      album: c.album,
      durationSeconds: c.durationSeconds,
    );
    if (meta == null || c.lrcContent.trim().isEmpty) continue;
    var sc = meta + 0.08;
    if (c.hasTranslation) sc += 0.05;
    if (c.hasWordTiming) sc += 0.04;
    if (sc < LyricMatchThresholds.lowConfidence) continue;
    if (best == null || sc > best.score) {
      best = ScoredLyricCandidate(c, sc);
    }
  }
  return best;
}

/// 运行当前 S2 完整并行竞速引擎。
Future<ScoredLyricCandidate?> _runS2Engine(
  _BenchFixture f, {
  required bool enableQq,
}) async {
  final q = LyricSearchQuery(
    title: f.title,
    artist: f.artist,
    fileName: f.fileName,
    durationSeconds: f.duration,
  );
  if (LyricVersionMatcher.isInstrumentalTrack(
    title: q.title,
    fileName: q.fileName,
  )) {
    return null;
  }

  final transport = _FixtureReplayTransport(f);
  final sources = <LyricCandidateSource>[
    NeteaseAmllCandidateSource(
      netease: NeteaseLyricProvider(transport),
      amll: AmllLyricProvider(
        transport,
        hedgeDelay: const Duration(milliseconds: 5),
      ),
    ),
    if (enableQq) QqMusicCandidateSource(QqMusicLyricProvider(transport)),
    LrclibCandidateSource(LrclibLyricProvider(transport)),
  ];
  const engine = LyricRaceEngine(
    firstPaintGrace: Duration(milliseconds: 2),
    lowConfidencePaintAfter: Duration(milliseconds: 10),
    deadline: Duration(milliseconds: 500),
  );
  final settled = await engine.start(q, sources).settled;
  return settled.best;
}

bool _isCorrectMatch(_BenchFixture f, LyricCandidate c) {
  if (f.expectedTitleKeyword.isNotEmpty) {
    final candTitleKey = WorkMatcherScoring.normalizeKey(c.title);
    final expTitleKey = WorkMatcherScoring.normalizeKey(f.expectedTitleKeyword);
    if (!candTitleKey.contains(expTitleKey)) return false;
  }
  if (f.expectedArtistKeyword.isNotEmpty) {
    final candArtistKey = WorkMatcherScoring.normalizeKey(c.artist);
    final expArtistKey = WorkMatcherScoring.normalizeKey(f.expectedArtistKeyword);
    if (!candArtistKey.contains(expArtistKey)) return false;
  }
  // 检查版本标签未发生严重错配。
  final qTags = LyricVersionMatcher.extractVersionTags(title: f.title);
  final cTags = LyricVersionMatcher.extractVersionTags(title: c.title);
  if (qTags.contains(TrackVersionTag.tvSize) !=
      cTags.contains(TrackVersionTag.tvSize)) {
    return false;
  }
  if (qTags.contains(TrackVersionTag.live) !=
      cTags.contains(TrackVersionTag.live)) {
    return false;
  }
  return true;
}

void _recordCase(
  _EvalSummary summary,
  _BenchFixture f,
  ScoredLyricCandidate? result,
) {
  if (!f.expectMatch) {
    summary.negativeTotal++;
    if (result != null) {
      summary.falsePositive++;
      summary.issues.add(
        '[误报] ${f.id}(${f.category}) ${f.title} -> ${result.candidate.source.name}:${result.candidate.title}',
      );
    }
    return;
  }

  summary.positiveTotal++;
  if (result == null) {
    summary.issues.add('[漏选] ${f.id}(${f.category}) ${f.title}');
    return;
  }
  final cand = result.candidate;
  if (!_isCorrectMatch(f, cand)) {
    summary.wrongMatch++;
    summary.issues.add(
      '[误选] ${f.id}(${f.category}) ${f.title} -> ${cand.source.name}:${cand.title} / ${cand.artist}',
    );
    return;
  }

  summary.positiveHit++;
  if (cand.hasTranslation) summary.translated++;
  if (cand.hasWordTiming) summary.wordTimed++;
  if (cand.hasRomaji) summary.romaji++;

  // 检查译文质量（空串 / `//` / 原文译文同串 / 原文译文倒挂）。
  final doc = LrcParser.parseText(cand.lrcContent);
  final kana = RegExp(r'[\u3040-\u309F\u30A0-\u30FF]');
  final han = RegExp(r'[\u4E00-\u9FFF]');
  for (final line in doc.lines) {
    for (final sec in line.secondaryLines) {
      if (sec.startsWith('bg:')) continue;
      summary.totalSecondaryLines++;
      final trimmed = sec.trim();
      final isNoise = trimmed.isEmpty || trimmed == '//';
      final isSame = trimmed.toLowerCase() == line.primaryText.trim().toLowerCase();
      final isInverted =
          kana.hasMatch(trimmed) &&
          !kana.hasMatch(line.primaryText) &&
          han.hasMatch(line.primaryText);
      if (isNoise || isSame || isInverted) {
        summary.badSecondaryLines++;
      }
    }
  }
}

void _printSummary(_EvalSummary s) {
  String pct(double v) => '${(v * 100).toStringAsFixed(1)}%';
  stdout.writeln(
    '${s.label.padRight(16)} | '
    '命中率 ${pct(s.hitRate).padLeft(5)} (${s.positiveHit}/${s.positiveTotal}) | '
    '误选率 ${pct(s.misselectRate).padLeft(5)} (误选${s.wrongMatch}+误报${s.falsePositive}/${s.totalCases}) | '
    '译文 ${pct(s.translationRate).padLeft(5)} (${s.translated}/${s.positiveTotal}) | '
    '罗马音 ${pct(s.romajiRate).padLeft(5)} | '
    '逐字 ${pct(s.wordRate).padLeft(5)} | '
    '异常译文行 ${pct(s.badSecondaryRate)} (${s.badSecondaryLines}/${s.totalSecondaryLines})',
  );
  if (s.issues.isNotEmpty) {
    for (final issue in s.issues.take(10)) {
      stdout.writeln('  $issue');
    }
    if (s.issues.length > 10) {
      stdout.writeln('  ...其余 ${s.issues.length - 10} 条已省略');
    }
  }
}

Future<void> main(List<String> args) async {
  final fixturePath = args.isNotEmpty
      ? args.first
      : 'tool/fixtures/lyric_bench_fixtures.json';
  final file = File(fixturePath);
  if (!await file.exists()) {
    stderr.writeln('未找到离线评测 fixtures 文件：$fixturePath');
    exitCode = 2;
    return;
  }

  final rawList = jsonDecode(await file.readAsString());
  if (rawList is! List) {
    stderr.writeln('fixtures 格式错误：根节点必须为 JSON 数组');
    exitCode = 2;
    return;
  }
  final fixtures = [
    for (final item in rawList)
      if (item is Map)
        _BenchFixture.fromMap(item.cast<String, Object?>()),
  ];

  final s1 = _EvalSummary('S1 基线');
  final s2Default = _EvalSummary('S2 默认源');
  final s2WithQq = _EvalSummary('S2 含QQ源');

  for (final f in fixtures) {
    _recordCase(s1, f, await _runS1Baseline(f));
    _recordCase(s2Default, f, await _runS2Engine(f, enableQq: false));
    _recordCase(s2WithQq, f, await _runS2Engine(f, enableQq: true));
  }

  stdout.writeln(
    '=== Konata 歌词引擎离线回放评测（共 ${fixtures.length} 首：正样本 ${s2Default.positiveTotal} / 负样本与伴奏 ${s2Default.negativeTotal}）===',
  );
  _printSummary(s1);
  _printSummary(s2Default);
  _printSummary(s2WithQq);
}
