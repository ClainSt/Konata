import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:konata_design_system/konata_design_system.dart';

void main() {
  testWidgets('底层视口按真实像素同步，移动、缩放和移除均不重复派发', (tester) async {
    tester.view.devicePixelRatio = 2;
    tester.view.physicalSize = const Size(800, 600);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final owner = Object();
    final events = <KonataUnderlayGeometry?>[];
    Widget frame(double x, double w, double dpr) => MediaQuery(
      data: MediaQueryData(size: const Size(400, 300), devicePixelRatio: dpr),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Stack(
          children: [
            Positioned(
              left: x,
              top: 20,
              width: w,
              height: 90,
              child: KonataUnderlayViewport(
                owner: owner,
                cornerRadius: 8,
                onGeometryChanged: events.add,
              ),
            ),
          ],
        ),
      ),
    );
    await tester.pumpWidget(frame(10, 160, 2));
    expect(events, [
      (rect: const Rect.fromLTRB(20, 40, 340, 220), radius: 16.0),
    ]);
    await tester.pumpWidget(frame(10, 160, 2));
    expect(events, hasLength(1));
    await tester.pumpWidget(frame(30, 160, 2));
    expect(events.last?.rect, const Rect.fromLTRB(60, 40, 380, 220));
    await tester.pumpWidget(frame(30, 120, 1.5));
    expect(events.last, (
      rect: const Rect.fromLTRB(45, 30, 225, 165),
      radius: 12.0,
    ));
    await tester.pumpWidget(const SizedBox.shrink());
    expect(events.last, isNull);
    expect(events, hasLength(4));
    expect(tester.takeException(), isNull);
  });
}
