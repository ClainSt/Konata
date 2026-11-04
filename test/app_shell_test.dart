import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ccplayer/core/app_theme.dart';
import 'package:ccplayer/core/catalog.dart';
import 'package:ccplayer/main.dart';
import 'package:ccplayer/ui/nipaplay_style.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
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
      'open-settings',
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
    expect(find.widgetWithText(TextButton, '添加媒体源'), findsOneWidget);
    expect(find.text('添加媒体源'), findsOneWidget);
    final addButton = find.widgetWithText(TextButton, '添加媒体源');
    final addIcon = find.descendant(of: addButton, matching: find.byType(Icon));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(0, 0));
    await mouse.moveTo(tester.getCenter(addButton));
    await tester.pumpAndSettle();
    expect(IconTheme.of(tester.element(addIcon)).color, NipaPlayStyle.accent);
    await mouse.moveTo(const Offset(0, 0));
    await tester.pumpAndSettle();
    expect(
      IconTheme.of(tester.element(addIcon)).color,
      isNot(NipaPlayStyle.accent),
    );
    await mouse.removePointer();
    await tester.tap(find.text('添加媒体源'));
    await tester.pumpAndSettle();
    expect(find.text('本地媒体'), findsOneWidget);
    expect(find.text('网络媒体'), findsOneWidget);
    expect(find.text('SMB'), findsOneWidget);
    await tester.tap(find.text('WebDAV'));
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
    await tester.tap(find.text('本地文件夹'));
    await tester.pumpAndSettle();
    expect(fields, findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加媒体源'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('SMB'));
    await tester.pumpAndSettle();
    expect(find.text('添加 SMB 共享'), findsOneWidget);
    expect(fields, findsNWidgets(4));
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('toggle-theme')));
    await tester.pumpAndSettle();
    expect(AppTheme.instance.mode, ThemeMode.dark);
    expect(find.widgetWithText(TextButton, '设置'), findsNothing);
    expect(
      tester.getCenter(find.byKey(const ValueKey('open-settings'))).dx,
      greaterThan(
        tester.getCenter(find.byKey(const ValueKey('toggle-theme'))).dx,
      ),
    );
    await tester.tap(find.byTooltip('设置'));
    await tester.pumpAndSettle();
    expect(find.text('主题模式'), findsOneWidget);
    for (final category in ['外观设置', '刮削设置', '关于']) {
      await tester.tap(find.text(category).first);
      await tester.pumpAndSettle();
      for (var index = 0; index < 3; index++) {
        final tile = find.byKey(ValueKey('settings-category-$index'));
        expect(tester.getSize(tile).height, 64);
        final label = tester.widget<Text>(
          find.descendant(of: tile, matching: find.byType(Text)),
        );
        expect(label.maxLines, 1);
      }
    }
    await tester.tap(find.text('外观设置').first);
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
    final firstOption = find.widgetWithText(PopupMenuItem<ThemeMode>, '日间模式');
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
      tester
          .getTopLeft(find.widgetWithText(PopupMenuItem<ThemeMode>, '日间模式'))
          .dy,
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
    await tester.tap(find.text('刮削设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('TMDB API 设置'));
    await tester.pumpAndSettle();
    expect(find.text('TMDB 认证方式'), findsOneWidget);
    expect(tester.takeException(), isNull, reason: 'TMDB dialog');
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('关于'));
    await tester.pumpAndSettle();
    expect(find.text('版本 1.0.0'), findsOneWidget);
    expect(find.text('ClainSt/CCPlayer'), findsOneWidget);
    expect(find.text('https://github.com/ClainSt/CCPlayer'), findsOneWidget);
    expect(find.text('开源许可'), findsNothing);
    expect(tester.takeException(), isNull, reason: 'about settings');
    await tester.binding.setSurfaceSize(const Size(400, 700));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('关闭设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('nav-library')));
    await tester.pumpAndSettle();
    expect(libraryDestination.value, isFalse);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, '搜索动画'), findsOneWidget);
    expect(tester.takeException(), isNull, reason: 'compact library toolbar');
    await tester.pumpWidget(const SizedBox());
  });
}
