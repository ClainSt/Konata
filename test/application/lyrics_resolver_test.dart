import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:konata/application/playback/lyric_candidate_sources.dart';
import 'package:konata/application/playback/lyric_race_engine.dart';
import 'package:konata/application/playback/lyrics_resolver.dart';
import 'package:konata/application/playback/unified_playback_engine.dart';
import 'package:konata/domain/lyrics/lyric_candidate.dart';
import 'package:konata/domain/lyrics/lyric_candidate_scorer.dart';
import 'package:konata/domain/lyrics/lyric_search_query.dart';
import 'package:konata/domain/lyrics/ttml_lyric_converter.dart';
import 'package:konata/domain/repositories/lyric_cache_repository.dart';
import 'package:konata/infrastructure/database/drift_lyric_cache_repository.dart';
import 'package:konata/infrastructure/database/konata_database.dart';
import 'package:konata/infrastructure/lyrics/amll_lyric_provider.dart';
import 'package:konata/infrastructure/lyrics/lrclib_lyric_provider.dart';
import 'package:konata/infrastructure/lyrics/lyric_http_transport.dart';
import 'package:konata/infrastructure/lyrics/netease_lyric_provider.dart';

/// 按固定延迟产出预设候选的测试来源。
class _FakeSource implements LyricCandidateSource {
  _FakeSource(this.label, this.items, {this.delay = Duration.zero});

  @override
  final String label;
  final List<LyricCandidate> items;
  final Duration delay;
  var calls = 0;

  @override
  Stream<LyricCandidate> candidates(LyricSearchQuery query) async* {
    calls++;
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    for (final c in items) {
      yield c;
    }
  }
}

LyricCandidate _candidate(
  LyricSource source,
  String id, {
  String title = 'アイドル',
  String artist = 'YOASOBI',
  double duration = 213,
  String lrc =
      '[00:01.00]無敵の笑顔で荒らすメディア\n'
      '[00:05.00]知りたいその秘密ミステリアス\n'
      '[00:09.00]抜けてるとこさえ彼女のエリア',
  bool translation = false,
  bool words = false,
  bool romaji = false,
  bool isSynced = true,
  String plainLyrics = '',
}) {
  return LyricCandidate(
    source: source,
    sourceId: id,
    title: title,
    artist: artist,
    durationSeconds: duration,
    lrcContent: lrc,
    hasTranslation: translation,
    hasWordTiming: words,
    hasRomaji: romaji,
    isSynced: isSynced,
    plainLyrics: plainLyrics,
  );
}

LyricResolveRequest _request({
  String trackKey = 'local::cd/01.flac|1024|',
  String title = '01. アイドル.flac',
  String fileName = '01. アイドル.flac',
  double? duration = 213,
}) {
  return LyricResolveRequest(
    trackKey: trackKey,
    query: LyricSearchQuery(
      title: title,
      artist: 'YOASOBI',
      fileName: fileName,
      durationSeconds: duration,
    ),
  );
}

void main() {
  group('LyricSearchQuery 与统一打分', () {
    test('清洗音轨序号与扩展名，歌曲身份键跨文件稳定', () {
      final a = LyricSearchQuery(title: '01. アイドル.flac', artist: 'YOASOBI', durationSeconds: 213.2);
      final b = LyricSearchQuery(title: 'アイドル', artist: 'ＹＯＡＳＯＢＩ', durationSeconds: 212.6);
      expect(a.title, equals('アイドル'));
      expect(a.keyword, equals('アイドル YOASOBI'));
      expect(a.songKey, isNotNull);
      expect(a.songKey, equals(b.songKey));
      expect(LyricSearchQuery(title: 'アイドル').songKey, isNull);
    });

    test('歌手参与打分：同名翻唱低于原唱，角色 (CV) 写法可命中声优', () {
      final query = LyricSearchQuery(title: 'God knows...', artist: '涼宮ハルヒ(CV.平野綾)', durationSeconds: 277);
      final original = LyricCandidateScorer.score(
        query,
        _candidate(LyricSource.netease, '1', title: 'God knows...', artist: '平野綾', duration: 277),
      )!;
      final cover = LyricCandidateScorer.score(
        query,
        _candidate(LyricSource.netease, '2', title: 'God knows...', artist: '某翻唱歌手', duration: 277),
      )!;
      expect(original, greaterThan(cover));
      expect(original, greaterThanOrEqualTo(LyricMatchThresholds.autoAccept));
    });

    test('曲名差异过大一票否决，能力加分让逐字/译文候选胜出', () {
      final query = LyricSearchQuery(title: 'アイドル', artist: 'YOASOBI', durationSeconds: 213);
      final wrong = LyricCandidateScorer.score(query, _candidate(LyricSource.lrclib, 'x', title: '夜に駆ける'))!;
      expect(wrong, lessThan(LyricMatchThresholds.lowConfidence));
      final plain = LyricCandidateScorer.score(query, _candidate(LyricSource.lrclib, 'p'))!;
      final rich = LyricCandidateScorer.score(
        query,
        _candidate(LyricSource.amll, 'r', translation: true, words: true),
      )!;
      expect(rich, greaterThanOrEqualTo(plain));
    });
  });

  group('TtmlLyricConverter', () {
    test('嵌套和声、词间空格、译文与罗马音处理', () {
      const ttml =
          '<tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata"><body><div>'
          '<p begin="00:10.000" end="00:13.000">'
          '<span begin="00:10.000" end="00:10.500">Hello</span> '
          '<span begin="00:10.600" end="00:11.000">world</span>'
          '<span ttm:role="x-bg"><span begin="00:10.200" end="00:10.800">(ah</span>'
          '<span begin="00:10.800" end="00:11.200">ha)</span></span>'
          '<span ttm:role="x-translation" xml:lang="zh-CN">你好世界</span>'
          '<span ttm:role="x-roman">harō</span>'
          '</p></div></body></tt>';
      final result = TtmlLyricConverter.convert(ttml);
      expect(result.hasWordTiming, isTrue);
      expect(result.hasTranslation, isTrue);
      final lines = result.lrc.trim().split('\n');
      expect(lines[0], equals('[00:10.00]<00:10.00>Hello <00:10.60>world'));
      expect(lines[1], equals('[00:10.00]你好世界'));
      expect(lines[2], equals('[00:10.00]bg:<00:10.20>(ah<00:10.80>ha)'));
      expect(result.lrc.contains('harō'), isFalse);
    });

    test('非法 XML 返回空结果', () {
      expect(TtmlLyricConverter.convert('<tt><p').lrc, isEmpty);
    });
  });

  group('AmllLyricProvider 镜像对冲', () {
    const hit = NeteaseSongHit(id: '42', title: 'アイドル', artist: 'YOASOBI', durationSeconds: 213);
    const ttml = '<tt><body><div><p begin="00:01.00"><span begin="00:01.00">無敵</span></p></div></body></tt>';

    test('主镜像无响应时由对冲镜像返回结果', () async {
      final hang = Completer<http.Response>();
      final transport = ClientLyricTransport(
        MockClient((req) {
          if (req.url.host == 'primary.test') return hang.future;
          return Future.value(http.Response.bytes(utf8.encode(ttml), 200));
        }),
      );
      final provider = AmllLyricProvider(
        transport,
        mirrors: const ['https://primary.test/', 'https://mirror.test/'],
        hedgeDelay: const Duration(milliseconds: 20),
      );
      final sw = Stopwatch()..start();
      final candidate = await provider.fetchByNeteaseHit(hit);
      expect(candidate, isNotNull);
      expect(candidate!.source, equals(LyricSource.amll));
      expect(candidate.hasWordTiming, isTrue);
      expect(sw.elapsedMilliseconds, lessThan(1000));
    });

    test('库中不存在（404）立即返回空，不等待其余镜像', () async {
      final transport = ClientLyricTransport(
        MockClient((req) async => http.Response('404: Not Found', 404)),
      );
      final provider = AmllLyricProvider(
        transport,
        mirrors: const ['https://primary.test/', 'https://mirror.test/'],
        hedgeDelay: const Duration(seconds: 5),
      );
      expect(await provider.fetchByNeteaseHit(hit), isNull);
    });
  });

  group('LyricRaceEngine 并行竞速', () {
    test('仅有低置信度候选时于软截止上屏，不等待慢速来源与总预算', () async {
      final weak = _FakeSource('weak', [_candidate(LyricSource.netease, 'w', artist: '别的歌手')]);
      final hanging = _FakeSource('hang', const [], delay: const Duration(seconds: 3));
      const engine = LyricRaceEngine(
        firstPaintGrace: Duration(milliseconds: 20),
        lowConfidencePaintAfter: Duration(milliseconds: 150),
        deadline: Duration(seconds: 2),
      );
      final query = LyricSearchQuery(title: 'アイドル', artist: 'YOASOBI', durationSeconds: 213);
      final sw = Stopwatch()..start();
      final session = engine.start(query, [weak, hanging]);
      final first = await session.firstPaint;
      expect(first, isNotNull);
      expect(first!.score, lessThan(LyricMatchThresholds.autoAccept));
      expect(first.score, greaterThanOrEqualTo(LyricMatchThresholds.lowConfidence));
      expect(sw.elapsedMilliseconds, lessThan(1000));
      session.cancel();
    });
    test('首个可自动采用候选经宽限期即上屏，不等待慢速来源；收束结果包含后到的更优候选', () async {
      final fast = _FakeSource('fast', [_candidate(LyricSource.netease, 'n', translation: true)]);
      final slow = _FakeSource(
        'slow',
        [_candidate(LyricSource.amll, 'a', translation: true, words: true)],
        delay: const Duration(milliseconds: 400),
      );
      const engine = LyricRaceEngine(
        firstPaintGrace: Duration(milliseconds: 30),
        lowConfidencePaintAfter: Duration(seconds: 2),
        deadline: Duration(seconds: 3),
      );
      final query = LyricSearchQuery(title: 'アイドル', artist: 'YOASOBI', durationSeconds: 213);
      final sw = Stopwatch()..start();
      final session = engine.start(query, [fast, slow]);
      final first = await session.firstPaint;
      expect(sw.elapsedMilliseconds, lessThan(300));
      expect(first?.candidate.source, equals(LyricSource.netease));
      final settled = await session.settled;
      expect(settled.best?.candidate.source, equals(LyricSource.amll));
      expect(settled.allSourcesFinished, isTrue);
    });

    test('预算截止或取消时不判定为未找到，且在途 HTTP 超时不会抛出未捕获异常', () async {
      final slowTimeoutTransport = ClientLyricTransport(
        MockClient((req) async {
          await Future<void>.delayed(const Duration(milliseconds: 120));
          throw TimeoutException('mock timeout after cancel');
        }),
      );
      const engine = LyricRaceEngine(
        firstPaintGrace: Duration(milliseconds: 10),
        lowConfidencePaintAfter: Duration(milliseconds: 30),
        deadline: Duration(milliseconds: 50),
      );
      final query = LyricSearchQuery(title: 'アイドル');
      final settled = await engine.start(query, [
        LrclibCandidateSource(LrclibLyricProvider(slowTimeoutTransport)),
      ]).settled;
      expect(settled.best, isNull);
      expect(settled.isConfirmedNotFound, isFalse);
      // 等待在途请求抛出超时异常，验证已被流守卫吞净且不触发未捕获异常。
      await Future<void>.delayed(const Duration(milliseconds: 160));
    });
  });

  group('LyricsResolver 缓存与短路', () {
    late KonataDatabase db;
    late LyricCacheRepository cache;
    late UnifiedPlaybackEngine engine;

    setUp(() {
      db = KonataDatabase(NativeDatabase.memory());
      cache = DriftLyricCacheRepository(db);
      engine = UnifiedPlaybackEngine();
    });

    tearDown(() async {
      await db.close();
    });

    LyricsResolver buildResolver(List<LyricCandidateSource> sources) {
      return LyricsResolver(
        playbackEngine: engine,
        cacheRepository: cache,
        sourcesFactory: () async => sources,
        raceEngine: const LyricRaceEngine(
          firstPaintGrace: Duration(milliseconds: 20),
          lowConfidencePaintAfter: Duration(milliseconds: 500),
          deadline: Duration(seconds: 2),
        ),
      );
    }

    test('伴奏轨零网络短路', () async {
      final source = _FakeSource('net', [_candidate(LyricSource.netease, 'n')]);
      final resolver = buildResolver([source]);
      final outcome = await resolver.resolve(
        _request(title: 'アイドル (Off Vocal)', fileName: '04_Idol_Instrumental.flac'),
      );
      expect(outcome.shortCircuitedInstrumental, isTrue);
      expect(source.calls, equals(0));
    });

    test('命中后写入缓存，二次解析零网络直出；同一首歌跨文件复用', () async {
      final source = _FakeSource('net', [_candidate(LyricSource.netease, 'n', translation: true)]);
      final resolver = buildResolver([source]);
      final first = await resolver.resolve(_request());
      expect(first.source, equals(LyricSource.netease));
      expect(first.fromCache, isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      var networkStarted = false;
      final second = await resolver.resolve(
        _request(),
        onNetworkLookupStarted: () => networkStarted = true,
      );
      expect(second.fromCache, isTrue);
      expect(second.lrcDocument?.lines, isNotEmpty);
      expect(networkStarted, isFalse);
      expect(source.calls, equals(1));

      final otherFile = await resolver.resolve(
        _request(trackKey: 'local::ost/05.flac|2048|'),
      );
      expect(otherFile.fromCache, isTrue);
      expect(source.calls, equals(1));
    });

    test('全部来源正常响应但无合格候选时写入负缓存，有效期内不再联网', () async {
      final source = _FakeSource('net', const []);
      final resolver = buildResolver([source]);
      final first = await resolver.resolve(_request());
      expect(first.lrcDocument, isNull);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final entry = await cache.findByTrackKey(_request().trackKey);
      expect(entry?.status, equals(LyricCacheStatus.notFound));

      final second = await resolver.resolve(_request());
      expect(second.fromCache, isTrue);
      expect(source.calls, equals(1));
    });

    test('网络异常不写负缓存', () async {
      final transport = ClientLyricTransport(
        MockClient((req) async => throw http.ClientException('offline')),
      );
      final resolver = buildResolver([
        LrclibCandidateSource(LrclibLyricProvider(transport)),
        NeteaseAmllCandidateSource(
          netease: NeteaseLyricProvider(transport),
          amll: AmllLyricProvider(transport),
        ),
      ]);
      final outcome = await resolver.resolve(_request());
      expect(outcome.lrcDocument, isNull);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(await cache.findByTrackKey(_request().trackKey), isNull);
    });

    test('LRCLIB 版本与时长消歧精确选中 TV Size', () async {
      final transport = ClientLyricTransport(
        MockClient((req) async {
          if (req.url.host != 'lrclib.net') return http.Response('[]', 200);
          return http.Response.bytes(
            utf8.encode(
              jsonEncode([
                {
                  'id': 1,
                  'trackName': 'Idol (Full Ver.)',
                  'artistName': 'YOASOBI',
                  'duration': 213.0,
                  'syncedLyrics':
                      '[00:01.00]Full version line\n[00:05.00]Second line\n[00:09.00]Third line',
                },
                {
                  'id': 2,
                  'trackName': 'Idol (TV Size)',
                  'artistName': 'YOASOBI',
                  'duration': 89.5,
                  'syncedLyrics':
                      '[00:01.00]TV size matched line\n[00:05.00]TV second line\n[00:09.00]TV third line',
                },
              ]),
            ),
            200,
          );
        }),
      );
      final resolver = buildResolver([
        LrclibCandidateSource(LrclibLyricProvider(transport)),
      ]);
      final outcome = await resolver.resolve(
        _request(title: 'Idol (TV Size)', fileName: '01_Idol_TV_Size.flac', duration: 90),
      );
      expect(outcome.source, equals(LyricSource.lrclib));
      expect(outcome.lrcDocument?.lines.first.primaryText, equals('TV size matched line'));
    });

    test('切歌取消后结果作废', () async {
      final slow = _FakeSource(
        'slow',
        [_candidate(LyricSource.netease, 'n')],
        delay: const Duration(milliseconds: 200),
      );
      final resolver = buildResolver([slow]);
      final pending = resolver.resolve(_request());
      await Future<void>.delayed(const Duration(milliseconds: 20));
      resolver.cancelPendingLookups();
      final outcome = await pending;
      expect(outcome.staleAborted, isTrue);
    });
  });
}
