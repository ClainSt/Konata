import 'package:engine_playback/engine_playback.dart';
import 'package:feature_player_video/feature_player_video.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_design_system/konata_design_system.dart';

import 'support/video_test_harness.dart';

void main() {
  group('EmbeddedVideoPage 舞台渲染、控制层自隐与动态侧栏贡献', () {
    testWidgets('未注入自定义画面构建器时优雅展示占位舞台并在 3 秒播放无操作后隐藏控制层', (tester) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final harness = await VideoTestHarness.create();
      addTearDown(harness.dispose);
      final seeded = await harness.seedSampleAnime();
      final controller = harness.createController(enablePeriodicTimers: false);
      addTearDown(controller.dispose);

      await controller.initialize(VideoLaunchRequest(workId: seeded.work.id));
      controller.handleDurationUpdate(1000.0);

      await tester.pumpWidget(
        wrapVideoTestApp(
          child: EmbeddedVideoPage(
            request: VideoLaunchRequest(workId: seeded.work.id),
            controller: controller,
            autoHideDelay: const Duration(seconds: 3),
          ),
        ),
      );
      await tester.pump();

      expect(
        find.byKey(const ValueKey('embedded_video_placeholder_stage')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('embedded_video_top_bar')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('video_capsule_progress_rail')),
        findsOneWidget,
      );

      // 暂停状态下经过 5 秒也不会自动隐藏控制条。
      await tester.pump(const Duration(seconds: 5));
      expect(
        find.byKey(const ValueKey('embedded_video_top_bar')),
        findsOneWidget,
      );

      // 开始播放后经过 3 秒无操作，控制层自动隐藏并卸载高频进度监听器。
      await controller.setPlaying(true);
      await tester.pump();
      await tester.pump(const Duration(seconds: 3, milliseconds: 100));

      expect(
        find.byKey(const ValueKey('embedded_video_top_bar')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('video_capsule_progress_rail')),
        findsNothing,
      );

      // 暂停播放后立即重新唤醒控制栏。
      await controller.setPlaying(false);
      await tester.pump();
      expect(
        find.byKey(const ValueKey('embedded_video_top_bar')),
        findsOneWidget,
      );
    });

    testWidgets('支持自定义画面构建器并动态挂载视频模式 PlayerSidePanelContribution', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final harness = await VideoTestHarness.create();
      addTearDown(harness.dispose);
      final seeded = await harness.seedSampleAnime();
      final controller = harness.createController(enablePeriodicTimers: false);
      addTearDown(controller.dispose);

      await controller.initialize(VideoLaunchRequest(workId: seeded.work.id));

      final videoContrib = PlayerSidePanelContribution(
        id: 'mock_video_danmaku',
        label: '弹幕控制',
        iconKey: 'subtitles',
        order: 10,
        supportedModes: const <PlayerMediaMode>{PlayerMediaMode.video},
        viewBuilder: (slot) => Center(
          key: const ValueKey('mock_video_contrib_body'),
          child: Text('扩展侧栏 · ${slot.workId?.value}'),
        ),
      );
      final audioOnlyContrib = PlayerSidePanelContribution(
        id: 'mock_audio_lyrics',
        label: '纯音乐歌词',
        iconKey: 'lyrics',
        order: 20,
        supportedModes: const <PlayerMediaMode>{PlayerMediaMode.audio},
        viewBuilder: (_) => const SizedBox.shrink(),
      );

      await tester.pumpWidget(
        wrapVideoTestApp(
          child: EmbeddedVideoPage(
            request: VideoLaunchRequest(workId: seeded.work.id),
            controller: controller,
            playerSidePanels: <PlayerSidePanelContribution>[
              videoContrib,
              audioOnlyContrib,
            ],
            videoSurfaceBuilder: (context, textureId) => Container(
              key: const ValueKey('custom_host_surface'),
              color: KonataPlaybackTokens.cinemaPureBlack,
              child: Center(child: Text('宿主画面 $textureId')),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.byKey(const ValueKey('custom_host_surface')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('embedded_video_placeholder_stage')),
        findsNothing,
      );

      // 切换探针浮层开关验证技术信息浮层显隐。
      await tester.tap(find.byKey(const ValueKey('video_probe_toggle_button')));
      await tester.pump();
      expect(find.byKey(const ValueKey('video_probe_overlay')), findsOneWidget);

      // 打开右侧栏，验证仅挂载了支持 video 模式的贡献，过滤掉 audio 贡献。
      await tester.tap(
        find.byKey(const ValueKey('video_episodes_sheet_button')),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('video_side_sheet')), findsOneWidget);
      expect(find.text('播放控制台'), findsOneWidget);
      expect(find.byType(KonataSegmentedCapsule<String>), findsOneWidget);
      await tester.tap(find.text('画面'));
      await tester.pumpAndSettle();
      expect(find.text('渲染画质与解码策略'), findsOneWidget);
      expect(find.text('硬件视频解码'), findsOneWidget);
      expect(find.text('去色带滤镜 (Deband)'), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(
        find.byKey(const ValueKey('side_sheet_tab_contrib_mock_video_danmaku')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('side_sheet_tab_contrib_mock_audio_lyrics')),
        findsNothing,
      );

      await tester.tap(
        find.byKey(const ValueKey('side_sheet_tab_contrib_mock_video_danmaku')),
      );
      await tester.pump();
      expect(
        find.byKey(const ValueKey('mock_video_contrib_body')),
        findsOneWidget,
      );
    });
  });

  group('设置面板组件渲染与交互验证', () {
    testWidgets('SettingsPlayersPanel 与 SettingsExternalToolsPanel 正常渲染交互', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final harness = await VideoTestHarness.create();
      addTearDown(harness.dispose);
      final deps = harness.buildDependencies();

      await tester.pumpWidget(
        wrapVideoTestApp(
          dependencies: deps,
          child: const SingleChildScrollView(
            child: Column(
              children: [
                SettingsPlayersPanel(),
                SizedBox(height: 16),
                SettingsExternalToolsPanel(),
              ],
            ),
          ),
        ),
      );
      await tester.pump();

      expect(
        find.byKey(const ValueKey('settings_players_panel')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('settings_external_tools_panel')),
        findsOneWidget,
      );

      final autoSkipFinder = find.byKey(
        const ValueKey('settings_auto_skip_switch'),
      );
      await tester.ensureVisible(autoSkipFinder);
      await tester.tap(autoSkipFinder);
      await tester.pump();
      expect(harness.preferencesStore.read().autoSkipChapters, isTrue);

      expect(find.text('外部视频播放器与热接力'), findsOneWidget);
      expect(find.text('外部音频播放器'), findsOneWidget);
      expect(find.text('待配置 foobar2000 路径'), findsOneWidget);
      expect(find.text('浏览'), findsNWidgets(3));
      final probeFinder = find.text('检测连接');
      await tester.ensureVisible(probeFinder);
      await tester.pump();
      await tester.tap(probeFinder);
      await tester.pumpAndSettle();
      expect(find.text('已连接 foo_beefweb (8880)'), findsOneWidget);
      tester.view.physicalSize = const Size(640, 700);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  group('Wave 2 第十节视频精修契约与三端横屏零溢出回归', () {
    testWidgets('顶底单层毛玻璃胶囊保留桌面窗口三键且底栏显隐联动字幕 sub-pos 避让', (tester) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final harness = await VideoTestHarness.create();
      addTearDown(harness.dispose);
      final seeded = await harness.seedSampleAnime();
      final fakeClient = FakeLibMpvClient();
      var clientCount = 0;
      final controller = harness.createController(
        libMpvClientFactory: () {
          clientCount++;
          return clientCount == 1 ? fakeClient : FakeLibMpvClient();
        },
        enablePeriodicTimers: false,
      );
      addTearDown(controller.dispose);

      await controller.initialize(VideoLaunchRequest(workId: seeded.work.id));
      controller.handleDurationUpdate(1200.0);

      bool? capturedForceLightIcons;
      var dragWrapCalled = false;

      await tester.pumpWidget(
        KonataDesktopWindowChromeScope(
          windowControlsBuilder:
              ({bool forceLightIcons = false, bool showGlassPill = false}) {
                capturedForceLightIcons = forceLightIcons;
                return const SizedBox(
                  key: ValueKey('mock_desktop_window_controls'),
                  width: 96,
                  height: 30,
                );
              },
          dragToMoveBuilder: ({required Widget child}) {
            dragWrapCalled = true;
            return child;
          },
          child: wrapVideoTestApp(
            child: EmbeddedVideoPage(
              request: VideoLaunchRequest(workId: seeded.work.id),
              controller: controller,
              autoHideDelay: const Duration(seconds: 3),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(capturedForceLightIcons, isTrue);
      expect(dragWrapCalled, isTrue);
      expect(
        find.byKey(const ValueKey('mock_desktop_window_controls')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('video_audio_only_button')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('video_top_video_sheet_button')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('video_capsule_screenshot_button')),
        findsOneWidget,
      );

      final capsuleRect = tester.getRect(
        find.byKey(const ValueKey('embedded_video_bottom_capsule')),
      );
      expect(capsuleRect.height, closeTo(60.0, 0.5));

      final centerTransportRect = tester.getRect(
        find.byKey(const ValueKey('video_capsule_center_transport')),
      );
      expect(
        (centerTransportRect.center.dx - capsuleRect.center.dx).abs(),
        lessThan(1.0),
      );

      // 底部胶囊可见时，按 20dp 底边距 + 60dp 胶囊高 + 16dp 留白自动抬升常规字幕。
      const expectedLift = (20.0 + 60.0 + 16.0) / 720.0 * 100.0;
      expect(
        controller.currentSubtitleHudLiftPercent,
        closeTo(expectedLift, 0.25),
      );
      expect(
        fakeClient.properties['sub-pos'] as double,
        closeTo(100.0 - expectedLift, 0.35),
      );
      expect(fakeClient.options['sub-ass-override'], 'no');

      // 播放后经过 3 秒自动隐藏控制层，字幕抬升立即归零复原。
      await controller.setPlaying(true);
      await tester.pump();
      await tester.pump(const Duration(seconds: 3, milliseconds: 100));

      expect(
        find.byKey(const ValueKey('embedded_video_bottom_capsule')),
        findsNothing,
      );
      expect(controller.currentSubtitleHudLiftPercent, 0.0);
      expect(fakeClient.properties['sub-pos'] as double, closeTo(100.0, 0.05));

      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      await tester.pump();
    });

    testWidgets('顶边平齐 y=0 圆角倒三角章节点、居中播放头圆点与磁吸预览浮泡对齐', (tester) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final harness = await VideoTestHarness.create();
      addTearDown(harness.dispose);
      final seeded = await harness.seedSampleAnime();
      final controller = harness.createController(enablePeriodicTimers: false);
      addTearDown(controller.dispose);

      await controller.initialize(VideoLaunchRequest(workId: seeded.work.id));
      controller.handleDurationUpdate(1200.0);
      controller.handlePositionUpdate(240.0);

      const chapters = <PlaybackChapter>[
        PlaybackChapter(
          index: 0,
          title: '序章',
          startSeconds: 0.0,
          endSeconds: 120.0,
        ),
        PlaybackChapter(
          index: 1,
          title: 'OP',
          startSeconds: 120.0,
          endSeconds: 600.0,
        ),
        PlaybackChapter(
          index: 2,
          title: '正片 B',
          startSeconds: 600.0,
          endSeconds: 1200.0,
        ),
      ];

      await tester.pumpWidget(
        wrapVideoTestApp(
          child: Center(
            child: VideoPlaybackCapsule(
              isPlaying: true,
              hasPreviousEpisode: true,
              hasNextEpisode: true,
              speed: 1.0,
              volume: 80.0,
              isMuted: false,
              isFullscreen: false,
              positionListenable: controller.positionNotifier,
              durationListenable: controller.durationNotifier,
              bufferedListenable: controller.bufferedNotifier,
              chapters: chapters,
              onTogglePlayPause: () {},
              onSeek: (sec) => controller.handlePositionUpdate(sec),
              onPreviousEpisode: () {},
              onNextEpisode: () {},
              onSelectSpeed: (_) {},
              onVolumeChanged: (_) {},
              onToggleMute: () {},
              onOpenEpisodesSheet: () {},
              onOpenSubtitlesSheet: () {},
              onOpenAudioSheet: () {},
              onOpenVideoSheet: () {},
              onToggleFullscreen: () {},
            ),
          ),
        ),
      );
      await tester.pump();

      expect(
        find.byKey(const ValueKey('konata_chapter_diamond_1')),
        findsNothing,
      );
      final railFinder = find.byKey(
        const ValueKey('video_capsule_progress_rail'),
      );
      final railRect = tester.getRect(railFinder);
      final chapter1Finder = find.byKey(
        const ValueKey('video_chapter_marker_1'),
      );
      final chapter2Finder = find.byKey(
        const ValueKey('video_chapter_marker_2'),
      );
      expect(chapter1Finder, findsOneWidget);
      expect(chapter2Finder, findsOneWidget);

      // 倒三角章节点顶边严格与进度条顶边 y=0 平齐，零向上凸起。
      final chapter1Rect = tester.getRect(chapter1Finder);
      expect(chapter1Rect.top, closeTo(railRect.top, 0.01));
      expect(chapter1Rect.width, closeTo(10.0, 0.01));
      expect(chapter1Rect.height, closeTo(7.5, 0.01));

      // 鼠标悬停靠近第 2 章（600s = 50% 位置）触发磁吸、放大 1.28x、显示缩略图浮泡并居中播放头圆点。
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(gesture.removePointer);
      await gesture.addPointer(location: Offset.zero);
      final nearChapter2 = Offset(
        railRect.left + railRect.width * 0.5 + 3.0,
        railRect.top + 3.0,
      );
      await gesture.moveTo(nearChapter2);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 220));

      final thumbFinder = find.byKey(
        const ValueKey('video_capsule_playhead_thumb'),
      );
      expect(thumbFinder, findsOneWidget);
      final thumbRect = tester.getRect(thumbFinder);
      // 播放头圆心严格垂直居中对齐悬停态 4.5px 轨道中心线（dy = 2.25）。
      expect(
        thumbRect.center.dy - railRect.top,
        closeTo(VideoPlaybackCapsule.railHoverHeight * 0.5, 0.2),
      );

      // 磁吸放大后倒三角顶边仍严格锁定在 y=0。
      final scaledWidget = tester.widget<AnimatedScale>(
        find.ancestor(of: chapter2Finder, matching: find.byType(AnimatedScale)),
      );
      expect(scaledWidget.scale, closeTo(1.28, 0.01));
      expect(scaledWidget.alignment, Alignment.topCenter);
      expect(tester.getRect(chapter2Finder).top, closeTo(railRect.top, 0.05));

      final previewBubble = find.byKey(
        const ValueKey('video_thumbnail_preview_bubble'),
      );
      expect(previewBubble, findsOneWidget);
      expect(find.text('正片 B'), findsOneWidget);
      expect(find.text('10:00'), findsOneWidget);

      // 点击靠近章节起点应磁吸精确跳转至 600s。
      await tester.tapAt(nearChapter2);
      await tester.pump();
      expect(controller.positionNotifier.value.inSeconds, 600);
    });

    testWidgets('Android 手机与平板强制锁定纯横屏并在退出销毁恢复原方向，触屏锁与三端横屏视口零溢出', (
      tester,
    ) async {
      final orientationCalls = <Object?>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'SystemChrome.setPreferredOrientations') {
              orientationCalls.add(call.arguments);
            }
            return null;
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null);
      });

      final viewports = <({KonataPlatform platform, Size size})>[
        (platform: KonataPlatform.androidPhone, size: const Size(810, 386)),
        (platform: KonataPlatform.androidPhone, size: const Size(667, 375)),
        (platform: KonataPlatform.androidTablet, size: const Size(1024, 700)),
        (platform: KonataPlatform.windows, size: const Size(1440, 900)),
      ];

      for (final entry in viewports) {
        orientationCalls.clear();
        tester.view.physicalSize = entry.size;
        tester.view.devicePixelRatio = 1.0;

        final harness = await VideoTestHarness.create(platform: entry.platform);
        final seeded = await harness.seedSampleAnime();
        final controller = harness.createController(
          enablePeriodicTimers: false,
        );
        await controller.initialize(VideoLaunchRequest(workId: seeded.work.id));
        controller.handleDurationUpdate(1000.0);

        await tester.pumpWidget(
          wrapVideoTestApp(
            child: EmbeddedVideoPage(
              request: VideoLaunchRequest(workId: seeded.work.id),
              controller: controller,
              autoHideDelay: const Duration(seconds: 3),
            ),
          ),
        );
        await tester.pump();
        expect(tester.takeException(), isNull);

        if (entry.platform != KonataPlatform.windows) {
          expect(harness.hostWindow.preferredLandscape, isTrue);
          expect(orientationCalls.last, <String>[
            'DeviceOrientation.landscapeLeft',
            'DeviceOrientation.landscapeRight',
          ]);

          // 验证触屏左侧防误触锁钮仅在触屏端显示，并控制底栏与字幕抬升。
          final lockFinder = find.byKey(
            const ValueKey('video_screen_lock_button'),
          );
          expect(lockFinder, findsOneWidget);
          await tester.tap(lockFinder);
          await tester.pump();
          expect(
            find.byKey(const ValueKey('embedded_video_bottom_capsule')),
            findsNothing,
          );
          expect(controller.currentSubtitleHudLiftPercent, 0.0);

          await tester.tap(lockFinder);
          await tester.pump();
          expect(
            find.byKey(const ValueKey('embedded_video_bottom_capsule')),
            findsOneWidget,
          );
        } else {
          expect(orientationCalls, isEmpty);
          expect(
            find.byKey(const ValueKey('video_screen_lock_button')),
            findsNothing,
          );
        }

        // 验证三端横屏视口打开侧滑面板无溢出且底部避让停留在播控胶囊上方。
        await tester.tap(
          find.byKey(const ValueKey('video_episodes_sheet_button')),
        );
        await tester.pump();
        final sheetFinder = find.byKey(const ValueKey('video_side_sheet'));
        expect(sheetFinder, findsOneWidget, reason: 'viewport=${entry.size}');
        await tester.pumpAndSettle();
        final sheetRect = tester.getRect(
          find
              .descendant(of: sheetFinder, matching: find.byType(ClipRRect))
              .first,
        );
        final capsuleRect = tester.getRect(
          find.byKey(const ValueKey('embedded_video_bottom_capsule')),
        );
        expect(
          sheetRect.bottom,
          lessThanOrEqualTo(capsuleRect.top + 0.5),
          reason: '侧栏底边必须避让 52px 播控胶囊上方 (${entry.size})',
        );
        expect(tester.takeException(), isNull);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        if (entry.platform != KonataPlatform.windows) {
          expect(harness.hostWindow.preferredLandscape, isFalse);
          expect(orientationCalls.last, isEmpty);
        }

        controller.dispose();
        await harness.dispose();
      }

      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  });
}
