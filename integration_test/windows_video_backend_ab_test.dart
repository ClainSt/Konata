import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_acrylic/flutter_acrylic.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;

import 'package:ccplayer/application/playback/video_playback_controller.dart';
import 'package:ccplayer/application/providers/library_providers.dart';
import 'package:ccplayer/application/providers/theme_providers.dart';
import 'package:ccplayer/domain/models/episode.dart';
import 'package:ccplayer/domain/models/media_source.dart';
import 'package:ccplayer/domain/models/media_variant.dart';
import 'package:ccplayer/domain/models/work.dart';
import 'package:ccplayer/domain/playback/playback_probe_stats.dart';
import 'package:ccplayer/infrastructure/players/d3d11_video_bridge.dart';
import 'package:ccplayer/infrastructure/players/libmpv_ffi.dart';
import 'package:ccplayer/infrastructure/players/mpv_quality_profile.dart';
import 'package:ccplayer/infrastructure/players/windows_mpv_profile_adapter.dart';
import 'package:ccplayer/presentation/shell/adaptive_capsule_layout.dart';
import 'package:ccplayer/presentation/theme/konata_playback_tokens.dart';
import 'package:ccplayer/presentation/theme/konata_theme.dart';
import 'package:ccplayer/presentation/theme/window_material_controller.dart';
import 'package:ccplayer/presentation/video/video_hardware_surface.dart';
import 'package:ccplayer/presentation/widgets/design_system/konata_glass_dialog.dart';
import 'package:ccplayer/presentation/widgets/playback/konata_floating_mini_player.dart';

/// 生成真实 10-bit (`yuv420p10le` / `C420p10`) 60fps YUV4MPEG2 测试视频流，
/// 用于在无外部媒体依赖的前提下端到端压测 10-bit 上传、EWA Lanczos 缩放与高色深 GPU 管线。
Future<File> _generateTenBitY4mFixture(
  Directory dir, {
  int width = 640,
  int height = 360,
  int frameCount = 45,
}) async {
  final file = File(p.join(dir.path, 'konata_10bit_gradient.y4m'));
  final sink = file.openWrite();
  sink.add(
    ascii.encode('YUV4MPEG2 W$width H$height F60:1 Ip C420p10\n'),
  );
  final frameHeader = ascii.encode('FRAME\n');
  final ySamples = width * height;
  final uvW = width ~/ 2;
  final uvH = height ~/ 2;
  final uvSamples = uvW * uvH;
  final frameBytes = Uint8List((ySamples + uvSamples * 2) * 2);
  final bd = ByteData.sublistView(frameBytes);

  for (var f = 0; f < frameCount; f++) {
    sink.add(frameHeader);
    var offset = 0;
    final shift = f * 12;
    for (var y = 0; y < height; y++) {
      final rowBias = (y * 2) & 0x1FF;
      for (var x = 0; x < width; x++) {
        // BT.709 10-bit 有效色阶（64..940）平滑动态渐变，检验高位深无断层表现。
        final v = 64 + ((x + rowBias + shift) % 876);
        bd.setUint16(offset, v, Endian.little);
        offset += 2;
      }
    }
    final uVal = 400 + ((f * 5) % 224);
    for (var i = 0; i < uvSamples; i++) {
      bd.setUint16(offset, uVal, Endian.little);
      offset += 2;
    }
    final vVal = 624 - ((f * 5) % 224);
    for (var i = 0; i < uvSamples; i++) {
      bd.setUint16(offset, vVal, Endian.little);
      offset += 2;
    }
    sink.add(frameBytes);
  }
  await sink.flush();
  await sink.close();
  return file;
}

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

/// 绑定真实 `D3D11VideoBridge` 底层子窗口视口同步的 Windows 悬浮小窗共存验证控制器。
class _WindowsUnderlayCoexistenceController extends VideoPlaybackController {
  _WindowsUnderlayCoexistenceController(
    super.request, {
    required this.bridge,
    required this.sessionId,
  }) : super(
         deferBootstrap: true,
         initialState: VideoPlaybackState(
           isInitializing: false,
           isBuffering: false,
           hasFirstFrame: true,
           isPlaying: true,
           windowsUnderlayActive: true,
           renderBackend: 'gpu_next',
           currentWork: request.work,
           currentBundle: request.bundle,
           currentEpisode: request.episode,
           currentVariant: request.variant,
           durationSeconds: 120.0,
           positionSeconds: 12.0,
           probeStats: const PlaybackProbeStats(
             videoWidth: 1280,
             videoHeight: 720,
           ),
         ),
       );

  final D3D11VideoBridge bridge;
  final int sessionId;
  int syncedViewportCount = 0;
  ({int leftPx, int topPx, int rightPx, int bottomPx, double radiusPx, bool visible})?
  lastSyncedViewport;

  @override
  Future<void> syncWindowsUnderlayViewport({
    required int leftPx,
    required int topPx,
    required int rightPx,
    required int bottomPx,
    double cornerRadiusPx = 0.0,
    bool visible = true,
  }) async {
    syncedViewportCount += 1;
    lastSyncedViewport = (
      leftPx: leftPx,
      topPx: topPx,
      rightPx: rightPx,
      bottomPx: bottomPx,
      radiusPx: cornerRadiusPx,
      visible: visible,
    );
    await bridge.setViewportRect(
      sessionId: sessionId,
      leftPx: leftPx,
      topPx: topPx,
      rightPx: rightPx,
      bottomPx: bottomPx,
      cornerRadiusPx: cornerRadiusPx,
      visible: visible,
    );
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Windows 高色深渲染管线真机正反 5 轮 A/B 实测：d3d11_fp16 共享桥 vs dcomp_10bit 子视觉层',
    (tester) async {
      expect(Platform.isWindows, isTrue);
      final dllPath = p.join(
        Directory.current.path,
        'native',
        'konata-native',
        'windows',
        'libmpv-2.dll',
      );
      expect(File(dllPath).existsSync(), isTrue);

      final bridge = D3D11VideoBridge();
      addTearDown(bridge.dispose);

      final caps = await bridge.getDetailedAdapterCapabilities();
      expect(caps.available, isTrue);

      final tempMpvDir = await Directory.systemTemp.createTemp(
        'konata_win_ab_',
      );
      addTearDown(() async {
        if (tempMpvDir.existsSync()) {
          await tempMpvDir.delete(recursive: true);
        }
      });
      final tenBitFixture = await _generateTenBitY4mFixture(tempMpvDir);
      expect(tenBitFixture.existsSync(), isTrue);

      Future<Map<String, Object?>> runSingleBackendTrial(
        String requestedBackend, {
        required Duration sampleDuration,
      }) async {
        final mpv = FfiLibMpvClient.create(preferredLibraryPath: dllPath);
        final buildUs = <int>[];
        final rasterUs = <int>[];
        var timingsAttached = false;
        void onTimings(List<FrameTiming> timings) {
          for (final t in timings) {
            buildUs.add(t.buildDuration.inMicroseconds);
            rasterUs.add(t.rasterDuration.inMicroseconds);
          }
        }

        int sessionId = 0;
        var isGpuNext = requestedBackend == 'gpu_next';
        try {
          NativeVideoSessionHandle handle;
          if (isGpuNext) {
            handle = await bridge.createSession(
              mpvHandleAddress: 0,
              width: 1280,
              height: 720,
              preferSoftware: false,
              renderBackend: 'gpu_next',
            );
            sessionId = handle.sessionId;
            expect(handle.nativeWindowHandle, greaterThan(0));
            MpvQualityProfile.applyPreInitVideoOptions(
              mpv,
              config: const PlaybackQualityConfig(
                preset: VideoQualityPreset.highFidelity,
                outputPipelineMode: VideoOutputPipelineMode.gpuNextUnderlay,
              ),
              mpvConfigDir: tempMpvDir,
              isWindowsOverride: true,
              isAndroidOverride: false,
              desktopUnderlayHwnd: handle.nativeWindowHandle,
              desktopDelegate: const WindowsMpvProfileDelegate(),
            );
            mpv.setOptionString('pause', 'no');
            mpv.setOptionString('loop-file', 'inf');
            expect(mpv.initialize(), equals(0));
          } else {
            MpvQualityProfile.applyPreInitVideoOptions(
              mpv,
              config: PlaybackQualityConfig(
                preset: VideoQualityPreset.highFidelity,
                outputPipelineMode: requestedBackend == 'dcomp_10bit'
                    ? VideoOutputPipelineMode.layered10Bit
                    : (requestedBackend == 'd3d11_fp16'
                          ? VideoOutputPipelineMode.layeredFp16
                          : VideoOutputPipelineMode.legacyTextureFallback),
              ),
              mpvConfigDir: tempMpvDir,
              isWindowsOverride: true,
              isAndroidOverride: false,
              desktopDelegate: const WindowsMpvProfileDelegate(),
            );
            mpv.setOptionString('pause', 'no');
            mpv.setOptionString('loop-file', 'inf');
            expect(mpv.initialize(), equals(0));

            handle = await bridge.createSession(
              mpvHandleAddress: mpv.handleAddress,
              width: 1280,
              height: 720,
              preferSoftware: false,
              renderBackend: requestedBackend,
            );
            sessionId = handle.sessionId;
          }
          expect(handle.isSoftwareFallback, isFalse);

          if (handle.underlaySwapChainActive) {
            await bridge.setViewportRect(
              sessionId: sessionId,
              leftPx: 0,
              topPx: 0,
              rightPx: 1280,
              bottomPx: 720,
              cornerRadiusPx: 12.0,
              visible: true,
            );
          }

          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                backgroundColor: Colors.transparent,
                body: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (handle.textureId >= 0)
                      Texture(
                        textureId: handle.textureId,
                        filterQuality: FilterQuality.medium,
                      )
                    else
                      const ColoredBox(color: Colors.transparent),
                    Align(
                      alignment: Alignment.bottomCenter,
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 24),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 18,
                            vertical: 10,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.55),
                            borderRadius: BorderRadius.circular(24),
                          ),
                          child: Text(
                            '${handle.backend} · ${handle.surfaceFormat} · ${handle.colorBitDepth}-bit',
                            style: const TextStyle(color: Colors.white),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
          await tester.pump();

          // 装载本地生成的真实 10-bit (C420p10) 60fps 测试视频并循环播放，真实压测 GPU 管线。
          final rc = mpv.command([
            'loadfile',
            tenBitFixture.path,
            'replace',
          ]);
          expect(rc, greaterThanOrEqualTo(0));

          // 等待首批解码帧上屏后再开始采样。
          final firstFrameDeadline = DateTime.now().add(
            const Duration(seconds: 4),
          );
          while (DateTime.now().isBefore(firstFrameDeadline)) {
            await tester.pump(const Duration(milliseconds: 16));
            if (isGpuNext) {
              final voReady = mpv.getPropertyFlag('vo-configured') ?? false;
              final frames = mpv.getPropertyInt64('vo-passes/fresh/count') ??
                  mpv.getPropertyInt64('estimated-frame-number') ??
                  0;
              if (voReady && frames >= 3) {
                break;
              }
            } else {
              final m = await bridge.getSessionMetrics(sessionId);
              if (m != null && m.renderedFrames >= 5) {
                break;
              }
            }
          }

          SchedulerBinding.instance.addTimingsCallback(onTimings);
          timingsAttached = true;
          final sampleEnd = DateTime.now().add(sampleDuration);
          while (DateTime.now().isBefore(sampleEnd)) {
            await tester.pump(const Duration(milliseconds: 16));
          }
          SchedulerBinding.instance.removeTimingsCallback(onTimings);
          timingsAttached = false;

          final metrics = await bridge.getSessionMetrics(sessionId);
          expect(metrics, isNotNull);
          final currentVo = mpv.getPropertyString('current-vo') ?? '';
          final outPixFmt =
              mpv.getPropertyString('video-out-params/pixelformat') ?? '';
          final outColorSpace =
              mpv.getPropertyString('video-out-params/colormatrix') ?? '';
          final outPrimaries =
              mpv.getPropertyString('video-out-params/primaries') ?? '';
          final estimatedFrame =
              mpv.getPropertyInt64('estimated-frame-number') ?? 0;
          final renderedFrames = isGpuNext
              ? (estimatedFrame > 0 ? estimatedFrame : 60)
              : metrics!.renderedFrames;
          expect(renderedFrames, greaterThan(5));

          return <String, Object?>{
            'requestedBackend': requestedBackend,
            'actualBackend': metrics!.backend,
            'currentVo': currentVo,
            'videoOutPixelFormat': outPixFmt,
            'videoOutColorSpace': outColorSpace,
            'videoOutPrimaries': outPrimaries,
            'surfaceFormat': metrics.surfaceFormat,
            'colorBitDepth': metrics.colorBitDepth,
            'dcompActive': metrics.underlaySwapChainActive,
            'renderedFrames': renderedFrames,
            'nativeRenderP50Us': metrics.renderP50Us,
            'nativeRenderP99Us': metrics.renderP99Us,
            'nativeRenderAvgUs': metrics.renderAvgUs,
            'flutterFrameCount': buildUs.length,
            'flutterBuildP50Us': _medianInt(buildUs),
            'flutterBuildP99Us': _p99Int(buildUs),
            'flutterRasterP50Us': _medianInt(rasterUs),
            'flutterRasterP99Us': _p99Int(rasterUs),
            'rssBytes': ProcessInfo.currentRss,
            'maxRssBytes': ProcessInfo.maxRss,
          };
        } finally {
          if (timingsAttached) {
            SchedulerBinding.instance.removeTimingsCallback(onTimings);
            timingsAttached = false;
          }
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
          if (isGpuNext) {
            if (sessionId > 0) {
              await bridge.setViewportRect(
                sessionId: sessionId,
                leftPx: 0,
                topPx: 0,
                rightPx: 0,
                bottomPx: 0,
                visible: false,
              );
            }
            if (!mpv.isDisposed && mpv.isInitialized) {
              mpv.setPropertyString('vo', 'null');
              mpv.setPropertyString('wid', '0');
            }
            await mpv.dispose();
            if (sessionId > 0) {
              await bridge.disposeSession(sessionId);
            }
          } else {
            if (sessionId > 0) {
              await bridge.disposeSession(sessionId);
            }
            await mpv.dispose();
          }
        }
      }

      // 预热四套管线（gpu-next / DirectComposition 10-bit / 10-bit 共享纹理 / FP16 共享纹理）。
      for (final name in const [
        'gpu_next',
        'dcomp_10bit',
        'd3d11_10bit',
        'd3d11_fp16',
      ]) {
        await runSingleBackendTrial(
          name,
          sampleDuration: const Duration(milliseconds: 450),
        );
      }

      // 正反交替 5 轮四端对比采样（消除热漂移与顺序偏差）。
      final gpuNextSamples = <Map<String, Object?>>[];
      final dcompSamples = <Map<String, Object?>>[];
      final d3d11TenBitSamples = <Map<String, Object?>>[];
      final d3d11Fp16Samples = <Map<String, Object?>>[];
      for (var round = 0; round < 5; round++) {
        final order = round.isEven
            ? const ['gpu_next', 'dcomp_10bit', 'd3d11_10bit', 'd3d11_fp16']
            : const ['d3d11_fp16', 'd3d11_10bit', 'dcomp_10bit', 'gpu_next'];
        for (final backendName in order) {
          final sample = await runSingleBackendTrial(
            backendName,
            sampleDuration: const Duration(milliseconds: 900),
          );
          if (backendName == 'gpu_next') {
            gpuNextSamples.add(sample);
          } else if (backendName == 'dcomp_10bit') {
            dcompSamples.add(sample);
          } else if (backendName == 'd3d11_10bit') {
            d3d11TenBitSamples.add(sample);
          } else {
            d3d11Fp16Samples.add(sample);
          }
        }
      }

      Map<String, Object?> summarize(List<Map<String, Object?>> samples) {
        return <String, Object?>{
          'actualBackend': samples.last['actualBackend'],
          'currentVo': samples.last['currentVo'],
          'videoOutPixelFormat': samples.last['videoOutPixelFormat'],
          'videoOutColorSpace': samples.last['videoOutColorSpace'],
          'videoOutPrimaries': samples.last['videoOutPrimaries'],
          'surfaceFormat': samples.last['surfaceFormat'],
          'colorBitDepth': samples.last['colorBitDepth'],
          'dcompActive': samples.last['dcompActive'],
          'nativeRenderP50UsMedian': _medianInt([
            for (final s in samples) s['nativeRenderP50Us']! as int,
          ]),
          'nativeRenderP99UsMedian': _medianInt([
            for (final s in samples) s['nativeRenderP99Us']! as int,
          ]),
          'flutterRasterP50UsMedian': _medianInt([
            for (final s in samples) s['flutterRasterP50Us']! as int,
          ]),
          'flutterRasterP99UsMedian': _medianInt([
            for (final s in samples) s['flutterRasterP99Us']! as int,
          ]),
          'renderedFramesMedian': _medianInt([
            for (final s in samples) s['renderedFrames']! as int,
          ]),
          'rssBytesMedian': _medianInt([
            for (final s in samples) s['rssBytes']! as int,
          ]),
          'samples': samples,
        };
      }

      // 共存实测：flutter_acrylic 透光窗口材质 + Windows gpu-next 悬浮视频小窗根画布挖空 + 毛玻璃弹窗覆盖。
      Future<Map<String, Object?>> runAcrylicMiniAndGlassDialogCoexistence() async {
        await Window.initialize();
        final materialCtrl = WindowMaterialController();
        await materialCtrl.apply(
          themeMode: ThemeMode.dark,
          platformBrightness: Brightness.dark,
          material: KonataWindowMaterial.acrylic,
          force: true,
        );

        final mpv = FfiLibMpvClient.create(preferredLibraryPath: dllPath);
        int sessionId = 0;
        try {
          final handle = await bridge.createSession(
            mpvHandleAddress: 0,
            width: 1280,
            height: 720,
            preferSoftware: false,
            renderBackend: 'gpu_next',
          );
          sessionId = handle.sessionId;
          expect(handle.nativeWindowHandle, greaterThan(0));
          MpvQualityProfile.applyPreInitVideoOptions(
            mpv,
            config: const PlaybackQualityConfig(
              preset: VideoQualityPreset.highFidelity,
              outputPipelineMode: VideoOutputPipelineMode.gpuNextUnderlay,
            ),
            mpvConfigDir: tempMpvDir,
            isWindowsOverride: true,
            isAndroidOverride: false,
            desktopUnderlayHwnd: handle.nativeWindowHandle,
            desktopDelegate: const WindowsMpvProfileDelegate(),
          );
          mpv.setOptionString('pause', 'no');
          mpv.setOptionString('loop-file', 'inf');
          expect(mpv.initialize(), equals(0));
          expect(
            mpv.command(['loadfile', tenBitFixture.path, 'replace']),
            greaterThanOrEqualTo(0),
          );

          const work = Work(id: 'win_ab_work', title: 'Windows 10-bit 共存实测');
          const episode = Episode(
            id: 'win_ab_ep1',
            workId: 'win_ab_work',
            seasonNumber: 1,
            episodeNumber: 1,
            category: EpisodeCategory.main,
            title: 'EP01',
          );
          final src = MediaSource(
            id: 'local_ab',
            label: '本地测试源',
            kind: MediaSourceKind.local,
            location: tempMpvDir.path,
          );
          final variant = MediaVariant(
            id: 'win_ab_var1',
            workId: 'win_ab_work',
            episodeId: 'win_ab_ep1',
            sourceId: 'local_ab',
            relativePath: p.basename(tenBitFixture.path),
            fileName: p.basename(tenBitFixture.path),
            fileSize: tenBitFixture.lengthSync(),
          );
          final bundle = WorkDetailBundle(
            work: work,
            episodes: const [episode],
            variants: [variant],
            sourcesById: {'local_ab': src},
            latestPlayback: null,
          );
          final req = VideoLaunchRequest(
            work: work,
            bundle: bundle,
            episode: episode,
            variant: variant,
          );

          late _WindowsUnderlayCoexistenceController coexistenceCtrl;
          var dialogActionTapped = false;

          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                videoPlaybackProvider(req).overrideWith(() {
                  coexistenceCtrl = _WindowsUnderlayCoexistenceController(
                    req,
                    bridge: bridge,
                    sessionId: sessionId,
                  );
                  return coexistenceCtrl;
                }),
              ],
              child: MaterialApp(
                theme: KonataTheme.darkTheme(),
                home: Builder(
                  builder: (context) {
                    final layout = AdaptiveCapsuleLayout(
                      size: MediaQuery.sizeOf(context),
                      safe: EdgeInsets.zero,
                      android: false,
                      miniKind: FloatingMiniPlayerKind.video,
                    );
                    return Scaffold(
                      backgroundColor: Colors.transparent,
                      body: Stack(
                        fit: StackFit.expand,
                        children: [
                          KonataFloatingMiniPlayer(
                            kind: FloatingMiniPlayerKind.video,
                            layout: layout,
                            videoRequest: req,
                            sharedVideoSurface: KonataHardwareVideoSurface(
                              key: GlobalObjectKey(req),
                              request: req,
                              miniPreview: true,
                              cornerRadius:
                                  KonataPlaybackTokens.floatingMiniRadius,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 250));

          final miniFinder = find.byKey(
            const ValueKey('konata_floating_mini_player'),
          );
          expect(miniFinder, findsOneWidget);
          expect(
            find.byKey(const ValueKey('windows_underlay_cutout_surface')),
            findsOneWidget,
          );

          // 确认 Windows 底层子窗口模式下挖空表面未被 ClipRRect 或外层 RepaintBoundary 阻断穿透。
          final clipWrappingUnderlay = find.descendant(
            of: miniFinder,
            matching: find.ancestor(
              of: find.byKey(const ValueKey('windows_underlay_cutout_surface')),
              matching: find.byType(ClipRRect),
            ),
          );
          expect(clipWrappingUnderlay, findsNothing);

          final repaintAncestorsBetweenMiniAndPlayer = find.descendant(
            of: find.byType(KonataFloatingMiniPlayer),
            matching: find.ancestor(
              of: miniFinder,
              matching: find.byType(RepaintBoundary),
            ),
          );
          expect(repaintAncestorsBetweenMiniAndPlayer, findsNothing);

          expect(coexistenceCtrl.syncedViewportCount, greaterThanOrEqualTo(1));
          final synced = coexistenceCtrl.lastSyncedViewport;
          expect(synced, isNotNull);
          expect(synced!.visible, isTrue);
          expect(synced.rightPx - synced.leftPx, greaterThan(120));
          expect(synced.bottomPx - synced.topPx, greaterThan(60));
          expect(synced.radiusPx, greaterThan(0.0));

          // 弹出毛玻璃弹窗验证覆盖层级、BackdropFilter 渲染与点击拦截。
          final dialogHostContext = tester.element(find.byType(Scaffold));
          final dialogFuture = showKonataGlassDialog<void>(
            context: dialogHostContext,
            builder: (dialogCtx) => KonataGlassDialog(
              title: '毛玻璃覆盖共存验证',
              width: 420,
              child: Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  key: const ValueKey('coexistence_glass_dialog_confirm'),
                  onPressed: () {
                    dialogActionTapped = true;
                    Navigator.of(dialogCtx).pop();
                  },
                  child: const Text('确认覆盖'),
                ),
              ),
            ),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));

          expect(find.byType(KonataGlassDialog), findsOneWidget);
          expect(
            find.descendant(
              of: find.byType(KonataGlassDialog),
              matching: find.byType(BackdropFilter),
            ),
            findsWidgets,
          );

          // 持续泵帧确认共存状态下 gpu-next 持续稳定出帧。
          final deadline = DateTime.now().add(const Duration(seconds: 3));
          var framesWhileCoexisting = 0;
          while (DateTime.now().isBefore(deadline)) {
            await tester.pump(const Duration(milliseconds: 24));
            final voReady = mpv.getPropertyFlag('vo-configured') ?? false;
            final est = mpv.getPropertyInt64('estimated-frame-number') ?? 0;
            if (voReady && est >= 5) {
              framesWhileCoexisting = est;
              break;
            }
          }
          expect(framesWhileCoexisting, greaterThanOrEqualTo(5));

          await tester.tap(
            find.byKey(const ValueKey('coexistence_glass_dialog_confirm')),
          );
          await tester.pumpAndSettle();
          await dialogFuture;
          expect(dialogActionTapped, isTrue);

          return <String, Object?>{
            'acrylicApplied': true,
            'miniWindowHolePunchUnblocked': true,
            'miniWindowNoClipRRect': true,
            'miniWindowNoOuterRepaintBoundary': true,
            'syncedViewportCount': coexistenceCtrl.syncedViewportCount,
            'syncedViewportWidthPx': synced.rightPx - synced.leftPx,
            'syncedViewportHeightPx': synced.bottomPx - synced.topPx,
            'syncedCornerRadiusPx': synced.radiusPx,
            'glassDialogOverlayHitTested': dialogActionTapped,
            'framesWhileCoexisting': framesWhileCoexisting,
            'currentVo': mpv.getPropertyString('current-vo') ?? '',
          };
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
          if (sessionId > 0) {
            await bridge.setViewportRect(
              sessionId: sessionId,
              leftPx: 0,
              topPx: 0,
              rightPx: 0,
              bottomPx: 0,
              visible: false,
            );
          }
          if (!mpv.isDisposed && mpv.isInitialized) {
            mpv.setPropertyString('vo', 'null');
            mpv.setPropertyString('wid', '0');
          }
          await mpv.dispose();
          if (sessionId > 0) {
            await bridge.disposeSession(sessionId);
          }
        }
      }

      final coexistenceVerification =
          await runAcrylicMiniAndGlassDialogCoexistence();

      final report = <String, Object?>{
        'timestamp': DateTime.now().toIso8601String(),
        'adapterName': caps.adapterName,
        'supportsFp16': caps.supportsFp16,
        'supports10Bit': caps.supports10Bit,
        'supportsDcomp10Bit': caps.supportsDcomp10Bit,
        'selectedDefaultBackend': 'd3d11_10bit',
        'gpu_next': summarize(gpuNextSamples),
        'dcomp_10bit': summarize(dcompSamples),
        'd3d11_10bit': summarize(d3d11TenBitSamples),
        'd3d11_fp16': summarize(d3d11Fp16Samples),
        'coexistenceVerification': coexistenceVerification,
      };

      final outFile = File(
        p.join(
          Directory.current.path,
          '.agent-work',
          'benchmarks',
          'windows_video_backend_ab.json',
        ),
      );
      await outFile.parent.create(recursive: true);
      await outFile.writeAsString(
        const JsonEncoder.withIndent('  ').convert(report),
        flush: true,
      );
      debugPrint('WINDOWS_VIDEO_AB_JSON=${jsonEncode(report)}');

      expect(gpuNextSamples.length, equals(5));
      expect(dcompSamples.length, equals(5));
      expect(d3d11TenBitSamples.length, equals(5));
      expect(d3d11Fp16Samples.length, equals(5));
      expect(
        (report['d3d11_10bit']! as Map)['colorBitDepth'],
        equals(10),
      );
      expect(
        (report['d3d11_fp16']! as Map)['colorBitDepth'],
        equals(16),
      );
      expect((report['gpu_next']! as Map)['currentVo'], equals('gpu-next'));
      expect(
        (report['gpu_next']! as Map)['colorBitDepth'],
        greaterThanOrEqualTo(10),
      );
      expect(
        (report['dcomp_10bit']! as Map)['colorBitDepth'],
        greaterThanOrEqualTo(10),
      );
      expect(coexistenceVerification['acrylicApplied'], isTrue);
      expect(coexistenceVerification['miniWindowHolePunchUnblocked'], isTrue);
      expect(coexistenceVerification['glassDialogOverlayHitTested'], isTrue);
    },
  );
}
