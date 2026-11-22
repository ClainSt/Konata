import 'dart:async';
import 'dart:io';

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart' show GlobalWidgetsLocalizations;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ccplayer/application/playback/audio_playback_notifier.dart';
import 'package:ccplayer/application/playback/playback_preferences_provider.dart';
import 'package:ccplayer/application/playback/video_playback_controller.dart';
import 'package:ccplayer/application/providers/library_providers.dart';
import 'package:ccplayer/domain/models/episode.dart';
import 'package:ccplayer/domain/models/media_source.dart';
import 'package:ccplayer/domain/models/media_variant.dart';
import 'package:ccplayer/domain/models/work.dart';
import 'package:ccplayer/domain/playback/playback_probe_stats.dart';
import 'package:ccplayer/domain/playback/track_preferences.dart';
import 'package:ccplayer/infrastructure/players/android/android_video_surface_controller.dart';
import 'package:ccplayer/infrastructure/players/embedded_mpv_session.dart';
import 'package:ccplayer/infrastructure/players/libmpv_ffi.dart';
import 'package:ccplayer/infrastructure/players/mpv_quality_profile.dart';
import 'package:ccplayer/infrastructure/players/windows_mpv_profile_adapter.dart';
import 'package:ccplayer/presentation/audio/immersive_audio_page.dart';
import 'package:ccplayer/presentation/audio/mini_audio_bar.dart';
import 'package:ccplayer/presentation/shell/adaptive_capsule_layout.dart';
import 'package:ccplayer/presentation/theme/konata_playback_tokens.dart';
import 'package:ccplayer/presentation/theme/konata_theme.dart';
import 'package:ccplayer/presentation/video/embedded_video_page.dart';
import 'package:ccplayer/presentation/video/video_hardware_surface.dart';
import 'package:ccplayer/presentation/video/video_side_sheet.dart';

class _R3FakeVideoController extends VideoPlaybackController {
  _R3FakeVideoController(
    super.request, {
    bool windowsUnderlay = false,
    String? renderBackend,
    List<ScreenshotCaptureMode>? capturedModes,
  }) : _initialWindowsUnderlay = windowsUnderlay,
       _initialRenderBackend = renderBackend,
       capturedModes = capturedModes ?? <ScreenshotCaptureMode>[],
       super(deferBootstrap: true);

  final bool _initialWindowsUnderlay;
  final String? _initialRenderBackend;
  final List<ScreenshotCaptureMode> capturedModes;
  final List<({int leftPx, int topPx, int rightPx, int bottomPx, double radiusPx, bool visible})>
  windowsUnderlayCalls = [];

  @override
  VideoPlaybackState build() {
    return super.build().copyWith(
      isInitializing: false,
      isBuffering: false,
      hasFirstFrame: true,
      isPlaying: true,
      textureId: _initialWindowsUnderlay ? -1 : 101,
      windowsUnderlayActive: _initialWindowsUnderlay,
      renderBackend: _initialRenderBackend ??
          (_initialWindowsUnderlay ? 'gpu_next' : null),
      durationSeconds: 1440.0,
      positionSeconds: 120.0,
    );
  }

  @override
  Future<void> syncWindowsUnderlayViewport({
    required int leftPx,
    required int topPx,
    required int rightPx,
    required int bottomPx,
    double cornerRadiusPx = 0.0,
    bool visible = true,
  }) async {
    windowsUnderlayCalls.add((
      leftPx: leftPx,
      topPx: topPx,
      rightPx: rightPx,
      bottomPx: bottomPx,
      radiusPx: cornerRadiusPx,
      visible: visible,
    ));
  }

  void enableWindowsUnderlay() {
    state = state.copyWith(
      textureId: -1,
      windowsUnderlayActive: true,
      renderBackend: 'gpu_next',
    );
  }

  @override
  Future<ScreenshotCaptureResult?> captureScreenshot({
    ScreenshotCaptureMode mode = ScreenshotCaptureMode.pureVideo,
  }) async {
    capturedModes.add(mode);
    return ScreenshotCaptureResult(
      mode: mode,
      displayLabel: '相册/Konata/${mode.mpvFlag}.png',
      galleryUri: 'content://media/external/images/media/1',
    );
  }

  @override
  Future<void> closeAndRelease() async {
    state = state.copyWith(isClosing: true);
  }
}

class _R3StaticAudioNotifier extends AudioPlaybackNotifier {
  _R3StaticAudioNotifier(AudioPlaybackState initial)
    : super(initialState: initial);
}

class _R3RecordingOptionClient implements LibMpvClient {
  final Map<String, String> options = <String, String>{};

  @override
  bool isInitialized = false;

  @override
  bool isDisposed = false;

  @override
  int get handleAddress => 1;

  @override
  Stream<MpvClientEvent> get events => const Stream<MpvClientEvent>.empty();

  @override
  String errorString(int code) => 'ok';

  @override
  int setOptionString(String name, String value) {
    options[name] = value;
    return 0;
  }

  @override
  int initialize() {
    isInitialized = true;
    return 0;
  }

  @override
  int command(List<String> args) => 0;

  @override
  int commandAsync(int replyUserdata, List<String> args) => command(args);

  @override
  Future<void> dispose() async {
    isDisposed = true;
  }

  @override
  bool? getPropertyFlag(String name) => null;

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

VideoLaunchRequest _buildR3Request() {
  const work = Work(id: 'w_r3', title: 'R3 渲染与形变测试');
  const ep = Episode(
    id: 'ep_r3_1',
    workId: 'w_r3',
    category: EpisodeCategory.main,
    seasonNumber: 1,
    episodeNumber: 1,
    title: '第一话',
  );
  const src = MediaSource(
    id: 'src_r3',
    label: '本地',
    kind: MediaSourceKind.local,
    location: '/tmp/r3',
  );
  const variant = MediaVariant(
    id: 'var_r3_1',
    workId: 'w_r3',
    episodeId: 'ep_r3_1',
    sourceId: 'src_r3',
    relativePath: 'ep01.mkv',
    fileName: 'ep01.mkv',
    fileSize: 1024,
  );
  const bundle = WorkDetailBundle(
    work: work,
    episodes: [ep],
    variants: [variant],
    sourcesById: {'src_r3': src},
    latestPlayback: null,
  );
  return const VideoLaunchRequest(
    work: work,
    episode: ep,
    variant: variant,
    bundle: bundle,
    source: src,
  );
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('批次 R3：Windows 高色深管线、Android 帧同步挖空、双向弹簧与双模截图回归', () {
    testWidgets(
      '[#6] Android 底层 Underlay 挖空表面在组件测试中真实渲染、禁止 paint 同步直发通道且去重合并脏矩形',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        try {
          tester.view.physicalSize = const Size(1280, 720);
          tester.view.devicePixelRatio = 2.0;
          addTearDown(tester.view.reset);

          final channelCalls = <MethodCall>[];
          const underlayChannel = MethodChannel(
            AndroidVideoSurfaceController.underlayChannelName,
          );
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(underlayChannel, (call) async {
                channelCalls.add(call);
                return null;
              });
          addTearDown(() {
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
                .setMockMethodCallHandler(underlayChannel, null);
          });

          final req = _buildR3Request();
          final radiusNotifier = ValueNotifier<double>(16.0);
          addTearDown(radiusNotifier.dispose);

          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                videoPlaybackProvider(req).overrideWith(
                  () => _R3FakeVideoController(req),
                ),
              ],
              child: MaterialApp(
                theme: KonataTheme.darkTheme(),
                home: Scaffold(
                  body: ValueListenableBuilder<double>(
                    valueListenable: radiusNotifier,
                    builder: (_, r, _) => Align(
                      alignment: Alignment.topLeft,
                      child: SizedBox(
                        width: 320,
                        height: 180,
                        child: KonataHardwareVideoSurface(
                          request: req,
                          miniPreview: true,
                          cornerRadius: r,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );

          // 1. 严禁出现 _isWidgetTest 纯黑占位短路线，必须真实挂载 _AndroidUnderlayCutout。
          expect(
            find.byKey(const ValueKey('android_underlay_cutout_surface')),
            findsOneWidget,
          );
          expect(
            find.byKey(const ValueKey('android_hardware_surface_placeholder')),
            findsNothing,
          );

          // 2. 帧末回调完成后应收到恰好 1 次 show 同步，且包含精确物理像素坐标与圆角半径（16 * 2.0 = 32）。
          await tester.pump();
          final showCalls = channelCalls
              .where((c) => c.method == 'show')
              .toList();
          expect(showCalls, hasLength(1));
          final firstArgs = Map<String, Object?>.from(
            showCalls.first.arguments as Map,
          );
          expect(firstArgs['rightPx'], equals(640));
          expect(firstArgs['bottomPx'], equals(360));
          expect((firstArgs['radiusPx'] as num).toDouble(), closeTo(32.0, 0.1));

          // 3. 未发生脏矩形变更时重复绘制数帧不得产生任何多余通道调用（脏矩形去重）。
          final countBeforeIdle = channelCalls.length;
          await tester.pump(const Duration(milliseconds: 16));
          await tester.pump(const Duration(milliseconds: 16));
          expect(channelCalls.length, equals(countBeforeIdle));

          // 4. 修改圆角半径后仅在下一帧帧末派发 1 次 setRect。
          radiusNotifier.value = 0.0;
          await tester.pump();
          await tester.pump();
          final setRectCalls = channelCalls
              .where((c) => c.method == 'setRect')
              .toList();
          expect(setRectCalls, hasLength(1));
          final updatedArgs = Map<String, Object?>.from(
            setRectCalls.first.arguments as Map,
          );
          expect(
            (updatedArgs['radiusPx'] as num).toDouble(),
            closeTo(0.0, 0.1),
          );

          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );

    testWidgets(
      '[#7] 触屏截图按钮提供「含字幕原画 / 纯净原画」双模胶囊菜单与长按直出含字幕原画',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        try {
          tester.view.physicalSize = const Size(1280, 800);
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.reset);

          final req = _buildR3Request();
          late _R3FakeVideoController fakeCtrl;

          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                videoPlaybackProvider(req).overrideWith(() {
                  fakeCtrl = _R3FakeVideoController(req);
                  return fakeCtrl;
                }),
              ],
              child: MaterialApp(
                theme: KonataTheme.darkTheme(),
                locale: const Locale('zh', 'CN'),
                supportedLocales: const [Locale('zh', 'CN')],
                localizationsDelegates: const [
                  GlobalMaterialLocalizations.delegate,
                  GlobalWidgetsLocalizations.delegate,
                  GlobalCupertinoLocalizations.delegate,
                ],
                home: EmbeddedVideoPage(request: req),
              ),
            ),
          );
          await tester.pumpAndSettle();

          final shotBtn = find.byKey(
            const ValueKey('video_android_screenshot_button'),
          );
          expect(shotBtn, findsOneWidget);

          // 1. 轻触打开双模毛玻璃菜单，选择「含字幕原画」。
          await tester.tap(shotBtn);
          await tester.pumpAndSettle();
          final withSubItem = find.byKey(
            const ValueKey('video_screenshot_mode_with_subtitles'),
          );
          final pureItem = find.byKey(
            const ValueKey('video_screenshot_mode_pure_video'),
          );
          expect(withSubItem, findsOneWidget);
          expect(pureItem, findsOneWidget);

          await tester.tap(withSubItem);
          await tester.pumpAndSettle();
          expect(
            fakeCtrl.capturedModes,
            equals([ScreenshotCaptureMode.withSubtitles]),
          );

          // 2. 再次轻触并选择「纯净原画」。
          await tester.tap(shotBtn);
          await tester.pumpAndSettle();
          await tester.tap(
            find.byKey(const ValueKey('video_screenshot_mode_pure_video')),
          );
          await tester.pumpAndSettle();
          expect(
            fakeCtrl.capturedModes,
            equals([
              ScreenshotCaptureMode.withSubtitles,
              ScreenshotCaptureMode.pureVideo,
            ]),
          );

          // 3. 长按触屏截图按钮直出「含字幕原画」。
          await tester.longPress(shotBtn);
          await tester.pumpAndSettle();
          expect(
            fakeCtrl.capturedModes.last,
            equals(ScreenshotCaptureMode.withSubtitles),
          );

          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );

    testWidgets(
      '[#8] 详情页源卡片 ↔ 全屏音频舞台 ↔ 悬浮小窗双向 SpringSimulation 形变，且收起继承真实下拉初速度绝不瞬移硬切',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        try {
          tester.view.physicalSize = const Size(390, 844);
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.reset);

          const audioWork = Work(id: 'w_r3', title: 'R3 音乐测试');
          const audioSource = MediaSource(
            id: 'src_cd',
            label: '本地',
            kind: MediaSourceKind.local,
            location: '/tmp/r3',
          );
          const audioVariant = MediaVariant(
            id: 'v_r3_cd',
            workId: 'w_r3',
            episodeId: 'ep_cd_r3',
            sourceId: 'src_cd',
            relativePath: 'CD/01.flac',
            fileName: '01.flac',
            fileSize: 2048,
          );
          const audioItem = AudioQueueItem(
            id: 'r3_audio_1',
            work: audioWork,
            variant: audioVariant,
            source: audioSource,
            title: 'OP Theme',
            performer: 'Konata Band',
            albumTitle: 'OST',
            duration: Duration(seconds: 210),
          );
          const activeAudioState = AudioPlaybackState(
            isActive: true,
            isPlaying: true,
            queue: [audioItem],
            currentIndex: 0,
            positionSeconds: 20.0,
            durationSeconds: 210.0,
          );

          final container = ProviderContainer(
            overrides: [
              audioPlaybackProvider.overrideWith(
                () => _R3StaticAudioNotifier(activeAudioState),
              ),
            ],
          );
          addTearDown(container.dispose);

          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: container,
              child: MaterialApp(
                theme: KonataTheme.darkTheme(),
                locale: const Locale('zh', 'CN'),
                supportedLocales: const [Locale('zh', 'CN')],
                localizationsDelegates: const [
                  GlobalMaterialLocalizations.delegate,
                  GlobalWidgetsLocalizations.delegate,
                  GlobalCupertinoLocalizations.delegate,
                ],
                builder: (_, child) => MiniAudioOverlayHost(child: child!),
                home: Scaffold(
                  body: Center(
                    child: Builder(
                      builder: (cardCtx) => GestureDetector(
                        key: const ValueKey('detail_source_card_trigger'),
                        onTap: () {
                          captureStageMorphOriginRect(cardCtx);
                          container
                                  .read(immersiveAudioExpandedProvider.notifier)
                                  .state =
                              true;
                        },
                        child: const SizedBox(
                          width: 180,
                          height: 100,
                          child: ColoredBox(color: Colors.blueGrey),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();

          // 1. 点击详情页源卡片触发展开：应捕获源卡片矩形并启动正向 SpringSimulation。
          await tester.tap(
            find.byKey(const ValueKey('detail_source_card_trigger')),
          );
          await tester.pump();
          expect(container.read(stageMorphOriginRectProvider), isNotNull);

          await tester.pump(const Duration(milliseconds: 48));
          final morphFinder = find.byKey(
            const ValueKey('spring_morph_audio_fullscreen'),
          );
          expect(morphFinder, findsOneWidget);
          final morphState = tester.state<KonataStageMorphFrameState>(
            morphFinder,
          );
          expect(morphState.isTickerActive, isTrue);
          expect(morphState.currentProgress, inExclusiveRange(0.0, 1.0));

          // 展开到达终态后停钟（零闲置 Ticker）。
          await tester.pumpAndSettle();
          expect(morphState.isTickerActive, isFalse);
          expect(morphState.currentProgress, closeTo(1.0, 0.01));

          // 2. 在全屏音频页执行真实向下快速甩动（1400 px/s）：
          // 严禁下一帧直接消失为 SizedBox.shrink()，必须进入反向弹簧并继承非零负向初速度！
          await tester.fling(
            find.byKey(const ValueKey('portrait_cover_stage')),
            const Offset(0, 220),
            1400,
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 48));
          expect(container.read(immersiveAudioExpandedProvider), isFalse);
          expect(morphFinder, findsOneWidget);
          expect(find.byType(ImmersiveAudioPage), findsOneWidget);
          final collapseState = tester.state<KonataStageMorphFrameState>(
            morphFinder,
          );
          expect(collapseState.isTickerActive, isTrue);
          expect(collapseState.lastAppliedNormalizedVelocity, lessThan(-0.1));
          expect(collapseState.currentProgress, inExclusiveRange(0.0, 1.0));

          // 反向弹簧收敛完成后自动停钟卸载全屏层，并展示悬浮小窗。
          await tester.pumpAndSettle();
          expect(find.byType(ImmersiveAudioPage), findsNothing);
          expect(
            find.byKey(const ValueKey('konata_floating_mini_player')),
            findsOneWidget,
          );

          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );

    test(
      '[#5] Windows 高色深 10-bit/FP16 与 vo=gpu-next (libplacebo) 配置选项在真实 libmpv-2.dll 零错误生效',
      () async {
        final tempDir = await Directory.systemTemp.createTemp('konata_r3_mpv_');
        addTearDown(() async {
          if (tempDir.existsSync()) {
            await tempDir.delete(recursive: true);
          }
        });

        // 1. 验证 gpuNextUnderlay 与 legacyTextureFallback 两种配置生成的精确参数集。
        final gpuNextRecorder = _R3RecordingOptionClient();
        MpvQualityProfile.applyPreInitVideoOptions(
          gpuNextRecorder,
          config: const PlaybackQualityConfig(
            outputPipelineMode: VideoOutputPipelineMode.gpuNextUnderlay,
          ),
          mpvConfigDir: tempDir,
          isWindowsOverride: true,
          isAndroidOverride: false,
          desktopUnderlayHwnd: 0x123456,
          desktopDelegate: const WindowsMpvProfileDelegate(),
        );
        expect(gpuNextRecorder.options['wid'], equals('${0x123456}'));
        expect(gpuNextRecorder.options['vo'], equals('gpu-next'));
        expect(gpuNextRecorder.options['gpu-api'], equals('d3d11'));
        expect(gpuNextRecorder.options['gpu-context'], equals('d3d11'));
        expect(
          gpuNextRecorder.options['d3d11-output-format'],
          equals('rgb10_a2'),
        );
        expect(gpuNextRecorder.options['d3d11-flip'], equals('yes'));
        expect(gpuNextRecorder.options['fbo-format'], equals('rgba16hf'));
        expect(gpuNextRecorder.options['target-colorspace-hint'], equals('auto'));

        final shared10BitRecorder = _R3RecordingOptionClient();
        MpvQualityProfile.applyPreInitVideoOptions(
          shared10BitRecorder,
          config: const PlaybackQualityConfig(
            outputPipelineMode: VideoOutputPipelineMode.legacyTextureFallback,
          ),
          mpvConfigDir: tempDir,
          isWindowsOverride: true,
          isAndroidOverride: false,
          desktopDelegate: const WindowsMpvProfileDelegate(),
        );
        expect(shared10BitRecorder.options['vo'], equals('libmpv'));
        expect(shared10BitRecorder.options['fbo-format'], equals('rgb10_a2'));
        expect(
          shared10BitRecorder.options['target-colorspace-hint'],
          equals('auto'),
        );

        final layeredFp16Recorder = _R3RecordingOptionClient();
        MpvQualityProfile.applyPreInitVideoOptions(
          layeredFp16Recorder,
          config: const PlaybackQualityConfig(
            outputPipelineMode: VideoOutputPipelineMode.layeredFp16,
          ),
          mpvConfigDir: tempDir,
          isWindowsOverride: true,
          isAndroidOverride: false,
          desktopDelegate: const WindowsMpvProfileDelegate(),
        );
        expect(layeredFp16Recorder.options['vo'], equals('libmpv'));
        expect(layeredFp16Recorder.options['fbo-format'], equals('rgba16hf'));

        // 2. 在 Windows 主机强制加载真实 native/konata-native/windows/libmpv-2.dll 实测校验参数接受度。
        if (Platform.isWindows) {
          final dllPath = p.join(
            Directory.current.path,
            'native',
            'konata-native',
            'windows',
            'libmpv-2.dll',
          );
          expect(File(dllPath).existsSync(), isTrue);

          final mpv = FfiLibMpvClient.create(preferredLibraryPath: dllPath);
          try {
            expect(mpv.setOptionString('vo', 'gpu-next'), greaterThanOrEqualTo(0));
            expect(mpv.setOptionString('gpu-api', 'd3d11'), greaterThanOrEqualTo(0));
            expect(
              mpv.setOptionString('d3d11-output-format', 'rgb10_a2'),
              greaterThanOrEqualTo(0),
            );
            expect(
              mpv.setOptionString('fbo-format', 'rgba16hf'),
              greaterThanOrEqualTo(0),
            );
            expect(
              mpv.setOptionString('tone-mapping', 'bt.2446a'),
              greaterThanOrEqualTo(0),
            );
            expect(
              mpv.setOptionString('hdr-compute-peak', 'yes'),
              greaterThanOrEqualTo(0),
            );
            expect(
              mpv.setOptionString('target-colorspace-hint', 'auto'),
              greaterThanOrEqualTo(0),
            );
            // 随后回切 libmpv 并完成真实初始化验证。
            expect(mpv.setOptionString('vo', 'libmpv'), greaterThanOrEqualTo(0));
            expect(mpv.initialize(), equals(0));
            expect(mpv.getPropertyString('mpv-version'), isNotEmpty);
          } finally {
            await mpv.dispose();
          }
        }
      },
    );

    testWidgets(
      '[#5] Windows 底层 10-bit 挖空表面（textureId == -1）走 BlendMode.clear 挖空与帧同步 setViewportRect 绝不画黑框，且输出模式持久落盘',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.windows;
        try {
          tester.view.physicalSize = const Size(1280, 720);
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.reset);

          final req = _buildR3Request();
          late _R3FakeVideoController fakeCtrl;
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                videoPlaybackProvider(req).overrideWith(() {
                  fakeCtrl = _R3FakeVideoController(
                    req,
                    windowsUnderlay: true,
                    renderBackend: 'gpu_next',
                  );
                  return fakeCtrl;
                }),
              ],
              child: MaterialApp(
                theme: KonataTheme.darkTheme(),
                home: Scaffold(
                  backgroundColor: Colors.transparent,
                  body: KonataHardwareVideoSurface(
                    request: req,
                    cornerRadius: 12.0,
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();

          expect(
            find.byKey(const ValueKey('windows_underlay_cutout_surface')),
            findsOneWidget,
          );
          expect(fakeCtrl.windowsUnderlayCalls, isNotEmpty);
          final lastCall = fakeCtrl.windowsUnderlayCalls.last;
          expect(lastCall.visible, isTrue);
          expect(lastCall.rightPx - lastCall.leftPx, equals(1280));
          expect(lastCall.bottomPx - lastCall.topPx, equals(720));
          expect(lastCall.radiusPx, closeTo(12.0, 0.5));

          // 验证输出后端偏好经 SharedPreferences 持久化重载不丢失。
          await tester.runAsync(() async {
            final c1 = ProviderContainer(
              overrides: [
                playbackPreferencesProvider.overrideWith(
                  () => PlaybackPreferencesNotifier(
                    enablePersistence: true,
                    desktopDelegate: const WindowsMpvProfileDelegate(),
                  ),
                ),
              ],
            );
            final c2 = ProviderContainer(
              overrides: [
                playbackPreferencesProvider.overrideWith(
                  () => PlaybackPreferencesNotifier(
                    enablePersistence: true,
                    desktopDelegate: const WindowsMpvProfileDelegate(),
                  ),
                ),
              ],
            );
            try {
              await c1
                  .read(playbackPreferencesProvider.notifier)
                  .setOutputPipelineMode(VideoOutputPipelineMode.layered10Bit);
              // 触发第二容器加载已持久化配置。
              c2.read(playbackPreferencesProvider);
              await Future<void>.delayed(const Duration(milliseconds: 40));
              expect(
                c2
                    .read(playbackPreferencesProvider)
                    .qualityConfig
                    .outputPipelineMode,
                equals(VideoOutputPipelineMode.layered10Bit),
              );
            } finally {
              c1.dispose();
              c2.dispose();
            }
          });

          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );

    testWidgets(
      '[#7 & #8] 手机竖屏（width < 540dp）保留毛玻璃双模截图入口，且全屏视频中央下拉收起继承真实释放初速度',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        try {
          tester.view.physicalSize = const Size(390, 844);
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.reset);

          final req = _buildR3Request();
          late _R3FakeVideoController fakeCtrl;
          var collapsedCount = 0;
          final container = ProviderContainer(
            overrides: [
              videoPlaybackProvider(req).overrideWith(() {
                fakeCtrl = _R3FakeVideoController(req);
                return fakeCtrl;
              }),
            ],
          );
          addTearDown(container.dispose);

          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: container,
              child: MaterialApp(
                theme: KonataTheme.darkTheme(),
                locale: const Locale('zh', 'CN'),
                supportedLocales: const [Locale('zh', 'CN')],
                localizationsDelegates: const [
                  GlobalMaterialLocalizations.delegate,
                  GlobalWidgetsLocalizations.delegate,
                  GlobalCupertinoLocalizations.delegate,
                ],
                home: EmbeddedVideoPage(
                  request: req,
                  onCollapseToMini: () => collapsedCount += 1,
                ),
              ),
            ),
          );

          // 1. 手机竖屏 390dp < 540dp：首帧进入有界旋转等待，超时自动挂载全部 HUD 与双模毛玻璃截图入口。
          await tester.pump();
          expect(
            find.byKey(const ValueKey('video_android_screenshot_button')),
            findsNothing,
          );
          await tester.pump(
            KonataPlaybackTokens.portraitRotationFallbackTimeout +
                const Duration(milliseconds: 20),
          );
          await tester.pumpAndSettle();

          final shotBtn = find.byKey(
            const ValueKey('video_android_screenshot_button'),
          );
          expect(shotBtn, findsOneWidget);
          await tester.tap(shotBtn);
          await tester.pumpAndSettle();
          expect(
            find.byKey(const ValueKey('video_screenshot_mode_pure_video')),
            findsOneWidget,
          );
          await tester.tap(
            find.byKey(const ValueKey('video_screenshot_mode_pure_video')),
          );
          await tester.pumpAndSettle();
          expect(fakeCtrl.capturedModes, equals([ScreenshotCaptureMode.pureVideo]));

          // 2. 全屏视频中央非冲突区快速下拉收起，必须将真实释放初速度写入 stageMorphReleaseVelocityProvider。
          await tester.flingFrom(
            const Offset(195, 360),
            const Offset(0, 220),
            1200,
          );
          await tester.pumpAndSettle();
          expect(collapsedCount, equals(1));
          expect(
            container.read(stageMorphReleaseVelocityProvider),
            greaterThan(0.0),
          );

          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );

    testWidgets(
      '[#7] Windows 底栏相机按钮与视频侧栏均提供双模原画截图入口（纯净 S / 带字幕 Shift+S）',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.windows;
        try {
          SharedPreferences.setMockInitialValues({});
          tester.view.physicalSize = const Size(1280, 720);
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.reset);

          final req = _buildR3Request();
          late _R3FakeVideoController fakeCtrl;

          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                videoPlaybackProvider(req).overrideWith(() {
                  fakeCtrl = _R3FakeVideoController(req);
                  return fakeCtrl;
                }),
              ],
              child: MaterialApp(
                theme: KonataTheme.darkTheme(),
                locale: const Locale('zh', 'CN'),
                supportedLocales: const [Locale('zh', 'CN')],
                localizationsDelegates: const [
                  GlobalMaterialLocalizations.delegate,
                  GlobalWidgetsLocalizations.delegate,
                  GlobalCupertinoLocalizations.delegate,
                ],
                home: EmbeddedVideoPage(request: req),
              ),
            ),
          );
          await tester.pumpAndSettle();

          // 1. 点击桌面底栏相机按钮，弹出双模截图菜单并分别验证纯净原画帧与带字幕合成帧。
          final desktopBtn = find.byKey(
            const ValueKey('video_desktop_screenshot_button'),
          );
          expect(desktopBtn, findsOneWidget);
          await tester.tap(desktopBtn);
          await tester.pumpAndSettle();
          expect(find.text('纯净原画帧 (S)'), findsOneWidget);
          expect(find.text('带字幕合成帧 (Shift+S)'), findsOneWidget);
          await tester.tap(
            find.byKey(const ValueKey('video_screenshot_mode_with_subtitles')),
          );
          await tester.pumpAndSettle();
          expect(
            fakeCtrl.capturedModes,
            equals([ScreenshotCaptureMode.withSubtitles]),
          );

          await tester.tap(desktopBtn);
          await tester.pumpAndSettle();
          await tester.tap(
            find.byKey(const ValueKey('video_screenshot_mode_pure_video')),
          );
          await tester.pumpAndSettle();
          expect(
            fakeCtrl.capturedModes,
            equals([
              ScreenshotCaptureMode.withSubtitles,
              ScreenshotCaptureMode.pureVideo,
            ]),
          );

          // 2. 验证视频侧栏画面标签页提供显式双模原画截图按钮。
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                videoPlaybackProvider(req).overrideWith(
                  () => _R3FakeVideoController(
                    req,
                    capturedModes: fakeCtrl.capturedModes,
                  ),
                ),
              ],
              child: MaterialApp(
                theme: KonataTheme.darkTheme(),
                locale: const Locale('zh', 'CN'),
                supportedLocales: const [Locale('zh', 'CN')],
                localizationsDelegates: const [
                  GlobalMaterialLocalizations.delegate,
                  GlobalWidgetsLocalizations.delegate,
                  GlobalCupertinoLocalizations.delegate,
                ],
                home: Scaffold(
                  body: VideoSideSheet(
                    request: req,
                    initialTab: VideoSideSheetTab.video,
                    onClose: () {},
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();

          final sheetPureBtn = find.byKey(
            const ValueKey('video_sheet_screenshot_pure_button'),
          );
          final sheetSubBtn = find.byKey(
            const ValueKey('video_sheet_screenshot_subtitled_button'),
          );
          await tester.scrollUntilVisible(sheetSubBtn, 160);
          await tester.pumpAndSettle();
          expect(sheetPureBtn, findsOneWidget);
          expect(sheetSubBtn, findsOneWidget);
          await tester.tap(sheetPureBtn);
          await tester.tap(sheetSubBtn);
          await tester.pumpAndSettle();
          expect(
            fakeCtrl.capturedModes,
            equals([
              ScreenshotCaptureMode.withSubtitles,
              ScreenshotCaptureMode.pureVideo,
              ScreenshotCaptureMode.pureVideo,
              ScreenshotCaptureMode.withSubtitles,
            ]),
          );

          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );

    testWidgets(
      '[#5] Windows 底层子窗口（gpu_next / DComp）悬浮视频小窗免除 ClipRRect 与外层 RepaintBoundary 挖空阻断',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.windows;
        try {
          tester.view.physicalSize = const Size(1280, 720);
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.reset);

          final req = _buildR3Request();
          final layout = AdaptiveCapsuleLayout(
            size: const Size(1280, 720),
            safe: EdgeInsets.zero,
            android: false,
            miniKind: FloatingMiniPlayerKind.video,
          );

          // 1. windowsUnderlayActive == true 时，小窗禁止包裹 ClipRRect 与外层 RepaintBoundary。
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                videoPlaybackProvider(req).overrideWith(
                  () => _R3FakeVideoController(
                    req,
                    windowsUnderlay: true,
                    renderBackend: 'gpu_next',
                  ),
                ),
              ],
              child: MaterialApp(
                theme: KonataTheme.darkTheme(),
                home: Scaffold(
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
                          cornerRadius: KonataPlaybackTokens.floatingMiniRadius,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
          await tester.pump();

          final miniFinder = find.byKey(
            const ValueKey('konata_floating_mini_player'),
          );
          expect(miniFinder, findsOneWidget);
          final cutoutFinder = find.byKey(
            const ValueKey('windows_underlay_cutout_surface'),
          );
          expect(cutoutFinder, findsOneWidget);
          // 底层挖空表面自身绝不被 ClipRRect 包裹，确保 BlendMode.clear 透明直透；仅同级上层浮层做圆角裁切
          expect(
            find.descendant(
              of: miniFinder,
              matching: find.ancestor(
                of: cutoutFinder,
                matching: find.byType(ClipRRect),
              ),
            ),
            findsNothing,
          );
          expect(
            find.descendant(
              of: find.byType(KonataFloatingMiniPlayer),
              matching: find.ancestor(
                of: miniFinder,
                matching: find.byType(RepaintBoundary),
              ),
            ),
            findsNothing,
          );

          // 2. 兼容共享纹理回退路径（windowsUnderlayActive == false）仍保留圆角裁剪与重绘边界隔离。
          await tester.pumpWidget(
            ProviderScope(
              key: const ValueKey('fallback_texture_scope'),
              overrides: [
                videoPlaybackProvider(req).overrideWith(
                  () => _R3FakeVideoController(
                    req,
                    windowsUnderlay: false,
                    renderBackend: 'd3d11_fp16',
                  ),
                ),
              ],
              child: MaterialApp(
                theme: KonataTheme.darkTheme(),
                home: Scaffold(
                  backgroundColor: Colors.transparent,
                  body: Stack(
                    fit: StackFit.expand,
                    children: [
                      KonataFloatingMiniPlayer(
                        kind: FloatingMiniPlayerKind.video,
                        layout: layout,
                        videoRequest: req,
                        sharedVideoSurface: const SizedBox.expand(),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
          await tester.pump();

          expect(
            find.descendant(of: miniFinder, matching: find.byType(ClipRRect)),
            findsOneWidget,
          );
          expect(
            find.descendant(
              of: find.byType(KonataFloatingMiniPlayer),
              matching: find.ancestor(
                of: miniFinder,
                matching: find.byType(RepaintBoundary),
              ),
            ),
            findsOneWidget,
          );

          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );
  });
}
