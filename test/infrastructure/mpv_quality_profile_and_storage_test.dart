import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:ccplayer/domain/playback/playback_probe_stats.dart';
import 'package:ccplayer/domain/playback/track_preferences.dart';
import 'package:ccplayer/infrastructure/logging/diagnostics_log_store.dart';
import 'package:ccplayer/infrastructure/players/libmpv_ffi.dart';
import 'package:ccplayer/infrastructure/players/mpv_quality_profile.dart';
import 'package:ccplayer/infrastructure/storage/storage_root_provider.dart';

class _FakeLibMpvClient implements LibMpvClient {
  final Map<String, String> options = <String, String>{};
  final Map<String, String> stringProps = <String, String>{};
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
  int commandAsync(int replyUserdata, List<String> args) => 0;

  @override
  Future<void> dispose() async {
    isDisposed = true;
    await _events.close();
  }
}

void main() {
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

    test('discoverShaderFilesSync 仅按排序收集 .glsl / .hook 脚本', () async {
      final shadersDir = await storage.ensureShadersDir();
      await File(p.join(shadersDir.path, 'b_sharpen.glsl')).writeAsString('//');
      await File(p.join(shadersDir.path, 'a_anime4k.hook')).writeAsString('//');
      await File(p.join(shadersDir.path, 'readme.txt')).writeAsString('ignore');

      final discovered = MpvQualityProfile.discoverShaderFilesSync(shadersDir);
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
        hardwareDecode: true,
        debandEnabled: true,
        wasapiExclusive: true,
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
        logStore: logStore,
      );

      expect(client.options['vo'], equals('libmpv'));
      expect(client.options['hwdec'], equals('d3d11va,d3d11va-copy,auto-safe'));
      expect(client.options['scale'], equals('ewa_lanczossharp'));
      expect(client.options['cscale'], equals('ewa_lanczossoft'));
      expect(client.options['fbo-format'], equals('rgba16hf'));
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
        onWasapiFallbackNotice: notices.add,
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
      expect(audioClient.options['cache-pause'], equals('no'));
      expect(audioClient.options['gapless-audio'], equals('yes'));
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
      if (!dll.existsSync()) {
        return;
      }
      final probe = await MpvQualityProfile.probeRuntimeVersions(
        preferredLibraryPath: dll.path,
      );
      expect(probe.isAvailable, isTrue);
      expect(probe.mpvVersion, isNotEmpty);
    });
  });
}
