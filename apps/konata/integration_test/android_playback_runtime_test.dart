import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:feature_lyrics/feature_lyrics.dart';
import 'package:feature_player_audio/feature_player_audio.dart';
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

  testWidgets('Android 真机独立夹具播放、硬件表面、小窗及默认音频路由', (tester) async {
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
    AudioPlaybackController? audio;
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

    Future<void> tap(Finder finder) async {
      await until(
        () => finder.hitTestable().evaluate().isNotEmpty,
        '实际控件未就绪：$finder',
      );
      await tester.tap(finder.hitTestable().first);
      await tester.pump(const Duration(milliseconds: 250));
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

    Future<Map<String, dynamic>> systemAction(String action) async {
      final request = await http.getUrl(
        Uri.parse('$fixtureUrl/system/$action'),
      );
      final response = await request.close();
      final body = await utf8.decoder.bind(response).join();
      expect(response.statusCode, 200, reason: body);
      return jsonDecode(body) as Map<String, dynamic>;
    }

    try {
      for (final path in [
        '01.mkv',
        '01.sc.ass',
        'audit-poster.png',
        'CD/01.flac',
        'CD/01.lrc',
        'CD/02.flac',
      ]) {
        final file = File('${fixture.path}/$path');
        await file.parent.create(recursive: true);
        final request = await http.getUrl(Uri.parse('$fixtureUrl/media/$path'));
        final response = await request.close();
        expect(response.statusCode, 200);
        await response.pipe(file.openWrite());
        expect(await file.length(), greaterThan(0));
      }
      await File('${fixture.path}/CD/01.lrc').copy('${fixture.path}/CD/02.lrc');
      final cleared = await route.negotiateBitPerfectUsb(enable: false);
      evidence['usb_disable_supported'] = cleared.supported;
      evidence['usb_disable_confirmed'] = cleared.operationSucceeded;
      evidence['usb_disable_detail'] = cleared.detail;
      expect(cleared.engaged, isFalse);
      expect(cleared.operationSucceeded, isTrue, reason: cleared.detail);
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
        WorkRecord(
          id: work,
          posterRef: LocalCustomArtworkRef(
            localPath: '${fixture.path}/audit-poster.png',
          ),
          title: 'Android 实播验收',
          tmdbMediaType: TmdbMediaType.tv,
          scrapeStatus: ScrapeStatus.matched,
          updatedAtMs: 1,
        ),
      );
      db.episodes.upsert(
        const EpisodeRecord(
          id: episode,
          workId: work,
          seasonNumber: 1,
          episodeNumber: 1,
          category: EpisodeCategory.main,
          title: '实播',
          updatedAtMs: 1,
        ),
      );
      for (final (id, path, kind) in [
        (variant, '01.mkv', AssetKind.video),
        (
          const VariantId.trusted('android-audit-a1'),
          'CD/01.flac',
          AssetKind.cdAlbum,
        ),
        (
          const VariantId.trusted('android-audit-a2'),
          'CD/02.flac',
          AssetKind.cdAlbum,
        ),
      ]) {
        final file = File('${fixture.path}/$path');
        db.mediaVariants.upsert(
          MediaVariantRecord(
            id: id,
            workId: work,
            episodeId: kind == AssetKind.video ? episode : null,
            sourceId: source,
            relativePath: path,
            fileName: file.uri.pathSegments.last,
            fileSize: file.lengthSync(),
            assetKind: kind,
            updatedAtMs: 1,
          ),
        );
      }
      // 在根组件启动之前准备本机暂停快照，验证冷恢复不会短暂误播。
      final recoveryStore = ScopedPrefsPipRecoveryStore(boot.scopedPrefs);
      await recoveryStore.saveSnapshot(
        PipPlaybackRecoverySnapshot(
          workId: work.value,
          episodeId: episode.value,
          variantId: variant.value,
          positionSeconds: 12,
          isPlaying: false,
          updatedAtMs: DateTime.now().millisecondsSinceEpoch,
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
      final navigator = container.read(appNavigatorProvider);
      final sessions = container.read(activeVideoSessionManagerProvider);
      manager = sessions;
      await until(
        () => sessions.controller?.state.hasFirstFrame == true,
        '冷恢复没有启动指定物理视频',
        seconds: 40,
      );
      final restored = sessions.controller!;
      expect(restored.state.currentWork?.id, work);
      expect(restored.state.currentEpisode.id, episode);
      expect(restored.state.currentVariant.id, variant);
      final restoredClient = boot.playbackEngine.activeNativeClient!;
      expect(restoredClient.getPropertyFlag('pause'), isTrue);
      final coldPosition = restoredClient.getPropertyDouble('time-pos')!;
      expect(coldPosition, closeTo(12, 1));
      await Future<void>.delayed(const Duration(milliseconds: 800));
      expect(
        restoredClient.getPropertyDouble('time-pos'),
        closeTo(coldPosition, .2),
      );
      expect(await recoveryStore.readFreshSnapshot(), isNull);
      evidence['cold_route_position_seconds'] = coldPosition;
      evidence['cold_route_paused'] = true;
      evidence['cold_route_snapshot_consumed'] = true;
      await restored.setPlaying(true);
      await until(
        () =>
            sessions.controller?.state.hasFirstFrame == true &&
            (sessions.controller?.positionNotifier.value.inMilliseconds ?? 0) >
                500,
        'Android 真实视频未完成首帧及播放推进',
        seconds: 40,
      );
      final video = sessions.controller!;
      video.setVolume(10);
      final client = boot.playbackEngine.activeNativeClient!;
      final descriptor = await surface.queryCurrent();
      expect(descriptor, isNotNull, reason: '未取得实际原生视频表面');
      expect(descriptor!.width, greaterThan(0));
      expect(descriptor.height, greaterThan(0));
      evidence['video_surface_width'] = descriptor.width;
      evidence['video_surface_height'] = descriptor.height;
      evidence['video_render_backend'] = video.state.renderBackend;
      evidence['video_codec'] = video.state.probeStats.videoCodec;
      expect(video.state.durationSeconds, greaterThan(50));
      await until(
        () => view.physicalSize.width > view.physicalSize.height,
        '手机视频舞台未切换横屏',
      );
      evidence['video_landscape'] = true;
      await video.setPlaying(false);
      await video.seekToSeconds(10);
      await until(
        () =>
            (video.positionNotifier.value.inMilliseconds - 10000).abs() < 1000,
        '视频跳转失败',
      );
      video.setSubtitleDelay(0.2);
      video.setAudioDelay(0.1);
      await until(
        () =>
            ((client.getPropertyDouble('sub-delay') ?? -99) - 0.2).abs() <
                0.02 &&
            ((client.getPropertyDouble('audio-delay') ?? -99) - 0.1).abs() <
                0.02,
        '实际字幕或音频延迟未生效',
      );
      video.setSubtitleDelay(0);
      video.setAudioDelay(0);
      await capture('video-stage');
      await tap(find.byKey(const ValueKey('video_collapse_button')));
      await until(
        () =>
            sessions.shouldShowFloatingMiniPlayer &&
            find
                .byKey(const ValueKey('video_floating_mini_player'))
                .evaluate()
                .isNotEmpty,
        'Android 应用内视频小窗未出现',
      );
      expect(sessions.controller, same(video));
      expect(boot.playbackEngine.activeNativeClient, same(client));
      await capture('video-mini');
      await video.setPlaying(true);
      await until(() => video.state.isPlaying, '小窗未恢复播放');
      expect(video.canAutoEnterSystemPip(stageExpanded: false), isFalse);
      final miniHome = await systemAction('mini-home-no-pip');
      expect(miniHome['foreground'], isFalse);
      expect(miniHome['pinned'], isFalse);
      await systemAction('restore');
      await until(() => sessions.shouldShowFloatingMiniPlayer, '应用内小窗未恢复');
      expect(boot.playbackEngine.activeNativeClient, same(client));
      await video.setPlaying(false);
      await video.seekToSeconds(10);
      evidence['mini_home_no_system_pip'] = true;
      await tap(find.byKey(const ValueKey('mini_player_expand_button')));
      await until(
        () =>
            sessions.isStageExpanded &&
            video.state.miniMode == VideoMiniMode.stage,
        '视频小窗未恢复',
      );
      expect(boot.playbackEngine.activeNativeClient, same(client));
      expect(video.positionNotifier.value.inMilliseconds, closeTo(10000, 1000));
      // HOME 必须进入原生系统画中画，而非应用内悬浮播放器。
      await video.setPlaying(true);
      await until(() => video.state.isPlaying, '视频未恢复播放');
      final prefs = container.read(videoPlaybackPreferencesStoreProvider);
      prefs.setAutoEnterPip(false);
      await tester.pump(const Duration(milliseconds: 300));
      expect(video.canAutoEnterSystemPip(stageExpanded: true), isFalse);
      final disabledHome = await systemAction('disabled-home-no-pip');
      expect(disabledHome['foreground'], isFalse);
      expect(disabledHome['pinned'], isFalse);
      await systemAction('restore');
      await until(() => sessions.isStageExpanded, '关闭自动PiP后舞台未恢复');
      expect(boot.playbackEngine.activeNativeClient, same(client));
      prefs.setAutoEnterPip(true);
      await video.setPlaying(true);
      await until(
        () => video.canAutoEnterSystemPip(stageExpanded: true),
        '重新启用自动PiP后资格未恢复',
      );
      await tester.pump(const Duration(milliseconds: 300));
      evidence['disabled_home_no_system_pip'] = true;
      final pipBefore = client.getPropertyDouble('time-pos')!;
      final pip = await systemAction('video-home');
      expect(pip['pinned'], isTrue, reason: '系统未进入画中画');
      expect(video.systemPipActive, isTrue);
      final systemSnapshot = await recoveryStore.readFreshSnapshot();
      expect(systemSnapshot, isNotNull);
      expect(systemSnapshot!.workId, work.value);
      expect(systemSnapshot.episodeId, episode.value);
      expect(systemSnapshot.variantId, variant.value);
      expect(systemSnapshot.positionSeconds, closeTo(pipBefore, 3));
      evidence['system_pip_recovery_snapshot_seconds'] =
          systemSnapshot.positionSeconds;
      expect(
        find.byKey(const ValueKey('embedded_video_bottom_capsule')),
        findsNothing,
      );
      await Future<void>.delayed(const Duration(seconds: 2));
      final pipAfter = client.getPropertyDouble('time-pos')!;
      expect(pipAfter - pipBefore, greaterThan(0.5));
      await systemAction('restore');
      await until(
        () =>
            binding.platformDispatcher.views.first.physicalSize.width >
            binding.platformDispatcher.views.first.physicalSize.height,
        '画中画恢复后未返回横屏',
      );
      expect(sessions.controller, same(video));
      expect(boot.playbackEngine.activeNativeClient, same(client));
      expect((await systemAction('state'))['pinned'], isFalse);
      await until(() => !video.systemPipActive, '原生画中画退出回调未恢复舞台');
      expect(await recoveryStore.readFreshSnapshot(), isNull);
      evidence['system_pip_snapshot_cleared_on_restore'] = true;
      evidence['system_pip_progress_delta'] = pipAfter - pipBefore;
      evidence['system_pip_same_session'] = true;
      await video.setPlaying(false);
      await tap(find.byKey(const ValueKey('video_back_button')));
      await until(() => !sessions.hasActiveSession, '视频会话未关闭');
      evidence['video_mini_same_session'] = true;
      final player = container.read(audioPlaybackControllerProvider);
      audio = player;
      unawaited(navigator.openAudioPlayer(workId: work));
      await until(
        () =>
            player.snapshot.status == AudioPlaybackStatus.playing &&
            player.currentTrackPositionSeconds > 0.4,
        'Android FLAC 未播放',
        seconds: 30,
      );
      await player.setVolume(10);
      expect(player.snapshot.queue, hasLength(2));
      expect(player.snapshot.sampleRateHz, 48000);
      evidence['audio_codec'] = player.snapshot.audioCodecName;
      evidence['audio_sample_rate'] = player.snapshot.sampleRateHz;
      final lyrics = container.read(lyricDisplayControllerProvider);
      await until(() => lyrics.state.lrcDocument?.lines.length == 4, '本地歌词未装载');
      await player.seekRelativeTrackSeconds(19);
      await until(() => lyrics.state.activeLyricIndex == 2, '本地歌词未随实际播放时钟更新');
      await player.setPlaying(false);
      await until(
        () => view.physicalSize.height > view.physicalSize.width,
        '手机音频舞台未切回竖屏',
      );
      evidence['audio_portrait'] = true;
      final audioClient = boot.playbackEngine.activeNativeClient;
      final position = player.currentTrackPositionSeconds;
      await capture('audio-stage');
      await tap(find.byKey(const ValueKey('audio_minimize_button')));
      final disc = find.byKey(const ValueKey('mini_audio_disc_surface'));
      await until(() => disc.evaluate().isNotEmpty, 'Android 音频圆盘未出现');
      await tap(disc);
      final capsule = find.byKey(const ValueKey('mini_audio_expanded_capsule'));
      await until(() => capsule.evaluate().isNotEmpty, 'Android 音频胶囊未出现');
      await capture('audio-mini');
      expect(boot.playbackEngine.activeNativeClient, same(audioClient));
      expect(player.currentTrackPositionSeconds, closeTo(position, 1));
      await tester.drag(capsule, const Offset(-1000, 0));
      final tucked = find.byKey(const ValueKey('mini_audio_tucked_tab'));
      await until(() => tucked.evaluate().isNotEmpty, 'Android 音频贴边未出现');
      await capture('audio-tucked');
      await tap(tucked);
      await tap(disc);
      await tap(
        find.descendant(
          of: capsule,
          matching: find.text(player.snapshot.currentItem!.title),
        ),
      );
      await until(
        () => find.byType(ImmersiveAudioPage).evaluate().isNotEmpty,
        'Android 音频舞台未恢复',
      );
      expect(boot.playbackEngine.activeNativeClient, same(audioClient));
      evidence['audio_mini_same_session'] = true;
      await until(
        () => player.snapshot.cover is MemoryAudioCover,
        '作品海报未生成音频回退封面',
      );
      final cover = player.snapshot.cover as MemoryAudioCover;
      final codec = await ui.instantiateImageCodec(cover.bytes);
      final frame = await codec.getNextFrame();
      evidence['notification_source_cover_width'] = frame.image.width;
      evidence['notification_source_cover_height'] = frame.image.height;
      expect(frame.image.width, frame.image.height);
      frame.image.dispose();
      codec.dispose();
      await player.seekRelativeTrackSeconds(5);
      await player.setPlaying(true);
      await until(
        () => player.snapshot.status == AudioPlaybackStatus.playing,
        '音频未恢复播放',
      );
      final audioBefore = audioClient!.getPropertyDouble('time-pos')!;
      final bg = await systemAction('audio-home');
      expect(bg['foreground'], isFalse);
      expect(bg['pinned'], isFalse);
      expect(bg['session'], isTrue);
      expect(bg['service'], isTrue);
      expect(bg['notification_record'], isTrue);
      await Future<void>.delayed(const Duration(seconds: 2));
      final audioAfter = audioClient.getPropertyDouble('time-pos')!;
      expect(audioAfter - audioBefore, greaterThan(0.5));
      // 在后台用 Android 系统媒体按键控制同一真实会话。
      if (bg['nonsecure_keyguard'] == true) {
        final sleepBefore = audioClient.getPropertyDouble('time-pos')!;
        try {
          final asleep = await systemAction('screen-off');
          expect(asleep['screen_off'], isTrue);
          expect(asleep['session'], isTrue);
          await Future<void>.delayed(const Duration(seconds: 2));
          final sleepAfter = audioClient.getPropertyDouble('time-pos')!;
          expect(sleepAfter - sleepBefore, greaterThan(0.5));
          evidence['screen_off_audio_progress_delta'] =
              sleepAfter - sleepBefore;
          evidence['screen_off_keyguard_showing'] = asleep['keyguard_showing'];
        } finally {
          final awake = await systemAction('screen-on');
          expect(awake['screen_off'], isFalse);
          expect(awake['keyguard_showing'], isFalse);
        }
      } else {
        evidence['screen_off_skipped_secure_keyguard'] = true;
      }
      final firstTrack = player.snapshot.currentIndex;
      await systemAction('media-pause');
      await until(
        () => player.snapshot.status == AudioPlaybackStatus.paused,
        '系统暂停按键未生效',
      );
      final pausedAt = audioClient.getPropertyDouble('time-pos')!;
      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(
        audioClient.getPropertyDouble('time-pos')!,
        closeTo(pausedAt, 0.25),
      );
      await systemAction('media-play');
      await until(
        () => player.snapshot.status == AudioPlaybackStatus.playing,
        '系统恢复按键未生效',
      );
      await systemAction('media-next');
      await until(
        () =>
            player.snapshot.currentIndex != firstTrack &&
            player.snapshot.status == AudioPlaybackStatus.playing,
        '系统下一曲按键未生效',
      );
      await systemAction('media-previous');
      await until(
        () =>
            player.snapshot.currentIndex == firstTrack &&
            player.snapshot.status == AudioPlaybackStatus.playing,
        '系统上一曲按键未生效',
      );
      evidence['system_media_pause_play_next_previous'] = true;
      await systemAction('restore');
      await until(
        () => player.snapshot.status == AudioPlaybackStatus.playing,
        '恢复前台后未保持播放',
      );
      expect(boot.playbackEngine.activeNativeClient, same(audioClient));
      evidence['background_audio_progress_delta'] = audioAfter - audioBefore;
      evidence['background_audio_same_session'] = true;
      evidence['background_media_session'] = bg;
      await systemAction('media-stop');
      await until(() => !player.activeListenable.value, '系统停止按键未关闭音频会话');
      evidence['system_media_stop'] = true;
      final stopped = await systemAction('stopped');
      expect(stopped['session'], isFalse);
      expect(stopped['service'], isFalse);
      evidence['media_session_cleanup'] = true;
      expect(tester.takeException(), isNull);
      binding.reportData = evidence;
      debugPrint('ANDROID_RUNTIME_EVIDENCE=${jsonEncode(evidence)}');
    } finally {
      if (audio?.activeListenable.value == true) await audio!.stopAndClose();
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
