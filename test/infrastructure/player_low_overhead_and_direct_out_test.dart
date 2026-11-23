import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:konata/application/playback/audio_playback_notifier.dart';
import 'package:konata/application/playback/audiophile_safety_coordinator.dart';
import 'package:konata/application/playback/playback_preferences_provider.dart';
import 'package:konata/application/playback/unified_playback_engine.dart';
import 'package:konata/application/playback/video_playback_controller.dart';
import 'package:konata/application/providers/library_providers.dart';
import 'package:konata/application/providers/playback_providers.dart';
import 'package:konata/domain/models/episode.dart';
import 'package:konata/domain/models/media_source.dart';
import 'package:konata/domain/models/media_variant.dart';
import 'package:konata/domain/models/work.dart';
import 'package:konata/domain/playback/playback_probe_stats.dart';
import 'package:konata/domain/playback/track_preferences.dart';
import 'package:konata/infrastructure/cache/album_cover_compactor.dart';
import 'package:konata/infrastructure/database/drift_library_repository.dart';
import 'package:konata/infrastructure/database/konata_database.dart';
import 'package:konata/infrastructure/logging/diagnostics_log_store.dart';
import 'package:konata/infrastructure/players/android/android_audio_route_bridge.dart';
import 'package:konata/infrastructure/players/libmpv_ffi.dart';
import 'package:konata/infrastructure/players/mpv_quality_profile.dart';
import 'package:konata/infrastructure/players/mpv_thumbnail_service.dart';
import 'package:konata/infrastructure/players/windows_mpv_profile_adapter.dart';
import 'package:konata/infrastructure/sources/byte_stream_source_gateway.dart';
import 'package:konata/infrastructure/storage/storage_root_provider.dart';
import 'package:konata/infrastructure/storage/temp_cache_pruner.dart';
import 'package:konata/infrastructure/stream_bridge/local_stream_bridge.dart';
import 'package:konata/infrastructure/stream_bridge/remote_window_reader.dart';
import 'package:konata/presentation/theme/konata_playback_tokens.dart';
import 'package:konata/presentation/theme/konata_theme.dart';
import 'package:konata/presentation/video/video_hardware_surface.dart';
import 'package:konata/presentation/widgets/playback/konata_audiophile_unlock_dialog.dart';

/// 面向低开销与原画/原音直出回归验证的可观测模拟 `libmpv` 客户端。
class _LowOverheadFakeMpvClient implements LibMpvClient, LibMpvUnobservable {
  _LowOverheadFakeMpvClient();

  final List<List<String>> commands = <List<String>>[];
  final Map<String, String> options = <String, String>{};
  final Map<String, String> stringProps = <String, String>{};
  final Map<String, bool> flagProps = <String, bool>{'pause': false};
  final Map<String, double> doubleProps = <String, double>{
    'time-pos': 0.0,
    'duration': 180.0,
  };
  final Map<String, int> intProps = <String, int>{'playlist-count': 0};
  final Map<int, String> _observedById = <int, String>{};
  final List<int> unobserveCalls = <int>[];

  Set<String> get observedProperties => _observedById.values.toSet();
  final StreamController<MpvClientEvent> _events =
      StreamController<MpvClientEvent>.broadcast();
  final List<String> _playlist = <String>[];
  int _nextEntryId = 1;

  @override
  bool isInitialized = false;

  @override
  bool isDisposed = false;

  @override
  int get handleAddress => 7788;

  @override
  Stream<MpvClientEvent> get events => _events.stream;

  void emitEvent(MpvClientEvent event) {
    if (!_events.isClosed) {
      _events.add(event);
    }
  }

  @override
  String errorString(int code) => 'err($code)';

  @override
  int setOptionString(String name, String value) {
    options[name] = value;
    stringProps[name] = value;
    return 0;
  }

  @override
  int initialize() {
    isInitialized = true;
    return 0;
  }

  @override
  int setPropertyString(String name, String value) {
    stringProps[name] = value;
    return 0;
  }

  @override
  int setPropertyFlag(String name, bool value) {
    flagProps[name] = value;
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
  String? getPropertyString(String name) => stringProps[name] ?? options[name];

  @override
  bool? getPropertyFlag(String name) => flagProps[name];

  @override
  int? getPropertyInt64(String name) => intProps[name];

  @override
  double? getPropertyDouble(String name) => doubleProps[name];

  @override
  List<MpvTrackInfo> readTrackList() => const [];

  @override
  List<PlaybackChapter> readChapterList({double? totalDurationSeconds}) =>
      const [];

  @override
  List<MpvAudioDevice> readAudioDeviceList() => const [
    MpvAudioDevice(name: 'wasapi/{usb-dac-01}', description: 'USB DAC'),
  ];

  @override
  List<MpvSeekableRange> readDemuxerSeekableRanges() => const [];

  @override
  int observeProperty(int replyUserdata, String name, int format) {
    _observedById[replyUserdata] = name;
    return 0;
  }

  @override
  int unobserveProperty(int registeredReplyUserdata) {
    unobserveCalls.add(registeredReplyUserdata);
    _observedById.remove(registeredReplyUserdata);
    return 0;
  }

  @override
  int requestLogMessages(String minLevel) => 0;

  @override
  int command(List<String> args) {
    commands.add(List<String>.from(args));
    if (args.isEmpty) return 0;
    if (args.first == 'loadfile') {
      final target = args.length >= 2 ? args[1] : '';
      final mode = args.length >= 3 ? args[2] : 'replace';
      if (mode == 'replace') {
        _playlist
          ..clear()
          ..add(target);
        intProps['playlist-count'] = _playlist.length;
        final id = _nextEntryId++;
        intProps['playlist-entry-id'] = id;
        scheduleMicrotask(() {
          emitEvent(MpvStartFileEvent(id));
          emitEvent(const MpvFileLoadedEvent());
          emitEvent(const MpvPlaybackRestartEvent());
        });
      } else if (mode == 'append') {
        _playlist.add(target);
        intProps['playlist-count'] = _playlist.length;
      }
    } else if (args.first == 'playlist-clear') {
      if (_playlist.length > 1) {
        _playlist.removeRange(1, _playlist.length);
      }
      intProps['playlist-count'] = _playlist.length;
    } else if (args.first == 'stop') {
      _playlist.clear();
      intProps['playlist-count'] = 0;
    }
    return 0;
  }

  @override
  int commandAsync(int replyUserdata, List<String> args) => command(args);

  @override
  Future<void> dispose() async {
    isDisposed = true;
    await _events.close();
  }
}

/// 构造最小合法 24-bit 1x1 BMP 字节，供模拟缩略图软渲染抽帧返回。
Uint8List _buildMinimalBmpBytes() {
  return Uint8List.fromList(const [
    0x42, 0x4D, 0x3A, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x36, 0x00,
    0x00, 0x00, 0x28, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00,
    0x00, 0x00, 0x01, 0x00, 0x18, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00,
    0x00, 0x00, 0x13, 0x0B, 0x00, 0x00, 0x13, 0x0B, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF, 0xAA, 0x55, 0x00,
  ]);
}

/// 支持模拟软件缩略图渲染回调的最小客户端，用于验证按需惰性预热与空闲自动回收。
class _FakeThumbMpvClient extends _LowOverheadFakeMpvClient
    implements LibMpvSoftwareFrameSource {
  final StreamController<void> _renderUpdates =
      StreamController<void>.broadcast();
  bool softwareRendererFreed = false;
  bool _frameReady = false;

  @override
  bool initSoftwareRenderer({int width = 192, int height = 108}) => true;

  @override
  Stream<void> get softwareRenderUpdates => _renderUpdates.stream;

  @override
  bool pollSoftwareFrameReady() => _frameReady;

  @override
  Uint8List? renderSoftwareFrameBmp({int width = 192, int height = 108}) {
    _frameReady = false;
    return _buildMinimalBmpBytes();
  }

  @override
  void releaseSoftwareRenderer() {
    softwareRendererFreed = true;
  }

  @override
  int command(List<String> args) {
    final rc = super.command(args);
    if (args.isNotEmpty && args.first == 'seek') {
      scheduleMicrotask(() {
        _frameReady = true;
        emitEvent(const MpvPlaybackRestartEvent());
        if (!_renderUpdates.isClosed) {
          _renderUpdates.add(null);
        }
      });
    }
    return rc;
  }

  @override
  Future<void> dispose() async {
    await _renderUpdates.close();
    await super.dispose();
  }
}

/// 面向 `RemoteWindowReader` 零拷贝与大文件首尾缓存策略测试的内存确定性远程字节网关。
class _CountingPatternGateway implements ByteRangeReadableGateway {
  _CountingPatternGateway({required this.totalSize});

  final int totalSize;
  int rangeRequests = 0;

  @override
  Future<int?> probeFileLength(String relativePath) async => totalSize;

  @override
  Future<Stream<List<int>>> openByteRange(
    String relativePath, {
    required int start,
    int? endInclusive,
  }) async {
    rangeRequests += 1;
    final end = (endInclusive ?? (totalSize - 1)).clamp(start, totalSize - 1);
    final len = end - start + 1;
    final buf = Uint8List(len);
    for (var i = 0; i < len; i++) {
      buf[i] = (start + i) & 0xFF;
    }
    return Stream<List<int>>.value(buf);
  }

  @override
  Future<void> close() async {}
}

Future<Uint8List> _collectRange(
  RemoteWindowReader reader,
  int start,
  int endInclusive,
) async {
  final builder = BytesBuilder(copy: false);
  await for (final chunk in reader.read(
    start: start,
    endInclusive: endInclusive,
  )) {
    builder.add(chunk);
  }
  return builder.takeBytes();
}

/// 使用 Flutter 原生引擎编码生成指定宽高与高熵像素的真实 PNG 字节流。
Future<Uint8List> _encodeNoisyPng(int width, int height) async {
  final rgba = Uint8List(width * height * 4);
  var idx = 0;
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      rgba[idx++] = ((x * 73) ^ (y * 37) ^ ((x * y) >> 3)) & 0xFF;
      rgba[idx++] = ((x * 29) + (y * 91) ^ (x >> 1)) & 0xFF;
      rgba[idx++] = ((x * 13) ^ (y * 53) + (y >> 2)) & 0xFF;
      rgba[idx++] = 0xFF;
    }
  }
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    rgba,
    width,
    height,
    ui.PixelFormat.rgba8888,
    completer.complete,
  );
  final image = await completer.future;
  try {
    final bd = await image.toByteData(format: ui.ImageByteFormat.png);
    return bd!.buffer.asUint8List(bd.offsetInBytes, bd.lengthInBytes);
  } finally {
    image.dispose();
  }
}

/// 记录视口尺寸同步调用的最小视频控制器（用于校验悬浮小窗防抖缩降与全屏瞬时恢复）。
class _ViewportSpyVideoController extends VideoPlaybackController {
  _ViewportSpyVideoController(super.request)
    : super(
        deferBootstrap: true,
        initialState: VideoPlaybackState(
          isInitializing: false,
          isBuffering: false,
          hasFirstFrame: true,
          isPlaying: true,
          textureId: 42,
          windowsUnderlayActive: false,
          renderBackend: 'd3d11_fp16',
          currentWork: request.work,
          currentBundle: request.bundle,
          currentEpisode: request.episode,
          currentVariant: request.variant,
          durationSeconds: 1420.0,
          positionSeconds: 12.0,
          probeStats: const PlaybackProbeStats(
            videoWidth: 1920,
            videoHeight: 1080,
          ),
        ),
      );

  final List<({double w, double h, double dpr})> viewportReports = [];

  @override
  void notifySurfaceViewportSize(
    double logicalWidth,
    double logicalHeight,
    double devicePixelRatio,
  ) {
    viewportReports.add((
      w: logicalWidth,
      h: logicalHeight,
      dpr: devicePixelRatio,
    ));
  }
}

VideoLaunchRequest _buildSampleVideoRequest() {
  const source = MediaSource(
    id: 'src-local',
    label: '本地源',
    kind: MediaSourceKind.local,
    location: 'D:/Anime',
  );
  const work = Work(id: 'w-low-overhead', title: '葬送的芙莉莲');
  const ep = Episode(
    id: 'ep-1',
    workId: 'w-low-overhead',
    category: EpisodeCategory.main,
    seasonNumber: 1,
    episodeNumber: 1,
    title: '第 1 话',
  );
  const variant = MediaVariant(
    id: 'var-1',
    episodeId: 'ep-1',
    workId: 'w-low-overhead',
    sourceId: 'src-local',
    relativePath: 'Frieren/01.mkv',
    fileName: '01.mkv',
    fileSize: 2048,
  );
  return const VideoLaunchRequest(
    work: work,
    bundle: WorkDetailBundle(
      work: work,
      episodes: [ep],
      variants: [variant],
      sourcesById: {'src-local': source},
      latestPlayback: null,
    ),
    episode: ep,
    variant: variant,
    source: source,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('阶段一：远程零拷贝流读、缓存自清、画质/缓冲精细化、惰性缩略图与封面压缩', () {
    test('RemoteWindowReader 对大文件仅缓存首尾元数据区（不囤积中部），对小文件保留全窗口 LRU', () async {
      const largeSize = 24 * 1024 * 1024;
      final largeGw = _CountingPatternGateway(totalSize: largeSize);
      final largeReader = RemoteWindowReader(
        gateway: largeGw,
        relativePath: '/anime/big.mkv',
        totalLength: largeSize,
      );

      final head1 = await _collectRange(largeReader, 0, 64 * 1024 - 1);
      final mid1 = await _collectRange(
        largeReader,
        10 * 1024 * 1024,
        10 * 1024 * 1024 + 64 * 1024 - 1,
      );
      final tail1 = await _collectRange(
        largeReader,
        largeSize - 64 * 1024,
        largeSize - 1,
      );
      expect(head1[0], equals(0));
      expect(mid1[0], equals((10 * 1024 * 1024) & 0xFF));
      expect(tail1[0], equals((largeSize - 64 * 1024) & 0xFF));

      // 大文件缓存应仅保留首尾边缘窗口，中部窗口零囤积。
      expect(largeReader.cachedBytes, lessThanOrEqualTo(4 * 1024 * 1024));
      final fetchesAfterFirstPass = largeGw.rangeRequests;

      // 再次读取首部与尾部元数据（如 MKV Cues / MP4 moov）应 100% 命中缓存、零新增网络请求。
      await _collectRange(largeReader, 4096, 8191);
      await _collectRange(largeReader, largeSize - 4096, largeSize - 1);
      expect(largeGw.rangeRequests, equals(fetchesAfterFirstPass));

      // 小文件（4 MiB <= 16 MiB）应保留完整 LRU 窗口缓存。
      const smallSize = 4 * 1024 * 1024;
      final smallGw = _CountingPatternGateway(totalSize: smallSize);
      final smallReader = RemoteWindowReader(
        gateway: smallGw,
        relativePath: '/music/track.flac',
        totalLength: smallSize,
      );
      await _collectRange(
        smallReader,
        2 * 1024 * 1024,
        2 * 1024 * 1024 + 4095,
      );
      final smallFetches = smallGw.rangeRequests;
      await _collectRange(
        smallReader,
        2 * 1024 * 1024 + 512,
        2 * 1024 * 1024 + 1023,
      );
      expect(smallGw.rangeRequests, equals(smallFetches));
    });

    test('TempCachePruner 按 TTL 与 LRU 字节配额清理过期/超限文件及孤儿 .part 临时文件', () async {
      final root = await Directory.systemTemp.createTemp('konata_pruner_');
      addTearDown(() async {
        if (root.existsSync()) await root.delete(recursive: true);
      });

      final storageRoot = StorageRootService(overrideRoot: root);
      final cacheRoot = await storageRoot.resolveCacheRootDir();
      final bucketDir = Directory(
        p.join(
          cacheRoot.path,
          StoragePathConfig.tempSubdirName,
          StoragePathConfig.subtitleStageSubdirName,
        ),
      )..createSync(recursive: true);

      var now = DateTime(2026, 6, 1, 12, 0);
      final expired = File(p.join(bucketDir.path, 'expired.ass'))
        ..writeAsBytesSync(List<int>.filled(1024, 1))
        ..setLastModifiedSync(now.subtract(const Duration(days: 20)));
      final oldKeep = File(p.join(bucketDir.path, 'old.ass'))
        ..writeAsBytesSync(List<int>.filled(3000, 2))
        ..setLastModifiedSync(now.subtract(const Duration(days: 3)));
      final fresh = File(p.join(bucketDir.path, 'fresh.ass'))
        ..writeAsBytesSync(List<int>.filled(3000, 3))
        ..setLastModifiedSync(now.subtract(const Duration(hours: 2)));
      final stalePart = File(p.join(bucketDir.path, 'a.ass.part.123'))
        ..writeAsBytesSync(List<int>.filled(512, 4))
        ..setLastModifiedSync(now.subtract(const Duration(hours: 3)));
      final activePart = File(p.join(bucketDir.path, 'b.ass.part.456'))
        ..writeAsBytesSync(List<int>.filled(512, 5))
        ..setLastModifiedSync(now.subtract(const Duration(minutes: 5)));
      final emptySubDir = Directory(p.join(bucketDir.path, 'empty_sub'))
        ..createSync();

      final pruner = TempCachePruner(
        storageRoot: storageRoot,
        policies: const [
          TempCacheBucketPolicy(
            relativeSegments: [
              StoragePathConfig.tempSubdirName,
              StoragePathConfig.subtitleStageSubdirName,
            ],
            maxBytes: 4000,
            maxAge: Duration(days: 14),
          ),
        ],
        minInterval: const Duration(minutes: 30),
        clock: () => now,
      );

      final result = await pruner.pruneIfDue(force: true);
      expect(result.skippedByThrottle, isFalse);
      expect(result.removedFiles, equals(3));
      expect(expired.existsSync(), isFalse);
      expect(stalePart.existsSync(), isFalse);
      expect(oldKeep.existsSync(), isFalse);
      expect(fresh.existsSync(), isTrue);
      expect(activePart.existsSync(), isTrue);
      expect(emptySubDir.existsSync(), isFalse);

      // 节流窗口内再次调用 pruneIfDue 应直接跳过。
      now = now.add(const Duration(minutes: 5));
      final throttled = await pruner.pruneIfDue();
      expect(throttled.skippedByThrottle, isTrue);
    });

    test('MpvQualityProfile 持久化着色器/ICC 缓存、按预设开关 hdr-compute-peak 并精细化缓冲', () {
      final mpv = _LowOverheadFakeMpvClient();
      final cfgDir = Directory('D:/Temp/mpv_cfg');
      final shaderDir = Directory('D:/Temp/mpv_shaders');
      final iccDir = Directory('D:/Temp/mpv_icc');

      MpvQualityProfile.applyPreInitVideoOptions(
        mpv,
        config: const PlaybackQualityConfig(
          preset: VideoQualityPreset.lightweight,
        ),
        mpvConfigDir: cfgDir,
        gpuShaderCacheDir: shaderDir,
        iccCacheDir: iccDir,
        isRemoteStream: true,
        isWindowsOverride: true,
        isAndroidOverride: false,
        desktopDelegate: const WindowsMpvProfileDelegate(),
      );

      expect(mpv.options['gpu-shader-cache'], equals('yes'));
      expect(mpv.options['gpu-shader-cache-dir'], equals(shaderDir.path));
      expect(mpv.options['icc-cache'], equals('yes'));
      expect(mpv.options['icc-cache-dir'], equals(iccDir.path));

      final androidMpv = _LowOverheadFakeMpvClient();
      MpvQualityProfile.applyPreInitVideoOptions(
        androidMpv,
        config: const PlaybackQualityConfig(
          preset: VideoQualityPreset.highFidelity,
        ),
        mpvConfigDir: cfgDir,
        gpuShaderCacheDir: shaderDir,
        iccCacheDir: iccDir,
        isRemoteStream: true,
        isWindowsOverride: false,
        isAndroidOverride: true,
      );
      expect(androidMpv.options['cscale'], equals('ewa_lanczos'));
      expect(androidMpv.options['icc-cache'], equals('no'));
      expect(androidMpv.options.containsKey('icc-cache-dir'), isFalse);
      expect(mpv.options['hdr-compute-peak'], equals('no'));
      expect(mpv.options['demuxer-max-bytes'], equals('48MiB'));
      expect(mpv.options['demuxer-max-back-bytes'], equals('16MiB'));

      expect(
        MpvQualityProfile.shouldEnableHdrComputePeak(
          VideoQualityPreset.highFidelity,
        ),
        isTrue,
      );
      expect(
        MpvQualityProfile.shouldEnableHdrComputePeak(
          VideoQualityPreset.highFidelity,
          isHdrSource: false,
        ),
        isFalse,
      );
      expect(
        MpvQualityProfile.shouldEnableHdrComputePeak(
          VideoQualityPreset.lightweight,
        ),
        isFalse,
      );
      expect(
        MpvQualityProfile.resolveDemuxerBufferMiB(
          config: const PlaybackQualityConfig(),
          isAudio: false,
          isRemoteStream: true,
          isAndroid: true,
        ),
        equals((maxBytesMiB: 32, backBytesMiB: 12)),
      );
      expect(
        MpvQualityProfile.resolveDemuxerBufferMiB(
          config: const PlaybackQualityConfig(),
          isAudio: true,
          isRemoteStream: true,
          isAndroid: false,
        ),
        equals((maxBytesMiB: 24, backBytesMiB: 8)),
      );
      expect(MpvQualityProfile.remoteAudioProbesize, equals('1048576'));
    });

    test('MpvThumbnailService 构造零原生实例，悬停才惰性建联，空闲到期自动回收且保留缓存帧', () async {
      final tempDir = await Directory.systemTemp.createTemp('konata_thumb_');
      addTearDown(() async {
        if (tempDir.existsSync()) await tempDir.delete(recursive: true);
      });
      final mediaFile = File(p.join(tempDir.path, 'test.mkv'))
        ..writeAsBytesSync(const [1, 2, 3, 4]);

      var createdClients = 0;
      final clients = <_FakeThumbMpvClient>[];
      final bridge = LocalStreamBridge();
      addTearDown(bridge.dispose);

      final svc = MpvThumbnailService(
        streamBridge: bridge,
        idleReleaseDuration: const Duration(milliseconds: 60),
        clientFactory: () {
          createdClients += 1;
          final c = _FakeThumbMpvClient();
          clients.add(c);
          return c;
        },
      );
      addTearDown(svc.dispose);

      final source = MediaSource(
        id: 's-local',
        label: '本地源',
        kind: MediaSourceKind.local,
        location: tempDir.path,
      );
      final variant = MediaVariant(
        id: 'v-thumb',
        episodeId: 'e-thumb',
        workId: 'w-thumb',
        sourceId: source.id,
        relativePath: p.basename(mediaFile.path),
        fileName: p.basename(mediaFile.path),
        fileSize: 4,
      );

      // 未悬停前严禁预建第二实例。
      expect(createdClients, equals(0));
      expect(svc.hasActiveNativeClient, isFalse);

      // 首次悬停触发预热并抽帧缓存。
      await svc.warmUp(
        variant: variant,
        source: source,
        durationSeconds: 120.0,
      );
      expect(createdClients, equals(1));
      expect(svc.hasActiveNativeClient, isTrue);

      svc.requestPreview(10.0);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(svc.resolvePreviewFrame(10.0), isNotNull);
      expect(svc.cachedCount, greaterThanOrEqualTo(1));

      // 移开进度条并等待空闲超时 -> 自动回收原生实例，但保留已抽帧缓存。
      svc.requestPreview(null);
      await Future<void>.delayed(const Duration(milliseconds: 140));
      expect(svc.hasActiveNativeClient, isFalse);
      expect(clients.first.isDisposed, isTrue);
      expect(svc.resolvePreviewFrame(10.0), isNotNull);

      // 悬停已命中缓存点无需重建实例；悬停未命中缓存点自动静默重建。
      svc.requestPreview(10.0);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(createdClients, equals(1));

      svc.requestPreview(55.0);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(createdClients, equals(2));
      expect(svc.resolvePreviewFrame(55.0), isNotNull);
    });

    test('AlbumCoverCompactor 对小图零开销原样返回，对超大 PNG 等比缩降且严格缩小体积', () async {
      final tiny = await _encodeNoisyPng(32, 32);
      final tinyOut = await AlbumCoverCompactor.compactForDisk(tiny);
      expect(identical(tinyOut, tiny), isTrue);

      final bigPng = await _encodeNoisyPng(1600, 1600);
      expect(bigPng.length, greaterThan(AlbumCoverCompactor.minBytesToCompact));

      final compacted = await AlbumCoverCompactor.compactForDisk(bigPng);
      expect(compacted.length, lessThan(bigPng.length));

      final codec = await ui.instantiateImageCodec(compacted);
      try {
        final frame = await codec.getNextFrame();
        expect(frame.image.width, lessThanOrEqualTo(720));
        expect(frame.image.height, lessThanOrEqualTo(720));
        frame.image.dispose();
      } finally {
        codec.dispose();
      }
    });
  });

  group('阶段二：原音直出硬件核验解锁、音频分级静默订阅与 C 级无缝续播', () {
    testWidgets(
      'AudiophileSafetyCoordinator 实证 WASAPI 独占路由并在弹窗内两步解锁满幅 af=""',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final fakeClient = _LowOverheadFakeMpvClient()
          ..initialize()
          ..stringProps['current-ao'] = 'wasapi'
          ..stringProps['audio-out-detected-device'] = 'wasapi/{usb-dac-01}'
          ..flagProps['audio-exclusive'] = true;

        final engine = UnifiedPlaybackEngine(
          defaultClientFactory: ({String? preferredLibraryPath}) => fakeClient,
        );
        await engine.acquireExclusiveNativeClient(
          stage: PlaybackStageKind.audio,
          onEvicted: () async {},
        );
        final coordinator = AudiophileSafetyCoordinator(
          engine: engine,
          androidRouteBridge: AndroidAudioRouteBridge(),
          logStore: DiagnosticsLogStore(),
        );
        const prefs = PlaybackPreferencesState(
          qualityConfig: PlaybackQualityConfig(
            exclusiveAudioOutput: true,
            audioDevice: 'wasapi/{usb-dac-01}',
          ),
        );
        coordinator.attachSession(
          owner: 'test-audio',
          clientProvider: () => fakeClient,
          prefsProvider: () => prefs,
          onTransientMuteAndPause: (_) {},
        );
        // 建立初始设备快照基线，便于后续热拔出检验。
        coordinator.handleWindowsAudioDevicesChanged(
          devices: const [
            MpvAudioDevice(
              name: 'wasapi/{usb-dac-01}',
              description: 'USB DAC',
            ),
          ],
          currentAudioDevice: 'wasapi/{usb-dac-01}',
        );

        // 初始未实证状态下强锁安全限幅。
        expect(coordinator.deviceSafetyState.isBackendMeterVerified, isFalse);
        expect(
          await coordinator.confirmSessionFullScaleUnlock(prefs),
          isFalse,
        );

        final container = ProviderContainer(
          overrides: [
            unifiedPlaybackEngineProvider.overrideWithValue(engine),
            audiophileSafetyCoordinatorProvider.overrideWithValue(coordinator),
          ],
        );
        addTearDown(container.dispose);
        await container
            .read(playbackPreferencesProvider.notifier)
            .setExclusiveAudioOutput(true);

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: KonataTheme.darkTheme(),
              home: Scaffold(
                body: Consumer(
                  builder: (context, ref, _) => ElevatedButton(
                    onPressed: () =>
                        showAudiophileFullScaleUnlockDialog(context, ref),
                    child: const Text('打开安全确认'),
                  ),
                ),
              ),
            ),
          ),
        );

        await tester.tap(find.text('打开安全确认'));
        await tester.pumpAndSettle();

        // 第一步：点击「检测直通链路」完成硬件路由核验。
        final verifyBtn = find.byKey(
          const ValueKey('audiophile_verify_route_button'),
        );
        expect(verifyBtn, findsOneWidget);
        await tester.tap(verifyBtn);
        await tester.pumpAndSettle();
        expect(coordinator.deviceSafetyState.isBackendMeterVerified, isTrue);

        // 第二步：点击「确认解锁本次满幅」清空软件滤镜 af=""。
        await tester.tap(
          find.byKey(const ValueKey('audiophile_unlock_confirm_button')),
        );
        await tester.pumpAndSettle();
        expect(
          coordinator.deviceSafetyState.sessionFullScaleUnlocked,
          isTrue,
        );
        expect(fakeClient.stringProps['af'], equals(''));

        // 设备热拔出后自动复锁并恢复安全衰减滤镜。
        coordinator.handleWindowsAudioDevicesChanged(
          devices: const [],
          currentAudioDevice: null,
        );
        expect(coordinator.deviceSafetyState.isBackendMeterVerified, isFalse);
        expect(
          coordinator.deviceSafetyState.sessionFullScaleUnlocked,
          isFalse,
        );
        expect(
          fakeClient.stringProps['af'],
          contains('alimiter'),
        );
      },
    );

    test(
      'AudioPlaybackNotifier 支持分级进度订阅（suspended 零唤醒）与 C 级多文件无缝 append',
      () async {
        SharedPreferences.setMockInitialValues({});
        final tempDir = await Directory.systemTemp.createTemp('konata_gapless_');
        addTearDown(() async {
          if (tempDir.existsSync()) await tempDir.delete(recursive: true);
        });
        final f1 = File(p.join(tempDir.path, '01.flac'))
          ..writeAsBytesSync(const [0x66, 0x4C, 0x61, 0x43]);
        final f2 = File(p.join(tempDir.path, '02.flac'))
          ..writeAsBytesSync(const [0x66, 0x4C, 0x61, 0x43]);

        final fakeClient = _LowOverheadFakeMpvClient();
        final storageRoot = StorageRootService(overrideRoot: tempDir);
        final streamBridge = LocalStreamBridge(storageRoot: storageRoot);
        addTearDown(streamBridge.dispose);
        final engine = UnifiedPlaybackEngine(
          defaultClientFactory: ({String? preferredLibraryPath}) => fakeClient,
        );

        final db = KonataDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final repo = DriftLibraryRepository(db);
        final container = ProviderContainer(
          overrides: [
            libraryRepositoryProvider.overrideWithValue(repo),
            storageRootProvider.overrideWithValue(storageRoot),
            localStreamBridgeProvider.overrideWithValue(streamBridge),
            unifiedPlaybackEngineProvider.overrideWithValue(engine),
          ],
        );
        addTearDown(container.dispose);

        final source = MediaSource(
          id: 'src-local',
          label: '本地源',
          kind: MediaSourceKind.local,
          location: tempDir.path,
        );
        const work = Work(id: 'w-audio-gapless', title: 'OST');
        final v1 = MediaVariant(
          id: 'v-cd-1',
          episodeId: 'cd-1',
          workId: work.id,
          sourceId: source.id,
          relativePath: p.basename(f1.path),
          fileName: p.basename(f1.path),
          fileSize: 4,
        );
        final v2 = MediaVariant(
          id: 'v-cd-2',
          episodeId: 'cd-2',
          workId: work.id,
          sourceId: source.id,
          relativePath: p.basename(f2.path),
          fileName: p.basename(f2.path),
          fileSize: 4,
        );

        final notifier = container.read(audioPlaybackProvider.notifier);
        await notifier.playCdCollection(
          work: work,
          cdVariants: [v1, v2],
          initialVariant: v1,
          sourcesById: {source.id: source},
        );
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(container.read(audioPlaybackProvider).currentIndex, equals(0));
        expect(fakeClient.observedProperties.contains('time-pos'), isTrue);

        // 1. 切换至 suspended：退订 time-pos 且丢弃滞后事件（0 次进度状态唤醒）。
        var positionUpdates = 0;
        final sub = container.listen<double>(
          audioPlaybackProvider.select((s) => s.positionSeconds),
          (_, _) => positionUpdates += 1,
        );
        addTearDown(sub.close);

        notifier.setProgressObservationMode(
          AudioProgressObservationMode.suspended,
        );
        expect(fakeClient.observedProperties.contains('time-pos'), isFalse);
        expect(fakeClient.unobserveCalls, contains(101));
        final beforeEmit = positionUpdates;
        fakeClient.emitEvent(
          const MpvPropertyChangeEvent(
            name: 'time-pos',
            replyUserdata: 101,
            format: MpvFormat.double_,
            doubleValue: 42.5,
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(positionUpdates, equals(beforeEmit));
        expect(
          container.read(audioPlaybackProvider).positionSeconds,
          isNot(closeTo(42.5, 0.1)),
        );

        // 2. 切回 highFrequency：恢复 time-pos 订阅。
        notifier.setProgressObservationMode(
          AudioProgressObservationMode.highFrequency,
        );
        expect(fakeClient.observedProperties.contains('time-pos'), isTrue);

        // 3. 临近尾段触发 C 级 playlist append 预排队，EOF 不应回退发起 loadfile replace，
        // 收到 MpvStartFileEvent 后原子切换 currentIndex 到 1。
        fakeClient.emitEvent(
          const MpvPropertyChangeEvent(
            name: 'duration',
            replyUserdata: 102,
            format: MpvFormat.double_,
            doubleValue: 180.0,
          ),
        );
        fakeClient.emitEvent(
          const MpvPropertyChangeEvent(
            name: 'time-pos',
            replyUserdata: 101,
            format: MpvFormat.double_,
            doubleValue: 170.0,
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 40));
        expect(
          fakeClient.commands.any(
            (c) => c.length >= 3 && c[0] == 'loadfile' && c[2] == 'append',
          ),
          isTrue,
        );
        final replaceCountBeforeEof = fakeClient.commands
            .where(
              (c) => c.length >= 3 && c[0] == 'loadfile' && c[2] == 'replace',
            )
            .length;

        fakeClient.emitEvent(
          const MpvEndFileEvent(
            reason: MpvEndFileReason.eof,
            errorCode: 0,
            playlistEntryId: 1,
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        final replaceCountAfterEof = fakeClient.commands
            .where(
              (c) => c.length >= 3 && c[0] == 'loadfile' && c[2] == 'replace',
            )
            .length;
        expect(replaceCountAfterEof, equals(replaceCountBeforeEof));

        fakeClient.emitEvent(const MpvStartFileEvent(2));
        await Future<void>.delayed(const Duration(milliseconds: 25));
        expect(container.read(audioPlaybackProvider).currentIndex, equals(1));
        await notifier.stopAndClose();
      },
    );
  });

  group('阶段三：Windows 悬浮小窗共享纹理防抖缩降与全屏零延迟恢复', () {
    testWidgets(
      'KonataHardwareVideoSurface 全屏直通同步，切入悬浮小窗经 180ms 防抖缩降，还原全屏即时恢复',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 720);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final req = _buildSampleVideoRequest();
        late _ViewportSpyVideoController spy;
        final isMini = ValueNotifier<bool>(false);
        addTearDown(isMini.dispose);

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              videoPlaybackProvider(req).overrideWith(() {
                spy = _ViewportSpyVideoController(req);
                return spy;
              }),
            ],
            child: MaterialApp(
              theme: KonataTheme.darkTheme(),
              home: Scaffold(
                body: ValueListenableBuilder<bool>(
                  valueListenable: isMini,
                  builder: (_, mini, _) => Align(
                    alignment: Alignment.topLeft,
                    child: SizedBox(
                      width: mini ? 320 : 1280,
                      height: mini ? 180 : 720,
                      child: KonataHardwareVideoSurface(
                        request: req,
                        miniPreview: mini,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );

        // 1. 全屏首帧立即可同步 1280x720。
        await tester.pump();
        expect(spy.viewportReports, hasLength(1));
        expect(spy.viewportReports.last.w, equals(1280));
        expect(spy.viewportReports.last.h, equals(720));

        // 2. 切入悬浮小窗（320x180）：100ms 内防抖未触发，超过 180ms 后精准触发 1 次缩降。
        isMini.value = true;
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(spy.viewportReports, hasLength(1));

        await tester.pump(KonataPlaybackTokens.miniSurfaceResizeDebounce);
        expect(spy.viewportReports, hasLength(2));
        expect(spy.viewportReports.last.w, equals(320));
        expect(spy.viewportReports.last.h, equals(180));

        // 3. 切回全屏：0ms 立即恢复 1280x720，无防抖延迟。
        isMini.value = false;
        await tester.pump();
        await tester.pump();
        expect(spy.viewportReports, hasLength(3));
        expect(spy.viewportReports.last.w, equals(1280));
        expect(spy.viewportReports.last.h, equals(720));
      },
    );
  });
}
