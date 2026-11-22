import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ccplayer/application/playback/subtitle_memory_engine.dart';
import 'package:ccplayer/application/playback/unified_playback_engine.dart';
import 'package:ccplayer/domain/models/media_extensions.dart';
import 'package:ccplayer/domain/models/media_source.dart';
import 'package:ccplayer/domain/models/media_variant.dart';
import 'package:ccplayer/domain/playback/subtitle_content_processor.dart';
import 'package:ccplayer/domain/playback/track_preferences.dart';
import 'package:ccplayer/domain/text/multibyte_text_decoder.dart';
import 'package:ccplayer/infrastructure/players/android/android_video_surface_controller.dart';
import 'package:ccplayer/infrastructure/players/d3d11_video_bridge.dart';
import 'package:ccplayer/infrastructure/players/embedded_mpv_session.dart';
import 'package:ccplayer/infrastructure/players/libmpv_ffi.dart';
import 'package:ccplayer/infrastructure/players/mpv_quality_profile.dart';
import 'package:ccplayer/infrastructure/players/windows_mpv_profile_adapter.dart';
import 'package:ccplayer/infrastructure/sources/byte_stream_source_gateway.dart';
import 'package:ccplayer/infrastructure/sources/local_source_gateway.dart';
import 'package:ccplayer/infrastructure/storage/storage_root_provider.dart';
import 'package:ccplayer/infrastructure/stream_bridge/local_stream_bridge.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;

import 'codec_matrix_loader.dart';

/// 为实机测试构建纯透明 `BlendMode.clear` 视口挖空画布，使底层 10-bit 硬件画面真实上屏。
class _HardwareUnderlayCutoutPainter extends CustomPainter {
  const _HardwareUnderlayCutoutPainter();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..blendMode = BlendMode.clear);
  }

  @override
  bool shouldRepaint(covariant _HardwareUnderlayCutoutPainter oldDelegate) =>
      false;
}

/// 统计 `LocalStreamBridge` 上游真实 Range 请求区间与累计流出字节的本地只读代理网关。
class _CountingRangeGateway implements ByteRangeReadableGateway {
  _CountingRangeGateway(this._inner, {required this.totalFileSize});

  final LocalSourceGateway _inner;
  final int totalFileSize;
  final List<({int start, int? endInclusive, int emittedBytes, int cumulativeBeforeStart})>
      requests = [];
  int totalEmittedBytes = 0;
  int? bytesBeforeFirstTailRequest;

  @override
  Future<int?> probeFileLength(String relativePath) =>
      _inner.probeFileLength(relativePath);

  @override
  Future<Stream<List<int>>> openByteRange(
    String relativePath, {
    required int start,
    int? endInclusive,
  }) async {
    final upstream = await _inner.openByteRange(
      relativePath,
      start: start,
      endInclusive: endInclusive,
    );
    final cumBefore = totalEmittedBytes;
    if (bytesBeforeFirstTailRequest == null &&
        start > (totalFileSize * 0.70).round()) {
      bytesBeforeFirstTailRequest = cumBefore;
    }
    final idx = requests.length;
    requests.add((
      start: start,
      endInclusive: endInclusive,
      emittedBytes: 0,
      cumulativeBeforeStart: cumBefore,
    ));
    final controller = StreamController<List<int>>();
    late final StreamSubscription<List<int>> sub;
    sub = upstream.listen(
      (chunk) {
        totalEmittedBytes += chunk.length;
        final prev = requests[idx];
        requests[idx] = (
          start: prev.start,
          endInclusive: prev.endInclusive,
          emittedBytes: prev.emittedBytes + chunk.length,
          cumulativeBeforeStart: prev.cumulativeBeforeStart,
        );
        if (!controller.isClosed) {
          controller.add(chunk);
        }
      },
      onError: (Object error, StackTrace stack) {
        if (!controller.isClosed) {
          controller.addError(error, stack);
        }
      },
      onDone: () {
        if (!controller.isClosed) {
          controller.close();
        }
      },
      cancelOnError: false,
    );
    controller.onCancel = () => sub.cancel();
    return controller.stream;
  }

  @override
  Future<void> close() => _inner.close();
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
    'dw': client.getPropertyInt64('video-out-params/dw') ??
        client.getPropertyInt64('video-params/dw') ??
        0,
    'dh': client.getPropertyInt64('video-out-params/dh') ??
        client.getPropertyInt64('video-params/dh') ??
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
    'colorlevels': client.getPropertyString('video-out-params/colorlevels') ??
        client.getPropertyString('video-params/colorlevels') ??
        '',
    'primaries': client.getPropertyString('video-out-params/primaries') ??
        client.getPropertyString('video-params/primaries') ??
        '',
    'gamma': client.getPropertyString('video-out-params/gamma') ??
        client.getPropertyString('video-params/gamma') ??
        '',
    'sig_peak': client.getPropertyDouble('video-out-params/sig-peak') ??
        client.getPropertyDouble('video-params/sig-peak'),
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

/// 等待真实视频帧呈现并返回精确 `ttff_us`（禁止任何假绿跳过）。
Future<int> _waitFirstRealFrame(
  LibMpvClient client,
  Stopwatch watch,
  Completer<void> firstFrameReady,
) async {
  await firstFrameReady.future.timeout(const Duration(seconds: 15));
  for (var i = 0; i < 60; i++) {
    final w =
        client.getPropertyInt64('video-out-params/w') ??
        client.getPropertyInt64('video-params/w') ??
        0;
    final vo = client.getPropertyString('current-vo') ?? '';
    final ao = client.getPropertyString('current-ao') ?? '';
    final frameNo = client.getPropertyInt64('estimated-frame-number') ?? 0;
    final pos = client.getPropertyDouble('time-pos') ?? 0.0;
    if (w > 0 &&
        vo.isNotEmpty &&
        vo != 'null' &&
        ao.isNotEmpty &&
        ao != 'null' &&
        (frameNo > 0 || pos > 0.01)) {
      break;
    }
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  watch.stop();
  return watch.elapsedMicroseconds;
}

/// 执行真实绝对 Seek 并采集恢复至新帧呈现的微秒耗时。
Future<int> _measureSeekRecoveryUs(
  LibMpvClient client, {
  double targetSeconds = 0.8,
}) async {
  final restarted = Completer<void>();
  late final StreamSubscription<MpvClientEvent> sub;
  sub = client.events.listen((event) {
    if (event is MpvPlaybackRestartEvent && !restarted.isCompleted) {
      restarted.complete();
    }
  });
  try {
    final watch = Stopwatch()..start();
    final rc = client.command([
      'seek',
      targetSeconds.toStringAsFixed(2),
      'absolute',
      'exact',
    ]);
    expect(rc, equals(0), reason: 'libmpv seek 指令必须成功');
    await restarted.future.timeout(const Duration(seconds: 10));
    watch.stop();
    return watch.elapsedMicroseconds;
  } finally {
    await sub.cancel();
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('G01~G12 真实压缩编码微样本矩阵实机硬解/软解冒烟与客观指标采集', (tester) async {
    final matrixDir = await resolveCodecMatrixDirectory();
    final manifestJson =
        jsonDecode(
              await File(
                p.join(matrixDir.path, 'manifest.json'),
              ).readAsString(encoding: utf8),
            )
            as Map<String, Object?>;
    final groupsMeta = (manifestJson['groups']! as Map<String, Object?>);

    // 挂载真实透明挖空舞台，确保 Windows 10-bit gpu-next 子窗口与 Android Underlay SurfaceView 真实上屏。
    await tester.pumpWidget(
      const MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          backgroundColor: Colors.transparent,
          body: SizedBox.expand(
            child: CustomPaint(painter: _HardwareUnderlayCutoutPainter()),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    final view = tester.view;
    final viewportW = view.physicalSize.width.round().clamp(640, 1920);
    final viewportH = view.physicalSize.height.round().clamp(360, 1080);

    final storageRoot = await StorageRootService.createForCurrentPlatform();
    final streamBridge = LocalStreamBridge(storageRoot: storageRoot);
    addTearDown(() async => streamBridge.dispose());

    final winBridge = Platform.isWindows ? D3D11VideoBridge() : null;
    if (winBridge != null) {
      addTearDown(winBridge.dispose);
    }
    final winDll = _resolvePreferredWinMpvDll();
    final desktopDelegate = Platform.isWindows
        ? const WindowsMpvProfileDelegate()
        : null;

    final localSource = MediaSource(
      id: 'codec_matrix_local',
      label: 'CodecMatrix',
      kind: MediaSourceKind.local,
      location: matrixDir.path,
    );

    final results = <Map<String, Object?>>[];

    /// 运行单组真实压缩视频样本（开启真实硬件画面 vo=gpu-next 与真实音频输出 wasapi/aaudio，严禁 vo=null/ao=null）。
    Future<Map<String, Object?>> runVideoCase({
      required String groupId,
      required String relativePath,
      required bool expectHardwareDecode,
      required bool expectSoftwareFallback,
      String? explicitTargetUrl,
      bool verifyChapters = false,
      bool verifyBig5OpenCc = false,
      bool verifySurroundHotSwitch = false,
      bool verifyExternalAlac = false,
      bool verifyHdr10 = false,
      bool verifyPgsSubtitle = false,
      bool verifyAnamorphic16x9 = false,
      double? seekTargetSeconds,
    }) async {
      final absFile = File(p.join(matrixDir.path, relativePath));
      expect(
        await absFile.exists(),
        isTrue,
        reason: '$groupId 样本文件必须存在：$relativePath',
      );
      final fileSize = await absFile.length();

      final engine = UnifiedPlaybackEngine();
      late final EmbeddedMpvSession session;
      final subEngine = SubtitleMemoryEngine(
        clientSupplier: () => session.activeClient,
        playbackEngine: engine,
      );
      session = EmbeddedMpvSession(
        storageRoot: storageRoot,
        streamBridge: streamBridge,
        desktopSurfaceBridge: winBridge,
        desktopProfileDelegate: desktopDelegate,
        clientFactory: () =>
            FfiLibMpvClient.create(preferredLibraryPath: winDll),
      );
      final firstFrame = Completer<void>();
      final notices = <String>[];
      SubtitleMemoryApplyResult? lastSubApply;
      String? decodedBig5Preview;
      String? convertedScPreview;
      var big5ReplacementChars = -1;

      session.onFileLoaded = () {
        final active = session.activeClient;
        if (active != null && engine.nativeInstanceId != active.handleAddress) {
          engine.beginPhysicalMedia(
            nativeInstanceId: active.handleAddress,
            stage: PlaybackStageKind.video,
          );
          subEngine.resetForPhysicalMediaEpoch(engine.physicalMediaEpoch);
        }
      };
      session.onFirstFrameRendered = () {
        if (!firstFrame.isCompleted) {
          firstFrame.complete();
        }
      };
      session.onNotice = notices.add;
      session.onMountExternalTextSubtitles =
          (textPaths, trackMemory, trackPrefs) async {
            final client = session.activeClient;
            if (client == null || textPaths.isEmpty) return;
            final path = textPaths.first;
            if (verifyBig5OpenCc) {
              final rawBytes = await File(path).readAsBytes();
              final decoded = MultibyteTextDecoder.decodeWithInfo(rawBytes);
              decodedBig5Preview = decoded.text;
              big5ReplacementChars = '\uFFFD'.allMatches(decoded.text).length;
              final processed = SubtitleContentProcessor.process(
                content: decoded.text,
                mode: SubtitleOpenCcMode.toSimplified,
              );
              convertedScPreview = processed.content;
            }
            lastSubApply = await subEngine.applyIntent(
              AuthoritativeSubtitleIntent(
                primary: SubtitleSlotRequest.memory(
                  localFilePath: path,
                  fileName: p.basename(path),
                  openCcMode: verifyBig5OpenCc
                      ? SubtitleOpenCcMode.toSimplified
                      : SubtitleOpenCcMode.none,
                ),
              ),
            );
          };

      AndroidVideoSurfaceController? androidCtrl;
      if (Platform.isAndroid) {
        androidCtrl = AndroidVideoSurfaceController();
        await androidCtrl.syncViewportRect(
          leftPx: 0,
          topPx: 0,
          rightPx: viewportW,
          bottomPx: viewportH,
        );
      }

      try {
        final variant = MediaVariant(
          id: 'var_$groupId',
          episodeId: 'ep_$groupId',
          workId: 'work_matrix',
          sourceId: localSource.id,
          relativePath: explicitTargetUrl ?? relativePath,
          fileName: p.basename(relativePath),
          fileSize: fileSize,
          assetKind: AssetKind.video,
        );

        final watch = Stopwatch()..start();
        await session.initializeAndLoad(
          request: EmbeddedVideoLoadRequest(
            workId: 'work_matrix',
            variant: variant,
            source: explicitTargetUrl == null ? localSource : null,
            initialWidth: viewportW,
            initialHeight: viewportH,
          ),
          qualityConfig: const PlaybackQualityConfig(
            preset: VideoQualityPreset.highFidelity,
            outputPipelineMode: VideoOutputPipelineMode.gpuNextUnderlay,
            hardwareDecode: true,
          ),
          // 保持真实音频后端工作但以低音量输出，避免实机测试噪音干扰。
          initialVolume: 5.0,
          androidSurfaceSupplier: androidCtrl != null
              ? () async => androidCtrl!
              : null,
        );
        if (Platform.isWindows) {
          await session.setWindowsUnderlayViewport(
            leftPx: 0,
            topPx: 0,
            rightPx: viewportW,
            bottomPx: viewportH,
            visible: true,
          );
        }

        final client = session.activeClient;
        expect(client, isNotNull, reason: '$groupId libmpv 客户端必须活跃');
        if (engine.nativeInstanceId != client!.handleAddress) {
          engine.beginPhysicalMedia(
            nativeInstanceId: client.handleAddress,
            stage: PlaybackStageKind.video,
          );
          subEngine.resetForPhysicalMediaEpoch(engine.physicalMediaEpoch);
        }
        final mpvDiagLogs = <String>[];
        String? peakObservedAo;
        String? peakObservedAudioCodec;
        Map<String, Object?>? peakObservedAudioOut;
        final logSub = client.events.listen((e) {
          if (e is MpvLogMessageEvent) {
            final pfx = e.prefix.toLowerCase();
            if (pfx.contains('ao') ||
                pfx.contains('ad') ||
                pfx.contains('audio') ||
                e.level == 'error' ||
                e.level == 'warn') {
              if (mpvDiagLogs.length < 24) {
                mpvDiagLogs.add('[${e.prefix}/${e.level}] ${e.text.trim()}');
              }
            }
          } else if (e is MpvAudioReconfigEvent || e is MpvPlaybackRestartEvent) {
            final aoNow = client.getPropertyString('current-ao') ?? '';
            if (aoNow.isNotEmpty && aoNow != 'null') {
              peakObservedAo = aoNow;
              peakObservedAudioCodec =
                  client.getPropertyString('audio-codec-name') ??
                  client.getPropertyString('audio-codec') ??
                  '';
              peakObservedAudioOut = _readAudioOutParams(client);
            }
          }
        });
        try {
        // 明确验证未启用 vo=null / ao=null 假播放。
        final ttffUs = await _waitFirstRealFrame(client, watch, firstFrame);

        // 持续播放 350ms 采集真实解码帧数、音频输出格式及音轨/字幕挂载结果（确保早于 1.5s 短样本 EOF）。
        await Future<void>.delayed(const Duration(milliseconds: 350));

        // 再次核验解码器参数，采集真实运行态指标。
        final currentVo = client.getPropertyString('current-vo') ?? '';
        final currentAo = client.getPropertyString('current-ao') ?? '';
        final demuxer =
            client.getPropertyString('file-format') ??
            client.getPropertyString('current-demuxer') ??
            '';
        final videoCodec =
            client.getPropertyString('video-format') ??
            client.getPropertyString('video-codec') ??
            '';
        final videoProfile =
            client.getPropertyString('current-tracks/video/codec-profile') ??
            client.getPropertyString('video-params/profile') ??
            '';
        final pixelFormat =
            client.getPropertyString('video-params/pixelformat') ?? '';
        final hwPixelFormat =
            client.getPropertyString('video-params/hw-pixelformat') ?? '';
        final hwdecCurrent = client.getPropertyString('hwdec-current') ?? '';
        final audioCodec =
            client.getPropertyString('audio-codec-name') ??
            client.getPropertyString('audio-codec') ??
            '';
        final videoOutParams = _readVideoOutParams(client);
        final audioOutParams = _readAudioOutParams(client);
        final estimatedFrames =
            client.getPropertyInt64('estimated-frame-number') ?? 0;
        final droppedVo = client.getPropertyInt64('frame-drop-count') ?? 0;
        final delayedVo =
            client.getPropertyInt64('vo-delayed-frame-count') ?? 0;
        final chapterCount = client.getPropertyInt64('chapters') ?? 0;
        final tracks = client.readTrackList();
        final audioTracks = tracks
            .where((t) => t.type == MpvTrackType.audio)
            .toList();
        final subTracks = tracks
            .where((t) => t.type == MpvTrackType.subtitle)
            .toList();

        // 强制核心通用断言（禁止任何 vo=null / ao=null 假跑）。
        expect(
          currentVo,
          isNot(anyOf(isEmpty, equals('null'))),
          reason: '$groupId 必须启用真实硬件画面输出（禁止 vo=null）',
        );
        expect(
          currentAo,
          isNot(anyOf(isEmpty, equals('null'))),
          reason:
              '$groupId 必须启用真实硬件音频输出（禁止 ao=null；vo=$currentVo, hwdec=$hwdecCurrent, pos=${client.getPropertyDouble('time-pos')}, eof=${client.getPropertyFlag('eof-reached')}, codec=$audioCodec, peakAo=$peakObservedAo, peakCodec=$peakObservedAudioCodec, peakOut=$peakObservedAudioOut, logs=${mpvDiagLogs.join(' | ')}）',
        );
        expect(demuxer, isNotEmpty, reason: '$groupId 必须上报真实解复用器');
        expect(videoCodec, isNotEmpty, reason: '$groupId 必须上报真实视频编码格式');
        expect(
          pixelFormat,
          isNotEmpty,
          reason:
              '$groupId 必须上报真实像素格式（vo=$currentVo, hwdec=$hwdecCurrent, codec=$videoCodec, profile=$videoProfile, out=$videoOutParams, notices=$notices, logs=${mpvDiagLogs.join(' | ')}）',
        );
        expect(
          (videoOutParams['w']! as int),
          greaterThan(0),
          reason: '$groupId video-out-params 宽度必须大于 0',
        );
        expect(audioCodec, isNotEmpty, reason: '$groupId 必须上报真实音频编码格式');
        expect(
          (audioOutParams['samplerate']! as int),
          greaterThan(0),
          reason: '$groupId audio-out-params 采样率必须大于 0',
        );
        expect(
          (audioOutParams['channel_count']! as int),
          greaterThan(0),
          reason: '$groupId audio-out-params 声道数必须大于 0',
        );
        expect(
          estimatedFrames,
          greaterThan(0),
          reason: '$groupId decoded_frames 必须大于 0',
        );

        if (expectHardwareDecode) {
          expect(
            hwdecCurrent,
            isNot(anyOf(isEmpty, equals('no'))),
            reason: '$groupId 主力流必须真实命中硬件解码（实得 hwdec=$hwdecCurrent）',
          );
        }
        if (expectSoftwareFallback) {
          expect(
            hwdecCurrent.isEmpty || hwdecCurrent == 'no',
            isTrue,
            reason: '$groupId 高危/非标流必须精准回落软解（实得 hwdec=$hwdecCurrent）',
          );
        }
        if (verifyChapters) {
          expect(
            chapterCount,
            greaterThanOrEqualTo(3),
            reason: '$groupId 必须完整解析 OP/正片/ED 章节',
          );
        }
        if (verifyBig5OpenCc) {
          expect(
            lastSubApply?.applied,
            isTrue,
            reason: 'G05 外挂 Big5 字幕必须通过内存通道挂载成功',
          );
          expect(
            lastSubApply?.primaryDecodedCharset,
            equals(DetectedTextCharset.big5),
            reason: 'G05 外挂字幕必须精准识别为 Big5/CP950',
          );
          expect(
            big5ReplacementChars,
            equals(0),
            reason: 'G05 Big5 解码必须 0 乱码（0xFFFD == 0）',
          );
          expect(
            convertedScPreview,
            contains('电影院里的皇后与头发干干净净'),
            reason: 'G05 OpenCC 繁转简必须准确完成多义消歧',
          );
        }
        if (verifyHdr10) {
          final primaries = (videoOutParams['primaries']! as String)
              .toLowerCase();
          final gamma = (videoOutParams['gamma']! as String).toLowerCase();
          expect(
            primaries,
            contains('2020'),
            reason: 'G09 必须识别 BT.2020 广色域（实得 $primaries）',
          );
          expect(
            gamma,
            anyOf(contains('pq'), contains('2084')),
            reason: 'G09 必须识别 PQ/SMPTE2084 HDR 传递函数（实得 $gamma）',
          );
        }
        if (verifyPgsSubtitle) {
          final hasPgs = subTracks.any(
            (t) => t.codec.toLowerCase().contains('pgs'),
          );
          expect(hasPgs, isTrue, reason: 'G09 必须成功解析内封蓝光 PGS (.sup) 图形字幕');
          final pgsTrack = subTracks.firstWhere(
            (t) => t.codec.toLowerCase().contains('pgs'),
          );
          client.setPropertyString('sid', '${pgsTrack.id}');
          await Future<void>.delayed(const Duration(milliseconds: 120));
        }
        if (verifyAnamorphic16x9) {
          final aspect = (videoOutParams['aspect'] as double?) ?? 0.0;
          final par = (videoOutParams['par'] as double?) ?? 0.0;
          expect(
            aspect,
            closeTo(16.0 / 9.0, 0.04),
            reason: 'G12 720x480 SAR 32:27 必须正确还原为 16:9 DAR（实得 $aspect）',
          );
          expect(
            par,
            closeTo(32.0 / 27.0, 0.04),
            reason: 'G12 像素宽高比 PAR 必须准确为 32/27≈1.185（实得 $par）',
          );
        }

        List<String>? hotSwitchCodecs;
        if (verifySurroundHotSwitch) {
          expect(
            audioTracks.length,
            greaterThanOrEqualTo(3),
            reason: 'G10 必须同时解析 DTS / AC3 / E-AC3 三条环绕音轨',
          );
          hotSwitchCodecs = <String>[];
          for (final track in audioTracks) {
            client.setPropertyString('aid', '${track.id}');
            await Future<void>.delayed(const Duration(milliseconds: 180));
            final activeCodec =
                client.getPropertyString('audio-codec-name') ?? '';
            expect(activeCodec, isNotEmpty);
            hotSwitchCodecs.add(activeCodec);
          }
          expect(
            hotSwitchCodecs.toSet().length,
            greaterThanOrEqualTo(3),
            reason: 'G10 热切必须依次激活 dts / ac3 / eac3 三种编码器',
          );
        }

        bool? externalAlacMounted;
        if (verifyExternalAlac) {
          expect(
            audioTracks.length,
            greaterThanOrEqualTo(2),
            reason: 'G11 必须自动发现并挂载同目录外挂 .m4a (ALAC) 音轨',
          );
          final extTrack = audioTracks.firstWhere(
            (t) => t.isExternal,
            orElse: () => audioTracks.last,
          );
          client.setPropertyString('aid', '${extTrack.id}');
          await Future<void>.delayed(const Duration(milliseconds: 160));
          final switchedCodec =
              client.getPropertyString('audio-codec-name') ?? '';
          expect(switchedCodec.toLowerCase(), contains('alac'));
          externalAlacMounted = true;
        }

        // 执行真实 Seek 并采集恢复耗时。
        final seekRecoveryUs = await _measureSeekRecoveryUs(
          client,
          targetSeconds: seekTargetSeconds ?? 0.8,
        );
        expect(seekRecoveryUs, greaterThan(0));

        return <String, Object?>{
          'group_id': groupId,
          'file': relativePath,
          'file_size_bytes': fileSize,
          'current_vo': currentVo,
          'current_ao': currentAo,
          'demuxer': demuxer,
          'video_codec': videoCodec,
          'video_profile': videoProfile,
          'pixel_format': pixelFormat,
          'hw_pixel_format': hwPixelFormat,
          'hwdec_current': hwdecCurrent,
          'hwdec_safety_fallback_active': session.isUsingSoftwareFallback,
          'video_out_params': videoOutParams,
          'audio_codec': audioCodec,
          'audio_out_params': audioOutParams,
          'ttff_us': ttffUs,
          'decoded_frames': estimatedFrames,
          'vo_delayed_or_dropped_frames': droppedVo + delayedVo,
          'seek_recovery_us': seekRecoveryUs,
          'chapters_count': chapterCount,
          'audio_track_count': audioTracks.length,
          'subtitle_track_count': subTracks.length,
          if (verifyBig5OpenCc) 'big5_replacement_chars': big5ReplacementChars,
          if (verifyBig5OpenCc)
            'big5_opencc_simplified_ok':
                convertedScPreview?.contains('电影院里的皇后与头发干干净净') ?? false,
          if (verifyBig5OpenCc)
            'big5_decoded_sample': decodedBig5Preview?.split('\n').last,
          'surround_hot_switch_codecs': ?hotSwitchCodecs,
          'external_alac_mounted': ?externalAlacMounted,
          if (notices.isNotEmpty) 'notices': notices,
          'passed': true,
        };
        } finally {
          await logSub.cancel();
        }
      } finally {
        await session.dispose();
        await Future<void>.delayed(const Duration(milliseconds: 80));
      }
    }

    // ---------------- 逐组实跑 G01 ~ G12 ----------------
    String pathOf(String groupId, [String key = 'primary']) =>
        (groupsMeta[groupId]! as Map<String, Object?>)[key]! as String;

    // G01：主力 BDRip HEVC Main10 + FLAC 2.0/5.1 + 外挂繁日 ASS + Chapter
    results.add(
      await runVideoCase(
        groupId: 'G01',
        relativePath: pathOf('G01'),
        expectHardwareDecode: true,
        expectSoftwareFallback: false,
        verifyChapters: true,
      ),
    );

    // G02：主力 WEBRip HEVC Main10 + AAC + 内封简繁双 ASS + 内封 TTF
    results.add(
      await runVideoCase(
        groupId: 'G02',
        relativePath: pathOf('G02'),
        expectHardwareDecode: true,
        expectSoftwareFallback: false,
      ),
    );

    // G03：Opus 新番 HEVC Main10 + Opus 2.0/5.1 + 命名 OP/ED 章节
    results.add(
      await runVideoCase(
        groupId: 'G03',
        relativePath: pathOf('G03'),
        expectHardwareDecode: true,
        expectSoftwareFallback: false,
        verifyChapters: true,
      ),
    );

    // G04：8-bit 主力 H.264 High 8-bit + FLAC (MKV) & AAC (MP4)
    results.add(
      await runVideoCase(
        groupId: 'G04_MKV',
        relativePath: pathOf('G04', 'primary'),
        expectHardwareDecode: true,
        expectSoftwareFallback: false,
      ),
    );
    results.add(
      await runVideoCase(
        groupId: 'G04_MP4',
        relativePath: pathOf('G04', 'secondary'),
        expectHardwareDecode: true,
        expectSoftwareFallback: false,
      ),
    );

    // G05：Hi10P 杀手组 + 真实 BIG5 外挂繁中 ASS（验证软解拦截零绿屏 + Big5->简中零乱码）
    results.add(
      await runVideoCase(
        groupId: 'G05',
        relativePath: pathOf('G05'),
        expectHardwareDecode: false,
        expectSoftwareFallback: true,
        verifyBig5OpenCc: true,
      ),
    );

    // G06：2160p 12-bit HEVC Main12 + FLAC（验证 12-bit 软解拦截零花屏）
    results.add(
      await runVideoCase(
        groupId: 'G06',
        relativePath: pathOf('G06'),
        expectHardwareDecode: false,
        expectSoftwareFallback: true,
        seekTargetSeconds: 0.6,
      ),
    );

    // G07：4:4:4 Rext + VFR 24/60fps 混帧 + FLAC（验证 4:4:4 软解拦截与 VFR 跨帧率对齐）
    results.add(
      await runVideoCase(
        groupId: 'G07',
        relativePath: pathOf('G07'),
        expectHardwareDecode: false,
        expectSoftwareFallback: true,
        seekTargetSeconds: 1.2,
      ),
    );

    // G08：AV1 10-bit (MKV+FLAC) & AV1 8-bit (WebM+Opus)（硬解或 dav1d 软解均可）
    results.add(
      await runVideoCase(
        groupId: 'G08_MKV_10BIT',
        relativePath: pathOf('G08', 'primary'),
        expectHardwareDecode: false,
        expectSoftwareFallback: false,
      ),
    );
    results.add(
      await runVideoCase(
        groupId: 'G08_WEBM_8BIT',
        relativePath: pathOf('G08', 'secondary'),
        expectHardwareDecode: false,
        expectSoftwareFallback: false,
      ),
    );

    // G09：4K HDR10 (BT.2020 PQ) + TrueHD + PGS (MKV) 与 M2TS 蓝光容器
    results.add(
      await runVideoCase(
        groupId: 'G09_MKV_HDR10_TRUEHD_PGS',
        relativePath: pathOf('G09', 'primary'),
        expectHardwareDecode: true,
        expectSoftwareFallback: false,
        verifyHdr10: true,
        verifyPgsSubtitle: true,
        seekTargetSeconds: 0.6,
      ),
    );
    results.add(
      await runVideoCase(
        groupId: 'G09_M2TS_HDR10_PGS',
        relativePath: pathOf('G09', 'secondary'),
        expectHardwareDecode: true,
        expectSoftwareFallback: false,
        verifyHdr10: true,
        verifyPgsSubtitle: true,
        seekTargetSeconds: 0.6,
      ),
    );

    // G10：DTS 5.1 + AC3 5.1 + E-AC3 5.1 三音轨无缝热切
    results.add(
      await runVideoCase(
        groupId: 'G10',
        relativePath: pathOf('G10'),
        expectHardwareDecode: true,
        expectSoftwareFallback: false,
        verifySurroundHotSwitch: true,
      ),
    );

    // G11：ALAC 无损内封 + 同目录外挂 .m4a (ALAC) 自动挂载切换
    results.add(
      await runVideoCase(
        groupId: 'G11',
        relativePath: pathOf('G11'),
        expectHardwareDecode: true,
        expectSoftwareFallback: false,
        verifyExternalAlac: true,
      ),
    );

    // G12-A：720x480 非正方像素 SAR 32:27 (DAR 16:9) + AC3/MP3
    results.add(
      await runVideoCase(
        groupId: 'G12_DVD_ANAMORPHIC',
        relativePath: pathOf('G12', 'primary'),
        expectHardwareDecode: true,
        expectSoftwareFallback: false,
        verifyAnamorphic16x9: true,
      ),
    );

    // G12-B：尾部 moov MP4 经 LocalStreamBridge 远程模拟点播（验证首尾 Range 秒开与 DAR 16:9）
    final g12Mp4Rel = pathOf('G12', 'secondary');
    final g12Mp4File = File(p.join(matrixDir.path, g12Mp4Rel));
    final g12Mp4Size = await g12Mp4File.length();
    final countingGw = _CountingRangeGateway(
      LocalSourceGateway(rootPath: matrixDir.path),
      totalFileSize: g12Mp4Size,
    );
    final bridgeReg = await streamBridge.registerSession(
      gateway: countingGw,
      relativePath: g12Mp4Rel,
      fileName: p.basename(g12Mp4Rel),
      knownLength: g12Mp4Size,
      ownsGateway: false,
      sourceKind: MediaSourceKind.webdav,
    );
    try {
      final g12BridgeRes = await runVideoCase(
        groupId: 'G12_TAIL_MOOV_BRIDGE',
        relativePath: g12Mp4Rel,
        explicitTargetUrl: bridgeReg.url.toString(),
        expectHardwareDecode: true,
        expectSoftwareFallback: false,
        verifyAnamorphic16x9: true,
        seekTargetSeconds: 0.4,
      );
      final hitHead = countingGw.requests.any((r) => r.start < 131072);
      final hitTail = countingGw.requests.any(
        (r) => r.start > (g12Mp4Size * 0.70).round(),
      );
      final bytesBeforeTail =
          countingGw.bytesBeforeFirstTailRequest ?? countingGw.totalEmittedBytes;
      final openReadRatio = bytesBeforeTail / g12Mp4Size;
      expect(
        countingGw.requests.length,
        greaterThanOrEqualTo(2),
        reason: 'G12 尾部 moov MP4 必须至少触发首尾两次 Range 请求',
      );
      expect(hitHead, isTrue, reason: 'G12 必须请求文件头部区间');
      expect(hitTail, isTrue, reason: 'G12 必须直接通过尾部 Range 定位 moov 原子');
      expect(
        openReadRatio,
        lessThan(0.45),
        reason:
            'G12 定位尾部 moov 秒开前必须跳过中部数据，严禁顺序读完整文件（尾定位前已读比例=${openReadRatio.toStringAsFixed(3)}）',
      );
      g12BridgeRes['bridge_range_count'] = countingGw.requests.length;
      g12BridgeRes['bridge_hit_head'] = hitHead;
      g12BridgeRes['bridge_hit_tail'] = hitTail;
      g12BridgeRes['bridge_bytes_before_tail_moov'] = bytesBeforeTail;
      g12BridgeRes['bridge_open_read_ratio'] = double.parse(
        openReadRatio.toStringAsFixed(4),
      );
      g12BridgeRes['bridge_total_bytes_served'] = countingGw.totalEmittedBytes;
      results.add(g12BridgeRes);
    } finally {
      await streamBridge.unregisterSession(bridgeReg.token);
    }

    // ---------------- 附测：WavPack (.wv) 与 DSD64 (.dsf) 真实音频输出冒烟 ----------------
    final audioBonusResults = <Map<String, Object?>>[];
    final bonusMeta = groupsMeta['AUDIO_BONUS'] as Map<String, Object?>?;
    if (bonusMeta != null) {
      final mpvDir = await storageRoot.ensureMpvConfigDir();
      for (final key in ['wavpack', 'dsf']) {
        final rel = bonusMeta[key] as String?;
        if (rel == null) continue;
        final absPath = p.join(matrixDir.path, rel);
        final audioClient = FfiLibMpvClient.create(
          preferredLibraryPath: winDll,
        );
        try {
          MpvQualityProfile.applyPreInitAudioOptions(
            audioClient,
            config: const PlaybackQualityConfig(
              preset: VideoQualityPreset.highFidelity,
            ),
            mpvConfigDir: mpvDir,
            isWindowsOverride: Platform.isWindows,
            desktopDelegate: desktopDelegate,
          );
          audioClient.setOptionString('pause', 'no');
          expect(audioClient.initialize(), equals(0));
          audioClient.setPropertyDouble('volume', 5.0);
          final ready = Completer<void>();
          final sub = audioClient.events.listen((e) {
            if (e is MpvPlaybackRestartEvent && !ready.isCompleted) {
              ready.complete();
            }
          });
          try {
            final watch = Stopwatch()..start();
            expect(audioClient.command(['loadfile', absPath, 'replace']), 0);
            await ready.future.timeout(const Duration(seconds: 10));
            watch.stop();
            await Future<void>.delayed(const Duration(milliseconds: 350));
            final ao = audioClient.getPropertyString('current-ao') ?? '';
            final codec =
                audioClient.getPropertyString('audio-codec-name') ?? '';
            final aoParams = _readAudioOutParams(audioClient);
            expect(ao, isNot(anyOf(isEmpty, equals('null'))));
            expect(codec, isNotEmpty);
            expect((aoParams['samplerate']! as int), greaterThan(0));
            audioBonusResults.add({
              'format_key': key,
              'file': rel,
              'current_ao': ao,
              'audio_codec': codec,
              'audio_out_params': aoParams,
              'ttff_us': watch.elapsedMicroseconds,
              'passed': true,
            });
          } finally {
            await sub.cancel();
          }
        } finally {
          await audioClient.dispose();
        }
      }
    }

    // ---------------- 可选只读真实藏品抽样冒烟（严格零写入） ----------------
    const collectionDefine = String.fromEnvironment(
      'KONATA_REAL_COLLECTION_DIR',
    );
    final collectionPath = collectionDefine.trim().isNotEmpty
        ? collectionDefine.trim()
        : (Platform.environment['KONATA_REAL_COLLECTION_DIR'] ?? '').trim();
    final realCollectionSamples = <Map<String, Object?>>[];
    if (collectionPath.isNotEmpty) {
      final collectionDir = Directory(collectionPath);
      if (await collectionDir.exists()) {
        final discovered = <File>[];
        await for (final entity in collectionDir.list(
          recursive: true,
          followLinks: false,
        )) {
          if (entity is File &&
              KonataMediaExtensions.isVideoFile(entity.path)) {
            discovered.add(entity);
            if (discovered.length >= 5) break;
          }
        }
        for (var i = 0; i < discovered.length; i++) {
          final file = discovered[i];
          final session = EmbeddedMpvSession(
            storageRoot: storageRoot,
            streamBridge: streamBridge,
            desktopSurfaceBridge: winBridge,
            desktopProfileDelegate: desktopDelegate,
            clientFactory: () =>
                FfiLibMpvClient.create(preferredLibraryPath: winDll),
          );
          final firstFrame = Completer<void>();
          session.onFirstFrameRendered = () {
            if (!firstFrame.isCompleted) firstFrame.complete();
          };
          AndroidVideoSurfaceController? androidCtrl;
          if (Platform.isAndroid) {
            androidCtrl = AndroidVideoSurfaceController();
            await androidCtrl.syncViewportRect(
              leftPx: 0,
              topPx: 0,
              rightPx: viewportW,
              bottomPx: viewportH,
            );
          }
          try {
            final watch = Stopwatch()..start();
            await session.initializeAndLoad(
              request: EmbeddedVideoLoadRequest(
                workId: 'real_collection_$i',
                variant: MediaVariant(
                  id: 'real_var_$i',
                  episodeId: 'real_ep_$i',
                  workId: 'real_collection_$i',
                  sourceId: 'readonly_collection',
                  relativePath: file.path,
                  fileName: p.basename(file.path),
                  fileSize: await file.length(),
                  assetKind: AssetKind.video,
                ),
                initialWidth: viewportW,
                initialHeight: viewportH,
              ),
              qualityConfig: const PlaybackQualityConfig(
                preset: VideoQualityPreset.highFidelity,
                outputPipelineMode: VideoOutputPipelineMode.gpuNextUnderlay,
                hardwareDecode: true,
              ),
              initialVolume: 5.0,
              androidSurfaceSupplier: androidCtrl != null
                  ? () async => androidCtrl!
                  : null,
            );
            if (Platform.isWindows) {
              await session.setWindowsUnderlayViewport(
                leftPx: 0,
                topPx: 0,
                rightPx: viewportW,
                bottomPx: viewportH,
                visible: true,
              );
            }
            final client = session.activeClient!;
            final ttffUs = await _waitFirstRealFrame(client, watch, firstFrame);
            await Future<void>.delayed(const Duration(milliseconds: 300));
            realCollectionSamples.add({
              'file': p.basename(file.path),
              'current_vo': client.getPropertyString('current-vo') ?? '',
              'current_ao': client.getPropertyString('current-ao') ?? '',
              'demuxer': client.getPropertyString('file-format') ?? '',
              'video_codec': client.getPropertyString('video-format') ?? '',
              'video_profile':
                  client.getPropertyString('video-params/profile') ?? '',
              'pixel_format':
                  client.getPropertyString('video-params/pixelformat') ?? '',
              'hwdec_current': client.getPropertyString('hwdec-current') ?? '',
              'video_out_params': _readVideoOutParams(client),
              'audio_codec':
                  client.getPropertyString('audio-codec-name') ?? '',
              'audio_out_params': _readAudioOutParams(client),
              'ttff_us': ttffUs,
              'decoded_frames':
                  client.getPropertyInt64('estimated-frame-number') ?? 0,
            });
          } finally {
            await session.dispose();
          }
        }
      }
    }

    binding.reportData = <String, Object?>{
      'platform': Platform.operatingSystem,
      'matrix_dir': matrixDir.path,
      'zero_null_vo_ao_verified': true,
      'total_cases': results.length,
      'passed_cases': results.where((r) => r['passed'] == true).length,
      'pass_rate': results.isEmpty
          ? 0.0
          : results.where((r) => r['passed'] == true).length / results.length,
      'groups': results,
      'audio_bonus': audioBonusResults,
      'real_collection_readonly_enabled': collectionPath.isNotEmpty,
      'real_collection_samples': realCollectionSamples,
    };
  });
}
