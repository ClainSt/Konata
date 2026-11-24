import 'dart:io';
import 'dart:typed_data';

import 'package:feature_detail/feature_detail.dart';
import 'package:feature_library/feature_library.dart';
import 'package:feature_scan_viewer/feature_scan_viewer.dart';
import 'package:feature_sources/feature_sources.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:konata/bootstrap/app_bootstrap.dart';
import 'package:konata/bootstrap/feature_registry.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_design_system/konata_design_system.dart';
import 'package:konata_storage/konata_storage.dart';

void main() {
  group('apps/konata 双端极薄组装壳与 Phase 3 端到端闭环', () {
    testWidgets('挂载四大扩展模块、保持 cache.db 惰性，并打通媒体源到海报墙到详情页到扫图标签全链路', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final tempRoot = Directory.systemTemp.createTempSync('konata_shell_e2e_');
      addTearDown(() {
        if (tempRoot.existsSync()) {
          tempRoot.deleteSync(recursive: true);
        }
      });

      late final KonataBootstrapContext bootstrap;
      await tester.runAsync(() async {
        bootstrap = await KonataBootstrapContext.initialize(
          platform: KonataPlatform.windows,
          storageRoot: PortableStorageRootService(
            overrideRootPath: tempRoot.path,
          ),
          secureStorage: InMemorySecureStorage(),
          filePicker: const NoopFilePickerPort(),
          urlOpener: const NoopUrlOpenerPort(),
          useInMemoryDatabases: true,
          autoStartDetailWarmupAndBackfill: false,
          customScanStreamOpener: (source, variant, maxBytes) async {
            final sampleRgba = Uint8List(4 * 4 * 4)..fillRange(0, 64, 0xFF);
            final webp = CompactWebpEncoder.encodeRgba(
              rgba: sampleRgba,
              width: 4,
              height: 4,
            );
            return (
              stream: Stream<List<int>>.value(webp),
              close: () async {},
            );
          },
        );
      });
      addTearDown(() => tester.runAsync(bootstrap.dispose));

      // 冷启动阶段缓存库必须保持惰性未打开，且四个 Phase 3 模块均按字母序注册。
      expect(bootstrap.databases.isCacheOpen, isFalse);
      expect(
        bootstrap.featureRegistry.manifests.map((m) => m.id).toList(),
        equals(<String>[
          'feature_detail',
          'feature_library',
          'feature_scan_viewer',
          'feature_sources',
        ]),
      );

      // 模拟已完成加源与刮削入库：写入媒体源、作品、正片剧集及扫图画集变体。
      final sourceId = SourceId('src-e2e');
      final workId = WorkId('work-frieren');
      final episodeId = EpisodeId('ep-01');
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      bootstrap.databases.library.mediaSources.upsert(
        MediaSourceRecord(
          id: sourceId,
          kind: MediaSourceKind.local,
          label: '本地蓝光番剧盘',
          location: tempRoot.path,
          createdAtMs: nowMs,
          updatedAtMs: nowMs,
        ),
      );
      bootstrap.databases.library.works.upsert(
        WorkRecord(
          id: workId,
          title: '葬送的芙莉莲',
          originalTitle: '葬送のフリーレン',
          year: 2023,
          tmdbId: 209867,
          tmdbMediaType: TmdbMediaType.tv,
          scrapeStatus: ScrapeStatus.matched,
          updatedAtMs: nowMs,
        ),
      );
      bootstrap.databases.library.episodes.upsert(
        EpisodeRecord(
          id: episodeId,
          workId: workId,
          seasonNumber: 1,
          episodeNumber: 1,
          category: EpisodeCategory.main,
          title: '冒险的终点',
          updatedAtMs: nowMs,
        ),
      );
      bootstrap.databases.library.mediaVariants.upsert(
        MediaVariantRecord(
          id: VariantId('var-ep-01'),
          workId: workId,
          episodeId: episodeId,
          sourceId: sourceId,
          relativePath: 'Frieren/01.mkv',
          fileName: '01.mkv',
          fileSize: 1024 * 1024,
          assetKind: AssetKind.video,
          updatedAtMs: nowMs,
        ),
      );
      bootstrap.databases.library.mediaVariants.upsert(
        MediaVariantRecord(
          id: VariantId('var-scan-01'),
          workId: workId,
          sourceId: sourceId,
          relativePath: 'Frieren/Scans/Booklet_01.webp',
          fileName: 'Booklet_01.webp',
          fileSize: 2048,
          assetKind: AssetKind.scanGallery,
          updatedAtMs: nowMs,
        ),
      );

      await tester.pumpWidget(
        KonataBootstrapApp(
          bootstrap: bootstrap,
          platformLabel: 'Windows',
        ),
      );
      await _pumpFrames(tester);

      // 1. 海报墙默认挂载真实的 LibraryPage，展示已入库作品。
      expect(find.byType(KonataAdaptiveShell), findsOneWidget);
      expect(find.byType(LibraryPage), findsOneWidget);
      expect(find.text('葬送的芙莉莲'), findsWidgets);

      // 2. 切换至顶层「媒体源」分区，确认真实的 SourcesPage 已挂载并展示已配置媒体源。
      await tester.tap(find.text('媒体源').first);
      await _pumpFrames(tester);
      expect(find.byType(SourcesPage), findsOneWidget);
      expect(find.text('本地蓝光番剧盘'), findsWidgets);

      // 3. 切回「媒体库」并点击作品卡片，经 AppNavigator 推入 WorkDetailPage。
      await tester.tap(find.text('媒体库').first);
      await _pumpFrames(tester);
      await tester.tap(find.byType(PosterCard).first);
      await _pumpFrames(tester, count: 8);

      expect(find.byType(WorkDetailPage), findsOneWidget);
      expect(find.text('葬送的芙莉莲'), findsWidgets);

      // 4. 详情页通过 DetailTabContribution 动态挂载 feature_scan_viewer 的「扫图」标签并可切换渲染。
      final scanTabFinder = find.text('扫图');
      expect(scanTabFinder, findsWidgets);
      await tester.tap(scanTabFinder.first);
      await _pumpFrames(tester, count: 6);
      expect(find.byType(ScanGalleryTabHost), findsOneWidget);

      // 在退出前显式卸载组件树以触发全部控制器与调度器同步释放。
      await tester.pumpWidget(const SizedBox.shrink());
      await _pumpFrames(tester, count: 2);
    });

    test('FeatureRegistry 强制校验字母序与唯一标识并按平台过滤扩展点', () {
      expect(
        () => FeatureRegistry(<FeatureManifest>[
          const FeatureManifest(id: 'feature_z', displayName: 'Z'),
          const FeatureManifest(id: 'feature_a', displayName: 'A'),
        ]),
        throwsArgumentError,
      );
      expect(
        () => FeatureRegistry(<FeatureManifest>[
          const FeatureManifest(id: 'feature_a', displayName: 'A1'),
          const FeatureManifest(id: 'feature_a', displayName: 'A2'),
        ]),
        throwsArgumentError,
      );

      final registry = FeatureRegistry(<FeatureManifest>[
        FeatureManifest(
          id: 'feature_alpha',
          displayName: 'Alpha',
          settingsSections: <SettingsSectionContribution>[
            SettingsSectionContribution(
              id: 'win_only',
              title: '仅桌面设置',
              iconKey: 'desktop',
              order: 20,
              supportedPlatforms: const <KonataPlatform>{KonataPlatform.windows},
              viewBuilder: (_) => 'win',
            ),
            SettingsSectionContribution(
              id: 'common',
              title: '通用设置',
              iconKey: 'settings',
              order: 10,
              viewBuilder: (_) => 'all',
            ),
          ],
        ),
      ]);

      final winSections = registry.settingsSectionsFor(KonataPlatform.windows);
      expect(
        winSections.map((s) => s.id),
        equals(<String>['common', 'win_only']),
      );

      final phoneSections = registry.settingsSectionsFor(
        KonataPlatform.androidPhone,
      );
      expect(phoneSections.map((s) => s.id), equals(<String>['common']));
    });
  });
}

Future<void> _pumpFrames(WidgetTester tester, {int count = 5}) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 80));
  }
}
