import 'dart:io';
import 'package:ccplayer/ui/managed_image.dart';
import 'package:ccplayer/ui/konata_motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('cover route stays anchored while the poster travels', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    navigator.push(
      PageRouteBuilder<void>(
        transitionDuration: const Duration(milliseconds: 360),
        transitionsBuilder: (_, animation, _, child) =>
            KonataMotion.coverTransition(animation, child),
        pageBuilder: (_, _, _) =>
            const SizedBox.expand(key: ValueKey('detail-plane')),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('detail-plane'))),
      Offset.zero,
      reason: 'The route must not move the Hero landing point independently',
    );
    await tester.pumpAndSettle();
  });
  testWidgets('a decoded cover remains visible on the first frame of a new route', (
    tester,
  ) async {
    final dir = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('konata-cover-'),
    ))!;
    final file = File('${dir.path}/cover.png');
    await tester.runAsync(
      () => File('assets/brand/konata-ui.png').copy(file.path),
    );
    addTearDown(() => tester.runAsync(() => dir.delete(recursive: true)));
    Widget frame(int key) => MaterialApp(
      home: Scaffold(
        body: KonataPoster(
          tag: 'cover',
          image: (alignment) =>
              ManagedImage(file.path, key: ValueKey(key), alignment: alignment),
        ),
      ),
    );
    await tester.runAsync(() => tester.pumpWidget(frame(0)));
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
      if (tester
          .widgetList<RawImage>(find.byType(RawImage))
          .any((i) => i.image != null)) {
        break;
      }
    }
    expect(
      tester
          .widgetList<RawImage>(find.byType(RawImage))
          .any((i) => i.image != null),
      isTrue,
    );
    for (var i = 1; i <= 6; i++) {
      // A different route/Hero subtree must reuse the decoded image immediately.
      await tester.pumpWidget(frame(i));
      expect(
        tester
            .widgetList<RawImage>(find.byType(RawImage))
            .any((i) => i.image != null),
        isTrue,
        reason:
            'Cover must not become a placeholder when entering/leaving a page',
      );
    }
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    navigator.push(
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
        pageBuilder: (_, _, _) => Scaffold(
          body: Center(
            child: SizedBox(
              width: 180,
              height: 270,
              child: KonataPoster(
                tag: 'cover',
                radius: 8,
                image: (alignment) =>
                    ManagedImage(file.path, alignment: alignment),
              ),
            ),
          ),
        ),
      ),
    );
    for (final reverse in [false, true]) {
      if (reverse) navigator.pop();
      await tester.pump();
      for (var frame = 0; frame < 20; frame++) {
        await tester.pump(const Duration(milliseconds: 24));
        final visible = tester.widgetList<RawImage>(find.byType(RawImage));
        expect(visible, isNotEmpty);
        expect(
          visible.every((image) => image.image != null),
          true,
          reason:
              'Cover cannot disappear during Hero flight, reverse=$reverse frame=$frame',
        );
      }
    }
    await tester.pumpAndSettle();
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pumpWidget(const SizedBox());
  });
}
