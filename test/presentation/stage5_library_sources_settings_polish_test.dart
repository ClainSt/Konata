import 'dart:io';
import 'dart:ui' show PointerDeviceKind;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ccplayer/application/playback/playback_preferences_provider.dart';
import 'package:ccplayer/application/providers/desktop_external_tools_providers.dart';
import 'package:ccplayer/application/providers/library_providers.dart';
import 'package:ccplayer/application/providers/theme_providers.dart';
import 'package:ccplayer/domain/models/external_player_config.dart';
import 'package:ccplayer/domain/models/work.dart';
import 'package:ccplayer/infrastructure/storage/storage_root_provider.dart';
import 'package:ccplayer/presentation/library/poster_card.dart';
import 'package:ccplayer/presentation/settings/settings_appearance_panel.dart';
import 'package:ccplayer/presentation/settings/settings_external_tools_panel.dart';
import 'package:ccplayer/presentation/settings/settings_players_panel.dart';
import 'package:ccplayer/presentation/theme/konata_theme.dart';
import 'package:ccplayer/presentation/widgets/design_system/bangumi_score_wordmark_badge.dart';
import 'package:ccplayer/presentation/widgets/design_system/konata_system_file_picker.dart';

final class _MemoryPlatformFile extends PlatformFile {
  _MemoryPlatformFile({required this.name, required Uint8List content})
    : _bytes = content;

  @override
  final String name;

  final Uint8List _bytes;

  @override
  Uri get uri => Uri.parse('content://konata.test/shaders/$name');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  @override
  int? lengthSync() => _bytes.length;

  @override
  Future<int?> length() async => _bytes.length;

  @override
  Future<Uint8List> readAsBytes() async => _bytes;

  @override
  Stream<Uint8List> readAsByteStream() => Stream<Uint8List>.value(_bytes);
}

final Uint8List _sample1x1Png = Uint8List.fromList(const <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0xF8, 0xCF, 0xC0, 0xF0,
  0x1F, 0x00, 0x05, 0x00, 0x01, 0xFF, 0x89, 0x99, 0x3D, 0x1D, 0x00, 0x00,
  0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

Widget _wrapApp(
  Widget child, {
  List<Override> overrides = const [],
  ThemeMode themeMode = ThemeMode.dark,
}) {
  return ProviderScope(
    overrides: overrides,
    child: MaterialApp(
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: KonataTheme.lightTheme(),
      darkTheme: KonataTheme.darkTheme(),
      themeMode: themeMode,
      home: Scaffold(body: child),
    ),
  );
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(const {});
  });

  group('阶段 5 · 海报墙左下 Bangumi 粉色微标、外观流光画布开关与外部调用精简验收', () {
    testWidgets('桌面端悬停 PosterCard 在左下呈现粉色矢量 Bangumi 评分微标，无快捷播放圆钮', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      const item = WorkLibraryItem(
        work: Work(
          id: 'w_bgm_1',
          title: '凉宫春日的忧郁',
          year: 2006,
          bangumiScore: 6.7,
          posterPath: '/haruhi.jpg',
          scrapeStatus: ScrapeStatus.matched,
        ),
        variants: [],
        episodeCount: 14,
        releaseGroups: ['VCB-Studio'],
      );

      await tester.pumpWidget(
        _wrapApp(
          Center(
            child: SizedBox(
              width: 180,
              height: 310,
              child: PosterCard(
                item: item,
                imageLoader: (_, {targetWidth, imageSize}) async =>
                    _sample1x1Png,
                onTap: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final badgeFinder = find.byKey(
        const ValueKey('poster_bangumi_badge_w_bgm_1'),
      );
      expect(badgeFinder, findsOneWidget);
      expect(find.byType(BangumiScoreWordmarkBadge), findsOneWidget);
      expect(find.text('6.7'), findsOneWidget);
      // 悬停前保持透明隐藏
      final opacityBefore = tester.widget<AnimatedOpacity>(
        find.ancestor(
          of: badgeFinder,
          matching: find.byType(AnimatedOpacity),
        ).first,
      );
      expect(opacityBefore.opacity, 0.0);

      // 模拟桌面鼠标悬停卡片 -> 微标淡入并位于海报左下方，无快捷播放按钮
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await gesture.moveTo(tester.getCenter(find.byType(PosterCard)));
      await tester.pumpAndSettle();

      final opacityAfter = tester.widget<AnimatedOpacity>(
        find.ancestor(
          of: badgeFinder,
          matching: find.byType(AnimatedOpacity),
        ).first,
      );
      expect(opacityAfter.opacity, 1.0);
      final cardRect = tester.getRect(find.byType(PosterCard));
      final badgeRect = tester.getRect(badgeFinder);
      expect(badgeRect.left - cardRect.left, lessThan(24.0));
      expect(badgeRect.center.dy, greaterThan(cardRect.center.dy));
      expect(find.byIcon(Icons.play_arrow_rounded), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('外观面板仅在 Windows 展示流光氛围画布开关且外部调用面板已彻底移除外部图片查看器', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      tester.view.physicalSize = const Size(900, 720);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final container = ProviderContainer();
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            locale: const Locale('zh', 'CN'),
            supportedLocales: const [Locale('zh', 'CN')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            theme: KonataTheme.darkTheme(),
            home: const Scaffold(
              body: SingleChildScrollView(
                padding: EdgeInsets.all(20),
                child: SettingsAppearancePanel(),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final switchFinder = find.byKey(
        const ValueKey('settings_ambient_canvas_switch'),
      );
      expect(switchFinder, findsOneWidget);
      expect(container.read(ambientCanvasEnabledProvider), isFalse);

      await tester.tap(switchFinder);
      await tester.pumpAndSettle();
      expect(container.read(ambientCanvasEnabledProvider), isTrue);

      // Android 端自动过滤桌面专属「流光氛围画布」与「窗口材质」卡片
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            locale: const Locale('zh', 'CN'),
            supportedLocales: const [Locale('zh', 'CN')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            theme: KonataTheme.darkTheme(),
            home: const Scaffold(
              body: SingleChildScrollView(
                padding: EdgeInsets.all(20),
                child: SettingsAppearancePanel(),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(switchFinder, findsNothing);

      // 校验桌面端外部调用面板已移除外部图片查看器输入框，仅保留视频与音频外部程序
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      await tester.pumpWidget(
        _wrapApp(
          const SingleChildScrollView(
            padding: EdgeInsets.all(20),
            child: SettingsExternalToolsPanel(),
          ),
          overrides: [
            desktopExternalPlayersProvider.overrideWith(
              (_) async => const <ExternalPlayerConfig>[],
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('外部音频播放器'), findsWidgets);
      expect(find.textContaining('外部图片查看器'), findsNothing);
      expect(find.textContaining('Honeyview'), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets(
      'libsoxr 精度仅在 Windows 展示并在 Android 隐藏；Android 完整支持多选导入、启用与长按删除 GLSL 着色器',
      (tester) async {
        final tempRoot = Directory.systemTemp.createTempSync(
          'konata_android_shaders_',
        );
        addTearDown(() {
          debugDefaultTargetPlatformOverride = null;
          if (tempRoot.existsSync()) {
            tempRoot.deleteSync(recursive: true);
          }
        });
        tester.view.physicalSize = const Size(900, 1200);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final fakePicker = KonataSystemFilePicker(
          pickFilesImpl: ({
            dialogTitle,
            initialDirectory,
            type = FileType.any,
            allowedExtensions,
            windowsOptions = const WindowsOptions(),
          }) async => [
            _MemoryPlatformFile(
              name: 'Anime4K:Restore_M.glsl',
              content: Uint8List.fromList('// anime4k glsl\n'.codeUnits),
            ),
            _MemoryPlatformFile(
              name: 'readme.txt',
              content: Uint8List.fromList('hello'.codeUnits),
            ),
          ],
        );

        // 1. Windows 端：显示 libsoxr 下拉框与「打开目录」，不显示 Android 专属「导入着色器」
        debugDefaultTargetPlatformOverride = TargetPlatform.windows;
        await tester.pumpWidget(
          _wrapApp(
            const SingleChildScrollView(
              padding: EdgeInsets.all(20),
              child: SettingsPlayersPanel(),
            ),
            overrides: [
              storageRootProvider.overrideWithValue(
                StorageRootService(overrideRoot: tempRoot),
              ),
              konataSystemFilePickerProvider.overrideWithValue(fakePicker),
            ],
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('libsoxr 音频重采样精度'), findsOneWidget);
        expect(find.text('打开目录'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('settings_import_shader_button')),
          findsNothing,
        );

        // 2. Android 端：隐藏无效的 libsoxr 精度选项，呈现「导入着色器」并完成导入 -> 激活 -> 长按删除闭环
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        debugDefaultTargetPlatformOverride = TargetPlatform.android;

        final container = ProviderContainer(
          overrides: [
            storageRootProvider.overrideWithValue(
              StorageRootService(overrideRoot: tempRoot),
            ),
            konataSystemFilePickerProvider.overrideWithValue(fakePicker),
          ],
        );
        addTearDown(container.dispose);

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              locale: const Locale('zh', 'CN'),
              supportedLocales: const [Locale('zh', 'CN')],
              localizationsDelegates: GlobalMaterialLocalizations.delegates,
              theme: KonataTheme.darkTheme(),
              home: const Scaffold(
                body: SingleChildScrollView(
                  padding: EdgeInsets.all(20),
                  child: SettingsPlayersPanel(),
                ),
              ),
            ),
          ),
        );
        Future<void> flushRealIo() async {
          for (var i = 0; i < 20; i++) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)),
            );
            await tester.pump();
          }
          await tester.pumpAndSettle();
        }

        await flushRealIo();

        expect(find.text('libsoxr 音频重采样精度'), findsNothing);
        expect(find.text('打开目录'), findsNothing);
        final importBtn = find.byKey(
          const ValueKey('settings_import_shader_button'),
        );
        expect(importBtn, findsOneWidget);

        await tester.ensureVisible(importBtn);
        await tester.pumpAndSettle();
        await tester.tap(importBtn);
        await tester.pump();
        await flushRealIo();

        // 非法 .txt 已过滤，冒号已清洗为下划线并落盘至 userdata/shaders/
        const sanitizedName = 'Anime4K_Restore_M.glsl';
        final importedFile = File(
          p.join(tempRoot.path, 'userdata', 'shaders', sanitizedName),
        );
        expect(importedFile.existsSync(), isTrue);
        expect(find.text(sanitizedName), findsOneWidget);
        expect(find.text('readme.txt'), findsNothing);

        // 单击胶囊启用着色器
        await tester.ensureVisible(find.text(sanitizedName));
        await tester.pumpAndSettle();
        await tester.tap(find.text(sanitizedName));
        await tester.pumpAndSettle();
        expect(
          container
              .read(playbackPreferencesProvider)
              .qualityConfig
              .activeShaderPaths,
          contains(importedFile.path),
        );

        // 长按胶囊弹出毛玻璃菜单并删除着色器文件（同步移出激活列表）
        await tester.longPress(find.text(sanitizedName));
        await tester.pumpAndSettle();
        final deleteMenuItem = find.byKey(const ValueKey('shader_menu_delete'));
        expect(deleteMenuItem, findsOneWidget);
        await tester.tap(deleteMenuItem);
        await tester.pump();
        await flushRealIo();

        expect(importedFile.existsSync(), isFalse);
        expect(find.text(sanitizedName), findsNothing);
        expect(
          container
              .read(playbackPreferencesProvider)
              .qualityConfig
              .activeShaderPaths,
          isNot(contains(importedFile.path)),
        );

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        debugDefaultTargetPlatformOverride = null;
      },
    );
  });
}
