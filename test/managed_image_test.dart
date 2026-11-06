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
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(home: Center(child: ManagedImage(file.path))),
      );
    });
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.runAsync(() => dir.delete(recursive: true));
  });
}
