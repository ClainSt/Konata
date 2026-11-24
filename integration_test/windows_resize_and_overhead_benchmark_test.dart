import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:konata/application/providers/artwork_provider.dart';
import 'package:konata/application/providers/library_providers.dart';
import 'package:konata/composition/windows_composition_root.dart';
import 'package:konata/domain/models/episode.dart';
import 'package:konata/domain/models/media_source.dart';
import 'package:konata/domain/models/media_variant.dart';
import 'package:konata/domain/models/work.dart';
import 'package:konata/infrastructure/database/drift_library_repository.dart';
import 'package:konata/infrastructure/database/konata_database.dart';
import 'package:konata/infrastructure/players/d3d11_video_bridge.dart';
import 'package:konata/infrastructure/players/libmpv_ffi.dart';
import 'package:konata/infrastructure/players/mpv_quality_profile.dart';
import 'package:konata/infrastructure/storage/storage_root_provider.dart';
import 'package:konata/presentation/detail/work_detail_page.dart';
import 'package:konata/presentation/library/library_page.dart';
import 'package:konata/presentation/theme/konata_theme.dart';
import 'package:konata/presentation/widgets/playback/konata_playback_capsule.dart';

import 'process_metrics.dart';

/// 轻量 Win32 窗口句柄探测与真窗尺寸调节封装（用于驱动真实 WM_ENTERSIZEMOVE / WM_SIZE / WM_EXITSIZEMOVE）。
final class _Win32ResizeDriver {
  _Win32ResizeDriver() {
    final user32 = DynamicLibrary.open('user32.dll');
    _findWindowW = user32.lookupFunction<
      IntPtr Function(Pointer<Utf16>, Pointer<Utf16>),
      int Function(Pointer<Utf16>, Pointer<Utf16>)
    >('FindWindowW');
    _setWindowPos = user32.lookupFunction<
      Int32 Function(IntPtr, IntPtr, Int32, Int32, Int32, Int32, Uint32),
      int Function(int, int, int, int, int, int, int)
    >('SetWindowPos');
    _sendMessageW = user32.lookupFunction<
      IntPtr Function(IntPtr, Uint32, IntPtr, IntPtr),
      int Function(int, int, int, int)
    >('SendMessageW');
  }

  static const int _wmEnterSizeMove = 0x0231;
  static const int _wmExitSizeMove = 0x0232;
  static const int _swpNoMove = 0x0002;
  static const int _swpNoZOrder = 0x0004;
  static const int _swpNoActivate = 0x0010;

  late final int Function(Pointer<Utf16>, Pointer<Utf16>) _findWindowW;
  late final int Function(int, int, int, int, int, int, int) _setWindowPos;
  late final int Function(int, int, int, int) _sendMessageW;

  int findRunnerHwnd() {
    final cls = 'FLUTTER_RUNNER_WIN32_WINDOW'.toNativeUtf16();
    try {
      return _findWindowW(cls, nullptr);
    } finally {
      calloc.free(cls);
    }
  }

  void enterSizeMove(int hwnd) {
    if (hwnd == 0) return;
    _sendMessageW(hwnd, _wmEnterSizeMove, 0, 0);
  }

  void resizeTo(int hwnd, int width, int height) {
    if (hwnd == 0) return;
    _setWindowPos(
      hwnd,
      0,
      0,
      0,
      width,
      height,
      _swpNoMove | _swpNoZOrder | _swpNoActivate,
    );
  }

  void exitSizeMove(int hwnd) {
    if (hwnd == 0) return;
    _sendMessageW(hwnd, _wmExitSizeMove, 0, 0);
  }
}

int _medianInt(List<int> values) {
  if (values.isEmpty) return 0;
  final sorted = List<int>.of(values)..sort();
  return sorted[sorted.length ~/ 2];
}

int _percentileInt(List<int> values, int p) {
  if (values.isEmpty) return 0;
  final sorted = List<int>.of(values)..sort();
  final idx = ((sorted.length - 1) * p) ~/ 100;
  return sorted[idx];
}

/// 生成真实编码的渐变 PNG 图像（供详情页 1920x1080 背景与 ClearLogo 使用）。
Future<Uint8List> _generateGradientPng(
  int width,
  int height, {
  required bool transparentLogo,
}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final rect = Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble());
  if (transparentLogo) {
    final paint = Paint()
      ..shader = const LinearGradient(
        colors: <Color>[Color(0xFFFFFFFF), Color(0xFFE0ECFF)],
      ).createShader(rect);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(24, 24, width - 48.0, height - 48.0),
        const Radius.circular(18),
      ),
      paint,
    );
  } else {
    final paint = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: <Color>[
          Color(0xFF1A233A),
          Color(0xFF2D436B),
          Color(0xFF8A4F7D),
          Color(0xFFE5A93B),
        ],
      ).createShader(rect);
    canvas.drawRect(rect, paint);
    final accentPaint = Paint()..color = const Color(0x44FFFFFF);
    for (var i = 0; i < 16; i++) {
      canvas.drawCircle(
        Offset(width * (0.1 + i * 0.055), height * (0.2 + (i % 4) * 0.18)),
        48.0 + (i % 3) * 28.0,
        accentPaint,
      );
    }
  }
  final picture = recorder.endRecording();
  final img = await picture.toImage(width, height);
  final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  picture.dispose();
  return bytes!.buffer.asUint8List();
}

/// 生成供实时播放基准使用的本地 10-bit 渐变 Y4M 视频流。
Future<File> _generateY4mFixture(
  Directory dir, {
  int width = 640,
  int height = 360,
  int frameCount = 120,
}) async {
  final file = File(p.join(dir.path, 'bench_sdr_60fps.y4m'));
  final sink = file.openWrite();
  sink.add(ascii.encode('YUV4MPEG2 W$width H$height F60:1 Ip C420\n'));
  final frameHeader = ascii.encode('FRAME\n');
  final ySize = width * height;
  final uvSize = (width ~/ 2) * (height ~/ 2);
  final buf = Uint8List(ySize + uvSize * 2);
  for (var f = 0; f < frameCount; f++) {
    sink.add(frameHeader);
    final baseY = 40 + ((f * 5) % 180);
    buf.fillRange(0, ySize, baseY);
    buf.fillRange(ySize, ySize + uvSize, 128);
    buf.fillRange(ySize + uvSize, ySize + uvSize * 2, 128);
    sink.add(buf);
  }
  await sink.flush();
  await sink.close();
  return file;
}

/// 构造拟真中型番剧库：100 部作品，含 12 正片 + 10 特典 + 20 CD + 40 Scan（总计约 8200 条变体）。
Future<void> _seedRealisticLibrary(
  DriftLibraryRepository repo, {
  required String sourceId,
  required int workCount,
}) async {
  await repo.upsertMediaSource(
    MediaSource(
      id: sourceId,
      kind: MediaSourceKind.local,
      label: '基准本地库',
      location: Directory.systemTemp.path,
    ),
  );
  for (var w = 0; w < workCount; w++) {
    final workId = 'bench_work_$w';
    final isRichTarget = w == 0;
    final mainCount = 12;
    final extraCount = isRichTarget ? 28 : 10;
    final cdCount = isRichTarget ? 63 : 20;
    final scanCount = isRichTarget ? 187 : 40;
    await repo.upsertWork(
      Work(
        id: workId,
        title: isRichTarget ? '16bit的感動 ANOTHER LAYER' : '基准测试番剧 #$w',
        originalTitle: 'Benchmark Anime Title #$w',
        year: 2023 - (w % 10),
        overview:
            '秋里乐叶是热爱美少女和美少女游戏的插画家，她梦想成为超人气插画家并在美少女游戏制作公司奋斗着。'
            '因为社交游戏全盛时期的现代公司转变了方针，乐叶在偶然机会下穿越回 1992 年见证黄金时代。',
        posterPath: '/bench_poster_$w.png',
        backdropPath: '/bench_backdrop_$w.png',
        logoPath: '/bench_logo_$w.png',
        bangumiId: 400000 + w,
        tmdbId: 200000 + w,
        tmdbMediaType: TmdbMediaType.tv,
        bangumiScore: 7.4,
      ),
    );
    final episodes = <Episode>[];
    final variants = <MediaVariant>[];
    for (var e = 1; e <= mainCount; e++) {
      final epId = '${workId}_ep_$e';
      episodes.add(
        Episode(
          id: epId,
          workId: workId,
          seasonNumber: 1,
          episodeNumber: e,
          title: '第 $e 集',
          category: EpisodeCategory.main,
        ),
      );
      variants.add(
        MediaVariant(
          id: '${epId}_v1',
          workId: workId,
          episodeId: epId,
          sourceId: sourceId,
          relativePath: 'Anime_$w/[VCB-Studio] Ep$e [Ma10p_1080p].mkv',
          fileName: '[VCB-Studio] Ep$e [Ma10p_1080p].mkv',
          fileSize: 640 * 1024 * 1024,
          releaseGroup: 'VCB-Studio',
          assetKind: AssetKind.video,
          externalSubtitles: [
            'Anime_$w/[SweetSub&VCB-Studio] Ep$e.cht.ass',
            'Anime_$w/[SweetSub&VCB-Studio] Ep$e.chs.ass',
          ],
        ),
      );
    }
    const extraTags = ['NCOP', 'NCED', 'PV', 'CM', 'Menu'];
    for (var x = 1; x <= extraCount; x++) {
      final tag = extraTags[x % extraTags.length];
      final epId = '${workId}_sp_$x';
      episodes.add(
        Episode(
          id: epId,
          workId: workId,
          seasonNumber: 0,
          episodeNumber: x,
          title: '$tag $x',
          category: EpisodeCategory.extra,
        ),
      );
      variants.add(
        MediaVariant(
          id: '${epId}_v1',
          workId: workId,
          episodeId: epId,
          sourceId: sourceId,
          relativePath: 'Anime_$w/SPs/[VCB-Studio] $tag 0$x [1080p].mkv',
          fileName: '[VCB-Studio] $tag 0$x [1080p].mkv',
          fileSize: 96 * 1024 * 1024,
          releaseGroup: 'VCB-Studio',
          assetKind: AssetKind.video,
        ),
      );
    }
    for (var c = 1; c <= cdCount; c++) {
      final albumIdx = (c % 4) + 1;
      variants.add(
        MediaVariant(
          id: '${workId}_cd_$c',
          workId: workId,
          sourceId: sourceId,
          relativePath: 'Anime_$w/CDs/Vol.0$albumIdx OST/Track_$c.flac',
          fileName: 'Track_$c.flac',
          fileSize: 32 * 1024 * 1024,
          assetKind: AssetKind.cdAlbum,
        ),
      );
    }
    for (var s = 1; s <= scanCount; s++) {
      final volIdx = (s % 6) + 1;
      variants.add(
        MediaVariant(
          id: '${workId}_scan_$s',
          workId: workId,
          sourceId: sourceId,
          relativePath: 'Anime_$w/Scans/Vol.0$volIdx/Page_$s.png',
          fileName: 'Page_$s.png',
          fileSize: 8 * 1024 * 1024,
          assetKind: AssetKind.scanGallery,
        ),
      );
    }
    await repo.upsertEpisodesBatch(episodes);
    await repo.upsertMediaVariantsBatch(variants);
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Windows 窗口拉伸丝滑度、大片库静息开销与视频 OSD 播放全链路基准', (tester) async {
    expect(Platform.isWindows, isTrue);
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    SharedPreferences.setMockInitialValues({});

    const tag = String.fromEnvironment(
      'KONATA_PERF_TAG',
      defaultValue: 'baseline',
    );
    final tempDir = await Directory.systemTemp.createTemp('konata_win_perf_');
    final storageRoot = StorageRootService(overrideRoot: tempDir);
    final db = KonataDatabase(NativeDatabase.memory());
    final repo = DriftLibraryRepository(db);
    await _seedRealisticLibrary(repo, sourceId: 'src_bench', workCount: 100);

    final backdropPng = await _generateGradientPng(
      1920,
      1080,
      transparentLogo: false,
    );
    final posterPng = await _generateGradientPng(
      400,
      600,
      transparentLogo: false,
    );
    final logoPng = await _generateGradientPng(
      640,
      160,
      transparentLogo: true,
    );

    Future<Uint8List> fakeImageLoader(
      String url, {
      int? targetWidth,
      dynamic imageSize,
    }) async {
      if (url.contains('backdrop')) return backdropPng;
      if (url.contains('logo')) return logoPng;
      return posterPng;
    }

    final winDriver = _Win32ResizeDriver();
    final hwnd = winDriver.findRunnerHwnd();
    final frames = <ui.FrameTiming>[];
    void collectFrames(List<ui.FrameTiming> list) => frames.addAll(list);
    binding.addTimingsCallback(collectFrames);

    final container = ProviderContainer(
      overrides: <Override>[
        ...WindowsCompositionRoot.providerOverrides(storageRoot: storageRoot),
        konataDatabaseProvider.overrideWithValue(db),
        libraryRepositoryProvider.overrideWithValue(repo),
        tmdbImageLoaderProvider.overrideWithValue(
          (url, {targetWidth, imageSize}) => fakeImageLoader(
            url,
            targetWidth: targetWidth,
            imageSize: imageSize,
          ),
        ),
      ],
    );

    final resizeSamples = <Map<String, Object?>>[];
    final libraryIdleSamples = <Map<String, Object?>>[];
    final osdPlaybackSamples = <Map<String, Object?>>[];

    try {
      // ============================================================
      // 场景 1：详情页真实 Win32 窗口连续拉伸压测（预热 1 轮 + 采样 5 轮）
      // ============================================================
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: KonataTheme.darkTheme(),
            home: const WorkDetailPage(workId: 'bench_work_0'),
          ),
        ),
      );
      await tester.pumpAndSettle(const Duration(milliseconds: 200));

      const resizeSteps = <(int, int)>[
        (1280, 720),
        (1340, 760),
        (1420, 800),
        (1500, 860),
        (1580, 900),
        (1460, 840),
        (1320, 760),
        (1180, 700),
        (1060, 650),
        (1140, 680),
        (1220, 710),
        (1280, 720),
      ];

      for (var round = 0; round < 6; round++) {
        frames.clear();
        final sw = Stopwatch()..start();
        final cpuStart = processCpuMicroseconds();
        var peakRss = ProcessInfo.currentRss;

        winDriver.enterSizeMove(hwnd);
        for (final (w, h) in resizeSteps) {
          winDriver.resizeTo(hwnd, w, h);
          await tester.pump(const Duration(milliseconds: 16));
          final rss = ProcessInfo.currentRss;
          if (rss > peakRss) peakRss = rss;
        }
        winDriver.exitSizeMove(hwnd);
        await tester.pump(const Duration(milliseconds: 32));
        await tester.pump(const Duration(milliseconds: 32));

        sw.stop();
        final cpuUs = processCpuMicroseconds() - cpuStart;
        final builds = frames
            .map((f) => f.buildDuration.inMicroseconds)
            .toList(growable: false);
        final rasters = frames
            .map((f) => f.rasterDuration.inMicroseconds)
            .toList(growable: false);
        if (round > 0) {
          resizeSamples.add(<String, Object?>{
            'elapsed_us': sw.elapsedMicroseconds,
            'cpu_us': cpuUs,
            'frame_count': frames.length,
            'build_p50_us': _percentileInt(builds, 50),
            'build_p99_us': _percentileInt(builds, 99),
            'raster_p50_us': _percentileInt(rasters, 50),
            'raster_p99_us': _percentileInt(rasters, 99),
            'peak_rss_bytes': peakRss,
          });
        }
      }

      // ============================================================
      // 场景 2：100 部作品（~8,200 变体）媒体库 + 进出详情页静息驻留开销
      // ============================================================
      for (var round = 0; round < 6; round++) {
        container.invalidate(libraryItemsProvider);
        frames.clear();
        final sw = Stopwatch()..start();
        final cpuStart = processCpuMicroseconds();
        var peakRss = ProcessInfo.currentRss;

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: KonataTheme.darkTheme(),
              home: const Scaffold(body: LibraryPage()),
            ),
          ),
        );
        await tester.pumpAndSettle(const Duration(milliseconds: 120));
        final loadedItems = await container.read(libraryItemsProvider.future);
        var retainedVariants = 0;
        for (final item in loadedItems) {
          retainedVariants += item.variants.length;
        }
        final rssAfterLibrary = ProcessInfo.currentRss;
        if (rssAfterLibrary > peakRss) peakRss = rssAfterLibrary;

        // 模拟进入详情页再返回媒体库并静息 300ms。
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: KonataTheme.darkTheme(),
              home: const WorkDetailPage(workId: 'bench_work_0'),
            ),
          ),
        );
        await tester.pumpAndSettle(const Duration(milliseconds: 120));
        final rssInDetail = ProcessInfo.currentRss;
        if (rssInDetail > peakRss) peakRss = rssInDetail;

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: KonataTheme.darkTheme(),
              home: const Scaffold(body: LibraryPage()),
            ),
          ),
        );
        await tester.pumpAndSettle(const Duration(milliseconds: 300));
        final postIdleRss = ProcessInfo.currentRss;
        sw.stop();
        final cpuUs = processCpuMicroseconds() - cpuStart;
        if (round > 0) {
          libraryIdleSamples.add(<String, Object?>{
            'elapsed_us': sw.elapsedMicroseconds,
            'cpu_us': cpuUs,
            'peak_rss_bytes': peakRss,
            'post_idle_rss_bytes': postIdleRss,
            'library_item_count': loadedItems.length,
            'retained_variant_objects': retainedVariants,
          });
        }
      }

      // ============================================================
      // 场景 3：真实 libmpv + D3D11 共享纹理 + 60Hz OSD 播放胶囊压测
      // ============================================================
      final y4mFile = await _generateY4mFixture(tempDir);
      final dllCandidate = p.join(
        Directory.current.path,
        'native',
        'konata-native',
        'windows',
        'libmpv-2.dll',
      );
      final mpv = FfiLibMpvClient.create(
        preferredLibraryPath: File(dllCandidate).existsSync()
            ? dllCandidate
            : null,
      );
      final bridge = D3D11VideoBridge();
      int? sessionId;
      try {
        MpvQualityProfile.applyPreInitVideoOptions(
          mpv,
          config: const PlaybackQualityConfig(),
          mpvConfigDir: tempDir,
          isWindowsOverride: true,
        );
        expect(mpv.initialize(), equals(0));
        final handle = await bridge.createSession(
          mpvHandleAddress: mpv.handleAddress,
          width: 1280,
          height: 720,
          renderBackend: 'd3d11_10bit',
        );
        sessionId = handle.sessionId;
        mpv.setPropertyString('loop-file', 'inf');
        mpv.setPropertyFlag('pause', false);
        mpv.command(<String>['loadfile', y4mFile.path, 'replace']);

        final posNotifier = ValueNotifier<double>(0.0);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: KonataTheme.darkTheme(),
              home: Scaffold(
                backgroundColor: KonataTheme.cinemaObsidian,
                body: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (handle.textureId >= 0)
                      Texture(textureId: handle.textureId),
                    Align(
                      alignment: Alignment.bottomCenter,
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 24),
                        child: KonataPlaybackCapsule(
                          title: '16bit的感動 · 第 1 集',
                          isPlaying: true,
                          positionSeconds: posNotifier.value,
                          positionListenable: posNotifier,
                          durationSeconds: 1440.0,
                          onTogglePlayPause: () {},
                          onSeek: (_) {},
                          onPrevious: () {},
                          onNext: () {},
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 200));

        for (var round = 0; round < 6; round++) {
          frames.clear();
          final sw = Stopwatch()..start();
          final cpuStart = processCpuMicroseconds();
          var peakRss = ProcessInfo.currentRss;
          for (var step = 0; step < 30; step++) {
            posNotifier.value = round * 10.0 + step * 0.05;
            await tester.pump(const Duration(milliseconds: 16));
            final rss = ProcessInfo.currentRss;
            if (rss > peakRss) peakRss = rss;
          }
          sw.stop();
          final cpuUs = processCpuMicroseconds() - cpuStart;
          final builds = frames
              .map((f) => f.buildDuration.inMicroseconds)
              .toList(growable: false);
          final rasters = frames
              .map((f) => f.rasterDuration.inMicroseconds)
              .toList(growable: false);
          if (round > 0) {
            osdPlaybackSamples.add(<String, Object?>{
              'elapsed_us': sw.elapsedMicroseconds,
              'cpu_us': cpuUs,
              'frame_count': frames.length,
              'build_p50_us': _percentileInt(builds, 50),
              'build_p99_us': _percentileInt(builds, 99),
              'raster_p50_us': _percentileInt(rasters, 50),
              'raster_p99_us': _percentileInt(rasters, 99),
              'peak_rss_bytes': peakRss,
              'surface_format': handle.surfaceFormat,
              'color_bit_depth': handle.colorBitDepth,
            });
          }
        }
        posNotifier.dispose();
      } finally {
        if (sessionId != null) {
          await bridge.disposeSession(sessionId);
        }
        await mpv.dispose();
      }

      Map<String, Object?> summarize(List<Map<String, Object?>> list) {
        int medOf(String key) =>
            _medianInt(list.map((m) => (m[key] as int?) ?? 0).toList());
        return <String, Object?>{
          'rounds': list.length,
          'elapsed_us_median': medOf('elapsed_us'),
          'cpu_us_median': medOf('cpu_us'),
          'peak_rss_bytes_median': medOf('peak_rss_bytes'),
          if (list.first.containsKey('post_idle_rss_bytes'))
            'post_idle_rss_bytes_median': medOf('post_idle_rss_bytes'),
          if (list.first.containsKey('retained_variant_objects'))
            'retained_variant_objects': list.first['retained_variant_objects'],
          if (list.first.containsKey('build_p50_us')) ...<String, Object?>{
            'build_p50_us_median': medOf('build_p50_us'),
            'build_p99_us_median': medOf('build_p99_us'),
            'raster_p50_us_median': medOf('raster_p50_us'),
            'raster_p99_us_median': medOf('raster_p99_us'),
          },
          if (list.first.containsKey('surface_format')) ...<String, Object?>{
            'surface_format': list.first['surface_format'],
            'color_bit_depth': list.first['color_bit_depth'],
          },
          'raw': list,
        };
      }

      final report = <String, Object?>{
        'tag': tag,
        'timestamp': DateTime.now().toIso8601String(),
        'hwnd_found': hwnd != 0,
        'detail_resize': summarize(resizeSamples),
        'large_library_idle': summarize(libraryIdleSamples),
        'video_osd_playback': summarize(osdPlaybackSamples),
      };

      binding.reportData = report;
      debugPrint('WIN_PERF_REPORT_$tag=${jsonEncode(report)}');
      expect(resizeSamples.length, equals(5));
      expect(libraryIdleSamples.length, equals(5));
      expect(osdPlaybackSamples.length, equals(5));
    } finally {
      binding.removeTimingsCallback(collectFrames);
      container.dispose();
      await db.close();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    }
  });
}
