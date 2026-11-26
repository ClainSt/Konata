import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:engine_playback/engine_playback.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/playback_test_fixtures.dart';

void main() {
  group('UnifiedPlaybackEngine 四维代数隔离、租约与熔断器', () {
    test('CUE 跨轨与音频路由重载均不中断物理媒体代数与主流租约', () {
      final engine = UnifiedPlaybackEngine();
      final instId = engine.attachNativeInstance();
      final mediaEpoch = engine.beginPhysicalMedia(nativeInstanceId: instId);
      engine.bindPlaylistEntryId(7);
      engine.bindMainStreamLease('lease-main-1');
      engine.bindPrefetchStreamLease('lease-prefetch-2', playlistEntryId: 8);

      final subToken = engine.acquireTaskToken(
        PlaybackTaskDomain.rawSubtitleFetch,
      );
      final cloudToken = engine.acquireTaskToken(
        PlaybackTaskDomain.cloudSubset,
      );
      final lyricToken = engine.acquireTaskToken(
        PlaybackTaskDomain.lyricLookup,
      );
      final colorToken = engine.acquireTaskToken(
        PlaybackTaskDomain.artworkColor,
      );

      engine.cancelTaskDomain(PlaybackTaskDomain.cloudSubset);
      expect(engine.isTaskAlive(cloudToken), isFalse);
      expect(engine.isTaskAlive(subToken), isTrue);
      expect(engine.isTaskAlive(lyricToken), isTrue);
      expect(engine.isTaskAlive(colorToken), isTrue);

      final prevAo = engine.audioOutputEpoch;
      engine.advanceAudioOutputRoute();
      expect(engine.audioOutputEpoch, prevAo + 1);
      expect(engine.physicalMediaEpoch, mediaEpoch);
      expect(engine.mainStreamLease?.leaseToken, 'lease-main-1');
      expect(engine.prefetchStreamLease?.leaseToken, 'lease-prefetch-2');

      final prevLogical = engine.logicalTrackEpoch;
      engine.advanceLogicalTrack();
      expect(engine.logicalTrackEpoch, prevLogical + 1);
      expect(engine.physicalMediaEpoch, mediaEpoch);
      expect(engine.mainStreamLease?.leaseToken, 'lease-main-1');
      expect(engine.isTaskAlive(lyricToken), isFalse);
      expect(engine.isTaskAlive(subToken), isTrue);

      final retiredMain = engine.promotePrefetchLeaseToMain(playlistEntryId: 8);
      expect(retiredMain, 'lease-main-1');
      expect(engine.mainStreamLease?.leaseToken, 'lease-prefetch-2');
      expect(engine.prefetchStreamLease, isNull);
      expect(
        engine.matchesPhysicalEvent(
          physicalMediaEpoch: mediaEpoch,
          nativeInstanceId: instId,
          playlistEntryId: 7,
        ),
        isFalse,
      );
    });

    test('连续 3 个物理坏文件熔断：FILE_LOADED 不清零，仅手动点选或有效进展清零', () {
      final engine = UnifiedPlaybackEngine();
      engine.beginPhysicalMedia();

      engine.recordFileLoaded();
      expect(engine.recordPhysicalMediaFailure(), isFalse);
      expect(engine.consecutiveBadFiles, 1);

      engine.beginPhysicalMedia();
      engine.recordFileLoaded();
      expect(engine.recordEffectiveProgress(audioAdvancedMs: 300), isFalse);
      expect(engine.recordPhysicalMediaFailure(), isFalse);
      expect(engine.consecutiveBadFiles, 2);

      engine.beginPhysicalMedia();
      engine.recordFileLoaded();
      expect(engine.recordPhysicalMediaFailure(), isTrue);
      expect(engine.isCircuitBreakerTripped, isTrue);

      expect(engine.recordEffectiveProgress(audioAdvancedMs: 500), isTrue);
      expect(engine.consecutiveBadFiles, 0);
      expect(engine.isCircuitBreakerTripped, isFalse);

      engine.recordPhysicalMediaFailure();
      engine.recordPhysicalMediaFailure();
      engine.recordPhysicalMediaFailure();
      expect(engine.isCircuitBreakerTripped, isTrue);
      engine.recordManualSelection();
      expect(engine.consecutiveBadFiles, 0);
      expect(engine.isCircuitBreakerTripped, isFalse);
    });

    test('独占唯一 LibMpvClient 互斥托管与暂挂会话重绑隔离', () async {
      final first = FakeLibMpvClient();
      final second = FakeLibMpvClient();
      var evictedFirst = false;

      final engine = UnifiedPlaybackEngine(
        defaultClientFactory: ({preferredLibraryPath}) => FakeLibMpvClient(),
      );

      final lease1 = await engine.acquireExclusiveNativeClient(
        stage: PlaybackStageKind.video,
        factoryOverride: () => first,
        onEvicted: () async {
          evictedFirst = true;
        },
      );
      expect(identical(lease1.client, first), isTrue);
      engine.bindMainStreamLease('video-main-lease');

      final lease2 = await engine.acquireExclusiveNativeClient(
        stage: PlaybackStageKind.audio,
        factoryOverride: () => second,
      );
      expect(evictedFirst, isTrue);
      expect(first.isDisposed, isTrue);
      expect(identical(lease2.client, second), isTrue);
      expect(engine.liveNativeClientCount, equals(1));

      // 视频重新拉起恢复暂挂租约，并验证安全释放后计数清零
      engine.resumeOrRebindStage(
        PlaybackStageKind.video,
        nativeInstanceId: lease1.nativeInstanceId,
      );
      expect(engine.mainStreamLease?.leaseToken, equals('video-main-lease'));

      await engine.releaseNativeClient(lease2.client);
      expect(second.isDisposed, isTrue);
      expect(engine.liveNativeClientCount, equals(0));
    });
  });

  group('AudiophileSafetyCoordinator -12 dBFS 安全链与外设热拔出保护', () {
    test('Windows 无活动会话或缺少实际 WASAPI 反馈时不得核验解锁', () async {
      final coordinator = AudiophileSafetyCoordinator(
        engine: UnifiedPlaybackEngine(),
        isWindowsOverride: true,
        isAndroidOverride: false,
      );
      addTearDown(coordinator.dispose);
      const prefs = AudiophileAudioPreferences(
        qualityConfig: PlaybackQualityConfig(exclusiveAudioOutput: true),
      );
      expect(
        (await coordinator.verifyActiveHardwareRoute(prefs)).verified,
        isFalse,
      );
      expect(await coordinator.confirmSessionFullScaleUnlock(prefs), isFalse);
      final client = FakeLibMpvClient()..initialize();
      addTearDown(client.dispose);
      coordinator.attachSession(
        owner: 'video',
        clientProvider: () => client,
        prefsProvider: () => prefs,
        onTransientMuteAndPause: (_) {},
      );
      coordinator.applyToClient(client, prefs: prefs);
      expect(
        (await coordinator.verifyActiveHardwareRoute(prefs)).verified,
        isFalse,
      );
      client.setPropertyFlag('audio-exclusive', true);
      client.setPropertyString('current-ao', 'wasapi');
      expect(
        (await coordinator.verifyActiveHardwareRoute(prefs)).verified,
        isTrue,
      );
      expect(await coordinator.confirmSessionFullScaleUnlock(prefs), isTrue);
      coordinator.detachSession('video');
      expect(coordinator.deviceSafetyState.allowFullScaleBypass, isFalse);
    });
    test('Android 无会话、过期核验及撤销失败均不能保留满幅解锁', () async {
      final engine = UnifiedPlaybackEngine();
      final route = FakeAndroidAudioRoutePort();
      final coordinator = AudiophileSafetyCoordinator(
        engine: engine,
        androidRouteBridge: route,
        isWindowsOverride: false,
        isAndroidOverride: true,
      );
      addTearDown(coordinator.dispose);
      addTearDown(route.dispose);
      var prefs = const AudiophileAudioPreferences(androidBitPerfectUsb: true);
      expect(
        (await coordinator.verifyActiveHardwareRoute(prefs)).verified,
        isFalse,
      );
      expect(route.negotiateCallCount, 0);
      final client = FakeLibMpvClient()..initialize();
      addTearDown(client.dispose);
      final reasons = <String>[];
      coordinator.attachSession(
        owner: 'audio',
        clientProvider: () => client,
        prefsProvider: () => prefs,
        onTransientMuteAndPause: reasons.add,
      );
      coordinator.applyToClient(client, prefs: prefs);
      final pending = Completer<AndroidBitPerfectNegotiationResult>();
      route.onNegotiate = (enable) => enable
          ? pending.future
          : Future.value(
              const AndroidBitPerfectNegotiationResult(
                supported: true,
                engaged: false,
                operationSucceeded: true,
              ),
            );
      final verification = coordinator.verifyActiveHardwareRoute(prefs);
      prefs = const AudiophileAudioPreferences();
      await coordinator.reapplyAll(prefs);
      pending.complete(
        const AndroidBitPerfectNegotiationResult(
          supported: true,
          engaged: true,
          operationSucceeded: true,
        ),
      );
      expect((await verification).verified, isFalse);
      expect(await coordinator.confirmSessionFullScaleUnlock(prefs), isFalse);
      route.onNegotiate = null;
      prefs = const AudiophileAudioPreferences(androidBitPerfectUsb: true);
      coordinator.applyToClient(client, prefs: prefs);
      expect(
        (await coordinator.verifyActiveHardwareRoute(prefs)).verified,
        isTrue,
      );
      expect(await coordinator.confirmSessionFullScaleUnlock(prefs), isTrue);
      prefs = const AudiophileAudioPreferences();
      route.nextNegotiationResult = const AndroidBitPerfectNegotiationResult(
        supported: true,
        engaged: false,
        detail: '系统拒绝撤销',
      );
      await coordinator.reapplyAll(prefs);
      await Future<void>.delayed(Duration.zero);
      expect(coordinator.deviceSafetyState.allowFullScaleBypass, isFalse);
      expect(client.boolProps['mute'], isTrue);
      expect(client.boolProps['pause'], isTrue);
      expect(reasons, contains('android_usb_route_unconfirmed'));
      expect(await coordinator.confirmSessionFullScaleUnlock(prefs), isFalse);
    });
    test('控制器仍登记但解码实例已释放时撤销 USB 路由，不等待旧协商', () async {
      final engine = UnifiedPlaybackEngine();
      final route = FakeAndroidAudioRoutePort();
      final coordinator = AudiophileSafetyCoordinator(
        engine: engine,
        androidRouteBridge: route,
        isWindowsOverride: false,
        isAndroidOverride: true,
      );
      addTearDown(route.dispose);
      addTearDown(coordinator.dispose);
      final client = FakeLibMpvClient()..initialize();
      addTearDown(client.dispose);
      LibMpvClient? activeClient = client;
      const prefs = AudiophileAudioPreferences(androidBitPerfectUsb: true);
      coordinator.attachSession(
        owner: 'audio',
        clientProvider: () => activeClient,
        prefsProvider: () => prefs,
        onTransientMuteAndPause: (_) {},
      );
      coordinator.applyToClient(client, prefs: prefs);
      expect(
        (await coordinator.verifyActiveHardwareRoute(prefs)).verified,
        isTrue,
      );
      expect(await coordinator.confirmSessionFullScaleUnlock(prefs), isTrue);

      final pending = Completer<AndroidBitPerfectNegotiationResult>();
      route.onNegotiate = (enable) => enable
          ? pending.future
          : Future.value(
              const AndroidBitPerfectNegotiationResult(
                supported: true,
                engaged: false,
                operationSucceeded: true,
              ),
            );
      final oldVerification = coordinator.verifyActiveHardwareRoute(prefs);
      activeClient = null;
      try {
        await coordinator.reapplyAll(prefs).timeout(const Duration(seconds: 2));
        expect(route.lastNegotiateEnable, isFalse);
        expect(coordinator.deviceSafetyState.allowFullScaleBypass, isFalse);
        expect(coordinator.activePlan.safetyLimiterEngaged, isTrue);
      } finally {
        pending.complete(
          const AndroidBitPerfectNegotiationResult(
            supported: true,
            engaged: true,
            operationSucceeded: true,
          ),
        );
      }
      expect((await oldVerification).verified, isFalse);
      expect(coordinator.deviceSafetyState.allowFullScaleBypass, isFalse);
    });

    test('未实证后端锁定 -12 dBFS 安全限幅、拔出瞬间静音暂停、重连复归安全上限', () async {
      final engine = UnifiedPlaybackEngine();
      final routePort = FakeAndroidAudioRoutePort();
      var rev = 0;
      final coordinator = AudiophileSafetyCoordinator(
        engine: engine,
        androidRouteBridge: routePort,
        onRevisionChanged: () => rev += 1,
        isWindowsOverride: false,
        isAndroidOverride: true,
      );
      addTearDown(() {
        coordinator.dispose();
        routePort.dispose();
      });

      final client = FakeLibMpvClient()..initialize();
      addTearDown(client.dispose);
      final mutedReasons = <String>[];
      const prefs = AudiophileAudioPreferences(androidBitPerfectUsb: true);

      coordinator.attachSession(
        owner: 'audio-stage',
        clientProvider: () => client,
        prefsProvider: () => prefs,
        onTransientMuteAndPause: mutedReasons.add,
        sampleRateProvider: () => 96000,
      );

      final lockedPlan = coordinator.applyToClient(client, prefs: prefs);
      expect(lockedPlan.safetyLimiterEngaged, isTrue);
      expect(
        client.stringProps['af'],
        equals(AudiophileSafetyPolicy.postDspSafetyLimiterFilter),
      );

      // 未获实证前拒绝强行解锁满幅
      expect(await coordinator.confirmSessionFullScaleUnlock(prefs), isFalse);

      // 完成 Android USB DAC 实证并二次确认解锁
      final verifyRes = await coordinator.verifyActiveHardwareRoute(prefs);
      expect(verifyRes.verified, isTrue);
      expect(await coordinator.confirmSessionFullScaleUnlock(prefs), isTrue);
      expect(coordinator.activePlan.safetyLimiterEngaged, isFalse);
      expect(client.stringProps['af'], isEmpty);

      // 模拟耳机/DAC 拔出瞬间静音并暂停，且随后插入新设备恢复安全门锁
      routePort.triggerRemoved('usb_unplugged');
      expect(client.boolProps['mute'], isTrue);
      expect(client.boolProps['pause'], isTrue);
      expect(mutedReasons, equals(['usb_unplugged']));

      routePort.triggerAdded('new_usb_dac');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(coordinator.deviceSafetyState.allowFullScaleBypass, isFalse);
      expect(rev, greaterThanOrEqualTo(2));
    });
  });

  group('SubtitleMemoryEngine 并发零反写、SHA-1 去重与 OpenCC 回收', () {
    late Directory tempRoot;

    setUp(() {
      tempRoot = Directory.systemTemp.createTempSync('konata_sub_mem_');
    });

    tearDown(() {
      if (tempRoot.existsSync()) {
        tempRoot.deleteSync(recursive: true);
      }
    });

    test('换轨在途关字幕、改延迟或切集时 0 反写，正常注入零改 sub-codepage 并原子归零 sub-delay', () async {
      final fakeClient = FakeLibMpvClient()..initialize();
      addTearDown(fakeClient.dispose);
      final unifiedEngine = UnifiedPlaybackEngine();
      unifiedEngine.beginPhysicalMedia();
      final memEngine = SubtitleMemoryEngine(
        clientSupplier: () => fakeClient,
        playbackEngine: unifiedEngine,
      );

      final sampleAssBytes = Uint8List.fromList(
        utf8.encode('''
[Script Info]
ScriptType: v4.00+
[Events]
Dialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,這個動畫真好看
'''),
      );

      // 场景 A：换轨在途关闭字幕 -> 过时任务 0 写回
      final gateA = Completer<Uint8List>();
      final inflightA = memEngine.applyIntent(
        AuthoritativeSubtitleIntent(
          primary: SubtitleSlotRequest.memory(
            loadBytes: () => gateA.future,
            fileName: 'ep01.ass',
            openCcMode: SubtitleOpenCcMode.toSimplified,
          ),
        ),
      );
      final disableRes = await memEngine.applyIntent(
        const AuthoritativeSubtitleIntent.disable(),
      );
      expect(disableRes.applied, isTrue);
      expect(fakeClient.stringProps['sid'], equals('no'));

      final cmdCountAfterDisable = fakeClient.commands.length;
      final writeCountAfterDisable = fakeClient.propWrites.length;
      gateA.complete(sampleAssBytes);
      final staleResA = await inflightA;
      expect(staleResA.applied, isFalse);
      expect(staleResA.staleAborted, isTrue);
      expect(fakeClient.commands.length, equals(cmdCountAfterDisable));
      expect(fakeClient.propWrites.length, equals(writeCountAfterDisable));

      // 场景 B：正常离线调轴 + 繁转简直注
      fakeClient.doubleProps['sub-delay'] = 2.4;
      final okRes = await memEngine.applyIntent(
        AuthoritativeSubtitleIntent(
          primary: SubtitleSlotRequest.memory(
            loadBytes: () async => sampleAssBytes,
            fileName: 'ep02.ass',
            displayTitle: 'EP02 简中重映射',
            openCcMode: SubtitleOpenCcMode.toSimplified,
            timelineTransform: const SubtitleTimelineTransform(
              offsetSeconds: 2.0,
            ),
          ),
        ),
      );
      expect(okRes.applied, isTrue);
      expect(okRes.zeroedInstantSubDelay, isTrue);
      expect(fakeClient.doubleProps['sub-delay'], equals(0.0));
      expect(
        fakeClient.propWrites.any((w) => w.name == 'sub-codepage'),
        isFalse,
      );
      final subAddCmd = fakeClient.commands.last;
      expect(subAddCmd[0], equals('sub-add'));
      expect(subAddCmd[1], startsWith('memory://'));
      expect(subAddCmd[1], contains('这个动画真好看'));
      expect(subAddCmd[1], contains('0:00:03.00,0:00:05.00'));

      // 同内容二次提交命中 SHA-1 去重
      final cmdBeforeReuse = fakeClient.commands.length;
      final reuseRes = await memEngine.applyIntent(
        AuthoritativeSubtitleIntent(
          primary: SubtitleSlotRequest.memory(
            loadBytes: () async => sampleAssBytes,
            fileName: 'ep02.ass',
            displayTitle: 'EP02 简中重映射',
            openCcMode: SubtitleOpenCcMode.toSimplified,
            timelineTransform: const SubtitleTimelineTransform(
              offsetSeconds: 2.0,
            ),
          ),
        ),
      );
      expect(reuseRes.usedCachedMemoryTrack, isTrue);
      expect(fakeClient.commands.length, equals(cmdBeforeReuse));
    });

    test('反复切换 OpenCC 模式自动回收旧派生轨，轨道列表恒定无重复', () async {
      final chsFile = File(p.join(tempRoot.path, 'Ep01.chs.ass'))
        ..writeAsStringSync('''
[Script Info]
ScriptType: v4.00+
[Events]
Dialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,我穿越了，这个动画真好看
''');
      final fakeClient = FakeLibMpvClient()..initialize();
      addTearDown(fakeClient.dispose);
      final unifiedEngine = UnifiedPlaybackEngine();
      unifiedEngine.beginPhysicalMedia();
      final memEngine = SubtitleMemoryEngine(
        clientSupplier: () => fakeClient,
        playbackEngine: unifiedEngine,
      );

      final mountRes = await memEngine.mountDiscoveredExternalSubtitles(
        textSubtitlePaths: [chsFile.path],
        trackMemory: const CrossEpisodeTrackMemory(),
        trackPreferences: const TrackPreferences(),
      );
      expect(mountRes.applied, isTrue);

      for (var i = 0; i < 3; i++) {
        await memEngine.applyIntent(
          AuthoritativeSubtitleIntent(
            primary: SubtitleSlotRequest.memory(
              localFilePath: chsFile.path,
              fileName: p.basename(chsFile.path),
              displayTitle: 'Ep01 [繁]',
              openCcMode: SubtitleOpenCcMode.toTraditional,
            ),
          ),
        );
        await memEngine.applyIntent(
          AuthoritativeSubtitleIntent(
            primary: SubtitleSlotRequest.memory(
              localFilePath: chsFile.path,
              fileName: p.basename(chsFile.path),
              displayTitle: 'Ep01 [原]',
              openCcMode: SubtitleOpenCcMode.none,
            ),
          ),
        );
      }

      // 派生轨经过清理后保持有界不无限累加
      expect(fakeClient.tracks.length, lessThanOrEqualTo(2));
    });
  });
}
