import 'dart:async';
import 'dart:io';

import 'package:engine_playback/engine_playback.dart';
import 'package:feature_player_video/feature_player_video.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_acrylic/flutter_acrylic.dart' as acrylic;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:konata/bootstrap/app_bootstrap.dart';
import 'package:konata/bootstrap/windows_platform_bridges.dart';
import 'package:konata/bootstrap/windows_window_host.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_design_system/konata_design_system.dart';
import 'package:konata_storage/konata_storage.dart';
import 'package:window_manager/window_manager.dart' as wm;

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('真实复杂 ASS 在播控显示与隐藏时避让并恢复', (tester) async {
    expect(Platform.isWindows, isTrue);
    const fixture = String.fromEnvironment('KONATA_PLAYBACK_FIXTURE');
    expect(fixture, isNotEmpty, reason: '需要独立的合成媒体测试目录');
    final parent = File(Platform.resolvedExecutable).parent;
    final root = await parent.createTemp('konata-playback-audit-');
    final bridge = WindowsD3d11VideoBridge();
    final host = WindowsPlaybackWindowAdapter();
    await acrylic.Window.initialize();
    final win =
        wm.WindowManager.instance.getCurrent() ??
        (throw StateError('原生测试窗口未就绪'));
    win.isFullScreen = false;
    if (win.isMaximized) win.unmaximize();
    win.titleBarStyle = wm.TitleBarStyle.hidden;
    win.isWindowControlButtonsVisible = false;
    win.minimumSize = wm.SizeToNative(
      KonataPlaybackTokens.desktopNormalWindowMinSize,
    ).toNative();
    win.setSize(wm.SizeToNative(const Size(1280, 800)).toNative(), false);
    win.center();
    win.show();
    final bootstrap = await KonataBootstrapContext.initialize(
      platform: KonataPlatform.windows,
      storageRoot: PortableStorageRootService(overrideRootPath: root.path),
      secureStorage: InMemorySecureStorage(),
      filePicker: const NoopFilePickerPort(),
      backupFilePort: const NoopBackupFilePort(),
      urlOpener: const NoopUrlOpenerPort(),
      hostWindow: host,
      desktopSurfaceBridge: bridge,
      desktopProfileDelegate: createWindowsMpvProfileDelegate(),
      legacyCodePageDecoder: windowsLegacyCodePageDecoder,
      useInMemoryDatabases: true,
      autoStartDetailWarmupAndBackfill: false,
      autoStartOngoingWorksSync: false,
    );
    Future<void> until(
      bool Function() condition,
      String reason, {
      int seconds = 20,
    }) async {
      final timer = Stopwatch()..start();
      while (!condition() && timer.elapsed.inSeconds < seconds) {
        await tester.pump(const Duration(milliseconds: 100));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(condition(), isTrue, reason: reason);
    }

    const workId = WorkId.trusted('audit-work');
    const epId = EpisodeId.trusted('audit-episode');
    const sourceId = SourceId.trusted('audit-source');
    const vidId = VariantId.trusted('audit-video');
    final evidence = <String, Object?>{};
    const captureScript = String.fromEnvironment(
      'KONATA_PLAYBACK_CAPTURE_SCRIPT',
    );
    Future<void> capture(String stage) async {
      expect(captureScript, isNotEmpty);
      await tester.pump(const Duration(milliseconds: 450));
      final result = await Process.run('powershell.exe', [
        '-NoProfile',
        '-File',
        captureScript,
        '-AppPid',
        '$pid',
        '-Stage',
        stage,
      ]);
      expect(result.exitCode, 0, reason: result.stderr.toString());
      if (result.exitCode != 0) {
        debugPrint('截图未取得：$stage，${result.stderr}');
        return;
      }
      evidence['capture_$stage'] = result.stdout.toString().trim();
    }

    ActiveVideoSessionManager? manager;
    try {
      final original = File('$fixture/01.mkv');
      final videoFile = await original.copy('${root.path}/01.mkv');
      final ass = await File('${root.path}/01.sc.ass').writeAsString(
        r'''[Script Info]
ScriptType: v4.00+
PlayResX: 640
PlayResY: 360
ScaledBorderAndShadow: yes
[V4+ Styles]
Format: Name,Fontname,Fontsize,PrimaryColour,SecondaryColour,OutlineColour,BackColour,Bold,Italic,Underline,StrikeOut,ScaleX,ScaleY,Spacing,Angle,BorderStyle,Outline,Shadow,Alignment,MarginL,MarginR,MarginV,Encoding
Style: Normal,Arial,28,&H0000FF00,&H00000000,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,0,0,2,10,10,10,1
Style: Fx,Arial,23,&H000000FF,&H00FFFF00,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,0,0,7,0,0,0,1
[Events]
Format: Layer,Start,End,Style,Name,MarginL,MarginR,MarginV,Effect,Text
Dialogue: 0,0:00:00.00,0:00:59.00,Normal,,0,0,0,,NORMAL DIALOGUE
Dialogue: 1,0:00:05.00,0:00:25.00,Fx,,0,0,0,,{\an7\move(30,18,140,18,0,20000)\c&H0000FF&\t(0,20000,\fscx140\fscy125)}MOVING
Dialogue: 1,0:00:00.00,0:00:59.00,Fx,,0,0,0,,{\an7\pos(20,75)\clip(20,75,134,110)\c&H00FFFF&}CLIPPED TEXT
Dialogue: 1,0:00:00.00,0:00:59.00,Fx,,0,0,0,,{\an7\pos(410,18)\p1\c&HFF0000&}m 0 0 l 65 0 65 32 0 32{\p0}
Dialogue: 1,0:00:05.00,0:00:25.00,Fx,,0,0,0,,{\an7\pos(350,75)\c&HFF00FF&\2c&HFFFF00&\k1000}KARA{\k1000}OKE
''',
      );
      final originalAss = await ass.readAsBytes();
      final db = bootstrap.databases.library;
      db.mediaSources.upsert(
        MediaSourceRecord(
          id: sourceId,
          kind: MediaSourceKind.local,
          label: '隔离字幕验收',
          location: root.path,
        ),
      );
      db.works.upsert(
        const WorkRecord(
          id: workId,
          title: '复杂字幕验收',
          tmdbMediaType: TmdbMediaType.tv,
          scrapeStatus: ScrapeStatus.matched,
        ),
      );
      db.episodes.upsert(
        const EpisodeRecord(
          id: epId,
          workId: workId,
          seasonNumber: 1,
          episodeNumber: 1,
          title: '实播',
        ),
      );
      db.mediaVariants.upsert(
        MediaVariantRecord(
          id: vidId,
          workId: workId,
          episodeId: epId,
          sourceId: sourceId,
          relativePath: '01.mkv',
          fileName: '01.mkv',
          fileSize: videoFile.lengthSync(),
          assetKind: AssetKind.video,
          externalSubtitles: const ['01.sc.ass'],
        ),
      );
      await tester.pumpWidget(
        KonataBootstrapApp(
          bootstrap: bootstrap,
          platformLabel: 'Windows',
          windowHost: WindowsWindowHost(),
        ),
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
        (q) => q.copyWith(
          outputPipelineMode: VideoOutputPipelineMode.legacyTextureFallback,
          subOverrideMode: SubtitleAssOverrideMode.preserveAss,
        ),
      );
      manager = container.read(activeVideoSessionManagerProvider);
      unawaited(
        container
            .read(appNavigatorProvider)
            .openVideoPlayer(workId: workId, episodeId: epId, variantId: vidId),
      );
      await until(
        () => manager?.controller?.state.hasFirstFrame == true,
        '视频未取得首帧',
      );
      final video = manager!.controller!;
      await video.setPlaying(false);
      await until(
        () => video.state.subtitles.any((s) => s.isExternal),
        '未发现合成 ASS',
      );
      await video.selectSubtitleChoice(
        video.state.subtitles.firstWhere((s) => s.isExternal),
      );
      await video.setSubtitleOpenCcMode(SubtitleOpenCcMode.none);
      final client = bootstrap.playbackEngine.activeNativeClient!;
      final sid = client.getPropertyString('sid');
      expect(int.tryParse(sid ?? ''), isNotNull);
      await video.seekToSeconds(10);
      await until(
        () =>
            ((client.getPropertyDouble('time-pos') ?? 0) - 10).abs() < 0.2 &&
            (client.getPropertyString('sub-text') ?? '').contains(
              'NORMAL DIALOGUE',
            ),
        '未定位复杂 ASS',
      );
      final surface = find.byKey(const ValueKey('video_touch_gesture_surface'));
      final capsule = find.byKey(
        const ValueKey('embedded_video_bottom_capsule'),
      );
      double pos() => client.getPropertyDouble('sub-pos') ?? -1;
      String mode() => client.getPropertyString('sub-ass-override') ?? '';
      Future<void> tapCanvas() async {
        await tester.tapAt(tester.getCenter(surface));
        await tester.pump(const Duration(milliseconds: 450));
      }

      Future<void> waitMode(bool visible) async {
        await until(
          () => visible
              ? mode() == 'scale' &&
                    pos() < 99 &&
                    capsule.hitTestable().evaluate().isNotEmpty
              : mode() == 'no' &&
                    (pos() - 100).abs() < .1 &&
                    capsule.hitTestable().evaluate().isEmpty,
          '实际 HUD 与原生字幕状态未同步',
        );
        expect(bootstrap.playbackEngine.activeNativeClient, same(client));
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

      const evidenceDir = String.fromEnvironment('KONATA_ASS_EVIDENCE');
      expect(evidenceDir, isNotEmpty);
      Future<void> sample(String name) async {
        await tester.pump(const Duration(milliseconds: 400));
        final dest = '$evidenceDir/$name-native.png';
        expect(client.command(['screenshot-to-file', dest, 'subtitles']), 0);
        await until(
          () => File(dest).existsSync() && File(dest).lengthSync() > 1000,
          '原生字幕截图未保存',
        );
        await capture(name);
        evidence[name] = {
          'position': pos(),
          'mode': mode(),
          'time': client.getPropertyDouble('time-pos'),
        };
        debugPrint('ASS_HUD_SAMPLE $name: ${evidence[name]}');
      }

      if (mode() == 'scale') await tapCanvas();
      await waitMode(false);
      await sample('ass-hidden-before');
      // 同一暂停帧无字幕底图，用于排除视频自身颜色与动态内容。
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
      expect(tester.takeException(), isNull);
      binding.reportData = evidence;
      debugPrint('ASS_HUD_EVIDENCE: $evidence');
    } finally {
      if (manager?.hasActiveSession == true) {
        await manager!.closeActiveSession();
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await bootstrap.dispose();
      await host.exitDesktopMiniWindow();
      await root.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
