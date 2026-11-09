import 'package:ccplayer/ui/konata_motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final viewport in [
    const Size(390, 780),
    const Size(1024, 700),
    const Size(1440, 900),
  ]) {
    testWidgets('poster geometry and crop remain continuous at $viewport', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(viewport);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final phone = viewport.width < 650;
      final start = Rect.fromLTWH(viewport.width - 160, 280, 130, 195);
      final end = phone
          ? Rect.fromLTWH(0, 0, viewport.width, 400)
          : const Rect.fromLTWH(40, 80, 245, 367.5);
      Widget page(Rect rect, bool detail) => Scaffold(
        body: Stack(
          children: [
            Positioned.fromRect(
              rect: rect,
              child: KonataPoster(
                tag: 'poster',
                radius: detail ? (phone ? 0 : 8) : 4,
                alignment: detail && phone
                    ? Alignment.topCenter
                    : Alignment.center,
                gradient: detail && phone
                    ? const LinearGradient(
                        colors: [Colors.transparent, Colors.white],
                      )
                    : null,
                image: (alignment) => Align(
                  alignment: alignment,
                  child: const ColoredBox(
                    color: Colors.green,
                    child: SizedBox.expand(),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
      await tester.pumpWidget(MaterialApp(home: page(start, false)));
      final nav = tester.state<NavigatorState>(find.byType(Navigator));
      void open() => nav.push(
        PageRouteBuilder<void>(
          transitionDuration: KonataMotion.coverDuration(
            tester.element(find.byType(Hero)),
          ),
          reverseTransitionDuration: KonataMotion.coverDuration(
            tester.element(find.byType(Hero)),
            reverse: true,
          ),
          transitionsBuilder: (_, animation, _, child) =>
              KonataMotion.coverTransition(animation, child),
          pageBuilder: (_, _, _) => page(end, true),
        ),
      );
      final flight = find.byKey(const ValueKey('poster-flight'));
      open();
      for (final reverse in [false, true]) {
        if (reverse) nav.pop();
        await tester.pump();
        final from = reverse ? end : start, to = reverse ? start : end;
        var previous = from;
        var samples = 0;
        for (var i = 0; i < 25; i++) {
          await tester.pump(const Duration(milliseconds: 16));
          if (flight.evaluate().isEmpty) break;
          final rect = tester.getRect(flight);
          final t = (rect.width - from.width) / (to.width - from.width);
          expect(t, inInclusiveRange(0.0, 1.0));
          final expected = Rect.lerp(from, to, t)!;
          expect(
            (rect.center - expected.center).distance,
            lessThan(.01),
            reason: 'No independent arc or moving landing point',
          );
          expect(
            (rect.center - previous.center).distance,
            lessThan((to.center - from.center).distance * .18 + 1),
            reason: 'No single-frame position jump',
          );
          final clip = tester.widget<ClipRRect>(
            find.descendant(of: flight, matching: find.byType(ClipRRect)),
          );
          final fromRadius = reverse ? (phone ? 0.0 : 8.0) : 4.0;
          final toRadius = reverse ? 4.0 : (phone ? 0.0 : 8.0);
          expect(
            (clip.borderRadius as BorderRadius).topLeft.x,
            closeTo(fromRadius + (toRadius - fromRadius) * t, .001),
          );
          final crop = tester.widget<Align>(
            find.descendant(of: flight, matching: find.byType(Align)),
          );
          final fromAlign = reverse && phone
              ? Alignment.topCenter
              : Alignment.center;
          final toAlign = !reverse && phone
              ? Alignment.topCenter
              : Alignment.center;
          expect(
            (crop.alignment as Alignment).y,
            closeTo(Alignment.lerp(fromAlign, toAlign, t)!.y, .001),
          );
          previous = rect;
          samples++;
        }
        expect(samples, greaterThan(12));
        expect((previous.center - to.center).distance, lessThan(2));
        await tester.pumpAndSettle();
      }
      // An immediate back action redirects the existing flight, without resetting it.
      open();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 96));
      final interrupted = tester.getRect(flight);
      nav.pop();
      await tester.pump();
      expect(
        (tester.getRect(flight).center - interrupted.center).distance,
        lessThan(.01),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(tester.binding.transientCallbackCount, 0);
    });
  }
}
