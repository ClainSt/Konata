import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:konata/application/playback/audio_playback_notifier.dart';
import 'package:konata/application/playback/lyric_candidate_sources.dart';
import 'package:konata/application/playback/lyric_race_engine.dart';
import 'package:konata/application/playback/lyrics_resolver.dart';
import 'package:konata/application/playback/unified_playback_engine.dart';
import 'package:konata/application/providers/library_providers.dart';
import 'package:konata/domain/lyrics/lyric_candidate.dart';
import 'package:konata/domain/lyrics/lyric_search_query.dart';
import 'package:konata/domain/models/media_variant.dart';
import 'package:konata/domain/models/work.dart';
import 'package:konata/domain/playback/cue_and_lrc_parser.dart';
import 'package:konata/domain/playback/playback_probe_stats.dart';
import 'package:konata/domain/playback/track_preferences.dart';
import 'package:konata/infrastructure/database/drift_library_repository.dart';
import 'package:konata/infrastructure/database/konata_database.dart';
import 'package:konata/infrastructure/lyrics/lyric_http_transport.dart';
import 'package:konata/infrastructure/lyrics/netease_lyric_provider.dart';
import 'package:konata/infrastructure/lyrics/qqmusic_lyric_provider.dart';
import 'package:konata/infrastructure/lyrics/qrc_decryptor.dart';
import 'package:konata/infrastructure/players/libmpv_ffi.dart';
import 'package:konata/infrastructure/storage/storage_root_provider.dart';

class _DelayedCandidateSource implements LyricCandidateSource {
  _DelayedCandidateSource(this.label, this._items);

  @override
  final String label;
  final List<({Duration delay, LyricCandidate candidate})> _items;

  @override
  Stream<LyricCandidate> candidates(LyricSearchQuery query) async* {
    for (final item in _items) {
      if (item.delay > Duration.zero) {
        await Future<void>.delayed(item.delay);
      }
      yield item.candidate;
    }
  }
}

class _GateCandidateSource implements LyricCandidateSource {
  _GateCandidateSource(this.label, this._gate, this._candidate);

  @override
  final String label;
  final Future<void> _gate;
  final LyricCandidate _candidate;

  @override
  Stream<LyricCandidate> candidates(LyricSearchQuery query) async* {
    await _gate;
    yield _candidate;
  }
}

class _S3FakeAudioClient implements LibMpvClient {
  final StreamController<MpvClientEvent> _events =
      StreamController<MpvClientEvent>.broadcast();
  final Map<String, String> _stringProps = {};
  final Map<String, double> _doubleProps = {};
  bool _disposed = false;
  bool _initialized = false;

  void emitTimePos(double seconds) {
    _doubleProps['time-pos'] = seconds;
    _events.add(
      MpvPropertyChangeEvent(
        name: 'time-pos',
        replyUserdata: 101,
        format: MpvFormat.double_,
        doubleValue: seconds,
      ),
    );
  }

  @override
  int get handleAddress => 0;

  @override
  bool get isDisposed => _disposed;

  @override
  bool get isInitialized => _initialized && !_disposed;

  @override
  Stream<MpvClientEvent> get events => _events.stream;

  @override
  int initialize() {
    _initialized = true;
    return 0;
  }

  @override
  int command(List<String> args) {
    if (args.length >= 2 && args.first == 'loadfile') {
      scheduleMicrotask(() {
        if (!_disposed && !_events.isClosed) {
          _events.add(const MpvStartFileEvent(1));
          _events.add(const MpvFileLoadedEvent());
          _events.add(const MpvPlaybackRestartEvent());
          _events.add(
            const MpvPropertyChangeEvent(
              name: 'pause',
              replyUserdata: 103,
              format: MpvFormat.flag,
              boolValue: false,
            ),
          );
          _events.add(
            const MpvPropertyChangeEvent(
              name: 'duration',
              replyUserdata: 102,
              format: MpvFormat.double_,
              doubleValue: 213.0,
            ),
          );
        }
      });
    }
    return 0;
  }

  @override
  int commandAsync(int replyUserdata, List<String> args) => command(args);

  @override
  int setOptionString(String name, String value) {
    _stringProps[name] = value;
    return 0;
  }

  @override
  int setPropertyString(String name, String value) {
    _stringProps[name] = value;
    return 0;
  }

  @override
  int setPropertyFlag(String name, bool value) => 0;

  @override
  int setPropertyInt64(String name, int value) {
    _stringProps[name] = '$value';
    return 0;
  }

  @override
  int setPropertyDouble(String name, double value) {
    _doubleProps[name] = value;
    return 0;
  }

  @override
  String? getPropertyString(String name) => _stringProps[name];

  @override
  bool? getPropertyFlag(String name) => false;

  @override
  int? getPropertyInt64(String name) => null;

  @override
  double? getPropertyDouble(String name) => _doubleProps[name] ?? 0.0;

  @override
  int observeProperty(int replyUserdata, String name, int format) => 0;

  @override
  int requestLogMessages(String minLevel) => 0;

  @override
  String errorString(int errorCode) => 'ok($errorCode)';

  @override
  List<MpvSeekableRange> readDemuxerSeekableRanges() => const [];

  @override
  List<MpvAudioDevice> readAudioDeviceList() => const [];

  @override
  List<MpvTrackInfo> readTrackList() => const [];

  @override
  List<PlaybackChapter> readChapterList({double? totalDurationSeconds}) =>
      const [];

  @override
  Future<void> dispose() async {
    _disposed = true;
    await _events.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('S3 基础设施逐字提供者', () {
    test('NeteaseLyricProvider 请求 yv=1 并优先解析 YRC 逐字与 ytlrc/yromalrc', () async {
      Uri? capturedUri;
      final transport = ClientLyricTransport(
        MockClient((req) async {
          capturedUri = req.url;
          return http.Response.bytes(
            utf8.encode(
              jsonEncode({
                'yrc': {
                  'lyric':
                      '[10000,2000](10000,500,0)無敵(10600,600,0)の笑顔\n'
                      '[13000,2000](13000,600,0)秘密(13700,600,0)のエリア\n'
                      '[16000,2000](16000,500,0)星(16600,500,0)の瞳',
                },
                'ytlrc': {
                  'lyric': '[00:10.00]无敌的笑容\n[00:13.00]秘密的领域\n[00:16.00]星辰的眼眸',
                },
                'yromalrc': {
                  'lyric':
                      '[00:10.00]muteki no egao\n'
                      '[00:13.00]himitsu no eria\n'
                      '[00:16.00]hoshi no hitomi',
                },
                'lrc': {'lyric': '[00:10.00]無敵の笑顔'},
              }),
            ),
            200,
          );
        }),
      );

      final provider = NeteaseLyricProvider(transport);
      final candidate = await provider.fetchLyric(
        const NeteaseSongHit(
          id: '2034742057',
          title: 'アイドル',
          artist: 'YOASOBI',
          durationSeconds: 213,
        ),
      );

      expect(capturedUri?.queryParameters['yv'], equals('1'));
      expect(candidate, isNotNull);
      expect(candidate!.hasWordTiming, isTrue);
      expect(candidate.hasTranslation, isTrue);
      expect(candidate.hasRomaji, isTrue);

      final doc = LrcParser.parseText(candidate.lrcContent);
      expect(doc.lines, hasLength(3));
      expect(doc.lines.first.words, hasLength(2));
      expect(doc.lines.first.words.first.endSeconds, closeTo(10.5, 1e-3));
      expect(doc.lines.first.secondaryLines, equals(<String>['无敌的笑容']));
      expect(doc.lines.first.romajiText, equals('muteki no egao'));
    });

    test('NeteaseLyricProvider 在 ytlrc 遗漏单句译文时自动用完整 tlyric 补齐且不丢逐字时间', () async {
      final transport = ClientLyricTransport(
        MockClient((req) async {
          return http.Response.bytes(
            utf8.encode(
              jsonEncode({
                'yrc': {
                  'lyric':
                      '[41710,3200](41710,500,0)また次の(42550,800,0)問題と混ぜ合わさって\n'
                      '[44910,3350](44910,600,0)色褪せた(45920,900,0)ガール思い出せ\n'
                      '[48260,3060](48260,700,0)何を背負って(49690,900,0)何年になれど\n'
                      '[51320,2920](51320,600,0)タテジマな(52550,900,0)ラブは健在です',
                },
                // 模拟网易云服务端 ytlrc 漏掉 00:44.910 一句中文译文
                'ytlrc': {
                  'lyric':
                      '[00:41.710]混合着下一个问题\n'
                      '[00:48.260]究竟背负了什么  无论多少年\n'
                      '[00:51.320]竖条纹的爱仍然健在',
                },
                // 完整 tlyric 存在轻微时间差，包含被 ytlrc 漏掉的译文
                'tlyric': {
                  'lyric':
                      '[00:41.715]混合着下一个问题\n'
                      '[00:44.939]回忆起那个褪色了的女孩\n'
                      '[00:48.324]究竟背负了什么  无论多少年\n'
                      '[00:51.348]竖条纹的爱仍然健在',
                },
                'yromalrc': {
                  'lyric':
                      '[00:41.710]ma ta tsu gi no\n'
                      '[00:44.910]i ro a se ta gaa ru o mo i da se\n'
                      '[00:48.260]na ni wo se o tte\n'
                      '[00:51.320]ta te ji ma na ra bu',
                },
              }),
            ),
            200,
          );
        }),
      );

      final provider = NeteaseLyricProvider(transport);
      final candidate = await provider.fetchLyric(
        const NeteaseSongHit(
          id: '2084102053',
          title: '65535',
          artist: '中川翔子',
          durationSeconds: 193,
        ),
      );

      expect(candidate, isNotNull);
      expect(candidate!.hasWordTiming, isTrue);
      expect(candidate.hasTranslation, isTrue);
      expect(candidate.hasRomaji, isTrue);

      final doc = LrcParser.parseText(candidate.lrcContent);
      expect(doc.lines, hasLength(4));
      expect(doc.lines[0].secondaryLines, equals(<String>['混合着下一个问题']));
      expect(doc.lines[1].primaryText, equals('色褪せたガール思い出せ'));
      expect(doc.lines[1].secondaryLines, equals(<String>['回忆起那个褪色了的女孩']));
      expect(doc.lines[1].romajiText, equals('i ro a se ta gaa ru o mo i da se'));
      expect(doc.lines[1].words, hasLength(2));
      expect(doc.lines[2].secondaryLines, equals(<String>['究竟背负了什么  无论多少年']));
      expect(doc.lines[3].secondaryLines, equals(<String>['竖条纹的爱仍然健在']));
    });

    test('QqMusicLyricProvider 解密加密 QRC 逐字并合并 Base64 译文；无 QRC 自动回退 LRC', () async {
      const qrcXml =
          '<QrcInfos><LyricInfo><Lyric_1 LyricContent="'
          '[10000,2000]無敵(10000,500)の笑顔(10600,700)\n'
          '[13000,2000]秘密(13000,600)のエリア(13700,700)\n'
          '[16000,2000]星(16000,500)の瞳(16600,600)"/></LyricInfo></QrcInfos>';
      final encryptedHex = QrcDecryptor.encryptToHex(qrcXml);
      final transB64 = base64Encode(
        utf8.encode('[00:10.00]无敌的笑容\n[00:13.00]秘密的领域\n[00:16.00]星辰的眼眸'),
      );
      final plainLrcB64 = base64Encode(
        utf8.encode('[00:10.00]無敵の笑顔\n[00:13.00]秘密のエリア\n[00:16.00]星の瞳'),
      );

      Map<String, Object?>? lastParam;
      var returnQrc = true;
      final transport = ClientLyricTransport(
        MockClient((req) async {
          final body = jsonDecode(req.body) as Map;
          lastParam =
              ((body['req'] as Map)['param'] as Map).cast<String, Object?>();
          return http.Response.bytes(
            utf8.encode(
              jsonEncode({
                'req': {
                  'code': 0,
                  'data': returnQrc
                      ? {'qrc': 1, 'lyric': encryptedHex, 'trans': transB64}
                      : {'qrc': 0, 'lyric': plainLrcB64, 'trans': transB64},
                },
              }),
            ),
            200,
          );
        }),
      );

      final provider = QqMusicLyricProvider(transport);
      const hit = QqMusicSongHit(
        mid: '001MFU8s2twj4U',
        id: 403181955,
        title: 'アイドル',
        artist: 'YOASOBI',
        durationSeconds: 213,
      );

      final qrcCand = await provider.fetchLyric(hit);
      expect(lastParam?['qrc'], equals(1));
      expect(qrcCand, isNotNull);
      expect(qrcCand!.hasWordTiming, isTrue);
      expect(qrcCand.hasTranslation, isTrue);
      final qrcDoc = LrcParser.parseText(qrcCand.lrcContent);
      expect(qrcDoc.lines.first.words, hasLength(2));
      expect(qrcDoc.lines.first.words.first.endSeconds, closeTo(10.5, 1e-3));
      expect(qrcDoc.lines.first.secondaryLines, equals(<String>['无敌的笑容']));

      returnQrc = false;
      final lrcCand = await provider.fetchLyric(hit);
      expect(lrcCand, isNotNull);
      expect(lrcCand!.hasWordTiming, isFalse);
      expect(lrcCand.hasTranslation, isTrue);
    });
  });

  group('S3 渐进升级对齐守卫与行边界热替换', () {
    const lineLevelLrc =
        '[00:10.00]無敵の笑顔で荒らすメディア\n'
        '[00:14.00]知りたいその秘密ミステリアス\n'
        '[00:18.00]抜けてるとこさえ彼女のエリア';
    const alignedWordLrc =
        '[00:10.05]<00:10.050-00:11.000>無敵の笑顔で<00:11.100-00:12.500>荒らすメディア\n'
        '[00:10.05]以无敌笑容席卷媒体\n'
        '[00:14.05]<00:14.050-00:15.000>知りたいその秘密<00:15.100-00:16.500>ミステリアス\n'
        '[00:14.05]好想知道那神秘的秘密\n'
        '[00:18.05]<00:18.050-00:19.000>抜けてるとこさえ<00:19.100-00:20.500>彼女のエリア\n'
        '[00:18.05]就连迷糊之处也是她的领域';
    const shiftedWordLrc =
        '[00:12.50]<00:12.500-00:13.500>無敵の笑顔で<00:13.600-00:15.000>荒らすメディア\n'
        '[00:16.50]<00:16.500-00:17.500>知りたいその秘密<00:17.600-00:19.000>ミステリアス\n'
        '[00:20.50]<00:20.500-00:21.500>抜けてるとこさえ<00:21.600-00:23.000>彼女のエリア';

    test('shouldApplyProgressiveUpgrade 仅允许高对齐且时间差 <= 0.25s 的能力升级', () {
      const first = ScoredLyricCandidate(
        LyricCandidate(
          source: LyricSource.netease,
          sourceId: '1',
          title: 'アイドル',
          artist: 'YOASOBI',
          durationSeconds: 213,
          lrcContent: lineLevelLrc,
        ),
        0.95,
      );
      const alignedAmll = ScoredLyricCandidate(
        LyricCandidate(
          source: LyricSource.amll,
          sourceId: '1',
          title: 'アイドル',
          artist: 'YOASOBI',
          durationSeconds: 213,
          lrcContent: alignedWordLrc,
          hasWordTiming: true,
          hasTranslation: true,
        ),
        1.04,
      );
      const shiftedAmll = ScoredLyricCandidate(
        LyricCandidate(
          source: LyricSource.amll,
          sourceId: '1',
          title: 'アイドル',
          artist: 'YOASOBI',
          durationSeconds: 213,
          lrcContent: shiftedWordLrc,
          hasWordTiming: true,
        ),
        1.02,
      );

      expect(
        LyricsResolver.shouldApplyProgressiveUpgrade(first, alignedAmll),
        isTrue,
      );
      expect(
        LyricsResolver.shouldApplyProgressiveUpgrade(first, shiftedAmll),
        isFalse,
      );
    });

    test('LyricsResolver 首屏上屏后，延迟到达的对齐 AMLL 逐字歌词触发渐进升级回调', () async {
      final engine = UnifiedPlaybackEngine();
      final resolver = LyricsResolver(
        playbackEngine: engine,
        raceEngine: const LyricRaceEngine(
          firstPaintGrace: Duration(milliseconds: 20),
          lowConfidencePaintAfter: Duration(milliseconds: 80),
          deadline: Duration(milliseconds: 400),
        ),
        sourcesFactory: () async => [
          _DelayedCandidateSource('netease', [
            (
              delay: Duration.zero,
              candidate: const LyricCandidate(
                source: LyricSource.netease,
                sourceId: '1',
                title: 'アイドル',
                artist: 'YOASOBI',
                durationSeconds: 213,
                lrcContent: lineLevelLrc,
              ),
            ),
          ]),
          _DelayedCandidateSource('amll', [
            (
              delay: const Duration(milliseconds: 80),
              candidate: const LyricCandidate(
                source: LyricSource.amll,
                sourceId: '1',
                title: 'アイドル',
                artist: 'YOASOBI',
                durationSeconds: 213,
                lrcContent: alignedWordLrc,
                hasWordTiming: true,
                hasTranslation: true,
              ),
            ),
          ]),
        ],
      );

      final upgradedCompleter = Completer<LyricResolveOutcome>();
      final firstOutcome = await resolver.resolve(
        LyricResolveRequest(
          trackKey: 'local::idol.flac|1000|',
          query: LyricSearchQuery(
            title: 'アイドル',
            artist: 'YOASOBI',
            durationSeconds: 213,
          ),
        ),
        onProgressiveUpgrade: (u) {
          if (!upgradedCompleter.isCompleted) upgradedCompleter.complete(u);
        },
      );

      expect(firstOutcome.source, equals(LyricSource.netease));
      expect(firstOutcome.lrcDocument?.hasWordTiming, isFalse);

      final upgraded = await upgradedCompleter.future.timeout(
        const Duration(seconds: 2),
      );
      expect(upgraded.source, equals(LyricSource.amll));
      expect(upgraded.lrcDocument?.hasWordTiming, isTrue);
      expect(upgraded.lrcDocument?.lines.first.words, hasLength(2));
    });

    test('AudioPlaybackNotifier 在演唱句中途暂存渐进升级，跨越下一句边界时原子热替换', () async {
      SharedPreferences.setMockInitialValues({});
      final fakeClient = _S3FakeAudioClient();
      final engine = UnifiedPlaybackEngine();
      final lateAmllGate = Completer<void>();
      final tempRoot = await Directory.systemTemp.createTemp('konata_s3_upg_');
      final db = KonataDatabase(NativeDatabase.memory());
      final repo = DriftLibraryRepository(db);

      final resolver = LyricsResolver(
        playbackEngine: engine,
        raceEngine: const LyricRaceEngine(
          firstPaintGrace: Duration(milliseconds: 20),
          lowConfidencePaintAfter: Duration(milliseconds: 80),
          deadline: Duration(seconds: 2),
        ),
        sourcesFactory: () async => [
          _DelayedCandidateSource('netease', [
            (
              delay: Duration.zero,
              candidate: const LyricCandidate(
                source: LyricSource.netease,
                sourceId: '1',
                title: 'アイドル',
                artist: 'YOASOBI',
                durationSeconds: 213,
                lrcContent: lineLevelLrc,
              ),
            ),
          ]),
          _GateCandidateSource(
            'amll',
            lateAmllGate.future,
            const LyricCandidate(
              source: LyricSource.amll,
              sourceId: '1',
              title: 'アイドル',
              artist: 'YOASOBI',
              durationSeconds: 213,
              lrcContent: alignedWordLrc,
              hasWordTiming: true,
              hasTranslation: true,
            ),
          ),
        ],
      );

      final container = ProviderContainer(
        overrides: [
          libraryRepositoryProvider.overrideWithValue(repo),
          storageRootProvider.overrideWithValue(
            StorageRootService(overrideRoot: tempRoot),
          ),
          libraryItemsProvider.overrideWith((ref) async => const []),
          unifiedPlaybackEngineProvider.overrideWithValue(engine),
          lyricsResolverProvider.overrideWithValue(resolver),
          audioPlaybackProvider.overrideWith(
            () => AudioPlaybackNotifier(clientFactory: () => fakeClient),
          ),
        ],
      );

      const work = Work(id: 'w1', title: '推しの子');
      const variant = MediaVariant(
        id: 'v1',
        workId: 'w1',
        sourceId: 'none',
        relativePath: '01_アイドル.flac',
        fileName: '01_アイドル.flac',
        fileSize: 1000,
        assetKind: AssetKind.cdAlbum,
      );

      try {
        final notifier = container.read(audioPlaybackProvider.notifier);
        await notifier.playCdCollection(
          work: work,
          cdVariants: const [variant],
          initialVariant: variant,
          sourcesById: const {},
        );
        await Future<void>.delayed(const Duration(milliseconds: 120));

        // 首屏已采用网易云行级歌词，进入第 0 句中途播放态（10.5s）。
        fakeClient.emitTimePos(10.5);
        await Future<void>.delayed(const Duration(milliseconds: 30));
        var st = container.read(audioPlaybackProvider);
        expect(st.activeLyricSource, equals(LyricSource.netease));
        expect(st.activeLyricIndex, equals(0));
        expect(st.lrcDocument?.hasWordTiming, isFalse);

        // 放行 AMLL 逐字结果：因当前仍在唱第 0 句，不得中途打断替换。
        lateAmllGate.complete();
        await Future<void>.delayed(const Duration(milliseconds: 60));
        fakeClient.emitTimePos(11.2);
        await Future<void>.delayed(const Duration(milliseconds: 30));
        st = container.read(audioPlaybackProvider);
        expect(st.activeLyricIndex, equals(0));
        expect(st.activeLyricSource, equals(LyricSource.netease));
        expect(st.lrcDocument?.hasWordTiming, isFalse);

        // 跨越至第 1 句边界（14.1s）：原子热替换为 AMLL 逐字歌词！
        fakeClient.emitTimePos(14.1);
        await Future<void>.delayed(const Duration(milliseconds: 30));
        st = container.read(audioPlaybackProvider);
        expect(st.activeLyricIndex, equals(1));
        expect(st.activeLyricSource, equals(LyricSource.amll));
        expect(st.lrcDocument?.hasWordTiming, isTrue);
        expect(st.lrcDocument?.lines[1].words, hasLength(2));
      } finally {
        container.dispose();
        await db.close();
        if (await tempRoot.exists()) {
          await tempRoot.delete(recursive: true);
        }
      }
    });
  });
}
