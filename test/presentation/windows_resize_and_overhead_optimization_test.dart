import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:konata/application/providers/library_providers.dart';
import 'package:konata/application/providers/memory_coordinator.dart';
import 'package:konata/application/providers/scraping_providers.dart';
import 'package:konata/composition/platform_composition.dart';
import 'package:konata/domain/models/episode.dart';
import 'package:konata/domain/models/media_source.dart';
import 'package:konata/domain/models/media_variant.dart';
import 'package:konata/domain/models/work.dart';
import 'package:konata/infrastructure/cache/artwork_cache.dart';
import 'package:konata/infrastructure/cache/photos_storage.dart';
import 'package:konata/infrastructure/database/drift_library_repository.dart';
import 'package:konata/infrastructure/database/konata_database.dart';
import 'package:konata/infrastructure/players/mpv_thumbnail_service.dart';
import 'package:konata/presentation/theme/konata_theme.dart';
import 'package:konata/presentation/widgets/design_system/konata_adaptive_blur.dart';
import 'package:konata/presentation/widgets/design_system/konata_keep_alive_tab_switcher.dart';
import 'package:konata/presentation/widgets/managed_image.dart';
import 'package:konata/presentation/widgets/playback/konata_playback_capsule.dart';

/// 标准 1×1 纯色 PNG 字节常量（零异步编码，FakeAsync 测试安全）。
final Uint8List _kValid1x1Png = Uint8List.fromList(const <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53,
  0xDE, 0x00, 0x00, 0x00, 0x0C, 0x49, 0x44, 0x41,
  0x54, 0x08, 0xD7, 0x63, 0xF8, 0xCF, 0xC0, 0x00,
  0x00, 0x03, 0x01, 0x01, 0x00, 0x18, 0xDD, 0x8D,
  0xB0, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E,
  0x44, 0xAE, 0x42, 0x60, 0x82,
]);

void main() {
  group('模块一：窗口拖拽分组模糊与 ManagedImage 拉伸锁定', () {
    testWidgets('KonataAdaptiveBackdropBlur 在 BackdropGroup 内自动分组，且拖拽期暂停模糊、松手即刻还原', (
      tester,
    ) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final groupKey = BackdropKey();

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: KonataTheme.darkTheme(),
            home: BackdropGroup(
              backdropKey: groupKey,
              child: Center(
                child: KonataAdaptiveBackdropBlur(
                  filter: KonataTheme.blurFilterMedium,
                  child: const SizedBox(width: 120, height: 48),
                ),
              ),
            ),
          ),
        ),
      );

      final restingFilter = tester.widget<BackdropFilter>(
        find.byType(BackdropFilter),
      );
      final restingRender = tester.renderObject<RenderBackdropFilter>(
        find.byType(BackdropFilter),
      );
      expect(restingFilter.enabled, isTrue);
      expect(restingRender.backdropKey, equals(groupKey));

      container.read(windowLiveResizingProvider.notifier).state = true;
      await tester.pump();

      final resizingFilter = tester.widget<BackdropFilter>(
        find.byType(BackdropFilter),
      );
      expect(resizingFilter.enabled, isFalse);

      container.read(windowLiveResizingProvider.notifier).state = false;
      await tester.pump();

      final restoredFilter = tester.widget<BackdropFilter>(
        find.byType(BackdropFilter),
      );
      expect(restoredFilter.enabled, isTrue);
    });

    testWidgets('ManagedImage 拖拽期锁定目标宽度并降档 FilterQuality.low，松手后恢复 FilterQuality.high', (
      tester,
    ) async {
      final pngBytes = _kValid1x1Png;
      final requestedWidths = <int?>[];
      Future<Uint8List> stableLoader(
        String _, {
        int? targetWidth,
        dynamic imageSize,
      }) async {
        requestedWidths.add(targetWidth);
        return pngBytes;
      }

      final container = ProviderContainer();
      addTearDown(container.dispose);

      Widget buildBox(double width) {
        return UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: KonataTheme.darkTheme(),
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: width,
                  height: 360,
                  child: ManagedImage(
                    'https://example.invalid/hero.png',
                    loader: stableLoader,
                    isHeroBackdrop: true,
                    fit: BoxFit.cover,
                  ),
                ),
              ),
            ),
          ),
        );
      }

      await tester.pumpWidget(buildBox(600));
      await tester.pumpAndSettle();

      final imgBefore = tester.widget<Image>(find.byType(Image));
      expect(imgBefore.filterQuality, equals(FilterQuality.high));
      final loadsBeforeDrag = requestedWidths.length;

      // 开始拖拽窗口：大幅改变容器宽度期间不得触发重复解码，且临时降档为 low。
      container.read(windowLiveResizingProvider.notifier).state = true;
      await tester.pump();
      await tester.pumpWidget(buildBox(1100));
      await tester.pump();

      final imgDuring = tester.widget<Image>(find.byType(Image));
      expect(imgDuring.filterQuality, equals(FilterQuality.low));
      expect(requestedWidths.length, equals(loadsBeforeDrag));

      // 松手结束拖拽：立即恢复 FilterQuality.high 并按新宽度更新目标档位。
      container.read(windowLiveResizingProvider.notifier).state = false;
      await tester.pumpAndSettle();

      final imgAfter = tester.widget<Image>(find.byType(Image));
      expect(imgAfter.filterQuality, equals(FilterQuality.high));
      expect(requestedWidths.length, greaterThan(loadsBeforeDrag));
    });
  });

  group('模块二：媒体库零变体常驻、autoDispose 回收与后台页懒卸载', () {
    test('libraryItemsProvider 零全量变体滞留且完整保留标量摘要与 workDetailBundleProvider 自动回收', () async {
      final db = KonataDatabase(NativeDatabase.memory());
      final repo = DriftLibraryRepository(db);
      final tempDir = await testerTempDir();
      final photos = PhotosStorage(overrideRoot: tempDir);
      addTearDown(() async {
        await db.close();
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      await repo.upsertMediaSource(
        MediaSource(
          id: 'src_1',
          label: '本地片库',
          kind: MediaSourceKind.local,
          location: tempDir.path,
        ),
      );
      await repo.upsertWork(
        const Work(
          id: 'w_slim',
          title: '瘦身测试番剧',
          scrapeStatus: ScrapeStatus.matched,
        ),
      );
      await repo.upsertEpisodesBatch(const [
        Episode(
          id: 'ep_1',
          workId: 'w_slim',
          seasonNumber: 1,
          episodeNumber: 1,
          title: '第 1 集',
          category: EpisodeCategory.main,
        ),
      ]);
      await repo.upsertMediaVariantsBatch(const [
        MediaVariant(
          id: 'v_1',
          workId: 'w_slim',
          episodeId: 'ep_1',
          sourceId: 'src_1',
          relativePath: 'Anime/Ep01_VCB.mkv',
          fileName: 'Ep01_VCB.mkv',
          fileSize: 1024,
          releaseGroup: 'VCB-Studio',
        ),
        MediaVariant(
          id: 'v_2',
          workId: 'w_slim',
          episodeId: 'ep_1',
          sourceId: 'src_1',
          relativePath: 'Anime/Ep01_Moozzi2.mkv',
          fileName: 'Ep01_Moozzi2.mkv',
          fileSize: 2048,
          releaseGroup: 'Moozzi2',
        ),
      ]);

      final disposedProviders = <Object?>[];
      final container = ProviderContainer(
        observers: [_DisposeSpyObserver(disposedProviders)],
        overrides: [
          konataDatabaseProvider.overrideWithValue(db),
          libraryRepositoryProvider.overrideWithValue(repo),
          photosStorageProvider.overrideWithValue(photos),
        ],
      );
      addTearDown(container.dispose);

      final items = await container.read(libraryItemsProvider.future);
      expect(items, hasLength(1));
      final item = items.single;
      expect(item.variants, isEmpty);
      expect(item.variantCount, equals(2));
      expect(item.firstVariantRelativePath, equals('Anime/Ep01_VCB.mkv'));
      expect(item.episodeCount, equals(1));
      expect(item.maxEpisodeVariantCount, equals(2));
      expect(item.sourceIds, equals(const <String>['src_1']));
      expect(
        item.copyWithCrossSourceBadge('本地').variantCount,
        equals(2),
      );

      // 校验详情包 autoDispose：释放监听后立即被回收。
      final bundleProvider = workDetailBundleProvider('w_slim');
      final sub = container.listen(bundleProvider, (_, _) {});
      final bundle = await container.read(bundleProvider.future);
      expect(bundle?.variants.length, equals(2));
      sub.close();
      await Future<void>.delayed(Duration.zero);
      expect(disposedProviders, contains(bundleProvider));
    });

    test('KonataMemoryCoordinator 桌面缓存上限为 36 MiB / 120 条，且 onExitWorkDetail 仅清理非音频缓存', () async {
      expect(
        KonataMemoryCoordinator.desktopImageCacheMaxBytes,
        equals(36 * 1024 * 1024),
      );
      expect(KonataMemoryCoordinator.desktopImageCacheMaxEntries, equals(120));

      final tempDir = await testerTempDir();
      final artCache = ArtworkCache(tempDir);
      addTearDown(() async {
        artCache.close();
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });
      await artCache.write('poster_1', Uint8List(32 * 1024));
      var uiTrimCount = 0;

      final container = ProviderContainer(
        overrides: [
          artworkCacheProvider.overrideWith((_) async => artCache),
          konataUiImageCacheTrimmerProvider.overrideWithValue(() {
            uiTrimCount += 1;
          }),
        ],
      );
      addTearDown(container.dispose);

      await container.read(artworkCacheProvider.future);
      final coordinator = container.read(konataMemoryCoordinatorProvider);
      coordinator.onExitWorkDetail();
      expect(uiTrimCount, equals(1));
      expect(artCache.currentMemoryBytes, equals(0));
    });

    testWidgets('KonataKeepAliveTabSwitcher 零定时器按时间戳懒回收超时后台非锁定页且始终保活首页', (
      tester,
    ) async {
      var now = DateTime(2026, 5, 1, 12, 0, 0);
      var page0Builds = 0;
      var page1Builds = 0;

      Widget buildTabs(int active) {
        return MaterialApp(
          theme: KonataTheme.darkTheme(),
          home: KonataKeepAliveTabSwitcher(
            activeIndex: active,
            duration: Duration.zero,
            idleEvictAfter: const Duration(seconds: 90),
            pinnedIndices: const <int>{0},
            clock: () => now,
            children: [
              _BuildCountBox(
                key: const ValueKey('tab_0'),
                label: '首页',
                onBuild: () => page0Builds += 1,
              ),
              _BuildCountBox(
                key: const ValueKey('tab_1'),
                label: '媒体源',
                onBuild: () => page1Builds += 1,
              ),
              const SizedBox(key: ValueKey('tab_2')),
            ],
          ),
        );
      }

      await tester.pumpWidget(buildTabs(0));
      expect(find.byKey(const ValueKey('tab_0')), findsOneWidget);
      expect(find.byKey(const ValueKey('tab_1')), findsNothing);

      // 切到第 1 页再切回首页，此时第 1 页处于后台保活。
      await tester.pumpWidget(buildTabs(1));
      expect(find.byKey(const ValueKey('tab_1')), findsOneWidget);
      await tester.pumpWidget(buildTabs(0));
      expect(find.byKey(const ValueKey('tab_1'), skipOffstage: false), findsOneWidget);

      // 超过 90 秒后再切到第 2 页：非锁定的第 1 页应被卸载，锁定的第 0 页保持挂载。
      now = now.add(const Duration(seconds: 95));
      await tester.pumpWidget(buildTabs(2));
      expect(find.byKey(const ValueKey('tab_1'), skipOffstage: false), findsNothing);
      expect(find.byKey(const ValueKey('tab_0'), skipOffstage: false), findsOneWidget);
      expect(page0Builds, greaterThanOrEqualTo(1));
      expect(page1Builds, greaterThanOrEqualTo(1));
    });
  });

  group('模块三：播控胶囊 60Hz 进度隔离与缩略图释放预算', () {
    test('MpvThumbnailService 空闲自动释放默认时长收紧至 15 秒', () {
      expect(
        MpvThumbnailService.defaultIdleReleaseDuration,
        equals(const Duration(seconds: 15)),
      );
    });

    testWidgets('KonataPlaybackCapsule 传入 positionListenable 时 60Hz 推进零整胶囊重建且 1Hz 更新时间戳', (
      tester,
    ) async {
      final posNotifier = ValueNotifier<double>(10.0);
      addTearDown(posNotifier.dispose);
      var rightSlotBuildCount = 0;

      await tester.pumpWidget(
        MaterialApp(
          theme: KonataTheme.darkTheme(),
          home: Scaffold(
            body: Center(
              child: KonataPlaybackCapsule(
                title: '孤立更新验证',
                positionSeconds: 10.0,
                positionListenable: posNotifier,
                durationSeconds: 1440.0,
                isPlaying: true,
                onTogglePlayPause: () {},
                onSeek: (_) {},
                rightSlot: _BuildCountBox(
                  label: 'right',
                  onBuild: () => rightSlotBuildCount += 1,
                ),
              ),
            ),
          ),
        ),
      );

      expect(find.text('00:10 / 24:00'), findsOneWidget);
      final initialBuilds = rightSlotBuildCount;

      // 连续 30 次亚秒级更新（10.02 -> 10.60），时间戳保持 00:10 且胶囊主体零重建。
      for (var i = 1; i <= 30; i++) {
        posNotifier.value = 10.0 + i * 0.02;
        await tester.pump();
      }
      expect(rightSlotBuildCount, equals(initialBuilds));
      expect(find.text('00:10 / 24:00'), findsOneWidget);

      // 跨入下一整秒后，仅时间戳叶子更新至 00:11，胶囊右侧按钮槽仍零重建。
      posNotifier.value = 11.05;
      await tester.pump();
      expect(find.text('00:11 / 24:00'), findsOneWidget);
      expect(rightSlotBuildCount, equals(initialBuilds));
    });
  });
}

Future<Directory> testerTempDir() =>
    Directory.systemTemp.createTemp('konata_win_opt_test_');

final class _DisposeSpyObserver extends ProviderObserver {
  _DisposeSpyObserver(this.disposed);

  final List<Object?> disposed;

  @override
  void didDisposeProvider(ProviderObserverContext context) {
    disposed.add(context.provider);
  }
}

class _BuildCountBox extends StatelessWidget {
  const _BuildCountBox({
    super.key,
    required this.label,
    required this.onBuild,
  });

  final String label;
  final VoidCallback onBuild;

  @override
  Widget build(BuildContext context) {
    onBuild();
    return SizedBox(width: 24, height: 24, child: Text(label));
  }
}
