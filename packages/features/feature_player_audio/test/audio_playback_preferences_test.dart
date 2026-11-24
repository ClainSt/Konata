import 'package:engine_playback/engine_playback.dart';
import 'package:feature_player_audio/feature_player_audio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';

void main() {
  late KonataDatabaseBundle db;
  late ScopedPrefsStore store;
  late InMemoryDomainEventBus eventBus;
  late AudioPlaybackPreferences prefsRepo;

  setUp(() {
    db = KonataDatabaseBundle.openInMemory();
    store = ScopedPrefsStore(db.userState);
    eventBus = InMemoryDomainEventBus();
    prefsRepo = AudioPlaybackPreferences(store: store, eventBus: eventBus);
  });

  tearDown(() async {
    await eventBus.dispose();
    await db.close();
  });

  test('默认配置包含 -12 dBFS 安全天花板与规范命名空间 playback_audio', () {
    final defaults = prefsRepo.read();
    expect(AudioPlaybackPreferences.namespace, 'playback_audio');
    expect(defaults.audiophileSafetyLimiterEnabled, isTrue);
    expect(defaults.replayGainMode, AudioReplayGainMode.none);
    expect(defaults.replayGainPreampDb, 0.0);
    expect(defaults.audioResamplerPrecision, 28);
    expect(defaults.foobarBeefwebPort, 8880);
    expect(defaults.audioFloatingMiniEnabled, isTrue);
    expect(defaults.preferredAudioEngine, PreferredPlaybackEngine.builtinLibmpv);
  });

  test('写入发烧直通、回放增益与桌面外部转发设置可跨次持久化往返与发送低频事件', () async {
    final events = <DomainEvent>[];
    final sub = eventBus.stream.listen(events.add);

    prefsRepo.update(
      (p) => p.copyWith(
        defaultVolume: 64.0,
        isMuted: true,
        loopMode: AudioLoopMode.loopOne,
        shuffleEnabled: true,
        audiophileSafetyLimiterEnabled: false,
        replayGainMode: AudioReplayGainMode.album,
        replayGainPreampDb: 3.5,
        preferredAudioEngine: PreferredPlaybackEngine.desktopRelay,
        audioResamplerPrecision: 32,
        exclusiveAudioOutput: true,
        audioDevice: 'wasapi/{dac}',
        keepPitch: false,
        bitstreamPassthrough: true,
        androidBitPerfectUsb: true,
        audioFloatingMiniEnabled: false,
        foobarBeefwebPort: 8888,
        skipFoobarBeefwebPrompt: true,
        preferredRelayTargetId: 'foobar2000',
      ),
    );

    await pumpEventQueue();
    final raw = await store.readRawSlice('playback_audio');
    expect(raw, isNotNull);
    expect(raw!['replayGainMode'], 'album');
    expect(raw['foobarBeefwebPort'], 8888);

    // 使用新仓库实例重新反序列化校验完整往返一致。
    final freshRepo = AudioPlaybackPreferences(store: store);
    final restored = freshRepo.read();
    expect(restored.defaultVolume, 64.0);
    expect(restored.isMuted, isTrue);
    expect(restored.loopMode, AudioLoopMode.loopOne);
    expect(restored.shuffleEnabled, isTrue);
    expect(restored.audiophileSafetyLimiterEnabled, isFalse);
    expect(restored.replayGainMode, AudioReplayGainMode.album);
    expect(restored.replayGainPreampDb, 3.5);
    expect(restored.preferredAudioEngine, PreferredPlaybackEngine.desktopRelay);
    expect(restored.audioResamplerPrecision, 32);
    expect(restored.exclusiveAudioOutput, isTrue);
    expect(restored.audioDevice, 'wasapi/{dac}');
    expect(restored.keepPitch, isFalse);
    expect(restored.bitstreamPassthrough, isTrue);
    expect(restored.androidBitPerfectUsb, isTrue);
    expect(restored.audioFloatingMiniEnabled, isFalse);
    expect(restored.foobarBeefwebPort, 8888);
    expect(restored.skipFoobarBeefwebPrompt, isTrue);
    expect(restored.preferredRelayTargetId, 'foobar2000');

    final audiophile = restored.toAudiophilePreferences();
    expect(audiophile.bitstreamPassthrough, isTrue);
    expect(audiophile.androidBitPerfectUsb, isTrue);
    expect(audiophile.qualityConfig.exclusiveAudioOutput, isTrue);
    expect(audiophile.qualityConfig.audioResamplerPrecision, 32);

    expect(
      events.whereType<PrefsSliceChangedEvent>().map((e) => e.namespace),
      contains('playback_audio'),
    );

    prefsRepo.resetToDefaults();
    expect(freshRepo.read().audiophileSafetyLimiterEnabled, isTrue);
    expect(freshRepo.read().replayGainMode, AudioReplayGainMode.none);
    await sub.cancel();
  });
}
