import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:konata/application/playback/audio_playback_notifier.dart';
import 'package:konata/application/playback/playback_preferences_provider.dart';
import 'package:konata/application/providers/artwork_provider.dart';
import 'package:konata/application/providers/library_providers.dart';
import 'package:konata/application/providers/scan_lightbox_loader.dart';
import 'package:konata/application/providers/work_management_provider.dart';
import 'package:konata/application/sync/konata_backup_service.dart';
import 'package:konata/domain/models/media_extensions.dart';
import 'package:konata/domain/models/media_source.dart';
import 'package:konata/domain/models/media_variant.dart';
import 'package:konata/domain/models/work.dart';
import 'package:konata/infrastructure/cache/photos_storage.dart';
import 'package:konata/infrastructure/logging/diagnostics_log_store.dart';
import 'package:konata/infrastructure/sources/source_gateway_factory.dart';
import 'package:konata/presentation/audio/immersive_audio_sub_widgets.dart';
import 'package:konata/presentation/audio/mini_audio_bar.dart';
import 'package:konata/presentation/detail/scan_lightbox_dialog.dart';
import 'package:konata/presentation/dialogs/work_artwork_picker_dialog.dart';
import 'package:konata/presentation/library/library_page.dart';
import 'package:konata/presentation/shell/adaptive_capsule_layout.dart';
import 'package:konata/presentation/sources/source_editor_dialog.dart';
import 'package:konata/presentation/theme/konata_playback_tokens.dart';
import 'package:konata/presentation/theme/konata_theme.dart';
import 'package:konata/presentation/widgets/design_system/adaptive_action_header.dart';
import 'package:konata/presentation/widgets/design_system/konata_soft_text_field.dart';
import 'package:konata/presentation/widgets/design_system/konata_system_file_picker.dart';

/// 挂起候选艺术图请求的测试替身，用于验证加载期标题文案不闪烁空态提示。
class _PendingArtworkActions extends WorkManagementActions {
  _PendingArtworkActions(super.ref, this.completer);

  final Completer<WorkArtworkOptions> completer;

  @override
  Future<WorkArtworkOptions> fetchWorkArtworkOptions(
    Work work, {
    bool includeLogos = false,
  }) => completer.future;
}

/// 最小合法 1×1 透明 PNG，用于灯箱与图片组件测试零网络零磁盘。
final Uint8List _kOnePixelPng = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
]);

/// 灯箱图片加载器测试替身，直接返回内存测试图字节。
class _MemoryScanLightboxLoader extends ScanLightboxLoaderService {
  _MemoryScanLightboxLoader()
    : super(
        gatewayFactory: const MediaSourceGatewayFactory(),
        logStore: DiagnosticsLogStore(),
      );

  @override
  ScanImageLoadHandle startLoad({
    required MediaVariant variant,
    required MediaSource source,
  }) {
    return ScanImageLoadHandle(
      future: Future<Uint8List?>.value(_kOnePixelPng),
      onCancel: () async {},
    );
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
  });

  group('手机端极限压测定位缺陷回归验证', () {
    testWidgets('KonataRootBackGate 优先拦截全屏音频返回键而不弹出底层子路由，并在模态弹窗存在时让行', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);

      final container = ProviderContainer();
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: Consumer(
            builder: (context, ref, _) {
              final navKey = ref.watch(rootNavigatorKeyProvider);
              final routeObserver = ref.watch(rootRouteObserverProvider);
              return KonataRootBackGate(
                child: MaterialApp(
                  navigatorKey: navKey,
                  navigatorObservers: [routeObserver],
                  theme: KonataTheme.darkTheme(),
                  home: Scaffold(
                    body: Builder(
                      builder: (ctx) => TextButton(
                        onPressed: () {
                          Navigator.of(ctx).push(
                            MaterialPageRoute<void>(
                              builder: (_) =>
                                  const Scaffold(body: Text('底层详情页内容')),
                            ),
                          );
                        },
                        child: const Text('打开详情'),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 推入模拟详情子路由，再展开全屏沉浸音频标志。
      await tester.tap(find.text('打开详情'));
      await tester.pumpAndSettle();
      expect(find.text('底层详情页内容'), findsOneWidget);

      container.read(immersiveAudioExpandedProvider.notifier).state = true;
      await tester.pump();

      // 系统返回应优先收起全屏音频层，底层详情页必须保持完整存活。
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(container.read(immersiveAudioExpandedProvider), isFalse);
      expect(find.text('底层详情页内容'), findsOneWidget);

      // 当顶层存在根级模态弹窗时，返回键应先关闭弹窗而不误关全屏音频。
      container.read(immersiveAudioExpandedProvider.notifier).state = true;
      await tester.pump();
      final nav = container.read(rootNavigatorKeyProvider).currentState!;
      unawaited(
        showDialog<void>(
          context: nav.context,
          builder: (_) => const AlertDialog(content: Text('顶层确认弹窗')),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('顶层确认弹窗'), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('顶层确认弹窗'), findsNothing);
      expect(container.read(immersiveAudioExpandedProvider), isTrue);
      expect(find.text('底层详情页内容'), findsOneWidget);
    });

    testWidgets('窄屏展开搜索栏后按系统返回键先收起搜索栏且不退出页面', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      var lastQuery = '初始';

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: KonataTheme.darkTheme(),
            home: Scaffold(
              body: AdaptiveActionHeader(
                title: '媒体库',
                searchQuery: '',
                onSearchChanged: (v) => lastQuery = v,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.search_rounded));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('adaptive_header_search_back')),
        findsOneWidget,
      );

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('adaptive_header_search_back')),
        findsNothing,
      );
      expect(find.text('媒体库'), findsOneWidget);
      expect(lastQuery, isEmpty);
    });

    testWidgets('ImmersiveCoverWithReflection 四侧外扩倒影遮罩并使用 decal 模糊防分数屏边缘亮线', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1220, 2712);
      tester.view.devicePixelRatio = 3.25;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            tmdbImageLoaderProvider.overrideWithValue(
              (_, {imageSize, targetWidth}) async => _kOnePixelPng,
            ),
          ],
          child: MaterialApp(
            theme: KonataTheme.darkTheme(),
            home: const Scaffold(
              body: Center(
                child: ImmersiveCoverWithReflection(
                  cover: EmptyAudioCover(),
                  maxCoverSize: 340,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final reflectionFinder = find.byKey(
        const ValueKey('immersive_cover_reflection'),
      );
      expect(reflectionFinder, findsOneWidget);

      final positioned = tester.widget<Positioned>(
        find.descendant(
          of: reflectionFinder,
          matching: find.byType(Positioned),
        ),
      );
      const bleed = KonataPlaybackTokens.albumReflectionMaskBleed;
      expect(positioned.left, equals(-bleed));
      expect(positioned.top, equals(-bleed));
      expect(positioned.width, closeTo(340.0 + bleed * 2, 0.5));
      expect(positioned.height, closeTo(340.0 + bleed * 2, 0.5));

      final filtered = tester.widget<ImageFiltered>(
        find.descendant(
          of: reflectionFinder,
          matching: find.byType(ImageFiltered),
        ),
      );
      expect(
        filtered.imageFilter,
        equals(
          ui.ImageFilter.blur(
            sigmaX: KonataPlaybackTokens.albumReflectionBlurSigma,
            sigmaY: KonataPlaybackTokens.albumReflectionBlurSigma,
            tileMode: ui.TileMode.decal,
          ),
        ),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('WorkArtworkPickerDialog 候选封面加载中仅展示加载提示而不与空态文案冲突', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(420, 860);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      final pending = Completer<WorkArtworkOptions>();
      const work = Work(
        id: 'w_pending',
        title: '16bit 感动',
        tmdbId: 210001,
        scrapeStatus: ScrapeStatus.matched,
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            tmdbImageLoaderProvider.overrideWithValue(
              (_, {imageSize, targetWidth}) async => _kOnePixelPng,
            ),
            workManagementProvider.overrideWith(
              (ref) => _PendingArtworkActions(ref, pending),
            ),
          ],
          child: MaterialApp(
            theme: KonataTheme.darkTheme(),
            home: const Scaffold(
              body: WorkArtworkPickerDialog(
                work: work,
                kind: WorkArtworkKind.poster,
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('正在获取在线候选封面...'), findsOneWidget);
      expect(find.text('暂无可用候选封面'), findsNothing);

      pending.complete(const WorkArtworkOptions());
      await tester.pumpAndSettle();
      expect(find.text('暂无可用候选封面'), findsOneWidget);
    });

    testWidgets('SourceEditorDialog 在 Android 端本地目录输入框展示 Android 路径示例', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      tester.view.physicalSize = const Size(420, 860);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: KonataTheme.darkTheme(),
            home: Scaffold(
              body: SourceEditorDialog(
                onSave: (_, _, {clearPassword = false}) async {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final fields = tester
          .widgetList<KonataSoftTextField>(find.byType(KonataSoftTextField))
          .map((w) => w.hintText)
          .toList();
      expect(fields, contains('/storage/emulated/0/Anime'));
      expect(fields, isNot(contains(r'D:\Anime')));
    });

    testWidgets('ScanLightboxDialog 手机窄屏顶栏精简为页码计数以防截断', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      tester.view.physicalSize = const Size(375, 812);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      final tempDir = await tester.runAsync(
        () => Directory.systemTemp.createTemp('konata_lightbox_compact_'),
      );
      addTearDown(() async {
        if (tempDir != null && await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      const source = MediaSource(
        id: 'src_1',
        kind: MediaSourceKind.webdav,
        label: '测试源',
        location: 'https://example.invalid/dav',
      );
      const work = Work(
        id: 'w_scan',
        title: '扫图测试',
        scrapeStatus: ScrapeStatus.matched,
      );
      const v1 = MediaVariant(
        id: 's1',
        workId: 'w_scan',
        sourceId: 'src_1',
        relativePath: 'VeryLongSeriesName/Scans/Vol.1/Booklet/001.jpg',
        fileName: '001.jpg',
        fileSize: 1024,
        assetKind: AssetKind.scanGallery,
      );
      const v2 = MediaVariant(
        id: 's2',
        workId: 'w_scan',
        sourceId: 'src_1',
        relativePath: 'VeryLongSeriesName/Scans/Vol.1/Booklet/002.jpg',
        fileName: '002.jpg',
        fileSize: 1024,
        assetKind: AssetKind.scanGallery,
      );
      const bundle = WorkDetailBundle(
        work: work,
        episodes: [],
        variants: [v1, v2],
        scanVariants: [v1, v2],
        sourcesById: {'src_1': source},
        latestPlayback: null,
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            photosStorageProvider.overrideWithValue(
              PhotosStorage(overrideRoot: tempDir),
            ),
            scanLightboxLoaderProvider.overrideWithValue(
              _MemoryScanLightboxLoader(),
            ),
          ],
          child: MaterialApp(
            theme: KonataTheme.darkTheme(),
            home: const Scaffold(
              body: ScanLightboxDialog(bundle: bundle, initialVariant: v1),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('1 / 2'), findsOneWidget);
      expect(find.textContaining('VeryLongSeriesName'), findsNothing);
    });

    testWidgets('LibraryPage 手机端展开搜索栏后按系统返回键优先收起搜索栏且不退出页面', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            filteredLibraryItemsProvider.overrideWithValue(
              const AsyncValue.data(<WorkLibraryItem>[]),
            ),
            worksCountProvider.overrideWith((ref) => 0),
            needsReviewItemsProvider.overrideWithValue(
              const AsyncValue.data(<WorkLibraryItem>[]),
            ),
            hiddenWorksProvider.overrideWith((ref) => const <Work>[]),
            tmdbImageLoaderProvider.overrideWithValue(
              (_, {imageSize, targetWidth}) async => _kOnePixelPng,
            ),
          ],
          child: MaterialApp(
            theme: KonataTheme.darkTheme(),
            home: const Scaffold(body: LibraryPage()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.search_rounded));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('library_header_search_row')),
        findsOneWidget,
      );

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('library_header_search_row')),
        findsNothing,
      );
      expect(find.text('全部作品'), findsOneWidget);
    });

    test('KonataSystemFilePicker 在 Android 端将 FileType.custom 退化为 FileType.any 避免 .konata/.ass 不可见', () async {
      FileType? androidType;
      List<String>? androidExts = const <String>['sentinel'];
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        final androidPicker = KonataSystemFilePicker(
          useWindowsNativeBridge: false,
          pickFilesImpl: ({
            dialogTitle,
            initialDirectory,
            type = FileType.any,
            allowedExtensions,
            windowsOptions = const WindowsOptions(),
          }) async {
            androidType = type;
            androidExts = allowedExtensions;
            return const <PlatformFile>[];
          },
        );
        await androidPicker.pickFiles(
          dialogTitle: '选择要恢复的 .konata 备份文件',
          type: FileType.custom,
          allowedExtensions: KonataBackupService.backupFileExtensions,
          allowMultiple: false,
        );
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }

      expect(androidType, equals(FileType.any));
      expect(androidExts, isNull);

      // Windows 端保持 FileType.custom 精确扩展名过滤不变。
      final winFilter = KonataSystemFilePicker.resolvePlatformPickerFilter(
        isAndroid: false,
        type: FileType.custom,
        allowedExtensions: KonataBackupService.backupFileExtensions,
      );
      expect(winFilter.type, equals(FileType.custom));
      expect(
        winFilter.allowedExtensions,
        equals(KonataBackupService.backupFileExtensions),
      );

      // 选后扩展名校验兼容大小写、.konata/.json 与外挂字幕，并拦截误选的无关文件。
      expect(
        KonataSystemFilePicker.matchesAllowedExtension(
          'konata_backup_20261124.KONATA',
          KonataBackupService.backupFileExtensions,
          allowNoExtension: true,
        ),
        isTrue,
      );
      expect(
        KonataSystemFilePicker.matchesAllowedExtension(
          'saf_backup_no_ext',
          KonataBackupService.backupFileExtensions,
          allowNoExtension: true,
        ),
        isTrue,
      );
      expect(
        KonataSystemFilePicker.matchesAllowedExtension(
          'movie.mp4',
          KonataBackupService.backupFileExtensions,
          allowNoExtension: true,
        ),
        isFalse,
      );
      expect(
        KonataSystemFilePicker.matchesAllowedExtension(
          'episode01.sc.ASS',
          KonataMediaExtensions.subtitleExtensionsNoDot,
        ),
        isTrue,
      );
      expect(
        KonataSystemFilePicker.matchesAllowedExtension(
          'cover.png',
          KonataMediaExtensions.subtitleExtensionsNoDot,
        ),
        isFalse,
      );
    });
  });
}
