import 'dart:async';

import 'package:feature_lyrics/feature_lyrics.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';

import 'support/lyrics_test_helpers.dart';

void main() {
  group('LyricDisplayController 契约、句边界热升级与三级偏移叠加', () {
    test('渐进升级仅在跨越歌词行边界后平滑落位，绝不打断正在唱的一行', () async {
      final bundle = KonataDatabaseBundle.openInMemory();
      addTearDown(bundle.close);
      final prefsStore = LyricsPreferencesStore(ScopedPrefsStore(bundle.userState));
      final cacheRepo = StorageLyricCacheRepository.fromBundle(bundle);
      final positionNotifier = ValueNotifier<Duration>(const Duration(seconds: 12));
      final playingNotifier = ValueNotifier<bool>(true);
      addTearDown(positionNotifier.dispose);
      addTearDown(playingNotifier.dispose);

      final resolver = LyricsResolver(
        cacheRepository: cacheRepo,
        raceEngine: const LyricRaceEngine(
          firstPaintGrace: Duration(milliseconds: 25),
          lowConfidencePaintAfter: Duration(milliseconds: 80),
          deadline: Duration(milliseconds: 300),
        ),
        sourcesFactory: () async => [
          FakeLyricCandidateSource(
            label: 'FastPlain',
            streamBuilder: (_) => Stream.fromIterable([
              const LyricCandidate(
                source: LyricSource.lrclib,
                sourceId: 'plain-1',
                title: '光の海',
                artist: 'Singer',
                durationSeconds: 210.0,
                lrcContent: kSampleJapaneseLrc,
              ),
            ]),
          ),
          FakeLyricCandidateSource(
            label: 'SlowAmllWord',
            streamBuilder: (_) => Stream.fromFuture(
              Future<LyricCandidate>.delayed(
                const Duration(milliseconds: 65),
                () => const LyricCandidate(
                  source: LyricSource.amll,
                  sourceId: 'amll-word-1',
                  title: '光の海',
                  artist: 'Singer',
                  durationSeconds: 210.0,
                  lrcContent: '''
[00:10.00]<00:10.000-00:11.500>光の中へと手を伸ばして
[00:15.00]<00:15.000-00:16.500>風の歌が今響いてる
[00:20.00]<00:20.000-00:21.500>空の彼方まで駆け出そう
[00:25.00]<00:25.000-00:26.500>君と描いた未来へ
''',
                  hasWordTiming: true,
                ),
              ),
            ),
          ),
        ],
      );

      final controller = LyricDisplayController(
        resolver: resolver,
        preferencesStore: prefsStore,
        positionListenable: positionNotifier,
        isPlayingListenable: playingNotifier,
      );
      addTearDown(controller.dispose);

      await controller.resolveForTrack(
        const LyricTrackQuery(
          trackKey: 'track-upgrade',
          albumKey: 'album-upgrade',
          title: '光の海',
          artist: 'Singer',
          durationSeconds: 210.0,
        ),
      );
      expect(controller.state.activeSource, LyricSource.lrclib);
      expect(controller.state.activeLyricIndex, 0);

      // 等待后台高阶逐字源到达（当前仍在唱第 0 句 12 秒位置，应暂挂等待跨行再生效）。
      await Future<void>.delayed(const Duration(milliseconds: 110));
      expect(controller.state.activeSource, LyricSource.lrclib);
      expect(controller.state.hasPendingUpgrade, isTrue);

      // 同一句内推进（12s -> 13s）保持当前歌词不断流。
      positionNotifier.value = const Duration(seconds: 13);
      expect(controller.state.activeSource, LyricSource.lrclib);
      expect(controller.state.hasPendingUpgrade, isTrue);

      // 跨越至第 1 句（15.1s）时自动热替换升级至 AMLL 逐字歌词。
      positionNotifier.value = const Duration(milliseconds: 15100);
      expect(controller.state.activeSource, LyricSource.amll);
      expect(controller.state.hasPendingUpgrade, isFalse);
      expect(controller.state.activeSpanLines, isNotEmpty);
      expect(controller.state.activeLyricIndex, 1);

      controller.clearActive();
      expect(controller.state.lrcDocument, isNull);
      expect(controller.state.activeSource, isNull);
    });

    test('三级偏移实时叠加、升格为专辑偏移与蓝牙路由自动切换，且高频位置更新绝不广播事件总线', () async {
      final bundle = KonataDatabaseBundle.openInMemory();
      addTearDown(bundle.close);
      final bus = InMemoryDomainEventBus();
      addTearDown(bus.dispose);
      final events = <DomainEvent>[];
      final sub = bus.stream.listen(events.add);
      addTearDown(sub.cancel);

      final prefsStore = LyricsPreferencesStore(
        ScopedPrefsStore(bundle.userState),
        eventBus: bus,
      );
      final cacheRepo = StorageLyricCacheRepository.fromBundle(bundle);
      final pos = ValueNotifier<Duration>(Duration.zero);
      final playing = ValueNotifier<bool>(true);
      addTearDown(pos.dispose);
      addTearDown(playing.dispose);

      double? requestedSeek;
      final controller = LyricDisplayController(
        resolver: LyricsResolver(
          cacheRepository: cacheRepo,
          sourcesFactory: () async => const [],
        ),
        preferencesStore: prefsStore,
        positionListenable: pos,
        isPlayingListenable: playing,
        onSeekRequested: (sec, {resumePlayback = false}) {
          requestedSeek = sec;
        },
      );
      addTearDown(controller.dispose);

      await controller.resolveForTrack(
        const LyricTrackQuery(
          trackKey: 'track-offset-1',
          albumKey: 'album-offset-1',
          title: '微调测试',
          artist: 'Tester',
          durationSeconds: 180.0,
          embeddedLrcText: kSampleJapaneseLrc,
        ),
      );

      // 60Hz 连续位置推进 30 帧，事件总线事件数量必须严格为零。
      for (var ms = 10000; ms <= 15000; ms += 167) {
        pos.value = Duration(milliseconds: ms);
      }
      await pumpEventQueue();
      expect(events, isEmpty);

      // 三级偏移调节：单曲 +300ms、蓝牙全局 +200ms。
      await controller.adjustTrackOffsetMillis(300);
      await controller.setRouteOffsetMillis(LyricAudioRouteKind.bluetooth, 200);
      expect(controller.state.offsetSnapshot.trackOffsetMillis, 300);

      // 切到蓝牙路由（AirPods）后蓝牙全局延迟立即生效叠加。
      controller.updateAudioRoute(deviceName: 'AirPods Pro');
      expect(
        controller.state.offsetSnapshot.activeRouteKind,
        LyricAudioRouteKind.bluetooth,
      );
      expect(controller.state.offsetSnapshot.totalOffsetMillis, 500);

      // 一键应用至整张专辑后单曲清零、专辑承接 +300ms，总偏移保持不变。
      await controller.promoteCurrentOffsetToAlbum();
      expect(controller.state.offsetSnapshot.trackOffsetMillis, 0);
      expect(controller.state.offsetSnapshot.albumOffsetMillis, 300);
      expect(controller.state.offsetSnapshot.totalOffsetMillis, 500);

      // 切回有线输出后总偏移随路由回到 +300ms。
      controller.updateAudioRoute(deviceName: 'USB DAC');
      expect(
        controller.state.offsetSnapshot.activeRouteKind,
        LyricAudioRouteKind.wired,
      );
      expect(controller.state.offsetSnapshot.totalOffsetMillis, 300);

      // 验证只有低频配置写入向事件总线发布 PrefsSliceChangedEvent。
      await pumpEventQueue();
      expect(events.whereType<PrefsSliceChangedEvent>(), isNotEmpty);

      // 点行跳转触发回调。
      controller.requestSeekToLyricLine(14.5);
      expect(requestedSeek, closeTo(14.5, 0.001));
    });
  });

  group('Riverpod 依赖注入图与 FeatureLyricsManifest 扩展注册', () {
    test('通过 ProviderContainer 解析端口契约并在 QQ 开关变更后生效参与竞速', () async {
      final bundle = KonataDatabaseBundle.openInMemory();
      addTearDown(bundle.close);
      final prefsStore = ScopedPrefsStore(bundle.userState);
      final bus = InMemoryDomainEventBus();
      addTearDown(bus.dispose);

      var qqRequested = false;
      final fakeHttp = FakeKonataHttpClient((method, uri, headers, body) {
        if (uri.host.contains('y.qq.com')) {
          qqRequested = true;
          return FakeLyricHttpTransport.jsonResponse({
            'req': {
              'data': {
                'body': {
                  'item_song': [
                    {
                      'mid': 'qq_demo',
                      'id': 99,
                      'name': 'QQ专用曲',
                      'singer': [
                        {'name': 'Tester'},
                      ],
                      'album': {'name': 'Demo'},
                      'interval': 200,
                    },
                  ],
                },
                'qrc': 0,
                'lyric': '',
                'trans': '',
              },
            },
          });
        }
        return FakeLyricHttpTransport.utf8Response('', statusCode: 404);
      });

      final deps = FeatureLyricsDependencies(
        databases: bundle,
        scopedPrefs: prefsStore,
        httpClient: fakeHttp,
        domainEventBus: bus,
        localDeviceId: 'dev_container',
      );

      final container = ProviderContainer(
        overrides: [featureLyricsDependenciesProvider.overrideWithValue(deps)],
      );
      addTearDown(container.dispose);

      // 校验静态清单结构与运行期清单包含 syncSlice。
      expect(featureLyricsManifest.id, 'feature_lyrics');
      expect(
        featureLyricsManifest.playerSidePanels.single.id,
        'lyrics_control',
      );
      expect(
        featureLyricsManifest.playerSidePanels.single.supportedModes,
        {PlayerMediaMode.audio},
      );
      expect(featureLyricsManifest.settingsSections.single.id, 'lyrics_sources');
      expect(featureLyricsManifest.dataProviders.length, 4);

      final runtimeManifest = createFeatureLyricsManifest(
        databases: bundle,
        httpClient: fakeHttp,
      );
      expect(
        runtimeManifest.syncSlices.single.sliceId,
        'lyric_overrides_slice',
      );

      // 1. 默认情况下 QQ 源处于关闭状态，即使启用自动解析与手动检索也不请求 QQ 接口。
      final port = container.read(lyricDisplayPortProvider);
      final ctrl = container.read(lyricDisplayControllerProvider);
      expect(identical(port, ctrl), isTrue);

      await ctrl.resolveForTrack(
        const LyricTrackQuery(
          trackKey: 'qq-check-track',
          albumKey: 'qq-check-album',
          title: 'QQ专用曲',
          artist: 'Tester',
          durationSeconds: 200.0,
        ),
      );
      await ctrl.searchCandidatesManual(title: 'QQ专用曲', artist: 'Tester');
      expect(qqRequested, isFalse);

      // 2. 开启 QQ 免责声明确认与开关后，后续检索立即并发纳入 QQ 音乐来源。
      container.read(lyricsPreferencesStoreProvider).acceptQqDisclaimerAndEnable();
      await ctrl.searchCandidatesManual(title: 'QQ专用曲', artist: 'Tester');
      expect(qqRequested, isTrue);

      final syncSlice = container.read(lyricOverridesSyncSliceProvider);
      expect(syncSlice.sliceId, 'lyric_overrides_slice');
    });
  });
}
