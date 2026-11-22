import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:konata/application/playback/audio_playback_notifier.dart';
import 'package:konata/application/playback/subtitle_memory_engine.dart';
import 'package:konata/application/playback/video_playback_controller.dart';
import 'package:konata/application/providers/library_providers.dart';
import 'package:konata/application/providers/playback_providers.dart';
import 'package:konata/domain/models/episode.dart';
import 'package:konata/domain/models/media_source.dart';
import 'package:konata/domain/models/media_variant.dart';
import 'package:konata/domain/models/work.dart';
import 'package:konata/domain/playback/audiophile_safety_policy.dart';
import 'package:konata/domain/playback/playback_probe_stats.dart';
import 'package:konata/domain/playback/subtitle_content_processor.dart';
import 'package:konata/domain/playback/subtitle_timeline_remapper.dart';
import 'package:konata/domain/playback/track_preferences.dart';
import 'package:konata/domain/repositories/file_system_gateway.dart';
import 'package:konata/infrastructure/database/drift_library_repository.dart';
import 'package:konata/infrastructure/database/konata_database.dart';
import 'package:konata/infrastructure/players/embedded_mpv_session.dart';
import 'package:konata/infrastructure/players/libmpv_ffi.dart';
import 'package:konata/infrastructure/players/mpv_quality_profile.dart';
import 'package:konata/infrastructure/players/playback_probe.dart';
import 'package:konata/infrastructure/players/windows_mpv_profile_adapter.dart';
import 'package:konata/infrastructure/sources/byte_stream_source_gateway.dart';
import 'package:konata/infrastructure/sources/source_gateway_factory.dart';
import 'package:konata/infrastructure/sources/webdav_source_gateway.dart';
import 'package:konata/infrastructure/storage/storage_root_provider.dart';
import 'package:konata/infrastructure/stream_bridge/local_stream_bridge.dart';
import 'package:konata/infrastructure/stream_bridge/remote_window_reader.dart';
import 'package:konata/infrastructure/subtitles/subtitle_font_pool_manager.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

Uint8List _buildSingleFileStoredZip(String fileName, Uint8List payload) {
  final nameBytes = utf8.encode(fileName);
  final out = BytesBuilder(copy: false);
  void u16(int v) => out.add([v & 0xFF, (v >> 8) & 0xFF]);
  void u32(int v) => out.add([
    v & 0xFF,
    (v >> 8) & 0xFF,
    (v >> 16) & 0xFF,
    (v >> 24) & 0xFF,
  ]);
  // 本地文件头
  u32(0x04034B50);
  u16(20);
  u16(0);
  u16(0); // 无压缩存储方式
  u16(0);
  u16(0);
  u32(0); // 校验和占位
  u32(payload.length);
  u32(payload.length);
  u16(nameBytes.length);
  u16(0);
  out.add(nameBytes);
  out.add(payload);
  final cdOffset = out.length;
  // 中央目录文件头
  u32(0x02014B50);
  u16(20);
  u16(20);
  u16(0);
  u16(0);
  u16(0);
  u16(0);
  u32(0);
  u32(payload.length);
  u32(payload.length);
  u16(nameBytes.length);
  u16(0);
  u16(0);
  u16(0);
  u16(0);
  u32(0);
  u32(0);
  out.add(nameBytes);
  final cdSize = out.length - cdOffset;
  // 中央目录结束记录
  u32(0x06054B50);
  u16(0);
  u16(0);
  u16(1);
  u16(1);
  u32(cdSize);
  u32(cdOffset);
  u16(0);
  return out.toBytes();
}

class _PerfFakeMpvClient implements LibMpvClient, LibMpvUnobservable {
  final StreamController<MpvClientEvent> _events =
      StreamController<MpvClientEvent>.broadcast();
  final Map<String, String> options = {};
  final Map<String, String> stringProps = {
    'video-codec': 'hevc',
    'video-format': 'hevc',
    'video-params/pixelformat': 'p010le',
    'hwdec-current': 'd3d11va',
    'track-list': '[]',
    'chapter-list': '[]',
    'audio-device-list': '[]',
    'demuxer-cache-state': '{}',
  };
  final Map<String, int> intProps = {
    'video-params/w': 1920,
    'video-params/h': 1080,
  };
  final Map<String, double> doubleProps = {'time-pos': 0.0, 'duration': 1420.0};
  final Map<String, bool> flagProps = {'pause': false, 'mute': false};
  final List<List<String>> syncCommands = [];
  final List<List<String>> asyncCommands = [];
  final List<MpvTrackInfo> _tracks = [];
  int _nextTrackId = 1;
  int propertyGetCount = 0;
  bool _initialized = false;
  bool _disposed = false;

  void emit(MpvClientEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  @override
  bool get isDisposed => _disposed;

  @override
  bool get isInitialized => _initialized;

  @override
  int get handleAddress => 0x5555;

  @override
  Stream<MpvClientEvent> get events => _events.stream;

  @override
  int setOptionString(String name, String value) {
    options[name] = value;
    return 0;
  }

  @override
  int initialize() {
    _initialized = true;
    return 0;
  }

  @override
  int command(List<String> args) {
    syncCommands.add(List<String>.from(args));
    if (args.isNotEmpty && args.first == 'sub-add') {
      final id = _nextTrackId++;
      _tracks.add(
        MpvTrackInfo(
          id: id,
          type: MpvTrackType.subtitle,
          title: args.length > 3 ? args[3] : 'sub_$id',
          isExternal: true,
          externalFilename: args.length > 1 ? args[1] : null,
        ),
      );
    }
    return 0;
  }

  @override
  int commandAsync(int replyUserdata, List<String> args) {
    asyncCommands.add(List<String>.from(args));
    return 0;
  }

  @override
  int setPropertyString(String name, String value) {
    stringProps[name] = value;
    return 0;
  }

  @override
  int setPropertyInt64(String name, int value) {
    intProps[name] = value;
    return 0;
  }

  @override
  int setPropertyDouble(String name, double value) {
    doubleProps[name] = value;
    return 0;
  }

  @override
  int setPropertyFlag(String name, bool value) {
    flagProps[name] = value;
    return 0;
  }

  @override
  String? getPropertyString(String name) {
    propertyGetCount += 1;
    return stringProps[name];
  }

  @override
  int? getPropertyInt64(String name) {
    propertyGetCount += 1;
    return intProps[name];
  }

  @override
  double? getPropertyDouble(String name) {
    propertyGetCount += 1;
    return doubleProps[name];
  }

  @override
  bool? getPropertyFlag(String name) {
    propertyGetCount += 1;
    return flagProps[name];
  }

  @override
  int observeProperty(int replyUserdata, String name, int format) => 0;

  @override
  int unobserveProperty(int registeredReplyUserdata) => 0;

  @override
  int requestLogMessages(String minLevel) => 0;

  @override
  String errorString(int errorCode) => 'err($errorCode)';

  @override
  List<MpvSeekableRange> readDemuxerSeekableRanges() => const [];

  @override
  List<MpvTrackInfo> readTrackList() => List<MpvTrackInfo>.of(_tracks);

  @override
  List<PlaybackChapter> readChapterList({double? totalDurationSeconds}) =>
      const [];

  @override
  List<MpvAudioDevice> readAudioDeviceList() => const [];

  @override
  Future<void> dispose() async {
    _disposed = true;
    await _events.close();
  }
}

class _ValidatedMemoryGateway
    implements MediaSourceGateway, ValidatedByteRangeGateway {
  _ValidatedMemoryGateway(this.files);

  final Map<String, Uint8List> files;
  static const String etag = '"perf-etag-v1"';
  final List<(int, int?)> requestedRanges = [];
  bool closed = false;

  @override
  Future<List<RemoteEntry>> listDirectory(String relativePath) async =>
      const [];

  @override
  Future<String?> readTextFile(
    String relativePath, {
    int maxBytes = 256 * 1024,
  }) async => null;

  @override
  Future<String?> testConnection() async => null;

  @override
  Future<int?> probeFileLength(String relativePath) async =>
      files[relativePath]?.length;

  @override
  Future<ValidatedByteRangeStream> openValidatedByteRange(
    String relativePath, {
    required int start,
    int? endInclusive,
    String? expectedStrongValidator,
  }) async {
    requestedRanges.add((start, endInclusive));
    final data = files[relativePath];
    if (data == null) {
      throw PathNotFoundException(relativePath, const OSError('not found', 2));
    }
    final actualEnd = (endInclusive ?? (data.length - 1)).clamp(
      start,
      data.length - 1,
    );
    final slice = Uint8List.sublistView(data, start, actualEnd + 1);
    return ValidatedByteRangeStream(
      stream: Stream<List<int>>.fromIterable(<List<int>>[slice]),
      start: start,
      endInclusive: actualEnd,
      totalLength: data.length,
      strongValidator: etag,
      isPartialContent: true,
    );
  }

  @override
  Future<Stream<List<int>>> openByteRange(
    String relativePath, {
    required int start,
    int? endInclusive,
  }) async {
    final v = await openValidatedByteRange(
      relativePath,
      start: start,
      endInclusive: endInclusive,
    );
    return v.stream;
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

class _FixedGatewayFactory extends MediaSourceGatewayFactory {
  _FixedGatewayFactory(this.gatewayBuilder);

  final MediaSourceGateway Function(MediaSource source) gatewayBuilder;

  @override
  Future<MediaSourceGateway> create(
    MediaSource source, {
    String? passwordOverride,
    bool clearPassword = false,
  }) async => gatewayBuilder(source);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    HttpOverrides.global = null;
  });

  group('第一批：轻量探针、微任务合并、高频叶子信道与后台 Isolate 卸载', () {
    test('PlaybackProbeCollector.collectLight 仅读 <= 6 次属性并完整保留顶栏 5 项规格', () {
      final client = _PerfFakeMpvClient()..initialize();
      const collector = PlaybackProbeCollector();

      client.propertyGetCount = 0;
      final light = collector.collectLight(client, gpuApiOverride: 'd3d11_fp16');
      final lightGets = client.propertyGetCount;

      client.propertyGetCount = 0;
      final full = collector.collect(client, gpuApiOverride: 'd3d11_fp16');
      final fullGets = client.propertyGetCount;

      expect(lightGets, lessThanOrEqualTo(6));
      expect(fullGets, greaterThanOrEqualTo(50));
      expect(light.videoWidth, equals(1920));
      expect(light.videoHeight, equals(1080));
      expect(light.videoCodec, equals('hevc'));
      expect(light.videoPixelFormat, equals('p010le'));
      expect(light.hwdecCurrent, equals('d3d11va'));
      expect(light.gpuApi, equals('d3d11_fp16'));
      expect(full.videoWidth, equals(light.videoWidth));
    });

    test('EmbeddedMpvSession 同一事件轮次内突发多条被动元数据事件合并为单次快照回调', () async {
      final tempDir = await Directory.systemTemp.createTemp('konata_coalesce_');
      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });
      final storage = StorageRootService(overrideRoot: tempDir);
      final bridge = LocalStreamBridge(storageRoot: storage);
      addTearDown(bridge.dispose);
      final fakeClient = _PerfFakeMpvClient();
      final session = EmbeddedMpvSession(
        storageRoot: storage,
        streamBridge: bridge,
        clientFactory: () => fakeClient,
      );
      var snapshotCallbacks = 0;
      session.onMediaMetadataUpdated =
          ({
            required subtitles,
            required audioTracks,
            required chapters,
            required audioDevices,
          }) {
            snapshotCallbacks += 1;
          };

      final videoFile = File(p.join(tempDir.path, 'ep01.mkv'))
        ..writeAsBytesSync(const [0, 1, 2, 3]);
      final source = MediaSource(
        id: 'src_loc',
        label: '本地',
        kind: MediaSourceKind.local,
        location: tempDir.path,
      );
      final variant = MediaVariant(
        id: 'v1',
        workId: 'w1',
        sourceId: source.id,
        relativePath: p.basename(videoFile.path),
        fileName: p.basename(videoFile.path),
        fileSize: 4,
      );
      await session.initializeAndLoad(
        request: EmbeddedVideoLoadRequest(
          workId: 'w1',
          variant: variant,
          source: source,
        ),
        qualityConfig: const PlaybackQualityConfig(),
      );
      snapshotCallbacks = 0;

      // 连续发射 6 条被动元数据变更事件（含 track-list/count=210, aid=208, sid=209），合流后仅派发 1 次快照。
      fakeClient.emit(const MpvVideoReconfigEvent());
      fakeClient.emit(const MpvAudioReconfigEvent());
      fakeClient.emit(
        const MpvPropertyChangeEvent(
          replyUserdata: 210,
          name: 'track-list/count',
          format: MpvFormat.int64,
          intValue: 3,
        ),
      );
      fakeClient.emit(
        const MpvPropertyChangeEvent(
          replyUserdata: 202,
          name: 'duration',
          format: MpvFormat.double_,
          doubleValue: 1420.0,
        ),
      );
      fakeClient.emit(
        const MpvPropertyChangeEvent(
          replyUserdata: 208,
          name: 'aid',
          format: MpvFormat.string,
          stringValue: '1',
        ),
      );
      fakeClient.emit(
        const MpvPropertyChangeEvent(
          replyUserdata: 209,
          name: 'sid',
          format: MpvFormat.string,
          stringValue: '1',
        ),
      );

      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(snapshotCallbacks, equals(1));
      await session.dispose();
    });

    test('SubtitleMemoryEngine 与 SubtitleFontPoolManager 对 >= 64 KiB 负载转入后台 Isolate 且结果完全保真', () async {
      final tempDir = await Directory.systemTemp.createTemp('konata_iso_sub_');
      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });
      final storage = StorageRootService(overrideRoot: tempDir);
      final fontMgr = SubtitleFontPoolManager(storageRoot: storage);

      // 1. 构造 > 64 KiB 繁体 ASS 字幕，校验 OpenCC + 时间轴偏移结果正确。
      final sb = StringBuffer()
        ..writeln('[Script Info]')
        ..writeln('Title: Isolate Test')
        ..writeln('[Events]')
        ..writeln(
          'Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text',
        );
      for (var i = 0; i < 1600; i++) {
        sb.writeln(
          'Dialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,測試繁體字幕行_$i',
        );
      }
      final subFile = File(p.join(tempDir.path, 'large_tc.ass'));
      await subFile.writeAsBytes(utf8.encode(sb.toString()), flush: true);
      expect(await subFile.length(), greaterThanOrEqualTo(64 * 1024));

      final subClient = _PerfFakeMpvClient()..initialize();
      final engine = SubtitleMemoryEngine(clientSupplier: () => subClient);
      final applied = await engine.applyIntent(
        AuthoritativeSubtitleIntent(
          primary: SubtitleSlotRequest.memory(
            loadBytes: subFile.readAsBytes,
            fileName: 'large_tc.ass',
            openCcMode: SubtitleOpenCcMode.toSimplified,
            timelineTransform: const SubtitleTimelineTransform(
              offsetSeconds: 2.0,
              rateScale: 1.0,
            ),
          ),
        ),
      );
      expect(applied.applied, isTrue);
      final subAddCmd = subClient.syncCommands.firstWhere(
        (cmd) => cmd.isNotEmpty && cmd.first == 'sub-add',
      );
      final capturedUri = subAddCmd[1];
      expect(capturedUri, startsWith('memory://'));
      final rendered = capturedUri.substring('memory://'.length);
      expect(rendered, contains('测试繁体字幕行_0'));
      expect(rendered, contains('0:00:03.00,0:00:05.00'));
      engine.dispose();
      await subClient.dispose();

      // 2. 构造 > 64 KiB 含合法 TrueType 魔数的 Fonts.zip，校验 Isolate 解包入池。
      final ttfBytes = Uint8List(96 * 1024)
        ..[0] = 0x00
        ..[1] = 0x01
        ..[2] = 0x00
        ..[3] = 0x00;
      final zipBytes = _buildSingleFileStoredZip('TestFont.ttf', ttfBytes);
      final ingested = await fontMgr.ingestFontZipBytes(zipBytes);
      expect(ingested.fontCount, equals(1));
      expect(await Directory(ingested.directoryPath).exists(), isTrue);
    });

    test('AudioPlaybackNotifier 60Hz 高频进度仅更新 positionListenable，整秒边界才触发 Riverpod 状态扇出', () async {
      SharedPreferences.setMockInitialValues({});
      final tempDir = await Directory.systemTemp.createTemp('konata_audio_60_');
      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });
      final flac = File(p.join(tempDir.path, '01.flac'))
        ..writeAsBytesSync(const [0x66, 0x4C, 0x61, 0x43, 0, 0]);
      final fakeClient = _PerfFakeMpvClient();
      final db = KonataDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final storage = StorageRootService(overrideRoot: tempDir);
      final bridge = LocalStreamBridge(storageRoot: storage);
      addTearDown(bridge.dispose);

      final container = ProviderContainer(
        overrides: [
          libraryRepositoryProvider.overrideWithValue(DriftLibraryRepository(db)),
          storageRootProvider.overrideWithValue(storage),
          localStreamBridgeProvider.overrideWithValue(bridge),
          audioPlaybackProvider.overrideWith(
            () => AudioPlaybackNotifier(clientFactory: () => fakeClient),
          ),
        ],
      );
      addTearDown(container.dispose);

      var riverpodStateUpdates = 0;
      final sub = container.listen(
        audioPlaybackProvider,
        (_, _) => riverpodStateUpdates += 1,
      );
      addTearDown(sub.close);

      final notifier = container.read(audioPlaybackProvider.notifier);
      var leafTicks = 0;
      notifier.positionListenable.addListener(() => leafTicks += 1);

      const work = Work(id: 'w_a', title: '音乐集');
      final source = MediaSource(
        id: 's_a',
        label: '本地',
        kind: MediaSourceKind.local,
        location: tempDir.path,
      );
      final variant = MediaVariant(
        id: 'v_a',
        workId: 'w_a',
        sourceId: 's_a',
        relativePath: p.basename(flac.path),
        fileName: p.basename(flac.path),
        fileSize: 6,
      );
      await notifier.playCdCollection(
        work: work,
        cdVariants: [variant],
        initialVariant: variant,
        sourcesById: {'s_a': source},
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      riverpodStateUpdates = 0;
      leafTicks = 0;

      // 连续发射 60 次亚秒级进度推进（10.01 -> 10.60），全部在同一整秒内。
      for (var i = 1; i <= 60; i++) {
        fakeClient.emit(
          MpvPropertyChangeEvent(
            replyUserdata: 101,
            name: 'time-pos',
            format: MpvFormat.double_,
            doubleValue: 10.0 + i * 0.01,
          ),
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(leafTicks, equals(60));
      expect(notifier.currentPositionSeconds, closeTo(10.60, 1e-4));
      // 同一整秒区间仅首次跨越整秒 0->10 触发 1 次 Riverpod state 变更，其余 59 次零扇出。
      expect(riverpodStateUpdates, lessThanOrEqualTo(2));
      await notifier.stopAndClose();
    });
  });

  group('第二批：WebDAV 302 直链缓存、自适应顺读窗与视频下一集预热', () {
    test('WebDavSourceGateway 复用 302 CDN 直链、跨源不泄漏鉴权，并在 CDN 返回 403 后立即驱逐回源', () async {
      final payload = Uint8List.fromList(List<int>.generate(4096, (i) => i % 251));
      var originHits = 0;
      var cdnV1Hits = 0;
      var cdnV2Hits = 0;
      var cdnV1Expired = false;
      String? leakedAuthHeader;

      final cdnServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => cdnServer.close(force: true));
      cdnServer.listen((req) async {
        final auth = req.headers.value(HttpHeaders.authorizationHeader);
        if (auth != null) {
          leakedAuthHeader = auth;
        }
        if (req.uri.path == '/cdn-v1' && cdnV1Expired) {
          req.response.statusCode = HttpStatus.forbidden;
          await req.response.close();
          return;
        }
        if (req.uri.path == '/cdn-v1') {
          cdnV1Hits += 1;
        } else {
          cdnV2Hits += 1;
        }
        final m = RegExp(r'bytes=(\d+)-(\d+)').firstMatch(
          req.headers.value(HttpHeaders.rangeHeader) ?? '',
        );
        final s = int.parse(m!.group(1)!);
        final e = int.parse(m.group(2)!);
        req.response.statusCode = HttpStatus.partialContent;
        req.response.headers.set(HttpHeaders.etagHeader, '"cdn-etag-1"');
        req.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $s-$e/${payload.length}',
        );
        req.response.contentLength = e - s + 1;
        req.response.add(payload.sublist(s, e + 1));
        await req.response.close();
      });

      final originServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => originServer.close(force: true));
      originServer.listen((req) async {
        originHits += 1;
        req.response.statusCode = HttpStatus.found;
        final cdnPath = cdnV1Expired ? '/cdn-v2' : '/cdn-v1';
        req.response.headers.set(
          HttpHeaders.locationHeader,
          'http://127.0.0.1:${cdnServer.port}$cdnPath',
        );
        await req.response.close();
      });

      final gw = WebDavSourceGateway(
        rootUri: Uri.parse('http://127.0.0.1:${originServer.port}/dav/'),
        username: 'konata',
        password: 'secret-password',
      );
      addTearDown(gw.close);

      // 第 1 次读取经源站 302 获取 CDN-v1。
      final r1 = await gw.openValidatedByteRange('ep01.mkv', start: 0, endInclusive: 1023);
      final b1 = await r1.stream.expand((c) => c).toList();
      expect(b1, payload.sublist(0, 1024));
      expect(originHits, equals(1));
      expect(cdnV1Hits, equals(1));

      // 第 2 次读取直接命中短 TTL 缓存直连 CDN-v1，不再打源站。
      final r2 = await gw.openValidatedByteRange('ep01.mkv', start: 1024, endInclusive: 2047);
      final b2 = await r2.stream.expand((c) => c).toList();
      expect(b2, payload.sublist(1024, 2048));
      expect(originHits, equals(1));
      expect(cdnV1Hits, equals(2));

      // 模拟 CDN-v1 签名过期返回 403 -> 自动驱逐缓存、回源重新 302 到 CDN-v2。
      cdnV1Expired = true;
      final r3 = await gw.openValidatedByteRange('ep01.mkv', start: 2048, endInclusive: 3071);
      final b3 = await r3.stream.expand((c) => c).toList();
      expect(b3, payload.sublist(2048, 3072));
      expect(originHits, equals(2));
      expect(cdnV2Hits, equals(1));
      expect(leakedAuthHeader, isNull);
    });

    test('RemoteWindowReader 对超大文件执行 1->4->8 MiB 顺序扩张，并在 Seek 后立即回落 4 MiB', () async {
      const mib = 1024 * 1024;
      final data = Uint8List(32 * mib);
      for (var i = 0; i < data.length; i += 4096) {
        data[i] = (i ~/ 4096) % 251;
      }
      final gw = _ValidatedMemoryGateway({'Big/01.mkv': data});
      final reader = RemoteWindowReader(
        gateway: gw,
        relativePath: 'Big/01.mkv',
        totalLength: data.length,
      );

      final totalRead = await reader
          .read(start: 0, endInclusive: data.length - 1)
          .fold<int>(0, (acc, chunk) => acc + chunk.length);
      expect(totalRead, equals(data.length));
      // 1 MiB + 4 MiB + 8 MiB + 8 MiB + 8 MiB + 3 MiB = 6 次请求，单窗封顶 8 MiB 控制峰值内存。
      expect(gw.requestedRanges.length, equals(6));
      expect(gw.requestedRanges[0], equals((0, mib - 1)));
      expect(gw.requestedRanges[1], equals((mib, 5 * mib - 1)));
      expect(gw.requestedRanges[2], equals((5 * mib, 13 * mib - 1)));
      expect(gw.requestedRanges[3], equals((13 * mib, 21 * mib - 1)));
      expect(gw.requestedRanges[4], equals((21 * mib, 29 * mib - 1)));
      expect(gw.requestedRanges[5], equals((29 * mib, 32 * mib - 1)));

      // 随机 Seek 到 10 MiB 仅读取 100 KiB：立即从 4 MiB 起步（并严格钳制到 endInclusive）。
      gw.requestedRanges.clear();
      final seekBytes = await reader
          .read(start: 10 * mib, endInclusive: 10 * mib + 1023)
          .expand((c) => c)
          .toList();
      expect(seekBytes.length, equals(1024));
      expect(gw.requestedRanges, equals([(10 * mib, 10 * mib + 1023)]));
    });

    test('LocalStreamBridge.prewarmSessionMetadata 预热首尾元数据且远程 2x 倍速动态扩容 demuxer-readahead-secs', () async {
      final gw = _ValidatedMemoryGateway({
        'Remote/02.mkv': Uint8List(4 * 1024 * 1024),
      });
      final bridge = LocalStreamBridge();
      addTearDown(bridge.dispose);

      final reg = await bridge.registerSession(
        gateway: gw,
        relativePath: 'Remote/02.mkv',
        fileName: '02.mkv',
        knownLength: 4 * 1024 * 1024,
        ownsGateway: false,
      );
      final ok = await bridge.prewarmSessionMetadata(
        reg.token,
        headBytes: 256 * 1024,
        tailBytes: 128 * 1024,
      );
      expect(ok, isTrue);
      expect(gw.requestedRanges.length, equals(2));
      expect(gw.requestedRanges.first.$1, equals(0));
      expect(gw.requestedRanges.last.$2, equals(4 * 1024 * 1024 - 1));

      // 验证动态预读秒数策略与 EmbeddedMpvSession.setSpeed 联动。
      expect(
        MpvQualityProfile.resolveDemuxerReadaheadSecs(
          playbackSpeed: 1.0,
          isRemoteStream: true,
          isAndroid: false,
        ),
        equals(15),
      );
      expect(
        MpvQualityProfile.resolveDemuxerReadaheadSecs(
          playbackSpeed: 2.0,
          isRemoteStream: true,
          isAndroid: false,
        ),
        equals(30),
      );
      expect(
        MpvQualityProfile.resolveDemuxerReadaheadSecs(
          playbackSpeed: 2.0,
          isRemoteStream: true,
          isAndroid: true,
        ),
        equals(24),
      );
    });

    test('VideoPlaybackController 后段静默预热下一集远程流并在切集时无缝接管，关闭即清理', () async {
      SharedPreferences.setMockInitialValues({});
      final tempDir = await Directory.systemTemp.createTemp('konata_prewarm_');
      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });
      final db = KonataDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final storage = StorageRootService(overrideRoot: tempDir);
      final bridge = LocalStreamBridge(storageRoot: storage);
      addTearDown(bridge.dispose);
      final fakeClient = _PerfFakeMpvClient();
      final remoteFiles = {
        'Anime/01.mkv': Uint8List(2 * 1024 * 1024),
        'Anime/02.mkv': Uint8List(2 * 1024 * 1024),
      };
      final source = MediaSource(
        id: 'src_dav',
        label: '远端',
        kind: MediaSourceKind.webdav,
        location: 'https://example.invalid/dav',
      );
      const work = Work(id: 'w_pre', title: '预热番剧');
      const ep1 = Episode(
        id: 'e1',
        workId: 'w_pre',
        seasonNumber: 1,
        episodeNumber: 1,
      );
      const ep2 = Episode(
        id: 'e2',
        workId: 'w_pre',
        seasonNumber: 1,
        episodeNumber: 2,
      );
      const v1 = MediaVariant(
        id: 'v1',
        workId: 'w_pre',
        episodeId: 'e1',
        sourceId: 'src_dav',
        relativePath: 'Anime/01.mkv',
        fileName: '01.mkv',
        fileSize: 2 * 1024 * 1024,
      );
      const v2 = MediaVariant(
        id: 'v2',
        workId: 'w_pre',
        episodeId: 'e2',
        sourceId: 'src_dav',
        relativePath: 'Anime/02.mkv',
        fileName: '02.mkv',
        fileSize: 2 * 1024 * 1024,
      );
      final bundle = WorkDetailBundle(
        work: work,
        episodes: const [ep1, ep2],
        variants: const [v1, v2],
        sourcesById: {'src_dav': source},
        latestPlayback: null,
      );
      final req = VideoLaunchRequest(
        work: work,
        episode: ep1,
        variant: v1,
        bundle: bundle,
        source: source,
      );
      final repo = DriftLibraryRepository(db);
      await repo.upsertMediaSource(source);
      await repo.upsertWork(work);
      await repo.upsertEpisode(ep1);
      await repo.upsertEpisode(ep2);
      await repo.upsertMediaVariant(v1);
      await repo.upsertMediaVariant(v2);

      final gwFactory = _FixedGatewayFactory(
        (_) => _ValidatedMemoryGateway(remoteFiles),
      );
      final container = ProviderContainer(
        overrides: [
          libraryRepositoryProvider.overrideWithValue(repo),
          storageRootProvider.overrideWithValue(storage),
          localStreamBridgeProvider.overrideWithValue(bridge),
          mediaSourceGatewayFactoryProvider.overrideWithValue(gwFactory),
          videoPlaybackProvider(req).overrideWith(
            () => VideoPlaybackController(
              req,
              sessionFactory: () => EmbeddedMpvSession(
                storageRoot: storage,
                streamBridge: bridge,
                gatewayFactory: gwFactory,
                clientFactory: () => fakeClient,
              ),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      final sub = container.listen(videoPlaybackProvider(req), (_, _) {});
      addTearDown(sub.close);
      final ctrl = container.read(videoPlaybackProvider(req).notifier);

      await Future<void>.delayed(const Duration(milliseconds: 30));
      fakeClient.emit(const MpvFileLoadedEvent());
      fakeClient.emit(const MpvPlaybackRestartEvent());
      fakeClient.emit(
        const MpvPropertyChangeEvent(
          replyUserdata: 202,
          name: 'duration',
          format: MpvFormat.double_,
          doubleValue: 1400.0,
        ),
      );
      fakeClient.emit(
        const MpvPropertyChangeEvent(
          replyUserdata: 203,
          name: 'pause',
          format: MpvFormat.flag,
          boolValue: false,
        ),
      );
      fakeClient.emit(
        const MpvPropertyChangeEvent(
          replyUserdata: 204,
          name: 'paused-for-cache',
          format: MpvFormat.flag,
          boolValue: false,
        ),
      );
      // 推进播放到 80%（1120s / 1400s），自动触发下一集静默预热。
      fakeClient.emit(
        const MpvPropertyChangeEvent(
          replyUserdata: 201,
          name: 'time-pos',
          format: MpvFormat.double_,
          doubleValue: 1120.0,
        ),
      );
      for (var i = 0; i < 40 && ctrl.prewarmedNextEpisodeId == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 15));
      }
      expect(ctrl.prewarmedNextEpisodeId, equals('e2'));

      // 切换至下一集时接管预热会话并清空暂存槽位。
      await ctrl.switchToEpisode(ep2);
      expect(ctrl.prewarmedNextEpisodeId, isNull);

      // 测试远程 2x 倍速动态写入 demuxer-readahead-secs = 30，还原后回到 15。
      ctrl.startSpeedBoost();
      expect(fakeClient.intProps['demuxer-readahead-secs'], equals(30));
      ctrl.endSpeedBoost();
      expect(fakeClient.intProps['demuxer-readahead-secs'], equals(15));

      await ctrl.closeAndRelease();
    });
  });

  group('第三批：零 af 常规共享音频策略、Windows 独占源格式直出与 Android 零拷贝硬解', () {
    test('AudiophileSafetyPolicy 常规无 DSP 共享零 af 直出并保留 150ms 微淡入，有 DSP 或未解锁独占仍挂 -12 dBFS', () {
      const unverified = AudioDeviceSafetyState(
        deviceFingerprint: 'default',
        isBackendMeterVerified: false,
      );

      // 1. 常规共享无用户 DSP -> 零 af、零限幅、保留 150ms S 型微淡入。
      final cleanShared = AudiophileSafetyPolicy.buildPlan(
        requestedMode: AudioOutputRouteMode.sharedResampled,
        safetyState: unverified,
      );
      expect(cleanShared.audioFilterString, isEmpty);
      expect(cleanShared.safetyLimiterEngaged, isFalse);
      expect(cleanShared.microFadeInDurationMs, equals(150));

      // 2. 共享模式挂载正向增益 EQ DSP -> 强制在链尾串联 -12 dBFS 限幅。
      final dspShared = AudiophileSafetyPolicy.buildPlan(
        requestedMode: AudioOutputRouteMode.sharedResampled,
        safetyState: unverified,
        upstreamDspFilters: const ['equalizer=f=80:g=6'],
      );
      expect(dspShared.safetyLimiterEngaged, isTrue);
      expect(
        dspShared.audioFilterString,
        endsWith(AudiophileSafetyPolicy.postDspSafetyLimiterFilter),
      );

      // 3. 请求独占但未实证/未解锁 -> 强制挂载 -12 dBFS 限幅防炸耳。
      final lockedExclusive = AudiophileSafetyPolicy.buildPlan(
        requestedMode: AudioOutputRouteMode.exclusiveAudioOutput,
        safetyState: unverified,
      );
      expect(lockedExclusive.safetyLimiterEngaged, isTrue);
      expect(
        lockedExclusive.audioFilterString,
        equals(AudiophileSafetyPolicy.postDspSafetyLimiterFilter),
      );
    });

    test('Windows 独占模式显式配置 audio-samplerate=0 与 audio-format=no 保持源格式直出', () {
      final client = _PerfFakeMpvClient();
      const delegate = WindowsMpvProfileDelegate();
      const setter = MpvSafePropertySetter();
      delegate.applyDesktopAudioExclusivePreInit(
        client,
        setter,
        const PlaybackQualityConfig(exclusiveAudioOutput: true),
      );
      expect(client.options['audio-exclusive'], equals('yes'));
      expect(client.options['audio-samplerate'], equals('0'));
      expect(client.options['audio-format'], equals('no'));
    });

    test('Android 硬件解码默认策略升级为 mediacodec,mediacodec-copy,auto-safe 零拷贝优先', () {
      expect(
        MpvQualityProfile.resolveHwdecValue(
          config: const PlaybackQualityConfig(),
          isWindows: false,
          isAndroid: true,
        ),
        equals('mediacodec,mediacodec-copy,auto-safe'),
      );
    });
  });
}
