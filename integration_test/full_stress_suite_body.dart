import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:konata/application/playback/audio_playback_notifier.dart';
import 'package:konata/application/playback/playback_dispatcher.dart';
import 'package:konata/application/playback/playback_preferences_provider.dart';
import 'package:konata/application/playback/unified_playback_coordinator.dart';
import 'package:konata/application/playback/unified_playback_engine.dart';
import 'package:konata/application/playback/video_playback_controller.dart';
import 'package:konata/application/providers/diagnostics_providers.dart';
import 'package:konata/application/providers/library_providers.dart';
import 'package:konata/application/providers/memory_coordinator.dart';
import 'package:konata/application/providers/scraping_providers.dart';
import 'package:konata/application/providers/source_actions_provider.dart';
import 'package:konata/application/providers/sync_providers.dart';
import 'package:konata/application/providers/theme_providers.dart';
import 'package:konata/application/scraping/scrape_progress.dart';
import 'package:konata/domain/logging/diagnostic_event.dart';
import 'package:konata/domain/models/episode.dart';
import 'package:konata/domain/models/media_source.dart';
import 'package:konata/domain/models/media_variant.dart';
import 'package:konata/domain/playback/cue_variant_resolver.dart';
import 'package:konata/domain/playback/video_aspect_mode.dart';
import 'package:konata/infrastructure/sources/source_gateway_factory.dart';
import 'package:konata/infrastructure/storage/storage_root_provider.dart';
import 'package:konata/presentation/app/konata_app.dart';
import 'package:konata/presentation/audio/immersive_audio_page.dart';
import 'package:konata/presentation/detail/detail_full_list_dialog.dart';
import 'package:konata/presentation/detail/supplementary_asset_cards.dart';
import 'package:konata/presentation/detail/work_detail_page.dart';
import 'package:konata/presentation/history/playback_history_cards.dart';
import 'package:konata/presentation/history/playback_history_page.dart';
import 'package:konata/presentation/library/library_page.dart';
import 'package:konata/presentation/settings/settings_page.dart';
import 'package:konata/presentation/shell/capsule_navigation.dart';
import 'package:konata/presentation/sources/sources_page.dart';
import 'package:konata/presentation/video/embedded_video_page.dart';
import 'package:konata/presentation/video/video_side_sheet.dart';
import 'package:konata/presentation/widgets/design_system/konata_surface_card.dart';

import 'process_metrics.dart';

/// 桌面端可选扩展钩子（窗口缩放与置顶迷你窗压测）。
typedef DesktopStressHook = Future<void> Function(
  WidgetTester tester,
  ProviderContainer container,
  String stage,
  Map<String, Object?> metrics,
);

/// 单阶段性能与帧耗时采集器。
class _PhaseProfiler {
  _PhaseProfiler(this.binding, this.name)
    : _cpuStart = processCpuMicroseconds(),
      _startRss = ProcessInfo.currentRss {
    _peakRss = _startRss;
    _watch.start();
    binding.addTimingsCallback(_onTimings);
    _rssTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      final rss = ProcessInfo.currentRss;
      if (rss > _peakRss) _peakRss = rss;
    });
  }

  final IntegrationTestWidgetsFlutterBinding binding;
  final String name;
  final Stopwatch _watch = Stopwatch();
  final int _cpuStart;
  final int _startRss;
  final List<FrameTiming> _frames = <FrameTiming>[];
  late int _peakRss;
  Timer? _rssTimer;

  void _onTimings(List<FrameTiming> timings) {
    _frames.addAll(timings);
  }

  Map<String, Object?> finish([Map<String, Object?> extra = const {}]) {
    _watch.stop();
    _rssTimer?.cancel();
    binding.removeTimingsCallback(_onTimings);
    final endRss = ProcessInfo.currentRss;
    if (endRss > _peakRss) _peakRss = endRss;
    final buildMs =
        _frames.map((f) => f.buildDuration.inMicroseconds / 1000.0).toList()
          ..sort();
    final rasterMs =
        _frames.map((f) => f.rasterDuration.inMicroseconds / 1000.0).toList()
          ..sort();
    final jankFrames = _frames
        .where(
          (f) =>
              f.buildDuration.inMicroseconds > 16667 ||
              f.rasterDuration.inMicroseconds > 16667,
        )
        .length;
    return <String, Object?>{
      'phase': name,
      'elapsed_ms': _watch.elapsedMilliseconds,
      'cpu_ms': ((processCpuMicroseconds() - _cpuStart) / 1000.0).round(),
      'start_rss_mb': _toMb(_startRss),
      'peak_rss_mb': _toMb(_peakRss),
      'end_rss_mb': _toMb(endRss),
      'frame_count': _frames.length,
      'build_p50_ms': _percentile(buildMs, 0.50),
      'build_p95_ms': _percentile(buildMs, 0.95),
      'raster_p50_ms': _percentile(rasterMs, 0.50),
      'raster_p95_ms': _percentile(rasterMs, 0.95),
      'jank_frames': jankFrames,
      ...extra,
    };
  }

  static double _toMb(int bytes) =>
      double.parse((bytes / (1024 * 1024)).toStringAsFixed(1));

  static double _percentile(List<double> sorted, double q) {
    if (sorted.isEmpty) return 0.0;
    final idx = ((sorted.length - 1) * q).round().clamp(0, sorted.length - 1);
    return double.parse(sorted[idx].toStringAsFixed(2));
  }
}

/// 跨端共享全页面与全功能实机压力测试主入口。
void runFullAppRealDeviceStressSuite({
  required Future<void> Function() launchApp,
  required String platformTag,
  Finder Function(String label)? desktopNavFinder,
  DesktopStressHook? desktopHook,
  bool runAndroidOrientationStress = false,
}) {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Konata 全页面与全功能实机压力测试 ($platformTag)', (tester) async {
    final caughtFlutterErrors = <String>[];
    final caughtPlatformErrors = <String>[];
    final phaseReports = <Map<String, Object?>>[];
    final anomalies = <String>[];

    final prevFlutterOnError = FlutterError.onError;
    final prevPlatformOnError = PlatformDispatcher.instance.onError;

    FlutterError.onError = (FlutterErrorDetails details) {
      final msg = details.exceptionAsString();
      caughtFlutterErrors.add(
        '${details.context ?? 'unknown'} :: $msg',
      );
      prevFlutterOnError?.call(details);
    };
    PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
      caughtPlatformErrors.add(error.toString());
      return prevPlatformOnError?.call(error, stack) ?? true;
    };

    try {
      await launchApp();
      await _pumpFrames(tester, count: 12);

      final appFinder = find.byType(KonataApp);
      expect(appFinder, findsOneWidget, reason: 'KonataApp 必须正常挂载');
      final container = ProviderScope.containerOf(
        tester.element(appFinder),
        listen: false,
      );

      final storagePath = container
          .read(storageRootProvider)
          .resolveAppRootSync()
          .path;
      debugPrint('[STRESS][$platformTag] 存储根目录: $storagePath');

      Future<void> switchMainSection(String label) async {
        final hasCapsule = find
            .byType(CapsuleNavigation)
            .evaluate()
            .isNotEmpty;
        final target = hasCapsule
            ? find
                  .descendant(
                    of: find.byType(CapsuleNavigation),
                    matching: find.byTooltip(label),
                  )
                  .hitTestable()
            : (desktopNavFinder != null
                  ? desktopNavFinder(label)
                  : find.text(label).hitTestable());
        if (target.evaluate().isNotEmpty) {
          await tester.tap(target.first);
          await _pumpFrames(tester, count: 10);
          return;
        }
        final section = switch (label) {
          '媒体库' => KonataNavSection.library,
          '媒体源' => KonataNavSection.sources,
          '播放记录' => KonataNavSection.history,
          '设置' => KonataNavSection.settings,
          _ => KonataNavSection.library,
        };
        container.read(selectedNavSectionProvider.notifier).state = section;
        await _pumpFrames(tester, count: 10);
      }

      // 阶段 1：WebDAV 媒体源连通测试、编辑器弹窗与真实扫描刮削压测。
      {
        final prof = _PhaseProfiler(binding, 'P1_webdav_source_and_scan');
        await switchMainSection('媒体源');
        expect(find.byType(SourcesPage), findsOneWidget);

        // 校验新增媒体源弹窗三类页签切换无溢出。
        final addBtn = find.text('添加媒体源').hitTestable();
        if (addBtn.evaluate().isNotEmpty) {
          await tester.tap(addBtn.first);
          await _pumpFrames(tester, count: 8);
          for (final tab in const ['WebDAV', 'SMB', '本地目录']) {
            final f = find.text(tab).hitTestable();
            if (f.evaluate().isNotEmpty) {
              await tester.tap(f.first);
              await _pumpFrames(tester, count: 5);
            }
          }
          final cancelBtn = find.text('取消').hitTestable();
          if (cancelBtn.evaluate().isNotEmpty) {
            await tester.tap(cancelBtn.first);
          } else {
            await _popModalIfOpen(tester);
          }
          await _pumpFrames(tester, count: 6);
        }

        final sources = await container.read(mediaSourcesProvider.future);
        final webdavSources = sources
            .where((s) => s.kind == MediaSourceKind.webdav)
            .toList(growable: false);
        expect(
          webdavSources,
          isNotEmpty,
          reason: '压测环境必须已配置至少一个真实 WebDAV 媒体源',
        );
        final webdav = webdavSources.first;

        final connWatch = Stopwatch()..start();
        final connErr = await container
            .read(konataActionsProvider)
            .testMediaSourceConnection(webdav);
        connWatch.stop();
        if (connErr != null) {
          anomalies.add('WebDAV 连通测试失败: $connErr');
        }

        // 阶段 1a：启动全盘 WebDAV 扫描并执行中途取消与断点检查点压测。
        var cancelTested = false;
        final existingBefore = await container.read(libraryItemsProvider.future);
        final scopedRoots = await _resolveWebDavStressScanRoots(
          webdav: webdav,
          existingItems: existingBefore,
        );
        if (scopedRoots.isNotEmpty) {
          cancelTested = true;
          final cancelFuture = container
              .read(scrapeControllerProvider.notifier)
              .scanSource(webdav);
          var cancelDone = false;
          unawaited(cancelFuture.whenComplete(() => cancelDone = true));
          final cancelPumpEnd = DateTime.now().add(const Duration(seconds: 5));
          while (!cancelDone && DateTime.now().isBefore(cancelPumpEnd)) {
            await tester.pump(const Duration(milliseconds: 250));
          }
          if (!cancelDone) {
            container.read(scrapeControllerProvider.notifier).requestCancel();
            final cancelDeadline = DateTime.now().add(
              const Duration(seconds: 25),
            );
            while (!cancelDone && DateTime.now().isBefore(cancelDeadline)) {
              await tester.pump(const Duration(milliseconds: 200));
            }
          }
          if (!cancelDone) {
            anomalies.add('WebDAV 扫描取消超过 25 秒未收敛');
          } else {
            await cancelFuture;
          }
          await _pumpFrames(tester, count: 6);
        }

        // 阶段 1b：执行真实 WebDAV 完整四段漏斗扫描 + TMDB/Bangumi 刮削 + 落库闭环压测。
        final scanWatch = Stopwatch()..start();
        final scanFuture = container
            .read(scrapeControllerProvider.notifier)
            .scanSource(
              webdav,
              scanRootsOverride: scopedRoots.isEmpty ? null : scopedRoots,
            );
        var scanDone = false;
        unawaited(scanFuture.whenComplete(() => scanDone = true));
        final deadline = DateTime.now().add(const Duration(seconds: 180));
        while (!scanDone && DateTime.now().isBefore(deadline)) {
          await tester.pump(const Duration(milliseconds: 250));
        }
        if (!scanDone) {
          container.read(scrapeControllerProvider.notifier).requestCancel();
          anomalies.add('WebDAV 定向扫描刮削超过 180 秒触发安全取消');
          await _pumpFrames(tester, count: 10);
        } else {
          await scanFuture;
        }
        scanWatch.stop();
        final scrapeState = container.read(scrapeControllerProvider);
        if (scrapeState.phase == ScrapePhase.failed) {
          anomalies.add('WebDAV 扫描刮削异常终止: ${scrapeState.errorMessage}');
        } else if (scrapeState.phase != ScrapePhase.completed) {
          anomalies.add('WebDAV 定向扫描刮削未正常完成: ${scrapeState.phase.name}');
        }

        final allWorks = await container.read(libraryItemsProvider.future);
        phaseReports.add(
          prof.finish({
            'webdav_connect_ms': connWatch.elapsedMilliseconds,
            'webdav_connect_ok': connErr == null,
            'cancel_checkpoint_tested': cancelTested,
            'scoped_roots': scopedRoots,
            'scan_elapsed_ms': scanWatch.elapsedMilliseconds,
            'scan_phase': scrapeState.phase.name,
            'scanned_dirs': scrapeState.scannedDirectories,
            'works_count': allWorks.length,
          }),
        );
      }

      final libraryItems = await container.read(libraryItemsProvider.future);
      expect(libraryItems, isNotEmpty, reason: '扫描后媒体库必须包含可用作品');

      // 阶段 2：媒体库海报墙三轮高频滚动、检索过滤与深浅主题切换压测。
      {
        final prof = _PhaseProfiler(binding, 'P2_library_scroll_search_theme');
        await switchMainSection('媒体库');
        expect(find.byType(LibraryPage), findsOneWidget);

        final gridScroll = find.descendant(
          of: find.byType(LibraryPage),
          matching: find.byType(Scrollable),
        );
        if (gridScroll.evaluate().isNotEmpty) {
          for (var sweep = 0; sweep < 3; sweep++) {
            for (var step = 0; step < 4; step++) {
              await tester.drag(gridScroll.first, const Offset(0, -680));
              await tester.pump(const Duration(milliseconds: 60));
            }
            for (var step = 0; step < 4; step++) {
              await tester.drag(gridScroll.first, const Offset(0, 680));
              await tester.pump(const Duration(milliseconds: 60));
            }
          }
          await _pumpFrames(tester, count: 8);
        }

        // 高频搜索过滤与空结果恢复。
        final sampleTitle = libraryItems.first.work.title;
        final queryToken = sampleTitle.length >= 2
            ? sampleTitle.substring(0, 2)
            : sampleTitle;
        container.read(librarySearchQueryProvider.notifier).state = queryToken;
        await _pumpFrames(tester, count: 6);
        final hitCount =
            container.read(filteredLibraryItemsProvider).value?.length ?? 0;
        container.read(librarySearchQueryProvider.notifier).state =
            '___konata_stress_nomatch___';
        await _pumpFrames(tester, count: 6);
        final missCount =
            container.read(filteredLibraryItemsProvider).value?.length ?? -1;
        container.read(librarySearchQueryProvider.notifier).state = '';
        await _pumpFrames(tester, count: 8);
        if (hitCount <= 0 || missCount != 0) {
          anomalies.add('媒体库检索结果异常: hit=$hitCount, miss=$missCount');
        }

        // 深浅主题双轮切换压测。
        for (final mode in const [
          ThemeMode.light,
          ThemeMode.dark,
          ThemeMode.light,
          ThemeMode.dark,
        ]) {
          await container.read(themeModeProvider.notifier).setThemeMode(mode);
          await _pumpFrames(tester, count: 8);
        }

        phaseReports.add(
          prof.finish({
            'library_works': libraryItems.length,
            'search_hit': hitCount,
            'search_miss': missCount,
          }),
        );
      }

      // 挑选测试样本作品：优先同时包含正片/特典/CD/Scan 的丰富作品与多季系列作品。
      WorkLibraryItem pickBestWork(
        bool Function(WorkLibraryItem) predicate,
        int Function(WorkLibraryItem) score,
      ) {
        final candidates = libraryItems.where(predicate).toList();
        if (candidates.isEmpty) return libraryItems.first;
        candidates.sort((a, b) => score(b).compareTo(score(a)));
        return candidates.first;
      }

      final richWork = pickBestWork(
        (item) => item.variants.any((v) => v.assetKind == AssetKind.video),
        (item) {
          final hasCd = item.variants.any(
            (v) => v.assetKind == AssetKind.cdAlbum,
          );
          final hasScan = item.variants.any(
            (v) => v.assetKind == AssetKind.scanGallery,
          );
          final hasSeries = item.work.seriesId != null;
          return (hasCd ? 100 : 0) +
              (hasScan ? 100 : 0) +
              (hasSeries ? 50 : 0) +
              item.variants.length.clamp(0, 40);
        },
      );
      final cdWork = pickBestWork(
        (item) => item.variants.any(
          (v) =>
              v.assetKind == AssetKind.cdAlbum &&
              !CueVariantResolver.isCueSheetFile(v.fileName),
        ),
        (item) => item.variants
            .where((v) => v.assetKind == AssetKind.cdAlbum)
            .length,
      );
      final scanWork = pickBestWork(
        (item) =>
            item.variants.any((v) => v.assetKind == AssetKind.scanGallery),
        (item) => item.variants
            .where((v) => v.assetKind == AssetKind.scanGallery)
            .length
            .clamp(0, 30),
      );

      // 阶段 3：详情页、抽屉四页签、二级筛选、完整列表、齿轮弹窗与 WebDAV Scan 灯箱压测。
      {
        final prof = _PhaseProfiler(binding, 'P3_detail_drawer_list_scan');
        final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
        unawaited(
          nav.push(
            MaterialPageRoute<void>(
              builder: (_) => WorkDetailPage(workId: richWork.work.id),
            ),
          ),
        );
        await _pumpFrames(tester, count: 16);
        expect(find.byType(WorkDetailPage), findsOneWidget);

        // 切换正片 / 特典 / CD / Scan 抽屉标签。
        for (final prefix in const ['正片', '特典', 'CD', 'Scan']) {
          final chip = find.textContaining('$prefix (').hitTestable();
          if (chip.evaluate().isNotEmpty) {
            await tester.tap(chip.first);
            await _pumpFrames(tester, count: 10);
          }
        }

        // 打开「完整列表」弹窗并测试搜索与切换。
        final fullListBtn = find.byTooltip('完整列表').hitTestable();
        if (fullListBtn.evaluate().isNotEmpty) {
          await tester.tap(fullListBtn.first);
          await _pumpFrames(tester, count: 10);
          if (find.byType(DetailFullListDialog).evaluate().isNotEmpty) {
            final searchField = find.descendant(
              of: find.byType(DetailFullListDialog),
              matching: find.byType(TextField),
            );
            if (searchField.evaluate().isNotEmpty) {
              await tester.enterText(searchField.first, '01');
              await _pumpFrames(tester, count: 6);
              await tester.enterText(searchField.first, '');
              await _pumpFrames(tester, count: 6);
            }
            final closeBtn = find.byTooltip('关闭 (Esc)').hitTestable();
            if (closeBtn.evaluate().isNotEmpty) {
              await tester.tap(closeBtn.first);
            } else {
              await _popModalIfOpen(tester);
            }
            await _pumpFrames(tester, count: 8);
          }
        }

        // 测试齿轮管理菜单打开与收起。
        final gearBtn = find.byTooltip('作品管理选项').hitTestable();
        if (gearBtn.evaluate().isNotEmpty) {
          await tester.tap(gearBtn.first);
          await _pumpFrames(tester, count: 6);
          final editItem = find.text('手动编辑信息').hitTestable();
          if (editItem.evaluate().isNotEmpty) {
            await tester.tap(editItem.first);
            await _pumpFrames(tester, count: 8);
            final cancelEdit = find.text('取消').hitTestable();
            if (cancelEdit.evaluate().isNotEmpty) {
              await tester.tap(cancelEdit.first);
            } else {
              await _popModalIfOpen(tester);
            }
            await _pumpFrames(tester, count: 6);
          } else {
            await _popModalIfOpen(tester);
            await _pumpFrames(tester, count: 4);
          }
        }

        // 退出 richWork 并进入 scanWork 实测真实 WebDAV Scan 灯箱原图流式加载与 LRU 清理。
        nav.pop();
        await _pumpFrames(tester, count: 10);

        var scanLightboxTested = false;
        if (scanWork.variants.any(
          (v) => v.assetKind == AssetKind.scanGallery,
        )) {
          unawaited(
            nav.push(
              MaterialPageRoute<void>(
                builder: (_) => WorkDetailPage(workId: scanWork.work.id),
              ),
            ),
          );
          await _pumpFrames(tester, count: 14);
          final scanTab = find.textContaining('Scan (').hitTestable();
          if (scanTab.evaluate().isNotEmpty) {
            await tester.tap(scanTab.first);
            await _pumpFrames(tester, count: 16);
          }
          final scanCard = find.byType(ScanDrawerCard).hitTestable();
          if (scanCard.evaluate().isNotEmpty) {
            await tester.tap(scanCard.first);
            await _pumpFrames(tester, count: 24);
            if (find.byType(ScanLightboxDialog).evaluate().isNotEmpty) {
              scanLightboxTested = true;
              final nextBtn = find.byTooltip('下一张 (→)').hitTestable();
              if (nextBtn.evaluate().isNotEmpty) {
                await tester.tap(nextBtn.first);
                await _pumpFrames(tester, count: 18);
              }
              final prevBtn = find.byTooltip('上一张 (←)').hitTestable();
              if (prevBtn.evaluate().isNotEmpty) {
                await tester.tap(prevBtn.first);
                await _pumpFrames(tester, count: 14);
              }
              await _popModalIfOpen(tester);
              await _pumpFrames(tester, count: 10);
            }
          }
          nav.pop();
          await _pumpFrames(tester, count: 10);
        }

        // 快速进出 3 部不同作品详情页，验证并发预热与缩略图调度取消无竞态。
        for (final w in libraryItems.take(3)) {
          unawaited(
            nav.push(
              MaterialPageRoute<void>(
                builder: (_) => WorkDetailPage(workId: w.work.id),
              ),
            ),
          );
          await _pumpFrames(tester, count: 8);
          nav.pop();
          await _pumpFrames(tester, count: 6);
        }

        phaseReports.add(
          prof.finish({
            'rich_work_title': richWork.work.title,
            'scan_lightbox_tested': scanLightboxTested,
          }),
        );
      }

      // 阶段 4：真实 WebDAV 视频流播放、高频 Seek、五标签侧栏、字幕/OpenCC、小窗与置顶迷你窗压测。
      VideoLaunchRequest? lastVideoRequest;
      {
        final prof = _PhaseProfiler(binding, 'P4_webdav_video_playback_stress');
        final bundle = await container.read(
          workDetailBundleProvider(richWork.work.id).future,
        );
        expect(bundle, isNotNull, reason: '样本作品详情包不能为空');
        final nonNullBundle = bundle!;
        final mainEp = nonNullBundle.episodes.firstWhere(
          (e) =>
              e.category == EpisodeCategory.main &&
              nonNullBundle.variantsForEpisode(e.id).isNotEmpty,
          orElse: () => nonNullBundle.episodes.firstWhere(
            (e) => nonNullBundle.variantsForEpisode(e.id).isNotEmpty,
          ),
        );
        final videoVariant = nonNullBundle.variantsForEpisode(mainEp.id).first;
        final videoReq = VideoLaunchRequest(
          work: nonNullBundle.work,
          episode: mainEp,
          variant: videoVariant,
          bundle: nonNullBundle,
          source: nonNullBundle.sourcesById[videoVariant.sourceId],
        );
        lastVideoRequest = videoReq;

        final ttffWatch = Stopwatch()..start();
        await container
            .read(activeVideoSessionProvider.notifier)
            .openVideo(videoReq);
        await _pumpFrames(tester, count: 12);
        expect(find.byType(EmbeddedVideoPage), findsOneWidget);

        var videoReady = false;
        final readyDeadline = DateTime.now().add(const Duration(seconds: 30));
        while (DateTime.now().isBefore(readyDeadline)) {
          await tester.pump(const Duration(milliseconds: 250));
          final vs = container.read(videoPlaybackProvider(videoReq));
          if (vs.durationSeconds > 0 || (vs.probeStats.videoWidth ?? 0) > 0) {
            videoReady = true;
            break;
          }
          if (vs.errorMessage != null && vs.errorMessage!.isNotEmpty) {
            anomalies.add('WebDAV 视频起播报错: ${vs.errorMessage}');
            break;
          }
        }
        ttffWatch.stop();
        if (!videoReady) {
          anomalies.add('WebDAV 视频 30 秒内未就绪');
        }

        final liveClientsDuringVideo = container
            .read(unifiedPlaybackEngineProvider)
            .liveNativeClientCount;
        if (liveClientsDuringVideo > 1) {
          anomalies.add('视频播放期原生句柄数越界: $liveClientsDuringVideo');
        }

        final vCtrl = container.read(videoPlaybackProvider(videoReq).notifier);
        if (videoReady) {
          // 连续暂停/恢复 + 5 次高频 Range Seek + 倍速/画面模式切换。
          for (var i = 0; i < 3; i++) {
            vCtrl.togglePlayPause();
            await _pumpFrames(tester, count: 6);
          }
          final dur = container.read(videoPlaybackProvider(videoReq)).durationSeconds;
          final safeMax = dur > 30 ? 30.0 : (dur * 0.5).clamp(2.0, 20.0);
          for (final pos in [safeMax * 0.4, safeMax * 0.8, 2.0, safeMax * 0.6, 5.0]) {
            vCtrl.seekAbsolute(pos);
            await _pumpFrames(tester, count: 8);
          }
          vCtrl.setPlaybackSpeed(1.5);
          await _pumpFrames(tester, count: 5);
          vCtrl.setPlaybackSpeed(1.0);
          vCtrl.setAspectMode(VideoAspectMode.cover);
          await _pumpFrames(tester, count: 4);
          vCtrl.setAspectMode(VideoAspectMode.auto);

          // 打开播放控制台侧栏，遍历全部 5 个标签并测试字幕/OpenCC/延迟/音轨。
          vCtrl.setSideSheetOpen(true);
          await _pumpFrames(tester, count: 10);
          if (find.byType(VideoSideSheet).evaluate().isNotEmpty) {
            for (final tab in const ['选集', '章节', '字幕', '音频', '画面']) {
              final f = find
                  .descendant(
                    of: find.byType(VideoSideSheet),
                    matching: find.text(tab),
                  )
                  .hitTestable();
              if (f.evaluate().isNotEmpty) {
                await tester.tap(f.first);
                await _pumpFrames(tester, count: 6);
              }
            }
          }
          vCtrl.setSubtitleDelay(0.5);
          await _pumpFrames(tester, count: 4);
          vCtrl.setSubtitleDelay(0.0);
          final vsNow = container.read(videoPlaybackProvider(videoReq));
          if (vsNow.subtitles.length >= 2) {
            vCtrl.selectSubtitle(vsNow.subtitles[1]);
            await _pumpFrames(tester, count: 8);
            vCtrl.selectSubtitle(vsNow.subtitles.first);
            await _pumpFrames(tester, count: 8);
          }
          if (vsNow.audioTracks.length >= 2) {
            vCtrl.selectAudioTrack(vsNow.audioTracks[1]);
            await _pumpFrames(tester, count: 8);
            vCtrl.selectAudioTrack(vsNow.audioTracks.first);
            await _pumpFrames(tester, count: 6);
          }
          vCtrl.setSideSheetOpen(false);
          await _pumpFrames(tester, count: 8);

          // 收起为窗内悬浮小窗并跨页保活浏览。
          await container
              .read(activeVideoSessionProvider.notifier)
              .collapseToMini();
          await _pumpFrames(tester, count: 14);
          for (final navLabel in const ['媒体库', '播放记录', '设置']) {
            await switchMainSection(navLabel);
          }

          // Windows 专属：测试桌面置顶视频迷你窗进入与无损还原。
          if (desktopHook != null) {
            await desktopHook(tester, container, 'video_mini', {});
          }
        }

        await container.read(activeVideoSessionProvider.notifier).closeVideo();
        await _pumpFrames(tester, count: 12);
        final afterCloseClients = container
            .read(unifiedPlaybackEngineProvider)
            .liveNativeClientCount;
        if (afterCloseClients != 0) {
          anomalies.add('关闭视频后原生句柄未归零: $afterCloseClients');
        }

        phaseReports.add(
          prof.finish({
            'video_ready': videoReady,
            'video_ttff_ms': ttffWatch.elapsedMilliseconds,
            'live_clients_peak': liveClientsDuringVideo,
            'live_clients_after_close': afterCloseClients,
          }),
        );
      }

      // 阶段 5：真实 WebDAV CD 音频流播放、歌词/队列切换、迷你圆盘与音视频高频互斥压测。
      {
        final prof = _PhaseProfiler(binding, 'P5_webdav_audio_and_mutex_stress');
        var audioReady = false;
        var audioTtffMs = 0;

        final cdBundle = await container.read(
          workDetailBundleProvider(cdWork.work.id).future,
        );
        final playableCds = cdBundle == null
            ? const <MediaVariant>[]
            : cdBundle.cdVariants
                  .where((v) => !CueVariantResolver.isCueSheetFile(v.fileName))
                  .toList(growable: false);

        if (cdBundle != null && playableCds.isNotEmpty) {
          final ttffWatch = Stopwatch()..start();
          await container
              .read(playbackDispatcherProvider)
              .playCdVariant(
                work: cdBundle.work,
                variant: playableCds.first,
                cdPlaylist: playableCds.take(8).toList(growable: false),
                sourcesById: cdBundle.sourcesById,
                overrideEngine: PreferredPlaybackEngine.builtinLibmpv,
                expandImmersive: true,
              );
          await _pumpFrames(tester, count: 14);

          final audioDeadline = DateTime.now().add(const Duration(seconds: 25));
          while (DateTime.now().isBefore(audioDeadline)) {
            await tester.pump(const Duration(milliseconds: 250));
            final asState = container.read(audioPlaybackProvider);
            if (asState.isActive &&
                (asState.durationSeconds > 0 || asState.positionSeconds > 0)) {
              audioReady = true;
              break;
            }
          }
          ttffWatch.stop();
          audioTtffMs = ttffWatch.elapsedMilliseconds;

          if (find.byType(ImmersiveAudioPage).evaluate().isNotEmpty) {
            final toggleBtn = find
                .byKey(const ValueKey('immersive_toggle_pane_button'))
                .hitTestable();
            for (var i = 0; i < 4; i++) {
              if (toggleBtn.evaluate().isNotEmpty) {
                await tester.tap(toggleBtn.first);
                await _pumpFrames(tester, count: 6);
              }
            }
          }

          final aCtrl = container.read(audioPlaybackProvider.notifier);
          aCtrl.cycleLoopMode();
          aCtrl.cycleLoopMode();
          aCtrl.cycleLoopMode();
          await aCtrl.togglePlayPause();
          await _pumpFrames(tester, count: 6);
          await aCtrl.togglePlayPause();
          await _pumpFrames(tester, count: 6);

          // 收起至音频悬浮圆盘并跨页浏览。
          container.read(immersiveAudioExpandedProvider.notifier).state = false;
          await _pumpFrames(tester, count: 12);
          await switchMainSection('媒体库');
          await switchMainSection('播放记录');

          // Windows 专属：测试桌面置顶音频迷你窗进入与无损还原。
          if (desktopHook != null) {
            await desktopHook(tester, container, 'audio_mini', {});
          }

          // 音视频高频互斥抢占压测（连续 2 轮）。
          for (var round = 0; round < 2; round++) {
            await container
                .read(activeVideoSessionProvider.notifier)
                .openVideo(lastVideoRequest);
            await _pumpFrames(tester, count: 12);
            final c1 = container
                .read(unifiedPlaybackEngineProvider)
                .liveNativeClientCount;
            if (c1 > 1) {
              anomalies.add('互斥切视频时句柄数越界: $c1');
            }
            await container
                .read(playbackDispatcherProvider)
                .playCdVariant(
                  work: cdBundle.work,
                  variant: playableCds.first,
                  cdPlaylist: playableCds.take(4).toList(growable: false),
                  sourcesById: cdBundle.sourcesById,
                  overrideEngine: PreferredPlaybackEngine.builtinLibmpv,
                  expandImmersive: false,
                );
            await _pumpFrames(tester, count: 12);
            final c2 = container
                .read(unifiedPlaybackEngineProvider)
                .liveNativeClientCount;
            if (c2 > 1) {
              anomalies.add('互斥切音频时句柄数越界: $c2');
            }
          }

          await container.read(audioPlaybackProvider.notifier).stopAndClose();
          await container.read(activeVideoSessionProvider.notifier).closeVideo();
          await _pumpFrames(tester, count: 12);
        }

        final afterAllClients = container
            .read(unifiedPlaybackEngineProvider)
            .liveNativeClientCount;
        if (afterAllClients != 0) {
          anomalies.add('停止全部播放后句柄未归零: $afterAllClients');
        }
        phaseReports.add(
          prof.finish({
            'cd_count_tested': playableCds.length,
            'audio_ready': audioReady,
            'audio_ttff_ms': audioTtffMs,
            'live_clients_after_stop': afterAllClients,
          }),
        );
      }

      // 阶段 6：播放记录时间轴（视频/音频切换、展开横拖、深浅主题）压测。
      {
        final prof = _PhaseProfiler(binding, 'P6_playback_history_stress');
        await switchMainSection('播放记录');
        expect(find.byType(PlaybackHistoryPage), findsOneWidget);

        for (final tab in const ['音频', '视频', '音频', '视频']) {
          final seg = find
              .descendant(
                of: find.byType(PlaybackHistoryPage),
                matching: find.text(tab),
              )
              .hitTestable();
          if (seg.evaluate().isNotEmpty) {
            await tester.tap(seg.first);
            await _pumpFrames(tester, count: 8);
          }
        }

        // 展开首个作品卡片并测试深浅双主题与横向拖动。
        final groupCards = find
            .byType(PlaybackHistoryWorkGroupCard)
            .hitTestable();
        if (groupCards.evaluate().isNotEmpty) {
          await tester.tap(groupCards.first);
          await _pumpFrames(tester, count: 8);
          await container
              .read(themeModeProvider.notifier)
              .setThemeMode(ThemeMode.light);
          await _pumpFrames(tester, count: 8);
          await container
              .read(themeModeProvider.notifier)
              .setThemeMode(ThemeMode.dark);
          await _pumpFrames(tester, count: 8);
          await tester.tap(groupCards.first);
          await _pumpFrames(tester, count: 6);
        }

        phaseReports.add(prof.finish());
      }

      // 阶段 7：全 7 项设置面板、宽屏歌词布局校验、真实 .konata 备份导出校验、诊断报告与尺寸/横竖屏压测。
      {
        final prof = _PhaseProfiler(
          binding,
          'P7_settings_backup_diag_resize_stress',
        );
        await switchMainSection('设置');
        expect(find.byType(SettingsPage), findsOneWidget);

        var playersWideLyricsFullWidthOk = true;
        for (final theme in const [ThemeMode.dark, ThemeMode.light]) {
          await container.read(themeModeProvider.notifier).setThemeMode(theme);
          await _pumpFrames(tester, count: 6);

          for (final category in SettingsCategory.values) {
            if (Platform.isAndroid &&
                category == SettingsCategory.externalTools) {
              continue;
            }
            container.read(selectedSettingsCategoryProvider.notifier).state =
                category;
            container.read(settingsDeepLinkPulseProvider.notifier).state += 1;
            await _pumpFrames(tester, count: 8);

            // 滚动当前设置面板到底再回顶，检测溢出与重绘稳定性（兼容手机推入二级路由与宽屏双栏）。
            final scrollables = find.byType(SingleChildScrollView).hitTestable();
            if (scrollables.evaluate().isNotEmpty) {
              await tester.drag(scrollables.last, const Offset(0, -450));
              await _pumpFrames(tester, count: 5);
              await tester.drag(scrollables.last, const Offset(0, 450));
              await _pumpFrames(tester, count: 5);
            }

            if (category == SettingsCategory.player &&
                theme == ThemeMode.dark &&
                MediaQuery.sizeOf(tester.element(find.byType(KonataApp)))
                        .width >=
                    1040) {
              final lyricsFinder = find.byKey(
                const ValueKey('settings_lyrics_card'),
              );
              final videoCardFinder = find.ancestor(
                of: find.text('视频渲染与看番体验'),
                matching: find.byType(KonataSurfaceCard),
              );
              final audioCardFinder = find.ancestor(
                of: find.text('无损音频与着色器链路'),
                matching: find.byType(KonataSurfaceCard),
              );
              if (lyricsFinder.evaluate().isNotEmpty &&
                  videoCardFinder.evaluate().isNotEmpty &&
                  audioCardFinder.evaluate().isNotEmpty) {
                final lRect = tester.getRect(lyricsFinder);
                final vRect = tester.getRect(videoCardFinder);
                final aRect = tester.getRect(audioCardFinder);
                if ((lRect.left - vRect.left).abs() > 2.0 ||
                    (lRect.right - aRect.right).abs() > 2.0) {
                  playersWideLyricsFullWidthOk = false;
                  anomalies.add(
                    '宽屏播放器设置页歌词卡片未通栏对齐: lyrics=$lRect, video=$vRect, audio=$aRect',
                  );
                }
              }
            }

            // 手机单栏设置推入二级页后需返回分类列表。
            if (Platform.isAndroid) {
              final backBtn = find
                  .byKey(const ValueKey('settings_detail_back'))
                  .hitTestable();
              if (backBtn.evaluate().isNotEmpty) {
                await tester.tap(backBtn.first);
                await _pumpFrames(tester, count: 10);
              }
            }
          }
        }
        await container
            .read(themeModeProvider.notifier)
            .setThemeMode(ThemeMode.dark);
        await _pumpFrames(tester, count: 6);

        // 实测真实全库 `.konata` 备份导出与预检校验（绝不含敏感密钥）。
        final backupWatch = Stopwatch()..start();
        final backupService = container.read(konataBackupServiceProvider);
        final archiveBytes = await backupService.exportKonataArchiveBytes();
        final preview = backupService.inspectKonataArchiveBytes(archiveBytes);
        backupWatch.stop();

        // 校验诊断日志分诊报告可正常导出。
        final diagStore = container.read(diagnosticsLogStoreProvider);
        final diagReport = diagStore.buildRecentIncidentReport();
        final diagCounts = diagStore.summaryCounts;

        // Windows 窗口极限尺寸缩放压测。
        if (desktopHook != null) {
          await desktopHook(tester, container, 'window_resize', {});
        }

        // Android 横竖屏切换压测。
        if (runAndroidOrientationStress) {
          for (final orientations in const [
            [DeviceOrientation.landscapeLeft],
            [DeviceOrientation.portraitUp],
            [DeviceOrientation.landscapeRight],
            [
              DeviceOrientation.portraitUp,
              DeviceOrientation.landscapeLeft,
              DeviceOrientation.landscapeRight,
            ],
          ]) {
            await SystemChrome.setPreferredOrientations(orientations);
            await _pumpFrames(tester, count: 14);
          }
        }

        phaseReports.add(
          prof.finish({
            'players_lyrics_full_width_ok': playersWideLyricsFullWidthOk,
            'backup_export_ms': backupWatch.elapsedMilliseconds,
            'backup_bytes': archiveBytes.length,
            'backup_work_overrides': preview.workOverrideCount,
            'backup_playbacks': preview.playbackCount,
            'backup_preferences': preview.preferenceCount,
            'diag_errors': diagCounts.errorCount,
            'diag_warnings': diagCounts.warningCount,
            'diag_report_chars': diagReport.length,
          }),
        );
      }

      // 阶段 8：三轮高频页面切换耐力与内存回收观测。
      {
        final prof = _PhaseProfiler(binding, 'P8_multi_round_endurance');
        final roundRssMb = <double>[];
        for (var round = 0; round < 3; round++) {
          for (final label in const ['媒体库', '媒体源', '播放记录', '设置']) {
            await switchMainSection(label);
          }
          await container
              .read(konataMemoryCoordinatorProvider)
              .trimIdleMemory(releaseIdleDevice: true, trimWorkingSet: true);
          await _pumpFrames(tester, count: 8);
          roundRssMb.add(_PhaseProfiler._toMb(ProcessInfo.currentRss));
        }
        phaseReports.add(prof.finish({'round_rss_mb': roundRssMb}));
      }

      final diagStore = container.read(diagnosticsLogStoreProvider);
      final diagEvents = diagStore
          .snapshotIncidentEvents()
          .where(
            (e) =>
                e.severity == DiagnosticSeverity.error ||
                e.severity == DiagnosticSeverity.fatal,
          )
          .map((e) => '[${e.subsystem.name}] ${e.code}: ${e.message}')
          .toList(growable: false);

      final appSize = MediaQuery.sizeOf(tester.element(find.byType(KonataApp)));
      final summary = <String, Object?>{
        'platform': platformTag,
        'screen_dp': '${appSize.width.round()}x${appSize.height.round()}',
        'caught_flutter_errors_count': caughtFlutterErrors.length,
        'caught_flutter_errors': caughtFlutterErrors.take(20).toList(),
        'caught_platform_errors_count': caughtPlatformErrors.length,
        'caught_platform_errors': caughtPlatformErrors.take(10).toList(),
        'anomalies_count': anomalies.length,
        'anomalies': anomalies,
        'diag_error_events': diagEvents.take(20).toList(),
        'phases': phaseReports,
      };
      debugPrint('KONATA_STRESS_REPORT_BEGIN');
      debugPrint(const JsonEncoder.withIndent('  ').convert(summary));
      debugPrint('KONATA_STRESS_REPORT_END');

      expect(
        caughtFlutterErrors,
        isEmpty,
        reason: '实机压测期间出现未捕获 Flutter 错误/布局溢出: ${caughtFlutterErrors.take(5)}',
      );
      expect(
        caughtPlatformErrors,
        isEmpty,
        reason: '实机压测期间出现平台异步异常: ${caughtPlatformErrors.take(5)}',
      );
      expect(
        anomalies,
        isEmpty,
        reason: '实机压测期间出现业务/性能异常: $anomalies',
      );
    } finally {
      FlutterError.onError = prevFlutterOnError;
      PlatformDispatcher.instance.onError = prevPlatformOnError;
    }
  });
}

Future<void> _pumpFrames(WidgetTester tester, {int count = 8}) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _popModalIfOpen(WidgetTester tester) async {
  final navs = find.byType(Navigator);
  if (navs.evaluate().isEmpty) return;
  final rootNav = tester.state<NavigatorState>(navs.first);
  if (rootNav.canPop()) {
    rootNav.pop();
  }
}

/// 自动为大型 WebDAV 仓库挑选可完整闭环四段扫描刮削的真实子目录（小型仓库直接全盘扫描）。
Future<List<String>> _resolveWebDavStressScanRoots({
  required MediaSource webdav,
  required List<WorkLibraryItem> existingItems,
}) async {
  // 已有入库作品时，直接从真实已刮削变体路径中挑一个兼具多资产且规模适中的二级目录，确保四段闭环可完整跑通。
  final countsByFolder = <String, int>{};
  final richScoreByFolder = <String, int>{};
  for (final item in existingItems) {
    for (final v in item.variants) {
      if (v.sourceId != webdav.id) continue;
      final segs = v.relativePath
          .replaceAll('\\', '/')
          .split('/')
          .where((s) => s.isNotEmpty)
          .toList(growable: false);
      if (segs.length < 2) continue;
      final key = segs.length >= 3 ? '${segs[0]}/${segs[1]}' : segs[0];
      countsByFolder[key] = (countsByFolder[key] ?? 0) + 1;
      if (v.assetKind == AssetKind.cdAlbum ||
          v.assetKind == AssetKind.scanGallery) {
        richScoreByFolder[key] = (richScoreByFolder[key] ?? 0) + 1;
      }
    }
  }
  if (countsByFolder.isNotEmpty) {
    final candidates = countsByFolder.entries.toList()
      ..sort((a, b) {
        final aFit = a.value >= 10 && a.value <= 160 ? 1 : 0;
        final bFit = b.value >= 10 && b.value <= 160 ? 1 : 0;
        if (aFit != bFit) return bFit.compareTo(aFit);
        final aRich = (richScoreByFolder[a.key] ?? 0) > 0 ? 1 : 0;
        final bRich = (richScoreByFolder[b.key] ?? 0) > 0 ? 1 : 0;
        if (aRich != bRich) return bRich.compareTo(aRich);
        return a.value.compareTo(b.value);
      });
    return <String>[candidates.first.key];
  }

  // 全新空库（如 Android 首次压测）：探测根目录规模，超大云盘仓库自动下钻挑 2 个真实作品目录。
  final gateway = await const MediaSourceGatewayFactory().create(webdav);
  try {
    final rootEntries = await gateway.listDirectory('');
    final dirs = rootEntries
        .where(
          (e) =>
              e.isDirectory &&
              !e.name.startsWith('.') &&
              !e.name.startsWith('@') &&
              !e.name.startsWith('{') &&
              !e.name.contains('外挂字幕') &&
              !e.name.contains('云添加'),
        )
        .toList(growable: false);
    if (dirs.length <= 4) {
      return const <String>[];
    }
    final preferredParent = dirs.firstWhere(
      (d) => d.name.contains('未添加TMDB') || d.name.contains('单作品'),
      orElse: () => dirs.first,
    );
    final subEntries = await gateway.listDirectory(
      preferredParent.relativePath,
    );
    final subDirs = subEntries
        .where((e) => e.isDirectory && !e.name.startsWith('.'))
        .take(2)
        .map((e) => e.relativePath)
        .toList(growable: false);
    return subDirs.isNotEmpty
        ? subDirs
        : <String>[preferredParent.relativePath];
  } catch (_) {
    return const <String>[];
  } finally {
    await gateway.close();
  }
}
