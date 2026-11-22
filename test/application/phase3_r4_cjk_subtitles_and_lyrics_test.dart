import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:charset/charset.dart' as cs;
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:konata/application/playback/audio_playback_notifier.dart';
import 'package:konata/application/playback/lyrics_resolver.dart';
import 'package:konata/application/playback/playback_preferences_provider.dart';
import 'package:konata/application/playback/unified_playback_engine.dart';
import 'package:konata/application/playback/video_playback_controller.dart';
import 'package:konata/application/providers/library_providers.dart';
import 'package:konata/application/providers/playback_providers.dart';
import 'package:konata/domain/lyrics/lyric_candidate.dart';
import 'package:konata/domain/models/episode.dart';
import 'package:konata/domain/models/media_source.dart';
import 'package:konata/domain/models/media_variant.dart';
import 'package:konata/domain/models/work.dart';
import 'package:konata/domain/playback/ass_uue_font_decoder.dart';
import 'package:konata/domain/playback/opencc_dictionaries.dart';
import 'package:konata/domain/playback/playback_probe_stats.dart';
import 'package:konata/domain/playback/subtitle_and_audio_choices.dart';
import 'package:konata/domain/playback/subtitle_content_processor.dart';
import 'package:konata/domain/playback/subtitle_timeline_remapper.dart';
import 'package:konata/domain/playback/track_preferences.dart';
import 'package:konata/domain/repositories/file_system_gateway.dart';
import 'package:konata/domain/text/big5_cp950_table.dart';
import 'package:konata/domain/text/multibyte_text_decoder.dart';
import 'package:konata/infrastructure/database/drift_library_repository.dart';
import 'package:konata/infrastructure/database/drift_lyric_cache_repository.dart';
import 'package:konata/infrastructure/database/konata_database.dart';
import 'package:konata/infrastructure/lyrics/lyric_http_transport.dart';
import 'package:konata/infrastructure/network/metered_network_detector.dart';
import 'package:konata/infrastructure/players/embedded_mpv_session.dart';
import 'package:konata/infrastructure/players/libmpv_ffi.dart';
import 'package:konata/infrastructure/sources/byte_stream_source_gateway.dart';
import 'package:konata/infrastructure/sources/source_gateway_factory.dart';
import 'package:konata/infrastructure/sources/subtitle_matcher.dart';
import 'package:konata/infrastructure/sources/work_detail_warmup_service.dart';
import 'package:konata/infrastructure/storage/atomic_file_writer.dart';
import 'package:konata/infrastructure/storage/storage_root_provider.dart';
import 'package:konata/infrastructure/stream_bridge/local_stream_bridge.dart';

/// 构造包含合法 SFNT 魔数的最小未压缩 ZIP 字节（用于验证 Fonts.zip 入池与 sub-fonts-dir 联动）。
Uint8List _buildStoredFontZip(Map<String, Uint8List> files) {
  final localChunks = <int>[];
  final centralChunks = <int>[];
  var offset = 0;

  for (final entry in files.entries) {
    final nameBytes = utf8.encode(entry.key);
    final data = entry.value;
    final lh = ByteData(30);
    lh.setUint32(0, 0x04034b50, Endian.little);
    lh.setUint16(4, 20, Endian.little);
    lh.setUint16(8, 0, Endian.little);
    lh.setUint32(18, data.length, Endian.little);
    lh.setUint32(22, data.length, Endian.little);
    lh.setUint16(26, nameBytes.length, Endian.little);

    localChunks
      ..addAll(lh.buffer.asUint8List())
      ..addAll(nameBytes)
      ..addAll(data);

    final ch = ByteData(46);
    ch.setUint32(0, 0x02014b50, Endian.little);
    ch.setUint16(4, 20, Endian.little);
    ch.setUint16(6, 20, Endian.little);
    ch.setUint16(10, 0, Endian.little);
    ch.setUint32(20, data.length, Endian.little);
    ch.setUint32(24, data.length, Endian.little);
    ch.setUint16(28, nameBytes.length, Endian.little);
    ch.setUint32(42, offset, Endian.little);

    centralChunks
      ..addAll(ch.buffer.asUint8List())
      ..addAll(nameBytes);

    offset += 30 + nameBytes.length + data.length;
  }

  final eocd = ByteData(22);
  eocd.setUint32(0, 0x06054b50, Endian.little);
  eocd.setUint16(8, files.length, Endian.little);
  eocd.setUint16(10, files.length, Endian.little);
  eocd.setUint32(12, centralChunks.length, Endian.little);
  eocd.setUint32(16, offset, Endian.little);

  return Uint8List.fromList([
    ...localChunks,
    ...centralChunks,
    ...eocd.buffer.asUint8List(),
  ]);
}

Uint8List _fakeTrueTypeFontBytes([int tagSeed = 1]) {
  return Uint8List.fromList([
    0x00, 0x01, 0x00, 0x00, // TrueType SFNT 魔数
    0x00, 0x04, 0x00, 0x40,
    0x00, 0x02, 0x00, tagSeed & 0xFF,
    ...List<int>.filled(64, (tagSeed * 17) & 0xFF),
  ]);
}

class _R4FakeMpvClient implements LibMpvClient {
  final List<List<String>> commands = [];
  final Map<String, String> stringProps = {};
  final Map<String, double> doubleProps = {};
  final List<MpvTrackInfo> tracks = [
    const MpvTrackInfo(id: 1, type: MpvTrackType.video, selected: true),
    const MpvTrackInfo(id: 1, type: MpvTrackType.audio, selected: true),
  ];
  final StreamController<MpvClientEvent> _events =
      StreamController<MpvClientEvent>.broadcast();
  int _nextSubId = 10;
  bool _disposed = false;
  bool _initialized = false;

  @override
  int get handleAddress => 0;

  @override
  bool get isInitialized => _initialized && !_disposed;

  @override
  bool get isDisposed => _disposed;

  @override
  String errorString(int code) => 'ok($code)';

  @override
  int setOptionString(String name, String value) {
    stringProps[name] = value;
    return 0;
  }

  @override
  int initialize() {
    _initialized = true;
    return 0;
  }

  @override
  int setPropertyString(String name, String value) {
    stringProps[name] = value;
    return 0;
  }

  @override
  int setPropertyFlag(String name, bool value) => 0;

  @override
  int setPropertyInt64(String name, int value) {
    stringProps[name] = '$value';
    return 0;
  }

  @override
  int setPropertyDouble(String name, double value) {
    doubleProps[name] = value;
    return 0;
  }

  @override
  String? getPropertyString(String name) => stringProps[name];

  @override
  bool? getPropertyFlag(String name) => false;

  @override
  int? getPropertyInt64(String name) => null;

  @override
  double? getPropertyDouble(String name) => doubleProps[name] ?? 0.0;

  @override
  List<MpvTrackInfo> readTrackList() => List<MpvTrackInfo>.unmodifiable(tracks);

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
    commands.add(List<String>.unmodifiable(args));
    if (args.length >= 2 && args[0] == 'sub-add') {
      final id = _nextSubId++;
      tracks.add(
        MpvTrackInfo(
          id: id,
          type: MpvTrackType.subtitle,
          title: args.length >= 4 ? args[3] : '',
          externalFilename: args[1],
          isExternal: true,
        ),
      );
    } else if (args.length >= 2 && args[0] == 'loadfile') {
      scheduleMicrotask(() {
        if (!_disposed && !_events.isClosed) {
          _events.add(const MpvStartFileEvent(1));
          _events.add(const MpvFileLoadedEvent());
          _events.add(const MpvPlaybackRestartEvent());
        }
      });
    }
    return 0;
  }

  @override
  int commandAsync(int replyUserdata, List<String> args) => command(args);

  @override
  Stream<MpvClientEvent> get events => _events.stream;

  @override
  Future<void> dispose() async {
    _disposed = true;
    await _events.close();
  }
}

class _ValidatorAwareGateway implements FileValidatorProbeGateway {
  _ValidatorAwareGateway({
    required this.files,
    required this.validators,
  });

  final Map<String, Uint8List> files;
  final Map<String, String> validators;

  @override
  Future<({int? length, String? validator})> probeFileMetadata(
    String relativePath,
  ) async {
    return (
      length: files[relativePath]?.length,
      validator: validators[relativePath],
    );
  }

  @override
  Future<int?> probeFileLength(String relativePath) async =>
      files[relativePath]?.length;

  @override
  Future<Stream<List<int>>> openByteRange(
    String relativePath, {
    required int start,
    int? endInclusive,
  }) async {
    final data = files[relativePath]!;
    final end = endInclusive == null
        ? data.length
        : (endInclusive + 1).clamp(start, data.length);
    return Stream<List<int>>.value(data.sublist(start, end));
  }

  @override
  Future<void> close() async {}
}

class _GatedWarmupGateway implements MediaSourceGateway {
  _GatedWarmupGateway({
    required this.rootEntries,
    required this.subEntries,
    required this.firstSubdirGate,
  });

  final List<RemoteEntry> rootEntries;
  final Map<String, List<RemoteEntry>> subEntries;
  final Completer<void> firstSubdirGate;
  final List<String> listedDirs = [];
  bool _gatedFirstSubdir = false;

  @override
  Future<List<RemoteEntry>> listDirectory(String relativePath) async {
    listedDirs.add(relativePath);
    if (relativePath == 'Anime/Show') {
      return rootEntries;
    }
    if (!_gatedFirstSubdir) {
      _gatedFirstSubdir = true;
      await firstSubdirGate.future;
    }
    return subEntries[relativePath] ?? const [];
  }

  @override
  Future<String?> readTextFile(String relativePath, {int maxBytes = 256 * 1024}) async =>
      null;

  @override
  Future<String?> testConnection() async => null;

  @override
  Future<void> close() async {}
}

class _SingleGatewayFactory extends MediaSourceGatewayFactory {
  const _SingleGatewayFactory(this.gateway);

  final MediaSourceGateway gateway;

  @override
  Future<MediaSourceGateway> create(
    MediaSource source, {
    String? passwordOverride,
    bool clearPassword = false,
  }) async => gateway;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('批次 R4 [#10] 完整 Big5/CP950 码表、标准 OpenCC 词库与 ASS 调轴保真', () {
    test('Big5/CP950 码表覆盖全部 >= 13,053 标准汉字且生僻繁日对白 0 个 0xFFFD', () {
      expect(Big5Cp950Table.standardHanziCount, greaterThanOrEqualTo(13053));
      expect(Big5Cp950Table.totalMappedCount, greaterThanOrEqualTo(13700));

      // 遍历标准 Big5 汉字区间 0xA440..0xC67E 与 0xC940..0xF9D5，实证核验有效映射数 >= 13,053。
      var verifiedHanziCount = 0;
      for (var b1 = 0xA4; b1 <= 0xF9; b1++) {
        for (final b2 in [
          for (var x = 0x40; x <= 0x7E; x++) x,
          for (var x = 0xA1; x <= 0xFE; x++) x,
        ]) {
          final code = (b1 << 8) | b2;
          final inStandardHanzi =
              (code >= 0xA440 && code <= 0xC67E) ||
              (code >= 0xC940 && code <= 0xF9D5);
          if (!inStandardHanzi) continue;
          if (Big5Cp950Table.lookup(b1, b2) > 0) {
            verifiedHanziCount += 1;
          }
        }
      }
      expect(verifiedHanziCount, greaterThanOrEqualTo(13053));

      // 用含常用与生僻次常用区（0xA440..0xC67E 与 0xC940..0xF9D5）繁体汉字的 CP950 原始字节流做纯 Dart 解码，
      // 断言零 0xFFFD 替换符且全字精确还原。
      final rareBig5Bytes = Uint8List.fromList([
        0xA1, 0x75, // 「
        0xC6, 0x7B, // 鬱
        0xC4, 0x60, // 巉
        0xC5, 0xC9, // 巖
        0xC6, 0x75, // 黷
        0xC5, 0x57, // 饗
        0xC6, 0x5F, // 鑰
        0xC6, 0x77, // 鑿
        0xC5, 0x5E, // 魑
        0xBE, 0x79, // 魅
        0xC3, 0x53, // 魍
        0xC3, 0x52, // 魎
        0xC5, 0xB9, // 饕
        0xC3, 0x4B, // 餮
        0xF6, 0xF6, // 礵 (次常用区 0xC940..0xF9D5)
        0xF6, 0xBE, // 鷎 (次常用区 0xC940..0xF9D5)
        0xF3, 0xCA, // 鯞 (次常用区 0xC940..0xF9D5)
        0xA1, 0x76, // 」
      ]);
      final decoded = MultibyteTextDecoder.decodeWithInfo(rareBig5Bytes);
      expect(decoded.charset, equals(DetectedTextCharset.big5));
      expect(decoded.text.contains('\uFFFD'), isFalse);
      expect(decoded.text, equals('「鬱巉巖黷饗鑰鑿魑魅魍魎饕餮礵鷎鯞」'));
    });

    test('OpenCC 标准词库规模 >= 4,000、简转繁非反转且全部高频多义消歧准确', () {
      expect(OpenCcDictionaries.tsCharacterCount, greaterThanOrEqualTo(4000));
      expect(OpenCcDictionaries.stCharacterCount, greaterThanOrEqualTo(4000));
      expect(OpenCcDictionaries.tsChars.length, greaterThanOrEqualTo(4000));
      expect(OpenCcDictionaries.stChars.length, greaterThanOrEqualTo(4000));
      expect(OpenCcDictionaries.stPhrases.length, greaterThan(5000));

      // 证实 STCharacters 并非简单反转 TSCharacters（如 一对多单字映射与词组定向消歧）。
      expect(
        OpenCcDictionaries.tsChars.length,
        isNot(equals(OpenCcDictionaries.stChars.length)),
      );

      // 繁 -> 简多义消歧实测（含 10 组高频歧义对 + 生僻双语 ASS 保护日文假名）。
      const tradAss = r'''
[Script Info]
ScriptType: v4.00+
[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:01.00,0:00:05.00,Default,,0,0,0,,皇后與以後的後面、裡面和裏面相距一公里、一隻貓只要開心\Nこれは日本語の「鬱巉巖」と假名テストです
Dialogue: 0,0:00:06.00,0:00:10.00,Default,,0,0,0,,戰鬥在北斗星下、時鐘見證一見鍾情、老闆擦黑板、醜陋的怪物在丑時戀愛、乾燥的頭髮出發扭轉乾坤去幹活
''';
      final toSimp = SubtitleContentProcessor.process(
        content: tradAss,
        mode: SubtitleOpenCcMode.toSimplified,
      );
      expect(toSimp.converted, isTrue);
      expect(toSimp.content, contains('皇后与以后的后面、里面和里面相距一公里、一只猫只要开心'));
      expect(toSimp.content, contains(r'\Nこれは日本語の「鬱巉巖」と假名テストです'));
      expect(
        toSimp.content,
        contains('战斗在北斗星下、时钟见证一见钟情、老板擦黑板、丑陋的怪物在丑时恋爱、干燥的头发出发扭转乾坤去干活'),
      );

      // 简 -> 繁多义消歧实测（防止 皇后->皇後、公里->公裏、北斗->北鬥、时钟->時鍾、黑板->黑闆、丑时->醜時、干活->乾活、头发->頭發 等误转）。
      const simpAss = '''
[Script Info]
ScriptType: v4.00+
[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:01.00,0:00:05.00,Default,,0,0,0,,皇后以后在后面、一公里内一只猫只要开心、战斗在北斗下
Dialogue: 0,0:00:06.00,0:00:10.00,Default,,0,0,0,,时钟见证一见钟情、老板擦黑板、丑陋的怪物在丑时恋爱、干燥的头发去干活扭转乾坤出发
''';
      final toTrad = SubtitleContentProcessor.process(
        content: simpAss,
        mode: SubtitleOpenCcMode.toTraditional,
      );
      expect(toTrad.converted, isTrue);
      expect(toTrad.content, contains('皇后以後在後面、一公里內一隻貓只要開心、戰鬥在北斗下'));
      expect(
        toTrad.content,
        contains('時鐘見證一見鍾情、老闆擦黑板、醜陋的怪物在丑時戀愛、乾燥的頭髮去幹活扭轉乾坤出發'),
      );
    });

    test('ASS 动态解析 Format 列序、保留合法负 fade t1 且 rateScale==1.0 跨零截断同步裁剪行内标签', () {
      const customOrderAss = r'''
[Script Info]
ScriptType: v4.00+
[Events]
Format: Style, Start, End, Layer, Text
Dialogue: Default,0:00:01.00,0:00:04.00,0,{\fade(255,0,255,-200,1500,2000,2500)\fad(1200,400)\t(500,1500,0.5,\fs48)\k60}啊{\k70}波{\k50}次,含逗号文本
''';
      // 1. 纯缩放时保留合法负 t1 (-200 * 1.5 = -300) 并按自定义 Format 列序重写 Start/End/Text。
      final scaled = SubtitleTimelineRemapper.remap(
        content: customOrderAss,
        transform: const SubtitleTimelineTransform(rateScale: 1.5),
      );
      expect(scaled, contains('Dialogue: Default,0:00:01.50,0:00:06.00,0,'));
      expect(scaled, contains(r'\fade(255,0,255,-300,2250,3000,3750)'));
      expect(scaled, contains(',含逗号文本'));

      // 2. rateScale == 1.0 且负偏移 -2.0s 导致 [1.0s, 4.0s] -> [0.0s, 2.0s]（头部裁掉 1000ms = 100cs）：
      //    行内 \k60\k70\k50 -> \k0\k30\k50，\t(500,1500,0.5,...) -> \t(0,500,0.5,...)，\fad(1200,400) -> \fad(200,400)，\fade t1=-200 -> -1200。
      final clipped = SubtitleTimelineRemapper.remap(
        content: customOrderAss,
        transform: const SubtitleTimelineTransform(
          rateScale: 1.0,
          offsetSeconds: -2.0,
        ),
      );
      expect(clipped, contains('Dialogue: Default,0:00:00.00,0:00:02.00,0,'));
      expect(clipped, contains(r'\fade(255,0,255,-1200,500,1000,1500)'));
      expect(clipped, contains(r'\fad(200,400)'));
      expect(clipped, contains(r'\t(0,500,0.5,\fs48)'));
      expect(clipped, contains(r'\k0}啊{\k30}波{\k50}次,含逗号文本'));
    });
  });

  group('批次 R4 [#11] 真实 ETag/mtime 缓存透传、Windows 安全原子替换、预热切页即停与唯一子目录判定', () {
    test('LocalStreamBridge 透传网关真实 ETag 验证器而非退化为 len:，且 Windows 目标已存在时安全原子覆盖', () async {
      final tempDir = await Directory.systemTemp.createTemp('konata_r4_11_');
      final bridge = LocalStreamBridge(
        storageRoot: StorageRootService(overrideRoot: tempDir),
      );
      try {
        final v1 = Uint8List.fromList(utf8.encode('[Script Info]\nTitle: V1\n'));
        final gw = _ValidatorAwareGateway(
          files: {'S01/ep01.ass': v1},
          validators: {'S01/ep01.ass': '"etag-real-abc123"'},
        );
        final records = await bridge.materializeRemoteSubtitleRecords(
          gateway: gw,
          workId: 'w_etag',
          sourceId: 'src_dav',
          subtitleRelativePaths: const ['S01/ep01.ass'],
        );
        expect(records, hasLength(1));
        expect(records.first.validator, equals('"etag-real-abc123"'));
        expect(records.first.validator.startsWith('len:'), isFalse);

        // 验证 AtomicFileWriter.replaceFile 在目标文件已存在时无损覆盖且零残留 .part/.bak。
        final target = File(p.join(tempDir.path, 'existing_target.ass'));
        await target.writeAsString('OLD_PAYLOAD', flush: true);
        final part = File('${target.path}.part.1');
        await part.writeAsString('NEW_ATOMIC_PAYLOAD', flush: true);
        await AtomicFileWriter.replaceFile(
          part,
          target,
          expectedLength: utf8.encode('NEW_ATOMIC_PAYLOAD').length,
        );
        expect(await target.readAsString(), equals('NEW_ATOMIC_PAYLOAD'));
        expect(await part.exists(), isFalse);
        final bakFiles = await tempDir
            .list()
            .where((e) => e.path.contains('.bak.'))
            .toList();
        expect(bakFiles, isEmpty);
      } finally {
        await bridge.dispose();
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      }
    });

    test('WorkDetailWarmupService 切页 cancelPending 后循环立即中止且共享唯一字幕子目录判定', () async {
      expect(SubtitleAndAudioChoices.isSubtitleSubdirName('Subs'), isTrue);
      expect(SubtitleAndAudioChoices.isSubtitleSubdirName('Subtitles'), isTrue);
      expect(SubtitleAndAudioChoices.isSubtitleSubdirName('简体字幕'), isTrue);
      expect(SubtitleAndAudioChoices.isSidecarSubdirName('SP Audio'), isTrue);
      expect(
        SubtitleAndAudioChoices.logicalParentDirOfSubtitleDir('Anime/S1/Subs'),
        equals('Anime/S1'),
      );
      final matched = SubtitleMatcher.matchForVideo(
        videoRelativePath: 'Anime/S1/ep01.mkv',
        allSubtitleRelativePaths: const ['Anime/S1/Subs_CHS/ep01.chs.ass'],
      );
      expect(matched.subtitlePaths, equals(['Anime/S1/Subs_CHS/ep01.chs.ass']));

      final gate = Completer<void>();
      final gw = _GatedWarmupGateway(
        rootEntries: const [
          RemoteEntry(
            name: 'Subs1',
            relativePath: 'Anime/Show/Subs1',
            isDirectory: true,
          ),
          RemoteEntry(
            name: 'Subs2',
            relativePath: 'Anime/Show/Subs2',
            isDirectory: true,
          ),
          RemoteEntry(
            name: 'Subs3',
            relativePath: 'Anime/Show/Subs3',
            isDirectory: true,
          ),
        ],
        subEntries: const {
          'Anime/Show/Subs1': [
            RemoteEntry(
              name: '01.chs.ass',
              relativePath: 'Anime/Show/Subs1/01.chs.ass',
              isDirectory: false,
              etag: '"etag-sub1"',
            ),
          ],
          'Anime/Show/Subs2': [],
          'Anime/Show/Subs3': [],
        },
        firstSubdirGate: gate,
      );
      final index = SubtitleDirectoryIndex();
      final svc = WorkDetailWarmupService(
        gatewayFactory: _SingleGatewayFactory(gw),
        directoryIndex: index,
      );
      const src = MediaSource(
        id: 'src_dav',
        label: 'DAV',
        kind: MediaSourceKind.webdav,
        location: 'https://dav.example.com',
      );

      final warmupFuture = svc.warmupDirectory(
        source: src,
        dirRelativePath: 'Anime/Show',
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      // 用户在扫描第 1 个子目录途中切页取消 -> 严禁再扫 Subs2/Subs3 且严禁写脏快照。
      svc.cancelPending();
      gate.complete();
      final snap = await warmupFuture;
      expect(snap, isNull);
      expect(gw.listedDirs, equals(['Anime/Show', 'Anime/Show/Subs1']));
      expect(index.lookup('src_dav', 'Anime/Show'), isNull);
    });
  });

  group('批次 R4 [#3 & #9] 单一内存字幕通道、云端子集化真实接线、Origin 持久化与字库入池', () {
    test('CloudSubsetAuthorizationStore 授权白名单持久化跨重启保留', () async {
      SharedPreferences.setMockInitialValues({});
      final originUri = Uri.parse('https://subset.konata.local:8443/api/subset');

      final container1 = ProviderContainer();
      final store1 = container1.read(cloudSubsetAuthorizationStoreProvider);
      await store1.ensureHydrated();
      expect(store1.isAuthorized(originUri), isFalse);
      store1.grant(originUri);
      await store1.flushPendingPersistence();
      container1.dispose();

      // 模拟应用重启后的全新 ProviderContainer：白名单自动从 SharedPreferences 恢复。
      final container2 = ProviderContainer();
      final store2 = container2.read(cloudSubsetAuthorizationStoreProvider);
      await store2.ensureHydrated();
      expect(store2.isAuthorized(originUri), isTrue);
      container2.dispose();
    });

    test('外挂 GBK ASS 经单一内存通道触发云端子集化、ASS [Fonts] 入池更新 sub-fonts-dir 并以 cached 挂载', () async {
      await HttpOverrides.runWithHttpOverrides(() async {
          SharedPreferences.setMockInitialValues({});
          final tempDir = await Directory.systemTemp.createTemp('konata_r4_39_');
          final fakeClient = _R4FakeMpvClient();
          var cloudPostCount = 0;

          // 构造含合法 [Fonts] UUE 字体的云端返回 ASS（与原对话语义 100% 同构）。
          final fontBytes = _fakeTrueTypeFontBytes(7);
          final uueFont = AssUueFontDecoder.encode(fontBytes);
          const originalAss = '''
[Script Info]
ScriptType: v4.00+
[V4+ Styles]
Format: Name, Fontname, Fontsize
Style: Default,NotoSansCJK,48
[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:01.00,0:00:04.00,Default,,0,0,0,,简体中文编码归一与云端子集测试
''';
          final subsettedAss = '''
[Script Info]
ScriptType: v4.00+
[V4+ Styles]
Format: Name, Fontname, Fontsize
Style: Default,AB12CD+NotoSansCJK,48
[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:01.00,0:00:04.00,Default,,0,0,0,,简体中文编码归一与云端子集测试
[Fonts]
fontname: AB12CD+NotoSansCJK.ttf
$uueFont
''';

          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          server.listen((req) async {
            cloudPostCount += 1;
            await req.drain<void>();
            req.response.statusCode = HttpStatus.ok;
            req.response.write(subsettedAss);
            await req.response.close();
          });

          final endpointUri = Uri.parse('http://127.0.0.1:${server.port}/subset');
          final videoFile = File(p.join(tempDir.path, 'ep01.mkv'))
            ..writeAsBytesSync(const [0x1A, 0x45, 0xDF, 0xA3]);
          // 将手动加载的 GBK 字幕放入独立目录，先验证起播 Fonts.zip 入池，再验证手动加载触发云端子集与 ASS [Fonts] 切换。
          final extraSubDir = await Directory(
            p.join(tempDir.path, 'external_manual'),
          ).create(recursive: true);
          final gbkSubFile = File(p.join(extraSubDir.path, 'manual.gbk.ass'));
          await gbkSubFile.writeAsBytes(cs.gbk.encode(originalAss), flush: true);

          // 同级放置 Fonts.zip 验证本地起播自动解包入池。
          final fontsZipFile = File(p.join(tempDir.path, 'Fonts.zip'));
          await fontsZipFile.writeAsBytes(
            _buildStoredFontZip({'SubFont.ttf': _fakeTrueTypeFontBytes(3)}),
            flush: true,
          );

          final db = KonataDatabase(NativeDatabase.memory());
          final repo = DriftLibraryRepository(db);
          final storage = StorageRootService(overrideRoot: tempDir);
          final bridge = LocalStreamBridge(storageRoot: storage);

          final source = MediaSource(
            id: 'src_local_r4',
            label: 'Local',
            kind: MediaSourceKind.local,
            location: tempDir.path,
          );
          const work = Work(id: 'w_r4', title: 'R4 Test Work');
          const ep = Episode(
            id: 'ep_r4_1',
            workId: 'w_r4',
            seasonNumber: 1,
            episodeNumber: 1,
            category: EpisodeCategory.main,
            title: '第 1 话',
          );
          final variant = MediaVariant(
            id: 'v_r4_1',
            workId: 'w_r4',
            sourceId: source.id,
            relativePath: p.basename(videoFile.path),
            fileName: p.basename(videoFile.path),
            fileSize: 4,
            assetKind: AssetKind.video,
          );
          await repo.upsertMediaSource(source);
          await repo.upsertWork(work);
          await repo.upsertEpisode(ep);
          await repo.upsertMediaVariant(variant);

          final bundle = WorkDetailBundle(
            work: work,
            episodes: const [ep],
            variants: [variant],
            sourcesById: {source.id: source},
            latestPlayback: null,
            playbackByEpisodeId: const {},
            seriesMembers: const [work],
          );
          final req = VideoLaunchRequest(
            work: work,
            episode: ep,
            variant: variant,
            bundle: bundle,
            source: source,
          );

          late EmbeddedMpvSession createdSession;
          late final ProviderContainer container;
          container = ProviderContainer(
            overrides: [
              libraryRepositoryProvider.overrideWithValue(repo),
              storageRootProvider.overrideWithValue(storage),
              localStreamBridgeProvider.overrideWithValue(bridge),
              libraryItemsProvider.overrideWith((ref) async => const []),
              videoPlaybackProvider(req).overrideWith(
                () => VideoPlaybackController(
                  req,
                  sessionFactory: () {
                    createdSession = EmbeddedMpvSession(
                      storageRoot: storage,
                      streamBridge: bridge,
                      clientFactory: () => fakeClient,
                      fontPoolManager: container.read(
                        subtitleFontPoolManagerProvider,
                      ),
                    );
                    return createdSession;
                  },
                ),
              ),
            ],
          );

          final prefsNotifier = container.read(playbackPreferencesProvider.notifier);
          await prefsNotifier.setCloudSubsetEnabled(true);
          await prefsNotifier.setCloudSubsetEndpoint(endpointUri.toString());
          container.read(cloudSubsetCoordinatorProvider).authorizeOrigin(endpointUri);
          await container
              .read(cloudSubsetAuthorizationStoreProvider)
              .flushPendingPersistence();

          final videoSub = container.listen(
            videoPlaybackProvider(req),
            (_, _) {},
          );
          final ctrl = container.read(videoPlaybackProvider(req).notifier);

          try {
            await Future<void>.delayed(const Duration(milliseconds: 120));
            // 1. 本地起播同级 Fonts.zip 已自动解包入池并写入 sub-fonts-dir。
            expect(createdSession.activeSubFontsDir, isNotEmpty);
            final pool = container.read(subtitleFontPoolManagerProvider);
            expect(pool.activeLeaseHashes, isNotEmpty);
            final initialFontsDir = createdSession.activeSubFontsDir;

            // 2. 手动加载 GBK 外挂 ASS：经单一 SubtitleMemoryEngine 编码归一 + 云端子集化 + ASS [Fonts] 入池 + `cached` 挂载。
            ctrl.addExternalSubtitleFile(gbkSubFile.path);
            await Future<void>.delayed(const Duration(milliseconds: 220));

            expect(cloudPostCount, greaterThanOrEqualTo(1));
            expect(
              fakeClient.commands.any(
                (c) =>
                    c.length >= 3 &&
                    c[0] == 'sub-add' &&
                    c[1].startsWith('memory://') &&
                    c[1].contains('简体中文编码归一与云端子集测试') &&
                    c[1].contains('AB12CD+NotoSansCJK') &&
                    c[2] == 'cached',
              ),
              isTrue,
            );
            // 严禁直接裸路径直传 GBK 文本字幕或修改 sub-codepage。
            expect(
              fakeClient.commands.any(
                (c) => c.length >= 2 && c[0] == 'sub-add' && c[1] == gbkSubFile.path,
              ),
              isFalse,
            );
            expect(fakeClient.stringProps.containsKey('sub-codepage'), isFalse);
            // 云端返回 ASS 携带 [Fonts] UUE 字体入池后已刷新 sub-fonts-dir。
            expect(createdSession.activeSubFontsDir, isNot(equals(initialFontsDir)));
            expect(pool.activeLeaseHashes.length, greaterThanOrEqualTo(2));
          } finally {
            await ctrl.closeAndRelease();
            videoSub.close();
            await bridge.dispose();
            container.dispose();
            await db.close();
            await server.close(force: true);
            if (await tempDir.exists()) {
              await tempDir.delete(recursive: true);
            }
          }
        },
        _PassthroughHttpOverrides(),
      );
    });
  });

  group('批次 R4 [#4] 在线歌词并行竞速、伴奏短路、AMLL 按网易云 ID 直取与持久缓存', () {
    test('真实播放链路：移动计量网络下零弹窗直取 AMLL 逐字和声，不再下载全量索引，结果写入持久缓存', () async {
      final requestedUrls = <Uri>[];
      final mockHttp = MockClient((req) async {
        requestedUrls.add(req.url);
        if (req.url.host == 'lrclib.net') {
          return http.Response('[]', 200);
        }
        if (req.url.host == 'music.163.com' &&
            req.url.path.endsWith('/search/get')) {
          return http.Response.bytes(
            utf8.encode(
              jsonEncode({
                'result': {
                  'songs': [
                    {
                      'id': 777,
                      'name': 'Yusha',
                      'artists': [
                        {'name': 'YOASOBI'},
                      ],
                      'album': {'name': 'Yusha'},
                      'duration': 195000,
                    },
                  ],
                },
              }),
            ),
            200,
          );
        }
        if (req.url.host == 'music.163.com' &&
            req.url.path.endsWith('/song/lyric')) {
          return http.Response.bytes(
            utf8.encode(
              jsonEncode({
                'lrc': {
                  'lyric':
                      '[00:01.00]勇者の旅\n[00:05.00]終わらない物語\n[00:09.00]記憶の中に',
                },
              }),
            ),
            200,
          );
        }
        if (req.url.host == 'raw.githubusercontent.com' &&
            req.url.path.endsWith('/ncm-lyrics/777.ttml')) {
          const ttml = '''
<tt><body><div>
  <p begin="00:01.00" end="00:04.00">
    <span begin="00:01.00" end="00:02.00">勇者</span>
    <span begin="00:02.00" end="00:03.50">の旅</span>
    <span ttm:role="x-bg" begin="00:01.50" end="00:03.00">Ah~</span>
    <span ttm:role="x-translation">勇者之旅</span>
  </p>
  <p begin="00:05.00" end="00:08.00">
    <span begin="00:05.00" end="00:06.50">終わらない</span>
    <span begin="00:06.50" end="00:08.00">物語</span>
    <span ttm:role="x-translation">永不终结的故事</span>
  </p>
  <p begin="00:09.00" end="00:12.00">
    <span begin="00:09.00" end="00:10.50">記憶の</span>
    <span begin="00:10.50" end="00:12.00">中に</span>
    <span ttm:role="x-translation">铭刻在记忆中</span>
  </p>
</div></body></tt>
''';
          return http.Response.bytes(utf8.encode(ttml), 200);
        }
        return http.Response('not found', 404);
      });

      final engine = UnifiedPlaybackEngine();
      final db = KonataDatabase(NativeDatabase.memory());
      final repo = DriftLibraryRepository(db);
      final lyricCache = DriftLyricCacheRepository(db);
      final tempAudioRoot = await Directory.systemTemp.createTemp(
        'konata_r4_audio_',
      );
      final fakeAudioMpv = _R4FakeMpvClient();
      final container = ProviderContainer(
        overrides: [
          libraryRepositoryProvider.overrideWithValue(repo),
          storageRootProvider.overrideWithValue(
            StorageRootService(overrideRoot: tempAudioRoot),
          ),
          unifiedPlaybackEngineProvider.overrideWithValue(engine),
          lyricHttpTransportProvider.overrideWith(
            (ref) async => ClientLyricTransport(mockHttp),
          ),
          meteredNetworkDetectorProvider.overrideWithValue(
            MeteredNetworkDetector(overrideProbe: () async => true),
          ),
          lyricCacheRepositoryProvider.overrideWithValue(lyricCache),
          libraryItemsProvider.overrideWith((ref) async => const []),
          audioPlaybackProvider.overrideWith(
            () => AudioPlaybackNotifier(clientFactory: () => fakeAudioMpv),
          ),
        ],
      );
      final audioNotifier = container.read(audioPlaybackProvider.notifier);
      const work = Work(id: 'w_frieren', title: 'Frieren');
      const variant = MediaVariant(
        id: 'cd_yusha',
        workId: 'w_frieren',
        sourceId: 'none',
        relativePath: '01_Yusha.flac',
        fileName: '01_Yusha.flac',
        fileSize: 1024,
        assetKind: AssetKind.cdAlbum,
      );
      try {
        await audioNotifier.playCdCollection(
          work: work,
          cdVariants: const [variant],
          initialVariant: variant,
          sourcesById: const {},
        );
        await Future<void>.delayed(const Duration(milliseconds: 900));

        final audioState = container.read(audioPlaybackProvider);
        expect(audioState.activeLyricSource, equals(LyricSource.amll));
        expect(audioState.isLyricLookupInFlight, isFalse);
        expect(audioState.lrcDocument, isNotNull);
        expect(
          audioState.lrcDocument!.lines.first.secondaryLines,
          contains('勇者之旅'),
        );
        expect(audioState.activeSpanLines, isNotEmpty);
        expect(
          audioState.activeSpanLines.first.spans.any((s) => s.isHarmony),
          isTrue,
        );
        // 只按 ID 直取单首 TTML，严禁再下载 AMLL 全量索引。
        expect(
          requestedUrls.any((u) => u.path.endsWith('/ncm-lyrics/777.ttml')),
          isTrue,
        );
        expect(
          requestedUrls.any((u) => u.path.contains('raw-lyrics-index')),
          isFalse,
        );

        final cachedRows = await db.select(db.lyricCacheEntries).get();
        expect(cachedRows, hasLength(1));
        expect(cachedRows.single.source, equals(LyricSource.amll));
      } finally {
        container.dispose();
        await db.close();
        if (await tempAudioRoot.exists()) {
          await tempAudioRoot.delete(recursive: true);
        }
      }
    });
  });
}

class _PassthroughHttpOverrides extends HttpOverrides {}
