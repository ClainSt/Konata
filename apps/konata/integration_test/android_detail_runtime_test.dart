import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:feature_detail/feature_detail.dart';
import 'package:feature_scan_viewer/feature_scan_viewer.dart';
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

Future<void> _writeArtwork(
  File file,
  Color bottom, {
  bool portrait = true,
}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final height = portrait ? 900 : 400;
  canvas.drawRect(
    Rect.fromLTWH(0, 0, 600, height.toDouble()),
    Paint()..color = bottom,
  );
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, 600, 250),
    Paint()..color = const Color(0xFFE7CDA7),
  );
  canvas.drawCircle(
    const Offset(300, 220),
    130,
    Paint()..color = const Color(0xFFEEE7F0),
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(600, height);
  try {
    final data = (await image.toByteData(format: ui.ImageByteFormat.png))!;
    await file.writeAsBytes(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    );
  } finally {
    image.dispose();
    picture.dispose();
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('Android 真机详情溶底与扫图独立页面验收', (tester) async {
    expect(Platform.isAndroid, isTrue);
    const captureUrl = String.fromEnvironment('KONATA_ANDROID_AUDIT_URL');
    expect(captureUrl, startsWith('http://127.0.0.1:'));
    final parent = Directory(
      await (await createAndroidStorageRoot()).resolveAppRootPath(),
    );
    await parent.create(recursive: true);
    final root = await parent.createTemp('konata-android-detail-audit-');
    final media = Directory('${root.path}/media')..createSync();
    final surface = AndroidVideoSurfaceAdapter();
    final audioRoute = AndroidAudioRouteAdapter();
    final host = AndroidPlaybackWindowAdapter();
    final http = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    KonataBootstrapContext? bootstrap;
    final evidence = <String, Object?>{};

    Future<void> until(bool Function() condition, String reason) async {
      final watch = Stopwatch()..start();
      while (!condition() && watch.elapsed.inSeconds < 20) {
        await tester.pump(const Duration(milliseconds: 100));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(condition(), isTrue, reason: reason);
    }

    Future<void> tap(Finder finder) async {
      await until(() => finder.evaluate().isNotEmpty, '控件未出现：$finder');
      await tester.ensureVisible(finder.first);
      await until(
        () => finder.hitTestable().evaluate().isNotEmpty,
        '控件不可点击：$finder',
      );
      await tester.tap(finder.hitTestable().first);
      await tester.pump(const Duration(milliseconds: 350));
    }

    Future<void> capture(String stage) async {
      await tester.pump(const Duration(milliseconds: 400));
      final response = await (await http.getUrl(
        Uri.parse('$captureUrl/capture/$stage'),
      )).close();
      final status = response.statusCode;
      await response.drain<void>();
      expect(status, 200, reason: '真机截图失败：$stage');
      evidence['capture_$stage'] = true;
    }

    final page = find.byType(WorkDetailPage);
    final header = find.byKey(const ValueKey('detail_portrait_hero_header'));
    final gradients = find.descendant(
      of: header,
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is DecoratedBox &&
            widget.decoration is BoxDecoration &&
            (widget.decoration as BoxDecoration).gradient is LinearGradient,
      ),
    );

    Color? dissolve() {
      if (gradients.evaluate().length != 1) return null;
      final decoration =
          tester.widget<DecoratedBox>(gradients).decoration as BoxDecoration;
      return (decoration.gradient! as LinearGradient).colors.last;
    }

    try {
      await host.setPreferredLandscape(false);
      final view = binding.platformDispatcher.views.first;
      await until(
        () => view.physicalSize.height > view.physicalSize.width,
        '手机未进入竖屏',
      );
      expect(
        view.physicalSize.shortestSide / view.devicePixelRatio,
        lessThan(600),
      );
      final red = File('${media.path}/red.png');
      final blue = File('${media.path}/blue.png');
      await _writeArtwork(red, const Color(0xFFB82B41));
      await _writeArtwork(blue, const Color(0xFF3947BC));
      final scanDir = Directory('${media.path}/Scans')..createSync();
      final scans = [
        File('${scanDir.path}/01.png'),
        File('${scanDir.path}/02.png'),
      ];
      await _writeArtwork(scans[0], const Color(0xFF9C4371), portrait: false);
      await _writeArtwork(scans[1], const Color(0xFF5370C8), portrait: false);
      final files = [red, blue, ...scans];
      final before = {
        for (final file in files)
          file.path: (file.lengthSync(), file.lastModifiedSync()),
      };
      final boot = await KonataBootstrapContext.initialize(
        platform: KonataPlatform.androidPhone,
        storageRoot: PortableStorageRootService(overrideRootPath: root.path),
        secureStorage: InMemorySecureStorage(),
        filePicker: const NoopFilePickerPort(),
        backupFilePort: const NoopBackupFilePort(),
        urlOpener: const NoopUrlOpenerPort(),
        hostWindow: host,
        androidSurfacePort: surface,
        androidAudioRoutePort: audioRoute,
        androidAudioFocusPort: AndroidAudioFocusAdapter(),
        androidMediaSessionPort: AndroidMediaSessionAdapter(),
        androidPipPort: AndroidPipAdapter(),
        useInMemoryDatabases: true,
        autoStartDetailWarmupAndBackfill: false,
        autoStartOngoingWorksSync: false,
      );
      bootstrap = boot;
      final db = boot.databases.library;
      const redWork = WorkId.trusted('android-detail-red');
      const blueWork = WorkId.trusted('android-detail-blue');
      const source = SourceId.trusted('android-detail-source');
      db.mediaSources.upsert(
        MediaSourceRecord(
          id: source,
          kind: MediaSourceKind.local,
          label: '隔离合成图片',
          location: media.path,
        ),
      );
      for (final (work, file, title) in [
        (redWork, red, '暖色详情验收'),
        (blueWork, blue, '冷色详情验收'),
      ]) {
        db.works.upsert(
          WorkRecord(
            id: work,
            title: title,
            posterRef: LocalCustomArtworkRef(localPath: file.path),
            overview: '独立合成媒体验收，不涉及正式媒体库。',
            tmdbMediaType: TmdbMediaType.tv,
            scrapeStatus: ScrapeStatus.matched,
            updatedAtMs: 1,
          ),
        );
      }
      for (var i = 0; i < scans.length; i++) {
        final file = scans[i];
        db.mediaVariants.upsert(
          MediaVariantRecord(
            id: VariantId.trusted('android-detail-scan-$i'),
            workId: redWork,
            sourceId: source,
            relativePath: 'Scans/${file.uri.pathSegments.last}',
            fileName: file.uri.pathSegments.last,
            fileSize: file.lengthSync(),
            assetKind: AssetKind.scanGallery,
            updatedAtMs: 1,
          ),
        );
      }

      await tester.pumpWidget(
        KonataBootstrapApp(bootstrap: boot, platformLabel: 'Android'),
      );
      await until(
        () => find.byType(KonataAdaptiveShell).evaluate().isNotEmpty,
        '主界面未就绪',
      );
      final container = ProviderScope.containerOf(
        tester.element(find.byType(KonataAdaptiveShell)),
      );
      final navigator = container.read(appNavigatorProvider);
      Color? redColor;
      for (final (work, warm, stage) in [
        (redWork, true, 'detail-warm'),
        (blueWork, false, 'detail-cool'),
      ]) {
        unawaited(navigator.openWorkDetail(work));
        await until(() => header.evaluate().isNotEmpty, '详情头图未出现');
        await until(() {
          final color = dissolve();
          if (color == null) return false;
          final hsl = HSLColor.fromColor(color);
          return hsl.saturation > .1 &&
              (warm
                  ? (hsl.hue > 320 || hsl.hue < 25)
                  : hsl.hue > 190 && hsl.hue < 280);
        }, '背景未正确继承封面色相');
        final color = dissolve()!;
        expect(color.a, 1.0, reason: '渐变终点必须完全不透明，避免海报边缘产生混色断层');
        final canvas = find.ancestor(
          of: header,
          matching: find.byWidgetPredicate(
            (widget) => widget is ColoredBox && widget.color == color,
          ),
        );
        expect(canvas, findsWidgets, reason: '渐变末端与页面底色不一致');
        final rect = tester.getRect(header);
        expect(rect.height, greaterThan(260));
        if (warm) {
          redColor = color;
        } else {
          expect(color, isNot(redColor));
        }
        evidence['${stage}_color'] = color.toARGB32().toRadixString(16);
        await capture(stage);
        await navigator.pop();
        await until(() => page.evaluate().isEmpty, '详情未正常退出');
      }

      unawaited(navigator.openWorkDetail(redWork, initialTabId: 'scan_viewer'));
      final tile = find.byKey(
        const ValueKey('scan_inline_tile_android-detail-scan-0'),
      );
      await tap(tile);
      final viewer = find.byType(ScanLightboxDialog);
      await until(() => viewer.evaluate().isNotEmpty, '扫图未打开');
      final route = ModalRoute.of(tester.element(viewer))!;
      await until(
        () => route.isCurrent && (route.animation?.isCompleted ?? true),
        '扫图入场未完成',
      );
      expect(route.opaque, isTrue);
      expect(find.byType(Dialog), findsNothing);
      expect(page, findsNothing);
      await until(
        () => find.textContaining('600×400').evaluate().isNotEmpty,
        '原图尺寸未读取',
      );
      final filmstrip = find.byKey(const ValueKey('scan_lightbox_filmstrip'));
      await capture('scan-fullscreen-first');
      await tap(find.descendant(of: filmstrip, matching: find.text('2')).last);
      await until(
        () => find.textContaining('2 / 2').evaluate().isNotEmpty,
        '点击第二页未翻页',
      );
      await capture('scan-fullscreen-second');
      Navigator.of(tester.element(viewer)).pop();
      await until(
        () => viewer.evaluate().isEmpty && page.evaluate().isNotEmpty,
        '扫图关闭后未恢复详情',
      );
      evidence['scan_fullscreen_route'] = true;
      evidence['scan_turn_and_restore'] = true;
      for (final file in files) {
        expect((file.lengthSync(), file.lastModifiedSync()), before[file.path]);
      }
      evidence['source_files_unchanged'] = true;
      expect(tester.takeException(), isNull);
      binding.reportData = evidence;
      debugPrint('真机详情验收：$evidence');
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await bootstrap?.dispose();
      if (bootstrap == null) {
        audioRoute.dispose();
        await surface.dispose();
      }
      http.close(force: true);
      await host.setPreferredLandscape(false);
      await root.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
