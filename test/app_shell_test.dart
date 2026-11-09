import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ccplayer/core/app_theme.dart';
import 'package:ccplayer/core/catalog.dart';
import 'package:ccplayer/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final mobile in [true, false]) {
    testWidgets(
      'rapid navigation removes source ghosts and animates the incoming page, mobile=$mobile',
      (tester) async {
        final previousSources = Catalog.instance.sources;
        final previousWorks = Catalog.instance.works;
        Catalog.instance.sources = [
          {
            'id': 'rapid',
            'kind': 'local',
            'label': 'rapid-switch-source',
            'location': '/fixture',
          },
        ];
        Catalog.instance.works = [];
        await tester.binding.setSurfaceSize(
          mobile ? const Size(390, 780) : const Size(1200, 800),
        );
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox());
          Catalog.instance.sources = previousSources;
          Catalog.instance.works = previousWorks;
          libraryDestination.value = false;
          await tester.binding.setSurfaceSize(null);
        });
        await tester.pumpWidget(CCPlayer(mobile: mobile));
        await tester.pumpAndSettle();
        for (var i = 0; i < 8; i++) {
          await tester.tap(find.byKey(const ValueKey('nav-sources')));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 65));
          expect(find.text('rapid-switch-source'), findsOneWidget);
          await tester.tap(find.byKey(const ValueKey('nav-library')));
          await tester.pump();
          expect(
            find.text('rapid-switch-source'),
            findsNothing,
            reason: 'No outgoing directory may paint through poster gaps',
          );
          final fade = find.descendant(
            of: find.byKey(const ValueKey('library-source-switcher')),
            matching: find.byType(FadeTransition),
          );
          expect(fade, findsOneWidget);
          expect(tester.widget<FadeTransition>(fade).opacity.value, 0);
          await tester.pump(const Duration(milliseconds: 65));
          expect(
            tester.widget<FadeTransition>(fade).opacity.value,
            inExclusiveRange(0.0, 1.0),
          );
        }
        await tester.tap(find.byKey(const ValueKey('nav-settings')));
        await tester.pump();
        expect(
          find.byKey(const ValueKey('library-source-switcher')),
          findsNothing,
        );
        final pageFade = find.descendant(
          of: find.byKey(const ValueKey('main-section-switcher')),
          matching: find.byType(FadeTransition),
        );
        expect(tester.widget<FadeTransition>(pageFade.first).opacity.value, 0);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(tester.binding.transientCallbackCount, 0);
      },
    );
  }
  testWidgets(
    'source card keeps five name characters and all actions at minimum window size',
    (tester) async {
      final previous = Catalog.instance.sources;
      Catalog.instance.sources = [
        {
          'id': 'layout-source',
          'kind': 'webdav',
          'label': '光鸭动画收藏媒体源',
          'location': 'https://example.invalid/a/very/long/path',
        },
      ];
      libraryDestination.value = true;
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        Catalog.instance.sources = previous;
        libraryDestination.value = false;
        await tester.binding.setSurfaceSize(null);
      });
      await tester.binding.setSurfaceSize(const Size(640, 480));
      await tester.pumpWidget(const CCPlayer());
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('konata-brand-icon')), findsOneWidget);
      final label = find.text('光鸭动画收藏媒体源');
      final widget = tester.widget<Text>(label);
      final painter = TextPainter(
        text: TextSpan(text: '光鸭动画收', style: widget.style),
        textDirection: TextDirection.ltr,
      )..layout();
      expect(tester.getSize(label).width, greaterThanOrEqualTo(painter.width));
      painter.dispose();
      for (final tooltip in ['编辑媒体源', '浏览云盘或本地目录并选取刮削文件夹', '移除']) {
        final rect = tester.getRect(find.byTooltip(tooltip));
        expect(rect.right, lessThanOrEqualTo(640));
        expect(rect.bottom, lessThanOrEqualTo(480));
        expect(rect.width, greaterThanOrEqualTo(40));
      }
      expect(tester.takeException(), isNull);
    },
  );
  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized()
        .platformDispatcher
        .localesTestValue = const [
      Locale('zh', 'CN'),
    ];
    SharedPreferences.setMockInitialValues({});
    await AppTheme.instance.load();
    libraryDestination.value = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('window_manager'),
          (call) async => false,
        );
  });

  test(
    'theme choice is restored and unknown values follow the system',
    () async {
      final first = AppTheme();
      await first.setMode(ThemeMode.dark);
      final restored = AppTheme();
      await restored.load();
      expect(restored.mode, ThemeMode.dark);
      await restored.setMode(ThemeMode.system);
      final system = AppTheme();
      await system.load();
      expect(system.mode, ThemeMode.system);
      SharedPreferences.setMockInitialValues({'theme_mode': 'invalid'});
      await restored.load();
      expect(restored.mode, ThemeMode.system);
    },
  );

  testWidgets('top navigation, theme shortcut and categorized settings work', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1100, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const CCPlayer());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: 'initial shell');
    expect(find.byKey(const ValueKey('nav-library')), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const ValueKey('nav-library'))).width,
      tester.getSize(find.byKey(const ValueKey('nav-sources'))).width,
    );
    final controls = [
      'toggle-theme',
      'window-最小化',
      'window-最大化',
      'window-关闭',
    ].map((key) => tester.getCenter(find.byKey(ValueKey(key))).dx).toList();
    for (var i = 1; i < controls.length; i++) {
      expect(controls[i] - controls[i - 1], closeTo(48, .1));
    }
    await tester.tap(find.byKey(const ValueKey('nav-sources')));
    await tester.pumpAndSettle();
    expect(libraryDestination.value, isTrue);
    expect(find.text('0 个媒体源'), findsOneWidget);
    expect(find.byTooltip('扫描已选范围'), findsNothing);
    expect(find.byTooltip('刮削 TMDB / Bangumi 元数据（不重新扫描视频）'), findsNothing);
    expect(find.widgetWithText(FilledButton, '添加媒体源'), findsOneWidget);
    expect(find.text('添加媒体源'), findsOneWidget);
    await tester.tap(find.text('添加媒体源'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('source-type-selector')));
    await tester.pumpAndSettle();
    final sourceField = tester.getRect(
      find.byKey(const ValueKey('source-type-selector')),
    );
    final sourceMenu = tester.getRect(
      find
          .ancestor(
            of: find.text('WebDAV').last,
            matching: find.byType(Material),
          )
          .first,
    );
    expect(sourceMenu.left, closeTo(sourceField.left, 1));
    expect(sourceMenu.width, closeTo(sourceField.width, 1));
    await tester.tap(find.text('WebDAV').last);
    await tester.pumpAndSettle();
    final fields = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );
    expect(fields, findsNWidgets(4));
    for (var i = 1; i < 4; i++) {
      expect(
        tester.getTopLeft(fields.at(i)).dy -
            tester.getBottomLeft(fields.at(i - 1)).dy,
        greaterThanOrEqualTo(16),
      );
    }
    await tester.tap(find.byTooltip('显示密码'));
    await tester.pump();
    expect(find.byTooltip('隐藏密码'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加媒体源'));
    await tester.pumpAndSettle();
    expect(fields, findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加媒体源'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('source-type-selector')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('SMB').last);
    await tester.pumpAndSettle();
    expect(find.text('添加 SMB 共享'), findsOneWidget);
    expect(fields, findsNWidgets(4));
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('toggle-theme')));
    await tester.pumpAndSettle();
    expect(AppTheme.instance.mode, ThemeMode.dark);
    await tester.tap(find.byKey(const ValueKey('nav-settings')));
    await tester.pumpAndSettle();
    expect(find.text('主题模式'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('settings-category-3')));
    await tester.pumpAndSettle();
    // History remains available in the main navigation, not duplicated here.
    expect(find.text('查看续播位置、管理本地已看状态'), findsNothing);
    expect(
      find.byKey(const ValueKey('library-backup-inspect')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('settings-category-0')));
    await tester.pumpAndSettle();
    for (final category in ['外观', '刮削服务', '关于']) {
      expect(find.text(category), findsOneWidget);
    }
    await tester.tap(find.text('外观').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('theme-accent-lightBlue')));
    await tester.pumpAndSettle();
    expect(
      Theme.of(tester.element(find.text('主题模式'))).colorScheme.primary,
      ThemeAccent.lightBlue.color,
    );
    final restoredAccent = AppTheme();
    await restoredAccent.load();
    expect(restoredAccent.accent, ThemeAccent.lightBlue);
    await tester.tap(find.byKey(const ValueKey('settings-theme-mode')));
    await tester.pumpAndSettle();
    final firstOption = find.widgetWithText(MenuItemButton, '日间模式');
    final selector = find.byKey(const ValueKey('settings-theme-mode'));
    expect(
      tester.getSize(firstOption).width,
      closeTo(tester.getSize(selector).width, 2),
    );
    expect(
      tester
          .getTopLeft(
            find.descendant(of: firstOption, matching: find.text('日间模式')),
          )
          .dx,
      closeTo(
        tester
            .getTopLeft(
              find.descendant(of: selector, matching: find.byType(Text)),
            )
            .dx,
        1,
      ),
    );
    expect(
      tester.getTopLeft(find.widgetWithText(MenuItemButton, '日间模式')).dy,
      greaterThanOrEqualTo(
        tester
            .getBottomLeft(find.byKey(const ValueKey('settings-theme-mode')))
            .dy,
      ),
    );
    await tester.tap(find.text('跟随系统'));
    await tester.pumpAndSettle();
    expect(AppTheme.instance.mode, ThemeMode.system);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    await tester.pumpAndSettle();
    expect(
      Theme.of(tester.element(find.text('主题模式'))).brightness,
      Brightness.dark,
    );
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    await tester.pumpAndSettle();
    expect(
      Theme.of(tester.element(find.text('主题模式'))).brightness,
      Brightness.light,
    );
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    await tester.tap(find.byKey(const ValueKey('nav-settings')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('刮削服务'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('TMDB API 设置'));
    await tester.pumpAndSettle();
    expect(find.text('TMDB 认证方式'), findsOneWidget);
    expect(tester.takeException(), isNull, reason: 'TMDB dialog');
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('nav-settings')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('关于'));
    await tester.pumpAndSettle();
    expect(find.text('版本 1.0.0'), findsOneWidget);
    expect(find.text('ClainSt/Konata'), findsOneWidget);
    expect(find.text('https://github.com/ClainSt/Konata'), findsOneWidget);
    expect(find.text('开源许可'), findsNothing);
    expect(tester.takeException(), isNull, reason: 'about settings');
    await tester.binding.setSurfaceSize(const Size(400, 700));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const ValueKey('nav-library')));
    await tester.pumpAndSettle();
    expect(libraryDestination.value, isFalse);
    await tester.pumpAndSettle();
    expect(find.text('添加媒体源'), findsNothing);
    expect(find.byKey(const ValueKey('library-search')), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('library-search')),
      '不存在的动画',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('关闭搜索'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('library-search')))
          .controller!
          .text,
      isEmpty,
    );
    expect(tester.takeException(), isNull, reason: 'compact library toolbar');
    await tester.pumpWidget(const SizedBox());
  });
}
