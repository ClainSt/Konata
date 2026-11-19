import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ccplayer/application/playback/playback_preferences_provider.dart';
import 'package:ccplayer/application/playback/video_playback_controller.dart';
import 'package:ccplayer/application/providers/library_providers.dart';
import 'package:ccplayer/composition/windows_composition_root.dart';
import 'package:ccplayer/domain/models/episode.dart';
import 'package:ccplayer/domain/models/media_source.dart';
import 'package:ccplayer/domain/models/media_variant.dart';
import 'package:ccplayer/domain/models/work.dart';
import 'package:ccplayer/domain/playback/hwdec_safety_policy.dart';
import 'package:ccplayer/domain/playback/playback_probe_stats.dart';
import 'package:ccplayer/domain/playback/track_preferences.dart';
import 'package:ccplayer/infrastructure/database/drift_library_repository.dart';
import 'package:ccplayer/infrastructure/database/konata_database.dart';
import 'package:ccplayer/infrastructure/players/android/android_video_surface_controller.dart';
import 'package:ccplayer/infrastructure/players/embedded_mpv_session.dart';
import 'package:ccplayer/infrastructure/players/libmpv_ffi.dart';
import 'package:ccplayer/infrastructure/players/mpv_quality_profile.dart';
import 'package:ccplayer/infrastructure/storage/storage_root_provider.dart';
import 'package:ccplayer/infrastructure/stream_bridge/local_stream_bridge.dart';

class _Step2FakeMpvClient implements LibMpvClient, LibMpvUnobservable {
  final Map<String, String> options = <String, String>{};
  final Map<String, String> stringProps = <String, String>{};
  final Map<String, double> doubleProps = <String, double>{};
  final Map<String, bool> boolProps = <String, bool>{};
  final List<List<String>> commands = <List<String>>[];
  final List<String> observedProps = <String>[];
  final List<int> unobservedIds = <int>[];
  final Set<String> failStringProps = <String>{};
  final StreamController<MpvClientEvent> _events =
      StreamController<MpvClientEvent>.broadcast();
  List<PlaybackChapter> chapters = const [];

  @override
  bool isInitialized = false;

  @override
  bool isDisposed = false;

  @override
  int get handleAddress => 7;

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
    return MpvError.success;
  }

  @override
  int initialize() {
    isInitialized = true;
    return MpvError.success;
  }

  @override
  int setPropertyString(String name, String value) {
    if (failStringProps.contains('$name=$value')) {
      return MpvError.voInitFailed;
    }
    stringProps[name] = value;
    return MpvError.success;
  }

  @override
  int setPropertyFlag(String name, bool value) {
    boolProps[name] = value;
    return MpvError.success;
  }

  @override
  int setPropertyInt64(String name, int value) => MpvError.success;

  @override
  int setPropertyDouble(String name, double value) {
    doubleProps[name] = value;
    return MpvError.success;
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
  List<MpvTrackInfo> readTrackList() => const [];

  @override
  List<PlaybackChapter> readChapterList({double? totalDurationSeconds}) =>
      chapters;

  @override
  List<MpvAudioDevice> readAudioDeviceList() => const [];

  @override
  List<MpvSeekableRange> readDemuxerSeekableRanges() => const [];

  @override
  int observeProperty(int replyUserdata, String name, int format) {
    observedProps.add('$replyUserdata:$name');
    return MpvError.success;
  }

  @override
  int unobserveProperty(int registeredReplyUserdata) {
    unobservedIds.add(registeredReplyUserdata);
    return MpvError.success;
  }

  @override
  int requestLogMessages(String minLevel) => MpvError.success;

  @override
  int command(List<String> args) {
    commands.add(List<String>.from(args));
    if (args.length >= 3 && args[0] == 'screenshot-to-file') {
      final outFile = File(args[1]);
      outFile.parent.createSync(recursive: true);
      outFile.writeAsBytesSync(const <int>[0x89, 0x50, 0x4E, 0x47, 1, 2, 3, 4]);
    }
    return MpvError.success;
  }

  @override
  int commandAsync(int replyUserdata, List<String> args) => command(args);

  @override
  Future<void> dispose() async {
    isDisposed = true;
    await _events.close();
  }
}

class _Step2FakeAndroidSurface extends AndroidVideoSurfaceController {
  _Step2FakeAndroidSurface(this._desc) : super(0);

  AndroidSurfaceDescriptor? _desc;

  @override
  AndroidSurfaceDescriptor? get current => _desc;

  @override
  Future<AndroidSurfaceDescriptor?> queryCurrent() async => _desc;

  @override
  Future<void> releaseReference(int wid) async {}

  @override
  Future<void> releaseSurface() async {
    _desc = null;
  }

  @override
  Future<void> dispose() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Step 2 · 解码层 Hi10P / HEVC Rext 拦截策略', () {
    test('精准拦截 AVC Hi10P / 4:2:2 / 4:4:4 与 HEVC Rext / 12-bit，放行标准 8/10-bit 4:2:0', () {
      final hi10Android = HwdecSafetyPolicy.evaluate(
        platform: HwdecPlatformKind.android,
        videoCodec: 'h264',
        videoProfile: 'High 10',
        pixelFormat: 'yuv420p10le',
      );
      expect(hi10Android.allowHardwareDecode, isFalse);
      expect(hi10Android.matchedRule, equals('avc_hi10p'));

      final hevcRextAndroid = HwdecSafetyPolicy.evaluate(
        platform: HwdecPlatformKind.android,
        videoCodec: 'hevc',
        videoProfile: 'Rext',
        pixelFormat: 'yuv422p10le',
      );
      expect(hevcRextAndroid.allowHardwareDecode, isFalse);
      expect(hevcRextAndroid.matchedRule, equals('hevc_rext_android'));

      final hevcMain10Android = HwdecSafetyPolicy.evaluate(
        platform: HwdecPlatformKind.android,
        videoCodec: 'hevc',
        videoProfile: 'Main 10',
        pixelFormat: 'yuv420p10le',
      );
      expect(hevcMain10Android.allowHardwareDecode, isTrue);

      final h264Main8 = HwdecSafetyPolicy.evaluate(
        platform: HwdecPlatformKind.android,
        videoCodec: 'h264',
        videoProfile: 'High',
        pixelFormat: 'yuv420p',
      );
      expect(h264Main8.allowHardwareDecode, isTrue);

      // 严防将 H.264 规范全称 "MPEG-4 part 10" 误判为 Hi10P 10-bit 而关闭 8-bit 硬解。
      final h264Part10Desc = HwdecSafetyPolicy.evaluate(
        platform: HwdecPlatformKind.windows,
        videoCodec: 'h264 (H.264 / AVC / MPEG-4 AVC / MPEG-4 part 10)',
        videoProfile: 'h264 (H.264 / AVC / MPEG-4 AVC / MPEG-4 part 10)',
        pixelFormat: 'yuv420p',
      );
      expect(h264Part10Desc.allowHardwareDecode, isTrue);

      final hevc12Win = HwdecSafetyPolicy.evaluate(
        platform: HwdecPlatformKind.windows,
        videoCodec: 'hevc',
        videoProfile: 'Main 12',
        pixelFormat: 'yuv420p12le',
      );
      expect(hevc12Win.allowHardwareDecode, isFalse);
      expect(hevc12Win.matchedRule, equals('hevc_gt10bit'));
    });

    test('EmbeddedMpvSession 收到 Hi10P 重配置时立即切软解，并在 gpu-next 失败时回落 gpu', () async {
      final tempDir = await Directory.systemTemp.createTemp('konata_step2_hw_');
      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });
      final storage = StorageRootService(overrideRoot: tempDir);
      final bridge = LocalStreamBridge(storageRoot: storage);
      addTearDown(bridge.dispose);

      final client = _Step2FakeMpvClient()
        ..failStringProps.add('vo=gpu-next')
        ..stringProps['video-format'] = 'h264'
        ..stringProps['video-params/profile'] = 'High 10'
        ..stringProps['video-params/pixelformat'] = 'yuv420p10le';
      final notices = <String>[];

      final session = EmbeddedMpvSession(
        storageRoot: storage,
        streamBridge: bridge,
        clientFactory: () => client,
      )..onNotice = notices.add;
      addTearDown(session.dispose);

      const variant = MediaVariant(
        id: 'v_hi10',
        workId: 'w_hi10',
        sourceId: 's_hi10',
        relativePath: '01_hi10p.mkv',
        fileName: '01_hi10p.mkv',
        fileSize: 2048,
      );

      await session.initializeAndLoad(
        request: const EmbeddedVideoLoadRequest(
          workId: 'w_hi10',
          variant: variant,
        ),
        qualityConfig: const PlaybackQualityConfig(),
        androidSurfaceSupplier: () async => _Step2FakeAndroidSurface(
          const AndroidSurfaceDescriptor(
            wid: 88,
            width: 1920,
            height: 1080,
            hdrPeak: 1000,
          ),
        ),
      );

      expect(client.stringProps['vo'], equals('gpu'));
      expect(session.renderBackendListenable.value, equals('gpu'));

      client.emitEvent(const MpvFileLoadedEvent());
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(client.stringProps['hwdec'], equals('no'));
      expect(client.stringProps['vd-lavc-threads'], equals('0'));
      expect(session.isUsingSoftwareFallback, isTrue);
      expect(notices.any((m) => m.contains('Hi10P')), isTrue);
      expect(
        client.commands.any((cmd) => cmd.length == 1 && cmd.first == 'video-reload'),
        isTrue,
      );
    });

    test('移动端在未解码出像素格式前通过轨道档位识别 HEVC Rext 并触发 video-reload 软解', () async {
      final tempDir = await Directory.systemTemp.createTemp('konata_step2_rext_');
      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });
      final storage = StorageRootService(overrideRoot: tempDir);
      final bridge = LocalStreamBridge(storageRoot: storage);
      addTearDown(bridge.dispose);

      // 模拟真实 MediaCodec 尚未输出首帧（video-params/pixelformat 缺失）但解复用轨道已上报 Rext 档位。
      final client = _Step2FakeMpvClient()
        ..stringProps['current-tracks/video/codec'] = 'hevc'
        ..stringProps['current-tracks/video/codec-profile'] = 'Rext';
      final notices = <String>[];

      final session = EmbeddedMpvSession(
        storageRoot: storage,
        streamBridge: bridge,
        clientFactory: () => client,
      )..onNotice = notices.add;
      addTearDown(session.dispose);

      const variant = MediaVariant(
        id: 'v_rext',
        workId: 'w_rext',
        sourceId: 's_rext',
        relativePath: 'g06_main12.mkv',
        fileName: 'g06_main12.mkv',
        fileSize: 4096,
      );

      await session.initializeAndLoad(
        request: const EmbeddedVideoLoadRequest(
          workId: 'w_rext',
          variant: variant,
        ),
        qualityConfig: const PlaybackQualityConfig(),
        androidSurfaceSupplier: () async => _Step2FakeAndroidSurface(
          const AndroidSurfaceDescriptor(
            wid: 89,
            width: 3840,
            height: 2160,
            hdrPeak: 1000,
          ),
        ),
      );

      client.emitEvent(const MpvFileLoadedEvent());
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(client.stringProps['hwdec'], equals('no'));
      expect(client.stringProps['vd-lavc-threads'], equals('0'));
      expect(session.isUsingSoftwareFallback, isTrue);
      expect(
        client.commands.any((cmd) => cmd.length == 1 && cmd.first == 'video-reload'),
        isTrue,
      );
      expect(notices.any((m) => m.contains('Rext')), isTrue);
    });
  });

  group('Step 2 · 双模原画截图与 OSD 静默零唤醒退订', () {
    test('双模截图经 FFI 参数数组下发，Android MediaStore 事务发布后幂等删除临时文件', () async {
      final tempDir = await Directory.systemTemp.createTemp('konata_step2_cap_');
      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });
      final storage = StorageRootService(overrideRoot: tempDir);
      final bridge = LocalStreamBridge(storageRoot: storage);
      addTearDown(bridge.dispose);
      final client = _Step2FakeMpvClient();
      final session = EmbeddedMpvSession(
        storageRoot: storage,
        streamBridge: bridge,
        clientFactory: () => client,
      );
      addTearDown(session.dispose);

      const variant = MediaVariant(
        id: 'v_cap',
        workId: 'w_cap',
        sourceId: 's_cap',
        relativePath: '01.mkv',
        fileName: '01.mkv',
        fileSize: 1024,
      );
      await session.initializeAndLoad(
        request: const EmbeddedVideoLoadRequest(
          workId: 'w_cap',
          variant: variant,
        ),
        qualityConfig: const PlaybackQualityConfig(),
      );

      final photoDir = Directory(p.join(tempDir.path, 'photos', 'Work [1]'));
      final pureRes = await session.captureScreenshot(
        workPhotoDir: photoDir,
        episodeTag: 'EP01',
        mode: ScreenshotCaptureMode.pureVideo,
      );
      expect(pureRes, isNotNull);
      expect(pureRes!.file, isNotNull);
      expect(pureRes.file!.existsSync(), isTrue);
      expect(
        client.commands.last,
        equals(['screenshot-to-file', pureRes.file!.path, 'video']),
      );

      File? publishedTempFile;
      final subRes = await session.captureScreenshot(
        workPhotoDir: photoDir,
        episodeTag: 'EP01',
        mode: ScreenshotCaptureMode.withSubtitles,
        androidMediaStorePublisher: (tempFile, displayName, album) async {
          publishedTempFile = tempFile;
          expect(tempFile.existsSync(), isTrue);
          expect(album, equals('Konata'));
          return 'content://media/external/images/media/9527';
        },
      );
      expect(subRes, isNotNull);
      expect(subRes!.galleryUri, equals('content://media/external/images/media/9527'));
      expect(subRes.file, isNull);
      expect(publishedTempFile, isNotNull);
      expect(publishedTempFile!.existsSync(), isFalse);
      expect(client.commands.last[2], equals('subtitles'));
    });

    test('OSD 隐藏静默期退订 time-pos 后 0 次进度状态唤醒，唤醒后即时同步最新秒数', () async {
      final tempDir = await Directory.systemTemp.createTemp('konata_step2_osd_');
      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });
      final storage = StorageRootService(overrideRoot: tempDir);
      final bridge = LocalStreamBridge(storageRoot: storage);
      addTearDown(bridge.dispose);
      final client = _Step2FakeMpvClient();
      final session = EmbeddedMpvSession(
        storageRoot: storage,
        streamBridge: bridge,
        clientFactory: () => client,
      );
      addTearDown(session.dispose);

      final receivedPositions = <double>[];
      session.onPositionChanged = receivedPositions.add;

      const variant = MediaVariant(
        id: 'v_osd',
        workId: 'w_osd',
        sourceId: 's_osd',
        relativePath: '01.mkv',
        fileName: '01.mkv',
        fileSize: 1024,
      );
      await session.initializeAndLoad(
        request: const EmbeddedVideoLoadRequest(
          workId: 'w_osd',
          variant: variant,
        ),
        qualityConfig: const PlaybackQualityConfig(),
      );

      // 挂起高频订阅
      session.setPositionObservationEnabled(false);
      expect(client.unobservedIds, contains(201));

      // 模拟底层仍存在迟到 time-pos 事件：必须 0 回调唤醒
      client.emitEvent(
        const MpvPropertyChangeEvent(
          name: 'time-pos',
          replyUserdata: 201,
          format: MpvFormat.double_,
          doubleValue: 42.5,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(receivedPositions, isEmpty);

      // OSD 唤醒后重新订阅并立即拉取当前精确秒数
      client.doubleProps['time-pos'] = 88.25;
      session.setPositionObservationEnabled(true);
      expect(receivedPositions, equals([88.25]));
    });
  });

  group('Step 2 · 无名 ~90s 层级二章节严格禁自动跳', () {
    test('autoSkipChapter=true 时仅层级一显式命名自动跳，层级二无名候选仅弹手动胶囊', () async {
      final tempDir = await Directory.systemTemp.createTemp('konata_step2_ch_');
      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });
      final storage = StorageRootService(overrideRoot: tempDir);
      final bridge = LocalStreamBridge(storageRoot: storage);
      addTearDown(bridge.dispose);
      final client = _Step2FakeMpvClient()
        ..chapters = const [
          PlaybackChapter(index: 0, title: 'Chapter 1', startSeconds: 0, endSeconds: 90),
          PlaybackChapter(index: 1, title: 'Chapter 2', startSeconds: 90, endSeconds: 1350),
          PlaybackChapter(index: 2, title: 'Ending', startSeconds: 1350, endSeconds: 1440),
        ];

      const work = Work(id: 'w_ch', title: '测试番剧');
      const episode = Episode(
        id: 'e_ch',
        workId: 'w_ch',
        category: EpisodeCategory.main,
        seasonNumber: 1,
        episodeNumber: 1,
      );
      const variant = MediaVariant(
        id: 'v_ch',
        workId: 'w_ch',
        sourceId: 's_ch',
        relativePath: '01.mkv',
        fileName: '01.mkv',
        fileSize: 1024,
      );
      const bundle = WorkDetailBundle(
        work: work,
        episodes: [episode],
        variants: [variant],
        sourcesById: {},
        latestPlayback: null,
      );
      final request = VideoLaunchRequest(
        work: work,
        episode: episode,
        variant: variant,
        bundle: bundle,
      );

      final db = KonataDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final repo = DriftLibraryRepository(db);
      await repo.upsertMediaSource(
        const MediaSource(
          id: 's_ch',
          kind: MediaSourceKind.local,
          label: 'Local',
          location: 'D:/Anime',
        ),
      );
      await repo.upsertWork(work);
      await repo.upsertEpisode(episode);
      await repo.upsertMediaVariant(variant);
      final container = ProviderContainer(
        overrides: [
          ...WindowsCompositionRoot.providerOverrides(),
          storageRootProvider.overrideWithValue(storage),
          libraryRepositoryProvider.overrideWithValue(repo),
          videoPlaybackProvider(request).overrideWith(
            (ref) => VideoPlaybackController(
              ref,
              request,
              sessionFactory: () => EmbeddedMpvSession(
                storageRoot: storage,
                streamBridge: bridge,
                clientFactory: () => client,
              ),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      SharedPreferences.setMockInitialValues({});
      // 开启自动跳过开关，并保持 autoDispose 控制器存活
      await container
          .read(playbackPreferencesProvider.notifier)
          .setAutoSkipChapter(true);
      final keepAliveSub = container.listen(
        videoPlaybackProvider(request),
        (_, _) {},
      );
      addTearDown(keepAliveSub.close);
      final ctrl = container.read(videoPlaybackProvider(request).notifier);
      await Future<void>.delayed(const Duration(milliseconds: 80));

      // 注入总时长 24 分钟触发章节计划构建
      client.emitEvent(
        const MpvPropertyChangeEvent(
          name: 'duration',
          replyUserdata: 202,
          format: MpvFormat.double_,
          doubleValue: 1440.0,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 25));

      // 落入无名 90s 层级二 OP（0~90s）：绝不自动 seek，仅展示手动胶囊
      client.commands.clear();
      client.emitEvent(
        const MpvPropertyChangeEvent(
          name: 'time-pos',
          replyUserdata: 201,
          format: MpvFormat.double_,
          doubleValue: 12.0,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 25));
      final stateInTier2 = container.read(videoPlaybackProvider(request));
      expect(stateInTier2.activeSkipWindow, isNotNull);
      expect(stateInTier2.activeSkipWindow!.isTier1Named, isFalse);
      expect(stateInTier2.activeSkipWindow!.allowsAutoSkip, isFalse);
      expect(
        client.commands.where((c) => c.isNotEmpty && c.first == 'seek'),
        isEmpty,
      );

      // 落入显式命名层级一 ED（1350~1440s）：允许自动跳过并下发 seek
      client.emitEvent(
        const MpvPropertyChangeEvent(
          name: 'time-pos',
          replyUserdata: 201,
          format: MpvFormat.double_,
          doubleValue: 1360.0,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 25));
      expect(
        client.commands.any(
          (c) => c.length >= 2 && c.first == 'seek' && c[1] == '1440.000',
        ),
        isTrue,
      );
      await ctrl.closeAndRelease();
    });
  });

  group('Step 2 · Windows 原生 libmpv HDR/色调映射与退订实证', () {
    test('真实 libmpv-2.dll 接受 bt.2446a / hdr-compute-peak / rgba16hf / unobserve_property', () async {
      if (!Platform.isWindows) return;
      final dll = File(
        p.join(
          Directory.current.path,
          'native',
          'konata-native',
          'windows',
          'libmpv-2.dll',
        ),
      );
      expect(
        dll.existsSync(),
        isTrue,
        reason: 'Windows 环境必须存在真实 libmpv-2.dll，禁止静默跳过',
      );

      final client = FfiLibMpvClient.create(preferredLibraryPath: dll.path);
      addTearDown(client.dispose);

      expect(client.setOptionString('vo', 'null'), greaterThanOrEqualTo(0));
      expect(client.setOptionString('ao', 'null'), greaterThanOrEqualTo(0));
      expect(
        client.setOptionString('fbo-format', 'rgba16hf'),
        greaterThanOrEqualTo(0),
      );
      expect(
        client.setOptionString('tone-mapping', 'bt.2446a'),
        greaterThanOrEqualTo(0),
      );
      expect(
        client.setOptionString('hdr-compute-peak', 'yes'),
        greaterThanOrEqualTo(0),
      );
      expect(
        client.setOptionString('vd-lavc-threads', '0'),
        greaterThanOrEqualTo(0),
      );
      expect(client.initialize(), greaterThanOrEqualTo(0));

      expect(
        client.observeProperty(9901, 'time-pos', MpvFormat.double_),
        greaterThanOrEqualTo(0),
      );
      expect(client.unobserveProperty(9901), greaterThanOrEqualTo(0));
    });
  });
}
