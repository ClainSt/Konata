import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:ccplayer/domain/models/media_variant.dart';
import 'package:ccplayer/domain/playback/playback_probe_stats.dart';
import 'package:ccplayer/domain/playback/track_preferences.dart';
import 'package:ccplayer/infrastructure/logging/diagnostics_log_store.dart';
import 'package:ccplayer/infrastructure/players/android/android_video_surface_controller.dart';
import 'package:ccplayer/infrastructure/players/embedded_mpv_session.dart';
import 'package:ccplayer/infrastructure/players/libmpv_ffi.dart';
import 'package:ccplayer/infrastructure/players/mpv_quality_profile.dart';
import 'package:ccplayer/infrastructure/players/windows_mpv_profile_adapter.dart';
import 'package:ccplayer/infrastructure/storage/storage_root_provider.dart';
import 'package:ccplayer/infrastructure/stream_bridge/local_stream_bridge.dart';

class _FakeLibMpvClient implements LibMpvClient {
  final Map<String, String> options = <String, String>{};
  final Map<String, String> stringProps = <String, String>{};
  final List<({String name, String value})> stringPropLog = [];
  final Map<String, bool> boolProps = <String, bool>{};
  final Map<String, int> intProps = <String, int>{};
  final Map<String, double> doubleProps = <String, double>{};
  final Set<String> failOptions = <String>{};
  final Set<String> failProps = <String>{};
  int nextErrorCode = MpvError.optionNotFound;

  final StreamController<MpvClientEvent> _events =
      StreamController<MpvClientEvent>.broadcast();

  @override
  bool isInitialized = true;

  @override
  bool isDisposed = false;

  @override
  int get handleAddress => 1;

  @override
  Stream<MpvClientEvent> get events => _events.stream;

  @override
  String errorString(int code) => 'err($code)';

  @override
  int setOptionString(String name, String value) {
    if (failOptions.contains(name)) return nextErrorCode;
    options[name] = value;
    return MpvError.success;
  }

  @override
  int initialize() => MpvError.success;

  @override
  int setPropertyString(String name, String value) {
    if (failProps.contains(name)) return MpvError.propertyNotFound;
    stringProps[name] = value;
    stringPropLog.add((name: name, value: value));
    return MpvError.success;
  }

  @override
  int setPropertyFlag(String name, bool value) {
    if (failProps.contains(name)) return MpvError.aoInitFailed;
    boolProps[name] = value;
    return MpvError.success;
  }

  @override
  int setPropertyInt64(String name, int value) {
    if (failProps.contains(name)) return MpvError.propertyUnavailable;
    intProps[name] = value;
    return MpvError.success;
  }

  @override
  int setPropertyDouble(String name, double value) {
    if (failProps.contains(name)) return MpvError.propertyNotFound;
    doubleProps[name] = value;
    return MpvError.success;
  }

  @override
  String? getPropertyString(String name) => stringProps[name];

  @override
  bool? getPropertyFlag(String name) => boolProps[name];

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
  List<MpvAudioDevice> readAudioDeviceList() => const [];

  @override
  List<MpvSeekableRange> readDemuxerSeekableRanges() => const [];

  @override
  int observeProperty(int replyUserdata, String name, int format) => 0;

  @override
  int requestLogMessages(String minLevel) => 0;

  @override
  int command(List<String> args) => 0;

  @override
  int commandAsync(int replyUserdata, List<String> args) => command(args);

  @override
  Future<void> dispose() async {
    isDisposed = true;
    await _events.close();
  }
}

class _FakeAndroidSurfaceController extends AndroidVideoSurfaceController {
  _FakeAndroidSurfaceController(this._initial) : super(77);

  AndroidSurfaceDescriptor? _initial;
  final StreamController<AndroidSurfaceDescriptor?> _changes =
      StreamController<AndroidSurfaceDescriptor?>.broadcast();
  final List<int> releasedRefs = [];

  @override
  AndroidSurfaceDescriptor? get current => _initial;

  @override
  Stream<AndroidSurfaceDescriptor?> get surfaceChanges => _changes.stream;

  @override
  Future<AndroidSurfaceDescriptor?> queryCurrent() async => _initial;

  @override
  Future<void> releaseReference(int wid) async {
    releasedRefs.add(wid);
  }

  @override
  Future<void> releaseSurface() async {
    _initial = null;
  }

  @override
  Future<void> dispose() async {
    await _changes.close();
  }

  void emit(AndroidSurfaceDescriptor? desc) {
    _initial = desc;
    if (!_changes.isClosed) {
      _changes.add(desc);
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('StorageRootService 便携根目录与截图分配测试', () {
    late Directory tempRoot;
    late StorageRootService storage;

    setUp(() async {
      tempRoot = await Directory.systemTemp.createTemp('konata_storage_test_');
      storage = StorageRootService(overrideRoot: tempRoot);
    });

    tearDown(() async {
      if (await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
    });

    test('所有运行期路径严格收口在便携根目录下，sync 查询不预建空目录', () async {
      final shadersSync = storage.resolveShadersDirSync();
      expect(shadersSync.existsSync(), isFalse);
      expect(
        shadersSync.path,
        equals(p.join(tempRoot.path, 'userdata', 'shaders')),
      );

      final mpvDir = await storage.ensureMpvConfigDir();
      final subStage = await storage.ensureSubtitleStageDir('work_hash_01');
      final shadersDir = await storage.ensureShadersDir();

      expect(mpvDir.existsSync(), isTrue);
      expect(subStage.existsSync(), isTrue);
      expect(shadersDir.existsSync(), isTrue);
      expect(p.isWithin(tempRoot.path, mpvDir.path), isTrue);
      expect(p.isWithin(tempRoot.path, subStage.path), isTrue);
      expect(p.isWithin(tempRoot.path, shadersDir.path), isTrue);
    });

    test('allocateWorkScreenshotFile 清洗非法文件名并自动递增避让重名', () async {
      final workDir = Directory(p.join(tempRoot.path, 'photos', 'Work [1]'));
      final ts = DateTime(2026, 3, 15, 21, 5, 9);

      final file1 = await storage.allocateWorkScreenshotFile(
        workPhotoDirectory: workDir,
        timestamp: ts,
        episodeTag: 'EP:01?/<bad>',
      );
      expect(p.basename(file1.path), equals('EP01bad_20260315_210509.png'));
      await file1.writeAsBytes([1, 2, 3]);

      final file2 = await storage.allocateWorkScreenshotFile(
        workPhotoDirectory: workDir,
        timestamp: ts,
        episodeTag: 'EP:01?/<bad>',
      );
      expect(
        p.basename(file2.path),
        equals('EP01bad_20260315_210509_1.png'),
      );
    });

    test('discoverShaderFiles 异步仅按排序收集 .glsl / .hook 脚本', () async {
      final shadersDir = await storage.ensureShadersDir();
      await File(p.join(shadersDir.path, 'b_sharpen.glsl')).writeAsString('//');
      await File(p.join(shadersDir.path, 'a_anime4k.hook')).writeAsString('//');
      await File(p.join(shadersDir.path, 'readme.txt')).writeAsString('ignore');

      final discovered = await MpvQualityProfile.discoverShaderFiles(
        shadersDir,
      );
      expect(
        discovered.map((f) => p.basename(f.path)).toList(),
        equals(['a_anime4k.hook', 'b_sharpen.glsl']),
      );
    });
  });

  group('MpvQualityProfile 与容错属性设置测试', () {
    late Directory tempRoot;

    setUp(() async {
      tempRoot = await Directory.systemTemp.createTemp('konata_mpv_profile_');
    });

    tearDown(() async {
      if (await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
    });

    test('四档预设正确映射滤波器与硬解选项，WASAPI 独占失败自动退回共享模式', () async {
      final mpvDir = Directory(p.join(tempRoot.path, 'userdata', 'mpv'))
        ..createSync(recursive: true);
      final client = _FakeLibMpvClient()..failProps.add('audio-exclusive');
      final logStore = DiagnosticsLogStore();
      logStore.setVerbose(true);

      final shaderFile = File(p.join(tempRoot.path, 'test.glsl'))
        ..writeAsStringSync('// shader');

      final config = PlaybackQualityConfig(
        preset: VideoQualityPreset.highFidelity,
        outputPipelineMode: VideoOutputPipelineMode.legacyTextureFallback,
        hardwareDecode: true,
        debandEnabled: true,
        exclusiveAudioOutput: true,
        audioResamplerPrecision: 28,
        activeShaderPaths: [
          shaderFile.path,
          p.join(tempRoot.path, 'missing.glsl'),
        ],
      );

      MpvQualityProfile.applyPreInitVideoOptions(
        client,
        config: config,
        mpvConfigDir: mpvDir,
        screenshotDir: tempRoot,
        isWindowsOverride: true,
        isAndroidOverride: false,
        desktopDelegate: const WindowsMpvProfileDelegate(),
        logStore: logStore,
      );

      expect(client.options['vo'], equals('libmpv'));
      expect(client.options['hwdec'], equals('d3d11va,d3d11va-copy,auto-safe'));
      expect(client.options['scale'], equals('ewa_lanczossharp'));
      expect(client.options['cscale'], equals('ewa_lanczossoft'));
      expect(client.options['fbo-format'], equals('rgb10_a2'));
      expect(client.options['hdr-compute-peak'], equals('no'));
      expect(client.options['cache-pause'], equals('no'));
      expect(client.options['deband'], equals('yes'));
      expect(
        client.options['audio-swresample-o'],
        equals('resampler=soxr,precision=28'),
      );
      expect(client.options['glsl-shaders'], equals(shaderFile.path));

      final notices = <String>[];
      MpvQualityProfile.applyPostInitVideoProperties(
        client,
        config: config,
        isWindowsOverride: true,
        desktopDelegate: const WindowsMpvProfileDelegate(),
        onExclusiveFallbackNotice: notices.add,
        logStore: logStore,
      );
      expect(notices, hasLength(1));
      expect(notices.single, contains('共享'));

      // 纯软件兜底档与纯音频前置
      final swHwdec = MpvQualityProfile.resolveHwdecValue(
        config: const PlaybackQualityConfig(
          preset: VideoQualityPreset.softwareFallback,
        ),
        isWindows: true,
        isAndroid: false,
      );
      expect(swHwdec, equals('no'));

      final audioClient = _FakeLibMpvClient();
      MpvQualityProfile.applyPreInitAudioOptions(
        audioClient,
        config: config,
        mpvConfigDir: mpvDir,
        isWindowsOverride: true,
        logStore: logStore,
      );
      expect(audioClient.options['vid'], equals('no'));
      expect(audioClient.options['vo'], equals('null'));
      expect(audioClient.options['keep-open'], equals('no'));
      expect(audioClient.options['loop-file'], equals('no'));
      expect(audioClient.options['loop-playlist'], equals('no'));
      expect(audioClient.options['cache-pause'], equals('no'));
      expect(audioClient.options['gapless-audio'], equals('weak'));
    });

    test('MpvSafePropertySetter 拦截兼容性错误码不抛异常且写入日志', () {
      final client = _FakeLibMpvClient()..failOptions.add('legacy-opt');
      final logStore = DiagnosticsLogStore();
      logStore.setVerbose(true);
      final setter = MpvSafePropertySetter(logStore: logStore);

      final ok = setter.setOption(client, 'legacy-opt', '1');
      expect(ok, isFalse);
      expect(
        logStore.buildRecentIncidentReport(),
        contains('[option:legacy-opt=1] skipped'),
      );
    });

    test('字幕热更新在 Scale / Force / Preserve 三模式下精确写入 sub-scale、浮点字号与边距', () {
      final client = _FakeLibMpvClient();

      // 1. Scale 模式：sub-scale 按 64 / 52 比例缩放，字号保持基准 52.0 (double)
      MpvQualityProfile.applyLiveQualityUpdate(
        client,
        config: const PlaybackQualityConfig(
          subFontSize: 64,
          subBottomMargin: 28,
          subOverrideMode: SubtitleAssOverrideMode.scaleOnly,
        ),
        isWindowsOverride: true,
        isAndroidOverride: false,
      );
      expect(client.stringProps['sub-ass-override'], equals('scale'));
      expect(client.doubleProps['sub-font-size'], equals(52.0));
      expect(client.doubleProps['sub-scale'], closeTo(64.0 / 52.0, 1e-4));

      // 2. Force 模式：强制覆写字号 68.0 (double)、底部边距 0 (int) 与 sub-ass-force-margins
      MpvQualityProfile.applyLiveQualityUpdate(
        client,
        config: const PlaybackQualityConfig(
          subFontSize: 68,
          subBottomMargin: 0,
          subOverrideMode: SubtitleAssOverrideMode.forceStyle,
        ),
        isWindowsOverride: true,
        isAndroidOverride: false,
      );
      expect(client.stringProps['sub-ass-override'], equals('force'));
      expect(client.doubleProps['sub-font-size'], equals(68.0));
      expect(client.doubleProps['sub-scale'], equals(1.0));
      expect(client.intProps['sub-margin-y'], equals(0));
      expect(client.boolProps['sub-ass-force-margins'], isTrue);

      // 3. Preserve 模式：还原 ASS 原生样式与 1.0x 缩放
      MpvQualityProfile.applyLiveQualityUpdate(
        client,
        config: const PlaybackQualityConfig(
          subFontSize: 52,
          subBottomMargin: 28,
          subOverrideMode: SubtitleAssOverrideMode.preserveAss,
        ),
        isWindowsOverride: true,
        isAndroidOverride: false,
      );
      expect(client.stringProps['sub-ass-override'], equals('no'));
      expect(client.doubleProps['sub-scale'], equals(1.0));
      expect(client.boolProps['sub-ass-force-margins'], isFalse);
    });

    test('存在 native/konata-native/windows/libmpv-2.dll 时真实探针返回可用版本', () async {
      final dll = File(
        p.join(
          Directory.current.path,
          'native',
          'konata-native',
          'windows',
          'libmpv-2.dll',
        ),
      );
      if (Platform.isWindows) {
        expect(
          dll.existsSync(),
          isTrue,
          reason: 'Windows 仓库必须包含 native/konata-native/windows/libmpv-2.dll 以执行真实探针断言',
        );
      }
      final probe = await MpvQualityProfile.probeRuntimeVersions(
        preferredLibraryPath: dll.path,
        clientFactory: FfiLibMpvClient.create,
      );
      expect(probe.isAvailable, isTrue);
      expect(probe.mpvVersion, isNotEmpty);
    });

    test('Android 视频前置配置启用 opengl-es 与 rgb10_a2 并延时初始化 vo=null', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'konata_android_mpv_cfg_',
      );
      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });
      final storage = StorageRootService(overrideRoot: tempDir);
      final client = _FakeLibMpvClient();
      final mpvDir = await storage.ensureMpvConfigDir();

      MpvQualityProfile.applyPreInitVideoOptions(
        client,
        config: const PlaybackQualityConfig(),
        mpvConfigDir: mpvDir,
        isWindowsOverride: false,
        isAndroidOverride: true,
      );

      expect(client.options['vo'], equals('null'));
      expect(client.options['gpu-context'], equals('android'));
      expect(client.options['gpu-api'], equals('opengl'));
      expect(client.options['opengl-es'], equals('yes'));
      expect(client.options['egl-output-format'], equals('rgb10_a2'));
      expect(client.options['hwdec'], equals('mediacodec,mediacodec-copy,auto-safe'));
      expect(client.options['sub-font-provider'], equals('none'));
      expect(
        client.options['sub-font'],
        equals(MpvQualityProfile.defaultAndroidCjkSubFontFamily),
      );
      expect(client.options.containsKey('fbo-format'), isFalse);
    });

    test(
      'EmbeddedMpvSession 按序绑定 android-hdr-peak/surface-size/wid/vo 且同表面尺寸变更不重开 vo',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'konata_android_mpv_sess_',
        );
        addTearDown(() async {
          if (await tempDir.exists()) await tempDir.delete(recursive: true);
        });
        final storage = StorageRootService(overrideRoot: tempDir);
        final bridge = LocalStreamBridge(storageRoot: storage);
        addTearDown(bridge.dispose);
        final client = _FakeLibMpvClient();
        const initialDesc = AndroidSurfaceDescriptor(
          wid: 42,
          width: 1220,
          height: 2712,
          hdrPeak: 1000.0,
        );
        final fakeSurface = _FakeAndroidSurfaceController(initialDesc);

        final session = EmbeddedMpvSession(
          storageRoot: storage,
          streamBridge: bridge,
          clientFactory: () => client,
        );
        addTearDown(session.dispose);

        const variant = MediaVariant(
          id: 'v_android',
          workId: 'w_android',
          sourceId: 's_android',
          relativePath: '01.mkv',
          fileName: '01.mkv',
          fileSize: 1024,
        );

        await session.initializeAndLoad(
          request: const EmbeddedVideoLoadRequest(
            workId: 'w_android',
            variant: variant,
          ),
          qualityConfig: const PlaybackQualityConfig(),
          androidSurfaceSupplier: () async => fakeSurface,
        );

        final bindSequence = client.stringPropLog
            .where(
              (e) =>
                  e.name == 'android-hdr-peak' ||
                  e.name == 'android-surface-size' ||
                  e.name == 'wid' ||
                  e.name == 'vo',
            )
            .map((e) => '${e.name}=${e.value}')
            .toList();
        expect(
          bindSequence,
          containsAllInOrder([
            'vo=null',
            'wid=0',
            'android-hdr-peak=1000',
            'android-surface-size=1220x2712',
            'wid=42',
            'vo=${MpvQualityProfile.androidVideoDriver}',
          ]),
        );

        // 同 Surface 旋转或全屏切换时仅更新 android-surface-size，绝不重置 vo 与 wid
        client.stringPropLog.clear();
        fakeSurface.emit(
          const AndroidSurfaceDescriptor(
            wid: 42,
            width: 2712,
            height: 1220,
            hdrPeak: 1000.0,
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 30));

        final resizeLog = client.stringPropLog
            .map((e) => '${e.name}=${e.value}')
            .toList();
        expect(resizeLog, equals(['android-surface-size=2712x1220']));
      },
    );

    test('移动端视频与纯音频前置选项回退原生高精度重采样器，禁止强制启用缺失的 soxr', () {
      final mpvDir = Directory(p.join(tempRoot.path, 'userdata', 'mpv_android'))
        ..createSync(recursive: true);
      const config = PlaybackQualityConfig(audioResamplerPrecision: 28);

      final videoClient = _FakeLibMpvClient();
      MpvQualityProfile.applyPreInitVideoOptions(
        videoClient,
        config: config,
        mpvConfigDir: mpvDir,
        isWindowsOverride: false,
        isAndroidOverride: true,
      );
      expect(
        videoClient.options['audio-swresample-o'],
        equals('resampler=swr,filter_size=32,phase_shift=10,cutoff=0.97'),
      );

      final audioClient = _FakeLibMpvClient();
      MpvQualityProfile.applyPreInitAudioOptions(
        audioClient,
        config: config,
        mpvConfigDir: mpvDir,
        isWindowsOverride: false,
      );
      expect(
        audioClient.options['audio-swresample-o'],
        equals('resampler=swr,filter_size=32,phase_shift=10,cutoff=0.97'),
      );
    });
  });
}
