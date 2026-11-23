import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:konata/domain/models/work.dart';
import 'package:konata/presentation/detail/detail_gear_menu.dart';
import 'package:konata/presentation/detail/series_switcher_dropdown.dart';
import 'package:konata/presentation/theme/konata_palette.dart';
import 'package:konata/presentation/theme/konata_playback_tokens.dart';
import 'package:konata/presentation/theme/konata_theme.dart';
import 'package:konata/presentation/widgets/design_system/konata_draggable_scrollbar.dart';
import 'package:konata/presentation/widgets/design_system/konata_dropdown.dart';
import 'package:konata/presentation/widgets/design_system/konata_glass_menu.dart';
import 'package:konata/presentation/widgets/design_system/konata_popover_option_tile.dart';

Widget _wrapTestApp(Widget child, {bool dark = true}) {
  final base = dark ? KonataTheme.darkTheme() : KonataTheme.lightTheme();
  return MaterialApp(
    theme: base.copyWith(platform: TargetPlatform.windows),
    darkTheme: base.copyWith(platform: TargetPlatform.windows),
    home: Scaffold(body: child),
  );
}

void main() {
  group('可拖拽滚动条与毛玻璃下拉菜单交互测试', () {
    testWidgets('KonataDraggableScrollbar 左键按住滑块拖拽可驱动绑定的 ScrollController 滚动', (
      tester,
    ) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        _wrapTestApp(
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

      expect(controller.offset, 0.0);
      final box = tester.getRect(find.byType(KonataDraggableScrollbar));
      // 鼠标左键精准按在右侧滑块（Windows crossAxisMargin=2, thickness=5.5）中心并向下拖拽
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
      await tester.pumpAndSettle();

      expect(controller.offset, greaterThan(100.0));
    });

    testWidgets('KonataDropdown 超过 20 项时展开支持拖拽滚动条并点选后段选项', (
      tester,
    ) async {
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
        _wrapTestApp(
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

      // 点击触发器展开下拉浮层
      await tester.tap(find.byType(KonataDropdown<String>));
      await tester.pumpAndSettle();

      expect(find.text('选项 0'), findsWidgets);
      expect(find.text('选项 25'), findsNothing);

      final scrollbarFinder = find.byType(KonataDraggableScrollbar).last;
      final box = tester.getRect(scrollbarFinder);
      final dragStart = Offset(box.right - 4.75, box.top + 18);
      final gesture = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
      );
      await gesture.addPointer(location: dragStart);
      await tester.pump();
      await gesture.down(dragStart);
      await tester.pump(const Duration(milliseconds: 50));
      await gesture.moveBy(const Offset(0, 260));
      await tester.pump(const Duration(milliseconds: 50));
      await gesture.up();
      await tester.pumpAndSettle();

      final targetOption = find.text('选项 25');
      expect(targetOption, findsOneWidget);
      await tester.tap(targetOption);
      await tester.pumpAndSettle();

      expect(selected, 'opt_25');
    });

    testWidgets(
      '浅色与深色主题下 KonataDropdown / KonataGlassMenu / DetailGearMenuOverlay / SeriesSwitcherDropdown 划过选项单帧严格单行高亮且零双行灰框残留',
      (tester) async {
        Color? tilePaintedBg(WidgetTester t, Finder textFinder) {
          final tile = find.ancestor(
            of: textFinder,
            matching: find.byType(KonataPopoverOptionTile),
          );
          expect(tile, findsOneWidget);
          expect(
            find.descendant(of: tile, matching: find.byType(AnimatedContainer)),
            findsNothing,
          );
          expect(
            find.descendant(of: tile, matching: find.byType(InkWell)),
            findsNothing,
          );
          final container = t.widget<Container>(
            find.descendant(of: tile, matching: find.byType(Container)).first,
          );
          final deco = container.decoration;
          return deco is BoxDecoration ? deco.color : null;
        }

        // 1. 浅色与深色主题下的 KonataDropdown 逐帧快速划过验证
        for (final isDark in const [false, true]) {
          final palette = isDark ? KonataPalette.dark : KonataPalette.light;
          final expectedHover = KonataPlaybackTokens.hoverFill(palette);
          var selected = 3;
          await tester.pumpWidget(
            _wrapTestApp(
              Center(
                child: SizedBox(
                  width: 240,
                  child: StatefulBuilder(
                    builder: (context, setState) => KonataDropdown<int>(
                      key: ValueKey('hover_dropdown_$isDark'),
                      value: selected,
                      options: const [
                        KonataDropdownOption(value: 0, label: '关闭（仅手动或事件触发）'),
                        KonataDropdownOption(value: 3, label: '每 3 分钟'),
                        KonataDropdownOption(value: 5, label: '每 5 分钟'),
                        KonataDropdownOption(value: 10, label: '每 10 分钟'),
                        KonataDropdownOption(value: 15, label: '每 15 分钟'),
                      ],
                      onChanged: (next) => setState(() => selected = next),
                    ),
                  ),
                ),
              ),
              dark: isDark,
            ),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.byType(KonataDropdown<int>));
          await tester.pumpAndSettle();

          final hoverLabels = const [
            '关闭（仅手动或事件触发）',
            '每 5 分钟',
            '每 10 分钟',
            '每 15 分钟',
          ];
          final pointer = TestPointer(10 + (isDark ? 1 : 0), PointerDeviceKind.mouse);
          for (final targetLabel in hoverLabels) {
            await tester.sendEventToBinding(
              pointer.hover(tester.getCenter(find.text(targetLabel))),
            );
            await tester.pump();
            for (final dt in const [Duration.zero, Duration(milliseconds: 16), Duration(milliseconds: 50)]) {
              if (dt > Duration.zero) await tester.pump(dt);
              var litCount = 0;
              for (final label in hoverLabels) {
                final bg = tilePaintedBg(tester, find.text(label));
                if (label == targetLabel) {
                  expect(bg, equals(expectedHover));
                  litCount++;
                } else {
                  expect(bg, equals(Colors.transparent));
                }
              }
              expect(litCount, equals(1));
            }
          }
          await tester.sendEventToBinding(pointer.hover(Offset.zero));
          await tester.pump();
          for (final label in hoverLabels) {
            expect(tilePaintedBg(tester, find.text(label)), Colors.transparent);
          }
        }

        // 2. 浅色主题下 showKonataGlassMenu 逐帧严格单行高亮
        await tester.pumpWidget(
          _wrapTestApp(
            Center(
              child: Builder(
                builder: (anchorCtx) => ElevatedButton(
                  onPressed: () => showKonataGlassMenu<String>(
                    anchorContext: anchorCtx,
                    items: const [
                      KonataGlassMenuItem(value: 'a', label: '菜单项甲'),
                      KonataGlassMenuItem(value: 'b', label: '菜单项乙'),
                      KonataGlassMenuItem(value: 'c', label: '菜单项丙'),
                    ],
                  ),
                  child: const Text('打开菜单'),
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
        final menuPointer = TestPointer(20, PointerDeviceKind.mouse);
        for (final active in const ['菜单项甲', '菜单项乙', '菜单项丙']) {
          await tester.sendEventToBinding(
            menuPointer.hover(tester.getCenter(find.text(active))),
          );
          await tester.pump();
          for (final label in const ['菜单项甲', '菜单项乙', '菜单项丙']) {
            expect(
              tilePaintedBg(tester, find.text(label)),
              equals(label == active ? lightHover : Colors.transparent),
            );
          }
        }
        await tester.tap(find.text('菜单项甲'));
        await tester.pumpAndSettle();

        // 3. 浅色主题下 DetailGearMenuOverlay 与 SeriesSwitcherDropdown 逐帧严格单行高亮
        final gearLink = LayerLink();
        await tester.pumpWidget(
          _wrapTestApp(
            Stack(
              children: [
                Positioned(
                  right: 24,
                  top: 24,
                  child: CompositedTransformTarget(
                    link: gearLink,
                    child: const SizedBox(width: 32, height: 32),
                  ),
                ),
                DetailGearMenuOverlay(
                  link: gearLink,
                  openDownward: true,
                  onDismiss: () {},
                  onSelect: (_) {},
                  onManualMatch: () {},
                  onManualEdit: () {},
                  onEditPoster: () {},
                  onEditBackdrop: () {},
                  onHideWork: () {},
                  onDeleteWork: () {},
                  onRescrape: () {},
                  onOpenLocalDir: () {},
                ),
              ],
            ),
            dark: false,
          ),
        );
        await tester.pumpAndSettle();

        final gearPointer = TestPointer(30, PointerDeviceKind.mouse);
        for (final active in const ['绑定元数据', '手动编辑', '编辑封面']) {
          await tester.sendEventToBinding(
            gearPointer.hover(tester.getCenter(find.text(active))),
          );
          await tester.pump();
          for (final label in const ['绑定元数据', '手动编辑', '编辑封面']) {
            expect(
              tilePaintedBg(tester, find.text(label)),
              equals(label == active ? lightHover : Colors.transparent),
            );
          }
        }

        const workA = Work(
          id: 'w_a',
          title: '第一季',
          seriesLabel: '第 1 季',
        );
        const workB = Work(
          id: 'w_b',
          title: '第二季',
          seriesLabel: '第 2 季',
        );
        const workC = Work(
          id: 'w_c',
          title: '剧场版',
          seriesLabel: '剧场版',
        );
        await tester.pumpWidget(
          _wrapTestApp(
            Center(
              child: SeriesSwitcherDropdown(
                activeWork: workA,
                seriesMembers: const [workA, workB, workC],
                openDownward: true,
                onSelectWork: (_) {},
              ),
            ),
            dark: false,
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byType(SeriesSwitcherDropdown));
        await tester.pumpAndSettle();

        final seriesPointer = TestPointer(40, PointerDeviceKind.mouse);
        for (final active in const ['第 2 季', '剧场版']) {
          await tester.sendEventToBinding(
            seriesPointer.hover(tester.getCenter(find.text(active))),
          );
          await tester.pump();
          for (final label in const ['第 2 季', '剧场版']) {
            expect(
              tilePaintedBg(tester, find.text(label)),
              equals(label == active ? lightHover : Colors.transparent),
            );
          }
        }
      },
    );
  });
}
