import 'dart:async';
import 'dart:io';

import 'package:feature_detail/feature_detail.dart';
import 'package:feature_scan_viewer/feature_scan_viewer.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
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

  testWidgets('黄金源同素材详情、画册、管理菜单与原生背景抽帧', (tester) async {
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

    const workId = WorkId.trusted('w0');
    const sourceId = SourceId.trusted('s0');
    const series = SeriesGroupId.trusted('series');
    try {
      final db = bootstrap.databases.library;
      const title = '玻璃之空 · Glass Sky';
      const mediaRoot = '$fixture/media';
      const overview =
          '风从玻璃之城吹向海岸。起航之前，主角们共同修复一台记录旧日记忆的放映机。'
          '这是用于桌面 UI 对照的合成作品简介，包含中文、日本語以及 English，供检查文字换行和信息密度。';
      db.mediaSources.upsert(
        const MediaSourceRecord(
          id: sourceId,
          kind: MediaSourceKind.local,
          label: '本地动画库',
          location: mediaRoot,
        ),
      );
      db.seriesGroups.upsert(
        const SeriesGroupRecord(id: series, title: '玻璃之空系列'),
      );
      for (var i = 0; i < 2; i++) {
        db.works.upsert(
          WorkRecord(
            id: WorkId.trusted('w$i'),
            title: i == 0 ? title : '玻璃之空 第二季',
            originalTitle: 'ガラスの空',
            year: 2024 - i,
            tmdbMediaType: TmdbMediaType.tv,
            matchedSeason: i + 1,
            overview: overview,
            posterRef: LocalCustomArtworkRef(
              localPath: '$fixture/poster-$i.png',
            ),
            backdropRef: const LocalCustomArtworkRef(
              localPath: '$fixture/hero.png',
            ),
            voteAverage: 8.3 - i * 0.2,
            bangumiScore: 7.8,
            scrapeStatus: ScrapeStatus.matched,
            metadataLocked: true,
            seriesId: series,
            seriesOrder: i,
            seriesLabel: '第 ${i + 1} 季',
          ),
        );
      }
      for (final (id, name, num, extra) in [
        ('e1', '玻璃之窗', 1, false),
        ('e2', '彼岸的回声', 2, false),
        ('ex', '无字幕片头', 1, true),
      ]) {
        db.episodes.upsert(
          EpisodeRecord(
            id: EpisodeId.trusted(id),
            workId: workId,
            seasonNumber: extra ? 0 : 1,
            episodeNumber: num,
            title: name,
            overview: overview,
            category: extra ? EpisodeCategory.extra : EpisodeCategory.main,
            extraType: extra ? ExtraKind.ncop : null,
            stillPath: '$fixture/still.png',
          ),
        );
      }
      final files = <File, (int, DateTime)>{};
      for (final (id, ep, path, kind) in [
        ('v1', 'e1', '01 - Window of Glass.avi', AssetKind.video),
        ('v2', 'e2', '02 - Beyond the Shore.avi', AssetKind.video),
        ('vx', 'ex', 'NCOP.avi', AssetKind.video),
        ('cd1', null, 'CD/01 - Blue Hour.wav', AssetKind.cdAlbum),
        ('cd2', null, 'CD/02 - Evening Shore.wav', AssetKind.cdAlbum),
        ('scan', null, 'Scan/01.png', AssetKind.scanGallery),
      ]) {
        final relative = 'Glass Sky/$path';
        final file = File('$mediaRoot/$relative');
        expect(file.existsSync(), isTrue);
        files[file] = (file.lengthSync(), file.lastModifiedSync());
        db.mediaVariants.upsert(
          MediaVariantRecord(
            id: VariantId.trusted(id),
            workId: workId,
            episodeId: ep == null ? null : EpisodeId.trusted(ep),
            sourceId: sourceId,
            relativePath: relative,
            fileName: file.uri.pathSegments.last,
            fileSize: file.lengthSync(),
            assetKind: kind,
          ),
        );
      }
      bootstrap.databases.userState.playbackRecords.upsert(
        const PlaybackRecordEntity(
          id: 'history-0',
          workId: workId,
          episodeId: EpisodeId.trusted('e1'),
          variantId: VariantId.trusted('v1'),
          playedAtMs: 1000,
          updatedAtMs: 1000,
          episodeNumber: 1,
          positionSeconds: 5,
          durationSeconds: 24,
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
      final navigator = container.read(appNavigatorProvider);
      unawaited(navigator.openWorkDetail(workId, initialTabId: 'episodes'));
      final page = find.byType(WorkDetailPage);
      final primary = find.byKey(const Key('detail_primary_play_button'));
      await until(() => primary.evaluate().isNotEmpty, '详情未就绪');
      expect(
        find.descendant(of: primary, matching: find.text('继续播放')),
        findsOneWidget,
      );
      final epCard = find.byKey(const ValueKey('episode_card_e1'));
      await until(() => epCard.evaluate().isNotEmpty, '正片卡轨道未显示');
      await capture('detail-track-latest');
      var pointer = 13000;
      Future<void> tap(Finder f) async {
        await until(() => f.hitTestable().evaluate().isNotEmpty, '无法访问验收控件');
        await tester.tap(f.hitTestable().first, pointer: pointer++);
        await tester.pump(const Duration(milliseconds: 350));
      }

      await tap(find.byKey(const Key('detail_tab_extras')));
      await capture('detail-extras-latest');
      await tap(find.byKey(const Key('detail_tab_cd')));
      await capture('detail-cd-latest');
      await tap(find.byKey(const Key('detail_tab_scan_viewer')));
      final scanTile = find.byKey(const ValueKey('scan_inline_tile_scan'));
      await until(() => scanTile.evaluate().isNotEmpty, '扫图轨道未出现');
      expect(find.byType(KonataSecondaryFilterBar<String?>), findsNothing);
      await capture('detail-scan-track-latest');
      await tap(find.byKey(const Key('detail_drawer_view_all_button')));
      final full = find.byType(DetailFullListDialog);
      await until(() => full.evaluate().isNotEmpty, '完整列表未打开');
      final scanGridTile = find.byKey(const ValueKey('scan_gallery_tile_scan'));
      await until(() => scanGridTile.evaluate().isNotEmpty, '单册扫图画廊未挂载');
      expect(
        find.descendant(
          of: full,
          matching: find.byType(KonataSecondaryFilterBar<String?>),
        ),
        findsNothing,
      );
      await capture('detail-scan-gallery-latest');
      await tap(scanGridTile);
      final lightbox = find.byType(ScanLightboxDialog);
      await until(() => lightbox.evaluate().isNotEmpty, '单册灯箱未挂载');
      await until(
        () => find.textContaining('1 / 1').evaluate().isNotEmpty,
        '灯箱图片未就绪',
      );
      expect(find.textContaining('全部分卷'), findsNothing);
      await capture('detail-scan-lightbox-latest');
      Navigator.of(tester.element(lightbox)).pop();
      await until(() => lightbox.evaluate().isEmpty, '灯箱未关闭');
      Navigator.of(tester.element(full)).pop();
      await until(() => full.evaluate().isEmpty, '完整列表未关闭');
      final gear = find.byKey(const Key('detail_gear_menu_button'));
      await tap(gear);
      final menuLabels = DetailBuiltInGearAction.values
          .map((e) => e.label)
          .toList();
      for (final label in menuLabels) {
        expect(find.text(label), findsOneWidget);
      }
      for (var i = 1; i < menuLabels.length; i++) {
        expect(
          tester.getTopLeft(find.text(menuLabels[i])).dy,
          greaterThan(tester.getTopLeft(find.text(menuLabels[i - 1])).dy),
        );
      }
      await capture('detail-gear-latest');
      await tap(find.text('编辑横版背景'));
      final picker = find.byType(WorkArtworkPickerDialog);
      await until(() => picker.evaluate().isNotEmpty, '背景原画选择器未打开');
      await capture('detail-backdrop-picker-latest');
      await tap(
        find.byKey(const ValueKey('artwork_picker_extract_video_frames_btn')),
      );
      final candidates = find.byType(VideoFrameCandidateTile);
      await until(
        () => candidates.evaluate().isNotEmpty,
        '真实正片未产出候选帧',
        seconds: 65,
      );
      final tile = tester.widget<VideoFrameCandidateTile>(candidates.first);
      expect(tile.sample.imageBytes, isNotEmpty);
      final frameBytes = tile.sample.imageBytes.toList();
      await capture('detail-backdrop-frames-latest');
      await tap(candidates.first);
      await tap(find.text('应用选中图片'));
      await until(() => picker.evaluate().isEmpty, '抽帧背景未保存');
      final saved =
          db.works.findById(workId)!.backdropRef as LocalCustomArtworkRef;
      expect(saved.locked, isTrue);
      expect(saved.localPath, isNot('$fixture/hero.png'));
      final savedFile = File(saved.localPath).isAbsolute
          ? File(saved.localPath)
          : File('${root.path}/${saved.localPath}');
      expect(savedFile.existsSync(), isTrue);
      expect(await savedFile.readAsBytes(), frameBytes);
      evidence['actual_frame_bytes'] = frameBytes.length;
      evidence['frame_saved_locked'] = true;
      await capture('detail-applied-backdrop-latest');
      await tap(gear);
      await tap(find.text('移除这部作品'));
      await until(() => find.text('确认移出').evaluate().isNotEmpty, '缺少移除确认');
      await capture('detail-remove-confirm-latest');
      await tap(find.text('取消'));
      expect(db.works.findById(workId), isNotNull);
      expect(db.mediaVariants.listByWork(workId), hasLength(6));
      for (final entry in files.entries) {
        expect(entry.key.lengthSync(), entry.value.$1);
        expect(entry.key.lastModifiedSync(), entry.value.$2);
      }
      expect(page, findsOneWidget);
      expect(tester.takeException(), isNull);
      // 单册流程完成后使用独立作品，避免系列共享或历史筛选干扰多分卷验收。
      const multiId = WorkId.trusted('multiscan-work');
      db.works.upsert(
        const WorkRecord(
          id: multiId,
          title: '多分卷收藏测试',
          scrapeStatus: ScrapeStatus.matched,
        ),
      );
      const multiSource = SourceId.trusted('multiscan-source');
      final multiRoot = Directory('${root.path}/generated-scans');
      await multiRoot.create(recursive: true);
      db.mediaSources.upsert(
        MediaSourceRecord(
          id: multiSource,
          kind: MediaSourceKind.local,
          label: '多分卷合成夹具',
          location: multiRoot.path,
        ),
      );
      for (final (id, relative, posterIndex) in [
        ('multi_a1', 'Multi Scan/Scans/Vol.01/01.png', 2),
        ('multi_a2', 'Multi Scan/Scans/Vol.01/02.png', 3),
        ('multi_b1', 'Multi Scan/Scans/Vol.02/01.png', 4),
      ]) {
        final file = File('${multiRoot.path}/$relative');
        final original = File('$fixture/poster-$posterIndex.png');
        files[original] = (original.lengthSync(), original.lastModifiedSync());
        await file.parent.create(recursive: true);
        await original.copy(file.path);
        files[file] = (file.lengthSync(), file.lastModifiedSync());
        db.mediaVariants.upsert(
          MediaVariantRecord(
            id: VariantId.trusted(id),
            workId: multiId,
            sourceId: multiSource,
            relativePath: relative,
            fileName: file.uri.pathSegments.last,
            fileSize: file.lengthSync(),
            assetKind: AssetKind.scanGallery,
          ),
        );
      }
      final summary = ScanGalleryRepository.loadWorkDataset(
        bootstrap.databases,
        multiId,
      ).scanSummary;
      expect(summary.hasMultipleSubdirs, isTrue);
      expect(summary.chips, hasLength(2));
      final firstVolume = summary.chips.singleWhere((v) => v.count == 2);
      final secondVolume = summary.chips.singleWhere((v) => v.count == 1);
      await navigator.pop();
      await until(() => page.evaluate().isEmpty, '单册详情未退出');
      unawaited(navigator.openWorkDetail(multiId, initialTabId: 'scan_viewer'));
      await until(() => page.evaluate().isNotEmpty, '多册详情未出现');
      // 初始 Scan 标签已自动展开，再点击同一标签会收起轨道。
      final railBar = find.byType(KonataSecondaryFilterBar<String?>);
      await until(() => railBar.evaluate().isNotEmpty, '多分卷轨道未显示筛选');
      expect(find.text('全部 (3)'), findsOneWidget);
      await capture('multiscan-rail-all');
      await tap(find.text('${firstVolume.label} (2)'));
      await until(
        () => find
            .byKey(const ValueKey('scan_inline_tile_multi_a2'))
            .evaluate()
            .isNotEmpty,
        '第一册第二张未出现',
      );
      expect(
        find.byKey(const ValueKey('scan_inline_tile_multi_b1')),
        findsNothing,
      );
      await capture('multiscan-rail-first');
      await tap(find.byKey(const Key('detail_drawer_view_all_button')));
      await until(() => full.evaluate().isNotEmpty, '多册完整画廊未打开');
      final fullBar = find.descendant(
        of: full,
        matching: find.byType(KonataSecondaryFilterBar<String?>),
      );
      await until(() => fullBar.evaluate().isNotEmpty, '多册画廊分卷栏未出现');
      await tap(
        find.descendant(
          of: full,
          matching: find.text('${firstVolume.label} (2)'),
        ),
      );
      final firstTile = find.byKey(
        const ValueKey('scan_gallery_tile_multi_a1'),
      );
      await until(() => firstTile.evaluate().isNotEmpty, '第一册画廊未出现');
      expect(
        find.byKey(const ValueKey('scan_gallery_tile_multi_b1')),
        findsNothing,
      );
      await capture('multiscan-gallery-first');
      await tap(firstTile);
      await until(() => lightbox.evaluate().isNotEmpty, '多册灯箱未打开');
      await until(
        () => find.textContaining('1 / 2').evaluate().isNotEmpty,
        '第一册灯箱页码不正确',
      );
      await capture('multiscan-lightbox-first');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await until(
        () => find.textContaining('2 / 2').evaluate().isNotEmpty,
        '第一册翻页失败',
      );
      await capture('multiscan-lightbox-second');
      await tap(
        find.descendant(of: lightbox, matching: find.text(firstVolume.label)),
      );
      await tap(find.text('${secondVolume.label} (1)'));
      await until(
        () => find.textContaining('1 / 1').evaluate().isNotEmpty,
        '第二册灯箱分卷范围不正确',
      );
      await capture('multiscan-lightbox-volume-two');
      await tap(
        find.descendant(of: lightbox, matching: find.text(secondVolume.label)),
      );
      await tap(find.text('全部分卷 (3)'));
      await until(
        () => find.textContaining(' / 3').evaluate().isNotEmpty,
        '灯箱全部分卷未恢复',
      );
      await capture('multiscan-lightbox-all');
      Navigator.of(tester.element(lightbox)).pop();
      await until(() => lightbox.evaluate().isEmpty, '多册灯箱未关闭');
      Navigator.of(tester.element(full)).pop();
      await until(() => full.evaluate().isEmpty, '多册画廊未关闭');
      for (final entry in files.entries) {
        expect(entry.key.lengthSync(), entry.value.$1);
        expect(entry.key.lastModifiedSync(), entry.value.$2);
      }
      expect(tester.takeException(), isNull);
      evidence['multi_scan_volume_counts'] = [
        firstVolume.count,
        secondVolume.count,
      ];
      evidence['multi_scan_rail_filter'] = true;
      evidence['multi_scan_gallery_filter'] = true;
      evidence['multi_scan_lightbox_turn_and_switch'] = true;
      evidence['gear_order'] = menuLabels;
      evidence['single_scan_no_filter'] = true;
      evidence['remove_cancel_preserved'] = true;
      evidence['source_files_unchanged'] = true;
      binding.reportData = evidence;
      debugPrint('DETAIL_RUNTIME_EVIDENCE: $evidence');
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await bootstrap.dispose();
      await host.exitDesktopMiniWindow();
      await root.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 4)));
}
