import 'dart:async';

import 'package:ccplayer/application/playback/audio_playback_notifier.dart';
import 'package:ccplayer/application/playback/playback_preferences_provider.dart';
import 'package:ccplayer/application/playback/unified_playback_coordinator.dart';
import 'package:ccplayer/application/playback/video_playback_controller.dart';
import 'package:ccplayer/application/providers/artwork_provider.dart';
import 'package:ccplayer/application/providers/library_providers.dart';
import 'package:ccplayer/application/providers/source_actions_provider.dart';
import 'package:ccplayer/domain/models/episode.dart';
import 'package:ccplayer/domain/models/media_source.dart';
import 'package:ccplayer/domain/models/media_variant.dart';
import 'package:ccplayer/domain/models/series_group.dart';
import 'package:ccplayer/domain/models/work.dart';
import 'package:ccplayer/domain/playback/playback_probe_stats.dart';
import 'package:ccplayer/domain/repositories/file_system_gateway.dart';
import 'package:ccplayer/infrastructure/database/drift_library_repository.dart';
import 'package:ccplayer/infrastructure/database/konata_database.dart';
import 'package:ccplayer/presentation/audio/mini_audio_bar.dart';
import 'package:ccplayer/presentation/detail/detail_bottom_drawer.dart';
import 'package:ccplayer/presentation/detail/detail_full_list_dialog.dart';
import 'package:ccplayer/presentation/detail/detail_gear_menu.dart';
import 'package:ccplayer/presentation/dialogs/series_manage_dialog.dart';
import 'package:ccplayer/presentation/dialogs/work_merge_target_dialog.dart';
import 'package:ccplayer/presentation/shell/adaptive_capsule_layout.dart';
import 'package:ccplayer/presentation/shell/capsule_navigation.dart';
import 'package:ccplayer/presentation/sources/source_folder_picker_dialog.dart';
import 'package:ccplayer/presentation/theme/konata_playback_tokens.dart';
import 'package:ccplayer/presentation/theme/konata_theme.dart';
import 'package:ccplayer/presentation/video/embedded_video_page.dart';
import 'package:ccplayer/presentation/video/video_hardware_surface.dart';
import 'package:ccplayer/presentation/widgets/design_system/konata_glass_dialog.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

final Uint8List _samplePng = Uint8List.fromList(const <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0xF8, 0xCF, 0xC0, 0xF0,
  0x1F, 0x00, 0x05, 0x00, 0x01, 0xFF, 0x89, 0x99, 0x3D, 0x1D, 0x00, 0x00,
  0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

class _ViewportCase {
  const _ViewportCase({
    required this.label,
    required this.size,
    required this.android,
    required this.safe,
  });

  final String label;
  final Size size;
  final bool android;
  final EdgeInsets safe;
}

const List<_ViewportCase> _fiveViewports = <_ViewportCase>[
  _ViewportCase(
    label: '手机竖屏 390x780',
    size: Size(390, 780),
    android: true,
    safe: EdgeInsets.fromLTRB(0, 28, 0, 16),
  ),
  _ViewportCase(
    label: '手机横屏 640x420',
    size: Size(640, 420),
    android: true,
    safe: EdgeInsets.fromLTRB(32, 0, 16, 14),
  ),
  _ViewportCase(
    label: '平板竖屏 768x1024',
    size: Size(768, 1024),
    android: true,
    safe: EdgeInsets.fromLTRB(0, 24, 0, 16),
  ),
  _ViewportCase(
    label: '平板横屏 1024x700',
    size: Size(1024, 700),
    android: true,
    safe: EdgeInsets.fromLTRB(0, 24, 0, 16),
  ),
  _ViewportCase(
    label: '桌面端 1440x900',
    size: Size(1440, 900),
    android: false,
    safe: EdgeInsets.zero,
  ),
];

class _StubAudioNotifier extends AudioPlaybackNotifier {
  _StubAudioNotifier(super.ref, AudioPlaybackState initial) {
    state = initial;
  }

  int prevCount = 0;
  int nextCount = 0;
  int toggleCount = 0;
  int stopCloseCount = 0;

  void emit(AudioPlaybackState next) => state = next;

  @override
  Future<void> previous() async {
    prevCount += 1;
  }

  @override
  Future<void> next() async {
    nextCount += 1;
  }

  @override
  Future<void> togglePlayPause() async {
    toggleCount += 1;
    state = state.copyWith(isPlaying: !state.isPlaying);
  }

  @override
  Future<void> stopAndClose() async {
    stopCloseCount += 1;
    state = const AudioPlaybackState();
  }
}

class _StubVideoController extends VideoPlaybackController {
  _StubVideoController(
    super.ref,
    super.request, {
    required this.onConstructed,
    required this.onClosed,
  }) : super(deferBootstrap: true) {
    onConstructed();
    state = VideoPlaybackState(
      isInitializing: false,
      isBuffering: false,
      hasFirstFrame: true,
      isPlaying: true,
      currentWork: request.work,
      currentBundle: request.bundle,
      currentEpisode: request.episode,
      currentVariant: request.variant,
      durationSeconds: 1420.0,
      positionSeconds: 180.0,
      probeStats: const PlaybackProbeStats(
        videoWidth: 1920,
        videoHeight: 1080,
      ),
    );
  }

  final VoidCallback onConstructed;
  final VoidCallback onClosed;

  @override
  Future<void> closeAndRelease() async {
    onClosed();
    state = state.copyWith(isClosing: true);
  }
}

class _StubActionsCoordinator extends KonataActionsCoordinator {
  const _StubActionsCoordinator(super.ref);

  @override
  Future<List<RemoteEntry>> listSourceDirectory(
    MediaSource source,
    String relativePath,
  ) async {
    return const <RemoteEntry>[
      RemoteEntry(
        name: 'BDMV_Season1',
        relativePath: 'BDMV_Season1',
        isDirectory: true,
      ),
      RemoteEntry(
        name: 'CDs_OST',
        relativePath: 'CDs_OST',
        isDirectory: true,
      ),
    ];
  }
}

class _HostTestShell extends ConsumerWidget {
  const _HostTestShell({required this.onHostBuild});

  final VoidCallback onHostBuild;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    onHostBuild();
    final android = defaultTargetPlatform == TargetPlatform.android;
    final hidden = ref.watch(capsuleNavigationHiddenProvider);
    final subPushed = ref.watch(subRoutePushedProvider);
    final layout = AdaptiveCapsuleLayout(
      size: MediaQuery.sizeOf(context),
      safe: MediaQuery.paddingOf(context),
      android: android,
      navigationVisible: android && !hidden && !subPushed,
    );
    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          const Center(child: Text('主壳层工作区')),
          if (android && !hidden && !subPushed)
            Positioned.fromRect(
              rect: layout.navigationRect,
              child: CapsuleNavigation(
                vertical: layout.verticalNavigation,
                selectedIndex: 0,
                onSelected: (_) {},
              ),
            ),
        ],
      ),
    );
  }
}

VideoLaunchRequest _buildSampleVideoRequest() {
  const source = MediaSource(
    id: 'src_1',
    label: 'WebDAV 动画库',
    kind: MediaSourceKind.webdav,
    location: 'http://192.168.1.178:29798/dav',
  );
  const work = Work(
    id: 'w_accel',
    title: '加速世界',
    scrapeStatus: ScrapeStatus.matched,
  );
  const ep = Episode(
    id: 'ep_01',
    workId: 'w_accel',
    seasonNumber: 1,
    episodeNumber: 1,
    title: '加速',
  );
  const variant = MediaVariant(
    id: 'var_01',
    workId: 'w_accel',
    episodeId: 'ep_01',
    sourceId: 'src_1',
    relativePath: 'AccelWorld/01.mkv',
    fileName: '01.mkv',
    fileSize: 1024 * 1024 * 600,
  );
  const bundle = WorkDetailBundle(
    work: work,
    episodes: [ep],
    variants: [variant],
    sourcesById: {'src_1': source},
    latestPlayback: null,
    seriesMembers: [work],
  );
  return const VideoLaunchRequest(
    work: work,
    bundle: bundle,
    episode: ep,
    variant: variant,
  );
}

AudioPlaybackState _buildSampleAudioState() {
  const work = Work(id: 'w_ost', title: '孤独摇滚原声集');
  const variant = MediaVariant(
    id: 'v_ost_01',
    workId: 'w_ost',
    sourceId: 'src_1',
    relativePath: 'OST/01.flac',
    fileName: '01.flac',
    fileSize: 30 * 1024 * 1024,
    assetKind: AssetKind.cdAlbum,
  );
  return AudioPlaybackState(
    isActive: true,
    isPlaying: true,
    currentIndex: 0,
    positionSeconds: 42.0,
    durationSeconds: 210.0,
    cover: MemoryAudioCover(_samplePng),
    queue: const [
      AudioQueueItem(
        id: 'trk_01',
        title: '青春コンプレックス',
        albumTitle: '結束バンド',
        work: work,
        variant: variant,
      ),
    ],
  );
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  group('阶段 4：音视频可拖拽悬浮小窗全端五视口 × 双主题验收测试', () {
    for (final vp in _fiveViewports) {
      for (final themeMode in [ThemeMode.dark, ThemeMode.light]) {
        final modeLabel = themeMode == ThemeMode.dark ? '深色' : '浅色';
        testWidgets(
          '${vp.label} ($modeLabel)：规格一致性、安全区拖拽吸附、零宿主重建与两段式 × 单击分流',
          (tester) async {
            debugDefaultTargetPlatformOverride = vp.android
                ? TargetPlatform.android
                : TargetPlatform.windows;
            addTearDown(() => debugDefaultTargetPlatformOverride = null);
            tester.view.physicalSize = vp.size;
            tester.view.devicePixelRatio = 1.0;
            addTearDown(tester.view.reset);

            late _StubAudioNotifier audioNotifier;
            var hostBuilds = 0;

            final container = ProviderContainer(
              overrides: [
                tmdbImageLoaderProvider.overrideWithValue(
                  (_, {targetWidth, imageSize}) async => _samplePng,
                ),
                audioPlaybackProvider.overrideWith((ref) {
                  audioNotifier = _StubAudioNotifier(
                    ref,
                    _buildSampleAudioState(),
                  );
                  return audioNotifier;
                }),
              ],
            );
            addTearDown(container.dispose);

            await tester.pumpWidget(
              UncontrolledProviderScope(
                container: container,
                child: MaterialApp(
                  navigatorKey: container.read(rootNavigatorKeyProvider),
                  navigatorObservers: [
                    container.read(rootRouteObserverProvider),
                  ],
                  theme: KonataTheme.lightTheme(),
                  darkTheme: KonataTheme.darkTheme(),
                  themeMode: themeMode,
                  locale: const Locale('zh', 'CN'),
                  supportedLocales: const [Locale('zh', 'CN')],
                  localizationsDelegates: GlobalMaterialLocalizations.delegates,
                  builder: (context, child) => MediaQuery(
                    data: MediaQuery.of(context).copyWith(
                      padding: vp.safe,
                      viewPadding: vp.safe,
                    ),
                    child: MiniAudioOverlayHost(child: child!),
                  ),
                  home: _HostTestShell(onHostBuild: () => hostBuilds += 1),
                ),
              ),
            );
            await tester.pumpAndSettle();

            final miniFinder = find.byKey(
              const ValueKey('konata_floating_mini_player'),
            );
            expect(miniFinder, findsOneWidget);

            // 1. 音频小窗：1:1 正方形纯封面（144dp）+ 底部三键（48dp 高），无曲名、无循环键
            final audioRect = tester.getRect(miniFinder);
            expect(
              audioRect.width,
              closeTo(KonataPlaybackTokens.floatingMiniAudioCoverSize, 0.5),
            );
            expect(
              audioRect.height,
              closeTo(KonataPlaybackTokens.floatingMiniAudioTotalHeight, 0.5),
            );
            expect(
              KonataPlaybackTokens.floatingMiniAudioCoverSize,
              equals(KonataPlaybackTokens.floatingMiniVideoHeight),
            );
            expect(find.text('青春コンプレックス'), findsNothing);
            expect(find.byIcon(Icons.repeat_rounded), findsNothing);
            expect(find.byIcon(Icons.trending_flat_rounded), findsNothing);

            // 音频三键等距排布且所有热区 >= 48dp，始终可直接点击
            final prevRect = tester.getRect(
              find.byKey(const ValueKey('floating_mini_audio_prev')),
            );
            final playRect = tester.getRect(
              find.byKey(const ValueKey('floating_mini_audio_play_pause')),
            );
            final nextRect = tester.getRect(
              find.byKey(const ValueKey('floating_mini_audio_next')),
            );
            for (final r in [prevRect, playRect, nextRect]) {
              expect(r.width, greaterThanOrEqualTo(48.0));
              expect(r.height, greaterThanOrEqualTo(48.0));
            }
            expect(
              ((playRect.center.dx - prevRect.center.dx) -
                      (nextRect.center.dx - playRect.center.dx))
                  .abs(),
              lessThan(0.5),
            );
            await tester.tap(
              find.byKey(const ValueKey('floating_mini_audio_prev')),
            );
            await tester.tap(
              find.byKey(const ValueKey('floating_mini_audio_next')),
            );
            expect(audioNotifier.prevCount, equals(1));
            expect(audioNotifier.nextCount, equals(1));
            expect(container.read(immersiveAudioExpandedProvider), isFalse);

            // 2. 拖拽边界与零宿主重建：向左上越界拖动时严格钳制在安全区内，松手吸附且不压住导航胶囊
            final buildsBeforeDrag = hostBuilds;
            final gesture = await tester.startGesture(audioRect.topLeft + const Offset(24, 24));
            await gesture.moveBy(const Offset(-900, -900));
            await tester.pump();
            // 拖拽途中宿主壳层 0 重建
            expect(hostBuilds, equals(buildsBeforeDrag));
            final clampedDragRect = tester.getRect(miniFinder);
            final minTopAllowed = !vp.android
                ? KonataPlaybackTokens.floatingMiniDesktopTopBarClearance +
                      KonataPlaybackTokens.floatingMiniEdgeMargin
                : vp.safe.top + KonataPlaybackTokens.floatingMiniEdgeMargin;
            expect(
              clampedDragRect.left,
              greaterThanOrEqualTo(vp.safe.left + 11.5),
            );
            expect(
              clampedDragRect.top,
              greaterThanOrEqualTo(minTopAllowed - 0.5),
            );

            // 再拖向底部中央导航区松手，验证自动吸附到安全边缘且绝不压住导航胶囊
            await gesture.moveBy(Offset(vp.size.width * 0.45, vp.size.height));
            await tester.pump();
            await gesture.up();
            await tester.pumpAndSettle();

            final snappedRect = tester.getRect(miniFinder);
            expect(snappedRect.left, greaterThanOrEqualTo(vp.safe.left));
            expect(
              snappedRect.right,
              lessThanOrEqualTo(vp.size.width - vp.safe.right + 0.5),
            );
            expect(
              snappedRect.bottom,
              lessThanOrEqualTo(vp.size.height - vp.safe.bottom + 0.5),
            );
            if (vp.android) {
              final navRect = tester.getRect(find.byType(CapsuleNavigation));
              expect(snappedRect.overlaps(navRect), isFalse);
            }

            // 3. 默认纯净态 -> 轻触显现 × 与展开图标（热区 >= 48dp） -> 3 秒无操作自动隐藏 -> × 关闭
            expect(
              find.byKey(const ValueKey('floating_mini_close_button')),
              findsNothing,
            );
            expect(
              find.byKey(const ValueKey('floating_mini_expand_button')),
              findsNothing,
            );
            await tester.tap(
              find.byKey(const ValueKey('floating_mini_surface_tap_target')),
            );
            await tester.pump();
            final closeFinder = find.byKey(
              const ValueKey('floating_mini_close_button'),
            );
            final expandFinder = find.byKey(
              const ValueKey('floating_mini_expand_button'),
            );
            expect(closeFinder, findsOneWidget);
            expect(expandFinder, findsOneWidget);
            expect(tester.getRect(closeFinder).width, greaterThanOrEqualTo(48));
            expect(
              tester.getRect(closeFinder).height,
              greaterThanOrEqualTo(48),
            );
            expect(
              tester.getRect(expandFinder).width,
              greaterThanOrEqualTo(48),
            );
            expect(
              tester.getRect(expandFinder).height,
              greaterThanOrEqualTo(48),
            );

            // 满 3 秒自动隐藏角标
            await tester.pump(const Duration(seconds: 3));
            expect(closeFinder, findsNothing);

            // 再次轻触唤出 × 后点击 × 立即停止并关闭小窗
            await tester.tap(
              find.byKey(const ValueKey('floating_mini_surface_tap_target')),
            );
            await tester.pump();
            await tester.tap(closeFinder);
            await tester.pumpAndSettle();
            expect(audioNotifier.stopCloseCount, equals(1));
            expect(miniFinder, findsNothing);
            debugDefaultTargetPlatformOverride = null;
          },
        );
      }
    }

    testWidgets(
      '视频 16:9 悬浮小窗跨页面推入弹出与展开/收起保持同一解码会话与同一硬件表面 State 实例',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        tester.view.physicalSize = const Size(768, 1024);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final req = _buildSampleVideoRequest();
        var constructCount = 0;
        var closeCount = 0;

        final container = ProviderContainer(
          overrides: [
            tmdbImageLoaderProvider.overrideWithValue(
              (_, {targetWidth, imageSize}) async => _samplePng,
            ),
            videoPlaybackProvider(req).overrideWith(
              (ref) => _StubVideoController(
                ref,
                req,
                onConstructed: () => constructCount += 1,
                onClosed: () => closeCount += 1,
              ),
            ),
          ],
        );
        addTearDown(container.dispose);

        late BuildContext rootPageCtx;
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              navigatorKey: container.read(rootNavigatorKeyProvider),
              navigatorObservers: [container.read(rootRouteObserverProvider)],
              theme: KonataTheme.darkTheme(),
              locale: const Locale('zh', 'CN'),
              supportedLocales: const [Locale('zh', 'CN')],
              localizationsDelegates: GlobalMaterialLocalizations.delegates,
              builder: (_, child) => MiniAudioOverlayHost(child: child!),
              home: Scaffold(
                body: Builder(
                  builder: (ctx) {
                    rootPageCtx = ctx;
                    return const Center(child: Text('一级页面'));
                  },
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        await container.read(activeVideoSessionProvider.notifier).openVideo(req);
        await tester.pumpAndSettle();
        expect(find.byType(EmbeddedVideoPage), findsOneWidget);
        expect(constructCount, equals(1));
        expect(closeCount, equals(0));

        final fullSurfaceState = tester.state(
          find.byType(KonataHardwareVideoSurface),
        );

        // 收起至 16:9 悬浮小窗：控制器与硬件表面 State 实例均完全相同
        await container.read(activeVideoSessionProvider.notifier).collapseToMini();
        await tester.pumpAndSettle();
        expect(find.byType(EmbeddedVideoPage), findsNothing);
        final miniFinder = find.byKey(
          const ValueKey('konata_floating_mini_player'),
        );
        expect(miniFinder, findsOneWidget);
        final miniRect = tester.getRect(miniFinder);
        expect(miniRect.width / miniRect.height, closeTo(16.0 / 9.0, 0.01));
        expect(
          identical(
            tester.state(find.byType(KonataHardwareVideoSurface)),
            fullSurfaceState,
          ),
          isTrue,
        );
        expect(constructCount, equals(1));
        expect(closeCount, equals(0));

        // 推入二级页面再弹出：视频悬浮小窗持续跨页挂载，零会话重建
        unawaited(
          Navigator.of(rootPageCtx).push<void>(
            MaterialPageRoute<void>(
              builder: (_) => const Scaffold(body: Center(child: Text('二级详情页'))),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('二级详情页'), findsOneWidget);
        expect(miniFinder, findsOneWidget);
        expect(
          identical(
            tester.state(find.byType(KonataHardwareVideoSurface)),
            fullSurfaceState,
          ),
          isTrue,
        );

        Navigator.of(rootPageCtx).pop();
        await tester.pumpAndSettle();
        expect(miniFinder, findsOneWidget);

        // 两段式轻触画面中心回到全屏，解码会话标识与硬件表面 State 依旧不变
        await tester.tap(
          find.byKey(const ValueKey('floating_mini_surface_tap_target')),
        );
        await tester.pump();
        await tester.tap(
          find.byKey(const ValueKey('floating_mini_surface_tap_target')),
        );
        await tester.pumpAndSettle();
        expect(find.byType(EmbeddedVideoPage), findsOneWidget);
        expect(
          identical(
            tester.state(find.byType(KonataHardwareVideoSurface)),
            fullSurfaceState,
          ),
          isTrue,
        );
        expect(constructCount, equals(1));
        expect(closeCount, equals(0));

        await container.read(activeVideoSessionProvider.notifier).closeVideo();
        await tester.pumpAndSettle();
        expect(closeCount, equals(1));
        debugDefaultTargetPlatformOverride = null;
      },
    );

    testWidgets(
      '根路由模态层遮盖验证：完整列表、并入已有作品、管理系列编组、媒体源目录选择、齿轮菜单与底部抽屉均盖住小窗并屏蔽小窗触控',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        tester.view.physicalSize = const Size(768, 1024);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final db = KonataDatabase(NativeDatabase.memory());
        addTearDown(() async => tester.runAsync(db.close));
        final repo = DriftLibraryRepository(db);

        const src = MediaSource(
          id: 'src_1',
          label: 'dav (192.168.1.178)',
          kind: MediaSourceKind.webdav,
          location: 'http://192.168.1.178:29798/dav',
        );
        const workA = Work(
          id: 'w_a',
          title: '加速世界',
          scrapeStatus: ScrapeStatus.matched,
          seriesId: 'ser_1',
          seriesOrder: 1,
        );
        const workB = Work(
          id: 'w_b',
          title: '加速世界 INFINITE BURST',
          scrapeStatus: ScrapeStatus.matched,
        );
        const ep1 = Episode(
          id: 'ep_1',
          workId: 'w_a',
          seasonNumber: 1,
          episodeNumber: 1,
          title: '加速',
        );
        const var1 = MediaVariant(
          id: 'var_1',
          workId: 'w_a',
          episodeId: 'ep_1',
          sourceId: 'src_1',
          relativePath: 'Accel/01.mkv',
          fileName: '01.mkv',
          fileSize: 1024,
        );
        await tester.runAsync(() async {
          await repo.upsertMediaSource(src);
          await repo.upsertSeriesGroup(
            SeriesGroup(
              id: 'ser_1',
              title: '加速世界系列',
              createdAt: DateTime(2026, 1, 1),
              updatedAt: DateTime(2026, 1, 1),
            ),
          );
          await repo.upsertWork(workA);
          await repo.upsertWork(workB);
          await repo.upsertEpisode(ep1);
          await repo.upsertMediaVariant(var1);
        });

        const bundle = WorkDetailBundle(
          work: workA,
          episodes: [ep1],
          variants: [var1],
          sourcesById: {'src_1': src},
          latestPlayback: null,
          seriesMembers: [workA],
        );

        late _StubAudioNotifier audioNotifier;
        final container = ProviderContainer(
          overrides: [
            libraryRepositoryProvider.overrideWithValue(repo),
            konataActionsProvider.overrideWith(
              (ref) => _StubActionsCoordinator(ref),
            ),
            tmdbImageLoaderProvider.overrideWithValue(
              (_, {targetWidth, imageSize}) async => _samplePng,
            ),
            audioPlaybackProvider.overrideWith((ref) {
              audioNotifier = _StubAudioNotifier(ref, _buildSampleAudioState());
              return audioNotifier;
            }),
          ],
        );
        addTearDown(container.dispose);

        late BuildContext pageCtx;
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              navigatorKey: container.read(rootNavigatorKeyProvider),
              navigatorObservers: [container.read(rootRouteObserverProvider)],
              theme: KonataTheme.darkTheme(),
              locale: const Locale('zh', 'CN'),
              supportedLocales: const [Locale('zh', 'CN')],
              localizationsDelegates: GlobalMaterialLocalizations.delegates,
              builder: (_, child) => MiniAudioOverlayHost(child: child!),
              home: Scaffold(
                body: Builder(
                  builder: (ctx) {
                    pageCtx = ctx;
                    return Align(
                      alignment: Alignment.topRight,
                      child: DetailOpsCapsule(
                        isExpanded: false,
                        hasContent: true,
                        onOpenFullList: () {},
                        onManualMatch: () {},
                        onManualEdit: () {},
                        onEditPoster: () {},
                        onEditBackdrop: () {},
                        onHideWork: () {},
                        onDeleteWork: () {},
                        onRescrape: () {},
                        onOpenLocalDir: () {},
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final miniFinder = find.byKey(
          const ValueKey('konata_floating_mini_player'),
        );
        final playPauseFinder = find.byKey(
          const ValueKey('floating_mini_audio_play_pause'),
        );
        expect(miniFinder.hitTestable(), findsOneWidget);
        expect(playPauseFinder.hitTestable(), findsOneWidget);

        Future<void> verifyModalOccludesMiniPlayer(
          String modalName,
          Future<void> Function() openModal,
        ) async {
          final togglesBefore = audioNotifier.toggleCount;
          await openModal();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 260));
          final observer = container.read(rootRouteObserverProvider);
          final nav = container.read(rootNavigatorKeyProvider).currentState;
          final diag =
              'observerNav=${identical(observer.navigator, nav)}, '
              'pages=${observer.pageRoutes.length}, '
              'modals=${observer.modalRoutes.length}, '
              'reg=${nav == null ? -1 : container.read(konataModalLayerRegistryProvider).routesFor(nav).length}';

          // 打开模态层期间，悬浮小窗位于 ModalBarrier 之下，hitTestable 必须为空！
          expect(
            miniFinder.hitTestable(),
            findsNothing,
            reason: '$modalName 打开时必须盖住悬浮小窗并阻断其命中测试 ($diag)',
          );
          expect(
            playPauseFinder.hitTestable(),
            findsNothing,
            reason: '$modalName 打开时悬浮小窗播放键不得可点击穿透',
          );
          expect(audioNotifier.toggleCount, equals(togglesBefore));

          Navigator.of(pageCtx, rootNavigator: true).pop();
          await tester.pumpAndSettle();

          // 关闭模态层后，悬浮小窗立即恢复可触控
          expect(
            playPauseFinder.hitTestable(),
            findsOneWidget,
            reason: '$modalName 关闭后悬浮小窗应恢复触控',
          );
        }

        // 1. 完整列表弹窗
        await verifyModalOccludesMiniPlayer('完整列表弹窗', () async {
          unawaited(
            DetailFullListDialog.show(
              pageCtx,
              bundle: bundle,
              imageLoader: (_, {targetWidth, imageSize}) async => _samplePng,
              initialTab: DetailDrawerTab.main,
              onEpisodeTap: (_) {},
              onEpisodeAdjustSlot: (_) {},
            ),
          );
        });

        // 2. 并入已有作品弹窗
        await verifyModalOccludesMiniPlayer('并入已有作品弹窗', () async {
          unawaited(
            showKonataGlassDialog<void>(
              context: pageCtx,
              builder: (_) => const WorkMergeTargetDialog(
                sourceWorkId: 'w_a',
                sourceWorkTitle: '加速世界',
              ),
            ),
          );
        });

        // 3. 管理系列编组弹窗
        await verifyModalOccludesMiniPlayer('管理系列编组弹窗', () async {
          unawaited(
            showKonataGlassDialog<void>(
              context: pageCtx,
              builder: (_) => SeriesManageDialog(bundle: bundle),
            ),
          );
        });

        // 4. 媒体源目录选择弹窗
        await verifyModalOccludesMiniPlayer('媒体源目录选择弹窗', () async {
          unawaited(
            showKonataGlassDialog<void>(
              context: pageCtx,
              builder: (_) => const SourceFolderPickerDialog(source: src),
            ),
          );
        });

        // 5. 底部毛玻璃抽屉
        await verifyModalOccludesMiniPlayer('公共底部毛玻璃抽屉', () async {
          unawaited(
            showKonataGlassBottomSheet<void>(
              context: pageCtx,
              title: '排序与筛选',
              builder: (_) => const SizedBox(height: 120),
            ),
          );
        });

        // 6. 详情页齿轮弹出菜单
        await verifyModalOccludesMiniPlayer('详情页齿轮菜单', () async {
          await tester.tap(find.byTooltip('作品管理选项'));
        });
        debugDefaultTargetPlatformOverride = null;
      },
    );
  });
}
