import 'dart:typed_data';

import 'package:engine_playback/engine_playback.dart';
import 'package:feature_player_video/feature_player_video.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:konata_contracts/konata_contracts.dart';

import 'support/video_test_harness.dart';

void main() {
  group('VideoPlaybackPreferencesStore 自治偏好切片', () {
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

      final res = await harness.shaderService.importShaderFiles(
        <ShaderImportSource>[
          ShaderImportSource(
            name: 'test_upscale.glsl',
            bytes: Uint8List.fromList('//!HOOK LUMA'.codeUnits),
          ),
          ShaderImportSource(
            name: 'malicious.txt',
            bytes: Uint8List.fromList('ignored'.codeUnits),
          ),
        ],
      );
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
    test('注册播放设置全端分区、桌面专属外部工具分区及视频模式侧栏贡献', () {
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
      expect(extSection.isSupportedOn(KonataPlatform.windows), isTrue);
      expect(extSection.isSupportedOn(KonataPlatform.androidPhone), isFalse);

      expect(featurePlayerVideoManifest.playerSidePanels, hasLength(1));
      final panel = featurePlayerVideoManifest.playerSidePanels.single;
      expect(panel.isSupportedOn(KonataPlatform.windows, PlayerMediaMode.video), isTrue);
      expect(panel.isSupportedOn(KonataPlatform.windows, PlayerMediaMode.audio), isFalse);
    });
  });
}
