import 'dart:async';
import 'dart:ffi' hide Size;
import 'dart:io';
import 'dart:ui' show FrameTiming;

import 'package:engine_scraping/engine_scraping.dart';
import 'package:feature_library/feature_library.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_acrylic/flutter_acrylic.dart' as acrylic;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:konata/bootstrap/app_bootstrap.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_design_system/konata_design_system.dart';
import 'package:konata_storage/konata_storage.dart';
import 'package:window_manager/window_manager.dart' as wm;

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets('新旧同负载海报墙五轮对照', (tester) async {
    expect(Platform.isWindows, isTrue);
    const fixture = String.fromEnvironment('KONATA_PARITY_COVERS');
    expect(fixture, isNotEmpty);
    final covers = [
      for (var i = 0; i < 24; i++) File('$fixture/cover-$i.png').path,
    ];
    for (final cover in covers) {
      expect(File(cover).existsSync(), isTrue);
    }
    await acrylic.Window.initialize();
    final win = wm.WindowManager.instance.getCurrent()!;
    if (win.isFullScreen) win.isFullScreen = false;
    if (win.isMaximized) win.unmaximize();
    win.titleBarStyle = wm.TitleBarStyle.hidden;
    win.isWindowControlButtonsVisible = false;
    win.setSize(wm.SizeToNative(const Size(1280, 800)).toNative(), false);
    win.center();
    win.show();
    await tester.pumpAndSettle();
    final view = binding.platformDispatcher.views.first;
    const target = Size(1280, 800);
    for (var attempt = 0; attempt < 4; attempt++) {
      final logical = view.physicalSize / view.devicePixelRatio;
      final delta = Offset(
        target.width - logical.width,
        target.height - logical.height,
      );
      if (delta.dx.abs() <= 1 && delta.dy.abs() <= 1) break;
      final outer = win.bounds.toRect().size;
      win.setSize(
        wm.SizeToNative(
          Size(outer.width + delta.dx, outer.height + delta.dy),
        ).toNative(),
        false,
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();
    }
    expect(view.physicalSize.width / view.devicePixelRatio, closeTo(1280, 1));
    expect(view.physicalSize.height / view.devicePixelRatio, closeTo(800, 1));
    const count = 240;
    const scored = bool.fromEnvironment('KONATA_PARITY_SCORED');
    var loaderCalls = 0;
    final root = await File(
      Platform.resolvedExecutable,
    ).parent.createTemp('konata-parity-');
    final bootstrap = await KonataBootstrapContext.initialize(
      platform: KonataPlatform.windows,
      storageRoot: PortableStorageRootService(overrideRootPath: root.path),
      secureStorage: InMemorySecureStorage(),
      filePicker: const NoopFilePickerPort(),
      backupFilePort: const NoopBackupFilePort(),
      urlOpener: const NoopUrlOpenerPort(),
      useInMemoryDatabases: true,
      autoStartDetailWarmupAndBackfill: false,
      autoStartOngoingWorksSync: false,
    );
    try {
      final db = bootstrap.databases.library;
      final sourceId = SourceId('benchmark-source');
      db.mediaSources.upsert(
        MediaSourceRecord(
          id: sourceId,
          kind: MediaSourceKind.local,
          label: '性能测试专用虚拟媒体源',
          location: root.path,
          createdAtMs: 1,
          updatedAtMs: 1,
        ),
      );
      for (var i = 0; i < count; i++) {
        final workId = WorkId('benchmark-work-$i');
        final episodeId = EpisodeId('benchmark-episode-$i');
        db.works.upsert(
          WorkRecord(
            id: workId,
            title: '测试动画 第$i部',
            originalTitle: 'テストアニメ $i',
            year: 2023,
            bangumiScore: scored ? 7.4 + (i % 12) / 10 : null,
            tmdbId: 900000 + i,
            tmdbMediaType: TmdbMediaType.tv,
            posterRef: ArtworkRef.localCustom(
              localPath: covers[i % covers.length],
            ),
            scrapeStatus: ScrapeStatus.matched,
            updatedAtMs: 1,
          ),
        );
        db.episodes.upsert(
          EpisodeRecord(
            id: episodeId,
            workId: workId,
            seasonNumber: 1,
            episodeNumber: 1,
            category: EpisodeCategory.main,
            title: '第1话',
            updatedAtMs: 1,
          ),
        );
        db.mediaVariants.upsert(
          MediaVariantRecord(
            id: VariantId('benchmark-variant-$i'),
            workId: workId,
            episodeId: episodeId,
            sourceId: sourceId,
            relativePath: '作品$i/01.mkv',
            fileName: '01.mkv',
            fileSize: 1024,
            updatedAtMs: 1,
          ),
        );
      }

      final navKey = GlobalKey<NavigatorState>();
      final navigator = HostAppNavigator(
        navigatorKey: navKey,
        onSwitchNavSection: (_) {},
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: bootstrap.toProviderOverrides(navigator: navigator),
          child: MaterialApp(
            navigatorKey: navKey,
            theme: KonataTheme.darkTheme(),
            home: Scaffold(
              body: LibraryPage(
                imageLoaderOverride:
                    (
                      path, {
                      targetWidth = 384,
                      imageSize = TmdbImageSize.w500,
                      ownerWorkId,
                      subfolder,
                    }) async {
                      loaderCalls++;
                      expect(covers, contains(path));
                      return File(path).readAsBytes();
                    },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      await tester.pumpAndSettle();
      final gridFinder = find.byType(AdaptiveCardGrid);
      expect(gridFinder, findsOneWidget);
      final grid = tester.widget<AdaptiveCardGrid>(gridFinder);
      expect(grid.itemCount, count);
      final position = grid.controller!.position;
      expect(position.maxScrollExtent, greaterThan(0));
      expect(loaderCalls, greaterThan(0), reason: '必须实际读取海报字节');
      Future<void> scrollCycle() async {
        for (final fraction in [0.25, 0.6, 0.9, 0.0]) {
          final target = position.maxScrollExtent * fraction;
          await position.animateTo(
            target,
            duration: const Duration(milliseconds: 750),
            curve: Curves.linear,
          );
          expect(position.pixels, closeTo(target, 2));
        }
      }

      // 首轮只预热真实网格和图片缓存，随后采样五轮。
      await scrollCycle();
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      final samples = <Map<String, Object>>[];
      for (var i = 0; i < 5; i++) {
        final frames = <FrameTiming>[];
        void record(List<FrameTiming> timings) => frames.addAll(timings);
        var peakRss = ProcessInfo.currentRss;
        final sampler = Timer.periodic(const Duration(milliseconds: 50), (_) {
          final rss = ProcessInfo.currentRss;
          if (rss > peakRss) peakRss = rss;
        });
        binding.addTimingsCallback(record);
        final cpuStart = _processCpuMicros();
        final watch = Stopwatch()..start();
        int elapsedUs;
        int cpuUs;
        try {
          await scrollCycle();
          watch.stop();
          elapsedUs = watch.elapsedMicroseconds;
          cpuUs = _processCpuMicros() - cpuStart;
          final rss = ProcessInfo.currentRss;
          if (rss > peakRss) peakRss = rss;
          // 真机帧时间批量回传，等待尾批而不计入负载耗时。
          await Future<void>.delayed(const Duration(milliseconds: 1200));
        } finally {
          sampler.cancel();
          binding.removeTimingsCallback(record);
        }
        expect(frames, isNotEmpty);
        expect(cpuUs, greaterThan(0));
        expect(peakRss, greaterThan(0));
        samples.add({
          'elapsed_us': elapsedUs,
          'cpu_us': cpuUs,
          'observed_peak_rss_bytes': peakRss,
          'frame_count': frames.length,
          'build_us': [for (final f in frames) f.buildDuration.inMicroseconds],
          'raster_us': [
            for (final f in frames) f.rasterDuration.inMicroseconds,
          ],
        });
      }
      binding.reportData = {
        'work_count': count,
        'scored': scored,
        'cover_count': covers.length,
        'platform': 'windows',
        'logical_viewport': [
          view.physicalSize.width / view.devicePixelRatio,
          view.physicalSize.height / view.devicePixelRatio,
        ],
        'physical_viewport': [
          view.physicalSize.width,
          view.physicalSize.height,
        ],
        'device_pixel_ratio': view.devicePixelRatio,
        'grid_viewport': [
          tester.getSize(gridFinder).width,
          tester.getSize(gridFinder).height,
        ],
        'max_scroll_extent': position.maxScrollExtent,
        'loader_calls': loaderCalls,
        'samples': samples,
      };
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await bootstrap.dispose();
      await root.delete(recursive: true);
    }
  });
}

/// 读取进程累计内核与用户态处理器时间，避免把等待时间当作 CPU 时间。
int _processCpuMicros() {
  if (Platform.isWindows) {
    final kernel = DynamicLibrary.open('kernel32.dll');
    final getProcess = kernel
        .lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>(
          'GetCurrentProcess',
        );
    final getTimes = kernel
        .lookupFunction<
          Int32 Function(
            Pointer<Void>,
            Pointer<Uint64>,
            Pointer<Uint64>,
            Pointer<Uint64>,
            Pointer<Uint64>,
          ),
          int Function(
            Pointer<Void>,
            Pointer<Uint64>,
            Pointer<Uint64>,
            Pointer<Uint64>,
            Pointer<Uint64>,
          )
        >('GetProcessTimes');
    final times = calloc<Uint64>(4);
    try {
      if (getTimes(getProcess(), times, times + 1, times + 2, times + 3) == 0) {
        throw StateError('读取 Windows 进程处理器时间失败');
      }
      return (times[2] + times[3]) ~/ 10;
    } finally {
      calloc.free(times);
    }
  }
  if (Platform.isAndroid && sizeOf<IntPtr>() == 8) {
    final clock = DynamicLibrary.open('libc.so')
        .lookupFunction<
          Int32 Function(Int32, Pointer<IntPtr>),
          int Function(int, Pointer<IntPtr>)
        >('clock_gettime');
    final time = calloc<IntPtr>(2);
    try {
      if (clock(2, time) != 0) {
        throw StateError('读取 Android 进程处理器时间失败');
      }
      return time[0] * 1000000 + time[1] ~/ 1000;
    } finally {
      calloc.free(time);
    }
  }
  throw UnsupportedError('当前设备不支持进程处理器时间采样');
}
