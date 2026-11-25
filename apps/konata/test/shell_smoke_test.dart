import 'dart:io';
import 'dart:typed_data';

import 'package:engine_playback/engine_playback.dart'
    show LegacyCodePageTables, OpenCcDictionaries;
import 'package:engine_scraping/engine_scraping.dart' show ReleaseGroups;
import 'package:feature_detail/feature_detail.dart';
import 'package:feature_history/feature_history.dart';
import 'package:feature_library/feature_library.dart';
import 'package:feature_scan_viewer/feature_scan_viewer.dart';
import 'package:feature_settings/feature_settings.dart';
import 'package:feature_sources/feature_sources.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:konata/bootstrap/app_bootstrap.dart';
import 'package:konata/bootstrap/feature_registry.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_design_system/konata_design_system.dart';
import 'package:konata_storage/konata_storage.dart';

void main() {
  group('apps/konata 双端极薄组装壳与全量 11 业务包端到端闭环', () {
    testWidgets('挂载全部 11 大扩展模块、保持 cache.db 惰性，并打通四主分区、详情扫图与跨包设置聚合全链路', (
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
          backupFilePort: const NoopBackupFilePort(),
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

      // 冷启动阶段缓存库必须保持惰性未打开，且全部 11 个业务模块严格按字母序注册。
      expect(bootstrap.databases.isCacheOpen, isFalse);
      expect(ReleaseGroups.isLoaded, isFalse);
      expect(OpenCcDictionaries.isLoaded, isFalse);
      expect(LegacyCodePageTables.isLoaded, isFalse);
      expect(ChinesePinyinCollator.isLoaded, isFalse);
      expect(
        bootstrap.featureRegistry.manifests.map((m) => m.id).toList(),
        equals(<String>[
          'feature_detail',
          'feature_history',
          'feature_library',
          'feature_lyrics',
          'feature_player_audio',
          'feature_player_video',
          'feature_scan_viewer',
          'feature_settings',
          'feature_sources',
          'feature_sync',
          'feature_tracker_sync',
        ]),
      );

      // 验证平台过滤：桌面专属外部工具分区仅出现在 Windows，Android 手机自动隐藏。
      final winSectionIds = bootstrap.featureRegistry
          .settingsSectionsFor(KonataPlatform.windows)
          .map((s) => s.id)
          .toList();
      final phoneSectionIds = bootstrap.featureRegistry
          .settingsSectionsFor(KonataPlatform.androidPhone)
          .map((s) => s.id)
          .toList();
      expect(winSectionIds, contains('external_tools'));
      expect(winSectionIds, contains('backup_sync'));
      expect(winSectionIds, contains('bangumi_sync'));
      expect(winSectionIds, contains('lyrics_sources'));
      expect(phoneSectionIds, isNot(contains('external_tools')));
      expect(phoneSectionIds, contains('backup_sync'));

      // 验证跨模块同步切片聚合包含内置三切片与歌词覆盖切片。
      final sliceIds = bootstrap.featureRegistry
          .syncSlicesFor(KonataPlatform.windows)
          .map((s) => s.sliceId)
          .toSet();
      expect(
        sliceIds,
        containsAll(<String>[
          'prefs_slice',
          'playback_history_slice',
          'library_catalog_slice',
          'lyric_overrides_slice',
        ]),
      );

      // 模拟已完成加源、刮削入库与播放记录落盘。
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
      bootstrap.databases.library.mediaVariants.upsert(
        MediaVariantRecord(
          id: VariantId('var-cd-01'),
          workId: workId,
          sourceId: sourceId,
          relativePath: 'Frieren/CD/01.flac',
          fileName: '01.flac',
          fileSize: 2048,
          assetKind: AssetKind.cdAlbum,
          updatedAtMs: nowMs,
        ),
      );
      bootstrap.databases.cache.scrapeCandidates.replaceForWork(workId, [
        ScrapeCandidateRecord(
          workId: workId,
          rank: 1,
          tmdbId: 209867,
          mediaType: TmdbMediaType.tv,
          title: '模拟刮削候选',
          score: 92,
          cachedAtMs: nowMs,
        ),
      ]);
      bootstrap.databases.userState.playbackRecords.upsert(
        PlaybackRecordEntity(
          id: 'rec-e2e-1',
          workId: workId,
          episodeId: episodeId,
          variantId: VariantId('var-ep-01'),
          positionSeconds: 420,
          durationSeconds: 1440,
          isCompleted: false,
          playedAtMs: nowMs,
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

      // 1. 海报墙默认挂载真实 LibraryPage。
      expect(find.byType(KonataAdaptiveShell), findsOneWidget);
      expect(find.byType(LibraryPage), findsOneWidget);
      expect(find.text('葬送的芙莉莲'), findsWidgets);
      expect(ReleaseGroups.isLoaded, isTrue);

      // 海报墙通过宿主打开详情模块的源文件复核与映射弹窗。
      await tester.longPress(find.byType(PosterCard).first);
      await _pumpFrames(tester);
      await tester.tap(find.text('查看源文件与拆分'));
      await _pumpFrames(tester, count: 8);
      expect(find.byType(SourceFilesReviewDialog), findsOneWidget);
      expect(find.text('音乐 CD'), findsOneWidget);
      expect(find.text('01.flac'), findsOneWidget);
      tester.view.physicalSize = const Size(780, 390);
      tester.view.viewInsets = const FakeViewPadding(bottom: 120);
      await _pumpFrames(tester);
      expect(tester.takeException(), isNull);
      tester.view.viewInsets = FakeViewPadding.zero;
      tester.view.physicalSize = const Size(1440, 900);
      await _pumpFrames(tester);
      await tester.tap(find.text('进入编辑与文件映射'));
      await _pumpFrames(tester, count: 8);
      expect(find.byType(WorkManualEditDialog), findsOneWidget);
      expect(find.byType(FileMappingPanel), findsOneWidget);
      await tester.tap(find.text('全选可见'));
      await _pumpFrames(tester);
      expect(find.text('已选 1 项：'), findsOneWidget);
      expect(find.text('拆为独立作品'), findsOneWidget);
      await tester.tap(find.text('移至已有作品'));
      await _pumpFrames(tester);
      expect(find.byType(WorkMergeTargetDialog), findsOneWidget);
      expect(find.text('归入方式：'), findsOneWidget);
      tester.view.physicalSize = const Size(780, 390);
      tester.view.viewInsets = const FakeViewPadding(bottom: 120);
      await _pumpFrames(tester);
      expect(tester.takeException(), isNull);
      expect(find.text('归入方式：'), findsNothing);
      tester.view.viewInsets = FakeViewPadding.zero;
      tester.view.physicalSize = const Size(1440, 900);
      await _pumpFrames(tester);
      await tester.tap(find.text('取消').last);
      await _pumpFrames(tester);
      await tester.tap(find.text('取消').last);
      await _pumpFrames(tester);
      expect(find.byType(WorkManualEditDialog), findsNothing);

      await tester.longPress(find.byType(PosterCard).first);
      await _pumpFrames(tester);
      await tester.tap(find.text('手动匹配元数据'));
      await _pumpFrames(tester, count: 8);
      expect(find.byType(ManualMatchDialog), findsOneWidget);
      expect(find.text('自动刮削推荐候选（点击可直接采纳绑定）'), findsOneWidget);
      expect(find.text('采纳绑定'), findsOneWidget);
      expect(find.textContaining('TMDB #209867'), findsWidgets);
      expect(find.text('Bangumi'), findsOneWidget);
      tester.view.physicalSize = const Size(780, 390);
      tester.view.viewInsets = const FakeViewPadding(bottom: 120);
      await _pumpFrames(tester);
      expect(tester.takeException(), isNull);
      expect(find.text('TMDB'), findsNothing);
      expect(find.text('采纳绑定'), findsOneWidget);
      tester.view.viewInsets = FakeViewPadding.zero;
      tester.view.physicalSize = const Size(1440, 900);
      await _pumpFrames(tester);
      await tester.tap(find.text('双源混合'));
      await _pumpFrames(tester);
      expect(find.text('搜 Bangumi'), findsOneWidget);
      await tester.tap(find.text('取消').last);
      await _pumpFrames(tester);

      // 2. 切换至顶层「媒体源」分区，挂载真实 SourcesPage。
      await tester.tap(find.text('媒体源').first);
      await _pumpFrames(tester);
      expect(find.byType(SourcesPage), findsOneWidget);
      expect(find.text('本地蓝光番剧盘'), findsWidgets);

      // 3. 切换至顶层「播放记录」分区，挂载真实 PlaybackHistoryPage。
      await tester.tap(find.text('播放记录').first);
      await _pumpFrames(tester);
      expect(find.byType(PlaybackHistoryPage), findsOneWidget);

      // 4. 切换至顶层「设置」分区，挂载声明式 SettingsPage 并展示跨包聚合分区。
      await tester.tap(find.text('设置').first);
      await _pumpFrames(tester);
      expect(find.byType(SettingsPage), findsOneWidget);
      expect(find.text('备份与同步'), findsWidgets);
      expect(find.text('追番同步'), findsWidgets);

      // 5. 切回「媒体库」并点击作品卡片进入 WorkDetailPage，并验证动态挂载「扫图」标签。
      await tester.tap(find.text('媒体库').first);
      await _pumpFrames(tester);
      await tester.tap(find.byType(PosterCard).first);
      await _pumpFrames(tester, count: 8);

      expect(find.byType(WorkDetailPage), findsOneWidget);
      final scanTabFinder = find.text('扫图');
      expect(scanTabFinder, findsWidgets);
      await tester.tap(scanTabFinder.first);
      await _pumpFrames(tester, count: 6);
      expect(find.byType(ScanGalleryTabHost), findsOneWidget);

      // 退出前显式卸载组件树以触发所有控制器与调度器同步释放。
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

    test('启动预加载网络密钥与完整外观切片，且绝不覆盖其他外观字段', () async {
      final tempRoot = Directory.systemTemp.createTempSync('konata_preload_');
      addTearDown(() {
        if (tempRoot.existsSync()) {
          tempRoot.deleteSync(recursive: true);
        }
      });

      final secureStorage = InMemorySecureStorage();
      await secureStorage.write(
        SettingsNetworkRepository.tmdbCredentialKey,
        'tmdb-startup-key-test',
      );
      await secureStorage.write(
        SettingsNetworkRepository.fanartClientKeyStorageKey,
        'fanart-startup-key-test',
      );

      final bootstrap = await KonataBootstrapContext.initialize(
        platform: KonataPlatform.windows,
        storageRoot: PortableStorageRootService(
          overrideRootPath: tempRoot.path,
        ),
        secureStorage: secureStorage,
        filePicker: const NoopFilePickerPort(),
        backupFilePort: const NoopBackupFilePort(),
        urlOpener: const NoopUrlOpenerPort(),
        useInMemoryDatabases: true,
        autoStartDetailWarmupAndBackfill: false,
      );
      addTearDown(bootstrap.dispose);

      // 1. 启动即预加载 TMDB / Fanart 凭据至全局网络客户端。
      expect(bootstrap.httpClient.config.credential, 'tmdb-startup-key-test');
      expect(
        bootstrap.httpClient.config.fanartClientKey,
        'fanart-startup-key-test',
      );

      // 2. 完整外观切片保存与读取保留全部字段（themeMode / ambientBackdropEnabled / windowMaterial）。
      saveAppearancePrefs(
        bootstrap.scopedPrefs,
        const HostAppearanceState(
          themeMode: ThemeMode.light,
          ambientBackdropEnabled: false,
          windowMaterial: KonataWindowMaterial.mica,
        ),
      );
      final loaded = readInitialAppearancePrefs(bootstrap.scopedPrefs);
      expect(loaded.themeMode, ThemeMode.light);
      expect(loaded.ambientBackdropEnabled, isFalse);
      expect(loaded.windowMaterial, KonataWindowMaterial.mica);
    });
  });
}

Future<void> _pumpFrames(WidgetTester tester, {int count = 5}) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 80));
  }
}
