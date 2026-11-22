import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ccplayer/presentation/theme/konata_theme.dart';
import 'package:ccplayer/presentation/widgets/design_system/konata_draggable_scrollbar.dart';
import 'package:ccplayer/presentation/widgets/design_system/konata_dropdown.dart';

Widget _wrapTestApp(Widget child) {
  final base = KonataTheme.darkTheme();
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
  });
}
