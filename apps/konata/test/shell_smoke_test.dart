import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:engine_playback/engine_playback.dart'
    show LegacyCodePageTables, OpenCcDictionaries;
import 'package:engine_scraping/engine_scraping.dart' show ReleaseGroups;
import 'package:feature_detail/feature_detail.dart';
import 'package:feature_history/feature_history.dart';
import 'package:feature_library/feature_library.dart';
import 'package:feature_player_audio/feature_player_audio.dart';
import 'package:feature_scan_viewer/feature_scan_viewer.dart';
import 'package:feature_settings/feature_settings.dart';
import 'package:feature_sources/feature_sources.dart';
import 'package:flutter/services.dart' show MethodCall, StandardMethodCodec;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:konata/bootstrap/app_bootstrap.dart';
import 'package:konata/bootstrap/feature_registry.dart';
import 'package:konata/bootstrap/windows_window_host.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_design_system/konata_design_system.dart';
import 'package:konata_storage/konata_storage.dart';

void main() {
  testWidgets('停用媒体库后隐藏其导航和搜索，历史和音频仍可加载海报', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final directory = Directory.systemTemp.createTempSync('konata_no_library_');
    addTearDown(() => directory.deleteSync(recursive: true));
    final registry = FeatureRegistry(
      registeredFeatureManifests
          .where((manifest) => manifest.id != 'feature_library')
          .toList(),
    );
    final bootstrap = (await tester.runAsync(
      () => KonataBootstrapContext.initialize(
        platform: KonataPlatform.windows,
        storageRoot: PortableStorageRootService(
          overrideRootPath: directory.path,
        ),
        secureStorage: InMemorySecureStorage(),
        useInMemoryDatabases: true,
        featureRegistry: registry,
        autoStartDetailWarmupAndBackfill: false,
        autoStartOngoingWorksSync: false,
      ),
    ))!;
    addTearDown(() => tester.runAsync(bootstrap.dispose));
    const workId = WorkId.trusted('work-without-library');
    final poster = File('${directory.path}/poster.png');
    final bytes = Uint8List.fromList([1, 2, 3]);
    poster.writeAsBytesSync(bytes);
    bootstrap.databases.library.works.upsert(
      WorkRecord(
        id: workId,
        title: '独立封面',
        posterRef: ArtworkRef.localCustom(localPath: poster.path, locked: true),
      ),
    );
    await tester.pumpWidget(
      KonataBootstrapApp(bootstrap: bootstrap, platformLabel: 'Windows'),
    );
    await _pumpFrames(tester);
    expect(find.byType(LibraryPage), findsNothing);
    expect(find.text('媒体库'), findsNothing);
    await tester.tap(find.text('播放记录').first);
    await _pumpFrames(tester);
    expect(find.byType(PlaybackHistoryPage), findsOneWidget);
    final shell = tester.widget<KonataAdaptiveShell>(
      find.byType(KonataAdaptiveShell),
    );
    expect(shell.onSearchChanged, isNull);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(PlaybackHistoryPage)),
    );
    await tester.runAsync(() async {
      final history = container.read(featureHistoryDependenciesProvider);
      final audio = container.read(featurePlayerAudioDependenciesProvider);
      expect(await history.imageLoader!(workId), bytes);
      expect(await audio.posterLoader!(poster.path, workId.value), bytes);
    });
    await tester.pumpWidget(const SizedBox.shrink());
    await _pumpFrames(tester);
  });

  testWidgets('关闭详情预热时仍由媒体源模块调度启动和前台巡检', (tester) async {
    final directory = Directory.systemTemp.createTempSync(
      'konata_sources_runtime_',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final registry = FeatureRegistry([featureSourcesManifest]);
    final bootstrap = (await tester.runAsync(
      () => KonataBootstrapContext.initialize(
        platform: KonataPlatform.windows,
        storageRoot: PortableStorageRootService(
          overrideRootPath: directory.path,
        ),
        secureStorage: InMemorySecureStorage(),
        useInMemoryDatabases: true,
        featureRegistry: registry,
        autoStartDetailWarmupAndBackfill: false,
      ),
    ))!;
    addTearDown(() => tester.runAsync(bootstrap.dispose));
    final scraper = _CountingSourceScrapeController();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...bootstrap.toProviderOverrides(
            navigator: HostAppNavigator(
              navigatorKey: GlobalKey<NavigatorState>(),
              onSwitchNavSection: (_) {},
            ),
          ),
          sourceScrapeControllerProvider.overrideWithValue(scraper),
        ],
        child: registry.wrapRuntime(
          KonataPlatform.windows,
          const SizedBox.shrink(),
        ),
      ),
    );
    expect(scraper.calls, 0);
    await tester.pump(const Duration(seconds: 5));
    expect(scraper.calls, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    expect(scraper.calls, 2);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Windows 原生通道转发缩放与最小化并支持解绑', (tester) async {
    final resizing = ValueNotifier(false);
    addTearDown(resizing.dispose);
    var minimized = 0;
    final unbind = WindowsWindowHost().bindLiveResizeChannel(
      resizing,
      onMinimized: () => minimized++,
    );
    addTearDown(unbind);

    Future<void> send(String method, [Object? arguments]) async {
      final message = const StandardMethodCodec().encodeMethodCall(
        MethodCall(method, arguments),
      );
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        konataWindowResizeChannelName,
        message,
        null,
      );
    }

    await send('resizeStateChanged', true);
    expect(resizing.value, isTrue);
    await send('windowMinimized');
    expect(minimized, 1);
    await send('resizeStateChanged', false);
    expect(resizing.value, isFalse);
    unbind();
    await send('windowMinimized');
    expect(minimized, 1);
  }, variant: const TargetPlatformVariant({TargetPlatform.windows}));

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
          autoStartOngoingWorksSync: false,
          customScanStreamOpener: (source, variant, maxBytes) async {
            final sampleRgba = Uint8List(4 * 4 * 4)..fillRange(0, 64, 0xFF);
            final webp = CompactWebpEncoder.encodeRgba(
              rgba: sampleRgba,
              width: 4,
              height: 4,
            );
            return (stream: Stream<List<int>>.value(webp), close: () async {});
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
        KonataBootstrapApp(bootstrap: bootstrap, platformLabel: 'Windows'),
      );
      await _pumpFrames(tester);

      final imageKey = Object();
      final imageCache = PaintingBinding.instance.imageCache;
      imageCache.putIfAbsent(
        imageKey,
        () => OneFrameImageStreamCompleter(Completer<ImageInfo>().future),
      );
      konataSharedThumbnailByteLru.put(imageKey, Uint8List.fromList([42]));
      expect(imageCache.containsKey(imageKey), isTrue);
      final artworkBytes = Uint8List.fromList([0x89, 0x50, 0x4e, 0x47, 42]);
      final artwork = bootstrap.artworkCache;
      const artworkKey = 'memory-pressure-fixture';
      const artworkOwner = 'memory-pressure-work';
      await tester.runAsync(() async {
        await artwork.write('preview-pressure', artworkBytes);
        await artwork.write(
          artworkKey,
          artworkBytes,
          owner: artworkOwner,
          subfolder: PhotoSubfolder.posters,
        );
      });
      expect(artwork.memoryEntryCount, greaterThanOrEqualTo(2));
      expect(artwork.currentMemoryBytes, greaterThanOrEqualTo(10));

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      expect(imageCache.containsKey(imageKey), isFalse);
      expect(konataSharedThumbnailByteLru.get(imageKey), isNull);
      expect(artwork.memoryEntryCount, 0);
      expect(artwork.currentMemoryBytes, 0);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);

      await tester.runAsync(() async {
        expect(await artwork.read('preview-pressure'), isNull);
        // 清理仅作用于内存，作品海报仍能从磁盘恢复。
        expect(
          await artwork.read(
            artworkKey,
            owner: artworkOwner,
            subfolder: PhotoSubfolder.posters,
          ),
          artworkBytes,
        );
      });
      expect(artwork.memoryEntryCount, 1);
      konataSharedThumbnailByteLru.put(imageKey, artworkBytes);
      imageCache.putIfAbsent(
        imageKey,
        () => OneFrameImageStreamCompleter(Completer<ImageInfo>().future),
      );
      tester.binding.handleMemoryPressure();
      expect(artwork.currentMemoryBytes, 0);
      expect(artwork.memoryEntryCount, 0);
      expect(konataSharedThumbnailByteLru.get(imageKey), isNull);
      expect(imageCache.containsKey(imageKey), isFalse);
      await tester.runAsync(() async {
        expect(
          await artwork.read(
            artworkKey,
            owner: artworkOwner,
            subfolder: PhotoSubfolder.posters,
          ),
          artworkBytes,
        );
      });

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
      final detailPrefs = DetailDisplayPreferencesStore(bootstrap.scopedPrefs);
      detailPrefs.write(
        const DetailDisplayPreferences(
          showMainHeroBackdrop: false,
          extraFields: {'futureDisplayOption': '保留'},
        ),
      );
      await tester.tap(find.text('显示与存储'));
      await _pumpFrames(tester);
      expect(find.text('本地图片存储'), findsOneWidget);
      expect(find.text('详情页标题'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('settings_display_cd_tab_switch')),
      );
      await _pumpFrames(tester);
      final updatedDetailPrefs = detailPrefs.read();
      expect(updatedDetailPrefs.showCdTab, isFalse);
      expect(updatedDetailPrefs.showScanTab, isTrue);
      expect(updatedDetailPrefs.showMainHeroBackdrop, isFalse);
      expect(updatedDetailPrefs.extraFields['futureDisplayOption'], '保留');
      expect(find.text('备份与同步'), findsWidgets);
      expect(find.text('追踪记录'), findsWidgets);

      // 5. 切回「媒体库」并点击作品卡片进入 WorkDetailPage，并验证动态挂载「扫图」标签。
      await tester.tap(find.text('媒体库').first);
      await _pumpFrames(tester);
      await tester.tap(find.byType(PosterCard).first);
      await _pumpFrames(tester, count: 8);

      expect(find.byType(WorkDetailPage), findsOneWidget);
      final scanTabFinder = find.byKey(
        const ValueKey<String>('detail_tab_scan_viewer'),
      );
      expect(
        find.descendant(
          of: scanTabFinder,
          matching: find.textContaining('Scan'),
        ),
        findsOneWidget,
      );
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
              supportedPlatforms: const <KonataPlatform>{
                KonataPlatform.windows,
              },
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
        autoStartOngoingWorksSync: false,
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

final class _CountingSourceScrapeController extends Fake
    implements SourceScrapeController {
  int calls = 0;

  @override
  Future<int> runOngoingWorksAutoSyncIfDue({bool force = false}) async {
    calls++;
    return 0;
  }
}
