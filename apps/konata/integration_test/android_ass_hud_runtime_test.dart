import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:engine_playback/engine_playback.dart';
import 'package:feature_player_video/feature_player_video.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:konata/bootstrap/android_platform_bridges.dart';
import 'package:konata/bootstrap/app_bootstrap.dart';
import 'package:konata/bootstrap/host_storage_adapters.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_design_system/konata_design_system.dart';
import 'package:konata_storage/konata_storage.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('Android 真机复杂 ASS 播控避让与恢复', (tester) async {
    expect(Platform.isAndroid, isTrue);
    const fixtureUrl = String.fromEnvironment('KONATA_ANDROID_AUDIT_URL');
    expect(fixtureUrl, startsWith('http://127.0.0.1:'));
    final parent = Directory(
      await (await createAndroidStorageRoot()).resolveAppRootPath(),
    );
    await parent.create(recursive: true);
    final root = await parent.createTemp('konata-android-audit-');
    final fixture = Directory('${root.path}/fixture')..createSync();
    final surface = AndroidVideoSurfaceAdapter();
    final route = AndroidAudioRouteAdapter();
    final host = AndroidPlaybackWindowAdapter();
    final http = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    KonataBootstrapContext? bootstrap;
    ActiveVideoSessionManager? manager;
    final evidence = <String, Object?>{};
    Future<void> until(
      bool Function() condition,
      String reason, {
      int seconds = 25,
    }) async {
      final watch = Stopwatch()..start();
      while (!condition() && watch.elapsed.inSeconds < seconds) {
        await tester.pump(const Duration(milliseconds: 100));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(condition(), isTrue, reason: reason);
    }

    Future<void> capture(String stage) async {
      final request = await http.getUrl(
        Uri.parse('$fixtureUrl/capture/$stage'),
      );
      final response = await request.close();
      expect(
        response.statusCode,
        200,
        reason: await utf8.decoder.bind(response).join(),
      );
      evidence['capture_$stage'] = true;
    }

    try {
      for (final path in ['01.mkv', '01.sc.ass']) {
        final file = File('${fixture.path}/$path');
        final request = await http.getUrl(Uri.parse('$fixtureUrl/media/$path'));
        final response = await request.close();
        expect(response.statusCode, 200);
        await response.pipe(file.openWrite());
        expect(await file.length(), greaterThan(0));
      }
      final ass = File('${fixture.path}/01.sc.ass');
      final originalAss = await ass.readAsBytes();
      final view = binding.platformDispatcher.views.first;
      final platform =
          view.physicalSize.shortestSide / view.devicePixelRatio >= 600
          ? KonataPlatform.androidTablet
          : KonataPlatform.androidPhone;
      final boot = await KonataBootstrapContext.initialize(
        platform: platform,
        storageRoot: PortableStorageRootService(overrideRootPath: root.path),
        secureStorage: InMemorySecureStorage(),
        filePicker: const NoopFilePickerPort(),
        backupFilePort: const NoopBackupFilePort(),
        urlOpener: const NoopUrlOpenerPort(),
        hostWindow: host,
        androidSurfacePort: surface,
        androidAudioRoutePort: route,
        androidAudioFocusPort: AndroidAudioFocusAdapter(),
        androidMediaSessionPort: AndroidMediaSessionAdapter(),
        androidPipPort: AndroidPipAdapter(),
        useInMemoryDatabases: true,
        autoStartDetailWarmupAndBackfill: false,
        autoStartOngoingWorksSync: false,
      );
      bootstrap = boot;
      const work = WorkId.trusted('android-audit-work');
      const episode = EpisodeId.trusted('android-audit-episode');
      const source = SourceId.trusted('android-audit-source');
      const variant = VariantId.trusted('android-audit-video');
      final db = boot.databases.library;
      db.mediaSources.upsert(
        MediaSourceRecord(
          id: source,
          kind: MediaSourceKind.local,
          label: '隔离真机合成媒体',
          location: fixture.path,
          createdAtMs: 1,
          updatedAtMs: 1,
        ),
      );
      db.works.upsert(
        const WorkRecord(
          id: work,
          title: '复杂字幕验收',
          tmdbMediaType: TmdbMediaType.tv,
          scrapeStatus: ScrapeStatus.matched,
        ),
      );
      db.episodes.upsert(
        const EpisodeRecord(
          id: episode,
          workId: work,
          seasonNumber: 1,
          episodeNumber: 1,
          title: '实播',
        ),
      );
      db.mediaVariants.upsert(
        MediaVariantRecord(
          id: variant,
          workId: work,
          episodeId: episode,
          sourceId: source,
          relativePath: '01.mkv',
          fileName: '01.mkv',
          fileSize: File('${fixture.path}/01.mkv').lengthSync(),
          assetKind: AssetKind.video,
          externalSubtitles: const ['01.sc.ass'],
        ),
      );
      await tester.pumpWidget(
        KonataBootstrapApp(bootstrap: boot, platformLabel: platform.name),
      );
      await until(
        () => find.byType(KonataAdaptiveShell).evaluate().isNotEmpty,
        '主界面未挂载',
      );
      final container = ProviderScope.containerOf(
        tester.element(find.byType(KonataAdaptiveShell)),
      );
      final prefs = container.read(videoPlaybackPreferencesStoreProvider);
      prefs.updateQualityConfig(
        (q) => q.copyWith(subOverrideMode: SubtitleAssOverrideMode.preserveAss),
      );
      manager = container.read(activeVideoSessionManagerProvider);
      unawaited(
        container
            .read(appNavigatorProvider)
            .openVideoPlayer(
              workId: work,
              episodeId: episode,
              variantId: variant,
            ),
      );
      await until(
        () =>
            manager?.controller?.state.hasFirstFrame == true &&
            view.physicalSize.width > view.physicalSize.height,
        '未取得横屏视频首帧',
        seconds: 40,
      );
      final video = manager!.controller!;
      video.setVolume(0);
      await video.setPlaying(false);
      await until(
        () => video.state.subtitles.any((s) => s.isExternal),
        '未发现合成 ASS',
      );
      await video.selectSubtitleChoice(
        video.state.subtitles.firstWhere((s) => s.isExternal),
      );
      await video.setSubtitleOpenCcMode(SubtitleOpenCcMode.none);
      final client = boot.playbackEngine.activeNativeClient!;
      final sid = client.getPropertyString('sid');
      expect(int.tryParse(sid ?? ''), isNotNull);
      final descriptor = await surface.queryCurrent();
      expect(descriptor, isNotNull);
      evidence['surface_width'] = descriptor!.width;
      evidence['surface_height'] = descriptor.height;
      evidence['render_backend'] = video.state.renderBackend;
      await video.seekToSeconds(10);
      await until(
        () =>
            ((client.getPropertyDouble('time-pos') ?? 0) - 10).abs() < 0.2 &&
            (client.getPropertyString('sub-text') ?? '').contains(
              'NORMAL DIALOGUE',
            ),
        '未定位复杂 ASS',
      );
      final touch = find.byKey(const ValueKey('video_touch_gesture_surface'));
      final capsule = find.byKey(
        const ValueKey('embedded_video_bottom_capsule'),
      );
      double pos() => client.getPropertyDouble('sub-pos') ?? -1;
      String mode() => client.getPropertyString('sub-ass-override') ?? '';
      Future<void> tapCanvas() async {
        await tester.tapAt(tester.getCenter(touch));
        await tester.pump(const Duration(milliseconds: 500));
      }

      Future<void> waitMode(bool visible) async {
        await until(
          () => visible
              ? mode() == 'scale' &&
                    pos() < 99 &&
                    capsule.hitTestable().evaluate().isNotEmpty
              : mode() == 'no' &&
                    (pos() - 100).abs() < 0.1 &&
                    capsule.hitTestable().evaluate().isEmpty,
          '实际 HUD 与原生字幕状态未同步',
        );
        expect(boot.playbackEngine.activeNativeClient, same(client));
        expect(client.getPropertyString('sid'), sid);
        expect(video.state.isPlaying, isFalse);
        await until(() {
          final text = client.getPropertyString('sub-text') ?? '';
          return [
            'NORMAL DIALOGUE',
            'MOVING',
            'CLIPPED TEXT',
            'KARAOKE',
          ].every(text.contains);
        }, '覆写切换后已生效的 ASS 事件丢失');
      }

      Future<void> sample(String name) async {
        await tester.pump(const Duration(milliseconds: 450));
        await capture(name);
        evidence[name] = {
          'position': pos(),
          'mode': mode(),
          'time': client.getPropertyDouble('time-pos'),
        };
        debugPrint('ANDROID_ASS_SAMPLE $name: ${evidence[name]}');
      }

      if (mode() == 'scale') await tapCanvas();
      await waitMode(false);
      await sample('ass-hidden-before');
      expect(client.setPropertyFlag('sub-visibility', false), 0);
      await tester.pump(const Duration(milliseconds: 500));
      await sample('ass-baseline');
      expect(client.setPropertyFlag('sub-visibility', true), 0);
      await tester.pump(const Duration(milliseconds: 500));
      await tapCanvas();
      await waitMode(true);
      await sample('ass-visible');
      await tapCanvas();
      await waitMode(false);
      await sample('ass-hidden-after');
      expect(await ass.readAsBytes(), originalAss);
      await video.setPlaying(true);
      await until(
        () => (client.getPropertyDouble('time-pos') ?? 0) > 10.5,
        '恢复播放后时钟未推进',
      );
      expect(boot.playbackEngine.activeNativeClient, same(client));
      expect(client.getPropertyString('sid'), sid);
      evidence['clock_resumed'] = true;
      expect(tester.takeException(), isNull);
      binding.reportData = evidence;
      debugPrint('ANDROID_ASS_EVIDENCE=${jsonEncode(evidence)}');
    } finally {
      if (manager?.hasActiveSession == true) {
        await manager!.closeActiveSession();
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await bootstrap?.dispose();
      if (bootstrap == null) {
        route.dispose();
        await surface.dispose();
      }
      http.close(force: true);
      await host.setPreferredLandscape(false);
      await root.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
