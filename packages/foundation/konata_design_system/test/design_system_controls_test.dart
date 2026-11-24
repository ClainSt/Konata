import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:konata_design_system/konata_design_system.dart';

Widget _wrapApp(Widget child, {bool dark = true}) {
  final base = dark ? KonataTheme.darkTheme() : KonataTheme.lightTheme();
  return MaterialApp(
    theme: base.copyWith(platform: TargetPlatform.windows),
    darkTheme: base.copyWith(platform: TargetPlatform.windows),
    home: Scaffold(body: child),
  );
}

void main() {
  group('KonataTheme 与光学令牌校验', () {
    test('亮/暗双主题 ProgressIndicatorTheme 与调色盘完全对齐', () {
      for (final isDark in const <bool>[false, true]) {
        final expectedPal = isDark ? KonataPalette.dark : KonataPalette.light;
        final theme = isDark
            ? KonataTheme.darkTheme()
            : KonataTheme.lightTheme();
        expect(theme.progressIndicatorTheme.color, expectedPal.progressFill);
        expect(
          theme.progressIndicatorTheme.linearTrackColor,
          expectedPal.progressTrack,
        );
        expect(
          theme.progressIndicatorTheme.stopIndicatorColor,
          Colors.transparent,
        );
        expect(theme.progressIndicatorTheme.stopIndicatorRadius, 0);
      }
    });
  });

  group('设置容器自适应分栏与手机二级推栈', () {
    testWidgets('桌面/平板左右分栏与手机推入二级路由及 desktopOnly 平台过滤', (tester) async {
      final categories = <AdaptiveSettingsCategory<String>>[
        AdaptiveSettingsCategory<String>(
          value: 'appearance',
          icon: Icons.palette_outlined,
          title: '外观',
          summary: '深色模式',
          panel: (_) => const Text('面板_外观'),
        ),
        AdaptiveSettingsCategory<String>(
          value: 'external',
          icon: Icons.open_in_new_rounded,
          title: '外置播放器',
          summary: '仅桌面',
          desktopOnly: true,
          panel: (_) => const Text('面板_外置'),
        ),
      ];

      // 1. 桌面端显示全部两项并直接呈现右侧面板。
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      var selected = 'appearance';
      await tester.pumpWidget(
        MaterialApp(
          theme: KonataTheme.darkTheme(),
          home: Scaffold(
            body: AdaptiveSettingsContainer<String>(
              categories: categories,
              selected: selected,
              onSelected: (v) => selected = v,
              onDetailVisibilityChanged: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('外置播放器'), findsOneWidget);
      expect(find.text('面板_外观'), findsOneWidget);

      // 2. Android 手机过滤 desktopOnly、一级仅见摘要、点击推入二级并可返回。
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      tester.view.physicalSize = const Size(390, 780);
      var detailVisible = false;
      await tester.pumpWidget(
        MaterialApp(
          theme: KonataTheme.darkTheme(),
          home: Scaffold(
            body: AdaptiveSettingsContainer<String>(
              categories: categories,
              selected: selected,
              onSelected: (v) => selected = v,
              onDetailVisibilityChanged: (v) => detailVisible = v,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('外置播放器'), findsNothing);
      expect(find.text('面板_外观'), findsNothing);
      expect(find.text('深色模式'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('settings_category_appearance')));
      await tester.pumpAndSettle();
      expect(detailVisible, isTrue);
      expect(find.text('面板_外观'), findsOneWidget);
      expect(find.byKey(const ValueKey('settings_detail_back')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('settings_detail_back')));
      await tester.pumpAndSettle();
      expect(detailVisible, isFalse);
      expect(find.text('面板_外观'), findsNothing);
    });
  });

  group('标准交互控件热区、滚动条、单行悬停高亮与毛玻璃浮层', () {
    testWidgets('触屏共用控件最小 48dp 热区与窄列折行无溢出', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      var changes = 0;

      await tester.pumpWidget(
        MaterialApp(
          theme: KonataTheme.darkTheme(),
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 290,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    KonataPillButton.secondary(
                      key: const ValueKey('touch_button'),
                      label: '测试按钮',
                      compact: true,
                      onPressed: () => changes++,
                    ),
                    KonataDropdown<int>(
                      key: const ValueKey('touch_dropdown'),
                      value: 0,
                      options: const <KonataDropdownOption<int>>[
                        KonataDropdownOption<int>(value: 0, label: '选项甲'),
                        KonataDropdownOption<int>(value: 1, label: '选项乙'),
                      ],
                      onChanged: (_) => changes++,
                    ),
                    KonataSegmentedCapsule<int>(
                      selected: 0,
                      options: const <KonataSegmentOption<int>>[
                        KonataSegmentOption<int>(value: 0, label: '跟随系统代理默认'),
                        KonataSegmentOption<int>(value: 1, label: '自定义本地代理'),
                        KonataSegmentOption<int>(value: 2, label: '不使用代理'),
                      ],
                      onChanged: (_) => changes++,
                    ),
                    KonataSwitch(
                      key: const ValueKey('touch_switch'),
                      value: false,
                      onChanged: (_) => changes++,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        tester.getSize(find.byKey(const ValueKey('touch_button'))).height,
        greaterThanOrEqualTo(48),
      );
      expect(
        tester.getSize(find.byKey(const ValueKey('touch_dropdown'))).height,
        greaterThanOrEqualTo(48),
      );
      expect(
        tester.getSize(find.byKey(const ValueKey('touch_switch'))).height,
        greaterThanOrEqualTo(48),
      );
      await tester.tap(find.text('测试按钮'));
      await tester.tap(find.text('不使用代理'));
      await tester.tap(find.byKey(const ValueKey('touch_switch')));
      expect(changes, 3);
    });

    testWidgets('KonataDraggableScrollbar 左键拖拽滚动与 KonataDropdown 长列表点选', (
      tester,
    ) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        _wrapApp(
          Center(
            child: SizedBox(
              width: 320,
              height: 220,
              child: KonataDraggableScrollbar(
                controller: controller,
                builder: (_, ctrl) => ListView.builder(
                  controller: ctrl,
                  itemExtent: 44,
                  itemCount: 40,
                  itemBuilder: (_, index) => SizedBox(
                    height: 44,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text('列表条目 $index'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final box = tester.getRect(find.byType(KonataDraggableScrollbar));
      final dragStart = Offset(box.right - 4.75, box.top + 18);
      final gesture = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
      );
      await gesture.addPointer(location: dragStart);
      await tester.pump();
      await gesture.down(dragStart);
      await tester.pump(const Duration(milliseconds: 50));
      await gesture.moveBy(const Offset(0, 110));
      await tester.pump(const Duration(milliseconds: 50));
      await gesture.up();
      await gesture.removePointer();
      await tester.pumpAndSettle();
      expect(controller.offset, greaterThan(100.0));

      String? selected = 'opt_0';
      final options = List<KonataDropdownOption<String>>.generate(
        26,
        (i) => KonataDropdownOption<String>(
          value: 'opt_$i',
          label: '选项 $i',
          subtitle: '子目录_$i',
        ),
      );

      await tester.pumpWidget(
        _wrapApp(
          Center(
            child: StatefulBuilder(
              builder: (context, setState) => SizedBox(
                width: 240,
                child: KonataDropdown<String>(
                  value: selected,
                  options: options,
                  onChanged: (next) => setState(() => selected = next),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(KonataDropdown<String>));
      await tester.pumpAndSettle();

      final ddBox = tester.getRect(find.byType(KonataDraggableScrollbar).last);
      final ddDrag = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await ddDrag.addPointer(location: Offset(ddBox.right - 4.75, ddBox.top + 18));
      await tester.pump();
      await ddDrag.down(Offset(ddBox.right - 4.75, ddBox.top + 18));
      await tester.pump(const Duration(milliseconds: 50));
      await ddDrag.moveBy(const Offset(0, 260));
      await tester.pump(const Duration(milliseconds: 50));
      await ddDrag.up();
      await tester.pumpAndSettle();

      await tester.tap(find.text('选项 25'));
      await tester.pumpAndSettle();
      expect(selected, 'opt_25');
    });

    testWidgets('KonataGlassMenu 浅色主题逐帧划过严格单行高亮零残影', (tester) async {
      Color? tileBg(Finder textFinder) {
        final tile = find.ancestor(
          of: textFinder,
          matching: find.byType(KonataPopoverOptionTile),
        );
        final container = tester.widget<Container>(
          find.descendant(of: tile, matching: find.byType(Container)).first,
        );
        final deco = container.decoration;
        return deco is BoxDecoration ? deco.color : null;
      }

      await tester.pumpWidget(
        _wrapApp(
          Center(
            child: Builder(
              builder: (anchorCtx) => KonataPillButton.primary(
                label: '打开菜单',
                onPressed: () {
                  showKonataGlassMenu<String>(
                    anchorContext: anchorCtx,
                    items: const <KonataGlassMenuItem<String>>[
                      KonataGlassMenuItem<String>(value: 'a', label: '菜单项甲'),
                      KonataGlassMenuItem<String>(value: 'b', label: '菜单项乙'),
                      KonataGlassMenuItem<String>(value: 'c', label: '菜单项丙'),
                    ],
                  );
                },
              ),
            ),
          ),
          dark: false,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('打开菜单'));
      await tester.pumpAndSettle();

      final lightHover = KonataPlaybackTokens.hoverFill(KonataPalette.light);
      final pointer = TestPointer(20, PointerDeviceKind.mouse);
      for (final active in const <String>['菜单项甲', '菜单项乙', '菜单项丙']) {
        await tester.sendEventToBinding(
          pointer.hover(tester.getCenter(find.text(active))),
        );
        await tester.pump();
        for (final label in const <String>['菜单项甲', '菜单项乙', '菜单项丙']) {
          expect(
            tileBg(find.text(label)),
            equals(label == active ? lightHover : Colors.transparent),
          );
        }
      }
      await tester.tap(find.text('菜单项甲'));
      await tester.pumpAndSettle();
    });

    testWidgets('KonataDraggableDialog 1px 即刻拖拽、越界钳制、双击归位与输入隔离', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final textCtrl = TextEditingController(text: '划选隔离文本');
      addTearDown(textCtrl.dispose);
      var closed = false;

      await tester.pumpWidget(
        _wrapApp(
          Center(
            child: KonataGlassDialog(
              title: '可拖拽弹窗',
              width: 420,
              onClose: () => closed = true,
              child: TextField(controller: textCtrl),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      Offset dialogOrigin() => tester.getTopLeft(
        find.descendant(
          of: find.byType(KonataDraggableDialog),
          matching: find.byType(ClipRRect),
        ),
      );

      final centerOrigin = dialogOrigin();
      final g1 = await tester.startGesture(tester.getCenter(find.text('可拖拽弹窗')));
      await g1.moveBy(const Offset(30, 16));
      await tester.pump();
      await g1.up();
      await tester.pump();
      expect(dialogOrigin().dx - centerOrigin.dx, closeTo(30.0, 2.0));
      expect(dialogOrigin().dy - centerOrigin.dy, closeTo(16.0, 2.0));

      final beforeFieldDrag = dialogOrigin();
      await tester.drag(find.byType(TextField), const Offset(80, 0));
      await tester.pump();
      expect(dialogOrigin().dx, closeTo(beforeFieldDrag.dx, 0.5));

      final titleFinder = find.text('可拖拽弹窗');
      await tester.tap(titleFinder);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(titleFinder);
      await tester.pumpAndSettle();
      expect(dialogOrigin().dx, closeTo(centerOrigin.dx, 0.5));
      expect(dialogOrigin().dy, closeTo(centerOrigin.dy, 0.5));

      await tester.tap(find.byIcon(Icons.close_rounded));
      await tester.pump();
      expect(closed, isTrue);
    });

    testWidgets('KonataToastScope 居中弹出关闭与 KonataWindowResizeScope 实时缩放模糊挂起', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);

      final toastCtrl = KonataToastController();
      addTearDown(toastCtrl.dispose);
      final resizing = ValueNotifier<bool>(false);
      addTearDown(resizing.dispose);

      await tester.pumpWidget(
        KonataToastScope(
          controller: toastCtrl,
          child: KonataWindowResizeScope(
            resizingListenable: resizing,
            child: MaterialApp(
              theme: KonataTheme.darkTheme(),
              home: Scaffold(
                body: Stack(
                  children: <Widget>[
                    Center(
                      child: KonataAdaptiveBackdropBlur(
                        filter: KonataTheme.blurFilterControl,
                        child: const Column(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            KonataSpecBadge(label: 'HEVC · 10bit', highlighted: true),
                            EpisodeCategoryBadge(isSpecial: false),
                            KonataOsdStrokedText('帧率 23.976'),
                            SizedBox(
                              width: 48,
                              height: 48,
                              child: KonataCdDiscPlaceholder(),
                            ),
                            BangumiScoreWordmarkBadge(score: 8.6),
                            EllipsisTextWithTooltip(
                              text: '超长作品标题测试',
                              style: TextStyle(fontSize: 13),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const KonataToastViewport(),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final adaptiveFilterFinder = find.descendant(
        of: find.byType(KonataAdaptiveBackdropBlur),
        matching: find.byType(BackdropFilter),
      ).first;
      expect(
        tester.widget<BackdropFilter>(adaptiveFilterFinder).enabled,
        isTrue,
      );
      resizing.value = true;
      await tester.pump();
      expect(
        tester.widget<BackdropFilter>(adaptiveFilterFinder).enabled,
        isFalse,
      );
      resizing.value = false;
      await tester.pump();
      expect(
        tester.widget<BackdropFilter>(adaptiveFilterFinder).enabled,
        isTrue,
      );

      toastCtrl.show('网络异常测试', isError: true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('网络异常测试'), findsOneWidget);

      final closeFinder = find.byKey(const ValueKey('konata_toast_close'));
      final closeSize = tester.getSize(closeFinder);
      expect(closeSize.width, greaterThanOrEqualTo(48));
      expect(closeSize.height, greaterThanOrEqualTo(48));
      await tester.tap(closeFinder);
      await tester.pumpAndSettle();
      expect(find.text('网络异常测试'), findsNothing);
    });
  });
}
