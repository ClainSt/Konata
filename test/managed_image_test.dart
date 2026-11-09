import 'dart:ui' as ui;
import 'dart:io';
import 'package:ccplayer/ui/managed_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('managed local artwork resolves into a decoded image', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('ccplayer-image-');
    final file = File('${dir.path}/pixel.png');
    await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawColor(Colors.blue, BlendMode.src);
      final picture = recorder.endRecording();
      final image = await picture.toImage(20, 30);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
      picture.dispose();
    });
    Object? loadError;
    Widget artwork(String path) => MaterialApp(
      home: Center(
        child: ManagedImage(
          path,
          frameBuilder: (_, child, frame, synchronous) =>
              frame == null && !synchronous
              ? const Text('episode placeholder')
              : child,
          errorBuilder: (_, error, _) {
            loadError = error;
            return const Text('episode placeholder');
          },
        ),
      ),
    );
    await tester.runAsync(() async {
      await tester.pumpWidget(artwork(file.path));
      expect(find.text('episode placeholder'), findsOneWidget);
      for (
        var attempt = 0;
        attempt < 100 && find.text('episode placeholder').evaluate().isNotEmpty;
        attempt++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        await tester.pump();
      }
    });
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsOneWidget);
    expect(find.text('episode placeholder'), findsNothing);
    expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
    expect(loadError, isNull);
    expect(tester.takeException(), isNull);
    await tester.runAsync(() async {
      await tester.pumpWidget(artwork('${dir.path}/missing.png'));
      expect(find.text('episode placeholder'), findsOneWidget);
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    expect(find.text('episode placeholder'), findsOneWidget);
    expect(loadError, isNotNull);
    expect(tester.takeException(), isNull);
    await tester.runAsync(() => dir.delete(recursive: true));
  });
}
