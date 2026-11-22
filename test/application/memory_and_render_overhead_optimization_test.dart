import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:ccplayer/application/playback/audio_playback_notifier.dart';
import 'package:ccplayer/application/playback/playback_preferences_provider.dart';
import 'package:ccplayer/application/providers/artwork_provider.dart';
import 'package:ccplayer/application/providers/memory_coordinator.dart';
import 'package:ccplayer/application/providers/scraping_providers.dart';
import 'package:ccplayer/domain/models/media_source.dart';
import 'package:ccplayer/domain/models/media_variant.dart';
import 'package:ccplayer/domain/playback/playback_probe_stats.dart';
import 'package:ccplayer/domain/playback/track_preferences.dart';
import 'package:ccplayer/infrastructure/cache/artwork_cache.dart';
import 'package:ccplayer/infrastructure/cache/photos_storage.dart';
import 'package:ccplayer/infrastructure/players/embedded_mpv_session.dart';
import 'package:ccplayer/infrastructure/players/konata_video_texture_bridge.dart';
import 'package:ccplayer/infrastructure/players/libmpv_ffi.dart';
import 'package:ccplayer/infrastructure/players/mpv_quality_profile.dart';
import 'package:ccplayer/infrastructure/players/windows_mpv_profile_adapter.dart';
import 'package:ccplayer/infrastructure/storage/storage_root_provider.dart';
import 'package:ccplayer/infrastructure/stream_bridge/local_stream_bridge.dart';
import 'package:ccplayer/infrastructure/stream_bridge/remote_window_reader.dart';
import 'package:ccplayer/presentation/audio/mini_audio_bar.dart';
import 'package:ccplayer/presentation/widgets/managed_image.dart';

class _DynamicHdrFakeMpvClient implements LibMpvClient {
  final Map<String, String> options = {};
  final Map<String, String> stringProps = {};
  final Map<String, bool> boolProps = {};
  final Map<String, double> doubleProps = {};
  final StreamController<MpvClientEvent> controller =
      StreamController<MpvClientEvent>.broadcast();

  bool _initialized = false;
  bool _disposed = false;

  @override
  int get handleAddress => 0x2001;

  @override
  bool get isInitialized => _initialized;

  @override
  bool get isDisposed => _disposed;

  @override
  Stream<MpvClientEvent> get events => controller.stream;

  @override
  int initialize() {
    _initialized = true;
    return 0;
  }

  @override
  int setOptionString(String name, String value) {
    options[name] = value;
    return 0;
  }

  @override
  int setPropertyString(String name, String value) {
    stringProps[name] = value;
    return 0;
  }

  @override
  int setPropertyFlag(String name, bool value) {
    boolProps[name] = value;
    return 0;
  }

  @override
  int setPropertyInt64(String name, int value) => 0;

  @override
  int setPropertyDouble(String name, double value) {
    doubleProps[name] = value;
    return 0;
  }

  @override
  String? getPropertyString(String name) => stringProps[name];

  @override
  bool? getPropertyFlag(String name) => boolProps[name];

  @override
  int? getPropertyInt64(String name) => null;

  @override
  double? getPropertyDouble(String name) => doubleProps[name];

  @override
  int observeProperty(int replyUserdata, String name, int format) => 0;

  @override
  int requestLogMessages(String minLevel) => 0;

  @override
  int command(List<String> args) => 0;

  @override
  int commandAsync(int replyUserdata, List<String> args) => 0;

  @override
  List<MpvTrackInfo> readTrackList() => const [];

  @override
  List<PlaybackChapter> readChapterList({double? totalDurationSeconds}) =>
      const [];

  @override
  List<MpvAudioDevice> readAudioDeviceList() => const [];

  @override
  List<MpvSeekableRange> readDemuxerSeekableRanges() => const [];

  @override
  String errorString(int errorCode) => 'ok';

  @override
  Future<void> dispose() async {
    _disposed = true;
    await controller.close();
  }
}

class _DynamicHdrRecordingBridge implements KonataVideoTextureBridge {
  final StreamController<NativeTextureChangedEvent> _changes =
      StreamController<NativeTextureChangedEvent>.broadcast();
  final List<({int sessionId, bool enabled})> hdrFboCalls = [];
  String? lastRequestedBackend;

  @override
  Stream<NativeTextureChangedEvent> get textureChanges => _changes.stream;

  @override
  Future<NativeVideoSessionHandle> createSession({
    required int mpvHandleAddress,
    int width = 1280,
    int height = 720,
    bool preferSoftware = false,
    String renderBackend = 'gpu_next',
  }) async {
    lastRequestedBackend = renderBackend;
    return const NativeVideoSessionHandle(
      sessionId: 7,
      textureId: 19,
      backend: 'd3d11_10bit',
      surfaceFormat: 'DXGI_FORMAT_R10G10B10A2_UNORM',
      colorBitDepth: 10,
      adapterName: 'Test-RTX',
    );
  }

  @override
  Future<void> resize({
    required int sessionId,
    required int width,
    required int height,
  }) async {}

  @override
  Future<void> setViewportRect({
    required int sessionId,
    required int leftPx,
    required int topPx,
    required int rightPx,
    required int bottomPx,
    double cornerRadiusPx = 0.0,
    bool visible = true,
  }) async {}

  @override
  Future<NativeSessionMetrics?> getSessionMetrics(int sessionId) async => null;

  @override
  Future<bool> setHdrFboEnabled({
    required int sessionId,
    required bool enabled,
  }) async {
    hdrFboCalls.add((sessionId: sessionId, enabled: enabled));
    return true;
  }

  @override
  Future<void> disposeSession(int sessionId) async {}

  @override
  Future<({bool available, String adapterName})> getAdapterInfo() async =>
      (available: true, adapterName: 'Test-RTX');

  @override
  Future<void> dispose() async {
    await _changes.close();
  }
}

void main() {
  group('图片有界物理像素解码与三重冗余内存治理', () {
    test('quantizeManagedImageWidth 将任意物理宽度离散化至标准档位并严格封顶', () {
      expect(quantizeManagedImageWidth(120), equals(192));
      expect(quantizeManagedImageWidth(310), equals(320));
      expect(quantizeManagedImageWidth(900), equals(960));
      expect(quantizeManagedImageWidth(1900), equals(1920));
      expect(quantizeManagedImageWidth(5200), equals(3840));
      expect(quantizeManagedImageWidth(2000, maxWidth: 1280), equals(1280));
      expect(quantizeManagedImageWidth(0), equals(192));
    });

    test('ArtworkCache 16 MiB 封顶、跳过超过 512 KiB 的本地大原图堆滞留并支持清空内存池', () async {
      final tempDir = await Directory.systemTemp.createTemp('konata_art_cap_');
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final storage = PhotosStorage(overrideRoot: tempDir);
      final cache = ArtworkCache.photos(storage);
      expect(cache.maxMemoryBytes, equals(16 * 1024 * 1024));
      expect(cache.maxMemoryEntries, equals(96));

      final largeLocalBackdrop = Uint8List(900 * 1024);
      await cache.write(
        'original_/hero.jpg',
        largeLocalBackdrop,
        owner: 'w1',
        subfolder: PhotoSubfolder.backdrops,
      );
      expect(cache.currentMemoryBytes, equals(0));
      expect(cache.memoryEntryCount, equals(0));

      final readBack = await cache.read(
        'original_/hero.jpg',
        owner: 'w1',
        subfolder: PhotoSubfolder.backdrops,
      );
      expect(readBack?.length, equals(largeLocalBackdrop.length));
      expect(cache.currentMemoryBytes, equals(0));

      final smallPoster = Uint8List(120 * 1024);
      await cache.write(
        'w500_/poster.jpg',
        smallPoster,
        owner: 'w1',
        subfolder: PhotoSubfolder.posters,
      );
      expect(cache.currentMemoryBytes, equals(smallPoster.length));
      expect(cache.memoryEntryCount, equals(1));

      cache.clearMemoryCache();
      expect(cache.currentMemoryBytes, equals(0));
      expect(cache.memoryEntryCount, equals(0));
    });

    test('ArtworkMemoryCaches 严格执行 16 MiB 去重专辑封面预算并支持一键清理', () {
      final caches = ArtworkMemoryCaches();
      final c1 = Uint8List(3 * 1024 * 1024);
      final c2 = Uint8List(3 * 1024 * 1024);
      final c3 = Uint8List(3 * 1024 * 1024);
      final c4 = Uint8List(3 * 1024 * 1024);
      final c5 = Uint8List(3 * 1024 * 1024);
      final c6 = Uint8List(3 * 1024 * 1024);

      caches.putAudioAlbumCover('s::a::1', c1);
      caches.putAudioAlbumCover('s::b::2', c2);
      caches.putAudioAlbumCover('s::c::3', c3);
      caches.putAudioAlbumCover('s::d::4', c4);
      caches.putAudioAlbumCover('s::e::5', c5);
      caches.putAudioAlbumCover('s::f::6', c6);

      expect(
        caches.currentAudioCoverBytes,
        lessThanOrEqualTo(ArtworkMemoryCaches.maxAudioCoverMemoryBytes),
      );
      expect(caches.audioAlbumCovers.containsKey('s::a::1'), isFalse);
      expect(caches.audioAlbumCovers.containsKey('s::f::6'), isTrue);

      caches.trimTransientCaches();
      expect(caches.currentAudioCoverBytes, equals(0));
    });
  });

  group('KonataMemoryCoordinator 停播与最小化内存协调器', () {
    test('全屏视频入口、停播延迟回收、取消定时器与最小化立即回吐协同生效', () async {
      final tempDir = await Directory.systemTemp.createTemp('konata_mem_coord_');
      final artCache = ArtworkCache(tempDir);
      addTearDown(() async {
        artCache.close();
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });
      await artCache.write('small_poster', Uint8List(64 * 1024));
      var uiClearCount = 0;
      final nativeCalls = <({bool releaseIdle, bool trimWs})>[];

      final container = ProviderContainer(
        overrides: [
          artworkCacheProvider.overrideWith((_) async => artCache),
          konataUiImageCacheTrimmerProvider.overrideWithValue(() {
            uiClearCount += 1;
          }),
          konataNativeMemoryTrimmerProvider.overrideWithValue(({
            bool releaseIdleDevice = false,
            bool trimWorkingSet = false,
          }) async {
            nativeCalls.add((
              releaseIdle: releaseIdleDevice,
              trimWs: trimWorkingSet,
            ));
          }),
        ],
      );
      addTearDown(container.dispose);

      await container.read(artworkCacheProvider.future);
      final memCaches = container.read(artworkMemoryCachesProvider);
      memCaches.putAudioAlbumCover('src::album::1', Uint8List(128 * 1024));
      final coordinator = container.read(konataMemoryCoordinatorProvider);

      coordinator.onEnterFullscreenVideo();
      expect(uiClearCount, equals(1));
      expect(artCache.currentMemoryBytes, equals(0));
      expect(memCaches.currentAudioCoverBytes, greaterThan(0));

      coordinator.schedulePostPlaybackTrim(
        delay: const Duration(milliseconds: 40),
      );
      coordinator.cancelPostPlaybackTrim();
      await Future<void>.delayed(const Duration(milliseconds: 70));
      expect(nativeCalls, isEmpty);

      coordinator.schedulePostPlaybackTrim(
        delay: const Duration(milliseconds: 30),
      );
      await Future<void>.delayed(const Duration(milliseconds: 70));
      expect(nativeCalls.length, equals(1));
      expect(nativeCalls.single.releaseIdle, isTrue);
      expect(nativeCalls.single.trimWs, isTrue);
      expect(memCaches.currentAudioCoverBytes, equals(0));

      await coordinator.onAppHiddenOrMinimized();
      expect(nativeCalls.length, equals(2));
      expect(nativeCalls.last.releaseIdle, isTrue);
      expect(nativeCalls.last.trimWs, isTrue);
    });
  });

  group('动态 HDR 升档、解复用与流式窗口定额治理', () {
    test('MpvQualityProfile 精准判定真 HDR 信号、按端定额缓冲且 RemoteWindowConfig 控顶', () {
      expect(MpvQualityProfile.isHdrTransfer(gamma: 'bt.1886', sigPeak: 1.0), isFalse);
      expect(MpvQualityProfile.isHdrTransfer(gamma: 'srgb', sigPeak: 1.0), isFalse);
      expect(MpvQualityProfile.isHdrTransfer(gamma: 'pq', sigPeak: 1.0), isTrue);
      expect(MpvQualityProfile.isHdrTransfer(gamma: 'hlg'), isTrue);
      expect(MpvQualityProfile.isHdrTransfer(gamma: 'bt.1886', sigPeak: 4.5), isTrue);

      const defaultCfg = PlaybackQualityConfig();
      expect(
        MpvQualityProfile.resolveDemuxerBufferMiB(
          config: defaultCfg,
          isRemoteStream: false,
          isAudio: false,
          isAndroid: false,
        ),
        equals((maxBytesMiB: 24, backBytesMiB: 8)),
      );
      expect(
        MpvQualityProfile.resolveDemuxerBufferMiB(
          config: defaultCfg,
          isRemoteStream: true,
          isAudio: false,
          isAndroid: false,
        ),
        equals((maxBytesMiB: 48, backBytesMiB: 16)),
      );
      expect(
        MpvQualityProfile.resolveDemuxerBufferMiB(
          config: defaultCfg,
          isRemoteStream: true,
          isAudio: false,
          isAndroid: true,
        ),
        equals((maxBytesMiB: 32, backBytesMiB: 12)),
      );
      expect(RemoteWindowConfig.maxCachedBytes, equals(6 * 1024 * 1024));
      expect(RemoteWindowConfig.maxSequentialWindowBytes, equals(8 * 1024 * 1024));
    });

    test('EmbeddedMpvSession 遇真 HDR 信号自动开启 hdr-compute-peak 并升档 FP16 FBO，切回 SDR 自动降回 10-bit', () async {
      final tempDir = await Directory.systemTemp.createTemp('konata_hdr_dyn_');
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final fakeMpv = _DynamicHdrFakeMpvClient();
      final fakeBridge = _DynamicHdrRecordingBridge();
      final streamBridge = LocalStreamBridge();
      addTearDown(streamBridge.dispose);

      final session = EmbeddedMpvSession(
        storageRoot: StorageRootService(overrideRoot: tempDir),
        streamBridge: streamBridge,
        desktopSurfaceBridge: fakeBridge,
        desktopProfileDelegate: const WindowsMpvProfileDelegate(),
        clientFactory: () => fakeMpv,
      );
      addTearDown(session.dispose);

      final source = MediaSource(
        id: 'local',
        label: '本地测试源',
        kind: MediaSourceKind.local,
        location: tempDir.path,
      );
      const variant = MediaVariant(
        id: 'v_hdr',
        workId: 'w_hdr',
        episodeId: 'ep_hdr',
        sourceId: 'local',
        relativePath: '01.mkv',
        fileName: '01.mkv',
        fileSize: 1024,
      );

      await session.initializeAndLoad(
        request: EmbeddedVideoLoadRequest(
          workId: 'w_hdr',
          variant: variant,
          source: source,
        ),
        qualityConfig: const PlaybackQualityConfig(
          preset: VideoQualityPreset.highFidelity,
          outputPipelineMode: VideoOutputPipelineMode.legacyTextureFallback,
        ),
      );

      expect(fakeMpv.options['hdr-compute-peak'], equals('no'));
      expect(fakeMpv.options['fbo-format'], equals('rgb10_a2'));

      // 常规 SDR 番剧首帧：保持关闭 hdr-compute-peak 与 10-bit FBO。
      fakeMpv.stringProps['video-params/gamma'] = 'bt.1886';
      fakeMpv.doubleProps['video-params/sig-peak'] = 1.0;
      fakeMpv.controller.add(const MpvVideoReconfigEvent());
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(fakeMpv.boolProps['hdr-compute-peak'], isFalse);
      if (Platform.isWindows) {
        expect(fakeBridge.hdrFboCalls.last.enabled, isFalse);
        expect(session.renderBackendListenable.value, equals('d3d11_10bit'));
      }

      // 切换至 PQ HDR10 视频：自动开启 hdr-compute-peak 并升档 FP16 FBO。
      fakeMpv.stringProps['video-params/gamma'] = 'pq';
      fakeMpv.doubleProps['video-params/sig-peak'] = 4.92;
      fakeMpv.controller.add(const MpvVideoReconfigEvent());
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(fakeMpv.boolProps['hdr-compute-peak'], isTrue);
      if (Platform.isWindows) {
        expect(fakeBridge.hdrFboCalls.last.enabled, isTrue);
        expect(fakeMpv.stringProps['fbo-format'], equals('rgba16hf'));
        expect(session.renderBackendListenable.value, equals('d3d11_fp16'));
      }

      // 切回常规 SDR 视频：自动降回 10-bit FBO 并关闭 hdr-compute-peak。
      fakeMpv.stringProps['video-params/gamma'] = 'bt.1886';
      fakeMpv.doubleProps['video-params/sig-peak'] = 1.0;
      fakeMpv.controller.add(const MpvVideoReconfigEvent());
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(fakeMpv.boolProps['hdr-compute-peak'], isFalse);
      if (Platform.isWindows) {
        expect(fakeBridge.hdrFboCalls.last.enabled, isFalse);
        expect(fakeMpv.stringProps['fbo-format'], equals('rgb10_a2'));
        expect(session.renderBackendListenable.value, equals('d3d11_10bit'));
      }
    });
  });

  group('全屏舞台稳态 OverlayEntry.opaque 剪枝与退场还原', () {
    testWidgets('KonataStageMorphFrame 展开稳态触发 onExpandCompleted，收起态绝不触发', (
      tester,
    ) async {
      var expandedCount = 0;
      var collapsedCount = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: KonataStageMorphFrame(
            originRect: const Rect.fromLTWH(20, 20, 200, 112),
            allowClipRadius: true,
            onExpandCompleted: () => expandedCount += 1,
            onCollapseCompleted: () => collapsedCount += 1,
            child: const ColoredBox(color: Colors.black),
          ),
        ),
      );
      expect(expandedCount, equals(0));
      await tester.pumpAndSettle();
      expect(expandedCount, equals(1));
      expect(collapsedCount, equals(0));

      await tester.pumpWidget(
        MaterialApp(
          home: KonataStageMorphFrame(
            originRect: const Rect.fromLTWH(20, 20, 200, 112),
            allowClipRadius: true,
            isCollapsing: true,
            onExpandCompleted: () => expandedCount += 1,
            onCollapseCompleted: () => collapsedCount += 1,
            child: const ColoredBox(color: Colors.black),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(expandedCount, equals(1));
      expect(collapsedCount, equals(1));
    });

    testWidgets('MiniAudioOverlayHost 全屏音频稳态将根全屏 Overlay 置为不透明，收起时立即还原透明露出下层页', (
      tester,
    ) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            builder: (context, child) =>
                MiniAudioOverlayHost(child: child ?? const SizedBox.shrink()),
            home: const Scaffold(
              body: Center(child: Text('底层媒体库主页')),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('底层媒体库主页'), findsOneWidget);

      // 打开全屏沉浸音频页，稳态后底层主页应被 OverlayEntry.opaque 剪枝下线。
      container.read(audioPlaybackProvider.notifier).state = const AudioPlaybackState(
        isActive: true,
      );
      container.read(immersiveAudioExpandedProvider.notifier).state = true;
      await tester.pump();
      await tester.pumpAndSettle();
      expect(find.text('底层媒体库主页'), findsNothing);

      // 收起全屏音频页，必须立即还原透明并恢复底层主页可见。
      container.read(immersiveAudioExpandedProvider.notifier).state = false;
      await tester.pump();
      await tester.pumpAndSettle();
      expect(find.text('底层媒体库主页'), findsOneWidget);
    });
  });
}
