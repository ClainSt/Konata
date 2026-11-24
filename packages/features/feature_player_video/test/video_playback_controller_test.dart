import 'package:engine_playback/engine_playback.dart';
import 'package:feature_player_video/feature_player_video.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';

import 'support/video_test_harness.dart';

void main() {
  group('VideoPlaybackController 播放状态、持久化与领域事件发布', () {
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
      expect(
        controller.state.activeSkipWindow!.kind,
        SkipActionKind.skipOp,
      );

      await controller.triggerActiveSkipWindow();
      expect(controller.positionNotifier.value.inSeconds, 90);
      expect(controller.state.activeSkipWindow, isNull);
    });

    test('底栏呼出按真实占高与 16dp 留白抬升 sub-pos 且隐藏瞬间复原 0 而不修改 sub-ass-override', () async {
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
      final baselineSubPos = fakeClient.properties['sub-pos'] as double?;
      expect(baselineSubPos, 100.0);

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
      expect(
        fakeClient.properties['secondary-sub-pos'] as double,
        closeTo(100.0 - expectedPercent, 0.1),
      );
      // 严禁改写 sub-ass-override 以保障 ASS \pos() 绝对坐标屏幕字不受干扰。
      expect(fakeClient.options['sub-ass-override'], 'no');
      expect(fakeClient.properties['sub-ass-override'], 'no');

      // 切换双语副字幕轨道时保持当前 HUD 上抬比例不回落。
      await controller.selectSecondarySubtitleTrack(2);
      expect(
        fakeClient.properties['secondary-sub-pos'] as double,
        closeTo(100.0 - expectedPercent, 0.1),
      );

      // OSD 隐藏瞬间立即复原为 0.0，副字幕复原 100.0，主字幕复原双语基准位；关闭副字幕后主字幕复原 100.0。
      final restored = controller.updateHudSubtitleLift(
        hudVisible: false,
        bottomCapsuleOccupiedHeight: 88.0,
        viewportHeight: 720.0,
      );
      expect(restored, 0.0);
      expect(controller.currentSubtitleHudLiftPercent, 0.0);
      expect(
        fakeClient.properties['secondary-sub-pos'] as double,
        closeTo(100.0, 0.01),
      );
      await controller.selectSecondarySubtitleTrack(null);
      expect(fakeClient.properties['sub-pos'] as double, closeTo(100.0, 0.01));
    });
  });
}
