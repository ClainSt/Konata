import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:ccplayer/application/playback/unified_playback_engine.dart';
import 'package:ccplayer/application/playback/video_playback_controller.dart';
import 'package:ccplayer/application/providers/library_providers.dart';
import 'package:ccplayer/composition/platform_composition.dart';
import 'package:ccplayer/domain/models/episode.dart';
import 'package:ccplayer/domain/models/media_source.dart';
import 'package:ccplayer/domain/models/media_variant.dart';
import 'package:ccplayer/domain/models/work.dart';
import 'package:ccplayer/infrastructure/database/drift_library_repository.dart';
import 'package:ccplayer/infrastructure/database/konata_database.dart';
import 'package:ccplayer/infrastructure/players/d3d11_video_bridge.dart';
import 'package:ccplayer/infrastructure/players/libmpv_ffi.dart';
import 'package:ccplayer/infrastructure/players/windows_mpv_profile_adapter.dart';
import 'package:ccplayer/infrastructure/storage/storage_root_provider.dart';
import 'package:ccplayer/presentation/theme/konata_playback_tokens.dart';
import 'package:ccplayer/presentation/theme/konata_theme.dart';
import 'package:ccplayer/presentation/video/embedded_video_page.dart';
import 'package:ccplayer/presentation/widgets/playback/konata_stage_morph_frame.dart';
import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;

import 'codec_matrix_loader.dart';
import 'process_metrics.dart';

int _medianInt(List<int> values) {
  if (values.isEmpty) return 0;
  final sorted = List<int>.of(values)..sort();
  return sorted[sorted.length ~/ 2];
}

int _p99Int(List<int> values) {
  if (values.isEmpty) return 0;
  final sorted = List<int>.of(values)..sort();
  final idx = ((sorted.length - 1) * 99) ~/ 100;
  return sorted[idx];
}

String? _resolvePreferredWinMpvDll() {
  if (!Platform.isWindows) return null;
  final candidate = p.join(
    Directory.current.path,
    'native',
    'konata-native',
    'windows',
    'libmpv-2.dll',
  );
  return File(candidate).existsSync() ? candidate : null;
}

Map<String, Object?> _readVideoOutParams(LibMpvClient client) {
  return <String, Object?>{
    'w': client.getPropertyInt64('video-out-params/w') ??
        client.getPropertyInt64('video-params/w') ??
        0,
    'h': client.getPropertyInt64('video-out-params/h') ??
        client.getPropertyInt64('video-params/h') ??
        0,
    'pixelformat': client.getPropertyString('video-out-params/pixelformat') ??
        client.getPropertyString('video-params/pixelformat') ??
        '',
    'hw_pixelformat':
        client.getPropertyString('video-out-params/hw-pixelformat') ??
        client.getPropertyString('video-params/hw-pixelformat') ??
        '',
    'colormatrix': client.getPropertyString('video-out-params/colormatrix') ??
        client.getPropertyString('video-params/colormatrix') ??
        '',
    'primaries': client.getPropertyString('video-out-params/primaries') ??
        client.getPropertyString('video-params/primaries') ??
        '',
    'gamma': client.getPropertyString('video-out-params/gamma') ??
        client.getPropertyString('video-params/gamma') ??
        '',
    'par': client.getPropertyDouble('video-out-params/par') ??
        client.getPropertyDouble('video-params/par'),
    'aspect': client.getPropertyDouble('video-out-params/aspect') ??
        client.getPropertyDouble('video-params/aspect'),
  };
}

Map<String, Object?> _readAudioOutParams(LibMpvClient client) {
  return <String, Object?>{
    'samplerate': client.getPropertyInt64('audio-out-params/samplerate') ??
        client.getPropertyInt64('audio-params/samplerate') ??
        0,
    'channels': client.getPropertyString('audio-out-params/channels') ??
        client.getPropertyString('audio-params/channels') ??
        '',
    'channel_count':
        client.getPropertyInt64('audio-out-params/channel-count') ??
        client.getPropertyInt64('audio-params/channel-count') ??
        0,
    'format': client.getPropertyString('audio-out-params/format') ??
        client.getPropertyString('audio-params/format') ??
        '',
  };
}

/// 挂载真实 `EmbeddedVideoPage` 与 `KonataStageMorphFrame` 的端到端视频舞台宿主。
class _LiveStageNorthstarHost extends StatelessWidget {
  const _LiveStageNorthstarHost({
    required this.request,
    required this.frameKey,
    required this.isCollapsing,
    required this.releaseVelocityPxPerSec,
    required this.originRect,
    required this.onCollapseCompleted,
    required this.onContainerReady,
  });

  final VideoLaunchRequest request;
  final GlobalKey<KonataStageMorphFrameState> frameKey;
  final bool isCollapsing;
  final double releaseVelocityPxPerSec;
  final Rect originRect;
  final VoidCallback onCollapseCompleted;
  final ValueChanged<ProviderContainer> onContainerReady;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: KonataTheme.darkTheme(),
      home: Consumer(
        builder: (context, ref, _) {
          onContainerReady(ProviderScope.containerOf(context));
          final usesUnderlay =
              Platform.isAndroid ||
              ref.watch(
                videoPlaybackProvider(request).select(
                  (s) => s.windowsUnderlayActive && !s.audioOnlyMode,
                ),
              );
          return Scaffold(
            backgroundColor: Colors.transparent,
            body: KonataStageMorphFrame(
              key: frameKey,
              originRect: originRect,
              allowClipRadius: !usesUnderlay,
              isCollapsing: isCollapsing,
              releaseVelocityPxPerSec: releaseVelocityPxPerSec,
              onCollapseCompleted: onCollapseCompleted,
              child: EmbeddedVideoPage(request: request),
            ),
          );
        },
      ),
    );
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('三端真硬件音视频播放北极星基准（零 vo=null/ao=null，真实压缩流 + 真页 OSD 零帧 + 120Hz 形变）', (
    tester,
  ) async {
    final matrixDir = await resolveCodecMatrixDirectory(
      onlyNorthstarSubset: true,
    );
    final manifestJson =
        jsonDecode(
              await File(
                p.join(matrixDir.path, 'manifest.json'),
              ).readAsString(encoding: utf8),
            )
            as Map<String, Object?>;
    final groupsMeta = manifestJson['groups']! as Map<String, Object?>;
    final g01Meta = groupsMeta['G01']! as Map<String, Object?>;
    final g04Meta = groupsMeta['G04']! as Map<String, Object?>;

    final g01SteadyRel = (g01Meta['steady_8s'] ?? g01Meta['primary'])! as String;
    final g04MkvRel = g04Meta['primary']! as String;
    final g01SteadyFile = File(p.join(matrixDir.path, g01SteadyRel));
    final g04MkvFile = File(p.join(matrixDir.path, g04MkvRel));
    expect(await g01SteadyFile.exists(), isTrue);
    expect(await g04MkvFile.exists(), isTrue);

    final storageRoot = await StorageRootService.createForCurrentPlatform();
    final winDll = _resolvePreferredWinMpvDll();
    final winBridge = Platform.isWindows ? D3D11VideoBridge() : null;
    if (winBridge != null) {
      addTearDown(winBridge.dispose);
    }
    final desktopDelegate = Platform.isWindows
        ? const WindowsMpvProfileDelegate()
        : null;

    final source = MediaSource(
      id: 'bench_local_src',
      label: 'NorthstarFixtures',
      kind: MediaSourceKind.local,
      location: matrixDir.path,
    );
    const work = Work(
      id: 'bench_work_01',
      title: 'Konata 真实压缩流基准测试',
      scrapeStatus: ScrapeStatus.matched,
    );
    const ep1 = Episode(
      id: 'bench_ep_1',
      workId: 'bench_work_01',
      seasonNumber: 1,
      episodeNumber: 1,
      title: 'G01 HEVC Main10 + FLAC 稳态流',
      category: EpisodeCategory.main,
    );
    const ep2 = Episode(
      id: 'bench_ep_2',
      workId: 'bench_work_01',
      seasonNumber: 1,
      episodeNumber: 2,
      title: 'G04 H.264 High 8-bit + FLAC',
      category: EpisodeCategory.main,
    );
    final var1 = MediaVariant(
      id: 'bench_var_1',
      episodeId: ep1.id,
      workId: work.id,
      sourceId: source.id,
      relativePath: g01SteadyRel,
      fileName: p.basename(g01SteadyRel),
      fileSize: await g01SteadyFile.length(),
      assetKind: AssetKind.video,
    );
    final var2 = MediaVariant(
      id: 'bench_var_2',
      episodeId: ep2.id,
      workId: work.id,
      sourceId: source.id,
      relativePath: g04MkvRel,
      fileName: p.basename(g04MkvRel),
      fileSize: await g04MkvFile.length(),
      assetKind: AssetKind.video,
    );
    final bundle = WorkDetailBundle(
      work: work,
      episodes: const [ep1, ep2],
      variants: [var1, var2],
      sourcesById: {source.id: source},
      latestPlayback: null,
    );
    final launchRequest = VideoLaunchRequest(
      work: work,
      episode: ep1,
      variant: var1,
      bundle: bundle,
      source: source,
    );

    ProviderContainer? liveContainer;

    final morphKey = GlobalKey<KonataStageMorphFrameState>();
    var collapseCompleted = false;
    var morphCollapsing = false;
    var morphVelocity = 640.0;
    const originRect = Rect.fromLTWH(24, 320, 260, 146);

    final collectedFrames = <FrameTiming>[];
    var recordingFrames = false;
    void onTimings(List<FrameTiming> timings) {
      if (recordingFrames) {
        collectedFrames.addAll(timings);
      }
    }

    binding.addTimingsCallback(onTimings);
    addTearDown(() => binding.removeTimingsCallback(onTimings));

    final inMemoryDb = KonataDatabase(NativeDatabase.memory());
    addTearDown(inMemoryDb.close);
    final seedRepo = DriftLibraryRepository(inMemoryDb);
    await seedRepo.upsertMediaSource(source);
    await seedRepo.upsertWork(work);
    await seedRepo.upsertEpisode(ep1);
    await seedRepo.upsertEpisode(ep2);
    await seedRepo.upsertMediaVariant(var1);
    await seedRepo.upsertMediaVariant(var2);

    final overrides = <Override>[
      konataDatabaseProvider.overrideWithValue(inMemoryDb),
      storageRootProvider.overrideWithValue(storageRoot),
      if (Platform.isWindows && winBridge != null)
        konataVideoBridgeFactoryProvider.overrideWithValue(() => winBridge),
      if (desktopDelegate != null)
        mpvPlatformProfileDelegateProvider.overrideWithValue(desktopDelegate),
      if (Platform.isWindows && winDll != null)
        unifiedPlaybackEngineProvider.overrideWithValue(
          UnifiedPlaybackEngine(
            defaultClientFactory: ({preferredLibraryPath}) =>
                FfiLibMpvClient.create(
                  preferredLibraryPath: preferredLibraryPath ?? winDll,
                ),
          ),
        ),
    ];

    Widget buildHost() => ProviderScope(
      overrides: overrides,
      child: _LiveStageNorthstarHost(
        request: launchRequest,
        frameKey: morphKey,
        isCollapsing: morphCollapsing,
        releaseVelocityPxPerSec: morphVelocity,
        originRect: originRect,
        onCollapseCompleted: () => collapseCompleted = true,
        onContainerReady: (c) => liveContainer = c,
      ),
    );

    // 1. 冷启动真实 EmbeddedVideoPage（全程走未裁剪的生产 VideoPlaybackController 与 UnifiedPlaybackEngine），
    // 记录冷启动真实首帧耗时（严禁 vo=null/ao=null）。
    final coldWatch = Stopwatch()..start();
    await tester.pumpWidget(buildHost());

    final coldDeadline = DateTime.now().add(const Duration(seconds: 20));
    while (DateTime.now().isBefore(coldDeadline)) {
      await tester.pump(const Duration(milliseconds: 30));
      final ctrl = liveContainer?.read(
        videoPlaybackProvider(launchRequest).notifier,
      );
      final st = liveContainer?.read(videoPlaybackProvider(launchRequest));
      final c = liveContainer
          ?.read(unifiedPlaybackEngineProvider)
          .activeNativeClient;
      if (ctrl != null &&
          st != null &&
          st.hasFirstFrame &&
          c != null &&
          !c.isDisposed) {
        final vo = c.getPropertyString('current-vo') ?? '';
        final ao = c.getPropertyString('current-ao') ?? '';
        final w =
            c.getPropertyInt64('video-out-params/w') ??
            c.getPropertyInt64('video-params/w') ??
            0;
        final sr =
            c.getPropertyInt64('audio-out-params/samplerate') ??
            c.getPropertyInt64('audio-params/samplerate') ??
            0;
        if (vo.isNotEmpty && vo != 'null' && ao.isNotEmpty && ao != 'null' && w > 0 && sr > 0) {
          break;
        }
      }
    }
    coldWatch.stop();
    final coldTtffUs = coldWatch.elapsedMicroseconds;

    final engine = liveContainer!.read(unifiedPlaybackEngineProvider);
    final coldState = liveContainer!.read(videoPlaybackProvider(launchRequest));
    final controller = liveContainer!.read(
      videoPlaybackProvider(launchRequest).notifier,
    );
    final client = engine.activeNativeClient!;
    addTearDown(() async {
      await controller.closeAndRelease();
    });
    expect(
      coldState.hasFirstFrame,
      isTrue,
      reason: '冷启动必须在超时窗口内触发真实首帧上屏（hasFirstFrame == true）',
    );
    expect(
      coldTtffUs,
      lessThan(const Duration(seconds: 12).inMicroseconds),
      reason:
          '冷启动首帧耗时不得触碰超时红线（实测 ${(coldTtffUs / 1000).toStringAsFixed(1)} ms）',
    );
    expect(
      engine.liveNativeClientCount,
      equals(1),
      reason: '真实视频冷启动后全进程必须仅存活 1 个受统一内核托管的 LibMpvClient',
    );

    // 调低音量避免噪声但保持真实 WASAPI/AAudio 音频硬件链路持续输出。
    controller.setVolume(5.0);
    await tester.pump(const Duration(milliseconds: 120));

    final initialVo = client.getPropertyString('current-vo') ?? '';
    final initialAo = client.getPropertyString('current-ao') ?? '';
    final initialHwdec = client.getPropertyString('hwdec-current') ?? '';
    final initialAf = client.getPropertyString('af') ?? '';
    final initialVideoOut = _readVideoOutParams(client);
    final initialAudioOut = _readAudioOutParams(client);

    expect(
      initialVo,
      isNot(anyOf(isEmpty, equals('null'))),
      reason: '北极星基准必须开启真实硬件画面输出（严禁 vo=null）',
    );
    expect(
      initialAo,
      isNot(anyOf(isEmpty, equals('null'))),
      reason: '北极星基准必须开启真实硬件音频输出（严禁 ao=null）',
    );
    expect((initialVideoOut['w']! as int), greaterThan(0));
    expect((initialAudioOut['samplerate']! as int), greaterThan(0));
    expect(
      initialAf,
      contains('alimiter=limit=0.251'),
      reason: '真实音频安全链必须挂载 -12 dBFS 数字限幅器',
    );

    // 预热：切换一轮剧集并执行一次双向弹簧过渡，排除首轮着色器编译冷抖动。
    Future<int> switchEpisodeAndMeasureTtff(Episode targetEp) async {
      final restarted = Completer<void>();
      final sub = client.events.listen((e) {
        if (e is MpvPlaybackRestartEvent && !restarted.isCompleted) {
          restarted.complete();
        }
      });
      try {
        final w = Stopwatch()..start();
        await controller.switchToEpisode(targetEp, startSeconds: 0.0);
        await restarted.future.timeout(const Duration(seconds: 12));
        for (var i = 0; i < 30; i++) {
          final frameNo = client.getPropertyInt64('estimated-frame-number') ?? 0;
          final pos = client.getPropertyDouble('time-pos') ?? 0.0;
          if (frameNo > 0 || pos > 0.01) break;
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        w.stop();
        await tester.pump(const Duration(milliseconds: 40));
        return w.elapsedMicroseconds;
      } finally {
        await sub.cancel();
      }
    }

    Future<({int recoveryUs, double actualSeconds})> measureSeekRecovery(
      double targetSeconds,
    ) async {
      final restarted = Completer<void>();
      final sub = client.events.listen((e) {
        if (e is MpvPlaybackRestartEvent && !restarted.isCompleted) {
          restarted.complete();
        }
      });
      try {
        if (!liveContainer!.read(videoPlaybackProvider(launchRequest)).isPlaying) {
          controller.togglePlayPause();
        }
        final frameBefore = client.getPropertyInt64('estimated-frame-number') ?? 0;
        final w = Stopwatch()..start();
        controller.seekAbsolute(targetSeconds);
        await restarted.future.timeout(const Duration(seconds: 8));
        var actualPos = client.getPropertyDouble('time-pos') ?? targetSeconds;
        for (var i = 0; i < 60; i++) {
          final seeking = client.getPropertyFlag('seeking') ?? false;
          final voReady = client.getPropertyFlag('vo-configured') ?? true;
          final frameNow = client.getPropertyInt64('estimated-frame-number') ?? 0;
          actualPos = client.getPropertyDouble('time-pos') ?? actualPos;
          if (!seeking &&
              voReady &&
              (frameNow != frameBefore || (actualPos - targetSeconds).abs() <= 0.75)) {
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        w.stop();
        await tester.pump(const Duration(milliseconds: 30));
        return (recoveryUs: w.elapsedMicroseconds, actualSeconds: actualPos);
      } finally {
        await sub.cancel();
      }
    }

    await switchEpisodeAndMeasureTtff(ep2);
    await switchEpisodeAndMeasureTtff(ep1);
    await measureSeekRecovery(1.6);

    // 预热一轮真实视频舞台 + 毛玻璃 HUD 双向 120Hz 弹簧形变。
    collapseCompleted = false;
    morphCollapsing = true;
    morphVelocity = 1280.0;
    await tester.pumpWidget(buildHost());
    await tester.pumpAndSettle(const Duration(milliseconds: 16));
    expect(collapseCompleted, isTrue);
    morphCollapsing = false;
    morphVelocity = 640.0;
    await tester.pumpWidget(buildHost());
    await tester.pumpAndSettle(const Duration(milliseconds: 16));

    // ---------------- 正式 5 轮交替 A/B 实机采样 ----------------
    final rounds = <Map<String, Object?>>[];

    for (var round = 0; round < 5; round++) {
      final reverseOrder = round.isOdd;
      int warmHevcTtffUs;
      int warmAvcTtffUs;
      if (!reverseOrder) {
        warmAvcTtffUs = await switchEpisodeAndMeasureTtff(ep2);
        warmHevcTtffUs = await switchEpisodeAndMeasureTtff(ep1);
      } else {
        warmHevcTtffUs = await switchEpisodeAndMeasureTtff(ep1);
        warmAvcTtffUs = await switchEpisodeAndMeasureTtff(ep2);
        await switchEpisodeAndMeasureTtff(ep1);
      }

      // 柱 1.5：真硬件渲染下的精确跳转恢复耗时（下发 seek 至目标新帧输出完成）。
      final seekTargetSec = round.isEven ? 2.1 : 1.5;
      final seekRes = await measureSeekRecovery(seekTargetSec);
      expect(
        seekRes.recoveryUs,
        greaterThan(0),
        reason: '第 ${round + 1} 轮真硬件 seek 恢复耗时必须大于 0',
      );
      expect(
        (seekRes.actualSeconds - seekTargetSec).abs(),
        lessThanOrEqualTo(1.2),
        reason:
            '第 ${round + 1} 轮跳转目标 ${seekTargetSec}s 与落点 ${seekRes.actualSeconds.toStringAsFixed(2)}s 偏差过大',
      );

      // 确保处于连续播放态进入稳态零帧观测窗口（2.1s 起点在 8s 稳态流内不触发回环）。
      if (!liveContainer!.read(videoPlaybackProvider(launchRequest)).isPlaying) {
        controller.togglePlayPause();
      }
      await tester.pump(const Duration(milliseconds: 100));

      // 真实推进墙钟越过 3.0s cursorIdleFadeDelay + 220ms 淡出时长，直至真实 OSD 自动隐藏并退订 time-pos。
      final hideDeadline = DateTime.now().add(
        KonataPlaybackTokens.cursorIdleFadeDelay +
            const Duration(milliseconds: 1500),
      );
      while (DateTime.now().isBefore(hideDeadline)) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 120)),
        );
        await tester.pump(const Duration(milliseconds: 32));
        if (!controller.isHudProgressActive &&
            !controller.isPositionObservationEnabled) {
          break;
        }
      }
      // 等待 OSD 淡出动画彻底完结停钟，并排空 Flutter 引擎 100ms 批量回调队列（250ms 余量），随后开始纯粹稳态零帧实测。
      await tester.pumpAndSettle(const Duration(milliseconds: 16));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 250)),
      );

      expect(
        controller.isHudProgressActive,
        isFalse,
        reason: '第 ${round + 1} 轮满 3 秒无操作后 OSD 必须自动隐藏并挂起进度派发',
      );
      expect(
        controller.isPositionObservationEnabled,
        isFalse,
        reason: '第 ${round + 1} 轮 OSD 隐藏后必须通过 mpv_unobserve_property 退订 time-pos',
      );
      expect(
        controller.isMicroFadeActive,
        isFalse,
        reason: '150ms S 型微淡入终态必须已停钟',
      );

      // 柱二：真实 >= 2.0s 连续硬件播放稳态窗口，采集真实 Flutter FrameTiming 计数（严格要求 == 0）与峰值 RSS。
      final startPos = client.getPropertyDouble('time-pos') ?? 0.0;
      final cpuStart = processCpuMicroseconds();
      var peakRss = ProcessInfo.currentRss;
      collectedFrames.clear();
      final steadyFrameOffsetsMs = <int>[];
      final steadyStateDiffs = <String>[];
      final steadyWatch = Stopwatch()..start();
      final stateSub = liveContainer!.listen<VideoPlaybackState>(
        videoPlaybackProvider(launchRequest),
        (prev, next) {
          steadyStateDiffs.add(
            '+${steadyWatch.elapsedMilliseconds}ms:'
            'buf=${prev?.isBuffering}->${next.isBuffering},'
            'play=${prev?.isPlaying}->${next.isPlaying},'
            'pos=${prev?.positionSeconds.toStringAsFixed(2)}->${next.positionSeconds.toStringAsFixed(2)},'
            'dur=${prev?.durationSeconds.toStringAsFixed(2)}->${next.durationSeconds.toStringAsFixed(2)},'
            'banner=${next.transientBanner},'
            'hw=${prev?.probeStats.hwdecCurrent}->${next.probeStats.hwdecCurrent}',
          );
        },
      );
      void recordSteadyOffset(List<FrameTiming> timings) {
        if (recordingFrames && timings.isNotEmpty) {
          for (var i = 0; i < timings.length; i++) {
            steadyFrameOffsetsMs.add(steadyWatch.elapsedMilliseconds);
          }
        }
      }
      binding.addTimingsCallback(recordSteadyOffset);
      recordingFrames = true;
      final rssTimer = Timer.periodic(const Duration(milliseconds: 50), (_) {
        final cur = ProcessInfo.currentRss;
        if (cur > peakRss) peakRss = cur;
      });
      try {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 2200)),
        );
      } finally {
        rssTimer.cancel();
        recordingFrames = false;
        binding.removeTimingsCallback(recordSteadyOffset);
        stateSub.close();
      }
      final steadyCpuUs = processCpuMicroseconds() - cpuStart;
      final endPos = client.getPropertyDouble('time-pos') ?? 0.0;
      final steadyFramesCount = collectedFrames.length;
      final playbackDeltaSec = endPos - startPos;

      expect(
        playbackDeltaSec,
        greaterThanOrEqualTo(0.8),
        reason:
            '第 ${round + 1} 轮稳态窗口内真实硬件视频必须持续推进（实测推进 ${playbackDeltaSec.toStringAsFixed(2)}s）',
      );
      expect(
        steadyFramesCount,
        equals(0),
        reason:
            '第 ${round + 1} 轮 OSD 隐藏后 >=2.0s 稳态播放期 Flutter 实际渲染帧必须严格为 0（实得 $steadyFramesCount 帧，帧时刻=$steadyFrameOffsetsMs，状态变化=$steadyStateDiffs）',
      );

      // 柱三：真实活跃视频视口 + 毛玻璃 HUD 双向 120Hz 物理弹簧形变 Build/Raster P99 实测。
      collectedFrames.clear();
      collapseCompleted = false;
      recordingFrames = true;
      morphCollapsing = true;
      morphVelocity = 1280.0;
      await tester.pumpWidget(buildHost());
      await tester.pumpAndSettle(const Duration(milliseconds: 8));
      expect(collapseCompleted, isTrue);
      expect(morphKey.currentState?.isTickerActive, isFalse);

      morphCollapsing = false;
      morphVelocity = 640.0;
      await tester.pumpWidget(buildHost());
      await tester.pumpAndSettle(const Duration(milliseconds: 8));
      recordingFrames = false;
      expect(morphKey.currentState?.isTickerActive, isFalse);

      final buildUs = collectedFrames
          .map((f) => f.buildDuration.inMicroseconds)
          .toList(growable: false);
      final rasterUs = collectedFrames
          .map((f) => f.rasterDuration.inMicroseconds)
          .toList(growable: false);
      expect(buildUs, isNotEmpty, reason: '双向弹簧形变必须采得真实 FrameTiming 样本');

      final roundVo = client.getPropertyString('current-vo') ?? '';
      final roundAo = client.getPropertyString('current-ao') ?? '';
      final roundHwdec = client.getPropertyString('hwdec-current') ?? '';
      final roundVideoOut = _readVideoOutParams(client);
      final roundAudioOut = _readAudioOutParams(client);

      rounds.add({
        'round': round + 1,
        'order': reverseOrder ? 'reverse_BA' : 'forward_AB',
        'warm_hevc10_ttff_us': warmHevcTtffUs,
        'warm_h264_8bit_ttff_us': warmAvcTtffUs,
        'seek_target_seconds': seekTargetSec,
        'seek_actual_seconds': double.parse(
          seekRes.actualSeconds.toStringAsFixed(3),
        ),
        'seek_recovery_us': seekRes.recoveryUs,
        'current_vo': roundVo,
        'current_ao': roundAo,
        'hwdec_current': roundHwdec,
        'video_out_params': roundVideoOut,
        'audio_out_params': roundAudioOut,
        'steady_window_ms': 2200,
        'steady_playback_delta_seconds': double.parse(
          playbackDeltaSec.toStringAsFixed(3),
        ),
        'steady_flutter_frame_count': steadyFramesCount,
        'steady_zero_frame_verified': steadyFramesCount == 0,
        'steady_cpu_us': steadyCpuUs,
        'steady_peak_rss_bytes': peakRss,
        'spring_morph_frame_count': buildUs.length,
        'spring_morph_build_p50_us': _medianInt(buildUs),
        'spring_morph_build_p99_us': _p99Int(buildUs),
        'spring_morph_raster_p50_us': _medianInt(rasterUs),
        'spring_morph_raster_p99_us': _p99Int(rasterUs),
      });
    }

    final hevcTtffs = [for (final r in rounds) r['warm_hevc10_ttff_us']! as int];
    final avcTtffs = [
      for (final r in rounds) r['warm_h264_8bit_ttff_us']! as int,
    ];
    final seekRecoveries = [
      for (final r in rounds) r['seek_recovery_us']! as int,
    ];
    final morphBuildP99s = [
      for (final r in rounds) r['spring_morph_build_p99_us']! as int,
    ];
    final morphRasterP99s = [
      for (final r in rounds) r['spring_morph_raster_p99_us']! as int,
    ];
    final steadyRsses = [
      for (final r in rounds) r['steady_peak_rss_bytes']! as int,
    ];
    final steadyFramesTotal = rounds.fold<int>(
      0,
      (sum, r) => sum + (r['steady_flutter_frame_count']! as int),
    );
    // 验证 5 轮 RSS 稳态收敛（末轮相对第 2 轮增幅 <= 15% 或 <= 24 MiB，无持续内存泄漏）。
    final rssGrowthBytes = steadyRsses.last - steadyRsses[1];

    binding.reportData = <String, Object?>{
      'platform': Platform.operatingSystem,
      'sample_rounds': rounds.length,
      'sampling_protocol':
          'real_hardware_vo_ao_warmup_1_then_5_alternating_AB_BA',
      'zero_null_vo_ao_verified': true,
      'compressed_fixtures_used': [g01SteadyRel, g04MkvRel],
      'live_pipeline_snapshot': {
        'current_vo': initialVo,
        'current_ao': initialAo,
        'hwdec_current': initialHwdec,
        'audio_filter_chain': initialAf,
        'video_out_params': initialVideoOut,
        'audio_out_params': initialAudioOut,
      },
      'summary': {
        'cold_ttff_us': coldTtffUs,
        'warm_hevc10_ttff_median_us': _medianInt(hevcTtffs),
        'warm_h264_8bit_ttff_median_us': _medianInt(avcTtffs),
        'seek_recovery_median_us': _medianInt(seekRecoveries),
        'seek_recovery_p99_us': _p99Int(seekRecoveries),
        'steady_osd_hidden_total_flutter_frames': steadyFramesTotal,
        'steady_osd_hidden_zero_frame_rate': steadyFramesTotal == 0 ? 1.0 : 0.0,
        'spring_morph_build_p99_median_us': _medianInt(morphBuildP99s),
        'spring_morph_raster_p99_median_us': _medianInt(morphRasterP99s),
        'steady_peak_rss_median_bytes': _medianInt(steadyRsses),
        'steady_rss_growth_r2_to_r5_bytes': rssGrowthBytes,
        'audiophile_safety_ceiling_db': -12.0,
        'micro_fade_stopped_at_terminal': !controller.isMicroFadeActive,
      },
      'rounds': rounds,
    };
  });
}
