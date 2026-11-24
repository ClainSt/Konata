import 'package:feature_player_video/feature_player_video.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_design_system/konata_design_system.dart';

import 'support/video_test_harness.dart';

void main() {
  group('EmbeddedVideoPage 舞台渲染、控制层自隐与动态侧栏贡献', () {
    testWidgets('未注入自定义画面构建器时优雅展示占位舞台并在 3 秒播放无操作后隐藏控制层', (
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

      expect(
        find.byKey(const ValueKey('custom_host_surface')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('embedded_video_placeholder_stage')),
        findsNothing,
      );

      // 切换探针浮层开关验证技术信息浮层显隐。
      await tester.tap(
        find.byKey(const ValueKey('video_probe_toggle_button')),
      );
      await tester.pump();
      expect(
        find.byKey(const ValueKey('video_probe_overlay')),
        findsOneWidget,
      );

      // 打开右侧栏，验证仅挂载了支持 video 模式的贡献，过滤掉 audio 贡献。
      await tester.tap(
        find.byKey(const ValueKey('video_episodes_sheet_button')),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('video_side_sheet')), findsOneWidget);
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

      final probeFinder = find.text('检测同步组件状态');
      await tester.ensureVisible(probeFinder);
      await tester.pump();
      await tester.tap(probeFinder);
      await tester.pumpAndSettle();
      expect(find.text('同步组件已就绪并在本地端口 8880 连通'), findsOneWidget);
    });
  });
}
