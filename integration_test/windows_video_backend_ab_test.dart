import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;

import 'package:ccplayer/infrastructure/players/d3d11_video_bridge.dart';
import 'package:ccplayer/infrastructure/players/libmpv_ffi.dart';
import 'package:ccplayer/infrastructure/players/mpv_quality_profile.dart';

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
        try {
          MpvQualityProfile.applyPreInitVideoOptions(
            mpv,
            config: PlaybackQualityConfig(
              preset: VideoQualityPreset.highFidelity,
              windowsRenderBackend: requestedBackend == 'dcomp_10bit'
                  ? WindowsVideoRenderBackend.directComposition10Bit
                  : WindowsVideoRenderBackend.d3d11Fp16,
            ),
            mpvConfigDir: tempMpvDir,
            isWindowsOverride: true,
            isAndroidOverride: false,
          );
          mpv.setOptionString('ao', 'null');
          mpv.setOptionString('pause', 'no');
          mpv.setOptionString('loop-file', 'inf');
          expect(mpv.initialize(), equals(0));

          final handle = await bridge.createSession(
            mpvHandleAddress: mpv.handleAddress,
            width: 1280,
            height: 720,
            preferSoftware: false,
            renderBackend: requestedBackend,
          );
          sessionId = handle.sessionId;
          expect(handle.isSoftwareFallback, isFalse);

          if (handle.dcompActive) {
            await bridge.setViewportRect(
              sessionId: sessionId,
              leftPx: 0,
              topPx: 0,
              rightPx: 1280,
              bottomPx: 720,
              cornerRadiusPx: 0.0,
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
            final m = await bridge.getSessionMetrics(sessionId);
            if (m != null && m.renderedFrames >= 5) {
              break;
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
          expect(metrics!.renderedFrames, greaterThan(10));

          return <String, Object?>{
            'requestedBackend': requestedBackend,
            'actualBackend': metrics.backend,
            'surfaceFormat': metrics.surfaceFormat,
            'colorBitDepth': metrics.colorBitDepth,
            'dcompActive': metrics.dcompActive,
            'renderedFrames': metrics.renderedFrames,
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
          if (sessionId > 0) {
            await bridge.disposeSession(sessionId);
          }
          await mpv.dispose();
        }
      }

      // 预热两套管线（着色器编译与 D3D11/DComp 驱动常驻缓存）。
      await runSingleBackendTrial(
        'd3d11_fp16',
        sampleDuration: const Duration(milliseconds: 450),
      );
      await runSingleBackendTrial(
        'dcomp_10bit',
        sampleDuration: const Duration(milliseconds: 450),
      );

      // 正反交替 5 轮 A/B 采样（消除热漂移与顺序偏差）。
      final d3d11Samples = <Map<String, Object?>>[];
      final dcompSamples = <Map<String, Object?>>[];
      for (var round = 0; round < 5; round++) {
        final order = round.isEven
            ? const ['d3d11_fp16', 'dcomp_10bit']
            : const ['dcomp_10bit', 'd3d11_fp16'];
        for (final backendName in order) {
          final sample = await runSingleBackendTrial(
            backendName,
            sampleDuration: const Duration(milliseconds: 900),
          );
          if (backendName == 'd3d11_fp16') {
            d3d11Samples.add(sample);
          } else {
            dcompSamples.add(sample);
          }
        }
      }

      Map<String, Object?> summarize(List<Map<String, Object?>> samples) {
        return <String, Object?>{
          'actualBackend': samples.last['actualBackend'],
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

      final report = <String, Object?>{
        'timestamp': DateTime.now().toIso8601String(),
        'adapterName': caps.adapterName,
        'supportsFp16': caps.supportsFp16,
        'supports10Bit': caps.supports10Bit,
        'supportsDcomp10Bit': caps.supportsDcomp10Bit,
        'd3d11_fp16': summarize(d3d11Samples),
        'dcomp_10bit': summarize(dcompSamples),
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

      expect(d3d11Samples.length, equals(5));
      expect(dcompSamples.length, equals(5));
      expect(
        (report['d3d11_fp16']! as Map)['colorBitDepth'],
        greaterThanOrEqualTo(10),
      );
      expect(
        (report['dcomp_10bit']! as Map)['colorBitDepth'],
        greaterThanOrEqualTo(10),
      );
    },
  );
}
