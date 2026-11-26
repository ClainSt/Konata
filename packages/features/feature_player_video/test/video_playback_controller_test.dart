import 'package:engine_playback/engine_playback.dart';
import 'package:feature_player_video/feature_player_video.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';

import 'support/video_test_harness.dart';

void main() {
  group('VideoPlaybackController 播放状态、持久化与领域事件发布', () {
    test('系统画中画进入保存断点、暂停刷新、关闭保留会话并清除快照', () async {
      final harness = await VideoTestHarness.create();
      addTearDown(harness.dispose);
      final seeded = await harness.seedSampleAnime();
      final client = FakeLibMpvClient();
      final controller = harness.createController(
        libMpvClientFactory: () => client,
        enablePeriodicTimers: false,
      );
      addTearDown(controller.dispose);
      await controller.initialize(
        VideoLaunchRequest(
          workId: seeded.work.id,
          episodeId: seeded.ep1.id,
          variantId: seeded.v1.id,
          initialPositionSeconds: 18,
          initialPlaying: false,
        ),
      );
      expect(client.properties['pause'], isTrue);
      expect(controller.positionNotifier.value.inSeconds, 18);
      await controller.setPlaying(true);
      client.properties['time-pos'] = 23.0;
      controller.setSystemPipActive(true);
      final snapshot = await controller.checkRecoverablePipSnapshot();
      expect(snapshot?.positionSeconds, 23);
      expect(snapshot?.isPlaying, isTrue);
      client.properties['time-pos'] = 27.0;
      await controller.setPlaying(false);
      final paused = await controller.checkRecoverablePipSnapshot();
      expect(paused?.positionSeconds, 27);
      expect(paused?.isPlaying, isFalse);
      await controller.dismissSystemPip();
      expect(controller.systemPipActive, isFalse);
      expect(controller.state.isClosing, isFalse);
      expect(client.isDisposed, isFalse);
      expect(client.properties['pause'], isTrue);
      expect(await controller.checkRecoverablePipSnapshot(), isNull);
      await controller.setPlaying(true);
      controller.setSystemPipActive(true);
      await controller.closeSession();
      expect(await controller.checkRecoverablePipSnapshot(), isNull);
    });

    test('无头初始化自动载入作品剧集并从既有未完播记录续播', () async {
      final harness = await VideoTestHarness.create();
      addTearDown(harness.dispose);
      final seeded = await harness.seedSampleAnime();

      harness.databases.userState.playbackRecords.upsert(
        PlaybackRecordEntity(
          id: '${seeded.work.id.value}::${seeded.ep1.id.value}',
          workId: seeded.work.id,
          episodeId: seeded.ep1.id,
          variantId: seeded.v1.id,
          seasonNumber: 1,
          episodeNumber: 1,
          episodeTitle: '01 · 第一话 启程',
          playedAtMs: 1000,
          positionSeconds: 185,
          durationSeconds: 1440,
          isCompleted: false,
          updatedAtMs: 1000,
        ),
      );

      final controller = harness.createController(enablePeriodicTimers: false);
      addTearDown(controller.dispose);

      await controller.initialize(VideoLaunchRequest(workId: seeded.work.id));

      expect(controller.state.currentWork?.id, seeded.work.id);
      expect(controller.state.currentEpisode.id, seeded.ep1.id);
      expect(controller.state.currentVariant.id, seeded.v1.id);
      expect(controller.positionNotifier.value.inSeconds, 185);
      expect(controller.durationNotifier.value.inSeconds, 1440);
      expect(controller.state.isCompletedCurrentEpisode, isFalse);
      expect(harness.hostWindow.preferredLandscape, isTrue);
      expect(harness.hostWindow.keepScreenOn, isTrue);
    });

    test('高频进度更新仅刷新叶子监听且达完播阈值时落盘并发布一次 EpisodeCompletionChangedEvent', () async {
      final harness = await VideoTestHarness.create();
      addTearDown(harness.dispose);
      final seeded = await harness.seedSampleAnime();

      final controller = harness.createController(enablePeriodicTimers: false);
      addTearDown(controller.dispose);

      await controller.initialize(VideoLaunchRequest(workId: seeded.work.id));
      controller.handleDurationUpdate(1000.0);

      var controllerNotifyCount = 0;
      controller.addListener(() => controllerNotifyCount++);

      final completionEvents = <EpisodeCompletionChangedEvent>[];
      final sub = harness.domainEventBus
          .on<EpisodeCompletionChangedEvent>()
          .listen(completionEvents.add);
      addTearDown(sub.cancel);

      controller.handlePositionUpdate(100.0);
      controller.handlePositionUpdate(250.0);
      controller.handlePositionUpdate(500.0);
      await Future<void>.delayed(Duration.zero);

      expect(controller.positionNotifier.value.inSeconds, 500);
      expect(controllerNotifyCount, 0);
      expect(completionEvents, isEmpty);

      controller.handlePositionUpdate(910.0);
      controller.handlePositionUpdate(920.0);
      controller.handlePositionUpdate(950.0);
      await Future<void>.delayed(Duration.zero);

      expect(controller.state.isCompletedCurrentEpisode, isTrue);
      expect(completionEvents, hasLength(1));
      expect(completionEvents.single.workId, seeded.work.id);
      expect(completionEvents.single.episodeId, seeded.ep1.id);
      expect(completionEvents.single.completed, isTrue);

      final stored = harness.databases.userState.playbackRecords
          .findLatestByEpisode(seeded.ep1.id);
      expect(stored, isNotNull);
      expect(stored!.isCompleted, isTrue);
      expect(stored.positionSeconds, 910);

      await controller.markEpisodeCompleted(seeded.ep1.id, completed: false);
      await Future<void>.delayed(Duration.zero);
      expect(controller.state.isCompletedCurrentEpisode, isFalse);
      expect(completionEvents, hasLength(2));
      expect(completionEvents.last.completed, isFalse);
      expect(
        harness.databases.userState.playbackRecords
            .findLatestByEpisode(seeded.ep1.id)!
            .isCompleted,
        isFalse,
      );
    });

    test('识别 Hi10P 高风险流并强制回落软解、支持暂停停表及切换下一集', () async {
      final harness = await VideoTestHarness.create();
      addTearDown(harness.dispose);
      final seeded = await harness.seedSampleAnime(
        videoCodec: 'h264',
        bitDepth: '10bit',
      );

      final fakeClient = FakeLibMpvClient();
      final controller = harness.createController(
        libMpvClientFactory: () => fakeClient,
        enablePeriodicTimers: true,
      );
      addTearDown(controller.dispose);

      await controller.initialize(VideoLaunchRequest(workId: seeded.work.id));
      expect(fakeClient.options['hwdec'], 'no');
      expect(controller.state.hwdecForcedSoftwareReason, isNotNull);

      await controller.setPlaying(true);
      expect(fakeClient.properties['pause'], isFalse);
      expect(controller.state.isPlaying, isTrue);

      await controller.setPlaying(false);
      expect(fakeClient.properties['pause'], isTrue);
      expect(controller.state.isPlaying, isFalse);

      expect(controller.hasNextEpisode, isTrue);
      await controller.playNextEpisode();
      expect(controller.state.currentEpisode.id, seeded.ep2.id);
      expect(controller.hasPreviousEpisode, isTrue);
    });

    test('关闭详细信息时仍以事件驱动真实解码规格，未知不误报软解', () async {
      final harness = await VideoTestHarness.create();
      addTearDown(harness.dispose);
      final seeded = await harness.seedSampleAnime();
      final clients = <FakeLibMpvClient>[];
      final controller = harness.createController(
        libMpvClientFactory: () {
          final client = FakeLibMpvClient();
          clients.add(client);
          return client;
        },
        enablePeriodicTimers: false,
      );
      addTearDown(controller.dispose);
      await controller.initialize(VideoLaunchRequest(workId: seeded.work.id));
      final client = clients.first;
      controller.refreshProbeOnce();
      expect(controller.state.probeOverlayVisible, isFalse);
      expect(controller.state.probeStats.hwdecCurrent, isEmpty);
      client.setPropertyInt64('video-params/w', 1920);
      client.setPropertyInt64('video-params/h', 1080);
      client.setPropertyString('video-codec', 'hevc');
      client.setPropertyString('video-params/pixelformat', 'd3d11');
      client.setPropertyString('video-params/hw-pixelformat', 'p010');
      client.setPropertyString('hwdec-current', 'd3d11va');
      client.emitEvent(const MpvVideoReconfigEvent());
      await Future<void>.delayed(Duration.zero);
      expect(controller.state.probeOverlayVisible, isFalse);
      expect(controller.state.probeStats.videoWidth, 1920);
      expect(controller.state.probeStats.videoCodec, 'hevc');
      expect(controller.state.probeStats.videoHwPixelFormat, 'p010');
      expect(controller.state.probeStats.hwdecCurrent, 'd3d11va');
      client.setPropertyString('hwdec-current', 'no');
      client.emitEvent(const MpvVideoReconfigEvent());
      await Future<void>.delayed(Duration.zero);
      expect(controller.state.probeStats.hwdecCurrent, 'no');
    });
    test('关闭播放会话时取消缩略图预热并等待两个播放器客户端释放', () async {
      final harness = await VideoTestHarness.create();
      addTearDown(harness.dispose);
      final seeded = await harness.seedSampleAnime();
      final clients = <FakeLibMpvClient>[];
      final controller = harness.createController(
        libMpvClientFactory: () {
          final client = FakeLibMpvClient();
          clients.add(client);
          return client;
        },
        enablePeriodicTimers: false,
      );
      addTearDown(controller.dispose);
      await controller.initialize(VideoLaunchRequest(workId: seeded.work.id));

      final thumbnails = controller.thumbnailService;
      await Future<void>.delayed(Duration.zero);
      expect(thumbnails.hasActiveNativeClient, isTrue);
      final mediaClients = clients
          .where(
            (client) =>
                client.commands.any((command) => command.first == 'loadfile'),
          )
          .toList();
      expect(mediaClients, hasLength(2));

      await controller.closeSession().timeout(const Duration(seconds: 6));
      expect(thumbnails.hasActiveNativeClient, isFalse);
      expect(thumbnails.isWarmingUp, isFalse);
      expect(mediaClients.every((client) => client.isDisposed), isTrue);
      expect(harness.hostWindow.keepScreenOn, isFalse);
    });

    test('全屏与悬浮小窗切换及画中画快照写入恢复与外部播放器接力回写', () async {
      final harness = await VideoTestHarness.create();
      addTearDown(harness.dispose);
      final seeded = await harness.seedSampleAnime();

      final controller = harness.createController(enablePeriodicTimers: false);
      addTearDown(controller.dispose);

      await controller.initialize(VideoLaunchRequest(workId: seeded.work.id));
      controller.handleDurationUpdate(1200.0);
      controller.handlePositionUpdate(320.0);

      await controller.toggleFullscreen();
      expect(controller.state.isFullscreen, isTrue);
      expect(harness.hostWindow.fullScreen, isTrue);

      await controller.enterMiniPlayer(width: 400, height: 225);
      expect(controller.state.isMiniPlayer, isTrue);
      expect(controller.state.miniMode, VideoMiniMode.desktop);
      expect(harness.hostWindow.desktopMiniMode, isTrue);
      expect(harness.hostWindow.alwaysOnTop, isTrue);

      final pipSnap = await controller.checkRecoverablePipSnapshot();
      expect(pipSnap, isNotNull);
      expect(pipSnap!.positionSeconds, 320);

      await controller.exitMiniPlayerToStage();
      expect(controller.state.isMiniPlayer, isFalse);
      expect(harness.hostWindow.desktopMiniMode, isFalse);
      expect(harness.hostWindow.alwaysOnTop, isFalse);
      expect(await controller.checkRecoverablePipSnapshot(), isNull);

      // 应用内小窗不触碰宿主置顶属性。
      await harness.hostWindow.setAlwaysOnTop(true);
      await controller.enterMiniPlayer(desktopAlwaysOnTop: false);
      expect(controller.state.miniMode, VideoMiniMode.floating);
      expect(harness.hostWindow.desktopMiniMode, isFalse);
      await controller.exitMiniPlayerToStage();
      expect(controller.state.miniMode, VideoMiniMode.stage);
      expect(harness.hostWindow.alwaysOnTop, isTrue);
      expect(controller.positionNotifier.value.inSeconds, 320);
      await harness.hostWindow.setAlwaysOnTop(false);

      final launchResult = await controller.launchExternalVideoPlayer();
      expect(launchResult.launched, isTrue);
      expect(harness.desktopRelay.launchCount, 1);
      expect(harness.desktopRelay.lastStartSeconds, 320);

      await harness.desktopRelay.lastProgressCallback!(
        1180,
        1200,
        isFinal: true,
      );
      final recordAfterRelay = harness.databases.userState.playbackRecords
          .findLatestByEpisode(seeded.ep1.id);
      expect(recordAfterRelay, isNotNull);
      expect(recordAfterRelay!.positionSeconds, 1180);
      expect(recordAfterRelay.isCompleted, isTrue);
    });

    test('旧路由销毁不关闭已回弹的同一个播放会话', () async {
      final harness = await VideoTestHarness.create();
      addTearDown(harness.dispose);
      final seeded = await harness.seedSampleAnime();
      var created = 0;
      final manager = ActiveVideoSessionManager(
        controllerFactory: () {
          created++;
          return harness.createController(enablePeriodicTimers: false);
        },
      );
      addTearDown(manager.dispose);
      final request = VideoLaunchRequest(workId: seeded.work.id);
      final oldRoute = Object();
      final newRoute = Object();
      final controller = await manager.openOrReuseSession(
        request,
        routeOwner: oldRoute,
      );
      for (var i = 0; i < 100 && controller.state.isInitializing; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(controller.state.isInitializing, isFalse);
      expect(controller.state.errorMessage, isNull);
      await manager.collapseToFloatingMini();
      expect(manager.shouldShowFloatingMiniPlayer, isTrue);
      final restored = await manager.openOrReuseSession(
        request,
        routeOwner: newRoute,
      );
      manager.handleStageRoutePopped(oldRoute);
      expect(manager.controller, same(controller));
      expect(restored, same(controller));
      expect(manager.isStageExpanded, isTrue);
      expect(controller.state.miniMode, VideoMiniMode.stage);
      expect(created, 1);
      expect(await manager.closeActiveSession(), isTrue);
      manager.handleStageRoutePopped(newRoute);
      expect(manager.hasActiveSession, isFalse);
    });
    test('关闭原生会话后保留仍挂载路由的通知器直到最后退场', () async {
      final harness = await VideoTestHarness.create();
      addTearDown(harness.dispose);
      final seeded = await harness.seedSampleAnime();
      final manager = ActiveVideoSessionManager(
        controllerFactory: () =>
            harness.createController(enablePeriodicTimers: false),
      );
      addTearDown(manager.dispose);
      final request = VideoLaunchRequest(workId: seeded.work.id);
      final oldRoute = Object();
      final newRoute = Object();
      final controller = await manager.openOrReuseSession(
        request,
        routeOwner: oldRoute,
      );
      for (var i = 0; i < 100 && controller.state.isInitializing; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(controller.state.isInitializing, isFalse);
      expect(controller.state.errorMessage, isNull);
      await manager.collapseToFloatingMini();
      expect(
        await manager.openOrReuseSession(request, routeOwner: newRoute),
        same(controller),
      );
      expect(await manager.closeActiveSession(), isTrue);
      expect(manager.hasActiveSession, isFalse);
      expect(controller.state.isClosing, isTrue);
      void listener() {}
      // 退出动画中旧路由及回弹路由仍可能重新订阅进度。
      expect(
        () => controller.positionNotifier.addListener(listener),
        returnsNormally,
        reason: '关闭后仍挂载路由的通知器必须存活',
      );
      controller.positionNotifier.removeListener(listener);
      manager.handleStageRoutePopped(newRoute);
      expect(
        () => controller.durationNotifier.addListener(listener),
        returnsNormally,
      );
      controller.durationNotifier.removeListener(listener);
      manager.handleStageRoutePopped(oldRoute);
      expect(
        () => controller.positionNotifier.addListener(listener),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            "错误信息",
            contains("used after being disposed"),
          ),
        ),
      );
      // 重复退场通知不得影响后续会话。
      manager.handleStageRoutePopped(oldRoute);
      final nextRoute = Object();
      final next = await manager.openOrReuseSession(
        request,
        routeOwner: nextRoute,
      );
      expect(next, isNot(same(controller)));
      for (var i = 0; i < 100 && next.state.isInitializing; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(next.state.isInitializing, isFalse);
      manager.handleStageRoutePopped(oldRoute);
      expect(manager.controller, same(next));
      expect(await manager.closeActiveSession(), isTrue);
      manager.handleStageRoutePopped(nextRoute);
      expect(
        () => next.durationNotifier.addListener(listener),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            "错误信息",
            contains("used after being disposed"),
          ),
        ),
      );
    });
    test('小窗宿主切换失败保留播放会话并允许重试', () async {
      final harness = await VideoTestHarness.create();
      addTearDown(harness.dispose);
      final seeded = await harness.seedSampleAnime();
      final controller = harness.createController(enablePeriodicTimers: false);
      addTearDown(controller.dispose);
      await controller.initialize(VideoLaunchRequest(workId: seeded.work.id));
      controller.handleDurationUpdate(1200);
      controller.handlePositionUpdate(320);
      final host = harness.hostWindow;
      host.failEnterMini = true;
      await controller.enterMiniPlayer();
      expect(controller.state.miniMode, VideoMiniMode.stage);
      expect(host.desktopMiniMode, isFalse);
      expect(controller.state.transientNotice?.isError, isTrue);
      expect(await controller.checkRecoverablePipSnapshot(), isNull);
      host.failEnterMini = false;
      await host.setAlwaysOnTop(true);
      await controller.enterMiniPlayer();
      expect(controller.state.miniMode, VideoMiniMode.desktop);
      host.failExitMini = true;
      await controller.exitMiniPlayerToStage();
      expect(controller.state.miniMode, VideoMiniMode.desktop);
      expect(host.desktopMiniMode, isTrue);
      expect(controller.state.transientNotice?.isError, isTrue);
      expect(await controller.checkRecoverablePipSnapshot(), isNotNull);
      await expectLater(controller.closeSession(), throwsStateError);
      expect(controller.state.isClosing, isFalse);
      expect(controller.state.miniMode, VideoMiniMode.desktop);
      expect(controller.positionNotifier.value.inSeconds, 320);
      host.failExitMini = false;
      await controller.exitMiniPlayerToStage();
      expect(controller.state.miniMode, VideoMiniMode.stage);
      expect(host.alwaysOnTop, isTrue);
      expect(controller.positionNotifier.value.inSeconds, 320);
    });
    test('支持显式章节片头跳过窗口触发与手动跳转定位', () async {
      final harness = await VideoTestHarness.create();
      addTearDown(harness.dispose);
      final seeded = await harness.seedSampleAnime();

      final fakeClient = FakeLibMpvClient()
        ..chapterList = const <PlaybackChapter>[
          PlaybackChapter(
            index: 0,
            title: 'OP',
            startSeconds: 0.0,
            endSeconds: 90.0,
          ),
          PlaybackChapter(
            index: 1,
            title: 'Part A',
            startSeconds: 90.0,
            endSeconds: 1300.0,
          ),
        ];
      final controller = harness.createController(
        libMpvClientFactory: () => fakeClient,
        enablePeriodicTimers: false,
      );
      addTearDown(controller.dispose);

      await controller.initialize(VideoLaunchRequest(workId: seeded.work.id));
      controller.handleDurationUpdate(1400.0);
      fakeClient.emitEvent(const MpvVideoReconfigEvent());
      await Future<void>.delayed(const Duration(milliseconds: 50));

      controller.handlePositionUpdate(15.0);
      expect(controller.state.activeSkipWindow, isNotNull);
      expect(controller.state.activeSkipWindow!.kind, SkipActionKind.skipOp);

      await controller.triggerActiveSkipWindow();
      expect(controller.positionNotifier.value.inSeconds, 90);
      expect(controller.state.activeSkipWindow, isNull);
    });

    test('底栏呼出临时启用等倍率 scale 抬升字幕且隐藏后恢复保真模式', () async {
      final harness = await VideoTestHarness.create();
      addTearDown(harness.dispose);
      final seeded = await harness.seedSampleAnime();

      final fakeClient = FakeLibMpvClient();
      final controller = harness.createController(
        libMpvClientFactory: () => fakeClient,
        enablePeriodicTimers: false,
      );
      addTearDown(controller.dispose);

      await controller.initialize(VideoLaunchRequest(workId: seeded.work.id));
      expect(controller.currentSubtitleHudLiftPercent, 0.0);
      expect(fakeClient.options['sub-ass-override'], 'no');
      expect(fakeClient.options['secondary-sid'], 'no');
      final baselineSubPos = fakeClient.properties['sub-pos'] as double?;
      expect(baselineSubPos, 100.0);
      fakeClient.trackList = const [
        MpvTrackInfo(
          id: 7,
          type: MpvTrackType.subtitle,
          codec: 'ass',
          selected: true,
        ),
        MpvTrackInfo(id: 8, type: MpvTrackType.subtitle, codec: 'subrip'),
      ];
      fakeClient.properties['sid'] = '7';
      fakeClient.stringWrites.clear();
      final commandsBefore = fakeClient.commands.length;
      List<String> sidWrites() => fakeClient.stringWrites
          .where((entry) => entry.$1 == 'sid')
          .map((entry) => entry.$2)
          .toList();

      // 模拟 720p 视口下 20dp 底边距 + 52dp 胶囊 + 16dp 留白 = 88dp 占高。
      final lifted = controller.updateHudSubtitleLift(
        hudVisible: true,
        bottomCapsuleOccupiedHeight: 88.0,
        viewportHeight: 720.0,
      );
      const expectedPercent = 88.0 / 720.0 * 100.0;
      expect(lifted, closeTo(expectedPercent, 0.05));
      expect(
        controller.currentSubtitleHudLiftPercent,
        closeTo(expectedPercent, 0.05),
      );
      expect(
        fakeClient.properties['sub-pos'] as double,
        closeTo(100.0 - expectedPercent, 0.1),
      );
      // 原始启动偏好保持 no；运行时临时 scale，倍率保持 1.0。
      expect(fakeClient.options['sub-ass-override'], 'no');
      expect(fakeClient.options['secondary-sid'], 'no');
      expect(fakeClient.properties['sub-ass-override'], 'scale');
      expect(fakeClient.properties['sub-scale'], 1.0);
      expect(sidWrites(), ['no', '7']);
      controller.updateHudSubtitleLift(
        hudVisible: true,
        bottomCapsuleOccupiedHeight: 96,
        viewportHeight: 720,
      );
      expect(sidWrites(), ['no', '7']);

      // OSD 隐藏瞬间抬升量归零，字幕复原到 100.0。
      final restored = controller.updateHudSubtitleLift(
        hudVisible: false,
        bottomCapsuleOccupiedHeight: 88.0,
        viewportHeight: 720.0,
      );
      expect(restored, 0.0);
      expect(controller.currentSubtitleHudLiftPercent, 0.0);
      expect(fakeClient.properties['sub-ass-override'], 'no');
      expect(fakeClient.properties['sub-pos'] as double, closeTo(100.0, 0.01));
      expect(sidWrites(), ['no', '7', 'no', '7']);
      expect(fakeClient.properties['sid'], '7');
      expect(fakeClient.commands.length, commandsBefore);
      // 图形、普通文本和关闭字幕均不能被 HUD 强制切轨。
      for (final sid in ['8', 'no']) {
        fakeClient.properties['sid'] = sid;
        fakeClient.stringWrites.clear();
        controller.updateHudSubtitleLift(
          hudVisible: true,
          bottomCapsuleOccupiedHeight: 88,
          viewportHeight: 720,
        );
        controller.updateHudSubtitleLift(
          hudVisible: false,
          bottomCapsuleOccupiedHeight: 88,
          viewportHeight: 720,
        );
        expect(sidWrites(), isEmpty);
        expect(fakeClient.properties['sid'], sid);
      }
    });
  });
}
