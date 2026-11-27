import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:konata_design_system/konata_design_system.dart';

void main() {
  const safe = EdgeInsets.fromLTRB(0, 24, 0, 20);

  group('三端自适应胶囊与悬浮小窗几何布局', () {
    test('手机矮横屏底部导航独立水平居中且音频圆钮避让导航', () {
      final cramped = AdaptiveCapsuleLayout(
        size: const Size(568, 320),
        safe: safe,
        android: true,
        miniKind: FloatingMiniPlayerKind.audio,
      );
      expect(cramped.shortPhone, isTrue);
      expect(cramped.verticalNavigation, isFalse);
      final miniRect = cramped.floatingMiniWindowRect!;
      expect(cramped.navigationRect.center.dx, closeTo(284.0, 0.5));
      expect(miniRect.overlaps(cramped.navigationRect), isFalse);
    });

    for (final size in const <Size>[
      Size(1024, 700),
      Size(1280, 800),
      Size(800, 1280),
    ]) {
      test('平板双方向左竖悬浮胶囊与视频小窗安全停靠 $size', () {
        final layout = AdaptiveCapsuleLayout(
          size: size,
          safe: safe,
          android: true,
          miniKind: FloatingMiniPlayerKind.video,
        );
        expect(layout.tablet, isTrue);
        expect(layout.verticalNavigation, isTrue);
        expect(
          layout.navigationRect.left,
          safe.left + KonataAdaptiveTokens.tabletNavEdgeGap,
        );
        expect(layout.navigationRect.height, lessThan(size.height));
        expect(
          layout.navigationRect.center.dy,
          closeTo(safe.top + (size.height - safe.vertical) / 2, 0.5),
        );
        final miniRect = layout.floatingMiniWindowRect!;
        expect(miniRect.width / miniRect.height, closeTo(16 / 9, 0.02));
        expect(miniRect.overlaps(layout.navigationRect), isFalse);
      });
    }

    test('手机竖屏视频悬浮小窗避让底栏胶囊且二级页下沉补位', () {
      final normal = AdaptiveCapsuleLayout(
        size: const Size(390, 780),
        safe: safe,
        android: true,
        miniKind: FloatingMiniPlayerKind.video,
      );
      final detail = AdaptiveCapsuleLayout(
        size: normal.size,
        safe: safe,
        android: true,
        navigationVisible: false,
        miniKind: FloatingMiniPlayerKind.video,
      );
      expect(normal.navigationRect.center.dx, closeTo(195.0, 0.5));
      final normalMini = normal.floatingMiniWindowRect!;
      final detailMini = detail.floatingMiniWindowRect!;
      expect(
        normal.navigationRect.top - normalMini.bottom,
        closeTo(KonataPlaybackTokens.floatingMiniNavigationGap, 0.5),
      );
      expect(detailMini.bottom, greaterThan(normalMini.bottom));
      expect(detail.bottomClearance, lessThan(normal.bottomClearance));
    });

    test('桌面宽屏自由停放与移动端侧边吸附规则隔离生效', () {
      final desktop = AdaptiveCapsuleLayout(
        size: const Size(1440, 900),
        safe: safe,
        android: false,
        miniKind: FloatingMiniPlayerKind.video,
        normalizedMiniAnchor: const Offset(0.42, 0.35),
      );
      final desktopRect = desktop.floatingMiniWindowRect!;
      final desktopBounds = desktop.safeBoundsFor(desktopRect.size);
      expect(
        desktopRect.left,
        closeTo(
          desktopBounds.minX + 0.42 * (desktopBounds.maxX - desktopBounds.minX),
          0.5,
        ),
      );
      expect(desktop.leftClearance, 0);
      expect(desktop.bottomClearance, 0);

      final mobile = AdaptiveCapsuleLayout(
        size: const Size(390, 844),
        safe: safe,
        android: true,
        miniKind: FloatingMiniPlayerKind.video,
        normalizedMiniAnchor: const Offset(0.42, 0.35),
      );
      final mobileRect = mobile.floatingMiniWindowRect!;
      final mobileBounds = mobile.safeBoundsFor(mobileRect.size);
      expect(mobileRect.left, closeTo(mobileBounds.minX, 0.5));
    });

    test('视频悬浮小窗按真实片源比例无黑边缩放（4:3 / 16:9 / 2.39:1 / 9:16）', () {
      for (final ratio in const <double>[4 / 3, 16 / 9, 2.39, 9 / 16]) {
        final layout = AdaptiveCapsuleLayout(
          size: const Size(1280, 800),
          safe: safe,
          android: false,
          miniKind: FloatingMiniPlayerKind.video,
          videoAspectRatio: ratio,
        );
        final rect = layout.floatingMiniWindowRect!;
        expect(rect.width / rect.height, closeTo(ratio, 0.02));
      }
    });

    for (final size in const [
      Size(320, 640),
      Size(390, 844),
      Size(844, 390),
      Size(1024, 700),
    ]) {
      test('音频小窗各状态不改变主导航位置 $size', () {
        final baseline = AdaptiveCapsuleLayout(
          size: size,
          safe: safe,
          android: true,
        );
        for (final state in FloatingMiniVisualState.values) {
          for (final side in FloatingMiniEdgeSide.values) {
            for (final anchor in <Offset?>[
              null,
              const Offset(0, 1),
              const Offset(1, 1),
              const Offset(0.4, 0.3),
            ]) {
              final active = AdaptiveCapsuleLayout(
                size: size,
                safe: safe,
                android: true,
                miniKind: FloatingMiniPlayerKind.audio,
                visualState: state,
                edgeSide: side,
                normalizedMiniAnchor: anchor,
              );
              expect(active.navigationRect, baseline.navigationRect);
              final miniRect = active.floatingMiniWindowRect!;
              expect(miniRect.overlaps(active.navigationRect), isFalse);
              expect(
                active.bottomClearance,
                greaterThanOrEqualTo(baseline.bottomClearance),
              );
              if (state == FloatingMiniVisualState.expanded) {
                expect(miniRect.width, greaterThan(miniRect.height));
              }
            }
          }
        }
      });
    }
  });

  group('四视口组件与三端外壳渲染回归', () {
    for (final entry in const <(TargetPlatform, Size, String)>[
      (TargetPlatform.android, Size(390, 780), '窄屏手机竖屏'),
      (TargetPlatform.android, Size(844, 390), '手机横屏'),
      (TargetPlatform.android, Size(1024, 700), '平板横屏'),
      (TargetPlatform.windows, Size(1440, 900), 'Windows 桌面'),
    ]) {
      testWidgets('KonataAdaptiveShell 四视口零溢出与导航形态校验：${entry.$3}', (
        tester,
      ) async {
        debugDefaultTargetPlatformOverride = entry.$1;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);

        tester.view.physicalSize = entry.$2;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        var selected = 0;
        var themeToggles = 0;

        await tester.pumpWidget(
          StatefulBuilder(
            builder: (context, setState) => MaterialApp(
              theme: KonataTheme.darkTheme(),
              home: KonataAdaptiveShell(
                navItems: KonataNavItem.defaults,
                pages: const <Widget>[
                  Center(child: Text('页面_媒体库')),
                  Center(child: Text('页面_媒体源')),
                  Center(child: Text('页面_播放记录')),
                  Center(child: Text('页面_设置')),
                ],
                selectedIndex: selected,
                onSelectedIndexChanged: (idx) => setState(() => selected = idx),
                onToggleTheme: () => themeToggles++,
                onSearchChanged: (_) {},
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(find.text('页面_媒体库'), findsOneWidget);

        if (entry.$1 == TargetPlatform.windows) {
          expect(find.byType(KonataTopNavBar), findsOneWidget);
          expect(find.byType(CapsuleNavigation), findsNothing);
          await tester.tap(find.text('设置'));
          await tester.pumpAndSettle();
          expect(selected, 3);
          expect(find.text('页面_设置'), findsOneWidget);

          await tester.tap(find.byTooltip('浅色模式'));
          await tester.pump();
          expect(themeToggles, 1);
        } else {
          expect(find.byType(CapsuleNavigation), findsOneWidget);
          expect(find.byType(KonataTopNavBar), findsNothing);
          final capsule = tester.widget<CapsuleNavigation>(
            find.byType(CapsuleNavigation),
          );
          final expectVertical = entry.$2.shortestSide >= 600;
          expect(capsule.vertical, expectVertical);

          for (final element
              in find.byType(KonataCapsuleIconButton).evaluate()) {
            final box = element.renderObject! as RenderBox;
            expect(box.size.width, greaterThanOrEqualTo(48));
            expect(box.size.height, greaterThanOrEqualTo(48));
          }

          await tester.tap(find.byType(KonataCapsuleIconButton).last);
          await tester.pumpAndSettle();
          expect(selected, 3);
          expect(find.text('页面_设置'), findsOneWidget);
        }
      });
    }

    testWidgets('手机实际导航在音频小窗状态变化期间始终居中', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      var kind = FloatingMiniPlayerKind.none;
      var visualState = FloatingMiniVisualState.collapsed;
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          theme: KonataTheme.darkTheme(),
          home: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return KonataAdaptiveShell(
                navItems: KonataNavItem.defaults,
                pages: const [SizedBox(), SizedBox(), SizedBox(), SizedBox()],
                selectedIndex: 0,
                onSelectedIndexChanged: (_) {},
                onToggleTheme: () {},
                miniKind: kind,
                visualState: visualState,
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      final nav = find.byType(CapsuleNavigation);
      final baseline = tester.getRect(nav);
      expect(baseline.center.dx, 195);
      for (final state in FloatingMiniVisualState.values) {
        update(() {
          kind = FloatingMiniPlayerKind.audio;
          visualState = state;
        });
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 80));
        expect(tester.getRect(nav), baseline);
        await tester.pumpAndSettle();
        expect(tester.getRect(nav), baseline);
      }
      update(() => kind = FloatingMiniPlayerKind.none);
      await tester.pumpAndSettle();
      expect(tester.getRect(nav), baseline);
      expect(tester.takeException(), isNull);
    });

    testWidgets('AdaptiveActionHeader 窄屏折叠搜索图标、点击原地展开与清除', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      var query = '';
      final focus = FocusNode();
      addTearDown(focus.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: KonataTheme.darkTheme(),
          home: Scaffold(
            body: AdaptiveActionHeader(
              title: '全部作品',
              searchQuery: query,
              searchFocusNode: focus,
              onSearchChanged: (value) => query = value,
            ),
          ),
        ),
      );

      expect(find.byType(TextField), findsNothing);
      await tester.tap(find.byTooltip('搜索'));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsOneWidget);

      await tester.enterText(find.byType(TextField), '轻音');
      await tester.pump();
      expect(query, '轻音');

      await tester.tap(find.byTooltip('清除搜索'));
      await tester.pumpAndSettle();
      expect(query, '');

      await tester.tap(find.byTooltip('收起搜索'));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
    });

    testWidgets('KonataTopNavBar 支持流畅滑块、防抖搜索与 Escape 清空收起', (tester) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final focus = FocusNode();
      addTearDown(focus.dispose);
      var expanded = false;
      var dispatched = '';

      await tester.pumpWidget(
        StatefulBuilder(
          builder: (context, setState) => MaterialApp(
            theme: KonataTheme.darkTheme(),
            home: Scaffold(
              body: KonataTopNavBar(
                selectedIndex: 0,
                onSelectedIndexChanged: (_) {},
                searchQuery: dispatched,
                onSearchChanged: (value) => dispatched = value,
                searchFocusNode: focus,
                searchExpanded: expanded,
                onSearchExpandedChanged: (v) => setState(() => expanded = v),
                onToggleTheme: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('top_nav_fluid_indicator')),
        findsOneWidget,
      );

      await tester.tap(find.byTooltip('搜索媒体库'));
      await tester.pumpAndSettle();
      expect(expanded, isTrue);

      await tester.enterText(
        find.byKey(const ValueKey('top_nav_search_text_field')),
        '冰菓',
      );
      await tester.pump(const Duration(milliseconds: 220));
      expect(dispatched, '冰菓');

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(expanded, isFalse);
      expect(dispatched, '');
    });
  });
}
