import 'dart:async';
import 'dart:convert';

import 'package:engine_playback/engine_playback.dart';
import 'package:engine_scraping/engine_scraping.dart';
import 'package:feature_lyrics/feature_lyrics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:konata_storage/konata_storage.dart';

import 'support/lyrics_test_helpers.dart';

void main() {
  group('多源歌词适配器与传输端口适配', () {
    test('AMLL 镜像对冲竞速在主镜像超时后采纳备用镜像，明确 404 时立即短路', () async {
      final slowHits = <String>[];
      final transport = FakeLyricHttpTransport((
        method,
        uri,
        headers,
        body,
      ) async {
        slowHits.add(uri.toString());
        if (uri.host == 'mirror1.example') {
          await Future<void>.delayed(const Duration(milliseconds: 250));
          return FakeLyricHttpTransport.utf8Response(
            'not found',
            statusCode: 404,
          );
        }
        return FakeLyricHttpTransport.utf8Response(kSampleAmllTtml);
      });

      final amll = AmllLyricProvider(
        transport,
        mirrors: const ['https://mirror1.example/', 'https://mirror2.example/'],
        hedgeDelay: const Duration(milliseconds: 25),
      );
      final candidate = await amll.fetchByNeteaseHit(
        const NeteaseSongHit(id: '1001', title: '光の中へ', artist: '結束バンド'),
      );

      expect(candidate, isNotNull);
      expect(candidate!.source, LyricSource.amll);
      expect(candidate.hasWordTiming, isTrue);
      expect(
        slowHits.any((u) => u.contains('mirror2.example/1001.ttml')),
        isTrue,
      );

      // 明确 404 时直接返回空，不启动延迟后的下一镜像请求。
      final fast404Hits = <String>[];
      final fast404Transport = FakeLyricHttpTransport((
        method,
        uri,
        headers,
        body,
      ) {
        fast404Hits.add(uri.toString());
        return FakeLyricHttpTransport.utf8Response('', statusCode: 404);
      });
      final amll404 = AmllLyricProvider(
        fast404Transport,
        mirrors: const ['https://m1.example/', 'https://m2.example/'],
        hedgeDelay: const Duration(milliseconds: 40),
      );
      final miss = await amll404.fetchByNeteaseHit(
        const NeteaseSongHit(id: '9999', title: 'Missing'),
      );
      expect(miss, isNull);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(fast404Hits.length, 1);
    });

    test('LRCLIB 精确匹配未中时自动回退搜索接口并保留纯文本候选', () async {
      final uris = <Uri>[];
      final transport = FakeLyricHttpTransport((method, uri, headers, body) {
        uris.add(uri);
        if (uri.path.endsWith('/api/get')) {
          return FakeLyricHttpTransport.utf8Response('', statusCode: 404);
        }
        return FakeLyricHttpTransport.jsonResponse([
          {
            'id': 88,
            'trackName': '空の彼方',
            'artistName': 'Tester',
            'albumName': 'Album',
            'duration': 210.0,
            'syncedLyrics': '',
            'plainLyrics': '第一句纯文本\n第二句纯文本\n第三句纯文本\n第四句纯文本',
            'instrumental': false,
          },
          {
            'id': 89,
            'trackName': '空の彼方',
            'artistName': 'Tester',
            'albumName': 'Album',
            'duration': 211.0,
            'syncedLyrics': kSampleJapaneseLrc,
            'plainLyrics': '',
            'instrumental': false,
          },
        ]);
      });

      final provider = LrclibLyricProvider(transport);
      final results = await provider.fetchCandidates(
        LyricSearchQuery(
          title: '空の彼方',
          artist: 'Tester',
          durationSeconds: 210.0,
        ),
      );
      expect(uris.length, 2);
      expect(uris.first.path, '/api/get');
      expect(uris.last.path, '/api/search');
      expect(results.length, 2);
      expect(results.first.isSynced, isFalse);
      expect(results.last.isSynced, isTrue);
      expect(results.last.source, LyricSource.lrclib);
    });

    test('网易云适配器请求逐字与罗马音参数并以完整译文兜底填补逐字辅助轨缺句', () async {
      final transport = FakeLyricHttpTransport((method, uri, headers, body) {
        if (uri.path.contains('/search/')) {
          return FakeLyricHttpTransport.jsonResponse({
            'result': {
              'songs': [
                {
                  'id': 5566,
                  'name': '光の海',
                  'duration': 210000,
                  'artists': [
                    {'name': '主唱A'},
                  ],
                  'album': {'name': '专辑A'},
                },
              ],
            },
          });
        }
        expect(uri.queryParameters['yv'], '1');
        expect(uri.queryParameters['rv'], '1');
        return FakeLyricHttpTransport.jsonResponse({
          'yrc': {
            'lyric':
                '[10000,2000](10000,1000,0)光(11000,1000,0)の\n'
                '[15000,2000](15000,1000,0)風(16000,1000,0)が\n'
                '[20000,2000](20000,1000,0)空(21000,1000,0)へ\n'
                '[25000,2000](25000,1000,0)君(26000,1000,0)と\n',
          },
          'ytlrc': {'lyric': '[00:10.00]逐字译文一\n'},
          'tlyric': {
            'lyric':
                '[00:10.00]完整译文一\n'
                '[00:15.00]完整译文二\n'
                '[00:20.00]完整译文三\n'
                '[00:25.00]完整译文四\n',
          },
          'romalrc': {
            'lyric':
                '[00:10.00]hikari no\n'
                '[00:15.00]kaze ga\n'
                '[00:20.00]sora e\n'
                '[00:25.00]kimi to\n',
          },
        });
      });

      final provider = NeteaseLyricProvider(transport);
      final query = LyricSearchQuery(title: '光の海', artist: '主唱A');
      final hits = await provider.searchSongs(query);
      expect(hits.single.id, '5566');

      final candidate = await provider.fetchLyric(hits.single);
      expect(candidate, isNotNull);
      expect(candidate!.hasWordTiming, isTrue);
      expect(candidate.hasTranslation, isTrue);
      expect(candidate.hasRomaji, isTrue);
      expect(candidate.lrcContent, contains('逐字译文一'));
      expect(candidate.lrcContent, contains('完整译文二'));
      expect(candidate.lrcContent, contains('roma:kaze ga'));
    });

    test('QQ 音乐适配器解密逐字 QRC 密文并在无密文时无感回退明文 LRC', () async {
      const qrcXml = '''
<QrcInfos><LyricInfo><Lyric_1 LyricType="1" LyricContent="[10000,2000]光(10000,1000)の(11000,1000)海
[15000,2000]風(15000,1000)が(16000,1000)吹く
[20000,2000]空(20000,1000)の(21000,1000)彼方
[25000,2000]君(25000,1000)と(26000,1000)今" /></LyricInfo></QrcInfos>
''';
      final cipherHex = QrcDecryptor.encryptToHex(qrcXml);
      final transB64 = base64Encode(
        utf8.encode(
          '[00:10.00]光之海\n[00:15.00]清风吹拂\n[00:20.00]天空彼端\n[00:25.00]此刻与你',
        ),
      );
      final plainLrcB64 = base64Encode(utf8.encode(kSampleJapaneseLrc));

      final transport = FakeLyricHttpTransport((method, uri, headers, body) {
        final payload = jsonDecode(body as String) as Map<String, dynamic>;
        final req = payload['req'] as Map<String, dynamic>;
        final methodName = req['method'] as String;
        if (methodName == 'DoSearchForQQMusicMobile') {
          return FakeLyricHttpTransport.jsonResponse({
            'req': {
              'data': {
                'body': {
                  'item_song': [
                    {
                      'mid': 'mid_qrc',
                      'id': 11,
                      'name': '光の海',
                      'singer': [
                        {'name': 'Tester'},
                      ],
                      'album': {'name': 'OST'},
                      'interval': 210,
                    },
                    {
                      'mid': 'mid_plain',
                      'id': 12,
                      'name': '光の海',
                      'singer': [
                        {'name': 'Tester'},
                      ],
                      'album': {'name': 'OST'},
                      'interval': 210,
                    },
                  ],
                },
              },
            },
          });
        }
        final param = req['param'] as Map<String, dynamic>;
        if (param['songMID'] == 'mid_qrc') {
          return FakeLyricHttpTransport.jsonResponse({
            'req': {
              'data': {'qrc': 1, 'lyric': cipherHex, 'trans': transB64},
            },
          });
        }
        return FakeLyricHttpTransport.jsonResponse({
          'req': {
            'data': {'qrc': 0, 'lyric': plainLrcB64, 'trans': ''},
          },
        });
      });

      final provider = QqMusicLyricProvider(transport);
      final hits = await provider.searchSongs(
        LyricSearchQuery(title: '光の海', artist: 'Tester'),
      );
      expect(hits.length, 2);

      final qrcCand = await provider.fetchLyric(hits[0]);
      expect(qrcCand, isNotNull);
      expect(qrcCand!.hasWordTiming, isTrue);
      expect(qrcCand.hasTranslation, isTrue);
      expect(qrcCand.lrcContent, contains('光之海'));

      final plainCand = await provider.fetchLyric(hits[1]);
      expect(plainCand, isNotNull);
      expect(plainCand!.hasWordTiming, isFalse);
      expect(plainCand.lrcContent, contains('光の中へと手を伸ばして'));
    });

    test('KonataHttpClientLyricTransport 透传跨包端口请求并保留响应头', () async {
      final client = FakeKonataHttpClient((method, uri, headers, body) {
        expect(headers['User-Agent'], LyricLookupConfig.userAgent);
        return FakeLyricHttpTransport.utf8Response(
          '{"ok":true}',
          headers: const {'x-trace': 'ok'},
        );
      });
      final transport = KonataHttpClientLyricTransport(client);
      final resp = await transport.get(
        Uri.parse('https://lrclib.net/api/get?track_name=Test'),
        headers: const {'User-Agent': LyricLookupConfig.userAgent},
        timeout: const Duration(seconds: 2),
      );
      expect(resp.statusCode, 200);
      expect(resp.headers['x-trace'], 'ok');
      expect(client.requestedUris.single.host, 'lrclib.net');
    });
  });

  group('竞速收束引擎与分级预取和双库隔离持久化', () {
    test('LyricRaceEngine 首屏宽限提前上屏并在后续源到达时完成跨源借译文收敛', () async {
      const amllLrc = '''
[00:10.00]<00:10.000-00:11.000>光の中へ
[00:15.00]<00:15.000-00:16.000>風の歌が
[00:20.00]<00:20.000-00:21.000>空の彼方
[00:25.00]<00:25.000-00:26.000>君と描いた
''';
      final fastPlainSource = FakeLyricCandidateSource(
        label: 'LRCLIB',
        streamBuilder: (_) => Stream.fromIterable([
          const LyricCandidate(
            source: LyricSource.lrclib,
            sourceId: 'lrc-fast',
            title: '光の旅',
            artist: 'Tester',
            durationSeconds: 210.0,
            lrcContent: kSampleJapaneseLrc,
          ),
        ]),
      );
      final delayedAmllSource = FakeLyricCandidateSource(
        label: 'AMLL',
        streamBuilder: (_) => Stream.fromFuture(
          Future<LyricCandidate>.delayed(
            const Duration(milliseconds: 90),
            () => const LyricCandidate(
              source: LyricSource.amll,
              sourceId: 'amll-slow',
              title: '光の旅',
              artist: 'Tester',
              durationSeconds: 210.0,
              lrcContent: amllLrc,
              hasWordTiming: true,
            ),
          ),
        ),
      );
      final delayedNeteaseTrans = FakeLyricCandidateSource(
        label: 'Netease',
        streamBuilder: (_) => Stream.fromFuture(
          Future<LyricCandidate>.delayed(
            const Duration(milliseconds: 110),
            () => const LyricCandidate(
              source: LyricSource.netease,
              sourceId: 'ncm-trans',
              title: '光の旅',
              artist: 'Tester',
              durationSeconds: 210.0,
              lrcContent: '''
[00:10.05]光の中へ
[00:10.05]前往光芒之中
[00:15.05]風の歌が
[00:15.05]风的歌声响起
[00:20.05]空の彼方
[00:20.05]向着天空彼方
[00:25.05]君と描いた
[00:25.05]与你一同描绘
''',
              hasTranslation: true,
            ),
          ),
        ),
      );

      const engine = LyricRaceEngine(
        firstPaintGrace: Duration(milliseconds: 40),
        lowConfidencePaintAfter: Duration(milliseconds: 150),
        deadline: Duration(milliseconds: 500),
      );
      final query = LyricSearchQuery(
        title: '光の旅',
        artist: 'Tester',
        durationSeconds: 210.0,
      );
      final session = engine.start(query, [
        fastPlainSource,
        delayedAmllSource,
        delayedNeteaseTrans,
      ]);

      final first = await session.firstPaint;
      expect(first, isNotNull);
      expect(first!.candidate.source, LyricSource.lrclib);

      final settled = await session.settled;
      expect(settled.best, isNotNull);
      expect(settled.best!.candidate.source, LyricSource.amll);
      expect(settled.best!.candidate.hasWordTiming, isTrue);
      expect(settled.best!.candidate.hasTranslation, isTrue);
      expect(settled.best!.crossSourceAgreed, isTrue);
    });

    test('伴奏曲目零网络短路并保持缓存库未打开，内嵌歌词零网络返回', () async {
      final bundle = KonataDatabaseBundle.openInMemory();
      addTearDown(bundle.close);
      final cacheRepo = StorageLyricCacheRepository.fromBundle(bundle);
      var sourceCalls = 0;

      final resolver = LyricsResolver(
        cacheRepository: cacheRepo,
        sourcesFactory: () async {
          sourceCalls++;
          return [
            FakeLyricCandidateSource(
              label: 'Mock',
              streamBuilder: (_) => const Stream.empty(),
            ),
          ];
        },
      );

      final instOutcome = await resolver.resolve(
        LyricResolveRequest(
          trackKey: 'track-inst',
          query: LyricSearchQuery(
            title: '光の海 (Instrumental)',
            artist: 'Tester',
            durationSeconds: 200.0,
          ),
        ),
      );
      expect(instOutcome.shortCircuitedInstrumental, isTrue);
      expect(sourceCalls, 0);
      expect(bundle.isCacheOpen, isFalse);

      final embeddedOutcome = await resolver.resolve(
        LyricResolveRequest(
          trackKey: 'track-embedded',
          query: LyricSearchQuery(
            title: '内嵌单曲',
            artist: 'Tester',
            durationSeconds: 200.0,
          ),
          embeddedLrcText: kSampleBilingualLrc,
        ),
      );
      expect(embeddedOutcome.lrcDocument, isNotNull);
      expect(embeddedOutcome.fromCache, isTrue);
      expect(embeddedOutcome.source, LyricSource.local);
      expect(sourceCalls, 0);
    });

    test('未补全数字轨名不使用旧自动缓存或联网，手选与内嵌歌词仍优先', () async {
      final bundle = KonataDatabaseBundle.openInMemory();
      addTearDown(bundle.close);
      final repo = StorageLyricCacheRepository.fromBundle(bundle);
      var networkCalls = 0;
      final resolver = LyricsResolver(
        cacheRepository: repo,
        sourcesFactory: () async {
          networkCalls++;
          return [
            FakeLyricCandidateSource(
              label: 'Mock',
              streamBuilder: (_) => Stream.value(
                const LyricCandidate(
                  source: LyricSource.netease,
                  sourceId: 'unrelated',
                  title: '01',
                  durationSeconds: 45,
                  lrcContent: kSampleJapaneseLrc,
                ),
              ),
            ),
          ];
        },
      );
      await repo.save(
        LyricCacheEntry(
          trackKey: 'numeric',
          songKey: '01||15',
          status: LyricCacheStatus.found,
          source: LyricSource.netease,
          sourceId: 'unrelated',
          lrcContent: kSampleJapaneseLrc,
          score: 0.95,
          engineVersion: LyricLookupConfig.engineVersion,
          updatedAt: DateTime.now(),
        ),
      );
      final req = LyricResolveRequest(
        trackKey: 'numeric',
        query: LyricSearchQuery(title: '01', durationSeconds: 45),
      );
      expect((await resolver.resolve(req)).lrcDocument, isNull);
      expect(
        (await resolver.resolve(req, bypassCache: true)).lrcDocument,
        isNull,
      );
      expect(await resolver.prefetchUpcomingTracks([req]), 0);
      expect(networkCalls, 0);
      final embedded = await resolver.resolve(
        LyricResolveRequest(
          trackKey: 'embedded-numeric',
          query: LyricSearchQuery(title: 'Track 01'),
          embeddedLrcText: kSampleBilingualLrc,
        ),
      );
      expect(embedded.source, LyricSource.local);
      expect(embedded.lrcDocument, isNotNull);
      await resolver.applyManualCandidate(
        trackKey: req.trackKey,
        selected: const ScoredLyricCandidate(
          LyricCandidate(
            source: LyricSource.amll,
            sourceId: 'manual',
            title: '已确认曲目',
            lrcContent: kSampleBilingualLrc,
          ),
          1.0,
        ),
      );
      await resolver.saveTrackOffset(req.trackKey, offsetMillis: 350);
      final manual = await resolver.resolve(req);
      expect(manual.userEdited, isTrue);
      expect(manual.trackOffsetMillis, 350);
      expect(manual.lrcDocument, isNotNull);
      expect(networkCalls, 0);
    });
    test('跨文件 songKey 复用、真实失败不写负缓存与渐进升级回调', () async {
      final bundle = KonataDatabaseBundle.openInMemory();
      addTearDown(bundle.close);
      final cacheRepo = StorageLyricCacheRepository.fromBundle(bundle);
      var now = DateTime.utc(2026, 6, 1, 12, 0);
      var networkCalls = 0;
      var emitSlowWordUpgrade = true;

      final resolver = LyricsResolver(
        cacheRepository: cacheRepo,
        now: () => now,
        raceEngine: const LyricRaceEngine(
          firstPaintGrace: Duration(milliseconds: 30),
          lowConfidencePaintAfter: Duration(milliseconds: 120),
          deadline: Duration(milliseconds: 400),
        ),
        sourcesFactory: () async {
          networkCalls++;
          return [
            FakeLyricCandidateSource(
              label: 'Fast',
              streamBuilder: (_) => Stream.fromIterable([
                const LyricCandidate(
                  source: LyricSource.lrclib,
                  sourceId: 'lrc-1',
                  title: '同じ空',
                  artist: 'Singer',
                  durationSeconds: 210.0,
                  lrcContent: kSampleJapaneseLrc,
                ),
              ]),
            ),
            if (emitSlowWordUpgrade)
              FakeLyricCandidateSource(
                label: 'SlowAmll',
                streamBuilder: (_) => Stream.fromFuture(
                  Future<LyricCandidate>.delayed(
                    const Duration(milliseconds: 80),
                    () => const LyricCandidate(
                      source: LyricSource.amll,
                      sourceId: 'amll-1',
                      title: '同じ空',
                      artist: 'Singer',
                      durationSeconds: 210.0,
                      lrcContent: '''
[00:10.02]<00:10.020-00:11.000>光の中へと手を伸ばして
[00:15.02]<00:15.020-00:16.000>風の歌が今響いてる
[00:20.02]<00:20.020-00:21.000>空の彼方まで駆け出そう
[00:25.02]<00:25.020-00:26.000>君と描いた未来へ
''',
                      hasWordTiming: true,
                    ),
                  ),
                ),
              ),
          ];
        },
      );

      final upgradedCompleter = Completer<LyricResolveOutcome>();
      final firstOutcome = await resolver.resolve(
        LyricResolveRequest(
          trackKey: 'file-a|1024|',
          query: LyricSearchQuery(
            title: '同じ空',
            artist: 'Singer',
            durationSeconds: 210.0,
          ),
        ),
        onProgressiveUpgrade: (upgraded) {
          if (!upgradedCompleter.isCompleted) {
            upgradedCompleter.complete(upgraded);
          }
        },
      );
      expect(firstOutcome.source, LyricSource.lrclib);
      final upgraded = await upgradedCompleter.future.timeout(
        const Duration(seconds: 2),
      );
      expect(upgraded.source, LyricSource.amll);
      expect(upgraded.activeSpanLines, isNotEmpty);
      expect(networkCalls, 1);

      // 不同物理文件但同一歌曲 songKey，零网络直接复用缓存。
      emitSlowWordUpgrade = false;
      final reusedOutcome = await resolver.resolve(
        LyricResolveRequest(
          trackKey: 'file-b|2048|',
          query: LyricSearchQuery(
            title: '同じ空',
            artist: 'Singer',
            durationSeconds: 211.0,
          ),
        ),
      );
      expect(reusedOutcome.fromCache, isTrue);
      expect(reusedOutcome.source, LyricSource.amll);
      expect(networkCalls, 1);

      // 来源全抛出异常（网络错误）不应写入未找到负缓存。
      final errorResolver = LyricsResolver(
        cacheRepository: cacheRepo,
        now: () => now,
        raceEngine: const LyricRaceEngine(
          firstPaintGrace: Duration(milliseconds: 20),
          lowConfidencePaintAfter: Duration(milliseconds: 40),
          deadline: Duration(milliseconds: 120),
        ),
        sourcesFactory: () async => [
          FakeLyricCandidateSource(
            label: 'Broken',
            streamBuilder: (_) => Stream.error(Exception('socket timeout')),
          ),
        ],
      );
      final failRes = await errorResolver.resolve(
        LyricResolveRequest(
          trackKey: 'err-track',
          query: LyricSearchQuery(title: 'UnknownErr', durationSeconds: 180.0),
        ),
      );
      expect(failRes.lrcDocument, isNull);
      expect(await cacheRepo.findByTrackKey('err-track'), isNull);

      // 明确空结果（所有来源正常响应无候选）写入负缓存，7 天内不再请求，过期后恢复。
      var emptyCalls = 0;
      final emptyResolver = LyricsResolver(
        cacheRepository: cacheRepo,
        now: () => now,
        raceEngine: const LyricRaceEngine(
          firstPaintGrace: Duration(milliseconds: 20),
          lowConfidencePaintAfter: Duration(milliseconds: 40),
          deadline: Duration(milliseconds: 120),
        ),
        sourcesFactory: () async {
          emptyCalls++;
          return [
            FakeLyricCandidateSource(
              label: 'EmptyOk',
              streamBuilder: (_) => const Stream.empty(),
            ),
          ];
        },
      );
      await emptyResolver.resolve(
        LyricResolveRequest(
          trackKey: 'notfound-track',
          query: LyricSearchQuery(title: 'MissingSong', durationSeconds: 180.0),
        ),
      );
      await emptyResolver.resolve(
        LyricResolveRequest(
          trackKey: 'notfound-track',
          query: LyricSearchQuery(title: 'MissingSong', durationSeconds: 180.0),
        ),
      );
      expect(emptyCalls, 1);

      now = now.add(
        LyricLookupConfig.notFoundRetryAfter + const Duration(hours: 1),
      );
      await emptyResolver.resolve(
        LyricResolveRequest(
          trackKey: 'notfound-track',
          query: LyricSearchQuery(title: 'MissingSong', durationSeconds: 180.0),
        ),
      );
      expect(emptyCalls, 2);
    });

    test('切歌取消作废、Bangumi 弱标题补全、双库隔离持久与网络分级预取', () async {
      final bundle = KonataDatabaseBundle.openInMemory();
      addTearDown(bundle.close);
      final cacheRepo = StorageLyricCacheRepository.fromBundle(
        bundle,
        localDeviceId: 'dev_test',
      );
      final engine = UnifiedPlaybackEngine();
      addTearDown(() => engine.resetSession());

      // 1. 切歌取消使在途解析标记为 staleAborted。
      final stalledCompleter = Completer<LyricCandidate>();
      final cancelResolver = LyricsResolver(
        playbackEngine: engine,
        cacheRepository: cacheRepo,
        raceEngine: const LyricRaceEngine(
          firstPaintGrace: Duration(milliseconds: 20),
          lowConfidencePaintAfter: Duration(milliseconds: 100),
          deadline: Duration(seconds: 2),
        ),
        sourcesFactory: () async => [
          FakeLyricCandidateSource(
            label: 'Stalled',
            streamBuilder: (_) => Stream.fromFuture(stalledCompleter.future),
          ),
        ],
      );
      final pendingFuture = cancelResolver.resolve(
        LyricResolveRequest(
          trackKey: 'track-cancel',
          query: LyricSearchQuery(
            title: 'StalledTrack',
            durationSeconds: 190.0,
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      cancelResolver.cancelPendingLookups();
      final abortedOutcome = await pendingFuture;
      expect(abortedOutcome.staleAborted, isTrue);

      // 2. Bangumi Track 01 补全真实原名后再触发检索，并测试网络分级预取 (Wi-Fi=2, Metered=1)。
      var metered = false;
      final fetchedQueries = <String>[];
      final prefetchResolver = LyricsResolver(
        cacheRepository: cacheRepo,
        isMeteredNetwork: () async => metered,
        bangumiMusicTracksLoader: (subjectId) async => const [
          BangumiMusicTrack(
            subjectId: 123,
            subjectTitle: '結束バンド',
            trackNumber: 1,
            title: '青春コンプレックス',
            titleCn: '青春情结',
          ),
        ],
        raceEngine: const LyricRaceEngine(
          firstPaintGrace: Duration(milliseconds: 20),
          lowConfidencePaintAfter: Duration(milliseconds: 80),
          deadline: Duration(milliseconds: 300),
        ),
        sourcesFactory: () async => [
          FakeLyricCandidateSource(
            label: 'MockCatalog',
            streamBuilder: (q) {
              fetchedQueries.add(q.title);
              return Stream.fromIterable([
                LyricCandidate(
                  source: LyricSource.netease,
                  sourceId: 'id-${q.title}',
                  title: q.title,
                  artist: q.artist,
                  durationSeconds: q.durationSeconds,
                  lrcContent: kSampleJapaneseLrc,
                ),
              ]);
            },
          ),
        ],
      );

      final track01Outcome = await prefetchResolver.resolve(
        LyricResolveRequest(
          trackKey: 'track-bgm-01',
          albumKey: 'album-kessoku',
          bangumiSubjectId: 123,
          trackNumber: 1,
          query: LyricSearchQuery(
            title: 'Track 01',
            album: '結束バンド',
            durationSeconds: 203.0,
          ),
        ),
      );
      expect(track01Outcome.lrcDocument, isNotNull);
      expect(fetchedQueries.single, '青春コンプレックス');

      // Wi-Fi 预取最多 2 首（第三首跳过）。
      final wifiQueue = [
        LyricResolveRequest(
          trackKey: 'q-1',
          query: LyricSearchQuery(title: 'Q1', durationSeconds: 180.0),
        ),
        LyricResolveRequest(
          trackKey: 'q-2',
          query: LyricSearchQuery(title: 'Q2', durationSeconds: 185.0),
        ),
        LyricResolveRequest(
          trackKey: 'q-3',
          query: LyricSearchQuery(title: 'Q3', durationSeconds: 190.0),
        ),
      ];
      expect(await prefetchResolver.prefetchUpcomingTracks(wifiQueue), 2);
      expect(fetchedQueries, containsAll(['Q1', 'Q2']));
      expect(fetchedQueries, isNot(contains('Q3')));

      // 移动计量网络下最多预取 1 首。
      metered = true;
      final meteredQueue = [
        LyricResolveRequest(
          trackKey: 'q-m1',
          query: LyricSearchQuery(title: 'QM1', durationSeconds: 195.0),
        ),
        LyricResolveRequest(
          trackKey: 'q-m2',
          query: LyricSearchQuery(title: 'QM2', durationSeconds: 198.0),
        ),
      ];
      expect(await prefetchResolver.prefetchUpcomingTracks(meteredQueue), 1);
      expect(fetchedQueries, contains('QM1'));
      expect(fetchedQueries, isNot(contains('QM2')));

      // 3. 手选歌词与单曲/专辑偏移落盘至 user_state.db，重置 cache.db 后丝毫不受损。
      await prefetchResolver.applyManualCandidate(
        trackKey: 'track-bgm-01',
        selected: const ScoredLyricCandidate(
          LyricCandidate(
            source: LyricSource.amll,
            sourceId: 'manual-99',
            title: '青春コンプレックス',
            lrcContent: kSampleBilingualLrc,
          ),
          1.12,
        ),
      );
      await prefetchResolver.saveTrackOffset('track-bgm-01', offsetMillis: 350);
      await prefetchResolver.saveAlbumOffset('album-kessoku', -200);

      expect(bundle.isCacheOpen, isTrue);
      await bundle.resetCacheDatabase();
      expect(bundle.isCacheOpen, isFalse);

      // 重置 cache.db 后查询手选曲目零网络、零重启打开 cache.db 且单曲与专辑偏移全部健在！
      final callsBeforeLockedRead = fetchedQueries.length;
      final afterReset = await prefetchResolver.resolve(
        LyricResolveRequest(
          trackKey: 'track-bgm-01',
          albumKey: 'album-kessoku',
          query: LyricSearchQuery(title: 'Track 01', durationSeconds: 203.0),
        ),
      );
      expect(afterReset.userEdited, isTrue);
      expect(afterReset.fromCache, isTrue);
      expect(afterReset.trackOffsetMillis, 350);
      expect(afterReset.userOffsetLocked, isTrue);
      expect(
        afterReset.lrcDocument!.lines.first.secondaryLines.first,
        contains('向着光芒之中'),
      );
      expect(fetchedQueries.length, callsBeforeLockedRead);
      expect(bundle.isCacheOpen, isFalse);

      final persistedOffsets = await prefetchResolver.readPersistedOffsets(
        trackKey: 'track-bgm-01',
        albumKey: 'album-kessoku',
      );
      expect(persistedOffsets.trackOffsetMillis, 350);
      expect(persistedOffsets.albumOffsetMillis, -200);

      // 解除手选锁后，单曲偏移依旧保留。
      await prefetchResolver.unlockUserEdit('track-bgm-01');
      final offsetsAfterUnlock = await prefetchResolver.readPersistedOffsets(
        trackKey: 'track-bgm-01',
        albumKey: 'album-kessoku',
      );
      expect(offsetsAfterUnlock.trackOffsetMillis, 350);
      expect(offsetsAfterUnlock.userOffsetLocked, isTrue);
    });
  });
}
