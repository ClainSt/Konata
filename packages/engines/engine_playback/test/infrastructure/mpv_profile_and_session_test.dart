import 'dart:async';
import 'dart:io';

import 'package:engine_playback/engine_playback.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/playback_test_fixtures.dart';

void main() {
  group('MpvQualityProfile 与容错属性设置测试', () {
    late Directory tempRoot;

    setUp(() {
      tempRoot = Directory.systemTemp.createTempSync('konata_mpv_profile_');
    });

    tearDown(() {
      if (tempRoot.existsSync()) {
        tempRoot.deleteSync(recursive: true);
      }
    });

    test('四档预设正确映射滤波器与硬解选项，WASAPI 独占失败自动退回共享模式', () {
      final mpvDir = Directory(p.join(tempRoot.path, 'userdata', 'mpv'))
        ..createSync(recursive: true);
      final client = FakeLibMpvClient()..failProps.add('audio-exclusive');
      final shaderFile = File(p.join(tempRoot.path, 'test.glsl'))
        ..writeAsStringSync('// 模拟着色器');

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
      );

      expect(client.options['vo'], equals('libmpv'));
      expect(client.options['hwdec'], equals('d3d11va,d3d11va-copy,auto-safe'));
      expect(client.options['scale'], equals('ewa_lanczossharp'));
      expect(client.options['cscale'], equals('ewa_lanczos'));
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
      );
      expect(notices, hasLength(1));
      expect(notices.single, contains('共享'));

      expect(
        MpvQualityProfile.resolveHwdecValue(
          config: const PlaybackQualityConfig(
            preset: VideoQualityPreset.softwareFallback,
          ),
          isWindows: true,
          isAndroid: false,
        ),
        equals('no'),
      );

      final audioClient = FakeLibMpvClient();
      MpvQualityProfile.applyPreInitAudioOptions(
        audioClient,
        config: config,
        mpvConfigDir: mpvDir,
        isWindowsOverride: true,
      );
      expect(audioClient.options['vid'], equals('no'));
      expect(audioClient.options['vo'], equals('null'));
      expect(audioClient.options['keep-open'], equals('no'));
      expect(audioClient.options['gapless-audio'], equals('weak'));
    });

    test('移动端视频与纯音频前置配置规避 soxr，字幕样式热更新精准写入属性', () {
      final mpvDir = Directory(p.join(tempRoot.path, 'android_mpv'))
        ..createSync(recursive: true);
      final client = FakeLibMpvClient();

      MpvQualityProfile.applyPreInitVideoOptions(
        client,
        config: const PlaybackQualityConfig(),
        mpvConfigDir: mpvDir,
        screenshotDir: tempRoot,
        isWindowsOverride: false,
        isAndroidOverride: true,
      );
      expect(client.options['vo'], equals('null'));
      expect(client.options['gpu-api'], equals('opengl'));
      expect(client.options['opengl-es'], equals('yes'));
      expect(client.options['audio-swresample-o'], contains('resampler=swr'));
      expect(client.options['audio-swresample-o'], isNot(contains('soxr')));

      final audioClient = FakeLibMpvClient();
      MpvQualityProfile.applyPreInitAudioOptions(
        audioClient,
        config: const PlaybackQualityConfig(),
        mpvConfigDir: mpvDir,
        isWindowsOverride: false,
      );
      expect(audioClient.options['audio-swresample-o'], contains('resampler=swr'));
      expect(audioClient.options['audio-swresample-o'], isNot(contains('soxr')));

      MpvQualityProfile.applyLiveSubtitleStyleUpdate(
        client,
        config: const PlaybackQualityConfig(
          subOverrideMode: SubtitleAssOverrideMode.forceStyle,
          subFontSize: 60,
          subBottomMargin: 32,
        ),
      );
      expect(client.stringProps['sub-ass-override'], equals('force'));
      expect(client.doubleProps['sub-font-size'], equals(60.0));
      expect(client.intProps['sub-margin-y'], equals(32));
      expect(client.boolProps['sub-ass-force-margins'], isTrue);
    });
  });

  group('EmbeddedMpvSession 无 UI 状态流转与安全护栏', () {
    late Directory tempRoot;

    setUp(() {
      tempRoot = Directory.systemTemp.createTempSync('konata_mpv_session_');
    });

    tearDown(() {
      if (tempRoot.existsSync()) {
        tempRoot.deleteSync(recursive: true);
      }
    });

    test('Hi10P 重配置立即切软解，gpu-next 失败回落 gpu 并推送 renderBackendChanges 流', () async {
      final storage = PortableStorageRootService(overrideRootPath: tempRoot.path);
      final bridge = FakeLocalStreamBridge();
      final client = FakeLibMpvClient()
        ..failStringAssignments.add('vo=gpu-next')
        ..stringProps['video-format'] = 'h264'
        ..stringProps['video-params/profile'] = 'High 10'
        ..stringProps['video-params/pixelformat'] = 'yuv420p10le';
      final notices = <String>[];
      final backends = <String>[];

      final session = EmbeddedMpvSession(
        storageRoot: storage,
        streamBridge: bridge,
        clientFactory: () => client,
        isWindowsOverride: false,
        isAndroidOverride: true,
      )..onNotice = notices.add;
      final backendSub = session.renderBackendChanges.listen(backends.add);
      addTearDown(() async {
        await backendSub.cancel();
        await session.dispose();
      });

      final surface = FakeAndroidVideoSurfacePort(
        const AndroidSurfaceDescriptor(
          wid: 88,
          width: 1920,
          height: 1080,
          hdrPeak: 1000,
        ),
      );
      addTearDown(surface.dispose);

      const variant = MediaVariantRecord(
        id: VariantId.trusted('v_hi10'),
        workId: WorkId.trusted('w_hi10'),
        sourceId: SourceId.trusted('s_hi10'),
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
        androidSurfaceSupplier: () async => surface,
      );

      await Future<void>.delayed(Duration.zero);
      expect(client.stringProps['vo'], equals('gpu'));
      expect(session.renderBackend, equals('gpu'));
      expect(backends, contains('gpu'));

      client.emitEvent(const MpvFileLoadedEvent());
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(client.stringProps['hwdec'], equals('no'));
      expect(client.stringProps['vd-lavc-threads'], equals('0'));
      expect(session.isUsingSoftwareFallback, isTrue);
      expect(notices.any((m) => m.contains('Hi10P')), isTrue);
      expect(
        client.commands.any(
          (cmd) => cmd.length == 1 && cmd.first == 'video-reload',
        ),
        isTrue,
      );
    });

    test('双模原画截图支持桌面直存与 MediaStore 接口发布并清理临时文件', () async {
      final storage = PortableStorageRootService(overrideRootPath: tempRoot.path);
      final bridge = FakeLocalStreamBridge();
      final client = FakeLibMpvClient();
      final session = EmbeddedMpvSession(
        storageRoot: storage,
        streamBridge: bridge,
        clientFactory: () => client,
        isWindowsOverride: true,
        isAndroidOverride: false,
      );
      addTearDown(session.dispose);

      const variant = MediaVariantRecord(
        id: VariantId.trusted('v_cap'),
        workId: WorkId.trusted('w_cap'),
        sourceId: SourceId.trusted('s_cap'),
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

      final photoDir = Directory(p.join(tempRoot.path, 'photos', 'Work [1]'));
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
      expect(
        subRes!.galleryUri,
        equals('content://media/external/images/media/9527'),
      );
      expect(subRes.file, isNull);
      expect(publishedTempFile, isNotNull);
      expect(publishedTempFile!.existsSync(), isFalse);
      expect(client.commands.last[2], equals('subtitles'));
    });

    test('OSD 静默期退订 time-pos 后零回调唤醒，恢复订阅即时同步最新秒数', () async {
      final storage = PortableStorageRootService(overrideRootPath: tempRoot.path);
      final bridge = FakeLocalStreamBridge();
      final client = FakeLibMpvClient();
      final session = EmbeddedMpvSession(
        storageRoot: storage,
        streamBridge: bridge,
        clientFactory: () => client,
        isWindowsOverride: true,
        isAndroidOverride: false,
      );
      addTearDown(session.dispose);

      final receivedPositions = <double>[];
      session.onPositionChanged = receivedPositions.add;

      const variant = MediaVariantRecord(
        id: VariantId.trusted('v_osd'),
        workId: WorkId.trusted('w_osd'),
        sourceId: SourceId.trusted('s_osd'),
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

      session.setPositionObservationEnabled(false);
      expect(client.unobservedIds, contains(201));

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

      client.doubleProps['time-pos'] = 58.25;
      session.setPositionObservationEnabled(true);
      expect(receivedPositions, equals([58.25]));
    });
  });
}
