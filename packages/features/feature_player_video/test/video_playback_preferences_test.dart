import 'dart:io';
import 'dart:typed_data';

import 'package:engine_playback/engine_playback.dart';
import 'package:feature_player_video/feature_player_video.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';

import 'support/video_test_harness.dart';

void main() {
  group('VideoPlaybackPreferencesStore 自治偏好切片', () {
    test('黄金源默认子集化地址兼容空旧配置且不产生授权', () async {
      const endpoint = 'https://font.anibt.net/api/subset';
      expect(FontInAssCloudClient.defaultEndpointUrl, endpoint);
      expect(const VideoPlaybackPreferences().fontInAssEndpoint, endpoint);
      for (final value in [null, '', '   ']) {
        final prefs = VideoPlaybackPreferences.fromJson({
          'fontInAssEndpoint': value,
          'enableCloudSubset': true,
          'volume': 0.4,
        }, 2);
        expect(prefs.fontInAssEndpoint, endpoint);
        expect(prefs.enableCloudSubset, isFalse);
        expect(prefs.authorizedCloudSubsetOrigins, isEmpty);
        expect(prefs.volume, 0.4);
      }
      final custom = VideoPlaybackPreferences.fromJson({
        'fontInAssEndpoint': 'https://custom.example/api/subset',
        'enableCloudSubset': true,
        'authorizedCloudSubsetOrigins': ['https://custom.example'],
      }, 2);
      expect(custom.fontInAssEndpoint, 'https://custom.example/api/subset');
      expect(custom.enableCloudSubset, isTrue);
      expect(custom.authorizedCloudSubsetOrigins, ['https://custom.example']);
      final h = await VideoTestHarness.create();
      addTearDown(h.dispose);
      expect(h.preferencesStore.read().fontInAssEndpoint, endpoint);
      expect(h.preferencesStore.read().enableCloudSubset, isFalse);
      h.preferencesStore.updateCloudSubsetSettings(
        endpointUrl: custom.fontInAssEndpoint,
      );
      expect(
        h.preferencesStore.read().fontInAssEndpoint,
        custom.fontInAssEndpoint,
      );
      expect(h.preferencesStore.read().authorizedCloudSubsetOrigins, isEmpty);
    });
    test('自动画中画默认开启且可持久关闭，旧载荷安全兼容', () async {
      final harness = await VideoTestHarness.create();
      addTearDown(harness.dispose);
      final store = harness.preferencesStore;
      expect(store.read().autoEnterPip, isTrue);
      store.setAutoEnterPip(false);
      final disabled = store.read();
      expect(disabled.autoEnterPip, isFalse);
      expect(disabled, isNot(const VideoPlaybackPreferences()));
      expect(VideoPlaybackPreferences.fromJson(disabled.toJson(), 2), disabled);
      expect(VideoPlaybackPreferences.fromJson({}, 2).autoEnterPip, isTrue);
      store.setAutoEnterPip(true);
      expect(store.read().autoEnterPip, isTrue);
    });
    test('输出模式原子互斥，兼容旧双开关并保留另一平台偏好', () async {
      final h = await VideoTestHarness.create();
      addTearDown(h.dispose);
      final store = h.preferencesStore;
      store.setAudioOutputRoute(
        AudioOutputRouteMode.androidBitPerfectUsb,
        platform: KonataPlatform.androidPhone,
      );
      store.setAudioOutputRoute(
        AudioOutputRouteMode.exclusiveAudioOutput,
        platform: KonataPlatform.windows,
      );
      expect(store.read().qualityConfig.exclusiveAudioOutput, isTrue);
      expect(store.read().bitstreamPassthrough, isFalse);
      expect(store.read().androidBitPerfectUsb, isTrue);
      store.setAudioOutputRoute(
        AudioOutputRouteMode.bitstreamPassthrough,
        platform: KonataPlatform.windows,
      );
      expect(store.read().qualityConfig.exclusiveAudioOutput, isFalse);
      expect(store.read().bitstreamPassthrough, isTrue);
      store.setAudioOutputRoute(
        AudioOutputRouteMode.sharedResampled,
        platform: KonataPlatform.windows,
      );
      expect(store.read().bitstreamPassthrough, isFalse);
      expect(store.read().androidBitPerfectUsb, isTrue);
      final restored = VideoPlaybackPreferences.fromJson({
        'qualityConfig': {'exclusiveAudioOutput': true},
        'bitstreamPassthrough': true,
      }, 2);
      expect(restored.bitstreamPassthrough, isTrue);
      expect(restored.qualityConfig.exclusiveAudioOutput, isFalse);
    });
    test('读取默认值并在写入与恢复后保持往返一致且发出领域事件', () async {
      final harness = await VideoTestHarness.create();
      addTearDown(harness.dispose);

      final events = <PrefsSliceChangedEvent>[];
      final eventSub = harness.domainEventBus
          .on<PrefsSliceChangedEvent>()
          .listen(events.add);
      addTearDown(eventSub.cancel);

      final initial = harness.preferencesStore.read();
      expect(initial.preferredEngine, PreferredPlaybackEngine.builtinLibmpv);
      expect(initial.volume, 1.0);
      expect(initial.autoPlayNextEpisode, isTrue);
      expect(initial.autoSkipChapters, isFalse);

      final streamEmissions = <VideoPlaybackPreferences>[];
      final streamSub = harness.preferencesStore.watch().listen(
        streamEmissions.add,
      );
      addTearDown(streamSub.cancel);

      harness.preferencesStore.update(
        (cur) => cur.copyWith(
          preferredEngine: PreferredPlaybackEngine.desktopRelay,
          volume: 0.65,
          isMuted: true,
          autoPlayNextEpisode: false,
          autoSkipChapters: true,
          enableCloudSubset: true,
          fontInAssEndpoint: 'https://subset.example.com/api',
          authorizedCloudSubsetOrigins: const <String>[
            'https://subset.example.com',
          ],
          qualityConfig: cur.qualityConfig.copyWith(
            preset: VideoQualityPreset.standard,
            outputPipelineMode: VideoOutputPipelineMode.layered10Bit,
            hardwareDecode: false,
            debandEnabled: true,
            activeShaderPaths: const <String>['anime4k.glsl'],
          ),
        ),
      );
      await Future<void>.delayed(Duration.zero);

      final reloaded = harness.preferencesStore.read();
      expect(reloaded.preferredEngine, PreferredPlaybackEngine.desktopRelay);
      expect(reloaded.volume, closeTo(0.65, 1e-6));
      expect(reloaded.isMuted, isTrue);
      expect(reloaded.autoPlayNextEpisode, isFalse);
      expect(reloaded.autoSkipChapters, isTrue);
      expect(reloaded.enableCloudSubset, isTrue);
      expect(reloaded.fontInAssEndpoint, 'https://subset.example.com/api');
      expect(reloaded.qualityConfig.preset, VideoQualityPreset.standard);
      expect(
        reloaded.qualityConfig.outputPipelineMode,
        VideoOutputPipelineMode.layered10Bit,
      );
      expect(reloaded.qualityConfig.hardwareDecode, isFalse);
      expect(reloaded.qualityConfig.debandEnabled, isTrue);
      expect(reloaded.qualityConfig.activeShaderPaths, <String>[
        'anime4k.glsl',
      ]);

      expect(streamEmissions, isNotEmpty);
      expect(events, hasLength(1));
      expect(events.single.namespace, 'playback_video');
    });
  });

  group('PipRecoveryStore 画中画断点恢复存储', () {
    test('损坏、缺失、负数和非有限快照安全拒绝', () {
      final valid = <String, Object?>{
        'workId': 'w',
        'episodeId': 'e',
        'variantId': 'v',
        'positionSeconds': 12,
        'updatedAtMs': 1000,
        'isPlaying': true,
      };
      expect(PipPlaybackRecoverySnapshot.tryFromJson(valid), isNotNull);
      for (final bad in <Map<String, Object?>>[
        {'workId': 1},
        {'episodeId': ''},
        {'variantId': false},
        {'positionSeconds': -1},
        {'positionSeconds': double.nan},
        {'positionSeconds': double.infinity},
        {'isPlaying': 'yes'},
        {'updatedAtMs': 'now'},
      ]) {
        expect(
          PipPlaybackRecoverySnapshot.tryFromJson({...valid, ...bad}),
          isNull,
        );
      }
    });
    test('磁盘关闭重开仍保留本机快照，错配物理版本被拒绝', () async {
      final dir = await Directory.systemTemp.createTemp('konata_pip_disk_');
      addTearDown(() => dir.delete(recursive: true));
      final root = PortableStorageRootService(overrideRootPath: dir.path);
      final first = await KonataDatabaseBundle.openFromStorageRoot(root);
      const work = WorkId.trusted('pip-work');
      const episode = EpisodeId.trusted('pip-episode');
      const variant = VariantId.trusted('pip-variant');
      const source = SourceId.trusted('pip-source');
      const otherEpisode = EpisodeId.trusted('pip-other-episode');
      final snapshot = PipPlaybackRecoverySnapshot(
        workId: work.value,
        episodeId: episode.value,
        variantId: variant.value,
        positionSeconds: 42,
        isPlaying: false,
        updatedAtMs: DateTime.now().millisecondsSinceEpoch,
      );
      try {
        first.library.works.upsert(const WorkRecord(id: work, title: '恢复测试'));
        first.library.episodes.upsert(
          const EpisodeRecord(
            id: episode,
            workId: work,
            seasonNumber: 1,
            episodeNumber: 1,
          ),
        );
        first.library.episodes.upsert(
          const EpisodeRecord(
            id: otherEpisode,
            workId: work,
            seasonNumber: 1,
            episodeNumber: 2,
          ),
        );
        first.library.mediaSources.upsert(
          MediaSourceRecord(
            id: source,
            kind: MediaSourceKind.local,
            label: '隔离夹具',
            location: dir.path,
            createdAtMs: 1,
            updatedAtMs: 1,
          ),
        );
        first.library.mediaVariants.upsert(
          const MediaVariantRecord(
            id: variant,
            workId: work,
            episodeId: episode,
            sourceId: source,
            relativePath: '01.mkv',
            fileName: '01.mkv',
            fileSize: 1,
          ),
        );
        await ScopedPrefsPipRecoveryStore(
          ScopedPrefsStore(first.userState),
        ).saveSnapshot(snapshot);
      } finally {
        await first.close();
      }
      final reopened = await KonataDatabaseBundle.openFromStorageRoot(root);
      try {
        final store = ScopedPrefsPipRecoveryStore(
          ScopedPrefsStore(reopened.userState),
        );
        final recovered = await store.readFreshSnapshot();
        expect(recovered?.toJson(), snapshot.toJson());
        expect(recovered!.matchesLibrary(reopened), isTrue);
        reopened.library.mediaVariants.upsert(
          const MediaVariantRecord(
            id: variant,
            workId: work,
            episodeId: otherEpisode,
            sourceId: source,
            relativePath: '01.mkv',
            fileName: '01.mkv',
            fileSize: 1,
          ),
        );
        expect(recovered.matchesLibrary(reopened), isFalse);
        await store.clear();
        expect(await store.readFreshSnapshot(), isNull);
      } finally {
        await reopened.close();
      }
    });
    test('保存有效快照、判断时效并在过期后自动清理', () async {
      final harness = await VideoTestHarness.create();
      addTearDown(harness.dispose);

      final now = DateTime.utc(2026, 6, 1, 12, 0);
      final snap = PipPlaybackRecoverySnapshot(
        workId: 'w_1',
        episodeId: 'ep_1',
        variantId: 'var_1',
        positionSeconds: 425,
        isPlaying: true,
        updatedAtMs: now.millisecondsSinceEpoch,
      );
      await harness.pipStore.saveSnapshot(snap);

      final fresh = await harness.pipStore.readFreshSnapshot(
        now: now.add(const Duration(hours: 2)),
      );
      expect(fresh, isNotNull);
      expect(fresh!.positionSeconds, 425);
      expect(fresh.isPlaying, isTrue);

      final expired = await harness.pipStore.readFreshSnapshot(
        now: now.add(const Duration(hours: 7)),
      );
      expect(expired, isNull);
    });
  });

  group('ShaderDiscoveryService 着色器导入、扫描与安全删除', () {
    test('仅接收合规着色器扩展名并在删除时同步关闭激活列表开关', () async {
      final harness = await VideoTestHarness.create();
      addTearDown(harness.dispose);

      final res = await harness.shaderService
          .importShaderFiles(<ShaderImportSource>[
            ShaderImportSource(
              name: 'test_upscale.glsl',
              bytes: Uint8List.fromList('//!HOOK LUMA'.codeUnits),
            ),
            ShaderImportSource(
              name: 'malicious.txt',
              bytes: Uint8List.fromList('ignored'.codeUnits),
            ),
          ]);
      expect(res.imported, hasLength(1));
      expect(res.skippedUnsupported, 1);
      expect(harness.shaderService.state.files, hasLength(1));

      final importedPath = res.imported.single.path;
      harness.preferencesStore.toggleShaderPath(importedPath, true);
      expect(
        harness.preferencesStore.read().qualityConfig.activeShaderPaths,
        contains(importedPath),
      );

      final deleted = await harness.shaderService.deleteShaderFile(
        importedPath,
      );
      expect(deleted, isTrue);
      expect(harness.shaderService.state.files, isEmpty);
      expect(
        harness.preferencesStore.read().qualityConfig.activeShaderPaths,
        isNot(contains(importedPath)),
      );
    });
  });

  group('ThumbnailBucketCache 时间桶量化与邻近兜底', () {
    test('区分本地与远程分桶步长并按容量上限淘汰旧缓存', () {
      expect(
        ThumbnailBucketCache.quantizeBucketSeconds(12.4, isRemote: false),
        closeTo(12.0, 1e-6),
      );
      expect(
        ThumbnailBucketCache.quantizeBucketSeconds(12.4, isRemote: true),
        closeTo(10.0, 1e-6),
      );

      final cache = ThumbnailBucketCache(capacity: 2);
      cache.put(5.0, Uint8List.fromList(<int>[1, 2]));
      cache.put(10.0, Uint8List.fromList(<int>[3, 4]));
      cache.put(20.0, Uint8List.fromList(<int>[5, 6]));

      expect(cache.length, 2);
      expect(cache.containsBucket(5.0), isFalse);
      expect(cache.getNearest(11.0), Uint8List.fromList(<int>[3, 4]));
    });
  });

  group('featurePlayerVideoManifest 模块扩展声明校验', () {
    test('注册播放设置全端分区及桌面专属外部工具分区，不再注册冗余侧栏', () {
      expect(featurePlayerVideoManifest.id, 'feature_player_video');
      expect(featurePlayerVideoManifest.settingsSections, hasLength(2));

      final playbackSection = featurePlayerVideoManifest.settingsSections[0];
      expect(playbackSection.id, 'playback_settings');
      expect(playbackSection.isSupportedOn(KonataPlatform.windows), isTrue);
      expect(
        playbackSection.isSupportedOn(KonataPlatform.androidPhone),
        isTrue,
      );

      final extSection = featurePlayerVideoManifest.settingsSections[1];
      expect(extSection.id, 'external_tools');
      expect(extSection.title, '外部调用');
      expect(extSection.isSupportedOn(KonataPlatform.windows), isTrue);
      expect(extSection.isSupportedOn(KonataPlatform.androidPhone), isFalse);

      expect(featurePlayerVideoManifest.playerSidePanels, isEmpty);
    });
  });
}
