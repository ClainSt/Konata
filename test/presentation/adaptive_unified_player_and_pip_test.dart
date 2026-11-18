import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ccplayer/application/playback/audio_playback_notifier.dart';
import 'package:ccplayer/application/playback/playback_dispatcher.dart';
import 'package:ccplayer/application/playback/playback_preferences_provider.dart';
import 'package:ccplayer/application/playback/unified_playback_coordinator.dart';
import 'package:ccplayer/application/playback/video_playback_controller.dart';
import 'package:ccplayer/application/providers/artwork_provider.dart';
import 'package:ccplayer/application/providers/library_providers.dart';
import 'package:ccplayer/domain/models/episode.dart';
import 'package:ccplayer/domain/models/media_source.dart';
import 'package:ccplayer/domain/models/media_variant.dart';
import 'package:ccplayer/domain/models/playback_record.dart';
import 'package:ccplayer/domain/models/work.dart';
import 'package:ccplayer/domain/playback/cue_and_lrc_parser.dart';
import 'package:ccplayer/domain/playback/playback_probe_stats.dart';
import 'package:ccplayer/domain/playback/subtitle_and_audio_choices.dart';
import 'package:ccplayer/domain/playback/video_aspect_mode.dart';
import 'package:ccplayer/infrastructure/database/drift_library_repository.dart';
import 'package:ccplayer/infrastructure/database/konata_database.dart';
import 'package:ccplayer/presentation/audio/immersive_audio_page.dart';
import 'package:ccplayer/presentation/audio/mini_audio_bar.dart';
import 'package:ccplayer/presentation/detail/detail_bottom_drawer.dart';
import 'package:ccplayer/presentation/detail/episode_drawer_card.dart';
import 'package:ccplayer/presentation/history/playback_history_page.dart';
import 'package:ccplayer/presentation/theme/konata_adaptive_tokens.dart';
import 'package:ccplayer/presentation/theme/konata_theme.dart';
import 'package:ccplayer/presentation/video/embedded_video_page.dart';
import 'package:ccplayer/presentation/video/video_side_sheet.dart';
import 'package:ccplayer/presentation/widgets/playback/konata_cached_artwork_backdrop.dart';
import 'package:ccplayer/presentation/widgets/playback/konata_playback_capsule.dart';

final Uint8List _sample1x1Png = Uint8List.fromList(const <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0xF8, 0xCF, 0xC0, 0xF0,
  0x1F, 0x00, 0x05, 0x00, 0x01, 0xFF, 0x89, 0x99, 0x3D, 0x1D, 0x00, 0x00,
  0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

class _StubAudioNotifier extends AudioPlaybackNotifier {
  _StubAudioNotifier(super.ref, AudioPlaybackState initial) {
    state = initial;
  }

  void emitPosition(double pos) {
    state = state.copyWith(positionSeconds: pos);
  }

  @override
  Future<void> togglePlayPause() async {
    state = state.copyWith(isPlaying: !state.isPlaying);
  }

  @override
  Future<void> previous() async {}

  @override
  Future<void> next() async {}

  @override
  Future<void> seekRelativeTrackSeconds(double seconds) async {
    state = state.copyWith(positionSeconds: seconds);
  }

  @override
  Future<void> playQueueIndex(int index) async {
    state = state.copyWith(currentIndex: index);
  }

  @override
  Future<void> pauseForVideoSession() async {
    state = state.copyWith(isPlaying: false);
  }
}

class _TrackingVideoController extends VideoPlaybackController {
  _TrackingVideoController(
    super.ref,
    super.request, {
    required this.onConstructed,
    required this.onClosed,
  }) : super(deferBootstrap: true) {
    onConstructed();
  }

  final VoidCallback onConstructed;
  final VoidCallback onClosed;

  int switchPrevCount = 0;
  int switchNextCount = 0;

  void forceState(VideoPlaybackState next) {
    state = next;
  }

  void forcePosition(double pos) {
    state = state.copyWith(positionSeconds: pos);
  }

  @override
  bool get hasPreviousEpisodeAny => true;

  @override
  bool get hasNextEpisodeAny => true;

  @override
  void togglePlayPause() {
    state = state.copyWith(isPlaying: !state.isPlaying);
  }

  @override
  void seekAbsolute(double seconds) {
    final clamped = state.durationSeconds > 0
        ? seconds.clamp(0.0, state.durationSeconds)
        : (seconds < 0 ? 0.0 : seconds);
    state = state.copyWith(positionSeconds: clamped);
  }

  @override
  void seekRelative(double deltaSeconds) {
    seekAbsolute(state.positionSeconds + deltaSeconds);
  }

  @override
  void setVolume(double volume) {
    state = state.copyWith(volume: volume.clamp(0.0, 100.0));
  }

  @override
  void setWindowBrightness(double brightness) {
    state = state.copyWith(windowBrightness: brightness.clamp(0.0, 1.0));
  }

  @override
  Future<bool> goToPreviousEpisode() async {
    switchPrevCount++;
    return true;
  }

  @override
  Future<bool> goToNextEpisode({bool isAutoAdvance = false}) async {
    switchNextCount++;
    return true;
  }

  @override
  Future<void> closeAndRelease() async {
    onClosed();
    state = state.copyWith(isClosing: true);
  }
}

VideoLaunchRequest _buildVideoRequest({int startSeconds = 0}) {
  const work = Work(
    id: 'w_unified_1',
    title: '孤独摇滚！',
    tmdbMediaType: TmdbMediaType.tv,
    scrapeStatus: ScrapeStatus.matched,
  );
  const ep1 = Episode(
    id: 'ep_1',
    workId: 'w_unified_1',
    category: EpisodeCategory.main,
    seasonNumber: 1,
    episodeNumber: 1,
    title: '转动的孤独',
  );
  const ep2 = Episode(
    id: 'ep_2',
    workId: 'w_unified_1',
    category: EpisodeCategory.main,
    seasonNumber: 1,
    episodeNumber: 2,
    title: '明天见',
  );
  const v1 = MediaVariant(
    id: 'v_1',
    workId: 'w_unified_1',
    episodeId: 'ep_1',
    sourceId: 's_1',
    relativePath: '01.mkv',
    fileName: '[VCB-Studio] Bocchi [01][Ma10p_1080p].mkv',
    fileSize: 512 * 1024 * 1024,
    assetKind: AssetKind.video,
  );
  const v2 = MediaVariant(
    id: 'v_2',
    workId: 'w_unified_1',
    episodeId: 'ep_2',
    sourceId: 's_1',
    relativePath: '02.mkv',
    fileName: '[VCB-Studio] Bocchi [02][Ma10p_1080p].mkv',
    fileSize: 512 * 1024 * 1024,
    assetKind: AssetKind.video,
  );
  const bundle = WorkDetailBundle(
    work: work,
    episodes: [ep1, ep2],
    variants: [v1, v2],
    sourcesById: {
      's_1': MediaSource(
        id: 's_1',
        kind: MediaSourceKind.local,
        label: 'Anime',
        location: 'D:/Anime',
      ),
    },
    latestPlayback: null,
  );
  return VideoLaunchRequest(
    work: work,
    episode: ep1,
    variant: v1,
    bundle: bundle,
    startSeconds: startSeconds,
  );
}

AudioPlaybackState _buildAudioTestState() {
  const work = Work(id: 'w_cd_1', title: '结束乐队');
  const cdVar = MediaVariant(
    id: 'cd_v1',
    workId: 'w_cd_1',
    sourceId: 's_1',
    relativePath: 'CD/01.flac',
    fileName: '01.flac',
    fileSize: 40 * 1024 * 1024,
    assetKind: AssetKind.cdAlbum,
  );
  const item1 = AudioQueueItem(
    id: 'trk_1',
    work: work,
    variant: cdVar,
    title: '青春情结',
    performer: '结束乐队',
    albumTitle: 'Kessoku Band',
    trackNumber: 1,
    duration: Duration(seconds: 204),
  );
  const item2 = AudioQueueItem(
    id: 'trk_2',
    work: work,
    variant: cdVar,
    title: '吉他与孤独与蓝色星球',
    performer: '结束乐队',
    albumTitle: 'Kessoku Band',
    trackNumber: 2,
    duration: Duration(seconds: 228),
  );
  const lrc = LrcDocument(
    lines: [
      LrcCueLine(
        startSeconds: 5,
        primaryText: 'かき鳴らせ 青春コンプレックス',
        secondaryLines: ['奏响吧 青春情结'],
      ),
      LrcCueLine(
        startSeconds: 18,
        primaryText: '蒼い惑星 ひとりぼっち',
        secondaryLines: ['蓝色星球 孤独一人'],
      ),
    ],
  );
  return AudioPlaybackState(
    isActive: true,
    isPlaying: true,
    currentIndex: 0,
    queue: const [item1, item2],
    positionSeconds: 10,
    durationSeconds: 204,
    audioCodecLabel: 'FLAC',
    sampleRateAndBitDepthLabel: '48kHz / 24bit',
    cover: MemoryAudioCover(_sample1x1Png),
    lrcDocument: lrc,
    activeLyricIndex: 0,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('1. 五视口全屏音频页布局、静态缓存背景与高频进度隔离', () {
    for (final spec in <(TargetPlatform, Size, EdgeInsets)>[
      (TargetPlatform.windows, const Size(1920, 1080), EdgeInsets.zero),
      (
        TargetPlatform.android,
        const Size(1280, 800),
        const EdgeInsets.only(top: 24),
      ),
      (
        TargetPlatform.android,
        const Size(800, 1280),
        const EdgeInsets.only(top: 24),
      ),
      (
        TargetPlatform.android,
        const Size(390, 844),
        const EdgeInsets.only(top: 28, bottom: 18),
      ),
      (
        TargetPlatform.android,
        const Size(844, 390),
        const EdgeInsets.only(left: 24, right: 24, bottom: 14),
      ),
    ]) {
      testWidgets('ImmersiveAudioPage 视口零溢出与高频进度隔离 ${spec.$2}', (tester) async {
        debugDefaultTargetPlatformOverride = spec.$1;
        addTearDown(() {
          debugDefaultTargetPlatformOverride = null;
          debugOnRebuildDirtyWidget = null;
        });
        tester.view.physicalSize = spec.$2;
        tester.view.devicePixelRatio = 1.0;
        tester.view.padding = FakeViewPadding(
          left: spec.$3.left,
          top: spec.$3.top,
          right: spec.$3.right,
          bottom: spec.$3.bottom,
        );
        addTearDown(tester.view.reset);

        SharedPreferences.setMockInitialValues({});
        late _StubAudioNotifier audioNotifier;

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              audioPlaybackProvider.overrideWith((ref) {
                audioNotifier = _StubAudioNotifier(ref, _buildAudioTestState());
                return audioNotifier;
              }),
              tmdbImageLoaderProvider.overrideWithValue(
                (_, {targetWidth, imageSize}) async => _sample1x1Png,
              ),
              immersiveAudioExpandedProvider.overrideWith((_) => true),
            ],
            child: MaterialApp(
              locale: const Locale('zh', 'CN'),
              supportedLocales: const [Locale('zh', 'CN')],
              localizationsDelegates: GlobalMaterialLocalizations.delegates,
              theme: KonataTheme.darkTheme(),
              home: const ImmersiveAudioPage(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byType(KonataCachedArtworkBackdrop), findsOneWidget);

        if (spec.$1 == TargetPlatform.android && spec.$2.shortestSide >= 600) {
          final collapseRect = tester.getRect(
            find.byKey(const ValueKey('immersive_collapse_button')),
          );
          expect(collapseRect.top, greaterThanOrEqualTo(44.0));
          final heroBox = tester.getSize(find.byType(Hero));
          expect(heroBox.width, lessThanOrEqualTo(420.0));
        }

        if (spec.$1 == TargetPlatform.android &&
            spec.$2.shortestSide < 600 &&
            spec.$2.height >= 500) {
          final queueBtn = find.byKey(
            const ValueKey('portrait_open_queue_button'),
          );
          final lyrBtn = find.byKey(
            const ValueKey('portrait_toggle_lyrics_button'),
          );
          expect(tester.getSize(queueBtn).height, greaterThanOrEqualTo(48.0));
          expect(tester.getSize(lyrBtn).height, greaterThanOrEqualTo(48.0));
          expect(find.text('かき鳴らせ 青春コンプレックス'), findsWidgets);

          // 原位切换封面 ↔ 滚动歌词
          await tester.tap(lyrBtn);
          await tester.pumpAndSettle();
          expect(
            find.byKey(const ValueKey('portrait_lyrics_stage')),
            findsOneWidget,
          );
          await tester.tap(
            find.byKey(const ValueKey('portrait_back_to_cover')),
          );
          await tester.pumpAndSettle();
          expect(
            find.byKey(const ValueKey('portrait_cover_stage')),
            findsOneWidget,
          );

          // 打开队列抽屉并关闭
          await tester.tap(queueBtn);
          await tester.pumpAndSettle();
          expect(find.text('播放队列 (2)'), findsOneWidget);
          await tester.tap(find.byTooltip('关闭队列抽屉'));
          await tester.pumpAndSettle();
        }

        // 连续更新播放秒数，顶层与静态缓存背景绝不重建
        var backdropRebuilds = 0;
        var pageRebuilds = 0;
        debugOnRebuildDirtyWidget = (element, builtOnce) {
          if (!builtOnce) return;
          if (element.widget is KonataCachedArtworkBackdrop) {
            backdropRebuilds++;
          }
          if (element.widget is ImmersiveAudioPage) {
            pageRebuilds++;
          }
        };
        for (var i = 1; i <= 5; i++) {
          audioNotifier.emitPosition(10.0 + i);
          await tester.pump();
        }
        debugOnRebuildDirtyWidget = null;
        expect(backdropRebuilds, equals(0));
        expect(pageRebuilds, equals(0));

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        debugDefaultTargetPlatformOverride = null;
      });
    }

    testWidgets('手机竖屏顶部下拉手势触发收起全屏音频页', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});

      final db = KonataDatabase(NativeDatabase.memory());
      addTearDown(() async => tester.runAsync(db.close));
      await tester.runAsync(() => db.customSelect('SELECT 1').get());
      final container = ProviderContainer(
        overrides: [
          libraryRepositoryProvider.overrideWithValue(DriftLibraryRepository(db)),
          audioPlaybackProvider.overrideWith(
            (ref) => _StubAudioNotifier(ref, _buildAudioTestState()),
          ),
          tmdbImageLoaderProvider.overrideWithValue(
            (_, {targetWidth, imageSize}) async => _sample1x1Png,
          ),
        ],
      );
      addTearDown(container.dispose);
      container.read(immersiveAudioExpandedProvider.notifier).state = true;

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            locale: const Locale('zh', 'CN'),
            supportedLocales: const [Locale('zh', 'CN')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            theme: KonataTheme.darkTheme(),
            builder: (_, child) => MiniAudioOverlayHost(child: child!),
            home: const Scaffold(body: SizedBox.expand()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ImmersiveAudioPage), findsOneWidget);

      await tester.dragFrom(const Offset(200, 30), const Offset(0, 120));
      await tester.pumpAndSettle();
      expect(container.read(immersiveAudioExpandedProvider), isFalse);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      debugDefaultTargetPlatformOverride = null;
    });
  });

  group('2. 音视频一体化与免重建迷你视频胶囊 + 后台纯音频切换', () {
    testWidgets('收起为圆角视频预览、切换后台纯音频及再展开零重建解码会话', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});

      final db = KonataDatabase(NativeDatabase.memory());
      addTearDown(() async => tester.runAsync(db.close));
      await tester.runAsync(() => db.customSelect('SELECT 1').get());
      final req = _buildVideoRequest();
      var constructCount = 0;
      var closeCount = 0;
      late _TrackingVideoController fakeCtrl;

      final container = ProviderContainer(
        overrides: [
          libraryRepositoryProvider.overrideWithValue(DriftLibraryRepository(db)),
          audioPlaybackProvider.overrideWith(
            (ref) => _StubAudioNotifier(ref, const AudioPlaybackState()),
          ),
          tmdbImageLoaderProvider.overrideWithValue(
            (_, {targetWidth, imageSize}) async => _sample1x1Png,
          ),
          videoPlaybackProvider(req).overrideWith((ref) {
            fakeCtrl = _TrackingVideoController(
              ref,
              req,
              onConstructed: () => constructCount++,
              onClosed: () => closeCount++,
            );
            fakeCtrl.forceState(
              VideoPlaybackState(
                isInitializing: false,
                isBuffering: false,
                hasFirstFrame: true,
                isPlaying: true,
                currentWork: req.work,
                currentBundle: req.bundle,
                currentEpisode: req.episode,
                currentVariant: req.variant,
                durationSeconds: 1440.0,
                positionSeconds: 120.0,
              ),
            );
            return fakeCtrl;
          }),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            navigatorKey: container.read(rootNavigatorKeyProvider),
            locale: const Locale('zh', 'CN'),
            supportedLocales: const [Locale('zh', 'CN')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            theme: KonataTheme.darkTheme(),
            builder: (_, child) => MiniAudioOverlayHost(child: child!),
            home: const Scaffold(body: SizedBox.expand()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await container.read(activeVideoSessionProvider.notifier).openVideo(req);
      await tester.pumpAndSettle();
      expect(find.byType(EmbeddedVideoPage), findsOneWidget);
      expect(constructCount, equals(1));
      expect(closeCount, equals(0));

      // 点击收起按钮转为 16:9 悬浮视频小窗，绝不关闭解码器
      await tester.tap(find.byKey(const ValueKey('video_collapse_button')));
      await tester.pumpAndSettle();

      expect(find.byType(EmbeddedVideoPage), findsNothing);
      expect(
        find.byKey(const ValueKey('konata_floating_mini_player')),
        findsOneWidget,
      );
      expect(container.read(miniAudioBottomClearanceProvider), greaterThan(0));
      expect(constructCount, equals(1));
      expect(closeCount, equals(0));
      expect(
        container.read(unifiedPlaybackControlProvider).kind,
        equals(UnifiedMediaKind.video),
      );

      // 切换后台纯音频模式并按两段式轻触（首次显现角标，再次轻触展开）回到全屏，控制器与会话不重建
      fakeCtrl.toggleAudioOnlyMode();
      await tester.pumpAndSettle();
      expect(fakeCtrl.state.audioOnlyMode, isTrue);

      await tester.tap(
        find.byKey(const ValueKey('floating_mini_surface_tap_target')),
      );
      await tester.pump();
      expect(
        find.byKey(const ValueKey('floating_mini_close_button')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey('floating_mini_surface_tap_target')),
      );
      await tester.pumpAndSettle();
      expect(find.byType(EmbeddedVideoPage), findsOneWidget);
      expect(find.byType(KonataCachedArtworkBackdrop), findsOneWidget);
      expect(constructCount, equals(1));
      expect(closeCount, equals(0));

      await container.read(activeVideoSessionProvider.notifier).closeVideo();
      await tester.pumpAndSettle();
      expect(closeCount, equals(1));

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      debugDefaultTargetPlatformOverride = null;
    });
  });

  group('3. 播放无操作 3 秒 OSD 自动隐藏并彻底退订进度界面监听', () {
    testWidgets('3 秒无操作淡出隐藏且后续跳秒产生严格 0 次 Widget 重建', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() {
        debugDefaultTargetPlatformOverride = null;
        debugOnRebuildDirtyWidget = null;
      });
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});

      final req = _buildVideoRequest();
      late _TrackingVideoController fakeCtrl;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            videoPlaybackProvider(req).overrideWith((ref) {
              fakeCtrl = _TrackingVideoController(
                ref,
                req,
                onConstructed: () {},
                onClosed: () {},
              );
              fakeCtrl.forceState(
                VideoPlaybackState(
                  isInitializing: false,
                  isBuffering: false,
                  hasFirstFrame: true,
                  isPlaying: true,
                  currentWork: req.work,
                  currentBundle: req.bundle,
                  currentEpisode: req.episode,
                  currentVariant: req.variant,
                  durationSeconds: 1440.0,
                  positionSeconds: 10.0,
                ),
              );
              return fakeCtrl;
            }),
          ],
          child: MaterialApp(
            locale: const Locale('zh', 'CN'),
            supportedLocales: const [Locale('zh', 'CN')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            theme: KonataTheme.darkTheme(),
            home: EmbeddedVideoPage(request: req),
          ),
        ),
      );
      await tester.pump();

      // 初始 OSD 可见
      final initialOpacity = tester.widget<AnimatedOpacity>(
        find
            .ancestor(
              of: find.byType(KonataPlaybackCapsule),
              matching: find.byType(AnimatedOpacity),
            )
            .first,
      );
      expect(initialOpacity.opacity, equals(1.0));

      // 推进超过 3000ms 空闲隐藏阈值并等待淡出结束
      await tester.pump(const Duration(milliseconds: 3100));
      await tester.pumpAndSettle();
      final hiddenOpacity = tester.widget<AnimatedOpacity>(
        find
            .ancestor(
              of: find.byType(KonataPlaybackCapsule),
              matching: find.byType(AnimatedOpacity),
            )
            .first,
      );
      expect(hiddenOpacity.opacity, equals(0.0));

      // 隐藏期间连续推进 10 次 positionSeconds，全树脏重建次数必须为 0
      var dirtyCount = 0;
      debugOnRebuildDirtyWidget = (_, builtOnce) {
        if (builtOnce) dirtyCount++;
      };
      for (var i = 1; i <= 10; i++) {
        fakeCtrl.forcePosition(10.0 + i);
        await tester.pump();
      }
      debugOnRebuildDirtyWidget = null;
      expect(dirtyCount, equals(0));

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      debugDefaultTargetPlatformOverride = null;
    });
  });

  group('4. 视频强制限位横屏全幅、五标签毛玻璃侧栏、触控手势与锁屏屏蔽', () {
    testWidgets('进入视频页立即请求横屏与沉浸窗并全幅铺满视口（无竖屏白底分栏）', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});

      final orientationCalls = <Object?>[];
      final windowCalls = <(String, Object?)>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'SystemChrome.setPreferredOrientations') {
            orientationCalls.add(call.arguments);
          }
          return null;
        },
      );
      const playbackWindowChannel = MethodChannel('ccplayer/playback_window');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        playbackWindowChannel,
        (call) async {
          windowCalls.add((call.method, call.arguments));
          return null;
        },
      );
      addTearDown(() {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        );
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          playbackWindowChannel,
          null,
        );
      });

      final req = _buildVideoRequest();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            videoPlaybackProvider(req).overrideWith((ref) {
              final c = _TrackingVideoController(
                ref,
                req,
                onConstructed: () {},
                onClosed: () {},
              );
              c.forceState(
                VideoPlaybackState(
                  isInitializing: false,
                  isBuffering: false,
                  hasFirstFrame: true,
                  isPlaying: true,
                  currentWork: req.work,
                  currentBundle: req.bundle,
                  currentEpisode: req.episode,
                  currentVariant: req.variant,
                  durationSeconds: 1440.0,
                  probeStats: const PlaybackProbeStats(
                    videoWidth: 1920,
                    videoHeight: 1080,
                  ),
                ),
              );
              return c;
            }),
          ],
          child: MaterialApp(
            locale: const Locale('zh', 'CN'),
            supportedLocales: const [Locale('zh', 'CN')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            theme: KonataTheme.darkTheme(),
            home: EmbeddedVideoPage(request: req),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        orientationCalls,
        contains(
          equals([
            'DeviceOrientation.landscapeLeft',
            'DeviceOrientation.landscapeRight',
          ]),
        ),
      );
      expect(windowCalls, contains(('setLandscape', true)));

      // 校验视频表面全幅铺满视口，不存在白底分栏
      final stageSize = tester.getSize(
        find.byKey(const ValueKey('android_hardware_surface_placeholder')),
      );
      expect(stageSize.width, equals(390.0));
      expect(stageSize.height, equals(844.0));

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(
        orientationCalls.last,
        equals([for (final o in DeviceOrientation.values) o.toString()]),
      );
      expect(windowCalls, contains(('setLandscape', false)));
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('平板右滑控制台含选集章节字幕音频画面五标签且屏蔽桌面独占 WASAPI', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      tester.view.padding = const FakeViewPadding(top: 24);
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});

      final req = _buildVideoRequest();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            videoPlaybackProvider(req).overrideWith((ref) {
              final c = _TrackingVideoController(
                ref,
                req,
                onConstructed: () {},
                onClosed: () {},
              );
              c.forceState(
                VideoPlaybackState(
                  isInitializing: false,
                  isBuffering: false,
                  hasFirstFrame: true,
                  isPlaying: true,
                  sideSheetOpen: true,
                  currentWork: req.work,
                  currentBundle: req.bundle,
                  currentEpisode: req.episode,
                  currentVariant: req.variant,
                  durationSeconds: 1440.0,
                  chapters: const [
                    PlaybackChapter(
                      index: 0,
                      title: 'OP',
                      startSeconds: 90,
                    ),
                  ],
                  audioTracks: const [
                    AudioTrackChoice(
                      mpvTrackId: 1,
                      language: 'jpn',
                      title: '日本語',
                      codec: 'flac',
                      channelCount: 2,
                      isDefault: true,
                      isExternal: false,
                      selected: true,
                    ),
                  ],
                  probeStats: const PlaybackProbeStats(
                    videoWidth: 1920,
                    videoHeight: 1080,
                    hwdecCurrent: 'mediacodec',
                  ),
                ),
              );
              return c;
            }),
          ],
          child: MaterialApp(
            locale: const Locale('zh', 'CN'),
            supportedLocales: const [Locale('zh', 'CN')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            theme: KonataTheme.darkTheme(),
            home: EmbeddedVideoPage(request: req),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      // 校验平板顶部避让与底部控制坞最大宽度 <= 640dp
      final topBarRect = tester.getRect(
        find.byKey(const ValueKey('android_video_top_capsule')),
      );
      expect(topBarRect.top, greaterThanOrEqualTo(44.0));
      expect(
        tester.getSize(find.byType(KonataPlaybackCapsule)).width,
        lessThanOrEqualTo(KonataAdaptiveTokens.tabletPlayerMaxWidth),
      );
      expect(find.byTooltip('切换外部播放器无缝接力续播'), findsNothing);

      expect(find.byType(VideoSideSheet), findsOneWidget);
      for (final tabLabel in const ['选集', '章节', '字幕', '音频', '画面']) {
        expect(find.text(tabLabel), findsOneWidget);
      }
      await tester.tap(find.text('音频'));
      await tester.pumpAndSettle();
      expect(find.text('WASAPI 独占直通'), findsNothing);

      await tester.tap(find.text('画面'));
      await tester.pumpAndSettle();
      expect(find.text('画面比例'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('后台纯音频模式'), 200);
      expect(find.text('后台纯音频模式'), findsOneWidget);

      await tester.tap(find.text('字幕'));
      await tester.pumpAndSettle();
      expect(find.text('字幕延迟'), findsOneWidget);
      expect(find.byType(Slider), findsWidgets);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('Android 横屏全套触控手势与锁屏屏蔽全部手势/控制坞', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      tester.view.physicalSize = const Size(844, 390);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});

      final req = _buildVideoRequest();
      late _TrackingVideoController fakeCtrl;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            videoPlaybackProvider(req).overrideWith((ref) {
              fakeCtrl = _TrackingVideoController(
                ref,
                req,
                onConstructed: () {},
                onClosed: () {},
              );
              fakeCtrl.forceState(
                VideoPlaybackState(
                  isInitializing: false,
                  isBuffering: false,
                  hasFirstFrame: true,
                  isPlaying: true,
                  currentWork: req.work,
                  currentBundle: req.bundle,
                  currentEpisode: req.episode,
                  currentVariant: req.variant,
                  windowBrightness: 0.5,
                  volume: 50.0,
                  positionSeconds: 100.0,
                  durationSeconds: 1440.0,
                ),
              );
              return fakeCtrl;
            }),
          ],
          child: MaterialApp(
            locale: const Locale('zh', 'CN'),
            supportedLocales: const [Locale('zh', 'CN')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            theme: KonataTheme.darkTheme(),
            home: EmbeddedVideoPage(request: req),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 悬浮胶囊不贴边（left >= 14, top >= 12）
      final topRect = tester.getRect(
        find.byKey(const ValueKey('android_video_top_capsule')),
      );
      expect(topRect.left, greaterThanOrEqualTo(14.0));
      expect(topRect.top, greaterThanOrEqualTo(12.0));

      // 左侧上滑调亮 + 居中数值胶囊
      await tester.dragFrom(const Offset(140, 220), const Offset(0, -100));
      await tester.pump();
      expect(fakeCtrl.state.windowBrightness, greaterThan(0.5));
      expect(
        find.byKey(const ValueKey('video_gesture_center_pill')),
        findsOneWidget,
      );
      await tester.pump(const Duration(milliseconds: 200));

      // 右侧上滑调音
      await tester.dragFrom(const Offset(700, 220), const Offset(0, -100));
      await tester.pump();
      expect(fakeCtrl.state.volume, greaterThan(50.0));
      await tester.pump(const Duration(milliseconds: 200));

      // 水平滑动预览跳转
      await tester.dragFrom(const Offset(360, 195), const Offset(180, 0));
      await tester.pump();
      expect(fakeCtrl.state.positionSeconds, greaterThan(100.0));
      await tester.pump(const Duration(milliseconds: 200));

      // 右侧 1/3 双击快进 10 秒
      final posBeforeRightDoubleTap = fakeCtrl.state.positionSeconds;
      await tester.tapAt(const Offset(760, 195));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(const Offset(760, 195));
      await tester.pump(const Duration(milliseconds: 350));
      expect(
        fakeCtrl.state.positionSeconds,
        closeTo(posBeforeRightDoubleTap + 10.0, 0.5),
      );

      // 左侧 1/3 双击快退 10 秒
      final posBeforeLeftDoubleTap = fakeCtrl.state.positionSeconds;
      await tester.tapAt(const Offset(80, 195));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(const Offset(80, 195));
      await tester.pump(const Duration(milliseconds: 350));
      expect(
        fakeCtrl.state.positionSeconds,
        closeTo(posBeforeLeftDoubleTap - 10.0, 0.5),
      );

      // 中央 1/3 双击暂停
      expect(fakeCtrl.state.isPlaying, isTrue);
      await tester.tapAt(const Offset(422, 195));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(const Offset(422, 195));
      await tester.pump(const Duration(milliseconds: 350));
      expect(fakeCtrl.state.isPlaying, isFalse);

      // 长按触发 2.0x 倍速快进，松手恢复
      final hold = await tester.startGesture(const Offset(422, 195));
      await tester.pump(const Duration(milliseconds: 650));
      expect(fakeCtrl.state.isSpeedBoostActive, isTrue);
      await hold.up();
      await tester.pumpAndSettle();
      expect(fakeCtrl.state.isSpeedBoostActive, isFalse);

      // 若 3 秒无操作已隐藏 HUD，先轻触唤醒后再点击锁屏键
      if (find.byKey(const ValueKey('video_screen_lock_button')).evaluate().isEmpty) {
        await tester.tapAt(const Offset(422, 195));
        await tester.pumpAndSettle();
      }
      await tester.tap(
        find.byKey(const ValueKey('video_screen_lock_button')),
      );
      await tester.pumpAndSettle();
      final lockedBottomOpacity = tester.widget<AnimatedOpacity>(
        find
            .ancestor(
              of: find.byType(KonataPlaybackCapsule),
              matching: find.byType(AnimatedOpacity),
            )
            .first,
      );
      expect(lockedBottomOpacity.opacity, equals(0.0));

      final lockedVol = fakeCtrl.state.volume;
      await tester.dragFrom(const Offset(700, 220), const Offset(0, -100));
      await tester.tapAt(const Offset(422, 195));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(const Offset(422, 195));
      await tester.pumpAndSettle();
      expect(fakeCtrl.state.volume, equals(lockedVol));
      expect(fakeCtrl.state.isPlaying, isFalse);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      debugDefaultTargetPlatformOverride = null;
    });
  });

  group('5. Android 原生画中画持久化开关、比例钳制、资格门控与纯净态', () {
    test('autoEnterPip 默认开启且持久化生效；宽高比严格钳制于 0.42 ~ 2.39', () async {
      SharedPreferences.setMockInitialValues({});
      final n1 = PlaybackPreferencesNotifier(enablePersistence: true);
      expect(n1.state.autoEnterPip, isTrue);

      await n1.setAutoEnterPip(false);
      expect(n1.state.autoEnterPip, isFalse);

      final n2 = PlaybackPreferencesNotifier(enablePersistence: true);
      for (var i = 0; i < 20 && n2.state.autoEnterPip; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(n2.state.autoEnterPip, isFalse);

      expect(
        PipAspectRatioPolicy.clampRational(360, 1280).ratio,
        closeTo(0.42, 0.001),
      );
      expect(
        PipAspectRatioPolicy.clampRational(3840, 1080).ratio,
        closeTo(2.39, 0.001),
      );
      expect(
        PipAspectRatioPolicy.clampRational(1920, 1080).ratio,
        closeTo(16 / 9, 0.01),
      );
      expect(
        PipAspectRatioPolicy.clampRational(0, 0).ratio,
        closeTo(16 / 9, 0.01),
      );
    });

    testWidgets('PiP 自动触发资格随播放态/纯音频/开关即时响应，进入 PiP 仅展示全幅纹理并接入原生回调', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() {
        debugDefaultTargetPlatformOverride = null;
        debugOnRebuildDirtyWidget = null;
      });
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});

      final db = KonataDatabase(NativeDatabase.memory());
      addTearDown(() async => tester.runAsync(db.close));
      await tester.runAsync(() => db.customSelect('SELECT 1').get());
      final req = _buildVideoRequest();
      late _TrackingVideoController fakeCtrl;
      final pipClient = AndroidPipChannelClient();

      final container = ProviderContainer(
        overrides: [
          libraryRepositoryProvider.overrideWithValue(DriftLibraryRepository(db)),
          audioPlaybackProvider.overrideWith(
            (ref) => _StubAudioNotifier(ref, const AudioPlaybackState()),
          ),
          playbackPreferencesProvider.overrideWith(
            (_) => PlaybackPreferencesNotifier(enablePersistence: false),
          ),
          androidPipChannelClientProvider.overrideWithValue(pipClient),
          videoPlaybackProvider(req).overrideWith((ref) {
            fakeCtrl = _TrackingVideoController(
              ref,
              req,
              onConstructed: () {},
              onClosed: () {},
            );
            fakeCtrl.forceState(
              VideoPlaybackState(
                isInitializing: false,
                isBuffering: false,
                hasFirstFrame: true,
                isPlaying: true,
                currentWork: req.work,
                currentBundle: req.bundle,
                currentEpisode: req.episode,
                currentVariant: req.variant,
                durationSeconds: 1440.0,
                probeStats: const PlaybackProbeStats(
                  videoWidth: 1920,
                  videoHeight: 1080,
                ),
              ),
            );
            return fakeCtrl;
          }),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            navigatorKey: container.read(rootNavigatorKeyProvider),
            locale: const Locale('zh', 'CN'),
            supportedLocales: const [Locale('zh', 'CN')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            theme: KonataTheme.darkTheme(),
            builder: (_, child) => MiniAudioOverlayHost(child: child!),
            home: const Scaffold(body: SizedBox.expand()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await container.read(activeVideoSessionProvider.notifier).openVideo(req);
      await tester.pumpAndSettle();

      expect(container.read(androidPipAutoSyncProvider).eligible, isTrue);

      // 暂停 -> 立即禁用自动进入 PiP
      fakeCtrl.togglePlayPause();
      await tester.pump();
      expect(container.read(androidPipAutoSyncProvider).eligible, isFalse);

      // 恢复播放 -> 恢复允许
      fakeCtrl.togglePlayPause();
      await tester.pump();
      expect(container.read(androidPipAutoSyncProvider).eligible, isTrue);

      // 后台纯音频 -> 禁用
      fakeCtrl.setAudioOnlyMode(true);
      await tester.pump();
      expect(container.read(androidPipAutoSyncProvider).eligible, isFalse);
      fakeCtrl.setAudioOnlyMode(false);
      await tester.pump();

      // 关闭持久化设置开关 -> 禁用
      await container
          .read(playbackPreferencesProvider.notifier)
          .setAutoEnterPip(false);
      await tester.pump();
      expect(container.read(androidPipAutoSyncProvider).eligible, isFalse);
      await container
          .read(playbackPreferencesProvider.notifier)
          .setAutoEnterPip(true);
      await tester.pump();

      // 进入系统画中画纯净态：隐藏所有胶囊/抽屉/SafeArea，挂起进度监听
      final sessionNotifier = container.read(
        activeVideoSessionProvider.notifier,
      );
      sessionNotifier.debugSetPipMode(true);
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('video_pip_pure_stage')),
        findsOneWidget,
      );
      expect(find.byType(KonataPlaybackCapsule), findsNothing);
      expect(find.byType(VideoSideSheet), findsNothing);

      var pipDirty = 0;
      debugOnRebuildDirtyWidget = (_, builtOnce) {
        if (builtOnce) pipDirty++;
      };
      fakeCtrl.forcePosition(222.0);
      await tester.pump();
      debugOnRebuildDirtyWidget = null;
      expect(pipDirty, equals(0));

      // 原生画中画 RemoteAction 回调正确驱动播放/暂停与上下话
      sessionNotifier.debugTriggerRemoteAction('togglePlayPause');
      expect(fakeCtrl.state.isPlaying, isFalse);
      sessionNotifier.debugTriggerRemoteAction('previous');
      expect(fakeCtrl.switchPrevCount, equals(1));
      sessionNotifier.debugTriggerRemoteAction('next');
      expect(fakeCtrl.switchNextCount, equals(1));

      await sessionNotifier.closeVideo();
      await tester.pumpAndSettle();
      expect(container.read(androidPipAutoSyncProvider).eligible, isFalse);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('AudioFocus 抢占降音、后台自动暂停释放焦点及系统关闭 PiP 同步暂停', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      SharedPreferences.setMockInitialValues({});

      final audioFocusMethods = <String>[];
      const audioFocusCodec = StandardMethodCodec();
      const focusChannel = 'ccplayer/audio_focus';
      const pipChannel = 'ccplayer/pip';
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel(focusChannel), (
            call,
          ) async {
            audioFocusMethods.add(call.method);
            return true;
          });
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel(pipChannel), (
            call,
          ) async {
            return true;
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(const MethodChannel(focusChannel), null);
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(const MethodChannel(pipChannel), null);
      });

      final db = KonataDatabase(NativeDatabase.memory());
      addTearDown(() async => tester.runAsync(db.close));
      await tester.runAsync(() => db.customSelect('SELECT 1').get());
      final req = _buildVideoRequest();
      late _TrackingVideoController fakeCtrl;
      final pipClient = AndroidPipChannelClient();

      final container = ProviderContainer(
        overrides: [
          libraryRepositoryProvider.overrideWithValue(DriftLibraryRepository(db)),
          audioPlaybackProvider.overrideWith(
            (ref) => _StubAudioNotifier(ref, const AudioPlaybackState()),
          ),
          playbackPreferencesProvider.overrideWith(
            (_) => PlaybackPreferencesNotifier(enablePersistence: false),
          ),
          androidPipChannelClientProvider.overrideWithValue(pipClient),
          videoPlaybackProvider(req).overrideWith((ref) {
            fakeCtrl = _TrackingVideoController(
              ref,
              req,
              onConstructed: () {},
              onClosed: () {},
            );
            fakeCtrl.forceState(
              VideoPlaybackState(
                isInitializing: false,
                isBuffering: false,
                hasFirstFrame: true,
                isPlaying: true,
                volume: 80.0,
                currentWork: req.work,
                currentBundle: req.bundle,
                currentEpisode: req.episode,
                currentVariant: req.variant,
                durationSeconds: 1440.0,
              ),
            );
            return fakeCtrl;
          }),
        ],
      );
      addTearDown(container.dispose);
      final keepAliveSub = container.listen(
        videoPlaybackProvider(req),
        (_, _) {},
      );
      addTearDown(keepAliveSub.close);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: Scaffold(body: SizedBox.expand())),
        ),
      );
      await tester.pumpAndSettle();

      final sessionNotifier = container.read(
        activeVideoSessionProvider.notifier,
      );
      await sessionNotifier.openVideo(req);
      await tester.pumpAndSettle();

      // 绑定音频焦点并模拟外部音乐抢占 (duck -> gain -> lossTransient)
      var duckCount = 0;
      var lossCount = 0;
      var gainCount = 0;
      await AndroidPlaybackWindowBridge.requestAudioFocus(
        onDuck: () => duckCount++,
        onLoss: () => lossCount++,
        onGain: () => gainCount++,
      );
      expect(audioFocusMethods, contains('request'));

      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            focusChannel,
            audioFocusCodec.encodeMethodCall(
              const MethodCall('focusChange', 'duck'),
            ),
            (_) {},
          );
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            focusChannel,
            audioFocusCodec.encodeMethodCall(
              const MethodCall('focusChange', 'gain'),
            ),
            (_) {},
          );
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            focusChannel,
            audioFocusCodec.encodeMethodCall(
              const MethodCall('focusChange', 'lossTransient'),
            ),
            (_) {},
          );
      expect(duckCount, equals(1));
      expect(gainCount, equals(1));
      expect(lossCount, equals(1));

      // 原生用户划掉 PiP 小窗时主动暂停播放并释放焦点
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            pipChannel,
            audioFocusCodec.encodeMethodCall(const MethodCall('pipDismissed')),
            (_) {},
          );
      await tester.pump();
      expect(container.read(activeVideoSessionProvider).isInPipMode, isFalse);
      expect(fakeCtrl.state.isPlaying, isFalse);
      expect(audioFocusMethods, contains('abandon'));

      // 关闭自动画中画并切后台时必须自动暂停并释放音频焦点
      fakeCtrl.forceState(fakeCtrl.state.copyWith(isPlaying: true));
      await container
          .read(playbackPreferencesProvider.notifier)
          .setAutoEnterPip(false);
      await sessionNotifier.handleAppBackgrounded();
      expect(fakeCtrl.state.isPlaying, isFalse);

      await sessionNotifier.closeVideo();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      debugDefaultTargetPlatformOverride = null;
    });
  });

  group('6. Android 端外部程序彻底过滤与触控 48dp 更多操作入口', () {
    testWidgets('PlaybackDispatcher.tryOpenExternalScan 返回 null 且记录/详情页过滤外部播放器', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});

      final db = KonataDatabase(NativeDatabase.memory());
      addTearDown(() async => tester.runAsync(db.close));
      await tester.runAsync(() => db.customSelect('SELECT 1').get());
      final repo = DriftLibraryRepository(db);
      final req = _buildVideoRequest();
      await tester.runAsync(() async {
        await repo.upsertWork(req.work);
        await repo.recordPlayback(
          PlaybackRecord(
            id: 'rec_android_1',
            workId: req.work.id,
            episodeId: req.episode.id,
            variantId: req.variant.id,
            seasonNumber: 1,
            episodeNumber: 1,
            episodeTitle: '第一话',
            sourceType: MediaSourceKind.local,
            playedAt: DateTime(2026, 11, 18, 10, 0),
            positionSeconds: 100,
            durationSeconds: 1440,
          ),
        );
      });

      final container = ProviderContainer(
        overrides: [
          libraryRepositoryProvider.overrideWithValue(repo),
          tmdbImageLoaderProvider.overrideWithValue(
            (_, {targetWidth, imageSize}) async => _sample1x1Png,
          ),
        ],
      );
      addTearDown(container.dispose);

      const scanVar = MediaVariant(
        id: 'scan_1',
        workId: 'w_unified_1',
        sourceId: 's_1',
        relativePath: 'Scans/01.jpg',
        fileName: '01.jpg',
        fileSize: 1024,
        assetKind: AssetKind.scanGallery,
      );
      final extScan = await container
          .read(playbackDispatcherProvider)
          .tryOpenExternalScan(
            work: req.work,
            variant: scanVar,
            source: req.bundle.sourcesById['s_1'],
          );
      expect(extScan, isNull);

      // 播放记录页 48dp 更多按钮与外部播放器过滤
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            locale: const Locale('zh', 'CN'),
            supportedLocales: const [Locale('zh', 'CN')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            theme: KonataTheme.darkTheme(),
            home: const Scaffold(body: PlaybackHistoryPage()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final histMore = find.byKey(const ValueKey('history_more_rec_android_1'));
      expect(histMore, findsOneWidget);
      final histSize = tester.getSize(histMore);
      expect(histSize.width, greaterThanOrEqualTo(48.0));
      expect(histSize.height, greaterThanOrEqualTo(48.0));

      await tester.tap(histMore);
      await tester.pumpAndSettle();
      expect(find.text('继续观看'), findsOneWidget);
      expect(find.text('使用内置播放器续播'), findsNothing);
      expect(find.text('使用外部播放器续播'), findsNothing);

      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      // 详情抽屉齿轮菜单与单集 48dp 更多按钮彻底过滤外部入口
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            locale: const Locale('zh', 'CN'),
            supportedLocales: const [Locale('zh', 'CN')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            theme: KonataTheme.darkTheme(),
            home: Scaffold(
              body: Align(
                alignment: Alignment.bottomCenter,
                child: DetailBottomDrawer(
                  bundle: req.bundle,
                  activeTab: DetailDrawerTab.main,
                  imageLoader: (_, {targetWidth, imageSize}) async =>
                      _sample1x1Png,
                  onToggleTab: (_) {},
                  onCollapse: () {},
                  onEpisodeTap: (_) {},
                  onEpisodePlayBuiltin: (_) {},
                  onEpisodePlayExternal: (_) {},
                  onEpisodeAdjustSlot: (_) {},
                  onOpenManualMatch: () {},
                  onOpenManualEdit: () {},
                  onOpenPosterPicker: () {},
                  onOpenBackdropPicker: () {},
                  onHideWork: () {},
                  onDeleteWork: () {},
                  onRescrape: () {},
                  onOpenLocalDir: () {},
                  onOpenSeriesManage: () {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final epMore = find.byKey(const ValueKey('episode_more_ep_1'));
      expect(epMore, findsNothing);

      await tester.longPress(find.byType(EpisodeDrawerCard).first);
      await tester.pumpAndSettle();
      expect(find.text('使用内置播放器播放'), findsOneWidget);
      expect(find.text('使用外部播放器播放'), findsNothing);

      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.settings_rounded));
      await tester.pumpAndSettle();
      expect(find.text('绑定元数据'), findsOneWidget);
      expect(find.text('打开本地所在文件夹'), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      debugDefaultTargetPlatformOverride = null;
    });
  });
}
