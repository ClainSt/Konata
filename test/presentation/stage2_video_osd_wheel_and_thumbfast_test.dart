import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ccplayer/application/playback/video_playback_controller.dart';
import 'package:ccplayer/application/providers/library_providers.dart';
import 'package:ccplayer/domain/models/episode.dart';
import 'package:ccplayer/domain/models/media_source.dart';
import 'package:ccplayer/domain/models/media_variant.dart';
import 'package:ccplayer/domain/models/work.dart';
import 'package:ccplayer/domain/playback/playback_probe_stats.dart';
import 'package:ccplayer/domain/playback/track_preferences.dart';
import 'package:ccplayer/infrastructure/database/drift_library_repository.dart';
import 'package:ccplayer/infrastructure/database/konata_database.dart';
import 'package:ccplayer/infrastructure/players/libmpv_ffi.dart';
import 'package:ccplayer/infrastructure/players/mpv_thumbnail_service.dart';
import 'package:ccplayer/infrastructure/stream_bridge/local_stream_bridge.dart';
import 'package:ccplayer/presentation/theme/konata_playback_tokens.dart';
import 'package:ccplayer/presentation/theme/konata_theme.dart';
import 'package:ccplayer/presentation/video/embedded_video_page.dart';
import 'package:ccplayer/presentation/video/video_probe_overlay.dart';
import 'package:ccplayer/presentation/widgets/playback/konata_osd_stroked_text.dart';
import 'package:ccplayer/presentation/widgets/playback/konata_playback_capsule.dart';

class _FakeThumbLibMpvClient
    implements LibMpvClient, LibMpvSoftwareFrameSource {
  final Map<String, String> options = <String, String>{};
  final List<List<String>> commands = <List<String>>[];
  final StreamController<MpvClientEvent> _events =
      StreamController<MpvClientEvent>.broadcast();
  final StreamController<void> _renderUpdates =
      StreamController<void>.broadcast();

  bool swInitialized = false;
  bool swReleased = false;
  bool pendingFrameReady = true;
  bool holdSeekRestart = false;
  Completer<void>? currentSeekGate;
  Uint8List nextBmpBytes = encodeRgb0ToBmp(
    Uint8List.fromList(List<int>.filled(4 * 4 * 4, 180)),
    4,
    4,
  );

  @override
  bool isInitialized = false;

  @override
  bool isDisposed = false;

  @override
  int get handleAddress => 77;

  @override
  Stream<MpvClientEvent> get events => _events.stream;

  @override
  Stream<void> get softwareRenderUpdates => _renderUpdates.stream;

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
  bool initSoftwareRenderer({int width = 256, int height = 144}) {
    swInitialized = true;
    return true;
  }

  @override
  bool pollSoftwareFrameReady() => pendingFrameReady;

  @override
  Uint8List? renderSoftwareFrameBmp({int width = 256, int height = 144}) {
    return nextBmpBytes;
  }

  @override
  void releaseSoftwareRenderer() {
    swReleased = true;
  }

  @override
  int command(List<String> args) {
    commands.add(List<String>.from(args));
    if (args.isNotEmpty && args.first == 'loadfile') {
      scheduleMicrotask(() {
        if (!_events.isClosed) _events.add(const MpvFileLoadedEvent());
      });
    } else if (args.isNotEmpty && args.first == 'seek') {
      if (holdSeekRestart) {
        currentSeekGate = Completer<void>();
        unawaited(
          currentSeekGate!.future.then((_) {
            if (!_events.isClosed) {
              _events.add(const MpvPlaybackRestartEvent());
            }
          }),
        );
      } else {
        scheduleMicrotask(() {
          if (!_events.isClosed) {
            _events.add(const MpvPlaybackRestartEvent());
          }
        });
      }
    }
    return MpvError.success;
  }

  @override
  int commandAsync(int replyUserdata, List<String> args) => command(args);

  @override
  Future<void> dispose() async {
    isDisposed = true;
    if (!_events.isClosed) await _events.close();
    if (!_renderUpdates.isClosed) await _renderUpdates.close();
  }

  @override
  bool? getPropertyFlag(String name) => false;
  @override
  double? getPropertyDouble(String name) => null;
  @override
  int? getPropertyInt64(String name) => null;
  @override
  String? getPropertyString(String name) => null;
  @override
  int observeProperty(int replyUserdata, String name, int format) => 0;
  @override
  List<MpvAudioDevice> readAudioDeviceList() => const [];
  @override
  List<MpvSeekableRange> readDemuxerSeekableRanges() => const [];
  @override
  List<PlaybackChapter> readChapterList({double? totalDurationSeconds}) =>
      const [];
  @override
  List<MpvTrackInfo> readTrackList() => const [];
  @override
  int requestLogMessages(String minLevel) => 0;
  @override
  int setPropertyDouble(String name, double value) => 0;
  @override
  int setPropertyFlag(String name, bool value) => 0;
  @override
  int setPropertyInt64(String name, int value) => 0;
  @override
  int setPropertyString(String name, String value) => 0;
}

class _FakeVideoController extends VideoPlaybackController {
  _FakeVideoController(super.ref, super.request);

  void forceState(VideoPlaybackState next) {
    state = next;
  }
}

Future<void> _sendMouseScroll(
  WidgetTester tester,
  TestPointer pointer,
  Offset location,
  Offset scrollDelta,
) async {
  await tester.sendEventToBinding(pointer.hover(location));
  await tester.pump();
  await tester.sendEventToBinding(pointer.scroll(scrollDelta));
}

void main() {
  group('阶段 2：纯文字描边探针、全画布滚轮调音、菱形章节点与 thumbfast 缩略图验证', () {
    testWidgets('VideoProbeOverlay 无背景框/模糊遮罩且外包 IgnorePointer 与描边文字', (
      tester,
    ) async {
      const stats = PlaybackProbeStats(
        mpvVersion: 'mpv 0.40.0',
        ffmpegVersion: 'ffmpeg 7.1',
        voBackend: 'libmpv',
        hwdecCurrent: 'd3d11va',
        videoCodec: 'hevc',
        videoProfile: 'Main 10',
        videoPixelFormat: 'yuv420p10le',
        videoWidth: 1920,
        videoHeight: 1080,
        targetWidth: 2560,
        targetHeight: 1440,
        containerFormat: 'matroska',
        containerFps: 23.976,
        displayFps: 144.0,
        audioCodec: 'flac',
        audioSampleRateHz: 48000,
        audioChannelCount: 2,
        demuxerCacheSeconds: 18.4,
        demuxerCacheBytes: 12 * 1024 * 1024,
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: KonataTheme.darkTheme(),
          home: const Scaffold(
            body: VideoProbeOverlay(
              stats: stats,
              adapterName: 'NVIDIA RTX 4080',
              renderBackend: 'd3d11',
            ),
          ),
        ),
      );

      final overlayFinder = find.byType(VideoProbeOverlay);
      expect(
        find.descendant(of: overlayFinder, matching: find.byType(BackdropFilter)),
        findsNothing,
      );
      expect(
        find.descendant(of: overlayFinder, matching: find.byType(ClipRRect)),
        findsNothing,
      );
      expect(
        find.descendant(of: overlayFinder, matching: find.byType(IgnorePointer)),
        findsOneWidget,
      );

      final strokedWidgets = tester
          .widgetList<KonataOsdStrokedText>(
            find.descendant(
              of: overlayFinder,
              matching: find.byType(KonataOsdStrokedText),
            ),
          )
          .toList();
      expect(strokedWidgets, isNotEmpty);
      expect(
        find.descendant(
          of: find.byType(KonataOsdStrokedText).first,
          matching: find.byType(RepaintBoundary),
        ),
        findsOneWidget,
      );

      final firstTexts = tester
          .widgetList<Text>(
            find.descendant(
              of: find.byType(KonataOsdStrokedText).first,
              matching: find.byType(Text),
            ),
          )
          .toList();
      expect(firstTexts.length, 2);
      expect(
        firstTexts.first.style?.foreground?.style,
        PaintingStyle.stroke,
      );
      expect(
        firstTexts.first.style?.foreground?.strokeWidth,
        closeTo(KonataPlaybackTokens.osdStrokeWidth, 0.001),
      );
      expect(
        firstTexts.last.style?.fontFeatures,
        KonataPlaybackTokens.tabularNumbers,
      );
    });

    test('MpvQualityProfile 与 MpvThumbnailService 落实强约束参数、分桶缓存与 Latest-Wins 单并发队列', () async {
      final createdClients = <_FakeThumbLibMpvClient>[];
      final service = MpvThumbnailService(
        streamBridge: LocalStreamBridge(),
        clientFactory: () {
          final c = _FakeThumbLibMpvClient();
          c.holdSeekRestart = true;
          createdClients.add(c);
          return c;
        },
      );

      const variant = MediaVariant(
        id: 'v1',
        workId: 'w1',
        episodeId: 'e1',
        sourceId: 's1',
        relativePath: 'BDMV/EP01.mkv',
        fileName: 'EP01.mkv',
        fileSize: 1024000,
      );

      await service.warmUp(
        variant: variant,
        source: null,
        durationSeconds: 1440,
      );
      expect(createdClients.length, 1);
      final client = createdClients.first;

      // 校验 14 项远程剥离与微缓冲参数
      expect(client.options['aid'], 'no');
      expect(client.options['sid'], 'no');
      expect(client.options['embeddedfonts'], 'no');
      expect(client.options['sub-auto'], 'no');
      expect(client.options['hr-seek'], 'no');
      expect(client.options['vd-lavc-fast'], 'yes');
      expect(client.options['vd-lavc-skiploopfilter'], 'all');
      expect(client.options['glsl-shaders'], '');
      expect(client.options['deband'], 'no');
      expect(client.options['scale'], 'bilinear');
      expect(client.options['cache'], 'no');
      expect(client.options['demuxer-readahead-secs'], '0');
      expect(client.options['demuxer-max-bytes'], '524288');
      expect(client.options['stream-buffer-size'], '65536');

      // 校验远程 WebDAV 5s 时间桶与本地 1s 时间桶量化
      expect(
        ThumbnailBucketCache.quantizeBucketSeconds(12.2, isRemote: false),
        12.0,
      );
      expect(
        ThumbnailBucketCache.quantizeBucketSeconds(12.2, isRemote: true),
        10.0,
      );
      expect(
        ThumbnailBucketCache.quantizeBucketSeconds(13.0, isRemote: true),
        15.0,
      );

      // 校验 Latest-Wins 单并发：10s 抽取尚未完成时连续划过 30s -> 45s -> 75s，
      // 最终只执行 10s 与 75s，严禁重复调用 loadfile。
      service.requestPreview(10.0);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      service.requestPreview(30.0);
      service.requestPreview(45.0);
      service.requestPreview(75.0);
      expect(service.pendingUserBucket, 75.0);

      client.currentSeekGate?.complete();
      await Future<void>.delayed(const Duration(milliseconds: 15));
      client.currentSeekGate?.complete();
      await Future<void>.delayed(const Duration(milliseconds: 15));

      final loadCount =
          client.commands.where((cmd) => cmd.first == 'loadfile').length;
      final seekTargets = client.commands
          .where((cmd) => cmd.first == 'seek')
          .map((cmd) => cmd[1])
          .toList();
      expect(loadCount, 1);
      expect(seekTargets, ['10.000', '75.000']);
      expect(service.resolvePreviewFrame(75.0), isNotNull);
      // 尚未缓存的时间点返回邻近缓存帧防闪烁
      expect(service.resolvePreviewFrame(70.0), isNotNull);

      await service.release();
      expect(client.swReleased, isTrue);
      expect(client.isDisposed, isTrue);
      service.dispose();
    });

    testWidgets('KonataPlaybackCapsule 展示 45° 菱形章节点与 16:9 缩略图悬浮预览气泡', (
      tester,
    ) async {
      final validBmp = encodeRgb0ToBmp(
        Uint8List.fromList(List<int>.filled(16 * 9 * 4, 210)),
        16,
        9,
      );
      final revision = ValueNotifier<int>(0);
      addTearDown(revision.dispose);

      const chapters = [
        PlaybackChapter(index: 0, title: 'Opening', startSeconds: 0),
        PlaybackChapter(index: 1, title: 'Part A', startSeconds: 90),
        PlaybackChapter(index: 2, title: 'Ending', startSeconds: 1200),
      ];

      await tester.pumpWidget(
        MaterialApp(
          theme: KonataTheme.darkTheme(),
          home: Scaffold(
            body: Center(
              child: KonataPlaybackCapsule(
                title: '第 01 话',
                positionSeconds: 120,
                durationSeconds: 1440,
                isPlaying: true,
                onTogglePlayPause: () {},
                onSeek: (_) {},
                chapters: chapters,
                supportsThumbnailPreview: true,
                previewRevisionListenable: revision,
                previewThumbnailResolver: (_) => validBmp,
              ),
            ),
          ),
        ),
      );

      // 两个非零章节点均渲染 45° 旋转菱形标记（起始 0s 不渲染多余标记）
      final d0 = find.byKey(const ValueKey('konata_chapter_diamond_0'));
      final d1 = find.byKey(const ValueKey('konata_chapter_diamond_1'));
      final d2 = find.byKey(const ValueKey('konata_chapter_diamond_2'));
      expect(d0, findsNothing);
      expect(d1, findsOneWidget);
      expect(d2, findsOneWidget);

      final d1Transform = tester.widget<Transform>(
        find.descendant(of: d1, matching: find.byType(Transform)),
      );
      expect(
        d1Transform.transform.entry(0, 0),
        closeTo(math.cos(math.pi / 4), 0.001),
      );
      final restDiamondSize = tester.getSize(
        find.descendant(of: d1, matching: find.byType(AnimatedContainer)),
      );
      expect(
        restDiamondSize.width,
        closeTo(KonataPlaybackTokens.chapterDiamondRestSize, 0.1),
      );

      // 悬停进度条后菱形放大且弹出 16:9 圆角缩略图 + 章节标题 + 等宽时间戳
      final capsuleBox = tester.getRect(find.byType(KonataPlaybackCapsule));
      final hoverTarget = Offset(
        capsuleBox.left + 120,
        capsuleBox.bottom -
            KonataPlaybackTokens.capsuleProgressBottomInset -
            KonataPlaybackTokens.capsuleProgressRestHeight * 0.5,
      );
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      await tester.pump();
      await mouse.moveTo(hoverTarget);
      await tester.pumpAndSettle();

      final hoverDiamondSize = tester.getSize(
        find.descendant(of: d1, matching: find.byType(AnimatedContainer)),
      );
      expect(hoverDiamondSize.width, greaterThan(restDiamondSize.width));

      expect(find.byType(Image), findsOneWidget);
      final imgSize = tester.getSize(find.byType(Image));
      expect(imgSize.width / imgSize.height, closeTo(16 / 9, 0.02));
      expect(find.textContaining('Part A'), findsOneWidget);
    });

    testWidgets('EmbeddedVideoPage 全画布滚轮调节音量、显示纯文字描边 OSD 并自动淡出', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      final db = KonataDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final repo = DriftLibraryRepository(db);

      const work = Work(
        id: 'w1',
        title: '测试动画',
      );
      const ep = Episode(
        id: 'e1',
        workId: 'w1',
        category: EpisodeCategory.main,
        seasonNumber: 1,
        episodeNumber: 1,
        title: '第一话',
      );
      const variant = MediaVariant(
        id: 'v1',
        workId: 'w1',
        episodeId: 'e1',
        sourceId: 's1',
        relativePath: 'anime/01.mkv',
        fileName: '01.mkv',
        fileSize: 1024,
      );
      const bundle = WorkDetailBundle(
        work: work,
        episodes: [ep],
        variants: [variant],
        sourcesById: {
          's1': MediaSource(
            id: 's1',
            label: 'Local',
            kind: MediaSourceKind.local,
            location: 'D:/Anime',
          ),
        },
        latestPlayback: null,
        playbackByEpisodeId: {},
      );
      const req = VideoLaunchRequest(
        work: work,
        episode: ep,
        variant: variant,
        bundle: bundle,
      );

      late _FakeVideoController fakeCtrl;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            libraryRepositoryProvider.overrideWithValue(repo),
            videoPlaybackProvider(req).overrideWith((ref) {
              fakeCtrl = _FakeVideoController(ref, req);
              fakeCtrl.forceState(
                const VideoPlaybackState(
                  isInitializing: false,
                  isBuffering: false,
                  hasFirstFrame: true,
                  isPlaying: true,
                  currentEpisode: ep,
                  currentVariant: variant,
                  volume: 50.0,
                  durationSeconds: 1440.0,
                ),
              );
              return fakeCtrl;
            }),
          ],
          child: MaterialApp(
            theme: KonataTheme.darkTheme(),
            home: const EmbeddedVideoPage(request: req),
          ),
        ),
      );
      await tester.pump();

      final pointer = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(pointer.addPointer(location: Offset.zero));
      addTearDown(() async {
        await tester.sendEventToBinding(pointer.removePointer());
      });

      // 在视频画面中心向上滚动滑轮（dy < 0 => 音量 +1%）
      await _sendMouseScroll(
        tester,
        pointer,
        const Offset(640, 360),
        const Offset(0, -120),
      );
      await tester.pump();

      expect(fakeCtrl.state.volume, closeTo(51.0, 0.1));
      expect(find.text('音量 51%'), findsWidgets);

      // 打开右侧选集抽屉后，滚动侧栏不触发视频画布滚轮调音
      fakeCtrl.forceState(fakeCtrl.state.copyWith(sideSheetOpen: true));
      await tester.pump();
      await _sendMouseScroll(
        tester,
        pointer,
        const Offset(1100, 360),
        const Offset(0, -120),
      );
      await tester.pump();
      expect(fakeCtrl.state.volume, closeTo(51.0, 0.1));
      fakeCtrl.forceState(fakeCtrl.state.copyWith(sideSheetOpen: false));
      await tester.pump();

      // 超过 1.2s 后瞬时音量 OSD 自动淡出
      await tester.pump(const Duration(milliseconds: 1300));
      await tester.pumpAndSettle();
      final opacityWidget = tester.widget<AnimatedOpacity>(
        find
            .ancestor(
              of: find.text('音量 51%'),
              matching: find.byType(AnimatedOpacity),
            )
            .first,
      );
      expect(opacityWidget.opacity, 0.0);
    });
  });
}
