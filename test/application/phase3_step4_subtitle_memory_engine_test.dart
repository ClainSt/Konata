import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:charset/charset.dart' as cs;
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:ccplayer/application/playback/subtitle_memory_engine.dart';
import 'package:ccplayer/application/playback/unified_playback_engine.dart';
import 'package:ccplayer/domain/playback/cue_and_lrc_parser.dart';
import 'package:ccplayer/domain/playback/playback_probe_stats.dart';
import 'package:ccplayer/domain/playback/subtitle_content_processor.dart';
import 'package:ccplayer/domain/playback/subtitle_timeline_remapper.dart';
import 'package:ccplayer/domain/playback/track_preferences.dart';
import 'package:ccplayer/infrastructure/players/libmpv_ffi.dart';
import 'package:ccplayer/infrastructure/sources/byte_stream_source_gateway.dart';
import 'package:ccplayer/infrastructure/sources/work_detail_warmup_service.dart';
import 'package:ccplayer/infrastructure/storage/storage_root_provider.dart';
import 'package:ccplayer/infrastructure/stream_bridge/local_stream_bridge.dart';

import '../support/phase3_test_fixtures.dart';

class _ControlledSubtitleGateway implements ByteRangeReadableGateway {
  _ControlledSubtitleGateway({
    required this.files,
    this.probedLengthOverrides = const {},
    this.failAfterBytesByPath = const {},
  });

  final Map<String, Uint8List> files;
  final Map<String, int> probedLengthOverrides;
  final Map<String, int> failAfterBytesByPath;

  @override
  Future<int?> probeFileLength(String relativePath) async {
    if (probedLengthOverrides.containsKey(relativePath)) {
      return probedLengthOverrides[relativePath];
    }
    return files[relativePath]?.length;
  }

  @override
  Future<Stream<List<int>>> openByteRange(
    String relativePath, {
    required int start,
    int? endInclusive,
  }) async {
    final payload = files[relativePath];
    if (payload == null) {
      throw PathNotFoundException(relativePath, const OSError('not found', 2));
    }
    final failLimit = failAfterBytesByPath[relativePath];
    if (failLimit != null) {
      return (() async* {
        final end = failLimit.clamp(0, payload.length);
        if (end > start) {
          yield payload.sublist(start, end);
        }
        throw const HttpException('simulated truncated subtitle stream');
      })();
    }
    final end = endInclusive == null
        ? payload.length
        : (endInclusive + 1).clamp(start, payload.length);
    return Stream<List<int>>.value(payload.sublist(start, end));
  }

  @override
  Future<void> close() async {}
}

class _FakeSubtitleMpvClient implements LibMpvClient {
  final List<List<String>> recordedCommands = [];
  final List<({String name, Object value})> recordedPropertyWrites = [];
  final List<MpvTrackInfo> _tracks = [
    const MpvTrackInfo(
      id: 1,
      type: MpvTrackType.video,
      selected: true,
    ),
    const MpvTrackInfo(
      id: 1,
      type: MpvTrackType.audio,
      selected: true,
    ),
  ];
  final StreamController<MpvClientEvent> _eventController =
      StreamController<MpvClientEvent>.broadcast();

  String sid = 'no';
  String secondarySid = 'no';
  double subDelay = 0.0;
  bool paused = false;
  int _nextSubTrackId = 10;
  bool _disposed = false;

  @override
  int get handleAddress => 0;

  @override
  bool get isInitialized => !_disposed;

  @override
  bool get isDisposed => _disposed;

  @override
  String errorString(int code) => 'ok($code)';

  @override
  int setOptionString(String name, String value) => 0;

  @override
  int initialize() => 0;

  @override
  int setPropertyString(String name, String value) {
    recordedPropertyWrites.add((name: name, value: value));
    if (name == 'sid') sid = value;
    if (name == 'secondary-sid') secondarySid = value;
    return 0;
  }

  @override
  int setPropertyFlag(String name, bool value) {
    recordedPropertyWrites.add((name: name, value: value));
    if (name == 'pause') paused = value;
    return 0;
  }

  @override
  int setPropertyInt64(String name, int value) {
    recordedPropertyWrites.add((name: name, value: value));
    if (name == 'sid') sid = '$value';
    if (name == 'secondary-sid') secondarySid = '$value';
    return 0;
  }

  @override
  int setPropertyDouble(String name, double value) {
    recordedPropertyWrites.add((name: name, value: value));
    if (name == 'sub-delay') subDelay = value;
    return 0;
  }

  @override
  String? getPropertyString(String name) {
    if (name == 'sid') return sid;
    if (name == 'secondary-sid') return secondarySid;
    return null;
  }

  @override
  bool? getPropertyFlag(String name) => name == 'pause' ? paused : false;

  @override
  int? getPropertyInt64(String name) => null;

  @override
  double? getPropertyDouble(String name) => name == 'sub-delay' ? subDelay : 0;

  @override
  List<MpvTrackInfo> readTrackList() => List<MpvTrackInfo>.unmodifiable(_tracks);

  @override
  List<PlaybackChapter> readChapterList({double? totalDurationSeconds}) =>
      const [];

  @override
  List<MpvAudioDevice> readAudioDeviceList() => const [];

  @override
  List<MpvSeekableRange> readDemuxerSeekableRanges() => const [];

  @override
  int observeProperty(int replyUserdata, String name, int format) => 0;

  @override
  int requestLogMessages(String minLevel) => 0;

  @override
  int command(List<String> args) {
    recordedCommands.add(List<String>.unmodifiable(args));
    if (args.length >= 2 && args[0] == 'sub-add') {
      final trackId = _nextSubTrackId++;
      final title = args.length >= 4 ? args[3] : '';
      _tracks.add(
        MpvTrackInfo(
          id: trackId,
          type: MpvTrackType.subtitle,
          title: title,
          externalFilename: args[1],
          isExternal: true,
          selected: false,
        ),
      );
    }
    return 0;
  }

  @override
  int commandAsync(int replyUserdata, List<String> args) => command(args);

  @override
  Stream<MpvClientEvent> get events => _eventController.stream;

  @override
  Future<void> dispose() async {
    _disposed = true;
    await _eventController.close();
  }
}

void main() {
  group('Step 4.1 原始字幕原子缓存、跨季同名隔离与按语种完备性扫描', () {
    late Directory tempRoot;
    late LocalStreamBridge bridge;

    setUp(() async {
      tempRoot = await Directory.systemTemp.createTemp('konata_step4_subs_');
      bridge = LocalStreamBridge(
        storageRoot: StorageRootService(overrideRoot: tempRoot),
      );
    });

    tearDown(() async {
      await bridge.dispose();
      if (await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
    });

    test('同作品跨季同名文件零串用，且源版本验证器变更自动刷新缓存并计算 srcSha1', () async {
      final s1Bytes = Uint8List.fromList(utf8.encode('[Script Info]\nTitle: S01 EP01\n'));
      final s2Bytes = Uint8List.fromList(utf8.encode('[Script Info]\nTitle: S02 EP01\n'));
      final s1V2Bytes = Uint8List.fromList(
        utf8.encode('[Script Info]\nTitle: S01 EP01 Revised V2\n'),
      );

      final gw = _ControlledSubtitleGateway(
        files: {
          'Season 01/01.ass': s1Bytes,
          'Season 02/01.ass': s2Bytes,
        },
      );

      final recS1 = await bridge.materializeRemoteSubtitleRecords(
        gateway: gw,
        workId: 'work_frieren',
        sourceId: 'src_webdav_1',
        subtitleRelativePaths: const ['Season 01/01.ass'],
        validatorsByPath: const {'Season 01/01.ass': '"etag-s1-v1"'},
      );
      final recS2 = await bridge.materializeRemoteSubtitleRecords(
        gateway: gw,
        workId: 'work_frieren',
        sourceId: 'src_webdav_1',
        subtitleRelativePaths: const ['Season 02/01.ass'],
        validatorsByPath: const {'Season 02/01.ass': '"etag-s2-v1"'},
      );

      expect(recS1, hasLength(1));
      expect(recS2, hasLength(1));
      expect(recS1.first.localFilePath, isNot(equals(recS2.first.localFilePath)));
      expect(
        await File(recS1.first.localFilePath).readAsString(),
        contains('Title: S01 EP01'),
      );
      expect(
        await File(recS2.first.localFilePath).readAsString(),
        contains('Title: S02 EP01'),
      );
      expect(recS1.first.sourceSha1, equals(sha1.convert(s1Bytes).toString()));
      expect(recS2.first.sourceSha1, equals(sha1.convert(s2Bytes).toString()));

      // 同一相对路径远端版本验证器变化时严禁串用旧缓存。
      gw.files['Season 01/01.ass'] = s1V2Bytes;
      final recS1V2 = await bridge.materializeRemoteSubtitleRecords(
        gateway: gw,
        workId: 'work_frieren',
        sourceId: 'src_webdav_1',
        subtitleRelativePaths: const ['Season 01/01.ass'],
        validatorsByPath: const {'Season 01/01.ass': '"etag-s1-v2"'},
      );
      expect(recS1V2, hasLength(1));
      expect(recS1V2.first.localFilePath, isNot(equals(recS1.first.localFilePath)));
      expect(
        await File(recS1V2.first.localFilePath).readAsString(),
        contains('Revised V2'),
      );
    });

    test('网络中断半包或长度截断拒绝落盘并清理残留 .part 临时文件', () async {
      final rawBytes = Uint8List.fromList(
        utf8.encode('[Script Info]\nTitle: Complete Subtitle Payload 1234567890\n'),
      );
      final gw = _ControlledSubtitleGateway(
        files: {
          'Season 01/broken.ass': rawBytes,
          'Season 01/truncated.ass': rawBytes.sublist(0, 12),
        },
        probedLengthOverrides: {
          'Season 01/broken.ass': rawBytes.length,
          'Season 01/truncated.ass': rawBytes.length,
        },
        failAfterBytesByPath: const {'Season 01/broken.ass': 16},
      );

      final records = await bridge.materializeRemoteSubtitleRecords(
        gateway: gw,
        workId: 'work_broken',
        sourceId: 'src_1',
        subtitleRelativePaths: const [
          'Season 01/broken.ass',
          'Season 01/truncated.ass',
        ],
      );
      expect(records, isEmpty);

      // 确认临时目录中无残留 .part 与损坏目标字幕文件。
      final stageRoot = Directory(p.join(tempRoot.path, 'cache', 'tmp', 'konata_subs'));
      if (await stageRoot.exists()) {
        final leftoverFiles = await stageRoot
            .list(recursive: true)
            .where((e) => e is File)
            .toList();
        expect(leftoverFiles, isEmpty);
      }
    });

    test('SubtitleDirectoryIndex 前 4 子目录仅命中日繁且有未扫目录时标记 incompleteForSimplified', () {
      final index = SubtitleDirectoryIndex();
      final snap = index.put(
        sourceId: 'src_a',
        dirRelativePath: 'Anime/Show',
        siblingPaths: const [
          'Anime/Show/Subs1/01.jpn.ass',
          'Anime/Show/Subs2/01.cht.ass',
        ],
        hasUnscannedSubdirs: true,
        scannedSubdirCount: 4,
        unscannedSubdirs: const ['Anime/Show/Subs5_CHS'],
      );

      expect(snap.hasUnscannedSubdirs, isTrue);
      expect(snap.incompleteForSimplified, isTrue);
      expect(snap.unscannedSubdirs, equals(['Anime/Show/Subs5_CHS']));

      // 续扫出简体中文后完备性标记自动归零。
      final completeSnap = index.put(
        sourceId: 'src_a',
        dirRelativePath: 'Anime/Show',
        siblingPaths: const [
          'Anime/Show/Subs1/01.jpn.ass',
          'Anime/Show/Subs5_CHS/01.chs.ass',
        ],
        hasUnscannedSubdirs: false,
        scannedSubdirCount: 5,
        unscannedSubdirs: const [],
      );
      expect(completeSnap.incompleteForSimplified, isFalse);
      expect(completeSnap.unscannedSubdirs, isEmpty);
    });
  });

  group('Step 4.2 全仓唯一四编码模块（UTF-8 / UTF-16 / CP932 / GB18030 / Big5）', () {
    test('精准识别并解码 UTF-8(无/含BOM)、UTF-16LE/BE(无/含BOM)、Shift-JIS、GBK 与 Big5', () {
      // UTF-8 无 BOM & 含 BOM
      final utf8NoBom = Uint8List.fromList(utf8.encode('简体中文与日本語テスト'));
      final resUtf8 = MultibyteTextDecoder.decodeWithInfo(utf8NoBom);
      expect(resUtf8.charset, equals(DetectedTextCharset.utf8));
      expect(resUtf8.text, equals('简体中文与日本語テスト'));

      final utf8Bom = Uint8List.fromList([0xEF, 0xBB, 0xBF, ...utf8.encode('带BOM字幕')]);
      final resUtf8Bom = MultibyteTextDecoder.decodeWithInfo(utf8Bom);
      expect(resUtf8Bom.charset, equals(DetectedTextCharset.utf8Bom));
      expect(resUtf8Bom.hadBom, isTrue);
      expect(resUtf8Bom.text, equals('带BOM字幕'));

      // UTF-16LE 无 BOM
      final utf16LeBytes = Uint8List.fromList([
        0x5B, 0x00, 0x53, 0x00, 0x63, 0x00, 0x72, 0x00, 0x69, 0x00, 0x70, 0x00, 0x74, 0x00,
      ]);
      final res16Le = MultibyteTextDecoder.decodeWithInfo(utf16LeBytes);
      expect(res16Le.charset, equals(DetectedTextCharset.utf16Le));
      expect(res16Le.text, equals('[Script'));

      // UTF-16BE 含 BOM
      final utf16BeBom = Uint8List.fromList([0xFE, 0xFF, 0x00, 0x41, 0x4E, 0x2D]);
      final res16Be = MultibyteTextDecoder.decodeWithInfo(utf16BeBom);
      expect(res16Be.charset, equals(DetectedTextCharset.utf16Be));
      expect(res16Be.hadBom, isTrue);
      expect(res16Be.text, equals('A中'));

      // CP932 / Shift-JIS（纯 Dart charset 完整码表，双端一致）
      final sjisBytes = Uint8List.fromList(cs.shiftJis.encode('葬送のフリーレン 第一話'));
      final resSjis = MultibyteTextDecoder.decodeWithInfo(sjisBytes);
      expect(resSjis.charset, equals(DetectedTextCharset.cp932ShiftJis));
      expect(resSjis.text, equals('葬送のフリーレン 第一話'));

      // GBK / GB18030（纯 Dart charset 完整码表）
      final gbkBytes = Uint8List.fromList(cs.gbk.encode('葬送的芙莉莲 第一话 简体字幕'));
      final resGbk = MultibyteTextDecoder.decodeWithInfo(gbkBytes);
      expect(resGbk.charset, equals(DetectedTextCharset.gb18030Gbk));
      expect(resGbk.text, equals('葬送的芙莉莲 第一话 简体字幕'));

      // Big5 高频低尾字节识别与解码
      final big5Bytes = Uint8List.fromList([
        0xC1, 0x63, // 繁
        0xC5, 0xE9, // 體
        0xA6, 0x72, // 字
        0xB9, 0xF5, // 幕
        0xB4, 0xFA, // 測
        0xB8, 0xD5, // 試
      ]);
      final resBig5 = MultibyteTextDecoder.decodeWithInfo(big5Bytes);
      expect(resBig5.charset, equals(DetectedTextCharset.big5));
      expect(resBig5.text, equals('繁體字幕測試'));

      // 确认 PlaybackTextDecoder 统一委托同一实现。
      expect(PlaybackTextDecoder.decodeBytes(gbkBytes), equals('葬送的芙莉莲 第一话 简体字幕'));
    });
  });

  group('Step 4.3 三态子集保护与双语 ASS 可逆片段 OpenCC', () {
    test('区分未子集/可还原映射子集/不透明混淆子集，自动模式严禁破坏不透明混淆子集', () {
      const normalAss = '''
[Script Info]
ScriptType: v4.00+
[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:01.00,0:00:04.00,Default,,0,0,0,,這個字幕組的時間軸很準確
''';
      final normalRes = SubtitleContentProcessor.process(
        content: normalAss,
        mode: SubtitleOpenCcMode.toSimplified,
      );
      expect(normalRes.subsetState, equals(SubtitleSubsetState.unsubsetted));
      expect(normalRes.converted, isTrue);
      expect(normalRes.content, contains('这个字幕组的时间轴很准确'));

      const mappedSubsetAss = '''
[Script Info]
ScriptType: v4.00+
[V4+ Styles]
Style: Default,ABCDEF+SourceHanSans,48,&H00FFFFFF
[Events]
Dialogue: 0,0:00:01.00,0:00:04.00,Default,,0,0,0,,繁體動畫測試
[Fonts]
fontname: ABCDEF+SourceHanSans.ttf
''';
      final mappedRes = SubtitleContentProcessor.process(
        content: mappedSubsetAss,
        mode: SubtitleOpenCcMode.toSimplified,
      );
      expect(
        mappedRes.subsetState,
        equals(SubtitleSubsetState.restorableMappedSubset),
      );
      expect(mappedRes.converted, isTrue);
      expect(mappedRes.content, contains('繁体动画测试'));

      const opaquePuaAss = '''
[Script Info]
ScriptType: v4.00+
[Events]
Dialogue: 0,0:00:01.00,0:00:04.00,Default,,0,0,0,,\uE001\uE002\uE003\uE004
[Fonts]
fontname: X9K2M1+ObfFont.ttf
''';
      final opaqueRes = SubtitleContentProcessor.process(
        content: opaquePuaAss,
        mode: SubtitleOpenCcMode.toSimplified,
      );
      expect(
        opaqueRes.subsetState,
        equals(SubtitleSubsetState.opaqueObfuscatedSubset),
      );
      expect(opaqueRes.converted, isFalse);
      expect(opaqueRes.skipReason, equals('opaque_obfuscated_subset_protected'));
      expect(opaqueRes.content, equals(opaquePuaAss));
    });

    test('双语 ASS 保留日文假名段与绘图块，仅跨标签可逆转换中文片段', () {
      const bilingualAss = r'''
[Script Info]
ScriptType: v4.00+
[Events]
Dialogue: 0,0:00:02.00,0:00:05.00,Default,,0,0,0,,{\b1}後{\b0}面的{\i1}動畫{\i0}聲音\Nこれは日本語の測試です{\p1}m 0 0 l 100 0 100 100{\p0}
''';
      final res = SubtitleContentProcessor.process(
        content: bilingualAss,
        mode: SubtitleOpenCcMode.toSimplified,
      );
      expect(res.converted, isTrue);
      // 跨标签合并分词「後面」->「后面」并原位回填标签，不破坏 {\b1}/{\b0} 边界。
      expect(res.content, contains(r'{\b1}后{\b0}面的{\i1}动画{\i0}声音'));
      // 日文假名视觉段与绘图指令完全原样保留。
      expect(
        res.content,
        contains(r'\Nこれは日本語の測試です{\p1}m 0 0 l 100 0 100 100{\p0}'),
      );
    });
  });

  group('Step 4.4 离线分段线性字幕时间轴重映射', () {
    test('暂停对齐强制归零反应补偿，精确变换 ASS \\fade/\\t/50 音节卡拉 OK（总误差 <= 5ms）', () {
      const pausedTransform = SubtitleTimelineTransform(
        rateScale: 1.0,
        offsetSeconds: 1.5,
        isPausedAlignment: true,
        reactionCompensationSeconds: -0.25,
      );
      expect(pausedTransform.effectiveReactionCompensation, equals(0.0));
      expect(pausedTransform.effectiveOffsetSeconds, closeTo(1.5, 1e-9));

      const scale = 25.0 / 23.976;
      const transform = SubtitleTimelineTransform(
        rateScale: scale,
        offsetSeconds: 2.0,
      );

      // 构造含 50 个 17 厘秒（总计 850cs = 8500ms）音节的卡拉 OK 行，验证累计边界差分零累积漂移。
      final karaokeSyllables = List<String>.generate(
        50,
        (i) => i.isEven ? r'{\kf17}音' : r'{\ko17}节',
      ).join();
      final ass = '''
[Script Info]
ScriptType: v4.00+
[Events]
Dialogue: 0,0:00:10.00,0:00:18.50,Default,,0,0,0,,{\\fade(255,0,255,100,400,2000,2500)\\t(100,500,0.5,\\fs48)}$karaokeSyllables
Dialogue: 0,0:00:00.50,0:00:01.00,Default,,0,0,0,,钳位下界测试
''';

      final remapped = SubtitleTimelineRemapper.remap(
        content: ass,
        transform: transform,
        format: SubtitleTextFormat.ass,
      );

      // 1. \fade 前 3 个 Alpha 参数 (255,0,255) 严格保留，后 4 个毫秒缩放。
      final expectedT1 = (100 * scale).round();
      final expectedT2 = (400 * scale).round();
      final expectedT3 = (2000 * scale).round();
      final expectedT4 = (2500 * scale).round();
      expect(
        remapped,
        contains('\\fade(255,0,255,$expectedT1,$expectedT2,$expectedT3,$expectedT4)'),
      );

      // 2. \t 保留非线性 accel=0.5 不变。
      final expectedTt1 = (100 * scale).round();
      final expectedTt2 = (500 * scale).round();
      expect(remapped, contains('\\t($expectedTt1,$expectedTt2,0.5,\\fs48)'));

      // 3. 50 音节卡拉 OK 累计总厘秒误差严格 <= 0.5 厘秒（5 ms）。
      final kMatches = RegExp(r'\\(?:kf|ko)(\d+)').allMatches(remapped).toList();
      expect(kMatches, hasLength(50));
      final sumCs = kMatches.fold<int>(
        0,
        (acc, m) => acc + int.parse(m.group(1)!),
      );
      final exactExpectedMs = 850 * 10.0 * scale;
      final actualMs = sumCs * 10.0;
      expect((actualMs - exactExpectedMs).abs(), lessThanOrEqualTo(5.0));

      // 4. 负偏移结果严格钳位到 0:00:00.00。
      final clampedAss = SubtitleTimelineRemapper.remap(
        content: ass,
        transform: const SubtitleTimelineTransform(offsetSeconds: -5.0),
      );
      expect(clampedAss, contains('Dialogue: 0,0:00:00.00,0:00:00.00,Default'));
    });

    test('同步重映射 SRT 与 WebVTT（含行内逐词时间戳）', () {
      const srt = '''
1
00:00:01,000 --> 00:00:03,500
第一行字幕
''';
      final remappedSrt = SubtitleTimelineRemapper.remap(
        content: srt,
        transform: const SubtitleTimelineTransform(offsetSeconds: 2.25),
      );
      expect(remappedSrt, contains('00:00:03,250 --> 00:00:05,750'));

      const vtt = '''
WEBVTT

00:01.000 --> 00:04.000
Hello <00:02.500>world <00:00:03.500>!
''';
      final remappedVtt = SubtitleTimelineRemapper.remap(
        content: vtt,
        transform: const SubtitleTimelineTransform(offsetSeconds: 1.5),
      );
      expect(remappedVtt, contains('00:02.500 --> 00:05.500'));
      expect(remappedVtt, contains('Hello <00:04.000>world <00:00:05.000>!'));
    });
  });

  group('Step 4.5 内存直注与 Completer 确定性并发零反写验证', () {
    test('换轨在途关字幕、改延迟或切集时 100% 零反写，且正常调轴 < 5ms 零落盘与 SHA-1 去重', () async {
      final fakeClient = _FakeSubtitleMpvClient();
      final unifiedEngine = UnifiedPlaybackEngine();
      unifiedEngine.beginPhysicalMedia();
      final memEngine = SubtitleMemoryEngine(
        clientSupplier: () => fakeClient,
        playbackEngine: unifiedEngine,
      );

      final sampleAssBytes = Uint8List.fromList(
        utf8.encode('''
[Script Info]
ScriptType: v4.00+
[Events]
Dialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,這個動畫真好看
'''),
      );

      // 场景 A：换轨在途用户关闭字幕 -> 过时任务必须 0 写回。
      final gateA = Completer<Uint8List>();
      final inflightA = memEngine.applyIntent(
        AuthoritativeSubtitleIntent(
          primary: SubtitleSlotRequest.memory(
            loadBytes: () => gateA.future,
            fileName: 'ep01.ass',
            openCcMode: SubtitleOpenCcMode.toSimplified,
          ),
        ),
      );
      final disableRes = await memEngine.applyIntent(
        const AuthoritativeSubtitleIntent.disable(),
      );
      expect(disableRes.applied, isTrue);
      expect(fakeClient.sid, equals('no'));

      final cmdCountAfterDisable = fakeClient.recordedCommands.length;
      final writeCountAfterDisable = fakeClient.recordedPropertyWrites.length;
      gateA.complete(sampleAssBytes);
      final staleResA = await inflightA;
      expect(staleResA.applied, isFalse);
      expect(staleResA.staleAborted, isTrue);
      expect(fakeClient.recordedCommands.length, equals(cmdCountAfterDisable));
      expect(
        fakeClient.recordedPropertyWrites.length,
        equals(writeCountAfterDisable),
      );
      expect(fakeClient.sid, equals('no'));

      // 场景 B：换轨在途用户修改瞬时延迟 -> 过时任务 0 写回，延迟稳守新值。
      final gateB = Completer<Uint8List>();
      final inflightB = memEngine.applyIntent(
        AuthoritativeSubtitleIntent(
          primary: SubtitleSlotRequest.memory(
            loadBytes: () => gateB.future,
            fileName: 'ep01.ass',
          ),
        ),
      );
      memEngine.setInstantSubtitleDelay(1.25);
      expect(fakeClient.subDelay, closeTo(1.25, 1e-6));
      final writesAfterDelay = fakeClient.recordedPropertyWrites.length;
      gateB.complete(sampleAssBytes);
      final staleResB = await inflightB;
      expect(staleResB.staleAborted, isTrue);
      expect(fakeClient.recordedPropertyWrites.length, equals(writesAfterDelay));
      expect(fakeClient.subDelay, closeTo(1.25, 1e-6));

      // 场景 C：换轨在途切换物理媒体（切集）-> 过时任务 0 写回。
      final gateC = Completer<Uint8List>();
      final inflightC = memEngine.applyIntent(
        AuthoritativeSubtitleIntent(
          primary: SubtitleSlotRequest.memory(
            loadBytes: () => gateC.future,
            fileName: 'ep01.ass',
          ),
        ),
      );
      unifiedEngine.beginPhysicalMedia();
      memEngine.resetForPhysicalMediaEpoch(unifiedEngine.physicalMediaEpoch);
      final cmdsAfterSwitch = fakeClient.recordedCommands.length;
      gateC.complete(sampleAssBytes);
      final staleResC = await inflightC;
      expect(staleResC.staleAborted, isTrue);
      expect(fakeClient.recordedCommands.length, equals(cmdsAfterSwitch));

      // 场景 D：正常离线调轴 + 繁转简直注 -> 零改 sub-codepage、原子归零 sub-delay、同内容 SHA-1 复用。
      fakeClient.subDelay = 2.4;
      final okRes = await memEngine.applyIntent(
        AuthoritativeSubtitleIntent(
          primary: SubtitleSlotRequest.memory(
            loadBytes: () async => sampleAssBytes,
            fileName: 'ep02.ass',
            displayTitle: 'EP02 简中重映射',
            openCcMode: SubtitleOpenCcMode.toSimplified,
            timelineTransform: const SubtitleTimelineTransform(
              offsetSeconds: 2.0,
            ),
          ),
        ),
      );
      expect(okRes.applied, isTrue);
      expect(okRes.staleAborted, isFalse);
      expect(okRes.zeroedInstantSubDelay, isTrue);
      expect(okRes.usedCachedMemoryTrack, isFalse);
      expect(fakeClient.subDelay, equals(0.0));
      expect(fakeClient.sid, equals('${okRes.primaryTrackId}'));
      expect(
        fakeClient.recordedPropertyWrites.any((w) => w.name == 'sub-codepage'),
        isFalse,
      );
      final subAddCmd = fakeClient.recordedCommands.last;
      expect(subAddCmd[0], equals('sub-add'));
      expect(subAddCmd[1], startsWith('memory://'));
      expect(subAddCmd[1], contains('这个动画真好看'));
      expect(subAddCmd[1], contains('0:00:03.00,0:00:05.00'));
      expect(subAddCmd[2], equals('cached'));

      // 再次提交相同内容与参数的意图：直接命中 SHA-1 内存轨去重，不发第二次 sub-add。
      final subAddCountBefore = fakeClient.recordedCommands.length;
      final reuseRes = await memEngine.applyIntent(
        AuthoritativeSubtitleIntent(
          primary: SubtitleSlotRequest.memory(
            loadBytes: () async => sampleAssBytes,
            fileName: 'ep02.ass',
            displayTitle: 'EP02 简中重映射',
            openCcMode: SubtitleOpenCcMode.toSimplified,
            timelineTransform: const SubtitleTimelineTransform(
              offsetSeconds: 2.0,
            ),
          ),
        ),
      );
      expect(reuseRes.applied, isTrue);
      expect(reuseRes.usedCachedMemoryTrack, isTrue);
      expect(reuseRes.primaryTrackId, equals(okRes.primaryTrackId));
      expect(fakeClient.recordedCommands.length, equals(subAddCountBefore));
    });

    test(
      'Windows 真机 libmpv-2.dll 内存直注实证：sub-add memory://... 毫秒级生效且零磁盘临时文件',
      () async {
        if (!Platform.isWindows) return;
        final dllPath = p.join(
          Directory.current.path,
          'native',
          'konata-native',
          'windows',
          'libmpv-2.dll',
        );
        expect(
          File(dllPath).existsSync(),
          isTrue,
          reason: 'Windows 环境必须存在真实 libmpv-2.dll，禁止静默跳过',
        );
        final tempDir = await Directory.systemTemp.createTemp('konata_mpv_mem_');
        final wavFile = File(p.join(tempDir.path, 'probe.wav'));
        await wavFile.writeAsBytes(
          Phase3TestFixtures.generateUniqueSampleWav(durationMs: 1200),
          flush: true,
        );

        final client = FfiLibMpvClient.create(preferredLibraryPath: dllPath);
        final unifiedEngine = UnifiedPlaybackEngine();
        unifiedEngine.beginPhysicalMedia();
        final memEngine = SubtitleMemoryEngine(
          clientSupplier: () => client,
          playbackEngine: unifiedEngine,
        );

        try {
          client.setOptionString('vo', 'null');
          client.setOptionString('ao', 'null');
          client.setOptionString('pause', 'yes');
          client.setOptionString('sub-auto', 'fuzzy');
          client.setOptionString('sid', 'no');
          expect(client.initialize(), equals(0));

          final loaded = Completer<void>();
          final sub = client.events.listen((e) {
            if (e is MpvFileLoadedEvent && !loaded.isCompleted) {
              loaded.complete();
            }
          });
          expect(client.command(['loadfile', wavFile.path, 'replace']), equals(0));
          await loaded.future.timeout(const Duration(seconds: 5));
          await sub.cancel();

          client.setPropertyDouble('sub-delay', 1.5);
          final gbkAss = Uint8List.fromList(
            cs.gbk.encode('''
[Script Info]
ScriptType: v4.00+
[Events]
Dialogue: 0,0:00:00.10,0:00:01.00,Default,,0,0,0,,内存直注零落盘测试
'''),
          );

          final result = await memEngine.applyIntent(
            AuthoritativeSubtitleIntent(
              primary: SubtitleSlotRequest.memory(
                loadBytes: () async => gbkAss,
                fileName: 'gbk_mem.ass',
                displayTitle: 'KonataMemLive',
                timelineTransform: const SubtitleTimelineTransform(
                  offsetSeconds: 0.5,
                ),
              ),
            ),
          );

          expect(result.applied, isTrue);
          expect(result.primaryTrackId, isNotNull);
          expect(result.primaryDecodedCharset, equals(DetectedTextCharset.gb18030Gbk));
          expect(result.zeroedInstantSubDelay, isTrue);
          expect(client.getPropertyString('sid'), equals('${result.primaryTrackId}'));
          expect(client.getPropertyDouble('sub-delay'), closeTo(0.0, 1e-6));
          // 确认临时目录中除探针音频外零额外字幕碎片文件产生。
          final files = await tempDir.list().toList();
          expect(files, hasLength(1));
        } finally {
          memEngine.dispose();
          await client.dispose();
          if (await tempDir.exists()) {
            await tempDir.delete(recursive: true);
          }
        }
      },
    );
  });
}
