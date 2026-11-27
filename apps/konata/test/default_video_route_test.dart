import 'dart:async';
import 'dart:io';

import 'package:engine_playback/engine_playback.dart';
import 'package:feature_player_video/feature_player_video.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:konata/bootstrap/app_bootstrap.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_design_system/konata_design_system.dart';
import 'package:konata_storage/konata_storage.dart';

final class _VideoRelay implements DesktopRelayGateway {
  final requests = <({EpisodeId episode, VariantId variant, int position})>[];
  bool configured = true;
  @override
  Future<List<RelayTargetDescriptor>> listVideoTargets() async => configured
      ? [
          const RelayTargetDescriptor(
            id: 'test',
            name: '测试播放器',
            kindKey: 'mpv',
            isDefault: true,
            configured: true,
          ),
        ]
      : [];

  @override
  Future<LaunchPlaybackResult> launchVideo({
    required WorkRecord work,
    required EpisodeSummaryView episode,
    required MediaVariantRecord variant,
    MediaSourceView? source,
    String? targetId,
    String? preferredKindKey,
    int startSeconds = 0,
    int? mainEpisodeCount,
    PlaybackProgressCallback? onProgressUpdate,
  }) async {
    requests.add((
      episode: episode.id,
      variant: variant.id,
      position: startSeconds,
    ));
    return const LaunchPlaybackResult(launched: true, message: '测试外部播放器已启动');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('宿主默认视频路由实际调用外部接力且拒绝失效历史目标', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final relay = _VideoRelay();
    final temp = Directory.systemTemp.createTempSync('konata_default_video_');
    addTearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });
    late KonataBootstrapContext boot;
    await tester.runAsync(() async {
      boot = await KonataBootstrapContext.initialize(
        platform: KonataPlatform.windows,
        storageRoot: PortableStorageRootService(overrideRootPath: temp.path),
        secureStorage: InMemorySecureStorage(),
        filePicker: const NoopFilePickerPort(),
        backupFilePort: const NoopBackupFilePort(),
        urlOpener: const NoopUrlOpenerPort(),
        useInMemoryDatabases: true,
        autoStartDetailWarmupAndBackfill: false,
        desktopRelayGateway: relay,
      );
    });
    addTearDown(() => tester.runAsync(boot.dispose));
    const work = WorkId.trusted('route-work');
    const ep = EpisodeId.trusted('route-ep');
    const variant = VariantId.trusted('route-variant');
    const src = SourceId.trusted('route-src');
    final library = boot.databases.library;
    library.works.upsert(const WorkRecord(id: work, title: '路由测试'));
    library.episodes.upsert(
      const EpisodeRecord(
        id: ep,
        workId: work,
        seasonNumber: 1,
        episodeNumber: 1,
      ),
    );
    library.mediaSources.upsert(
      MediaSourceRecord(
        id: src,
        kind: MediaSourceKind.local,
        label: '测试',
        location: temp.path,
      ),
    );
    library.mediaVariants.upsert(
      const MediaVariantRecord(
        id: variant,
        workId: work,
        episodeId: ep,
        sourceId: src,
        relativePath: 'test.mkv',
        fileName: 'test.mkv',
        fileSize: 100,
        assetKind: AssetKind.video,
      ),
    );
    boot.databases.userState.playbackRecords.upsert(
      const PlaybackRecordEntity(
        id: 'route-work::route-ep',
        workId: work,
        episodeId: ep,
        variantId: variant,
        playedAtMs: 100,
        positionSeconds: 44,
        durationSeconds: 100,
      ),
    );
    await tester.pumpWidget(
      KonataBootstrapApp(bootstrap: boot, platformLabel: 'Windows'),
    );
    Future<void> frames() async {
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }
    }

    await frames();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(KonataAdaptiveShell)),
    );
    final prefs = container.read(videoPlaybackPreferencesStoreProvider);
    final navigator =
        container.read(featurePlayerVideoDependenciesProvider).navigator
            as HostAppNavigator;
    prefs.setPreferredEngine(PreferredPlaybackEngine.desktopRelay);
    final manager = container.read(activeVideoSessionManagerProvider);
    unawaited(
      navigator.openVideoPlayer(
        workId: work,
        episodeId: ep,
        variantId: variant,
        initialPositionSeconds: 18,
      ),
    );
    await frames();
    expect(relay.requests.single, (
      episode: ep,
      variant: variant,
      position: 18,
    ));
    expect(manager.hasActiveSession, isFalse);
    unawaited(navigator.openVideoPlayer(workId: work));
    await frames();
    expect(relay.requests.last.position, 44);
    expect(relay.requests.length, 2);
    unawaited(
      navigator.openVideoPlayer(
        workId: work,
        episodeId: ep,
        variantId: const VariantId.trusted('missing'),
      ),
    );
    await frames();
    expect(relay.requests.length, 2);
    expect(manager.hasActiveSession, isFalse);
    relay.configured = false;
    unawaited(
      navigator.openVideoPlayer(
        workId: work,
        episodeId: ep,
        variantId: variant,
      ),
    );
    await frames();
    expect(relay.requests.length, 2);
    expect(manager.hasActiveSession, isFalse);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await frames();
  });
}
