import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:konata_design_system/konata_design_system.dart';

void main() {
  testWidgets('二级筛选跨端可读且支持选中、长名称和滚轮', (tester) async {
    final previous = debugDefaultTargetPlatformOverride;
    addTearDown(() => debugDefaultTargetPlatformOverride = previous);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.devicePixelRatio = 1;
    for (final size in const [
      Size(1440, 900),
      Size(1024, 700),
      Size(700, 1024),
      Size(390, 780),
      Size(780, 390),
    ]) {
      final touch = size.width != 1440;
      debugDefaultTargetPlatformOverride = touch
          ? TargetPlatform.android
          : TargetPlatform.windows;
      tester.view.physicalSize = size;
      for (final dark in [true, false]) {
        var selection = 0;
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpWidget(
          MaterialApp(
            theme: dark ? KonataTheme.darkTheme() : KonataTheme.lightTheme(),
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 320,
                  child: StatefulBuilder(
                    builder: (_, update) => KonataSecondaryFilterBar<int>(
                      items: [
                        (value: 0, label: '全部 (30)'),
                        (value: 1, label: '特典 (10)'),
                        (value: 2, label: '长名称' * 40),
                        (value: 3, label: '目录四'),
                      ],
                      selected: selection,
                      onSelected: (value) => update(() => selection = value),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final bar = find.byType(KonataSecondaryFilterBar<int>);
        expect(tester.getSize(bar).height, touch ? 48 : 32);
        await tester.tap(find.text('特典 (10)'));
        await tester.pumpAndSettle();
        expect(selection, 1);
        final scroll = tester.state<ScrollableState>(
          find.descendant(of: bar, matching: find.byType(Scrollable)),
        );
        await tester.sendEventToBinding(
          PointerScrollEvent(
            position: tester.getCenter(bar),
            scrollDelta: const Offset(0, 120),
          ),
        );
        await tester.pumpAndSettle();
        expect(scroll.position.pixels, greaterThan(0));
        expect(tester.takeException(), isNull);
      }
    }
  });

  testWidgets('滚动条在滚动范围变化时保持独立轨道宽度', (tester) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final dpr in [1.0, 1.5, 2.0]) {
      tester.view.devicePixelRatio = dpr;
      tester.view.physicalSize = Size(390 * dpr, 780 * dpr);
      for (final dark in [true, false]) {
        final controller = ScrollController();
        var count = 1;
        late StateSetter setCount;
        await tester.pumpWidget(
          MaterialApp(
            theme: dark ? KonataTheme.darkTheme() : KonataTheme.lightTheme(),
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 280,
                  height: 180,
                  child: StatefulBuilder(
                    builder: (_, update) {
                      setCount = update;
                      return KonataDraggableScrollbar(
                        controller: controller,
                        trackInsets: const EdgeInsets.only(right: 4),
                        builder: (_, ctrl) => ListView.builder(
                          controller: ctrl,
                          padding: EdgeInsets.zero,
                          itemExtent: 40,
                          itemCount: count,
                          itemBuilder: (_, index) => SizedBox(
                            key: ValueKey('card-$index'),
                            child: Text('条目 $index'),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final bar = tester.getRect(find.byType(KonataDraggableScrollbar));
        final shortRect = tester.getRect(find.byKey(const ValueKey('card-0')));
        expect(bar.right - shortRect.right, greaterThanOrEqualTo(18));
        setCount(() => count = 40);
        await tester.pumpAndSettle();
        expect(tester.getRect(find.byKey(const ValueKey('card-0'))), shortRect);
        expect(controller.position.maxScrollExtent, greaterThan(0));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        controller.dispose();
      }
    }
  });
}
