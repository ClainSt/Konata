import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show FrameTiming;

import 'package:feature_library/feature_library.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:konata/bootstrap/app_bootstrap.dart';
import 'package:konata/bootstrap/host_storage_adapters.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_design_system/konata_design_system.dart';
import 'package:konata_storage/konata_storage.dart';

void main() {
  const extended = bool.fromEnvironment('KONATA_EXTENDED_ARTWORK_WORKLOAD');
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('海报墙真实设备负载五轮采样', (tester) async {
    final view = binding.platformDispatcher.views.first;
    final platform = Platform.isWindows
        ? KonataPlatform.windows
        : view.physicalSize.shortestSide / view.devicePixelRatio >= 600
        ? KonataPlatform.androidTablet
        : KonataPlatform.androidPhone;
    final parent = Platform.isWindows
        ? File(Platform.resolvedExecutable).parent
        : Directory(
            await (await createAndroidStorageRoot()).resolveAppRootPath(),
          );
    await parent.create(recursive: true);
    final root = await parent.createTemp('konata-workload-');
    final bootstrap = await KonataBootstrapContext.initialize(
      platform: platform,
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
      expect(bootstrap.databases.isCacheOpen, isFalse);
      const count = extended ? 720 : 240;
      const coverCount = extended ? 240 : 24;
      const coverWidth = extended ? 384 : 160;
      const coverHeight = extended ? 576 : 240;
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
      final covers = <String>[];
      for (var i = 0; i < coverCount; i++) {
        final rgba = Uint8List(coverWidth * coverHeight * 4);
        for (var j = 0; j < rgba.length; j += 4) {
          rgba[j] = (i * 17 + (j ~/ 4) % coverWidth) % 256;
          rgba[j + 1] = (i * 29 + j ~/ (coverWidth * 4)) % 256;
          rgba[j + 2] = (i * 11) % 256;
          rgba[j + 3] = 255;
        }
        final file = File('${root.path}/cover-$i.webp');
        await file.writeAsBytes(
          CompactWebpEncoder.encodeRgba(
            rgba: rgba,
            width: coverWidth,
            height: coverHeight,
          ),
        );
        covers.add(file.path);
      }
      for (var i = 0; i < count; i++) {
        final workId = WorkId('benchmark-work-$i');
        final episodeId = EpisodeId('benchmark-episode-$i');
        db.works.upsert(
          WorkRecord(
            id: workId,
            title: '测试动画 第$i部',
            originalTitle: 'テストアニメ $i',
            year: 2023,
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

      await tester.pumpWidget(
        KonataBootstrapApp(bootstrap: bootstrap, platformLabel: platform.name),
      );
      await tester.pumpAndSettle();
      expect(find.byType(LibraryPage), findsOneWidget);
      final gridFinder = find.descendant(
        of: find.byType(LibraryPage),
        matching: find.byType(AdaptiveCardGrid),
      );
      expect(gridFinder, findsOneWidget);
      final grid = tester.widget<AdaptiveCardGrid>(gridFinder);
      expect(grid.itemCount, count);
      final position = grid.controller!.position;
      expect(position.maxScrollExtent, greaterThan(0));

      Future<void> scrollCycle() async {
        for (final fraction in [0.25, 0.6, 0.9, 0.0]) {
          final target = position.maxScrollExtent * fraction;
          await position.animateTo(
            target,
            duration: const Duration(milliseconds: extended ? 1500 : 750),
            curve: Curves.linear,
          );
          expect(position.pixels, closeTo(target, 2));
        }
      }

      // 首轮只预热真实网格和图片缓存，随后采样五轮。
      await scrollCycle();
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      final samples = <Map<String, Object>>[];
      final imageCache = PaintingBinding.instance.imageCache;
      final thumbnailCache = konataSharedThumbnailByteLru;
      final artworkCache = bootstrap.artworkCache;
      Map<String, int> cacheSnapshot() => {
        'rss_bytes': ProcessInfo.currentRss,
        'artwork_entries': artworkCache.memoryEntryCount,
        'artwork_bytes': artworkCache.currentMemoryBytes,
        'thumbnail_entries': thumbnailCache.entryCount,
        'thumbnail_bytes': thumbnailCache.totalBytes,
        'decoded_entries': imageCache.currentSize,
        'decoded_bytes': imageCache.currentSizeBytes,
        'live_images': imageCache.liveImageCount,
      };
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
        final sample = <String, Object>{
          'elapsed_us': elapsedUs,
          'cpu_us': cpuUs,
          'observed_peak_rss_bytes': peakRss,
          'frame_count': frames.length,
          'build_us': [for (final f in frames) f.buildDuration.inMicroseconds],
          'raster_us': [
            for (final f in frames) f.rasterDuration.inMicroseconds,
          ],
        };
        if (extended) {
          expect(thumbnailCache.entryCount, greaterThan(0));
          expect(
            thumbnailCache.entryCount,
            lessThanOrEqualTo(thumbnailCache.maxEntries),
          );
          expect(
            thumbnailCache.totalBytes,
            lessThanOrEqualTo(thumbnailCache.maxTotalBytes),
          );
          sample['before_trim'] = cacheSnapshot();
          if (i.isEven) {
            sample['trim_signal'] = 'hidden';
            binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
          } else {
            sample['trim_signal'] = 'memory_pressure';
            binding.handleMemoryPressure();
          }
          sample['after_trim'] = cacheSnapshot();
          expect(thumbnailCache.totalBytes, 0);
          expect(artworkCache.currentMemoryBytes, 0);
          expect(imageCache.currentSizeBytes, 0);
          if (i.isEven) {
            binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
          }
          await tester.pumpAndSettle();
        }
        samples.add(sample);
      }
      binding.reportData = {
        'work_count': count,
        'cover_count': covers.length,
        if (extended) 'cover_width': coverWidth,
        if (extended) 'cover_height': coverHeight,
        'platform': platform.name,
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
