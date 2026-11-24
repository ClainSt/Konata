import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:engine_scraping/engine_scraping.dart';
import 'package:engine_sources/engine_sources.dart';
import 'package:feature_scan_viewer/feature_scan_viewer.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_design_system/konata_design_system.dart';
import 'package:konata_storage/konata_storage.dart';

Future<Uint8List> _makePng(int width, int height, Color color) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..color = color,
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } finally {
    image.dispose();
    picture.dispose();
  }
}

void main() {
  group('ScanGalleryView 与 ScanLightboxDialog 组件及多视口测试', () {
    testWidgets(
      '经 DetailTabContribution 挂载渲染双模式切换、滚动划走自动取消 ticket 与灯箱交互',
      (tester) async {
        final tempPhotos = Directory.systemTemp.createTempSync(
          'konata_widget_scans_',
        );
        final db = KonataDatabaseBundle.openInMemory();
        addTearDown(() async {
          await db.close();
          if (tempPhotos.existsSync()) {
            tempPhotos.deleteSync(recursive: true);
          }
        });

        late final Uint8List samplePng;
        await tester.runAsync(() async {
          samplePng = await _makePng(400, 300, const Color(0xFF4A90E2));
        });

        final workId = WorkId('w_widget_1');
        final sourceId = SourceId('src_dav');
        db.library.mediaSources.upsert(
          MediaSourceRecord(
            id: sourceId,
            kind: MediaSourceKind.webdav,
            label: '测试云盘源',
            location: 'https://dav.example.com/anime',
          ),
        );
        db.library.works.upsert(
          WorkRecord(id: workId, title: '画册测试作品'),
        );

        for (var i = 0; i < 24; i++) {
          final vol = i < 12 ? 'Vol.1' : 'Vol.2';
          db.library.mediaVariants.upsert(
            MediaVariantRecord(
              id: VariantId('scan_$i'),
              workId: workId,
              sourceId: sourceId,
              relativePath: 'Scans/$vol/page_${i.toString().padLeft(2, '0')}.png',
              fileName: 'page_${i.toString().padLeft(2, '0')}.png',
              fileSize: samplePng.length,
              assetKind: AssetKind.scanGallery,
            ),
          );
        }

        final cancelledStreamIds = <String>[];
        final activeControllers = <String, StreamController<List<int>>>{};
        var blockThumbnailStreams = true;

        Future<({Stream<List<int>> stream, Future<void> Function() close})>
        streamOpener(
          MediaSourceView source,
          MediaVariant variant,
          int maxBytes,
        ) async {
          if (!blockThumbnailStreams) {
            return (
              stream: Stream<List<int>>.value(samplePng),
              close: () async {},
            );
          }
          late final StreamController<List<int>> ctrl;
          ctrl = StreamController<List<int>>(
            onCancel: () => cancelledStreamIds.add(variant.id),
          );
          activeControllers[variant.id] = ctrl;
          return (
            stream: ctrl.stream,
            close: () async {
              if (!ctrl.isClosed) await ctrl.close();
            },
          );
        }

        final prefsStore = ScopedPrefsStore(db.userState);
        final photosStorage = PhotosStorage(overrideRoot: tempPhotos);
        final deps = FeatureScanViewerDependencies(
          databases: db,
          storageRoot: PortableStorageRootService(
            overrideRootPath: tempPhotos.path,
          ),
          diagnosticLog: DiagnosticLogStore(),
          scopedPrefs: prefsStore,
          gatewayFactory: MediaSourceGatewayFactory(),
          photosStorage: photosStorage,
          platform: KonataPlatform.windows,
          customStreamOpener: streamOpener,
        );

        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final scrollController = ScrollController();
        addTearDown(scrollController.dispose);

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              featureScanViewerDependenciesProvider.overrideWithValue(deps),
            ],
            child: MaterialApp(
              theme: KonataTheme.darkTheme(),
              home: Scaffold(
                body: Builder(
                  builder: (ctx) => SizedBox.expand(
                    child:
                        featureScanViewerManifest.detailTabs.single.viewBuilder(
                          ViewSlotContext(
                            platformContext: ctx,
                            workId: workId,
                            arguments: <String, Object?>{
                              'scrollController': scrollController,
                            },
                          ),
                        ) as Widget,
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        await tester.pump();

        // 1. 验证默认整齐网格（保序画框）渲染且分卷胶囊可见，此时首批在途流已建立。
        expect(
          find.byKey(const ValueKey('scan_gallery_uniform_list')),
          findsOneWidget,
        );
        expect(find.text('全部 (24)'), findsOneWidget);
        expect(find.text('Vol.1 (12)'), findsOneWidget);
        expect(activeControllers.keys, isNotEmpty);
        final firstActiveId = activeControllers.keys.first;

        // 2. 切换为自适应等高瀑布流并验证偏好已持久化。
        await tester.tap(find.text('等高流'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 120));
        expect(
          find.byKey(const ValueKey('scan_gallery_justified_list')),
          findsOneWidget,
        );
        expect(
          prefsStore.read(scanGalleryPrefsSlice).mode,
          ScanGalleryMode.justified,
        );

        // 3. 切回整齐网格并快速滚动列表到底部，验证划出视口的卡片触发 ticket.cancel() 切断在途流。
        await tester.tap(find.text('保序画框'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 120));
        scrollController.jumpTo(scrollController.position.maxScrollExtent);
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        await tester.pump();
        expect(cancelledStreamIds, contains(firstActiveId));

        // 4. 滚回顶部并开放即时流读取，点击第一张扫图打开高清灯箱验证完整交互。
        blockThumbnailStreams = false;
        scrollController.jumpTo(0);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        final beforeLightboxFiles = tempPhotos
            .listSync(recursive: true)
            .whereType<File>()
            .map((f) => f.path)
            .toSet();

        await tester.tap(find.byKey(const ValueKey('scan_gallery_tile_scan_0')));
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump(const Duration(milliseconds: 150));

        expect(find.byType(ScanLightboxDialog), findsOneWidget);
        expect(find.text('page_00.png'), findsOneWidget);
        expect(find.textContaining('1 / 24'), findsOneWidget);
        expect(find.textContaining('400×300'), findsOneWidget);

        // 确认灯箱打开与读取原图期间绝不往磁盘写入任何文件。
        final afterLightboxFiles = tempPhotos
            .listSync(recursive: true)
            .whereType<File>()
            .map((f) => f.path)
            .toSet();
        expect(afterLightboxFiles.difference(beforeLightboxFiles), isEmpty);

        // 键盘右箭头切至第二页，随后按 Esc 关闭灯箱。
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump(const Duration(milliseconds: 150));
        expect(find.text('page_01.png'), findsOneWidget);
        expect(find.textContaining('2 / 24'), findsOneWidget);

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.byType(ScanLightboxDialog), findsNothing);
      },
    );

    testWidgets(
      '手机竖屏/手机横屏/平板/桌面四视口布局零溢出且内存滑窗关闭即释放',
      (tester) async {
        final tempPhotos = Directory.systemTemp.createTempSync(
          'konata_viewport_test_',
        );

        late final Uint8List samplePng;
        await tester.runAsync(() async {
          samplePng = await _makePng(640, 480, const Color(0xFF81B29A));
        });

        final scheduler = ScanThumbnailScheduler(
          photosStorage: PhotosStorage(overrideRoot: tempPhotos),
          streamOpener: (source, variant, maxBytes) async => (
            stream: Stream<List<int>>.value(samplePng),
            close: () async {},
          ),
        );

        final loader = ScanLightboxLoader(
          gatewayFactory: MediaSourceGatewayFactory(),
          streamOpener: (source, variant, maxBytes) async => (
            stream: Stream<List<int>>.value(samplePng),
            close: () async {},
          ),
        );

        final source = MediaSourceView(
          id: SourceId('src_v'),
          kind: MediaSourceKind.webdav,
          label: '测试源',
          location: 'https://dav.example.com/scans',
        );
        final items = List<MediaVariant>.generate(
          8,
          (i) => MediaVariant(
            id: 'vp_$i',
            workId: 'w_vp',
            sourceId: 'src_v',
            relativePath: 'Scans/${i < 4 ? 'Vol.1' : 'Vol.2'}/0$i.png',
            fileName: '0$i.png',
            assetKind: AssetKind.scanGallery,
            fileSize: samplePng.length,
          ),
        );
        final summary = SupplementarySubclassifier.groupScanVariants(items);

        final viewports = <({
          String name,
          Size size,
          TargetPlatform targetPlatform,
          KonataPlatform konataPlatform,
        })>[
          (
            name: '手机竖屏 390x780',
            size: const Size(390, 780),
            targetPlatform: TargetPlatform.android,
            konataPlatform: KonataPlatform.androidPhone,
          ),
          (
            name: '手机横屏 780x390',
            size: const Size(780, 390),
            targetPlatform: TargetPlatform.android,
            konataPlatform: KonataPlatform.androidPhone,
          ),
          (
            name: '平板 1024x700',
            size: const Size(1024, 700),
            targetPlatform: TargetPlatform.android,
            konataPlatform: KonataPlatform.androidTablet,
          ),
          (
            name: '桌面 1440x900',
            size: const Size(1440, 900),
            targetPlatform: TargetPlatform.windows,
            konataPlatform: KonataPlatform.windows,
          ),
        ];

        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        try {
          for (final vp in viewports) {
            debugDefaultTargetPlatformOverride = vp.targetPlatform;
            tester.view.physicalSize = vp.size;
            tester.view.devicePixelRatio = 1.0;

            final galleryCtrl = ScrollController();
            await tester.pumpWidget(
              MaterialApp(
                theme: KonataTheme.darkTheme(),
                home: Scaffold(
                  body: ScanGalleryView(
                    workId: WorkId('w_vp'),
                    workTitle: vp.name,
                    items: items,
                    sourcesById: {'src_v': source},
                    scanSummary: summary,
                    scheduler: scheduler,
                    scrollController: galleryCtrl,
                    prewarmOnMount: false,
                  ),
                ),
              ),
            );
            await tester.pump();
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 50)),
            );
            await tester.pump();
            expect(tester.takeException(), isNull, reason: '${vp.name} 画廊存在布局异常');

            // 同时挂载灯箱弹窗校验四视口零溢出，并在销毁后校验 96 MiB 滑窗即时释放归零。
            final memoryWindow = ScanLightboxMemoryWindow();
            await tester.pumpWidget(
              MaterialApp(
                theme: KonataTheme.darkTheme(),
                home: Scaffold(
                  body: ScanLightboxDialog(
                    workId: WorkId('w_vp'),
                    workTitle: vp.name,
                    scans: items,
                    sourcesById: {'src_v': source},
                    initialVariant: items.first,
                    scanSummary: summary,
                    scheduler: scheduler,
                    loader: loader,
                    memoryWindow: memoryWindow,
                    platform: vp.konataPlatform,
                  ),
                ),
              ),
            );
            galleryCtrl.dispose();
            await tester.pump();
            for (var round = 0; round < 20 && memoryWindow.totalBytes == 0; round++) {
              await tester.runAsync(
                () => Future<void>.delayed(const Duration(milliseconds: 25)),
              );
              await tester.pump(const Duration(milliseconds: 25));
            }
            expect(tester.takeException(), isNull, reason: '${vp.name} 灯箱存在布局异常');
            expect(memoryWindow.totalBytes, greaterThan(0));

            // 卸载灯箱，确认内存滑窗同步清空释放。
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.pump();
            expect(memoryWindow.totalBytes, 0);
            expect(memoryWindow.isEmpty, isTrue);
          }
        } finally {
          scheduler.dispose();
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 120)),
          );
          if (tempPhotos.existsSync()) {
            tempPhotos.deleteSync(recursive: true);
          }
        }
      },
    );
  });
}
