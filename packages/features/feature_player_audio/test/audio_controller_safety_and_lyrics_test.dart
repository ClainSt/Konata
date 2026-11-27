import 'dart:typed_data';

import 'package:engine_playback/engine_playback.dart';
import 'package:feature_player_audio/feature_player_audio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';

import 'test_fakes.dart';

void main() {
  late KonataDatabaseBundle db;
  late ScopedPrefsStore store;
  late AudioPlaybackPreferences prefsRepo;
  late UnifiedPlaybackEngine engine;
  late AudiophileSafetyCoordinator safetyCoordinator;
  late List<FakeLibMpvClient> spawnedClients;

  setUp(() {
    db = KonataDatabaseBundle.openInMemory();
    store = ScopedPrefsStore(db.userState);
    prefsRepo = AudioPlaybackPreferences(store: store);
    engine = UnifiedPlaybackEngine();
    safetyCoordinator = AudiophileSafetyCoordinator(
      engine: engine,
      isWindowsOverride: true,
    );
    spawnedClients = <FakeLibMpvClient>[];
  });

  tearDown(() async {
    await db.close();
  });

  AudioPlaybackController createController({
    LyricDisplayPort? lyricPort,
    PlaybackHostWindowPort windowPort = const NoopPlaybackHostWindowPort(),
  }) {
    final files = <String, Uint8List>{
      'CD/01. Track A.flac': Uint8List.fromList([1, 2, 3]),
      'CD/02. Track B.flac': Uint8List.fromList([4, 5, 6]),
    };
    return AudioPlaybackController(
      preferences: prefsRepo,
      assets: AudioPlaybackAssets(),
      engine: engine,
      safetyCoordinator: safetyCoordinator,
      gatewayFactory: FakeGatewayFactory(files),
      streamBridge: FakeStreamBridge(),
      windowPort: windowPort,
      lyricPort: lyricPort,
      database: db,
      isWindowsOverride: true,
      mpvClientFactoryOverride: () {
        final client = FakeLibMpvClient();
        spawnedClients.add(client);
        return client;
      },
    );
  }

  test('独占直通默认强制开启 -12 dBFS 限幅链，仅经实证与会话二次解锁后才旁路且支持随时重锁', () async {
    prefsRepo.update(
      (p) => p.copyWith(
        exclusiveAudioOutput: true,
        audiophileSafetyLimiterEnabled: true,
      ),
    );
    final controller = createController();
    addTearDown(controller.dispose);

    await controller.playCdCollection(
      work: makeTestWork(),
      variants: [
        makeTestCdVariant(id: 'v1', relativePath: 'CD/01. Track A.flac'),
      ],
      sources: [makeTestSource()],
    );

    final mpv = spawnedClients.single;
    expect(controller.snapshot.audiophilePlan.safetyLimiterEngaged, isTrue);
    expect(
      mpv.currentAf,
      contains(AudiophileSafetyPolicy.postDspSafetyLimiterFilter),
    );

    // 未检测前不可借解锁操作隐式通过核验或修改持久化门锁。
    final denied = await controller.confirmFullScaleUnlock();
    expect(denied.safetyLimiterEngaged, isTrue);
    expect(
      controller.snapshot.audiophileSafetyState.allowFullScaleBypass,
      isFalse,
    );
    expect(prefsRepo.read().audiophileSafetyLimiterEnabled, isTrue);
    // 执行硬件实证并用户显式确认解锁当次会话满幅直通。
    final verifyResult = await controller.verifyAudiophileHardwareRoute();
    expect(verifyResult.verified, isTrue);
    final unlockedPlan = await controller.confirmFullScaleUnlock();
    expect(unlockedPlan.safetyLimiterEngaged, isFalse);
    expect(mpv.currentAf, isEmpty);
    expect(
      controller.snapshot.audiophileSafetyState.allowFullScaleBypass,
      isTrue,
    );
    expect(prefsRepo.read().audiophileSafetyLimiterEnabled, isTrue);

    // 重新开启安全限幅或发生外设拔出热插拔时，应立即恢复 -12 dBFS 上限。
    await controller.setAudiophileSafetyLimiterEnabled(true);
    expect(controller.snapshot.audiophilePlan.safetyLimiterEngaged, isTrue);
    expect(
      mpv.currentAf,
      contains(AudiophileSafetyPolicy.postDspSafetyLimiterFilter),
    );

    safetyCoordinator.handleExternalDeviceRemoved('usb_unplugged');
    await pumpEventQueue();
    expect(controller.playingListenable.value, isFalse);
    expect(mpv.getPropertyFlag('mute'), isTrue);
    expect(mpv.getPropertyFlag('pause'), isTrue);
  });

  test('存在正向回放增益 DSP 时，-12 dBFS 限幅器必须位于滤镜链最末端且透传下发参数', () async {
    prefsRepo.update(
      (p) => p.copyWith(
        replayGainMode: AudioReplayGainMode.track,
        replayGainPreampDb: 4.5,
      ),
    );
    final controller = createController();
    addTearDown(controller.dispose);

    await controller.playCdCollection(
      work: makeTestWork(),
      variants: [
        makeTestCdVariant(id: 'v1', relativePath: 'CD/01. Track A.flac'),
      ],
      sources: [makeTestSource()],
    );

    final mpv = spawnedClients.single;
    expect(mpv.getPropertyString('replaygain'), 'track');
    expect(mpv.getPropertyDouble('replaygain-preamp'), closeTo(4.5, 0.01));
    expect(controller.snapshot.audiophilePlan.safetyLimiterEngaged, isTrue);
    expect(
      mpv.currentAf,
      endsWith(AudiophileSafetyPolicy.postDspSafetyLimiterFilter),
    );
  });

  test('接入 LyricDisplayPort 时仅在切歌/停播低频同步且暂停或隐藏时释放高频位置监听', () async {
    final spyLyrics = SpyLyricDisplayPort();
    final spyWindow = SpyHostWindowPort();
    final controller = createController(
      lyricPort: spyLyrics,
      windowPort: spyWindow,
    );
    addTearDown(controller.dispose);

    await controller.playCdCollection(
      work: makeTestWork(),
      variants: [
        makeTestCdVariant(id: 'v1', relativePath: 'CD/01. Track A.flac'),
        makeTestCdVariant(id: 'v2', relativePath: 'CD/02. Track B.flac'),
      ],
      sources: [makeTestSource()],
    );

    final mpv = spawnedClients.single;
    expect(spyLyrics.resolvedQueries.length, 1);
    expect(spyLyrics.resolvedQueries.single.title, 'Track A');
    expect(spyLyrics.prefetchedBatches.length, 1);
    expect(spyLyrics.prefetchedBatches.single.single.title, 'Track B');
    expect(mpv.isObserving('time-pos'), isTrue);

    // 连续推送多次播放进度仅触发叶子 ValueNotifier，严禁再次调用歌词端口 resolveForTrack。
    mpv.emitDuration(200.0);
    for (var s = 1; s <= 10; s++) {
      mpv.emitTimePos(s.toDouble());
    }
    await pumpEventQueue();
    expect(spyLyrics.resolvedQueries.length, 1);
    expect(controller.positionListenable.value.inSeconds, 10);
    expect(spyLyrics.lyricPosition.inSeconds, 10);
    await controller.seekToTrackPosition(const Duration(seconds: 19));
    expect(spyLyrics.lyricPosition.inSeconds, 19);
    await controller.seekToTrackPosition(const Duration(seconds: 3));
    expect(spyLyrics.lyricPosition.inSeconds, 3);

    // 暂停或舞台隐藏时立刻退订底层 `time-pos` 观察。
    await controller.setPlaying(false);
    expect(mpv.isObserving('time-pos'), isFalse);
    expect(spyLyrics.lyricPlaying, isFalse);

    // 切换至下一曲时再次低频触发歌词解析。
    await controller.next();
    expect(spyLyrics.resolvedQueries.length, 2);
    expect(spyLyrics.resolvedQueries.last.title, 'Track B');

    // 切换桌面迷你置顶窗应通过窗口抽象端口调用。
    await controller.setDesktopMiniWindow(true);
    expect(spyWindow.enterMiniCount, 1);

    // 结束会话应清理歌词端口、写回 cd:: 历史记录并退出桌面小窗。
    await controller.stopAndClose();
    expect(spyLyrics.clearCount, greaterThanOrEqualTo(1));
    expect(spyWindow.exitMiniCount, 1);

    final latestHistory = db.userState.playbackRecords.findLatestByWork(
      WorkId('work_cd_1'),
    );
    expect(latestHistory, isNotNull);
    expect(latestHistory!.isAudioRecord, isTrue);
  });

  test('lyricPort 为 null 时全流程启播、切歌、定位与停播优雅降级零报错', () async {
    final controller = createController(lyricPort: null);
    addTearDown(controller.dispose);

    await controller.playCdCollection(
      work: makeTestWork(),
      variants: [
        makeTestCdVariant(id: 'v1', relativePath: 'CD/01. Track A.flac'),
        makeTestCdVariant(id: 'v2', relativePath: 'CD/02. Track B.flac'),
      ],
      sources: [makeTestSource()],
    );

    expect(controller.snapshot.isActive, isTrue);
    await controller.seekRelativeTrackSeconds(15.0);
    await controller.next();
    await controller.setPlaying(false);
    await controller.stopAndClose();
    expect(controller.snapshot.isActive, isFalse);
  });
}
