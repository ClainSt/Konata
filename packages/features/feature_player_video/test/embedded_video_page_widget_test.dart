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

    testWidgets('桌面置顶独立舞台与应用内悬浮模式共用原有播放实例', (tester) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final harness = await VideoTestHarness.create();
      addTearDown(harness.dispose);
      final seeded = await harness.seedSampleAnime();
      final clients = <FakeLibMpvClient>[];
      final controller = harness.createController(
        enablePeriodicTimers: false,
        libMpvClientFactory: () {
          final client = FakeLibMpvClient();
          clients.add(client);
          return client;
        },
      );
      addTearDown(controller.dispose);
      await controller.initialize(VideoLaunchRequest(workId: seeded.work.id));
      controller.handleDurationUpdate(1200);
      controller.handlePositionUpdate(320);
      final mpv = clients.first;
      final loads = mpv.commands.where((c) => c.first == 'loadfile').length;
      expect(loads, greaterThan(0));
      await tester.pumpWidget(
        wrapVideoTestApp(
          child: EmbeddedVideoPage(
            request: VideoLaunchRequest(workId: seeded.work.id),
            controller: controller,
            videoSurfaceBuilder: (_, _) =>
                const SizedBox.expand(key: ValueKey('shared_video_surface')),
          ),
        ),
      );
      await tester.pump();
      expect(clients.length, greaterThanOrEqualTo(2));
      for (final client in clients.skip(1)) {
        client.emitEvent(const MpvFileLoadedEvent());
      }
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('video_mini_mode_button')));
      await tester.pump();
      tester.view.physicalSize = const Size(360, 203);
      await tester.pump();
      expect(controller.state.miniMode, VideoMiniMode.desktop);
      expect(harness.hostWindow.desktopMiniMode, isTrue);
      expect(
        find.byKey(const ValueKey('video_desktop_mini_stage')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('shared_video_surface')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('embedded_video_top_bar')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('video_capsule_progress_rail')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('mini_player_expand_button')));
      tester.view.physicalSize = const Size(1280, 720);
      await tester.pump();
      expect(controller.state.miniMode, VideoMiniMode.stage);
      expect(harness.hostWindow.desktopMiniMode, isFalse);
      expect(
        find.byKey(const ValueKey('shared_video_surface')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('video_collapse_button')));
      await tester.pump();
      expect(controller.state.miniMode, VideoMiniMode.floating);
      expect(harness.hostWindow.desktopMiniMode, isFalse);
      expect(
        find.byKey(const ValueKey('video_floating_mini_player')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('shared_video_surface')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('mini_player_expand_button')));
      await tester.pump();
      expect(controller.state.miniMode, VideoMiniMode.stage);
      expect(controller.positionNotifier.value.inSeconds, 320);
      expect(mpv.commands.where((c) => c.first == 'loadfile').length, loads);
      expect(mpv.isDisposed, isFalse);
      expect(clients.first, same(mpv));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(tester.takeException(), isNull);
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
      expect(find.text('播放控制台'), findsNothing);
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

  testWidgets('播放侧栏与全局设置共享输出模式，透传与独占互斥', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final h = await VideoTestHarness.create();
    addTearDown(h.dispose);
    final seeded = await h.seedSampleAnime();
    final clients = <FakeLibMpvClient>[];
    final controller = h.createController(
      libMpvClientFactory: () {
        final client = FakeLibMpvClient();
        clients.add(client);
        return client;
      },
      enablePeriodicTimers: false,
    );
    addTearDown(controller.dispose);
    await controller.initialize(VideoLaunchRequest(workId: seeded.work.id));
    await tester.pumpWidget(
      wrapVideoTestApp(
        child: Stack(
          children: [
            VideoSideSheet(
              controller: controller,
              initialTab: VideoSideSheetTab.audio,
              onClose: () {},
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    final client = clients.first;
    for (final auxiliary in clients.skip(1)) {
      auxiliary.emitEvent(const MpvFileLoadedEvent());
    }
    await tester.pump();
    final route = find.byKey(const ValueKey('video_audio_route_mode'));
    await tester.ensureVisible(route);
    await tester.tap(route);
    await tester.pumpAndSettle();
    await tester.tap(find.text('HDMI / S/PDIF 透传').last);
    await tester.pumpAndSettle();
    expect(h.preferencesStore.read().bitstreamPassthrough, isTrue);
    expect(
      h.preferencesStore.read().qualityConfig.exclusiveAudioOutput,
      isFalse,
    );
    expect(
      client.properties['audio-spdif'],
      AudiophileSafetyPolicy.defaultSpdifCodecs,
    );
    expect(client.properties['af'], '');
    await tester.pumpWidget(
      wrapVideoTestApp(
        dependencies: h.buildDependencies(),
        child: const SingleChildScrollView(child: SettingsPlayersPanel()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(route);
    expect(
      tester.widget<KonataDropdown<AudioOutputRouteMode>>(route).value,
      AudioOutputRouteMode.bitstreamPassthrough,
    );
    await tester.tap(route);
    await tester.pumpAndSettle();
    await tester.tap(find.text('WASAPI 独占').last);
    await tester.pumpAndSettle();
    expect(h.preferencesStore.read().bitstreamPassthrough, isFalse);
    expect(
      h.preferencesStore.read().qualityConfig.exclusiveAudioOutput,
      isTrue,
    );
    expect(client.properties['audio-spdif'], '');
    expect(
      client.properties['af'],
      AudiophileSafetyPolicy.postDspSafetyLimiterFilter,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    await tester.pump(const Duration(seconds: 11));
    expect(tester.takeException(), isNull);
  });
  testWidgets('云字体同步偏好不自动授权，本机显式授权与撤销直接更新协调器', (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final h = await VideoTestHarness.create();
    addTearDown(h.dispose);
    final auth = CloudSubsetAuthorizationStore();
    final coordinator = CloudSubsetCoordinator(
      playbackEngine: h.engine,
      cloudClient: FontInAssCloudClient(
        authorizationStore: auth,
        storageRoot: h.storageRoot,
      ),
    );
    final endpoint = Uri.parse('http://127.0.0.1:54321/api/subset');
    final origin = CloudSubsetOrigin.fromUri(endpoint).key;
    h.preferencesStore.updateCloudSubsetSettings(
      enabled: true,
      endpointUrl: endpoint.toString(),
    );
    h.preferencesStore.authorizeCloudSubsetOrigin(origin);
    await tester.pumpWidget(
      wrapVideoTestApp(
        dependencies: h.buildDependencies(),
        child: SingleChildScrollView(
          child: SettingsPlayersPanel(cloudSubsetCoordinator: coordinator),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(auth.isAuthorized(endpoint), isFalse);
    expect(find.text('待本机授权'), findsOneWidget);
    final grant = find.text('本机授权');
    await tester.ensureVisible(grant);
    await tester.tap(grant);
    await tester.pumpAndSettle();
    expect(auth.isAuthorized(endpoint), isTrue);
    expect(find.text('本机已授权'), findsOneWidget);
    final revoke = find.text('撤销授权');
    await tester.ensureVisible(revoke);
    await tester.tap(revoke);
    await tester.pumpAndSettle();
    expect(auth.isAuthorized(endpoint), isFalse);
    expect(h.preferencesStore.read().authorizedCloudSubsetOrigins, isEmpty);
    final reset = find.byKey(
      const ValueKey('settings_cloud_subset_reset_default_button'),
    );
    await tester.ensureVisible(reset);
    await tester.tap(reset);
    await tester.pumpAndSettle();
    const defaultEndpoint = FontInAssCloudClient.defaultEndpointUrl;
    expect(h.preferencesStore.read().fontInAssEndpoint, defaultEndpoint);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is EditableText && widget.controller.text == defaultEndpoint,
      ),
      findsOneWidget,
    );
    expect(h.preferencesStore.read().authorizedCloudSubsetOrigins, isEmpty);
    expect(auth.isAuthorized(Uri.parse(defaultEndpoint)), isFalse);
    expect(tester.takeException(), isNull);
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
      var savedPort = 9090;
      var savedSkip = false;
      final deps = harness.buildDependencies(
        readAudioRelayPreferences: () =>
            (port: savedPort, skipGuide: savedSkip),
        writeAudioRelayPreferences: ({int? port, bool? skipGuide}) {
          if (port != null) savedPort = port;
          if (skipGuide != null) savedSkip = skipGuide;
        },
      );

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
      final portField = find.byKey(
        const ValueKey('settings_foobar_beefweb_port_field'),
      );
      await tester.ensureVisible(portField);
      expect(
        find.descendant(of: portField, matching: find.text('9090')),
        findsOneWidget,
      );
      await tester.enterText(
        find.descendant(of: portField, matching: find.byType(EditableText)),
        '8888',
      );
      await tester.pump();
      expect(savedPort, 8888);
      final guide = find.byKey(const ValueKey('external_skip_beefweb_guide'));
      await tester.ensureVisible(guide);
      await tester.tap(guide);
      await tester.pump();
      expect(savedSkip, isTrue);
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

  testWidgets('常速不常驻倍速入口，非正常倍速进入统一画面设置，原画菜单双模式调用实际控制器', (tester) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final harness = await VideoTestHarness.create();
    addTearDown(harness.dispose);
    final seeded = await harness.seedSampleAnime();
    final client = FakeLibMpvClient();
    var created = 0;
    final controller = harness.createController(
      libMpvClientFactory: () => created++ == 0 ? client : FakeLibMpvClient(),
      enablePeriodicTimers: false,
    );
    addTearDown(controller.dispose);
    await controller.initialize(VideoLaunchRequest(workId: seeded.work.id));
    controller.handleDurationUpdate(1200);
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
    final speedButton = find.byKey(const ValueKey('video_speed_button'));
    final screenshot = find.byKey(
      const ValueKey('video_capsule_screenshot_button'),
    );
    expect(speedButton, findsNothing);
    controller.setPlaybackSpeed(1.5);
    await tester.pump();
    expect(speedButton, findsOneWidget);
    expect(
      find.descendant(of: speedButton, matching: find.text('1.5x')),
      findsOneWidget,
    );
    await tester.tap(speedButton);
    await tester.pumpAndSettle();
    expect(find.text('播放倍速'), findsWidgets);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    controller.setPlaybackSpeed(1.0);
    await tester.pump();
    expect(speedButton, findsNothing);
    await tester.tap(screenshot);
    await tester.pumpAndSettle();
    expect(find.text('纯净原画'), findsOneWidget);
    expect(find.text('含字幕原画'), findsOneWidget);
    await tester.tap(find.text('纯净原画'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(screenshot);
    await tester.pumpAndSettle();
    await tester.tap(find.text('含字幕原画'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 500));
    final modes = client.commands
        .where((args) => args.first == 'screenshot-to-file')
        .map((args) => args.last);
    expect(modes, orderedEquals(['video', 'subtitles']));
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    await tester.pump();
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
      expect(fakeClient.properties['sub-ass-override'], 'scale');

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
      expect(fakeClient.properties['sub-ass-override'], 'no');

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

          // 原生 PiP 回调先到或窗口先缩小时均只保留视频，不产生控制层溢出。
          final top = find.byKey(const ValueKey('embedded_video_top_bar'));
          final bottom = find.byKey(
            const ValueKey('embedded_video_bottom_capsule'),
          );
          controller.setSystemPipActive(true);
          await tester.pump();
          expect(top, findsNothing);
          expect(bottom, findsNothing);
          expect(controller.currentSubtitleHudLiftPercent, 0);
          tester.view.physicalSize = const Size(190, 108);
          controller.setSystemPipActive(false);
          await tester.pump();
          expect(top, findsNothing);
          expect(bottom, findsNothing);
          expect(tester.takeException(), isNull);
          tester.view.physicalSize = entry.size;
          await tester.pump();
          expect(top, findsOneWidget);
          expect(bottom, findsOneWidget);
          expect(tester.takeException(), isNull);

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
