import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:engine_playback/engine_playback.dart';
import 'package:feature_lyrics/feature_lyrics.dart';
import 'package:feature_player_audio/feature_player_audio.dart';
import 'package:feature_player_video/feature_player_video.dart';
import 'package:flutter/gestures.dart'
    show kSecondaryMouseButton, PointerDeviceKind;
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

import 'support/playback_audit_webdav.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('真实媒体解码、字幕音轨章节与双类小窗切换', (tester) async {
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
      if (captureScript.isEmpty) return;
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
      if (result.exitCode != 0) {
        debugPrint('截图未取得：$stage，${result.stderr}');
        return;
      }
      evidence['capture_$stage'] = result.stdout.toString().trim();
    }

    const useWebDav = bool.fromEnvironment('KONATA_PLAYBACK_WEBDAV');
    PlaybackAuditWebDav? webdav;
    const remoteSourceId = SourceId.trusted('audit-webdav');
    ActiveVideoSessionManager? cleanupManager;
    AudioPlaybackController? cleanupAudio;
    try {
      final db = bootstrap.databases.library;
      db.mediaSources.upsert(
        const MediaSourceRecord(
          id: sourceId,
          kind: MediaSourceKind.local,
          label: '独立测试源',
          location: fixture,
          createdAtMs: 1,
          updatedAtMs: 1,
        ),
      );
      if (useWebDav) {
        webdav = await PlaybackAuditWebDav.start(fixture);
        db.mediaSources.upsert(
          MediaSourceRecord(
            id: remoteSourceId,
            kind: MediaSourceKind.webdav,
            label: '隔离回环 WebDAV',
            location: webdav.rootUri.toString(),
            createdAtMs: 1,
            updatedAtMs: 1,
          ),
        );
      }
      final poster = File('$fixture/audit-poster.png');
      final posterBytes = poster.existsSync()
          ? await poster.readAsBytes()
          : null;
      db.works.upsert(
        WorkRecord(
          id: workId,
          title: '实播验收',
          posterRef: posterBytes == null
              ? null
              : ArtworkRef.localCustom(localPath: poster.path),
          tmdbMediaType: TmdbMediaType.tv,
          scrapeStatus: ScrapeStatus.matched,
          updatedAtMs: 1,
        ),
      );
      db.episodes.upsert(
        const EpisodeRecord(
          id: epId,
          workId: workId,
          seasonNumber: 1,
          episodeNumber: 1,
          category: EpisodeCategory.main,
          title: '实播',
          updatedAtMs: 1,
        ),
      );
      for (final (id, path, kind) in [
        (vidId, '01.mkv', AssetKind.video),
        (const VariantId.trusted('audit-a1'), 'CD/01.flac', AssetKind.cdAlbum),
        (const VariantId.trusted('audit-a2'), 'CD/02.flac', AssetKind.cdAlbum),
        for (var i = 3; i <= 4; i++)
          if (File('$fixture/CD/0$i.flac').existsSync())
            (VariantId.trusted('audit-a$i'), 'CD/0$i.flac', AssetKind.cdAlbum),
      ]) {
        final file = File('$fixture/$path');
        expect(file.existsSync(), isTrue);
        db.mediaVariants.upsert(
          MediaVariantRecord(
            id: id,
            workId: workId,
            episodeId: kind == AssetKind.video ? epId : null,
            sourceId: useWebDav && kind == AssetKind.cdAlbum
                ? remoteSourceId
                : sourceId,
            relativePath: path,
            fileName: file.uri.pathSegments.last,
            fileSize: file.lengthSync(),
            assetKind: kind,
            updatedAtMs: 1,
          ),
        );
      }
      bootstrap.databases.userState.playbackRecords.upsert(
        const PlaybackRecordEntity(
          id: 'audit-video-resume',
          workId: workId,
          episodeId: epId,
          variantId: vidId,
          playedAtMs: 1000,
          updatedAtMs: 1000,
          episodeNumber: 1,
          positionSeconds: 17,
          durationSeconds: 60,
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
      const pipeline = String.fromEnvironment(
        'KONATA_PLAYBACK_PIPELINE',
        defaultValue: 'texture_fallback',
      );
      final mode = VideoOutputPipelineMode.parse(pipeline);
      final preferences = container.read(videoPlaybackPreferencesStoreProvider);
      preferences.updateQualityConfig(
        (q) => q.copyWith(outputPipelineMode: mode),
      );
      expect(preferences.read().qualityConfig.outputPipelineMode, mode);
      evidence['requested_pipeline'] = mode.name;
      final navigator = container.read(appNavigatorProvider);
      final manager = container.read(activeVideoSessionManagerProvider);
      cleanupManager = manager;
      unawaited(
        navigator.openVideoPlayer(
          workId: workId,
          episodeId: epId,
          variantId: vidId,
        ),
      );
      await until(
        () =>
            manager.controller?.state.hasFirstFrame == true &&
            (manager.controller?.state.durationSeconds ?? 0) > 50 &&
            (manager.controller?.positionNotifier.value.inMilliseconds ?? 0) >
                17400,
        '真实视频未从历史17秒断点恢复并推进',
        seconds: 10,
      );
      final video = manager.controller!;
      final resumedPosition = video.positionNotifier.value.inMilliseconds;
      expect(resumedPosition, inInclusiveRange(17400, 25000));
      evidence['video_history_resume_ms'] = resumedPosition;
      evidence['video_duration'] = video.state.durationSeconds;
      evidence['video_backend'] = video.state.renderBackend;
      evidence['video_underlay'] = video.state.windowsUnderlayActive;
      expect(video.state.probeOverlayVisible, isFalse);
      await until(
        () =>
            video.state.probeStats.videoWidth == 640 &&
            video.state.probeStats.videoHeight == 360 &&
            video.state.probeStats.videoCodec.isNotEmpty &&
            video.state.probeStats.hwdecCurrent.isNotEmpty,
        '关闭详细信息时基础规格未按解码事件更新',
      );
      evidence['video_hud_hwdec'] = video.state.probeStats.hwdecCurrent;
      evidence['video_hud_pixel_format'] =
          video.state.probeStats.videoPixelFormat;
      evidence['video_hud_hw_pixel_format'] =
          video.state.probeStats.videoHwPixelFormat;
      final format = video.state.probeStats.videoHwPixelFormat.isNotEmpty
          ? video.state.probeStats.videoHwPixelFormat
          : video.state.probeStats.videoPixelFormat;
      final depth = PlaybackFormatters.formatVideoBitDepthLabel(format);
      const expectHdrInput = bool.fromEnvironment('KONATA_PLAYBACK_EXPECT_HDR');
      expect(depth, expectHdrInput ? '10bit' : '8bit');
      evidence['video_hud_bit_depth'] = depth;
      if (mode != VideoOutputPipelineMode.legacyTextureFallback) {
        expect(
          video.state.windowsUnderlayActive,
          isTrue,
          reason: '请求底层渲染后端却未启用，不得将共享纹理回退计为直通通过',
        );
        expect(
          find.byKey(const ValueKey('video_hardware_underlay')),
          findsOneWidget,
        );
        expect(video.state.renderBackend, switch (mode) {
          VideoOutputPipelineMode.gpuNextUnderlay => 'gpu_next',
          VideoOutputPipelineMode.layered10Bit => 'dcomp_10bit',
          VideoOutputPipelineMode.layeredFp16 => 'dcomp_fp16',
          VideoOutputPipelineMode.legacyTextureFallback => 'd3d11_10bit',
        }, reason: '实际后端必须与请求一致');
      }
      const expectHdr = bool.fromEnvironment('KONATA_PLAYBACK_EXPECT_HDR');
      if (expectHdr) {
        video.setProbeOverlayVisible(true);
        await until(
          () =>
              video.state.probeStats.videoCodec.isNotEmpty &&
              video.state.probeStats.colorGamma.isNotEmpty,
          '未读取真实视频色彩遥测',
        );
        final probe = video.state.probeStats;
        evidence['video_codec'] = probe.videoCodec;
        evidence['video_pixel_format'] = probe.videoPixelFormat;
        evidence['video_color_primaries'] = probe.colorPrimaries;
        evidence['video_color_gamma'] = probe.colorGamma;
        evidence['video_hdr_peak_nits'] = probe.hdrPeakNits;
        evidence['video_hwdec'] = probe.hwdecCurrent;
        debugPrint('HDR 输入遥测：$evidence');
        expect(probe.videoCodec.toLowerCase(), contains('hevc'));
        expect(probe.colorPrimaries.toLowerCase(), contains('2020'));
        expect(
          probe.colorGamma.toLowerCase(),
          anyOf(contains('pq'), contains('2084')),
        );
        video.setProbeOverlayVisible(false);
      }
      expect(video.state.errorMessage, isNull);
      await video.setPlaying(false);
      await until(
        () =>
            video.state.chapters.length == 2 &&
            video.state.audioTracks.length >= 2 &&
            video.state.subtitles.any((s) => s.isExternal) &&
            video.state.subtitles.any((s) => !s.isExternal),
        '真实章节或音轨、字幕枚举不完整',
      );
      evidence['chapters'] = video.state.chapters.map((c) => c.title).toList();
      evidence['audio_tracks'] = video.state.audioTracks
          .map((a) => a.displayLabel)
          .toList();
      evidence['subtitles'] = video.state.subtitles
          .map((s) => s.displayLabel)
          .toList();
      final originalAss = await File('$fixture/01.sc.ass').readAsBytes();
      String currentSubText() =>
          bootstrap.playbackEngine.activeNativeClient?.getPropertyString(
            'sub-text',
          ) ??
          '';
      final ext = video.state.subtitles.firstWhere((s) => s.isExternal);
      await video.selectSubtitleChoice(ext);
      await until(
        () => video.state.subtitles.any((s) => s.selected && s.isExternal),
        '外挂字幕未激活',
      );
      await video.setSubtitleOpenCcMode(SubtitleOpenCcMode.toSimplified);
      expect(video.state.subtitleOpenCcMode, SubtitleOpenCcMode.toSimplified);
      await video.setPlaying(true);
      await until(
        () => currentSubText().contains('繁体字测试'),
        '实际 libmpv 字幕未转为简体',
      );
      evidence['subtitle_simplified_text'] = currentSubText();
      await video.setSubtitleOpenCcMode(SubtitleOpenCcMode.none);
      await until(() => currentSubText().contains('繁體字測試'), '实际字幕未恢复原文');
      evidence['subtitle_original_text'] = currentSubText();
      await video.setSubtitleOpenCcMode(SubtitleOpenCcMode.toTraditional);
      await until(() => currentSubText().contains('繁體字測試'), '实际字幕未转为繁体');
      evidence['subtitle_traditional_text'] = currentSubText();
      await video.setSubtitleOpenCcMode(SubtitleOpenCcMode.toSimplified);
      await until(() => currentSubText().contains('繁体字测试'), '重复繁简切换未生效');
      expect(await File('$fixture/01.sc.ass').readAsBytes(), originalAss);
      final cloudFont = File('$fixture/audit-subset.ttf');
      if (cloudFont.existsSync()) {
        await video.setSubtitleOpenCcMode(SubtitleOpenCcMode.none);
        await until(() => currentSubText().contains('繁體字測試'), '云字体测试前未恢复原文');
        final fontBytes = await cloudFont.readAsBytes();
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        var calls = 0;
        var filenameSent = false;
        server.listen((request) async {
          calls++;
          filenameSent |= request.headers.value('X-Filename') != null;
          final content = await utf8.decoder.bind(request).join();
          request.response
            ..headers.contentType = ContentType(
              'text',
              'plain',
              charset: 'utf-8',
            )
            ..write(
              '$content\n[Fonts]\nfontname: KonataAuditSubset.ttf\n${AssUueFontDecoder.encode(fontBytes)}\n',
            );
          await request.response.close();
        });
        final coordinator = bootstrap.cloudSubsetCoordinator;
        final prefs = video.env.preferencesStore;
        final endpoint = Uri.parse(
          'http://127.0.0.1:${server.port}/api/subset',
        );
        final origin = CloudSubsetOrigin.fromUri(endpoint).key;
        try {
          prefs.updateCloudSubsetSettings(
            enabled: true,
            endpointUrl: endpoint.toString(),
          );
          prefs.authorizeCloudSubsetOrigin(origin);
          await video.applyCloudSubsetToCurrentSubtitle();
          expect(calls, 0);
          expect(
            coordinator.cloudClient.authorizationStore.isAuthorized(endpoint),
            isFalse,
          );
          coordinator.authorizeOrigin(endpoint);
          await video.applyCloudSubsetToCurrentSubtitle();
          await until(
            () =>
                video.state.subtitles.any((s) => s.isCloudSubset && s.selected),
            '云字体返回后未挂载独立子集轨',
          );
          final subset = video.state.subtitles.firstWhere(
            (s) => s.isCloudSubset && s.selected,
          );
          final original = video.state.subtitles.firstWhere(
            (s) => s.isExternal && !s.isCloudSubset,
          );
          expect(subset.mpvTrackId, isNot(original.mpvTrackId));
          expect(calls, 1);
          expect(filenameSent, isFalse);
          final native = bootstrap.playbackEngine.activeNativeClient!;
          final subsetDir = native.getPropertyString('sub-fonts-dir');
          expect(subsetDir, isNotNull);
          expect(Directory(subsetDir!).existsSync(), isTrue);
          await video.selectSubtitleChoice(original);
          await until(
            () => video.state.subtitles.any(
              (s) => s.selected && !s.isCloudSubset && s.isExternal,
            ),
            '无法从子集轨切回原轨',
          );
          expect(native.getPropertyString('sub-fonts-dir'), isNot(subsetDir));
          await video.selectSubtitleChoice(subset);
          await until(
            () =>
                video.state.subtitles.any((s) => s.isCloudSubset && s.selected),
            '无法从原轨切回子集轨',
          );
          expect(native.getPropertyString('sub-fonts-dir'), subsetDir);
          expect(await File('$fixture/01.sc.ass').readAsBytes(), originalAss);
          expect(calls, 1);
          evidence['cloud_subset_native_compare'] = true;
          evidence['cloud_subset_network_calls'] = calls;
          await video.selectSubtitleChoice(original);
          await video.setSubtitleOpenCcMode(SubtitleOpenCcMode.toSimplified);
        } finally {
          coordinator.revokeOriginAndCancel(endpoint);
          prefs.revokeCloudSubsetOrigin(origin);
          prefs.updateCloudSubsetSettings(enabled: false);
          await server.close(force: true);
        }
      }
      await video.setPlaying(false);
      final audioTrack = video.state.audioTracks.firstWhere((a) => !a.selected);
      await video.selectAudioTrack(audioTrack);
      await until(
        () => video.state.audioTracks.any(
          (a) => a.selected && a.mpvTrackId == audioTrack.mpvTrackId,
        ),
        '真实音轨切换未反馈',
      );
      await video.seekToChapter(video.state.chapters.last);
      await video.setPlaying(true);
      await until(
        () =>
            video.positionNotifier.value.inMilliseconds > 10500 &&
            video.positionNotifier.value.inMilliseconds < 12000,
        '章节跳转后播放时钟未推进',
      );
      await video.setPlaying(false);
      var paused = video.positionNotifier.value;
      evidence['video_chapter_seek_ms'] = paused.inMilliseconds;
      await capture('video-hud');
      if (captureScript.isNotEmpty) {
        video.setProbeOverlayVisible(true);
        await tester.pump(const Duration(milliseconds: 600));
        await capture('video-probe');
        video.setProbeOverlayVisible(false);
      }
      // 通过实际胶囊打开控制台，使用真实原生轨道与章节状态核验选中态。
      var pointer = 12000;
      Future<void> tapControl(Finder finder) async {
        await until(
          () => finder.hitTestable().evaluate().isNotEmpty,
          '实际播控入口不可见',
        );
        await tester.tap(finder.hitTestable(), pointer: pointer++);
        await tester.pump(const Duration(milliseconds: 350));
      }

      final sheet = find.byKey(const ValueKey('video_side_sheet'));
      Future<void> openSheet(String key) async {
        await tapControl(find.byKey(ValueKey(key)));
        await until(() => sheet.evaluate().isNotEmpty, '播放控制台未打开');
      }

      Finder withinSheet(Finder finder) =>
          find.descendant(of: sheet, matching: finder);
      Future<void> closeSheet() async {
        await tapControl(withinSheet(find.byType(KonataGlassCloseButton)));
        await until(() => sheet.evaluate().isEmpty, '播放控制台未关闭');
      }

      await openSheet('video_episodes_sheet_button');
      await tapControl(withinSheet(find.text('章节')));
      final chapter0 = find.byKey(
        ValueKey('video_chapter_${video.state.chapters.first.index}'),
      );
      final chapter1 = find.byKey(
        ValueKey('video_chapter_${video.state.chapters.last.index}'),
      );
      bool selectedChapter(Finder row) {
        final semantics = find.descendant(
          of: row,
          matching: find.byType(Semantics),
        );
        return tester
            .widgetList<Semantics>(semantics)
            .any((w) => w.properties.selected == true);
      }

      expect(selectedChapter(chapter1), isTrue);
      expect(selectedChapter(chapter0), isFalse);
      await tapControl(chapter0);
      await until(
        () =>
            video.positionNotifier.value.inMilliseconds < 1000 &&
            selectedChapter(chapter0),
        '章节单行选项未跟随实际跳转',
      );
      await tapControl(chapter1);
      await until(
        () =>
            video.positionNotifier.value.inMilliseconds >= 10000 &&
            selectedChapter(chapter1),
        '章节高亮未跟随真实播放位置',
      );
      evidence['chapter_panel_highlight'] = true;
      await capture('video-chapters-panel');
      await closeSheet();

      await openSheet('video_subtitles_sheet_button');
      expect(withinSheet(find.text('添加外挂字幕')), findsOneWidget);
      expect(withinSheet(find.text('转简体')), findsOneWidget);
      await capture('video-subtitle-panel');
      final subDelay = withinSheet(find.byTooltip('增加字幕延迟'));
      await tester.ensureVisible(subDelay);
      await tapControl(subDelay);
      await until(() => video.state.subtitleDelaySeconds > 0.09, '字幕延迟步进未生效');
      expect(
        bootstrap.playbackEngine.activeNativeClient?.getPropertyDouble(
          'sub-delay',
        ),
        closeTo(0.1, 0.01),
      );
      await tapControl(withinSheet(find.byTooltip('减少字幕延迟')));
      await until(
        () => video.state.subtitleDelaySeconds.abs() < 0.01,
        '字幕延迟无法恢复',
      );
      evidence['subtitle_delay_native'] = true;
      await closeSheet();

      await openSheet('video_audio_sheet_button');
      expect(withinSheet(find.text('系统默认音频输出 (Auto)')), findsOneWidget);
      await capture('video-audio-panel');
      final audioDelay = withinSheet(find.byTooltip('增加音频延迟'));
      await tester.ensureVisible(audioDelay);
      await tapControl(audioDelay);
      await until(() => video.state.audioDelaySeconds > 0.09, '音频延迟步进未生效');
      expect(
        bootstrap.playbackEngine.activeNativeClient?.getPropertyDouble(
          'audio-delay',
        ),
        closeTo(0.1, 0.01),
      );
      await tapControl(withinSheet(find.byTooltip('减少音频延迟')));
      await until(() => video.state.audioDelaySeconds.abs() < 0.01, '音频延迟无法恢复');
      evidence['audio_delay_native'] = true;
      await closeSheet();

      // 倍速统一由画面设置控制；状态入口仅在非 1x 时存在。
      final speedStatus = find.byKey(const ValueKey('video_speed_button'));
      expect(speedStatus, findsNothing);
      await openSheet('video_top_video_sheet_button');
      final speed15 = withinSheet(find.text('1.5x'));
      await tester.scrollUntilVisible(
        speed15,
        160,
        scrollable: find.descendant(
          of: withinSheet(find.byType(ListView)),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tapControl(speed15);
      await until(() => (video.state.speed - 1.5).abs() < 0.01, '倍速设置未更新');
      expect(
        bootstrap.playbackEngine.activeNativeClient?.getPropertyDouble('speed'),
        closeTo(1.5, 0.01),
      );
      await closeSheet();
      await openSheet('video_speed_button');
      final speed1 = withinSheet(find.text('1.0x'));
      await tester.scrollUntilVisible(
        speed1,
        160,
        scrollable: find.descendant(
          of: withinSheet(find.byType(ListView)),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tapControl(speed1);
      await until(() => (video.state.speed - 1).abs() < 0.01, '倍速恢复未更新');
      await closeSheet();
      expect(speedStatus, findsNothing);
      evidence['video_speed_unified_native'] = true;

      // 从实际 UI 菜单生成两张原画，而非仅断言模拟后端指令。
      final screenshots = await PlaybackStoragePaths.resolveWorkScreenshotDir(
        bootstrap.storageRoot,
        workId.value,
      );
      Set<String> existingScreenshots() => screenshots.existsSync()
          ? screenshots
                .listSync()
                .whereType<File>()
                .where((f) => f.path.endsWith('.png'))
                .map((f) => f.path)
                .toSet()
          : <String>{};
      final shotButton = find.byKey(
        const ValueKey('video_capsule_screenshot_button'),
      );
      final createdShots = <File>[];
      for (final label in ['纯净原画', '含字幕原画']) {
        final before = existingScreenshots();
        await tapControl(shotButton);
        expect(find.text('纯净原画'), findsOneWidget);
        expect(find.text('含字幕原画'), findsOneWidget);
        if (createdShots.isEmpty) await capture('video-screenshot-menu');
        await tapControl(find.text(label));
        await until(
          () => existingScreenshots()
              .difference(before)
              .any((p) => File(p).lengthSync() > 0),
          '原画未实际落盘：$label',
        );
        final file = File(existingScreenshots().difference(before).single);
        createdShots.add(file);
        final codec = await ui.instantiateImageCodec(await file.readAsBytes());
        final frame = (await codec.getNextFrame()).image;
        try {
          expect(frame.width, greaterThan(0));
          expect(frame.height, greaterThan(0));
          evidence['video_screenshot_${createdShots.length}_size'] = [
            frame.width,
            frame.height,
          ];
        } finally {
          frame.dispose();
          codec.dispose();
        }
      }
      expect(createdShots[0].path, isNot(createdShots[1].path));
      evidence['video_screenshot_actual_files'] = createdShots
          .map((f) => f.lengthSync())
          .toList();
      await video.seekToChapter(video.state.chapters.last);
      await video.setPlaying(true);
      await until(
        () =>
            video.positionNotifier.value.inMilliseconds > 10500 &&
            video.positionNotifier.value.inMilliseconds < 12000,
        '面板验收后未恢复章节位置',
      );
      await video.setPlaying(false);
      paused = video.positionNotifier.value;
      await video.enterMiniPlayer();
      await until(
        () => find
            .byKey(const ValueKey('video_desktop_mini_stage'))
            .evaluate()
            .isNotEmpty,
        '桌面视频小窗未渲染',
      );
      expect(win.isAlwaysOnTop, isTrue);
      expect(win.bounds.toRect().width, lessThan(500));
      expect(manager.controller, same(video));
      expect(
        video.positionNotifier.value.inMilliseconds,
        closeTo(paused.inMilliseconds, 1000),
      );
      await capture('video-desktop-mini');
      await video.exitMiniPlayerToStage();
      await until(
        () => find
            .byKey(const ValueKey('embedded_video_top_bar'))
            .evaluate()
            .isNotEmpty,
        '视频舞台未恢复',
      );
      expect(win.isAlwaysOnTop, isFalse);
      expect(win.bounds.toRect().width, greaterThan(600));
      debugPrint('真实视频已验证：$evidence');
      await until(
        () => find
            .byKey(const ValueKey('video_collapse_button'))
            .hitTestable()
            .evaluate()
            .isNotEmpty,
        '悬浮小窗入口未取得点击命中',
      );
      await tester.tap(
        find.byKey(const ValueKey('video_collapse_button')).hitTestable(),
        pointer: 10001,
      );
      await until(
        () =>
            manager.shouldShowFloatingMiniPlayer &&
            find
                .byKey(const ValueKey('video_floating_mini_player'))
                .evaluate()
                .isNotEmpty,
        '应用内视频小窗未挂载',
      );
      await capture('video-floating-mini');
      expect(manager.controller, same(video));
      await until(
        () => find
            .byKey(const ValueKey('mini_player_expand_button'))
            .hitTestable()
            .evaluate()
            .isNotEmpty,
        '悬浮小窗恢复按钮未取得点击命中',
      );
      await tester.tap(
        find.byKey(const ValueKey('mini_player_expand_button')).hitTestable(),
        pointer: 10002,
      );
      await until(
        () =>
            manager.isStageExpanded &&
            video.state.miniMode == VideoMiniMode.stage,
        '应用内小窗未恢复',
      );
      expect(manager.controller, same(video));
      expect(
        video.positionNotifier.value.inMilliseconds,
        closeTo(paused.inMilliseconds, 1000),
      );
      evidence['video_mini_position_ms'] =
          video.positionNotifier.value.inMilliseconds;
      final closeVideo = find
          .byKey(const ValueKey('video_back_button'))
          .hitTestable();
      await until(
        () => closeVideo.evaluate().length == 1,
        '恢复后的唯一可点击视频关闭按钮未就绪',
      );
      await tester.tap(closeVideo, pointer: 10003);
      await until(
        () =>
            !manager.hasActiveSession &&
            find.byType(EmbeddedVideoPage).evaluate().isEmpty,
        '视频会话与舞台未关闭',
      );
      debugPrint('视频内外小窗验证通过：$evidence');
      final audio = container.read(audioPlaybackControllerProvider);
      cleanupAudio = audio;
      unawaited(navigator.openAudioPlayer(workId: workId));
      await until(
        () =>
            audio.snapshot.status == AudioPlaybackStatus.playing &&
            audio.durationListenable.value.inSeconds >= 40 &&
            audio.currentTrackPositionSeconds > 0.4,
        '真实 FLAC 未播放',
      );
      evidence['audio_sample_rate'] = audio.snapshot.sampleRateHz;
      evidence['audio_codec'] = audio.snapshot.audioCodecName;
      final trackCount = [
        for (var i = 1; i <= 4; i++)
          if (File('$fixture/CD/0$i.flac').existsSync()) i,
      ].length;
      expect(audio.snapshot.queue, hasLength(trackCount));
      evidence['audio_queue_count'] = trackCount;
      Future<void> assertPosterCover() async {
        if (posterBytes == null) return;
        await until(
          () =>
              audio.snapshot.cover is MemoryAudioCover &&
              (audio.snapshot.coverVariantTag?.startsWith('poster-square::') ??
                  false),
          '无专属封面曲目未生成作品海报方形裁图',
        );
        final bytes = (audio.snapshot.cover as MemoryAudioCover).bytes;
        final codec = await ui.instantiateImageCodec(bytes);
        final image = (await codec.getNextFrame()).image;
        try {
          expect(image.width, image.height);
          final pixels = (await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!;
          final x = image.width ~/ 2;
          final y = (image.height * 5 / 72).round();
          expect(pixels.getUint8((y * image.width + x) * 4), 0x11);
          evidence['audio_poster_square_size'] = [image.width, image.height];
          evidence['audio_poster_head_preserved'] = true;
        } finally {
          image.dispose();
          codec.dispose();
        }
        await until(
          () => find
              .byWidgetPredicate(
                (w) =>
                    w is Image &&
                    w.image is MemoryImage &&
                    identical((w.image as MemoryImage).bytes, bytes),
              )
              .evaluate()
              .isNotEmpty,
          '当前音频封面组件未使用裁剪后共享字节',
        );
        expect(await poster.readAsBytes(), posterBytes);
      }

      await assertPosterCover();
      if (posterBytes != null) await capture('audio-poster-stage');
      final lyrics = container.read(lyricDisplayControllerProvider);
      if (File('$fixture/CD/01.lrc').existsSync()) {
        await until(
          () =>
              lyrics.state.lrcDocument?.lines.length == 4 &&
              !lyrics.state.isLookupInFlight,
          '同名本地 LRC 未装载',
        );
        expect(lyrics.state.activeSource, LyricSource.local);
        await audio.seekRelativeTrackSeconds(19);
        await until(() => lyrics.state.activeLyricIndex == 2, '歌词未按真实曲内时钟聚焦');
        evidence['audio_local_lyric_index'] = lyrics.state.activeLyricIndex;
        await audio.setPlaying(false);
        await capture('audio-local-lyrics');
        await audio.playQueueIndex(1);
        await until(
          () =>
              audio.snapshot.currentIndex == 1 &&
              !audio.snapshot.isBuffering &&
              lyrics.state.activeQuery?.title == '02' &&
              lyrics.state.lrcDocument == null &&
              !lyrics.state.isLookupInFlight,
          '无歌词曲目未清空上一曲或仍在网络查询',
        );
        await until(
          () => find.text('当前曲目暂无同步歌词').evaluate().isNotEmpty,
          '无歌词占位舞台未显示',
        );
        evidence['audio_no_lyric_fallback'] = true;
        await audio.setPlaying(false);
        await capture('audio-no-lyrics');
      } else {
        await until(
          () =>
              lyrics.state.activeQuery != null &&
              lyrics.state.lrcDocument == null &&
              !lyrics.state.isLookupInFlight,
          '无可靠曲名不应自动取得歌词',
        );
        evidence['audio_no_lyric_fallback'] = true;
      }
      await audio.setPlaying(false);
      await capture('audio-stage');
      await until(
        () => find
            .byKey(const ValueKey('audio_desktop_queue_button'))
            .evaluate()
            .isNotEmpty,
        '音频队列按钮未出现',
      );
      await tester.tap(
        find.byKey(const ValueKey('audio_desktop_queue_button')).hitTestable(),
        pointer: 10004,
      );
      await until(
        () => find
            .byKey(const ValueKey('audio_desktop_queue_stage'))
            .evaluate()
            .isNotEmpty,
        '原位音频队列未挂载',
      );
      await capture('audio-queue');
      final item = audio.snapshot.currentItem!.itemId;
      final position = audio.currentTrackPositionSeconds;
      await audio.setDesktopMiniWindow(true);
      await until(
        () => find
            .byKey(const ValueKey('audio_desktop_mini_stage'))
            .evaluate()
            .isNotEmpty,
        '桌面音频小窗未渲染',
      );
      expect(win.isAlwaysOnTop, isTrue);
      expect(win.bounds.toRect().height, closeTo(76, 10));
      expect(audio.snapshot.currentItem!.itemId, item);
      expect(audio.currentTrackPositionSeconds, closeTo(position, 1));
      expect(
        find.byKey(const ValueKey('mini_audio_expanded_capsule')),
        findsOneWidget,
      );
      await tapControl(find.byTooltip('收起'));
      final desktopDisc = find.byKey(const ValueKey('mini_audio_disc_surface'));
      await until(
        () =>
            desktopDisc.evaluate().isNotEmpty &&
            (win.bounds.toRect().width - 72).abs() < 12,
        '桌面圆盘未缩窗',
      );
      await assertPosterCover();
      await capture('audio-desktop-disc');
      await tester.tap(
        desktopDisc,
        buttons: kSecondaryMouseButton,
        kind: PointerDeviceKind.mouse,
        pointer: pointer++,
      );
      final desktopTucked = find.byKey(const ValueKey('mini_audio_tucked_tab'));
      await until(
        () =>
            desktopTucked.evaluate().isNotEmpty &&
            (win.bounds.toRect().width - 40).abs() < 12,
        '桌面收起耳片未缩窗',
      );
      await capture('audio-desktop-tucked');
      await tapControl(desktopTucked);
      await until(
        () =>
            desktopDisc.evaluate().isNotEmpty &&
            (win.bounds.toRect().width - 72).abs() < 12,
        '桌面耳片未恢复圆盘',
      );
      evidence['audio_desktop_tucked'] = true;
      await tapControl(desktopDisc);
      await until(
        () =>
            find
                .byKey(const ValueKey('mini_audio_expanded_capsule'))
                .evaluate()
                .isNotEmpty &&
            (win.bounds.toRect().width - 336).abs() < 12,
        '桌面胶囊未展开',
      );
      evidence['audio_desktop_shared_capsule_disc'] = true;
      const dockScript = String.fromEnvironment('KONATA_PLAYBACK_DOCK_SCRIPT');
      if (dockScript.isNotEmpty) {
        Future<void> dockCommand(String stage) async {
          final result = await Process.run('powershell.exe', [
            '-NoProfile',
            '-File',
            dockScript,
            '-AppPid',
            '$pid',
            '-Stage',
            stage,
          ]);
          expect(
            result.exitCode,
            0,
            reason: '${result.stdout}\n${result.stderr}',
          );
          evidence['desktop_dock_$stage'] = result.stdout.toString().trim();
        }

        for (final side in ['left', 'right']) {
          await dockCommand(side);
          await until(
            () =>
                desktopTucked.evaluate().isNotEmpty &&
                (win.bounds.toRect().width - 40).abs() < 12,
            '桌面移动结束未自动收起至$side',
          );
          await dockCommand('$side-check');
          await capture('audio-desktop-docked-$side');
          await tapControl(desktopTucked);
          await until(
            () =>
                desktopDisc.evaluate().isNotEmpty &&
                (win.bounds.toRect().width - 72).abs() < 12,
            '贴边恢复圆盘失败',
          );
          await dockCommand('$side-check');
          await tapControl(desktopDisc);
          await until(
            () =>
                find
                    .byKey(const ValueKey('mini_audio_expanded_capsule'))
                    .evaluate()
                    .isNotEmpty &&
                (win.bounds.toRect().width - 336).abs() < 12,
            '贴边展开胶囊失败',
          );
          await dockCommand('$side-check');
        }
        await dockCommand('middle');
        await tester.pump(const Duration(milliseconds: 500));
        expect(
          find.byKey(const ValueKey('mini_audio_expanded_capsule')),
          findsOneWidget,
        );
        await dockCommand('visible-check');
        evidence['audio_desktop_native_dock_messages'] = true;
      }
      await assertPosterCover();
      await capture('audio-desktop-mini');
      final audioClient = bootstrap.playbackEngine.activeNativeClient;
      await tapControl(
        find.byKey(const ValueKey('audio_desktop_mini_internal')),
      );
      final disc = find.byKey(const ValueKey('mini_audio_disc_surface'));
      await until(
        () =>
            !audio.snapshot.isDesktopMiniWindow &&
            find.byType(ImmersiveAudioPage).evaluate().isEmpty &&
            disc.evaluate().isNotEmpty,
        '桌面小窗未直接恢复应用内圆盘',
      );
      expect(win.isAlwaysOnTop, isFalse);
      expect(audio.snapshot.currentItem!.itemId, item);
      expect(bootstrap.playbackEngine.activeNativeClient, same(audioClient));
      expect(audio.currentTrackPositionSeconds, closeTo(position, 1));
      evidence['audio_desktop_to_internal'] = true;
      await assertPosterCover();
      await capture('audio-floating-disc');
      await tapControl(disc);
      final capsule = find.byKey(const ValueKey('mini_audio_expanded_capsule'));
      await until(() => capsule.evaluate().isNotEmpty, '音频展开胶囊未挂载');
      expect(
        find.descendant(
          of: capsule,
          matching: find.text(audio.snapshot.currentItem!.title),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: capsule,
          matching: find.byKey(const ValueKey('audio_playing_bars')),
        ),
        findsOneWidget,
      );
      await assertPosterCover();
      await capture('audio-floating-pill');
      await tester.drag(capsule, const Offset(-1500, 0), pointer: pointer++);
      final tucked = find.byKey(const ValueKey('mini_audio_tucked_tab'));
      await until(() => tucked.evaluate().isNotEmpty, '音频贴边态未挂载');
      expect(
        find.descendant(
          of: tucked,
          matching: find.byKey(const ValueKey('audio_playing_bars')),
        ),
        findsOneWidget,
      );
      await capture('audio-floating-tucked');
      await tapControl(tucked);
      await until(() => disc.evaluate().isNotEmpty, '贴边态无法恢复圆盘');
      await tapControl(disc);
      await until(() => capsule.evaluate().isNotEmpty, '恢复圆盘无法再次展开');
      await tapControl(
        find.descendant(
          of: capsule,
          matching: find.text(audio.snapshot.currentItem!.title),
        ),
      );
      await until(
        () => find.byType(ImmersiveAudioPage).evaluate().isNotEmpty,
        '内部小窗无法返回音频舞台',
      );
      expect(bootstrap.playbackEngine.activeNativeClient, same(audioClient));
      expect(audio.snapshot.currentItem!.itemId, item);
      expect(audio.currentTrackPositionSeconds, closeTo(position, 1));
      evidence['audio_internal_mini_shapes'] = true;
      // 通过真实解码器自然结束事件验证四个模式，而不是调用 next 代替 EOF。
      final duration = audio.currentTrackDurationSeconds;
      expect(duration, greaterThan(40));
      Future<void> approachEnd() async {
        await audio.setPlaying(false);
        await audio.seekRelativeTrackSeconds(
          audio.currentTrackDurationSeconds - 0.8,
        );
        await audio.setPlaying(true);
      }

      audio.setLoopMode(AudioLoopMode.sequence);
      await audio.playQueueIndex(trackCount - 1);
      await until(
        () =>
            !audio.snapshot.isBuffering &&
            audio.currentTrackDurationSeconds > 40,
        '队尾尚未加载',
      );
      await approachEnd();
      await until(
        () =>
            !audio.playingListenable.value &&
            audio.snapshot.status == AudioPlaybackStatus.paused,
        '顺序播放队尾没有停止',
      );
      expect(audio.snapshot.currentIndex, trackCount - 1);
      evidence['audio_sequence_eof'] = true;
      audio.setLoopMode(AudioLoopMode.loopAll);
      await audio.playQueueIndex(trackCount - 1);
      await until(
        () =>
            !audio.snapshot.isBuffering &&
            audio.currentTrackDurationSeconds > 40,
        '列表循环队尾尚未加载',
      );
      await approachEnd();
      await until(
        () =>
            audio.snapshot.currentIndex == 0 &&
            audio.currentTrackPositionSeconds < 5 &&
            audio.playingListenable.value,
        '列表循环未回到队首',
      );
      evidence['audio_loop_all_eof'] = true;
      audio.setLoopMode(AudioLoopMode.loopOne);
      await until(
        () =>
            !audio.snapshot.isBuffering &&
            audio.currentTrackDurationSeconds > 40,
        '单曲循环尚未加载',
      );
      await approachEnd();
      await until(
        () =>
            audio.snapshot.currentIndex == 0 &&
            audio.currentTrackPositionSeconds < 5 &&
            audio.playingListenable.value,
        '单曲循环未回到本曲',
      );
      await until(
        () =>
            audio.currentTrackPositionSeconds > 0.5 &&
            audio.currentTrackPositionSeconds < 5,
        '单曲循环重启后时钟未推进',
      );
      evidence['audio_loop_one_eof'] = true;
      audio.setLoopMode(AudioLoopMode.shuffle);
      final order = List<int>.of(audio.snapshot.playOrder);
      expect(order.toSet(), {for (var i = 0; i < trackCount; i++) i});
      expect(order.first, audio.snapshot.currentIndex);
      for (final nextRandom in [...order.skip(1), order.first]) {
        expect(nextRandom, isNot(audio.snapshot.currentIndex));
        await until(
          () =>
              !audio.snapshot.isBuffering &&
              audio.currentTrackDurationSeconds > 40,
          '随机曲目尚未加载',
        );
        debugPrint(
          '随机曲终：当前=${audio.snapshot.currentIndex}，目标=$nextRandom，顺序=$order',
        );
        await approachEnd();
        await until(
          () =>
              audio.snapshot.currentIndex == nextRandom &&
              audio.currentTrackPositionSeconds < 5 &&
              audio.playingListenable.value,
          '随机播放未按唯一随机顺序推进',
        );
        expect(audio.snapshot.playOrder, order);
        await until(
          () =>
              audio.currentTrackPositionSeconds > 0.3 &&
              audio.currentTrackPositionSeconds < 5,
          '随机曲目解码时钟未推进',
        );
      }
      evidence['audio_shuffle_order'] = order;
      evidence['audio_shuffle_eof'] = true;
      debugPrint('四种真实曲终模式：$evidence');
      await audio.stopAndClose();
      expect(audio.activeListenable.value, isFalse);
      if (webdav != null) {
        await until(
          () => bootstrap.streamBridge.activeSessionCount == 0,
          '停播后远程网桥会话未释放',
        );
        expect(webdav.rangeRequests, greaterThan(0));
        expect(webdav.methods.difference({'GET', 'HEAD', 'PROPFIND'}), isEmpty);
        evidence['webdav_audio_range_requests'] = webdav.rangeRequests;
        evidence['webdav_audio_read_only'] = true;
        evidence['webdav_audio_sessions_after_close'] =
            bootstrap.streamBridge.activeSessionCount;
      }
      expect(tester.takeException(), isNull);
      evidence['audio_mini_position'] = position;
      binding.reportData = evidence;
      debugPrint('PLAYBACK_RUNTIME_EVIDENCE: $evidence');
    } finally {
      if (cleanupAudio?.activeListenable.value == true) {
        await cleanupAudio!.stopAndClose();
      }
      if (cleanupManager?.hasActiveSession == true) {
        await cleanupManager!.closeActiveSession();
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await bootstrap.dispose();
      await webdav?.close();
      await host.exitDesktopMiniWindow();
      await root.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 4)));
}
