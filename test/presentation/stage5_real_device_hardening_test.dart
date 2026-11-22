import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show PointerDeviceKind;

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ccplayer/application/playback/audio_playback_notifier.dart';
import 'package:ccplayer/application/playback/video_playback_controller.dart';
import 'package:ccplayer/application/providers/artwork_provider.dart';
import 'package:ccplayer/application/providers/library_providers.dart';
import 'package:ccplayer/application/providers/theme_providers.dart';
import 'package:ccplayer/composition/windows_composition_root.dart';
import 'package:ccplayer/domain/models/episode.dart';
import 'package:ccplayer/domain/models/media_source.dart';
import 'package:ccplayer/domain/models/media_variant.dart';
import 'package:ccplayer/domain/models/tmdb_models.dart';
import 'package:ccplayer/domain/models/work.dart';
import 'package:ccplayer/domain/playback/playback_probe_stats.dart';
import 'package:ccplayer/domain/playback/track_preferences.dart';
import 'package:ccplayer/infrastructure/database/drift_library_repository.dart';
import 'package:ccplayer/infrastructure/database/konata_database.dart';
import 'package:ccplayer/infrastructure/players/embedded_mpv_session.dart';
import 'package:ccplayer/infrastructure/players/libmpv_ffi.dart';
import 'package:ccplayer/infrastructure/players/mpv_thumbnail_service.dart';
import 'package:ccplayer/infrastructure/storage/storage_root_provider.dart';
import 'package:ccplayer/infrastructure/stream_bridge/local_stream_bridge.dart';
import 'package:ccplayer/presentation/audio/mini_audio_bar.dart';
import 'package:ccplayer/presentation/library/review_dialog.dart';
import 'package:ccplayer/presentation/library/review_work_item_card.dart';
import 'package:ccplayer/presentation/shell/desktop_shell.dart';
import 'package:ccplayer/presentation/theme/konata_palette.dart';
import 'package:ccplayer/presentation/theme/konata_playback_tokens.dart';
import 'package:ccplayer/presentation/theme/konata_theme.dart';
import 'package:ccplayer/presentation/video/embedded_video_page.dart';
import 'package:ccplayer/presentation/video/video_side_sheet.dart';
import 'package:ccplayer/presentation/widgets/design_system/konata_glass_dialog.dart';
import 'package:ccplayer/presentation/widgets/playback/konata_playback_capsule.dart';

final Uint8List _tinyPng = Uint8List.fromList([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

double _srgbToLinear(int channel) {
  final c = channel / 255.0;
  return c <= 0.03928 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
}

double _relativeLuminance(Color c) {
  final r = _srgbToLinear((c.r * 255.0).round().clamp(0, 255));
  final g = _srgbToLinear((c.g * 255.0).round().clamp(0, 255));
  final b = _srgbToLinear((c.b * 255.0).round().clamp(0, 255));
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

Color _alphaComposite(Color fg, Color opaqueBackdrop) {
  final a = fg.a;
  final r = ((fg.r * a + opaqueBackdrop.r * (1.0 - a)) * 255.0).round().clamp(0, 255);
  final g = ((fg.g * a + opaqueBackdrop.g * (1.0 - a)) * 255.0).round().clamp(0, 255);
  final b = ((fg.b * a + opaqueBackdrop.b * (1.0 - a)) * 255.0).round().clamp(0, 255);
  return Color.fromARGB(255, r, g, b);
}

double _wcagContrastRatio(Color a, Color b) {
  final la = _relativeLuminance(a);
  final lb = _relativeLuminance(b);
  final lighter = math.max(la, lb);
  final darker = math.min(la, lb);
  return (lighter + 0.05) / (darker + 0.05);
}

class _FakeSwThumbClient implements LibMpvClient, LibMpvSoftwareFrameSource {
  final Map<String, String> options = {};
  final List<({int w, int h})> initSizes = [];
  final List<({int w, int h})> renderSizes = [];
  final StreamController<MpvClientEvent> _events =
      StreamController<MpvClientEvent>.broadcast();
  final StreamController<void> _renderUpdates =
      StreamController<void>.broadcast();

  @override
  bool isInitialized = false;

  @override
  bool isDisposed = false;

  @override
  int get handleAddress => 88;

  @override
  Stream<MpvClientEvent> get events => _events.stream;

  @override
  Stream<void> get softwareRenderUpdates => _renderUpdates.stream;

  @override
  String errorString(int code) => 'err($code)';

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
  bool initSoftwareRenderer({int width = 192, int height = 108}) {
    initSizes.add((w: width, h: height));
    return true;
  }

  @override
  bool pollSoftwareFrameReady() => true;

  @override
  Uint8List? renderSoftwareFrameBmp({int width = 192, int height = 108}) {
    renderSizes.add((w: width, h: height));
    return Uint8List.fromList([1, 2, 3, 4]);
  }

  @override
  void releaseSoftwareRenderer() {}

  @override
  int command(List<String> args) {
    if (args.isNotEmpty && args.first == 'loadfile') {
      scheduleMicrotask(() {
        if (!_events.isClosed) _events.add(const MpvFileLoadedEvent());
      });
    } else if (args.isNotEmpty && args.first == 'seek') {
      scheduleMicrotask(() {
        if (!_events.isClosed) _events.add(const MpvPlaybackRestartEvent());
      });
    }
    return 0;
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
  double? getPropertyDouble(String name) => 0.0;
  @override
  int? getPropertyInt64(String name) => 0;
  @override
  String? getPropertyString(String name) => '';
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

class _StubAudioNotifier extends AudioPlaybackNotifier {
  _StubAudioNotifier(AudioPlaybackState initial) : super(initialState: initial);
}

class _FakeVideoClient implements LibMpvClient {
  final StreamController<MpvClientEvent> _events =
      StreamController<MpvClientEvent>.broadcast();

  @override
  bool isInitialized = false;
  @override
  bool isDisposed = false;
  @override
  int get handleAddress => 55;
  @override
  Stream<MpvClientEvent> get events => _events.stream;
  @override
  String errorString(int code) => 'err($code)';
  @override
  int setOptionString(String name, String value) => 0;
  @override
  int initialize() {
    isInitialized = true;
    return 0;
  }

  @override
  int command(List<String> args) {
    if (args.isNotEmpty && args.first == 'loadfile') {
      scheduleMicrotask(() {
        if (!_events.isClosed) {
          _events.add(const MpvFileLoadedEvent());
          _events.add(const MpvPlaybackRestartEvent());
        }
      });
    }
    return 0;
  }

  @override
  int commandAsync(int replyUserdata, List<String> args) => command(args);

  @override
  Future<void> dispose() async {
    isDisposed = true;
    if (!_events.isClosed) await _events.close();
  }

  @override
  bool? getPropertyFlag(String name) => false;
  @override
  double? getPropertyDouble(String name) => 60.0;
  @override
  int? getPropertyInt64(String name) => 0;
  @override
  String? getPropertyString(String name) => '';
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

void main() {
  group('实机走查 5 项问题收口回归测试', () {
    test(
      '1. 缩略图预热配置包含 hwdec=no 与 keepaspect=no，渲染宽高严格 4 像素对齐且零 1x1 奇数调用',
      () async {
        expect(KonataPlaybackTokens.thumbnailDecodeWidth, 192);
        expect(KonataPlaybackTokens.thumbnailDecodeHeight, 108);
        expect(KonataPlaybackTokens.thumbnailDecodeWidth % 4, 0);
        expect(KonataPlaybackTokens.thumbnailDecodeHeight % 4, 0);

        expect(LibMpvSoftwareFrameSource.alignDimension(1), 16);
        expect(LibMpvSoftwareFrameSource.alignDimension(193), 192);
        expect(LibMpvSoftwareFrameSource.alignDimension(109), 108);
        expect(LibMpvSoftwareFrameSource.alignDimension(192), 192);

        final fake = _FakeSwThumbClient();
        final tempDir = await Directory.systemTemp.createTemp('konata_stage5_sw_');
        addTearDown(() async {
          if (tempDir.existsSync()) await tempDir.delete(recursive: true);
        });
        final storage = StorageRootService(overrideRoot: tempDir);
        final bridge = LocalStreamBridge(storageRoot: storage);
        final service = MpvThumbnailService(
          streamBridge: bridge,
          clientFactory: () => fake,
          decodeWidth: 193, // 故意传入奇数验证强制对齐
          decodeHeight: 109,
        );
        addTearDown(() async => service.release());

        await service.warmUp(
          variant: const MediaVariant(
            id: 'v1',
            workId: 'w1',
            sourceId: 's1',
            relativePath: 'ep01.mkv',
            fileName: 'ep01.mkv',
            fileSize: 1024,
          ),
        );

        expect(fake.options['hwdec'], 'no');
        expect(fake.options['keepaspect'], 'no');
        expect(fake.initSizes, [(w: 192, h: 108)]);

        service.requestPreview(12.0);
        await Future<void>.delayed(const Duration(milliseconds: 40));

        expect(fake.renderSizes, isNotEmpty);
        for (final sz in fake.renderSizes) {
          expect(sz.w % 4, 0);
          expect(sz.h % 4, 0);
          expect(sz.w, greaterThanOrEqualTo(16));
          expect(sz.h, greaterThanOrEqualTo(16));
          expect(sz.w == 1 && sz.h == 1, isFalse);
        }
      },
    );

    testWidgets(
      '2. 脱离 Scaffold 的播控胶囊与悬浮小窗保持 TextDecoration.none 零黄双下划线且采用内嵌底置滑轨',
      (tester) async {
        tester.view.physicalSize = const Size(1024, 720);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);

        expect(KonataPlaybackTokens.osdSurfaceDark, const Color(0x8810131C));
        expect(KonataPlaybackTokens.osdBorderLight, const Color(0x2BFFFFFF));

        const work = Work(id: 'w1', title: '孤独摇滚！');
        const variant = MediaVariant(
          id: 'v1',
          workId: 'w1',
          sourceId: 's1',
          relativePath: '01.flac',
          fileName: '01.flac',
          fileSize: 1000,
          assetKind: AssetKind.cdAlbum,
        );
        const queue = [
          AudioQueueItem(
            id: 'q1',
            work: work,
            variant: variant,
            title: 'Seishun Complex',
            performer: 'Kessoku Band',
            duration: Duration(seconds: 200),
          ),
        ];

        // 故意不使用 Scaffold，直接放在 MaterialApp(home: Stack) 模拟顶层 Overlay 环境
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              tmdbImageLoaderProvider.overrideWithValue(
                (_, {targetWidth, imageSize}) async => _tinyPng,
              ),
              audioPlaybackProvider.overrideWith(
                () => _StubAudioNotifier(
                  const AudioPlaybackState(
                    isActive: true,
                    isPlaying: true,
                    queue: queue,
                    currentIndex: 0,
                    positionSeconds: 40.0,
                    durationSeconds: 200.0,
                    volume: 100.0,
                    audioCodecLabel: 'FLAC',
                  ),
                ),
              ),
            ],
            child: MaterialApp(
              theme: KonataTheme.darkTheme(),
              locale: const Locale('zh', 'CN'),
              supportedLocales: const [Locale('zh', 'CN')],
              localizationsDelegates: GlobalMaterialLocalizations.delegates,
              home: Stack(
                children: [
                  Align(
                    alignment: Alignment.bottomCenter,
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 18),
                      child: Material(
                        type: MaterialType.transparency,
                        child: DefaultTextStyle.merge(
                          style: const TextStyle(
                            decoration: TextDecoration.none,
                          ),
                          child: KonataPlaybackCapsule(
                            title: 'Seishun Complex',
                            positionSeconds: 40.0,
                            durationSeconds: 200.0,
                            isPlaying: true,
                            onTogglePlayPause: () {},
                            onSeek: (_) {},
                          ),
                        ),
                      ),
                    ),
                  ),
                  const Align(
                    alignment: Alignment.topRight,
                    child: KonataFloatingMiniPlayer.standalone(
                      kind: FloatingMiniPlayerKind.audio,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.pump();

        void assertAllTextsNoUnderline(String stageLabel) {
          for (final element in find.byType(Text).evaluate()) {
            final textWidget = element.widget as Text;
            final inheritedStyle = DefaultTextStyle.of(element).style;
            final effectiveStyle = inheritedStyle.merge(textWidget.style);
            expect(
              effectiveStyle.decoration,
              isNot(TextDecoration.underline),
              reason: '$stageLabel 中文本 "${textWidget.data}" 不应出现 underline',
            );
            expect(
              effectiveStyle.decoration,
              isNot(TextDecoration.combine([TextDecoration.underline])),
            );
            expect(
              Material.maybeOf(element),
              isNotNull,
              reason: '$stageLabel 中文本 "${textWidget.data}" 必须拥有 Material 祖先',
            );
          }
        }

        assertAllTextsNoUnderline('播控胶囊与悬浮小窗');

        final capsuleRect = tester.getRect(find.byType(KonataPlaybackCapsule));
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(
          location: Offset(capsuleRect.center.dx, capsuleRect.top + 6),
        );
        addTearDown(mouse.removePointer);
        await tester.pump();
        assertAllTextsNoUnderline('进度条悬停时间气泡');
        await mouse.moveTo(Offset.zero);
        await tester.pump();
      },
    );

    testWidgets(
      '3. 浅色全局主题下 VideoSideSheet 锁定深色卡片外观，且 KonataPalette.dark 四类彩色徽章叠中灰对比度 >= 4.5:1',
      (tester) async {
        // 验证 KonataPalette.dark 四类语义徽章叠在中灰(#808080)毛玻璃上的 WCAG 对比度
        const midGreyBackdrop = Color(0xFF808080);
        final badges = [
          ('successBadge', KonataPalette.dark.successBadge),
          ('accentBadge', KonataPalette.dark.accentBadge),
          ('warningBadge', KonataPalette.dark.warningBadge),
          ('dangerBadge', KonataPalette.dark.dangerBadge),
        ];
        for (final entry in badges) {
          final compositedBg = _alphaComposite(entry.$2.bg, midGreyBackdrop);
          final contrast = _wcagContrastRatio(entry.$2.fg, compositedBg);
          expect(
            contrast,
            greaterThanOrEqualTo(4.5),
            reason: '${entry.$1} 叠中灰对比度应 >= 4.5:1，当前为 ${contrast.toStringAsFixed(2)}',
          );
        }

        // 在全局亮色 ThemeMode.light 下打开 EmbeddedVideoPage 与 VideoSideSheet，必须锁定深色作用域
        SharedPreferences.setMockInitialValues({});
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);

        debugDefaultTargetPlatformOverride = TargetPlatform.windows;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        const d3d11Channel = MethodChannel('konata/d3d11_video');
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(d3d11Channel, (call) async {
          if (call.method == 'createSession') {
            return <String, Object?>{
              'sessionId': 1,
              'textureId': 101,
              'backend': 'd3d11',
              'adapterName': 'Mock GPU',
            };
          }
          return null;
        });
        addTearDown(() {
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(d3d11Channel, null);
        });

        final tempRoot = await tester.runAsync(
          () => Directory.systemTemp.createTemp('konata_stage5_vid_'),
        );
        addTearDown(() async {
          if (tempRoot != null && tempRoot.existsSync()) {
            await tempRoot.delete(recursive: true);
          }
        });
        final storage = StorageRootService(overrideRoot: tempRoot);

        const work = Work(id: 'w1', title: '芙莉莲', year: 2023);
        const ep1 = Episode(
          id: 'ep1',
          workId: 'w1',
          seasonNumber: 1,
          episodeNumber: 1,
          category: EpisodeCategory.main,
          title: '冒险的终点',
        );
        const ep2 = Episode(
          id: 'ep2',
          workId: 'w1',
          seasonNumber: 1,
          episodeNumber: 2,
          category: EpisodeCategory.main,
          title: '魔法并非全部',
        );
        const v1 = MediaVariant(
          id: 'v1',
          workId: 'w1',
          episodeId: 'ep1',
          sourceId: 's1',
          relativePath: '01.mkv',
          fileName: '01.mkv',
          fileSize: 1000,
        );
        const v2 = MediaVariant(
          id: 'v2',
          workId: 'w1',
          episodeId: 'ep2',
          sourceId: 's1',
          relativePath: '02.mkv',
          fileName: '02.mkv',
          fileSize: 1000,
        );
        const bundle = WorkDetailBundle(
          work: work,
          episodes: [ep1, ep2],
          variants: [v1, v2],
          sourcesById: {},
          latestPlayback: null,
        );
        const req = VideoLaunchRequest(
          work: work,
          episode: ep1,
          variant: v1,
          bundle: bundle,
        );

        driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
        final db = KonataDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final repo = DriftLibraryRepository(db);
        await repo.upsertMediaSource(
          const MediaSource(
            id: 's1',
            label: 'Local',
            kind: MediaSourceKind.local,
            location: r'D:\Anime',
          ),
        );
        await repo.upsertWork(work);
        await repo.upsertEpisode(ep1);
        await repo.upsertEpisode(ep2);
        await repo.upsertMediaVariant(v1);
        await repo.upsertMediaVariant(v2);

        late VideoPlaybackController controller;
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              storageRootProvider.overrideWithValue(storage),
              libraryRepositoryProvider.overrideWithValue(repo),
              videoPlaybackProvider(req).overrideWith(() {
                controller = VideoPlaybackController(
                  req,
                  sessionFactory: () => EmbeddedMpvSession(
                    storageRoot: storage,
                    streamBridge: LocalStreamBridge(storageRoot: storage),
                    clientFactory: () => _FakeVideoClient(),
                  ),
                );
                return controller;
              }),
            ],
            child: MaterialApp(
              theme: KonataTheme.lightTheme(),
              darkTheme: KonataTheme.darkTheme(),
              themeMode: ThemeMode.light,
              locale: const Locale('zh', 'CN'),
              supportedLocales: const [Locale('zh', 'CN')],
              localizationsDelegates: GlobalMaterialLocalizations.delegates,
              home: const EmbeddedVideoPage(request: req),
            ),
          ),
        );
        for (var i = 0; i < 12; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump(const Duration(milliseconds: 20));
          if (controller.state.hasFirstFrame) break;
        }

        controller.setSideSheetOpen(true);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 260));

        expect(find.byType(VideoSideSheet), findsOneWidget);
        final sheetCtx = tester.element(find.byType(VideoSideSheet));
        expect(sheetCtx.palette.isDark, isFalse);
        expect(Theme.of(sheetCtx).brightness, Brightness.light);

        final ep2Text = tester.widget<Text>(find.textContaining('魔法并非全部'));
        expect(ep2Text.style?.color, KonataPalette.light.textPrimary);

        final closing = controller.closeAndRelease();
        for (var i = 0; i < 10; i++) {
          await tester.pump(const Duration(milliseconds: 20));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
        }
        await closing;
        debugDefaultTargetPlatformOverride = null;
      },
    );

    testWidgets(
      '4. 待复核居中宽幅弹窗支持 0 延迟拖拽且展开候选按基线单行并排零折行',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);

        driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
        final db = KonataDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final repo = DriftLibraryRepository(db);

        await repo.upsertMediaSource(
          const MediaSource(
            id: 's1',
            label: 'Local',
            kind: MediaSourceKind.local,
            location: r'D:\Anime',
          ),
        );
        await repo.upsertWork(
          const Work(
            id: 'w_rev',
            title: '未知新番测试文件夹',
            year: 2025,
            scrapeStatus: ScrapeStatus.needsReview,
            reviewReason: '评分低于自动匹配阈值',
          ),
        );
        await repo.upsertMediaVariant(
          const MediaVariant(
            id: 'v_rev',
            workId: 'w_rev',
            sourceId: 's1',
            relativePath: 'Anime/2025/VeryLongSubFolder/Episode01.mkv',
            fileName: 'Episode01.mkv',
            fileSize: 1000,
          ),
        );
        await repo.saveScrapeCandidates('w_rev', const [
          ScrapeCandidateSummary(
            workId: 'w_rev',
            tmdbId: 987654,
            mediaType: TmdbMediaType.tv,
            title: '超长候选标题测试动画作品名称用于验证基线单行对齐与徽章绝不折行',
            originalTitle: 'Super Long Original Japanese Title Line Two',
            year: 2025,
            episodeCount: 12,
            posterPath: 'tmdb://cand/987654.jpg',
            score: 86.0,
            rank: 1,
            reasons: ['title_similarity', 'year_match'],
          ),
        ]);

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              libraryRepositoryProvider.overrideWithValue(repo),
              tmdbImageLoaderProvider.overrideWithValue(
                (_, {targetWidth, imageSize}) async => _tinyPng,
              ),
            ],
            child: MaterialApp(
              theme: KonataTheme.darkTheme(),
              locale: const Locale('zh', 'CN'),
              supportedLocales: const [Locale('zh', 'CN')],
              localizationsDelegates: GlobalMaterialLocalizations.delegates,
              home: Builder(
                builder: (ctx) => Scaffold(
                  body: Center(
                    child: ElevatedButton(
                      onPressed: () => showReviewDialog(ctx),
                      child: const Text('打开待复核'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('打开待复核'));
        await tester.pumpAndSettle();

        expect(find.byType(ReviewDialog), findsOneWidget);
        final glassClipFinder = find
            .descendant(
              of: find.byType(KonataGlassDialog),
              matching: find.byType(ClipRRect),
            )
            .first;
        final glassSize = tester.getSize(glassClipFinder);
        // 1280 * 0.74 = 947.2，落在 [760, 960] 宽幅区间
        expect(glassSize.width, closeTo(947.2, 0.5));

        // 0 延迟拖拽标题栏
        final handleFinder = find.descendant(
          of: find.byType(KonataGlassDialog),
          matching: find.text('待复核'),
        );
        final initialCenter = tester.getCenter(handleFinder);
        await tester.timedDragFrom(
          initialCenter,
          const Offset(80, 40),
          const Duration(milliseconds: 120),
        );
        await tester.pumpAndSettle();
        final movedCenter = tester.getCenter(handleFinder);
        expect(movedCenter.dx, greaterThan(initialCenter.dx + 40));
        expect(movedCenter.dy, greaterThan(initialCenter.dy + 20));

        // 展开候选并验证 56x80 海报与严格单行徽章/元数据不折行
        await tester.tap(find.text('展开候选 (1)'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);

        expect(find.text('TMDB #987654'), findsOneWidget);
        expect(find.text('匹配度 86'), findsOneWidget);
        final tmdbBadgeSize = tester.getSize(find.text('TMDB #987654'));
        final scoreBadgeSize = tester.getSize(find.text('匹配度 86'));
        expect(tmdbBadgeSize.height, lessThan(22.0));
        expect(scoreBadgeSize.height, lessThan(22.0));
        expect(
          find.descendant(
            of: find.byType(ReviewWorkItemCard),
            matching: find.text('Super Long Original Japanese Title Line Two'),
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      '5. DesktopShell 浅/深色共享蓝色流体滑块与方向感保状态转场保留媒体库滚动偏移',
      (tester) async {
        SharedPreferences.setMockInitialValues({'konata_v2_theme_mode': 'light'});
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);

        driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
        final db = KonataDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final repo = DriftLibraryRepository(db);
        for (var i = 1; i <= 30; i++) {
          await repo.upsertWork(
            Work(
              id: 'w_$i',
              title: '测试作品 $i',
              year: 2024,
              scrapeStatus: ScrapeStatus.matched,
            ),
          );
        }

        final container = ProviderContainer(
          overrides: [
            ...WindowsCompositionRoot.providerOverrides(),
            libraryRepositoryProvider.overrideWithValue(repo),
          ],
        );
        addTearDown(container.dispose);

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: Consumer(
              builder: (_, ref, _) {
                final mode = ref.watch(themeModeProvider);
                return MaterialApp(
                  theme: KonataTheme.lightTheme(),
                  darkTheme: KonataTheme.darkTheme(),
                  themeMode: mode,
                  locale: const Locale('zh', 'CN'),
                  supportedLocales: const [Locale('zh', 'CN')],
                  localizationsDelegates: GlobalMaterialLocalizations.delegates,
                  home: const DesktopShell(),
                );
              },
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.runAsync(
          () => container
              .read(themeModeProvider.notifier)
              .setThemeMode(ThemeMode.light),
        );
        await tester.pumpAndSettle();

        // 1. 浅色模式下共享单实例滑块颜色为 KonataPalette.light.progressFill
        var indicator = tester.widget<DecoratedBox>(
          find.byKey(const ValueKey('top_nav_fluid_indicator')),
        );
        var dec = indicator.decoration as BoxDecoration;
        expect(dec.color, KonataPalette.light.progressFill);
        final initialLeft = tester
            .getRect(find.byKey(const ValueKey('top_nav_fluid_indicator')))
            .left;

        // 向下滚动媒体库海报墙并记录滚动偏移量
        final gridFinder = find.byType(GridView);
        expect(gridFinder, findsOneWidget);
        await tester.drag(gridFinder, const Offset(0, -320));
        await tester.pumpAndSettle();
        final scrollableFinder = find.descendant(
          of: gridFinder,
          matching: find.byType(Scrollable),
        );
        final scrollable = tester.state<ScrollableState>(scrollableFinder);
        final savedOffset = scrollable.position.pixels;
        expect(savedOffset, greaterThan(150.0));

        // 切换至「播放记录」验证流体滑块平滑右移且切页完成
        await tester.tap(find.text('播放记录'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 120));
        final midWidth = tester
            .getSize(find.byKey(const ValueKey('top_nav_fluid_indicator')))
            .width;
        expect(midWidth, greaterThan(18.0));
        await tester.pumpAndSettle();
        final historyLeft = tester
            .getRect(find.byKey(const ValueKey('top_nav_fluid_indicator')))
            .left;
        expect(historyLeft, greaterThan(initialLeft));

        // 切回「媒体库」：验证 100% 保留原有滚动偏移量
        await tester.tap(find.text('媒体库'));
        await tester.pumpAndSettle();
        expect(
          tester
              .state<ScrollableState>(
                find.descendant(
                  of: find.byType(GridView),
                  matching: find.byType(Scrollable),
                ),
              )
              .position
              .pixels,
          closeTo(savedOffset, 0.5),
        );

        // 切换为深色模式：共享滑块颜色同步切换为 KonataPalette.dark.progressFill
        await tester.tap(find.byIcon(Icons.dark_mode_outlined));
        await tester.pumpAndSettle();
        indicator = tester.widget<DecoratedBox>(
          find.byKey(const ValueKey('top_nav_fluid_indicator')),
        );
        dec = indicator.decoration as BoxDecoration;
        expect(dec.color, KonataPalette.dark.progressFill);
      },
    );
  });
}
