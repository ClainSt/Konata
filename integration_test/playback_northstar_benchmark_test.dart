import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:ccplayer/application/playback/audiophile_safety_coordinator.dart';
import 'package:ccplayer/domain/playback/audiophile_safety_policy.dart';
import 'package:ccplayer/domain/playback/subtitle_content_processor.dart';
import 'package:ccplayer/domain/text/multibyte_text_decoder.dart';
import 'package:ccplayer/infrastructure/players/libmpv_ffi.dart';
import 'package:ccplayer/infrastructure/players/mpv_quality_profile.dart';
import 'package:ccplayer/presentation/theme/konata_theme.dart';
import 'package:ccplayer/presentation/widgets/playback/konata_stage_morph_frame.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;

import 'process_metrics.dart';

/// 生成真实 10-bit (`C420p10`) 60fps YUV4MPEG2 测试视频流（无外部媒体依赖）。
Future<File> _generateTenBitVideoFixture(
  Directory dir, {
  int width = 320,
  int height = 180,
  int frameCount = 90,
}) async {
  final file = File(p.join(dir.path, 'konata_bench_10bit.y4m'));
  final sink = file.openWrite();
  sink.add(ascii.encode('YUV4MPEG2 W$width H$height F60:1 Ip C420p10\n'));
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
    final shift = f * 9;
    for (var y = 0; y < height; y++) {
      final rowBias = (y * 3) & 0x1FF;
      for (var x = 0; x < width; x++) {
        final v = 64 + ((x * 2 + rowBias + shift) % 876);
        bd.setUint16(offset, v, Endian.little);
        offset += 2;
      }
    }
    final uVal = 420 + ((f * 3) % 180);
    for (var i = 0; i < uvSamples; i++) {
      bd.setUint16(offset, uVal, Endian.little);
      offset += 2;
    }
    final vVal = 600 - ((f * 3) % 180);
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

/// 生成真实 48kHz / 24-bit 立体声无损 PCM WAV 测试音频（2 秒正弦测试信号）。
Future<File> _generateLossless48k24bitWav(
  Directory dir, {
  int sampleRate = 48000,
  int durationSeconds = 2,
}) async {
  final file = File(p.join(dir.path, 'konata_bench_48k_24bit.wav'));
  const channels = 2;
  const bitsPerSample = 24;
  const bytesPerSample = bitsPerSample ~/ 8;
  final numFrames = sampleRate * durationSeconds;
  final dataSize = numFrames * channels * bytesPerSample;
  final out = Uint8List(44 + dataSize);
  final bd = ByteData.sublistView(out);

  void writeTag(int offset, String tag) {
    for (var i = 0; i < 4; i++) {
      out[offset + i] = tag.codeUnitAt(i);
    }
  }

  writeTag(0, 'RIFF');
  bd.setUint32(4, 36 + dataSize, Endian.little);
  writeTag(8, 'WAVE');
  writeTag(12, 'fmt ');
  bd.setUint32(16, 16, Endian.little);
  bd.setUint16(20, 1, Endian.little);
  bd.setUint16(22, channels, Endian.little);
  bd.setUint32(24, sampleRate, Endian.little);
  bd.setUint32(28, sampleRate * channels * bytesPerSample, Endian.little);
  bd.setUint16(32, channels * bytesPerSample, Endian.little);
  bd.setUint16(34, bitsPerSample, Endian.little);
  writeTag(36, 'data');
  bd.setUint32(40, dataSize, Endian.little);

  var pos = 44;
  const scale = 2000000.0;
  for (var i = 0; i < numFrames; i++) {
    final t = i / sampleRate;
    final l = (math.sin(2.0 * math.pi * 440.0 * t) * scale).round();
    final r = (math.sin(2.0 * math.pi * 660.0 * t) * scale).round();
    out[pos++] = l & 0xFF;
    out[pos++] = (l >> 8) & 0xFF;
    out[pos++] = (l >> 16) & 0xFF;
    out[pos++] = r & 0xFF;
    out[pos++] = (r >> 8) & 0xFF;
    out[pos++] = (r >> 16) & 0xFF;
  }
  await file.writeAsBytes(out, flush: true);
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

/// 驱动真实 `KonataStageMorphFrame` 执行单轮双向临界阻尼弹簧展开与收起形变的测试宿主。
class _MorphBenchHost extends StatefulWidget {
  const _MorphBenchHost({
    required this.isCollapsing,
    required this.releaseVelocityPxPerSec,
    required this.originRect,
    required this.onCollapseCompleted,
    required this.frameKey,
  });

  final bool isCollapsing;
  final double releaseVelocityPxPerSec;
  final Rect originRect;
  final VoidCallback onCollapseCompleted;
  final GlobalKey<KonataStageMorphFrameState> frameKey;

  @override
  State<_MorphBenchHost> createState() => _MorphBenchHostState();
}

class _MorphBenchHostState extends State<_MorphBenchHost> {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: KonataTheme.darkTheme(),
      home: Scaffold(
        backgroundColor: KonataTheme.cinemaObsidian,
        body: KonataStageMorphFrame(
          key: widget.frameKey,
          originRect: widget.originRect,
          allowClipRadius: true,
          isCollapsing: widget.isCollapsing,
          releaseVelocityPxPerSec: widget.releaseVelocityPxPerSec,
          onCollapseCompleted: widget.onCollapseCompleted,
          child: DecoratedBox(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF141B29), Color(0xFF0A0C12)],
              ),
            ),
            child: Center(
              child: Container(
                width: 240,
                height: 135,
                decoration: BoxDecoration(
                  color: const Color(0xFF1E2636),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.14),
                  ),
                ),
                alignment: Alignment.center,
                child: const Text(
                  'Konata 120Hz 双向弹簧舞台实测',
                  style: TextStyle(color: Colors.white, fontSize: 14),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

Future<int> _measureMpvLoadTtffUs({
  required LibMpvClient client,
  required String filePath,
  String? memorySubtitlePayload,
  bool verifyAudioFormat = false,
  Map<String, Object?>? outDiagnostics,
}) async {
  final ready = Completer<void>();
  late final StreamSubscription<MpvClientEvent> sub;
  sub = client.events.listen((event) {
    if (event is MpvPlaybackRestartEvent && !ready.isCompleted) {
      ready.complete();
    } else if (event is MpvEndFileEvent &&
        event.reason == MpvEndFileReason.error &&
        !ready.isCompleted) {
      ready.completeError(StateError('libmpv 加载失败: code=${event.errorCode}'));
    }
  });
  try {
    final watch = Stopwatch()..start();
    final rc = client.command(['loadfile', filePath, 'replace']);
    expect(rc, equals(0), reason: 'libmpv loadfile 必须成功');
    await ready.future.timeout(const Duration(seconds: 12));
    watch.stop();

    if (memorySubtitlePayload != null) {
      final subRc = client.command([
        'sub-add',
        'memory://$memorySubtitlePayload',
        'cached',
        'Konata实测内存字幕',
      ]);
      expect(subRc, equals(0), reason: 'sub-add memory:// cached 必须成功');
      await Future<void>.delayed(const Duration(milliseconds: 60));
      final trackCount = client.getPropertyInt64('track-list/count') ?? 0;
      expect(trackCount, greaterThanOrEqualTo(2));
      outDiagnostics?['memory_subtitle_track_count'] = trackCount;
    }

    if (verifyAudioFormat) {
      var sampleRate = 0;
      var audioFormat = '';
      for (var attempt = 0; attempt < 25; attempt++) {
        sampleRate = client.getPropertyInt64('audio-params/samplerate') ?? 0;
        audioFormat = client.getPropertyString('audio-params/format') ?? '';
        if (sampleRate > 0 && audioFormat.isNotEmpty) break;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(sampleRate, equals(48000), reason: '必须精确还原 48kHz 无损源采样率');
      expect(audioFormat, isNotEmpty, reason: '必须上报真实音频采样格式');
      outDiagnostics?['audio_sample_rate_hz'] = sampleRate;
      outDiagnostics?['audio_sample_format'] = audioFormat;
    }

    return watch.elapsedMicroseconds;
  } finally {
    await sub.cancel();
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('三端真实音视频播放专项集成基准（预热后正反 5 轮 A/B 采样）', (tester) async {
    final tempDir = await Directory.systemTemp.createTemp('konata_av_bench_');
    addTearDown(() async {
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
    });

    final mpvConfigDir = Directory(p.join(tempDir.path, 'mpv_cfg'));
    await mpvConfigDir.create(recursive: true);
    final videoFile = await _generateTenBitVideoFixture(tempDir);
    final audioFile = await _generateLossless48k24bitWav(tempDir);
    expect(videoFile.existsSync(), isTrue);
    expect(audioFile.existsSync(), isTrue);

    // 经全仓唯一 OpenCC 与纯字节解码器生成真实内存 ASS 字幕，串通 R4 字幕流水线。
    const rawTradAss =
        '[Script Info]\nScriptType: v4.00+\n\n[Events]\n'
        'Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n'
        'Dialogue: 0,0:00:00.00,0:00:02.00,Default,,0,0,0,,電影院裡的皇后與頭髪乾乾淨淨\n';
    final decodedSub = MultibyteTextDecoder.decodeBytes(
      Uint8List.fromList(utf8.encode(rawTradAss)),
    );
    final convertedSub = SubtitleContentProcessor.process(
      content: decodedSub,
      mode: SubtitleOpenCcMode.toSimplified,
    );
    expect(convertedSub.content, contains('电影院里的皇后'));

    // 1. 构造真实 libmpv 视频会话与无损音频会话。
    String? preferredWinDll;
    if (Platform.isWindows) {
      final localDll = p.join(
        Directory.current.path,
        'native',
        'konata-native',
        'windows',
        'libmpv-2.dll',
      );
      if (File(localDll).existsSync()) {
        preferredWinDll = localDll;
      }
    }

    final videoClient = FfiLibMpvClient.create(
      preferredLibraryPath: preferredWinDll,
    );
    final audioClient = FfiLibMpvClient.create(
      preferredLibraryPath: preferredWinDll,
    );
    addTearDown(() async {
      await videoClient.dispose();
      await audioClient.dispose();
    });

    MpvQualityProfile.applyPreInitVideoOptions(
      videoClient,
      config: const PlaybackQualityConfig(
        preset: VideoQualityPreset.highFidelity,
      ),
      mpvConfigDir: mpvConfigDir,
      isWindowsOverride: Platform.isWindows,
      isAndroidOverride: Platform.isAndroid,
    );
    videoClient.setOptionString('vo', 'null');
    videoClient.setOptionString('ao', 'null');
    videoClient.setOptionString('pause', 'no');
    videoClient.setOptionString('loop-file', 'inf');
    videoClient.setOptionString('sub-auto', 'fuzzy');
    expect(videoClient.initialize(), equals(0), reason: '视频 libmpv 初始化必须成功');

    MpvQualityProfile.applyPreInitAudioOptions(
      audioClient,
      config: const PlaybackQualityConfig(
        preset: VideoQualityPreset.highFidelity,
      ),
      mpvConfigDir: mpvConfigDir,
    );
    audioClient.setOptionString('ao', 'null');
    audioClient.setOptionString('pause', 'no');
    audioClient.setOptionString('loop-file', 'inf');
    expect(audioClient.initialize(), equals(0), reason: '音频 libmpv 初始化必须成功');

    // 应用共享发烧音频安全链（-12 dBFS 数字安全上限与 150ms S 型微淡入斜坡校验）。
    final safetyPlan = AudiophileSafetyPolicy.buildPlan(
      requestedMode: AudioOutputRouteMode.sharedResampled,
      safetyState: const AudioDeviceSafetyState(),
    );
    expect(safetyPlan.safetyLimiterEngaged, isTrue);
    expect(safetyPlan.audioFilterString, contains('alimiter=limit=0.251'));
    audioClient.setPropertyString('af', safetyPlan.audioFilterString);

    final fadeDriver = AudiophileMicroFadeDriver(
      stepInterval: const Duration(milliseconds: 25),
    );
    addTearDown(fadeDriver.cancel);
    fadeDriver.start(
      client: audioClient,
      plan: safetyPlan,
      targetVolume: 85.0,
      isMuted: false,
      isAlive: () => !audioClient.isDisposed,
    );
    await Future<void>.delayed(const Duration(milliseconds: 260));
    expect(fadeDriver.isActive, isFalse, reason: '150ms S 型微淡入终态必须立即停钟');
    expect(audioClient.getPropertyDouble('volume') ?? 0.0, closeTo(85.0, 0.5));

    // 预热一轮（不计入 5 轮正式采样）。
    await _measureMpvLoadTtffUs(
      client: videoClient,
      filePath: videoFile.path,
      memorySubtitlePayload: convertedSub.content,
    );
    await _measureMpvLoadTtffUs(
      client: audioClient,
      filePath: audioFile.path,
      verifyAudioFormat: true,
    );

    // 收集 120Hz 双向弹簧 FrameTiming 回调。
    final activeMorphFrames = <FrameTiming>[];
    var collectingMorph = false;
    void onTimings(List<FrameTiming> timings) {
      if (collectingMorph) {
        activeMorphFrames.addAll(timings);
      }
    }

    binding.addTimingsCallback(onTimings);
    addTearDown(() => binding.removeTimingsCallback(onTimings));

    // 预热一轮双向弹簧形变。
    final warmupKey = GlobalKey<KonataStageMorphFrameState>();
    var warmupCollapsed = false;
    await tester.pumpWidget(
      _MorphBenchHost(
        frameKey: warmupKey,
        isCollapsing: false,
        releaseVelocityPxPerSec: 640.0,
        originRect: const Rect.fromLTWH(24, 320, 260, 146),
        onCollapseCompleted: () => warmupCollapsed = true,
      ),
    );
    await tester.pumpAndSettle(const Duration(milliseconds: 16));
    await tester.pumpWidget(
      _MorphBenchHost(
        frameKey: warmupKey,
        isCollapsing: true,
        releaseVelocityPxPerSec: 1280.0,
        originRect: const Rect.fromLTWH(24, 320, 260, 146),
        onCollapseCompleted: () => warmupCollapsed = true,
      ),
    );
    await tester.pumpAndSettle(const Duration(milliseconds: 16));
    expect(warmupCollapsed, isTrue);

    final rounds = <Map<String, Object?>>[];
    const osdPropToken = 201;

    Future<({int eventCount, int cpuUs, int peakRssBytes})> sampleOsdWindow({
      required bool hudActive,
      required Duration duration,
    }) async {
      var eventCount = 0;
      final sub = videoClient.events.listen((event) {
        if (event is MpvPropertyChangeEvent &&
            event.replyUserdata == osdPropToken &&
            event.name == 'time-pos') {
          eventCount++;
        }
      });
      try {
        if (hudActive) {
          videoClient.observeProperty(osdPropToken, 'time-pos', MpvFormat.double_);
        } else {
          videoClient.unobserveProperty(osdPropToken);
          // 排空退订瞬间队列中尚未消费的尾部事件，再开始稳态静默期计数。
          await Future<void>.delayed(const Duration(milliseconds: 80));
          eventCount = 0;
        }
        final cpuStart = processCpuMicroseconds();
        var peakRss = ProcessInfo.currentRss;
        final rssTimer = Timer.periodic(const Duration(milliseconds: 25), (_) {
          final cur = ProcessInfo.currentRss;
          if (cur > peakRss) peakRss = cur;
        });
        try {
          await tester.runAsync(() => Future<void>.delayed(duration));
        } finally {
          rssTimer.cancel();
        }
        final cpuDelta = processCpuMicroseconds() - cpuStart;
        return (
          eventCount: eventCount,
          cpuUs: cpuDelta,
          peakRssBytes: peakRss,
        );
      } finally {
        await sub.cancel();
      }
    }

    // 正反交替 5 轮真实采样（偶数轮 A->B，奇数轮 B->A，消除顺序热漂移偏差）。
    for (var round = 0; round < 5; round++) {
      final reverseOrder = round.isOdd;
      final diag = <String, Object?>{};
      int videoTtffUs;
      int audioTtffUs;

      if (!reverseOrder) {
        videoTtffUs = await _measureMpvLoadTtffUs(
          client: videoClient,
          filePath: videoFile.path,
          memorySubtitlePayload: convertedSub.content,
          outDiagnostics: diag,
        );
        audioTtffUs = await _measureMpvLoadTtffUs(
          client: audioClient,
          filePath: audioFile.path,
          verifyAudioFormat: true,
          outDiagnostics: diag,
        );
      } else {
        audioTtffUs = await _measureMpvLoadTtffUs(
          client: audioClient,
          filePath: audioFile.path,
          verifyAudioFormat: true,
          outDiagnostics: diag,
        );
        videoTtffUs = await _measureMpvLoadTtffUs(
          client: videoClient,
          filePath: videoFile.path,
          memorySubtitlePayload: convertedSub.content,
          outDiagnostics: diag,
        );
      }

      // 柱二：正反 A/B 对比 OSD 展示期 vs OSD 隐藏稳态期零唤醒率。
      ({int eventCount, int cpuUs, int peakRssBytes}) osdActiveRes;
      ({int eventCount, int cpuUs, int peakRssBytes}) osdHiddenRes;
      if (!reverseOrder) {
        osdActiveRes = await sampleOsdWindow(
          hudActive: true,
          duration: const Duration(milliseconds: 500),
        );
        osdHiddenRes = await sampleOsdWindow(
          hudActive: false,
          duration: const Duration(milliseconds: 500),
        );
      } else {
        osdHiddenRes = await sampleOsdWindow(
          hudActive: false,
          duration: const Duration(milliseconds: 500),
        );
        osdActiveRes = await sampleOsdWindow(
          hudActive: true,
          duration: const Duration(milliseconds: 500),
        );
        videoClient.unobserveProperty(osdPropToken);
      }
      expect(
        osdActiveRes.eventCount,
        greaterThan(0),
        reason: 'OSD 展开态必须收到真实 libmpv time-pos 进度回调',
      );
      expect(
        osdHiddenRes.eventCount,
        equals(0),
        reason: 'OSD 隐藏稳态期必须彻底退订高频进度实现 0 唤醒',
      );

      // 柱三：120Hz 双向 SpringSimulation 形变帧耗时采样。
      activeMorphFrames.clear();
      final morphKey = GlobalKey<KonataStageMorphFrameState>();
      var collapseCompleted = false;
      collectingMorph = true;
      await tester.pumpWidget(
        _MorphBenchHost(
          frameKey: morphKey,
          isCollapsing: false,
          releaseVelocityPxPerSec: 640.0,
          originRect: const Rect.fromLTWH(24, 320, 260, 146),
          onCollapseCompleted: () => collapseCompleted = true,
        ),
      );
      await tester.pumpAndSettle(const Duration(milliseconds: 8));
      expect(morphKey.currentState?.isTickerActive, isFalse);

      await tester.pumpWidget(
        _MorphBenchHost(
          frameKey: morphKey,
          isCollapsing: true,
          releaseVelocityPxPerSec: 1280.0,
          originRect: const Rect.fromLTWH(24, 320, 260, 146),
          onCollapseCompleted: () => collapseCompleted = true,
        ),
      );
      await tester.pumpAndSettle(const Duration(milliseconds: 8));
      collectingMorph = false;
      expect(collapseCompleted, isTrue);
      expect(morphKey.currentState?.isTickerActive, isFalse);

      final buildUs = activeMorphFrames
          .map((f) => f.buildDuration.inMicroseconds)
          .toList(growable: false);
      final rasterUs = activeMorphFrames
          .map((f) => f.rasterDuration.inMicroseconds)
          .toList(growable: false);
      expect(buildUs, isNotEmpty, reason: '双向弹簧过渡必须采集到真实渲染帧耗时');

      rounds.add({
        'round': round + 1,
        'order': reverseOrder ? 'reverse_BA' : 'forward_AB',
        'video_ttff_us': videoTtffUs,
        'audio_ttff_us': audioTtffUs,
        'memory_subtitle_track_count': diag['memory_subtitle_track_count'],
        'audio_sample_rate_hz': diag['audio_sample_rate_hz'],
        'audio_sample_format': diag['audio_sample_format'],
        'osd_active_time_pos_events': osdActiveRes.eventCount,
        'osd_hidden_time_pos_events': osdHiddenRes.eventCount,
        'osd_hidden_zero_wakeup_rate': osdHiddenRes.eventCount == 0 ? 1.0 : 0.0,
        'osd_active_cpu_us': osdActiveRes.cpuUs,
        'osd_hidden_cpu_us': osdHiddenRes.cpuUs,
        'steady_peak_rss_bytes': osdHiddenRes.peakRssBytes,
        'spring_morph_frame_count': buildUs.length,
        'spring_morph_build_p50_us': _medianInt(buildUs),
        'spring_morph_build_p99_us': _p99Int(buildUs),
        'spring_morph_raster_p50_us': _medianInt(rasterUs),
        'spring_morph_raster_p99_us': _p99Int(rasterUs),
      });
    }

    final videoTtffs = [for (final r in rounds) r['video_ttff_us']! as int];
    final audioTtffs = [for (final r in rounds) r['audio_ttff_us']! as int];
    final morphBuildP99s = [
      for (final r in rounds) r['spring_morph_build_p99_us']! as int,
    ];
    final morphRasterP99s = [
      for (final r in rounds) r['spring_morph_raster_p99_us']! as int,
    ];
    final steadyRsses = [
      for (final r in rounds) r['steady_peak_rss_bytes']! as int,
    ];
    final hiddenWakeups = [
      for (final r in rounds) r['osd_hidden_time_pos_events']! as int,
    ];

    binding.reportData = {
      'platform': Platform.operatingSystem,
      'sample_rounds': rounds.length,
      'sampling_protocol': 'warmup_1_then_5_alternating_AB_BA',
      'summary': {
        'video_ttff_median_us': _medianInt(videoTtffs),
        'audio_ttff_median_us': _medianInt(audioTtffs),
        'osd_hidden_total_wakeups': hiddenWakeups.fold<int>(0, (a, b) => a + b),
        'osd_hidden_zero_wakeup_rate': hiddenWakeups.every((v) => v == 0)
            ? 1.0
            : 0.0,
        'spring_morph_build_p99_median_us': _medianInt(morphBuildP99s),
        'spring_morph_raster_p99_median_us': _medianInt(morphRasterP99s),
        'steady_peak_rss_median_bytes': _medianInt(steadyRsses),
        'lossless_sample_rate_hz': 48000,
        'audiophile_safety_ceiling_db': -12.0,
        'micro_fade_stopped_at_terminal': !fadeDriver.isActive,
      },
      'rounds': rounds,
    };
  });
}
